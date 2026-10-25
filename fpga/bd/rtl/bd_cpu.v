`timescale 1ns/1ps
`default_nettype none
// Wiring-only Block Design adapter. Functional RTL remains in rtl/.
module bd_cpu (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK CLK", X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK, ASSOCIATED_BUSIF M_CPU, ASSOCIATED_RESET rst_n, FREQ_HZ 100000000" *)
    input  wire clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST", X_INTERFACE_PARAMETER = "XIL_INTERFACENAME rst_n, POLARITY ACTIVE_LOW" *)
    input  wire rst_n,
    input  wire irq,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 M_CPU READ", X_INTERFACE_MODE = "master" *)
    output wire m_read,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 M_CPU WRITE" *)
    output wire m_write,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 M_CPU ADDR" *)
    output wire [31:0] m_addr,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 M_CPU WDATA" *)
    output wire [31:0] m_wdata,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 M_CPU RDATA" *)
    input  wire [31:0] m_rdata,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 M_CPU READY" *)
    input  wire m_ready
);
    rvcore32_pipeline_soc u_cpu (
        .clk(clk),
        .rst(~rst_n),
        .irq(irq),
        .bus_rd(m_read),
        .bus_wr(m_write),
        .bus_addr(m_addr),
        .bus_wdata(m_wdata),
        .bus_rdata(m_rdata),
        .bus_ready(m_ready)
    );
endmodule
`default_nettype wire
