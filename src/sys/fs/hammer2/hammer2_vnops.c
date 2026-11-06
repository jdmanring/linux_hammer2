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
#include <linux/falloc.h>	/* Linux: FALLOC_FL_MODE_MASK, fallocate(2) */
#include <linux/folio_batch.h>	/* Linux: the siblings of a split block */
#include <linux/fiemap.h>	/* Linux: fiemap_prep, fiemap_fill_next_extent */
#include <linux/filelock.h>	/* Linux: generic_setlease */
#include <linux/dirent.h>	/* Linux: linux_dirent64, the readdir budget */

/*
 * Linux: the smallest entry getdents64(2) writes, the header up to the
 * name plus a one-byte name and its NUL, rounded as the kernel rounds it,
 * so a buffer of n bytes holds at most n / HAMMER2_DIRENT64_MIN entries;
 * HAMMER2_READDIR_NMAX (hammer2.h) bounds what is fed past the buffer's
 * end.  See hammer2_vop_readdir().
 */
#define HAMMER2_DIRENT64_MIN \
	ALIGN(offsetof(struct linux_dirent64, d_name) + 2, sizeof(u64))

static int hammer2_vop_setattr(struct mnt_idmap *, struct dentry *,
    struct iattr *);
static int hammer2_zero_tail(struct inode *, loff_t);	/* Linux */

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
	hammer2_key_t lkey, rkey;
	size_t room, per;
	int dtype, error, nmax, emitted = 0;
	bool more;

	if (!dir_emit_dots(file, ctx))
		return (0);	/* Linux: not an error, the buffer is full */

	hammer2_inode_lock(ip, HAMMER2_RESOLVE_SHARED);

	/*
	 * Linux: one XOP per chunk of what the caller's buffer holds, rather
	 * than one per directory.  The backend runs in this thread, so
	 * nothing drains its FIFO while it feeds, and a scan to the end
	 * walked every entry past the position on every call; it now feeds
	 * nmax entries and leaves in rkey the key it stopped before,
	 * HAMMER2_KEY_MAX when it reached the end, and the next XOP starts
	 * there.  nmax comes from ctx->count, the space left in the caller's
	 * buffer, which the kernel of record offers as a hint and the actor
	 * draws down as it emits: the first chunk assumes the smallest entry
	 * there is, each later one the mean size of the entries this call
	 * has emitted, and both are capped, since a 32 KiB buffer asks for
	 * 1365 of the smallest entries and holds a third as many real ones,
	 * and every entry fed past the buffer's end is a chain allocated for
	 * nothing.  A caller that passes no hint gets a FIFO's worth,
	 * doubled each time its buffer outlasts a chunk; the hint's third
	 * value, INT_MAX for unlimited, is answered by the cap.  An entry at
	 * or past rkey is one some element has not fed, so it waits for that
	 * next XOP rather than being emitted from the elements that did.
	 * hammer2_xop_readdir() has the cost this replaces.
	 */
	room = ctx->count;	/* 0 when the caller says nothing */
	nmax = room ? clamp_t(size_t, room / HAMMER2_DIRENT64_MIN, 1,
	    HAMMER2_READDIR_NMAX) : HAMMER2_XOPFIFO - 1;
	lkey = ctx->pos | HAMMER2_DIRHASH_VISIBLE;
	do {
		xop = hammer2_xop_alloc(ip, 0);
		xop->lkey = lkey;
		xop->rkey = HAMMER2_KEY_MAX;
		xop->nmax = nmax;
		hammer2_xop_start(&xop->head, &hammer2_readdir_desc);
		rkey = xop->rkey;
		more = true;

		for (;;) {
			const hammer2_inode_data_t *ripdata;
			const char *dname;
			uint16_t namlen;
			bool ok = true;

			error = hammer2_error_to_errno(hammer2_xop_collect(&xop->head,
			    0));
			if (error)
				break;
			hammer2_cluster_bref(&xop->head.cluster, &bref);
			if (rkey != HAMMER2_KEY_MAX && bref.key >= rkey)
				break;
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
			if (!ok) {
				more = false;	/* the buffer is full */
				break;
			}
			/*
			 * Linux: the position is the next entry's, not this
			 * one's, once it has been emitted; dir_context has it
			 * so, and upstream's offset is where a full buffer stops
			 * the scan, which is always an entry not yet written.  A
			 * scan that ends on an error after this entry would
			 * otherwise hand the next getdents(2) this entry again,
			 * measured 2026-10-18 as a listing of one name without
			 * end once the kernel returned the entries written
			 * before the error.
			 */
			ctx->pos = (bref.key & HAMMER2_DIRHASH_USERMSK) + 1;
			emitted++;
		}
		hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);
		lkey = rkey;
		if (room == 0) {
			nmax = min(nmax * 2, HAMMER2_READDIR_NMAX);
		} else {
			per = emitted ? (room - ctx->count) / emitted : 0;
			if (per < HAMMER2_DIRENT64_MIN)
				per = HAMMER2_DIRENT64_MIN;
			nmax = clamp_t(size_t, ctx->count / per, 1,
			    HAMMER2_READDIR_NMAX);
		}
	} while (more && rkey != HAMMER2_KEY_MAX &&
	    (error == 0 || error == ENOENT));

	/* ENOENT here is the end: the loop went round on every other one. */
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
	struct timespec64 ts;
	hammer2_tid_t inum;
	uint64_t mtime;
	int error;

	if (READ_ONCE(hammer2_device_error))	/* Linux */
		return (-EIO);
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
		/*
		 * Linux: page_symlink() returns the negative errno the VFS
		 * uses and the return below negates a positive one, so its
		 * failure went back to symlink(2) as a positive number, which
		 * no caller reads as an error.  cp reported it with whatever
		 * errno the last failed call had left.  The dirent stays, as
		 * it does on FreeBSD when hammer2_write_file() fails there.
		 */
		error = -page_symlink(inode, target, strlen(target) + 1);
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
		/* Linux: the VFS copy of the time just stored. */
		hammer2_time_to_timespec(mtime, &ts);
		inode_set_mtime_to_ts(dir, inode_set_ctime_to_ts(dir, ts));
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
	struct timespec64 ts;
	uint64_t mtime;
	int error;

	if (READ_ONCE(hammer2_device_error))	/* Linux */
		return (-EIO);
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
			/*
			 * Linux: the VFS copy of the ctime the finisher
			 * stored on an inode that keeps a link, set under
			 * the lock that stored it.  One it emptied has no
			 * stamp to copy, and nothing on the media will be
			 * read against the kernel's.
			 */
			if (ip->meta.nlinks) {
				hammer2_time_to_timespec(ip->meta.ctime, &ts);
				inode_set_ctime_to_ts(inode, ts);
			} else {
				inode_set_ctime_current(inode);
			}
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
		/* Linux: the VFS copy of the time just stored. */
		hammer2_time_to_timespec(mtime, &ts);
		inode_set_mtime_to_ts(dir, inode_set_ctime_to_ts(dir, ts));
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
	struct timespec64 ts;
	uint64_t mtime;
	int error, update_fdip = 0, update_tdip = 0;

	if (flags & ~RENAME_NOREPLACE)
		return (-EINVAL);
	if (READ_ONCE(hammer2_device_error))	/* Linux */
		return (-EIO);
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
		if (tip)				/* Linux */
			xop4->tip_inum = tip->meta.inum;
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
		/* Linux: as the unlink sets the replaced inode's ctime. */
		if (tip->meta.nlinks) {
			hammer2_time_to_timespec(tip->meta.ctime, &ts);
			inode_set_ctime_to_ts(tinode, ts);
		} else {
			inode_set_ctime_current(tinode);
		}
		if (tip->meta.type == HAMMER2_OBJTYPE_DIRECTORY)
			clear_nlink(tinode);		/* Linux */
		else
			drop_nlink(tinode);		/* Linux */
	}

	/* Update directory mtimes to represent the something changed. */
	if (update_fdip || update_tdip) {
		hammer2_update_time(&mtime);
		hammer2_inode_modify(fip);	/* Linux: as the VFS stamps it */
		fip->meta.ctime = mtime;	/* Linux */
		if (update_fdip) {
			hammer2_inode_modify(fdip);
			fdip->meta.mtime = mtime;
			fdip->meta.ctime = mtime;	/* Linux */
			if (fip->meta.type == HAMMER2_OBJTYPE_DIRECTORY &&
			    fdip->meta.nlinks != 1)
				--fdip->meta.nlinks;
		}
		if (update_tdip) {
			hammer2_inode_modify(tdip);
			tdip->meta.mtime = mtime;
			tdip->meta.ctime = mtime;	/* Linux */
			if (fip->meta.type == HAMMER2_OBJTYPE_DIRECTORY &&
			    tdip->meta.nlinks != 1)
				++tdip->meta.nlinks;
		}
	}
	if (error == 0) {
		/* Linux: the VFS inodes' copies of the above. */
		hammer2_time_to_timespec(mtime, &ts);
		inode_set_mtime_to_ts(fdir, inode_set_ctime_to_ts(fdir, ts));
		inode_set_mtime_to_ts(tdir, inode_set_ctime_to_ts(tdir, ts));
		inode_set_ctime_to_ts(finode, ts);
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
	struct timespec64 ts;
	uint64_t cmtime;
	int error;

	if (ip->meta.nlinks >= U32_MAX)	/* Linux */
		return (-EMLINK);
	hammer2_pfs_memory_wait(tdip->pmp);	/* Linux: hammer2_vfs_modifying() */
	if (hammer2_vfs_enospace(tdip, 0, current_cred()) > 1)
		return (-ENOSPC);
	if (READ_ONCE(hammer2_device_error))	/* Linux */
		return (-EIO);
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
		/* Linux: the VFS copies, set under the locks that stored them. */
		hammer2_time_to_timespec(cmtime, &ts);
		inode_set_ctime_to_ts(inode, ts);
		inode_set_mtime_to_ts(dir, inode_set_ctime_to_ts(dir, ts));
	}
	hammer2_inode_unlock(ip);
	hammer2_inode_unlock(tdip);

	hammer2_trans_done(ip->pmp, HAMMER2_TRANS_SIDEQ);

	if (error == 0) {
		inc_nlink(inode);
		ihold(inode);
		d_instantiate(dentry, inode);
	}
	return (hammer2_vfs_errno(error));
}

