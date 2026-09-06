// SPDX-License-Identifier: BSD-3-Clause
/*
 * Copyright (c) 2026 James Manring.  All rights reserved.
 * Copyright (c) 2022-2023 Tomohiro Kusumi <tkusumi@netbsd.org>
 * Copyright (c) 2011-2022 The DragonFly Project.  All rights reserved.
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

/*
 * The vnode operations, which on Linux are three tables rather than one
 * vop vector: inode_operations, file_operations and
 * address_space_operations.
 *
 * WHAT IS HERE AND WHY IT IS FIRST.  Until this file the root inode
 * carried no operations at all: hammer2_igetv() set i_mode and nothing
 * else, so d_make_root() produced a directory the VFS could not look up
 * in, could not read and could not stat correctly.  The read path was
 * planned ahead of this and could not have run: ->read_folio is reached
 * through a regular file's inode, a regular file's inode is reached
 * through ->lookup on its parent, and there was no ->lookup.
 *
 * ->lookup is upstream's hammer2_lookup() with the parts Linux does
 * itself removed, which is most of its length.  The dcache resolves "."
 * and "..", so the ISDOTDOT and single-dot branches are not carried, and
 * the nameiop cases are not carried either: FreeBSD's lookup is told
 * which operation the name is being resolved for and pre-checks write
 * access to the directory, where Linux calls ->lookup with no such
 * intent and checks permission in the operation itself.  What remains is
 * the nresolve XOP, which is the part that reads the media, and it is
 * carried unchanged in shape.
 *
 * ->iterate_shared is upstream's hammer2_readdir() with the cookie array
 * and the artificial entries dropped, for the reasons written above it.
 *
 * A regular file reads through ->read_iter and ->read_folio, and a
 * symlink reads its target through the same ->read_folio, the way
 * hammer2_vop_readlink() reads it with hammer2_read_file().
 */

#include "hammer2.h"

#include <linux/pagemap.h>	/* Linux: write_begin_get_folio, folio_* */
#include <linux/writeback.h>	/* Linux: writeback_iter */

static int hammer2_vop_setattr(struct mnt_idmap *, struct dentry *,
    struct iattr *);

/*
 * Resolve one name in a directory.
 *
 * Returns a dentry rather than an errno: d_splice_alias() attaches the
 * inode to the dentry and returns NULL in the ordinary case, and a NULL
 * inode makes the dentry negative, which is how a missing name is
 * reported.  ENOENT from the XOP is therefore not an error here, which
 * is the one place this differs in kind from upstream rather than in
 * detail.
 */
static struct dentry *
hammer2_vop_lookup(struct inode *dir, struct dentry *dentry,
    unsigned int flags __maybe_unused)
{
	hammer2_xop_nresolve_t *xop;
	hammer2_inode_t *dip = VTOI(dir), *ip;
	struct inode *inode = NULL;
	int error;

	/*
	 * Strictly less, which is the bound upstream asserts at both call
	 * sites in hammer2_inode.c: HAMMER2_INODE_MAXNAME is the size of
	 * the on-media filename array, so a name of exactly that length
	 * does not fit the comparison the core makes.  The VFS rejects
	 * anything past NAME_MAX before ->lookup is reached, which is 255
	 * and smaller again, so this guard is unreachable through a path
	 * walk.  It is still the core's bound and is written as the core
	 * writes it.
	 */
	if (dentry->d_name.len >= HAMMER2_INODE_MAXNAME)
		return (ERR_PTR(-ENAMETOOLONG));	/* Linux: negative */

	hammer2_inode_lock(dip, HAMMER2_RESOLVE_SHARED);
	xop = hammer2_xop_alloc(dip, 0);
	/*
	 * The cast is the sign difference and nothing else: d_name.name is
	 * const unsigned char *, and the XOP takes the const char * that
	 * the carried core uses throughout.  clang reports it under
	 * -Wpointer-sign and gcc does not, which is why the syntax gate
	 * runs both.
	 */
	hammer2_xop_setname(&xop->head, (const char *)dentry->d_name.name,
	    dentry->d_name.len);	/* Linux */
	hammer2_xop_start(&xop->head, &hammer2_nresolve_desc);

	error = hammer2_error_to_errno(hammer2_xop_collect(&xop->head, 0));
	if (error == 0)
		ip = hammer2_inode_get(dip->pmp, &xop->head, -1, -1);
	else
		ip = NULL;
	hammer2_inode_unlock(dip);

	if (ip) {
		error = hammer2_igetv(ip, 0, &inode);
		/*
		 * hammer2_inode_unlock() drops the reference as well as
		 * releasing the lock, in this port as in DragonFly.  The
		 * comment above hammer2_inode_get() reads "dispose of both
		 * via hammer2_inode_unlock() + hammer2_inode_drop()", where
		 * both is the lock and the reference and not two
		 * references, so there is no drop to make here.
		 */
		hammer2_inode_unlock(ip);
	}

	/*
	 * The retire is last, as it is upstream: hammer2_inode_get() reads
	 * the cluster this XOP owns.
	 */
	hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);

	if (error && error != ENOENT)
		return (ERR_PTR(hammer2_vfs_errno(error)));	/* Linux */

	return (d_splice_alias(inode, dentry));
}

/*
 * Read one directory.
 *
 * This is upstream's hammer2_vop_readdir() with the cookie array and the
 * artificial entries dropped.  The cookie array is a DragonFly NFS
 * export interface that Linux does not have: nfsd reads ctx->pos, which
 * this fills with the same values the array would have carried.  The
 * artificial entries are dir_emit_dots(), which resolves "." and ".."
 * from the dentry the same way the dcache resolves them for ->lookup, so
 * the mount-point check upstream makes against pmp->iroot is the VFS's
 * to make and not this module's.
 *
 * WHAT THE COOKIE IS.  A directory is hash-ordered, not sequential, so
 * ctx->pos is a key and not an index.  hammer2_dirhash() sets bit 63 on
 * every key it produces and bit 15 below it, which reserves 0x0000-0x7FFF
 * for the artificial entries and leaves bit 63 free to be stripped, so
 * that what reaches userspace is always a positive 64-bit quantity.  So a
 * position is a key with bit 63 cleared, and resuming means putting it
 * back.
 *
 * WHY ctx->pos TRAILS BY ONE ENTRY.  It is set to the key of the entry
 * about to be emitted, not the one after it, because the key of the next
 * entry is not known until the XOP feeds it.  A dir_emit() that returns
 * false therefore leaves ctx->pos on the entry that did not fit and the
 * next call re-reads it, which is what upstream's saveoff does on the
 * same break.  Exhaustion is the one case that can advance past the last
 * entry, and it sets HAMMER2_DIRHASH_USERMSK, whose lookup finds nothing
 * on a subsequent call.
 */
