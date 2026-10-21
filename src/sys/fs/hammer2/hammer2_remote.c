// SPDX-License-Identifier: BSD-3-Clause
/*
 * The HM2 XOP API server: the kernel's side of a PROTO_2 peer's read
 * requests, doc/CLUSTER_PROTOCOL_DESIGN.md, the wire format and the server
 * side.  This file is the port's.  The carried hammer2_iocom.c hands it
 * every frame in the HM2 space and nothing else; no BSD tree has a remote
 * element, so there is no sibling to read beside it.
 *
 * The reader thread never runs chain code.  hammer2_remote_rcvmsg() runs on
 * it: a request, the command with CREATE, is copied, its name detached from
 * the frame, and queued to the device's ordered workqueue, which runs one
 * request at a time per connection as the design's service thread does; a
 * continuation, the command with no flag on the same transaction, widens
 * the request's window by one FIFO; the peer's DELETE, real or simulated at
 * the connection's end, cancels it.  hammer2_remote_serve() runs on the
 * workqueue: it finds the PFS the request names among the mounted ones
 * with an element on this device, resolves the inode by number without an
 * XOP and without the inode dependency, runs the descriptor's own storage
 * function on a handle whose only element is this device's, sends one
 * reply frame per fed chain under the window, and closes the transaction
 * with the element's final error.
 *
 * kern_dmsg frees a transaction's state once both directions are closed,
 * and the server's direction stays open until the request is answered, so
 * the request record holds the state by that open side and never by a
 * reference, which kern_dmsg does not export.  The record is reachable
 * from the state through the field kern_dmsg leaves to devices, and is
 * unhooked under the server's lock before the closing frame is queued,
 * since the writer thread may free the state the moment both sides are
 * closed.  The PFS a request runs on is held by hammer2_mntlk for the
 * request's duration, the lock every mount, unmount and pfs-delete takes.
 */
#include <linux/ratelimit.h>
#include <linux/refcount.h>
#include <linux/sched.h>
#include <linux/wait.h>
#include <linux/workqueue.h>
#include <linux/xarray.h>

#include "hammer2.h"

struct hammer2_remote {
	struct workqueue_struct	*wq;		/* ordered: one request at a time */
	spinlock_t		lock;		/* reqq, req->window, req->cancelled, cdev */
	struct list_head	reqq;		/* queued or running */
	int			state;		/* HAMMER2_REMOTE_* */
	hammer2_dev_t		*hmp;		/* the device this connection is on */
	hammer2_dev_t		*cdev;		/* the connection device, the client side */
	struct delayed_work	regwork;	/* registration and detach */
};

#define HAMMER2_REMOTE_OPEN	0	/* requests admitted */
#define HAMMER2_REMOTE_QUIESCED	1	/* refused until the next announcement */
#define HAMMER2_REMOTE_CLOSED	2	/* refused for good, the device is going */

struct hammer2_remote_req {
	struct work_struct	work;
	struct list_head	entry;
	hammer2_dev_t		*hmp;
	kdmsg_state_t		*state;		/* held by our open reply direction */
	dmsg_hm2_xop_t		req;		/* the request frame, header included */
	kdmsg_data_t		aux;		/* the name, detached from the frame */
	wait_queue_head_t	waitq;		/* window, cancel and stop */
	int			idx;		/* descriptor index */
	int			window;		/* feeds the peer has allowed so far */
	int			cancelled;	/* the peer's DELETE arrived */
};

/*
 * The lookup flags a scanall request carries: whether data is resolved, and
 * whether a direct-data inode answers as itself.  The slave's pass asks for
 * NODIRECT; without it a direct-data file's scan fed the file's own inode,
 * the pass inserted it beneath itself, and the flush recursed to its limit.
 * The lock modes stay the server's.
 */
#define HAMMER2_REMOTE_LOOKUPF	(HAMMER2_LOOKUP_NODATA | HAMMER2_LOOKUP_NODIRECT)

/*
 * The read set of the command table: the descriptor at each index the
 * server runs, NULL where the command modifies and is refused.
 */
static hammer2_xop_desc_t *const hammer2_remote_descs[DMSG_HM2_XOP_COUNT] = {
	[0] = &hammer2_ipcluster_desc,
	[1] = &hammer2_readdir_desc,
	[2] = &hammer2_nresolve_desc,
	[5] = &hammer2_scanlhc_desc,
	[6] = &hammer2_scanall_desc,
	[7] = &hammer2_lookup_desc,
	[18] = &hammer2_strategy_read_desc,
	[20] = &hammer2_bmap_desc,
};

_Static_assert(sizeof(hammer2_blockref_t) ==
    sizeof(((dmsg_hm2_feed_t *)0)->bref), "a feed carries one blockref");
_Static_assert(sizeof(dmsg_hm2_feed_t) == 256, "a feed frame's size");

static void hammer2_remote_serve(struct work_struct *);
static void hammer2_remote_reconcile(struct work_struct *);
static void hammer2_remote_conn_end(struct hammer2_remote *, int);

void
hammer2_remote_init(hammer2_dev_t *hmp)
{
	struct hammer2_remote *rm;

	rm = kzalloc_obj(*rm);
	if (rm) {
		rm->wq = alloc_ordered_workqueue("hammer2-srv", 0);
		if (rm->wq == NULL) {
			kfree(rm);
			rm = NULL;
		}
	}
	if (rm) {
		spin_lock_init(&rm->lock);
		INIT_LIST_HEAD(&rm->reqq);
		rm->hmp = hmp;
		INIT_DELAYED_WORK(&rm->regwork, hammer2_remote_reconcile);
	} else {
		hprintf("no HM2 server for this device: out of memory\n");
	}
	hmp->remote = rm;
}

/*
 * Close the queue to the connection being replaced or torn down and fail
 * every request on it: once the state leaves OPEN under the lock no
 * CREATE is admitted, a queued request closes as it runs, a running one
 * at its next wait, and the flush returns when the queue is empty.  The
 * reader thread is still alive here and may deliver frames, which is why
 * admission closes under the same lock the reader queues under, and why
 * the queue itself is freed only by hammer2_remote_uninit(), after the
 * message threads are gone.  A reconnect's close is QUIESCED, which the
 * new connection's peer lifts by announcing PROTO_2, on the reader that
 * admits (hammer2_remote_resume()); a teardown's close is CLOSED and
 * nothing lifts it, so an announcement read during the teardown admits
 * nothing.
 */
void
hammer2_remote_quiesce(hammer2_dev_t *hmp, int final)
{
	struct hammer2_remote *rm = hmp->remote;
	struct hammer2_remote_req *req;

	if (rm == NULL)
		return;
	spin_lock(&rm->lock);
	rm->state = final ? HAMMER2_REMOTE_CLOSED : HAMMER2_REMOTE_QUIESCED;
	list_for_each_entry(req, &rm->reqq, entry)
		wake_up(&req->waitq);
	spin_unlock(&rm->lock);
	flush_workqueue(rm->wq);
	hammer2_remote_conn_end(rm, final);	/* the client side */
}

void
hammer2_remote_resume(hammer2_dev_t *hmp)
{
	struct hammer2_remote *rm = hmp->remote;

	if (rm == NULL)
		return;
	spin_lock(&rm->lock);
	if (rm->state == HAMMER2_REMOTE_QUIESCED)
		rm->state = HAMMER2_REMOTE_OPEN;
	spin_unlock(&rm->lock);
}

/*
 * After kdmsg_iocom_uninit(): no reader can deliver a frame, so nothing
 * reads hmp->remote once it is freed.
 */
void
hammer2_remote_uninit(hammer2_dev_t *hmp)
{
	struct hammer2_remote *rm = hmp->remote;

	if (rm == NULL)
		return;
	WARN_ON(rm->state != HAMMER2_REMOTE_CLOSED);
	destroy_workqueue(rm->wq);
	WARN_ON(!list_empty(&rm->reqq));
	kfree(rm);
	hmp->remote = NULL;
}

/*
 * On the reader thread, and on the writer thread for the DELETEs the
 * teardown simulates.  Nothing here ends the connection: a frame the
 * server cannot place is answered DMSG_ERR_NOSUPP as upstream answers an
 * unknown command, a one-off is ignored as upstream ignores one.
 */
int
hammer2_remote_rcvmsg(kdmsg_msg_t *msg)
{
	hammer2_dev_t *hmp = msg->state->iocom->handle;
	struct hammer2_remote *rm = hmp->remote;
	struct hammer2_remote_req *req;
	kdmsg_state_t *state = msg->state;
	uint32_t cmd = msg->any.head.cmd;
	int idx = (int)((cmd & DMSGF_CMDS) >> 8) - DMSG_HM2_XOP_BASE;

	if ((cmd & (DMSGF_CREATE | DMSGF_REPLY)) == DMSGF_CREATE) {
		const char *why = NULL;

		if (rm == NULL)
			why = "no server";
		else if (idx < 0 || idx >= DMSG_HM2_XOP_COUNT)
			why = "not a command";
		else if (hammer2_remote_descs[idx] == NULL)
			why = "a modifying command";
		else if (cmd & DMSGF_DELETE)
			why = "one-shot, no continuation possible";
		else if (msg->hdr_size != sizeof(dmsg_hm2_xop_t))
			why = "wrong size";
		if (why == NULL) {
			req = kzalloc_obj(*req);
			if (req == NULL)
				why = "out of memory";
		}
		if (why) {
			pr_warn_ratelimited("hammer2: HM2 request %08x refused: %s\n",
			    cmd, why);
			kdmsg_msg_reply(msg, DMSG_ERR_NOSUPP);
			return (0);
		}
		req->hmp = hmp;
		req->state = state;
		req->idx = idx;
		req->window = HAMMER2_XOPFIFO;
		memcpy(&req->req, &msg->any.hm2_xop, sizeof(req->req));
		kdmsg_detach_aux_data(msg, &req->aux);
		init_waitqueue_head(&req->waitq);
		INIT_WORK(&req->work, hammer2_remote_serve);
		/*
		 * Admission and the queue under one lock, so a quiesce that
		 * closed the state before this point sees the request in its
		 * flush and one that closes it after refuses the next request.
		 */
		spin_lock(&rm->lock);
		if (rm->state != HAMMER2_REMOTE_OPEN) {
			spin_unlock(&rm->lock);
			kdmsg_free_aux_data(&req->aux);
			kfree(req);
			pr_warn_ratelimited("hammer2: HM2 request %08x refused: connection closing\n",
			    cmd);
			kdmsg_msg_reply(msg, DMSG_ERR_NOSUPP);
			return (0);
		}
		state->any.any = req;
		list_add_tail(&req->entry, &rm->reqq);
		queue_work(rm->wq, &req->work);
		spin_unlock(&rm->lock);
		return (0);
	}
	if ((cmd & DMSGF_REPLY) || rm == NULL || state == &state->iocom->state0)
		return (0);
	spin_lock(&rm->lock);
	req = state->any.any;
	if (req) {
		if (cmd & DMSGF_DELETE)
			req->cancelled = 1;
		else
			req->window += HAMMER2_XOPFIFO;
		wake_up(&req->waitq);
	}
	spin_unlock(&rm->lock);
	return (0);
}

