> Lưu trữ lịch sử: các firmware phụ và testbench tương ứng đã được bỏ khi tinh gọn project.
> Các tên/lệnh/kết quả bên dưới mô tả trạng thái tại thời điểm kiểm chứng.
> Luồng hiện hành: [fir_timer_1000.c](../firmware/fir_timer_1000.c); xem
> [hướng dẫn hiện tại](../firmware/README.md) để build và chạy.

# AXI/FIR RTL fixes and verification — 2026-10-18

> **Historical record (up to Giai đoạn 4.1, before Phase 5).** Results below describe the RTL at that time.
> Superseded by Phase 5 (2026-10-21, [PHASE5_VERIFICATION.md](PHASE5_VERIFICATION.md)):
> unmapped addresses now return **DECERR** (not OKAY); `cpu_axi_master` checks BRESP/RRESP (BUSERR
> registers); an external-RAM access that never completes ends with **SLVERR after 1024 cycles**
> (no CPU hang); `rst_n` goes through a reset synchronizer; Vivado synthesis has been run
> (synthesis PASS, timing 100 MHz FAIL). The current overall status is in the [README](../README.md).

## Scope

Fix AXI/FIR transport and integration defects found in the first review.
The CPU ISA and the eight generated FIR HLS `.v`/`.dat` files are unchanged.
No application firmware, linker or startup implementation is included.

## Confirmed defects and corrections

| Defect | Correction | Regression |
|---|---|---|
| Read routing used live ARADDR after handshake | Latch all slave selects together with ARADDR; use them until response | Change ARADDR immediately after handshake, including to unmapped addresses |
| AWREADY/WREADY/ARREADY stayed high after receive capacity was exhausted | Derive READY from the corresponding receiving state; capture only on VALID && READY | Queue two reads and two writes while holding the next VALID; check both responses and write pulses |
| Peripheral read enable lasted two cycles, clearing a newly completed FIR result | Emit exactly one read pulse; retain a full cycle for registered peripheral data before sampling RDATA | Read DATA_OUT one edge before, on, and one edge after completion with real HLS |
| MMIO ignored WSTRB and address alignment | Aligned WSTRB=0000 is a no-op/OKAY; partial writes and unaligned reads/writes return SLVERR without peripheral enables | Zero-strobe CTRL write, partial CTRL write, unaligned CTRL and DATA_OUT accesses |
| FIR unit TB sampled the second read snapshot and raced its IRQ monitor | Model the single read pulse and wait until the IRQ edge monitor has sampled the new level | FIR unit tests including coincident read/completion and repeated reads |

Functional RTL changes are in `rtl/AXI/AXI_Interconnect.v`. Wrapper, CPU and
SoC header comments document the corrected contract; their datapaths are unchanged.

## Read contract

The register map and CPU/AXI address translation are unchanged.

1. AR handshake captures the address and target.
2. READ_DATA issues one `rd_en` pulse and the saved address.
3. At the READ_WAIT edge, the peripheral snapshots its register and applies
   the read side effect exactly once.
4. At the following READ_RESP edge, the interconnect captures that snapshot.
   RDATA/RRESP/RVALID then remain stable until RREADY.

If FIR completion coincides with the peripheral's DATA_OUT read edge, the read
returns the previous output snapshot and **new DONE remains set**. A subsequent
DATA_OUT read obtains the new result and clears DONE. Completion continues to
win over ordinary clears; soft reset continues to win over completion.

Timer, Interrupt and FIR MMIO support aligned 32-bit register transactions.
Partial MMIO writes are explicitly rejected, rather than silently treated as
full-word writes. External RAM retains its existing full-WSTRB policy;
unmapped addresses retain their previous zero/no-op/OKAY behavior.

## Reproduction before fixing

Vivado XSim 2026.1 ran the tests; Questa simulation could not acquire a license.

