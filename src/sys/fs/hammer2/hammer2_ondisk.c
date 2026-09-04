/*-
 * SPDX-License-Identifier: BSD-3-Clause
 *
 * Copyright (c) 2022-2023 Tomohiro Kusumi <tkusumi@netbsd.org>
 * Copyright (c) 2011-2022 The DragonFly Project.  All rights reserved.
 * All rights reserved.
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

/*
 * XXX Linux: FreeBSD reaches the device through GEOM, opening a consumer
 * on a vnode that namei() resolved.  Linux has one call that does the
 * whole of that, bdev_file_open_by_path(), so the layering here differs
 * from all three BSD ports and the differences are collected in this
 * comment rather than repeated at each site:
 *
 *   - hammer2_lookup_device() is not carried.  It is NDINIT/namei plus
 *     vn_isdisk_error() plus VOP_ACCESS(), which is exactly the path
 *     resolution, the block-device test and the permission check that
 *     lookup_bdev() and bdev_file_open_by_path() perform between them.
 *   - hammer2_init_devvp() here resolves each path with lookup_bdev()
 *     and opens nothing; hammer2_open_devvp() does the opening.  The
 *     split is not the same as FreeBSD's, which holds a vnode reference
 *     from init and calls g_vfs_open() later, but it keeps what that
 *     reference was FOR: a bad path is diagnosed in init, and the mount
 *     path gets a dev_t to match a second mount of the same device
 *     against before anything is opened.  The open has to come second on
 *     Linux because bdev_file_open_by_path() claims the device for a
 *     holder, and the device's filesystem callbacks reach a superblock
 *     only if it is the holder (below 7.3) or registered against the
 *     device (7.3, through a table the open helper below is the seam
 *     for, and each mount adds its own entry to at mount time).
 *   - hammer2_gaccess_devvp() and its two callers hammer2_getw_devvp() and
 *     hammer2_putw_devvp() are not carried.  They adjust a GEOM consumer's
 *     write count around a volume-header write; Linux states the access it
 *     wants once, in the blk_mode_t passed at open, and has nothing to
 *     adjust afterwards.  hammer2.h records the same at their declaration.
 */
#include <linux/blkdev.h>
#include <linux/fs.h>
#include <linux/pagemap.h>

/*
 * XXX Linux: 7.3 made fs_holder_ops static and replaced "the holder is a
 * superblock" with a {device, superblock} registration table, so an open
 * that wants the device's freeze, thaw, sync and mark_dead callbacks now
 * goes through fs_bdev_file_open_by_path(), which opens and registers in
 * one call.  fs/super.c documents the holder as "a superblock, or the
 * file_system_type when the device may be shared by several superblocks
 * of that type", and bd_may_claim() lets the same holder claim again,
 * which is how several superblocks come to share one device: each one
 * opens it again under the shared holder to register itself, and
 * releases its own claim at unmount.  That is what a HAMMER2 device with
 * more than one PFS mounted is, so the holder here is hammer2_fs_type.
 *
 * The open a hammer2_dev keeps for the life of the device therefore
 * registers no superblock at all: it is opened for the mounting one and
 * unregistered at once with fs_bdev_unregister(), which fs/super.c
 * documents as the pairing for a caller that wants the device open and
 * no table entry.  The entries belong to the mounts, see
 * hammer2_register_sb() below.  A registration pins its superblock
 * passively (super_dev_insert() takes s_passive), so an entry that
 * outlived its mount would not point at freed memory, it would keep the
 * memory alive and the callbacks would skip it as inactive.
 *
 * A version comparison and not an existence test: fs_bdev_file_open_by_path()
 * is a function, so the preprocessor cannot ask for it, and the two calls
 * take different arguments rather than the same ones under a new name.
 * Measured: 7.2.3-300.fc45 declares fs_holder_ops at blkdev.h:1778 and
 * neither wrapper; 7.3.0-0.rc0.260819gbd5f485f3f02 declares the wrappers at
 * fs/super.h:243 and no fs_holder_ops anywhere under include/.  linux/fs.h
 * includes the split header, so no include changes with the version.
 *
 * DEFER(7.3 ships a released -rc): the basis above is a merge-window
 * snapshot, so these names can still move before 7.3 final.  Re-measure
 * against the release and pin the comparison to what it shipped.
 */
#define LINUX_FS_BDEV_OPEN	KERNEL_VERSION(7, 3, 0)

static struct file *	/* Linux */
hammer2_bdev_open(const char *path, blk_mode_t mode, struct super_block *sb)
{
#if LINUX_VERSION_CODE < LINUX_FS_BDEV_OPEN
	return (bdev_file_open_by_path(path, mode, sb, &fs_holder_ops));
#else
	struct file *bdev_file;

	bdev_file = fs_bdev_file_open_by_path(path, mode, &hammer2_fs_type, sb);
	if (!IS_ERR(bdev_file))
		fs_bdev_unregister(bdev_file, sb);
	return (bdev_file);
#endif
}

