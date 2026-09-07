/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_LOCKDEP_H_
#define _H2_STUB_LOCKDEP_H_
#include <linux/kernel.h>
/*
 * The annotation surface hammer2_mtx uses, parsed in its annotated form
 * so the branch the debug guest runs is the one the stub checks.
 */
#define CONFIG_DEBUG_LOCK_ALLOC 1
struct lockdep_map { int unused; };
struct lock_class_key { int unused; };
#define LD_WAIT_SLEEP 3
#define _RET_IP_ ((unsigned long)0)
void lockdep_init_map_wait(struct lockdep_map *l, const char *name,
    struct lock_class_key *key, int subclass, short inner);
void lock_acquire(struct lockdep_map *l, unsigned int subclass, int trylock,
    int read, int check, struct lockdep_map *nest_lock, unsigned long ip);
void lock_release(struct lockdep_map *l, unsigned long ip);
#define lock_acquire_exclusive(l, s, t, n, i)	lock_acquire(l, s, t, 0, 1, n, i)
#define lock_acquire_shared(l, s, t, n, i)	lock_acquire(l, s, t, 1, 1, n, i)
#define lock_acquire_shared_recursive(l, s, t, n, i) lock_acquire(l, s, t, 2, 1, n, i)
#endif
