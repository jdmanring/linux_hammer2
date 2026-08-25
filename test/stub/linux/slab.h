/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_SLAB_H_
#define _H2_STUB_SLAB_H_
#include <linux/kernel.h>
/* Signatures from include/linux/slab.h at v7.1. */
void *kvmalloc(size_t size, gfp_t flags);
void *kvrealloc(const void *p, size_t size, gfp_t flags);
void kvfree(const void *addr);
void kfree(const void *objp);
char *kstrdup(const char *s, gfp_t gfp);
#endif
