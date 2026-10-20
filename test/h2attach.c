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
 * Stage 1 of doc/CLUSTER_PROTOCOL_DESIGN.md: every frame this end sends
 * carries both CRCs, and these actions play a DMSG_SPAN_PROTO_2 peer,
 * whose frames the kernel verifies.  After a frame the kernel may refuse,
 * a DBG_SHELL is sent and its NOSUPP result awaited, since "no EOF yet"
 * and "ignored and still serving" read the same until the next frame is
 * answered.
 *   proto2    this end's own LNK_CONN announcing PROTO_2, then DBG_SHELL
 *   badcrc    PROTO_2, then a PING with one header CRC bit flipped: EOF,
 *             and the DBG_SHELL after it unanswered
 *   badcrc1   PROTO_1, the same PING: consumed, the DBG_SHELL answered
 *   auxok     PROTO_2, DBG_SHELL carrying an aux with its CRC right: answered
 *   auxbad    PROTO_2, the same with one aux CRC bit flipped: EOF
 *   spanlist  PROTO_2, three PROTO_2 spans: each answered and left open
 *   span2on1  PROTO_1, one PROTO_2 span: closed, the reply carrying DELETE
 *   hm2proto1 PROTO_1, a one-off frame in the HM2 space: EOF
 *   hm2proto2 PROTO_2, the same frame: ignored, the DBG_SHELL answered
 *   hold      announces PROTO_2 and opens three spans before holding, so
 *             the unmount under it tears a populated span table down
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
#define DMSG_PROTO_HM2	0x00200000U
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
#define DMSG_HM2_PROBE	(DMSG_PROTO_HM2 | (0x010 << 8) | ENC(struct dmsg_hdr))
/* The HM2 XOP API, as src/sys/sys/dmsg.h lays it out; the on-media types
 * a reply carries come through hammer2_ioctl.h from hammer2_disk.h. */
struct dmsg_hm2_xop {
	struct dmsg_hdr head;
	uint8_t pfs_clid[16];
	uint64_t inum, key_beg, key_end;
	uint32_t resolve_flags, lookup_flags;
	int32_t nmax;
	uint32_t reserved[3];
};
struct dmsg_hm2_feed {
	struct dmsg_hdr head;
	hammer2_blockref_t bref;
	uint32_t bytes, error;
	uint8_t reserved[56];
};
_Static_assert(sizeof(struct dmsg_hm2_xop) == 128, "dmsg_hm2_xop");
_Static_assert(sizeof(struct dmsg_hm2_feed) == 256, "dmsg_hm2_feed");
#define DMSG_HM2_XOP(i)	(DMSG_PROTO_HM2 | ((0x010 + (i)) << 8) | ENC(struct dmsg_hm2_xop))
#define DMSG_HM2_FEED	(DMSG_PROTO_HM2 | (0x030 << 8) | ENC(struct dmsg_hm2_feed))
#define HM2_WINDOW	16	/* HAMMER2_XOPFIFO, feeds per continuation */
#define BASE(cmd)	((cmd) & ~DMSGF_FLAGS)

static FILE *tracef;
static int mfd = -1;		/* the mountpoint */
static int dfd = -1;		/* the daemon's end of the live pair */
static int old_dfd = -1;	/* the pair a reconnect replaced */
static long wait_ms = 2000;
static long settle_ms = 1000;
static int nocont;		/* hm2: send no continuation, so the window is read */
static int oneshot;		/* hm2: CREATE|DELETE, which the server refuses */

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

/* CRC-32C, the core's iscsi_crc32(), as test/h2loop.c carries it: over the
 * header with hdr_crc zeroed and over the aligned aux, which is what the
 * kernel verifies on a DMSG_SPAN_PROTO_2 connection and ignores on PROTO_1. */
static uint32_t crc_table[256];

static void
crc_init(void)
{
	for (uint32_t i = 0; i < 256; i++) {
		uint32_t c = i;
		for (int k = 0; k < 8; k++)
			c = (c & 1) ? (c >> 1) ^ 0x82F63B78u : c >> 1;
		crc_table[i] = c;
	}
}

