/*
 * Copyright (c) 2015-2018 The DragonFly Project.  All rights reserved.
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
/*
 * This module implements the cluster synchronizer.  Basically the way
 * it works is that a thread is created for each cluster node in a PFS.
 * This thread is responsible for synchronizing the current node using
 * data from other nodes.
 *
 * Any out of sync master or slave can get back into synchronization as
 * long as a quorum of masters agree on the update_tid.  If a quorum is
 * not available it may still be possible to synchronize to the highest
 * available update_tid as a way of trying to catch up as much as possible
 * until a quorum is available.
 *
 * If no quorum is possible (which can happen even if all masters are
 * available, if the update_tid does not match), then manual intervention
 * may be required to resolve discrepancies.
 */
#include "hammer2.h"

typedef struct hammer2_deferred_ip {
	struct hammer2_deferred_ip *next;
	hammer2_inode_t	*ip;
	int		scanned;	/* XXX Linux: see list->failed */
	/*
	 * XXX Linux: on a snapshot pass ip is an inode of the snapshot PFS,
	 * made from the snapshot's data as upstream makes the live one from a
	 * master's, and the slave is addressed apart from it: inum is the
	 * inode number both sides share and pin is the slave's inode chain as
	 * the scan saw it, referenced, so the recursion can tell that the
	 * chain it finds by number is the one that was deferred.
	 */
	hammer2_key_t	inum;
	hammer2_chain_t	*pin;
} hammer2_deferred_ip_t;

typedef struct hammer2_deferred_list {
	hammer2_deferred_ip_t	*base;
	int			count;
	/*
	 * XXX Linux: set when an action on any key of this pass returned
	 * non-zero, and read at every inode-root stamp.  The list is the one
	 * object every hammer2_sync_slaves() call of a pass shares, so a
	 * failure in a deferred child reaches its parent's stamp through it.
	 * Reset per pass.
	 */
	int			failed;
	/*
	 * XXX Linux: the keys this pass inserted, replaced or destroyed, read
	 * by the snapshot pass's verify rounds: a round that compares every
	 * inode the root holds and counts none has brought the slave to the
	 * snapshot.  Reset per pass.
	 */
	int			acted;
	/*
	 * XXX Linux: the keys this pass kept because the slave's copy was
	 * newer than the snapshot's, the frontend having written the slave
	 * element after the snapshot was taken.  A pass that kept one cannot
	 * verify against this snapshot and need not try again: the next
	 * snapshot holds what the slave holds.  Reset per pass.
	 */
	int			kept;
	/*
	 * XXX Linux: the entries this pass has scanned, kept until the
	 * pass-end flush with their slave inode chains referenced.  A
	 * mounted PFS's sync descends with FLUSH_INODE_STOP, skips each inode
	 * child it meets and leaves that inode's ONFLUSH set, but pre-clears
	 * ONFLUSH on the indirect blocks and root above it without re-flagging
	 * them (hammer2_flush_core), since upstream's dirty inodes each flush
	 * themselves from the inode down.  This thread's copies have no inode
	 * on the sync queue, so a sync landing mid-pass broke the path from
	 * the root to every subtree copied before it, and the pass-end flush
	 * from the root reached none of them: measured 2026-10-18, 22354
	 * modified chains left after the cluster unmount's sync, the flush
	 * complete in 15 ms with error 0, 22201 chains scrapped unflushed at
	 * the device teardown and the slave 16000 inodes short.  The path
	 * above each kept chain is re-flagged before the flush.
	 */
	hammer2_deferred_ip_t	*done;
} hammer2_deferred_list_t;


#define HAMMER2_SYNCHRO_DEBUG 1

static int hammer2_sync_slaves(hammer2_thread_t *thr, hammer2_inode_t *ip,
				hammer2_key_t inum, hammer2_chain_t *pin,
				hammer2_deferred_list_t *list, int isroot);
#if 0
static void hammer2_update_pfs_status(hammer2_thread_t *thr, uint32_t flags);
				nerror = hammer2_sync_insert(
						thr, &parent, &chain,
						focus->bref.modify_tid,
						idx, focus);
#endif
static int hammer2_sync_insert(hammer2_thread_t *thr,
			hammer2_chain_t **parentp, hammer2_chain_t **chainp,
			hammer2_tid_t modify_tid, int idx,
			hammer2_xop_head_t *xop, hammer2_chain_t *focus);
static int hammer2_sync_destroy(hammer2_thread_t *thr,
			hammer2_chain_t **parentp, hammer2_chain_t **chainp,
			hammer2_tid_t mtid, int idx);
static int hammer2_sync_replace(hammer2_thread_t *thr,
			hammer2_chain_t *parent, hammer2_chain_t *chain,
			hammer2_tid_t mtid, int idx,
			hammer2_xop_head_t *xop, hammer2_chain_t *focus,
			int isroot);

/*
 * XXX Linux: the thread's rescan set, the inodes whose last scan kept or
 * failed a key; see hammer2_thread.rescan.  The set is small and a pass
 * reads every inode key once, so the search is linear.  The thread is the
 * only writer and reader.
 */
static int
hammer2_sync_rescan_find(hammer2_thread_t *thr, hammer2_key_t inum)
{
	int i;

	for (i = 0; i < thr->nrescan; ++i) {
		if (thr->rescan[i] == inum)
			return (i);
	}
	return (-1);
}

/*
 * An entry noted by this pass is the next pass's to act on; see
 * hammer2_thread.rescan_noted.
 */
static int
hammer2_sync_rescan_wanted(hammer2_thread_t *thr, hammer2_key_t inum)
{
	int i;

	if (thr->rescan_now)
		return (1);
	i = hammer2_sync_rescan_find(thr, inum);
	return (i >= 0 && thr->rescan_noted[i] != thr->rescan_pass);
}

/*
 * A scan that kept or failed a key puts its inode on the set, or renews
 * its entry with this pass's number; a clean scan takes it off.  A full set
 * asks the next pass to compare every inode.
 */
static void
hammer2_sync_rescan_note(hammer2_thread_t *thr, hammer2_key_t inum, int nfail)
{
	int i;

	i = hammer2_sync_rescan_find(thr, inum);
	if (nfail) {
		if (i >= 0) {
			thr->rescan_noted[i] = thr->rescan_pass;
			return;
		}
		if (thr->nrescan < HAMMER2_SYNC_RESCAN_MAX) {
			thr->rescan_noted[thr->nrescan] = thr->rescan_pass;
			thr->rescan[thr->nrescan++] = inum;
		} else {
			thr->rescan_all = 1;
		}
	} else if (i >= 0) {
		--thr->nrescan;
		thr->rescan[i] = thr->rescan[thr->nrescan];
		thr->rescan_noted[i] = thr->rescan_noted[thr->nrescan];
	}
}

/*
 * XXX Linux: the slave side of a snapshot pass.  Upstream reads the slave's
 * inode chain out of the inode it scans, which holds every element of the
 * cluster; the inode a snapshot pass scans belongs to the snapshot PFS and
 * holds the snapshot's chain alone, so the slave's chain is found under
 * this element by inode number instead, and the PFS root's out of this
 * PFS's root inode.  A chain other than the one the scan deferred means
 * the frontend replaced the inode since, inode numbers being never reused
 * on a mount, and the key is left for the next pass, as is one that is
 * gone.  Both chains return locked shared, parent first, as
 * hammer2_inode_chain_and_parent() returns them, or both NULL.  The caller
 * holds no chain of the snapshot's tree across this; see the lock classes
 * in hammer2_os.h.
 */
static hammer2_chain_t *
hammer2_sync_slave_chain(hammer2_thread_t *thr, hammer2_key_t inum,
    hammer2_chain_t *pin, int isroot, hammer2_chain_t **parentp,
    hammer2_deferred_list_t *list)
{
	hammer2_pfs_t *pmp = thr->pmp;
	hammer2_chain_t *chain = NULL;
	int error;

	*parentp = NULL;
	if (isroot) {
		chain = hammer2_inode_chain_and_parent(pmp->iroot, thr->clindex,
		    parentp, HAMMER2_RESOLVE_ALWAYS | HAMMER2_RESOLVE_SHARED);
		return (chain);
	}
	error = hammer2_chain_inode_find(pmp, inum, thr->clindex,
	    HAMMER2_LOOKUP_SHARED | HAMMER2_LOOKUP_NODIRECT |
	    HAMMER2_LOOKUP_ALWAYS, parentp, &chain);
	if (chain && (error || (pin && chain != pin))) {
		if (pin && chain != pin) {
			kprintf("syncsnap: inum %016llx slave chain %p "
			    "is not the deferred %p\n",
			    (long long)inum, chain, pin);
		}
		hammer2_chain_unlock(chain);
		hammer2_chain_drop(chain);
		chain = NULL;
	}
	if (chain == NULL) {
		if (*parentp) {
			hammer2_chain_unlock(*parentp);
			hammer2_chain_drop(*parentp);
			*parentp = NULL;
		}
		list->failed = 1;
	}
	return (chain);
}

/*
 * XXX Linux: the fields hammer2_sync_replace() copies onto a PFS root, as
 * one list for the two other places that need the same set: the snapshot
 * the thread takes (hammer2_pfs_snapshot(), so the snapshot's root carries
 * the master's fields and not a new PFS's defaults, which a slave root was
 * being brought to) and the idle test of hammer2_sync_pass_snap().
 * pfs_lsnap_tid is not among them: the arm max-merges it and every snapshot
 * moves it.
 */
void
hammer2_sync_root_meta_copy(hammer2_inode_meta_t *dst,
    const hammer2_inode_meta_t *src)
{
	dst->uflags = src->uflags;
	dst->rmajor = src->rmajor;
	dst->rminor = src->rminor;
	dst->ctime = src->ctime;
	dst->mtime = src->mtime;
	dst->atime = src->atime;
	dst->uid = src->uid;
	dst->gid = src->gid;
	dst->mode = src->mode;
	dst->ncopies = src->ncopies;
	dst->comp_algo = src->comp_algo;
	dst->check_algo = src->check_algo;
	dst->data_quota = src->data_quota;
	dst->inode_quota = src->inode_quota;
}

/* XXX Linux: whether the fields above differ between two root metas. */
static int
hammer2_sync_root_meta_differs(const hammer2_inode_meta_t *a,
    const hammer2_inode_meta_t *b)
{
	hammer2_inode_meta_t t = *a;

	hammer2_sync_root_meta_copy(&t, b);
	return (bcmp(&t, a, sizeof(t)) != 0);
}

/* Release a deferral of either kind. */
static void
hammer2_sync_defer_free(hammer2_deferred_ip_t *defer)
{
	if (defer->ip)
		hammer2_inode_drop(defer->ip);
	if (defer->pin)
		hammer2_chain_drop(defer->pin);
	/* XXX Linux: kfree(defer, M_HAMMER2) */
	hfree(defer, M_HAMMER2, sizeof(*defer));
}

/*
 * XXX Linux: a deferral this pass is finished with moves to the done list
 * for the pass-end flush's re-flag, its inode dropped and its slave chain
 * kept referenced; see hammer2_deferred_list.done.
 */
static void
hammer2_sync_defer_done(hammer2_deferred_list_t *list,
    hammer2_deferred_ip_t *defer)
{
	if (defer->ip) {
		hammer2_inode_drop(defer->ip);
		defer->ip = NULL;
	}
	defer->next = list->done;
	list->done = defer;
}

static void hammer2_sync_setflush(hammer2_chain_t *);

/*
 * XXX Linux: re-flag the path from each kept slave inode chain to the volume
 * root and release the done list; run before the pass-end flush.  The chain
 * is locked so its parent pointer is stable for the walk, as the arms hold
 * theirs.
 */
static void
hammer2_sync_reflag(hammer2_deferred_list_t *list)
{
	hammer2_deferred_ip_t *defer;
	int n = 0;

	while ((defer = list->done) != NULL) {
		list->done = defer->next;
		if (defer->pin) {
			hammer2_chain_lock(defer->pin, HAMMER2_RESOLVE_NEVER);
			hammer2_sync_setflush(defer->pin);
			hammer2_chain_unlock(defer->pin);
			++n;
		}
		hammer2_sync_defer_free(defer);
	}
	if (n && (hammer2_debug & 0x8000))
		kprintf("sync_flush: reflagged %d inode path(s)\n", n);
}

/****************************************************************************
 *			    HAMMER2 SYNC THREADS 			    *
 ****************************************************************************/
static int h2dbg_setflush_walks;	/* XXX Linux */
static int h2dbg_setflush_inode_tail;	/* XXX Linux */

/*
 * XXX Linux: make a change the sync thread made visible to the flusher.
 * hammer2_chain_setflush() stops at the first inode chain, because a
 * frontend change reaches the flusher through its hammer2_inode, whose
 * flush bridges the inode chain to its parent; see
 * hammer2_xop_inode_flush().  This thread changes chains directly and
 * puts no inode on the sync queue, so nothing bridged them: the path from
 * the slave's PFS root down to its changes was never flagged, and the
 * final flush of an unmount, FLUSH_ALL included, never reached them and
 * the unmount scrapped them unwritten.  This flags the whole path to the
 * volume root, inode boundaries included.  The chain is held exclusively,
 * so its parent is stable, and the handoff up the path is
 * hammer2_chain_setflush()'s.
 *
 * A mounted PFS's own sync stops at inode boundaries whatever the flags,
 * so the slave's changes reach media when the PFS is no longer mounted or
 * its device is torn down.  A crash before then loses only work the next
 * pass redoes, the slave being compared with its masters by modify_tid.
 *
 * XXX Linux: idle-pass cost is not established by the old gate readings.
 * The gate below follows an unconditional re-mark of this same root, so it
 * cannot distinguish an idle pass from one with dirty descendants.  A
 * 2026-10-16 KASAN run saw root flags 00046102 before marking on idle
 * passes, then 00046302 and a flush decision; the active pass read
 * 000c6343 before marking.  This is a comparison from one debug-enabled
 * run, not a controlled cost measurement.  See the verification record.
 */
