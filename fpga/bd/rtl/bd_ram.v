`timescale 1ns/1ps
`default_nettype none
// Wiring-only Block Design adapter. Functional RTL remains in rtl/.
module bd_ram #(parameter USE_CACHE = 0) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK CLK", X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK, ASSOCIATED_BUSIF S_RAM, ASSOCIATED_RESET rst_n, FREQ_HZ 100000000" *)
    input  wire clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST", X_INTERFACE_PARAMETER = "XIL_INTERFACENAME rst_n, POLARITY ACTIVE_LOW" *)
    input  wire rst_n,
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
    cache_top #(.USE_CACHE(USE_CACHE)) u_ext_mem (
        .clk(clk),
        .rst(~rst_n),
        .cpu_read(s_read),
        .cpu_write(s_write),
        .cpu_addr(s_addr),
        .cpu_wdata(s_wdata),
        .cpu_rdata(s_rdata),
        .cpu_ready(s_ready)
    );
endmodule
`default_nettype wire
