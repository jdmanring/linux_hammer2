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
#include "hammer2_ioctl.h"
#include "hammer2_mount.h"

#include <linux/uaccess.h>	/* XXX Linux: copy_to_user; was sys/filio.h and geom/geom.h */

/*
 * Return 1 if read-only mounted otherwise 0.  DragonFly allows bwrite(9)
 * against a read-only mounted device, but FreeBSD does not.
 */
static int
hammer2_is_rdonly(const struct super_block *mp)	/* XXX Linux: was struct mount */
{
	if (sb_rdonly(mp)) {	/* XXX Linux: was mnt_flag & MNT_RDONLY */
		hprintf("read-only mounted\n");
		return (1);
	}

	return (0);
}

static int hammer2_ioctl_recluster(hammer2_inode_t *ip, void *data);

/*
 * Retrieve ondisk version.
 */
static int
hammer2_ioctl_version_get(hammer2_inode_t *ip, void *data)
{
	hammer2_ioc_version_t *v = data;
	hammer2_dev_t *hmp = ip->pmp->pfs_hmps[0];

	if (hmp == NULL)
		return (EINVAL);

	if (hmp)
		v->version = hmp->voldata.version;
	else
		v->version = -1;

	return (0);
}

static int
hammer2_ioctl_recluster(hammer2_inode_t *ip, void *data)
{
	hammer2_ioc_recluster_t *recl = data;
	struct file *fp;
	hammer2_cluster_t *cluster;
	int error;

	fp = holdfp(curthread, recl->fd, -1);
	if (fp) {
		/*
		 * XXX Linux: upstream pins the mount with VFS_ROOT() and
		 * vput() around the reconnect.  The ioctl runs on an open
		 * file of this super block, which pins it for the call.
		 */
		error = 0;
		if (error == 0) {
			/*
			 * XXX Linux: upstream hands the descriptor to the
			 * focus's device.  With a remote master registered
			 * the focus is a proxy on the connection device, and
			 * after a detach the focus is cleared, so the socket
			 * goes to the first slot on a block device, the pick
			 * hammer2_vfs_statfs() makes, and no focus is read
			 * (doc/CLUSTER_PROTOCOL_DESIGN.md, the seven ioctls).
			 */
			hammer2_dev_t *hmp = hammer2_pfs_first_bdev(ip->pmp);

			cluster = &ip->pmp->iroot->cluster;
			if (hmp != NULL) {
				hammer2_cluster_reconnect(hmp, fp);
				error = 0;
			} else {
				kprintf("hammer2: recluster: "
					"nchains=%d no block device\n",
					cluster->nchains);
				error = EINVAL;
			}
		}
	} else {
		error = EINVAL;
	}
	return error;
}

/*
 * Retrieve information about a remote
 */
static int
hammer2_ioctl_remote_scan(hammer2_inode_t *ip, void *data)
{
	hammer2_dev_t *hmp;
	hammer2_ioc_remote_t *remote = data;
	int copyid = remote->copyid;

	hmp = hammer2_pfs_first_bdev(ip->pmp);	/* XXX Linux: was pfs_hmps[0] */
	if (hmp == NULL)
		return (EINVAL);

	if (copyid < 0 || copyid >= HAMMER2_COPYID_COUNT)
		return (EINVAL);

	hammer2_voldata_lock(hmp);
	remote->copy1 = hmp->voldata.copyinfo[copyid];
	hammer2_voldata_unlock(hmp);

	/*
	 * Adjust nextid (GET only)
	 */
	while (++copyid < HAMMER2_COPYID_COUNT &&
	       hmp->voldata.copyinfo[copyid].copyid == 0) {
		;
	}
	if (copyid == HAMMER2_COPYID_COUNT)
		remote->nextid = -1;
	else
		remote->nextid = copyid;

	return(0);
}

/*
 * XXX Linux: the fields a row carries from userland, checked before the
 * row reaches the volume header (HAMMER2_AGENT_HANDOFF.md's validation
 * list): the strings are terminated, the type is one the format names
 * and the flags are the bits the format defines.  Upstream copies the
 * structure as it arrives.
 */
static int
hammer2_ioctl_remote_check(hammer2_volconf_t *copy)
{
	copy->label[sizeof(copy->label) - 1] = 0;
	copy->path[sizeof(copy->path) - 1] = 0;
	if (copy->remote_pfs_type >= HAMMER2_PFSTYPE_MAX)
		return (EINVAL);
	if (copy->flags & ~(DMSG_VOLF_ENABLED | DMSG_VOLF_INPROG))
		return (EINVAL);
	return (0);
}

/*
 * Add new remote entry
 */
static int
hammer2_ioctl_remote_add(hammer2_inode_t *ip, void *data)
{
	hammer2_ioc_remote_t *remote = data;
	hammer2_pfs_t *pmp = ip->pmp;
	hammer2_dev_t *hmp;
	int copyid = remote->copyid;
	int error = 0;

	hmp = hammer2_pfs_first_bdev(pmp);	/* XXX Linux: was pfs_hmps[0] */
	if (hmp == NULL)
		return (EINVAL);
	if (copyid >= HAMMER2_COPYID_COUNT)
		return (EINVAL);
	if (hammer2_ioctl_remote_check(&remote->copy1))	/* XXX Linux */
		return (EINVAL);
	if (hmp->rdonly)	/* XXX Linux: a row is a volume header write */
		return (EROFS);

	hammer2_voldata_lock(hmp);
	if (copyid < 0) {
		for (copyid = 1; copyid < HAMMER2_COPYID_COUNT; ++copyid) {
			if (hmp->voldata.copyinfo[copyid].copyid == 0)
				break;
		}
		if (copyid == HAMMER2_COPYID_COUNT) {
			error = ENOSPC;
			goto failed;
		}
	}
	hammer2_voldata_modify(hmp);
	remote->copy1.copyid = copyid;
	hmp->voldata.copyinfo[copyid] = remote->copy1;
	hammer2_volconf_update(hmp, copyid);
failed:
	hammer2_voldata_unlock(hmp);
	return (error);
}

/*
 * Delete existing remote entry
 */
static int
hammer2_ioctl_remote_del(hammer2_inode_t *ip, void *data)
{
	hammer2_ioc_remote_t *remote = data;
	hammer2_pfs_t *pmp = ip->pmp;
	hammer2_dev_t *hmp;
	int copyid = remote->copyid;
	int error = 0;

	hmp = hammer2_pfs_first_bdev(pmp);	/* XXX Linux: was pfs_hmps[0] */
	if (hmp == NULL)
		return (EINVAL);
	if (copyid >= HAMMER2_COPYID_COUNT)
		return (EINVAL);
	if (hmp->rdonly)	/* XXX Linux */
		return (EROFS);
	remote->copy1.path[sizeof(remote->copy1.path) - 1] = 0;
	hammer2_voldata_lock(hmp);
	if (copyid < 0) {
		for (copyid = 1; copyid < HAMMER2_COPYID_COUNT; ++copyid) {
			if (hmp->voldata.copyinfo[copyid].copyid == 0)
				continue;
			if (strcmp(remote->copy1.path,
			    hmp->voldata.copyinfo[copyid].path) == 0) {
				break;
			}
		}
		if (copyid == HAMMER2_COPYID_COUNT) {
			error = ENOENT;
			goto failed;
		}
	}
	hammer2_voldata_modify(hmp);
	hmp->voldata.copyinfo[copyid].copyid = 0;
	hammer2_volconf_update(hmp, copyid);
failed:
	hammer2_voldata_unlock(hmp);
	return (error);
}

/*
 * Replace existing remote entry
 */
