/* SPDX-License-Identifier: GPL-3.0-only */
#include "sc88_parameter_files.h"
#include "sc88_parameter_service.h"
#include "sc88_player.h"
#include "sc88_storage.h"
#include "sc88_codec.h"
#include "xparameters.h"
#include "xuartps_hw.h"
#include "xil_cache.h"
#include "xil_io.h"
#include "xil_exception.h"
#include "xiicps.h"
#include "xscugic.h"
#include "sleep.h"
#include <stdio.h>
#include <string.h>

static FATFS filesystem;
static XIicPs i2c;
static XScuGic interrupt_controller;
static volatile unsigned block_interrupt, interrupt_count;
#define PL_IRQ 61u
static sc88_parameter_files files;
static sc88_parameter_blocks blocks;
static sc88_parameter_service service;
static sc88_parameter_event event;
static unsigned enabled, initialized, pending, host_enabled, wave_loaded, command, cancel;
static int playback_result;
static unsigned callback_us, callback_frame;
#ifdef SC88_PARAMETER_CAPTURE_FIRST
static unsigned capture_pending;
#endif
static char tx[512];
static unsigned tx_bytes, tx_position;

static void block_irq(void *context)
{
    (void)context;
    XScuGic_Disable(&interrupt_controller, PL_IRQ);
    block_interrupt = 1;
    ++interrupt_count;
}

static int initialize_interrupts(void)
{
    XScuGic_Config *config = XScuGic_LookupConfig(XPAR_SCUGIC_SINGLE_DEVICE_ID);
    if (!config || XScuGic_CfgInitialize(&interrupt_controller, config, config->CpuBaseAddress) != XST_SUCCESS ||
        XScuGic_Connect(&interrupt_controller, PL_IRQ, block_irq, NULL) != XST_SUCCESS) return -1;
    XScuGic_SetPriorityTriggerType(&interrupt_controller, PL_IRQ, 0xa0, 1);
    Xil_ExceptionInit();
    Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT, (Xil_ExceptionHandler)XScuGic_InterruptHandler, &interrupt_controller);
    Xil_ExceptionEnable();
    return 0;
}

uint32_t sc88_read32(unsigned offset) {return Xil_In32(SC88_CONTROL_BASE + offset);}
void sc88_write32(unsigned offset, uint32_t value) {Xil_Out32(SC88_CONTROL_BASE + offset, value);}
void sc88_flush(uintptr_t address, size_t bytes) {Xil_DCacheFlushRange((INTPTR)address, (u32)bytes);}
void sc88_invalidate(uintptr_t address, size_t bytes) {Xil_DCacheInvalidateRange((INTPTR)address, (u32)bytes);}
void sc88_barrier(void) {__asm__ volatile("dsb sy" ::: "memory");}
uint64_t sc88_time_us(void) {return sc88_storage_time_us();}
void sc88_delay_us(unsigned us) {usleep(us);}
int sc88_i2c_write(uint8_t address, const uint8_t *bytes, unsigned count)
{
    if (XIicPs_MasterSendPolled(&i2c, (u8 *)bytes, (s32)count, address) != XST_SUCCESS) return -1;
    uint64_t start = sc88_time_us();
    while (XIicPs_BusIsBusy(&i2c)) if (sc88_time_us() - start >= 100000) return -1;
    return 0;
}

static void uart_poll(void)
{
    for (unsigned i = 0; i < 8 && tx_position < tx_bytes; ++i) {
        if (XUartPs_IsTransmitFull(XPAR_XUARTPS_0_BASEADDR)) break;
        XUartPs_WriteReg(XPAR_XUARTPS_0_BASEADDR, XUARTPS_FIFO_OFFSET, (uint8_t)tx[tx_position++]);
    }
    if (XUartPs_IsReceiveData(XPAR_XUARTPS_0_BASEADDR)) {
        unsigned key = XUartPs_ReadReg(XPAR_XUARTPS_0_BASEADDR, XUARTPS_FIFO_OFFSET);
        if (key == 'x') cancel = 1;
        else if (!command && key != '\r' && key != '\n') command = key;
    }
}

static void stop_playback(int result)
{
    if (initialized) sc88_parameter_service_stop(&service);
    else {sc88_write32(4, 8); sc88_barrier();}
    enabled = 0;
    XScuGic_Disable(&interrupt_controller, PL_IRQ);
    playback_result = result;
    /* A fill in progress notices cancellation after its current bounded read. */
    if (files.filling && !files.fault) files.fault = 1006;
}