static int h2dbg_setflush_walks;	/* XXX Linux */
static int h2dbg_setflush_inode_tail;	/* XXX Linux */

static void
hammer2_sync_setflush(hammer2_chain_t *chain)
{
	hammer2_chain_t *parent;

	hammer2_spin_sh(&chain->core.spin);
	for (;;) {
		atomic_set_int(&chain->flags, HAMMER2_CHAIN_ONFLUSH);
		parent = chain->parent;
		/*
		 * XXX Linux: how far the walk got, and on which type it stopped.
		 * Measured 2026-10-13: the element root the flush helper tests
		 * reads `not flagged (00046102)` on every pass, so this walk is
		 * not reaching it.  The count says whether it stopped at the
		 * first inode -- which is what the carried
		 * hammer2_chain_setflush() does, and why this helper exists --
		 * or at a NULL parent, which is a different defect.
		 */
		if (parent == NULL) {
			/*
			 * XXX Linux: the volume chain is the walk's proper end
			 * and not a stop worth a line: printed for every copied
			 * chain it made 104272 lines in one run, a console
			 * flood that measured itself (2026-10-18).
			 */
			if ((hammer2_debug & 0x8000) &&
			    chain->bref.type != HAMMER2_BREF_TYPE_VOLUME)
				kprintf("sync_setflush: stopped at %016llx/%d type %d "
				    "(NULL parent)\n",
				    (long long)chain->bref.key, chain->bref.keybits,
				    chain->bref.type);
			break;
		}
		hammer2_spin_sh(&parent->core.spin);
		hammer2_spin_unsh(&chain->core.spin);
		chain = parent;
	}
	if (hammer2_debug & 0x8000) {
		atomic_add_int(&h2dbg_setflush_walks, 1);
		if (chain->bref.type == HAMMER2_BREF_TYPE_INODE &&
		    chain->parent != NULL)
			atomic_add_int(&h2dbg_setflush_inode_tail, 1);
	}
	hammer2_spin_unsh(&chain->core.spin);
}

/*
 * XXX Linux: write what a pass copied.  A mounted PFS's sync clears
 * ONFLUSH on its way down and stops at each child inode, leaving that
 * inode's subtree to the inode's own flush, and the chains this thread
 * changes have no inode on the sync queue to do it.  So the first sync
 * after a pass erased the path hammer2_sync_setflush() had flagged and
 * the copies stayed in memory until an unmount scrapped them.  The thread
 * flushes its own element instead, from the slave's PFS root down through
 * every inode, in a flush transaction taken in the order
 * hammer2_vfs_sync_pmp() takes it, and flags the root's parent so the next
 * flush of the device writes the volume header.
 *
 * The flush is unconditional.  The root's own flags cannot gate it: a
 * mounted PFS's sync clears the root's ONFLUSH on its way down, so a test
 * before the re-mark skipped the flush on the pass that needed it, and a
 * test after the re-mark reads the bit the walk just set.  Measured on the
 * kernel of record, an idle pass's flush takes 0.03 ms median, 0.05 ms p90,
 * from the root-before print to the completed one, against a 5.12 s pass
 * cadence; an earlier 0.94 ms reading priced two more prints inside that
 * window.  hammer2_vfs_sync_pmp() spends the same flush every sync interval
 * for the same reason.  DEFER(an idle pass's flush measured above a tenth of the cadence):
 * a per-pass count of actions and stamps, read here, proved to cover every
 * mutation the pass can make.
 */
static int
hammer2_sync_flush(hammer2_thread_t *thr)
{
	hammer2_pfs_t *pmp = thr->pmp;
	hammer2_chain_t *chain;
	int error = 0;

	hammer2_trans_init(pmp, HAMMER2_TRANS_ISFLUSH);
	hammer2_inode_lock(pmp->iroot, HAMMER2_RESOLVE_SHARED);
	chain = hammer2_inode_chain(pmp->iroot, thr->clindex,
	    HAMMER2_RESOLVE_ALWAYS);
	hammer2_inode_unlock(pmp->iroot);
	if (chain) {
		if (hammer2_debug & 0x8000)
			kprintf("sync_flush: clindex %d root-before %08x\n",
			    thr->clindex, chain->flags);
		hammer2_sync_setflush(chain);
		/*
		 * XXX Linux: the return value was DISCARDED, so a flush
		 * that wrote nothing was indistinguishable from one that
		 * wrote everything. That is the shape of the 2026-10-13
		 * loss: the thread copied 3873 inodes into the slave's
		 * element, flagged the path, ran this flush at the end of
		 * the pass, and the slave's media held 801 of them. With
		 * the error thrown away there was nothing to read.
		 *
		 * Read and report it. The caller prints it and does NOT
		 * retry the pass, so this alone turns a silent failure
		 * into a visible one rather than repairing it.
		 */
		error = hammer2_flush(chain, HAMMER2_FLUSH_TOP |
		    HAMMER2_FLUSH_ALL | HAMMER2_FLUSH_FSSYNC);
		if (hammer2_debug & 0x8000)
			kprintf("sync_flush: clindex %d completed flags %08x error %08x\n",
			    thr->clindex, chain->flags, error);
		if (error) {
			kprintf("sync_flush: clindex %d chain %p "
			    "flush error %08x\n",
			    thr->clindex, chain, error);
		}
		hammer2_chain_unlock(chain);
		hammer2_chain_drop(chain);
	} else if (hammer2_debug & 0x8000) {
		kprintf("sync_flush: clindex %d no element chain\n",
		    thr->clindex);
	}
	hammer2_trans_done(pmp, HAMMER2_TRANS_ISFLUSH);

	return (error);
}

/*
 * XXX Linux: one synchronization pass over this thread's element: the
 * root scan, the deferred directories drained bottom-up, the flush.  The
 * body is upstream's loop from hammer2_primary_sync_thread(), moved here
 * so the live pass and the snapshot pass share it; snap_pmp is NULL for
 * the live pass and the snapshot's PFS otherwise, in which case every
 * hammer2_sync_slaves() call reads from the snapshot's tree.
 */
static int
hammer2_sync_pass(hammer2_thread_t *thr, hammer2_pfs_t *snap_pmp,
    hammer2_deferred_list_t *list)
{
	hammer2_pfs_t *pmp = thr->pmp;
	hammer2_deferred_ip_t *defer;
	int error;
	int ferror;		/* XXX Linux: the write-back's own result */

	if (hammer2_debug & 0x8000)
		kprintf("sync_slaves pfs %s clindex %d\n",
			pmp->pfs_names[thr->clindex], thr->clindex);
	hammer2_trans_init(pmp, 0);

	hammer2_inode_ref(pmp->iroot);
	list->failed = 0;	/* XXX Linux */
	list->acted = 0;	/* XXX Linux */
	list->kept = 0;		/* XXX Linux */
	/*
	 * XXX Linux: a rescan set that overflowed asks this pass to compare
	 * every inode, and an entry this pass notes is the next one's; see
	 * hammer2_thread.rescan.
	 */
	++thr->rescan_pass;
	thr->rescan_now = thr->rescan_all;
	thr->rescan_all = 0;
	if (thr->rescan_now && (hammer2_debug & 0x8000))
		kprintf("syncthr: rescan all clindex %d\n", thr->clindex);

	for (;;) {
		int didbreak = 0;
		/* XXX lock synchronize pmp->modify_tid */
		error = hammer2_sync_slaves(thr,
		    snap_pmp ? snap_pmp->iroot : pmp->iroot, 0, NULL, list, 1);
		if (hammer2_debug & 0x8000) {
			kprintf("sync_slaves error %d defer %p\n",
				error, list->base);
		}
		if (error != HAMMER2_ERROR_EAGAIN)
			break;
		while ((defer = list->base) != NULL) {
			/*
			 * XXX Linux: in a failing pass a deferred directory's
			 * children stay unstamped, so its rescan would defer
			 * them again and keep it at the head of the list.
			 * Each entry is scanned once; see the pass-end break
			 * below for the root's half of the same loop.
			 */
			if (list->failed && defer->scanned) {
				--list->count;
				list->base = defer->next;
				hammer2_sync_defer_done(list, defer);
				continue;
			}
			defer->scanned = 1;
			error = hammer2_sync_slaves(thr, defer->ip,
			    defer->inum, defer->pin, list,
			    (defer->ip == pmp->iroot));
			if (error &&
			    error != HAMMER2_ERROR_EAGAIN &&
			    error != HAMMER2_ERROR_ENOENT) {
				break;
			}
			if (hammer2_thr_break(thr)) {
				didbreak = 1;
				break;
			}

			/*
			 * If no additional defers occurred we can
			 * remove this one, otherwise keep it on
			 * the list and retry once the additional
			 * defers have completed.
			 */
			if (defer == list->base) {
				--list->count;
				list->base = defer->next;
				hammer2_sync_defer_done(list, defer);
				defer = NULL;	/* safety */
			}
		}

		/*
		 * If the thread is being remastered, frozen, or
		 * stopped, clean up any left-over deferals.
		 */
		if (didbreak ||
		    (error && error != HAMMER2_ERROR_EAGAIN)) {
			kprintf("didbreak\n");
			while ((defer = list->base) != NULL) {
				--list->count;
				list->base = defer->next;
				hammer2_sync_defer_done(list, defer);
			}
			if (error == 0 || error == HAMMER2_ERROR_EAGAIN)
				error = HAMMER2_ERROR_EINPROGRESS;
			break;
		}

		/*
		 * XXX Linux: a failed key withheld every stamp of this
		 * pass, so a root rescan finds the deferred directories
		 * still differing and defers them again: measured as 4492
		 * rescans in 760 s before the thread blocked
		 * (cluster-hang-20261016-074222).  The deferrals were
		 * drained once above; the pass ends here and the next one
		 * retries the key, which is what the withheld stamp is for.
		 */
		if (list->failed) {
			error = 0;
			break;
		}
	}

	hammer2_inode_drop(pmp->iroot);
	hammer2_trans_done(pmp, 0);
	/*
	 * XXX Linux: the write-back's own error was discarded, so a pass
	 * whose copies never reached media looked exactly like one that
	 * wrote them. Read it: the flush is what carries what the scan
	 * copied, and a failure here means the scan's stamps were set
	 * against a slave that did not receive them. Reported through the
	 * same path as a scan error, which the loop above treats as a
	 * pass to retry rather than one that succeeded.
	 */
	hammer2_sync_reflag(list);	/* XXX Linux: see hammer2_deferred_list.done */
	ferror = hammer2_sync_flush(thr);
	if (ferror && error == 0)
		error = ferror;

	return (error);
}

/*
 * XXX Linux: a pass that reads a snapshot of the master element rather
 * than the live master.  The source element is the one the root's quorum
 * focus names; without one the live pass runs, which finds the same and
 * copies nothing.  The snapshot is a PFS of its own under the super-root of
 * that element's device, named for this element with a suffix, taken by
 * the ioctl's own code with the PFS flush in place of hammer2_sync(), and
 * deleted after the pass's flush.  One left by a crash is deleted before
 * the new one is taken.  hammer2_mntlk is tried, never waited for: an
 * unmount holds it while it waits for this thread to stop.  The scan reads
 * the snapshot through its PFS root inode and, for each directory it
 * defers, an inode of the snapshot PFS made from the scan's cluster, so the
 * source side is upstream's ipcluster and scanall XOPs unchanged and only
 * the slave side is found differently.  See doc/SYNC_DESIGN.md.
 *
 * The pass is skipped while the master has not changed since the last
 * verified one: the master root's flushed blockset and the root fields the
 * PFSROOT arm copies are compared with the snapshot's that verified
 * (hammer2_thread.last_blockset).  An idle master whose root tid still
 * differs from the slave root's, which is every master once after a
 * snapshot, since the snapshot writes its root, gets the live pass once:
 * its root scan is one level, inode by inode and by tid, and its PFSROOT
 * arm copies the live root's fields and stamps the slave root with the live
 * tid, which is the condition under which hammer2_cluster_check() serves
 * the slave.
 *
 * A pass that acted is run again against the same snapshot, the root pushed
 * onto the rescan set so the tid gate cannot pass it, until a round acts on
 * nothing or HAMMER2_SYNC_VERIFY_ROUNDS have run; a pass whose last round
 * acted on nothing and failed nothing is verified.  Before the first pass
 * after a verified one the slave element is snapshotted too,
 * <name>.h2sync-tgt on its own device, deleted when a pass verifies and
 * kept across a failed or interrupted pass, a crash and an unmount: the
 * last known-good slave, by the primitives the port has.
 * DEFER(a consumer that reads a slave element directly, a static mount or a standalone slave mount):
 * the design note's fork-and-swap of a live target is not built.  No tree
 * swaps a cluster element's root under a live mount, and nothing in this
 * port reads a slave element's mixed state: the cluster mount serves reads
 * from the master and a lone SLAVE label is refused at mount, so the slave
 * is written in place and this snapshot is what a failed pass leaves intact.
 */
