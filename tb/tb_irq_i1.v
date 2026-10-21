`timescale 1ns/1ps
`include "interrupt_pkg.vh"

//======================================================================
// tb_irq_i1 : I1 - FIR IRQ vs. new DATA_IN sent before the old ACK
//======================================================================
// Real fir11_wrapper + interrupt_axi_wrapper + interrupt_controller, wired
// as in soc_top (irq_in = {fir_irq, timer_irq}, timer_irq = 0), driven at
// the peripheral bus pins (wr_en/rd_en one-cycle pulses).
//
// Sequence per case (FIR enabled in ENABLE):
//   DATA_IN #1 -> done #1 -> pending[1] = 1   (old, not yet ACKed)
//   DATA_IN #2 at cycle t0 (accept clears done -> fir_irq falls)
//   ACK(FIR) written at t0 + d, d = 0..MAX_D
//   wait until done #2 and settle; done #2 is a NEW, unserviced event.
// Specification: a completion that has not been serviced must stay pending
// (pending[1] = 1). Lost = pending[1] == 0 while fir_irq (done_q) == 1:
// the level stays high, so no later rising edge can ever re-arm pending.
// Reference case (current firmware order): ACK first, then DATA_IN.
// Scenario P (no duplicate): done #1 pending, software consumes it by polling
// (DATA_OUT read, no ACK), sends DATA_IN #2; done #2 is then serviced by an ISR
// (STATUS, ACK, DATA_OUT). Exactly one service -> pending must end at 0.
// Each ISR-like sequence reads STATUS first (as irq_handler does).
//======================================================================

