`ifndef SOC_PKG_VH
`define SOC_PKG_VH

//---------------------------------------------------------
// soc_pkg.vh
// Dựa trên rtl/packages/sos_pkg.vh của tiny-riscv-soc (MIT; file gốc bị
// đặt nhầm tên "sos", mọi file RTL đều include "soc_pkg.vh").
// riscv-soc-fir-hls: chỉ giữ các slave đang dùng (Timer, Interrupt, FIR).
// Các vùng RAM bus/GPIO/UART/SPI/I2C/DMA của bản gốc đã bỏ; địa chỉ của
// chúng giờ là địa chỉ không map (ghi bị bỏ qua, đọc ra 0).
// Mã SEL_* và địa chỉ của các slave còn lại giữ nguyên như bản gốc.
//---------------------------------------------------------

//---------------------------------------------------------
// Global Parameters
//---------------------------------------------------------

`define DATA_WIDTH 32
`define ADDR_WIDTH 32

//---------------------------------------------------------
// AXI Response Codes
//---------------------------------------------------------

`define AXI_RESP_OKAY    2'b00
`define AXI_RESP_SLVERR  2'b10
`define AXI_RESP_DECERR  2'b11   // A1: địa chỉ không map

//---------------------------------------------------------
// Peripheral Select Encoding (slave_id of axi_address_decoder)
//---------------------------------------------------------

`define SEL_NONE        4'd0
`define SEL_TIMER       4'd3
`define SEL_INTERRUPT   4'd8
`define SEL_FIR         4'd9
`define SEL_EXT_RAM     4'd10   // mã còn trống; không dùng lại SEL_RAM=1 của bản gốc (RAM bus 64 byte khác)

//---------------------------------------------------------
// Memory Map (bus address; CPU sees 0x4000_0000 + bus address)
//---------------------------------------------------------
// 0x000 - 0x07F : (không map)  - bản gốc: RAM bus, GPIO
// 0x080 - 0x0BF : TIMER
// 0x0C0 - 0x1BF : (không map)  - bản gốc: UART, SPI, I2C, DMA
// 0x1C0 - 0x1FF : INTERRUPT CONTROLLER
// 0x200 - 0x23F : FIR (thêm mới)
// 0x0001_0000 - 0x0001_FFFF : RAM dữ liệu ngoài 64 KB (mở rộng, chỉ khi
//                 soc_top.ENABLE_EXT_RAM = 1; khi = 0 vùng này không map)
//---------------------------------------------------------

// TIMER
`define TIMER_BASE       32'h0000_0080
`define TIMER_END        32'h0000_00BF
// Timer registers (offset, addr[5:2]; see rtl/Peripherals/timer.v)
//   0x00 LEGACY one-shot (unchanged; 0x10-0x3C remain aliases of LEGACY)
//   0x04 PERIOD   0x08 CTRL (bit0 ENABLE, bit1 PERIODIC, bit2 PERIOD_INVALID RO)
//   0x0C TICK_COUNT (RO)
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
// Base căn theo 64 KB; offset backend = địa chỉ bus - EXT_RAM_BASE.
`define EXT_RAM_BASE     32'h0001_0000
`define EXT_RAM_END      32'h0001_FFFF

`endif
