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

const struct inode_operations hammer2_dir_iops = {
	.lookup		= hammer2_vop_lookup,
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
const struct file_operations hammer2_file_fops = {
	.llseek		= generic_file_llseek,
	.read_iter	= generic_file_read_iter,
};

/*
 * DEFER(the write path lands: 0.5): no ->writepages and no
 * ->write_begin, so the mapping is read-only, which is what the mount is.
 */
const struct address_space_operations hammer2_file_aops = {
	.read_folio	= hammer2_read_folio,
};

/*
 * A regular file has an operations table so that i_op is never NULL on
 * an inode this module hands the VFS, and no methods in it.  The VFS
 * reads size, mode, owner and times out of the inode itself, which
 * hammer2_igetv() fills, so stat needs nothing here.
 */
const struct inode_operations hammer2_file_iops = {
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
};
