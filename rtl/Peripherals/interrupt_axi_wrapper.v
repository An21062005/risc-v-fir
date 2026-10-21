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
//   0x10  BUSERR  (R/W1C) A1: lỗi bus đầu tiên (cpu_axi_master): bit0 valid,
//                       bit1 write, bit[3:2] resp, bit4 overflow; ghi bit0=1 xóa.
//   0x14  BUSERR_ADDR (RO) địa chỉ bus của lỗi đầu tiên.
// ACK dùng cùng định dạng với STATUS: ISR đọc STATUS rồi ghi lại đúng giá trị
// đó vào ACK là xóa đúng nguồn vừa phục vụ.
// C4 (2026-10-21): ack/ack_id tổ hợp ngay trong chu kỳ wr_en (trước đây chốt
//   thêm 1 chu kỳ). pending xóa trước khi CPU nhận bus_ready của lệnh sw ACK
//   -> biên 1 chu kỳ cho `sw ACK; mret` (trước đây 0). Kiểm: tb/tb_cpu_irq_c4.v.
// status_rd: xung 1 chu kỳ khi đọc STATUS = claim cho interrupt_controller (I1).
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
    output wire                        ack,
    output wire [`INT_ID_WIDTH-1:0]    ack_id,
    output wire                        status_rd,   // FIX I1: claim
    input  wire [`NUM_INTERRUPTS-1:0]  pending,
    input  wire                        interrupt,
    input  wire [`INT_ID_WIDTH-1:0]    interrupt_id,

    //------------------------------------------------------------
    // A1: bus error status (cpu_axi_master)
    //------------------------------------------------------------

    input  wire                        buserr_valid,
    input  wire                        buserr_write,
    input  wire [1:0]                  buserr_resp,
    input  wire                        buserr_overflow,
    input  wire [31:0]                 buserr_addr,
    output wire                        buserr_clr

);

    //------------------------------------------------------------
    // Register index = offset[5:2]
    //------------------------------------------------------------

    localparam [3:0] IDX_ENABLE  = `INT_ENABLE_REG  >> 2;
    localparam [3:0] IDX_PENDING = `INT_PENDING_REG >> 2;
    localparam [3:0] IDX_ACK     = `INT_ACK_REG     >> 2;
    localparam [3:0] IDX_STATUS  = `INT_STATUS_REG  >> 2;
    localparam [3:0] IDX_BUSERR  = `INT_BUSERR_REG  >> 2;
    localparam [3:0] IDX_BUSERR_ADDR = `INT_BUSERR_ADDR_REG >> 2;

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

    // FIX C4: same cycle as wr_en (was registered: +1 cycle)
    assign ack    = wr_en && (wr_idx == IDX_ACK) && wdata[0];
    assign ack_id = wdata[`INT_ID_WIDTH:1];
    assign status_rd = rd_en && (rd_idx == IDX_STATUS);

    // A1: W1C clear of the captured bus error
    assign buserr_clr = wr_en && (wr_idx == IDX_BUSERR) && wdata[0];


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
