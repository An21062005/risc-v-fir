"""Local Vivado tool environment shared by the Block Design build and checks."""

import os
from pathlib import Path
import re
import subprocess


def environment(vivado):
    env = os.environ.copy()
    if os.name != "nt":
        return env
    vivado = Path(vivado).resolve()
    paths = [vivado / "lib/win64.o", vivado / "bin/unwrapped/win64.o", vivado / "bin"]
    runtimes = list((vivado / "tps/win64").glob("python-*"))
    jres = sorted((vivado / "tps/win64").glob("jre*"),
                  key=lambda p: [int(v) for v in re.findall(r"\d+", p.name)])
    if jres:
        runtimes.append(jres[-1])
        env["RDI_JAVAROOT"] = str(jres[-1])
    for runtime in runtimes:
        paths.extend([runtime, runtime / "DLLs", runtime / "bin", runtime / "bin/server"])
    env["PATH"] = os.pathsep.join(map(str, paths)) + os.pathsep + env.get("PATH", "")
    for name, relative in {
        "XILINX_VIVADO": ".", "RDI_APPROOT": ".", "HDI_APPROOT": ".",
        "RDI_BASEROOT": "..", "RDI_BINROOT": "bin", "RDI_BINDIR": "bin",
        "RDI_LIBDIR": "lib/win64.o", "RDI_DATADIR": "data",
        "TCL_LIBRARY": "tps/tcl/tcl8.6", "RT_LIBPATH": "scripts/rt/data",
        "RT_TCL_PATH": "scripts/rt/base_tcl/tcl",
    }.items():
        env[name] = (vivado / relative).resolve().as_posix()
    env["RDI_PROG"] = (vivado / "bin/unwrapped/win64.o/vivado.exe").as_posix()
    env["RDI_PLATFORM"] = "win64"
    env["RDI_OPT_EXT"] = ".o"
    return env


def run(vivado, tool, args, directory, log_name, timeout=None):
    vivado, directory = Path(vivado).resolve(), Path(directory).resolve()
    binary = vivado / ("bin/unwrapped/win64.o" if os.name == "nt" else "bin")
    command = [str(binary / (tool + (".exe" if os.name == "nt" else ""))), *map(str, args)]
    directory.mkdir(parents=True, exist_ok=True)
    log = directory / log_name
    print(f"Running {tool}; log: {log}", flush=True)
    with log.open("w", encoding="utf-8") as stream:
        result = subprocess.run(command, cwd=directory, env=environment(vivado),
                                stdout=stream, stderr=subprocess.STDOUT, timeout=timeout)
    text = log.read_text(encoding="utf-8", errors="replace")
    if result.returncode or re.search(r"(?im)^\s*(?:ERROR:|FATAL:|TEST FAILED)", text):
        raise RuntimeError(f"{tool} failed (exit {result.returncode}); see {log}\n{text[-6000:]}")
    return text
