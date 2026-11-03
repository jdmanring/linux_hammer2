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
 * the kernel initiates LNK_CONN|CREATE from the device's work item, after
 * RECLUSTER has returned (hammer2_link_work -> hammer2_cluster_tail ->
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
 *   tlslink   a TCP pair whose server end goes into this mount (--keyring,
 *             --admit) and client end into --attach2's (--key), --tls none
 *             for the plaintext control; prints both RECLUSTER errnos
 *   tlsclient a client intake with --key, the peer end held unanswered
 *             until EOF or --hold-max-ms; prints the errno, then whether
 *             EOF came, the bytes read and the milliseconds
 *   hsstub    a handshake agent that is not tlshd (see hsstub()), no mount
 *   tlspeer   built with -DH2_GNUTLS: a client intake with --key, this end
 *             the TLS server, then one record of --send's type on the live
 *             link; prints the handshake, the DBG_SHELL replies around the
 *             record or the EOF after it (see the action)
 *   tlsrefuse each refusal of hammer2_link_check() driven once with its
 *             own socket: PSK on an AF_UNIX pair, an unknown mode, six
 *             keys, a client with none, a server with no keyring, an
 *             unknown role, a TCP socket already carrying the tls ULP
 *             (EBUSY), and no TLS with cluster_tls_required set (the
 *             parameter set to 1 for that one call and back to 0); the
 *             errno of each printed, with the parameter read around it
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
#include <netinet/in.h>
#include <netinet/tcp.h>
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
#include <linux/genetlink.h>
#include <linux/handshake.h>
#include <linux/netlink.h>

#define __packed	__attribute__((__packed__))
#include <stddef.h>
#include "hammer2_ioctl.h"	/* HAMMER2IOC_RECLUSTER, as the module sees it */

/* -DH2_GNUTLS adds tlspeer, built on the guest against its GnuTLS, since
 * no static copy exists to build it here; every frame then goes through
 * tlss's record layer once it is set. */
#ifdef H2_GNUTLS
#include <gnutls/gnutls.h>
#include <linux/keyctl.h>
#include <sys/syscall.h>
static gnutls_session_t tlss;
#endif

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
	uint8_t tag[8];
	uint32_t reserved;
};
struct dmsg_hm2_feed {
	struct dmsg_hdr head;
	hammer2_blockref_t bref;
	uint32_t bytes, error, flags, seq;
	uint64_t rkey, tid;
	uint8_t tag[8];
	uint8_t reserved[24];
};
_Static_assert(sizeof(struct dmsg_hm2_xop) == 128, "dmsg_hm2_xop");
_Static_assert(sizeof(struct dmsg_hm2_feed) == 256, "dmsg_hm2_feed");
#define DMSG_HM2_XOP(i)	(DMSG_PROTO_HM2 | ((0x010 + (i)) << 8) | ENC(struct dmsg_hm2_xop))
#define DMSG_HM2_FEED	(DMSG_PROTO_HM2 | (0x030 << 8) | ENC(struct dmsg_hm2_feed))
/* SNAPSHOT and SNAPDEL follow the XOP table, DMSG_HM2_XOP_COUNT 21 */
#define DMSG_HM2_SNAPSHOT_IDX	21
#define DMSG_HM2_SNAPDEL_IDX	22
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

/* The same with a TLS request.  Key serials run from tls_key_base, any
 * positive value, since every call here must be refused before a serial is
 * looked up; tlsrefuse sets the base to 0 for the one refusal that reads
 * the serial's value. */
static int tls_key_base = 1000;

static int
recluster_tls(int fd_to_pass, int mode, int role, int keyring, int nkeys)
{
	struct hammer2_ioc_recluster recl;
	int i;

	memset(&recl, 0, sizeof(recl));
	recl.fd = fd_to_pass;
	recl.tls.mode = mode;
	recl.tls.role = role;
	recl.tls.keyring = keyring;
	recl.tls.nkeys = nkeys;
	for (i = 0; i < nkeys && i < HAMMER2_LINK_TLS_MAXKEYS; ++i)
		recl.tls.keys[i] = tls_key_base + i;
	if (ioctl(mfd, HAMMER2IOC_RECLUSTER, &recl) < 0)
		return (errno);
	return (0);
}

/* A connected TCP pair over IPv4 loopback; the accepted end in *peer.
 * The listener takes tcp_port, 0 for any, so a capture can name it. */
static int tcp_port;

