/*
 * The CCMS thread lock under contention, on the host.
 *
 * test/hammer2-ccms-lock.c reads the transitions one thread at a time.
 * This file runs the same shipped functions from many threads at once,
 * with the spin, the sleep and the wakeup made real: the spin is a
 * pthread mutex, ssleep() releases it and waits on a condition, and
 * wakeup() broadcasts.  That is the contract the kernel primitives give
 * the carried code, a sleep that drops the CST's spin and a wakeup of
 * every sleeper on the channel.
 *
 * What it checks, under eight threads for many rounds each:
 *
 *   - mutual exclusion: while a thread holds the lock exclusively, no
 *     other thread is inside a shared or exclusive section;
 *   - shared holders coexist with each other and never with a writer;
 *   - an upgrade becomes exclusive with no other holder inside;
 *   - the lock is unlocked, with no pending upgrade, when every thread
 *     has finished.
 *
 * Each section records itself in two atomic counters, readers and
 * writers, and asserts the invariant on entry.  A violation is counted
 * rather than aborted, so the run reports how many there were.
 *
 * Cannot prove: that the kernel's rw_semaphore and wait queue behave as
 * these stand-ins do, or anything about lockdep, which needs the kernel.
 * The guest run of the module under lockdep is the other half.
 *
 * Exit 0 pass, 1 fail.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define bzero(p, n)	memset((p), 0, (n))
#define KKASSERT(x)	do { if (!(x)) atomic_fetch_add(&asserts, 1); } while (0)
#define hz		100
#define EBUSY		16

static atomic_int asserts, timeouts;

typedef struct {
	pthread_mutex_t	mtx;
	pthread_cond_t	cv;
} hammer2_spin_t;

static void
hammer2_spin_init(hammer2_spin_t *p, const char *s)
{
	(void)s;
	pthread_mutex_init(&p->mtx, NULL);
	pthread_cond_init(&p->cv, NULL);
}

static void
hammer2_spin_ex(hammer2_spin_t *p)
{
	pthread_mutex_lock(&p->mtx);
}

static void
hammer2_spin_unex(hammer2_spin_t *p)
{
	pthread_mutex_unlock(&p->mtx);
}

/*
 * The carried code calls ssleep(cst, &cst->spin, ...) and wakeup(cst).
 * The channel is the CST and the CST holds the spin, so the condition
 * lives beside the mutex and the channel pointer finds it.
 */
struct ccms_cst;
static void ssleep(struct ccms_cst *, hammer2_spin_t *, int, const char *, int);
static void wakeup(struct ccms_cst *);

static int
hpanic(const char *fmt, ...)
{
	(void)fmt;
	atomic_fetch_add(&asserts, 1);
	return 0;
}

static _Thread_local int self_id;
#define curthread	((void *)&self_id)

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

static void
ssleep(struct ccms_cst *cst, hammer2_spin_t *spin, int pri, const char *w, int t)
{
	struct timespec ts;

	(void)pri; (void)w; (void)t; (void)cst;
	/*
	 * The carried call passes hz as its timeout, so the kernel sleep
	 * returns after a second even if no wakeup comes, and the caller's
	 * while loop re-checks.  A plain wait here would turn a lost wakeup
	 * into a hang the kernel does not have; a bounded wait keeps that
	 * behavior, and the wakeup counter below says whether any sleep
	 * ever timed out rather than being woken.
	 */
	clock_gettime(CLOCK_REALTIME, &ts);
	ts.tv_nsec += 10 * 1000 * 1000;
	if (ts.tv_nsec >= 1000000000) {
		ts.tv_sec++;
		ts.tv_nsec -= 1000000000;
	}
	if (pthread_cond_timedwait(&spin->cv, &spin->mtx, &ts) == ETIMEDOUT)
		atomic_fetch_add(&timeouts, 1);
}

static void
wakeup(struct ccms_cst *cst)
{
	pthread_mutex_lock(&cst->spin.mtx);
	pthread_cond_broadcast(&cst->spin.cv);
	pthread_mutex_unlock(&cst->spin.mtx);
}

#include "hammer2-ccms-extracted.h"

#define NTHREADS	8
#define ROUNDS		20000

static ccms_cst_t cst;
static atomic_int readers, writers, violations, upgrades;

static void
enter_shared(void)
{
	atomic_fetch_add(&readers, 1);
	if (atomic_load(&writers) != 0)
		atomic_fetch_add(&violations, 1);
}

static void
leave_shared(void)
{
	atomic_fetch_sub(&readers, 1);
}

static void
enter_exclusive(void)
{
	if (atomic_fetch_add(&writers, 1) != 0 || atomic_load(&readers) != 0)
		atomic_fetch_add(&violations, 1);
}

static void
leave_exclusive(void)
{
	atomic_fetch_sub(&writers, 1);
}