static void	/* Linux */
hammer2_bdev_release(struct file *bdev_file)
{
	bdev_fput(bdev_file);
}

/*
 * Linux: claim every device a PFS spans on behalf of its superblock, so
 * the device's freeze, thaw, sync and mark_dead callbacks reach this
 * mount and not only the first one on the device.  Below 7.3 the holder
 * is the superblock of the first mount and no second claim is possible,
 * so a secondary mount keeps the reach it always had there: none.
 */
int
hammer2_register_sb(struct super_block *sb, hammer2_pfs_t *pmp)
{
#if LINUX_VERSION_CODE >= LINUX_FS_BDEV_OPEN
	hammer2_cluster_t *cluster = &pmp->iroot->cluster;
	hammer2_chain_t *rchain;
	hammer2_devvp_t *e, *n;
	struct file *bdev_file;
	int i;

	for (i = 0; i < cluster->nchains; ++i) {
		rchain = cluster->array[i].chain;
		if (rchain == NULL)
			continue;
		TAILQ_FOREACH(e, &rchain->hmp->devvp_list, entry) {
			/* The entry first, so a failed open leaks nothing. */
			n = hmalloc(sizeof(*n), M_HAMMER2, M_WAITOK | M_ZERO);
			bdev_file = fs_bdev_file_open_by_dev(e->devno,
			    sb_open_mode(sb->s_flags), &hammer2_fs_type, sb);
			if (IS_ERR(bdev_file)) {
				hfree(n, M_HAMMER2, sizeof(*n));
				hprintf("failed to claim %s for this mount %d\n",
				    e->path, (int)-PTR_ERR(bdev_file));
				hammer2_unregister_sb(pmp);
				return (-PTR_ERR(bdev_file));	/* positive */
			}
			n->bdev_file = bdev_file;
			n->devno = e->devno;
			n->open = 1;
			TAILQ_INSERT_TAIL(&pmp->sbdev_list, n, entry);
		}
	}
#endif
	return (0);
}

void
hammer2_unregister_sb(hammer2_pfs_t *pmp)
{
#if LINUX_VERSION_CODE >= LINUX_FS_BDEV_OPEN
	hammer2_devvp_t *e;

	while (!TAILQ_EMPTY(&pmp->sbdev_list)) {
		e = TAILQ_FIRST(&pmp->sbdev_list);
		TAILQ_REMOVE(&pmp->sbdev_list, e, entry);
		fs_bdev_file_release(e->bdev_file, pmp->mp);
		hfree(e, M_HAMMER2, sizeof(*e));
	}
#endif
}

int
hammer2_open_devvp(struct super_block *sb, const hammer2_devvp_list_t *devvpl)
{
	hammer2_devvp_t *e;
	struct file *bdev_file;
	size_t fmax, fneed;	/* Linux */
	int lblksize, sectorsize, error;

	TAILQ_FOREACH(e, devvpl, entry) {
		KKASSERT(e->path);
		KKASSERT(!e->bdev_file);

		/* XXX Linux: g_vfs_open() on a vnode namei() already
		 * resolved.  The holder is the superblock and the holder
		 * ops are the kernel's own filesystem holder ops, which is what
		 * every in-tree filesystem passes and what makes the
		 * device's freeze, sync and mark_dead callbacks reach a
		 * mounted filesystem at all.
		 */
		bdev_file = hammer2_bdev_open(e->path,
		    sb_open_mode(sb->s_flags), sb);	/* Linux */
		if (IS_ERR(bdev_file)) {
			error = -PTR_ERR(bdev_file);	/* Linux: positive */
			hprintf("failed to open %s %d\n", e->path, error);
			return (error);
		}

		/* XXX Linux: FreeBSD compares hammer2_get_logical() against
		 * the GEOM provider's sectorsize.  The same comparison, on
		 * the block device's logical block size.
		 */
		sectorsize = bdev_logical_block_size(file_bdev(bdev_file));
		lblksize = hammer2_get_logical();
		if (sectorsize <= 0 || (lblksize % sectorsize) != 0 ||
		    lblksize < sectorsize) {
			hprintf("invalid sector size %d vs lblksize %d\n",
			    sectorsize, lblksize);
			hammer2_bdev_release(bdev_file);	/* Linux */
			return (EINVAL);
		}

		/* Linux: the DIO layer reads this device through its page
		 * cache and hands the core a folio_address() pointer for a
		 * whole HAMMER2_PBUFSIZE buffer, so the mapping's minimum
		 * folio order has to cover that buffer before the first
		 * read.  set_blocksize() is what sets it, and it is called
		 * per device rather than through sb_set_blocksize() because
		 * a HAMMER2 filesystem spans up to HAMMER2_MAX_VOLUMES
		 * devices and only the root volume is ever sb->s_bdev.
		 * hammer2_io_folio_check() is the runtime backstop for this
		 * having been done.
		 */
		/* Linux: ask the page cache before asking the device.
		 * set_blocksize() fails EINVAL on a kernel whose page cache
		 * cannot hold a HAMMER2_PBUFSIZE folio and says nothing
		 * about why, so the question is put to
		 * mapping_max_folio_size_supported() first, which pagemap.h
		 * says is what a filesystem with a folio-size requirement
		 * calls at mount, and the refusal names both numbers.  The
		 * static_assert in hammer2_io.c stays as the build-time
		 * guard, since a kernel without CONFIG_TRANSPARENT_HUGEPAGE
		 * is better refused at the compile than at the first mount.
		 * HAMMER2_FOLIO_CONTROL is the negative control: it asks for
		 * twice what the kernel offers, so a module built with it
		 * must refuse every mount through this branch.
		 */
		fmax = mapping_max_folio_size_supported();
#ifdef HAMMER2_FOLIO_CONTROL
		fneed = 2 * fmax;
#else
		fneed = HAMMER2_PBUFSIZE;
#endif
		if (fneed > fmax) {
			hprintf("this kernel caches at most %zu bytes in one folio and HAMMER2 needs %zu: mount refused\n",
			    fmax, fneed);
			hammer2_bdev_release(bdev_file);	/* Linux */
			return (EOPNOTSUPP);		/* Linux: positive */
		}

		error = set_blocksize(bdev_file, HAMMER2_PBUFSIZE);
		if (error) {
			hprintf("failed to set %s blocksize %d %d\n",
			    e->path, (int)HAMMER2_PBUFSIZE, -error);
			hammer2_bdev_release(bdev_file);	/* Linux */
			return (-error);		/* Linux: positive */
		}

		e->bdev_file = bdev_file;
		e->open = 1;
		KKASSERT(e->open);
	}

	return (0);
}

