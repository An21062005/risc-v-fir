/*
 * timer_irq_test.c - Giai đoạn 2: CPU nhận ngắt Timer periodic, chạy ISR, ACK, mret.
 * Build: scripts/build_firmware.py --firmware timer_irq_test
 *        (startup_irq.S + linker_irq.ld; firmware FIR và startup.S cũ không đổi)
 *
 * Timer (CPU 0x4000_0080): PERIOD = 10000 clock (10 kHz @ 100 MHz), CTRL = ENABLE|PERIODIC.
 * Interrupt controller (CPU 0x4000_01C0): ENABLE bit IRQ_TIMER; ACK = (id << 1) | 1.
 * ISR (timer_isr, gọi từ __trap_entry 0x10): đọc STATUS, nếu là Timer thì tăng irq_count
 * và ACK đúng nguồn Timer, ngược lại tăng spurious_count. Không đọc RAM mẫu, không đụng FIR.
 * (TICK_COUNT tại mỗi lần vào ISR do testbench đọc trực tiếp từ Timer, không cần log ở đây.)
 * Chương trình chính KHÔNG polling cờ ngắt để giả lập ISR; nó chỉ chờ irq_count do ISR tăng.
 *
 * Các pha (dừng ở pha đầu tiên có lỗi, exit_code = số pha):
 *   1 cấu hình Timer + bật nguồn ngắt, đọc lại PERIOD/CTRL
 *   2 reg_integrity_run(): 26 thanh ghi giữ mẫu qua >= REG_TEST_IRQS lần ngắt
 *     (ngắt đến khi CPU đang chờ RAM ngoài / MMIO). Giá trị thanh ghi do testbench
 *     kiểm trực tiếp trong register file sau mỗi lần mret (IMEM 1 KB không đủ chỗ
 *     cho dump + vòng kiểm tra bằng C); firmware kiểm số ngắt đã nhận.
 *   3 che nguồn Timer (ENABLE = 0) trong MASKED_TICKS tick: không có ISR,
 *     PENDING giữ 1 (nhiều tick gộp thành 1 pending)
 *   4 mở lại: đúng 1 ISR cho cả MASKED_TICKS tick đã gộp
 *   5 chạy tiếp 2 ngắt, tắt Timer (CTRL = 0): không còn tick / ISR, không có ISR giả
 *
 * Signature (struct sig tại 0x1000_0000):
 *   0 status  "TIRQ" khi chạy, STATUS_PASS, hoặc STATUS_FAIL | pha
 *   1 halt    "HALT" (startup_irq.S)      2 exit_code (startup_irq.S)
 *   3 phase   pha lỗi đầu tiên            4 irq_reg_test irq_count sau pha 2
 *   5 mask_t0 TICK_COUNT lúc che          6 mask_t1     TICK_COUNT trước khi mở
 *   7 unmask_isrs số ISR ngay sau khi mở  8 dis_tick    TICK_COUNT lúc tắt Timer
 *   9 final_tick TICK_COUNT cuối
 */

#include <stdint.h>

#define MMIO(a)         (*(volatile uint32_t *)(a))
#define TIMER_PERIOD    MMIO(0x40000084u)
#define TIMER_CTRL      MMIO(0x40000088u)
#define TIMER_TICKS     MMIO(0x4000008Cu)
#define INT_ENABLE      MMIO(0x400001C0u)
#define INT_PENDING     MMIO(0x400001C4u)
#define INT_ACK         MMIO(0x400001C8u)
#define INT_STATUS      MMIO(0x400001CCu)

#define IRQ_TIMER       0u
#define TIMER_ID_CODE   ((IRQ_TIMER << 1) | 1u)   /* STATUS/ACK: bit0 = 1, bit[3:1] = id */
#define CTRL_ENABLE     0x1u
#define CTRL_PERIODIC   0x2u
#define PERIOD_10KHZ    10000u                     /* 100 MHz / 10 kHz */

