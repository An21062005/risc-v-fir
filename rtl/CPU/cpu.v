//------------------------------------------------------------------
// Bản sao từ tiny-riscv-soc (MIT). Thay đổi trong riscv-soc-fir-hls:
//   rvcore32_pipeline_top: nối .hold(1'b0) cho 4 thanh ghi pipeline
//   (cổng hold mới trong Pipeline_Registers.v), hành vi không đổi.
//   Lõi dùng trong SoC là rvcore32_pipeline_soc (rtl/cpu_soc.v), tái sử
//   dụng các submodule trong file này.
//------------------------------------------------------------------
//--------------------------------------------------------------------------
//             PhoenixRV-32
//--------------------------------------------------------------------------
`timescale 1ns/1ps

//------------------------------------------------------------
// program counter
//------------------------------------------------------------

module program_counter(

    input clk,
    input rst,

    input enable,

    input [31:0] next_pc,

    output reg [31:0] pc

);

always @(posedge clk or posedge rst)
begin

    if (rst)

        pc <= 32'd0;

    else if (enable)

        pc <= next_pc;

end

endmodule

//------------------------------------------------------------
// Instruction Memory
//------------------------------------------------------------

module instruction_memory(

    input  [31:0] address,
    output [31:0] instruction

);

reg [31:0] memory [0:255];

integer i;

initial begin

    for (i = 0; i < 256; i = i + 1)
        memory[i] = 32'h00000013;   // NOP

    $readmemh("program.mem", memory);

end

assign instruction = memory[address[9:2]];


endmodule

//................................................
//      Data_memory
//................................................

module data_memory(

    input wire clk,

    input wire mem_read,
    input wire mem_write,

    input wire [31:0] address,

    input wire [31:0] write_data,

    output wire [31:0] read_data

);

    //------------------------------------------------
    // Data Memory
    //------------------------------------------------

    reg [31:0] memory [0:255];

    integer i;

    //------------------------------------------------
    // Initialize Memory
    //------------------------------------------------

    initial begin

        for (i = 0; i < 256; i = i + 1)
            memory[i] = 32'd0;

        $readmemh("data.mem", memory);


    end

    //------------------------------------------------
    // Write Operation
    //------------------------------------------------

    always @(posedge clk) begin

        if (mem_write) begin

            memory[address[9:2]] <= write_data;


        end

    end

    //------------------------------------------------
    // Read Operation
    //------------------------------------------------

    assign read_data = (mem_read)
                     ? memory[address[9:2]]
                     : 32'd0;

endmodule

//------------------------------------------------------------
// decoder
//------------------------------------------------------------

module decoder(

    input  [31:0] instruction,

    output [6:0] opcode,
    output [4:0] rd,
    output [2:0] funct3,
    output [4:0] rs1,
    output [4:0] rs2,
    output [6:0] funct7

);

assign opcode = instruction[6:0];
assign rd      = instruction[11:7];
assign funct3  = instruction[14:12];
assign rs1     = instruction[19:15];
assign rs2     = instruction[24:20];
assign funct7  = instruction[31:25];

endmodule

//------------------------------------------------------------
// register file
//------------------------------------------------------------

module register_file(

    input              clk,
    input              write_enable,

    input      [4:0]   rs1,
    input      [4:0]   rs2,
    input      [4:0]   rd,

    input      [31:0]  write_data,

    output     [31:0]  read_data1,
    output     [31:0]  read_data2

);

reg [31:0] registers [0:31];

integer i;

//--------------------------------------------------
// Register Initialization
//--------------------------------------------------

initial begin

    for (i = 0; i < 32; i = i + 1)
        registers[i] = 32'd0;

end

//--------------------------------------------------
// Read Ports
//--------------------------------------------------

assign read_data1 = (rs1 == 5'd0) ? 32'd0 :
                     (write_enable && (rd == rs1)) ? write_data :
                     registers[rs1];

assign read_data2 = (rs2 == 5'd0) ? 32'd0 :
                     (write_enable && (rd == rs2)) ? write_data :
                     registers[rs2];

//--------------------------------------------------
// Write Port
//--------------------------------------------------

always @(posedge clk) begin

    if (write_enable && (rd != 5'd0)) begin

        registers[rd] <= write_data;


    end

    registers[0] <= 32'd0;

end
  

endmodule

//------------------------------------------------------------
// control unit
//------------------------------------------------------------
module control_unit(

    input [6:0] opcode,

    output reg RegWrite,
    output reg MemRead,
    output reg MemWrite,
    output reg Branch,

    output reg Jump,
    output reg JumpReg,

    output reg ALUSrc,
    output reg MemToReg,

    output reg [1:0] ALUOp

);

always @(*) begin

    //--------------------------------------------------
    // Default values
    //--------------------------------------------------

    RegWrite = 0;
    MemRead  = 0;
    MemWrite = 0;
    Branch   = 0;

    Jump     = 0;
    JumpReg  = 0;

    ALUSrc   = 0;
    MemToReg = 0;

    ALUOp    = 2'b00;

    case (opcode)

        //--------------------------------------------------
        // R-Type
        //--------------------------------------------------

        7'b0110011: begin

            RegWrite = 1;
            ALUSrc   = 0;
            ALUOp    = 2'b10;

        end

        //--------------------------------------------------
        // I-Type
        //--------------------------------------------------

        7'b0010011: begin

            RegWrite = 1;
            ALUSrc   = 1;
            ALUOp    = 2'b11;

        end

        //--------------------------------------------------
        // LUI
        //--------------------------------------------------

        7'b0110111: begin

            RegWrite = 1;
            ALUSrc   = 1;
            ALUOp    = 2'b00;

        end

        //--------------------------------------------------
        // AUIPC
        //--------------------------------------------------

        7'b0010111: begin

            RegWrite = 1;
            ALUSrc   = 1;
            ALUOp    = 2'b00;

        end

        //--------------------------------------------------
        // LW
        //--------------------------------------------------

        7'b0000011: begin

            RegWrite = 1;
            MemRead  = 1;
            ALUSrc   = 1;
            MemToReg = 1;
            ALUOp    = 2'b00;

        end

        //--------------------------------------------------
        // SW
        //--------------------------------------------------

        7'b0100011: begin

            MemWrite = 1;
            ALUSrc   = 1;
            ALUOp    = 2'b00;

        end

        //--------------------------------------------------
        // Branch
        //--------------------------------------------------

        7'b1100011: begin

            Branch   = 1;
            ALUSrc   = 0;
            ALUOp    = 2'b01;

        end

        //--------------------------------------------------
        // JAL
        //--------------------------------------------------

        7'b1101111: begin

            RegWrite = 1;
            Jump     = 1;

        end

        //--------------------------------------------------
        // JALR
        //--------------------------------------------------

        7'b1100111: begin

            RegWrite = 1;
            JumpReg  = 1;
            ALUSrc   = 1;

        end

    endcase

end

endmodule


//------------------------------------------------------------
// imidiate generator
//------------------------------------------------------------
module immediate_generator(

    input  [31:0] instruction,
    output reg [31:0] immediate

);

wire [6:0] opcode;

assign opcode = instruction[6:0];

always @(*) begin

    case (opcode)

        //--------------------------------------------------
        // I-Type (ADDI, LW, JALR)
        //--------------------------------------------------

        7'b0010011,
        7'b0000011,
        7'b1100111:

            immediate = {

                {20{instruction[31]}},
                instruction[31:20]

            };

        //--------------------------------------------------
        // S-Type (SW)
        //--------------------------------------------------

        7'b0100011:

            immediate = {

                {20{instruction[31]}},
                instruction[31:25],
                instruction[11:7]

            };

        //--------------------------------------------------
        // B-Type (BEQ, BNE, BLT, BGE)
        //--------------------------------------------------

        7'b1100011:

            immediate = {

                {19{instruction[31]}},
                instruction[31],
                instruction[7],
                instruction[30:25],
                instruction[11:8],
                1'b0

            };

        //--------------------------------------------------
        // U-Type (LUI, AUIPC)
        //--------------------------------------------------

        7'b0110111,
        7'b0010111:

            immediate = {

                instruction[31:12],
                12'b0

            };

        //--------------------------------------------------
        // J-Type (JAL)
        //--------------------------------------------------

        7'b1101111:

            immediate = {

                {11{instruction[31]}},
                instruction[31],
                instruction[19:12],
                instruction[20],
                instruction[30:21],
                1'b0

            };

        //--------------------------------------------------
        // Default
        //--------------------------------------------------

        default:

            immediate = 32'd0;

    endcase

end

endmodule


//------------------------------------------------------------
// alu
//------------------------------------------------------------
module alu(

    input [31:0] A,
    input [31:0] B,

    input [3:0] ALU_Control,

    output reg [31:0] Result,
    output Zero

);

always @(*) begin

    case (ALU_Control)

        // AND

        4'b0000:
            Result = A & B;

        // OR

        4'b0001:
            Result = A | B;

        // ADD

        4'b0010:
            Result = A + B;

        // SUB

        4'b0110:
            Result = A - B;

        // SLT

        4'b0111:
            Result = ($signed(A) < $signed(B))
                     ? 32'd1
                     : 32'd0;

        // XOR

        4'b1100:
            Result = A ^ B;

        // SLL

        4'b1000:
            Result = A << B[4:0];

        // SRL

        4'b1001:
            Result = A >> B[4:0];

        // SRA

        4'b1010:
            Result = $signed(A) >>> B[4:0];

        default:
            Result = 32'd0;

    endcase

end

assign Zero = (Result == 32'd0);

endmodule

//------------------------------------------------------------
// alu_control
//------------------------------------------------------------
module alu_control(

    input [1:0] ALUOp,
    input [2:0] funct3,
    input [6:0] funct7,

    output reg [3:0] ALU_Control

);

always @(*) begin

    case (ALUOp)

        //--------------------------------------------------
        // LW / SW
        //--------------------------------------------------

        2'b00:

            ALU_Control = 4'b0010;
//--------------------------------------------------
// Branch Instructions
//--------------------------------------------------

2'b01: begin

    case (funct3)

        // BEQ

        3'b000:
            ALU_Control = 4'b0110;

        // BNE

        3'b001:
            ALU_Control = 4'b0110;

        // BLT

        3'b100:
            ALU_Control = 4'b0111;

        // BGE

        3'b101:
            ALU_Control = 4'b0111;

        default:
            ALU_Control = 4'b0110;

    endcase

end
        //--------------------------------------------------
        // R-Type
        //--------------------------------------------------

        2'b10: begin

            case ({funct7, funct3})

                {7'b0000000, 3'b000}:
                    ALU_Control = 4'b0010; // ADD

                {7'b0100000, 3'b000}:
                    ALU_Control = 4'b0110; // SUB

                {7'b0000000, 3'b111}:
                    ALU_Control = 4'b0000; // AND

                {7'b0000000, 3'b110}:
                    ALU_Control = 4'b0001; // OR

                {7'b0000000, 3'b100}:
                    ALU_Control = 4'b1100; // XOR

                {7'b0000000, 3'b010}:
                    ALU_Control = 4'b0111; // SLT

                {7'b0000000, 3'b001}:
                    ALU_Control = 4'b1000; // SLL

                {7'b0000000, 3'b101}:
                    ALU_Control = 4'b1001; // SRL

                {7'b0100000, 3'b101}:
                    ALU_Control = 4'b1010; // SRA

                default:
                    ALU_Control = 4'b0000;

            endcase

        end

        //--------------------------------------------------
        // I-Type
        //--------------------------------------------------

        2'b11: begin

            case (funct3)

                3'b000:
                    ALU_Control = 4'b0010; // ADDI

                3'b111:
                    ALU_Control = 4'b0000; // ANDI

                3'b110:
                    ALU_Control = 4'b0001; // ORI

                3'b100:
                    ALU_Control = 4'b1100; // XORI

                3'b010:
                    ALU_Control = 4'b0111; // SLTI
              
                3'b001: ALU_Control = 4'b1000; // SLLI
              
                3'b101: ALU_Control = (funct7 == 7'b0100000) ? 4'b1010      
                                                             : 4'b1001;     

                default:
                    ALU_Control = 4'b0010;

            endcase

        end

        default:

            ALU_Control = 4'b0000;

    endcase

end

endmodule


//------------------------------------------------------------
// wb_stage
//------------------------------------------------------------
module wb_stage(

    input  [31:0] ALU_Result,
    input  [31:0] MemoryData,

    input  [31:0] pc_plus_4,

    input         MemToReg,
    input         Jump,
    input         JumpReg,

    output [31:0] WriteBackData

);

assign WriteBackData =

       (Jump || JumpReg) ? pc_plus_4 :

       (MemToReg) ? MemoryData :

                    ALU_Result;

endmodule



//...........................(main)......................................

module rvcore32_top(

    input wire clk,
    input wire rst,

    output wire [31:0] pc,
    input wire [31:0] instruction,

    output wire mem_read,
    output wire mem_write,

    output wire [31:0] mem_addr,
    output wire [31:0] mem_wdata,

    input wire [31:0] mem_rdata,

    input wire mem_ready

);

//------------------------------------------------------------
// Decoder Outputs
//------------------------------------------------------------

wire [6:0] opcode;
wire [4:0] rd;
wire [2:0] funct3;
wire [4:0] rs1;
wire [4:0] rs2;
wire [6:0] funct7;


//------------------------------------------------------------
// Register File
//------------------------------------------------------------

wire [31:0] read_data1;
wire [31:0] read_data2;


//------------------------------------------------------------
// Immediate
//------------------------------------------------------------

wire [31:0] immediate;


//------------------------------------------------------------
// Control Signals
//------------------------------------------------------------

wire        RegWrite;
wire        MemRead;
wire        MemWrite;

wire        Branch;
wire        Jump;
wire        JumpReg;

wire        ALUSrc;
wire        MemToReg;

wire [1:0] ALUOp;


//------------------------------------------------------------
// Branch / Jump Signals
//------------------------------------------------------------

wire        branch_condition;
wire        branch_taken;

wire [31:0] branch_target;
wire [31:0] jump_target;
wire [31:0] jalr_target;

wire [31:0] next_pc;
wire [31:0] pc_plus_4;

wire        debug_zero;


//------------------------------------------------------------
// LUI / AUIPC
//------------------------------------------------------------

wire        is_lui;
wire        is_auipc;

wire [31:0] wb_alu_result;


//------------------------------------------------------------
// EX Stage
//------------------------------------------------------------

wire [3:0]  ALU_Control;
wire [31:0] ALU_Result;
wire [31:0] OperandB;
wire        Zero;


//------------------------------------------------------------
// WB Stage
//------------------------------------------------------------

wire [31:0] WriteBackData;


//------------------------------------------------------------
// Program Counter
//------------------------------------------------------------

wire cpu_enable;

assign cpu_enable =

    !(MemRead || MemWrite) ||

    mem_ready;
   

program_counter PC(

    .clk(clk),
    .rst(rst),

    .enable(cpu_enable),

    .next_pc(next_pc),

    .pc(pc)

);
  
//------------------------------------------------------------
// Decoder
//------------------------------------------------------------

decoder DEC(

    .instruction(instruction),

    .opcode(opcode),
    .rd(rd),
    .funct3(funct3),
    .rs1(rs1),
    .rs2(rs2),
    .funct7(funct7)

);


//------------------------------------------------------------
// Register File
//------------------------------------------------------------

register_file RF(

    .clk(clk),

    .write_enable(RegWrite),

    .rs1(rs1),
    .rs2(rs2),
    .rd(rd),

    .write_data(WriteBackData),

    .read_data1(read_data1),
    .read_data2(read_data2)

);


//------------------------------------------------------------
// Control Unit
//------------------------------------------------------------

control_unit CU(

    .opcode(opcode),

    .RegWrite(RegWrite),
    .MemRead(MemRead),
    .MemWrite(MemWrite),

    .Branch(Branch),

    .Jump(Jump),
    .JumpReg(JumpReg),

    .ALUSrc(ALUSrc),
    .MemToReg(MemToReg),

    .ALUOp(ALUOp)

);


//------------------------------------------------------------
// Immediate Generator
//------------------------------------------------------------

immediate_generator IG(

    .instruction(instruction),

    .immediate(immediate)

);


//------------------------------------------------------------
// ALU Operand MUX
//------------------------------------------------------------

assign OperandB = ALUSrc ? immediate : read_data2;


//------------------------------------------------------------
// Branch / Jump Logic
//------------------------------------------------------------

assign debug_zero = Zero;

assign pc_plus_4 = pc + 32'd4;

assign branch_target = pc + immediate;

assign jump_target = pc + immediate;

assign jalr_target = (read_data1 + immediate) & ~32'd1;


//------------------------------------------------------------
// LUI / AUIPC Decode
//------------------------------------------------------------

assign is_lui   = (opcode == 7'b0110111);

assign is_auipc = (opcode == 7'b0010111);


//------------------------------------------------------------
// Branch Logic
//------------------------------------------------------------

assign branch_condition =

       (funct3 == 3'b000) ? Zero :

       (funct3 == 3'b001) ? ~Zero :

       (funct3 == 3'b100) ? (ALU_Result == 32'd1) :

       (funct3 == 3'b101) ? (ALU_Result == 32'd0) :

       1'b0;

assign branch_taken = Branch && branch_condition;


//------------------------------------------------------------
// Next PC
//------------------------------------------------------------

assign next_pc =

       JumpReg      ? jalr_target :

       Jump         ? jump_target :

       branch_taken ? branch_target :

                      pc_plus_4;
 


//------------------------------------------------------------
// Memory Interface
//------------------------------------------------------------

assign mem_read  = MemRead;

assign mem_write = MemWrite;

assign mem_addr  = ALU_Result;

assign mem_wdata = read_data2;


//------------------------------------------------------------
// Write-back ALU Override
//------------------------------------------------------------

assign wb_alu_result =

       is_lui   ? immediate :

       is_auipc ? (pc + immediate) :

                  ALU_Result;


//------------------------------------------------------------
// ALU Control
//------------------------------------------------------------

alu_control AC(

    .ALUOp(ALUOp),
    .funct3(funct3),
    .funct7(funct7),

    .ALU_Control(ALU_Control)

);


//------------------------------------------------------------
// ALU
//------------------------------------------------------------

alu ALU(

    .A(read_data1),
    .B(OperandB),

    .ALU_Control(ALU_Control),

    .Result(ALU_Result),
    .Zero(Zero)

);


//------------------------------------------------------------
// Write Back
//------------------------------------------------------------

wb_stage WB(

    .ALU_Result(wb_alu_result),

    .MemoryData(mem_rdata),

    .pc_plus_4(pc_plus_4),

    .MemToReg(MemToReg),

    .Jump(Jump),
    .JumpReg(JumpReg),

    .WriteBackData(WriteBackData)

);

endmodule


//......................................................................................................

module rvcore32_pipeline_top(

    input wire clk,
    input wire rst
);


//============================================================
// IF STAGE
//============================================================

wire [31:0] pc;
wire [31:0] next_pc;
wire [31:0] instruction;


//============================================================
// IF / ID REGISTER
//============================================================

wire [31:0] if_id_pc;
wire [31:0] if_id_instruction;


//============================================================
// ID STAGE
//============================================================

wire [6:0] opcode;
wire [4:0] rd;
wire [2:0] funct3;
wire [4:0] rs1;
wire [4:0] rs2;
wire [6:0] funct7;

wire [31:0] read_data1;
wire [31:0] read_data2;
wire [31:0] immediate;
  
  


//============================================================
// CONTROL SIGNALS
//============================================================

wire RegWrite;
wire MemRead;
wire MemWrite;

wire Branch;
wire Jump;
wire JumpReg;

wire ALUSrc;
wire MemToReg;

wire [1:0] ALUOp;
wire is_lui;              // NEW
wire is_auipc;             // NEW    
  
wire stall_RegWrite;
wire stall_MemRead;
wire stall_MemWrite;
wire stall_Branch;

wire stall_Jump;
wire stall_JumpReg;

wire stall_ALUSrc;
wire stall_MemToReg;

wire [1:0] stall_ALUOp; 
wire stall_isLUI;          // NEW
wire stall_isAUIPC;        // NEW  



//============================================================
// ID / EX REGISTER
//============================================================

wire [31:0] id_ex_pc;

wire [31:0] id_ex_read_data1;
wire [31:0] id_ex_read_data2;

wire [31:0] id_ex_immediate;

wire [4:0] id_ex_rs1;
wire [4:0] id_ex_rs2;
wire [4:0] id_ex_rd;

wire [2:0] id_ex_funct3;
wire [6:0] id_ex_funct7;

wire id_ex_RegWrite;
wire id_ex_MemRead;
wire id_ex_MemWrite;
wire id_ex_MemToReg;

wire id_ex_Branch;
wire id_ex_Jump;
wire id_ex_JumpReg;

wire id_ex_ALUSrc;

wire [1:0] id_ex_ALUOp;
wire id_ex_isLUI;          // NEW
wire id_ex_isAUIPC;        // NEW  


//============================================================
// EX STAGE
//============================================================

wire [31:0] ex_operand_b;
wire [31:0] ex_alu_A;      // NEW  

wire [3:0] ex_alu_control;

wire [31:0] ex_alu_result;

wire ex_zero;

wire ex_branch_condition;
wire ex_branch_taken;

wire [31:0] ex_branch_target;
wire [31:0] ex_jump_target;
wire [31:0] ex_jalr_target;
  
//------------------------------------------------------------
// EX / MEM Stage
//------------------------------------------------------------

wire [31:0] ex_mem_alu_result;
wire [31:0] ex_mem_write_data;

wire [4:0] ex_mem_rd;

wire ex_mem_RegWrite;
wire ex_mem_MemRead;
wire ex_mem_MemWrite;
wire ex_mem_MemToReg;  
  
//------------------------------------------------------------
// MEM / WB Stage
//------------------------------------------------------------

wire [31:0] mem_wb_mem_data;
wire [31:0] mem_wb_alu_result;

wire [4:0] mem_wb_rd;

wire        mem_wb_MemToReg;
wire        mem_wb_RegWrite;  
wire [31:0] WriteBackData;
  
wire ex_mem_Jump;
wire ex_mem_JumpReg;

wire mem_wb_Jump;
wire mem_wb_JumpReg;

wire [31:0] ex_mem_pc_plus_4;
wire [31:0] mem_wb_pc_plus_4;  
//--------------------------------------------------
// Forwarding
//--------------------------------------------------

wire [1:0] ForwardA;
wire [1:0] ForwardB;

wire [31:0] forwarded_A;
wire [31:0] forwarded_B;  
  
wire PCWrite;
wire IF_ID_Write;
wire ControlMuxSelect;  
  
wire flush_if_id;
wire flush_id_ex;  
  
  
//------------------------------------------------
// Data Memory Interface
//------------------------------------------------

wire mem_read;
wire mem_write;

wire [31:0] mem_addr;
wire [31:0] mem_wdata;
wire [31:0] mem_rdata;
  

//============================================================
// TEMPORARY PC LOGIC
//============================================================

assign next_pc =

       id_ex_JumpReg ? ex_jalr_target :

       id_ex_Jump ? ex_jump_target :

       ex_branch_taken ? ex_branch_target :

       pc + 32'd4;


//============================================================
// PROGRAM COUNTER
//============================================================

program_counter PC (

    .clk(clk),
    .rst(rst),

    .enable(PCWrite),

    .next_pc(next_pc),

    .pc(pc)

);


//============================================================
// INSTRUCTION MEMORY
//============================================================
  
instruction_memory IMEM (

    .address(pc),

    .instruction(instruction)

);

//============================================================
// IF / ID REGISTER
//============================================================

if_id_reg IF_ID (

    .clk(clk),
    .rst(rst),
    .hold(1'b0),   // riscv-soc-fir-hls: giữ hành vi gốc

    .write_enable(IF_ID_Write),

    .flush(flush_if_id),

    .pc_in(pc),
    .instr_in(instruction),

    .pc_out(if_id_pc),
    .instr_out(if_id_instruction)

);


//============================================================
// DECODER
//============================================================

decoder DEC (

    .instruction(if_id_instruction),

    .opcode(opcode),
    .rd(rd),
    .funct3(funct3),
    .rs1(rs1),
    .rs2(rs2),
    .funct7(funct7)

);


//------------------------------------------------------------
// Register File
//------------------------------------------------------------

register_file RF (

    .clk(clk),

    .rs1(rs1),
    .rs2(rs2),

    .rd(mem_wb_rd),

    .write_data(WriteBackData),

    .write_enable(mem_wb_RegWrite),

    .read_data1(read_data1),
    .read_data2(read_data2)

);

 

//============================================================
// CONTROL UNIT
//============================================================

control_unit CU (

    .opcode(opcode),

    .RegWrite(RegWrite),
    .MemRead(MemRead),
    .MemWrite(MemWrite),

    .Branch(Branch),

    .Jump(Jump),
    .JumpReg(JumpReg),

    .ALUSrc(ALUSrc),
    .MemToReg(MemToReg),

    .ALUOp(ALUOp)

);


//============================================================
// IMMEDIATE GENERATOR
//============================================================

immediate_generator IG (

    .instruction(if_id_instruction),

    .immediate(immediate)

);

assign stall_RegWrite = (ControlMuxSelect) ? 1'b0 : RegWrite;

assign stall_MemRead  = (ControlMuxSelect) ? 1'b0 : MemRead;

assign stall_MemWrite = (ControlMuxSelect) ? 1'b0 : MemWrite;

assign stall_Branch   = (ControlMuxSelect) ? 1'b0 : Branch;

assign stall_Jump     = (ControlMuxSelect) ? 1'b0 : Jump;

assign stall_JumpReg  = (ControlMuxSelect) ? 1'b0 : JumpReg;

assign stall_ALUSrc   = (ControlMuxSelect) ? 1'b0 : ALUSrc;

assign stall_MemToReg = (ControlMuxSelect) ? 1'b0 : MemToReg;

assign is_lui   = (opcode == 7'b0110111);   // NEW
assign is_auipc = (opcode == 7'b0010111);   // NEW
  

assign stall_ALUOp    = (ControlMuxSelect) ? 2'b00 : ALUOp;
assign stall_isLUI    = (ControlMuxSelect) ? 1'b0 : is_lui;     // NEW
assign stall_isAUIPC  = (ControlMuxSelect) ? 1'b0 : is_auipc;   // NEW  

//============================================================
// ID / EX REGISTER
//============================================================  
  
  
id_ex_reg ID_EX (

    .clk(clk),
    .rst(rst),
    .hold(1'b0),   // riscv-soc-fir-hls: giữ hành vi gốc
  
    .flush(flush_id_ex),

    .pc_in(if_id_pc),

    .read_data1_in(read_data1),
    .read_data2_in(read_data2),

    .immediate_in(immediate),

    .rs1_in(rs1),
    .rs2_in(rs2),
    .rd_in(rd),

    .funct3_in(funct3),
    .funct7_in(funct7),

    .RegWrite_in(stall_RegWrite),
    .MemRead_in(stall_MemRead),
    .MemWrite_in(stall_MemWrite),

    .Branch_in(stall_Branch),

    .Jump_in(stall_Jump),
    .JumpReg_in(stall_JumpReg),

    .ALUSrc_in(stall_ALUSrc),
    .MemToReg_in(stall_MemToReg),

    .ALUOp_in(stall_ALUOp),
  
    .isLUI_in(stall_isLUI),
    .isAUIPC_in(stall_isAUIPC),

    .pc_out(id_ex_pc),

    .read_data1_out(id_ex_read_data1),
    .read_data2_out(id_ex_read_data2),

    .immediate_out(id_ex_immediate),

    .rs1_out(id_ex_rs1),
    .rs2_out(id_ex_rs2),
    .rd_out(id_ex_rd),

    .funct3_out(id_ex_funct3),
    .funct7_out(id_ex_funct7),

    .RegWrite_out(id_ex_RegWrite),
    .MemRead_out(id_ex_MemRead),
    .MemWrite_out(id_ex_MemWrite),
    .MemToReg_out(id_ex_MemToReg),

    .Branch_out(id_ex_Branch),
    .Jump_out(id_ex_Jump),
    .JumpReg_out(id_ex_JumpReg),

    .ALUSrc_out(id_ex_ALUSrc),

    .ALUOp_out(id_ex_ALUOp),
  
    .isLUI_out(id_ex_isLUI), 
    .isAUIPC_out(id_ex_isAUIPC)
  

);


//============================================================
// ALU OPERAND MUX
//============================================================

assign forwarded_A =

       (ForwardA == 2'b00) ? id_ex_read_data1 :

       (ForwardA == 2'b10) ? ex_mem_alu_result :

                             WriteBackData;


assign forwarded_B =

       (ForwardB == 2'b00) ? id_ex_read_data2 :

       (ForwardB == 2'b10) ? ex_mem_alu_result :

                             WriteBackData;


assign ex_operand_b =

       (id_ex_ALUSrc)

       ? id_ex_immediate

       : forwarded_B;
  
assign ex_alu_A =
       id_ex_isLUI   ? 32'd0    :
       id_ex_isAUIPC ? id_ex_pc :
                        forwarded_A;

//============================================================
// ALU CONTROL
//============================================================

alu_control AC (

    .ALUOp(id_ex_ALUOp),

    .funct3(id_ex_funct3),

    .funct7(id_ex_funct7),

    .ALU_Control(ex_alu_control)

);


//============================================================
// ALU
//============================================================

alu ALU (
    .A(ex_alu_A), .B(ex_operand_b), .ALU_Control(ex_alu_control), .Result(ex_alu_result), .Zero(ex_zero)
);

//============================================================
// BRANCH / JUMP LOGIC
//============================================================

assign ex_branch_target =

       id_ex_pc + id_ex_immediate;

assign ex_jump_target =

       id_ex_pc + id_ex_immediate;

assign ex_jalr_target = (forwarded_A + id_ex_immediate) & ~32'd1;


assign ex_branch_condition =

       // BEQ

       (id_ex_funct3 == 3'b000)

       ? ex_zero

       :

       // BNE

       (id_ex_funct3 == 3'b001)

       ? ~ex_zero

       :

       // BLT

       (id_ex_funct3 == 3'b100)

       ? (ex_alu_result == 32'd1)

       :

       // BGE

       (id_ex_funct3 == 3'b101)

       ? (ex_alu_result == 32'd0)

       :

       1'b0;


assign ex_branch_taken =

       id_ex_Branch

       &&

       ex_branch_condition;
  
  
  
//------------------------------------------------------------
// EX / MEM Register
//------------------------------------------------------------

ex_mem_reg EX_MEM (

    .clk(clk),
    .rst(rst),
    .hold(1'b0),   // riscv-soc-fir-hls: giữ hành vi gốc

    //--------------------------------------------------
    // Data Inputs
    //--------------------------------------------------

    .alu_result_in(ex_alu_result),

    .write_data_in(forwarded_B),

    .rd_in(id_ex_rd),

    //--------------------------------------------------
    // Control Inputs
    //--------------------------------------------------

    .RegWrite_in(id_ex_RegWrite),

    .MemRead_in(id_ex_MemRead),

    .MemWrite_in(id_ex_MemWrite),

    .MemToReg_in(id_ex_MemToReg),

    //--------------------------------------------------
    // Outputs
    //--------------------------------------------------

    .alu_result_out(ex_mem_alu_result),

    .write_data_out(ex_mem_write_data),

    .rd_out(ex_mem_rd),

    .RegWrite_out(ex_mem_RegWrite),

    .MemRead_out(ex_mem_MemRead),

    .MemWrite_out(ex_mem_MemWrite),

  .MemToReg_out(ex_mem_MemToReg),
  
   .pc_plus_4_in(id_ex_pc + 32'd4),

.Jump_in(id_ex_Jump),
.JumpReg_in(id_ex_JumpReg),

.pc_plus_4_out(ex_mem_pc_plus_4),

.Jump_out(ex_mem_Jump),
.JumpReg_out(ex_mem_JumpReg)

);  
  
  
//------------------------------------------------------------
// Memory Interface
//------------------------------------------------------------

assign mem_read  = ex_mem_MemRead;

assign mem_write = ex_mem_MemWrite;

assign mem_addr  = ex_mem_alu_result;

assign mem_wdata = ex_mem_write_data;
  
//============================================================
// DATA MEMORY
//============================================================

data_memory DMEM (

    .clk(clk),

    .mem_read(mem_read),
    .mem_write(mem_write),

    .address(mem_addr),

    .write_data(mem_wdata),

    .read_data(mem_rdata)

);  
  
//------------------------------------------------------------
// MEM / WB Register
//------------------------------------------------------------

mem_wb_reg MEM_WB(

    .clk(clk),
    .rst(rst),
    .hold(1'b0),   // riscv-soc-fir-hls: giữ hành vi gốc

    .mem_data_in(mem_rdata),

    .alu_result_in(ex_mem_alu_result),

    .rd_in(ex_mem_rd),

    .MemToReg_in(ex_mem_MemToReg),

    .RegWrite_in(ex_mem_RegWrite),

    .Jump_in(ex_mem_Jump),
    .JumpReg_in(ex_mem_JumpReg),

    .pc_plus_4_in(ex_mem_pc_plus_4),

    .mem_data_out(mem_wb_mem_data),

    .alu_result_out(mem_wb_alu_result),

    .rd_out(mem_wb_rd),

    .MemToReg_out(mem_wb_MemToReg),

    .RegWrite_out(mem_wb_RegWrite),

    .Jump_out(mem_wb_Jump),
    .JumpReg_out(mem_wb_JumpReg),

    .pc_plus_4_out(mem_wb_pc_plus_4)

);
  
wb_stage WB (

    .ALU_Result(mem_wb_alu_result),

    .MemoryData(mem_wb_mem_data),

    .pc_plus_4(mem_wb_pc_plus_4),

    .MemToReg(mem_wb_MemToReg),

    .Jump(mem_wb_Jump),

    .JumpReg(mem_wb_JumpReg),

    .WriteBackData(WriteBackData)

);
  
forwarding_unit FU(

    .id_ex_rs1(id_ex_rs1),
    .id_ex_rs2(id_ex_rs2),

    .ex_mem_rd(ex_mem_rd),
    .mem_wb_rd(mem_wb_rd),

    .ex_mem_RegWrite(ex_mem_RegWrite),
    .mem_wb_RegWrite(mem_wb_RegWrite),

    .ForwardA(ForwardA),
    .ForwardB(ForwardB)

);    
  

  
hazard_detection_unit HDU (

    .id_ex_MemRead(id_ex_MemRead),

    .id_ex_rd(id_ex_rd),

    .if_id_rs1(rs1),
    .if_id_rs2(rs2),

    .PCWrite(PCWrite),

    .IF_ID_Write(IF_ID_Write),

    .ControlMuxSelect(ControlMuxSelect)

);  

flush_unit FLUSH (

    .branch_taken(ex_branch_taken),

    .jump(id_ex_Jump),

    .jump_reg(id_ex_JumpReg),

    .flush_if_id(flush_if_id),

    .flush_id_ex(flush_id_ex)

);
  
endmodule