static int
hammer2_ioctl_remote_rep(hammer2_inode_t *ip, void *data)
{
	hammer2_ioc_remote_t *remote = data;
	hammer2_dev_t *hmp;
	int copyid = remote->copyid;

	hmp = hammer2_pfs_first_bdev(ip->pmp);	/* XXX Linux: was pfs_hmps[0] */
	if (hmp == NULL)
		return (EINVAL);
	if (copyid < 0 || copyid >= HAMMER2_COPYID_COUNT)
		return (EINVAL);

	hammer2_voldata_lock(hmp);
	hammer2_voldata_modify(hmp);
	/*hammer2_volconf_update(hmp, copyid);*/
	hammer2_voldata_unlock(hmp);

	return(0);
}

/*
 * Retrieve communications socket
 */
static int
hammer2_ioctl_socket_get(hammer2_inode_t *ip, void *data)
{
	return (EOPNOTSUPP);
}

/*
 * Set communications socket for connection
 */
static int
hammer2_ioctl_socket_set(hammer2_inode_t *ip, void *data)
{
	hammer2_ioc_remote_t *remote = data;
	hammer2_dev_t *hmp;
	int copyid = remote->copyid;

	hmp = hammer2_pfs_first_bdev(ip->pmp);	/* XXX Linux: was pfs_hmps[0] */
	if (hmp == NULL)
		return (EINVAL);
	if (copyid < 0 || copyid >= HAMMER2_COPYID_COUNT)
		return (EINVAL);

	hammer2_voldata_lock(hmp);
	hammer2_voldata_unlock(hmp);

	return(0);
}

/*
 * Used to scan and retrieve PFS information.  PFS's are directories under
 * the super-root.
 *
 * To scan PFSs pass name_key=0.  The function will scan for the next
 * PFS and set all fields, as well as set name_next to the next key.
 * When no PFSs remain, name_next is set to (hammer2_key_t)-1.
 *
 * To retrieve a particular PFS by key, specify the key but note that
 * the ioctl will return the lowest key >= specified_key, so the caller
 * must verify the key.
 *
 * To retrieve the PFS associated with the file descriptor, pass
 * name_key set to (hammer2_key_t)-1.
 */
static int
hammer2_ioctl_pfs_get(hammer2_inode_t *ip, void *data)
{
	hammer2_ioc_pfs_t *pfs = data;
	hammer2_dev_t *hmp = ip->pmp->pfs_hmps[0];
	const hammer2_inode_data_t *ripdata;
	hammer2_chain_t *chain, *parent;
	hammer2_key_t key_next, save_key;
	int error = 0;

	if (hmp == NULL)
		return (EINVAL);

	save_key = pfs->name_key;

	if (save_key == (hammer2_key_t)-1) {
		hammer2_inode_lock(ip->pmp->iroot, 0);
		parent = NULL;
		chain = hammer2_inode_chain(ip->pmp->iroot, 0,
		    HAMMER2_RESOLVE_ALWAYS | HAMMER2_RESOLVE_SHARED);
	} else {
		hammer2_inode_lock(hmp->spmp->iroot, 0);
		parent = hammer2_inode_chain(hmp->spmp->iroot, 0,
		    HAMMER2_RESOLVE_ALWAYS | HAMMER2_RESOLVE_SHARED);
		chain = hammer2_chain_lookup(&parent, &key_next, pfs->name_key,
		    HAMMER2_KEY_MAX, &error, HAMMER2_LOOKUP_SHARED);
	}

	/* Locate next PFS. */
	while (chain) {
		if (chain->bref.type == HAMMER2_BREF_TYPE_INODE)
			break;
		if (parent == NULL) {
			hammer2_chain_unlock(chain);
			hammer2_chain_drop(chain);
			chain = NULL;
			break;
		}
		chain = hammer2_chain_next(&parent, chain, &key_next,
		    HAMMER2_KEY_MAX, &error, HAMMER2_LOOKUP_SHARED);
	}
	error = hammer2_error_to_errno(error);

	/* Load the data being returned by the ioctl. */
	if (chain && chain->error == 0) {
		ripdata = &chain->data->ipdata;
		pfs->name_key = ripdata->meta.name_key;
		pfs->pfs_type = ripdata->meta.pfs_type;
		pfs->pfs_subtype = ripdata->meta.pfs_subtype;
		pfs->pfs_clid = ripdata->meta.pfs_clid;
		pfs->pfs_fsid = ripdata->meta.pfs_fsid;
		KKASSERT(ripdata->meta.name_len < sizeof(pfs->name));
		bcopy(ripdata->filename, pfs->name, ripdata->meta.name_len);
		pfs->name[ripdata->meta.name_len] = 0;
		ripdata = NULL; /* safety */

		/*
		 * Calculate name_next, if any.  We are only accessing
		 * chain->bref so we can ignore chain->error (if the key
		 * is used later it will error then).
		 */
		if (parent == NULL) {
			pfs->name_next = (hammer2_key_t)-1;
		} else {
			chain = hammer2_chain_next(&parent, chain, &key_next,
			    HAMMER2_KEY_MAX, &error, HAMMER2_LOOKUP_SHARED);
			if (chain)
				pfs->name_next = chain->bref.key;
			else
				pfs->name_next = (hammer2_key_t)-1;
		}
	} else {
		pfs->name_next = (hammer2_key_t)-1;
		error = ENOENT;
	}

	if (chain) {
		hammer2_chain_unlock(chain);
		hammer2_chain_drop(chain);
	}
	if (parent) {
		hammer2_chain_unlock(parent);
		hammer2_chain_drop(parent);
	}

	if (save_key == (hammer2_key_t)-1)
		hammer2_inode_unlock(ip->pmp->iroot);
	else
		hammer2_inode_unlock(hmp->spmp->iroot);

	return (error);
}

/*
 * Find a specific PFS by name.
 */
static int
hammer2_ioctl_pfs_lookup(hammer2_inode_t *ip, void *data)
{
	hammer2_ioc_pfs_t *pfs = data;
	hammer2_dev_t *hmp = ip->pmp->pfs_hmps[0];
	const hammer2_inode_data_t *ripdata;
	hammer2_chain_t *chain, *parent;
	hammer2_key_t key_next, lhc;
	size_t len;
	int error = 0;

	if (hmp == NULL)
		return (EINVAL);

	hammer2_inode_lock(hmp->spmp->iroot, HAMMER2_RESOLVE_SHARED);
	parent = hammer2_inode_chain(hmp->spmp->iroot, 0,
	    HAMMER2_RESOLVE_ALWAYS | HAMMER2_RESOLVE_SHARED);

	pfs->name[sizeof(pfs->name) - 1] = 0;
	len = strlen(pfs->name);
	lhc = hammer2_dirhash(pfs->name, len);

	chain = hammer2_chain_lookup(&parent, &key_next, lhc,
	    lhc + HAMMER2_DIRHASH_LOMASK, &error, HAMMER2_LOOKUP_SHARED);
	while (chain) {
		if (hammer2_chain_dirent_test(chain, pfs->name, len))
			break;
		chain = hammer2_chain_next(&parent, chain, &key_next,
		    lhc + HAMMER2_DIRHASH_LOMASK, &error,
		    HAMMER2_LOOKUP_SHARED);
	}
	error = hammer2_error_to_errno(error);

	/* Load the data being returned by the ioctl. */
	if (chain && chain->error == 0) {
		KKASSERT(chain->bref.type == HAMMER2_BREF_TYPE_INODE);
		ripdata = &chain->data->ipdata;
		pfs->name_key = ripdata->meta.name_key;
		pfs->pfs_type = ripdata->meta.pfs_type;
		pfs->pfs_subtype = ripdata->meta.pfs_subtype;
		pfs->pfs_clid = ripdata->meta.pfs_clid;
		pfs->pfs_fsid = ripdata->meta.pfs_fsid;

		hammer2_chain_unlock(chain);
		hammer2_chain_drop(chain);
	} else if (error == 0) {
		error = ENOENT;
	}
	if (parent) {
		hammer2_chain_unlock(parent);
		hammer2_chain_drop(parent);
	}

	hammer2_inode_unlock(hmp->spmp->iroot);

	return (error);
}

