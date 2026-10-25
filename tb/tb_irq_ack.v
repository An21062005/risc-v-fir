`timescale 1ns/1ps
`include "interrupt_pkg.vh"

// Pin-level edge/ACK boundary verification, using the real controller.
module tb_irq_ack;
    reg clk=0, rst=1, ack=0;
    reg [1:0] raw=0, en=3;
    reg [`INT_ID_WIDTH-1:0] id=0;
    wire [1:0] pending;
    wire interrupt;
    wire [`INT_ID_WIDTH-1:0] winner;
    always #5 clk=~clk;
    interrupt_controller dut(.clk(clk), .rst(rst), .irq_in(raw), .irq_enable(en), .claim(1'b0),
        .ack(ack), .ack_id(id), .pending(pending), .interrupt(interrupt), .interrupt_id(winner));
    integer errors=0, checks=0, source, target, delta, preload, k, cases=0;
    reg [1:0] expected, prior;
    // Independent specification: a new edge survives a simultaneous ACK;
    task step;
        input [1:0] pulse;
        input do_ack;
        input integer ack_source;
        begin
            @(negedge clk); raw=pulse; ack=do_ack; id=ack_source;
            expected = (expected & ~(do_ack ? (2'b01 << ack_source) : 2'b00)) | (pulse & ~prior);
            prior=pulse;
            @(posedge clk); #1;
            checks=checks+1;
            if (pending !== expected || interrupt !== (|(expected & en)) ||
                ((|(expected & en)) && winner !== ((expected[0] && en[0]) ? 0 : 1))) begin
                errors=errors+1;
                $display("ERROR pending/priority source=%0d ACK=%0d offset=%0d got=%b expected=%b",
                         source,target,delta,pending,expected);
            end
        end
    endtask
    initial begin
        for (preload=0; preload<4; preload=preload+1)
        for (source=0; source<2; source=source+1)
        for (target=0; target<2; target=target+1)
        for (delta=-1; delta<=1; delta=delta+1) begin
            @(negedge clk); rst=1; raw=0; ack=0;
            @(negedge clk); rst=0; expected=0; prior=0;
            step(preload,0,0); step(0,0,0);
            for(k=-1;k<=1;k=k+1) step(k==delta ? (2'b01<<source) : 0,k==0,target);
            step(0,0,0); step(0,1,0); step(0,1,1); step(0,0,0);
            cases=cases+1;
        end
        // Simultaneous Timer/FIR edges at ACK and repeated coalesced Timer pulses.
        step(3,1,0); step(0,0,0); step(1,0,0); step(0,0,0);
        step(1,0,0); step(0,1,0); step(0,1,1);
        $display("INFO IRQ/ACK: %0d directed source/target/pending/offset cases plus simultaneous/coalesced edges",cases);
        $display("Checks: %0d, errors: %0d",checks,errors);
        if(errors==0) $display("TEST PASSED"); else $display("TEST FAILED");
        $finish;
    end
endmodule
