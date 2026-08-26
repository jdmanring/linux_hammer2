/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_BLKDEV_H_
#define _H2_STUB_BLKDEV_H_
#include <linux/kernel.h>
#define SZ_64K 0x10000
/* The two facts reading 2 rests on, transcribed from v7.1. */
#define BLK_MAX_BLOCK_SIZE SZ_64K
struct block_device;
struct file;

/*
 * Transcribed from v7.2 include/linux/blkdev.h, where file_bdev() and
 * sync_blockdev() are declared unconditionally and blkdev_issue_flush()
 * has a second definition under !CONFIG_BLOCK with the same signature.
 * hammer2_os.h calls all three, so without them the shim compiles here
 * only by declaring struct file inside a parameter list, which one
 * compiler warns about and another does not: the gate then passes or
 * fails on which cc the machine has.
 */
struct block_device *file_bdev(struct file *bdev_file);
int sync_blockdev(struct block_device *bdev);
int blkdev_issue_flush(struct block_device *bdev);
#endif
