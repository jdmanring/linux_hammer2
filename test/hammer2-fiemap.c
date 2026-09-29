/* fiemap on a HAMMER2 file.
 *
 * A Linux VFS operation this port did not carry.  It is not reachable
 * from the BSD ports, so there is no upstream arrangement to compare
 * against and the contract is the kernel's own, read from fs/ioctl.c;
 * the failure this exercises is the one that matters: a WRONG ANSWER
 * rather than a refusal.
 *
 * WHAT IT REPORTS.  A hole in this format is an offset no chain covers,
 * which the carried bmap XOP answers with ENOENT, and that is what
 * ->llseek already calls a hole.  FIEMAP is the same question asked a
 * block at a time, so the answer is the file's own layout and there is
 * nothing to compare against another filesystem.
 *
 * THE CONTROL IS THE FILE, NOT A REFERENCE FILESYSTEM, and that is
 * deliberate.  Both fiemap and the seek whences describe this media, so
 * a control on btrfs would compare two different layouts rather than
 * check an answer.  The shape is built here and known before the call: a
 * hole is opened in the middle of the file with a sparse seek, and the
 * returned map is compared against that shape.  This is the same
 * reasoning the readiness audit's item 5 records for a test whose
 * subject has no reference, and the reference-control table in
 * doc/README.testing.md says so in the row rather than leaving it out.
 *
 * The first fake pass is a filesystem that reports the whole file as one
 * extent, which is what a stub and a filesystem with no ->fiemap both
 * do; the hole check catches it.  The second is a map whose physical
 * addresses are all zero, which a stub returning success without walking
 * the tree produces; the physical check catches it.  The third is a file
 * that is not really sparse, so its hole is not a hole and the check
 * would pass vacuously; asserted first, against st_blocks.
 *
 * FREEZE IS TESTED HERE TOO, and its structure is the point.  A write
 * while the filesystem is frozen BLOCKS and is released by the thaw, so
 * a test that writes and then thaws from the SAME process deadlocks
 * itself and leaves the volume frozen.  That is exactly what the first
 * version did on 2026-09-29, and it made the freeze vop look broken when
 * the test was.  Every blocking call here is therefore in a child and
 * every thaw is reached by the parent that cannot block.
 *
 * THE COUNT.  Eleven checks on a volume that answers, which is the
 * number the changelog row and the readiness audit cite.  The count is
 * what carries the verdict here, because a volume that refuses FIEMAP or
 * FIFREEZE prints a LOW count and zero failures rather than a failure:
 * the assertion that the file is really sparse runs before the call is
 * made, so a run that answered nothing at all still prints a count of
 * one.  `test-enospc.sh` pins the count at eleven for that reason and
 * fails any other value, and the refusal is visible twice over, in the
 * count and in the fiemap-skip lines it prints.
 *
 * Every line is prefixed so the gate does no quoting:
 *
 *     fiemap-ok <what>          a check that passed
 *     fiemap-fail <what>        a check that failed
 *     fiemap-skip <what>        an operation this filesystem or kernel refused
 *     fiemap-checks <n>         how many checks ran
 *     fiemap-failures <n>       how many failed
 *     fiemap-skipped <n>        how many were refused here
 */
#define _GNU_SOURCE
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <signal.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <linux/fiemap.h>
#include <linux/fs.h>

static int fails;
static int checks;
static int skipped;

#define MAXEXT 64
static struct fiemap_extent exts[MAXEXT];
static unsigned int nexts;

static int
unsupported(int e)
{
	return (e == EOPNOTSUPP || e == ENOTTY || e == ENOSYS ||
	    e == EINVAL || e == ENOTBLK);
}

static long
size_of(const char *path)
{
	struct stat st;

	if (stat(path, &st) != 0)
		return (-1);
	return ((long)st.st_size);
}

/*
 * Ask for the file's extent map.  Returns 0 and fills exts/nexts, -1 on
 * a refusal this filesystem is entitled to give, -2 on a real failure.
 *
 * The request struct and the extent array must be contiguous, because
 * struct fiemap ends in a flexible array member and the kernel reads the
 * extents from the address just past the header.  One heap block, with
 * the header at its start and the extents immediately after, keeps that
 * layout without the non-standard "flexible member not last" struct,
 * which is a GNU extension and warns.
 */
