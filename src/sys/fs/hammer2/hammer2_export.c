// SPDX-License-Identifier: BSD-3-Clause
/*
 * Copyright (c) 2026 James Manring.  All rights reserved.
 *
 * The Linux file-handle surface, which is this port's and not carried from
 * any BSD tree: DragonFly reaches NFS through vfsops (vfs_vptofh,
 * vfs_fhtovp, vfs_checkexp) and each BSD port registers one or two of the
 * same three, while Linux asks the filesystem for an export_operations
 * table instead.  The encoding is DragonFly's and the interface is the
 * kernel's.
 *
 * The handle carries the inode number, masked with HAMMER2_DIRHASH_USERMSK
 * as DragonFly's hammer2_vfs_vptofh() masks it, and for a connectable
 * handle the parent's.  The generation field is zero, which the kernel
 * reads as "accept any": HAMMER2 allocates inode numbers from
 * pmp->inode_tid with atomic_fetchadd_64() (hammer2_trans_newinum(),
 * hammer2_flush.c), so a number is never reused within a PFS and a handle
 * for a removed inode resolves to ENOENT rather than to a different inode.
 * A generation would only be needed to tell those two apart.
 *
 * The reverse lookup is the FreeBSD port's hammer2_vget()
 * (freebsd_hammer2 hammer2_vfsops.c), which is this port's closest sibling
 * and needs no new machinery here: the by-inum lookup is hammer2_lookup_desc
 * + hammer2_xop_lookup(), the same pair hammer2_checkpath() drives in
 * hammer2_inode.c.
 *
 * For the kernel's contract, read against the kernel of record:
 *   exportfs_may_export() needs fh_to_dentry and sets no ->open/->permission.
 *   fh_to_parent is needed to ENCODE a connectable handle, which nfsd asks
 *   for unless the export sets no_subtree_check (fs/nfsd/nfsfh.c).
 *   get_parent is needed to RECONNECT a detached directory dentry
 *   (fs/exportfs/expfs.c, reconnect_path -> reconnect_one).
 * So all four are registered; without fh_to_parent the default export fails
 * to encode, and without get_parent a directory handle does not resolve.
 */
#include "hammer2.h"

#include <linux/exportfs.h>

/*
 * The parent form of the handle, which the kernel's FILEID_INO64_GEN_PARENT
 * documents as a 64-bit inode number, a 32-bit generation, a 64-bit parent
 * inode number and a 32-bit parent generation: 24 bytes, no padding, so the
 * parent's inode number begins at word 3.  struct fid has an i64 member for
 * the three-word form only, so this is packed over fid->raw, on the same
 * terms as the kernel's own generic_encode_ino32_fh().
 */
struct hammer2_fid_parent {
	uint64_t ino;
	uint32_t gen;
	uint64_t parent_ino;
	uint32_t parent_gen;
} __packed;

#define HAMMER2_FH_INO64_LEN	3	/* struct fid.i64, in 32-bit words */
#define HAMMER2_FH_PARENT_LEN	6	/* struct hammer2_fid_parent, ditto */

_Static_assert(sizeof(struct hammer2_fid_parent) == 24,
    "FILEID_INO64_GEN_PARENT is 6 words");

/*
 * Reverse lookup: inode number to a referenced hammer2 inode, the FreeBSD
 * port's hammer2_vget() with the PFS already resolved.
 *
 * The easy path is the in-memory hash, which a live mount keeps inode
 * numbers in; otherwise the by-inum chain lookup runs off the PFS root, the
 * same XOP hammer2_checkpath() uses.  Both return the inode LOCKED holding
 * one reference, which hammer2_inode_unlock() releases, the state
 * hammer2_inode_get() returns: the cached path takes its own lock with
 * hammer2_inode_lock() and drops the lookup's reference, as the FreeBSD
 * port's hammer2_vget() does, and the lookup path is already in that state.
 */
static hammer2_inode_t *
hammer2_vget(hammer2_pfs_t *pmp, hammer2_tid_t inum)
{
	hammer2_xop_lookup_t *xop;
	hammer2_inode_t *ip;
	int error;

	ip = hammer2_inode_lookup(pmp, inum);
	if (ip) {
		hammer2_inode_lock(ip, HAMMER2_RESOLVE_SHARED);
		hammer2_inode_drop(ip);	/* from lookup */
		return (ip);
	}

	xop = hammer2_xop_alloc(pmp->iroot, 0);
	xop->lhc = inum;
	hammer2_xop_start(&xop->head, &hammer2_lookup_desc);
	error = hammer2_error_to_errno(hammer2_xop_collect(&xop->head, 0));
	if (error == 0)
		ip = hammer2_inode_get(pmp, &xop->head, -1, -1);
	else
		ip = NULL;
	hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);

	return (ip);
}

