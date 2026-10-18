`timescale 1ns/1ps

//======================================================================
// tb_fir11_wrapper : testbench tự kiểm cho fir11_wrapper + FIR11 HLS thật
//======================================================================
// Kết quả chạy: docs/RTL_FIX_VERIFICATION.md. Chỉ kiểm khối bọc + IP, không có CPU,
// không dùng program.mem. Kiểm chương trình CPU là việc riêng (cần sw/).
//
// Mô hình bus giống axi_interconnect:
//   ghi : wr_en 1 chu kỳ (bus_write)
//   đọc : rd_en 1 chu kỳ, lấy rdata ở chu kỳ sau (bus_read)
// Mô hình tham chiếu: phép tính RTL modulo 2^32,
//   c = {54,0,-92,0,313,500,313,0,-92,0,54}, hist[0] = mẫu mới nhất.
//
// Nhóm kiểm tra:
//   T1  giá trị sau reset, offset không map
//   T2  chuỗi mẫu liên tiếp (xung đơn vị, số âm, số lớn gây tràn)
//   T3  một DATA_IN -> đúng một lần IP chạy, một ap_done, không chạy lặp
//   T4  ghi DATA_IN khi bận: bỏ qua, overrun, x không đổi
//   T5  xóa done bằng CTRL bit0; DATA_OUT vẫn giữ kết quả
//   T6  đọc DATA_OUT lặp lại: không tạo cạnh IRQ mới
//   T7  hoàn tất trùng chu kỳ với xóa (CTRL bit0 / đọc DATA_OUT): done thắng
//   T8  reset mềm khi rảnh: lịch sử FIR giữ nguyên (hành vi đọc từ RTL HLS)
//   T9  reset mềm khi đang chạy / đúng chu kỳ ap_done: không IRQ còn sót
//   T10 sau reset mềm giữa chừng: nạp 11 mẫu mới rồi đối chiếu lại
//
// Chạy (từ thư mục dự án, xem rtl/Peripherals/FIR11/README.md):
//   bash scripts/prep_fir11_dat.sh sim_fir11 && cd sim_fir11
//   bash ~/.claude/skills/soc-design/scripts/qsim.sh all --top tb_fir11_wrapper \
//        ../rtl/Peripherals/fir11_wrapper.v ../rtl/Peripherals/FIR11/*.v ../tb/tb_fir11_wrapper.v
//   (vsim đọc .dat theo thư mục làm việc hiện tại, nên phải cd vào sim_fir11)
//======================================================================

module tb_fir11_wrapper;

    localparam [31:0] A_DATA_IN  = 32'h0000_0200;
    localparam [31:0] A_DATA_OUT = 32'h0000_0204;
    localparam [31:0] A_STATUS   = 32'h0000_0208;
    localparam [31:0] A_CTRL     = 32'h0000_020C;
    localparam [31:0] A_CYC_CNT  = 32'h0000_0210;
    localparam [31:0] A_UNMAPPED = 32'h0000_0214;

    localparam [31:0] ST_DONE    = 32'h01;
    localparam [31:0] ST_IDLE    = 32'h02;
    localparam [31:0] ST_READY   = 32'h04;
    localparam [31:0] ST_BUSY    = 32'h08;
    localparam [31:0] ST_OVERRUN = 32'h10;

    localparam TAPS       = 11;
    localparam CLK_PERIOD = 10;

    //------------------------------------------------------------
    // DUT
    //------------------------------------------------------------

    reg         clk;
    reg         rst_n;
    reg         wr_en;
    reg         rd_en;
    reg  [31:0] wr_addr;
    reg  [31:0] rd_addr;
    reg  [31:0] wdata;
    wire [31:0] rdata;
    wire        irq;

    fir11_wrapper dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (wr_en),
        .rd_en   (rd_en),
        .wr_addr (wr_addr),
        .rd_addr (rd_addr),
        .wdata   (wdata),
        .rdata   (rdata),
        .irq     (irq)
    );

    initial clk = 1'b0;
    always #(CLK_PERIOD/2) clk = ~clk;

    //------------------------------------------------------------
    // Scoreboard helpers
    //------------------------------------------------------------

    integer errors;
    integer checks;

    task check_eq;
        input [31:0]  got;
        input [31:0]  exp;
        input [255:0] what;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("[%0t] ERROR %0s: got 0x%08h, exp 0x%08h", $time, what, got, exp);
            end
        end
    endtask

    //------------------------------------------------------------
    // Monitors (hierarchical refs into the real HLS IP)
    //------------------------------------------------------------

    integer n_accept;      // DATA_IN accepted by the wrapper
    integer n_ip_start;    // IP leaves state1 with ap_start=1
    integer n_ip_done;     // ap_done=1 seen while ap_rst=0
    integer n_irq_rise;
    integer busy_cycles;   // (edge seeing ap_done - edge accepting DATA_IN) / period
    time    t_accept;
    reg     irq_d;

    always @(posedge clk) begin
        if (!rst_n) begin
            irq_d <= 1'b0;
        end else begin
            irq_d <= irq;
            if (dut.accept)
                n_accept = n_accept + 1;
            if (!dut.ap_rst && dut.ap_start && dut.u_fir11.ap_CS_fsm_state1)
                n_ip_start = n_ip_start + 1;
            if (!dut.ap_rst && dut.ap_done)
                n_ip_done = n_ip_done + 1;
            if (irq && !irq_d)
                n_irq_rise = n_irq_rise + 1;
            if (dut.accept)
                t_accept = $time;
            if (dut.busy_q && dut.ap_done && !dut.ap_rst)
                busy_cycles = ($time - t_accept) / CLK_PERIOD;
        end
    end

    //------------------------------------------------------------
    // Bus model (same timing as axi_interconnect)
    //------------------------------------------------------------

    task bus_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            wr_en   = 1'b1;
            wr_addr = addr;
            wdata   = data;
            @(negedge clk);
            wr_en   = 1'b0;
        end
    endtask

    task bus_read;
        input  [31:0] addr;
        output [31:0] data;
        begin
            @(negedge clk);
            rd_en   = 1'b1;           // READ_DATA
            rd_addr = addr;
            @(negedge clk);
            rd_en   = 1'b0;           // snapshot is now registered
            data    = rdata;
            @(negedge clk);           // READ_RESP: interconnect samples snapshot
        end
    endtask

    task wait_irq;
        input integer max_cycles;
        integer k;
        begin
            k = 0;
            while (!irq && k < max_cycles) begin
                @(negedge clk);       // observe IRQ and posedge monitor settled
                k = k + 1;
            end
            // IRQ is assigned by NBA at completion. The edge monitor sees
            // that new level on the following posedge; settle it before callers
            // take n_irq_rise as the baseline for checking later read effects.
            @(negedge clk);
            checks = checks + 1;
            if (!irq) begin
                errors = errors + 1;
                $display("[%0t] ERROR irq timeout after %0d cycles", $time, max_cycles);
            end
        end
    endtask

    task idle_cycles;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1)
                @(posedge clk);
        end
    endtask

    //------------------------------------------------------------
    // Reference model (fir.cpp)
    //------------------------------------------------------------

    integer hist [0:TAPS-1];
    integer coef [0:TAPS-1];

    function [31:0] model_peek;   // y if x were pushed now (no state change)
        input [31:0] x;
        integer i;
        integer acc;
        begin
            acc = x * coef[0];
            for (i = TAPS - 1; i >= 1; i = i - 1)
                acc = acc + hist[i-1] * coef[i];
            model_peek = acc;
        end
    endfunction

    task model_push;
        input [31:0] x;
        integer i;
        begin
            for (i = TAPS - 1; i >= 1; i = i - 1)
                hist[i] = hist[i-1];
            hist[0] = x;
        end
    endtask

    // one full transaction: write, wait irq, read DATA_OUT, compare
    task run_sample;
        input [31:0]  x;
        input         do_check;
        reg   [31:0]  exp_y;
        reg   [31:0]  got;
        integer       acc0, start0, done0;
        begin
            exp_y  = model_peek(x);
            acc0   = n_accept;
            start0 = n_ip_start;
            done0  = n_ip_done;
            bus_write(A_DATA_IN, x);
            check_eq(n_accept - acc0, 1, "accept count");
            wait_irq(200);
            idle_cycles(30);          // let a hypothetical re-run show up
            check_eq(n_ip_start - start0, 1, "IP start count per DATA_IN");
            check_eq(n_ip_done  - done0,  1, "ap_done count per DATA_IN");
            check_eq(dut.ap_start, 1'b0, "ap_start low after done");
            bus_read(A_CYC_CNT, got);
            check_eq(got, busy_cycles, "CYC_CNT vs TB busy cycles");
            bus_read(A_DATA_OUT, got);
            if (do_check)
                check_eq(got, exp_y, "DATA_OUT vs fir.cpp model");
            check_eq(irq, 1'b0, "irq cleared by DATA_OUT read");
            model_push(x);
        end
    endtask

    //------------------------------------------------------------
    // Test sequence
    //------------------------------------------------------------

    reg [31:0] r;
    reg [31:0] cyc_first;
    reg [31:0] y_before;
    integer    i;
    integer    irq0;
    integer    done0;

    initial begin : watchdog
        #2_000_000;
        $display("TEST FAILED: watchdog timeout");
        $finish;
    end

    initial begin
        errors = 0; checks = 0;
        n_accept = 0; n_ip_start = 0; n_ip_done = 0; n_irq_rise = 0; busy_cycles = 0; t_accept = 0;
        wr_en = 1'b0; rd_en = 1'b0; wr_addr = 32'd0; rd_addr = 32'd0; wdata = 32'd0;
        coef[0] = 54;  coef[1] = 0; coef[2] = -92; coef[3] = 0; coef[4] = 313;
        coef[5] = 500; coef[6] = 313; coef[7] = 0; coef[8] = -92; coef[9] = 0; coef[10] = 54;
        for (i = 0; i < TAPS; i = i + 1)
            hist[i] = 0;

        rst_n = 1'b0;
        idle_cycles(5);

        // .dat must be in the simulator working directory
        for (i = 0; i < TAPS; i = i + 1)
            check_eq(dut.u_fir11.grp_fir_Pipeline_Shift_Accum_Loop_fu_55.fir_int_int_c_U.rom0[i],
                     coef[i], "ROM coefficient (.dat loaded?)");
        if (errors != 0) begin
            $display("TEST FAILED: ROM .dat not loaded, run scripts/prep_fir11_dat.sh <sim dir>");
            $finish;
        end

        @(negedge clk);
        rst_n = 1'b1;
        idle_cycles(3);

        //---------------- T1 reset values ----------------
        $display("[%0t] T1 reset values", $time);
        bus_read(A_STATUS,   r); check_eq(r, ST_IDLE, "STATUS after reset");
        bus_read(A_DATA_OUT, r); check_eq(r, 32'd0,   "DATA_OUT after reset");
        bus_read(A_CYC_CNT,  r); check_eq(r, 32'd0,   "CYC_CNT after reset");
        bus_read(A_DATA_IN,  r); check_eq(r, 32'd0,   "DATA_IN reads 0");
        bus_read(A_CTRL,     r); check_eq(r, 32'd0,   "CTRL reads 0");
        bus_write(A_UNMAPPED, 32'hFFFF_FFFF);
        bus_read(A_UNMAPPED, r); check_eq(r, 32'd0,   "unmapped reads 0");
        bus_write(A_STATUS, 32'hFFFF_FFFF);           // RO: ignored
        bus_read(A_STATUS,   r); check_eq(r, ST_IDLE, "STATUS write ignored");
        check_eq(n_accept, 0, "no accept from non-DATA_IN writes");
        check_eq(irq, 1'b0, "irq low after reset");

        //---------------- T2/T3 consecutive samples ----------------
        $display("[%0t] T2/T3 consecutive samples", $time);
        run_sample(32'd1, 1'b1);                      // impulse -> c[0..10]
        bus_read(A_CYC_CNT, cyc_first);
        $display("[%0t] INFO CYC_CNT (DATA_IN accept -> ap_done) = %0d cycles (csynth latency 18)",
                 $time, cyc_first);
        for (i = 0; i < TAPS + 1; i = i + 1)
            run_sample(32'd0, 1'b1);
        run_sample(32'd100, 1'b1);
        run_sample(-32'sd250, 1'b1);
        run_sample(32'h7FFF_FFFF, 1'b1);              // RTL 32-bit wrap
        run_sample(32'h8000_0000, 1'b1);
        run_sample(32'h1234_5678, 1'b1);
        for (i = 0; i < 20; i = i + 1)
            run_sample((i * 37 - 300), 1'b1);
        bus_read(A_CYC_CNT, r);
        check_eq(r, cyc_first, "CYC_CNT constant across runs");

        //---------------- T4 write while busy ----------------
        $display("[%0t] T4 DATA_IN while busy", $time);
        bus_write(A_DATA_IN, 32'd7);
        bus_write(A_DATA_IN, 32'd9999);               // must be dropped
        check_eq(dut.x_q, 32'd7, "x held while busy");
        bus_read(A_STATUS, r);
        check_eq(r & (ST_BUSY | ST_OVERRUN), ST_BUSY | ST_OVERRUN, "STATUS busy+overrun");
        wait_irq(200);
        idle_cycles(30);
        bus_read(A_DATA_OUT, r);
        check_eq(r, model_peek(32'd7), "result uses first sample only");
        model_push(32'd7);
        bus_read(A_STATUS, r);
        check_eq(r & ST_OVERRUN, ST_OVERRUN, "overrun sticky after done");
        bus_write(A_CTRL, 32'h1);
        bus_read(A_STATUS, r);
        check_eq(r, ST_IDLE, "CTRL bit0 clears overrun");
        check_eq(n_accept, n_ip_start, "accepts == IP starts");
        check_eq(n_ip_start, n_ip_done, "IP starts == IP dones");

        //---------------- T5 CTRL clear keeps DATA_OUT ----------------
        $display("[%0t] T5 CTRL bit0 clears done", $time);
        bus_write(A_DATA_IN, 32'd55);
        wait_irq(200);
        bus_write(A_CTRL, 32'h1);
        check_eq(irq, 1'b0, "irq cleared by CTRL bit0");
        bus_read(A_STATUS, r);
        check_eq(r & ST_DONE, 32'd0, "STATUS.done cleared by CTRL");
        bus_read(A_DATA_OUT, r);
        check_eq(r, model_peek(32'd55), "DATA_OUT kept after CTRL clear");
        model_push(32'd55);

        //---------------- T6 repeated DATA_OUT reads ----------------
        $display("[%0t] T6 repeated DATA_OUT reads", $time);
        bus_write(A_DATA_IN, 32'd3);
        wait_irq(200);
        irq0 = n_irq_rise;
        bus_read(A_DATA_OUT, y_before);
        check_eq(y_before, model_peek(32'd3), "DATA_OUT first read");
        model_push(32'd3);
        bus_read(A_DATA_OUT, r);
        check_eq(r, y_before, "DATA_OUT second read same value");
        bus_read(A_STATUS, r);
        check_eq(r, ST_IDLE, "STATUS clean after repeated reads");
        check_eq(n_irq_rise, irq0, "no extra irq edge from reads");

        //---------------- T7 done vs clear in same cycle ----------------
        $display("[%0t] T7 completion coincides with clear", $time);
        // T7a: CTRL bit0 write in the ap_done cycle
        wr_addr = A_CTRL; wdata = 32'h1;
        bus_write_at_done_start(32'd11);
        idle_cycles(2);
        check_eq(irq, 1'b1, "done wins over CTRL clear");
        bus_read(A_DATA_OUT, r);
        check_eq(r, model_peek(32'd11), "DATA_OUT after T7a");
        model_push(32'd11);
        check_eq(irq, 1'b0, "irq cleared after T7a read");

        // T7b: read snapshots old y while completion latches new y.
        // Completion wins the clear: DONE must survive for the new result.
        bus_read(A_DATA_OUT, y_before);
        bus_write(A_DATA_IN, 32'd12);
        wait_ap_done_negedge;
        rd_en = 1'b1; rd_addr = A_DATA_OUT;           // READ_DATA aligned with ap_done
        @(negedge clk);
        rd_en = 1'b0;
        r = rdata;
        check_eq(r, y_before, "coincident read snapshots previous y");
        check_eq(irq, 1'b1, "new done survives coincident result read");
        bus_read(A_DATA_OUT, r);
        check_eq(r, model_peek(32'd12), "next read returns new result");
        check_eq(irq, 1'b0, "new result read clears done");
        model_push(32'd12);

        //---------------- T8 soft reset while idle ----------------
        $display("[%0t] T8 soft reset while idle", $time);
        bus_write(A_CTRL, 32'h2);
        idle_cycles(3);
        bus_read(A_STATUS, r);
        check_eq(r, ST_IDLE, "STATUS after idle soft reset");
        // history in shift_reg RAM is not cleared by ap_rst (read from RTL)
        run_sample(32'd5, 1'b1);
        run_sample(32'd6, 1'b1);

        //---------------- T9 soft reset during run ----------------
        $display("[%0t] T9 soft reset during run", $time);
        bus_read(A_DATA_OUT, y_before);
        done0 = n_ip_done;
        irq0  = n_irq_rise;
        bus_write(A_DATA_IN, 32'd1000);
        idle_cycles(4);
        bus_write(A_CTRL, 32'h2);
        idle_cycles(60);
        check_eq(irq, 1'b0, "no irq after mid-run soft reset");
        check_eq(n_irq_rise, irq0, "no irq edge after mid-run soft reset");
        check_eq(n_ip_done, done0, "no ap_done after mid-run soft reset");
        bus_read(A_STATUS, r);
        check_eq(r, ST_IDLE, "STATUS after mid-run soft reset");
        bus_read(A_DATA_OUT, r);
        check_eq(r, y_before, "DATA_OUT unchanged by aborted run");

        // T9b: soft reset written exactly in the ap_done cycle
        irq0 = n_irq_rise;
        wr_addr = A_CTRL; wdata = 32'h2;
        bus_write_at_done_start(32'd2000);
        idle_cycles(20);
        check_eq(irq, 1'b0, "soft reset wins over coincident ap_done");
        check_eq(n_irq_rise, irq0, "no irq edge from aborted completion");
        bus_read(A_DATA_OUT, r);
        check_eq(r, y_before, "DATA_OUT unchanged by aborted completion");
        bus_read(A_STATUS, r);
        check_eq(r, ST_IDLE, "STATUS after soft reset at ap_done");

        //---------------- T10 re-sync after abort ----------------
        // shift_reg may be partially shifted by the abort: push 11 fresh
        // samples (unchecked), then the window is fully known again.
        $display("[%0t] T10 resync after abort", $time);
        for (i = 0; i < TAPS; i = i + 1)
            run_sample(i * 11 + 1, 1'b0);
        run_sample(32'd77, 1'b1);
        run_sample(-32'sd78, 1'b1);
        run_sample(32'd79, 1'b1);

        check_eq(n_accept, n_ip_start, "total accepts == IP starts");

        //---------------- summary ----------------
        idle_cycles(5);
        $display("Checks: %0d, errors: %0d", checks, errors);
        if (errors == 0)
            $display("TEST PASSED");
        else
            $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

    //------------------------------------------------------------
    // Helpers for cycle-aligned races (T7, T9b)
    //------------------------------------------------------------

    task wait_ap_done_negedge;
        integer k;
        begin
            k = 0;
            @(negedge clk);
            while (!dut.ap_done && k < 200) begin
                @(negedge clk);
                k = k + 1;
            end
            if (!dut.ap_done) begin
                errors = errors + 1;
                $display("[%0t] ERROR ap_done never seen", $time);
            end
        end
    endtask

    // Start a run with x, then drive the write held in wr_addr/wdata
    // (set by the caller before the call) in the ap_done cycle.
    task bus_write_at_done_start;
        input [31:0] x;
        reg   [31:0] a, d;
        begin
            a = wr_addr; d = wdata;
            bus_write(A_DATA_IN, x);
            wait_ap_done_negedge;
            wr_en = 1'b1; wr_addr = a; wdata = d;
            @(negedge clk);
            wr_en = 1'b0;
        end
    endtask

endmodule
