/*
 * main.c - firmware smoke test: chứng minh CPU chạy đúng code C do GCC biên dịch.
 *
 * Kết quả ghi vào struct `sig` ở đầu DMEM (0x1000_0000, word 0..17):
 *   word 0  status        0 = chưa chạy, STATUS_RUNNING, STATUS_PASS, STATUS_FAIL|id
 *   word 1  halt          "HALT" do startup.S ghi sau khi main trả về
 *   word 2  exit_code     giá trị trả về của main (0 = PASS)
 *   word 3  checks_total  số phép kiểm tra đã chạy
 *   word 4  checks_failed số phép kiểm tra sai
 *   word 5  first_failed  id (1-based) của phép sai đầu tiên, 0 nếu không có
 *   word 6..17 result[0..11]  giá trị tính được (testbench so lại độc lập)
 *
 * Ràng buộc của CPU (xem tb/tb_cpu_firmware.v, scripts/build_firmware.py):
 *   chỉ int 32-bit (lw/sw), không char/short, không so sánh unsigned (bltu/bgeu/
 *   sltu), không nhân/chia, không thư viện C. Đầu vào là biến volatile trong
 *   .data / .rodata để GCC không tính trước kết quả lúc biên dịch.
 */

#define STATUS_RUNNING 0x52554E31   /* "RUN1" */
#define STATUS_PASS    0x600DC0DE
#define STATUS_FAIL    0xBAD00000   /* | id phép sai đầu tiên */
#define NUM_RESULTS    12

typedef struct {
    int status;
    int halt;
    int exit_code;
    int checks_total;
    int checks_failed;
    int first_failed;
    int result[NUM_RESULTS];
} signature_t;

/* Đầu DMEM (linker.ld: .signature) - startup.S dùng offset +4/+8 của struct này */
__attribute__((section(".signature"), used))
volatile signature_t sig;

/* .data: khởi tạo bằng data.mem */
volatile int in_a = 1234;
volatile int in_b = 567;
volatile int in_n_sum = 100;
volatile int in_n_fib = 20;
volatile int in_arr[8] = {3, -7, 11, 25, -2, 8, 13, -21};
volatile int in_table_len = 8;

/* .rodata: hằng số phải nằm trong DMEM vì CPU không lw được từ IMEM */
static const int table[8] = {100, 200, 300, 400, 500, 600, 700, 800};
const int *volatile table_ptr = table;

/* .bss: startup.S xóa về 0 */
volatile int bss_marker;

static void check(int id, int got, int expected)
{
    sig.checks_total = sig.checks_total + 1;
    if (got != expected) {
        sig.checks_failed = sig.checks_failed + 1;
        if (sig.first_failed == 0)
            sig.first_failed = id;
    }
}

__attribute__((noinline)) static int sum_to(int n)
{
    int s = 0;
    for (int i = 1; i <= n; i++)
        s += i;
    return s;
}

__attribute__((noinline)) static int fib(int n)
{
    int a = 0, b = 1;
    for (int i = 0; i < n; i++) {
        int t = a + b;
        a = b;
        b = t;
    }
    return a;
}

/* Đệ quy: kiểm tra stack (sw/lw ra, s0 qua sp) và jal/jalr lồng nhau */
__attribute__((noinline)) static int rsum(int n)
{
    if (n <= 0)
        return 0;
    return n + rsum(n - 1);
}

__attribute__((noinline)) static int array_sum(const volatile int *p, int len)
{
    int s = 0;
    for (int i = 0; i < len; i++)
        s += p[i];
    return s;
}

__attribute__((noinline)) static int count_negative(const volatile int *p, int len)
{
    int c = 0;
    for (int i = 0; i < len; i++) {
        if (p[i] < 0)                   /* so sánh có dấu: blt / bge */
            c = c + 1;
    }
    return c;
}

int main(void)
{
    int a = in_a;
    int b = in_b;
    int r[NUM_RESULTS];

    sig.status = STATUS_RUNNING;
    sig.checks_total = 0;
    sig.checks_failed = 0;
    sig.first_failed = 0;

    r[0]  = a + b;                                  /* 1801 */
    r[1]  = a - b;                                  /* 667 */
    r[2]  = b - a;                                  /* -667 */
    r[3]  = sum_to(in_n_sum);                       /* 5050 */
    r[4]  = fib(in_n_fib);                          /* 6765 */
    r[5]  = array_sum(in_arr, 8);                   /* 30 */
    {
        const int *t = table_ptr;                   /* .rodata qua con trỏ volatile */
        int s = 0;
        for (int i = 1; i < in_table_len; i += 2)
            s += t[i];
        r[6] = s;                                   /* 200+400+600+800 = 2000 */
    }
    r[7]  = (a ^ b) | (a & 0xF0);                   /* 0x6E5 | 0xD0 = 0x6F5 = 1781 */
    r[8]  = (a << 3) >> 2;                          /* 2468 */
    r[9]  = (-a) >> 4;                              /* -78 (dịch phải số học) */
    r[10] = rsum(10);                               /* 55 */
    r[11] = count_negative(in_arr, 8) + bss_marker; /* 3 + 0 (.bss đã xóa) */

    for (int i = 0; i < NUM_RESULTS; i++)
        sig.result[i] = r[i];

    check(1,  r[0],  1801);
    check(2,  r[1],  667);
    check(3,  r[2],  -667);
    check(4,  r[3],  5050);
    check(5,  r[4],  6765);
    check(6,  r[5],  30);
    check(7,  r[6],  2000);
    check(8,  r[7],  1781);
    check(9,  r[8],  2468);
    check(10, r[9],  -78);
    check(11, r[10], 55);
    check(12, r[11], 3);

    if (sig.checks_failed == 0) {
        sig.status = STATUS_PASS;
        return 0;
    }
    sig.status = STATUS_FAIL | sig.first_failed;
    return 1;
}
