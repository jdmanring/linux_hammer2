/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_RWSEM_H_
#define _H2_STUB_RWSEM_H_
#include <linux/kernel.h>
/*
 * The three fields the shim reads: the count and owner words for the
 * shared to exclusive upgrade, checked against the running kernel at
 * module load, and the lockdep map it annotates.  Nothing else.
 */
typedef struct { long counter; } atomic_long_t;
struct lockdep_map { int unused; };
struct rw_semaphore { atomic_long_t count; atomic_long_t owner; struct lockdep_map dep_map; };
struct lock_class_key { int unused; };
long atomic_long_read(const atomic_long_t *v);
void atomic_long_set(atomic_long_t *v, long i);
int atomic_long_try_cmpxchg_acquire(atomic_long_t *v, long *old, long new);
void rwsem_acquire(struct lockdep_map *l, unsigned int subclass, int trylock, unsigned long ip);
void rwsem_release(struct lockdep_map *l, unsigned long ip);
#define _RET_IP_ ((unsigned long)0)
void init_rwsem(struct rw_semaphore *sem);
void __init_rwsem(struct rw_semaphore *sem, const char *name, struct lock_class_key *key);
void down_write(struct rw_semaphore *sem);
void up_write(struct rw_semaphore *sem);
void down_read(struct rw_semaphore *sem);
void up_read(struct rw_semaphore *sem);
int down_write_trylock(struct rw_semaphore *sem);
void down_write_nested(struct rw_semaphore *sem, int subclass);
void down_read_nested(struct rw_semaphore *sem, int subclass);
int down_read_trylock(struct rw_semaphore *sem);
void downgrade_write(struct rw_semaphore *sem);
int rwsem_is_locked(struct rw_semaphore *sem);
#endif
