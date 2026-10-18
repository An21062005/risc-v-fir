`ifndef CACHE_PKG_VH
`define CACHE_PKG_VH

// Bản sao từ tiny-riscv-soc/rtl/packages/cache_pkg.vh (MIT, (c) 2026 Leela
// Shanmukh Yagneek Patnala, xem tiny-riscv-soc/LICENCE).
// Thay đổi trong riscv-soc-fir-hls: bỏ `define ADDR_WIDTH/DATA_WIDTH (đã có
// trong soc_pkg.vh cùng giá trị 32; tránh định nghĩa lại macro).

//------------------------------------------------------------
// Cache Configuration
//------------------------------------------------------------

// Total cache size = 1 KB
`define CACHE_SIZE_BYTES      1024

// Cache line size = 16 Bytes (4 words)
`define CACHE_LINE_BYTES      16

// Word size
`define WORD_SIZE_BYTES       4

//------------------------------------------------------------
// Derived Parameters
//------------------------------------------------------------

// Number of cache lines = 64
`define CACHE_LINES           64

// ADDR_WIDTH / DATA_WIDTH: xem soc_pkg.vh

//------------------------------------------------------------
// Address Fields
//------------------------------------------------------------

// Byte offset (16 Bytes → 4 bits)
`define OFFSET_BITS           4

// Cache index (64 lines → 6 bits)
`define INDEX_BITS            6

// Remaining bits are tag
`define TAG_BITS              22

//------------------------------------------------------------
// Cache FSM States
//------------------------------------------------------------

`define CACHE_IDLE            3'd0
`define CACHE_LOOKUP          3'd1
`define CACHE_MISS            3'd2
`define CACHE_REFILL_REQ      3'd3
`define CACHE_REFILL_WAIT     3'd4
`define CACHE_COMPLETE        3'd5

//------------------------------------------------------------
// Cache Line Status
//------------------------------------------------------------

`define VALID_BIT             1'b1
`define INVALID_BIT           1'b0

`endif