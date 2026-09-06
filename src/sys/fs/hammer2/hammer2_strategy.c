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
 * The strategy layer: the two data-path XOP handlers and the live dedup
 * heuristic.
 *
 * WHAT IS HERE AND WHAT IS NOT.  This file exists ahead of the read path
 * because the module could not link without it.  hammer2_admin.c carries
 * upstream's XOP descriptor table, which names strategy_read and
 * strategy_write, and hammer2_bulkfree.c calls hammer2_dedup_clear().
 * Three undefined symbols out of modpost is not a state a driver can be
 * loaded from, and 0.3 asks for a module that loads and unloads.
 *
 * hammer2_dedup_clear() is carried.  Both XOP handlers are floors: they
 * feed an error through the XOP protocol and warn once.  Neither is
 * reachable today, because an XOP is started from a vnode operation and
 * this port has no ->read_folio and no ->writepages to start one.  That
 * is the whole of the reason: the mount path returns success now, so
 * nothing upstream of the vnode operations holds these back.  The floors
 * are what makes that unreachability visible at link time rather than
 * asserted here.
 *
 * WHY A FLOOR RATHER THAN A CARRY.  Upstream's file is 1132 lines and is
 * not carryable: it includes <sys/bio.h>, hammer2_lz4.h and
 * <contrib/zlib/zlib.h>, and its read half copies into a struct buf.  The
 * two compression dependencies are not dependencies on Linux, which was
 * measured rather than assumed: the kernel exports LZ4_decompress_safe()
 * from vmlinux under the name upstream already calls, and zlib_inflate(),
 * zlib_inflateInit2() and zlib_inflate_workspacesize() beside it.
 *
 * Present was the only question asked of them until 2026-09-03, when the
 * SHA-256 context struct turned out to have been renamed one release above
 * the declared floor with its function names and argument order unchanged.
 * A name that resolves says nothing about the shape behind it.  So both
 * headers were compared rather than looked up: <linux/lz4.h> and
 * <linux/zlib.h> are byte-identical at v6.15 and at v7.2, which is the
 * whole range this module claims, and these four declarations cannot have
 * moved inside it.
 *
 * Nothing needs vendoring.  What remains is
 * the buffer, and that is the rewrite: the destination of a read is a
 * folio, which is why hammer2_xop_strategy carries one.
 *
 * The write handler is a floor for a second reason on top of the first.
 * The write path is 0.5.  It is not deferred here because it is hard; it
 * is deferred because a read-only milestone that can write is not a
 * read-only milestone.
 */

#include "hammer2.h"
#include "hammer2_xxhash.h"	/* Linux: XXH64 for the dedup heuristic */

#include <linux/highmem.h>
#include <linux/lz4.h>	/* Linux: LZ4_decompress_safe */
#include <linux/vmalloc.h>	/* Linux: the zlib workspace */
#include <linux/zlib.h>	/* Linux: zlib_inflate */	/* Linux: memcpy_to_folio, folio_zero_range */
#include <linux/pagemap.h>	/* Linux: folio_pos, folio_unlock */

/*
 * Clear the live dedup heuristic.  Carried.
 */
void
hammer2_dedup_clear(hammer2_dev_t *hmp)
{
	int i;

	for (i = 0; i < HAMMER2_DEDUP_HEUR_SIZE; ++i) {
		hmp->heur_dedup[i].data_off = 0;
		hmp->heur_dedup[i].ticks = getticks() - 1;
	}
}

/*
 * XXX Linux: both handlers below are floors, not translations.
 *
 * The XOP protocol requires exactly one hammer2_xop_feed() per handler
 * call, since the frontend in hammer2_xop_collect() waits on the FIFO and
 * a handler that returns without feeding hangs the caller rather than
 * failing it.  Feeding a NULL chain with an error is how every carried
 * handler reports one, so that is what these do.
 *
 * WARN_ONCE rather than KKASSERT: this is code written for the OS half,
 * where the port's rule is a warning plus recovery plus an errno, and the
 * recovery is the error fed to the frontend.  A reachable floor must be
 * loud once and survivable, not fatal.
 */

/*
 * Backend for a logical read: resolve the chain covering xop->lbase and
 * feed it to the frontend.
 *
 * This is the first half of upstream's hammer2_xop_strategy_read() and
 * none of the second.  Upstream's second half races the frontend to
 * complete a bio, because a DragonFly XOP runs on a backend thread and
 * either end may finish first.  hammer2_xop_start() in this port calls the
 * storage function inline on the calling thread, so there is no race to
 * win: the frontend collects after start returns, exactly as ->lookup and
 * ->iterate_shared do.  That is why hammer2_xop_strategy carries no
 * finished flag, no lock and no bio, which was decided when the struct was
 * written.
 */
void
hammer2_xop_strategy_read(hammer2_xop_t *arg, void *scratch __maybe_unused,
    int clindex)
{
	hammer2_xop_strategy_t *xop = &arg->xop_strategy;
	hammer2_chain_t *parent, *chain;
	hammer2_key_t key_dummy, lbase;
	int error;

	lbase = xop->lbase;

	parent = hammer2_inode_chain(xop->head.ip1, clindex,
	    HAMMER2_RESOLVE_ALWAYS | HAMMER2_RESOLVE_SHARED);
	if (parent) {
		chain = hammer2_chain_lookup(&parent, &key_dummy, lbase, lbase,
		    &error, HAMMER2_LOOKUP_ALWAYS | HAMMER2_LOOKUP_SHARED);
		if (chain)
			error = chain->error;
	} else {
		error = HAMMER2_ERROR_EIO;
		chain = NULL;
	}
	hammer2_xop_feed(&xop->head, chain, clindex, error);
	if (chain) {
		hammer2_chain_unlock(chain);
		hammer2_chain_drop(chain);
	}
	if (parent) {
		hammer2_chain_unlock(parent);
		hammer2_chain_drop(parent);
	}
}

/*
 * Decompress one LZ4 block into the folio.
 *
 * The on-media block begins with the compressed length as a plain int,
 * which upstream reads the same way, and the rest is the LZ4 stream.  The
 * logical size is always HAMMER2_PBUFSIZE, hammer2_calc_logical() having
 * no other answer, so the destination is a fixed 64 KiB.
 *
 * WHAT IS CHECKED THAT UPSTREAM ASSERTS.  Upstream reads the length and
 * KKASSERTs that it fits, which compiles out unless invariants are on, and
 * on a decompression failure it zeroes its buffer and reports success.
 * Both are readings of media this module does not trust: a length is four
 * bytes off a disk that may be corrupt or hostile, and LZ4_decompress_safe()
 * is bounded by the length it is given, so a length past the end of the
 * block is the one input that could make it read beyond the buffer.  It is
 * a branch here rather than an assertion, and a failure returns an errno
 * rather than a folio full of zeroes that every later reader would take as
 * the file's contents.
 *
 * The folio is the whole block: hammer2_igetv() sets the file mapping's
 * minimum folio order to the block's, so one read_folio and one
 * decompression serve a block, as one logical buffer does upstream.
 * Before that a page-sized folio decompressed the same block once per
 * page, forty-three reads of a 176000-byte file where there are now three.
 */