int
hammer2_close_devvp(const hammer2_devvp_list_t *devvpl)
{
	hammer2_devvp_t *e;

	TAILQ_FOREACH(e, devvpl, entry) {
		if (e->open) {
			KKASSERT(e->bdev_file);
			hammer2_bdev_release(e->bdev_file);
							/* XXX Linux: g_vfs_close */
			e->bdev_file = NULL;
			e->open = 0;
		}
	}

	return (0);
}

int
hammer2_init_devvp(const struct super_block *sb, const char *blkdevs,
    hammer2_devvp_list_t *devvpl)
{
	hammer2_devvp_t *e;
	const char *p;
	char *path;
	dev_t devno;
	int i, error;

	KKASSERT(TAILQ_EMPTY(devvpl));
	KKASSERT(blkdevs); /* Could be empty string. */
	p = blkdevs;

	/* XXX Linux: the superblock is unused here.  FreeBSD passes the
	 * mount to namei(), and the open that replaced it happens in
	 * hammer2_open_devvp().  The argument is kept so the four trees
	 * read side by side and so the split can move back if a later
	 * mount path needs it.
	 */
	(void)sb;

	path = hmalloc(PATH_MAX, M_TEMP, M_WAITOK | M_ZERO);
	while (1) {
		strscpy(path, "", PATH_MAX);	/* XXX Linux: was strlcpy */
		if (*p != '/')
			strscpy(path, "/dev/", PATH_MAX); /* Relative path. */

		/* Scan beyond "/dev/". */
		for (i = strlen(path); i < PATH_MAX-1; ++i) {
			if (*p == '\0') {
				break;
			} else if (*p == ':') {
				p++;
				break;
			} else {
				path[i] = *p;
				p++;
			}
		}
		path[i] = '\0';
		/* Path shorter than "/dev/" means invalid or done. */
		if (strlen(path) <= strlen("/dev/")) {
			if (strlen(p)) {
				hprintf("ignore incomplete path %s\n", path);
				continue;
			} else {
				/* End of string. */
				KKASSERT(*p == '\0');
				break;
			}
		}

		/* XXX Linux: FreeBSD looks the device vnode up here with
		 * namei() and holds a reference to it, both to diagnose a
		 * bad path before anything is opened and to give the mount
		 * path a devvp->v_rdev to match a second mount of the same
		 * device against.  lookup_bdev() answers the same two
		 * questions without opening anything and without a
		 * reference to release: it resolves the path in the
		 * caller's namespace and yields the dev_t.  The open
		 * itself still belongs to hammer2_open_devvp(), which
		 * cannot run before there is a superblock to hold the
		 * device.
		 */
		error = lookup_bdev(path, &devno);
		if (error) {
			hprintf("failed to resolve %s %d\n", path, -error);
			hfree(path, M_TEMP, PATH_MAX);
			return (-error);		/* Linux: positive */
		}

		e = hmalloc(sizeof(*e), M_HAMMER2, M_WAITOK | M_ZERO);
		e->bdev_file = NULL;
		e->path = hstrdup(path);
		e->devno = devno;
		TAILQ_INSERT_TAIL(devvpl, e, entry);
	}
	hfree(path, M_TEMP, PATH_MAX);

	return (0);
}