#define HAMMER2_SYNC_VERIFY_ROUNDS	3

static int
hammer2_sync_pass_snap(hammer2_thread_t *thr, hammer2_deferred_list_t *list)
{
	hammer2_pfs_t *pmp = thr->pmp;
	hammer2_pfs_t *snap_pmp = NULL;
	hammer2_xop_ipcluster_t *xop2;
	hammer2_chain_t *focus;
	hammer2_chain_t *chain;
	hammer2_inode_meta_t mmeta;	/* the master root's, as flushed */
	hammer2_tid_t root_tid = 0;
	hammer2_tid_t mtid = 0;		/* the master root chain's tid */
	hammer2_tid_t stid = 0;		/* the slave root chain's tid */
	char name[HAMMER2_INODE_MAXNAME];
	char tname[HAMMER2_INODE_MAXNAME];
	int idx, m, n, error, derror, round, verified, idle;

	idx = thr->clindex;

	/*
	 * Elect the source element, and read its root's tid and meta for the
	 * idle test below.
	 */
	hammer2_inode_lock(pmp->iroot, HAMMER2_RESOLVE_SHARED);
	xop2 = hammer2_xop_alloc(pmp->iroot, HAMMER2_XOP_MODIFYING);
	hammer2_xop_start_except(&xop2->head, &hammer2_ipcluster_desc, idx);
	hammer2_inode_unlock(pmp->iroot);
	error = hammer2_xop_collect(&xop2->head, 0);
	m = -1;
	bzero(&mmeta, sizeof(mmeta));
	if (error == 0 && (focus = xop2->head.cluster.focus) != NULL) {
		for (n = 0; n < xop2->head.cluster.nchains; ++n) {
			if (xop2->head.cluster.array[n].chain == focus) {
				m = n;
				break;
			}
		}
		mtid = focus->bref.modify_tid;
		mmeta = hammer2_xop_gdata(&xop2->head)->ipdata.meta;
		hammer2_xop_pdata(&xop2->head);
	}
	hammer2_xop_retire(&xop2->head, HAMMER2_XOPMASK_VOP);
	if (m < 0 || m == idx || pmp->pfs_hmps[m] == NULL ||
	    hammer2_dev_is_conn(pmp->pfs_hmps[m]) ||	/* XXX Linux */
	    pmp->pfs_names[idx] == NULL) {
		/*
		 * No source to snapshot: no quorum, or the focus is this
		 * element itself, a master with no other master to read.  The
		 * live pass runs then, as it did before this one existed: its
		 * own collect finds the same and copies nothing, and the pass
		 * is counted where the harness counts passes.
		 *
		 * XXX Linux: nor a remote master, whose device is a
		 * connection on which a snapshot cannot be created; the
		 * master takes it on its own device once the protocol has
		 * the command (doc/CLUSTER_PROTOCOL_DESIGN.md, the client
		 * side), and until then the pass over the wire is live.
		 */
		if (hammer2_debug & 0x8000)
			kprintf("syncsnap: noquorum clindex %d error %d\n",
			    idx, error);
		return (hammer2_sync_pass(thr, NULL, list));
	}

	n = snprintf(name, sizeof(name), "%s.h2sync-src",
	    pmp->pfs_names[idx]);
	if (n < 0 || n >= (int)sizeof(name)) {
		kprintf("syncsnap: name too long for %s, live pass\n",
		    pmp->pfs_names[idx]);
		return (hammer2_sync_pass(thr, NULL, list));
	}
	snprintf(tname, sizeof(tname), "%s.h2sync-tgt", pmp->pfs_names[idx]);

	/*
	 * The idle test.  The blockset is read as the flush left it, so a
	 * change still dirty in memory is seen one flush later, which the
	 * snapshot's own flush then carries; the live pass compared in-memory
	 * chains and saw it at once.
	 */
	hammer2_spin_sh(&pmp->blockset_spin);
	idle = (bcmp(&pmp->pfs_iroot_blocksets[m], &thr->last_blockset,
	    sizeof(thr->last_blockset)) == 0);
	hammer2_spin_unsh(&pmp->blockset_spin);
	if (idle && hammer2_sync_root_meta_differs(&mmeta, &thr->last_meta))
		idle = 0;
	if (idle) {
		hammer2_inode_lock(pmp->iroot, HAMMER2_RESOLVE_SHARED);
		chain = hammer2_inode_chain(pmp->iroot, idx,
		    HAMMER2_RESOLVE_NEVER);
		hammer2_inode_unlock(pmp->iroot);
		if (chain) {
			stid = chain->bref.modify_tid;
			hammer2_chain_unlock(chain);
			hammer2_chain_drop(chain);
		}
		if (hammer2_debug & 0x8000)
			kprintf("syncsnap: idle clindex %d master %016llx "
			    "slave %016llx\n",
			    idx, (long long)mtid, (long long)stid);
		if (chain == NULL || stid == mtid)
			return (0);
		/*
		 * The idle stamp is the live pass: with the master idle its
		 * root scan finds every inode's tid equal and acts on none,
		 * and its PFSROOT arm copies the live root's fields and
		 * stamps the slave root with the live tid.  How many of these
		 * a quiet master costs is the `idlestamp` count.
		 */
		if (hammer2_debug & 0x8000)
			kprintf("syncsnap: idlestamp clindex %d tid %016llx\n",
			    idx, (long long)mtid);
		return (hammer2_sync_pass(thr, NULL, list));
	}

	/*
	 * A snapshot a crash left behind.
	 */
	error = hammer2_pfs_delete_byname(pmp->pfs_hmps[m], name,
	    HAMMER2_PFSDEL_TRYLOCK);
	if (error == 0) {
		if (hammer2_debug & 0x8000)
			kprintf("syncsnap: stale %s deleted\n", name);
	} else if (error != ENOENT) {
		if (hammer2_debug & 0x8000)
			kprintf("syncsnap: stale %s error %d\n", name, error);
		return (0);
	}

	if (!hammer2_lk_tryex(&hammer2_mntlk)) {
		if (hammer2_debug & 0x8000)
			kprintf("syncsnap: busy clindex %d\n", idx);
		return (0);
	}
	error = hammer2_pfs_snapshot(pmp, m, name, HAMMER2_PFSSNAP_PMPSYNC,
	    &root_tid, &snap_pmp);
	if (error || snap_pmp == NULL) {
		hammer2_lk_unlock(&hammer2_mntlk);
		kprintf("syncsnap: snapshot %s error %d\n", name, error);
		return (0);
	}
	/*
	 * A target whose delete a verified pass could not finish, the lock
	 * being held by something other than an unmount (a bulkfree scan
	 * holds it for its whole run): deleted now, so the pass below takes a
	 * fresh one and a later unverified pass is not left with a stale
	 * target marked for the unmount to delete.
	 */
	if (thr->tgt_left) {
		derror = hammer2_pfs_delete_byname(pmp->pfs_hmps[idx], tname,
		    HAMMER2_PFSDEL_LOCKED);
		if (derror == 0 || derror == ENOENT)
			thr->tgt_valid = 0;
		thr->tgt_left = 0;
	}
	if (thr->tgt_valid == 0) {
		/*
		 * The slave as it is before this pass writes it.  One a crash
		 * or an unmount left is the same thing, the slave before the
		 * last pass that did not verify, and is kept; it is found by
		 * name, since the snapshot's create would make a second PFS of
		 * the name beside it (hammer2_pfs_find_byname()).  Without a
		 * target the pass does not run: a pass that failed halfway
		 * would otherwise be snapshotted by the next as the last
		 * known-good slave.
		 */
		if (hammer2_pfs_find_byname(pmp->pfs_hmps[idx], tname, NULL)) {
			derror = EEXIST;
		} else {
			derror = hammer2_pfs_snapshot(pmp, idx, tname,
			    HAMMER2_PFSSNAP_PMPSYNC, NULL, NULL);
		}
		if (derror == 0 || derror == EEXIST) {
			thr->tgt_valid = 1;
			if (hammer2_debug & 0x8000)
				kprintf("syncsnap: target %s %s\n", tname,
				    derror ? "kept" : "taken");
			/*
			 * The snapshot's own flush stops at its inode and
			 * leaves the volume header to the next sync of a
			 * mounted PFS, so a cut before that sync finds no
			 * target by name on the slave's media, only the
			 * blocks of one; the source snapshot survives the
			 * same cut because the target's sync wrote the
			 * master's header after it.  A target is the last
			 * known-good slave only if it is on the media before
			 * the pass's first write, so the header is written
			 * here by the sync the snapshot itself ran.
			 */
			if (derror == 0)
				hammer2_vfs_sync_pmp(pmp, MNT_WAIT);
		} else {
			if (hammer2_debug & 0x8000)
				kprintf("syncsnap: target %s error %d\n",
				    tname, derror);
			derror = hammer2_pfs_delete_byname(pmp->pfs_hmps[m],
			    name, HAMMER2_PFSDEL_LOCKED);
			if (derror && (hammer2_debug & 0x8000))
				kprintf("syncsnap: delete %s error %d\n",
				    name, derror);
			hammer2_lk_unlock(&hammer2_mntlk);
			return (0);
		}
	}
	hammer2_lk_unlock(&hammer2_mntlk);
	if (hammer2_debug & 0x8000)
		kprintf("syncsnap: pass clindex %d src %d tid %016llx\n",
		    idx, m, (long long)root_tid);

	/*
	 * The pass, and the rounds that verify it against the same snapshot.
	 * A round that acts on nothing ends them whether or not it failed,
	 * and so does one that kept a key as newer than the snapshot: the
	 * frontend wrote the slave element after the snapshot was taken, and
	 * what it wrote is the next snapshot's to settle, not this one's.
	 * Measured 2026-10-18: the first pass after a slave's return, whose
	 * cut is 0 so every stale tail is kept, acted 29 then 5 then 5 over
	 * three rounds against one snapshot, and the next snapshot settled
	 * the 5 in one.  The cut stays the previous snapshot's for every
	 * round.
	 */
	for (round = 1;; ++round) {
		/*
		 * Every round scans the root whatever its tid, see
		 * hammer2_thread.rescan: a round is a compare of the root
		 * level and never a skip at the tid gate, which the snapshot
		 * root's tid, counted on its device's super-root, could pass
		 * against the slave root's by coincidence.
		 */
		hammer2_sync_rescan_note(thr, snap_pmp->iroot->meta.inum, 1);
		error = hammer2_sync_pass(thr, snap_pmp, list);
		if (hammer2_debug & 0x8000)
			kprintf("syncsnap: verify clindex %d round %d acted %d "
			    "failed %d kept %d error %d\n",
			    idx, round, list->acted, list->failed, list->kept,
			    error);
		if (error || list->acted == 0 || list->kept ||
		    round >= HAMMER2_SYNC_VERIFY_ROUNDS)
			break;
	}
	verified = (error == 0 && list->acted == 0 && list->failed == 0);
	thr->snap_cut = root_tid;	/* the next pass's cut, see hammer2.h */

	if (verified) {
		/*
		 * What the snapshot held is what the slave holds; the next
		 * idle test reads against it.  The snapshot PFS was registered
		 * from its root's data by hammer2_pfsalloc(), and nothing else
		 * holds it.
		 */
		hammer2_spin_sh(&snap_pmp->blockset_spin);
		thr->last_blockset = snap_pmp->pfs_iroot_blocksets[0];
		hammer2_spin_unsh(&snap_pmp->blockset_spin);
		hammer2_inode_lock(snap_pmp->iroot, HAMMER2_RESOLVE_SHARED);
		thr->last_meta = snap_pmp->iroot->meta;
		hammer2_inode_unlock(snap_pmp->iroot);
		if (hammer2_debug & 0x8000)
			kprintf("syncsnap: verified clindex %d rounds %d\n",
			    idx, round);
		if (thr->tgt_valid) {
			derror = hammer2_pfs_delete_byname(pmp->pfs_hmps[idx],
			    tname, HAMMER2_PFSDEL_TRYLOCK);
			if (derror == 0 || derror == ENOENT) {
				thr->tgt_valid = 0;
				thr->tgt_left = 0;
			} else {
				thr->tgt_left = 1;
				if (hammer2_debug & 0x8000)
					kprintf("syncsnap: delete %s error %d\n",
					    tname, derror);
			}
		}
	} else if (error == 0 && list->kept) {
		/*
		 * The slave is ahead of the snapshot; nothing failed.  Not a
		 * pass that ran out of rounds, and read apart from one.  The
		 * target stands, and no unmount deletes it.
		 */
		thr->tgt_left = 0;
		if (hammer2_debug & 0x8000)
			kprintf("syncsnap: newer clindex %d rounds %d kept %d "
			    "acted %d\n",
			    idx, round, list->kept, list->acted);
	} else if (error == HAMMER2_ERROR_EINPROGRESS) {
		/*
		 * The thread was asked to stop mid-pass (an unmount of its
		 * device, a remaster); the target stands and the next thread
		 * finds it.  Read apart from a pass that ran out of rounds.
		 */
		thr->tgt_left = 0;
		if (hammer2_debug & 0x8000)
			kprintf("syncsnap: interrupted clindex %d rounds %d "
			    "acted %d\n", idx, round, list->acted);
	} else {
		thr->tgt_left = 0;	/* the target stands */
		kprintf("syncsnap: unverified clindex %d rounds %d acted %d "
		    "failed %d error %d\n",
		    idx, round, list->acted, list->failed, error);
	}

	/*
	 * Every chain of the snapshot was dropped with the scan and the
	 * pass's flush has run; the snapshot can go.  One the lock refuses
	 * is the next pass's stale one.
	 */
	derror = hammer2_pfs_delete_byname(pmp->pfs_hmps[m], name,
	    HAMMER2_PFSDEL_TRYLOCK);
	if (derror && (hammer2_debug & 0x8000))
		kprintf("syncsnap: delete %s error %d\n", name, derror);
	/*
	 * A refused delete is recorded for hammer2_sync_snap_cleanup(): the
	 * lock that refused it is an unmount's, and the unmount deletes the
	 * snapshot under that lock once this thread is frozen.  Measured
	 * 2026-10-18: the final unmount of a run left `CL.h2sync-src` on the
	 * master's media, 40039 inodes counted twice.
	 */
	thr->snap_left = derror ? m + 1 : 0;

	return (error);
}