static void service_audio_work(void)
{
    uart_poll();
    if (cancel) {if (enabled || files.filling) stop_playback(-2); return;}
    if (!enabled) return;
    if (initialized) {
        int status = sc88_parameter_service_poll(&service);
        if (status) {stop_playback(status); return;}
    }
    for (unsigned budget = 0; budget < 256 && !blocks.input_complete; ++budget) {
        if (!pending) {
            int status = sc88_parameter_files_next(&files, &event);
            if (status < 0) {stop_playback(-3); return;}
            if (!status) break;
            if (status == 2) {
                if (!initialized || sc88_parameter_blocks_finish(&blocks)) {stop_playback(-4); return;}
                break;
            }
            pending = 1;
            if (!initialized) {
                sc88_parameter_blocks_init(&blocks, files.reader.total_frames,
                    (uint8_t *)SC88_PS_CONTROL_BASE, (uint8_t *)SC88_FRAME_COMMAND_BASE, (uint8_t *)SC88_PARAMETER_BASE);
                if (sc88_parameter_service_init(&service, &blocks, (uint8_t *)SC88_SEND_RESULT_BASE,
                                                (uint8_t *)SC88_RETURN_AUDIO_BASE, 8, 9)) {stop_playback(-5); return;}
                initialized = 1;
                block_interrupt = 0;
                sc88_write32(0x014, 31); sc88_barrier();
                XScuGic_Enable(&interrupt_controller, PL_IRQ);
            }
        }
        int status = sc88_parameter_blocks_event(&blocks, &event);
        if (status < 0) {stop_playback(-6); return;}
        if (!status) break;
        pending = 0;
        /* Publish a complete block before decoding records from the next one. */
        if (blocks.input[blocks.submit_slot].owner == SC88_INPUT_READY) break;
    }
    if (initialized && blocks.input[blocks.submit_slot].owner == SC88_INPUT_READY) {
        int status = sc88_parameter_service_poll(&service);
        if (status) stop_playback(status);
    }
    if (enabled && block_interrupt) {
        block_interrupt = 0;
        XScuGic_Enable(&interrupt_controller, PL_IRQ);
    }
}

static void service_audio(void)
{
    if (!enabled) {service_audio_work(); return;}
    uint64_t start = sc88_time_us();
    service_audio_work();
    unsigned elapsed = (unsigned)(sc88_time_us() - start);
    if (elapsed > callback_us) {callback_us = elapsed; callback_frame = (unsigned)blocks.prepare.frame;}
}

static int reset_pl(void)
{
    sc88_write32(4, 4); sc88_barrier();
    sc88_delay_us(10);
    uint64_t start = sc88_time_us();
    while (sc88_read32(8) != 1 || sc88_read32(0x84) != 7 || sc88_read32(0x80) || sc88_read32(0x88)) {
        if (sc88_time_us() - start >= 100000) return -1;
        uart_poll();
    }
    initialized = pending = 0;
    return 0;
}

static int load_wave(void)
{
    if (reset_pl()) return -6;
    wave_loaded = 0;
    FRESULT mounted = f_mount(&filesystem, "0:", 1);
    if (mounted != FR_OK) return (int)mounted;
    FIL wave;
    if (f_open(&wave, "0:/decoded-wave.bin", FA_READ) != FR_OK) return -2;
    int result = f_size(&wave) == SC88_PARAMETER_WAVE_BYTES ? 0 : -3;
    for (unsigned offset = 0; !result && offset < SC88_PARAMETER_WAVE_BYTES; offset += 16384) {
        UINT got = 0;
        if (f_read(&wave, (void *)(SC88_PARAMETER_WAVE_BASE + offset), 16384, &got) != FR_OK || got != 16384) result = -4;
        sc88_storage_poll();
        if (cancel) result = -2;
    }
    if (f_close(&wave) != FR_OK && !result) result = -5;
    if (result) return result;
    sc88_flush(SC88_PARAMETER_WAVE_BASE, SC88_PARAMETER_WAVE_BYTES); sc88_barrier();
    wave_loaded = 1;
    return 0;
}

