/* Force ->iterate_shared to resume: one entry per getdents64 call. */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/syscall.h>

struct linux_dirent64 {
	unsigned long long d_ino;
	long long d_off;
	unsigned short d_reclen;
	unsigned char d_type;
	char d_name[];
};

int
main(int argc, char **argv)
{
	char buf[64];		/* holds one entry at a time */
	int fd, n, calls = 0, seen = 0;

	fd = open(argv[1], O_RDONLY | O_DIRECTORY);
	if (fd < 0) {
		perror("open");
		return (1);
	}
	while ((n = syscall(SYS_getdents64, fd, buf, sizeof(buf))) > 0) {
		int off = 0;
		++calls;
		while (off < n) {
			struct linux_dirent64 *d = (void *)(buf + off);
			printf("  %s\n", d->d_name);
			++seen;
			off += d->d_reclen;
		}
		if (calls > 100) {
			printf("RUNAWAY: more than 100 calls\n");
			return (1);
		}
	}
	if (n < 0) {
		perror("getdents64");
		return (1);
	}
	printf("entries=%d calls=%d\n", seen, calls);
	return (0);
}