/*
 * XXX Linux: delete the snapshots a frozen thread's last pass left behind
 * for want of the lock, see hammer2_sync_pass_snap(): the source snapshot,
 * and the target snapshot only when the pass had verified, since an
 * unverified pass keeps it on purpose.  Called by hammer2_pfsfree_scan()
 * under hammer2_mntlk, with the thread frozen and the element names
 * intact.  Returns 1 when a PFS was removed from hammer2_pfslist, so the
 * caller can restart its walk of that list.
 */
static int
hammer2_sync_snap_cleanup_one(hammer2_thread_t *thr, int m,
    const char *suffix)
{
	hammer2_pfs_t *pmp = thr->pmp;
	char name[HAMMER2_INODE_MAXNAME];
	int n, error;

	if (pmp->pfs_hmps[m] == NULL)
		return (0);
	n = snprintf(name, sizeof(name), "%s%s", pmp->pfs_names[thr->clindex],
	    suffix);
	if (n < 0 || n >= (int)sizeof(name))
		return (0);
	error = hammer2_pfs_delete_byname(pmp->pfs_hmps[m], name,
	    HAMMER2_PFSDEL_LOCKED);
	if (hammer2_debug & 0x8000)
		kprintf("syncsnap: unmount deleted %s error %d\n", name, error);
	return (error == 0);
}

int
hammer2_sync_snap_cleanup(hammer2_thread_t *thr)
{
	hammer2_pfs_t *pmp = thr->pmp;
	int freed = 0;

	if (pmp == NULL || pmp->pfs_names[thr->clindex] == NULL)
		return (0);
	if (thr->snap_left) {
		freed |= hammer2_sync_snap_cleanup_one(thr, thr->snap_left - 1,
		    ".h2sync-src");
		thr->snap_left = 0;
	}
	if (thr->tgt_left) {
		if (hammer2_sync_snap_cleanup_one(thr, thr->clindex,
		    ".h2sync-tgt")) {
			freed = 1;
			thr->tgt_valid = 0;
		}
		thr->tgt_left = 0;
	}
	return (freed);
}

/*
 * Primary management thread for an element of a node.  A thread will exist
 * for each element requiring management.
 *
 * No management threads are needed for the SPMP or for any PMP with only
 * a single MASTER.
 *
 * On the SPMP - handles bulkfree and dedup operations
 * On a PFS    - handles remastering and synchronization
 */
void
hammer2_primary_sync_thread(void *arg)
{
	hammer2_thread_t *thr = arg;
	hammer2_deferred_list_t list;
	int error;
	uint32_t flags;
	uint32_t nflags;

	bzero(&list, sizeof(list));
	/*
	 * XXX Linux: a recreated thread's are stale.  hammer2_thr_create()
	 * does not zero the structure, and an element that left and rejoined
	 * is compared with its master once before the idle test is trusted;
	 * a target snapshot it left on media is found by name.
	 */
	thr->snap_cut = 0;
	bzero(&thr->last_blockset, sizeof(thr->last_blockset));
	bzero(&thr->last_meta, sizeof(thr->last_meta));
	thr->tgt_valid = 0;
	thr->tgt_left = 0;

	for (;;) {
		flags = thr->flags;
		cpu_ccfence();

		/*
		 * Handle stop request
		 */
		if (flags & HAMMER2_THREAD_STOP)
			break;

		/*
		 * Handle freeze request
		 */
		if (flags & HAMMER2_THREAD_FREEZE) {
			nflags = (flags & ~(HAMMER2_THREAD_FREEZE |
					    HAMMER2_THREAD_WAITING)) |
				 HAMMER2_THREAD_FROZEN;
			if (!atomic_cmpset_int(&thr->flags, flags, nflags))
				continue;
			if (flags & HAMMER2_THREAD_WAITING)
				wakeup(&thr->flags);
			continue;
		}

		if (flags & HAMMER2_THREAD_UNFREEZE) {
			nflags = flags & ~(HAMMER2_THREAD_UNFREEZE |
					   HAMMER2_THREAD_FROZEN |
					   HAMMER2_THREAD_WAITING);
			if (!atomic_cmpset_int(&thr->flags, flags, nflags))
				continue;
			if (flags & HAMMER2_THREAD_WAITING)
				wakeup(&thr->flags);
			continue;
		}

		/*
		 * Force idle if frozen until unfrozen or stopped.
		 */
		if (flags & HAMMER2_THREAD_FROZEN) {
			nflags = flags | HAMMER2_THREAD_WAITING;

			/* XXX Linux: tsleep_interlock() and PINTERLOCKED */
			if (atomic_cmpset_int(&thr->flags, flags, nflags))
				tsleep_word(&thr->flags, nflags, 0, "frozen", 0);
			continue;
		}

		/*
		 * Reset state on REMASTER request
		 */
		if (thr->flags & HAMMER2_THREAD_REMASTER) {
			nflags = flags & ~HAMMER2_THREAD_REMASTER;
			if (atomic_cmpset_int(&thr->flags, flags, nflags)) {
				/* reset state here */
			}
			continue;
		}

		/*
		 * Synchronization scan.
		 *
		 * XXX Linux: one pass, live or from a snapshot of the master
		 * element; the pass body is hammer2_sync_pass() below.
		 */
		/*
		 * XXX Linux: the pass writes its element through chain calls
		 * and its own flush, which nothing refuses on a device opened
		 * read-only, a CL mounted with no read-write PFS beside it,
		 * and the block layer does not consult the open mode, so the
		 * pass would write a volume whose mount-time recovery never
		 * ran.  It refuses, and says so on every poll.
		 */
		if (thr->pmp->pfs_hmps[thr->clindex] &&
		    thr->pmp->pfs_hmps[thr->clindex]->rdonly) {
			pr_warn_ratelimited("hammer2: sync pass refused on clindex %d: device opened read-only\n",
			    thr->clindex);
			error = 0;
		} else if (hammer2_sync_snapshot)
			error = hammer2_sync_pass_snap(thr, &list);
		else
			error = hammer2_sync_pass(thr, NULL, &list);

		if (error && error != HAMMER2_ERROR_EINPROGRESS)
			kprintf("hammer2_sync_slaves: error %d\n", error);

		/*
		 * Wait for event, or 5-second poll.
		 */
		nflags = flags | HAMMER2_THREAD_WAITING;
		/* XXX Linux: tsleep_interlock(), see hammer2_os.h */
		if (atomic_cmpset_int(&thr->flags, flags, nflags)) {
			tsleep_word(&thr->flags, nflags, 0, "h2idle", hz * 5);
		}
	}
	thr->td = NULL;
	hammer2_thr_signal(thr, HAMMER2_THREAD_STOPPED);
	/* thr structure can go invalid after this point */
}

#if 0
/*
 * Given a locked cluster created from pmp->iroot, update the PFS's
 * reporting status.
 */
static
void
hammer2_update_pfs_status(hammer2_thread_t *thr, uint32_t flags)
{
	hammer2_pfs_t *pmp = thr->pmp;

	flags &= HAMMER2_CLUSTER_ZFLAGS;
	if (pmp->cluster_flags == flags)
		return;
	pmp->cluster_flags = flags;

	kprintf("pfs %p", pmp);
	if (flags & HAMMER2_CLUSTER_MSYNCED)
		kprintf(" masters-all-good");
	if (flags & HAMMER2_CLUSTER_SSYNCED)
		kprintf(" slaves-all-good");

	if (flags & HAMMER2_CLUSTER_WRHARD)
		kprintf(" quorum/rw");
	else if (flags & HAMMER2_CLUSTER_RDHARD)
		kprintf(" quorum/ro");

	if (flags & HAMMER2_CLUSTER_UNHARD)
		kprintf(" out-of-sync-masters");
	else if (flags & HAMMER2_CLUSTER_NOHARD)
		kprintf(" no-masters-visible");

	if (flags & HAMMER2_CLUSTER_WRSOFT)
		kprintf(" soft/rw");
	else if (flags & HAMMER2_CLUSTER_RDSOFT)
		kprintf(" soft/ro");

	if (flags & HAMMER2_CLUSTER_UNSOFT)
		kprintf(" out-of-sync-slaves");
	else if (flags & HAMMER2_CLUSTER_NOSOFT)
		kprintf(" no-slaves-visible");
	kprintf("\n");
}
#endif

#if 0
static
void
dumpcluster(const char *label,
	    hammer2_cluster_t *cparent, hammer2_cluster_t *cluster)
{
	hammer2_chain_t *chain;
	int i;

	if ((hammer2_debug & 1) == 0)
		return;

	kprintf("%s\t", label);
	KKASSERT(cparent->nchains == cluster->nchains);
	for (i = 0; i < cparent->nchains; ++i) {
		if (i)
			kprintf("\t");
		kprintf("%d ", i);
		if ((chain = cparent->array[i].chain) != NULL) {
			kprintf("%016jx%s ",
				chain->bref.key,
				((cparent->array[i].flags &
				  HAMMER2_CITEM_INVALID) ? "(I)" : "   ")
			);
		} else {
			kprintf("      NULL      %s ", "   ");
		}
		if ((chain = cluster->array[i].chain) != NULL) {
			kprintf("%016jx%s ",
				chain->bref.key,
				((cluster->array[i].flags &
				  HAMMER2_CITEM_INVALID) ? "(I)" : "   ")
			);
		} else {
			kprintf("      NULL      %s ", "   ");
		}
		kprintf("\n");
	}
}
#endif

/*
 * Each out of sync node sync-thread must issue an all-nodes XOP scan of
 * the inode.  This creates a multiplication effect since the XOP scan itself
 * issues to all nodes.  However, this is the only way we can safely
 * synchronize nodes which might have disparate I/O bandwidths and the only
 * way we can safely deal with stalled nodes.
 *
 * XXX serror / merror rollup and handling.
 */
static int h2dbg_file_nlt;	/* XXX Linux */
static int h2dbg_file_neq;	/* XXX Linux */
static int h2dbg_file_ngt;	/* XXX Linux */
/*
 * XXX Linux: how many copies the action switch below attempted and how many
 * returned non-zero.  The value of nerror is discarded (see the comment at
 * the discard), so a copy that fails leaves no trace and the pass still
 * stamps the element root's modify_tid, after which every later pass reads
 * want_update == 0 and does not retry.  These separate the two candidates
 * for the interrupted pass's shortfall: a copy that failed and was masked,
 * or a pass that never reached the missing inodes.  Debug reads them from
 * the same print as the file-key counters; not in any shipped path.
 */
static int h2dbg_act_tried;	/* XXX Linux */
static int h2dbg_act_failed;	/* XXX Linux */
static int h2dbg_act_last;	/* XXX Linux: the most recent non-zero nerror */
static int h2dbg_act_replace;	/* XXX Linux: the two arms a first pass never takes */
static int h2dbg_act_destroy;	/* XXX Linux */
static int h2dbg_rescan;	/* XXX Linux: scans the rescan set asked for */
static int h2dbg_newer_kept;	/* XXX Linux: n < 0 with the chain newer, kept */

/*
 * XXX Linux: ip is the inode scanned, this PFS's on the live path and the
 * snapshot PFS's on a snapshot pass, and the source is read through its
 * cluster's XOPs either way.  On a snapshot pass the slave is no element of
 * that inode and is found by inode number and the pinned slave chain
 * (NULL for the root); see hammer2_sync_slave_chain() above and
 * doc/SYNC_DESIGN.md.  The compare loop and the three arms are the same
 * code on both.
 */
