/*-
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Copyright (c) 2022-2023 Tomohiro Kusumi <tkusumi@netbsd.org>
 * Copyright (c) 2011-2022 The DragonFly Project.  All rights reserved.
 * All rights reserved.
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

#include "hammer2.h"

/*
 * Upstream keeps the mount-side lists here too.  hammer2_mntlist and
 * hammer2_mntlk are the mount path's, so they land with it rather than
 * sitting unused: a definition with no user is what the syntax gate
 * flags, and silencing that would hide the fact that this file is half
 * written.
 */
hammer2_pfslist_t hammer2_pfslist;
static hammer2_pfslist_t hammer2_spmplist;

/*
 * XXX Linux: this file is a rewrite with a carried body, and that is a
 * weaker claim than the one hammer2_ondisk.c makes.  There no carried
 * function had its control flow edited; here the function boundary itself
 * moves, because FreeBSD's hammer2_mount(struct mount *) maps onto Linux's
 * ->init_fs_context, ->parse_param, ->get_tree and a fill_super, with
 * MNT_UPDATE splitting off to ->reconfigure.  Statements carry; functions
 * do not.  The differences are collected here rather than repeated:
 *
 * - HAMMER2 spans up to HAMMER2_MAX_VOLUMES devices and hammer2_open_devvp()
 *   already opens all of them with the super_block as holder.  So this port
 *   does NOT use get_tree_bdev(), which opens exactly one device and takes
 *   sb->s_bdev for it.  It follows btrfs, the multi-device filesystem in
 *   tree: sget_fc() with set_anon_super_fc(), super_setup_bdi(), and no
 *   sb->s_bdev at all.  Read against Linux v7.2, the kernel of record:
 *   fs/btrfs/super.c btrfs_get_tree_super(), and fs/super.c
 *   setup_bdev_super(), which is what get_tree_bdev() would have run and
 *   which ends in sb_set_blocksize(sb, block_size(bdev)) -- the device's
 *   block size, not HAMMER2_PBUFSIZE.
 *
 * - the PFS half below is DragonFly's and carries.  It is separated from
 *   the Linux entry so that half stays readable against the BSD ports.
 *
 * - hammer2_pfsfree_scan() keeps its hammer2_vfs_sync_pmp() call, which is
 *   declared in hammer2.h and not yet defined anywhere.  That is deliberate:
 *   nothing in this tree links yet, and a symbol that is missing at link
 *   time is visible, where a stub returning success would be silent on the
 *   one path that decides whether an unmount lost data.
 */

/*
 * XXX Linux: FreeBSD's hashinit(9) allocates a power-of-two array of list
 * heads and hands back the mask.  HAMMER2_IHASH_SIZE is a compile-time
 * constant, so there is nothing to size at run time and nothing here that
 * a hash-table abstraction would earn: the array and the two lines that
 * initialize it are the whole of it.  The field types in hammer2.h are
 * left as upstream has them so the carried users read unchanged.
 */
static int
hammer2_ipdep_init(hammer2_pfs_t *pmp)
{
	int i;

	pmp->ipdep_lists = hmalloc(HAMMER2_IHASH_SIZE * sizeof(*pmp->ipdep_lists),
	    M_HAMMER2, M_WAITOK | M_ZERO);
	if (pmp->ipdep_lists == NULL)
		return (ENOMEM);
	for (i = 0; i < HAMMER2_IHASH_SIZE; i++)
		LIST_INIT(&pmp->ipdep_lists[i]);
	pmp->ipdep_mask = HAMMER2_IHASH_SIZE - 1;

	return (0);
}

static void
hammer2_ipdep_destroy(hammer2_pfs_t *pmp)
{
	hfree(pmp->ipdep_lists,
	    M_HAMMER2, HAMMER2_IHASH_SIZE * sizeof(*pmp->ipdep_lists));
	pmp->ipdep_lists = NULL;
}

void
hammer2_voldata_lock(hammer2_dev_t *hmp)
{
	hammer2_lk_ex(&hmp->vollk);
}

void
hammer2_voldata_unlock(hammer2_dev_t *hmp)
{
	hammer2_lk_unlock(&hmp->vollk);
}

void
hammer2_voldata_modify(hammer2_dev_t *hmp)
{
	if ((hmp->vchain.flags & HAMMER2_CHAIN_MODIFIED) == 0) {
		atomic_add_int(&hammer2_count_chain_modified, 1);
		atomic_set_int(&hmp->vchain.flags, HAMMER2_CHAIN_MODIFIED);
		hmp->vchain.bref.mirror_tid = hmp->voldata.mirror_tid + 1;
	}
}

