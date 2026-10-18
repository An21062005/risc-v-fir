`ifndef INTERRUPT_PKG_VH
`define INTERRUPT_PKG_VH

//------------------------------------------------------------
// Interrupt Sources (Rút gọn còn 2 nguồn: Timer và FIR)
//------------------------------------------------------------

`define NUM_INTERRUPTS     2
`define INT_ID_WIDTH       3

`define IRQ_TIMER          0
`define IRQ_FIR            1

//------------------------------------------------------------
// Register Map (Offsets từ địa chỉ cơ sở INTERRUPT_BASE = 0x1C0)
//------------------------------------------------------------
// 0x1C0 (Offset 0x00): REG_ENABLE  (R/W) - bit[`NUM_INTERRUPTS-1:0] cho phép ngắt
// 0x1C4 (Offset 0x04): REG_PENDING (RO)  - bit[`NUM_INTERRUPTS-1:0] cờ ngắt đang chờ
// 0x1C8 (Offset 0x08): REG_ACK     (WO)  - bit[0] = 1: tạo xung xóa ngắt (ack pulse),
//                                          bit[3:1] = số hiệu nguồn cần xóa (cùng định dạng STATUS)
// 0x1CC (Offset 0x0C): REG_STATUS  (RO)  - bit[0]: có ngắt; bit[3:1]: số hiệu ngắt đang phục vụ
//------------------------------------------------------------

`define INT_ENABLE_REG     8'h00   // R/W : bit[1:0] = irq_enable
`define INT_PENDING_REG    8'h04   // RO  : bit[1:0] = pending
`define INT_ACK_REG        8'h08   // WO  : bit0 = ack (xung 1 chu kỳ), bit[3:1] = ack_id
`define INT_STATUS_REG     8'h0C   // RO  : bit0 = interrupt, bit[3:1] = interrupt_id

`endif
