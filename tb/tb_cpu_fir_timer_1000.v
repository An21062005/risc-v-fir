`timescale 1ns/1ps

// tb_cpu_fir_timer_1000 : Timer IRQ 10 kHz điều phối 1000 mẫu FIR11 HLS, dữ liệu trong RAM ngoài

module tb_cpu_fir_timer_1000;

    parameter USE_CACHE = 0;
    parameter PERIOD    = 10000;
    parameter STRESS = 0;
    parameter LATE_LAST = 0;
    parameter RESET_TEST = 0;
    parameter ACCEPT_HOLD = 0;
    // Fixed engineering budgets, declared before measurement; shared across all datasets.
    parameter ACCEPT_LIMIT = 400;
    parameter STORE_LIMIT = 500;
    parameter JITTER_LIMIT = 128;

    localparam N            = 1000;
    localparam NUM_FLUSH    = 10;
    localparam TAPS         = 11;
    localparam MAX_CYCLES   = N * (PERIOD + 1000) + 300000;    // ~10.3 M
    localparam STALL_LIMIT  = (STRESS ? N * PERIOD + 10000 : 3 * PERIOD);             // progress watchdog
    localparam TXN_TIMEOUT  = LATE_LAST ? 3 * PERIOD : (ACCEPT_HOLD > 0 ? ACCEPT_HOLD + 300 : 300);
    localparam MAX_ERR_MSG  = 20;
    localparam RAM_WORDS    = 16384;
    localparam MAX_TICKS    = MAX_CYCLES / PERIOD + 16;

    localparam [31:0] HALT_MAGIC  = 32'h4841_4C54;
    localparam [31:0] MRET        = 32'h3020_0073;
    localparam [31:0] TRAP_VECTOR = 32'h0000_0010;
    localparam [31:0] DMEM_BASE   = 32'h1000_0000;
    localparam [31:0] DMEM_END    = 32'h1000_0400;
    localparam [31:0] IMEM_END    = 32'h0000_0400;
    localparam [31:0] RAM_BUS_LO  = 32'h0001_0000;
    localparam [31:0] RAM_BUS_HI  = 32'h0001_FFFF;

    localparam [31:0] A_PERIOD = 32'h084, A_CTRL = 32'h088, A_TICK = 32'h08C;
    localparam [31:0] A_INT_EN = 32'h1C0, A_INT_ACK = 32'h1C8, A_INT_STAT = 32'h1CC;
    localparam [31:0] A_DIN = 32'h200, A_DOUT = 32'h204, A_FSTAT = 32'h208, A_FCTRL = 32'h20C;

    localparam F_TICKS = 0, F_SENT = 1, F_DONE = 2, F_MISSED = 3, F_BACKLOG = 4, F_COAL = 5, F_SPUR = 6;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    wire cpu_irq;
    always #5 clk = ~clk;                        // 100 MHz

    soc_top #(.ENABLE_EXT_RAM(1), .EXT_RAM_USE_CACHE(USE_CACHE)) dut (
        .clk(clk), .rst_n(rst_n), .cpu_irq(cpu_irq)
    );

    // Symbols, data
    reg [31:0] sym [0:5];
    reg [31:0] S_FST, S_STACK_LIMIT, S_STACK_TOP, S_TRAP, S_MRET, S_ISR_END;
    reg [31:0] layout [0:5];
    reg [31:0] x_in   [0:N-1];                   // input.mem
    reg [31:0] y_exp1 [0:N-1];                   // expected.mem (Python model)
    reg [31:0] y_exp  [0:N-1];                   // Verilog model from x_in
    reg [31:0] IN_BUS, OUT_BUS;                  // bus addresses of input[0] / output[0]

    function [31:0] dmem;
        input [31:0] a;
        begin dmem = dut.u_cpu.DMEM.memory[a[9:2]]; end
    endfunction

    function [31:0] sdram_word;                  // word at RAM offset o (halfword low at o/2)
        input [31:0] o;
        begin
            sdram_word = {dut.g_ext_ram.u_ext_mem.U_SDRAM.MEMORY.memory[(o >> 1) + 1],
                          dut.g_ext_ram.u_ext_mem.U_SDRAM.MEMORY.memory[o >> 1]};
        end
    endfunction

    // Errors
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

    // Independent FIR model (Verilog)
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

    // Context: full register file at ISR entry vs at return
    reg [31:0] ctx [1:31];
    reg        ctx_wait = 1'b0, ret_armed = 1'b0;
    reg [31:0] ret_pc, prev_pc_mem = 32'd0;
    integer    ctx_checks = 0, ctx_errors = 0, rn;

    task ctx_compare;
        input [8*24-1:0] where;
        begin
            ctx_checks = ctx_checks + 1;
            for (rn = 1; rn < 32; rn = rn + 1)
                if (dut.u_cpu.RF.registers[rn] !== ctx[rn]) begin
                    ctx_errors = ctx_errors + 1;
                    fail("register changed across ISR (reg, value)", rn, dut.u_cpu.RF.registers[rn]);
                    if (msgs <= MAX_ERR_MSG) $display("      at %0s: before ISR 0x%08h", where, ctx[rn]);
                end
        end
    endtask

    // Monitor state
    integer tick_n = 0, en_edge = -1, dis_edge = -1, first_gap = -1, last_tick = -1;
    integer gap_min = 32'h7fffffff, gap_max = 0, gap_bad = 0, tick_after_dis = 0, tick_cnt_err = 0;
    integer tick_t [0:MAX_TICKS-1];
    integer take_after_tick [0:MAX_TICKS-1];
    integer next_tick_take = 0;
    reg     prev_tirq = 1'b0;
    integer tim_events = 0, fir_events = 0, tim_coal = 0, both_pending = 0, ack_n = 0, ack_bad = 0;
    integer take_n = 0, mret_n = 0, ret_n = 0, isr_tim = 0, isr_fir = 0, isr_other = 0;
    integer isr_stat_n = 0, isr_ack_n = 0, isr_dout_n = 0, isr_in_n = 0, isr_out_n = 0;
    integer isr_bad = 0, isr_seq_bad = 0, isr_dl_done = 0;
    reg [31:0] isr_stat_val;
    reg        isr_open = 1'b0, chk_vec = 1'b0, chk_ret = 1'b0;
    reg [31:0] exp_mepc, ret_target;
    // samples
    integer accept_n = 0, finish_n = 0, dout_rd_n = 0;
    integer busy_wr = 0, overrun_seen = 0, flush_bad = 0, order_bad = 0, early_bad = 0, main_din = 0;
    integer acc_t [0:N-1];
    integer fin_t [0:N-1];
    integer st_t  [0:N-1];
    reg [31:0] y_hls [0:N-1];
    reg [31:0] y_rd  [0:N-1];
    reg [31:0] y_mdl [0:N-1];
    integer hls_y_n = 0, idx;
    // external RAM traffic
    integer in_rd_n = 0, in_rd_bad = 0, out_wr_n = 0, out_wr_bad = 0, rb_n = 0, rb_bad = 0, ram_other = 0;
    integer stored_now = 0, ram_req_n = 0, ram_done_n = 0, ram_axi_n = 0;
    reg     ram_open = 1'b0;
    // deadlines
    integer fw_late_clock = 0, sched_ticks = 0;
    integer tb_missed = 0, late_accept = 0, tb_backlog_max = 0;
    // progress watchdog
    integer last_progress = 0, deadlock = 0;
    // bus
    integer req_n = 0, req_wr_n = 0, req_rd_n = 0, resp_n = 0, req_age = 0, req_age_max = 0;
    integer aw_n = 0, b_n = 0, ar_n = 0, r_n = 0, timeouts = 0, main_bad = 0;
    integer mmio_axi_n = 0, isr_ram_age_max = 0;
    reg        req_open = 1'b0, req_is_wr = 1'b0, req_isr = 1'b0;
    reg [31:0] req_addr = 32'd0, pc_mem, dw_addr;
    integer pc_err = 0, illegal_err = 0, dmem_err = 0, sp_err = 0;
    reg     sp_valid = 1'b0;
    reg [31:0] sp_min = 32'hFFFF_FFFF;
    reg     halted = 1'b0;
    integer halt_cyc = 0;

    reg verification_active = 0;
    always @(posedge clk) begin
        if (dut.rst_n_sync && verification_active && !halted && !deadlock) begin   // DUT out of reset (S1)
            cyc = cyc + 1;
            pc_mem = dut.u_cpu.ex_mem_pc_plus_4 - 32'd4;

            // Timer
            if (dut.timer_wr_en && dut.write_addr == A_CTRL) begin
                if (dut.write_data[0] && !dut.u_timer.ctrl_enable && en_edge < 0) begin
                    en_edge = cyc;
                    last_progress = cyc;
                end
                if (!dut.write_data[0] && dis_edge < 0) dis_edge = cyc;
            end
            if (dut.timer_irq) begin
                if (tick_n < MAX_TICKS) begin tick_t[tick_n] = cyc - 1; take_after_tick[tick_n] = -1; end
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
                if (((tick_n < N) ? tick_n : N) - stored_now > tb_backlog_max)
                    tb_backlog_max = ((tick_n < N) ? tick_n : N) - stored_now;
            end
            prev_tirq = dut.timer_irq;
            if (dut.u_timer.tick_count !== tick_n) begin
                tick_cnt_err = tick_cnt_err + 1;
                if (tick_cnt_err <= 3) fail("TICK_COUNT != observed ticks", dut.u_timer.tick_count, tick_n);
            end

            // Interrupt controller
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

            // CPU: irq_take / vector / mret / return, context snapshot
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
            // ISR entry: first ISR instruction in MEM -> all older instructions written back
            if (pc_mem == S_TRAP && prev_pc_mem != S_TRAP) begin
                if (ctx_wait) ctx_compare("re-entry before return");
                else for (rn = 1; rn < 32; rn = rn + 1) ctx[rn] = dut.u_cpu.RF.registers[rn];
                ctx_wait = 1'b1;
                ret_armed = 1'b0;
            end
            // return: instruction at mepc in MEM -> all ISR instructions (before mret) written back
            if (ret_armed && pc_mem == ret_pc && prev_pc_mem != ret_pc) begin
                ctx_compare("return to mepc");
                ctx_wait = 1'b0;
                ret_armed = 1'b0;
            end
            prev_pc_mem = pc_mem;
            if (dut.u_cpu.irq_take) begin
                take_n = take_n + 1;
                if (!cpu_irq || dut.u_cpu.in_irq || dut.u_cpu.bus_stall)
                    fail("irq_take without IRQ / nested / during stall", cpu_irq, dut.u_cpu.in_irq);
                while (next_tick_take < tick_n && next_tick_take < MAX_TICKS) begin
                    take_after_tick[next_tick_take] = cyc;
                    next_tick_take = next_tick_take + 1;
                end
                isr_open = 1'b1;
                isr_stat_n = 0; isr_ack_n = 0; isr_dout_n = 0; isr_dl_done = 0; isr_in_n = 0; isr_out_n = 0;
                isr_stat_val = 32'hxxxx_xxxx;
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
                    if (isr_dout_n != 1 || isr_out_n != 1)
                        fail("FIR ISR: not exactly one DATA_OUT read + one output store", isr_dout_n, isr_out_n);
                end else isr_other = isr_other + 1;
                isr_open = 1'b0;
                ret_target = dut.u_cpu.mepc;
                ret_pc = dut.u_cpu.mepc;
                ret_armed = 1'b1;
                chk_ret = 1'b1;
            end

            // Bus requests, classified by the PC of the MEM-stage instruction
            if ((dut.bus_rd || dut.bus_wr) && !req_open) begin
                req_open = 1'b1;
                req_is_wr = dut.bus_wr;
                req_addr = dut.bus_addr;
                req_isr = in_isr(pc_mem);
                req_age = 0;
                req_n = req_n + 1;
                if (dut.bus_wr) req_wr_n = req_wr_n + 1; else req_rd_n = req_rd_n + 1;
                if (dut.bus_addr >= RAM_BUS_LO && dut.bus_addr <= RAM_BUS_HI) ram_axi_n = ram_axi_n + 1;
                else mmio_axi_n = mmio_axi_n + 1;
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
                        if (isr_ack_n != 1 || isr_in_n != 1)
                            fail("DATA_IN written before ACK / without reading input[i]", isr_ack_n, isr_in_n);
                    end else if (!dut.bus_wr && dut.bus_addr == A_DOUT) begin
                        isr_dout_n = isr_dout_n + 1;
                        if (isr_ack_n != 1 || isr_stat_val !== 32'd3)
                            fail("DATA_OUT read outside FIR ISR or before ACK", isr_stat_val, isr_ack_n);
                    end else if (!dut.bus_wr && dut.bus_addr == IN_BUS + 4 * in_rd_n && in_rd_n < N) begin
                        isr_in_n = isr_in_n + 1;    // input[in_rd_n], data checked at bus_ready
                    end else if (dut.bus_wr && dut.bus_addr == OUT_BUS + 4 * out_wr_n && out_wr_n < N) begin
                        isr_out_n = isr_out_n + 1;
                        if (isr_dout_n != 1 || dut.bus_wdata !== y_rd[out_wr_n]) begin
                            out_wr_bad = out_wr_bad + 1;
                            fail("output store != DATA_OUT read in this ISR", dut.bus_wdata, y_rd[out_wr_n]);
                        end
                    end else if (!((!dut.bus_wr && dut.bus_addr == A_INT_STAT) ||
                                   (!dut.bus_wr && dut.bus_addr == A_TICK) ||
                                   (dut.bus_wr && dut.bus_addr == A_CTRL && dut.bus_wdata == 0) ||
                                   (dut.bus_wr && dut.bus_addr == A_INT_EN && dut.bus_wdata == 2))) begin
                        isr_bad = isr_bad + 1;
                        if (dut.bus_addr >= RAM_BUS_LO && dut.bus_addr <= RAM_BUS_HI) ram_other = ram_other + 1;
                        fail("unexpected ISR bus access (addr, pc): wrong/duplicate RAM index or register", dut.bus_addr, pc_mem);
                    end
                end else begin
                    if (dut.bus_wr && dut.bus_addr == A_DIN) begin
                        main_din = main_din + 1;
                        if (en_edge >= 0 || dut.bus_wdata !== 0)
                            fail("main wrote DATA_IN after Timer start / non-zero flush", dut.bus_wdata, pc_mem);
                    end else if (dut.bus_wr && dut.bus_addr == A_INT_ACK) begin
                        if (en_edge >= 0 || dut.bus_wdata !== 3) fail("ACK from main after start", dut.bus_wdata, pc_mem);
                    end else if (!dut.bus_wr && dut.bus_addr == OUT_BUS + 4 * rb_n && rb_n < N) begin
                        if (stored_now != N) fail("main read output[] before all outputs stored", rb_n, stored_now);
                        rb_n = rb_n + 1;            // readback checksum, data checked at bus_ready
                    end else if (dut.bus_wr ? !((dut.bus_addr == A_FCTRL && dut.bus_wdata == 1) ||
                                                (dut.bus_addr == A_PERIOD && dut.bus_wdata == PERIOD) ||
                                                (dut.bus_addr == A_INT_EN && dut.bus_wdata == 3) ||
                                                (dut.bus_addr == A_CTRL && dut.bus_wdata == 3))
                                            : !(dut.bus_addr == A_FSTAT || dut.bus_addr == A_CTRL ||
                                                (dut.bus_addr == A_DOUT && en_edge < 0))) begin
                        main_bad = main_bad + 1;
                        if (dut.bus_addr >= RAM_BUS_LO && dut.bus_addr <= RAM_BUS_HI) ram_other = ram_other + 1;
                        fail("unexpected bus access from main code (addr, pc)", dut.bus_addr, pc_mem);
                    end
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
                if (req_isr && req_addr >= RAM_BUS_LO && req_addr <= RAM_BUS_HI && req_age > isr_ram_age_max)
                    isr_ram_age_max = req_age;
                if (req_isr && !req_is_wr && req_addr == A_INT_STAT) begin
                    isr_stat_n = isr_stat_n + 1;
                    isr_stat_val = dut.bus_rdata;
                end
                if (req_isr && !req_is_wr && req_addr == IN_BUS + 4 * in_rd_n && in_rd_n < N) begin
                    if (dut.bus_rdata !== x_in[in_rd_n]) begin
                        in_rd_bad = in_rd_bad + 1;
                        fail("input[i] read by CPU != input.mem[i] (data, exp)", dut.bus_rdata, x_in[in_rd_n]);
                    end
                    in_rd_n = in_rd_n + 1;
                end
                if (req_isr && req_is_wr && req_addr == OUT_BUS + 4 * out_wr_n && out_wr_n < N) begin
                    st_t[out_wr_n] = cyc;
                    if (cyc >= tick_t[out_wr_n] + PERIOD) tb_missed = tb_missed + 1;
                    out_wr_n = out_wr_n + 1;
                    stored_now = stored_now + 1;
                    last_progress = cyc;
                end
                if (!req_isr && !req_is_wr && req_addr == OUT_BUS + 4 * (rb_n - 1) && rb_n > 0 &&
                    dut.bus_rdata !== y_exp[rb_n - 1]) begin
                    rb_bad = rb_bad + 1;
                    fail("readback output[i] != reference", dut.bus_rdata, y_exp[rb_n - 1]);
                end
                // deadline check point (once per sample): first TICK_COUNT read in a FIR ISR after the store
                if (req_isr && !req_is_wr && req_addr == A_TICK && isr_stat_val == 32'd3 && !isr_dl_done) begin
                    isr_dl_done = 1;
                    // firmware observation checked below against absolute clock, not read data
                end
                req_open = 1'b0;
            end
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
            // interconnect -> cache_top: exactly one request + one ready per RAM AXI transaction
            if ((dut.ext_ram_read || dut.ext_ram_write) && !ram_open) begin
                ram_open = 1'b1;
                ram_req_n = ram_req_n + 1;
            end
            if (dut.ext_ram_ready) begin
                if (!ram_open) fail("ext_ram_ready without request", 0, 0);
                ram_done_n = ram_done_n + 1;
                ram_open = 1'b0;
            end

            // FIR wrapper / HLS
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
                    idx = model_push(dut.write_data);
                end else if (accept_n - NUM_FLUSH < N) begin
                    idx = accept_n - NUM_FLUSH;
                    acc_t[idx] = cyc;
                    y_mdl[idx] = model_push(dut.write_data);
                    last_progress = cyc;
                    if (dut.write_data !== x_in[idx]) begin
                        order_bad = order_bad + 1;
                        fail("accepted sample != input[i] (lost / duplicated / out of order)", dut.write_data, idx);
                    end
                    if (idx >= tick_n) begin
                        early_bad = early_bad + 1;
                        fail("sample accepted before its tick (ticks so far, sample)", tick_n, idx);
                    end
                    if (idx + 1 < tick_n) late_accept = late_accept + 1;
                end else
                    fail("more than 10 + 1000 samples accepted", accept_n, dut.write_data);
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
                    y_rd[dout_rd_n - NUM_FLUSH] = dut.u_fir.y_q;
                    if (!dut.u_fir.done_q) fail("DATA_OUT read without DONE", dout_rd_n, 0);
                end
                dout_rd_n = dout_rd_n + 1;
            end

            // DMEM, PC, ISA, stack
            dw_addr = dut.u_cpu.ex_mem_alu_result;
            if ((dut.u_cpu.dmem_read || dut.u_cpu.dmem_write) && (dw_addr < DMEM_BASE || dw_addr >= DMEM_END)) begin
                dmem_err = dmem_err + 1;
                fail("DMEM access outside window", dw_addr, pc_mem);
            end
            if (dut.u_cpu.dmem_write) begin
                if (in_isr(pc_mem)) begin
                    if (!((dw_addr >= S_FST && dw_addr < S_FST + 28) ||
                          (dw_addr >= S_STACK_LIMIT && dw_addr < S_STACK_TOP))) begin
                        isr_bad = isr_bad + 1;
                        fail("ISR DMEM write outside fst / stack", dw_addr, pc_mem);
                    end
                end else if (!((dw_addr >= DMEM_BASE && dw_addr < DMEM_BASE + 12) ||
                               (dw_addr >= S_STACK_LIMIT && dw_addr < S_STACK_TOP) ||
                               (en_edge < 0 && dut.u_cpu.ex_mem_write_data == 0 &&
                                dw_addr >= S_FST && dw_addr < S_FST + 28))) begin
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
            if (dut.u_cpu.mem_wb_pc_plus_4 == 12 && dut.u_cpu.RF.registers[2] === S_STACK_TOP) sp_valid = 1'b1;
            if (sp_valid) begin
                if (dut.u_cpu.RF.registers[2] < sp_min) sp_min = dut.u_cpu.RF.registers[2];
                if ((dut.u_cpu.RF.registers[2] < S_STACK_LIMIT || dut.u_cpu.RF.registers[2] > S_STACK_TOP ||
                     dut.u_cpu.RF.registers[2][3:0] != 4'd0) && sp_err < 5) begin
                    sp_err = sp_err + 1;
                    fail("sp outside stack or not 16-byte aligned", dut.u_cpu.RF.registers[2], 0);
                end
            end

            // The MMIO snapshot edge, evaluated using only the independent clock origin.
            if (dut.timer_rd_en && dut.read_addr == A_TICK) begin
                if (isr_stat_val == 3 && cyc - en_edge >= (stored_now + 1) * PERIOD)
                    fw_late_clock = fw_late_clock + 1;
                if (isr_stat_val == 1) sched_ticks = (cyc - en_edge) / PERIOD;
            end
            // progress watchdog (deadlock / lost IRQ)
            if (en_edge >= 0 && stored_now < N && cyc - last_progress > STALL_LIMIT) begin
                deadlock = 1;
                fail("DEADLOCK: no sample accepted / stored for 3 Timer periods (accepted, stored)",
                     accept_n - NUM_FLUSH, stored_now);
            end
            if (dut.u_cpu.DMEM.memory[1] === HALT_MAGIC) begin
                halted = 1'b1;
                halt_cyc = cyc;
            end
        end
    end

    // Test sequence and final checks
    integer i, cnt, lat, lat_min, lat_max, lat_take_min, lat_take_max, ivl_min, ivl_max;
    integer fin_min, fin_max, st_min, st_max;
    reg [63:0] lat_sum, take_sum, st_sum;
    reg [31:0] w, in_off, out_off;
    integer actual_fd;

    // Bounded reset scenarios run before the full checked stream. The stimulus never
    wire cache_refilling, cache_invalid;
    integer reset_cases = 0, reset_wait;
    reg reset_target;
    task reset_now;
        begin
            rst_n = 0;
            repeat (5) @(negedge clk);
            check_eq(dut.u_cpu.pc, 0, "reset CPU returns to reset vector");
            check_eq({dut.axi_bvalid, dut.axi_rvalid, dut.bus_ready, dut.ext_ram_ready}, 0,
                     "reset cancels old AXI/backend completion");
            check_true(cache_invalid, "reset invalidates all cache lines");
            check_eq({dut.irq_pending, dut.u_fir.done_q, dut.u_fir.busy_q}, 0,
                     "reset clears pending IRQ, DONE and BUSY");
            rst_n = 1;
            // No new CPU bus request exists during these startup instructions.
            repeat (12) begin
                @(negedge clk);
                check_eq({dut.bus_ready, dut.ext_ram_ready, dut.axi_bvalid, dut.axi_rvalid, dut.fir_irq}, 0,
                         "no stale completion after reset release");
            end
            reset_cases = reset_cases + 1;
        end
    endtask

    task reset_scenarios;
        integer scenario;
        begin
            rst_n = 1;
            for (scenario = 0; scenario < (USE_CACHE ? 4 : 3); scenario = scenario + 1) begin
                reset_wait = 0; reset_target = 0;
                while (!reset_target && reset_wait < 50000) begin
                    @(negedge clk);
                    reset_wait = reset_wait + 1;
                    case (scenario)
                        0: reset_target = dut.ext_ram_read && !dut.ext_ram_ready;
                        1: reset_target = dut.ext_ram_write && !dut.ext_ram_ready;
                        2: reset_target = dut.u_cpu.in_irq && dut.u_fir.busy_q;
                        3: reset_target = cache_refilling;
                    endcase
                end
                check_true(reset_target, "reset target reached before watchdog");
                reset_now();
            end
            rst_n = 0;
            repeat (5) @(negedge clk);
            $display("INFO reset scenarios: %0d exercised; full 1000-sample reboot follows", reset_cases);
        end
    endtask
    generate if (USE_CACHE) begin
        assign cache_invalid = dut.g_ext_ram.u_ext_mem.g_cache.U_CACHE_CONTROLLER.u_cache_tag_ram.valid_memory == 0;
        assign cache_refilling = dut.g_ext_ram.u_ext_mem.g_cache.U_CACHE_CONTROLLER.state == 4 &&
                                 dut.g_ext_ram.u_ext_mem.g_cache.U_CACHE_CONTROLLER.refill_word > 0;
    end else begin
        assign cache_refilling = 0;
        assign cache_invalid = 1;
    end endgenerate

    initial begin
        if (ACCEPT_HOLD > 0) begin
            wait(in_rd_n == 10);
            wait(dut.axi_arvalid && dut.axi_araddr == IN_BUS + 40);
            @(negedge clk);
            force dut.u_axi_master.M_AXI_RREADY = 0;
            repeat (ACCEPT_HOLD) @(negedge clk);
            release dut.u_axi_master.M_AXI_RREADY;
            $display("INFO injected input response delay %0d clocks", ACCEPT_HOLD);
        end
    end
    initial begin
        if (LATE_LAST) begin
            wait(out_wr_n == N-1);
            wait(dut.axi_awvalid && dut.axi_awaddr == OUT_BUS + 4*(N-1));
            @(negedge clk);
            force dut.u_axi_master.M_AXI_BREADY = 0;
            repeat (2 * PERIOD) @(negedge clk);
            release dut.u_axi_master.M_AXI_BREADY;
            $display("INFO injected final-store AXI response delay: %0d clocks", 2*PERIOD);
        end
    end

    initial begin
        $readmemh("symbols.mem", sym);
        $readmemh("layout.mem", layout);
        $readmemh("input.mem", x_in);
        $readmemh("expected.mem", y_exp1);
        S_FST = sym[0]; S_STACK_LIMIT = sym[1]; S_STACK_TOP = sym[2]; S_TRAP = sym[3]; S_MRET = sym[4]; S_ISR_END = sym[5];
        IN_BUS = layout[0] - 32'h4000_0000; OUT_BUS = layout[1] - 32'h4000_0000;
        in_off = IN_BUS - RAM_BUS_LO; out_off = OUT_BUS - RAM_BUS_LO;
        coef[0] = 54;  coef[1] = 0;   coef[2] = -92; coef[3] = 0;   coef[4] = 313; coef[5] = 500;
        coef[6] = 313; coef[7] = 0;   coef[8] = -92; coef[9] = 0;   coef[10] = 54;
        #1;                                      // after $readmemh and the sdram_model zero fill
        $readmemh("fir_fir_Pipeline_Shift_Accum_Loop_fir_int_int_c_ROM_AUTO_1R.dat", coef_rom);
        $readmemh("fir_fir_Pipeline_Shift_Accum_Loop_shift_reg_RAM_AUTO_1R1W.dat", hist_dat);
        check_eq(layout[2], N, "layout.mem N == 1000");
        check_eq(S_TRAP, TRAP_VECTOR, "__trap_entry at TRAP_VECTOR 0x10");
        cnt = 0;
        for (i = 0; i < TAPS; i = i + 1) if (coef_rom[i] !== coef[i]) cnt = cnt + 1;
        check_eq(cnt, 0, "IP coefficient ROM == coefficients of the model");
        // reference: Verilog model from input.mem with zero history, must equal expected.mem (Python)
        for (i = 0; i < TAPS; i = i + 1) hist[i] = 0;
        cnt = 0;
        for (i = 0; i < N; i = i + 1) begin
            y_exp[i] = model_push(x_in[i]);
            if (y_exp[i] !== y_exp1[i]) cnt = cnt + 1;
        end
        check_eq(cnt, 0, "Verilog model == expected.mem (Python model), 1000 samples");
        for (i = 0; i < TAPS; i = i + 1) hist[i] = hist_dat[i];    // scoreboard starts from IP history
        // external RAM: all zero, then preload input[]
        cnt = 0;
        for (i = 0; i < RAM_WORDS; i = i + 1) if (sdram_word(4 * i) !== 32'd0) cnt = cnt + 1;
        check_eq(cnt, 0, "external RAM all zero before preload");
        for (i = 0; i < N; i = i + 1) begin
            dut.g_ext_ram.u_ext_mem.U_SDRAM.MEMORY.memory[(in_off + 4 * i) >> 1]       = x_in[i][15:0];
            dut.g_ext_ram.u_ext_mem.U_SDRAM.MEMORY.memory[((in_off + 4 * i) >> 1) + 1] = x_in[i][31:16];
        end
        $display("INFO config: USE_CACHE %0d, PERIOD %0d clocks (%0d Hz at 100 MHz), input @0x%08h output @0x%08h, ISR [0x%08h,0x%08h)",
                 USE_CACHE, PERIOD, 100000000 / PERIOD, layout[0], layout[1], S_TRAP, S_ISR_END);

        repeat (5) @(negedge clk);
        if (RESET_TEST) reset_scenarios();
        verification_active = 1;
        rst_n = 1'b1;
        while (!halted && !deadlock && cyc < MAX_CYCLES) @(negedge clk);
        repeat (20) @(negedge clk);

        check_true(halted, "firmware reached HALT (no deadlock, before MAX_CYCLES)");
        check_eq(deadlock, 0, "progress watchdog never fired");
        check_eq(dmem(DMEM_BASE + 8), (STRESS || LATE_LAST) ? 6 : 0, "firmware exit: 0 normal, 6 detected overload/deadline");

        // --- Timer ---
        if (!STRESS && !LATE_LAST) check_eq(tick_n, N, "exactly 1000 ticks");
        else check_true(tick_n > N, "deadline clock continues beyond final release");
        check_eq(first_gap, PERIOD, "first tick exactly PERIOD clocks after Timer enable");
        check_eq(gap_bad, 0, "every tick interval exactly PERIOD clocks");
        check_eq(tick_cnt_err, 0, "TICK_COUNT == observed ticks every cycle");
        check_true(dis_edge > 0, "ISR stopped the Timer");
        check_eq(tick_after_dis, 0, "no tick after the Timer was stopped");
        // --- external RAM traffic ---
        check_eq(in_rd_n, N, "CPU read input[0..999] from external RAM, in order, once each");
        check_eq(in_rd_bad, 0, "every input word read by the CPU == input.mem");
        check_eq(out_wr_n, N, "CPU stored output[0..999] to external RAM, in order, once each");
        check_eq(out_wr_bad, 0, "every output store == DATA_OUT of that sample");
        check_eq(ram_other, 0, "no other external RAM access (no wrong / duplicate index)");
        check_eq(rb_n, (STRESS || LATE_LAST) ? 0 : N, "firmware readback of output[] after completion");
        check_eq(rb_bad, 0, "readback through AXI/cache == reference");
        check_eq(ram_req_n, ram_axi_n, "one cache_top request per RAM AXI transaction");
        check_eq(ram_done_n, ram_axi_n, "one cache_top ready per RAM AXI transaction");
        // final external RAM contents, read directly from sdram_model
        cnt = 0;
        for (i = 0; i < N; i = i + 1) if (sdram_word(in_off + 4 * i) !== x_in[i]) cnt = cnt + 1;
        check_eq(cnt, 0, "external RAM input[] unchanged");
        cnt = 0;
        actual_fd = $fopen("actual.dat", "w");
        check_true(actual_fd != 0, "actual output artifact opened");
        for (i = 0; i < N; i = i + 1) begin
            w = sdram_word(out_off + 4 * i);
            $fdisplay(actual_fd, "%0d", $signed(w));
            if (w !== y_exp[i]) begin
                cnt = cnt + 1;
                if (cnt <= 5) $display("ERROR RAM output[%0d] = %0d, reference %0d", i, $signed(w), $signed(y_exp[i]));
            end
        end
        $fclose(actual_fd);
        check_eq(cnt, 0, "external RAM output[0..999] == reference (1000/1000 bit-exact)");
        cnt = 0;
        for (i = 0; i < RAM_WORDS; i = i + 1)
            if (!((4 * i >= in_off && 4 * i < in_off + 4 * N) || (4 * i >= out_off && 4 * i < out_off + 4 * N)) &&
                sdram_word(4 * i) !== 32'd0) cnt = cnt + 1;
        check_eq(cnt, 0, "every other external RAM word still 0 (no stray write)");
        // --- FIR ---
        check_eq(main_din, NUM_FLUSH, "main wrote exactly 10 flush samples, nothing after Timer start");
        check_eq(flush_bad, 0, "flush: 10 zero samples before the Timer");
        check_eq(accept_n, NUM_FLUSH + N, "FIR accepted 10 + 1000 samples");
        check_eq(finish_n, NUM_FLUSH + N, "FIR finished 10 + 1000 samples");
        check_eq(order_bad, 0, "accepted samples == input[0..999] in order (no loss / duplicate)");
        check_eq(early_bad, 0, "no sample accepted before its tick");
        check_eq(busy_wr, 0, "no DATA_IN write while BUSY");
        check_eq(overrun_seen, 0, "FIR OVERRUN never set");
        check_eq(dout_rd_n, NUM_FLUSH + N, "DATA_OUT read exactly once per sample");
        cnt = 0;
        for (i = 0; i < N; i = i + 1) if (y_rd[i] !== y_mdl[i] || y_hls[i] !== y_mdl[i]) cnt = cnt + 1;
        check_eq(cnt, 0, "DATA_OUT == HLS y == model (from accepted inputs), 1000 samples");
        // --- interrupts ---
        check_eq(isr_seq_bad, 0, "every ISR: one STATUS read, one ACK with the same value");
        check_eq(ack_bad, 0, "every ACK cleared a pending source");
        check_eq(isr_other, 0, "no ISR without a valid source");
        check_eq(dmem(S_FST + 4 * F_SPUR), 0, "fst.spurious == 0");
        check_eq(isr_tim + dut.irq_pending[0], tim_events, "Timer ISRs == Timer pending events (none lost)");
        check_eq(isr_fir, fir_events, "FIR ISRs == FIR pending events (none lost)");
        check_eq(fir_events, finish_n - NUM_FLUSH, "every FIR completion after start raised one FIR IRQ event");
        check_eq(isr_fir, N, "1000 FIR ISRs");
        check_eq(take_n, isr_tim + isr_fir, "interrupts taken == Timer + FIR ISRs");
        check_eq(mret_n, take_n, "one mret per interrupt");
        check_eq(ret_n, take_n, "returned to mepc after every mret");
        check_eq(ack_n, take_n + 1, "ACK pulses == ISRs + 1 (main clears flush DONE before start)");
        check_eq(isr_bad, 0, "ISR touched only allowed registers / memory");
        check_eq(main_bad, 0, "main code bus accesses as expected");
        check_eq(dut.irq_pending & dut.irq_enable, 0, "no enabled pending source (drain clock may leave masked Timer)");
        check_eq(tick_n, tim_events + tim_coal, "ticks == Timer pending events + coalesced ticks");
        // --- context ---
        check_eq(ctx_checks, take_n, "register file compared for every ISR");
        check_eq(ctx_errors, 0, "x1..x31 identical before and after every ISR");
        check_true(sp_valid, "startup established stack before monitoring");
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
        if (STRESS || LATE_LAST) check_true(tb_missed > 0, "injection/overload caused actual deadline misses");
        else check_eq(tb_missed, 0, "no deadline miss");
        if (LATE_LAST) begin
            check_true(st_t[N-1] >= tick_t[N-1] + PERIOD, "last output really stored after deadline");
            check_true(dmem(S_FST + 4 * F_MISSED) > 0, "firmware detects final output miss");
        end
        check_eq(dmem(S_FST + 4 * F_MISSED), fw_late_clock, "fst.missed == testbench");
        check_eq(dmem(S_FST + 4 * F_COAL), sched_ticks - isr_tim, "coalesced scheduling ticks independently accounted");
        check_eq(dmem(S_FST), sched_ticks, "fst.ticks == independent clock at last scheduling snapshot");
        if (STRESS) begin
            check_true(late_accept > 0, "overload: late accepts");
            check_true(tim_coal > 0, "overload: ticks coalesced");
            check_true(both_pending > 0, "overload: both IRQ sources pending");
            check_true(tb_backlog_max > 1, "overload: backlog detected");
            check_true(dmem(S_FST + 4 * F_BACKLOG) > 1, "firmware detects backlog");
        end else if (!LATE_LAST) begin
            check_eq(late_accept, 0, "every sample accepted before next tick");
            check_eq(tim_coal, 0, "no coalesced tick");
            check_eq(tb_backlog_max, 1, "backlog never above 1 sample");
            check_eq(dmem(S_FST + 4 * F_BACKLOG), 1, "fst.max_backlog == 1");
        end
        check_eq(dmem(S_FST + 4 * F_SENT), N, "fst.sent == 1000");
        check_eq(dmem(S_FST + 4 * F_DONE), N, "fst.done == 1000");

        // --- timing ---
        lat_min = 32'h7fffffff; lat_max = 0; lat_take_min = 32'h7fffffff; lat_take_max = 0;
        ivl_min = 32'h7fffffff; ivl_max = 0; fin_min = 32'h7fffffff; fin_max = 0;
        st_min = 32'h7fffffff; st_max = 0; lat_sum = 0; take_sum = 0; st_sum = 0;
        for (i = 0; i < N; i = i + 1) begin
            lat = acc_t[i] - tick_t[i];
            lat_sum = lat_sum + lat;
            if (lat < lat_min) lat_min = lat;
            if (lat > lat_max) lat_max = lat;
            lat = take_after_tick[i] - tick_t[i];
            take_sum = take_sum + lat;
            if (lat < lat_take_min) lat_take_min = lat;
            if (lat > lat_take_max) lat_take_max = lat;
            if (i > 0) begin
                if (acc_t[i] - acc_t[i-1] < ivl_min) ivl_min = acc_t[i] - acc_t[i-1];
                if (acc_t[i] - acc_t[i-1] > ivl_max) ivl_max = acc_t[i] - acc_t[i-1];
            end
            if (fin_t[i] - acc_t[i] < fin_min) fin_min = fin_t[i] - acc_t[i];
            if (fin_t[i] - acc_t[i] > fin_max) fin_max = fin_t[i] - acc_t[i];
            lat = st_t[i] - tick_t[i];
            st_sum = st_sum + lat;
            if (lat < st_min) st_min = lat;
            if (lat > st_max) st_max = lat;
        end
        if (!STRESS && !LATE_LAST) begin
            check_true(lat_take_max <= 16, "fixed ISR entry budget <= 16 clocks");
            check_true(lat_max <= ACCEPT_LIMIT, "fixed tick -> accept budget");
            check_true(st_max <= STORE_LIMIT, "fixed tick -> stored budget");
            check_true(lat_max - lat_min <= JITTER_LIMIT, "fixed accept jitter budget");
            check_true(ivl_min >= PERIOD - JITTER_LIMIT && ivl_max <= PERIOD + JITTER_LIMIT,
                       "accept interval within fixed jitter budget");
        end
        check_eq(fin_min, 17, "fixed minimum FIR latency");
        check_eq(fin_max, 17, "fixed maximum FIR latency");
        for (i = 0; i < N; i = i + 1)
            if (i < 4 || i >= N - 2)
                $display("INFO s[%3d] x=%6d tick@%0d isr@+%0d accept@+%0d fir_done@+%0d stored@+%0d y=%8d ref=%8d",
                         i, $signed(x_in[i]), tick_t[i], take_after_tick[i] - tick_t[i], acc_t[i] - tick_t[i],
                         fin_t[i] - tick_t[i], st_t[i] - tick_t[i], $signed(sdram_word(out_off + 4 * i)), $signed(y_exp[i]));
        $display("INFO Timer: %0d ticks, first %0d clocks after enable, interval min %0d max %0d clocks",
                 tick_n, first_gap, gap_min, gap_max);
        $display("INFO latency (clocks) tick->ISR entry: min %0d avg %0d max %0d", lat_take_min,
                 take_sum / N, lat_take_max);
        $display("INFO latency (clocks) tick->FIR accepts DATA_IN: min %0d avg %0d max %0d, jitter %0d clocks (%0d ns)",
                 lat_min, lat_sum / N, lat_max, lat_max - lat_min, (lat_max - lat_min) * 10);
        $display("INFO DATA_IN accept interval: min %0d max %0d clocks (Timer PERIOD %0d)", ivl_min, ivl_max, PERIOD);
        $display("INFO FIR processing (accept -> ap_done): min %0d max %0d clocks", fin_min, fin_max);
        $display("INFO latency (clocks) tick->output stored in RAM (AXI B): min %0d avg %0d max %0d; longest ISR RAM transaction %0d",
                 st_min, st_sum / N, st_max, isr_ram_age_max);
        $display("INFO IRQ: taken %0d = Timer ISR %0d + FIR ISR %0d; Timer events %0d + coalesced %0d; FIR events %0d; ACK %0d; mret %0d; both pending %0d cycles",
                 take_n, isr_tim, isr_fir, tim_events, tim_coal, fir_events, ack_n, mret_n, both_pending);
        $display("INFO samples: flush %0d, accepted %0d, finished %0d, DATA_OUT reads %0d, input reads %0d, output stores %0d, readback %0d; BUSY writes %0d, OVERRUN %0d",
                 main_din, accept_n - NUM_FLUSH, finish_n - NUM_FLUSH, dout_rd_n - NUM_FLUSH, in_rd_n, out_wr_n, rb_n,
                 busy_wr, overrun_seen);
        $display("INFO deadlines: missed tb %0d / fst %0d, accepted after next tick %0d, backlog max tb %0d / fst %0d, coalesced tb %0d / fst %0d",
                 tb_missed, dmem(S_FST + 4 * F_MISSED), late_accept, tb_backlog_max, dmem(S_FST + 4 * F_BACKLOG),
                 tim_coal, dmem(S_FST + 4 * F_COAL));
        $display("INFO bus: CPU requests %0d (wr %0d rd %0d) = MMIO %0d + RAM %0d; cache_top requests %0d; longest CPU bus transaction %0d clocks",
                 req_n, req_wr_n, req_rd_n, mmio_axi_n, ram_axi_n, ram_req_n, req_age_max);
        $display("INFO context: %0d ISR register-file comparisons, %0d differences, min sp 0x%08h",
                 ctx_checks, ctx_errors, sp_min);
        $display("Checks: %0d, errors: %0d, cycles to HALT: %0d, USE_CACHE=%0d, PERIOD=%0d",
                 checks, errors, halt_cyc, USE_CACHE, PERIOD);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

endmodule
