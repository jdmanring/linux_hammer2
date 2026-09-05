/* SPDX-License-Identifier: BSD-3-Clause
 *
 * STUBS. These are NOT the Linux kernel headers and must never be
 * mistaken for them.
 *
 * What the gate that uses them proves: that hammer2_linux.h is
 * syntactically valid C, that its braces and macros balance, that every
 * identifier it defines is spelled consistently, and that no function
 * body references a name the header never introduces.
 *
 * What it CANNOT prove, and this is the larger half: that any kernel
 * function is called with the right argument types, that a primitive
 * behaves as assumed, or that the header compiles against the real
 * headers at all. A stub agreeing with the shim proves the two agree with
 * each other. Only a build against a real kernel answers the rest, and
 * script/test-syntax.sh is the gate that does it.
 *
 * Every prototype here was transcribed from the kernel's own headers so a disagreement is at least likely to show up; a stub written to
 * match the shim rather than the kernel would turn this gate into a
 * mirror. Where a signature was not checked, the comment says so.
 */

#ifndef _H2_STUB_KERNEL_H_
#define _H2_STUB_KERNEL_H_

#include <stddef.h>
#include <stdint.h>

typedef unsigned int gfp_t;

#define GFP_KERNEL	((gfp_t)0x01)
#define GFP_NOWAIT	((gfp_t)0x02)
#define __GFP_ZERO	((gfp_t)0x04)
#define __GFP_NOFAIL	((gfp_t)0x08)

#define EINTR		4
#define ETIMEDOUT	110

#define __always_unused	__attribute__((unused))

#define likely(x)	(x)
#define unlikely(x)	(x)

#define READ_ONCE(x)		(*(volatile typeof(x) *)&(x))
#define WRITE_ONCE(x, v)	(*(volatile typeof(x) *)&(x) = (v))
#define barrier()		__asm__ __volatile__("" ::: "memory")

#define BUG_ON(cond)	do { if (cond) __builtin_trap(); } while (0)
#define WARN_ON(cond)	(!!(cond))
#define WARN_ON_ONCE(cond)	(!!(cond))
#define BUILD_BUG_ON_MSG(cond, msg)	_Static_assert(!(cond), msg)

/* kbuild passes -DKBUILD_MODNAME on every real build and there is no
 * kbuild here, so hpanic's module-name prefix would not expand without
 * this. Not transcribed from a kernel header: it is what kbuild supplies
 * on the command line. */
#ifndef KBUILD_MODNAME
#define KBUILD_MODNAME	"hammer2"
#endif

int pr_info(const char *fmt, ...);
int pr_cont(const char *fmt, ...);
void panic(const char *fmt, ...) __attribute__((noreturn));
void cpu_relax(void);
void dump_stack(void);

#endif
