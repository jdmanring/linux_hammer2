/*
 * Copyright (c) 2011-2018 The DragonFly Project.  All rights reserved.
 *
 * This code is derived from software contributed to The DragonFly Project
 * by Matthew Dillon <dillon@backplane.com>
 * by Daniel Flores (GSOC 2013 - mentored by Matthew Dillon, compression)
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
#include "hammer2.h"	/* XXX Linux: the DragonFly include block */

static int hammer2_rcvdmsg(kdmsg_msg_t *msg);
static void hammer2_autodmsg(kdmsg_msg_t *msg);
static int hammer2_lnk_span_reply(kdmsg_state_t *state, kdmsg_msg_t *msg);
static void hammer2_link_teardown(hammer2_dev_t *hmp);	/* XXX Linux */
static void hammer2_link_work(struct work_struct *work);	/* XXX Linux */
static void hammer2_cluster_tail(hammer2_dev_t *hmp, struct file *fp);	/* XXX Linux */

/*
 * XXX Linux: the span table, one entry per open DMSG_SPAN_PROTO_2
 * LNK_SPAN from the peer, printed under hammer2_debug 0x0100 as the
 * harness reads it (doc/CLUSTER_PROTOCOL_DESIGN.md, stage 1).  The
 * entry is found by its state, so kern_dmsg's fields are not borrowed.
 */
static void
hammer2_span_dump(hammer2_dev_t *hmp)
{
	struct hammer2_span *span;

	if ((hammer2_debug & 0x0100) == 0)
		return;
	hammer2_spin_ex(&hmp->span_spin);
	kprintf("H2 SPANTAB %d\n", hmp->nspans);
	TAILQ_FOREACH(span, &hmp->spanq, entry) {
		kprintf("H2 SPAN type=%d label=%s pfs=", span->pfs_type,
			span->pfs_label);
		printf_uuid(&span->pfs_id);
		kprintf("\n");
	}
	hammer2_spin_unex(&hmp->span_spin);
}

static int
hammer2_span_add(hammer2_dev_t *hmp, kdmsg_msg_t *msg)
{
	struct hammer2_span *span;

	/*
	 * XXX Linux: a span of a cluster id the link did not prove is kept out
	 * of the table, so nothing registers it, and the caller closes its
	 * transaction; rate-limited, since the peer chooses how many it sends.
	 * Stage 5.5 of the cluster note.
	 */
	if (!hammer2_link_binds(hmp, &msg->any.lnk_span.peer_id)) {
		hprintf("cluster link refused a span of cluster %pUl, which the link did not prove\n",
		    &msg->any.lnk_span.peer_id);
		return (0);
	}
	span = hmalloc(sizeof(*span), hmp->mmsg, M_WAITOK | M_ZERO);
	span->state = msg->state;
	span->peer_id = msg->any.lnk_span.peer_id;
	span->pfs_id = msg->any.lnk_span.pfs_id;
	span->pfs_type = msg->any.lnk_span.pfs_type;
	DMSG_TERMINATE_STRING(msg->any.lnk_span.pfs_label);
	bcopy(msg->any.lnk_span.pfs_label, span->pfs_label,
	      sizeof(span->pfs_label));
	DMSG_TERMINATE_STRING(msg->any.lnk_span.peer_label);
	bcopy(msg->any.lnk_span.peer_label, span->peer_label,
	      sizeof(span->peer_label));
	hammer2_spin_ex(&hmp->span_spin);
	TAILQ_INSERT_TAIL(&hmp->spanq, span, entry);
	++hmp->nspans;
	hammer2_spin_unex(&hmp->span_spin);
	hammer2_span_dump(hmp);
	hammer2_remote_span(hmp);	/* a master's span may register */
	return (1);
}

static void
hammer2_span_del(hammer2_dev_t *hmp, kdmsg_state_t *state)
{
	struct hammer2_span *span;
	int slotted;

	hammer2_spin_ex(&hmp->span_spin);
	TAILQ_FOREACH(span, &hmp->spanq, entry) {
		if (span->state == state)
			break;
	}
	if (span == NULL) {
		hammer2_spin_unex(&hmp->span_spin);
		return;
	}
	TAILQ_REMOVE(&hmp->spanq, span, entry);
	--hmp->nspans;
	slotted = span->slotted;
	hammer2_spin_unex(&hmp->span_spin);
	hfree(span, hmp->mmsg, sizeof(*span));
	hammer2_span_dump(hmp);
	if (slotted)
		hammer2_remote_span(hmp);	/* its element leaves */
}

void
hammer2_iocom_init(hammer2_dev_t *hmp)
{
	/*
	 * Automatic LNK_CONN
	 * Automatic LNK_SPAN handling
	 * No automatic LNK_SPAN generation (we generate multiple spans
	 *				     ourselves).
	 */
	kdmsg_iocom_init(&hmp->iocom, hmp,
			 KDMSG_IOCOMF_AUTOCONN |
			 KDMSG_IOCOMF_AUTORXSPAN,
			 hmp->mmsg, hammer2_rcvdmsg);
	TAILQ_INIT(&hmp->spanq);	/* XXX Linux */
	hmp->nspans = 0;		/* XXX Linux: the span table */
	hammer2_spin_init(&hmp->span_spin, "h2span");	/* XXX Linux */
	hammer2_remote_init(hmp);	/* XXX Linux: the HM2 XOP API server */
}