/* A loopback listener on tcp_port (0: any), its address in *a. */
static int
tcp_listen(struct sockaddr_in *a)
{
	socklen_t al = sizeof(*a);
	int l, one = 1;

	memset(a, 0, sizeof(*a));
	a->sin_family = AF_INET;
	a->sin_addr.s_addr = htonl(INADDR_LOOPBACK);
	a->sin_port = htons(tcp_port);
	l = socket(AF_INET, SOCK_STREAM, 0);
	if (l >= 0)
		setsockopt(l, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	if (l < 0 || bind(l, (struct sockaddr *)a, sizeof(*a)) < 0 ||
	    listen(l, 1) < 0 || getsockname(l, (struct sockaddr *)a, &al) < 0) {
		perror("tcp_listen");
		exit(2);
	}
	return (l);
}

static int
tcp_pair(int *peer)
{
	struct sockaddr_in a;
	int l, c;

	l = tcp_listen(&a);
	c = socket(AF_INET, SOCK_STREAM, 0);
	if (c < 0 || connect(c, (struct sockaddr *)&a, sizeof(a)) < 0 ||
	    (*peer = accept(l, NULL, NULL)) < 0) {
		perror("tcp_pair: connect");
		exit(2);
	}
	close(l);
	return (c);
}

/* One TLS intake on a fresh TCP pair; ulp names a ULP set first. */
static int
tls_tcp(const char *ulp, int *ulp_errno, int mode, int role, int keyring,
    int nkeys)
{
	int c, p, e;

	c = tcp_pair(&p);
	if (ulp != NULL)
		*ulp_errno = setsockopt(c, IPPROTO_TCP, TCP_ULP, ulp,
		    strlen(ulp)) < 0 ? errno : 0;
	e = recluster_tls(c, mode, role, keyring, nkeys);
	close(c);
	close(p);
	return (e);
}

/* Write the parameter and read it back; "?" when either fails. */
static void
tls_required(const char *v, char *out, size_t outlen)
{
	const char *path = "/sys/module/hammer2/parameters/cluster_tls_required";
	FILE *f;

	snprintf(out, outlen, "?");
	if (v != NULL) {
		if ((f = fopen(path, "w")) == NULL)
			return;
		fputs(v, f);
		if (fclose(f) != 0)
			return;
	}
	if ((f = fopen(path, "r")) == NULL)
		return;
	if (fgets(out, (int)outlen, f) == NULL)
		snprintf(out, outlen, "?");
	fclose(f);
	out[strcspn(out, "\n")] = '\0';
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

/* A frame's bytes, through the TLS session when tlspeer set one.  A kTLS
 * peer sends no close_notify, so its FIN reads as GnuTLS's premature
 * termination, which is end of stream here as it is to read(). */
static ssize_t
xread(int fd, void *b, size_t n)
{
#ifdef H2_GNUTLS
	if (tlss != NULL) {
		ssize_t r = gnutls_record_recv(tlss, b, n);
		if (r >= 0)
			return (r);
		if (r == GNUTLS_E_PREMATURE_TERMINATION)
			return (0);
		errno = (r == GNUTLS_E_AGAIN || r == GNUTLS_E_INTERRUPTED) ?
		    EINTR : EIO;
		return (-1);
	}
#endif
	return (read(fd, b, n));
}

static ssize_t
xwrite(int fd, const void *b, size_t n)
{
#ifdef H2_GNUTLS
	if (tlss != NULL) {
		ssize_t r = gnutls_record_send(tlss, b, n);
		if (r >= 0)
			return (r);
		errno = (r == GNUTLS_E_AGAIN || r == GNUTLS_E_INTERRUPTED) ?
		    EINTR : EIO;
		return (-1);
	}
#endif
	return (write(fd, b, n));
}

/* Wait for readable within the deadline; 1 readable, 0 timed out.  Bytes
 * GnuTLS already decrypted are readable whatever the socket says. */
static int
readable(int fd, long deadline)
{
	struct pollfd pfd = { fd, POLLIN, 0 };
	long left = deadline - now_ms();
	int r;
#ifdef H2_GNUTLS
	if (tlss != NULL && gnutls_record_check_pending(tlss) > 0)
		return (1);
#endif
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

/* A DCE uuid in the text form `hammer2 pfs-clid` prints, into the
 * format's struct uuid; test/h2service.c carries the same pair. */
static int
uuid_parse_text(const char *s, struct uuid *u)
{
	unsigned int b[16];

	if (strlen(s) != 36 || sscanf(s,
	    "%2x%2x%2x%2x-%2x%2x-%2x%2x-%2x%2x-%2x%2x%2x%2x%2x%2x",
	    &b[0], &b[1], &b[2], &b[3], &b[4], &b[5], &b[6], &b[7],
	    &b[8], &b[9], &b[10], &b[11], &b[12], &b[13], &b[14], &b[15]) != 16)
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

static const char *
uuid_text(const void *p)
{
	static char out[4][40];
	static int k;
	struct uuid u;

	memcpy(&u, p, sizeof(u));
	k = (k + 1) % 4;
	snprintf(out[k], sizeof(out[k]),
	    "%08x-%04x-%04x-%02x%02x-%02x%02x%02x%02x%02x%02x",
	    u.time_low, u.time_mid, u.time_hi_and_version,
	    u.clock_seq_hi_and_reserved, u.clock_seq_low,
	    u.node[0], u.node[1], u.node[2], u.node[3], u.node[4], u.node[5]);
	return (out[k]);
}

/* Every LNK_VOLCONF a connection delivers, counted by the row's cluster id
 * wherever frame_read() sees it, so a link's rows read as a set (stage
 * 5.5: a TLS link carries only the rows of cluster ids it proved). */
#define IS_VOLCONF(cmd)	((BASE(cmd) & ~DMSGF_SIZE) == DMSG_LNK_VOLCONF_BASE)
static struct { uint8_t clid[16]; int n; } vc[16];
static int nvc, vc_over;

static void
volconf_tally(const uint8_t *clid)
{
	int i;

	for (i = 0; i < nvc && memcmp(vc[i].clid, clid, 16); i++)
		;
	if (i == nvc) {
		if (nvc == 16) {
			vc_over++;
			return;
		}
		memcpy(vc[nvc++].clid, clid, 16);
	}
	vc[i].n++;
}

static void
volconf_print(void)
{
	printf(" volconf=");
	for (int i = 0; i < nvc; i++)
		printf("%s%s:%d", i ? "," : "", uuid_text(vc[i].clid), vc[i].n);
	if (nvc == 0)
		printf("none");
	if (vc_over)
		printf(",untallied:%d", vc_over);
}

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
		n = xread(fd, buf + got, need - got);
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
			n = xread(fd, rx.aux + agot, aux - agot);
			if (n <= 0)
				return (-1);
			agot += n;
		}
		rx.auxlen = h->aux_bytes;
	}
	trace("rx cmd=%08x msgid=%016" PRIx64 " error=%u\n", h->cmd, h->msgid, h->error);
	if (IS_VOLCONF(h->cmd))
		volconf_tally(rx.body + sizeof(*h) +
		    offsetof(hammer2_volconf_t, pfs_clid));
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
		ssize_t n = xwrite(fd, buf + off, len - off);
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
		if (IS_VOLCONF(h.cmd)) {
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

/* ---- the TLS link, kernel to kernel ------------------------------------ */

/* The cluster ids a TLS intake binds its key to (the cluster note's stage
 * 5.5): the ROOT of each mount the action opened, read by PFS_LOOKUP, so
 * each end announces its own ROOT and accepts the other's. */
static struct uuid bind_clid[2];
static int nbind_clid, bind_fixed;	/* bind_fixed: --bindclid named it */

/* In place of bind_clid[], each repeatable: --sbind SLOT:UUID a server
 * intake's binding by key slot, --admit2 its second key (slot 1), and
 * --cbind UUID a client intake's binding of its one key.  What selects a
 * link's cluster ids by the key it proved is read only with two keys. */
static struct {
	int slot;
	struct uuid clid;
} sbind[HAMMER2_LINK_TLS_MAXBIND];
static struct uuid cbind[HAMMER2_LINK_TLS_MAXBIND];
static int nsbind, ncbind, admit2;

static void
bind_root(int mnt)
{
	struct hammer2_ioc_pfs pfs;

	memset(&pfs, 0, sizeof(pfs));
	strcpy(pfs.name, "ROOT");
	if (mnt < 0 || nbind_clid >= 2 || bind_fixed ||
	    ioctl(mnt, HAMMER2IOC_PFS_LOOKUP, &pfs) < 0)
		return;
	if (nbind_clid == 1 && !memcmp(&bind_clid[0], &pfs.pfs_clid,
	    sizeof(pfs.pfs_clid)))
		return;
	bind_clid[nbind_clid++] = pfs.pfs_clid;
}

/* An intake with real key serials into the mount open at mnt: a client
 * names its one key, a server its keyring and the one key it admits, each
 * bound to bind_clid[]; mode none sends neither, which is today's plaintext
 * intake. */
static int
recluster_key(int mnt, int fd, int mode, int role, int ring, int key)
{
	struct hammer2_ioc_recluster recl;
	int i;

	memset(&recl, 0, sizeof(recl));
	recl.fd = fd;
	recl.tls.mode = mode;
	if (mode == HAMMER2_LINK_TLS_PSK) {
		recl.tls.role = role;
		recl.tls.keyring = role == HAMMER2_LINK_TLS_SERVER ? ring : 0;
		recl.tls.nkeys = 1;
		recl.tls.keys[0] = key;
		for (i = 0; i < nbind_clid; ++i) {
			recl.tls.bind[i].slot = 0;
			recl.tls.bind[i].clid = bind_clid[i];
		}
		recl.tls.nbind = nbind_clid;
		if (role == HAMMER2_LINK_TLS_SERVER && nsbind) {
			if (admit2)
				recl.tls.keys[recl.tls.nkeys++] = admit2;
			for (i = 0; i < nsbind; ++i) {
				recl.tls.bind[i].slot = sbind[i].slot;
				recl.tls.bind[i].clid = sbind[i].clid;
			}
			recl.tls.nbind = nsbind;
		} else if (role == HAMMER2_LINK_TLS_CLIENT && ncbind) {
			for (i = 0; i < ncbind; ++i) {
				recl.tls.bind[i].slot = 0;
				recl.tls.bind[i].clid = cbind[i];
			}
			recl.tls.nbind = ncbind;
		}
	}
	if (ioctl(mnt, HAMMER2IOC_RECLUSTER, &recl) < 0)
		return (errno);
	return (0);
}

/* Read and drop bytes until EOF or the bound; 1 at EOF or a reset, with
 * the byte count, since a TLS peer's records are not frames. */
static int
wait_close(int fd, long ms, long *bytes)
{
	char buf[4096];
	long deadline = now_ms() + ms;
	ssize_t n;

	*bytes = 0;
	while (readable(fd, deadline)) {
		n = read(fd, buf, sizeof(buf));
		if (n == 0 || (n < 0 && errno == ECONNRESET))
			return (1);
		if (n < 0 && errno != EINTR)
			return (0);
		if (n > 0)
			*bytes += n;
	}
	return (0);
}

#ifdef H2_GNUTLS
/* The key tlshd presents for the kernel, read by serial as tlshd reads it
 * (src/tlshd/keyring.c): the payload, and the identity after the
 * description's last ';'.  The server callback hands it to GnuTLS for that
 * identity alone, counting each identity asked for. */
static gnutls_datum_t psk_key;
static char psk_id[512];
static int psk_asked, psk_match;

static int
psk_load(int key)
{
	static unsigned char buf[512];
	char d[512], *p;
	long n;

	n = syscall(SYS_keyctl, KEYCTL_DESCRIBE, key, d, sizeof(d));
	if (n <= 0 || n > (long)sizeof(d))
		return (-1);
	d[sizeof(d) - 1] = '\0';
	p = strrchr(d, ';');
	snprintf(psk_id, sizeof(psk_id), "%s", p ? p + 1 : d);
	n = syscall(SYS_keyctl, KEYCTL_READ, key, buf, sizeof(buf));
	if (n <= 0 || n > (long)sizeof(buf))
		return (-1);
	psk_key.data = buf;
	psk_key.size = (unsigned int)n;
	return (0);
}

static int
psk_cb(gnutls_session_t s, const char *user, gnutls_datum_t *k)
{
	(void)s;
	psk_asked++;
	if (strcmp(user, psk_id) || (k->data = gnutls_malloc(psk_key.size)) == NULL)
		return (-1);
	memcpy(k->data, psk_key.data, psk_key.size);
	k->size = psk_key.size;
	psk_match++;
	return (0);
}
#endif

/*
 * A handshake agent that is not tlshd: it joins the "tlshd" multicast group
 * of the "handshake" generic netlink family, which is all genl_has_listeners()
 * asks (net/handshake/netlink.c), counts the READY notifications, and with
 * accept set answers the first with HANDSHAKE_CMD_ACCEPT and holds the
 * descriptor the kernel installs, never sending DONE.  It runs until SIGTERM
 * or the bound, then prints its counts.
 */
static volatile sig_atomic_t stub_stop;

static void
stub_term(int sig)
{
	(void)sig;
	stub_stop = 1;
}

#define NLA_EACH(a, start, len)						\
	for ((a) = (struct nlattr *)(start);				\
	    (char *)(a) + NLA_HDRLEN <= (char *)(start) + (len) &&	\
	    (a)->nla_len >= NLA_HDRLEN &&				\
	    (char *)(a) + (a)->nla_len <= (char *)(start) + (len);	\
	    (a) = (struct nlattr *)((char *)(a) + NLA_ALIGN((a)->nla_len)))
#define NLA_DATA(a)	((char *)(a) + NLA_HDRLEN)
#define NLA_PLEN(a)	((int)(a)->nla_len - NLA_HDRLEN)	/* the payload's length */

static int
genl_send(int s, int family, int cmd, int attr, const void *data, int dlen)
{
	static uint32_t seq;
	char buf[256];
	struct nlmsghdr *n = (struct nlmsghdr *)buf;
	struct genlmsghdr *g = NLMSG_DATA(n);
	struct nlattr *a = (struct nlattr *)((char *)g + GENL_HDRLEN);

	memset(buf, 0, sizeof(buf));
	g->cmd = cmd;
	g->version = 1;
	a->nla_type = attr;
	a->nla_len = NLA_HDRLEN + dlen;
	memcpy(NLA_DATA(a), data, dlen);
	n->nlmsg_len = NLMSG_HDRLEN + GENL_HDRLEN + NLA_ALIGN(a->nla_len);
	n->nlmsg_type = family;
	n->nlmsg_flags = NLM_F_REQUEST;
	n->nlmsg_seq = ++seq;
	return (send(s, buf, n->nlmsg_len, 0) < 0 ? errno : 0);
}

static int
hsstub(int accept_it, long hold_ms)
{
	static char buf[16384];
	struct sigaction sa;
	struct nlmsghdr *n;
	struct nlattr *a, *g, *f;
	long deadline = now_ms() + hold_ms;
	int s, len, fam = -1, grp = -1, readies = 0, fd = -1, aerr = 0;
	uint32_t class = HANDSHAKE_HANDLER_CLASS_TLSHD;

	memset(&sa, 0, sizeof(sa));
	sa.sa_handler = stub_term;	/* no SA_RESTART: poll returns EINTR */
	sigaction(SIGTERM, &sa, NULL);
	s = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_GENERIC);
	if (s < 0 || genl_send(s, GENL_ID_CTRL, CTRL_CMD_GETFAMILY,
	    CTRL_ATTR_FAMILY_NAME, HANDSHAKE_FAMILY_NAME,
	    sizeof(HANDSHAKE_FAMILY_NAME)) != 0 ||
	    (len = recv(s, buf, sizeof(buf), 0)) < 0) {
		perror("hsstub: nlctrl");
		return (2);
	}
	for (n = (struct nlmsghdr *)buf; NLMSG_OK(n, (unsigned)len);
	    n = NLMSG_NEXT(n, len)) {
		if (n->nlmsg_type != GENL_ID_CTRL)
			continue;
		NLA_EACH(a, (char *)NLMSG_DATA(n) + GENL_HDRLEN,
		    NLMSG_PAYLOAD(n, GENL_HDRLEN)) {
			if ((a->nla_type & NLA_TYPE_MASK) == CTRL_ATTR_FAMILY_ID &&
			    NLA_PLEN(a) >= (int)sizeof(uint16_t))
				fam = *(uint16_t *)NLA_DATA(a);
			if ((a->nla_type & NLA_TYPE_MASK) != CTRL_ATTR_MCAST_GROUPS)
				continue;
			NLA_EACH(g, NLA_DATA(a), a->nla_len - NLA_HDRLEN) {
				int id = -1, match = 0;
				NLA_EACH(f, NLA_DATA(g), g->nla_len - NLA_HDRLEN) {
					if (f->nla_type == CTRL_ATTR_MCAST_GRP_ID &&
					    NLA_PLEN(f) >= (int)sizeof(uint32_t))
						id = *(uint32_t *)NLA_DATA(f);
					if (f->nla_type == CTRL_ATTR_MCAST_GRP_NAME &&
					    NLA_PLEN(f) == (int)sizeof(HANDSHAKE_MCGRP_TLSHD) &&
					    !memcmp(NLA_DATA(f), HANDSHAKE_MCGRP_TLSHD,
					    sizeof(HANDSHAKE_MCGRP_TLSHD)))
						match = 1;
				}
				if (match)
					grp = id;
			}
		}
	}
	if (fam < 0 || grp < 0 || setsockopt(s, SOL_NETLINK,
	    NETLINK_ADD_MEMBERSHIP, &grp, sizeof(grp)) < 0) {
		printf("h2attach hsstub: family=%d group=%d join_errno=%d\n",
		    fam, grp, fam < 0 || grp < 0 ? 0 : errno);
		return (2);
	}
	printf("h2attach hsstub: joined family=%d group=%d accept=%d\n", fam,
	    grp, accept_it);
	fflush(stdout);
	/* Each poll is bounded, so a SIGTERM landing just before one ends
	 * the loop within 250 ms rather than at the deadline. */
	while (!stub_stop && now_ms() < deadline) {
		long step = now_ms() + 250;
		if (!readable(s, step < deadline ? step : deadline))
			continue;
		if ((len = recv(s, buf, sizeof(buf), 0)) < 0)
			continue;
		for (n = (struct nlmsghdr *)buf; NLMSG_OK(n, (unsigned)len);
		    n = NLMSG_NEXT(n, len)) {
			struct genlmsghdr *gh = NLMSG_DATA(n);
			if (n->nlmsg_type == NLMSG_ERROR) {
				struct nlmsgerr *e = NLMSG_DATA(n);
				if (e->error)
					aerr = -e->error;
				continue;
			}
			if (n->nlmsg_type != fam)
				continue;
			if (gh->cmd == HANDSHAKE_CMD_READY) {
				readies++;
				if (accept_it && fd < 0)
					aerr = genl_send(s, fam,
					    HANDSHAKE_CMD_ACCEPT,
					    HANDSHAKE_A_ACCEPT_HANDLER_CLASS,
					    &class, sizeof(class));
			} else if (gh->cmd == HANDSHAKE_CMD_ACCEPT) {
				NLA_EACH(a, (char *)gh + GENL_HDRLEN,
				    NLMSG_PAYLOAD(n, GENL_HDRLEN)) {
					if (a->nla_type == HANDSHAKE_A_ACCEPT_SOCKFD &&
					    NLA_PLEN(a) >= (int)sizeof(int32_t))
						fd = *(int32_t *)NLA_DATA(a);
				}
				printf("h2attach hsstub: accepted fd=%d\n", fd);
				fflush(stdout);
			}
		}
	}
	printf("h2attach hsstub: readies=%d accepted=%d accept_errno=%d"
	    " stopped=%d\n", readies, fd >= 0, aerr, (int)stub_stop);
	return (0);
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
	    " hm2read hm2scanall hm2lookup hm2bmap hm2scanlhc hm2refuse hm2snap\n"
	    "       hm2 options: [--pfs LABEL] [--inum N] [--key K] [--name S]"
	    " [--count N] [--nmax N] [--out FILE] [--nocont 1]\n"
	    "       hm2snap: [--clid UUID] [--snapdel 1] [--delclid UUID]\n"
	    "       tls: tlslink --attach2 M2 --keyring R --admit K --key K2"
	    " [--tls psk|none] [--port P]; tlsclient --key K [--port P];\n"
	    "            tlslink, the server's keys: [--admit2 K] [--sbind SLOT:UUID]...,"
	    " the client's: [--cbind UUID]...;\n"
	    "            tlsaccept --key K --port P [--cbind UUID]... [--hold-max-ms N];\n"
	    "            hsstub --accept 0|1 (no --attach) [--hold-max-ms N];\n"
	    "            tlspeer --key K --send ticket|keyupdate|alert|close|none"
	    " [--port P] [--spans 1] [--linger-ms N] (-DH2_GNUTLS)\n");
	exit(2);
}

int
main(int argc, char **argv)
{
	crc_init();
	const char *mnt = NULL, *action = NULL, *tr = NULL;
	const char *pfs = "ROOT", *name = NULL, *out = NULL, *mnt2 = NULL;
	const char *tlsmode = "psk", *send = "none";
	const char *clid_opt = NULL, *delclid_opt = NULL, *bindclid_opt = NULL;
	int ring = 0, admit = 0, hsaccept = 0, snapdel = 0, spans = 0;
	long linger_ms = 0;
	struct uuid uclid, udelclid;
	uint64_t inum = 1, key = 0;
	/*
	 * The server holds a readdir count to 1..255, its frontend's own
	 * bound (hammer2_remote.c), so the default asks for that bound;
	 * --nmax 0 asks for one entry.
	 */
	int count = 1, nmax = 255;
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
		else if (!strcmp(argv[i], "--attach2")) mnt2 = argv[i + 1];
		else if (!strcmp(argv[i], "--tls")) tlsmode = argv[i + 1];
		else if (!strcmp(argv[i], "--keyring")) ring = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "--admit")) admit = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "--port")) tcp_port = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "--accept")) hsaccept = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "--send")) send = argv[i + 1];
		else if (!strcmp(argv[i], "--clid")) clid_opt = argv[i + 1];
		else if (!strcmp(argv[i], "--delclid")) delclid_opt = argv[i + 1];
		else if (!strcmp(argv[i], "--snapdel")) snapdel = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "--spans")) spans = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "--linger-ms")) linger_ms = atol(argv[i + 1]);
		else if (!strcmp(argv[i], "--bindclid")) bindclid_opt = argv[i + 1];
		else if (!strcmp(argv[i], "--admit2")) admit2 = atoi(argv[i + 1]);
		else if (!strcmp(argv[i], "--sbind")) {
			const char *u = strchr(argv[i + 1], ':');

			if (nsbind == HAMMER2_LINK_TLS_MAXBIND || u == NULL ||
			    uuid_parse_text(u + 1, &sbind[nsbind].clid) < 0)
				usage();
			sbind[nsbind++].slot = atoi(argv[i + 1]);
		} else if (!strcmp(argv[i], "--cbind")) {
			if (ncbind == HAMMER2_LINK_TLS_MAXBIND ||
			    uuid_parse_text(argv[i + 1], &cbind[ncbind]) < 0)
				usage();
			ncbind++;
		} else usage();
	}
	if ((clid_opt && uuid_parse_text(clid_opt, &uclid) < 0) ||
	    (delclid_opt && uuid_parse_text(delclid_opt, &udelclid) < 0) ||
	    (bindclid_opt && uuid_parse_text(bindclid_opt, &bind_clid[0]) < 0)) {
		fprintf(stderr, "h2attach: --clid, --delclid and --bindclid take a uuid\n");
		return (2);
	}
	if (bindclid_opt)	/* the intake binds this id alone */
		nbind_clid = bind_fixed = 1;
	(void)send;	/* read by tlspeer alone, which the static build lacks */
	(void)spans; (void)linger_ms;
	if (action != NULL && !strcmp(action, "hsstub"))
		return (hsstub(hsaccept, hold_max_ms));
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
	bind_root(mfd);

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

	if (!strcmp(action, "tlsrefuse")) {
		const int P = HAMMER2_LINK_TLS_PSK, C = HAMMER2_LINK_TLS_CLIENT;
		const int S = HAMMER2_LINK_TLS_SERVER;
		int sv[2], e_unix, e_mode, e_nkeys, e_client, e_server, e_role, e_key;
		int e_ulp, ulp_set = -1, e_req, e_plain, e_dup, e_nobind, e_keynobind, c, p;
		struct hammer2_ioc_recluster recl;
		char before[16], set[16], after[16];

		if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) { perror("socketpair"); return (2); }
		e_unix = recluster_tls(sv[0], P, C, 0, 1);
		close(sv[0]); close(sv[1]);
		e_mode = tls_tcp(NULL, NULL, 7, C, 0, 1);
		e_nkeys = tls_tcp(NULL, NULL, P, C, 0, HAMMER2_LINK_TLS_MAXKEYS + 1);
		e_client = tls_tcp(NULL, NULL, P, C, 0, 0);
		e_server = tls_tcp(NULL, NULL, P, S, 0, 1);
		e_role = tls_tcp(NULL, NULL, P, 9, 0, 1);
		tls_key_base = 0;
		e_key = tls_tcp(NULL, NULL, P, C, 0, 1);
		tls_key_base = 1000;
		e_ulp = tls_tcp("tls", &ulp_set, P, C, 0, 1);
		tls_required(NULL, before, sizeof(before));
		tls_required("1", set, sizeof(set));
		if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) { perror("socketpair"); return (2); }
		e_req = recluster_tls(sv[0], HAMMER2_LINK_TLS_NONE, C, 0, 0);
		close(sv[0]); close(sv[1]);
		tls_required("0", after, sizeof(after));
		/* Stage 5.5's intake refusals: a client binding no cluster id,
		 * and a server listing one serial twice, its binding valid. */
		e_nobind = tls_tcp(NULL, NULL, P, C, 0, 1);
		c = tcp_pair(&p);
		memset(&recl, 0, sizeof(recl));
		recl.fd = c;
		recl.tls.mode = P;
		recl.tls.role = S;
		recl.tls.keyring = 1;
		recl.tls.nkeys = 2;
		recl.tls.keys[0] = recl.tls.keys[1] = tls_key_base;
		recl.tls.nbind = 2;	/* both bound: only the duplicate refuses it */
		recl.tls.bind[0].clid = bind_clid[0];
		recl.tls.bind[1].slot = 1;
		recl.tls.bind[1].clid = bind_clid[0];
		e_dup = ioctl(mfd, HAMMER2IOC_RECLUSTER, &recl) < 0 ? errno : 0;
		close(c); close(p);
		/* a server admitting two serials, the second bound to nothing */
		c = tcp_pair(&p);
		recl.fd = c;
		recl.tls.keys[1] = tls_key_base + 1;
		recl.tls.nbind = 1;
		e_keynobind = ioctl(mfd, HAMMER2IOC_RECLUSTER, &recl) < 0 ? errno : 0;
		close(c); close(p);
		/* Plaintext with nkeys far past keys[] and every byte after the
		 * mode positive: the key checks are PSK's, so this is admitted
		 * with nothing past keys[] read.  Its link ends as sv closes,
		 * as each action's does, and the next attach replaces it. */
		if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) { perror("socketpair"); return (2); }
		memset(&recl, 0x7f, sizeof(recl));
		recl.fd = sv[0];
		recl.tls.mode = HAMMER2_LINK_TLS_NONE;
		recl.tls.nkeys = 1000;
		e_plain = ioctl(mfd, HAMMER2IOC_RECLUSTER, &recl) < 0 ? errno : 0;
		close(sv[0]); close(sv[1]);
		printf("h2attach tlsrefuse: unix=%d mode=%d nkeys=%d client=%d server=%d role=%d key=%d ulp=%d ulp_set=%d required=%d req_before=%s req_set=%s req_after=%s plain=%d nobind=%d dup=%d keynobind=%d\n",
		    e_unix, e_mode, e_nkeys, e_client, e_server, e_role, e_key, e_ulp,
		    ulp_set, e_req, before, set, after, e_plain, e_nobind, e_dup,
		    e_keynobind);
		return (e_unix == EINVAL && e_mode == EINVAL && e_nkeys == EINVAL &&
		    e_client == EINVAL && e_server == EINVAL && e_role == EINVAL &&
		    e_key == EINVAL && ulp_set == 0 && e_ulp == EBUSY && e_req == EINVAL &&
		    e_plain == 0 && !strcmp(set, "1") && !strcmp(after, "0") &&
		    e_nobind == EINVAL && e_dup == EINVAL && e_keynobind == EINVAL ? 0 : 1);
	}

	/*
	 * tlslink: one TCP pair, the server end into this mount with the keyring
	 * and the one admitted serial, the client end into --attach2's with
	 * --key; --tls none hands both in plaintext.  Both ends belong to the
	 * kernel after the two calls, so nothing here holds the link.
	 */
	if (!strcmp(action, "tlslink")) {
		int m2, c, p, e_srv, e_cli;
		int mode = strcmp(tlsmode, "none") ? HAMMER2_LINK_TLS_PSK :
		    HAMMER2_LINK_TLS_NONE;

		if (mnt2 == NULL || (m2 = open(mnt2, O_RDONLY | O_DIRECTORY)) < 0) {
			perror(mnt2 ? mnt2 : "--attach2");
			return (2);
		}
		bind_root(m2);
		c = tcp_pair(&p);
		e_srv = recluster_key(mfd, p, mode, HAMMER2_LINK_TLS_SERVER, ring,
		    admit);
		e_cli = recluster_key(m2, c, mode, HAMMER2_LINK_TLS_CLIENT, 0,
		    (int)key);
		close(c); close(p); close(m2); close(mfd);
		printf("h2attach tlslink: mode=%s port=%d server=%d client=%d\n",
		    tlsmode, tcp_port, e_srv, e_cli);
		return (e_srv == 0 && e_cli == 0 ? 0 : 1);
	}

	/*
	 * tlsclient: a client intake with --key on one end of a TCP pair, the
	 * other end held here and never answered, read until EOF or
	 * --hold-max-ms; the mount is closed first so the harness can unmount
	 * under a pending handshake.
	 */
	if (!strcmp(action, "tlsclient")) {
		int c, p, e, eof = 0;
		long bytes = 0, t0;

		c = tcp_pair(&p);
		e = recluster_key(mfd, c, HAMMER2_LINK_TLS_PSK,
		    HAMMER2_LINK_TLS_CLIENT, 0, (int)key);
		close(c); close(mfd);
		printf("h2attach tlsclient: port=%d errno=%d\n", tcp_port, e);
		fflush(stdout);
		t0 = now_ms();
		if (e == 0)
			eof = wait_close(p, hold_max_ms, &bytes);
		printf("h2attach tlsclient: eof=%d bytes=%ld ms=%ld\n", eof, bytes,
		    now_ms() - t0);
		close(p);
		return (0);
	}

	/*
	 * tlsaccept: the client end of a link whose server end a mount's
	 * cluster_fd= hands in.  Listens on --port, says so, accepts one
	 * connection within --hold-max-ms and gives it to this mount as a
	 * client intake with --key, bound to --cbind or bind_clid[].
	 */
	if (!strcmp(action, "tlsaccept")) {
		struct sockaddr_in a;
		struct pollfd pf;
		int l, p = -1, e = -1;

		l = tcp_listen(&a);
		printf("h2attach tlsaccept: listening port=%d\n",
		    ntohs(a.sin_port));
		fflush(stdout);
		pf.fd = l;
		pf.events = POLLIN;
		if (poll(&pf, 1, (int)hold_max_ms) == 1)
			p = accept(l, NULL, NULL);
		close(l);
		if (p >= 0) {
			e = recluster_key(mfd, p, HAMMER2_LINK_TLS_PSK,
			    HAMMER2_LINK_TLS_CLIENT, 0, (int)key);
			close(p);
		}
		close(mfd);
		printf("h2attach tlsaccept: accepted=%d errno=%d\n", p >= 0, e);
		return (e == 0 ? 0 : 1);
	}