void
hammer2_cleanup_devvp(hammer2_devvp_list_t *devvpl)
{
	hammer2_devvp_t *e;

	while (!TAILQ_EMPTY(devvpl)) {
		e = TAILQ_FIRST(devvpl);
		TAILQ_REMOVE(devvpl, e, entry);

		/* XXX Linux: FreeBSD vrele()s the device vnode it took a
		 * reference to in hammer2_init_devvp().  Normally there is
		 * nothing to put here, because hammer2_close_devvp() ran
		 * first.  It is done unconditionally anyway, exactly as
		 * FreeBSD's vrele() is: hammer2_open_devvp() returns from
		 * the middle of its loop when one device fails, leaving the
		 * ones before it open, and the caller that has to unwind
		 * that is hammer2_vfsops.c.  A KKASSERT here would be
		 * compiled out of the default build and the reference would
		 * be held for the life of the module.
		 */
		if (e->bdev_file) {
			/* Linux: debug_hprintf and not WARN_ONCE.  A WARN
			 * says "this cannot happen", taints the kernel and
			 * kills a panic_on_warn box, and until the contract
			 * at the declaration in hammer2.h has a caller to
			 * hold to it, reaching here is an ordinary mount
			 * failure unwinding rather than a bug.
			 */
			debug_hprintf("%s still open at cleanup\n",
			    e->path ? e->path : "(null)");
			hammer2_bdev_release(e->bdev_file);	/* Linux */
			e->bdev_file = NULL;
			e->open = 0;
		}

		/* Cleanup path. */
		KKASSERT(e->path);
		hstrfree(e->path);
		e->path = NULL;

		hfree(e, M_HAMMER2, sizeof(*e));
	}
}

/*
 * Linux: HAMMER2_UUID_STRING as bytes.  The BSDs parse and format uuids in
 * the kernel; Linux does not, so the filesystem type uuid every volume
 * header must carry is spelled once here in the DCE 1.1 field layout that
 * struct uuid (hammer2_disk.h) has, and hammer2_verify_volumes_common()
 * compares against it.  The string above it is the same value and is what
 * the failure message prints, so the two are checkable by eye.
 *
 * %pUl elsewhere in this file prints a struct uuid by reading those first
 * three fields little-endian, which is what they are in memory on every
 * target this port builds for.  That is a print path only; nothing here
 * compares formatted text.
 */
static const struct uuid hammer2_fstype_uuid = {	/* 5cbb9ad1-862d-11dc-a94d-01301bb8a9f5 */
	.time_low = 0x5cbb9ad1,
	.time_mid = 0x862d,
	.time_hi_and_version = 0x11dc,
	.clock_seq_hi_and_reserved = 0xa9,
	.clock_seq_low = 0x4d,
	.node = { 0x01, 0x30, 0x1b, 0xb8, 0xa9, 0xf5 },
};

static int
hammer2_verify_volumes_common(const hammer2_volume_t *volumes,
			      const hammer2_volume_data_t *rootvoldata)
{
	const hammer2_volume_t *vol;
	const char *path;
	loff_t mediasize;		/* XXX Linux: was struct g_consumer *cp */
	int i;
	struct uuid uuid;

	/* Check volume header. */
	if (rootvoldata->volu_id != HAMMER2_ROOT_VOLUME) {
		hprintf("volume id %d must be %d\n", rootvoldata->volu_id,
		    HAMMER2_ROOT_VOLUME);
		return (EINVAL);
	}
	uuid = rootvoldata->fstype;
	/* XXX Linux: the BSDs format the uuid with snprintf_uuid(9) and
	 * strcmp() the text against HAMMER2_UUID_STRING.  Linux has no
	 * such formatter; uuid_parse() would need the string parsed on
	 * every mount, so the constant is compared as bytes and only the
	 * failure path formats, with the kernel's %pUl extension.
	 */
	if (memcmp(&uuid, &hammer2_fstype_uuid, sizeof(uuid))) {
		hprintf("volume fstype uuid %pUl must be %s\n", &uuid,
		    HAMMER2_UUID_STRING);
		return (EINVAL);
	}

	for (i = 0; i < HAMMER2_MAX_VOLUMES; ++i) {
		vol = &volumes[i];
		if (vol->id == -1)
			continue;
		path = vol->dev->path;

		/* Check volume fields are initialized. */
		if (!vol->dev->bdev_file) {	/* XXX Linux: was devvp */
			hprintf("%s has NULL devvp\n", path);
			return (EINVAL);
		}
		if (vol->offset == (hammer2_off_t)-1) {
			hprintf("%s has bad offset %016llx\n",
			    path, (long long)vol->offset);
			return (EINVAL);
		}
		if (vol->size == (hammer2_off_t)-1) {
			hprintf("%s has bad size %016llx\n",
			    path, (long long)vol->size);
			return (EINVAL);
		}

		/* Check volume size vs block device size. */
		/* XXX Linux: the GEOM provider's mediasize, read off the
		 * block device instead.
		 */
		mediasize = bdev_nr_bytes(file_bdev(vol->dev->bdev_file));
		if (vol->size > (hammer2_off_t)mediasize) {
			hprintf("%s's size %016llx exceeds device size %016llx\n",
			    path, (long long)vol->size,
			    (long long)mediasize);
			return (EINVAL);
		}
		if (vol->size == 0) {
			hprintf("%s has size of 0\n", path);
			return (EINVAL);
		}
	}

	return (0);
}

