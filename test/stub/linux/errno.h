/* SPDX-License-Identifier: BSD-3-Clause
 *
 * STUB. Not the Linux kernel header; see kernel.h in this directory.
 * The values the shim names, transcribed from
 * include/uapi/asm-generic/errno-base.h at v7.3-rc5.
 */
#ifndef _H2_STUB_ERRNO_H_
#define _H2_STUB_ERRNO_H_

#define EINTR	4	/* Interrupted system call */
#define EINVAL	22	/* Invalid argument */
/*
 * EWOULDBLOCK is EAGAIN's other name in Linux, the same value, which is
 * where include/uapi/asm-generic/errno.h puts it.  fp_read() tests for it
 * the way upstream's does, and the two names cannot both be distinct.
 */
#define EAGAIN	11	/* Try again */
#define EWOULDBLOCK	EAGAIN
#define EIO	5	/* I/O error */
#define ESPIPE	29	/* Illegal seek */
#define EDOM	33	/* Math argument out of domain of func */

#endif
