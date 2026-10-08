/* Mixed load on a HAMMER2 volume: mapped writers, write-then-fsync
 * writers, fdatasync batchers and readers, all on one set of files at
 * once, for a fixed time.
 *
 * Every other exerciser here asks one question on a quiet volume.  This
 * one is the load P2 names, mixed reads and writes with mmap and fsync
 * storms, and it has to say whether anything came back wrong under it,
 * so every write is checkable afterwards and during.
 *
 * THE CELL.  Each file is CELLS cells of 4 KiB.  A cell holds a header,
 * {magic, file, cell, writer, seq, crc}, and a payload derived from the
 * header, so a reader can tell a cell that is whole and belongs where it
 * is from one that is torn, misplaced or invented.  A writer takes the
 * cell's lock for one write and bumps its sequence; a sequence is per cell
 * and never goes backwards, so a reader that saw seq n in a cell and later
 * reads a smaller one has read a lost write.
 *
 * THE LOCK.  Readers and writers both take the cell's lock, in shared
 * memory.  Without it two writers interleave inside one cell and a reader
 * catches a copy half done, and tmpfs fails exactly so: no filesystem
 * makes a 4 KiB write atomic against a concurrent one.  What is checked is
 * therefore coherence and durability under load, not atomicity.
 *
 * WHAT FAILS.  A cell whose crc does not cover it, which is a torn or
 * corrupted write (an all-zero cell is a cell never written and passes).
 * A cell whose header names another file or cell, which is data in the
 * wrong place.  A sequence going backwards on one reader, which is a
 * write that was seen and then lost.  After the run every cell is read
 * again and must hold the last sequence any writer gave it: an older one
 * is a write the filesystem dropped.  The driver repeats that after a
 * remount and a cache drop with --verify.
 *
 * A FAKE PASS is a run where the roles blocked or never ran.  Each role
 * counts its operations and the run fails if any role completed none.
 * A crc that cannot fail is the other: --selftest corrupts a cell and a
 * header and requires both refused.
 *
 *   hammer2-storm <dir> <seconds> [files]
 *   hammer2-storm --verify <dir> [files]
 *   hammer2-storm --selftest
 *
 * The run writes the last sequence of every cell to <dir>/storm.seq after
 * an fsync of each file, and --verify checks the files against it, which
 * is what the driver runs after a remount with the cache dropped.
 *
 * Output, prefixed so the driver does no quoting:
 *   storm-ok <what>, storm-fail <what>, storm-ops <role> <n>,
 *   storm-checks <n>, storm-failures <n>
 */
#define _GNU_SOURCE
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <errno.h>
#include <sched.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#define CELL	4096
#define CELLS	256		/* 1 MiB per file, sixteen 64 KiB blocks */
#define MAXF	16
#define MAGIC	0x48325354u	/* "H2ST" */

enum { R_MAP, R_FSYNC, R_FDATA, R_READ, R_MAPREAD, NROLES };
static const char *rname[NROLES] = {
	"mapwrite", "write-fsync", "fdatasync-batch", "read", "mapread" };

struct hdr {
	uint32_t magic, file, cell, writer;
	uint64_t seq;
	uint32_t crc, pad;
};

/* Shared between the processes: per-cell sequence counters, the last
 * durable sequence, the op counts and the failure count. */
struct shared {
	uint64_t next[MAXF][CELLS];	/* last sequence written */
	uint32_t lock[MAXF][CELLS];
	long ops[NROLES];
	long fails;
	char first[256];
};

static struct shared *sh;
static char dir[4096];
static int nfiles = 4;

static uint32_t
crc32(const unsigned char *p, size_t n)
{
	uint32_t c = 0xffffffffu;
	size_t i;
	int k;

	for (i = 0; i < n; i++) {
		c ^= p[i];
		for (k = 0; k < 8; k++)
			c = (c >> 1) ^ (0xedb88320u & -(c & 1));
	}
	return (~c);
}

