`timescale 1ns/1ps

//======================================================================
// tb_cpu_timer_irq : CPU nhận ngắt Timer periodic 10 kHz, chạy ISR, ACK, mret
//======================================================================
// Firmware: firmware/timer_irq_test.c + startup_irq.S + linker_irq.ld
//   (build_firmware.py --firmware timer_irq_test). Testbench KHÔNG ghi lệnh/dữ liệu.
// SoC: soc_top #(ENABLE_EXT_RAM = EXT_RAM, EXT_RAM_USE_CACHE = USE_CACHE), clock 100 MHz.
//   EXT_RAM=1: vòng lặp kiểm tra thanh ghi đọc/ghi RAM ngoài (stall dài, B/C);
//   EXT_RAM=0: cấu hình A (mặc định của SoC), cùng địa chỉ là vùng không map:
//   A1 -> BRESP/RRESP = DECERR, RDATA = 0 (checked exactly; every other access OKAY).
// symbols.mem (địa chỉ ELF): irq_count, spurious_count, __stack_limit, __stack_top,
//   __trap_entry, __trap_mret, __isr_end, __regtest_loop, __regtest_exit.
//
// Kiểm chứng độc lập từ tín hiệu RTL (không dựa vào firmware tự báo PASS):
//   1 Timer: tick đầu cách cạnh bật CTRL đúng 10000 clock, mọi khoảng cách đúng
//     10000, xung 1 chu kỳ, TICK_COUNT == số tick quan sát ở mọi chu kỳ, không tick
//     sau khi tắt.
//   2 irq_take: chỉ khi pending&enable Timer, không lồng (in_irq), không khi bus
//     stall; chu kỳ sau PC = 0x10 và mepc = PC lúc nhận.
//   3 ISR thật sự chạy: truy cập bus/DMEM được phân loại theo PC của lệnh ở MEM
//     (ex_mem_pc_plus_4 - 4) thuộc [__trap_entry, __isr_end): ISR chỉ đọc STATUS,
//     ghi ACK = 1 (nguồn Timer), ghi irq_count (+1) và stack. Main không bao giờ ACK.
//   4 ACK: mỗi xung ack của controller có ack_id = Timer, đang có pending, trong
//     ngữ cảnh ngắt; số ACK == số lần vào ISR.
//   5 mret: lệnh ở __trap_mret, cpu_irq đã về 0 (không vào lại ngay), chu kỳ sau
//     PC = mepc = PC lúc nhận ngắt.
//   6 Ngữ cảnh: sau MỖI lần mret quay về vòng lặp kiểm tra và khi thoát vòng lặp,
//     26 thanh ghi (x1, x5-x9, x11, x12, x14, x15-x31) đúng mẫu; sp trong stack.
//   7 IRQ đến khi CPU đang stall AXI: được giữ ở pending và được phục vụ.
//   8 Không có ISR giả / vòng lặp ISR: số lần vào ISR == số sự kiện pending mới
//     == số ACK == irq_count, spurious = 0.
//   9 Che nguồn 3 tick: 1 sự kiện pending + 2 tick gộp, TICK_COUNT tăng 3, đúng 1 ISR
//     sau khi mở; khoảng TICK_COUNT giữa hai lần vào ISR liên tiếp là 1, riêng lần đó 3.
//   Bus: mỗi yêu cầu CPU đúng 1 giao dịch AXI OKAY, không chạm FIR.
//
// Chạy: python scripts/run_rtl_tests.py --vivado-root <Vivado> \
//          --tests tb_cpu_timer_irq_a tb_cpu_timer_irq_b tb_cpu_timer_irq_c
//======================================================================

module tb_cpu_timer_irq;

    parameter USE_CACHE = 0;
    parameter EXT_RAM   = 1;

    localparam PERIOD        = 10000;            // 100 MHz / 10 kHz
    localparam MAX_CYCLES    = 400000;
    localparam TXN_TIMEOUT   = 300;
    localparam MAX_ERR_MSG   = 20;
    localparam SIG_WORDS     = 10;
    localparam REG_TEST_IRQS = 4;
    localparam MASKED_TICKS  = 3;
    localparam MAX_LOG       = 64;

    localparam [31:0] STATUS_PASS = 32'h600D_C0DE;
    localparam [31:0] HALT_MAGIC  = 32'h4841_4C54;
    localparam [31:0] MRET        = 32'h3020_0073;
    localparam [31:0] TRAP_VECTOR = 32'h0000_0010;
    localparam [31:0] DMEM_BASE   = 32'h1000_0000;
    localparam [31:0] DMEM_END    = 32'h1000_0400;
    localparam [31:0] IMEM_END    = 32'h0000_0400;

    // bus addresses (CPU address - 0x4000_0000)
    localparam [31:0] A_PERIOD   = 32'h0000_0084;
    localparam [31:0] A_CTRL     = 32'h0000_0088;
    localparam [31:0] A_TICK     = 32'h0000_008C;
    localparam [31:0] A_INT_EN   = 32'h0000_01C0;
    localparam [31:0] A_INT_PEND = 32'h0000_01C4;
    localparam [31:0] A_INT_ACK  = 32'h0000_01C8;
    localparam [31:0] A_INT_STAT = 32'h0000_01CC;
    localparam [31:0] A_RAM_RD   = 32'h0001_0000;
    localparam [31:0] A_RAM_WR   = 32'h0001_0004;

    localparam W_STATUS = 0, W_HALT = 1, W_EXIT = 2, W_PHASE = 3, W_IRQ_REG = 4, W_MASK_T0 = 5,
               W_MASK_T1 = 6, W_UNMASK = 7, W_DIS_TICK = 8, W_FINAL_TICK = 9;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    wire cpu_irq;
    always #5 clk = ~clk;                        // 100 MHz

    soc_top #(.ENABLE_EXT_RAM(EXT_RAM), .EXT_RAM_USE_CACHE(USE_CACHE)) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .cpu_irq (cpu_irq)
    );

    //------------------------------------------------------------
    // Symbols from the ELF
    //------------------------------------------------------------
    reg [31:0] sym [0:8];
    reg [31:0] S_IRQ_COUNT, S_SPURIOUS, S_STACK_LIMIT, S_STACK_TOP, S_TRAP, S_MRET, S_ISR_END,
               S_LOOP, S_EXIT;

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

    function in_isr;                             // code that runs in interrupt context
        input [31:0] pc;
        begin in_isr = (pc >= S_TRAP) && (pc < S_ISR_END); end
    endfunction

    function [31:0] pattern;                     // startup_irq.S PAT: 0xFFFFF800 | n<<5 | n
        input integer n;
        begin pattern = 32'hFFFF_F800 | (n << 5) | n; end
    endfunction

    //------------------------------------------------------------
    // Register-file check (reg_integrity_run live registers)
    //------------------------------------------------------------
    integer reg_checks = 0, reg_errors = 0, rn;
    reg [31:0] rexp;

    task check_regs;
        input [8*40-1:0] where;
        begin
            reg_checks = reg_checks + 1;
            for (rn = 1; rn < 32; rn = rn + 1) begin
                if (rn != 2 && rn != 10 && rn != 13 && rn != 3 && rn != 4) begin
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
    reg     prev_tirq = 1'b0;
    // interrupt controller
    integer pend_events = 0, coalesced = 0, masked_ticks = 0, ack_n = 0;
    // expected AXI response: OKAY, except the ext-RAM window in config A (unmapped -> DECERR)
    reg [31:0] cur_aw = 0, cur_ar = 0;
    integer    unmapped_n = 0;
    function [1:0] exp_resp; input [31:0] a;
        exp_resp = (!EXT_RAM && a >= 32'h0001_0000 && a <= 32'h0001_FFFF) ? 2'b11 : 2'b00;
    endfunction
    integer stall_ticks = 0, stall_waiting = 0, stall_served = 0, stall_lat_max = 0, stall_from = 0;
    integer irq_rise_cyc = 0, lat_max = 0;
    reg     prev_cpu_irq = 1'b0;
    // CPU interrupt
    integer take_n = 0, mret_n = 0, ret_n = 0, ret_loop_n = 0, take_stalled = 0;
    integer take_cyc  [0:MAX_LOG-1];
    reg [31:0] take_pc   [0:MAX_LOG-1];
    reg [31:0] take_tick [0:MAX_LOG-1];
    reg        chk_vec = 1'b0, chk_ret = 1'b0;
    reg [31:0] exp_mepc, ret_target;
    integer    reg_chk_at = -1, exit_checked = 0;
    // ISR evidence
    integer isr_stat_rd = 0, isr_ack_wr = 0, isr_cnt_wr = 0, spur_wr = 0, isr_bad = 0;
    // bus
    integer req_n = 0, req_wr_n = 0, req_rd_n = 0, resp_n = 0, req_age = 0, req_age_max = 0;
    integer aw_n = 0, w_n = 0, b_n = 0, ar_n = 0, r_n = 0, mmio_wr_en = 0, mmio_rd_en = 0;
    integer mmio_wr_req = 0, mmio_rd_req = 0, ram_req = 0, fir_en = 0, main_bad = 0, timeouts = 0;
    reg        req_open = 1'b0, req_is_wr = 1'b0;
    reg [31:0] req_addr = 32'd0, pc_mem, dw_addr;
    // memory / CPU sanity
    integer pc_err = 0, illegal_err = 0, dmem_err = 0, sp_err = 0;
    reg     sp_valid = 1'b0;
    reg [31:0] sp_min = 32'hFFFF_FFFF;
    reg     halted = 1'b0;
    integer halt_cyc = 0;

    always @(posedge clk) begin
        if (dut.rst_n_sync && !halted) begin   // DUT out of reset (S1)
            cyc = cyc + 1;
            pc_mem = dut.u_cpu.ex_mem_pc_plus_4 - 32'd4;

            //====================================================
            // 1. Timer
            //====================================================
            if (dut.timer_wr_en && dut.write_addr == A_CTRL) begin
                if (dut.write_data[0] && !dut.u_timer.ctrl_enable && en_edge < 0) en_edge = cyc;
                if (!dut.write_data[0] && dis_edge < 0) dis_edge = cyc;
            end
            if (dut.timer_irq) begin                 // rose after the previous edge
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
                        fail("Timer interval != 10000 clocks", (cyc - 1) - last_tick, tick_n);
                    end
                end
                last_tick = cyc - 1;
            end
            prev_tirq = dut.timer_irq;
            if (dut.u_timer.tick_count !== tick_n) begin
                tick_cnt_err = tick_cnt_err + 1;
                if (tick_cnt_err <= 3) fail("TICK_COUNT != observed ticks", dut.u_timer.tick_count, tick_n);
            end

            //====================================================
            // 2. Interrupt controller: pending events, coalescing, ACK
            //====================================================
            if (dut.u_int_ctrl.irq_rising[0]) begin
                if (dut.irq_pending[0] && !(dut.irq_ack && dut.irq_ack_id == 0))
                    coalesced = coalesced + 1;       // pending already set: merged
                else
                    pend_events = pend_events + 1;   // new request needing one ISR
                if (!dut.irq_enable[0]) masked_ticks = masked_ticks + 1;
                if (dut.u_cpu.bus_stall) begin
                    stall_ticks = stall_ticks + 1;
                    if (dut.irq_enable[0] && !dut.irq_pending[0] && !dut.u_cpu.in_irq) begin
                        stall_waiting = 1;
                        stall_from = cyc;
                    end
                end
            end
            if (dut.irq_ack) begin
                ack_n = ack_n + 1;
                if (dut.irq_ack_id !== 0) fail("ACK of a source other than Timer", dut.irq_ack_id, 0);
                if (!dut.irq_pending[0]) fail("ACK while Timer not pending", dut.irq_pending, 0);
                if (!dut.u_cpu.in_irq) fail("ACK outside interrupt context", ack_n, 0);
            end
            if (cpu_irq && !prev_cpu_irq) irq_rise_cyc = cyc;
            prev_cpu_irq = cpu_irq;

            //====================================================
            // 3. CPU: irq_take / vector / mret / return
            //====================================================
            if (chk_vec) begin
                chk_vec = 1'b0;
                if (dut.u_cpu.pc !== TRAP_VECTOR) fail("PC after irq_take != 0x10", dut.u_cpu.pc, 0);
                if (dut.u_cpu.mepc !== exp_mepc) fail("mepc != PC at irq_take", dut.u_cpu.mepc, exp_mepc);
                if (!dut.u_cpu.in_irq) fail("in_irq not set after irq_take", 0, 0);
            end
            if (chk_ret) begin
                chk_ret = 1'b0;
                ret_n = ret_n + 1;
                if (dut.u_cpu.pc !== ret_target) fail("PC after mret != mepc", dut.u_cpu.pc, ret_target);
                if (dut.u_cpu.in_irq) fail("in_irq still set after mret", 0, 0);
            end
            if (reg_chk_at == cyc) begin
                reg_chk_at = -1;
                check_regs("return from ISR into reg test loop");
            end
            if (dut.u_cpu.irq_take) begin
                if (take_n < MAX_LOG) begin
                    take_cyc[take_n] = cyc;
                    take_pc[take_n] = dut.u_cpu.pc;
                    take_tick[take_n] = dut.u_timer.tick_count;
                end
                take_n = take_n + 1;
                if (!(cpu_irq && dut.irq_pending[0] && dut.irq_enable[0]))
                    fail("irq_take without enabled pending Timer", dut.irq_pending, dut.irq_enable);
                if (dut.u_cpu.in_irq) fail("nested interrupt taken", take_n, 0);
                if (dut.u_cpu.bus_stall) begin
                    take_stalled = take_stalled + 1;
                    fail("interrupt taken during bus stall", dut.bus_addr, 0);
                end
                if (cyc - irq_rise_cyc > lat_max) lat_max = cyc - irq_rise_cyc;
                if (stall_waiting) begin
                    stall_waiting = 0;
                    stall_served = stall_served + 1;
                    if (cyc - stall_from > stall_lat_max) stall_lat_max = cyc - stall_from;
                end
                exp_mepc = dut.u_cpu.pc;
                chk_vec = 1'b1;
            end
            if (dut.u_cpu.mret_take) begin
                mret_n = mret_n + 1;
                if (dut.u_cpu.if_id_pc !== S_MRET) fail("mret outside __trap_mret", dut.u_cpu.if_id_pc, S_MRET);
                if (!dut.u_cpu.in_irq) fail("mret without interrupt context", 0, 0);
                if (cpu_irq) fail("cpu_irq still high at mret (no ACK -> immediate re-entry)", dut.irq_pending, 0);
                if (dut.u_cpu.mepc !== exp_mepc) fail("mepc changed during ISR", dut.u_cpu.mepc, exp_mepc);
                ret_target = dut.u_cpu.mepc;
                chk_ret = 1'b1;
                if (dut.u_cpu.mepc >= S_LOOP && dut.u_cpu.mepc <= S_EXIT) begin
                    ret_loop_n = ret_loop_n + 1;
                    reg_chk_at = cyc + 4;            // ISR restores retired, return instr not yet written back
                end
            end
            // loop exit: the instruction after blt really enters EX (bubbles carry pc 0)
            if (dut.u_cpu.id_ex_pc == S_EXIT && !exit_checked && S_EXIT != 0) begin
                exit_checked = 1;
                check_regs("reg test loop exit");
            end

            //====================================================
            // 4. Bus requests, classified by the PC of the MEM-stage instruction
            //====================================================
            if ((dut.bus_rd || dut.bus_wr) && !req_open) begin
                req_open = 1'b1;
                req_is_wr = dut.bus_wr;
                req_addr = dut.bus_addr;
                req_age = 0;
                req_n = req_n + 1;
                if (dut.bus_wr) req_wr_n = req_wr_n + 1; else req_rd_n = req_rd_n + 1;
                if (dut.bus_addr >= 32'h80 && dut.bus_addr < 32'h200) begin
                    if (dut.bus_wr) mmio_wr_req = mmio_wr_req + 1; else mmio_rd_req = mmio_rd_req + 1;
                end else if (dut.bus_addr >= A_RAM_RD && dut.bus_addr <= 32'h0001_FFFF)
                    ram_req = ram_req + 1;
                if (in_isr(pc_mem)) begin
                    if (!dut.u_cpu.in_irq) begin isr_bad = isr_bad + 1; fail("ISR code ran outside interrupt context", pc_mem, 0); end
                    if (!dut.bus_wr && dut.bus_addr == A_INT_STAT)
                        isr_stat_rd = isr_stat_rd + 1;
                    else if (dut.bus_wr && dut.bus_addr == A_INT_ACK) begin
                        isr_ack_wr = isr_ack_wr + 1;
                        if (dut.bus_wdata !== 32'd1) fail("ISR ACK value != Timer (1)", dut.bus_wdata, 0);
                    end else begin
                        isr_bad = isr_bad + 1;
                        fail("ISR bus access other than STATUS/ACK (RAM/FIR/...)", dut.bus_addr, pc_mem);
                    end
                end else begin
                    if (dut.bus_wr ? !((dut.bus_addr == A_PERIOD && dut.bus_wdata == PERIOD) ||
                                       (dut.bus_addr == A_CTRL && (dut.bus_wdata == 3 || dut.bus_wdata == 0)) ||
                                       (dut.bus_addr == A_INT_EN && dut.bus_wdata <= 1) ||
                                       dut.bus_addr == A_RAM_WR)
                                   : !(dut.bus_addr == A_CTRL || dut.bus_addr == A_TICK ||
                                       dut.bus_addr == A_INT_PEND || dut.bus_addr == A_RAM_RD)) begin
                        main_bad = main_bad + 1;
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
                req_open = 1'b0;
            end
            if (dut.axi_awvalid && dut.axi_awready) begin aw_n = aw_n + 1; cur_aw = dut.axi_awaddr; end
            if (dut.axi_wvalid && dut.axi_wready) begin
                w_n = w_n + 1;
                if (dut.axi_wstrb !== 4'hF) fail("WSTRB != 1111", dut.axi_wstrb, 0);
            end
            if (dut.axi_bvalid && dut.axi_bready) begin
                b_n = b_n + 1;
                // A1: config A has no external RAM -> its window is unmapped -> DECERR
                if (dut.axi_bresp !== exp_resp(cur_aw)) fail("BRESP (got, addr)", dut.axi_bresp, cur_aw);
                if (exp_resp(cur_aw) == 2'b11) unmapped_n = unmapped_n + 1;
            end
            if (dut.axi_arvalid && dut.axi_arready) begin ar_n = ar_n + 1; cur_ar = dut.axi_araddr; end
            if (dut.axi_rvalid && dut.axi_rready) begin
                r_n = r_n + 1;
                if (dut.axi_rresp !== exp_resp(cur_ar)) fail("RRESP (got, addr)", dut.axi_rresp, cur_ar);
                if (exp_resp(cur_ar) == 2'b11) begin
                    unmapped_n = unmapped_n + 1;
                    if (dut.axi_rdata !== 32'd0) fail("DECERR read data not 0", dut.axi_rdata, cur_ar);
                end
            end
            if (dut.timer_wr_en || dut.interrupt_wr_en) mmio_wr_en = mmio_wr_en + 1;
            if (dut.timer_rd_en || dut.interrupt_rd_en) mmio_rd_en = mmio_rd_en + 1;
            if (dut.fir_wr_en || dut.fir_rd_en) begin
                fir_en = fir_en + 1;
                fail("FIR accessed by IRQ firmware", dut.write_addr, dut.read_addr);
            end

            //====================================================
            // 5. DMEM writes (ISR vs main), PC, ISA, stack
            //====================================================
            dw_addr = dut.u_cpu.ex_mem_alu_result;
            if ((dut.u_cpu.dmem_read || dut.u_cpu.dmem_write) && (dw_addr < DMEM_BASE || dw_addr >= DMEM_END)) begin
                dmem_err = dmem_err + 1;
                fail("DMEM access outside window", dw_addr, pc_mem);
            end
            if (dut.u_cpu.dmem_write) begin
                if (in_isr(pc_mem)) begin
                    if (dw_addr == S_IRQ_COUNT) begin
                        isr_cnt_wr = isr_cnt_wr + 1;
                        if (dut.u_cpu.ex_mem_write_data !== isr_cnt_wr)
                            fail("ISR irq_count write != previous + 1", dut.u_cpu.ex_mem_write_data, isr_cnt_wr);
                    end else if (dw_addr == S_SPURIOUS)
                        spur_wr = spur_wr + 1;
                    else if (!(dw_addr >= S_STACK_LIMIT && dw_addr < S_STACK_TOP)) begin
                        isr_bad = isr_bad + 1;
                        fail("ISR DMEM write outside irq vars / stack", dw_addr, pc_mem);
                    end
                end else if (!((dw_addr >= DMEM_BASE && dw_addr < DMEM_BASE + 4 * SIG_WORDS) ||
                               (dw_addr >= S_STACK_LIMIT && dw_addr < S_STACK_TOP) ||
                               ((dw_addr == S_IRQ_COUNT || dw_addr == S_SPURIOUS) &&
                                dut.u_cpu.ex_mem_write_data == 0 && en_edge < 0))) begin   // .bss clear
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

            if (dut.u_cpu.DMEM.memory[W_HALT] === HALT_MAGIC) begin
                halted = 1'b1;
                halt_cyc = cyc;
            end
        end
    end

    //------------------------------------------------------------
    // Test sequence and final checks
    //------------------------------------------------------------
    integer k, d1 = 0, d3 = 0, dbad = 0;
    reg [31:0] sw;

    initial begin
        $readmemh("symbols.mem", sym);
        S_IRQ_COUNT = sym[0]; S_SPURIOUS = sym[1]; S_STACK_LIMIT = sym[2]; S_STACK_TOP = sym[3];
        S_TRAP = sym[4]; S_MRET = sym[5]; S_ISR_END = sym[6]; S_LOOP = sym[7]; S_EXIT = sym[8];
        $display("INFO symbols: irq_count 0x%08h spurious 0x%08h stack [0x%08h,0x%08h) trap 0x%08h mret 0x%08h isr_end 0x%08h loop [0x%08h,0x%08h]",
                 S_IRQ_COUNT, S_SPURIOUS, S_STACK_LIMIT, S_STACK_TOP, S_TRAP, S_MRET, S_ISR_END, S_LOOP, S_EXIT);
        check_eq(S_TRAP, TRAP_VECTOR, "__trap_entry at TRAP_VECTOR 0x10");
        check_eq(dut.u_cpu.IMEM.memory[S_MRET[9:2]], MRET, "IMEM holds mret at __trap_mret");

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        while (!halted && cyc < MAX_CYCLES) @(negedge clk);
        repeat (20) @(negedge clk);

        check_true(halted, "firmware reached HALT before timeout");
        if (!halted)
            $display("  PC 0x%08h ID pc 0x%08h instr 0x%08h in_irq %0d status 0x%08h phase %0d",
                     dut.u_cpu.pc, dut.u_cpu.if_id_pc, dut.u_cpu.if_id_instruction, dut.u_cpu.in_irq,
                     dut.u_cpu.DMEM.memory[W_STATUS], dut.u_cpu.DMEM.memory[W_PHASE]);

        // --- firmware view (secondary) ---
        check_eq(dut.u_cpu.DMEM.memory[W_STATUS], STATUS_PASS, "firmware status PASS");
        check_eq(dut.u_cpu.DMEM.memory[W_EXIT], 0, "firmware exit code 0 (failing phase)");
        check_true(dut.u_cpu.DMEM.memory[W_IRQ_REG] >= REG_TEST_IRQS, "firmware: >= 4 IRQs during register test");
        check_eq(dut.u_cpu.DMEM.memory[W_MASK_T1] - dut.u_cpu.DMEM.memory[W_MASK_T0], MASKED_TICKS,
                 "firmware: TICK_COUNT +3 while Timer masked");
        check_eq(dut.u_cpu.DMEM.memory[W_UNMASK], 1, "firmware: one ISR for the coalesced ticks");
        check_eq(dut.u_cpu.DMEM.memory[W_FINAL_TICK], dut.u_cpu.DMEM.memory[W_DIS_TICK],
                 "firmware: TICK_COUNT frozen after disable");

        // --- 1 Timer ---
        check_eq(first_gap, PERIOD, "first Timer IRQ exactly 10000 clocks after CTRL enable edge");
        check_eq(gap_bad, 0, "every Timer interval exactly 10000 clocks (ACK does not shift the phase)");
        check_eq(tick_cnt_err, 0, "TICK_COUNT == observed ticks every cycle");
        check_eq(dut.u_timer.tick_count, tick_n, "final TICK_COUNT == ticks");
        check_true(dis_edge > 0, "firmware disabled the Timer");
        check_eq(tick_after_dis, 0, "no tick after disable");
        // --- 2/3/4/5 ISR, ACK, mret ---
        check_true(take_n >= REG_TEST_IRQS + 1 + 2, "CPU took the expected number of interrupts");
        check_eq(take_stalled, 0, "no interrupt taken during a bus stall");
        check_eq(mret_n, take_n, "one mret per interrupt");
        check_eq(ret_n, take_n, "returned to mepc after every mret");
        check_eq(ack_n, take_n, "one ACK pulse (Timer) per interrupt");
        check_eq(isr_ack_wr, take_n, "ISR wrote ACK once per interrupt");
        check_eq(isr_stat_rd, take_n, "ISR read STATUS once per interrupt");
        check_eq(isr_cnt_wr, take_n, "ISR incremented irq_count once per interrupt");
        check_eq(dut.u_cpu.DMEM.memory[S_IRQ_COUNT[9:2]], take_n, "irq_count (DMEM) == interrupts taken");
        check_eq(dut.u_cpu.DMEM.memory[S_SPURIOUS[9:2]], 0, "spurious_count == 0");
        check_eq(spur_wr, 0, "no spurious ISR path");
        check_eq(isr_bad, 0, "ISR touched only STATUS/ACK/irq_count/stack");
        check_eq(pend_events, take_n, "ISR entries == new pending events (no lost / no duplicate IRQ)");
        check_eq(dut.irq_pending, 0, "nothing left pending");
        check_eq(dut.u_cpu.in_irq, 0, "CPU not left in interrupt context");
        // --- 6 context ---
        check_true(ret_loop_n >= 1, "at least one ISR returned into the register test loop");
        check_eq(reg_checks, ret_loop_n + 1, "register file checked after each return into loop + at exit");
        check_eq(exit_checked, 1, "register test loop exit observed");
        check_eq(reg_errors, 0, "26 registers intact across interrupts");
        check_eq(sp_err, 0, "sp inside the stack, 16-byte aligned");
        check_eq(dut.u_cpu.RF.registers[2], S_STACK_TOP, "sp back at __stack_top after main returned");
        // --- 7 IRQ while stalled ---
        check_true(stall_ticks >= 1, "a Timer IRQ arrived while the CPU was stalled on AXI");
        check_eq(stall_waiting, 0, "IRQ that arrived during a stall was serviced");
        check_true(lat_max < PERIOD, "IRQ latency below one period (no tick lost)");
        // --- 9 coalescing ---
        check_eq(masked_ticks, MASKED_TICKS, "3 ticks while the Timer source was masked");
        check_eq(coalesced, MASKED_TICKS - 1, "2 ticks merged into an existing pending");
        check_eq(tick_n, pend_events + coalesced, "ticks == pending events + coalesced ticks");
        for (k = 0; k < take_n && k < MAX_LOG; k = k + 1) begin
            sw = (k == 0) ? take_tick[0] : take_tick[k] - take_tick[k - 1];
            if (sw == 1) d1 = d1 + 1;
            else if (sw == MASKED_TICKS) d3 = d3 + 1;
            else dbad = dbad + 1;
        end
        check_eq(d3, 1, "exactly one ISR covered 3 ticks (after unmask)");
        check_eq(dbad, 0, "every other ISR covered exactly one tick");
        // --- bus ---
        check_eq(timeouts, 0, "no bus timeout");
        check_eq(resp_n, req_n, "CPU responses == CPU requests");
        check_eq(aw_n, req_wr_n, "AXI AW == CPU writes");
        check_eq(w_n, req_wr_n, "AXI W == CPU writes");
        check_eq(b_n, req_wr_n, "AXI B == CPU writes");
        check_eq(ar_n, req_rd_n, "AXI AR == CPU reads");
        check_eq(r_n, req_rd_n, "AXI R == CPU reads");
        check_eq(mmio_wr_en, mmio_wr_req, "one Timer/Interrupt wr_en per MMIO write");
        check_eq(mmio_rd_en, mmio_rd_req, "one Timer/Interrupt rd_en per MMIO read");
        check_eq(fir_en, 0, "FIR never accessed");
        check_eq(main_bad, 0, "main code bus accesses as expected (no ACK from main)");
        if (EXT_RAM) check_true(ram_req > 0, "register test loop used the external RAM");
        else check_true(unmapped_n > 0, "config A: ext-RAM window accesses answered DECERR (unmapped)");
        if (EXT_RAM) check_eq(unmapped_n, 0, "no DECERR with external RAM present");
        check_eq(pc_err, 0, "PC inside IMEM");
        check_eq(illegal_err, 0, "only supported instructions (+ mret at __trap_mret)");
        check_eq(dmem_err, 0, "DMEM accesses inside allowed regions");

        $display("INFO Timer: first IRQ %0d clocks after enable, interval min %0d max %0d clocks (%0d us), ticks %0d, TICK_COUNT %0d",
                 first_gap, gap_min, gap_max, gap_max / 100, tick_n, dut.u_timer.tick_count);
        $display("INFO IRQ: pending events %0d, coalesced %0d (masked ticks %0d), irq_take %0d, ISR STATUS reads %0d, ACK %0d, mret %0d, returns to mepc %0d, irq_count %0d, spurious %0d",
                 pend_events, coalesced, masked_ticks, take_n, isr_stat_rd, ack_n, mret_n, ret_n,
                 dut.u_cpu.DMEM.memory[S_IRQ_COUNT[9:2]], dut.u_cpu.DMEM.memory[S_SPURIOUS[9:2]]);
        $display("INFO context: register-file checks %0d (returns into loop %0d + exit), register errors %0d, min sp 0x%08h",
                 reg_checks, ret_loop_n, reg_errors, sp_min);
        $display("INFO stall: ticks during CPU AXI stall %0d (serviced %0d, max latency %0d clocks), max IRQ latency %0d clocks, longest bus transaction %0d clocks",
                 stall_ticks, stall_served, stall_lat_max, lat_max, req_age_max);
        $display("INFO bus: CPU requests %0d (wr %0d rd %0d), ext RAM requests %0d, MMIO wr %0d rd %0d",
                 req_n, req_wr_n, req_rd_n, ram_req, mmio_wr_req, mmio_rd_req);
        for (k = 0; k < take_n && k < MAX_LOG; k = k + 1)
            $display("INFO ISR %0d: cycle %0d, mepc 0x%08h, TICK_COUNT %0d", k + 1, take_cyc[k], take_pc[k], take_tick[k]);
        $display("Checks: %0d, errors: %0d, cycles to HALT: %0d, USE_CACHE=%0d, EXT_RAM=%0d",
                 checks, errors, halt_cyc, USE_CACHE, EXT_RAM);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

endmodule
