/* fir_1000_data.h - SINH TỰ ĐỘNG bởi scripts/gen_fir_1000_data.py, không sửa tay. */
/* Nguồn: data_test/fir_test/output/test_04_noise/input.dat mẫu [0, 1000), xem data_test/fir_1000/manifest.txt */
#ifndef FIR_1000_DATA_H
#define FIR_1000_DATA_H

#define FIR1000_N        1000
#define FIR1000_IN_ADDR  0x40010000u   /* input[1000] trong RAM ngoài */
#define FIR1000_OUT_ADDR 0x40011000u   /* output[1000] trong RAM ngoài */
#define FIR1000_IN_SUM   0xFFFFEF10u   /* tổng x mod 2^32: kiểm dữ liệu vào */
#define FIR1000_EXP_SUM  0xFFF0AE4Cu   /* tổng y kỳ vọng mod 2^32 */
#define FIR1000_EXP_XOR  0x0015ED26u   /* XOR y kỳ vọng */

#endif
