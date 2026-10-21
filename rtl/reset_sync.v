`timescale 1ns/1ps

//======================================================================
// reset_sync : reset synchronizer (S1)
//======================================================================
// Asynchronous assert, synchronous release: rst_n_out goes low as soon as
// rst_n_in goes low (no clock needed, like the original direct reset), and
// goes high only STAGES rising clk edges after rst_n_in is released, aligned
// to clk. Every flop in the SoC thus leaves reset on the same edge, outside
// the release-time (recovery/removal) window of an asynchronous pin.
// ASYNC_REG keeps the chain together and tells Vivado it is a synchronizer.
//======================================================================

module reset_sync #(
    parameter STAGES = 2
) (
    input  wire clk,
    input  wire rst_n_in,     // asynchronous, active low (board pin / testbench)
    output wire rst_n_out     // asynchronous assert, synchronous release
);

    (* ASYNC_REG = "TRUE" *) reg [STAGES-1:0] sync;

    always @(posedge clk or negedge rst_n_in) begin
        if (!rst_n_in)
            sync <= {STAGES{1'b0}};
        else
            sync <= {sync[STAGES-2:0], 1'b1};
    end

    assign rst_n_out = sync[STAGES-1];

endmodule
