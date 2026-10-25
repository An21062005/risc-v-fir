#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Build the main 1000-sample Timer/FIR IRQ firmware for rvcore32_pipeline_soc.

  python scripts/build_firmware.py
  python scripts/build_firmware.py --firmware fir_timer_1000_stress

Sources: firmware/fir_timer_1000.c, fir_timer_isr.h, soc_mmio.h,
fir_1000_data.h, startup_irq.S and linker_irq.ld.
Outputs: firmware/build/fir_timer_1000/{program.mem,data.mem,symbols.mem},
plus ELF, disassembly, map and build report. The stress variant uses the same
sources with PERIOD=100 and a separate output directory.

The builder checks ELF layout, IMEM/DMEM bounds and every instruction against
the CPU's supported RV32I subset before emitting memory images.
"""

import argparse
import os
import re
import struct
import subprocess
import sys
from pathlib import Path

PROJECT = Path(__file__).resolve().parent.parent
FW_DIR = PROJECT / "firmware"
DEFAULT_OUT = FW_DIR / "build"
DEFAULT_TOOLCHAIN = Path("D:/vivado/2026.1/gnu/riscv/nt/bin")
PREFIX = "riscv64-unknown-elf-"

# CPU memory map; firmware/linker_irq.ld is checked against these limits.
IMEM_BASE, IMEM_WORDS = 0x0000_0000, 256
DMEM_BASE, DMEM_WORDS = 0x1000_0000, 256
RESET_PC = 0x0000_0000
NOP = 0x0000_0013

# One application; stress changes only the timer period for verification.
FIRMWARES = {}
_IRQ_DEFS = ["IRQ_C_HANDLER=irq_handler"]
FIRMWARES["fir_timer_1000"] = dict(c_src="fir_timer_1000.c", startup="startup_irq.S", linker="linker_irq.ld",
                                   allow_mret=True, out=DEFAULT_OUT / "fir_timer_1000", stem="fir_timer_1000",
                                   defines=_IRQ_DEFS,
                                   symbols=["fst", "__stack_limit", "__stack_top", "__trap_entry", "__trap_mret",
                                            "__isr_end"])
FIRMWARES["fir_timer_1000_stress"] = dict(FIRMWARES["fir_timer_1000"],
    out=DEFAULT_OUT / "fir_timer_1000_stress", stem="fir_timer_1000_stress",
    defines=_IRQ_DEFS + ["FIR_TIMER_PERIOD=100u"])
MRET = 0x3020_0073      # rtl/cpu_soc.v MRET_INSTR
TRAP_VECTOR = 0x10      # rtl/cpu_soc.v TRAP_VECTOR

CFLAGS = [
    "-march=rv32i", "-mabi=ilp32",       # cấu hình theo yêu cầu; ISA thật còn hẹp hơn -> kiểm tra bước 5
    "-ffreestanding", "-fno-builtin",    # không thư viện C, không thay vòng lặp bằng memset/memcpy
    "-nostdlib", "-nostartfiles",        # không libc, không crt0, không libgcc (nhân/chia -> lỗi link)
    "-mcmodel=medlow", "-fno-pic",
    "-mstrict-align",                    # không truy cập lệch (CPU chỉ có lw/sw theo word)
    "-ffunction-sections", "-fdata-sections",
    "-Wall", "-Wextra", "-Werror",
]
LDFLAGS = ["-Wl,--gc-sections", "-Wl,--build-id=none"]


# =============================================================================
# Tập lệnh CPU giải mã ĐÚNG (đọc từ control_unit / alu_control / immediate_generator
# trong rtl/CPU/cpu.v và nhánh rẽ trong rtl/cpu_soc.v). Lệnh RV32I khác KHÔNG bị CPU
# báo lỗi mà chạy SAI âm thầm, nên phải chặn ở đây.
# =============================================================================
UNSUPPORTED_REASON = {
    ("LOAD", 0b000): "LB: CPU chạy mọi load như LW (không tách byte/mở rộng dấu)",
    ("LOAD", 0b001): "LH: CPU chạy mọi load như LW",
    ("LOAD", 0b100): "LBU: CPU chạy mọi load như LW",
    ("LOAD", 0b101): "LHU: CPU chạy mọi load như LW",
    ("STORE", 0b000): "SB: CPU chạy mọi store như SW (ghi đè cả word)",
    ("STORE", 0b001): "SH: CPU chạy mọi store như SW (ghi đè cả word)",
    ("BRANCH", 0b110): "BLTU: CPU không bao giờ rẽ nhánh (rtl/cpu_soc.v)",
    ("BRANCH", 0b111): "BGEU: CPU không bao giờ rẽ nhánh (rtl/cpu_soc.v)",
    ("OP-IMM", 0b011): "SLTIU/seqz: alu_control rơi vào default -> CPU tính ADD",
    ("OP", 0b011): "SLTU/snez: alu_control rơi vào default -> CPU tính AND",
}


def check_instruction(word):
    """Trả về None nếu CPU hỗ trợ, ngược lại là chuỗi lý do."""
    if word & 0b11 != 0b11:
        return "lệnh nén (RVC): CPU không có"
    op = word & 0x7F
    f3 = (word >> 12) & 0x7
    f7 = word >> 25
    if op in (0b0110111, 0b0010111, 0b1101111):          # LUI, AUIPC, JAL
        return None
    if op == 0b1100111:                                  # JALR
        return None if f3 == 0 else "JALR với funct3 != 0 (không hợp lệ)"
    if op == 0b1100011:                                  # BRANCH
        if f3 in (0b000, 0b001, 0b100, 0b101):
            return None
        return UNSUPPORTED_REASON.get(("BRANCH", f3), "nhánh không hợp lệ")
    if op == 0b0000011:                                  # LOAD
        return None if f3 == 0b010 else UNSUPPORTED_REASON.get(("LOAD", f3), "load không hợp lệ")
    if op == 0b0100011:                                  # STORE
        return None if f3 == 0b010 else UNSUPPORTED_REASON.get(("STORE", f3), "store không hợp lệ")
    if op == 0b0010011:                                  # OP-IMM
        if f3 in (0b000, 0b010, 0b100, 0b110, 0b111):     # ADDI SLTI XORI ORI ANDI
            return None
        if f3 == 0b001:
            return None if f7 == 0 else "SLLI với funct7 != 0"
        if f3 == 0b101:
            return None if f7 in (0x00, 0x20) else "SRLI/SRAI với funct7 không hợp lệ"
        return UNSUPPORTED_REASON[("OP-IMM", f3)]
    if op == 0b0110011:                                  # OP
        if f7 == 0x01:
            return "RV32M (MUL/DIV/REM): CPU không có, alu_control rơi vào default"
        ok = {(0x00, 0b000), (0x20, 0b000), (0x00, 0b111), (0x00, 0b110), (0x00, 0b100),
              (0x00, 0b010), (0x00, 0b001), (0x00, 0b101), (0x20, 0b101)}
        if (f7, f3) in ok:
            return None
        return UNSUPPORTED_REASON.get(("OP", f3), "lệnh R-type CPU không giải mã")
    if op == 0b0001111:
        return "FENCE/FENCE.I: CPU coi như NOP (không có trong tập hỗ trợ)"
    if op == 0b1110011:
        return "SYSTEM (ecall/ebreak/CSR/mret): firmware không được dùng"
    return f"opcode 0b{op:07b} CPU không giải mã"


# =============================================================================
# ELF32 tối giản (chỉ cần header, section header, symtab)
# =============================================================================
class Elf:
    def __init__(self, path):
        self.data = data = Path(path).read_bytes()
        if data[:4] != b"\x7fELF":
            raise ValueError("không phải file ELF")
        self.ei_class, self.ei_data = data[4], data[5]
        if self.ei_class != 1 or self.ei_data != 1:
            raise ValueError("cần ELF32 little-endian")
        (self.e_type, self.e_machine, _, self.e_entry, _, e_shoff, self.e_flags, _, _, _,
         e_shentsize, e_shnum, e_shstrndx) = struct.unpack_from("<HHIIIIIHHHHHH", data, 16)
        self.sections = []
        for i in range(e_shnum):
            f = struct.unpack_from("<IIIIIIIIII", data, e_shoff + i * e_shentsize)
            self.sections.append(dict(name_off=f[0], type=f[1], flags=f[2], addr=f[3],
                                      offset=f[4], size=f[5], link=f[6]))
        strtab = self.sections[e_shstrndx]
        for s in self.sections:
            s["name"] = self._cstr(strtab["offset"] + s["name_off"])

    def _cstr(self, off):
        end = self.data.index(b"\0", off)
        return self.data[off:end].decode()

    def symbols(self):
        out = {}
        for s in self.sections:
            if s["type"] != 2:                          # SHT_SYMTAB
                continue
            strtab = self.sections[s["link"]]
            for i in range(s["size"] // 16):
                name_off, value, _, _, _, _ = struct.unpack_from("<IIIBBH", self.data, s["offset"] + i * 16)
                if name_off:
                    out[self._cstr(strtab["offset"] + name_off)] = value
        return out

    def content(self, s):
        return self.data[s["offset"]:s["offset"] + s["size"]]


SHF_ALLOC, SHF_EXECINSTR = 0x2, 0x4
SHT_NOBITS = 8


class BuildError(Exception):
    pass


def run(cmd, log):
    log.append("$ " + " ".join(str(c) for c in cmd))
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, encoding="utf-8",
                       errors="replace")
    if r.stdout.strip():
        log.append(r.stdout.rstrip())
    if r.stderr.strip():
        log.append(r.stderr.rstrip())
    if r.returncode != 0:
        raise BuildError(f"{Path(cmd[0]).name} lỗi (exit {r.returncode}):\n{r.stderr.strip()}")
    return r.stdout


def in_region(addr, size, base, words):
    return base <= addr and addr + size <= base + 4 * words


def write_mem(path, words):
    with open(path, "w", newline="\n") as f:
        for w in words:
            f.write(f"{w:08x}\n")


def main():
    try:
        sys.stdout.reconfigure(encoding="utf-8")
        sys.stderr.reconfigure(encoding="utf-8")
    except AttributeError:
        pass
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--toolchain", type=Path,
                    default=Path(os.environ.get("RISCV_TOOLCHAIN", DEFAULT_TOOLCHAIN)),
                    help=f"thư mục chứa {PREFIX}gcc.exe (mặc định {DEFAULT_TOOLCHAIN}, hoặc biến RISCV_TOOLCHAIN)")
    ap.add_argument("--firmware", choices=sorted(FIRMWARES), default="fir_timer_1000",
                    help="main application (default) or its overload verification build")
    ap.add_argument("--src", type=Path, default=FW_DIR,
                    help="firmware source directory (default: firmware/)")
    ap.add_argument("--out", type=Path,
                    help="output directory (default: firmware/build/<firmware>)")
    ap.add_argument("--opt", default="-Os", help="mức tối ưu (mặc định -Os: IMEM chỉ 1 KB)")
    args = ap.parse_args()

    fw = FIRMWARES[args.firmware]
    startup, linker = fw["startup"], fw["linker"]
    defines = [f"-D{d}" for d in fw.get("defines", [])]    # áp cho cả startup .S và nguồn C
    allow_mret = fw.get("allow_mret", False)
    out = (args.out or fw["out"]).resolve()
    src = args.src.resolve()
    for name, other in FIRMWARES.items():
        if name != args.firmware and out == other["out"].resolve():
            print(f"LỖI: --out {out} là thư mục kết quả của firmware '{name}'", file=sys.stderr)
            return 2
    out.mkdir(parents=True, exist_ok=True)
    exe = ".exe" if os.name == "nt" else ""
    tool = lambda name: args.toolchain / f"{PREFIX}{name}{exe}"
    if not tool("gcc").is_file():
        print(f"LỖI: không tìm thấy {tool('gcc')} (dùng --toolchain)", file=sys.stderr)
        return 2

    log = []
    stem = fw["stem"]
    elf_path, map_path, dis_path = out / f"{stem}.elf", out / f"{stem}.map", out / f"{stem}.dis"
    for stale in (elf_path.name, "program.mem", "data.mem", "symbols.mem"):     # không để lại image cũ khi build lỗi
        (out / stale).unlink(missing_ok=True)
    try:
        # ---- 1. Build ----
        version = run([tool("gcc"), "--version"], log).splitlines()[0]
        includes = ["-I", src]
        run([tool("gcc"), *CFLAGS, *defines, *includes, args.opt, "-T", src / linker, *LDFLAGS,
             f"-Wl,-Map={map_path}", src / startup, src / fw["c_src"], "-o", elf_path], log)

        # ---- 2. ELF header ----
        elf = Elf(elf_path)
        if elf.e_machine != 243:
            raise BuildError(f"e_machine = {elf.e_machine}, cần 243 (RISC-V)")
        if elf.e_flags & 0x1:
            raise BuildError("ELF có cờ RVC (lệnh nén) - CPU không hỗ trợ")
        if elf.e_flags & 0x6:
            raise BuildError("ELF dùng ABI số thực - cần ilp32")
        syms = elf.symbols()
        if elf.e_entry != RESET_PC or syms.get("_start") != RESET_PC:
            raise BuildError(f"entry = 0x{elf.e_entry:08x}, _start = {syms.get('_start')}: "
                             f"phải bằng reset PC 0x{RESET_PC:08x}")
        if syms.get("sig") != DMEM_BASE:
            raise BuildError("struct sig (signature) phải ở đầu DMEM 0x10000000")
        if allow_mret and syms.get("__trap_entry") != TRAP_VECTOR:
            raise BuildError(f"__trap_entry = {syms.get('__trap_entry')}: phải ở TRAP_VECTOR 0x{TRAP_VECTOR:x}")

        # ---- 3. Section -> vùng nhớ ----
        imem = [NOP] * IMEM_WORDS
        dmem = [0] * DMEM_WORDS
        rows, text_secs = [], []
        imem_used = dmem_used = 0
        for s in elf.sections:
            if not s["flags"] & SHF_ALLOC or s["size"] == 0:
                continue
            execu = bool(s["flags"] & SHF_EXECINSTR)
            nobits = s["type"] == SHT_NOBITS
            if execu:
                if not in_region(s["addr"], s["size"], IMEM_BASE, IMEM_WORDS):
                    raise BuildError(f"{s['name']} [0x{s['addr']:08x}, +{s['size']}] ngoài IMEM 1 KB")
                region, base, mem = "IMEM", IMEM_BASE, imem
                imem_used += s["size"]
                text_secs.append(s)
            else:
                if not in_region(s["addr"], s["size"], DMEM_BASE, DMEM_WORDS):
                    raise BuildError(f"{s['name']} [0x{s['addr']:08x}, +{s['size']}] ngoài DMEM 1 KB")
                region, base, mem = "DMEM", DMEM_BASE, dmem
                dmem_used += s["size"]
            if s["addr"] % 4 or s["size"] % 4:
                raise BuildError(f"{s['name']} không căn word (addr 0x{s['addr']:x}, size {s['size']})")
            if not nobits:
                blob = elf.content(s)
                for i in range(0, len(blob), 4):
                    mem[(s["addr"] - base + i) // 4] = struct.unpack_from("<I", blob, i)[0]
            rows.append((s["name"], region, s["addr"], s["size"],
                         "NOLOAD (0 khi reset)" if nobits else ("program.mem" if execu else "data.mem")))
        stack_top, stack_limit = syms["__stack_top"], syms["__stack_limit"]

        # ---- 4. Disassembly ----
        dis = run([tool("objdump"), "-d", "-M", "no-aliases,numeric", elf_path], log)
        dis_path.write_text(run([tool("objdump"), "-d", "-S", elf_path], log),
                                          encoding="utf-8", newline="\n")
        mnem = {}
        for line in dis.splitlines():
            m = re.match(r"^\s*([0-9a-f]+):\s+([0-9a-f]{8})\s+(.*)$", line)
            if m:
                mnem[int(m.group(1), 16)] = m.group(3).strip()

        # ---- 5. ISA ----
        bad, hist = [], {}
        for s in text_secs:
            blob = elf.content(s)
            for i in range(0, len(blob), 4):
                addr = s["addr"] + i
                w = struct.unpack_from("<I", blob, i)[0]
                if allow_mret and w == MRET and addr == syms.get("__trap_mret"):
                    why = None              # mret của trap entry: CPU giải mã (rtl/cpu_soc.v)
                else:
                    why = check_instruction(w)
                name = mnem.get(addr, "?").split()[0] if mnem.get(addr) else "?"
                hist[name] = hist.get(name, 0) + 1
                if why:
                    bad.append((addr, w, mnem.get(addr, "?"), why))
        if bad:
            lines = [f"  PC 0x{a:08x}: {w:08x}  {m:<32} -> {why}" for a, w, m, why in bad]
            raise BuildError(f"{len(bad)} lệnh CPU không hỗ trợ hoặc giải mã sai:\n" + "\n".join(lines))

        # ---- 6. .mem ----
        sym_rows = []
        for name in fw["symbols"]:
            if name not in syms:
                raise BuildError(f"thiếu symbol {name} (cần cho symbols.mem)")
            if not (DMEM_BASE <= syms[name] <= DMEM_BASE + 4 * DMEM_WORDS or
                    IMEM_BASE <= syms[name] <= IMEM_BASE + 4 * IMEM_WORDS) or syms[name] % 4:
                raise BuildError(f"symbol {name} = 0x{syms[name]:08x} ngoài DMEM/IMEM hoặc không căn word")
            sym_rows.append((name, syms[name]))
        write_mem(out / "program.mem", imem)
        write_mem(out / "data.mem", dmem)
        if sym_rows:
            with open(out / "symbols.mem", "w", newline="\n") as f:
                for name, addr in sym_rows:
                    f.write(f"{addr:08x} // {name}\n")
    except BuildError as e:
        (out / "build_report.txt").write_text("\n".join(log + ["", f"LỖI: {e}"]) + "\n",
                                              encoding="utf-8", newline="\n")
        print(f"LỖI: {e}", file=sys.stderr)
        print(f"Log: {out / 'build_report.txt'}", file=sys.stderr)
        return 1

    rel = lambda p: p.relative_to(PROJECT).as_posix() if p.is_relative_to(PROJECT) else str(p)
    rep = [
        "=" * 72, f"FIRMWARE BUILD - rvcore32_pipeline_soc - {args.firmware} ({fw['c_src']})", "=" * 72,
        f"Compiler     : {version}",
        f"Cờ           : {' '.join(CFLAGS + defines)} {args.opt} {' '.join(LDFLAGS)}",
        f"ELF          : {rel(elf_path)}  entry 0x{elf.e_entry:08x} (= reset PC), ELF32 RISC-V, "
        f"không RVC, ilp32",
        "", f"{'Section':<12}{'Vùng':<6}{'Địa chỉ':>12}{'Byte':>7}  Nạp từ",
    ]
    rep += [f"{n:<12}{r:<6}{'0x%08x' % a:>12}{sz:>7}  {how}" for n, r, a, sz, how in rows]
    rep += [
        "",
        f"IMEM: {imem_used}/{4 * IMEM_WORDS} byte ({100 * imem_used / (4 * IMEM_WORDS):.1f}%), "
        f"{imem_used // 4} lệnh",
        f"DMEM: {dmem_used}/{4 * DMEM_WORDS} byte dữ liệu + stack "
        f"[0x{stack_limit:08x}, 0x{stack_top:08x}) {stack_top - stack_limit} byte, sp đầu = 0x{stack_top:08x}",
        f"Src : {startup} + {fw['c_src']}, {linker}" + (", mret cho phép tại __trap_mret" if allow_mret else ""),
        f"ISA : {imem_used // 4} lệnh, tất cả thuộc tập CPU giải mã đúng. Dùng: "
        + ", ".join(f"{k}×{v}" for k, v in sorted(hist.items())),
        f"Ra  : {rel(out / 'program.mem')} ({IMEM_WORDS} word, trống = NOP), "
        f"{rel(out / 'data.mem')} ({DMEM_WORDS} word, trống = 0)",
        f"      {rel(dis_path)}, {rel(map_path)}",
    ]
    if sym_rows:
        rep.append(f"      {rel(out / 'symbols.mem')}: " + ", ".join(f"{n} = 0x{a:08x}" for n, a in sym_rows))
    rep += [
        "Kết quả: PASS",
    ]
    (out / "build_report.txt").write_text("\n".join(rep + ["", "---- log ----"] + log) + "\n",
                                          encoding="utf-8", newline="\n")
    print("\n".join(rep))
    return 0


if __name__ == "__main__":
    sys.exit(main())
