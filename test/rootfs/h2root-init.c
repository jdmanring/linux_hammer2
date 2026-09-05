/* Two roles in one static binary, chosen by whether /hammer2.ko exists.
 *
 * In the initramfs it loads the module, mounts the HAMMER2 volume as the
 * new root and hands PID 1 over to the copy on that volume.  On the
 * volume it is PID 1 running off HAMMER2: it writes, syncs, reads back
 * and powers the machine off.  Every line it prints is prefixed so the
 * serial log can be read without ambiguity.
 */
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>

#define SAY(...)	do { printf("H2ROOT: " __VA_ARGS__); fflush(stdout); } while (0)

static int
load_module(const char *path)
{
	int fd = open(path, O_RDONLY);

	if (fd < 0)
		return (-1);
	if (syscall(SYS_finit_module, fd, "", 0) != 0) {
		close(fd);
		return (-1);
	}
	close(fd);
	return (0);
}

static void
be_pid1_on_hammer2(void)
{
	char buf[64];
	int fd, n;

	SAY("pid 1 is running from the hammer2 volume\n");
	mount("proc", "/proc", "proc", 0, NULL);

	fd = open("/root-write-test", O_CREAT | O_RDWR | O_TRUNC, 0644);
	if (fd < 0) {
		SAY("write open failed\n");
	} else {
		write(fd, "written by pid 1\n", 17);
		fsync(fd);
		close(fd);
		sync();
		fd = open("/root-write-test", O_RDONLY);
		n = fd < 0 ? -1 : (int)read(fd, buf, sizeof(buf) - 1);
		if (n > 0) {
			buf[n] = '\0';
			SAY("read back: %s", buf);
		} else {
			SAY("read back failed\n");
		}
		if (fd >= 0)
			close(fd);
	}

	if (mount(NULL, "/", NULL, MS_REMOUNT | MS_RDONLY, NULL) == 0)
		SAY("remounted read-only\n");
	else
		SAY("remount read-only failed\n");

	SAY("done\n");
	sync();
	reboot(RB_POWER_OFF);
	for (;;)
		pause();
}

/* The device the kernel was told to use, so this is the same question a
 * real boot asks rather than a device name compiled in here. */
static int
root_from_cmdline(char *out, size_t len)
{
	char buf[1024], *p;
	int fd, n;

	fd = open("/proc/cmdline", O_RDONLY);
	if (fd < 0)
		return (-1);
	n = (int)read(fd, buf, sizeof(buf) - 1);
	close(fd);
	if (n <= 0)
		return (-1);
	buf[n] = '\0';
	p = strstr(buf, "root=");
	if (p == NULL || (p != buf && p[-1] != ' '))
		return (-1);
	p += 5;
	n = (int)strcspn(p, " \n");
	if (n <= 0 || (size_t)n >= len)
		return (-1);
	memcpy(out, p, n);
	out[n] = '\0';
	return (0);
}

int
main(void)
{
	char root[256];

	if (access("/hammer2.ko", F_OK) != 0)
		be_pid1_on_hammer2();

	mount("proc", "/proc", "proc", 0, NULL);
	mount("sysfs", "/sys", "sysfs", 0, NULL);
	mount("devtmpfs", "/dev", "devtmpfs", 0, NULL);
	SAY("initramfs up\n");

	if (load_module("/hammer2.ko") != 0) {
		SAY("module load failed\n");
		goto out;
	}
	SAY("module loaded\n");

	if (root_from_cmdline(root, sizeof(root)) != 0) {
		SAY("no root= on the kernel command line\n");
		goto out;
	}
	SAY("root= names %s\n", root);
	if (mount(root, "/root", "hammer2", 0, NULL) != 0) {
		SAY("mount of the hammer2 root failed\n");
		goto out;
	}
	SAY("hammer2 mounted as the new root\n");

	if (chdir("/root") != 0 || mount("/root", "/", NULL, MS_MOVE, NULL) != 0 ||
	    chroot(".") != 0 || chdir("/") != 0) {
		SAY("switch to the new root failed\n");
		goto out;
	}
	SAY("switched root\n");
	execl("/sbin/init", "/sbin/init", (char *)NULL);
	SAY("exec of the new init failed: %s\n", strerror(errno));
out:
	sync();
	reboot(RB_POWER_OFF);
	return (0);
}
