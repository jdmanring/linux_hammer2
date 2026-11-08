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
 *     hammer2-seekprobe race <path>           a truncate against a held
 *                                             seek, see race()
 *     hammer2-seekprobe time <path> <kind> <n>  n timed seeks, see
 *                                             timing()
 *     hammer2-seekprobe contend <path> <n>    n timed writes alone and
 *                                             beside a SEEK_HOLE loop,
 *                                             see contend(); contendgap
 *                                             beside SEEK_DATA across a
 *                                             hole into the data;
 *                                             contendon <path> <n> <MiB>
 *                                             on a file the caller made,
 *                                             its first hole at MiB;
 *                                             contendeio the same with
 *                                             the block at MiB one the
 *                                             masters disagree on, each
 *                                             SEEK_HOLE failing EIO
 *     hammer2-seekprobe fill <path> <MiB>     contend's dense file, kept
 *     hammer2-seekprobe corrupt <path>        a file whose data block
 *                                             fails its check: both
 *                                             seeks at every block
 *                                             answer from block
 *                                             references, the read EIO
 *     hammer2-seekprobe layout <path>         a synced file of data
 *                                             runs and holes across the
 *                                             map's tree-read edge, see
 *                                             layout()
 *     hammer2-seekprobe dump <path>           both seeks from every block
 *                                             and half block, then the
 *                                             FIEMAP extents, one line
 *                                             each, for comparing two
 *                                             readers of the same file
 *     hammer2-seekprobe cold <path> [MiB]     the dense file made, or one
 *                                             SEEK_HOLE timed on it after
 *                                             a cold mount, see cold()
 *     hammer2-seekprobe refuse <path>         a file whose blockref tree
 *                                             the module must refuse:
 *                                             both seeks at 0 and FIEMAP
 *                                             fail EIO, see refuse()
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
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <linux/fiemap.h>
#include <linux/fs.h>

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

static long
now_ns(void)
{
	struct timespec ts;

	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (ts.tv_sec * 1000000000L + ts.tv_nsec);
}

/*
 * A truncate against a held seek.  Blocks 0 and 1 data, 2 a hole, 3 data,
 * synced.  The module's seek_hold_ms (a HAMMER2_LOCKDEBUG build) holds the
 * SEEK_HOLE at 0 after it reads i_size; a child truncates the file to half
 * a block 50 ms in.  A seek that holds the inode lock keeps the truncate
 * out until it returns, and answers the file as it was, the hole at block
 * 2; one that does not lets the truncate land inside it.  The line says
 * which, with both return times from the seek's start, the size the file
 * has after both, and when the truncate began.
 */
static int
race(const char *path)
{
	volatile long *tt, *tb;
	char *buf = malloc(BSIZE);
	long t0, t1;
	off_t got;
	pid_t pid;
	int fd, st;

	tt = mmap(NULL, 2 * sizeof(*tt), PROT_READ | PROT_WRITE,
	    MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	tb = tt + 1;
	if (buf == NULL || tt == MAP_FAILED ||
	    (fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644)) < 0) {
		printf("seekm-fail race: the file could not be built\n");
		return (1);
	}
	fill(buf, 0);
	if (pwrite(fd, buf, BSIZE, 0) != BSIZE ||
	    pwrite(fd, buf, BSIZE, BSIZE) != BSIZE ||
	    pwrite(fd, buf, BSIZE, 3 * BSIZE) != BSIZE || fsync(fd) != 0) {
		printf("seekm-fail race: the file could not be built\n");
		return (1);
	}
	*tt = *tb = 0;
	t0 = now_ns();
	if ((pid = fork()) == 0) {
		int fd2 = open(path, O_RDWR);

		usleep(50000);
		*tb = now_ns();
		if (fd2 < 0 || ftruncate(fd2, BSIZE / 2) != 0)
			_exit(1);
		*tt = now_ns();
		_exit(0);
	}
	got = lseek(fd, 0, SEEK_HOLE);
	t1 = now_ns();
	waitpid(pid, &st, 0);
	if (!WIFEXITED(st) || WEXITSTATUS(st) != 0 || *tt == 0) {
		printf("seekm-fail race: the truncate failed\n");
		return (1);
	}
	/*
	 * "after" means the truncate began inside the seek and returned
	 * after it, so something held it.  One that began in the second half
	 * of the seek is "late": an unlocked seek about to return could
	 * still be passed by it, so it shows nothing either way.
	 */
	printf("seekm-race answer %ld seek-ms %ld truncate-ms %ld truncate %s "
	    "size-after %ld truncate-began-ms %ld\n", (long)got,
	    (t1 - t0) / 1000000, (*tt - t0) / 1000000,
	    *tb > t1 - (t1 - t0) / 2 ? "late" : *tt < t1 ? "inside" : "after",
	    (long)lseek(fd, 0, SEEK_END), (*tb - t0) / 1000000);
	close(fd);
	free(buf);
	return (0);
}

