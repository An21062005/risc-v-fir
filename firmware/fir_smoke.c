/*
 * fir_smoke.c - Bước 2: firmware C điều khiển FIR11 HLS thật qua AXI (một mẫu).
 *
 * Luồng: CPU (lw/sw 0x4000_02xx) -> cpu_axi_master -> axi_interconnect ->
 *        fir11_wrapper -> fir (Vitis HLS). Build: scripts/build_firmware.py --firmware fir_smoke
 *
 * Thanh ghi FIR (rtl/Peripherals/fir11_wrapper.v, FIR_BASE bus 0x200, CPU thấy 0x4000_0200):
 *   0x00 DATA_IN  W  nhận mẫu và chạy một lần tính; đang BUSY thì bỏ mẫu + bật OVERRUN
 *   0x04 DATA_OUT R  y đã chốt; đọc thì xóa DONE -> chỉ đọc sau khi thấy DONE
 *   0x08 STATUS   R  bit0 DONE, bit1 ap_idle, bit2 ap_ready, bit3 BUSY, bit4 OVERRUN
 *   0x0C CTRL     W  bit0 xóa DONE/OVERRUN, bit1 reset mềm IP
 *
 * Lịch sử FIR: shift_reg của IP chỉ được khởi tạo bằng $readmemh (11 số 0); rst_n và
 * reset mềm KHÔNG xóa nó. Vì vậy firmware đẩy FIR_TAPS-1 = 10 mẫu 0 trước mẫu 7:
 * khi đó y = c[0] * 7 = 54 * 7 = 378 bất kể lịch sử trước đó.
 *
 * Signature (struct sig tại 0x1000_0000 = DMEM word 0, testbench đọc lại):
 *   word 0  status        "FIR1" khi chạy, STATUS_PASS, hoặc STATUS_FAIL | mã lỗi
 *   word 1  halt          "HALT" do startup.S ghi sau khi main trả về
 *   word 2  exit_code     giá trị trả về của main (= mã lỗi, 0 = PASS)
 *   word 3  error         ERR_*
 *   word 4  result        DATA_OUT đọc từ phần cứng cho mẫu 7
 *   word 5  expected      378
 *   word 6  sample        7
 *   word 7  status_done   STATUS lúc thấy DONE (mẫu cuối đã gửi)
 *   word 8  status_after  STATUS sau khi đọc DATA_OUT (mẫu cuối đã gửi)
 *   word 9  done_polls    số lần đọc STATUS để chờ DONE (mẫu cuối đã gửi)
 *   word 10 samples_sent  số lần ghi DATA_IN (11 khi PASS)
 *   word 11 error_status  STATUS tại thời điểm phát hiện lỗi (0 nếu không lỗi)
 *
 * Ràng buộc CPU như main.c: chỉ lw/sw, không so sánh unsigned (bltu/bgeu/sltu),
 * không nhân/chia, không thư viện C. scripts/build_firmware.py kiểm tra lại từng lệnh.
 */

#include <stdint.h>

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
#define TEST_SAMPLE     7u
#define EXPECTED_Y      378u        /* c[0] * 7 với 10 mẫu trước bằng 0 */
#define POLL_LIMIT      1000        /* IP xong sau ~17 chu kỳ; mỗi lần đọc STATUS ~10 chu kỳ */

#define STATUS_RUNNING  0x46495231u /* "FIR1" */
#define STATUS_PASS     0x600DC0DEu
#define STATUS_FAIL     0xBAD00000u /* | mã lỗi */

#define ERR_NONE         0
#define ERR_TIMEOUT_IDLE 1          /* BUSY không về 0 */
#define ERR_TIMEOUT_DONE 2          /* DONE không lên sau khi ghi DATA_IN */
#define ERR_RESULT       3          /* DATA_OUT khác 378 */
#define ERR_STATUS       4          /* DONE cùng BUSY/OVERRUN, hoặc DONE không bị xóa sau khi đọc */

typedef struct {
    uint32_t status;
    uint32_t halt;
    uint32_t exit_code;
    uint32_t error;
    uint32_t result;
    uint32_t expected;
    uint32_t sample;
    uint32_t status_done;
    uint32_t status_after;
    uint32_t done_polls;
    uint32_t samples_sent;
    uint32_t error_status;
} signature_t;

/* Đầu DMEM (linker.ld: .signature) - startup.S dùng offset +4/+8 của struct này */
__attribute__((section(".signature"), used))
volatile signature_t sig;

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

/* Gửi một mẫu, chờ DONE, đọc y. Không gửi khi BUSY, không đọc DATA_OUT trước DONE. */
__attribute__((noinline)) static int fir_send(uint32_t x, uint32_t *y)
{
    uint32_t st;
    int n;
    int err = fir_wait_idle();

    if (err != ERR_NONE)
        return err;
    FIR_DATA_IN = x;
    sig.samples_sent = sig.samples_sent + 1;

    for (n = 1; ; n++) {
        st = FIR_STATUS;
        if (st & ST_DONE)
            break;
        if (n >= POLL_LIMIT) {
            sig.error_status = st;
            return ERR_TIMEOUT_DONE;
        }
    }
    sig.done_polls = n;
    sig.status_done = st;
    if (st & (ST_BUSY | ST_OVERRUN)) {
        sig.error_status = st;
        return ERR_STATUS;
    }

    *y = FIR_DATA_OUT;

    st = FIR_STATUS;                /* đọc DATA_OUT phải xóa DONE, IP rảnh */
    sig.status_after = st;
    if (st & (ST_DONE | ST_BUSY | ST_OVERRUN)) {
        sig.error_status = st;
        return ERR_STATUS;
    }
    return ERR_NONE;
}

int main(void)
{
    uint32_t y = 0;
    int err;

    sig.status = STATUS_RUNNING;
    sig.error = ERR_NONE;
    sig.result = 0;
    sig.expected = EXPECTED_Y;
    sig.sample = TEST_SAMPLE;
    sig.status_done = 0;
    sig.status_after = 0;
    sig.done_polls = 0;
    sig.samples_sent = 0;
    sig.error_status = 0;

    err = fir_wait_idle();
    if (err == ERR_NONE) {
        FIR_CTRL = CTRL_CLEAR;      /* bỏ DONE/OVERRUN còn sót trước khi bắt đầu */
        for (int i = 0; i < FIR_TAPS - 1; i++) {
            err = fir_send(0, &y);  /* 10 mẫu 0: lịch sử FIR về 0 */
            if (err != ERR_NONE)
                break;
        }
    }
    if (err == ERR_NONE) {
        err = fir_send(TEST_SAMPLE, &y);
        if (err == ERR_NONE) {
            sig.result = y;
            if (y != EXPECTED_Y)
                err = ERR_RESULT;
        }
    }

    sig.error = err;
    if (err == ERR_NONE) {
        sig.status = STATUS_PASS;
        return 0;
    }
    sig.status = STATUS_FAIL | err;
    return err;
}