/*
 * A superblock and an inode number to a disconnected dentry.
 *
 * Inode number 1 is the PFS root, which DragonFly's hammer2_vfs_fhtovp()
 * special-cases the same way rather than finding it through the lookup.  The
 * root is locked here with hammer2_inode_lock(), which takes the one
 * reference hammer2_inode_unlock() releases, so all three paths leave this
 * function with a locked inode holding exactly one owned reference and a
 * single unlock is the whole release.
 */
static struct dentry *
hammer2_get_inode(struct super_block *sb, hammer2_tid_t inum)
{
	hammer2_pfs_t *pmp = MPTOPMP(sb);
	hammer2_inode_t *ip;
	struct inode *inode;
	int error;

	inum &= HAMMER2_DIRHASH_USERMSK;

	if (inum == 1) {
		ip = pmp->iroot;
		if (ip == NULL)
			return (ERR_PTR(-ESTALE));
		hammer2_inode_lock(ip, HAMMER2_RESOLVE_SHARED);
	} else {
		ip = hammer2_vget(pmp, inum);
		if (ip == NULL)
			return (ERR_PTR(-ESTALE));
	}
	if (ip->meta.inum != inum) {
		/*
		 * A by-number lookup that returned a different inode is a
		 * defect, and hammer2_chain_inode_find() treats it as one.
		 */
		hammer2_inode_unlock(ip);
		return (ERR_PTR(-ESTALE));
	}
	/*
	 * An inode whose last link went but whose chain has not been
	 * reclaimed yet is still findable by number, and hammer2_igetv()
	 * warns on its zero links and clamps them to one.  A handle must
	 * not resurrect it: ext4 answers the same case with ESTALE
	 * (EXT4_IGET_HANDLE and a zero link count and mode, fs/ext4/inode.c),
	 * and a removed file is what a stale handle is.  Read under the
	 * inode lock taken above.  The gate found this: without it,
	 * hammer2-fh.c's unlink check still passed, because the removed
	 * file does not answer a normal name lookup, but the decode warned
	 * at hammer2_inode.c:801 on the way.
	 */
	if (ip->meta.nlinks == 0) {
		hammer2_inode_unlock(ip);
		return (ERR_PTR(-ESTALE));
	}

	error = hammer2_igetv(ip, 0, &inode);
	hammer2_inode_unlock(ip);

	if (error)
		return (ERR_PTR(-hammer2_vfs_errno(error)));	/* Linux */
	return (d_obtain_alias(inode));
}

/*
 * The file-handle encoder, reached through exportfs_encode_fh() from
 * name_to_handle_at(2) and from nfsd's fh_compose().
 *
 * The parent is encoded only when the kernel passes one, which it does for a
 * connectable request and a non-directory (exportfs_encode_fh()).
 *
 * A request that does not fit returns FILEID_INVALID with *max_len set to the
 * size needed in 32-bit words, the size-out protocol the kernel's own
 * exportfs_encode_ino64_fid() uses, and the caller retries with that size.
 *
 * When the kernel passes a parent it is asking for a CONNECTABLE handle, and
 * this must not answer with the shorter type instead: that handle carries no
 * parent, so a subtree-checked export cannot reconnect it and the decode
 * falls to find_acceptable_alias alone (fs/exportfs/expfs.c).  A connectable
 * request that does not fit is therefore refused with the size needed, not
 * degraded.  Measured: with the fallthrough, 3, 4 and 5 words all returned
 * the non-parent type.
 */
static int
hammer2_encode_fh(struct inode *inode, __u32 *fh, int *max_len,
    struct inode *parent)
{
	int len = *max_len;