/*
 * A server-side inode handle: what hammer2_inode_get() builds, less the
 * inode hash, so a frontend inode of the same number is neither found nor
 * disturbed, and never locked.  Its cluster holds this device's chain in
 * this device's slot and nothing else, so the storage function's clindex is
 * the server's own index for its element, which is what the nresolve
 * hardlink arm's hammer2_chain_inode_find() reads.  The cluster is set in
 * place, since hammer2_inode_repoint() is the inode file's own; the drop
 * releases it through that function as it does for every inode.
 */
static hammer2_inode_t *
hammer2_remote_handle(hammer2_pfs_t *pmp, hammer2_chain_t *chain, int clindex)
{
	hammer2_inode_t *ip;

	ip = uma_zalloc(hammer2_zone_inode, M_WAITOK | M_ZERO);
	atomic_add_int(&hammer2_count_inode_allocated, 1);
	hammer2_spin_init(&ip->cluster_spin, "h2ip_cl");
	ip->cluster.pmp = pmp;
	ip->meta = chain->data->ipdata.meta;
	ip->pmp = pmp;
	ip->ipdep_idx = ip->meta.inum % HAMMER2_IHASH_SIZE;
	ip->refs = 1;
	hammer2_lkc_init(&ip->syncq_cv, "h2ip_sq");
	hammer2_mtx_init_recurse(&ip->lock, "h2ip");
	hammer2_inode_lockdep_nest(&ip->lock);
	hammer2_mtx_init(&ip->truncate_lock, "h2ip_tr");
	TAILQ_INIT(&ip->depend_static.sideq);

	hammer2_chain_ref(chain);
	ip->cluster.array[clindex].chain = chain;
	ip->cluster.nchains = clindex + 1;
	ip->cluster.focus = chain;
	ip->cluster.focus_index = clindex;
	return (ip);
}

/*
 * One reply frame: the fed chain's blockref, bytes and error, its data as
 * aux.  The chain is held, so its data is resident; it is locked shared
 * for the copy so a writer on this host cannot change the block under it.
 * The first frame of the reply direction carries CREATE, as kern_dmsg's
 * own result does.
 */
static void
hammer2_remote_feed(struct hammer2_remote_req *req, hammer2_chain_t *chain,
    int error)
{
	kdmsg_msg_t *msg;
	uint32_t cmd = DMSG_HM2_FEED | DMSGF_REPLY;
	size_t abytes;

	if ((req->state->txcmd & DMSGF_CREATE) == 0)
		cmd |= DMSGF_CREATE;
	msg = kdmsg_msg_alloc(req->state, cmd, NULL, NULL);
	hammer2_chain_lock(chain, HAMMER2_RESOLVE_ALWAYS | HAMMER2_RESOLVE_SHARED);
	memcpy(msg->any.hm2_feed.bref, &chain->bref, sizeof(chain->bref));
	msg->any.hm2_feed.bytes = chain->bytes;
	msg->any.hm2_feed.error = error ? error : chain->error;
	if (chain->bytes && chain->data && chain->error == 0) {
		abytes = DMSG_DOALIGN(chain->bytes);
		msg->aux_data = hmalloc(abytes, req->hmp->mmsg, M_WAITOK | M_ZERO);
		memcpy(msg->aux_data, chain->data, chain->bytes);
		msg->aux_size = chain->bytes;
		msg->flags |= KDMSG_FLAG_AUXALLOC;
	}
	hammer2_chain_unlock(chain);
	kdmsg_msg_write(msg);
}

/*
 * The transaction's DELETE, a feed frame with no chain.  With
 * DMSG_HM2_FEEDF_EOF its error is the element's final one, what
 * hammer2_xop_feed() would have been given with a NULL chain, or the
 * server's own error ending the scan, which the peer feeds the same way;
 * without it the element fed only chains, as ipcluster and lookup do, and
 * the peer feeds no end.  A refusal is kern_dmsg's own LNK_ERROR reply
 * instead, so the peer tells the two apart by the closing frame's command.
 */
static void
hammer2_remote_close(struct hammer2_remote_req *req, uint32_t error, int eof,
    hammer2_key_t rkey)
{
	kdmsg_msg_t *msg;
	uint32_t cmd = DMSG_HM2_FEED | DMSGF_REPLY | DMSGF_DELETE;

	if ((req->state->txcmd & DMSGF_CREATE) == 0)
		cmd |= DMSGF_CREATE;
	msg = kdmsg_msg_alloc(req->state, cmd, NULL, NULL);
	msg->any.hm2_feed.error = error;
	msg->any.hm2_feed.rkey = rkey;
	if (eof)
		msg->any.hm2_feed.flags = DMSG_HM2_FEEDF_EOF;
	kdmsg_msg_write(msg);
}

/*
 * The window: HAMMER2_XOPFIFO feeds per continuation.  The wait is bounded
 * so a peer that stops continuing cannot hold the connection's queue, and
 * it ends early on the peer's DELETE and on the connection's end.
 * HAMMER2_NOWINDOW builds the negative control, which must send past it.
 */
static int
hammer2_remote_window(struct hammer2_remote_req *req, int fed)
{
#ifndef HAMMER2_NOWINDOW
	struct hammer2_remote *rm = req->hmp->remote;
	long left;

	left = wait_event_timeout(req->waitq,
	    READ_ONCE(req->cancelled) || READ_ONCE(rm->state) != HAMMER2_REMOTE_OPEN ||
	    READ_ONCE(req->window) > fed,
	    msecs_to_jiffies(hammer2_remote_timeout_ms));
	if (READ_ONCE(req->cancelled) || READ_ONCE(rm->state) != HAMMER2_REMOTE_OPEN)
		return (HAMMER2_ERROR_ABORTED);
	if (left == 0 && READ_ONCE(req->window) <= fed)
		return (HAMMER2_ERROR_ETIMEDOUT);
#endif
	return (0);
}

/*
 * The PFS a request names: a mounted one whose cluster id matches with an
 * element on this device, found on hammer2_pfslist under hammer2_mntlk,
 * which the request then holds until it is answered, since hammer2_pfs
 * carries no reference count and that lock is what every mount, unmount
 * and pfs-delete takes.  It is taken by try-lock to the bound, because the
 * unmount holds it while it waits for this queue to drain, so a blocking
 * take here would wait on the unmount waiting on it; a closed state ends the
 * wait.  A bulkfree scan holds the lock for its whole run and a request
 * started under one fails at the bound.  Returns with the lock held when
 * a PFS is found and released otherwise.
 */
static hammer2_pfs_t *
hammer2_remote_pfs(struct hammer2_remote_req *req, int *clindexp)
{
	hammer2_dev_t *hmp = req->hmp;
	struct hammer2_remote *rm = hmp->remote;
	hammer2_pfs_t *pmp;
	unsigned long deadline;
	int i;

	deadline = jiffies + msecs_to_jiffies(hammer2_remote_timeout_ms);
	while (!hammer2_lk_tryex(&hammer2_mntlk)) {
		if (READ_ONCE(req->cancelled) || READ_ONCE(rm->state) != HAMMER2_REMOTE_OPEN ||
		    time_after(jiffies, deadline))
			return (NULL);
		schedule_timeout_uninterruptible(msecs_to_jiffies(10));
	}
	TAILQ_FOREACH(pmp, &hammer2_pfslist, mntentry) {
		if (pmp->mp == NULL || pmp->iroot == NULL)
			continue;
		if (bcmp(&pmp->pfs_clid, &req->req.pfs_clid,
		    sizeof(pmp->pfs_clid)) != 0)
			continue;
		for (i = 0; i < pmp->iroot->cluster.nchains; ++i)
			if (pmp->pfs_hmps[i] == hmp)
				break;
		if (i < pmp->iroot->cluster.nchains) {
			*clindexp = i;
			return (pmp);	/* hammer2_mntlk held */
		}
	}
	hammer2_lk_unlock(&hammer2_mntlk);
	return (NULL);
}