/*
 * A writeback against a held seek.  Four blocks; for "hole" block 0 is
 * synced data and block 1 written and not synced, for "data" block 2 is
 * synced and block 1 written and not synced, the rest holes.  The module's
 * seek_tag_hold_ms (a HAMMER2_LOCKDEBUG build) holds the seek between its
 * page cache tag read and its tree read; a child writes the file back with
 * sync_file_range() 50 ms in, so block 1 moves from a tagged folio into
 * the tree inside the hold.  SEEK_HOLE at 0 must answer block 2 and
 * SEEK_DATA at 0 block 1, either way: a seek that read the tree first, or
 * accepted a hole the tags cleared without reading the tree again, calls
 * block 1 a hole.  The line says whether the writeback returned inside the
 * seek, which is the only case that tests anything.
 *
 * "map" asks FIEMAP of the "data" file instead, held the same way between
 * its tag read and its tree read: block 1 must be in some extent, as
 * DELALLOC or as written, and a map that read the tags after the tree
 * reports it as neither.  The answer printed is 65536 when it is mapped,
 * -1 when it is not and -2 when the map failed, with its errno.
 *
 * A trailing count of milliseconds delays the call by that much after the
 * fork, so it can land inside the writeback rather than before it: on two
 * MASTERs with the module's xop_gap_ms holding the write between its
 * elements, block 1 is then on the first master and not the second when
 * the tree is read (script/cluster-quorum.sh).  seek-ms runs from before
 * the fork, so it includes the delay.
 */
static long
mapped(int fd, long off)
{
	struct {
		struct fiemap fm;
		struct fiemap_extent fe[16];
	} m;
	unsigned int i;

	memset(&m, 0, sizeof(m));
	m.fm.fm_length = FIEMAP_MAX_OFFSET;
	m.fm.fm_extent_count = 16;
	if (ioctl(fd, FS_IOC_FIEMAP, &m.fm) != 0)
		return (-2);
	for (i = 0; i < m.fm.fm_mapped_extents && i < 16; i++)
		if ((long)m.fe[i].fe_logical <= off &&
		    off < (long)(m.fe[i].fe_logical + m.fe[i].fe_length))
			return (off);
	return (-1);
}

