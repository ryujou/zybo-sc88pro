/* SPDX-License-Identifier: GPL-3.0-only */
#include "sc88_host_config.h"
#include <string.h>

static void emit(sc88_host_changes *out, unsigned voice, unsigned word, uint32_t value)
{
    out->words[out->count++] = (UINT64_C(1) << 60) | ((uint64_t)voice << 54) |
                              ((uint64_t)word << 48) | value;
}

void sc88_host_reset(sc88_host_config *host)
{
    memset(host, 0, sizeof(*host));
    host->read_address = 0xffff;
    host->highest_voice = 63;
}

static void write_word(sc88_host_config *host, uint16_t address, uint16_t value,
                       sc88_host_changes *out)
{
    if (address >= 0x3940 && address < 0x39f0) {
        unsigned offset = address - 0x3940;
        address = (uint16_t)(((offset >> 2) << 8) | (host->window * 4) | (offset & 2));
    } else if (address >= 0x39f8 && address < 0x3a00) {
        address = (uint16_t)(0x3a00 + ((address - 0x39f8) >> 1) * 128 + host->window * 2);
    }
    unsigned bank = address >> 8, voice = (address & 255) >> 2;
    int word = -1;
    unsigned width = 18;
    if (bank <= 4) { word = (int)bank; width = 20; }
    else if (bank >= 0x0c && bank <= 0x0e) word = (int)bank - 7;
    else if (bank >= 0x10 && bank <= 0x1e) word = (int)bank - 8;
    else if (bank >= 0x20 && bank <= 0x26) { word = (int)bank - 9; width = 20; }
    else if (bank == 0x27) { word = 30; width = 16; }
    else if (bank >= 0x28 && bank <= 0x2a) { word = (int)bank - 9; width = 24; }
    if (word >= 0) {
        if (!(address & 2)) host->wide_latch = value;
        else {
            uint32_t wide = (((uint32_t)host->wide_latch << 16) | value) & ((1u << width) - 1);
            emit(out, voice, (unsigned)word, wide);
            if (bank == 0x1a) emit(out, voice, 48, (wide & 0x2c000) == 0x08000);
        }
    } else if (address >= 0x0800 && address < 0x0c00) {
        emit(out, (address & 127) >> 1, 34 + ((address - 0x0800) >> 7), value & 0x0fff);
    } else if ((address >= 0x3000 && address < 0x3300) ||
               (address >= 0x3400 && address < 0x3880)) {
        /* DSP and Voice banks share the same high-word latch. */
        if (!(address & 2)) host->wide_latch = value;
    } else if (address >= 0x3a00 && address < 0x3c00) {
        emit(out, (address & 127) >> 1, 42 + ((address - 0x3a00) >> 7), value);
    } else if (address >= 0x3900 && address < 0x3908) {
        unsigned first = ((address - 0x3900) >> 1) * 16;
        for (unsigned bit = 0; bit < 16; ++bit) {
            unsigned v = first + bit, next = (value >> bit) & 1;
            if (host->shadow[v] && !next) {
                host->released[v] = 0;
                emit(out, v, 46, 0);
                emit(out, v, 49, 0);
            }
            if (host->shadow[v] != next) emit(out, v, 47, next);
            host->shadow[v] = (uint8_t)next;
        }
    } else if (address >= 0x3908 && address < 0x3910) {
        unsigned cs = address - 0x3908;
        host->wave_descriptors[cs] = (uint8_t)value;
        host->wave_descriptors[cs + 1] = (uint8_t)(value >> 8);
    } else if (address == 0x3914) host->highest_voice = value;
    else if (address == 0x3918) host->irq_mask = value;
    else if (address == 0x3934) host->window = value & 63;
}

void sc88_host_write(sc88_host_config *host, uint16_t address, uint8_t value,
                     sc88_host_changes *changes)
{
    changes->count = changes->irq_acknowledge = 0;
    address &= 0x3fff;
    host->read_address = 0xffff;
    if (!(address & 1)) host->high_bytes[address >> 1] = value;
    else write_word(host, address - 1,
                    (uint16_t)((host->high_bytes[address >> 1] << 8) | value), changes);
}

void sc88_host_read(sc88_host_config *host, uint16_t address,
                    sc88_host_changes *changes)
{
    changes->count = changes->irq_acknowledge = 0;
    address &= 0x3fff;
    uint16_t word = address & 0xfffe;
    if (!(address & 1) || host->read_address != word) {
        if (word >= 0x3900 && word < 0x3908) {
            for (unsigned v = 0; v < 64; ++v) {
                if (host->shadow[v] && !host->released[v]) {
                    host->released[v] = 1;
                    emit(changes, v, 46, 1);
                    emit(changes, v, 49, 1);
                }
            }
        } else if (word == 0x391a) changes->irq_acknowledge = 1;
        host->read_address = word;
    }
    if (address & 1) host->read_address = 0xffff;
}
