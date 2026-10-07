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
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/statfs.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
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

/*
 * A seek that finds nothing is ENXIO, which lseek reports as -1.  The
 * errno is checked as well as the -1: every lseek failure returns -1, so
 * a probe that read only the return took EINVAL for ENXIO, and the
 * negative-offset checks passed on a build that answered EINVAL to all
 * four of generic/448's questions.
 */
static void
probe_enxio(int fd, const char *what, int whence, long from)
{
	off_t got;

	checks++;
	errno = 0;
	got = lseek(fd, from, whence);
	if (got != -1)
		fail(what, (long)got, -1);
	else if (errno != ENXIO) {
		printf("seek-fail %s: -1 with errno %d, want ENXIO (%d)\n",
		    what, errno, ENXIO);
		fails++;
	} else
		printf("seek-ok   %s: %ld -> -1 ENXIO\n", what, from);
}

/*
 * One probe whose answer may fall anywhere in [lo, hi].  lseek(2) lets a
 * filesystem report a hole as data, so a SEEK_HOLE may land late and a
 * SEEK_DATA early, but never may data be reported as a hole: the bounds
 * are what that one-sided contract allows.
 */
static void
probe_range(int fd, const char *what, int whence, long from, long lo,
    long hi)
{
	off_t got = lseek(fd, from, whence);

	checks++;
	if (got < (off_t)lo || got > (off_t)hi) {
		printf("seek-fail %s: got %ld, want %ld..%ld\n", what,
		    (long)got, lo, hi);
		fails++;
	} else
		printf("seek-ok   %s: %ld -> %ld\n", what, from, (long)got);
}

/* block 0: data, block 1: hole, block 2: data, then a truncate past it */
static int
build(const char *path, const char *buf, long bsize, long nbytes)
{
	int fd;

	if ((fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644)) < 0) {
		perror(path);
		return (-1);
	}
	if (pwrite(fd, buf, bsize, 0) != bsize ||
	    pwrite(fd, buf, bsize, 2 * bsize) != bsize) {
		fprintf(stderr, "seek-setup pwrite failed\n");
		close(fd);
		return (-1);
	}
	if (ftruncate(fd, nbytes) != 0) {
		fprintf(stderr, "seek-setup ftruncate failed\n");
		close(fd);
		return (-1);
	}
	return (fd);
}

/*
 * The same file, asked before anything has synced it.  Upstream disabled
 * FIOSEEKHOLE in 0d0182bdb4 because its blockref tree lags the file's
 * buffers after a write, and the answer from the tree alone reports
 * written data as a hole.  A copy that trusts that answer writes zeroes
 * where the data was.  The phase above cannot see this: its fsync() has
 * already put every block in the tree.
 *
 * The probes run microseconds after the writes, inside the writeback
 * interval, so the data is dirty in the page cache when they ask.  A pass
 * that came from writeback winning that race would look identical; it is
 * not likely at this distance, and the control is the same run on tmpfs
 * and btrfs, which must pass.
 */
static void
unsynced(const char *path, const char *buf, long bsize, long nbytes)
{
	int fd = build(path, buf, bsize, nbytes);

	if (fd < 0) {
		checks++;
		fails++;
		printf("seek-fail unsynced: the file could not be built\n");
		return;
	}
	probe(fd, "unsynced SEEK_DATA at 0", SEEK_DATA, 0, 0);
	probe(fd, "unsynced SEEK_DATA in data", SEEK_DATA, 2 * bsize + 10,
	    2 * bsize + 10);
	probe_range(fd, "unsynced SEEK_DATA in hole", SEEK_DATA, bsize + 100,
	    bsize + 100, 2 * bsize);
	probe_range(fd, "unsynced SEEK_HOLE at 0", SEEK_HOLE, 0, bsize, nbytes);
	probe_range(fd, "unsynced SEEK_HOLE in data", SEEK_HOLE,
	    2 * bsize + 10, 3 * bsize, nbytes);
	close(fd);
	unlink(path);
}

/*
 * One byte at `off` in a file three blocks long, synced or not.  The
 * offsets that matter are either side of a block boundary and on it,
 * since the scan asks by block and rounds.  The bounds hold on any block
 * size: the data must be found no later than the byte, and the hole
 * after it no earlier than the byte after it.  Not the end of HAMMER2's
 * 64 KiB block: tmpfs and btrfs end the data at their own 4 KiB, which
 * lseek(2) allows, and a bound taken from this driver's granularity is
 * the mistake this exerciser's first version made.
 */
