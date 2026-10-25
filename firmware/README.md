# Firmware chính: Timer IRQ → FIR HLS → RAM ngoài

Project chỉ giữ một chương trình C: [fir_timer_1000.c](fir_timer_1000.c).
Chương trình xử lý một khối 1000 mẫu trong RAM ngoài: Timer phát nhịp,
CPU gửi mẫu vào FIR HLS, ngắt FIR báo kết quả để CPU ghi về RAM.
Luồng này hiện chạy trong mô phỏng SoC cấu hình B/C.

## Các file cần đọc

| File | Vai trò |
|---|---|
| [fir_timer_1000.c](fir_timer_1000.c) | `main()`: làm sạch lịch sử FIR, bật Timer/ngắt, chờ 1000 output, kiểm kết quả |
| [fir_timer_isr.h](fir_timer_isr.h) | `try_send()`, `irq_handler()` và trạng thái `fst` điều phối từng mẫu |
| [soc_mmio.h](soc_mmio.h) | Địa chỉ thanh ghi Timer, bộ ngắt và FIR nhìn từ CPU |
| [fir_1000_data.h](fir_1000_data.h) | Số mẫu, địa chỉ input/output và checksum do bộ sinh dữ liệu tạo |
| [startup_irq.S](startup_irq.S) | Reset tại PC 0, đặt stack, xóa `.bss`, gọi `main`; vector IRQ 0x10 lưu/khôi phục thanh ghi và `mret` |
| [linker_irq.ld](linker_irq.ld) | Bố trí IMEM/DMEM 1 KB, vector và stack 256 byte |

## Luồng chạy

```text
reset → startup → main
  → gửi 10 mẫu 0 làm sạch lịch sử FIR
  → cấu hình Timer và bật ngắt Timer/FIR

Timer tick → irq_handler → ACK → try_send
  → đọc input[sent] tại RAM ngoài → ghi FIR_DATA_IN
  → wrapper khởi động FIR HLS

FIR hoàn tất → irq_handler → ACK → đọc FIR_DATA_OUT
  → ghi output[done] về RAM ngoài → tăng done

Đủ 1000 output → dừng Timer → main kiểm checksum → startup ghi HALT
```

Timer và FIR dùng cùng vector `0x10`; ISR phân biệt bằng `INT_STATUS`.
Đọc STATUS và ACK đúng code ngay đầu ISR. `sent == done` bảo đảm output
trước đã được thu rồi mới gửi mẫu tiếp. Gửi 10 mẫu 0 là bước khởi tạo của
luồng chính vì reset IP không xóa lịch sử mẫu trong RAM HLS.

## Build và nạp trong mô phỏng

Từ thư mục gốc repo:

```powershell
python scripts/build_firmware.py
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado
```

Build mặc định là `fir_timer_1000`; kết quả ở `firmware/build/fir_timer_1000/`.
`program.mem` chứa lệnh cho IMEM, `data.mem` chứa dữ liệu khởi tạo DMEM.
File `.dis` dùng đối chiếu PC/lệnh, `.map` và `symbols.mem` dùng tra địa chỉ.

Runner mặc định chạy `tb_cpu_fir_timer_1000_b` (RAM ngoài không cache),
sinh dữ liệu và header khớp nhau, build tại
`outfeed/tb_cpu_fir_timer_1000_b/firmware_build/`, rồi chép ảnh vào thư mục
simulator. CPU nạp `program.mem`/`data.mem` qua `$readmemh`.
Testbench nạp `input.mem` vào RAM ngoài trước khi thả reset. Header chỉ chứa
hằng số và checksum; nó không chứa mảng 1000 mẫu.

Input ở `0x40010000`, output ở `0x40011000`. Kết quả mỗi mẫu nằm trong
`outfeed/tb_cpu_fir_timer_1000_b/actual.dat`; log phải có `TEST PASSED`.
Để chạy cùng ứng dụng với cache, thêm `--tests tb_cpu_fir_timer_1000_c`.

## Kiểm chứng cùng ứng dụng

`fir_timer_1000_stress` build cùng nguồn với PERIOD=100 để kiểm quá tải.
Các biến thể dataset, reset, late và kiểm tra khối RTL được giữ để bảo vệ
luồng chính; không có chương trình C mẫu riêng.

```powershell
python scripts/gen_fir_1000_data.py --check
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado --fir-matrix
```

CPU chỉ hỗ trợ tập con RV32I. Build script kiểm từng word lệnh và giới hạn
bộ nhớ; dùng MMIO 32-bit `volatile`, không dùng byte/halfword, nhân/chia hay CSR.
PERIOD=10000 tương ứng 10 kHz khi clock 100 MHz.

## Giới hạn nạp FPGA thật

Luồng chính cần RAM ngoài. Backend hiện chứa `sdram_model` và dữ liệu được
nạp từ testbench; chưa có cơ chế nạp mẫu trên board. Script synthesis dùng
cấu hình C để kiểm netlist, chưa tạo bitstream. Cần thay backend RAM phù hợp
board, bổ sung đường nạp/đọc dữ liệu, gán chân và đóng timing trước khi chạy
phần cứng. Xem [lộ trình toàn SoC](../docs/FIR_READING_GUIDE.md).
