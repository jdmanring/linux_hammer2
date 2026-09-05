/* The read-only half of the ioctl surface, exercised against a mounted PFS.
 *
 * 0.7 puts HAMMER2's ioctls behind ->unlocked_ioctl, and every result the
 * tree records for them was typed at a guest by hand. This program is
 * those keystrokes: script/test-fixtures.sh compiles it, copies it to the
 * guest and runs it on each fixture mount, comparing its output line for
 * line against a block written into the gate.
 *
 * IT COVERS THE READ-ONLY SUBSET AND NOTHING ELSE. The fixtures are
 * mounted read-only, on purpose, so snapshot create, PFS create and
 * delete, growfs and bulkfree cannot run here and stay hand-verified.
 * The gate's summary says so rather than letting "the ioctls are gated"
 * stand for all of them.
 *
 * THE COMMAND NUMBERS ARE NOT COPIED. hammer2_ioctl.h is included as the
 * module sees it, so a renumbered command breaks the build rather than
 * going quietly green against a stale constant. Userland needs two
 * definitions the kernel supplies for it: __packed, and nothing else.
 *
 * Output is one `label value` line per case, value being 0 for success or
 * the negated errno for failure. Numbers rather than names because the
 * errno numbers are the ABI and strerrorname_np() is not everywhere.
 */
#include <sys/ioctl.h>
#include <fcntl.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdint.h>
#include <limits.h>

#define __packed	__attribute__((__packed__))
#include "hammer2_ioctl.h"

/*
 * Two command numbers this header does not define, because the module
 * does not implement them and that is the point: an unknown command
 * under HAMMER2's own type letter, and a command belonging to another
 * driver entirely. Both must be refused, and the refusals are different
 * questions: the first asks whether the dispatch has a default arm, the
 * second whether the entry point checks the type before anything else.
 */
#define IOC_UNKNOWN_H	_IOWR('h', 200, int)
#define IOC_FOREIGN	_IOWR('x', 1, int)
#define IOC_ZERO_SIZE	_IO('h', 201)

static int fd;

/* The result of one ioctl, in the form the expected block is written in. */
static void
say(const char *label, int rc)
{
	printf("%s %d\n", label, rc < 0 ? -errno : 0);
}

int
main(int argc, char **argv)
{
	struct hammer2_ioc_version vers;
	struct hammer2_ioc_pfs pfs;
	struct hammer2_ioc_inode ino;
	struct hammer2_ioc_volume_list2 vol;
	int unpriv = 0, npfs = 0;

	memset(&pfs, 0, sizeof(pfs));
	memset(&ino, 0, sizeof(ino));

	if (argc > 1 && strcmp(argv[1], "-u") == 0) {
		unpriv = 1;
		argc--; argv++;
	}
	if (argc != 2) {
		fprintf(stderr, "usage: %s [-u] <mount>\n", argv[0]);
		return (2);
	}
	fd = open(argv[1], O_RDONLY | O_DIRECTORY);
	if (fd < 0) {
		fprintf(stderr, "open %s: %s\n", argv[1], strerror(errno));
		return (2);
	}

	/*
	 * VERSION_GET is one of the three commands the entry point lets an
	 * unprivileged caller issue, so it is the control that says the
	 * dropped-privilege run reached the module at all. Without it an
	 * EPERM below could equally mean the mount was never opened.
	 */
	memset(&vers, 0, sizeof(vers));
	say("version", ioctl(fd, HAMMER2IOC_VERSION_GET, &vers));
	if (!unpriv)
		printf("version-number %d\n", vers.version);

	/*
	 * The super-root scan, which is what `hammer2 pfs-list` walks:
	 * name_next carries the key of the next entry and reads as the
	 * terminator when the scan is done. Bounded, because a cycle here
	 * would otherwise hang the gate rather than fail it.
	 */
	if (!unpriv) {
		say("pfs-get", ioctl(fd, HAMMER2IOC_PFS_GET, &pfs));

		memset(&pfs, 0, sizeof(pfs));
		while (npfs < 64 &&
		    ioctl(fd, HAMMER2IOC_PFS_GET, &pfs) == 0) {
			npfs++;
			if (pfs.name_next == (hammer2_key_t)-1)
				break;
			pfs.name_key = pfs.name_next;
		}
		printf("pfs-count %d\n", npfs);

		memset(&ino, 0, sizeof(ino));
		say("inode-get", ioctl(fd, HAMMER2IOC_INODE_GET, &ino));

		/*
		 * nvolumes is the caller's capacity going in and the count
		 * coming out, so a zeroed one asks for nothing and returns
		 * success having copied nothing. The array is inline in
		 * this structure, so its capacity is fixed.
		 */
		memset(&vol, 0, sizeof(vol));
		vol.nvolumes = HAMMER2_MAX_VOLUMES;
		say("volume-list", ioctl(fd, HAMMER2IOC_VOLUME_LIST2, &vol));
		printf("volume-count %d\n", vol.nvolumes);

		/*
		 * The three refusals. The zero-size one is reachable only
		 * as root: the entry point checks the capability before
		 * the size, so an unprivileged caller is turned away by
		 * the first check and never reaches the second.
		 */
		say("unknown-h", ioctl(fd, IOC_UNKNOWN_H, &vers));
		say("foreign-type", ioctl(fd, IOC_FOREIGN, &vers));
		say("zero-size", ioctl(fd, IOC_ZERO_SIZE, &vers));
	} else {
		say("unpriv-pfs-get", ioctl(fd, HAMMER2IOC_PFS_GET, &pfs));
		say("unpriv-inode-set", ioctl(fd, HAMMER2IOC_INODE_SET, &ino));
	}

	close(fd);
	return (0);
}
