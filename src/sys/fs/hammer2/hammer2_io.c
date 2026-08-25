// SPDX-License-Identifier: BSD-3-Clause
/*
 * Copyright (c) 2026 James Manring.  All rights reserved.
 * Copyright (c) 2022-2023 Tomohiro Kusumi <tkusumi@netbsd.org>
 * Copyright (c) 2013-2023 The DragonFly Project.  All rights reserved.
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
 * "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
 * LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
 * FOR A PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE
 * COPYRIGHT HOLDERS OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
 * INCIDENTAL, SPECIAL, EXEMPLARY OR CONSEQUENTIAL DAMAGES (INCLUDING,
 * BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
 * LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
 * CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 * ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

/*
 * The DIO layer, one hammer2_io per 64KB physical buffer.
 *
 * The hash and dedup halves are the FreeBSD port's, which replaced the
 * lockless DIO_INPROG state machine with a per-dio mutex. The OS-facing
 * half is written against the block device page cache: sb_set_blocksize()
 * makes every folio in that mapping a 64KB folio, so one hammer2_io holds
 * exactly one. Caching, writeback and reclaim belong to the page cache;
 * this file holds a folio reference for the life of DIO_GOOD, dirties it
 * on a dirty last drop, and kicks writeback on DIO_FLUSH.
 *
 * The format sits exactly on BLK_MAX_BLOCK_SIZE, which is 64KB only under
 * CONFIG_TRANSPARENT_HUGEPAGE. Without it the mount would fail EINVAL
 * saying nothing about why, so the assert below moves that to the build.
 * See docs/PORTING.md.
 */

#include "hammer2.h"

#include <linux/blkdev.h>
#include <linux/highmem.h>
#include <linux/mm.h>
#include <linux/pagemap.h>

/*
 * Operations for hammer2_io_getblk().  FreeBSD keeps these private to
 * its hammer2_io.c and so does this file; the core reaches them through
 * hammer2_io_new/newnz/bread/getquick.
 */
#define HAMMER2_DOP_READ	1
#define HAMMER2_DOP_NEW		2
#define HAMMER2_DOP_NEWNZ	3
#define HAMMER2_DOP_READQ	4

static_assert(HAMMER2_PBUFSIZE <= BLK_MAX_BLOCK_SIZE,
	      "HAMMER2_PBUFSIZE exceeds BLK_MAX_BLOCK_SIZE: this kernel lacks "
	      "CONFIG_TRANSPARENT_HUGEPAGE and cannot mount HAMMER2; "
	      "see docs/PORTING.md");
/*
 * hammer2_io_data() hands the core a pointer it keeps across sleeps, so
 * the folio's memory must be permanently mapped: folio_address(), not
 * kmap_local_folio().  True on every 64-bit target; a 32-bit HIGHMEM
 * kernel would need the core to map and unmap around every access.
 * DEFER(a 32-bit target is wanted): map per access in the callers.
 */
static_assert(!IS_ENABLED(CONFIG_HIGHMEM),
	      "hammer2 assumes a permanently mapped page cache");

/*
 * Page cache index of the 64 KiB folio holding device offset `pbase`
 * relative to the volume's start.  pbase is HAMMER2_PBUFSIZE-aligned,
 * so the index is aligned to the folio order the mapping enforces.
 */
static inline pgoff_t
hammer2_io_index(hammer2_io_t *dio)
{
	return (pgoff_t)((dio->pbase - dio->dbase) >> PAGE_SHIFT);
}

static inline struct address_space *
hammer2_io_mapping(hammer2_io_t *dio)
{
	return dio->bdev_file->f_mapping;
}

static __inline void
hammer2_assert_io_refs(hammer2_io_t *dio)
{
	KKASSERT(dio);
	hammer2_mtx_assert_ex(&dio->lock);
	KKASSERT((dio->refs & HAMMER2_DIO_MASK) != 0);
}

void
hammer2_io_hash_init(hammer2_dev_t *hmp)
{
	hammer2_io_hash_t *hash;
	int i;

	for (i = 0; i < HAMMER2_IOHASH_SIZE; ++i) {
		hash = &hmp->iohash[i];
		hammer2_spin_init(&hash->spin, "h2dev_io");
	}
}