/*
 * Linux: ->getattr is defined below with the other read-side entries, and
 * the directory table is the first of the four to name it.  A static
 * function called before its definition is an error in clang
 * (-Wundefined-internal) and in gcc ("used but never defined"), which
 * script/test-syntax.sh does not suppress, so it is declared here.
 */
static int hammer2_getattr(struct mnt_idmap *, const struct path *,
	struct kstat *, u32, unsigned int);
static int hammer2_vfs_update_time(struct inode *, enum fs_update_time,
	unsigned int);

const struct inode_operations hammer2_dir_iops = {
	.getattr	= hammer2_getattr,		/* Linux */
	.update_time	= hammer2_vfs_update_time,	/* Linux */
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
 * word, and the result copied back for a command that reads.  Every
 * command wants CAP_SYS_ADMIN except HAMMER2IOC_VERSION_GET and
 * HAMMER2IOC_INODE_GET, which any user may issue.  DragonFly leaves
 * HAMMER2IOC_BULKFREE_SCAN open as well, but a scan syncs every PFS on
 * the device under hammer2_mntlk and then holds the device's bulkfree
 * lock for its pass, so any user with a file open could repeat both; it
 * wants the capability here, as ext4's FITRIM does (fs/ext4/ioctl.c).  The
 * FreeBSD port checks nothing, and a snapshot or a PFS deletion is not
 * an operation to hand to every user with a file open.
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
	.setlease	= generic_setlease,		/* Linux */
};

/*
 * Linux: pages on a device that still need a block, across every
 * writeback it carries.  Under cgroup writeback the superblock's own
 * writeback is the root cgroup's alone, and a writer in any other
 * cgroup dirties pages the root's counter never sees; the walk is the
 * one the kernel's own accounting makes.  A page leaves the dirty count
 * when writeback starts on it and its block is allocated only when the
 * strategy runs, so the pages under writeback are counted too: without
 * them a writer arriving in that window was admitted into space the
 * writeback still needed, and four 4 MiB files of a fill were accepted
 * and lost, about one fill in eight.  A page whose block is already
 * allocated is counted twice for the rest of its writeback, which
 * refuses a little early and loses nothing.
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
		pages += wb_stat(wb, WB_WRITEBACK);
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
	ssize_t ret;

	if (READ_ONCE(hammer2_device_error))	/* Linux */
		return (-EIO);
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
	/*
	 * Linux: generic_file_write_iter(), with the tail of the block that
	 * holds the old end zeroed before a write that starts past it, as
	 * ->setattr and an extending fallocate do.  Otherwise the bytes a
	 * truncate left past the end in that block come back as file data
	 * (xfstests generic/112, a truncate then a write past the end).
	 * The size is read under i_rwsem, which keeps it still.  The times
	 * are stamped on the way, by file_update_time() through
	 * hammer2_vfs_update_time().
	 */
	inode_lock(inode);
	ret = generic_write_checks(iocb, from);
	if (ret > 0 && iocb->ki_pos > i_size_read(inode))
		ret = hammer2_zero_tail(inode, i_size_read(inode)) ?: ret;
	if (ret > 0)
		ret = __generic_file_write_iter(iocb, from);
	inode_unlock(inode);
	if (ret > 0)
		ret = generic_write_sync(iocb, ret);
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
 *
 * Linux: the folio is waited on before it is zeroed.  The mapping is
 * marked stable because the write XOP hashes a whole-block folio itself
 * rather than a copy, so a folio under writeback is one the core is
 * reading: zeroing it here would change bytes the core has already read
 * and is about to either copy to the media or compare against a dedup
 * candidate, and a false match there points the file at another block's
 * content.  read_mapping_folio() takes no FGP_STABLE of its own, so the
 * wait is made here, once, rather than by asking for the folio again.
 */
static int
hammer2_zero_tail(struct inode *inode, loff_t off)
{
	struct folio *folio;
	loff_t pos, bend;

	if (off == 0 || (off & HAMMER2_PBUFMASK64) == 0)
		return (0);
	/*
	 * Linux: to the end of the logical block, not of one folio.  Under
	 * memory pressure the block is cached as several smaller folios,
	 * and the media keeps the old bytes past off until the block is
	 * rewritten, so a later extend read them back as file data.  fsx
	 * (xfstests generic/075) found it: a truncate inside a block, then
	 * an extend, read bytes the file no longer held.
	 */
	bend = (off | HAMMER2_PBUFMASK64) + 1;
	for (pos = off; pos < bend; pos = folio_pos(folio) + folio_size(folio)) {
		/*
		 * Only the folio holding off has bytes to keep.  One wholly
		 * past it is zeroed entire, so it is grabbed rather than
		 * read: a read past the end asks the tree for a block a
		 * file held in its inode does not have, and fails EIO
		 * (xfstests generic/438, an extending fallocate).
		 */
		if (pos == off)
			folio = read_mapping_folio(inode->i_mapping,
			    pos >> PAGE_SHIFT, NULL);
		else
			folio = filemap_grab_folio(inode->i_mapping,
			    pos >> PAGE_SHIFT);
		if (IS_ERR(folio))
			return (PTR_ERR(folio));
		if (pos == off)
			folio_lock(folio);
		else if (!folio_test_uptodate(folio)) {
			folio_zero_range(folio, 0, folio_size(folio));
			folio_mark_uptodate(folio);
		}
		/*
		 * The lock is held and the writeback is waited on under it:
		 * a writer that is already in the core's hands cannot be
		 * holding the lock, so no writer can begin while the wait
		 * runs and the zeroing below then lands on a folio nobody
		 * else is reading.
		 */
		folio_wait_stable(folio);
		folio_zero_segment(folio, pos - folio_pos(folio),
		    min_t(loff_t, bend - folio_pos(folio), folio_size(folio)));
		folio_mark_dirty(folio);
		folio_unlock(folio);
		folio_put(folio);
	}
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

	if (READ_ONCE(hammer2_device_error))	/* Linux */
		return (-EIO);
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
		/*
		 * Linux: truncate(2) by path passes ATTR_SIZE alone, and
		 * ftruncate(2) adds the two times, so a size change that
		 * names neither takes them, as xfs_setattr_size() does
		 * (xfstests generic/313).
		 */
		if (!(attr->ia_valid & (ATTR_CTIME | ATTR_MTIME)))
			attr->ia_valid |= ATTR_CTIME | ATTR_MTIME;
	}
	/*
	 * Linux: notify_change() filled ia_ctime, and ia_mtime and ia_atime
	 * where the caller set neither, from the kernel's clock, which runs
	 * ahead of the one hammer2_update_time() reads by the multigrain
	 * floor any other filesystem on the machine raises.  Every stamp the
	 * media takes is read from that one function, so these are too; a
	 * time the caller set is kept.
	 */
	hammer2_update_time(&ctime);
	hammer2_time_to_timespec(ctime, &ts);
	attr->ia_ctime = ts;
	if ((attr->ia_valid & (ATTR_MTIME | ATTR_MTIME_SET)) == ATTR_MTIME)
		attr->ia_mtime = ts;
	if ((attr->ia_valid & (ATTR_ATIME | ATTR_ATIME_SET)) == ATTR_ATIME)
		attr->ia_atime = ts;

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

	if (READ_ONCE(hammer2_device_error))	/* Linux */
		return (-EIO);
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
	/*
	 * Linux: vfsync() wrote the vnode's buffers to the device and
	 * waited; the strategy XOPs above left them in the device's page
	 * cache.  Write them through now, and give a device's error to
	 * this file's mapping, so every descriptor on it reads it once,
	 * the way file_write_and_wait_range() above reports the mapping's
	 * own.
	 */
	if (error1 == 0) {
		error1 = hammer2_vfs_sync_devs(ip->pmp);
		if (error1) {
			mapping_set_error(inode->i_mapping, error1);
			error1 = file_check_and_advance_wb_err(file);
		}
	}
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

	if (READ_ONCE(hammer2_device_error))	/* Linux */
		return (VM_FAULT_SIGBUS);
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

/*
 * One logical block's physical offset, through the carried bmap XOP.
 *
 * This is upstream's hammer2_bmap_impl() with the parts a Linux ->bmap
 * and ->llseek need and no vnode buffer object to hand back.  The XOP
 * reports ENOENT for an offset no chain covers, which is a hole: the
 * read path takes the same answer at the same place and zeroes the
 * folio rather than failing, so a hole is reported here as a hole and
 * never as an error.
 *
 * Returns 0 and sets *poff, or an errno.  The errno is POSITIVE, which
 * is this module's convention inside the core: hammer2_error_to_errno()
 * returns positive values and the VFS entry points negate them.  ENOENT
 * means the block is a hole.  Getting the sign wrong is silent, since a
 * positive ENOENT compared against a negative one is never equal, and
 * the caller then takes the errno for a file position.
 *
 * The XOP's offset is whichever element ran last, which may lack the block
 * or hold an older one, so the address is the focus's own, the chain the
 * quorum check chose.  A block only a remote element holds has no address
 * on this host: with a remote focus the address is a local element's the
 * check matched to it, and is otherwise HAMMER2_BMAP_UNKNOWN, never an
 * invented one.
 */
#define HAMMER2_BMAP_UNKNOWN	((hammer2_off_t)-1)	/* Linux */

static hammer2_off_t
hammer2_bmap_offset(hammer2_cluster_t *cluster, hammer2_off_t none) /* Linux */
{
	hammer2_chain_t *chain;
	int i;

	if (cluster->focus == NULL)
		return (none);
	if (!hammer2_dev_is_conn(cluster->focus->hmp))
		return (cluster->focus->bref.data_off);
	for (i = 0; i < cluster->nchains; ++i) {
		chain = cluster->array[i].chain;
		if (chain && chain->error == 0 &&
		    !hammer2_dev_is_conn(chain->hmp) &&
		    (cluster->array[i].flags & HAMMER2_CITEM_INVALID) == 0)
			return (chain->bref.data_off);
	}
	return (HAMMER2_BMAP_UNKNOWN);
}

