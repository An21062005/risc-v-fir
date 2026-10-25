# riscv-soc-fir-hls

Vivado Block Design: xem [hướng dẫn tạo project, sơ đồ gom bus và kiểm chứng](docs/BLOCK_DESIGN.md).

Mới đọc thiết kế: xem [lộ trình từ luồng chính đến từng test/khối RTL](docs/FIR_READING_GUIDE.md)
và [hướng dẫn firmware, build và ảnh `.mem`](firmware/README.md).

SoC RISC-V 32-bit (RV32I, pipeline 5 tầng) có bộ lọc **FIR 11 tap sinh bằng Vitis HLS**, nối qua
bus AXI4-Lite cùng Timer, bộ điều khiển ngắt và RAM dữ liệu ngoài (tùy chọn). Toàn bộ thiết kế
được kiểm chứng bằng mô phỏng XSim tự kiểm tra (self-checking) và đã tổng hợp bằng Vivado.

| Hạng mục | Trạng thái hiện tại |
|---|---|
| Mô phỏng XSim | Luồng chính 1000 mẫu; 7 bài kiểm tra tích hợp Block Design A/B/C PASS (mục 11) |
| FIR HLS so với mô hình Python | bit-exact 6/6 bộ vector (6 000 mẫu), 1 000 mẫu × 6 dataset × 2 cấu hình RAM |
| Vivado synthesis (Block Design C) | **PASS**: 0 latch, 0 critical warning, nạp đủ 4 file khởi tạo bộ nhớ |
| Timing 100 MHz (sau synthesis) | Chưa đạt: WNS −4,945 ns; không yêu cầu đóng timing trong phạm vi project |
| Phạm vi | Mô phỏng và synthesis; không yêu cầu chạy board hoặc tạo bitstream |

## Mục lục