void
hammer2_io_hash_destroy(hammer2_dev_t *hmp)
{
	hammer2_io_hash_t *hash;
	int i;

	for (i = 0; i < HAMMER2_IOHASH_SIZE; ++i) {
		hash = &hmp->iohash[i];
		hammer2_spin_destroy(&hash->spin);
	}
}

static hammer2_io_t *hammer2_io_hash_lookup(hammer2_dev_t *hmp,
    hammer2_off_t pbase, uint64_t *refsp);
static hammer2_io_t *hammer2_io_hash_enter(hammer2_dev_t *hmp,
    hammer2_io_t *dio, uint64_t *refsp);
static void hammer2_io_hash_cleanup(hammer2_dev_t *hmp, int dio_limit);

/*
 * Returns the locked DIO corresponding to the data|radix offset.
 */
static hammer2_io_t *
hammer2_io_alloc(hammer2_dev_t *hmp, hammer2_off_t data_off, uint8_t btype,
    int createit)
{
	hammer2_volume_t *vol;
	hammer2_io_t *dio, *xio;
	hammer2_off_t lbase, pbase, pmask;
	int lsize, psize;

	hammer2_mtx_assert_ex(&hmp->iohash_lock);

	psize = HAMMER2_PBUFSIZE;
	pmask = ~(hammer2_off_t)(psize - 1);
	if ((int)(data_off & HAMMER2_OFF_MASK_RADIX))
		lsize = 1 << (int)(data_off & HAMMER2_OFF_MASK_RADIX);
	else
		lsize = 0;
	lbase = data_off & ~HAMMER2_OFF_MASK_RADIX;
	pbase = lbase & pmask;

	if (pbase == 0 || ((lbase + lsize - 1) & pmask) != pbase)
		hpanic("illegal base: %016llx %016llx+%08x / %016llx",
		    (long long)pbase, (long long)lbase, lsize,
		    (long long)pmask);

	/* Access or allocate dio, bump dio->refs to prevent destruction. */
	dio = hammer2_io_hash_lookup(hmp, pbase, NULL);
	if (dio) {
		/* NOP */
	} else if (createit) {
		vol = hammer2_get_volume(hmp, pbase);
		dio = hmalloc(sizeof(*dio), M_HAMMER2, M_WAITOK | M_ZERO);
		dio->hmp = hmp;
		dio->bdev_file = vol->dev->bdev_file;
		dio->dbase = vol->offset;
		KKASSERT((dio->dbase & HAMMER2_FREEMAP_LEVEL1_MASK) == 0);
		dio->pbase = pbase;
		dio->psize = psize;
		dio->btype = btype;
		dio->refs = 1;
		dio->act = 5;
		hammer2_mtx_init(&dio->lock, "h2io");
		hammer2_mtx_ex(&dio->lock);
		xio = hammer2_io_hash_enter(hmp, dio, NULL);
		if (xio == NULL) {
			atomic_add_int(&hammer2_count_dio_allocated, 1);
		} else {
			hammer2_mtx_unlock(&dio->lock);
			hammer2_mtx_destroy(&dio->lock);
			hfree(dio, M_HAMMER2, sizeof(*dio));
			dio = xio;
			hammer2_mtx_ex(&dio->lock);
		}
	} else {
		return (NULL);
	}

	dio->ticks = getticks();
	if (dio->act < 10)
		++dio->act;

	hammer2_assert_io_refs(dio);

	return (dio);
}

/*
 * Bring the dio's folio in from the device, uptodate, holding one
 * reference.  read_mapping_folio() returns the folio UNLOCKED with the
 * read complete, or an ERR_PTR; it blocks in process context, which is
 * the whole reason reading 1's rw_semaphore mapping stays legal.
 *
 * Readahead: the BSDs pass a cluster hint (hammer2_cluster_*_read) to
 * cluster_read().  The block device mapping has the kernel's own
 * readahead behind read_cache_folio(); nothing is passed.
 * DEFER(sequential-read throughput measured against DragonFly in H6):
 * page_cache_sync_ra() with the same hint, if the measurement wants it.
 */