- Original FIR unit test: **475 checks, 1 error** in the IRQ-edge-count baseline.
- New AXI/FIR integration regression on original RTL: **27 checks, 9 errors**,
  exposing live read decode, lost queued requests and duplicate read effects.
- Added MMIO strobe/alignment regression before its RTL guard:
  **36 checks, 8 errors**, including a zero-strobe write clearing DONE.

These were observed simulation failures, not conclusions from compilation.
Local evidence directories are `D:/SoC/verification_evidence/rtl_fix_2026-10-18/fir-rtl-fix-baseline`,
`D:/SoC/verification_evidence/rtl_fix_2026-10-18/fir-rtl-red` and `D:/SoC/verification_evidence/rtl_fix_2026-10-18/fir-rtl-strobes-red`.
The pre-fix RTL was preserved in `D:/SoC/verification_evidence/rtl_fix_2026-10-18/fir-rtl-original/rtl`.

## Final observed results

| Test | Configuration | Checks | Errors | Result |
|---|---|---:|---:|---|
| `tb_fir11_wrapper` | Real HLS, signed/overflow samples, overrun, clear and abort/reset races | 477 | 0 | PASS |
| `tb_axi_fir` | Real interconnect + wrapper + HLS; queued traffic, payload changes, backpressure, strobe/alignment and completion boundaries | 36 | 0 | PASS |
| `tb_ext_ram_cfgA` | External RAM disabled | 9 | 0 | PASS |
| `tb_ext_ram_axi_b` | Bypass, initial seed 1 | 8,343 | 0 | PASS |
| `tb_ext_ram_axi_c` | Cache enabled, initial seed 1 | 8,343 | 0 | PASS |
| `tb_cpu_bus_b` | Real CPU/master/FIR/IRQ/RAM, bypass | 104 | 0 | PASS |
| `tb_cpu_bus_c` | Same directed CPU instruction fixture, cache enabled | 162 | 0 | PASS |
| `tb_ext_ram_axi_b` | Bypass, initial seed 7 | 8,343 | 0 | PASS |
| `tb_ext_ram_axi_c` | Cache enabled, initial seed 7 | 8,343 | 0 | PASS |

Total: **9 simulation runs, 34,160 checks, 0 errors**. The RAM test mutates its
PRNG seed as it runs; its final summary therefore prints a different seed value.
`simulate.log` also records the initial seed.

Independent Questa 10.7c `vlog -lint` of all RTL and five testbench modules
completed with **0 errors, 0 warnings**. Its log is
`D:/SoC/verification_evidence/rtl_fix_2026-10-18/fir-rtl-questa-lint/compile.log`; Questa runtime was not used.

The CPU fixture verifies FIR(7)=378, dependent RAM load/store, held PC/pipeline
and bus request, one FIR start/completion, one CPU completion per AXI response,
Timer IRQ pending while stalled, one ISR entry, ACK and MRET return. Masked FIR
pending remains independent from the enabled Timer source. Longest observed
stall was **24 cycles in B** and **79 cycles in C** for this fixture.

FIR wrapper `CYC_CNT` measured **17 cycles**. The HLS synthesis report's latency
18/interval 19 is retained; neither number is a measured FPGA timing result.

Final logs: `D:/SoC/verification_evidence/rtl_fix_2026-10-18/fir-rtl-final/<test>/simulate.log` and
`D:/SoC/verification_evidence/rtl_fix_2026-10-18/fir-rtl-seed7/<test>/simulate.log`. Each run also has compile and
elaboration logs. The runner checks process status, failure messages and the
explicit TEST PASSED marker; simulator exit code alone is insufficient.

## Run again

From the project root, with Python and a Vivado installation:

```powershell
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado --tests tb_ext_ram_axi_b tb_ext_ram_axi_c --seed 7 --output sim_rtl_seed7
```

Set `--output` to place generated artifacts elsewhere. Default `outfeed/`
(project root): `outfeed/<testbench>/` build/log directories are ignored by
`.gitignore`; `outfeed/<test>/actual.dat` holds the FIR RTL results of
`tb_fir11_vectors`. CPU `.mem` fixtures and FIR `.dat`
copies are generated only inside the simulation output directory.