static uint32_t
iscsi_crc32(const void *buf, size_t len)
{
	const uint8_t *p = buf;
	uint32_t c = ~0u;

	while (len--)
		c = crc_table[(c ^ *p++) & 0xff] ^ (c >> 8);
	return (~c);
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
/* The last frame frame_read() returned, header included, and its aux. */
static struct {
	uint8_t body[8192];
	size_t bodylen;
	uint8_t aux[65536 + 64];	/* one block at most, the design's bound */
	size_t auxlen;
} rx;

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
	memcpy(rx.body, buf, need);
	rx.bodylen = need;
	rx.auxlen = 0;
	if (h->aux_bytes) {
		size_t aux = (h->aux_bytes + DMSG_ALIGN - 1) & ~(size_t)(DMSG_ALIGN - 1);
		size_t agot = 0;
		if (aux > sizeof(rx.aux))
			return (-1);
		while (agot < aux) {
			if (!readable(fd, deadline))
				return (-1);
			n = read(fd, rx.aux + agot, aux - agot);
			if (n <= 0)
				return (-1);
			agot += n;
		}
		rx.auxlen = h->aux_bytes;
	}
	trace("rx cmd=%08x msgid=%016" PRIx64 " error=%u\n", h->cmd, h->msgid, h->error);
	return (1);
}

/* Write a frame of the size its command encodes, the body given or zero,
 * then the aux padded to 64 bytes, with both CRCs computed as libdmsg
 * computes them (lib/libdmsg/msg.c, aux_crc over the aligned aux, then
 * hdr_crc over the header with the field zeroed): a PROTO_1 kernel checks
 * neither, a PROTO_2 one checks both.  flipaux spoils aux_crc by one bit. */
static int
frame_write_full(int fd, uint32_t cmd, uint64_t msgid, uint32_t error,
    const uint8_t *body, size_t bodylen, const uint8_t *aux, size_t auxlen,
    int flipaux)
{
	uint8_t buf[8192];
	size_t len = (cmd & DMSGF_SIZE) * DMSG_ALIGN;
	size_t alen = (auxlen + DMSG_ALIGN - 1) & ~(size_t)(DMSG_ALIGN - 1);
	struct dmsg_hdr *h = (struct dmsg_hdr *)buf;
	size_t off = 0;

	if (len < sizeof(*h) || len > sizeof(buf))
		len = sizeof(*h);
	if (len + alen > sizeof(buf))
		return (-1);
	memset(buf, 0, len + alen);
	h->magic = DMSG_HDR_MAGIC;
	h->cmd = cmd;
	h->msgid = msgid;
	h->error = error;
	if (body && bodylen && sizeof(*h) + bodylen <= len)
		memcpy(buf + sizeof(*h), body, bodylen);
	if (aux && auxlen) {
		memcpy(buf + len, aux, auxlen);
		h->aux_bytes = (uint32_t)auxlen;
		h->aux_crc = iscsi_crc32(buf + len, alen) ^ (flipaux ? 1u : 0u);
	}
	h->hdr_crc = 0;
	h->hdr_crc = iscsi_crc32(buf, len);
	len += alen;
	trace("tx cmd=%08x msgid=%016" PRIx64 " error=%u aux=%zu\n", cmd, msgid,
	    error, auxlen);
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

static int
frame_write_body(int fd, uint32_t cmd, uint64_t msgid, uint32_t error,
    const uint8_t *body, size_t bodylen)
{
	return (frame_write_full(fd, cmd, msgid, error, body, bodylen, NULL, 0, 0));
}

static int
frame_write(int fd, uint32_t cmd, uint64_t msgid, uint32_t error)
{
	return (frame_write_body(fd, cmd, msgid, error, NULL, 0));
}

/* The peer's own LNK_CONN announcing DMSG_SPAN_PROTO_2, and a PROTO_2
 * span, laid out as sys/sys/dmsg.h lays them: in the CONN body peer_type
 * is at header+56 and proto_version at +58; in the SPAN body pfs_id is
 * at +16, pfs_type at +32, peer_type at +33, proto_version at +34 and
 * pfs_label at +240.  Offsets from the struct text; the header's size is
 * asserted above and the two body totals are the sizes the commands
 * encode in 64-byte units (the kernel's sizeof(dmsg_lnk_conn) is 328 with
 * padding, which rounds to the same six units as 324). */
#define DMSG_PEER_HAMMER2	3
#define DMSG_SPAN_PROTO_2	2

static void
conn2_body(uint8_t *b)
{
	memset(b, 0, 324 - 64);
	b[56] = DMSG_PEER_HAMMER2;
	b[58] = DMSG_SPAN_PROTO_2; b[59] = 0;
	memcpy(b + 48, "\x08\x00\x00\x00\x00\x00\x00\x00", 8); /* peer_mask: HAMMER2 */
	strncpy((char *)b + (324 - 64 - 128), "h2attach/proto2", 127);
}

static void
span2_body(uint8_t *b, int n)
{
	memset(b, 0, 432 - 64);
	memset(b + 16, 0x5a, 16);	/* pfs_id: distinct per span */
	b[16 + 15] = (uint8_t)n;
	b[32] = HAMMER2_PFSTYPE_MASTER;	/* hammer2_disk.h, by hammer2_ioctl.h */
	b[33] = DMSG_PEER_HAMMER2;
	b[34] = DMSG_SPAN_PROTO_2; b[35] = 0;
	snprintf((char *)b + 240, 128, "h2attach-span-%d", n);
}

static int wait_frame(int, uint64_t, uint32_t, uint32_t *, int *);

/* Announce PROTO_2 on the live pair; 1 when the kernel answered the CONN. */
static int
proto2_prelude(int fd, uint32_t *err, int *others)
{
	uint8_t body[324 - 64];

	conn2_body(body);
	frame_write_body(fd, DMSG_LNK_CONN | DMSGF_CREATE, 0x2000, 0, body,
	    sizeof(body));
	return (wait_frame(fd, 0x2000, DMSGF_REPLY, err, others));
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
	int conn_proto;		/* the kernel's LNK_CONN proto_version */
	int volconf, spans, other;
	uint64_t span_msgid;	/* one open span, for cancel */
	int nspan;		/* the kernel's HAMMER2 spans kept below */
	struct {
		uint8_t clid[16], fsid[16];
		int type, proto;
		char label[128];
	} span[8];
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
			hs->conn_proto = rx.body[122] | (rx.body[123] << 8);
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
			if (rx.body[97] == 3 && hs->nspan < 8) {	/* DMSG_PEER_HAMMER2 */
				memcpy(hs->span[hs->nspan].clid, rx.body + 64, 16);
				memcpy(hs->span[hs->nspan].fsid, rx.body + 80, 16);
				hs->span[hs->nspan].type = rx.body[96];
				hs->span[hs->nspan].proto = rx.body[98] | (rx.body[99] << 8);
				/* hammer2_update_spans() puts the PFS name in
				 * peer_label; a libdmsg span names it in pfs_label */
				memcpy(hs->span[hs->nspan].label,
				    rx.body[304] ? rx.body + 304 : rx.body + 176, 127);
				hs->nspan++;
			}
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

/* Wait for one frame with the given msgid and flags set; 1 if it came, and
 * its command is left in last_cmd, where DELETE tells a closing reply from
 * a result that leaves the transaction open. */
static uint32_t last_cmd;

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
			last_cmd = h.cmd;
			return (1);
		}
		(*others)++;
	}
	return (0);
}