void
hammer2_iocom_uninit(hammer2_dev_t *hmp)
{
	struct hammer2_span *span;

	/* XXX chain depend deadlck? */
	hammer2_mtx_ex(&hmp->link_mtx);	/* XXX Linux: no attempt left */
	hammer2_link_teardown(hmp);
	hammer2_mtx_unlock(&hmp->link_mtx);
	hammer2_remote_quiesce(hmp, 1);	/* XXX Linux: no request admitted or left */
	if (hmp->iocom.mmsg)
		kdmsg_iocom_uninit(&hmp->iocom);
	hammer2_remote_uninit(hmp);	/* XXX Linux: after the reader is gone */
	/*
	 * XXX Linux: the teardown above delivers a simulated DELETE for
	 * every open span on the writer thread, which empties the table
	 * through hammer2_span_del(); both threads are gone when it
	 * returns, so this sweep runs unlocked and finds nothing unless
	 * the teardown missed an entry, which the line names.
	 */
	if (hmp->nspans)
		kprintf("HAMMER2: %d span(s) left after the connection closed\n",
			hmp->nspans);
	while ((span = TAILQ_FIRST(&hmp->spanq)) != NULL)
		hammer2_span_del(hmp, span->state);
}

/*
 * XXX Linux: the descriptor swap's hook, called by kdmsg_iocom_reconnect()
 * with msglk held once the old connection's threads are reaped and before
 * the new ones start, so whatever it installs is seen by every reader of
 * the new connection and by none of the old.  Spinlocks only.
 */
static void
hammer2_link_swap(kdmsg_iocom_t *iocom)
{
	hammer2_dev_t *hmp = iocom->handle;

	hammer2_remote_swap(hmp);
	hammer2_spin_ex(&hmp->link_spin);
	hmp->link_rec = hmp->link_next;
	hammer2_spin_unex(&hmp->link_spin);
}

/*
 * XXX Linux: whether the link may carry a cluster id: any on a plaintext
 * link, the bound ones on a PSK link, none before a link has proved
 * anything.  Stage 5.5 of the cluster note.
 */
int
hammer2_link_binds(hammer2_dev_t *hmp, const struct uuid *clid)
{
	const struct hammer2_link_rec *r = &hmp->link_rec;
	int i, ok = 0;

	hammer2_spin_ex(&hmp->link_spin);
	if (r->mode == HAMMER2_LINK_REC_PLAIN)
		ok = 1;
	else if (r->mode == HAMMER2_LINK_REC_PSK) {
		for (i = 0; i < r->nclid && !ok; ++i)
			ok = (bcmp(&r->clid[i], clid, sizeof(*clid)) == 0);
	}
	hammer2_spin_unex(&hmp->link_spin);

	return (ok);
}

/*
 * XXX Linux: what hammer2_cluster_reconnect() ran after its quiesce,
 * run by the work item with the quiesce done.
 */
static void
hammer2_cluster_tail(hammer2_dev_t *hmp, struct file *fp)
{
	/*
	 * Closes old comm descriptor, kills threads, cleans up
	 * states, then installs the new descriptor and creates
	 * new threads.
	 */
	/*
	 * XXX Linux: the callback is installed before the reader starts,
	 * since kern_dmsg answers a peer's LNK_CONN already in the socket
	 * with no callback when none is set, and the callback is what reads
	 * its PROTO_2; upstream installs it in kdmsg_iocom_autoinitiate()
	 * below, where its callback only monitors.  Seen once in a wire run:
	 * the link up and every span closed.
	 */
	hmp->iocom.auto_callback = HAMMER2_CTL_NOCONNFIX ? NULL : hammer2_autodmsg;
	hmp->iocom.swap_callback = hammer2_link_swap;	/* XXX Linux */
	kdmsg_iocom_reconnect(&hmp->iocom, fp, "hammer2");
	hammer2_ctl_connwait();	/* XXX Linux: the control's window, else nothing */

	/*
	 * Setup LNK_CONN fields for autoinitiated state machine.  LNK_CONN
	 * does not have to be unique.  peer_id can be used to filter incoming
	 * LNK_SPANs automatically if desired (though we still need to check).
	 * peer_label typically identifies who we are and is not a filter.
	 *
	 * Since we will be initiating multiple LNK_SPANs we cannot use
	 * AUTOTXSPAN, but we do use AUTORXSPAN so kdmsg tracks received
	 * LNK_SPANs, and we simply monitor those messages.
	 */
	bzero(&hmp->iocom.auto_lnk_conn.peer_id,
	      sizeof(hmp->iocom.auto_lnk_conn.peer_id));
	/* hmp->iocom.auto_lnk_conn.peer_id = hmp->voldata.fsid; */
	/*
	 * XXX Linux: the kernel speaks the HM2 XOP API since stage 2 of
	 * doc/CLUSTER_PROTOCOL_DESIGN.md, so its LNK_CONN and its spans say
	 * so; libdmsg reads neither field, a DragonFly kernel closes the span.
	 */
	hmp->iocom.auto_lnk_conn.proto_version = DMSG_SPAN_PROTO_2;
#if 0
	hmp->iocom.auto_lnk_conn.peer_type = hmp->voldata.peer_type;
#endif
	hmp->iocom.auto_lnk_conn.peer_type = DMSG_PEER_HAMMER2;

	/*
	 * We just want to receive LNK_SPANs related to HAMMER2 matching
	 * peer_id.
	 */
	hmp->iocom.auto_lnk_conn.peer_mask = 1LLU << DMSG_PEER_HAMMER2;

#if 0
	switch (ipdata->meta.pfs_type) {
	case DMSG_PFSTYPE_CLIENT:
		hmp->iocom.auto_lnk_conn.peer_mask &=
				~(1LLU << DMSG_PFSTYPE_CLIENT);
		break;
	default:
		break;
	}
#endif

	bzero(&hmp->iocom.auto_lnk_conn.peer_label,
	      sizeof(hmp->iocom.auto_lnk_conn.peer_label));
	ksnprintf(hmp->iocom.auto_lnk_conn.peer_label,
		  sizeof(hmp->iocom.auto_lnk_conn.peer_label),
		  "%s/%s",
		  init_utsname()->nodename, "hammer2-mount"); /* XXX Linux */
	kdmsg_iocom_autoinitiate(&hmp->iocom, hammer2_autodmsg);
	hammer2_remote_connected(hmp);	/* XXX Linux: after our LNK_CONN */
	hprintf_each("cluster link handed to the message threads\n");	/* XXX Linux */
}