static int
hammer2_vop_readdir(struct file *file, struct dir_context *ctx)
{
	hammer2_xop_readdir_t *xop;
	hammer2_blockref_t bref;
	hammer2_inode_t *ip = VTOI(file_inode(file));
	hammer2_key_t lkey;
	int dtype, error;

	if (!dir_emit_dots(file, ctx))
		return (0);	/* Linux: not an error, the buffer is full */

	hammer2_inode_lock(ip, HAMMER2_RESOLVE_SHARED);

	lkey = ctx->pos | HAMMER2_DIRHASH_VISIBLE;
	xop = hammer2_xop_alloc(ip, 0);
	xop->lkey = lkey;
	hammer2_xop_start(&xop->head, &hammer2_readdir_desc);

	for (;;) {
		const hammer2_inode_data_t *ripdata;
		const char *dname;
		uint16_t namlen;
		bool ok;

		error = hammer2_error_to_errno(hammer2_xop_collect(&xop->head,
		    0));
		if (error)
			break;
		hammer2_cluster_bref(&xop->head.cluster, &bref);
		ctx->pos = bref.key & HAMMER2_DIRHASH_USERMSK;

		if (bref.type == HAMMER2_BREF_TYPE_INODE) {
			ripdata = &hammer2_xop_gdata(&xop->head)->ipdata;
			dtype = hammer2_get_dtype(ripdata->meta.type);
			/*
			 * The cast is the sign difference and nothing
			 * else, as at the setname call in ->lookup:
			 * filename is unsigned char[] on the media and
			 * dir_emit() takes const char *.  clang reports
			 * it under -Wpointer-sign and gcc does not.
			 */
			ok = dir_emit(ctx, (const char *)ripdata->filename,
			    ripdata->meta.name_len,
			    ripdata->meta.inum & HAMMER2_DIRHASH_USERMSK,
			    dtype);
			hammer2_xop_pdata(&xop->head);
			if (!ok)
				break;
		} else if (bref.type == HAMMER2_BREF_TYPE_DIRENT) {
			/*
			 * A name that fits the blockref's check area is
			 * stored there and the entry has no data block,
			 * which is why the get is conditional and the put
			 * has to match it.
			 */
			dtype = hammer2_get_dtype(bref.embed.dirent.type);
			namlen = bref.embed.dirent.namlen;
			if (namlen <= sizeof(bref.check.buf))
				dname = bref.check.buf;
			else
				dname = hammer2_xop_gdata(&xop->head)->buf;
			ok = dir_emit(ctx, dname, namlen,
			    bref.embed.dirent.inum, dtype);
			if (namlen > sizeof(bref.check.buf))
				hammer2_xop_pdata(&xop->head);
			if (!ok)
				break;
		} else {
			/*
			 * Upstream prints and continues.  A type that
			 * cannot be named is media this module does not
			 * understand, so it is reported once and the
			 * listing goes on rather than truncating.
			 */
			WARN_ONCE(1, "hammer2: bad chain type %d in readdir\n",
			    bref.type);	/* Linux */
		}
	}
	hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);

	if (error == ENOENT) {
		error = 0;
		ctx->pos = HAMMER2_DIRHASH_USERMSK;
	}
	hammer2_inode_unlock(ip);

	return (hammer2_vfs_errno(error));	/* Linux: negative, EDOM is EIO */
}

/*
 * Create a new inode under dir and give it the name, which is the body
 * shared by upstream's hammer2_create(), hammer2_mknod(), hammer2_mkdir()
 * and hammer2_symlink(), each of which repeats it.  The directory is
 * locked before the new inode, as upstream says, to avoid deadlock;
 * inode_depend() precedes igetv() because igetv() may release the inode
 * lock.  The mtime update on the directory is upstream's, and its link
 * count moves with a subdirectory as hammer2_mkdir() moves it.  The
 * Linux inode's own copies of the directory's times and link count are
 * kept beside the meta so stat is right without a flush.
 *
 * A symlink's target is written last, as hammer2_symlink() does with
 * hammer2_write_file(), through page_symlink() over the same
 * ->write_begin and ->write_end a regular file uses, with the new inode
 * unlocked as upstream has it there.
 */
static int
hammer2_vop_ncreate(struct mnt_idmap *idmap, struct inode *dir,
    struct dentry *dentry, umode_t mode, dev_t rdev, const char *target)
{
	hammer2_inode_t *dip = VTOI(dir), *nip;
	struct inode *inode = NULL;
	hammer2_tid_t inum;
	uint64_t mtime;
	int error;

	if (dip->pmp->rdonly || (dip->pmp->flags & HAMMER2_PMPF_EMERG))
		return (-EROFS);
	hammer2_pfs_memory_wait(dip->pmp);	/* Linux: hammer2_vfs_modifying() */
	if (hammer2_vfs_enospace(dip, 0, current_cred()) > 1)
		return (-ENOSPC);
	if (S_ISDIR(mode) && dip->meta.nlinks >= U32_MAX)	/* Linux */
		return (-EMLINK);
	if (dentry->d_name.len > HAMMER2_INODE_MAXNAME)
		return (-ENAMETOOLONG);

	hammer2_trans_init(dip->pmp, 0);
	inum = hammer2_trans_newinum(dip->pmp);

	hammer2_inode_lock(dip, 0);
	nip = hammer2_inode_create_normal(dip, mode, rdev, idmap, inum, &error);
	if (error)
		error = hammer2_error_to_errno(error);
	else
		error = hammer2_dirent_create(dip,
		    (const char *)dentry->d_name.name,	/* Linux: u8 */
		    dentry->d_name.len, nip->meta.inum, nip->meta.type);
	if (error) {
		if (nip) {
			hammer2_inode_unlink_finisher(nip, NULL);
			hammer2_inode_unlock(nip);
			nip = NULL;
		}
	} else {
		hammer2_inode_depend(dip, nip); /* before igetv */
		error = hammer2_igetv(nip, 0, &inode);
		hammer2_inode_unlock(nip);
	}

	if (error == 0 && target != NULL) {
		error = page_symlink(inode, target, strlen(target) + 1);
		if (error) {
			iput(inode);
			inode = NULL;
		}
	}

	if (error == 0) {
		hammer2_update_time(&mtime);
		hammer2_inode_modify(dip);
		dip->meta.mtime = mtime;
		dip->meta.ctime = mtime;
		if (S_ISDIR(mode) && dip->meta.nlinks != 1)
			++dip->meta.nlinks;
		inode_set_mtime_to_ts(dir,
		    inode_set_ctime_current(dir));	/* Linux */
		if (S_ISDIR(mode))
			set_nlink(dir, dip->meta.nlinks);	/* Linux */
		d_instantiate(dentry, inode);		/* Linux */
	}
	hammer2_inode_unlock(dip);
	hammer2_trans_done(dip->pmp, HAMMER2_TRANS_SIDEQ);

	return (hammer2_vfs_errno(error));
}

static int
hammer2_vop_create(struct mnt_idmap *idmap, struct inode *dir,
    struct dentry *dentry, umode_t mode)
{
	return (hammer2_vop_ncreate(idmap, dir, dentry, mode | S_IFREG, 0,
	    NULL));
}

static int
hammer2_vop_mknod(struct mnt_idmap *idmap, struct inode *dir,
    struct dentry *dentry, umode_t mode, dev_t rdev)
{
	return (hammer2_vop_ncreate(idmap, dir, dentry, mode, rdev, NULL));
}

