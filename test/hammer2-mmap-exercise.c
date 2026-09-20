/* Shared writable mmap on a HAMMER2 file: write through the mapping,
 * msync, and let the caller check the bytes reached the media.
 *
 * A third argument "race" runs a mode that exists for one defect: the
 * write XOP hands the core the folio itself, so a writer that can reach
 * that folio while the core reads it makes the block's check code cover
 * bytes that were never a state of the file.  write(2) cannot do it,
 * because generic_file_write_iter() takes i_rwsem exclusively and the
 * second writer waits.  A write fault can: it goes through
 * ->page_mkwrite, which takes the folio lock and not i_rwsem, so it
 * runs against a writeback of the same folio.  This mode holds a shared
 * writable mapping of one block and faults into it in a loop while
 * another process forces writeback of the file, so the window is
 * entered rather than waited for.  What changed under the core is
 * counted by the module, not here; this is the trigger, and the module
 * parameter `folio_changed` is the reading. */
#define _GNU_SOURCE	/* sync_file_range */
#include <sys/mman.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* The race needs the writer to still be writing when writeback runs, and
 * the first shape of this got that wrong: the child faulted its rounds
 * and exited, and only then did the parent's sync() start writeback, so
 * the two never overlapped and the module's counter stayed at zero over
 * six thousand rounds on a build with the guard removed.
 *
 * This shape overlaps them.  Each writer holds a shared writable mapping
 * and stores through it in a loop with no bound until the racer stops;
 * the racer drives writeback of the same ranges with
 * sync_file_range(SYNC_FILE_RANGE_WRITE), which starts writeback and
 * returns without waiting for it, so a writeback is in flight for the
 * whole run.  Several writers on several files are used because the
 * window is one block's read and the machine has cores to spare.
 */
#define RACE_FILES 8

static int
race_mode(const char *path, int rounds)
{
	size_t len = 64 * 1024;		/* one logical block */
	char *p[RACE_FILES];
	int fd[RACE_FILES];
	pid_t pid[RACE_FILES];
	int i, j;

	for (i = 0; i < RACE_FILES; i++) {
		char name[256];

		snprintf(name, sizeof(name), "%s.%d", path, i);
		fd[i] = open(name, O_RDWR | O_CREAT | O_TRUNC, 0644);
		if (fd[i] < 0) { perror("open"); return (1); }
		if (ftruncate(fd[i], len) != 0) { perror("ftruncate"); return (1); }
		p[i] = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_SHARED,
		    fd[i], 0);
		if (p[i] == MAP_FAILED) { perror("mmap shared"); return (1); }
	}

	for (i = 0; i < RACE_FILES; i++) {
		pid[i] = fork();
		if (pid[i] < 0) { perror("fork"); return (1); }
		if (pid[i] == 0) {
			/* The writer: store through the mapping for as long
			 * as the racer runs.  This is the path that reaches
			 * the folio through ->page_mkwrite rather than
			 * write(), and therefore the one the stable-writes
			 * wait is there to hold off. */
			unsigned int n = 0;

			while (1) {
				memset(p[i], 'A' + (n % 26), len);
				n++;
			}
		}
	}
	/* The racer: writeback in flight over the same ranges, so a
	 * writeback is running while the writers above are storing. */
	for (j = 0; j < rounds; j++) {
		for (i = 0; i < RACE_FILES; i++)
			sync_file_range(fd[i], 0, len,
			    SYNC_FILE_RANGE_WRITE);
	}
	for (i = 0; i < RACE_FILES; i++) {
		kill(pid[i], SIGKILL);
		waitpid(pid[i], NULL, 0);
		munmap(p[i], len);
		close(fd[i]);
	}
	printf("race mode ran %d round(s) over %d file(s)\n", rounds,
	    RACE_FILES);
	return (0);
}

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

	if (argc > 2 && strcmp(argv[2], "race") == 0)
		return (race_mode(path, argc > 3 ? atoi(argv[3]) : 2000));

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