static int
hammer2_rcvdmsg(kdmsg_msg_t *msg)
{
	if (hammer2_debug & 0x0400)	/* XXX Linux: one line per frame */
		kprintf("RCVMSG %08x\n", msg->tcmd);

	/*
	 * XXX Linux: the HM2 space is the XOP API server's, hammer2_remote.c
	 * (doc/CLUSTER_PROTOCOL_DESIGN.md, the server side).  The reader only
	 * queues; a frame it cannot place is answered there, never fatal.
	 */
	if ((msg->any.head.cmd & DMSGF_PROTOS) == DMSG_PROTO_HM2)
		return (hammer2_remote_rcvmsg(msg));

	switch(msg->tcmd) {
	case DMSG_DBG_SHELL:
		/*
		 * (non-transaction)
		 * Execute shell command (not supported atm)
		 */
		kdmsg_msg_result(msg, DMSG_ERR_NOSUPP);
		break;
	case DMSG_DBG_SHELL | DMSGF_REPLY:
		/*
		 * (non-transaction)
		 */
		if (msg->aux_data) {
			msg->aux_data[msg->aux_size - 1] = 0;
			kprintf("HAMMER2 DBG: %s\n", msg->aux_data);
		}
		break;
	default:
		/*
		 * Unsupported message received.  We only need to
		 * reply if it's a transaction in order to close our end.
		 * Ignore any one-way messages or any further messages
		 * associated with the transaction.
		 *
		 * NOTE: This case also includes DMSG_LNK_ERROR messages
		 *	 which might be one-way, replying to those would
		 *	 cause an infinite ping-pong.
		 */
		if (msg->any.head.cmd & DMSGF_CREATE)
			kdmsg_msg_reply(msg, DMSG_ERR_NOSUPP);
		break;
	}
	return(0);
}

/*
 * This function is called after KDMSG has automatically handled processing
 * of a LNK layer message (typically CONN or SPAN).
 *
 * We trampoline off LNK_CONN (link level connection advertising the presence
 * of H2 partitions) to generate LNK_HAMMER2_VOLCONF's from the vol->copyinfo[]
 * array in the volume header, and to generate LNK_SPANs advertising all PFSs
 * available from that volume.  Currently the VOLCONFs go through the motions
 * but are otherwise ignored.
 *
 * We collect LNK_SPAN state for hammer2 peers and turn those into 'remote'
 * PFSs which look similar to local (direct storage) PFSs.  These PFSs are
 * merged with local PFSs and may be mounted locally or merged with other
 * elements that might or might not include local cluster components (local
 * PFSs).  If you wish to ensure that a mandatory PFS rendezvous is present
 * even without network connectivity you would normally just create a dummy
 * local PFS configured as PFSTYPE_CACHE (that can be small and ram-backed).
 *
 * Remote PFSs are object-based and operate using an (inode,key) DMSG API
 * instead of hammer2_chain's + direct I/O.  A high level XOP API is employed
 * to retain integrity across operations such as rename()s.
 */
static void hammer2_update_spans(hammer2_dev_t *hmp, kdmsg_state_t *state);

