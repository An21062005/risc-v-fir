`timescale 1ns/1ps
`default_nettype none
// Wiring-only Block Design adapter. Functional RTL remains in rtl/.
module bd_fir (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK CLK", X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK, ASSOCIATED_BUSIF S_MMIO, ASSOCIATED_RESET rst_n, FREQ_HZ 100000000" *)
    input  wire clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST", X_INTERFACE_PARAMETER = "XIL_INTERFACENAME rst_n, POLARITY ACTIVE_LOW" *)
    input  wire rst_n,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 S_MMIO WR_EN", X_INTERFACE_MODE = "slave" *)
    input  wire s_wr_en,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 S_MMIO RD_EN" *)
    input  wire s_rd_en,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 S_MMIO WR_ADDR" *)
    input  wire [31:0] s_wr_addr,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 S_MMIO RD_ADDR" *)
    input  wire [31:0] s_rd_addr,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 S_MMIO WDATA" *)
    input  wire [31:0] s_wdata,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 S_MMIO RDATA" *)
    output wire [31:0] s_rdata,
    output wire irq
);
    fir11_wrapper u_fir (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(s_wr_en),
        .rd_en(s_rd_en),
        .wr_addr(s_wr_addr),
        .rd_addr(s_rd_addr),
        .wdata(s_wdata),
        .rdata(s_rdata),
        .irq(irq)
    );
endmodule
`default_nettype wire
