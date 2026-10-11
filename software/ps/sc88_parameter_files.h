/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef SC88_PARAMETER_FILES_H
#define SC88_PARAMETER_FILES_H
#include "ff.h"
#include "sc88_parameter_reader.h"
#define SC88_FILE_BUFFER_BYTES (16u * 1024u * 1024u)

enum sc88_file_owner { SC88_FILE_FREE, SC88_FILE_FILLING, SC88_FILE_READY, SC88_FILE_READING };
typedef struct {
    uint8_t *data;
    unsigned owner, bytes, position, header_present, eof, more;
    uint8_t header[104];
} sc88_file_buffer;

typedef struct {
    FIL file;
    sc88_parameter_reader reader;
    sc88_file_buffer buffers[2];
    char base[256];
    const uint8_t *carry;
    unsigned producer, consumer, segment, carry_bytes, first_header, open, input_done, fault, filling;
    uint64_t bytes_read;
} sc88_parameter_files;

/* The caller mounts FatFs and supplies two distinct 16 MiB buffers. */
int sc88_parameter_files_open(sc88_parameter_files *files, const char *path, uint8_t *a, uint8_t *b);
/* Main loop only. May read disk; audio callbacks may call next(), but never fill/open/close. */
int sc88_parameter_files_fill(sc88_parameter_files *files);
/* No filesystem calls: 1 event, 0 waiting for prefetch, 2 complete, -1 fault.
   Consume/copy the returned payload before calling next again. */
int sc88_parameter_files_next(sc88_parameter_files *files, sc88_parameter_event *event);
/* Main loop only, after fill has returned and consumers have stopped. */
int sc88_parameter_files_close(sc88_parameter_files *files);
#endif