static int
hammer2_bmap_lbn(struct inode *inode, sector_t lbn, hammer2_off_t *poff)
{
	hammer2_inode_t *ip = VTOI(inode);
	hammer2_xop_bmap_t *xop;
	int error;

	hammer2_inode_lock(ip, HAMMER2_RESOLVE_SHARED);
	xop = hammer2_xop_alloc(ip, 0);
	xop->lbn = lbn;
	hammer2_xop_start(&xop->head, &hammer2_bmap_desc);
	error = hammer2_error_to_errno(hammer2_xop_collect(&xop->head, 0));
	if (error == 0)
		*poff = hammer2_bmap_offset(&xop->head.cluster, xop->offset);
	hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);
	hammer2_inode_unlock(ip);

	return (error);
}

/*
 * Linux: the seek's and the map's answer from hammer2_xop_scanall(), for a
 * cluster hammer2_xop_seek() does not walk, one with a remote element,
 * which has no blockref array on this host, and for a range on which
 * several voting elements' walks disagree (hammer2_seek_vote()), where
 * the scan's collect decides key by key.  The scan feeds every chain in
 * its range before the frontend's first collect
 * (hammer2_xop_start_except()), so it runs over a chunk of key space at a
 * time and stops at the first chunk that holds the
 * answer.  A chunk that held no data doubles up to HAMMER2_SEEK_HOLE_MAX,
 * since an empty range costs one lookup however large; one that held data
 * doubles only up to HAMMER2_SEEK_DATA_MAX, since each of its blocks costs
 * a chain.
 *
 * On two voting elements the quorum is both, so a block the walks disagree
 * on is a hole to the collect, and a SEEK_HOLE that falls back stops there,
 * inside the batch that disagreed; SEEK_DATA's scan crosses holes a GiB at
 * a time, and a map falls back one batch at a time.  On three or more a
 * block two of them hold at one tid is data to the quorum while the slots
 * differ, so the scan can run on to the next block the quorum lacks.
 * DEFER(H2_WIRE_SEEKTIME's 1 GiB SEEK_HOLE above 2.5 s on h2debug-7.3tls, a PFS with a remote element mounted read-write, cluster-quorum.sh's two-master 16 GiB SEEK_HOLE above 50 ms on h2release-7.3tls with or without H2_QUORUM_SPLIT, or a third MASTER in cluster-quorum.sh):
 * a seek request the cluster transport carries would let a remote element
 * walk, and a quorum over the elements' blockref lists would let masters
 * that disagree walk rather than scan.
 */
#define HAMMER2_SEEK_CHUNK	((hammer2_key_t)HAMMER2_XOPFIFO * HAMMER2_PBUFSIZE)
#define HAMMER2_SEEK_DATA_MAX	((hammer2_key_t)1024 * HAMMER2_PBUFSIZE)
#define HAMMER2_SEEK_HOLE_MAX	((hammer2_key_t)1 << 30)

static int
hammer2_seek_scanall(hammer2_inode_t *ip, struct hammer2_seek_req *r)
{
	hammer2_xop_scanall_t *sxop;
	hammer2_blockref_t *bref;
	hammer2_key_t cur = r->key_beg, end, next, chunk = HAMMER2_SEEK_CHUNK;
	bool held;
	int error;

	r->key = r->key_beg;
	r->found = 0;
	r->n = 0;
	for (;;) {
		cond_resched();
		if (fatal_signal_pending(current))
			return (EINTR);
		end = (r->key_end - cur < chunk) ? r->key_end : cur + chunk - 1;
		held = false;
		hammer2_inode_lock(ip, HAMMER2_RESOLVE_SHARED);
		sxop = hammer2_xop_alloc(ip, 0);
		sxop->key_beg = cur;
		sxop->key_end = end;
		sxop->resolve_flags = HAMMER2_RESOLVE_ALWAYS |
		    HAMMER2_RESOLVE_SHARED;
		sxop->lookup_flags = HAMMER2_LOOKUP_NODATA |
		    HAMMER2_LOOKUP_SHARED;
		hammer2_xop_start(&sxop->head, &hammer2_scanall_desc);
		while ((error = hammer2_xop_collect(&sxop->head, 0)) == 0) {
			bref = &sxop->head.cluster.focus->bref;
			if (bref->type != HAMMER2_BREF_TYPE_DATA)
				continue;
			if (bref->keybits > 63) {
				error = HAMMER2_ERROR_BADBREF;
				break;
			}
			held = true;
			next = bref->key + ((hammer2_key_t)1 << bref->keybits);
			if (r->mode == HAMMER2_SEEK_MODE_DATA) {
				r->key = max(bref->key, r->key);
				r->found = 1;
				break;
			}
			if (r->mode == HAMMER2_SEEK_MODE_HOLE) {
				if (bref->key > r->key)
					break;		/* a hole at r->key */
				r->key = next;
				continue;
			}
			if (r->n == r->max)
				break;
			r->v[r->n].key = bref->key;
			r->v[r->n].keybits = bref->keybits;
			r->v[r->n].methods = bref->methods;
			r->v[r->n].poff = hammer2_bmap_offset(&sxop->head.cluster,
			    HAMMER2_BMAP_UNKNOWN);
			++r->n;
			r->key = next;
		}
		if (error == HAMMER2_ERROR_ENOENT)
			error = 0;
		hammer2_xop_retire(&sxop->head, HAMMER2_XOPMASK_VOP);
		hammer2_inode_unlock(ip);
		if (error != 0 || r->found || end == r->key_end ||
		    (r->mode == HAMMER2_SEEK_MODE_HOLE && r->key <= end) ||
		    (r->mode == HAMMER2_SEEK_MODE_MAP && r->n == r->max))
			break;
		cur = end + 1;
		if (chunk < (held ? HAMMER2_SEEK_DATA_MAX : HAMMER2_SEEK_HOLE_MAX))
			chunk *= 2;
	}
	return (hammer2_error_to_errno(error));
}

/*
 * Linux: whether hammer2_xop_seek() walks for this XOP: a PFS with no
 * remote element, which has no blockref array on this host.  The test
 * reads every slot of the PFS (hammer2_remote_has_slot()), not only those
 * the XOP runs, so an element joining the inode's cluster under
 * cluster_spin, which the inode lock does not exclude, cannot slip a
 * remote one past it.  The debug build's seek_scanall parameter sends
 * every seek and map to hammer2_seek_scanall(), so a test can compare the
 * two readers on one file; seek_walked counts the tree reads the walk
 * answered, and seek_fellback the reads hammer2_seek_vote() handed to the
 * scan after a first walk: voting elements that disagreed, an element
 * joined since the call began, or a remote slot or seek_scanall appearing
 * between batches; so the test knows which reader each answer came from.
 * seek_agree_break, 1 or 2, breaks the comparison of the elements'
 * answers (hammer2_seek_agree()) for that comparison's control.
 */
#if defined(HAMMER2_LOCKDEBUG)
static unsigned int hammer2_seek_force_scanall;
module_param_named(seek_scanall, hammer2_seek_force_scanall, uint, 0644);
static unsigned int hammer2_seek_walked;
module_param_named(seek_walked, hammer2_seek_walked, uint, 0444);
static unsigned int hammer2_seek_fellback;
module_param_named(seek_fellback, hammer2_seek_fellback, uint, 0444);
static unsigned int hammer2_seek_agree_break;
module_param_named(seek_agree_break, hammer2_seek_agree_break, uint, 0644);
#define HAMMER2_SEEK_COUNT(c)	WRITE_ONCE(c, (c) + 1)
#else
#define HAMMER2_SEEK_COUNT(c)	((void)0)
#endif

static bool
hammer2_seek_walks(hammer2_xop_seek_t *xop)
{
#if defined(HAMMER2_LOCKDEBUG)
	if (READ_ONCE(hammer2_seek_force_scanall)) {
		pr_info_once("hammer2: seek scanall forced\n");
		return (false);
	}
#endif
	return (!hammer2_remote_has_slot(xop->head.ip1->pmp));
}

/*
 * Linux: the elements that decide a key, as hammer2_cluster_check() counts
 * them: a MASTER or the SUPROOT.
 */
static int
hammer2_seek_voters(hammer2_xop_seek_t *xop)
{
	int i, n = 0;

	for (i = 0; i < xop->head.cluster.nchains; ++i)
		switch (xop->head.ip1->pmp->pfs_types[i]) {
		case HAMMER2_PFSTYPE_MASTER:
		case HAMMER2_PFSTYPE_SUPROOT:
			++n;
			break;
		}
	return (n);
}

/*
 * Linux: whether the elements that walked answered alike, block for block:
 * the same answer and the same deciding blocks at the same keybits and
 * modify_tid.  The physical address and the methods are each element's
 * own and are not compared: the compression heuristic is the inode's
 * (ip->comp_heuristic, hammer2_strategy.c), so one element's write of a
 * block can move it before the next element's write of the same block
 * reads it, and two masters can hold one block at one tid compressed and
 * not.  The caller reports one element's address and methods together, as
 * the scan reports its focus's.  Returns the highest-index element that
 * walked, the focus hammer2_cluster_check() would choose among matching
 * masters, or -1 when they differ.  Alike is the quorum's answer at every
 * key: each block in the range is held by every voting element at one
 * tid.  A difference fixes no rule of its own; the caller asks the scan,
 * whose collect decides key by key.
 */
static int
hammer2_seek_agree(struct hammer2_seek_req *rs, int nc)
{
	struct hammer2_seek_req *a, *b;
	int i, j, k = -1;
	unsigned int brk = 0;

#if defined(HAMMER2_LOCKDEBUG)
	brk = READ_ONCE(hammer2_seek_agree_break);
#endif
	for (i = 0; i < nc; ++i) {
		if (!rs[i].walked)
			continue;
		if (k < 0 || brk == 2) {
			if (k < 0)
				k = i;
			if (brk == 2)
				return (k);	/* the control: the first, unread */
			continue;
		}
		a = &rs[k];
		b = &rs[i];
		if (a->key != b->key || a->found != b->found ||
		    a->n != b->n || a->full != b->full)
			return (-1);
		for (j = 0; j < a->n; ++j)
			if (a->v[j].key != b->v[j].key ||
			    a->v[j].keybits != b->v[j].keybits ||
			    (brk != 1 && a->v[j].tid != b->v[j].tid))
				return (-1);
		k = i;
	}
	return (k);
}

