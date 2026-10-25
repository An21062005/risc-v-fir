`timescale 1ns/1ps

// Directed instruction fixture, not a firmware build. Exercises the actual CPU,
module tb_cpu_bus;
    parameter USE_CACHE = 0;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst_n = 0;
    wire cpu_irq;
    soc_top #(.ENABLE_EXT_RAM(1), .EXT_RAM_USE_CACHE(USE_CACHE)) dut (
        .clk(clk), .rst_n(rst_n), .cpu_irq(cpu_irq)
    );
    integer errors = 0, checks = 0;
    integer starts = 0, finishes = 0, completions = 0, responses = 0;
    integer wait_length = 0, longest_wait = 0, irq_while_stalled = 0;
    reg prev_stall = 0;
    wire [255:0] pipeline_state = {
        dut.u_cpu.pc, dut.u_cpu.if_id_pc, dut.u_cpu.if_id_instruction,
        dut.u_cpu.id_ex_pc, dut.u_cpu.id_ex_read_data1,
        dut.u_cpu.ex_mem_alu_result, dut.u_cpu.mem_wb_mem_data,
        dut.u_cpu.mem_wb_alu_result
    };
    reg [255:0] saved_pipeline;
    reg [65:0] saved_request;
    always @(posedge clk) begin
        if (rst_n) begin
            if (prev_stall) begin
                checks = checks + 1;
                if (pipeline_state !== saved_pipeline ||
                    {dut.bus_rd, dut.bus_wr, dut.bus_addr, dut.bus_wdata} !== saved_request) begin
                    errors = errors + 1;
                    $display("ERROR: pipeline/request changed while bus stalled");
                end
            end
            if (dut.u_cpu.bus_stall) begin
                wait_length = wait_length + 1;
                if (wait_length > longest_wait) longest_wait = wait_length;
                if (cpu_irq) irq_while_stalled = 1;
            end else wait_length = 0;
            if (dut.u_cpu.irq_take && dut.u_cpu.bus_stall) begin
                errors = errors + 1;
                $display("ERROR: interrupt taken before bus transaction completed");
            end
            if (dut.u_fir.accept) starts = starts + 1;
            if (dut.u_fir.hls_finish) finishes = finishes + 1;
            if (dut.bus_ready) completions = completions + 1;
            if ((dut.axi_bvalid && dut.axi_bready) ||
                (dut.axi_rvalid && dut.axi_rready)) responses = responses + 1;
        end
        prev_stall = rst_n && dut.u_cpu.bus_stall;
        saved_pipeline = pipeline_state;
        saved_request = {dut.bus_rd, dut.bus_wr, dut.bus_addr, dut.bus_wdata};
    end

    task check;
        input condition;
        input [511:0] message;
        begin
            checks = checks + 1;
            if (condition !== 1'b1) begin
                errors = errors + 1;
                $display("ERROR: %0s", message);
            end
        end
    endtask
    function [31:0] addi;
        input [4:0] rd, rs;
        input [11:0] imm;
        begin addi = {imm, rs, 3'b000, rd, 7'b0010011}; end
    endfunction
    function [31:0] lw;
        input [4:0] rd, rs;
        input [11:0] imm;
        begin lw = {imm, rs, 3'b010, rd, 7'b0000011}; end
    endfunction
    function [31:0] sw;
        input [4:0] rs2, rs1;
        input [11:0] imm;
        begin sw = {imm[11:5], rs2, rs1, 3'b010, imm[4:0], 7'b0100011}; end
    endfunction
    integer i, timeout;
    initial begin
        // readmemh initializers run at time 0; only then install the fixture.
        #1;
        for (i = 0; i < 256; i = i + 1) dut.u_cpu.IMEM.memory[i] = 32'h00000013;
        dut.u_cpu.IMEM.memory[0] = 32'h0400006f; // jal x0, 0x40
        // Fixed trap vector 0x10. Dedicated registers avoid clobbering main.
        dut.u_cpu.IMEM.memory[4] = addi(20, 20, 1);
        dut.u_cpu.IMEM.memory[5] = sw(21, 1, 12'h1c8); // ACK timer source 0
        dut.u_cpu.IMEM.memory[6] = 32'h30200073;        // mret

        dut.u_cpu.IMEM.memory[16] = 32'h400000b7; // lui x1, 0x40000
        dut.u_cpu.IMEM.memory[17] = addi(21, 0, 1);
        dut.u_cpu.IMEM.memory[18] = addi(2, 0, 7);
        dut.u_cpu.IMEM.memory[19] = sw(2, 1, 12'h200);
        dut.u_cpu.IMEM.memory[20] = lw(3, 1, 12'h208);
        dut.u_cpu.IMEM.memory[21] = {12'd1, 5'd3, 3'b111, 5'd3, 7'b0010011}; // andi
        dut.u_cpu.IMEM.memory[22] = 32'hfe018ce3; // beq x3, x0, -8
        dut.u_cpu.IMEM.memory[23] = lw(4, 1, 12'h204);
        dut.u_cpu.IMEM.memory[24] = sw(4, 0, 12'h020);
        dut.u_cpu.IMEM.memory[25] = 32'h400102b7; // lui x5, 0x40010
        dut.u_cpu.IMEM.memory[26] = addi(6, 0, 85);
        dut.u_cpu.IMEM.memory[27] = sw(21, 1, 12'h1c0); // enable timer IRQ
        dut.u_cpu.IMEM.memory[28] = addi(9, 0, 15);
        dut.u_cpu.IMEM.memory[29] = sw(9, 1, 12'h080);  // start timer
        dut.u_cpu.IMEM.memory[30] = sw(6, 5, 0);
        dut.u_cpu.IMEM.memory[31] = lw(7, 5, 0);
        dut.u_cpu.IMEM.memory[32] = addi(8, 7, 1);     // load-use hazard
        dut.u_cpu.IMEM.memory[33] = sw(8, 0, 12'h024);
        dut.u_cpu.IMEM.memory[34] = 32'h0000006f;      // terminal loop
        repeat (5) @(negedge clk);
        rst_n = 1;
        timeout = 0;
        while (dut.u_cpu.DMEM.memory[9] !== 32'd86 && timeout < 10000) begin
            @(negedge clk); timeout = timeout + 1;
        end
        repeat (30) @(negedge clk);
        check(timeout < 10000, "CPU fixture completed without deadlock");
        check(dut.u_cpu.DMEM.memory[8] === 32'd378, "CPU received FIR(7) = 54 * 7");
        check(dut.u_cpu.DMEM.memory[9] === 32'd86, "RAM load forwarding and dependent store");
        check(starts == 1 && finishes == 1, "exactly one FIR run, no duplicate bus write");
        check(completions == responses, "one CPU completion per AXI response");
        check(longest_wait > 10, "long-latency backend exercised CPU stall");
        check(irq_while_stalled == 1, "timer IRQ arrived while CPU bus stalled");
        check(dut.u_cpu.RF.registers[20] === 32'd1, "ISR executed once and returned");
        check((dut.irq_pending & dut.irq_enable) === 2'b00,
              "ISR acknowledged enabled source; masked FIR pending is independent");
        check(dut.u_fir.overrun_q === 1'b0, "no unexpected FIR overrun");
        $display("Checks: %0d, errors: %0d, longest stall: %0d, USE_CACHE=%0d",
                 checks, errors, longest_wait, USE_CACHE);
        if (errors == 0) $display("TEST PASSED");
        else $display("TEST FAILED (%0d errors)", errors);
        $finish;
    end
endmodule
