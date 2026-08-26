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


#ifndef _CRYPTO_SHA2_SHA256_H_
#define _CRYPTO_SHA2_SHA256_H_

/*
 * FreeBSD's <crypto/sha2/sha256.h> spelled in the kernel's own SHA-256.
 * hammer2_chain.c includes that path by name and calls SHA256_Init,
 * _Update and _Final, so the header is provided at the path the core
 * expects rather than the include being edited - the same move as the
 * vendored <sys/tree.h> and <sys/queue.h> one directory up.
 *
 * THE ARGUMENT ORDER IS REVERSED BETWEEN THE TWO. FreeBSD's
 * SHA256_Final(digest, ctx) puts the output first; the kernel's
 * sha256_final(ctx, out) puts it second. Getting that backwards compiles
 * cleanly on any target where both are pointers and writes the digest
 * into the context, so the wrapper below is the only place it is stated.
 */
/* Linux */
#include <crypto/sha2.h>

#define SHA256_DIGEST_LENGTH	SHA256_DIGEST_SIZE

typedef struct sha256_ctx SHA256_CTX;

static inline void
SHA256_Init(SHA256_CTX *ctx)
{
	sha256_init(ctx);
}

static inline void
SHA256_Update(SHA256_CTX *ctx, const void *data, size_t len)
{
	sha256_update(ctx, data, len);
}

static inline void
SHA256_Final(unsigned char *digest, SHA256_CTX *ctx)
{
	sha256_final(ctx, digest);
}

#endif /* !_CRYPTO_SHA2_SHA256_H_ */
