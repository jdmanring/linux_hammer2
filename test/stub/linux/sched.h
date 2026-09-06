/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_SCHED_H_
#define _H2_STUB_SCHED_H_
#include <linux/kernel.h>
#define TASK_INTERRUPTIBLE 0x0001
#define MAX_SCHEDULE_TIMEOUT ((long)(~0UL >> 1))
struct task_struct { char comm[16]; long opaque; void *journal_info; };
int task_pid_nr(struct task_struct *p);
extern struct task_struct *current;
long schedule_timeout(long timeout);
/* Transcribed from include/linux/sched.h:333 at 7.2.0-cachyos. */
long schedule_timeout_interruptible(long timeout);
/* Transcribed from include/linux/sched.h:335 at 7.2.0-cachyos. */
long schedule_timeout_uninterruptible(long timeout);
int signal_pending(struct task_struct *p);
typedef struct { int counter; } atomic_t;
void atomic_inc(atomic_t *v);
int atomic_dec_if_positive(atomic_t *v);
void atomic_dec(atomic_t *v);
#endif