module tb_irq_i1;
    parameter MAX_D = 40;

    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg         fir_wr = 0, fir_rd = 0, int_wr = 0, int_rd = 0;
    reg  [31:0] addr = 0, wdata = 0, iaddr = 0, iwdata = 0;
    wire [31:0] fir_rdata, int_rdata;
    wire        fir_irq;

    wire [1:0] irq_in = {fir_irq, 1'b0};
    wire [1:0] irq_enable, pending;
    wire       ack, interrupt;
    wire [`INT_ID_WIDTH-1:0] ack_id, irq_id;
    wire claim;   // STATUS read (claim), interrupt_axi_wrapper -> controller

    fir11_wrapper u_fir (.clk(clk), .rst_n(rst_n), .wr_en(fir_wr), .rd_en(fir_rd),
        .wr_addr(addr), .rd_addr(addr), .wdata(wdata), .rdata(fir_rdata), .irq(fir_irq));
    interrupt_axi_wrapper u_regs (.clk(clk), .rst_n(rst_n), .wr_en(int_wr), .rd_en(int_rd),
        .wr_addr(iaddr), .rd_addr(iaddr), .wdata(iwdata), .rdata(int_rdata),
        .irq_enable(irq_enable), .ack(ack), .ack_id(ack_id),
        .status_rd(claim),
        .pending(pending), .interrupt(interrupt), .interrupt_id(irq_id),
        .buserr_valid(1'b0), .buserr_write(1'b0), .buserr_resp(2'b00), .buserr_overflow(1'b0),
        .buserr_addr(32'd0), .buserr_clr());
    interrupt_controller u_ctrl (.clk(clk), .rst(~rst_n), .irq_in(irq_in), .claim(claim),
        .irq_enable(irq_enable), .ack(ack), .ack_id(ack_id),
        .pending(pending), .interrupt(interrupt), .interrupt_id(irq_id));

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    // cycle of every FIR irq rising edge / ACK pulse seen by the controller
    integer edge_cyc = -1, ack_cyc = -1, edges = 0;
    always @(posedge clk) begin
        if (rst_n && fir_irq && !u_ctrl.irq_in_d[1]) begin edge_cyc = cyc; edges = edges + 1; end
        if (rst_n && ack && ack_id == 1) ack_cyc = cyc;
    end

    task wr_fir; input [31:0] a, d;
        begin @(negedge clk); fir_wr = 1; addr = a; wdata = d; @(negedge clk); fir_wr = 0; end
    endtask
    task wr_int; input [31:0] a, d;
        begin @(negedge clk); int_wr = 1; iaddr = a; iwdata = d; @(negedge clk); int_wr = 0; end
    endtask
    task rd_int; input [31:0] a;
        begin @(negedge clk); int_rd = 1; iaddr = a; @(negedge clk); int_rd = 0; end
    endtask
    task rd_fir; input [31:0] a;
        begin @(negedge clk); fir_rd = 1; addr = a; @(negedge clk); fir_rd = 0; end
    endtask
    task idle; input integer n; integer k; begin for (k = 0; k < n; k = k + 1) @(negedge clk); end
    endtask

    integer errors = 0, checks = 0, d, lost = 0, kept = 0, first_lost = -1, last_lost = -1;
    integer t0, e2;

    task reset_and_arm;
        begin
            @(negedge clk); rst_n = 0; fir_wr = 0; int_wr = 0; fir_rd = 0; int_rd = 0;
            idle(2); rst_n = 1; idle(2);
            wr_int(32'h00, 32'h2);                 // ENABLE = FIR only
            wr_fir(32'h00, 32'd5);                 // DATA_IN #1
            idle(40);                              // done #1 -> pending[1]
        end
    endtask

    initial begin
        // ---------------- Reference: ACK before DATA_IN (current firmware) ----
        reset_and_arm;
        checks = checks + 1;
        if (pending !== 2'b10 || fir_irq !== 1) begin
            errors = errors + 1; $display("ERROR ref: done#1 not pending (%b)", pending);
        end
        rd_int(32'h0C);                            // STATUS (ISR entry)
        wr_int(32'h08, 32'h3);                     // ACK FIR
        rd_fir(32'h04);                            // DATA_OUT #1
        wr_fir(32'h00, 32'd7);                     // DATA_IN #2
        idle(40);
        checks = checks + 1;
        if (pending[1] !== 1 || fir_irq !== 1) begin
            errors = errors + 1; $display("ERROR ref ACK-then-DATA_IN: pending=%b fir_irq=%b", pending, fir_irq);
        end else
            $display("INFO ref ACK->DATA_IN: done#2 pending=%b fir_irq=%b  OK", pending, fir_irq);

        // ---------------- Sweep: DATA_IN #2 at t0, ACK at t0 + d ----------------
        for (d = 0; d <= MAX_D; d = d + 1) begin
            reset_and_arm;
            rd_int(32'h0C);                        // ISR: STATUS (claims FIR)
            edge_cyc = -1; ack_cyc = -1;
            @(negedge clk); fir_wr = 1; addr = 32'h00; wdata = 32'd7; t0 = cyc;  // accept at edge t0
            if (d == 0) begin int_wr = 1; iaddr = 32'h08; iwdata = 32'h3; end                                     // same bus cycle (TB only)
            @(negedge clk); fir_wr = 0; int_wr = 0;
            if (d > 0) begin
                idle(d - 1);
                @(negedge clk); int_wr = 1; iaddr = 32'h08; iwdata = 32'h3;
                @(negedge clk); int_wr = 0;
            end
            idle(60);
            checks = checks + 1;
            if (pending[1] === 1'b1) kept = kept + 1;
            else begin
                lost = lost + 1;
                if (first_lost < 0) first_lost = d;
                last_lost = d;
                if (fir_irq === 1'b1 && u_fir.done_q === 1'b1)
                    $display("FAIL I1 d=%0d: done#2 edge @%0d (t0+%0d), ACK pulse @%0d (t0+%0d) -> pending[1]=0, fir_irq=1 (stuck high, no new edge possible)",
                             d, edge_cyc, edge_cyc - t0, ack_cyc, ack_cyc - t0);
            end
        end
        // ---------------- Scenario P: polling consumption, then ISR for done #2 ----
        reset_and_arm;                              // done #1 pending, not ACKed
        rd_fir(32'h04);                             // poll: DATA_OUT #1 (done falls)
        wr_fir(32'h00, 32'd9);                      // DATA_IN #2
        idle(40);                                   // done #2 (pending still 1)
        rd_int(32'h0C);                             // ISR: STATUS
        wr_int(32'h08, 32'h3);                      // ACK FIR
        rd_fir(32'h04);                             // DATA_OUT #2
        idle(5);
        checks = checks + 1;
        if (pending[1] !== 1'b0) begin
            errors = errors + 1;
            $display("FAIL P: done #2 already serviced (STATUS, ACK, DATA_OUT) but pending[1]=%b -> duplicate ISR", pending[1]);
        end else
            $display("INFO P polling-consumed #1, ISR serviced #2: pending=%b fir_irq=%b  OK (no duplicate)", pending, fir_irq);

        $display("INFO I1 sweep d=0..%0d: kept=%0d lost=%0d (lost for d=%0d..%0d)",
                 MAX_D, kept, lost, first_lost, last_lost);
        if (lost != 0) errors = errors + lost;
        $display("Checks: %0d, errors: %0d", checks, errors);
        if (errors == 0) $display("TEST PASSED"); else $display("TEST FAILED");
        $finish;
    end
endmodule
