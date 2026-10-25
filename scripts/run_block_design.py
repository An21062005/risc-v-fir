'Create a runnable Vivado Block Design project; optionally synthesize the whole top.'

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from vivado_tools import run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vivado-root", type=Path, default=os.environ.get("XILINX_VIVADO"))
    parser.add_argument("--cfg", choices=("A", "B", "C"), default="C")
    parser.add_argument("--synth", action="store_true")
    parser.add_argument("--diagram", action="store_true",
                        help="briefly open Vivado's GUI canvas, save layout and export SVG")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not args.vivado_root:
        parser.error("Pass --vivado-root or set XILINX_VIVADO")
    repo = Path(__file__).resolve().parent.parent
    vivado = args.vivado_root.resolve()
    out = (args.output or repo / "outfeed/block_design" / args.cfg).resolve()
    out.mkdir(parents=True, exist_ok=True)
    (out / "result.json").unlink(missing_ok=True)
    fw = out / "fw"
    subprocess.run([sys.executable, str(repo / "scripts/build_firmware.py"),
                    "--firmware", "fir_timer_1000", "--out", str(fw),
                    "--toolchain", str(vivado.parent / "gnu/riscv/nt/bin")], check=True)
    text = run(vivado, "vivado", ["-mode", "batch", "-nojournal", "-log", "vivado.log",
               "-source", repo / "fpga/bd/create_soc_bd.tcl", "-tclargs",
               repo, out, args.cfg, fw, int(args.synth)], out, "console.log")
    required = [f"BD_CREATED cfg={args.cfg}"]
    if args.synth:
        required.append(f"BD_SYNTH_DONE cfg={args.cfg}")
    problems = [f"Missing completion marker: {s}" for s in required if s not in text]
    problems += re.findall(r"(?m)^CRITICAL WARNING:.*$", text)
    problems += re.findall(r"(?m)^WARNING: \[Synth 8-327\].*$", text)
    if args.synth:
        for name in ("program.mem", "data.mem", *(p.name for p in (repo / "rtl/Peripherals/FIR11").glob("*.dat"))):
            if not re.search(r"\$readmem data file '[^']*" + re.escape(name) + r"' is read successfully", text):
                problems.append(f"Memory image was not loaded: {name}")
    if problems:
        raise RuntimeError("\n".join(problems))
    if args.diagram:
        run(vivado, "vivado", ["-mode", "batch", "-nojournal", "-log", "layout.log",
            "-source", repo / "fpga/bd/export_layout.tcl", "-tclargs", out], out, "layout_console.log", 180)
        if not (out / "soc_system.svg").is_file():
            raise RuntimeError("Vivado did not export soc_system.svg")
    result = dict(configuration=args.cfg, top="soc_system_wrapper", synthesis=args.synth,
                  passed=not problems, problems=problems,
                  project=str(out / "project/soc_bd.xpr"),
                  diagram=str(out / "soc_system.svg") if args.diagram else None,
                  log=str(out / "vivado.log"))
    (out / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(f"BLOCK DESIGN {'SYNTHESIS ' if args.synth else ''}PASSED: {out}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.SubprocessError) as exc:
        sys.exit(str(exc))
