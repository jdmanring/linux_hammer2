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
	struct delayed_work	pingwork;	/* the keepalive */
	unsigned long		ping_sent;	/* jiffies of the ping awaiting its answer, 0 none */
	struct list_head	snaps;		/* snapshots taken for this link, rm->lock */
};

/*
 * A snapshot the server took for the peer, by name on this device, deleted
 * at the peer's SNAPDEL or, if the link ends first, at the link's end.
 */
struct hammer2_remote_snap {
	struct list_head	entry;
	char			name[HAMMER2_INODE_MAXNAME];
};

/* The suffix of a synchronization pass's source snapshot, hammer2_synchro.c. */
#define HAMMER2_REMOTE_SNAP_SUFFIX	".h2sync-src"

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
	uint32_t		nsent;		/* feeds sent, each frame's seq */
	unsigned long		deadline;	/* the whole request's bound */
};

/*
 * The lookup flag a scanall request carries: whether a direct-data inode
 * answers as itself.  The slave's pass asks for NODIRECT; without it a
 * direct-data file's scan fed the file's own inode, the pass inserted it
 * beneath itself, and the flush recursed to its limit.  NODATA is not
 * carried: the server's scan runs with LOOKUP_ALWAYS, which resolves data
 * whatever else is asked, and every feed ships its chain's data.  The lock
 * modes stay the server's.
 */
#define HAMMER2_REMOTE_LOOKUPF	HAMMER2_LOOKUP_NODIRECT

/*
 * The read set of the command table: the descriptor at each index the
 * server runs, NULL where the command modifies and is refused; the two
 * indices past the descriptors are the snapshot commands, served here with
 * no storage function.
 */