static int
hammer2_verify_volumes_1(const hammer2_volume_t *volumes,
    const hammer2_volume_data_t *rootvoldata)
{
	const hammer2_volume_t *vol;
	hammer2_off_t off;
	const char *path;
	int i, nvolumes = 0;

	/* Check initialized volume count. */
	for (i = 0; i < HAMMER2_MAX_VOLUMES; ++i) {
		vol = &volumes[i];
		if (vol->id != -1)
			nvolumes++;
	}
	if (nvolumes != 1) {
		hprintf("only 1 volume supported\n");
		return (EINVAL);
	}

	/* Check volume header. */
	if (rootvoldata->nvolumes) {
		hprintf("volume count %d must be 0\n", rootvoldata->nvolumes);
		return (EINVAL);
	}
	if (rootvoldata->total_size) {
		hprintf("total size %016llx must be 0\n",
		    (long long)rootvoldata->total_size);
		return (EINVAL);
	}
	for (i = 0; i < HAMMER2_MAX_VOLUMES; ++i) {
		off = rootvoldata->volu_loff[i];
		if (off) {
			hprintf("volume offset[%d] %016llx must be 0\n",
			    i, (long long)off);
			return (EINVAL);
		}
	}

	/* Check volume. */
	vol = &volumes[HAMMER2_ROOT_VOLUME];
	path = vol->dev->path;
	if (vol->id) {
		hprintf("%s has non zero id %d\n", path, vol->id);
		return (EINVAL);
	}
	if (vol->offset) {
		hprintf("%s has non zero offset %016llx\n",
		    path, (long long)vol->offset);
		return (EINVAL);
	}
	if (vol->size & HAMMER2_VOLUME_ALIGNMASK64) {
		hprintf("%s's size is not %016llx aligned\n",
		    path, (long long)HAMMER2_VOLUME_ALIGN);
		return (EINVAL);
	}

	return (0);
}

static int
hammer2_verify_volumes_2(const hammer2_volume_t *volumes,
    const hammer2_volume_data_t *rootvoldata)
{
	const hammer2_volume_t *vol;
	hammer2_off_t off, total_size = 0;
	const char *path;
	int i, nvolumes = 0;

	/* Check initialized volume count. */
	for (i = 0; i < HAMMER2_MAX_VOLUMES; ++i) {
		vol = &volumes[i];
		if (vol->id != -1) {
			nvolumes++;
			total_size += vol->size;
		}
	}

	/* Check volume header. */
	if (rootvoldata->nvolumes != nvolumes) {
		hprintf("volume header requires %d devices, %d specified\n",
		    rootvoldata->nvolumes, nvolumes);
		return (EINVAL);
	}
	if (rootvoldata->total_size != total_size) {
		hprintf("total size %016llx does not equal sum of volumes "
		    "%016llx\n",
		    (long long)rootvoldata->total_size, (long long)total_size);
		return (EINVAL);
	}
	for (i = 0; i < nvolumes; ++i) {
		off = rootvoldata->volu_loff[i];
		if (off == (hammer2_off_t)-1) {
			hprintf("volume offset[%d] %016llx must not be -1\n",
			    i, (long long)off);
			return (EINVAL);
		}
	}
	for (i = nvolumes; i < HAMMER2_MAX_VOLUMES; ++i) {
		off = rootvoldata->volu_loff[i];
		if (off != (hammer2_off_t)-1) {
			hprintf("volume offset[%d] %016llx must be -1\n",
			    i, (long long)off);
			return (EINVAL);
		}
	}

	/* Check volumes. */
	for (i = 0; i < HAMMER2_MAX_VOLUMES; ++i) {
		vol = &volumes[i];
		if (vol->id == -1)
			continue;
		path = vol->dev->path;
		/* Check offset. */
		if (vol->offset & HAMMER2_FREEMAP_LEVEL1_MASK) {
			hprintf("%s's offset %016llx not %016llx aligned\n",
			    path, (long long)vol->offset,
			    (long long)HAMMER2_FREEMAP_LEVEL1_SIZE);
			return (EINVAL);
		}
		/* Check vs previous volume. */
		if (i) {
			if (vol->id <= (vol-1)->id) {
				hprintf("%s has inconsistent id %d\n",
				    path, vol->id);
				return (EINVAL);
			}
			if (vol->offset != (vol-1)->offset + (vol-1)->size) {
				hprintf("%s has inconsistent offset %016llx\n",
				    path, (long long)vol->offset);
				return (EINVAL);
			}
		} else { /* first */
			if (vol->offset) {
				hprintf("%s has non zero offset %016llx\n",
				    path, (long long)vol->offset);
				return (EINVAL);
			}
		}
		/* Check size for non-last and last volumes. */
		if (i != rootvoldata->nvolumes - 1) {
			if (vol->size < HAMMER2_FREEMAP_LEVEL1_SIZE) {
				hprintf("%s's size must be >= %016llx\n",
				    path,
				    (long long)HAMMER2_FREEMAP_LEVEL1_SIZE);
				return (EINVAL);
			}
			if (vol->size & HAMMER2_FREEMAP_LEVEL1_MASK) {
				hprintf("%s's size is not %016llx aligned\n",
				    path,
				    (long long)HAMMER2_FREEMAP_LEVEL1_SIZE);
				return (EINVAL);
			}
		} else { /* last */
			if (vol->size & HAMMER2_VOLUME_ALIGNMASK64) {
				hprintf("%s's size is not %016llx aligned\n",
				    path, (long long)HAMMER2_VOLUME_ALIGN);
				return (EINVAL);
			}
		}
	}

	return (0);
}