static void
hammer2_remote_serve(struct work_struct *work)
{
	struct hammer2_remote_req *req =
	    container_of(work, struct hammer2_remote_req, work);
	hammer2_dev_t *hmp = req->hmp;
	struct hammer2_remote *rm = hmp->remote;
	hammer2_xop_desc_t *desc = hammer2_remote_descs[req->idx];
	kdmsg_state_t *state = req->state;
	hammer2_pfs_t *pmp = NULL;
	hammer2_inode_t *ip = NULL;
	hammer2_xop_t *xop = NULL;
	hammer2_chain_t *parent = NULL, *chain = NULL;
	hammer2_xop_fifo_t *fifo;
	unsigned long t0 = jiffies;
	uint32_t error = 0;
	int clindex = 0, fed = 0, nerror, refused = 0, eof = 1;

	if (READ_ONCE(req->cancelled) || READ_ONCE(rm->state) != HAMMER2_REMOTE_OPEN) {
		error = HAMMER2_ERROR_ABORTED;
		goto out;
	}
	pmp = hammer2_remote_pfs(req, &clindex);
	if (pmp == NULL) {
		pr_warn_ratelimited("hammer2: HM2 %s refused: no mounted PFS of that cluster on this device\n",
		    desc->id);
		refused = 1;
		goto out;
	}

	/*
	 * The inode, by number, as the nresolve hardlink arm finds one: the
	 * frontend's inode if it is in memory, the inode tree under the PFS
	 * root otherwise.  No inode is locked and no dependency taken.
	 */
	error = hammer2_chain_inode_find(pmp, req->req.inum, clindex,
	    HAMMER2_LOOKUP_SHARED, &parent, &chain);
	if (chain == NULL) {
		if (error == 0)
			error = HAMMER2_ERROR_ENOENT;
		goto out;
	}
	if (chain->bref.type != HAMMER2_BREF_TYPE_INODE || chain->data == NULL) {
		error = HAMMER2_ERROR_EINVAL;
		goto out;
	}
	ip = hammer2_remote_handle(pmp, chain, clindex);
	hammer2_chain_unlock(chain);
	hammer2_chain_drop(chain);
	chain = NULL;
	if (parent) {
		hammer2_chain_unlock(parent);
		hammer2_chain_drop(parent);
		parent = NULL;
	}

	/*
	 * The XOP, with the strategy flag so that hammer2_xop_retire() asks
	 * for no dependency the server never took.  The lock modes a scan
	 * runs under are the server's, not the peer's: shared, resolving
	 * data, as the slave's own source scans run.
	 */
	xop = hammer2_xop_alloc(ip, HAMMER2_XOP_STRATEGY);
	switch (req->idx) {
	case 1:
		xop->xop_readdir.lkey = req->req.key_beg;
		xop->xop_readdir.rkey = req->req.key_end;
		xop->xop_readdir.nmax = req->req.nmax;
		break;
	case 2:
		if (req->aux.aux_data == NULL || req->aux.aux_size == 0 ||
		    req->aux.aux_size >= HAMMER2_INODE_MAXNAME) {
			error = HAMMER2_ERROR_EINVAL;
			goto out;
		}
		hammer2_xop_setname(&xop->head, req->aux.aux_data,
		    req->aux.aux_size);
		break;
	case 5:
		xop->xop_scanlhc.lhc = req->req.key_beg;
		break;
	case 6:
		xop->xop_scanall.key_beg = req->req.key_beg;
		xop->xop_scanall.key_end = req->req.key_end;
		xop->xop_scanall.resolve_flags = HAMMER2_RESOLVE_ALWAYS |
		    HAMMER2_RESOLVE_SHARED;
		xop->xop_scanall.lookup_flags = HAMMER2_LOOKUP_ALWAYS |
		    HAMMER2_LOOKUP_SHARED |
		    (req->req.lookup_flags & HAMMER2_REMOTE_LOOKUPF);
		break;
	case 7:
		xop->xop_lookup.lhc = req->req.key_beg;
		break;
	case 18:
		xop->xop_strategy.lbase = req->req.key_beg;
		break;
	case 20:
		xop->xop_bmap.lbn = req->req.key_beg;
		break;
	default:
		break;
	}
	xop->head.desc = desc;
	atomic_set_32(&xop->head.run_mask, 1U << clindex);
	desc->storage_func(xop, NULL, clindex);

	/*
	 * The element's FIFO, in feed order: a chain is one reply frame, a
	 * NULL chain is the end of the scan and its error is the final one.
	 * A chain left in the FIFO by an early end is dropped by the retire.
	 */
	fifo = &xop->head.collect[clindex];
	eof = 0;
	while (fifo->ri != fifo->wi) {
		chain = fifo->array[fifo->ri & fifo_mask(&xop->head)];
		nerror = fifo->errors[fifo->ri & fifo_mask(&xop->head)];
		++fifo->ri;
		if (chain == NULL) {
			error = nerror;
			eof = 1;
			break;
		}
		if (fed >= READ_ONCE(req->window)) {
			error = hammer2_remote_window(req, fed);
			if (error) {
				hammer2_chain_drop_unhold(chain);
				eof = 1;
				break;
			}
		}
		hammer2_remote_feed(req, chain, nerror);
		hammer2_chain_drop_unhold(chain);
		++fed;
		error = nerror;
	}
	chain = NULL;
out:
	if (chain) {
		hammer2_chain_unlock(chain);
		hammer2_chain_drop(chain);
	}
	if (parent) {
		hammer2_chain_unlock(parent);
		hammer2_chain_drop(parent);
	}
	if (pmp)
		hammer2_lk_unlock(&hammer2_mntlk);
	if (hammer2_debug & 0x0100)
		kprintf("H2 SERVE %s inum=%016llx fed=%d error=%08x%s%s ms=%u\n",
		    desc->id, (unsigned long long)req->req.inum, fed, error,
		    eof ? " eof" : "", refused ? " refused" : "",
		    jiffies_to_msecs(jiffies - t0));

	/*
	 * Unhook before the closing frame: once both directions are closed
	 * the writer thread frees the state, so nothing reads it after the
	 * frame is queued.
	 */
	spin_lock(&rm->lock);
	state->any.any = NULL;
	list_del(&req->entry);
	spin_unlock(&rm->lock);
	if (refused)
		kdmsg_state_reply(state, DMSG_ERR_NOSUPP);
	else
		hammer2_remote_close(req, eof ? error : 0, eof,
		    (xop && req->idx == 1) ? xop->xop_readdir.rkey :
		    HAMMER2_KEY_MAX);

	if (xop) {
		hammer2_xop_retire(&xop->head, 1U << clindex);
		hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);
	}
	if (ip)
		hammer2_inode_drop(ip);
	kdmsg_free_aux_data(&req->aux);
	kfree(req);
}


/*
 * The client side: the remote element (doc/CLUSTER_PROTOCOL_DESIGN.md, the
 * remote element and the client side).
 *
 * A PROTO_2 connection owns a connection device, a hammer2_dev_t with no
 * block device whose chains are proxies for the peer's.  A reply's chain
 * is allocated on it with the peer's blockref and a synthetic data_off, a
 * handle in block units, and the handle table records what the peer needs
 * to find the chain again.  The block is stashed on the handle by the feed
 * and taken by the first load; a later load refetches it from the peer
 * through hammer2_io_getblk_conn().  So the carried chain code runs
 * unchanged on a proxy, and the device is freed after its last chain,
 * which the ccache and the inode clusters hold past the XOP and past the
 * connection.
 *
 * A master's span, admitted by a copyinfo[] row with its cluster id,
 * registers its root as an element of the PFS of that cluster id that
 * this host holds a local element of, unless it is mounted read-write, by
 * the steps hammer2_pfsalloc() takes for a later local mount less the
 * mount count and the sync thread; the span's DELETE, the connection's end
 * and the departure of the PFS's local device detach it.  The XOP element loop
 * runs a slot on a connection device through hammer2_remote_xop(), which
 * sends the XOP as one HM2 request and feeds a proxy per reply frame.
 */
struct hammer2_rconn {
	hammer2_dev_t		*cdev;		/* the device this is */
	struct mutex		mtx;		/* dead, lhmp, every call */
	hammer2_dev_t		*lhmp;		/* the device carrying the link */
	int			dead;		/* the link has ended */
	refcount_t		refs;		/* the link's, each chain's, each user's */
	wait_queue_head_t	waitq;		/* every call on the link */
	spinlock_t		hlock;		/* handle stashes */
	struct xarray		byid;		/* handle number -> handle */
	struct xarray		byoff;		/* the peer's data_off -> handle */
	struct work_struct	free_work;
};

/*
 * What the peer needs to find a proxy's chain again: an inode by number
 * through ipcluster, anything else by key beneath its inode through
 * lookup.  A handle stands for one block version, the peer's data_off,
 * which the peer's media does not reuse while the block is live, under
 * one identity: a block deduplicated under two keys has two handles.
 *
 * ponytail: the table grows with the block versions this connection has
 * seen and is freed with the device; prune handles whose dio has left the
 * hash when a long-lived connection's memory is measured.
 */
struct hammer2_rhandle {
	uint32_t		id;		/* the byid index */
	uint8_t			type;
	uint8_t			cmd;		/* descriptor index, 0 or 7 */
	struct uuid		clid;
	uint64_t		inum;
	hammer2_key_t		key;
	char			*stash;		/* the fed block, until loaded */
	int			stash_bytes;
	struct hammer2_rhandle	*next;		/* the block's next identity, hlock */
	uint8_t			methods;	/* the fed bref's; not identity */
};

/*
 * One reply frame, copied off the reader thread.
 */
struct hammer2_rframe {
	struct list_head	entry;
	hammer2_blockref_t	bref;
	uint32_t		bytes;
	uint32_t		error;
	char			*data;		/* kvmalloc(bytes) or NULL */
};

/*
 * One request in flight, with two references: the caller's and the
 * transaction's, which the reply callback drops at the peer's DELETE, real
 * or simulated at the link's end.  Every field is under the connection's
 * mutex, which the callback takes on the reader thread, and nothing is
 * sent on the state once either side has closed it or the link is dead,
 * so the state is never touched after kern_dmsg may have freed it.
 */
struct hammer2_rcall {
	hammer2_dev_t		*cdev;		/* referenced */
	kdmsg_state_t		*state;
	int			idx;
	int			refs;
	struct list_head	frames;		/* received, not yet taken */
	int			nrecv;		/* feeds received */
	int			allowed;	/* feeds the window allows */
	int			txclosed;	/* our DELETE is sent */
	int			done;		/* the peer's DELETE arrived */
	int			eof;		/* the element fed its end */
	hammer2_key_t		rkey;		/* a readdir's, from the end; 0 none */
	uint32_t		error;		/* HAMMER2_ERROR_* of the end */
};

void
hammer2_remote_dev_ref(hammer2_dev_t *cdev)
{
	refcount_inc(&cdev->rconn->refs);
}

/*
 * The free takes the hash lock, a sleeping lock, and a chain can reach its
 * free under other locks, so it runs on the module's queue, which the
 * module's exit drains.  Nothing reaches the device by then: no chain, no
 * call, no link.
 */
static void
hammer2_remote_dev_free(struct work_struct *work)
{
	struct hammer2_rconn *rc = container_of(work, struct hammer2_rconn,
	    free_work);
	hammer2_dev_t *cdev = rc->cdev;
	struct hammer2_rhandle *h;
	unsigned long id;

	hammer2_mtx_ex(&cdev->iohash_lock);
	hammer2_io_hash_cleanup_all(cdev);
	hammer2_mtx_unlock(&cdev->iohash_lock);
	hammer2_io_hash_destroy(cdev);
	hammer2_mtx_destroy(&cdev->iohash_lock);
	xa_for_each(&rc->byid, id, h) {
		kvfree(h->stash);
		kfree(h);
	}
	xa_destroy(&rc->byid);
	xa_destroy(&rc->byoff);
	mutex_destroy(&rc->mtx);
	if (hammer2_debug & 0x0100)
		kprintf("H2 CDEV freed\n");
	kfree(rc);
	kvfree(cdev);
}

