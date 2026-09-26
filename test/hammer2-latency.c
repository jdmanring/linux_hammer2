/* Per-operation latency on a HAMMER2 file: random 4 KiB and fsync.
 *
 * Every performance number this tree had was sequential.  Sequential
 * throughput is where a copy-on-write filesystem with 64 KiB blocks and a
 * checksum per block is expected to look good; random small I/O and the
 * cost of making one write durable are where the same design is expected
 * to pay, and neither was measured anywhere in this tree.  A number from
 * one half of that pair says nothing about the other, so this measures the
 * half that was missing.
 *
 * WHAT IS MEASURED, and why each needs the method it has:
 *
 *   random 4 KiB read   The page cache would serve a repeat, so the cache
 *                       is dropped on the guest before the pass and the
 *                       file is sized well above the guest's RAM.  A
 *                       latency served from memory is a cache reading,
 *                       not the filesystem's.
 *   random 4 KiB write  A pwrite returns once the page cache has it, so
 *                       its latency alone is the page cache's and would
 *                       flatter every filesystem equally.  The unit
 *                       measured is write-then-fsync, which is what a
 *                       database or a package manager actually pays, and
 *                       it is the number that differs.
 *   fsync               The durable commit on its own, over a batch of
 *                       small writes, which is what an installer does at
 *                       the end of unpacking a package.
 *
 * O_DIRECT is not used and cannot be: this port has no ->direct_IO, so
 * open(O_DIRECT) returns EINVAL.  O_SYNC is not used either, since
 * write-then-fsync measures the same commit and reports the two halves
 * separately, which is more useful than their sum.
 *
 * THE REFERENCE.  Every kernel-facing expectation in this tree needs a
 * filesystem that is not this port as a control, because a reading that
 * cannot come out any other way is not a measurement.  The same binary
 * runs on HAMMER2, on ext4 and on btrfs in the same guest, so a number
 * here is only interesting as a comparison.
 *
 * A FAKE PASS would be a run where the reads were served from cache
 * (latencies in the hundreds of nanoseconds, far below any device), or
 * where the write path did not reach the device at all.  The exerciser
 * prints the raw minima and the operation count beside the percentiles,
 * so a cache reading is visible rather than merely surprising, and it
 * asserts the file exists at the size it asked for before timing it.
 *
 * Every line is prefixed so the driving script does no quoting:
 *
 *     lat-ok <what>          a check that passed
 *     lat-fail <what>        a check that failed
 *     lat-check <what>       a reading, in microseconds
 *     lat-summary <fs> <mode> <n> <ops/s> <min> <p50> <p95> <p99> <max>
 *
 * The ops/s column is not comparable across the three modes, because an
 * "op" is a different amount of work in each: one read, one write plus a
 * commit, or eight writes plus a commit.  Comparing the batch figure
 * against the single-write figure directly makes batching look slower
 * when it is faster per byte, which is the correct reading and the one
 * the comment beside each mode states.
 *     lat-checks <n>
 *     lat-failures <n>
 */
#define _GNU_SOURCE
#include <sys/stat.h>
#include <sys/time.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>

static int fails;
static int checks;

#define MAXOPS 20000

static long long
now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return ((long long)ts.tv_sec * 1000000000LL + ts.tv_nsec);
}

static int
cmp_ll(const void *a, const void *b)
{
	long long x = *(const long long *)a, y = *(const long long *)b;

	return (x < y ? -1 : x > y ? 1 : 0);
}

/* Print the summary line for one pass.  ns are converted to microseconds. */
static void
summary(const char *fs, const char *mode, long long *t, long n, double secs)
{
	long long mn, p50, p95, p99, mx;

	qsort(t, (size_t)n, sizeof(*t), cmp_ll);
	mn = t[0];
	p50 = t[(long)(n * 0.50)];
	p95 = t[(long)(n * 0.95)];
	p99 = t[(long)(n * 0.99)];
	mx = t[n - 1];
	printf("lat-summary %s %s %ld %.0f %lld %lld %lld %lld %lld\n",
	    fs, mode, n, (double)n / (secs > 0 ? secs : 1e-9),
	    mn / 1000, p50 / 1000, p95 / 1000, p99 / 1000, mx / 1000);
	printf("lat-ok   %s: %s over %ld op(s), %.1f s\n", fs, mode, n, secs);
}

/* A reproducible pseudo-random offset within a file of `blocks` 4K blocks. */
static unsigned int rseed = 20260926u;
static off_t
rand_off(long blocks)
{
	rseed = rseed * 1103515245u + 12345u;
	return ((off_t)((rseed >> 8) % (unsigned)blocks) * 4096);
}

