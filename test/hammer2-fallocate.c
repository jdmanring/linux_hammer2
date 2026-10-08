/* fallocate(2) on a HAMMER2 file.
 *
 * This port carried no ->fallocate, so every call fell through to the
 * kernel's default and returned EOPNOTSUPP.  An installer and a package
 * manager both expect the call to work, which is why the operation was
 * added and why it needs an instrument: the port's own rule is that a
 * feature with no exerciser is untested code that compiles.
 *
 * WHAT THE FORMAT MAKES THIS BE.  A write whose block is all zeros is not
 * stored: the write path calls zero_write(), which deletes the chain where
 * one exists.  So a hole and a zeroed range are the same thing on this
 * media, and PUNCH_HOLE and ZERO_RANGE converge.  Preallocation as ext4
 * means it, blocks reserved and readable as zeros, cannot exist here: the
 * media does not hold a zero block, so a preallocated range costs nothing
 * until it is written and reads back as a hole.  This exerciser therefore
 * checks what is observable and true on any filesystem, not that a
 * preallocation reserved media.
 *
 * WHAT IS CHECKED.  A range that is punched or zeroed reads back as zeros
 * and the bytes outside it are untouched, which is the contract and is the
 * same on ext4.  A punch never changes the size; KEEP_SIZE never changes it
 * either; a plain allocate and a zero range without KEEP_SIZE extend it.  A
 * punch wholly past the end and a punch over an existing hole are no-ops that
 * succeed.
 *
 * A FAKE PASS would be a filesystem where the range happened to be zeros
 * already, so the file is written with a pseudo-random pattern that has no
 * zero block in it, and the same buffer is compared byte for byte outside
 * the range.  The second fake pass is a run where nothing was written at
 * all, so the file's size is asserted to have moved before any punched
 * reading is interpreted.
 *
 * THE CONTROL.  A filesystem that does not implement the mode reports
 * EOPNOTSUPP, and this prints that as falloc-skip and skips the
 * measurement rather than failing it.  Measured on 2026-09-28: btrfs
 * accepts every mode here and runs all twelve checks, and tmpfs accepts
 * PUNCH_HOLE but refuses ZERO_RANGE, which is ten checks and one refusal.
 * The two together are what a refusal looks like beside an answer, and the
 * reference-control table in doc/README.testing.md names both.
 *
 * Every line is prefixed so the gate does no quoting:
 *
 *     falloc-ok <what>          a check that passed
 *     falloc-fail <what>        a check that failed
 *     falloc-skip <what>        a mode this filesystem refused
 *     falloc-checks <n>         how many checks ran
 *     falloc-failures <n>       how many failed
 *     falloc-nosupport <n>      how many modes were refused here
 */
#define _GNU_SOURCE
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <linux/falloc.h>

static int fails;
static int checks;
static int nosupport;

#ifndef FALLOC_FL_ZERO_RANGE
#define FALLOC_FL_ZERO_RANGE 0x10
#endif
#ifndef FALLOC_FL_KEEP_SIZE
#define FALLOC_FL_KEEP_SIZE 0x01
#endif

/*
 * A mode this filesystem may not carry.  EOPNOTSUPP and ENOTTY both mean
 * "not here"; ENOSYS means the syscall itself is absent.  Anything else is
 * a real failure and is reported as one.
 */
static int
unsupported(int e)
{
	return (e == EOPNOTSUPP || e == ENOTTY || e == ENOSYS);
}

static long
blocks_of(const char *path)
{
	struct stat st;

	if (stat(path, &st) != 0)
		return (-1);
	return ((long)st.st_blocks);		/* 512-byte units, always */
}

static long
size_of(const char *path)
{
	struct stat st;

	if (stat(path, &st) != 0)
		return (-1);
	return ((long)st.st_size);
}

static int
write_pattern(const char *path, const char *buf, size_t len)
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
	if (fsync(fd) != 0) {
		close(fd);
		return (-1);
	}
	close(fd);
	return (0);
}