/*
 * Create a new PFS under the super-root.
 */
static int
hammer2_ioctl_pfs_create(hammer2_inode_t *ip, void *data)
{
	hammer2_inode_data_t *nipdata;
	hammer2_chain_t *nchain;
	hammer2_dev_t *hmp, *force_local;
	hammer2_ioc_pfs_t *pfs = data;
	hammer2_inode_t *nip = NULL;
	hammer2_tid_t mtid;
	int error;

	hmp = ip->pmp->pfs_hmps[0];
	if (hmp == NULL)
		return (EINVAL);

	if (pfs->name[0] == 0)
		return (EINVAL);
	pfs->name[sizeof(pfs->name) - 1] = 0;

	if (hammer2_is_rdonly(ip->pmp->mp))
		return (EROFS);

	if (hammer2_ioctl_pfs_lookup(ip, pfs) == 0)
		return (EEXIST);

	/*
	 * XXX Linux: the three BSD ports refuse every type but MASTER here,
	 * having no synchronization thread for any other type to start.
	 * This port carries hammer2_synchro.c and takes the types a cluster
	 * element can be: hammer2_pfsalloc() starts the thread a SLAVE or a
	 * soft type needs, and a single MASTER still gets none.  DragonFly
	 * tests nothing, so a caller could store NONE, which the cluster code
	 * reads as an empty slot, SUPROOT, the super-root's own type, or any
	 * byte up to 255 in a PFS root on media.
	 */
	switch (pfs->pfs_type) {
	case HAMMER2_PFSTYPE_CACHE:
	case HAMMER2_PFSTYPE_SLAVE:
	case HAMMER2_PFSTYPE_SOFT_SLAVE:
	case HAMMER2_PFSTYPE_SOFT_MASTER:
	case HAMMER2_PFSTYPE_MASTER:
		break;
	default:
		return (EINVAL);
	}
	if (pfs->pfs_subtype > HAMMER2_PFSSUBTYPE_AUTOSNAP)	/* Linux */
		return (EINVAL);

	hammer2_trans_init(hmp->spmp, HAMMER2_TRANS_ISFLUSH);
	mtid = hammer2_trans_sub(hmp->spmp);
	nip = hammer2_inode_create_pfs(hmp->spmp, pfs->name, strlen(pfs->name),
	    &error);
	if (error == 0) {
		atomic_set_int(&nip->flags, HAMMER2_INODE_NOSIDEQ);
		hammer2_inode_modify(nip);
		nchain = hammer2_inode_chain(nip, 0, HAMMER2_RESOLVE_ALWAYS);
		error = hammer2_chain_modify(nchain, mtid, 0, 0);
		KKASSERT(error == 0);
		nipdata = &nchain->data->ipdata;

		nip->meta.pfs_type = pfs->pfs_type;
		nip->meta.pfs_subtype = pfs->pfs_subtype;
		nip->meta.pfs_clid = pfs->pfs_clid;
		nip->meta.pfs_fsid = pfs->pfs_fsid;
		nip->meta.op_flags |= HAMMER2_OPFLAG_PFSROOT;

		/*
		 * Set default compression and check algorithm.  This
		 * can be changed later.
		 *
		 * Do not allow compression on PFS's with the special name
		 * "boot", the boot loader can't decompress (yet).
		 */
		nip->meta.comp_algo =
		    HAMMER2_ENC_ALGO(HAMMER2_COMP_DEFAULT);
		nip->meta.check_algo =
		    HAMMER2_ENC_ALGO(HAMMER2_CHECK_DEFAULT);

		if (strcasecmp(pfs->name, "boot") == 0)
			nip->meta.comp_algo =
			    HAMMER2_ENC_ALGO(HAMMER2_COMP_AUTOZERO);

		/* Super-root isn't mounted, fsync it. */
		hammer2_chain_unlock(nchain);
		hammer2_inode_ref(nip);
		hammer2_inode_unlock(nip);
		hammer2_inode_chain_sync(nip);
		hammer2_inode_chain_flush(nip,
		    HAMMER2_XOP_INODE_STOP | HAMMER2_XOP_FSSYNC);
		hammer2_inode_drop(nip);
		/* nip is dead */

		/*
		 * We still have a ref on the chain, relock and associate
		 * with an appropriate PFS.
		 */
		force_local = (hmp->hflags & HMNT2_LOCAL) ? hmp : NULL;

		hammer2_chain_lock(nchain, HAMMER2_RESOLVE_ALWAYS);
		/*
		 * XXX Linux: the flush above left the chain unmodified, so the
		 * unlock dropped its data and this lock reads it again; a read
		 * that fails leaves no data, and the PFS is created on media
		 * but not associated, as a failed flush would leave it.
		 */
		if (nchain->data == NULL) {
			error = nchain->error ? nchain->error :
			    HAMMER2_ERROR_EIO;
			hprintf("PFS %s created but not read back, error %08x\n",
			    pfs->name, error);
		} else {
			nipdata = &nchain->data->ipdata;
			debug_hprintf("ADD LOCAL PFS (IOCTL): %s\n",
			    nipdata->filename);
			hammer2_pfsalloc(nchain, nipdata, force_local);
		}

		hammer2_chain_unlock(nchain);
		hammer2_chain_drop(nchain);
	}
	hammer2_trans_done(hmp->spmp,
	    HAMMER2_TRANS_ISFLUSH | HAMMER2_TRANS_SIDEQ);

	/*
	 * XXX Linux: the error here is the core's, from the create or the
	 * read back, and the boundary only negates; the early returns
	 * above are errnos already.
	 */
	return (hammer2_error_to_errno(error));
}

/*
 * Destroy an existing PFS under the super-root.
 */
static int
hammer2_ioctl_pfs_delete(hammer2_inode_t *ip, void *data)
{
	hammer2_ioc_pfs_t *pfs = data;
	hammer2_dev_t *hmp;

	hmp = ip->pmp->pfs_hmps[0];
	if (hmp == NULL)
		return (EINVAL);

	if (pfs->name[0] == 0)
		return (EINVAL);
	pfs->name[sizeof(pfs->name) - 1] = 0;

	if (hammer2_is_rdonly(ip->pmp->mp))
		return (EROFS);

	return (hammer2_pfs_delete_byname(hmp, pfs->name, 0));
}

/*
 * XXX Linux: the PFS registered on hmp under name, with its element index
 * in *idxp, or NULL.  The caller holds hammer2_mntlk.  The delete below
 * finds its target this way, and the synchronization thread asks whether
 * a target snapshot a crash or an unmount left stands before it takes one:
 * the snapshot's create walks the hash collision space to an unused key
 * without comparing names (hammer2_inode_create_pfs()), so a second PFS of
 * the same name would be made beside the first, and EEXIST never returns.
 */
hammer2_pfs_t *
hammer2_pfs_find_byname(hammer2_dev_t *hmp, const char *name, int *idxp)
{
	hammer2_pfs_t *pmp;
	int i;

	TAILQ_FOREACH(pmp, &hammer2_pfslist, mntentry) {
		for (i = 0; i < HAMMER2_MAXCLUSTER; ++i) {
			if (pmp->pfs_hmps[i] == hmp && pmp->pfs_names[i] &&
			    strcmp(pmp->pfs_names[i], name) == 0) {
				if (idxp)
					*idxp = i;
				return (pmp);
			}
		}
	}
	return (NULL);
}

/*
 * XXX Linux: the device holding a PFS of the name, any element, or NULL.
 * Under hammer2_mntlk.
 */
