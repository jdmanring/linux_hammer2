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
typedef long loff_t;

/*
 * Transcribed from include/linux/fs.h at the kernel of record.  fp_read()
 * tests it to decide whether the file has a position at all, which is
 * file_ppos()'s own test.
 */
#define FMODE_STREAM		((unsigned int)(1 << 21))

/*
 * The two members of struct file the shim touches, and the mode bit it
 * tests.  fp_read() takes the file's position the way ksys_read() does,
 * and ksys_read()'s test is file_ppos(): a file opened with FMODE_STREAM,
 * which a socket is, has no meaningful position and gets NULL.  The stub
 * carries the fields in the order the kernel of record declares them
 * among f_mode and f_pos so the shape is not invented.
 */
struct file {
	unsigned int		f_mode;
	loff_t			f_pos;
};

/*
 * loff_t is written as long for the same reason ssize_t is, and it is
 * what the shim's fp_read() declares a local of when it takes the file's
 * position the way ksys_read() does.
 */
long kernel_read(struct file *file, void *buf, size_t count, loff_t *pos);
long kernel_write(struct file *file, const void *buf, size_t count,
    loff_t *pos);

#endif
