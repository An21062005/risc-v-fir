`timescale 1ns/1ps
`include "interrupt_pkg.vh"

// Thanh ghi MMIO quản lý enable, claim/ACK và trạng thái lỗi bus.

module interrupt_axi_wrapper (

    input  wire                        clk,
    input  wire                        rst_n,

    // Bus side (axi_interconnect)

    input  wire                        wr_en,
    input  wire                        rd_en,
    input  wire [31:0]                 wr_addr,
    input  wire [31:0]                 rd_addr,
    input  wire [31:0]                 wdata,
    output reg  [31:0]                 rdata,

    // Controller side (interrupt_controller)

    output reg  [`NUM_INTERRUPTS-1:0]  irq_enable,
    output wire                        ack,
    output wire [`INT_ID_WIDTH-1:0]    ack_id,
    output wire                        status_rd,   // FIX I1: claim
    input  wire [`NUM_INTERRUPTS-1:0]  pending,
    input  wire                        interrupt,
    input  wire [`INT_ID_WIDTH-1:0]    interrupt_id,

    // A1: bus error status (cpu_axi_master)

    input  wire                        buserr_valid,
    input  wire                        buserr_write,
    input  wire [1:0]                  buserr_resp,
    input  wire                        buserr_overflow,
    input  wire [31:0]                 buserr_addr,
    output wire                        buserr_clr

);

    // Register index = offset[5:2]

    localparam [3:0] IDX_ENABLE  = `INT_ENABLE_REG  >> 2;
    localparam [3:0] IDX_PENDING = `INT_PENDING_REG >> 2;
    localparam [3:0] IDX_ACK     = `INT_ACK_REG     >> 2;
    localparam [3:0] IDX_STATUS  = `INT_STATUS_REG  >> 2;
    localparam [3:0] IDX_BUSERR  = `INT_BUSERR_REG  >> 2;
    localparam [3:0] IDX_BUSERR_ADDR = `INT_BUSERR_ADDR_REG >> 2;

    wire [3:0] wr_idx = wr_addr[5:2];
    wire [3:0] rd_idx = rd_addr[5:2];


    // ENABLE register

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            irq_enable <= {`NUM_INTERRUPTS{1'b0}};
        else if (wr_en && (wr_idx == IDX_ENABLE))
            irq_enable <= wdata[`NUM_INTERRUPTS-1:0];
    end


    // ACK: self-clearing one-cycle pulse

    // FIX C4: same cycle as wr_en (was registered: +1 cycle)
    assign ack    = wr_en && (wr_idx == IDX_ACK) && wdata[0];
    assign ack_id = wdata[`INT_ID_WIDTH:1];
    assign status_rd = rd_en && (rd_idx == IDX_STATUS);

    // A1: W1C clear of the captured bus error
    assign buserr_clr = wr_en && (wr_idx == IDX_BUSERR) && wdata[0];


    // Read data (registered on rd_en, no read side effects)

    reg [31:0] rd_mux;

    always @(*) begin
        rd_mux = 32'd0;
        case (rd_idx)
            IDX_ENABLE:  rd_mux[`NUM_INTERRUPTS-1:0] = irq_enable;
            IDX_PENDING: rd_mux[`NUM_INTERRUPTS-1:0] = pending;
            IDX_STATUS:  rd_mux[`INT_ID_WIDTH:0]     = {interrupt_id, interrupt};
            // fields read 0 while no error is captured (after reset / W1C clear)
            IDX_BUSERR:  rd_mux[4:0] = buserr_valid ? {buserr_overflow, buserr_resp, buserr_write, 1'b1} : 5'd0;
            IDX_BUSERR_ADDR: rd_mux  = buserr_valid ? buserr_addr : 32'd0;
            default:     rd_mux = 32'd0;           // ACK and unmapped read 0
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            rdata <= 32'd0;
        else if (rd_en)
            rdata <= rd_mux;
    end

endmodule