/* After a frame the kernel may refuse: send DBG_SHELL and read until EOF
 * or the deadline.  Returns 1 on EOF; *shell is 1 when a result came, with
 * its error in *err (NOSUPP is the kernel still serving), *frames counts
 * everything read. */
static int
probe_alive(int fd, long ms, int *shell, uint32_t *err, int *frames)
{
	struct dmsg_hdr h;
	long deadline = now_ms() + ms;
	int r;

	*shell = 0; *err = 0; *frames = 0;
	frame_write(fd, DMSG_DBG_SHELL, 0x1003, 0);
	while ((r = frame_read(fd, &h, deadline)) == 1) {
		(*frames)++;
		if (h.msgid == 0 && (h.cmd & DMSGF_REPLY)) {
			*shell = 1;
			*err = h.error;
		}
	}
	return (r == 0);
}

/* The PROTO_2 prelude and three spans, for hold and spanlist. */
static int
open_spans(int fd, int n, uint32_t *serr)
{
	uint8_t body[432 - 64];
	int o, i, open = 0;

	for (i = 1; i <= n; i++) {
		span2_body(body, i);
		frame_write_body(fd, DMSG_LNK_SPAN | DMSGF_CREATE, 0x3000 + i,
		    0, body, sizeof(body));
		if (wait_frame(fd, 0x3000 + i, DMSGF_REPLY, serr, &o) &&
		    *serr == 0 && (last_cmd & DMSGF_DELETE) == 0)
			open++;
	}
	return (open);
}

/* The shape of every refusal reading: an optional PROTO_2 prelude, one
 * header-only frame, then probe_alive().  ended says what the kernel must
 * do with it: 1, end the connection, EOF with the DBG_SHELL unanswered; 0,
 * serve it, no EOF and the DBG_SHELL answered NOSUPP.  flipcrc spoils
 * hdr_crc by one bit, which a PROTO_2 kernel reads and a PROTO_1 kernel
 * never does.  Returns the action's exit status. */