hammer2_dev_t *
hammer2_pfs_dev_byname(const char *name)
{
	hammer2_pfs_t *pmp;
	int i;

	TAILQ_FOREACH(pmp, &hammer2_pfslist, mntentry) {
		for (i = 0; i < HAMMER2_MAXCLUSTER; ++i) {
			if (pmp->pfs_hmps[i] && pmp->pfs_names[i] &&
			    strcmp(pmp->pfs_names[i], name) == 0)
				return (pmp->pfs_hmps[i]);
		}
	}
	return (NULL);
}

/*
 * XXX Linux: the body of the pfs-delete ioctl, callable from the
 * synchronization thread, which deletes the snapshots it took.  The
 * caller has checked the name and the mount's writability.
 * HAMMER2_PFSDEL_TRYLOCK returns EAGAIN rather than waiting for
 * hammer2_mntlk, since an unmount holds that lock while it waits for the
 * thread to stop.
 */
int
hammer2_pfs_delete_byname(hammer2_dev_t *hmp, const char *name, int flags)
{
	hammer2_pfs_t *spmp, *pmp;
	hammer2_xop_unlink_t *xop;
	hammer2_inode_t *dip;
	struct uuid clid;	/* Linux */
	int error, i;

	/*
	 * The PFS should be probed, so we should be able to
	 * locate it.  We only delete the PFS from the
	 * specific H2 block device (hmp), not all of
	 * them.  We must remove the PFS from the cluster
	 * before we can destroy it.
	 */
	if (flags & HAMMER2_PFSDEL_LOCKED) {
		/* the caller holds it; see hammer2_sync_snap_cleanup() */
	} else if (flags & HAMMER2_PFSDEL_TRYLOCK) {
		if (!hammer2_lk_tryex(&hammer2_mntlk))
			return (EAGAIN);
	} else {
		hammer2_lk_ex(&hammer2_mntlk);
	}

	pmp = hammer2_pfs_find_byname(hmp, name, &i);

	if (pmp == NULL) {
		if ((flags & HAMMER2_PFSDEL_LOCKED) == 0)
			hammer2_lk_unlock(&hammer2_mntlk);
		return (ENOENT);
	}
	if (pmp->mp) {
		if ((flags & HAMMER2_PFSDEL_LOCKED) == 0)
			hammer2_lk_unlock(&hammer2_mntlk);
		return (EBUSY);
	}

	/*
	 * Ok, we found the pmp and we have the index.  Permanently remove
	 * the PFS from the cluster.
	 */
	debug_hprintf("FOUND PFS %s CLINDEX %d\n", name, i);
	clid = pmp->pfs_clid;	/* Linux: for the master's delete below */
	hammer2_pfsdealloc(pmp, i, 1);

	/*
	 * XXX Linux: a PFS whose last element was just removed stayed on
	 * hammer2_pfslist until its device was torn down, since only
	 * hammer2_pfsfree_scan() frees a PFS at zero elements.  One such
	 * structure per pfs-delete was a slow accumulation; the
	 * synchronization thread deleting a snapshot every pass would make
	 * it a fast one.  An unmounted PFS left with no chain in any slot is
	 * freed here, under the same lock pfsfree_scan() holds for it.
	 */
	if (pmp->mp == NULL && pmp->iroot) {
		for (i = 0; i < pmp->iroot->cluster.nchains; ++i) {
			if (pmp->iroot->cluster.array[i].chain)
				break;
		}
		if (i == pmp->iroot->cluster.nchains)
			hammer2_pfsfree(pmp);
	}

	if ((flags & HAMMER2_PFSDEL_LOCKED) == 0)
		hammer2_lk_unlock(&hammer2_mntlk);

	/*
	 * XXX Linux: a snapshot on a connection device is the master's, taken
	 * for the thread's pass; its PFS here held a proxy of the root and
	 * is freed above, and the master deletes the snapshot itself at
	 * SNAPDEL, named by the cluster id the freed PFS carried.  The link's
	 * loss is not this delete's failure: the master deletes what a lost
	 * link left at the link's end.
	 */
	if (hammer2_dev_is_conn(hmp)) {
		error = hammer2_remote_snapshot_del(hmp, &clid, name);
		return (error == ENOTCONN ? 0 : error);
	}

	/*
	 * Now destroy the PFS under its device using the per-device
	 * super-root.
	 */
	spmp = hmp->spmp;
	dip = spmp->iroot;
	hammer2_trans_init(spmp, 0);
	hammer2_inode_lock(dip, 0);

	xop = hammer2_xop_alloc(dip, HAMMER2_XOP_MODIFYING);
	hammer2_xop_setname(&xop->head, name, strlen(name));
	xop->isdir = 2;
	xop->dopermanent = H2DOPERM_PERMANENT | H2DOPERM_FORCE;
	hammer2_xop_start(&xop->head, &hammer2_unlink_desc);
	error = hammer2_xop_collect(&xop->head, 0);
	error = hammer2_error_to_errno(error);
	hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);

	hammer2_inode_unlock(dip);
	hammer2_trans_done(spmp, HAMMER2_TRANS_SIDEQ);

	return (error);
}

static int
hammer2_ioctl_pfs_snapshot(hammer2_inode_t *ip, void *data)
{
	hammer2_ioc_pfs_t *pfs = data;

	if (ip->pmp->pfs_hmps[0] == NULL)
		return (EINVAL);

	if (pfs->name[0] == 0)
		return (EINVAL);
	pfs->name[sizeof(pfs->name) - 1] = 0;

	if (hammer2_is_rdonly(ip->pmp->mp))
		return (EROFS);

	return (hammer2_pfs_snapshot(ip->pmp, 0, pfs->name, pfs->pfs_flags,
	    NULL, NULL));
}

/*
 * XXX Linux: the body of the snapshot ioctl, callable from the
 * synchronization thread, which snapshots the master element it reads
 * from and the slave element it writes.  Upstream snapshots element 0;
 * clindex names the element here.  HAMMER2_PFSSNAP_PMPSYNC flushes the
 * PFS through hammer2_vfs_sync_pmp() rather than hammer2_sync(), whose
 * read of s_umount a thread that an unmount is waiting to stop must not
 * take.  *mtidp receives the snapshot transaction's id, the point in time
 * the snapshot represents, and *pmpp the PFS the snapshot
 * was registered as, so the thread need not walk hammer2_pfslist for it.
 * The caller has checked the name and the mount's writability; the thread
 * holds hammer2_mntlk across the call, since hammer2_pfsalloc() inserts
 * into a list the unmount walks under it, and the ioctl does not, which is
 * upstream's own exposure left as it stands.
 */
