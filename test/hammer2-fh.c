/* The file-handle surface: name_to_handle_at(2) and open_by_handle_at(2).
 *
 * These two syscalls are the whole of what a filesystem's export_operations
 * table does, and they need no nfsd: name_to_handle_at() calls ->encode_fh,
 * open_by_handle_at() calls ->fh_to_dentry and, for a directory, the
 * reconnect path that calls ->get_parent.  So a mount with a correct table
 * answers both and a mount with no table answers neither.
 *
 * The failure this exists to catch is a handle that opens the WRONG object.
 * "The open succeeded" is satisfied by a decoder that ignores the inode
 * number and hands back any inode, and by a decoder whose length guard is
 * off by one, so the positive checks are paired with a control that says
 * which object came back:
 *
 *   - two files with different contents are encoded and reopened, and each
 *     must read its own bytes and report its own st_ino;
 *   - a handle whose inode number has a bit flipped must be REFUSED, not
 *     resolved to a neighbour;
 *   - a handle for a file that is unlinked must go stale, and a file
 *     created after it must not be reachable through it.
 *
 * The directory check is the only one that forces ->get_parent to run: a
 * directory dentry from d_obtain_alias() is DCACHE_DISCONNECTED, so the
 * kernel reconnects it, and a ->get_parent that returned NULL would be a
 * kernel oops here rather than a failed check.
 *
 * Every line is prefixed, and the last two are the counts the gate reads:
 *
 *     fh-ok <what>          a check that passed
 *     fh-fail <what>        a check that failed
 *     fh-checks <n>         how many checks ran
 *     fh-failures <n>       how many failed
 *
 * The prefix is what lets the gate do no quoting.  This runs inside a
 * single-quoted ssh command, where a quote ends the string early and hands
 * the rest of the script to this machine instead of the guest, so the guest
 * side prints what it is given and counts nothing itself.
 *
 * Usage: hammer2-fh <writable-mount-dir>.  It makes its own files under the
 * directory and removes them.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/syscall.h>

/* From <linux/fcntl.h>, a stable ABI; a libc older than the syscall has
 * neither the op nor these, so both are spelled here rather than assumed. */
#ifndef AT_HANDLE_CONNECTABLE
#define AT_HANDLE_CONNECTABLE	0x002
#endif
#ifndef MAX_HANDLE_SZ
#define MAX_HANDLE_SZ		128
#endif

/* FILEID_INO64_GEN / FILEID_INO64_GEN_PARENT, the types the port encodes. */
#define FILEID_INO64_GEN		0x81
#define FILEID_INO64_GEN_PARENT		0x82

static int checks, failures;

static void
ok(const char *what)
{
	printf("fh-ok %s\n", what);
	checks++;
}

static void
fail(const char *what)
{
	printf("fh-fail %s\n", what);
	checks++;
	failures++;
}

static struct file_handle *
fh_alloc(void)
{
	struct file_handle *h;

	h = malloc(sizeof(*h) + MAX_HANDLE_SZ);
	if (h == NULL)
		exit(2);
	memset(h, 0, sizeof(*h) + MAX_HANDLE_SZ);
	h->handle_bytes = MAX_HANDLE_SZ;
	return (h);
}

static int
fh_encode(int dirfd, const char *name, struct file_handle *h)
{
	int mnt_id = 0;

	/*
	 * mount_id is not optional: name_to_handle_at(2) put_user()s the
	 * mount id through it on every call and returns EFAULT for a NULL,
	 * whether or not the caller wants the value.
	 */
	return (name_to_handle_at(dirfd, name, h, &mnt_id,
	    AT_HANDLE_CONNECTABLE));
}

/* Read a whole small file and return its length, or -1. */
static long
slurp(int fd, char *buf, size_t n)
{
	long got = read(fd, buf, n);

	return (got);
}

