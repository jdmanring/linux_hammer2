/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_RWSEM_H_
#define _H2_STUB_RWSEM_H_
#include <linux/kernel.h>
/* Opaque on purpose: the shim must never depend on the layout. */
struct rw_semaphore { long opaque; };
struct lock_class_key { int unused; };
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
