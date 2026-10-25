# Quy tắc làm việc: Vivado Block Design

## Phạm vi đã thống nhất

- Project phục vụ mô phỏng và synthesis; không yêu cầu chạy trên board thật.
- Dựng Vivado IP Integrator Block Design có thể sinh HDL và synthesis được,
  đồng thời gom chân, đặt tên rõ ràng, bố trí dây dễ đọc như ảnh tham chiếu.
- Giữ kiến trúc và hành vi của RTL hiện tại. Không dùng việc làm đẹp sơ đồ
  làm lý do thay đổi giao thức, thuật toán hoặc độ trễ xử lý.
- Mốc trước khi tích hợp: commit `72dc8636e50a023ed337729b8b38b8d7917faef1`,
  đã push lên `main` của `https://github.com/An21062005/risc-v-fir`.

## Kiến trúc phải giữ

```text
RV32I CPU -> CPU AXI4-Lite Master -> Custom Interconnect
                                     |-> Timer
                                     |-> Interrupt
                                     |-> FIR Accelerator
                                     `-> External RAM / Cache (theo cấu hình)

Timer IRQ ----> Interrupt Controller ----> cpu_irq ----> CPU
FIR IRQ ------^
```

- CPU: `rvcore32_pipeline_soc`, pipeline 5 giai đoạn, IMEM/DMEM và logic
  hazard/forwarding/stall/trap nằm bên trong khối CPU.
- AXI Master: `cpu_axi_master` nối CPU với phía AXI4-Lite của interconnect.
- Interconnect: tiếp tục dùng `axi_interconnect` trong
  `rtl/AXI/AXI_Interconnect.v`, giữ giải mã địa chỉ, FSM đọc/ghi,
  timeout và phản hồi lỗi.
- Phía Timer/FIR/Interrupt dùng bus MMIO hiện tại gồm xung đọc/ghi,
  địa chỉ và dữ liệu; đây không phải các AXI4-Lite slave độc lập.
- Khối Interrupt có thể chứa cả `interrupt_axi_wrapper` và
  `interrupt_controller`; giữ nguyên đường ngắt và thứ tự ưu tiên.
- Khối FIR Accelerator chứa `fir11_wrapper` và FIR11 HLS hiện tại.
- RAM ngoài giữ `ENABLE_EXT_RAM` và `EXT_RAM_USE_CACHE`:
  A = không RAM ngoài; B = RAM bypass cache; C = RAM có cache.
  Giữ cache, arbiter và backend SDRAM model hiện có theo cấu hình.

Địa chỉ nhìn từ CPU phải giữ nguyên:

| Khối | Địa chỉ gốc |
|---|---|
| Timer | `0x4000_0080` |
| Interrupt | `0x4000_01C0` |
| FIR | `0x4000_0200` |
| External RAM 64 KB | `0x4001_0000` |

CPU bỏ hai bit địa chỉ cao trước khi phát ra bus. Giữ nguyên cách dịch
địa chỉ này, toàn bộ offset thanh ghi, tác dụng phụ đọc/ghi và firmware.

## Clock và reset đã chốt

- Giữ một miền clock hệ thống như RTL hiện tại: CPU, AXI Master,
  interconnect, ngoại vi và RAM/cache khi bật nhận cùng nguồn `clk`.
- `fir11_wrapper.clk` và FIR HLS `fir.ap_clk` nối cùng nguồn `clk`;
  không tách clock IP và clock wrapper trong công việc Block Design.
- Giữ chuỗi reset hiện tại: `rst_n` ngoài qua `reset_sync` thành
  `rst_n_sync`; các khối nhận đúng cực tính reset như trong `soc_top.v`.
- Giữ reset của FIR HLS: `ap_rst = ~rst_n | soft_rst_q` bên trong
  `fir11_wrapper`, với `rst_n` của wrapper nhận `rst_n_sync`.
- Không thêm bộ chia clock, PLL/MMCM, miền clock mới hoặc CDC.
  Tách đường clock/reset khi bố trí sơ đồ chỉ là cách trình bày dây,
  không phải tạo nguồn clock/reset độc lập cho từng khối.

## Cách triển khai được phép

- Ưu tiên thêm wrapper chỉ nối dây, định nghĩa bus/interface và metadata
  đóng gói IP để gom các tín hiệu thành cổng có tên trên Block Design.
- Đoạn AXI hiển thị thành `M_AXI` / `S_AXI`; bus CPU và bus MMIO dùng
  interface riêng phản ánh đúng các tín hiệu hiện có.
- Interconnect wrapper có thể đưa địa chỉ/dữ liệu chung ra từng nhóm
  `M_TIMER`, `M_FIR`, `M_IRQ` bằng nối dây tổ hợp. Không thêm thanh ghi,
  FSM, handshake mới hoặc chu kỳ chờ để phục vụ việc gom chân.
- Không đổi tên bus MMIO thành AXI và coi đó là chuyển đổi giao thức.
- Không thay custom interconnect bằng AMD AXI Interconnect/SmartConnect.
- Giữ các file logic gốc, đặc biệt CPU, interconnect và RTL HLS, nguyên vẹn
  trong bước tích hợp đầu tiên. Nếu gặp trở ngại, tìm giải pháp ở wrapper,
  metadata hoặc script trước; báo rõ nếu cần thay đổi hành vi ngoài phạm vi.
- Giữ `rtl/soc_top.v` và luồng build trực tiếp RTL làm bản đối chiếu.
  Thêm luồng build Block Design riêng, không xóa hoặc âm thầm thay thế bản cũ.
- Thêm script Tcl tái tạo IP/interface, Block Design, kết nối và HDL wrapper
  từ source được quản lý trong Git. Không phụ thuộc vào thao tác GUI thủ công.
- Dùng đường dẫn tương đối theo repo/tham số đầu vào; không cố định đường
  dẫn máy cá nhân trong định nghĩa IP hoặc thiết kế.
- Để sản phẩm sinh tự động, cache, checkpoint và log trong thư mục output
  được ignore. Quản lý trong Git các source/script/metadata cần để tái tạo.

## Yêu cầu sơ đồ

- Hiện riêng CPU, AXI Master, Interconnect, Timer, Interrupt và FIR;
  hiện RAM/cache khi cấu hình bật. Không gom cả SoC thành một ô duy nhất.
- Bố trí CPU -> AXI Master -> Interconnect từ trái sang phải, ngoại vi
  bên phải; tách đường clock/reset và đường IRQ cho dễ theo dõi.
- Gom bus thành interface có thể mở rộng xem chân chi tiết; dùng tên khối
  và cổng có ý nghĩa. Các khối con nằm trong hierarchy phù hợp.
- Các tín hiệu trạng thái, reset và lỗi bus vẫn phải nối đúng như `soc_top`;
  không bỏ kết nối cần thiết chỉ để giảm dây trên hình.
- Kiểm tra trực quan Block Design thực tế sau khi tạo; nếu xuất hình bàn giao,
  lấy từ thiết kế thực tế, giữ chữ đọc được và các khối chính nhìn thấy rõ.

## Kiểm tra và tiêu chí hoàn thành

1. Tái tạo thiết kế bằng script, chạy Validate Design, sinh output products
   và HDL wrapper thành công. Xử lý lỗi interface, chiều tín hiệu,
   clock/reset và các chân đầu vào chưa được điều khiển.
2. Mô phỏng đường tích hợp mới có chứa các wrapper/Block Design được thêm,
   so với hành vi RTL gốc: luồng chính 1000 mẫu ở B/C, dữ liệu FIR, IRQ,
   truy cập MMIO/RAM và trạng thái lỗi. Có thể tái sử dụng test hiện có;
   không chỉ chạy test trên `soc_top` cũ rồi coi như đã kiểm chứng Block Design.
3. Synthesis toàn bộ top mới, không chỉ synthesis từng IP rời. Cấu hình C
   với firmware `fir_timer_1000` là mục tiêu synthesis hiện hành của repo.
   Giữ khả năng chọn cấu hình A/B/C; kiểm tra elaboration các cấu hình
   được cung cấp qua luồng Block Design và báo rõ cấu hình đã synthesis.
4. Yêu cầu synthesis PASS: không ERROR, CRITICAL WARNING hoặc latch suy ra;
   kiểm tra nạp thành công `program.mem`, `data.mem` và hai file FIR11 `.dat`.
   Đọc báo cáo tài nguyên để phát hiện khối chính bị tối ưu mất ngoài dự kiến.
5. Giữ constraint clock hiện có và báo cáo timing trung thực. Synthesis PASS
   không đồng nghĩa timing closure; đạt timing sau place/route không phải
   tiêu chí bắt buộc của công việc này. Không nới clock để che lỗi tích hợp.
6. Ghi lại lệnh tái tạo, lệnh test/synthesis, top/cấu hình, kết quả và đường
   dẫn log/report. Nếu thiếu công cụ hoặc kiểm tra chưa chạy, nêu rõ giới hạn;
   không tuyên bố PASS chỉ vì script đã được viết.

Tham khảo luồng gốc: `scripts/run_rtl_tests.py`,
`scripts/run_vivado_synth.py`, `fpga/synth_soc.tcl`,
`docs/FIR_READING_GUIDE.md` và `firmware/README.md`.

## Chú thích và output

- Ưu tiên chú thích ngắn một dòng; bỏ banner, đoạn giải thích dài và lịch sử sửa lỗi trong code.
- Giữ ghi chú cần thiết cho giao thức, thứ tự xử lý, giấy phép và chỉ thị công cụ; hướng dẫn dài đặt trong README/docs.
- Giữ source và project/kết quả bàn giao; có thể dọn output thử, baseline cũ và cache không dùng. Giữ waveform đang dùng để xem.

## Ngoài phạm vi

- Không triển khai trên board, gán package pin/IOSTANDARD hoặc tạo/nạp bitstream.
- Không thay SDRAM model bằng controller/PHY thật, thêm UART/DMA/bootloader,
  hoặc thiết kế cơ chế nạp dữ liệu trên board.
- Không sửa pipeline, tối ưu timing hoặc mở rộng ISA/firmware trong công việc này.
- Không bắt buộc chạy place/route; chỉ chạy thêm nếu cần điều tra vấn đề cụ thể.
- Commit/push baseline đã hoàn tất. Không tự động commit/push phần Block Design
  chỉ dựa trên quyền push baseline; thực hiện khi người dùng yêu cầu tương ứng.
