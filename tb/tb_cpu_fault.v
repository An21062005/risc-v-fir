`timescale 1ns/1ps

// tb_cpu_fault : AXI error responses and ext-RAM timeout on the real SoC (A1/A2)
module tb_cpu_fault;
    parameter USE_CACHE = 0;
    localparam TIMEOUT = 1024;                 // soc_top default EXT_RAM_TIMEOUT
    reg clk = 0, rst_n = 0;
    wire irq, bus_error;
    always #5 clk = ~clk;
    soc_top #(.ENABLE_EXT_RAM(1), .EXT_RAM_USE_CACHE(USE_CACHE)) dut (
        .clk(clk), .rst_n(rst_n), .cpu_irq(irq), .bus_error(bus_error));

    integer errors = 0, checks = 0, i, t;
    integer b_slverr, r_slverr, b_decerr, r_decerr, completions, rd_done_n, wr_done_n, orphan_swallowed;
    integer cyc = 0, t_ar, t_r, t_aw, t_b;
    task ck;
        input cond;
        input [8*110-1:0] message;
        begin checks = checks + 1; if (cond !== 1'b1) begin errors = errors + 1; $display("ERROR %0s (t=%0t)", message, $time); end end
    endtask
    always @(posedge clk) begin
        cyc <= cyc + 1;
        if (dut.rst_n_sync) begin
            if (dut.axi_bvalid && dut.axi_bready && dut.axi_bresp == 2) b_slverr = b_slverr + 1;
            if (dut.axi_rvalid && dut.axi_rready && dut.axi_rresp == 2) r_slverr = r_slverr + 1;
            if (dut.axi_bvalid && dut.axi_bready && dut.axi_bresp == 3) b_decerr = b_decerr + 1;
            if (dut.axi_rvalid && dut.axi_rready && dut.axi_rresp == 3) r_decerr = r_decerr + 1;
            if (dut.bus_ready) completions = completions + 1;
            if (dut.u_interconnect.EXT_RAM_ARB.rd_done) rd_done_n = rd_done_n + 1;
            if (dut.u_interconnect.EXT_RAM_ARB.wr_done) wr_done_n = wr_done_n + 1;
            if (dut.u_interconnect.EXT_RAM_ARB.orphan && dut.ext_ram_ready) orphan_swallowed = orphan_swallowed + 1;
        end
    end
    function [31:0] x; input integer r; begin x = dut.u_cpu.RF.registers[r]; end endfunction

    task boot;
        begin
            rst_n = 0; repeat (5) @(negedge clk);
            for (i = 0; i < 256; i = i + 1) begin
                dut.u_cpu.IMEM.memory[i] = 32'h00000013;
                dut.u_cpu.DMEM.memory[i] = 0;
            end
            for (i = 0; i < 32; i = i + 1) dut.u_cpu.RF.registers[i] = 0;
            b_slverr = 0; r_slverr = 0; b_decerr = 0; r_decerr = 0; completions = 0;
            rd_done_n = 0; wr_done_n = 0; orphan_swallowed = 0;
        end
    endtask
    task wait_sentinel; input integer limit;
        begin t = 0; while (dut.u_cpu.DMEM.memory[0] !== 1 && t < limit) begin @(negedge clk); t = t + 1; end end
    endtask

    initial begin
        #1;
        //------------------------------------------------------------ Part 1
        boot();
        dut.u_cpu.IMEM.memory[0]  = 32'h400000b7; // lui  x1,0x40000
        dut.u_cpu.IMEM.memory[1]  = 32'h00100113; // addi x2,x0,1
        dut.u_cpu.IMEM.memory[2]  = 32'h2020a6a3; // sw   x2,0x20d(x1)  SLVERR (first error)
        dut.u_cpu.IMEM.memory[3]  = 32'h20d0a183; // lw   x3,0x20d(x1)  SLVERR (overflow)
        dut.u_cpu.IMEM.memory[4]  = 32'h1d00a283; // lw   x5,0x1d0(x1)  BUSERR
        dut.u_cpu.IMEM.memory[5]  = 32'h1d40a303; // lw   x6,0x1d4(x1)  BUSERR_ADDR
        dut.u_cpu.IMEM.memory[6]  = 32'h1c20a823; // sw   x2,0x1d0(x1)  W1C clear
        dut.u_cpu.IMEM.memory[7]  = 32'h1d00a383; // lw   x7,0x1d0(x1)
        dut.u_cpu.IMEM.memory[8]  = 32'h05500413; // addi x8,x0,0x55
        dut.u_cpu.IMEM.memory[9]  = 32'h4080a023; // sw   x8,0x400(x1)  unmapped -> DECERR
        dut.u_cpu.IMEM.memory[10] = 32'h4000a483; // lw   x9,0x400(x1)  unmapped -> DECERR, 0
        dut.u_cpu.IMEM.memory[11] = 32'h1d00a503; // lw   x10,0x1d0(x1)
        dut.u_cpu.IMEM.memory[12] = 32'h1d40a583; // lw   x11,0x1d4(x1)
        dut.u_cpu.IMEM.memory[13] = 32'h10000237; // lui  x4,0x10000
        dut.u_cpu.IMEM.memory[14] = 32'h00222023; // sw   x2,0(x4)      progress sentinel
        dut.u_cpu.IMEM.memory[15] = 32'h0000006f; // j    .
        dut.u_cpu.RF.registers[3] = 32'hDEAD_BEEF;
        dut.u_cpu.RF.registers[9] = 32'hDEAD_BEEF;
        rst_n = 1;
        wait_sentinel(2000);
        ck(t < 2000, "CPU continues after SLVERR/DECERR (no trap, no hang)");
        ck(b_slverr == 1 && r_slverr == 1, "one BRESP SLVERR and one RRESP SLVERR (unaligned MMIO)");
        ck(b_decerr == 1 && r_decerr == 1, "one BRESP DECERR and one RRESP DECERR (unmapped)");
        ck(completions == 10, "one CPU completion per bus access (10; sentinel is DMEM)");
        ck(x(3) === 0, "failed SLVERR read returns 0 to the CPU");
        ck(x(9) === 0, "failed DECERR read returns 0 to the CPU");
        ck(x(5) === 32'h1B, "BUSERR = valid|write|SLVERR|overflow (0x1B)");
        ck(x(6) === 32'h20D, "BUSERR_ADDR = first error address 0x20D");
        ck(x(7) === 0, "BUSERR reads 0 after W1C clear");
        ck(x(10) === 32'h1F, "BUSERR = valid|write|DECERR (write first), read DECERR -> overflow (0x1F)");
        ck(x(11) === 32'h400, "BUSERR_ADDR = 0x400");
        ck(bus_error === 1'b1, "bus_error output follows BUSERR.valid");
        ck(!dut.u_cpu.in_irq && !dut.u_fir.busy_q && !dut.u_fir.done_q && dut.u_fir.overrun_q === 1'b0,
           "error responses have no FIR side effect and no trap");
        $display("INFO part1: SLVERR B/R=%0d/%0d DECERR B/R=%0d/%0d completions=%0d BUSERR=0x%02h/0x%03h -> 0x%02h/0x%03h",
                 b_slverr, r_slverr, b_decerr, r_decerr, completions, x(5), x(6), x(10), x(11));

        //------------------------------------------------------------ Part 2
        boot();
        dut.u_cpu.IMEM.memory[0]  = 32'h400100b7; // lui  x1,0x40010    ext RAM
        dut.u_cpu.IMEM.memory[1]  = 32'h00005437; // lui  x8,0x5
        dut.u_cpu.IMEM.memory[2]  = 32'h05a40413; // addi x8,x8,0x5a    0x505a
        dut.u_cpu.IMEM.memory[3]  = 32'h11100493; // addi x9,x0,0x111
        dut.u_cpu.IMEM.memory[4]  = 32'h0080a023; // sw   x8,0(x1)
        dut.u_cpu.IMEM.memory[5]  = 32'h0090a423; // sw   x9,8(x1)
        dut.u_cpu.IMEM.memory[6]  = 32'h0000a783; // lw   x15,0(x1)
        dut.u_cpu.IMEM.memory[7]  = 32'h1000a183; // lw   x3,0x100(x1)  backend hidden -> timeout
        dut.u_cpu.IMEM.memory[8]  = 32'h22200613; // addi x12,x0,0x222
        dut.u_cpu.IMEM.memory[9]  = 32'h00c0a423; // sw   x12,8(x1)     not granted -> timeout
        dut.u_cpu.IMEM.memory[10] = 32'h0000a503; // lw   x10,0(x1)
        dut.u_cpu.IMEM.memory[11] = 32'h0080a683; // lw   x13,8(x1)
        dut.u_cpu.IMEM.memory[12] = 32'h33300713; // addi x14,x0,0x333
        dut.u_cpu.IMEM.memory[13] = 32'h00e0a623; // sw   x14,12(x1)
        dut.u_cpu.IMEM.memory[14] = 32'h00c0a703; // lw   x14,12(x1)
        dut.u_cpu.IMEM.memory[15] = 32'h10000237; // lui  x4,0x10000
        dut.u_cpu.IMEM.memory[16] = 32'h00100113; // addi x2,x0,1
        dut.u_cpu.IMEM.memory[17] = 32'h00222023; // sw   x2,0(x4)      sentinel
        dut.u_cpu.IMEM.memory[18] = 32'h0000006f; // j    .
        dut.u_cpu.RF.registers[3] = 32'hDEAD_BEEF;
        rst_n = 1;
        // hide the backend as soon as the read of offset 0x100 is requested
        wait (dut.u_interconnect.READ_FSM.ext_ram_rd_req && dut.u_interconnect.READ_FSM.ext_ram_rd_addr == 32'h100);
        force dut.g_ext_ram.u_ext_mem.arb_mem_read  = 1'b0;
        force dut.g_ext_ram.u_ext_mem.arb_mem_write = 1'b0;
        t_ar = cyc;
        wait (dut.axi_rvalid && dut.axi_rready); t_r = cyc;
        ck(dut.axi_rresp == 2 && dut.axi_rdata == 0, "timed-out read: RRESP SLVERR, RDATA 0");
        ck(t_r - t_ar >= TIMEOUT && t_r - t_ar <= TIMEOUT + 8, "read response only after EXT_RAM_TIMEOUT cycles");
        @(negedge clk);
        wait (dut.u_interconnect.WRITE_FSM.ext_ram_wr_req); t_aw = cyc;
        ck(dut.u_interconnect.EXT_RAM_ARB.orphan === 1'b1, "timed-out read is an orphan while the backend is busy");
        wait (dut.axi_bvalid && dut.axi_bready); t_b = cyc;
        ck(dut.axi_bresp == 2, "write blocked by the orphan: BRESP SLVERR");
        ck(t_b - t_aw >= TIMEOUT && t_b - t_aw <= TIMEOUT + 8, "write response only after EXT_RAM_TIMEOUT cycles");
        @(negedge clk);
        release dut.g_ext_ram.u_ext_mem.arb_mem_read;
        release dut.g_ext_ram.u_ext_mem.arb_mem_write;
        wait_sentinel(4000);
        ck(t < 4000, "CPU finishes the program after both timeouts");
        ck(orphan_swallowed == 1, "late backend completion of the orphan is swallowed exactly once");
        ck(x(3) === 0, "timed-out read returned 0 (not the late data)");
        ck(x(10) === 32'h505a, "read after recovery: correct data 0x505a");
        ck(x(13) === 32'h111, "timed-out write never reached the memory (0x111 kept)");
        ck(x(14) === 32'h333, "write/read after recovery: 0x333");
        ck(r_slverr == 1 && b_slverr == 1 && r_decerr == 0 && b_decerr == 0, "exactly one timeout per channel");
        ck(completions == 9, "one CPU completion per bus access (9), none for the orphan");
        ck(rd_done_n == 4 && wr_done_n == 3, "backend done reported only for granted, live requests (4 R + 3 W)");
        ck(dut.buserr_valid && !dut.buserr_write && dut.buserr_resp == 2 && dut.buserr_addr == 32'h0001_0100 && dut.buserr_overflow,
           "BUSERR captured the timed-out read (0x10100) first, write timeout -> overflow");
        $display("INFO part2: read timeout %0d clk, write timeout %0d clk, orphan swallowed=%0d, completions=%0d, rd/wr_done=%0d/%0d",
                 t_r - t_ar, t_b - t_aw, orphan_swallowed, completions, rd_done_n, wr_done_n);

        //------------------------------------------------------------ Part 3
        boot();
        dut.u_cpu.IMEM.memory[0] = 32'h400100b7; // lui  x1,0x40010
        dut.u_cpu.IMEM.memory[1] = 32'h0000a183; // lw   x3,0(x1)      backend never answers
        dut.u_cpu.IMEM.memory[2] = 32'h10000237; // lui  x4,0x10000
        dut.u_cpu.IMEM.memory[3] = 32'h00100113; // addi x2,x0,1
        dut.u_cpu.IMEM.memory[4] = 32'h00222023; // sw   x2,0(x4)
        dut.u_cpu.IMEM.memory[5] = 32'h0000006f; // j    .
        force dut.g_ext_ram.u_ext_mem.arb_mem_read  = 1'b0;
        force dut.g_ext_ram.u_ext_mem.arb_mem_write = 1'b0;
        rst_n = 1;
        wait_sentinel(TIMEOUT + 500);
        ck(t < TIMEOUT + 500, "nonresponding backend: CPU continues after the timeout (no hang)");
        ck(r_slverr == 1 && completions == 1, "one SLVERR completion for the stuck read");
        ck(dut.u_interconnect.EXT_RAM_ARB.orphan === 1'b1, "stuck backend request kept as orphan");
        rst_n = 0; repeat (5) @(negedge clk);
        release dut.g_ext_ram.u_ext_mem.arb_mem_read;
        release dut.g_ext_ram.u_ext_mem.arb_mem_write;
        ck(!dut.bus_ready && !dut.axi_rvalid && !dut.ext_ram_ready && dut.u_interconnect.EXT_RAM_ARB.active == 0 &&
           !dut.u_interconnect.EXT_RAM_ARB.orphan && !bus_error, "reset aborts the stuck request and clears BUSERR");
        $display("INFO part3: stuck backend, CPU progressed after %0d clk", t);

        $display("Checks: %0d, errors: %0d, USE_CACHE=%0d", checks, errors, USE_CACHE);
        if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED");
        $finish;
    end
endmodule