To compare the current regression against a saved baseline, pass
`--rtl-root <directory-containing-the-old-rtl-filelists>` and a separate output
directory. Tests continue to come from the current project.

## Firmware tests (steps 1–4), run from a clean tree — 2026-10-18

Run after deleting `firmware/build/` and `outfeed/tb_*/`; every image was rebuilt by
`scripts/build_firmware.py` (GCC 13.4, rv32i/ilp32, ISA whitelist, IMEM/DMEM 1 KB checks).
No RTL change. All 15 configurations: `TEST PASSED`, 0 errors (XSim 2026.1, ~66 s total).

| Test | Firmware (IMEM bytes) | Checks | Cycles to HALT |
|---|---|---|---|
| `tb_cpu_firmware` | `main.c` (952) | 28 | 1672 |
| `tb_cpu_fir_firmware` | `fir_smoke.c` (568) | 54 | 1509 |
| `tb_cpu_fir_stream` | `fir_stream.c` (768) | 71 | 6365 |
| `tb_cpu_ext_ram_b` / `_c` | `ext_ram_test.c` (732) | 47 / 47 | 8524 / 13072 |
| `tb_cpu_fir_1000` / `_c` | `fir_1000.c` (860) | 82 / 82 | 218389 / 230955 |

Default regression in the same run: `tb_fir11_wrapper` 477, `tb_fir11_vectors` 90985
(6000/6000 samples), `tb_axi_fir` 36, `tb_ext_ram_cfgA` 9, `tb_ext_ram_axi_b`/`_c` 8343 each,
`tb_cpu_bus_b` 104, `tb_cpu_bus_c` 162 checks, 0 errors. Re-run:

```text
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado --tests \
    tb_cpu_firmware tb_cpu_fir_firmware tb_cpu_fir_stream \
    tb_cpu_ext_ram_b tb_cpu_ext_ram_c tb_cpu_fir_1000 tb_cpu_fir_1000_c
```

## Verification limits

- CPU still implements its existing ISA subset. No ISA compliance claim is made.
- CPU AXI master still does not expose BRESP/RRESP errors to software and has
  no bus timeout. Returning SLVERR at the interconnect does not add CPU traps.
- IMEM/DMEM aliasing outside their physical depth and the existing unmapped
  address behavior are unchanged.
- FIR reset still does not clear sample history. Unit tests cover its documented
  retention/abort behavior, not a new zero-history reset contract.
- Directed CPU tests use instructions installed by the testbench after time-zero
  initialization, not production firmware or a toolchain/linker validation.
- Timer IRQ during a CPU RAM stall is covered; FIR ISR execution and all
  interrupt/reset combinations are not exhaustively verified.
- No FPGA synthesis, implementation, reset synchronizer or physical SDRAM PHY
  verification was performed. Passing these simulations is not whole-system
  hardware sign-off.

## Timer periodic 10 kHz + CPU Timer IRQ (Giai đoạn 1–2) — 2026-10-18

Scope: Timer periodic mode and a dedicated IRQ firmware. FIR HLS RTL, FIR wrapper,
FIR firmware, CPU pipeline, interrupt controller, `startup.S`/`linker.ld` unchanged.

Timer (`rtl/Peripherals/timer.v`, bus 0x080 / CPU 0x4000_0080) now decodes `addr[5:2]`:

| Offset | Register | Behaviour |
|---|---|---|
| 0x00 | LEGACY | Original one-shot, bit-exact (0x10–0x3C stay aliases, as before) |
| 0x04 | PERIOD | Clocks per tick; < 2 is invalid (no ticks) |
| 0x08 | CTRL | bit0 ENABLE, bit1 PERIODIC (0 = one tick then ENABLE clears), bit2 PERIOD_INVALID (RO) |
| 0x0C | TICK_COUNT | RO, ticks since reset |

