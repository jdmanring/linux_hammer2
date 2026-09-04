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
#include <linux/statfs.h>	/* Linux: uuid_to_fsid, struct kstatfs */

static int hammer2_recovery(hammer2_dev_t *);
static int hammer2_fixup_pfses(hammer2_dev_t *);
static void hammer2_update_pmps(hammer2_dev_t *);
static void hammer2_mount_helper(struct super_block *, hammer2_pfs_t *);
static void hammer2_unmount_helper(struct super_block *, hammer2_pfs_t *,
    hammer2_dev_t *);
static void hammer2_evict_inode(struct inode *);
static const struct super_operations hammer2_sops;

/*
 * The globals upstream keeps in this file.  Nothing in the tree defined
 * them until now, which is why nothing linked: every carried file that
 * reads hammer2_dio_limit or bumps hammer2_count_chain_allocated
 * declares it extern in hammer2.h and waits for this file.
 */
TAILQ_HEAD(hammer2_mntlist, hammer2_dev);	/* <-> hammer2_dev::mntentry */
typedef struct hammer2_mntlist hammer2_mntlist_t;
static hammer2_mntlist_t hammer2_mntlist;

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
 * - a static with no user is a warning and a static FUNCTION with no
 *   user is not: script/test-syntax.sh passes -Wno-unused-function,
 *   because the carried files arrive with statics their unported
 *   callers would have used.  So nothing mechanical stops an
 *   unreachable helper from landing here ahead of its caller, and the
 *   rule that none does is a discipline rather than a gate.  The
 *   converse IS a gate, and caught a missing carry the first time this
 *   file used a forward declaration: a static DECLARED and never
 *   defined is -Wundefined-internal in clang and "used but never
 *   defined" in gcc, and neither is suppressed here.  The two halves of
 *   what looks like one check are not both on.
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
		TAILQ_INIT(&pmp->sbdev_list);	/* Linux */
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

/*
 * The device half of FreeBSD's hammer2_mount().  Given fc->source, this
 * ends with an hmp on hammer2_mntlist whose volumes are open, whose
 * vchain and fchain are set up, whose super-root inode is read, and whose
 * PFSs are on hammer2_pfslist.  The PFS half, which picks one of those
 * PFSs by label and builds a root inode and a root dentry, is what
 * remains.
 *
 * Two orderings differ from FreeBSD and neither is a preference.
 *
 * sget_fc() comes before the device is opened, where FreeBSD is handed a
 * struct mount and opens whenever it likes.  Opening a block device
 * claims it for a holder, the holder ops any filesystem passes are
 * fs_holder_ops, and all four of its callbacks start at
 * bdev_super_lock(), which does sb = bdev->bd_holder and then requires
 * s_root and SB_ACTIVE.  The holder has to be a live superblock, so
 * there has to be one before the open.  btrfs orders it the same way.
 * Both read at the kernel of record.
 *
 * The superblock is created with a NULL test function, so every mount
 * gets a fresh one and sget_fc() never hands back an existing
 * superblock.  That is deliberate: upstream answers "is this PFS already
 * mounted" with an explicit pmp->mp check, and a test function would be
 * a second answer to the same question that could disagree with the
 * first.  One question, one place.
 */
