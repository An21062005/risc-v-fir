/*
 * startup.S - điểm vào firmware tại địa chỉ reset 0x00000000
 *
 *   1. sp = __stack_top (cuối DMEM, căn 16 byte)
 *   2. xóa .bss bằng sw (word); .data/.rodata đã được nạp sẵn từ data.mem
 *   3. gọi main()
 *   4. ghi mã trả về + dấu HALT vào signature, rồi lặp tại chỗ
 *
 * Chỉ dùng lệnh CPU hỗ trợ: lui/addi/auipc/sw/blt/jal/jalr.
 * Vector ngắt cố định 0x10 của CPU không dùng ở đây (firmware không bật ngắt).
 */
    .section .text.start, "ax"
    .globl _start
    .option norelax                 /* không có gp-relaxation: gp không được dùng */
_start:
    la      sp, __stack_top

    la      t0, __bss_start
    la      t1, __bss_end
1:  bge     t0, t1, 2f              /* địa chỉ DMEM 0x1000_xxxx dương: so sánh có dấu đúng */
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:
    call    main

    /* Offset theo struct signature_t trong main.c: +4 halt, +8 exit_code */
    la      t0, sig
    sw      a0, 8(t0)               /* mã trả về của main */
    li      t1, 0x48414C54          /* "HALT": main đã trả về, startup chạy tiếp đúng */
    sw      t1, 4(t0)
halt:
    j       halt
