# riscv-soc-fir-hls

SoC RISC-V có bộ lọc FIR 11 tap sinh bằng Vitis HLS, gắn vào bus qua `fir11_wrapper`.
README này hướng dẫn chạy test RTL, compile thủ công, mở waveform, tạo dữ liệu tham chiếu
và xem đồ thị so sánh FIR RTL với mô hình Python.

Mọi lệnh bên dưới chạy trong **Git Bash** tại thư mục gốc của project. Tất cả các script
tự xác định project root từ vị trí của chúng, nên không bắt buộc phải `cd` vào đâu cả.

## Cấu trúc thư mục

```text
riscv-soc-fir-hls/
├── hls/FIR11/FIR11/          # C HLS: fir.cpp (hệ số c[]), fir.h, report csynth
├── rtl/                      # RTL SoC: CPU, AXI, peripheral, FIR11 HLS (bản sao)
│   ├── Peripherals/fir11_wrapper.v
│   ├── Peripherals/FIR11/    # RTL do Vitis HLS sinh + 2 file ROM/RAM .dat
│   └── filelist_fir11.f      # danh sách nguồn SoC
├── firmware/                 # firmware C cho CPU (build/ sinh ra, gitignore)
│   ├── startup.S, linker.ld  # dùng chung cho mọi firmware
│   ├── main.c                # Bước 1: smoke test CPU
│   ├── fir_smoke.c           # Bước 2: 1 mẫu FIR qua AXI
│   ├── fir_stream.c          # Bước 3: 32 mẫu DMEM -> FIR -> DMEM (+ fir_stream_data.h sinh tự động)
│   ├── ext_ram_test.c        # Bước 4a: lw/sw RAM ngoài 64 KB
│   └── fir_1000.c            # Bước 4: 1000 mẫu RAM ngoài -> FIR -> RAM ngoài (+ fir_1000_data.h)
├── tb/                       # testbench Verilog self-checking (cpu_soc_monitor.vh: checker dùng chung)
├── scripts/
│   ├── run_rtl_tests.py      # compile + chạy test XSim, ghi waveform, mở GUI
│   ├── build_firmware.py     # GCC build firmware + kiểm tra ISA/IMEM/DMEM -> program.mem, data.mem
│   ├── gen_fir_stream_data.py   # sinh firmware/fir_stream_data.h (32 mẫu + expected)
│   ├── gen_fir_1000_data.py  # sinh data_test/fir_1000/ + firmware/fir_1000_data.h
│   ├── plot_fir_rtl_results.py  # phân tích + vẽ đồ thị RTL vs Python
│   ├── view_fir_plots.py     # xem đồ thị từng test: trình duyệt hoặc cửa sổ Python
│   ├── view_fir_plots.m      # xem đồ thị từng test bằng MATLAB
│   └── prep_fir11_dat.sh     # chép 2 file .dat của HLS vào thư mục mô phỏng
├── data_test/fir_test/
│   ├── generate_fir_data.py  # tạo input/expected từ hệ số trong fir.cpp
│   ├── output/<test>/        # input.dat, expected.dat (Python)
│   └── rtl_plots/            # đồ thị + summary.txt so sánh RTL vs Python
├── data_test/fir_1000/       # Bước 4: input/expected/layout.mem 1000 mẫu + manifest.txt (nguồn, SHA-256)
├── outfeed/
│   ├── <test>/actual.dat     # kết quả FIR RTL của tb_fir11_vectors
│   └── tb_*/                 # build, log, waveform XSim của từng testbench (gitignore)
└── docs/RTL_FIX_VERIFICATION.md
```

Sáu test dữ liệu FIR, mỗi test 1000 mẫu, FS = 10 kHz:

| Test | Tín hiệu |
|---|---|
| `test_01_low` | sin 500 Hz |
| `test_02_high` | sin 4000 Hz |
| `test_03_mixed` | 500 Hz + 4000 Hz |
| `test_04_noise` | 500 Hz + 4000 Hz + nhiễu Gauss |
| `test_05_impulse` | xung x[0] = 1000 |
| `test_06_step` | bậc thang x[n ≥ 100] = 1000 |

## Yêu cầu

- **Vivado 2026.1 (XSim)**, đường dẫn mặc định `D:/vivado/2026.1/Vivado`. Đây là simulator
  dùng để chạy test.
