# rtl/Peripherals/FIR11: RTL FIR11 do Vitis HLS sinh ra (bản sao)

Nguồn: `hls/FIR11/FIR11/fir11_prj/fir/hls/syn/verilog/` (Vitis HLS v2024.1, top `fir`,
C gốc `hls/FIR11/FIR11/fir.cpp`, hệ số `{54,0,-92,0,313,500,313,0,-92,0,54}`).
Báo cáo: `hls/FIR11/FIR11/fir11_prj/fir/hls/syn/report/fir_csynth.rpt`
(latency 18, interval 19 — số liệu HLS). Regression XSim đo `CYC_CNT = 17`;
đây là phép đếm ở wrapper, không thay thế số liệu tổng hợp/timing vật lý.

8 file được **chép nguyên trạng**, không sửa (tên module, hệ số, `$readmemh` giữ nguyên).
SHA-256 tại lúc chép (2026-10-14), khớp với thư mục nguồn:

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

Kiểm lại: `sha256sum rtl/Peripherals/FIR11/* hls/FIR11/FIR11/fir11_prj/fir/hls/syn/verilog/*`.
Nếu chạy lại HLS, chép lại cả 8 file và cập nhật bảng này.

## Đưa vào biên dịch

- Cả 6 file `.v` đã nằm trong [rtl/filelist_fir11.f](../../filelist_fir11.f) (`fir.v` cần đủ 5 module con).
- **Chỉ một bộ module `fir`** trong mỗi lần biên dịch: không thêm đồng thời thư mục nguồn
  `hls/FIR11/.../syn/verilog/` (cùng tên module `fir`).
- Khối bọc: [../fir11_wrapper.v](../fir11_wrapper.v).

## File `.dat`

`fir_..._ROM_AUTO_1R.dat` (11 hệ số) và `fir_..._shift_reg_RAM_AUTO_1R1W.dat` (11 số 0, giá trị đầu
của `shift_reg`) được nạp bằng `$readmemh("./<tên>.dat")`, tức **tương đối với thư mục làm việc
của simulator**. Trước khi mô phỏng:

```bash
bash scripts/prep_fir11_dat.sh <thư mục chạy mô phỏng>   # ví dụ sim_fir11
```

Thiếu file: ROM hệ số toàn X, kết quả FIR sai/X. Đây là dữ liệu của IP FIR,
khác `program.mem`/`data.mem` (bộ nhớ lệnh/dữ liệu CPU).

## Chạy testbench khối FIR11

Đã chạy với XSim; kết quả, giao thức đọc một xung và lệnh chạy tự động:
[RTL_FIX_VERIFICATION.md](../../../docs/RTL_FIX_VERIFICATION.md).

```bash
bash scripts/prep_fir11_dat.sh sim_fir11 && cd sim_fir11
vlib work
vlog ../rtl/Peripherals/fir11_wrapper.v ../rtl/Peripherals/FIR11/*.v ../tb/tb_fir11_wrapper.v
vsim -c tb_fir11_wrapper -do "run -all; quit -f"
```

PASS chỉ khi log có `TEST PASSED`, không có `TEST FAILED`/`** Error`/`** Fatal`. Ghi lại dòng
`INFO CYC_CNT ... = N cycles` (regression hiện tại: 17).
