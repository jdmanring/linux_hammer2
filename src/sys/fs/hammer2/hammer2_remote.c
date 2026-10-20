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
#include <linux/sched.h>
#include <linux/wait.h>
#include <linux/workqueue.h>

#include "hammer2.h"

struct hammer2_remote {
	struct workqueue_struct	*wq;		/* ordered: one request at a time */
	spinlock_t		lock;		/* reqq, req->window, req->cancelled */
	struct list_head	reqq;		/* queued or running */
	int			stopping;	/* the connection is going */
};

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

static void hammer2_remote_serve(struct work_struct *);

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
	} else {
		hprintf("no HM2 server for this device: out of memory\n");
	}
	hmp->remote = rm;
}

/*
 * Close the queue to the connection being replaced or torn down and fail
 * every request on it: once stopping is set under the lock no CREATE is
 * admitted, a queued request closes as it runs, a running one at its next
 * wait, and the flush returns when the queue is empty.  The reader thread
 * is still alive here and may deliver frames, which is why admission
 * closes under the same lock the reader queues under, and why the queue
 * itself is freed only by hammer2_remote_uninit(), after the message
 * threads are gone.  A reconnect reopens the queue with
 * hammer2_remote_resume() once the new connection's threads run.
 */
void
hammer2_remote_quiesce(hammer2_dev_t *hmp)
{
	struct hammer2_remote *rm = hmp->remote;
	struct hammer2_remote_req *req;

	if (rm == NULL)
		return;
	spin_lock(&rm->lock);
	rm->stopping = 1;
	list_for_each_entry(req, &rm->reqq, entry)
		wake_up(&req->waitq);
	spin_unlock(&rm->lock);
	flush_workqueue(rm->wq);
}

void
hammer2_remote_resume(hammer2_dev_t *hmp)
{
	struct hammer2_remote *rm = hmp->remote;

	if (rm)
		WRITE_ONCE(rm->stopping, 0);
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
	WARN_ON(!rm->stopping);
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
		 * set stopping before this point sees the request in its
		 * flush and one that sets it after refuses the next request.
		 */
		spin_lock(&rm->lock);
		if (rm->stopping) {
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
 * The transaction's DELETE, a feed frame with no chain whose error is the
 * element's final one, what hammer2_xop_feed() would have been given with
 * a NULL chain.  A refusal is kern_dmsg's own LNK_ERROR reply instead, so
 * the peer tells the two apart by the closing frame's command.
 */
static void
hammer2_remote_close(struct hammer2_remote_req *req, uint32_t error)
{
	kdmsg_msg_t *msg;
	uint32_t cmd = DMSG_HM2_FEED | DMSGF_REPLY | DMSGF_DELETE;

	if ((req->state->txcmd & DMSGF_CREATE) == 0)
		cmd |= DMSGF_CREATE;
	msg = kdmsg_msg_alloc(req->state, cmd, NULL, NULL);
	msg->any.hm2_feed.error = error;
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
	    READ_ONCE(req->cancelled) || READ_ONCE(rm->stopping) ||
	    READ_ONCE(req->window) > fed,
	    msecs_to_jiffies(hammer2_remote_timeout_ms));
	if (READ_ONCE(req->cancelled) || READ_ONCE(rm->stopping))
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
 * take here would wait on the unmount waiting on it; stopping ends the
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
		if (READ_ONCE(req->cancelled) || READ_ONCE(rm->stopping) ||
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
	int clindex = 0, fed = 0, nerror, refused = 0;

	if (READ_ONCE(req->cancelled) || READ_ONCE(rm->stopping)) {
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
		    (req->req.lookup_flags & HAMMER2_LOOKUP_NODATA);
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
	while (fifo->ri != fifo->wi) {
		chain = fifo->array[fifo->ri & fifo_mask(&xop->head)];
		nerror = fifo->errors[fifo->ri & fifo_mask(&xop->head)];
		++fifo->ri;
		if (chain == NULL) {
			error = nerror;
			break;
		}
		if (fed >= READ_ONCE(req->window)) {
			error = hammer2_remote_window(req, fed);
			if (error) {
				hammer2_chain_drop_unhold(chain);
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
		kprintf("H2 SERVE %s inum=%016llx fed=%d error=%08x%s ms=%u\n",
		    desc->id, (unsigned long long)req->req.inum, fed, error,
		    refused ? " refused" : "", jiffies_to_msecs(jiffies - t0));

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
		hammer2_remote_close(req, error);

	if (xop) {
		hammer2_xop_retire(&xop->head, 1U << clindex);
		hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);
	}
	if (ip)
		hammer2_inode_drop(ip);
	kdmsg_free_aux_data(&req->aux);
	kfree(req);
}
