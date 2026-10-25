`timescale 1ns/1ps
`default_nettype none
// Configuration A: the original g_no_ext_ram tie-offs, no RAM instance.
module bd_ram_disabled (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK CLK", X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK, ASSOCIATED_BUSIF S_RAM, ASSOCIATED_RESET rst_n, FREQ_HZ 100000000" *)
    input wire clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST", X_INTERFACE_PARAMETER = "XIL_INTERFACENAME rst_n, POLARITY ACTIVE_LOW" *)
    input wire rst_n,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 S_RAM READ", X_INTERFACE_MODE = "slave" *)
    input  wire s_read,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 S_RAM WRITE" *)
    input  wire s_write,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 S_RAM ADDR" *)
    input  wire [31:0] s_addr,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 S_RAM WDATA" *)
    input  wire [31:0] s_wdata,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 S_RAM RDATA" *)
    output wire [31:0] s_rdata,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 S_RAM READY" *)
    output wire s_ready
);
    assign s_rdata = 32'd0;
    assign s_ready = 1'b0;
endmodule
`default_nettype wire
