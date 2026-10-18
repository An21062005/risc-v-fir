"""Run self-checking RTL tests with Vivado XSim, including a strict log gate.

Example (Windows):
  python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado
All generated files live in --output (default: sim_rtl_tests).
--rtl-root allows running the same regression against a saved RTL baseline.
"""

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vivado-root", type=Path,
                        default=os.environ.get("XILINX_VIVADO"))
    parser.add_argument("--rtl-root", type=Path)
    parser.add_argument("--output", type=Path, default=Path("sim_rtl_tests"))
    parser.add_argument("--tests", nargs="+")
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()
    if args.vivado_root is None:
        parser.error("Pass --vivado-root or set XILINX_VIVADO")
    project = Path(__file__).resolve().parent.parent
    rtl = (args.rtl_root or project / "rtl").resolve()
    vivado = args.vivado_root.resolve()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    if os.name == "nt":
        # Match Vivado's loader environment without relying on installation
        # settings64.bat files that can reference unrelated/missing products.
        binary = vivado / "bin/unwrapped/win64.o"
        paths = [vivado / "lib/win64.o", binary, vivado / "bin"]
        for pattern in ("python-*", "jre*"):
            for runtime in (vivado / "tps/win64").glob(pattern):
                paths.extend([runtime, runtime / "DLLs", runtime / "bin",
                              runtime / "bin/server"])
        env["PATH"] = os.pathsep.join(map(str, paths)) + os.pathsep + env.get("PATH", "")
        for name, relative in {
            "XILINX_VIVADO": ".", "RDI_APPROOT": ".", "HDI_APPROOT": ".",
            "RDI_BASEROOT": "..", "RDI_BINROOT": "bin", "RDI_BINDIR": "bin",
            "RDI_LIBDIR": "lib/win64.o", "RDI_DATADIR": "data",
            "TCL_LIBRARY": "tps/tcl/tcl8.6", "RT_LIBPATH": "scripts/rt/data",
            "RT_TCL_PATH": "scripts/rt/base_tcl/tcl",
        }.items():
            env[name] = str((vivado / relative).resolve())
        suffix = ".exe"
    else:
        binary = vivado / "bin"
        suffix = ""

    def run(tool, arguments, directory, log_name, require_pass=False):
        command = [str(binary / (tool + suffix)), *map(str, arguments)]
        result = subprocess.run(command, cwd=directory, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, encoding="utf-8", errors="replace",
                                timeout=180)
        (directory / log_name).write_text(result.stdout, encoding="utf-8")
        failed = result.returncode != 0 or bool(re.search(
            r"(?im)^\s*(?:#\s*)?(?:\[[^\]\n]+\]\s*)?"
            r"(?:ERROR\b|FATAL\b|\*\*\s+(?:Error|Fatal)|TEST FAILED)",
            result.stdout))
        if require_pass and "TEST PASSED" not in result.stdout:
            failed = True
        if failed:
            print(result.stdout)
            raise RuntimeError(f"{tool} failed; see {directory / log_name}")
        for line in result.stdout.splitlines():
            if any(token in line for token in ("TEST PASSED", "Checks:", "INFO CYC_CNT")):
                print(line)

    sources = []
    for filelist in ("filelist_fir11.f", "filelist_ext_ram_sim.f"):
        for line in (rtl / filelist).read_text(encoding="utf-8-sig").splitlines():
            line = line.strip()
            if line and not line.startswith(("//", "+")):
                sources.append(rtl / Path(line).relative_to("rtl"))
    tests = [
        ("tb_fir11_wrapper", []),
        ("tb_axi_fir", []),
        ("tb_ext_ram_cfgA", []),
        ("tb_ext_ram_axi_b", ["USE_CACHE=0"]),
        ("tb_ext_ram_axi_c", ["USE_CACHE=1"]),
        ("tb_cpu_bus_b", ["USE_CACHE=0"]),
        ("tb_cpu_bus_c", ["USE_CACHE=1"]),
    ]
    selected = args.tests or [name for name, _ in tests]
    unknown = set(selected) - {name for name, _ in tests}
    if unknown:
        parser.error(f"Unknown tests: {sorted(unknown)}")
    for name, generics in tests:
        if name not in selected:
            continue
        top = ("tb_cpu_bus" if name.startswith("tb_cpu_bus_") else
               "tb_ext_ram_axi" if generics else name)
        directory = output / name
        directory.mkdir(parents=True, exist_ok=True)
        for data in (rtl / "Peripherals/FIR11").glob("*.dat"):
            shutil.copy2(data, directory / data.name)
        if top == "tb_cpu_bus":
            # Empty memory fixtures for the CPU's readmemh; the testbench
            # installs directed instructions after time-zero initialization.
            (directory / "program.mem").write_text("00000013\n" * 256, encoding="ascii")
            (directory / "data.mem").write_text("00000000\n" * 256, encoding="ascii")
        print(f"Running {name}", flush=True)
        run("xvlog", ["-i", rtl / "packages", "-i", project / "tb",
                      *sources, project / "tb" / (top + ".v")], directory, "compile.log")
        options = [top, "-s", name, "-mt", "2"]
        for generic in generics:
            options.extend(["-generic_top", generic])
        run("xelab", options, directory, "elaborate.log")
        run("xsim", [name, "-runall", "-testplusarg", f"seed={args.seed}"],
            directory, "simulate.log", require_pass=True)
    print(f"PASS: {len(selected)} test configuration(s)")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