int
hammer2_pfs_snapshot(hammer2_pfs_t *pmp, int clindex, const char *name,
    int flags, hammer2_tid_t *mtidp, hammer2_pfs_t **pmpp)
{
	hammer2_dev_t *hmp, *force_local;
	hammer2_inode_t *ip;
	hammer2_chain_t *chain, *nchain;
	hammer2_inode_t *nip;
	hammer2_inode_data_t *wipdata;
	hammer2_tid_t mtid, starting_inum;
	int error;

	/*
	 * XXX Linux: hammer2_sync() needs the mount; the PFS sync does not,
	 * and the synchronization thread runs on a PFS whose cluster is not
	 * mounted whenever only a device of it is, which is the harness's
	 * divergence phase and every pass between a cluster unmount and the
	 * device's own.  Measured 2026-10-18: 14 passes refused with EINVAL
	 * while the live path in the same phase destroyed and replaced keys.
	 */
	ip = pmp->iroot;
	if (ip == NULL ||
	    (pmp->mp == NULL && (flags & HAMMER2_PFSSNAP_PMPSYNC) == 0))
		return (EINVAL);

	hmp = pmp->pfs_hmps[clindex];
	if (hmp == NULL)
		return (EINVAL);
	/*
	 * XXX Linux: an element on a connection device is a remote master's,
	 * which takes the snapshot on its own device at the thread's request
	 * and serves it over the link (hammer2_remote_snapshot_take()); only
	 * the thread's flag reaches here, the ioctl snapshotting element 0.
	 * Anything else on a connection device is refused before the body,
	 * which takes locks such a device never initialized and creates under
	 * a super-root it does not have.
	 */
	if (hammer2_dev_is_conn(hmp) && (flags & HAMMER2_PFSSNAP_PMPSYNC) &&
	    !HAMMER2_CTL_NOSNAPROUTE)
		return (hammer2_remote_snapshot_take(pmp, clindex, name, mtidp,
		    pmpp));
	if (hammer2_dev_is_conn(hmp))	/* XXX Linux */
		return (EOPNOTSUPP);

	hammer2_lk_ex(&hmp->bulklk);

	/*
	 * NOSYNC is for debugging.  We skip the filesystem sync and use
	 * a normal transaction (which is less likely to stall).  used for
	 * testing filesystem consistency.
	 *
	 * In normal mode we sync the filesystem and use a flush transaction.
	 */
	if (flags & HAMMER2_PFSFLAGS_NOSYNC) {
		hammer2_trans_init(pmp, 0);
	} else {
		if (flags & HAMMER2_PFSSNAP_PMPSYNC)	/* Linux */
			hammer2_vfs_sync_pmp(pmp, MNT_WAIT);
		else
			hammer2_sync(pmp->mp, MNT_WAIT);
		hammer2_trans_init(pmp, HAMMER2_TRANS_ISFLUSH);
	}
	mtid = hammer2_trans_sub(pmp);
	if (mtidp)		/* Linux */
		*mtidp = mtid;
	hammer2_inode_lock(ip, 0);
	hammer2_inode_modify(ip);
	ip->meta.pfs_lsnap_tid = mtid;

	chain = hammer2_inode_chain(ip, clindex, HAMMER2_RESOLVE_ALWAYS);
	if (chain == NULL) {
		/*
		 * XXX Linux: an element with no chain, which pfs-delete leaves
		 * behind in a slot; upstream dereferences it.
		 */
		hammer2_inode_unlock(ip);
		if (flags & HAMMER2_PFSFLAGS_NOSYNC)
			hammer2_trans_done(pmp, 0);
		else
			hammer2_trans_done(pmp,
			    HAMMER2_TRANS_ISFLUSH | HAMMER2_TRANS_SIDEQ);
		hammer2_lk_unlock(&hmp->bulklk);
		return (ENOENT);
	}
	hmp = chain->hmp;

	/*
	 * Create the snapshot directory under the super-root.
	 *
	 * Set PFS type, generate a unique filesystem id, and generate
	 * a cluster id.  Use the same clid when snapshotting a PFS root,
	 * which theoretically allows the snapshot to be used as part of
	 * the same cluster (perhaps as a cache).
	 *
	 * Note that pfs_lsnap_tid must be set in the snapshot as well,
	 * ensuring that any nocrc/nocomp file data modifications force
	 * a copy-on-write.
	 *
	 * Copy the (flushed) blockref array.  Theoretically we could use
	 * chain_duplicate() but it becomes difficult to disentangle
	 * the shared core so for now just brute-force it.
	 */
	hammer2_chain_unlock(chain);
	nip = hammer2_inode_create_pfs(hmp->spmp, name, strlen(name), &error);
	hammer2_chain_lock(chain, HAMMER2_RESOLVE_ALWAYS);

	if (nip) {
		atomic_set_int(&nip->flags, HAMMER2_INODE_NOSIDEQ);
		hammer2_inode_modify(nip);
		/*
		 * XXX Linux: the snapshot root is locked here under the
		 * chain it copies, which lives in another tree at the same
		 * level, so it takes the level of a chain under that one.
		 */
		if (nip->cluster.array[0].chain)
			hammer2_chain_lockdep_nest(
			    &nip->cluster.array[0].chain->lock, &chain->lock);
		nchain = hammer2_inode_chain(nip, 0, HAMMER2_RESOLVE_ALWAYS);
		error = hammer2_chain_modify(nchain, mtid, 0, 0);
		/*
		 * XXX Linux: upstream asserts this modify, which holds in
		 * hammer2_ioctl_pfs_create() under the super-root's flush
		 * transaction.  Here the transaction is the source PFS's, so
		 * a device sync can flush the new chain after
		 * hammer2_inode_create_pfs() unlocks it, and the modify then
		 * allocates and can fail with its data NULL.  The source
		 * chain was relocked above, which reads its data again after
		 * the unlock dropped it, and a failed read leaves it NULL.
		 * Either fails the snapshot and leaves the new root on media
		 * with the create's defaults, type NONE and zero ids, and
		 * registered nowhere until a remount, so a delete by name
		 * cannot find it before then.
		 */
		if (error == 0 && chain->data == NULL)
			error = chain->error ? chain->error : HAMMER2_ERROR_EIO;
		if (error) {
			hprintf("snapshot %s not taken, error %08x\n", name,
			    error);
			hammer2_chain_unlock(chain);
			hammer2_chain_unlock(nchain);
			hammer2_chain_drop(nchain);
			hammer2_inode_unlock(nip);
			goto done;
		}
		wipdata = &nchain->data->ipdata;

		starting_inum = ip->pmp->inode_tid + 1;
		nip->meta.pfs_inum = starting_inum;
		nip->meta.pfs_type = HAMMER2_PFSTYPE_MASTER;
		nip->meta.pfs_subtype = HAMMER2_PFSSUBTYPE_SNAPSHOT;
		nip->meta.op_flags |= HAMMER2_OPFLAG_PFSROOT;
		nip->meta.pfs_lsnap_tid = mtid;
		/*
		 * XXX Linux: the synchronization thread's snapshot carries the
		 * source root's own fields, the ones hammer2_sync_replace()
		 * copies onto a PFS root, so a slave root brought to the
		 * snapshot's is brought to the master's and not to a new PFS's
		 * defaults (mode 0755, the creation time, the super-root's
		 * algorithms); the thread's idle test reads the same fields
		 * back.  The ioctl's snapshots keep upstream's shape.
		 */
		if (flags & HAMMER2_PFSSNAP_PMPSYNC)
			hammer2_sync_root_meta_copy(&nip->meta,
			    &chain->data->ipdata.meta);
		nchain->bref.embed.stats = chain->bref.embed.stats;

		kern_uuidgen(&nip->meta.pfs_fsid, 1);
		kern_uuidgen(&nip->meta.pfs_clid, 1);
		nchain->bref.flags |= HAMMER2_BREF_FLAG_PFSROOT;

		/* XXX hack blockset copy */
		/* XXX doesn't work with real cluster */
		/*
		 * XXX Linux: it works for one named element, which is what the
		 * synchronization thread asks for: the blockset copied is that
		 * element's flushed root, and the snapshot is of that element.
		 */
		wipdata->meta = nip->meta;
		hammer2_spin_ex(&pmp->blockset_spin);
		wipdata->u.blockset = pmp->pfs_iroot_blocksets[clindex];
		hammer2_spin_unex(&pmp->blockset_spin);

		KKASSERT(wipdata == &nchain->data->ipdata);

		/*
		 * XXX Linux: the source chain has been copied and is not
		 * read again.  The flush below locks the super-root's chain,
		 * which a mount locks before the chain of the PFS root it
		 * looks up, so holding this one across the flush is the
		 * reverse of that order; lockdep reported the cycle.
		 */
		hammer2_chain_unlock(chain);

		hammer2_chain_unlock(nchain);
		hammer2_inode_ref(nip);
		hammer2_inode_unlock(nip);
		hammer2_inode_chain_sync(nip);
		hammer2_inode_chain_flush(nip,
		    HAMMER2_XOP_INODE_STOP | HAMMER2_XOP_FSSYNC);
		    /* XXX | HAMMER2_XOP_VOLHDR */
		hammer2_inode_drop(nip);
		/* nip is dead */

		force_local = (hmp->hflags & HMNT2_LOCAL) ? hmp : NULL;

		hammer2_chain_lock(nchain, HAMMER2_RESOLVE_ALWAYS);
		/* XXX Linux: read back as in hammer2_ioctl_pfs_create() */
		if (nchain->data == NULL) {
			error = nchain->error ? nchain->error :
			    HAMMER2_ERROR_EIO;
			hprintf("snapshot %s created but not read back, error %08x\n",
			    name, error);
		} else {
			wipdata = &nchain->data->ipdata;
			debug_hprintf("SNAPSHOT LOCAL PFS (IOCTL): %s\n",
			    wipdata->filename);
			hammer2_pfsalloc(nchain, wipdata, force_local);
			nchain->pmp->inode_tid = starting_inum;
			if (pmpp)		/* Linux */
				*pmpp = nchain->pmp;
		}

		hammer2_chain_unlock(nchain);
		hammer2_chain_drop(nchain);
	}

done:
	if (nip == NULL)	/* XXX Linux: otherwise released above */
		hammer2_chain_unlock(chain);
	hammer2_chain_drop(chain);

	hammer2_inode_unlock(ip);
	if (flags & HAMMER2_PFSFLAGS_NOSYNC)
		hammer2_trans_done(pmp, 0);
	else
		hammer2_trans_done(pmp,
		    HAMMER2_TRANS_ISFLUSH | HAMMER2_TRANS_SIDEQ);

	hammer2_lk_unlock(&hmp->bulklk);

	return (hammer2_error_to_errno(error));
}