static struct dentry *
hammer2_vop_mkdir(struct mnt_idmap *idmap, struct inode *dir,
    struct dentry *dentry, umode_t mode)
{
	int error;

	error = hammer2_vop_ncreate(idmap, dir, dentry, mode | S_IFDIR, 0,
	    NULL);
	return (error ? ERR_PTR(error) : NULL);
}

static int
hammer2_vop_symlink(struct mnt_idmap *idmap, struct inode *dir,
    struct dentry *dentry, const char *target)
{
	return (hammer2_vop_ncreate(idmap, dir, dentry, S_IFLNK | 0777, 0,
	    target));
}

/*
 * Remove a name, which is upstream's hammer2_remove() and hammer2_rmdir()
 * with isdir telling them apart, as the unlink XOP already does.  The
 * XOP finds the entry by name and deletes it; hammer2_inode_get() on its
 * result is the inode the name pointed to, which is the dentry's, and
 * hammer2_inode_unlink_finisher() drops its link count and marks it
 * ISUNLINKED at zero, which hammer2_evict_inode() acts on when the VFS
 * lets go of it.  Linux has no chflags, so that check has no place
 * here, as at ->setattr.
 */
static int
hammer2_vop_nremove(struct inode *dir, struct dentry *dentry, int isdir)
{
	struct inode *inode = d_inode(dentry);
	hammer2_inode_t *dip = VTOI(dir);
	hammer2_inode_t *ip;
	hammer2_xop_unlink_t *xop;
	uint64_t mtime;
	int error;

	if (dip->pmp->rdonly)
		return (-EROFS);
	hammer2_pfs_memory_wait(dip->pmp);	/* Linux: hammer2_vfs_modifying() */
	if (hammer2_vfs_enospace(dip, 0, current_cred()) > 1)
		return (-ENOSPC);

	hammer2_trans_init(dip->pmp, 0);
	hammer2_inode_lock(dip, 0);

	xop = hammer2_xop_alloc(dip, HAMMER2_XOP_MODIFYING);
	hammer2_xop_setname(&xop->head,
	    (const char *)dentry->d_name.name,	/* Linux: u8 */
	    dentry->d_name.len);
	xop->isdir = isdir;
	xop->dopermanent = 0;
	hammer2_xop_start(&xop->head, &hammer2_unlink_desc);
	error = hammer2_xop_collect(&xop->head, 0);
	error = hammer2_error_to_errno(error);
	if (error == 0) {
		ip = hammer2_inode_get(dip->pmp, &xop->head, -1, -1);
		hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);
		if (ip) {
			KKASSERT(ip->vp == inode);
			hammer2_inode_unlink_finisher(ip, NULL);
			hammer2_inode_depend(dip, ip); /* after modified */
			hammer2_inode_unlock(ip);
		}
	} else {
		hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);
	}

	if (error == 0) {
		hammer2_update_time(&mtime);
		hammer2_inode_modify(dip);
		dip->meta.mtime = mtime;
		dip->meta.ctime = mtime;
		if (isdir && dip->meta.nlinks != 1)
			--dip->meta.nlinks;
		inode_set_mtime_to_ts(dir,
		    inode_set_ctime_current(dir));	/* Linux */
		inode_set_ctime_current(inode);		/* Linux */
		if (isdir) {
			set_nlink(dir, dip->meta.nlinks);	/* Linux */
			clear_nlink(inode);		/* Linux */
		} else {
			drop_nlink(inode);		/* Linux */
		}
	}
	hammer2_inode_unlock(dip);
	hammer2_trans_done(dip->pmp, HAMMER2_TRANS_SIDEQ);

	return (hammer2_vfs_errno(error));
}

static int
hammer2_vop_unlink(struct inode *dir, struct dentry *dentry)
{
	return (hammer2_vop_nremove(dir, dentry, 0));
}

static int
hammer2_vop_rmdir(struct inode *dir, struct dentry *dentry)
{
	return (hammer2_vop_nremove(dir, dentry, 1));
}

/*
 * Rename, which is upstream's hammer2_rename() from the transaction on.
 * Everything before it there is FreeBSD's vnode layer: the four vnodes
 * arrive unlocked and are relocked in an order that can fail and
 * restart, and the two names are resolved again in case they moved.
 * Linux calls ->rename with both directories and the target locked by
 * lock_rename(), and the dentries it passes are the resolution, so
 * none of that has a counterpart here.  What remains is upstream's: the
 * four inodes locked in address order, the target's collision space
 * scanned for a free hash, the nrename XOP, the moved inode's name and
 * parent updated, the replaced target's link dropped, and the two
 * directories' times and link counts adjusted.  The Linux inodes'
 * copies of the link counts and times move beside the meta.
 *
 * RENAME_NOREPLACE is what the VFS already checked; the other two flags
 * name operations upstream has no XOP for.
 */
static int
hammer2_vop_rename(struct mnt_idmap *idmap __maybe_unused,
    struct inode *fdir, struct dentry *fdentry, struct inode *tdir,
    struct dentry *tdentry, unsigned int flags)
{
	struct inode *finode = d_inode(fdentry);
	struct inode *tinode = d_inode(tdentry);
	hammer2_inode_t *fdip = VTOI(fdir); /* source directory */
	hammer2_inode_t *fip = VTOI(finode); /* file being renamed */
	hammer2_inode_t *tdip = VTOI(tdir); /* target directory */
	hammer2_inode_t *tip = tinode ? VTOI(tinode) : NULL; /* replaced */
	hammer2_inode_t *ip1, *ip2, *ip3, *ip4;
	hammer2_xop_scanlhc_t *sxop;
	hammer2_xop_nrename_t *xop4;
	hammer2_key_t tlhc, lhcbase;
	uint64_t mtime;
	int error, update_fdip = 0, update_tdip = 0;

	if (flags & ~RENAME_NOREPLACE)
		return (-EINVAL);
	if (fdip->pmp->rdonly || (fdip->pmp->flags & HAMMER2_PMPF_EMERG))
		return (-EROFS);
	hammer2_pfs_memory_wait(fdip->pmp);	/* Linux: hammer2_vfs_modifying() */
	if (hammer2_vfs_enospace(fdip, 0, current_cred()) > 1)
		return (-ENOSPC);
	if (tdentry->d_name.len > HAMMER2_INODE_MAXNAME)
		return (-ENAMETOOLONG);

	if (fip->meta.type == HAMMER2_OBJTYPE_DIRECTORY &&
	    fdip->meta.inum != tdip->meta.inum) {
		error = hammer2_checkpath(fip, tdip);
		if (error)
			return (hammer2_vfs_errno(error));
		if (tdip->meta.nlinks >= U32_MAX)	/* Linux */
			return (-EMLINK);
	}

	hammer2_trans_init(tdip->pmp, 0);
	hammer2_inode_ref(fip); /* extra ref */
	if (tip)
		hammer2_inode_ref(tip); /* extra ref */

