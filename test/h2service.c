/* The cluster service daemon for the harness: what DragonFly's
 * `hammer2 service` does for the port, reduced to what stage 2b of
 * doc/CLUSTER_PROTOCOL_DESIGN.md reads.
 *
 * DragonFly's daemon owns the peer list and the keys: it reads the
 * volume's copyinfo[] rows, dials each remote, authenticates it against
 * /etc/hammer2/remote/<name>.pub, and hands the kernel one end of the
 * link.  This program does the same with the admission reduced to the
 * marker the note names for every stage before 5: a peer is dialed only
 * when KEYDIR holds <label>.none, the explicit plaintext opt-out, or
 * <label>.pub, which stage 5 will read; with neither the dial is refused
 * and the line says so, which is libdmsg's "auth failure: unknown host".
 *
 * The socket itself is the link.  kern_dmsg reads and writes the file it
 * is handed with kernel_read() and kernel_write(), which a TCP socket's
 * file serves as an AF_UNIX one does, so the connected socket goes to the
 * kernel by HAMMER2IOC_RECLUSTER and this program exits; nothing pumps
 * bytes in userland, and the kernel's threads hold the socket until the
 * next RECLUSTER or the unmount.  The far end is test/h2loop.c's relay,
 * which pairs the two guests' connections.
 *
 *   h2service scan MNT                           the rows, one per line
 *   h2service add  MNT --clid UUID --label L --path span:HOST:PORT
 *                      [--type master|slave]     one row; prints its copyid
 *   h2service del  MNT (--copyid N | --path P)
 *   h2service dial MNT [--keys DIR] [--copyid N] [--timeout-ms N]
 *                                                dial one admitted row
 *
 * The rows are the on-disk hammer2_volconf_t of the volume's header, so
 * `add` is a volume header write and needs a read-write mount of a PFS on
 * that volume; the kernel refuses it with EROFS otherwise.  A dial picks
 * the lowest-numbered ENABLED row whose path starts with span: unless
 * --copyid names one.  Exit 0 on success, 1 on a refusal the program
 * made or the kernel returned, 2 on a usage or environment error.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

/* The ioctl numbers and structures, from the module's own header. */
#define __packed	__attribute__((__packed__))
#include "hammer2_ioctl.h"

static void
usage(void)
{
	fprintf(stderr,
	    "usage: h2service scan MNT\n"
	    "       h2service add  MNT --clid UUID --label L --path span:HOST:PORT [--type master|slave]\n"
	    "       h2service del  MNT (--copyid N | --path P)\n"
	    "       h2service dial MNT [--keys DIR] [--copyid N] [--timeout-ms N]\n");
	exit(2);
}

/* A DCE uuid in its text form, the one `hammer2 pfs-clid` prints, into
 * the format's struct uuid: time_low, time_mid, time_hi, two clock bytes
 * and six node bytes, the first three little-endian in the struct. */
static int
uuid_parse_text(const char *s, struct uuid *u)
{
	unsigned int b[16];
	int n;

	if (strlen(s) != 36)
		return (-1);
	n = sscanf(s,
	    "%2x%2x%2x%2x-%2x%2x-%2x%2x-%2x%2x-%2x%2x%2x%2x%2x%2x",
	    &b[0], &b[1], &b[2], &b[3], &b[4], &b[5], &b[6], &b[7],
	    &b[8], &b[9], &b[10], &b[11], &b[12], &b[13], &b[14], &b[15]);
	if (n != 16)
		return (-1);
	u->time_low = (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3];
	u->time_mid = (b[4] << 8) | b[5];
	u->time_hi_and_version = (b[6] << 8) | b[7];
	u->clock_seq_hi_and_reserved = b[8];
	u->clock_seq_low = b[9];
	for (int i = 0; i < 6; i++)
		u->node[i] = b[10 + i];
	return (0);
}

static void
uuid_print(const struct uuid *u, char *out, size_t len)
{
	snprintf(out, len,
	    "%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
	    u->time_low, u->time_mid, u->time_hi_and_version,
	    u->clock_seq_hi_and_reserved, u->clock_seq_low,
	    u->node[0], u->node[1], u->node[2], u->node[3], u->node[4],
	    u->node[5]);
}

static int
open_mount(const char *mnt)
{
	int fd = open(mnt, O_RDONLY | O_DIRECTORY);
	if (fd < 0) {
		fprintf(stderr, "h2service: %s: %s\n", mnt, strerror(errno));
		exit(2);
	}
	return (fd);
}

/* One row by copyid; 0 with the row, -1 past the end or on an error. */
static int
row_get(int mfd, int copyid, struct hammer2_ioc_remote *r)
{
	memset(r, 0, sizeof(*r));
	r->copyid = copyid;
	if (ioctl(mfd, HAMMER2IOC_REMOTE_SCAN, r) < 0) {
		fprintf(stderr, "h2service: REMOTE_SCAN %d: %s\n", copyid,
		    strerror(errno));
		return (-1);
	}
	return (0);
}

