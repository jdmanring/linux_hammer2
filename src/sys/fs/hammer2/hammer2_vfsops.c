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
#include "hammer2_mount.h"

#include <linux/fs_context.h>
#include <linux/fs_parser.h>
#include <linux/mm.h>
#include <linux/module.h>

/*
 * The globals upstream keeps in this file.  Nothing in the tree defined
 * them until now, which is why nothing linked: every carried file that
 * reads hammer2_dio_limit or bumps hammer2_count_chain_allocated
 * declares it extern in hammer2.h and waits for this file.
 *
 * hammer2_mntlist, the global list of hammer2_dev, is still not here.
 * It is the mount path's and lands with it rather than sitting unused:
 * a definition with no user is what the syntax gate flags, and
 * silencing that would hide the fact that this file is part written.
 */
hammer2_pfslist_t hammer2_pfslist;
static hammer2_pfslist_t hammer2_spmplist;

hammer2_lk_t hammer2_mntlk;

uma_zone_t hammer2_zone_inode;
uma_zone_t hammer2_zone_xops;

int hammer2_cluster_meta_read = 1;	/* for physical read-ahead */
int hammer2_cluster_data_read = 4;	/* for physical read-ahead */
int hammer2_cluster_write;		/* for physical write clustering */
int hammer2_dedup_enable = 1;
int hammer2_count_inode_allocated;
int hammer2_count_chain_allocated;
int hammer2_count_chain_modified;
int hammer2_count_dio_allocated;
int hammer2_dio_limit = 256;
int hammer2_bulkfree_tps = 5000;
int hammer2_limit_scan_depth;
int hammer2_limit_saved_chains;
int hammer2_always_compress;

#ifdef HAMMER2_MALLOC
int malloc_leak_m_hammer2;
int malloc_leak_m_hammer2_lz4;
int malloc_leak_m_temp;
#endif

/*
 * XXX Linux: upstream exports the block above through sysctl(9) under
 * vfs.hammer2, read-write for the tunables and read-only for the
 * counters.  Linux's nearest thing that costs nothing to build is
 * module_param_named(), which puts the read-write half under
 * /sys/module/hammer2/parameters/ at 0644.  The names are upstream's
 * with the hammer2_ prefix dropped, exactly as sysctl drops it.
 *
 * Only the tunables.  Upstream's read-only sysctls, the four allocation
 * counters and supported_version, are NOT here and cannot be, because
 * perm is visibility in sysfs and nothing else: a 0444 parameter is
 * still settable on the insmod command line
 * (include/linux/moduleparam.h says so in as many words at the kernel of
 * record).  A counter that can be handed a value at load is a counter
 * hammer2_assert_clean() cannot trust, in both directions -- a nonzero
 * at load reports a leak that never happened, and a negative one hides a
 * real leak under a sum that reaches zero.  That is the check this file
 * moved to the unload path to make work, so exposing the counters this
 * way would take it back.  supported_version goes with them rather than
 * being settable to a version the code does not support; there is no
 * variable for it until there is somewhere read-only to put it.
 *
 * DEFER(a second filesystem-wide knob wants a per-mount value): move
 * these to /sys/fs/hammer2/, which is where ext4 and btrfs put theirs.
 * That is also the only place the counters and supported_version can go,
 * so the same move carries them.  A module parameter is one value for
 * every mount on the machine, which is what sysctl gave upstream too, so
 * nothing is lost on the tunables until that day.
 */
