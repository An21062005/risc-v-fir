/*
 * fir_timer_1000.c - Giai đoạn 4: Timer IRQ 10 kHz điều phối 1000 mẫu FIR11 HLS, dữ liệu trong
 * RAM ngoài, FIR IRQ báo kết quả. Ngữ cảnh CPU do testbench kiểm
 * (snapshot register file vào/ra ISR). Luồng hiện chạy trong mô phỏng SoC.
 * Build: scripts/build_firmware.py --firmware fir_timer_1000 (dữ liệu: scripts/gen_fir_1000_data.py)
 * SoC  : soc_top ENABLE_EXT_RAM=1 (EXT_RAM_USE_CACHE 0 hoặc 1).
 *
 * ISR: firmware/fir_timer_isr.h - try_send() và irq_handler().
 *   Timer IRQ -> ACK -> TICK_COUNT (tick gộp) -> lw input[sent] (RAM ngoài) -> sw DATA_IN
 *   FIR IRQ   -> ACK -> lw DATA_OUT (1 lần) -> sw output[done] (RAM ngoài) -> kiểm trễ
 *   Timer remains running through the last completed output store and deadline observation;
 *   its IRQ is masked at N releases to permit backlog drain without priority starvation.
 * RAM ngoài: input[1000] @ FIR1000_IN_ADDR (0x4001_0000), output[1000] @ FIR1000_OUT_ADDR
 * (0x4001_1000).
 * Lộ trình đọc và test: firmware/README.md, docs/FIR_READING_GUIDE.md.
 *
 * main: flush 10 mẫu 0 (polling, ngắt chưa bật), ACK pending FIR do flush, bật Timer + ngắt,
 * chờ fst.done == 1000 (chỉ đọc DMEM, mọi xử lý mẫu do ISR), tự kiểm tóm tắt, HALT.
 * Tự kiểm (phụ; testbench đọc thẳng RAM ngoài): đọc lại output[] so checksum FIR1000_EXP_*.
 *
 * Signature (struct sig tại 0x1000_0000): 0 (dự phòng), 1 halt "HALT", 2 exit_code
 *   (0 PASS; 3 Timer chưa tắt, 4 thiếu mẫu / ISR lạ, 5 FIR BUSY|OVERRUN, 6 trễ / tick gộp,
 *    7 checksum output đọc lại từ RAM ngoài sai)
 */

#include <stdint.h>
#include "fir_1000_data.h"

#ifndef FIR_TIMER_PERIOD
#define FIR_TIMER_PERIOD 10000u                    /* 100 MHz / 10 kHz */
#endif

#define FIR_FLUSH       10                         /* taps - 1 */

typedef struct {
    uint32_t reserved;
    uint32_t halt;
    uint32_t exit_code;
} signature_t;

__attribute__((section(".signature"), used))
volatile signature_t sig;

#define FT_N            FIR1000_N
#define FT_IN(i)        (((volatile int32_t *)FIR1000_IN_ADDR)[i])
#define FT_OUT(i)       (((volatile int32_t *)FIR1000_OUT_ADDR)[i])
#include "fir_timer_isr.h"                                                 /* fst, try_send, irq_handler */

int main(void)
{
    volatile fir_state_t *st = &fst;           /* fst chỉ do ISR ghi */
    uint32_t sum = 0, x = 0, y;
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
    while (st->done < FT_N)
        ;

    /* 3: tự kiểm tóm tắt; mã riêng từng điều kiện */
    if (TIMER_CTRL != 0)
        return 3;                           /* Timer chưa dừng sau lần lưu output cuối */
    if (st->sent != FT_N || st->spurious != 0)
        return 4;                           /* thiếu mẫu / ISR không nguồn */
    if ((FIR_STATUS & ST_BUSY_OVR) != 0)
        return 5;                           /* FIR còn BUSY hoặc OVERRUN */
    if (st->missed != 0 || st->coalesced != 0)
        return 6;                           /* trễ / tick gộp */
    for (i = 0; i < FT_N; i++) {
        y = (uint32_t)FT_OUT(i);
        sum += y;
        x ^= y;
    }
    if (sum != FIR1000_EXP_SUM || x != FIR1000_EXP_XOR)
        return 7;                           /* output trong RAM ngoài sai */
    return 0;
}