	/*
	 * For now try to avoid deadlocks with a simple pointer address
	 * test.  (tip) can be NULL.
	 */
	ip1 = fdip;
	ip2 = tdip;
	ip3 = fip;
	ip4 = tip; /* may be NULL */

	if (fdip > tdip) {
		ip1 = tdip;
		ip2 = fdip;
	}
	if (tip && fip > tip) {
		ip3 = tip;
		ip4 = fip;
	}
	hammer2_inode_lock4(ip1, ip2, ip3, ip4);

	/*
	 * Resolve the collision space for (tdip, tname, tname_len).
	 *
	 * tdip must be held exclusively locked to prevent races since
	 * multiple filenames can end up in the same collision space.
	 */
	tlhc = hammer2_dirhash((const char *)tdentry->d_name.name,
	    tdentry->d_name.len);
	lhcbase = tlhc;
	sxop = hammer2_xop_alloc(tdip, HAMMER2_XOP_MODIFYING);
	sxop->lhc = tlhc;
	hammer2_xop_start(&sxop->head, &hammer2_scanlhc_desc);
	while ((error = hammer2_xop_collect(&sxop->head, 0)) == 0) {
		if (tlhc != sxop->head.cluster.focus->bref.key)
			break;
		++tlhc;
	}
	error = hammer2_error_to_errno(error);
	hammer2_xop_retire(&sxop->head, HAMMER2_XOPMASK_VOP);
	if (error) {
		if (error != ENOENT)
			goto done;
		++tlhc;
		error = 0;
	}
	if ((lhcbase ^ tlhc) & ~HAMMER2_DIRHASH_LOMASK) {
		error = ENOSPC;
		goto done;
	}

	/*
	 * Ready to go, issue the rename to the backend.  Note that meta-data
	 * updates to the related inodes occur separately from the rename
	 * operation.  ip1|2|3|4 are fdip, fip, tdip, tip in this order.
	 *
	 * NOTE: While it is not necessary to update ip->meta.name*, doing
	 *	 so aids catastrophic recovery and debugging.
	 */
	if (error == 0) {
		xop4 = hammer2_xop_alloc(fdip, HAMMER2_XOP_MODIFYING);
		xop4->lhc = tlhc;
		xop4->ip_key = fip->meta.name_key;
		hammer2_xop_setip2(&xop4->head, fip);
		hammer2_xop_setip3(&xop4->head, tdip);
		if (tip && tip->meta.type == HAMMER2_OBJTYPE_DIRECTORY)
			hammer2_xop_setip4(&xop4->head, tip);
		hammer2_xop_setname(&xop4->head,
		    (const char *)fdentry->d_name.name, fdentry->d_name.len);
		hammer2_xop_setname2(&xop4->head,
		    (const char *)tdentry->d_name.name, tdentry->d_name.len);
		hammer2_xop_start(&xop4->head, &hammer2_nrename_desc);
		error = hammer2_xop_collect(&xop4->head, 0);
		error = hammer2_error_to_errno(error);
		hammer2_xop_retire(&xop4->head, HAMMER2_XOPMASK_VOP);
		if (error == ENOENT)
			error = 0;
		/*
		 * Update inode meta-data.
		 *
		 * WARNING!  The in-memory inode (ip) structure does not
		 *	     maintain a copy of the inode's filename buffer.
		 */
		if (error == 0 &&
		    (fip->meta.name_key & HAMMER2_DIRHASH_VISIBLE)) {
			hammer2_inode_modify(fip);
			fip->meta.name_len = tdentry->d_name.len;
			fip->meta.name_key = tlhc;
		}
		if (error == 0) {
			hammer2_inode_modify(fip);
			fip->meta.iparent = tdip->meta.inum;
		}
		update_fdip = 1;
		update_tdip = 1;
	}
done:
	/*
	 * If no error, the backend has replaced the target directory entry.
	 * We must adjust nlinks on the original replace target if it exists.
	 */
	if (error == 0 && tip) {
		hammer2_inode_unlink_finisher(tip, NULL);
		if (tip->meta.type == HAMMER2_OBJTYPE_DIRECTORY)
			clear_nlink(tinode);		/* Linux */
		else
			drop_nlink(tinode);		/* Linux */
	}

	/* Update directory mtimes to represent the something changed. */
	if (update_fdip || update_tdip) {
		hammer2_update_time(&mtime);
		if (update_fdip) {
			hammer2_inode_modify(fdip);
			fdip->meta.mtime = mtime;
			if (fip->meta.type == HAMMER2_OBJTYPE_DIRECTORY &&
			    fdip->meta.nlinks != 1)
				--fdip->meta.nlinks;
		}
		if (update_tdip) {
			hammer2_inode_modify(tdip);
			tdip->meta.mtime = mtime;
			if (fip->meta.type == HAMMER2_OBJTYPE_DIRECTORY &&
			    tdip->meta.nlinks != 1)
				++tdip->meta.nlinks;
		}
	}
	if (error == 0) {
		/* Linux: the VFS inodes' copies of the above. */
		inode_set_mtime_to_ts(fdir, inode_set_ctime_current(fdir));
		inode_set_mtime_to_ts(tdir, inode_set_ctime_current(tdir));
		inode_set_ctime_current(finode);
		if (tinode)
			inode_set_ctime_current(tinode);
		if (S_ISDIR(finode->i_mode) && fdir != tdir) {
			set_nlink(fdir, fdip->meta.nlinks);
			set_nlink(tdir, tdip->meta.nlinks);
		}
	}
	if (tip) {
		hammer2_inode_unlock(tip);
		hammer2_inode_drop(tip);
	}
	hammer2_inode_unlock(fip);
	hammer2_inode_unlock(tdip);
	hammer2_inode_unlock(fdip);
	hammer2_inode_drop(fip);
	hammer2_trans_done(tdip->pmp, HAMMER2_TRANS_SIDEQ);

	return (hammer2_vfs_errno(error));
}

/*
 * Hard link, which is upstream's hammer2_link(): a directory entry
 * naming the inode, its link count bumped, the times updated.  The
 * target must be an indexed inode, as every inode this port creates is
 * and every inode DragonFly writes has been since the hardlink rewrite;
 * upstream asserts it, and here it is an error, since the media is the
 * source of the claim.  The Linux inode takes a reference for the new
 * dentry, as every filesystem's ->link does.
 */
static int
hammer2_vop_link(struct dentry *odentry, struct inode *dir,
    struct dentry *dentry)
{
	struct inode *inode = d_inode(odentry);
	hammer2_inode_t *tdip = VTOI(dir); /* target directory */
	hammer2_inode_t *ip = VTOI(inode); /* inode we are hardlinking to */
	uint64_t cmtime;
	int error;

