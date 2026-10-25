`timescale 1ns/1ps
`default_nettype none
`include "interrupt_pkg.vh"
// Wiring-only Block Design adapter. Functional RTL remains in rtl/.
module bd_interrupt (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 CLK CLK", X_INTERFACE_PARAMETER = "XIL_INTERFACENAME CLK, ASSOCIATED_BUSIF S_MMIO:S_BUSERR, ASSOCIATED_RESET rst_n, FREQ_HZ 100000000" *)
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
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_buserr:1.0 S_BUSERR VALID", X_INTERFACE_MODE = "slave" *)
    input  wire err_valid,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_buserr:1.0 S_BUSERR WRITE" *)
    input  wire err_write,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_buserr:1.0 S_BUSERR RESP" *)
    input  wire [1:0] err_resp,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_buserr:1.0 S_BUSERR ADDR" *)
    input  wire [31:0] err_addr,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_buserr:1.0 S_BUSERR OVERFLOW" *)
    input  wire err_overflow,
    (* X_INTERFACE_INFO = "riscv-soc.local:interface:soc_buserr:1.0 S_BUSERR CLR" *)
    output wire err_clr,
    input  wire timer_irq,
    input  wire fir_irq,
    output wire cpu_irq
);
    wire [`NUM_INTERRUPTS-1:0] irq_enable, irq_pending;
    wire [`INT_ID_WIDTH-1:0] irq_id, irq_ack_id;
    wire irq_ack, irq_claim;
    interrupt_axi_wrapper u_int_regs (
        .clk(clk),
        .rst_n(rst_n),
        .wr_en(s_wr_en),
        .rd_en(s_rd_en),
        .wr_addr(s_wr_addr),
        .rd_addr(s_rd_addr),
        .wdata(s_wdata),
        .rdata(s_rdata),
        .irq_enable(irq_enable),
        .ack(irq_ack),
        .ack_id(irq_ack_id),
        .status_rd(irq_claim),
        .pending(irq_pending),
        .interrupt(cpu_irq),
        .interrupt_id(irq_id),
        .buserr_valid(err_valid),
        .buserr_write(err_write),
        .buserr_resp(err_resp),
        .buserr_addr(err_addr),
        .buserr_overflow(err_overflow),
        .buserr_clr(err_clr)
    );
    interrupt_controller u_int_ctrl (
        .clk(clk),
        .rst(~rst_n),
        .irq_in({fir_irq, timer_irq}),
        .irq_enable(irq_enable),
        .ack(irq_ack),
        .ack_id(irq_ack_id),
        .claim(irq_claim),
        .pending(irq_pending),
        .interrupt(cpu_irq),
        .interrupt_id(irq_id)
    );
endmodule
`default_nettype wire