static int
hammer2_get_tree(struct fs_context *fc)
{
	struct hammer2_fs_context *ctx = fc->fs_private;
	struct super_block *sb;
	struct inode *root_inode;
	hammer2_dev_t *hmp = NULL, *hmp_tmp, *force_local;
	hammer2_pfs_t *pmp = NULL, *spmp;
	hammer2_devvp_list_t devvpl;
	hammer2_devvp_t *e, *e_tmp;
	hammer2_chain_t *parent, *schain, *chain;
	const hammer2_inode_data_t *ripdata;
	hammer2_key_t key_dummy, key_next, lhc;
	hammer2_xop_head_t *xop;
	char *devstr, *label;
	int rdonly = (fc->sb_flags & SB_RDONLY) != 0;
	int i, error, devvp_found;

	/*
	 * XXX Linux: FreeBSD reads the device out of the "from" mount
	 * option and errors if it is absent.  fc->source is the same
	 * string, and it is checked here for the same reason: this
	 * filesystem is FS_REQUIRES_DEV, but the VFS only enforces that
	 * through get_tree_bdev(), which a multi-device filesystem cannot
	 * use.  Nothing else would reject a bare "mount -t hammer2 none".
	 */
	if (fc->source == NULL || fc->source[0] == '\0')
		return (-EINVAL);	/* Linux: the VFS half is negative */

	/*
	 * DEFER(recovery is exercised on a device): refuse a read-write
	 * mount.  Upstream replays an interrupted flush at mount time,
	 * and that code is carried, in hammer2_recovery() and
	 * hammer2_fixup_pfses() below.  It has never been run: it writes,
	 * and no module has been loaded, so a read-write mount would be
	 * the first exercise of a write path on a filesystem whose last
	 * flush was cut short.  A read-only mount is refused nothing,
	 * because the recovery upstream runs is conditional on the mount
	 * being read-write in the first place.
	 *
	 * The refusal sits here rather than at the recovery site because
	 * that site is reached only after the device is open and the
	 * super-root is read.  Refusing before either has happened
	 * refuses the operation; refusing there would unwind one.
	 * hammer2_reconfigure() covers the remount.
	 */
	if (!rdonly) {
		hprintf("read-write mount refused, flush recovery has never been exercised, mount -o ro\n");
		return (-EROFS);	/* Linux: the VFS half is negative */
	}

	/*
	 * XXX Linux: FreeBSD copies the device string into an MNAMELEN
	 * stack buffer because the '@' split writes a NUL into it.  A
	 * private copy is still needed for that reason, but it is taken
	 * on the heap and sized to the string: MNAMELEN is 1024 and this
	 * is a kernel stack.  fc->source itself must not be written to,
	 * because a later reconfigure and every mount error message read
	 * it back whole.
	 */
	devstr = hstrdup(fc->source);
	debug_hprintf("devstr \"%s\"\n", devstr);

	/*
	 * Extract device and label, automatically mount @DATA if no label
	 * specified.  Error out if no label or device is specified.  This is
	 * a convenience to match the default label created by newfs_hammer2,
	 * our preference is that a label always be specified.
	 *
	 * NOTE: We allow 'mount @LABEL <blah>'... that is, a mount command
	 *	 that does not specify a device, as long as some HAMMER2 label
	 *	 has already been mounted from that device.  This makes
	 *	 mounting snapshots a lot easier.
	 */
	label = strchr(devstr, '@');
	if (label == NULL || label[1] == 0) {
		/*
		 * DragonFly HAMMER2 uses either "BOOT", "ROOT" or "DATA"
		 * based on label[-1].
		 */
		label = "DATA";
	} else {
		*label = '\0';
		label++;
	}

	debug_hprintf("device \"%s\" label \"%s\" rdonly %d\n",
	    devstr, label, rdonly);

	/*
	 * Linux: the superblock has to exist before a device can be opened
	 * under it, for the holder reason in this function's comment.  From
	 * here on every failure goes through deactivate_locked_super(),
	 * which reaches ->kill_sb, so anything hung off the superblock is
	 * unwound by the VFS and anything not yet hung off it is unwound
	 * here.
	 */
	sb = sget_fc(fc, NULL, set_anon_super_fc);
	if (IS_ERR(sb))
		return (PTR_ERR(sb));	/* Linux: already negative */

	/* Initialize all device vnodes. */
	TAILQ_INIT(&devvpl);
	error = hammer2_init_devvp(sb, devstr, &devvpl);
	if (error) {
		hprintf("failed to initialize devvp in %s\n", devstr);
		hammer2_cleanup_devvp(&devvpl);
		hstrfree(devstr);
		deactivate_locked_super(sb);
		return (-error);	/* Linux: the VFS half is negative */
	}

	/*
	 * Determine if the device has already been mounted.  After this
	 * check hmp will be non-NULL if we are doing the second or more
	 * HAMMER2 mounts from the same device.
	 */
	hammer2_lk_ex(&hammer2_mntlk);
	if (!TAILQ_EMPTY(&devvpl)) {
		/*
		 * XXX Linux: FreeBSD matches the device vnode pointer and
		 * falls back to the underlying device, because devfs can
		 * hand out more than one vnode for one device.  There is no
		 * vnode here and nothing is open yet, so the fallback is
		 * the whole comparison: e->devno is what lookup_bdev()
		 * resolved and is the same quantity as v_rdev.
		 */
		TAILQ_FOREACH(hmp_tmp, &hammer2_mntlist, mntentry) {
			TAILQ_FOREACH(e_tmp, &hmp_tmp->devvp_list, entry) {
				devvp_found = 0;
				TAILQ_FOREACH(e, &devvpl, entry) {
					if (e_tmp->devno == e->devno)
						devvp_found = 1;
				}
				if (!devvp_found)
					goto next_hmp;
			}
			hmp = hmp_tmp;
			debug_hprintf("hmp matched\n");
			/*
			 * Linux: a secondary mount reuses the open this
			 * device already has, and registers its own
			 * superblock against it in hammer2_register_sb(),
			 * so the device's callbacks reach every mount on
			 * it at 7.3 and above.  Below 7.3 the holder is a
			 * superblock and only the first mount's is reached.
			 */
			break;
next_hmp:
			continue;
		}
		/*
		 * XXX Linux: FreeBSD checks here that a device it has not
		 * matched is not mounted by something else, on a
		 * vfs_mountedon() call its own port already has commented
		 * out.  Linux answers that question at the open instead:
		 * bdev_file_open_by_path() claims the device for a holder
		 * and fails with EBUSY if another holder has it, so a
		 * device carrying some other filesystem is refused by
		 * hammer2_open_devvp() below rather than here.
		 */
	} else {
		/* Match the label to a pmp already probed. */
		TAILQ_FOREACH(pmp, &hammer2_pfslist, mntentry) {
			for (i = 0; i < HAMMER2_MAXCLUSTER; ++i) {
				if (pmp->pfs_names[i] &&
				    strcmp(pmp->pfs_names[i], label) == 0) {
					hmp = pmp->pfs_hmps[i];
					break;
				}
			}
			if (hmp)
				break;
		}
		if (hmp == NULL) {
			hprintf("PFS label \"%s\" not found\n", label);
			hammer2_cleanup_devvp(&devvpl);
			hammer2_lk_unlock(&hammer2_mntlk);
			hstrfree(devstr);
			deactivate_locked_super(sb);
			return (-ENOENT);
		}
	}

	/*
	 * Open the device if this isn't a secondary mount and construct the
	 * HAMMER2 device mount (hmp).
	 */
	if (hmp == NULL) {
		/* Now open the device(s). */
		KKASSERT(!TAILQ_EMPTY(&devvpl));
		error = hammer2_open_devvp(sb, &devvpl);
		if (error) {
			hammer2_close_devvp(&devvpl);
			hammer2_cleanup_devvp(&devvpl);
			hammer2_lk_unlock(&hammer2_mntlk);
			hstrfree(devstr);
			deactivate_locked_super(sb);
			return (-error);
		}

		/* Construct volumes and link with device vnodes. */
		hmp = hmalloc(sizeof(*hmp), M_HAMMER2, M_WAITOK | M_ZERO);
		hmp->bdev_file = NULL;
		error = hammer2_init_volumes(&devvpl, hmp->volumes,
		    &hmp->voldata, &hmp->volhdrno, &hmp->bdev_file);
		if (error) {
			hammer2_close_devvp(&devvpl);
			hammer2_cleanup_devvp(&devvpl);
			hammer2_lk_unlock(&hammer2_mntlk);
			hfree(hmp, M_HAMMER2, sizeof(*hmp));
			hstrfree(devstr);
			deactivate_locked_super(sb);
			return (-error);
		}
		if (!hmp->bdev_file) {
			hprintf("failed to initialize root volume\n");
			hammer2_unmount_helper(NULL, NULL, hmp);
			hammer2_lk_unlock(&hammer2_mntlk);
			hstrfree(devstr);
			deactivate_locked_super(sb);
			return (-EINVAL);
		}

		hmp->rdonly = rdonly;
		hmp->hflags = ctx->hflags & HMNT2_DEVFLAGS;

		TAILQ_INSERT_TAIL(&hammer2_mntlist, hmp, mntentry);
		hammer2_mtx_init(&hmp->iohash_lock, "h2dev_iohash");
		hammer2_io_hash_init(hmp);

		hammer2_lk_init(&hmp->vollk, "h2dev_vol");
		hammer2_lk_init(&hmp->bulklk, "h2dev_bulk");
		hammer2_lk_init(&hmp->bflk, "h2dev_bf");

		/*
		 * vchain setup.  vchain.data is embedded.
		 * vchain.refs is initialized and will never drop to 0.
		 */
		hmp->vchain.hmp = hmp;
		hmp->vchain.refs = 1;
		hmp->vchain.data = (void *)&hmp->voldata;
		hmp->vchain.bref.type = HAMMER2_BREF_TYPE_VOLUME;
		hmp->vchain.bref.data_off = 0 | HAMMER2_PBUFRADIX;
		hammer2_chain_init(&hmp->vchain);

		/*
		 * fchain setup.  fchain.data is embedded.
		 * fchain.refs is initialized and will never drop to 0.
		 *
		 * The data is not used but needs to be initialized to
		 * pass assertion muster.  We use this chain primarily
		 * as a placeholder for the freemap's top-level radix tree
		 * so it does not interfere with the volume's topology
		 * radix tree.
		 */
		hmp->fchain.hmp = hmp;
		hmp->fchain.refs = 1;
		hmp->fchain.data = (void *)&hmp->voldata.freemap_blockset;
		hmp->fchain.bref.type = HAMMER2_BREF_TYPE_FREEMAP;
		hmp->fchain.bref.data_off = 0 | HAMMER2_PBUFRADIX;
		hmp->fchain.bref.methods =
		    HAMMER2_ENC_CHECK(HAMMER2_CHECK_FREEMAP) |
		    HAMMER2_ENC_COMP(HAMMER2_COMP_NONE);
		hammer2_chain_init(&hmp->fchain);

		/* Initialize volume header related fields. */
		KKASSERT(hmp->voldata.magic == HAMMER2_VOLUME_ID_HBO ||
		    hmp->voldata.magic == HAMMER2_VOLUME_ID_ABO);
		hmp->volsync = hmp->voldata;
		hmp->free_reserved = hmp->voldata.allocator_size / 20;

		/*
		 * Must use hmp instead of volume header for these two
		 * in order to handle volume versions transparently.
		 */
		if (hmp->voldata.version >= HAMMER2_VOL_VERSION_MULTI_VOLUMES) {
			hmp->nvolumes = hmp->voldata.nvolumes;
			hmp->total_size = hmp->voldata.total_size;
		} else {
			hmp->nvolumes = 1;
			hmp->total_size = hmp->voldata.volu_size;
		}
		KKASSERT(hmp->nvolumes > 0);

		/* Move devvpl entries to hmp. */
		TAILQ_INIT(&hmp->devvp_list);
		while ((e = TAILQ_FIRST(&devvpl)) != NULL) {
			TAILQ_REMOVE(&devvpl, e, entry);
			TAILQ_INSERT_TAIL(&hmp->devvp_list, e, entry);
		}
		KKASSERT(TAILQ_EMPTY(&devvpl));
		KKASSERT(!TAILQ_EMPTY(&hmp->devvp_list));

		/*
		 * Really important to get these right or teardown code
		 * will get confused.
		 */
		hmp->spmp = hammer2_pfsalloc(NULL, NULL, hmp);
		spmp = hmp->spmp;
		spmp->pfs_hmps[0] = hmp;

		/*
		 * Dummy-up vchain and fchain's modify_tid.
		 * mirror_tid is inherited from the volume header.
		 */
		hmp->vchain.bref.mirror_tid = hmp->voldata.mirror_tid;
		hmp->vchain.bref.modify_tid = hmp->vchain.bref.mirror_tid;
		hmp->vchain.pmp = spmp;
		hmp->fchain.bref.mirror_tid = hmp->voldata.freemap_tid;
		hmp->fchain.bref.modify_tid = hmp->fchain.bref.mirror_tid;
		hmp->fchain.pmp = spmp;

		/*
		 * First locate the super-root inode, which is key 0
		 * relative to the volume header's blockset.
		 *
		 * Then locate the root inode by scanning the directory keyspace
		 * represented by the label.
		 */
		parent = hammer2_chain_lookup_init(&hmp->vchain, 0);
		schain = hammer2_chain_lookup(&parent, &key_dummy,
		    HAMMER2_SROOT_KEY, HAMMER2_SROOT_KEY, &error, 0);
		hammer2_chain_lookup_done(parent);
		if (schain == NULL) {
			hprintf("invalid super-root\n");
			hammer2_unmount_helper(NULL, NULL, hmp);
			hammer2_lk_unlock(&hammer2_mntlk);
			hstrfree(devstr);
			deactivate_locked_super(sb);
			return (-EINVAL);
		}
		if (schain->error) {
			hprintf("chain error %08x reading super-root\n",
			    schain->error);
			hammer2_chain_unlock(schain);
			hammer2_chain_drop(schain);
			schain = NULL;
			hammer2_unmount_helper(NULL, NULL, hmp);
			hammer2_lk_unlock(&hammer2_mntlk);
			hstrfree(devstr);
			deactivate_locked_super(sb);
			return (-EINVAL);
		}

		/*
		 * The super-root always uses an inode_tid of 1 when
		 * creating PFSs.
		 */
		spmp->inode_tid = 1;
		spmp->modify_tid = schain->bref.modify_tid + 1;

		/*
		 * Sanity-check schain's pmp and finish initialization.
		 * Any chain belonging to the super-root topology should
		 * have a NULL pmp (not even set to spmp).
		 */
		ripdata = &schain->data->ipdata;
		KKASSERT(schain->pmp == NULL);
		spmp->pfs_clid = ripdata->meta.pfs_clid;

		/*
		 * Replace the dummy spmp->iroot with a real one.  It's
		 * easier to just do a wholesale replacement than to try
		 * to update the chain and fixup the iroot fields.
		 *
		 * The returned inode is locked with the supplied cluster.
		 */
		xop = uma_zalloc(hammer2_zone_xops, M_WAITOK | M_ZERO);
		hammer2_dummy_xop_from_chain(xop, schain);
		hammer2_inode_drop(spmp->iroot);
		spmp->iroot = hammer2_inode_get(spmp, xop, -1, -1);
		spmp->spmp_hmp = hmp;
		spmp->pfs_types[0] = ripdata->meta.pfs_type;
		spmp->rdonly = rdonly;
		hammer2_inode_ref(spmp->iroot);
		hammer2_inode_unlock(spmp->iroot);
		hammer2_chain_unlock(schain);
		hammer2_chain_drop(schain);
		schain = NULL;
		uma_zfree(hammer2_zone_xops, xop);
		/* Leave spmp->iroot with one ref. */

		/*
		 * DEFER(recovery is exercised on a device): upstream runs
		 * this on a read-write mount to replay an interrupted
		 * flush, and it is carried above.  It WRITES, so it is
		 * reached only when the mount is read-write, and no mount
		 * is: hammer2_get_tree() refuses that before the device is
		 * opened and hammer2_reconfigure() refuses the remount
		 * that would arrive at the same state sideways.  Carrying
		 * the code and lifting those refusals are different
		 * things, and the second one needs a loaded module and a
		 * scratch device with an interrupted flush on it, which is
		 * what this trigger names.
		 *
		 * The teardown a few lines below flushes vchain and fchain
		 * when either carries a HAMMER2_CHAIN_FLUSH_MASK bit, and
		 * neither does: the four bits in that mask are set at
		 * eleven sites in nine functions, counted on 2026-08-26 by
		 * grepping atomic_set_int() for each of the four, and
		 * those nine are hammer2_chain_modify(),
		 * hammer2_chain_create(), hammer2_chain_setflush(),
		 * hammer2_chain_lastdrop(), the two chain deletes, the two
		 * flush functions and hammer2_voldata_modify().  The
		 * device half calls none of them.  The one it reaches
		 * indirectly is lastdrop, through the drop of a chain it
		 * only read, and that sets DESTROY on the chain being
		 * dropped and propagates it downward to children, never up
		 * to an anchor whose refs never reach zero.  So the flush
		 * in the teardown is a no-op here.
		 */
		if (!hmp->rdonly) {
			error = hammer2_recovery(hmp);
			if (error == 0)
				error |= hammer2_fixup_pfses(hmp);
			/* XXX do something with error */
		}

		/*
		 * A false-positive lock order reversal may be detected.
		 * There are 2 directions of locking, which is a bad design.
		 * chain is locked -> hammer2_inode_get() -> lock inode
		 * inode is locked -> hammer2_inode_chain() -> lock chain
		 */
		hammer2_update_pmps(hmp);
		hammer2_bulkfree_init(hmp);
	} else {
		/* hmp->devvp_list is already constructed. */
		hammer2_cleanup_devvp(&devvpl);
		if (ctx->hflags & HMNT2_DEVFLAGS)
			hprintf("WARNING: mount flags pertaining to the whole "
			    "device may only be specified on the first mount "
			    "of the device: %08x\n",
			    ctx->hflags & HMNT2_DEVFLAGS);
	}

	/*
	 * Force local mount (disassociate all PFSs from their clusters).
	 * Used primarily for debugging.
	 */
	force_local = (hmp->hflags & HMNT2_LOCAL) ? hmp : NULL;

	/*
	 * Lookup the mount point under the media-localized super-root.
	 * Scanning hammer2_pfslist doesn't help us because it represents
	 * PFS cluster ids which can aggregate several named PFSs together.
	 */
	spmp = hmp->spmp;
	hammer2_inode_lock(spmp->iroot, 0);
	parent = hammer2_inode_chain(spmp->iroot, 0, HAMMER2_RESOLVE_ALWAYS);
	lhc = hammer2_dirhash(label, strlen(label));
	chain = hammer2_chain_lookup(&parent, &key_next, lhc,
	    lhc + HAMMER2_DIRHASH_LOMASK, &error, 0);
	while (chain) {
		if (chain->bref.type == HAMMER2_BREF_TYPE_INODE &&
		    strcmp(label, (char *)chain->data->ipdata.filename) == 0)
			break;
		chain = hammer2_chain_next(&parent, chain, &key_next,
		    lhc + HAMMER2_DIRHASH_LOMASK, &error, 0);
	}
	if (parent) {
		hammer2_chain_unlock(parent);
		hammer2_chain_drop(parent);
	}
	hammer2_inode_unlock(spmp->iroot);

	/* PFS could not be found? */
	if (chain == NULL) {
		hammer2_unmount_helper(NULL, NULL, hmp);
		hammer2_lk_unlock(&hammer2_mntlk);
		hstrfree(devstr);
		deactivate_locked_super(sb);

		if (error) {
			hprintf("PFS label \"%s\" error %08x\n", label, error);
			return (-EINVAL);
		}
		hprintf("PFS label \"%s\" not found\n", label);
		return (-ENOENT);
	}

	/* Acquire the pmp structure. */
	if (chain->error) {
		hprintf("PFS label \"%s\" chain error %08x\n",
		    label, chain->error);
	} else {
		ripdata = &chain->data->ipdata;
		pmp = hammer2_pfsalloc(NULL, ripdata, force_local);
	}
	hammer2_chain_unlock(chain);
	hammer2_chain_drop(chain);

	/* PFS to mount must exist at this point. */
	if (pmp == NULL) {
		hprintf("failed to acquire PFS structure\n");
		hammer2_unmount_helper(NULL, NULL, hmp);
		hammer2_lk_unlock(&hammer2_mntlk);
		hstrfree(devstr);
		deactivate_locked_super(sb);
		return (-EINVAL);
	}

	if (pmp->mp) {
		hprintf("PFS already mounted!\n");
		hammer2_unmount_helper(NULL, NULL, hmp);
		hammer2_lk_unlock(&hammer2_mntlk);
		hstrfree(devstr);
		deactivate_locked_super(sb);
		return (-EBUSY);
	}

	/* Linux fill-super */
	sb->s_op = &hammer2_sops;
	sb->s_magic = HAMMER2_VOLUME_ID_HBO;
	sb->s_maxbytes = MAX_LFS_FILESIZE;
	sb->s_time_gran = 1;
	sb->s_blocksize = HAMMER2_PBUFSIZE;
	sb->s_blocksize_bits = HAMMER2_PBUFRADIX;
	snprintf(sb->s_id, sizeof(sb->s_id), "%pg",
	    file_bdev(hmp->bdev_file));

	error = super_setup_bdi(sb);
	if (error) {
		hprintf("super_setup_bdi failed: %d\n", error);
		hammer2_unmount_helper(NULL, NULL, hmp);
		hammer2_lk_unlock(&hammer2_mntlk);
		hstrfree(devstr);
		deactivate_locked_super(sb);
		return error;
	}

	/* Connect up mount pointers. */
	hammer2_mount_helper(sb, pmp);

	/* Linux: this superblock's own claim on every device it spans. */
	error = hammer2_register_sb(sb, pmp);
	if (error) {
		hammer2_lk_unlock(&hammer2_mntlk);
		hstrfree(devstr);
		deactivate_locked_super(sb);	/* ->kill_sb unmounts */
		return (-error);
	}

	/* Update readonly hmp if !rdonly. */
	pmp->rdonly = rdonly;

	hammer2_inode_lock(pmp->iroot, 0);
	error = hammer2_igetv(pmp->iroot, 0, &root_inode);
	hammer2_inode_unlock(pmp->iroot);
	if (error) {
		hprintf("failed to get root inode: %d\n", error);
		hammer2_lk_unlock(&hammer2_mntlk);
		hstrfree(devstr);
		deactivate_locked_super(sb);
		return (hammer2_vfs_errno(error));	/* Linux */
	}

	sb->s_root = d_make_root(root_inode);
	if (sb->s_root == NULL) {
		hprintf("failed to make root dentry\n");
		hammer2_lk_unlock(&hammer2_mntlk);
		hstrfree(devstr);
		deactivate_locked_super(sb);
		return (-ENOMEM);
	}

	fc->root = dget(sb->s_root);
	sb->s_flags |= SB_ACTIVE;
	hammer2_lk_unlock(&hammer2_mntlk);
	hstrfree(devstr);

	return 0;
}

