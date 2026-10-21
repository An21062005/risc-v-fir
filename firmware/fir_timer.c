/*
 * fir_timer.c - Giai đoạn 3: Timer IRQ 10 kHz điều phối 32 mẫu FIR11 HLS, FIR IRQ báo kết quả.
 * Build: scripts/build_firmware.py --firmware fir_timer        (PERIOD = 10000, cấu hình thường)
 *        scripts/build_firmware.py --firmware fir_timer_stress (PERIOD nhỏ: cố ý quá tải)
 * Dùng chung startup_irq.S (vector 0x10, lưu 16 thanh ghi caller-saved, mret) + linker_irq.ld.
 * fir_stream.c (polling) và timer_irq_test.c giữ nguyên.
 *
 * Luồng (mọi xử lý mẫu nằm trong ISR, không polling DONE trong ISR):
 *   irq_handler đọc STATUS rồi ghi lại đúng giá trị đó vào ACK NGAY ĐẦU ISR: xóa đúng nguồn đang
 *                phục vụ, trước mọi đọc DATA_OUT / ghi DATA_IN (DONE kế tiếp tạo pending mới).
 *   Timer tick -> pending[0] -> irq_handler: đọc TICK_COUNT (phát hiện tick gộp),
 *                đủ 32 tick thì mask Timer IRQ, giữ clock đo deadline đến output cuối, try_send()
 *   try_send   -> gửi fir_input[sent] vào DATA_IN chỉ khi sent < min(tick, 32) (mẫu đã đến hạn)
 *                và sent == done (FIR rảnh, output trước đã thu) -> không BUSY/OVERRUN, đúng thứ tự
 *   FIR DONE   -> pending[1] -> irq_handler: đọc DATA_OUT đúng 1 lần (xóa DONE),
 *                lưu fir_output[done], try_send() mẫu đang chờ
 *   STATUS cho nguồn ưu tiên cao nhất (Timer > FIR); nguồn còn lại vẫn pending -> CPU vào lại
 *   ngay sau mret. Mỗi lần vào ISR xử lý đúng một nguồn, ACK đúng nguồn đó.
 *
 * Đo trong firmware (fst, DMEM): ticks (TICK_COUNT mới nhất), sent, done, missed (mẫu i có
 * kết quả sau khi tick i+2 đã đến = trễ quá một chu kỳ), max_backlog (mẫu đã đến hạn chưa xong),
 * coalesced (tick gộp: TICK_COUNT tăng > 1 giữa hai lần ISR Timer), spurious.
 * Số ISR, thời điểm, output so với mô hình tham chiếu: testbench đo độc lập (IMEM 1 KB).
 * Quá tải: mẫu vẫn gửi theo thứ tự (backlog), trễ được đếm, không bỏ tick.
 *
 * main: flush lịch sử FIR bằng 10 mẫu 0 (polling, trước khi bật ngắt), ACK pending FIR do flush,
 * bật Timer + ngắt, rồi chạy reg_integrity_run(32) (chờ fst.done >= 32 với 26 thanh ghi giữ mẫu;
 * testbench kiểm register file sau mỗi lần mret), tự kiểm tóm tắt, HALT.
 *
 * Signature (struct sig tại 0x1000_0000): 0 (dự phòng), 1 halt "HALT", 2 exit_code
 *   (0 = PASS; 3 Timer chưa tắt, 4 thiếu mẫu / ISR lạ, 5 FIR BUSY|OVERRUN, 6 trễ/tick gộp ở cấu hình thường).
 */

#include <stdint.h>
#include "fir_stream_data.h"

#ifndef FIR_TIMER_PERIOD
#define FIR_TIMER_PERIOD 10000u                    /* 100 MHz / 10 kHz */
#endif

#define FIR_FLUSH       10                         /* taps - 1 */
#define N               FIR_STREAM_N               /* 32 */


typedef struct {
    uint32_t reserved;
    uint32_t halt;
    uint32_t exit_code;
} signature_t;

__attribute__((section(".signature"), used))
volatile signature_t sig;

volatile int32_t fir_input[N] = FIR_STREAM_INPUT;                          /* .data */
extern volatile int32_t fir_output[N];

#define FT_N            N
#define FT_IN(i)        fir_input[i]
#define FT_OUT(i)       fir_output[i]
#include "fir_timer_isr.h"                                                 /* fst, try_send, irq_handler */

volatile int32_t fir_output[N];             /* .bss (sau fst: giữ bố trí DMEM của Giai đoạn 3) */

void reg_integrity_run(int32_t target);      /* startup_irq.S, chờ fst.done >= target */

int main(void)
{
    int i;

    /* 1: flush lịch sử FIR (shift_reg không bị reset xóa), ngắt chưa bật */
    FIR_CTRL = 1u;
    for (i = 0; i < FIR_FLUSH; i++) {
        FIR_DATA_IN = 0;
        while ((FIR_STATUS & ST_DONE) == 0)
            ;
        (void)FIR_DATA_OUT;
    }
    INT_ACK = CODE_FIR;                     /* các cạnh DONE lúc flush đã chốt pending FIR */

    /* 2: Timer 10 kHz + ngắt Timer/FIR; mọi mẫu do ISR xử lý */
    TIMER_PERIOD = FIR_TIMER_PERIOD;
    INT_ENABLE = EN_TIMER_FIR;
    TIMER_CTRL = CTRL_RUN;
    reg_integrity_run(N);

    /* 3: tự kiểm tóm tắt (testbench kiểm chi tiết); mã riêng từng điều kiện */
    if (TIMER_CTRL != 0)
        return 3;                           /* Timer chưa dừng sau 32 tick */
    if (fst.sent != N || fst.spurious != 0)
        return 4;                           /* thiếu mẫu / ISR không nguồn */
    if ((FIR_STATUS & ST_BUSY_OVR) != 0)
        return 5;                           /* FIR còn BUSY hoặc OVERRUN */
#ifndef FIR_TIMER_STRESS
    if (fst.missed != 0 || fst.coalesced != 0)
        return 6;                           /* trễ / tick gộp ở cấu hình thường */
#endif
    return 0;
}