static int
hammer2_decompress_lz4(hammer2_xop_strategy_t *xop, hammer2_chain_t *focus,
    const char *data, hammer2_off_t skip)
{
	struct folio *folio = xop->folio;
	size_t fsize = folio_size(folio);
	char *buf;
	int csize, dsize;
	size_t len;

	if (focus->bytes <= sizeof(int)) {
		WARN_ONCE(1, "hammer2: lz4 block of %u bytes\n", focus->bytes);
		return (EIO);
	}
	csize = *(const int *)data;
	if (csize <= 0 || (size_t)csize > focus->bytes - sizeof(int)) {
		WARN_ONCE(1, "hammer2: lz4 length %d in a %u byte block\n",
		    csize, focus->bytes);
		return (EIO);
	}

	buf = hmalloc(HAMMER2_PBUFSIZE, M_HAMMER2, M_WAITOK);
	if (buf == NULL)
		return (ENOMEM);

	dsize = LZ4_decompress_safe(data + sizeof(int), buf, csize,
	    HAMMER2_PBUFSIZE);
	if (dsize < 0) {
		hfree(buf, M_HAMMER2, HAMMER2_PBUFSIZE);
		WARN_ONCE(1, "hammer2: lz4 decompression failed at %lld\n",
		    (long long)xop->lbase);
		return (EIO);
	}

	if (skip >= (hammer2_off_t)dsize) {
		folio_zero_range(folio, 0, fsize);
	} else {
		len = dsize - skip;
		if (len > fsize)
			len = fsize;
		memcpy_to_folio(folio, 0, buf + skip, len);
		if (len < fsize)
			folio_zero_range(folio, len, fsize - len);
	}
	hfree(buf, M_HAMMER2, HAMMER2_PBUFSIZE);

	return (0);
}

/*
 * Decompress one ZLIB block into the folio.
 *
 * The kernel's zlib differs from userland's in shape and not in name,
 * which is the distinction this tree has been caught by before: a symbol
 * that resolves says nothing about the contract behind it.  There is no
 * inflateInit(); zlib_inflateInit() is a macro over zlib_inflateInit2()
 * and, like it, requires the caller to have already placed a workspace of
 * zlib_inflate_workspacesize() bytes in the stream.  Upstream's
 * inflateInit() allocates its own.
 *
 * The workspace is vmalloc'd because it is tens of kilobytes and is not
 * touched by any DMA, which is what the kernel's own callers of this
 * interface do.  There is no compressed length prefix here as there is for
 * LZ4: the block is the stream and avail_in is the whole of it, which is
 * upstream's reading too.
 *
 * The workspace and the 64 KiB buffer are allocated once per block now
 * that a folio is a block, as the LZ4 path above says.
 */
static int
hammer2_decompress_zlib(hammer2_xop_strategy_t *xop, hammer2_chain_t *focus,
    const char *data, hammer2_off_t skip)
{
	struct folio *folio = xop->folio;
	size_t fsize = folio_size(folio);
	struct z_stream_s strm;
	char *buf;
	size_t len;
	int dsize, ret;

	memset(&strm, 0, sizeof(strm));
	strm.workspace = vmalloc(zlib_inflate_workspacesize());	/* Linux */
	if (strm.workspace == NULL)
		return (ENOMEM);

	buf = hmalloc(HAMMER2_PBUFSIZE, M_HAMMER2, M_WAITOK);
	if (buf == NULL) {
		vfree(strm.workspace);
		return (ENOMEM);
	}

	ret = zlib_inflateInit(&strm);
	if (ret != Z_OK) {
		hfree(buf, M_HAMMER2, HAMMER2_PBUFSIZE);
		vfree(strm.workspace);
		WARN_ONCE(1, "hammer2: zlib init returned %d\n", ret);
		return (EIO);
	}

	/*
	 * Both casts are the sign difference and nothing else: zlib counts
	 * in Byte, which is unsigned char, and the media pointer and the
	 * scratch are both char *.  clang reports either under
	 * -Wpointer-sign and gcc reports neither.
	 */
	strm.next_in = (unsigned char *)data;
	strm.avail_in = focus->bytes;
	strm.next_out = (unsigned char *)buf;
	strm.avail_out = HAMMER2_PBUFSIZE;

	ret = zlib_inflate(&strm, Z_FINISH);
	dsize = HAMMER2_PBUFSIZE - strm.avail_out;
	zlib_inflateEnd(&strm);
	vfree(strm.workspace);

	/*
	 * Upstream zeroes its buffer here and reports success.  A stream
	 * that did not end is a block this module could not decode, and
	 * saying so is the only answer that cannot be mistaken for a file
	 * of zeroes.
	 */
	if (ret != Z_STREAM_END) {
		hfree(buf, M_HAMMER2, HAMMER2_PBUFSIZE);
		WARN_ONCE(1, "hammer2: zlib inflate returned %d at %lld\n",
		    ret, (long long)xop->lbase);
		return (EIO);
	}

	if (skip >= (hammer2_off_t)dsize) {
		folio_zero_range(folio, 0, fsize);
	} else {
		len = dsize - skip;
		if (len > fsize)
			len = fsize;
		memcpy_to_folio(folio, 0, buf + skip, len);
		if (len < fsize)
			folio_zero_range(folio, len, fsize - len);
	}
	hfree(buf, M_HAMMER2, HAMMER2_PBUFSIZE);

	return (0);
}

/*
 * Fill xop->folio from the collected chain.  Returns a positive errno by
 * the core's convention; the VFS boundary negates.
 *
 * WHAT DIFFERS FROM UPSTREAM, AND WHY IT IS NOT A LIBERTY.  Upstream
 * panics on an unknown compression type and on an unknown bref type, and
 * on a failed LZ4 decompression it zeroes its buffer, sets b_resid to 0
 * and reports success.  Neither is available here.  The port's rule for
 * the OS half is a warning plus recovery plus an errno, and more than that:
 * on Linux a folio marked uptodate is what every later reader of that file
 * offset gets, without asking this module again.  Zero-filling a folio
 * whose contents could not be decoded and calling it success is
 * indistinguishable, from userspace, from a file that really holds zeroes.
 * So every path that cannot produce the bytes returns an error and leaves
 * the folio not uptodate.
 *
 * LZ4 and ZLIB are written and measured against media that actually holds
 * each, `makefs` taking a CompressionType option.  Neither needed
 * vendoring: the kernel exports LZ4_decompress_safe() under the name
 * upstream already calls and zlib_inflate() beside it.
 */
