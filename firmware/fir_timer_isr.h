/*
 * fir_timer_isr.h - ISR dùng chung cho firmware Timer IRQ + FIR IRQ
 *   fir_timer.c      (Giai đoạn 3: 32 mẫu trong DMEM)
 *   fir_timer_1000.c (Giai đoạn 4: 1000 mẫu trong RAM ngoài)
 * Giai đoạn 4.1: live deadline clock through final output; shared by both stream sizes.
 *
 * Trước khi #include, file nguồn phải định nghĩa:
 *   FT_N        số mẫu (mask Timer IRQ at FT_N; clock stops after final output)
 *   FT_IN(i)    biểu thức đọc mẫu vào thứ i      (DMEM hoặc RAM ngoài)
 *   FT_OUT(i)   lvalue lưu kết quả thứ i          (DMEM hoặc RAM ngoài)
 * Header định nghĩa thanh ghi MMIO, fir_state_t fst, try_send() và irq_handler() (gọi từ
 * __trap_entry của startup_irq.S với -DIRQ_C_HANDLER=irq_handler). Hai hàm nằm trong .text.isr
 * (linker_irq.ld đặt ngay sau trap entry -> [__trap_entry, __isr_end) = mã ngữ cảnh ngắt).
 *
 * irq_handler: đọc STATUS, ghi lại đúng giá trị đó vào ACK ngay đầu ISR (xóa đúng nguồn đang
 * phục vụ, trước mọi đọc DATA_OUT / ghi DATA_IN), rồi
 *   Timer: read live ticks, mask Timer IRQ at FT_N, update backlog, try_send()
 *   FIR: store output, read still-running TICK_COUNT, then stop Timer after final output.
 *   A result is conservatively late if the deadline observation (after the completed store)
 *   reaches the next tick. No cycle CSR exists on this CPU. Keeping the existing periodic
 *   clock alive avoids a stopped-clock false negative, including during backlog drain.
 *   Timer IRQ is masked at FT_N to avoid priority starvation under overload; a masked
 *   Timer pending bit may remain at HALT. FIR IRQ remains enabled. No new timer register.
 *   Counter wrap is outside this bounded 1000-sample run (2^32 ticks).
 *   khác : spurious++
 * try_send: gửi FT_IN(sent) chỉ khi sent < min(ticks, FT_N) (đến hạn) và sent == done (FIR rảnh,
 * output trước đã thu) -> không BUSY/OVERRUN, đúng thứ tự, không bỏ/không lặp mẫu.
 */
#ifndef FIR_TIMER_ISR_H
#define FIR_TIMER_ISR_H

#include <stdint.h>

#define MMIO(a)         (*(volatile uint32_t *)(a))
#define TIMER_PERIOD    MMIO(0x40000084u)
#define TIMER_CTRL      MMIO(0x40000088u)
#define TIMER_TICKS     MMIO(0x4000008Cu)
#define INT_ENABLE      MMIO(0x400001C0u)
#define INT_ACK         MMIO(0x400001C8u)
#define INT_STATUS      MMIO(0x400001CCu)
#define FIR_DATA_IN     MMIO(0x40000200u)
#define FIR_DATA_OUT    MMIO(0x40000204u)
#define FIR_STATUS      MMIO(0x40000208u)
#define FIR_CTRL        MMIO(0x4000020Cu)

#define CODE_TIMER      1u                         /* STATUS/ACK = (id << 1) | 1, IRQ_TIMER = 0 */
#define CODE_FIR        3u                         /* IRQ_FIR = 1 */
#define EN_TIMER_FIR    3u
#define CTRL_RUN        3u                         /* Timer ENABLE | PERIODIC */
#define ST_DONE         1u
#define ST_BUSY_OVR     0x18u                      /* FIR STATUS BUSY | OVERRUN */

/* Chỉ ISR ghi; main đọc sau một hàm ngoài (reg_integrity_run) hoặc qua con trỏ volatile. */
typedef struct {
    int32_t ticks;          /* +0  TICK_COUNT ở lần ISR Timer gần nhất */
    int32_t sent;           /* +4  số mẫu đã ghi DATA_IN */
    int32_t done;           /* +8  số output đã lưu (REGTEST_COUNTER=fst+8) */
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