static
int
hammer2_sync_slaves(hammer2_thread_t *thr, hammer2_inode_t *ip,
		    hammer2_key_t inum, hammer2_chain_t *pin,
		    hammer2_deferred_list_t *list, int isroot)
{
	hammer2_xop_scanall_t *xop;
	hammer2_chain_t *parent;
	hammer2_chain_t *chain;
	hammer2_pfs_t *pmp;
	hammer2_key_t key_next;
	hammer2_tid_t sync_tid;
	hammer2_tid_t slave_tid;	/* XXX Linux: this element's inode chain tid */
	int needrescan;
	int want_update;
	int serror;		/* slave error */
	int merror;		/* master error (from xop_collect) */
	int nerror;		/* temporary error */
	int idx;
	int n;
	int snap;		/* XXX Linux: ip is the snapshot's, see below */
	int iters;		/* XXX Linux: loop turns, per pass */
	int exit_reason;	/* XXX Linux: which break left the loop */
	int swept;		/* XXX Linux: sweep destroys this pass */
	int nfail;		/* XXX Linux: this call's kept or failed keys */
	hammer2_key_t rinum;	/* XXX Linux: the inode's number on both sides */

	pmp = thr->pmp;
	/*
	 * XXX Linux: on a snapshot pass the inode scanned belongs to the
	 * snapshot PFS, so the two XOPs below read the snapshot's tree through
	 * the same code that reads the live masters', and the slave, which is
	 * no element of that inode, is addressed by inode number instead; see
	 * hammer2_sync_pass_snap() and hammer2_sync_slave_chain().  The live
	 * path is unchanged: ip is this PFS's inode and holds every element.
	 */
	snap = (ip->pmp != pmp);
	idx = thr->clindex;	/* cluster node we are responsible for */
	needrescan = 0;
	want_update = 0;
	sync_tid = 0;
	slave_tid = 0;		/* XXX Linux */
	chain = NULL;
	parent = NULL;
	nfail = 0;		/* XXX Linux */
	rinum = ip->meta.inum;	/* XXX Linux: the snapshot's inode has the master's */

#if 0
	/*
	 * Nothing to do if all slaves are synchronized.
	 * Nothing to do if cluster not authoritatively readable.
	 */
	if (pmp->cluster_flags & HAMMER2_CLUSTER_SSYNCED)
		return(0);
	if ((pmp->cluster_flags & HAMMER2_CLUSTER_RDHARD) == 0)
		return(HAMMER2_ERROR_INCOMPLETE);
#endif

	merror = 0;

	/*
	 * XXX Linux: the failing run's passes each take one action and return,
	 * and nothing records why.  iters counts the loop's turns and
	 * exit_reason names the break that left it: 1 and 2 are the loop-head
	 * ends (both scans done, or the XOP errored), 3 is the deferral
	 * threshold.  Printed with the file-key counters once per pass.
	 */
	iters = 0;
	exit_reason = 0;
	swept = 0;
	/*
	 * Resolve the root inode of the PFS and determine if synchronization
	 * is needed by checking modify_tid.
	 *
	 * Retain the synchronization TID from the focus inode and use it
	 * later to synchronize the focus inode if/when the recursion
	 * succeeds.
	 */
	{
		hammer2_xop_ipcluster_t *xop2;
		hammer2_chain_t *focus;

		hammer2_inode_lock(ip, HAMMER2_RESOLVE_SHARED);
		xop2 = hammer2_xop_alloc(ip, HAMMER2_XOP_MODIFYING);
		/*
		 * XXX Linux: on a snapshot pass the inode's cluster is the
		 * snapshot's one element, and this element's index names
		 * nothing in it; excluding that index would exclude the
		 * snapshot itself whenever this element is element 0.
		 */
		hammer2_xop_start_except(&xop2->head, &hammer2_ipcluster_desc,
					 snap ? -1 : idx);
		hammer2_inode_unlock(ip);
		merror = hammer2_xop_collect(&xop2->head, 0);
		/*
		 * XXX Linux: a source that could not be read is a pass that
		 * cannot verify, not a skipped inode; see list->failed.
		 */
		if (merror)
			list->failed = 1;
		if (merror == 0 && (focus = xop2->head.cluster.focus) != NULL) {
			sync_tid = focus->bref.modify_tid;
			if (snap) {
				chain = hammer2_sync_slave_chain(thr, inum, pin,
				    isroot, &parent, list);
			} else {
				chain = hammer2_inode_chain_and_parent(ip, idx,
							    &parent,
							    HAMMER2_RESOLVE_ALWAYS |
							    HAMMER2_RESOLVE_SHARED);
			}
			/*
			 * XXX Linux: the carried code read
			 * `chain->bref.modify_tid` on the line above its own
			 * `if (chain)` test, so a NULL chain was a null-ptr
			 * deref rather than a skipped update.
			 *
			 * Which way the NULL case should go has now been
			 * measured both ways, and neither is right, because
			 * neither is where the defect is.  Returning 1 (ask for
			 * the update) sends the inode into the scan below, which
			 * does `parent = hammer2_inode_chain()` at
			 * hammer2_synchro.c:556 and then
			 * `hammer2_chain_lookup(&parent, ...)` with that NULL,
			 * faulting at +0x28.  Returning 0 (skip) silently loses
			 * the element: measured on the 2026-10-13 images as
			 * 4,000 inodes and 4,000 data blocks absent from the
			 * slave while all 4,801 dirents arrived.  0 is the state
			 * this tree ships, because a fault on the sync thread
			 * never sets HAMMER2_THREAD_FROZEN and the unmount then
			 * waits for it in a loop with no bound: that run hung
			 * past 1500 s, which is worse than a copy that does not
			 * converge.
			 *
			 * An empty element is created when a chain cannot be
			 * placed, which left the destination's cluster element
			 * unbuilt.  Two things fixed that and neither is here.
			 * The split bound in hammer2_chain_create_indirect()
			 * sizes the new block one radix level under its parent,
			 * so no block is built that its parent cannot hold and
			 * the guard that used to refuse them does not fire: the
			 * run of 2026-10-13 records 0 refusals and 0 calls to
			 * create_indirect across its passes, against 340 and
			 * 536026 before the bound.  The clamp in
			 * hammer2_sync_insert() narrows a copied radix to the
			 * receiving parent's.
			 *
			 * This ternary is not either of those.  It keeps a copy
			 * off a NULL element when one still arises, and what it
			 * avoids is a fault on the sync thread, which never sets
			 * HAMMER2_THREAD_FROZEN and leaves the unmount waiting
			 * in a loop with no bound.
			 */
			slave_tid = chain ? chain->bref.modify_tid : 0;
			want_update = chain ? (chain->bref.modify_tid != sync_tid) : 0;
			/*
			 * XXX Linux: or the rescan set asks for it, the tids
			 * agreeing by the flush's propagation and not by a clean
			 * scan; see hammer2_thread.rescan.
			 */
			if (chain && want_update == 0 &&
			    hammer2_sync_rescan_wanted(thr, rinum)) {
				want_update = 1;
				atomic_add_int(&h2dbg_rescan, 1);
			}
			/*
			 * XXX Linux: on a snapshot pass an inode the frontend
			 * wrote after the snapshot was taken is ahead of it.  A
			 * scan would keep each newer key and put back each one
			 * the frontend deleted, since the insert arm has nothing
			 * to compare a missing key against; the inode is left to
			 * the next snapshot, which holds what the slave holds,
			 * and counted as kept so the pass reads `newer`.  The
			 * same rule the kept-newer arms apply to a key, one
			 * level up.  The root is not tested: its snapshot tid is
			 * a fresh one on another counter.
			 */
			if (snap && !isroot && chain && slave_tid > sync_tid) {
				want_update = 0;
				++list->kept;
				if (hammer2_debug & 0x8000)
					kprintf("syncsnap: newer inode %016llx\n",
					    (long long)rinum);
			}
			if (chain) {
				hammer2_chain_unlock(chain);
				hammer2_chain_drop(chain);
				chain = NULL;
			}
			if (parent) {
				hammer2_chain_unlock(parent);
				hammer2_chain_drop(parent);
				parent = NULL;
			}
		}
		hammer2_xop_retire(&xop2->head, HAMMER2_XOPMASK_VOP);
	}

	if (want_update == 0)
		return(0);

	/*
	 * The inode is left unlocked during the scan.  Issue a XOP
	 * that does *not* include our cluster index to iterate
	 * properly synchronized elements and resolve our cluster index
	 * against it.
	 */
	hammer2_inode_lock(ip, HAMMER2_RESOLVE_SHARED);
	xop = hammer2_xop_alloc(ip, HAMMER2_XOP_MODIFYING);
	xop->key_beg = HAMMER2_KEY_MIN;
	xop->key_end = HAMMER2_KEY_MAX;
	xop->resolve_flags = HAMMER2_RESOLVE_SHARED |
			     HAMMER2_RESOLVE_ALWAYS;
	xop->lookup_flags = HAMMER2_LOOKUP_SHARED |
			    HAMMER2_LOOKUP_NODIRECT |
			    HAMMER2_LOOKUP_ALWAYS;
	hammer2_xop_start_except(&xop->head, &hammer2_scanall_desc,
				 snap ? -1 : idx);	/* XXX Linux: see above */
	if (snap) {
		/*
		 * XXX Linux: the slave's inode chain is found under this
		 * element once the snapshot's inode is unlocked, so that no
		 * lock of the snapshot's tree is held while one of this tree's
		 * is taken.  The chain lock classes carry a chain's type and
		 * level and not which tree it is in, see hammer2_os.h, and the
		 * two trees have the same shape; the scan itself holds the
		 * snapshot's chains the way the FIFO holds a master's, held
		 * and not locked.
		 */
		hammer2_chain_t *pparent;

		hammer2_inode_unlock(ip);
		parent = hammer2_sync_slave_chain(thr, inum, pin, isroot,
		    &pparent, list);
		if (pparent) {
			hammer2_chain_unlock(pparent);
			hammer2_chain_drop(pparent);
		}
	} else {
		parent = hammer2_inode_chain(ip, idx,
					     HAMMER2_RESOLVE_ALWAYS |
					     HAMMER2_RESOLVE_SHARED);
		hammer2_inode_unlock(ip);
	}

	/*
	 * XXX Linux: an inode with no chain on this element cannot be
	 * scanned, and hammer2_chain_lookup() faults on the NULL parent.
	 * The pass fails and the inode is not stamped, so the next pass
	 * reaches it again.
	 */
	if (parent == NULL) {
		hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);
		list->failed = 1;
		return (HAMMER2_ERROR_EIO);
	}

	chain = hammer2_chain_lookup(&parent, &key_next,
				     HAMMER2_KEY_MIN, HAMMER2_KEY_MAX,
				     &serror,
				     HAMMER2_LOOKUP_SHARED |
				     HAMMER2_LOOKUP_NODIRECT |
				     HAMMER2_LOOKUP_NODATA);
	merror = hammer2_xop_collect(&xop->head, 0);
	/*
	 * XXX Linux: the root scan's line; one per deferred inode was 20000
	 * lines a copy pass on a serial console (2026-10-18).
	 */
	if ((hammer2_debug & 0x8000) && isroot) {
		/* XXX Linux: %jx, which printk does not implement */
		kprintf("START_SCAN IP=%016llx chain=%p (%016llx)\n",
			ip->meta.name_key, chain,
			(chain ? chain->bref.key : -1));
	}

	for (;;) {
		/*
		 * We are done if our scan is done and the XOP scan is done.
		 * We are done if the XOP scan failed (that is, we don't
		 * have authoritative data to synchronize with).
		 */
		int advance_local = 0;
		int advance_xop = 0;
		int dodefer = 0;
		hammer2_chain_t *focus;

		++iters;
		if (chain == NULL && merror == HAMMER2_ERROR_ENOENT) {
			exit_reason = 1;
			break;
		}
		if (merror && merror != HAMMER2_ERROR_ENOENT) {
			exit_reason = 2;
			break;
		}

		/*
		 * Compare
		 */
		if (chain && merror == HAMMER2_ERROR_ENOENT) {
			/*
			 * If we have local chains but the XOP scan is done,
			 * the chains need to be deleted.
			 *
			 * XXX Linux: this is the sweep, and the counter for it
			 * belongs here.  It was first placed in the `n < 0` arm
			 * on `merror == HAMMER2_ERROR_ENOENT`, which this path
			 * never reaches with: the arm runs with the same merror,
			 * so the test was true only if the counter was already in
			 * the arm, and the arm is entered from here with `n` set
			 * rather than from the compare.  The counter read 0 in
			 * every run, and two entries were written retracting the
			 * sweep on the strength of that 0.  Counted here, where
			 * the sweep decides to delete, it can only be 0 if the
			 * sweep does not run.
			 */
			++swept;
			n = -1;
			focus = NULL;
		} else if (chain == NULL) {
			/*
			 * If our local scan is done but the XOP scan is not,
			 * we need to create the missing chain(s).
			 */
			n = 1;
			focus = xop->head.cluster.focus;
		} else {
			/*
			 * Otherwise compare to determine the action
			 * needed.
			 */
			focus = xop->head.cluster.focus;
			n = hammer2_chain_cmp(chain, focus);
		}

		/*
		 * XXX Linux: the instrument the six refuted changes assumed.
		 * Every arm below decides whether an inode is copied, replaced,
		 * deleted or left alone, and no reading so far has said WHICH arm
		 * the file keys take.  A directory holding 4001 entries has its
		 * file keys in the hash space above the inode-number range, and
		 * the counts of `sync_insert` say those keys are offered 4001
		 * times while only 75 inode-type chains are created, so the arm
		 * taken for them is the question, not the mechanism behind the
		 * arm.
		 *
		 * keybits 0 with a key above 2^63 is a file hash: inode numbers
		 * are small and directories hash to the top of the space.  The
		 * three counters are printed once per pass at the end of the root
		 * scan rather than per key, since a per-key print is the console
		 * flood this file already carries two of.
		 */
		{
			uint64_t kh = (focus ? focus->bref.key :
			    (chain ? chain->bref.key : 0));
			if (kh > 0x8000000000000000ULL && kh != 0xffffffffffffffffULL) {
				if (n < 0)
					atomic_add_int(&h2dbg_file_nlt, 1);
				else if (n == 0)
					atomic_add_int(&h2dbg_file_neq, 1);
				else
					atomic_add_int(&h2dbg_file_ngt, 1);
			}
		}

		/*
		 * Take action based on comparison results.
		 */
		/*
		 * XXX Linux: the per-iteration state of the sweep path.  Two fixes
		 * to this path have hung the loop in two different places, and
		 * neither could be diagnosed from the pass totals.  This prints the
		 * values the arm decision was just made from, so the next change is
		 * written against the state rather than a guess about it.  Gated on
		 * 0x10000, a bit no other print in this file uses.  Read-only.
		 *
		 * MEASURED 2026-10-15, and it disposes of the first version of this
		 * gate: `iters < 64` alone caps the print out of the region the
		 * defect lives in.  The failing run's destroy pass
		 * (`cluster-run-20261015-014720`) ran 3816 turns and destroyed at
		 * the end of them, so the print covered turns 1 to 63 of a pass
		 * whose damage lands at turn ~3800, and every reading taken from it
		 * described the head of a healthy pass.  A turn that is about to
		 * take the `n < 0` arm is the one worth printing and there are few
		 * of them, so it is printed whatever its turn number is.
		 */
		if ((hammer2_debug & 0x10000) && (iters < 64 || n < 0)) {
			kprintf("sweepstate it %d n %d merror %08x "
			    "focus %016llx/%d local %016llx/%d\n",
			    iters, n, merror,
			    (focus ? focus->bref.key : 0),
			    (focus ? focus->bref.type : -1),
			    (chain ? chain->bref.key : 0),
			    (chain ? chain->bref.type : -1));
		}
		if (n < 0) {
			/*
			 * Delete extranious local data.  This will
			 * automatically advance the chain.
			 *
			 * XXX Linux: two ways reach this arm and only one is a
			 * deletion.  The compare arm takes it when the local
			 * chain sorts before the master's focus, which is a real
			 * leftover.  The entry above takes it when the XOP scan
			 * has ended but the local scan has not, and that
			 * end-of-scan is not always an end: hammer2_xop_scanall()
			 * feeds NULL with error 0 when hammer2_inode_chain()
			 * cannot resolve the element, and
			 * hammer2_xop_collect() reads the all-NULL cluster as
			 * ENOENT exactly as it reads a completed scan.  The
			 * pass then deletes every key the element still holds,
			 * including keys the master holds.
			 *
			 * Kept apart on the 2026-10-14 run: `n<0` was 0 for every
			 * pass up to the one that lost keys, which then read
			 * `n<0 66` with `n>0` flat at 57, and the 66 destroys
			 * landed in 3 ms, one per key, with no compare between
			 * them.  A compare arm cannot produce that shape.
			 *
			 * The counters below count and nothing else; the delete
			 * stays on both paths.  Skipping it on the sweep path
			 * livelocked the pass, measured the same day: that path
			 * sets `n = -1` on every iteration by construction, so a
			 * skipped destroy sets neither advance flag and the loop
			 * re-enters with the same chain forever.  The hung-task
			 * report names it, kworker/5:1 blocked in
			 * hammer2_chain_lock under hammer2_inode_chain_flush from
			 * hammer2_vfs_sync_pmp 122 s in, where the pass's own
			 * `START_SCAN` had run 222 s earlier.
			 */
			/*
			 * XXX Linux: on a snapshot pass the test is against the
			 * previous pass's snapshot cut, thr->snap_cut, and not
			 * this inode's tid: a key the frontend wrote while this
			 * snapshot's flush walked its tree can be missing from
			 * the snapshot with a tid below the flushed maximum,
			 * since writers are not interlocked against a flush
			 * here (hammer2_trans_init()), and would have been
			 * flushed into the next one.  Measured 2026-10-18 as
			 * 1997 entries destroyed on the slave during a 20000-file
			 * write, 836 of them never re-inserted, every one present
			 * on the master.  A key older than the previous cut and
			 * absent from this snapshot has been deleted on the
			 * master, or was never there.
			 */
			if (snap ? (chain->bref.modify_tid >= thr->snap_cut) :
			    (chain->bref.modify_tid > sync_tid)) {
				/*
				 * XXX Linux: the chain was written on this element
				 * after the master state this pass copies, so the
				 * master's scan, which reflects that state, has no
				 * focus for its key.  The compare reads the key as
				 * one the master no longer holds and destroys it,
				 * and the key is then gone from the slave while the
				 * master still holds it: measured on
				 * `cluster-run-20261014-171347`, 66 keys destroyed
				 * and the same 66 present on the master and absent
				 * from the slave.
				 *
				 * Keep it and advance BOTH cursors.  Every other arm
				 * of this switch advances both, and this one must
				 * too: the earlier guard set only `advance_local`,
				 * which walked the local scan away from a master
				 * cursor that stayed put, and the change that dropped
				 * the advance altogether re-entered this arm on the
				 * same chain forever and hung the pass.  With both
				 * set the two walk forward together and the loop ends
				 * when either exhausts.
				 *
				 * EINPROGRESS so the pass does not stamp the element:
				 * the kept chain is not yet known to match the master,
				 * and a stamp here would call it synchronized against a
				 * state this pass never compared it to.
				 */
				atomic_add_int(&h2dbg_newer_kept, 1);
				++list->kept;	/* XXX Linux */
				advance_local = 1;
				advance_xop = 1;
				nerror = HAMMER2_ERROR_EINPROGRESS;
			} else {
				/*
				 * XXX Linux: the focus key and type, printed on the
				 * destroy.  The sweep arm above is tested first, so
				 * this arm is reached only with `merror` not ENOENT,
				 * and `hammer2_cluster_check()` returns EIO rather
				 * than leaving a NULL focus after a quorum agrees --
				 * the compare's `n < 0` therefore means the master's
				 * focus key is HIGHER than the local key, not that
				 * the master lacks it.  Read here, a focus key above
				 * the destroyed key is a scan that jumped over a live
				 * key mid-scan; a focus key equal to or overlapping
				 * the local key refutes that and reopens the compare.
				 */
				kprintf("destroy focus %016llx/%d local %016llx/%d\n",
					(focus ? focus->bref.key : 0),
					(focus ? focus->bref.type : -1),
					chain->bref.key, chain->bref.type);
				nerror = hammer2_sync_destroy(thr, &parent,
							      &chain, 0, idx);
				atomic_add_int(&h2dbg_act_destroy, 1);
				++list->acted;	/* XXX Linux */
			}
		} else if (n == 0 && snap &&
			   chain->bref.modify_tid > focus->bref.modify_tid) {
			/*
			 * XXX Linux: the slave's chain is newer than the
			 * snapshot's: the frontend wrote it after the snapshot
			 * was taken, or while its flush ran, and the next
			 * snapshot will hold the same.  Replacing it would put
			 * the older copy back for a pass, measured 2026-10-18 as
			 * 98 replacements for 5 rewritten files.  Kept, both
			 * cursors advance, and EINPROGRESS withholds the stamp
			 * as the kept-newer arm above does.
			 */
			atomic_add_int(&h2dbg_newer_kept, 1);
			++list->kept;	/* XXX Linux */
			advance_local = 1;
			advance_xop = 1;
			nerror = HAMMER2_ERROR_EINPROGRESS;
		} else if (n == 0 && chain->bref.modify_tid !=
				     focus->bref.modify_tid) {
			atomic_add_int(&h2dbg_act_replace, 1);	/* XXX Linux */
			++list->acted;	/* XXX Linux */
			/*
			 * Matching key but local data or meta-data requires
			 * updating.  If we will recurse, we still need to
			 * update to compatible content first but we do not
			 * synchronize modify_tid until the entire recursion
			 * has completed successfully.
			 */
			if (focus->bref.type == HAMMER2_BREF_TYPE_INODE) {
				nerror = hammer2_sync_replace(
						thr, parent, chain,
						0,
						idx, &xop->head, focus, 0);
				dodefer = 1;
			} else {
				nerror = hammer2_sync_replace(
						thr, parent, chain,
						focus->bref.modify_tid,
						idx, &xop->head, focus, 0);
			}
			advance_local = 1;
			advance_xop = 1;
		} else if (n == 0) {
			/*
			 * 100% match, advance both
			 */
			advance_local = 1;
			advance_xop = 1;
			nerror = 0;
			/*
			 * XXX Linux: unless the inode is on the rescan set, in
			 * which case the tids agree by the flush's propagation
			 * and not by a clean scan, and the recursion runs as the
			 * replace arm's would; see hammer2_thread.rescan.  An
			 * inode chain's key is its number.
			 */
			if (focus->bref.type == HAMMER2_BREF_TYPE_INODE &&
			    hammer2_sync_rescan_wanted(thr, focus->bref.key))
				dodefer = 1;
		} else if (n > 0) {
			/*
			 * Insert missing local data.
			 *
			 * If we will recurse, we still need to update to
			 * compatible content first but we do not synchronize
			 * modify_tid until the entire recursion has
			 * completed successfully.
			 */
			/*
			 * XXX Linux: on a snapshot pass a key the snapshot holds
			 * and the slave lacks, under an inode the frontend wrote
			 * after the snapshot was taken, is one the frontend has
			 * deleted since, and this arm has nothing to compare it
			 * against: it puts the deleted key back for a pass.
			 * Counted first, so the rule that follows is written
			 * against a number; see the verification record.
			 */
			if (snap && !isroot && slave_tid > sync_tid &&
			    (hammer2_debug & 0x8000))
				kprintf("syncsnap: reinsert %016llx/%d under newer "
				    "inode %016llx\n", (long long)focus->bref.key,
				    focus->bref.type, (long long)rinum);
			++list->acted;	/* XXX Linux */
			if (focus->bref.type == HAMMER2_BREF_TYPE_INODE) {
				nerror = hammer2_sync_insert(
						thr, &parent, &chain,
						0,
						idx, &xop->head, focus);
				dodefer = 2;
			} else {
				nerror = hammer2_sync_insert(
						thr, &parent, &chain,
						focus->bref.modify_tid,
						idx, &xop->head, focus);
			}
			advance_local = 1;
			advance_xop = 1;
		}

		/*
		 * XXX Linux: every arm above sets nerror and the carried code
		 * never reads it, so a key whose copy failed was followed by the
		 * stamp of the element root's modify_tid below, and every later
		 * pass read the two equal and did not retry.  Rolling the error
		 * into merror was tried on 2026-10-13 and reverted: the first
		 * failure then ended the scan, and the next pass retried the
		 * same early keys, 75 inode keys about 52 times each across 44
		 * passes, with the keys after them never reached.
		 *
		 * The record is one bit on the pass's deferral list instead.  The
		 * scan goes on past the failed key, so every key that can be
		 * copied is, and no inode root is stamped for the rest of the
		 * pass, so the next pass rescans and reaches the failed key again.
		 * EINPROGRESS from the kept-newer arm is a failure here on
		 * purpose: that arm's comment promises the element is not
		 * stamped, and this is what keeps the promise.
		 *
		 * DEFER(a failing pass is measured rewriting unrelated inodes):
		 * the bit is pass-wide, so a failure under one directory
		 * withholds the stamp from every inode the pass touches after
		 * it, and the next pass replaces each of those inodes' roots
		 * again.  Scoping it to the failed inode's ancestry needs the
		 * deferral entry to name its parent.
		 */
		if (advance_local || advance_xop) {
			atomic_add_int(&h2dbg_act_tried, 1);
			if (nerror) {
				atomic_add_int(&h2dbg_act_failed, 1);
				h2dbg_act_last = nerror;
			}
		}
		if (nerror == HAMMER2_ERROR_EINPROGRESS) {
			/*
			 * XXX Linux: a key kept as newer than the source is not
			 * a failure: nothing is retried for it, and its inode
			 * goes on the rescan set so the next pass, with its cut
			 * advanced, destroys a stale one or finds the next
			 * snapshot agreeing with it.  Withholding the stamp for it
			 * was measured 2026-10-18 on a resumed copy: one kept key
			 * ended each pass after a single deferral drain with no
			 * inode stamped, a thousand inodes handled and replaced
			 * again per pass, and no update line for the harness to
			 * read progress by.  The entry waits for the next pass; one
			 * read by this pass's own root rescan deferred the
			 * directory without end, see hammer2_thread.rescan_noted.
			 */
			++nfail;	/* XXX Linux: see hammer2_thread.rescan */
		} else if (nerror) {
			list->failed = 1;
			++nfail;	/* XXX Linux: see hammer2_thread.rescan */
		}

		/*
		 * We cannot recurse depth-first because the XOP is still
		 * running in node threads for this scan.  Create a placemarker
		 * by obtaining and record the hammer2_inode.
		 *
		 * We excluded our node from the XOP so we must temporarily
		 * add it to xop->head.cluster so it is properly incorporated
		 * into the inode.
		 *
		 * The deferral is pushed onto a LIFO list for bottom-up
		 * synchronization.
		 */
		/*
		 * XXX Linux: and only if the arm succeeded.  A deferred inode
		 * whose insert or replace failed has no element chain to
		 * recurse into: measured 2026-10-16 with three allocations
		 * refused in the first pass, the recursion's
		 * hammer2_inode_chain() returned NULL and the scan's lookup
		 * faulted on it, taking the sync thread with it.  The failed
		 * key is reached again by the next pass, since its root is
		 * not stamped.
		 */
		if (merror == 0 && dodefer && nerror == 0) {
			hammer2_inode_t *nip;
			hammer2_deferred_ip_t *defer;

			KKASSERT(focus->bref.type == HAMMER2_BREF_TYPE_INODE);

			/* XXX Linux: kmalloc(), DragonFly's three-argument one */
			defer = hmalloc(sizeof(*defer), M_HAMMER2,
					M_WAITOK | M_ZERO);
			if (snap) {
				/*
				 * XXX Linux: the inode is the snapshot's, made as
				 * the live one is below but from the scan's own
				 * cluster, which holds the snapshot's chain and no
				 * element of this PFS; the slave's chain is pinned
				 * beside it.  See hammer2_deferred_ip.
				 */
				nip = hammer2_inode_get(ip->pmp, &xop->head, -1,
				    -1);
				defer->inum = nip->meta.inum;
				defer->pin = chain;
				hammer2_chain_ref(chain);
			} else {
				KKASSERT(xop->head.cluster.array[idx].chain ==
				    NULL);
				xop->head.cluster.array[idx].flags =
								HAMMER2_CITEM_INVALID;
				xop->head.cluster.array[idx].chain = chain;
				nip = hammer2_inode_get(pmp, &xop->head, -1,
				    idx);
				xop->head.cluster.array[idx].chain = NULL;
				/*
				 * XXX Linux: the slave's chain is kept for the
				 * pass-end flush's re-flag on this path too; see
				 * hammer2_deferred_list.done.
				 */
				defer->pin = chain;
				hammer2_chain_ref(chain);
			}

			hammer2_inode_ref(nip);
			hammer2_inode_unlock(nip);
			defer->ip = nip;

			defer->next = list->base;
			list->base = defer;
			++list->count;
			needrescan = 1;
		}

		/*
		 * If at least one deferral was added and the deferral
		 * list has grown too large, stop adding more.  This
		 * will trigger an HAMMER2_ERROR_EAGAIN return.
		 */
		if (needrescan && list->count > 1000) {
			exit_reason = 3;
			break;
		}

		/*
		 * Advancements for iteration.
		 */
		if (advance_xop) {
			merror = hammer2_xop_collect(&xop->head, 0);
		}
		if (advance_local) {
			/* XXX Linux: the FreeBSD port's chain_next(), no key_beg */
			chain = hammer2_chain_next(&parent, chain, &key_next,
						   HAMMER2_KEY_MAX,
						   &serror,
						   HAMMER2_LOOKUP_SHARED |
						   HAMMER2_LOOKUP_NODIRECT |
						   HAMMER2_LOOKUP_NODATA);
		}
	}
	hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);
	/*
	 * XXX Linux: the arm the file keys took, printed once per root scan.
	 * These are cumulative and the run is read from them at the end, so a
	 * repeated line is the expected shape rather than a flood: one per
	 * `hammer2_sync_slaves()` call on the PFS root.  On the root alone
	 * since 2026-10-18: one per deferred inode was 20000 lines a copy
	 * pass, and the harness reads the last root line and the largest
	 * sweep, which a directory scan's local counters never carried.
	 */
	if ((hammer2_debug & 0x8000) && isroot) {
		kprintf("filekeys n<0 %d  n==0 %d  n>0 %d  acted %d failed %d last %d kept %d sweep %d iters %d exit %d replaced %d destroyed %d rescan %d\n",
		    h2dbg_file_nlt, h2dbg_file_neq, h2dbg_file_ngt,
		    h2dbg_act_tried, h2dbg_act_failed, h2dbg_act_last,
		    h2dbg_newer_kept, swept, iters,
		    exit_reason, h2dbg_act_replace, h2dbg_act_destroy,
		    h2dbg_rescan);
	}
	if (chain) {
		hammer2_chain_unlock(chain);
		hammer2_chain_drop(chain);
	}
	if (parent) {
		hammer2_chain_unlock(parent);
		hammer2_chain_drop(parent);
	}

	/*
	 * If we added deferrals we want the caller to synchronize them
	 * and then call us again.
	 *
	 * NOTE: In this situation we do not yet want to synchronize our
	 *	 inode, setting the error code also has that effect.
	 */
	if ((merror == 0 || merror == HAMMER2_ERROR_ENOENT) && needrescan)
		merror = HAMMER2_ERROR_EAGAIN;

	/*
	 * If no error occurred we can synchronize the inode meta-data
	 * and modify_tid.  Only limited changes are made to PFSROOTs.
	 *
	 * XXX inode lock was lost
	 *
	 * XXX Linux: and only if no key of this pass failed, see list->failed.
	 */
	if ((merror == 0 || merror == HAMMER2_ERROR_ENOENT) && !list->failed) {
		hammer2_xop_ipcluster_t *xop2;
		hammer2_chain_t *focus;

		hammer2_inode_lock(ip, HAMMER2_RESOLVE_SHARED);
		xop2 = hammer2_xop_alloc(ip, HAMMER2_XOP_MODIFYING);
		hammer2_xop_start_except(&xop2->head, &hammer2_ipcluster_desc,
					 snap ? -1 : idx);	/* XXX Linux */
		hammer2_inode_unlock(ip);
		merror = hammer2_xop_collect(&xop2->head, 0);
		if (merror == 0) {
			focus = xop2->head.cluster.focus;
			if ((hammer2_debug & 0x8000) && focus) {
				const char *filename;

				filename = hammer2_xop_gdata(&xop2->head)->
						ipdata.filename;
				kprintf("syncthr: update inode %p (%s)\n",
					focus, filename);
				hammer2_xop_pdata(&xop2->head);
			}
			/*
			 * XXX Linux: the slave's chain and its parent come out of
			 * the inode on the live path and are found by inode
			 * number on a snapshot pass; see hammer2_sync_slave_chain().
			 */
			if (snap) {
				chain = hammer2_sync_slave_chain(thr, inum, pin,
				    isroot, &parent, list);
			} else {
				chain = hammer2_inode_chain_and_parent(ip, idx,
							    &parent,
							    HAMMER2_RESOLVE_ALWAYS |
							    HAMMER2_RESOLVE_SHARED);
			}

			/*
			 * XXX Linux: this call site already guards on
			 * parent, and since a NULL chain always comes with a
			 * NULL parent the pair is one condition.  Upstream
			 * states it as an assert; here a missing cluster
			 * element is an ordinary outcome of the flush path,
			 * so it is a skipped update rather than a fault.
			 */
			if (parent == NULL) {
				hammer2_xop_retire(&xop2->head,
				    HAMMER2_XOPMASK_VOP);
				hammer2_sync_rescan_note(thr, rinum, nfail);
				return (merror);
			}
			KKASSERT(parent != NULL);
			nerror = hammer2_sync_replace(
					thr, parent, chain,
					sync_tid,
					idx, &xop2->head, focus, isroot);
			hammer2_chain_unlock(chain);
			hammer2_chain_drop(chain);
			hammer2_chain_unlock(parent);
			hammer2_chain_drop(parent);
			/* XXX */
		}
		hammer2_xop_retire(&xop2->head, HAMMER2_XOPMASK_VOP);
	} else if (merror == HAMMER2_ERROR_ENOENT) {
		/*
		 * XXX Linux: the scan's own end, which the stamp above used
		 * to absorb by reissuing the collect.  With the stamp
		 * withheld it reached the caller as a pass error: measured
		 * 2026-10-16, two `error 64` prints on a run that converged.
		 * The failure that withheld the stamp is in list->failed, so
		 * this returns what a completed scan returns.
		 */
		merror = 0;
	}

	/*
	 * XXX Linux: a scan that kept or failed a key puts this inode on the
	 * rescan set, a clean one takes it off; see hammer2_thread.rescan.
	 */
	hammer2_sync_rescan_note(thr, rinum, nfail);

	return merror;
}