static int
wbrace(const char *path, const char *kind, long delay)
{
	volatile long *tt;
	char *buf = malloc(BSIZE);
	int hole = strcmp(kind, "hole") == 0, map = strcmp(kind, "map") == 0;
	int fd, st, e;
	long t0, t1, want = hole ? 2 * BSIZE : BSIZE;
	off_t got;
	pid_t pid;

	if (!hole && !map && strcmp(kind, "data") != 0)
		return (2);
	tt = mmap(NULL, sizeof(*tt), PROT_READ | PROT_WRITE,
	    MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	if (buf == NULL || tt == MAP_FAILED ||
	    (fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644)) < 0)
		goto fail;
	fill(buf, 0);
	if (ftruncate(fd, 4 * BSIZE) != 0 ||
	    pwrite(fd, buf, BSIZE, hole ? 0 : 2 * BSIZE) != BSIZE ||
	    fsync(fd) != 0 || pwrite(fd, buf, BSIZE, BSIZE) != BSIZE)
		goto fail;
	*tt = 0;
	t0 = now_ns();
	if ((pid = fork()) == 0) {
		usleep(50000);
		if (sync_file_range(fd, 0, 0, SYNC_FILE_RANGE_WAIT_BEFORE |
		    SYNC_FILE_RANGE_WRITE | SYNC_FILE_RANGE_WAIT_AFTER) != 0)
			_exit(1);
		*tt = now_ns();
		_exit(0);
	}
	if (delay > 0)
		usleep(delay * 1000);
	errno = 0;
	got = map ? mapped(fd, BSIZE) : lseek(fd, 0, hole ? SEEK_HOLE : SEEK_DATA);
	e = errno;
	t1 = now_ns();
	waitpid(pid, &st, 0);
	if (!WIFEXITED(st) || WEXITSTATUS(st) != 0 || *tt == 0) {
		printf("seekm-fail wbrace %s: the writeback failed\n", kind);
		return (1);
	}
	printf("seekm-wbrace %s answer %ld want %ld seek-ms %ld sync-ms %ld "
	    "sync %s errno %d\n", kind, (long)got, want, (t1 - t0) / 1000000,
	    (*tt - t0) / 1000000, *tt < t1 ? "inside" : "after", e);
	if (got != (off_t)want) {
		printf("seekm-fail wbrace %s: answered %ld, want %ld\n", kind,
		    (long)got, want);
		fails++;
	}
	close(fd);
	free(buf);
	return (fails ? 1 : 0);
fail:
	printf("seekm-fail wbrace %s: the file could not be built\n", kind);
	return (1);
}

static int
cmp_long(const void *a, const void *b)
{
	long x = *(const long *)a, y = *(const long *)b;

	return (x < y ? -1 : x > y);
}

/*
 * The cost of a seek, n times on one file made once and read once
 * beforehand, so the first timed seek finds the tree in memory.
 *   sparse  1 GiB, all hole but the last block, SEEK_DATA at 0
 *   hole    the dense file's size, all hole but the first and last
 *           blocks, SEEK_DATA from inside the hole, so the seek crosses
 *           the hole the size gives and only one block of data
 *   dense   64 MiB of data, or the MiB given, SEEK_DATA and SEEK_HOLE in
 *           turn at offsets from a fixed sequence; the sequence is 24 bits
 *           wide, so every offset lies in the first 16 MiB and each
 *           SEEK_HOLE crosses nearly the whole file
 *   dirty   the dense file, one byte written at a block from that
 *           sequence before each SEEK_DATA at 0, so each seek writes back
 *   deep    the dense file, SEEK_DATA at a block in its last sixteenth,
 *           so the seek starts above every indirect block it passes
 * Every answer is checked; one line per seek, then the median, which for
 * dense is taken for each whence apart (dense-data, dense-hole): one
 * median over both is the fastest SEEK_HOLE, since every SEEK_DATA on a
 * dense file answers at once.
 */
static long dense = 64L << 20;	/* the dense file's size, time and contend */

