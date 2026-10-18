/*
 * fir_stream.c - Bước 3: firmware C gửi 32 mẫu liên tiếp từ DMEM tới FIR11 HLS qua AXI
 * và lưu 32 kết quả vào DMEM. Build: scripts/build_firmware.py --firmware fir_stream
 *
 * Luồng: fir_input[i] (DMEM, .data) -> lw -> sw DATA_IN -> cpu_axi_master -> axi_interconnect
 *        -> fir11_wrapper -> fir (HLS) -> STATUS/DATA_OUT -> lw -> sw fir_output[i] (DMEM, .bss)
 *
 * Thanh ghi FIR (rtl/Peripherals/fir11_wrapper.v, CPU thấy 0x4000_0200):
 *   0x00 DATA_IN W, 0x04 DATA_OUT R (đọc xóa DONE), 0x08 STATUS R
 *   (bit0 DONE, bit1 ap_idle, bit2 ap_ready, bit3 BUSY, bit4 OVERRUN), 0x0C CTRL W (bit0 xóa DONE/OVERRUN)
 *
 * Lịch sử FIR: shift_reg của IP không bị rst_n / reset mềm xóa -> trước 32 mẫu firmware
 * đẩy 10 mẫu 0 (giao dịch thật qua AXI) để y[n] = sum c[k]*x[n-k] với x[<0] = 0.
 *
 * fir_expected[] do scripts/gen_fir_stream_data.py tính (mô hình Python, modulo 2^32).
 * Firmware chỉ so sánh output phần cứng với bảng này, không tự tính FIR.
 *
 * Signature (struct sig tại 0x1000_0000 = DMEM word 0):
 *   word 0  status        "FIR3" khi chạy, STATUS_PASS, hoặc STATUS_FAIL | mã lỗi
 *   word 1  halt          "HALT" do startup.S ghi sau khi main trả về
 *   word 2  exit_code     giá trị trả về của main (= mã lỗi, 0 = PASS)
 *   word 3  error         ERR_*
 *   word 4  samples_done  số mẫu đã có output lưu trong fir_output[] (32 khi PASS)
 *   word 5  first_bad     chỉ số mẫu đầu tiên có output != expected, NO_INDEX nếu không có
 *   word 6  mismatches    số mẫu output != expected
 *   word 7  error_index   chỉ số mẫu bị timeout / lỗi trạng thái; mẫu làm sạch: FLUSH_INDEX | i
 *   word 8  error_status  STATUS lúc phát hiện lỗi (0 nếu không lỗi)
 *   word 9  flush_done    số mẫu 0 làm sạch đã xong (10)
 *   word 10 num_samples   FIR_STREAM_N (32)
 *   word 11 max_polls     số lần đọc STATUS nhiều nhất để chờ DONE của một mẫu
 *
 * Ràng buộc CPU: chỉ lw/sw, không so sánh unsigned, không nhân/chia, không thư viện C.
 */

#include <stdint.h>
#include "fir_stream_data.h"

#define FIR_BASE        0x40000200u
#define FIR_REG(off)    (*(volatile uint32_t *)(FIR_BASE + (off)))
#define FIR_DATA_IN     FIR_REG(0x00)
#define FIR_DATA_OUT    FIR_REG(0x04)
#define FIR_STATUS      FIR_REG(0x08)
#define FIR_CTRL        FIR_REG(0x0C)

#define ST_DONE         (1u << 0)
#define ST_BUSY         (1u << 3)
#define ST_OVERRUN      (1u << 4)
#define CTRL_CLEAR      (1u << 0)

#define FIR_TAPS        11
#define POLL_LIMIT      1000

#define STATUS_RUNNING  0x46495233u /* "FIR3" */
#define STATUS_PASS     0x600DC0DEu
#define STATUS_FAIL     0xBAD00000u /* | mã lỗi */
#define NO_INDEX        0xFFFFFFFFu
#define FLUSH_INDEX     0xF1000000u

#define ERR_NONE         0
#define ERR_TIMEOUT_IDLE 1          /* BUSY không về 0 */
#define ERR_TIMEOUT_DONE 2          /* DONE không lên sau khi ghi DATA_IN */
#define ERR_RESULT       3          /* có output != expected */
#define ERR_STATUS       4          /* DONE cùng BUSY/OVERRUN, hoặc DONE không bị xóa sau khi đọc */