static void
hammer2_autodmsg(kdmsg_msg_t *msg)
{
	hammer2_dev_t *hmp = msg->state->iocom->handle;
	int copyid;

	switch(msg->tcmd) {
	case DMSG_LNK_CONN | DMSGF_CREATE:
	case DMSG_LNK_CONN | DMSGF_CREATE | DMSGF_DELETE:
	case DMSG_LNK_CONN | DMSGF_DELETE:
		/*
		 * NOTE: kern_dmsg will automatically issue a result,
		 *       leaving the transaction open, for CREATEs,
		 *	 and will automatically issue a terminating reply
		 *	 for DELETEs.
		 */
		/*
		 * XXX Linux: the peer's LNK_CONN names the protocol it
		 * speaks.  PROTO_2 means the frames after it carry CRCs the
		 * kernel verifies and its spans are listed; this runs on the
		 * reader thread, which is the one that reads the flag.  The
		 * flag is the connection's for its life: a CONN DELETE does
		 * not clear it, kdmsg_iocom_reconnect() does.
		 */
		if ((msg->any.head.cmd & DMSGF_CREATE) &&
		    msg->any.lnk_conn.proto_version == DMSG_SPAN_PROTO_2) {
			msg->state->iocom->flags |= KDMSG_IOCOMF_PROTO2;
			kprintf("HAMMER2: peer speaks DMSG_SPAN_PROTO_2\n");
			hammer2_remote_resume(hmp);	/* XXX Linux: lifts AWAITING */
		}
		break;
	case DMSG_LNK_CONN | DMSGF_CREATE | DMSGF_REPLY:
	case DMSG_LNK_CONN | DMSGF_CREATE | DMSGF_DELETE | DMSGF_REPLY:
		/*
		 * Do a volume configuration dump when we receive a reply
		 * to our auto-CONN (typically leaving the transaction open).
		 */
		if (msg->any.head.cmd & DMSGF_CREATE) {
			kprintf("HAMMER2: VOLDATA DUMP\n");

			/*
			 * Dump the configuration stored in the volume header.
			 * This will typically be import/export access rights,
			 * master encryption keys (encrypted), etc.
			 */
			hammer2_voldata_lock(hmp);
			copyid = 0;
			while (copyid < HAMMER2_COPYID_COUNT) {
				if (hmp->voldata.copyinfo[copyid].copyid)
					hammer2_volconf_update(hmp, copyid);
				++copyid;
			}
			hammer2_voldata_unlock(hmp);

			kprintf("HAMMER2: INITIATE SPANs\n");
			hammer2_update_spans(hmp, msg->state);
		}
		if ((msg->any.head.cmd & DMSGF_DELETE) &&
		    msg->state && (msg->state->txcmd & DMSGF_DELETE) == 0) {
			kprintf("HAMMER2: CONN WAS TERMINATED\n");
		}
		break;
	case DMSG_LNK_SPAN | DMSGF_CREATE:
		/*
		 * Monitor SPANs and issue a result, leaving the SPAN open
		 * if it is something we can use now or in the future.
		 */
		if (msg->any.lnk_span.peer_type != DMSG_PEER_HAMMER2) {
			kdmsg_msg_reply(msg, 0);
			break;
		}
		/*
		 * XXX Linux: a PROTO_2 span is admitted beside PROTO_1 and
		 * listed, but only on a connection whose peer announced
		 * PROTO_2, so that nothing enters the table from a
		 * connection whose frames are not verified; on any other
		 * connection it is closed, as is a version the kernel does
		 * not know, which is what upstream does to every span that
		 * is not PROTO_1.
		 */
		if (msg->any.lnk_span.proto_version != DMSG_SPAN_PROTO_1 &&
		    (msg->any.lnk_span.proto_version != DMSG_SPAN_PROTO_2 ||
		     (msg->state->iocom->flags & KDMSG_IOCOMF_PROTO2) == 0)) {
			kdmsg_msg_reply(msg, 0);
			break;
		}
		DMSG_TERMINATE_STRING(msg->any.lnk_span.peer_label);
		if (hammer2_debug & 0x0100) {
			kprintf("H2 +RXSPAN cmd=%08x (%-20s) cl=",
				msg->any.head.cmd,
				msg->any.lnk_span.peer_label);
			printf_uuid(&msg->any.lnk_span.peer_id);
			kprintf(" fs=");
			printf_uuid(&msg->any.lnk_span.pfs_id);
			kprintf(" type=%d\n", msg->any.lnk_span.pfs_type);
		}
		if (msg->any.lnk_span.proto_version == DMSG_SPAN_PROTO_2 &&
		    !hammer2_span_add(hmp, msg)) {	/* XXX Linux */
			kdmsg_msg_reply(msg, DMSG_ERR_NOSUPP);
			break;
		}
		kdmsg_msg_result(msg, 0);
		break;
	case DMSG_LNK_SPAN | DMSGF_DELETE:
		/*
		 * NOTE: kern_dmsg will automatically reply to DELETEs.
		 */
		if (hammer2_debug & 0x0100)
			kprintf("H2 -RXSPAN\n");
		hammer2_span_del(hmp, msg->state);	/* XXX Linux */
		break;
	default:
		break;
	}
}

/*
 * Update LNK_SPAN state
 */