- **Questa 10.7c** (tùy chọn): chỉ dùng được `vlog -lint`; `vsim` không có license runtime.
- **Python 3** với `numpy`, `scipy`, `matplotlib` (đã thử với Python 3.14, numpy 2.4,
  scipy 1.17, matplotlib 3.11).

Để khỏi gõ `--vivado-root` mỗi lần, có thể đặt biến môi trường:

```bash
export XILINX_VIVADO=D:/vivado/2026.1/Vivado
```

Các ví dụ bên dưới vẫn ghi `--vivado-root` đầy đủ.

## Chạy nhanh toàn bộ luồng FIR

```bash
# 1. Tạo input.dat / expected.dat từ hệ số trong fir.cpp
python data_test/fir_test/generate_fir_data.py

# 2. Chạy RTL testbench với 6 bộ vector -> outfeed/<test>/actual.dat
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado --tests tb_fir11_vectors

# 3. So sánh bit-exact + vẽ đồ thị -> data_test/fir_test/rtl_plots/
python scripts/plot_fir_rtl_results.py

# 4. Xem kết quả trong trình duyệt
python scripts/view_fir_plots.py
```

## Chạy test RTL

```bash
# Regression mặc định (20 cấu hình, gồm I1/C4 và AXI fault; danh sách đầy đủ 56 cấu hình:
# docs/PHASE5_VERIFICATION.md)
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado

# Chỉ một vài test
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado --tests tb_fir11_wrapper tb_axi_fir

# Đổi seed cho test có random
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado --tests tb_ext_ram_axi_b tb_ext_ram_axi_c --seed 7
```

Mỗi lần chạy, script compile (`xvlog`), elaborate (`xelab`) rồi mô phỏng (`xsim`). Nó cũng tự
chép 2 file ROM/RAM `.dat` của HLS vào `outfeed/<testbench>/`. Một test chỉ được tính là PASS
khi log có `TEST PASSED` và không có `ERROR`, `FATAL` hay `TEST FAILED`. Script trả về exit 0
nếu tất cả PASS, exit 1 nếu có lỗi.

| Testbench | Nội dung |
|---|---|
| `tb_fir11_wrapper` | wrapper + FIR HLS thật: số âm, tràn 32-bit, overrun, xóa done, reset mềm |
| `tb_fir11_vectors` | 6 bộ vector `data_test/fir_test/output`, so bit-exact, ghi `actual.dat` |
| `tb_axi_fir` | interconnect + wrapper + HLS: hàng đợi, backpressure, strobe |
| `tb_ext_ram_cfgA` | cấu hình không có RAM ngoài |
| `tb_ext_ram_axi_b` / `_c` | RAM ngoài, bypass / có cache (random theo seed) |
| `tb_cpu_bus_b` / `_c` | CPU thật + FIR + IRQ + RAM, bypass / có cache |
| `tb_axi_fault` | interconnect: DECERR/SLVERR, timeout RAM ngoài, backpressure, scoreboard (A1/A2) |
| `tb_cpu_fault_b` / `_c` | CPU: SLVERR/DECERR + thanh ghi BUSERR, timeout đọc/ghi, phục hồi |
| `tb_irq_i1` | FIR IRQ khi gửi DATA_IN trước ACK (I1) |
| `tb_cpu_irq_c4_a` / `_b` / `_c` | ACK sát MRET, ngắt chen giữa ACK/MRET (C4); ảnh asm từ `tb/asm/irq_dir.S` |
| `tb_timer`, `tb_irq_ack`, `tb_id_ex_reg`, `tb_cpu_flush_hold_b` / `_c` | Timer, ACK pin-level, ID/EX flush+hold |

Kết quả Phase 5 (56/56 cấu hình, synthesis, timing): [docs/PHASE5_VERIFICATION.md](docs/PHASE5_VERIFICATION.md).

## Synthesis Vivado (không tạo bitstream)

```bash
# Top soc_top, cấu hình A, firmware fir_timer, clock 100 MHz (fpga/soc_top.xdc), synth + place/route
python scripts/run_vivado_synth.py --vivado-root D:/vivado/2026.1/Vivado --impl
```

Kết quả: synthesis PASS, **timing 100 MHz FAIL** (WNS −3,247 ns, Fmax ≈ 75 MHz; 50 MHz đạt).
`fpga/soc_top.xdc` chỉ có ràng buộc clock, chưa gán chân (board chưa xác định).