struct hammer2_recovery_elm {
	TAILQ_ENTRY(hammer2_recovery_elm) entry;
	hammer2_chain_t *chain;
	hammer2_tid_t sync_tid;
};

TAILQ_HEAD(hammer2_recovery_list, hammer2_recovery_elm);

struct hammer2_recovery_info {
	struct hammer2_recovery_list list;
	hammer2_tid_t mtid;
	int depth;
};

static int hammer2_recovery_scan(hammer2_dev_t *, hammer2_chain_t *,
    struct hammer2_recovery_info *, hammer2_tid_t);

#define HAMMER2_RECOVERY_MAXDEPTH	10

/*
 * Recovery re-scans the topology from the last flushed freemap_tid up to
 * mirror_tid and re-marks the blocks it finds allocated, which is what
 * makes a filesystem whose last flush was interrupted safe to write to
 * again.  It WRITES: hammer2_freemap_adjust() with DORECOVER, and
 * hammer2_flush() at each PFS boundary.
 *
 * The recursion is bounded by HAMMER2_RECOVERY_MAXDEPTH rather than by
 * the shape of the tree.  hammer2_recovery_scan() defers anything deeper
 * onto info->list, which hammer2_recovery() then drains at depth zero, so
 * the stack cost is a fixed ten frames whatever the topology is.
 */