static void
hammer2_update_spans(hammer2_dev_t *hmp, kdmsg_state_t *state)
{
	const hammer2_inode_data_t *ripdata;
	hammer2_chain_t *parent;
	hammer2_chain_t *chain;
	hammer2_pfs_t *spmp;
	hammer2_key_t key_next;
	kdmsg_msg_t *rmsg;
	size_t name_len;
	int error;

	/*
	 * Lookup mount point under the media-localized super-root.
	 *
	 * cluster->pmp will incorrectly point to spmp and must be fixed
	 * up later on.
	 */
	spmp = hmp->spmp;
	hammer2_inode_lock(spmp->iroot, 0);
	error = 0;

	parent = hammer2_inode_chain(spmp->iroot, 0, HAMMER2_RESOLVE_ALWAYS);
	chain = NULL;
	if (parent == NULL) {
		/* XXX Linux: done is past the inode's unlock */
		hammer2_inode_unlock(spmp->iroot);
		goto done;
	}
	chain = hammer2_chain_lookup(&parent, &key_next,
				     HAMMER2_KEY_MIN, HAMMER2_KEY_MAX,
				     &error, 0);
	while (chain) {
		/*
		 * XXX Linux: the carried continue never advanced the chain,
		 * and an inode whose read failed has no data to announce.
		 */
		if (chain->bref.type != HAMMER2_BREF_TYPE_INODE ||
		    chain->data == NULL)
			goto next;
		ripdata = &chain->data->ipdata;
#if 0
		kprintf("UPDATE SPANS: %s\n", ripdata->filename);
#endif
		/* XXX Linux: only the cluster ids the link proved */
		if (!hammer2_link_binds(hmp, &ripdata->meta.pfs_clid))
			goto next;

		rmsg = kdmsg_msg_alloc(&hmp->iocom.state0,
				       DMSG_LNK_SPAN | DMSGF_CREATE,
				       hammer2_lnk_span_reply, NULL);
		rmsg->any.lnk_span.peer_id = ripdata->meta.pfs_clid;
		rmsg->any.lnk_span.pfs_id = ripdata->meta.pfs_fsid;
		rmsg->any.lnk_span.pfs_type = ripdata->meta.pfs_type;
		rmsg->any.lnk_span.peer_type = DMSG_PEER_HAMMER2;
		rmsg->any.lnk_span.proto_version = DMSG_SPAN_PROTO_2; /* XXX Linux */
		name_len = ripdata->meta.name_len;
		if (name_len >= sizeof(rmsg->any.lnk_span.peer_label))
			name_len = sizeof(rmsg->any.lnk_span.peer_label) - 1;
		bcopy(ripdata->filename,
		      rmsg->any.lnk_span.peer_label,
		      name_len);

		kdmsg_msg_write(rmsg);
next:
		chain = hammer2_chain_next(&parent, chain, &key_next,
					       HAMMER2_KEY_MAX, /* XXX key_beg */
					       &error, 0);
	}
	hammer2_inode_unlock(spmp->iroot);
	/* XXX do something with error */
done:
	if (chain) {
		hammer2_chain_unlock(chain);
		hammer2_chain_drop(chain);
	}
	if (parent) {
		hammer2_chain_unlock(parent);
		hammer2_chain_drop(parent);
	}
}

static
int
hammer2_lnk_span_reply(kdmsg_state_t *state, kdmsg_msg_t *msg)
{
	if ((state->txcmd & DMSGF_DELETE) == 0 &&
	    (msg->any.head.cmd & DMSGF_DELETE)) {
		kdmsg_msg_reply(msg, 0);
	}
	return 0;
}

/*
 * Volume configuration updates are passed onto the userland service
 * daemon via the open LNK_CONN transaction.
 */
void
hammer2_volconf_update(hammer2_dev_t *hmp, int index)
{
	kdmsg_msg_t *msg;

	/* XXX interlock against connection state termination */
	/*
	 * XXX Linux: conn_state, the link's record and the queue within one
	 * hold of msglk, under which conn_state is set and cleared and the
	 * descriptor swap installs the record, so the row goes on the
	 * connection whose record admitted it, ahead of its DELETE, or not at
	 * all.  A PSK link sends only the rows of cluster ids it proved.
	 * Stage 5.5 of the cluster note.
	 */
	lockmgr(&hmp->iocom.msglk, LK_EXCLUSIVE);
	kprintf("volconf update %p\n", hmp->iocom.conn_state);
	if (hmp->iocom.conn_state &&
	    hammer2_link_binds(hmp, &hmp->voldata.copyinfo[index].pfs_clid)) {
		kprintf("TRANSMIT VOLCONF VIA OPEN CONN TRANSACTION\n");
		msg = kdmsg_msg_alloc(hmp->iocom.conn_state,
				      DMSG_LNK_HAMMER2_VOLCONF,
				      NULL, NULL);
		H2_LNK_VOLCONF(msg)->copy = hmp->voldata.copyinfo[index];
		H2_LNK_VOLCONF(msg)->mediaid = hmp->voldata.fsid;
		H2_LNK_VOLCONF(msg)->index = index;
#if defined(HAMMER2_LOCKDEBUG)
		/*
		 * Linux: stage 5.5's controls, a hold between the alloc and
		 * the queue with msglk held, and whether the circuit queued
		 * on is already dying, read under that hold.
		 */
		if (READ_ONCE(hammer2_volconf_hold_ms)) {
			unsigned int ms = READ_ONCE(hammer2_volconf_hold_ms);

			kprintf("hammer2: volconf held %u ms\n", ms);
			schedule_timeout_uninterruptible(msecs_to_jiffies(ms));
			kprintf("hammer2: volconf hold ended\n");
		}
		if (msg->state->flags & KDMSG_STATE_DYING)
			kprintf("hammer2: volconf queued on a dying circuit\n");
#endif
		kdmsg_msg_write_locked(&hmp->iocom, msg);
	}
	lockmgr(&hmp->iocom.msglk, LK_RELEASE);
}

/*
 * XXX Linux: a link attempt.  Every intake, RECLUSTER and the mount's
 * cluster_fd=, hooks one on the device and ends in the device's work item,
 * which runs the reconnect tail below; the mount holds hammer2_mntlk across
 * its intake and the tail's quiesce needs that lock, so the tail cannot run
 * on the intake's thread.  Whoever unhooks the attempt under link_spin
 * owns it and its file; the work unhooks only a submitted one.  Every
 * owner waits on done before freeing it.  It is signaled by
 * complete_all() because the teardown waits on it and hammer2_link_end()
 * then waits again, and complete() would release only one of the two.
 * The status is the handshake core's, a negative errno against the
 * module's positive convention (net/handshake/netlink.c), and
 * -EINPROGRESS until it is known.  doc/CLUSTER_PROTOCOL_DESIGN.md, the
 * TLS link section, is the design.
 */
