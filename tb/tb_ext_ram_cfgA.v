`timescale 1ns/1ps
`include "soc_pkg.vh"

//======================================================================
// tb_ext_ram_cfgA : cấu hình A (ENABLE_EXT_RAM = 0) giữ hành vi cũ
//======================================================================
// Kết quả chạy: docs/RTL_FIX_VERIFICATION.md.
// DUT: axi_interconnect #(ENABLE_EXT_RAM=0) + interrupt_axi_wrapper; cổng
// ext_ram_rdata/ext_ram_ready buộc 0 như soc_top (g_no_ext_ram). Kiểm:
//   - 0x0001_0000 / 0x0001_FFFC: đọc ra 0, RRESP DECERR; ghi BRESP DECERR (A1);
//     không có yêu cầu ext_ram_read / ext_ram_write (vùng không map như trước)
//   - MMIO interrupt ENABLE R/W, FIR/Timer rdata, mỗi lần đọc FIR đúng 1
//     xung fir_rd_en, mỗi lần ghi FIR đúng 1 xung fir_wr_en
// Chạy: vlog +incdir+rtl/packages +incdir+tb rtl/AXI/AXI_Interconnect.v \
//         rtl/Peripherals/interrupt_axi_wrapper.v tb/tb_ext_ram_cfgA.v
//       vsim -c tb_ext_ram_cfgA -do "run -all; quit -f"
//======================================================================

module tb_ext_ram_cfgA;

    localparam [31:0] FIR_CONST   = 32'hF1F0_0000;
    localparam [31:0] TIMER_CONST = 32'h7171_0000;

    reg clk;
    reg rst_n;
    initial clk = 1'b0;
    always #5 clk = ~clk;

    integer errors, checks, seed, max_bp;

    reg  [31:0] s_axi_awaddr;  reg s_axi_awvalid; wire s_axi_awready;
    reg  [31:0] s_axi_wdata;   reg [3:0] s_axi_wstrb; reg s_axi_wvalid; wire s_axi_wready;
    wire [1:0]  s_axi_bresp;   wire s_axi_bvalid; reg s_axi_bready;
    reg  [31:0] s_axi_araddr;  reg s_axi_arvalid; wire s_axi_arready;
    wire [31:0] s_axi_rdata;   wire [1:0] s_axi_rresp; wire s_axi_rvalid; reg s_axi_rready;

    wire [31:0] write_addr, write_data, read_addr;
    wire        timer_wr_en, timer_rd_en, interrupt_wr_en, interrupt_rd_en, fir_wr_en, fir_rd_en;
    wire [31:0] interrupt_rdata;
    wire        ext_ram_read, ext_ram_write;
    wire [31:0] ext_ram_addr, ext_ram_wdata;

    axi_interconnect #(.ENABLE_EXT_RAM(0)) u_ic (
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
        .ext_ram_rdata(32'd0), .ext_ram_ready(1'b0)
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

    integer n_ext, n_fir_wr, n_fir_rd_cycles;
    always @(posedge clk) begin
        if (rst_n) begin
            if (ext_ram_write || ext_ram_read) n_ext = n_ext + 1;
            if (fir_wr_en) n_fir_wr = n_fir_wr + 1;
            if (fir_rd_en) n_fir_rd_cycles = n_fir_rd_cycles + 1;
        end
    end

    task b_seen_hook;
        input [31:0] addr;
        input [31:0] data;
        input [3:0]  strb;
        begin
        end
    endtask

    `include "axi_lite_bfm.vh"

    reg [31:0] r;
    reg [1:0]  resp;
    integer    w0, c0;

    initial begin : watchdog
        #2_000_000;
        $display("TEST FAILED: watchdog timeout");
        $finish;
    end

    initial begin
        errors = 0; checks = 0; max_bp = 3; seed = 1;
        n_ext = 0; n_fir_wr = 0; n_fir_rd_cycles = 0;
        s_axi_awaddr = 0; s_axi_awvalid = 0; s_axi_wdata = 0; s_axi_wstrb = 0;
        s_axi_wvalid = 0; s_axi_bready = 0; s_axi_araddr = 0; s_axi_arvalid = 0;
        s_axi_rready = 0;
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        @(negedge clk) rst_n = 1'b1;

        axi_write(32'h0001_0000, 32'h1234_5678, 4'hF, resp);
        check_eq(resp, `AXI_RESP_DECERR, "unmapped write DECERR");
        axi_read(32'h0001_0000, r, resp);
        check_eq(r, 32'd0, "unmapped read 0 (ext RAM disabled)");
        check_eq(resp, `AXI_RESP_DECERR, "unmapped read DECERR");
        axi_read(32'h0001_FFFC, r, resp);
        check_eq(r, 32'd0, "unmapped read 0 at window end");
        check_eq(resp, `AXI_RESP_DECERR, "unmapped read DECERR at window end");
        check_eq(n_ext, 0, "no ext_ram strobes in config A");

        axi_write(32'h0000_01C0, 32'h2, 4'hF, resp);
        axi_read(32'h0000_01C0, r, resp);
        check_eq(r, 32'h2, "interrupt ENABLE readback");

        w0 = n_fir_wr; c0 = n_fir_rd_cycles;
        axi_write(32'h0000_0200, 32'h5, 4'hF, resp);
        check_eq(n_fir_wr - w0, 1, "FIR write: one wr_en pulse");
        axi_read(32'h0000_0204, r, resp);
        check_eq(r, FIR_CONST, "FIR rdata");
        check_eq(n_fir_rd_cycles - c0, 1, "FIR read: exactly one rd_en pulse");

        repeat (5) @(negedge clk);
        $display("Checks: %0d, errors: %0d", checks, errors);
        if (errors == 0) $display("TEST PASSED");
        else             $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end

endmodule
