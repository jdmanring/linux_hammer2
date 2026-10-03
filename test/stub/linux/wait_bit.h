/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_WAIT_BIT_H_
#define _H2_STUB_WAIT_BIT_H_
#include <linux/wait.h>
/*
 * The var-waitqueue pool tsleep() and wakeup() sleep on, transcribed from
 * include/linux/wait_bit.h at v7.3-rc5: the two structures at :10 and
 * :16, and the three declarations at :250-252.
 */
struct wait_bit_key {
	unsigned long		*flags;
	int			bit_nr;
	unsigned long		timeout;
};
struct wait_bit_queue_entry {
	struct wait_bit_key	key;
	struct wait_queue_entry	wq_entry;
};
void init_wait_var_entry(struct wait_bit_queue_entry *wbq_entry, void *var,
    int flags);
void wake_up_var(void *var);
wait_queue_head_t *__var_waitqueue(void *p);
#endif