static int
hammer2_strategy_read_completion(hammer2_xop_strategy_t *xop,
    hammer2_chain_t *focus, const char *data)
{
	struct folio *folio = xop->folio;
	size_t fsize = folio_size(folio);
	hammer2_off_t skip;
	size_t len;

	if (focus->bref.type == HAMMER2_BREF_TYPE_INODE) {
		/*
		 * The first HAMMER2_EMBEDDED_BYTES of a small file live in
		 * the inode itself, so the block base is the file base.
		 */
		const hammer2_inode_data_t *ripdata;

		ripdata = (const hammer2_inode_data_t *)data;
		if (xop->lbase != 0) {
			WARN_ONCE(1, "hammer2: embedded data at offset %lld\n",
			    (long long)xop->lbase);
			return (EIO);
		}
		len = fsize < HAMMER2_EMBEDDED_BYTES ?
		    fsize : HAMMER2_EMBEDDED_BYTES;
		memcpy_to_folio(folio, 0, ripdata->u.data, len);
		if (len < fsize)
			folio_zero_range(folio, len, fsize - len);
		return (0);
	}

	if (focus->bref.type != HAMMER2_BREF_TYPE_DATA) {
		WARN_ONCE(1, "hammer2: bad chain type %d in read\n",
		    focus->bref.type);
		return (EIO);
	}

	/*
	 * The chain covers a key range that begins at or below this folio,
	 * a logical block being up to HAMMER2_PBUFSIZE and a folio in a
	 * file mapping being one page.  So the bytes wanted start at an
	 * offset inside the block rather than at its base.  Upstream has no
	 * such offset because a DragonFly logical buffer is the block.
	 */
	if (xop->lbase < focus->bref.key) {
		WARN_ONCE(1, "hammer2: chain key %llx above read at %llx\n",
		    (unsigned long long)focus->bref.key,
		    (unsigned long long)xop->lbase);
		return (EIO);
	}
	skip = xop->lbase - focus->bref.key;

	switch (HAMMER2_DEC_COMP(focus->bref.methods)) {
	case HAMMER2_COMP_NONE:
	case HAMMER2_COMP_AUTOZERO:
		/*
		 * Stored uncompressed, so focus->bytes is the logical size
		 * and the wanted bytes can be copied straight out of it.
		 */
		if (skip >= focus->bytes) {
			folio_zero_range(folio, 0, fsize);
			return (0);
		}
		len = focus->bytes - skip;
		if (len > fsize)
			len = fsize;
		memcpy_to_folio(folio, 0, data + skip, len);
		if (len < fsize)
			folio_zero_range(folio, len, fsize - len);
		return (0);
	case HAMMER2_COMP_LZ4:
		return (hammer2_decompress_lz4(xop, focus, data, skip));
	case HAMMER2_COMP_ZLIB:
		return (hammer2_decompress_zlib(xop, focus, data, skip));
	default:
		WARN_ONCE(1, "hammer2: compression method %d is not read yet\n",
		    HAMMER2_DEC_COMP(focus->bref.methods));
		return (EIO);
	}
}

/*
 * Read one folio of a regular file.
 *
 * The folio arrives locked and must leave unlocked on every path,
 * including every error: a folio released still locked leaves the next
 * reader in folio_wait_locked() forever, which is a hang and writes no
 * report.  folio_mark_uptodate() is what makes the contents authoritative
 * for every later reader without asking this module again, so it is set
 * only where the bytes are known to be right.
 */
int
hammer2_read_folio(struct file *file __maybe_unused, struct folio *folio)
{
	hammer2_xop_strategy_t *xop;
	hammer2_inode_t *ip = VTOI(folio->mapping->host);
	hammer2_chain_t *focus;
	const char *data;
	int error;

	hammer2_inode_lock(ip, HAMMER2_RESOLVE_SHARED);
	xop = hammer2_xop_alloc(ip, 0);
	xop->lbase = folio_pos(folio);
	xop->folio = folio;
	hammer2_xop_start(&xop->head, &hammer2_strategy_read_desc);

	error = hammer2_error_to_errno(hammer2_xop_collect(&xop->head, 0));
	if (error == 0) {
		focus = xop->head.cluster.focus;
		data = hammer2_xop_gdata(&xop->head)->buf;
		error = hammer2_strategy_read_completion(xop, focus, data);
		hammer2_xop_pdata(&xop->head);
	} else if (error == ENOENT) {
		/*
		 * No chain covers this offset, which is a hole rather than
		 * a failure.  Upstream zeroes the buffer and reports
		 * success at the same place.
		 */
		folio_zero_range(folio, 0, folio_size(folio));
		error = 0;
	}
	hammer2_xop_retire(&xop->head, HAMMER2_XOPMASK_VOP);
	hammer2_inode_unlock(ip);

	/*
	 * Linux: the block is copied whole and a file's last block can
	 * carry bytes past its end, so zero from i_size to the end of the
	 * folio.  That is what nvextendbuf() does for upstream when a file
	 * grows, and what keeps a later extend from exposing them.
	 */
	if (error == 0) {
		loff_t isize = i_size_read(folio->mapping->host);

		if (isize < folio_pos(folio) + folio_size(folio))
			folio_zero_segment(folio, isize > folio_pos(folio) ?
			    isize - folio_pos(folio) : 0, folio_size(folio));
		folio_mark_uptodate(folio);
	}
	folio_unlock(folio);

	/* The block is already named in dmesg by hammer2_chain_testcheck(). */
	return (hammer2_vfs_errno(error));	/* Linux: negative, EDOM is EIO */
}

/*
 * Wait for pending I/O to complete.  Empty in the FreeBSD port too: the
 * DIO layer's writes complete synchronously.
 */
void
hammer2_bioq_sync(hammer2_pfs_t *pmp __maybe_unused)
{
}

/*
 * XXX Linux: FreeBSD orders these definitions so that only the two dedup
 * functions need prototypes; kbuild's -Wmissing-prototypes and the strict
 * ordering here want all of them declared, and this is where they are.
 */
static hammer2_chain_t *hammer2_assign_physical(hammer2_inode_t *,
    hammer2_chain_t **, hammer2_key_t, int, hammer2_tid_t, char **, int *);
