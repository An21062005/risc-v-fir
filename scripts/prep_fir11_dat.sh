#!/usr/bin/env bash
# Chép 2 file khởi tạo RAM/ROM của FIR11 HLS vào thư mục chạy mô phỏng.
# RTL HLS nạp bằng $readmemh("./<tên>.dat"), tức tương đối với thư mục làm
# việc của simulator (nơi chạy vsim/xsim/vvp), KHÔNG phải thư mục chứa .v.
# Không đụng tới program.mem / data.mem của CPU.
#
# Dùng: bash scripts/prep_fir11_dat.sh <thư mục chạy mô phỏng>
#       (chạy từ thư mục dự án; mặc định: sim_fir11)
set -eu
RUN_DIR="${1:-sim_fir11}"
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)/rtl/Peripherals/FIR11"
mkdir -p "$RUN_DIR"
for f in fir_fir_Pipeline_Shift_Accum_Loop_fir_int_int_c_ROM_AUTO_1R.dat \
         fir_fir_Pipeline_Shift_Accum_Loop_shift_reg_RAM_AUTO_1R1W.dat; do
    cp "$SRC_DIR/$f" "$RUN_DIR/$f"
    echo "copied $f -> $RUN_DIR/"
done