/*
 * Retrieve the raw inode structure, non-inclusive of node-specific data.
 */
static int
hammer2_ioctl_inode_get(hammer2_inode_t *ip, void *data)
{
	hammer2_ioc_inode_t *ino = data;

	hammer2_inode_lock(ip, HAMMER2_RESOLVE_SHARED);

	ino->data_count = hammer2_inode_data_count(ip);
	ino->inode_count = hammer2_inode_inode_count(ip);
	bzero(&ino->ip_data, sizeof(ino->ip_data));
	ino->ip_data.meta = ip->meta;

	hammer2_inode_unlock(ip);

	return (0);
}

/*
 * Set various parameters in an inode which cannot be set through
 * normal filesystem VNOPS.
 */
static int
hammer2_ioctl_inode_set(hammer2_inode_t *ip, void *data)
{
	hammer2_ioc_inode_t *ino = data;

	if (hammer2_is_rdonly(ip->pmp->mp))
		return (EROFS);

	hammer2_trans_init(ip->pmp, 0);
	hammer2_inode_lock(ip, 0);

	if ((ino->flags & HAMMER2IOC_INODE_FLAG_CHECK) &&
	    ip->meta.check_algo != ino->ip_data.meta.check_algo) {
		hammer2_inode_modify(ip);
		ip->meta.check_algo = ino->ip_data.meta.check_algo;
	}
	if ((ino->flags & HAMMER2IOC_INODE_FLAG_COMP) &&
	    ip->meta.comp_algo != ino->ip_data.meta.comp_algo) {
		hammer2_inode_modify(ip);
		ip->meta.comp_algo = ino->ip_data.meta.comp_algo;
	}

	/* Ignore these flags for now... */
	if ((ino->flags & HAMMER2IOC_INODE_FLAG_IQUOTA) &&
	    ip->meta.inode_quota != ino->ip_data.meta.inode_quota) {
		hammer2_inode_modify(ip);
		ip->meta.inode_quota = ino->ip_data.meta.inode_quota;
	}
	if ((ino->flags & HAMMER2IOC_INODE_FLAG_DQUOTA) &&
	    ip->meta.data_quota != ino->ip_data.meta.data_quota) {
		hammer2_inode_modify(ip);
		ip->meta.data_quota = ino->ip_data.meta.data_quota;
	}
	if ((ino->flags & HAMMER2IOC_INODE_FLAG_COPIES) &&
	    ip->meta.ncopies != ino->ip_data.meta.ncopies) {
		hammer2_inode_modify(ip);
		ip->meta.ncopies = ino->ip_data.meta.ncopies;
	}

	hammer2_inode_unlock(ip);
	hammer2_trans_done(ip->pmp, HAMMER2_TRANS_SIDEQ);

	return (0);
}

/*
 * Recursively dump chains of a given inode.
 */
static int
hammer2_ioctl_debug_dump(hammer2_inode_t *ip, unsigned int flags __maybe_unused)	/* XXX Linux: was __unused */
{
#ifdef HAMMER2_INVARIANTS
	hammer2_chain_t *chain;
	int i;

	for (i = 0; i < ip->cluster.nchains; ++i) {
		chain = ip->cluster.array[i].chain;
		if (chain) {
			hprintf("cluster #%d\n", i);
			hammer2_dump_chain(chain, 0, 0, -1, 'i');
		}
	}

	return (0);
#else
	return (EOPNOTSUPP);
#endif
}

/*
 * Turn on or off emergency mode on a filesystem.
 */
static int
hammer2_ioctl_emerg_mode(hammer2_inode_t *ip, u_int mode)
{
	hammer2_pfs_t *pmp = ip->pmp;
	hammer2_dev_t *hmp;
	int i;

	if (mode) {
		hprintf("WARNING: Emergency mode enabled\n");
		atomic_set_int(&pmp->flags, HAMMER2_PMPF_EMERG);
	} else {
		hprintf("WARNING: Emergency mode disabled\n");
		atomic_clear_int(&pmp->flags, HAMMER2_PMPF_EMERG);
	}

	for (i = 0; i < HAMMER2_MAXCLUSTER; ++i) {
		hmp = pmp->pfs_hmps[i];
		if (hmp == NULL)
			continue;
		if (mode)
			atomic_set_int(&hmp->hflags, HMNT2_EMERG);
		else
			atomic_clear_int(&hmp->hflags, HMNT2_EMERG);
	}

	return (0);
}

/*
 * Do a bulkfree scan on media related to the PFS.  This routine will
 * flush all PFSs associated with the media before doing the bulkfree
 * scan.
 *
 * This version can only run on non-clustered media.  A new ioctl or a
 * temporary mount of @LOCAL will be needed to run on clustered media.
 */
static int
hammer2_ioctl_bulkfree_scan(hammer2_inode_t *ip, void *data)
{
	hammer2_ioc_bulkfree_t *bfi = data;
	hammer2_dev_t *hmp;
	hammer2_pfs_t *pmp;
	hammer2_chain_t *vchain;
	int error = 0, didsnap, etmp, i;

	ip = ip->pmp->iroot;

	hmp = ip->pmp->pfs_hmps[0];
	if (hmp == NULL)
		return (EINVAL);
	if (bfi == NULL)
		return (EINVAL);

	if (hammer2_is_rdonly(ip->pmp->mp))
		return (EROFS);

	/*
	 * Bulkfree has to be serialized to guarantee at least one sync
	 * inbetween bulkfrees.
	 */
	hammer2_lk_ex(&hmp->bflk);

	/* Sync all mounts related to the media. */
	hammer2_lk_ex(&hammer2_mntlk);
	TAILQ_FOREACH(pmp, &hammer2_pfslist, mntentry) {
		for (i = 0; i < HAMMER2_MAXCLUSTER; ++i) {
			if (pmp->pfs_hmps[i] != hmp)
				continue;
			etmp = hammer2_vfs_sync_pmp(pmp, MNT_WAIT);
			if (etmp && (error == 0 || error == ENOSPC))
				error = etmp;
			break;
		}
	}
	hammer2_lk_unlock(&hammer2_mntlk);

	if (error && error != ENOSPC)
		goto failed;

	/*
	 * If we have an ENOSPC error we have to bulkfree on the live
	 * topology.  Otherwise we can bulkfree on a snapshot.
	 */
	if (error) {
		hprintf("WARNING: bulkfree forced to use live topology due to "
		    "ENOSPC\n");
		vchain = &hmp->vchain;
		hammer2_chain_ref(vchain);
		didsnap = 0;
	} else {
		vchain = hammer2_chain_bulksnap(hmp);
		didsnap = 1;
	}

	/*
	 * Normal bulkfree operations do not require a transaction because
	 * they operate on a snapshot, and so can run concurrently with
	 * any operation except another bulkfree.
	 *
	 * If we are running bulkfree on the live topology we have to be
	 * in a FLUSH transaction.
	 */
	if (didsnap == 0)
		hammer2_trans_init(hmp->spmp, HAMMER2_TRANS_ISFLUSH);
	error = hammer2_bulkfree_pass(hmp, vchain, bfi);
	if (didsnap) {
		hammer2_chain_bulkdrop(vchain);
	} else {
		hammer2_chain_drop(vchain);
		hammer2_trans_done(hmp->spmp, HAMMER2_TRANS_ISFLUSH |
		    HAMMER2_TRANS_SIDEQ);
	}
	error = hammer2_error_to_errno(error);

failed:
	hammer2_lk_unlock(&hmp->bflk);
	return (error);
}