void
hammer2_remote_dev_drop(hammer2_dev_t *cdev)
{
	if (refcount_dec_and_test(&cdev->rconn->refs))
		queue_work(hammer2_ra_wq, &cdev->rconn->free_work);
}

static hammer2_dev_t *
hammer2_remote_dev_alloc(hammer2_dev_t *lhmp)
{
	hammer2_dev_t *cdev;
	struct hammer2_rconn *rc;

	cdev = kvzalloc_obj(*cdev);
	rc = kzalloc_obj(*rc);
	if (cdev == NULL || rc == NULL) {
		kvfree(cdev);
		kfree(rc);
		return (NULL);
	}
	rc->cdev = cdev;
	rc->lhmp = lhmp;
	mutex_init(&rc->mtx);
	refcount_set(&rc->refs, 1);	/* the link's */
	init_waitqueue_head(&rc->waitq);
	spin_lock_init(&rc->hlock);
	xa_init_flags(&rc->byid, XA_FLAGS_ALLOC1);
	xa_init(&rc->byoff);
	INIT_WORK(&rc->free_work, hammer2_remote_dev_free);
	TAILQ_INIT(&cdev->devvp_list);	/* hammer2_register_sb() walks it */
	hammer2_io_hash_init(cdev);
	hammer2_mtx_init(&cdev->iohash_lock, "h2cdev_iohash");
	cdev->rdonly = 1;
	cdev->rconn = rc;
	if (hammer2_debug & 0x0100)
		kprintf("H2 CDEV allocated\n");

	return (cdev);
}

/*
 * The link has ended: nothing is sent on it again, and every request in
 * flight fails now with the closed-connection code rather than at its
 * bound.
 */
static void
hammer2_remote_dev_kill(hammer2_dev_t *cdev)
{
	struct hammer2_rconn *rc = cdev->rconn;

	mutex_lock(&rc->mtx);
	rc->dead = 1;
	rc->lhmp = NULL;
	mutex_unlock(&rc->mtx);
	wake_up_all(&rc->waitq);
}

static void
hammer2_rcall_put(struct hammer2_rcall *call)
{
	struct hammer2_rframe *f, *n;
	hammer2_dev_t *cdev = call->cdev;
	int last;

	mutex_lock(&cdev->rconn->mtx);
	last = (--call->refs == 0);
	mutex_unlock(&cdev->rconn->mtx);
	if (!last)
		return;
	list_for_each_entry_safe(f, n, &call->frames, entry) {
		kvfree(f->data);
		kfree(f);
	}
	kfree(call);
	hammer2_remote_dev_drop(cdev);
}

/*
 * Our side's DELETE, an HM2 frame so the server's queue sees it and
 * cancels a request still running.  Under the connection's mutex.
 */
static void
hammer2_rcall_close_locked(struct hammer2_rcall *call)
{
	kdmsg_msg_t *msg;

	if (call->txclosed || call->cdev->rconn->dead)
		return;
	call->txclosed = 1;
	msg = kdmsg_msg_alloc(call->state,
	    DMSG_HM2_XOP(call->idx) | DMSGF_DELETE, NULL, NULL);
	kdmsg_msg_write(msg);
}

/*
 * The reply callback, on the reader thread, and on the writer thread for
 * the DELETEs the link's end simulates.  A frame is copied and queued; the
 * window and the frame's shape are checked here, where they can be read,
 * and a peer breaking either ends the link by the reader's own shutdown.
 */
static int
hammer2_rcall_reply(kdmsg_state_t *state, kdmsg_msg_t *msg)
{
	struct hammer2_rcall *call = state->any.any;
	struct hammer2_rconn *rc = call->cdev->rconn;
	struct hammer2_rframe *f = NULL;
	uint32_t cmd = msg->any.head.cmd;
	const char *bad = NULL;
	int feed;

	feed = (cmd & DMSGF_BASECMDMASK) == (DMSG_HM2_FEED & DMSGF_BASECMDMASK);
	if (feed && msg->any.hm2_feed.bytes) {
		/* the closing frame carries no chain */
		f = kzalloc_obj(*f);
		if (f) {
			memcpy(&f->bref, msg->any.hm2_feed.bref, sizeof(f->bref));
			f->bytes = msg->any.hm2_feed.bytes;
			f->error = msg->any.hm2_feed.error;
		}
		if (f && f->error == 0) {
			if (f->bytes > HAMMER2_PBUFSIZE || msg->aux_data == NULL ||
			    msg->aux_size < f->bytes)
				bad = "a feed with no data for its bytes";
			else
				f->data = kvmemdup(msg->aux_data, f->bytes,
				    GFP_KERNEL);
		}
	} else if (feed && (cmd & DMSGF_DELETE) == 0) {
		/* a chain whose bytes are embedded in its blockref */
		f = kzalloc_obj(*f);
		if (f) {
			memcpy(&f->bref, msg->any.hm2_feed.bref, sizeof(f->bref));
			f->error = msg->any.hm2_feed.error;
		}
	}

	mutex_lock(&rc->mtx);
	if (f) {
		++call->nrecv;
#ifndef HAMMER2_NOCLIENTWINDOW
		if (call->nrecv > call->allowed)
			bad = "a feed past the window";
#endif
		if ((f->error == 0 && f->bytes && f->data == NULL) || bad) {
			call->error = HAMMER2_ERROR_EIO;
			kvfree(f->data);
			kfree(f);
		} else {
			list_add_tail(&f->entry, &call->frames);
		}
	} else if (feed && (cmd & DMSGF_DELETE) == 0) {
		call->error = HAMMER2_ERROR_EIO;	/* out of memory */
	}
	if (cmd & DMSGF_DELETE) {
		if (feed) {
			if (msg->any.hm2_feed.flags & DMSG_HM2_FEEDF_EOF)
				call->eof = 1;
			call->rkey = msg->any.hm2_feed.rkey;
			if (call->error == 0)
				call->error = msg->any.hm2_feed.error;
		} else if (call->error == 0) {
			/* kern_dmsg's LNK_ERROR: a refusal or the link's loss */
			switch (msg->any.head.error) {
			case DMSG_ERR_NOSUPP:
				call->error = HAMMER2_ERROR_EOPNOTSUPP;
				break;
			case DMSG_ERR_LOSTLINK:
				call->error = HAMMER2_ERROR_ENOTCONN;
				break;
			default:
				call->error = HAMMER2_ERROR_EIO;
				break;
			}
		}
		call->done = 1;
		/* our side closes here, where the state is known to be live */
		hammer2_rcall_close_locked(call);
	}
	mutex_unlock(&rc->mtx);
	wake_up_all(&rc->waitq);

	if (bad) {
		pr_warn_ratelimited("hammer2: HM2 peer sent %s, ending the link\n",
		    bad);
		atomic_set_int(&state->iocom->msg_ctl, KDMSG_CLUSTERCTL_KILLRX);
	}
	if (cmd & DMSGF_DELETE)
		hammer2_rcall_put(call);	/* the transaction's reference */
	return (0);
}

/*
 * Send one request: the XOP at descriptor index idx, under the inode inum
 * of the PFS whose cluster id is clid.  Returns the call, or NULL with
 * *errorp set when the link is gone.
 */
static struct hammer2_rcall *
hammer2_rcall_start(hammer2_dev_t *cdev, int idx, const struct uuid *clid,
    uint64_t inum, hammer2_key_t key_beg, hammer2_key_t key_end,
    uint32_t lookup_flags, int nmax, const char *name, size_t name_len,
    int *errorp)
{
	struct hammer2_rconn *rc = cdev->rconn;
	struct hammer2_rcall *call;
	kdmsg_msg_t *msg;

	call = kzalloc_obj(*call);
	if (call == NULL) {
		*errorp = HAMMER2_ERROR_EIO;
		return (NULL);
	}
	hammer2_remote_dev_ref(cdev);
	call->cdev = cdev;
	call->idx = idx;
	call->refs = 2;		/* the caller's and the transaction's */
	call->allowed = HAMMER2_XOPFIFO;
	INIT_LIST_HEAD(&call->frames);

	mutex_lock(&rc->mtx);
	if (rc->dead || rc->lhmp == NULL ||
	    (rc->lhmp->iocom.flags & KDMSG_IOCOMF_PROTO2) == 0) {
		mutex_unlock(&rc->mtx);
		kfree(call);
		hammer2_remote_dev_drop(cdev);
		*errorp = HAMMER2_ERROR_ENOTCONN;
		return (NULL);
	}
	msg = kdmsg_msg_alloc(&rc->lhmp->iocom.state0,
	    DMSG_HM2_XOP(idx) | DMSGF_CREATE, hammer2_rcall_reply, call);
	call->state = msg->state;
	msg->any.hm2_xop.pfs_clid = *clid;
	msg->any.hm2_xop.inum = inum;
	msg->any.hm2_xop.key_beg = key_beg;
	msg->any.hm2_xop.key_end = key_end;
	msg->any.hm2_xop.lookup_flags = lookup_flags;
	msg->any.hm2_xop.nmax = nmax;
	if (name && name_len) {
		msg->aux_data = hmalloc(DMSG_DOALIGN(name_len), rc->lhmp->mmsg,
		    M_WAITOK | M_ZERO);
		memcpy(msg->aux_data, name, name_len);
		msg->aux_size = name_len;
		msg->flags |= KDMSG_FLAG_AUXALLOC;
	}
	kdmsg_msg_write(msg);
	mutex_unlock(&rc->mtx);

	return (call);
}

/*
 * The next frame of the reply, waiting to the call's deadline.  Returns 0
 * with a frame, or the end: HAMMER2_ERROR_EOF when the transaction closed
 * with the element's end consumed (call->eof and call->error say which),
 * HAMMER2_ERROR_ETIMEDOUT at the bound, HAMMER2_ERROR_ENOTCONN when the
 * link ended.  A continuation goes back every HAMMER2_XOPFIFO frames.
 */