/*
 * Create a missing chain by copying the focus from another device.
 *
 * On entry *parentp and focus are both locked shared.  The chain will be
 * created and returned in *chainp also locked shared.
 */
static
int
hammer2_sync_insert(hammer2_thread_t *thr,
		    hammer2_chain_t **parentp, hammer2_chain_t **chainp,
		    hammer2_tid_t mtid, int idx, hammer2_xop_head_t *xop,
		    hammer2_chain_t *focus)
{
	hammer2_chain_t *chain;
	hammer2_key_t dummy;
	int error;

	/*
	 * XXX Linux: the held-chain dump, at the site the 2026-10-12 lock
	 * report was taken from.  That report was a recursive-locking
	 * warning on `h2core_indirect/2#2` acquired twice at one site in
	 * this function, and the class scheme prints only type and level, so
	 * two distinct INDIRECT chains of one keybits name identically.  The
	 * dump beside the class registry prints each held chain's key and
	 * keybits, which is the value the invariant is stated in: keybits
	 * strictly decreases from parent to child within a type.  A held
	 * stack that is not strictly decreasing is a topology defect, and one
	 * with no repeated keybits is a lock defect; the two want different
	 * fixes, which is why the value is worth printing.
	 *
	 * The acquisition the report named is the inlined
	 * hammer2_spin_sh(&parent->core.spin) inside hammer2_sync_setflush(),
	 * reached from the hammer2_chain_create() call further down, so the
	 * stack is complete only after that.  This prints on entry, where
	 * *parentp is the chain already held shared, which is the half of the
	 * stack the report showed as already-held.
	 */
	(void)hammer2_dbg_held_chains("sync_insert entry");

	/*
	 * The decisive reading, and it does not depend on lockdep: the parent
	 * being inserted into and the focus being copied, side by side, with
	 * their type and keybits.  The invariant is that keybits strictly
	 * decreases from parent to child within a type, so if this prints a
	 * parent whose keybits is not greater than the focus's, the sync path
	 * is building a topology that the radix descent lookup relies on and
	 * that the invariant forbids.  Two INDIRECT entries at equal keybits
	 * is exactly the shape the 2026-10-12 lock report could not settle,
	 * since the class scheme names both identically.  A false negative is
	 * possible and is why the dump above is kept beside it: this prints
	 * only on the insert path, and the report's stack also arises from a
	 * delete and a reinsert inside one create.
	 */
	if ((*parentp)->bref.type == HAMMER2_BREF_TYPE_INDIRECT &&
	    focus->bref.type == HAMMER2_BREF_TYPE_INDIRECT)
		hprintf("sync_insert: parent indirect kb %d key %016llx, "
		    "focus indirect kb %d key %016llx%s\n",
		    (*parentp)->bref.keybits, (long long)(*parentp)->bref.key,
		    focus->bref.keybits, (long long)focus->bref.key,
		    (*parentp)->bref.keybits <= focus->bref.keybits ?
		    "  <- NOT strictly decreasing" : "");

#if HAMMER2_SYNCHRO_DEBUG
	if (hammer2_debug & 1)
	/* XXX Linux: %jx, which printk does not implement */
	kprintf("insert rec par=%p/%d.%016llx slave %d %d.%016llx mod=%016llx\n",
		*parentp,
		(*parentp)->bref.type,
		(*parentp)->bref.key,
		idx,
		focus->bref.type, focus->bref.key, mtid);
#endif

	/*
	 * Parent requires an exclusive lock for the insertion.
	 * We must unlock the child to avoid deadlocks while
	 * relocking the parent.
	 */
	if (*chainp) {
		hammer2_chain_unlock(*chainp);
		hammer2_chain_drop(*chainp);
		*chainp = NULL;
	}
	hammer2_chain_unlock(*parentp);
	hammer2_chain_lock(*parentp, HAMMER2_RESOLVE_ALWAYS);

	/*
	 * We must reissue the lookup to properly position (*parentp)
	 * for the insertion.
	 */
	chain = hammer2_chain_lookup(parentp, &dummy,
				     focus->bref.key, focus->bref.key,
				     &error,
				     HAMMER2_LOOKUP_NODIRECT |
				     HAMMER2_LOOKUP_ALWAYS);
	KKASSERT(chain == NULL);

	chain = NULL;
	/*
	 * XXX Linux: the radix this hands chain_create() comes from the FOCUS
	 * (the other device's chain) and is inserted under whichever parent
	 * the scan above left in *parentp.  When the two trees differ in
	 * radix there the new block is born wider than its parent and cannot
	 * be inserted: measured 2026-10-13 as a radix-7 block for key 0x460
	 * refused under an INDIRECT parent of 0x440/6, whose keyspace 0x440-0x47f
	 * DOES contain the create key, so the parent was right and only the
	 * radix was wrong.  Printed here, where both values exist, because the
	 * reading that decides whether to fix the radix or the parent
	 * selection is this pair and nothing else.
	 *
	 * Gated on the debug bit like the START_SCAN print above, and it was
	 * not when it was added: ungated it is one line per element copied,
	 * 102,370 lines and 22 MB for a 4,000-file set, straight out the
	 * guest's serial console.  That starved the CPU irq#4 lands on and
	 * produced five soft lockups on ttyS0 in the 2026-10-13 run against
	 * zero in the twelve runs before it, so the probe was manufacturing a
	 * warning the run then reported.  The values are still wanted, so the
	 * bit turns them on rather than the line being dropped.
	 */
	if (hammer2_debug & 0x8000)
		kprintf("sync_insert: focus %016llx/%d into parent %016llx/%d type %d\n",
		    (long long)focus->bref.key, focus->bref.keybits,
		    (long long)(*parentp)->bref.key, (*parentp)->bref.keybits,
		    (*parentp)->bref.type);
	/*
	 * XXX Linux: the radix handed to hammer2_chain_create() here is the
	 * SOURCE's, and the source's tree need not be shaped like this one.
	 * Measured 2026-10-13 in the wedged log: 543902 inserts, every one with
	 * `focus .../0 ... type 2` and a parent at keybits 5, 6 or 7, and a
	 * `create_indirect` line for each producing `-> keybits 7`. A keybits-7
	 * block spans the whole of a keybits-7 parent's keyspace, so it is not
	 * that parent's child and cannot be represented: the destination either
	 * refuses it (340 refusals measured) or rebuilds it per key (536026
	 * create_indirect calls) until the run wedges.
	 *
	 * The clamp is HERE and not in hammer2_chain_indkey_dir(), because that
	 * function is shared with the master's own inserts. Capping it there was
	 * tried and narrowed BOTH trees, and the slave then covered no file keys
	 * at all: 0 of 1001 presented, against 4001 of 8080. This path is the
	 * only one that copies a radix from another device, so it is the only
	 * one that can hand back a block too wide for the tree receiving it.
	 */
	{
		int cbits = focus->bref.keybits;
		hammer2_key_t ckey = focus->bref.key;

		if ((*parentp)->bref.keybits > 0 &&
		    cbits >= (*parentp)->bref.keybits) {
			cbits = (*parentp)->bref.keybits - 1;
			if (cbits < 0)
				cbits = 0;
			/*
			 * The key was normalized to the source's radix, so it
			 * has to be renormalized to the narrower one or the
			 * block lands on the wrong boundary.  Same mask the
			 * radix helpers apply.
			 */
			ckey &= ~(((hammer2_key_t)1 << cbits) - 1);
		}
		error = hammer2_chain_create(parentp, &chain, NULL, thr->pmp,
				     focus->bref.methods,
				     ckey, cbits,
				     focus->bref.type, focus->bytes,
				     mtid, 0, 0);
	}
	if (error == 0) {
		const hammer2_media_data_t *data;

		error = hammer2_chain_modify(chain, mtid, 0, 0);
		if (error)
			goto failed;
		hammer2_sync_setflush(chain);	/* XXX Linux */

		/*
		 * Copy focus to new chain
		 */

		/* type already set */
		chain->bref.methods = focus->bref.methods;
		/* keybits already set */
		chain->bref.vradix = focus->bref.vradix;
		/* mirror_tid set by flush */
		KKASSERT(chain->bref.modify_tid == mtid);
		chain->bref.flags = focus->bref.flags;
		/* key already present */
		/* check code will be recalculated */

		/*
		 * Copy data body.
		 */
		switch(chain->bref.type) {
		case HAMMER2_BREF_TYPE_INODE:
			data = hammer2_xop_gdata(xop);

			if ((data->ipdata.meta.op_flags &
			     HAMMER2_OPFLAG_DIRECTDATA) == 0) {
				/* do not copy block table */
				bcopy(data, chain->data,
				      offsetof(hammer2_inode_data_t, u));
				hammer2_xop_pdata(xop);
				break;
			}
			hammer2_xop_pdata(xop);
			/* fall through copy whole thing */
		case HAMMER2_BREF_TYPE_DATA:
			data = hammer2_xop_gdata(xop);
			bcopy(data, chain->data, chain->bytes);
			hammer2_chain_setcheck(chain, chain->data);
			hammer2_xop_pdata(xop);
			break;
		case HAMMER2_BREF_TYPE_DIRENT:
			/*
			 * Directory entries embed data in the blockref.
			 */
			if (chain->bytes) {
				data = hammer2_xop_gdata(xop);
				bcopy(data, chain->data, chain->bytes);
				hammer2_chain_setcheck(chain, chain->data);
				hammer2_xop_pdata(xop);
			} else {
				chain->bref.check = focus->bref.check;
			}
			chain->bref.embed = focus->bref.embed;
			break;
		default:
			KKASSERT(0);
			break;
		}
	}

failed:
	if (chain)
		hammer2_chain_unlock(chain);	/* unlock, leave ref */
	*chainp = chain;			/* will be returned locked */

	/*
	 * Avoid an ordering deadlock when relocking shared.
	 */
	hammer2_chain_unlock(*parentp);
	hammer2_chain_lock(*parentp, HAMMER2_RESOLVE_SHARED |
				     HAMMER2_RESOLVE_ALWAYS);
	if (chain) {
		hammer2_chain_lock(chain, HAMMER2_RESOLVE_SHARED |
					  HAMMER2_RESOLVE_ALWAYS);
		/*
		 * XXX Linux: the carried line assigned chain->error here, which
		 * a failed hammer2_chain_modify() does not set, so an insert
		 * whose allocation was refused returned 0 and its key was
		 * stamped as copied.  The first error wins.
		 */
		if (error == 0)
			error = chain->error;
	}

	return error;
}

