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

#ifndef _FS_HAMMER2_OS_H_
#define _FS_HAMMER2_OS_H_

#include <linux/version.h>
#include <linux/kernel.h>
#include <linux/slab.h>
#include <linux/rwsem.h>
#include <linux/wait.h>
#include <linux/sched.h>
#include <linux/sched/signal.h>
#include <linux/string.h>
#include <linux/blkdev.h>

#include "hammer2_compat.h"

/*
 * The floor is BLK_MAX_BLOCK_SIZE, which the DIO layer needs to assert the
 * 64KB physical buffer against. Measured by reading each header at the
 * tag: BLK_MAX_BLOCK_SIZE absent in v6.14 and present in v6.15,
 * folio_mark_dirty_lock absent in v6.12 and present in v6.13, kvrealloc
 * still four arguments in v6.11 and three in v6.12.
 */
#define LINUX_BLK_MAX_BLOCK_SIZE	KERNEL_VERSION(6, 15, 0)
#if LINUX_VERSION_CODE < LINUX_BLK_MAX_BLOCK_SIZE
#error "HAMMER2 requires Linux 6.15 or newer"
#endif

#define print_backtrace()	dump_stack()

#ifdef HAMMER2_INVARIANTS
#define HFMT	"%s(%s|%d): "
#define HARGS	__func__, current->comm, task_pid_nr(current)
#else
#define HFMT	"%s: "
#define HARGS	__func__
#endif

/*
 * THE MODULE NAME IS CARRIED HERE, NOT BY pr_fmt.  Linux's native answer
 * is a `#define pr_fmt` at the top of every .c file, before the first
 * kernel header, since <linux/printk.h> supplies an empty one when it
 * finds none.  That is unavailable to this port for the files that do
 * most of the logging: they are carried byte-for-byte and adding a line
 * to them is the edit the whole tree exists to avoid.  Measured
 * 2026-08-26 with only hammer2_io.c carrying the define: five carried
 * files hold every other call site and printed to dmesg with no module
 * name at all, which is the one thing a filesystem's log lines must have.
 *
 * So the name goes in the macro, which is this port's own.  It reaches
 * every file including the carried ones, there is one copy of it, and no
 * .c file has to remember anything.
 */
#define hprintf(X, ...)	pr_info(KBUILD_MODNAME ": " HFMT X, HARGS, ## __VA_ARGS__)
/*
 * hpanic carries the name for a different reason: panic() is not a pr_*
 * macro and takes its format verbatim, so it would not read a pr_fmt even
 * where one exists.  One token of divergence from the three BSD ports.
 */
/* Linux */
#define hpanic(X, ...)	panic(KBUILD_MODNAME ": " HFMT X, HARGS, ## __VA_ARGS__)
/*
 * DEFER(the VFS layer lands, giving a super_block to mark): panic() is
 * what the three BSD ports do, and on Linux it is a machine-wide event
 * standing in for a per-mount one. A Linux filesystem fails the operation
 * and takes the mount read-only. See doc/README.porting.md.
 */

#ifdef HAMMER2_INVARIANTS
#define debug_hprintf	hprintf
#else
#define debug_hprintf(X, ...)	do {} while (0)
#endif

/* hammer2_lk is lockmgr(9) in DragonFly. Every use in the core is exclusive. */
typedef struct rw_semaphore hammer2_lk_t;

static inline void
hammer2_lk_init(hammer2_lk_t *p, const char *s __always_unused)
{
	init_rwsem(p);
}

static inline void
hammer2_lk_ex(hammer2_lk_t *p)
{
	down_write(p);
}

static inline void
hammer2_lk_unlock(hammer2_lk_t *p)
{
	up_write(p);
}

static inline void
hammer2_lk_destroy(hammer2_lk_t *p __always_unused)
{
}

#ifdef HAMMER2_INVARIANTS
#define hammer2_lk_assert_ex(p)		BUG_ON(!rwsem_is_locked(p))
#define hammer2_lk_assert_unlocked(p)	BUG_ON(rwsem_is_locked(p))
#else
#define hammer2_lk_assert_ex(p)		do {} while (0)
#define hammer2_lk_assert_unlocked(p)	do {} while (0)
#endif

