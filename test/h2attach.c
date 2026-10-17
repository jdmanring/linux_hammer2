/* The daemon's end of the cluster transport, against a mounted HAMMER2.
 *
 * DragonFly's hammer2 service hands the kernel one end of a descriptor
 * pair through HAMMER2IOC_RECLUSTER and speaks dmsg on the other.  This
 * program does the daemon's part for exactly what the kernel's message
 * core sends and expects (kern_dmsg.c, hammer2_iocom.c), one scripted
 * action per run, and prints every count it took as one line, so the
 * fleet script that drives it on the guest reads numbers rather than a
 * verdict.  test/h2loop.c is the same transport with no kernel in the
 * loop; this is the kernel in the loop.
 *
 * The handshake every action starts with is the kernel's: on RECLUSTER
 * the kernel initiates LNK_CONN|CREATE (hammer2_cluster_reconnect ->
 * kdmsg_iocom_autoinitiate); the daemon answers CONN|CREATE|REPLY with
 * REVTRANS set, since the transaction is the kernel's (kdmsg_state_msgrx
 * looks a REVTRANS frame up in the tree of transactions it initiated);
 * the kernel then dumps one LNK_HAMMER2_VOLCONF per copyinfo slot in use
 * and one LNK_SPAN|CREATE per PFS under the super-root
 * (hammer2_autodmsg), and each span is answered SPAN|CREATE|REPLY.
 *
 * Actions, each with the reading it prints:
 *   conn      the handshake, then DBG_SHELL (the kernel answers it
 *             DMSG_ERR_NOSUPP, hammer2_rcvdmsg) and a one-off PING (the
 *             kernel ignores a one-off, kdmsg_autorxmsg's cmd is built
 *             from the state's icmd and state0 has none)
 *   cancel    close the kernel's transactions from this side: the daemon's
 *             half is the reply half, so its DELETE carries REPLY and
 *             REVTRANS, and the kernel closes its own half with a DELETE
 *             on the same msgid (kdmsg_lnk_conn_reply, hammer2_lnk_span_reply
 *             through kdmsg_msg_reply, which sets REPLY only on a
 *             transaction the other side opened); the same CONN DELETE
 *             sent again draws nothing, the state being gone
 *   badmagic, badsize, badaux
 *             one malformed frame: the kernel's reader exits on it and
 *             shuts the socket down, so this end reads EOF
 *   halfclose this end stops sending: the reader sees EOF, exits, and
 *             shuts the socket, so this end reads EOF too
 *   close     this end closes; nothing to read, the script reads the
 *             kernel's threads and log
 *   reconnect a second RECLUSTER with a fresh pair while connected: a new
 *             CONN arrives on the new pair and the old pair reads EOF
 *   hold      the handshake, then neither read nor write until EOF: the
 *             script unmounts meanwhile and the kernel's uninit path has
 *             to unstick its own reader with fp_shutdown() (the ten-retry
 *             branch in kdmsg_iocom_uninit); the milliseconds to EOF are
 *             printed
 *   refuse    a pipe end and an unconnected stream socket are each handed
 *             to RECLUSTER and each must be refused EINVAL by holdfp()
 *
 * Every frame in or out is one trace line when --trace is given.  Nothing
 * here sleeps except the bounded waits, each a poll() with a deadline.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define __packed	__attribute__((__packed__))
#include "hammer2_ioctl.h"	/* HAMMER2IOC_RECLUSTER, as the module sees it */

/* The wire constants, from sys/sys/dmsg.h, which userland here has no
 * installed copy of.  The struct copies exist for their sizes only: the
 * low byte of a command is the header size in 64-byte units. */
#define DMSG_HDR_MAGIC	0x4832
#define DMSG_ALIGN	64
#define DMSGF_CREATE	0x80000000U
#define DMSGF_DELETE	0x40000000U
#define DMSGF_REPLY	0x20000000U
#define DMSGF_REVTRANS	0x08000000U
#define DMSGF_FLAGS	0xFF000000U
#define DMSGF_SIZE	0x000000FFU
#define DMSG_PROTO_LNK	0x00000000U
#define DMSG_PROTO_DBG	0x00100000U
#define DMSG_ERR_NOSUPP	0x20

