`timescale 1ns/1ps
`include "interrupt_pkg.vh"

//======================================================================
// INTERRUPT AXI WRAPPER  (viết mới cho dự án riscv-soc-fir-hls)
//======================================================================
// Khối thanh ghi nối interrupt_controller vào axi_interconnect.
// Repo tiny-riscv-soc không có file này (chỉ được nhắc tới trong chú thích
// của interrupt_pkg.vh), nên viết lại theo bản đồ thanh ghi dưới đây.
//
// Bản đồ thanh ghi (offset từ INTERRUPT_BASE = 0x1C0, chọn bằng addr[5:2]):
//   0x00  ENABLE  (R/W) bit[NUM_INTERRUPTS-1:0] cho phép từng nguồn
//   0x04  PENDING (RO)  bit[NUM_INTERRUPTS-1:0] cờ đang chờ (từ controller)
//   0x08  ACK     (WO)  ghi bit0=1: tạo xung ack 1 chu kỳ,
//                       bit[3:1] = số hiệu nguồn cần xóa (ack_id).
//                       Đọc ra 0.
//   0x0C  STATUS  (RO)  bit0 = có ngắt, bit[3:1] = số hiệu ngắt ưu tiên cao nhất
// ACK dùng cùng định dạng với STATUS: ISR đọc STATUS rồi ghi lại đúng giá trị
// đó vào ACK là xóa đúng nguồn vừa phục vụ.
//
// Giao thức bus (xem chú thích đầu AXI_Interconnect.v):
//   ghi : wr_en xung 1 chu kỳ, wr_addr/wdata hợp lệ đúng chu kỳ đó
//   đọc : rd_en xung 1 chu kỳ; rdata chốt theo rd_en (trễ 1 chu kỳ)
//
// Reset: rst_n mức thấp như các ngoại vi khác trên bus. interrupt_controller
// dùng rst mức cao, do soc_top tạo (rst = ~rst_n).
//======================================================================

module interrupt_axi_wrapper (

    input  wire                        clk,
    input  wire                        rst_n,

    //------------------------------------------------------------
    // Bus side (axi_interconnect)
    //------------------------------------------------------------

    input  wire                        wr_en,
    input  wire                        rd_en,
    input  wire [31:0]                 wr_addr,
    input  wire [31:0]                 rd_addr,
    input  wire [31:0]                 wdata,
    output reg  [31:0]                 rdata,

    //------------------------------------------------------------
    // Controller side (interrupt_controller)
    //------------------------------------------------------------

    output reg  [`NUM_INTERRUPTS-1:0]  irq_enable,
    output reg                         ack,
    output reg  [`INT_ID_WIDTH-1:0]    ack_id,
    input  wire [`NUM_INTERRUPTS-1:0]  pending,
    input  wire                        interrupt,
    input  wire [`INT_ID_WIDTH-1:0]    interrupt_id

);

    //------------------------------------------------------------
    // Register index = offset[5:2]
    //------------------------------------------------------------

    localparam [3:0] IDX_ENABLE  = `INT_ENABLE_REG  >> 2;
    localparam [3:0] IDX_PENDING = `INT_PENDING_REG >> 2;
    localparam [3:0] IDX_ACK     = `INT_ACK_REG     >> 2;
    localparam [3:0] IDX_STATUS  = `INT_STATUS_REG  >> 2;

    wire [3:0] wr_idx = wr_addr[5:2];
    wire [3:0] rd_idx = rd_addr[5:2];


    //------------------------------------------------------------
    // ENABLE register
    //------------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            irq_enable <= {`NUM_INTERRUPTS{1'b0}};
        else if (wr_en && (wr_idx == IDX_ENABLE))
            irq_enable <= wdata[`NUM_INTERRUPTS-1:0];
    end


    //------------------------------------------------------------
    // ACK: self-clearing one-cycle pulse
    //------------------------------------------------------------

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ack    <= 1'b0;
            ack_id <= {`INT_ID_WIDTH{1'b0}};
        end else begin
            ack <= wr_en && (wr_idx == IDX_ACK) && wdata[0];
            if (wr_en && (wr_idx == IDX_ACK))
                ack_id <= wdata[`INT_ID_WIDTH:1];
        end
    end


    //------------------------------------------------------------
    // Read data (registered on rd_en, no read side effects)
    //------------------------------------------------------------

    reg [31:0] rd_mux;

    always @(*) begin
        rd_mux = 32'd0;
        case (rd_idx)
            IDX_ENABLE:  rd_mux[`NUM_INTERRUPTS-1:0] = irq_enable;
            IDX_PENDING: rd_mux[`NUM_INTERRUPTS-1:0] = pending;
            IDX_STATUS:  rd_mux[`INT_ID_WIDTH:0]     = {interrupt_id, interrupt};
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