	if (ip->meta.nlinks >= U32_MAX)	/* Linux */
		return (-EMLINK);
	hammer2_pfs_memory_wait(tdip->pmp);	/* Linux: hammer2_vfs_modifying() */
	if (hammer2_vfs_enospace(tdip, 0, current_cred()) > 1)
		return (-ENOSPC);
	if (tdip->pmp->rdonly || (tdip->pmp->flags & HAMMER2_PMPF_EMERG))
		return (-EROFS);
	if (dentry->d_name.len > HAMMER2_INODE_MAXNAME)
		return (-ENAMETOOLONG);
	if (ip->meta.name_key & HAMMER2_DIRHASH_VISIBLE) {
		WARN_ONCE(1, "hammer2: link to an unindexed inode %016llx\n",
		    (long long)ip->meta.inum);
		return (-EOPNOTSUPP);
	}

	KKASSERT(ip->pmp);
	hammer2_trans_init(ip->pmp, 0);

	hammer2_inode_lock4(tdip, ip, NULL, NULL);
	hammer2_update_time(&cmtime);

	/*
	 * Create the directory entry and bump nlinks.
	 * Also update ip's ctime.
	 */
	error = hammer2_dirent_create(tdip, (const char *)dentry->d_name.name,
	    dentry->d_name.len, ip->meta.inum, ip->meta.type);
	hammer2_inode_modify(ip);
	++ip->meta.nlinks;
	ip->meta.ctime = cmtime;

	if (error == 0) {
		/* Update dip's [cm]time. */
		hammer2_inode_modify(tdip);
		tdip->meta.mtime = cmtime;
		tdip->meta.ctime = cmtime;
	}
	hammer2_inode_unlock(ip);
	hammer2_inode_unlock(tdip);

	hammer2_trans_done(ip->pmp, HAMMER2_TRANS_SIDEQ);

	if (error == 0) {
		/* Linux */
		inode_set_ctime_current(inode);
		inode_set_mtime_to_ts(dir, inode_set_ctime_current(dir));
		inc_nlink(inode);
		ihold(inode);
		d_instantiate(dentry, inode);
	}
	return (hammer2_vfs_errno(error));
}

const struct inode_operations hammer2_dir_iops = {
	.lookup		= hammer2_vop_lookup,
	.create		= hammer2_vop_create,
	.mknod		= hammer2_vop_mknod,
	.mkdir		= hammer2_vop_mkdir,
	.symlink	= hammer2_vop_symlink,
	.unlink		= hammer2_vop_unlink,
	.rmdir		= hammer2_vop_rmdir,
	.rename		= hammer2_vop_rename,
	.link		= hammer2_vop_link,
	.setattr	= hammer2_vop_setattr,
};

/*
 * THE FILE OPERATIONS ARE NOT OPTIONAL, WHICH IS NOT OBVIOUS FROM THE
 * INODE OPERATIONS BEING THE HALF THAT MATTERS HERE.  do_dentry_open()
 * in fs/open.c reads i_fop straight out of the inode and takes a NULL
 * through WARN_ON before failing the open with ENODEV, at v6.15 as at
 * v7.2.  So an inode handed to the VFS with no file_operations does not
 * refuse an open quietly, it prints a kernel warning first, and the
 * first `ls` on a mount point would produce one.  These two tables exist
 * so that never happens; what is deferred is what is in them.
 *
 * The regular-file table gained ->read_iter and the mapping gained
 * ->read_folio when the read path landed, so a read reaches the media.
 *
 * generic_file_llseek() permits a seek to a position that is not a valid
 * directory key, which then starts the scan at the next key above it and
 * skips entries.  DragonFly carries the same exposure, since a cookie is
 * a hash and not an index in both, so this matches it rather than
 * inventing a check the core does not make.
 */
/*
 * Linux: the ioctl entry.  FreeBSD's hammer2_ioctl() hands the command
 * to hammer2_ioctl_impl() with the argument already copied in by the
 * syscall layer; here the copy is this function's, sized by the command
 * word, and the result copied back for a command that reads.  The
 * privilege rule is DragonFly's: every command wants root except
 * HAMMER2IOC_VERSION_GET and HAMMER2IOC_INODE_GET, which any user may
 * issue, and HAMMER2IOC_BULKFREE_SCAN, which DragonFly leaves open too.
 * The FreeBSD port checks nothing, and a snapshot or a PFS deletion is
 * not an operation to hand to every user with a file open.
 */
static long
hammer2_ioctl(struct file *file, unsigned int cmd, unsigned long arg)
{
	void *data;
	unsigned int size = _IOC_SIZE(cmd);
	int error;

	if (_IOC_TYPE(cmd) != 'h')
		return (-ENOTTY);
	switch (cmd) {
	case HAMMER2IOC_VERSION_GET:
	case HAMMER2IOC_INODE_GET:
	case HAMMER2IOC_BULKFREE_SCAN:
		break;
	default:
		if (!capable(CAP_SYS_ADMIN))
			return (-EPERM);
	}
	if (size == 0)	/* the command word bounds it at 16 KiB */
		return (-EINVAL);
	data = kzalloc(size, GFP_KERNEL);
	if (data == NULL)
		return (-ENOMEM);
	if ((_IOC_DIR(cmd) & _IOC_WRITE) &&
	    copy_from_user(data, (void __user *)arg, size)) {
		kfree(data);
		return (-EFAULT);
	}
	error = hammer2_ioctl_impl(file_inode(file), cmd, data, file->f_flags,
	    file->f_cred);
	if (error == 0 && (_IOC_DIR(cmd) & _IOC_READ) &&
	    copy_to_user((void __user *)arg, data, size))
		error = EFAULT;
	kfree(data);
	return (hammer2_vfs_errno(error));
}

const struct file_operations hammer2_dir_fops = {
	.llseek		= generic_file_llseek,
	.read		= generic_read_dir,
	.iterate_shared	= hammer2_vop_readdir,
	.unlocked_ioctl	= hammer2_ioctl,		/* Linux */
};

/*
 * Linux: dirty pages on a device, across every writeback it carries.
 * Under cgroup writeback the superblock's own writeback is the root
 * cgroup's alone, and a writer in any other cgroup dirties pages the
 * root's counter never sees; the walk is the one the kernel's own
 * accounting makes.
 */
static loff_t
hammer2_bdi_dirty_bytes(struct backing_dev_info *bdi)
{
	struct bdi_writeback *wb;
	s64 pages = 0;

	rcu_read_lock();
	list_for_each_entry_rcu(wb, &bdi->wb_list, bdi_node) {
		if (!wb_tryget(wb))
			continue;
		pages += wb_stat(wb, WB_RECLAIMABLE);
		wb_put(wb);
	}
	rcu_read_unlock();
	return ((loff_t)pages << PAGE_SHIFT);
}

/*
 * A regular file reads through the page cache.  ->read_iter is what sets
 * FMODE_CAN_READ in do_dentry_open(): without it an open succeeds and
 * every read fails EINVAL whatever the address space can do, which is the
 * state this table recorded until the read path landed.
 */
/*
 * A buffered write, which is upstream's hammer2_write() and
 * hammer2_write_file() with the copy loop handed to the page cache.
 * Upstream wraps the write in a transaction so the size change and the
 * inode modify inside it are ordered against a flush, and closes it with
 * SIDEQ so the inode reaches the sync queue; the same here, around the
 * generic writer, whose ->write_begin and ->write_end below do the per
 * block work.  The mtime and the modify after a successful write are
 * upstream's, from the end of hammer2_write_file().
 */
