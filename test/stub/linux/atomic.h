/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_ATOMIC_H_
#define _H2_STUB_ATOMIC_H_
#include <linux/kernel.h>
/* The atomic_t operations the lock word uses. */
typedef struct { int counter; } atomic_t;
int atomic_read(const atomic_t *v);
void atomic_set(atomic_t *v, int i);
void atomic_set_release(atomic_t *v, int i);
void atomic_inc(atomic_t *v);
void atomic_dec(atomic_t *v);
int atomic_dec_return_release(atomic_t *v);
int atomic_try_cmpxchg_acquire(atomic_t *v, int *old, int new);
#define smp_mb() do {} while (0)
#endif