struct hammer2_link {
	hammer2_dev_t		*hmp;
	struct file		*fp;
	struct hammer2_link_tls	tls;		/* the intake's inputs */
	unsigned long		deadline;	/* jiffies, a PSK attempt's */
	key_serial_t		peerid;		/* the key the peer proved */
	int			status;		/* the handshake's, negative */
	int			submitted;
	struct completion	done;
};

static int
hammer2_link_psk(const struct hammer2_link *l)
{
	return (l->tls.mode == HAMMER2_LINK_TLS_PSK);
}

/*
 * The intake's refusals, made before anything is submitted or torn down,
 * so a refused intake leaves the current link alone.  A positive errno,
 * with the reason printed.
 */
static int
hammer2_link_check(struct file *fp, const struct hammer2_link_tls *tls)
{
	struct socket *so = sock_from_file(fp);
	const char *why = NULL;
	int error = EINVAL, i, j;

	if (tls->mode == HAMMER2_LINK_TLS_NONE) {
		if (READ_ONCE(hammer2_cluster_tls_required))
			why = "cluster_tls_required is set and no TLS was asked for";
	} else if (tls->mode != HAMMER2_LINK_TLS_PSK) {
		why = "unknown cluster_tls mode";
	} else if (!IS_ENABLED(CONFIG_NET_HANDSHAKE)) {
		why = "this kernel has no handshake upcall (NET_HANDSHAKE)";
		error = EOPNOTSUPP;
	} else if (so == NULL || !sk_is_tcp(so->sk)) {
		why = "TLS needs a TCP socket over IPv4 or IPv6";
	} else if (inet_csk_has_ulp(so->sk)) {
		why = "the socket already carries an upper-layer protocol";
		error = EBUSY;
	} else if (tls->nkeys < 0 || tls->nkeys > HAMMER2_LINK_TLS_MAXKEYS) {
		why = "more key serials than the intake takes";
	} else if (tls->role == HAMMER2_LINK_TLS_CLIENT) {
		if (tls->nkeys != 1)
			why = "a client takes exactly one key serial";
	} else if (tls->role == HAMMER2_LINK_TLS_SERVER) {
		if (tls->keyring <= 0 || tls->nkeys == 0)
			why = "a server needs a keyring serial and a key serial";
	} else {
		why = "unknown cluster_tls_role";
	}
	/*
	 * 0 is the core's "no peer" (TLS_NO_PEERID), never a key to admit.
	 * PSK only: nkeys is range-checked above on that branch alone, and a
	 * plaintext intake's key fields are whatever its caller left there.
	 */
	for (i = 0; why == NULL && tls->mode == HAMMER2_LINK_TLS_PSK &&
	    i < tls->nkeys; ++i) {
		if (tls->keys[i] <= 0)
			why = "a key serial must be positive";
		for (j = 0; why == NULL && j < i; ++j) {
			if (tls->keys[j] == tls->keys[i])
				why = "a key serial is listed twice";
		}
	}
	/*
	 * Stage 5.5: a PSK link carries only the cluster ids its intake bound
	 * to the key it proves, so an intake that binds none would admit
	 * nothing.
	 */
	if (why == NULL && tls->mode == HAMMER2_LINK_TLS_PSK) {
		if (tls->nbind <= 0)
			why = "a TLS intake binds no cluster id";
		else if (tls->nbind > HAMMER2_LINK_TLS_MAXBIND)
			why = "too many cluster id bindings";
		for (i = 0; why == NULL && i < tls->nbind; ++i) {
			if (tls->bind[i].slot < 0 ||
			    tls->bind[i].slot >= tls->nkeys)
				why = "a cluster id binding names no key";
		}
		/* a key bound to nothing would prove a link that admits nothing */
		for (i = 0; why == NULL && i < tls->nkeys; ++i) {
			for (j = 0; j < tls->nbind; ++j)
				if (tls->bind[j].slot == i)
					break;
			if (j == tls->nbind)
				why = "an admitted key binds no cluster id";
		}
	}
	if (why == NULL)
		return (0);
	hprintf_each("cluster link refused: %s\n", why);
	return (error);
}

/* A server admits only a peer whose key is one the intake named. */
static int
hammer2_link_admitted(const struct hammer2_link *l)
{
	int i;

	if (!hammer2_link_psk(l) || l->tls.role != HAMMER2_LINK_TLS_SERVER)
		return (1);
	for (i = 0; i < l->tls.nkeys; ++i) {
		if (l->peerid == l->tls.keys[i])
			return (1);
	}
	return (0);
}

/*
 * What the link proved, staged by the work for the descriptor swap's hook
 * to install: a server's key is the one tlshd reported, a client's its one
 * key, which a completed handshake shows the server holds too.  The
 * cluster ids are those the intake bound to that key.
 */
static void
hammer2_link_stage(hammer2_dev_t *hmp, const struct hammer2_link *l)
{
	struct hammer2_link_rec r;
	int i;

	memset(&r, 0, sizeof(r));
	r.mode = HAMMER2_LINK_REC_PLAIN;
	if (hammer2_link_psk(l)) {
		r.mode = HAMMER2_LINK_REC_PSK;
		r.serial = (l->tls.role == HAMMER2_LINK_TLS_SERVER) ?
		    l->peerid : l->tls.keys[0];
		for (i = 0; i < l->tls.nbind; ++i) {
			if (l->tls.keys[l->tls.bind[i].slot] == r.serial)
				r.clid[r.nclid++] = l->tls.bind[i].clid;
		}
	}
	hammer2_spin_ex(&hmp->link_spin);
	hmp->link_next = r;
	hammer2_spin_unex(&hmp->link_spin);
}

