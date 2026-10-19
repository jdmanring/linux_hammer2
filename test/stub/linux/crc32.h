/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_CRC32_H_
#define _H2_STUB_CRC32_H_
#include <linux/kernel.h>
/*
 * The CRC-32C update iscsi_crc32() wraps, transcribed from
 * include/linux/crc32.h:82 at v7.3.
 */
uint32_t crc32c(uint32_t crc, const void *p, size_t len);	/* u32 in the kernel */
#endif