static int
timing(const char *path, const char *kind, long n)
{
	unsigned int seed = 4242;
	long *ns, i, size;
	char *buf = malloc(BSIZE);
	int fd, k;

	k = strcmp(kind, "sparse") == 0 ? 0 : strcmp(kind, "dense") == 0 ? 1 :
	    strcmp(kind, "dirty") == 0 ? 2 : strcmp(kind, "hole") == 0 ? 3 :
	    strcmp(kind, "deep") == 0 ? 4 : -1;
	if (k < 0 || n < 1 || buf == NULL || (ns = calloc(n, sizeof(*ns))) ==
	    NULL)
		return (2);
	size = k == 0 ? (1L << 30) : dense;
	if ((fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644)) < 0)
		return (2);
	fill(buf, 1);
	if (k == 0 || k == 3) {
		if (size < 3 * BSIZE || ftruncate(fd, size) != 0 ||
		    pwrite(fd, buf, BSIZE, size - BSIZE) != BSIZE ||
		    (k == 3 && pwrite(fd, buf, BSIZE, 0) != BSIZE))
			return (2);
	} else {
		for (i = 0; i < size; i += BSIZE)
			if (pwrite(fd, buf, BSIZE, i) != BSIZE)
				return (2);
	}
	if (fsync(fd) != 0)
		return (2);
	lseek(fd, 0, SEEK_DATA);
	lseek(fd, 0, SEEK_HOLE);
	for (i = 0; i < n; i++) {
		long off, t0, want;
		off_t got;
		int whence = SEEK_DATA;

		seed = seed * 1103515245u + 12345u;
		off = (long)(seed >> 8) % size;
		if (k == 0) {
			off = 0;
			want = size - BSIZE;
		} else if (k == 3) {
			off = BSIZE;
			want = size - BSIZE;
		} else if (k == 1) {
			whence = (i & 1) ? SEEK_HOLE : SEEK_DATA;
			want = whence == SEEK_HOLE ? size : off;
		} else if (k == 4) {
			off = size - size / 16 +
			    ((long)(seed >> 8) % (size / 16 / BSIZE)) * BSIZE;
			want = off;
		} else {
			if (pwrite(fd, "D", 1, off & ~(BSIZE - 1)) != 1)
				return (2);
			off = 0;
			want = 0;
		}
		t0 = now_ns();
		got = lseek(fd, off, whence);
		ns[i] = now_ns() - t0;
		if (got != (off_t)want) {
			printf("seekm-fail time %s %ld: got %ld, want %ld\n", kind,
			    i, (long)got, want);
			fails++;
		}
		printf("seekm-time %s %ld %ld\n", kind, i, ns[i]);
	}
	if (k == 1 && n >= 2) {
		/* even seeks were SEEK_DATA, odd ones SEEK_HOLE */
		long *w = calloc(n, sizeof(*w)), nd = (n + 1) / 2, nh = n / 2;

		if (w == NULL)
			return (2);
		for (i = 0; i < n; i++)
			w[(i & 1) ? nd + i / 2 : i / 2] = ns[i];
		qsort(w, nd, sizeof(*w), cmp_long);
		qsort(w + nd, nh, sizeof(*w), cmp_long);
		printf("seekm-time dense-data median-ns %ld n %ld\n", w[nd / 2], nd);
		printf("seekm-time dense-hole median-ns %ld n %ld\n",
		    w[nd + nh / 2], nh);
		free(w);
	}
	qsort(ns, n, sizeof(*ns), cmp_long);
	printf("seekm-time %s median-ns %ld n %ld\n", kind, ns[n / 2], n);
	close(fd);
	unlink(path);
	free(ns);
	free(buf);
	return (fails ? 1 : 0);
}

/*
 * A seek's cost with nothing in memory.  Given a size in MiB, the dense
 * file is made as timing() makes it and synced.  Without one, a single
 * SEEK_HOLE at 0 is timed on that file, which the caller has mounted
 * after dropping the guest's caches and the host's copy of the image, so
 * every indirect block the walk reads comes off the disk.
 */
static int
cold(const char *path, long mib)
{
	char *buf = malloc(BSIZE);
	struct stat st;
	long i, t0, ns, size = mib << 20;
	off_t got;
	int fd;

	if (buf == NULL)
		return (2);
	if (mib > 0) {
		if ((fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644)) < 0)
			return (2);
		fill(buf, 1);
		for (i = 0; i < size; i += BSIZE)
			if (pwrite(fd, buf, BSIZE, i) != BSIZE)
				return (2);
		if (fsync(fd) != 0 || close(fd) != 0)
			return (2);
		printf("seekm-ok   cold: %ld MiB made and synced\n", mib);
		free(buf);
		return (0);
	}
	if ((fd = open(path, O_RDONLY)) < 0 || fstat(fd, &st) != 0)
		return (2);
	t0 = now_ns();
	got = lseek(fd, 0, SEEK_HOLE);
	ns = now_ns() - t0;
	if (got != st.st_size) {
		printf("seekm-fail cold: SEEK_HOLE 0 got %ld, want %ld\n",
		    (long)got, (long)st.st_size);
		fails++;
	}
	printf("seekm-cold ns %ld size %ld\n", ns, (long)st.st_size);
	close(fd);
	free(buf);
	return (fails ? 1 : 0);
}

