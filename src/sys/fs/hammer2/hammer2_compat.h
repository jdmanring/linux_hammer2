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
#include <linux/uuid.h>	/* Linux: generate_random_uuid, for kern_uuidgen */

/* Taken from sys/sys/cdefs.h in FreeBSD. */
#define __DECONST(type, var)	((type)(uintptr_t)(const void *)(var))

/*
 * The carried core guards assertion-only locals on FreeBSD's own
 * INVARIANTS, not on this port's knob: hammer2_freemap.c declares
 * `size_t bytes` inside #ifdef INVARIANTS and then asserts on it, so with
 * only HAMMER2_INVARIANTS defined the file fails to compile in exactly
 * the configuration the assertions exist for. The knob keeps its name and
 * lights FreeBSD's spelling too.
 */
#ifdef HAMMER2_INVARIANTS
#define INVARIANTS	1
#endif

/*
 * FreeBSD's cdefs marks a local that only an assertion reads, so the
 * compiler does not warn about it when INVARIANTS is off.  The OpenBSD
 * port defines it in this same file and spells it __unused; here that
 * name belongs to the kernel, and __maybe_unused is Linux's word for the
 * same thing.  It stays unconditional for the reason OpenBSD's does:
 * "may be unused" is true in both knob positions, so one spelling is
 * correct in both and cannot drift.
 */
#define __diagused	__maybe_unused

/*
 * kern_uuidgen(9) fills DCE UUIDs.  The kernel's generator writes the
 * sixteen bytes in wire order with the version and variant bits set,
 * which is what newfs_hammer2 and DragonFly both store, so the struct
 * uuid the core carries is filled through its bytes.
 */
struct uuid;
static inline void
kern_uuidgen(struct uuid *store, int count)
{
	unsigned char *p = (unsigned char *)store;	/* a UUID is 16 bytes */

	while (count-- > 0) {
		generate_random_uuid(p);
		p += 16;
	}
}

/* DragonFly KKASSERT is FreeBSD KASSERT equivalent. */
#ifdef HAMMER2_INVARIANTS
#define KKASSERT(exp)		BUG_ON(!(exp))
/* Linux: BUG() rather than panic(), for the reason hpanic gives. */
#define KASSERTMSG(exp, msg, ...)					\
	do {								\
		if (unlikely(!(exp))) {					\
			pr_emerg("%s: " msg, __func__, ## __VA_ARGS__);	\
			BUG();						\
		}							\
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

/*
 * BSD vnode types.  hammer2_subr.c translates between HAMMER2_OBJTYPE_*
 * and these in both directions, and every BSD kernel supplies the enum;
 * Linux is the first host that does not, having S_IFMT bits in i_mode
 * instead.  Defining the names here is what keeps those two carried
 * functions readable as DragonFly's.
 *
 * The VALUES are this port's own and are deliberately not transcribed
 * from anyone: nothing on disk holds a vtype and nothing outside this
 * module sees one, so the enumeration is internal and only the names
 * have to agree.  VNON is 0 so a zeroed structure reads as "no type",
 * which is the one property the carried code relies on.
 *
 * The conversion to S_IFMT is hammer2_vtype_to_ifmt() in
 * hammer2_inode.c, beside hammer2_igetv(), which is the one place an
 * inode is constructed.  This was a DEFER naming that function as its
 * trigger until 2026-08-26.  The reverse direction is
 * hammer2_ifmt_to_vtype() beside it, for the create path.
 */
enum vtype { VNON, VREG, VDIR, VBLK, VCHR, VLNK, VSOCK, VFIFO, VBAD };

/*
 * The BSD sync waitfor argument.  All three BSD ports pass MNT_WAIT or
 * MNT_NOWAIT down from VFS_SYNC(9), and the carried sync path spells it
 * that way.  Linux's ->sync_fs(sb, int wait) is the same distinction with
 * the same two values, so these are chosen to BE that argument rather
 * than to be translated at the boundary: MNT_WAIT is what the VFS passes
 * as wait=1.  Nothing on disk and nothing outside this module sees them.
 */
#define MNT_WAIT	1	/* Linux */
#define MNT_NOWAIT	0	/* Linux */

/*
 * The ioflag bits the write side passes down, IO_SYNC to write now and
 * wait, IO_ASYNC to issue now, neither to delay.  Nothing outside this
 * module sees them.  MAXPHYS is FreeBSD's largest physical transfer,
 * which the core asserts a logical block fits.
 */
#define IO_SYNC		0x0001	/* Linux */
#define IO_ASYNC	0x0002	/* Linux */
#define MAXPHYS		(128 * 1024)	/* Linux */

#endif /* !_FS_HAMMER2_COMPAT_H_ */
