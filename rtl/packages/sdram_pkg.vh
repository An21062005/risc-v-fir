`ifndef SDRAM_PKG_VH
`define SDRAM_PKG_VH

// Tham số SDRAM; nguồn tiny-riscv-soc (MIT, (c) 2026 Leela Shanmukh Yagneek Patnala).

// Tham số SDRAM; nguồn tiny-riscv-soc (MIT, (c) 2026 Leela Shanmukh Yagneek Patnala).

`define SDRAM_ADDR_WIDTH      13
`define SDRAM_BANK_WIDTH      2
`define SDRAM_DATA_WIDTH      16
`define SDRAM_DQM_WIDTH       2

// Memory Geometry

`define SDRAM_BANKS           4
`define SDRAM_ROWS            8192
`define SDRAM_COLUMNS         512

// CAS Latency

`define CAS_LATENCY           3

// Burst Length

`define BURST_LENGTH          4

// SDRAM Commands

`define CMD_LOAD_MODE         4'b0000
`define CMD_AUTO_REFRESH      4'b0001
`define CMD_PRECHARGE         4'b0010
`define CMD_ACTIVE            4'b0011
`define CMD_WRITE             4'b0100
`define CMD_READ              4'b0101
`define CMD_BURST_STOP        4'b0110
`define CMD_NOP               4'b0111

// Timing Parameters

`define tRP                  3
`define tRCD                 3
`define tRFC                 7
`define tMRD                 2
`define tWR                  2
`define tRAS                 6
`define tRC                  9

// Refresh

`define REFRESH_PERIOD        780

// FSM States

`define SDRAM_RESET           4'd0
`define SDRAM_INIT            4'd1
`define SDRAM_PRECHARGE       4'd2
`define SDRAM_REFRESH1        4'd3
`define SDRAM_REFRESH2        4'd4
`define SDRAM_MODE            4'd5
`define SDRAM_IDLE            4'd6
`define SDRAM_ACTIVATE        4'd7
`define SDRAM_READ            4'd8
`define SDRAM_WRITE           4'd9
`define SDRAM_PRECHARGE_ROW   4'd10
`define SDRAM_WAIT            4'd11

`endif