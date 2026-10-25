`ifndef INTERRUPT_PKG_VH
`define INTERRUPT_PKG_VH

// Interrupt Sources (Rút gọn còn 2 nguồn: Timer và FIR)

`define NUM_INTERRUPTS     2
`define INT_ID_WIDTH       3

`define IRQ_TIMER          0
`define IRQ_FIR            1

// Register Map (Offsets từ địa chỉ cơ sở INTERRUPT_BASE = 0x1C0)

`define INT_ENABLE_REG     8'h00   // R/W : bit[1:0] = irq_enable
`define INT_PENDING_REG    8'h04   // RO  : bit[1:0] = pending
`define INT_ACK_REG        8'h08   // WO  : bit0 = ack (xung 1 chu kỳ), bit[3:1] = ack_id
`define INT_STATUS_REG     8'h0C   // RO  : bit0 = interrupt, bit[3:1] = interrupt_id
`define INT_BUSERR_REG     8'h10   // R/W1C: bit0 valid, bit1 write, bit[3:2] resp, bit4 overflow
`define INT_BUSERR_ADDR_REG 8'h14  // RO  : address of the first bus error

`endif