Test firmware (tùy chọn, cần GCC RISC-V của Vivado, chỉ chạy khi gọi tên qua `--tests`; mỗi test
tự build firmware trước khi mô phỏng):

| Testbench | Firmware | Nội dung |
|---|---|---|
| `tb_cpu_firmware` | `main.c` | Bước 1: CPU chạy C do GCC build, 12 kết quả trong signature DMEM |
| `tb_cpu_fir_firmware` | `fir_smoke.c` | Bước 2: CPU ghi 7 vào FIR qua AXI, chờ DONE, đọc 378 |
| `tb_cpu_fir_stream` | `fir_stream.c` | Bước 3: 32 mẫu DMEM -> FIR -> DMEM, so 32/32 với mô hình |
| `tb_cpu_ext_ram_b` / `_c` | `ext_ram_test.c` | Bước 4a: lw/sw RAM ngoài, không cache / có cache |
| `tb_cpu_fir_1000` / `_c` | `fir_1000.c` | Bước 4: 1000 mẫu RAM ngoài -> FIR -> RAM ngoài, không cache / có cache |

Các tùy chọn của `run_rtl_tests.py`:

| Tùy chọn | Ý nghĩa |
|---|---|
| `--tests T1 T2 ...` | chỉ chạy các testbench này |
| `--seed N` | seed cho test random (mặc định 1) |
| `--output DIR` | thư mục kết quả (mặc định `outfeed/`) |
| `--wave` | elaborate với `-debug typical`, ghi mọi tín hiệu vào `outfeed/<tb>/<tb>.wdb` |
| `--open-wave TB` | mở `outfeed/TB/TB.wdb` trong XSim GUI |
| `--vector-dir DIR` | bộ vector khác cho `tb_fir11_vectors`; khi đó `actual.dat` ghi vào `<output>/tb_fir11_vectors/actual/` |
| `--outfeed-dir DIR` | nơi ghi `<test>/actual.dat` |
| `--rtl-root DIR` | chạy regression trên một bản RTL khác |

Kết quả của `tb_fir11_vectors` in ra theo dạng:

```text
INFO VEC test_01_low: PASS 1000/1000 samples match
...
INFO VEC TOTAL: 6/6 tests PASS, 6000/6000 samples match, 0 mismatch
TEST PASSED
```

Log đầy đủ nằm ở `outfeed/<testbench>/simulate.log`; lỗi compile hay elaborate xem ở
`compile.log` và `elaborate.log` trong cùng thư mục.

## Compile thủ công

### XSim (Vivado)

Ví dụ compile và chạy riêng khối FIR (wrapper + HLS) trong một thư mục tùy chọn:

```bash
V=D:/vivado/2026.1/Vivado/bin
P=$(pwd)                                    # thư mục gốc project
bash scripts/prep_fir11_dat.sh sim_fir11    # chép 2 file .dat của HLS
cd sim_fir11

$V/xvlog.bat $P/rtl/Peripherals/fir11_wrapper.v $P/rtl/Peripherals/FIR11/*.v $P/tb/tb_fir11_wrapper.v
$V/xelab.bat tb_fir11_wrapper -s tb_fir11_wrapper -debug typical
$V/xsim.bat  tb_fir11_wrapper -runall
```

RTL của HLS nạp ROM hệ số bằng `$readmemh("./<tên>.dat")`, tức là đọc theo **thư mục làm việc
của simulator**. Thiếu 2 file `.dat` thì testbench báo `TEST FAILED: HLS ROM/RAM .dat not loaded`.
`run_rtl_tests.py` tự chép các file này, còn khi chạy tay thì dùng `prep_fir11_dat.sh`.
Thư mục `sim_fir11/` đã được gitignore.

Muốn compile cả SoC thì lấy danh sách nguồn trong `rtl/filelist_fir11.f` (thêm
`rtl/filelist_ext_ram_sim.f` cho cấu hình RAM ngoài) với `-i rtl/packages -i tb`, giống cách
`run_rtl_tests.py` đang làm.

### Lint bằng Questa

```bash
mkdir -p sim_lint && cd sim_lint && vlib work
vlog -lint ../rtl/Peripherals/fir11_wrapper.v ../rtl/Peripherals/FIR11/*.v ../tb/tb_fir11_vectors.v
```

