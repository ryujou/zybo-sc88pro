// SPDX-License-Identifier: GPL-3.0-only
#include "tusb.h"
#include "host/hcd.h"
#include "portable/ehci/ehci_api.h"
#include "xparameters.h"
#include "xusbps_hw.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xtime_l.h"

static bool poll_enabled;

uint32_t tusb_time_millis_api(void)
{
    XTime now;
    XTime_GetTime(&now);
    return (uint32_t)(now / (COUNTS_PER_SECOND / 1000u));
}

bool hcd_init(uint8_t rhport, const tusb_rhport_init_t *init)
{
    if (rhport != 0 || init->role != TUSB_ROLE_HOST) return false;
    const uintptr_t base = XPAR_XUSBPS_0_BASEADDR;
    Xil_Out32(base + XUSBPS_CMD_OFFSET, 2u);
    const uint32_t started = tusb_time_millis_api();
    while (Xil_In32(base + XUSBPS_CMD_OFFSET) & 2u) {
        if (tusb_time_millis_api() - started >= 100u) return false;
    }
    // Zynq USB0 uses its external ULPI PHY; select Host immediately after reset.
    Xil_Out32(base + XUSBPS_MODE_OFFSET, 3u);
    __asm__ volatile("dsb sy" ::: "memory");
    return ehci_init(rhport, base + 0x100u, base + XUSBPS_CMD_OFFSET);
}

bool hcd_deinit(uint8_t rhport)
{
    poll_enabled = false;
    return ehci_deinit(rhport);
}

// USB is polled from the main loop and disk waits. Audio IRQs remain enabled.
void hcd_int_enable(uint8_t rhport) { (void)rhport; poll_enabled = true; }
void hcd_int_disable(uint8_t rhport) { (void)rhport; poll_enabled = false; }

void sc88_usb_poll(void)
{
    if (poll_enabled) hcd_int_handler(0, false);
    tuh_task_ext(0, false);
}

bool hcd_dcache_clean(const void *address, uint32_t bytes)
{
    Xil_DCacheFlushRange((INTPTR)address, bytes);
    __asm__ volatile("dsb sy" ::: "memory");
    return true;
}

bool hcd_dcache_invalidate(const void *address, uint32_t bytes)
{
    Xil_DCacheInvalidateRange((INTPTR)address, bytes);
    __asm__ volatile("dsb sy" ::: "memory");
    return true;
}

bool hcd_dcache_clean_invalidate(const void *address, uint32_t bytes)
{
    return hcd_dcache_clean(address, bytes);
}
