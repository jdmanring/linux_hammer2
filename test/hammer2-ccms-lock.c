/*
 * The CCMS thread lock's release count, on the host.
 *
 * hammer2_ccms.c is carried from DragonFly, where the bad-state arm of
 * ccms_thread_lock() and ccms_thread_lock_nonblock() releases the CST's
 * spin, calls panic(), and falls through to the release after the
 * if/else chain.  panic() never returns there, so the fall-through is
 * unreachable and the count is one.  This port's hpanic() returns, so
 * the same shape releases the spin twice, and the spin is a
 * rw_semaphore here: the second up_write() on a lock nobody holds
 * corrupts the count, which is the defect this file exists to catch.
 *
 * The functions under test are the shipped ones.  script/test-ccms-lock.sh
 * extracts them from src/sys/fs/hammer2/hammer2_ccms.c by name into a
 * generated file and fails if any extraction comes back empty, so a
 * function that was renamed or deleted is a could-not-run rather than a
 * probe that quietly tests nothing.  Nothing is copied by hand.
 *
 * The count is the whole test.  A probe that asserted "the function
 * returned" would pass on the unfixed file too, since hpanic() returns
 * either way; what separates the two is how many times the spin came
 * back up.
 *
 * Exit 0 pass, 1 fail.
 */
#include <stdio.h>
#include <string.h>
#include <stdint.h>

/*
 * The stand-in.  Each name below is one the carried file uses and the
 * shim supplies; here they are the smallest thing that lets the
 * extracted text compile and lets the count be read.
 */
#define bzero(p, n)	memset((p), 0, (n))
#define KKASSERT(x)	do { if (!(x)) { printf("KKASSERT failed: %s\n", #x); fails++; } } while (0)
#define hz		100
#define EBUSY		16

typedef struct { int held; } hammer2_spin_t;

static int releases;		/* up_write() calls, the reading */
static int acquires;		/* down_write() calls */
static int fails;		/* KKASSERT failures */

static void
hammer2_spin_init(hammer2_spin_t *p, const char *s)
{
	(void)s;
	p->held = 0;
}

static void
hammer2_spin_ex(hammer2_spin_t *p)
{
	p->held = 1;
	acquires++;
}

static void
hammer2_spin_unex(hammer2_spin_t *p)
{
	/*
	 * The defect this probe is for: a release of a spin that is not
	 * held.  Counted rather than asserted so the run reports both the
	 * count and the fault, and a caller that releases twice shows up
	 * as releases > acquires.
	 */
	if (!p->held)
		printf("  note: release of an unheld spin\n");
	p->held = 0;
	releases++;
}

static void
ssleep(const void *chan, hammer2_spin_t *spin, int pri, const char *wmesg, int timo)
{
	(void)chan; (void)spin; (void)pri; (void)wmesg; (void)timo;
}

static void
wakeup(const void *chan)
{
	(void)chan;
}

static int
hpanic(const char *fmt, ...)
{
	(void)fmt;
	return 0;		/* returns, as the port's does */
}

#define curthread	((void *)0x1)

/*
 * The state and type definitions the carried file expects from its own
 * header, which includes hammer2.h and so cannot be compiled here.  The
 * values are the header's; the struct is the header's, less the fields
 * the lock functions do not touch.
 */
typedef uint8_t ccms_state_t;
typedef uint8_t ccms_type_t;
typedef void *thread_t;

#define CCMS_STATE_INVALID	0
#define CCMS_STATE_SHARED	2
#define CCMS_STATE_EXCLUSIVE	3

struct ccms_cst {
	hammer2_spin_t	spin;
	ccms_state_t	state;
	ccms_type_t	type;
	int32_t		upgrade;
	int32_t		count;
	int32_t		blocked;
	thread_t	td;
};
typedef struct ccms_cst ccms_cst_t;

/*
 * The shipped functions, extracted by script/test-ccms-lock.sh.
 */
#include "hammer2-ccms-extracted.h"

static void
reset(void)
{
	releases = 0;
	acquires = 0;
	fails = 0;
}

static void
init(ccms_cst_t *cst)
{
	hammer2_spin_init(&cst->spin, "ccmscst");
	cst->count = 0;
	cst->upgrade = 0;
	cst->td = NULL;
}