Kết quả mong đợi là `Errors: 0, Warnings: 0`. Questa ở đây chỉ dùng để lint, không chạy
`vsim` được vì thiếu license.

## Firmware C trên CPU RISC-V

```bash
# Build riêng một firmware (mặc định smoke): firmware/build[/<tên>]/<tên>.elf, .dis, .map,
# program.mem, data.mem (+ symbols.mem cho fir_stream, ext_ram_test, fir_1000)
python scripts/build_firmware.py --firmware smoke|fir_smoke|fir_stream|ext_ram_test|fir_1000

# Build + chạy toàn bộ Bước 1-4 trên SoC thật (XSim), từ repo sạch
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado --tests     tb_cpu_firmware tb_cpu_fir_firmware tb_cpu_fir_stream     tb_cpu_ext_ram_b tb_cpu_ext_ram_c tb_cpu_fir_1000 tb_cpu_fir_1000_c
```

Dữ liệu sinh tự động đã có sẵn trong repo (`firmware/fir_stream_data.h`, `firmware/fir_1000_data.h`,
`data_test/fir_1000/`). Chỉ cần sinh lại khi đổi dữ liệu; `--check` xác nhận file trong repo khớp script:

```bash
python scripts/gen_fir_stream_data.py [--check]
python scripts/gen_fir_1000_data.py [--check]     # nguồn: data_test/fir_test/output/test_04_noise
```

Bước 4 dùng `soc_top #(ENABLE_EXT_RAM=1)`: RAM ngoài 64 KB tại CPU `0x4001_0000`
(`input[1000]` @ `0x4001_0000`, `output[1000]` @ `0x4001_1000`). `sdram_model` không có `$readmemh`,
nên `tb_cpu_fir_1000` nạp `input.mem` vào mô hình trước khi thả reset (chỉ dữ liệu kích thích;
trên FPGA thật cần bootloader/UART/DMA, SoC chưa có).

- **Toolchain:** `D:/vivado/2026.1/gnu/riscv/nt/bin/riscv64-unknown-elf-*` (bên trong là GCC 13.4),
  build với `-march=rv32i -mabi=ilp32 -Os`, không libc, không libgcc.
- **Bộ nhớ:** IMEM 1 KB tại `0x0000_0000` (`_start` = reset PC), DMEM 1 KB tại `0x1000_0000`
  (`.rodata`, `.data`, `.bss`, stack 256 byte ở cuối, căn 16 byte). CPU không đọc dữ liệu từ
  IMEM, nên mọi hằng số đều nằm trong DMEM và được nạp bằng `data.mem`.
- **Kiểm tra ISA:** `build_firmware.py` giải mã từng lệnh và **từ chối** các lệnh CPU này giải mã
  sai dù chúng thuộc RV32I: `lb/lh/lbu/lhu/sb/sh` (CPU chạy như `lw/sw`), `bltu/bgeu` (không bao
  giờ rẽ), `sltu/sltiu` (tính ra AND/ADD), cùng RV32M, FENCE và SYSTEM. Vì vậy firmware chỉ dùng
  `int`, không dùng `char`/`short`, `unsigned`, phép nhân/chia hay thư viện C.
- **Signature** ở đầu DMEM (`0x1000_0000`): status, `HALT` (do `startup.S` ghi), mã trả về và các
  trường riêng của từng firmware (mô tả ở đầu mỗi file `.c`). Testbench **không** tin signature: nó
  quan sát giao dịch CPU/AXI/FIR/RAM và so kết quả với mô hình tham chiếu riêng.
- Các test firmware không nằm trong regression mặc định, vì cần toolchain; muốn chạy phải gọi tên
  qua `--tests`. Thêm `--no-firmware-build` để dùng lại image đã build. Log ở
  `outfeed/<testbench>/simulate.log`.

## Waveform

```bash
# 1. Chạy test có ghi waveform -> outfeed/<tb>/<tb>.wdb
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado --tests tb_fir11_wrapper --wave

# 2. Mở waveform trong XSim GUI
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado --open-wave tb_fir11_wrapper
```

