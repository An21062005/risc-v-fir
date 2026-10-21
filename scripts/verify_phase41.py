"""Reproduce phase 4.1 XSim verification; expected-red mutations have specific log gates."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

PROJECT = Path(__file__).resolve().parent.parent
DATASETS = ("test_01_low", "test_02_high", "test_03_mixed", "test_04_noise", "test_05_impulse", "test_06_step")
REGRESSION = """tb_fir11_wrapper tb_fir11_vectors tb_axi_fir tb_ext_ram_cfgA
tb_ext_ram_axi_b tb_ext_ram_axi_c tb_cpu_bus_b tb_cpu_bus_c tb_timer
tb_irq_ack tb_cpu_fault_b tb_cpu_fault_c tb_cpu_firmware tb_cpu_fir_firmware
tb_cpu_fir_stream tb_cpu_ext_ram_b tb_cpu_ext_ram_c tb_cpu_fir_1000 tb_cpu_fir_1000_c
tb_cpu_timer_irq_a tb_cpu_timer_irq_b tb_cpu_timer_irq_c tb_cpu_fir_timer
tb_cpu_fir_timer_stress tb_cpu_fir_timer_1000_b tb_cpu_fir_timer_1000_c""".split()


def validate_artifacts(directory, dataset="test_04_noise"):
    """Check provenance and every actual sample against freshly generated references."""
    from gen_fir_1000_data import build
    files, _, expected = build(dataset)
    for name in ("input.mem", "expected.mem", "layout.mem", "manifest.txt"):
        if (directory / name).read_text(encoding="utf-8") != files[name]:
            raise RuntimeError(f"stale/wrong dataset artifact: {directory / name}")
    if (directory / "firmware_src/fir_1000_data.h").read_text(encoding="utf-8") != files["fir_1000_data.h"]:
        raise RuntimeError(f"stale firmware dataset header: {directory}")
    actual = [int(v) for v in (directory / "actual.dat").read_text().split()]
    if actual != expected:
        raise RuntimeError(f"actual.dat differs from reference: {directory}")
    provenance = json.loads((directory / "provenance.json").read_text())
    for name, digest in provenance["artifacts"].items():
        if hashlib.sha256((directory / name).read_bytes()).hexdigest() != digest:
            raise RuntimeError(f"image/fixture hash changed: {directory / name}")
    return dict(dataset=dataset, matched_samples=len(actual), artifacts=provenance["artifacts"])


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--vivado-root", required=True, type=Path)
    ap.add_argument("--output", type=Path, default=PROJECT / "outfeed/phase41")
    ap.add_argument("--suite", choices=("matrix", "special", "regression", "mutations"), required=True)
    ap.add_argument("--jobs", type=int, default=3)
    args = ap.parse_args()
    output = args.output.resolve() / args.suite
    output.mkdir(parents=True, exist_ok=True)
    jobs = []
    if args.suite == "matrix":
        jobs = [(f"tb_cpu_fir_timer_1000_{cache}_{data}", [], None)
                for data in DATASETS for cache in ("b", "c")]
    elif args.suite == "special":
        jobs = [(f"tb_cpu_fir_timer_1000_{case}_{cache}", [], None)
                for case in ("stress", "reset", "late") for cache in ("b", "c")]
    elif args.suite == "regression":
        # A single runner serializes builds of shared legacy firmware images.
        jobs = [("regression", ["--tests", *REGRESSION], None)]
    else:
        sources = output / "stopped_clock_sources"
        sources.mkdir(exist_ok=True)
        for src in (PROJECT / "firmware").iterdir():
            if src.suffix in (".c", ".h", ".S", ".ld"):
                shutil.copy2(src, sources / src.name)
        header = sources / "fir_timer_isr.h"
        text = header.read_text(encoding="utf-8")
        old = """        if (t >= FT_N) {
            t = FT_N;
            INT_ENABLE = 2u;                /* stop scheduling IRQs; keep deadline clock running */
        }"""
        assert old in text
        text = text.replace(old, "        if (t >= FT_N) TIMER_CTRL = 0;")
        final_stop = """        if (d + 1 == FT_N)
            TIMER_CTRL = 0;                 /* only stop AFTER final store and live deadline read */
"""
        assert final_stop in text
        header.write_text(text.replace(final_stop, ""), encoding="utf-8")
        jobs.append(("deadline_old", ["--tests", "tb_cpu_fir_timer_1000_late_b",
                    "--firmware-src", str(sources)], "firmware detects final output miss"))
        jobs.append(("fixed_budgets", ["--tests", "tb_cpu_fir_timer_1000_timing_fault_b"],
                    ["ERROR fixed tick -> accept budget", "ERROR fixed tick -> stored budget",
                     "ERROR fixed accept jitter budget"]))
        jobs.append(("jitter_only", ["--tests", "tb_cpu_fir_timer_1000_jitter_fault_b"],
                    "ERROR fixed accept jitter budget"))
        rtl = output / "wrong_ack_rtl"
        shutil.copytree(PROJECT / "rtl", rtl, dirs_exist_ok=True)
        controller = rtl / "Peripherals/Interrupt_controller.v"
        text = controller.read_text(encoding="utf-8")
        assert "(ack_id == i)" in text
        controller.write_text(text.replace("(ack_id == i)", "(interrupt_id == i)"), encoding="utf-8")
        jobs.append(("wrong_ack", ["--tests", "tb_irq_ack", "--rtl-root", str(rtl)], "ERROR pending/priority"))

    def run(job):
        name, extra, expected_failure = job
        directory = output / name
        directory.mkdir(exist_ok=True)
        command = [sys.executable, str(PROJECT / "scripts/run_rtl_tests.py"),
                   "--vivado-root", str(args.vivado_root), "--output", str(directory)]
        command += extra or ["--tests", name]
        result = subprocess.run(command, cwd=PROJECT, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT, encoding="utf-8", errors="replace")
        (directory / "runner.log").write_text(result.stdout, encoding="utf-8")
        if expected_failure:
            required = [expected_failure] if isinstance(expected_failure, str) else expected_failure
            success = result.returncode == 1 and all(s in result.stdout for s in required) and "TEST FAILED" in result.stdout
        else:
            success = result.returncode == 0 and "TEST PASSED" in result.stdout
        artifact_check = None
        if success and not expected_failure and name.startswith("tb_cpu_fir_timer_1000"):
            dataset = next((d for d in DATASETS if name.endswith(d)), "test_04_noise")
            try:
                artifact_check = validate_artifacts(directory / name, dataset)
            except (OSError, RuntimeError, ValueError) as exc:
                print(f"FAIL artifacts {name}: {exc}", flush=True)
                success = False
        record = dict(test=name, passed=success, expected_failure=expected_failure,
                      returncode=result.returncode, log=str(directory / "runner.log"), artifacts=artifact_check)
        print(f"{'PASS' if success else 'FAIL'} {name}" + (" (expected rejection)" if expected_failure else ""), flush=True)
        return record

    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        records = list(pool.map(run, jobs))
    (output / "summary.json").write_text(json.dumps(records, indent=2), encoding="utf-8")
    return 0 if all(r["passed"] for r in records) else 1


if __name__ == "__main__":
    sys.exit(main())
