/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_WAIT_H_
#define _H2_STUB_WAIT_H_
#include <linux/kernel.h>
typedef struct wait_queue_head { long opaque; } wait_queue_head_t;
struct wait_queue_entry { long opaque; };
#define DEFINE_WAIT(name) struct wait_queue_entry name = { 0 }
void init_waitqueue_head(wait_queue_head_t *wq);
void wake_up(wait_queue_head_t *wq);
void wake_up_all(wait_queue_head_t *wq);
int waitqueue_active(wait_queue_head_t *wq);
void might_sleep(void);
#define wait_event(wq, cond) do { while (!(cond)) ; } while (0)
/*
 * The timeout form, from include/linux/wait.h at the kernel of record,
 * where it returns 0 on timeout, the remaining jiffies if the condition
 * came true, and -ERESTARTSYS if a signal arrived.  The thread API calls
 * it for a wait with no lock to drop.
 */
long wait_event_interruptible_timeout(wait_queue_head_t wq, int cond,
    long timeout);
void prepare_to_wait(wait_queue_head_t *wq, struct wait_queue_entry *e, int state);
void finish_wait(wait_queue_head_t *wq, struct wait_queue_entry *e);
#endif