static int
hammer2_recovery(hammer2_dev_t *hmp)
{
	struct hammer2_recovery_info info;
	struct hammer2_recovery_elm *elm;
	hammer2_chain_t *parent;
	hammer2_tid_t sync_tid, mirror_tid;
	int error;

	hammer2_trans_init(hmp->spmp, 0);

	sync_tid = hmp->voldata.freemap_tid;
	mirror_tid = hmp->voldata.mirror_tid;

	if (sync_tid >= mirror_tid)
		debug_hprintf("no recovery needed\n");
	else
		hprintf("freemap recovery %016llx-%016llx\n",
		    (long long)sync_tid + 1, (long long)mirror_tid);

	TAILQ_INIT(&info.list);
	info.depth = 0;
	parent = hammer2_chain_lookup_init(&hmp->vchain, 0);
	error = hammer2_recovery_scan(hmp, parent, &info, sync_tid);
	hammer2_chain_lookup_done(parent);

	while ((elm = TAILQ_FIRST(&info.list)) != NULL) {
		TAILQ_REMOVE(&info.list, elm, entry);
		parent = elm->chain;
		sync_tid = elm->sync_tid;
		hfree(elm, M_HAMMER2, sizeof(*elm));

		hammer2_chain_lock(parent, HAMMER2_RESOLVE_ALWAYS);
		error |= hammer2_recovery_scan(hmp, parent, &info,
		    hmp->voldata.freemap_tid);
		hammer2_chain_unlock(parent);
		hammer2_chain_drop(parent); /* drop elm->chain ref */
	}

	hammer2_trans_done(hmp->spmp, 0);

	return (error);
}