struct dmsg_hdr {
	uint16_t magic, reserved02;
	uint32_t salt;
	uint64_t msgid, circuit, link_verifier;
	uint32_t cmd, aux_crc, aux_bytes, error;
	uint64_t aux_descr;
	uint32_t reserved38, hdr_crc;
};
struct dmsg_lnk_conn { struct dmsg_hdr head; uint8_t body[324 - 64]; };
struct dmsg_lnk_span { struct dmsg_hdr head; uint8_t body[432 - 64]; };
_Static_assert(sizeof(struct dmsg_hdr) == 64, "dmsg_hdr");

#define ENC(T)		((uint32_t)((sizeof(T) + DMSG_ALIGN - 1) / DMSG_ALIGN))
#define DMSG_LNK(c, T)	(DMSG_PROTO_LNK | ((c) << 8) | ENC(T))
#define DMSG_DBG(c, T)	(DMSG_PROTO_DBG | ((c) << 8) | ENC(T))
#define DMSG_LNK_PING	DMSG_LNK(0x001, struct dmsg_hdr)
#define DMSG_LNK_CONN	DMSG_LNK(0x011, struct dmsg_lnk_conn)
#define DMSG_LNK_SPAN	DMSG_LNK(0x012, struct dmsg_lnk_span)
#define DMSG_LNK_ERROR	DMSG_LNK(0xFFF, struct dmsg_hdr)
#define DMSG_LNK_VOLCONF_BASE	(DMSG_PROTO_LNK | (0x20 << 8))
#define DMSG_DBG_SHELL	DMSG_DBG(0x001, struct dmsg_hdr)
#define BASE(cmd)	((cmd) & ~DMSGF_FLAGS)

static FILE *tracef;
static int mfd = -1;		/* the mountpoint */
static int dfd = -1;		/* the daemon's end of the live pair */
static int old_dfd = -1;	/* the pair a reconnect replaced */
static long wait_ms = 2000;

static void
trace(const char *fmt, ...)
{
	va_list ap;
	if (tracef == NULL)
		return;
	va_start(ap, fmt);
	vfprintf(tracef, fmt, ap);
	va_end(ap);
}

static long
now_ms(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (ts.tv_sec * 1000L + ts.tv_nsec / 1000000L);
}

/* ---- the socket and the ioctl ------------------------------------------ */

/* Make a pair, hand one end in; the kernel takes its own reference, so
 * this end's copy of it is closed at once.  Returns the ioctl's errno. */
static int
recluster(int fd_to_pass)
{
	struct hammer2_ioc_recluster recl;
	memset(&recl, 0, sizeof(recl));
	recl.fd = fd_to_pass;
	if (ioctl(mfd, HAMMER2IOC_RECLUSTER, &recl) < 0)
		return (errno);
	return (0);
}

static int
attach_pair(void)
{
	int sv[2], e;
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
		perror("socketpair");
		exit(2);
	}
	e = recluster(sv[0]);
	close(sv[0]);
	if (e) {
		close(sv[1]);
		fprintf(stderr, "h2attach: RECLUSTER: %s\n", strerror(e));
		return (-1);
	}
	if (dfd >= 0)
		old_dfd = dfd;
	dfd = sv[1];
	trace("attach fd=%d\n", dfd);
	return (0);
}

/* ---- frames ------------------------------------------------------------- */

/* Wait for readable within the deadline; 1 readable, 0 timed out. */
static int
readable(int fd, long deadline)
{
	struct pollfd pfd = { fd, POLLIN, 0 };
	long left = deadline - now_ms();
	int r;
	if (left < 0)
		left = 0;
	r = poll(&pfd, 1, (int)left);
	return (r > 0);
}

/* Read a whole frame as kdmsg_iocom_thread_rd does: header, extended
 * header, aligned aux (the aux is read and dropped).  1 frame, 0 EOF,
 * -1 timeout or error. */