/*
 * hammer2_lkc is the condition variable half of DragonFly tsleep/wakeup.
 * FreeBSD uses an int as a sleep address; Linux needs a real wait queue.
 */
typedef wait_queue_head_t hammer2_lkc_t;

static inline void
hammer2_lkc_init(hammer2_lkc_t *c, const char *s __always_unused)
{
	init_waitqueue_head(c);
}

static inline void
hammer2_lkc_destroy(hammer2_lkc_t *c __always_unused)
{
}

static inline void
hammer2_lkc_wakeup(hammer2_lkc_t *c)
{
	wake_up(c);
}

/*
 * Not wait_event(), which does not drop a caller's lock. The tsleep
 * contract is to enqueue first, then unlock, then schedule; enqueuing
 * after the unlock loses a wakeup that lands in between.
 */
static inline int
hammer2_lkc_sleep(hammer2_lkc_t *c, hammer2_lk_t *p,
    const char *s __always_unused, int timo)
{
	DEFINE_WAIT(wait);
	long remain;

	prepare_to_wait(c, &wait, TASK_INTERRUPTIBLE);
	up_write(p);
	remain = schedule_timeout(timo ? timo : MAX_SCHEDULE_TIMEOUT);
	finish_wait(c, &wait);
	down_write(p);

	if (signal_pending(current))
		return (-EINTR);
	return ((timo && remain == 0) ? -ETIMEDOUT : 0);
}

/*
 * hammer2_mtx is a shared/exclusive lock with a reference count and an
 * ownership test. rw_semaphore has the first; the wrapper keeps the rest.
 *
 * owner exists because rwsem_is_locked() says whether a lock is held and
 * never by whom, and the core asks the second question. FreeBSD gets that
 * from sx_xlocked() for free.
 */
struct rw_semaphore_wrapper {
	struct rw_semaphore lock;
	int refs;
	struct task_struct *owner;	/* exclusive holder, or NULL */
};

typedef struct rw_semaphore_wrapper hammer2_mtx_t;

static inline void
hammer2_mtx_init(hammer2_mtx_t *p, const char *s __always_unused)
{
	memset(p, 0, sizeof(*p));
	init_rwsem(&p->lock);
}

/*
 * The recursive variant, which DragonFly and FreeBSD provide and this
 * port does not.  A Linux rw_semaphore deadlocks against its own holder
 * exactly as a NetBSD krwlock does, so the mapping follows the NetBSD
 * port: there is no recursive lock, the two call sites
 * (hammer2_chain_init and hammer2_inode_get) get a plain lock, and the
 * ONE path that recursed is disabled instead.  That path is
 * hammer2_chain_lookup() reaching chain->lock again for an inode in
 * DIRECTDATA mode; NetBSD stops it by never setting
 * HAMMER2_OPFLAG_DIRECTDATA, which costs a data block for a tiny file
 * and costs no correctness.  That half of the change lands with
 * hammer2_inode.c, which is where the flag is set.
 * XXX Not a recursive lock.  A caller that genuinely recurses will
 * deadlock rather than fail, so any new recursion must be resolved at
 * its call site the same way.
 */
static inline void
hammer2_mtx_init_recurse(hammer2_mtx_t *p, const char *s)
{
	hammer2_mtx_init(p, s);
}

static inline void
hammer2_mtx_ex(hammer2_mtx_t *p)
{
	down_write(&p->lock);
	WRITE_ONCE(p->owner, current);
	p->refs++;
}

static inline void
hammer2_mtx_sh(hammer2_mtx_t *p)
{
	down_read(&p->lock);
	atomic_add_int(&p->refs, 1);
}

static inline int
hammer2_mtx_owned(hammer2_mtx_t *p)
{
	return (READ_ONCE(p->owner) == current);
}