static void
one_byte(const char *path, long off, int synced, long bsize)
{
	long size = 3 * bsize;
	char what[96];
	int fd;

	if ((fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644)) < 0 ||
	    ftruncate(fd, size) != 0 || pwrite(fd, "B", 1, off) != 1) {
		checks++;
		fails++;
		printf("seek-fail byte at %ld: the file could not be built\n",
		    off);
		if (fd >= 0)
			close(fd);
		return;
	}
	if (synced)
		fsync(fd);
	snprintf(what, sizeof(what), "%s byte at %ld, SEEK_DATA at 0",
	    synced ? "synced" : "unsynced", off);
	probe_range(fd, what, SEEK_DATA, 0, 0, off);
	snprintf(what, sizeof(what), "%s byte at %ld, SEEK_HOLE at it",
	    synced ? "synced" : "unsynced", off);
	probe_range(fd, what, SEEK_HOLE, off, off + 1, size);
	close(fd);
	unlink(path);
}

/*
 * A write through a shared mapping and no msync(): the folio is dirtied
 * at the fault, and the tree knows nothing of it until writeback.
 */
/*
 * A file small enough to live in the inode.  HAMMER2 stores up to
 * HAMMER2_EMBEDDED_BYTES (512) of a file's data in the inode's own
 * metadata, with HAMMER2_OPFLAG_DIRECTDATA set and no blockref tree at
 * all, so a scan of the tree finds nothing and has no answer to give.
 * The file is still all data from 0 to i_size, so the contract is that
 * SEEK_DATA answers the offset asked and SEEK_HOLE answers i_size.
 *
 * This is the case a copier trips over: `cp` asks SEEK_HOLE at 0, and an
 * answer of 0 says the whole file is a hole, so it writes a file of the
 * right length filled with zeros and reports success.
 */
static void
embedded(const char *path, long bsize)
{
	char what[128];
	long sizes[] = { 1, 512 };
	int i;
	int fd;

	(void)bsize;
	for (i = 0; i < 2; i++) {
		long n = sizes[i];

		/* Written small on purpose: build() writes whole blocks. */
		if ((fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644)) < 0) {
			perror(path);
			continue;
		}
		if (write(fd, "E", 1) != 1) {
			fprintf(stderr, "seek-setup small write failed\n");
			close(fd);
			continue;
		}
		if (ftruncate(fd, n) != 0) {
			fprintf(stderr, "seek-setup small truncate failed\n");
			close(fd);
			continue;
		}
		fsync(fd);
		close(fd);
		if ((fd = open(path, O_RDONLY)) < 0)
			continue;
		snprintf(what, sizeof(what), "%ld-byte file in the inode, "
		    "SEEK_DATA at 0", n);
		probe(fd, what, SEEK_DATA, 0, 0);
		snprintf(what, sizeof(what), "%ld-byte file in the inode, "
		    "SEEK_HOLE at 0", n);
		probe(fd, what, SEEK_HOLE, 0, n);
		snprintf(what, sizeof(what), "%ld-byte file in the inode, "
		    "SEEK_DATA at the last byte", n);
		probe(fd, what, SEEK_DATA, n - 1, n - 1);
		snprintf(what, sizeof(what), "%ld-byte file in the inode, "
		    "SEEK_HOLE at the last byte", n);
		probe(fd, what, SEEK_HOLE, n - 1, n);
		close(fd);
		unlink(path);
	}
}

/*
 * A writer and a seeker on the same file at once.  The writer fills the
 * file's blocks one at a time in increasing order, unsynced, and after
 * each one publishes how many it has finished through a shared counter.
 * The seeker reads the counter, then asks SEEK_HOLE from 0: every block
 * below the counter it read was complete before the question was asked,
 * so the hole may not start inside them.  It may start anywhere at or
 * past them, since the writer is still going.  SEEK_DATA from 0 has to
 * answer 0 once the first block is done.
 *
 * This is the window the writeback-before-scan fix closes, with the
 * writeback racing new dirty folios rather than settled ones: a scan that
 * wrote back only what was dirty when it started, then read a tree that a
 * second writeback was changing, could report a finished block as a hole.
 *
 * The count of questions asked is printed and asserted, since a seeker
 * that never overlapped the writer would pass without testing anything.
 */
