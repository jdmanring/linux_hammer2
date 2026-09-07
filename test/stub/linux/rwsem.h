/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_RWSEM_H_
#define _H2_STUB_RWSEM_H_
#include <linux/kernel.h>
#include <linux/lockdep.h>
/* Opaque: the shim locks and unlocks it and reads nothing inside. */
struct rw_semaphore { long opaque; struct lockdep_map dep_map; };
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