static int
hammer2_bread(hammer2_dev_t *hmp, hammer2_io_t *dio)
{
	struct folio *folio;

	folio = read_mapping_folio(hammer2_io_mapping(dio),
				   hammer2_io_index(dio), dio->bdev_file);
	if (IS_ERR(folio))
		return (int)-PTR_ERR(folio);	/* the core's errnos are positive */
	KKASSERT(folio_size(folio) >= (size_t)dio->psize);
	dio->folio = folio;
	hammer2_inc_iostat(&hmp->iostat_read, dio->btype, dio->psize);

	return (0);
}

/*
 * Get the dio's folio WITHOUT reading it: the caller is about to write
 * every byte of the physical buffer (DOP_NEW zeroes it here, DOP_NEWNZ
 * fills it).  filemap_grab_folio() returns it locked; it is marked
 * uptodate so a later read finds it, and unlocked before return since
 * this file holds references, never locks, across the dio's life.
 */
static int
hammer2_getblk_new(hammer2_io_t *dio, int zero)
{
	struct folio *folio;

	folio = filemap_grab_folio(hammer2_io_mapping(dio),
				   hammer2_io_index(dio));
	if (IS_ERR(folio))
		return (int)-PTR_ERR(folio);	/* the core's errnos are positive */
	KKASSERT(folio_size(folio) >= (size_t)dio->psize);
	if (zero)
		folio_zero_range(folio, 0, dio->psize);
	folio_mark_uptodate(folio);
	folio_unlock(folio);
	dio->folio = folio;

	return (0);
}

/*
 * Acquire the requested dio.
 * If DIO_GOOD is set the buffer already exists and is good to go.
 */
hammer2_io_t *
hammer2_io_getblk(hammer2_dev_t *hmp, int btype, hammer2_off_t lbase, int lsize,
    int op)
{
	hammer2_io_t *dio;
	int error;

	KKASSERT((1 << (int)(lbase & HAMMER2_OFF_MASK_RADIX)) == lsize);

	hammer2_mtx_ex(&hmp->iohash_lock);
	if (op == HAMMER2_DOP_READQ) {
		dio = hammer2_io_alloc(hmp, lbase, btype, 0);
		if (dio == NULL) {
			hammer2_mtx_unlock(&hmp->iohash_lock);
			return (NULL);
		}
		op = HAMMER2_DOP_READ;
	} else {
		dio = hammer2_io_alloc(hmp, lbase, btype, 1);
	}
	KKASSERT(dio);
	hammer2_assert_io_refs(dio); /* dio locked + refs > 0 */
	hammer2_mtx_unlock(&hmp->iohash_lock);

	/* Buffer is already GOOD, handle the op and return. */
	if (dio->refs & HAMMER2_DIO_GOOD) {
		switch (op) {
		case HAMMER2_DOP_NEW:
			memset(hammer2_io_data(dio, lbase), 0, lsize);
			fallthrough;
		case HAMMER2_DOP_NEWNZ:
			dio->refs |= HAMMER2_DIO_DIRTY;
			break;
		default:
			break;
		}
		hammer2_mtx_unlock(&dio->lock);
		return (dio);
	}

	/* GOOD is not set. */
	KKASSERT(dio->folio == NULL);

	error = 0;
	if (dio->pbase == (lbase & ~HAMMER2_OFF_MASK_RADIX) &&
	    dio->psize == lsize) {
		/* The whole physical buffer is being created. */
		switch (op) {
		case HAMMER2_DOP_NEW:
		case HAMMER2_DOP_NEWNZ:
			error = hammer2_getblk_new(dio, op == HAMMER2_DOP_NEW);
			if (error == 0)
				dio->refs |= HAMMER2_DIO_DIRTY;
			break;
		default:
			error = hammer2_bread(hmp, dio);
			break;
		}
	} else {
		/* A logical buffer inside it: the rest must come from disk. */
		error = hammer2_bread(hmp, dio);
		if (dio->folio) {
			KKASSERT(error == 0);
			switch (op) {
			case HAMMER2_DOP_NEW:
				memset(hammer2_io_data(dio, lbase), 0, lsize);
				fallthrough;
			case HAMMER2_DOP_NEWNZ:
				dio->refs |= HAMMER2_DIO_DIRTY;
				break;
			default:
				break;
			}
		}
	}
	KKASSERT(error == 0 || dio->folio == NULL);

	dio->error = error;
	if (error == 0)
		dio->refs |= HAMMER2_DIO_GOOD;

	hammer2_mtx_unlock(&dio->lock);

	/*
	 * Upstream carries "XXX error handling" here: an errored dio is
	 * returned with dio->error set and no buffer, and every caller
	 * reads ->error.  Kept, so the callers' contract is unchanged.
	 */

	return (dio);
}