/*
 * What a seek costs a writer.  A 64 MiB dense file, or the MiB given,
 * synced.  n one-block pwrite()s at blocks from a fixed sequence are timed
 * twice: alone, then
 * with a child looping SEEK_HOLE at 0 on its own descriptor.  A seek
 * holding i_rwsem shared keeps write_iter's exclusive i_rwsem out for the
 * length of the seek, so the contended worst write approaches one seek;
 * a seek holding nothing leaves it near the alone figure.  The child
 * loops until the last write has returned, so the phases overlap when its
 * first seek began before the first write did; a run where it did not
 * fails rather than reads.  It counts the seeks it began, not the ones it
 * finished: one seek of seconds can outlast every write.
 *
 * With gap set (contendgap) the data begins after a hole of the same size
 * and the child loops SEEK_DATA at 0, so each seek crosses the hole into
 * the data and the write reads what that crossing holds the lock for.
 * SEEK_DATA bounds its tree read at the first dirty block, so the writes
 * go to the data's upper half: a write near the data's start would
 * shorten the read being timed.
 */
static int gap;
/*
 * With reuse set (contendon) the file is the caller's, whose first hole the
 * caller placed at the dense size: it is neither made nor synced, SEEK_HOLE
 * from 0 is timed alone first and its answer printed, and the writes stay
 * below that hole, as the loop's check requires.
 */
static int reuse;
/*
 * With want_eio set (contendeio, a contendon) the caller's block at the
 * dense size is one the masters disagree on, so every SEEK_HOLE from 0
 * must fail with EIO rather than answer.
 */
static int want_eio;

static int
hole_ok(long a)
{
	return (want_eio ? a == -1 && errno == EIO : a == dense);
}

