/* SEEK_DATA and SEEK_HOLE on a HAMMER2 file.
 *
 * The failure this exists to catch is a wrong ANSWER, not a refusal.  A
 * filesystem that registers no ->llseek of its own gets
 * generic_file_llseek(), which treats the whole file as data: SEEK_HOLE
 * then returns i_size for a file that is mostly hole, and a sparse file
 * copied with `cp --sparse=always` or archived with `tar -S` comes out
 * dense and looks correct.
 *
 * So the test builds a file whose holes are known, asks where the data
 * is, and fails if the answer is the one the generic path would give.
 * The file is one logical block of data, one block of hole, one block of
 * data, then a truncate into what would be a fourth block.
 *
 * Every line it prints is prefixed, and the last two are the counts the
 * gate reads:
 *
 *     seek-ok <what>        a check that passed
 *     seek-fail <what>      a check that failed
 *     seek-checks <n>       how many checks ran
 *     seek-failures <n>     how many failed
 *
 * The prefix is what lets the gate do no quoting.  This runs inside a
 * single-quoted ssh command, where a quote ends the string early and
 * hands the rest of the script to this machine instead of the guest, so
 * the guest side prints what it is given and counts nothing itself.
 *
 * The hole is asserted to be real on media before the checks.  A file
 * whose middle block was written as zeroes is not sparse, SEEK_HOLE on
 * it correctly reports no hole, and the run would then be measuring a
 * different file from the one it built.
 */
#define _GNU_SOURCE
#include <sys/stat.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int fails;
static int checks;

static void
fail(const char *what, long got, long want)
{
	printf("seek-fail %s: got %ld, want %ld\n", what, got, want);
	fails++;
}

/* One probe: ask `whence` at `from` and compare with `want`. */
static void
probe(int fd, const char *what, int whence, long from, long want)
{
	off_t got = lseek(fd, from, whence);

	checks++;
	if (got != (off_t)want)
		fail(what, (long)got, (long)want);
	else
		printf("seek-ok   %s: %ld -> %ld\n", what, from, (long)got);
}

/* A seek that finds nothing is ENXIO, which lseek reports as -1. */
static void
probe_enxio(int fd, const char *what, int whence, long from)
{
	off_t got;

	checks++;
	got = lseek(fd, from, whence);
	if (got != -1)
		fail(what, (long)got, -1);
	else
		printf("seek-ok   %s: %ld -> -1\n", what, from);
}

int
main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "seek-test";
	long bsize = 65536;			/* HAMMER2_PBUFSIZE */
	long nbytes = 3 * bsize + bsize / 2;
	char *buf;
	int fd;

	if ((fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644)) < 0) {
		perror(path);
		return 2;
	}
	buf = malloc(bsize);
	if (!buf)
		return 2;
	memset(buf, 'A', bsize);

	/* block 0: data, block 1: hole, block 2: data */
	if (pwrite(fd, buf, bsize, 0) != bsize ||
	    pwrite(fd, buf, bsize, 2 * bsize) != bsize) {
		fprintf(stderr, "seek-setup pwrite failed\n");
		return 2;
	}
	if (ftruncate(fd, nbytes) != 0) {
		fprintf(stderr, "seek-setup ftruncate failed\n");
		return 2;
	}
	fsync(fd);

	/* The hole has to be real before anything below means anything. */
	{
		struct stat st;

		fstat(fd, &st);
		checks++;
		if (st.st_blocks * 512 >= nbytes) {
			printf("seek-fail the file is not sparse: %ld blocks "
			    "of 512 for %ld bytes, so no hole was made\n",
			    (long)st.st_blocks, nbytes);
			fails++;
		} else {
			printf("seek-ok   the middle block is a hole on media "
			    "(%ld blocks of 512)\n", (long)st.st_blocks);
		}
	}

	/* Data where data is: the start of block 0. */
	probe(fd, "SEEK_DATA at 0", SEEK_DATA, 0, 0);
	/* The first hole starts at the end of block 0. */
	probe(fd, "SEEK_HOLE at 0", SEEK_HOLE, 0, bsize);
	/* Inside the hole: data resumes at block 2.  SEEK_HOLE inside a hole
	 * answers the offset asked, not the hole's start, because the next
	 * hole at or after that offset is the one already being stood in. */
	probe(fd, "SEEK_DATA in hole", SEEK_DATA, bsize + 100, 2 * bsize);
	probe(fd, "SEEK_HOLE in hole", SEEK_HOLE, bsize + 100, bsize + 100);
	/* Inside block 2, which holds data: the next hole is block 3, made
	 * by the ftruncate with nothing ever written into it. */
	probe(fd, "SEEK_HOLE in data", SEEK_HOLE, 2 * bsize + 10, 3 * bsize);
	/* No data at or after block 3, and none at i_size. */
	probe_enxio(fd, "SEEK_DATA in last hole", SEEK_DATA, 3 * bsize);
	probe_enxio(fd, "SEEK_DATA at i_size", SEEK_DATA, nbytes);
	/* At i_size both whences find nothing: the caller is already at the
	 * implicit hole after the last byte, and the kernel reports ENXIO
	 * rather than handing back the offset it was given. */
	probe_enxio(fd, "SEEK_HOLE at i_size", SEEK_HOLE, nbytes);

	/* SEEK_SET/CUR/END must still work; they go through the same entry. */
	probe(fd, "SEEK_SET", SEEK_SET, 1234, 1234);
	probe(fd, "SEEK_CUR", SEEK_CUR, 100, 1334);
	probe(fd, "SEEK_END", SEEK_END, 0, nbytes);

	close(fd);
	unlink(path);
	printf("seek-checks %d\nseek-failures %d\n", checks, fails);
	return fails ? 1 : 0;
}