/*
 * Release our ref on *diop.
 * On the 1->0 transition we clear DIO_GOOD and dispose of dio->folio.
 */
void
hammer2_io_putblk(hammer2_io_t **diop)
{
	hammer2_dev_t *hmp;
	hammer2_io_t *dio;
	struct folio *folio;
	uint64_t orefs;
	int dio_limit;

	dio = *diop;
	*diop = NULL;

	hammer2_mtx_ex(&dio->lock);
	if ((dio->refs & HAMMER2_DIO_MASK) == 0) {
		hammer2_mtx_unlock(&dio->lock);
		return; /* lost race */
	}
	hammer2_assert_io_refs(dio);

	/*
	 * Drop refs.
	 * On the 1->0 transition clear DIO_GOOD.
	 * On any other transition we can return early.
	 */
	orefs = dio->refs;
	if ((dio->refs & HAMMER2_DIO_MASK) == 1) {
		dio->refs--;
		dio->refs &= ~(HAMMER2_DIO_GOOD | HAMMER2_DIO_DIRTY);
	} else {
		dio->refs--;
		hammer2_mtx_unlock(&dio->lock);
		return;
	}

	/* Lastdrop (1->0 transition) case. */
	hmp = dio->hmp;
	folio = dio->folio;
	dio->folio = NULL;

	/*
	 * Dispose of the folio reference.  The BSD version chooses among
	 * bdwrite (delay), bawrite/cluster_write (issue now) and
	 * brelse/bqrelse here; on Linux "delay" is what marking a page
	 * cache folio dirty already means, and "issue now" is
	 * filemap_fdatawrite_range over exactly this buffer.  Dillon's
	 * reasoning for defaulting to delay is kept from upstream:
	 *
	 *   Allows dirty buffers to accumulate and possibly be canceled
	 *   (e.g. by a 'rm'), by default we will burst-write later.  Due
	 *   to the way chains are locked, buffers may be cycled in and
	 *   out quite often and disposal here can cause multiple writes
	 *   or write-read stalls.  If FLUSH is set we do want to issue
	 *   the actual write; this typically occurs in the write-behind
	 *   case when writing to large files.
	 */
	if ((orefs & HAMMER2_DIO_GOOD) && folio) {
		if (orefs & HAMMER2_DIO_DIRTY) {
			folio_mark_dirty_lock(folio);
			if (dio->refs & HAMMER2_DIO_FLUSH) {
				loff_t start = (loff_t)(dio->pbase - dio->dbase);

				filemap_fdatawrite_range(hammer2_io_mapping(dio),
				    start, start + dio->psize - 1);
			}
			hammer2_inc_iostat(&hmp->iostat_write, dio->btype,
			    dio->psize);
		}
		folio_put(folio);
	} else if (folio) {
		/* Errored disposal of buffer. */
		folio_put(folio);
	}

	/* Update iofree_count before disposing of the dio. */
	atomic_add_int(&hmp->iofree_count, 1);

	KKASSERT(!(dio->refs & HAMMER2_DIO_GOOD));
	hammer2_mtx_unlock(&dio->lock);
	/* Another process may come in and get/put this dio. */

	/*
	 * We cache free buffers so re-use cases can use a shared lock,
	 * but if too many build up we have to clean them out.
	 */
	hammer2_mtx_ex(&hmp->iohash_lock);
	dio_limit = hammer2_dio_limit;
	if (dio_limit < 256)
		dio_limit = 256;
	if (dio_limit > 1024*1024)
		dio_limit = 1024*1024;
	if (hmp->iofree_count > dio_limit)
		hammer2_io_hash_cleanup(hmp, dio_limit);
	hammer2_mtx_unlock(&hmp->iohash_lock);
}