static void hammer2_write_file_core(char *, hammer2_inode_t *,
    hammer2_chain_t **, hammer2_key_t, int, int, hammer2_tid_t, int *);
static void hammer2_compress_and_write(char *, hammer2_inode_t *,
    hammer2_chain_t **, hammer2_key_t, int, int, hammer2_tid_t, int *, int,
    int);
static void hammer2_zero_check_and_write(char *, hammer2_inode_t *,
    hammer2_chain_t **, hammer2_key_t, int, int, hammer2_tid_t, int *, int);
static int test_block_zeros(const char *, size_t);
static void zero_write(char *, hammer2_inode_t *, hammer2_chain_t **,
    hammer2_key_t, hammer2_tid_t, int *);
static void hammer2_write_bp(hammer2_chain_t *, char *, int, int,
    hammer2_tid_t, int *, int);
static void hammer2_dedup_record(hammer2_chain_t *, hammer2_io_t *,
    const char *);
static hammer2_off_t hammer2_dedup_lookup(hammer2_dev_t *, char **, int);

/*
 * Assign physical storage at (cparent, lbase), returning a suitable chain
 * and setting *errorp appropriately.
 *
 * If no error occurs, the returned chain will be in a modified state.
 *
 * If an error occurs, the returned chain may or may not be NULL.  If
 * not-null any chain->error (if not 0) will also be rolled up into *errorp.
 * So the caller only needs to test *errorp.
 *
 * cparent can wind up being anything.
 *
 * If datap is not NULL, *datap points to the real data we intend to write.
 * If we can dedup the storage location we set *datap to NULL to indicate
 * to the caller that a dedup occurred.
 *
 * NOTE: Special case for data embedded in inode.
 */
static hammer2_chain_t *
hammer2_assign_physical(hammer2_inode_t *ip, hammer2_chain_t **parentp,
    hammer2_key_t lbase, int pblksize, hammer2_tid_t mtid, char **datap,
    int *errorp)
{
	hammer2_chain_t *chain;
	hammer2_key_t key_dummy;
	hammer2_off_t dedup_off;
	int pradix;

	KKASSERT(pblksize >= HAMMER2_ALLOC_MIN);
	pradix = hammer2_getradix(pblksize);

	/*
	 * Locate the chain associated with lbase, return a locked chain.
	 * However, do not instantiate any data reference (which utilizes a
	 * device buffer) because we will be using direct IO via the
	 * logical buffer cache buffer.
	 */
	chain = hammer2_chain_lookup(parentp, &key_dummy, lbase, lbase, errorp,
	    HAMMER2_LOOKUP_NODATA);
	/*
	 * The lookup code should not return a DELETED chain to us, unless
	 * its a short-file embedded in the inode.  Then it is possible for
	 * the lookup to return a deleted inode.
	 */
	if (chain && (chain->flags & HAMMER2_CHAIN_DELETED) &&
	    chain->bref.type != HAMMER2_BREF_TYPE_INODE)
		hpanic("assign physical deleted %s chain %016llx/%d inum "
		    "%016llx lbase %016llx",
		    hammer2_breftype_to_str(chain->bref.type),
		    (long long)chain->bref.key, chain->bref.keybits,
		    (long long)ip->meta.inum, (long long)lbase);

	if (chain == NULL) {
		/*
		 * We found a hole, create a new chain entry.
		 *
		 * NOTE: DATA chains are created without device backing
		 *	 store (nor do we want any).
		 */
		dedup_off = hammer2_dedup_lookup((*parentp)->hmp, datap,
		    pblksize);
		*errorp |= hammer2_chain_create(parentp, &chain, NULL, ip->pmp,
		    HAMMER2_ENC_CHECK(ip->meta.check_algo) |
		    HAMMER2_ENC_COMP(HAMMER2_COMP_NONE), lbase,
		    HAMMER2_PBUFRADIX, HAMMER2_BREF_TYPE_DATA, pblksize, mtid,
		    dedup_off, 0);
		if (chain == NULL)
			goto failed;
	} else if (chain->error == 0) {
		switch (chain->bref.type) {
		case HAMMER2_BREF_TYPE_INODE:
			/*
			 * The data is embedded in the inode, which requires
			 * a bit more finess.
			 */
			*errorp |= hammer2_chain_modify_ip(ip, chain, mtid, 0);
			break;
		case HAMMER2_BREF_TYPE_DATA:
			dedup_off = hammer2_dedup_lookup(chain->hmp, datap,
			    pblksize);
			if (chain->bytes != (unsigned int)pblksize) {
				*errorp |= hammer2_chain_resize(chain, mtid,
				    dedup_off, pradix, HAMMER2_MODIFY_OPTDATA);
				if (*errorp)
					break;
			}
			/*
			 * DATA buffers must be marked modified whether the
			 * data is in a logical buffer or not.  We also have
			 * to make this call to fixup the chain data pointers
			 * after resizing in case this is an encrypted or
			 * compressed buffer.
			 */
			*errorp |= hammer2_chain_modify(chain, mtid, dedup_off,
			    HAMMER2_MODIFY_OPTDATA);
			break;
		default:
			hpanic("bad blockref type %d", chain->bref.type);
			break;
		}
	} else {
		*errorp = chain->error;
	}
	atomic_set_int(&ip->flags, HAMMER2_INODE_DIRTYDATA);
failed:
	return (chain);
}

/*
 * The core write function which determines which path to take
 * depending on compression settings.  We also have to locate the
 * related chains so we can calculate and set the check data for
 * the blockref.
 */
