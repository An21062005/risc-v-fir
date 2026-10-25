`timescale 1ns/1ps

// CPU RV32I 5 tầng; địa chỉ 0x40000000 đi bus, pipeline giữ khi chờ bus, IRQ không lồng.

module rvcore32_pipeline_soc #(
    parameter [31:0] TRAP_VECTOR = 32'h0000_0010
) (
    input  wire        clk,
    input  wire        rst,          // mức cao

    input  wire        irq,          // từ interrupt_controller (mức)

    output wire        bus_rd,
    output wire        bus_wr,
    output wire [31:0] bus_addr,
    output wire [31:0] bus_wdata,
    input  wire [31:0] bus_rdata,
    input  wire        bus_ready
);

    localparam [31:0] MRET_INSTR = 32'h3020_0073;

    // IF
    wire [31:0] pc;
    wire [31:0] next_pc;
    wire [31:0] instruction;

    // IF/ID
    wire [31:0] if_id_pc;
    wire [31:0] if_id_instruction;

    // ID
    wire [6:0]  opcode;
    wire [4:0]  rd;
    wire [2:0]  funct3;
    wire [4:0]  rs1;
    wire [4:0]  rs2;
    wire [6:0]  funct7;
    wire [31:0] read_data1;
    wire [31:0] read_data2;
    wire [31:0] immediate;

    wire        RegWrite, MemRead, MemWrite, Branch, Jump, JumpReg, ALUSrc, MemToReg;
    wire [1:0]  ALUOp;
    wire        is_lui, is_auipc;

    wire        stall_RegWrite, stall_MemRead, stall_MemWrite, stall_Branch;
    wire        stall_Jump, stall_JumpReg, stall_ALUSrc, stall_MemToReg;
    wire [1:0]  stall_ALUOp;
    wire        stall_isLUI, stall_isAUIPC;

    // ID/EX
    wire [31:0] id_ex_pc;
    wire [31:0] id_ex_read_data1;
    wire [31:0] id_ex_read_data2;
    wire [31:0] id_ex_immediate;
    wire [4:0]  id_ex_rs1;
    wire [4:0]  id_ex_rs2;
    wire [4:0]  id_ex_rd;
    wire [2:0]  id_ex_funct3;
    wire [6:0]  id_ex_funct7;
    wire        id_ex_RegWrite, id_ex_MemRead, id_ex_MemWrite, id_ex_MemToReg;
    wire        id_ex_Branch, id_ex_Jump, id_ex_JumpReg, id_ex_ALUSrc;
    wire [1:0]  id_ex_ALUOp;
    wire        id_ex_isLUI, id_ex_isAUIPC;

    // EX
    wire [31:0] ex_operand_b;
    wire [31:0] ex_alu_A;
    wire [3:0]  ex_alu_control;
    wire [31:0] ex_alu_result;
    wire        ex_zero;
    wire        ex_branch_condition;
    wire        ex_branch_taken;
    wire [31:0] ex_branch_target;
    wire [31:0] ex_jump_target;
    wire [31:0] ex_jalr_target;

    // EX/MEM
    wire [31:0] ex_mem_alu_result;
    wire [31:0] ex_mem_write_data;
    wire [4:0]  ex_mem_rd;
    wire        ex_mem_RegWrite, ex_mem_MemRead, ex_mem_MemWrite, ex_mem_MemToReg;
    wire        ex_mem_Jump, ex_mem_JumpReg;
    wire [31:0] ex_mem_pc_plus_4;

    // MEM/WB
    wire [31:0] mem_wb_mem_data;
    wire [31:0] mem_wb_alu_result;
    wire [4:0]  mem_wb_rd;
    wire        mem_wb_MemToReg, mem_wb_RegWrite, mem_wb_Jump, mem_wb_JumpReg;
    wire [31:0] mem_wb_pc_plus_4;
    wire [31:0] WriteBackData;

    // Hazard / forwarding / flush
    wire [1:0]  ForwardA, ForwardB;
    wire [31:0] forwarded_A, forwarded_B;
    wire        PCWrite, IF_ID_Write, ControlMuxSelect;
    wire        flush_if_id, flush_id_ex;

    // MEM stage: address split, bus port, stall
    wire        is_bus_addr = (ex_mem_alu_result[31:30] == 2'b01);

    assign bus_rd    = ex_mem_MemRead  &  is_bus_addr;
    assign bus_wr    = ex_mem_MemWrite &  is_bus_addr;
    assign bus_addr  = {2'b00, ex_mem_alu_result[29:0]};
    assign bus_wdata = ex_mem_write_data;

    wire        bus_stall = (bus_rd | bus_wr) & ~bus_ready;

    wire        dmem_read  = ex_mem_MemRead  & ~is_bus_addr;
    wire        dmem_write = ex_mem_MemWrite & ~is_bus_addr;
    wire [31:0] dmem_rdata;
    wire [31:0] mem_rdata  = is_bus_addr ? bus_rdata : dmem_rdata;

    // Interrupt / mret control
    reg  [31:0] mepc;
    reg         in_irq;

    wire is_mret_id  = (if_id_instruction == MRET_INSTR);
    wire redirect_ex = ex_branch_taken | id_ex_Jump | id_ex_JumpReg;
    wire ctrl_in_id  = Branch | Jump | JumpReg | is_mret_id;

    wire mret_take   = is_mret_id & ~redirect_ex & ~bus_stall & PCWrite;
    wire irq_take    = irq & ~in_irq & ~bus_stall & PCWrite &
                       ~redirect_ex & ~ctrl_in_id;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mepc   <= 32'd0;
            in_irq <= 1'b0;
        end else if (irq_take) begin
            mepc   <= pc;
            in_irq <= 1'b1;
        end else if (mret_take) begin
            in_irq <= 1'b0;
        end
    end

    // Next PC (priority: EX redirect > mret > interrupt > pc+4)
    assign next_pc =
           id_ex_JumpReg   ? ex_jalr_target   :
           id_ex_Jump      ? ex_jump_target   :
           ex_branch_taken ? ex_branch_target :
           mret_take       ? mepc             :
           irq_take        ? TRAP_VECTOR      :
                             pc + 32'd4;

    program_counter PC (
        .clk(clk),
        .rst(rst),
        .enable(PCWrite & ~bus_stall),
        .next_pc(next_pc),
        .pc(pc)
    );

    instruction_memory IMEM (
        .address(pc),
        .instruction(instruction)
    );

    if_id_reg IF_ID (
        .clk(clk),
        .rst(rst),
        .hold(bus_stall),
        .write_enable(IF_ID_Write),
        .flush(flush_if_id | mret_take | irq_take),
        .pc_in(pc),
        .instr_in(instruction),
        .pc_out(if_id_pc),
        .instr_out(if_id_instruction)
    );

    // ID
    decoder DEC (
        .instruction(if_id_instruction),
        .opcode(opcode),
        .rd(rd),
        .funct3(funct3),
        .rs1(rs1),
        .rs2(rs2),
        .funct7(funct7)
    );

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

    immediate_generator IG (
        .instruction(if_id_instruction),
        .immediate(immediate)
    );

    assign is_lui   = (opcode == 7'b0110111);
    assign is_auipc = (opcode == 7'b0010111);

    assign stall_RegWrite = ControlMuxSelect ? 1'b0  : RegWrite;
    assign stall_MemRead  = ControlMuxSelect ? 1'b0  : MemRead;
    assign stall_MemWrite = ControlMuxSelect ? 1'b0  : MemWrite;
    assign stall_Branch   = ControlMuxSelect ? 1'b0  : Branch;
    assign stall_Jump     = ControlMuxSelect ? 1'b0  : Jump;
    assign stall_JumpReg  = ControlMuxSelect ? 1'b0  : JumpReg;
    assign stall_ALUSrc   = ControlMuxSelect ? 1'b0  : ALUSrc;
    assign stall_MemToReg = ControlMuxSelect ? 1'b0  : MemToReg;
    assign stall_ALUOp    = ControlMuxSelect ? 2'b00 : ALUOp;
    assign stall_isLUI    = ControlMuxSelect ? 1'b0  : is_lui;
    assign stall_isAUIPC  = ControlMuxSelect ? 1'b0  : is_auipc;

    id_ex_reg ID_EX (
        .clk(clk),
        .rst(rst),
        .hold(bus_stall),
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
        .MemToReg_in(stall_MemToReg),
        .Branch_in(stall_Branch),
        .Jump_in(stall_Jump),
        .JumpReg_in(stall_JumpReg),
        .isAUIPC_in(stall_isAUIPC),
        .ALUSrc_in(stall_ALUSrc),
        .isLUI_in(stall_isLUI),
        .ALUOp_in(stall_ALUOp),
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
        .isLUI_out(id_ex_isLUI),
        .isAUIPC_out(id_ex_isAUIPC),
        .ALUOp_out(id_ex_ALUOp)
    );

    // EX
    assign forwarded_A =
           (ForwardA == 2'b00) ? id_ex_read_data1  :
           (ForwardA == 2'b10) ? ex_mem_alu_result :
                                 WriteBackData;
    assign forwarded_B =
           (ForwardB == 2'b00) ? id_ex_read_data2  :
           (ForwardB == 2'b10) ? ex_mem_alu_result :
                                 WriteBackData;

    assign ex_operand_b = id_ex_ALUSrc ? id_ex_immediate : forwarded_B;
    assign ex_alu_A     = id_ex_isLUI   ? 32'd0    :
                          id_ex_isAUIPC ? id_ex_pc :
                                          forwarded_A;

    alu_control AC (
        .ALUOp(id_ex_ALUOp),
        .funct3(id_ex_funct3),
        .funct7(id_ex_funct7),
        .ALU_Control(ex_alu_control)
    );

    alu ALU (
        .A(ex_alu_A),
        .B(ex_operand_b),
        .ALU_Control(ex_alu_control),
        .Result(ex_alu_result),
        .Zero(ex_zero)
    );

    assign ex_branch_target = id_ex_pc + id_ex_immediate;
    assign ex_jump_target   = id_ex_pc + id_ex_immediate;
    assign ex_jalr_target   = (forwarded_A + id_ex_immediate) & ~32'd1;

    assign ex_branch_condition =
           (id_ex_funct3 == 3'b000) ?  ex_zero                  :   // BEQ
           (id_ex_funct3 == 3'b001) ? ~ex_zero                  :   // BNE
           (id_ex_funct3 == 3'b100) ? (ex_alu_result == 32'd1)  :   // BLT
           (id_ex_funct3 == 3'b101) ? (ex_alu_result == 32'd0)  :   // BGE
                                      1'b0;                         // BLTU/BGEU: không hỗ trợ (như bản gốc)

    assign ex_branch_taken = id_ex_Branch && ex_branch_condition;

    ex_mem_reg EX_MEM (
        .clk(clk),
        .rst(rst),
        .hold(bus_stall),
        .alu_result_in(ex_alu_result),
        .write_data_in(forwarded_B),
        .rd_in(id_ex_rd),
        .RegWrite_in(id_ex_RegWrite),
        .MemRead_in(id_ex_MemRead),
        .MemWrite_in(id_ex_MemWrite),
        .MemToReg_in(id_ex_MemToReg),
        .Jump_in(id_ex_Jump),
        .JumpReg_in(id_ex_JumpReg),
        .pc_plus_4_in(id_ex_pc + 32'd4),
        .alu_result_out(ex_mem_alu_result),
        .write_data_out(ex_mem_write_data),
        .rd_out(ex_mem_rd),
        .RegWrite_out(ex_mem_RegWrite),
        .MemRead_out(ex_mem_MemRead),
        .MemWrite_out(ex_mem_MemWrite),
        .MemToReg_out(ex_mem_MemToReg),
        .Jump_out(ex_mem_Jump),
        .JumpReg_out(ex_mem_JumpReg),
        .pc_plus_4_out(ex_mem_pc_plus_4)
    );

    // MEM
    data_memory DMEM (
        .clk(clk),
        .mem_read(dmem_read),
        .mem_write(dmem_write),
        .address(ex_mem_alu_result),
        .write_data(ex_mem_write_data),
        .read_data(dmem_rdata)
    );

    mem_wb_reg MEM_WB (
        .clk(clk),
        .rst(rst),
        .hold(bus_stall),
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

    // WB
    wb_stage WB (
        .ALU_Result(mem_wb_alu_result),
        .MemoryData(mem_wb_mem_data),
        .pc_plus_4(mem_wb_pc_plus_4),
        .MemToReg(mem_wb_MemToReg),
        .Jump(mem_wb_Jump),
        .JumpReg(mem_wb_JumpReg),
        .WriteBackData(WriteBackData)
    );

    // Forwarding, hazard detection, flush (unchanged units)
    forwarding_unit FU (
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