static inline void
hammer2_mtx_unlock(hammer2_mtx_t *p)
{
	if (hammer2_mtx_owned(p)) {
		p->refs--;
		WRITE_ONCE(p->owner, NULL);
		up_write(&p->lock);
	} else {
		atomic_add_int(&p->refs, -1);
		up_read(&p->lock);
	}
}

static inline int
hammer2_mtx_refs(hammer2_mtx_t *p)
{
	return (READ_ONCE(p->refs));
}

static inline void
hammer2_mtx_destroy(hammer2_mtx_t *p __always_unused)
{
}

/* Non-zero on failure. */
static inline int
hammer2_mtx_ex_try(hammer2_mtx_t *p)
{
	if (!down_write_trylock(&p->lock))
		return (1);
	WRITE_ONCE(p->owner, current);
	p->refs++;
	return (0);
}

static inline int
hammer2_mtx_sh_try(hammer2_mtx_t *p)
{
	if (!down_read_trylock(&p->lock))
		return (1);
	atomic_add_int(&p->refs, 1);
	return (0);
}

/*
 * XXX Linux has downgrade_write() and no upgrade, so this succeeds only
 * when the caller already holds it exclusively. Every caller of a _try
 * handles failure by dropping and re-acquiring, so this is correct and
 * slow. OpenBSD unlocks and retries here for the same reason.
 */
static inline int
hammer2_mtx_upgrade_try(hammer2_mtx_t *p)
{
	return (hammer2_mtx_owned(p) ? 0 : 1);
}

/* Non-zero if the lock was held exclusively. */
static inline int
hammer2_mtx_temp_release(hammer2_mtx_t *p)
{
	int x = hammer2_mtx_owned(p);

	hammer2_mtx_unlock(p);
	return (x);
}

static inline void
hammer2_mtx_temp_restore(hammer2_mtx_t *p, int x)
{
	if (x)
		hammer2_mtx_ex(p);
	else
		hammer2_mtx_sh(p);
}

static inline int
hammer2_mtx_sleep(hammer2_lkc_t *c, hammer2_mtx_t *p,
    const char *s __always_unused, int timo)
{
	DEFINE_WAIT(wait);
	long remain;
	int x;

	prepare_to_wait(c, &wait, TASK_INTERRUPTIBLE);
	x = hammer2_mtx_temp_release(p);
	remain = schedule_timeout(timo ? timo : MAX_SCHEDULE_TIMEOUT);
	finish_wait(c, &wait);
	hammer2_mtx_temp_restore(p, x);

	if (signal_pending(current))
		return (-EINTR);
	return ((timo && remain == 0) ? -ETIMEDOUT : 0);
}

#define hammer2_mtx_wakeup(c)	hammer2_lkc_wakeup(c)

#ifdef HAMMER2_INVARIANTS
#define hammer2_mtx_assert_ex(p)	BUG_ON(!hammer2_mtx_owned(p))
#define hammer2_mtx_assert_locked(p)	BUG_ON(!rwsem_is_locked(&(p)->lock))
#define hammer2_mtx_assert_unlocked(p)	BUG_ON(rwsem_is_locked(&(p)->lock))
/* XXX rwsem_is_locked() cannot tell shared from exclusive. */
#define hammer2_mtx_assert_sh(p)	hammer2_mtx_assert_locked(p)
#else
#define hammer2_mtx_assert_ex(p)	do {} while (0)
#define hammer2_mtx_assert_sh(p)	do {} while (0)
#define hammer2_mtx_assert_locked(p)	do {} while (0)
#define hammer2_mtx_assert_unlocked(p)	do {} while (0)
#endif

/*
 * hammer2_spin is a spinlock in DragonFly and on no port. The 62
 * port-relevant acquire sites were audited: none sleeps under the lock and
 * none is reachable from an I/O completion path, since the physical
 * buffers live in the block device page cache and complete there.
 */
typedef struct rw_semaphore hammer2_spin_t;

static inline void
hammer2_spin_init(hammer2_spin_t *p, const char *s __always_unused)
{
	init_rwsem(p);
}