static void *
worker(void *arg)
{
	unsigned seed = (unsigned)(uintptr_t)arg * 2654435761u;

	self_id = (int)(uintptr_t)arg;
	for (int i = 0; i < ROUNDS; i++) {
		seed = seed * 1103515245u + 12345u;
		switch ((seed >> 16) % 4) {
		case 0:
			ccms_thread_lock(&cst, CCMS_STATE_SHARED);
			enter_shared();
			leave_shared();
			ccms_thread_unlock(&cst);
			break;
		case 1:
			ccms_thread_lock(&cst, CCMS_STATE_EXCLUSIVE);
			enter_exclusive();
			leave_exclusive();
			ccms_thread_unlock(&cst);
			break;
		case 2:
			/*
			 * Upgrade from shared.  Only one thread upgrades: two
			 * shared holders that both upgrade each wait for the
			 * other's count to drain, which is the lock's contract
			 * rather than a defect ("other upgraders are allowed"
			 * while the count drains), and no caller in DragonFly
			 * before the revamp upgraded from a position another
			 * upgrader shared.  The others take shared, which is
			 * what the upgrade has to wait out.
			 */
			if (self_id == 1) {
				ccms_thread_lock(&cst, CCMS_STATE_SHARED);
				enter_shared();
				leave_shared();
				ccms_state_t o = ccms_thread_lock_upgrade(&cst);
				enter_exclusive();
				leave_exclusive();
				ccms_thread_lock_downgrade(&cst, o);
				enter_shared();
				leave_shared();
				ccms_thread_unlock(&cst);
				atomic_fetch_add(&upgrades, 1);
			} else if (ccms_thread_lock_nonblock(&cst,
			    CCMS_STATE_SHARED) == 0) {
				enter_shared();
				leave_shared();
				ccms_thread_unlock(&cst);
			}
			break;
		default:
			if (ccms_thread_lock_nonblock(&cst, CCMS_STATE_EXCLUSIVE) == 0) {
				enter_exclusive();
				leave_exclusive();
				ccms_thread_unlock(&cst);
			}
			break;
		}
	}
	return NULL;
}

int
main(void)
{
	pthread_t t[NTHREADS];
	int bad = 0;

	bzero(&cst, sizeof(cst));
	hammer2_spin_init(&cst.spin, "ccmscst");

	for (int i = 0; i < NTHREADS; i++)
		pthread_create(&t[i], NULL, worker, (void *)(uintptr_t)(i + 1));
	/*
	 * A broken lock does not always cross a section: it can strand a
	 * waiter whose count never drains.  The joins are bounded so a hang
	 * is reported as a hang, with the violations counted up to it,
	 * rather than leaving the gate to time out with nothing said.
	 */
	struct timespec dl;
	int hung = 0;

	clock_gettime(CLOCK_REALTIME, &dl);
	dl.tv_sec += 60;
	for (int i = 0; i < NTHREADS; i++)
		if (pthread_timedjoin_np(t[i], NULL, &dl) != 0)
			hung++;
	if (hung) {
		printf("  FAIL   %d thread(s) still waiting after 60 s, %d violation(s) before it\n",
		    hung, atomic_load(&violations));
		printf("ccms-concurrent: hung\n");
		fflush(stdout);
		_exit(1);
	}

	printf("ccms concurrency, %d threads x %d rounds against the shipped hammer2_ccms.c:\n",
	    NTHREADS, ROUNDS);
	printf("  %s  mutual exclusion: %d violation(s)\n",
	    atomic_load(&violations) ? "FAIL " : "ok   ", atomic_load(&violations));
	if (atomic_load(&violations))
		bad++;
	printf("  %s  final state: count %d, upgrade %d, td %s\n",
	    (cst.count == 0 && cst.upgrade == 0 && cst.td == NULL) ? "ok   " : "FAIL ",
	    cst.count, cst.upgrade, cst.td ? "held" : "NULL");
	if (cst.count != 0 || cst.upgrade != 0 || cst.td != NULL)
		bad++;
	printf("  %s  assertions: %d\n", atomic_load(&asserts) ? "FAIL " : "ok   ",
	    atomic_load(&asserts));
	if (atomic_load(&asserts))
		bad++;
	printf("  %s  upgrades taken: %d\n", atomic_load(&upgrades) ? "ok   " : "FAIL ",
	    atomic_load(&upgrades));
	if (!atomic_load(&upgrades))
		bad++;
	/*
	 * A timed-out sleep is not a failure, the kernel has the same
	 * timeout, but it is reported: a run whose sleepers were all freed
	 * by the timeout rather than by wakeup() would pass the exclusion
	 * checks while the wakeup path never worked.
	 */
	printf("  note   sleeps ended by timeout rather than wakeup: %d\n",
	    atomic_load(&timeouts));
	printf("ccms-concurrent: %d failure(s)\n", bad);
	return bad ? 1 : 0;
}