char *
hammer2_io_data(hammer2_io_t *dio, hammer2_off_t lbase)
{
	struct folio *folio;
	int off;

	folio = dio->folio;
	KASSERTMSG(folio != NULL, "NULL dio folio");

	off = (int)((lbase & ~HAMMER2_OFF_MASK_RADIX) - dio->pbase);

	KASSERTMSG(off >= 0, "bad offset not 0x%x >= 0x%x", off, 0);
	KASSERTMSG(off < dio->psize, "bad offset not 0x%x < 0x%x",
	    off, dio->psize);

	return ((char *)folio_address(folio) + off);
}

int
hammer2_io_new(hammer2_dev_t *hmp, int btype, hammer2_off_t lbase, int lsize,
    hammer2_io_t **diop)
{
	*diop = hammer2_io_getblk(hmp, btype, lbase, lsize, HAMMER2_DOP_NEW);
	return ((*diop)->error);
}

int
hammer2_io_newnz(hammer2_dev_t *hmp, int btype, hammer2_off_t lbase, int lsize,
    hammer2_io_t **diop)
{
	*diop = hammer2_io_getblk(hmp, btype, lbase, lsize, HAMMER2_DOP_NEWNZ);
	return ((*diop)->error);
}

int
hammer2_io_bread(hammer2_dev_t *hmp, int btype, hammer2_off_t lbase, int lsize,
    hammer2_io_t **diop)
{
	*diop = hammer2_io_getblk(hmp, btype, lbase, lsize, HAMMER2_DOP_READ);
	return ((*diop)->error);
}

hammer2_io_t *
hammer2_io_getquick(hammer2_dev_t *hmp, hammer2_off_t lbase, int lsize)
{
	return (hammer2_io_getblk(hmp, 0, lbase, lsize, HAMMER2_DOP_READQ));
}

/*
 * Ref a dio that is already owned.  DragonFly's atomic_add_64 on refs;
 * the per-dio mutex is the reference discipline here.
 */
void
hammer2_io_ref(hammer2_io_t *dio)
{
	hammer2_mtx_ex(&dio->lock);
	dio->refs++;
	hammer2_mtx_unlock(&dio->lock);
}

/*
 * FreeBSD sets these flag bits with an atomic OR outside the dio lock.
 * The lock is taken instead: it is a sleeping lock and the bits share a
 * word with the refcount that putblk reads under it.
 */
static inline void
hammer2_io_setflags(hammer2_io_t *dio, uint64_t flags)
{
	hammer2_mtx_ex(&dio->lock);
	dio->refs |= flags;
	hammer2_mtx_unlock(&dio->lock);
}

void
hammer2_io_bawrite(hammer2_io_t **diop)
{
	hammer2_io_setflags(*diop, HAMMER2_DIO_DIRTY | HAMMER2_DIO_FLUSH);
	hammer2_io_putblk(diop);
}

void
hammer2_io_bdwrite(hammer2_io_t **diop)
{
	hammer2_io_setflags(*diop, HAMMER2_DIO_DIRTY);
	hammer2_io_putblk(diop);
}

int
hammer2_io_bwrite(hammer2_io_t **diop)
{
	hammer2_io_setflags(*diop, HAMMER2_DIO_DIRTY | HAMMER2_DIO_FLUSH);
	hammer2_io_putblk(diop);

	return (0); /* upstream: XXX */
}

void
hammer2_io_setdirty(hammer2_io_t *dio)
{
	hammer2_io_setflags(dio, HAMMER2_DIO_DIRTY);
}

void
hammer2_io_brelse(hammer2_io_t **diop)
{
	hammer2_io_putblk(diop);
}

