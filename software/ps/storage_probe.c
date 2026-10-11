// SPDX-License-Identifier: GPL-3.0-only
#include "sc88_storage.h"
#include "ff.h"
#include "diskio.h"
#include "xparameters.h"
#include "xuartps_hw.h"
#include "xil_cache.h"
#include "xil_printf.h"
#include <stdbool.h>
#include <string.h>

volatile uint32_t sc88_storage_command[8] __attribute__((aligned(32)));
volatile struct {
    uint32_t magic, state, result, device, sector_size, sectors, faults, reads;
    uint32_t read_bytes_low, read_bytes_high, max_read_us, benchmark_us;
} sc88_storage_probe __attribute__((aligned(32)));
static FATFS filesystem;
static uint8_t buffer[16384] __attribute__((aligned(32)));

static void publish(void)
{
    sc88_storage_probe.device = sc88_storage_stats.device;
    sc88_storage_probe.sector_size = sc88_storage_stats.sector_size;
    sc88_storage_probe.sectors = sc88_storage_stats.sectors;
    sc88_storage_probe.faults = sc88_storage_stats.faults;
    sc88_storage_probe.reads = sc88_storage_stats.reads;
    sc88_storage_probe.read_bytes_low = (uint32_t)sc88_storage_stats.read_bytes;
    sc88_storage_probe.read_bytes_high = (uint32_t)(sc88_storage_stats.read_bytes >> 32);
    sc88_storage_probe.max_read_us = sc88_storage_stats.max_read_us;
    Xil_DCacheFlushRange((INTPTR)&sc88_storage_probe, sizeof(sc88_storage_probe));
}

static int benchmark(void)
{
    if (disk_status(0) & STA_NOINIT) return -1;
    const uint32_t size = sc88_storage_stats.sector_size;
    uint32_t total = (32u << 20) / size;
    if (total > sc88_storage_stats.sectors) total = sc88_storage_stats.sectors;
    const uint64_t started = sc88_storage_time_us();
    for (uint32_t sector = 0; sector < total;) {
        uint32_t count = sizeof(buffer) / size;
        if (count > total - sector) count = total - sector;
        if (disk_read(0, buffer, sector, count) != RES_OK) return -2;
        sector += count;
    }
    const uint32_t elapsed = (uint32_t)(sc88_storage_time_us() - started);
    sc88_storage_probe.benchmark_us = elapsed;
    xil_printf("SC88_USB_READ bytes=%u us=%u max_transfer_us=%u\r\n",
               total * size, elapsed, sc88_storage_stats.max_read_us);
    return 0;
}

static int files(bool read_file)
{
    FRESULT result = f_mount(&filesystem, "0:", 1);
    if (result != FR_OK) return result;
    DIR directory;
    FILINFO info;
    result = f_opendir(&directory, "0:/");
    if (result != FR_OK) return result;
    char selected[sizeof(info.fname) + 3] = {0};
    while ((result = f_readdir(&directory, &info)) == FR_OK && info.fname[0]) {
        xil_printf("SC88_FILE %s size=%u dir=%u\r\n", info.fname,
                   (unsigned)info.fsize, !!(info.fattrib & AM_DIR));
        if (!(info.fattrib & AM_DIR) && !selected[0]) {
            memcpy(selected, "0:/", 3);
            memcpy(selected + 3, info.fname, strlen(info.fname) + 1);
        }
        sc88_storage_poll();
    }
    const FRESULT closed = f_closedir(&directory);
    if (result != FR_OK) return result;
    if (closed != FR_OK) return closed;
    if (!read_file) return 0;
    if (!selected[0]) return -3;
    FIL file;
    result = f_open(&file, selected, FA_READ);
    if (result != FR_OK) return result;
    uint32_t total = 0;
    UINT bytes;
    do {
        result = f_read(&file, buffer, sizeof(buffer), &bytes);
        total += bytes;
        sc88_storage_poll();
    } while (result == FR_OK && bytes);
    const FRESULT file_closed = f_close(&file);
    if (result != FR_OK) return result;
    if (file_closed != FR_OK) return file_closed;
    xil_printf("SC88_FILE_READ name=%s bytes=%u\r\n", selected, total);
    return 0;
}

int main(void)
{
    Xil_ICacheEnable();
    Xil_DCacheEnable();
    sc88_storage_probe.magic = 0x53433455;
    sc88_storage_probe.state = 1;
    memset((void *)sc88_storage_command, 0, sizeof(sc88_storage_command));
    Xil_DCacheFlushRange((INTPTR)sc88_storage_command, sizeof(sc88_storage_command));
    publish();
    xil_printf("SC88_STORAGE_READY h=host b=read32MiB l=list r=read-first-file s=status\r\n");
    uint64_t next_status = 0;
    for (;;) {
        sc88_storage_poll();
        const uint64_t now = sc88_storage_time_us();
        if (now < next_status) continue;
        next_status = now + 10000;
        Xil_DCacheInvalidateRange((INTPTR)sc88_storage_command, sizeof(sc88_storage_command));
        unsigned command = sc88_storage_command[0];
        if (command) {
            sc88_storage_command[0] = 0;
            Xil_DCacheFlushRange((INTPTR)sc88_storage_command, sizeof(sc88_storage_command));
        }
        if (XUartPs_IsReceiveData(XPAR_XUARTPS_0_BASEADDR)) {
            const char key = (char)XUartPs_ReadReg(XPAR_XUARTPS_0_BASEADDR, XUARTPS_FIFO_OFFSET);
            if (key == 'h') command = 1;
            if (key == 'b') command = 2;
            if (key == 'l') command = 3;
            if (key == 'r') command = 4;
            if (key == 's') command = 5;
        }
        int result = 0;
        if (command == 1) result = sc88_storage_init(NULL);
        else if (command == 2) result = benchmark();
        else if (command == 3 || command == 4) result = files(command == 4);
        if (command) {
            sc88_storage_probe.result = (uint32_t)result;
            sc88_storage_probe.state = result ? 0x80000000u | command : command + 1;
            xil_printf("SC88_STORAGE command=%u result=%d device=%u faults=%u\r\n",
                       command, result, sc88_storage_stats.device, sc88_storage_stats.faults);
        }
        publish();
    }
}
