// SPDX-License-Identifier: GPL-3.0-only
#include "sc88_storage.h"
#include "tusb.h"
#include "ff.h"
#include "diskio.h"
#include "xtime_l.h"
#include <string.h>

struct sc88_storage_stats sc88_storage_stats;
static void (*audio_service)(void);
static bool completed, transfer_ok, busy, initialized;
// A qTD has five 4 KiB page pointers; 16 KiB fits at every page offset.
static uint8_t transfer_buffer[16384] __attribute__((aligned(32)));

uint64_t sc88_storage_time_us(void)
{
    XTime now;
    XTime_GetTime(&now);
    return (uint64_t)now * 1000000u / COUNTS_PER_SECOND;
}

int sc88_storage_init(void (*service_audio)(void))
{
    if (initialized) return -1;
    audio_service = service_audio;
    const tusb_rhport_init_t init = { .role = TUSB_ROLE_HOST, .speed = TUSB_SPEED_HIGH };
    if (!tusb_init(0, &init)) return -2;
    initialized = true;
    return 0;
}

void sc88_storage_poll(void)
{
    if (audio_service) audio_service();
    if (initialized) sc88_usb_poll();
}

void tuh_msc_mount_cb(uint8_t device)
{
    sc88_storage_stats.device = device;
    sc88_storage_stats.sector_size = tuh_msc_get_block_size(device, 0);
    sc88_storage_stats.sectors = tuh_msc_get_block_count(device, 0);
    const uint32_t size = sc88_storage_stats.sector_size;
    if (size < 512 || size > 4096 || (size & (size - 1))) ++sc88_storage_stats.faults;
}

void tuh_msc_umount_cb(uint8_t device)
{
    if (sc88_storage_stats.device == device) {
        sc88_storage_stats.device = 0;
        if (busy) ++sc88_storage_stats.faults;
    }
}

static bool read_complete(uint8_t device, const tuh_msc_complete_data_t *data)
{
    transfer_ok = device == sc88_storage_stats.device &&
        data->csw->signature == MSC_CSW_SIGNATURE && data->csw->tag == data->cbw->tag &&
        data->csw->status == 0 && data->csw->data_residue == 0;
    completed = true;
    return true;
}

DSTATUS disk_status(BYTE drive)
{
    if (drive || !sc88_storage_stats.device) return STA_NOINIT | STA_NODISK;
    return sc88_storage_stats.faults ? STA_NOINIT : STA_PROTECT;
}

DSTATUS disk_initialize(BYTE drive) { return disk_status(drive); }

DRESULT disk_read(BYTE drive, BYTE *buffer, LBA_t sector, UINT count)
{
    if (disk_status(drive) & STA_NOINIT) return RES_NOTRDY;
    if (!count || busy || sector >= sc88_storage_stats.sectors ||
        count > sc88_storage_stats.sectors - sector) return RES_PARERR;
    const uint32_t size = sc88_storage_stats.sector_size;
    while (count) {
        const uint32_t blocks = count < sizeof(transfer_buffer)/size ? count : sizeof(transfer_buffer)/size;
        const uint64_t started = sc88_storage_time_us();
        completed = transfer_ok = false;
        busy = true;
        if (!tuh_msc_read10(sc88_storage_stats.device, 0, transfer_buffer, sector,
                           (uint16_t)blocks, read_complete, 0)) {
            busy = false;
            ++sc88_storage_stats.faults;
            return RES_ERROR;
        }
        while (!completed && sc88_storage_stats.device && !sc88_storage_stats.faults) {
            sc88_storage_poll();
            if (sc88_storage_time_us() - started >= 2000000u) {
                ++sc88_storage_stats.faults;
                break;
            }
        }
        busy = false;
        if (!completed || !transfer_ok || sc88_storage_stats.faults) {
            if (!sc88_storage_stats.faults) ++sc88_storage_stats.faults;
            // The static DMA buffer stays allocated; a late completion cannot touch caller memory.
            return RES_ERROR;
        }
        const uint32_t elapsed = (uint32_t)(sc88_storage_time_us() - started);
        if (elapsed > sc88_storage_stats.max_read_us) sc88_storage_stats.max_read_us = elapsed;
        ++sc88_storage_stats.reads;
        sc88_storage_stats.read_bytes += blocks * size;
        memcpy(buffer, transfer_buffer, blocks * size);
        buffer += blocks * size;
        sector += blocks;
        count -= blocks;
    }
    return RES_OK;
}

DRESULT disk_write(BYTE drive, const BYTE *buffer, LBA_t sector, UINT count)
{
    (void)drive; (void)buffer; (void)sector; (void)count;
    return RES_WRPRT;
}

DRESULT disk_ioctl(BYTE drive, BYTE command, void *buffer)
{
    if (disk_status(drive) & STA_NOINIT) return RES_NOTRDY;
    switch (command) {
    case CTRL_SYNC: return RES_OK;
    case GET_SECTOR_SIZE: *(WORD *)buffer = (WORD)sc88_storage_stats.sector_size; return RES_OK;
    case GET_SECTOR_COUNT: *(LBA_t *)buffer = sc88_storage_stats.sectors; return RES_OK;
    case GET_BLOCK_SIZE: *(DWORD *)buffer = 1; return RES_OK;
    default: return RES_PARERR;
    }
}