static void
fill(unsigned char *b, uint32_t file, uint32_t cell, uint32_t w, uint64_t seq)
{
	struct hdr h = { MAGIC, file, cell, w, seq, 0, 0 };
	uint64_t x = seq * 0x9e3779b97f4a7c15ull ^ ((uint64_t)file << 32 | cell);
	size_t i;

	for (i = sizeof(h); i < CELL; i++) {
		x ^= x << 13; x ^= x >> 7; x ^= x << 17;
		b[i] = (unsigned char)x;
	}
	memcpy(b, &h, sizeof(h));
	h.crc = crc32(b + sizeof(h), CELL - sizeof(h)) ^ crc32(b, 24);
	memcpy(b, &h, sizeof(h));
}

/* 0 good, 1 never written (all zero), -1 bad. On good, *seq is set. */
static int
check(const unsigned char *b, uint32_t file, uint32_t cell, uint64_t *seq)
{
	struct hdr h;
	size_t i;

	memcpy(&h, b, sizeof(h));
	if (h.magic != MAGIC) {
		for (i = 0; i < CELL; i++)
			if (b[i])
				return (-1);
		return (1);
	}
	if (h.file != file || h.cell != cell)
		return (-1);
	if ((crc32(b + sizeof(h), CELL - sizeof(h)) ^ crc32(b, 24)) != h.crc)
		return (-1);
	*seq = h.seq;
	return (0);
}

static void
fail(const char *what, int f, int c)
{
	if (__atomic_fetch_add(&sh->fails, 1, __ATOMIC_SEQ_CST) == 0)
		snprintf(sh->first, sizeof(sh->first), "%s at file %d cell %d",
		    what, f, c);
}

static void
lock(int f, int c)
{
	while (__atomic_exchange_n(&sh->lock[f][c], 1, __ATOMIC_ACQUIRE))
		sched_yield();
}

static void
unlock(int f, int c)
{
	__atomic_store_n(&sh->lock[f][c], 0, __ATOMIC_RELEASE);
}

static void
path(char *p, size_t n, int f)
{
	snprintf(p, n, "%s/storm.%d", dir, f);
}

static unsigned
rnd(unsigned *s)
{
	*s = *s * 1103515245u + 12345u;
	return (*s >> 8);
}

