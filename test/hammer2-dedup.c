/* Deduplication on a HAMMER2 file.
 *
 * The failure this exists to catch is a feature that is advertised, on by
 * default, and never checked.  `hammer2_dedup_enable` defaults to 1 and the
 * write path asks `hammer2_dedup_lookup()` before allocating every data
 * block, so a second copy of a block should be pointed at the first one's
 * media instead of taking fresh media.  Nothing in this tree had ever
 * written a duplicate block: `script/throughput.sh` is the only file that
 * names dedup and it draws fresh random data every pass precisely so a run
 * cannot read as a dedup hit.
 *
 * The observable is free space, which needs no debug hook and is what a
 * consumer would use.  Two files are written; the second holds the same
 * bytes as the first.  If dedup works the volume gives back roughly half the
 * blocks; if it does not, both take full allocation.  The check is a
 * comparison of the two, not a fixed number, so a volume with other data on
 * it still measures the difference the duplicate made.
 *
 * A FAKE PASS would be a run where the file was never written, where the
 * free count did not move at all (so the difference is zero either way), or
 * where the block size is not what the arithmetic assumes.  The test prints
 * every raw count it uses, asserts the counts are sane, and asserts the
 * first file alone moved them, before it interprets the second.
 *
 * Every line is prefixed so the gate does no quoting:
 *
 *     dedup-ok <what>        a check that passed
 *     dedup-fail <what>      a check that failed
 *     dedup-checks <n>       how many checks ran
 *     dedup-failures <n>     how many failed
 */
#define _GNU_SOURCE
#include <sys/stat.h>
#include <sys/statfs.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int fails;
static int checks;

/* Free blocks in units of the filesystem's own fragment size, which is what
 * the count is in on every filesystem.  Read after a sync so dirty pages have
 * become allocations.  The unit is returned through *unitp rather than
 * assumed: this port reports HAMMER2_PBUFSIZE (64 KiB) while btrfs reports
 * 4 KiB, and the reference control is run on btrfs. */
static long
free_blocks(const char *dir, long *unitp)
{
	struct statfs sf;

	if (statfs(dir, &sf) != 0)
		return (-1);
	if (sf.f_frsize <= 0)
		return (-1);
	*unitp = (long)sf.f_frsize;
	return ((long)sf.f_bfree);
}

static int
write_file(const char *path, const char *buf, size_t len, long bsize)
{
	int fd;
	size_t done = 0;

	if ((fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644)) < 0)
		return (-1);
	while (done < len) {
		ssize_t n = pwrite(fd, buf + done, len - done, done);
		if (n <= 0) {
			close(fd);
			return (-1);
		}
		done += (size_t)n;
	}
	fsync(fd);
	close(fd);
	(void)bsize;
	return (0);
}

