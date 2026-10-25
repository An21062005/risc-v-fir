# Đọc luồng chính: 1000 mẫu bằng Timer/FIR IRQ

Bắt đầu tại [firmware/fir_timer_1000.c](../firmware/fir_timer_1000.c):
đọc `main()`, rồi [fir_timer_isr.h](../firmware/fir_timer_isr.h):
`try_send()` và `irq_handler()`. Đây là chương trình C duy nhất của project.

## 1. Khởi động và xử lý mẫu

```text
Reset PC=0 → startup_irq.S đặt sp, xóa .bss → main()
  → gửi 10 mẫu 0 làm sạch lịch sử FIR
  → ACK pending FIR → đặt PERIOD → bật Timer/FIR IRQ

Timer tick → interrupt controller → CPU vector 0x10
  → startup lưu thanh ghi → irq_handler đọc STATUS và ACK
  → try_send đọc input[sent] → ghi FIR_DATA_IN
  → CPU MEM → AXI master → interconnect → wrapper → FIR HLS
  → startup khôi phục thanh ghi → mret

FIR ap_done → wrapper chốt y và DONE → FIR IRQ → CPU vector 0x10
  → irq_handler đọc STATUS và ACK → đọc FIR_DATA_OUT (xóa DONE)
  → ghi output[done] về RAM → kiểm deadline → tăng done
  → try_send nếu còn backlog → khôi phục thanh ghi → mret

Đủ 1000 output → dừng Timer → main kiểm kết quả → HALT
```

Hai nguồn ngắt dùng chung vector; `INT_STATUS` cho biết nguồn đang phục vụ.
ISR ACK ngay đầu; Timer ưu tiên hơn FIR. `sent == done` bảo đảm chỉ có một
mẫu đang xử lý và output trước đã thu. Timer IRQ được mask sau 1000 lần
phát hành; clock Timer vẫn chạy tới sau lần lưu output cuối để kiểm deadline.

## 2. File theo từng tầng

| Thứ tự | Nguồn | Điểm cần theo |
|---|---|---|
| 1 | [fir_timer_1000.c](../firmware/fir_timer_1000.c) | `main`, `FT_N`, `FT_IN`, `FT_OUT`, khởi tạo và kết thúc |
| 2 | [fir_timer_isr.h](../firmware/fir_timer_isr.h) | `fst`, `try_send`, hai nhánh của `irq_handler` |
| 3 | [soc_mmio.h](../firmware/soc_mmio.h), [fir_1000_data.h](../firmware/fir_1000_data.h) | Thanh ghi MMIO, input tại 0x40010000, output tại 0x40011000 |
| 4 | [startup_irq.S](../firmware/startup_irq.S), [linker_irq.ld](../firmware/linker_irq.ld) | Reset, vector 0x10, stack, lưu/khôi phục thanh ghi, `mret` |
| 5 | [soc_top.v](../rtl/soc_top.v) | Kết nối CPU, AXI, Timer, bộ ngắt, FIR và RAM ngoài |
| 6 | [cpu_soc.v](../rtl/cpu_soc.v) | `lw/sw`, bus address, `bus_stall`, nhận IRQ và quay về |
| 7 | [AXI_master.v](../rtl/AXI/AXI_master.v), [AXI_Interconnect.v](../rtl/AXI/AXI_Interconnect.v) | Handshake và giải mã địa chỉ, xung đọc/ghi ngoại vi |
| 8 | [fir11_wrapper.v](../rtl/Peripherals/fir11_wrapper.v) | Giữ x, `ap_start`, chốt y, DONE/BUSY/IRQ, đọc DATA_OUT |
| 9 | [fir.cpp](../hls/FIR11/FIR11/fir.cpp), [fir.h](../hls/FIR11/FIR11/fir.h), [fir.v](../rtl/Peripherals/FIR11/fir.v) | Thuật toán FIR 11 tap và phần cứng HLS tương ứng |
| 10 | [timer.v](../rtl/Peripherals/timer.v), [interrupt_axi_wrapper.v](../rtl/Peripherals/interrupt_axi_wrapper.v), [Interrupt_controller.v](../rtl/Peripherals/Interrupt_controller.v) | Phát nhịp, pending/enable, claim/ACK và ưu tiên |
| 11 | [cache_controller.v](../rtl/Memory/cache_controller.v), [sdram.v](../rtl/Memory/sdram.v) | RAM ngoài không cache (B) hoặc có cache (C) |