void
hammer2_io_bqrelse(hammer2_io_t **diop)
{
	hammer2_io_putblk(diop);
}

/*
 * Two DragonFly entry points the carried core still calls
 * (hammer2_flush.c:932, hammer2_chain.c:847) and FreeBSD dropped:
 *
 * hammer2_io_inval() is a NOP upstream too ("for now, don't try to
 * invalidate the data areas", hammer2_io.c:660), kept so the callers
 * stay byte-identical.
 *
 * hammer2_io_bkvasync() is bkvasync(9): on DragonFly a buffer's kernel
 * virtual mapping can be stale on another CPU after the buffer is
 * recycled and must be synchronised before the data is read.  A page
 * cache folio is the memory, not a mapping of it, so there is nothing
 * to synchronise.
 */
void
hammer2_io_inval(hammer2_io_t *dio __always_unused,
    hammer2_off_t data_off __always_unused, unsigned int bytes __always_unused)
{
}

void
hammer2_io_bkvasync(hammer2_io_t *dio)
{
	KKASSERT(dio->folio != NULL);
}

/*
 * ---- Carried from FreeBSD unchanged below this line: the hash and
 * ---- the dedup masks.  Neither touches the buffer.
 */

static __inline hammer2_io_hash_t *
hammer2_io_hashv(hammer2_dev_t *hmp, hammer2_off_t pbase)
{
	int hv;

	hv = (int)pbase + (int)(pbase >> 16);
	return (&hmp->iohash[hv & HAMMER2_IOHASH_MASK]);
}

/*
 * Lookup and reference the requested dio.
 */
static hammer2_io_t *
hammer2_io_hash_lookup(hammer2_dev_t *hmp, hammer2_off_t pbase, uint64_t *refsp)
{
	hammer2_io_hash_t *hash;
	hammer2_io_t *dio;
	uint64_t refs;

	hammer2_mtx_assert_ex(&hmp->iohash_lock);

	if (refsp)
		*refsp = 0;

	hash = hammer2_io_hashv(hmp, pbase);
	for (dio = hash->base; dio; dio = dio->next) {
		if (dio->pbase == pbase) {
			hammer2_mtx_ex(&dio->lock);
			refs = dio->refs++;
			if ((refs & HAMMER2_DIO_MASK) == 0)
				atomic_add_int(&dio->hmp->iofree_count, -1);
			if (refsp)
				*refsp = refs;
			break;
		}
	}

	if (dio)
		hammer2_assert_io_refs(dio);
	return (dio);
}

/*
 * Enter a dio into the hash.  If the pbase already exists in the hash,
 * the xio in the hash is referenced and returned.  If dio is sucessfully
 * entered into the hash, NULL is returned.
 */
static hammer2_io_t *
hammer2_io_hash_enter(hammer2_dev_t *hmp, hammer2_io_t *dio, uint64_t *refsp)
{
	hammer2_io_hash_t *hash;
	hammer2_io_t *xio, **xiop;
	uint64_t refs;

	hammer2_mtx_assert_ex(&hmp->iohash_lock);
	hammer2_assert_io_refs(dio);

	if (refsp)
		*refsp = 0;

	hash = hammer2_io_hashv(hmp, dio->pbase);
	for (xiop = &hash->base; (xio = *xiop) != NULL; xiop = &xio->next) {
		if (xio->pbase == dio->pbase) {
			refs = xio->refs++;
			if ((refs & HAMMER2_DIO_MASK) == 0)
				atomic_add_int(&xio->hmp->iofree_count, -1);
			if (refsp)
				*refsp = refs;
			goto done;
		}
	}
	dio->next = NULL;
	*xiop = dio;
done:
	return (xio);
}

/*
 * Clean out a limited number of freeable DIOs.
 */
