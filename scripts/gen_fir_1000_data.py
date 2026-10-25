#!/usr/bin/env python3
# -*- coding: utf-8 -*-
'gen_fir_1000_data.py - dữ liệu cho firmware/fir_timer_1000.c và tb/tb_cpu_fir_timer_1000.v.'

import argparse
import hashlib
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
COEF = [54, 0, -92, 0, 313, 500, 313, 0, -92, 0, 54]


def s32(v):
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v & 0x80000000 else v


def fir_model(xs, taps=COEF):
    hist = [0] * len(taps)
    out = []
    for x in xs:
        hist = [x] + hist[:-1]
        acc = 0
        for c, h in zip(taps, hist):
            acc = s32(acc + s32(c * h))
        out.append(acc)
    return out


N = 1000
IN_ADDR = 0x4001_0000
OUT_ADDR = 0x4001_1000
EXT_RAM_LO, EXT_RAM_HI = 0x4001_0000, 0x4001_FFFF
OUT_DIR = PROJECT / "data_test" / "fir_1000"
HEADER = PROJECT / "firmware" / "fir_1000_data.h"


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def u32(v):
    return v & 0xFFFFFFFF


def read_dat(path):
    return [int(line) for line in Path(path).read_text(encoding="utf-8").split()]


def build(test):
    src_dir = PROJECT / "data_test" / "fir_test" / "output" / test
    src_in, src_exp = src_dir / "input.dat", src_dir / "expected.dat"
    xs_all = read_dat(src_in)
    if len(xs_all) < N:
        raise SystemExit(f"{src_in}: chỉ có {len(xs_all)} mẫu, cần {N}")
    xs = xs_all[:N]
    if not all(-2**31 <= x < 2**31 for x in xs):
        raise SystemExit("mẫu vượt int32")
    ys = fir_model(xs)
    ref = read_dat(src_exp)[:N]
    match = sum(1 for a, b in zip(ys, ref) if a == b)
    if match != N:
        raise SystemExit(f"mô hình #1 lệch expected.dat của bộ dữ liệu: {match}/{N} mẫu khớp")

    assert IN_ADDR % 4 == 0 and OUT_ADDR % 4 == 0
    assert EXT_RAM_LO <= IN_ADDR and IN_ADDR + 4 * N - 1 <= EXT_RAM_HI
    assert EXT_RAM_LO <= OUT_ADDR and OUT_ADDR + 4 * N - 1 <= EXT_RAM_HI
    assert IN_ADDR + 4 * N <= OUT_ADDR or OUT_ADDR + 4 * N <= IN_ADDR, "input/output chồng lấn"

    exp_sum = u32(sum(ys))
    exp_xor = 0
    for y in ys:
        exp_xor ^= u32(y)
    in_sum = u32(sum(xs))

    mem = lambda vals: "".join(f"{u32(v):08x}\n" for v in vals)
    files = {
        "input.mem": mem(xs),
        "expected.mem": mem(ys),
        "layout.mem": "".join(f"{v:08x} // {n}\n" for n, v in (
            ("IN_ADDR", IN_ADDR), ("OUT_ADDR", OUT_ADDR), ("N", N),
            ("EXP_SUM", exp_sum), ("EXP_XOR", exp_xor), ("IN_SUM", in_sum))),
    }
    digest = {n: hashlib.sha256(t.encode()).hexdigest() for n, t in files.items()}
    rel = lambda p: p.relative_to(PROJECT).as_posix()
    files["manifest.txt"] = "\n".join([
        "FIR 1000 mẫu - dữ liệu luồng chính (SINH TỰ ĐỘNG bởi scripts/gen_fir_1000_data.py)",
        f"Nguồn input    : {rel(src_in)}  mẫu [0, {N})  sha256 {sha256(src_in)}",
        f"Đối chiếu      : {rel(src_exp)}  {match}/{N} mẫu khớp mô hình #1  sha256 {sha256(src_exp)}",
        f"Hệ số          : {COEF} (hls/FIR11/FIR11/fir.cpp)",
        "Mô hình        : y[n] = sum c[k]*x[n-k], lịch sử đầu = 0, int32 wrap modulo 2^32",
        f"Số mẫu         : {N}",
        f"x              : min {min(xs)}, max {max(xs)}, {sum(1 for x in xs if x < 0)} âm, "
        f"{sum(1 for x in xs if x == 0)} bằng 0",
        f"y              : min {min(ys)}, max {max(ys)}",
        f"IN_ADDR        : 0x{IN_ADDR:08x} .. 0x{IN_ADDR + 4 * N - 1:08x}",
        f"OUT_ADDR       : 0x{OUT_ADDR:08x} .. 0x{OUT_ADDR + 4 * N - 1:08x}",
        f"IN_SUM         : 0x{in_sum:08x}  (tổng x mod 2^32)",
        f"EXP_SUM        : 0x{exp_sum:08x}  (tổng y mod 2^32)",
        f"EXP_XOR        : 0x{exp_xor:08x}  (XOR các y)",
        *[f"sha256 {n:<13}: {d}" for n, d in digest.items()],
        "",
        "Nạp dữ liệu: MÔ PHỎNG - tb/tb_cpu_fir_timer_1000.v ghi input.mem vào sdram_model trước khi thả reset",
        "(sdram_model không có $readmemh). FPGA thật cần cơ chế khác (bootloader/UART/DMA hoặc BRAM",
        "khởi tạo), chưa có trong SoC.",
        "",
    ])
    files["fir_1000_data.h"] = "\n".join([
        "/* fir_1000_data.h - SINH TỰ ĐỘNG bởi scripts/gen_fir_1000_data.py, không sửa tay. */",
        f"/* Nguồn: {rel(src_in)} mẫu [0, {N}), xem data_test/fir_1000/manifest.txt */",
        "#ifndef FIR_1000_DATA_H", "#define FIR_1000_DATA_H", "",
        f"#define FIR1000_N        {N}",
        f"#define FIR1000_IN_ADDR  0x{IN_ADDR:08X}u   /* input[{N}] trong RAM ngoài */",
        f"#define FIR1000_OUT_ADDR 0x{OUT_ADDR:08X}u   /* output[{N}] trong RAM ngoài */",
        f"#define FIR1000_IN_SUM   0x{in_sum:08X}u   /* tổng x mod 2^32: kiểm dữ liệu vào */",
        f"#define FIR1000_EXP_SUM  0x{exp_sum:08X}u   /* tổng y kỳ vọng mod 2^32 */",
        f"#define FIR1000_EXP_XOR  0x{exp_xor:08X}u   /* XOR y kỳ vọng */",
        "", "#endif", "",
    ])
    return files, xs, ys


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except AttributeError:
        pass
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--test", default="test_04_noise")
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    files, xs, ys = build(args.test)
    target = lambda n: HEADER if n == "fir_1000_data.h" else OUT_DIR / n
    if args.check:
        bad = [n for n, t in files.items()
               if not target(n).is_file() or target(n).read_text(encoding="utf-8") != t]
        print("khớp" if not bad else f"LỆCH: {bad} - chạy lại không có --check")
        return 1 if bad else 0
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for n, t in files.items():
        target(n).write_text(t, encoding="utf-8", newline="\n")
        print(f"Ghi {target(n).relative_to(PROJECT).as_posix()}")
    print(files["manifest.txt"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