static void
worker(int role, int id, time_t end)
{
	unsigned char b[CELL];
	uint64_t seen[MAXF][CELLS];
	unsigned s = 77u * (unsigned)(id + 1) + (unsigned)role;
	char p[4200];
	long ops = 0;

	memset(seen, 0, sizeof(seen));
	while (time(NULL) < end) {
		int f = rnd(&s) % nfiles, c = rnd(&s) % CELLS, fd, k;
		uint64_t q;

		path(p, sizeof(p), f);
		fd = open(p, O_RDWR);
		if (fd < 0) {
			fail("open failed", f, c);
			break;
		}
		switch (role) {
		case R_MAP: {
			unsigned char *m = mmap(NULL, (size_t)CELLS * CELL,
			    PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);

			if (m == MAP_FAILED) {
				fail("mmap failed", f, c);
				break;
			}
			lock(f, c);
			q = ++sh->next[f][c];
			fill(b, f, c, id, q);
			memcpy(m + (size_t)c * CELL, b, CELL);
			unlock(f, c);
			if ((rnd(&s) & 1) &&
			    msync(m, (size_t)CELLS * CELL, MS_SYNC))
				fail("msync failed", f, c);
			munmap(m, (size_t)CELLS * CELL);
			break;
		}
		case R_FSYNC:
			lock(f, c);
			q = ++sh->next[f][c];
			fill(b, f, c, id, q);
			k = pwrite(fd, b, CELL, (off_t)c * CELL) != CELL;
			unlock(f, c);
			if (k)
				fail("pwrite failed", f, c);
			else if (fsync(fd))
				fail("fsync failed", f, c);
			break;
		case R_FDATA:
			for (k = 0; k < 8; k++) {
				int cc = rnd(&s) % CELLS;

				int bad;

				lock(f, cc);
				q = ++sh->next[f][cc];
				fill(b, f, cc, id, q);
				bad = pwrite(fd, b, CELL, (off_t)cc * CELL) != CELL;
				unlock(f, cc);
				if (bad)
					fail("pwrite failed", f, cc);
			}
			if (fdatasync(fd))
				fail("fdatasync failed", f, c);
			break;
		case R_READ:
		case R_MAPREAD: {
			const unsigned char *src = b;
			unsigned char *m = NULL;
			int r;

			if (role == R_MAPREAD) {
				m = mmap(NULL, (size_t)CELLS * CELL, PROT_READ,
				    MAP_SHARED, fd, 0);
				if (m == MAP_FAILED) {
					fail("mmap failed", f, c);
					break;
				}
				src = m + (size_t)c * CELL;
			}
			lock(f, c);
			if (m)
				memcpy(b, src, CELL);
			r = (m || pread(fd, b, CELL, (off_t)c * CELL) == CELL) ?
			    check(b, f, c, &q) : -2;
			unlock(f, c);
			if (r == -2)
				fail("pread short", f, c);
			else if (r < 0)
				fail("a cell read back torn or misplaced", f, c);
			else if (r == 0) {
				if (q < seen[f][c])
					fail("a cell went back in sequence", f,
					    c);
				else
					seen[f][c] = q;
			}
			if (m)
				munmap(m, (size_t)CELLS * CELL);
			break;
		}
		}
		close(fd);
		ops++;
	}
	__atomic_fetch_add(&sh->ops[role], ops, __ATOMIC_SEQ_CST);
}

static int
selftest(void)
{
	unsigned char b[CELL];
	uint64_t q;
	int bad = 0;

	fill(b, 1, 2, 3, 99);
	if (check(b, 1, 2, &q) != 0 || q != 99)
		bad++, printf("storm-fail selftest: a good cell was refused\n");
	b[CELL - 1] ^= 1;
	if (check(b, 1, 2, &q) != -1)
		bad++, printf("storm-fail selftest: a torn payload passed\n");
	fill(b, 1, 2, 3, 99);
	if (check(b, 1, 3, &q) != -1)
		bad++, printf("storm-fail selftest: a misplaced cell passed\n");
	memset(b, 0, CELL);
	if (check(b, 1, 2, &q) != 1)
		bad++, printf("storm-fail selftest: a zero cell was not unwritten\n");
	b[100] = 1;
	if (check(b, 1, 2, &q) != -1)
		bad++, printf("storm-fail selftest: garbage passed as unwritten\n");
	printf("storm-%s selftest: 5 cases, %d failed\n", bad ? "fail" : "ok", bad);
	return (bad != 0);
}

