/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_WAIT_H_
#define _H2_STUB_WAIT_H_
#include <linux/kernel.h>
typedef struct wait_queue_head { long opaque; } wait_queue_head_t;
struct wait_queue_entry { long opaque; };
#define DEFINE_WAIT(name) struct wait_queue_entry name = { 0 }
void init_waitqueue_head(wait_queue_head_t *wq);
void wake_up(wait_queue_head_t *wq);
void prepare_to_wait(wait_queue_head_t *wq, struct wait_queue_entry *e, int state);
void finish_wait(wait_queue_head_t *wq, struct wait_queue_entry *e);
#endif