/*
 * Linux: the seek's and the map's answer on several voting elements.
 * Each walks into its own request and v, HAMMER2_SEEK_VOTE_REFS blocks at
 * a time, and the frontend compares them (hammer2_seek_agree()): alike,
 * the answer stands, and a SEEK_HOLE whose v filled goes on from its
 * cursor in a new XOP; otherwise the scan answers from the cursor, and for
 * a map only this batch, the next walking again.  The elements walk one
 * after another in this thread (hammer2_xop_start_except()), so a writer
 * waits for the sum of the walks.  nc is the element count v was sized
 * for; an XOP with more, an element joined since, goes to the scan.
 */
#define HAMMER2_SEEK_VOTE_REFS	1024

static int
hammer2_seek_vote(hammer2_inode_t *ip, struct hammer2_seek_req *r, int nc)
{
	struct hammer2_seek_req *rs, r2;
	struct hammer2_fiemap_ref *rv;
	hammer2_xop_seek_t *xop;
	hammer2_key_t cur = r->key_beg;
	int error, i, k, refs;

	rs = kcalloc(nc, sizeof(*rs), GFP_KERNEL);
	/* SEEK_DATA records the one block it answers at */
	refs = (r->mode == HAMMER2_SEEK_MODE_DATA) ? 1 : HAMMER2_SEEK_VOTE_REFS;
	rv = kvmalloc_array((size_t)nc * refs, sizeof(*rv), GFP_KERNEL);
	if (rs == NULL || rv == NULL) {
		kfree(rs);
		kvfree(rv);
		return (hammer2_seek_scanall(ip, r));
	}
	for (;;) {
		hammer2_inode_lock(ip, HAMMER2_RESOLVE_SHARED);
		xop = hammer2_xop_alloc(ip, 0);
		if (xop->head.cluster.nchains > nc || !hammer2_seek_walks(xop)) {
			hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);
			hammer2_inode_unlock(ip);
			k = -1;
			error = 0;
			break;
		}
		for (i = 0; i < nc; ++i) {
			memset(&rs[i], 0, sizeof(rs[i]));
			rs[i].key_beg = cur;
			rs[i].key_end = r->key_end;
			rs[i].mode = r->mode;
			rs[i].v = rv + (size_t)i * refs;
			rs[i].max = (r->mode == HAMMER2_SEEK_MODE_MAP) ?
			    min(r->max, refs) : refs;
		}
		xop->rs = rs;
		hammer2_xop_start(&xop->head, &hammer2_seek_desc);
		error = hammer2_xop_collect(&xop->head, 0);
		if (error == HAMMER2_ERROR_ENOENT)	/* the walks fed no chain */
			error = 0;
		hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);
		hammer2_inode_unlock(ip);
		if (error != 0)
			break;
		k = hammer2_seek_agree(rs, nc);
		if (k < 0 || r->mode != HAMMER2_SEEK_MODE_HOLE || !rs[k].full)
			break;
		HAMMER2_SEEK_COUNT(hammer2_seek_walked);
		cur = rs[k].key;
	}
	if (error == 0 && k >= 0) {
		HAMMER2_SEEK_COUNT(hammer2_seek_walked);
		r->key = rs[k].key;
		r->found = rs[k].found;
		r->n = 0;
		if (r->mode == HAMMER2_SEEK_MODE_MAP) {
			memcpy(r->v, rs[k].v, rs[k].n * sizeof(*r->v));
			r->n = rs[k].n;
		}
	}
	kfree(rs);
	kvfree(rv);
	if (error != 0)
		return (hammer2_error_to_errno(error));
	if (k < 0) {
		HAMMER2_SEEK_COUNT(hammer2_seek_fellback);
		r2 = *r;
		r2.key_beg = cur;
		error = hammer2_seek_scanall(ip, &r2);
		r->key = r2.key;
		r->found = r2.found;
		r->n = r2.n;
	}
	return (error);
}

/*
 * Linux: the blockref tree's answer to a seek or a map (struct
 * hammer2_seek_req): hammer2_xop_seek()'s walk on a cluster of local
 * elements, through hammer2_seek_vote() where several vote, and
 * hammer2_seek_scanall() for a cluster with a remote element.
 * Returns 0 or a positive errno.
 */
static int
hammer2_seek_tree(struct inode *inode, struct hammer2_seek_req *r)
{
	hammer2_inode_t *ip = VTOI(inode);
	hammer2_xop_seek_t *xop;
	int error, nc;

	hammer2_inode_lock(ip, HAMMER2_RESOLVE_SHARED);
	xop = hammer2_xop_alloc(ip, 0);
	if (!hammer2_seek_walks(xop)) {
		hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);
		hammer2_inode_unlock(ip);
		return (hammer2_seek_scanall(ip, r));
	}
	if (hammer2_seek_voters(xop) > 1) {
		nc = xop->head.cluster.nchains;
		hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);
		hammer2_inode_unlock(ip);
		return (hammer2_seek_vote(ip, r, nc));
	}
	xop->r = *r;
	hammer2_xop_start(&xop->head, &hammer2_seek_desc);
	error = hammer2_xop_collect(&xop->head, 0);
	if (error == HAMMER2_ERROR_ENOENT) {	/* the walk fed no chain */
		HAMMER2_SEEK_COUNT(hammer2_seek_walked);
		*r = xop->r;
		error = 0;
	}
	hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);
	hammer2_inode_unlock(ip);

	return (hammer2_error_to_errno(error));
}

/*
 * Linux: the first byte in [from, to] held by a folio tagged dirty or
 * under writeback, or -1.  Such a folio holds data the blockref tree does
 * not have yet; hammer2_seek_data_hole() says why that order of reading is
 * safe.
 */
static loff_t
hammer2_seek_tagged(struct address_space *mapping, loff_t from, loff_t to)
{
	static const xa_mark_t tags[] = {
	    PAGECACHE_TAG_DIRTY, PAGECACHE_TAG_WRITEBACK
	};
	struct folio_batch fbatch;
	loff_t first = -1, pos;
	pgoff_t index;
	int i;

	for (i = 0; i < ARRAY_SIZE(tags); ++i) {
		index = from >> PAGE_SHIFT;
		folio_batch_init(&fbatch);
		if (filemap_get_folios_tag(mapping, &index, to >> PAGE_SHIFT,
		    tags[i], &fbatch)) {
			pos = max(folio_pos(fbatch.folios[0]), from);
			if (first < 0 || pos < first)
				first = pos;
		}
		folio_batch_release(&fbatch);
	}
	return (first);
}

/*
 * Linux: the debug build's hold between a seek's or a map's page cache tag
 * read and its tree read (hammer2_debug_hold()), so a writeback can be
 * completed between the two.
 */
#if defined(HAMMER2_LOCKDEBUG)
static unsigned int hammer2_seek_tag_hold_ms;
module_param_named(seek_tag_hold_ms, hammer2_seek_tag_hold_ms, uint, 0644);
#endif

/*
 * Linux: SEEK_DATA and SEEK_HOLE.  Called and returning with i_rwsem held
 * shared; returns the answer or a negative errno, and leaves the file
 * position to hammer2_llseek().
 *
 * A hole is an offset no block covers, and the bytes past i_size are a
 * hole by definition, so no answer passes i_size.  An offset before the
 * start or at or past the end fails with ENXIO for either whence, as
 * iomap_seek_hole() and iomap_seek_data() fail it.  A file whose data is
 * embedded in its inode (HAMMER2_OPFLAG_DIRECTDATA) has no blockref tree
 * and is data from 0 to i_size.
 *
 * The blockref tree records a block at its writeback, so a block written
 * and not yet written back is held by a folio tagged dirty or under
 * writeback, and such a block is data.  A folio leaves its tags only after
 * its block is in the tree, and i_rwsem keeps write(2) from tagging
 * another, so a tag read made before a tree read sees every block of data
 * the tree read misses.  SEEK_DATA reads the tags first and asks the tree
 * only below the first tagged block.  SEEK_HOLE asks the tree, reads the
 * tags over the hole it found, and accepts a hole only from a tree read
 * made after the tags called that block clean.  Against write(2), a
 * mapping tagged nowhere stays so under i_rwsem, and its tags are not
 * read.
 *
 * Two cases fall outside that.  A write through a shared mapping takes no
 * i_rwsem, so a fault after the tag read can dirty a block the tree then
 * calls a hole; iomap's seek leaves the same window.  A writeback that
 * fails ends with the folio clean and its block not in the tree
 * (hammer2_xop_strategy_write()), so the seek calls that block a hole
 * while read(2) still returns the cached bytes, and fsync(2) reports the
 * error.
 */