static hammer2_xop_desc_t *const hammer2_remote_descs[DMSG_HM2_CMD_COUNT] = {
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
_Static_assert(sizeof(dmsg_hm2_xop_t) == 128, "a request frame's size");

static const char *
hammer2_remote_cmd_name(int idx)
{
	if (idx == DMSG_HM2_SNAPSHOT_IDX)
		return ("snapshot");
	if (idx == DMSG_HM2_SNAPDEL_IDX)
		return ("snapdel");
	return (hammer2_remote_descs[idx]->id);
}

static void hammer2_remote_serve(struct work_struct *);
static void hammer2_remote_reconcile(struct work_struct *);
static void hammer2_remote_keepalive(struct work_struct *);
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
		INIT_DELAYED_WORK(&rm->pingwork, hammer2_remote_keepalive);
		INIT_LIST_HEAD(&rm->snaps);
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

/*
 * The peer announced PROTO_2, on the reader thread: requests are admitted
 * and the keepalive starts, its first ping half a bound from now.
 */
void
hammer2_remote_resume(hammer2_dev_t *hmp)
{
	struct hammer2_remote *rm = hmp->remote;

	if (rm == NULL)
		return;
	spin_lock(&rm->lock);
	if (rm->state == HAMMER2_REMOTE_QUIESCED)
		rm->state = HAMMER2_REMOTE_OPEN;
	rm->ping_sent = 0;
	spin_unlock(&rm->lock);
#ifndef HAMMER2_NOKEEPALIVE
	mod_delayed_work(system_dfl_wq, &rm->pingwork,
	    msecs_to_jiffies(hammer2_remote_timeout_ms / 2));
#endif
}

/*
 * The keepalive (doc/CLUSTER_PROTOCOL_DESIGN.md, the client side).
 * kern_dmsg has none, so a partition that drops frames and keeps the socket
 * would be seen only when a request reached its bound, and on a link with
 * no request in flight never.  A PROTO_2 link carries this second work item
 * for it alone, which neither the registration item nor a server busy in a
 * request holds up.  Every half of the bound it sends LNK_PING as a
 * CREATE|DELETE transaction, since the carried kernel answers no one-way
 * PING (C15) and a transaction left open would leak a state per ping; the
 * peer's refusal of it, LNK_ERROR with DMSG_ERR_NOSUPP, is the answer, and
 * so is the DELETE the link's own end simulates, after which the item sees
 * KILLRX and stops.  A ping unanswered for the bound ends the link by the
 * reader's own path, KILLRX and the descriptor shut down as a reconnect
 * does it, never by the teardown, which disables this item and would wait
 * on itself; the link's end then reaches the element as its span deleted.
 * HAMMER2_NOKEEPALIVE builds the negative control, which never arms the
 * item: under it a silent peer is seen at the next request's bound and
 * never before.
 */
static int
hammer2_remote_pong(kdmsg_state_t *state, kdmsg_msg_t *msg)
{
	struct hammer2_remote *rm = state->any.any;

	if (msg->any.head.cmd & DMSGF_DELETE) {
		spin_lock(&rm->lock);
		rm->ping_sent = 0;
		spin_unlock(&rm->lock);
	}
	return (0);
}

static void
hammer2_remote_keepalive(struct work_struct *work)
{
	struct hammer2_remote *rm = container_of(to_delayed_work(work),
	    struct hammer2_remote, pingwork);
	kdmsg_iocom_t *iocom = &rm->hmp->iocom;
	kdmsg_msg_t *msg;
	unsigned long sent, bound = msecs_to_jiffies(hammer2_remote_timeout_ms);

	if ((iocom->flags & KDMSG_IOCOMF_PROTO2) == 0 ||
	    (iocom->msg_ctl & KDMSG_CLUSTERCTL_KILLRX))
		return;
	spin_lock(&rm->lock);
	sent = rm->ping_sent;
	if (sent == 0)
		rm->ping_sent = jiffies | 1;	/* never the 0 that means none */
	spin_unlock(&rm->lock);
	if (sent == 0) {
		msg = kdmsg_msg_alloc(&iocom->state0,
		    DMSG_LNK_PING | DMSGF_CREATE | DMSGF_DELETE,
		    hammer2_remote_pong, rm);
		kdmsg_msg_write(msg);
	} else if (time_after_eq(jiffies, sent + bound)) {
		pr_warn("hammer2: HM2 peer silent for %u ms, ending the link\n",
		    jiffies_to_msecs(jiffies - sent));
		lockmgr(&iocom->msglk, LK_EXCLUSIVE);
		atomic_set_int(&iocom->msg_ctl, KDMSG_CLUSTERCTL_KILLRX);
		if (iocom->msg_fp)
			fp_shutdown(iocom->msg_fp, SHUT_RDWR);
		lockmgr(&iocom->msglk, LK_RELEASE);
		return;
	}
	mod_delayed_work(system_dfl_wq, &rm->pingwork, max(bound / 2, 1UL));
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
		else if (idx < 0 || idx >= DMSG_HM2_CMD_COUNT)
			why = "not a command";
		else if (idx < DMSG_HM2_XOP_COUNT &&
		    hammer2_remote_descs[idx] == NULL)
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
			kdmsg_msg_reply(msg, DMSG_ERR_LOSTLINK);
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
	msg->any.hm2_feed.seq = req->nsent++;
	memcpy(msg->any.hm2_feed.tag, req->req.tag, sizeof(req->req.tag));
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
    hammer2_key_t rkey, hammer2_tid_t tid)
{
	kdmsg_msg_t *msg;
	uint32_t cmd = DMSG_HM2_FEED | DMSGF_REPLY | DMSGF_DELETE;

	if ((req->state->txcmd & DMSGF_CREATE) == 0)
		cmd |= DMSGF_CREATE;
	msg = kdmsg_msg_alloc(req->state, cmd, NULL, NULL);
	msg->any.hm2_feed.error = error;
	msg->any.hm2_feed.rkey = rkey;
	msg->any.hm2_feed.tid = tid;
	msg->any.hm2_feed.seq = req->nsent;	/* the count the peer checks */
	memcpy(msg->any.hm2_feed.tag, req->req.tag, sizeof(req->req.tag));
	if (eof)
		msg->any.hm2_feed.flags = DMSG_HM2_FEEDF_EOF;
	kdmsg_msg_write(msg);
}

/*
 * The window: HAMMER2_XOPFIFO feeds per continuation.  The wait runs to
 * the request's own deadline, not a bound per window, since the request
 * holds hammer2_mntlk throughout and a peer continuing just inside a
 * per-window bound would hold it for as many windows as the scan has.  It
 * ends early on the peer's DELETE and on the connection's end.
 * HAMMER2_NOWINDOW builds the negative control, which must send past it.
 */
static int
hammer2_remote_window(struct hammer2_remote_req *req, int fed)
{
#ifndef HAMMER2_NOWINDOW
	struct hammer2_remote *rm = req->hmp->remote;
	long left = (long)(req->deadline - jiffies);

	if (left > 0)
		wait_event_timeout(req->waitq,
		    READ_ONCE(req->cancelled) ||
		    READ_ONCE(rm->state) != HAMMER2_REMOTE_OPEN ||
		    READ_ONCE(req->window) > fed, left);
	if (READ_ONCE(req->cancelled) || READ_ONCE(rm->state) != HAMMER2_REMOTE_OPEN)
		return (HAMMER2_ERROR_ABORTED);
	if (READ_ONCE(req->window) <= fed)
		return (HAMMER2_ERROR_ETIMEDOUT);
#endif
	return (0);
}

/*
 * Whether a name is one of the synchronization pass's source snapshots,
 * the only PFS a peer may have this server create, delete or read unmounted.
 */
static int
hammer2_remote_snap_name(const char *name)
{
	size_t len, slen = strlen(HAMMER2_REMOTE_SNAP_SUFFIX);

	if (name == NULL)
		return (0);
	len = strlen(name);
	return (len > slen && len < HAMMER2_INODE_MAXNAME &&
	    strcmp(name + len - slen, HAMMER2_REMOTE_SNAP_SUFFIX) == 0);
}

/*
 * The snapshot commands, under hammer2_mntlk with the PFS found.  SNAPSHOT
 * takes the pass's source snapshot of this device's element by the body the
 * local pass uses, a stale one of the name deleted first as the local pass
 * deletes it, records the name against the link, and feeds the snapshot
 * root's chain with the transaction id on the closing frame; SNAPDEL
 * deletes a snapshot this link took and forgets it.  The name is the aux,
 * only a name under the pass's suffix is taken and only this link's is
 * deleted, so a peer cannot have a PFS of its choosing deleted.  Returns
 * the final error, with *chainp the chain
 * to feed, held and unlocked, and *tidp the id.
 */
static uint32_t
hammer2_remote_snapshot(struct hammer2_remote_req *req, hammer2_pfs_t *pmp,
    int clindex, hammer2_chain_t **chainp, hammer2_tid_t *tidp)
{
	hammer2_dev_t *hmp = req->hmp;
	struct hammer2_remote *rm = hmp->remote;
	struct hammer2_remote_snap *snap, *n;
	hammer2_pfs_t *spmp = NULL;
	char name[HAMMER2_INODE_MAXNAME];
	int error;

	*chainp = NULL;
	*tidp = 0;
	if (req->aux.aux_data == NULL || req->aux.aux_size == 0 ||
	    req->aux.aux_size >= sizeof(name))
		return (HAMMER2_ERROR_EINVAL);
	memcpy(name, req->aux.aux_data, req->aux.aux_size);
	name[req->aux.aux_size] = 0;
	if (!hammer2_remote_snap_name(name) || strchr(name, '/'))
		return (HAMMER2_ERROR_EINVAL);

	if (req->idx == DMSG_HM2_SNAPDEL_IDX) {
		/*
		 * Only a snapshot this link took is deleted: a name it never
		 * took, a crash's leftover or another pass's live source, is
		 * left as it is and the peer is told nothing was there.  A
		 * leftover goes at the next SNAPSHOT's stale delete.  The peer
		 * names the snapshot by its own cluster id, so the PFS found
		 * is the one freed here; the caller reads nothing of it after.
		 */
		int taken = 0;

		spin_lock(&rm->lock);
		list_for_each_entry(snap, &rm->snaps, entry)
			if (strcmp(snap->name, name) == 0)
				taken = 1;
		spin_unlock(&rm->lock);
		if (!taken && !HAMMER2_CTL_NOSNAPSCOPE) {
			if (hammer2_debug & 0x8000)
				kprintf("syncsnap: peer named %s, not this link's\n",
				    name);
			return (0);
		}
		error = hammer2_pfs_delete_byname(hmp, name,
		    HAMMER2_PFSDEL_LOCKED);
		if (error && error != ENOENT) {
			kprintf("syncsnap: peer's delete of %s error %d\n", name,
			    error);
			return (HAMMER2_ERROR_EIO);	/* still the link's */
		}
		spin_lock(&rm->lock);
		list_for_each_entry_safe(snap, n, &rm->snaps, entry) {
			if (strcmp(snap->name, name) == 0) {
				list_del(&snap->entry);
				kfree(snap);
			}
		}
		spin_unlock(&rm->lock);
		if (hammer2_debug & 0x8000)
			kprintf("syncsnap: peer deleted %s error %d\n", name, error);
		return (0);
	}

	snap = kzalloc_obj(*snap);
	if (snap == NULL)
		return (HAMMER2_ERROR_ENOSPC);
	strscpy(snap->name, name, sizeof(snap->name));
	error = hammer2_pfs_delete_byname(hmp, name, HAMMER2_PFSDEL_LOCKED);
	if (error && error != ENOENT) {
		kfree(snap);
		return (HAMMER2_ERROR_EIO);
	}
	if (error == 0 && (hammer2_debug & 0x8000))
		kprintf("syncsnap: stale %s deleted for a peer\n", name);
	error = hammer2_pfs_snapshot(pmp, clindex, name,
	    HAMMER2_PFSSNAP_PMPSYNC, tidp, &spmp);
	if (error || spmp == NULL || spmp->iroot == NULL) {
		kfree(snap);
		kprintf("syncsnap: snapshot %s for a peer error %d\n", name,
		    error);
		return (HAMMER2_ERROR_EIO);
	}
	spin_lock(&rm->lock);
	list_add_tail(&snap->entry, &rm->snaps);
	spin_unlock(&rm->lock);
	*chainp = hammer2_inode_chain(spmp->iroot, 0, HAMMER2_RESOLVE_ALWAYS);
	if (*chainp == NULL)
		return (HAMMER2_ERROR_EIO);
	hammer2_chain_unlock(*chainp);
	if (hammer2_debug & 0x8000)
		kprintf("syncsnap: snapshot %s for a peer tid %016llx\n", name,
		    (long long)*tidp);
	return (0);
}

/*
 * The snapshots a link leaves, deleted at its end under hammer2_mntlk,
 * which the teardown's caller holds and a reconnect takes; the peer's pass
 * deletes its own, so what is here is what a lost link left.
 */
static void
hammer2_remote_snaps_drop(struct hammer2_remote *rm)
{
	struct hammer2_remote_snap *snap, *n;
	LIST_HEAD(left);
	int error;

	spin_lock(&rm->lock);
	list_splice_init(&rm->snaps, &left);
	spin_unlock(&rm->lock);
	list_for_each_entry_safe(snap, n, &left, entry) {
		error = hammer2_pfs_delete_byname(rm->hmp, snap->name,
		    HAMMER2_PFSDEL_LOCKED);
		kprintf("HAMMER2: snapshot %s left by the link deleted, error %d\n",
		    snap->name, error);
		list_del(&snap->entry);
		kfree(snap);
	}
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
 * a PFS is found and released otherwise, with *errorp saying why: 0 when
 * this device has no such PFS mounted, a refusal, and ABORTED or ETIMEDOUT
 * when the lock was not had, which says nothing of what the device holds.
 */
static hammer2_pfs_t *
hammer2_remote_pfs(struct hammer2_remote_req *req, int *clindexp,
    uint32_t *errorp)
{
	hammer2_dev_t *hmp = req->hmp;
	struct hammer2_remote *rm = hmp->remote;
	hammer2_pfs_t *pmp;
	int i;

	*errorp = 0;
	while (!hammer2_lk_tryex(&hammer2_mntlk)) {
		if (READ_ONCE(req->cancelled) || READ_ONCE(rm->state) != HAMMER2_REMOTE_OPEN) {
			*errorp = HAMMER2_ERROR_ABORTED;
			return (NULL);
		}
		if (time_after(jiffies, req->deadline)) {
			*errorp = HAMMER2_ERROR_ETIMEDOUT;
			return (NULL);
		}
		schedule_timeout_uninterruptible(msecs_to_jiffies(10));
	}
	TAILQ_FOREACH(pmp, &hammer2_pfslist, mntentry) {
		if (pmp->iroot == NULL)
			continue;
		if (bcmp(&pmp->pfs_clid, &req->req.pfs_clid,
		    sizeof(pmp->pfs_clid)) != 0)
			continue;
		for (i = 0; i < pmp->iroot->cluster.nchains; ++i)
			if (pmp->pfs_hmps[i] == hmp)
				break;
		if (i == pmp->iroot->cluster.nchains)
			continue;
		/*
		 * A mounted PFS, or an unmounted one this server snapshotted
		 * for a peer's pass, which is never mounted and is named by
		 * its suffix; every other unmounted PFS of the device is not
		 * served, whatever cluster id a peer names.
		 */
		if (pmp->mp == NULL && !hammer2_remote_snap_name(pmp->pfs_names[i]))
			continue;
		*clindexp = i;
		return (pmp);	/* hammer2_mntlk held */
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
	hammer2_tid_t tid = 0;
	unsigned long t0 = jiffies;
	uint32_t error = 0;
	int clindex = 0, fed = 0, nerror, refused = 0, eof = 1;

	/*
	 * One bound for the whole request, from here to its closing frame,
	 * since everything from the PFS's lookup on holds hammer2_mntlk.
	 */
	req->deadline = t0 + msecs_to_jiffies(hammer2_remote_timeout_ms);
	if (READ_ONCE(req->cancelled) || READ_ONCE(rm->state) != HAMMER2_REMOTE_OPEN) {
		error = HAMMER2_ERROR_ABORTED;
		goto out;
	}
	pmp = hammer2_remote_pfs(req, &clindex, &error);
	if (pmp == NULL && error) {
		pr_warn_ratelimited("hammer2: HM2 %s not served: %s\n",
		    hammer2_remote_cmd_name(req->idx),
		    error == HAMMER2_ERROR_ETIMEDOUT ?
		    "the mount lock stayed held to the bound" :
		    "the request or the connection ended");
		goto out;
	}
	if (pmp == NULL) {
		pr_warn_ratelimited("hammer2: HM2 %s refused: no mounted PFS of that cluster on this device\n",
		    hammer2_remote_cmd_name(req->idx));
		refused = 1;
		goto out;
	}
	if (desc == NULL) {
		/* the snapshot commands: one chain or none, then the end */
		error = hammer2_remote_snapshot(req, pmp, clindex, &chain, &tid);
		if (chain) {
			hammer2_remote_feed(req, chain, 0);
			hammer2_chain_drop(chain);
			chain = NULL;
			fed = 1;
		}
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
		/* a count of 0 or less would never stop the scan */
		xop->xop_readdir.nmax = clamp_t(int, req->req.nmax, 1,
		    HAMMER2_READDIR_NMAX);
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
	/*
	 * run_mask and chk_mask as hammer2_xop_start_except() sets them for
	 * one element: chk_mask is the set of FIFOs the retire drains, so
	 * without it every chain an early end leaves keeps its reference.
	 */
	xop->head.desc = desc;
	atomic_set_32(&xop->head.chk_mask, 1U << clindex);
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
		    hammer2_remote_cmd_name(req->idx),
		    (unsigned long long)req->req.inum, fed, error,
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
		    HAMMER2_KEY_MAX, tid);

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
	uint64_t		ntag;		/* the last call's tag */
	refcount_t		refs;		/* the link's, each chain's, each user's */
	wait_queue_head_t	waitq;		/* every call on the link */
	spinlock_t		hlock;		/* handle stashes */
	struct xarray		byid;		/* handle number -> handle */
	struct xarray		byoff;		/* the peer's data_off -> handle */
	struct work_struct	free_work;
	/*
	 * Where a frame's block goes, counted at each hand-over so the
	 * device's free can print the balance: copied from the frame, freed
	 * with its frame, stashed on a handle, a stash replaced by a newer
	 * feed, a stash taken by a load, a fetched block dropped for a dio
	 * filled meanwhile, a block freed with its dio, a stash freed here.
	 */
	atomic_t		nb_copied, nb_framed, nb_stashed, nb_replaced,
				nb_taken, nb_dropped, nb_diofreed, nb_devfreed;
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
	uint8_t			methods;	/* the fed bref's, which decodes it */
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

static void hammer2_rframe_free_on(struct hammer2_rconn *, struct hammer2_rframe *);

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
	uint64_t		tag;		/* sent with the request, echoed */
	struct list_head	frames;		/* received, not yet taken */
	int			nrecv;		/* feeds received */
	int			allowed;	/* feeds the window allows */
	int			txclosed;	/* our DELETE is sent */
	int			done;		/* the peer's DELETE arrived */
	int			eof;		/* the element fed its end */
	hammer2_key_t		rkey;		/* a readdir's, from the end; 0 none */
	hammer2_tid_t		tid;		/* a snapshot's, from the end */
	uint32_t		error;		/* HAMMER2_ERROR_* of the end */
};

/* A connection block freed by the DIO layer, for the balance above. */
void
hammer2_remote_block_freed(hammer2_dev_t *cdev, int dropped)
{
	atomic_inc(dropped ? &cdev->rconn->nb_dropped : &cdev->rconn->nb_diofreed);
}

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
		if (h->stash)
			atomic_inc(&rc->nb_devfreed);
		kvfree(h->stash);
		kfree(h);
	}
	xa_destroy(&rc->byid);
	xa_destroy(&rc->byoff);
	mutex_destroy(&rc->mtx);
	if (hammer2_debug & 0x0100)
		kprintf("H2 CDEV freed: blocks copied %d framed %d stashed %d replaced %d taken %d dropped %d diofreed %d devfreed %d\n",
		    atomic_read(&rc->nb_copied), atomic_read(&rc->nb_framed),
		    atomic_read(&rc->nb_stashed), atomic_read(&rc->nb_replaced),
		    atomic_read(&rc->nb_taken), atomic_read(&rc->nb_dropped),
		    atomic_read(&rc->nb_diofreed), atomic_read(&rc->nb_devfreed));
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
 * The link has ended: no request is sent on it again, and every request in
 * flight fails now with the closed-connection code rather than at its
 * bound.  Its transactions still close (hammer2_rcall_close_locked()).
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
	list_for_each_entry_safe(f, n, &call->frames, entry)
		hammer2_rframe_free_on(cdev->rconn, f);
	kfree(call);
	hammer2_remote_dev_drop(cdev);
}

/*
 * Our side's DELETE, an HM2 frame so the server's queue sees it and
 * cancels a request still running.  Under the connection's mutex.  It goes
 * out on a dead link too: kern_dmsg frees a state only once both
 * directions are closed, and its writer, exiting, waits for every state
 * (kern_dmsg.c, kdmsg_iocom_thread_wr()) and drains a write to a dying
 * one locally, so a DELETE withheld there wedges the redial and the
 * unmount behind it.
 */
static void
hammer2_rcall_close_locked(struct hammer2_rcall *call)
{
	kdmsg_msg_t *msg;

	if (call->txclosed)
		return;
	call->txclosed = 1;
	msg = kdmsg_msg_alloc(call->state,
	    DMSG_HM2_XOP(call->idx) | DMSGF_DELETE, NULL, NULL);
	kdmsg_msg_write(msg);
}

/*
 * A fed chain's error: one of the media errors a chain carries, which the
 * collect reads as a local chain's, or EIO.  Any other bit is a control
 * code the core acts on (EAGAIN restarts the sync pass with no sleep,
 * ESRCH and EDEADLK are quorum verdicts) and no chain carries one.
 */
#define HAMMER2_REMOTE_CHAIN_ERRORS	(HAMMER2_ERROR_EIO | \
	HAMMER2_ERROR_CHECK | HAMMER2_ERROR_BADBREF)

