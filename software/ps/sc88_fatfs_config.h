/* SPDX-License-Identifier: GPL-3.0-only */
#ifndef SC88_FATFS_CONFIG_H
#define SC88_FATFS_CONFIG_H

#define FILE_SYSTEM_READ_ONLY
#define FILE_SYSTEM_NUM_LOGIC_VOL 1
#define FILE_SYSTEM_USE_LFN 1
#define FILE_SYSTEM_INTERFACE_RAM
#define FILE_SYSTEM_FS_EXFAT
#include "ffconf.h"

/* The actual USB disk has a GPT partition table. FatFs requires both
 * 64-bit LBA and exFAT support to discover its FAT32 volume. */
#undef FF_LBA64
#define FF_LBA64 1

#endif
