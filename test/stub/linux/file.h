/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_FILE_H_
#define _H2_STUB_FILE_H_
#include <linux/fs.h>
/*
 * The two declarations holdfp() and fdrop() need, transcribed from
 * include/linux/file.h at v7.3-rc5 (:66 and :18): the reference a
 * descriptor number resolves to, and its release.
 */
extern struct file *fget(unsigned int fd);
extern void fput(struct file *);
#endif