#define RACE_BLOCKS	64

static void
concurrent(const char *path, long bsize)
{
	volatile long *done;
	char *buf;
	pid_t pid;
	long asked = 0, bad = 0, i;
	int fd, st;

	checks++;
	done = mmap(NULL, sizeof(*done), PROT_READ | PROT_WRITE,
	    MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	buf = malloc(bsize);
	if (done == MAP_FAILED || buf == NULL ||
	    (fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644)) < 0 ||
	    ftruncate(fd, RACE_BLOCKS * bsize) != 0) {
		printf("seek-fail concurrent: the file could not be built\n");
		fails++;
		free(buf);
		return;
	}
	*done = 0;
	memset(buf, 'C', bsize);
	pid = fork();
	if (pid == 0) {
		for (i = 0; i < RACE_BLOCKS; i++) {
			if (pwrite(fd, buf, bsize, i * bsize) != bsize)
				_exit(1);
			__atomic_store_n(done, i + 1, __ATOMIC_RELEASE);
			/*
			 * Paced, so the overlap does not depend on which
			 * process the scheduler favours: unpaced, tmpfs
			 * finished all 64 blocks before the seeker asked
			 * twice, in one run of three.
			 */
			usleep(2000);
		}
		_exit(0);
	}
	while (__atomic_load_n(done, __ATOMIC_ACQUIRE) < RACE_BLOCKS) {
		long n = __atomic_load_n(done, __ATOMIC_ACQUIRE);
		off_t h, d;

		if (n == 0)
			continue;
		asked++;
		h = lseek(fd, 0, SEEK_HOLE);
		d = lseek(fd, 0, SEEK_DATA);
		if (h < n * bsize || d != 0) {
			if (bad++ == 0)
				printf("seek-fail concurrent: with %ld block(s) "
				    "done, SEEK_HOLE at 0 said %ld and SEEK_DATA "
				    "%ld\n", n, (long)h, (long)d);
		}
	}
	waitpid(pid, &st, 0);
	close(fd);
	unlink(path);
	free(buf);
	munmap((void *)done, sizeof(*done));
	if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
		printf("seek-fail concurrent: the writer failed\n");
		fails++;
	} else if (asked < RACE_BLOCKS) {
		printf("seek-fail concurrent: only %ld question(s) overlapped "
		    "the writer, so the race was not run\n", asked);
		fails++;
	} else if (bad) {
		printf("seek-fail concurrent: %ld of %ld answers called a "
		    "finished block a hole\n", bad, asked);
		fails++;
	} else
		printf("seek-ok   concurrent: %ld answers during %d block "
		    "writes, none calling a finished block a hole\n", asked,
		    RACE_BLOCKS);
}

static void
mapped(const char *path, long bsize)
{
	long size = 3 * bsize, off = 2 * bsize + 5;
	char *p;
	int fd;

	checks++;
	if ((fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644)) < 0 ||
	    ftruncate(fd, size) != 0 ||
	    (p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd,
	    0)) == MAP_FAILED) {
		fails++;
		printf("seek-fail mapped: the mapping could not be built\n");
		if (fd >= 0)
			close(fd);
		return;
	}
	checks--;
	p[off] = 'M';
	probe_range(fd, "mapped, SEEK_DATA at 0", SEEK_DATA, 0, 0, off);
	probe_range(fd, "mapped, SEEK_HOLE at the byte", SEEK_HOLE, off,
	    off + 1, size);
	munmap(p, size);
	close(fd);
	unlink(path);
}

/*
 * Shrunk into the first block and grown back: the data ends at the cut,
 * and nothing after it is data, synced or not.
 */