/*
 * The handshake core's done function, called in process context from
 * tlshd's netlink request or a namespace's drain.  It blocks on nothing,
 * touches nothing of the device but link_spin and link_work, and signals
 * done as its last act, since every owner waits on done before freeing.
 */
static void
hammer2_link_done(void *data, int status, key_serial_t peerid)
{
	struct hammer2_link *l = data;
	hammer2_dev_t *hmp = l->hmp;

	hammer2_spin_ex(&hmp->link_spin);
	l->status = status;
	l->peerid = peerid;
	hammer2_spin_unex(&hmp->link_spin);
	mod_delayed_work(system_dfl_long_wq, &hmp->link_work, 0);
	complete_all(&l->done);
}

/*
 * Cancel an owned PSK attempt's handshake.  True means the request was
 * still pending and done will never be called, so the caller signals it;
 * false means done has run or is running, since the request stays hashed
 * until the socket is destructed and the owned file keeps it alive.
 */
static void
hammer2_link_cancel(struct hammer2_link *l)
{
	if (IS_ENABLED(CONFIG_NET_HANDSHAKE) && hammer2_link_psk(l) &&
	    tls_handshake_cancel(sock_from_file(l->fp)->sk))
		complete_all(&l->done);
}

/*
 * Submit a PSK attempt's handshake.  A client names its one key, which
 * tlshd sends as its identity; a server names the keyring the core links
 * into tlshd's, and the work checks the key tlshd reports against the
 * intake's list.  Without the upcall the calls compile away, and
 * hammer2_link_check() has refused already.
 */
static int
hammer2_link_submit(struct hammer2_link *l)
{
	struct tls_handshake_args args = {
		.ta_sock	= sock_from_file(l->fp),
		.ta_done	= hammer2_link_done,
		.ta_data	= l,
		.ta_timeout_ms	= READ_ONCE(hammer2_cluster_tls_timeout_ms),
	};

	if (!IS_ENABLED(CONFIG_NET_HANDSHAKE))
		return (EOPNOTSUPP);
	if (l->tls.role == HAMMER2_LINK_TLS_SERVER) {
		args.ta_keyring = l->tls.keyring;
		return (-tls_server_hello_psk(&args, GFP_KERNEL));
	}
	args.ta_num_peerids = 1;
	args.ta_my_peerids[0] = l->tls.keys[0];
	return (-tls_client_hello_psk(&args, GFP_KERNEL));
}

void
hammer2_link_devinit(hammer2_dev_t *hmp)
{
	hammer2_spin_init(&hmp->link_spin, "h2link");
	hammer2_mtx_init(&hmp->link_mtx, "h2linkm");
	INIT_DELAYED_WORK(&hmp->link_work, hammer2_link_work);
}

/* Unhook the device's attempt if it is submitted; the caller owns it. */
static struct hammer2_link *
hammer2_link_claim(hammer2_dev_t *hmp)
{
	struct hammer2_link *l;

	hammer2_spin_ex(&hmp->link_spin);
	l = hmp->link;
	if (l != NULL && l->submitted)
		hmp->link = NULL;
	else
		l = NULL;
	hammer2_spin_unex(&hmp->link_spin);
	return (l);
}

/* End an owned attempt that will not become the link. */
static void
hammer2_link_end(struct hammer2_link *l, const char *why)
{
	wait_for_completion(&l->done);
	if (why != NULL)
		hprintf_each("cluster link refused: %s (status %d, peer key %d)\n",
		    why, l->status, l->peerid);
	fp_shutdown(l->fp, SHUT_RDWR);
	fdrop(l->fp);
	kfree(l);
}

/*
 * The teardown, under link_mtx: an intake that finds an attempt hooked,
 * and hammer2_iocom_uninit() before its quiesce, which holds hammer2_mntlk.
 * A work in its try-lock loop finds nothing hooked once this unhooks and
 * returns, and a work past its claim holds hammer2_mntlk only through the
 * quiesce, so the cancel below never waits on the caller's own lock.
 */
static void
hammer2_link_teardown(hammer2_dev_t *hmp)
{
	struct hammer2_link *l;

	hammer2_spin_ex(&hmp->link_spin);
	l = hmp->link;
	hmp->link = NULL;
	hammer2_spin_unex(&hmp->link_spin);
	if (l != NULL) {
		hammer2_link_cancel(l);
		wait_for_completion(&l->done);
	}
	cancel_delayed_work_sync(&hmp->link_work);
	if (l != NULL)
		hammer2_link_end(l, NULL);
}