static void
hammer2_io_hash_cleanup(hammer2_dev_t *hmp, int dio_limit)
{
	hammer2_io_hash_t *hash;
	hammer2_io_t *dio, **diop, *cleanbase, **cleanapp;
	int count, maxscan, act, i;

	hammer2_mtx_assert_ex(&hmp->iohash_lock);

	count = hmp->iofree_count - dio_limit + 32;
	if (count <= 0)
		return;

	cleanbase = NULL;
	cleanapp = &cleanbase;
	i = hmp->io_iterator++;
	maxscan = HAMMER2_IOHASH_SIZE;

	while (count > 0 && maxscan--) {
		hash = &hmp->iohash[i & HAMMER2_IOHASH_MASK];
		diop = &hash->base;
		while ((dio = *diop) != NULL) {
			if ((dio->refs & HAMMER2_DIO_MASK) != 0) {
				diop = &dio->next;
				continue;
			}
			if (dio->act > 0) {
				act = dio->act - (getticks() - dio->ticks) / hz - 1;
				dio->act = (act < 0) ? 0 : act;
			}
			if (dio->act) {
				diop = &dio->next;
				continue;
			}
			KKASSERT(dio->folio == NULL);
			*diop = dio->next;
			dio->next = NULL;
			*cleanapp = dio;
			cleanapp = &dio->next;
			--count;
			/* diop remains unchanged */
			atomic_add_int(&hammer2_count_dio_allocated, -1);
			atomic_add_int(&hmp->iofree_count, -1);
		}
		i = hmp->io_iterator++;
	}

	/* Get rid of dios on clean list without holding any locks. */
	while ((dio = cleanbase) != NULL) {
		cleanbase = dio->next;
		dio->next = NULL;
		KKASSERT(dio->folio == NULL &&
		    (dio->refs & HAMMER2_DIO_MASK) == 0);
		if (dio->refs & HAMMER2_DIO_DIRTY)
			hprintf("dirty buffer %016llx/%d\n",
			    (long long)dio->pbase, dio->psize);
		hammer2_mtx_destroy(&dio->lock);
		hfree(dio, M_HAMMER2, sizeof(*dio));
	}
}

/*
 * Destroy all DIOs associated with the media.
 */
void
hammer2_io_hash_cleanup_all(hammer2_dev_t *hmp)
{
	hammer2_io_hash_t *hash;
	hammer2_io_t *dio;
	int i;

	hammer2_mtx_assert_ex(&hmp->iohash_lock);

	for (i = 0; i < HAMMER2_IOHASH_SIZE; ++i) {
		hash = &hmp->iohash[i];
		while ((dio = hash->base) != NULL) {
			hash->base = dio->next;
			dio->next = NULL;
			KKASSERT(dio->folio == NULL &&
			    (dio->refs & HAMMER2_DIO_MASK) == 0);
			if (dio->refs & HAMMER2_DIO_DIRTY)
				hprintf("dirty buffer %016llx/%d\n",
				    (long long)dio->pbase, dio->psize);
			hammer2_mtx_destroy(&dio->lock);
			hfree(dio, M_HAMMER2, sizeof(*dio));
			atomic_add_int(&hammer2_count_dio_allocated, -1);
			atomic_add_int(&hmp->iofree_count, -1);
		}
	}
}

#define HAMMER2_DEDUP_FRAG	(HAMMER2_PBUFSIZE / 64)
#define HAMMER2_DEDUP_FRAGRADIX	(HAMMER2_PBUFRADIX - 6)

uint64_t
hammer2_dedup_mask(hammer2_io_t *dio, hammer2_off_t data_off, unsigned int bytes)
{
	int bbeg, bits;
	uint64_t mask;

	bbeg = (int)((data_off & ~HAMMER2_OFF_MASK_RADIX) - dio->pbase) >>
	    HAMMER2_DEDUP_FRAGRADIX;
	bits = (int)((bytes + (HAMMER2_DEDUP_FRAG - 1)) >>
	    HAMMER2_DEDUP_FRAGRADIX);

	if (bbeg + bits == 64)
		mask = (uint64_t)-1;
	else
		mask = ((uint64_t)1 << (bbeg + bits)) - 1;
	mask &= ~(((uint64_t)1 << bbeg) - 1);

	return (mask);
}

