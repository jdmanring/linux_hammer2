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
 * DEFER(the read path lands, with ->read_folio): a regular file gets an
 * inode_operations and a file_operations with no methods in either, so
 * it can be looked up, stat'd and opened, and read fails EINVAL.
 * ->iterate_shared is the other half of a usable directory and is
 * upstream's hammer2_readdir().
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
		hammer2_inode_unlock(ip);
		hammer2_inode_drop(ip);
	}

	/*
	 * The retire is last, as it is upstream: hammer2_inode_get() reads
	 * the cluster this XOP owns.
	 */
	hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);

	if (error && error != ENOENT)
		return (ERR_PTR(-error));	/* Linux: negative */

	return (d_splice_alias(inode, dentry));
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
 * DEFER(the read path lands, with ->read_folio): the directory table has
 * no ->iterate_shared, which iterate_dir() in fs/readdir.c reports as
 * ENOTDIR and nothing else, so a readdir fails cleanly.  Its content is
 * upstream's hammer2_readdir().  The regular-file table is empty, which
 * leaves FMODE_CAN_READ unset in do_dentry_open() and makes a read fail
 * EINVAL, again with no warning: an open succeeds and reads do not.
 */
const struct file_operations hammer2_dir_fops = {
	.llseek		= generic_file_llseek,
	.read		= generic_read_dir,
};

const struct file_operations hammer2_file_fops = {
};

/*
 * DEFER(the read path lands, with ->read_folio): a regular file has an
 * operations table so that i_op is never NULL on an inode this module
 * hands the VFS, and no methods in it.  The VFS reads size, mode, owner
 * and times out of the inode itself, which hammer2_igetv() fills, so
 * stat works and open does not.
 */
const struct inode_operations hammer2_file_iops = {
};
