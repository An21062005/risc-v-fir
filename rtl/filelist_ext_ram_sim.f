// Bổ sung cho cấu hình B/C (soc_top ENABLE_EXT_RAM=1), dùng KÈM rtl/filelist_fir11.f.
// Đường dẫn tính từ thư mục dự án. CHỈ MÔ PHỎNG: sdram.v chứa sdram_top
// (instance sdram_model, thiết bị nhớ hành vi) - không đưa vào danh sách tổng hợp FPGA.
// cache_pkg.vh / sdram_pkg.vh nằm trong rtl/packages (+incdir đã có trong filelist_fir11.f).
// Phần chốt/giữ yêu cầu RAM nằm trong rtl/AXI/AXI_Interconnect.v (đã có trong filelist_fir11.f).
+incdir+rtl/packages

rtl/Memory/cache_controller.v
rtl/Memory/sdram.v