- `--wave` ghi toàn bộ tín hiệu (`log_wave -r /`). Kích thước tham khảo:
  `tb_fir11_wrapper.wdb` khoảng 0,4 MB, `tb_fir11_vectors.wdb` khoảng 24 MB.
- `--open-wave` gọi launcher chính thức `bin/xsim.bat -gui <tb>.wdb`. Lần đầu GUI mất khoảng
  10–20 giây để nạp. Trong GUI, kéo tín hiệu từ cửa sổ *Scope/Objects* vào cửa sổ wave, ví dụ
  `dut/ap_start`, `dut/ap_done`, `dut/busy_q`, `dut/x_q`, `dut/y_q`.
- Nếu chạy tay thì dùng `$V/xsim.bat -gui <tb>.wdb` ngay trong thư mục `outfeed/<tb>/`.
- Chạy test lại mà không có `--wave` sẽ không cập nhật file `.wdb` cũ. Muốn waveform khớp với
  lần chạy mới nhất thì chạy lại với `--wave`.

## Tạo dữ liệu tham chiếu FIR

```bash
python data_test/fir_test/generate_fir_data.py
```

Script này đọc 11 hệ số trực tiếp từ `hls/FIR11/FIR11/fir.cpp`; nếu không đọc được thì dừng,
không tự thiết kế hệ số mới. Nó tạo `input.dat` và `expected.dat` cho 6 test, tính theo
`y[n] = Σ c[k]·x[n−k]` với số nguyên signed 32-bit, wrap khi tràn, không chia SCALE, và lịch
sử 10 mẫu bằng 0 ở đầu mỗi test. Kết quả còn được kiểm lại bằng một vòng lặp Python thuần.
Báo cáo của bước này nằm ở `data_test/fir_test/output/summary.txt`.

## Phân tích và xem đồ thị RTL vs Python

### Vẽ đồ thị

```bash
python scripts/plot_fir_rtl_results.py
```

Script đọc `input.dat` và `expected.dat` từ `data_test/fir_test/output/`, đọc `actual.dat` từ
`outfeed/`, so sánh bit-exact từng mẫu (không tolerance, không dịch chuỗi), rồi tạo:

| File | Nội dung |
|---|---|
| `rtl_plots/<test>/time_domain.png` | input, expected, actual: toàn bộ 1000 mẫu + vùng phóng to |
| `rtl_plots/<test>/frequency_domain.png` | FFT: Hann + bỏ quá độ với sin; DFT không cửa sổ với xung/bậc |
| `rtl_plots/<test>/error.png` | `actual − expected`, hiển thị `BIT-EXACT PASS` hoặc `FAIL` kèm mẫu sai đầu tiên |
| `rtl_plots/fir_rtl_comparison.png` | hình tổng hợp mixed + noise (thời gian, FFT, sai số) cho báo cáo |
| `rtl_plots/summary.txt` | số mẫu khớp, max \|error\|, độ lợi 500/4000 Hz đo được so với lý thuyết |

Mỗi hình được lưu hai bản cùng tên: `.png` (200 dpi, 2600 px ngang, dùng để chèn báo cáo)
và `.svg` (vector, phóng to bao nhiêu cũng nét; trang HTML hiển thị bản này).

Script trả exit 0 khi cả 6 test bit-exact, exit 1 khi có test FAIL hoặc thiếu `actual.dat`.
Thiếu file thì test đó bị báo ERROR; script không bao giờ dùng `expected.dat` thay cho `actual.dat`.

### Xem trong cửa sổ đồ thị (zoom/pan như MATLAB)

```bash
python scripts/view_fir_plots.py 3 --window   # 3 cửa sổ của test 3: thời gian, tần số, sai số
python scripts/view_fir_plots.py --window     # cửa sổ hình tổng hợp mixed + noise
```

Các hình được vẽ lại trực tiếp từ `outfeed/` và `output/`, nên không phụ thuộc file PNG cũ.
Dùng thanh công cụ dưới cửa sổ: kính lúp để zoom vùng, mũi tên 4 chiều để kéo, Home để về
ban đầu, đĩa mềm để lưu hình. Đóng hết các cửa sổ thì lệnh kết thúc.

### Xem bằng MATLAB

Trong MATLAB (Command Window), đứng ở thư mục gốc project:

