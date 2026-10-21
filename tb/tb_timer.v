`timescale 1ns/1ps
`include "soc_pkg.vh"

//======================================================================
// tb_timer : unit test của rtl/Peripherals/timer.v (LEGACY + PERIODIC)
//======================================================================
// Clock 100 MHz (10 ns). Cổng bus giống axi_interconnect: wr_en / rd_en là
// xung 1 chu kỳ, addr/wdata hợp lệ đúng chu kỳ đó; rdata chốt theo rd_en.
//
// Hai mô hình tham chiếu chạy song song, so sánh MỖI chu kỳ:
//   - timer_legacy_ref: nguyên văn timer.v của commit HEAD (trước khi thêm
//     chế độ periodic, chỉ đổi tên module, cuối file). Nhận mọi ghi/đọc vào
//     offset không phải 0x04/0x08/0x0C -> chứng minh LEGACY không đổi.
//   - mô hình periodic viết theo cách khác RTL ("hạn chót tuyệt đối": tick khi
//     số cạnh kể từ mốc >= PERIOD), không dùng bộ đếm so sánh như RTL.
//   irq của DUT phải == irq_ref_legacy | tick_model ở mọi chu kỳ.
//
// Quy ước đo: cyc = số thứ tự cạnh lên. Lệnh ghi đặt ở cạnh xuống được chốt
// ở cạnh lên kế tiếp (last_wr_edge). Xung irq quan sát ở cạnh xuống sau cạnh
// lên cyc được ghi là thời điểm cyc. "IRQ sau N clock" = irq_t - last_wr_edge.
//
// Test: T1 one-shot LEGACY (+ bí danh offset), T2 periodic PERIOD = 10000,
//   T3 TICK_COUNT, T4 disable (kể cả trùng cạnh tick), T5 reset giữa chừng,
//   T6 PERIOD 0/1/2, T7 off-by-one nhiều PERIOD, T8 one-shot mới / đổi chế độ /
//   ghi lại CTRL / đổi PERIOD khi chạy, T9 ngẫu nhiên có reset so với mô hình.
//
// Chạy: python scripts/run_rtl_tests.py --vivado-root <Vivado> --tests tb_timer
//======================================================================