static int
frame_read(int fd, struct dmsg_hdr *h, long deadline)
{
	uint8_t buf[8192];
	size_t need, got = 0;
	ssize_t n;

	need = sizeof(*h);
	while (got < need) {
		if (!readable(fd, deadline))
			return (-1);
		n = read(fd, buf + got, need - got);
		if (n == 0)
			return (got == 0 ? 0 : -1);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			return (-1);
		}
		got += n;
		if (got == sizeof(*h)) {
			memcpy(h, buf, sizeof(*h));
			need = (h->cmd & DMSGF_SIZE) * DMSG_ALIGN;
			if (need < sizeof(*h) || need > sizeof(buf))
				return (-1);
		}
	}
	if (h->aux_bytes) {
		size_t aux = (h->aux_bytes + DMSG_ALIGN - 1) & ~(size_t)(DMSG_ALIGN - 1);
		while (aux) {
			size_t chunk = aux < sizeof(buf) ? aux : sizeof(buf);
			if (!readable(fd, deadline))
				return (-1);
			n = read(fd, buf, chunk);
			if (n <= 0)
				return (-1);
			aux -= n;
		}
	}
	trace("rx cmd=%08x msgid=%016" PRIx64 " error=%u\n", h->cmd, h->msgid, h->error);
	return (1);
}

/* Write a frame of the size its command encodes, body zero but for the
 * header; the kernel checks neither CRC and these are left zero. */
static int
frame_write(int fd, uint32_t cmd, uint64_t msgid, uint32_t error)
{
	uint8_t buf[8192];
	size_t len = (cmd & DMSGF_SIZE) * DMSG_ALIGN;
	struct dmsg_hdr *h = (struct dmsg_hdr *)buf;
	size_t off = 0;

	if (len < sizeof(*h) || len > sizeof(buf))
		len = sizeof(*h);
	memset(buf, 0, len);
	h->magic = DMSG_HDR_MAGIC;
	h->cmd = cmd;
	h->msgid = msgid;
	h->error = error;
	trace("tx cmd=%08x msgid=%016" PRIx64 " error=%u\n", cmd, msgid, error);
	while (off < len) {
		ssize_t n = write(fd, buf + off, len - off);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			return (-1);
		}
		off += n;
	}
	return (0);
}

/* A raw header, for the malformed frames. */
static int
raw_write(int fd, const struct dmsg_hdr *h)
{
	trace("tx raw magic=%04x cmd=%08x aux_bytes=%u\n", h->magic, h->cmd, h->aux_bytes);
	return (write(fd, h, sizeof(*h)) == (ssize_t)sizeof(*h) ? 0 : -1);
}

/* ---- the handshake ----------------------------------------------------- */

struct hs {
	int conn;		/* CONN|CREATE received and answered */
	uint64_t conn_msgid;
	int volconf, spans, other;
	uint64_t span_msgid;	/* one open span, for cancel */
};

/* Wait for the kernel's CONN|CREATE on fd, answer it, then collect what
 * follows for settle_ms, answering each SPAN.  Returns 0 if the CONN came. */
static int
handshake(int fd, struct hs *hs, long settle_ms)
{
	struct dmsg_hdr h;
	long deadline = now_ms() + wait_ms;
	int r;

	memset(hs, 0, sizeof(*hs));
	while ((r = frame_read(fd, &h, deadline)) == 1) {
		if (BASE(h.cmd) == DMSG_LNK_CONN && (h.cmd & DMSGF_CREATE) &&
		    !(h.cmd & DMSGF_REPLY)) {
			hs->conn = 1;
			hs->conn_msgid = h.msgid;
			frame_write(fd, DMSG_LNK_CONN | DMSGF_CREATE | DMSGF_REPLY |
			    DMSGF_REVTRANS, h.msgid, 0);
			break;
		}
		hs->other++;
	}
	if (!hs->conn)
		return (-1);
	deadline = now_ms() + settle_ms;
	while ((r = frame_read(fd, &h, deadline)) == 1) {
		if (BASE(h.cmd) == DMSG_LNK_VOLCONF_BASE) {
			hs->volconf++;
		} else if (BASE(h.cmd) == DMSG_LNK_SPAN && (h.cmd & DMSGF_CREATE) &&
		    !(h.cmd & DMSGF_REPLY)) {
			hs->spans++;
			hs->span_msgid = h.msgid;
			frame_write(fd, DMSG_LNK_SPAN | DMSGF_CREATE | DMSGF_REPLY |
			    DMSGF_REVTRANS, h.msgid, 0);
		} else {
			hs->other++;
		}
	}
	return (0);
}

