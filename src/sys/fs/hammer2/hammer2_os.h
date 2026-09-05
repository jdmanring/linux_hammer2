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
#include <linux/errno.h>
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

/*
 * i_state is read through inode_state_read_once() from 6.19, where it
 * became a struct behind accessors that let the kernel validate consumers.
 * Before that it is a scalar and READ_ONCE() on it is the same read.
 * Measured by reading include/linux/fs.h at each tag rather than from
 * memory: u32 in v6.15, v6.16 and v6.17, enum inode_state_flags_t in
 * v6.18, and a struct with the two accessors in v6.19.
 *
 * The floor is 6.15 and this call sits in hammer2_igetv(), so without this
 * the module cannot build on four of the releases the #error above says it
 * supports, and it fails as an implicit declaration in the middle of a
 * build rather than at that #error. It did, on every push from 2026-09-02.
 */
#define LINUX_INODE_STATE_ACCESSORS	KERNEL_VERSION(6, 19, 0)
#if LINUX_VERSION_CODE < LINUX_INODE_STATE_ACCESSORS
#define inode_state_read_once(inode)	READ_ONCE((inode)->i_state) /* Linux */
#endif

/*
 * kzalloc_obj() is the object-allocation spelling that arrived in 7.0,
 * absent at v6.19 and present at v7.0, read at the tags. Below that,
 * kzalloc() with sizeof is the same allocation.
 *
 * The kernel's takes (P, ...) and this takes (P). That is deliberate.
 * The tail selects the gfp flags through default_gfp(), which arrived
 * with it and is equally absent at the floor, so honouring the tail
 * would mean writing a gfp-defaulting macro here: a second
 * implementation of the kernel's, to serve calls this tree does not
 * make. A call that does pass flags fails below 7.0, and gcc names this
 * macro when it does, "macro kzalloc_obj passed 2 arguments, but takes
 * just 1", which was measured rather than assumed. It fails only below
 * 7.0, so it would build on a developer's machine and break at the
 * floor; CI builds at 6.17 on every push, which is what turns that into
 * the same push rather than a later one.
 *
 * The guard is #ifndef and not a version comparison, because stable
 * series backport this: Arch's 6.18.46 has it where mainline v6.18 does
 * not, and a version guard redefined it there with a warning that a
 * -Werror build turns into a failure. Where the kernel spells a facility
 * as a macro, asking whether the macro exists is the exact question. The
 * guard above it cannot do the same, since inode_state_read_once() is an
 * inline function, and a macro of that name would shadow it silently
 * rather than collide; its version comparison is against mainline, which
 * is what the floor means, and a stable backport of that one would
 * defeat it.
 */
#ifndef kzalloc_obj
#define kzalloc_obj(P)		kzalloc(sizeof(typeof(P)), GFP_KERNEL) /* Linux */
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

/*
 * Linux: EVERY LOCK INITIALIZER HERE IS A MACRO WITH A STATIC KEY, the way
 * the kernel's own init_rwsem() and mutex_init() are.  Lockdep classes a
 * lock by the key its initializer was compiled with, so an inline
 * function initializing every hammer2_lk_t from one line put the mount
 * list lock, each PFS's XOP locks and the device locks in one class, and
 * an order between two of them read as one lock taken in two orders.
 * Measured: the first report after the chain locks were classed was a
 * false cycle between hammer2_mntlk and a pmp->xop_lock[].  With a key
 * per call site each core initializer is its own class, named by the
 * string the core already passes.
 */

/* hammer2_lk is lockmgr(9) in DragonFly. Every use in the core is exclusive. */
typedef struct rw_semaphore hammer2_lk_t;

#define hammer2_lk_init(p, s)						\
	do {								\
		static struct lock_class_key __key;			\
		__init_rwsem((p), (s), &__key);				\
	} while (0)

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
	unsigned int subclass;		/* lockdep nesting level, see below */
	atomic_t again;			/* shared re-locks owed no up_read */
};

typedef struct rw_semaphore_wrapper hammer2_mtx_t;

static inline void
__hammer2_mtx_init(hammer2_mtx_t *p, const char *s, struct lock_class_key *k)
{
	memset(p, 0, sizeof(*p));
	__init_rwsem(&p->lock, s, k);
}

#define hammer2_mtx_init(p, s)						\
	do {								\
		static struct lock_class_key __key;			\
		__hammer2_mtx_init((p), (s), &__key);			\
	} while (0)

