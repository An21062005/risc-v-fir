'Exercise the actual generated BD with the existing SoC scoreboards.'

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys

from gen_fir_1000_data import build as build_vectors
from vivado_tools import run


# Original verification names -> the actual Vivado module-reference hierarchy.
PATHS = {
    "u_cpu": "CPU.inst.u_cpu", "u_axi_master": "AXI_Master.inst.u_axi_master",
    "u_interconnect": "Interconnect.inst.u_interconnect",
    "u_fir": "FIR_Accelerator.inst.u_fir", "u_timer": "Timer.inst.u_timer",
    "u_int_ctrl": "Interrupt.inst.u_int_ctrl", "u_int_regs": "Interrupt.inst.u_int_regs",
    "g_ext_ram": "External_RAM.inst", "rst_n_sync": "Reset.inst.rst_n_out",
    "bus_rd": "CPU.inst.m_read", "bus_wr": "CPU.inst.m_write",
    "bus_addr": "CPU.inst.m_addr", "bus_wdata": "CPU.inst.m_wdata",
    "bus_rdata": "CPU.inst.m_rdata", "bus_ready": "CPU.inst.m_ready",
    "write_addr": "Interconnect.inst.write_addr", "read_addr": "Interconnect.inst.read_addr",
    "write_data": "Interconnect.inst.write_data",
    "timer_irq": "Timer.inst.irq", "fir_irq": "FIR_Accelerator.inst.irq",
}
for name in ("irq_pending", "irq_enable", "irq_ack", "irq_ack_id", "irq_claim", "irq_id"):
    PATHS[name] = "Interrupt.inst." + name
for name in ("timer_wr_en", "timer_rd_en", "fir_wr_en", "fir_rd_en"):
    PATHS[name] = "Interconnect.inst." + name
for signal in ("awaddr", "awvalid", "awready", "wdata", "wstrb", "wvalid", "wready",
               "bresp", "bvalid", "bready", "araddr", "arvalid", "arready",
               "rdata", "rresp", "rvalid", "rready"):
    PATHS["axi_" + signal] = "Interconnect.inst.s_axi_" + signal
for signal in ("read", "write", "addr", "wdata", "rdata", "ready"):
    PATHS["ext_ram_" + signal] = "Interconnect.inst.ram_" + signal
for signal in ("valid", "write", "resp", "addr", "overflow", "clr"):
    PATHS["buserr_" + signal] = "AXI_Master.inst.err_" + signal


def remap(text):
    def replace(match):
        name = match[1]
        if name not in PATHS:
            raise ValueError(f"Unmapped scoreboard reference: dut.{name}")
        return "dut.soc_system_i." + PATHS[name]
    return re.sub(r"\bdut\.([A-Za-z_]\w*)", replace, text)


