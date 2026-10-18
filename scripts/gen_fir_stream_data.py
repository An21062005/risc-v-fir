#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_fir_stream_data.py - sinh firmware/fir_stream_data.h cho firmware Bước 3 (fir_stream.c).

  FIR_STREAM_INPUT     32 mẫu int32 có dấu (dương, âm, 0, đổi dấu liên tiếp, giá trị gây tràn)
  FIR_STREAM_EXPECTED  y[n] = sum_{k=0..10} c[k] * x[n-k], lịch sử ban đầu = 0
                       (firmware đẩy 10 mẫu 0 trước), số học modulo 2^32 như RTL HLS:
                       bộ nhân fir_mul_11s_32s_32 cắt 32 bit, acc 32 bit, c[0]*x = (x<<6)-(x<<3)-(x<<1).

Hệ số lấy từ hls/FIR11/FIR11/fir.cpp, thứ tự c[k] nhân với shift_reg[k] = x[n-k]
(Shift_Accum_Loop: địa chỉ ROM = địa chỉ shift_reg = i).

Đây là mô hình tham chiếu #1 (Python) cho firmware tự kiểm tra; testbench
tb/tb_cpu_fir_stream.v có mô hình #2 viết riêng bằng Verilog.

Chạy:  python scripts/gen_fir_stream_data.py          (ghi header)
       python scripts/gen_fir_stream_data.py --check  (chỉ so sánh, exit 1 nếu header lệch)
"""

import argparse
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
HEADER = PROJECT / "firmware" / "fir_stream_data.h"

COEF = [54, 0, -92, 0, 313, 500, 313, 0, -92, 0, 54]

INPUT = [
    0, 1, -1, 7, -7, 100, -100, 0,
    0, 2047, -2048, 12345, -12345, 32767, -32768, 0,
    1000000, -1000000, 5, 5, 5, 5, 0x7FFFFFFF, -0x80000000,
    3, -3, 3, -3, 65536, -65536, 0, 42,
]


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


def c_int(v):
    # -2^31 không viết được trực tiếp dạng literal int trong C
    return "(-2147483647 - 1)" if v == -0x80000000 else str(v)


def render():
    exp = fir_model(INPUT)
    fmt = lambda vals: ",".join(("\\\n    " if i % 8 == 0 else " ") + c_int(v) for i, v in enumerate(vals))
    return (
        "/* fir_stream_data.h - SINH TỰ ĐỘNG bởi scripts/gen_fir_stream_data.py, không sửa tay. */\n"
        "#ifndef FIR_STREAM_DATA_H\n#define FIR_STREAM_DATA_H\n\n"
        f"#define FIR_STREAM_N {len(INPUT)}\n\n"
        f"#define FIR_STREAM_INPUT {{{fmt(INPUT)} }}\n\n"
        "/* y[n] = sum c[k]*x[n-k], c = {" + ", ".join(map(str, COEF)) + "}, modulo 2^32 */\n"
        f"#define FIR_STREAM_EXPECTED {{{fmt(exp)} }}\n\n"
        "#endif\n"
    )


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
    except AttributeError:
        pass
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    assert len(INPUT) == 32 and all(-2**31 <= v < 2**31 for v in INPUT)
    text = render()
    if args.check:
        ok = HEADER.is_file() and HEADER.read_text(encoding="utf-8") == text
        print(f"{HEADER}: {'khớp' if ok else 'LỆCH - chạy lại không có --check'}")
        return 0 if ok else 1
    HEADER.write_text(text, encoding="utf-8", newline="\n")
    print(f"Ghi {HEADER}")
    for i, (x, y) in enumerate(zip(INPUT, fir_model(INPUT))):
        print(f"  [{i:2d}] x = {x:11d}  y = {y:11d}  (0x{y & 0xFFFFFFFF:08x})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
