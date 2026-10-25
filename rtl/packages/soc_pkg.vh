`ifndef SOC_PKG_VH
`define SOC_PKG_VH

// soc_pkg.vh

// Global Parameters

`define DATA_WIDTH 32
`define ADDR_WIDTH 32

// AXI Response Codes

`define AXI_RESP_OKAY    2'b00
`define AXI_RESP_SLVERR  2'b10
`define AXI_RESP_DECERR  2'b11   // A1: địa chỉ không map

// Peripheral Select Encoding (slave_id of axi_address_decoder)

`define SEL_NONE        4'd0
`define SEL_TIMER       4'd3
`define SEL_INTERRUPT   4'd8
`define SEL_FIR         4'd9
`define SEL_EXT_RAM     4'd10   // mã còn trống; không dùng lại SEL_RAM=1 của bản gốc (RAM bus 64 byte khác)

// Memory Map (bus address; CPU sees 0x4000_0000 + bus address)

// TIMER
`define TIMER_BASE       32'h0000_0080
`define TIMER_END        32'h0000_00BF
// Timer registers (offset, addr[5:2]; see rtl/Peripherals/timer.v)
`define TIMER_LEGACY_REG 8'h00
`define TIMER_PERIOD_REG 8'h04
`define TIMER_CTRL_REG   8'h08
`define TIMER_TICK_REG   8'h0C

// Interrupt Controller
`define INTERRUPT_BASE   32'h0000_01C0
`define INTERRUPT_END    32'h0000_01FF

// FIR Filter Accelerator
`define FIR_BASE         32'h0000_0200
`define FIR_END          32'h0000_023F

// External data RAM (SDRAM mô phỏng, cache tùy chọn) - đề mục mở rộng
`define EXT_RAM_BASE     32'h0001_0000
`define EXT_RAM_END      32'h0001_FFFF

`endif