static int
refusal(int fd, const char *action, int p2, int ended, uint32_t cmd,
    uint64_t msgid, int flipcrc)
{
	struct dmsg_hdr h;
	uint32_t cerr = 0, serr;
	int o1 = 0, c2 = 1, f, eof, shell;
	long t0;

	if (p2)
		c2 = proto2_prelude(fd, &cerr, &o1);
	memset(&h, 0, sizeof(h));
	h.magic = DMSG_HDR_MAGIC;
	h.cmd = cmd;
	h.msgid = msgid;
	h.hdr_crc = iscsi_crc32(&h, sizeof(h)) ^ (flipcrc ? 1u : 0u);
	t0 = now_ms();
	raw_write(fd, &h);
	eof = probe_alive(fd, ended ? wait_ms : settle_ms, &shell, &serr, &f);
	printf("h2attach %s: conn=1 conn2_reply=%d eof=%d shell_reply=%d"
	    " shell_error=%u frames=%d ms=%ld\n",
	    action, c2, eof, shell, serr, f, now_ms() - t0);
	if (ended)
		return ((c2 && eof && !shell) ? 0 : 1);
	return ((c2 && !eof && shell && serr == DMSG_ERR_NOSUPP) ? 0 : 1);
}

/* ---- the HM2 XOP API client, stage 2a ---------------------------------- */

/* What one request's reply looked like on the wire. */
struct hm2reply {
	int frames;		/* feed frames carrying a chain */
	int runs;		/* continuations sent */
	int maxrun;		/* most feed frames between two continuations */
	int closed;		/* the transaction's DELETE arrived */
	int refused;		/* closed by LNK_ERROR, never served */
	uint32_t error;		/* the close's error */
	long ms;
};

/* What the fed chains held, decoded by type. */
struct hm2ctx {
	FILE *out;		/* where data blocks go, for the digest */
	int print;		/* one line per chain on stdout */
	int inodes, dirents, datas, others, comp_none, full;
	hammer2_inode_meta_t meta;	/* the last inode fed */
	hammer2_blockref_t bref;	/* the last chain fed */
};

static void
hm2_feed(const struct dmsg_hm2_feed *f, const uint8_t *aux, size_t auxlen,
    struct hm2ctx *c)
{
	const hammer2_blockref_t *b = &f->bref;
	const char *name;

	c->bref = *b;
	switch (b->type) {
	case HAMMER2_BREF_TYPE_INODE:
		c->inodes++;
		if (auxlen >= sizeof(hammer2_inode_data_t))
			memcpy(&c->meta, aux, sizeof(c->meta));
		break;
	case HAMMER2_BREF_TYPE_DIRENT:
		c->dirents++;
		name = b->embed.dirent.namlen <= sizeof(b->check.buf) ?
		    b->check.buf : (const char *)aux;
		if (c->print)
			printf("ent inum=%llu type=%d key=%016llx name=%.*s\n",
			    (unsigned long long)b->embed.dirent.inum,
			    b->embed.dirent.type, (unsigned long long)b->key,
			    (int)b->embed.dirent.namlen, name);
		break;
	case HAMMER2_BREF_TYPE_DATA:
		c->datas++;
		if (HAMMER2_DEC_COMP(b->methods) == HAMMER2_COMP_NONE)
			c->comp_none++;
		if (auxlen == f->bytes)
			c->full++;
		if (c->out)
			fwrite(aux, 1, auxlen, c->out);
		/* FALLTHROUGH */
	default:
		if (b->type != HAMMER2_BREF_TYPE_DATA)
			c->others++;
		if (c->print)
			printf("blk key=%016llx type=%d bytes=%u data_off=%016llx\n",
			    (unsigned long long)b->key, b->type, f->bytes,
			    (unsigned long long)b->data_off);
		break;
	}
}

/* One request: the command with CREATE, the arguments in the body and the
 * name as aux; then every reply frame on the transaction until its DELETE,
 * a continuation after each window of HM2_WINDOW feeds, and our own DELETE
 * after the close.  A feed frame closing the transaction is a served
 * request's final error, LNK_ERROR a refusal. */
static int
hm2_request(int fd, int idx, const uint8_t clid[16], uint64_t inum,
    uint64_t key_beg, uint64_t key_end, int nmax, const char *name,
    struct hm2ctx *c, struct hm2reply *r)
{
	static uint64_t next_msgid = 0x4000;
	struct dmsg_hm2_xop q;
	struct dmsg_hdr h;
	uint64_t id = ++next_msgid;
	long t0 = now_ms(), deadline = t0 + wait_ms;
	int run = 0;