static int
hammer2_rcall_next(struct hammer2_rcall *call, unsigned long deadline,
    struct hammer2_rframe **fp)
{
	struct hammer2_rconn *rc = call->cdev->rconn;
	struct hammer2_rframe *f;
	kdmsg_msg_t *msg = NULL;
	long left;

	*fp = NULL;
	for (;;) {
		mutex_lock(&rc->mtx);
		f = list_first_entry_or_null(&call->frames,
		    struct hammer2_rframe, entry);
		if (f) {
			list_del(&f->entry);
			/*
			 * Written under the mutex, as every frame on the state
			 * is: the reply callback takes it to see the peer's
			 * DELETE and send ours, and a continuation behind that
			 * would go out on a closed state.
			 */
			if (!call->done && !call->txclosed && !rc->dead &&
			    call->nrecv == call->allowed &&
			    list_empty(&call->frames)) {
				call->allowed += HAMMER2_XOPFIFO;
				msg = kdmsg_msg_alloc(call->state,
				    DMSG_HM2_XOP(call->idx), NULL, NULL);
				kdmsg_msg_write(msg);
			}
			mutex_unlock(&rc->mtx);
			*fp = f;
			return (0);
		}
		if (call->done) {
			mutex_unlock(&rc->mtx);
			return (HAMMER2_ERROR_EOF);
		}
		if (rc->dead) {
			mutex_unlock(&rc->mtx);
			return (HAMMER2_ERROR_ENOTCONN);
		}
		mutex_unlock(&rc->mtx);
		left = (long)(deadline - jiffies);
		if (left <= 0)
			return (HAMMER2_ERROR_ETIMEDOUT);
		wait_event_timeout(rc->waitq,
		    READ_ONCE(call->done) || READ_ONCE(rc->dead) ||
		    !list_empty_careful(&call->frames), left);
	}
}

static void
hammer2_rcall_end(struct hammer2_rcall *call)
{
	struct hammer2_rconn *rc = call->cdev->rconn;

	mutex_lock(&rc->mtx);
	if (!call->done)
		hammer2_rcall_close_locked(call);
	mutex_unlock(&rc->mtx);
	hammer2_rcall_put(call);
}

static void
hammer2_rframe_free(struct hammer2_rframe *f)
{
	kvfree(f->data);
	kfree(f);
}

static int
hammer2_rhandle_same(const struct hammer2_rhandle *a,
    const struct hammer2_rhandle *b)
{
	return (a->type == b->type && a->cmd == b->cmd && a->inum == b->inum &&
	    a->key == b->key && bcmp(&a->clid, &b->clid, sizeof(a->clid)) == 0);
}

/* The handle of a block under one identity, or NULL. */
static struct hammer2_rhandle *
hammer2_rhandle_find(struct hammer2_rconn *rc, unsigned long off,
    const struct hammer2_rhandle *want)
{
	struct hammer2_rhandle *h;

	spin_lock(&rc->hlock);
	for (h = xa_load(&rc->byoff, off); h; h = h->next)
		if (hammer2_rhandle_same(h, want))
			break;
	spin_unlock(&rc->hlock);
	return (h);
}

/*
 * The handle for a fed block: the one this block version already has, or
 * a new one, with the frame's data stashed on it for the first load.
 * Returns the handle number, or 0.
 */
static uint32_t
hammer2_rhandle_get(hammer2_dev_t *cdev, struct hammer2_rframe *f,
    const struct uuid *clid, uint64_t parent_inum)
{
	struct hammer2_rconn *rc = cdev->rconn;
	struct hammer2_rhandle *h, *nh, *xh, want = { 0 };
	unsigned long off = (unsigned long)f->bref.data_off;
	uint32_t id;
	char *old;

	want.type = f->bref.type;
	want.methods = f->bref.methods;
	want.clid = *clid;
	want.key = f->bref.key;
	if (f->bref.type == HAMMER2_BREF_TYPE_INODE) {
		want.cmd = 0;	/* ipcluster, by its own number */
		want.inum = ((hammer2_inode_data_t *)f->data)->meta.inum;
	} else {
		want.cmd = 7;	/* lookup, by key beneath its inode */
		want.inum = parent_inum;
	}

	/*
	 * One block can be live under several identities, a deduplicated
	 * block under two files' keys, and a refetch asks by identity, so a
	 * feed takes the handle of its own identity.  The handles of one
	 * block hang from the first, the one byoff holds, under hlock.
	 */
	h = hammer2_rhandle_find(rc, off, &want);
	if (h == NULL) {
		nh = kzalloc_obj(*nh);
		if (nh == NULL)
			return (0);
		*nh = want;
		if (xa_alloc(&rc->byid, &id, nh, XA_LIMIT(1, 0x7FFFFFFF),
		    GFP_KERNEL)) {
			kfree(nh);
			return (0);
		}
		nh->id = id;
		xh = xa_cmpxchg(&rc->byoff, off, NULL, nh, GFP_KERNEL);
		if (xa_is_err(xh)) {
			xa_erase(&rc->byid, id);
			kfree(nh);
			return (0);
		}
		if (xh == NULL) {
			h = nh;			/* the block's first */
		} else {
			spin_lock(&rc->hlock);
			for (h = xh; h; h = h->next)
				if (hammer2_rhandle_same(h, &want))
					break;		/* raced */
			if (h == NULL) {
				nh->next = xh->next;
				xh->next = nh;
				h = nh;
				nh = NULL;
			}
			spin_unlock(&rc->hlock);
			if (nh) {
				xa_erase(&rc->byid, id);
				kfree(nh);
			}
		}
	}
	spin_lock(&rc->hlock);
	old = h->stash;
	h->stash = f->data;
	h->stash_bytes = f->bytes;
	spin_unlock(&rc->hlock);
	f->data = NULL;
	kvfree(old);

	return (h->id);
}

/*
 * The descriptor's index in the command table, for the descriptors a
 * remote element answers: the read set, and inode_flush, which asks
 * nothing of the peer, since the peer flushes its own element.
 */
#define HAMMER2_REMOTE_IDX_FLUSH	17

static int
hammer2_remote_desc_idx(hammer2_xop_desc_t *desc)
{
	int i;

	for (i = 0; i < DMSG_HM2_XOP_COUNT; ++i)
		if (hammer2_remote_descs[i] == desc)
			return (i);
	if (desc == &hammer2_inode_flush_desc)
		return (HAMMER2_REMOTE_IDX_FLUSH);
	return (-1);
}

/*
 * What the carried consumers trust the media for, checked on every block
 * a peer sends, fed or fetched again: a check method testcheck knows,
 * whose default arm hpanics every device; a compression the decode knows;
 * keybits a shift can take and a key aligned to them, since the slave's
 * pass copies both into its own media; a dirent's name where the media
 * keeps it, in the blockref up to its 64 bytes and in a block past them,
 * since readdir picks one by the length and a copy's check overwrites the
 * other; and an inode's name no longer than its array.  The block's own
 * check is not tested again after its first load, so the content is.
 */
static int
hammer2_remote_feed_ok(const hammer2_blockref_t *bref, uint32_t error,
    uint32_t bytes, const char *data)
{
	hammer2_key_t mask;

	switch (HAMMER2_DEC_CHECK(bref->methods)) {
	case HAMMER2_CHECK_NONE:
	case HAMMER2_CHECK_DISABLED:
	case HAMMER2_CHECK_ISCSI32:
	case HAMMER2_CHECK_XXHASH64:
	case HAMMER2_CHECK_SHA192:
		break;
	default:
		return (0);
	}
	if (HAMMER2_DEC_COMP(bref->methods) > HAMMER2_COMP_ZLIB)
		return (0);
	if (bref->keybits > 63)
		return (0);
	mask = ((hammer2_key_t)1 << bref->keybits) - 1;
	if (bref->key & mask)
		return (0);
	if (error)
		return (1);
	if (bref->type == HAMMER2_BREF_TYPE_DIRENT &&
	    ((bref->embed.dirent.namlen <= sizeof(bref->check.buf)) !=
	    (bytes == 0) || (bytes && bref->embed.dirent.namlen > bytes)))
		return (0);
	if (bref->type == HAMMER2_BREF_TYPE_INODE && bytes &&
	    (bytes < sizeof(hammer2_inode_data_t) || data == NULL ||
	    ((const hammer2_inode_data_t *)data)->meta.name_len >
	    HAMMER2_INODE_MAXNAME))
		return (0);
	return (1);
}

/*
 * Whether a fed chain is one the request can be answered with: a type its
 * storage function feeds and a key in what it asked for.  ipcluster feeds
 * the inode itself, checked by its number, since the slave's pass copies
 * it over the inode it asked about; a readdir, scanlhc or nresolve feeds
 * directory entries and inodes, a readdir from its start (its end is the
 * local element's and the peer's stopping key comes back with its end)
 * and a scanlhc in its hash range; a scanall its key range, whatever the
 * type; a lookup the chain covering its key; a read or bmap the data
 * block covering its offset, or the inode of a direct-data file at
 * offset 0.  bmap names a block number, the others a key.
 */
static int
hammer2_remote_in_range(int idx, const struct hammer2_rframe *f,
    hammer2_key_t key_beg, hammer2_key_t key_end, uint64_t inum)
{
	const hammer2_blockref_t *bref = &f->bref;
	hammer2_key_t last = bref->key |
	    (((hammer2_key_t)1 << bref->keybits) - 1);
	int entry = bref->type == HAMMER2_BREF_TYPE_DIRENT ||
	    bref->type == HAMMER2_BREF_TYPE_INODE;

	switch (idx) {
	case 0:			/* ipcluster */
		if (bref->type != HAMMER2_BREF_TYPE_INODE)
			return (0);
		return (f->error || (f->data &&
		    f->bytes >= sizeof(hammer2_inode_data_t) &&
		    ((const hammer2_inode_data_t *)f->data)->meta.inum == inum));
	case 1:			/* readdir */
		return (entry && last >= key_beg);
	case 2:			/* nresolve */
		return (entry);
	case 5:			/* scanlhc */
		return (entry && bref->key <= key_beg + HAMMER2_DIRHASH_LOMASK &&
		    last >= key_beg);
	case 6:			/* scanall */
		return (bref->key <= key_end && last >= key_beg);
	case 7:			/* lookup */
		return (bref->key <= key_beg && last >= key_beg);
	case 20:		/* bmap */
		key_beg *= hammer2_get_logical();
		fallthrough;
	case 18:		/* strategy_read */
		if (bref->type == HAMMER2_BREF_TYPE_INODE)
			return (key_beg == 0);
		return (bref->type == HAMMER2_BREF_TYPE_DATA &&
		    bref->key <= key_beg && last >= key_beg);
	default:
		return (1);
	}
}