module_param_named(cluster_meta_read, hammer2_cluster_meta_read, int, 0644);
module_param_named(cluster_data_read, hammer2_cluster_data_read, int, 0644);
module_param_named(cluster_write, hammer2_cluster_write, int, 0644);
module_param_named(dedup_enable, hammer2_dedup_enable, int, 0644);
module_param_named(dio_limit, hammer2_dio_limit, int, 0644);
module_param_named(bulkfree_tps, hammer2_bulkfree_tps, int, 0644);
module_param_named(limit_scan_depth, hammer2_limit_scan_depth, int, 0644);
module_param_named(limit_saved_chains, hammer2_limit_saved_chains, int, 0644);
module_param_named(always_compress, hammer2_always_compress, int, 0644);

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
static void
hammer2_ipdep_init(hammer2_pfs_t *pmp)
{
	int i;

	pmp->ipdep_lists = hmalloc(
	    HAMMER2_IHASH_SIZE * sizeof(*pmp->ipdep_lists),
	    M_HAMMER2, M_WAITOK | M_ZERO);
	for (i = 0; i < HAMMER2_IHASH_SIZE; i++)
		LIST_INIT(&pmp->ipdep_lists[i]);
	pmp->ipdep_mask = HAMMER2_IHASH_SIZE - 1;
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
		hammer2_ipdep_init(pmp);

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

/*
 * Upstream calls this from its vfs_init, where on Linux it can only read
 * globals the module loader has just zeroed.  It is moved to the unload
 * path, which is where the counters can be anything but zero and so the
 * only place the check can fail.  Zero here is the healthy signature at
 * unload and the inert one at load, and reading it in the wrong place
 * would have made a leak check that cannot report a leak.
 */
static int
hammer2_assert_clean(void)
{
	int error = 0;

	if (hammer2_count_inode_allocated > 0) {
		hprintf("%d inode left\n", hammer2_count_inode_allocated);
		error = EINVAL;
	}
	KKASSERT(hammer2_count_inode_allocated == 0);

	if (hammer2_count_chain_allocated > 0) {
		hprintf("%d chain left\n", hammer2_count_chain_allocated);
		error = EINVAL;
	}
	KKASSERT(hammer2_count_chain_allocated == 0);

	if (hammer2_count_chain_modified > 0) {
		hprintf("%d modified chain left\n",
		    hammer2_count_chain_modified);
		error = EINVAL;
	}
	KKASSERT(hammer2_count_chain_modified == 0);

	if (hammer2_count_dio_allocated > 0) {
		hprintf("%d dio left\n", hammer2_count_dio_allocated);
		error = EINVAL;
	}
	KKASSERT(hammer2_count_dio_allocated == 0);

	return (error);
}

/*
 * XXX Linux: upstream derives this from desiredvnodes, FreeBSD's target
 * size for the vnode cache, which is itself derived from physical
 * memory.  Linux exports no equivalent, so the derivation is made from
 * physical memory directly and upstream's clamp is kept unchanged.  The
 * clamp does most of the work: at pages/10 the low end is only reached
 * below 40 MiB of RAM and the high end only above 40 TiB, so on any
 * machine this module will run on the value is one tenth of the page
 * count, and the factor of five to saved_chains is upstream's.
 *
 * hammer2_limit_dirty_chains is a local upstream too, with a comment
 * saying it was a sysctl once.  Nothing in this tree reads it; only
 * hammer2_limit_saved_chains has callers, in hammer2_bulkfree.c.
 */
static void
hammer2_init_limits(void)
{
	unsigned long dirty_chains = totalram_pages() / 10;

	if (dirty_chains > HAMMER2_LIMIT_DIRTY_CHAINS)
		dirty_chains = HAMMER2_LIMIT_DIRTY_CHAINS;
	if (dirty_chains < 1000)
		dirty_chains = 1000;
	hammer2_limit_saved_chains = (int)(dirty_chains * 5);
}

/*
 * XXX Linux: the mount options.
 *
 * FreeBSD's mount_hammer2 hands the kernel an int of HMNT2_* bits under
 * the name "hflags", because that is what nmount(2) gives it.  Only two
 * bits are defined, and hammer2_mount() rejects one of them outright:
 * HMNT2_LOCAL is broken in DragonFly, so the whole of hflags that a
 * mount can actually set is HMNT2_EMERG.  A single named flag is what
 * Linux would spell that, so this port does, and there is no numeric
 * hflags option to get wrong.  hammer2_mount.h keeps the bits, since
 * the carried core reads pmp->hflags against them.
 *
 * "source" is not here.  Returning -ENOPARAM for a key this table does
 * not know sends it to vfs_parse_fs_param_source(), which is the
 * generic handling and sets fc->source; read at v7.2 in
 * fs/fs_context.c, vfs_parse_fs_param().  The device-and-label split
 * that FreeBSD does on its "from" option happens where fc->source is
 * final, which is ->get_tree and not here.
 */
enum hammer2_param {
	Opt_emerg,
};

static const struct fs_parameter_spec hammer2_fs_parameters[] = {
	fsparam_flag("emerg", Opt_emerg),
	{}
};

/*
 * The fs_context private state.  FreeBSD reads its options straight out
 * of the mount structure inside hammer2_mount(); Linux parses them one
 * at a time, before there is a super_block, so they have to be kept
 * somewhere until ->get_tree runs.
 */
struct hammer2_fs_context {
	int	hflags;
};

static int
hammer2_parse_param(struct fs_context *fc, struct fs_parameter *param)
{
	struct hammer2_fs_context *ctx = fc->fs_private;
	struct fs_parse_result result;
	int opt;

	opt = fs_parse(fc, hammer2_fs_parameters, param, &result);
	if (opt < 0)
		return (opt);	/* Linux: -ENOPARAM falls through to source */

	switch (opt) {
	case Opt_emerg:
		ctx->hflags |= HMNT2_EMERG;
		break;
	default:
		return (-EINVAL);
	}

	return (0);
}

static void
hammer2_free_fs_context(struct fs_context *fc)
{
	kfree(fc->fs_private);
	fc->fs_private = NULL;
}

static int
hammer2_get_tree(struct fs_context *fc __maybe_unused)
{
	/*
	 * DEFER(the fill-super lands): until then the
	 * filesystem is registered and every mount of it fails.  The
	 * design this owes is in this file's opening comment.  Returning
	 * an error rather than stubbing a success is the point: a mount
	 * that appears to work and has no root is the failure this port
	 * cannot afford to make quiet.
	 */
	return (-EINVAL);	/* Linux: the VFS half is negative */
}

/*
 * DEFER(a super_block exists to reconfigure): ->reconfigure, which is
 * where FreeBSD's MNT_UPDATE branch of hammer2_mount() goes.  Without
 * it the VFS refuses a remount, which is the right answer while there
 * is nothing to remount.
 */
static const struct fs_context_operations hammer2_context_ops = {
	.parse_param	= hammer2_parse_param,
	.get_tree	= hammer2_get_tree,
	.free		= hammer2_free_fs_context,
};

static int
hammer2_init_fs_context(struct fs_context *fc)
{
	struct hammer2_fs_context *ctx;

	ctx = kzalloc_obj(struct hammer2_fs_context);
	if (ctx == NULL)
		return (-ENOMEM);

	fc->fs_private = ctx;
	fc->ops = &hammer2_context_ops;

	return (0);
}

/*
 * kill_anon_super() runs first and the private teardown after, which is
 * the order btrfs_kill_super() uses at v7.2: the generic call drops
 * every inode and the root dentry, and those hold the references the
 * teardown is about to free.
 *
 * DEFER(->get_tree constructs a super_block): the teardown itself,
 * hammer2_close_devvp() and the unmount helpers.  Nothing reaches here
 * while hammer2_get_tree() cannot succeed.
 */
static void
hammer2_kill_sb(struct super_block *sb)
{
	kill_anon_super(sb);
}

static struct file_system_type hammer2_fs_type = {
	.owner			= THIS_MODULE,
	.name			= "hammer2",
	.init_fs_context	= hammer2_init_fs_context,
	.parameters		= hammer2_fs_parameters,
	.kill_sb		= hammer2_kill_sb,
	.fs_flags		= FS_REQUIRES_DEV,
};
MODULE_ALIAS_FS("hammer2");

static int __init
hammer2_module_init(void)
{
	int error;

	/*
	 * XXX Linux: upstream asserts that uma_zcreate(9) never returns
	 * NULL.  kmem_cache_create() can, so the assertion becomes an
	 * error path.  This is the one place in the shim's uma_ mapping
	 * where the Linux primitive is weaker than the BSD one.
	 */
	hammer2_zone_inode = uma_zcreate("h2inozone", sizeof(hammer2_inode_t));
	if (hammer2_zone_inode == NULL)
		return (-ENOMEM);

	hammer2_zone_xops = uma_zcreate("h2xopszone", sizeof(hammer2_xop_t));
	if (hammer2_zone_xops == NULL) {
		error = -ENOMEM;
		goto fail_xops;
	}

	hammer2_lk_init(&hammer2_mntlk, "h2_mnt");
	TAILQ_INIT(&hammer2_pfslist);
	TAILQ_INIT(&hammer2_spmplist);
	hammer2_init_limits();

	error = register_filesystem(&hammer2_fs_type);
	if (error)
		goto fail_register;

	return (0);

fail_register:
	hammer2_lk_destroy(&hammer2_mntlk);
	uma_zdestroy(hammer2_zone_xops);
	hammer2_zone_xops = NULL;
fail_xops:
	uma_zdestroy(hammer2_zone_inode);
	hammer2_zone_inode = NULL;

	return (error);
}

static void __exit
hammer2_module_exit(void)
{
	unregister_filesystem(&hammer2_fs_type);
	hammer2_lk_destroy(&hammer2_mntlk);

	/*
	 * Before the zones, not after.  A nonzero counter here means live
	 * objects in the cache about to be destroyed, and
	 * kmem_cache_destroy() complains about that itself; running the
	 * check first puts the message that says which counter ahead of
	 * the one that says the cache was not empty.
	 */
	hammer2_assert_clean();

	uma_zdestroy(hammer2_zone_xops);
	hammer2_zone_xops = NULL;
	uma_zdestroy(hammer2_zone_inode);
	hammer2_zone_inode = NULL;
}

module_init(hammer2_module_init);
module_exit(hammer2_module_exit);

/*
 * Dual BSD/GPL, not BSD alone: the tree is BSD-3-Clause, which the
 * kernel lists in LICENSES/preferred/, and the dual tag is what keeps
 * EXPORT_SYMBOL_GPL symbols reachable.  doc/README.kernel-style.md has
 * the reasoning.
 */
MODULE_LICENSE("Dual BSD/GPL");
MODULE_DESCRIPTION("HAMMER2 filesystem");
MODULE_AUTHOR("James Manring <james_manring@yahoo.com>");