static void
hammer2_link_work(struct work_struct *work)
{
	hammer2_dev_t *hmp = container_of(to_delayed_work(work),
	    hammer2_dev_t, link_work);
	struct hammer2_link *l;
	unsigned long deadline = 0;
	int status = 0, submitted = 0, admitted = 1;

	hammer2_spin_ex(&hmp->link_spin);
	if (hmp->link != NULL) {
		status = hmp->link->status;
		submitted = hmp->link->submitted;
		deadline = hmp->link->deadline;
		admitted = hammer2_link_admitted(hmp->link);
	}
	hammer2_spin_unex(&hmp->link_spin);
	if (!submitted)
		return;
	if (status == -EINPROGRESS) {
		/*
		 * A timer armed for an earlier attempt, or spent by a work
		 * that found nothing, is re-armed at this attempt's deadline.
		 */
		if (time_before(jiffies, deadline)) {
			queue_delayed_work(system_dfl_long_wq, &hmp->link_work,
			    deadline - jiffies);
			return;
		}
		l = hammer2_link_claim(hmp);
		if (l != NULL) {
			hammer2_link_cancel(l);
			hammer2_link_end(l, "the handshake timed out");
		}
		return;
	}
	if (status != 0 || !admitted) {
		l = hammer2_link_claim(hmp);
		if (l != NULL)
			hammer2_link_end(l, status != 0 ?
			    "the handshake failed" :
			    "the peer's key is not one the intake admits");
		return;
	}
	while (!hammer2_lk_tryex(&hammer2_mntlk)) {
		if (READ_ONCE(hmp->link) == NULL)
			return;
		schedule_timeout_uninterruptible(msecs_to_jiffies(10));
	}
	l = hammer2_link_claim(hmp);
	if (l == NULL) {
		hammer2_lk_unlock(&hammer2_mntlk);
		return;
	}
	if (l->status != 0) {
		hammer2_lk_unlock(&hammer2_mntlk);
		hammer2_link_end(l, "the handshake failed");
		return;
	}
	wait_for_completion(&l->done);
	hammer2_remote_quiesce(hmp, 0);	/* the old connection's requests */
#if defined(HAMMER2_LOCKDEBUG)
	/*
	 * Linux: stage 5.5's controls, a hold after the quiesce with
	 * hammer2_mntlk held and the old connection still up.
	 */
	if (READ_ONCE(hammer2_link_hold_ms)) {
		unsigned int ms = READ_ONCE(hammer2_link_hold_ms);

		kprintf("hammer2: cluster link held %u ms after the quiesce\n", ms);
		schedule_timeout_uninterruptible(msecs_to_jiffies(ms));
		kprintf("hammer2: cluster link hold ended\n");
	}
#endif
	hammer2_link_stage(hmp, l);	/* installed at the swap */
	hammer2_lk_unlock(&hammer2_mntlk);
	hammer2_cluster_tail(hmp, l->fp);	/* kdmsg owns the file now */
	kfree(l);
}

/*
 * Reconnect using the passed file pointer.  The caller must ref the
 * fp for us.
 *
 * XXX Linux: the intake.  The file is the attempt's from here, dropped on
 * every failure; the tail runs in the device's work item, so a return
 * means the link is queued, not that LNK_CONN is.
 */
int
hammer2_cluster_reconnect(hammer2_dev_t *hmp, struct file *fp,
    const struct hammer2_link_tls *tls)
{
	static const struct hammer2_link_tls none;
	struct hammer2_link *l;
	unsigned long deadline;
	int error, status;

	if (tls == NULL)
		tls = &none;
	error = hammer2_link_check(fp, tls);
	if (error == 0) {
		l = kzalloc_obj(*l);
		if (l == NULL)
			error = ENOMEM;
	}
	if (error) {
		fdrop(fp);
		return (error);
	}
	l->hmp = hmp;
	l->fp = fp;
	l->tls = *tls;
	l->status = -EINPROGRESS;
	init_completion(&l->done);
	hammer2_mtx_ex(&hmp->link_mtx);
	hammer2_link_teardown(hmp);
	if (!hammer2_link_psk(l)) {
		complete_all(&l->done);	/* no handshake to wait for */
		hammer2_spin_ex(&hmp->link_spin);
		l->status = 0;
		l->submitted = 1;
		hmp->link = l;
		hammer2_spin_unex(&hmp->link_spin);
		mod_delayed_work(system_dfl_long_wq, &hmp->link_work, 0);
		hammer2_mtx_unlock(&hmp->link_mtx);
		return (0);
	}

	/*
	 * PSK.  The attempt's file is the caller's reference the submit
	 * requires for its duration, and nothing drops it before the attempt
	 * is marked submitted, since a teardown takes link_mtx.  The deadline
	 * is copied first: once the attempt is marked submitted the work may
	 * free it.
	 */
	deadline = jiffies +
	    msecs_to_jiffies(READ_ONCE(hammer2_cluster_tls_timeout_ms));
	l->deadline = deadline;
	hammer2_spin_ex(&hmp->link_spin);
	hmp->link = l;
	hammer2_spin_unex(&hmp->link_spin);
	error = hammer2_link_submit(l);
	if (error) {
		/* Done is never called; nothing else ever saw it hooked. */
		hammer2_spin_ex(&hmp->link_spin);
		hmp->link = NULL;
		hammer2_spin_unex(&hmp->link_spin);
		hammer2_mtx_unlock(&hmp->link_mtx);
		hprintf_each("cluster link refused: the handshake was not submitted (%d)\n",
		    error);
		fp_shutdown(fp, SHUT_RDWR);
		fdrop(fp);
		kfree(l);
		return (error);
	}
	hammer2_spin_ex(&hmp->link_spin);
	l->submitted = 1;
	status = l->status;
	hammer2_spin_unex(&hmp->link_spin);
	if (status != -EINPROGRESS)
		mod_delayed_work(system_dfl_long_wq, &hmp->link_work, 0);
	else
		queue_delayed_work(system_dfl_long_wq, &hmp->link_work,
		    time_before(jiffies, deadline) ? deadline - jiffies : 0);
	hammer2_mtx_unlock(&hmp->link_mtx);
	return (0);
}