static void
row_print(const struct hammer2_ioc_remote *r)
{
	struct uuid u;
	char clid[40];

	memcpy(&u, &r->copy1.pfs_clid, sizeof(u));	/* the row is packed */
	uuid_print(&u, clid, sizeof(clid));
	printf("copyid=%d flags=0x%04x type=%d clid=%s label=%.16s path=%.64s\n",
	    r->copy1.copyid, r->copy1.flags, r->copy1.remote_pfs_type, clid,
	    (const char *)r->copy1.label, (const char *)r->copy1.path);
}

static int
cmd_scan(int mfd)
{
	struct hammer2_ioc_remote r;
	int copyid = 1, n = 0;

	/* Row 0 is the volume's own; the rows start at 1 as upstream's do. */
	while (copyid > 0 && copyid < HAMMER2_COPYID_COUNT) {
		if (row_get(mfd, copyid, &r) < 0)
			return (1);
		if (r.copy1.copyid) {
			row_print(&r);
			n++;
		}
		copyid = r.nextid;
	}
	printf("h2service: %d row(s)\n", n);
	return (0);
}

static int
cmd_add(int mfd, const char *clid, const char *label, const char *path,
    const char *type)
{
	struct hammer2_ioc_remote r;
	struct uuid u;

	if (clid == NULL || label == NULL || path == NULL)
		usage();
	memset(&r, 0, sizeof(r));
	r.copyid = -1;
	if (uuid_parse_text(clid, &u) < 0) {
		fprintf(stderr, "h2service: --clid %s: not a uuid\n", clid);
		return (2);
	}
	memcpy(&r.copy1.pfs_clid, &u, sizeof(u));	/* the row is packed */
	if (strlen(label) >= sizeof(r.copy1.label) ||
	    strlen(path) >= sizeof(r.copy1.path)) {
		fprintf(stderr, "h2service: label or path too long\n");
		return (2);
	}
	strcpy((char *)r.copy1.label, label);
	strcpy((char *)r.copy1.path, path);
	r.copy1.flags = DMSG_VOLF_ENABLED;
	if (type == NULL || !strcmp(type, "master"))
		r.copy1.remote_pfs_type = HAMMER2_PFSTYPE_MASTER;
	else if (!strcmp(type, "slave"))
		r.copy1.remote_pfs_type = HAMMER2_PFSTYPE_SLAVE;
	else
		usage();
	if (ioctl(mfd, HAMMER2IOC_REMOTE_ADD, &r) < 0) {
		fprintf(stderr, "h2service: REMOTE_ADD: %s\n", strerror(errno));
		return (1);
	}
	printf("h2service: added copyid=%d\n", r.copy1.copyid);
	return (0);
}

static int
cmd_del(int mfd, int copyid, const char *path)
{
	struct hammer2_ioc_remote r;

	memset(&r, 0, sizeof(r));
	r.copyid = copyid;
	if (copyid < 0) {
		if (path == NULL || strlen(path) >= sizeof(r.copy1.path))
			usage();
		strcpy((char *)r.copy1.path, path);
	}
	if (ioctl(mfd, HAMMER2IOC_REMOTE_DEL, &r) < 0) {
		fprintf(stderr, "h2service: REMOTE_DEL: %s\n", strerror(errno));
		return (1);
	}
	printf("h2service: deleted copyid=%d\n", copyid);
	return (0);
}

/* The admission test: the marker file for the row's label. */
static const char *
admitted(const char *keys, const char *label)
{
	static char p[4096];
	struct stat st;

#ifdef H2SERVICE_NOADMIT
	/* the negative control, script/cluster-wire.sh's: every row admitted */
	return ("control");
#endif
	snprintf(p, sizeof(p), "%s/%s.none", keys, label);
	if (stat(p, &st) == 0)
		return ("none");
	snprintf(p, sizeof(p), "%s/%s.pub", keys, label);
	if (stat(p, &st) == 0)
		return ("pub");
	return (NULL);
}

/* The path names an address, not a name: the program is static and the
 * harness's peer is the host's bridge address. */