static int
contend(const char *path, long n)
{
	volatile long *stop, *seeks, *first;
	unsigned int seed = 777;
	long *ns, i, ph, w0, base = gap ? dense : 0;
	char *buf = malloc(BSIZE);
	pid_t pid = -1;
	int fd, st;

	stop = mmap(NULL, 3 * sizeof(*stop), PROT_READ | PROT_WRITE,
	    MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	seeks = stop + 1;
	first = stop + 2;
	if (n < 1 || buf == NULL || stop == MAP_FAILED ||
	    (ns = calloc(n, sizeof(*ns))) == NULL ||
	    (fd = open(path, reuse ? O_RDWR : O_CREAT | O_TRUNC | O_RDWR,
	    0644)) < 0)
		return (2);
	fill(buf, 1);
	if (reuse) {
		long hs[10], a = -1;
		int e = 0;

		for (i = 0; i < 10; i++) {
			long t0 = now_ns();

			errno = 0;
			a = lseek(fd, 0, SEEK_HOLE);
			e = errno;
			hs[i] = now_ns() - t0;
			if (!hole_ok(a))
				break;
		}
		if (i < 10) {
			printf("seekm-fail contend: SEEK_HOLE from 0 answered %ld "
			    "errno %d, not %s\n", a, e, want_eio ? "EIO" : "the hole");
			return (1);
		}
		qsort(hs, 10, sizeof(*hs), cmp_long);
		printf("seekm-contend hole median-ns %ld n 10 answer %ld errno %d\n",
		    hs[5], a, e);
	} else {
		for (i = 0; i < dense; i += BSIZE)
			if (pwrite(fd, buf, BSIZE, base + i) != BSIZE)
				return (2);
		if (fsync(fd) != 0)
			return (2);
	}
	for (ph = 0; ph < 2; ph++) {
		*stop = 0;
		*seeks = 0;
		*first = 0;
		if (ph == 1 && (pid = fork()) == 0) {
			int sfd = open(path, O_RDONLY);

			if (sfd < 0)
				_exit(1);
			while (!__atomic_load_n(stop, __ATOMIC_ACQUIRE)) {
				if (*first == 0)
					__atomic_store_n(first, now_ns(),
					    __ATOMIC_RELEASE);
				__atomic_add_fetch(seeks, 1, __ATOMIC_RELEASE);
				if (gap ? lseek(sfd, 0, SEEK_DATA) != base :
				    !hole_ok(lseek(sfd, 0, SEEK_HOLE)))
					_exit(1);
			}
			_exit(0);
		}
		if (ph == 1)
			usleep(20000);	/* the first seek under way */
		w0 = now_ns();
		for (i = 0; i < n; i++) {
			long t0, off;

			seed = seed * 1103515245u + 12345u;
			off = ((long)(seed >> 8) % (dense / BSIZE)) * BSIZE;
			if (gap)
				off = dense / 2 + off / 2 / BSIZE * BSIZE;
			t0 = now_ns();
			if (pwrite(fd, buf, BSIZE, base + off) != BSIZE)
				return (2);
			ns[i] = now_ns() - t0;
		}
		qsort(ns, n, sizeof(*ns), cmp_long);
		if (ph == 0)
			printf("seekm-contend alone median-ns %ld max-ns %ld n %ld\n",
			    ns[n / 2], ns[n - 1], n);
		else {
			long s = __atomic_load_n(seeks, __ATOMIC_ACQUIRE);
			long f = __atomic_load_n(first, __ATOMIC_ACQUIRE);

			__atomic_store_n(stop, 1, __ATOMIC_RELEASE);
			waitpid(pid, &st, 0);
			printf("seekm-contend seeking median-ns %ld max-ns %ld n %ld "
			    "seeks %ld\n", ns[n / 2], ns[n - 1], n, s);
			if (!WIFEXITED(st) || WEXITSTATUS(st) != 0) {
				printf("seekm-fail contend: a seek answered wrongly\n");
				fails++;
			} else if (s < 1 || f == 0 || f >= w0) {
				printf("seekm-fail contend: no seek began before the "
				    "writes, so nothing contended\n");
				fails++;
			}
		}
	}
	close(fd);
	if (!reuse)
		unlink(path);
	free(ns);
	free(buf);
	return (fails ? 1 : 0);
}

/*
 * The dense file contend() makes, the same blocks of the same pattern,
 * written and synced and left for the caller: contendon's file before the
 * caller places its hole.
 */
static int
fillfile(const char *path)
{
	char *buf = malloc(BSIZE);
	long i;
	int fd;

	if (buf == NULL ||
	    (fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644)) < 0)
		return (2);
	fill(buf, 1);
	for (i = 0; i < dense; i += BSIZE)
		if (pwrite(fd, buf, BSIZE, i) != BSIZE)
			return (2);
	if (fsync(fd) != 0 || close(fd) != 0)
		return (2);
	free(buf);
	printf("seekm-ok   fill: %ld MiB made and synced\n", dense >> 20);
	return (0);
}

/*
 * A file whose data block was altered on media, one the fixtures name
 * `# corrupt`.  The seeks ask for block references and no data, so no
 * check runs and they answer as for any dense file.  Both are asked at
 * every block, so the altered one is reached wherever it sits: SEEK_DATA
 * at a block answers that block, SEEK_HOLE answers the size.  Asked at 0
 * alone, SEEK_DATA answers from the first block and never reaches a later
 * one.  The read loads the blocks and must fail EIO, not some other errno
 * and not the bytes.
 */
static int
corrupt(const char *path)
{
	char buf[BSIZE];
	struct stat st;
	off_t got;
	long off, nb = 0;
	ssize_t n;
	int fd;

	if ((fd = open(path, O_RDONLY)) < 0 || fstat(fd, &st) != 0 ||
	    st.st_size < 1)
		return (2);
	for (off = 0; off < st.st_size; off += BSIZE, nb++) {
		if ((got = lseek(fd, off, SEEK_DATA)) != (off_t)off) {
			printf("seekm-fail corrupt, SEEK_DATA %ld: got %ld\n",
			    off, (long)got);
			fails++;
		}
		if ((got = lseek(fd, off, SEEK_HOLE)) != st.st_size) {
			printf("seekm-fail corrupt, SEEK_HOLE %ld: got %ld, "
			    "want %ld\n", off, (long)got, (long)st.st_size);
			fails++;
		}
	}
	if (fails == 0)
		printf("seekm-ok   corrupt, SEEK_DATA and SEEK_HOLE at each of "
		    "%ld block(s)\n", nb);
	if (lseek(fd, 0, SEEK_SET) != 0)
		return (2);
	while ((n = read(fd, buf, sizeof(buf))) > 0)
		;
	if (n == 0 || errno != EIO) {
		printf("seekm-fail corrupt, read: %s\n", n == 0 ?
		    "read to the end" : strerror(errno));
		fails++;
	} else
		printf("seekm-ok   corrupt, read: EIO\n");
	close(fd);
	return (fails ? 1 : 0);
}

