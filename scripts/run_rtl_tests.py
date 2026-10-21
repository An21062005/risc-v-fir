"""Run self-checking RTL tests with Vivado XSim, including a strict log gate.

Example (Windows):
  python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado
All generated files live in --output (default: <project>/outfeed):
  outfeed/<testbench>/        XSim build, logs, HLS .dat copies
  outfeed/<test>/actual.dat   FIR RTL results of tb_fir11_vectors
--rtl-root allows running the same regression against a saved RTL baseline.

Optional (not part of the default regression, run by name):
Default list also includes tb_irq_i1 and tb_cpu_irq_c4_a/_b/_c (I1/C4); the latter
assemble tb/asm/irq_dir.S with the RISC-V GCC next to Vivado (<vivado>/../gnu/riscv/nt/bin).
  --tests tb_cpu_firmware   build firmware/ with GCC (scripts/build_firmware.py),
                            copy firmware/build/program.mem + data.mem into
                            outfeed/tb_cpu_firmware/ and run the C firmware on the CPU.
  --tests tb_cpu_fir_firmware
                            same for firmware/fir_smoke.c (build_firmware.py
                            --firmware fir_smoke -> firmware/build/fir_smoke/):
                            the CPU drives the FIR11 HLS IP over AXI.
  --tests tb_cpu_fir_stream same for firmware/fir_stream.c (--firmware fir_stream ->
                            firmware/build/fir_stream/, also copies symbols.mem):
                            32 samples DMEM -> FIR over AXI -> DMEM.
  --tests tb_cpu_ext_ram_b tb_cpu_ext_ram_c
                            firmware/ext_ram_test.c: CPU lw/sw on the 64 KB external
                            RAM (soc_top ENABLE_EXT_RAM=1, B = no cache, C = cache).
  --tests tb_cpu_timer_irq_a tb_cpu_timer_irq_b tb_cpu_timer_irq_c
                            firmware/timer_irq_test.c: Timer periodic 10 kHz -> IRQ -> ISR
                            (vector 0x10) -> ACK -> mret; A = no ext RAM, B/C = ext RAM.
  --tests tb_cpu_fir_timer tb_cpu_fir_timer_stress
                            firmware/fir_timer.c: Timer IRQ 10 kHz paces 32 FIR samples, FIR IRQ
                            returns results (stress: PERIOD 100, deliberate overload).
  --tests tb_cpu_fir_timer_1000_b tb_cpu_fir_timer_1000_c
                            firmware/fir_timer_1000.c: Timer IRQ 10 kHz paces 1000 samples from the
                            external RAM, FIR IRQ stores results back (B = no cache, C = cache).
                            ~10 M cycles each.
  --tests tb_cpu_fir_1000 tb_cpu_fir_1000_c
                            firmware/fir_1000.c: 1000 samples external RAM -> FIR ->
                            external RAM; data from data_test/fir_1000/ (generate with
                            scripts/gen_fir_1000_data.py). Long run (~1-2 min each).
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


def assemble_irq_images(toolchain, source, directory):
    """tb_cpu_irq_c4: assemble tb/asm/irq_dir.S variants into <directory>/<name>.mem (256 words)."""
    prefix = "riscv64-unknown-elf-"
    tool = lambda name: str(toolchain / (prefix + name)) if toolchain.is_dir() else prefix + name
    variants = []
    for n in range(7):
        variants += [(f"c4a_{n}", 0, n, 2, []), (f"c4b_{n}", 1, n, 3, []),
                     (f"c4p_{n}", 0, n, 2, ["-DLOOPPAD=24"])]
    variants += [(f"i1_{n}", 2, n, 2, []) for n in (0, 2, 4, 6, 8, 10, 12, 14, 16, 20, 24)]
    for name, mode, nops, enable, extra in variants:
        elf, binary = directory / f"{name}.elf", directory / f"{name}.bin"
        subprocess.run([tool("gcc"), "-march=rv32i", "-mabi=ilp32", "-nostdlib", "-nostartfiles",
                        "-Wl,-Ttext=0", "-Wl,--no-relax", f"-DMODE={mode}", f"-DNOPS={nops}",
                        f"-DENABLE={enable}", *extra, str(source), "-o", str(elf)], check=True)
        subprocess.run([tool("objcopy"), "-O", "binary", "-j", ".text", str(elf), str(binary)], check=True)
        data = binary.read_bytes()
        data += bytes(-len(data) % 4)
        words = [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)]
        if len(words) > 256:
            raise RuntimeError(f"{name}: {len(words)} words > 256-word IMEM")
        words += [0x13] * (256 - len(words))
        (directory / f"{name}.mem").write_text("".join(f"{w:08x}\n" for w in words), encoding="ascii")


def main():
    for stream in (sys.stdout, sys.stderr):
        try:  # simulator logs may contain non-cp1252 text; never crash while reporting
            stream.reconfigure(encoding="utf-8", errors="replace")
        except AttributeError:
            pass
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vivado-root", type=Path,
                        default=os.environ.get("XILINX_VIVADO"))
    parser.add_argument("--rtl-root", type=Path)
    parser.add_argument("--output", type=Path,
                        default=Path(__file__).resolve().parent.parent / "outfeed")
    parser.add_argument("--tests", nargs="+")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--vector-dir", type=Path,
                        help="FIR reference vectors for tb_fir11_vectors "
                             "(default: data_test/fir_test/output)")
    parser.add_argument("--outfeed-dir", type=Path,
                        help="where tb_fir11_vectors writes <test>/actual.dat "
                             "(default: <output>; with a custom "
                             "--vector-dir: <output>/tb_fir11_vectors/actual)")
    parser.add_argument("--wave", action="store_true",
                        help="elaborate with -debug typical and log all signals to "
                             "<output>/<test>/<test>.wdb")
    parser.add_argument("--no-firmware-build", action="store_true",
                        help="firmware tests: use the existing firmware/build[/<fw>]/*.mem "
                             "instead of rebuilding with GCC")
    parser.add_argument("--open-wave", metavar="TEST",
                        help="open <output>/TEST/TEST.wdb in the XSim GUI and exit "
                             "(run once with --wave first)")
    parser.add_argument("--fir-matrix", action="store_true", help="all six Timer/FIR datasets in B and C")
    parser.add_argument("--firmware-src", type=Path, help="alternate firmware sources for reproducible mutation tests")
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
        runtimes = list((vivado / "tps/win64").glob("python-*"))
        # Only the newest bundled JRE (Vivado's default, see bin/rdiArgs.bat):
        # an older JRE earlier on PATH makes the XSim GUI fail to create its JVM.
        jres = sorted((vivado / "tps/win64").glob("jre*"),
                      key=lambda p: [int(v) for v in re.findall(r"\d+", p.name)])
        if jres:
            runtimes.append(jres[-1])
            env["RDI_JAVAROOT"] = str(jres[-1])
        for runtime in runtimes:
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

    if args.open_wave:
        wdb = output / args.open_wave / f"{args.open_wave}.wdb"
        if not wdb.is_file():
            parser.error(f"{wdb} not found; run with --tests {args.open_wave} --wave first")
        # The GUI needs Vivado's full Tcl/Java setup, so go through the official
        # launcher (bin/xsim[.bat]) with the caller's environment, not the batch
        # environment above. It keeps running after this script exits.
        if os.name == "nt":
            command = ["cmd", "/c", str(vivado / "bin" / "xsim.bat"), "-gui", wdb.name]
        else:
            command = [str(vivado / "bin" / "xsim"), "-gui", wdb.name]
        subprocess.Popen(command, cwd=wdb.parent)
        print(f"Opening {wdb} in XSim GUI")
        return

    def run(tool, arguments, directory, log_name, require_pass=False, timeout=180):
        command = [str(binary / (tool + suffix)), *map(str, arguments)]
        result = subprocess.run(command, cwd=directory, env=env,
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, encoding="utf-8", errors="replace",
                                timeout=timeout)
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
            if any(token in line for token in ("TEST PASSED", "Checks:", "INFO CYC_CNT", "INFO VEC")):
                print(line)

    sources = []
    for filelist in ("filelist_fir11.f", "filelist_ext_ram_sim.f"):
        for line in (rtl / filelist).read_text(encoding="utf-8-sig").splitlines():
            line = line.strip()
            if line and not line.startswith(("//", "+")):
                sources.append(rtl / Path(line).relative_to("rtl"))
    vector_dir = (args.vector_dir or project / "data_test/fir_test/output").resolve()
    # RTL results of the official vectors: <output>/<test>/actual.dat (outfeed/);
    # runs on other vector sets stay in the testbench directory so they never mix.
    if args.outfeed_dir:
        outfeed_dir = args.outfeed_dir.resolve()
    elif args.vector_dir:
        outfeed_dir = output / "tb_fir11_vectors" / "actual"
    else:
        outfeed_dir = output
    if "tb_fir11_vectors" in (args.tests or ["tb_fir11_vectors"]):
        # xsim -testplusarg cannot carry spaces; it hangs instead of failing.
        for label, path in (("--vector-dir", vector_dir), ("--output", output),
                            ("--outfeed-dir", outfeed_dir)):
            if " " in str(path):
                parser.error(f"{label} must not contain spaces for tb_fir11_vectors: {path}")
    vector_tests = ("test_01_low", "test_02_high", "test_03_mixed",
                    "test_04_noise", "test_05_impulse", "test_06_step")
    tests = [
        ("tb_fir11_wrapper", []),
        ("tb_fir11_vectors", []),
        ("tb_axi_fir", []),
        ("tb_axi_fault", []),        # A1/A2: DECERR/SLVERR, ext-RAM timeout, backpressure
        ("tb_ext_ram_cfgA", []),
        ("tb_ext_ram_axi_b", ["USE_CACHE=0"]),
        ("tb_ext_ram_axi_c", ["USE_CACHE=1"]),
        ("tb_cpu_bus_b", ["USE_CACHE=0"]),
        ("tb_cpu_bus_c", ["USE_CACHE=1"]),
        ("tb_timer", []),
        ("tb_irq_ack", []),
        ("tb_cpu_fault_b", ["USE_CACHE=0"]),
        ("tb_cpu_fault_c", ["USE_CACHE=1"]),
        ("tb_id_ex_reg", []),
        ("tb_cpu_flush_hold_b", ["USE_CACHE=0"]),
        ("tb_cpu_flush_hold_c", ["USE_CACHE=1"]),
        # I1/C4: FIR IRQ vs late ACK, ACK right before mret (tb/asm/irq_dir.S images)
        ("tb_irq_i1", []),
        ("tb_cpu_irq_c4_a", ["EXT_RAM=0"]),
        ("tb_cpu_irq_c4_b", ["EXT_RAM=1", "USE_CACHE=0"]),
        ("tb_cpu_irq_c4_c", ["EXT_RAM=1", "USE_CACHE=1"]),
    ]
    default_tests = [name for name, _ in tests]
    # Optional: needs the RISC-V GCC toolchain, so it only runs when named.
    # Firmware testbench: build_firmware.py --firmware, image directory, image files,
    # testbench top, generics, extra data files (copied into the run directory), xsim timeout.
    images = ("program.mem", "data.mem")
    fw_build = project / "firmware" / "build"
    fir_1000_data = [project / "data_test" / "fir_1000" / f
                     for f in ("input.mem", "expected.mem", "layout.mem")]
    def firmware_test(fw, build, files=images, top=None, generics=(), data=(), timeout=180):
        return dict(fw=fw, build=build, files=files, top=top, generics=list(generics),
                    data=list(data), timeout=timeout)
    firmware_tests = {
        "tb_cpu_firmware": firmware_test("smoke", fw_build),
        "tb_cpu_fir_firmware": firmware_test("fir_smoke", fw_build / "fir_smoke"),
        "tb_cpu_fir_stream": firmware_test("fir_stream", fw_build / "fir_stream",
                                           images + ("symbols.mem",)),
        "tb_cpu_ext_ram_b": firmware_test("ext_ram_test", fw_build / "ext_ram_test",
                                          images + ("symbols.mem",), "tb_cpu_ext_ram",
                                          ["USE_CACHE=0"]),
        "tb_cpu_ext_ram_c": firmware_test("ext_ram_test", fw_build / "ext_ram_test",
                                          images + ("symbols.mem",), "tb_cpu_ext_ram",
                                          ["USE_CACHE=1"]),
        "tb_cpu_fir_1000": firmware_test("fir_1000", fw_build / "fir_1000",
                                         images + ("symbols.mem",), "tb_cpu_fir_1000",
                                         ["USE_CACHE=0"], fir_1000_data, 1800),
        "tb_cpu_fir_1000_c": firmware_test("fir_1000", fw_build / "fir_1000",
                                           images + ("symbols.mem",), "tb_cpu_fir_1000",
                                           ["USE_CACHE=1"], fir_1000_data, 1800),
        # Timer IRQ: firmware/timer_irq_test.c (startup_irq.S, vector 0x10, ISR, ACK, mret)
        "tb_cpu_timer_irq_a": firmware_test("timer_irq_test", fw_build / "timer_irq_test",
                                            images + ("symbols.mem",), "tb_cpu_timer_irq",
                                            ["EXT_RAM=0"]),
        "tb_cpu_timer_irq_b": firmware_test("timer_irq_test", fw_build / "timer_irq_test",
                                            images + ("symbols.mem",), "tb_cpu_timer_irq",
                                            ["EXT_RAM=1", "USE_CACHE=0"]),
        "tb_cpu_timer_irq_c": firmware_test("timer_irq_test", fw_build / "timer_irq_test",
                                            images + ("symbols.mem",), "tb_cpu_timer_irq",
                                            ["EXT_RAM=1", "USE_CACHE=1"]),
        # Giai đoạn 3: Timer IRQ 10 kHz -> 32 mẫu FIR, FIR IRQ (firmware/fir_timer.c);
        # _stress: PERIOD 100 clock, cố ý quá tải (tick gộp, trễ, Timer+FIR cùng pending)
        "tb_cpu_fir_timer": firmware_test("fir_timer", fw_build / "fir_timer",
                                          images + ("symbols.mem",), "tb_cpu_fir_timer",
                                          ["PERIOD=10000", "STRESS=0"]),
        "tb_cpu_fir_timer_stress": firmware_test("fir_timer_stress", fw_build / "fir_timer_stress",
                                                 images + ("symbols.mem",), "tb_cpu_fir_timer",
                                                 ["PERIOD=100", "STRESS=1"]),
        # Giai đoạn 4: Timer IRQ 10 kHz -> 1000 mẫu RAM ngoài -> FIR IRQ -> RAM ngoài (~10 M chu kỳ)
        "tb_cpu_fir_timer_1000_b": firmware_test("fir_timer_1000", fw_build / "fir_timer_1000",
                                                 images + ("symbols.mem",), "tb_cpu_fir_timer_1000",
                                                 ["USE_CACHE=0"], fir_1000_data, 3600),
        "tb_cpu_fir_timer_1000_c": firmware_test("fir_timer_1000", fw_build / "fir_timer_1000",
                                                 images + ("symbols.mem",), "tb_cpu_fir_timer_1000",
                                                 ["USE_CACHE=1"], fir_1000_data, 3600),
    }
    for cache, label in ((0, "b"), (1, "c")):
        base = firmware_tests[f"tb_cpu_fir_timer_1000_{label}"]
        for dataset in vector_tests:
            cfg = dict(base, dataset=dataset)
            firmware_tests[f"tb_cpu_fir_timer_1000_{label}_{dataset}"] = cfg
        firmware_tests[f"tb_cpu_fir_timer_1000_stress_{label}"] = dict(base,
            fw="fir_timer_1000_stress", generics=[f"USE_CACHE={cache}", "PERIOD=100", "STRESS=1"])
        firmware_tests[f"tb_cpu_fir_timer_1000_timing_fault_{label}"] = dict(base,
            generics=[f"USE_CACHE={cache}", "ACCEPT_HOLD=400"])
        firmware_tests[f"tb_cpu_fir_timer_1000_jitter_fault_{label}"] = dict(base,
            generics=[f"USE_CACHE={cache}", "ACCEPT_HOLD=200"])
        firmware_tests[f"tb_cpu_fir_timer_1000_reset_{label}"] = dict(base,
            generics=[f"USE_CACHE={cache}", "RESET_TEST=1"])
        firmware_tests[f"tb_cpu_fir_timer_1000_late_{label}"] = dict(base,
            generics=[f"USE_CACHE={cache}", "LATE_LAST=1"])
    tests += [(name, cfg["generics"]) for name, cfg in firmware_tests.items()]
    selected = args.tests or ([] if args.fir_matrix else default_tests)
    if args.fir_matrix:
        selected += [f"tb_cpu_fir_timer_1000_{label}_{dataset}"
                     for dataset in vector_tests for label in ("b", "c")]
    unknown = set(selected) - {name for name, _ in tests}
    if unknown:
        parser.error(f"Unknown tests: {sorted(unknown)}")
    for name, generics in tests:
        if name not in selected:
            continue
        top = ((firmware_tests[name]["top"] or name) if name in firmware_tests else
               "tb_cpu_fault" if name.startswith("tb_cpu_fault_") else
               "tb_cpu_flush_hold" if name.startswith("tb_cpu_flush_hold_") else
               "tb_cpu_bus" if name.startswith("tb_cpu_bus_") else
               "tb_cpu_irq_c4" if name.startswith("tb_cpu_irq_c4_") else
               "tb_ext_ram_axi" if generics else name)
        directory = output / name
        directory.mkdir(parents=True, exist_ok=True)
        for data in (rtl / "Peripherals/FIR11").glob("*.dat"):
            shutil.copy2(data, directory / data.name)
        if top in ("tb_cpu_bus", "tb_cpu_fault", "tb_cpu_flush_hold"):
            # Empty memory fixtures for the CPU's readmemh; the testbench
            # installs directed instructions after time-zero initialization.
            (directory / "program.mem").write_text("00000013\n" * 256, encoding="ascii")
            (directory / "data.mem").write_text("00000000\n" * 256, encoding="ascii")
        if top == "tb_cpu_irq_c4":
            (directory / "program.mem").write_text("00000013\n" * 256, encoding="ascii")
            (directory / "data.mem").write_text("00000000\n" * 256, encoding="ascii")
            assemble_irq_images(vivado.parent / "gnu" / "riscv" / "nt" / "bin",
                                project / "tb" / "asm" / "irq_dir.S", directory)
        sim_timeout = 180
        if name in firmware_tests:
            # GCC image, never the NOP fixtures above. Build first so the image
            # always matches firmware/ sources (toolchain next to Vivado).
            cfg = firmware_tests[name]
            firmware, firmware_build, firmware_files = cfg["fw"], cfg["build"], cfg["files"]
            sim_timeout = cfg["timeout"]
            source_dir = args.firmware_src
            if top == "tb_cpu_fir_timer_1000":
                if args.no_firmware_build:
                    raise RuntimeError("Timer/FIR 1000 requires rebuild with its run-specific dataset header")
                # Generate all fixtures AND the firmware header together in this run directory.
                # Never reuse a tracked noise checksum with a different input or expected file.
                from gen_fir_1000_data import build as build_vectors
                files, _, _ = build_vectors(cfg.get("dataset", "test_04_noise"))
                source_dir = directory / "firmware_src"
                source_dir.mkdir(exist_ok=True)
                for source in (args.firmware_src or project / "firmware").iterdir():
                    if source.suffix in (".c", ".h", ".S", ".ld"):
                        shutil.copy2(source, source_dir / source.name)
                for filename, contents in files.items():
                    target = source_dir / filename if filename.endswith(".h") else directory / filename
                    target.write_text(contents, encoding="utf-8", newline="\n")
                firmware_build = directory / "firmware_build"
            for data in ([] if top == "tb_cpu_fir_timer_1000" else cfg["data"]):
                if not data.is_file():
                    raise RuntimeError(f"{data} missing; run scripts/gen_fir_1000_data.py")
                shutil.copy2(data, directory / data.name)
            if not args.no_firmware_build:
                toolchain = vivado.parent / "gnu" / "riscv" / "nt" / "bin"
                command = [sys.executable, str(project / "scripts" / "build_firmware.py"),
                           "--firmware", firmware, "--out", str(firmware_build)]
                if source_dir:
                    command += ["--src", str(source_dir)]
                if toolchain.is_dir():
                    command += ["--toolchain", str(toolchain)]
                print("Building firmware", flush=True)
                if subprocess.run(command).returncode != 0:
                    raise RuntimeError(f"firmware build failed; see {firmware_build / 'build_report.txt'}")
            for image in firmware_files:
                if not (firmware_build / image).is_file():
                    raise RuntimeError(f"{firmware_build / image} missing; run scripts/build_firmware.py")
                shutil.copy2(firmware_build / image, directory / image)
        artifacts = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in directory.glob("*.mem")}
        source_hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in [project / "tb" / (top + ".v"), *sources]}
        if name in firmware_tests and source_dir:
            source_hashes.update({"firmware/" + p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                for p in source_dir.iterdir() if p.suffix in (".c", ".h", ".S", ".ld")})
        (directory / "provenance.json").write_text(json.dumps(dict(test=name, top=top,
            generics=generics, seed=args.seed, artifacts=artifacts, sources=source_hashes), indent=2), encoding="utf-8")
        plusargs = [f"seed={args.seed}"]
        if top == "tb_fir11_vectors":
            # Reference vectors are read in place; actual.dat goes to <outfeed>/<test>/.
            for vector_test in vector_tests:
                (outfeed_dir / vector_test).mkdir(parents=True, exist_ok=True)
            plusargs += [f"VEC_DIR={vector_dir.as_posix()}", f"OUT_DIR={outfeed_dir.as_posix()}"]
        print(f"Running {name}", flush=True)
        run("xvlog", ["-i", rtl / "packages", "-i", project / "tb",
                      *sources, project / "tb" / (top + ".v")], directory, "compile.log")
        options = [top, "-s", name, "-mt", "2"]
        if args.wave:
            options += ["-debug", "typical"]
        for generic in generics:
            options.extend(["-generic_top", generic])
        run("xelab", options, directory, "elaborate.log")
        if args.wave:
            (directory / "wave.tcl").write_text("log_wave -r /\nrun -all\nquit\n", encoding="ascii")
            sim_args = [name, "-tclbatch", "wave.tcl", "-wdb", f"{name}.wdb"]
        else:
            sim_args = [name, "-runall"]
        for plusarg in plusargs:
            sim_args += ["-testplusarg", plusarg]
        run("xsim", sim_args, directory, "simulate.log", require_pass=True, timeout=sim_timeout)
        # xsim keeps a backup of the previous xsim.jou/log on every rerun;
        # simulate.log already holds the full output.
        for backup in directory.glob("xsim_*.backup.*"):
            backup.unlink()
    print(f"PASS: {len(selected)} test configuration(s)")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