	if (parent) {
		struct hammer2_fid_parent *fhp;

		if (len < HAMMER2_FH_PARENT_LEN) {
			*max_len = HAMMER2_FH_PARENT_LEN;
			return (FILEID_INVALID);
		}
		fhp = (void *)fh;
		fhp->ino = inode->i_ino;
		fhp->gen = inode->i_generation;
		fhp->parent_ino = parent->i_ino;
		fhp->parent_gen = parent->i_generation;
		*max_len = HAMMER2_FH_PARENT_LEN;
		return (FILEID_INO64_GEN_PARENT);
	}
	if (len < HAMMER2_FH_INO64_LEN) {
		*max_len = HAMMER2_FH_INO64_LEN;
		return (FILEID_INVALID);
	}
	((struct fid *)fh)->i64.ino = inode->i_ino;
	((struct fid *)fh)->i64.gen = inode->i_generation;
	*max_len = HAMMER2_FH_INO64_LEN;
	return (FILEID_INO64_GEN);
}

/*
 * The decoder, from both fh_to_dentry and fh_to_parent.  The inode number is
 * at word 0 in both forms; the parent form carries the parent's at word 3.
 * A type this port did not write, or a fragment too short for the type,
 * returns NULL, which the kernel reads as not found.
 */
static struct dentry *
hammer2_fh_to_dentry(struct super_block *sb, struct fid *fid, int fh_len,
    int fh_type)
{
	hammer2_tid_t inum;

	switch (fh_type) {
	case FILEID_INO64_GEN:
		if (fh_len < HAMMER2_FH_INO64_LEN)
			return (NULL);
		inum = fid->i64.ino;
		break;
	case FILEID_INO64_GEN_PARENT:
		if (fh_len < HAMMER2_FH_PARENT_LEN)
			return (NULL);
		inum = ((struct hammer2_fid_parent *)fid->raw)->ino;
		break;
	default:
		return (NULL);
	}

	return (hammer2_get_inode(sb, inum));
}

static struct dentry *
hammer2_fh_to_parent(struct super_block *sb, struct fid *fid, int fh_len,
    int fh_type)
{
	hammer2_tid_t inum;

	if (fh_type != FILEID_INO64_GEN_PARENT ||
	    fh_len < HAMMER2_FH_PARENT_LEN)
		return (NULL);
	inum = ((struct hammer2_fid_parent *)fid->raw)->parent_ino;

	return (hammer2_get_inode(sb, inum));
}

/*
 * The parent of a child directory, for reconnect_path().  The inode holds
 * its parent's number in meta.iparent, the same field hammer2_checkpath()
 * walks, so no lookup is needed.
 *
 * "No parent" is an error return and never NULL: reconnect_one() checks
 * IS_ERR(parent) and nothing else, then hands the pointer to
 * exportfs_get_name(), so a NULL here is a kernel oops from a decoded
 * handle.  btrfs_get_parent() returns ERR_PTR on every such path.  The PFS
 * root has no parent, and neither does an inode whose iparent is unset or
 * points at itself; all three answer ESTALE.  A disconnected dentry is
 * always IS_ROOT, so IS_ROOT cannot stand for "at the root" and is not
 * tested.
 *
 * meta.iparent is read under the inode lock, not the caller's i_rwsem.
 * reconnect_one() holds child->d_inode->i_rwsem, which stops a lookup from
 * racing this, but iparent is written by the rename path with that same
 * inode's hammer2 lock held and nothing else (hammer2_vop_rename(),
 * hammer2_inode_modify() takes no lock of its own), so i_rwsem alone does
 * not order against a concurrent rename of this directory.  Every other
 * reader of meta in this tree holds the inode lock; this one now does too.
 */
static struct dentry *
hammer2_get_parent(struct dentry *child)
{
	struct inode *inode = d_inode(child);
	hammer2_inode_t *ip = VTOI(inode);
	hammer2_tid_t inum, self;

	if (ip == ip->pmp->iroot)
		return (ERR_PTR(-ESTALE));

	hammer2_inode_lock(ip, HAMMER2_RESOLVE_SHARED);
	inum = ip->meta.iparent;
	self = ip->meta.inum;
	/*
	 * The reference taken by hammer2_inode_lock() is released by
	 * hammer2_inode_unlock(), so nothing is held across the lookup
	 * below.
	 */
	hammer2_inode_unlock(ip);

	if (inum == 0 || inum == self)
		return (ERR_PTR(-ESTALE));

	return (hammer2_get_inode(child->d_sb, inum));
}

const struct export_operations hammer2_export_ops = {
	.encode_fh = hammer2_encode_fh,
	.fh_to_dentry = hammer2_fh_to_dentry,
	.fh_to_parent = hammer2_fh_to_parent,
	.get_parent = hammer2_get_parent,
};