static inline void
hammer2_spin_ex(hammer2_spin_t *p)
{
	down_write(p);
}

static inline void
hammer2_spin_sh(hammer2_spin_t *p)
{
	down_read(p);
}

static inline void
hammer2_spin_unex(hammer2_spin_t *p)
{
	up_write(p);
}

static inline void
hammer2_spin_unsh(hammer2_spin_t *p)
{
	up_read(p);
}

static inline void
hammer2_spin_destroy(hammer2_spin_t *p __always_unused)
{
}

#ifdef HAMMER2_INVARIANTS
#define hammer2_spin_assert_locked(p)	BUG_ON(!rwsem_is_locked(p))
#define hammer2_spin_assert_unlocked(p)	BUG_ON(rwsem_is_locked(p))
#define hammer2_spin_assert_ex(p)	hammer2_spin_assert_locked(p)
#define hammer2_spin_assert_sh(p)	hammer2_spin_assert_locked(p)
#else
#define hammer2_spin_assert_locked(p)	do {} while (0)
#define hammer2_spin_assert_unlocked(p)	do {} while (0)
#define hammer2_spin_assert_ex(p)	do {} while (0)
#define hammer2_spin_assert_sh(p)	do {} while (0)
#endif

/*
 * Linux has no malloc type, so these are tokens with no identity. Kept
 * distinct so a grep for M_HAMMER2_LZ4 still finds the LZ4 allocations.
 */
#define M_HAMMER2	((void *)0)
#define M_HAMMER2_LZ4	((void *)0)
#define M_TEMP		((void *)0)

/* Only these flags are used by the core. */
#define M_WAITOK	0x0001
#define M_NOWAIT	0x0002
#define M_ZERO		0x0100

static inline gfp_t
hammer2_gfp(int flags)
{
	gfp_t gfp = (flags & M_NOWAIT) ? GFP_NOWAIT : GFP_KERNEL;

	if (flags & M_ZERO)
		gfp |= __GFP_ZERO;
	return (gfp);
}

#ifdef HAMMER2_MALLOC
extern int malloc_leak_m_hammer2;	/* hammer2_vfsops.c */
extern int malloc_leak_m_hammer2_lz4;
extern int malloc_leak_m_temp;

static inline void
adjust_malloc_leak(int delta, void *type)
{
	int *lp;

	if (type == M_HAMMER2_LZ4)
		lp = &malloc_leak_m_hammer2_lz4;
	else if (type == M_TEMP)
		lp = &malloc_leak_m_temp;
	else
		lp = &malloc_leak_m_hammer2;

	atomic_add_int(lp, delta);
}
#else
static inline void
adjust_malloc_leak(int delta __always_unused, void *type __always_unused)
{
}
#endif

/*
 * kvmalloc and not kmalloc: the core allocates 64KB scratch buffers, which
 * is order 4 and fails under fragmentation where a vmalloc fallback would
 * not. Every such buffer is accessed by pointer and never by page.
 */
static inline void *
hmalloc(size_t size, void *type, int flags)
{
	void *addr;

	addr = kvmalloc(size, hammer2_gfp(flags));
	KASSERTMSG(addr, "size %ld flags %x", (long)size, flags);
	if (addr)
		adjust_malloc_leak(size, type);
	return (addr);
}

static inline void *
hrealloc(void *addr, size_t size, void *type, int flags)
{
	addr = kvrealloc(addr, size, hammer2_gfp(flags));
	KASSERTMSG(addr, "size %ld flags %x", (long)size, flags);
	if (addr)
		adjust_malloc_leak(size, type);
	return (addr);
}

static inline void
hfree(void *addr, void *type, size_t freedsize)
{
	if (!addr)
		return;
	adjust_malloc_leak(-(int)freedsize, type);
	kvfree(addr);
}

static inline char *
hstrdup(const char *str)
{
	size_t len = strlen(str) + 1;

	adjust_malloc_leak(len, M_TEMP);
	return (kstrdup(str, GFP_KERNEL));
}