static uint32_t
hammer2_remote_error(uint32_t error)
{
	return ((error & ~HAMMER2_REMOTE_CHAIN_ERRORS) ? HAMMER2_ERROR_EIO : error);
}

/*
 * The element's end, the error fed with its NULL chain, which the quorum
 * check reads as this master's vote (hammer2_cluster.c): a clean end, 0,
 * or ENOENT, no such key, are what a master says of the key and count.
 * Every other end is the absence of an answer, whatever made it (a
 * refusal, a server that could not take its mount lock, a frame this side
 * could not take, the peer's own media error, the bound, the link's loss),
 * and reads as unreachable, which the check counts as no vote.  A peer
 * that lies about a key is admission's to keep out
 * (doc/CLUSTER_PROTOCOL_DESIGN.md, the security model); one that fails to
 * answer must never be read as having answered, and an allowlist keeps a
 * new way of failing on the unreachable side without anyone listing it.
 */
static uint32_t
hammer2_remote_end(uint32_t error)
{
	if (error == 0 || error == HAMMER2_ERROR_ENOENT ||
	    error == HAMMER2_ERROR_ETIMEDOUT)
		return (error);
	return (HAMMER2_ERROR_ENOTCONN);
}

/*
 * The reply callback, on the reader thread, and on the writer thread for
 * the DELETEs the link's end simulates.  A frame is copied and queued; the
 * window, the frame's shape and its place in the reply are checked here,
 * where they can be read, and a peer breaking any ends the link by the
 * reader's own shutdown.
 *
 * The state outlives the call: it stays in kern_dmsg's tree until the
 * client's own DELETE goes out, and kern_dmsg passes a frame after the peer's DELETE
 * to this callback as it passed the ones before.  So the close clears the
 * call from the state before the transaction's reference goes, and a
 * frame finding none ends the link rather than reading a call its
 * consumer may have freed.  The link's simulated end reaches only a state
 * whose peer has not closed, and a frame arrives on the reader thread
 * that ran the close, so the test needs no lock.
 */
