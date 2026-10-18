/*
 * linker.ld - bố trí bộ nhớ cho firmware smoke test trên rvcore32_pipeline_soc
 *
 * CPU là kiến trúc Harvard với hai bộ nhớ nội bộ tách biệt (rtl/CPU/cpu.v):
 *   IMEM: 256 word = 1 KB, chỉ cổng nạp lệnh (index = pc[9:2]), nạp từ program.mem.
 *         Lệnh load/store KHÔNG truy cập được IMEM.
 *   DMEM: 256 word = 1 KB, index = addr[9:2], nạp từ data.mem. RTL giải mã DMEM
 *         cho mọi địa chỉ có addr[31:30] != 2'b01 (0x4000_0000+ là bus ngoại vi).
 *
 * Quy ước firmware: DMEM đặt tại 0x1000_0000 (cửa sổ 1 KB, không trùng địa chỉ
 * lệnh, không dùng địa chỉ 0 cho dữ liệu). LENGTH = 1 KB đúng bằng dung lượng
 * vật lý nên ld báo lỗi khi tràn; không dựa vào bí danh addr[9:2] để "gói" dữ liệu.
 *
 * Mọi dữ liệu (.rodata, .data, .bss, stack, signature) đều nằm trong DMEM vì CPU
 * không đọc được hằng số từ IMEM. .rodata/.data được khởi tạo bằng data.mem
 * ($readmemh lúc mô phỏng bắt đầu), không có vòng copy từ IMEM.
 */
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
        KEEP(*(.text.start))            /* _start phải ở địa chỉ reset 0x0 */
        *(.text .text.*)
        . = ALIGN(4);
    } > IMEM

    /* Vùng kết quả cho testbench: luôn ở đầu DMEM (word 0..). Không có trong
       data.mem (NOLOAD) -> giá trị đầu là 0, firmware tự ghi. */
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
