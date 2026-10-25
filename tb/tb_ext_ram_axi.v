`timescale 1ns/1ps
`include "soc_pkg.vh"
`include "sdram_pkg.vh"

// tb_ext_ram_axi : kiểm RAM dữ liệu ngoài qua axi_interconnect (cấu hình B/C)

module tb_ext_ram_axi;

    parameter USE_CACHE = 0;

    localparam [31:0] BASE     = `EXT_RAM_BASE;
    localparam [31:0] A_INT_EN = 32'h0000_01C0;
    localparam [31:0] A_FIR    = 32'h0000_0200;
    localparam [31:0] A_TIMER  = 32'h0000_0080;
    localparam [31:0] FIR_CONST   = 32'hF1F0_0000;
    localparam [31:0] TIMER_CONST = 32'h7171_0000;
    localparam WORDS = 16384;                 // 64 KB

    reg clk;
    reg rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer errors, checks, seed, max_bp;

    // AXI signals

    reg  [31:0] s_axi_awaddr;  reg s_axi_awvalid; wire s_axi_awready;
    reg  [31:0] s_axi_wdata;   reg [3:0] s_axi_wstrb; reg s_axi_wvalid; wire s_axi_wready;
    wire [1:0]  s_axi_bresp;   wire s_axi_bvalid; reg s_axi_bready;
    reg  [31:0] s_axi_araddr;  reg s_axi_arvalid; wire s_axi_arready;
    wire [31:0] s_axi_rdata;   wire [1:0] s_axi_rresp; wire s_axi_rvalid; reg s_axi_rready;

    // DUT

    wire [31:0] write_addr, write_data, read_addr;
    wire        timer_wr_en, timer_rd_en, interrupt_wr_en, interrupt_rd_en, fir_wr_en, fir_rd_en;
    wire [31:0] interrupt_rdata;
    wire        ext_ram_read, ext_ram_write, ext_ram_ready;
    wire [31:0] ext_ram_addr, ext_ram_wdata, ext_ram_rdata;

    axi_interconnect #(.ENABLE_EXT_RAM(1)) u_ic (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .timer_rdata(TIMER_CONST), .interrupt_rdata(interrupt_rdata), .fir_rdata(FIR_CONST),
        .timer_wr_en(timer_wr_en), .timer_rd_en(timer_rd_en),
        .interrupt_wr_en(interrupt_wr_en), .interrupt_rd_en(interrupt_rd_en),
        .fir_wr_en(fir_wr_en), .fir_rd_en(fir_rd_en),
        .write_addr(write_addr), .write_data(write_data), .read_addr(read_addr),
        .ext_ram_read(ext_ram_read), .ext_ram_write(ext_ram_write),
        .ext_ram_addr(ext_ram_addr), .ext_ram_wdata(ext_ram_wdata),
        .ext_ram_rdata(ext_ram_rdata), .ext_ram_ready(ext_ram_ready)
    );

    interrupt_axi_wrapper u_int (
        .clk(clk), .rst_n(rst_n),
        .wr_en(interrupt_wr_en), .rd_en(interrupt_rd_en),
        .wr_addr(write_addr), .rd_addr(read_addr), .wdata(write_data), .rdata(interrupt_rdata),
        .irq_enable(), .ack(), .ack_id(),
        .pending(2'b00), .interrupt(1'b0), .interrupt_id(3'd0),
        .buserr_valid(1'b0), .buserr_write(1'b0), .buserr_resp(2'b00), .buserr_overflow(1'b0),
        .buserr_addr(32'd0), .buserr_clr()
    );

    cache_top #(.USE_CACHE(USE_CACHE)) u_mem (
        .clk(clk), .rst(~rst_n),
        .cpu_read(ext_ram_read), .cpu_write(ext_ram_write), .cpu_addr(ext_ram_addr),
        .cpu_wdata(ext_ram_wdata), .cpu_rdata(ext_ram_rdata), .cpu_ready(ext_ram_ready)
    );

    // Monitors (pre-edge values at posedge)

    // n_wr_en / n_rd_en: rising edges of cpu_write / cpu_read at cache_top
    integer n_wr_en, n_rd_en, n_wr_done, n_rd_done;
    integer n_be_rd, n_be_wr, n_refresh;
    reg        prev_rd, prev_wr;
    reg [31:0] prev_addr, prev_wdata;

    always @(posedge clk) begin
        if (rst_n) begin
            if (ext_ram_write && !prev_wr) n_wr_en = n_wr_en + 1;
            if (ext_ram_read  && !prev_rd) n_rd_en = n_rd_en + 1;
            if (u_ic.ext_ram_wr_done) n_wr_done = n_wr_done + 1;
            if (u_ic.ext_ram_rd_done) n_rd_done = n_rd_done + 1;
            // request held: address / data must not change while waiting
            if ((ext_ram_write && prev_wr) || (ext_ram_read && prev_rd)) begin
                if (ext_ram_addr !== prev_addr || (ext_ram_write && ext_ram_wdata !== prev_wdata)) begin
                    errors = errors + 1;
                    $display("[%0t] ERROR cpu_addr/cpu_wdata changed while request held", $time);
                end
            end
            if (ext_ram_read && ext_ram_write) begin
                errors = errors + 1;
                $display("[%0t] ERROR cpu_read and cpu_write both high", $time);
            end
            // completion only for a granted request (no idle/stale ready)
            if (ext_ram_ready && u_ic.EXT_RAM_ARB.active == 2'd0) begin
                errors = errors + 1;
                $display("[%0t] ERROR cpu_ready with no request in flight", $time);
            end
            if (u_mem.arb_mem_ready) begin
                if (u_mem.U_SDRAM.CONTROLLER.saved_read) n_be_rd = n_be_rd + 1;
                else                                     n_be_wr = n_be_wr + 1;
            end
            if (u_mem.U_SDRAM.refresh_done) n_refresh = n_refresh + 1;
        end
        prev_rd    = rst_n && ext_ram_read;
        prev_wr    = rst_n && ext_ram_write;
        prev_addr  = ext_ram_addr;
        prev_wdata = ext_ram_wdata;
    end

    // Shadow memory, backdoor, TB cache model

    reg [31:0] shadow [0:WORDS-1];
    reg        tbc_valid [0:63];
    reg [21:0] tbc_tag   [0:63];

    function [31:0] backdoor;           // word at byte offset off, from sdram_model
        input [31:0] off;
        begin
            backdoor = {u_mem.U_SDRAM.MEMORY.memory[(off >> 1) + 1],
                        u_mem.U_SDRAM.MEMORY.memory[off >> 1]};
        end
    endfunction

    task b_seen_hook;                   // called by axi_write when BVALID is seen
        input [31:0] addr;
        input [31:0] data;
        input [3:0]  strb;
        begin
            if (addr >= BASE && addr <= `EXT_RAM_END && addr[1:0] == 2'b00 && strb == 4'hF)
                check_eq(backdoor(addr - BASE), data, "backend holds data at BVALID");
        end
    endtask

    `include "axi_lite_bfm.vh"

    // RAM access wrappers with all per-transaction checks

    task ram_write;
        input [31:0] off;
        input [31:0] data;
        reg   [1:0]  resp;
        integer w0, d0, br0, bw0;
        begin
            w0 = n_wr_en; d0 = n_wr_done; br0 = n_be_rd; bw0 = n_be_wr;
            axi_write(BASE + off, data, 4'hF, resp);
            check_eq(resp, `AXI_RESP_OKAY, "ram_write BRESP");
            check_eq(n_wr_en - w0,   1, "one memory write request per AXI write");
            check_eq(n_wr_done - d0, 1, "one wr_done per AXI write");
            check_eq(n_be_wr - bw0,  1, "one backend write per AXI write");
            check_eq(n_be_rd - br0,  0, "no backend read on write (no-allocate)");
            shadow[off >> 2] = data;
        end
    endtask

    task ram_read;
        input [31:0] off;
        reg   [31:0] data;
        reg   [1:0]  resp;
        integer r0, d0, br0, bw0, exp_rd;
        reg   [5:0]  idx;
        begin
            idx = off[9:4];
            if (USE_CACHE == 0)
                exp_rd = 1;
            else if (tbc_valid[idx] && tbc_tag[idx] == off[31:10])
                exp_rd = 0;
            else
                exp_rd = 4;
            r0 = n_rd_en; d0 = n_rd_done; br0 = n_be_rd; bw0 = n_be_wr;
            axi_read(BASE + off, data, resp);
            check_eq(resp, `AXI_RESP_OKAY, "ram_read RRESP");
            check_eq(data, shadow[off >> 2], "ram_read data");
            check_eq(n_rd_en - r0,   1, "one memory read request per AXI read");
            check_eq(n_rd_done - d0, 1, "one rd_done per AXI read");
            check_eq(n_be_rd - br0,  exp_rd, "backend reads (cache model)");
            check_eq(n_be_wr - bw0,  0, "no backend write on read");
            if (USE_CACHE != 0) begin
                tbc_valid[idx] = 1'b1;
                tbc_tag[idx]   = off[31:10];
            end
        end
    endtask

    // Test sequence

    reg [31:0] r;
    reg [1:0]  resp;
    integer    i, k, br0, bw0, rf0;
    reg [31:0] offs [0:9];

    initial begin : watchdog
        #20_000_000;
        $display("TEST FAILED: watchdog timeout");
        $finish;
    end

    initial begin
        errors = 0; checks = 0; max_bp = 3;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        n_wr_en = 0; n_rd_en = 0; n_wr_done = 0; n_rd_done = 0;
        n_be_rd = 0; n_be_wr = 0; n_refresh = 0;
        s_axi_awaddr = 0; s_axi_awvalid = 0; s_axi_wdata = 0; s_axi_wstrb = 0;
        s_axi_wvalid = 0; s_axi_bready = 0; s_axi_araddr = 0; s_axi_arvalid = 0;
        s_axi_rready = 0;
        for (i = 0; i < WORDS; i = i + 1) shadow[i] = 32'd0;   // sdram_model initialises to 0
        for (i = 0; i < 64; i = i + 1) begin tbc_valid[i] = 1'b0; tbc_tag[i] = 22'd0; end
        $display("tb_ext_ram_axi: USE_CACHE=%0d seed=%0d", USE_CACHE, seed);

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;

        //---------------- T0 first request during SDRAM init ----------------
        $display("[%0t] T0 request during init, cold cache", $time);
        if (u_mem.U_SDRAM.state == `SDRAM_IDLE)
            $display("[%0t] INFO SDRAM already idle at first request", $time);
        ram_read(32'h0000_0000);              // C: must be a 4-read miss (valid reset)
        ram_write(32'h0000_0000, 32'hA5A5_0000);
        ram_read(32'h0000_0000);

        //---------------- T1 mapping boundaries ----------------
        $display("[%0t] T1 mapping boundaries", $time);
        offs[0] = 32'h0000; offs[1] = 32'h0004; offs[2] = 32'h03FC; offs[3] = 32'h0400;
        offs[4] = 32'h0404; offs[5] = 32'h07FC; offs[6] = 32'h0800; offs[7] = 32'h8000;
        offs[8] = 32'hFFF8; offs[9] = 32'hFFFC;
        for (i = 0; i < 10; i = i + 1)
            ram_write(offs[i], 32'hB000_0000 | (i << 16) | offs[i]);
        for (i = 0; i < 10; i = i + 1)
            ram_read(offs[i]);
        // halfword placement: low half at column {addr[9:2],0}, high at +1
        for (i = 0; i < 10; i = i + 1) begin
            check_eq(u_mem.U_SDRAM.MEMORY.memory[offs[i] >> 1],       shadow[offs[i] >> 2] & 32'hFFFF, "low halfword placement");
            check_eq(u_mem.U_SDRAM.MEMORY.memory[(offs[i] >> 1) + 1], shadow[offs[i] >> 2] >> 16,     "high halfword placement");
        end
        check_eq((backdoor(32'h0000) !== backdoor(32'h0400)), 1, "0x000 and 0x400 are distinct cells");

        //---------------- T2 sweep across row boundaries ----------------
        $display("[%0t] T2 sweep 0x000-0x80F", $time);
        for (i = 0; i <= 32'h80C; i = i + 4)
            ram_write(i, {16'hC0DE ^ i[15:0], i[15:0]});
        for (i = 0; i <= 32'h80C; i = i + 4)
            ram_read(i);

        //---------------- T3 cache behaviour ----------------
        $display("[%0t] T3 line / hit / miss / replace", $time);
        ram_write(32'h2000, 32'h1111_0001);   // write miss: no allocate
        ram_write(32'h2004, 32'h2222_0002);
        ram_write(32'h2008, 32'h3333_0003);
        ram_write(32'h200C, 32'h4444_0004);
        ram_read (32'h2000);                  // C: miss, refill 4
        ram_read (32'h2004);                  // C: hit
        ram_read (32'h2008);
        ram_read (32'h200C);
        ram_write(32'h2008, 32'h3333_FFFF);   // C: write hit, write-through
        ram_read (32'h2008);                  // C: hit, new value from line
        ram_read (32'h2400);                  // same index, other tag: replace
        ram_read (32'h2000);                  // C: miss again
        ram_write(32'h2404, 32'h5555_0005);   // write miss (line 0x2400 evicted)
        ram_read (32'h2404);

        //---------------- T4 request during refresh ----------------
        $display("[%0t] T4 refresh", $time);
        rf0 = n_refresh;
        k = 0;
        @(negedge clk);
        while (!u_mem.U_SDRAM.refresh_request && k < 5000) begin
            @(negedge clk);
            k = k + 1;
        end
        check_eq(u_mem.U_SDRAM.refresh_request, 1, "refresh_request seen");
        ram_read(32'h0404);                   // issued while refresh pending
        ram_write(32'h0408, 32'hDEAD_0408);
        ram_read(32'h0408);
        repeat (2000) @(negedge clk);
        check_eq(n_refresh - rf0 >= 2, 1, "periodic refresh keeps running");

        //---------------- T7 errors ----------------
        $display("[%0t] T7 partial / unaligned", $time);
        br0 = n_be_rd; bw0 = n_be_wr; k = n_wr_en + n_rd_en;
        axi_write(BASE + 32'h0100, 32'hFFFF_FFFF, 4'b0011, resp);
        check_eq(resp, `AXI_RESP_SLVERR, "partial write -> SLVERR");
        axi_write(BASE + 32'h0102, 32'hFFFF_FFFF, 4'b1111, resp);
        check_eq(resp, `AXI_RESP_SLVERR, "unaligned write -> SLVERR");
        axi_read(BASE + 32'h0102, r, resp);
        check_eq(resp, `AXI_RESP_SLVERR, "unaligned read -> SLVERR");
        check_eq(r, 32'd0, "unaligned read data 0");
        check_eq(n_be_rd - br0, 0, "no backend read for errors");
        check_eq(n_be_wr - bw0, 0, "no backend write for errors");
        check_eq(n_wr_en + n_rd_en - k, 0, "no memory request for rejected accesses");
        check_eq(backdoor(32'h0100), shadow[32'h0100 >> 2], "memory unchanged by partial write");
        ram_read(32'h0100);

        //---------------- T8 MMIO not cached ----------------
        $display("[%0t] T8 MMIO", $time);
        br0 = n_be_rd; bw0 = n_be_wr;
        axi_write(A_INT_EN, 32'h3, 4'hF, resp);
        axi_read(A_INT_EN, r, resp);  check_eq(r, 32'h3, "interrupt ENABLE readback");
        axi_write(A_INT_EN, 32'h1, 4'hF, resp);
        axi_read(A_INT_EN, r, resp);  check_eq(r, 32'h1, "interrupt ENABLE readback 2");
        axi_read(A_FIR, r, resp);     check_eq(r, FIR_CONST, "FIR rdata path");
        axi_read(A_TIMER, r, resp);   check_eq(r, TIMER_CONST, "Timer rdata path");
        check_eq(n_be_rd - br0, 0, "MMIO reads never reach RAM backend");
        check_eq(n_be_wr - bw0, 0, "MMIO writes never reach RAM backend");

        //---------------- T9 concurrent write + read ----------------
        $display("[%0t] T9 concurrent channels", $time);
        for (k = 0; k < 8; k = k + 1) begin
            fork
                axi_write(BASE + 32'h3000 + 4 * k, 32'h9000_0000 + k, 4'hF, resp);
                begin
                    axi_read(BASE + 32'h0000, r, resp);
                    check_eq(r, shadow[0], "concurrent read data");
                end
            join
            shadow[(32'h3000 + 4 * k) >> 2] = 32'h9000_0000 + k;
        end
        check_eq(n_wr_en, n_wr_done, "every RAM write completed once");
        check_eq(n_rd_en, n_rd_done, "every RAM read completed once");
        // the raw axi_read(0) above allocated line 0 (tag 0) in config C;
        tbc_valid[0] = 1'b1;
        tbc_tag[0]   = 22'd0;
        for (k = 0; k < 8; k = k + 1)
            ram_read(32'h3000 + 4 * k);

        //---------------- T6 random traffic with backpressure ----------------
        $display("[%0t] T6 random traffic", $time);
        max_bp = 6;
        for (k = 0; k < 300; k = k + 1) begin
            i = ({$random(seed)} % 1024) * 4;        // first 4 KB: many index/tag conflicts
            if ({$random(seed)} % 2)
                ram_write(i, $random(seed));
            else
                ram_read(i);
        end

        //---------------- summary ----------------
        check_eq(n_wr_en, n_wr_done, "final: wr_en == wr_done");
        check_eq(n_rd_en, n_rd_done, "final: rd_en == rd_done");
        repeat (10) @(negedge clk);
        $display("Checks: %0d, errors: %0d (USE_CACHE=%0d, seed=%0d)", checks, errors, USE_CACHE, seed);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

endmodule