/*
 * A file for comparing the blockref walk with hammer2_xop_scanall(), read
 * twice by dump with the module's seek_scanall parameter off and on: 1040
 * blocks of data, each its own bytes so none dedups, which crosses the
 * map's tree-read edge at block 1024; a 20-block hole; one block; one of
 * hole; eight blocks; and a size half a block past a 30-block tail hole.
 * Synced, so neither reader meets a tag.
 */
#define LAYOUT_BLOCKS	1100

static int
layout(const char *path)
{
	char *buf = malloc(BSIZE);
	long b;
	int fd;

	if (buf == NULL ||
	    (fd = open(path, O_CREAT | O_TRUNC | O_WRONLY, 0644)) < 0)
		return (2);
	fill(buf, 1);
	for (b = 0; b < LAYOUT_BLOCKS - 30; b++) {
		if ((b >= 1040 && b < 1060) || b == 1061)
			continue;
		memcpy(buf, &b, sizeof(b));
		if (pwrite(fd, buf, BSIZE, b * BSIZE) != BSIZE)
			return (2);
	}
	if (ftruncate(fd, LAYOUT_BLOCKS * BSIZE + BSIZE / 2) != 0 ||
	    fsync(fd) != 0 || close(fd) != 0)
		return (2);
	free(buf);
	printf("seekm-ok   layout: %d blocks made and synced\n", LAYOUT_BLOCKS);
	return (0);
}

/*
 * A file whose blockref tree the module must refuse, with the debug
 * build's seek_depth_max at 0 or with an indirect block altered on media:
 * SEEK_DATA and SEEK_HOLE at 0 and FIEMAP from 0 each fail EIO, the errno
 * a block that failed its check is to every Linux filesystem.  An answer
 * or any other errno fails, EDOM among them, which is what the core's
 * error mapping gives a check failure before the VFS boundary converts it.
 */
static int
refuse(const char *path)
{
	static const int whence[] = { SEEK_DATA, SEEK_HOLE };
	static const char *const name[] = { "SEEK_DATA", "SEEK_HOLE" };
	struct fiemap fm;
	off_t got;
	int fd, i, r, e;

	if ((fd = open(path, O_RDONLY)) < 0)
		return (2);
	for (i = 0; i < 2; i++) {
		got = lseek(fd, 0, whence[i]);
		e = errno;
		if (got == -1 && e == EIO) {
			printf("seekm-ok   refuse, %s: EIO\n", name[i]);
		} else {
			printf("seekm-fail refuse, %s: %s %ld\n", name[i],
			    got == -1 ? strerror(e) : "answered", (long)got);
			fails++;
		}
	}
	memset(&fm, 0, sizeof(fm));
	fm.fm_length = FIEMAP_MAX_OFFSET;
	r = ioctl(fd, FS_IOC_FIEMAP, &fm);
	e = errno;
	if (r == -1 && e == EIO) {
		printf("seekm-ok   refuse, FIEMAP: EIO\n");
	} else {
		printf("seekm-fail refuse, FIEMAP: %s\n",
		    r == -1 ? strerror(e) : "answered");
		fails++;
	}
	close(fd);
	return (fails ? 1 : 0);
}

