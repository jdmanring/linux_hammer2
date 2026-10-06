/* The seek file of test/hammer2-seek.c, made and asked in separate runs.
 *
 * script/seek-matrix.sh needs the file to outlive the process that made
 * it, across a snapshot, a dedup and a hard stop of the guest, so the
 * make and the questions are separate commands here:
 *
 *     hammer2-seekprobe make  <path> [rand]   the shape, not synced; with
 *                                             rand the data is a fixed
 *                                             pseudo-random sequence that
 *                                             does not compress
 *     hammer2-seekprobe dedup <path> <n>      n full blocks of an
 *                                             incompressible sequence
 *                                             that continues across the
 *                                             blocks, so two files made
 *                                             so are large enough for the
 *                                             first's allocation to be a
 *                                             real measurement and are
 *                                             identical to dedup against
 *                                             each other
 *     hammer2-seekprobe check <path> <what>   the five questions the
 *                                             unsynced phase asks, and
 *                                             the bytes read back
 *     hammer2-seekprobe agree <path> <what>   for a file that may hold
 *                                             any prefix of the shape:
 *                                             no range SEEK_HOLE calls a
 *                                             hole may read back nonzero
 *
 * The shape and bounds are hammer2-seek.c's, so the two answer to one
 * contract: one 64 KiB block of 'A', one of hole, one of 'A', and a
 * truncate to half a block past the third.  A check reads the third block
 * back against the same fill it was made with.  lseek(2) lets a hole be
 * reported as data and never the reverse, so every bound is one-sided.
 *
 * Output is prefixed as hammer2-seek.c's is, seekm-ok and seekm-fail,
 * because the script counts it from inside a quoted ssh command.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define BSIZE	65536L
#define NBYTES	(3 * BSIZE + BSIZE / 2)

static int fails;

static void
range(int fd, const char *what, const char *q, int whence, long from,
    long lo, long hi)
{
	off_t got = lseek(fd, from, whence);

	if (got < (off_t)lo || got > (off_t)hi) {
		printf("seekm-fail %s, %s: got %ld, want %ld..%ld\n", what, q,
		    (long)got, lo, hi);
		fails++;
	} else
		printf("seekm-ok   %s, %s: %ld\n", what, q, (long)got);
}

/* The block's content: all 'A', or the dedup exerciser's generator. */
static void
fill(char *buf, int rand)
{
	unsigned int seed = 12345;
	long i;

	if (!rand) {
		memset(buf, 'A', BSIZE);
		return;
	}
	for (i = 0; i < BSIZE; i++) {
		seed = seed * 1103515245u + 12345u;
		buf[i] = (char)(seed >> 16);
	}
}

static int
make(const char *path, int rand)
{
	char *buf = malloc(BSIZE);
	int fd;

	if (buf == NULL)
		return (2);
	fill(buf, rand);
	if ((fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644)) < 0 ||
	    pwrite(fd, buf, BSIZE, 0) != BSIZE ||
	    pwrite(fd, buf, BSIZE, 2 * BSIZE) != BSIZE ||
	    ftruncate(fd, NBYTES) != 0) {
		printf("seekm-fail make %s\n", path);
		return (1);
	}
	close(fd);
	free(buf);
	return (0);
}

/*
 * Whether every byte of [off, off + len) is zero.  Short reads count as
 * nonzero, since a read that cannot be completed is not a hole.
 */
static int
zeroes(int fd, long off, long len)
{
	char b[4096];

	while (len > 0) {
		long n = len < (long)sizeof(b) ? len : (long)sizeof(b);
		long i;

		if (pread(fd, b, n, off) != n)
			return (0);
		for (i = 0; i < n; i++)
			if (b[i] != 0)
				return (0);
		off += n;
		len -= n;
	}
	return (1);
}