/*
 * Destroy an extranious chain.
 *
 * Both *parentp and *chainp are locked shared.
 *
 * On return, *chainp will be adjusted to point to the next element in the
 * iteration and locked shared.
 */
static
int
hammer2_sync_destroy(hammer2_thread_t *thr,
		     hammer2_chain_t **parentp, hammer2_chain_t **chainp,
		     hammer2_tid_t mtid, int idx)
{
	hammer2_chain_t *chain;
	hammer2_key_t key_next;
	hammer2_key_t save_key;
	int error;
	int derror;		/* XXX Linux: the delete's own */

	chain = *chainp;

#if HAMMER2_SYNCHRO_DEBUG
	/*
	 * XXX Linux: fires on 0x0001 (as carried, so 0x8001 keeps printing
	 * destroys) or on 0x4000 alone. The per-chain prints share 0x0001 with
	 * the insert and replace prints, and enabling it floods the pass with
	 * one line per insert until the interrupted stop lands after a couple
	 * of copies, which hides the shortfall the destroy is read against. A
	 * run at 0x8000|0x4000 carries the destroy keys with the pass running
	 * at its normal length.
	 */
	if (hammer2_debug & (1 | 0x4000))
	/* XXX Linux: %jx, which printk does not implement */
	kprintf("destroy rec %p/%p slave %d %d.%016llx\n",
		*parentp, chain,
		idx, chain->bref.type, chain->bref.key);
#endif

	save_key = chain->bref.key;
	if (save_key != HAMMER2_KEY_MAX)
		++save_key;

	/*
	 * Try to avoid unnecessary I/O.
	 *
	 * XXX accounting not propagated up properly.  We might have to do
	 *     a RESOLVE_MAYBE here and pass 0 for the flags.
	 */
	hammer2_chain_unlock(chain);	/* relock exclusive */
	hammer2_chain_unlock(*parentp);
	hammer2_chain_lock(*parentp, HAMMER2_RESOLVE_ALWAYS);
	hammer2_chain_lock(chain, HAMMER2_RESOLVE_NEVER);

	/*
	 * XXX Linux: the carried call discarded the delete's return, and the
	 * helper behind it modifies the parent, which can fail.  Kept and
	 * returned ahead of the re-lookup's, which still has to run to
	 * position *chainp.
	 */
	derror = hammer2_chain_delete(*parentp, chain, mtid,
				      HAMMER2_DELETE_PERMANENT);
	hammer2_sync_setflush(*parentp);	/* XXX Linux */
	hammer2_chain_unlock(chain);
	hammer2_chain_drop(chain);
	chain = NULL;			/* safety */

	hammer2_chain_unlock(*parentp);	/* relock shared */
	hammer2_chain_lock(*parentp, HAMMER2_RESOLVE_SHARED |
				     HAMMER2_RESOLVE_ALWAYS);
	*chainp = hammer2_chain_lookup(parentp, &key_next,
				     save_key, HAMMER2_KEY_MAX,
				     &error,
				     HAMMER2_LOOKUP_SHARED |
				     HAMMER2_LOOKUP_NODIRECT |
				     HAMMER2_LOOKUP_NODATA);
	return (derror ? derror : error);
}