static int play(unsigned song)
{
    if (!wave_loaded || !host_enabled) return -1;
    if (reset_pl()) return -2;
    memset(&blocks, 0, sizeof(blocks));
    char path[32];
    snprintf(path, sizeof(path), "0:/th06_%02u.scp", song);
    if (sc88_parameter_files_open(&files, path, (uint8_t *)SC88_FILE_A_BASE, (uint8_t *)SC88_FILE_B_BASE)) return -3;
    for (unsigned i = 0; i < 2; ++i) {
        if (sc88_parameter_files_fill(&files) < 0 || cancel) return -4;
    }
    playback_result = 0;
    callback_us = callback_frame = 0;
    enabled = 1;
#ifdef SC88_PARAMETER_CAPTURE_FIRST
    capture_pending = 1;
#endif
    return 0;
}

#ifdef SC88_PARAMETER_EFFECTS
extern volatile unsigned sc88_effect_capture_frames;

static void cached_descriptor(unsigned offset, unsigned address, unsigned bytes,
                              unsigned result_bytes, unsigned frames, unsigned first, unsigned last)
{
    const uint32_t values[7] = {address, bytes, result_bytes ? SC88_SEND_RESULT_BASE : 0,
                                result_bytes, frames, first, 0};
    for (unsigned i = 0; i < 7; ++i) sc88_write32(offset + i * 4, values[i]);
    sc88_barrier();
    sc88_write32(offset + 28, last ? 0x101 : 1);
    sc88_barrier();
}

static int play_cached(unsigned slice)
{
    enum { BOOT = 256000, SLICE = 960000, GUARD = 3200 };
    const unsigned total = (unsigned)blocks.prepare.total_frames;
    if (enabled || playback_result != 1 || total <= BOOT || sc88_effect_capture_frames != total || slice > 3) return -1;
    if (reset_pl()) return -2;
    unsigned first = slice == 3 ? BOOT : BOOT + slice * SLICE;
    unsigned end = slice == 3 ? total : first + SLICE + GUARD;
    if (slice && slice != 3) first -= GUARD;
    if (end > total) end = total;
    if (first >= end) return -1;
    const unsigned count = end - first;

    // End the command engine after one silent frame; audio DMA then reads only
    // PCM previously synthesized on this board, leaving the cached song intact.
    sc88_frame_prepare prepare;
    sc88_prepared_frame frame;
    sc88_parameter_event boundary = {0};
    boundary.kind = 5;
    sc88_frame_prepare_init(&prepare, 1);
    if (sc88_frame_prepare_begin(&prepare, &frame, (uint8_t *)SC88_PARAMETER_BASE, SC88_PARAMETER_BASE) ||
        sc88_frame_prepare_event(&prepare, &boundary) != 1) return -3;
    memcpy((void *)SC88_FRAME_COMMAND_BASE, frame.command, 64);
    sc88_flush(SC88_PARAMETER_BASE, frame.parameter_bytes);
    sc88_flush(SC88_FRAME_COMMAND_BASE, 64);
    cached_descriptor(0x100, SC88_FRAME_COMMAND_BASE, 64, frame.result_words * 8, 1, 0, 1);
    sc88_write32(4, 1);
    sc88_barrier();
    unsigned next = 0, slot = 0, started = 0;
    uint64_t deadline = sc88_time_us() + (uint64_t)count * 1000000 / 32000 + 3000000;
    while (!(sc88_read32(8) & 16)) {
        uart_poll();
        if (cancel || sc88_read32(0xc) || sc88_time_us() > deadline) {
            sc88_write32(4, 8);
            sc88_barrier();
            return -4;
        }
        unsigned owner = (sc88_read32(0x88) >> (slot * 2)) & 3;
        if (owner == 3) {
            sc88_write32(0x180 + slot * 32 + 28, 2);
            sc88_write32(0x10, 4u << slot);
            sc88_barrier();
            owner = 0;
        }
        if (!owner && next < count) {
            unsigned frames = count - next < 16 ? count - next : 16;
            unsigned address = SC88_RETURN_AUDIO_BASE + slot * SC88_RETURN_AUDIO_STRIDE;
            memcpy((void *)address, (const uint64_t *)SC88_NATIVE_CAPTURE_BASE + first + next, frames * 8);
            sc88_flush(address, frames * 8);
            cached_descriptor(0x180 + slot * 32, address, frames * 8, 0, frames, next, next + frames == count);
            next += frames;
            slot ^= 1;
        }
        if (!started && sc88_read32(0x3c) == 32) {
            sc88_write32(4, 16);
            sc88_barrier();
            started = 1;
        }
    }
    return sc88_read32(0x90) == count && !sc88_read32(0x3c) ? 0 : -5;
}
#endif

