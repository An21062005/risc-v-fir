`timescale 1ns/1ps
`default_nettype none
// Wiring-only Block Design adapter. Functional RTL remains in rtl/.
module bd_reset (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK CLK", X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK, ASSOCIATED_RESET rst_n_out, FREQ_HZ 100000000" *)
    input  wire clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n_in RST", X_INTERFACE_PARAMETER = "XIL_INTERFACENAME rst_n_in, POLARITY ACTIVE_LOW" *)
    input  wire rst_n_in,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n_out RST", X_INTERFACE_PARAMETER = "XIL_INTERFACENAME rst_n_out, POLARITY ACTIVE_LOW" *)
    output wire rst_n_out
);
    reset_sync #(.STAGES(2)) u_rst_sync (
        .clk(clk),
        .rst_n_in(rst_n_in),
        .rst_n_out(rst_n_out)
    );
endmodule
`default_nettype wire
