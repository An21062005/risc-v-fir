`timescale 1ns/1ps

//======================================================================
// tb_cpu_flush_hold : ID/EX flush + hold inside the real CPU/SoC
//======================================================================
// Real soc_top (ENABLE_EXT_RAM = 1, B or C via USE_CACHE): a bus access in
// MEM holds the whole pipeline (bus_stall) while the instruction in EX is a
// taken branch / JAL / JALR, so id_ex_reg sees flush = 1 and hold = 1 at the
// same time. Program (assembled with the Vivado RISC-V GCC, -Ttext=0):
//   A  taken BEQ in EX while SW to ext RAM stalls        (flush + hold)
//   B  JAL in EX while LW from ext RAM stalls             (flush + hold)
//   C  JALR after a load-use stall on a bus load
//   C2 JALR in EX while SW stalls; rs1 forwarded from the LW held in WB
//   D  not-taken BNE in EX while SW stalls               (hold, no flush)
//   E  backward BNE right after an ext-RAM LW, 5 iterations
//   F  taken BEQ behind an MMIO read stall, branch behind it in ID
// Wrong-path instructions write x10 != 0; x10 must never be written != 0.
// Monitors (every edge, after reset):
//   - bus_stall at an edge  -> every ID/EX output unchanged across it
//   - flush && !bus_stall   -> ID/EX cleared at that edge
//   - no wrong-path write to x10
//   - coverage of each flush/hold combination listed above
// Run 1: complete program. Run 2: asynchronous rst_n assertion between
// edges while flush and hold are both 1 -> ID/EX, IF/ID and PC clear without
// a clock edge. Run 3: rerun after that abort, same results.
//======================================================================

module tb_cpu_flush_hold;

    parameter USE_CACHE = 0;

    reg clk = 1'b0, rst_n = 1'b0;
    wire irq;
    always #5 clk = ~clk;

    soc_top #(.ENABLE_EXT_RAM(1), .EXT_RAM_USE_CACHE(USE_CACHE)) dut (
        .clk(clk), .rst_n(rst_n), .cpu_irq(irq));

    integer errors = 0, checks = 0, i, t;

    task ck;
        input cond;
        input [8*96-1:0] message;
        begin
            checks = checks + 1;
            if (cond !== 1'b1) begin
                errors = errors + 1;
                $display("ERROR %0s (t=%0t)", message, $time);
            end
        end
    endtask

    //------------------------------------------------------------
    // ID/EX state as seen from the CPU
    //------------------------------------------------------------
    wire [31:0] idex_pc   = dut.u_cpu.id_ex_pc;
    wire [31:0] idex_rd1  = dut.u_cpu.id_ex_read_data1;
    wire [31:0] idex_rd2  = dut.u_cpu.id_ex_read_data2;
    wire [31:0] idex_imm  = dut.u_cpu.id_ex_immediate;
    wire [14:0] idex_regs = {dut.u_cpu.id_ex_rs1, dut.u_cpu.id_ex_rs2, dut.u_cpu.id_ex_rd};
    wire [9:0]  idex_func = {dut.u_cpu.id_ex_funct3, dut.u_cpu.id_ex_funct7};
    wire [11:0] idex_ctrl = {dut.u_cpu.id_ex_RegWrite, dut.u_cpu.id_ex_MemRead,
                             dut.u_cpu.id_ex_MemWrite, dut.u_cpu.id_ex_MemToReg,
                             dut.u_cpu.id_ex_Branch, dut.u_cpu.id_ex_Jump,
                             dut.u_cpu.id_ex_JumpReg, dut.u_cpu.id_ex_ALUSrc,
                             dut.u_cpu.id_ex_isLUI, dut.u_cpu.id_ex_isAUIPC,
                             dut.u_cpu.id_ex_ALUOp};
    wire [164:0] idex = {idex_pc, idex_rd1, idex_rd2, idex_imm, idex_regs, idex_func, idex_ctrl};

    wire bus_stall = dut.u_cpu.bus_stall;
    wire flush     = dut.u_cpu.flush_id_ex;

    //------------------------------------------------------------
    // Monitors (values sampled at the edge = state before the edge)
    //------------------------------------------------------------
    reg         mon_en = 1'b0;
    reg         prev_valid = 1'b0, prev_stall = 1'b0, prev_flush = 1'b0;
    reg [164:0] prev_idex;
    integer cov_taken_hold = 0, cov_jal_hold = 0, cov_jalr_hold = 0, cov_nt_hold = 0;
    integer cov_flush_run = 0, cov_hold = 0, wrong_path = 0, hold_err = 0, flush_err = 0;

    always @(posedge clk) begin
        if (mon_en && rst_n) begin
            if (prev_valid && prev_stall && (idex !== prev_idex)) begin
                hold_err = hold_err + 1;
                if (hold_err <= 5) $display("ERROR ID/EX changed across a held edge (t=%0t)", $time);
            end
            if (prev_valid && !prev_stall && prev_flush && (idex !== 165'd0)) begin
                flush_err = flush_err + 1;
                if (flush_err <= 5) $display("ERROR ID/EX not cleared by flush (t=%0t)", $time);
            end
            if (dut.u_cpu.mem_wb_RegWrite && dut.u_cpu.mem_wb_rd == 5'd10 &&
                dut.u_cpu.WriteBackData != 32'd0) begin
                wrong_path = wrong_path + 1;
                $display("ERROR wrong-path instruction wrote x10 = %0d (t=%0t)",
                         dut.u_cpu.WriteBackData, $time);
            end
            if (bus_stall) cov_hold = cov_hold + 1;
            if (bus_stall && dut.u_cpu.ex_branch_taken) cov_taken_hold = cov_taken_hold + 1;
            if (bus_stall && dut.u_cpu.id_ex_Jump)      cov_jal_hold   = cov_jal_hold + 1;
            if (bus_stall && dut.u_cpu.id_ex_JumpReg)   cov_jalr_hold  = cov_jalr_hold + 1;
            if (bus_stall && dut.u_cpu.id_ex_Branch && !dut.u_cpu.ex_branch_taken)
                cov_nt_hold = cov_nt_hold + 1;
            if (!bus_stall && flush) cov_flush_run = cov_flush_run + 1;
            prev_valid = 1'b1;
            prev_stall = bus_stall;
            prev_flush = flush;
            prev_idex  = idex;
        end else begin
            prev_valid = 1'b0;
        end
    end

    //------------------------------------------------------------
    // Program
    //------------------------------------------------------------
    task install;
        begin
            for (i = 0; i < 256; i = i + 1) begin
                dut.u_cpu.IMEM.memory[i] = 32'h00000013;
                dut.u_cpu.DMEM.memory[i] = 32'd0;
            end
            dut.u_cpu.IMEM.memory[0] = 32'h400100b7; // 00: lui x1,0x40010
            dut.u_cpu.IMEM.memory[1] = 32'h10000137; // 04: lui x2,0x10000
            dut.u_cpu.IMEM.memory[2] = 32'h400001b7; // 08: lui x3,0x40000
            dut.u_cpu.IMEM.memory[3] = 32'h12300293; // 0c: addi x5,x0,291
            dut.u_cpu.IMEM.memory[4] = 32'h00000513; // 10: addi x10,x0,0
            dut.u_cpu.IMEM.memory[5] = 32'h00000613; // 14: addi x12,x0,0
            dut.u_cpu.IMEM.memory[6] = 32'h00000713; // 18: addi x14,x0,0
            dut.u_cpu.IMEM.memory[7] = 32'h00500793; // 1c: addi x15,x0,5
            dut.u_cpu.IMEM.memory[8] = 32'h00000813; // 20: addi x16,x0,0
            // A
            dut.u_cpu.IMEM.memory[9] = 32'h0050a023; // 24: sw x5,0(x1)
            dut.u_cpu.IMEM.memory[10] = 32'h00000663; // 28: beq x0,x0,34 <a_ok>
            dut.u_cpu.IMEM.memory[11] = 32'h00100513; // 2c: addi x10,x0,1   (wrong path)
            dut.u_cpu.IMEM.memory[12] = 32'h00200513; // 30: addi x10,x0,2   (wrong path)
            // B
            dut.u_cpu.IMEM.memory[13] = 32'h0000a303; // 34: lw x6,0(x1)
            dut.u_cpu.IMEM.memory[14] = 32'h00c003ef; // 38: jal x7,44 <b_ok>
            dut.u_cpu.IMEM.memory[15] = 32'h00300513; // 3c: addi x10,x0,3   (wrong path)
            dut.u_cpu.IMEM.memory[16] = 32'h00400513; // 40: addi x10,x0,4   (wrong path)
            // C
            dut.u_cpu.IMEM.memory[17] = 32'h05c00413; // 44: addi x8,x0,92 (c_ok)
            dut.u_cpu.IMEM.memory[18] = 32'h0080a423; // 48: sw x8,8(x1)
            dut.u_cpu.IMEM.memory[19] = 32'h0080a483; // 4c: lw x9,8(x1)
            dut.u_cpu.IMEM.memory[20] = 32'h000485e7; // 50: jalr x11,0(x9)
            dut.u_cpu.IMEM.memory[21] = 32'h00500513; // 54: addi x10,x0,5   (wrong path)
            dut.u_cpu.IMEM.memory[22] = 32'h00600513; // 58: addi x10,x0,6   (wrong path)
            // C2
            dut.u_cpu.IMEM.memory[23] = 32'h07400413; // 5c: addi x8,x0,116 (c2_ok)
            dut.u_cpu.IMEM.memory[24] = 32'h0080aa23; // 60: sw x8,20(x1)
            dut.u_cpu.IMEM.memory[25] = 32'h0140a483; // 64: lw x9,20(x1)
            dut.u_cpu.IMEM.memory[26] = 32'h0050a823; // 68: sw x5,16(x1)
            dut.u_cpu.IMEM.memory[27] = 32'h000489e7; // 6c: jalr x19,0(x9)
            dut.u_cpu.IMEM.memory[28] = 32'h00900513; // 70: addi x10,x0,9   (wrong path)
            // D
            dut.u_cpu.IMEM.memory[29] = 32'h0050a623; // 74: sw x5,12(x1)
            dut.u_cpu.IMEM.memory[30] = 32'h00001663; // 78: bne x0,x0,84 <d_bad>
            dut.u_cpu.IMEM.memory[31] = 32'h00160613; // 7c: addi x12,x12,1
            dut.u_cpu.IMEM.memory[32] = 32'h0080006f; // 80: jal x0,88 <d_ok>
            dut.u_cpu.IMEM.memory[33] = 32'h00700513; // 84: addi x10,x0,7   (d_bad)
            // E
            dut.u_cpu.IMEM.memory[34] = 32'h00680833; // 88: add x16,x16,x6
            dut.u_cpu.IMEM.memory[35] = 32'h00170713; // 8c: addi x14,x14,1
            dut.u_cpu.IMEM.memory[36] = 32'h0000a303; // 90: lw x6,0(x1)
            dut.u_cpu.IMEM.memory[37] = 32'hfef71ae3; // 94: bne x14,x15,88
            // F
            dut.u_cpu.IMEM.memory[38] = 32'h08c1a883; // 98: lw x17,140(x3)  (TICK_COUNT)
            dut.u_cpu.IMEM.memory[39] = 32'h00000663; // 9c: beq x0,x0,a8 <f_ok>
            dut.u_cpu.IMEM.memory[40] = 32'h00000263; // a0: beq x0,x0,a4 <f_bad>
            dut.u_cpu.IMEM.memory[41] = 32'h00800513; // a4: addi x10,x0,8   (f_bad)
            // results
            dut.u_cpu.IMEM.memory[42] = 32'h00a12223; // a8: sw x10,4(x2)
            dut.u_cpu.IMEM.memory[43] = 32'h00c12423; // ac: sw x12,8(x2)
            dut.u_cpu.IMEM.memory[44] = 32'h00e12623; // b0: sw x14,12(x2)
            dut.u_cpu.IMEM.memory[45] = 32'h01012823; // b4: sw x16,16(x2)
            dut.u_cpu.IMEM.memory[46] = 32'h00712a23; // b8: sw x7,20(x2)
            dut.u_cpu.IMEM.memory[47] = 32'h00b12c23; // bc: sw x11,24(x2)
            dut.u_cpu.IMEM.memory[48] = 32'h00612e23; // c0: sw x6,28(x2)
            dut.u_cpu.IMEM.memory[49] = 32'h03312023; // c4: sw x19,32(x2)
            dut.u_cpu.IMEM.memory[50] = 32'h600d6937; // c8: lui x18,0x600d6
            dut.u_cpu.IMEM.memory[51] = 32'h00d90913; // cc: addi x18,x18,13
            dut.u_cpu.IMEM.memory[52] = 32'h01212023; // d0: sw x18,0(x2)
            dut.u_cpu.IMEM.memory[53] = 32'h0000006f; // d4: jal x0,d4 <done>
        end
    endtask

    task run_to_done;
        input [8*24-1:0] label;
        begin
            t = 0;
            while (dut.u_cpu.DMEM.memory[0] !== 32'h600D600D && t < 20000) begin
                @(negedge clk); t = t + 1;
            end
            ck(t < 20000, "program reached the done sentinel");
            ck(dut.u_cpu.DMEM.memory[1] === 32'd0,     "x10 = 0: no wrong-path instruction retired");
            ck(dut.u_cpu.DMEM.memory[2] === 32'd1,     "x12 = 1: not-taken BNE fall-through executed once");
            ck(dut.u_cpu.DMEM.memory[3] === 32'd5,     "x14 = 5: backward BNE loop iterations");
            ck(dut.u_cpu.DMEM.memory[4] === 32'h5AF,   "x16 = 5 * 0x123: loop body with ext-RAM loads");
            ck(dut.u_cpu.DMEM.memory[5] === 32'h3C,    "x7 = JAL link (pc+4)");
            ck(dut.u_cpu.DMEM.memory[6] === 32'h54,    "x11 = JALR link after load-use");
            ck(dut.u_cpu.DMEM.memory[7] === 32'h123,   "x6 = value read back from ext RAM");
            ck(dut.u_cpu.DMEM.memory[8] === 32'h70,    "x19 = JALR link, rs1 forwarded during hold");
            $display("INFO %0s: done after %0d cycles", label, t);
        end
    endtask

    initial begin
        #1;
        //--------------------------------------------------------
        // Run 1
        //--------------------------------------------------------
        rst_n = 0; repeat (5) @(negedge clk);
        install();
        mon_en = 1; rst_n = 1;
        run_to_done("run 1");
        $display("INFO coverage: held edges=%0d taken+hold=%0d jal+hold=%0d jalr+hold=%0d notaken+hold=%0d flush(no hold)=%0d",
                 cov_hold, cov_taken_hold, cov_jal_hold, cov_jalr_hold, cov_nt_hold, cov_flush_run);
        ck(cov_taken_hold > 0, "covered: taken branch in EX while held");
        ck(cov_jal_hold > 0,   "covered: JAL in EX while held");
        ck(cov_jalr_hold > 0,  "covered: JALR in EX while held");
        ck(cov_nt_hold > 0,    "covered: not-taken branch in EX while held");
        ck(cov_flush_run > 0,  "covered: flush without hold");

        //--------------------------------------------------------
        // Run 2: async reset between edges while flush && hold
        //--------------------------------------------------------
        rst_n = 0; repeat (5) @(negedge clk);
        install();
        rst_n = 1;
        t = 0;
        while (!(flush && bus_stall) && t < 20000) begin @(negedge clk); t = t + 1; end
        ck(t < 20000, "reached a cycle with flush = 1 and hold = 1");
        ck(idex_ctrl !== 12'd0, "ID/EX holds a live control word before the reset");
        #2 rst_n = 0;                      // between edges, no clock edge follows yet
        #1;
        ck(idex === 165'd0,                       "async rst clears ID/EX without a clock edge");
        ck(dut.u_cpu.if_id_instruction === 32'd0, "async rst clears IF/ID");
        ck(dut.u_cpu.pc === 32'd0,                "async rst clears PC");
        ck(!dut.u_cpu.ex_mem_MemWrite && !dut.u_cpu.ex_mem_MemRead, "async rst clears EX/MEM request");
        repeat (3) @(posedge clk);
        #1 ck(idex === 165'd0 && dut.u_cpu.pc === 32'd0, "held in reset across edges");

        //--------------------------------------------------------
        // Run 3: full program after the abort
        //--------------------------------------------------------
        @(negedge clk);
        for (i = 0; i < 256; i = i + 1) dut.u_cpu.DMEM.memory[i] = 32'd0;
        rst_n = 1;
        run_to_done("run 3 (after abort)");

        ck(hold_err == 0,   "ID/EX never changed across a held edge");
        ck(flush_err == 0,  "ID/EX always cleared by a flush without hold");
        ck(wrong_path == 0, "no wrong-path write to x10");
        $display("Checks: %0d, errors: %0d, USE_CACHE=%0d", checks, errors, USE_CACHE);
        if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED");
        $finish;
    end

endmodule