int main(void)
{
    Xil_ICacheEnable(); Xil_DCacheEnable();
    XIicPs_Config *config = XIicPs_LookupConfig(XPAR_XIICPS_0_DEVICE_ID);
    if (!config || XIicPs_CfgInitialize(&i2c, config, config->BaseAddress) != XST_SUCCESS ||
        XIicPs_SetSClk(&i2c, 100000) != XST_SUCCESS || sc88_read32(0) != 0x53435034 || reset_pl() ||
        sc88_codec_init() || initialize_interrupts())
        return 1;
#ifdef SC88_PARAMETER_EFFECTS
    tx_bytes = (unsigned)snprintf(tx, sizeof(tx), "SC88_PARAMETER_EFFECTS h=host w=load-wave 1..7=render p=play-whole a/b/c=30s-slices x=stop s=status XP/LSP\r\n");
#else
    tx_bytes = (unsigned)snprintf(tx, sizeof(tx), "SC88_PARAMETER_DIAGNOSTIC h=host w=load-wave 1..7=play x=stop s=status cells=8,9\r\n");
#endif
    for (;;) {
        if (host_enabled) sc88_storage_poll(); else uart_poll();
        if (cancel) {
            stop_playback(-2);
            command = 0;
        }
#ifdef SC88_PARAMETER_CAPTURE_FIRST
        if (!enabled && capture_pending) {
            sc88_parameter_capture_flush();
            capture_pending = 0;
        }
#endif
        if (!enabled && files.open) {
            if (sc88_parameter_files_close(&files)) playback_result = -7;
        }
        if (cancel) {
            if (reset_pl()) playback_result = -8;
            cancel = 0;
        }
        if (command && tx_position == tx_bytes) {
            unsigned key = command; command = 0;
            int result = 0;
#ifdef SC88_PARAMETER_EFFECTS
            if (key == 'p') result = play_cached(3);
            else if (key >= 'a' && key <= 'c') result = play_cached(key - 'a');
            else
#endif
            if (key == 'h') {
                if (enabled || host_enabled) result = -1;
                else {result = sc88_storage_init(service_audio); if (!result) host_enabled = 1;}
            } else if (key == 'w') {
                if (enabled || !host_enabled) result = -1; else result = load_wave();
            } else if (key >= '1' && key <= '7') {
                if (enabled) stop_playback(0);
                if (files.open && sc88_parameter_files_close(&files)) result = -7;
                if (!result) result = play(key - '0');
            } else if (key != 's') result = -9;
            tx_position = 0;
            tx_bytes = (unsigned)snprintf(tx, sizeof(tx),
                "SC88 key=%c rc=%d playing=%u result=%d frames=%u audio_frames=%u pl_fault=%08x ps_fault=%u fifo=%u max_due=%u service_us=%u gap_us=%u usb_max_us=%u irqs=%u device=%u sector=%u sectors=%u reads=%u usb_faults=%u retries=%u retry_max=%u retry_fail=%u callback_us=%u callback_frame=%u\r\n",
                (char)key, result, enabled, playback_result, (unsigned)sc88_read32(0x18), (unsigned)sc88_read32(0x90), (unsigned)sc88_read32(0xc), service.fault,
                (unsigned)sc88_read32(0x3c), (unsigned)sc88_read32(0x1c), (unsigned)service.max_service_us, (unsigned)service.max_gap_us,
                (unsigned)sc88_storage_stats.max_read_us, interrupt_count,
                (unsigned)sc88_storage_stats.device, (unsigned)sc88_storage_stats.sector_size,
                (unsigned)sc88_storage_stats.sectors, (unsigned)sc88_storage_stats.reads, (unsigned)sc88_storage_stats.faults,
                (unsigned)sc88_storage_stats.xact_retries, (unsigned)sc88_storage_stats.max_xact_retries,
                (unsigned)sc88_storage_stats.xact_exhausted, callback_us, callback_frame);
        }
        if (enabled) {
            int status = sc88_parameter_files_fill(&files);
            if (enabled && status < 0) stop_playback(-3);
        }
    }
}
