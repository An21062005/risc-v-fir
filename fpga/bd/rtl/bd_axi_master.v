`timescale 1ns/1ps
`default_nettype none
// Wiring-only Block Design adapter. Functional RTL remains in rtl/.
module bd_axi_master (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK CLK", X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK, ASSOCIATED_BUSIF S_CPU:M_AXI:M_BUSERR, ASSOCIATED_RESET rst_n, FREQ_HZ 100000000" *)
    input  wire clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST", X_INTERFACE_PARAMETER = "XIL_INTERFACENAME rst_n, POLARITY ACTIVE_LOW" *)
    input  wire rst_n,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 S_CPU READ", X_INTERFACE_MODE = "slave" *)
    input  wire s_read,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 S_CPU WRITE" *)
    input  wire s_write,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 S_CPU ADDR" *)
    input  wire [31:0] s_addr,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 S_CPU WDATA" *)
    input  wire [31:0] s_wdata,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 S_CPU RDATA" *)
    output wire [31:0] s_rdata,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_mem:1.0 S_CPU READY" *)
    output wire s_ready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWADDR", X_INTERFACE_MODE = "master", X_INTERFACE_PARAMETER = "XIL_INTERFACENAME M_AXI, PROTOCOL AXI4LITE, ADDR_WIDTH 32, DATA_WIDTH 32, HAS_BURST 0, HAS_LOCK 0, SUPPORTS_NARROW_BURST 0" *)
    output wire [31:0] m_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWVALID" *)
    output wire m_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI AWREADY" *)
    input  wire m_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WDATA" *)
    output wire [31:0] m_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WSTRB" *)
    output wire [3:0] m_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WVALID" *)
    output wire m_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI WREADY" *)
    input  wire m_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BRESP" *)
    input  wire [1:0] m_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BVALID" *)
    input  wire m_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI BREADY" *)
    output wire m_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARADDR" *)
    output wire [31:0] m_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARVALID" *)
    output wire m_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI ARREADY" *)
    input  wire m_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RDATA" *)
    input  wire [31:0] m_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RRESP" *)
    input  wire [1:0] m_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RVALID" *)
    input  wire m_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 M_AXI RREADY" *)
    output wire m_axi_rready,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_buserr:1.0 M_BUSERR VALID", X_INTERFACE_MODE = "master" *)
    output wire err_valid,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_buserr:1.0 M_BUSERR WRITE" *)
    output wire err_write,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_buserr:1.0 M_BUSERR RESP" *)
    output wire [1:0] err_resp,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_buserr:1.0 M_BUSERR ADDR" *)
    output wire [31:0] err_addr,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_buserr:1.0 M_BUSERR OVERFLOW" *)
    output wire err_overflow,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_buserr:1.0 M_BUSERR CLR" *)
    input  wire err_clr,
    output wire bus_error
);
    cpu_axi_master u_axi_master (
        .clk(clk),
        .rst_n(rst_n),
        .mem_read(s_read),
        .mem_write(s_write),
        .mem_addr(s_addr),
        .mem_wdata(s_wdata),
        .mem_rdata(s_rdata),
        .mem_ready(s_ready),
        .mem_err(),
        .M_AXI_AWADDR(m_axi_awaddr),
        .M_AXI_AWVALID(m_axi_awvalid),
        .M_AXI_AWREADY(m_axi_awready),
        .M_AXI_WDATA(m_axi_wdata),
        .M_AXI_WSTRB(m_axi_wstrb),
        .M_AXI_WVALID(m_axi_wvalid),
        .M_AXI_WREADY(m_axi_wready),
        .M_AXI_BRESP(m_axi_bresp),
        .M_AXI_BVALID(m_axi_bvalid),
        .M_AXI_BREADY(m_axi_bready),
        .M_AXI_ARADDR(m_axi_araddr),
        .M_AXI_ARVALID(m_axi_arvalid),
        .M_AXI_ARREADY(m_axi_arready),
        .M_AXI_RDATA(m_axi_rdata),
        .M_AXI_RRESP(m_axi_rresp),
        .M_AXI_RVALID(m_axi_rvalid),
        .M_AXI_RREADY(m_axi_rready),
        .err_valid(err_valid),
        .err_write(err_write),
        .err_resp(err_resp),
        .err_addr(err_addr),
        .err_overflow(err_overflow),
        .err_clr(err_clr)
    );
    assign bus_error = err_valid;
endmodule
`default_nettype wire
