`timescale 1ns/1ps

// Reset assert bất đồng bộ, release đồng bộ sau STAGES cạnh clock.

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
