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
/*
 * The slab allocator, for the xop zone. In 7.2 kmem_cache_create is a
 * variadic MACRO dispatching on its third argument, and it still accepts
 * the legacy (name, size, align, flags, ctor) form the shim calls; this
 * stub declares that form directly, since a stub exists to check the
 * shim's internal consistency and not to reproduce the kernel's dispatch.
 * Signatures transcribed from include/linux/slab.h at 7.2.0-cachyos:
 * kmem_cache_destroy at :482, kmem_cache_free at :888.
 */
struct kmem_cache;
struct kmem_cache *kmem_cache_create(const char *name, unsigned int size,
				     unsigned int align, unsigned long flags,
				     void (*ctor)(void *));
void kmem_cache_destroy(struct kmem_cache *s);
void *kmem_cache_alloc(struct kmem_cache *s, gfp_t flags);
void kmem_cache_free(struct kmem_cache *s, void *objp);

#endif