def adapt(text, cache, reference=False):
    text, count = re.subn(
        r"soc_top\s*#\([^;]*?\)\s+dut\s*\(", "soc_system_wrapper dut (", text, count=1)
    if count != 1:
        raise ValueError("Expected exactly one parameterized soc_top DUT")
    # Add a reference SoC and identical RAM preloads for the main application.
    if reference:
        preload = re.compile(r"(?m)^(\s*)(dut\.g_ext_ram\.[^\n;]*\.memory\[[^\n;]+\]\s*=(?!=)[^\n;]+;)")
        text = preload.sub(lambda m: m[0] + "\n" + m[1] + m[2].replace("dut.", "reference.", 1), text)
    text = remap(text)
    if reference:
        signals = ["rst_n_sync", "bus_rd", "bus_wr", "bus_addr", "bus_wdata", "bus_rdata", "bus_ready",
                   "axi_awvalid", "axi_awready", "axi_wvalid", "axi_wready", "axi_bvalid", "axi_bresp",
                   "axi_arvalid", "axi_arready", "axi_rvalid", "axi_rresp", "axi_rdata",
                   "timer_irq", "fir_irq", "irq_pending", "irq_ack", "irq_ack_id",
                   "ext_ram_read", "ext_ram_write", "ext_ram_ready", "ext_ram_rdata",
                   "buserr_valid", "buserr_addr", "u_cpu.pc"]
        compare = []
        for name in signals:
            compare.append(f'''        if ({remap("dut." + name)} !== reference.{name}) begin
            $display("ERROR BD/reference mismatch: {name}, cycle %0d", cyc);
            $fatal(1, "Block Design changed cycle behavior");
        end''')
        extra = f'''
    // The same firmware and RAM input drive an independent original RTL SoC.
    soc_top #(.ENABLE_EXT_RAM(1), .EXT_RAM_USE_CACHE({cache})) reference (
        .clk(clk), .rst_n(rst_n), .cpu_irq(), .bus_error()
    );
    always @(negedge clk) if (rst_n) begin
{chr(10).join(compare)}
    end
'''
        text = text.replace("endmodule", extra + "\nendmodule")
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vivado-root", type=Path, required=True)
    parser.add_argument("--cfg", choices=("A", "B", "C"), default="C")
    parser.add_argument("--build-dir", type=Path)
    parser.add_argument("--tests", nargs="+", choices=("application", "fault", "reset", "elaborate"))
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    bd = (args.build_dir or repo / "outfeed/block_design" / args.cfg).resolve()
    manifest = bd / "simulation_sources.txt"
    if not manifest.is_file():
        parser.error("Build the BD first with scripts/run_block_design.py")
    cache = int(args.cfg == "C")
    tests = args.tests or (["elaborate"] if args.cfg == "A" else ["application", "fault"])
    if args.cfg == "A" and set(tests) != {"elaborate"}:
        parser.error("The main firmware requires external RAM; use --cfg B or C")
    sources = [Path(p) for p in manifest.read_text().splitlines() if p.strip()]
    sources.append(repo / "rtl/soc_top.v")
    results = []
    for test in tests:
        out = bd / "checks" / test
        out.mkdir(parents=True, exist_ok=True)
        if test in ("application", "reset"):
            original = repo / "tb/tb_cpu_fir_timer_1000.v"
            bench = adapt(original.read_text(encoding="utf-8"), cache, reference=test == "application")
            top = "tb_cpu_fir_timer_1000"
            fixtures, _, _ = build_vectors("test_04_noise")
            source = out / "firmware_src"
            source.mkdir(exist_ok=True)
            for f in (repo / "firmware").iterdir():
                if f.suffix in (".c", ".h", ".S", ".ld"):
                    shutil.copy2(f, source / f.name)
            for name, content in fixtures.items():
                (source / name if name.endswith(".h") else out / name).write_text(content, encoding="utf-8")
            fw = out / "firmware_build"
            subprocess.run([sys.executable, str(repo / "scripts/build_firmware.py"), "--src", str(source),
                            "--out", str(fw), "--toolchain", str(args.vivado_root.parent / "gnu/riscv/nt/bin")],
                           check=True)
            for name in ("program.mem", "data.mem", "symbols.mem"):
                shutil.copy2(fw / name, out / name)
            generics = ["-generic_top", f"USE_CACHE={cache}"]
            if test == "reset":
                generics += ["-generic_top", "RESET_TEST=1"]
        elif test == "fault":
            original = repo / "tb/tb_cpu_fault.v"
            bench = adapt(original.read_text(encoding="utf-8"), cache)
            top, generics = "tb_cpu_fault", ["-generic_top", f"USE_CACHE={cache}"]
        else:
            original = None
            top, generics = "tb_bd_elaborate", []
            bench = '''`timescale 1ns/1ps
module tb_bd_elaborate;
    reg clk = 0, rst_n = 0;
    wire irq, bus_error;
    always #5 clk = ~clk;
    soc_system_wrapper dut (.clk(clk), .rst_n(rst_n), .cpu_irq(irq), .bus_error(bus_error));
    initial begin
        repeat (5) @(negedge clk);
        if (dut.soc_system_i.CPU.inst.u_cpu.pc !== 0 || irq !== 0 || bus_error !== 0)
            $fatal(1, "Reset smoke check failed");
        rst_n = 1;
        repeat (10) @(negedge clk);
        if (dut.soc_system_i.Reset.inst.rst_n_out !== 1)
            $fatal(1, "Synchronized reset did not release");
        $display("TEST PASSED: generated BD elaboration and reset");
        $finish;
    end
endmodule
'''
        if test not in ("application", "reset"):
            (out / "program.mem").write_text("00000013\n" * 256)
            (out / "data.mem").write_text("00000000\n" * 256)
        for f in (repo / "rtl/Peripherals/FIR11").glob("*.dat"):
            shutil.copy2(f, out / f.name)
        tb = out / f"{top}.v"
        tb.write_text(bench, encoding="utf-8")
        run(args.vivado_root, "xvlog", ["-i", repo / "rtl/packages", *sources, tb], out, "compile.log", 180)
        run(args.vivado_root, "xelab", [top, "-s", "bd_check", "-mt", "2", *generics], out, "elaborate.log", 180)
        text = run(args.vivado_root, "xsim", ["bd_check", "-runall"], out, "simulate.log", 3600)
        if "TEST PASSED" not in text or re.search(r"(?m)^ERROR\b|TEST FAILED", text):
            raise RuntimeError(f"Scoreboard failed: {out / 'simulate.log'}")
        recorded = [*sources, tb, *out.glob("*.mem")]
        if original is not None:
            recorded.append(original)
        hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in recorded}
        result = dict(test=test, config=args.cfg, passed=True, original_testbench=str(original),
                      reference_lockstep=test == "application", source_and_fixture_sha256=hashes)
        (out / "provenance.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
        print("\n".join(s for s in text.splitlines() if "TEST PASSED" in s or "Checks:" in s))
        results.append(dict(test=test, passed=True))
    summary = bd / "checks/result.json"
    previous = json.loads(summary.read_text()) if summary.is_file() else []
    by_test = {r["test"]: r for r in previous}
    by_test.update({r["test"]: r for r in results})
    summary.write_text(json.dumps(list(by_test.values()), indent=2))
    print(f"BD CHECKS PASSED: {args.cfg}: {', '.join(tests)}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        sys.exit(str(exc))