static void
hammer2_write_file_core(char *data, hammer2_inode_t *ip,
    hammer2_chain_t **parentp, hammer2_key_t lbase, int ioflag, int pblksize,
    hammer2_tid_t mtid, int *errorp)
{
	hammer2_chain_t *chain;
	hammer2_inode_data_t *wipdata;
	char *bdata;

	*errorp = 0;

	switch (HAMMER2_DEC_ALGO(ip->meta.comp_algo)) {
	case HAMMER2_COMP_NONE:
		/*
		 * We have to assign physical storage to the buffer
		 * we intend to dirty or write now to avoid deadlocks
		 * in the strategy code later.
		 *
		 * This can return NOOFFSET for inode-embedded data.
		 * The strategy code will take care of it in that case.
		 */
		bdata = data;
		chain = hammer2_assign_physical(ip, parentp, lbase, pblksize,
		    mtid, &bdata, errorp);
		if (*errorp) {
			/* Skip modifications. */
		} else if (chain->bref.type == HAMMER2_BREF_TYPE_INODE) {
			wipdata = &chain->data->ipdata;
			KKASSERT(wipdata->meta.op_flags &
			    HAMMER2_OPFLAG_DIRECTDATA);
			bcopy(data, wipdata->u.data, HAMMER2_EMBEDDED_BYTES);
		} else if (bdata == NULL) {
			/* Copy of data already present on-media. */
			chain->bref.methods =
			    HAMMER2_ENC_COMP(HAMMER2_COMP_NONE) +
			    HAMMER2_ENC_CHECK(ip->meta.check_algo);
			hammer2_chain_setcheck(chain, data);
			atomic_clear_int(&chain->flags, HAMMER2_CHAIN_INITIAL);
		} else {
			hammer2_write_bp(chain, data, ioflag, pblksize, mtid,
			    errorp, ip->meta.check_algo);
		}
		if (chain) {
			hammer2_chain_unlock(chain);
			hammer2_chain_drop(chain);
		}
		break;
	case HAMMER2_COMP_AUTOZERO:
		/* Check for zero-fill only. */
		hammer2_zero_check_and_write(data, ip, parentp, lbase, ioflag,
		    pblksize, mtid, errorp, ip->meta.check_algo);
		break;
	case HAMMER2_COMP_LZ4:
	case HAMMER2_COMP_ZLIB:
	default:
		/* Check for zero-fill and attempt compression. */
		hammer2_compress_and_write(data, ip, parentp, lbase, ioflag,
		    pblksize, mtid, errorp, ip->meta.comp_algo,
		    ip->meta.check_algo);
		break;
	}
}

/*
 * Generic function that will perform the compression in compression
 * write path. The compression algorithm is determined by the settings
 * obtained from inode.
 */
static void
hammer2_compress_and_write(char *data, hammer2_inode_t *ip,
    hammer2_chain_t **parentp, hammer2_key_t lbase, int ioflag, int pblksize,
    hammer2_tid_t mtid, int *errorp, int comp_algo, int check_algo)
{
	hammer2_chain_t *chain;
	hammer2_inode_data_t *wipdata;
	hammer2_io_t *dio;
	z_stream strm_compress;
	char *lz4_wrkmem;	/* Linux */
	char *comp_buffer, *bdata;
	int comp_size, comp_block_size, comp_level, ret;

	KKASSERT(pblksize / 2 <= 32768);
	KKASSERT(pblksize / 2 <= HAMMER2_PBUFSIZE / 2);

	/*
	 * An all-zeros write creates a hole unless the check code
	 * is disabled.  When the check code is disabled all writes
	 * are done in-place, including any all-zeros writes.
	 *
	 * NOTE: A snapshot will still force a copy-on-write
	 *	 (see the HAMMER2_CHECK_NONE in hammer2_chain.c).
	 */
	if (check_algo != HAMMER2_CHECK_NONE &&
	    test_block_zeros(data, pblksize)) {
		zero_write(data, ip, parentp, lbase, mtid, errorp);
		return;
	}

	/*
	 * Compression requested.  Try to compress the block.  We store
	 * the data normally if we cannot sufficiently compress it.
	 *
	 * We have a heuristic to detect files which are mostly
	 * uncompressable and avoid the compression attempt in that
	 * case.  If the compression heuristic is turned off, we always
	 * try to compress.
	 */
	comp_size = 0;
	comp_buffer = NULL;

	if (ip->comp_heuristic < 8 || (ip->comp_heuristic & 7) == 0 ||
	    hammer2_always_compress) {
		switch (HAMMER2_DEC_ALGO(comp_algo)) {
		case HAMMER2_COMP_LZ4:
			/*
			 * We need to prefix with the size, LZ4
			 * doesn't do it for us.  Add the related
			 * overhead.
			 *
			 * NOTE: The LZ4 code seems to assume at least an
			 *	 8-byte buffer size granularity and may
			 *	 overrun the buffer if given a 4-byte
			 *	 granularity.
			 */
			comp_buffer = hmalloc(HAMMER2_PBUFSIZE, M_HAMMER2, M_WAITOK); /* XXX Linux: was hammer2_zone_wbuf */
			lz4_wrkmem = hmalloc(LZ4_MEM_COMPRESS, M_HAMMER2, M_WAITOK); /* Linux */
			comp_size = LZ4_compress_default(data, /* XXX Linux: was LZ4_compress_limitedOutput */
			    &comp_buffer[sizeof(int)], pblksize,
			    pblksize / 2 - sizeof(int64_t), lz4_wrkmem);
			hfree(lz4_wrkmem, M_HAMMER2, LZ4_MEM_COMPRESS); /* Linux */
			*(int *)comp_buffer = comp_size;
			if (comp_size)
				comp_size += sizeof(int);
			break;
		case HAMMER2_COMP_ZLIB:
			comp_level = HAMMER2_DEC_LEVEL(comp_algo);
			if (comp_level == 0)
				comp_level = 6; /* default zlib compression */
			else if (comp_level < 6)
				comp_level = 6;
			else if (comp_level > 9)
				comp_level = 9;
			bzero(&strm_compress, sizeof(strm_compress));
			/* XXX Linux: the kernel's zlib takes a caller-owned workspace */
			strm_compress.workspace = vmalloc(
			    zlib_deflate_workspacesize(MAX_WBITS, MAX_MEM_LEVEL));
			ret = strm_compress.workspace ?
			    zlib_deflateInit(&strm_compress, comp_level) : Z_MEM_ERROR;
			if (ret != Z_OK)
				hprintf("fatal error on deflateInit\n");

			comp_buffer = hmalloc(HAMMER2_PBUFSIZE, M_HAMMER2, M_WAITOK); /* XXX Linux: was hammer2_zone_wbuf */
			strm_compress.next_in = (Byte *)data;	/* XXX Linux: Bytef is unsigned */
			strm_compress.avail_in = pblksize;
			strm_compress.next_out = (Byte *)comp_buffer;	/* XXX Linux */
			strm_compress.avail_out = pblksize / 2;
			ret = ret == Z_OK ? zlib_deflate(&strm_compress, Z_FINISH) : ret; /* XXX Linux */
			if (ret == Z_STREAM_END)
				comp_size = pblksize / 2 -
				    strm_compress.avail_out;
			else
				comp_size = 0;
			ret = zlib_deflateEnd(&strm_compress); /* XXX Linux */
			vfree(strm_compress.workspace); /* Linux */
			break;
		default:
			hprintf("unknown compression method %d\n", comp_algo);
			break;
		}
	}

	if (comp_size == 0) {
		/* Compression failed or turned off. */
		comp_block_size = pblksize; /* safety */
		if (++ip->comp_heuristic > 128)
			ip->comp_heuristic = 8;
	} else {
		/* Compression succeeded. */
		ip->comp_heuristic = 0;
		if (comp_size <= 1024) {
			comp_block_size = 1024;
		} else if (comp_size <= 2048) {
			comp_block_size = 2048;
		} else if (comp_size <= 4096) {
			comp_block_size = 4096;
		} else if (comp_size <= 8192) {
			comp_block_size = 8192;
		} else if (comp_size <= 16384) {
			comp_block_size = 16384;
		} else if (comp_size <= 32768) {
			comp_block_size = 32768;
		} else {
			hpanic("weird comp_size value");
			/* NOT REACHED */
		}
		/*
		 * Must zero the remainder or dedup (which operates on a
		 * physical block basis) will not find matches.
		 */
		if (comp_size < comp_block_size)
			bzero(comp_buffer + comp_size,
			    comp_block_size - comp_size);
	}

	/*
	 * Assign physical storage, bdata will be set to NULL if a live-dedup
	 * was successful.
	 */
	bdata = comp_size ? comp_buffer : data;
	chain = hammer2_assign_physical(ip, parentp, lbase, comp_block_size,
	    mtid, &bdata, errorp);
	if (*errorp)
		goto done;
	if (chain->bref.type == HAMMER2_BREF_TYPE_INODE) {
		*errorp = hammer2_chain_modify_ip(ip, chain, mtid, 0);
		if (*errorp == 0) {
			wipdata = &chain->data->ipdata;
			KKASSERT(wipdata->meta.op_flags &
			    HAMMER2_OPFLAG_DIRECTDATA);
			bcopy(data, wipdata->u.data, HAMMER2_EMBEDDED_BYTES);
		}
	} else if (bdata == NULL) {
		/*
		 * Live deduplication, a copy of the data is already present
		 * on the media.
		 */
		if (comp_size)
			chain->bref.methods =
			    HAMMER2_ENC_COMP(comp_algo) +
			    HAMMER2_ENC_CHECK(check_algo);
		else
			chain->bref.methods =
			    HAMMER2_ENC_COMP(HAMMER2_COMP_NONE) +
			    HAMMER2_ENC_CHECK(check_algo);
		bdata = comp_size ? comp_buffer : data;
		hammer2_chain_setcheck(chain, bdata);
		atomic_clear_int(&chain->flags, HAMMER2_CHAIN_INITIAL);
	} else {
		KKASSERT(chain->flags & HAMMER2_CHAIN_MODIFIED);
		switch (chain->bref.type) {
		case HAMMER2_BREF_TYPE_INODE:
			hpanic("unexpected inode");
			break;
		case HAMMER2_BREF_TYPE_DATA:
			/* Optimize out the read-before-write if possible. */
			*errorp = hammer2_io_newnz(chain->hmp, chain->bref.type,
			    chain->bref.data_off, chain->bytes, &dio);
			if (*errorp) {
				hammer2_io_brelse(&dio);
				hprintf("getblk error %d\n", *errorp);
				break;
			}
			bdata = hammer2_io_data(dio, chain->bref.data_off);
			/*
			 * When loading the block make sure we don't
			 * leave garbage after the compressed data.
			 */
			if (comp_size) {
				chain->bref.methods =
				    HAMMER2_ENC_COMP(comp_algo) +
				    HAMMER2_ENC_CHECK(check_algo);
				bcopy(comp_buffer, bdata, comp_block_size);
			} else {
				chain->bref.methods =
				    HAMMER2_ENC_COMP(HAMMER2_COMP_NONE) +
				    HAMMER2_ENC_CHECK(check_algo);
				bcopy(data, bdata, pblksize);
			}
			/*
			 * The flush code doesn't calculate check codes for
			 * file data (doing so can result in excessive I/O),
			 * so we do it here.
			 */
			hammer2_chain_setcheck(chain, bdata);
			/*
			 * Device buffer is now valid, chain is no longer in
			 * the initial state.
			 *
			 * (No blockref table worries with file data)
			 */
			atomic_clear_int(&chain->flags, HAMMER2_CHAIN_INITIAL);
			hammer2_dedup_record(chain, dio, bdata);
			/* Now write the related dio. */
			if (ioflag & IO_SYNC)
				hammer2_io_bwrite(&dio);
			else if (ioflag & IO_ASYNC)
				hammer2_io_bawrite(&dio);
			else
				hammer2_io_bdwrite(&dio);
			break;
		default:
			hpanic("bad blockref type %d", chain->bref.type);
			break;
		}
	}
done:
	if (chain) {
		hammer2_chain_unlock(chain);
		hammer2_chain_drop(chain);
	}
	if (comp_buffer)
		hfree(comp_buffer, M_HAMMER2, HAMMER2_PBUFSIZE) /* XXX Linux */;
}