	memset(r, 0, sizeof(*r));
	memset(&q, 0, sizeof(q));
	memcpy(q.pfs_clid, clid, 16);
	q.inum = inum;
	q.key_beg = key_beg;
	q.key_end = key_end;
	q.nmax = nmax;
	frame_write_full(fd, DMSG_HM2_XOP(idx) | DMSGF_CREATE |
	    (oneshot ? DMSGF_DELETE : 0), id, 0,
	    (const uint8_t *)&q + sizeof(h), sizeof(q) - sizeof(h),
	    (const uint8_t *)name, name ? strlen(name) : 0, 0);
	while (frame_read(fd, &h, deadline) == 1) {
		if (h.msgid != id || !(h.cmd & DMSGF_REPLY))
			continue;
		if (BASE(h.cmd) == DMSG_HM2_FEED && !(h.cmd & DMSGF_DELETE)) {
			r->frames++;
			if (++run > r->maxrun)
				r->maxrun = run;
			if (c)
				hm2_feed((const struct dmsg_hm2_feed *)rx.body,
				    rx.aux, rx.auxlen, c);
			if (run == HM2_WINDOW && !nocont) {
				frame_write(fd, DMSG_HM2_XOP(idx), id, 0);
				r->runs++;
				run = 0;
				deadline = now_ms() + wait_ms;
			}
			continue;
		}
		if (h.cmd & DMSGF_DELETE) {
			r->closed = 1;
			if (BASE(h.cmd) == DMSG_HM2_FEED)
				r->error = ((const struct dmsg_hm2_feed *)rx.body)->error;
			else {
				r->refused = 1;
				r->error = h.error;
			}
			break;
		}
	}
	r->ms = now_ms() - t0;
	if (!oneshot)
		frame_write(fd, DMSG_HM2_XOP(idx) | DMSGF_DELETE, id, 0);
	return (r->closed ? 0 : -1);
}

/* ---- the actions ------------------------------------------------------- */

static void
usage(void)
{
	fprintf(stderr, "usage: h2attach --attach MOUNTPOINT --action ACTION"
	    " [--wait-ms N] [--settle-ms N] [--hold-max-ms N] [--trace FILE]\n"
	    "       actions: conn cancel badmagic badsize badaux halfclose close"
	    " reconnect hold refuse proto2 badcrc badcrc1 auxok auxbad spanlist"
	    " span2on1 hm2proto1 hm2proto2 hm2root hm2readdir hm2nresolve"
	    " hm2read hm2scanall hm2lookup hm2bmap hm2scanlhc hm2refuse\n"
	    "       hm2 options: [--pfs LABEL] [--inum N] [--key K] [--name S]"
	    " [--count N] [--nmax N] [--out FILE] [--nocont 1]\n");
	exit(2);
}