static ssize_t
hammer2_file_write_iter(struct kiocb *iocb, struct iov_iter *from)
{
	struct inode *inode = file_inode(iocb->ki_filp);
	hammer2_inode_t *ip = VTOI(inode);
	uint64_t mtime;
	ssize_t ret;

	if (ip->pmp->rdonly)
		return (-EROFS);
	/*
	 * XXX Linux: upstream's case 1, under twice the reserve, makes the
	 * write semi-synchronous with IO_DIRECT.  A data-sync write is the
	 * page cache's form of it: the write goes through ->fsync before
	 * it returns, so the strategy allocates the blocks now and the
	 * free count the refusal reads stays current.  Without it the page
	 * cache accepted 511 files of a fill the free count saw nothing of
	 * until the flush, and 37 of them were lost.
	 */
	/*
	 * XXX Linux: the free count moves when a block is allocated, and
	 * the page cache holds what write(2) accepted until writeback
	 * allocates it, so a write is judged with everything dirty on this
	 * device counted against the reserve as well as itself.  Without
	 * that, fifteen files of a fill were still lost to a flush that
	 * found the reserve already eaten by data the count had not seen.
	 */
	hammer2_pfs_memory_wait(ip->pmp);	/* Linux: hammer2_vfs_modifying() */
	switch (hammer2_vfs_enospace(ip, iov_iter_count(from) +
	    hammer2_bdi_dirty_bytes(inode->i_sb->s_bdi), current_cred())) {
	case 2:
		return (-ENOSPC);
	case 1:
		iocb->ki_flags |= IOCB_DSYNC;
		break;
	default:
		break;
	}
	hammer2_trans_init(ip->pmp, 0);
	ret = generic_file_write_iter(iocb, from);
	if (ret > 0) {
		hammer2_update_time(&mtime);
		hammer2_mtx_ex(&ip->lock);
		hammer2_inode_modify(ip);
		ip->meta.mtime = mtime;
		hammer2_mtx_unlock(&ip->lock);
	}
	hammer2_trans_done(ip->pmp, HAMMER2_TRANS_SIDEQ);
	return (ret);
}

/*
 * Zero the cached tail of the block that holds byte off, from off to the
 * end of the folio, and dirty it so the zeros reach the disk.  This is
 * what nvtruncbuf() and nvextendbuf() do for upstream in the buffer
 * cache: a block is stored whole, so the bytes past a shrunken end stay
 * on the media until something overwrites them, and a later extend would
 * read them back as file data.  Runs outside ip->lock, since the read it
 * may take goes through ->read_folio, which takes that lock shared.
 */
static int
hammer2_zero_tail(struct inode *inode, loff_t off)
{
	struct folio *folio;

	if (off == 0 || (off & HAMMER2_PBUFMASK64) == 0)
		return (0);
	folio = read_mapping_folio(inode->i_mapping, off >> PAGE_SHIFT, NULL);
	if (IS_ERR(folio))
		return (PTR_ERR(folio));
	folio_lock(folio);
	if (off < folio_pos(folio) + folio_size(folio))
		folio_zero_segment(folio, offset_in_folio(folio, off),
		    folio_size(folio));
	folio_mark_dirty(folio);
	folio_unlock(folio);
	folio_put(folio);
	return (0);
}

/*
 * Truncate the file to nsize, which is upstream's hammer2_truncate_file()
 * with the buffer cache part taken out: the caller has already run
 * truncate_setsize() and hammer2_zero_tail() before taking ip->lock,
 * where upstream drops and retakes ip->lock around vtruncbuf() under
 * truncate_lock.  That retake is the reverse of the order every other
 * path takes the two locks in, and lockdep reported it as such on the
 * first truncate here.  What remains records the old and new sizes under
 * RESIZED so the chain sync that follows deletes the data chains past
 * the new end.
 */
static void
hammer2_truncate_file(hammer2_inode_t *ip, hammer2_key_t nsize)
{
	hammer2_mtx_assert_locked(&ip->lock);

	KKASSERT((ip->flags & HAMMER2_INODE_RESIZED) == 0);
	ip->osize = ip->meta.size;
	ip->meta.size = nsize;
	atomic_set_int(&ip->flags, HAMMER2_INODE_RESIZED);
	hammer2_inode_modify(ip);
}

/*
 * Extend the file to nsize without writing, which is upstream's
 * hammer2_extend_file() with writing == 0, and with the page cache part
 * taken out as above.  Crossing the embedded size takes the chain sync
 * now, for the reason upstream gives: the flush code and the in-memory
 * state must agree on DIRECTDATA.
 */
static void
hammer2_extend_file(hammer2_inode_t *ip, hammer2_key_t nsize)
{
	hammer2_key_t osize;

	hammer2_mtx_assert_locked(&ip->lock);

	KKASSERT((ip->flags & HAMMER2_INODE_RESIZED) == 0);
	osize = ip->meta.size;

	hammer2_inode_modify(ip);
	ip->osize = osize;
	ip->meta.size = nsize;
	if (osize <= HAMMER2_EMBEDDED_BYTES && nsize > HAMMER2_EMBEDDED_BYTES) {
		atomic_set_int(&ip->flags, HAMMER2_INODE_RESIZED);
		hammer2_inode_chain_sync(ip);
	}
}

/*
 * Set attributes, which is upstream's hammer2_setattr() with the
 * permission checks handed to setattr_prepare() and the attribute copy
 * to setattr_copy(), as every Linux filesystem does; what remains is
 * the size change and copying the result into ip->meta so the flush
 * writes it.  The uflags branch is not carried: Linux has no chflags
 * through setattr.  A truncation takes the chain sync before the
 * transaction closes, for the reason upstream gives at its done label.
 */
static int
hammer2_vop_setattr(struct mnt_idmap *idmap, struct dentry *dentry,
    struct iattr *attr)
{
	struct inode *inode = d_inode(dentry);
	hammer2_inode_t *ip = VTOI(inode);
	struct timespec64 ts;
	uint64_t ctime;
	int error, resize;

	if (ip->pmp->rdonly)
		return (-EROFS);
	/*
	 * Normally disallow setattr if there is no space, unless we
	 * are in emergency mode (might be needed to chflags -R noschg
	 * files prior to removal).
	 */
	hammer2_pfs_memory_wait(ip->pmp);	/* Linux: hammer2_vfs_modifying() */
	if ((ip->pmp->flags & HAMMER2_PMPF_EMERG) == 0 &&
	    hammer2_vfs_enospace(ip, 0, current_cred()) > 1)
		return (-ENOSPC);
	error = setattr_prepare(idmap, dentry, attr);
	if (error)
		return (error);

