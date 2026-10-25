`timescale 1ns/1ps
`include "soc_pkg.vh"

// Integration regression: real interconnect, register wrapper and HLS FIR.
module tb_axi_fir;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    integer errors = 0, checks = 0, seed = 1, max_bp = 3;
    reg [31:0] s_axi_awaddr = 0, s_axi_wdata = 0, s_axi_araddr = 0;
    reg [3:0] s_axi_wstrb = 15;
    reg s_axi_awvalid = 0, s_axi_wvalid = 0, s_axi_bready = 0;
    reg s_axi_arvalid = 0, s_axi_rready = 0;
    wire s_axi_awready, s_axi_wready, s_axi_bvalid, s_axi_arready, s_axi_rvalid;
    wire [1:0] s_axi_bresp, s_axi_rresp;
    wire [31:0] s_axi_rdata, write_addr, write_data, read_addr, fir_rdata;
    wire fir_wr_en, fir_rd_en, fir_irq;
    localparam [31:0] TIMER_VALUE = 32'h7654_3210;
    localparam [31:0] DATA_IN = `FIR_BASE, DATA_OUT = `FIR_BASE + 4;
    localparam [31:0] STATUS = `FIR_BASE + 8, CTRL = `FIR_BASE + 12;

    axi_interconnect u_ic (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid), .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid), .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid), .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp), .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
        .timer_rdata(TIMER_VALUE), .interrupt_rdata(32'h1234_5678), .fir_rdata(fir_rdata),
        .timer_wr_en(), .timer_rd_en(), .interrupt_wr_en(), .interrupt_rd_en(),
        .fir_wr_en(fir_wr_en), .fir_rd_en(fir_rd_en),
        .write_addr(write_addr), .write_data(write_data), .read_addr(read_addr),
        .ext_ram_read(), .ext_ram_write(), .ext_ram_addr(), .ext_ram_wdata(),
        .ext_ram_rdata(32'd0), .ext_ram_ready(1'b0)
    );
    fir11_wrapper u_fir (
        .clk(clk), .rst_n(rst_n), .wr_en(fir_wr_en), .rd_en(fir_rd_en),
        .wr_addr(write_addr), .rd_addr(read_addr), .wdata(write_data),
        .rdata(fir_rdata), .irq(fir_irq)
    );

    task b_seen_hook;
        input [31:0] addr, data;
        input [3:0] strb;
        begin end
    endtask
    `include "axi_lite_bfm.vh"

    integer cycle = 0, accepted_at = 0, latency = 0;
    integer n_rd = 0, n_wr = 0, n_done = 0;
    always @(posedge clk) begin
        cycle = cycle + 1;
        if (rst_n) begin
            if (u_fir.accept) accepted_at = cycle;
            if (u_fir.hls_finish) begin
                latency = cycle - accepted_at;
                n_done = n_done + 1;
            end
            if (fir_rd_en) n_rd = n_rd + 1;
            if (fir_wr_en) n_wr = n_wr + 1;
        end
    end

    task reset_bus;
        begin
            @(negedge clk);
            rst_n = 0;
            s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0;
            s_axi_arvalid = 0; s_axi_rready = 0;
            repeat (4) @(negedge clk);
            rst_n = 1;
            repeat (2) @(negedge clk);
        end
    endtask

    // Keep the next AR valid immediately after the first handshake. Both
    task queued_reads;
        reg [31:0] first, second;
        integer k;
        begin
            @(negedge clk);
            s_axi_araddr = STATUS; s_axi_arvalid = 1;
            while (!s_axi_arready) @(negedge clk);
            @(negedge clk);
            s_axi_araddr = `TIMER_BASE;
            fork
                begin
                    while (!s_axi_arready) @(negedge clk);
                    @(negedge clk);
                    s_axi_arvalid = 0;
                end
                begin
                    wait_high_r;
                    first = s_axi_rdata;
                    repeat (3) @(negedge clk);
                    s_axi_rready = 1;
                    @(negedge clk);
                    s_axi_rready = 0;
                    k = 0;
                    while (!s_axi_rvalid && k < 100) begin
                        @(negedge clk); k = k + 1;
                    end
                    check_eq(s_axi_rvalid, 1, "queued second AR not lost");
                    second = s_axi_rdata;
                    s_axi_rready = 1;
                    @(negedge clk); s_axi_rready = 0;
                end
            join
            check_eq(first, 2, "first response uses latched FIR selection");
            check_eq(second, TIMER_VALUE, "second response is Timer");
        end
    endtask

    task queued_writes;
        integer k, i, before_wr;
        begin
            before_wr = n_wr;
            fork
                begin
                    @(negedge clk);
                    s_axi_awaddr = CTRL; s_axi_awvalid = 1;
                    for (i = 0; i < 2; i = i + 1) begin
                        while (!s_axi_awready) @(negedge clk);
                        @(negedge clk);
                    end
                    s_axi_awvalid = 0;
                end
                begin : write_data
                    integer j;
                    @(negedge clk);
                    s_axi_wdata = 1; s_axi_wvalid = 1;
                    for (j = 0; j < 2; j = j + 1) begin
                        while (!s_axi_wready) @(negedge clk);
                        @(negedge clk);
                    end
                    s_axi_wvalid = 0;
                end
                begin : responses
                    integer j;
                    for (j = 0; j < 2; j = j + 1) begin
                        k = 0;
                        while (!s_axi_bvalid && k < 100) begin
                            @(negedge clk); k = k + 1;
                        end
                        check_eq(s_axi_bvalid, 1, "queued B response not lost");
                        repeat (3) @(negedge clk);
                        s_axi_bready = 1;
                        @(negedge clk); s_axi_bready = 0;
                    end
                end
            join
            check_eq(n_wr - before_wr, 2, "two writes cause two peripheral pulses");
        end
    endtask

    task changed_ar_read;
        input [31:0] address;
        output [31:0] value;
        begin
            @(negedge clk);
            s_axi_araddr = address; s_axi_arvalid = 1;
            while (!s_axi_arready) @(negedge clk);
            @(negedge clk);
            s_axi_arvalid = 0;
            s_axi_araddr = `TIMER_BASE; // payload is unconstrained after handshake
            wait_high_r;
            value = s_axi_rdata;
            repeat (3) @(negedge clk);
            s_axi_rready = 1;
            @(negedge clk); s_axi_rready = 0;
        end
    endtask

    integer hist [0:10];
    integer coef [0:10];
    function [31:0] expected;
        input [31:0] x;
        reg [31:0] acc;
        integer k;
        begin
            acc = x * coef[0];
            for (k = 1; k < 11; k = k + 1) acc = acc + hist[k-1] * coef[k];
            expected = acc;
        end
    endfunction
    task push;
        input [31:0] x;
        integer k;
        begin
            for (k = 10; k > 0; k = k - 1) hist[k] = hist[k-1];
            hist[0] = x;
        end
    endtask

    reg [31:0] r, previous_y, new_y;
    reg [1:0] resp;
    integer k, offset, rd_before, done_before;
    initial begin
        #2_000_000;
        $display("TEST FAILED: watchdog timeout");
        $finish;
    end
    initial begin
        coef[0]=54; coef[1]=0; coef[2]=-92; coef[3]=0; coef[4]=313;
        coef[5]=500; coef[6]=313; coef[7]=0; coef[8]=-92; coef[9]=0; coef[10]=54;
        for (k = 0; k < 11; k = k + 1) hist[k] = 0;
        reset_bus;
        changed_ar_read(STATUS, r);
        check_eq(r, 2, "changing ARADDR after handshake keeps FIR response");
        queued_reads;
        reset_bus;
        queued_writes;
        reset_bus;

        axi_write(DATA_IN, 1, 15, resp);
        wait (fir_irq);
        @(negedge clk);
        check_eq(latency > 3, 1, "measured HLS latency");
        // Register peripherals have word semantics. Zero-strobe writes must
        rd_before = n_wr;
        axi_write(CTRL, 1, 4'b0000, resp);
        check_eq(resp, `AXI_RESP_OKAY, "zero WSTRB is an acknowledged no-op");
        check_eq(fir_irq, 1, "zero WSTRB does not clear DONE");
        axi_write(CTRL, 1, 4'b0001, resp);
        check_eq(resp, `AXI_RESP_SLVERR, "partial MMIO write is rejected");
        check_eq(fir_irq, 1, "partial MMIO write has no side effect");
        axi_write(CTRL + 1, 1, 15, resp);
        check_eq(resp, `AXI_RESP_SLVERR, "unaligned MMIO write is rejected");
        check_eq(n_wr - rd_before, 0, "invalid/no-op writes emit no peripheral pulse");
        axi_read(DATA_OUT + 1, r, resp);
        check_eq(resp, `AXI_RESP_SLVERR, "unaligned MMIO read is rejected");
        check_eq(r, 0, "unaligned read returns zero");
        check_eq(fir_irq, 1, "unaligned read does not clear DONE");
        axi_read(DATA_OUT, previous_y, resp);
        check_eq(previous_y, expected(1), "first real FIR result");
        push(1);

        // The peripheral snapshots y before the read edge. If completion
        for (offset = -1; offset <= 1; offset = offset + 1) begin
            new_y = expected(32'd11 + offset);
            done_before = n_done;
            rd_before = n_rd;
            fork
                axi_write(DATA_IN, 32'd11 + offset, 15, resp);
                begin
                    wait (u_fir.busy_q);
                    repeat (latency - 2 + offset) @(negedge clk);
                    s_axi_araddr = DATA_OUT; s_axi_arvalid = 1;
                    while (!s_axi_arready) @(negedge clk);
                    @(negedge clk); s_axi_arvalid = 0;
                    wait_high_r;
                    r = s_axi_rdata;
                    repeat (3) @(negedge clk);
                    s_axi_rready = 1;
                    @(negedge clk); s_axi_rready = 0;
                end
            join
            check_eq(n_rd - rd_before, 1, "one read pulse per DATA_OUT transaction");
            check_eq(n_done - done_before, 1, "one HLS completion per input");
            check_eq(r, offset <= 0 ? previous_y : new_y, "DATA_OUT snapshot at completion boundary");
            check_eq(fir_irq, offset <= 0, "unread coincident/new completion stays pending");
            axi_read(DATA_OUT, r, resp);
            check_eq(r, new_y, "new result remains readable");
            check_eq(fir_irq, 0, "subsequent result read clears DONE");
            previous_y = new_y;
            push(32'd11 + offset);
        end
        $display("Checks: %0d, errors: %0d", checks, errors);
        if (errors == 0) $display("TEST PASSED");
        else $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end
endmodule
