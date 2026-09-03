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
 * this port has no ->read_folio and no ->writepages to start one; a mount
 * still fails before any of that, at DEFER(a mount can succeed).  The
 * floors are what makes that unreachability visible at link time rather
 * than asserted here.
 *
 * WHY A FLOOR RATHER THAN A CARRY.  Upstream's file is 1132 lines and is
 * not carryable: it includes <sys/bio.h>, hammer2_lz4.h and
 * <contrib/zlib/zlib.h>, and its read half copies into a struct buf.  The
 * two compression dependencies are not dependencies on Linux, which was
 * measured rather than assumed: the kernel exports LZ4_decompress_safe()
 * from vmlinux under the name upstream already calls, and zlib_inflate(),
 * zlib_inflateInit2() and zlib_inflate_workspacesize() beside it, all four
 * confirmed present at v7.2.  Nothing needs vendoring.  What remains is
 * the buffer, and that is the rewrite: the destination of a read is a
 * folio, which is why hammer2_xop_strategy carries one.
 *
 * The write handler is a floor for a second reason on top of the first.
 * The write path is 0.5.  It is not deferred here because it is hard; it
 * is deferred because a read-only milestone that can write is not a
 * read-only milestone.
 */

#include "hammer2.h"

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
 * DEFER(the read path lands, with ->read_folio): the body is upstream's
 * hammer2_xop_strategy_read() down to hammer2_xop_collect(), then a
 * completion that copies into xop->folio instead of a struct buf: the
 * embedded-inode case, the three HAMMER2_DEC_COMP() cases on the kernel's
 * own LZ4 and zlib, and hammer2_dedup_record() for the on-media case.
 */
void
hammer2_xop_strategy_read(hammer2_xop_t *arg, void *scratch, int clindex)
{
	hammer2_xop_strategy_t *xop = &arg->xop_strategy;

	WARN_ONCE(1, "hammer2: strategy read reached with no read path\n");
	hammer2_xop_feed(&xop->head, NULL, clindex, HAMMER2_ERROR_EIO);
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