int
main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : ".";
	long bsize;
	long unit = 0;
	long nblocks;				/* blocks per file */
	long bytes;				/* nblocks * bsize */
	char p1[4096], p2[4096];
	char *buf;
	long f0, f1, f2;
	long grew1, grew2;

	if (snprintf(p1, sizeof(p1), "%s/dedup-a", dir) >= (int)sizeof(p1) ||
	    snprintf(p2, sizeof(p2), "%s/dedup-b", dir) >= (int)sizeof(p2)) {
		fprintf(stderr, "dedup-setup path too long\n");
		return 2;
	}
	/*
	 * One statfs before anything is allocated, to learn the unit this
	 * filesystem counts in.  Everything below is expressed in that unit,
	 * so the run is meaningful on this port's 64 KiB blocks and on btrfs's
	 * 4 KiB ones, and the two readings are comparable.
	 */
	if (free_blocks(dir, &unit) < 0 || unit <= 0) {
		fprintf(stderr, "dedup-setup statfs failed\n");
		return 2;
	}
	bytes = 4L * 1024 * 1024;		/* 4 MiB per file, as before */
	bsize = unit;
	nblocks = bytes / unit;
	if (nblocks < 4) {
		fprintf(stderr, "dedup-setup unit too large for a 4 MiB file\n");
		return 2;
	}
	printf("dedup-ok   filesystem counts in %ld-byte units, %ld per file\n",
	    unit, nblocks);

	buf = malloc((size_t)bsize * nblocks);
	if (!buf) {
		fprintf(stderr, "dedup-setup malloc failed\n");
		return 2;
	}

	/*
	 * Pseudo-random but reproducible, and incompressible enough that the
	 * core does not store it compressed: a compressed block is a
	 * different length and could not be shared at all, which would make
	 * the reading about the compressor instead of the dedup.
	 */
	{
		unsigned int seed = 12345;
		size_t i;
		for (i = 0; i < (size_t)bsize * nblocks; ++i) {
			seed = seed * 1103515245u + 12345u;
			buf[i] = (char)(seed >> 16);
		}
	}

	unlink(p1);
	unlink(p2);
	sync();
	f0 = free_blocks(dir, &unit);
	if (f0 < 0) {
		fprintf(stderr, "dedup-setup statfs failed or block size is "
		    "not 64 KiB\n");
		return 2;
	}
	printf("dedup-ok   free blocks before: %ld\n", f0);

	/* File A alone, synced: this is what one copy of the data costs. */
	if (write_file(p1, buf, (size_t)bsize * nblocks, bsize) != 0) {
		fprintf(stderr, "dedup-setup write A failed\n");
		return 2;
	}
	sync();
	f1 = free_blocks(dir, &unit);
	if (f1 < 0) {
		fprintf(stderr, "dedup-setup statfs failed\n");
		return 2;
	}
	printf("dedup-ok   free blocks after file A: %ld\n", f1);

	/* File B holds the same bytes.  If dedup works it costs far less. */
	if (write_file(p2, buf, (size_t)bsize * nblocks, bsize) != 0) {
		fprintf(stderr, "dedup-setup write B failed\n");
		return 2;
	}
	sync();
	f2 = free_blocks(dir, &unit);
	if (f2 < 0) {
		fprintf(stderr, "dedup-setup statfs failed\n");
		return 2;
	}
	printf("dedup-ok   free blocks after file B: %ld\n", f2);

	grew1 = f0 - f1;			/* what file A cost */
	grew2 = f1 - f2;			/* what the duplicate cost */

	/* Sanity first: a run where nothing was written proves nothing. */
	checks++;
	if (grew1 < nblocks / 2) {
		printf("dedup-fail file A did not move the count: "
		    "cost %ld blocks for a %ld-block file\n",
		    grew1, nblocks);
		fails++;
	} else {
		printf("dedup-ok   file A allocated %ld blocks "
		    "for %ld blocks of data\n", grew1, nblocks);
	}

	checks++;
	if (grew2 <= 0) {
		printf("dedup-fail the duplicate moved the count by %ld: "
		    "the reading is about nothing\n", grew2);
		fails++;
	} else {
		printf("dedup-ok   the duplicate cost %ld blocks against "
		    "file A's %ld\n", grew2, grew1);
	}

	/*
	 * The measurement.  A block shared by dedup costs only its
	 * blockref, so the duplicate should be a small fraction of the
	 * first file.  The bar is a quarter, loose on purpose: the refs and
	 * whatever the allocator rounds up are real costs, and a threshold
	 * tuned tight would fail for reasons unrelated to dedup.
	 */
	if (grew1 > 0) {
		checks++;
		if (grew2 < grew1 / 4) {
			printf("dedup-ok   the duplicate was shared, not "
			    "allocated: %ld against %ld blocks\n",
			    grew2, grew1);
		} else {
			printf("dedup-fail the duplicate allocated its own "
			    "media: %ld against %ld blocks for identical "
			    "content\n", grew2, grew1);
			fails++;
		}
	}

	unlink(p1);
	unlink(p2);
	free(buf);
	printf("dedup-checks %d\ndedup-failures %d\n", checks, fails);
	return fails ? 1 : 0;
}
