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
	kprintf("H2 SPANTAB %d\n", hmp->nspans);
	TAILQ_FOREACH(span, &hmp->spanq, entry) {
		kprintf("H2 SPAN type=%d label=%s pfs=", span->pfs_type,
			span->pfs_label);
		printf_uuid(&span->pfs_id);
		kprintf("\n");
	}
}

static void
hammer2_span_add(hammer2_dev_t *hmp, kdmsg_msg_t *msg)
{
	struct hammer2_span *span;

	span = hmalloc(sizeof(*span), hmp->mmsg, M_WAITOK | M_ZERO);
	span->state = msg->state;
	span->pfs_id = msg->any.lnk_span.pfs_id;
	span->pfs_type = msg->any.lnk_span.pfs_type;
	DMSG_TERMINATE_STRING(msg->any.lnk_span.pfs_label);
	bcopy(msg->any.lnk_span.pfs_label, span->pfs_label,
	      sizeof(span->pfs_label));
	TAILQ_INSERT_TAIL(&hmp->spanq, span, entry);
	++hmp->nspans;
	hammer2_span_dump(hmp);
}

static void
hammer2_span_del(hammer2_dev_t *hmp, kdmsg_state_t *state)
{
	struct hammer2_span *span;

	TAILQ_FOREACH(span, &hmp->spanq, entry) {
		if (span->state == state)
			break;
	}
	if (span == NULL)
		return;
	TAILQ_REMOVE(&hmp->spanq, span, entry);
	--hmp->nspans;
	hfree(span, hmp->mmsg, sizeof(*span));
	hammer2_span_dump(hmp);
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
	hmp->nspans = 0;
	hammer2_remote_init(hmp);	/* XXX Linux: the HM2 XOP API server */
}

void
hammer2_iocom_uninit(hammer2_dev_t *hmp)
{
	struct hammer2_span *span;

	/* XXX chain depend deadlck? */
	hammer2_remote_quiesce(hmp);	/* XXX Linux: no request admitted or left */
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
 * Reconnect using the passed file pointer.  The caller must ref the
 * fp for us.
 */
void
hammer2_cluster_reconnect(hammer2_dev_t *hmp, struct file *fp)
{
	/*
	 * Closes old comm descriptor, kills threads, cleans up
	 * states, then installs the new descriptor and creates
	 * new threads.
	 */
	hammer2_remote_quiesce(hmp);	/* XXX Linux: the old connection's requests */
	kdmsg_iocom_reconnect(&hmp->iocom, fp, "hammer2");
	hammer2_remote_resume(hmp);	/* XXX Linux */

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
}

static int
hammer2_rcvdmsg(kdmsg_msg_t *msg)
{
	if (hammer2_debug & 0x0100)	/* XXX Linux: one line per frame */
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
		if (msg->any.lnk_span.proto_version == DMSG_SPAN_PROTO_2)
			hammer2_span_add(hmp, msg);	/* XXX Linux */
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
	if (parent == NULL)
		goto done;
	chain = hammer2_chain_lookup(&parent, &key_next,
				     HAMMER2_KEY_MIN, HAMMER2_KEY_MAX,
				     &error, 0);
	while (chain) {
		if (chain->bref.type != HAMMER2_BREF_TYPE_INODE)
			continue;
		ripdata = &chain->data->ipdata;
#if 0
		kprintf("UPDATE SPANS: %s\n", ripdata->filename);
#endif

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
	kprintf("volconf update %p\n", hmp->iocom.conn_state);
	if (hmp->iocom.conn_state) {
		kprintf("TRANSMIT VOLCONF VIA OPEN CONN TRANSACTION\n");
		msg = kdmsg_msg_alloc(hmp->iocom.conn_state,
				      DMSG_LNK_HAMMER2_VOLCONF,
				      NULL, NULL);
		H2_LNK_VOLCONF(msg)->copy = hmp->voldata.copyinfo[index];
		H2_LNK_VOLCONF(msg)->mediaid = hmp->voldata.fsid;
		H2_LNK_VOLCONF(msg)->index = index;
		kdmsg_msg_write(msg);
	}
}
