/* tb/asm/irq_dir.S - directed ISR variants for tb_cpu_irq_c4 (I1/C4); built by */
    .option norelax
    .text
    .globl _start
_start:
    j       reset
    nop
    nop
    nop
    .org 0x10
trap:
    addi    x20, x20, 1
#if MODE == 0
    sw      x6, 0x1C8(x14)
#elif MODE == 1
    lw      x7, 0x1CC(x14)
    sw      x7, 0x1C8(x14)
#else
    sw      x0, 0x200(x14)
#endif
    .rept NOPS
    nop
    .endr
#if MODE == 2
    sw      x6, 0x1C8(x14)
#endif
    .globl  trap_mret
trap_mret:
    mret
reset:
    lui     x14, 0x40000
    addi    x5, x0, ENABLE
    sw      x5, 0x1C0(x14)
    addi    x6, x0, 3
    sw      x0, 0x200(x14)      /* DATA_IN: FIR done -> IRQ ~17 clk later */
loop:
    addi    x21, x21, 1
#ifdef LOOPPAD
    .rept LOOPPAD
    addi    x22, x22, 1
    .endr
#endif
    j       loop