static int
hammer2_rcall_reply(kdmsg_state_t *state, kdmsg_msg_t *msg)
{
	struct hammer2_rcall *call = state->any.any;
	struct hammer2_rconn *rc;
	struct hammer2_rframe *f = NULL;
	uint32_t cmd = msg->any.head.cmd;
	const char *bad = NULL;
	int feed, lost = 0;

	if (call == NULL) {
		pr_warn_ratelimited("hammer2: HM2 peer sent a frame after its reply closed, ending the link\n");
		atomic_set_int(&state->iocom->msg_ctl, KDMSG_CLUSTERCTL_KILLRX);
		return (0);
	}
	rc = call->cdev->rconn;
	feed = (cmd & DMSGF_BASECMDMASK) == (DMSG_HM2_FEED & DMSGF_BASECMDMASK);
	if (feed && (cmd & DMSGF_DELETE) && msg->any.hm2_feed.bytes) {
		bad = "sent a closing feed with a chain";
	} else if (feed && (cmd & DMSGF_DELETE) == 0) {
		/* a chain, its bytes in the aux data or in its blockref */
		f = kzalloc_obj(*f);
		if (f) {
			memcpy(&f->bref, msg->any.hm2_feed.bref, sizeof(f->bref));
			f->bytes = msg->any.hm2_feed.bytes;
			f->error = hammer2_remote_error(msg->any.hm2_feed.error);
		}
		if (f && f->error == 0 && f->bytes) {
			if (f->bytes > HAMMER2_PBUFSIZE || msg->aux_data == NULL ||
			    msg->aux_size < f->bytes)
				bad = "sent a feed with no data for its bytes";
			else
				f->data = kvmemdup(msg->aux_data, f->bytes,
				    GFP_KERNEL);
			if (f->data)
				atomic_inc(&rc->nb_copied);
		}
	}

	/*
	 * A frame not taken, refused or out of memory, ends the link, so no
	 * later frame is fed past the key it held: a scan's later keys would
	 * otherwise read that one as absent before the call's end is seen.
	 */
	mutex_lock(&rc->mtx);
#ifndef HAMMER2_NOCLIENTSEQ
	/*
	 * A feed of another call, or out of its place, would be taken as this
	 * call's next: a reused msgid's late frame reads as the new call's
	 * first key, a lost feed as a key the master lacks, and a repeated one
	 * stops the scan short.  The tag before the index, so a late frame is
	 * named as what it is.
	 */
	if (feed && bad == NULL) {
		if (memcmp(msg->any.hm2_feed.tag, &call->tag, sizeof(call->tag)))
			bad = "sent another call's feed";
		else if (msg->any.hm2_feed.seq != (uint32_t)call->nrecv)
			bad = (cmd & DMSGF_DELETE) ? "closed a reply short" :
			    "sent a feed out of sequence";
	}
#endif
	if (f) {
		++call->nrecv;
#ifndef HAMMER2_NOCLIENTWINDOW
		if (call->nrecv > call->allowed && bad == NULL)
			bad = "sent a feed past the window";
#else
		/* the control's reading: the frames it exists to refuse came */
		if (call->nrecv > call->allowed)
			pr_warn_once("hammer2: HM2 feed past the window taken\n");
#endif
		if ((f->error == 0 && f->bytes && f->data == NULL) || bad) {
			lost = 1;
			hammer2_rframe_free_on(rc, f);
		} else {
			list_add_tail(&f->entry, &call->frames);
		}
	} else if (bad || (feed && (cmd & DMSGF_DELETE) == 0)) {
		lost = 1;
	}
	if (lost)
		call->error = HAMMER2_ERROR_EIO;
	if (cmd & DMSGF_DELETE) {
		if (feed) {
			if (msg->any.hm2_feed.flags & DMSG_HM2_FEEDF_EOF)
				call->eof = 1;
			call->rkey = msg->any.hm2_feed.rkey;
			call->tid = msg->any.hm2_feed.tid;
			/* the peer's own, for hammer2_remote_end() to judge */
			if (call->error == 0)
				call->error = msg->any.hm2_feed.error;
		} else if (call->error == 0) {
			/* kern_dmsg's LNK_ERROR: a refusal or the link's loss */
			call->error = HAMMER2_ERROR_ENOTCONN;
		}
		call->done = 1;
		state->any.any = NULL;
		/* our side closes here, where the state is known to be live */
		hammer2_rcall_close_locked(call);
	}
	mutex_unlock(&rc->mtx);
	wake_up_all(&rc->waitq);

	if (lost) {
		if (bad)
			pr_warn_ratelimited("hammer2: HM2 peer %s, ending the link\n",
			    bad);
		else
			pr_warn_ratelimited("hammer2: HM2 no memory for a feed, ending the link\n");
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

	/*
	 * A link whose reader has exited is dead before the quiesce marks it:
	 * the writer, draining toward its exit, fails a new state only at its
	 * next half-second tick (kern_dmsg.c), so a pass sending one request
	 * per deferred directory would wait that long on each.
	 */
	mutex_lock(&rc->mtx);
	if (rc->dead || rc->lhmp == NULL ||
	    (rc->lhmp->iocom.flags & KDMSG_IOCOMF_PROTO2) == 0 ||
	    (READ_ONCE(rc->lhmp->iocom.flags) & KDMSG_IOCOMF_EXITNOACC)) {
		mutex_unlock(&rc->mtx);
		kfree(call);
		hammer2_remote_dev_drop(cdev);
		*errorp = HAMMER2_ERROR_ENOTCONN;
		return (NULL);
	}
	msg = kdmsg_msg_alloc(&rc->lhmp->iocom.state0,
	    DMSG_HM2_XOP(idx) | DMSGF_CREATE, hammer2_rcall_reply, call);
	call->state = msg->state;
	call->tag = ++rc->ntag;
	memcpy(msg->any.hm2_xop.tag, &call->tag, sizeof(call->tag));
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
 * Until the peer's DELETE the bound is tested before a queued frame is
 * taken, so a peer that keeps the next frame queued is timed out like one
 * that sends nothing.  After it every frame of the reply is here and the
 * peer has nothing left to send, so a complete reply is consumed to its
 * end whatever the consumer's own time.
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
		if (!call->done && time_after(jiffies, deadline)) {
			mutex_unlock(&rc->mtx);
			return (HAMMER2_ERROR_ETIMEDOUT);
		}
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

/* The frame's block freed with it, counted against the connection. */
static void
hammer2_rframe_free_on(struct hammer2_rconn *rc, struct hammer2_rframe *f)
{
	if (f->data)
		atomic_inc(&rc->nb_framed);
	hammer2_rframe_free(f);
}

static int
hammer2_rhandle_same(const struct hammer2_rhandle *a,
    const struct hammer2_rhandle *b)
{
	return (a->type == b->type && a->cmd == b->cmd && a->inum == b->inum &&
	    a->key == b->key && a->methods == b->methods &&
	    bcmp(&a->clid, &b->clid, sizeof(a->clid)) == 0);
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
	atomic_inc(&rc->nb_stashed);
	if (old) {
		atomic_inc(&rc->nb_replaced);
		kvfree(old);
	}

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
 * it over the inode it asked about; a readdir or scanlhc feeds directory
 * entries and inodes, a readdir from its start (its end is the local
 * element's and the peer's stopping key comes back with its end) and a
 * scanlhc in its hash range, at or past its start; an nresolve the inode
 * its entry names, since the storage function resolves the entry and its
 * caller reads the result as an inode, or an errored entry; a scanall its
 * key range, and what the scanned inode holds: entries and inodes under a
 * directory, data under a file, and the inode itself only when NODIRECT
 * was not asked, since the slave's pass inserts what it is fed beneath the
 * inode it scanned.  The type is read from this side's inode, which never
 * changes it; whether a file's data is embedded is not, since this side's
 * copy is not refreshed when the master's file grows, so the slave's
 * insert refuses a block beneath a direct-data inode itself; a lookup the
 * inode of the number it asked for, which both its callers read as an inode; a
 * read or bmap the data block covering its offset, or the file's own
 * inode, which the core's lookup returns for every key of a direct-data
 * file.  A
 * direct-data file has one block, at its base, and the read completion
 * refuses an inode anywhere else, so a read takes the inode at offset 0
 * only.  An errored inode carries no number and is taken as the file's.
 * bmap names a block number, the others a key.
 */
static int
hammer2_remote_in_range(int idx, const struct hammer2_rframe *f,
    hammer2_key_t key_beg, hammer2_key_t key_end, const hammer2_inode_t *ip1,
    uint32_t lookup_flags)
{
	uint64_t inum = ip1->meta.inum;
	const hammer2_blockref_t *bref = &f->bref;
	hammer2_key_t last;
	int isinode = bref->type == HAMMER2_BREF_TYPE_INODE;
	int entry = bref->type == HAMMER2_BREF_TYPE_DIRENT || isinode;
	const hammer2_inode_data_t *ipdata = isinode && f->data &&
	    f->bytes >= sizeof(hammer2_inode_data_t) ?
	    (const hammer2_inode_data_t *)f->data : NULL;
	int own = isinode && (f->error ||
	    (ipdata && ipdata->meta.inum == inum));

	if (bref->keybits > 63)		/* the proxy refuses it, after this */
		return (0);
	last = bref->key | (((hammer2_key_t)1 << bref->keybits) - 1);
	switch (idx) {
	case 0:			/* ipcluster */
		return (own);
	case 1:			/* readdir */
		return (entry && bref->key >= key_beg);
	case 2:			/* nresolve */
		return (isinode || (f->error && entry));
	case 5:			/* scanlhc */
		return (entry && bref->key >= key_beg &&
		    bref->key <= key_beg + HAMMER2_DIRHASH_LOMASK);
	case 6:			/* scanall */
		if (bref->key > key_end || last < key_beg)
			return (0);
		if (own && f->error == 0)	/* an errored chain is never a focus */
			return ((lookup_flags & HAMMER2_LOOKUP_NODIRECT) == 0);
		if (ip1->meta.type == HAMMER2_OBJTYPE_DIRECTORY)
			return (entry);
		return (bref->type == HAMMER2_BREF_TYPE_DATA);
	case 7:			/* lookup */
		return (isinode && bref->key <= key_beg && last >= key_beg &&
		    (f->error || (ipdata && ipdata->meta.inum == key_beg)));
	case 20:		/* bmap */
		key_beg *= hammer2_get_logical();
		fallthrough;
	case 18:		/* strategy_read */
		if (bref->type == HAMMER2_BREF_TYPE_INODE)
			return (own && (idx == 20 || key_beg == 0));
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
 * wait is bounded for the whole reply, and every way it ends feeds an end
 * the quorum reads: the peer's answer through hammer2_remote_end, or
 * unreachable.  The flush feeds a clean end no peer gave (DEFER), and a
 * one-chain descriptor's close after its chain feeds no end.
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
	int proxy, idx, nmax = 0, fed = 0, cap, error, onechain;
	unsigned int level;
	hammer2_key_t maxkey = 0;

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
		/* DEFER(stage 3: a flush over the wire): a vote no peer gave */
		hammer2_xop_feed(xop, NULL, clindex, 0);
		goto done;
	default:
		/* a request this element cannot make leaves it without a vote */
		hammer2_xop_feed(xop, NULL, clindex,
		    hammer2_remote_end(HAMMER2_ERROR_EOPNOTSUPP));
		goto done;
	}

	/*
	 * The chains a descriptor's storage function feeds at most: one for
	 * those that answer one chain, nmax for a readdir, a scan's whole
	 * range otherwise.  The window bounds the frames in flight and not
	 * their total, so a peer past this is refused here.
	 */
	switch (idx) {
	case 1:
		cap = nmax;
		break;
	case 5:
	case 6:
		cap = INT_MAX;
		break;
	default:
		cap = 1;
		break;
	}
	onechain = idx != 1 && idx != 5 && idx != 6;

	deadline = jiffies + msecs_to_jiffies(hammer2_remote_timeout_ms);
	call = hammer2_rcall_start(cdev, idx, &pmp->pfs_clid, ip1->meta.inum,
	    key_beg, key_end, lookup_flags, nmax, name, name_len, &error);
	if (call == NULL) {
		hammer2_xop_feed(xop, NULL, clindex, hammer2_remote_end(error));
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
		/*
		 * A scan feeds leaves in ascending key order, so a key at or
		 * below the last one fed is a repeat no honest peer sends.
		 * It also bounds a scanlhc by its hash range.
		 */
		chain = NULL;
		if (fed < cap && (fed == 0 || f->bref.key > maxkey) &&
		    hammer2_remote_in_range(idx, f, key_beg,
		    key_end, ip1, lookup_flags))
			chain = hammer2_remote_proxy(cdev, pmp, f,
			    &pmp->pfs_clid, ip1->meta.inum, level);
		if (chain == NULL) {
			pr_warn_ratelimited("hammer2: HM2 %s feed of type %d not a proxy\n",
			    xop->desc->id, f->bref.type);
			hammer2_rframe_free_on(cdev->rconn, f);
			error = HAMMER2_ERROR_EIO;
			break;
		}
		maxkey = f->bref.key;
		error = hammer2_xop_feed(xop, chain, clindex, f->error);
		hammer2_chain_unlock(chain);
		hammer2_chain_drop(chain);
		hammer2_rframe_free_on(cdev->rconn, f);
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
		 * not fed, and the next XOP starts there.  It is taken only
		 * from a clean end after a full batch and only past every key
		 * the peer fed, so the next XOP always starts beyond this one's
		 * start: a peer's key at or below what it fed would otherwise
		 * restart the frontend's loop at the same key for good.
		 */
		if (idx == 1 && call->eof && error == 0 && fed > 0 &&
		    fed >= x->xop_readdir.nmax && call->rkey > maxkey &&
		    call->rkey < x->xop_readdir.rkey)
			x->xop_readdir.rkey = call->rkey;
		/*
		 * A clean close with no end fed is an answer only from a
		 * one-chain descriptor, after that chain: a readdir or a
		 * scan always feeds its end.  Any other is a reply with no
		 * answer, which would leave the element counted in progress.
		 */
		if (!call->eof && error == 0 && !(onechain && fed == 1))
			error = HAMMER2_ERROR_ENOTCONN;
		if (call->eof || error)
			hammer2_xop_feed(xop, NULL, clindex,
			    hammer2_remote_end(error));
	} else {
		hammer2_xop_feed(xop, NULL, clindex, hammer2_remote_end(error));
	}
	hammer2_rcall_end(call);
	if (hammer2_debug & 0x0100)
		kprintf("H2 REMOTE %s inum=%016llx fed=%d error=%08x end=%08x ms=%u\n",
		    xop->desc->id, (unsigned long long)ip1->meta.inum, fed,
		    error, hammer2_remote_end(error),
		    jiffies_to_msecs(jiffies - t0));
done:
	hammer2_remote_dev_drop(cdev);
	return (1);
}

/*
 * hammer2_io_getblk_conn()'s fetch, with no lock held: the stash the feed
 * left, or the peer's chain again by the handle.  The refetch takes the
 * block the peer has now, so a chain the peer has moved on reads its
 * current content, as a local chain does under another thread, checked as
 * a feed is, an inode by the number the handle asked for.  A handle
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
		atomic_inc(&rc->nb_taken);
		if (h->stash_bytes != lsize) {
			atomic_inc(&rc->nb_dropped);
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
		    hammer2_remote_feed_ok(&f->bref, 0, f->bytes, f->data) &&
		    (h->type != HAMMER2_BREF_TYPE_INODE ||
		    ((hammer2_inode_data_t *)f->data)->meta.inum == h->inum)) {
			buf = f->data;
			f->data = NULL;
			atomic_inc(&rc->nb_taken);
			error = 0;
		}
		hammer2_rframe_free_on(rc, f);
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
 * The pass's source snapshot of a remote master, what hammer2_pfs_snapshot()
 * gives the local pass and routes here for an element on a connection
 * device (hammer2_sync_pass_snap()): the master takes it on its own device
 * at SNAPSHOT, the name as the request's aux, a stale one of the name
 * deleted first as the local pass deletes it, and feeds the snapshot root
 * with the transaction id on the closing frame.  The root is registered
 * here as the local one is, by hammer2_pfsalloc() under hammer2_mntlk,
 * which the caller holds: a PFS of its own by the snapshot's fresh cluster
 * id, its one element the proxy on this device, so the pass's reads of it
 * go over the wire under that id as the element's do, and the master
 * serves it unmounted by its suffix.  The root is taken only as a snapshot
 * of that name, since a peer could feed any inode.  The wait is the
 * request's bound, under the lock as the local snapshot's sync and flush
 * are.  Errnos, as hammer2_pfs_snapshot() returns them.
 */
int
hammer2_remote_snapshot_take(hammer2_pfs_t *pmp, int clindex,
    const char *name, hammer2_tid_t *tidp, hammer2_pfs_t **spmpp)
{
	const hammer2_inode_data_t *ripdata;
	hammer2_dev_t *cdev = NULL;
	struct hammer2_rcall *call;
	struct hammer2_rframe *f;
	hammer2_chain_t *chain = NULL;
	hammer2_tid_t tid = 0;
	struct uuid clid;
	unsigned long deadline;
	size_t len = strlen(name);
	int error;

	if (tidp)
		*tidp = 0;
	if (spmpp)
		*spmpp = NULL;
	if (pmp->iroot == NULL || len == 0 || len >= HAMMER2_INODE_MAXNAME)
		return (EINVAL);
	hammer2_spin_sh(&pmp->iroot->cluster_spin);
	if (hammer2_dev_is_conn(pmp->pfs_hmps[clindex])) {
		cdev = pmp->pfs_hmps[clindex];
		hammer2_remote_dev_ref(cdev);
	}
	hammer2_spin_unsh(&pmp->iroot->cluster_spin);
	if (cdev == NULL)
		return (ENOTCONN);

	deadline = jiffies + msecs_to_jiffies(hammer2_remote_timeout_ms);
	call = hammer2_rcall_start(cdev, DMSG_HM2_SNAPSHOT_IDX, &pmp->pfs_clid,
	    1, 0, 0, 0, 0, name, len, &error);
	if (call == NULL) {
		hammer2_remote_dev_drop(cdev);
		return (hammer2_error_to_errno(error));
	}
	while ((error = hammer2_rcall_next(call, deadline, &f)) == 0) {
		/*
		 * The handle's cluster id is the snapshot's own, read from
		 * the fed inode, since a later load of the root fetches it
		 * again by that id.
		 */
		if (chain == NULL && f->error == 0 &&
		    f->bref.type == HAMMER2_BREF_TYPE_INODE &&
		    f->bytes >= sizeof(hammer2_inode_data_t) && f->data) {
			memcpy(&clid, &((const hammer2_inode_data_t *)f->data)->
			    meta.pfs_clid, sizeof(clid));
			chain = hammer2_remote_proxy(cdev, NULL, f, &clid, 1,
			    1);	/* a PFS root's level, hammer2_pfsalloc() */
		}
		hammer2_rframe_free_on(cdev->rconn, f);
	}
	if (error == HAMMER2_ERROR_EOF)
		error = call->error;
	tid = call->tid;
	hammer2_rcall_end(call);
	if (chain == NULL) {
		hammer2_remote_dev_drop(cdev);
		kprintf("syncsnap: remote snapshot %s fed no root, error %08x\n",
		    name, error);
		return (error ? hammer2_error_to_errno(error) : ENOENT);
	}

	error = EINVAL;
	if (chain->error == 0 && chain->data) {
		ripdata = &chain->data->ipdata;
		if (ripdata->meta.pfs_type == HAMMER2_PFSTYPE_MASTER &&
		    ripdata->meta.pfs_subtype == HAMMER2_PFSSUBTYPE_SNAPSHOT &&
		    ripdata->meta.name_len == len &&
		    memcmp(ripdata->filename, name, len) == 0)
			error = 0;
	}
	if (error) {
		kprintf("syncsnap: remote snapshot %s fed a root that is not it\n",
		    name);
		hammer2_chain_unlock(chain);
		hammer2_chain_drop(chain);
		hammer2_remote_dev_drop(cdev);
		return (error);
	}
	/*
	 * Registered as hammer2_pfs_snapshot() registers the local one, the
	 * chain locked for the blockset it copies out; nothing merges with
	 * it, its cluster id being fresh, so one element and no thread.
	 */
	hammer2_pfsalloc(chain, &chain->data->ipdata, NULL);
	if (spmpp)
		*spmpp = chain->pmp;
	if (tidp)
		*tidp = tid;
	hammer2_chain_unlock(chain);
	hammer2_chain_drop(chain);
	hammer2_remote_dev_drop(cdev);
	if (hammer2_debug & 0x8000)
		kprintf("syncsnap: remote snapshot %s tid %016llx\n", name,
		    (long long)tid);

	return (0);
}

/*
 * SNAPDEL over the link: the master deletes the snapshot of that name on
 * its device.  Sent by hammer2_pfs_delete_byname() for a snapshot PFS on a
 * connection device after it has freed the PFS here, under no lock, by
 * the snapshot's own cluster id, which is how the master finds a PFS it
 * serves unmounted.  A link that has ended sends nothing, and the master
 * deletes what a lost link left at the link's end.  Errnos.
 */
int
hammer2_remote_snapshot_del(hammer2_dev_t *cdev, const struct uuid *clid,
    const char *name)
{
	struct hammer2_rcall *call;
	struct hammer2_rframe *f;
	unsigned long deadline;
	int error;

	hammer2_remote_dev_ref(cdev);
	deadline = jiffies + msecs_to_jiffies(hammer2_remote_timeout_ms);
	call = hammer2_rcall_start(cdev, DMSG_HM2_SNAPDEL_IDX, clid, 1, 0, 0,
	    0, 0, name, strlen(name), &error);
	if (call == NULL) {
		hammer2_remote_dev_drop(cdev);
		return (hammer2_error_to_errno(error));
	}
	while ((error = hammer2_rcall_next(call, deadline, &f)) == 0)
		hammer2_rframe_free_on(cdev->rconn, f);	/* a chain no SNAPDEL feeds */
	if (error == HAMMER2_ERROR_EOF)
		error = call->error;
	hammer2_rcall_end(call);
	hammer2_remote_dev_drop(cdev);
	if (hammer2_debug & 0x8000)
		kprintf("syncsnap: remote delete %s error %08x\n", name, error);

	return (hammer2_error_to_errno(error));
}

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
		hammer2_rframe_free_on(cdev->rconn, f);
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
	WARN_ONCE(i == 0 && pmp->mp, "hammer2: a detach emptied a mounted cluster\n");

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
		/* a pass's snapshot of a remote source has no span and no local element */
		if (!hammer2_remote_local_elm(pmp))
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
 * the device's teardown: its requests fail now, both work items are stopped
 * (disable_delayed_work_sync(), since a cancel would let one requeue), and
 * every slot on it is detached under hammer2_mntlk, which the teardown's
 * caller already holds and a reconnect, on the ioctl's thread, takes.  A
 * reconnect re-enables the items for the next link once its LNK_CONN is
 * queued, hammer2_remote_connected().  The device itself lives until its last proxy.
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
	disable_delayed_work_sync(&rm->pingwork);
	if (!final)
		hammer2_lk_ex(&hammer2_mntlk);
	if (cdev) {
		TAILQ_FOREACH(pmp, &hammer2_pfslist, mntentry) {
			/*
			 * A pass's snapshot of a remote source has no local
			 * element; its one slot is this device's and is the
			 * thread's to free, with the device dead under it.
			 */
			if (pmp->iroot == NULL || !hammer2_remote_local_elm(pmp))
				continue;
			for (j = 0; j < HAMMER2_MAXCLUSTER; ++j)
				if (pmp->pfs_hmps[j] == cdev)
					hammer2_remote_detach(pmp, j,
					    "connection ended");
		}
	}
	hammer2_remote_snaps_drop(rm);
	if (!final)
		hammer2_lk_unlock(&hammer2_mntlk);
	if (cdev)
		hammer2_remote_dev_drop(cdev);	/* the link's reference */
	hammer2_spin_ex(&rm->hmp->span_spin);
	TAILQ_FOREACH(span, &rm->hmp->spanq, entry) {
		span->tried = 1;	/* the old link's, whose DELETEs follow */
		span->slotted = 0;
	}
	hammer2_spin_unex(&rm->hmp->span_spin);
}

/*
 * The next link's LNK_CONN is queued: the two items run again.  Not before,
 * since the reader starts first and may read the peer's announcement and
 * spans already in the socket, and an item run then would put an HM2 frame
 * or a ping on the wire ahead of the LNK_CONN that announces PROTO_2, which
 * the peer reads as a PROTO_1 connection and ends.  A span or an
 * announcement read while the items were disabled queued nothing, so they
 * are queued here; the reader sets the flag before its own queue attempt,
 * and that attempt and the enable take the same lock, so the flag read
 * after the enable sees it.
 */
void
hammer2_remote_connected(hammer2_dev_t *hmp)
{
	struct hammer2_remote *rm = hmp->remote;

	if (rm == NULL)
		return;
	enable_delayed_work(&rm->regwork);
	enable_delayed_work(&rm->pingwork);
	if (hmp->iocom.flags & KDMSG_IOCOMF_PROTO2) {
		mod_delayed_work(system_dfl_wq, &rm->regwork, 0);
#ifndef HAMMER2_NOKEEPALIVE
		mod_delayed_work(system_dfl_wq, &rm->pingwork,
		    msecs_to_jiffies(hammer2_remote_timeout_ms / 2));
#endif
	}
}
