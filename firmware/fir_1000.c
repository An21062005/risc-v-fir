/*
 * fir_1000.c - Bước 4: firmware C xử lý 1000 mẫu FIR, dữ liệu trong RAM ngoài qua AXI.
 * Build: scripts/build_firmware.py --firmware fir_1000  (dữ liệu: scripts/gen_fir_1000_data.py)
 *
 * Luồng mỗi mẫu: lw input[i] (RAM ngoài) -> chờ BUSY=0 -> sw DATA_IN -> poll STATUS.DONE
 *   -> lw DATA_OUT (một lần) -> sw output[i] (RAM ngoài). Mọi truy cập đi qua
 *   cpu_axi_master -> axi_interconnect -> {fir11_wrapper | cache_top -> sdram_top}.
 * RAM ngoài (soc_top ENABLE_EXT_RAM=1): input[1000] @ 0x4001_0000, output[1000] @ 0x4001_1000.
 * IMEM/DMEM chỉ chứa chương trình, stack và signature.
 *
 * Trước 1000 mẫu: CTRL=1 (xóa DONE/OVERRUN) và 10 mẫu 0 làm sạch lịch sử FIR
 * (shift_reg của IP không bị reset xóa).
 *
 * Tự kiểm tra (firmware không chứa expected, không tự tính FIR):
 *   in_sum  = tổng x đọc từ RAM        == FIR1000_IN_SUM  (dữ liệu vào đúng)
 *   out_sum / out_xor của y từ DATA_OUT == FIR1000_EXP_SUM / EXP_XOR (Python)
 *   đọc lại output[0..999] từ RAM: rb_sum / rb_xor == out_sum / out_xor (ghi RAM không mất)
 * cpu_axi_master bỏ qua BRESP/RRESP nên firmware không thấy SLVERR; testbench kiểm tra.
 *
 * Signature (struct sig tại 0x1000_0000 = DMEM word 0):
 *   word 0  status        "F1K0" khi chạy, STATUS_PASS, hoặc STATUS_FAIL | mã lỗi
 *   word 1  halt          "HALT" (startup.S)
 *   word 2  exit_code     (startup.S) = mã lỗi, 0 = PASS
 *   word 3  error         ERR_*
 *   word 4  samples_done  số mẫu đã có output ghi vào RAM (1000 khi PASS)
 *   word 5  error_index   mẫu bị timeout/lỗi trạng thái; mẫu làm sạch: FLUSH_INDEX | i; NO_INDEX
 *   word 6  error_status  STATUS lúc lỗi (0 nếu không lỗi)
 *   word 7  flush_done    số mẫu 0 làm sạch đã xong (10)
 *   word 8  num_samples   FIR1000_N
 *   word 9  max_polls     số lần đọc STATUS nhiều nhất để chờ DONE
 *   word 10 in_sum        tổng x mod 2^32
 *   word 11 out_sum       tổng y mod 2^32
 *   word 12 out_xor       XOR y
 *   word 13 rb_sum        tổng output[] đọc lại từ RAM
 *   word 14 rb_xor        XOR output[] đọc lại từ RAM
 */

#include <stdint.h>
#include "fir_1000_data.h"

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

#define STATUS_RUNNING  0x46314B30u /* "F1K0" */
#define STATUS_PASS     0x600DC0DEu
#define STATUS_FAIL     0xBAD00000u
#define NO_INDEX        0xFFFFFFFFu
#define FLUSH_INDEX     0xF1000000u

#define ERR_NONE         0
#define ERR_TIMEOUT_IDLE 1          /* BUSY không về 0 */
#define ERR_TIMEOUT_DONE 2          /* DONE không lên sau khi ghi DATA_IN */
#define ERR_RESULT       3          /* checksum output != expected */
#define ERR_STATUS       4          /* DONE cùng BUSY/OVERRUN, hoặc DONE không bị xóa sau khi đọc */
#define ERR_INPUT        5          /* checksum input đọc từ RAM sai */
#define ERR_READBACK     6          /* output đọc lại từ RAM khác giá trị đã ghi */

typedef struct {
    uint32_t status;
    uint32_t halt;
    uint32_t exit_code;
    uint32_t error;
    uint32_t samples_done;
    uint32_t error_index;
    uint32_t error_status;
    uint32_t flush_done;
    uint32_t num_samples;
    uint32_t max_polls;
    uint32_t in_sum;
    uint32_t out_sum;
    uint32_t out_xor;
    uint32_t rb_sum;
    uint32_t rb_xor;
} signature_t;

__attribute__((section(".signature"), used))
volatile signature_t sig;

#define fir_input  ((volatile int32_t *)FIR1000_IN_ADDR)
#define fir_output ((volatile int32_t *)FIR1000_OUT_ADDR)

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
    uint32_t in_sum = 0, out_sum = 0, out_xor = 0, rb_sum = 0, rb_xor = 0;

    sig.status = STATUS_RUNNING;
    sig.error = ERR_NONE;
    sig.samples_done = 0;
    sig.error_index = NO_INDEX;
    sig.error_status = 0;
    sig.flush_done = 0;
    sig.num_samples = FIR1000_N;
    sig.max_polls = 0;

    err = fir_wait_idle();
    if (err == ERR_NONE) {
        FIR_CTRL = CTRL_CLEAR;      /* bỏ DONE/OVERRUN còn sót */
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
        for (i = 0; i < FIR1000_N; i++) {
            int32_t x = fir_input[i];
            in_sum += (uint32_t)x;
            err = fir_send(x, &y);
            if (err != ERR_NONE) {
                sig.error_index = i;
                break;
            }
            fir_output[i] = y;
            out_sum += (uint32_t)y;
            out_xor ^= (uint32_t)y;
            sig.samples_done = i + 1;
        }
    }

    if (err == ERR_NONE) {
        for (i = 0; i < FIR1000_N; i++) {
            uint32_t v = (uint32_t)fir_output[i];
            rb_sum += v;
            rb_xor ^= v;
        }
    }

    sig.in_sum = in_sum;
    sig.out_sum = out_sum;
    sig.out_xor = out_xor;
    sig.rb_sum = rb_sum;
    sig.rb_xor = rb_xor;

    if (err == ERR_NONE && in_sum != FIR1000_IN_SUM)
        err = ERR_INPUT;
    if (err == ERR_NONE && (rb_sum != out_sum || rb_xor != out_xor))
        err = ERR_READBACK;
    if (err == ERR_NONE && (out_sum != FIR1000_EXP_SUM || out_xor != FIR1000_EXP_XOR))
        err = ERR_RESULT;

    sig.error = err;
    if (err == ERR_NONE) {
        sig.status = STATUS_PASS;
        return 0;
    }
    sig.status = STATUS_FAIL | err;
    return err;
}