1. [Tổng quan](#1-tổng-quan)
2. [Kiến trúc](#2-kiến-trúc)
3. [Cấu trúc thư mục](#3-cấu-trúc-thư-mục)
4. [Cấu hình SoC và bản đồ địa chỉ](#4-cấu-hình-soc-và-bản-đồ-địa-chỉ)
5. [Yêu cầu công cụ](#5-yêu-cầu-công-cụ)
6. [Firmware](#6-firmware)
7. [Mô phỏng và regression](#7-mô-phỏng-và-regression)
8. [Danh sách testbench](#8-danh-sách-testbench)
9. [FIR HLS IP và dữ liệu kiểm chứng](#9-fir-hls-ip-và-dữ-liệu-kiểm-chứng)
10. [RAM ngoài: cache và SDRAM mô phỏng](#10-ram-ngoài-cache-và-sdram-mô-phỏng)
11. [Kết quả kiểm chứng](#11-kết-quả-kiểm-chứng)
12. [Synthesis và timing](#12-synthesis-và-timing)
13. [Giới hạn và việc cần làm trước khi chạy FPGA](#13-giới-hạn-và-việc-cần-làm-trước-khi-chạy-fpga)
14. [Tài liệu hướng dẫn](#14-tài-liệu-hướng-dẫn)
15. [Lưu ý khi sử dụng](#15-lưu-ý-khi-sử-dụng)

## 1. Tổng quan

- **CPU** `rvcore32_pipeline_soc` ([rtl/cpu_soc.v](rtl/cpu_soc.v)): RV32I tập con, 5 tầng
  IF/ID/EX/MEM/WB, forwarding, phát hiện load-use, giải quyết nhánh ở EX. IMEM 1 KB và DMEM 1 KB
  nội bộ. Ngắt tối thiểu không có CSR: một mức ngắt, vector cố định `0x10`, `mepc`/`in_irq` nội bộ,
  trở về bằng `mret`.
- **Bus**: CPU → `cpu_axi_master` (AXI4-Lite, một giao dịch tại một thời điểm) → `axi_interconnect`
  → Timer, bộ ngắt, FIR, và RAM ngoài (tùy chọn).
- **FIR11**: IP do Vitis HLS 2024.1 sinh từ [hls/FIR11/FIR11/fir.cpp](hls/FIR11/FIR11/fir.cpp),
  hệ số `{54, 0, -92, 0, 313, 500, 313, 0, -92, 0, 54}`, bọc bởi
  [fir11_wrapper.v](rtl/Peripherals/fir11_wrapper.v) thành khối thanh ghi có ngắt DONE.
- **Ứng dụng mẫu**: Timer IRQ 10 kHz điều phối từng mẫu vào FIR, FIR IRQ trả kết quả;
  1 000 mẫu lưu ở RAM ngoài, so bit-exact với mô hình Python.

**Nguồn gốc và giấy phép.** CPU (`rtl/CPU/`, `cpu_soc.v`), AXI master/interconnect, Timer, bộ ngắt,
cache, SDRAM và các package dựa trên **tiny-riscv-soc** (MIT, © 2026 Leela Shanmukh Yagneek
Patnala, file `LICENCE` của repo đó). Mỗi file được sao chép ghi rõ nguồn và các thay đổi ở phần
chú thích đầu file. FIR11 là RTL do Vitis HLS sinh từ `fir.cpp` của project này. Wrapper FIR,
reset synchronizer, testbench, firmware và script là phần viết riêng cho project.

## 2. Kiến trúc

```text
                   rst_n ──► reset_sync (2 FF: bật bất đồng bộ, nhả đồng bộ)
                                    │
 ┌──────────────────────────────────┴───────────────────────────────────────────────┐
 │ soc_top                                                                          │
 │  ┌────────────────────────────┐  bus_rd/wr, addr, data, ready                    │
 │  │ CPU rvcore32_pipeline_soc  │──────────────────────┐                           │
 │  │ IF ID EX MEM WB            │◄── irq ──────────┐   ▼                           │
 │  │ IMEM 1 KB  DMEM 1 KB       │                  │  cpu_axi_master (AXI4-Lite)   │
 │  │ (program.mem, data.mem)    │                  │   │ BRESP/RRESP, BUSERR       │
 │  └────────────────────────────┘                  │   ▼                           │
 │                                                  │  axi_interconnect             │
 │                                                  │   ├─► timer           0x080   │
 │                                                  │   ├─► interrupt_axi_wrapper   │
 │                     irq_in = {fir_irq, timer_irq}│   │   + interrupt_controller  │
 │                                                  └───┤                 0x1C0     │
 │                                                      ├─► fir11_wrapper  0x200     │
 │                                                      │     └─ fir (Vitis HLS)    │
 │                                                      │        ROM hệ số + RAM    │
 │                                                      │        shift_reg (.dat)   │
 │                                                      └─► RAM ngoài 0x0001_0000   │
 │                                                          (chỉ cấu hình B/C)      │
 │                                                          cache_top               │
 │                                                           ├ cache_controller (C) │
 │                                                           └ cache_dma_arbiter    │
 │                                                              └ sdram_top         │
 │                                                                 (controller +    │
 │                                                                  sdram_model)    │
 └──────────────────────────────────────────────────────────────────────────────────┘
   cổng ra: cpu_irq (yêu cầu ngắt tới CPU), bus_error (đã chốt lỗi bus)
```

- CPU đưa mọi địa chỉ có `addr[31:30] == 01` ra bus với `bus_addr = {2'b00, addr[29:0]}`, nên
  CPU thấy ngoại vi ở `0x4000_0000 + offset bus`. Các địa chỉ khác đi vào DMEM nội bộ.
- Khi CPU chờ bus, `bus_stall` giữ PC và cả 4 thanh ghi pipeline. Ngắt chỉ được nhận khi không
  stall và lệnh ở ID không phải nhánh/nhảy/`mret`.

## 3. Cấu trúc thư mục

```text
riscv-soc-fir-hls/
├── rtl/
│   ├── soc_top.v               top SoC (tham số ENABLE_EXT_RAM, EXT_RAM_USE_CACHE, EXT_RAM_TIMEOUT)
│   ├── cpu_soc.v               CPU pipeline có cổng bus + ngắt
│   ├── reset_sync.v            đồng bộ reset
│   ├── CPU/                    cpu.v (submodule gốc), Pipeline_Registers.v
│   ├── AXI/                    AXI_master.v, AXI_Interconnect.v (decoder, write/read FSM, arbiter RAM)
│   ├── Peripherals/            timer.v, Interrupt_controller.v, interrupt_axi_wrapper.v,
│   │   │                       fir11_wrapper.v
│   │   └── FIR11/              8 file do Vitis HLS sinh (6 .v + 2 .dat), chép nguyên trạng
│   ├── Memory/                 cache_controller.v (cache_top), sdram.v (sdram_top, sdram_model)
│   ├── packages/               soc_pkg.vh, interrupt_pkg.vh, cache_pkg.vh, sdram_pkg.vh
│   ├── filelist_fir11.f        danh sách nguồn cấu hình A
│   └── filelist_ext_ram_sim.f  thêm cho cấu hình B/C
├── tb/                         testbench self-checking; asm/irq_dir.S (ảnh lệnh cho tb_cpu_irq_c4)
├── firmware/                   một firmware fir_timer_1000.c + ISR/MMIO/startup/linker;
│                               build/ sinh ra, gitignore
├── fpga/                       soc_top.xdc (clock 100 MHz), synth_soc.tcl (Vivado non-project)
├── hls/FIR11/FIR11/            nguồn C HLS (fir.cpp, fir.h) + syn/verilog, syn/report
├── scripts/                    run_rtl_tests.py, build_firmware.py, run_vivado_synth.py,
│                               verify_phase41.py, gen_fir_*_data.py, plot/view_fir_plots.*,
│                               prep_fir11_dat.sh
├── data_test/
│   ├── fir_test/               generate_fir_data.py, output/<test>/ (input.dat, expected.dat),
│   │                           rtl_plots/ (đồ thị RTL vs Python)
│   └── fir_1000/               input/expected/layout.mem 1 000 mẫu + manifest.txt
├── outfeed/<test>/actual.dat   kết quả FIR RTL của tb_fir11_vectors (được git theo dõi)
└── docs/                       hướng dẫn đọc thiết kế, Block Design và ảnh sơ đồ (mục 14)
```

`outfeed/tb_*/`, `outfeed/synth_*/`, `firmware/build/` là thư mục sinh ra, đã gitignore.

## 4. Cấu hình SoC và bản đồ địa chỉ

### 4.1 Ba cấu hình

| Cấu hình | Tham số `soc_top` | Danh sách file | Dùng cho |
|---|---|---|---|
| **A** (mặc định RTL) | `ENABLE_EXT_RAM=0` | `rtl/filelist_fir11.f` | kiểm khối RTL; không đủ RAM ngoài cho firmware chính |
| **B** | `ENABLE_EXT_RAM=1 EXT_RAM_USE_CACHE=0` | + `rtl/filelist_ext_ram_sim.f` | chỉ mô phỏng: RAM ngoài, không cache |
| **C** | `ENABLE_EXT_RAM=1 EXT_RAM_USE_CACHE=1` | + `rtl/filelist_ext_ram_sim.f` | chỉ mô phỏng: RAM ngoài có cache |

Vì sao B/C chỉ dùng cho mô phỏng: xem [mục 10](#10-ram-ngoài-cache-và-sdram-mô-phỏng).
`EXT_RAM_TIMEOUT` (mặc định 1 024 chu kỳ) giới hạn thời gian chờ RAM ngoài.

### 4.2 Bản đồ địa chỉ CPU

| Vùng | Địa chỉ CPU | Địa chỉ bus | Ghi chú |
|---|---|---|---|
| IMEM 1 KB | `0x0000_0000`–`0x0000_03FF` | — | chỉ nạp lệnh; reset PC = 0, vector ngắt `0x10` |
| DMEM 1 KB | `0x1000_0000`–`0x1000_03FF` | — | dữ liệu, stack; mọi địa chỉ `addr[31:30] != 01` đều vào DMEM (bí danh ngoài 1 KB) |
| Timer | `0x4000_0080`–`0x4000_00BF` | `0x080`–`0x0BF` | |
| Bộ ngắt | `0x4000_01C0`–`0x4000_01FF` | `0x1C0`–`0x1FF` | |
| FIR11 | `0x4000_0200`–`0x4000_023F` | `0x200`–`0x23F` | |
| RAM ngoài 64 KB | `0x4001_0000`–`0x4001_FFFF` | `0x0001_0000`–`0x0001_FFFF` | chỉ B/C; ở cấu hình A là vùng không map |

### 4.3 Quy tắc truy cập bus (RTL hiện tại)

| Trường hợp | BRESP / RRESP | Tác dụng |
|---|---|---|
| Word căn 4 byte, `WSTRB = 1111` | `OKAY` | một xung `wr_en`/`rd_en` mỗi giao dịch |
| MMIO ghi `WSTRB = 0000` (căn lề) | `OKAY` | không làm gì |
| Ghi từng phần, ghi/đọc lệch | `SLVERR` | không ghi, đọc trả 0, không tác dụng phụ |
| **Địa chỉ không map** | **`DECERR`** | không ghi, đọc trả 0 |
| RAM ngoài không trả lời trong `EXT_RAM_TIMEOUT` chu kỳ | `SLVERR` | đọc trả 0; completion đến muộn bị bỏ |

`cpu_axi_master` kiểm BRESP/RRESP: đọc lỗi trả 0 cho CPU, lỗi đầu tiên được chốt vào thanh ghi
`BUSERR`/`BUSERR_ADDR` và cổng `bus_error`. CPU **không có trap** khi lỗi bus (không có CSR),
phần mềm phải tự đọc `BUSERR`.

### 4.4 Thanh ghi ngoại vi

**Timer** (`0x4000_0080`, [timer.v](rtl/Peripherals/timer.v))

| Offset | Tên | Mô tả |
|---|---|---|
| `0x00` | LEGACY | one-shot gốc: ghi = nạp compare và chạy, đọc = bộ đếm |
| `0x04` | PERIOD | số chu kỳ giữa hai tick (≥ 2) |
| `0x08` | CTRL | bit0 ENABLE, bit1 PERIODIC, bit2 PERIOD_INVALID (RO) |
| `0x0C` | TICK_COUNT | số tick từ reset (RO) |

**Bộ ngắt** (`0x4000_01C0`, [interrupt_axi_wrapper.v](rtl/Peripherals/interrupt_axi_wrapper.v)).
Nguồn: `IRQ_TIMER = 0`, `IRQ_FIR = 1` (0 ưu tiên cao hơn). Pending bắt theo cạnh lên.

| Offset | Tên | Mô tả |
|---|---|---|
| `0x00` | ENABLE | bit[1:0] cho phép từng nguồn |
| `0x04` | PENDING | cờ đang chờ (RO) |
| `0x08` | ACK | ghi `(id << 1) \| 1` để xóa pending của nguồn `id` |
| `0x0C` | STATUS | bit0 có ngắt, bit[3:1] nguồn ưu tiên cao nhất (RO); đọc STATUS cũng là "claim" |
| `0x10` | BUSERR | bit0 valid, bit1 ghi, bit[3:2] mã lỗi (2 = SLVERR, 3 = DECERR), bit4 overflow; ghi bit0 = 1 để xóa |
| `0x14` | BUSERR_ADDR | địa chỉ bus của lỗi đầu tiên (RO) |

ISR chuẩn: đọc STATUS, ghi lại đúng giá trị đó vào ACK **ngay đầu ISR**, rồi mới phục vụ nguồn.
ACK trễ của sự kiện cũ không xóa sự kiện mới đến sau lần đọc STATUS (sửa lỗi I1).

**FIR11** (`0x4000_0200`, [fir11_wrapper.v](rtl/Peripherals/fir11_wrapper.v))

| Offset | Tên | Mô tả |
|---|---|---|
| `0x00` | DATA_IN | ghi = chốt mẫu x và chạy một lần tính; đang bận thì bỏ mẫu và bật overrun |
| `0x04` | DATA_OUT | y đã chốt; đọc thì xóa done |
| `0x08` | STATUS | bit0 done, bit1 ap_idle, bit2 ap_ready, bit3 busy, bit4 overrun |
| `0x0C` | CTRL | bit0 xóa done/overrun, bit1 reset mềm IP |
| `0x10` | CYC_CNT | số chu kỳ bận của giao dịch gần nhất (đo được 17) |

`fir_irq = done` (mức). Lịch sử mẫu của FIR **không bị reset xóa** (nằm trong RAM của IP), nên
phần mềm phải gửi 10 mẫu 0 để xóa lịch sử trước khi xử lý dữ liệu mới.

## 5. Yêu cầu công cụ

| Công cụ | Dùng cho | Ghi chú |
|---|---|---|
| Vivado 2026.1 (XSim) | mô phỏng, synthesis | mặc định `D:/vivado/2026.1/Vivado` |
| GCC RISC-V kèm Vivado | build firmware, ảnh asm | `D:/vivado/2026.1/gnu/riscv/nt/bin/riscv64-unknown-elf-*` (GCC 13.4) |
| Python 3 + numpy, scipy, matplotlib | script, dữ liệu, đồ thị | đã chạy với Python 3.14 |
| Questa 10.7c (tùy chọn) | chỉ `vlog -lint` | `vsim` không có license runtime |
| Vitis HLS 2024.1 (tùy chọn) | chỉ khi sinh lại IP FIR | |

Các lệnh dưới đây chạy trong **Git Bash** tại thư mục gốc project. Có thể đặt
`export XILINX_VIVADO=D:/vivado/2026.1/Vivado` để bỏ `--vivado-root`.

## 6. Firmware

Project chỉ giữ [firmware/fir_timer_1000.c](firmware/fir_timer_1000.c): Timer IRQ
điều phối 1000 mẫu từ RAM ngoài vào FIR HLS, FIR IRQ trả kết quả về RAM ngoài.

```text
firmware/
├── fir_timer_1000.c     main: khởi tạo, bật Timer/ngắt, chờ đủ mẫu, kiểm kết quả
├── fir_timer_isr.h      try_send(), irq_handler(), trạng thái fst
├── soc_mmio.h           địa chỉ thanh ghi nhìn từ CPU
├── fir_1000_data.h      số mẫu, địa chỉ input/output, checksum được sinh tự động
├── startup_irq.S        reset tại 0, vector ngắt 0x10, lưu/khôi phục thanh ghi
├── linker_irq.ld        IMEM/DMEM 1 KB, stack 256 byte
└── build/               ảnh sinh tự động (gitignore)
```

```bash
python scripts/build_firmware.py
```

Mặc định build `fir_timer_1000` vào `firmware/build/fir_timer_1000/`:
`program.mem`, `data.mem`, `symbols.mem`, ELF, disassembly, map và báo cáo.
`fir_timer_1000_stress` dùng cùng nguồn, chỉ đổi PERIOD=100 để kiểm quá tải.
Runner tạo header theo dataset và build ảnh riêng cho từng lần mô phỏng.

Luồng chính cần RAM ngoài, hiện chạy trong mô phỏng B/C. CPU hỗ trợ tập con
RV32I; build script kiểm ISA và dung lượng bộ nhớ. MMIO dùng word 32-bit
`volatile`; `mret` chỉ được phép tại `__trap_mret`. Sinh/kiểm dữ liệu bằng
`python scripts/gen_fir_1000_data.py [--check]`.

Xem [hướng dẫn firmware và nạp ảnh](firmware/README.md) và
[lộ trình theo một luồng chính](docs/FIR_READING_GUIDE.md).

## 7. Mô phỏng và regression

Script [run_rtl_tests.py](scripts/run_rtl_tests.py) compile (`xvlog`), elaborate (`xelab`), mô phỏng
(`xsim`), tự chép 2 file `.dat` của FIR, tự build firmware/ảnh asm. Một test chỉ PASS khi log có
`TEST PASSED` và không có `ERROR`, `FATAL`, `TEST FAILED`. Log: `outfeed/<test>/simulate.log`.

```bash
# Mặc định: luồng chính 1000 mẫu, RAM ngoài không cache (B)
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado

# Cùng ứng dụng với cache (C)
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado --tests tb_cpu_fir_timer_1000_c

# Ma trận sáu dataset trong B/C
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado --fir-matrix

# Kiểm các khối RTL và luồng chính B/C
python scripts/verify_phase41.py --vivado-root D:/vivado/2026.1/Vivado --suite regression

# 4 negative test: PHẢI kết thúc bằng TEST FAILED với lỗi ngân sách thời gian (chạy từng test)
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado --tests tb_cpu_fir_timer_1000_timing_fault_b
#   ... tương tự: _timing_fault_c, _jitter_fault_b, _jitter_fault_c
```

Runner dừng ở test FAIL đầu tiên, nên các negative test phải chạy riêng. Kết quả mong đợi:
`timing_fault` báo `fixed tick -> accept budget`, `fixed tick -> stored budget`,
`fixed accept jitter budget`; `jitter_fault` báo `fixed accept jitter budget`.
[verify_phase41.py](scripts/verify_phase41.py) `--suite matrix|special|regression|mutations` chạy
song song các nhóm này và tự kiểm lý do "đỏ" của negative test.

| Tùy chọn `run_rtl_tests.py` | Ý nghĩa |
|---|---|
| `--tests T1 T2 ...` | chỉ chạy các test này |
| `--fir-matrix` | thêm 12 cấu hình 6 dataset × B/C |
| `--seed N` | seed cho test random (mặc định 1) |
| `--output DIR` | thư mục kết quả (mặc định `outfeed/`) |
| `--wave` / `--open-wave TB` | ghi waveform `outfeed/<tb>/<tb>.wdb` / mở trong XSim GUI |
| `--wave-time all\|<t>` | thời gian ghi sóng (tự bật `--wave`): `all` (mặc định) chạy hết và yêu cầu `TEST PASSED`; `500us`, `2ms`, `40000ns`... dừng tại mốc đó, không kết luận PASS (vẫn báo lỗi nếu có `ERROR`/`TEST FAILED`) |
| `--rtl-root DIR` | chạy trên một bản RTL khác (ví dụ mutant) |
| `--firmware-src DIR` | nguồn firmware khác (thử nghiệm đột biến) |
| `--vector-dir DIR`, `--outfeed-dir DIR` | bộ vector khác / nơi ghi `actual.dat` cho `tb_fir11_vectors` |

**Compile thủ công khối FIR** (XSim):

```bash
V=D:/vivado/2026.1/Vivado/bin; P=$(pwd)
bash scripts/prep_fir11_dat.sh sim_fir11 && cd sim_fir11
$V/xvlog.bat $P/rtl/Peripherals/fir11_wrapper.v $P/rtl/Peripherals/FIR11/*.v $P/tb/tb_fir11_wrapper.v
$V/xelab.bat tb_fir11_wrapper -s tb_fir11_wrapper -debug typical
$V/xsim.bat  tb_fir11_wrapper -runall
```

Compile cả SoC: lấy nguồn trong `rtl/filelist_fir11.f` (+ `rtl/filelist_ext_ram_sim.f` cho B/C) với
`-i rtl/packages -i tb`, giống cách `run_rtl_tests.py` làm. Lint: `vlog -lint +incdir+rtl/packages <nguồn>`
(Questa), kết quả hiện tại `Errors: 0, Warnings: 0`.

## 8. Danh sách testbench

**Kiểm khối RTL (20 cấu hình, chọn qua `--tests` hoặc suite regression)**

| Testbench | Kiểm tra |
|---|---|
| `tb_fir11_wrapper` | wrapper + FIR HLS: số âm, tràn 32-bit, overrun, xóa done, reset mềm, `CYC_CNT` |
| `tb_fir11_vectors` | 6 bộ vector, bit-exact 6 000 mẫu, ghi `outfeed/<test>/actual.dat` |
| `tb_axi_fir` | interconnect + FIR: hàng đợi, backpressure, WSTRB/lệch → SLVERR |
| `tb_axi_fault` | interconnect: DECERR/SLVERR, timeout RAM ngoài, backpressure ngẫu nhiên, scoreboard 3 000 giao dịch |
| `tb_ext_ram_cfgA` | cấu hình A: vùng RAM không map → DECERR, không có yêu cầu bộ nhớ |
| `tb_ext_ram_axi_b` / `_c` | RAM ngoài B/C: ranh giới địa chỉ, cache hit/miss/refill, refresh, truy cập ngẫu nhiên theo seed |
| `tb_cpu_bus_b` / `_c` | CPU thật + FIR + IRQ + RAM: stall, forwarding, không ghi trùng |
| `tb_cpu_fault_b` / `_c` | CPU: SLVERR/DECERR, thanh ghi BUSERR, timeout đọc/ghi, phục hồi, reset |
| `tb_timer` | Timer định kỳ: pha, PERIOD, ENABLE, TICK_COUNT |
| `tb_irq_ack` | ACK đúng nguồn, cạnh mới trùng ACK, ưu tiên (439 kiểm tra) |
| `tb_irq_i1` | FIR IRQ khi gửi DATA_IN trước ACK (lỗi I1) |
| `tb_cpu_irq_c4_a` / `_b` / `_c` | ACK sát `mret`, ngắt chen giữa ACK/`mret` (lỗi C4), dùng ảnh `tb/asm/irq_dir.S` |
| `tb_id_ex_reg`, `tb_cpu_flush_hold_b` / `_c` | thanh ghi ID/EX khi flush và hold cùng lúc |

**Ứng dụng chính (24 cấu hình)**: `tb_cpu_fir_timer_1000_b/_c`, ma trận 6 dataset × B/C,
`stress`, `reset`, `late` (B/C) và 4 negative test `timing_fault`/`jitter_fault` (B/C).
Mặc định chỉ chạy `tb_cpu_fir_timer_1000_b`.
Testbench không tin signature của firmware: chúng quan sát giao dịch CPU/AXI/FIR/RAM và so với mô
hình tham chiếu riêng.

## 9. FIR HLS IP và dữ liệu kiểm chứng

### 9.1 Nguồn gốc IP

- Nguồn C: [hls/FIR11/FIR11/fir.cpp](hls/FIR11/FIR11/fir.cpp). Vitis HLS 2024.1, top `fir`, thiết bị
  `xc7z020-clg484-1`. Báo cáo HLS
  ([fir_csynth.rpt](hls/FIR11/FIR11/fir11_prj/fir/hls/syn/report/fir_csynth.rpt)): latency 18, interval 19.
  Wrapper đo `CYC_CNT = 17` (đếm từ lúc nhận DATA_IN tới `ap_done`).
- 8 file trong [rtl/Peripherals/FIR11/](rtl/Peripherals/FIR11/) được **chép nguyên trạng** từ
  `hls/FIR11/FIR11/fir11_prj/fir/hls/syn/verilog/` (không sửa tên module, hệ số, `$readmemh`).
  Hai thư mục giống nhau từng byte; **chỉ đưa một bộ module `fir` vào mỗi lần biên dịch**.
- Nếu chạy lại HLS: chép lại cả 8 file và cập nhật bảng SHA-256 dưới đây.

| File | SHA-256 |
|---|---|
| `fir.v` | `abbee508578dc96d2b1d71c7dc1a9713b20e332c868a378b8cdfb31f3859da4a` |
| `fir_fir_Pipeline_Shift_Accum_Loop.v` | `c24040dbd356f434d8b579e7e8ad22e80623f29c9fa761623e7abe02e4e07b73` |
| `fir_fir_Pipeline_Shift_Accum_Loop_fir_int_int_c_ROM_AUTO_1R.v` | `d1b1fa395ceb837ea34623ffab5b06a1bbc131ec433d54209520819395590eef` |
| `fir_fir_Pipeline_Shift_Accum_Loop_shift_reg_RAM_AUTO_1R1W.v` | `9f2fd0c014c538a7d9b98b997ca1ee6b42c17221ed8fee8284de6d34dbb1800b` |
| `fir_flow_control_loop_pipe_sequential_init.v` | `398725a9a4fd66384fdf1b04ac25e54faca56a534928e48829d5290e1bd8e305` |
| `fir_mul_11s_32s_32_2_1.v` | `fa71e94bdb4b891825a364701360599f8a99825064b6885777884cbe37de9009` |
| `fir_fir_Pipeline_Shift_Accum_Loop_fir_int_int_c_ROM_AUTO_1R.dat` | `351eef83b1a2cd212ab13ba97212401cce4171b8e244f799c4ff1d20413d7466` |
| `fir_fir_Pipeline_Shift_Accum_Loop_shift_reg_RAM_AUTO_1R1W.dat` | `d88918b810dfe5f03f2409f9b5524274099f73aceee96c05cbbac7330a1a995b` |

Kiểm lại: `sha256sum rtl/Peripherals/FIR11/*.v rtl/Peripherals/FIR11/*.dat`.

### 9.2 Hai file `.dat` bắt buộc

| File | Nội dung |
|---|---|
| `fir_..._fir_int_int_c_ROM_AUTO_1R.dat` | 11 hệ số của ROM |
| `fir_..._shift_reg_RAM_AUTO_1R1W.dat` | 11 số 0, giá trị đầu của `shift_reg` |

RTL HLS nạp chúng bằng `$readmemh("./<tên>.dat")`, tức là **tương đối với thư mục làm việc** của
simulator/Vivado. Thiếu file thì ROM hệ số là X và kết quả FIR sai; testbench báo
`TEST FAILED: HLS ROM/RAM .dat not loaded`. Cách cung cấp:

- `run_rtl_tests.py`: tự chép vào `outfeed/<test>/`.
- Chạy tay: `bash scripts/prep_fir11_dat.sh <thư mục mô phỏng>`.
- Synthesis: `fpga/synth_soc.tcl` chép vào thư mục chạy Vivado; `run_vivado_synth.py` bắt buộc log có
  `$readmem data file ... is read successfully` cho cả 2 file `.dat` và `program.mem`, `data.mem`.

Hai file này là dữ liệu của IP FIR, khác `program.mem`/`data.mem` (lệnh và dữ liệu của CPU).

### 9.3 Dữ liệu kiểm chứng và đồ thị

```bash
python data_test/fir_test/generate_fir_data.py     # input.dat/expected.dat từ hệ số trong fir.cpp
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado --tests tb_fir11_vectors
python scripts/plot_fir_rtl_results.py             # so bit-exact, vẽ đồ thị -> data_test/fir_test/rtl_plots/
python scripts/view_fir_plots.py [1-6] [--window]  # xem trong trình duyệt / cửa sổ Python
```

| Test | Tín hiệu (1 000 mẫu, FS = 10 kHz) |
|---|---|
| `test_01_low` | sin 500 Hz |
| `test_02_high` | sin 4 000 Hz |
| `test_03_mixed` | 500 Hz + 4 000 Hz |
| `test_04_noise` | 500 Hz + 4 000 Hz + nhiễu Gauss |
| `test_05_impulse` | xung x[0] = 1 000 |
| `test_06_step` | bậc x[n ≥ 100] = 1 000 |

- `expected.dat`: `y[n] = Σ c[k]·x[n−k]`, số nguyên signed 32-bit, wrap khi tràn, lịch sử đầu bằng 0.
  Script dừng nếu không đọc được hệ số từ `fir.cpp`.
- `plot_fir_rtl_results.py` so từng mẫu, không tolerance; exit 1 nếu có test sai hoặc thiếu
  `actual.dat` (không bao giờ dùng `expected.dat` thay thế). Mỗi hình có bản `.png` và `.svg`.
- MATLAB: `cd scripts; view_fir_plots(3)` (không cần toolbox, đã chạy với R2024b).
- `data_test/fir_1000/` (sinh bởi `gen_fir_1000_data.py` từ `test_04_noise`): 1 000 mẫu cho firmware
  ở RAM ngoài, `input[1000]` tại `0x4001_0000`, `output[1000]` tại `0x4001_1000`.

## 10. RAM ngoài: cache và SDRAM mô phỏng

Chỉ dùng ở cấu hình B/C. Nguồn gốc: `cache_controller.v` và `sdram.v` từ tiny-riscv-soc (MIT),
có sửa đổi ghi ở đầu mỗi file.

```text
axi_interconnect: WRITE_FSM / READ_FSM (giữ yêu cầu tới done, timeout -> SLVERR)
   -> axi_ext_ram_arbiter (ghi trước đọc sau; chốt địa chỉ/dữ liệu khi cấp quyền; bỏ completion muộn)
   -> cache_top #(USE_CACHE)
        USE_CACHE=1: cache_controller  |  USE_CACHE=0: bypass
        -> cache_dma_arbiter (đầu vào DMA buộc 0)
        -> sdram_top = refresh_controller + sdram_fsm + sdram_controller + sdram_model
```

| Khối | Đặc điểm (đọc từ RTL) |
|---|---|
| Cache | direct-mapped 1 way, 64 line × 16 byte = 1 KB, chỉ dữ liệu. tag `addr[31:10]`, index `addr[9:4]`, word `addr[3:2]`. Đọc miss: refill 4 yêu cầu word riêng (không burst). Ghi: write-through, miss thì write-no-allocate. Valid bit xóa khi reset |
| SDRAM controller | bus dữ liệu 16 bit, mỗi word = ACTIVATE → 2 halfword → PRECHARGE (không burst); refresh mỗi 780 chu kỳ; `ready` là xung 1 chu kỳ |
| Ánh xạ địa chỉ (đã sửa so với bản gốc) | halfword `{bank,row,col} = addr[24:1]`, tuyến tính, không bí danh; bản gốc làm 0x000 và 0x400 trùng ô nhớ |
| `sdram_model` | mảng 32 768 × 16 bit (64 KB), `initial` xóa 0, đọc trả sau 1 cạnh clock; không mô phỏng CAS latency, tRCD/tRP/tRFC, LOAD MODE |
| Giới hạn đã biết (chưa sửa) | `refresh_controller`: nếu bộ đếm chạm chu kỳ refresh đúng lúc `refresh_done` thì yêu cầu refresh đó bị xóa; chỉ xảy ra khi refresh bị chặn đúng 780 chu kỳ |

**Giới hạn FPGA**: `sdram_top` chứa luôn `sdram_model` và **không có chân ra ngoài**. Vivado tổng hợp được
(64 KB → 17 BRAM36 ở cấu hình C) nhưng đó chỉ là BRAM bọc trong giao thức lệnh SDRAM, không phải
chip SDRAM trên board. Luồng chính cần thay `sdram_top` bằng backend
BRAM trên cùng giao diện `cpu_*` (module `main_memory` trong `cache_controller.v` là tham chiếu, hiện
không được instance) hoặc một controller/PHY SDRAM thật theo board.

Testbench nạp dữ liệu vào `sdram_model` trực tiếp (model không có `$readmemh`); trên FPGA cần
bootloader/UART/DMA để nạp dữ liệu, SoC chưa có.

## 11. Kết quả kiểm chứng

Kiểm tra trên HDL Block Design do Vivado sinh ra, dùng các scoreboard hiện có:

| Nhóm | Cấu hình | Kết quả |
|---|---|---|
| Elaboration và reset | A | PASS |
| 1000 mẫu noise, đối chiếu từng chu kỳ với RTL gốc | B/C | 2 PASS, mỗi bài 83 checks, 0 lỗi |
| Lỗi bus, BUSERR, timeout và orphan | B/C | 2 PASS, mỗi bài 32 checks, 0 lỗi |
| Reset giữa giao dịch rồi chạy lại đủ 1000 mẫu | B/C | 2 PASS, B: 134 checks; C: 151 checks; 0 lỗi |
| **Tổng** | **7 bài mô phỏng** | **7 PASS** |

Xem [hướng dẫn chạy kiểm tra Block Design](docs/BLOCK_DESIGN.md#kiểm-tra-trên-thiết-kế-mới).
Log, testbench sinh ra và hash source/ảnh bộ nhớ nằm trong
`outfeed/block_design/<cfg>/checks/<test>/`. Các bài đối chiếu theo chu kỳ
dùng dataset noise; đây là kiểm chứng bằng mô phỏng, không phải chứng minh formal mọi input.

## 12. Synthesis và timing

```bash
# Kiểm synthesis cấu hình C với firmware chính; không tạo bitstream, không nạp input RAM
python scripts/run_vivado_synth.py --vivado-root D:/vivado/2026.1/Vivado --cfg C

# Tạo Block Design, synthesis toàn top và xuất sơ đồ
python scripts/run_block_design.py --vivado-root D:/vivado/2026.1/Vivado --cfg C --synth --diagram
```

Hai luồng dùng cấu hình C và firmware `fir_timer_1000`.

Part `xc7z020clg484-1` (cùng part với báo cáo HLS; dùng để ước lượng tài nguyên/timing, board chưa
xác định). Ràng buộc: [fpga/soc_top.xdc](fpga/soc_top.xdc) chỉ có clock 100 MHz, chưa gán chân.

Kết quả Block Design C, top `soc_system_wrapper`, Vivado 2026.1:

| Hạng mục | Sau synthesis |
|---|---|
| LUT / Flip-flop | 3 433 / 3 174 |
| Latch | 0 |
| BRAM36 / DSP | 17 / 2 |
| Khởi tạo bộ nhớ | `program.mem`, `data.mem`, 2 file FIR `.dat` nạp thành công |
| Critical warning / error | 0 / 0 |
| Timing 100 MHz | Chưa đạt: WNS −4,945 ns, TNS −1526,985 ns |

**Synthesis PASS; timing closure không thuộc yêu cầu project.** Giữ clock
constraint 100 MHz; không chạy place/route cho phần Block Design này.
Log và báo cáo nằm trong `outfeed/block_design/C/`; lần tái tạo từ thư mục
mới với cùng kết quả nằm trong `outfeed/block_design/clean_C/`.

## 13. Giới hạn và việc cần làm trước khi chạy FPGA

Project **mới được kiểm chứng bằng mô phỏng và synthesis/implementation**, chưa chạy trên phần cứng.

1. **Gán chân board**: thêm `PACKAGE_PIN`/`IOSTANDARD` cho `clk`, `rst_n` (tích cực mức thấp),
   `cpu_irq`, `bus_error` vào XDC (nếu thiếu, `write_bitstream` sẽ dừng ở DRC NSTD/UCIO).
2. **Clock**: 100 MHz không đạt timing. Dùng ≤ 75 MHz (khuyên 50 MHz qua MMCM) hoặc sửa pipeline CPU.
   Khi đổi clock, chỉnh `FIR_TIMER_PERIOD` trong firmware (10 kHz = f_clk / 10 000).
3. **Bộ nhớ**: luồng chính cần RAM ngoài B/C. Thay backend mô phỏng bằng RAM triển khai được
   trên board và bổ sung cơ chế nạp input/đọc output; cấu hình A không đủ cho firmware chính.
4. **Quan sát**: chỉ có 2 chân trạng thái; cần thêm UART/GPIO hoặc ILA để đọc kết quả.
5. **Firmware cố định lúc synthesis** (IMEM/DMEM `$readmemh`): đổi chương trình thì synth lại hoặc
   dùng `updatemem`.

Giới hạn khác của thiết kế: CPU là tập con RV32I (không có byte/halfword load-store, `bltu/bgeu`,
`sltu`, M extension), không có CSR/trap ngoại lệ, một mức ngắt không lồng; IMEM/DMEM chỉ 1 KB;
lỗi bus không gây trap (phần mềm đọc BUSERR); chưa kiểm chứng ISA đầy đủ.

## 14. Tài liệu hướng dẫn

| Tài liệu | Nội dung |
|---|---|
| [docs/FIR_READING_GUIDE.md](docs/FIR_READING_GUIDE.md) | Thứ tự đọc code, luồng Timer/FIR IRQ, test và waveform |
| [docs/BLOCK_DESIGN.md](docs/BLOCK_DESIGN.md) | Tạo/mở project Vivado, gom bus, chạy mô phỏng và synthesis |
| [firmware/README.md](firmware/README.md) | Firmware chính, build và nạp ảnh bộ nhớ trong mô phỏng |

## 15. Lưu ý khi sử dụng

- **Đường dẫn không có khoảng trắng** cho `tb_fir11_vectors` (`--output`, `--vector-dir`,
  `--outfeed-dir`): xsim `-testplusarg` treo khi gặp khoảng trắng; script báo lỗi trước.
- **`actual.dat` dùng xuống dòng CRLF** (XSim trên Windows); bỏ `\r` trước khi so bằng `cmp`.
- **Reset**: chân `rst_n` đi qua `reset_sync`, DUT ra khỏi reset sau 2 cạnh clock kể từ khi nhả chân.
- Waveform: `--wave` ghi toàn bộ tín hiệu (ví dụ `tb_fir11_vectors.wdb` khoảng 24 MB);
  `--open-wave <tb>` mở bằng `bin/xsim.bat -gui`. Với `tb_cpu_fir_timer_1000_*` (≈ 10 triệu chu kỳ)
  nên giới hạn bằng `--wave-time 500us` (đủ 4 mẫu đầu, tick đầu ở chu kỳ 10 553).
- `outfeed/tb_*/` và `outfeed/synth_*/` xóa được bất cứ lúc nào; chạy lại test/synthesis sẽ tạo lại.