hammer2_pfs_t *
hammer2_pfsalloc(hammer2_chain_t *chain, const hammer2_inode_data_t *ripdata,
    hammer2_dev_t *force_local)
{
	hammer2_pfs_t *pmp = NULL;
	hammer2_inode_t *iroot;
	int i, j;

	/*
	 * Locate or create the PFS based on the cluster id.  If ripdata
	 * is NULL this is a spmp which is unique and is always allocated.
	 *
	 * If the device is mounted in local mode all PFSs are considered
	 * independent and not part of any cluster.
	 */
	if (ripdata) {
		TAILQ_FOREACH(pmp, &hammer2_pfslist, mntentry) {
			if (force_local != pmp->force_local)
				continue;
			if (force_local == NULL &&
			    bcmp(&pmp->pfs_clid, &ripdata->meta.pfs_clid,
			    sizeof(pmp->pfs_clid)) == 0)
				break;
			else if (force_local && pmp->pfs_names[0] &&
			    strcmp(pmp->pfs_names[0],
			    (const char *)ripdata->filename) == 0)
				break;
		}
	}

	if (pmp == NULL) {
		pmp = hmalloc(sizeof(*pmp), M_HAMMER2, M_WAITOK | M_ZERO);
		pmp->force_local = force_local;
		hammer2_trans_manage_init(pmp);
		hammer2_spin_init(&pmp->blockset_spin, "h2mp_bset");
		hammer2_spin_init(&pmp->list_spin, "h2mp_list");
		for (i = 0; i < HAMMER2_IHASH_SIZE; i++) {
			hammer2_lk_init(&pmp->xop_lock[i], "h2mp_xop");
			hammer2_lkc_init(&pmp->xop_cv[i], "h2mp_xop_cv");
		}
		hammer2_lk_init(&pmp->trans_lock, "h2mp_tx");
		hammer2_lkc_init(&pmp->trans_cv, "h2mp_tx_cv");
		TAILQ_INIT(&pmp->syncq);
		TAILQ_INIT(&pmp->depq);
		hammer2_inum_hash_init(pmp);

		/* XXX Linux: hashinit(9), see hammer2_ipdep_init(). */
		if (hammer2_ipdep_init(pmp)) {
			hfree(pmp, M_HAMMER2, sizeof(*pmp));
			return (NULL);
		}

		if (ripdata) {
			pmp->pfs_clid = ripdata->meta.pfs_clid;
			TAILQ_INSERT_TAIL(&hammer2_pfslist, pmp, mntentry);
		} else {
			pmp->flags |= HAMMER2_PMPF_SPMP;
			TAILQ_INSERT_TAIL(&hammer2_spmplist, pmp, mntentry);
		}
	}

	/* Create the PFS's root inode. */
	if ((iroot = pmp->iroot) == NULL) {
		iroot = hammer2_inode_get(pmp, NULL, 1, -1);
		if (ripdata)
			iroot->meta = ripdata->meta;
		pmp->iroot = iroot;
		hammer2_inode_ref(iroot);
		hammer2_inode_unlock(iroot);
	}

	/* Stop here if no chain is passed in. */
	if (chain == NULL)
		goto done;

	/*
	 * When a chain is passed in we must add it to the PFS's root
	 * inode, update pmp->pfs_types[].
	 *
	 * When forcing local mode, mark the PFS as a MASTER regardless.
	 *
	 * At the moment empty spots can develop due to removals or failures.
	 * Ultimately we want to re-fill these spots but doing so might
	 * confused running code. XXX
	 */
	hammer2_inode_ref(iroot);
	hammer2_mtx_ex(&iroot->lock);
	j = iroot->cluster.nchains;

	if (j == HAMMER2_MAXCLUSTER) {
		hprintf("cluster full\n");
		/* XXX fatal error? */
	} else {
		KKASSERT(chain->pmp == NULL);
		chain->pmp = pmp;
		hammer2_chain_ref(chain);
		iroot->cluster.array[j].chain = chain;
		if (force_local)
			pmp->pfs_types[j] = HAMMER2_PFSTYPE_MASTER;
		else
			pmp->pfs_types[j] = ripdata->meta.pfs_type;
		pmp->pfs_names[j] = hstrdup((const char *)ripdata->filename);
		pmp->pfs_hmps[j] = chain->hmp;
		hammer2_spin_ex(&pmp->blockset_spin);
		pmp->pfs_iroot_blocksets[j] = chain->data->ipdata.u.blockset;
		hammer2_spin_unex(&pmp->blockset_spin);

		/*
		 * If the PFS is already mounted we must account
		 * for the mount_count here.
		 */
		if (pmp->mp)
			++chain->hmp->mount_count;
		++j;
	}
	iroot->cluster.nchains = j;
	hammer2_assert_cluster(&iroot->cluster);

	hammer2_mtx_unlock(&iroot->lock);
	hammer2_inode_drop(iroot);
done:
	return (pmp);
}

/* XXX Linux: __unused is the kernel's own name. */
void
hammer2_pfsdealloc(hammer2_pfs_t *pmp, int clindex,
    int destroying __maybe_unused)
{
	hammer2_inode_t *iroot;
	hammer2_chain_t *chain;

	/*
	 * Cleanup our reference on iroot.  iroot is (should) not be needed
	 * by the flush code.
	 */
	iroot = pmp->iroot;
	if (iroot) {
		/* Remove the cluster index from the group. */
		hammer2_mtx_ex(&iroot->lock);
		chain = iroot->cluster.array[clindex].chain;
		iroot->cluster.array[clindex].chain = NULL;
		pmp->pfs_types[clindex] = HAMMER2_PFSTYPE_NONE;
		hammer2_mtx_unlock(&iroot->lock);

		/* Release the chain. */
		if (chain) {
			atomic_set_int(&chain->flags, HAMMER2_CHAIN_RELEASE);
			hammer2_chain_drop(chain);
		}
	}
}

