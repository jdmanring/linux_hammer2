/* SPDX-License-Identifier: BSD-3-Clause - stub, see linux/kernel.h */
#ifndef _H2_STUB_DELAY_H_
#define _H2_STUB_DELAY_H_
/*
 * The kernel's ssleep(), transcribed from include/linux/delay.h:103 at
 * v7.3. It is here so this gate sees the collision the shim renames its
 * own ssleep() around: without the rename the two definitions conflict.
 */
static inline void ssleep(unsigned int seconds) { (void)seconds; }
#endif