static void
regrow(const char *path, const char *buf, int synced, long bsize)
{
	long size = 3 * bsize, cut = bsize / 2;
	char what[96];
	int fd;

	if ((fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644)) < 0 ||
	    pwrite(fd, buf, bsize, 0) != bsize || fsync(fd) != 0 ||
	    ftruncate(fd, cut) != 0 || ftruncate(fd, size) != 0) {
		checks++;
		fails++;
		printf("seek-fail regrow: the file could not be built\n");
		if (fd >= 0)
			close(fd);
		return;
	}
	if (synced)
		fsync(fd);
	snprintf(what, sizeof(what), "%s regrown, SEEK_HOLE at 0",
	    synced ? "synced" : "unsynced");
	probe_range(fd, what, SEEK_HOLE, 0, cut, size);
	snprintf(what, sizeof(what), "%s regrown, SEEK_DATA at 0",
	    synced ? "synced" : "unsynced");
	probe(fd, what, SEEK_DATA, 0, 0);
	close(fd);
	unlink(path);
}

/*
 * Run `hammer2 setcomp <algo> <dir>`.  0 when the command ran and exited
 * 0, which on this driver means the inode ioctl took the setting.
 */
static int
setcomp(const char *algo, const char *dir)
{
	int st;
	pid_t pid = fork();

	if (pid == 0) {
		int nul = open("/dev/null", O_WRONLY);

		if (nul >= 0) {
			dup2(nul, 1);
			dup2(nul, 2);
		}
		execlp("hammer2", "hammer2", "setcomp", algo, dir, (char *)NULL);
		_exit(127);
	}
	if (pid < 0 || waitpid(pid, &st, 0) != pid)
		return (-1);
	return (WIFEXITED(st) ? WEXITSTATUS(st) : -1);
}

/*
 * The block count of the three-block test file, written under the calling
 * directory's compression and synced, so the two sides below compare.
 * -1 on failure.
 */
static long
written_blocks(const char *t, const char *buf, long bsize, long nbytes)
{
	struct stat st;
	int fd = build(t, buf, bsize, nbytes);

	if (fd < 0)
		return (-1);
	if (fsync(fd) != 0 || fstat(fd, &st) != 0) {
		close(fd);
		unlink(t);
		return (-1);
	}
	close(fd);
	unlink(t);
	return ((long)st.st_blocks);
}

/*
 * The unsynced questions again, under compression.  A compressed block is
 * written by a different path, hammer2_compress_and_write(), so the seek's
 * writeback has to reach that path too before the scan.  The file is the
 * same as everywhere else here, and its contents compress to almost
 * nothing.
 *
 * Compression is set per directory with `hammer2 setcomp` and inherited by
 * the files made in it.  The volume's default is LZ4, so the comparison
 * side is set to none explicitly rather than assumed.  That compression
 * actually happened is asserted, not trusted: the file written under zlib
 * has to occupy fewer blocks of 512 than the same file under none, and the
 * file under none has to hold both its data blocks.  Without that, a
 * setcomp that silently did nothing would pass every seek check below on
 * uncompressed data and report it as compressed.
 *
 * Only on HAMMER2, whose statfs type is HAMMER2_SUPER_MAGIC: the control
 * filesystems have no setcomp, and the phase prints that it was skipped.
 */
#define H2_SUPER_MAGIC	0x48414d32	/* HAMMER2_SUPER_MAGIC */

static void
compressed(const char *path, const char *buf, long bsize, long nbytes)
{
	char dd[4096], dn[4096 + 16], dz[4096 + 16], tn[4096 + 32],
	    tz[4096 + 32];
	struct statfs sfs;
	long bn, bz;
	char *slash;

	snprintf(dd, sizeof(dd), "%s", path);
	if ((slash = strrchr(dd, '/')) != NULL)
		*slash = 0;
	else
		snprintf(dd, sizeof(dd), ".");
	if (statfs(dd, &sfs) != 0 || sfs.f_type != H2_SUPER_MAGIC) {
		printf("seek-skip compression: not a HAMMER2 mount\n");
		return;
	}
	snprintf(dn, sizeof(dn), "%s/.h2seek-none", dd);
	snprintf(dz, sizeof(dz), "%s/.h2seek-zlib", dd);
	snprintf(tn, sizeof(tn), "%s/f", dn);
	snprintf(tz, sizeof(tz), "%s/f", dz);

	checks++;
	if ((mkdir(dn, 0755) != 0 && errno != EEXIST) ||
	    (mkdir(dz, 0755) != 0 && errno != EEXIST) ||
	    setcomp("none", dn) != 0 || setcomp("zlib:9", dz) != 0) {
		fails++;
		printf("seek-fail compression: setcomp did not take\n");
		goto out;
	}
	bn = written_blocks(tn, buf, bsize, nbytes);
	bz = written_blocks(tz, buf, bsize, nbytes);
	if (bn < 2 * bsize / 512 || bz < 0 || bz >= bn) {
		fails++;
		printf("seek-fail compression: %ld blocks of 512 under none "
		    "against %ld under zlib, so nothing was compressed\n",
		    bn, bz);
		goto out;
	}
	printf("seek-ok   compression: %ld blocks of 512 under none against "
	    "%ld under zlib\n", bn, bz);

	unsynced(tz, buf, bsize, nbytes);
out:
	unlink(tn);
	unlink(tz);
	rmdir(dn);
	rmdir(dz);
}