/* Read until EOF or the deadline; 1 EOF seen, 0 not, frames counted. */
static int
wait_eof(int fd, long ms, int *frames)
{
	struct dmsg_hdr h;
	long deadline = now_ms() + ms;
	int r;
	*frames = 0;
	while ((r = frame_read(fd, &h, deadline)) == 1)
		(*frames)++;
	return (r == 0);
}

/* Wait for one frame with the given msgid and flags set; 1 if it came. */
static int
wait_frame(int fd, uint64_t msgid, uint32_t flags, uint32_t *error, int *others)
{
	struct dmsg_hdr h;
	long deadline = now_ms() + wait_ms;
	*others = 0;
	while (frame_read(fd, &h, deadline) == 1) {
		if (h.msgid == msgid && (h.cmd & flags) == flags) {
			if (error)
				*error = h.error;
			return (1);
		}
		(*others)++;
	}
	return (0);
}

/* ---- the actions ------------------------------------------------------- */

static void
usage(void)
{
	fprintf(stderr, "usage: h2attach --attach MOUNTPOINT --action ACTION"
	    " [--wait-ms N] [--settle-ms N] [--hold-max-ms N] [--trace FILE]\n"
	    "       actions: conn cancel badmagic badsize badaux halfclose close"
	    " reconnect hold refuse\n");
	exit(2);
}