static int
dial_tcp(const char *host, const char *port, int timeout_ms)
{
	struct sockaddr_in sin;
	struct timeval tv = { timeout_ms / 1000, (timeout_ms % 1000) * 1000 };
	int fd, one = 1;

	memset(&sin, 0, sizeof(sin));
	sin.sin_family = AF_INET;
	sin.sin_port = htons((uint16_t)atoi(port));
	if (inet_pton(AF_INET, host, &sin.sin_addr) != 1 || sin.sin_port == 0) {
		fprintf(stderr, "h2service: %s:%s: not an IPv4 address and port\n",
		    host, port);
		return (-1);
	}
	fd = socket(AF_INET, SOCK_STREAM, 0);
	if (fd < 0) {
		perror("socket");
		return (-1);
	}
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
	if (connect(fd, (struct sockaddr *)&sin, sizeof(sin)) < 0) {
		fprintf(stderr, "h2service: %s:%s: %s\n", host, port, strerror(errno));
		close(fd);
		return (-1);
	}
	/* the kernel's reader blocks without a timeout; the dial's was ours */
	tv.tv_sec = tv.tv_usec = 0;
	setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
	setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
	return (fd);
}

static int
cmd_dial(int mfd, const char *keys, int want, int timeout_ms)
{
	struct hammer2_ioc_remote r;
	struct hammer2_ioc_recluster recl;
	char host[sizeof(r.copy1.path)], *colon;
	const char *how;
	int copyid = want > 0 ? want : 1, fd;

	for (;;) {
		if (copyid <= 0 || copyid >= HAMMER2_COPYID_COUNT) {
			fprintf(stderr, "h2service: no ENABLED span: row to dial\n");
			return (1);
		}
		if (row_get(mfd, copyid, &r) < 0)
			return (1);
		if (r.copy1.copyid && (r.copy1.flags & DMSG_VOLF_ENABLED) &&
		    strncmp((const char *)r.copy1.path, "span:", 5) == 0)
			break;
		if (want > 0) {
			fprintf(stderr, "h2service: copyid %d is not an ENABLED span: row\n", want);
			return (1);
		}
		copyid = r.nextid;
	}
	r.copy1.label[sizeof(r.copy1.label) - 1] = 0;
	r.copy1.path[sizeof(r.copy1.path) - 1] = 0;
	how = admitted(keys, (const char *)r.copy1.label);
	if (how == NULL) {
		fprintf(stderr, "h2service: refused copyid=%d label=%s: "
		    "auth failure: unknown host (no %s/%s.none or .pub)\n",
		    r.copy1.copyid, (const char *)r.copy1.label, keys,
		    (const char *)r.copy1.label);
		return (1);
	}
	memcpy(host, r.copy1.path + 5, sizeof(host) - 5);
	host[sizeof(host) - 5] = 0;
	colon = strrchr(host, ':');
	if (colon == NULL) {
		fprintf(stderr, "h2service: copyid=%d path %s: no port\n",
		    r.copy1.copyid, (const char *)r.copy1.path);
		return (1);
	}
	*colon = 0;
	fd = dial_tcp(host, colon + 1, timeout_ms);
	if (fd < 0)
		return (1);
	memset(&recl, 0, sizeof(recl));
	recl.fd = fd;
	if (ioctl(mfd, HAMMER2IOC_RECLUSTER, &recl) < 0) {
		fprintf(stderr, "h2service: RECLUSTER: %s\n", strerror(errno));
		close(fd);
		return (1);
	}
	close(fd);	/* the kernel holds its own reference */
	printf("h2service: dialed copyid=%d label=%s %s:%s key=%s handed in\n",
	    r.copy1.copyid, (const char *)r.copy1.label, host, colon + 1, how);
	return (0);
}

int
main(int argc, char **argv)
{
	const char *cmd, *mnt, *clid = NULL, *label = NULL, *path = NULL;
	const char *type = NULL, *keys = "/etc/hammer2/remote";
	int copyid = -1, timeout_ms = 5000, mfd, rc;

	if (argc < 3)
		usage();
	cmd = argv[1];
	mnt = argv[2];
	for (int i = 3; i + 1 < argc; i += 2) {
		const char *a = argv[i], *v = argv[i + 1];
		if (!strcmp(a, "--clid")) clid = v;
		else if (!strcmp(a, "--label")) label = v;
		else if (!strcmp(a, "--path")) path = v;
		else if (!strcmp(a, "--type")) type = v;
		else if (!strcmp(a, "--keys")) keys = v;
		else if (!strcmp(a, "--copyid")) copyid = atoi(v);
		else if (!strcmp(a, "--timeout-ms")) timeout_ms = atoi(v);
		else usage();
	}
	if ((argc - 3) % 2)
		usage();
	mfd = open_mount(mnt);
	if (!strcmp(cmd, "scan"))
		rc = cmd_scan(mfd);
	else if (!strcmp(cmd, "add"))
		rc = cmd_add(mfd, clid, label, path, type);
	else if (!strcmp(cmd, "del"))
		rc = cmd_del(mfd, copyid, path);
	else if (!strcmp(cmd, "dial"))
		rc = cmd_dial(mfd, keys, copyid, timeout_ms);
	else
		usage();
	close(mfd);
	return (rc);
}
