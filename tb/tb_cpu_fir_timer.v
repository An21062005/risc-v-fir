`timescale 1ns/1ps

//======================================================================
// tb_cpu_fir_timer : Timer IRQ điều phối 32 mẫu FIR11 HLS, FIR IRQ báo kết quả
//======================================================================
// Firmware: firmware/fir_timer.c + startup_irq.S + linker_irq.ld
//   build_firmware.py --firmware fir_timer        (PERIOD = 10000, STRESS = 0)
//                     --firmware fir_timer_stress (PERIOD = 100,   STRESS = 1: cố ý quá tải)
// SoC: soc_top cấu hình A mặc định (CPU + AXI + Timer + IRQ + FIR11), clock 100 MHz.
// symbols.mem: fst, fir_input, fir_output, __stack_limit, __stack_top, __trap_entry,
//   __trap_mret, __isr_end, __regtest_loop, __regtest_exit.
//
// Kiểm chứng độc lập từ tín hiệu RTL (firmware chỉ là nguồn phụ):
//   Timer   : tick đầu đúng PERIOD clock sau cạnh bật, mọi khoảng cách = PERIOD, xung 1 chu kỳ,
//             TICK_COUNT == số tick quan sát, không tick sau khi tắt; thường: đúng 32 tick.
//   ISR     : mỗi lần vào ISR (irq_take -> mret) đọc STATUS đúng 1 lần và ghi ACK đúng 1 lần với
//             đúng giá trị STATUS đó; xung ack của controller xóa nguồn đang pending; Timer ISR /
//             FIR ISR == số sự kiện pending mới của từng nguồn (không mất IRQ, không ISR giả);
//             mret ở __trap_mret, quay về đúng mepc; register file (26 thanh ghi, gồm t3) đúng
//             sau mỗi lần quay về vòng lặp chính.
//   FIR     : 10 mẫu flush = 0 trước khi bật Timer; 32 mẫu được wrapper NHẬN (accept) đúng thứ tự
//             fir_input[0..31], không thiếu / trùng; mẫu i nhận sau tick i+1; không ghi DATA_IN khi
//             BUSY, không OVERRUN; DATA_IN chỉ từ ISR. DATA_OUT == y của HLS == mô hình Verilog
//             độc lập; fir_output[i] trong DMEM ghi đúng 1 lần, bằng mô hình tính từ fir_input
//             (32/32 bit-exact).
//   Thời gian: tick -> CPU vào ISR -> accept DATA_IN -> FIR xong -> đọc DATA_OUT -> lưu DMEM,
//             đo trên giao dịch thật; độ trễ tick -> accept, jitter, khoảng cách accept.
//   Hạn chót: mẫu i trễ nếu lúc firmware kiểm (đọc TICK_COUNT trong FIR ISR) đã có > i+1 tick;
//             đếm độc lập + so với fst.missed. Tick gộp (đến khi pending Timer còn 1) so với
//             fst.coalesced. Backlog. Thường: 0 trễ, 0 gộp, backlog 1. STRESS: phải có trễ, tick
//             gộp và Timer+FIR cùng pending, nhưng kết quả vẫn 32/32 đúng thứ tự.
//
// Chạy: python scripts/run_rtl_tests.py --vivado-root <Vivado> --tests tb_cpu_fir_timer tb_cpu_fir_timer_stress
//======================================================================

module tb_cpu_fir_timer;

    parameter PERIOD = 10000;                    // phải khớp FIR_TIMER_PERIOD của firmware
    parameter STRESS = 0;

    localparam N           = 32;
    localparam NUM_FLUSH   = 10;
    localparam TAPS        = 11;
    localparam MAX_CYCLES  = 600000;
    localparam TXN_TIMEOUT = 300;
    localparam MAX_ERR_MSG = 20;
    localparam MAX_LOG     = 128;

    localparam [31:0] HALT_MAGIC  = 32'h4841_4C54;
    localparam [31:0] MRET        = 32'h3020_0073;
    localparam [31:0] TRAP_VECTOR = 32'h0000_0010;
    localparam [31:0] DMEM_BASE   = 32'h1000_0000;
    localparam [31:0] DMEM_END    = 32'h1000_0400;
    localparam [31:0] IMEM_END    = 32'h0000_0400;

    // bus addresses (CPU address - 0x4000_0000)
    localparam [31:0] A_PERIOD   = 32'h084, A_CTRL     = 32'h088, A_TICK     = 32'h08C;
    localparam [31:0] A_INT_EN   = 32'h1C0, A_INT_ACK  = 32'h1C8, A_INT_STAT = 32'h1CC;
    localparam [31:0] A_DIN      = 32'h200, A_DOUT     = 32'h204, A_FSTAT    = 32'h208, A_FCTRL = 32'h20C;

    // fst offsets (fir_timer.c fir_state_t)
    localparam F_TICKS = 0, F_SENT = 1, F_DONE = 2, F_MISSED = 3, F_BACKLOG = 4, F_COAL = 5, F_SPUR = 6;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    wire cpu_irq;
    always #5 clk = ~clk;                        // 100 MHz

    soc_top dut (.clk(clk), .rst_n(rst_n), .cpu_irq(cpu_irq));

    //------------------------------------------------------------
    // Symbols
    //------------------------------------------------------------
    reg [31:0] sym [0:9];
    reg [31:0] S_FST, S_IN, S_OUT, S_STACK_LIMIT, S_STACK_TOP, S_TRAP, S_MRET, S_ISR_END, S_LOOP, S_EXIT;

    function [31:0] dmem;
        input [31:0] a;
        begin dmem = dut.u_cpu.DMEM.memory[a[9:2]]; end
    endfunction

    //------------------------------------------------------------
    // Errors
    //------------------------------------------------------------
    integer errors = 0, checks = 0, msgs = 0, cyc = 0;

    task fail;
        input [8*100-1:0] what;
        input [31:0]      a;
        input [31:0]      b;
        begin
            errors = errors + 1;
            msgs = msgs + 1;
            if (msgs <= MAX_ERR_MSG)
                $display("ERROR [cycle %0d] %0s (0x%08h, 0x%08h)", cyc, what, a, b);
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
                $display("ERROR %0s: got %0d (0x%08h), exp %0d (0x%08h)", what, got, got, exp, exp);
            end
        end
    endtask

    task check_true;
        input             cond;
        input [8*100-1:0] what;
        begin
            checks = checks + 1;
            if (cond !== 1'b1) begin
                errors = errors + 1;
                $display("ERROR %0s", what);
            end
        end
    endtask

    function supported;                          // same as scripts/build_firmware.py
        input [31:0] w;
        reg [6:0] op; reg [2:0] f3; reg [6:0] f7;
        begin
            op = w[6:0]; f3 = w[14:12]; f7 = w[31:25];
            case (op)
                7'b0110111, 7'b0010111, 7'b1101111: supported = 1'b1;
                7'b1100111: supported = (f3 == 3'b000);
                7'b1100011: supported = (f3 == 3'b000) || (f3 == 3'b001) ||
                                        (f3 == 3'b100) || (f3 == 3'b101);
                7'b0000011, 7'b0100011: supported = (f3 == 3'b010);
                7'b0010011: supported = (f3 == 3'b001) ? (f7 == 7'h00) :
                                        (f3 == 3'b101) ? (f7 == 7'h00 || f7 == 7'h20) :
                                        (f3 != 3'b011);
                7'b0110011: supported = (f7 == 7'h00 && f3 != 3'b011) ||
                                        (f7 == 7'h20 && (f3 == 3'b000 || f3 == 3'b101));
                default:    supported = 1'b0;
            endcase
        end
    endfunction

    function in_isr;
        input [31:0] pc;
        begin in_isr = (pc >= S_TRAP) && (pc < S_ISR_END); end
    endfunction

    function [31:0] pattern;                     // startup_irq.S PAT
        input integer n;
        begin pattern = 32'hFFFF_F800 | (n << 5) | n; end
    endfunction

    //------------------------------------------------------------
    // Independent FIR model (Verilog): y = sum c[k] x[n-k], modulo 2^32
    //------------------------------------------------------------
    integer    coef [0:TAPS-1];
    integer    hist [0:TAPS-1];
    reg [31:0] coef_rom [0:TAPS-1];
    reg [31:0] hist_dat [0:TAPS-1];
    integer    mj;

    function [31:0] model_push;
        input [31:0] x;
        reg   [31:0] acc;
        begin
            for (mj = TAPS - 1; mj > 0; mj = mj - 1) hist[mj] = hist[mj-1];
            hist[0] = x;
            acc = 32'd0;
            for (mj = 0; mj < TAPS; mj = mj + 1) acc = acc + coef[mj] * hist[mj];
            model_push = acc;
        end
    endfunction

    //------------------------------------------------------------
    // Register-file check
    //------------------------------------------------------------
    integer reg_checks = 0, reg_errors = 0, rn;
    reg [31:0] rexp;

    task check_regs;
        input [8*40-1:0] where;
        begin
            reg_checks = reg_checks + 1;
            for (rn = 1; rn < 32; rn = rn + 1) begin
                if (rn != 2 && rn != 3 && rn != 4 && rn != 10 && rn != 13) begin
                    rexp = (rn == 12) ? 32'h4001_0000 : (rn == 14) ? 32'h4000_0000 : pattern(rn);
                    if (dut.u_cpu.RF.registers[rn] !== rexp) begin
                        reg_errors = reg_errors + 1;
                        fail("register corrupted (reg, value)", rn, dut.u_cpu.RF.registers[rn]);
                        if (msgs <= MAX_ERR_MSG) $display("      at %0s, expected 0x%08h", where, rexp);
                    end
                end
            end
        end
    endtask

    //------------------------------------------------------------
    // Monitor state
    //------------------------------------------------------------
    // Timer
    integer tick_n = 0, en_edge = -1, dis_edge = -1, first_gap = -1, last_tick = -1;
    integer gap_min = 32'h7fffffff, gap_max = 0, gap_bad = 0, tick_after_dis = 0, tick_cnt_err = 0;
    integer tick_t [0:MAX_LOG-1];
    integer take_after_tick [0:MAX_LOG-1];
    integer next_tick_take = 0;
    reg     prev_tirq = 1'b0;
    // interrupt controller
    integer tim_events = 0, fir_events = 0, tim_coal = 0, both_pending = 0, ack_n = 0, ack_bad = 0;
    // ISR bookkeeping
    integer take_n = 0, mret_n = 0, ret_n = 0, ret_loop_n = 0, isr_tim = 0, isr_fir = 0, isr_other = 0;
    integer isr_stat_n = 0, isr_ack_n = 0, isr_dout_n = 0, isr_bad = 0, isr_seq_bad = 0, isr_dl_done = 0;
    reg [31:0] isr_stat_val;
    reg        isr_open = 1'b0, chk_vec = 1'b0, chk_ret = 1'b0;
    reg [31:0] exp_mepc, ret_target;
    integer    reg_chk_at = -1, exit_checked = 0;
    // FIR / samples
    integer accept_n = 0, finish_n = 0, dout_rd_n = 0, store_n = 0;
    integer busy_wr = 0, overrun_seen = 0, flush_bad = 0, order_bad = 0, early_bad = 0, main_din = 0;
    integer acc_t  [0:N-1];
    integer fin_t  [0:N-1];
    integer rd_t   [0:N-1];
    integer st_t   [0:N-1];
    reg [31:0] x_acc [0:N-1];
    reg [31:0] y_hls [0:N-1];
    reg [31:0] y_rd  [0:N-1];
    reg [31:0] y_mdl [0:N-1];
    reg [31:0] x_in  [0:N-1];
    reg [31:0] y_exp [0:N-1];
    integer    st_cnt [0:N-1];
    integer    hls_y_n = 0, y_bad = 0, store_bad = 0;
    // deadlines
    integer fw_late_clock = 0, sched_ticks = 0;
    integer tb_missed = 0, late_accept = 0, tb_backlog_max = 0, stored_now = 0;
    // bus
    integer req_n = 0, req_wr_n = 0, req_rd_n = 0, resp_n = 0, req_age = 0, req_age_max = 0;
    integer aw_n = 0, b_n = 0, ar_n = 0, r_n = 0, timeouts = 0, main_bad = 0;
    reg        req_open = 1'b0, req_is_wr = 1'b0, req_isr = 1'b0;
    reg [31:0] req_addr = 32'd0, pc_mem, dw_addr;
    // CPU sanity
    integer pc_err = 0, illegal_err = 0, dmem_err = 0, sp_err = 0;
    reg     sp_valid = 1'b0;
    reg [31:0] sp_min = 32'hFFFF_FFFF;
    reg     halted = 1'b0;
    integer halt_cyc = 0, k2, idx;

    always @(posedge clk) begin
        if (dut.rst_n_sync && !halted) begin   // DUT out of reset (S1)
            cyc = cyc + 1;
            pc_mem = dut.u_cpu.ex_mem_pc_plus_4 - 32'd4;

            //====================================================
            // Timer
            //====================================================
            if (dut.timer_wr_en && dut.write_addr == A_CTRL) begin
                if (dut.write_data[0] && !dut.u_timer.ctrl_enable && en_edge < 0) en_edge = cyc;
                if (!dut.write_data[0] && dis_edge < 0) dis_edge = cyc;
            end
            if (dut.timer_irq) begin
                if (tick_n < MAX_LOG) begin tick_t[tick_n] = cyc - 1; take_after_tick[tick_n] = -1; end
                tick_n = tick_n + 1;
                if (prev_tirq) fail("Timer irq longer than one cycle", tick_n, 0);
                if (dis_edge >= 0 && cyc - 1 >= dis_edge) begin
                    tick_after_dis = tick_after_dis + 1;
                    fail("Timer tick after CTRL disable", cyc - 1, dis_edge);
                end
                if (last_tick < 0) first_gap = (cyc - 1) - en_edge;
                else begin
                    if ((cyc - 1) - last_tick < gap_min) gap_min = (cyc - 1) - last_tick;
                    if ((cyc - 1) - last_tick > gap_max) gap_max = (cyc - 1) - last_tick;
                    if ((cyc - 1) - last_tick != PERIOD) begin
                        gap_bad = gap_bad + 1;
                        fail("Timer interval != PERIOD", (cyc - 1) - last_tick, tick_n);
                    end
                end
                last_tick = cyc - 1;
                // backlog at this tick: samples due - outputs stored
                if (((tick_n < N) ? tick_n : N) - stored_now > tb_backlog_max)
                    tb_backlog_max = ((tick_n < N) ? tick_n : N) - stored_now;
            end
            prev_tirq = dut.timer_irq;
            if (dut.u_timer.tick_count !== tick_n) begin
                tick_cnt_err = tick_cnt_err + 1;
                if (tick_cnt_err <= 3) fail("TICK_COUNT != observed ticks", dut.u_timer.tick_count, tick_n);
            end

            //====================================================
            // Interrupt controller (events counted after the Timer is enabled)
            //====================================================
            if (en_edge >= 0) begin
                if (dut.u_int_ctrl.irq_rising[0]) begin
                    if (dut.irq_pending[0] && !(dut.irq_ack && dut.irq_ack_id == 0)) tim_coal = tim_coal + 1;
                    else tim_events = tim_events + 1;
                end
                if (dut.u_int_ctrl.irq_rising[1]) begin
                    if (dut.irq_pending[1] && !(dut.irq_ack && dut.irq_ack_id == 1))
                        fail("FIR DONE edge while FIR still pending (result could be lost)", fir_events, 0);
                    else fir_events = fir_events + 1;
                end
                if (dut.irq_pending == 2'b11) both_pending = both_pending + 1;
            end
            if (dut.irq_ack) begin
                ack_n = ack_n + 1;
                if (dut.irq_ack_id > 1 || !dut.irq_pending[dut.irq_ack_id[0]]) begin
                    ack_bad = ack_bad + 1;
                    fail("ACK of a source that is not pending (id, pending)", dut.irq_ack_id, dut.irq_pending);
                end
            end

            //====================================================
            // CPU: irq_take / vector / mret / return; per-ISR STATUS<->ACK pairing
            //====================================================
            if (chk_vec) begin
                chk_vec = 1'b0;
                if (dut.u_cpu.pc !== TRAP_VECTOR) fail("PC after irq_take != 0x10", dut.u_cpu.pc, 0);
                if (dut.u_cpu.mepc !== exp_mepc) fail("mepc != PC at irq_take", dut.u_cpu.mepc, exp_mepc);
            end
            if (chk_ret) begin
                chk_ret = 1'b0;
                ret_n = ret_n + 1;
                if (dut.u_cpu.pc !== ret_target) fail("PC after mret != mepc", dut.u_cpu.pc, ret_target);
            end
            if (reg_chk_at == cyc) begin
                reg_chk_at = -1;
                check_regs("return from ISR into main loop");
            end
            if (dut.u_cpu.irq_take) begin
                take_n = take_n + 1;
                if (!cpu_irq || dut.u_cpu.in_irq || dut.u_cpu.bus_stall)
                    fail("irq_take without IRQ / nested / during stall", cpu_irq, dut.u_cpu.in_irq);
                while (next_tick_take < tick_n && next_tick_take < MAX_LOG) begin
                    take_after_tick[next_tick_take] = cyc;
                    next_tick_take = next_tick_take + 1;
                end
                isr_open = 1'b1;
                isr_stat_n = 0; isr_ack_n = 0; isr_dout_n = 0; isr_dl_done = 0; isr_stat_val = 32'hxxxx_xxxx;
                exp_mepc = dut.u_cpu.pc;
                chk_vec = 1'b1;
            end
            if (dut.u_cpu.mret_take) begin
                mret_n = mret_n + 1;
                if (dut.u_cpu.if_id_pc !== S_MRET) fail("mret outside __trap_mret", dut.u_cpu.if_id_pc, S_MRET);
                if (dut.u_cpu.mepc !== exp_mepc) fail("mepc changed during ISR", dut.u_cpu.mepc, exp_mepc);
                if (isr_stat_n != 1 || isr_ack_n != 1) begin
                    isr_seq_bad = isr_seq_bad + 1;
                    fail("ISR did not read STATUS once and ACK once (reads, acks)", isr_stat_n, isr_ack_n);
                end
                if (isr_stat_val == 32'd1) isr_tim = isr_tim + 1;
                else if (isr_stat_val == 32'd3) begin
                    isr_fir = isr_fir + 1;
                    if (isr_dout_n != 1) fail("FIR ISR did not read DATA_OUT exactly once", isr_dout_n, 0);
                end else isr_other = isr_other + 1;
                isr_open = 1'b0;
                ret_target = dut.u_cpu.mepc;
                chk_ret = 1'b1;
                if (dut.u_cpu.mepc >= S_LOOP && dut.u_cpu.mepc <= S_EXIT) begin
                    ret_loop_n = ret_loop_n + 1;
                    reg_chk_at = cyc + 4;
                end
            end
            if (dut.u_cpu.id_ex_pc == S_EXIT && !exit_checked && S_EXIT != 0) begin
                exit_checked = 1;
                check_regs("main loop exit");
            end

            //====================================================
            // Bus requests, classified by the PC of the MEM-stage instruction
            //====================================================
            if ((dut.bus_rd || dut.bus_wr) && !req_open) begin
                req_open = 1'b1;
                req_is_wr = dut.bus_wr;
                req_addr = dut.bus_addr;
                req_isr = in_isr(pc_mem);
                req_age = 0;
                req_n = req_n + 1;
                if (dut.bus_wr) req_wr_n = req_wr_n + 1; else req_rd_n = req_rd_n + 1;
                if (req_isr) begin
                    if (!dut.u_cpu.in_irq || !isr_open) begin
                        isr_bad = isr_bad + 1;
                        fail("ISR code ran outside interrupt context", pc_mem, 0);
                    end
                    if (dut.bus_wr && dut.bus_addr == A_INT_ACK) begin
                        isr_ack_n = isr_ack_n + 1;
                        if (isr_stat_n != 1 || dut.bus_wdata !== isr_stat_val)
                            fail("ISR ACK value != STATUS read in this ISR (ack, status)", dut.bus_wdata, isr_stat_val);
                    end else if (dut.bus_wr && dut.bus_addr == A_DIN) begin
                        if (isr_ack_n != 1) fail("DATA_IN written before ACK in ISR", isr_ack_n, 0);
                    end else if (!dut.bus_wr && dut.bus_addr == A_DOUT) begin
                        isr_dout_n = isr_dout_n + 1;
                        if (isr_ack_n != 1 || isr_stat_val !== 32'd3)
                            fail("DATA_OUT read outside FIR ISR or before ACK", isr_stat_val, isr_ack_n);
                    end else if (!((!dut.bus_wr && dut.bus_addr == A_INT_STAT) ||
                                   (!dut.bus_wr && dut.bus_addr == A_TICK) ||
                                   (dut.bus_wr && dut.bus_addr == A_CTRL && dut.bus_wdata == 0) ||
                                   (dut.bus_wr && dut.bus_addr == A_INT_EN && dut.bus_wdata == 2))) begin
                        isr_bad = isr_bad + 1;
                        fail("unexpected ISR bus access (addr, pc)", dut.bus_addr, pc_mem);
                    end
                end else begin
                    if (dut.bus_wr && dut.bus_addr == A_DIN) begin
                        main_din = main_din + 1;
                        if (en_edge >= 0 || dut.bus_wdata !== 0)
                            fail("main wrote DATA_IN after Timer start / non-zero flush", dut.bus_wdata, pc_mem);
                    end else if (dut.bus_wr && dut.bus_addr == A_INT_ACK) begin
                        if (en_edge >= 0 || dut.bus_wdata !== 3) fail("ACK from main after start", dut.bus_wdata, pc_mem);
                    end else if (dut.bus_wr ? !((dut.bus_addr == A_FCTRL && dut.bus_wdata == 1) ||
                                                (dut.bus_addr == A_PERIOD && dut.bus_wdata == PERIOD) ||
                                                (dut.bus_addr == A_INT_EN && dut.bus_wdata == 3) ||
                                                (dut.bus_addr == A_CTRL && dut.bus_wdata == 3))
                                            : !(dut.bus_addr == A_FSTAT || dut.bus_addr == A_DOUT ||
                                                dut.bus_addr == A_TICK || dut.bus_addr == A_CTRL)) begin
                        main_bad = main_bad + 1;
                        fail("unexpected bus access from main code (addr, pc)", dut.bus_addr, pc_mem);
                    end
                    if (!dut.bus_wr && dut.bus_addr == A_DOUT && en_edge >= 0)
                        fail("main read DATA_OUT after Timer start (output stolen from ISR)", pc_mem, 0);
                end
            end
            if (req_open) begin
                req_age = req_age + 1;
                if (req_age > req_age_max) req_age_max = req_age;
                if (!(dut.bus_rd || dut.bus_wr) || dut.bus_addr !== req_addr || dut.bus_wr !== req_is_wr)
                    fail("CPU bus request changed/dropped before bus_ready", dut.bus_addr, req_addr);
                if (req_age == TXN_TIMEOUT) begin
                    timeouts = timeouts + 1;
                    fail("bus transaction timeout", req_addr, req_age);
                end
            end
            if (dut.bus_ready) begin
                if (!req_open) fail("bus_ready without request", 0, 0);
                resp_n = resp_n + 1;
                if (req_isr && !req_is_wr && req_addr == A_INT_STAT) begin
                    isr_stat_n = isr_stat_n + 1;
                    isr_stat_val = dut.bus_rdata;
                end
                // deadline check point (once per sample): first TICK_COUNT read in a FIR ISR after
                // the output store; sample stored_now-1 is late if more than stored_now ticks came
                // (value read == TICK_COUNT snapshot; TICK_COUNT == observed ticks is checked each cycle)
                if (req_isr && !req_is_wr && req_addr == A_TICK && isr_stat_val == 32'd3 && !isr_dl_done) begin
                    isr_dl_done = 1;
                    // Count independently at the peripheral snapshot edge below.
                end
                req_open = 1'b0;
            end
            if (isr_open && dut.timer_rd_en && dut.read_addr == A_TICK && isr_stat_val == 1)
                sched_ticks = (cyc - en_edge) / PERIOD;
            if (isr_open && dut.timer_rd_en && dut.read_addr == A_TICK && isr_stat_val == 3 &&
                cyc - en_edge >= (stored_now + 1) * PERIOD) fw_late_clock = fw_late_clock + 1;
            if (dut.axi_awvalid && dut.axi_awready) aw_n = aw_n + 1;
            if (dut.axi_bvalid && dut.axi_bready) begin
                b_n = b_n + 1;
                if (dut.axi_bresp !== 2'b00) fail("BRESP not OKAY", dut.axi_bresp, 0);
            end
            if (dut.axi_arvalid && dut.axi_arready) ar_n = ar_n + 1;
            if (dut.axi_rvalid && dut.axi_rready) begin
                r_n = r_n + 1;
                if (dut.axi_rresp !== 2'b00) fail("RRESP not OKAY", dut.axi_rresp, 0);
            end

            //====================================================
            // FIR wrapper / HLS: accept, finish, DATA_OUT reads
            //====================================================
            if (dut.u_fir.wr_data_in && dut.u_fir.busy_q) begin
                busy_wr = busy_wr + 1;
                fail("DATA_IN written while FIR BUSY", dut.write_data, accept_n);
            end
            if (dut.u_fir.overrun_q) overrun_seen = overrun_seen + 1;
            if (dut.u_fir.accept) begin
                if (accept_n < NUM_FLUSH) begin
                    if (dut.write_data !== 0 || en_edge >= 0) begin
                        flush_bad = flush_bad + 1;
                        fail("flush sample not 0 or after Timer start", dut.write_data, accept_n);
                    end
                    y_mdl[0] = model_push(dut.write_data);          // history; flush y not stored
                end else if (accept_n - NUM_FLUSH < N) begin
                    idx = accept_n - NUM_FLUSH;
                    acc_t[idx] = cyc;
                    x_acc[idx] = dut.write_data;
                    y_mdl[idx] = model_push(dut.write_data);
                    if (dut.write_data !== x_in[idx]) begin
                        order_bad = order_bad + 1;
                        fail("accepted sample != fir_input[i] (lost / duplicated / out of order)", dut.write_data, idx);
                    end
                    if (idx >= tick_n) begin
                        early_bad = early_bad + 1;
                        fail("sample accepted before its tick (ticks so far, sample)", tick_n, idx);
                    end
                    if (idx + 1 < tick_n) late_accept = late_accept + 1;   // next tick already came
                end else
                    fail("more than 10 + 32 samples accepted", accept_n, dut.write_data);
                accept_n = accept_n + 1;
            end
            if (dut.u_fir.hls_y_take) begin
                if (hls_y_n >= NUM_FLUSH && hls_y_n - NUM_FLUSH < N) y_hls[hls_y_n - NUM_FLUSH] = dut.u_fir.hls_y;
                hls_y_n = hls_y_n + 1;
            end
            if (dut.u_fir.hls_finish) begin
                if (finish_n >= NUM_FLUSH && finish_n - NUM_FLUSH < N) fin_t[finish_n - NUM_FLUSH] = cyc;
                finish_n = finish_n + 1;
            end
            if (dut.fir_rd_en && dut.read_addr == A_DOUT) begin
                if (dout_rd_n >= NUM_FLUSH && dout_rd_n - NUM_FLUSH < N) begin
                    rd_t[dout_rd_n - NUM_FLUSH] = cyc;
                    y_rd[dout_rd_n - NUM_FLUSH] = dut.u_fir.y_q;    // snapshot taken at this edge
                    if (!dut.u_fir.done_q) fail("DATA_OUT read without DONE", dout_rd_n, 0);
                end
                dout_rd_n = dout_rd_n + 1;
            end

            //====================================================
            // DMEM writes
            //====================================================
            dw_addr = dut.u_cpu.ex_mem_alu_result;
            if ((dut.u_cpu.dmem_read || dut.u_cpu.dmem_write) && (dw_addr < DMEM_BASE || dw_addr >= DMEM_END)) begin
                dmem_err = dmem_err + 1;
                fail("DMEM access outside window", dw_addr, pc_mem);
            end
            if (dut.u_cpu.dmem_write) begin
                if (in_isr(pc_mem)) begin
                    if (dw_addr >= S_OUT && dw_addr < S_OUT + 4 * N) begin
                        idx = (dw_addr - S_OUT) / 4;
                        st_cnt[idx] = st_cnt[idx] + 1;
                        st_t[idx] = cyc;
                        if (cyc >= tick_t[idx] + PERIOD) tb_missed = tb_missed + 1;
                        if (st_cnt[idx] != 1) fail("fir_output[i] written more than once", idx, st_cnt[idx]);
                        if (idx != stored_now) fail("output stored out of order (index, expected)", idx, stored_now);
                        if (dut.u_cpu.ex_mem_write_data !== y_rd[idx])
                            fail("stored output != DATA_OUT read", dut.u_cpu.ex_mem_write_data, y_rd[idx]);
                        stored_now = stored_now + 1;
                        store_n = store_n + 1;
                    end else if (!((dw_addr >= S_FST && dw_addr < S_FST + 28) ||
                                   (dw_addr >= S_STACK_LIMIT && dw_addr < S_STACK_TOP))) begin
                        isr_bad = isr_bad + 1;
                        fail("ISR DMEM write outside fst / fir_output / stack", dw_addr, pc_mem);
                    end
                end else if (!((dw_addr >= DMEM_BASE && dw_addr < DMEM_BASE + 12) ||
                               (dw_addr >= S_STACK_LIMIT && dw_addr < S_STACK_TOP) ||
                               (en_edge < 0 && dut.u_cpu.ex_mem_write_data == 0 &&
                                ((dw_addr >= S_FST && dw_addr < S_FST + 28) ||
                                 (dw_addr >= S_OUT && dw_addr < S_OUT + 4 * N))))) begin    // .bss clear
                    dmem_err = dmem_err + 1;
                    fail("main DMEM write outside signature / stack", dw_addr, pc_mem);
                end
            end
            if (dut.u_cpu.pc >= IMEM_END && pc_err < 5) begin
                pc_err = pc_err + 1;
                fail("PC outside 1 KB IMEM", dut.u_cpu.pc, 0);
            end
            if (!(supported(dut.u_cpu.if_id_instruction) ||
                  (dut.u_cpu.if_id_instruction == MRET && dut.u_cpu.if_id_pc == S_MRET)) &&
                !(cyc == 1 && dut.u_cpu.if_id_instruction == 32'd0) && illegal_err < 5) begin
                illegal_err = illegal_err + 1;
                fail("unsupported instruction in ID (pc, instr)", dut.u_cpu.if_id_pc, dut.u_cpu.if_id_instruction);
            end
            if (dut.u_cpu.RF.registers[2] === S_STACK_TOP) sp_valid = 1'b1;
            if (sp_valid) begin
                if (dut.u_cpu.RF.registers[2] < sp_min) sp_min = dut.u_cpu.RF.registers[2];
                if ((dut.u_cpu.RF.registers[2] < S_STACK_LIMIT || dut.u_cpu.RF.registers[2] > S_STACK_TOP ||
                     dut.u_cpu.RF.registers[2][3:0] != 4'd0) && sp_err < 5) begin
                    sp_err = sp_err + 1;
                    fail("sp outside stack or not 16-byte aligned", dut.u_cpu.RF.registers[2], 0);
                end
            end

            if (dut.u_cpu.DMEM.memory[1] === HALT_MAGIC) begin
                halted = 1'b1;
                halt_cyc = cyc;
            end
        end
    end

    //------------------------------------------------------------
    // Test sequence and final checks
    //------------------------------------------------------------
    integer i, cnt, lat, lat_min, lat_max, lat_take_max, ivl_min, ivl_max, fin_lat_max, st_lat_max;
    reg [31:0] y_out;
    reg [8*8-1:0] okstr;

    initial begin
        $readmemh("symbols.mem", sym);
        S_FST = sym[0]; S_IN = sym[1]; S_OUT = sym[2]; S_STACK_LIMIT = sym[3]; S_STACK_TOP = sym[4];
        S_TRAP = sym[5]; S_MRET = sym[6]; S_ISR_END = sym[7]; S_LOOP = sym[8]; S_EXIT = sym[9];
        coef[0] = 54;  coef[1] = 0;   coef[2] = -92; coef[3] = 0;   coef[4] = 313; coef[5] = 500;
        coef[6] = 313; coef[7] = 0;   coef[8] = -92; coef[9] = 0;   coef[10] = 54;
        for (i = 0; i < N; i = i + 1) st_cnt[i] = 0;
        #1;                                      // after the CPU's $readmemh initializers
        $readmemh("fir_fir_Pipeline_Shift_Accum_Loop_fir_int_int_c_ROM_AUTO_1R.dat", coef_rom);
        $readmemh("fir_fir_Pipeline_Shift_Accum_Loop_shift_reg_RAM_AUTO_1R1W.dat", hist_dat);
        cnt = 0;
        for (i = 0; i < TAPS; i = i + 1) if (coef_rom[i] !== coef[i]) cnt = cnt + 1;
        check_eq(cnt, 0, "IP coefficient ROM == fir.cpp coefficients used by the model");
        // reference outputs from the intended input (fir_input in data.mem), history = flush zeros
        for (i = 0; i < TAPS; i = i + 1) hist[i] = 0;
        for (i = 0; i < N; i = i + 1) begin
            x_in[i] = dmem(S_IN + 4 * i);
            y_exp[i] = model_push(x_in[i]);
        end
        for (i = 0; i < TAPS; i = i + 1) hist[i] = hist_dat[i];    // scoreboard: IP initial history
        check_eq(S_TRAP, TRAP_VECTOR, "__trap_entry at TRAP_VECTOR 0x10");
        $display("INFO config: PERIOD %0d clocks (%0d Hz at 100 MHz), STRESS %0d, fst 0x%08h fir_input 0x%08h fir_output 0x%08h isr [0x%08h,0x%08h)",
                 PERIOD, 100000000 / PERIOD, STRESS, S_FST, S_IN, S_OUT, S_TRAP, S_ISR_END);

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        while (!halted && cyc < MAX_CYCLES) @(negedge clk);
        repeat (20) @(negedge clk);

        check_true(halted, "firmware reached HALT before timeout");
        if (!halted)
            $display("  PC 0x%08h in_irq %0d ticks %0d accepted %0d stored %0d",
                     dut.u_cpu.pc, dut.u_cpu.in_irq, tick_n, accept_n, store_n);
        check_eq(dmem(DMEM_BASE + 8), 0, "firmware exit code 0");

        // --- Timer ---
        check_eq(first_gap, PERIOD, "first tick exactly PERIOD clocks after Timer enable");
        check_eq(gap_bad, 0, "every tick interval exactly PERIOD clocks");
        check_eq(tick_cnt_err, 0, "TICK_COUNT == observed ticks every cycle");
        check_true(dis_edge > 0, "ISR stopped the Timer");
        check_eq(tick_after_dis, 0, "no tick after the Timer was stopped");
        if (!STRESS) check_eq(tick_n, N, "exactly 32 ticks");
        else         check_true(tick_n >= N, ">= 32 ticks");
        check_eq(dmem(S_FST + 4 * F_TICKS), sched_ticks, "scheduling ticks independently measured at snapshot edge");
        // --- FIR ---
        check_eq(main_din, NUM_FLUSH, "main wrote exactly 10 flush samples, nothing after Timer start");
        check_eq(flush_bad, 0, "flush: 10 zero samples before the Timer");
        check_eq(accept_n, NUM_FLUSH + N, "FIR accepted 10 + 32 samples");
        check_eq(finish_n, NUM_FLUSH + N, "FIR finished 10 + 32 samples");
        check_eq(order_bad, 0, "accepted samples == fir_input[0..31] in order (no loss / duplicate)");
        check_eq(early_bad, 0, "no sample accepted before its tick");
        check_eq(busy_wr, 0, "no DATA_IN write while BUSY");
        check_eq(overrun_seen, 0, "FIR OVERRUN never set");
        check_eq(dout_rd_n, NUM_FLUSH + N, "DATA_OUT read exactly once per sample");
        cnt = 0;
        for (i = 0; i < N; i = i + 1)
            if (y_rd[i] !== y_mdl[i] || y_hls[i] !== y_mdl[i]) begin
                cnt = cnt + 1;
                $display("ERROR sample %0d: DATA_OUT %0d, HLS y %0d, model %0d", i,
                         $signed(y_rd[i]), $signed(y_hls[i]), $signed(y_mdl[i]));
            end
        check_eq(cnt, 0, "DATA_OUT == HLS y == model (from accepted inputs), 32 samples");
        cnt = 0;
        for (i = 0; i < N; i = i + 1)
            if (dmem(S_OUT + 4 * i) !== y_exp[i] || st_cnt[i] != 1) begin
                cnt = cnt + 1;
                $display("ERROR fir_output[%0d] = %0d (written %0d times), reference %0d", i,
                         $signed(dmem(S_OUT + 4 * i)), st_cnt[i], $signed(y_exp[i]));
            end
        check_eq(cnt, 0, "fir_output[0..31] in DMEM == reference from fir_input, each written once (32/32)");
        check_eq(store_n, N, "32 outputs stored by the ISR");
        // --- interrupts ---
        check_eq(isr_seq_bad, 0, "every ISR: one STATUS read, one ACK with the same value");
        check_eq(ack_bad, 0, "every ACK cleared a pending source");
        check_eq(isr_other, 0, "no ISR without a valid source");
        check_eq(dmem(S_FST + 4 * F_SPUR), 0, "fst.spurious == 0");
        check_eq(isr_tim + dut.irq_pending[0], tim_events, "Timer ISRs == Timer pending events (none lost)");
        check_eq(isr_fir, fir_events, "FIR ISRs == FIR pending events (none lost)");
        check_eq(isr_fir, N, "32 FIR ISRs");
        check_eq(fir_events, finish_n - NUM_FLUSH, "every FIR completion after start raised one FIR IRQ event");
        check_eq(take_n, isr_tim + isr_fir, "interrupts taken == Timer + FIR ISRs");
        check_eq(mret_n, take_n, "one mret per interrupt");
        check_eq(ret_n, take_n, "returned to mepc after every mret");
        check_eq(ack_n, take_n + 1, "ACK pulses == ISRs + 1 (main clears flush DONE before start)");
        check_eq(isr_bad, 0, "ISR touched only allowed registers / memory");
        check_eq(main_bad, 0, "main code bus accesses as expected");
        check_eq(dut.irq_pending & dut.irq_enable, 0, "no enabled pending IRQ after drain");
        check_eq(tick_n, tim_events + tim_coal, "ticks == Timer pending events + coalesced ticks");
        check_eq(dmem(S_FST + 4 * F_COAL), sched_ticks - isr_tim, "coalesced release ticks independently accounted");
        // --- context ---
        check_true(ret_loop_n >= 1, "ISRs returned into the main loop");
        check_eq(reg_checks, ret_loop_n + 1, "register file checked after each return into loop + at exit");
        check_eq(reg_errors, 0, "26 registers (incl. t3, s0-s11) intact across interrupts");
        check_eq(sp_err, 0, "sp inside the stack, 16-byte aligned");
        // --- bus / CPU ---
        check_eq(timeouts, 0, "no bus timeout");
        check_eq(resp_n, req_n, "CPU responses == CPU requests");
        check_eq(aw_n, req_wr_n, "AXI AW == CPU writes");
        check_eq(b_n, req_wr_n, "AXI B == CPU writes");
        check_eq(ar_n, req_rd_n, "AXI AR == CPU reads");
        check_eq(r_n, req_rd_n, "AXI R == CPU reads");
        check_eq(pc_err, 0, "PC inside IMEM");
        check_eq(illegal_err, 0, "only supported instructions (+ mret at __trap_mret)");
        check_eq(dmem_err, 0, "DMEM writes inside allowed regions");
        // --- deadlines ---
        check_eq(dmem(S_FST + 4 * F_MISSED), fw_late_clock, "fst.missed == deadline misses measured by the testbench");
        check_eq(dmem(S_FST + 4 * F_SENT), N, "fst.sent == 32");
        check_eq(dmem(S_FST + 4 * F_DONE), N, "fst.done == 32");
        if (!STRESS) begin
            check_eq(tb_missed, 0, "no deadline miss");
            check_eq(late_accept, 0, "every sample accepted before the next tick");
            check_eq(tim_coal, 0, "no coalesced tick");
            check_eq(tb_backlog_max, 1, "backlog never above 1 sample");
            check_eq(dmem(S_FST + 4 * F_BACKLOG), 1, "fst.max_backlog == 1");
        end else begin
            check_true(tb_missed > 0, "stress: deadline misses detected");
            check_true(tim_coal > 0, "stress: coalesced ticks detected");
            check_true(both_pending > 0, "stress: Timer and FIR pending at the same time");
            check_true(dmem(S_FST + 4 * F_BACKLOG) > 1, "stress: firmware saw backlog > 1");
        end

        // --- timing report ---
        lat_min = 32'h7fffffff; lat_max = 0; lat_take_max = 0; ivl_min = 32'h7fffffff; ivl_max = 0;
        fin_lat_max = 0; st_lat_max = 0;
        for (i = 0; i < N; i = i + 1) begin
            lat = acc_t[i] - tick_t[i];
            if (lat < lat_min) lat_min = lat;
            if (lat > lat_max) lat_max = lat;
            if (take_after_tick[i] - tick_t[i] > lat_take_max) lat_take_max = take_after_tick[i] - tick_t[i];
            if (i > 0) begin
                if (acc_t[i] - acc_t[i-1] < ivl_min) ivl_min = acc_t[i] - acc_t[i-1];
                if (acc_t[i] - acc_t[i-1] > ivl_max) ivl_max = acc_t[i] - acc_t[i-1];
            end
            if (fin_t[i] - acc_t[i] > fin_lat_max) fin_lat_max = fin_t[i] - acc_t[i];
            if (st_t[i] - tick_t[i] > st_lat_max) st_lat_max = st_t[i] - tick_t[i];
        end
        if (!STRESS) begin
            check_true(lat_take_max <= 16, "fixed ISR entry budget <= 16 clocks");
            check_true(lat_max <= 400, "fixed tick -> accept budget <= 400 clocks");
            check_true(st_lat_max <= 500, "fixed tick -> stored budget <= 500 clocks");
            check_true(lat_max - lat_min <= 128, "fixed accept jitter budget <= 128 clocks");
            check_true(ivl_min >= PERIOD - 128 && ivl_max <= PERIOD + 128,
                       "accept interval within fixed jitter budget");
        end
        for (i = 0; i < N; i = i + 1) begin
            y_out = dmem(S_OUT + 4 * i);
            okstr = (y_out === y_exp[i]) ? "OK" : "MISMATCH";
            $display("INFO s[%2d] x=%11d tick@%0d isr@+%0d accept@+%0d fir_done@+%0d dout_rd@+%0d store@+%0d  y=%11d ref=%11d %0s",
                     i, $signed(x_acc[i]), tick_t[i], take_after_tick[i] - tick_t[i], acc_t[i] - tick_t[i],
                     fin_t[i] - tick_t[i], rd_t[i] - tick_t[i], st_t[i] - tick_t[i], $signed(y_out),
                     $signed(y_exp[i]), okstr);
        end
        $display("INFO Timer: %0d ticks, first %0d clocks after enable, interval min %0d max %0d clocks",
                 tick_n, first_gap, gap_min, gap_max);
        $display("INFO latency (clocks): tick->ISR entry max %0d; tick->DATA_IN accept min %0d max %0d (jitter %0d = %0d ns); accept->FIR done max %0d; tick->output stored max %0d",
                 lat_take_max, lat_min, lat_max, lat_max - lat_min, (lat_max - lat_min) * 10, fin_lat_max, st_lat_max);
        $display("INFO DATA_IN accept interval: min %0d max %0d clocks (PERIOD %0d)", ivl_min, ivl_max, PERIOD);
        $display("INFO IRQ: taken %0d = Timer ISR %0d + FIR ISR %0d; Timer events %0d + coalesced %0d; FIR events %0d; ACK %0d; mret %0d; both pending %0d cycles",
                 take_n, isr_tim, isr_fir, tim_events, tim_coal, fir_events, ack_n, mret_n, both_pending);
        $display("INFO samples: flush %0d, accepted %0d, finished %0d, DATA_OUT reads %0d, stored %0d; BUSY writes %0d, OVERRUN %0d",
                 main_din, accept_n - NUM_FLUSH, finish_n - NUM_FLUSH, dout_rd_n - NUM_FLUSH, store_n, busy_wr, overrun_seen);
        $display("INFO deadlines: testbench missed %0d (fst.missed %0d), accepted after next tick %0d, backlog max tb %0d / fst %0d, coalesced tb %0d / fst %0d",
                 tb_missed, dmem(S_FST + 4 * F_MISSED), late_accept, tb_backlog_max, dmem(S_FST + 4 * F_BACKLOG),
                 tim_coal, dmem(S_FST + 4 * F_COAL));
        $display("INFO context: register checks %0d, register errors %0d, min sp 0x%08h, longest bus transaction %0d",
                 reg_checks, reg_errors, sp_min, req_age_max);
        $display("Checks: %0d, errors: %0d, cycles to HALT: %0d, PERIOD=%0d, STRESS=%0d",
                 checks, errors, halt_cyc, PERIOD, STRESS);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

endmodule