static int
hammer2_verify_volumes(const hammer2_volume_t *volumes,
    const hammer2_volume_data_t *rootvoldata)
{
	int error;

	error = hammer2_verify_volumes_common(volumes, rootvoldata);
	if (error)
		return (error);

	if (rootvoldata->version >= HAMMER2_VOL_VERSION_MULTI_VOLUMES)
		return (hammer2_verify_volumes_2(volumes, rootvoldata));
	else
		return (hammer2_verify_volumes_1(volumes, rootvoldata));
}

/*
 * Returns zone# of returned volume header or < 0 on failure.
 */
static int
hammer2_read_volume_header(struct file *bdev_file, const char *path,
    hammer2_volume_data_t *voldata)
{
	hammer2_volume_data_t *vd;
	hammer2_crc32_t crc0, crc1;
	struct address_space *mapping;
	struct folio *folio;
	const char *bdata;
	loff_t mediasize;
	off_t blkoff;
	int i, zone = -1;

	/* XXX Linux: FreeBSD reads through bread(9) on the device vnode
	 * after g_vfs_open() has installed the GEOM buffer ops.  This
	 * reads the block device's page cache directly, which is the same
	 * mapping hammer2_io.c reads through once a mount exists; there is
	 * no hammer2_dev_t yet at this point, so hammer2_io_bread() is not
	 * available and read_mapping_folio() is called here directly.
	 *
	 * The folio covers the whole HAMMER2_VOLUME_BYTES header because
	 * hammer2_open_devvp() set the mapping's minimum folio order to
	 * HAMMER2_PBUFSIZE, which is the same 64 KiB, and because blkoff
	 * below is a multiple of HAMMER2_ZONE_BYTES64 and so folio-aligned.
	 */
	mapping = bdev_file->f_mapping;
	mediasize = bdev_nr_bytes(file_bdev(bdev_file));

	/*
	 * There are up to 4 copies of the volume header (syncs iterate
	 * between them so there is no single master).  We don't trust the
	 * volu_size field so we don't know precisely how large the filesystem
	 * is, so depend on the OS to return an error if we go beyond the
	 * block device's EOF.
	 */
	for (i = 0; i < HAMMER2_NUM_VOLHDRS; ++i) {
		/* Ignore if blkoff is beyond media size. */
		blkoff = (off_t)i * HAMMER2_ZONE_BYTES64;
		if (blkoff >= mediasize)
			continue;

		folio = read_mapping_folio(mapping, blkoff >> PAGE_SHIFT,
					   bdev_file);
		if (IS_ERR(folio))
			continue;
		if (folio_size(folio) < HAMMER2_VOLUME_BYTES) {
			/* Linux: the minimum folio order was not set, which
			 * hammer2_open_devvp() is responsible for; reading
			 * on would hand the CRC below a short buffer.
			 */
			WARN_ONCE(1, "hammer2: %s #%d: folio %zu < %d\n",
				  path, i, folio_size(folio),
				  (int)HAMMER2_VOLUME_BYTES);
			folio_put(folio);
			continue;
		}
		bdata = folio_address(folio);

		vd = (struct hammer2_volume_data *)bdata;
		/* Verify volume header magic. */
		if ((vd->magic != HAMMER2_VOLUME_ID_HBO) &&
		    (vd->magic != HAMMER2_VOLUME_ID_ABO)) {
			hprintf("%s #%d: bad magic\n", path, i);
			folio_put(folio);
			continue;
		}
		if (vd->magic == HAMMER2_VOLUME_ID_ABO) {
			/* XXX: Reversed-endianness filesystem. */
			hprintf("%s #%d: reverse-endian filesystem detected\n",
			    path, i);
			folio_put(folio);
			continue;
		}

		/* Verify volume header CRC's. */
		crc0 = vd->icrc_sects[HAMMER2_VOL_ICRC_SECT0];
		crc1 = hammer2_icrc32(bdata + HAMMER2_VOLUME_ICRC0_OFF,
		    HAMMER2_VOLUME_ICRC0_SIZE);
		if (crc0 != crc1) {
			hprintf("%s #%d: volume header crc mismatch sect0 "
			    "%08x/%08x\n",
			    path, i, crc0, crc1);
			folio_put(folio);
			continue;
		}
		crc0 = vd->icrc_sects[HAMMER2_VOL_ICRC_SECT1];
		crc1 = hammer2_icrc32(bdata + HAMMER2_VOLUME_ICRC1_OFF,
		    HAMMER2_VOLUME_ICRC1_SIZE);
		if (crc0 != crc1) {
			hprintf("%s #%d: volume header crc mismatch sect1 "
			    "%08x/%08x\n",
			    path, i, crc0, crc1);
			folio_put(folio);
			continue;
		}
		crc0 = vd->icrc_volheader;
		crc1 = hammer2_icrc32(bdata + HAMMER2_VOLUME_ICRCVH_OFF,
		    HAMMER2_VOLUME_ICRCVH_SIZE);
		if (crc0 != crc1) {
			hprintf("%s #%d: volume header crc mismatch vh "
			    "%08x/%08x\n",
			    path, i, crc0, crc1);
			folio_put(folio);
			continue;
		}

		if (zone == -1 || voldata->mirror_tid < vd->mirror_tid) {
			*voldata = *vd;
			zone = i;
		}
		folio_put(folio);
	}

	if (zone == -1) {
		hprintf("%s has no valid volume headers\n", path);
		return (-EINVAL);
	}
	return (zone);
}