int
main(int argc, char **argv)
{
	const char *mnt = NULL, *action = NULL, *tr = NULL;
	long settle_ms = 1000, hold_max_ms = 30000;
	struct hs hs;
	int rc = 1;

	for (int i = 1; i + 1 < argc; i += 2) {
		if (!strcmp(argv[i], "--attach")) mnt = argv[i + 1];
		else if (!strcmp(argv[i], "--action")) action = argv[i + 1];
		else if (!strcmp(argv[i], "--wait-ms")) wait_ms = atol(argv[i + 1]);
		else if (!strcmp(argv[i], "--settle-ms")) settle_ms = atol(argv[i + 1]);
		else if (!strcmp(argv[i], "--hold-max-ms")) hold_max_ms = atol(argv[i + 1]);
		else if (!strcmp(argv[i], "--trace")) tr = argv[i + 1];
		else usage();
	}
	if (mnt == NULL || action == NULL)
		usage();
	if (tr) {
		tracef = fopen(tr, "w");
		if (tracef == NULL) {
			perror(tr);
			return (2);
		}
	}
	signal(SIGPIPE, SIG_IGN);
	mfd = open(mnt, O_RDONLY | O_DIRECTORY);
	if (mfd < 0) {
		perror(mnt);
		return (2);
	}

	if (!strcmp(action, "refuse")) {
		int p[2], s, e_pipe, e_sock;
		if (pipe(p) < 0) { perror("pipe"); return (2); }
		e_pipe = recluster(p[0]);
		close(p[0]); close(p[1]);
		s = socket(AF_UNIX, SOCK_STREAM, 0);
		e_sock = recluster(s);
		close(s);
		printf("h2attach refuse: pipe_errno=%d sock_errno=%d\n", e_pipe, e_sock);
		return (e_pipe == EINVAL && e_sock == EINVAL ? 0 : 1);
	}

	if (attach_pair() < 0)
		return (1);
	/* The daemon holds nothing on the mount once the descriptor is in:
	 * an open directory would make the unmount the hold action waits
	 * through EBUSY.  reconnect needs it once more and closes it then. */
	if (strcmp(action, "reconnect")) {
		close(mfd);
		mfd = -1;
	}

	if (!strcmp(action, "close")) {
		handshake(dfd, &hs, settle_ms);
		close(dfd);
		printf("h2attach close: conn=%d volconf=%d spans=%d other=%d\n",
		    hs.conn, hs.volconf, hs.spans, hs.other);
		return (hs.conn ? 0 : 1);
	}

	if (handshake(dfd, &hs, settle_ms) < 0) {
		printf("h2attach %s: conn=0 other=%d\n", action, hs.other);
		return (1);
	}

	if (!strcmp(action, "conn")) {
		uint32_t err = 0;
		int others, pings = 0, f;
		int shell;
		frame_write(dfd, DMSG_DBG_SHELL, 0x1000, 0);
		shell = wait_frame(dfd, 0, DMSGF_REPLY, &err, &others);
		frame_write(dfd, DMSG_LNK_PING, 0x1001, 0);
		wait_eof(dfd, settle_ms, &f);
		pings = f;
		printf("h2attach conn: conn=1 volconf=%d spans=%d other=%d"
		    " shell_reply=%d shell_error=%u ping_replies=%d\n",
		    hs.volconf, hs.spans, hs.other, shell, err, pings);
		rc = (shell && err == DMSG_ERR_NOSUPP) ? 0 : 1;
	} else if (!strcmp(action, "cancel")) {
		int o1, o2, o3, f, cd, sd;
		frame_write(dfd, DMSG_LNK_ERROR | DMSGF_DELETE | DMSGF_REPLY | DMSGF_REVTRANS,
		    hs.conn_msgid, 0);
		cd = wait_frame(dfd, hs.conn_msgid, DMSGF_DELETE, NULL, &o1);
		sd = -1; o2 = 0;
		if (hs.spans) {
			frame_write(dfd, DMSG_LNK_ERROR | DMSGF_DELETE | DMSGF_REPLY | DMSGF_REVTRANS,
			    hs.span_msgid, 0);
			sd = wait_frame(dfd, hs.span_msgid, DMSGF_DELETE, NULL, &o2);
		}
		frame_write(dfd, DMSG_LNK_ERROR | DMSGF_DELETE | DMSGF_REPLY | DMSGF_REVTRANS,
		    hs.conn_msgid, 0);
		o3 = wait_frame(dfd, hs.conn_msgid, DMSGF_DELETE, NULL, &f);
		printf("h2attach cancel: conn=1 spans=%d conn_deleted=%d span_deleted=%d"
		    " second_delete_answered=%d frames_after=%d\n",
		    hs.spans, cd, sd, o3, f + o1 + o2);
		rc = (cd && sd == 1 && !o3) ? 0 : 1;
	} else if (!strcmp(action, "badmagic") || !strcmp(action, "badsize") ||
	    !strcmp(action, "badaux")) {
		struct dmsg_hdr h;
		int f, eof;
		long t0;
		memset(&h, 0, sizeof(h));
		h.magic = DMSG_HDR_MAGIC;
		h.cmd = DMSG_LNK_PING;
		if (!strcmp(action, "badmagic")) h.magic = 0x1234;
		if (!strcmp(action, "badsize")) h.cmd = DMSG_PROTO_LNK | (0x001 << 8) | 0;
		if (!strcmp(action, "badaux")) h.aux_bytes = 2 * 1024 * 1024;
		t0 = now_ms();
		raw_write(dfd, &h);
		eof = wait_eof(dfd, wait_ms, &f);
		printf("h2attach %s: conn=1 spans=%d eof=%d frames=%d ms=%ld\n",
		    action, hs.spans, eof, f, now_ms() - t0);
		rc = eof ? 0 : 1;
	} else if (!strcmp(action, "halfclose")) {
		int f, eof;
		long t0 = now_ms();
		shutdown(dfd, SHUT_WR);
		eof = wait_eof(dfd, wait_ms, &f);
		printf("h2attach halfclose: conn=1 spans=%d eof=%d frames=%d ms=%ld\n",
		    hs.spans, eof, f, now_ms() - t0);
		rc = eof ? 0 : 1;
	} else if (!strcmp(action, "reconnect")) {
		struct hs hs2;
		int f, old_eof, c2;
		if (attach_pair() < 0)
			return (1);
		close(mfd);
		mfd = -1;
		c2 = handshake(dfd, &hs2, settle_ms) == 0;
		old_eof = wait_eof(old_dfd, wait_ms, &f);
		printf("h2attach reconnect: conn=1 spans=%d conn2=%d spans2=%d"
		    " old_eof=%d old_frames=%d\n",
		    hs.spans, c2, hs2.spans, old_eof, f);
		rc = (c2 && old_eof) ? 0 : 1;
	} else if (!strcmp(action, "hold")) {
		int f, eof;
		long t0 = now_ms();
		printf("h2attach hold: conn=1 spans=%d holding\n", hs.spans);
		fflush(stdout);
		eof = wait_eof(dfd, hold_max_ms, &f);
		printf("h2attach hold: eof=%d frames=%d ms=%ld\n", eof, f, now_ms() - t0);
		rc = eof ? 0 : 1;
	} else {
		usage();
	}
	if (tracef)
		fclose(tracef);
	return (rc);
}