Ví dụ: ghi `FIR_DATA_IN` tại địa chỉ CPU `0x40000200` tạo lệnh `sw`;
CPU bỏ hai bit địa chỉ cao để đưa `0x200` ra bus. Interconnect chọn FIR,
wrapper phát `ap_start`. FIR tính toán trong phần cứng, CPU chỉ điều phối.
Wrapper nhận giao diện xung `wr_en/rd_en` từ interconnect, không trực tiếp
nhận năm kênh AXI. Đọc `cpu_soc.v` trước `CPU/cpu.v` vì `soc_top` dùng
`rvcore32_pipeline_soc`; các thanh ghi pipeline nằm ở `CPU/Pipeline_Registers.v`.

## 3. Build, nạp và chạy

```powershell
python scripts/build_firmware.py
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado
```

Build mặc định tạo `firmware/build/fir_timer_1000/`. Runner mặc định chạy
`tb_cpu_fir_timer_1000_b` và tự build ảnh riêng trong
`outfeed/tb_cpu_fir_timer_1000_b/firmware_build/` theo đúng dataset.
Xem [firmware/README.md](../firmware/README.md) để phân biệt ảnh build riêng
và ảnh được simulator thực sự nạp.

[tb_cpu_fir_timer_1000.v](../tb/tb_cpu_fir_timer_1000.v) cấp clock/reset,
nạp input vào mô hình RAM và kiểm các giao dịch; CPU chạy firmware thật.
Đọc phần nạp trước reset và scoreboard khi cần biết dữ liệu vào từ đâu,
output được so với gì. Testbench đối chiếu từng output với mô hình Verilog
và expected Python, đồng thời kiểm giao thức và ngữ cảnh ngắt.

## 4. Waveform và kết quả

```powershell
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado --wave
python scripts/run_rtl_tests.py --vivado-root D:/vivado/2026.1/Vivado --open-wave tb_cpu_fir_timer_1000_b
```

Theo một tick qua các nhóm tín hiệu trong `tb_cpu_fir_timer_1000.dut`:

1. `cpu_irq`, `u_cpu.irq_take`, `u_cpu.mepc`, `u_cpu.in_irq`, `u_cpu.mret_take`.
2. `u_cpu.pc`, pipeline, `bus_rd/wr`, `bus_addr`, `bus_wdata/rdata`, `bus_ready`.
3. Các kênh AW/W/B và AR/R tại `u_axi_master`.
4. `fir_wr_en`, `fir_rd_en`, `u_fir.accept`, `x_q`, `ap_start`, `ap_done`, `y_q`, `done_q`.
5. Đọc/ghi RAM ngoài và trạng thái `fst` theo địa chỉ trong `symbols.mem`.

`outfeed/tb_cpu_fir_timer_1000_b/simulate.log` phải có `TEST PASSED`, không lỗi,
và runner trả thành công. `actual.dat` có 1000 output, `provenance.json` ghi
hash ảnh lệnh/dữ liệu đã dùng. Chạy cùng luồng có cache bằng
`--tests tb_cpu_fir_timer_1000_c`; `--fir-matrix` kiểm sáu dataset trong B/C.
Các test khối RTL và biến thể stress/reset/late bảo vệ các tình huống của cùng
luồng chính, không có thêm firmware mẫu để học theo.

## 5. Giới hạn FPGA

Luồng 1000 mẫu hiện dùng RAM mô phỏng; chưa có backend RAM ngoài và đường
nạp dữ liệu cho board thật. Synthesis không đồng nghĩa nạp chạy được:
cần hoàn thiện RAM, I/O, chân board và timing. CPU hỗ trợ tập con RV32I,
IMEM/DMEM 1 KB, không có CSR chuẩn hay ngắt lồng nhau.