/*
 * A proxy for one fed chain: the peer's blockref with its data_off
 * replaced by the handle, locked as a storage function's chain is when it
 * is fed, its data loaded from the stash.  Only leaves are fed, since
 * chain_lookup and chain_next return leaves.  level is the lockdep level
 * the chain has on the peer, see hammer2_chain_lockdep_remote().  NULL for
 * a frame this protocol never sends.
 */
static hammer2_chain_t *
hammer2_remote_proxy(hammer2_dev_t *cdev, hammer2_pfs_t *pmp,
    struct hammer2_rframe *f, const struct uuid *clid, uint64_t parent_inum,
    unsigned int level)
{
	hammer2_blockref_t bref = f->bref;
	hammer2_chain_t *chain;
	int radix = (int)(bref.data_off & HAMMER2_OFF_MASK_RADIX);
	uint32_t id;

	switch (bref.type) {
	case HAMMER2_BREF_TYPE_INODE:
	case HAMMER2_BREF_TYPE_DATA:
	case HAMMER2_BREF_TYPE_DIRENT:
		break;
	default:
		return (NULL);
	}

	if (!hammer2_remote_feed_ok(&bref, f->error, f->bytes, f->data))
		return (NULL);
	if (f->bytes) {
		if (radix < HAMMER2_RADIX_MIN || radix > HAMMER2_PBUFRADIX ||
		    (1U << radix) != f->bytes)
			return (NULL);
		if (bref.type == HAMMER2_BREF_TYPE_INODE &&
		    f->bytes < sizeof(hammer2_inode_data_t))
			return (NULL);
		if (f->error == 0) {
			id = hammer2_rhandle_get(cdev, f, clid, parent_inum);
			if (id == 0)
				return (NULL);
			bref.data_off = ((hammer2_off_t)id << HAMMER2_PBUFRADIX) |
			    radix;
		} else {
			bref.data_off = radix;	/* no block to load */
		}
	} else {
		/* only a dirent's name fits in its blockref */
		if (f->error == 0 && bref.type != HAMMER2_BREF_TYPE_DIRENT)
			return (NULL);
		bref.data_off = 0;	/* embedded in the blockref */
	}
	chain = hammer2_chain_alloc(cdev, pmp, &bref);
	if (chain == NULL)
		return (NULL);
	hammer2_chain_lockdep_remote(&chain->lock, level);
	if (f->error == 0 && f->bytes)
		hammer2_chain_lock(chain, HAMMER2_RESOLVE_ALWAYS |
		    HAMMER2_RESOLVE_SHARED);
	else
		hammer2_chain_lock(chain, HAMMER2_RESOLVE_NEVER |
		    HAMMER2_RESOLVE_SHARED);
	if (f->error)
		chain->error = f->error;

	return (chain);
}

/*
 * The remote storage function, run by the XOP element loop for every slot
 * in place of the descriptor's own.  Returns 0 for a local element, which
 * the loop then runs; 1 when the element was answered here.
 *
 * The slot is remote when its device is a connection device, read under
 * the root inode's cluster spin, which the registration and the detach
 * write it under, with the device referenced before the spin is dropped.
 * The request names the inode by number and the PFS by cluster id, so the
 * inode's own chain at the slot is not read and an inode whose proxy came
 * from an earlier connection is served by the current one.  A proxy at a
 * slot that is no longer remote is fed as the closed connection.  The
 * wait is bounded for the whole reply, and every way the reply ends feeds
 * what a local element ending that way feeds.
 */
int
hammer2_remote_xop(hammer2_xop_head_t *xop, int clindex)
{
	hammer2_xop_t *x = (hammer2_xop_t *)xop;
	hammer2_inode_t *ip1 = xop->ip1;
	hammer2_pfs_t *pmp = ip1->pmp;
	hammer2_inode_t *iroot = pmp ? pmp->iroot : NULL;
	hammer2_dev_t *cdev = NULL;
	hammer2_chain_t *chain;
	struct hammer2_rcall *call;
	struct hammer2_rframe *f;
	hammer2_key_t key_beg = 0, key_end = 0;
	uint32_t lookup_flags = 0;
	unsigned long deadline, t0 = jiffies;
	const char *name = NULL;
	size_t name_len = 0;
	int proxy, idx, nmax = 0, fed = 0, error;
	unsigned int level;

	hammer2_spin_sh(&ip1->cluster_spin);
	chain = ip1->cluster.array[clindex].chain;
	proxy = chain != NULL && hammer2_dev_is_conn(chain->hmp);
	hammer2_spin_unsh(&ip1->cluster_spin);
	if (iroot) {
		hammer2_spin_sh(&iroot->cluster_spin);
		if (hammer2_dev_is_conn(pmp->pfs_hmps[clindex])) {
			cdev = pmp->pfs_hmps[clindex];
			hammer2_remote_dev_ref(cdev);
		}
		hammer2_spin_unsh(&iroot->cluster_spin);
	}
	if (cdev == NULL) {
		if (!proxy)
			return (0);
		hammer2_xop_feed(xop, NULL, clindex, HAMMER2_ERROR_ENOTCONN);
		return (1);
	}

	idx = hammer2_remote_desc_idx(xop->desc);
	switch (idx) {
	case 0:			/* ipcluster */
		break;
	case 1:			/* readdir */
		key_beg = x->xop_readdir.lkey;
		key_end = x->xop_readdir.rkey;
		nmax = x->xop_readdir.nmax;
		break;
	case 2:			/* nresolve */
		name = xop->name1;
		name_len = xop->name1_len;
		break;
	case 5:			/* scanlhc */
		key_beg = x->xop_scanlhc.lhc;
		break;
	case 6:			/* scanall */
		key_beg = x->xop_scanall.key_beg;
		key_end = x->xop_scanall.key_end;
		lookup_flags = x->xop_scanall.lookup_flags &
		    HAMMER2_REMOTE_LOOKUPF;
		break;
	case 7:			/* lookup */
		key_beg = x->xop_lookup.lhc;
		break;
	case 18:		/* strategy_read */
		key_beg = x->xop_strategy.lbase;
		break;
	case 20:		/* bmap, whose offset stays the local element's */
		key_beg = x->xop_bmap.lbn;
		break;
	case HAMMER2_REMOTE_IDX_FLUSH:
		hammer2_xop_feed(xop, NULL, clindex, 0);
		goto done;
	default:
		hammer2_xop_feed(xop, NULL, clindex, HAMMER2_ERROR_EOPNOTSUPP);
		goto done;
	}

	deadline = jiffies + msecs_to_jiffies(hammer2_remote_timeout_ms);
	call = hammer2_rcall_start(cdev, idx, &pmp->pfs_clid, ip1->meta.inum,
	    key_beg, key_end, lookup_flags, nmax, name, name_len, &error);
	if (call == NULL) {
		hammer2_xop_feed(xop, NULL, clindex, error);
		goto done;
	}
	while ((error = hammer2_rcall_next(call, deadline, &f)) == 0) {
		/*
		 * ipcluster feeds the inode's own chain and the rest its
		 * children, except an inode, which lives under the PFS root
		 * whatever directory names it.
		 */
		if (idx == 0)
			level = ip1->lock.level;
		else if (f->bref.type == HAMMER2_BREF_TYPE_INODE)
			level = iroot->lock.level + 1;
		else
			level = ip1->lock.level + 1;
		chain = NULL;
		if (hammer2_remote_in_range(idx, f, key_beg, key_end,
		    ip1->meta.inum))
			chain = hammer2_remote_proxy(cdev, pmp, f,
			    &pmp->pfs_clid, ip1->meta.inum, level);
		if (chain == NULL) {
			pr_warn_ratelimited("hammer2: HM2 %s feed of type %d not a proxy\n",
			    xop->desc->id, f->bref.type);
			hammer2_rframe_free(f);
			error = HAMMER2_ERROR_EIO;
			break;
		}
		error = hammer2_xop_feed(xop, chain, clindex, f->error);
		hammer2_chain_unlock(chain);
		hammer2_chain_drop(chain);
		hammer2_rframe_free(f);
		++fed;
		if (error)	/* the frontend has gone; the call is cancelled */
			break;
	}
	if (error == HAMMER2_ERROR_EOF) {
		error = call->error;
		/*
		 * The peer's readdir stopped after nmax entries at its rkey,
		 * which the frontend must not pass, as it does not pass the
		 * local element's: an entry beyond it is one this element has
		 * not fed, and the next XOP starts there.  0 is no key.
		 */
		if (idx == 1 && call->eof && call->rkey != 0 &&
		    call->rkey < x->xop_readdir.rkey)
			x->xop_readdir.rkey = call->rkey;
		if (call->eof || error)
			hammer2_xop_feed(xop, NULL, clindex, error);
	} else {
		hammer2_xop_feed(xop, NULL, clindex, error);
	}
	hammer2_rcall_end(call);
	if (hammer2_debug & 0x0100)
		kprintf("H2 REMOTE %s inum=%016llx fed=%d error=%08x ms=%u\n",
		    xop->desc->id, (unsigned long long)ip1->meta.inum, fed,
		    error, jiffies_to_msecs(jiffies - t0));
done:
	hammer2_remote_dev_drop(cdev);
	return (1);
}

/*
 * hammer2_io_getblk_conn()'s fetch, with no lock held: the stash the feed
 * left, or the peer's chain again by the handle.  The refetch takes the
 * block the peer has now, so a chain the peer has moved on reads its
 * current content, as a local chain does under another thread.  A handle
 * the peer no longer resolves reads EIO through load_data, never a fault.
 * Errnos are the DIO layer's, positive.
 */