int
main(int argc, char **argv)
{
	crc_init();
	const char *mnt = NULL, *action = NULL, *tr = NULL;
	const char *pfs = "ROOT", *name = NULL, *out = NULL;
	uint64_t inum = 1, key = 0;
	int count = 1, nmax = 0;
	long hold_max_ms = 30000;
	struct hs hs;
	int rc = 1;

	for (int i = 1; i + 1 < argc; i += 2) {
		if (!strcmp(argv[i], "--attach")) mnt = argv[i + 1];
		else if (!strcmp(argv[i], "--action")) action = argv[i + 1];
		else if (!strcmp(argv[i], "--wait-ms")) wait_ms = atol(argv[i + 1]);
		else if (!strcmp(argv[i], "--settle-ms")) settle_ms = atol(argv[i + 1]);
		else if (!strcmp(argv[i], "--hold-max-ms")) hold_max_ms = atol(argv[i + 1]);
		else if (!strcmp(argv[i], "--trace")) tr = argv[i + 1];
		else if (!strcmp(argv[i], "--pfs")) pfs = argv[i + 1];
		else if (!strcmp(argv[i], "--name")) name = argv[i + 1];
		else if (!strcmp(argv[i], "--out")) out = argv[i + 1];
		else if (!strcmp(argv[i], "--inum")) inum = strtoull(argv[i + 1], NULL, 0);
		else if (!strcmp(argv[i], "--key")) key = strtoull(argv[i + 1], NULL, 0);
		else if (!strcmp(argv[i], "--count")) count = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "--nmax")) nmax = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "--nocont")) nocont = atoi(argv[i + 1]);
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
	} else if (!strcmp(action, "proto2")) {
		uint32_t cerr = 0, serr = 0;
		int o1, o2, c2, shell;
		c2 = proto2_prelude(dfd, &cerr, &o1);
		frame_write(dfd, DMSG_DBG_SHELL, 0x1000, 0);
		/* a stateless frame is answered on state 0, as conn reads it */
		shell = wait_frame(dfd, 0, DMSGF_REPLY, &serr, &o2);
		printf("h2attach proto2: conn=1 conn2_reply=%d conn2_error=%u"
		    " shell_reply=%d shell_error=%u other=%d\n",
		    c2, cerr, shell, serr, o1 + o2);
		rc = (c2 && shell && serr == DMSG_ERR_NOSUPP) ? 0 : 1;
	} else if (!strcmp(action, "badcrc") || !strcmp(action, "badcrc1")) {
		/* badcrc: PROTO_2 announced, a flipped header CRC must end the
		 * connection and the DBG_SHELL after it goes unanswered.
		 * badcrc1: PROTO_1 as today, the same frame is consumed and the
		 * DBG_SHELL answered, since upstream's core checks no CRC. */
		int p2 = !strcmp(action, "badcrc");
		rc = refusal(dfd, action, p2, p2, DMSG_LNK_PING, 0x1002, 1);
	} else if (!strcmp(action, "auxok") || !strcmp(action, "auxbad")) {
		/* A DBG_SHELL carrying an aux on a PROTO_2 connection: with its
		 * CRC right the kernel answers it NOSUPP as it answers one with
		 * no aux; with one bit flipped the connection ends. */
		static const uint8_t aux[] = "h2attach aux payload, 64-byte padded";
		uint32_t cerr = 0, aerr = 0, serr;
		int o1, o2, c2, f, eof, shell, areply, bad = !strcmp(action, "auxbad");
		long t0;
		c2 = proto2_prelude(dfd, &cerr, &o1);
		t0 = now_ms();
		frame_write_full(dfd, DMSG_DBG_SHELL, 0x1004, 0, NULL, 0, aux,
		    sizeof(aux), bad);
		areply = wait_frame(dfd, 0, DMSGF_REPLY, &aerr, &o2);
		eof = probe_alive(dfd, bad ? wait_ms : settle_ms, &shell, &serr, &f);
		printf("h2attach %s: conn=1 conn2_reply=%d aux_reply=%d aux_error=%u"
		    " eof=%d shell_reply=%d frames=%d ms=%ld\n",
		    action, c2, areply, aerr, eof, shell, f + o2, now_ms() - t0);
		if (bad)
			rc = (c2 && !areply && eof) ? 0 : 1;
		else
			rc = (c2 && areply && aerr == DMSG_ERR_NOSUPP && !eof) ? 0 : 1;
	} else if (!strcmp(action, "spanlist")) {
		uint32_t cerr = 0, serr = 0;
		int o, c2, open;
		c2 = proto2_prelude(dfd, &cerr, &o);
		open = open_spans(dfd, 3, &serr);
		printf("h2attach spanlist: conn=1 conn2_reply=%d spans_sent=3"
		    " spans_open=%d\n", c2, open);
		rc = (c2 && open == 3) ? 0 : 1;
	} else if (!strcmp(action, "span2on1")) {
		/* A PROTO_2 span on a connection whose peer announced nothing:
		 * the kernel closes it, which the reply's DELETE shows, and the
		 * table never lists its label. */
		uint8_t body[432 - 64];
		uint32_t serr = 0;
		int o, answered, closed;
		span2_body(body, 9);
		frame_write_body(dfd, DMSG_LNK_SPAN | DMSGF_CREATE, 0x3009, 0, body,
		    sizeof(body));
		answered = wait_frame(dfd, 0x3009, DMSGF_REPLY, &serr, &o);
		closed = answered && (last_cmd & DMSGF_DELETE) != 0;
		printf("h2attach span2on1: conn=1 answered=%d closed=%d error=%u\n",
		    answered, closed, serr);
		rc = closed ? 0 : 1;
	} else if (!strcmp(action, "hm2proto1") || !strcmp(action, "hm2proto2")) {
		/* A one-off frame in the HM2 space.  On a connection whose peer
		 * announced PROTO_2 it falls to hammer2_rcvdmsg's default arm,
		 * which ignores a one-off, and the DBG_SHELL after it is served;
		 * on one that announced nothing the reader ends the connection,
		 * the space being PROTO_2's vocabulary. */
		int p2 = !strcmp(action, "hm2proto2");
		rc = refusal(dfd, action, p2, !p2, DMSG_HM2_PROBE, 0x1005, 0);
	} else if (!strncmp(action, "hm2", 3)) {	/* hm2proto[12] matched above */
		/* Stage 2a: the HM2 XOP API against the mounted PFS the kernel
		 * spanned, every reply read beside what the guest itself
		 * sees of the same volume.  The kernel's CONN must announce
		 * PROTO_2 now that it serves the space. */
		uint32_t cerr = 0, serr;
		int o1, c2, i, sp = -1, f, eof, shell;
		struct hm2ctx c;
		struct hm2reply r;
		const uint8_t *clid;

		memset(&c, 0, sizeof(c));
		c2 = proto2_prelude(dfd, &cerr, &o1);
		for (i = 0; i < hs.nspan; i++)
			if (!strcmp(hs.span[i].label, pfs))
				sp = i;
		if (!c2 || sp < 0) {
			printf("h2attach %s: conn=1 conn_proto=%d conn2_reply=%d"
			    " spans=%d pfs_found=%d labels=", action, hs.conn_proto,
			    c2, hs.nspan, sp >= 0);
			for (i = 0; i < hs.nspan; i++)
				printf("%s%s", i ? "," : "", hs.span[i].label);
			printf("\n");
			rc = 1;
			goto hm2done;
		}
		clid = hs.span[sp].clid;
		if (!strcmp(action, "hm2root")) {
			int match;
			hm2_request(dfd, 0, clid, inum, 0, 0, 0, NULL, &c, &r);
			match = c.inodes == 1 &&
			    memcmp(&c.meta.pfs_fsid, hs.span[sp].fsid, 16) == 0;
			printf("h2attach hm2root: conn=1 conn_proto=%d span_proto=%d"
			    " span_type=%d found=%d frames=%d inum=%llu type=%d"
			    " pfs_type=%d fsid_match=%d closed=%d refused=%d"
			    " error=%u ms=%ld\n", hs.conn_proto, hs.span[sp].proto,
			    hs.span[sp].type, c.inodes, r.frames,
			    (unsigned long long)c.meta.inum, c.meta.type,
			    c.meta.pfs_type, match, r.closed, r.refused, r.error,
			    r.ms);
			rc = (hs.conn_proto == 2 && hs.span[sp].proto == 2 &&
			    match && r.closed && !r.refused && r.error == 0) ? 0 : 1;
		} else if (!strcmp(action, "hm2readdir")) {
			c.print = 1;
			hm2_request(dfd, 1, clid, inum, HAMMER2_DIRHASH_VISIBLE,
			    HAMMER2_KEY_MAX, nmax, NULL, &c, &r);
			printf("h2attach hm2readdir: conn=1 entries=%d frames=%d"
			    " runs=%d maxrun=%d closed=%d refused=%d error=%u"
			    " ms=%ld\n", c.dirents, r.frames, r.runs, r.maxrun,
			    r.closed, r.refused, r.error, r.ms);
			rc = (r.closed && !r.refused && r.error == 0) ? 0 : 1;
		} else if (!strcmp(action, "hm2nresolve")) {
			hm2_request(dfd, 2, clid, inum, 0, 0, 0, name, &c, &r);
			printf("h2attach hm2nresolve: conn=1 name=%s found=%d"
			    " inum=%llu size=%llu type=%d closed=%d refused=%d"
			    " error=%u ms=%ld\n", name ? name : "", c.inodes,
			    (unsigned long long)c.meta.inum,
			    (unsigned long long)c.meta.size, c.meta.type,
			    r.closed, r.refused, r.error, r.ms);
			rc = (r.closed && !r.refused) ? 0 : 1;
		} else if (!strcmp(action, "hm2read")) {
			long bytes = 0, ms = 0;
			if (out && (c.out = fopen(out, "w")) == NULL) {
				perror(out);
				rc = 2;
				goto hm2done;
			}
			memset(&r, 0, sizeof(r));
			for (i = 0; i < count; i++) {
				hm2_request(dfd, 18, clid, inum,
				    (uint64_t)i * HAMMER2_PBUFSIZE, 0, 0, NULL,
				    &c, &r);
				bytes += rx.auxlen;
				ms += r.ms;
				if (!r.closed || r.refused || r.error)
					break;
			}
			if (c.out)
				fclose(c.out);
			printf("h2attach hm2read: conn=1 blocks=%d datas=%d"
			    " comp_none=%d full=%d bytes=%ld closed=%d refused=%d"
			    " error=%u ms=%ld\n", count, c.datas, c.comp_none, c.full,
			    bytes, r.closed, r.refused, r.error, ms);
			rc = (c.datas == count && c.comp_none == count &&
			    c.full == count && r.closed && !r.refused &&
			    r.error == 0) ? 0 : 1;
		} else if (!strcmp(action, "hm2scanall")) {
			c.print = 1;
			hm2_request(dfd, 6, clid, inum, 0, HAMMER2_KEY_MAX, 0,
			    NULL, &c, &r);
			printf("h2attach hm2scanall: conn=1 chains=%d datas=%d"
			    " runs=%d maxrun=%d closed=%d refused=%d error=%u"
			    " ms=%ld\n", r.frames, c.datas, r.runs, r.maxrun,
			    r.closed, r.refused, r.error, r.ms);
			rc = (r.closed && !r.refused && r.error == 0) ? 0 : 1;
		} else if (!strcmp(action, "hm2lookup")) {
			hm2_request(dfd, 7, clid, inum, key, 0, 0, NULL, &c, &r);
			printf("h2attach hm2lookup: conn=1 found=%d key=%016llx"
			    " type=%d bytes=%u data_off=%016llx closed=%d"
			    " refused=%d error=%u ms=%ld\n", r.frames,
			    (unsigned long long)c.bref.key, c.bref.type,
			    c.datas || c.inodes || c.dirents || c.others ?
			    (unsigned)c.bref.vradix : 0,
			    (unsigned long long)c.bref.data_off, r.closed,
			    r.refused, r.error, r.ms);
			rc = (r.closed && !r.refused) ? 0 : 1;
		} else if (!strcmp(action, "hm2bmap")) {
			hm2_request(dfd, 20, clid, inum, key, 0, 0, NULL, &c, &r);
			printf("h2attach hm2bmap: conn=1 found=%d key=%016llx"
			    " data_off=%016llx closed=%d refused=%d error=%u"
			    " ms=%ld\n", r.frames, (unsigned long long)c.bref.key,
			    (unsigned long long)c.bref.data_off, r.closed,
			    r.refused, r.error, r.ms);
			rc = (r.closed && !r.refused) ? 0 : 1;
		} else if (!strcmp(action, "hm2scanlhc")) {
			c.print = 1;
			hm2_request(dfd, 5, clid, inum,
			    key & ~HAMMER2_DIRHASH_LOMASK, 0, 0, NULL, &c, &r);
			printf("h2attach hm2scanlhc: conn=1 ents=%d closed=%d"
			    " refused=%d error=%u ms=%ld\n", c.dirents, r.closed,
			    r.refused, r.error, r.ms);
			rc = (r.closed && !r.refused && r.error == 0) ? 0 : 1;
		} else if (!strcmp(action, "hm2refuse")) {
			/* A modifying command, a cluster this device has no
			 * mounted PFS of, a one-shot request and an inode that
			 * does not exist: the first three refused by LNK_ERROR
			 * NOSUPP, the fourth served and closed with an error
			 * and no chain; none of them ends the connection. */
			static const uint8_t noclid[16] = { 0xde, 0xad, 0xbe, 0xef };
			struct hm2reply r1, r2, r3, r4;
			hm2_request(dfd, 3, clid, inum, 0, 0, 0, NULL, NULL, &r1);
			hm2_request(dfd, 0, noclid, inum, 0, 0, 0, NULL, NULL, &r2);
			oneshot = 1;
			hm2_request(dfd, 0, clid, inum, 0, 0, 0, NULL, NULL, &r4);
			oneshot = 0;
			hm2_request(dfd, 0, clid, 0xfffffffULL, 0, 0, 0, NULL, NULL,
			    &r3);
			eof = probe_alive(dfd, settle_ms, &shell, &serr, &f);
			printf("h2attach hm2refuse: conn=1 mod_closed=%d"
			    " mod_refused=%d mod_error=%u nopfs_closed=%d"
			    " nopfs_refused=%d nopfs_error=%u oneshot_closed=%d"
			    " oneshot_refused=%d oneshot_error=%u noino_closed=%d"
			    " noino_refused=%d noino_error=%u noino_frames=%d"
			    " eof=%d shell_reply=%d shell_error=%u\n",
			    r1.closed, r1.refused, r1.error, r2.closed,
			    r2.refused, r2.error, r4.closed, r4.refused, r4.error,
			    r3.closed, r3.refused, r3.error, r3.frames, eof,
			    shell, serr);
			rc = (r1.closed && r1.refused && r1.error == DMSG_ERR_NOSUPP &&
			    r2.closed && r2.refused && r2.error == DMSG_ERR_NOSUPP &&
			    r4.closed && r4.refused && r4.error == DMSG_ERR_NOSUPP &&
			    r3.closed && !r3.refused && r3.error != 0 &&
			    r3.frames == 0 && !eof && shell &&
			    serr == DMSG_ERR_NOSUPP) ? 0 : 1;
		} else {
			usage();
		}
hm2done:
		;
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
		uint32_t cerr = 0, serr = 0;
		int o, c2, open, f, eof;
		long t0 = now_ms();
		c2 = proto2_prelude(dfd, &cerr, &o);
		open = open_spans(dfd, 3, &serr);
		printf("h2attach hold: conn=1 spans=%d conn2_reply=%d spans_open=%d"
		    " holding\n", hs.spans, c2, open);
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