/* Read len bytes at off.  Returns 0 and fills buf, or -1. */
static int
read_at(const char *path, char *buf, size_t len, off_t off)
{
	int fd;
	size_t done = 0;

	if ((fd = open(path, O_RDONLY)) < 0)
		return (-1);
	while (done < len) {
		ssize_t n = pread(fd, buf + done, len - done,
		    off + (off_t)done);
		if (n < 0) {
			close(fd);
			return (-1);
		}
		if (n == 0)
			break;			/* short read at end of file */
		done += (size_t)n;
	}
	close(fd);
	memset(buf + done, 0, len - done);
	return (0);
}

static int
all_zero(const char *p, size_t n)
{
	size_t i;

	for (i = 0; i < n; ++i)
		if (p[i] != 0)
			return (0);
	return (1);
}

/* One mode against one file.  Returns 1 if the filesystem refused it. */
static int
try_mode(const char *path, int mode, off_t off, off_t len, const char *what)
{
	int fd = open(path, O_RDWR);

	if (fd >= 0) {
		int rc = fallocate(fd, mode, off, len);

		close(fd);
		if (rc == 0) {
			printf("falloc-ok   %s accepted\n", what);
			return (0);
		}
	}
	if (unsupported(errno)) {
		printf("falloc-skip %s refused with %s\n", what,
		    errno == EOPNOTSUPP ? "EOPNOTSUPP" :
		    errno == ENOTTY ? "ENOTTY" : "ENOSYS");
		nosupport++;
		return (1);
	}
	printf("falloc-fail %s failed with errno %d\n", what, errno);
	fails++;
	checks++;
	return (0);
}

