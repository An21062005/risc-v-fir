/* IMEM/DMEM 1 KB; vector IRQ 0x10, stack 256 byte ở cuối DMEM. */
OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    IMEM (rx)  : ORIGIN = 0x00000000, LENGTH = 1K
    DMEM (rw)  : ORIGIN = 0x10000000, LENGTH = 1K
}

STACK_SIZE = 256;

SECTIONS
{
    .text :
    {
        KEEP(*(.text.start))            /* _start @0x0, __trap_entry @0x10 */
        KEEP(*(.text.isr .text.isr.*))  /* C ISR ngay sau trap entry */
        __isr_end = .;
        *(.text .text.*)
        . = ALIGN(4);
    } > IMEM

    /* Vùng kết quả cho testbench: luôn ở đầu DMEM (word 0..). Không có trong */
    .signature (NOLOAD) :
    {
        KEEP(*(.signature))
        . = ALIGN(4);
    } > DMEM

    .rodata :
    {
        . = ALIGN(4);
        *(.rodata .rodata.* .srodata .srodata.*)
        . = ALIGN(4);
    } > DMEM

    .data :
    {
        . = ALIGN(4);
        *(.data .data.* .sdata .sdata.*)
        . = ALIGN(4);
    } > DMEM

    .bss (NOLOAD) :
    {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss .bss.* .sbss .sbss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > DMEM

    /* Stack ở cuối DMEM, đi xuống; đỉnh căn 16 byte theo ABI ilp32. */
    __stack_top = ORIGIN(DMEM) + LENGTH(DMEM);
    __stack_limit = __stack_top - STACK_SIZE;

    /DISCARD/ :
    {
        *(.comment)
        *(.eh_frame .eh_frame_hdr)
        *(.note .note.*)
    }
}

ASSERT(_start == ORIGIN(IMEM), "_start phai o dia chi reset 0x00000000")
ASSERT(ADDR(.signature) == ORIGIN(DMEM), ".signature phai o dau DMEM (word 0) cho testbench")
ASSERT(__stack_top % 16 == 0, "stack top phai can 16 byte")
ASSERT(__bss_end <= __stack_limit, "DMEM khong du cho .rodata/.data/.bss + stack 256 byte")
ASSERT(__trap_entry == 0x10, "__trap_entry phai o TRAP_VECTOR 0x10 cua CPU")
ASSERT(__trap_mret > __trap_entry && __trap_mret < __isr_end, "mret phai nam trong vung ISR")
