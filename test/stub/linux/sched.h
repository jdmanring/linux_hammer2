/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_SCHED_H_
#define _H2_STUB_SCHED_H_
#include <linux/kernel.h>
#define TASK_INTERRUPTIBLE 0x0001
#define MAX_SCHEDULE_TIMEOUT ((long)(~0UL >> 1))
struct task_struct { char comm[16]; long opaque; };
int task_pid_nr(struct task_struct *p);
extern struct task_struct *current;
long schedule_timeout(long timeout);
int signal_pending(struct task_struct *p);
typedef struct { int counter; } atomic_t;
void atomic_inc(atomic_t *v);
void atomic_dec(atomic_t *v);
#endif