/*
 * Function that performs zero-checking and writing without compression,
 * it corresponds to default zero-checking path.
 */
static void
hammer2_zero_check_and_write(char *data, hammer2_inode_t *ip,
    hammer2_chain_t **parentp, hammer2_key_t lbase, int ioflag, int pblksize,
    hammer2_tid_t mtid, int *errorp, int check_algo)
{
	hammer2_chain_t *chain;
	char *bdata;

	if (check_algo != HAMMER2_CHECK_NONE &&
	    test_block_zeros(data, pblksize)) {
		/*
		 * An all-zeros write creates a hole unless the check code
		 * is disabled.  When the check code is disabled all writes
		 * are done in-place, including any all-zeros writes.
		 *
		 * NOTE: A snapshot will still force a copy-on-write
		 *	 (see the HAMMER2_CHECK_NONE in hammer2_chain.c).
		 */
		zero_write(data, ip, parentp, lbase, mtid, errorp);
	} else {
		/* Normal write (bdata set to NULL if de-duplicated). */
		bdata = data;
		chain = hammer2_assign_physical(ip, parentp, lbase, pblksize,
		    mtid, &bdata, errorp);
		if (*errorp) {
			/* Do nothing. */
		} else if (bdata) {
			hammer2_write_bp(chain, data, ioflag, pblksize, mtid,
			    errorp, check_algo);
		} else {
			/* Dedup occurred. */
			chain->bref.methods =
			    HAMMER2_ENC_COMP(HAMMER2_COMP_NONE) +
			    HAMMER2_ENC_CHECK(check_algo);
			hammer2_chain_setcheck(chain, data);
			atomic_clear_int(&chain->flags, HAMMER2_CHAIN_INITIAL);
		}
		if (chain) {
			hammer2_chain_unlock(chain);
			hammer2_chain_drop(chain);
		}
	}
}

/*
 * A function to test whether a block of data contains only zeros,
 * returns TRUE (non-zero) if the block is all zeros.
 */