int
main(int argc, char **argv)
{
	char pat_a[4096], buf[4096];
	struct file_handle *ha, *hb, *hdir, *hbad;
	int mfd, fd, i;
	long n;
	char path[4096];

	if (argc < 2) {
		fprintf(stderr, "usage: %s <mount-dir>\n", argv[0]);
		return (2);
	}
	snprintf(path, sizeof(path), "%s", argv[1]);
	if (mkdir(path, 0777) != 0 && errno != EEXIST) {
		perror("mkdir");
		return (2);
	}

	memset(pat_a, 'A', sizeof(pat_a));
	for (i = 0; i < (int)sizeof(pat_a); i++)
		buf[i] = 'B';

	/* Two files whose contents are distinct and known. */
	snprintf(path, sizeof(path), "%s/a", argv[1]);
	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) { perror("open a"); return (2); }
	write(fd, pat_a, sizeof(pat_a));
	close(fd);
	snprintf(path, sizeof(path), "%s/b", argv[1]);
	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) { perror("open b"); return (2); }
	write(fd, buf, 2048);
	close(fd);

	mfd = open(argv[1], O_RDONLY | O_DIRECTORY);
	if (mfd < 0) { perror("open mount"); return (2); }

	ha = fh_alloc();
	hb = fh_alloc();

	/* (a) encode and reopen a regular file, and read its bytes back. */
	if (fh_encode(mfd, "a", ha) != 0) {
		fail("encode a regular file");
	} else if ((ha->handle_type & 0xff) != FILEID_INO64_GEN_PARENT) {
		/* A connectable non-directory carries its parent. */
		fail("a file encodes as the parent form");
	} else {
		ok("encode a regular file");
		fd = open_by_handle_at(mfd, ha, O_RDONLY);
		if (fd < 0) {
			fail("reopen a regular file by handle");
		} else {
			n = slurp(fd, buf, sizeof(buf));
			if (n == (long)sizeof(pat_a) &&
			    memcmp(buf, pat_a, sizeof(pat_a)) == 0)
				ok("the reopened file reads its own bytes");
			else
				fail("the reopened file reads its own bytes");
			close(fd);
		}
	}

	/* The contrast: b's handle must open b, not a.  A decoder that
	 * ignores the inode number makes these two agree. */
	if (fh_encode(mfd, "b", hb) != 0) {
		fail("encode a second file");
	} else {
		int fa = open_by_handle_at(mfd, ha, O_RDONLY);
		int fb = open_by_handle_at(mfd, hb, O_RDONLY);

		if (fa < 0 || fb < 0) {
			fail("both handles reopen");
		} else {
			struct stat sa, sb;

			fstat(fa, &sa);
			fstat(fb, &sb);
			if (sa.st_ino != sb.st_ino &&
			    sa.st_size != sb.st_size)
				ok("the two handles open two different files");
			else
				fail("the two handles open two different files");
		}
		if (fa >= 0) close(fa);
		if (fb >= 0) close(fb);
	}

	/* (c) the negative control: a forged handle is refused. */
	if (ha->handle_bytes >= 12) {
		hbad = fh_alloc();
		memcpy(hbad, ha, sizeof(*ha) + ha->handle_bytes);
		/* Flip a bit in the middle of the 64-bit inode number. */
		hbad->f_handle[3] ^= 0x40;
		fd = open_by_handle_at(mfd, hbad, O_RDONLY);
		if (fd < 0)
			ok("a forged handle is refused");
		else {
			fail("a forged handle is refused");
			close(fd);
		}
		free(hbad);
	}

	/* (d) a directory handle reopens and lists: this runs get_parent. */
	hdir = fh_alloc();
	if (fh_encode(mfd, ".", hdir) != 0) {
		fail("encode a directory");
	} else {
		int dfd = open_by_handle_at(mfd, hdir, O_RDONLY | O_DIRECTORY);

		if (dfd < 0) {
			fail("reopen a directory by handle");
		} else {
			char dbuf[4096];
			long dn = syscall(SYS_getdents64, dfd, dbuf,
			    sizeof(dbuf));

			if (dn > 0)
				ok("a directory handle reopens and lists");
			else
				fail("a directory handle reopens and lists");
			close(dfd);
		}
	}

	/* (b) unlink: the handle goes stale, and a later file does not
	 * answer for it.  A non-recycling inode allocator is the claim. */
	snprintf(path, sizeof(path), "%s/c", argv[1]);
	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd >= 0) {
		struct file_handle *hc = fh_alloc();

		close(fd);
		if (fh_encode(mfd, "c", hc) == 0) {
			unsigned int saved = hc->handle_bytes;
			unsigned char savedb[24];

			memcpy(savedb, hc->f_handle,
			    saved < 24 ? saved : 24);
			unlink(path);
			fd = open_by_handle_at(mfd, hc, O_RDONLY);
			if (fd < 0)
				ok("a handle to a removed file is refused");
			else {
				fail("a handle to a removed file is refused");
				close(fd);
			}
			/* Create a new file and confirm it is not reachable
			 * through the stale handle's number. */
			snprintf(path, sizeof(path), "%s/d", argv[1]);
			fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
			if (fd >= 0) {
				struct stat sd;

				close(fd);
				fstatat(mfd, "d", &sd, 0);
				memcpy(hc->f_handle, savedb,
				    saved < 24 ? saved : 24);
				hc->handle_bytes = saved;
				fd = open_by_handle_at(mfd, hc, O_RDONLY);
				if (fd < 0) {
					ok("a new file does not answer a stale handle");
				} else {
					struct stat sf;

					fstat(fd, &sf);
					if (sf.st_ino != sd.st_ino)
						ok("a new file does not answer a stale handle");
					else
						fail("a new file does not answer a stale handle");
					close(fd);
				}
			}
		}
		free(hc);
	}

	/* (e) rename: a handle taken before the move still opens it. */
	snprintf(path, sizeof(path), "%s/e", argv[1]);
	fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (fd >= 0) {
		struct file_handle *he = fh_alloc();
		char p2[4096];

		write(fd, pat_a, sizeof(pat_a));
		close(fd);
		if (fh_encode(mfd, "e", he) == 0) {
			snprintf(p2, sizeof(p2), "%s/f", argv[1]);
			if (rename(path, p2) == 0) {
				fd = open_by_handle_at(mfd, he, O_RDONLY);
				if (fd >= 0) {
					n = slurp(fd, buf, sizeof(buf));
					if (n == (long)sizeof(pat_a) &&
					    memcmp(buf, pat_a, sizeof(pat_a)) == 0)
						ok("a handle survives a rename");
					else
						fail("a handle survives a rename");
					close(fd);
				} else {
					fail("a handle survives a rename");
				}
			}
		}
		free(he);
	}

	printf("fh-checks %d\n", checks);
	printf("fh-failures %d\n", failures);
	free(ha);
	free(hb);
	free(hdir);
	close(mfd);
	return (failures ? 1 : 0);
}
