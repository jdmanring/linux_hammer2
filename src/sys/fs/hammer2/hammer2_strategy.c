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
 * ponytail: a 4 KiB folio decompresses its whole 64 KiB block, so reading
 * a compressed block through sixteen folios decompresses it sixteen times.
 * Upstream does it once because a DragonFly logical buffer is the block.
 * The fix is a mapping that carries 64 KiB folios, not a cache here.
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
 * ponytail: allocates a workspace and a 64 KiB buffer per folio, so a
 * compressed block read through sixteen folios does both sixteen times.
 * Same ceiling as the LZ4 path above and the same fix, a mapping that
 * carries 64 KiB folios.
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

	if (error == 0)
		folio_mark_uptodate(folio);
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
 * DEFER(the write path lands: 0.5): the body is upstream's
 * hammer2_xop_strategy_write() and the six static functions beneath it,
 * hammer2_assign_physical() through hammer2_write_bp(), plus
 * hammer2_dedup_record() and hammer2_dedup_lookup().
 */
void
hammer2_xop_strategy_write(hammer2_xop_t *arg, void *scratch, int clindex)
{
	hammer2_xop_strategy_t *xop = &arg->xop_strategy;

	WARN_ONCE(1, "hammer2: strategy write reached at a read-only milestone\n");
	hammer2_xop_feed(&xop->head, NULL, clindex, HAMMER2_ERROR_EIO);
}