static void
hammer2_print_uuid_mismatch(struct uuid *uuid1, struct uuid *uuid2,
    const char *id)
{
	/* XXX Linux: the BSDs format with snprintf_uuid(9) into two
	 * buffers.  %pUl is the kernel's own printf extension for a
	 * 16-byte little-endian UUID, which is the byte order struct uuid
	 * in hammer2_disk.h already has.
	 */
	hprintf("volume %s uuid mismatch %pUl vs %pUl\n", id, uuid1, uuid2);
}

int
hammer2_init_volumes(const hammer2_devvp_list_t *devvpl,
    hammer2_volume_t *volumes, hammer2_volume_data_t *rootvoldata,
    int *rootvolzone, struct file **rootvoldevvp)	/* XXX Linux: was struct vnode ** */
{
	hammer2_volume_data_t *voldata;
	hammer2_volume_t *vol;
	hammer2_devvp_t *e;
	struct file		*bdev_file;	/* XXX Linux: was struct vnode * */
	struct uuid fsid, fstype;
	const char *path;
	int i, zone, error = 0, v = -1, nvolumes = 0;

	for (i = 0; i < HAMMER2_MAX_VOLUMES; ++i) {
		vol = &volumes[i];
		vol->dev = NULL;
		vol->id = -1;
		vol->offset = (hammer2_off_t)-1;
		vol->size = (hammer2_off_t)-1;
	}

	voldata = hmalloc(sizeof(*voldata), M_HAMMER2, M_WAITOK | M_ZERO);
	bzero(&fsid, sizeof(fsid));
	bzero(&fstype, sizeof(fstype));
	bzero(rootvoldata, sizeof(*rootvoldata));

	TAILQ_FOREACH(e, devvpl, entry) {
		bdev_file = e->bdev_file;
		path = e->path;
		KKASSERT(bdev_file);

		/* Returns negative error or positive zone#. */
		error = hammer2_read_volume_header(bdev_file, path, voldata);
		if (error < 0) {
			hprintf("failed to read %s's volume header\n", path);
			error = -error;
			goto done;
		}
		zone = error;
		error = 0; /* Reset error. */

		/* Check volume ID. */
		if (voldata->volu_id >= HAMMER2_MAX_VOLUMES) {
			hprintf("%s has bad volume id %d\n",
			    path, voldata->volu_id);
			error = EINVAL;
			goto done;
		}
		vol = &volumes[voldata->volu_id];
		if (vol->id != -1) {
			hprintf("volume id %d already initialized\n",
			    voldata->volu_id);
			error = EINVAL;
			goto done;
		}

		/* All headers must have the same version, nvolumes and uuid. */
		if (v == -1) {
			v = voldata->version;
			nvolumes = voldata->nvolumes;
			fsid = voldata->fsid;
			fstype = voldata->fstype;
		} else {
			if (v != (int)voldata->version) {
				hprintf("volume version mismatch %d vs %d\n",
				    v, (int)voldata->version);
				error = ENXIO;
				goto done;
			}
			if (nvolumes != voldata->nvolumes) {
				hprintf("volume count mismatch %d vs %d\n",
				    nvolumes, voldata->nvolumes);
				error = ENXIO;
				goto done;
			}
			if (bcmp(&fsid, &voldata->fsid, sizeof(fsid))) {
				hammer2_print_uuid_mismatch(&fsid,
				    &voldata->fsid, "fsid");
				error = ENXIO;
				goto done;
			}
			if (bcmp(&fstype, &voldata->fstype, sizeof(fstype))) {
				hammer2_print_uuid_mismatch(&fstype,
				    &voldata->fstype, "fstype");
				error = ENXIO;
				goto done;
			}
		}
		if (v < HAMMER2_VOL_VERSION_MIN ||
		    v > HAMMER2_VOL_VERSION_WIP) {
			hprintf("bad volume version %d\n", v);
			error = EINVAL;
			goto done;
		}

		/* All per-volume tests passed. */
		vol->dev = e;
		vol->id = voldata->volu_id;
		vol->offset = voldata->volu_loff[vol->id];
		vol->size = voldata->volu_size;
		if (vol->id == HAMMER2_ROOT_VOLUME) {
			bcopy(voldata, rootvoldata, sizeof(*rootvoldata));
			*rootvolzone = zone;
			KKASSERT(*rootvoldevvp == NULL);
			*rootvoldevvp = bdev_file;
		}
		debug_hprintf("\"%s\" zone %d id %d offset %016llx size "
		    "%016llx\n",
		    path, zone, vol->id, (long long)vol->offset,
		    (long long)vol->size);
	}
done:
	if (error == 0) {
		if (!rootvoldata->version) {
			hprintf("root volume not found\n");
			error = EINVAL;
		}
		if (error == 0)
			error = hammer2_verify_volumes(volumes, rootvoldata);
	}
	hfree(voldata, M_HAMMER2, sizeof(*voldata));

	return (error);
}

