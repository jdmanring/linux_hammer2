/*
 * Root-directory churn for script/sync-root-entry.sh: operations that edit
 * the PFS root's entries while a sync or a snapshot runs, and a back-to-back
 * syncfs(2) loop beside them.
 *
 *   rootchurn mkdir  <dir> <id> <secs>   mkdir then rmdir <dir>/m<id>, repeated
 *   rootchurn create <dir> <id> <secs>   mkdir <dir>/d<id>.<k>, k = 0, 1, ...
 *   rootchurn rename <dir> <id> <secs>   <dir>/r<id> to <dir>/sub/r<id> and back
 *   rootchurn link   <dir> <id> <secs>   link <dir>/sub/l<id> as <dir>/l<id>, unlink it
 *   rootchurn unlink <dir> <id> <secs>   create <dir>/u<id>.<k>, unlink the one
 *                                        made LAG creates earlier
 *   rootchurn sync   <dir> <secs>        syncfs(2) on <dir>'s filesystem, back to back
 *
 * A fifth argument sleeps that many us after each operation, so a churn
 * through many snapshots leaves a tree a dump can still be read from.
 *
 * Prints one line: the mode, the id, the operations done, the errors and the
 * first errno; sync prints the count and the longest and mean call in us.
 * Exits 1 on any error, so a run that did nothing is not read as quiet.
 * SIGTERM ends the loop early and the line still prints.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <signal.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define LAG	200

static volatile sig_atomic_t stop;

static void
onterm(int sig)
{
	(void)sig;
	stop = 1;
}

static double
now(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (ts.tv_sec + ts.tv_nsec / 1e9);
}

int
main(int argc, char **argv)
{
	char a[4096], b[4096];
	unsigned long n = 0, errs = 0;
	int first = 0, id, fd, gap;
	double end, t, d, max = 0, sum = 0;

	signal(SIGTERM, onterm);	/* SIGTERM ends the loop; the line still prints */
	if (argc < 4)
		goto usage;
	if (strcmp(argv[1], "sync") == 0) {
		end = now() + atof(argv[3]);
		if ((fd = open(argv[2], O_RDONLY | O_DIRECTORY)) < 0) {
			perror(argv[2]);
			return (1);
		}
		while (now() < end && !stop) {
			t = now();
			if (syncfs(fd) != 0 && errs++ == 0)
				first = errno;
			d = now() - t;
			sum += d;
			if (d > max)
				max = d;
			++n;
		}
		printf("sync ops %lu errors %lu errno %d max_us %.0f mean_us %.0f\n",
		    n, errs, first, max * 1e6, n ? sum / n * 1e6 : 0);
		return (errs != 0 || n == 0);
	}
	if (argc < 5)
		goto usage;
	id = atoi(argv[3]);
	end = now() + atof(argv[4]);
	gap = argc > 5 ? atoi(argv[5]) : 0;
	if (strcmp(argv[1], "mkdir") == 0) {
		snprintf(a, sizeof(a), "%s/m%d", argv[2], id);
		while (now() < end && !stop) {
			if (mkdir(a, 0755) != 0 || rmdir(a) != 0) {
				if (errs++ == 0)
					first = errno;
				break;
			}
			n += 2;
			if (gap)
				usleep(gap);
		}
	} else if (strcmp(argv[1], "create") == 0) {
		while (now() < end && !stop) {
			snprintf(a, sizeof(a), "%s/d%d.%lu", argv[2], id, n);
			if (mkdir(a, 0755) != 0) {
				if (errs++ == 0)
					first = errno;
				break;
			}
			++n;
			if (gap)
				usleep(gap);
		}
	} else if (strcmp(argv[1], "rename") == 0) {
		snprintf(a, sizeof(a), "%s/r%d", argv[2], id);
		snprintf(b, sizeof(b), "%s/sub/r%d", argv[2], id);
		if ((fd = open(a, O_CREAT | O_WRONLY, 0644)) < 0) {
			perror(a);
			return (1);
		}
		close(fd);
		while (now() < end && !stop) {
			if (rename(a, b) != 0 || rename(b, a) != 0) {
				if (errs++ == 0)
					first = errno;
				break;
			}
			n += 2;
			if (gap)
				usleep(gap);
		}
	} else if (strcmp(argv[1], "link") == 0) {
		snprintf(a, sizeof(a), "%s/sub/l%d", argv[2], id);
		snprintf(b, sizeof(b), "%s/l%d", argv[2], id);
		if ((fd = open(a, O_CREAT | O_WRONLY, 0644)) < 0) {
			perror(a);
			return (1);
		}
		close(fd);
		while (now() < end && !stop) {
			if (link(a, b) != 0 || unlink(b) != 0) {
				if (errs++ == 0)
					first = errno;
				break;
			}
			n += 2;
			if (gap)
				usleep(gap);
		}
	} else if (strcmp(argv[1], "unlink") == 0) {
		while (now() < end && !stop) {
			snprintf(a, sizeof(a), "%s/u%d.%lu", argv[2], id, n);
			if ((fd = open(a, O_CREAT | O_WRONLY, 0644)) < 0) {
				if (errs++ == 0)
					first = errno;
				break;
			}
			close(fd);
			if (n >= LAG) {
				snprintf(b, sizeof(b), "%s/u%d.%lu", argv[2], id,
				    n - LAG);
				if (unlink(b) != 0) {
					if (errs++ == 0)
						first = errno;
					break;
				}
			}
			++n;
			if (gap)
				usleep(gap);
		}
	} else {
		goto usage;
	}
	printf("%s %d ops %lu errors %lu errno %d\n", argv[1], id, n, errs, first);
	return (errs != 0 || n == 0);
usage:
	fprintf(stderr, "usage: rootchurn mkdir|create|rename|link|unlink <dir> <id> <secs> [gap_us]\n"
	    "       rootchurn sync <dir> <secs>\n");
	return (2);
}
