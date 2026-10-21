# Phase 5 — I1/C4, AXI errors/timeout (A1/A2), FPGA preparation (S1/S3/S4/F3) — 2026-10-21

## Changes

| ID | Defect | Fix | Files |
|---|---|---|---|
| I1 | A late ACK of an old FIR event (DATA_IN sent before ACK) cleared the pending bit of the NEW completion; `fir_irq` (= `done_q`, level) stays 1, so no edge can re-arm it: lost IRQ, stream deadlock. | `newer[i]`: edge while `pending[i]` is already 1 and after the last STATUS read (claim) of source i. ACK: `pending <= newer & irq_in`. New claim input = STATUS read pulse. | `rtl/Peripherals/Interrupt_controller.v`, `interrupt_axi_wrapper.v` (`status_rd`), `rtl/soc_top.v` |
| C4 | `sw ACK; mret` back to back: pending cleared in exactly the cycle the store's `bus_ready` releases the stall (0-cycle margin; +1 cycle of ACK latency -> duplicate ISR, shown by mutant). | ACK pulse combinational in the `wr_en` cycle (was registered). Margin 1 cycle, checked by `tb_cpu_irq_c4`. | `interrupt_axi_wrapper.v` |
| A1 | Master ignored BRESP/RRESP (failed read data went to the CPU); unmapped addresses answered OKAY. | Master: RRESP != OKAY -> data 0; first error captured (valid/write/resp/addr, overflow), `mem_err` pulse. Interconnect: unmapped -> DECERR. Software: BUSERR (0x1D0, W1C) / BUSERR_ADDR (0x1D4); `bus_error` output. No trap (no CSR). | `rtl/AXI/AXI_master.v`, `rtl/AXI/AXI_Interconnect.v`, `rtl/packages/soc_pkg.vh`, `interrupt_pkg.vh`, `interrupt_axi_wrapper.v`, `soc_top.v` |
| A2 | An external-RAM backend that never answers hung the CPU forever. | Slave-side timeout (`EXT_RAM_TIMEOUT`, default 1024 clk; measured worst case 109): SLVERR, RDATA 0. Arbiter latches addr/data at grant; a request abandoned by timeout becomes an orphan whose late `mem_ready` is swallowed. No master-side timeout (dropping VALID before the handshake would violate AXI). | `AXI_Interconnect.v`, `soc_top.v` (parameter) |
| S1 | `rst_n` went straight to every flop. | `reset_sync` (2 FF, async assert, sync release, ASYNC_REG). | `rtl/reset_sync.v`, `soc_top.v`, `rtl/filelist_fir11.f` |
| S3/S4/F3 | No synthesis flow / constraints. | `fpga/synth_soc.tcl` (top `soc_top`), `fpga/soc_top.xdc` (100 MHz clock only, no pins), `scripts/run_vivado_synth.py` (builds firmware, copies program.mem/data.mem + FIR `.dat` into the run dir, requires Vivado's "$readmem ... read successfully" for all four). | `fpga/*`, `scripts/run_vivado_synth.py` |

Testbench updates required by the specification changes (no check removed or relaxed):
- `tb_ext_ram_cfgA`: unmapped access now expects DECERR (was OKAY).
- `tb_cpu_timer_irq` (A): the same firmware image touches the ext-RAM window, unmapped in A -> exactly DECERR with RDATA 0 is required there, OKAY elsewhere.
- `tb_cpu_fault`: rewritten for A1/A2 (was: "backend never answers -> CPU hangs, no timeout").
- CPU monitors start at `dut.rst_n_sync` (the DUT leaves reset 2 clocks after the TB pin).
- `tb_irq_ack`, `tb_ext_ram_axi`, `tb_ext_ram_cfgA`, `tb_irq_i1`: new ports tied/connected.

## New tests (default list of `scripts/run_rtl_tests.py`)

| Test | Content | Result |
|---|---|---|
| `tb_irq_i1` | FIR wrapper + interrupt block: ACK delay sweep 0..40 clk after a new DATA_IN; polling-consumed event then ISR (no duplicate) | 44/44 PASS (old RTL: 24 lost) |
| `tb_cpu_irq_c4_a/b/c` | Real SoC, ISR `[lw STATUS] sw ACK; N nop; mret`, N = 0..6, padded main loop, Timer pulse at 41 phases; I1 replay on CPU; C4 margin >= 1 clk | 326/326 each |
| `tb_axi_fault` | Interconnect, 3000 random transactions, random backend latency (in time / around / beyond timeout), BREADY/RREADY backpressure, response stability, scoreboard, liveness watchdog | 49 052 checks PASS; 4/4 RTL mutants killed (no orphan gate, unmapped OKAY, no read timeout, no address latch) |
| `tb_cpu_fault_b/c` | CPU: SLVERR/DECERR + BUSERR by software; read/write timeout (1025/1024 clk), orphan swallowed, timed-out write not committed, recovery; permanent hang -> progress; reset | 32/32 each |

## Regression (XSim 2026.1)

56 configurations, same RTL throughout, run in three passes (the runner stops at the first
FAIL): `reg_full` 27, `reg_full2` 14 (+1 negative), `reg_full3` 11, `reg_neg` 3 negatives.

| Group | Configurations | Result |
|---|---|---|
| Default list (FIR wrapper/vectors, AXI FIR, **AXI fault**, ext-RAM A/B/C, CPU bus B/C, Timer, IRQ ACK, **CPU fault B/C**, ID/EX, flush+hold B/C, **I1**, **C4 A/B/C**) | 20 | 20 PASS |
| Firmware: smoke, fir_smoke, fir_stream, ext_ram B/C, fir_1000 B/C | 7 | 7 PASS |
| Timer IRQ A/B/C, fir_timer, fir_timer_stress | 5 | 5 PASS |
| fir_timer_1000 B/C (cache off/on), stress B/C, reset B/C, late B/C | 8 | 8 PASS |
| FIR matrix: 6 datasets x B/C (1000 samples, bit-exact) | 12 | 12 PASS |
| Negative: timing_fault B/C, jitter_fault B/C | 4 | 4 expected rejections |
| **Total** | **56** | **52 PASS + 4 expected rejections, 0 unexpected FAIL** |

One failure seen during the run and fixed: `tb_cpu_timer_irq_a` expected OKAY for the unmapped
ext-RAM window in configuration A; the checker now requires exactly DECERR there (see above).

Negative (fault-injection) configurations `tb_cpu_fir_timer_1000_timing_fault_b/c` and
`jitter_fault_b/c` must END IN `TEST FAILED` with the budget errors (as in
`scripts/verify_phase41.py`); they are reported as "expected rejection".

## Vivado 2026.1 synthesis (`python scripts/run_vivado_synth.py --impl`)

Part xc7z020clg484-1 (reference only, board not specified), firmware `fir_timer` in IMEM/DMEM.

| | Config A (default, FPGA target) post-route | Config C (ext RAM + cache) post-synth |
|---|---|---|
| Slice LUT | 2533 (4.8 %) | 3437 (6.5 %) |
| LUT as memory | 130 (IMEM/DMEM LUTRAM) | 279 |
| Flip-flops | 2460 (2.3 %) | 3174 |
| Latches | 0 | 0 |
| BRAM36 | 1 (FIR11) | 17 (sdram_model 64 KB + FIR) |
| DSP48 | 2 (FIR multiplier) | 2 |
| $readmem | program.mem, data.mem, both FIR .dat read successfully | same |
| Critical warnings / errors | 0 / 0 | 0 / 0 |
| Timing @ 100 MHz | **WNS −3.247 ns, TNS −940 ns (VIOLATED)**, WHS +0.056 ns | WNS −4.945 ns (synth estimate) |

Same routed netlist re-timed: 75 MHz (13.333 ns) WNS +0.086 ns; 50 MHz WNS +6.753 ns.
Critical path (13 logic levels, ~84 % routing): `MEM_WB.rd` -> forwarding compare -> EX ALU /
branch condition -> branch redirect/flush -> `IF_ID` clock enable — the CPU resolves branches in
EX with WB forwarding in the same cycle. Fixing it needs a CPU pipeline change (out of scope).

Warnings: Synth 8-7129 (unused input ports) x100, Synth 8-3332 x34 (config A: constant ext-RAM
arbiter FSM, HLS multiplier low bits), Synth 8-3936 x2 (HLS ROM register trimmed 32 -> 11 bits).

**Synthesis PASS; timing at 100 MHz FAIL (Fmax ~75 MHz).**

## sdram_model on FPGA

`sdram_top` instantiates `sdram_model` internally and has no external pins. The model
synthesises (64 KB array -> BRAM, `$display` ignored) but it is on-chip BRAM behind an SDRAM
command protocol, never the board SDRAM. Configurations B/C are simulation configurations.
For hardware use configuration A; if more data RAM is needed, replace `sdram_top` by a BRAM
backend on the same `cpu_*` interface (or a real SDRAM controller/PHY with board-specific pins
and timing). Not changed here (architecture change).

## Required before running on an FPGA

1. Board XDC: PACKAGE_PIN / IOSTANDARD for clk, rst_n (polarity: active low), cpu_irq, bus_error.
2. Clock: 100 MHz does not close. Use <= 75 MHz (50 MHz recommended, e.g. MMCM) or pipeline the
   CPU branch/forwarding path. With a different clock, rescale Timer PERIOD in firmware
   (`FIR_TIMER_PERIOD`, 10 kHz = f_clk / 10 kHz).
3. No observable I/O besides two status pins: add a UART/GPIO or ILA to see results.
4. Program image is fixed at synthesis (IMEM/DMEM `$readmemh`); re-synthesise (or `updatemem`) to change firmware.