static int
check(const char *path, const char *what)
{
	char b[BSIZE], want[BSIZE];
	int fd;

	if ((fd = open(path, O_RDONLY)) < 0) {
		printf("seekm-fail %s: cannot open %s\n", what, path);
		return (1);
	}
	range(fd, what, "SEEK_DATA at 0", SEEK_DATA, 0, 0, 0);
	range(fd, what, "SEEK_DATA in data", SEEK_DATA, 2 * BSIZE + 10,
	    2 * BSIZE + 10, 2 * BSIZE + 10);
	range(fd, what, "SEEK_DATA in hole", SEEK_DATA, BSIZE + 100,
	    BSIZE + 100, 2 * BSIZE);
	range(fd, what, "SEEK_HOLE at 0", SEEK_HOLE, 0, BSIZE, NBYTES);
	range(fd, what, "SEEK_HOLE in data", SEEK_HOLE, 2 * BSIZE + 10,
	    3 * BSIZE, NBYTES);
	fill(want, 0);
	if (pread(fd, b, BSIZE, 2 * BSIZE) != BSIZE)
		b[0] = 0;
	if (memcmp(b, want, BSIZE) != 0)
		fill(want, 1);
	if (memcmp(b, want, BSIZE) != 0) {
		printf("seekm-fail %s, read back: the third block is not what "
		    "was written\n", what);
		fails++;
	} else
		printf("seekm-ok   %s, read back: the third block is what was "
		    "written\n", what);
	close(fd);
	return (fails ? 1 : 0);
}

/*
 * A file recovered from a hard stop may hold any prefix of the writes, so
 * the only claim is the contract's own: walk SEEK_HOLE/SEEK_DATA across
 * the file and read every range the walk calls a hole.
 */
static int
agree(const char *path, const char *what)
{
	off_t size, pos = 0;
	int fd, holes = 0;

	if ((fd = open(path, O_RDONLY)) < 0) {
		printf("seekm-fail %s: cannot open %s\n", what, path);
		return (1);
	}
	size = lseek(fd, 0, SEEK_END);
	while (pos < size) {
		off_t h = lseek(fd, pos, SEEK_HOLE), d;

		if (h < 0 || h >= size)
			break;
		d = lseek(fd, h, SEEK_DATA);
		if (d < 0)
			d = size;
		holes++;
		if (!zeroes(fd, h, d - h)) {
			printf("seekm-fail %s: %ld..%ld is called a hole and "
			    "reads back nonzero\n", what, (long)h, (long)d);
			fails++;
		}
		pos = d;
	}
	if (!fails)
		printf("seekm-ok   %s: %d hole range(s) over %ld bytes, each "
		    "reading back zero\n", what, holes, (long)size);
	close(fd);
	return (fails ? 1 : 0);
}

/*
 * The same generator as `make ... rand`, continued across blocks rather
 * than restarted at each one.  Restarting would write the same 64 KiB n
 * times, and a file that deduplicates against ITSELF costs one block
 * however small the free count moves, which reads as sharing between the
 * two files that was never measured.
 */
static unsigned int dedup_seed = 12345;

static void
fill_next(char *buf)
{
	long i;

	for (i = 0; i < BSIZE; i++) {
		dedup_seed = dedup_seed * 1103515245u + 12345u;
		buf[i] = (char)(dedup_seed >> 16);
	}
}

static int
dedup(const char *path, long n)
{
	char *buf;
	long i;
	int fd;

	if (n < 1 || (buf = malloc(BSIZE)) == NULL)
		return (2);
	if ((fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644)) < 0) {
		free(buf);
		return (2);
	}
	for (i = 0; i < n; i++) {
		fill_next(buf);
		if (pwrite(fd, buf, BSIZE, i * BSIZE) != BSIZE) {
			printf("seekm-fail dedup %s\n", path);
			close(fd);
			free(buf);
			return (1);
		}
	}
	close(fd);
	free(buf);
	return (0);
}

int
main(int argc, char **argv)
{
	if (argc == 3 && strcmp(argv[1], "make") == 0)
		return (make(argv[2], 0));
	if (argc == 4 && strcmp(argv[1], "make") == 0 &&
	    strcmp(argv[3], "rand") == 0)
		return (make(argv[2], 1));
	if (argc == 4 && strcmp(argv[1], "dedup") == 0)
		return (dedup(argv[2], strtol(argv[3], NULL, 10)));
	if (argc == 4 && strcmp(argv[1], "check") == 0)
		return (check(argv[2], argv[3]));
	if (argc == 4 && strcmp(argv[1], "agree") == 0)
		return (agree(argv[2], argv[3]));
	fprintf(stderr, "usage: %s make <path> [rand] | dedup <path> <n> | "
	    "check|agree <path> <what>\n",
	    argv[0]);
	return (2);
}