	/*
	 * Linux: the page cache side of a size change, under the i_rwsem
	 * the VFS holds for the call, before ip->lock.  The order of the
	 * two locks is what keeps the tail zeroing off ip->lock.
	 */
	resize = (attr->ia_valid & ATTR_SIZE) &&
	    attr->ia_size != i_size_read(inode);
	if (resize) {
		if (!S_ISREG(inode->i_mode))
			return (-EINVAL);
		if (attr->ia_size < i_size_read(inode)) {
			truncate_setsize(inode, attr->ia_size);
			error = hammer2_zero_tail(inode, attr->ia_size);
		} else {
			error = hammer2_zero_tail(inode, i_size_read(inode));
			truncate_setsize(inode, attr->ia_size);
		}
		if (error)
			return (error);
	}

	hammer2_trans_init(ip->pmp, 0);
	hammer2_inode_lock(ip, 0);

	if (resize) {
		if (attr->ia_size < ip->meta.size) {
			hammer2_mtx_ex(&ip->truncate_lock);
			hammer2_truncate_file(ip, attr->ia_size);
			hammer2_mtx_unlock(&ip->truncate_lock);
		} else {
			hammer2_extend_file(ip, attr->ia_size);
		}
		hammer2_update_time(&ctime);
		hammer2_inode_modify(ip);
		ip->meta.ctime = ctime;
		ip->meta.mtime = ctime;
	}

	setattr_copy(idmap, inode, attr);
	hammer2_inode_modify(ip);
	if (attr->ia_valid & ATTR_MODE)
		ip->meta.mode = inode->i_mode & 07777;
	if (attr->ia_valid & ATTR_UID)
		hammer2_guid_to_uuid(&ip->meta.uid, i_uid_read(inode));
	if (attr->ia_valid & ATTR_GID)
		hammer2_guid_to_uuid(&ip->meta.gid, i_gid_read(inode));
	if (attr->ia_valid & ATTR_ATIME) {
		ts = inode_get_atime(inode);
		ip->meta.atime = hammer2_timespec_to_time(&ts);
	}
	if (attr->ia_valid & ATTR_MTIME) {
		ts = inode_get_mtime(inode);
		ip->meta.mtime = hammer2_timespec_to_time(&ts);
	}
	ts = inode_get_ctime(inode);
	ip->meta.ctime = hammer2_timespec_to_time(&ts);

	if (ip->flags & HAMMER2_INODE_RESIZED)
		hammer2_inode_chain_sync(ip);
	hammer2_inode_unlock(ip);
	hammer2_trans_done(ip->pmp, HAMMER2_TRANS_SIDEQ);
	return (error);
}

/*
 * fsync, which is upstream's hammer2_fsync(): write the file's dirty
 * data first, so the strategy XOPs have assigned its blocks, then sync
 * the inode's meta-data if it changed and flush the chains under it.
 * vop_stdfsync() is file_write_and_wait_range() here.  As upstream says,
 * this is not a flush transaction; the inode stays on the sideq and the
 * syncer carries it to the volume root.
 */
static int
hammer2_vop_fsync(struct file *file, loff_t start, loff_t end,
    int datasync __maybe_unused)
{
	struct inode *inode = file_inode(file);
	hammer2_inode_t *ip = VTOI(inode);
	int error1 = 0, error2;

	if (ip->pmp->rdonly)
		return (0);
	hammer2_trans_init(ip->pmp, 0);

	error1 = file_write_and_wait_range(file, start, end);	/* Linux */

	hammer2_inode_lock(ip, 0);
	if (ip->flags & (HAMMER2_INODE_RESIZED | HAMMER2_INODE_MODIFIED))
		error1 = error1 ? error1 :
		    hammer2_vfs_errno(hammer2_inode_chain_sync(ip));
	error2 = hammer2_vfs_errno(hammer2_inode_chain_flush(ip,
	    HAMMER2_XOP_INODE_STOP));
	if (error2)
		error1 = error2;
	hammer2_inode_unlock(ip);
	hammer2_trans_done(ip->pmp, 0);
	return (error1);
}

/*
 * Linux: without ->mmap_prepare a file on this filesystem cannot be
 * mapped, and so cannot be executed: the ELF loader maps the segments it
 * is given and the mapping is what fails, which surfaces as ENOEXEC on a
 * binary whose bytes read back byte for byte correct.  Measured before
 * this line existed: /bin/true copied onto a HAMMER2 volume compared
 * identical with cmp and refused to run, while the same file copied off
 * it onto tmpfs ran.  Shared libraries were the same defect and are
 * measured too: the loader run out of a volume, given a library path
 * into it, maps every library from HAMMER2 and exits 0.
 *
 * generic_file_mmap_prepare() wants ->read_folio, which the mapping has,
 * and installs generic_file_vm_ops, whose write fault dirties a folio
 * that filemap_fault() has already brought uptodate through that same
 * ->read_folio and leaves ->writepages to write it.  That is what ext2,
 * fat, jfs and hpfs use unchanged.  ext4 and xfs do not: they wrap it to
 * install a ->page_mkwrite of their own, which reserves space while the
 * faulting thread can still be told the answer.  Here the allocation
 * happens in the strategy XOP at writeback, so a mapping dirtied on a
 * full volume failed where nothing was left to report it to, until the
 * write fault below learned to refuse.  ->mmap_prepare rather than ->mmap because the kernel of
 * record takes either and the in-tree filesystems have moved; fs.h warns
 * when a table sets both.
 */
/*
 * Linux: the write fault asks the reserve check the write entry asks,
 * with the folio it is about to dirty as the size, and answers a
 * refusal with SIGBUS as ext4 does when it cannot allocate at the
 * fault.  The freemap cannot reserve at fault time; what it can do is
 * refuse, and a mapped write on a full volume was accepted, synced and
 * read back with nothing asked while write(2) beside it was refused,
 * so a mapping could take the whole reserve the flush needs.  Any
 * other cgroup's dirty pages are counted as the write entry counts
 * them.
 */
static vm_fault_t
hammer2_page_mkwrite(struct vm_fault *vmf)
{
	struct inode *inode = file_inode(vmf->vma->vm_file);
	hammer2_inode_t *ip = VTOI(inode);

	if (ip->pmp->rdonly)
		return (VM_FAULT_SIGBUS);
	hammer2_pfs_memory_wait(ip->pmp);	/* Linux: hammer2_vfs_modifying() */
	if (hammer2_vfs_enospace(ip, folio_size(page_folio(vmf->page)) +
	    hammer2_bdi_dirty_bytes(inode->i_sb->s_bdi), current_cred()) > 1)
		return (VM_FAULT_SIGBUS);
	return (filemap_page_mkwrite(vmf));
}

static const struct vm_operations_struct hammer2_file_vm_ops = {
	.fault		= filemap_fault,
	.map_pages	= filemap_map_pages,
	.page_mkwrite	= hammer2_page_mkwrite,
};

static int
hammer2_file_mmap_prepare(struct vm_area_desc *desc)
{
	int error;

	error = generic_file_mmap_prepare(desc);
	if (error)
		return (error);
	desc->vm_ops = &hammer2_file_vm_ops;
	return (0);
}

