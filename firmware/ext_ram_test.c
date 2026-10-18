/*
 * ext_ram_test.c - Bước 4a: CPU đọc/ghi RAM ngoài 64 KB bằng lw/sw qua AXI.
 * Build: scripts/build_firmware.py --firmware ext_ram_test
 *
 * RAM ngoài (soc_top ENABLE_EXT_RAM=1): CPU 0x4001_0000..0x4001_FFFF -> bus 0x0001_xxxx
 *   -> axi_interconnect -> cache_top (bypass hoặc cache) -> sdram_top.
 *
 * Các pha (dừng ở pha đầu tiên có lỗi):
 *   1 ghi bảng ram_tests[] (đầu / giữa / cuối vùng, 0, âm, 0xFFFFFFFF, 0x80000000, 0x7FFFFFFF,
 *     các địa chỉ cách nhau 0x400 để lộ alias), rồi đọc lại toàn bộ
 *   2 ghi ~giá trị vào từng ô và đọc lại ngay (ghi rồi đọc liền nhau)
 *   3 quét 64 word bước 0x400 (mọi row SDRAM của cửa sổ 64 KB), dữ liệu phụ thuộc địa chỉ,
 *     ghi hết rồi đọc lại hết
 *   4 các biến canary trong DMEM không đổi (không ghi nhầm vào DMEM)
 *
 * Signature (struct sig tại 0x1000_0000 = DMEM word 0):
 *   word 0  status       "XRAM" khi chạy, STATUS_PASS, hoặc STATUS_FAIL | pha lỗi
 *   word 1  halt         "HALT" (startup.S)
 *   word 2  exit_code    (startup.S) = pha lỗi, 0 = PASS
 *   word 3  phase        pha lỗi đầu tiên (0 = không lỗi)
 *   word 4  checks       số lần so sánh
 *   word 5  fails        số lần sai
 *   word 6  fail_addr    địa chỉ CPU của lần sai đầu tiên (0 nếu không có)
 *   word 7  fail_got     giá trị đọc được
 *   word 8  fail_exp     giá trị kỳ vọng
 *   word 9  ram_writes   số lần sw vào RAM ngoài
 *   word 10 ram_reads    số lần lw từ RAM ngoài
 */

#include <stdint.h>

#define EXT_RAM_BASE    0x40010000u
#define RAM(off)        (*(volatile uint32_t *)(EXT_RAM_BASE + (off)))
#define NUM_SWEEP       64
#define SWEEP_STRIDE    0x400u

#define STATUS_RUNNING  0x5852414Du /* "XRAM" */
#define STATUS_PASS     0x600DC0DEu
#define STATUS_FAIL     0xBAD00000u
#define CANARY_A        0xC0FFEE11u
#define CANARY_B        0x13579BDFu

typedef struct {
    uint32_t status;
    uint32_t halt;
    uint32_t exit_code;
    uint32_t phase;
    uint32_t checks;
    uint32_t fails;
    uint32_t fail_addr;
    uint32_t fail_got;
    uint32_t fail_exp;
    uint32_t ram_writes;
    uint32_t ram_reads;
} signature_t;

__attribute__((section(".signature"), used))
volatile signature_t sig;

typedef struct {
    uint32_t off;
    uint32_t val;
} ram_test_t;

/* .rodata (DMEM): offset trong RAM ngoài và giá trị */
static const volatile ram_test_t ram_tests[] = {
    {0x0000, 0x12345678u},          /* đầu vùng */
    {0x0004, 0x00000000u},          /* zero */
    {0x0008, 0xFFFFFFFFu},
    {0x000C, 0x80000000u},
    {0x0010, 0x7FFFFFFFu},
    {0x0014, 0xFFFE1DC0u},          /* -123456 */
    {0x0400, 0xCAFEF00Du},          /* cách 0x0000 đúng 0x400: lộ alias cột */
    {0x0800, 0x00000457u},          /* 1111 */
    {0x1000, 0xA5A5A5A5u},
    {0x3FFC, 0x5A5A5A5Au},
    {0x7FFC, 0xDEADBEEFu},
    {0x8000, 0x0BADF00Du},          /* giữa vùng */
    {0x8004, 0xFFFFFF85u},          /* -123 */
    {0xFFF8, 0x0F0F0F0Fu},
    {0xFFFC, 0xF0F0F0F0u},          /* cuối vùng */
};
#define NUM_TESTS ((int)(sizeof(ram_tests) / sizeof(ram_tests[0])))

volatile uint32_t canary_a = CANARY_A;  /* .data */
volatile uint32_t canary_b = CANARY_B;

static void ram_write(uint32_t off, uint32_t v)
{
    RAM(off) = v;
    sig.ram_writes = sig.ram_writes + 1;
}

/* Đọc RAM và so sánh; trả 1 nếu sai */
__attribute__((noinline)) static int ram_check(uint32_t off, uint32_t exp)
{
    uint32_t got = RAM(off);

    sig.ram_reads = sig.ram_reads + 1;
    sig.checks = sig.checks + 1;
    if (got == exp)
        return 0;
    if (sig.fails == 0) {
        sig.fail_addr = EXT_RAM_BASE + off;
        sig.fail_got = got;
        sig.fail_exp = exp;
    }
    sig.fails = sig.fails + 1;
    return 1;
}

static uint32_t sweep_value(uint32_t off)
{
    return (off << 16) ^ off ^ 0x3C3C0000u;
}

int main(void)
{
    int i, bad;
    uint32_t phase = 0;

    sig.status = STATUS_RUNNING;
    sig.phase = 0;
    sig.checks = 0;
    sig.fails = 0;
    sig.fail_addr = 0;
    sig.fail_got = 0;
    sig.fail_exp = 0;
    sig.ram_writes = 0;
    sig.ram_reads = 0;

    /* Pha 1: ghi hết rồi đọc lại hết */
    for (i = 0; i < NUM_TESTS; i++)
        ram_write(ram_tests[i].off, ram_tests[i].val);
    bad = 0;
    for (i = 0; i < NUM_TESTS; i++)
        bad += ram_check(ram_tests[i].off, ram_tests[i].val);
    if (bad)
        phase = 1;

    /* Pha 2: ghi ~giá trị, đọc lại ngay */
    if (phase == 0) {
        for (i = 0; i < NUM_TESTS; i++) {
            ram_write(ram_tests[i].off, ~ram_tests[i].val);
            bad += ram_check(ram_tests[i].off, ~ram_tests[i].val);
        }
        if (bad)
            phase = 2;
    }

    /* Pha 3: quét mọi row, dữ liệu phụ thuộc địa chỉ (offset 0x...8 tránh trùng bảng) */
    if (phase == 0) {
        uint32_t off;
        for (off = 0x8; off < NUM_SWEEP * SWEEP_STRIDE; off += SWEEP_STRIDE)
            ram_write(off, sweep_value(off));
        for (off = 0x8; off < NUM_SWEEP * SWEEP_STRIDE; off += SWEEP_STRIDE)
            bad += ram_check(off, sweep_value(off));
        if (bad)
            phase = 3;
    }

    /* Pha 4: DMEM không bị ghi nhầm */
    if (phase == 0) {
        sig.checks = sig.checks + 2;
        if (canary_a != CANARY_A || canary_b != CANARY_B)
            phase = 4;
    }

    sig.phase = phase;
    if (phase == 0) {
        sig.status = STATUS_PASS;
        return 0;
    }
    sig.status = STATUS_FAIL | phase;
    return (int)phase;
}
