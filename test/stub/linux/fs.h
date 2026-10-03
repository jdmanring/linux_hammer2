/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_FS_H_
#define _H2_STUB_FS_H_
#include <linux/kernel.h>

/*
 * The two declarations hammer2_os.h needs from the kernel's
 * include/linux/fs.h, transcribed from v7.3-rc5 where they read:
 *
 *     extern ssize_t kernel_read(struct file *, void *, size_t, loff_t *);
 *     extern ssize_t kernel_write(struct file *, const void *, size_t, loff_t *);
 *
 * They are the cluster transport, reached through fp_read() and
 * fp_write(), and both are EXPORT_SYMBOL at the kernel of record so a
 * module may call them.  ssize_t and loff_t are written out as long,
 * which is the same width on every target the module builds for and is
 * the same substitution the shim makes when it calls them.
 */
struct file;

long kernel_read(struct file *file, void *buf, size_t count, long *pos);
long kernel_write(struct file *file, const void *buf, size_t count,
    long *pos);

#endif
