`timescale 1ns/1ps

// Chuyển bus CPU sang AXI4-Lite và chốt lỗi đầu tiên vào BUSERR.
`include "soc_pkg.vh"

module cpu_axi_master (

    input wire clk,
    input wire rst_n,

    // CPU Interface

    input wire        mem_read,
    input wire        mem_write,

    input wire [31:0] mem_addr,
    input wire [31:0] mem_wdata,

    output reg [31:0] mem_rdata,
    output reg        mem_ready,
    output reg        mem_err,        // A1: 1 cùng chu kỳ mem_ready nếu BRESP/RRESP != OKAY

    // A1: bus error capture (first error, sticky until err_clr)

    input  wire       err_clr,
    output reg        err_valid,
    output reg        err_write,
    output reg [1:0]  err_resp,
    output reg [31:0] err_addr,
    output reg        err_overflow,

    // AXI Write Address Channel

    output reg [31:0] M_AXI_AWADDR,
    output reg        M_AXI_AWVALID,
    input  wire        M_AXI_AWREADY,

    // AXI Write Data Channel

    output reg [31:0] M_AXI_WDATA,
    output reg [3:0]  M_AXI_WSTRB,
    output reg        M_AXI_WVALID,
    input  wire        M_AXI_WREADY,

    // AXI Write Response Channel

    input  wire [1:0] M_AXI_BRESP,
    input  wire       M_AXI_BVALID,
    output reg        M_AXI_BREADY,

    // AXI Read Address Channel

    output reg [31:0] M_AXI_ARADDR,
    output reg        M_AXI_ARVALID,
    input  wire        M_AXI_ARREADY,

    // AXI Read Data Channel

    input wire [31:0] M_AXI_RDATA,
    input wire [1:0]  M_AXI_RRESP,
    input wire        M_AXI_RVALID,
    output reg        M_AXI_RREADY

);

    // FSM STATES

    localparam ST_IDLE       = 3'd0;
    localparam ST_WRITE_ADDR = 3'd1;
    localparam ST_WRITE_DATA = 3'd2;
    localparam ST_WRITE_RESP = 3'd3;
    localparam ST_READ_ADDR  = 3'd4;
    localparam ST_READ_DATA  = 3'd5;

    reg [2:0] state;

    // CPU REQUEST REGISTERS

    reg [31:0] saved_addr;
    reg [31:0] saved_wdata;

    // Sequential FSM

    always @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            state <= ST_IDLE;

            saved_addr  <= 32'd0;
            saved_wdata <= 32'd0;

            M_AXI_AWADDR  <= 32'd0;
            M_AXI_AWVALID <= 1'b0;

            M_AXI_WDATA   <= 32'd0;
            M_AXI_WSTRB   <= 4'b1111;
            M_AXI_WVALID  <= 1'b0;

            M_AXI_BREADY  <= 1'b0;

            M_AXI_ARADDR  <= 32'd0;
            M_AXI_ARVALID <= 1'b0;

            M_AXI_RREADY  <= 1'b0;

            mem_rdata     <= 32'd0;
            mem_ready     <= 1'b0;
            mem_err       <= 1'b0;

            err_valid     <= 1'b0;
            err_write     <= 1'b0;
            err_resp      <= 2'b00;
            err_addr      <= 32'd0;
            err_overflow  <= 1'b0;

        end

        else begin

            // Default: mem_ready is a one-cycle completion pulse

            mem_ready <= 1'b0;
            mem_err   <= 1'b0;

            if (err_clr) begin
                err_valid    <= 1'b0;
                err_overflow <= 1'b0;
            end

            // FSM

            case (state)

                // IDLE

                ST_IDLE: begin

                    // Defaults

                    M_AXI_AWVALID <= 1'b0;
                    M_AXI_WVALID  <= 1'b0;
                    M_AXI_BREADY  <= 1'b0;

                    M_AXI_ARVALID <= 1'b0;
                    M_AXI_RREADY  <= 1'b0;

                    // Capture WRITE request

                    // Chặn nhận lại yêu cầu cũ trong chu kỳ mem_ready=1.
                    if (mem_write && !mem_ready) begin

                        saved_addr  <= mem_addr;
                        saved_wdata <= mem_wdata;

                        state <= ST_WRITE_ADDR;

                    end

                    // Capture READ request

                    else if (mem_read && !mem_ready) begin

                        saved_addr <= mem_addr;

                        state <= ST_READ_ADDR;

                    end

                end

                // WRITE ADDRESS

                ST_WRITE_ADDR: begin

                    // Drive address

                    M_AXI_AWADDR  <= saved_addr;
                    M_AXI_AWVALID <= 1'b1;

                    // Wait for AW handshake

                    if (M_AXI_AWVALID && M_AXI_AWREADY) begin

                        M_AXI_AWVALID <= 1'b0;

                        state <= ST_WRITE_DATA;

                    end

                end

                // WRITE DATA

                ST_WRITE_DATA: begin

                    // Drive write data

                    M_AXI_WDATA  <= saved_wdata;
                    M_AXI_WSTRB  <= 4'b1111;
                    M_AXI_WVALID <= 1'b1;

                    // Wait for W handshake

                    if (M_AXI_WVALID && M_AXI_WREADY) begin

                        M_AXI_WVALID <= 1'b0;

                        state <= ST_WRITE_RESP;

                    end

                end

                // WRITE RESPONSE

                ST_WRITE_RESP: begin

                    // Always ready for response

                    M_AXI_BREADY <= 1'b1;

                    // Wait for BVALID

                    if (M_AXI_BVALID && M_AXI_BREADY) begin

                        M_AXI_BREADY <= 1'b0;

                        // Write transaction completed

                        mem_ready <= 1'b1;

                        if (M_AXI_BRESP != 2'b00) begin
                            mem_err <= 1'b1;
                            if (err_valid && !err_clr)
                                err_overflow <= 1'b1;
                            else begin
                                err_valid <= 1'b1;
                                err_write <= 1'b1;
                                err_resp  <= M_AXI_BRESP;
                                err_addr  <= saved_addr;
                            end
                        end

                        state <= ST_IDLE;

                    end

                end

                // READ ADDRESS

                ST_READ_ADDR: begin

                    M_AXI_ARADDR  <= saved_addr;
                    M_AXI_ARVALID <= 1'b1;

                    // AR handshake

                    if (M_AXI_ARVALID && M_AXI_ARREADY) begin

                        M_AXI_ARVALID <= 1'b0;

                        state <= ST_READ_DATA;

                    end

                end

                // READ DATA

                ST_READ_DATA: begin

                    M_AXI_RREADY <= 1'b1;

                    // Wait for RVALID

                    if (M_AXI_RVALID && M_AXI_RREADY) begin

                        // A1: payload of a failed read is never forwarded
                        mem_rdata <= (M_AXI_RRESP == 2'b00) ? M_AXI_RDATA : 32'd0;

                        if (M_AXI_RRESP != 2'b00) begin
                            mem_err <= 1'b1;
                            if (err_valid && !err_clr)
                                err_overflow <= 1'b1;
                            else begin
                                err_valid <= 1'b1;
                                err_write <= 1'b0;
                                err_resp  <= M_AXI_RRESP;
                                err_addr  <= saved_addr;
                            end
                        end

                        M_AXI_RREADY <= 1'b0;

                        // Read transaction completed

                        mem_ready <= 1'b1;

                        state <= ST_IDLE;

                    end

                end

                // DEFAULT

                default: begin

                    state <= ST_IDLE;

                    M_AXI_AWVALID <= 1'b0;
                    M_AXI_WVALID  <= 1'b0;
                    M_AXI_BREADY  <= 1'b0;

                    M_AXI_ARVALID <= 1'b0;
                    M_AXI_RREADY  <= 1'b0;

                end

            endcase

        end

    end

endmodule