/*
 * Unconditionally delete meta-data in a hammer2 filesystem.
 */
static int
hammer2_ioctl_destroy(hammer2_inode_t *ip, void *data)
{
#ifdef HAMMER2_INVARIANTS
	hammer2_ioc_destroy_t *iocd = data;
	hammer2_pfs_t *pmp = ip->pmp;
	int error;

	if (pmp->rdonly)
		return (EROFS);
	if (hammer2_is_rdonly(ip->pmp->mp))
		return (EROFS);

	switch (iocd->cmd) {
	case HAMMER2_DELETE_FILE:
		/*
		 * Destroy a bad directory entry by name.  Caller must
		 * pass the directory as fd.
		 */
		{
		hammer2_xop_unlink_t *xop;

		if (iocd->path[sizeof(iocd->path)-1]) {
			error = EINVAL;
			break;
		}
		if (ip->meta.type != HAMMER2_OBJTYPE_DIRECTORY) {
			error = EINVAL;
			break;
		}
		hammer2_trans_init(pmp, 0);
		hammer2_inode_lock(ip, 0);

		xop = hammer2_xop_alloc(ip, HAMMER2_XOP_MODIFYING);
		hammer2_xop_setname(&xop->head, iocd->path, strlen(iocd->path));
		xop->isdir = -1;
		xop->dopermanent =
		    H2DOPERM_PERMANENT | H2DOPERM_FORCE | H2DOPERM_IGNINO;
		hammer2_xop_start(&xop->head, &hammer2_unlink_desc);
		error = hammer2_xop_collect(&xop->head, 0);
		error = hammer2_error_to_errno(error);
		hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);

		hammer2_inode_unlock(ip);
		hammer2_trans_done(pmp, HAMMER2_TRANS_SIDEQ);
		}
		break;
	case HAMMER2_DELETE_INUM:
		/* Destroy a bad inode by inode number. */
		{
		hammer2_xop_lookup_t *xop;

		if (iocd->inum < 1) {
			error = EINVAL;
			break;
		}
		hammer2_trans_init(pmp, 0);

		xop = hammer2_xop_alloc(pmp->iroot, HAMMER2_XOP_MODIFYING);
		xop->lhc = iocd->inum;
		hammer2_xop_start(&xop->head, &hammer2_delete_desc);
		error = hammer2_xop_collect(&xop->head, 0);
		error = hammer2_error_to_errno(error);
		hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);

		hammer2_trans_done(pmp, HAMMER2_TRANS_SIDEQ);
		}
		break;
	default:
		error = EINVAL;
		break;
	}

	return (error);
#else
	return (EOPNOTSUPP);
#endif
}

/*
 * Grow a filesystem into its partition size.
 */
static int
hammer2_ioctl_growfs(hammer2_inode_t *ip, void *data)
{
	hammer2_ioc_growfs_t *grow = data;
	hammer2_dev_t *hmp;
	hammer2_off_t size, delta;
	hammer2_tid_t mtid;
	hammer2_io_t *dio;	/* XXX Linux: was struct buf, GEOM consumer, daddr_t */
	int i, error;

	hmp = ip->pmp->pfs_hmps[0];
	if (hmp == NULL)
		return (EINVAL);

	if (hammer2_is_rdonly(ip->pmp->mp))
		return (EROFS);

	if (hmp->nvolumes > 1) {
		hprintf("growfs currently unsupported with multiple volumes\n");
		return (EOPNOTSUPP);
	}
	KKASSERT(hmp->total_size == hmp->voldata.volu_size);

	/* Get media size. */
	/* XXX Linux: the block device's own size, not a GEOM provider's. */
	size = bdev_nr_bytes(file_bdev(TAILQ_FIRST(&hmp->devvp_list)->bdev_file));
	hprintf("growfs partition-auto to %016llx\n", (long long)size);

	/* Expand to devvp size unless specified. */
	grow->modified = 0;
	if (grow->size == 0) {
		grow->size = size;
	} else if (grow->size > size) {
		hprintf("growfs size %016llx exceeds device size %016llx\n",
		    (long long)grow->size, (long long)size);
		return (EINVAL);
	}

	/*
	 * This is typically ~8MB alignment to avoid edge cases accessing
	 * reserved blocks at the base of each 2GB zone.
	 */
	grow->size &= ~HAMMER2_VOLUME_ALIGNMASK64;
	delta = grow->size - hmp->voldata.volu_size;

	/* Maximum allowed size is 2^63. */
	if (grow->size > 0x7FFFFFFFFFFFFFFFLU) {
		hprintf("growfs failure, limit is 2^63 - 1 bytes\n");
		return (EINVAL);
	}

	/* We can't shrink a filesystem. */
	if (grow->size < hmp->voldata.volu_size) {
		hprintf("growfs failure, would shrink from %016llx to %016llx\n",
		    (long long)hmp->voldata.volu_size, (long long)grow->size);
		return (EINVAL);
	}

	if (delta == 0) {
		hprintf("growfs - size did not change\n");
		return (0);
	}

	/*
	 * Clear any new volume header backups that we extend into.
	 * Skip volume headers that are already part of the filesystem.
	 */
	for (i = 0; i < HAMMER2_NUM_VOLHDRS; ++i) {
		if (i * HAMMER2_ZONE_BYTES64 < hmp->voldata.volu_size)
			continue;
		if (i * HAMMER2_ZONE_BYTES64 >= grow->size)
			break;
		hprintf("growfs - clear volhdr %d\n", i);
		/*
		 * XXX Linux: FreeBSD zeroes the zone through bread(9) and
		 * bwrite(9) on the device vnode.  The DIO layer is the one
		 * path to the device here, and hammer2_io_new() hands back a
		 * zeroed buffer for exactly this block.
		 */
		error = hammer2_io_new(hmp, HAMMER2_BREF_TYPE_VOLUME,
		    i * HAMMER2_ZONE_BYTES64, HAMMER2_VOLUME_BYTES, &dio);
		if (error) {
			hprintf("I/O error %d\n", error);
			return (EINVAL);
		}
		error = hammer2_io_bwrite(&dio);
		if (error) {
			hprintf("I/O error %d\n", error);
			return (EINVAL);
		}
	}

	hammer2_trans_init(hmp->spmp, HAMMER2_TRANS_ISFLUSH);
	mtid = hammer2_trans_sub(hmp->spmp);

	hprintf("growfs - expand by %016llx to %016llx mtid %016llx\n",
	    (long long)delta, (long long)grow->size, (long long)mtid);

	hammer2_voldata_lock(hmp);
	hammer2_voldata_modify(hmp);

	/*
	 * NOTE: Just adjusting total_size for a single-volume filesystem
	 *	 or for the last volume in a multi-volume filesystem, is
	 *	 fine.  But we can't grow any other partition in a multi-volume
	 *	 filesystem.  For now we just punt (at the top) on any
	 *	 multi-volume filesystem.
	 */
	hmp->voldata.volu_size = grow->size;
	hmp->voldata.total_size += delta;
	hmp->voldata.allocator_size += delta;
	hmp->voldata.allocator_free += delta;
	hmp->total_size += delta;
	hmp->volumes[0].size += delta; /* note: indexes first (only) volume */

	hammer2_voldata_unlock(hmp);

	hammer2_trans_done(hmp->spmp,
	    HAMMER2_TRANS_ISFLUSH | HAMMER2_TRANS_SIDEQ);
	grow->modified = 1;

	/*
	 * Flush the mess right here and now.  We could just let the
	 * filesystem syncer do it, but this was a sensitive operation
	 * so don't take any chances.
	 */
	hammer2_sync(ip->pmp->mp, MNT_WAIT);

	return (0);
}