/*
 * HOW THIS PORT'S LOCKS ARE DESCRIBED TO LOCKDEP.  A chain lock's class is
 * its blockref's type and keybits, set by hammer2_chain_lockdep_class()
 * when the core initializes it under the name "h2ch": keybits strictly
 * decreases from parent to child, so that orders every indirect and
 * freemap level, and the type separates volume, freemap, inode, dirent
 * and data from each other.  What a class cannot carry is the depth of an
 * inode chain under another inode chain, a directory above its entry, so
 * each chain also carries a nesting level, set by
 * hammer2_chain_lockdep_nest() where hammer2_chain_get() first knows the
 * parent: the parent's level, plus one when the parent is an inode.  The
 * level is the subclass every acquire below passes, the VFS's own
 * notation for i_rwsem.  The core spinlock in a chain is taken child
 * before parent, which upstream states as its rule, so its level runs
 * the other way.  An inode lock nests at its chain's level.  Every other
 * lock initializer in this file takes a static key per call site, as
 * init_rwsem() and mutex_init() do, so no two of the core's locks share a
 * class by accident.
 *
 * Every step of that was measured on the installed DragonFly root, 28210
 * paths, under CONFIG_PROVE_LOCKING, and doc/README.status.md records
 * the report each step removed.  With all of them lockdep stays enabled
 * through mount, the full walk, two thousand file reads and unmount.
 */

/*
 * The recursive variant, which DragonFly and FreeBSD provide and this
 * port does not.  A Linux rw_semaphore deadlocks against its own holder
 * exactly as a NetBSD krwlock does, so the mapping follows the NetBSD
 * port: there is no recursive lock, the two call sites
 * (hammer2_chain_init and hammer2_inode_get) get a plain lock, and the
 * ONE path that recursed is disabled for inodes this port creates.  That
 * path is hammer2_chain_lookup() reaching chain->lock again for an inode
 * in DIRECTDATA mode; NetBSD stops it by never setting
 * HAMMER2_OPFLAG_DIRECTDATA, which costs a data block for a tiny file
 * and costs no correctness.  This port sets it nowhere, because its only
 * setter is in hammer2_inode_create_normal(), which is not carried.
 * XXX The flag is ON DISK, so a filesystem written elsewhere still has
 * DIRECTDATA inodes and the lookup still reaches that branch.  Not
 * setting the flag does not close the READ path.  See
 * doc/README.porting.md; open for the read-only mount at 0.4.
 * XXX Not a recursive lock.  A caller that genuinely recurses will
 * deadlock rather than fail, so any new recursion must be resolved at
 * its call site the same way.
 */
/*
 * Linux: the lockdep class and level of a chain lock and the level of an
 * inode lock.  Defined in hammer2_vfsops.c, where the structs are
 * complete, and called by the core where each lock is initialized or
 * first placed under its parent, the marked lines in hammer2_chain.c and
 * hammer2_inode.c.  All of them compile to nothing without CONFIG_LOCKDEP.
 */
void hammer2_chain_lockdep_class(hammer2_mtx_t *);
void hammer2_chain_lockdep_nest(hammer2_mtx_t *, hammer2_mtx_t *);
void hammer2_inode_lockdep_nest(hammer2_mtx_t *);

static inline void
__hammer2_mtx_init_recurse(hammer2_mtx_t *p, const char *s,
    struct lock_class_key *k)
{
	__hammer2_mtx_init(p, s, k);
}

#define hammer2_mtx_init_recurse(p, s)					\
	do {								\
		static struct lock_class_key __key;			\
		__hammer2_mtx_init_recurse((p), (s), &__key);		\
	} while (0)

static inline void
hammer2_mtx_ex(hammer2_mtx_t *p)
{
	down_write_nested(&p->lock, p->subclass);
	WRITE_ONCE(p->owner, current);
	p->refs++;
}

/*
 * Linux: an exclusive acquisition of a lock nothing else can reach.
 * hammer2_inode_get() locks a freshly allocated inode, and
 * hammer2_pfsalloc() the root inode of a PFS not yet mounted, while the
 * caller holds the inode's chain lock, which is the reverse of the order
 * every later path uses, inode above chain.  Neither can deadlock, the
 * inode being unreachable, but lockdep records the order all the same and
 * reports the inversion at the next ordinary acquire.  A trylock records
 * no dependency, and on an unreachable lock it cannot fail; if it ever
 * does, the assumption behind this function is false, which is worth a
 * warning before falling back to the blocking acquire.
 */
static inline void
hammer2_mtx_ex_fresh(hammer2_mtx_t *p)
{
	if (WARN_ON_ONCE(!down_write_trylock(&p->lock)))
		down_write(&p->lock);
	WRITE_ONCE(p->owner, current);
	p->refs++;
}