static int
hammer2_recovery_scan(hammer2_dev_t *hmp, hammer2_chain_t *parent,
    struct hammer2_recovery_info *info, hammer2_tid_t sync_tid)
{
	hammer2_chain_t *chain;
	hammer2_blockref_t bref;
	struct hammer2_recovery_elm *elm;
	const hammer2_inode_data_t *ripdata;
	int tmp_error, rup_error, error, first;

	/* Adjust freemap to ensure that the block(s) are marked allocated. */
	if (parent->bref.type != HAMMER2_BREF_TYPE_VOLUME)
		hammer2_freemap_adjust(hmp, &parent->bref,
		    HAMMER2_FREEMAP_DORECOVER);

	/* Check type for recursive scan. */
	switch (parent->bref.type) {
	case HAMMER2_BREF_TYPE_VOLUME:
		/* data already instantiated */
		break;
	case HAMMER2_BREF_TYPE_INODE:
		/*
		 * Must instantiate data for DIRECTDATA test and also
		 * for recursion.
		 */
		hammer2_chain_lock(parent, HAMMER2_RESOLVE_ALWAYS);
		ripdata = &parent->data->ipdata;
		if (ripdata->meta.op_flags & HAMMER2_OPFLAG_DIRECTDATA) {
			/* not applicable to recovery scan */
			hammer2_chain_unlock(parent);
			return (0);
		}
		hammer2_chain_unlock(parent);
		break;
	case HAMMER2_BREF_TYPE_INDIRECT:
		/* Must instantiate data for recursion. */
		hammer2_chain_lock(parent, HAMMER2_RESOLVE_ALWAYS);
		hammer2_chain_unlock(parent);
		break;
	case HAMMER2_BREF_TYPE_DIRENT:
	case HAMMER2_BREF_TYPE_DATA:
	case HAMMER2_BREF_TYPE_FREEMAP:
	case HAMMER2_BREF_TYPE_FREEMAP_NODE:
	case HAMMER2_BREF_TYPE_FREEMAP_LEAF:
		/* not applicable to recovery scan */
		return (0);
		break;
	default:
		return (HAMMER2_ERROR_BADBREF);
	}

	/* Defer operation if depth limit reached. */
	if (info->depth >= HAMMER2_RECOVERY_MAXDEPTH) {
		elm = hmalloc(sizeof(*elm), M_HAMMER2, M_ZERO | M_WAITOK);
		elm->chain = parent;
		elm->sync_tid = sync_tid;
		hammer2_chain_ref(parent);
		TAILQ_INSERT_TAIL(&info->list, elm, entry);
		/* unlocked by caller */
		return (0);
	}

	/*
	 * Recursive scan of the last flushed transaction only.  We are
	 * doing this without pmp assignments so don't leave the chains
	 * hanging around after we are done with them.
	 *
	 * error	Cumulative error this level only
	 * rup_error	Cumulative error for recursion
	 * tmp_error	Specific non-cumulative recursion error
	 */
	chain = NULL;
	first = 1;
	rup_error = 0;
	error = 0;

	for (;;) {
		error |= hammer2_chain_scan(parent, &chain, &bref, &first,
		    HAMMER2_LOOKUP_NODATA);
		/* Problem during scan or EOF. */
		if (error)
			break;

		/* If this is a leaf. */
		if (chain == NULL) {
			if (bref.mirror_tid > sync_tid)
				hammer2_freemap_adjust(hmp, &bref,
				    HAMMER2_FREEMAP_DORECOVER);
			continue;
		}

		/* This may or may not be a recursive node. */
		atomic_set_int(&chain->flags, HAMMER2_CHAIN_RELEASE);
		if (bref.mirror_tid > sync_tid) {
			++info->depth;
			tmp_error = hammer2_recovery_scan(hmp, chain, info,
			    sync_tid);
			--info->depth;
		} else {
			tmp_error = 0;
		}

		/*
		 * Flush the recovery at the PFS boundary to stage it for
		 * the final flush of the super-root topology.
		 */
		if (tmp_error == 0 &&
		    (bref.flags & HAMMER2_BREF_FLAG_PFSROOT) &&
		    (chain->flags & HAMMER2_CHAIN_ONFLUSH))
			hammer2_flush(chain,
			    HAMMER2_FLUSH_TOP | HAMMER2_FLUSH_ALL);
		rup_error |= tmp_error;
	}
	return ((error | rup_error) & ~HAMMER2_ERROR_EOF);
}

/*
 * This fixes up an error introduced in earlier H2 implementations where
 * moving a PFS inode into an indirect block wound up causing the
 * HAMMER2_BREF_FLAG_PFSROOT flag in the bref to get cleared.
 */
