`timescale 1ns/1ps
//------------------------------------------------------------------
// Bản sao từ tiny-riscv-soc (MIT). Thay đổi trong riscv-soc-fir-hls:
//   Thêm cổng `hold` cho if_id_reg, id_ex_reg, ex_mem_reg, mem_wb_reg.
//   id_ex_reg: tách reset bất đồng bộ và flush đồng bộ thành hai nhánh
//   (trước đây gộp `rst || (flush && !hold)`), hành vi không đổi.
//   hold = 1: thanh ghi giữ nguyên giá trị, kể cả khi có flush
//   (dùng để đóng băng toàn bộ pipeline khi CPU chờ bus ngoại vi).
//   Verilog-2001 không có giá trị mặc định cho cổng: nơi gọi cũ phải
//   nối .hold(1'b0) để giữ nguyên hành vi gốc (để hở -> hold = z -> sai).
//------------------------------------------------------------------
//--------------------------------------------------------------------------
//             Pipeline Registers
//--------------------------------------------------------------------------

module if_id_reg(

    input clk,
    input hold,              // thêm mới: 1 = giữ nguyên (đóng băng khi chờ bus)
    input rst,

    input write_enable,

    input [31:0] pc_in,
    input [31:0] instr_in,
    
    input flush,

    output reg [31:0] pc_out,
    output reg [31:0] instr_out

);

always @(posedge clk or posedge rst)
begin

    if (rst) begin

        pc_out    <= 32'd0;
        instr_out <= 32'd0;

    end

    else if (flush && !hold) begin

        pc_out    <= 32'd0;
        instr_out <= 32'h00000013;   // NOP

    end

    else if (write_enable && !hold) begin

        pc_out    <= pc_in;
        instr_out <= instr_in;

    end

end

endmodule

//......................................................................................

module id_ex_reg(

    input wire clk,
    input hold,              // thêm mới: 1 = giữ nguyên (đóng băng khi chờ bus)
    input wire rst,
    input flush,

    //------------------------------------------------
    // Data Signals
    //------------------------------------------------

    input wire [31:0] pc_in,
    input wire [31:0] read_data1_in,
    input wire [31:0] read_data2_in,
    input wire [31:0] immediate_in,

    input wire [4:0] rs1_in,
    input wire [4:0] rs2_in,
    input wire [4:0] rd_in,

    input wire [2:0] funct3_in,
    input wire [6:0] funct7_in,

    //------------------------------------------------
    // Control Signals
    //------------------------------------------------

    input wire RegWrite_in,
    input wire MemRead_in,
    input wire MemWrite_in,
    input wire MemToReg_in,

    input wire Branch_in,
    input wire Jump_in,
    input wire JumpReg_in,
    input wire isAUIPC_in,

    input wire ALUSrc_in,
    input wire isLUI_in,
  

    input wire [1:0] ALUOp_in,
   
    

    //------------------------------------------------
    // Outputs
    //------------------------------------------------

    output reg [31:0] pc_out,
    output reg [31:0] read_data1_out,
    output reg [31:0] read_data2_out,
    output reg [31:0] immediate_out,

    output reg [4:0] rs1_out,
    output reg [4:0] rs2_out,
    output reg [4:0] rd_out,

    output reg [2:0] funct3_out,
    output reg [6:0] funct7_out,

    output reg RegWrite_out,
    output reg MemRead_out,
    output reg MemWrite_out,
    output reg MemToReg_out,

    output reg Branch_out,
    output reg Jump_out,
    output reg JumpReg_out,

    output reg ALUSrc_out,
    output reg isLUI_out,
    output reg isAUIPC_out,

    output reg [1:0] ALUOp_out

);

// riscv-soc-fir-hls: rst (asynchronous) and flush (synchronous) are separate
// branches, as in if_id_reg. Priority unchanged: rst > hold > flush > load.
// The former `if (rst || (flush && !hold))` put a synchronous term in the
// async-reset condition (non-standard template).
always @(posedge clk or posedge rst) begin

    if (rst) begin

        pc_out <= 32'd0;
        read_data1_out <= 32'd0;
        read_data2_out <= 32'd0;
        immediate_out <= 32'd0;

        rs1_out <= 5'd0;
        rs2_out <= 5'd0;
        rd_out <= 5'd0;

        funct3_out <= 3'd0;
        funct7_out <= 7'd0;

        RegWrite_out <= 1'b0;
        MemRead_out <= 1'b0;
        MemWrite_out <= 1'b0;
        MemToReg_out <= 1'b0;

        Branch_out <= 1'b0;
        Jump_out <= 1'b0;
        JumpReg_out <= 1'b0;

        ALUSrc_out <= 1'b0;
        ALUOp_out <= 2'b00;

        isLUI_out <= 1'b0;
        isAUIPC_out <= 1'b0;

    end

    else if (flush && !hold) begin

        pc_out <= 32'd0;
        read_data1_out <= 32'd0;
        read_data2_out <= 32'd0;
        immediate_out <= 32'd0;

        rs1_out <= 5'd0;
        rs2_out <= 5'd0;
        rd_out <= 5'd0;

        funct3_out <= 3'd0;
        funct7_out <= 7'd0;

        RegWrite_out <= 1'b0;
        MemRead_out <= 1'b0;
        MemWrite_out <= 1'b0;
        MemToReg_out <= 1'b0;

        Branch_out <= 1'b0;
        Jump_out <= 1'b0;
        JumpReg_out <= 1'b0;

        ALUSrc_out <= 1'b0;
        ALUOp_out <= 2'b00;
      
        isLUI_out <= 1'b0;      // NEW
        isAUIPC_out <= 1'b0;    // NEW

    end

    else if (!hold) begin

        pc_out <= pc_in;

        read_data1_out <= read_data1_in;
        read_data2_out <= read_data2_in;

        immediate_out <= immediate_in;

        rs1_out <= rs1_in;
        rs2_out <= rs2_in;
        rd_out <= rd_in;

        funct3_out <= funct3_in;
        funct7_out <= funct7_in;

        RegWrite_out <= RegWrite_in;
        MemRead_out <= MemRead_in;
        MemWrite_out <= MemWrite_in;
        MemToReg_out <= MemToReg_in;

        Branch_out <= Branch_in;
        Jump_out <= Jump_in;
        JumpReg_out <= JumpReg_in;

        ALUSrc_out <= ALUSrc_in;
        ALUOp_out <= ALUOp_in;
      
        isLUI_out <= isLUI_in;      // NEW
        isAUIPC_out <= isAUIPC_in;  // NEW

    end

end

endmodule

//........................................................................................
module ex_mem_reg(

    input clk,
    input hold,              // thêm mới: 1 = giữ nguyên (đóng băng khi chờ bus)
    input rst,

    //--------------------------------------------------
    // Data Inputs
    //--------------------------------------------------

    input [31:0] alu_result_in,
    input [31:0] write_data_in,

    input [4:0] rd_in,

    //--------------------------------------------------
    // Control Inputs
    //--------------------------------------------------

    input RegWrite_in,
    input MemRead_in,
    input MemWrite_in,
    input MemToReg_in,
    input Jump_in,
    input JumpReg_in,

  input [31:0] pc_plus_4_in,

    //--------------------------------------------------
    // Data Outputs
    //--------------------------------------------------

    output reg [31:0] alu_result_out,
    output reg [31:0] write_data_out,

    output reg [4:0] rd_out,

    //--------------------------------------------------
    // Control Outputs
    //--------------------------------------------------

    output reg RegWrite_out,
    output reg MemRead_out,
    output reg MemWrite_out,
    output reg MemToReg_out,
    output reg Jump_out,
    output reg JumpReg_out,

    output reg [31:0] pc_plus_4_out

);

always @(posedge clk or posedge rst) begin

    if (rst) begin

        alu_result_out <= 32'd0;
        write_data_out <= 32'd0;

        rd_out <= 5'd0;

        RegWrite_out <= 1'b0;
        MemRead_out  <= 1'b0;
        MemWrite_out <= 1'b0;
        MemToReg_out <= 1'b0;

        Jump_out      <= 1'b0;
        JumpReg_out   <= 1'b0;

        pc_plus_4_out <= 32'd0;

    end

    else if (!hold) begin

        alu_result_out <= alu_result_in;
        write_data_out <= write_data_in;

        rd_out <= rd_in;

        RegWrite_out <= RegWrite_in;
        MemRead_out  <= MemRead_in;
        MemWrite_out <= MemWrite_in;
        MemToReg_out <= MemToReg_in;

        Jump_out      <= Jump_in;
        JumpReg_out   <= JumpReg_in;

        pc_plus_4_out <= pc_plus_4_in;

    end

end

endmodule

//....................................................................................

module mem_wb_reg(

    input clk,
    input hold,              // thêm mới: 1 = giữ nguyên (đóng băng khi chờ bus)
    input rst,

    //--------------------------------------------------
    // Data Inputs
    //--------------------------------------------------

    input [31:0] mem_data_in,
    input [31:0] alu_result_in,

    input [4:0] rd_in,

    //--------------------------------------------------
    // Control Inputs
    //--------------------------------------------------

    input MemToReg_in,
    input RegWrite_in,
    input Jump_in,
    input JumpReg_in,

    input [31:0] pc_plus_4_in,

    //--------------------------------------------------
    // Data Outputs
    //--------------------------------------------------

    output reg [31:0] mem_data_out,
    output reg [31:0] alu_result_out,

    output reg [4:0] rd_out,

    //--------------------------------------------------
    // Control Outputs
    //--------------------------------------------------

    output reg MemToReg_out,
    output reg RegWrite_out,
    output reg Jump_out,
    output reg JumpReg_out,

    output reg [31:0] pc_plus_4_out

);

always @(posedge clk or posedge rst) begin

    if (rst) begin

        mem_data_out   <= 32'd0;
        alu_result_out <= 32'd0;

        rd_out <= 5'd0;

        MemToReg_out <= 1'b0;
        RegWrite_out <= 1'b0;

        Jump_out      <= 1'b0;
        JumpReg_out   <= 1'b0;

        pc_plus_4_out <= 32'd0;

    end

    else if (!hold) begin

        mem_data_out   <= mem_data_in;
        alu_result_out <= alu_result_in;

        rd_out <= rd_in;

        MemToReg_out <= MemToReg_in;
        RegWrite_out <= RegWrite_in;

        Jump_out      <= Jump_in;
        JumpReg_out   <= JumpReg_in;

        pc_plus_4_out <= pc_plus_4_in;

    end

end

endmodule


//..........................................................................


module forwarding_unit(

    input [4:0] id_ex_rs1,
    input [4:0] id_ex_rs2,

    input [4:0] ex_mem_rd,
    input [4:0] mem_wb_rd,

    input ex_mem_RegWrite,
    input mem_wb_RegWrite,

    output reg [1:0] ForwardA,
    output reg [1:0] ForwardB

);

always @(*) begin

    //--------------------------------------------------
    // Default
    //--------------------------------------------------

    ForwardA = 2'b00;
    ForwardB = 2'b00;

    //--------------------------------------------------
    // EX Hazard
    //--------------------------------------------------

    if (ex_mem_RegWrite &&
        (ex_mem_rd != 0) &&
        (ex_mem_rd == id_ex_rs1))

        ForwardA = 2'b10;

    if (ex_mem_RegWrite &&
        (ex_mem_rd != 0) &&
        (ex_mem_rd == id_ex_rs2))

        ForwardB = 2'b10;

    //--------------------------------------------------
    // MEM Hazard
    //--------------------------------------------------

    if (mem_wb_RegWrite &&
        (mem_wb_rd != 0) &&
        !(ex_mem_RegWrite &&
          (ex_mem_rd != 0) &&
          (ex_mem_rd == id_ex_rs1)) &&
        (mem_wb_rd == id_ex_rs1))

        ForwardA = 2'b01;

    if (mem_wb_RegWrite &&
        (mem_wb_rd != 0) &&
        !(ex_mem_RegWrite &&
          (ex_mem_rd != 0) &&
          (ex_mem_rd == id_ex_rs2)) &&
        (mem_wb_rd == id_ex_rs2))

        ForwardB = 2'b01;

end

endmodule

//.............................................................................................

module hazard_detection_unit(

    input        id_ex_MemRead,

    input  [4:0] id_ex_rd,

    input  [4:0] if_id_rs1,
    input  [4:0] if_id_rs2,

    output reg   PCWrite,
    output reg   IF_ID_Write,
    output reg   ControlMuxSelect

);

always @(*) begin

    //-----------------------------------------
    // Default: normal execution
    //-----------------------------------------

    PCWrite         = 1'b1;
    IF_ID_Write     = 1'b1;
    ControlMuxSelect = 1'b0;

    //-----------------------------------------
    // Load-use hazard
    //-----------------------------------------

    if ( id_ex_MemRead &&
        (id_ex_rd != 5'd0) &&
        ((id_ex_rd == if_id_rs1) ||
         (id_ex_rd == if_id_rs2)) ) begin

        PCWrite          = 1'b0;
        IF_ID_Write      = 1'b0;
        ControlMuxSelect = 1'b1;

    end

end

endmodule

//..........................................................................

module flush_unit(

    input  branch_taken,
    input  jump,
    input  jump_reg,

    output flush_if_id,
    output flush_id_ex

);

assign flush_if_id =

       branch_taken ||

       jump ||

       jump_reg;

assign flush_id_ex =

       branch_taken ||

       jump ||

       jump_reg;

endmodule