/*
 * cparent is locked exclusively, with an extra ref, cluster is not locked.
 * Replace element [i] in the cluster.
 */
static
int
hammer2_sync_replace(hammer2_thread_t *thr,
		     hammer2_chain_t *parent, hammer2_chain_t *chain,
		     hammer2_tid_t mtid, int idx,
		     hammer2_xop_head_t *xop, hammer2_chain_t *focus,
		     int isroot)
{
	uint8_t otype;
	int nradix;
	int error;

#if HAMMER2_SYNCHRO_DEBUG
	if (hammer2_debug & 1)
	/* XXX Linux: %jx, which printk does not implement */
	kprintf("replace rec %p slave %d %d.%016llx mod=%016llx\n",
		chain,
		idx,
		focus->bref.type, focus->bref.key, mtid);
#endif
	hammer2_chain_unlock(chain);
	hammer2_chain_lock(chain, HAMMER2_RESOLVE_ALWAYS);
	error = chain->error;
	if (error == 0) {
		const hammer2_media_data_t *data;

		if (chain->bytes != focus->bytes) {
			/* XXX what if compressed? */
			/*
			 * XXX Linux: upstream takes the radix of chain->bytes,
			 * the slave's own size, so the resize changed nothing
			 * and the copy below ran for the slave's old length out
			 * of the master's shorter block.  KASAN read 64 KiB
			 * from a block with 6 KiB left when a rewritten file
			 * shrank (cluster-run-20261016-152207).  The master's
			 * size is the one the slave is being brought to.
			 */
			nradix = hammer2_getradix(focus->bytes);
			error = hammer2_chain_resize(chain, mtid, 0, nradix, 0);
			if (error)
				goto failed;
		}
		error = hammer2_chain_modify(chain, mtid, 0, 0);
		if (error)
			goto failed;
		hammer2_sync_setflush(chain);	/* XXX Linux */
		otype = chain->bref.type;
		data = hammer2_xop_gdata(xop);
		chain->bref.type = focus->bref.type;
		chain->bref.methods = focus->bref.methods;
		chain->bref.keybits = focus->bref.keybits;
		chain->bref.vradix = focus->bref.vradix;
		/* mirror_tid updated by flush */
		KKASSERT(mtid == 0 || chain->bref.modify_tid == mtid);
		chain->bref.flags = focus->bref.flags;
		/* key already present */
		/* check code will be recalculated */

		/*
		 * Copy data body.
		 */
		switch(chain->bref.type) {
		case HAMMER2_BREF_TYPE_INODE:
			/*
			 * Special case PFSROOTs, only limited changes can
			 * be made since the meta-data contains miscellanious
			 * distinguishing fields.
			 */
			if (isroot) {
				chain->data->ipdata.meta.uflags =
					data->ipdata.meta.uflags;
				chain->data->ipdata.meta.rmajor =
					data->ipdata.meta.rmajor;
				chain->data->ipdata.meta.rminor =
					data->ipdata.meta.rminor;
				chain->data->ipdata.meta.ctime =
					data->ipdata.meta.ctime;
				chain->data->ipdata.meta.mtime =
					data->ipdata.meta.mtime;
				chain->data->ipdata.meta.atime =
					data->ipdata.meta.atime;
				/* not btime */
				chain->data->ipdata.meta.uid =
					data->ipdata.meta.uid;
				chain->data->ipdata.meta.gid =
					data->ipdata.meta.gid;
				chain->data->ipdata.meta.mode =
					data->ipdata.meta.mode;
				chain->data->ipdata.meta.ncopies =
					data->ipdata.meta.ncopies;
				chain->data->ipdata.meta.comp_algo =
					data->ipdata.meta.comp_algo;
				chain->data->ipdata.meta.check_algo =
					data->ipdata.meta.check_algo;
				chain->data->ipdata.meta.data_quota =
					data->ipdata.meta.data_quota;
				chain->data->ipdata.meta.inode_quota =
					data->ipdata.meta.inode_quota;

				/*
				 * last snapshot tid controls overwrite
				 */
				if (chain->data->ipdata.meta.pfs_lsnap_tid <
				    data->ipdata.meta.pfs_lsnap_tid) {
					chain->data->ipdata.meta.pfs_lsnap_tid =
					data->ipdata.meta.pfs_lsnap_tid;
				}

				hammer2_chain_setcheck(chain, chain->data);
				break;
			}

			/*
			 * Normal replacement.
			 */
			if ((data->ipdata.meta.op_flags &
			     HAMMER2_OPFLAG_DIRECTDATA) == 0) {
				/*
				 * If DIRECTDATA is transitioning to 0 or the
				 * old chain is not an inode we have to
				 * initialize the block table.
				 */
				if (otype != HAMMER2_BREF_TYPE_INODE ||
				    (chain->data->ipdata.meta.op_flags &
				     HAMMER2_OPFLAG_DIRECTDATA)) {
					kprintf("chain inode trans "
						"away from dd\n");
					bzero(&chain->data->ipdata.u,
					      sizeof(chain->data->ipdata.u));
				}
				bcopy(data, chain->data,
				      offsetof(hammer2_inode_data_t, u));
				/* XXX setcheck on inode should not be needed */
				hammer2_chain_setcheck(chain, chain->data);
				break;
			}
			/* fall through */
		case HAMMER2_BREF_TYPE_DATA:
			bcopy(data, chain->data, chain->bytes);
			hammer2_chain_setcheck(chain, chain->data);
			break;
		case HAMMER2_BREF_TYPE_DIRENT:
			/*
			 * Directory entries embed data in the blockref.
			 */
			if (chain->bytes) {
				bcopy(data, chain->data, chain->bytes);
				hammer2_chain_setcheck(chain, chain->data);
			} else {
				chain->bref.check = focus->bref.check;
			}
			chain->bref.embed = focus->bref.embed;
			break;
		default:
			KKASSERT(0);
			break;
		}
		hammer2_xop_pdata(xop);
	}

failed:
	hammer2_chain_unlock(chain);
	hammer2_chain_lock(chain, HAMMER2_RESOLVE_SHARED |
				  HAMMER2_RESOLVE_MAYBE);

	return error;
}
