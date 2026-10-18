/*
 * Force ->iterate_shared to resume: one entry per getdents64 call.
 *
 * With a second argument, "sweep", the directory is read once per buffer
 * size from 128 bytes to 32 KiB and every pass must return the same
 * entries: the same count and the same order-independent sum of name
 * hashes.  A filesystem that sizes its own read from the buffer, as this
 * port does from dir_context.count since 1.0.38, has a chunk boundary at
 * every size, and this is what checks that no boundary drops or repeats
 * an entry.  Exit 1 on a mismatch or a runaway.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>

struct linux_dirent64 {
	unsigned long long d_ino;
	long long d_off;
	unsigned short d_reclen;
	unsigned char d_type;
	char d_name[];
};

static unsigned long long
fnv(const char *s)
{
	unsigned long long h = 1469598103934665603ULL;

	while (*s)
		h = (h ^ (unsigned char)*s++) * 1099511628211ULL;
	return (h);
}

/* One pass; prints each name when verbose.  Returns entries or -1. */
static int
pass(const char *path, char *buf, size_t size, int verbose,
    unsigned long long *sum, int *calls)
{
	int fd, n, seen = 0;

	*sum = 0;
	*calls = 0;
	fd = open(path, O_RDONLY | O_DIRECTORY);
	if (fd < 0) {
		perror("open");
		return (-1);
	}
	while ((n = syscall(SYS_getdents64, fd, buf, size)) > 0) {
		int off = 0;
		++*calls;
		while (off < n) {
			struct linux_dirent64 *d = (void *)(buf + off);
			if (verbose)
				printf("  %s\n", d->d_name);
			*sum += fnv(d->d_name);
			++seen;
			off += d->d_reclen;
		}
		if (*calls > 100000) {
			printf("RUNAWAY: more than 100000 calls\n");
			close(fd);
			return (-1);
		}
	}
	close(fd);
	if (n < 0) {
		perror("getdents64");
		return (-1);
	}
	return (seen);
}

int
main(int argc, char **argv)
{
	static const size_t sizes[] = { 128, 280, 1024, 4096, 32768 };
	static char buf[32768];
	unsigned long long sum, sum0 = 0;
	int seen, seen0 = 0, calls, bad = 0;
	unsigned i;

	if (argc < 2) {
		fprintf(stderr, "usage: getdents-resume <dir> [sweep]\n");
		return (1);
	}
	if (argc < 3) {
		seen = pass(argv[1], buf, 64, 1, &sum, &calls);
		if (seen < 0)
			return (1);
		printf("entries=%d calls=%d\n", seen, calls);
		return (0);
	}
	for (i = 0; i < sizeof(sizes) / sizeof(sizes[0]); i++) {
		seen = pass(argv[1], buf, sizes[i], 0, &sum, &calls);
		if (seen < 0)
			return (1);
		if (i == 0) {
			seen0 = seen;
			sum0 = sum;
		} else if (seen != seen0 || sum != sum0) {
			bad++;
		}
		printf("size=%zu entries=%d calls=%d %s\n", sizes[i], seen,
		    calls, i == 0 ? "reference" :
		    (seen == seen0 && sum == sum0) ? "same" : "DIFFERENT");
	}
	printf("sweep: sizes=%u entries=%d mismatches=%d\n", i, seen0, bad);
	return (bad ? 1 : 0);
}
