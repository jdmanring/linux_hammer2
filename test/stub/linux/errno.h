/* SPDX-License-Identifier: BSD-3-Clause
 *
 * STUB. Not the Linux kernel header; see kernel.h in this directory.
 * The values the shim names, transcribed from
 * include/uapi/asm-generic/errno-base.h at v7.3-rc5.
 */
#ifndef _H2_STUB_ERRNO_H_
#define _H2_STUB_ERRNO_H_

#define EINTR	4	/* Interrupted system call */
/*
 * ERESTARTSYS is not in the userspace errno space and has no asm-generic
 * home; include/linux/errno.h defines it at v7.3-rc5.  It is what a
 * blocking socket read returns when a signal interrupts it, which for the
 * cluster transport's read thread is kthread_stop(), and the shim maps it
 * to EINTR rather than handing 512 to a caller whose error tables carry
 * errno names.
 */
#define ERESTARTSYS	512
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