/*
 * Get a list of volumes.
 */
static int
hammer2_ioctl_volume_list(hammer2_inode_t *ip, void *data)
{
	hammer2_ioc_volume_list_t *vollist = data;
	hammer2_ioc_volume_t entry;
	hammer2_volume_t *vol;
	hammer2_dev_t *hmp = ip->pmp->pfs_hmps[0];
	int i, error = 0, cnt = 0;

	if (hmp == NULL)
		return (EINVAL);

	for (i = 0; i < hmp->nvolumes; ++i) {
		if (cnt >= vollist->nvolumes)
			break;
		vol = &hmp->volumes[i];
		bzero(&entry, sizeof(entry));
		/* Copy hammer2_volume_t fields. */
		entry.id = vol->id;
		/*
		 * XXX Linux: was bcopy of sizeof(entry.path) from a string
		 * kstrdup() sized to its length, a read past the allocation
		 * that KASAN reports; the string copy is what was meant.
		 */
		strscpy_pad(entry.path, vol->dev->path);
		entry.offset = vol->offset;
		entry.size = vol->size;
		/*
		 * XXX Linux: was copyout.  volumes is a user pointer carried
		 * in a header the four trees share, so the address space is
		 * named here rather than there.
		 */
		error = copy_to_user((void __user *)&vollist->volumes[cnt],
		    &entry, sizeof(entry)) ? EFAULT : 0;
		if (error)
			return (error);
		cnt++;
	}
	vollist->nvolumes = cnt;
	vollist->version = hmp->voldata.version;
	/* XXX Linux: was bcopy, as above */
	strscpy_pad(vollist->pfs_name, ip->pmp->pfs_names[0]);

	return (error);
}

/*
 * Get a list of volumes (version 2).
 */
static int
hammer2_ioctl_volume_list2(hammer2_inode_t *ip, void *data)
{
	hammer2_ioc_volume_list2_t *vollist = data;
	hammer2_ioc_volume2_t *entry;
	hammer2_volume_t *vol;
	hammer2_dev_t *hmp = ip->pmp->pfs_hmps[0];
	int i, error = 0, cnt = 0;

	if (hmp == NULL)
		return (EINVAL);

	for (i = 0; i < hmp->nvolumes; ++i) {
		if (cnt >= vollist->nvolumes)
			break;
		vol = &hmp->volumes[i];
		entry = &vollist->volumes[cnt];
		/* Copy hammer2_volume_t fields. */
		entry->id = vol->id;
		strscpy_pad(entry->path, vol->dev->path);	/* XXX Linux */
		entry->offset = vol->offset;
		entry->size = vol->size;
		cnt++;
	}
	vollist->nvolumes = cnt;
	vollist->version = hmp->voldata.version;
	/* XXX Linux: was bcopy, as above */
	strscpy_pad(vollist->pfs_name, ip->pmp->pfs_names[0]);

	return (error);
}

int
hammer2_ioctl_impl(struct inode *vp, unsigned int com, void *data, int fflag,
    const struct cred *cred)	/* XXX Linux: was struct vnode, u_long, struct ucred */
{
	hammer2_inode_t *ip = VTOI(vp);
	int error;

	switch (com) {
	case HAMMER2IOC_VERSION_GET:
		error = hammer2_ioctl_version_get(ip, data);
		break;
	case HAMMER2IOC_RECLUSTER:
		error = hammer2_ioctl_recluster(ip, data);
		break;
	case HAMMER2IOC_REMOTE_SCAN:
		error = hammer2_ioctl_remote_scan(ip, data);
		break;
	case HAMMER2IOC_REMOTE_ADD:
		error = hammer2_ioctl_remote_add(ip, data);
		break;
	case HAMMER2IOC_REMOTE_DEL:
		error = hammer2_ioctl_remote_del(ip, data);
		break;
	case HAMMER2IOC_REMOTE_REP:
		error = hammer2_ioctl_remote_rep(ip, data);
		break;
	case HAMMER2IOC_SOCKET_GET:
		error = hammer2_ioctl_socket_get(ip, data);
		break;
	case HAMMER2IOC_SOCKET_SET:
		error = hammer2_ioctl_socket_set(ip, data);
		break;
	case HAMMER2IOC_PFS_GET:
		error = hammer2_ioctl_pfs_get(ip, data);
		break;
	case HAMMER2IOC_PFS_LOOKUP:
		error = hammer2_ioctl_pfs_lookup(ip, data);
		break;
	case HAMMER2IOC_PFS_CREATE:
		error = hammer2_ioctl_pfs_create(ip, data);
		break;
	case HAMMER2IOC_PFS_DELETE:
		error = hammer2_ioctl_pfs_delete(ip, data);
		break;
	case HAMMER2IOC_PFS_SNAPSHOT:
		error = hammer2_ioctl_pfs_snapshot(ip, data);
		break;
	case HAMMER2IOC_INODE_GET:
		error = hammer2_ioctl_inode_get(ip, data);
		break;
	case HAMMER2IOC_INODE_SET:
		error = hammer2_ioctl_inode_set(ip, data);
		break;
	case HAMMER2IOC_DEBUG_DUMP:
		error = hammer2_ioctl_debug_dump(ip, *(unsigned int *)data);
		break;
	case HAMMER2IOC_EMERG_MODE:
		error = hammer2_ioctl_emerg_mode(ip, *(unsigned int *)data);
		break;
	case HAMMER2IOC_BULKFREE_SCAN:
		error = hammer2_ioctl_bulkfree_scan(ip, data);
		break;
	case HAMMER2IOC_DESTROY:
		error = hammer2_ioctl_destroy(ip, data);
		break;
	case HAMMER2IOC_GROWFS:
		error = hammer2_ioctl_growfs(ip, data);
		break;
	case HAMMER2IOC_VOLUME_LIST:
		error = hammer2_ioctl_volume_list(ip, data);
		break;
	case HAMMER2IOC_VOLUME_LIST2:
		error = hammer2_ioctl_volume_list2(ip, data);
		break;
	/* XXX Linux: FIOSEEKDATA and FIOSEEKHOLE are ->llseek here, not ioctls. */
	default:
		/*
		 * XXX Linux: EOPNOTSUPP on a BSD reaches userland as ENOTTY,
		 * the ioctl layer mapping it; nothing maps it here, so an
		 * unrecognized command reported "Operation not supported"
		 * where every other Linux driver reports "Inappropriate
		 * ioctl for device". The refusals above stay EOPNOTSUPP:
		 * they are commands this port has, declining the request.
		 */
		error = ENOTTY;
		break;
	}
	/* XXX Linux: the in_seek assertion went with the seek ioctls above. */

	return (error);
}