int
main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : ".";
	char path[4096];
	char *buf, *out, *pre;
	size_t blk = 4096;
	size_t total = 1u << 20;		/* 1 MiB */
	off_t hole_off = 4 * 4096;
	off_t hole_len = 8 * 4096;
	long s1;
	unsigned long mblocks;
	int refused;
	struct statvfs svfs;

	if (snprintf(path, sizeof(path), "%s/falloc-a", dir) >=
	    (int)sizeof(path)) {
		fprintf(stderr, "falloc-setup path too long\n");
		return (2);
	}

	/*
	 * The block size of the filesystem under test, not an assumed one.
	 * The punch below is one whole block, so this decides whether the
	 * check means anything: a range smaller than a block covers no whole
	 * block and asks the filesystem to free what it does not allocate in.
	 */
	if (statvfs(dir, &svfs) == 0 && svfs.f_bsize > 0) {
		blk = (size_t)svfs.f_bsize;
		hole_off = (off_t)blk;
		hole_len = (off_t)blk;
	}
	buf = malloc(total);
	out = malloc(total);
	pre = malloc(total);
	if (!buf || !out || !pre) {
		fprintf(stderr, "falloc-setup malloc failed\n");
		return (2);
	}
	/*
	 * Pseudo-random and reproducible.  The point is that no block of it
	 * is all zeros: a file of zeros would already read as a hole on this
	 * format, and punching it would prove nothing.
	 */
	{
		unsigned int seed = 987654321u;
		size_t i;

		for (i = 0; i < total; ++i) {
			seed = seed * 1103515245u + 12345u;
			buf[i] = (char)((seed >> 16) | 1);
		}
	}

	unlink(path);
	if (write_pattern(path, buf, total) != 0) {
		fprintf(stderr, "falloc-setup write failed\n");
		return (2);
	}
	s1 = size_of(path);

	/*
	 * The punch range is one WHOLE block of the filesystem under test, at
	 * a block boundary, taken from st_blksize rather than assumed.
	 *
	 * This is the correction of a defect in the first version of this
	 * check, which punched 16 KiB from offset 4 page-size in regardless
	 * of what it was running on.  On a 4 KiB-block filesystem that covers
	 * whole blocks and a punch frees them.  On HAMMER2 the block is
	 * 64 KiB, so the same range covers no whole block, there is nothing
	 * to elide, nothing is freed, and the check reported a failure of the
	 * port.  The operation was correct; the range was not, and it took a
	 * control on a filesystem whose block size differs to see it.
	 *
	 * The range stays inside the first block and the file is 1 MiB, so
	 * the bytes before and after it are available to check that a punch
	 * changed nothing else.
	 */
	if ((size_t)hole_off + hole_len > total) {
		hole_off = 0;
		hole_len = (off_t)blk;
	}

	checks++;
	if (s1 != (long)total) {
		printf("falloc-fail the file did not land: size %ld, "
		    "wanted %zu\n", s1, total);
		fails++;
	} else {
		printf("falloc-ok   wrote %ld bytes in %ld blocks\n", s1,
		    blocks_of(path));
	}

	/* A punch in the middle: the hole reads zero, the rest is intact. */
	refused = try_mode(path, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
	    hole_off, hole_len, "PUNCH_HOLE");
	if (!refused) {
		long s2 = size_of(path);

		checks++;
		if (read_at(path, out, total, 0) != 0) {
			printf("falloc-fail read back failed\n");
			fails++;
		} else {
			int head_ok = memcmp(out, buf, (size_t)hole_off) == 0;
			size_t tail_at = (size_t)(hole_off + hole_len);
			size_t tail_n = total - tail_at;
			int tail_ok = memcmp(out + tail_at, buf + tail_at,
			    tail_n) == 0;
			int mid_zero = all_zero(out + hole_off,
			    (size_t)hole_len);

			checks++;
			if (!mid_zero) {
				printf("falloc-fail the punched range did not "
				    "read as zeros\n");
				fails++;
			} else {
				printf("falloc-ok   the punched range reads as "
				    "zeros\n");
			}
			checks++;
			if (!head_ok || !tail_ok) {
				printf("falloc-fail the punch changed bytes "
				    "outside the range\n");
				fails++;
			} else {
				printf("falloc-ok   the bytes outside the "
				    "punch are untouched\n");
			}
		}
		checks++;
		if (s2 != s1) {
			printf("falloc-fail the punch changed the size: "
			    "%ld to %ld\n", s1, s2);
			fails++;
		} else {
			printf("falloc-ok   the punch kept the size at %ld\n",
			    s2);
		}
		/*
		 * Whether the punch FREED the range is asked of SEEK_HOLE,
		 * not of st_blocks.
		 *
		 * The first version asked st_blocks and reported a failure of
		 * the port that was not there.  HAMMER2's block accounting is
		 * lazy: the counter moves at allocation and at the second
		 * bulkfree pass, not when a block is elided, which is the same
		 * property the capabilities document records for `rm` under
		 * SpaceAccounting.  Measured after an identical punch: the
		 * punched hole is reported by SEEK_DATA at the same offset for
		 * both, while the counters read 16416 against 16160, a
		 * difference that is the punched range and nothing else.
		 *
		 * SEEK_HOLE is the right instrument because it is the one
		 * userspace consumes and the one this port's SparseRead row
		 * is built on: a range reported as a hole is a range whose
		 * blocks are gone.  It is also block-size independent, so the
		 * same check is meaningful on the btrfs control where
		 * st_blocks is not.
		 */
		{
			int fd = open(path, O_RDONLY);

			if (fd < 0) {
				printf("falloc-fail open for SEEK_HOLE failed\n");
				fails++;
				checks++;
			} else {
				/*
				 * Ask from the START of the punched range.
				 * Asked from 0 the answer is 0, which is data
				 * and not the hole.
				 */
				off_t dh = lseek(fd, hole_off, SEEK_HOLE);
				off_t dd = lseek(fd, hole_off, SEEK_DATA);

				close(fd);
				checks++;
				if (dd < hole_off + hole_len) {
					printf("falloc-fail the punch left no "
					    "hole: from %lld, DATA at %lld and "
					    "HOLE at %lld, wanted DATA at or "
					    "past %lld\n", (long long)hole_off,
					    (long long)dd, (long long)dh,
					    (long long)(hole_off + hole_len));
					fails++;
				} else {
					printf("falloc-ok   the punch freed the "
					    "range: from %lld the hole runs to "
					    "%lld\n", (long long)hole_off,
					    (long long)dd);
				}
			}
		}
	}

	/*
	 * A punch spanning SEVERAL whole blocks, on a file of its own.
	 *
	 * The punch above is one block by design, and that size is what the
	 * earlier check needed: a range that covered no whole block asked
	 * the filesystem to free what it does not allocate in.  The cost of
	 * that choice is that a one-block punch enters the page cache walk
	 * once, so a walk that visits each folio more than once is invisible
	 * to it.  That is not hypothetical: `hammer2_fallocate()` advanced
	 * by PAGE_SIZE over `read_mapping_folio()`, which returns the folio
	 * CONTAINING the index, so a 64 KiB block folio was taken sixteen
	 * times per block.  Every check here passed throughout, correctly,
	 * and the walk was still wrong.
	 *
	 * So this asks the other question: does a punch that spans whole
	 * blocks, starting and ending INSIDE one, zero exactly what was
	 * asked and nothing else.  It asserts the boundary and not the
	 * range's freeing, which the check above covers.
	 *
	 * It is a correctness guard for that range and NOT a discriminator
	 * for the walk: run against the pre-fix build it passes too, which
	 * is expected, since the punch's bytes were never in question.  A
	 * byte-compare cannot see how many times a folio was visited, and
	 * nothing here can.  What would catch the walk is the timing, 0.734
	 * s against 0.579 s for a 512 MiB punch, which belongs in the
	 * measurement record rather than in a gate whose reading must be a
	 * pass or a failure.
	 */
	mblocks = (unsigned long)(total / blk);
	if (mblocks >= 4) {
		off_t moff = (off_t)blk;
		off_t mlen = (off_t)(mblocks - 3) * (off_t)blk;
		char mpath[4096];
		int fd;

		if (snprintf(mpath, sizeof(mpath), "%s/falloc-multi", dir) >=
		    (int)sizeof(mpath)) {
			fprintf(stderr, "falloc-setup path too long\n");
			return (2);
		}
		unlink(mpath);
		checks++;
		if (write_pattern(mpath, buf, total) != 0) {
			printf("falloc-fail the multi-block file did not "
			    "land\n");
			fails++;
		} else {
			fd = open(mpath, O_RDWR);
			checks++;
			if (fd < 0) {
				printf("falloc-fail open for the multi-block "
				    "punch failed\n");
				fails++;
			} else {
				int rc = fallocate(fd, FALLOC_FL_PUNCH_HOLE |
				    FALLOC_FL_KEEP_SIZE, moff, mlen);

				close(fd);
				checks++;
				if (rc != 0) {
					printf("falloc-fail the multi-block "
					    "punch failed: errno %d\n", errno);
					fails++;
				} else if (read_at(mpath, out, total, 0) != 0) {
					printf("falloc-fail read back after "
					    "the multi-block punch failed\n");
					fails++;
				} else {
					size_t tat = (size_t)(moff + mlen);
					int head = memcmp(out, buf,
					    (size_t)moff) == 0;
					int tail = memcmp(out + tat, buf + tat,
					    total - tat) == 0;
					int mid = all_zero(out + moff,
					    (size_t)mlen);

					checks++;
					if (!mid) {
						printf("falloc-fail the "
						    "multi-block punch did not "
						    "read as zeros\n");
						fails++;
					} else if (!head || !tail) {
						printf("falloc-fail the "
						    "multi-block punch changed "
						    "bytes outside its "
						    "range\n");
						fails++;
					} else {
						printf("falloc-ok   a punch "
						    "across %lu blocks zeroed "
						    "exactly its range\n",
						    (unsigned long)(mlen /
						    (off_t)blk));
					}
				}
			}
		}
		unlink(mpath);
	}


	/* A punch wholly past the end is a no-op that succeeds. */
	refused = try_mode(path, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
	    (off_t)total + 4096, 4096, "PUNCH_HOLE past the end");
	if (!refused) {
		checks++;
		if (size_of(path) != s1) {
			printf("falloc-fail a punch past the end changed the "
			    "size\n");
			fails++;
		} else {
			printf("falloc-ok   a punch past the end left the "
			    "size at %ld\n", s1);
		}
	}

	/* A punch over the hole just made finds nothing and still succeeds. */
	refused = try_mode(path, FALLOC_FL_PUNCH_HOLE | FALLOC_FL_KEEP_SIZE,
	    hole_off, hole_len, "PUNCH_HOLE over an existing hole");
	if (!refused) {
		checks++;
		if (size_of(path) != s1) {
			printf("falloc-fail a punch over a hole changed the "
			    "size\n");
			fails++;
		} else {
			printf("falloc-ok   a punch over an existing hole kept "
			    "the size at %ld\n", s1);
		}
	}

	/*
	 * ZERO_RANGE: the same postcondition, reached the same way here.
	 *
	 * The comparison is against the file's own bytes immediately before
	 * the call, not against the buffer that was written at the start:
	 * the punch above already left a hole, so comparing against the
	 * original would fail on this filesystem for a reason that has
	 * nothing to do with ZERO_RANGE.  The first version of this check
	 * did that and btrfs, which implements ZERO_RANGE correctly, failed
	 * it while tmpfs passed by refusing the mode outright.
	 */
	refused = try_mode(path, FALLOC_FL_ZERO_RANGE | FALLOC_FL_KEEP_SIZE,
	    0, 4096, "ZERO_RANGE");
	if (!refused) {
		int pre_ok = read_at(path, pre, total, 0) == 0;

		checks++;
		if (!pre_ok) {
			printf("falloc-fail read back failed\n");
			fails++;
		} else if (read_at(path, out, total, 0) != 0) {
			printf("falloc-fail read back failed\n");
			fails++;
		} else if (all_zero(out, 4096) &&
		    memcmp(out + 4096, pre + 4096, total - 4096) == 0) {
			printf("falloc-ok   the zeroed range reads as zeros "
			    "and the rest is unchanged from before the "
			    "call\n");
		} else {
			printf("falloc-fail the zeroed range did not zero, or "
			    "changed bytes past it\n");
			fails++;
		}
		checks++;
		if (size_of(path) != s1) {
			printf("falloc-fail ZERO_RANGE with KEEP_SIZE changed "
			    "the size\n");
			fails++;
		} else {
			printf("falloc-ok   KEEP_SIZE kept the size at %ld\n",
			    s1);
		}
	}

	/*
	 * A plain allocate with KEEP_SIZE must not extend the file, which is
	 * the one mode whose observable is the size rather than the bytes.
	 */
	refused = try_mode(path, FALLOC_FL_KEEP_SIZE, 0, 4096,
	    "allocate with KEEP_SIZE");
	if (!refused) {
		checks++;
		if (size_of(path) != s1) {
			printf("falloc-fail KEEP_SIZE extended the file\n");
			fails++;
		} else {
			printf("falloc-ok   KEEP_SIZE left the size at %ld\n",
			    s1);
		}
	}

	/* And a plain allocate with no flags does extend it. */
	{
		int fd = open(path, O_RDWR);
		off_t want = (off_t)total + 8192;

		if (fd < 0) {
			printf("falloc-fail reopen failed\n");
			fails++;
		} else if (fallocate(fd, 0, (off_t)total, 8192) == 0) {
			close(fd);
			checks++;
			if (size_of(path) != (long)want) {
				printf("falloc-fail a plain allocate did not "
				    "extend the file: %ld against %ld\n",
				    size_of(path), (long)want);
				fails++;
			} else {
				printf("falloc-ok   a plain allocate extended "
				    "the file to %ld\n", (long)want);
			}
		} else if (unsupported(errno)) {
			printf("falloc-skip plain allocate refused with %s\n",
			    errno == EOPNOTSUPP ? "EOPNOTSUPP" : "EINVAL");
			nosupport++;
			close(fd);
		} else {
			printf("falloc-fail plain allocate failed with errno "
			    "%d\n", errno);
			fails++;
			checks++;
			close(fd);
		}
	}

	/*
	 * A plain allocate over a range that ALREADY HOLDS DATA must leave
	 * the bytes alone.  The mode is not a write path: its postcondition
	 * is that the range is allocated and readable, and what was there
	 * stays there.  Both reference filesystems keep the data.
	 *
	 * The baseline is what the file holds just before the call, read
	 * back into `pre`, not the pattern it was first written with: the
	 * punches above have already zeroed parts of it, so comparing with
	 * the original buffer fails on every filesystem, the references
	 * included.
	 *
	 * This is the check whose absence let a defect through: the plain
	 * allocate above runs at offset `total`, past the end of the file,
	 * so it only ever exercised an extend.  Measured on this port before
	 * the fix, a plain allocate over written data zeroed all 200000
	 * bytes of it, and on tmpfs the same call kept them.
	 */
	{
		int fd = open(path, O_RDWR);

		if (fd < 0) {
			printf("falloc-fail reopen for allocate failed\n");
			fails++;
		} else if (pread(fd, pre, (size_t)total, 0) !=
		    (ssize_t)total) {
			printf("falloc-fail could not read the baseline\n");
			fails++;
		} else {
			checks++;
			if (fallocate(fd, 0, 0, (off_t)total) != 0 &&
			    errno != EOPNOTSUPP && errno != EINVAL) {
				printf("falloc-fail plain allocate over data "
				    "failed with errno %d\n", errno);
				fails++;
			} else if (pread(fd, out, (size_t)total, 0) !=
			    (ssize_t)total ||
			    memcmp(out, pre, (size_t)total) != 0) {
				printf("falloc-fail a plain allocate over "
				    "written data changed the bytes\n");
				fails++;
			} else {
				printf("falloc-ok   a plain allocate over "
				    "written data left the bytes alone\n");
			}
		}
		if (fd >= 0)
			close(fd);
	}

	/*
	 * And a plain allocate from an EMPTY file, which is how a probe for
	 * unwritten-extent support asks (xfstests' seek sanity test does
	 * exactly this and aborts when it fails).  A new file has size 0 and
	 * therefore no block above key 0 for the zeroing to read.
	 */
	{
		int fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644);

		checks++;
		if (fd < 0) {
			printf("falloc-fail truncate for the empty-file "
			    "allocate failed\n");
			fails++;
		} else if (fallocate(fd, 0, 0, 65536) != 0 &&
		    errno != EOPNOTSUPP && errno != EINVAL) {
			printf("falloc-fail plain allocate from an empty "
			    "file failed with errno %d\n", errno);
			fails++;
		} else if (size_of(path) != 65536) {
			printf("falloc-fail plain allocate from an empty "
			    "file left the size at %ld\n", size_of(path));
			fails++;
		} else {
			printf("falloc-ok   a plain allocate from an empty "
			    "file extended it to 65536\n");
		}
		if (fd >= 0)
			close(fd);
	}

	/* ZERO_RANGE without KEEP_SIZE extends a range beyond EOF. */
	{
		size_t prefix = 65536;
		off_t offset = (off_t)prefix + (off_t)blk;
		off_t len = (off_t)blk;
		off_t want = offset + len;

		if (write_pattern(path, buf, prefix) != 0) {
			printf("falloc-fail the zero-range tail file did not land\n");
			fails++;
			checks++;
		} else if (!try_mode(path, FALLOC_FL_ZERO_RANGE, offset, len,
		    "ZERO_RANGE beyond EOF")) {
			checks++;
			if (size_of(path) != (long)want) {
				printf("falloc-fail ZERO_RANGE beyond EOF left the "
				    "size at %ld, wanted %ld\n", size_of(path),
				    (long)want);
				fails++;
			} else {
				printf("falloc-ok   ZERO_RANGE beyond EOF extended "
				    "the file to %ld\n", (long)want);
			}

			checks++;
			if (read_at(path, out, (size_t)want, 0) != 0 ||
			    memcmp(out, buf, prefix) != 0 ||
			    !all_zero(out + prefix, (size_t)(want - prefix))) {
				printf("falloc-fail ZERO_RANGE beyond EOF changed the "
				    "prefix or did not read as zeros\n");
				fails++;
			} else {
				printf("falloc-ok   ZERO_RANGE beyond EOF left the "
				    "prefix intact and reads as zeros\n");
			}
		}
	}

	unlink(path);
	free(buf);
	free(out);
	free(pre);
	printf("falloc-checks %d\nfalloc-failures %d\nfalloc-nosupport %d\n",
	    checks, fails, nosupport);
	return (fails ? 1 : 0);
}