static int
hammer2_fixup_pfses(hammer2_dev_t *hmp)
{
	const hammer2_inode_data_t *ripdata;
	hammer2_chain_t *parent, *chain;
	hammer2_key_t key_next;
	hammer2_pfs_t *spmp;
	int error = 0, error2;

	/*
	 * Lookup mount point under the media-localized super-root.
	 *
	 * cluster->pmp will incorrectly point to spmp and must be fixed
	 * up later on.
	 */
	spmp = hmp->spmp;
	hammer2_inode_lock(spmp->iroot, 0);
	parent = hammer2_inode_chain(spmp->iroot, 0, HAMMER2_RESOLVE_ALWAYS);
	chain = hammer2_chain_lookup(&parent, &key_next, HAMMER2_KEY_MIN,
	    HAMMER2_KEY_MAX, &error, 0);

	while (chain) {
		if (chain->bref.type != HAMMER2_BREF_TYPE_INODE)
			continue;
		if (chain->error) {
			hprintf("I/O error scanning PFS labels\n");
			error |= chain->error;
		} else if ((chain->bref.flags & HAMMER2_BREF_FLAG_PFSROOT) == 0) {
			ripdata = &chain->data->ipdata;
			hammer2_trans_init(hmp->spmp, 0);
			error2 = hammer2_chain_modify(chain,
			    chain->bref.modify_tid, 0, 0);
			if (error2 == 0) {
				hprintf("correct mis-flagged PFS %s\n",
				    ripdata->filename);
				chain->bref.flags |= HAMMER2_BREF_FLAG_PFSROOT;
			} else {
				error |= error2;
			}
			hammer2_flush(chain,
			    HAMMER2_FLUSH_TOP | HAMMER2_FLUSH_ALL);
			hammer2_trans_done(hmp->spmp, 0);
		}
		chain = hammer2_chain_next(&parent, chain, &key_next,
		    HAMMER2_KEY_MAX, &error, 0);
	}

	if (parent) {
		hammer2_chain_unlock(parent);
		hammer2_chain_drop(parent);
	}
	hammer2_inode_unlock(spmp->iroot);

	return (error);
}

/*
 * Scan PFSs under the super-root and create hammer2_pfs structures.
 */
static void
hammer2_update_pmps(hammer2_dev_t *hmp)
{
	hammer2_dev_t *force_local;
	hammer2_pfs_t *spmp;
	const hammer2_inode_data_t *ripdata;
	hammer2_chain_t *parent;
	hammer2_chain_t *chain;
	hammer2_key_t key_next;
	int error;

	/*
	 * Force local mount (disassociate all PFSs from their clusters).
	 * Used primarily for debugging.
	 */
	force_local = (hmp->hflags & HMNT2_LOCAL) ? hmp : NULL;

	/* Lookup mount point under the media-localized super-root. */
	spmp = hmp->spmp;
	hammer2_inode_lock(spmp->iroot, 0);
	parent = hammer2_inode_chain(spmp->iroot, 0, HAMMER2_RESOLVE_ALWAYS);
	chain = hammer2_chain_lookup(&parent, &key_next, HAMMER2_KEY_MIN,
	    HAMMER2_KEY_MAX, &error, 0);
	while (chain) {
		if (chain->error) {
			hprintf("chain error %08x reading PFS root\n",
			    chain->error);
		} else if (chain->bref.type != HAMMER2_BREF_TYPE_INODE) {
			hprintf("non inode chain type %d under super-root\n",
			    chain->bref.type);
		} else {
			ripdata = &chain->data->ipdata;
			hammer2_pfsalloc(chain, ripdata, force_local);
		}
		chain = hammer2_chain_next(&parent, chain, &key_next,
		    HAMMER2_KEY_MAX, &error, 0);
	}
	if (parent) {
		hammer2_chain_unlock(parent);
		hammer2_chain_drop(parent);
	}
	hammer2_inode_unlock(spmp->iroot);
}

/*
 * Mount helper, hook the system mount into our PFS.
 * The mount lock is held.
 *
 * We must bump the mount_count on related devices for any mounted PFSs.
 */
static void
hammer2_mount_helper(struct super_block *sb, hammer2_pfs_t *pmp)
{
	hammer2_cluster_t *cluster;
	hammer2_chain_t *rchain;
	int i;

	sb->s_fs_info = pmp;
	pmp->mp = sb;

	/* After pmp->mp is set adjust hmp->mount_count. */
	cluster = &pmp->iroot->cluster;
	for (i = 0; i < cluster->nchains; ++i) {
		rchain = cluster->array[i].chain;
		if (rchain == NULL)
			continue;
		++rchain->hmp->mount_count;
	}
}

static void
hammer2_evict_inode(struct inode *inode)
{
	hammer2_inode_t *ip = VTOI(inode);

	truncate_inode_pages_final(&inode->i_data);
	clear_inode(inode);

	if (ip) {
		ip->vp = NULL;
		hammer2_inode_drop(ip);
	}
}

/*
 * Report the filesystem's size and identity.
 *
 * This is upstream's hammer2_vfs_statfs() with its two loops collapsed and
 * its credential check replaced by the field Linux already has for it.
 *
 * Upstream walks iroot's chains and overwrites every field on each pass,
 * so the last non-NULL device wins and the earlier ones are computed and
 * discarded; the first is taken here instead, which is the same answer for
 * the single-device case and an honest one rather than an arbitrary one
 * for a cluster this port cannot mount anyway.
 *
 * The credential check is the interesting half. Upstream subtracts the 5%
 * reserve from all three block counts when the caller is not root, which
 * is a question Linux answers with the fields themselves: f_bfree is what
 * is free and f_bavail is what an unprivileged writer may have, so the
 * reserve is subtracted from one and not the other, and no caller identity
 * is consulted. df reads f_bavail, which is why a full disk still shows a
 * few percent free to root.
 *
 * f_fsid is the PFS uuid rather than the device, because a device carries
 * more than one PFS and each is a separate filesystem to the VFS. Folding
 * sixteen bytes to eight is uuid_to_fsid(), which is the kernel's own
 * helper for exactly this.
 *
 * WHY THERE IS NO NULL CHECK HERE WHEN hammer2_unmount() HAS ONE.  That
 * one exists because a superblock reaches teardown when the mount failed
 * before hammer2_mount_helper() ran, so its pmp really can be NULL.  This
 * is reached only through a dentry, which requires sb->s_root, which
 * hammer2_get_tree() sets after the root inode is resolved and returns an
 * error without setting when that fails.  So pmp and pmp->iroot are both
 * live whenever this runs, and a check for either would be a branch that
 * cannot be taken.  Upstream makes the same assumption and says so about
 * the cluster rather than the inode: iroot exists, but may not have
 * validated its cluster yet, which is why the chain array is read
 * defensively below and the inode pointer is not.
 */
