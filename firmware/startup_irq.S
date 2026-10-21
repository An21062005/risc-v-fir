/*
 * startup_irq.S - startup có vector ngắt cho firmware kiểm tra Timer IRQ
 *                 (timer_irq_test.c, linker_irq.ld). startup.S cũ giữ nguyên.
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
 *                       stack (64 byte, giữ sp căn 16), gọi timer_isr() (C, ABI
 *                       ilp32 tự giữ s0-s11), khôi phục, mret.
 *   gp/tp: firmware không dùng (không gp-relaxation), C không ghi -> không cần lưu.
 *   Stack: ISR dùng chung stack của chương trình chính (một mức ngắt).
 *
 * reg_integrity_run(target): kiểm tra ngữ cảnh. Nạp mẫu riêng cho 24 thanh
 *   ghi (x1, x5-x9, x11, x15-x31; gồm cả s0-s11 để kiểm ISR C giữ đúng ABI),
 *   a2 = 0x40010000 (RAM ngoài), a4 = 0x40000000 (MMIO) cố định, rồi lặp
 *   đọc/ghi RAM ngoài + đọc TICK_COUNT (CPU dừng chờ AXI phần lớn thời gian ->
 *   IRQ đến lúc đang stall) tới khi REGTEST_COUNTER >= target.
 *   Mẫu x_n = 0xFFFFF800 | (n << 5) | n. Dùng riêng: sp, a0 (target), a3 (tạm).
 *   Không ghi dump: testbench đọc thẳng register file của CPU sau MỖI lần mret
 *   quay về vòng lặp [__regtest_loop, __regtest_exit] và khi thoát vòng lặp.
 *
 * Lệnh dùng: lui/auipc/addi/lw/sw/blt/bge/jal/jalr + mret (chỉ ở __trap_mret).
 *
 * Dùng chung cho nhiều firmware IRQ; build_firmware.py truyền -D theo firmware.
 * Mặc định (không -D) = timer_irq_test, binary không đổi:
 *   IRQ_C_HANDLER       hàm C trap entry gọi            (mặc định timer_isr)
 *   REGTEST_COUNTER     biến int32 vòng lặp kiểm tra chờ >= target (mặc định irq_count)
 *   REGTEST_NO_EXT_RAM  định nghĩa: vòng lặp chỉ đọc TICK_COUNT, không đọc/ghi RAM ngoài
 */
#ifndef IRQ_C_HANDLER
#define IRQ_C_HANDLER timer_isr
#endif
#ifndef REGTEST_COUNTER
#define REGTEST_COUNTER irq_count
#endif

    .option norelax

    .macro PAT reg, n
    addi    \reg, x0, (-2048 + ((\n << 5) | \n))
    .endm

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

    /* Offset theo signature_t trong timer_irq_test.c: +4 halt, +8 exit_code */
    la      t0, sig
    sw      a0, 8(t0)
    li      t1, 0x48414C54          /* "HALT" */
    sw      t1, 4(t0)
halt:
    j       halt

/*-------------------------------------------------------------------------
 * void reg_integrity_run(int32_t target_irq_count)
 *-----------------------------------------------------------------------*/
    .section .text.regtest, "ax"
    .globl reg_integrity_run
reg_integrity_run:
    addi    sp, sp, -64
    sw      ra,  0(sp)
    sw      s0,  4(sp)
    sw      s1,  8(sp)
    sw      s2, 12(sp)
    sw      s3, 16(sp)
    sw      s4, 20(sp)
    sw      s5, 24(sp)
    sw      s6, 28(sp)
    sw      s7, 32(sp)
    sw      s8, 36(sp)
    sw      s9, 40(sp)
    sw      s10, 44(sp)
    sw      s11, 48(sp)

    PAT     x1, 1
    PAT     x5, 5
    PAT     x6, 6
    PAT     x7, 7
    PAT     x8, 8
    PAT     x9, 9
    PAT     x11, 11
    lui     x12, 0x40010            /* a2: RAM ngoài (bus 0x1_0000) */
    lui     x14, 0x40000            /* a4: MMIO base */
    PAT     x15, 15
    PAT     x16, 16
    PAT     x17, 17
    PAT     x18, 18
    PAT     x19, 19
    PAT     x20, 20
    PAT     x21, 21
    PAT     x22, 22
    PAT     x23, 23
    PAT     x24, 24
    PAT     x25, 25
    PAT     x26, 26
    PAT     x27, 27
    PAT     x28, 28
    PAT     x29, 29
    PAT     x30, 30
    PAT     x31, 31

    .globl  __regtest_loop
__regtest_loop:
1:
#ifndef REGTEST_NO_EXT_RAM
    lw      x13, 0(x12)             /* RAM ngoài: đọc (stall dài) */
    sw      x13, 4(x12)             /* RAM ngoài: ghi */
#endif
    lw      x13, 0x8C(x14)          /* Timer TICK_COUNT */
2:  auipc   x13, %pcrel_hi(REGTEST_COUNTER)
    lw      x13, %pcrel_lo(2b)(x13)
    blt     x13, x10, 1b
    .globl  __regtest_exit
__regtest_exit:
    lw      ra,  0(sp)
    lw      s0,  4(sp)
    lw      s1,  8(sp)
    lw      s2, 12(sp)
    lw      s3, 16(sp)
    lw      s4, 20(sp)
    lw      s5, 24(sp)
    lw      s6, 28(sp)
    lw      s7, 32(sp)
    lw      s8, 36(sp)
    lw      s9, 40(sp)
    lw      s10, 44(sp)
    lw      s11, 48(sp)
    addi    sp, sp, 64
    ret