```matlab
cd scripts
view_fir_plots(1)        % test_01_low     - sin 500 Hz
view_fir_plots(2)        % test_02_high    - sin 4000 Hz
view_fir_plots(3)        % test_03_mixed   - 500 Hz + 4000 Hz
view_fir_plots(4)        % test_04_noise   - 500 Hz + 4000 Hz + nhiễu
view_fir_plots(5)        % test_05_impulse - đáp ứng xung
view_fir_plots(6)        % test_06_step    - đáp ứng bậc
view_fir_plots()         % hình tổng hợp mixed + noise
view_fir_plots('list')   % in trạng thái bit-exact 6 test, không vẽ
```

Hoặc mở thẳng từ Git Bash: `matlab -r "cd scripts; view_fir_plots(3)"`.

- Mỗi test mở 3 figure: miền thời gian, miền tần số và sai số. Command Window in kết quả
  bit-exact và độ lợi 500/4000 Hz đo được so với lý thuyết.
- Script đọc trực tiếp `input.dat`, `expected.dat` (`data_test/fir_test/output/`), `actual.dat`
  (`outfeed/`) và hệ số `c[]` trong `fir.cpp`, nên không phụ thuộc bản Python. Cách so sánh và
  đo độ lợi giống hệt bản Python, và kết quả đã đối chiếu là trùng nhau.
- Script không ghi file nào. Muốn lưu hình thì dùng menu *File → Save As* của figure, hoặc
  `exportgraphics(gcf, 'hinh.png', 'Resolution', 300)`.
- Chỉ dùng hàm MATLAB gốc, không cần toolbox. Đã chạy thử với MATLAB R2024b.

### Xem từng test trong trình duyệt

Gọi theo số thứ tự của test:

```bash
python scripts/view_fir_plots.py      # trang tổng quan: bảng PASS/FAIL + độ lợi
python scripts/view_fir_plots.py 1    # test_01_low     - sin 500 Hz
python scripts/view_fir_plots.py 2    # test_02_high    - sin 4000 Hz
python scripts/view_fir_plots.py 3    # test_03_mixed   - 500 Hz + 4000 Hz
python scripts/view_fir_plots.py 4    # test_04_noise   - 500 Hz + 4000 Hz + nhiễu
python scripts/view_fir_plots.py 5    # test_05_impulse - đáp ứng xung
python scripts/view_fir_plots.py 6    # test_06_step    - đáp ứng bậc
```

Tùy chọn thêm:

```bash
python scripts/view_fir_plots.py 3 --window  # mở test 3 trong cửa sổ đồ thị thay cho trình duyệt
python scripts/view_fir_plots.py 3 --regen   # vẽ lại từ outfeed/ rồi mở test 3
python scripts/view_fir_plots.py --list      # in trạng thái 6 test ra terminal
python scripts/view_fir_plots.py --no-open   # chỉ sinh HTML, không mở trình duyệt
```

Mỗi trang có thanh chuyển giữa các test, số liệu của test và 3 đồ thị. Script sinh
`rtl_plots/index.html` và `rtl_plots/<test>/index.html`. Tên đầy đủ (`test_03_mixed`) hoặc
tên loại (`mixed`) vẫn dùng được nếu cần.

## Lưu ý

- **Đường dẫn không được có khoảng trắng** với `tb_fir11_vectors` (`--output`, `--vector-dir`,
  `--outfeed-dir`), vì xsim `-testplusarg` bị treo khi gặp khoảng trắng. Script sẽ báo lỗi ngay
  thay vì treo.
- **Lịch sử FIR không bị reset xóa.** `shift_reg` của IP nằm trong RAM, `ap_rst` không xóa nó.
  Vì vậy `tb_fir11_vectors` gửi 10 mẫu 0 trước mỗi test; firmware cũng phải làm tương tự.
- **`actual.dat` dùng xuống dòng CRLF** (XSim trên Windows). Nội dung số giống hệt
  `expected.dat`; muốn so sánh bằng `cmp` thì bỏ `\r` trước.
- **`outfeed/tb_*/` là file sinh ra**, đã gitignore và xóa được bất cứ lúc nào; chạy lại test
  sẽ tạo lại. `outfeed/<test>/actual.dat` thì được git theo dõi.
- Kết quả kiểm chứng RTL chi tiết và lịch sử sửa lỗi xem
  [docs/RTL_FIX_VERIFICATION.md](docs/RTL_FIX_VERIFICATION.md).