#define REG_TEST_IRQS   4
#define MASKED_TICKS    3
#define RESUME_IRQS     2
#define DISABLED_READS  2500                       /* > 2 chu kỳ Timer */

#define STATUS_RUNNING  0x5449525Au /* "TIRQ" */
#define STATUS_PASS     0x600DC0DEu
#define STATUS_FAIL     0xBAD00000u

typedef struct {
    uint32_t status;
    uint32_t halt;
    uint32_t exit_code;
    uint32_t phase;
    uint32_t irq_reg_test;
    uint32_t mask_t0;
    uint32_t mask_t1;
    uint32_t unmask_isrs;
    uint32_t dis_tick;
    uint32_t final_tick;
} signature_t;

__attribute__((section(".signature"), used))
volatile signature_t sig;

/* Chỉ ISR ghi (startup xóa .bss trước khi bật ngắt) */
volatile int32_t  irq_count;
volatile int32_t  spurious_count;

void reg_integrity_run(int32_t target_irq_count);   /* startup_irq.S */
void timer_isr(void);

/* Gọi từ __trap_entry (0x10) sau khi đã lưu thanh ghi caller-saved. */
__attribute__((section(".text.isr"), used, noinline))
void timer_isr(void)
{
    if (INT_STATUS == TIMER_ID_CODE) {
        irq_count = irq_count + 1;
        INT_ACK = TIMER_ID_CODE;            /* xóa đúng pending của Timer */
    } else {
        spurious_count = spurious_count + 1;
    }
}

__attribute__((noinline))
static int finish(int phase)
{
    sig.phase = (uint32_t)phase;
    sig.status = STATUS_FAIL | (uint32_t)phase;
    return phase;
}

int main(void)
{
    int32_t  c0;
    uint32_t t;
    int      i;

    sig.status = STATUS_RUNNING;

    /* 1: cấu hình */
    TIMER_PERIOD = PERIOD_10KHZ;
    INT_ENABLE = 1u << IRQ_TIMER;
    TIMER_CTRL = CTRL_ENABLE | CTRL_PERIODIC;
    if (TIMER_CTRL != (CTRL_ENABLE | CTRL_PERIODIC))  /* PERIOD hợp lệ (bit2 = 0), đang chạy */
        return finish(1);

    /* 2: ngữ cảnh thanh ghi qua nhiều lần ngắt */
    reg_integrity_run(REG_TEST_IRQS);
    c0 = irq_count;
    sig.irq_reg_test = (uint32_t)c0;
    if (c0 < REG_TEST_IRQS)
        return finish(2);

    /* 3: che Timer ở interrupt controller, để MASKED_TICKS tick trôi qua */
    INT_ENABLE = 0;
    c0 = irq_count;
    t = TIMER_TICKS;
    sig.mask_t0 = t;
    while ((int32_t)(TIMER_TICKS - t) < MASKED_TICKS)
        ;
    sig.mask_t1 = TIMER_TICKS;
    if (irq_count != c0 || (INT_PENDING & (1u << IRQ_TIMER)) == 0)
        return finish(3);

    /* 4: mở lại -> đúng một ISR cho các tick đã gộp */
    INT_ENABLE = 1u << IRQ_TIMER;
    while (irq_count == c0)
        ;
    sig.unmask_isrs = (uint32_t)(irq_count - c0);
    if (sig.unmask_isrs != 1)
        return finish(4);

    /* 5: chạy tiếp, rồi tắt Timer: không còn tick / ISR, không có ISR giả */
    while (irq_count < c0 + 1 + RESUME_IRQS)
        ;
    TIMER_CTRL = 0;
    c0 = irq_count;
    t = TIMER_TICKS;
    sig.dis_tick = t;
    for (i = 0; i < DISABLED_READS; i++)
        (void)TIMER_TICKS;
    sig.final_tick = TIMER_TICKS;
    if (sig.final_tick != t || irq_count != c0 || spurious_count != 0)
        return finish(5);

    sig.status = STATUS_PASS;
    return 0;
}