#ifdef H2_GNUTLS
	/*
	 * tlspeer: a client intake with --key into this mount, and this end the
	 * TLS server, since the kernel is the client and only a TLS 1.3 server
	 * sends NewSessionTicket.  GnuTLS answers tlshd with the same key, read
	 * by serial; the frames then go through its record layer, the kernel's
	 * handshake is answered and a DBG_SHELL read as served, and --send puts
	 * one record on the link: ticket (a NewSessionTicket), keyupdate, alert
	 * (fatal internal_error), close (user_canceled, then close_notify) or
	 * none.  After ticket and none a second DBG_SHELL reads whether the
	 * link still serves; after the others the end is read until EOF.
	 */
	if (!strcmp(action, "tlspeer")) {
		gnutls_psk_server_credentials_t cred;
		gnutls_datum_t tk;
		gnutls_session_t s;
		uint32_t err1 = 0, err2 = 0;
		int c, p, e, r, sr = 0, o, f = 0, sh1 = 0, sh2 = -1, eof = -1;
		long t0;

		if (psk_load((int)key) < 0) {
			printf("h2attach tlspeer: key %d unreadable: %s\n", (int)key,
			    strerror(errno));
			return (2);
		}
		c = tcp_pair(&p);
		e = recluster_key(mfd, c, HAMMER2_LINK_TLS_PSK,
		    HAMMER2_LINK_TLS_CLIENT, 0, (int)key);
		close(c); close(mfd);
		printf("h2attach tlspeer: port=%d errno=%d\n", tcp_port, e);
		fflush(stdout);
		if (e != 0)
			return (1);
		if (gnutls_psk_allocate_server_credentials(&cred) < 0 ||
		    gnutls_init(&s, GNUTLS_SERVER | GNUTLS_NO_AUTO_SEND_TICKET) < 0 ||
		    gnutls_session_ticket_key_generate(&tk) < 0 ||
		    gnutls_session_ticket_enable_server(s, &tk) < 0 ||
		    gnutls_priority_set_direct(s,
		    "NORMAL:-VERS-ALL:+VERS-TLS1.3:+PSK:+ECDHE-PSK:+DHE-PSK", NULL) < 0) {
			printf("h2attach tlspeer: GnuTLS setup failed\n");
			return (2);
		}
		gnutls_psk_set_server_credentials_function(cred, psk_cb);
		gnutls_credentials_set(s, GNUTLS_CRD_PSK, cred);
		gnutls_transport_set_int(s, p);
		gnutls_handshake_set_timeout(s, 15000);
		do
			r = gnutls_handshake(s);
		while (r < 0 && !gnutls_error_is_fatal(r));
		printf("h2attach tlspeer: handshake=%d asked=%d match=%d cipher=%s\n",
		    r, psk_asked, psk_match,
		    r == 0 ? gnutls_cipher_get_name(gnutls_cipher_get(s)) : "none");
		fflush(stdout);
		if (r != 0)
			return (1);
		tlss = s;
		dfd = p;
		if (handshake(dfd, &hs, settle_ms) == 0) {
			frame_write(dfd, DMSG_DBG_SHELL, 0x1000, 0);
			sh1 = wait_frame(dfd, 0, DMSGF_REPLY, &err1, &o);
		}
		if (!strcmp(send, "ticket"))
			sr = gnutls_session_ticket_send(s, 1, 0);
		else if (!strcmp(send, "keyupdate"))
			sr = gnutls_session_key_update(s, 0);
		else if (!strcmp(send, "alert"))
			sr = gnutls_alert_send(s, GNUTLS_AL_FATAL,
			    GNUTLS_A_INTERNAL_ERROR);
		else if (!strcmp(send, "close") &&
		    (sr = gnutls_alert_send(s, GNUTLS_AL_WARNING,
		    GNUTLS_A_USER_CANCELED)) == 0)
			sr = gnutls_bye(s, GNUTLS_SHUT_WR);
		t0 = now_ms();
		if (!strcmp(send, "ticket") || !strcmp(send, "none")) {
			frame_write(dfd, DMSG_DBG_SHELL, 0x1001, 0);
			sh2 = wait_frame(dfd, 0, DMSGF_REPLY, &err2, &o);
		} else {
			eof = wait_eof(dfd, 10000, &f);
		}
		printf("h2attach tlspeer: send=%s rc=%d conn=%d spans=%d shell1=%d"
		    " err1=%u shell2=%d err2=%u eof=%d frames=%d ms=%ld\n", send, sr,
		    hs.conn, hs.spans, sh1, err1, sh2, err2, eof, f, now_ms() - t0);
		if ((spans || linger_ms) && eof != 1) {
			/*
			 * Stage 5.5: with --spans 1, a MASTER span for the
			 * cluster id the kernel's intake bound and one for an
			 * id it did not; then --linger-ms of whatever the
			 * kernel sends, an HM2 request among it being
			 * registration's fetch of the bound span's root, until
			 * the bound or the link's end.  Every VOLCONF of the
			 * session is printed by cluster id.
			 */
			static const uint8_t other[16] = { 0x0e, 0x7e, 0x55, 0xa5,
			    0x5a, 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77 };
			uint8_t body[432 - 64];
			struct dmsg_hdr h;
			uint32_t e1 = 0, e2 = 0, cerr = 0;
			int c2, a1, a2, o1 = 0, o2 = 0, x1, x2, hm2rx = 0, lf = 0;
			long dl;

			c2 = a1 = a2 = x1 = x2 = -1;
			if (spans) {
				c2 = proto2_prelude(dfd, &cerr, &o);
				span2_body(body, 21);
				memcpy(body, &bind_clid[0], 16);
				frame_write_body(dfd, DMSG_LNK_SPAN | DMSGF_CREATE,
				    0x3101, 0, body, sizeof(body));
				a1 = wait_frame(dfd, 0x3101, DMSGF_REPLY, &e1, &o1);
				x1 = a1 && (last_cmd & DMSGF_DELETE) == 0;
				span2_body(body, 22);
				memcpy(body, other, 16);
				frame_write_body(dfd, DMSG_LNK_SPAN | DMSGF_CREATE,
				    0x3102, 0, body, sizeof(body));
				a2 = wait_frame(dfd, 0x3102, DMSGF_REPLY, &e2, &o2);
				x2 = a2 && (last_cmd & DMSGF_DELETE) == 0;
			}
			dl = now_ms() + linger_ms;
			while (frame_read(dfd, &h, dl) == 1) {
				lf++;
				if ((h.cmd & 0x00F00000U) == DMSG_PROTO_HM2 &&
				    (h.cmd & DMSGF_CREATE) && !(h.cmd & DMSGF_REPLY))
					hm2rx++;
			}
			printf("h2attach tlspeer: spans conn2=%d bound=%s bound_open=%d"
			    " other=%s other_answered=%d other_open=%d hm2rx=%d"
			    " lingered=%d ended_ms=%ld", c2, uuid_text(&bind_clid[0]),
			    x1, uuid_text(other), a2, x2, hm2rx, lf,
			    linger_ms - (dl - now_ms()));
		} else {
			printf("h2attach tlspeer: session");
		}
		volconf_print();
		printf("\n");
		tlss = NULL;
		gnutls_deinit(s);
		close(p);
		return (0);
	}
