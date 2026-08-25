/* SPDX-License-Identifier: BSD-3-Clause */
/*
 * Copyright (c) 2026 James Manring.  All rights reserved.
 *
 * The <sys/cdefs.h> the vendored BSD headers beside this file include.
 * The kernel has no such header, so this directory is on the include path
 * and supplies one, holding only the three names sys/tree.h and
 * sys/queue.h actually use.
 *
 * Nothing here may be a name the kernel uses: a macro defined here is
 * live for the rest of the translation unit, and hammer2.h is not always
 * the last include. `__unused` is the one the BSD headers wanted that
 * fails that test, being a struct field name in the uapi headers; an
 * array field so declared is an error and a scalar one vanishes with a
 * warning, changing the layout. The three names below were grepped for
 * over the 7.2 include tree: zero hits.
 */
#ifndef _HAMMER2_SYS_CDEFS_H_
#define _HAMMER2_SYS_CDEFS_H_

#include <linux/compiler.h>
#include <linux/container_of.h>
#include <linux/types.h>

#ifndef __containerof
#define __containerof(x, s, m)	container_of(x, s, m)
#endif
#ifndef __predict_false
#define __predict_false(exp)	unlikely(exp)
#endif
#ifndef __uintptr_t
#define __uintptr_t		uintptr_t
#endif
/* __inline and __typeof are compiler keywords under gnu11; nothing to do. */

#endif /* !_HAMMER2_SYS_CDEFS_H_ */