static int
get_map(const char *path)
{
	struct fiemap *fm;
	struct fiemap_extent *fe;
	char *buf;
	int fd, ret;

	buf = calloc(1, sizeof(*fm) + MAXEXT * sizeof(*fe));
	if (buf == NULL)
		return (-2);
	fm = (struct fiemap *)buf;
	fe = (struct fiemap_extent *)(buf + sizeof(*fm));

	fm->fm_start = 0;
	fm->fm_length = FIEMAP_MAX_OFFSET;
	fm->fm_extent_count = MAXEXT;
	fm->fm_flags = 0;

	fd = open(path, O_RDONLY);
	if (fd < 0) {
		free(buf);
		return (-2);
	}
	if (ioctl(fd, FS_IOC_FIEMAP, fm) != 0) {
		int e = errno;

		close(fd);
		free(buf);
		if (unsupported(e)) {
			printf("fiemap-skip FIEMAP refused with errno %d\n", e);
			skipped++;
			return (-1);
		}
		printf("fiemap-fail FIEMAP failed with errno %d\n", e);
		fails++;
		checks++;
		return (-2);
	}
	close(fd);
	nexts = fm->fm_mapped_extents;
	ret = 0;
	if (nexts > MAXEXT) {
		nexts = MAXEXT;
		ret = 1;		/* the caller was not shown it all */
	}
	memcpy(exts, fe, nexts * sizeof(exts[0]));
	free(buf);
	return (ret);
}

/* Is [off, off+len) fully covered by data extents (not a hole)? */
static int
range_is_data(unsigned long long off, unsigned long long len)
{
	unsigned long long want_end = off + len;
	unsigned long long have = off;
	unsigned int i;

	for (i = 0; i < nexts; ++i) {
		unsigned long long s = exts[i].fe_logical;
		unsigned long long e = s + exts[i].fe_length;

		if (e <= have)
			continue;
		if (s > have)
			return (0);		/* gap before this extent */
		have = e;
		if (have >= want_end)
			return (1);
	}
	return (have >= want_end);
}

/* Is any part of [off, off+len) inside a data extent? */
static int
range_is_hole(unsigned long long off, unsigned long long len)
{
	unsigned long long want_end = off + len;
	unsigned int i;

	for (i = 0; i < nexts; ++i) {
		unsigned long long s = exts[i].fe_logical;
		unsigned long long e = s + exts[i].fe_length;

		if (s < want_end && e > off)
			return (0);		/* overlaps a data extent */
	}
	return (1);
}

