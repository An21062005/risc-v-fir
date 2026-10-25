`timescale 1ns/1ps
`include "soc_pkg.vh"

// tb_axi_fault : axi_interconnect error responses, timeout and backpressure (A1/A2)

module tb_axi_fault;
    parameter integer N_TX = 3000;
    localparam integer TIMEOUT = 32;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  [31:0] awaddr = 0, wdata = 0, araddr = 0;
    reg  [3:0]  wstrb = 4'hF;
    reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;

    wire timer_wr_en, timer_rd_en, interrupt_wr_en, interrupt_rd_en, fir_wr_en, fir_rd_en;
    wire [31:0] write_addr, write_data, read_addr;
    wire        ext_read, ext_write;
    wire [31:0] ext_addr, ext_wdata;
    reg  [31:0] ext_rdata = 0;
    reg         ext_ready = 0;

    axi_interconnect #(.ENABLE_EXT_RAM(1), .EXT_RAM_TIMEOUT(TIMEOUT)) dut (
        .clk(clk), .rst_n(rst_n),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .timer_rdata(32'hA000_0001), .interrupt_rdata(32'hB000_0002), .fir_rdata(32'hC000_0003),
        .timer_wr_en(timer_wr_en), .timer_rd_en(timer_rd_en),
        .interrupt_wr_en(interrupt_wr_en), .interrupt_rd_en(interrupt_rd_en),
        .fir_wr_en(fir_wr_en), .fir_rd_en(fir_rd_en),
        .write_addr(write_addr), .write_data(write_data), .read_addr(read_addr),
        .ext_ram_read(ext_read), .ext_ram_write(ext_write), .ext_ram_addr(ext_addr),
        .ext_ram_wdata(ext_wdata), .ext_ram_rdata(ext_rdata), .ext_ram_ready(ext_ready));

    integer errors = 0, checks = 0, seed = 1;
    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;
    task ck; input cond; input [8*100-1:0] msg;
        begin checks = checks + 1;
            if (cond !== 1'b1) begin errors = errors + 1;
                if (errors <= 20) $display("ERROR %0s (cycle %0d)", msg, cyc); end
        end
    endtask

    // Behavioural backend: 16 words, random latency, commit at ready
    reg [31:0] mem [0:15];
    integer    lat, busy = 0, wait_n = 0, commits = 0, never = 0;
    reg [31:0] req_addr, req_data; reg req_wr;
    integer    commit_cnt [0:65535];      // per write value: times committed
    integer    k;
    always @(posedge clk) begin
        ext_ready <= 1'b0;
        if (rst_n) begin
            if (busy) begin
                ck(ext_read == !req_wr && ext_write == req_wr && ext_addr == req_addr &&
                   (!req_wr || ext_wdata == req_data), "backend request held stable until ready");
                if (wait_n == 0) begin
                    ext_ready <= 1'b1;
                    if (req_wr) begin
                        mem[req_addr[5:2]] <= req_data; commits = commits + 1;
                        commit_cnt[req_data[15:0]] = commit_cnt[req_data[15:0]] + 1;
                    end else
                        ext_rdata <= mem[req_addr[5:2]];
                    busy = 0;
                end else
                    wait_n = wait_n - 1;
            end else if ((ext_read || ext_write) && !ext_ready) begin
                ck(!(ext_read && ext_write), "backend never sees read and write together");
                req_wr = ext_write; req_addr = ext_addr; req_data = ext_wdata;
                lat = $random(seed) & 15;
                if (lat < 9)       wait_n = $random(seed) & 15;              // in time
                else if (lat < 13) wait_n = TIMEOUT - 6 + ($random(seed) & 15); // around the limit
                else begin         wait_n = 3 * TIMEOUT; never = never + 1; end // late -> orphan
                busy = 1;
            end
        end
    end

    // Response stability monitor + strobe counters
    reg        pb = 0, pr = 0; reg [1:0] pbr, prr; reg [31:0] prd;
    integer    strobes = 0;
    always @(posedge clk) if (rst_n) begin
        if (pb && !bready) ck(bvalid && bresp == pbr, "BVALID/BRESP stable until BREADY");
        if (pr && !rready) ck(rvalid && rresp == prr && rdata == prd, "RVALID/RRESP/RDATA stable until RREADY");
        pb <= bvalid && !bready; pbr <= bresp;
        pr <= rvalid && !rready; prr <= rresp; prd <= rdata;
        strobes = strobes + timer_wr_en + interrupt_wr_en + fir_wr_en + timer_rd_en + interrupt_rd_en + fir_rd_en;
    end

    // Master
    integer n, kind, d, t0, n_ok = 0, n_slv = 0, n_dec = 0, n_tmo = 0, wseq = 1;
    integer okay_w [0:65535];
    reg [31:0] a, v; reg [1:0] exp_resp; reg wr; integer strobes0, commits0;

    reg [1:0] pbr_last, prr_last; reg [31:0] prd_last;
    always @(posedge clk) begin
        if (bvalid && bready) pbr_last <= bresp;
        if (rvalid && rready) begin prr_last <= rresp; prd_last <= rdata; end
    end

    // liveness watchdog: a handshake that never completes ends the test as FAILED
    reg wd_hit = 0; integer hs_wait = 0;
    always @(posedge clk) begin
        hs_wait = ((awvalid && !awready) || (wvalid && !wready) || (arvalid && !arready)) ? hs_wait + 1 : 0;
        if (hs_wait > 4 * TIMEOUT + 200 && !wd_hit) begin
            wd_hit = 1; errors = errors + 1;
            $display("ERROR liveness: AW/W/AR not accepted for %0d cycles (bus stuck)", hs_wait);
            $display("Checks: %0d, errors: %0d", checks, errors); $display("TEST FAILED"); $finish;
        end
    end

    task pick;   // address class
        begin
            kind = $random(seed) & 7;
            case (kind)
                0, 1, 2: a = `EXT_RAM_BASE + (($random(seed) & 15) << 2);       // ext RAM word
                3:       a = `FIR_BASE + 32'h0C;                                // MMIO (FIR CTRL)
                4:       a = 32'h0000_0300 + (($random(seed) & 3) << 2);        // unmapped
                5:       a = 32'h0002_0000;                                     // unmapped (above RAM)
                6:       a = `EXT_RAM_BASE + 2;                                 // unaligned RAM
                default: a = `TIMER_BASE + 32'h04 + 1;                          // unaligned MMIO
            endcase
        end
    endtask

    task stall; input integer max; integer s;
        begin s = $random(seed) & max; repeat (s) @(negedge clk); end
    endtask

    // one AXI handshake on a channel: VALID held until VALID && READY at a clock edge
    task do_write;
        integer resp_wait;
        begin
            v = {16'h5A00 ^ (wseq >> 16), wseq[15:0]}; wseq = wseq + 1;
            wstrb = (kind <= 2 && (($random(seed) & 7) == 0)) ? 4'b0011 : 4'hF;   // partial RAM write
            strobes0 = strobes;
            @(negedge clk);
            awaddr = a; wdata = v; t0 = cyc;
            fork
                begin : aw_ch
                    stall(3); awvalid = 1;
                    @(posedge clk); while (!awready && !wd_hit) @(posedge clk);
                    #1 awvalid = 0;
                end
                begin : w_ch
                    stall(3); wvalid = 1;              // may precede AW: WREADY only after AW
                    @(posedge clk); while (!wready && !wd_hit) @(posedge clk);
                    #1 wvalid = 0;
                end
            join
            resp_wait = 0;
            while (!bvalid && resp_wait < 4 * TIMEOUT + 200) begin @(negedge clk); resp_wait = resp_wait + 1; end
            ck(bvalid === 1'b1 && cyc - t0 < TIMEOUT + 64, "write responds within TIMEOUT + slack");
            stall(7);                               // BREADY backpressure
            @(negedge clk); bready = 1;
            @(posedge clk); #1 bready = 0;
            @(negedge clk);
            if (a >= `EXT_RAM_BASE && a <= `EXT_RAM_END) begin
                if (a[1:0] != 0 || wstrb != 4'hF) exp_resp = `AXI_RESP_SLVERR;
                else exp_resp = 2'bxx;              // OKAY or timeout SLVERR
            end
            else if (a >= `FIR_BASE && a <= `FIR_END || a >= `TIMER_BASE && a <= `TIMER_END)
                exp_resp = (a[1:0] != 0) ? `AXI_RESP_SLVERR : `AXI_RESP_OKAY;
            else exp_resp = `AXI_RESP_DECERR;
            if (exp_resp !== 2'bxx) ck(pbr_last == exp_resp, "write response code");
            else ck(pbr_last == `AXI_RESP_OKAY || pbr_last == `AXI_RESP_SLVERR, "RAM write OKAY or timeout SLVERR");
            if (pbr_last == `AXI_RESP_OKAY) n_ok = n_ok + 1;
            if (pbr_last == `AXI_RESP_DECERR) n_dec = n_dec + 1;
            if (pbr_last == `AXI_RESP_SLVERR) n_slv = n_slv + 1;
            if (exp_resp === 2'bxx && pbr_last == `AXI_RESP_SLVERR) n_tmo = n_tmo + 1;
            if (exp_resp !== 2'bxx && exp_resp != `AXI_RESP_OKAY)
                ck(strobes == strobes0, "rejected / DECERR write: no peripheral strobe");
            if (exp_resp === `AXI_RESP_OKAY) ck(strobes == strobes0 + 1, "MMIO write: exactly one wr_en");
            if (exp_resp !== 2'bxx) ck(commit_cnt[v[15:0]] == 0, "rejected / DECERR / MMIO write never reaches the backend");
            if (exp_resp === 2'bxx && pbr_last == `AXI_RESP_OKAY)
                ck(commit_cnt[v[15:0]] == 1, "OKAY write committed exactly once (before B)");
        end
    endtask


    task do_read;
        integer resp_wait;
        reg [31:0] expect_mem;
        begin
            strobes0 = strobes;
            @(negedge clk);
            araddr = a; t0 = cyc;
            stall(3); arvalid = 1;
            @(posedge clk); while (!arready && !wd_hit) @(posedge clk);
            #1 arvalid = 0;
            resp_wait = 0;
            while (!rvalid && resp_wait < 4 * TIMEOUT + 200) begin @(negedge clk); resp_wait = resp_wait + 1; end
            ck(rvalid === 1'b1 && cyc - t0 < TIMEOUT + 64, "read responds within TIMEOUT + slack");
            stall(7);                               // RREADY backpressure
            @(negedge clk); expect_mem = mem[a[5:2]]; rready = 1;
            @(posedge clk); #1 rready = 0;
            @(negedge clk);
            if (a >= `EXT_RAM_BASE && a <= `EXT_RAM_END) begin
                if (a[1:0] != 0) begin
                    n_slv = n_slv + 1;
                    ck(prr_last == `AXI_RESP_SLVERR && prd_last == 0, "unaligned RAM read: SLVERR, 0");
                end else if (prr_last == `AXI_RESP_OKAY) begin
                    n_ok = n_ok + 1; ck(prd_last == expect_mem, "OKAY RAM read returns backend memory word");
                end else begin
                    n_slv = n_slv + 1; n_tmo = n_tmo + 1;
                    ck(prr_last == `AXI_RESP_SLVERR && prd_last == 0, "timed-out RAM read: SLVERR, RDATA 0");
                end
            end
            else if (a >= `FIR_BASE && a <= `FIR_END || a >= `TIMER_BASE && a <= `TIMER_END) begin
                if (a[1:0] != 0) begin
                    n_slv = n_slv + 1;
                    ck(prr_last == `AXI_RESP_SLVERR && prd_last == 0 && strobes == strobes0,
                       "unaligned MMIO read: SLVERR, 0, no rd_en");
                end else begin
                    n_ok = n_ok + 1;
                    ck(prr_last == `AXI_RESP_OKAY && strobes == strobes0 + 1 && prd_last == 32'hC000_0003,
                       "MMIO read OKAY, one rd_en, FIR data");
                end
            end
            else begin
                n_dec = n_dec + 1;
                ck(prr_last == `AXI_RESP_DECERR && prd_last == 0 && strobes == strobes0,
                   "unmapped read: DECERR, RDATA 0, no rd_en");
            end
        end
    endtask

    integer b_seen = 0, r_seen = 0, aw_seen = 0, ar_seen = 0;
    always @(posedge clk) if (rst_n) begin
        if (bvalid && bready) b_seen = b_seen + 1;
        if (rvalid && rready) r_seen = r_seen + 1;
        if (awvalid && awready) aw_seen = aw_seen + 1;
        if (arvalid && arready) ar_seen = ar_seen + 1;
    end

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        for (k = 0; k < 16; k = k + 1) mem[k] = 32'hF000_0000 + k;
        for (k = 0; k < 65536; k = k + 1) begin commit_cnt[k] = 0; okay_w[k] = 0; end
        repeat (4) @(negedge clk); rst_n = 1; repeat (2) @(negedge clk);
        for (n = 0; n < N_TX; n = n + 1) begin
            pick;
            if ($random(seed) & 1) do_write; else do_read;
            stall(3);
        end
        // let any orphan finish, then check nothing completes spuriously
        repeat (4 * TIMEOUT) @(negedge clk);
        ck(b_seen == aw_seen && r_seen == ar_seen, "exactly one response per accepted AW / AR");
        ck(!bvalid && !rvalid, "no response without a request");
        for (k = 0; k < 65536; k = k + 1) if (commit_cnt[k] > 1) ck(0, "a write value was committed twice");
        $display("INFO AXI fault: %0d transactions (seed %0d): OKAY %0d, SLVERR %0d (timeouts %0d), DECERR %0d, backend late %0d, commits %0d",
                 N_TX, seed, n_ok, n_slv, n_tmo, n_dec, never, commits);
        ck(n_tmo > 50 && n_dec > 100 && n_ok > 500, "coverage: timeouts, DECERR and OKAY all exercised");
        $display("Checks: %0d, errors: %0d", checks, errors);
        if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED");
        $finish;
    end
endmodule