static int
hammer2_statfs(struct dentry *dentry, struct kstatfs *buf)
{
	struct super_block *sb = dentry->d_sb;
	hammer2_pfs_t *pmp = MPTOPMP(sb);
	hammer2_dev_t *hmp = NULL;
	hammer2_off_t avail;
	int i;

	for (i = 0; i < pmp->iroot->cluster.nchains; ++i) {
		if (pmp->pfs_hmps[i]) {
			hmp = pmp->pfs_hmps[i];
			break;
		}
	}
	if (hmp == NULL)
		return (-EIO);		/* Linux: the VFS half is negative */

	/*
	 * HAMMER2_PBUFSIZE is what upstream reports as f_bsize and is the
	 * unit its allocator counts in, so the division below is upstream's
	 * and not a choice made here.
	 */
	buf->f_type = HAMMER2_SUPER_MAGIC;
	buf->f_bsize = HAMMER2_PBUFSIZE;
	buf->f_frsize = HAMMER2_PBUFSIZE;
	buf->f_blocks = hmp->voldata.allocator_size / HAMMER2_PBUFSIZE;
	buf->f_bfree = hmp->voldata.allocator_free / HAMMER2_PBUFSIZE;

	avail = hmp->voldata.allocator_free;
	avail -= avail < hmp->free_reserved ? avail : hmp->free_reserved;
	buf->f_bavail = avail / HAMMER2_PBUFSIZE;

	buf->f_files = hammer2_inode_inode_count(pmp->iroot);
	buf->f_ffree = 0;	/* Linux: as upstream, inodes are not preallocated */

	/*
	 * Strictly less, which is the bound the core compares against at
	 * both call sites in hammer2_inode.c, so the longest name that fits
	 * is one below the array.
	 */
	buf->f_namelen = HAMMER2_INODE_MAXNAME - 1;
	buf->f_fsid = uuid_to_fsid((__u8 *)&pmp->iroot->meta.pfs_fsid);

	return (0);
}

static const struct super_operations hammer2_sops = {
	.evict_inode	= hammer2_evict_inode,
	.statfs		= hammer2_statfs,		/* Linux */
};

/*
 * DEFER(recovery is exercised on a device): the read-write refusal in
 * hammer2_get_tree() covers the mount, and this covers the remount that
 * would otherwise walk around it.
 *
 * A NULL ->reconfigure does NOT make the VFS refuse a remount.
 * reconfigure_super() calls the operation only when it is present and
 * then applies fc->sb_flags under fc->sb_flags_mask either way, so
 * "mount -o remount,rw" on a superblock mounted read-only clears
 * SB_RDONLY with nothing consulted.  Read at the kernel of record, in
 * fs/super.c.
 *
 * XXX Linux: this is not FreeBSD's MNT_UPDATE branch of
 * hammer2_mount(), which is what a real ->reconfigure carries.  It is
 * the refusal alone, and it goes away when the real one is written.
 * That one is upstream's hammer2_remount_impl(), which is not carried:
 * it reopens each volume for writing and then runs hammer2_recovery()
 * and hammer2_fixup_pfses() a second time, on the ro to rw transition,
 * before clearing hmp->rdonly.  The mount path's call to those two is
 * carried above; this one is not, and refusing the transition is why
 * that has not mattered yet.
 */
static int
hammer2_reconfigure(struct fs_context *fc)
{
	struct super_block *sb = fc->root->d_sb;

	if ((fc->sb_flags_mask & SB_RDONLY) && !(fc->sb_flags & SB_RDONLY) &&
	    sb_rdonly(sb)) {
		hprintf("read-write remount refused, flush recovery has never been exercised\n");
		return (-EROFS);	/* Linux: the VFS half is negative */
	}

	return (0);
}

