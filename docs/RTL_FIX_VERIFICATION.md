# AXI/FIR RTL fixes and verification — 2026-10-18

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
Local evidence directories are `D:/SoC/.tmp/fir-rtl-fix-baseline`,
`D:/SoC/.tmp/fir-rtl-red` and `D:/SoC/.tmp/fir-rtl-strobes-red`.
The pre-fix RTL was preserved in `D:/SoC/.tmp/fir-rtl-original/rtl`.

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
`D:/SoC/.tmp/fir-rtl-questa-lint/compile.log`; Questa runtime was not used.

The CPU fixture verifies FIR(7)=378, dependent RAM load/store, held PC/pipeline
and bus request, one FIR start/completion, one CPU completion per AXI response,
Timer IRQ pending while stalled, one ISR entry, ACK and MRET return. Masked FIR
pending remains independent from the enabled Timer source. Longest observed
stall was **24 cycles in B** and **79 cycles in C** for this fixture.

FIR wrapper `CYC_CNT` measured **17 cycles**. The HLS synthesis report's latency
18/interval 19 is retained; neither number is a measured FPGA timing result.

Final logs: `D:/SoC/.tmp/fir-rtl-final/<test>/simulate.log` and
`D:/SoC/.tmp/fir-rtl-seed7/<test>/simulate.log`. Each run also has compile and
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
