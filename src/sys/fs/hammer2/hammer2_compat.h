/* SPDX-License-Identifier: BSD-3-Clause */
/*-
 * Copyright (c) 2026 James Manring <james_manring@yahoo.com>
 * Copyright (c) 2022-2023 Tomohiro Kusumi <tkusumi@netbsd.org>
 * Copyright (c) 2011-2022 The DragonFly Project.  All rights reserved.
 *
 * This code is derived from software contributed to The DragonFly Project
 * by Matthew Dillon <dillon@dragonflybsd.org>
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in
 *    the documentation and/or other materials provided with the
 *    distribution.
 * 3. Neither the name of The DragonFly Project nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific, prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
 * ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE
 * COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY OR CONSEQUENTIAL DAMAGES (INCLUDING,
 * BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED
 * AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
 * OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT
 * OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#ifndef _FS_HAMMER2_COMPAT_H_
#define _FS_HAMMER2_COMPAT_H_

#include <linux/kernel.h>
#include <linux/string.h>
#include <linux/jiffies.h>
#include <linux/processor.h>

/* Taken from sys/sys/cdefs.h in FreeBSD. */
#define __DECONST(type, var)	((type)(uintptr_t)(const void *)(var))

/* DragonFly KKASSERT is FreeBSD KASSERT equivalent. */
#ifdef HAMMER2_INVARIANTS
#define KKASSERT(exp)		BUG_ON(!(exp))
#define KASSERTMSG(exp, msg, ...)					\
	do {								\
		if (unlikely(!(exp)))					\
			panic("%s: " msg, __func__, ## __VA_ARGS__);	\
	} while (0)
#else
#define KKASSERT(exp)		do {} while (0)
#define KASSERTMSG(exp, msg, ...)	do {} while (0)
#endif

/*
 * The core reads these counters without an atomic, so they are plain int
 * and not atomic_t. The compiler builtins have the BSD semantics on a
 * plain int at the same cost.
 */
#define atomic_add_int(p, v)	((void)__atomic_fetch_add((p), (v), __ATOMIC_SEQ_CST))
#define atomic_add_long(p, v)	atomic_add_int((p), (v))
#define atomic_add_32(p, v)	atomic_add_int((p), (v))
#define atomic_add_64(p, v)	atomic_add_int((p), (v))

/* atomic_set_int is a bitwise OR in DragonFly, not a store. */
#define atomic_set_int(p, v)	((void)__atomic_fetch_or((p), (v), __ATOMIC_SEQ_CST))
#define atomic_set_32(p, v)	atomic_set_int((p), (v))
#define atomic_set_64(p, v)	atomic_set_int((p), (v))

#define atomic_clear_int(p, v)	((void)__atomic_fetch_and((p), ~(v), __ATOMIC_SEQ_CST))
#define atomic_clear_32(p, v)	atomic_clear_int((p), (v))
#define atomic_clear_64(p, v)	atomic_clear_int((p), (v))

/* fetchadd returns the old value. */
#define atomic_fetchadd_int(p, v)	__atomic_fetch_add((p), (v), __ATOMIC_SEQ_CST)
#define atomic_fetchadd_32(p, v)	atomic_fetchadd_int((p), (v))
#define atomic_fetchadd_64(p, v)	atomic_fetchadd_int((p), (v))

/* cmpset returns nonzero on success. */
#define atomic_cmpset_int(ptr, old, new) ({				\
	__typeof__(*(ptr)) __old = (old);				\
	__atomic_compare_exchange_n((ptr), &__old, (new), 0,		\
	    __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST); })
#define atomic_cmpset_32(ptr, old, new)	atomic_cmpset_int((ptr), (old), (new))
#define atomic_cmpset_64(ptr, old, new)	atomic_cmpset_int((ptr), (old), (new))

#define cpu_pause()	cpu_relax()
#define cpu_ccfence()	barrier()

/* jiffies is the same clock at the same resolution as DragonFly ticks. */
#define getticks()	((int)jiffies)
#define hz		HZ

/* Linux has no <strings.h> names in the kernel. */
#define bzero(d, l)	memset((d), 0, (l))
#define bcopy(s, d, l)	memmove((d), (s), (l))
#define bcmp(a, b, l)	memcmp((a), (b), (l))

#ifndef howmany
#define howmany(x, y)	(((x) + ((y) - 1)) / (y))
#endif
#define rounddown2(x, y)	((x) & ~((__typeof__(x))(y) - 1))

#endif /* !_FS_HAMMER2_COMPAT_H_ */
