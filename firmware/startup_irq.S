/*
 * startup_irq.S - startup cho fir_timer_1000.c, dùng linker_irq.ld.
 *
 * Cơ chế ngắt của rvcore32_pipeline_soc (rtl/cpu_soc.v), KHÔNG có CSR:
 *   - nhận ngắt: mepc = PC lệnh kế tiếp (nội bộ CPU), in_irq = 1, PC = 0x10
 *     (TRAP_VECTOR cố định). Không có mstatus/mie/mcause: không dùng lệnh CSR.
 *   - in_irq = 1 chặn ngắt mới -> không có ngắt lồng nhau.
 *   - mret (0x30200073): PC = mepc, in_irq = 0.
 *   - mức irq = pending & enable của interrupt_controller: ISR phải ACK
 *     nguồn trước mret, nếu không CPU vào lại ISR ngay.
 *
 * Bố trí:
 *   0x00 _start       : la sp, __stack_top; j _reset (+ 1 nop đệm)
 *   0x10 __trap_entry : lưu 16 thanh ghi caller-saved (ra, t0-t6, a0-a7) lên
 *                       stack (64 byte, giữ sp căn 16), gọi IRQ_C_HANDLER (C, ABI
 *                       ilp32 tự giữ s0-s11), khôi phục, mret.
 *   gp/tp: firmware không dùng (không gp-relaxation), C không ghi -> không cần lưu.
 *   Stack: ISR dùng chung stack của chương trình chính (một mức ngắt).
 *
 * IRQ_C_HANDLER mặc định là irq_handler của fir_timer_isr.h.
 */
#ifndef IRQ_C_HANDLER
#define IRQ_C_HANDLER irq_handler
#endif
    .option norelax

/*-------------------------------------------------------------------------
 * Vector table + trap entry (0x00 - ...)
 *-----------------------------------------------------------------------*/
    .section .text.start, "ax"
    .globl _start
_start:
    la      sp, __stack_top         /* auipc + addi */
    j       _reset
    nop

    .org    0x10
    .globl  __trap_entry
__trap_entry:
    addi    sp, sp, -64
    sw      ra,  0(sp)
    sw      t0,  4(sp)
    sw      t1,  8(sp)
    sw      t2, 12(sp)
    sw      a0, 16(sp)
    sw      a1, 20(sp)
    sw      a2, 24(sp)
    sw      a3, 28(sp)
    sw      a4, 32(sp)
    sw      a5, 36(sp)
    sw      a6, 40(sp)
    sw      a7, 44(sp)
    sw      t3, 48(sp)
    sw      t4, 52(sp)
    sw      t5, 56(sp)
    sw      t6, 60(sp)
    jal     ra, IRQ_C_HANDLER
    lw      ra,  0(sp)
    lw      t0,  4(sp)
    lw      t1,  8(sp)
    lw      t2, 12(sp)
    lw      a0, 16(sp)
    lw      a1, 20(sp)
    lw      a2, 24(sp)
    lw      a3, 28(sp)
    lw      a4, 32(sp)
    lw      a5, 36(sp)
    lw      a6, 40(sp)
    lw      a7, 44(sp)
    lw      t3, 48(sp)
    lw      t4, 52(sp)
    lw      t5, 56(sp)
    lw      t6, 60(sp)
    addi    sp, sp, 64
    .globl  __trap_mret
__trap_mret:
    mret

/*-------------------------------------------------------------------------
 * Reset
 *-----------------------------------------------------------------------*/
    .section .text.reset, "ax"
_reset:
    la      t0, __bss_start
    la      t1, __bss_end
1:  bge     t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:
    call    main

    /* ABI signature chung cho firmware IRQ: +4 halt, +8 exit_code */
    la      t0, sig
    sw      a0, 8(t0)
    li      t1, 0x48414C54          /* "HALT" */
    sw      t1, 4(t0)
halt:
    j       halt