hammer2_volume_t*
hammer2_get_volume(hammer2_dev_t *hmp, hammer2_off_t offset)
{
	hammer2_volume_t *vol, *ret = NULL;
	int i;

	offset &= ~HAMMER2_OFF_MASK_RADIX;

	/* locking is unneeded until volume-add support */
	//hammer2_voldata_lock(hmp);
	/* Do binary search if users really use this many supported volumes. */
	for (i = 0; i < hmp->nvolumes; ++i) {
		vol = &hmp->volumes[i];
		if ((offset >= vol->offset) &&
		    (offset < vol->offset + vol->size)) {
			ret = vol;
			break;
		}
	}
	//hammer2_voldata_unlock(hmp);

	if (!ret)
		hpanic("no volume for offset %016llx", (long long)offset);

	KKASSERT(ret);
	KKASSERT(ret->dev);
	KKASSERT(ret->dev->bdev_file);
	KKASSERT(ret->dev->path);

	return (ret);
}


int
hammer2_access_devvp(struct file *bdev_file, int rdonly)
{
	/* XXX Linux: FreeBSD asks VOP_ACCESS() for VREAD or VREAD|VWRITE on
	 * the device vnode and falls back to priv_check(PRIV_VFS_MOUNT_PERM).
	 * Neither question exists here.  The VFS checked the mount
	 * capability before ->get_tree() ran, and the device permission
	 * check happened inside bdev_file_open_by_path(); what is left to
	 * ask is whether the file that call returned was actually opened
	 * for writing, which is a different question at a different layer
	 * and the one a caller passing rdonly==0 means.
	 *
	 * XXX Linux: the write bit is read off f_mode, and that the open
	 * sets it was confirmed rather than assumed.  Traced through Linux
	 * v7.2 on 2026-08-26: sb_open_mode() gives BLK_OPEN_WRITE unless
	 * SB_RDONLY, block/bdev.c blk_to_file_flags() turns that into
	 * O_RDWR (with BLK_OPEN_READ) or O_WRONLY, and fs/file_table.c
	 * sets f->f_mode = OPEN_FMODE(flags) at alloc_file().  So
	 * FMODE_WRITE is set exactly when the mount asked to write.
	 *
	 * This was a DEFER until then, on the grounds that the kernel tree
	 * of record is headers only and block/bdev.c could not be read.
	 * That was true of the tree and false of the question: the file is
	 * published at the tag the tree is pinned to.
	 */
	KKASSERT(bdev_file);

	if (!rdonly && !(bdev_file->f_mode & FMODE_WRITE))
		return (EACCES);

	return (0);
}
