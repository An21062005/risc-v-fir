`timescale 1ns/1ps

//======================================================================
// tb_cpu_ext_ram : firmware C (GCC) đọc/ghi RAM ngoài 64 KB bằng lw/sw qua AXI
//======================================================================
// Firmware: firmware/ext_ram_test.c (build_firmware.py --firmware ext_ram_test)
// SoC: soc_top #(ENABLE_EXT_RAM=1, EXT_RAM_USE_CACHE=USE_CACHE)
//   USE_CACHE=0: cấu hình B (bypass), USE_CACHE=1: cấu hình C (cache write-through)
// RAM ngoài: CPU 0x4001_0000..0x4001_FFFF = bus 0x0001_xxxx -> cache_top -> sdram_top.
// Testbench KHÔNG ghi lệnh / dữ liệu / RAM; sdram_model khởi tạo 0 (initial).
//
// Kiểm chứng độc lập:
//   - cpu_soc_monitor.vh: requested / accepted / completed / responded, mỗi giao dịch
//     RAM đúng 1 yêu cầu + 1 ready ở cache_top với offset và dữ liệu đúng, OKAY
//   - bộ nhớ bóng cập nhật theo từng ghi AXI quan sát được; mọi lần đọc phải trả
//     đúng giá trị bóng (ô chưa ghi = 0)
//   - cuối test: toàn bộ 16384 word của sdram_model == bộ nhớ bóng (không ghi nhầm
//     ô, không alias), có ghi đầu / giữa / cuối vùng và các mẫu 0, âm, dương,
//     0xFFFFFFFF, 0x80000000
//   - không có giao dịch tới FIR/Timer/IRQ, DMEM chỉ ghi signature/stack
//
// Chạy: python scripts/run_rtl_tests.py --vivado-root <Vivado> --tests tb_cpu_ext_ram_b tb_cpu_ext_ram_c
//======================================================================

module tb_cpu_ext_ram;

    parameter USE_CACHE = 0;

    localparam MAX_CYCLES  = 100000;
    localparam TXN_TIMEOUT = 300;       // RAM: ~15-25 chu kỳ/word, refill cache 4 word, refresh
    localparam MAX_ERR_MSG = 12;
    localparam SIG_WORDS   = 11;
    localparam IMEM_WORDS  = 256;
    localparam DMEM_WORDS  = 256;
    localparam RAM_WORDS   = 16384;
    localparam EXP_RAM_WR  = 94;        // ext_ram_test.c: 15 + 15 + 64
    localparam EXP_RAM_RD  = 94;

    localparam [31:0] SIG_RUNNING = 32'h5852_414D;  // "XRAM"
    localparam [31:0] SIG_PASS    = 32'h600D_C0DE;
    localparam [31:0] HALT_MAGIC  = 32'h4841_4C54;
    localparam [31:0] NOP         = 32'h0000_0013;

    localparam W_STATUS = 0, W_HALT = 1, W_EXIT = 2, W_PHASE = 3, W_CHECKS = 4, W_FAILS = 5,
               W_FAIL_ADDR = 6, W_FAIL_GOT = 7, W_FAIL_EXP = 8, W_RAM_WR = 9, W_RAM_RD = 10;

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
    // Bộ nhớ bóng
    //------------------------------------------------------------
    reg [31:0] shadow  [0:RAM_WORDS-1];
    reg        written [0:RAM_WORDS-1];
    integer    sh_wr_n = 0, sh_rd_n = 0, sh_rd_err = 0, fir_txn_n = 0;
    integer    seen_zero = 0, seen_ones = 0, seen_min = 0, seen_pos = 0, seen_neg = 0;
    integer    seen_first = 0, seen_mid = 0, seen_last = 0;
    reg [31:0] off;

    task on_txn;
        input        is_wr;
        input [31:0] addr;
        input [31:0] data;
        begin
            if (is_ram(addr)) begin
                off = addr - MON_RAM_LO;
                if (off[1:0] != 2'b00)
                    mon_fail("unaligned RAM access", addr, data);
                else if (is_wr) begin
                    sh_wr_n = sh_wr_n + 1;
                    shadow[off >> 2] = data;
                    written[off >> 2] = 1'b1;
                    if (data == 32'h0000_0000) seen_zero = 1;
                    if (data == 32'hFFFF_FFFF) seen_ones = 1;
                    if (data == 32'h8000_0000) seen_min = 1;
                    if ($signed(data) > 0) seen_pos = 1;
                    if ($signed(data) < 0) seen_neg = 1;
                    if (off == 32'h0000) seen_first = 1;
                    if (off == 32'h8000) seen_mid = 1;
                    if (off == 32'hFFFC) seen_last = 1;
                end else begin
                    sh_rd_n = sh_rd_n + 1;
                    if (data !== (written[off >> 2] ? shadow[off >> 2] : 32'd0)) begin
                        sh_rd_err = sh_rd_err + 1;
                        mon_fail("RAM read != shadow memory (data, expected)", data,
                                 written[off >> 2] ? shadow[off >> 2] : 32'd0);
                    end
                end
            end else begin
                fir_txn_n = fir_txn_n + 1;
                mon_fail("RAM test firmware must not access FIR/other peripherals", addr, data);
            end
        end
    endtask

    function [31:0] sdram_word;         // word tại offset o: halfword thấp ở o/2, cao ở o/2+1
        input [31:0] o;
        begin
            sdram_word = {dut.g_ext_ram.u_ext_mem.U_SDRAM.MEMORY.memory[(o >> 1) + 1],
                          dut.g_ext_ram.u_ext_mem.U_SDRAM.MEMORY.memory[o >> 1]};
        end
    endfunction

    //------------------------------------------------------------
    // Test sequence
    //------------------------------------------------------------
    reg [31:0] prog_ref [0:IMEM_WORDS-1];
    reg [31:0] data_ref [0:DMEM_WORDS-1];
    reg [31:0] syms     [0:1];
    integer    i, cnt, done_cycle, mem_bad;
    reg [31:0] w, e;

    initial begin : watchdog
        #((MAX_CYCLES + 1000) * 10);
        $display("ERROR TIMEOUT: watchdog");
        $display("TEST FAILED: watchdog");
        $finish;
    end

    initial begin
        for (i = 0; i < RAM_WORDS; i = i + 1) begin shadow[i] = 32'd0; written[i] = 1'b0; end
        for (i = 0; i < IMEM_WORDS; i = i + 1) prog_ref[i] = 32'hxxxx_xxxx;
        for (i = 0; i < DMEM_WORDS; i = i + 1) data_ref[i] = 32'hxxxx_xxxx;
        syms[0] = 32'hxxxx_xxxx; syms[1] = 32'hxxxx_xxxx;
        $readmemh("program.mem", prog_ref);
        $readmemh("data.mem", data_ref);
        $readmemh("symbols.mem", syms);
        #1;
        if (prog_ref[0] === 32'hxxxx_xxxx || data_ref[0] === 32'hxxxx_xxxx || syms[1] === 32'hxxxx_xxxx) begin
            $display("TEST FAILED: cannot read program.mem / data.mem / symbols.mem");
            $finish;
        end
        stack_limit = syms[0]; stack_top = syms[1];
        $display("INFO config %0s (USE_CACHE=%0d), stack [0x%08h, 0x%08h)",
                 USE_CACHE ? "C: cache" : "B: no cache", USE_CACHE, stack_limit, stack_top);

        check_eq(prog_ref[0] !== NOP, 1, "program.mem holds firmware");
        cnt = 0;
        for (i = 0; i < IMEM_WORDS; i = i + 1) if (dut.u_cpu.IMEM.memory[i] !== prog_ref[i]) cnt = cnt + 1;
        check_eq(cnt, 0, "IMEM == program.mem before reset");
        cnt = 0;
        for (i = 0; i < DMEM_WORDS; i = i + 1) if (dut.u_cpu.DMEM.memory[i] !== data_ref[i]) cnt = cnt + 1;
        check_eq(cnt, 0, "DMEM == data.mem before reset");
        cnt = 0;
        for (i = 0; i < RAM_WORDS; i = i + 1) if (sdram_word(4 * i) !== 32'd0) cnt = cnt + 1;
        check_eq(cnt, 0, "external RAM all zero before the run");

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        while (sigw(W_HALT) !== HALT_MAGIC && cycles < MAX_CYCLES)
            @(negedge clk);
        done_cycle = cycles;
        if (sigw(W_HALT) !== HALT_MAGIC) begin
            errors = errors + 1;
            $display("ERROR TIMEOUT: firmware did not write HALT within %0d cycles", MAX_CYCLES);
            dump_cpu;
        end else begin
            $display("INFO firmware HALT after %0d cycles (%0d ns at 100 MHz)", done_cycle, done_cycle * 10);
            repeat (200) @(negedge clk);    // không còn giao dịch sau HALT (monitor vẫn chạy)
        end

        monitor_final_checks;
        check_eq(fir_txn_n, 0, "no FIR / peripheral transaction");
        check_eq(sh_rd_err, 0, "every RAM read returned the last value written (shadow memory)");
        check_eq(sh_wr_n, EXP_RAM_WR, "RAM writes observed on AXI");
        check_eq(sh_rd_n, EXP_RAM_RD, "RAM reads observed on AXI");
        check_eq(seen_first && seen_mid && seen_last, 1, "RAM written at start (0x0), middle (0x8000) and end (0xFFFC)");
        check_eq(seen_zero && seen_ones && seen_min && seen_pos && seen_neg, 1,
                 "data patterns 0, 0xFFFFFFFF, 0x80000000, positive, negative written");
        // backend: mọi word == bóng, word không ghi vẫn 0
        mem_bad = 0;
        for (i = 0; i < RAM_WORDS; i = i + 1) begin
            w = sdram_word(4 * i);
            e = written[i] ? shadow[i] : 32'd0;
            if (w !== e) begin
                mem_bad = mem_bad + 1;
                if (mem_bad <= 5)
                    $display("ERROR sdram_model word offset 0x%04h = 0x%08h, expected 0x%08h", 4 * i, w, e);
            end
        end
        check_eq(mem_bad, 0, "sdram_model content == shadow memory (16384 words)");

        check_eq(sigw(W_STATUS), SIG_PASS, "signature.status = PASS");
        check_eq(sigw(W_EXIT), 0, "main() returned 0");
        check_eq(sigw(W_PHASE), 0, "signature.phase = 0");
        check_eq(sigw(W_FAILS), 0, "signature.fails = 0");
        check_eq(sigw(W_CHECKS), EXP_RAM_RD + 2, "signature.checks = 94 RAM + 2 DMEM canary");
        check_eq(sigw(W_RAM_WR), sh_wr_n, "signature.ram_writes == RAM writes seen on AXI");
        check_eq(sigw(W_RAM_RD), sh_rd_n, "signature.ram_reads == RAM reads seen on AXI");
        cnt = 0;
        for (i = 0; i < IMEM_WORDS; i = i + 1) if (dut.u_cpu.IMEM.memory[i] !== prog_ref[i]) cnt = cnt + 1;
        check_eq(cnt, 0, "IMEM unchanged after the run");

        monitor_report;
        $display("INFO signature: status 0x%08h phase %0d checks %0d fails %0d ram_writes %0d ram_reads %0d fail_addr 0x%08h got 0x%08h exp 0x%08h",
                 sigw(W_STATUS), sigw(W_PHASE), sigw(W_CHECKS), sigw(W_FAILS), sigw(W_RAM_WR), sigw(W_RAM_RD),
                 sigw(W_FAIL_ADDR), sigw(W_FAIL_GOT), sigw(W_FAIL_EXP));
        if (errors != 0) begin
            $display("State at end of test:");
            dump_cpu;
        end
        $display("Checks: %0d, errors: %0d, cycles to HALT: %0d, USE_CACHE=%0d", checks, errors, done_cycle, USE_CACHE);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

endmodule
