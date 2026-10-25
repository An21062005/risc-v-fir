/* ISR Timer/FIR: ACK nguồn ngắt, gửi mẫu đến hạn khi FIR rảnh và thu kết quả. */
#ifndef FIR_TIMER_ISR_H
#define FIR_TIMER_ISR_H

#include <stdint.h>
#include "soc_mmio.h"

#define CODE_TIMER      1u                         /* STATUS/ACK = (id << 1) | 1, IRQ_TIMER = 0 */
#define CODE_FIR        3u                         /* IRQ_FIR = 1 */
#define EN_TIMER_FIR    3u
#define CTRL_RUN        3u                         /* Timer ENABLE | PERIODIC */
#define ST_DONE         1u
#define ST_BUSY_OVR     0x18u                      /* FIR STATUS BUSY | OVERRUN */

/* Chỉ ISR ghi; main đọc qua con trỏ volatile. */
typedef struct {
    int32_t ticks;          /* +0  TICK_COUNT ở lần ISR Timer gần nhất */
    int32_t sent;           /* +4  số mẫu đã ghi DATA_IN */
    int32_t done;           /* +8  số output đã lưu */
    int32_t missed;         /* +12 conservative deadline misses observed after completed stores */
    int32_t max_backlog;    /* +16 max(mẫu đến hạn - mẫu xong) tại ISR Timer */
    int32_t coalesced;      /* +20 tick bị gộp ở interrupt controller */
    int32_t spurious;       /* +24 ISR không có nguồn hợp lệ */
} fir_state_t;

fir_state_t fst;                                                           /* .bss */

void irq_handler(void);

/* Gửi mẫu kế tiếp nếu đã đến hạn và FIR rảnh (chỉ gọi trong ISR). */
__attribute__((section(".text.isr"), noinline))
static void try_send(void)
{
    int32_t s = fst.sent;

    if (s < FT_N && s < fst.ticks && s == fst.done) {
        FIR_DATA_IN = (uint32_t)FT_IN(s);
        fst.sent = s + 1;
    }
}

/* Gọi từ __trap_entry (0x10) sau khi đã lưu thanh ghi caller-saved. */
__attribute__((section(".text.isr"), used, noinline))
void irq_handler(void)
{
    uint32_t code = INT_STATUS;
    int32_t  t, d, backlog;

    INT_ACK = code;                         /* đúng nguồn đang phục vụ (code = 0: không có xung ACK) */
    if (code == CODE_TIMER) {
        t = (int32_t)TIMER_TICKS;
        fst.coalesced += t - fst.ticks - 1;
        fst.ticks = t;
        if (t >= FT_N) {
            t = FT_N;
            INT_ENABLE = 2u;                /* stop scheduling IRQs; keep deadline clock running */
        }
        backlog = t - fst.done;
        if (backlog > fst.max_backlog)
            fst.max_backlog = backlog;
    } else if (code == CODE_FIR && fst.done < fst.sent) {
        d = fst.done;
        FT_OUT(d) = (int32_t)FIR_DATA_OUT;
        if ((int32_t)TIMER_TICKS > d + 1)
            fst.missed++;
        if (d + 1 == FT_N)
            TIMER_CTRL = 0;                 /* only stop AFTER final store and live deadline read */
        fst.done = d + 1;
    } else {
        fst.spurious++;
        return;
    }
    try_send();
}

#endif
