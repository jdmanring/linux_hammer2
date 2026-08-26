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
 *     bdev_file_open_by_path() already performs.
 *   - because that one call both resolves and opens, hammer2_init_devvp()
 *     here records paths and opens nothing, and hammer2_open_devvp() does
 *     the opening.  FreeBSD splits it the other way, holding a vnode
 *     reference from init and calling g_vfs_open() later.
 *   - hammer2_gaccess_devvp() and its two callers hammer2_getw_devvp() and
 *     hammer2_putw_devvp() are not carried.  They adjust a GEOM consumer's
 *     write count around a volume-header write; Linux states the access it
 *     wants once, in the blk_mode_t passed at open, and has nothing to
 *     adjust afterwards.  hammer2.h records the same at their declaration.
 */
#include <linux/blkdev.h>
#include <linux/fs.h>
#include <linux/pagemap.h>

int
hammer2_open_devvp(struct super_block *sb, const hammer2_devvp_list_t *devvpl)
{
	hammer2_devvp_t *e;
	struct file *bdev_file;
	int lblksize, sectorsize, error;

	TAILQ_FOREACH(e, devvpl, entry) {
		KKASSERT(e->path);
		KKASSERT(!e->bdev_file);

		/* XXX Linux: g_vfs_open() on a vnode namei() already
		 * resolved.  The holder is the superblock and the holder
		 * ops are the kernel's own fs_holder_ops, which is what
		 * every in-tree filesystem passes and what makes the
		 * device's freeze, sync and mark_dead callbacks reach a
		 * mounted filesystem at all.
		 */
		bdev_file = bdev_file_open_by_path(e->path,
		    sb_open_mode(sb->s_flags), sb, &fs_holder_ops);
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
			bdev_fput(bdev_file);
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
		error = set_blocksize(bdev_file, HAMMER2_PBUFSIZE);
		if (error) {
			hprintf("failed to set %s blocksize %d %d\n",
			    e->path, (int)HAMMER2_PBUFSIZE, -error);
			bdev_fput(bdev_file);
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
			bdev_fput(e->bdev_file);	/* XXX Linux: g_vfs_close */
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
	int i, error = 0;

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

		/* XXX Linux: FreeBSD looks the device vnode up here and
		 * holds a reference to it.  bdev_file_open_by_path() does
		 * the lookup and the open in one call, so the path is all
		 * that is kept and hammer2_open_devvp() does the rest.
		 */
		e = hmalloc(sizeof(*e), M_HAMMER2, M_WAITOK | M_ZERO);
		e->bdev_file = NULL;
		e->path = hstrdup(path);
		TAILQ_INSERT_TAIL(devvpl, e, entry);
	}
	hfree(path, M_TEMP, PATH_MAX);

	return (error);
}

void
hammer2_cleanup_devvp(hammer2_devvp_list_t *devvpl)
{
	hammer2_devvp_t *e;

	while (!TAILQ_EMPTY(devvpl)) {
		e = TAILQ_FIRST(devvpl);
		TAILQ_REMOVE(devvpl, e, entry);

		/* XXX Linux: FreeBSD vrele()s the device vnode it took a
		 * reference to in hammer2_init_devvp().  Nothing is held
		 * here: hammer2_close_devvp() has already put the file.
		 */
		KKASSERT(!e->open);
		KKASSERT(!e->bdev_file);

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
	 */
	KKASSERT(bdev_file);

	if (!rdonly && !(bdev_file->f_mode & FMODE_WRITE))
		return (EACCES);

	return (0);
}