static loff_t
hammer2_seek_data_hole(struct file *file, loff_t offset, int whence)
{
	struct inode *inode = file->f_mapping->host;
	struct address_space *mapping = file->f_mapping;
	struct hammer2_seek_req r = { 0 };
	loff_t isize = i_size_read(inode);
	unsigned int bsize = i_blocksize(inode);
	loff_t cur = offset & ~((loff_t)bsize - 1), clean = -1, pos;
	bool tagged;
	int error;

	if (offset < 0 || offset >= isize)
		return (-ENXIO);
	/* Linux: the seek's race control; i_size is read, the tree not yet. */
	HAMMER2_DEBUG_HOLD(hammer2_seek_hold_ms, "seek");
	if (VTOI(inode)->meta.op_flags & HAMMER2_OPFLAG_DIRECTDATA)
		return (whence == SEEK_DATA ? offset : isize);

	tagged = mapping_tagged(mapping, PAGECACHE_TAG_DIRTY) ||
	    mapping_tagged(mapping, PAGECACHE_TAG_WRITEBACK);
	r.key_end = (hammer2_key_t)isize - 1;
	if (whence == SEEK_DATA) {
		pos = -1;
		if (tagged) {
			pos = hammer2_seek_tagged(mapping, cur, isize - 1);
			if (pos >= 0) {
				pos &= ~((loff_t)bsize - 1);
				if (pos <= cur)
					return (offset);
				r.key_end = (hammer2_key_t)pos - 1;
			}
			HAMMER2_DEBUG_HOLD(hammer2_seek_tag_hold_ms, "seek tag");
		}
		r.mode = HAMMER2_SEEK_MODE_DATA;
		r.key_beg = (hammer2_key_t)cur;
		error = hammer2_seek_tree(inode, &r);
		if (error != 0)
			return (hammer2_vfs_errno(error));
		if (r.found)
			return (max_t(loff_t, (loff_t)r.key, offset));
		return (pos >= 0 ? pos : -ENXIO);
	}

	r.mode = HAMMER2_SEEK_MODE_HOLE;
	for (;;) {
		r.key_beg = (hammer2_key_t)cur;
		error = hammer2_seek_tree(inode, &r);
		if (error != 0)
			return (hammer2_vfs_errno(error));
		if (r.key >= (hammer2_key_t)isize)
			return (isize);
		pos = (loff_t)r.key;
		if (!tagged || pos == clean)
			return (max(pos, offset));
		HAMMER2_DEBUG_HOLD(hammer2_seek_tag_hold_ms, "seek tag");
		while (pos < isize &&
		    hammer2_seek_tagged(mapping, pos, pos + bsize - 1) >= 0)
			pos += bsize;
		if (pos >= isize)
			return (isize);
		clean = cur = pos;
	}
}

/*
 * Linux: lseek(2).  SEEK_DATA and SEEK_HOLE hold i_rwsem shared for the
 * whole seek, as btrfs_file_llseek() holds it, so the size, the tags and
 * the tree are read under one hold, the answer lies within the size the
 * seek read, and a truncate waits for the seek.  Under it the seek takes
 * the inode lock and chain locks, which sit below i_rwsem in the module's
 * order as hammer2_vop_setattr() takes them, and no folio lock.  On a
 * cluster of local elements the tree read is a walk of blockref arrays
 * that makes no chain for a block on the media (hammer2_xop_seek()).  A
 * success sets the file position through vfs_setpos(), as ext4_llseek()
 * ends; a failure leaves it where it was.
 */
static loff_t
hammer2_llseek(struct file *file, loff_t offset, int whence)
{
	struct inode *inode = file->f_mapping->host;
	loff_t maxbytes = inode->i_sb->s_maxbytes;
	loff_t pos;

	switch (whence) {
	case SEEK_DATA:
	case SEEK_HOLE:
		break;
	default:
		return (generic_file_llseek_size(file, offset, whence,
		    maxbytes, i_size_read(inode)));
	}
	inode_lock_shared(inode);
	pos = hammer2_seek_data_hole(file, offset, whence);
	inode_unlock_shared(inode);
	if (pos < 0)
		return (pos);
	return (vfs_setpos(file, pos, maxbytes));
}

static sector_t
hammer2_bmap(struct address_space *mapping, sector_t lbn)
{
	hammer2_off_t poff;
	int error;

	error = hammer2_bmap_lbn(mapping->host, lbn, &poff);
	if (error != 0 || poff == HAMMER2_BMAP_UNKNOWN)
		return (0);	/* a hole, an error, or no address on this host */
	/*
	 * Linux: FIBMAP counts in filesystem blocks (bmap() in fs/inode.c),
	 * not sectors.  The first run returned sectors, and filefrag -B read
	 * every block 128 times too far out (xfstests generic/519).
	 */
	return (poff >> mapping->host->i_blkbits);
}

/*
 * Linux: fallocate(2).  No BSD port has this.  FreeBSD, DragonFly and OpenBSD
 * carry no fallocate vop at all, and NetBSD's entries in its vop table are
 * genfs_eopnotsupp, so there is no upstream arrangement to follow and this is
 * marked XXX where it decides something the format did not.
 *
 * WHAT THE FORMAT GIVES.  A write whose block is all zeros does not store
 * that block: hammer2_write_file_core() calls zero_write(), which deletes the
 * chain where one exists.  So a hole and a zeroed range are the same thing on
 * this media, and the only question a mode has to answer is whether the file
 * should also get bigger.
 *
 *   FALLOC_FL_PUNCH_HOLE   deallocate the range.  Zeroing it is exactly that,
 *                          since the block is then not stored.
 *   FALLOC_FL_ZERO_RANGE   the same, and on this format it cannot be
 *                          distinguished from a punch afterwards.
 *   KEEP_SIZE              leave i_size alone, which is what a punch always
 *                          does and what a plain allocate does not.
 *   plain allocate         zero the range and extend i_size to cover it.
 *
 * Preallocation in the sense ext4 means it, blocks reserved and readable as
 * zeros, is what this cannot provide: the media does not hold a zero block,
 * so a preallocated range costs nothing until it is written and reads back as
 * a hole.  That is not a weaker fallocate, it is what the format's block
 * elision makes of one, and it is the reason the range is zeroed here rather
 * than allocated.
 *
 * The zeroing goes through the page cache, which is the path that already
 * turns zeros into chain deletion, under the lock order the size change in
 * ->setattr uses: i_rwsem for the call, the page cache touched before
 * ip->lock, and ->read_folio (which the read of a folio may take) taking
 * ip->lock shared.  The transaction and ip->lock are then taken for the
 * size change alone.
 */