typedef struct {
    uint32_t status;
    uint32_t halt;
    uint32_t exit_code;
    uint32_t error;
    uint32_t samples_done;
    uint32_t first_bad;
    uint32_t mismatches;
    uint32_t error_index;
    uint32_t error_status;
    uint32_t flush_done;
    uint32_t num_samples;
    uint32_t max_polls;
} signature_t;

/* Đầu DMEM (linker.ld: .signature) - startup.S dùng offset +4/+8 của struct này */
__attribute__((section(".signature"), used))
volatile signature_t sig;

volatile int32_t fir_input[FIR_STREAM_N] = FIR_STREAM_INPUT;            /* .data  (data.mem) */
const volatile int32_t fir_expected[FIR_STREAM_N] = FIR_STREAM_EXPECTED; /* .rodata (data.mem) */
volatile int32_t fir_output[FIR_STREAM_N];                              /* .bss   (startup xóa) */

static int fir_wait_idle(void)
{
    uint32_t st = 0;

    for (int n = 0; n < POLL_LIMIT; n++) {
        st = FIR_STATUS;
        if ((st & ST_BUSY) == 0)
            return ERR_NONE;
    }
    sig.error_status = st;
    return ERR_TIMEOUT_IDLE;
}

/* Gửi một mẫu, chờ DONE, đọc DATA_OUT đúng một lần. Không gửi khi BUSY, không đọc trước DONE. */
__attribute__((noinline)) static int fir_send(int32_t x, int32_t *y)
{
    uint32_t st;
    int n;
    int err = fir_wait_idle();

    if (err != ERR_NONE)
        return err;
    FIR_DATA_IN = (uint32_t)x;

    for (n = 1; ; n++) {
        st = FIR_STATUS;
        if (st & ST_DONE)
            break;
        if (n >= POLL_LIMIT) {
            sig.error_status = st;
            return ERR_TIMEOUT_DONE;
        }
    }
    if ((int)sig.max_polls < n)
        sig.max_polls = n;
    if (st & (ST_BUSY | ST_OVERRUN)) {
        sig.error_status = st;
        return ERR_STATUS;
    }

    *y = (int32_t)FIR_DATA_OUT;

    st = FIR_STATUS;                /* đọc DATA_OUT phải xóa DONE, IP rảnh */
    if (st & (ST_DONE | ST_BUSY | ST_OVERRUN)) {
        sig.error_status = st;
        return ERR_STATUS;
    }
    return ERR_NONE;
}

int main(void)
{
    int32_t y = 0;
    int err;
    int i;

    sig.status = STATUS_RUNNING;
    sig.error = ERR_NONE;
    sig.samples_done = 0;
    sig.first_bad = NO_INDEX;
    sig.mismatches = 0;
    sig.error_index = NO_INDEX;
    sig.error_status = 0;
    sig.flush_done = 0;
    sig.num_samples = FIR_STREAM_N;
    sig.max_polls = 0;

    err = fir_wait_idle();
    if (err == ERR_NONE) {
        FIR_CTRL = CTRL_CLEAR;      /* bỏ DONE/OVERRUN còn sót trước khi bắt đầu */
        for (i = 0; i < FIR_TAPS - 1; i++) {
            err = fir_send(0, &y);  /* 10 mẫu 0: lịch sử FIR về 0 */
            if (err != ERR_NONE) {
                sig.error_index = FLUSH_INDEX | i;
                break;
            }
            sig.flush_done = i + 1;
        }
    }

    if (err == ERR_NONE) {
        for (i = 0; i < FIR_STREAM_N; i++) {
            err = fir_send(fir_input[i], &y);
            if (err != ERR_NONE) {
                sig.error_index = i;
                break;
            }
            fir_output[i] = y;
            sig.samples_done = i + 1;
            if (y != fir_expected[i]) {
                if (sig.mismatches == 0)
                    sig.first_bad = i;
                sig.mismatches = sig.mismatches + 1;
            }
        }
        if (err == ERR_NONE && sig.mismatches != 0)
            err = ERR_RESULT;
    }

    sig.error = err;
    if (err == ERR_NONE) {
        sig.status = STATUS_PASS;
        return 0;
    }
    sig.status = STATUS_FAIL | err;
    return err;
}