static int
test_block_zeros(const char *buf, size_t bytes)
{
	size_t i;

	for (i = 0; i < bytes; i += sizeof(long)) {
		if (*(const long *)(buf + i) != 0)
			return (0);
	}
	return (1);
}

/*
 * Function to "write" a block that contains only zeros.
 */
static void
zero_write(char *data, hammer2_inode_t *ip, hammer2_chain_t **parentp,
    hammer2_key_t lbase, hammer2_tid_t mtid, int *errorp)
{
	hammer2_chain_t *chain;
	hammer2_inode_data_t *wipdata;
	hammer2_key_t key_dummy;

	chain = hammer2_chain_lookup(parentp, &key_dummy, lbase, lbase, errorp,
	    HAMMER2_LOOKUP_NODATA);
	if (chain) {
		if (chain->bref.type == HAMMER2_BREF_TYPE_INODE) {
			if (*errorp == 0)
				*errorp = hammer2_chain_modify_ip(ip, chain,
				    mtid, 0);
			if (*errorp == 0) {
				wipdata = &chain->data->ipdata;
				KKASSERT(wipdata->meta.op_flags &
				    HAMMER2_OPFLAG_DIRECTDATA);
				bzero(wipdata->u.data, HAMMER2_EMBEDDED_BYTES);
			}
		} else {
			/* chain->error ok for deletion */
			hammer2_chain_delete(*parentp, chain, mtid,
			    HAMMER2_DELETE_PERMANENT);
		}
		atomic_set_int(&ip->flags, HAMMER2_INODE_DIRTYDATA);
		hammer2_chain_unlock(chain);
		hammer2_chain_drop(chain);
	}
}

/*
 * Function to write the data as it is, without performing any sort of
 * compression. This function is used in path without compression and
 * default zero-checking path.
 */
static void
hammer2_write_bp(hammer2_chain_t *chain, char *data, int ioflag, int pblksize,
    hammer2_tid_t mtid, int *errorp, int check_algo)
{
	hammer2_inode_data_t *wipdata;
	hammer2_io_t *dio;
	char *bdata;
	int error = 0;

	KKASSERT(chain->flags & HAMMER2_CHAIN_MODIFIED);

	switch (chain->bref.type) {
	case HAMMER2_BREF_TYPE_INODE:
		wipdata = &chain->data->ipdata;
		KKASSERT(wipdata->meta.op_flags & HAMMER2_OPFLAG_DIRECTDATA);
		bcopy(data, wipdata->u.data, HAMMER2_EMBEDDED_BYTES);
		error = 0;
		break;
	case HAMMER2_BREF_TYPE_DATA:
		error = hammer2_io_newnz(chain->hmp, chain->bref.type,
		    chain->bref.data_off, chain->bytes, &dio);
		if (error) {
			hammer2_io_bqrelse(&dio);
			hprintf("getblk error %d\n", error);
			break;
		}
		bdata = hammer2_io_data(dio, chain->bref.data_off);
		chain->bref.methods =
		    HAMMER2_ENC_COMP(HAMMER2_COMP_NONE) +
		    HAMMER2_ENC_CHECK(check_algo);
		bcopy(data, bdata, chain->bytes);
		/*
		 * The flush code doesn't calculate check codes for
		 * file data (doing so can result in excessive I/O),
		 * so we do it here.
		 */
		hammer2_chain_setcheck(chain, bdata);
		/*
		 * Device buffer is now valid, chain is no longer in
		 * the initial state.
		 *
		 * (No blockref table worries with file data)
		 */
		atomic_clear_int(&chain->flags, HAMMER2_CHAIN_INITIAL);
		hammer2_dedup_record(chain, dio, bdata);
		/* Now write the related dio. */
		if (ioflag & IO_SYNC)
			hammer2_io_bwrite(&dio);
		else if (ioflag & IO_ASYNC)
			hammer2_io_bawrite(&dio);
		else
			hammer2_io_bdwrite(&dio);
		break;
	default:
		hpanic("bad blockref type %d", chain->bref.type);
		break;
	}
	*errorp = error;
}

/*
 * LIVE DEDUP HEURISTICS
 *
 * Record media and crc information for possible dedup operation.  Note
 * that the dedup mask bits must also be set in the related DIO for a dedup
 * to be fully validated (which is handled in the freemap allocation code).
 *
 * WARNING! This code is SMP safe but the heuristic allows SMP collisions.
 *	    All fields must be loaded into locals and validated.
 *
 * WARNING! Should only be used for file data and directory entries,
 *	    hammer2_chain_modify() only checks for the dedup case on data
 *	    chains.  Also, dedup data can only be recorded for committed
 *	    chains (so NOT strategy writes which can undergo further
 *	    modification after the fact!).
 */
static void
hammer2_dedup_record(hammer2_chain_t *chain, hammer2_io_t *dio,
    const char *data)
{
	hammer2_dev_t *hmp = chain->hmp;
	hammer2_dedup_t *dedup;
	uint64_t crc, mask;
	int i, dticks, best = 0;

	/*
	 * We can only record a dedup if we have media data to test against.
	 * If dedup is not enabled, return early, which allows a chain to
	 * remain marked MODIFIED (which might have benefits in special
	 * situations, though typically it does not).
	 */
	if (hammer2_dedup_enable == 0)
		return;
	if (dio == NULL) {
		dio = chain->dio;
		if (dio == NULL)
			return;
	}
	hammer2_mtx_assert_unlocked(&dio->lock);

	switch (HAMMER2_DEC_CHECK(chain->bref.methods)) {
	case HAMMER2_CHECK_ISCSI32:
		/*
		 * XXX use the built-in crc (the dedup lookup sequencing
		 * needs to be fixed so the check code is already present
		 * when dedup_lookup is called)
		 */
		crc = XXH64(data, chain->bytes, XXH_HAMMER2_SEED);
		break;
	case HAMMER2_CHECK_XXHASH64:
		crc = chain->bref.check.xxhash64.value;
		break;
	case HAMMER2_CHECK_SHA192:
		/*
		 * XXX use the built-in crc (the dedup lookup sequencing
		 * needs to be fixed so the check code is already present
		 * when dedup_lookup is called)
		 */
		crc = XXH64(data, chain->bytes, XXH_HAMMER2_SEED);
		break;
	default:
		/*
		 * Cannot dedup without a check code.
		 *
		 * NOTE: In particular, CHECK_NONE allows a sector to be
		 *	 overwritten without copy-on-write, recording
		 *	 a dedup block for a CHECK_NONE object would be
		 *	 a disaster!
		 */
		return;
	}

	atomic_set_int(&chain->flags, HAMMER2_CHAIN_DEDUPABLE);

	dedup = &hmp->heur_dedup[crc & (HAMMER2_DEDUP_HEUR_MASK & ~3)];
	for (i = 0; i < 4; ++i) {
		if (dedup[i].data_crc == crc) {
			best = i;
			break;
		}
		dticks = (int)(dedup[i].ticks - dedup[best].ticks);
		if (dticks < 0 || dticks > hz * 60 * 30)
			best = i;
	}

	dedup += best;
	dedup->ticks = getticks();
	dedup->data_off = chain->bref.data_off;
	dedup->data_crc = crc;

	/*
	 * Set the valid bits for the dedup only after we know the data
	 * buffer has been updated.  The alloc bits were set (and the valid
	 * bits cleared) when the media was allocated.
	 *
	 * This is done in two stages becuase the bulkfree code can race
	 * the gap between allocation and data population.  Both masks must
	 * be set before a bcmp/dedup operation is able to use the block.
	 */
	mask = hammer2_dedup_mask(dio, chain->bref.data_off, chain->bytes);
	hammer2_mtx_ex(&dio->lock);
	dio->dedup_valid |= mask; /* DragonFly uses atomic_set_64 */
	hammer2_mtx_unlock(&dio->lock);
}