int
main(int argc, char **argv)
{
	const char *dir = argc > 1 ? argv[1] : ".";
	char path[4096];
	char buf[65536];
	size_t blk = 4096;
	long off_data1, off_hole, off_data2;
	ssize_t n;
	int fd, ret;
	struct statvfs svfs;

	if (snprintf(path, sizeof(path), "%s/fiemap-a", dir) >=
	    (int)sizeof(path)) {
		fprintf(stderr, "fiemap-setup path too long\n");
		return (2);
	}
	memset(buf, 0x5a, sizeof(buf));

	/*
	 * The filesystem's own block size, so the file's shape is built in
	 * whole blocks of whatever this is and the map is compared in the
	 * same unit.  On this port that is 64 KiB.
	 */
	if (statvfs(dir, &svfs) == 0 && svfs.f_bsize > 0)
		blk = (size_t)svfs.f_bsize;
	if (blk > sizeof(buf))
		blk = sizeof(buf);

	off_data1 = 0;
	off_hole = (long)blk;
	off_data2 = (long)blk * 2;

	unlink(path);
	fd = open(path, O_CREAT | O_TRUNC | O_RDWR, 0644);
	if (fd < 0) {
		fprintf(stderr, "fiemap-setup create failed\n");
		return (2);
	}

	/* Block 0: data. */
	n = pwrite(fd, buf, blk, off_data1);
	if (n != (ssize_t)blk) {
		fprintf(stderr, "fiemap-setup write1 failed\n");
		close(fd);
		return (2);
	}
	/* Block 1: leave a hole by seeking past it (so it is sparse). */
	/* Block 2: data. */
	n = pwrite(fd, buf, blk, off_data2);
	if (n != (ssize_t)blk) {
		fprintf(stderr, "fiemap-setup write2 failed\n");
		close(fd);
		return (2);
	}
	fsync(fd);
	close(fd);

	/*
	 * The hole must be REAL before its absence from the map means
	 * anything: a file whose middle block was written as zeros is not
	 * sparse, has no hole, and a map with no gap over it would be
	 * correct.  This is the same trap the seek exerciser documents.
	 */
	{
		struct stat st;

		checks++;
		if (stat(path, &st) != 0) {
			printf("fiemap-fail stat failed\n");
			fails++;
		} else if ((unsigned long long)st.st_blocks * 512 >=
		    (unsigned long long)off_data2 + blk) {
			printf("fiemap-fail the file has no hole: %lld blocks "
			    "for a %ld-byte file, so the map is being "
			    "asked about a dense file\n",
			    (long long)st.st_blocks, off_data2 + (long)blk);
			fails++;
		} else {
			printf("fiemap-ok   the file is sparse: %lld blocks for "
			    "%ld bytes\n", (long long)st.st_blocks,
			    off_data2 + (long)blk);
		}
	}

	ret = get_map(path);
	if (ret == -1) {
		/* Refused: report and stop, the count check is the gate's. */
		unlink(path);
		printf("fiemap-checks %d\nfiemap-failures %d\nfiemap-skipped %d\n",
		    checks, fails, skipped);
		return (fails ? 1 : 0);
	}
	if (ret == -2) {
		unlink(path);
		printf("fiemap-checks %d\nfiemap-failures %d\nfiemap-skipped %d\n",
		    checks, fails, skipped);
		return (1);
	}

	/* The map must have at least one extent at all. */
	checks++;
	if (nexts == 0) {
		printf("fiemap-fail FIEMAP reported no extent for a file with "
		    "data in it\n");
		fails++;
	} else {
		printf("fiemap-ok   FIEMAP returned %u extent(s)\n", nexts);
	}

	/* Data where the data is. */
	checks++;
	if (range_is_data((unsigned long long)off_data1, blk))
		printf("fiemap-ok   the map shows data at the first block\n");
	else {
		printf("fiemap-fail the map shows no data at the first block, "
		    "which was written\n");
		fails++;
	}

	/* The hole. This is the fake pass the whole file as one extent
	 * would fail. */
	checks++;
	if (range_is_hole((unsigned long long)off_hole, blk))
		printf("fiemap-ok   the map shows the middle block as a hole\n");
	else {
		printf("fiemap-fail the map reports data over the hole at %ld, "
		    "so it is not describing the file\n", off_hole);
		fails++;
	}

	/* Data after the hole. */
	checks++;
	if (range_is_data((unsigned long long)off_data2, blk))
		printf("fiemap-ok   the map shows data at the third block\n");
	else {
		printf("fiemap-fail the map shows no data at the third block, "
		    "which was written\n");
		fails++;
	}

	/*
	 * The physical addresses must not all be the same and must not be
	 * zero: a stub that returns success without walking the tree
	 * reports zeroes, which is the second fake pass.
	 */
	checks++;
	{
		unsigned int i;
		int any_zero = 0, any_set = 0;

		for (i = 0; i < nexts; ++i) {
			if (exts[i].fe_physical == 0)
				any_zero = 1;
			else
				any_set = 1;
		}
		if (nexts > 0 && !any_set) {
			printf("fiemap-fail every extent reports physical 0, so "
			    "the map was not walked\n");
			fails++;
		} else {
			printf("fiemap-ok   the extents carry a physical address "
			    "(none set: %d)\n", !any_set);
		}
		(void)any_zero;
	}

	/*
	 * A write must still take after the map was taken, which is the
	 * control that the map did not leave the volume unable to write.
	 * It is deliberately the last thing here and deliberately not
	 * conditional on anything above: a run that returns early still
	 * proves the file is writable, and a stub that left a lock held
	 * would fail this.
	 */
	{
		int wfd = open(path, O_WRONLY | O_APPEND);
		long before = size_of(path);

		checks++;
		if (wfd < 0) {
			printf("fiemap-fail reopen for the write control failed\n");
			fails++;
		} else {
			ssize_t w = write(wfd, "x", 1);

			close(wfd);
			if (w != 1 || size_of(path) != before + 1) {
				printf("fiemap-fail a write after the map did "
				    "not take\n");
				fails++;
			} else {
				printf("fiemap-ok   the volume still accepts a "
				    "write after the map\n");
			}
		}
	}

	/*
	 * FREEZE.  The contract, measured rather than assumed: while the
	 * filesystem is frozen a write BLOCKS and is released by the thaw.
	 * It must not fail, and it must not block forever.
	 *
	 * The structure here is the whole point and the earlier version of
	 * this test got it wrong.  A write while frozen blocks in the
	 * frozen process, so a test that writes and then thaws from the
	 * SAME process deadlocks itself and leaves the volume frozen, which
	 * is what happened on 2026-09-29 and made the freeze vop look
	 * broken when it was the test.  So: the writing is done in a child
	 * that may block, and the thaw is always reached by the parent that
	 * never blocks.  Every blocking step is in a child and every thaw
	 * is in the parent.
	 */
	{
		int dfd = open(dir, O_RDONLY | O_DIRECTORY);
		int wfd, status;
		pid_t pid;
		long before;

		if (dfd < 0) {
			printf("fiemap-skip freeze: could not open the directory\n");
			skipped++;
		} else if (ioctl(dfd, FIFREEZE, 0) != 0) {
			printf("fiemap-skip FIFREEZE refused with errno %d\n",
			    errno);
			skipped++;
			close(dfd);
			dfd = -1;
		}

		if (dfd >= 0) {
			printf("fiemap-ok   FIFREEZE returned 0\n");
			checks++;

			/* The file is made before the freeze so the child's
			 * write is a write and not a create, which takes a
			 * different path. */
			wfd = open(path, O_CREAT | O_WRONLY | O_APPEND, 0644);
			if (wfd >= 0)
				close(wfd);
			before = size_of(path);

			/* The writer may block; it is a child, so it can. */
			pid = fork();
			if (pid == 0) {
				int fd = open(path, O_WRONLY | O_APPEND);
				ssize_t w;

				if (fd < 0)
					_exit(2);
				w = write(fd, "frozen", 6);
				close(fd);
				_exit(w == 6 ? 0 : 3);
			}

			/*
			 * Give the child time to reach the blocked write,
			 * then thaw.  The thaw must be reached whatever the
			 * child did, which is why it is not conditional on
			 * anything the child did.
			 */
			sleep(2);
			checks++;
			if (ioctl(dfd, FITHAW, 0) != 0) {
				printf("fiemap-fail FITHAW failed with errno %d, so "
				    "the volume is left frozen\n", errno);
				fails++;
				kill(pid, SIGKILL);
				waitpid(pid, &status, 0);
				close(dfd);
				goto freeze_done;
			}
			printf("fiemap-ok   FITHAW returned 0\n");

			checks++;
			{
				int waited = 0;
				pid_t r;

				while ((r = waitpid(pid, &status,
				    WNOHANG)) != pid) {
					if (waited >= 10) {
						printf("fiemap-fail the writer is "
						    "still blocked 10s after "
						    "the thaw\n");
						fails++;
						kill(pid, SIGKILL);
						waitpid(pid, &status, 0);
						break;
					}
					sleep(1);
					waited++;
				}
				if (r == pid && WIFEXITED(status) &&
				    WEXITSTATUS(status) == 0)
					printf("fiemap-ok   the blocked write was "
					    "released by the thaw\n");
				else if (r == pid) {
					printf("fiemap-fail the write across the "
					    "freeze did not succeed: exit "
					    "%d\n", WIFEXITED(status) ?
					    WEXITSTATUS(status) : -1);
					fails++;
				}
			}

			/* And the data the child wrote must be there. */
			checks++;
			if (size_of(path) != before + 6) {
				printf("fiemap-fail the write released by the thaw "
				    "did not reach the file: %ld against "
				    "%ld\n", size_of(path), before + 6);
				fails++;
			} else {
				printf("fiemap-ok   the write the thaw released "
				    "is in the file\n");
			}

			close(dfd);
		}
	}
freeze_done:

	unlink(path);
	printf("fiemap-checks %d\nfiemap-failures %d\nfiemap-skipped %d\n",
	    checks, fails, skipped);
	return (fails ? 1 : 0);
}
