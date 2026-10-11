/* SPDX-License-Identifier: GPL-3.0-only */
#include "sc88_parameter_files.h"
#include "sc88_storage.h"
#include <stdio.h>
#include <string.h>

static int fail(sc88_parameter_files *files, unsigned reason)
{
    if (!files->fault) files->fault = reason;
    return -1;
}

static uint32_t size_at(const uint8_t *p)
{
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

static int segment_path(sc88_parameter_files *files, unsigned segment, char path[256])
{
    const char *extension = strrchr(files->base, '.');
    if (!segment) { strcpy(path, files->base); return 0; }
    int length = snprintf(path, 256, "%.*s.%03u%s", (int)(extension - files->base), files->base, segment, extension);
    return length < 0 || length >= 256 ? fail(files, 1001) : 0;
}

static int read_bytes(sc88_parameter_files *files, uint8_t *data, unsigned bytes, unsigned allow_eof)
{
    unsigned total = 0;
    while (total < bytes) {
        UINT got = 0, part = bytes - total > 16384 ? 16384 : bytes - total;
        FRESULT result = f_read(&files->file, data + total, part, &got);
        files->bytes_read += got;
        if (result != FR_OK) return fail(files, result);
        if (!got && !total && allow_eof) return 0;
        if (got != part) return fail(files, 1002);
        total += got;
        sc88_storage_poll();
        if (files->fault) return -1;
    }
    return 1;
}

int sc88_parameter_files_open(sc88_parameter_files *files, const char *path, uint8_t *a, uint8_t *b)
{
    memset(files, 0, sizeof(*files));
    sc88_parameter_reader_init(&files->reader);
    size_t length = strlen(path);
    if (length < 4 || length >= sizeof(files->base) || strcmp(path + length - 4, ".scp")) return fail(files, 1001);
    memcpy(files->base, path, length + 1);
    files->buffers[0].data = a;
    files->buffers[1].data = b;
    FRESULT result = f_open(&files->file, path, FA_READ);
    if (result != FR_OK) return fail(files, result);
    files->open = files->first_header = 1;
    return 0;
}

static int fill(sc88_parameter_files *files, sc88_file_buffer *slot)
{
    slot->owner = SC88_FILE_FILLING;
    slot->bytes = slot->position = slot->header_present = slot->eof = slot->more = 0;
    if (!files->open) {
        char path[256];
        if (segment_path(files, files->segment, path)) return -1;
        FRESULT result = f_open(&files->file, path, FA_READ);
        if (result != FR_OK) return fail(files, result);
        files->open = files->first_header = 1;
    }
    if (files->first_header) {
        if (read_bytes(files, slot->header, 104, 0) < 0) return -1;
        slot->header_present = 1;
        files->first_header = 0;
    }
    /* Keep incomplete logical blocks outside the previous slot's published bytes.
       Copy that tail before the previous slot can be reused; disk reads remain
       large and sequential instead of issuing a separate read for each header. */
    unsigned available = files->carry_bytes;
    for (unsigned offset = 0; offset < available;) {
        unsigned part = available - offset > 16384 ? 16384 : available - offset;
        memcpy(slot->data + offset, files->carry + offset, part);
        offset += part;
        sc88_storage_poll();
        if (files->fault) return -1;
    }
    files->carry_bytes = 0;
    FSIZE_t remaining = f_size(&files->file) - f_tell(&files->file);
    unsigned capacity = SC88_FILE_BUFFER_BYTES - available;
    unsigned bytes = remaining < capacity ? (unsigned)remaining : capacity;
    if (read_bytes(files, slot->data + available, bytes, 0) < 0) return -1;
    available += bytes;
    unsigned checked = 0;
    while (available - slot->bytes >= 32) {
        const uint8_t *header = slot->data + slot->bytes;
        unsigned payload = size_at(header + 24);
        if (memcmp(header, "PBL1", 4) || !payload || payload > SC88_PARAMETER_BLOCK_BYTES) return fail(files, 1003);
        if (payload + 32 > available - slot->bytes) break;
        slot->bytes += payload + 32;
        if ((++checked & 63) == 0) {
            sc88_storage_poll();
            if (files->fault) return -1;
        }
    }
    files->carry = slot->data + slot->bytes;
    files->carry_bytes = available - slot->bytes;
    if (f_tell(&files->file) == f_size(&files->file)) {
        if (files->carry_bytes) return fail(files, 1002);
        FRESULT closed = f_close(&files->file);
        files->open = 0;
        if (closed != FR_OK) return fail(files, closed);
        char next[256]; FILINFO info;
        if (segment_path(files, files->segment + 1, next)) return -1;
        FRESULT exists = f_stat(next, &info);
        if (exists != FR_OK && exists != FR_NO_FILE && exists != FR_NO_PATH) return fail(files, exists);
        slot->eof = 1;
        slot->more = exists == FR_OK;
        files->input_done = !slot->more;
        if (slot->more) ++files->segment;
    }
    slot->owner = SC88_FILE_READY;
    files->producer ^= 1;
    return 1;
}

int sc88_parameter_files_fill(sc88_parameter_files *files)
{
    if (files->fault || files->filling) return fail(files, 1004);
    if (files->input_done || files->buffers[files->producer].owner != SC88_FILE_FREE) return 0;
    files->filling = 1;
    int result = fill(files, &files->buffers[files->producer]);
    files->filling = 0;
    return result;
}

int sc88_parameter_files_next(sc88_parameter_files *files, sc88_parameter_event *event)
{
    if (files->fault) return -1;
    if (files->reader.complete) return 2;
    while (1) {
        sc88_file_buffer *slot = &files->buffers[files->consumer];
        if (slot->owner == SC88_FILE_READY) {
            if (slot->header_present && sc88_parameter_reader_header(&files->reader, slot->header, 104)) return fail(files, 1005);
            slot->owner = SC88_FILE_READING;
        }
        if (slot->owner != SC88_FILE_READING) return 0;
        int status = sc88_parameter_reader_next(&files->reader, event);
        if (status < 0) return fail(files, 1005);
        if (status) return 1;
        if (slot->position < slot->bytes) {
            unsigned size = size_at(slot->data + slot->position + 24) + 32;
            if (sc88_parameter_reader_block(&files->reader, slot->data + slot->position, size)) return fail(files, 1005);
            slot->position += size;
            continue;
        }
        if (slot->eof && sc88_parameter_reader_eof(&files->reader, slot->more)) return fail(files, 1005);
        slot->owner = SC88_FILE_FREE;
        files->consumer ^= 1;
        if (files->reader.complete) return 2;
    }
}

int sc88_parameter_files_close(sc88_parameter_files *files)
{
    if (files->filling) return fail(files, 1004);
    FRESULT result = files->open ? f_close(&files->file) : FR_OK;
    files->open = 0;
    files->input_done = 1;
    files->buffers[0].owner = files->buffers[1].owner = SC88_FILE_FREE;
    if (result != FR_OK) return fail(files, result);
    return 0;
}
