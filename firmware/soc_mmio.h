/*
 * CPU-visible register map shared by the FIR application and staged tests.
 * See rtl/packages/soc_pkg.vh and the peripheral register decoders.
 * The CPU strips address bits [31:30] before issuing a bus request:
 * CPU 0x40000200 -> bus 0x00000200. Use aligned 32-bit lw/sw only.
 */
#ifndef SOC_MMIO_H
#define SOC_MMIO_H

#include <stdint.h>

#define MMIO(a)         (*(volatile uint32_t *)(a))

#define TIMER_PERIOD    MMIO(0x40000084u)
#define TIMER_CTRL      MMIO(0x40000088u)
#define TIMER_TICKS     MMIO(0x4000008Cu)

#define INT_ENABLE      MMIO(0x400001C0u)
#define INT_PENDING     MMIO(0x400001C4u)
#define INT_ACK         MMIO(0x400001C8u)
#define INT_STATUS      MMIO(0x400001CCu) /* read claims the highest priority source */
#define INT_BUSERR      MMIO(0x400001D0u)
#define INT_BUSERR_ADDR MMIO(0x400001D4u)

#define FIR_BASE        0x40000200u
#define FIR_REG(off)    MMIO(FIR_BASE + (off))
#define FIR_DATA_IN     FIR_REG(0x00)     /* write starts one sample */
#define FIR_DATA_OUT    FIR_REG(0x04)     /* read clears DONE */
#define FIR_STATUS      FIR_REG(0x08)
#define FIR_CTRL        FIR_REG(0x0C)     /* bit0 clear flags; bit1 soft reset */
#define FIR_CYC_CNT     FIR_REG(0x10)

#endif