First tick exactly PERIOD clocks after the edge that sets ENABLE 0→1; then every
PERIOD clocks; 1-cycle pulse; TICK_COUNT +1 per tick. Rewriting CTRL with ENABLE=1
keeps the phase; ENABLE=0 wins over a coincident tick. ACK is in the interrupt
controller and never touches the Timer. `irq = legacy | tick` (do not use both modes
at once: adjacent pulses merge into one edge).

IRQ firmware: `firmware/timer_irq_test.c` + `startup_irq.S` (vector 0x10, saves the 16
caller-saved registers, calls C `timer_isr`, `mret`) + `linker_irq.ld`. IMEM 1004/1024 B.
`build_firmware.py` allows `mret` only for this firmware and only at `__trap_mret`.

| Test | Checks | Result | Notes |
|---|---:|---|---|
| `tb_timer` | 2013 | PASS | LEGACY compared every cycle with the original `timer.v` (commit f748661); periodic vs independent model; 407,639 cycles, 0 mismatches. PERIOD=10000: first IRQ 10000 clk, interval 10000/10000 |
| `tb_cpu_timer_irq_a` / `_b` / `_c` | 58 / 59 / 59 | PASS | 9 ticks (interval 10000), 7 pending events + 2 coalesced, 7 irq_take = 7 STATUS reads = 7 ACK = 7 mret = irq_count, 0 spurious; registers checked after 4 returns into the test loop + exit; IRQs during AXI stall serviced (B max 19, C 22 clocks) |

Mutation checks (scratch copies): `tb_timer` caught 6/6 Timer faults; `tb_cpu_timer_irq`
caught no-ACK, wrong ACK id, ISR clobbering s2, missing a5 restore, Timer off-by-one and
wrong `mepc`. Not restoring t3 is undetectable (equivalent: `timer_isr` never uses t3).

Full regression after the change: 19 configurations PASS (the 15 pre-existing ones with
the same check counts and cycles to HALT as before). Questa `vlog -lint`: 0/0.

```text
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado --tests tb_timer     tb_cpu_timer_irq_a tb_cpu_timer_irq_b tb_cpu_timer_irq_c
```

Limits: one interrupt level, no nesting (CPU `in_irq`); ISR shares the main stack; no CSRs,
so no `mcause` — the ISR identifies the source through the controller STATUS register.

## Giai đoạn 3: Timer IRQ 10 kHz điều phối 32 mẫu FIR, FIR IRQ — 2026-10-18

No RTL change. New: `firmware/fir_timer.c`, `tb/tb_cpu_fir_timer.v`. `startup_irq.S` gained
`IRQ_C_HANDLER` / `REGTEST_COUNTER` / `REGTEST_NO_EXT_RAM` macros (defaults keep
`timer_irq_test` binary-identical, verified by comparing program.mem); `build_firmware.py` passes
per-firmware `defines`. `fir_stream.c` (polling) unchanged.

Flow: tick → Timer ISR (ACK = STATUS, read TICK_COUNT, stop Timer at 32, send sample if due and
FIR idle) → FIR DONE → FIR ISR (ACK = STATUS first, read DATA_OUT once, store, send next due
sample). Main: 10-zero flush (polling, IRQs off), ACK flush pending, start, wait in the
register-pattern loop. IMEM 1012/1024 B (stress build 996 B), DMEM 296 B + 256 B stack.

| Test | Checks | Result | Measured |
|---|---:|---|---|
| `tb_cpu_fir_timer` (PERIOD 10000) | 63 | PASS | 32 ticks, interval 10000/10000; 64 ISRs (32 Timer + 32 FIR), 65 ACK (+1 main flush); 32/32 outputs bit-exact vs Verilog model; tick→DATA_IN accept 109–116 clk (jitter 7 clk = 70 ns), accept interval 9993–10007 clk, accept→FIR done 17 clk, tick→stored ≤ 206 clk; 0 missed, 0 coalesced, backlog 1, 0 BUSY write, 0 OVERRUN |
| `tb_cpu_fir_timer_stress` (PERIOD 100, overload) | 60 | PASS | 32 ticks, 4 coalesced (TB = firmware), 28 Timer + 32 FIR ISRs, Timer+FIR pending together 1739 cycles, 31 missed (TB = firmware), backlog 32; still 32/32 correct, in order, no BUSY/OVERRUN |

