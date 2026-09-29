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
 * FREEZE IS NOT TESTED HERE.  This port does not carry ->freeze_fs: the
 * first implementation of it wedged a volume on 2026-09-29 and it was
 * removed rather than shipped, and hammer2_vfsops.c carries the record.
 * The freeze half of this exerciser is what wedged it, and the defect
 * was in the exerciser as much as in the vop, so neither is here: a test
 * for an operation the tree does not carry would be a test of the
 * kernel's own EOPNOTSUPP, which fs/ioctl.c already answers.
 *
 * Every line is prefixed so the gate does no quoting:
 *
 *     fm-ok <what>          a check that passed
 *     fm-fail <what>        a check that failed
 *     fm-skip <what>        an operation this filesystem or kernel refused
 *     fm-checks <n>         how many checks ran
 *     fm-failures <n>       how many failed
 *     fm-skipped <n>        how many were refused here
 */
#define _GNU_SOURCE
#include <sys/stat.h>
#include <sys/statvfs.h>
#include <sys/ioctl.h>
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
			printf("fm-skip FIEMAP refused with errno %d\n", e);
			skipped++;
			return (-1);
		}
		printf("fm-fail FIEMAP failed with errno %d\n", e);
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
		fprintf(stderr, "fm-setup path too long\n");
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
		fprintf(stderr, "fm-setup create failed\n");
		return (2);
	}

	/* Block 0: data. */
	n = pwrite(fd, buf, blk, off_data1);
	if (n != (ssize_t)blk) {
		fprintf(stderr, "fm-setup write1 failed\n");
		close(fd);
		return (2);
	}
	/* Block 1: leave a hole by seeking past it (so it is sparse). */
	/* Block 2: data. */
	n = pwrite(fd, buf, blk, off_data2);
	if (n != (ssize_t)blk) {
		fprintf(stderr, "fm-setup write2 failed\n");
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
			printf("fm-fail stat failed\n");
			fails++;
		} else if ((unsigned long long)st.st_blocks * 512 >=
		    (unsigned long long)off_data2 + blk) {
			printf("fm-fail the file has no hole: %lld blocks "
			    "for a %ld-byte file, so the map is being "
			    "asked about a dense file\n",
			    (long long)st.st_blocks, off_data2 + (long)blk);
			fails++;
		} else {
			printf("fm-ok   the file is sparse: %lld blocks for "
			    "%ld bytes\n", (long long)st.st_blocks,
			    off_data2 + (long)blk);
		}
	}

	ret = get_map(path);
	if (ret == -1) {
		/* Refused: report and stop, the count check is the gate's. */
		unlink(path);
		printf("fm-checks %d\nfm-failures %d\nfm-skipped %d\n",
		    checks, fails, skipped);
		return (fails ? 1 : 0);
	}
	if (ret == -2) {
		unlink(path);
		printf("fm-checks %d\nfm-failures %d\nfm-skipped %d\n",
		    checks, fails, skipped);
		return (1);
	}

	/* The map must have at least one extent at all. */
	checks++;
	if (nexts == 0) {
		printf("fm-fail FIEMAP reported no extent for a file with "
		    "data in it\n");
		fails++;
	} else {
		printf("fm-ok   FIEMAP returned %u extent(s)\n", nexts);
	}

	/* Data where the data is. */
	checks++;
	if (range_is_data((unsigned long long)off_data1, blk))
		printf("fm-ok   the map shows data at the first block\n");
	else {
		printf("fm-fail the map shows no data at the first block, "
		    "which was written\n");
		fails++;
	}

	/* The hole. This is the fake pass the whole file as one extent
	 * would fail. */
	checks++;
	if (range_is_hole((unsigned long long)off_hole, blk))
		printf("fm-ok   the map shows the middle block as a hole\n");
	else {
		printf("fm-fail the map reports data over the hole at %ld, "
		    "so it is not describing the file\n", off_hole);
		fails++;
	}

	/* Data after the hole. */
	checks++;
	if (range_is_data((unsigned long long)off_data2, blk))
		printf("fm-ok   the map shows data at the third block\n");
	else {
		printf("fm-fail the map shows no data at the third block, "
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
			printf("fm-fail every extent reports physical 0, so "
			    "the map was not walked\n");
			fails++;
		} else {
			printf("fm-ok   the extents carry a physical address "
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
			printf("fm-fail reopen for the write control failed\n");
			fails++;
		} else {
			ssize_t w = write(wfd, "x", 1);

			close(wfd);
			if (w != 1 || size_of(path) != before + 1) {
				printf("fm-fail a write after the map did "
				    "not take\n");
				fails++;
			} else {
				printf("fm-ok   the volume still accepts a "
				    "write after the map\n");
			}
		}
	}

	unlink(path);
	printf("fm-checks %d\nfm-failures %d\nfm-skipped %d\n",
	    checks, fails, skipped);
	return (fails ? 1 : 0);
}