static long
hammer2_fallocate_locked(struct file *file, int mode, loff_t offset,
    loff_t len)
{
	struct inode *inode = file_inode(file);
	hammer2_inode_t *ip = VTOI(inode);
	loff_t end = offset + len;
	loff_t isize = i_size_read(inode);
	bool keep_size = (mode & FALLOC_FL_KEEP_SIZE) != 0;
	int error;

	/*
	 * vfs_fallocate() has already rejected the modes this format does not
	 * carry and checked the range against s_maxbytes, but it hands every
	 * mode it recognizes down, so the refusals below are this port's and
	 * are why they are named rather than left to a default.
	 */
	switch (mode & FALLOC_FL_MODE_MASK) {
	case FALLOC_FL_PUNCH_HOLE:
		/*
		 * A punch is defined to keep the size, and the VFS has already
		 * refused a punch without the flag.
		 */
		break;
	case FALLOC_FL_ZERO_RANGE:
		break;
	case FALLOC_FL_ALLOCATE_RANGE:
		break;
	case FALLOC_FL_COLLAPSE_RANGE:
	case FALLOC_FL_INSERT_RANGE:
		/*
		 * These move data rather than write it, and this port has no
		 * range shift: the blockref tree is keyed by logical offset, so
		 * a shift is a re-key of every chain past the point, which no
		 * upstream port does either.
		 */
		return (-EOPNOTSUPP);
	case FALLOC_FL_UNSHARE_RANGE:
		/*
		 * Every write here is already a copy on write, so there is
		 * nothing shared to unshare, and the mode is a plain allocate:
		 * without KEEP_SIZE it still extends the file, which returning
		 * 0 early skipped (xfstests generic/075 read the size short).
		 */
		break;
	case FALLOC_FL_WRITE_ZEROES:
		/*
		 * The device is not told to write zeroes and the format has no
		 * command for it; a zeroed range is a hole here as above.
		 */
		return (-EOPNOTSUPP);
	default:
		return (-EOPNOTSUPP);
	}

	if (READ_ONCE(hammer2_device_error))	/* Linux */
		return (-EIO);
	if (ip->pmp->rdonly)
		return (-EROFS);
	/*
	 * The same reservation check the write and setattr paths make.  A
	 * punch frees space rather than taking it, so only the modes that can
	 * grow the file are checked.
	 */
	if (!(mode & (FALLOC_FL_PUNCH_HOLE | FALLOC_FL_ZERO_RANGE))) {
		hammer2_pfs_memory_wait(ip->pmp);	/* Linux */
		if (hammer2_vfs_enospace(ip, len, current_cred()) > 1)
			return (-ENOSPC);
	}

	/*
	 * A punch, or a zero range with KEEP_SIZE, past the end finds
	 * nothing to free, and the range is clamped to the end of the file:
	 * the bytes past i_size are a hole already.  A zero range without
	 * KEEP_SIZE extends the file, so its range is not clamped.  The
	 * alignment is not forced, since the page cache can zero a partial
	 * folio and the block elision reads whatever it is given.
	 */
	if ((mode & FALLOC_FL_PUNCH_HOLE) ||
	    ((mode & FALLOC_FL_ZERO_RANGE) && keep_size)) {
		if (offset >= isize)
			return (0);
		if (end > isize)
			end = isize;
	}

	/* An empty range after clamping is nothing to do, not an error. */
	if (end <= offset)
		return (0);

	/*
	 * The size change first, under the transaction and ip->lock, as
	 * ->setattr does it.  A punch and KEEP_SIZE leave the size where it
	 * is; an allocate or a zero range extends to cover the range, and the
	 * extend is what makes the new tail read back as zeros rather than as
	 * the media that was there.
	 *
	 * It runs BEFORE the folios are read.  Reading a folio of a range
	 * past the current size asks the blockref tree for a block the inode
	 * does not have: on a file of size 0 the chain's key is at 0 and the
	 * read is for the block after it, which hammer2_read_folio() refuses
	 * with EIO and a WARN_ONCE.  Measured: fallocate(fd, 0, 0, 131072)
	 * on a new file returned EIO and tripped "chain key 0 above read at
	 * 1000", while the same call on a file whose size was already
	 * 131072 returned 0 with no warning.  xfstests' seek sanity test
	 * calls exactly that to probe for unwritten-extent support and
	 * aborts on it, so this is what made generic/436 fail.
	 */
	if (!keep_size && !(mode & FALLOC_FL_PUNCH_HOLE) && end > isize) {
		/*
		 * RLIMIT_FSIZE and s_maxbytes, which a write meets in
		 * generic_write_checks() and an extending allocate here, as
		 * ext4 and xfs check them (xfstests generic/228).
		 */
		error = inode_newsize_ok(inode, end);
		if (error)
			return (error);
		/* As ->setattr does: the old tail block must not reappear. */
		error = hammer2_zero_tail(inode, isize);
		if (error)
			return (error);
		hammer2_trans_init(ip->pmp, 0);
		hammer2_inode_lock(ip, 0);
		hammer2_extend_file(ip, end);
		hammer2_inode_modify(ip);
		if (ip->flags & HAMMER2_INODE_RESIZED)
			hammer2_inode_chain_sync(ip);
		hammer2_inode_unlock(ip);
		hammer2_trans_done(ip->pmp, HAMMER2_TRANS_SIDEQ);
		truncate_setsize(inode, end);
	}

	/*
	 * The page cache side, in folio-sized steps, before ip->lock.  Each
	 * folio is locked, waited on and zeroed the way hammer2_zero_tail()
	 * does, and for the same reason: the write XOP hashes a whole-block
	 * folio itself, so a folio under writeback is one the core is reading
	 * and zeroing it would change bytes it has already read.
	 *
	 * ONLY a punch or a zero range zeroes anything.  A plain allocate is
	 * not a write path: its postcondition is that the range is allocated
	 * and reads back, and the bytes already in it stay.  Zeroing on that
	 * mode destroys them.  Measured: a plain allocate over a written
	 * 200000-byte file left all 200000 bytes zero on this port while
	 * tmpfs and btrfs kept them, and the folio loop was the only thing
	 * that could have written them.  The mode reaches the page cache
	 * only to flush it below.
	 */
	if (mode & (FALLOC_FL_PUNCH_HOLE | FALLOC_FL_ZERO_RANGE)) {
		loff_t pos = offset & ~(loff_t)(PAGE_SIZE - 1);
		struct timespec64 ts;
		uint64_t mtime;

		/*
		 * This is a write, and is bracketed as write_iter brackets one:
		 * the content changes, so the modification time moves as a
		 * write moves it, and the inode is marked modified and queued.
		 * The queueing alone is also hammer2_writepages()'s, for every
		 * dirty folio whatever dirtied it; before it was, a zero range
		 * that extended nothing left the inode on no queue and unmount
		 * scrapped its deletions as unflushed indirect blocks (xfstests
		 * generic/610 read the zeroed bytes back after a remount).
		 */
		hammer2_trans_init(ip->pmp, 0);
		error = 0;
		while (pos < end) {
			struct folio *folio;

			folio = read_mapping_folio(inode->i_mapping,
			    pos >> PAGE_SHIFT, file);
			if (IS_ERR(folio)) {
				error = PTR_ERR(folio);
				break;
			}
			folio_lock(folio);
			folio_wait_stable(folio);
			{
				loff_t zstart = max_t(loff_t, offset,
				    folio_pos(folio));
				loff_t zend = min_t(loff_t, end,
				    folio_pos(folio) + folio_size(folio));

				if (zend > zstart)
					folio_zero_segment(folio,
					    (size_t)(zstart - folio_pos(folio)),
					    (size_t)(zend - folio_pos(folio)));
			}
			folio_mark_dirty(folio);
			folio_unlock(folio);
			/*
			 * Advance past the folio just zeroed, not by a page.
			 * read_mapping_folio() returns the folio CONTAINING
			 * the index, and a block folio covers sixteen pages,
			 * so stepping by a page took the same folio sixteen
			 * times.  The work those repeats do is small, the
			 * lookup being a hash probe on a folio already in
			 * the cache and the zeroing of pages already zeroed
			 * a no-op, so the saving is the walk and not a
			 * sixteenth of the work: a 512 MiB punch measured
			 * 0.734 s against 0.579 s, over three runs each, on
			 * the debug kernel of record.  What the step did
			 * wrong was the walk, taking a folio it had already
			 * finished, and the next folio's index is what the
			 * loop actually wants.
			 */
			pos = (loff_t)(folio_next_index(folio)) << PAGE_SHIFT;
			folio_put(folio);
		}
		hammer2_update_time(&mtime);
		hammer2_mtx_ex(&ip->lock);
		hammer2_inode_modify(ip);
		ip->meta.mtime = mtime;
		ip->meta.ctime = mtime;
		/*
		 * The VFS copies, which stat showed stale until a remount,
		 * set under the lock that stored them.
		 */
		hammer2_time_to_timespec(mtime, &ts);
		inode_set_mtime_to_ts(inode, inode_set_ctime_to_ts(inode, ts));
		hammer2_mtx_unlock(&ip->lock);
		hammer2_trans_done(ip->pmp, HAMMER2_TRANS_SIDEQ);
		if (error)
			return (error);
	}

	error = filemap_write_and_wait_range(inode->i_mapping, offset,
	    end - 1);
	if (error)
		return (error);
	return (0);
}

/*
 * vfs_fallocate() takes no inode lock, so the call takes i_rwsem itself,
 * as ext4_fallocate() does.  Without it the size the call reads at entry
 * could be overtaken by a write before truncate_setsize() set the size to
 * the end of the range, dropping the written pages past it: a writer
 * extending a file beside a racing allocate lost 575 to 1001 of 2048
 * writes in three runs, where tmpfs lost none.
 */
static long
hammer2_fallocate(struct file *file, int mode, loff_t offset, loff_t len)
{
	struct inode *inode = file_inode(file);
	long error;

	inode_lock(inode);
	error = hammer2_fallocate_locked(file, mode, offset, len);
	inode_unlock(inode);
	return (error);
}

const struct file_operations hammer2_file_fops = {
	.llseek		= hammer2_llseek,		/* Linux */
	.read_iter	= generic_file_read_iter,
	.write_iter	= hammer2_file_write_iter,	/* Linux */
	.splice_read	= filemap_splice_read,		/* Linux */
	.splice_write	= iter_file_splice_write,	/* Linux */
	.mmap_prepare	= hammer2_file_mmap_prepare,	/* Linux */
	.fsync		= hammer2_vop_fsync,
	.fallocate	= hammer2_fallocate,		/* Linux: XXX */
	.unlocked_ioctl	= hammer2_ioctl,		/* Linux */
	.setlease	= generic_setlease,		/* Linux */
};

/*
 * Prepare one folio for a write.  The folio is a whole logical block
 * unless memory could not give one, so this is upstream's per-block
 * choice in hammer2_write_file(): a write that covers the folio needs
 * nothing read, a folio past the end of the file is zero, and a partial
 * overwrite reads the folio first, which upstream does with bread() and
 * this does with ->read_folio on the folio it will then hand back
 * locked.  A folio smaller than the block is the same choice made over
 * the part of the block it covers, and the rest of the block is the
 * write XOP's to assemble.
 */
static int
hammer2_write_begin(const struct kiocb *iocb,
    struct address_space *mapping, loff_t pos, unsigned int len,
    struct folio **foliop, void **fsdata __maybe_unused)
{
	struct inode *inode = mapping->host;
	struct folio *folio;
	pgoff_t index = pos >> PAGE_SHIFT, bindex;
	int error;

	/*
	 * Ask for the block, at the block's own index.  The page cache
	 * sizes a new folio by the alignment of the index it is asked at
	 * as well as by the order asked for, so asked at the write's own
	 * page, a write inside a block would get a page whatever memory
	 * held.  Asked at the block's index it gets the block when the
	 * allocation succeeds; when it does not, or when a smaller folio
	 * already sits at that index and stops short of pos, the write
	 * takes the folio at its own page and the write XOP assembles the
	 * block around it.  What the helper adds to the flags is the
	 * uncached one when the iocb carries it.
	 */
	/*
	 * The page cache asks for any order above the mapping's minimum
	 * with __GFP_NORETRY, so under fragmentation the block folio fails
	 * at once and the write takes pages.  The write XOP turns each page
	 * into a whole block, and each after the first into a fresh one by
	 * the core's dedup rule: sixteen blocks of media for one block of
	 * data, none of it counted by the reserve, which is what lost four
	 * files of a fill.  So the block folio is allocated here with the
	 * mapping's own mask, which retries reclaim and compaction before
	 * failing, and the page cache is asked only when that fails or a
	 * folio already sits in the block.  A failure is expected and has
	 * its fallback, so it is not reported as the page cache's own
	 * order request does not report it.
	 */
	bindex = index & ~(pgoff_t)((HAMMER2_PBUFSIZE >> PAGE_SHIFT) - 1);
	folio = filemap_alloc_folio(mapping_gfp_mask(mapping) | __GFP_NOWARN,
	    HAMMER2_PBUFRADIX - PAGE_SHIFT, NULL);
	if (folio) {
		if (iocb && (iocb->ki_flags & IOCB_DONTCACHE))
			__folio_set_dropbehind(folio);
		if (filemap_add_folio(mapping, folio, bindex,
		    mapping_gfp_mask(mapping)) != 0) {
			folio_put(folio);
			folio = NULL;
		}
	}
	if (folio == NULL) {
		pr_debug("hammer2: no block folio at %llx, asking the cache\n",
		    (unsigned long long)bindex << PAGE_SHIFT);
		folio = write_begin_get_folio(iocb, mapping, bindex,
		    HAMMER2_PBUFSIZE);
	}
	if (!IS_ERR(folio) && folio_next_index(folio) <= index) {
		folio_unlock(folio);
		folio_put(folio);
		folio = write_begin_get_folio(iocb, mapping, index, len);
	}
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
/*
 * The other dirty folios of the block a folio smaller than the block
 * belongs to, taken out of the dirty set and put under writeback here so
 * the write XOP lays them all into the one block write.  Written one
 * folio per XOP, a split block took fresh media for every folio after
 * the first, since the core registers a data block for dedup as its
 * bytes go out and will not overwrite a registered block: sixteen
 * blocks of media for one block of data, none of it counted by the
 * write entry's reserve, which is what lost four files of a fill.  A
 * sibling that is locked or already under writeback is left to its own
 * XOP.  Each folio added carries a reference the caller releases once
 * the XOP has ended its writeback.
 */
static void
hammer2_gather_block(struct address_space *mapping, struct folio *folio,
    struct folio_batch *siblings)
{
	struct folio_batch found;
	struct folio *f;
	pgoff_t start, end;
	unsigned int i;

