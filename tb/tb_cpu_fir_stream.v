`timescale 1ns/1ps

//======================================================================
// tb_cpu_fir_stream : firmware C (GCC) gửi 32 mẫu DMEM -> FIR11 HLS qua AXI
//======================================================================
// Firmware: firmware/fir_stream.c + startup.S + linker.ld, build bằng
//   python scripts/build_firmware.py --firmware fir_stream
//   -> firmware/build/fir_stream/program.mem, data.mem, symbols.mem
// CPU tự nạp program.mem / data.mem ($readmemh). Testbench KHÔNG ghi lệnh, KHÔNG
// gửi dữ liệu vào FIR, KHÔNG force/deposit; chỉ đọc file và quan sát tín hiệu.
// symbols.mem (build script đọc từ ELF): [0] fir_input [1] fir_output
//   [2] fir_expected [3] __stack_limit [4] __stack_top
//
// Dữ liệu vào: 32 mẫu lấy từ image data.mem tại fir_input (stimulus). Kết quả kỳ
// vọng do testbench tự tính (mô hình #2, Verilog): y[n] = sum c[k]*x[n-k],
// c từ fir.cpp (đối chiếu ROM của IP), lịch sử đầu = .dat shift_reg của IP,
// số học 32 bit modulo 2^32 như RTL HLS. Bảng fir_expected của firmware
// (mô hình #1, scripts/gen_fir_stream_data.py) được so với mô hình #2.
//
// Quan sát (mỗi giao dịch phải qua đủ các tầng đúng một lần):
//   CPU   : yêu cầu bus mới (requested), bus_ready (completed), địa chỉ giữ ổn định
//           khi stall; lw fir_input[i] / sw fir_output[i] trong DMEM
//   AXI   : AW/AR (accepted), W, B/R (completed) ở cổng cpu_axi_master
//   FIR   : fir_wr_en / fir_rd_en, đúng 1 xung mỗi giao dịch AXI
//   HLS   : accept của wrapper, x_q, ap_done, y/y_ap_vld
//
// Scoreboard giao thức: STATUS* (BUSY=0) -> CTRL=1 ->
//   42 lần { [lw fir_input[i]] -> STATUS* (BUSY=0) -> DATA_IN=x -> STATUS* (DONE=1)
//            -> DATA_OUT -> STATUS (DONE=0, BUSY=0) -> [sw fir_output[i]] }
//   (10 mẫu 0 làm sạch lịch sử, rồi 32 mẫu fir_input[0..31]); sau đó không còn giao dịch.
//
// PASS chỉ khi: scoreboard đủ 42 mẫu, 32/32 output (AXI và DMEM) khớp mô hình,
//   số giao dịch các tầng bằng nhau, không OVERRUN, signature PASS + HALT, không timeout.
//
// Chạy: python scripts/run_rtl_tests.py --vivado-root <Vivado> --tests tb_cpu_fir_stream
//======================================================================

module tb_cpu_fir_stream;

    localparam IMEM_WORDS  = 256;
    localparam DMEM_WORDS  = 256;
    localparam MAX_CYCLES  = 100000;
    localparam TXN_TIMEOUT = 200;           // chu kỳ tối đa cho một giao dịch bus của CPU
    localparam TAPS        = 11;
    localparam NUM_FLUSH   = 10;
    localparam NUM_STREAM  = 32;
    localparam NUM_TOTAL   = NUM_FLUSH + NUM_STREAM;
    localparam SIG_WORDS   = 12;
    localparam MAX_ERR_MSG = 12;

    localparam [31:0] IMEM_END   = 32'h0000_0400;
    localparam [31:0] DMEM_BASE  = 32'h1000_0000;
    localparam [31:0] DMEM_END   = 32'h1000_0400;
    localparam [31:0] SIG_END    = DMEM_BASE + 4 * SIG_WORDS;
    localparam [31:0] NOP        = 32'h0000_0013;

    localparam [31:0] A_DATA_IN  = 32'h0000_0200;
    localparam [31:0] A_DATA_OUT = 32'h0000_0204;
    localparam [31:0] A_STATUS   = 32'h0000_0208;
    localparam [31:0] A_CTRL     = 32'h0000_020C;
    localparam [31:0] FIR_LO     = 32'h0000_0200;
    localparam [31:0] FIR_HI     = 32'h0000_023F;

    localparam ST_DONE_BIT = 0, ST_BUSY_BIT = 3, ST_OVERRUN_BIT = 4;

    localparam [31:0] SIG_RUNNING = 32'h4649_5233;  // "FIR3"
    localparam [31:0] SIG_PASS    = 32'h600D_C0DE;
    localparam [31:0] HALT_MAGIC  = 32'h4841_4C54;  // "HALT"
    localparam [31:0] NO_INDEX    = 32'hFFFF_FFFF;

    localparam W_STATUS = 0, W_HALT = 1, W_EXIT = 2, W_ERROR = 3, W_DONE = 4,
               W_FIRST_BAD = 5, W_MISMATCH = 6, W_ERR_IDX = 7, W_ERR_ST = 8,
               W_FLUSH = 9, W_NUM = 10, W_MAX_POLLS = 11;

    localparam SB_INIT_IDLE = 0, SB_CTRL = 1, SB_IDLE_POLL = 2, SB_DATA_IN = 3,
               SB_DONE_POLL = 4, SB_DATA_OUT = 5, SB_AFTER = 6, SB_END = 7;

    //------------------------------------------------------------
    // DUT
    //------------------------------------------------------------
    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    wire cpu_irq;
    always #5 clk = ~clk;

    soc_top dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .cpu_irq (cpu_irq)
    );

    //------------------------------------------------------------
    // Helpers
    //------------------------------------------------------------
    integer errors = 0;
    integer checks = 0;
    integer cycles = 0;

    task check_eq;
        input [31:0]     got;
        input [31:0]     exp;
        input [8*96-1:0] what;
        begin
            checks = checks + 1;
            if (got !== exp) begin
                errors = errors + 1;
                $display("ERROR %0s: got 0x%08h (%0d), exp 0x%08h (%0d)",
                         what, got, $signed(got), exp, $signed(exp));
            end
        end
    endtask

    integer mon_errors = 0;
    task mon_fail;
        input [8*96-1:0] what;
        input [31:0]     a;
        input [31:0]     b;
        begin
            mon_errors = mon_errors + 1;
            if (mon_errors <= MAX_ERR_MSG)
                $display("ERROR [cycle %0d] %0s (0x%08h, 0x%08h)", cycles, what, a, b);
        end
    endtask

    function [31:0] dmem;               // đọc DMEM theo địa chỉ CPU
        input [31:0] addr;
        begin dmem = dut.u_cpu.DMEM.memory[addr[9:2]]; end
    endfunction

    function [31:0] sigw;
        input integer idx;
        begin sigw = dut.u_cpu.DMEM.memory[idx]; end
    endfunction

    function supported;                 // giống scripts/build_firmware.py
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

    //------------------------------------------------------------
    // Image, symbol, mô hình FIR #2
    //------------------------------------------------------------
    reg [31:0] prog_ref [0:IMEM_WORDS-1];
    reg [31:0] data_ref [0:DMEM_WORDS-1];
    reg [31:0] syms     [0:4];
    reg [31:0] coef_rom [0:TAPS-1];
    reg [31:0] hist_dat [0:TAPS-1];
    integer    coef [0:TAPS-1];
    integer    hist [0:TAPS-1];
    integer    i, k;

    reg [31:0] in_addr, out_addr, exp_addr, stack_limit, stack_top;

    initial begin
        for (i = 0; i < IMEM_WORDS; i = i + 1) prog_ref[i] = 32'hxxxx_xxxx;
        for (i = 0; i < DMEM_WORDS; i = i + 1) data_ref[i] = 32'hxxxx_xxxx;
        for (i = 0; i < 5; i = i + 1) syms[i] = 32'hxxxx_xxxx;
        for (i = 0; i < TAPS; i = i + 1) begin coef_rom[i] = 32'hxxxx_xxxx; hist_dat[i] = 32'hxxxx_xxxx; end
        $readmemh("program.mem", prog_ref);
        $readmemh("data.mem", data_ref);
        $readmemh("symbols.mem", syms);
        $readmemh("fir_fir_Pipeline_Shift_Accum_Loop_fir_int_int_c_ROM_AUTO_1R.dat", coef_rom);
        $readmemh("fir_fir_Pipeline_Shift_Accum_Loop_shift_reg_RAM_AUTO_1R1W.dat", hist_dat);
        coef[0] = 54;  coef[1] = 0;   coef[2] = -92; coef[3] = 0;   coef[4] = 313; coef[5] = 500;
        coef[6] = 313; coef[7] = 0;   coef[8] = -92; coef[9] = 0;   coef[10] = 54;
    end

    function [31:0] model_push;         // y = sum c[k] * x[n-k], 32 bit modulo 2^32
        input [31:0] x;
        integer j;
        reg [31:0] acc;
        begin
            for (j = TAPS - 1; j > 0; j = j - 1) hist[j] = hist[j-1];
            hist[0] = x;
            acc = 32'd0;
            for (j = 0; j < TAPS; j = j + 1) acc = acc + coef[j] * hist[j];
            model_push = acc;
        end
    endfunction

    //------------------------------------------------------------
    // Monitor + scoreboard
    //------------------------------------------------------------
    // Đếm theo tầng: requested (CPU) / accepted (AW, AR) / completed (B, R, bus_ready)
    integer req_n = 0, req_wr_n = 0, req_rd_n = 0;
    integer cpu_done_n = 0, cpu_wr_n = 0, cpu_rd_n = 0;
    integer aw_n = 0, w_n = 0, b_n = 0, ar_n = 0, r_n = 0;
    integer fir_wr_n = 0, fir_rd_n = 0, other_en_n = 0;
    integer accept_n = 0, hls_done_n = 0, hls_vld_n = 0;
    integer data_in_wr_n = 0, status_rd_n = 0, data_out_rd_n = 0, ctrl_wr_n = 0;

    // Yêu cầu bus của CPU đang chờ
    reg        req_open;
    reg [31:0] req_addr;
    reg        req_is_wr;
    integer    req_age = 0, req_age_max = 0, txn_timeouts = 0;

    // Giao dịch AXI đang chạy
    reg        wr_open, rd_open, cur_w_seen;
    reg [31:0] cur_awaddr, cur_wdata, cur_araddr;
    integer    cur_fir_wr, cur_fir_rd;
    integer    axi_done_n = 0;
    reg [31:0] last_axi_addr, last_axi_rdata;
    reg        last_axi_is_wr;

    // Theo mẫu (k = 0..41; mẫu stream s = k - NUM_FLUSH)
    reg [31:0] x_sent  [0:NUM_TOTAL-1];
    reg [31:0] y_model [0:NUM_TOTAL-1];
    reg [31:0] y_read  [0:NUM_TOTAL-1];
    reg [31:0] hls_x   [0:NUM_TOTAL-1];
    reg [31:0] hls_y   [0:NUM_TOTAL-1];
    integer    polls   [0:NUM_TOTAL-1];
    integer    in_load_cnt  [0:NUM_STREAM-1];
    integer    out_store_cnt[0:NUM_STREAM-1];
    integer    in_load_n = 0, out_store_n = 0, bss_clear_n = 0;
    integer    y_mismatch_n = 0, y_first_bad = -1;
    reg        out_pending;
    integer    out_pending_idx;

    integer    sb_state = SB_INIT_IDLE;
    integer    sb_idx = 0;
    integer    sb_polls = 0, sb_max_polls = 0;
    integer    last_data_out_cycle = -1, pass_cycle = -1, running_seen = 0;

    integer    dmem_range_err = 0, wr_region_err = 0, pc_range_err = 0, illegal_err = 0;
    integer    irq_seen = 0, overrun_seen = 0, soft_rst_seen = 0, wr_busy_seen = 0;
    integer    sp_err = 0;
    reg        sp_valid;
    reg [31:0] sp_min;
    reg [31:0] last_pc [0:7];
    reg [31:0] a, d;
    integer    s;

    task sb_txn;                        // một giao dịch AXI vừa hoàn tất
        input        is_wr;
        input [31:0] addr;
        input [31:0] data;
        begin
            if (addr < FIR_LO || addr > FIR_HI)
                mon_fail("bus transaction outside FIR window", addr, data);
            if (is_wr && addr == A_DATA_IN)   data_in_wr_n  = data_in_wr_n + 1;
            if (is_wr && addr == A_CTRL)      ctrl_wr_n     = ctrl_wr_n + 1;
            if (!is_wr && addr == A_STATUS)   status_rd_n   = status_rd_n + 1;
            if (!is_wr && addr == A_DATA_OUT) data_out_rd_n = data_out_rd_n + 1;

            case (sb_state)
                SB_INIT_IDLE, SB_IDLE_POLL: begin
                    if (is_wr || addr != A_STATUS)
                        mon_fail("protocol: expected STATUS read while waiting for BUSY=0", addr, sb_idx);
                    else if (!data[ST_BUSY_BIT])
                        sb_state = (sb_state == SB_INIT_IDLE) ? SB_CTRL : SB_DATA_IN;
                end
                SB_CTRL: begin
                    if (!is_wr || addr != A_CTRL || data !== 32'd1)
                        mon_fail("protocol: expected CTRL write = 1 (clear DONE/OVERRUN)", addr, data);
                    else
                        sb_state = SB_IDLE_POLL;
                end
                SB_DATA_IN: begin
                    if (!is_wr || addr != A_DATA_IN)
                        mon_fail("protocol: expected DATA_IN write after STATUS.BUSY=0", addr, sb_idx);
                    else begin
                        if (out_pending)
                            mon_fail("new DATA_IN before fir_output[] of previous sample was stored",
                                     out_pending_idx, sb_idx);
                        if (sb_idx >= NUM_FLUSH && in_load_cnt[sb_idx - NUM_FLUSH] != 1)
                            mon_fail("DATA_IN without exactly one lw fir_input[i] before it (i, loads)",
                                     sb_idx - NUM_FLUSH, in_load_cnt[sb_idx - NUM_FLUSH]);
                        if (data !== x_sent[sb_idx]) begin
                            mon_fail("DATA_IN value wrong / out of order (got, exp)", data, x_sent[sb_idx]);
                            if (sb_idx >= NUM_FLUSH)
                                $display("ERROR stream sample %0d: DATA_IN %0d, expected fir_input[%0d] = %0d",
                                         sb_idx - NUM_FLUSH, $signed(data), sb_idx - NUM_FLUSH,
                                         $signed(x_sent[sb_idx]));
                        end
                        y_model[sb_idx] = model_push(data);
                        sb_polls = 0;
                        sb_state = SB_DONE_POLL;
                    end
                end
                SB_DONE_POLL: begin
                    if (is_wr || addr != A_STATUS)
                        mon_fail("protocol: expected STATUS poll before DATA_OUT (read before DONE?)", addr, sb_idx);
                    else begin
                        sb_polls = sb_polls + 1;
                        if (data[ST_DONE_BIT]) begin
                            polls[sb_idx] = sb_polls;
                            if (sb_polls > sb_max_polls) sb_max_polls = sb_polls;
                            if (data[ST_BUSY_BIT] || data[ST_OVERRUN_BIT])
                                mon_fail("STATUS at DONE has BUSY/OVERRUN set", data, sb_idx);
                            if (hls_done_n != sb_idx + 1)
                                mon_fail("STATUS.DONE seen but HLS ap_done count wrong (count, exp)",
                                         hls_done_n, sb_idx + 1);
                            sb_state = SB_DATA_OUT;
                        end
                    end
                end
                SB_DATA_OUT: begin
                    if (is_wr || addr != A_DATA_OUT)
                        mon_fail("protocol: expected one DATA_OUT read after STATUS.DONE=1", addr, sb_idx);
                    else begin
                        y_read[sb_idx] = data;
                        if (data !== y_model[sb_idx] || data !== hls_y[sb_idx]) begin
                            y_mismatch_n = y_mismatch_n + 1;
                            if (y_first_bad < 0) y_first_bad = sb_idx;
                            if (sb_idx >= NUM_FLUSH)
                                $display("ERROR stream sample %0d (x = %0d): DATA_OUT %0d (0x%08h), model %0d (0x%08h), HLS y %0d",
                                         sb_idx - NUM_FLUSH, $signed(x_sent[sb_idx]), $signed(data), data,
                                         $signed(y_model[sb_idx]), y_model[sb_idx], $signed(hls_y[sb_idx]));
                            else
                                $display("ERROR flush sample %0d: DATA_OUT %0d, model %0d, HLS y %0d",
                                         sb_idx, $signed(data), $signed(y_model[sb_idx]), $signed(hls_y[sb_idx]));
                        end
                        last_data_out_cycle = cycles;
                        sb_state = SB_AFTER;
                    end
                end
                SB_AFTER: begin
                    if (is_wr || addr != A_STATUS)
                        mon_fail("protocol: expected STATUS read after DATA_OUT (DATA_OUT read twice?)", addr, sb_idx);
                    else begin
                        if (data[ST_DONE_BIT] || data[ST_BUSY_BIT] || data[ST_OVERRUN_BIT])
                            mon_fail("STATUS after DATA_OUT: DONE not cleared / BUSY / OVERRUN", data, sb_idx);
                        if (sb_idx >= NUM_FLUSH) begin
                            out_pending = 1'b1;
                            out_pending_idx = sb_idx - NUM_FLUSH;
                        end
                        sb_idx = sb_idx + 1;
                        sb_state = (sb_idx == NUM_TOTAL) ? SB_END : SB_IDLE_POLL;
                    end
                end
                default:
                    mon_fail("unexpected bus transaction after the last sample", addr, data);
            endcase
        end
    endtask

    always @(posedge clk) begin
        if (dut.rst_n_sync) begin   // DUT out of reset (S1: 2-cycle synchronizer)
            cycles = cycles + 1;
            for (k = 7; k > 0; k = k - 1) last_pc[k] = last_pc[k-1];
            last_pc[0] = dut.u_cpu.if_id_pc;

            // ---- CPU ----
            if (dut.u_cpu.pc >= IMEM_END && pc_range_err < 5) begin
                pc_range_err = pc_range_err + 1;
                $display("ERROR [cycle %0d] PC 0x%08h outside 1 KB IMEM", cycles, dut.u_cpu.pc);
            end
            if (!supported(dut.u_cpu.if_id_instruction) &&
                !(cycles == 1 && dut.u_cpu.if_id_instruction == 32'd0) && illegal_err < 5) begin
                illegal_err = illegal_err + 1;
                $display("ERROR [cycle %0d] unsupported instruction in ID: PC 0x%08h instr 0x%08h",
                         cycles, dut.u_cpu.if_id_pc, dut.u_cpu.if_id_instruction);
            end
            // startup.S: la sp = auipc + addi -> chỉ kiểm tra từ khi sp đạt __stack_top lần đầu
            if (dut.u_cpu.RF.registers[2] === stack_top) sp_valid = 1'b1;
            if (sp_valid) begin
                if (dut.u_cpu.RF.registers[2] < sp_min) sp_min = dut.u_cpu.RF.registers[2];
                if ((dut.u_cpu.RF.registers[2] < stack_limit || dut.u_cpu.RF.registers[2] > stack_top) &&
                    sp_err < 5) begin
                    sp_err = sp_err + 1;
                    $display("ERROR [cycle %0d] sp 0x%08h outside stack [0x%08h, 0x%08h]", cycles,
                             dut.u_cpu.RF.registers[2], stack_limit, stack_top);
                end
            end
            if (cpu_irq || dut.u_cpu.in_irq) irq_seen = irq_seen + 1;
            if (sigw(W_STATUS) === SIG_RUNNING) running_seen = 1;
            if (sigw(W_STATUS) === SIG_PASS && pass_cycle < 0) pass_cycle = cycles;

            // ---- DMEM: lw fir_input[i], sw fir_output[i], vùng ghi hợp lệ ----
            a = dut.u_cpu.ex_mem_alu_result;
            if (dut.u_cpu.dmem_read || dut.u_cpu.dmem_write) begin
                if (a < DMEM_BASE || a >= DMEM_END) begin
                    if (dmem_range_err < 5)
                        $display("ERROR [cycle %0d] DMEM %0s at 0x%08h outside window", cycles,
                                 dut.u_cpu.dmem_write ? "write" : "read", a);
                    dmem_range_err = dmem_range_err + 1;
                end
            end
            if (dut.u_cpu.dmem_read && a >= in_addr && a < in_addr + 4 * NUM_STREAM) begin
                s = (a - in_addr) >> 2;
                in_load_n = in_load_n + 1;
                in_load_cnt[s] = in_load_cnt[s] + 1;
                if (sb_state != SB_IDLE_POLL || sb_idx < NUM_FLUSH || s != sb_idx - NUM_FLUSH)
                    mon_fail("lw fir_input[i] out of order (i, expected sample k)", s, sb_idx);
                if (dut.u_cpu.dmem_rdata !== x_sent[NUM_FLUSH + s])
                    mon_fail("lw fir_input[i] returned a value != image (data, exp)",
                             dut.u_cpu.dmem_rdata, x_sent[NUM_FLUSH + s]);
            end
            if (dut.u_cpu.dmem_write) begin
                d = dut.u_cpu.ex_mem_write_data;
                if (a >= out_addr && a < out_addr + 4 * NUM_STREAM) begin
                    s = (a - out_addr) >> 2;
                    if (axi_done_n == 0) begin             // startup.S xóa .bss
                        bss_clear_n = bss_clear_n + 1;
                        if (d !== 32'd0)
                            mon_fail("store to fir_output[] before any FIR transaction is not 0", s, d);
                    end else begin
                        out_store_n = out_store_n + 1;
                        out_store_cnt[s] = out_store_cnt[s] + 1;
                        if (!out_pending || s != out_pending_idx)
                            mon_fail("sw fir_output[i] not right after DATA_OUT of sample i (i, pending)",
                                     s, out_pending_idx);
                        else if (d !== y_read[NUM_FLUSH + s]) begin
                            mon_fail("sw fir_output[i] value != DATA_OUT read over AXI (data, axi)",
                                     d, y_read[NUM_FLUSH + s]);
                            $display("ERROR stream sample %0d: fir_output store %0d != DATA_OUT %0d",
                                     s, $signed(d), $signed(y_read[NUM_FLUSH + s]));
                        end
                        out_pending = 1'b0;
                    end
                end else if (!((a >= DMEM_BASE && a < SIG_END) || (a >= stack_limit && a < stack_top))) begin
                    wr_region_err = wr_region_err + 1;
                    if (wr_region_err <= 5)
                        $display("ERROR [cycle %0d] DMEM write 0x%08h outside signature/fir_output/stack (data 0x%08h)",
                                 cycles, a, d);
                end
            end

            // ---- HLS / wrapper ----
            if (dut.u_fir.accept) begin
                accept_n = accept_n + 1;
                if (accept_n <= NUM_TOTAL && dut.write_data !== x_sent[accept_n - 1])
                    mon_fail("wrapper accepted a sample different from the expected x", dut.write_data, accept_n);
            end
            if (dut.u_fir.wr_data_in && dut.u_fir.busy_q) wr_busy_seen = wr_busy_seen + 1;
            if (dut.u_fir.overrun_q)  overrun_seen  = overrun_seen + 1;
            if (dut.u_fir.soft_rst_q) soft_rst_seen = soft_rst_seen + 1;
            if (dut.u_fir.ap_done) begin
                hls_done_n = hls_done_n + 1;
                if (!dut.u_fir.busy_q)
                    mon_fail("HLS ap_done without a transaction in flight", hls_done_n, 0);
            end
            if (dut.u_fir.hls_y_ap_vld) begin
                if (hls_vld_n < NUM_TOTAL) begin
                    hls_x[hls_vld_n] = dut.u_fir.x_q;
                    hls_y[hls_vld_n] = dut.u_fir.hls_y;
                    if (dut.u_fir.x_q !== x_sent[hls_vld_n])
                        mon_fail("HLS IP computed with x != sample sent (x, k)", dut.u_fir.x_q, hls_vld_n);
                end
                hls_vld_n = hls_vld_n + 1;
            end

            // ---- Interconnect -> ngoại vi ----
            if (dut.timer_wr_en || dut.timer_rd_en || dut.interrupt_wr_en || dut.interrupt_rd_en) begin
                other_en_n = other_en_n + 1;
                mon_fail("timer/interrupt register access (firmware only talks to FIR)", dut.write_addr, dut.read_addr);
            end
            if (dut.fir_wr_en) begin
                fir_wr_n = fir_wr_n + 1;
                cur_fir_wr = cur_fir_wr + 1;
                if (!wr_open || !cur_w_seen)
                    mon_fail("fir_wr_en outside an AXI write", dut.write_addr, dut.write_data);
                if (dut.write_addr !== cur_awaddr || dut.write_data !== cur_wdata)
                    mon_fail("fir_wr_en addr/data != AXI AW/W", dut.write_addr, dut.write_data);
            end
            if (dut.fir_rd_en) begin
                fir_rd_n = fir_rd_n + 1;
                cur_fir_rd = cur_fir_rd + 1;
                if (!rd_open)
                    mon_fail("fir_rd_en outside an AXI read", dut.read_addr, 0);
                if (dut.read_addr !== cur_araddr)
                    mon_fail("fir_rd_en read_addr != AXI ARADDR", dut.read_addr, cur_araddr);
            end

            // ---- CPU: yêu cầu bus (requested), giữ ổn định khi stall, timeout ----
            if ((dut.bus_rd || dut.bus_wr) && !req_open) begin
                req_open = 1'b1;
                req_n = req_n + 1;
                if (dut.bus_wr) req_wr_n = req_wr_n + 1; else req_rd_n = req_rd_n + 1;
                req_addr = dut.bus_addr;
                req_is_wr = dut.bus_wr;
                req_age = 0;
            end
            if (req_open) begin
                req_age = req_age + 1;
                if (req_age > req_age_max) req_age_max = req_age;
                if (!(dut.bus_rd || dut.bus_wr) || dut.bus_addr !== req_addr || dut.bus_wr !== req_is_wr)
                    mon_fail("CPU bus request changed/dropped before bus_ready", dut.bus_addr, req_addr);
                if (req_age == TXN_TIMEOUT + 1) begin
                    txn_timeouts = txn_timeouts + 1;
                    $display("ERROR TIMEOUT [cycle %0d] CPU bus %0s 0x%08h not completed within %0d cycles",
                             cycles, req_is_wr ? "write" : "read", req_addr, TXN_TIMEOUT);
                end
            end

            // ---- AXI: accepted (AW/AR), completed (B/R) ----
            if (dut.axi_awvalid && dut.axi_awready) begin
                aw_n = aw_n + 1;
                if (wr_open || rd_open)
                    mon_fail("AW while another AXI transaction is open (duplicate)", dut.axi_awaddr, 0);
                if (!dut.bus_wr || dut.axi_awaddr !== dut.bus_addr)
                    mon_fail("AWADDR != CPU bus write address", dut.axi_awaddr, dut.bus_addr);
                wr_open = 1'b1; cur_w_seen = 1'b0; cur_fir_wr = 0;
                cur_awaddr = dut.axi_awaddr;
            end
            if (dut.axi_wvalid && dut.axi_wready) begin
                w_n = w_n + 1;
                if (!wr_open || cur_w_seen)
                    mon_fail("W without matching AW or duplicate W", dut.axi_wdata, 0);
                if (dut.axi_wdata !== dut.bus_wdata || dut.axi_wstrb !== 4'b1111)
                    mon_fail("WDATA/WSTRB != CPU bus write data", dut.axi_wdata, dut.bus_wdata);
                cur_w_seen = 1'b1;
                cur_wdata = dut.axi_wdata;
            end
            if (dut.axi_bvalid && dut.axi_bready) begin
                b_n = b_n + 1;
                if (!wr_open || !cur_w_seen)
                    mon_fail("B without AW/W", 0, 0);
                if (dut.axi_bresp !== 2'b00)
                    mon_fail("BRESP not OKAY", dut.axi_bresp, cur_awaddr);
                if (cur_fir_wr != 1)
                    mon_fail("AXI write did not produce exactly one fir_wr_en (count, addr)", cur_fir_wr, cur_awaddr);
                wr_open = 1'b0;
                axi_done_n = axi_done_n + 1;
                last_axi_is_wr = 1'b1; last_axi_addr = cur_awaddr;
                sb_txn(1'b1, cur_awaddr, cur_wdata);
            end
            if (dut.axi_arvalid && dut.axi_arready) begin
                ar_n = ar_n + 1;
                if (wr_open || rd_open)
                    mon_fail("AR while another AXI transaction is open (duplicate)", dut.axi_araddr, 0);
                if (!dut.bus_rd || dut.axi_araddr !== dut.bus_addr)
                    mon_fail("ARADDR != CPU bus read address", dut.axi_araddr, dut.bus_addr);
                rd_open = 1'b1; cur_fir_rd = 0;
                cur_araddr = dut.axi_araddr;
            end
            if (dut.axi_rvalid && dut.axi_rready) begin
                r_n = r_n + 1;
                if (!rd_open)
                    mon_fail("R without AR", dut.axi_rdata, 0);
                if (dut.axi_rresp !== 2'b00)
                    mon_fail("RRESP not OKAY", dut.axi_rresp, cur_araddr);
                if (cur_fir_rd != 1)
                    mon_fail("AXI read did not produce exactly one fir_rd_en (count, addr)", cur_fir_rd, cur_araddr);
                rd_open = 1'b0;
                axi_done_n = axi_done_n + 1;
                last_axi_is_wr = 1'b0; last_axi_addr = cur_araddr; last_axi_rdata = dut.axi_rdata;
                sb_txn(1'b0, cur_araddr, dut.axi_rdata);
            end

            // ---- CPU: completed (bus_ready = xung mem_ready) ----
            if (dut.bus_ready) begin
                if (!req_open)
                    mon_fail("bus_ready without a CPU bus request", 0, 0);
                else begin
                    cpu_done_n = cpu_done_n + 1;
                    if (dut.bus_wr) cpu_wr_n = cpu_wr_n + 1; else cpu_rd_n = cpu_rd_n + 1;
                    if (axi_done_n != cpu_done_n)
                        mon_fail("CPU bus completions != AXI completions (cpu, axi)", cpu_done_n, axi_done_n);
                    if (dut.bus_addr !== last_axi_addr || dut.bus_wr !== last_axi_is_wr)
                        mon_fail("CPU bus request != last AXI transaction", dut.bus_addr, last_axi_addr);
                    if (dut.bus_rd && dut.bus_rdata !== last_axi_rdata)
                        mon_fail("CPU bus_rdata != AXI RDATA", dut.bus_rdata, last_axi_rdata);
                end
                req_open = 1'b0;
            end
        end
    end

    //------------------------------------------------------------
    // Test sequence
    //------------------------------------------------------------
    integer    done_cycle;
    integer    cnt, pos_n, neg_n, zero_n, flip_n;
    reg [31:0] snap [0:SIG_WORDS-1];
    reg [31:0] y_dmem;

    task dump_state;
        begin
            $display("  PC = 0x%08h, ID: PC 0x%08h instr 0x%08h, sp = 0x%08h, ra = 0x%08h",
                     dut.u_cpu.pc, dut.u_cpu.if_id_pc, dut.u_cpu.if_id_instruction,
                     dut.u_cpu.RF.registers[2], dut.u_cpu.RF.registers[1]);
            $display("  last 8 ID PCs: %h %h %h %h %h %h %h %h", last_pc[0], last_pc[1],
                     last_pc[2], last_pc[3], last_pc[4], last_pc[5], last_pc[6], last_pc[7]);
            $display("  scoreboard: state %0d sample k=%0d polls %0d, bus req open %0d age %0d",
                     sb_state, sb_idx, sb_polls, req_open, req_age);
            $display("  signature: status 0x%08h halt 0x%08h exit %0d error %0d done %0d first_bad 0x%08h mismatches %0d err_idx 0x%08h err_status 0x%08h",
                     sigw(W_STATUS), sigw(W_HALT), $signed(sigw(W_EXIT)), sigw(W_ERROR), sigw(W_DONE),
                     sigw(W_FIRST_BAD), sigw(W_MISMATCH), sigw(W_ERR_IDX), sigw(W_ERR_ST));
        end
    endtask

    initial begin : watchdog
        #((MAX_CYCLES + 1000) * 10);
        $display("ERROR TIMEOUT: watchdog");
        $display("TEST FAILED: watchdog");
        $finish;
    end

    initial begin
        for (k = 0; k < 8; k = k + 1) last_pc[k] = 32'd0;
        for (k = 0; k < NUM_TOTAL; k = k + 1) begin
            x_sent[k] = 32'd0; y_model[k] = 32'hxxxx_xxxx; y_read[k] = 32'hxxxx_xxxx;
            hls_x[k] = 32'hxxxx_xxxx; hls_y[k] = 32'hxxxx_xxxx; polls[k] = 0;
        end
        for (k = 0; k < NUM_STREAM; k = k + 1) begin in_load_cnt[k] = 0; out_store_cnt[k] = 0; end
        req_open = 1'b0; req_addr = 32'd0; req_is_wr = 1'b0;
        wr_open = 1'b0; rd_open = 1'b0; cur_w_seen = 1'b0; cur_fir_wr = 0; cur_fir_rd = 0;
        last_axi_addr = 32'hxxxx_xxxx; last_axi_rdata = 32'hxxxx_xxxx; last_axi_is_wr = 1'b0;
        out_pending = 1'b0; out_pending_idx = -1;
        sp_min = 32'hFFFF_FFFF; sp_valid = 1'b0;

        #1;   // $readmemh ở t = 0
        if (prog_ref[0] === 32'hxxxx_xxxx || data_ref[0] === 32'hxxxx_xxxx || syms[4] === 32'hxxxx_xxxx ||
            coef_rom[0] === 32'hxxxx_xxxx || hist_dat[0] === 32'hxxxx_xxxx) begin
            $display("TEST FAILED: cannot read program.mem / data.mem / symbols.mem / FIR .dat in the simulation directory");
            $finish;
        end
        in_addr = syms[0]; out_addr = syms[1]; exp_addr = syms[2]; stack_limit = syms[3]; stack_top = syms[4];
        $display("INFO symbols: fir_input 0x%08h fir_output 0x%08h fir_expected 0x%08h stack [0x%08h, 0x%08h)",
                 in_addr, out_addr, exp_addr, stack_limit, stack_top);

        // ---- bố trí bộ nhớ ----
        check_eq(in_addr >= SIG_END && in_addr + 4 * NUM_STREAM <= stack_limit, 1, "fir_input[32] inside DMEM, after signature, below stack");
        check_eq(out_addr >= SIG_END && out_addr + 4 * NUM_STREAM <= stack_limit, 1, "fir_output[32] inside DMEM, after signature, below stack");
        check_eq(exp_addr >= SIG_END && exp_addr + 4 * NUM_STREAM <= stack_limit, 1, "fir_expected[32] inside DMEM, after signature, below stack");
        check_eq((in_addr + 4 * NUM_STREAM <= out_addr) || (out_addr + 4 * NUM_STREAM <= in_addr), 1, "fir_input and fir_output do not overlap");
        check_eq(stack_top == DMEM_END && stack_top - stack_limit == 256, 1, "stack = last 256 bytes of DMEM");

        // ---- image nạp đúng ----
        check_eq(prog_ref[0] !== NOP, 1, "program.mem holds firmware (word 0 is not NOP)");
        cnt = 0;
        for (i = 0; i < IMEM_WORDS; i = i + 1) if (dut.u_cpu.IMEM.memory[i] !== prog_ref[i]) cnt = cnt + 1;
        check_eq(cnt, 0, "IMEM == program.mem before reset");
        cnt = 0;
        for (i = 0; i < DMEM_WORDS; i = i + 1) if (dut.u_cpu.DMEM.memory[i] !== data_ref[i]) cnt = cnt + 1;
        check_eq(cnt, 0, "DMEM == data.mem before reset");
        check_eq(sigw(W_STATUS), 0, "signature.status = 0 before the CPU runs");

        // ---- dữ liệu vào (image tại fir_input) ----
        pos_n = 0; neg_n = 0; zero_n = 0; flip_n = 0;
        for (i = 0; i < NUM_STREAM; i = i + 1) begin
            x_sent[NUM_FLUSH + i] = data_ref[(in_addr - DMEM_BASE) / 4 + i];
            if ($signed(x_sent[NUM_FLUSH + i]) > 0) pos_n = pos_n + 1;
            if ($signed(x_sent[NUM_FLUSH + i]) < 0) neg_n = neg_n + 1;
            if (x_sent[NUM_FLUSH + i] == 0) zero_n = zero_n + 1;
            if (i > 0 && ($signed(x_sent[NUM_FLUSH + i]) > 0) && ($signed(x_sent[NUM_FLUSH + i - 1]) < 0)) flip_n = flip_n + 1;
            if (i > 0 && ($signed(x_sent[NUM_FLUSH + i]) < 0) && ($signed(x_sent[NUM_FLUSH + i - 1]) > 0)) flip_n = flip_n + 1;
        end
        check_eq(pos_n > 0 && neg_n > 0 && zero_n > 0 && flip_n > 0, 1, "input has positive, negative, zero and sign changes");
        $display("INFO input: %0d positive, %0d negative, %0d zero, %0d consecutive sign changes",
                 pos_n, neg_n, zero_n, flip_n);

        // ---- mô hình #2: hệ số fir.cpp == ROM IP; so với bảng mô hình #1 của firmware ----
        cnt = 0;
        for (i = 0; i < TAPS; i = i + 1) begin
            if (coef_rom[i] !== coef[i]) cnt = cnt + 1;
            hist[i] = hist_dat[i];
        end
        check_eq(cnt, 0, "IP coefficient ROM == fir.cpp coefficients");
        cnt = 0;
        for (i = 0; i < TAPS; i = i + 1) if (hist_dat[i] !== 32'd0) cnt = cnt + 1;
        check_eq(cnt, 0, "IP shift_reg initial content = 0 (from .dat)");
        for (i = 0; i < NUM_TOTAL; i = i + 1) y_model[i] = model_push(x_sent[i]);
        cnt = 0;
        for (i = 0; i < NUM_STREAM; i = i + 1)
            if (data_ref[(exp_addr - DMEM_BASE) / 4 + i] !== y_model[NUM_FLUSH + i]) begin
                cnt = cnt + 1;
                $display("ERROR model #1 (firmware fir_expected) != model #2 at stream sample %0d: %0d vs %0d", i,
                         $signed(data_ref[(exp_addr - DMEM_BASE) / 4 + i]), $signed(y_model[NUM_FLUSH + i]));
            end
        check_eq(cnt, 0, "firmware fir_expected[] (Python model) == testbench model, 32 samples");
        // scoreboard tính lại y_model từ DATA_IN thực tế: đặt lại lịch sử
        for (i = 0; i < TAPS; i = i + 1) hist[i] = hist_dat[i];
        for (i = 0; i < NUM_TOTAL; i = i + 1) y_model[i] = 32'hxxxx_xxxx;

        // ---- reset rồi chạy ----
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        while (sigw(W_HALT) !== HALT_MAGIC && cycles < MAX_CYCLES)
            @(negedge clk);
        done_cycle = cycles;

        if (sigw(W_HALT) !== HALT_MAGIC) begin
            errors = errors + 1;
            $display("ERROR TIMEOUT: firmware did not write HALT within %0d cycles", MAX_CYCLES);
            dump_state;
        end else begin
            $display("INFO firmware HALT after %0d cycles (%0d ns at 100 MHz)", done_cycle, done_cycle * 10);
            for (i = 0; i < SIG_WORDS; i = i + 1) snap[i] = sigw(i);
            repeat (200) @(negedge clk);
            cnt = 0;
            for (i = 0; i < SIG_WORDS; i = i + 1) if (sigw(i) !== snap[i]) cnt = cnt + 1;
            check_eq(cnt, 0, "signature stable after HALT");
        end

        // ---- giao dịch: scoreboard + requested / accepted / completed ----
        check_eq(mon_errors, 0, "monitor/scoreboard errors");
        check_eq(txn_timeouts, 0, "no per-transaction timeout");
        check_eq(sb_state, SB_END, "scoreboard reached the end (full protocol observed)");
        check_eq(sb_idx, NUM_TOTAL, "samples completed by the protocol (10 flush + 32)");
        check_eq(data_in_wr_n, NUM_TOTAL, "CPU wrote DATA_IN 42 times (10 x 0 + 32 samples)");
        check_eq(ctrl_wr_n, 1, "CPU wrote CTRL once");
        check_eq(data_out_rd_n, NUM_TOTAL, "CPU read DATA_OUT exactly once per sample");
        check_eq(status_rd_n >= 3 * NUM_TOTAL + 1, 1, "CPU polled STATUS (idle, DONE, after-read)");
        check_eq(req_n, cpu_done_n, "CPU bus requests (requested) == completions");
        check_eq(req_wr_n, data_in_wr_n + ctrl_wr_n, "requested writes == FIR writes");
        check_eq(req_rd_n, status_rd_n + data_out_rd_n, "requested reads == FIR reads");
        check_eq(aw_n, req_wr_n, "AXI AW accepted == requested writes");
        check_eq(ar_n, req_rd_n, "AXI AR accepted == requested reads");
        check_eq(w_n, req_wr_n, "AXI W handshakes == requested writes");
        check_eq(b_n, req_wr_n, "AXI B completed == requested writes");
        check_eq(r_n, req_rd_n, "AXI R completed == requested reads");
        check_eq(cpu_wr_n, req_wr_n, "CPU write completions (bus_ready) == requested writes");
        check_eq(cpu_rd_n, req_rd_n, "CPU read completions (bus_ready) == requested reads");
        check_eq(fir_wr_n, req_wr_n, "fir_wr_en pulses == requested writes");
        check_eq(fir_rd_n, req_rd_n, "fir_rd_en pulses == requested reads");
        check_eq(other_en_n, 0, "no timer/interrupt register access");
        check_eq(wr_open || rd_open || req_open, 0, "no transaction left open");
        // ---- DMEM: đọc input, ghi output ----
        check_eq(in_load_n, NUM_STREAM, "CPU loaded fir_input[] 32 times");
        cnt = 0;
        for (i = 0; i < NUM_STREAM; i = i + 1) if (in_load_cnt[i] != 1 || out_store_cnt[i] != 1) cnt = cnt + 1;
        check_eq(cnt, 0, "each fir_input[i] loaded once and each fir_output[i] stored once");
        check_eq(out_store_n, NUM_STREAM, "CPU stored fir_output[] 32 times (after DATA_OUT)");
        check_eq(bss_clear_n, NUM_STREAM, "startup cleared fir_output[] (.bss) before the run");
        check_eq(out_pending, 0, "last output stored");
        check_eq(wr_region_err, 0, "DMEM writes only to signature / fir_output / stack");
        check_eq(sp_valid, 1, "sp set to __stack_top by startup");
        check_eq(sp_err, 0, "sp stayed inside the stack region");
        // ---- FIR HLS ----
        check_eq(accept_n, NUM_TOTAL, "FIR wrapper accepted 42 samples");
        check_eq(hls_done_n, NUM_TOTAL, "HLS ap_done pulses");
        check_eq(hls_vld_n, NUM_TOTAL, "HLS y_ap_vld pulses");
        check_eq(wr_busy_seen, 0, "no DATA_IN write while FIR BUSY");
        check_eq(overrun_seen, 0, "FIR OVERRUN never set");
        check_eq(soft_rst_seen, 0, "no FIR soft reset");
        check_eq(irq_seen, 0, "no interrupt taken");
        // ---- 32/32 kết quả ----
        check_eq(y_mismatch_n, 0, "DATA_OUT == model == HLS y for all 42 samples");
        cnt = 0;
        for (i = 0; i < NUM_STREAM; i = i + 1) begin
            y_dmem = dmem(out_addr + 4 * i);
            if (y_dmem !== y_model[NUM_FLUSH + i]) begin
                cnt = cnt + 1;
                $display("ERROR stream sample %0d: fir_output[%0d] in DMEM = %0d (0x%08h), model %0d (0x%08h)",
                         i, i, $signed(y_dmem), y_dmem, $signed(y_model[NUM_FLUSH + i]), y_model[NUM_FLUSH + i]);
            end
        end
        check_eq(cnt, 0, "fir_output[0..31] in DMEM == model (32/32)");
        $display("INFO 32/32 compare: %0d sample(s) wrong in DMEM, %0d DATA_OUT mismatch(es)", cnt, y_mismatch_n);
        cnt = 0;
        for (i = 0; i < NUM_STREAM; i = i + 1)
            if (dmem(in_addr + 4 * i) !== x_sent[NUM_FLUSH + i]) cnt = cnt + 1;
        check_eq(cnt, 0, "fir_input[] unchanged");
        for (i = 0; i < NUM_STREAM; i = i + 1)
            $display("INFO s[%2d] x = %11d  y(AXI) = %11d  y(DMEM) = %11d  model = %11d  polls %0d  %0s", i,
                     $signed(x_sent[NUM_FLUSH + i]), $signed(y_read[NUM_FLUSH + i]),
                     $signed(dmem(out_addr + 4 * i)), $signed(y_model[NUM_FLUSH + i]), polls[NUM_FLUSH + i],
                     (y_read[NUM_FLUSH + i] === y_model[NUM_FLUSH + i] &&
                      dmem(out_addr + 4 * i) === y_model[NUM_FLUSH + i]) ? "OK" : "MISMATCH");
        $display("INFO bus: requested %0d (wr %0d, rd %0d) | AXI accepted AW %0d AR %0d, W %0d, completed B %0d R %0d | CPU completed %0d | fir_wr_en %0d fir_rd_en %0d",
                 req_n, req_wr_n, req_rd_n, aw_n, ar_n, w_n, b_n, r_n, cpu_done_n, fir_wr_n, fir_rd_n);
        $display("INFO FIR regs: DATA_IN wr %0d, CTRL wr %0d, STATUS rd %0d, DATA_OUT rd %0d; max DONE polls %0d, longest bus txn %0d cycles, min sp 0x%08h",
                 data_in_wr_n, ctrl_wr_n, status_rd_n, data_out_rd_n, sb_max_polls, req_age_max, sp_min);

        // ---- signature ----
        check_eq(running_seen, 1, "firmware wrote status = FIR3 (fir_stream main started)");
        check_eq(sigw(W_STATUS), SIG_PASS, "signature.status = PASS");
        check_eq(sigw(W_EXIT), 0, "main() returned 0");
        check_eq(sigw(W_ERROR), 0, "signature.error = 0");
        check_eq(sigw(W_DONE), NUM_STREAM, "signature.samples_done = 32");
        check_eq(sigw(W_FIRST_BAD), NO_INDEX, "signature.first_bad = none");
        check_eq(sigw(W_MISMATCH), 0, "signature.mismatches = 0");
        check_eq(sigw(W_ERR_IDX), NO_INDEX, "signature.error_index = none");
        check_eq(sigw(W_ERR_ST), 0, "signature.error_status = 0");
        check_eq(sigw(W_FLUSH), NUM_FLUSH, "signature.flush_done = 10");
        check_eq(sigw(W_NUM), NUM_STREAM, "signature.num_samples = 32");
        check_eq(sigw(W_MAX_POLLS), sb_max_polls, "signature.max_polls == max DONE polls seen on AXI");
        check_eq(pass_cycle > last_data_out_cycle && last_data_out_cycle > 0, 1,
                 "PASS written only after the final DATA_OUT read");
        $display("INFO signature: status 0x%08h exit %0d error %0d samples_done %0d first_bad 0x%08h mismatches %0d flush %0d max_polls %0d",
                 sigw(W_STATUS), $signed(sigw(W_EXIT)), sigw(W_ERROR), sigw(W_DONE), sigw(W_FIRST_BAD),
                 sigw(W_MISMATCH), sigw(W_FLUSH), sigw(W_MAX_POLLS));

        // ---- an toàn thực thi ----
        cnt = 0;
        for (i = 0; i < IMEM_WORDS; i = i + 1) if (dut.u_cpu.IMEM.memory[i] !== prog_ref[i]) cnt = cnt + 1;
        check_eq(cnt, 0, "IMEM unchanged after the run");
        check_eq(pc_range_err, 0, "PC always inside IMEM");
        check_eq(illegal_err, 0, "no unsupported instruction reached ID");
        check_eq(dmem_range_err, 0, "all DMEM load/store inside 0x10000000-0x100003FF");

        if (errors != 0) begin
            $display("State at end of test:");
            dump_state;
        end
        $display("Checks: %0d, errors: %0d, cycles to HALT: %0d", checks, errors, done_cycle);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

endmodule
