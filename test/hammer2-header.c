// SPDX-License-Identifier: BSD-3-Clause
/*
 * Copyright (c) 2026 James Manring.  All rights reserved.
 *
 * The one runnable check hammer2.h leaves behind: a translation unit
 * that includes it and instantiates what a header alone never
 * exercises.  RB_GENERATE and RB_GENERATE_SCAN expand the vendored
 * tree.h and hammer2_rb.h through sys/cdefs.h's `__always_unused`; the queue
 * macros expand sys/queue.h; the atomic family in hammer2_linux.h is
 * called on the field widths the core uses it on (int, uint32_t,
 * uint64_t); and the errno round trip is spelled out once.
 * -fsyntax-only, like the rest of the gate: nothing is built.
 */
#include "hammer2.h"

int
hammer2_chain_cmp(const hammer2_chain_t *a, const hammer2_chain_t *b)
{
	return (a->bref.key < b->bref.key) ? -1 : (a->bref.key > b->bref.key);
}

RB_GENERATE(hammer2_chain_tree, hammer2_chain, rbnode, hammer2_chain_cmp);
RB_GENERATE_SCAN(hammer2_chain_tree, hammer2_chain, rbnode);

static int
scan_cb(hammer2_chain_t *chain __always_unused, void *data __always_unused)
{
	return 0;
}

int
hammer2_header_check(hammer2_pfs_t *pmp, hammer2_chain_t *chain)
{
	hammer2_inode_t *ip;
	unsigned int flags = 0;
	uint32_t w32 = 0;
	uint64_t w64 = 0;
	int n = 0;

	RB_INSERT(hammer2_chain_tree, &chain->core.rbtree, chain);
	RB_SCAN(hammer2_chain_tree, &chain->core.rbtree, NULL, scan_cb, NULL);
	RB_REMOVE(hammer2_chain_tree, &chain->core.rbtree, chain);

	TAILQ_INIT(&pmp->syncq);
	TAILQ_FOREACH(ip, &pmp->syncq, qentry)
		n++;

	atomic_set_int(&flags, HAMMER2_CHAIN_MODIFIED);
	atomic_clear_int(&flags, HAMMER2_CHAIN_MODIFIED);
	atomic_add_int(&n, 1);
	atomic_set_32(&w32, 1);
	atomic_set_64(&w64, 1);
	atomic_clear_64(&w64, 1);
	n += atomic_fetchadd_int(&n, 1);
	w64 += atomic_fetchadd_64(&w64, 1);
	if (!atomic_cmpset_int(&flags, 0, 1))
		n++;
	if (!atomic_cmpset_64(&w64, w64, 0))
		n++;

	/* errno round trip; positive errnos are the module's convention */
	n += hammer2_error_to_errno(hammer2_errno_to_error(EIO)) != EIO;
	static_assert(sizeof(struct uuid) == 16, "struct uuid");

	return (int)(VTOI(ip->vp) == ip) + (int)(MPTOPMP(pmp->mp) == pmp) + n;
}
