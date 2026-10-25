`timescale 1ns/1ps
`default_nettype none
// Wiring-only Block Design adapter. Functional RTL remains in rtl/.
module bd_interconnect #(parameter ENABLE_EXT_RAM = 0, parameter EXT_RAM_TIMEOUT = 1024) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK CLK", X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK, ASSOCIATED_BUSIF S_AXI:M_TIMER:M_FIR:M_IRQ:M_RAM, ASSOCIATED_RESET rst_n, FREQ_HZ 100000000" *)
    input  wire clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST", X_INTERFACE_PARAMETER = "XIL_INTERFACENAME rst_n, POLARITY ACTIVE_LOW" *)
    input  wire rst_n,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWADDR", X_INTERFACE_MODE = "slave", X_INTERFACE_PARAMETER = "XIL_INTERFACENAME S_AXI, PROTOCOL AXI4LITE, ADDR_WIDTH 32, DATA_WIDTH 32, HAS_BURST 0, HAS_LOCK 0, SUPPORTS_NARROW_BURST 0" *)
    input  wire [31:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWVALID" *)
    input  wire s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI AWREADY" *)
    output wire s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WDATA" *)
    input  wire [31:0] s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WSTRB" *)
    input  wire [3:0] s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WVALID" *)
    input  wire s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI WREADY" *)
    output wire s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BRESP" *)
    output wire [1:0] s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BVALID" *)
    output wire s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI BREADY" *)
    input  wire s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARADDR" *)
    input  wire [31:0] s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARVALID" *)
    input  wire s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI ARREADY" *)
    output wire s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RDATA" *)
    output wire [31:0] s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RRESP" *)
    output wire [1:0] s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RVALID" *)
    output wire s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 S_AXI RREADY" *)
    input  wire s_axi_rready,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 M_TIMER WR_EN", X_INTERFACE_MODE = "master" *)
    output wire timer_wr_en,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 M_TIMER RD_EN" *)
    output wire timer_rd_en,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 M_TIMER WR_ADDR" *)
    output wire [31:0] timer_wr_addr,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 M_TIMER RD_ADDR" *)
    output wire [31:0] timer_rd_addr,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 M_TIMER WDATA" *)
    output wire [31:0] timer_wdata,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 M_TIMER RDATA" *)
    input  wire [31:0] timer_rdata,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 M_FIR WR_EN", X_INTERFACE_MODE = "master" *)
    output wire fir_wr_en,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 M_FIR RD_EN" *)
    output wire fir_rd_en,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 M_FIR WR_ADDR" *)
    output wire [31:0] fir_wr_addr,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 M_FIR RD_ADDR" *)
    output wire [31:0] fir_rd_addr,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 M_FIR WDATA" *)
    output wire [31:0] fir_wdata,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 M_FIR RDATA" *)
    input  wire [31:0] fir_rdata,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 M_IRQ WR_EN", X_INTERFACE_MODE = "master" *)
    output wire irq_wr_en,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 M_IRQ RD_EN" *)
    output wire irq_rd_en,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 M_IRQ WR_ADDR" *)
    output wire [31:0] irq_wr_addr,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 M_IRQ RD_ADDR" *)
    output wire [31:0] irq_rd_addr,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 M_IRQ WDATA" *)
    output wire [31:0] irq_wdata,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mmio:1.0 M_IRQ RDATA" *)
    input  wire [31:0] irq_rdata,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 M_RAM READ", X_INTERFACE_MODE = "master" *)
    output wire ram_read,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 M_RAM WRITE" *)
    output wire ram_write,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 M_RAM ADDR" *)
    output wire [31:0] ram_addr,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 M_RAM WDATA" *)
    output wire [31:0] ram_wdata,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 M_RAM RDATA" *)
    input  wire [31:0] ram_rdata,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 M_RAM READY" *)
    input  wire ram_ready
);
    wire [31:0] write_addr, read_addr, write_data;
    assign timer_wr_addr = write_addr;
    assign timer_rd_addr = read_addr;
    assign timer_wdata = write_data;
    assign fir_wr_addr = write_addr;
    assign fir_rd_addr = read_addr;
    assign fir_wdata = write_data;
    assign irq_wr_addr = write_addr;
    assign irq_rd_addr = read_addr;
    assign irq_wdata = write_data;
    axi_interconnect #(.ENABLE_EXT_RAM(ENABLE_EXT_RAM), .EXT_RAM_TIMEOUT(EXT_RAM_TIMEOUT)) u_interconnect (
        .clk(clk),
        .rst_n(rst_n),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .timer_wr_en(timer_wr_en),
        .timer_rd_en(timer_rd_en),
        .timer_rdata(timer_rdata),
        .fir_wr_en(fir_wr_en),
        .fir_rd_en(fir_rd_en),
        .fir_rdata(fir_rdata),
        .interrupt_wr_en(irq_wr_en),
        .interrupt_rd_en(irq_rd_en),
        .interrupt_rdata(irq_rdata),
        .write_addr(write_addr),
        .read_addr(read_addr),
        .write_data(write_data),
        .ext_ram_read(ram_read),
        .ext_ram_write(ram_write),
        .ext_ram_addr(ram_addr),
        .ext_ram_wdata(ram_wdata),
        .ext_ram_rdata(ram_rdata),
        .ext_ram_ready(ram_ready)
    );
endmodule
`default_nettype wire
