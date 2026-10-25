'Synthesize soc_top with Vivado (batch, non-project) and check the results.'

import argparse
import collections
from pathlib import Path
import re
import subprocess
import sys


def main():
    project = Path(__file__).resolve().parent.parent
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--vivado-root", type=Path, required=True)
    ap.add_argument("--cfg", choices=("C",), default="C",
                    help="synthesis check with external RAM; not a board-ready memory backend")
    ap.add_argument("--impl", action="store_true", help="also opt/place/route (post-route timing)")
    ap.add_argument("--firmware", choices=("fir_timer_1000", "fir_timer_1000_stress"),
                    default="fir_timer_1000", help="main firmware image for IMEM/DMEM")
    ap.add_argument("--output", type=Path)
    args = ap.parse_args()
    out = (args.output or project / "outfeed" / f"synth_{args.cfg}").resolve()
    out.mkdir(parents=True, exist_ok=True)
    vivado = args.vivado_root.resolve()

    fw = out / "fw"
    cmd = [sys.executable, str(project / "scripts" / "build_firmware.py"), "--firmware", args.firmware, "--out", str(fw)]
    toolchain = vivado.parent / "gnu" / "riscv" / "nt" / "bin"
    if toolchain.is_dir():
        cmd += ["--toolchain", str(toolchain)]
    if subprocess.run(cmd).returncode != 0:
        sys.exit("firmware build failed")

    launcher = vivado / "bin" / ("vivado.bat" if sys.platform == "win32" else "vivado")
    log = out / "vivado.log"
    r = subprocess.run([str(launcher), "-mode", "batch", "-nojournal", "-log", str(log),
                        "-source", str(project / "fpga" / "synth_soc.tcl"), "-tclargs",
                        str(project), str(fw), str(out), "1" if args.impl else "0", args.cfg],
                       cwd=out, stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT)
    if not log.is_file():
        sys.exit(f"Vivado did not create {log} (launcher exit {r.returncode}); check the Vivado installation/environment")
    text = log.read_text(encoding="utf-8", errors="replace")
    problems = []
    if r.returncode != 0 or "SYNTH_SOC_DONE" not in text:
        problems.append(f"Vivado failed (exit {r.returncode}), see {log}")

    # F3: memory images
    for name in ("program.mem", "data.mem", "fir_fir_Pipeline_Shift_Accum_Loop_fir_int_int_c_ROM_AUTO_1R.dat",
                 "fir_fir_Pipeline_Shift_Accum_Loop_shift_reg_RAM_AUTO_1R1W.dat"):
        if not re.search(r"\$readmem data file '[^']*" + re.escape(name) + r"' is read successfully", text):
            problems.append(f"memory image not loaded: {name}")
    warnings = collections.Counter(re.findall(r"^WARNING: \[([^\]]+)\]", text, re.M))
    crit = re.findall(r"^CRITICAL WARNING: .*$", text, re.M)
    errors = re.findall(r"^ERROR: .*$", text, re.M)
    latches = re.findall(r"^WARNING: \[Synth 8-327\].*$", text, re.M)
    problems += [f"latch: {l}" for l in latches] + crit + errors

    def util(path):
        rows = {}
        if path.is_file():
            for line in path.read_text(errors="replace").splitlines():
                m = re.match(r"\|\s*(Slice LUTs\*?|LUT as Logic|LUT as Memory|Slice Registers|Register as Flip Flop|"
                             r"Register as Latch|Block RAM Tile|RAMB36/FIFO\*?|RAMB18|DSPs|F7 Muxes)\s*\|\s*([\d.]+)\s*\|"
                             r"(?:[^|]*\|){2}\s*([\d.]+)\s*\|\s*([\d.<]+)", line)
                if m and m.group(1).rstrip("*") not in rows:
                    rows[m.group(1).rstrip("*")] = (m.group(2), m.group(3), m.group(4))
        return rows

    stage = "route" if args.impl else "synth"
    timing_fail = False
    print(f"== soc_top cfg {args.cfg}, firmware {args.firmware}, {stage} ({out})")
    for k, (used, avail, pct) in util(out / f"util_{stage}.txt").items():
        print(f"   {k:22s} {used:>8s} / {avail:<8s} ({pct}%)")
    timing = (out / f"timing_{stage}.txt")
    if timing.is_file():
        t = timing.read_text(errors="replace")
        m = re.search(r"WNS\(ns\)\s+TNS\(ns\).*?\n\s*-+.*?\n\s*([-\d.]+)\s+([-\d.]+)\s+(\d+)\s+(\d+)\s+([-\d.]+)\s+([-\d.]+)", t, re.S)
        if m:
            wns, tns, whs = float(m.group(1)), float(m.group(2)), float(m.group(5))
            ok = wns >= 0 and whs >= 0
            print(f"   timing @100 MHz ({stage}): WNS {wns:.3f} ns, TNS {tns:.3f} ns, WHS {whs:.3f} ns -> "
                  f"{'MET' if ok else 'VIOLATED'} (Fmax est. {1000.0 / (10.0 - wns):.1f} MHz)")
            if args.impl and not ok:
                timing_fail = True
        if "All user specified timing constraints are met" in t:
            print("   Vivado: All user specified timing constraints are met.")
    print("   warnings by ID: " + ", ".join(f"{k} x{v}" for k, v in warnings.most_common()))
    print(f"   latches: {len(latches)}, critical warnings: {len(crit)}, errors: {len(errors)}")
    if problems:
        print("SYNTH FAILED:\n  " + "\n  ".join(problems))
        sys.exit(1)
    print("SYNTH PASSED (netlist, memory images, no latch / critical warning)")
    if args.impl:
        print("TIMING " + ("FAILED: post-route WNS < 0 at 100 MHz" if timing_fail else "PASSED at 100 MHz (post-route)"))
        if timing_fail:
            sys.exit(2)


if __name__ == "__main__":
    main()
