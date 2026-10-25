// axi_lite_bfm.vh : AXI4-Lite master BFM + protocol checker (include trong module TB)

task check_eq;
    input [31:0]  got;
    input [31:0]  exp;
    input [511:0] what;
    begin
        checks = checks + 1;
        if (got !== exp) begin
            errors = errors + 1;
            $display("[%0t] ERROR %0s: got 0x%08h, exp 0x%08h", $time, what, got, exp);
        end
    end
endtask

function integer bp_delay;
    input dummy;
    begin
        if (max_bp == 0)
            bp_delay = 0;
        else
            bp_delay = {$random(seed)} % (max_bp + 1);
    end
endfunction

// Wait for a level with timeout (in negedges)
task wait_high_b;
    integer k;
    begin
        k = 0;
        while (!s_axi_bvalid && k < 20000) begin
            @(negedge clk);
            k = k + 1;
        end
        if (!s_axi_bvalid) begin
            errors = errors + 1;
            $display("[%0t] ERROR BVALID timeout", $time);
        end
    end
endtask

task wait_high_r;
    integer k;
    begin
        k = 0;
        while (!s_axi_rvalid && k < 20000) begin
            @(negedge clk);
            k = k + 1;
        end
        if (!s_axi_rvalid) begin
            errors = errors + 1;
            $display("[%0t] ERROR RVALID timeout", $time);
        end
    end
endtask

// AW then W (same order as cpu_axi_master), then B with random BREADY delay
task axi_write;
    input  [31:0] addr;
    input  [31:0] data;
    input  [3:0]  strb;
    output [1:0]  resp;
    integer d;
    begin
        @(negedge clk);
        s_axi_awaddr  = addr;
        s_axi_awvalid = 1'b1;
        while (!s_axi_awready) @(negedge clk);
        @(negedge clk);                      // AW handshake happened
        s_axi_awvalid = 1'b0;
        s_axi_awaddr  = 32'hFFFF_FFFC;       // accepted address must be latched
        s_axi_wdata   = data;
        s_axi_wstrb   = strb;
        s_axi_wvalid  = 1'b1;
        while (!s_axi_wready) @(negedge clk);
        @(negedge clk);                      // W handshake happened
        s_axi_wvalid  = 1'b0;
        wait_high_b;
        b_seen_hook(addr, data, strb);       // defined by the TB
        d = bp_delay(0);
        repeat (d) @(negedge clk);
        resp = s_axi_bresp;
        s_axi_bready = 1'b1;
        @(negedge clk);                      // B handshake happened
        s_axi_bready = 1'b0;
    end
endtask

task axi_read;
    input  [31:0] addr;
    output [31:0] data;
    output [1:0]  resp;
    integer d;
    begin
        @(negedge clk);
        s_axi_araddr  = addr;
        s_axi_arvalid = 1'b1;
        while (!s_axi_arready) @(negedge clk);
        @(negedge clk);                      // AR handshake happened
        s_axi_arvalid = 1'b0;
        s_axi_araddr  = 32'hFFFF_FFFC;       // payload may change after handshake
        wait_high_r;
        d = bp_delay(0);
        repeat (d) @(negedge clk);
        data = s_axi_rdata;
        resp = s_axi_rresp;
        s_axi_rready = 1'b1;
        @(negedge clk);                      // R handshake happened
        s_axi_rready = 1'b0;
    end
endtask

// Protocol checker: VALID must stay high, payload stable, until READY
reg        chk_b_hold, chk_r_hold;
reg [1:0]  chk_bresp_q, chk_rresp_q;
reg [31:0] chk_rdata_q;

always @(posedge clk) begin
    if (chk_b_hold && (!s_axi_bvalid || s_axi_bresp !== chk_bresp_q)) begin
        errors = errors + 1;
        $display("[%0t] ERROR protocol: BVALID/BRESP changed before BREADY", $time);
    end
    if (chk_r_hold && (!s_axi_rvalid || s_axi_rresp !== chk_rresp_q || s_axi_rdata !== chk_rdata_q)) begin
        errors = errors + 1;
        $display("[%0t] ERROR protocol: RVALID/RDATA/RRESP changed before RREADY", $time);
    end
    chk_b_hold  <= s_axi_bvalid && !s_axi_bready;
    chk_bresp_q <= s_axi_bresp;
    chk_r_hold  <= s_axi_rvalid && !s_axi_rready;
    chk_rresp_q <= s_axi_rresp;
    chk_rdata_q <= s_axi_rdata;
end

initial begin
    chk_b_hold = 1'b0;
    chk_r_hold = 1'b0;
end
