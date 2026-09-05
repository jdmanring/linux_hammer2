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

#include <linux/pagemap.h>	/* Linux: __filemap_get_folio, folio_* */
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
			inc_nlink(dir);			/* Linux */
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
			drop_nlink(dir);		/* Linux */
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

const struct inode_operations hammer2_dir_iops = {
	.lookup		= hammer2_vop_lookup,
	.create		= hammer2_vop_create,
	.mknod		= hammer2_vop_mknod,
	.mkdir		= hammer2_vop_mkdir,
	.symlink	= hammer2_vop_symlink,
	.unlink		= hammer2_vop_unlink,
	.rmdir		= hammer2_vop_rmdir,
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
const struct file_operations hammer2_dir_fops = {
	.llseek		= generic_file_llseek,
	.read		= generic_read_dir,
	.iterate_shared	= hammer2_vop_readdir,
};

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
 *
 * XXX Linux: the mount is refused read-write in the shipped module, so
 * this is reached only under HAMMER2_RW_EXPERIMENT; the VFS refuses the
 * open for writing on a read-only superblock before this is called.
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

const struct file_operations hammer2_file_fops = {
	.llseek		= generic_file_llseek,
	.read_iter	= generic_file_read_iter,
	.write_iter	= hammer2_file_write_iter,	/* Linux */
	.fsync		= hammer2_vop_fsync,
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
hammer2_write_begin(const struct kiocb *iocb __maybe_unused,
    struct address_space *mapping, loff_t pos, unsigned int len,
    struct folio **foliop, void **fsdata __maybe_unused)
{
	struct inode *inode = mapping->host;
	struct folio *folio;
	int error;

	folio = __filemap_get_folio(mapping, pos >> PAGE_SHIFT,
	    FGP_WRITEBEGIN, mapping_gfp_mask(mapping));
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
 * DEFER(the write path lands: 0.5): what is here writes a file in
 * place, extends it, truncates it and syncs it, and creates and removes
 * names; nothing here renames or links.  There is no ->invalidate_folio
 * because no folio carries private data.
 */
const struct address_space_operations hammer2_file_aops = {
	.read_folio	= hammer2_read_folio,
	.dirty_folio	= filemap_dirty_folio,		/* Linux */
	.write_begin	= hammer2_write_begin,		/* Linux */
	.write_end	= hammer2_write_end,		/* Linux */
	.writepages	= hammer2_writepages,		/* Linux */
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