#endif

	if (attach_pair() < 0)
		return (1);
	/* The daemon holds nothing on the mount once the descriptor is in:
	 * an open directory would make the unmount the hold action waits
	 * through EBUSY.  reconnect needs it once more and closes it then. */
	if (strcmp(action, "reconnect") && strcmp(action, "hm2snap") &&
	    strcmp(action, "quiesce")) {
		close(mfd);
		mfd = -1;
	}

	if (!strcmp(action, "close")) {
		handshake(dfd, &hs, settle_ms);
		close(dfd);
		printf("h2attach close: conn=%d volconf=%d spans=%d other=%d",
		    hs.conn, hs.volconf, hs.spans, hs.other);
		volconf_print();
		printf("\n");
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
		/* --clid names a cluster no span need announce: hm2snap's alone */
		if (!c2 || (sp < 0 && (clid_opt == NULL ||
		    strcmp(action, "hm2snap")))) {
			printf("h2attach %s: conn=1 conn_proto=%d conn2_reply=%d"
			    " spans=%d pfs_found=%d labels=", action, hs.conn_proto,
			    c2, hs.nspan, sp >= 0);
			for (i = 0; i < hs.nspan; i++)
				printf("%s%s", i ? "," : "", hs.span[i].label);
			printf("\n");
			rc = 1;
			goto hm2done;
		}
		clid = clid_opt ? (const uint8_t *)&uclid : hs.span[sp].clid;
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
		} else if (!strcmp(action, "hm2snap")) {
			/*
			 * Stage 5.5, rules 4 and 5: SNAPSHOT of the cluster
			 * --count times, the media read after each by the name
			 * the server gives it, --pfs plus .h2sync-peer; then,
			 * with --snapdel 1, SNAPDEL by the snapshot's own
			 * cluster id, or by --delclid's, and the name read
			 * again.  The link's end deletes what is left, which
			 * the harness reads in the log.
			 */
			struct hm2reply rd;
			struct hammer2_ioc_pfs lk;
			char want[sizeof(lk.name)];
			uint8_t taken[16];
			int on_media = -1, after_del = -1, ok = 0, served;

			memset(taken, 0, sizeof(taken));
			snprintf(want, sizeof(want), "%s.h2sync-peer", pfs);
			for (i = 0; i < count; i++) {
				memset(&c, 0, sizeof(c));
				hm2_request(dfd, DMSG_HM2_SNAPSHOT_IDX, clid, 1, 0,
				    0, 0, "h2attach-snap", &c, &r);
				served = r.closed && !r.refused && r.error == 0 &&
				    c.inodes == 1;
				if (served) {
					ok++;
					memcpy(taken, &c.meta.pfs_clid, 16);
				}
				memset(&lk, 0, sizeof(lk));
				memcpy(lk.name, want, sizeof(lk.name));
				on_media = ioctl(mfd, HAMMER2IOC_PFS_LOOKUP, &lk) == 0;
				printf("h2attach hm2snap: n=%d closed=%d refused=%d"
				    " error=%u inodes=%d snap_clid=%s on_media=%d"
				    " subtype=%d ms=%ld\n", i + 1, r.closed, r.refused,
				    r.error, c.inodes, served ?
				    uuid_text(&c.meta.pfs_clid) : "none", on_media,
				    on_media ? lk.pfs_subtype : -1, r.ms);
			}
			memset(&rd, 0, sizeof(rd));
			if (snapdel || delclid_opt) {
				hm2_request(dfd, DMSG_HM2_SNAPDEL_IDX, delclid_opt ?
				    (const uint8_t *)&udelclid : taken, 1, 0, 0, 0,
				    "h2attach-snap", NULL, &rd);
				memset(&lk, 0, sizeof(lk));
				memcpy(lk.name, want, sizeof(lk.name));
				after_del = ioctl(mfd, HAMMER2IOC_PFS_LOOKUP, &lk) == 0;
			}
			eof = probe_alive(dfd, settle_ms, &shell, &serr, &f);
			printf("h2attach hm2snap: done served=%d of=%d del=%d"
			    " del_clid=%s del_closed=%d del_refused=%d del_error=%u"
			    " after_del=%d eof=%d shell_reply=%d\n", ok, count,
			    snapdel || delclid_opt, delclid_opt ? delclid_opt :
			    (snapdel ? uuid_text(taken) : "none"), rd.closed,
			    rd.refused, rd.error, after_del, eof, shell);
			rc = (!eof && shell) ? 0 : 1;
			close(mfd);
			mfd = -1;
		} else {
			usage();
		}