int
main(void)
{
	ccms_cst_t cst;
	int bad = 0;

	printf("ccms lock release count, against the shipped hammer2_ccms.c:\n");

	/*
	 * A good state: lock and unlock.  Two acquires and two releases,
	 * because ccms_thread_unlock() takes the spin itself to clear the
	 * count.  The property is that the two are equal: a release with
	 * no acquire is the defect, and this is the control that says the
	 * counting works, without which a zero on the bad path would be
	 * indistinguishable from a probe that never ran.
	 */
	reset();
	init(&cst);
	ccms_thread_lock(&cst, CCMS_STATE_EXCLUSIVE);
	ccms_thread_unlock(&cst);
	printf("  %s  exclusive lock and unlock: %d acquire(s), %d release(s)\n",
	    (acquires == 2 && releases == 2) ? "ok   " : "FAIL ", acquires, releases);
	if (acquires != 2 || releases != 2) {
		printf("        the control expected 2 and 2\n");
		bad++;
	}

	/*
	 * The bad-state arm of ccms_thread_lock().  State 7 is not one the
	 * function implements.  The spin is taken once and must come back
	 * up once; the unfixed file releases it twice.
	 */
	reset();
	init(&cst);
	ccms_thread_lock(&cst, 7);
	printf("  %s  ccms_thread_lock(bad state): %d acquire(s), %d release(s)\n",
	    releases == 1 ? "ok   " : "FAIL ", acquires, releases);
	if (releases != 1) {
		printf("        expected 1 release, got %d\n", releases);
		bad++;
	}

	/*
	 * The same arm of ccms_thread_lock_nonblock(), which returns a
	 * value and so also has to say what it returns.
	 */
	reset();
	init(&cst);
	(void)ccms_thread_lock_nonblock(&cst, 7);
	printf("  %s  ccms_thread_lock_nonblock(bad state): %d acquire(s), %d release(s)\n",
	    releases == 1 ? "ok   " : "FAIL ", acquires, releases);
	if (releases != 1) {
		printf("        expected 1 release, got %d\n", releases);
		bad++;
	}

	/*
	 * The other two hpanic sites, which are not bad-state arms and
	 * must not have been changed by the fix.  ccms_thread_lock_upgrade()
	 * on an unlocked CST holds no spin when it fires.
	 */
	reset();
	init(&cst);
	(void)ccms_thread_lock_upgrade(&cst);
	printf("  %s  ccms_thread_lock_upgrade(unlocked): %d acquire(s), %d release(s)\n",
	    releases == 0 ? "ok   " : "FAIL ", acquires, releases);
	if (releases != 0) {
		printf("        expected 0 releases, got %d\n", releases);
		bad++;
	}

	reset();
	init(&cst);
	ccms_thread_unlock(&cst);
	printf("  %s  ccms_thread_unlock(zero count): %d acquire(s), %d release(s)\n",
	    releases == 0 ? "ok   " : "FAIL ", acquires, releases);
	if (releases != 0) {
		printf("        expected 0 releases, got %d\n", releases);
		bad++;
	}

	/*
	 * The transition matrix, doc/CCMS_TRANSITIONS.md.  Each row is a
	 * call from a stated precondition, and the check is the
	 * postcondition the document claims: count, td and upgrade after
	 * the call, and every acquire matched by a release.  A row whose
	 * document claim and code disagreed would fail here, which is the
	 * point of writing the claims as checks rather than prose.
	 */
#define POST(name, c, t, u)	do {					\
	int ok = cst.count == (c) && cst.td == (t) &&			\
	    cst.upgrade == (u) && acquires == releases && !fails;	\
	printf("  %s  %s: count %d, td %s, upgrade %d, %d/%d\n",	\
	    ok ? "ok   " : "FAIL ", (name), cst.count,			\
	    cst.td ? "held" : "NULL", cst.upgrade, acquires, releases);	\
	if (!ok)							\
		bad++;							\
} while (0)

	reset(); init(&cst);
	ccms_thread_lock(&cst, CCMS_STATE_SHARED);
	POST("unlocked -> shared", 1, NULL, 0);

	reset(); init(&cst);
	ccms_thread_lock(&cst, CCMS_STATE_SHARED);
	ccms_thread_lock(&cst, CCMS_STATE_SHARED);
	POST("shared -> shared, depth 2", 2, NULL, 0);
	ccms_thread_unlock(&cst);
	POST("shared depth 2 -> shared depth 1", 1, NULL, 0);
	ccms_thread_unlock(&cst);
	POST("shared depth 1 -> unlocked", 0, NULL, 0);

	reset(); init(&cst);
	ccms_thread_lock(&cst, CCMS_STATE_EXCLUSIVE);
	POST("unlocked -> exclusive", -1, curthread, 0);
	ccms_thread_lock(&cst, CCMS_STATE_SHARED);
	POST("exclusive asks shared, stays exclusive, depth 2", -2, curthread, 0);
	ccms_thread_lock(&cst, CCMS_STATE_EXCLUSIVE);
	POST("exclusive recursion, depth 3", -3, curthread, 0);
	ccms_thread_unlock(&cst);
	ccms_thread_unlock(&cst);
	POST("exclusive depth 3 -> depth 1", -1, curthread, 0);
	ccms_thread_unlock(&cst);
	POST("exclusive depth 1 -> unlocked", 0, NULL, 0);

	reset(); init(&cst);
	ccms_thread_lock(&cst, CCMS_STATE_SHARED);
	{
		ccms_state_t o = ccms_thread_lock_upgrade(&cst);
		POST("shared -> upgraded to exclusive", -1, curthread, 1);
		if (o != CCMS_STATE_SHARED) {
			printf("  FAIL  upgrade returned %d, expected SHARED\n", o);
			bad++;
		}
		ccms_thread_lock_downgrade(&cst, o);
		POST("upgraded -> downgraded to shared", 1, NULL, 0);
	}
	ccms_thread_unlock(&cst);
	POST("downgraded shared -> unlocked", 0, NULL, 0);

	reset(); init(&cst);
	ccms_thread_lock(&cst, CCMS_STATE_EXCLUSIVE);
	{
		ccms_state_t o = ccms_thread_lock_upgrade(&cst);
		POST("exclusive upgrade is a no-op", -1, curthread, 0);
		if (o != CCMS_STATE_EXCLUSIVE) {
			printf("  FAIL  upgrade returned %d, expected EXCLUSIVE\n", o);
			bad++;
		}
		ccms_thread_lock_downgrade(&cst, o);
		POST("exclusive downgrade is a no-op", -1, curthread, 0);
	}
	ccms_thread_unlock(&cst);

	reset(); init(&cst);
	ccms_thread_lock(&cst, CCMS_STATE_EXCLUSIVE);
	{
		ccms_state_t o = ccms_thread_lock_temp_release(&cst);
		POST("exclusive -> temp released", 0, NULL, 0);
		if (o != CCMS_STATE_EXCLUSIVE) {
			printf("  FAIL  temp_release returned %d, expected EXCLUSIVE\n", o);
			bad++;
		}
		ccms_thread_lock_temp_restore(&cst, o);
		POST("temp released -> restored exclusive", -1, curthread, 0);
	}
	ccms_thread_unlock(&cst);

	reset(); init(&cst);
	if (ccms_thread_lock_temp_release(&cst) != CCMS_STATE_INVALID) {
		printf("  FAIL  temp_release of an unlocked CST did not return INVALID\n");
		bad++;
	}
	POST("unlocked temp release is a no-op", 0, NULL, 0);

	/*
	 * The nonblock refusals: a would-block returns EBUSY and leaves the
	 * holder's state as it was.
	 */
	reset(); init(&cst);
	ccms_thread_lock(&cst, CCMS_STATE_SHARED);
	cst.upgrade = 1;		/* another thread's upgrade pending */
	if (ccms_thread_lock_nonblock(&cst, CCMS_STATE_SHARED) != EBUSY) {
		printf("  FAIL  nonblock shared under a pending upgrade was not refused\n");
		bad++;
	}
	cst.upgrade = 0;
	POST("nonblock shared refused under upgrade, state kept", 1, NULL, 0);
	if (ccms_thread_lock_nonblock(&cst, CCMS_STATE_EXCLUSIVE) != EBUSY) {
		printf("  FAIL  nonblock exclusive over a shared holder was not refused\n");
		bad++;
	}
	POST("nonblock exclusive refused over shared, state kept", 1, NULL, 0);
	ccms_thread_unlock(&cst);

	reset(); init(&cst);
	if (ccms_thread_lock_nonblock(&cst, CCMS_STATE_EXCLUSIVE) != 0) {
		printf("  FAIL  nonblock exclusive on an unlocked CST was refused\n");
		bad++;
	}
	POST("nonblock unlocked -> exclusive", -1, curthread, 0);
	if (!ccms_thread_lock_owned(&cst)) {
		printf("  FAIL  owned() false for the exclusive holder\n");
		bad++;
	}
	ccms_thread_unlock(&cst);
	if (ccms_thread_lock_owned(&cst)) {
		printf("  FAIL  owned() true after the release\n");
		bad++;
	}
#undef POST

	if (fails) {
		printf("  FAIL  %d KKASSERT failure(s)\n", fails);
		bad++;
	}

	printf("ccms-lock: %d failure(s)\n", bad);
	return bad ? 1 : 0;
}