void
hammer2_pfsfree(hammer2_pfs_t *pmp)
{
	hammer2_inode_t *iroot;
	hammer2_chain_t *chain;
	int i, chains_still_present = 0;

	KKASSERT(!(pmp->flags & HAMMER2_PMPF_WAITING));

	/* Cleanup our reference on iroot. */
	if (pmp->flags & HAMMER2_PMPF_SPMP)
		TAILQ_REMOVE(&hammer2_spmplist, pmp, mntentry);
	else
		TAILQ_REMOVE(&hammer2_pfslist, pmp, mntentry);

	/* Clean up iroot. */
	iroot = pmp->iroot;
	if (iroot) {
		for (i = 0; i < iroot->cluster.nchains; ++i) {
			chain = iroot->cluster.array[i].chain;
			if (chain && !RB_EMPTY(&chain->core.rbtree))
				chains_still_present = 1;
		}
		KASSERTMSG(iroot->refs == 1,
		    "iroot inum %016llx refs %d not 1",
		    (long long)iroot->meta.inum, iroot->refs);
		hammer2_inode_drop(iroot);
		pmp->iroot = NULL;
	}

	/* Free remaining pmp resources. */
	if (chains_still_present) {
		KKASSERT(pmp->mp);
		hprintf("PFS still in use\n");
	} else {
		hammer2_spin_destroy(&pmp->blockset_spin);
		hammer2_spin_destroy(&pmp->list_spin);
		for (i = 0; i < HAMMER2_IHASH_SIZE; i++) {
			hammer2_lk_destroy(&pmp->xop_lock[i]);
			hammer2_lkc_destroy(&pmp->xop_cv[i]);
		}
		hammer2_lk_destroy(&pmp->trans_lock);
		hammer2_lkc_destroy(&pmp->trans_cv);
		hammer2_inum_hash_destroy(pmp);
		hammer2_ipdep_destroy(pmp); /* XXX Linux: hashdestroy(9) */
		hfree(pmp, M_HAMMER2, sizeof(*pmp));
	}
}

void
hammer2_pfsfree_scan(hammer2_dev_t *hmp, int which)
{
	hammer2_pfs_t *pmp;
	hammer2_inode_t *iroot;
	hammer2_chain_t *rchain;
	struct hammer2_pfslist *wlist;
	int i;

	if (which == 0)
		wlist = &hammer2_pfslist;
	else
		wlist = &hammer2_spmplist;
again:
	TAILQ_FOREACH(pmp, wlist, mntentry) {
		if ((iroot = pmp->iroot) == NULL)
			continue;

		/* Determine if this PFS is affected. */
		for (i = 0; i < HAMMER2_MAXCLUSTER; ++i)
			if (pmp->pfs_hmps[i] == hmp)
				break;
		if (i == HAMMER2_MAXCLUSTER)
			continue;

		hammer2_vfs_sync_pmp(pmp, MNT_WAIT);

		/*
		 * Lock the inode and clean out matching chains.
		 * Note that we cannot use hammer2_inode_lock_*()
		 * here because that would attempt to validate the
		 * cluster that we are in the middle of ripping
		 * apart.
		 */
		hammer2_mtx_ex(&iroot->lock);

		/* Remove the chain from matching elements of the PFS. */
		for (i = 0; i < HAMMER2_MAXCLUSTER; ++i) {
			if (pmp->pfs_hmps[i] != hmp)
				continue;
			rchain = iroot->cluster.array[i].chain;
			iroot->cluster.array[i].chain = NULL;
			pmp->pfs_types[i] = HAMMER2_PFSTYPE_NONE;
			if (pmp->pfs_names[i]) {
				hstrfree(pmp->pfs_names[i]);
				pmp->pfs_names[i] = NULL;
			}
			if (rchain) {
				hammer2_chain_drop(rchain);
				/* focus hint */
				if (iroot->cluster.focus == rchain)
					iroot->cluster.focus = NULL;
			}
			pmp->pfs_hmps[i] = NULL;
		}
		hammer2_mtx_unlock(&iroot->lock);

		/* Cleanup trailing chains.  Gaps may remain. */
		for (i = HAMMER2_MAXCLUSTER - 1; i >= 0; --i)
			if (pmp->pfs_hmps[i])
				break;
		iroot->cluster.nchains = i + 1;

		/* If the PMP has no elements remaining we can destroy it. */
		if (iroot->cluster.nchains == 0) {
			/*
			 * If this was the hmp's spmp, we need to clean
			 * a little more stuff out.
			 */
			if (hmp->spmp == pmp) {
				hmp->spmp = NULL;
				hmp->vchain.pmp = NULL;
				hmp->fchain.pmp = NULL;
			}

			/* Free the pmp and restart the loop. */
			hammer2_pfsfree(pmp);
			goto again;
		}
	}
}