module tb_timer;

    localparam [31:0] BASE = `TIMER_BASE;
    localparam [3:0]  IDX_LEGACY = 4'd0, IDX_PERIOD = 4'd1, IDX_CTRL = 4'd2, IDX_TICK = 4'd3;
    localparam        P10K = 10000;            // 100 MHz / 10 kHz
    localparam        MAX_IRQ_LOG = 4096;
    localparam        MAX_ERR_MSG = 20;

    reg clk = 1'b0;
    always #5 clk = ~clk;                      // 100 MHz

    reg        rst_n   = 1'b0;
    reg        wr_en   = 1'b0;
    reg        rd_en   = 1'b0;
    reg [31:0] wr_addr = 32'd0;
    reg [31:0] rd_addr = 32'd0;
    reg [31:0] wdata   = 32'd0;
    wire [31:0] rdata, ref_rdata;
    wire        irq, ref_irq;

    wire [3:0] widx = wr_addr[5:2];
    wire [3:0] ridx = rd_addr[5:2];
    wire       w_new = (widx == IDX_PERIOD) || (widx == IDX_CTRL) || (widx == IDX_TICK);
    wire       r_new = (ridx == IDX_PERIOD) || (ridx == IDX_CTRL) || (ridx == IDX_TICK);

    timer dut (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .rd_en(rd_en), .wr_addr(wr_addr), .rd_addr(rd_addr),
        .wdata(wdata), .rdata(rdata), .irq(irq)
    );

    // original timer: sees exactly the accesses that map to LEGACY
    timer_legacy_ref legacy_ref (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en && !w_new), .rd_en(rd_en && !r_new),
        .wdata(wdata), .rdata(ref_rdata), .irq(ref_irq)
    );

    // edge counter: value seen at a negedge = number of the preceding rising edge
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    //------------------------------------------------------------
    // Errors
    //------------------------------------------------------------
    integer errors = 0, checks = 0, msgs = 0;

    task fail;
        input [8*120-1:0] what;
        begin
            errors = errors + 1;
            msgs = msgs + 1;
            if (msgs <= MAX_ERR_MSG) $display("ERROR [cyc %0d] %0s", cyc, what);
        end
    endtask

    task check_eq;
        input [31:0]      got;
        input [31:0]      exp;
        input [8*100-1:0] what;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                msgs = msgs + 1;
                if (msgs <= MAX_ERR_MSG)
                    $display("ERROR [cyc %0d] %0s: got %0d (0x%08h), exp %0d (0x%08h)",
                             cyc, what, got, got, exp, exp);
            end
        end
    endtask

    //------------------------------------------------------------
    // IRQ log
    //------------------------------------------------------------

    integer n_irq = 0;
    integer irq_t [0:MAX_IRQ_LOG-1];
    reg     prev_irq = 1'b0;
    reg     width_check = 1'b1;
    integer cmp_cycles = 0, cmp_err = 0;

    //------------------------------------------------------------
    // Periodic model (absolute-deadline formulation)
    //------------------------------------------------------------
    reg [31:0] m_period = 0, m_ticks = 0, m_base = 0, m_e = 0, m_rd = 0;
    reg        m_en = 0, m_per = 0, m_tick = 0, tick_now;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            m_period = 0; m_ticks = 0; m_base = 0; m_en = 0; m_per = 0; m_tick = 0;
        end else begin
            m_e = m_e + 1;
            if (rd_en)
                m_rd = (ridx == IDX_PERIOD) ? m_period :
                       (ridx == IDX_CTRL)   ? {29'd0, (m_period < 2), m_per, m_en} :
                                              m_ticks;
            // tick due at this edge (values before the edge)
            tick_now = m_en && (m_period >= 2) && (m_e - m_base >= m_period);
            if (wr_en && widx == IDX_CTRL) begin
                if (!wdata[0]) begin
                    m_en = 0; tick_now = 0;            // disable wins
                end else if (!m_en) begin
                    m_en = 1; m_base = m_e;            // start: deadline = this edge + PERIOD
                end
                m_per = wdata[1];
            end
            if (tick_now) begin
                m_ticks = m_ticks + 1;
                m_base  = m_e;
                if (!m_per) m_en = 0;                  // one-shot
            end else if (m_en && m_period < 2)
                m_base = m_e;                          // invalid PERIOD: deadline floats
            if (wr_en && widx == IDX_PERIOD) m_period = wdata;
            m_tick = tick_now;
        end
    end

    //------------------------------------------------------------
    // Cycle-by-cycle comparison + IRQ log (negedge: all NBAs settled)
    //------------------------------------------------------------
    always @(negedge clk) if ($time > 0) begin     // t=0: x->0 of clk is not a real cycle
        cmp_cycles = cmp_cycles + 1;
        if (irq !== (ref_irq | m_tick)) begin
            cmp_err = cmp_err + 1;
            fail("irq != legacy_ref.irq | model.tick");
            if (msgs <= MAX_ERR_MSG)
                $display("      irq=%b ref_irq=%b model_tick=%b", irq, ref_irq, m_tick);
        end
        if (!rst_n && irq !== 1'b0) fail("irq high during reset");
        if (irq === 1'b1) begin
            if (n_irq < MAX_IRQ_LOG) irq_t[n_irq] = cyc;
            n_irq = n_irq + 1;
            if (width_check && prev_irq) fail("irq longer than one cycle");
        end
        prev_irq = irq;
    end

    //------------------------------------------------------------
    // Bus tasks
    //------------------------------------------------------------
    integer last_wr_edge = 0;

    task wr;
        input [3:0]  idx;
        input [31:0] d;
        begin
            @(negedge clk);
            wr_en = 1'b1; wr_addr = BASE + {idx, 2'b00}; wdata = d;
            last_wr_edge = cyc + 1;
            @(negedge clk);
            wr_en = 1'b0; wr_addr = 32'h0000_00FC; wdata = 32'hDEAD_BEEF;
        end
    endtask

    // write sampled exactly at rising edge `edge_n`
    task wr_at;
        input [3:0]  idx;
        input [31:0] d;
        input integer edge_n;
        begin
            @(negedge clk);
            while (cyc < edge_n - 1) @(negedge clk);
            if (cyc != edge_n - 1) fail("wr_at: edge already passed (test scheduling)");
            wr_en = 1'b1; wr_addr = BASE + {idx, 2'b00}; wdata = d;
            last_wr_edge = cyc + 1;
            @(negedge clk);
            wr_en = 1'b0; wr_addr = 32'h0000_00FC; wdata = 32'hDEAD_BEEF;
        end
    endtask

    // read and check against legacy reference / periodic model
    task rd;
        input  [3:0]  idx;
        output [31:0] v;
        begin
            @(negedge clk);
            rd_en = 1'b1; rd_addr = BASE + {idx, 2'b00};
            @(negedge clk);
            rd_en = 1'b0; rd_addr = 32'h0000_00F8;
            v = rdata;
            checks = checks + 1;
            if ((idx == IDX_PERIOD) || (idx == IDX_CTRL) || (idx == IDX_TICK)) begin
                if (rdata !== m_rd) begin
                    fail("read of PERIOD/CTRL/TICK_COUNT != model");
                    $display("      idx %0d got 0x%08h model 0x%08h", idx, rdata, m_rd);
                end
            end else if (rdata !== ref_rdata) begin
                fail("LEGACY read != original timer");
                $display("      idx %0d got 0x%08h ref 0x%08h", idx, rdata, ref_rdata);
            end
        end
    endtask

    task wait_edge;
        input integer edge_n;
        begin
            @(negedge clk);
            while (cyc < edge_n) @(negedge clk);
        end
    endtask

    task idle;
        input integer n;
        begin repeat (n) @(negedge clk); end
    endtask

    // ticks logged since index n0 must be exactly at start + k*period (k = 1..cnt)
    task expect_ticks;
        input integer n0;
        input integer start;
        input integer period;
        input integer cnt;
        input [8*100-1:0] what;
        integer k;
        begin
            check_eq(n_irq - n0, cnt, what);
            for (k = 0; k < cnt && k < n_irq - n0; k = k + 1)
                check_eq(irq_t[n0 + k], start + (k + 1) * period, what);
        end
    endtask

    //------------------------------------------------------------
    // Test sequence
    //------------------------------------------------------------
    integer    n0, n1, e0, e1, i, k, first_gap, gap_min, gap_max, r_op;
    reg [31:0] v, t0, seed;

    initial begin
        seed = 32'd1;
        if ($value$plusargs("seed=%d", seed)) ;
        repeat (3) @(negedge clk);
        rst_n = 1'b1;
        idle(3);

        //==========================================================
        // T1: LEGACY one-shot (offset 0x00) unchanged
        //==========================================================
        n0 = n_irq;
        wr(IDX_LEGACY, 32'd15);
        e0 = last_wr_edge;
        wait_edge(e0 + 8);
        rd(IDX_LEGACY, v);                     // count while running, == original
        wait_edge(e0 + 60);
        check_eq(n_irq - n0, 1, "T1 legacy one-shot: exactly one IRQ");
        check_eq(irq_t[n0] - e0, 16, "T1 legacy compare=15: IRQ 16 clocks after write (original)");
        first_gap = irq_t[n0] - e0;
        rd(IDX_LEGACY, v);
        check_eq(v, 0, "T1 legacy count back to 0 after one-shot");
        n0 = n_irq;
        wr(IDX_LEGACY, 32'd0);                 // compare 0
        e0 = last_wr_edge;
        wait_edge(e0 + 20);
        expect_ticks(n0, e0, 1, 1, "T1 legacy compare=0");
        n0 = n_irq;
        wr(4'd4, 32'd5);                       // 0x10: old alias of LEGACY
        e0 = last_wr_edge;
        wait_edge(e0 + 20);
        expect_ticks(n0, e0, 6, 1, "T1 legacy alias 0x10");
        n0 = n_irq;
        wr(4'd15, 32'd3);                      // 0x3C: old alias of LEGACY
        e0 = last_wr_edge;
        wait_edge(e0 + 20);
        expect_ticks(n0, e0, 4, 1, "T1 legacy alias 0x3C");
        rd(4'd7, v);                           // alias read == timer_count
        $display("INFO T1 legacy one-shot: compare=15 -> IRQ after %0d clocks (original timer: 16)", first_gap);

        //==========================================================
        // T2/T3: PERIODIC, PERIOD = 10000 (10 kHz at 100 MHz)
        //==========================================================
        rd(IDX_CTRL, v);
        check_eq(v, 32'h4, "T2 CTRL after reset: disabled, PERIOD=0 invalid");
        wr(IDX_PERIOD, P10K);
        rd(IDX_PERIOD, v);
        check_eq(v, P10K, "T2 PERIOD readback");
        rd(IDX_TICK, t0);
        check_eq(t0, 0, "T2 TICK_COUNT 0 before first enable");
        n0 = n_irq;
        wr(IDX_CTRL, 32'h3);                   // ENABLE | PERIODIC
        e0 = last_wr_edge;
        rd(IDX_CTRL, v);
        check_eq(v, 32'h3, "T2 CTRL readback");
        // TICK_COUNT around the first tick edge
        wait_edge(e0 + P10K / 2);
        rd(IDX_TICK, v);
        check_eq(v, 0, "T3 TICK_COUNT before first tick");
        // read sampled AT the tick edge returns the value before the edge
        @(negedge clk); while (cyc < e0 + P10K - 1) @(negedge clk);
        rd_en = 1'b1; rd_addr = BASE + 32'h0C;
        @(negedge clk); rd_en = 1'b0;
        check_eq(rdata, 0, "T3 TICK_COUNT sampled on the tick edge (old value)");
        rd(IDX_TICK, v);
        check_eq(v, 1, "T3 TICK_COUNT right after first tick");
        wait_edge(e0 + 10 * P10K + 100);
        expect_ticks(n0, e0, P10K, 10, "T2 periodic 10000: tick k at E0 + k*10000");
        rd(IDX_TICK, v);
        check_eq(v, 10, "T3 TICK_COUNT == number of IRQs (10)");
        first_gap = irq_t[n0] - e0;
        gap_min = 32'h7fffffff; gap_max = 0;
        for (k = 1; k < 10; k = k + 1) begin
            if (irq_t[n0 + k] - irq_t[n0 + k - 1] < gap_min) gap_min = irq_t[n0 + k] - irq_t[n0 + k - 1];
            if (irq_t[n0 + k] - irq_t[n0 + k - 1] > gap_max) gap_max = irq_t[n0 + k] - irq_t[n0 + k - 1];
        end
        $display("INFO T2 PERIOD=10000: first IRQ %0d clocks after enable, interval min %0d max %0d clocks (%0d ns = %0d us), TICK_COUNT %0d",
                 first_gap, gap_min, gap_max, gap_max * 10, gap_max / 100, v);

        // T8a: rewriting CTRL=ENABLE|PERIODIC while running keeps the phase
        wait_edge(e0 + 10 * P10K + P10K / 2);
        n0 = n_irq;
        wr(IDX_CTRL, 32'h3);
        wait_edge(e0 + 12 * P10K + 10);
        check_eq(n_irq - n0, 2, "T8 CTRL rewrite while running: no restart");
        check_eq(irq_t[n0], e0 + 11 * P10K, "T8 CTRL rewrite: phase kept (tick 11)");
        check_eq(irq_t[n0 + 1], e0 + 12 * P10K, "T8 CTRL rewrite: phase kept (tick 12)");

        //==========================================================
        // T4: disable (no extra IRQ), including on/around the tick edge
        //==========================================================
        wait_edge(e0 + 12 * P10K + 3000);
        rd(IDX_TICK, t0);
        n0 = n_irq;
        wr(IDX_CTRL, 32'h2);                   // ENABLE = 0 (PERIODIC bit left 1)
        rd(IDX_CTRL, v);
        check_eq(v, 32'h2, "T4 CTRL after disable");
        idle(3 * P10K);
        check_eq(n_irq - n0, 0, "T4 no IRQ for 3 periods after disable");
        rd(IDX_TICK, v);
        check_eq(v, t0, "T4 TICK_COUNT frozen while disabled");

        // disable written exactly on the tick edge -> no tick
        wr(IDX_CTRL, 32'h3); e1 = last_wr_edge;
        n0 = n_irq;
        wr_at(IDX_CTRL, 32'h0, e1 + P10K);
        idle(2 * P10K);
        check_eq(n_irq - n0, 0, "T4 disable on the tick edge: no IRQ");
        // disable one edge before the tick -> no tick
        wr(IDX_CTRL, 32'h3); e1 = last_wr_edge;
        n0 = n_irq;
        wr_at(IDX_CTRL, 32'h0, e1 + P10K - 1);
        idle(2 * P10K);
        check_eq(n_irq - n0, 0, "T4 disable one edge before the tick: no IRQ");
        // disable one edge after the tick -> that tick happened, nothing more
        wr(IDX_CTRL, 32'h3); e1 = last_wr_edge;
        n0 = n_irq;
        wr_at(IDX_CTRL, 32'h0, e1 + P10K + 1);
        idle(2 * P10K);
        expect_ticks(n0, e1, P10K, 1, "T4 disable one edge after the tick");
        // re-enable restarts the phase from the enable edge
        n0 = n_irq;
        wr(IDX_CTRL, 32'h3); e1 = last_wr_edge;
        wait_edge(e1 + 2 * P10K + 5);
        expect_ticks(n0, e1, P10K, 2, "T4 re-enable: phase restarts at enable edge");
        wr(IDX_CTRL, 32'h0);

        //==========================================================
        // T5: reset in the middle of counting
        //==========================================================
        n0 = n_irq;
        wr(IDX_CTRL, 32'h3); e1 = last_wr_edge;
        wr(IDX_LEGACY, 32'd50000);             // legacy one-shot also in flight (fires after reset point)
        wait_edge(e1 + 2 * P10K + 4321);
        check_eq(n_irq - n0, 2, "T5 two ticks before reset");
        @(posedge clk); #2 rst_n = 1'b0;       // asynchronous, mid-cycle
        idle(4);
        rst_n = 1'b1;
        n0 = n_irq;
        rd(IDX_PERIOD, v); check_eq(v, 0, "T5 PERIOD cleared by reset");
        rd(IDX_CTRL, v);   check_eq(v, 32'h4, "T5 CTRL cleared by reset (PERIOD invalid)");
        rd(IDX_TICK, v);   check_eq(v, 0, "T5 TICK_COUNT cleared by reset");
        rd(IDX_LEGACY, v); check_eq(v, 0, "T5 legacy count cleared by reset");
        idle(3 * P10K);
        check_eq(n_irq - n0, 0, "T5 no IRQ after reset until reconfigured");
        wr(IDX_PERIOD, P10K);
        wr(IDX_CTRL, 32'h3); e1 = last_wr_edge;
        wait_edge(e1 + 2 * P10K + 5);
        expect_ticks(n0, e1, P10K, 2, "T5 reconfigure after reset: exact period");
        rd(IDX_TICK, v);   check_eq(v, 2, "T5 TICK_COUNT counts from reset");
        wr(IDX_CTRL, 32'h0);

        //==========================================================
        // T6: invalid PERIOD (0, 1) and minimum PERIOD 2
        //==========================================================
        wr(IDX_PERIOD, 32'd0);
        rd(IDX_TICK, t0);
        n0 = n_irq;
        wr(IDX_CTRL, 32'h3);
        idle(1000);
        check_eq(n_irq - n0, 0, "T6 PERIOD=0 enabled: no IRQ");
        rd(IDX_CTRL, v); check_eq(v, 32'h7, "T6 PERIOD=0: CTRL = EN|PER|INVALID");
        wr(IDX_PERIOD, 32'd1);
        idle(1000);
        check_eq(n_irq - n0, 0, "T6 PERIOD=1 enabled: no IRQ");
        rd(IDX_TICK, v); check_eq(v, t0, "T6 PERIOD 0/1: TICK_COUNT unchanged");
        wr(IDX_PERIOD, 32'd2); e1 = last_wr_edge;    // becomes valid while enabled
        rd(IDX_CTRL, v); check_eq(v, 32'h3, "T6 PERIOD=2 valid: INVALID bit clear");
        wait_edge(e1 + 20 + 1);
        expect_ticks(n0, e1, 2, 10, "T6 PERIOD=2: tick every 2 clocks from PERIOD write");
        wr(IDX_PERIOD, 32'd1); e1 = last_wr_edge;    // invalid again while running
        n1 = n_irq;                                  // a tick on the write edge is allowed (old PERIOD)
        idle(1000);
        check_eq(n_irq - n1, 0, "T6 PERIOD 2 -> 1 while running: ticks stop");
        wr(IDX_CTRL, 32'h0);

        //==========================================================
        // T7: off-by-one for several PERIOD values
        //==========================================================
        for (i = 0; i < 6; i = i + 1) begin
            k = (i == 0) ? 2 : (i == 1) ? 3 : (i == 2) ? 4 : (i == 3) ? 5 : (i == 4) ? 17 : P10K;
            wr(IDX_PERIOD, k);
            n0 = n_irq;
            wr(IDX_CTRL, 32'h3); e1 = last_wr_edge;
            wait_edge(e1 + 3 * k);
            wr(IDX_CTRL, 32'h0);                  // sampled after tick 3, before tick 4
            idle(2 * k + 5);
            expect_ticks(n0, e1, k, 3, "T7 first tick at E0+P, then every P");
        end

        //==========================================================
        // T8: new one-shot, mode switch, PERIOD change while running
        //==========================================================
        wr(IDX_PERIOD, 32'd50);
        n0 = n_irq;
        wr(IDX_CTRL, 32'h1); e1 = last_wr_edge;      // ENABLE, one-shot
        idle(500);
        expect_ticks(n0, e1, 50, 1, "T8 new one-shot: one tick at E0+PERIOD");
        rd(IDX_CTRL, v); check_eq(v, 32'h0, "T8 one-shot clears ENABLE");

        wr(IDX_PERIOD, 32'd100);
        n0 = n_irq;
        wr(IDX_CTRL, 32'h3); e1 = last_wr_edge;
        wait_edge(e1 + 250);
        wr(IDX_CTRL, 32'h1);                         // periodic -> one-shot, phase kept
        idle(1000);
        expect_ticks(n0, e1, 100, 3, "T8 periodic -> one-shot: finishes current period, stops");
        rd(IDX_CTRL, v); check_eq(v, 32'h0, "T8 periodic -> one-shot: ENABLE cleared");

        n0 = n_irq;
        wr(IDX_CTRL, 32'h1); e1 = last_wr_edge;      // one-shot ...
        wait_edge(e1 + 50);
        wr(IDX_CTRL, 32'h3);                         // ... -> periodic before it fires
        wait_edge(e1 + 400 + 5);
        expect_ticks(n0, e1, 100, 4, "T8 one-shot -> periodic: keeps running");
        wr(IDX_CTRL, 32'h0);

        // one-shot -> periodic written exactly on the tick edge: new mode wins
        n0 = n_irq;
        wr(IDX_CTRL, 32'h1); e1 = last_wr_edge;
        wr_at(IDX_CTRL, 32'h3, e1 + 100);
        wait_edge(e1 + 300 + 5);
        expect_ticks(n0, e1, 100, 3, "T8 mode write on tick edge: new mode applies");
        wr(IDX_CTRL, 32'h0);

        // PERIOD shortened while running
        wr(IDX_PERIOD, 32'd100);
        n0 = n_irq;
        wr(IDX_CTRL, 32'h3); e1 = last_wr_edge;
        wr_at(IDX_PERIOD, 32'd50, e1 + 30);          // elapsed 30 < 50: tick at E0+50
        wait_edge(e1 + 160);
        expect_ticks(n0, e1, 50, 3, "T8 PERIOD 100 -> 50 at elapsed 30");
        n0 = n_irq;
        wr_at(IDX_PERIOD, 32'd20, e1 + 190);         // elapsed 40 >= 20: tick next edge
        wait_edge(e1 + 260);
        check_eq(n_irq - n0, 4, "T8 PERIOD 50 -> 20 at elapsed 40: ticks");
        check_eq(irq_t[n0], e1 + 191, "T8 PERIOD shortened below elapsed: tick on next edge");
        check_eq(irq_t[n0 + 1], e1 + 211, "T8 then every new PERIOD");
        wr(IDX_CTRL, 32'h0);
        idle(5);

        //==========================================================
        // T9: random accesses + resets, checked every cycle vs models
        //==========================================================
        width_check = 1'b0;                          // legacy and periodic may overlap here
        for (i = 0; i < 6000; i = i + 1) begin
            r_op = $random(seed) & 15;
            k = $random(seed) & 7;
            case (r_op)
                0, 1:    wr(IDX_PERIOD, (k == 0) ? 0 : (k == 1) ? 1 : (k == 7) ? 37 : k + 1);
                2, 3, 4: wr(IDX_CTRL, ($random(seed) & 32'hFFFF_FFF0) | (k & 3));
                5:       wr(IDX_LEGACY, k * 3);
                6:       wr(IDX_TICK, $random(seed));        // RO: ignored
                7, 8:    rd(IDX_TICK, v);
                9:       rd(IDX_CTRL, v);
                10:      rd(IDX_PERIOD, v);
                11:      rd((k < 4) ? IDX_LEGACY : 4'd8, v);
                12:      if (k == 0) begin
                             @(posedge clk); #3 rst_n = 1'b0;
                             idle(2);
                             rst_n = 1'b1;
                         end
                default: idle(k + 1);
            endcase
        end
        width_check = 1'b1;
        idle(50);

        $display("INFO compared irq every cycle against legacy reference + periodic model: %0d cycles, %0d mismatches, %0d IRQ pulses",
                 cmp_cycles, cmp_err, n_irq);
        check_eq(cmp_err, 0, "cycle-by-cycle irq comparison");
        $display("Checks: %0d, errors: %0d", checks, errors);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

    initial begin
        #50_000_000;                                 // 5 ms watchdog
        $display("ERROR watchdog timeout");
        $display("TEST FAILED (timeout)");
        $finish;
    end

endmodule

//======================================================================
// timer_legacy_ref : rtl/Peripherals/timer.v at commit f748661 (before the
// PERIODIC mode), verbatim except for the module name. Golden reference for
// LEGACY behaviour. Do not edit.
//======================================================================
module timer_legacy_ref #(

    parameter WIDTH = `DATA_WIDTH

)(

    input  wire                 clk,
    input  wire                 rst_n,

    //---------------------------------------------------------
    // AXI-Lite Interface
    //---------------------------------------------------------

    input  wire                 wr_en,
    input  wire                 rd_en,
    input  wire [WIDTH-1:0]     wdata,

    output reg  [WIDTH-1:0]     rdata,

    //---------------------------------------------------------
    // Timer Interrupt
    //---------------------------------------------------------

    output reg                  irq

);

    //---------------------------------------------------------
    // Timer Registers
    //---------------------------------------------------------

    reg [WIDTH-1:0] timer_count;
    reg [WIDTH-1:0] timer_compare;
    reg             timer_enable;

    //---------------------------------------------------------
    // Write Logic
    //---------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            timer_compare <= {WIDTH{1'b0}};
            timer_enable  <= 1'b0;

        end

        else begin

            if (wr_en) begin

                timer_compare <= wdata;
                timer_enable  <= 1'b1;


            end

            else if (timer_enable &&
              (timer_count >= timer_compare)) begin

                timer_enable <= 1'b0;

            end

        end

    end

    //---------------------------------------------------------
    // Counter Logic
    //---------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n)

            timer_count <= {WIDTH{1'b0}};

        else if (timer_enable)

            timer_count <= timer_count + 1'b1;

        else

            timer_count <= {WIDTH{1'b0}};

    end

    //---------------------------------------------------------
    // Interrupt Logic
    //---------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin

     if (!rst_n)

         irq <= 1'b0;

     else if (timer_enable &&
              (timer_count >= timer_compare))

         irq <= 1'b1;

     else

         irq <= 1'b0;

    end

//---------------------------------------------------------
// Read Logic
//---------------------------------------------------------

always @(posedge clk or negedge rst_n) begin

    if (!rst_n)

        rdata <= {WIDTH{1'b0}};

    else if (rd_en)

        rdata <= timer_count;

end



endmodule