static int
dump(const char *path)
{
	struct fiemap *fm;
	unsigned int i, max = 4096;
	long off, size;
	int fd;

	if ((fd = open(path, O_RDONLY)) < 0 ||
	    (size = (long)lseek(fd, 0, SEEK_END)) < 0)
		return (2);
	for (off = 0; off < size; off += BSIZE / 2)
		printf("seekm-dump %ld data %ld hole %ld\n", off,
		    (long)lseek(fd, off, SEEK_DATA),
		    (long)lseek(fd, off, SEEK_HOLE));
	fm = calloc(1, sizeof(*fm) + max * sizeof(struct fiemap_extent));
	if (fm == NULL)
		return (2);
	fm->fm_length = FIEMAP_MAX_OFFSET;
	fm->fm_extent_count = max;
	if (ioctl(fd, FS_IOC_FIEMAP, fm) != 0) {
		printf("seekm-fail dump: FIEMAP errno %d\n", errno);
		return (1);
	}
	for (i = 0; i < fm->fm_mapped_extents; i++)
		printf("seekm-dump extent %llu %llu %llu %x\n",
		    (unsigned long long)fm->fm_extents[i].fe_logical,
		    (unsigned long long)fm->fm_extents[i].fe_physical,
		    (unsigned long long)fm->fm_extents[i].fe_length,
		    fm->fm_extents[i].fe_flags);
	printf("seekm-dump extents %u\n", fm->fm_mapped_extents);
	free(fm);
	close(fd);
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
	if (argc == 3 && strcmp(argv[1], "corrupt") == 0)
		return (corrupt(argv[2]));
	if (argc == 3 && strcmp(argv[1], "layout") == 0)
		return (layout(argv[2]));
	if (argc == 3 && strcmp(argv[1], "dump") == 0)
		return (dump(argv[2]));
	if (argc == 3 && strcmp(argv[1], "refuse") == 0)
		return (refuse(argv[2]));
	if (argc == 3 && strcmp(argv[1], "cold") == 0)
		return (cold(argv[2], 0));
	if (argc == 4 && strcmp(argv[1], "cold") == 0 &&
	    strtol(argv[3], NULL, 10) > 0)
		return (cold(argv[2], strtol(argv[3], NULL, 10)));
	if (argc == 3 && strcmp(argv[1], "race") == 0)
		return (race(argv[2]));
	if (argc == 4 && strcmp(argv[1], "wbrace") == 0)
		return (wbrace(argv[2], argv[3], 0));
	if (argc == 5 && strcmp(argv[1], "wbrace") == 0)
		return (wbrace(argv[2], argv[3], strtol(argv[4], NULL, 10)));
	/* A trailing count of MiB sizes the dense file, a block multiple. */
	if (argc >= 2 && strcmp(argv[1], "contendgap") == 0) {
		gap = 1;
		argv[1] = "contend";
	}
	if (argc == 5 && (strcmp(argv[1], "contendon") == 0 ||
	    strcmp(argv[1], "contendeio") == 0)) {
		want_eio = strcmp(argv[1], "contendeio") == 0;
		reuse = 1;
		argv[1] = "contend";
	}
	if (argc == 4 && strcmp(argv[1], "fill") == 0) {
		dense = strtol(argv[3], NULL, 10) << 20;
		return (dense < BSIZE ? 2 : fillfile(argv[2]));
	}
	if ((argc == 5 && strcmp(argv[1], "contend") == 0) ||
	    (argc == 6 && strcmp(argv[1], "time") == 0)) {
		dense = strtol(argv[argc - 1], NULL, 10) << 20;
		if (dense < BSIZE)
			return (2);
		argc--;
	}
	if (argc == 4 && strcmp(argv[1], "contend") == 0)
		return (contend(argv[2], strtol(argv[3], NULL, 10)));
	if (argc == 5 && strcmp(argv[1], "time") == 0)
		return (timing(argv[2], argv[3], strtol(argv[4], NULL, 10)));
	fprintf(stderr, "usage: %s make <path> [rand] | dedup <path> <n> | "
	    "check|agree <path> <what> | race <path> | wbrace <path> data|hole|map [ms] | corrupt|refuse <path> | layout|dump <path> | "
	    "time <path> sparse|dense|dirty|hole|deep <n> [MiB] | cold <path> [MiB] | contend|contendgap <path> <n> [MiB] | contendon|contendeio <path> <n> <MiB> | fill <path> <MiB>\n",
	    argv[0]);
	return (2);
}