Fault injection (scratch copies, checker unchanged) — all detected: wrong stored output, missing
sample, duplicated sample, ACK of the wrong source, late ACK (FIR IRQ lost/ordering), sending while
BUSY, coalesced ticks / deadline misses under normal-mode expectations, deliberate 10 kHz deadline
miss, ISR corrupting t3, RTL hiding one FIR IRQ edge.

Full regression: 21 configurations PASS (pre-existing ones with unchanged check counts and cycles).
Questa `vlog -lint`: 0/0. IMEM is the binding limit (98.8 %); the 1000-sample stage needs either a
smaller image or a larger IMEM (not changed here).

## Giai đoạn 4: Timer IRQ 10 kHz, 1000 mẫu từ RAM ngoài — 2026-10-18

No RTL change. New: `firmware/fir_timer_isr.h` (ISR moved verbatim out of `fir_timer.c`;
`fir_timer` / `fir_timer_stress` stay binary-identical, program.mem and data.mem compared),
`firmware/fir_timer_1000.c` (no register-pattern loop; input/output in external RAM at
0x4001_0000 / 0x4001_1000, data from `data_test/fir_1000`), `tb/tb_cpu_fir_timer_1000.v`.
IMEM 824/1024 B, DMEM 40 B + 256 B stack. Context is checked in the testbench: x1..x31 snapshot
when the first ISR instruction reaches MEM, compared when the mepc instruction reaches MEM.

| Measurement | B (no cache) | C (cache) |
|---|---:|---:|
| Checks / errors | 76 / 0 | 76 / 0 |
| Ticks (interval) | 1000 (10000/10000) | 1000 (10000/10000) |
| IRQs taken (Timer + FIR), ACK | 2000 (1000+1000), 2001 | 2000 (1000+1000), 2001 |
| Output in sdram_model == reference | 1000/1000 | 1000/1000 |
| Tick → ISR entry min/avg/max | 2/2/5 | 2/2/5 |
| Tick → FIR accepts DATA_IN min/avg/max | 132/132/139 | 118/136/207 |
| Jitter of DATA_IN accept | 7 clk (70 ns) | 89 clk (890 ns) |
| DATA_IN accept interval | 9998–10006 | 9912–10089 |
| FIR latency (accept → ap_done) | 17 | 17 |
| Tick → output stored (AXI B) min/avg/max | 242/243/262 | 231/249/320 |
| Longest RAM transaction | 42 | 99 |
| Deadline miss / coalesced / max backlog | 0 / 0 / 1 | 0 / 0 / 1 |
| BUSY writes / OVERRUN | 0 / 0 | 0 / 0 |
| CPU bus transactions (MMIO + RAM) | 11048 (8048 + 3000) | 11048 (8048 + 3000) |
| Cycles to HALT | 10,032,106 | 10,035,454 |

Fault injection (config B, checker unchanged) — all detected: ISR corrupting t3, skipped sample,
wrong stored output, ACK of the wrong source, RTL hiding one FIR IRQ (progress watchdog stops the run
at cycle 3.03 M instead of timing out at 10 M), one-bit RAM read-data and write-data corruption in
the interconnect. Full regression: 23 configurations PASS; Questa `vlog -lint` 0/0.

## Giai đoạn 4.1 — 2026-10-21

Xem [báo cáo verification Giai đoạn 4.1](PHASE41_VERIFICATION.md) cho cơ chế
deadline mới, 6 dataset × B/C, reset, IRQ/ACK, overload, fault injection và regression.