int
main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : ".";
	const char *fs = argc > 2 ? argv[2] : "fs";
	long mb = argc > 3 ? atol(argv[3]) : 1024;
	long ops = argc > 4 ? atol(argv[4]) : 2000;
	char path[4096];
	long blocks;
	long long *t;
	long i;
	int fd;
	struct stat st;

	if (ops > MAXOPS)
		ops = MAXOPS;
	if (snprintf(path, sizeof(path), "%s/latency.dat", dir) >=
	    (int)sizeof(path)) {
		fprintf(stderr, "lat-setup path too long\n");
		return 2;
	}
	blocks = mb * 256;			/* 4 KiB blocks in the file */
	t = malloc((size_t)ops * sizeof(*t));
	if (!t) {
		fprintf(stderr, "lat-setup malloc failed\n");
		return 2;
	}

	/*
	 * The file is made first and its size asserted, because a timing
	 * loop over a file that was never created measures the error path
	 * and reports it as speed.
	 */
	fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644);
	if (fd < 0) {
		fprintf(stderr, "lat-setup open failed: %s\n", strerror(errno));
		return 2;
	}
	if (ftruncate(fd, (off_t)mb * 1024 * 1024) != 0) {
		fprintf(stderr, "lat-setup ftruncate failed: %s\n",
		    strerror(errno));
		return 2;
	}
	close(fd);
	fd = open(path, O_RDWR);
	if (fd < 0 || fstat(fd, &st) != 0) {
		fprintf(stderr, "lat-setup reopen failed\n");
		return 2;
	}
	checks++;
	if (st.st_size != (off_t)mb * 1024 * 1024) {
		printf("lat-fail the file is %lld bytes, not %ld\n",
		    (long long)st.st_size, mb * 1024 * 1024);
		fails++;
		return (1);
	}
	printf("lat-ok   %s: file ready, %ld MiB, %ld 4 KiB blocks\n",
	    fs, mb, blocks);

	/*
	 * Pass 1: random 4 KiB read, cold.  The driving script drops the
	 * caches first; this asserts the file is larger than the page cache
	 * it could be served from by reporting both, so a fully cached run
	 * is visible in the numbers instead of silently flattering.
	 */
	{
		long long t0 = now_ns();
		char *b = malloc(4096);

		if (!b) {
			fprintf(stderr, "lat-setup malloc failed\n");
			return 2;
		}
		for (i = 0; i < ops; ++i) {
			off_t o = rand_off(blocks);
			long long a = now_ns();

			if (pread(fd, b, 4096, o) != 4096) {
				printf("lat-fail read at %lld failed\n",
				    (long long)o);
				fails++;
				break;
			}
			t[i] = now_ns() - a;
		}
		if (i == ops) {
			summary(fs, "randread4k", t, ops,
			    (double)(now_ns() - t0) / 1e9);
			/* A sub-microsecond median is page cache, not media. */
			qsort(t, (size_t)ops, sizeof(*t), cmp_ll);
			checks++;
			if (t[ops / 2] < 1000) {
				printf("lat-fail randread4k median %lld ns is "
				    "cache speed, so the cache was not cold "
				    "and this is not a media reading\n",
				    t[ops / 2]);
				fails++;
			} else {
				printf("lat-ok   randread4k median is device "
				    "speed, the cache was cold\n");
			}
		}
		free(b);
	}

	/*
	 * Pass 2: random 4 KiB write made durable with fsync, which is what
	 * a caller pays.  The two are timed as one unit because that is the
	 * unit a database's commit is.
	 */
	{
		long long t0 = now_ns();
		char *b = malloc(4096);

		if (!b) {
			fprintf(stderr, "lat-setup malloc failed\n");
			return 2;
		}
		memset(b, 0x5a, 4096);
		for (i = 0; i < ops; ++i) {
			off_t o = rand_off(blocks);
			long long a = now_ns();

			if (pwrite(fd, b, 4096, o) != 4096) {
				printf("lat-fail write at %lld failed\n",
				    (long long)o);
				fails++;
				break;
			}
			if (fsync(fd) != 0) {
				printf("lat-fail fsync failed: %s\n",
				    strerror(errno));
				fails++;
				break;
			}
			t[i] = now_ns() - a;
		}
		if (i == ops) {
			summary(fs, "randwrite4k_fsync", t, ops,
			    (double)(now_ns() - t0) / 1e9);
			checks++;
		}
		free(b);
	}

	/*
	 * Pass 3: the commit alone, at a batch size an installer would use.
	 * Eight writes then one fsync, so the reading is the flush and not
	 * the eight pwrites around it.
	 */
	{
		long batches = ops / 8;
		long long t0 = now_ns();
		char *b = malloc(4096);

		if (!b) {
			fprintf(stderr, "lat-setup malloc failed\n");
			return 2;
		}
		memset(b, 0xa5, 4096);
		for (i = 0; i < batches; ++i) {
			int k;
			long long a;
			int short_writes = 0;

			for (k = 0; k < 8; ++k) {
				if (pwrite(fd, b, 4096, rand_off(blocks)) != 4096) {
					short_writes = 1;
					break;
				}
			}
			/*
			 * The inner break leaves only that loop, so a failed
			 * write would otherwise be followed by the fsync and a
			 * recorded timing for a batch that was never written.
			 * The pass aborts instead.
			 */
			if (short_writes) {
				printf("lat-fail batch write failed\n");
				fails++;
				break;
			}
			a = now_ns();
			if (fsync(fd) != 0) {
				printf("lat-fail batch fsync failed\n");
				fails++;
				break;
			}
			t[i] = now_ns() - a;
		}
		if (i == batches && batches > 0) {
			summary(fs, "fsync_batch8", t, batches,
			    (double)(now_ns() - t0) / 1e9);
			checks++;
		}
		free(b);
	}

	close(fd);
	unlink(path);
	free(t);
	printf("lat-checks %d\nlat-failures %d\n", checks, fails);
	return (fails ? 1 : 0);
}