int
hammer2_remote_fetch(hammer2_dev_t *cdev, hammer2_off_t lbase, int lsize,
    char **bufp)
{
	struct hammer2_rconn *rc = cdev->rconn;
	struct hammer2_rhandle *h;
	struct hammer2_rcall *call;
	struct hammer2_rframe *f;
	unsigned long deadline, t0 = jiffies;
	char *buf;
	int error;

	*bufp = NULL;
	h = xa_load(&rc->byid, (unsigned long)((lbase &
	    ~HAMMER2_OFF_MASK_RADIX) >> HAMMER2_PBUFRADIX));
	if (h == NULL)
		return (EIO);
	spin_lock(&rc->hlock);
	buf = h->stash;
	h->stash = NULL;
	spin_unlock(&rc->hlock);
	if (buf) {
		if (h->stash_bytes != lsize) {
			kvfree(buf);
			return (EIO);
		}
		*bufp = buf;
		return (0);
	}

	/*
	 * ponytail: two threads refetching one handle send two requests and
	 * the second fill is discarded; share one in-flight request when a
	 * contended refetch is measured.
	 */
	deadline = jiffies + msecs_to_jiffies(hammer2_remote_timeout_ms);
	call = hammer2_rcall_start(cdev, h->cmd, &h->clid, h->inum, h->key, 0,
	    0, 0, NULL, 0, &error);
	if (call == NULL)
		return (EIO);
	error = EIO;
	while (hammer2_rcall_next(call, deadline, &f) == 0) {
		if (buf == NULL && f->error == 0 && f->data &&
		    f->bref.type == h->type && f->bref.key == h->key &&
		    f->bytes == (uint32_t)lsize &&
		    f->bref.methods == h->methods &&
		    hammer2_remote_feed_ok(&f->bref, 0, f->bytes, f->data)) {
			buf = f->data;
			f->data = NULL;
			error = 0;
		}
		hammer2_rframe_free(f);
	}
	hammer2_rcall_end(call);
	if (hammer2_debug & 0x0100)
		kprintf("H2 REFETCH handle=%u type=%d error=%d ms=%u\n",
		    h->id, h->type, error, jiffies_to_msecs(jiffies - t0));
	*bufp = buf;

	return (error);
}

/*
 * Registration and detach.  One work item per connection, never the
 * server's queue: two masters span each other at once, and a registration
 * waiting on the one thread that also serves the peer's requests would
 * wait on a peer waiting on it.
 */
#define HAMMER2_REMOTE_NCAND	4	/* spans taken per run */

struct hammer2_rcand {
	kdmsg_state_t		*state;		/* the span, by identity */
	struct uuid		peer_id;	/* its cluster id */
	struct uuid		pfs_id;
	uint8_t			pfs_type;
	hammer2_chain_t		*chain;		/* the root proxy, referenced */
	char			name[HAMMER2_INODE_MAXNAME + 1];
	hammer2_blockset_t	blockset;
};

/*
 * The kernel's own admission, beside h2service's: a copyinfo[] row of this
 * volume, enabled, with the span's cluster id.
 */
static int
hammer2_remote_admitted(hammer2_dev_t *hmp, const struct uuid *clid)
{
	hammer2_volconf_t *v;
	int i, ok = 0;

	hammer2_voldata_lock(hmp);
	for (i = 0; i < HAMMER2_COPYID_COUNT; ++i) {
		v = &hmp->voldata.copyinfo[i];
		if (v->copyid && (v->flags & DMSG_VOLF_ENABLED) &&
		    bcmp(&v->pfs_clid, clid, sizeof(*clid)) == 0) {
			ok = 1;
			break;
		}
	}
	hammer2_voldata_unlock(hmp);

	return (ok);
}

/*
 * The peer PFS's root, by one ipcluster request for inode 1, checked
 * against the span that named it.  Holds only the connection; the proxy is
 * left referenced and unlocked in c->chain, with what the registration
 * reads from its data copied out, since locking it again would refetch.
 */
static int
hammer2_remote_root(hammer2_dev_t *cdev, struct hammer2_rcand *c)
{
	const hammer2_inode_data_t *ripdata;
	struct hammer2_rcall *call;
	struct hammer2_rframe *f;
	hammer2_chain_t *chain = NULL;
	unsigned long deadline;
	size_t len;
	int error;

	deadline = jiffies + msecs_to_jiffies(hammer2_remote_timeout_ms);
	call = hammer2_rcall_start(cdev, 0, &c->peer_id, 1, 0, 0, 0, 0, NULL,
	    0, &error);
	if (call == NULL)
		return (error);
	while ((error = hammer2_rcall_next(call, deadline, &f)) == 0) {
		if (chain == NULL && f->bref.type == HAMMER2_BREF_TYPE_INODE)
			chain = hammer2_remote_proxy(cdev, NULL, f, &c->peer_id,
			    1, 1);	/* a PFS root's level, hammer2_pfsalloc() */
		hammer2_rframe_free(f);
	}
	if (error == HAMMER2_ERROR_EOF)
		error = call->error;
	hammer2_rcall_end(call);
	if (chain == NULL)
		return (error ? error : HAMMER2_ERROR_ENOENT);

	error = HAMMER2_ERROR_EINVAL;
	if (chain->error == 0 && chain->data) {
		ripdata = &chain->data->ipdata;
		if (ripdata->meta.pfs_type == c->pfs_type &&
		    bcmp(&ripdata->meta.pfs_fsid, &c->pfs_id,
		    sizeof(c->pfs_id)) == 0 &&
		    bcmp(&ripdata->meta.pfs_clid, &c->peer_id,
		    sizeof(c->peer_id)) == 0) {
			len = min_t(size_t, ripdata->meta.name_len,
			    HAMMER2_INODE_MAXNAME);
			memcpy(c->name, ripdata->filename, len);
			c->name[len] = 0;
			c->blockset = ripdata->u.blockset;
			error = 0;
		}
	} else if (chain->error) {
		error = chain->error;
	}
	hammer2_chain_unlock(chain);
	if (error) {
		hammer2_chain_drop(chain);
		return (error);
	}
	c->chain = chain;

	return (0);
}

static void
hammer2_remote_span_mark(hammer2_dev_t *hmp, struct hammer2_rcand *c,
    int slotted)
{
	struct hammer2_span *span;

	hammer2_spin_ex(&hmp->span_spin);
	TAILQ_FOREACH(span, &hmp->spanq, entry) {
		if (span->state == c->state &&
		    bcmp(&span->peer_id, &c->peer_id, sizeof(c->peer_id)) == 0) {
			span->tried = 1;
			span->slotted = slotted;
			break;
		}
	}
	hammer2_spin_unex(&hmp->span_spin);
}

/*
 * Whether a span of this link is registered for the cluster id.
 */
static int
hammer2_remote_slotted(hammer2_dev_t *hmp, const struct uuid *clid)
{
	struct hammer2_span *span;
	int found = 0;

	hammer2_spin_ex(&hmp->span_spin);
	TAILQ_FOREACH(span, &hmp->spanq, entry) {
		if (span->slotted &&
		    bcmp(&span->peer_id, clid, sizeof(*clid)) == 0) {
			found = 1;
			break;
		}
	}
	hammer2_spin_unex(&hmp->span_spin);

	return (found);
}

/*
 * Whether the PFS has an element on a block device of this host.
 */
static int
hammer2_remote_local_elm(hammer2_pfs_t *pmp)
{
	int j;

	for (j = 0; j < HAMMER2_MAXCLUSTER; ++j)
		if (pmp->pfs_hmps[j] && !hammer2_dev_is_conn(pmp->pfs_hmps[j]))
			return (1);
	return (0);
}

/*
 * The slot, by the steps hammer2_pfsalloc() takes for a later local mount
 * (chain->pmp, the reference, array[j], pfs_types[j], pfs_names[j],
 * pfs_hmps[j], pfs_iroot_blocksets[j], pfs_nmasters), less two: the
 * device has no mount to count, and no sync thread is created, which
 * would walk the peer's real media offsets through the connection device.
 * The PFS need not be mounted: a SLAVE alone has no quorum to mount by, so
 * its mount follows the element, as DragonFly's mount loop waits for a
 * master to appear.  A PFS mounted read-write is not registered, and a
 * read-write mount or remount is refused while a slot exists, all three
 * under hammer2_mntlk, which the caller holds.  The span is the one
 * queued, still unregistered.
 */
static int
hammer2_remote_register(hammer2_dev_t *hmp, hammer2_dev_t *cdev,
    struct hammer2_rcand *c)
{
	hammer2_pfs_t *pmp;
	hammer2_inode_t *iroot;
	struct hammer2_span *span;
	char *name;
	int found = 0, dead, count, i, j;

	hammer2_spin_ex(&hmp->span_spin);
	TAILQ_FOREACH(span, &hmp->spanq, entry) {
		if (span->state == c->state && !span->tried &&
		    bcmp(&span->peer_id, &c->peer_id, sizeof(c->peer_id)) == 0) {
			span->tried = 1;
			found = 1;
			break;
		}
	}
	hammer2_spin_unex(&hmp->span_spin);
	if (!found)
		return (ENOENT);

	TAILQ_FOREACH(pmp, &hammer2_pfslist, mntentry) {
		if (pmp->iroot && hammer2_remote_local_elm(pmp) &&
		    bcmp(&pmp->pfs_clid, &c->peer_id, sizeof(c->peer_id)) == 0)
			break;
	}
	if (pmp == NULL) {
		kprintf("HAMMER2: remote %s monitored: no local element of its cluster\n",
		    c->name);
		return (ENOENT);
	}
	if (pmp->mp && !pmp->rdonly) {
		kprintf("HAMMER2: remote %s monitored: its PFS is mounted read-write\n",
		    c->name);
		return (EROFS);
	}
	mutex_lock(&cdev->rconn->mtx);
	dead = cdev->rconn->dead;
	mutex_unlock(&cdev->rconn->mtx);
	if (dead)
		return (ENOTCONN);
	for (j = 0; j < HAMMER2_MAXCLUSTER; ++j)
		if (pmp->pfs_hmps[j] == cdev)
			return (EEXIST);

