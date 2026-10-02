/*-
 * SPDX-License-Identifier: BSD-3-Clause
 *
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

#include "hammer2.h"

/*
 * Returns the bref type of the cluster's foucs.
 *
 * If the cluster is errored, returns HAMMER2_BREF_TYPE_EMPTY (0).
 * The cluster must be locked.
 */
uint8_t
hammer2_cluster_type(const hammer2_cluster_t *cluster)
{
	if (cluster->error == 0) {
		KKASSERT(cluster->focus != NULL);
		return (cluster->focus->bref.type);
	}

	return (0);
}

/*
 * Returns the bref of the cluster's focus, sans any data-offset information
 * (since offset information is per-node and wouldn't be useful).
 *
 * If the cluster is errored, returns an empty bref.
 * The cluster must be locked.
 */
void
hammer2_cluster_bref(const hammer2_cluster_t *cluster, hammer2_blockref_t *bref)
{
	if (cluster->error == 0) {
		KKASSERT(cluster->focus != NULL);
		*bref = cluster->focus->bref;
		bref->data_off = 0;
	} else {
		bzero(bref, sizeof(*bref));
	}
}

/*
 * Create a degenerate cluster with one ref from a single locked chain.
 * The returned cluster will be focused on the chain and inherit its
 * error state.
 *
 * The chain's lock and reference are transfered to the new cluster, so
 * the caller should not try to unlock the chain separately.
 */
void
hammer2_dummy_xop_from_chain(hammer2_xop_head_t *xop, hammer2_chain_t *chain)
{
	hammer2_cluster_t *cluster = &xop->cluster;

	bzero(xop, sizeof(*xop));

	cluster->array[0].chain = chain;
	cluster->nchains = 1;
	cluster->focus = chain;
	cluster->pmp = chain->pmp;
	cluster->error = chain->error;

	hammer2_assert_cluster(cluster);
}

void
hammer2_cluster_unhold(hammer2_cluster_t *cluster)
{
	hammer2_chain_t *chain;
	int i;

	for (i = 0; i < cluster->nchains; ++i) {
		chain = cluster->array[i].chain;
		if (chain)
			hammer2_chain_unhold(chain);
	}
}

void
hammer2_cluster_rehold(hammer2_cluster_t *cluster)
{
	hammer2_chain_t *chain;
	int i;

	for (i = 0; i < cluster->nchains; ++i) {
		chain = cluster->array[i].chain;
		if (chain)
			hammer2_chain_rehold(chain);
	}
}

/*
 * This is used by the XOPS subsystem to calculate the state of the
 * collection and tell hammer2_xop_collect() what to do with it.
 *
 * Ported from DragonFly's hammer2_cluster_check().  The single-chain port
 * took the first pass and the tail of the third and dropped the quorum
 * machinery between them, which is what made nchains > 1 impossible: the
 * dropped tail asserted every slot but the first was NULL.  What follows
 * is upstream's three passes, with the quorum computed from the PFS's
 * master count and the three-way disagreement return that goes with it.
 *
 * The port's error values are positive bit flags rather than DragonFly's
 * negative errnos, so the returns below name the port's own codes; the
 * control flow is upstream's.
 */