static inline void
hstrfree(char *str)
{
	adjust_malloc_leak(-(int)(strlen(str) + 1), M_TEMP);
	kfree(str);
}

/*
 * printf() and tsleep() are kernel facilities on every BSD this port
 * follows, so none of the three shims them and both names reach the
 * carried core unqualified.
 *
 * printf IS NOT pr_info, AND THE DIFFERENCE IS NOT COSMETIC.  A BSD
 * kernel printf appends to whatever line is open, so the core builds one
 * log line out of several calls: hammer2_bulkfree.c prints a range with
 * hprintf and no trailing newline, then finishes the line with printf.
 * Linux's pr_info closes a record per call, so that mapping turns one
 * line into two and drops the second's prefix.  pr_cont is Linux's own
 * name for "continue the open record", which is the semantics the core
 * is written against, and on a record that is already closed it simply
 * starts a new line.  So it is correct at both kinds of call site, where
 * pr_info is correct at only one.
 *
 * DEFER(a message is seen interleaved in a real mount): pr_cont is not
 * SMP-safe against a concurrent printk, which is why the kernel
 * discourages it in new code.  The core's multi-call lines are the
 * reason it is here; the upgrade is to build the line in a buffer and
 * emit it in one call, which is a core edit and waits for a reason.
 *
 * tsleep's contract is a timed sleep on a wait channel that wakeup()
 * can cut short.  The one call site is a throttle - bulkfree pausing
 * between passes - and nothing wakes that channel, so a plain timed
 * sleep is faithful there and not in general.
 * XXX A tsleep whose sleeper must be woken early needs the wait queue
 * hammer2_lkc_t already provides; this mapping would silently ignore
 * the wakeup.
 */
/* Linux */
#define printf(X, ...)	pr_cont(X, ## __VA_ARGS__)

static inline int
tsleep(const void *ident __always_unused, int flags __always_unused,
    const char *wmesg __always_unused, int timo)
{
	schedule_timeout_interruptible(timo);
	return (signal_pending(current) ? EINTR : 0);
}

/*
 * pause() is DragonFly's uninterruptible sibling of tsleep, used by the
 * chain and flush code to back off a lost race for one tick.  Nothing
 * wakes the channel, so the timeout is the whole contract and the
 * mapping is exact.  FreeBSD's port passes it straight through to its
 * own pause(); NetBSD's uses kpause().
 */
static inline void
pause(const char *wmesg __always_unused, int timo)
{
	schedule_timeout_uninterruptible(timo);
}

/*
 * The xop allocation zone.  Every BSD port allocates hammer2_xop_t from
 * its kernel's slab allocator rather than from malloc: FreeBSD from a uma
 * zone, NetBSD and OpenBSD from a pool.  Linux's equivalent is a
 * kmem_cache, and the FreeBSD names are kept because the carried core and
 * hammer2.h follow that port -- hammer2_admin.c calls uma_zalloc() by
 * name, and a rename here would be an edit to the core.
 *
 * FreeBSD declares the zone itself in its own hammer2_os.h, so this
 * follows suit.  It is defined by hammer2_vfsops.c, which has not landed;
 * until then nothing calls uma_zcreate() and the pointer is NULL.
 */
/* Linux */
typedef struct kmem_cache *uma_zone_t;

extern uma_zone_t hammer2_zone_xops;	/* hammer2_vfsops.c */

static inline uma_zone_t
uma_zcreate(const char *name, size_t size)
{
	return (kmem_cache_create(name, size, 0, 0, NULL));
}

static inline void
uma_zdestroy(uma_zone_t zone)
{
	kmem_cache_destroy(zone);
}

static inline void *
uma_zalloc(uma_zone_t zone, int flags)
{
	void *addr = kmem_cache_alloc(zone, hammer2_gfp(flags));

	KASSERTMSG(addr, "flags %x", flags);
	return (addr);
}

static inline void
uma_zfree(uma_zone_t zone, void *addr)
{
	kmem_cache_free(zone, addr);
}

#endif /* !_FS_HAMMER2_OS_H_ */