	start = folio->index & ~(pgoff_t)((HAMMER2_PBUFSIZE >> PAGE_SHIFT) - 1);
	end = start + (HAMMER2_PBUFSIZE >> PAGE_SHIFT) - 1;
	folio_batch_init(&found);
	if (filemap_get_folios_tag(mapping, &start, end, PAGECACHE_TAG_DIRTY,
	    &found) == 0)
		return;
	for (i = 0; i < folio_batch_count(&found); i++) {
		f = found.folios[i];
		if (f == folio || !folio_trylock(f))
			continue;
		if (f->mapping == mapping && !folio_test_writeback(f) &&
		    folio_clear_dirty_for_io(f)) {
			folio_start_writeback(f);
			folio_get(f);
			folio_batch_add(siblings, f);
		}
		folio_unlock(f);
	}
	folio_batch_release(&found);
}

/*
 * Linux: the debug build's write_except, an element index or -1, writes
 * each block on every element but that one, through upstream's
 * hammer2_xop_start_except(), so a test can make two MASTERs hold
 * different blocks of one file without a crash (script/cluster-quorum.sh).
 */
#if defined(HAMMER2_LOCKDEBUG)
static int hammer2_write_except = -1;
module_param_named(write_except, hammer2_write_except, int, 0644);
#define HAMMER2_WRITE_EXCEPT	READ_ONCE(hammer2_write_except)
#else
#define HAMMER2_WRITE_EXCEPT	(-1)
#endif

static int
hammer2_writepages(struct address_space *mapping,
    struct writeback_control *wbc)
{
	hammer2_inode_t *ip = VTOI(mapping->host);
	hammer2_xop_strategy_t *xop;
	struct folio *folio = NULL;
	struct folio_batch siblings;
	bool wrote = false;
	int error = 0;

	while ((folio = writeback_iter(mapping, wbc, folio, &error)) != NULL) {
		wrote = true;
		folio_start_writeback(folio);
		folio_unlock(folio);
		folio_batch_init(&siblings);
		if (folio_size(folio) < HAMMER2_PBUFSIZE)
			hammer2_gather_block(mapping, folio, &siblings);

		atomic_set_int(&ip->flags, HAMMER2_INODE_DIRTYDATA);
		hammer2_trans_assert_strategy(ip->pmp);
		hammer2_trans_init(ip->pmp, HAMMER2_TRANS_BUFCACHE);
		xop = hammer2_xop_alloc(ip,
		    HAMMER2_XOP_MODIFYING | HAMMER2_XOP_STRATEGY);
		xop->folio = folio;
		xop->siblings = &siblings;
		xop->lbase = folio_pos(folio);
		hammer2_xop_start_except(&xop->head,
		    &hammer2_strategy_write_desc, HAMMER2_WRITE_EXCEPT);
		hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);
		folio_batch_release(&siblings);
		error = 0;
	}
	/*
	 * Linux: the sync reaches an inode's chains through the sync queue
	 * alone, and the flush stops at an inode it does not find there
	 * (HAMMER2_FLUSH_INODE_STOP), so an inode whose blocks the strategy
	 * has just written or deleted is queued here, after the writes, as
	 * write_iter queues after its write.  Upstream needs no such line:
	 * its sync scans every vnode for dirty buffers and requeues the
	 * inode behind them (hammer2_vfs_sync_pmp(), the vclrisdirty()
	 * branch).  Here a folio dirtied through a mapping, or by the zero
	 * range of fallocate(2), reached the strategy with its inode on no
	 * queue, and sync(2) and unmount both left the new blocks
	 * unreferenced: a mapped write to a synced file read back as the old
	 * bytes after a remount, and xfstests generic/610's zero range came
	 * back.  No folio lock is held here, and no caller of writeback
	 * holds ip->lock, which the sync's own writeback moved out from
	 * under it for the write_end() cycle described there.
	 */
	if (wrote) {
		hammer2_mtx_ex(&ip->lock);
		hammer2_inode_delayed_sideq(ip);
		hammer2_mtx_unlock(&ip->lock);
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
	.readahead	= hammer2_readahead,		/* Linux */
	.dirty_folio	= filemap_dirty_folio,		/* Linux */
	.write_begin	= hammer2_write_begin,		/* Linux */
	.write_end	= hammer2_write_end,		/* Linux */
	.writepages	= hammer2_writepages,		/* Linux */
	.migrate_folio	= filemap_migrate_folio,	/* Linux */
	.bmap		= hammer2_bmap,			/* Linux */
};

/*
 * Linux: fiemap, the extent map ioctl (FIEMAP).  Neither DragonFly nor
 * any BSD port has it; of the four, only the FreeBSD port answers the
 * seek ioctls FIOSEEKDATA and FIOSEEKHOLE, which ->llseek above answers
 * here, and the other three refuse them with EOPNOTSUPP.  FIEMAP is what
 * filefrag(8), lvm, and a defragmenter read to learn where a file's
 * blocks are.
 *
 * The map is the seek's tree read with each block's blockref kept
 * (HAMMER2_SEEK_MODE_MAP, hammer2_seek_tree()), HAMMER2_FIEMAP_REFS blocks
 * at a time, under i_rwsem shared for the whole call as xfs_vn_fiemap(),
 * ext4_fiemap() and btrfs_fiemap() hold it, with the page cache's dirty and
 * writeback tags read before the tree as SEEK_DATA reads them.
 *
 * Each block is an extent at its own data_off with the low six bits, the
 * stored size's radix, masked off.  A compressed block, whose stored size
 * is not its logical one and whose bytes at that address are not the
 * file's, is reported alone with FIEMAP_EXTENT_ENCODED and its logical
 * length.  Adjacent uncompressed blocks that are adjacent on the media are
 * merged, with FIEMAP_EXTENT_MERGED, since two blocks are two allocations
 * and the caller is told a physical run, not that it was allocated
 * together.  A block only a remote element holds has no address on this
 * host and is FIEMAP_EXTENT_UNKNOWN (hammer2_bmap_offset()).  A block the
 * tree does not hold whose folio is tagged dirty or under writeback is
 * FIEMAP_EXTENT_DELALLOC, which the kernel marks unknown as well; the map
 * writes nothing back unless the caller asks with FIEMAP_FLAG_SYNC, which
 * fiemap_prep() honours.  A hole is skipped.  The extents are copied out
 * with no hammer2 lock held, since a copy can fault.
 */
#define HAMMER2_FIEMAP_REFS	1024		/* Linux: blocks per tree read */
/*
 * Linux: hammer2_fiemap() reads a batch shorter than HAMMER2_FIEMAP_REFS as
 * the end of the range, and the vote clamps a map's batch to its own size.
 */
static_assert(HAMMER2_SEEK_VOTE_REFS >= HAMMER2_FIEMAP_REFS);

/*
 * Linux: the extent being built, and the step that adds one block's worth
 * to it or emits it and starts the next.  Returns 1 when the caller's
 * array is full, as fiemap_fill_next_extent() does.
 */
struct hammer2_fiemap_run {			/* Linux */
	u64	logical;
	u64	phys;
	u64	len;
	u32	flags;
};

static int
hammer2_fiemap_flush(struct fiemap_extent_info *fieinfo,
    struct hammer2_fiemap_run *r, u32 last)
{
	int ret = 0;

	if (r->len)
		ret = fiemap_fill_next_extent(fieinfo, r->logical, r->phys,
		    r->len, r->flags | last);
	r->len = 0;
	return (ret);
}

static int
hammer2_fiemap_add(struct fiemap_extent_info *fieinfo,
    struct hammer2_fiemap_run *r, u64 logical, u64 phys, u64 len, u32 flags)
{
	int ret;

