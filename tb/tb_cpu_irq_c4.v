`timescale 1ns/1ps

// tb_cpu_irq_c4 : C4 (ACK right before MRET) + I1 replayed on the CPU

module tb_cpu_irq_c4;
    parameter MAX_K = 40;
    parameter ASM = "";   // images built by run_rtl_tests.py into the run directory
    parameter EXT_RAM = 0, USE_CACHE = 0;

    reg clk = 0, rst_n = 0;
    wire irq;
    always #5 clk = ~clk;

    soc_top #(.ENABLE_EXT_RAM(EXT_RAM), .EXT_RAM_USE_CACHE(USE_CACHE)) dut (.clk(clk), .rst_n(rst_n), .cpu_irq(irq));

    wire irq_take  = dut.u_cpu.irq_take;
    wire mret_take = dut.u_cpu.mret_take;
    wire ack       = dut.u_int_ctrl.ack;
    wire [2:0] ack_id = dut.u_int_ctrl.ack_id;
    wire int_wr    = dut.interrupt_wr_en;
    wire fir_wr    = dut.fir_wr_en;
    wire bus_ready = dut.u_cpu.bus_ready;
    wire [1:0] pending = dut.u_int_ctrl.pending;
    wire fir_irq   = dut.fir_irq;
    // irq_take permission with the irq term removed: 1 = a still-high irq WOULD be taken
    wire take_win  = ~dut.u_cpu.in_irq & ~dut.u_cpu.bus_stall & dut.u_cpu.PCWrite &
                     ~dut.u_cpu.redirect_ex & ~dut.u_cpu.ctrl_in_id;
    reg  win_at_ready, irq_at_ready;

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    integer n_take, n_mret, n_ack0, n_ack1, n_fir_done, first_take;
    integer t_firwr2, n_firwr, t_take, t_intwr, t_ready, t_mret, t_ack, t_clear, t_take2;
    reg mon = 0, prev_int = 0, prev_fir = 0, ack_store = 0;
    always @(posedge clk) if (mon) begin
        if (irq_take) begin
            n_take = n_take + 1;
            if (first_take < 0) first_take = cyc;
            if (n_take == 2) t_take2 = cyc;
        end
        if (mret_take) begin n_mret = n_mret + 1; if (t_mret < 0) t_mret = cyc; end
        if (ack && ack_id == 0) n_ack0 = n_ack0 + 1;
        if (ack && ack_id == 1) begin n_ack1 = n_ack1 + 1; if (t_ack < 0) t_ack = cyc; end
        if (int_wr && t_intwr < 0 && n_take > 0) begin t_intwr = cyc; ack_store = 1; end
        if (ack_store && bus_ready) begin t_ready = cyc; ack_store = 0; win_at_ready = take_win; irq_at_ready = irq; end
        if (t_ack >= 0 && t_clear < 0 && !irq) t_clear = cyc;
        if (fir_wr) begin n_firwr = n_firwr + 1; if (n_firwr == 2) t_firwr2 = cyc; end
        if (fir_irq && !prev_fir) n_fir_done = n_fir_done + 1;
        prev_fir = fir_irq;
    end

    integer errors = 0, checks = 0, n, k, x20, x21a, x21b;
    integer c4a_fail = 0, c4b_fail = 0, i1_lost_n = 0;
    reg [8*80-1:0] fname;

    task ck; input cond; input [8*120-1:0] msg;
        begin checks = checks + 1;
            if (cond !== 1'b1) begin errors = errors + 1; $display("ERROR %0s", msg); end
        end
    endtask

    task load_and_reset; input [8*80-1:0] f;
        integer i;
        begin
            @(negedge clk); rst_n = 0; mon = 0;
            for (i = 0; i < 256; i = i + 1) dut.u_cpu.DMEM.memory[i] = 0;
            $readmemh(f, dut.u_cpu.IMEM.memory);
            for (i = 0; i < 32; i = i + 1) dut.u_cpu.RF.registers[i] = 0;
            n_take = 0; n_mret = 0; n_ack0 = 0; n_ack1 = 0; n_fir_done = 0; first_take = -1;
            t_take = -1; t_intwr = -1; t_ready = -1; t_mret = -1; t_ack = -1; t_clear = -1; t_take2 = -1;
            ack_store = 0; prev_fir = 0; n_firwr = 0; t_firwr2 = -1;
            repeat (3) @(negedge clk);
            rst_n = 1; mon = 1;
        end
    endtask

    task wait_cycles; input integer c; begin repeat (c) @(negedge clk); end endtask

    initial begin
        //---------------- C4-A: sw ACK ; N nop ; mret -----------------------------
        for (n = 0; n <= 13; n = n + 1) begin
            if (n < 7) $sformat(fname, "%0sc4a_%0d.mem", ASM, n);
            else       $sformat(fname, "%0sc4p_%0d.mem", ASM, n - 7);
            load_and_reset(fname);
            wait_cycles(400);
            x20 = dut.u_cpu.RF.registers[20]; x21a = dut.u_cpu.RF.registers[21];
            wait_cycles(20); x21b = dut.u_cpu.RF.registers[21];
            $display("INFO C4-A N=%0d: take@%0d ACK-wr_en@%0d(+%0d) bus_ready@%0d(+%0d) mret@%0d(+%0d) ack-pulse@%0d(+%0d) irq-low@%0d(+%0d) | @bus_ready: take_win=%b irq=%b | entries=%0d mret=%0d ack1=%0d x20=%0d",
                n, first_take, t_intwr, t_intwr-first_take, t_ready, t_ready-first_take, t_mret, t_mret-first_take,
                t_ack, t_ack-first_take, t_clear, t_clear-first_take, win_at_ready, irq_at_ready, n_take, n_mret, n_ack1, x20);
            if (n_take !== 1 || n_ack1 !== 1 || x20 !== 1 || x21b == x21a || dut.u_cpu.in_irq !== 0 || pending[1] !== 0) begin
                c4a_fail = c4a_fail + 1;
                $display("FAIL C4-A N=%0d: entries=%0d (expect 1) ack1=%0d x20=%0d 2nd-take@%0d", n, n_take, n_ack1, x20, t_take2);
            end
            ck(n_take == 1 && n_ack1 == 1 && x20 == 1 && x21b != x21a, "C4-A single event");
            // C4 margin: pending/irq must be low at least one cycle before the ACK store retires
            ck(t_clear >= 0 && t_ready >= 0 && t_clear < t_ready, "C4-A irq low before ACK bus_ready (>= 1 cycle margin)");
        end

        //---------------- C4-B: lw STATUS ; sw ACK ; N nop ; mret + Timer pulse ---
        for (n = 0; n <= 6; n = n + 1)
        for (k = 0; k <= MAX_K; k = k + 1) begin
            $sformat(fname, "%0sc4b_%0d.mem", ASM, n);
            load_and_reset(fname);
            wait (first_take >= 0);
            @(negedge clk);                          // now at cycle first_take+1 (negedge)
            if (k > 0) wait_cycles(k);
            force dut.timer_irq = 1'b1; @(negedge clk); release dut.timer_irq;
            wait_cycles(400);
            x20 = dut.u_cpu.RF.registers[20];
            if (n_take !== 2 || n_ack0 !== 1 || n_ack1 !== 1 || x20 !== 2 || pending !== 2'b00 || dut.u_cpu.in_irq !== 0) begin
                c4b_fail = c4b_fail + 1;
                $display("FAIL C4-B N=%0d k=%0d: entries=%0d ack0=%0d ack1=%0d x20=%0d pending=%b", n, k, n_take, n_ack0, n_ack1, x20, pending);
            end
            ck(n_take == 2 && n_ack0 == 1 && n_ack1 == 1 && pending == 0, "C4-B two events");
        end
        $display("INFO C4-B: 7 ISR shapes x %0d Timer phases, failures=%0d", MAX_K+1, c4b_fail);

        //---------------- I1 on CPU: sw DATA_IN ; N nop ; sw ACK ; mret ----------
        for (n = 0; n <= 24; n = n + 2) if (n <= 16 || n == 20 || n == 24) begin
            $sformat(fname, "%0si1_%0d.mem", ASM, n);
            load_and_reset(fname);
            wait_cycles(3000);
            $display("INFO I1-CPU N=%0d: FIR completions=%0d ISR entries=%0d ack1=%0d pending=%b fir_irq=%b ISR DATA_IN wr_en@%0d -> 1st ACK pulse@%0d (gap %0d clk)",
                     n, n_fir_done, n_take, n_ack1, pending, fir_irq, t_firwr2, t_ack, t_ack - t_firwr2);
            // lost = stream stalled: a completion is unserviced and can no longer raise pending
            if (n_take < n_fir_done - 1 ||
                (n_take < n_fir_done && pending[1] === 1'b0 && fir_irq === 1'b1 && !dut.u_cpu.in_irq)) begin
                i1_lost_n = i1_lost_n + 1;
                $display("FAIL I1-CPU N=%0d: %0d completion(s) never serviced, stream stalled (pending=%b, fir_irq=%b, in_irq=%b)",
                         n, n_fir_done - n_take, pending, fir_irq, dut.u_cpu.in_irq);
            end
            ck(!(n_take < n_fir_done - 1 || (n_take < n_fir_done && pending[1] === 1'b0 && fir_irq === 1'b1 && !dut.u_cpu.in_irq)),
               "I1 CPU completion serviced");
        end

        $display("SUMMARY C4-A fail=%0d  C4-B fail=%0d  I1-CPU lost-configs=%0d", c4a_fail, c4b_fail, i1_lost_n);
        $display("Checks: %0d, errors: %0d", checks, errors);
        if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED");
        $finish;
    end
endmodule