int
hammer2_cluster_check(hammer2_cluster_t *cluster, hammer2_key_t key, int flags)
{
	hammer2_chain_t *chain;
	hammer2_chain_t *focus;
	hammer2_pfs_t *pmp;
	hammer2_tid_t quorum_tid;
	hammer2_tid_t last_best_quorum_tid;
	uint32_t nflags;
	int ttlmasters;
	int ttlslaves;
	int nmasters;
	/*
	 * Upstream reads this in its early return, to tell ESRCH (the quorum
	 * does not agree on the key) from EDEADLK (it agrees on the key but
	 * not on the tid).  The port has no bit for either, both collapse
	 * to EIO, so it is counted and not read.
	 */
	int nmasters_keymatch __maybe_unused;
	int nslaves;
	int nquorum;
	int umasters;
	int error;
	int i;

	cluster->error = 0;
	cluster->focus = NULL;
	hammer2_assert_cluster(cluster);

	pmp = cluster->pmp;
	KKASSERT(pmp != NULL || cluster->nchains == 0);

	/*
	 * Calculate quorum.  pfs_nmasters is the on-disk field the PFS root
	 * carries; a single-master PFS has one, and a quorum of one is the
	 * case this port has always run.
	 */
	nquorum = pmp ? (int)pmp->pfs_nmasters / 2 + 1 : 0;
	nflags = 0;
	ttlmasters = 0;
	ttlslaves = 0;

	/*
	 * Pass 1
	 *
	 * NOTE: A NULL chain is not necessarily an error, it could be
	 *	 e.g. a lookup failure or the end of an iteration.
	 *	 Process normally.
	 */
	for (i = 0; i < cluster->nchains; ++i) {
		cluster->array[i].flags &= ~HAMMER2_CITEM_FEMOD;
		cluster->array[i].flags |= HAMMER2_CITEM_INVALID;

		chain = cluster->array[i].chain;
		error = cluster->array[i].error;
		if (chain && error) {
			/*
			 * Must count total masters and slaves whether the
			 * chain is errored or not.
			 */
			switch (pmp->pfs_types[i]) {
			case HAMMER2_PFSTYPE_SUPROOT:
			case HAMMER2_PFSTYPE_MASTER:
				++ttlmasters;
				break;
			case HAMMER2_PFSTYPE_SLAVE:
				++ttlslaves;
				break;
			}
			continue;
		}
		switch (pmp->pfs_types[i]) {
		case HAMMER2_PFSTYPE_MASTER:
			++ttlmasters;
			break;
		case HAMMER2_PFSTYPE_SLAVE:
			++ttlslaves;
			break;
		case HAMMER2_PFSTYPE_SOFT_MASTER:
			nflags |= HAMMER2_CLUSTER_WRSOFT;
			nflags |= HAMMER2_CLUSTER_RDSOFT;
			break;
		case HAMMER2_PFSTYPE_SOFT_SLAVE:
			nflags |= HAMMER2_CLUSTER_RDSOFT;
			break;
		case HAMMER2_PFSTYPE_SUPROOT:
			/*
			 * Degenerate cluster representing the super-root
			 * topology on a single device.
			 */
			++ttlmasters;
			nflags |= HAMMER2_CLUSTER_WRHARD;
			nflags |= HAMMER2_CLUSTER_RDHARD;
			cluster->focus_index = i;
			cluster->focus = chain;
			cluster->error = error;
			break;
		default:
			break;
		}
	}

	/*
	 * Pass 2
	 *
	 * Resolve nmasters           - master nodes fully match
	 * Resolve umasters           - master nodes still in progress
	 * Resolve nmasters_keymatch  - master nodes matching the passed key
	 *
	 * The quorum-agreed TID is the highest matching TID.
	 */
	last_best_quorum_tid = HAMMER2_TID_MAX;
	umasters = 0;
	nmasters = 0;
	nmasters_keymatch = 0;
	quorum_tid = 0;

	while (nmasters < nquorum && last_best_quorum_tid != 0) {
		umasters = 0;
		nmasters = 0;
		nmasters_keymatch = 0;
		quorum_tid = 0;

		for (i = 0; i < cluster->nchains; ++i) {
			switch (pmp->pfs_types[i]) {
			case HAMMER2_PFSTYPE_MASTER:
			case HAMMER2_PFSTYPE_SUPROOT:
				break;
			default:
				continue;
			}

			chain = cluster->array[i].chain;
			error = cluster->array[i].error;

			/*
			 * Skip elements still in progress.  umasters keeps
			 * track of masters that might still be in-progress.
			 */
			if (chain == NULL && (cluster->array[i].flags &
					      HAMMER2_CITEM_NULL) == 0) {
				++umasters;
				continue;
			}

			if (flags & HAMMER2_CHECK_NULL) {
				if (chain == NULL) {
					++nmasters;
					++nmasters_keymatch;
					if (cluster->error == 0)
						cluster->error = error;
				}
			} else if (chain &&
				   (key == (hammer2_key_t)-1 ||
				    chain->bref.key == key)) {
				++nmasters_keymatch;

				if (chain->bref.modify_tid <
				     last_best_quorum_tid &&
				    quorum_tid < chain->bref.modify_tid) {
					nmasters = 0;
					quorum_tid = chain->bref.modify_tid;
				}
				if (quorum_tid == chain->bref.modify_tid) {
					++nmasters;
					if (chain->error == 0) {
						cluster->focus = chain;
						cluster->focus_index = i;
					}
				}
			}
		}
		if (nmasters >= nquorum)
			break;
		last_best_quorum_tid = quorum_tid;
	}

	/*
	 * Early return if we do not have enough masters.  Upstream splits
	 * this three ways, EINPROGRESS when more replies may still arrive,
	 * ESRCH when the quorum does not even agree on the key, and EDEADLK
	 * when it agrees on the key but not on the transaction id.  The
	 * port has no bit for ESRCH or EDEADLK, so those two collapse to
	 * EIO and EAGAIN carries the first, which is what its callers
	 * branch on.
	 */
	if (nmasters < nquorum) {
		if (nmasters + umasters >= nquorum)
			return (HAMMER2_ERROR_EAGAIN);
		return (HAMMER2_ERROR_EIO);
	}

	/*
	 * Validated end of scan.
	 */
	if (flags & HAMMER2_CHECK_NULL) {
		if (cluster->error == 0)
			cluster->error = HAMMER2_ERROR_ENOENT;
		return (cluster->error);
	}

	/*
	 * If we have a NULL focus at this point the agreeing quorum all
	 * had chain errors.
	 */
	if (cluster->focus == NULL)
		return (HAMMER2_ERROR_EIO);

	/*
	 * Pass 3
	 *
	 * We have quorum agreement, validate elements, not end of scan.
	 */
	nslaves = 0;
	cluster->error = 0;

	for (i = 0; i < cluster->nchains; ++i) {
		chain = cluster->array[i].chain;
		error = cluster->array[i].error;
		if (chain == NULL ||
		    chain->bref.key != key ||
		    chain->bref.modify_tid != quorum_tid) {
			continue;
		}

		/* Quorum match: cumulative error, as upstream. */
		if (cluster->error == 0)
			cluster->error = error;

		switch (pmp->pfs_types[i]) {
		case HAMMER2_PFSTYPE_MASTER:
			cluster->array[i].flags |= HAMMER2_CITEM_FEMOD;
			cluster->array[i].flags &= ~HAMMER2_CITEM_INVALID;
			nflags |= HAMMER2_CLUSTER_WRHARD;
			nflags |= HAMMER2_CLUSTER_RDHARD;
			break;
		case HAMMER2_PFSTYPE_SLAVE:
			/*
			 * A slave must match the quorum's modify_tid.  Do
			 * not select an errored slave.
			 */
			cluster->array[i].flags &= ~HAMMER2_CITEM_INVALID;
			nflags |= HAMMER2_CLUSTER_RDHARD;
			++nslaves;
			break;
		case HAMMER2_PFSTYPE_SOFT_MASTER:
			cluster->array[i].flags |= HAMMER2_CITEM_FEMOD;
			cluster->array[i].flags &= ~HAMMER2_CITEM_INVALID;
			break;
		case HAMMER2_PFSTYPE_SOFT_SLAVE:
			cluster->array[i].flags &= ~HAMMER2_CITEM_INVALID;
			break;
		case HAMMER2_PFSTYPE_SUPROOT:
			cluster->array[i].flags |= HAMMER2_CITEM_FEMOD;
			cluster->array[i].flags &= ~HAMMER2_CITEM_INVALID;
			nflags |= HAMMER2_CLUSTER_WRHARD;
			nflags |= HAMMER2_CLUSTER_RDHARD;
			break;
		default:
			break;
		}
	}

	/*
	 * Focus now set, adjust ddflag.  Skip this pass if the focus is bad
	 * or if we are at the PFS root, where the bref will not match.
	 *
	 * focus is probably not locked and it is not safe to test its
	 * content here; the frontend does not always need its dio or data.
	 */
	focus = cluster->focus;
	if (focus) {
		cluster->ddflag =
		    (cluster->focus->bref.type == HAMMER2_BREF_TYPE_INODE);
	} else {
		cluster->ddflag = 0;
		goto skip4;
	}
	if (cluster->focus->flags & HAMMER2_CHAIN_PFSBOUNDARY)
		goto skip4;

	/*
	 * Pass 4
	 *
	 * Validate the elements not marked invalid.  They should match.
	 */
	for (i = 0; i < cluster->nchains; ++i) {
		int ddflag;

		chain = cluster->array[i].chain;

		if (chain == NULL)
			continue;
		if (chain == focus)
			continue;
		if (cluster->array[i].flags & HAMMER2_CITEM_INVALID)
			continue;

		ddflag = (chain->bref.type == HAMMER2_BREF_TYPE_INODE);
		if (chain->bref.type != focus->bref.type ||
		    chain->bref.key != focus->bref.key ||
		    chain->bref.keybits != focus->bref.keybits ||
		    chain->bref.modify_tid != focus->bref.modify_tid ||
		    chain->bytes != focus->bytes ||
		    ddflag != cluster->ddflag) {
			cluster->array[i].flags |= HAMMER2_CITEM_INVALID;
		}
	}
skip4:

	if (ttlslaves == 0)
		nflags |= HAMMER2_CLUSTER_NOSOFT;
	if (ttlmasters == 0)
		nflags |= HAMMER2_CLUSTER_NOHARD;

	/*
	 * Set SSYNCED or MSYNCED for slaves and masters respectively if all
	 * available nodes (even if 0 are available) are fully synchronized.
	 * The synchronization thread uses this to decide whether there is
	 * work it could accomplish.
	 */
	if (nslaves == ttlslaves)
		nflags |= HAMMER2_CLUSTER_SSYNCED;
	if (nmasters == ttlmasters)
		nflags |= HAMMER2_CLUSTER_MSYNCED;

	/*
	 * Determine whether the cluster was successfully locked for the
	 * requested operation and generate an error code.  The cluster is
	 * not locked or ref'd if an error is returned.
	 */
	cluster->flags = (cluster->flags & HAMMER2_CLUSTER_INODE) | nflags;

	return (cluster->error);
}