static const struct fs_context_operations hammer2_context_ops = {
	.parse_param	= hammer2_parse_param,
	.get_tree	= hammer2_get_tree,
	.reconfigure	= hammer2_reconfigure,
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
 * Unmount helper, unhook the system mount from our PFS.
 *
 * If hmp is supplied a mount responsible for being the first to open
 * the block device failed and the block device and all PFSs using the
 * block device must be cleaned up.
 *
 * If pmp is supplied multiple devices might be backing the PFS and each
 * must be disconnected.  This might not be the last PFS using some of the
 * underlying devices.  Also, we have to adjust our hmp->mount_count
 * accounting for the devices backing the pmp which is now undergoing an
 * unmount.
 */
static void
hammer2_unmount_helper(struct super_block *sb, hammer2_pfs_t *pmp,
    hammer2_dev_t *hmp)
{
	hammer2_cluster_t *cluster;
	hammer2_chain_t *rchain;
	int i;

	/*
	 * If no device supplied this is a high-level unmount and we have to
	 * to disconnect the mount, adjust mount_count, and locate devices
	 * that might now have no mounts.
	 */
	if (pmp) {
		KKASSERT(hmp == NULL);
		KKASSERT(MPTOPMP(sb) == pmp);
		hammer2_unregister_sb(pmp);	/* Linux: before mp is cleared */
		pmp->mp = NULL;
		sb->s_fs_info = NULL;

		/*
		 * After pmp->mp is cleared we have to account for
		 * mount_count.
		 */
		cluster = &pmp->iroot->cluster;
		for (i = 0; i < cluster->nchains; ++i) {
			rchain = cluster->array[i].chain;
			if (rchain == NULL)
				continue;
			--rchain->hmp->mount_count;
			/* Scrapping hmp now may invalidate the pmp. */
		}
again:
		TAILQ_FOREACH(hmp, &hammer2_mntlist, mntentry) {
			if (hmp->mount_count == 0) {
				hammer2_unmount_helper(NULL, NULL, hmp);
				goto again;
			}
		}
		return;
	}

	/*
	 * Try to terminate the block device.  We can't terminate it if
	 * there are still PFSs referencing it.
	 */
	if (hmp->mount_count) {
		hprintf("%d PFS mounts still exist\n", hmp->mount_count);
		return;
	}

	hammer2_bulkfree_uninit(hmp);
	hammer2_pfsfree_scan(hmp, 0);

	/*
	 * Flush whatever is left.  Unmounted but modified PFS's might still
	 * have some dirty chains on them.
	 */
	hammer2_chain_lock(&hmp->vchain, HAMMER2_RESOLVE_ALWAYS);
	hammer2_chain_lock(&hmp->fchain, HAMMER2_RESOLVE_ALWAYS);

	if (hmp->fchain.flags & HAMMER2_CHAIN_FLUSH_MASK) {
		hammer2_voldata_modify(hmp);
		hammer2_flush(&hmp->fchain,
		    HAMMER2_FLUSH_TOP | HAMMER2_FLUSH_ALL);
	}
	hammer2_chain_unlock(&hmp->fchain);

	if (hmp->vchain.flags & HAMMER2_CHAIN_FLUSH_MASK)
		hammer2_flush(&hmp->vchain,
		    HAMMER2_FLUSH_TOP | HAMMER2_FLUSH_ALL);
	hammer2_chain_unlock(&hmp->vchain);

	if ((hmp->vchain.flags | hmp->fchain.flags) &
	    HAMMER2_CHAIN_FLUSH_MASK) {
		hprintf("chains left over after final sync "
		    "vchain %08x fchain %08x\n",
		    hmp->vchain.flags, hmp->fchain.flags);
		KKASSERT(0);
	}

	hammer2_pfsfree_scan(hmp, 1);
	KKASSERT(hmp->spmp == NULL);

	/* Finish up with the device vnode. */
	if (!TAILQ_EMPTY(&hmp->devvp_list)) {
		hammer2_close_devvp(&hmp->devvp_list);
		hammer2_cleanup_devvp(&hmp->devvp_list);
	}
	KKASSERT(TAILQ_EMPTY(&hmp->devvp_list));

	/*
	 * Clear vchain/fchain flags that might prevent final cleanup
	 * of these chains.
	 */
	if (hmp->vchain.flags & HAMMER2_CHAIN_MODIFIED) {
		atomic_add_int(&hammer2_count_chain_modified, -1);
		atomic_clear_int(&hmp->vchain.flags, HAMMER2_CHAIN_MODIFIED);
	}
	if (hmp->vchain.flags & HAMMER2_CHAIN_UPDATE)
		atomic_clear_int(&hmp->vchain.flags, HAMMER2_CHAIN_UPDATE);

	if (hmp->fchain.flags & HAMMER2_CHAIN_MODIFIED) {
		atomic_add_int(&hammer2_count_chain_modified, -1);
		atomic_clear_int(&hmp->fchain.flags, HAMMER2_CHAIN_MODIFIED);
	}
	if (hmp->fchain.flags & HAMMER2_CHAIN_UPDATE)
		atomic_clear_int(&hmp->fchain.flags, HAMMER2_CHAIN_UPDATE);

#ifdef HAMMER2_INVARIANTS
	hammer2_dump_chain(&hmp->vchain, 0, 0, -1, 'v');
	hammer2_dump_chain(&hmp->fchain, 0, 0, -1, 'f');
#endif
	/*
	 * Final drop of embedded volume/freemap root chain to clean up
	 * [vf]chain.core ([vf]chain structure is not flagged ALLOCATED so
	 * it is cleaned out and then left to rot).
	 */
	hammer2_chain_drop(&hmp->vchain);
	hammer2_chain_drop(&hmp->fchain);

	hammer2_mtx_ex(&hmp->iohash_lock);
	hammer2_io_hash_cleanup_all(hmp);
	if (hmp->iofree_count)
		hprintf("XXX %d I/O's left hanging\n", hmp->iofree_count);
	hammer2_mtx_unlock(&hmp->iohash_lock);

	TAILQ_REMOVE(&hammer2_mntlist, hmp, mntentry);
	hammer2_mtx_destroy(&hmp->iohash_lock);
	hammer2_io_hash_destroy(hmp);

	hammer2_lk_destroy(&hmp->vollk);
	hammer2_lk_destroy(&hmp->bulklk);
	hammer2_lk_destroy(&hmp->bflk);

	hammer2_print_iostat(&hmp->iostat_read, "read");
	hammer2_print_iostat(&hmp->iostat_write, "write");

	hfree(hmp, M_HAMMER2, sizeof(*hmp));

#ifdef HAMMER2_MALLOC
	if (TAILQ_EMPTY(&hammer2_mntlist)) {
		if (malloc_leak_m_hammer2)
			hprintf("XXX M_HAMMER2 %d bytes leaked\n",
			    malloc_leak_m_hammer2);
		if (malloc_leak_m_hammer2_lz4)
			hprintf("XXX M_HAMMER2_LZ4 %d bytes leaked\n",
			    malloc_leak_m_hammer2_lz4);
		if (malloc_leak_m_temp)
			hprintf("XXX M_TEMP %d bytes leaked\n",
			    malloc_leak_m_temp);
	}
#endif
}

/*
 * XXX Linux: upstream's hammer2_unmount() returns an error and the VFS
 * can refuse the unmount on it.  Linux's ->kill_sb returns void and is
 * called after the unmount has already been decided, so there is no
 * error to return and no caller to return it to.  What upstream does
 * with the value is fail the unmount when vflush() fails, which is the
 * one branch that cannot happen here: kill_anon_super() has already run
 * by the time this is called, and evicting every inode and the root
 * dentry is exactly what vflush() was for.
 */
/*
 * XXX Linux: a floor, and the only definition this symbol has.
 *
 * Upstream walks the PFS's inodes, flushes each and flushes the volume
 * header.  None of that can run yet: the flush needs a chain topology a
 * successful mount would have built, and no mount succeeds.
 *
 * The trade this represents is recorded rather than silent.  Until
 * 2026-09-02 the symbol was declared and never defined, so modpost
 * refused the module and the absence could not be overlooked.  That also
 * meant the module could not be loaded, which is 0.3, so the link-time
 * tripwire is traded for a runtime one.  The replacement is not weaker in
 * the direction that matters: both call sites discard the return value,
 * so an errno was never going to reach anyone, and a WARN in dmesg is
 * read by whoever runs the driver rather than by whoever builds it.
 *
 * DEFER(->sync_fs lands): the body is upstream's hammer2_vfs_sync_pmp(),
 * and it is a hard prerequisite for the write path rather than a
 * companion to it.  An unmount that does not sync loses nothing while
 * nothing can be written; the day that stops being true, this floor is a
 * data-loss bug and not a deferral.
 */
int
hammer2_vfs_sync_pmp(hammer2_pfs_t *pmp, int waitfor)
{
	WARN_ONCE(1, "hammer2: unmount did not sync, ->sync_fs is not written\n");
	return (EOPNOTSUPP);		/* Linux: positive, negated at the VFS */
}

static void
hammer2_unmount(struct super_block *sb)
{
	hammer2_pfs_t *pmp = MPTOPMP(sb);

	/* Still NULL during mount before hammer2_mount_helper() called. */
	if (pmp == NULL)
		return;

	hammer2_lk_ex(&hammer2_mntlk);

	/*
	 * If mount initialization proceeded far enough we must sync the
	 * underlying mount points.  Three syncs are required to fully
	 * flush the filesystem (freemap updates lag by one flush, and one
	 * extra for safety).
	 *
	 * hammer2_vfs_sync_pmp() is a floor, not the sync.  It was declared
	 * and left undefined until 2026-09-02 so that the absence would be
	 * visible at link time; what that bought is now bought instead by
	 * doc/README.status.md's table and by the CI build step, and what it
	 * cost was a module that could not be loaded at all.  Both call sites
	 * here discard the return value, so the loud channel is the WARN in
	 * the floor rather than an errno either way.
	 */
	if (pmp->iroot) {
		hammer2_vfs_sync_pmp(pmp, MNT_WAIT);
		hammer2_vfs_sync_pmp(pmp, MNT_WAIT);
		hammer2_vfs_sync_pmp(pmp, MNT_WAIT);
	} else {
		debug_hprintf("no root inode"); /* failed before allocation */
	}

	hammer2_unmount_helper(sb, pmp, NULL);
	hammer2_lk_unlock(&hammer2_mntlk);

	if (TAILQ_EMPTY(&hammer2_mntlist))
		hammer2_assert_clean();
}


/*
 * kill_anon_super() runs first and the private teardown after, which is
 * the order btrfs_kill_super() uses at v7.2: the generic call drops
 * every inode and the root dentry, and those hold the references the
 * teardown is about to free.  It is also what makes upstream's vflush()
 * unnecessary here; see hammer2_unmount().
 */
static void
hammer2_kill_sb(struct super_block *sb)
{
	kill_anon_super(sb);
	hammer2_unmount(sb);
}

struct file_system_type hammer2_fs_type = {
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
	TAILQ_INIT(&hammer2_mntlist);
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