int
main(int argc, char **argv)
{
	int per[NROLES] = { 2, 2, 1, 2, 1 };
	unsigned char b[CELL];
	long checks = 0, failures;
	pid_t pids[64];
	int np = 0, f, c, r, i, st;
	time_t end;
	char p[4200];

	if (argc > 1 && strcmp(argv[1], "--selftest") == 0)
		return (selftest());
	if (argc > 2 && strcmp(argv[1], "--verify") == 0) {
		FILE *m;

		snprintf(dir, sizeof(dir), "%s", argv[2]);
		if (argc > 3)
			nfiles = atoi(argv[3]);
		if (nfiles < 1 || nfiles > MAXF)
			return (2);
		sh = mmap(NULL, sizeof(*sh), PROT_READ | PROT_WRITE,
		    MAP_SHARED | MAP_ANONYMOUS, -1, 0);
		if (sh == MAP_FAILED)
			return (2);
		memset(sh, 0, sizeof(*sh));
		snprintf(p, sizeof(p), "%s/storm.seq", dir);
		m = fopen(p, "r");
		if (m == NULL || fread(sh->next, sizeof(sh->next), 1, m) != 1) {
			fprintf(stderr, "storm-setup no manifest at %s\n", p);
			return (2);
		}
		fclose(m);
		goto verify;
	}
	if (argc < 3) {
		fprintf(stderr, "usage: %s <dir> <seconds> [files]\n", argv[0]);
		return (2);
	}
	snprintf(dir, sizeof(dir), "%s", argv[1]);
	if (argc > 3)
		nfiles = atoi(argv[3]);
	if (nfiles < 1 || nfiles > MAXF)
		return (2);
	sh = mmap(NULL, sizeof(*sh), PROT_READ | PROT_WRITE,
	    MAP_SHARED | MAP_ANONYMOUS, -1, 0);
	if (sh == MAP_FAILED)
		return (2);
	memset(sh, 0, sizeof(*sh));
	for (f = 0; f < nfiles; f++) {
		int fd;

		path(p, sizeof(p), f);
		fd = open(p, O_CREAT | O_TRUNC | O_RDWR, 0644);
		if (fd < 0 || ftruncate(fd, (off_t)CELLS * CELL) != 0) {
			fprintf(stderr, "storm-setup %s: %s\n", p, strerror(errno));
			return (2);
		}
		close(fd);
	}
	end = time(NULL) + atol(argv[2]);
	for (r = 0; r < NROLES; r++)
		for (i = 0; i < per[r]; i++) {
			pid_t pid = fork();

			if (pid == 0) {
				worker(r, np, end);
				_exit(0);
			}
			pids[np++] = pid;
		}
	for (i = 0; i < np; i++)
		if (waitpid(pids[i], &st, 0) < 0 || !WIFEXITED(st) ||
		    WEXITSTATUS(st) != 0)
			fail("a worker died", -1, -1);

	for (r = 0; r < NROLES; r++) {
		printf("storm-ops %s %ld\n", rname[r], sh->ops[r]);
		checks++;
		if (sh->ops[r] == 0)
			fail("a role completed no operation", -1, -1);
	}

	for (f = 0; f < nfiles; f++) {
		int fd;

		path(p, sizeof(p), f);
		if ((fd = open(p, O_RDWR)) < 0 || fsync(fd) != 0)
			fail("the final fsync failed", f, -1);
		if (fd >= 0)
			close(fd);
	}
	{
		FILE *m;

		snprintf(p, sizeof(p), "%s/storm.seq", dir);
		m = fopen(p, "w");
		if (m == NULL || fwrite(sh->next, sizeof(sh->next), 1, m) != 1 ||
		    fflush(m) != 0 || fsync(fileno(m)) != 0)
			fail("the sequence manifest was not written", -1, -1);
		if (m)
			fclose(m);
	}
verify:
	/* Every cell whole, in place and at its last sequence. */
	for (f = 0; f < nfiles; f++) {
		int fd;

		path(p, sizeof(p), f);
		fd = open(p, O_RDONLY);
		if (fd < 0) {
			fail("a file is gone after the run", f, -1);
			continue;
		}
		for (c = 0; c < CELLS; c++) {
			uint64_t q;

			checks++;
			if (pread(fd, b, CELL, (off_t)c * CELL) != CELL ||
			    (r = check(b, f, c, &q)) < 0)
				fail("a cell is bad after the run", f, c);
			else if (sh->next[f][c] && (r != 0 ||
			    q != sh->next[f][c]))
				fail("a cell lost its last write", f, c);
		}
		close(fd);
	}
	failures = sh->fails;
	if (failures)
		printf("storm-fail %s (%ld in all)\n", sh->first, failures);
	else
		printf("storm-ok   every cell whole and in place, %d files of "
		    "%d cells\n", nfiles, CELLS);
	printf("storm-checks %ld\nstorm-failures %ld\n", checks, failures);
	return (failures ? 1 : 0);
}