static hammer2_off_t
hammer2_dedup_lookup(hammer2_dev_t *hmp, char **datap, int pblksize)
{
	hammer2_dedup_t *dedup;
	hammer2_io_t *dio;
	hammer2_off_t off;
	char *data, *dtmp;
	uint64_t crc, mask;
	int i;

	if (hammer2_dedup_enable == 0)
		return (0);
	data = *datap;
	if (data == NULL)
		return (0);

	/*
	 * XXX use the built-in crc (the dedup lookup sequencing
	 * needs to be fixed so the check code is already present
	 * when dedup_lookup is called)
	 */
	crc = XXH64(data, pblksize, XXH_HAMMER2_SEED);
	dedup = &hmp->heur_dedup[crc & (HAMMER2_DEDUP_HEUR_MASK & ~3)];

	for (i = 0; i < 4; ++i) {
		off = dedup[i].data_off;
		cpu_ccfence();
		if (dedup[i].data_crc != crc)
			continue;
		if ((1 << (int)(off & HAMMER2_OFF_MASK_RADIX)) != pblksize)
			continue;
		dio = hammer2_io_getquick(hmp, off, pblksize);
		if (dio) {
			dtmp = hammer2_io_data(dio, off),
			mask = hammer2_dedup_mask(dio, off, pblksize);
			hammer2_mtx_assert_unlocked(&dio->lock);
			hammer2_mtx_ex(&dio->lock);
			if ((dio->dedup_alloc & mask) == mask &&
			    (dio->dedup_valid & mask) == mask &&
			    bcmp(data, dtmp, pblksize) == 0) {
				hammer2_mtx_unlock(&dio->lock);
				hammer2_io_putblk(&dio);
				*datap = NULL;
				dedup[i].ticks = getticks();
				return (off);
			}
			hammer2_mtx_unlock(&dio->lock);
			hammer2_io_putblk(&dio);
		}
	}
	return (0);
}

/*
 * The write half of the strategy XOP, upstream's body with the buffer
 * replaced by a folio the way the read half was.  The caller is what the
 * BSD ports' hammer2_strategy_write() is: it marks the inode DIRTYDATA,
 * enters a BUFCACHE transaction, allocates a MODIFYING|STRATEGY xop with
 * the folio and its position, and starts this; the transaction is closed
 * here, as upstream closes it.
 *
 * XXX Linux: the folio must cover the whole logical block, which is the
 * file mapping carrying folios of at least HAMMER2_PBUFRADIX order, the
 * same contract the DIO layer sets on the device mapping.  A smaller
 * folio would have this write zeros over the rest of the block, so it is
 * refused rather than padded.  hammer2_writepages() starts it, one
 * folio per XOP, and reads back what it fed the mapping's error.
 */
void
hammer2_xop_strategy_write(hammer2_xop_t *arg, void *scratch, int clindex)
{
	hammer2_xop_strategy_t *xop = &arg->xop_strategy;
	hammer2_chain_t *parent;
	hammer2_inode_t *ip = xop->head.ip1; /* retained by ref */
	hammer2_key_t lbase = xop->lbase;
	struct folio *folio = xop->folio;	/* XXX Linux: was struct buf *bp */
	char *bio_data = scratch;
	int error, lblksize, pblksize;

	lblksize = hammer2_calc_logical(ip, lbase, &lbase, NULL);
	pblksize = hammer2_calc_physical(ip, lbase);
	KKASSERT(lblksize <= MAXPHYS);
	if (WARN_ON_ONCE(folio_size(folio) < (size_t)lblksize)) { /* Linux */
		hammer2_xop_feed(&xop->head, NULL, clindex, HAMMER2_ERROR_EIO);
		goto done;
	}
	memcpy_from_folio(bio_data, folio, 0, lblksize); /* XXX Linux: bcopy(bp->b_data) */
	folio = NULL; /* safety, illegal to access after unlock */

	parent = hammer2_inode_chain(ip, clindex, HAMMER2_RESOLVE_ALWAYS);
	hammer2_write_file_core(bio_data, ip, &parent, lbase, IO_ASYNC,
	    pblksize, xop->head.mtid, &error);
	if (parent) {
		hammer2_chain_unlock(parent);
		hammer2_chain_drop(parent);
		parent = NULL; /* safety */
	}
	hammer2_xop_feed(&xop->head, NULL, clindex, error);
done:
	error = hammer2_xop_collect(&xop->head, HAMMER2_XOP_COLLECT_NOWAIT);

	folio = xop->folio; /* now owned by us */
	if (error == HAMMER2_ERROR_ENOENT || error == 0) {
		folio_end_writeback(folio);	/* XXX Linux: bufdone(bp) */
	} else {
		hprintf("error %08x at lbase %016llx\n",
		    error, (long long)xop->lbase);
		/*
		 * XXX Linux: was BIO_ERROR with b_error = EIO.  The kernel
		 * keeps ENOSPC distinct from EIO in writeback errors, and
		 * fsync(2) on a volume that ran out of space during
		 * writeback reports it as ext4 and iomap do.
		 */
		mapping_set_error(folio->mapping,
		    hammer2_vfs_errno(hammer2_error_to_errno(error)));
		folio_end_writeback(folio);
	}

	hammer2_trans_assert_strategy(ip->pmp);
	hammer2_trans_done(ip->pmp, HAMMER2_TRANS_BUFCACHE);
}
