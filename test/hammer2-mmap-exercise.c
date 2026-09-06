/* Shared writable mmap on a HAMMER2 file: write through the mapping,
 * msync, and let the caller check the bytes reached the media. */
#include <sys/mman.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	const char *path = argc > 1 ? argv[1] : "/mnt/r/mapped";
	/* "existing": open a file already sized by the caller, without
	 * creating or truncating, so that on a full volume neither the
	 * create path nor the size change is what answers and the write
	 * fault itself is what is measured. */
	int existing = argc > 2 && strcmp(argv[2], "existing") == 0;
	size_t len = 128 * 1024;	/* two 64 KiB folios */
	char *p;
	int fd;

	fd = existing ? open(path, O_RDWR) :
	    open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
	if (fd < 0) { perror("open"); return (1); }
	if (!existing && ftruncate(fd, len) != 0) { perror("ftruncate"); return (1); }

	p = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
	if (p == MAP_FAILED) { perror("mmap shared"); return (1); }
	memset(p, 'A', len / 2);
	memset(p + len / 2, 'B', len - len / 2);
	if (msync(p, len, MS_SYNC) != 0) { perror("msync"); return (1); }
	if (munmap(p, len) != 0) { perror("munmap"); return (1); }

	p = mmap(NULL, len, PROT_READ, MAP_PRIVATE, fd, 0);
	if (p == MAP_FAILED) { perror("mmap private"); return (1); }
	printf("first %c last %c middle %c%c\n", p[0], p[len - 1],
	    p[len / 2 - 1], p[len / 2]);
	munmap(p, len);
	close(fd);
	printf("mmap test ok\n");
	return (0);
}