const struct file_operations hammer2_file_fops = {
	.llseek		= generic_file_llseek,
	.read_iter	= generic_file_read_iter,
	.write_iter	= hammer2_file_write_iter,	/* Linux */
	.mmap_prepare	= hammer2_file_mmap_prepare,	/* Linux */
	.fsync		= hammer2_vop_fsync,
	.unlocked_ioctl	= hammer2_ioctl,		/* Linux */
};

/*
 * Prepare one folio for a write.  The folio is a whole logical block, so
 * this is upstream's per-block choice in hammer2_write_file(): a write
 * that covers the block needs nothing read, a block past the end of the
 * file is zero, and a partial overwrite reads the block first, which
 * upstream does with bread() and this does with ->read_folio on the
 * folio it will then hand back locked.
 */
static int
hammer2_write_begin(const struct kiocb *iocb,
    struct address_space *mapping, loff_t pos, unsigned int len,
    struct folio **foliop, void **fsdata __maybe_unused)
{
	struct inode *inode = mapping->host;
	struct folio *folio;
	int error;

	/*
	 * The mapping's folio order is pinned to the block, so the order
	 * the helper derives from len cannot exceed it; what the helper
	 * adds is the uncached flag when the iocb carries it.
	 */
	folio = write_begin_get_folio(iocb, mapping, pos >> PAGE_SHIFT, len);
	if (IS_ERR(folio))
		return (PTR_ERR(folio));

	if (!folio_test_uptodate(folio)) {
		if (pos == folio_pos(folio) && len >= folio_size(folio)) {
			/* Covered entirely by the write; nothing to read. */
		} else if (folio_pos(folio) >= i_size_read(inode)) {
			folio_zero_range(folio, 0, folio_size(folio));
			folio_mark_uptodate(folio);
		} else {
			error = mapping->a_ops->read_folio(NULL, folio);
			if (error) {
				folio_put(folio);
				return (error);
			}
			folio_lock(folio);
			if (folio->mapping != mapping ||
			    !folio_test_uptodate(folio)) {
				folio_unlock(folio);
				folio_put(folio);
				return (folio->mapping != mapping ?
				    -EAGAIN : -EIO);
			}
		}
	}
	*foliop = folio;
	return (0);
}

/*
 * Finish one folio's write: mark it dirty, extend the file if the write
 * reached past its end, the way hammer2_extend_file() does, and note
 * that the inode has dirty data so the flush code waits for it.
 *
 * A folio that was not read because the write was to cover it stays not
 * uptodate if the copy came up short, and the caller retries with the
 * data faulted in; that is the generic writer's contract.
 *
 * The extend takes ip->lock under the folio lock, which is the order the
 * read path already uses in hammer2_read_folio().  Crossing the embedded
 * size is upstream's RESIZED plus chain sync, inside the transaction the
 * write iterator opened.
 */
static int
hammer2_write_end(const struct kiocb *iocb __maybe_unused,
    struct address_space *mapping, loff_t pos, unsigned int len,
    unsigned int copied, struct folio *folio, void *fsdata __maybe_unused)
{
	struct inode *inode = mapping->host;
	hammer2_inode_t *ip = VTOI(inode);
	loff_t end = pos + copied;

	if (!folio_test_uptodate(folio)) {
		if (copied < len)
			copied = 0;
		else
			folio_mark_uptodate(folio);
	}
	if (copied) {
		folio_mark_dirty(folio);
		if (end > i_size_read(inode)) {
			hammer2_mtx_ex(&ip->lock);
			hammer2_inode_modify(ip);
			ip->osize = ip->meta.size;
			ip->meta.size = end;
			if (ip->osize <= HAMMER2_EMBEDDED_BYTES &&
			    end > HAMMER2_EMBEDDED_BYTES) {
				atomic_set_int(&ip->flags, HAMMER2_INODE_RESIZED);
				hammer2_inode_chain_sync(ip);
			}
			hammer2_mtx_unlock(&ip->lock);
			i_size_write(inode, end);
		}
		atomic_set_int(&ip->flags, HAMMER2_INODE_DIRTYDATA);
	}
	folio_unlock(folio);
	folio_put(folio);
	return (copied);
}

/*
 * Write back dirty folios, one strategy XOP per block, which is what the
 * BSD ports' hammer2_strategy_write() does per buffer: mark the inode
 * DIRTYDATA, open a BUFCACHE transaction, start a MODIFYING|STRATEGY xop
 * with the folio and its position.  The xop ends the folio's writeback
 * and closes the transaction, as upstream's does.  XOPs run synchronously
 * in this port, so each folio's write is complete when the loop moves on.
 */
static int
hammer2_writepages(struct address_space *mapping,
    struct writeback_control *wbc)
{
	hammer2_inode_t *ip = VTOI(mapping->host);
	hammer2_xop_strategy_t *xop;
	struct folio *folio = NULL;
	int error = 0;

	while ((folio = writeback_iter(mapping, wbc, folio, &error)) != NULL) {
		folio_start_writeback(folio);
		folio_unlock(folio);

		atomic_set_int(&ip->flags, HAMMER2_INODE_DIRTYDATA);
		hammer2_trans_assert_strategy(ip->pmp);
		hammer2_trans_init(ip->pmp, HAMMER2_TRANS_BUFCACHE);
		xop = hammer2_xop_alloc(ip,
		    HAMMER2_XOP_MODIFYING | HAMMER2_XOP_STRATEGY);
		xop->folio = folio;
		xop->lbase = folio_pos(folio);
		hammer2_xop_start(&xop->head, &hammer2_strategy_write_desc);
		hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);
		error = 0;
	}
	return (error);
}

/*
 * There is no ->invalidate_folio because no folio carries private data.
 * For the same reason ->migrate_folio is the kernel's own, as in xfs:
 * without it every folio of a mapping with ->writepages is refused to
 * compaction with a warning from mm/migrate.c, once per boot.
 */
const struct address_space_operations hammer2_file_aops = {
	.read_folio	= hammer2_read_folio,
	.dirty_folio	= filemap_dirty_folio,		/* Linux */
	.write_begin	= hammer2_write_begin,		/* Linux */
	.write_end	= hammer2_write_end,		/* Linux */
	.writepages	= hammer2_writepages,		/* Linux */
	.migrate_folio	= filemap_migrate_folio,	/* Linux */
};

/*
 * A regular file's inode operations.  The VFS reads size, mode, owner
 * and times out of the inode itself, which hammer2_igetv() fills, so
 * stat needs nothing here; setting them, and the size, is ->setattr.
 */
const struct inode_operations hammer2_file_iops = {
	.setattr	= hammer2_vop_setattr,
};

/*
 * A symlink's target is its file data, the first HAMMER2_EMBEDDED_BYTES
 * of it in the inode and the rest in data blocks, and every port reads
 * it that way: hammer2_vop_readlink() calls hammer2_read_file(), as the
 * NetBSD port's hammer2_readlink() does.  On Linux that is page_get_link()
 * over the same ->read_folio a regular file uses, so the symlink carries
 * the file mapping and the inode is marked nohighmem, which
 * page_get_link() asserts.
 */
const struct inode_operations hammer2_symlink_iops = {
	.get_link	= page_get_link,
	.setattr	= hammer2_vop_setattr,
};
