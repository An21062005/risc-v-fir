# rtl/Memory

Nội dung tài liệu của thư mục này (cấu hình A/B/C, cache, SDRAM mô phỏng, ánh xạ địa chỉ, giới hạn
FPGA, nguồn gốc và giấy phép) đã được gộp vào README chính:

- [Cấu hình SoC và bản đồ địa chỉ](../../README.md#4-cấu-hình-soc-và-bản-đồ-địa-chỉ)
- [RAM ngoài: cache và SDRAM mô phỏng](../../README.md#10-ram-ngoài-cache-và-sdram-mô-phỏng)
- [Testbench `tb_ext_ram_axi`, `tb_ext_ram_cfgA`](../../README.md#8-danh-sách-testbench) — chạy:
  `python scripts/run_rtl_tests.py --vivado-root <Vivado> --tests tb_ext_ram_axi_b tb_ext_ram_axi_c tb_ext_ram_cfgA`

File này được giữ lại chỉ vì chú thích trong `tb/tb_ext_ram_axi.v` còn trỏ tới đây.
