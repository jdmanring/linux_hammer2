/* SPDX-License-Identifier: BSD-3-Clause
 *
 * Drives hammer2_os.h through a compiler against the stubs beside it.
 * See test/stub/linux/kernel.h for exactly what this proves and what it
 * cannot. Every static inline is referenced below, because an unused
 * static inline in a header is not fully checked by every compiler and a
 * gate that skips half the file reads the same as one that passes.
 * script/test-shim.sh counts that rather than trusting this sentence,
 * which was wrong about nine of forty-three inlines until 2026-08-26.
 */

#include "../src/sys/fs/hammer2/hammer2_os.h"

struct task_struct *current;
unsigned long jiffies;

void hammer2_syntax_check_all(void);

void
hammer2_syntax_check_all(void)
{
	hammer2_lk_t lk;
	hammer2_lkc_t lkc;
	hammer2_mtx_t mtx;
	hammer2_spin_t spin;
	uma_zone_t zone;
	void *p;
	int x;

	hammer2_lk_init(&lk, "lk");
	hammer2_lk_ex(&lk);
	hammer2_lk_unlock(&lk);
	hammer2_lk_destroy(&lk);
	hammer2_lk_assert_ex(&lk);
	hammer2_lk_assert_unlocked(&lk);

	hammer2_lkc_init(&lkc, "lkc");
	hammer2_lkc_wakeup(&lkc);
	(void)hammer2_lkc_sleep(&lkc, &lk, "s", 0);
	(void)hammer2_lkc_sleep(&lkc, &lk, "s", 10);
	hammer2_lkc_destroy(&lkc);

	hammer2_mtx_init(&mtx, "mtx");
	hammer2_mtx_ex(&mtx);
	(void)hammer2_mtx_owned(&mtx);
	(void)hammer2_mtx_refs(&mtx);
	(void)hammer2_mtx_upgrade_try(&mtx);
	x = hammer2_mtx_temp_release(&mtx);
	hammer2_mtx_temp_restore(&mtx, x);
	hammer2_mtx_unlock(&mtx);
	hammer2_mtx_sh(&mtx);
	hammer2_mtx_unlock(&mtx);
	(void)hammer2_mtx_ex_try(&mtx);
	hammer2_mtx_unlock(&mtx);
	(void)hammer2_mtx_sh_try(&mtx);
	hammer2_mtx_unlock(&mtx);
	(void)hammer2_mtx_sleep(&lkc, &mtx, "s", 5);
	hammer2_mtx_wakeup(&lkc);
	hammer2_mtx_assert_ex(&mtx);
	hammer2_mtx_assert_sh(&mtx);
	hammer2_mtx_assert_locked(&mtx);
	hammer2_mtx_assert_unlocked(&mtx);
	hammer2_mtx_destroy(&mtx);

	hammer2_spin_init(&spin, "spin");
	hammer2_spin_ex(&spin);
	hammer2_spin_unex(&spin);
	hammer2_spin_sh(&spin);
	hammer2_spin_unsh(&spin);
	hammer2_spin_assert_ex(&spin);
	hammer2_spin_assert_sh(&spin);
	hammer2_spin_assert_locked(&spin);
	hammer2_spin_assert_unlocked(&spin);
	hammer2_spin_destroy(&spin);

	p = hmalloc(64, NULL, M_WAITOK | M_ZERO);
	p = hrealloc(p, 128, NULL, M_WAITOK);
	hfree(p, NULL, 128);
	hstrfree(hstrdup("x"));

	KKASSERT(1);
	KASSERTMSG(1, "no %d", 0);
	hprintf("hello %d", 1);
	debug_hprintf("dbg %d", 1);
	/*
	 * hpanic is noreturn, so it is expanded behind a constant false
	 * rather than called: an unexpanded macro is an unchecked one, and
	 * this one carries a prefix that only kbuild normally supplies.
	 */
	if (0)
		hpanic("boom %d", 1);
	/*
	 * The zone allocator, the sleeps and the leak counter. These were
	 * unreferenced until 2026-08-26 while both this file and
	 * script/test-shim.sh said every inline was referenced here, so
	 * nine of the shim's forty-three went through the gate untouched.
	 * The gate now counts, rather than the comment claiming.
	 */
	zone = uma_zcreate("z", 64);
	p = uma_zalloc(zone, M_WAITOK);
	uma_zfree(zone, p);
	uma_zdestroy(zone);
	(void)hammer2_gfp(M_WAITOK | M_ZERO);
	adjust_malloc_leak(64, NULL);
	adjust_malloc_leak(-64, NULL);
	hammer2_mtx_init_recurse(&mtx, "mtxr");
	hammer2_mtx_destroy(&mtx);
	pause("p", 1);
	(void)tsleep(&x, 0, "s", 1);

	/*
	 * The device flush pair, whose arguments the stubs declare rather
	 * than the shim: a null file is never dereferenced here, only
	 * type-checked.
	 */
	(void)hammer2_dev_writeback(NULL);
	(void)hammer2_dev_cache_flush(NULL);
	(void)hammer2_vfs_errno(EDOM);
	hammer2_mapping_set_block_folios(NULL, 16);
	{
		static struct lock_class_key k;

		__hammer2_mtx_init(&mtx, "x", &k);
		__hammer2_mtx_init_recurse(&mtx, "x", &k);
	}
	hammer2_mtx_ex_fresh(&mtx);
	hammer2_mtx_unlock(&mtx);
	hammer2_mtx_sh(&mtx);
	hammer2_mtx_sh_again(&mtx);
	hammer2_mtx_unlock(&mtx);
	hammer2_mtx_unlock(&mtx);

	cpu_pause();
	cpu_ccfence();
	(void)getticks();

	/*
	 * The format's physical buffer must fit the block layer's ceiling.
	 * Reading 2 is the whole argument; this is the assertion that
	 * stops a driver shipping if either number ever moves.
	 */
	_Static_assert(65536 <= BLK_MAX_BLOCK_SIZE,
		       "HAMMER2_PBUFSIZE exceeds BLK_MAX_BLOCK_SIZE; see "
		       "doc/README.porting.md");
}