hm2done:
		;
	} else if (!strcmp(action, "quiesce")) {
		/*
		 * Stage 5.5, rule 1: the old connection, PROTO_2 announced
		 * first when --count is 1, then a second intake on the mount,
		 * whose work holds link_hold_ms after its quiesce.  Inside the
		 * hold the old connection announces PROTO_2 and asks for a
		 * SNAPSHOT of the root, which the quiesced server must refuse
		 * at admission with LOSTLINK; then the new connection's CONN
		 * is read, and the media for ROOT.h2sync-peer.
		 */
		struct hm2reply r;
		struct hs hs2;
		struct hammer2_ioc_pfs lk;
		uint8_t body[324 - 64], rclid[16];
		uint32_t cerr = 0, e2 = 0;
		int o, c1 = -1, c2, sp = -1, on_media, n2;
		long t0, ts;

		for (int i = 0; i < hs.nspan; i++)
			if (!strcmp(hs.span[i].label, "ROOT"))
				sp = i;
		if (sp < 0) {
			printf("h2attach quiesce: no ROOT span on the old connection\n");
			return (1);
		}
		memcpy(rclid, hs.span[sp].clid, 16);
		if (count == 1)
			c1 = proto2_prelude(dfd, &cerr, &o);
		if (attach_pair() < 0)
			return (1);
		t0 = now_ms();
		usleep(300 * 1000);	/* inside the hold */
		conn2_body(body);
		frame_write_body(old_dfd, DMSG_LNK_CONN | DMSGF_CREATE, 0x2200, 0,
		    body, sizeof(body));
		c2 = wait_frame(old_dfd, 0x2200, DMSGF_REPLY, &e2, &o);
		ts = now_ms() - t0;	/* the send, not the reply: a served one waits out the hold */
		hm2_request(old_dfd, DMSG_HM2_SNAPSHOT_IDX, rclid, 1, 0, 0, 0,
		    "h2attach-snap", NULL, &r);
		printf("h2attach quiesce: prelude=%d conn2_reply=%d snap_closed=%d"
		    " snap_refused=%d snap_error=%u snap_ms=%ld since_intake_ms=%ld\n",
		    c1, c2, r.closed, r.refused, r.error, r.ms, ts);
		fflush(stdout);
		n2 = handshake(dfd, &hs2, settle_ms) == 0;
		memset(&lk, 0, sizeof(lk));
		snprintf(lk.name, sizeof(lk.name), "ROOT.h2sync-peer");
		on_media = ioctl(mfd, HAMMER2IOC_PFS_LOOKUP, &lk) == 0;
		printf("h2attach quiesce: new_conn=%d new_spans=%d on_media=%d"
		    " since_intake_ms=%ld\n", n2, hs2.spans, on_media, now_ms() - t0);
		close(mfd);
		mfd = -1;
		rc = n2 ? 0 : 1;
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