static inline void
hammer2_mtx_sh(hammer2_mtx_t *p)
{
	down_read_nested(&p->lock, p->subclass);
	atomic_add_int(&p->refs, 1);
}

static inline int
hammer2_mtx_owned(hammer2_mtx_t *p)
{
	return (READ_ONCE(p->owner) == current);
}

/*
 * Linux: a shared lock taken again by a task that already holds it
 * shared, which is what HAMMER2_RESOLVE_LOCKAGAIN means and what
 * DragonFly's mtx_lock_sh() does natively.  A second down_read() is not
 * that: a writer queued between the two blocks the second, and the task
 * deadlocks on itself, which lockdep reported on the first embedded-data
 * file read under it.  So the rwsem is not touched.  The re-lock is a
 * credit, and the next shared unlock on this lock spends the credit
 * instead of an up_read().  Any shared holder may spend it; the rwsem's
 * reader count is the sum of down_reads less up_reads whoever made them,
 * so the lock is released exactly when the last logical holder leaves,
 * and no writer is admitted earlier than it would have been.  The one
 * caller, hammer2_chain_lock() under LOCKAGAIN, never upgrades a lock it
 * holds this way, and hammer2_mtx_upgrade_try() assumes as much.
 */
static inline void
hammer2_mtx_sh_again(hammer2_mtx_t *p)
{
	atomic_inc(&p->again);
	atomic_add_int(&p->refs, 1);
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
		if (atomic_dec_if_positive(&p->again) >= 0)
			return;		/* a re-lock's credit, no up_read owed */
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
 * XXX Linux has downgrade_write() and no atomic upgrade, so the shared to
 * exclusive transition is done by releasing and retaking, which is what
 * the OpenBSD port does here for the same reason.
 *
 * This returned failure for every shared holder until a mount measured
 * it: hammer2_chain_unlock() asks for the upgrade in a loop and treats
 * refusal as a race to be retried, so a caller holding the chain shared
 * spun in that loop without end, unkillable, holding the mount until the
 * machine was rebooted. The comment this replaces asserted that every
 * caller of a _try drops and re-acquires on failure. That caller does not,
 * and a predicate that can never succeed is not a slow implementation of
 * an upgrade.
 *
 * The window where neither side is held is the one the caller's loop
 * already anticipates: it re-reads lockcnt on every iteration and commits
 * with a compare-and-set, so an upgrade that fails leaves the caller
 * holding exactly what it held before.
 */
static inline int
hammer2_mtx_upgrade_try(hammer2_mtx_t *p)
{
	if (hammer2_mtx_owned(p))
		return (0);

	up_read(&p->lock);
	if (!down_write_trylock(&p->lock)) {
		down_read(&p->lock);	/* Linux: restore the caller's hold */
		return (1);
	}
	WRITE_ONCE(p->owner, current);
	return (0);
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
/*
 * Linux: the wrapper carries a lockdep nesting level, as the mutex does.
 * A chain's core spinlock is taken bottom-up, child before parent, which
 * upstream's hammer2_chain_lastdrop() states as the rule for these locks
 * and the reverse of the chain lock's own order, so the level a chain's
 * core spinlock is given runs the other way: the deeper the chain, the
 * lower the subclass.  Set beside the chain lock's level in
 * hammer2_vfsops.c; every other spinlock stays at 0.
 */
struct hammer2_spin_wrapper {
	struct rw_semaphore lock;
	unsigned int subclass;
};

typedef struct hammer2_spin_wrapper hammer2_spin_t;

#define hammer2_spin_init(p, s)						\
	do {								\
		static struct lock_class_key __key;			\
		__init_rwsem(&(p)->lock, (s), &__key);			\
	} while (0)

static inline void
hammer2_spin_ex(hammer2_spin_t *p)
{
	down_write_nested(&p->lock, p->subclass);
}

static inline void
hammer2_spin_sh(hammer2_spin_t *p)
{
	down_read_nested(&p->lock, p->subclass);
}

static inline void
hammer2_spin_unex(hammer2_spin_t *p)
{
	up_write(&p->lock);
}

static inline void
hammer2_spin_unsh(hammer2_spin_t *p)
{
	up_read(&p->lock);
}

static inline void
hammer2_spin_destroy(hammer2_spin_t *p __always_unused)
{
}

#ifdef HAMMER2_INVARIANTS
#define hammer2_spin_assert_locked(p)	BUG_ON(!rwsem_is_locked(&(p)->lock))
#define hammer2_spin_assert_unlocked(p)	BUG_ON(rwsem_is_locked(&(p)->lock))
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

/*
 * XXX M_WAITOK MUST NOT FAIL, because eighteen carried call sites are
 * written against malloc(9), where it cannot.  Not one of them checks the
 * return, and that is upstream being correct rather than sloppy.  This
 * mapped M_WAITOK to a plain GFP_KERNEL until 2026-08-26, which can
 * return NULL: the whole carried core would then have dereferenced it,
 * guarded only by a KASSERTMSG that the default build compiles out.  The
 * same shape as the KKASSERT that stood in for a device close.
 *
 * __GFP_NOFAIL is the kernel's own name for this contract, and kvmalloc
 * honours it.  Read against Linux v7.2, mm/slub.c: __do_kmalloc_node()
 * takes the flag directly for a sub-page request, and above PAGE_SIZE
 * kmalloc_gfp_adjust() strips it with the comment "nofail semantic is
 * implemented by the vmalloc fallback".  So the one residual is a size
 * above INT_MAX, which __kvmalloc_node_noprof() refuses with a
 * WARN_ON_ONCE and a NULL whatever it is passed; the KASSERTMSG at each
 * caller is left in place for that, and no size in this module is within
 * three orders of magnitude of it.
 *
 * M_NOWAIT keeps GFP_NOWAIT and may still fail, which is also malloc(9)'s
 * contract and what the carried code expects when it passes it.
 */
static inline gfp_t
hammer2_gfp(int flags)
{
	gfp_t gfp;

	if (flags & M_NOWAIT)
		gfp = GFP_NOWAIT;
	else
		gfp = GFP_KERNEL | __GFP_NOFAIL;	/* Linux */

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

/*
 * XXX Linux: FreeBSD's hstrdup() is strdup(9) with M_WAITOK, which is
 * the same contract as the block above and cannot return NULL, so no
 * caller here or upstream checks one.  This passed a plain GFP_KERNEL
 * until 2026-08-26 and so could: hammer2_pfsalloc() would have stored
 * NULL in pfs_names[], hammer2_init_devvp() would have stored it in
 * e->path against a KKASSERT the default build compiles out, and
 * hammer2_get_tree() would have dereferenced it two lines later.  It
 * goes through hammer2_gfp() now for exactly the reason hmalloc() does,
 * and hstrfree()'s strlen() is safe for the same reason.
 */
static inline char *
hstrdup(const char *str)
{
	char *addr;

	addr = kstrdup(str, hammer2_gfp(M_WAITOK));
	KASSERTMSG(addr, "len %ld", (long)strlen(str));
	if (addr)
		adjust_malloc_leak(strlen(str) + 1, M_TEMP);
	return (addr);
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

extern uma_zone_t hammer2_zone_inode;	/* hammer2_vfsops.c */
extern uma_zone_t hammer2_zone_xops;	/* hammer2_vfsops.c */
/*
 * FreeBSD declares two more here, hammer2_zone_rbuf and hammer2_zone_wbuf,
 * for the compression bounce buffers in its strategy write path.  That
 * path is a rewrite here and no carried file names them, so they are not
 * declared until something calls them.
 */

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

/*
 * Flushing the device beneath the volume header.  The core issues two
 * operations in order: write back the device's dirty pages, then tell the
 * drive to empty its own write cache.  The second without the first is a
 * barrier around nothing.
 *
 * DragonFly builds a zero-length buf with BUF_CMD_FLUSH and hands it to
 * vn_strategy().  FreeBSD's port allocates a GEOM bio carrying BIO_FLUSH;
 * NetBSD's and OpenBSD's both collapse it to one VOP_IOCTL(DIOCCACHESYNC).
 * Linux has that single call, so these follow NetBSD and OpenBSD.
 *
 * Both return a positive errno, by the core's convention.
 */
/* Linux */
static inline int
hammer2_dev_writeback(struct file *bdev_file)
{
	return (-sync_blockdev(file_bdev(bdev_file)));
}

/* Linux */
static inline int
hammer2_dev_cache_flush(struct file *bdev_file)
{
	return (-blkdev_issue_flush(file_bdev(bdev_file)));
}

/*
 * The errno the VFS sees.  The core's hammer2_error_to_errno() is
 * upstream's and maps a check code mismatch, and any error it has no
 * name for, to EDOM, which DragonFly's system calls do return.  Linux's
 * do not: a block that failed its checksum is EIO to every filesystem in
 * the tree, and EDOM out of read(2) or stat(2) presents as a libm
 * failure.  Every entry point the VFS calls returns through here, so the
 * core keeps its mapping and the boundary owns what Linux sees, negated
 * as the VFS expects.
 */
/* Linux */
static inline int
hammer2_vfs_errno(int error)
{
	return (error == EDOM ? -EIO : -error);
}

#endif /* !_FS_HAMMER2_OS_H_ */