	if (r->len && logical == r->logical + r->len && flags == r->flags &&
	    !(flags & FIEMAP_EXTENT_ENCODED) &&
	    ((flags & (FIEMAP_EXTENT_UNKNOWN | FIEMAP_EXTENT_DELALLOC)) ||
	    phys == r->phys + r->len)) {
		r->len += len;
		return (0);
	}
	ret = hammer2_fiemap_flush(fieinfo, r, 0);
	if (ret != 0)
		return (ret);
	r->logical = logical;
	r->phys = phys;
	r->len = len;
	r->flags = flags;
	return (0);
}

/*
 * Linux: the blocks in [from, *top] whose folios are tagged dirty or
 * under writeback, at most max of them, into t; *np is how many.  When t
 * fills, *top is lowered to just before the first block left out, so the
 * caller scans the tree no further than the tags it read.
 */
static void
hammer2_fiemap_tags(struct address_space *mapping, loff_t from, loff_t *top,
    u32 bsize, loff_t *t, int max, int *np)
{
	loff_t pos;
	int n = 0;

	while (from <= *top &&
	    (pos = hammer2_seek_tagged(mapping, from, *top)) >= 0) {
		pos &= ~((loff_t)bsize - 1);
		if (n == max) {
			*top = pos - 1;
			break;
		}
		t[n++] = pos;
		from = pos + bsize;
	}
	*np = n;
}

static int
hammer2_fiemap(struct inode *inode, struct fiemap_extent_info *fieinfo,
	u64 start, u64 len)
{
	struct address_space *mapping = inode->i_mapping;
	struct hammer2_fiemap_run run = { 0 };
	struct hammer2_seek_req r = { 0 };
	struct hammer2_fiemap_ref *v;
	loff_t *t;
	u32 bsize = i_blocksize(inode);
	loff_t isize, cur, end, cend, next;
	u64 llen, plen;
	u32 flags;
	bool tagged;
	int error, ret = 0, i, j, n, nt;

	error = fiemap_prep(inode, fieinfo, start, &len, 0);
	if (error)
		return (error);
	v = kvmalloc_array(HAMMER2_FIEMAP_REFS, sizeof(*v), GFP_KERNEL);
	t = kvmalloc_array(HAMMER2_FIEMAP_REFS, sizeof(*t), GFP_KERNEL);
	if (v == NULL || t == NULL) {
		kvfree(v);
		kvfree(t);
		return (-ENOMEM);
	}

	inode_lock_shared(inode);
	isize = i_size_read(inode);
	/*
	 * A file of HAMMER2_EMBEDDED_BYTES or less keeps its data in the
	 * inode and has no data block.  As the seek answers it whole, it is
	 * one extent from 0, reported as btrfs reports an inline extent,
	 * FIEMAP_EXTENT_DATA_INLINE at physical 0.
	 */
	if (VTOI(inode)->meta.op_flags & HAMMER2_OPFLAG_DIRECTDATA) {
		if (start < (u64)isize)
			ret = fiemap_fill_next_extent(fieinfo, 0, 0, isize,
			    FIEMAP_EXTENT_DATA_INLINE | FIEMAP_EXTENT_LAST);
		error = 0;
		goto out;
	}
	cur = (loff_t)start & ~((loff_t)bsize - 1);
	end = (start + len > (u64)isize || start + len < start) ? isize :
	    (loff_t)(start + len);
	r.mode = HAMMER2_SEEK_MODE_MAP;
	r.v = v;
	r.max = HAMMER2_FIEMAP_REFS;
	while (cur < end) {
		cend = end - 1;
		tagged = mapping_tagged(mapping, PAGECACHE_TAG_DIRTY) ||
		    mapping_tagged(mapping, PAGECACHE_TAG_WRITEBACK);
		/*
		 * The tags are read before the tree, as SEEK_DATA reads them.
		 * A folio leaves its tags only after its chain is in the
		 * tree, or after a failed writeback, whose block the map
		 * omits as the seek calls it a hole (hammer2_seek_data_hole()).
		 * So a block tagged here is either in the tree read
		 * that follows, which is the answer reported, or DELALLOC; a
		 * tag read after the tree read could find a writeback that
		 * ended between the two and call its block neither.  At most
		 * HAMMER2_FIEMAP_REFS tagged blocks are kept, and the tree read
		 * ends before the first one left out.
		 */
		nt = 0;
		if (tagged) {
			hammer2_fiemap_tags(mapping, cur, &cend, bsize, t,
			    HAMMER2_FIEMAP_REFS, &nt);
			HAMMER2_DEBUG_HOLD(hammer2_seek_tag_hold_ms, "seek tag");
		}
		r.key_beg = (hammer2_key_t)cur;
		r.key_end = (hammer2_key_t)cend;
		error = hammer2_seek_tree(inode, &r);
		if (error != 0)
			break;
		n = r.n;
		next = (n == HAMMER2_FIEMAP_REFS) ? (loff_t)r.key : cend + 1;
		for (i = 0, j = 0; i <= n && ret == 0; ++i) {
			loff_t gap_end = (i < n) ? (loff_t)v[i].key - 1 : next - 1;

			/* a tag under a chain read below cur is the chain's */
			for (; j < nt && t[j] <= gap_end && ret == 0; ++j)
				if (t[j] >= cur)
					ret = hammer2_fiemap_add(fieinfo, &run,
					    t[j], 0, bsize,
					    FIEMAP_EXTENT_MERGED |
					    FIEMAP_EXTENT_DELALLOC);
			if (ret != 0 || i == n)
				break;
			llen = (u64)1 << v[i].keybits;
			flags = FIEMAP_EXTENT_MERGED;
			plen = 0;
			if (v[i].poff == HAMMER2_BMAP_UNKNOWN ||
			    (v[i].poff & ~HAMMER2_OFF_MASK_RADIX) == 0)
				flags |= FIEMAP_EXTENT_UNKNOWN;
			else if (v[i].poff & HAMMER2_OFF_MASK_RADIX)
				plen = (u64)1 << (v[i].poff &
				    HAMMER2_OFF_MASK_RADIX);
			if (!(flags & FIEMAP_EXTENT_UNKNOWN) &&
			    (HAMMER2_DEC_COMP(v[i].methods) != HAMMER2_COMP_NONE ||
			    plen != llen))
				flags |= FIEMAP_EXTENT_ENCODED;
			ret = hammer2_fiemap_add(fieinfo, &run, v[i].key,
			    (flags & FIEMAP_EXTENT_UNKNOWN) ? 0 :
			    v[i].poff & ~HAMMER2_OFF_MASK_RADIX, llen, flags);
			cur = (loff_t)(v[i].key + llen);
		}
		if (ret != 0)
			break;
		cur = next;
	}
	if (error == 0 && ret == 0)
		ret = hammer2_fiemap_flush(fieinfo, &run,
		    run.logical + run.len >= (u64)isize ? FIEMAP_EXTENT_LAST : 0);
out:
	inode_unlock_shared(inode);
	kvfree(t);
	kvfree(v);
	if (error != 0)
		return (hammer2_vfs_errno(error));
	return (ret < 0 ? ret : 0);
}

/*
 * A regular file's inode operations.  The VFS reads size, mode, owner
 * and times out of the inode itself, which hammer2_igetv() fills, so
 * stat needs nothing here; setting them, and the size, is ->setattr.
 */
/*
 * Linux: the block count, computed per call.
 *
 * st_blocks is how du, cp --sparse and every backup tool decide what a
 * file occupies, and i_blocks is what generic_fillattr() copies into
 * it.  The value comes from the inode's own blockref counter, which the
 * flush maintains, so it is only as fresh as the inode's cached meta.
 *
 * hammer2_igetv() sets i_blocks once, when the inode is first read in.
 * A file that then grows in this mount keeps reporting the allocation it
 * had at that moment: measured on a fresh volume, a 512 KiB file written
 * in one mount reported 0 blocks of 512, and the same file reported 1056
 * after a remount, which is where the number on media is read back.
 * Upstream has no such window, because hammer2_getattr() computes
 * va_bytes inside getattr() and every stat therefore re-derives it.
 *
 * So this is upstream's arrangement rather than a new one: getattr
 * recomputes both fields the same way hammer2_getattr() does, and the
 * assignment in hammer2_igetv() stays for the inode's first reader.
 */
static int
hammer2_getattr(struct mnt_idmap *idmap, const struct path *path,
	struct kstat *stat, u32 request_mask __maybe_unused,
	unsigned int flags)
{
	struct inode *inode = d_inode(path->dentry);
	hammer2_inode_t *ip = VTOI(inode);

	generic_fillattr(idmap, request_mask, inode, stat);

	/*
	 * The same two lines hammer2_igetv() writes at instantiation,
	 * repeated here because stat is answered from the inode's cached
	 * meta and that meta moves as the file does.  hammer2_inode_lock()
	 * is what the core requires before reading an inode's meta.
	 */
	hammer2_inode_lock(ip, HAMMER2_RESOLVE_SHARED);
	if (S_ISDIR(inode->i_mode))
		stat->blocks = HAMMER2_INODE_BYTES >> 9;
	else
		stat->blocks = hammer2_inode_data_count(ip) >> 9;
	hammer2_inode_unlock(ip);

	return (0);
}

/*
 * The kernel asks for a modification stamp here, from file_update_time()
 * under write(2), a write through a mapping (filemap_page_mkwrite()) and
 * a write into a fifo (pipe_write()), and for an access stamp from
 * touch_atime().  Without it generic_update_time() stamped the VFS inode
 * from the kernel's clock and the media never heard of a write through a
 * mapping, so its file read the old mtime back after a remount, and a
 * write(2) copied the kernel's stamp to the media after the fact, where
 * two writers could leave stat with one writer's stamp and the media
 * with the other's.  The stamp is hammer2_update_time()'s, the clock
 * every stamp this filesystem stores is read from, and the VFS copy is
 * set under the lock that stores it.  The access time a read stamps is
 * not stored (the mtime-as-atime decision in doc/README.porting.md), so
 * that one stays the kernel's; under HAMMER2_ATIME it is stored like the
 * others, since a build that reports the stored atime and never stores a
 * read's reads the create's back after every remount.  A nowait write
 * cannot take the inode lock, which is the answer generic_update_time()
 * gives for a filesystem that dirties its inodes itself.
 */
static int
hammer2_vfs_update_time(struct inode *inode, enum fs_update_time type,
    unsigned int flags)
{
	hammer2_inode_t *ip = VTOI(inode);
	struct timespec64 ts;
	uint64_t now;

#ifndef HAMMER2_ATIME
	if (type != FS_UPD_CMTIME)
		return (generic_update_time(inode, type, flags));
#endif
	if (flags & IOCB_NOWAIT)
		return (-EAGAIN);
	if (READ_ONCE(hammer2_device_error))
		return (-EIO);
	if (ip->pmp->rdonly)
		return (-EROFS);
	hammer2_trans_init(ip->pmp, 0);
	hammer2_mtx_ex(&ip->lock);
	hammer2_update_time(&now);
	hammer2_inode_modify(ip);
	hammer2_time_to_timespec(now, &ts);
	if (type == FS_UPD_ATIME) {
		ip->meta.atime = now;
		inode_set_atime_to_ts(inode, ts);
	} else {
		ip->meta.mtime = now;
		ip->meta.ctime = now;
		inode_set_mtime_to_ts(inode, inode_set_ctime_to_ts(inode, ts));
	}
	hammer2_mtx_unlock(&ip->lock);
	hammer2_trans_done(ip->pmp, HAMMER2_TRANS_SIDEQ);
	return (0);
}

const struct inode_operations hammer2_file_iops = {
	.setattr	= hammer2_vop_setattr,
	.getattr	= hammer2_getattr,		/* Linux */
	.update_time	= hammer2_vfs_update_time,	/* Linux */
	.fiemap		= hammer2_fiemap,		/* Linux */
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
	.getattr	= hammer2_getattr,		/* Linux */
	.update_time	= hammer2_vfs_update_time,	/* Linux */
	.setattr	= hammer2_vop_setattr,
};

/*
 * A device node, fifo or socket: its file operations are the kernel's,
 * from init_special_inode(), and only its attributes are this
 * filesystem's.
 */
const struct inode_operations hammer2_special_iops = {
	.getattr	= hammer2_getattr,		/* Linux */
	.update_time	= hammer2_vfs_update_time,	/* Linux */
	.setattr	= hammer2_vop_setattr,
};
