// Danh sách nguồn cấu hình FIR11 HLS thật (soc_top mặc định).
// Đường dẫn tính từ thư mục dự án riscv-soc-fir-hls; chạy vlog từ đó.
// Không thêm hls/FIR11/.../syn/verilog/*.v (nguồn gốc của bản sao) vì trùng
// tên module `fir`. RAM ngoài (cấu hình B/C): thêm rtl/filelist_ext_ram_sim.f
// (cache_top + sdram_top trong rtl/Memory/cache_controller.v, sdram.v).
// Trước khi mô phỏng: chép 2 file .dat (scripts/prep_fir11_dat.sh).
+incdir+rtl/packages

// SoC
rtl/soc_top.v
rtl/cpu_soc.v
rtl/CPU/cpu.v
rtl/CPU/Pipeline_Registers.v
rtl/AXI/AXI_master.v
rtl/AXI/AXI_Interconnect.v
rtl/Peripherals/timer.v
rtl/Peripherals/Interrupt_controller.v
rtl/Peripherals/interrupt_axi_wrapper.v
rtl/Peripherals/fir11_wrapper.v

// FIR11 HLS (Vitis HLS v2024.1, bản sao nguyên trạng)
rtl/Peripherals/FIR11/fir.v
rtl/Peripherals/FIR11/fir_fir_Pipeline_Shift_Accum_Loop.v
rtl/Peripherals/FIR11/fir_fir_Pipeline_Shift_Accum_Loop_fir_int_int_c_ROM_AUTO_1R.v
rtl/Peripherals/FIR11/fir_fir_Pipeline_Shift_Accum_Loop_shift_reg_RAM_AUTO_1R1W.v
rtl/Peripherals/FIR11/fir_flow_control_loop_pipe_sequential_init.v
rtl/Peripherals/FIR11/fir_mul_11s_32s_32_2_1.v
