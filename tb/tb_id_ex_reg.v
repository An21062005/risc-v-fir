`timescale 1ns/1ps

// Kiểm tra id_ex_reg: reset bất đồng bộ, hold ưu tiên flush và 20000 chu kỳ ngẫu nhiên.

module tb_id_ex_reg;

    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1, hold = 1'b0, flush = 1'b0;

    // Packed input / output vectors (same order on both sides)
    localparam W = 32*4 + 5*3 + 3 + 7 + 10 + 2;     // 165 bits
    reg  [W-1:0] din;
    wire [W-1:0] dout;

    wire [31:0] pc_o, rd1_o, rd2_o, imm_o;
    wire [4:0]  rs1_o, rs2_o, rd_o;
    wire [2:0]  f3_o;
    wire [6:0]  f7_o;
    wire        RegWrite_o, MemRead_o, MemWrite_o, MemToReg_o, Branch_o,
                Jump_o, JumpReg_o, ALUSrc_o, isLUI_o, isAUIPC_o;
    wire [1:0]  ALUOp_o;

    id_ex_reg dut (
        .clk(clk), .hold(hold), .rst(rst), .flush(flush),
        .pc_in(din[164:133]), .read_data1_in(din[132:101]),
        .read_data2_in(din[100:69]), .immediate_in(din[68:37]),
        .rs1_in(din[36:32]), .rs2_in(din[31:27]), .rd_in(din[26:22]),
        .funct3_in(din[21:19]), .funct7_in(din[18:12]),
        .RegWrite_in(din[11]), .MemRead_in(din[10]), .MemWrite_in(din[9]),
        .MemToReg_in(din[8]), .Branch_in(din[7]), .Jump_in(din[6]),
        .JumpReg_in(din[5]), .isAUIPC_in(din[4]), .ALUSrc_in(din[3]),
        .isLUI_in(din[2]), .ALUOp_in(din[1:0]),
        .pc_out(pc_o), .read_data1_out(rd1_o), .read_data2_out(rd2_o),
        .immediate_out(imm_o), .rs1_out(rs1_o), .rs2_out(rs2_o), .rd_out(rd_o),
        .funct3_out(f3_o), .funct7_out(f7_o),
        .RegWrite_out(RegWrite_o), .MemRead_out(MemRead_o), .MemWrite_out(MemWrite_o),
        .MemToReg_out(MemToReg_o), .Branch_out(Branch_o), .Jump_out(Jump_o),
        .JumpReg_out(JumpReg_o), .ALUSrc_out(ALUSrc_o), .isLUI_out(isLUI_o),
        .isAUIPC_out(isAUIPC_o), .ALUOp_out(ALUOp_o)
    );

    assign dout = {pc_o, rd1_o, rd2_o, imm_o, rs1_o, rs2_o, rd_o, f3_o, f7_o,
                   RegWrite_o, MemRead_o, MemWrite_o, MemToReg_o, Branch_o,
                   Jump_o, JumpReg_o, isAUIPC_o, ALUSrc_o, isLUI_o, ALUOp_o};

    // Independent reference model
    reg [W-1:0] model;
    always @(posedge clk or posedge rst) begin
        if (rst)                 model <= {W{1'b0}};
        else if (!hold && flush) model <= {W{1'b0}};
        else if (!hold)          model <= din;
    end

    integer errors = 0, checks = 0, i, seed;
    integer n_flush = 0, n_hold = 0, n_flush_hold = 0, n_load = 0, n_async_rst = 0;

    task check;
        input [W-1:0] expected;
        input [8*72-1:0] what;
        begin
            checks = checks + 1;
            if (dout !== expected) begin
                errors = errors + 1;
                if (errors <= 20)
                    $display("ERROR %0s at %0t: got %h expected %h", what, $time, dout, expected);
            end
        end
    endtask

    function [W-1:0] rnd;
        input integer dummy;
        integer k;
        begin
            for (k = 0; k < W; k = k + 32)
                rnd[k +: 32] = $random(seed);
        end
    endfunction

    // Drive inputs/controls at negedge, sample shortly after posedge
    task cycle;
        input r, h, f;
        input [W-1:0] d;
        begin
            @(negedge clk); rst = r; hold = h; flush = f; din = d;
            @(posedge clk); #1;
        end
    endtask

    reg [W-1:0] snap, pattern;

    initial begin
        seed = 1;
        if (!$value$plusargs("seed=%d", seed)) seed = 1;
        din = {W{1'b0}};
        #200;                                  // past glbl GSR (netlist run)

        // 1. Directed corners
        pattern = rnd(0);
        cycle(1, 0, 0, pattern); check(0, "rst=1 clears");
        cycle(1, 1, 1, pattern); check(0, "rst=1 with hold=1 flush=1 clears");
        cycle(0, 0, 0, pattern); check(pattern, "load after rst release");
        cycle(0, 1, 0, ~pattern); check(pattern, "hold keeps value");
        cycle(0, 1, 1, ~pattern); check(pattern, "hold beats flush");
        cycle(0, 0, 1, ~pattern); check(0, "flush when hold released");
        cycle(0, 0, 0, ~pattern); check(~pattern, "load after flush");
        cycle(0, 1, 1, pattern); check(~pattern, "flush+hold again keeps");
        cycle(0, 0, 0, pattern); check(pattern, "hold released without flush loads");

        // 2. Edges between clocks
        @(negedge clk); hold = 0; flush = 0; din = ~pattern;
        #2 flush = 1;
        #1 check(pattern, "flush mid-cycle is not asynchronous");
        @(posedge clk); #1 check(0, "flush applied at edge");
        // hold rises mid-cycle: no change before the edge
        cycle(0, 0, 0, pattern); check(pattern, "reload");
        @(negedge clk); flush = 1; hold = 0; din = ~pattern;
        #1 hold = 1;
        #1 check(pattern, "hold mid-cycle no change");
        @(posedge clk); #1 check(pattern, "hold sampled at edge beats flush");
        // rst rises mid-cycle: immediate clear, no edge needed
        @(negedge clk); hold = 0; flush = 0; din = pattern;
        #2 rst = 1;
        #1 check(0, "rst mid-cycle clears asynchronously");
        #1 rst = 0;
        #0.5 check(0, "stays clear after rst pulse until next edge");
        @(posedge clk); #1 check(pattern, "load after async rst pulse");

        // 3. Random against model, including async rst pulses
        for (i = 0; i < 20000; i = i + 1) begin
            @(negedge clk);
            din   = rnd(0);
            hold  = ($random(seed) % 4) == 0;
            flush = ($random(seed) % 3) == 0;
            rst   = ($random(seed) % 500) == 0;
            if (!rst && hold && flush) n_flush_hold = n_flush_hold + 1;
            else if (!rst && hold)     n_hold = n_hold + 1;
            else if (!rst && flush)    n_flush = n_flush + 1;
            else if (!rst)             n_load = n_load + 1;
            if (($random(seed) % 400) == 0) begin
                // async rst pulse between edges
                #2 rst = 1; n_async_rst = n_async_rst + 1;
                #1 check({W{1'b0}}, "random async rst clears immediately");
                #1 rst = 0;
            end
            @(posedge clk); #1;
            check(model, "random vs model");
        end

        $display("INFO id_ex_reg: load=%0d flush=%0d hold=%0d flush+hold=%0d async_rst=%0d",
                 n_load, n_flush, n_hold, n_flush_hold, n_async_rst);
        checks = checks + 1;
        if (n_flush_hold < 100 || n_async_rst < 10) begin
            errors = errors + 1;
            $display("ERROR coverage too low");
        end
        $display("Checks: %0d, errors: %0d", checks, errors);
        if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED");
        $finish;
    end

endmodule
