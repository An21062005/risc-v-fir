`timescale 1ns/1ps

//======================================================================
// tb_cpu_fir_1000 : firmware C xử lý 1000 mẫu FIR, dữ liệu trong RAM ngoài qua AXI
//======================================================================
// Firmware: firmware/fir_1000.c (build_firmware.py --firmware fir_1000)
// Dữ liệu : data_test/fir_1000/{input,expected,layout}.mem (scripts/gen_fir_1000_data.py,
//           nguồn data_test/fir_test/output/test_04_noise/input.dat, 1000 mẫu)
// SoC     : soc_top #(ENABLE_EXT_RAM=1, EXT_RAM_USE_CACHE=USE_CACHE)
//           USE_CACHE=0: cấu hình B (không cache), 1: cấu hình C (cache write-through)
//
// Testbench CHỈ nạp dữ liệu kích thích input.mem vào sdram_model trước khi thả reset
// (sdram_model không có $readmemh). Không ghi output, không gửi gì vào FIR, không
// force/deposit; chương trình do CPU tự nạp từ program.mem.
//
// Kiểm chứng (cpu_soc_monitor.vh + scoreboard dưới đây):
//   - requested / accepted / completed / responded bằng nhau; mỗi giao dịch FIR có
//     đúng 1 fir_*_en, mỗi giao dịch RAM đúng 1 yêu cầu + 1 ready tới cache_top
//   - giao thức FIR (Bước 3): STATUS* (BUSY=0) -> CTRL=1 -> 1010 lần
//     { [lw input[i]] STATUS* (BUSY=0) -> DATA_IN -> STATUS* (DONE) -> DATA_OUT ->
//       STATUS (DONE=0) -> [sw output[i]] }  (10 mẫu 0 làm sạch + 1000 mẫu)
//   - lw input[i]: địa chỉ IN_ADDR + 4i tăng dần, đúng một lần, ngay trước DATA_IN của mẫu i,
//     dữ liệu = input.mem[i]; sw output[i]: OUT_ADDR + 4i, ngay sau DATA_OUT, dữ liệu = DATA_OUT
//   - sau 1000 mẫu firmware đọc lại output[0..999] tăng dần
//   - y kỳ vọng: mô hình #2 (Verilog) từ DATA_IN thực tế; mô hình #2 == expected.mem (#1, Python)
//   - cuối test: RAM ngoài: input không đổi, output[i] == mô hình, mọi word khác vẫn 0
//   - signature PASS + HALT, checksum khớp số liệu testbench tự tính
//
// Chạy: python scripts/run_rtl_tests.py --vivado-root <Vivado> --tests tb_cpu_fir_1000 [tb_cpu_fir_1000_c]
//======================================================================

module tb_cpu_fir_1000;

    parameter USE_CACHE = 0;

    // Bước 3: ~150 chu kỳ/mẫu chỉ với FIR; RAM ngoài thêm ~3 truy cập x 25-90 chu kỳ/mẫu.
    // Ước tính <= 400 chu kỳ/mẫu -> 1010 mẫu ~ 400k; watchdog 1.5M (gấp ~3.7 lần).
    localparam MAX_CYCLES  = 1500000;
    localparam TXN_TIMEOUT = 300;       // Bước 4a đo: dài nhất 44 (B) / 86 (C) chu kỳ
    localparam MAX_ERR_MSG = 12;
    localparam SIG_WORDS   = 15;
    localparam IMEM_WORDS  = 256;
    localparam DMEM_WORDS  = 256;
    localparam RAM_WORDS   = 16384;
    localparam TAPS        = 11;
    localparam NUM_FLUSH   = 10;
    localparam N           = 1000;
    localparam NUM_TOTAL   = NUM_FLUSH + N;

    localparam [31:0] A_DATA_IN  = 32'h0000_0200;
    localparam [31:0] A_DATA_OUT = 32'h0000_0204;
    localparam [31:0] A_STATUS   = 32'h0000_0208;
    localparam [31:0] A_CTRL     = 32'h0000_020C;
    localparam [31:0] CPU_RAM_LO = 32'h4001_0000;
    localparam [31:0] CPU_RAM_HI = 32'h4001_FFFF;
    localparam ST_DONE_BIT = 0, ST_BUSY_BIT = 3, ST_OVERRUN_BIT = 4;

    localparam [31:0] SIG_RUNNING = 32'h4631_4B30;  // "F1K0"
    localparam [31:0] SIG_PASS    = 32'h600D_C0DE;
    localparam [31:0] HALT_MAGIC  = 32'h4841_4C54;
    localparam [31:0] NO_INDEX    = 32'hFFFF_FFFF;
    localparam [31:0] NOP         = 32'h0000_0013;

    localparam W_STATUS = 0, W_HALT = 1, W_EXIT = 2, W_ERROR = 3, W_DONE = 4, W_ERR_IDX = 5,
               W_ERR_ST = 6, W_FLUSH = 7, W_NUM = 8, W_MAX_POLLS = 9, W_IN_SUM = 10,
               W_OUT_SUM = 11, W_OUT_XOR = 12, W_RB_SUM = 13, W_RB_XOR = 14;

    localparam SB_INIT_IDLE = 0, SB_CTRL = 1, SB_IDLE_POLL = 2, SB_DATA_IN = 3,
               SB_DONE_POLL = 4, SB_DATA_OUT = 5, SB_AFTER = 6, SB_END = 7;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    wire cpu_irq;
    always #5 clk = ~clk;

    soc_top #(.ENABLE_EXT_RAM(1), .EXT_RAM_USE_CACHE(USE_CACHE)) dut (
        .clk     (clk),
        .rst_n   (rst_n),
        .cpu_irq (cpu_irq)
    );

    reg [31:0] stack_limit, stack_top;

    `include "cpu_soc_monitor.vh"

    function dmem_wr_allowed;           // firmware chỉ ghi signature + stack
        input [31:0] a;
        begin dmem_wr_allowed = 1'b0; end
    endfunction

    //------------------------------------------------------------
    // Dữ liệu, bố trí, mô hình FIR #2
    //------------------------------------------------------------
    reg [31:0] x_in     [0:N-1];        // input.mem (kích thích)
    reg [31:0] y_exp1   [0:N-1];        // expected.mem (mô hình #1, Python)
    reg [31:0] layout   [0:5];
    reg [31:0] coef_rom [0:TAPS-1];
    reg [31:0] hist_dat [0:TAPS-1];
    integer    coef [0:TAPS-1];
    integer    hist [0:TAPS-1];
    reg [31:0] in_off, out_off;         // offset trong RAM ngoài (bus - 0x1_0000)

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

    function [31:0] sdram_word;         // word tại offset o: halfword thấp ở o/2, cao ở o/2+1
        input [31:0] o;
        begin
            sdram_word = {dut.g_ext_ram.u_ext_mem.U_SDRAM.MEMORY.memory[(o >> 1) + 1],
                          dut.g_ext_ram.u_ext_mem.U_SDRAM.MEMORY.memory[o >> 1]};
        end
    endfunction

    //------------------------------------------------------------
    // Scoreboard
    //------------------------------------------------------------
    reg [31:0] x_sent  [0:NUM_TOTAL-1];
    reg [31:0] y_model [0:NUM_TOTAL-1];
    reg [31:0] y_read  [0:NUM_TOTAL-1];
    reg [31:0] hls_x   [0:NUM_TOTAL-1];
    reg [31:0] hls_y   [0:NUM_TOTAL-1];
    integer    in_load_cnt  [0:N-1];
    integer    out_store_cnt[0:N-1];

    integer    sb_state = SB_INIT_IDLE, sb_idx = 0, sb_polls = 0, sb_max_polls = 0;
    integer    data_in_wr_n = 0, ctrl_wr_n = 0, status_rd_n = 0, data_out_rd_n = 0;
    integer    in_load_n = 0, out_store_n = 0, rb_n = 0, ram_bad_n = 0;
    integer    y_mismatch_n = 0, hls_x_bad = 0;
    reg        out_pending;
    integer    out_pending_idx;
    integer    first_in_cycle = -1, last_out_cycle = -1, last_data_out_cycle = -1;
    integer    pass_cycle = -1, running_seen = 0;
    reg [31:0] tb_in_sum, tb_out_sum, tb_out_xor, tb_rb_sum, tb_rb_xor;
    reg [31:0] off;
    integer    s;

    task on_txn;
        input        is_wr;
        input [31:0] addr;
        input [31:0] data;
        begin
            if (is_ram(addr)) begin
                off = addr - MON_RAM_LO;
                if (!is_wr && off >= in_off && off < in_off + 4 * N && off[1:0] == 2'b00) begin
                    // ---- lw input[i] ----
                    s = (off - in_off) >> 2;
                    in_load_n = in_load_n + 1;
                    in_load_cnt[s] = in_load_cnt[s] + 1;
                    if (first_in_cycle < 0) first_in_cycle = cycles;
                    tb_in_sum = tb_in_sum + data;
                    if (sb_state != SB_IDLE_POLL || sb_idx < NUM_FLUSH || s != sb_idx - NUM_FLUSH)
                        mon_fail("lw input[i] out of order (i, next sample k)", s, sb_idx);
                    if (data !== x_in[s]) begin
                        mon_fail("lw input[i] data != input.mem (data, exp)", data, x_in[s]);
                        $display("ERROR sample %0d: input read from RAM %0d, input.mem %0d",
                                 s, $signed(data), $signed(x_in[s]));
                    end
                end else if (is_wr && off >= out_off && off < out_off + 4 * N && off[1:0] == 2'b00) begin
                    // ---- sw output[i] ----
                    s = (off - out_off) >> 2;
                    out_store_n = out_store_n + 1;
                    out_store_cnt[s] = out_store_cnt[s] + 1;
                    last_out_cycle = cycles;
                    if (!out_pending || s != out_pending_idx) begin
                        mon_fail("sw output[i] not right after DATA_OUT of sample i (wrong address?) (i, pending)",
                                 s, out_pending_idx);
                        $display("ERROR sample %0d: output written to RAM offset 0x%04h, expected output[%0d] @ 0x%04h",
                                 out_pending_idx, off, out_pending_idx, out_off + 4 * out_pending_idx);
                    end else if (data !== y_read[NUM_FLUSH + s]) begin
                        mon_fail("sw output[i] data != DATA_OUT read over AXI (data, axi)", data, y_read[NUM_FLUSH + s]);
                        $display("ERROR sample %0d: output stored %0d != DATA_OUT %0d",
                                 s, $signed(data), $signed(y_read[NUM_FLUSH + s]));
                    end
                    out_pending = 1'b0;
                end else if (!is_wr && off >= out_off && off < out_off + 4 * N && off[1:0] == 2'b00) begin
                    // ---- đọc lại output[i] sau 1000 mẫu ----
                    s = (off - out_off) >> 2;
                    tb_rb_sum = tb_rb_sum + data;
                    tb_rb_xor = tb_rb_xor ^ data;
                    if (sb_state != SB_END || out_pending || s != rb_n)
                        mon_fail("output read-back out of order / before all samples (i, expected)", s, rb_n);
                    else if (data !== y_read[NUM_FLUSH + s])
                        mon_fail("output read-back != value stored (data, exp)", data, y_read[NUM_FLUSH + s]);
                    rb_n = rb_n + 1;
                end else begin
                    ram_bad_n = ram_bad_n + 1;
                    mon_fail(is_wr ? "RAM write outside output[] (wrong address / overwrites input)"
                                   : "RAM read outside input[] / output[]", addr + 32'h4000_0000, data);
                end
            end else begin
                // ---- FIR (giao thức Bước 3) ----
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
                            mon_fail("protocol: expected CTRL write = 1", addr, data);
                        else
                            sb_state = SB_IDLE_POLL;
                    end
                    SB_DATA_IN: begin
                        if (!is_wr || addr != A_DATA_IN)
                            mon_fail("protocol: expected DATA_IN write after STATUS.BUSY=0", addr, sb_idx);
                        else begin
                            if (out_pending)
                                mon_fail("new DATA_IN before output[] of previous sample was stored",
                                         out_pending_idx, sb_idx);
                            if (sb_idx >= NUM_FLUSH && in_load_cnt[sb_idx - NUM_FLUSH] != 1)
                                mon_fail("DATA_IN without exactly one lw input[i] before it (i, loads)",
                                         sb_idx - NUM_FLUSH, in_load_cnt[sb_idx - NUM_FLUSH]);
                            if (data !== x_sent[sb_idx]) begin
                                mon_fail("DATA_IN value wrong / out of order (got, exp)", data, x_sent[sb_idx]);
                                if (sb_idx >= NUM_FLUSH)
                                    $display("ERROR sample %0d: DATA_IN %0d, expected input[%0d] = %0d",
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
                            last_data_out_cycle = cycles;
                            if (sb_idx >= NUM_FLUSH) begin
                                tb_out_sum = tb_out_sum + data;
                                tb_out_xor = tb_out_xor ^ data;
                            end
                            if (data !== y_model[sb_idx] || data !== hls_y[sb_idx]) begin
                                y_mismatch_n = y_mismatch_n + 1;
                                if (sb_idx >= NUM_FLUSH)
                                    $display("ERROR sample %0d (x = %0d): DATA_OUT %0d (0x%08h), expected %0d (0x%08h), HLS y %0d",
                                             sb_idx - NUM_FLUSH, $signed(x_sent[sb_idx]), $signed(data), data,
                                             $signed(y_model[sb_idx]), y_model[sb_idx], $signed(hls_y[sb_idx]));
                                else
                                    $display("ERROR flush sample %0d: DATA_OUT %0d, expected %0d, HLS y %0d",
                                             sb_idx, $signed(data), $signed(y_model[sb_idx]), $signed(hls_y[sb_idx]));
                            end
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
                        mon_fail("unexpected FIR transaction after the last sample", addr, data);
                endcase
            end
        end
    endtask

    // HLS: x và y của từng lần tính (chỉ số = số lần y_ap_vld đã thấy trước đó)
    integer hls_x_idx = 0;
    always @(posedge clk) begin
        if (rst_n) begin
            if (sigw(W_STATUS) === SIG_RUNNING) running_seen = 1;
            if (sigw(W_STATUS) === SIG_PASS && pass_cycle < 0) pass_cycle = cycles;
            if (dut.u_fir.hls_y_ap_vld) begin
                if (hls_x_idx < NUM_TOTAL) begin
                    hls_x[hls_x_idx] = dut.u_fir.x_q;
                    hls_y[hls_x_idx] = dut.u_fir.hls_y;
                    if (dut.u_fir.x_q !== x_sent[hls_x_idx]) hls_x_bad = hls_x_bad + 1;
                end
                hls_x_idx = hls_x_idx + 1;
            end
        end
    end

    //------------------------------------------------------------
    // Test sequence
    //------------------------------------------------------------
    reg [31:0] prog_ref [0:IMEM_WORDS-1];
    reg [31:0] data_ref [0:DMEM_WORDS-1];
    reg [31:0] syms     [0:1];
    integer    i, cnt, done_cycle, mem_bad, other_bad, model_bad;
    reg [31:0] w, e;

    initial begin : watchdog
        #((MAX_CYCLES + 1000) * 10);
        $display("ERROR TIMEOUT: watchdog");
        $display("TEST FAILED: watchdog");
        $finish;
    end

    initial begin
        for (i = 0; i < NUM_TOTAL; i = i + 1) begin
            x_sent[i] = 32'd0; y_model[i] = 32'hxxxx_xxxx; y_read[i] = 32'hxxxx_xxxx;
            hls_x[i] = 32'hxxxx_xxxx; hls_y[i] = 32'hxxxx_xxxx;
        end
        for (i = 0; i < N; i = i + 1) begin
            in_load_cnt[i] = 0; out_store_cnt[i] = 0; x_in[i] = 32'hxxxx_xxxx; y_exp1[i] = 32'hxxxx_xxxx;
        end
        for (i = 0; i < IMEM_WORDS; i = i + 1) prog_ref[i] = 32'hxxxx_xxxx;
        for (i = 0; i < DMEM_WORDS; i = i + 1) data_ref[i] = 32'hxxxx_xxxx;
        for (i = 0; i < 6; i = i + 1) layout[i] = 32'hxxxx_xxxx;
        for (i = 0; i < TAPS; i = i + 1) begin coef_rom[i] = 32'hxxxx_xxxx; hist_dat[i] = 32'hxxxx_xxxx; end
        syms[0] = 32'hxxxx_xxxx; syms[1] = 32'hxxxx_xxxx;
        out_pending = 1'b0; out_pending_idx = -1;
        tb_in_sum = 0; tb_out_sum = 0; tb_out_xor = 0; tb_rb_sum = 0; tb_rb_xor = 0;
        $readmemh("program.mem", prog_ref);
        $readmemh("data.mem", data_ref);
        $readmemh("symbols.mem", syms);
        $readmemh("input.mem", x_in);
        $readmemh("expected.mem", y_exp1);
        $readmemh("layout.mem", layout);
        $readmemh("fir_fir_Pipeline_Shift_Accum_Loop_fir_int_int_c_ROM_AUTO_1R.dat", coef_rom);
        $readmemh("fir_fir_Pipeline_Shift_Accum_Loop_shift_reg_RAM_AUTO_1R1W.dat", hist_dat);
        coef[0] = 54;  coef[1] = 0;   coef[2] = -92; coef[3] = 0;   coef[4] = 313; coef[5] = 500;
        coef[6] = 313; coef[7] = 0;   coef[8] = -92; coef[9] = 0;   coef[10] = 54;

        #1;   // sau $readmemh và vòng xóa 0 của sdram_model (t = 0)
        if (prog_ref[0] === 32'hxxxx_xxxx || data_ref[0] === 32'hxxxx_xxxx || syms[1] === 32'hxxxx_xxxx ||
            x_in[N-1] === 32'hxxxx_xxxx || y_exp1[N-1] === 32'hxxxx_xxxx || layout[5] === 32'hxxxx_xxxx ||
            coef_rom[0] === 32'hxxxx_xxxx || hist_dat[0] === 32'hxxxx_xxxx) begin
            $display("TEST FAILED: missing program.mem / data.mem / symbols.mem / input.mem / expected.mem / layout.mem / FIR .dat");
            $finish;
        end
        stack_limit = syms[0]; stack_top = syms[1];
        in_off = layout[0] - CPU_RAM_LO; out_off = layout[1] - CPU_RAM_LO;
        $display("INFO config %0s (USE_CACHE=%0d): input[%0d] @ 0x%08h, output[%0d] @ 0x%08h, stack [0x%08h, 0x%08h)",
                 USE_CACHE ? "C: cache" : "B: no cache", USE_CACHE, N, layout[0], N, layout[1], stack_limit, stack_top);

        // ---- bố trí ----
        check_eq(layout[2], N, "layout.mem N = 1000");
        check_eq(layout[0] >= CPU_RAM_LO && layout[0] + 4 * N - 1 <= CPU_RAM_HI && layout[0][1:0] == 0, 1,
                 "input[1000] inside external RAM, word aligned");
        check_eq(layout[1] >= CPU_RAM_LO && layout[1] + 4 * N - 1 <= CPU_RAM_HI && layout[1][1:0] == 0, 1,
                 "output[1000] inside external RAM, word aligned");
        check_eq((layout[0] + 4 * N <= layout[1]) || (layout[1] + 4 * N <= layout[0]), 1,
                 "input and output regions do not overlap");

        // ---- image ----
        check_eq(prog_ref[0] !== NOP, 1, "program.mem holds firmware");
        cnt = 0;
        for (i = 0; i < IMEM_WORDS; i = i + 1) if (dut.u_cpu.IMEM.memory[i] !== prog_ref[i]) cnt = cnt + 1;
        check_eq(cnt, 0, "IMEM == program.mem before reset");
        cnt = 0;
        for (i = 0; i < DMEM_WORDS; i = i + 1) if (dut.u_cpu.DMEM.memory[i] !== data_ref[i]) cnt = cnt + 1;
        check_eq(cnt, 0, "DMEM == data.mem before reset");
        cnt = 0;
        for (i = 0; i < RAM_WORDS; i = i + 1) if (sdram_word(4 * i) !== 32'd0) cnt = cnt + 1;
        check_eq(cnt, 0, "external RAM all zero before preload");

        // ---- mô hình #2 == expected.mem (#1); input.mem cũng là x_sent ----
        cnt = 0;
        for (i = 0; i < TAPS; i = i + 1) begin
            if (coef_rom[i] !== coef[i]) cnt = cnt + 1;
            hist[i] = hist_dat[i];
        end
        check_eq(cnt, 0, "IP coefficient ROM == fir.cpp coefficients");
        cnt = 0;
        for (i = 0; i < TAPS; i = i + 1) if (hist_dat[i] !== 32'd0) cnt = cnt + 1;
        check_eq(cnt, 0, "IP shift_reg initial content = 0");
        for (i = 0; i < N; i = i + 1) x_sent[NUM_FLUSH + i] = x_in[i];
        model_bad = 0;
        for (i = 0; i < NUM_TOTAL; i = i + 1) begin
            w = model_push(x_sent[i]);
            if (i >= NUM_FLUSH && w !== y_exp1[i - NUM_FLUSH]) begin
                model_bad = model_bad + 1;
                if (model_bad <= 5)
                    $display("ERROR sample %0d: expected.mem %0d != testbench model %0d", i - NUM_FLUSH,
                             $signed(y_exp1[i - NUM_FLUSH]), $signed(w));
            end
        end
        check_eq(model_bad, 0, "expected.mem (Python model) == testbench model, 1000 samples");
        for (i = 0; i < TAPS; i = i + 1) hist[i] = hist_dat[i];      // scoreboard tính lại từ DATA_IN

        // ---- nạp kích thích vào sdram_model (chỉ input[]) ----
        for (i = 0; i < N; i = i + 1) begin
            dut.g_ext_ram.u_ext_mem.U_SDRAM.MEMORY.memory[(in_off + 4 * i) >> 1]       = x_in[i][15:0];
            dut.g_ext_ram.u_ext_mem.U_SDRAM.MEMORY.memory[((in_off + 4 * i) >> 1) + 1] = x_in[i][31:16];
        end
        cnt = 0;
        for (i = 0; i < N; i = i + 1) if (sdram_word(in_off + 4 * i) !== x_in[i]) cnt = cnt + 1;
        check_eq(cnt, 0, "input[1000] preloaded into external RAM");

        // ---- chạy ----
        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        while (sigw(W_HALT) !== HALT_MAGIC && cycles < MAX_CYCLES)
            @(negedge clk);
        done_cycle = cycles;
        if (sigw(W_HALT) !== HALT_MAGIC) begin
            errors = errors + 1;
            $display("ERROR TIMEOUT: firmware did not write HALT within %0d cycles", MAX_CYCLES);
            $display("  scoreboard: state %0d sample k=%0d, outputs stored %0d", sb_state, sb_idx, out_store_n);
            dump_cpu;
        end else begin
            $display("INFO firmware HALT after %0d cycles (%0d ns at 100 MHz)", done_cycle, done_cycle * 10);
            repeat (200) @(negedge clk);
        end

        // ---- bus / protocol ----
        monitor_final_checks;
        check_eq(sb_state, SB_END, "scoreboard reached the end (full protocol observed)");
        check_eq(sb_idx, NUM_TOTAL, "samples completed by the protocol (10 flush + 1000)");
        check_eq(ctrl_wr_n, 1, "CPU wrote CTRL once");
        check_eq(data_in_wr_n, NUM_TOTAL, "CPU wrote DATA_IN 1010 times (10 flush + 1000)");
        check_eq(data_out_rd_n, NUM_TOTAL, "CPU read DATA_OUT exactly once per sample");
        check_eq(status_rd_n >= 3 * NUM_TOTAL + 1, 1, "CPU polled STATUS (idle, DONE, after-read)");
        check_eq(accept_n, NUM_TOTAL, "FIR wrapper accepted 1010 samples");
        check_eq(hls_done_n, NUM_TOTAL, "HLS ap_done pulses (one per sample)");
        check_eq(hls_vld_n, NUM_TOTAL, "HLS y_ap_vld pulses");
        check_eq(hls_x_bad, 0, "HLS IP computed every sample with the x that was sent");
        // ---- RAM ----
        check_eq(in_load_n, N, "CPU read input[] from external RAM 1000 times");
        check_eq(out_store_n, N, "CPU wrote output[] to external RAM 1000 times");
        check_eq(rb_n, N, "CPU read back output[] 1000 times");
        cnt = 0;
        for (i = 0; i < N; i = i + 1) if (in_load_cnt[i] != 1 || out_store_cnt[i] != 1) cnt = cnt + 1;
        check_eq(cnt, 0, "each input[i] read once and each output[i] written once");
        check_eq(out_pending, 0, "last output stored");
        check_eq(ram_bad_n, 0, "no RAM access outside input[] / output[]");
        check_eq(ram_axi_rd_n, 2 * N, "RAM AXI reads = 1000 input + 1000 read-back");
        check_eq(ram_axi_wr_n, N, "RAM AXI writes = 1000 output");
        // ---- kết quả ----
        check_eq(y_mismatch_n, 0, "DATA_OUT == model == HLS y for all 1010 samples");
        mem_bad = 0;
        for (i = 0; i < N; i = i + 1) begin
            w = sdram_word(out_off + 4 * i);
            if (w !== y_model[NUM_FLUSH + i]) begin
                mem_bad = mem_bad + 1;
                if (mem_bad <= 10)
                    $display("ERROR sample %0d: output[%0d] in external RAM = %0d (0x%08h), expected %0d (0x%08h)",
                             i, i, $signed(w), w, $signed(y_model[NUM_FLUSH + i]), y_model[NUM_FLUSH + i]);
            end
        end
        check_eq(mem_bad, 0, "output[0..999] in external RAM == model (1000/1000)");
        cnt = 0;
        for (i = 0; i < N; i = i + 1) if (sdram_word(in_off + 4 * i) !== x_in[i]) cnt = cnt + 1;
        check_eq(cnt, 0, "input[] in external RAM unchanged");
        other_bad = 0;
        for (i = 0; i < RAM_WORDS; i = i + 1)
            if (!((4 * i >= in_off && 4 * i < in_off + 4 * N) || (4 * i >= out_off && 4 * i < out_off + 4 * N)) &&
                sdram_word(4 * i) !== 32'd0) begin
                other_bad = other_bad + 1;
                if (other_bad <= 5)
                    $display("ERROR external RAM offset 0x%04h outside input/output = 0x%08h (stray write)",
                             4 * i, sdram_word(4 * i));
            end
        check_eq(other_bad, 0, "rest of external RAM still zero (no stray writes)");
        $display("INFO 1000-sample compare: %0d wrong in RAM, %0d DATA_OUT mismatch(es)", mem_bad, y_mismatch_n);
        for (i = 0; i < N; i = i + 1)
            if (i < 12 || i >= N - 4 || (i % 100) == 0)
                $display("INFO s[%3d] x = %6d  y(AXI) = %9d  y(RAM) = %9d  expected = %9d  %0s", i,
                         $signed(x_sent[NUM_FLUSH + i]), $signed(y_read[NUM_FLUSH + i]),
                         $signed(sdram_word(out_off + 4 * i)), $signed(y_model[NUM_FLUSH + i]),
                         (y_read[NUM_FLUSH + i] === y_model[NUM_FLUSH + i] &&
                          sdram_word(out_off + 4 * i) === y_model[NUM_FLUSH + i]) ? "OK" : "MISMATCH");

        // ---- signature ----
        check_eq(running_seen, 1, "firmware wrote status = F1K0 (fir_1000 main started)");
        check_eq(sigw(W_STATUS), SIG_PASS, "signature.status = PASS");
        check_eq(sigw(W_EXIT), 0, "main() returned 0");
        check_eq(sigw(W_ERROR), 0, "signature.error = 0");
        check_eq(sigw(W_DONE), N, "signature.samples_done = 1000");
        check_eq(sigw(W_ERR_IDX), NO_INDEX, "signature.error_index = none");
        check_eq(sigw(W_ERR_ST), 0, "signature.error_status = 0");
        check_eq(sigw(W_FLUSH), NUM_FLUSH, "signature.flush_done = 10");
        check_eq(sigw(W_NUM), N, "signature.num_samples = 1000");
        check_eq(sigw(W_MAX_POLLS), sb_max_polls, "signature.max_polls == max DONE polls seen on AXI");
        check_eq(sigw(W_IN_SUM), tb_in_sum, "signature.in_sum == sum of input read on AXI");
        check_eq(sigw(W_IN_SUM), layout[5], "signature.in_sum == IN_SUM (layout.mem)");
        check_eq(sigw(W_OUT_SUM), tb_out_sum, "signature.out_sum == sum of DATA_OUT on AXI");
        check_eq(sigw(W_OUT_XOR), tb_out_xor, "signature.out_xor == XOR of DATA_OUT on AXI");
        check_eq(sigw(W_OUT_SUM), layout[3], "signature.out_sum == EXP_SUM (layout.mem)");
        check_eq(sigw(W_OUT_XOR), layout[4], "signature.out_xor == EXP_XOR (layout.mem)");
        check_eq(sigw(W_RB_SUM), tb_rb_sum, "signature.rb_sum == sum of read-back on AXI");
        check_eq(sigw(W_RB_XOR), tb_rb_xor, "signature.rb_xor == XOR of read-back on AXI");
        check_eq(pass_cycle > last_data_out_cycle && last_data_out_cycle > 0, 1,
                 "PASS written only after the final DATA_OUT read");
        cnt = 0;
        for (i = 0; i < IMEM_WORDS; i = i + 1) if (dut.u_cpu.IMEM.memory[i] !== prog_ref[i]) cnt = cnt + 1;
        check_eq(cnt, 0, "IMEM unchanged after the run");

        monitor_report;
        $display("INFO FIR regs: DATA_IN wr %0d, CTRL wr %0d, STATUS rd %0d, DATA_OUT rd %0d, max DONE polls %0d",
                 data_in_wr_n, ctrl_wr_n, status_rd_n, data_out_rd_n, sb_max_polls);
        if (last_out_cycle > first_in_cycle && first_in_cycle >= 0)
            $display("INFO timing: 1000 samples from first input read (cycle %0d) to last output write (cycle %0d) = %0d cycles, %0d.%02d cycles/sample",
                     first_in_cycle, last_out_cycle, last_out_cycle - first_in_cycle,
                     (last_out_cycle - first_in_cycle) / N, ((last_out_cycle - first_in_cycle) % N) / 10);
        $display("INFO signature: status 0x%08h exit %0d error %0d samples_done %0d err_idx 0x%08h flush %0d max_polls %0d in_sum 0x%08h out_sum 0x%08h out_xor 0x%08h rb_sum 0x%08h rb_xor 0x%08h",
                 sigw(W_STATUS), $signed(sigw(W_EXIT)), sigw(W_ERROR), sigw(W_DONE), sigw(W_ERR_IDX),
                 sigw(W_FLUSH), sigw(W_MAX_POLLS), sigw(W_IN_SUM), sigw(W_OUT_SUM), sigw(W_OUT_XOR),
                 sigw(W_RB_SUM), sigw(W_RB_XOR));
        if (errors != 0) begin
            $display("State at end of test:");
            $display("  scoreboard: state %0d sample k=%0d", sb_state, sb_idx);
            dump_cpu;
        end
        $display("Checks: %0d, errors: %0d, cycles to HALT: %0d, USE_CACHE=%0d", checks, errors, done_cycle, USE_CACHE);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

endmodule
