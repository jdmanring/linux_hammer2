/* SPDX-License-Identifier: BSD-3-Clause */
/*-
 * Copyright (c) 2026 James Manring <james_manring@yahoo.com>
 * Copyright (c) 2022-2023 Tomohiro Kusumi <tkusumi@netbsd.org>
 * Copyright (c) 2011-2022 The DragonFly Project.  All rights reserved.
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


#ifndef _FS_HAMMER2_XXHASH_H_
#define _FS_HAMMER2_XXHASH_H_

/*
 * The kernel's own xxHash, not the vendored copy the BSD ports carry.
 * H0's vendored-library audit found DragonFly's xxHash stock, so the
 * substitution is safe while both remain so, and test/xxh64-vectors.c is
 * what measures that: it checks the reference digests under HAMMER2's own
 * seed, which is "MattDlln" in ASCII.
 *
 * The BSD ports include "xxhash/xxhash.h" here and get XXH64 as a
 * function; Linux spells it xxh64 and takes the same three arguments in
 * the same order, so the core's call sites are unchanged.
 */
/* Linux */
#include <linux/xxhash.h>

#define XXH_HAMMER2_SEED	0x4d617474446c6c6eLLU

#define XXH64(input, length, seed)	xxh64((input), (length), (seed))

#endif /* !_FS_HAMMER2_XXHASH_H_ */