int
main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "seek-test";
	long bsize = 65536;			/* HAMMER2_PBUFSIZE */
	long nbytes = 3 * bsize + bsize / 2;
	char dpath[4096];
	char *buf;
	int fd;

	buf = malloc(bsize);
	if (!buf)
		return 2;
	memset(buf, 'A', bsize);

	/* First, before any sync of its own has run on this file. */
	snprintf(dpath, sizeof(dpath), "%s.unsynced", path);
	unsynced(dpath, buf, bsize, nbytes);
	{
		long offs[] = { bsize - 1, bsize, bsize + 1 };
		int i, s;

		for (s = 0; s < 2; s++)
			for (i = 0; i < 3; i++)
				one_byte(dpath, offs[i], s, bsize);
		regrow(dpath, buf, 0, bsize);
		regrow(dpath, buf, 1, bsize);
		mapped(dpath, bsize);
		compressed(dpath, buf, bsize, nbytes);
		embedded(dpath, bsize);
		concurrent(dpath, bsize);
	}

	if ((fd = build(path, buf, bsize, nbytes)) < 0)
		return 2;
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
	/*
	 * A negative offset is before the start of the file, so both whences
	 * find nothing and the answer is ENXIO, not EINVAL.  That is what
	 * iomap_seek_hole() and iomap_seek_data() do and what
	 * generic_file_llseek() does, comparing the offset as unsigned so a
	 * negative one reads as past the end, and tmpfs agrees.  This port
	 * answered EINVAL until xfstests generic/448 asked it four ways.
	 *
	 * The offsets are the ones generic/448 asks with, -1 and LLONG_MIN,
	 * on a file of size 0, which is the shape that case uses.  A
	 * negative answer of 0 would mean a scan from before the file
	 * answered as though it were at its start.
	 */
	probe_enxio(fd, "SEEK_HOLE at -1", SEEK_HOLE, -1);
	probe_enxio(fd, "SEEK_DATA at -1", SEEK_DATA, -1);
	probe_enxio(fd, "SEEK_HOLE at LLONG_MIN", SEEK_HOLE, LLONG_MIN);
	probe_enxio(fd, "SEEK_DATA at LLONG_MIN", SEEK_DATA, LLONG_MIN);
	{
		/*
		 * Its own file: truncating `path` would empty the file `fd`
		 * still has open, and the SEEK_END below would then read 0.
		 */
		char zpath[4096 + 8];
		int zfd;

		snprintf(zpath, sizeof(zpath), "%s.zero", path);
		zfd = open(zpath, O_CREAT | O_TRUNC | O_RDWR, 0644);
		if (zfd < 0) {
			checks++;
			fails++;
			printf("seek-fail a zero-length file could not be "
			    "made for the negative-offset checks\n");
		} else {
			probe_enxio(zfd, "SEEK_HOLE at -1 on a file of size 0",
			    SEEK_HOLE, -1);
			probe_enxio(zfd, "SEEK_DATA at -1 on a file of size 0",
			    SEEK_DATA, -1);
			close(zfd);
		}
		unlink(zpath);
	}

	/* SEEK_SET/CUR/END must still work; they go through the same entry. */
	probe(fd, "SEEK_SET", SEEK_SET, 1234, 1234);
	probe(fd, "SEEK_CUR", SEEK_CUR, 100, 1334);
	probe(fd, "SEEK_END", SEEK_END, 0, nbytes);

	close(fd);
	unlink(path);
	printf("seek-checks %d\nseek-failures %d\n", checks, fails);
	return fails ? 1 : 0;
}