/*
 * Set dedup validation bits in a DIO.  We do not need the buffer cache
 * buffer for this.  This must be done concurrent with setting bits in
 * the freemap so as to interlock with bulkfree's clearing of those bits.
 */
void
hammer2_io_dedup_set(hammer2_dev_t *hmp, hammer2_blockref_t *bref)
{
	hammer2_io_t *dio;
	uint64_t mask;
	int lsize;

	hammer2_mtx_ex(&hmp->iohash_lock);
	dio = hammer2_io_alloc(hmp, bref->data_off, bref->type, 1);
	KKASSERT(dio);
	hammer2_assert_io_refs(dio); /* dio locked + refs > 0 */
	hammer2_mtx_unlock(&hmp->iohash_lock);

	if ((int)(bref->data_off & HAMMER2_OFF_MASK_RADIX))
		lsize = 1 << (int)(bref->data_off & HAMMER2_OFF_MASK_RADIX);
	else
		lsize = 0;

	mask = hammer2_dedup_mask(dio, bref->data_off, lsize);
	dio->dedup_valid &= ~mask;
	dio->dedup_alloc |= mask;

	hammer2_mtx_unlock(&dio->lock);
	hammer2_io_putblk(&dio);
}

/*
 * Clear dedup validation bits in a DIO.  This is typically done when
 * a modified chain is destroyed or by the bulkfree code.  No buffer
 * is needed for this operation.  If the DIO no longer exists it is
 * equivalent to the bits not being set.
 */
void
hammer2_io_dedup_delete(hammer2_dev_t *hmp, uint8_t btype,
    hammer2_off_t data_off, unsigned int bytes)
{
	hammer2_io_t *dio;
	uint64_t mask;

	if ((data_off & ~HAMMER2_OFF_MASK_RADIX) == 0)
		return;
	if (btype != HAMMER2_BREF_TYPE_DATA)
		return;

	hammer2_mtx_ex(&hmp->iohash_lock);
	dio = hammer2_io_alloc(hmp, data_off, btype, 0);
	if (dio) {
		hammer2_assert_io_refs(dio); /* dio locked + refs > 0 */
		hammer2_mtx_unlock(&hmp->iohash_lock);

		if (data_off < (hammer2_off_t)dio->pbase ||
		    (data_off & ~HAMMER2_OFF_MASK_RADIX) +
		    (hammer2_off_t)bytes >
		    (hammer2_off_t)dio->pbase + dio->psize)
			hpanic("bad data_off %016llx/%d %016llx",
			    (long long)data_off, bytes, (long long)dio->pbase);

		mask = hammer2_dedup_mask(dio, data_off, bytes);
		dio->dedup_alloc &= ~mask;
		dio->dedup_valid &= ~mask;

		hammer2_mtx_unlock(&dio->lock);
		hammer2_io_putblk(&dio);
	} else {
		hammer2_mtx_unlock(&hmp->iohash_lock);
	}
}

/*
 * Assert that dedup allocation bits in a DIO are not set.  This operation
 * does not require a buffer.  The DIO does not need to exist.
 */
void
hammer2_io_dedup_assert(hammer2_dev_t *hmp, hammer2_off_t data_off,
    unsigned int bytes)
{
	hammer2_io_t *dio;

	hammer2_mtx_ex(&hmp->iohash_lock);
	dio = hammer2_io_alloc(hmp, data_off, HAMMER2_BREF_TYPE_DATA, 0);
	if (dio) {
		hammer2_assert_io_refs(dio); /* dio locked + refs > 0 */
		hammer2_mtx_unlock(&hmp->iohash_lock);

		KASSERTMSG((dio->dedup_alloc &
		    hammer2_dedup_mask(dio, data_off, bytes)) == 0,
		    "%016llx/%d %016llx/%016llx",
		    (long long)data_off, bytes,
		    (long long)hammer2_dedup_mask(dio, data_off, bytes),
		    (long long)dio->dedup_alloc);

		hammer2_mtx_unlock(&dio->lock);
		hammer2_io_putblk(&dio);
	} else {
		hammer2_mtx_unlock(&hmp->iohash_lock);
	}
}