	iroot = pmp->iroot;
	name = hstrdup(c->name);
	hammer2_mtx_ex(&iroot->lock);
	j = iroot->cluster.nchains;
	if (j == HAMMER2_MAXCLUSTER) {
		hammer2_mtx_unlock(&iroot->lock);
		hstrfree(name);
		kprintf("HAMMER2: remote %s monitored: cluster full\n", c->name);
		return (ENOSPC);
	}
	c->chain->pmp = pmp;
	hammer2_spin_ex(&iroot->cluster_spin);
	iroot->cluster.array[j].chain = c->chain;	/* the candidate's reference */
	iroot->cluster.array[j].flags = 0;
	iroot->cluster.array[j].error = 0;
	pmp->pfs_types[j] = c->pfs_type;
	pmp->pfs_names[j] = name;
	pmp->pfs_hmps[j] = cdev;
	iroot->cluster.nchains = j + 1;
	hammer2_spin_unex(&iroot->cluster_spin);
	c->chain = NULL;
	hammer2_spin_ex(&pmp->blockset_spin);
	pmp->pfs_iroot_blocksets[j] = c->blockset;
	hammer2_spin_unex(&pmp->blockset_spin);
	for (count = 0, i = 0; i < iroot->cluster.nchains; ++i)
		if (pmp->pfs_types[i] == HAMMER2_PFSTYPE_MASTER)
			++count;
	if (pmp->pfs_nmasters < count)
		pmp->pfs_nmasters = count;
	hammer2_mtx_unlock(&iroot->lock);

	hammer2_remote_span_mark(hmp, c, 1);
	kprintf("HAMMER2: remote element %s registered at clindex %d, pfs_nmasters %d\n",
	    c->name, j, pmp->pfs_nmasters);

	return (0);
}

/*
 * Under hammer2_mntlk: the steps hammer2_pfsfree_scan() takes for one slot
 * of a departing device, and nothing else of it.  It never frees the PFS:
 * a slot registers only on a PFS with a local element, and the departure
 * of that element's device detaches every remote slot first
 * (hammer2_pfsfree_scan()).  pfs_nmasters is kept, so a detached master is counted
 * absent and a read under the lost quorum says so.
 */
static void
hammer2_remote_detach(hammer2_pfs_t *pmp, int j, const char *why)
{
	hammer2_inode_t *iroot = pmp->iroot;
	hammer2_chain_t *rchain;
	char *name;
	int i;

	hammer2_mtx_ex(&iroot->lock);
	hammer2_spin_ex(&iroot->cluster_spin);
	rchain = iroot->cluster.array[j].chain;
	iroot->cluster.array[j].chain = NULL;
	if (rchain && iroot->cluster.focus == rchain)
		iroot->cluster.focus = NULL;
	pmp->pfs_types[j] = HAMMER2_PFSTYPE_NONE;
	name = pmp->pfs_names[j];
	pmp->pfs_names[j] = NULL;
	pmp->pfs_hmps[j] = NULL;
	for (i = iroot->cluster.nchains; i > 0 && pmp->pfs_hmps[i - 1] == NULL;
	    --i)
		;
	iroot->cluster.nchains = i;
	hammer2_spin_unex(&iroot->cluster_spin);
	hammer2_mtx_unlock(&iroot->lock);
	WARN_ONCE(i == 0, "hammer2: a detach emptied a mounted cluster\n");

	kprintf("HAMMER2: remote element %s at clindex %d detached: %s\n",
	    name ? name : "?", j, why);
	if (name)
		hstrfree(name);
	if (rchain)
		hammer2_chain_drop(rchain);
}

void
hammer2_remote_detach_pmp(hammer2_pfs_t *pmp)
{
	int j;

	if (pmp->iroot == NULL)
		return;
	for (j = 0; j < HAMMER2_MAXCLUSTER; ++j)
		if (hammer2_dev_is_conn(pmp->pfs_hmps[j]))
			hammer2_remote_detach(pmp, j, "unmount");
}

int
hammer2_remote_has_slot(hammer2_pfs_t *pmp)
{
	int j;

	for (j = 0; j < HAMMER2_MAXCLUSTER; ++j)
		if (hammer2_dev_is_conn(pmp->pfs_hmps[j]))
			return (1);
	return (0);
}

/*
 * The work item.  Candidates are the masters' spans not yet tried; each
 * root is fetched holding only the connection, then hammer2_mntlk is tried
 * and, when refused, the item requeues after a delay rather than wait,
 * since every caller of the unmount helper holds that lock while it tears
 * this connection down.  Under the lock: registration, then the detach of
 * every slot on this connection whose span has gone.
 */
static void
hammer2_remote_reconcile(struct work_struct *work)
{
	struct hammer2_remote *rm = container_of(to_delayed_work(work),
	    struct hammer2_remote, regwork);
	hammer2_dev_t *hmp = rm->hmp, *cdev, *ncdev = NULL;
	struct hammer2_rcand *cand;
	struct hammer2_span *span;
	hammer2_pfs_t *pmp;
	unsigned long delay = 0;
	int n = 0, i, j, requeue = 0, error;

	if ((hmp->iocom.flags & KDMSG_IOCOMF_PROTO2) == 0)
		return;
	cand = kcalloc(HAMMER2_REMOTE_NCAND, sizeof(*cand), GFP_KERNEL);
	if (cand == NULL)
		return;

	/* The connection device, made at the link's first registration. */
	spin_lock(&rm->lock);
	cdev = (rm->state == HAMMER2_REMOTE_OPEN) ? rm->cdev : NULL;
	if (cdev)
		hammer2_remote_dev_ref(cdev);
	spin_unlock(&rm->lock);
	if (cdev == NULL) {
		ncdev = hammer2_remote_dev_alloc(hmp);
		spin_lock(&rm->lock);
		if (ncdev && rm->state == HAMMER2_REMOTE_OPEN &&
		    rm->cdev == NULL) {
			rm->cdev = ncdev;	/* the link's reference */
			ncdev = NULL;
		}
		cdev = (rm->state == HAMMER2_REMOTE_OPEN) ? rm->cdev : NULL;
		if (cdev)
			hammer2_remote_dev_ref(cdev);
		spin_unlock(&rm->lock);
		if (ncdev)
			hammer2_remote_dev_drop(ncdev);
	}
	if (cdev == NULL)
		goto out;

	hammer2_spin_ex(&hmp->span_spin);
	TAILQ_FOREACH(span, &hmp->spanq, entry) {
		if (span->tried || span->pfs_type != HAMMER2_PFSTYPE_MASTER)
			continue;
		if (n == HAMMER2_REMOTE_NCAND) {
			requeue = 1;
			break;
		}
		cand[n].state = span->state;
		cand[n].peer_id = span->peer_id;
		cand[n].pfs_id = span->pfs_id;
		cand[n].pfs_type = span->pfs_type;
		strscpy(cand[n].name, span->peer_label, sizeof(cand[n].name));
		++n;
	}
	hammer2_spin_unex(&hmp->span_spin);

	for (i = 0; i < n; ++i) {
		if (!hammer2_remote_admitted(hmp, &cand[i].peer_id)) {
			kprintf("HAMMER2: remote %s monitored: no enabled copyinfo row for its cluster\n",
			    cand[i].name);
			hammer2_remote_span_mark(hmp, &cand[i], 0);
			continue;
		}
		error = hammer2_remote_root(cdev, &cand[i]);
		if (error) {
			kprintf("HAMMER2: remote %s monitored: its root reads %08x\n",
			    cand[i].name, error);
			hammer2_remote_span_mark(hmp, &cand[i], 0);
		}
	}

	if (!hammer2_lk_tryex(&hammer2_mntlk)) {
		requeue = 1;
		delay = msecs_to_jiffies(100);
		goto drop;
	}
	for (i = 0; i < n; ++i)
		if (cand[i].chain)
			hammer2_remote_register(hmp, cdev, &cand[i]);
	TAILQ_FOREACH(pmp, &hammer2_pfslist, mntentry) {
		if (pmp->iroot == NULL)
			continue;
		for (j = 0; j < HAMMER2_MAXCLUSTER; ++j)
			if (pmp->pfs_hmps[j] == cdev &&
			    !hammer2_remote_slotted(hmp, &pmp->pfs_clid))
				hammer2_remote_detach(pmp, j, "span deleted");
	}
	hammer2_lk_unlock(&hammer2_mntlk);
drop:
	for (i = 0; i < n; ++i)
		if (cand[i].chain)
			hammer2_chain_drop(cand[i].chain);
	hammer2_remote_dev_drop(cdev);
out:
	kfree(cand);
	if (requeue)
		mod_delayed_work(system_dfl_wq, &rm->regwork, delay);
}

/*
 * A span arrived or a registered one left: run the work item.  On the
 * reader thread, and on the writer thread for the DELETEs a link's end
 * simulates, when the item is disabled and this queues nothing.
 */
void
hammer2_remote_span(hammer2_dev_t *hmp)
{
	struct hammer2_remote *rm = hmp->remote;

	if (rm)
		mod_delayed_work(system_dfl_wq, &rm->regwork, 0);
}

/*
 * The link this connection device stands for has ended, by a reconnect or
 * the device's teardown: its requests fail now, the work item is stopped
 * (disable_delayed_work_sync(), since a cancel would let it requeue), and
 * every slot on it is detached under hammer2_mntlk, which the teardown's
 * caller already holds and a reconnect, on the ioctl's thread, takes.  A
 * reconnect re-enables the item for the next link.  The device itself
 * lives until its last proxy.
 */
static void
hammer2_remote_conn_end(struct hammer2_remote *rm, int final)
{
	hammer2_dev_t *cdev;
	hammer2_pfs_t *pmp;
	struct hammer2_span *span;
	int j;

	spin_lock(&rm->lock);
	cdev = rm->cdev;
	rm->cdev = NULL;
	spin_unlock(&rm->lock);
	if (cdev)
		hammer2_remote_dev_kill(cdev);
	disable_delayed_work_sync(&rm->regwork);
	if (cdev) {
		if (!final)
			hammer2_lk_ex(&hammer2_mntlk);
		TAILQ_FOREACH(pmp, &hammer2_pfslist, mntentry) {
			if (pmp->iroot == NULL)
				continue;
			for (j = 0; j < HAMMER2_MAXCLUSTER; ++j)
				if (pmp->pfs_hmps[j] == cdev)
					hammer2_remote_detach(pmp, j,
					    "connection ended");
		}
		if (!final)
			hammer2_lk_unlock(&hammer2_mntlk);
		hammer2_remote_dev_drop(cdev);	/* the link's reference */
	}
	hammer2_spin_ex(&rm->hmp->span_spin);
	TAILQ_FOREACH(span, &rm->hmp->spanq, entry) {
		span->tried = 1;	/* the old link's, whose DELETEs follow */
		span->slotted = 0;
	}
	hammer2_spin_unex(&rm->hmp->span_spin);
	if (!final)
		enable_delayed_work(&rm->regwork);
}
