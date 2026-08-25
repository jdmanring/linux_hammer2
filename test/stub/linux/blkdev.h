/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_BLKDEV_H_
#define _H2_STUB_BLKDEV_H_
#include <linux/kernel.h>
#define SZ_64K 0x10000
/* The two facts reading 2 rests on, transcribed from v7.1. */
#define BLK_MAX_BLOCK_SIZE SZ_64K
struct block_device;
#endif
