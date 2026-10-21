# rtl/Peripherals/FIR11

8 file RTL do Vitis HLS 2024.1 sinh ra, chép nguyên trạng từ
`hls/FIR11/FIR11/fir11_prj/fir/hls/syn/verilog/`. Nguồn gốc IP, bảng SHA-256, hai file `.dat` bắt
buộc và cách đưa vào mô phỏng/synthesis đã được gộp vào README chính:

- [FIR HLS IP và dữ liệu kiểm chứng](../../../README.md#9-fir-hls-ip-và-dữ-liệu-kiểm-chứng)
- Chạy testbench khối FIR: `python scripts/run_rtl_tests.py --vivado-root <Vivado> --tests tb_fir11_wrapper tb_fir11_vectors`
  (tự chép 2 file `.dat`); chạy tay: [mục 7](../../../README.md#7-mô-phỏng-và-regression).

File này được giữ lại chỉ vì chú thích trong `soc_top.v`, `fir11_wrapper.v` và
`tb/tb_fir11_wrapper.v` còn trỏ tới đây.
