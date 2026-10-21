/* The deterministic loopback for the cluster transport.
 *
 * DragonFly's kernel never opens a cluster connection.  The userland
 * daemon, hammer2 service, makes a descriptor pair, hands one end to the
 * kernel through HAMMER2IOC_RECLUSTER, and runs the network side on the
 * other.  kern_dmsg.c then reads and writes dmsg frames on that one
 * descriptor from two kernel threads and calls nothing else of the
 * transport than read, write, shutdown and release.  This program sits
 * where the daemon sits: it holds the daemon's end of one AF_UNIX stream
 * socketpair and decides, frame by frame, what the other end sees.
 *
 * The kernel is not in the loop here.  The kernel's end is played by two
 * roles in this process: a generator that
 * writes frames the way kdmsg_iocom_thread_wr does (header, then aligned
 * aux), and a receiver that reads them the way kdmsg_iocom_thread_rd does
 * (header, extended header, aligned aux) and checks what the kernel checks
 * and, unlike the kernel, both CRCs.  The simulator in between reads each
 * frame off the daemon's end and either delivers it after a virtual delay,
 * drops it, or delivers it twice; at scripted frame indices it half-closes,
 * disconnects or reconnects the socket.  Delay is virtual: a frame sent at
 * tick i is queued for tick i + d and the queue drains in tick order, so
 * reordering is what differing delays produce and nothing here sleeps.
 *
 * Every decision is drawn from one seeded generator and written as one
 * trace line, so a run is a function of its arguments and nothing else.
 * --replay FILE reads the arguments out of a trace's first line, runs them
 * again and requires the new trace to equal the old one byte for byte; a
 * trace someone edited fails that comparison, which is how the replay is
 * known to read the file rather than agree with it.
 *
 * What a fake pass looks like, so the gate can rule it out: a simulator
 * that delivers everything prints the same summary as one whose loss knob
 * works when loss is 0, so the gate reads the dropped count with loss on
 * and requires it non-zero; a receiver that ignores CRCs passes every
 * frame, so --corrupt-at flips one bit and the gate requires one rejection.
 *
 * The kernel is in the loop in test/h2attach.c, which hands a pair's end
 * to a mounted HAMMER2 through HAMMER2IOC_RECLUSTER and plays the daemon
 * against the carried message core; this program keeps the generator and
 * receiver so the transport's own behaviour is measured with no kernel.
 *
 * Two kernels are in the loop under --relay PORT: the program listens on
 * the host, accepts two connections, the first A and the second B, and
 * relays frames between them under the same seeded knobs, so delay is
 * real milliseconds now, loss and duplication draw from the same
 * generator, --partition-at K with --partition-len N drops every frame
 * both ways from the Kth to the (K+N)th, and --disconnect-at K closes the
 * pair at the Kth frame, after which the next two connections are the next
 * pair.  --rekey-data 1 moves the key of the first fed data block that
 * carries its data 64 KiB up and signs the header again, so the frame
 * passes every CRC and only the receiving kernel's range check can
 * refuse it; the wire harness's control requires that refusal.  Every
 * decision is one trace line as before, under a header that
 * names the mode and the knobs.  The trace records what the relay did and
 * is not a replay: two live kernels do not send the same frames twice, so
 * --replay refuses a relay trace rather than agreeing with it.  Stage 2b
 * of doc/CLUSTER_PROTOCOL_DESIGN.md is what runs on it.
 *
 * Frame layout and CRC convention are DragonFly's (sys/sys/dmsg.h,
 * sys/libkern/icrc32.c): 64-byte header, magic 0x4832, size field
 * (cmd & 0xff) in 64-byte units, aux aligned to 64, hdr_crc over the
 * aligned header with its own field zeroed, aux_crc over the aligned aux,
 * both CRC-32C with ~0 in and ~0 out.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <inttypes.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#define DMSG_HDR_MAGIC	0x4832
#define DMSG_ALIGN	64
#define DMSG_ALIGNMASK	(DMSG_ALIGN - 1)
#define DMSG_DOALIGN(n)	(((n) + DMSG_ALIGNMASK) & ~DMSG_ALIGNMASK)
#define DMSGF_SIZE	0x000000FF
#define DMSG_HDR_MAX	2048		/* kern_dmsg's bound on a header */
#define AUX_CAP		65536	/* one frame fits a default socket buffer; see validate() */

struct dmsg_hdr {
	uint16_t magic;
	uint16_t reserved02;
	uint32_t salt;
	uint64_t msgid;
	uint64_t circuit;
	uint64_t link_verifier;
	uint32_t cmd;
	uint32_t aux_crc;
	uint32_t aux_bytes;
	uint32_t error;
	uint64_t aux_descr;
	uint32_t reserved38;
	uint32_t hdr_crc;
};

/* ---- CRC-32C, table built at start ------------------------------------ */

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

/* ---- the one random source ------------------------------------------- */

static uint64_t rng_state;

static uint64_t
rng(void)
{
	/* xorshift64*; the state is never 0 because the seed is or'd with 1 */
	uint64_t x = rng_state;
	x ^= x >> 12;
	x ^= x << 25;
	x ^= x >> 27;
	rng_state = x;
	return (x * 0x2545F4914F6CDD1DULL);
}

static double
rng_unit(void)
{
	return ((rng() >> 11) * (1.0 / 9007199254740992.0));
}

/* ---- arguments --------------------------------------------------------- */

static struct {
	uint64_t seed;
	long frames, aux_max, delay_max;
	double loss, dup;
	long halfclose_at, disconnect_at, reconnect_at, corrupt_at;
	const char *trace, *replay;
	int relay;			/* a TCP port: the two-kernel relay */
	long partition_at, partition_len;
	int rekey_data;		/* the relay moves one data feed's key */
} opt = { 1, 100, 4096, 0, 0.0, 0.0, -1, -1, -1, -1, NULL, NULL, 0, -1, 0, 0 };

static void
usage(void)
{
	fprintf(stderr,
	    "usage: h2loop [--seed N] [--frames N] [--aux-max N] [--delay-max N]\n"
	    "              [--loss P] [--dup P] [--halfclose-at K]\n"
	    "              [--disconnect-at K] [--reconnect-at K] [--corrupt-at K]\n"
	    "              [--trace FILE] [--replay FILE]\n"
	    "       h2loop --relay PORT [--seed N] [--delay-max MS] [--loss P] [--dup P]\n"
	    "              [--partition-at K --partition-len N] [--disconnect-at K]\n"
	    "              [--corrupt-at K] [--rekey-data 1] [--trace FILE]\n");
	exit(2);
}

static void validate(void);

static void
parse_args(int argc, char **argv)
{
	for (int i = 1; i < argc; i++) {
		const char *a = argv[i];
		const char *v = (i + 1 < argc) ? argv[i + 1] : NULL;
		if (v == NULL)
			usage();
		if (!strcmp(a, "--seed")) opt.seed = strtoull(v, NULL, 0);
		else if (!strcmp(a, "--frames")) opt.frames = atol(v);
		else if (!strcmp(a, "--aux-max")) opt.aux_max = atol(v);
		else if (!strcmp(a, "--delay-max")) opt.delay_max = atol(v);
		else if (!strcmp(a, "--loss")) opt.loss = atof(v);
		else if (!strcmp(a, "--dup")) opt.dup = atof(v);
		else if (!strcmp(a, "--halfclose-at")) opt.halfclose_at = atol(v);
		else if (!strcmp(a, "--disconnect-at")) opt.disconnect_at = atol(v);
		else if (!strcmp(a, "--reconnect-at")) opt.reconnect_at = atol(v);
		else if (!strcmp(a, "--corrupt-at")) opt.corrupt_at = atol(v);
		else if (!strcmp(a, "--trace")) opt.trace = v;
		else if (!strcmp(a, "--replay")) opt.replay = v;
		else if (!strcmp(a, "--relay")) opt.relay = atoi(v);
		else if (!strcmp(a, "--partition-at")) opt.partition_at = atol(v);
		else if (!strcmp(a, "--partition-len")) opt.partition_len = atol(v);
		else if (!strcmp(a, "--rekey-data")) opt.rekey_data = atoi(v);
		else usage();
		i++;
	}
	validate();
}

/* The bounds, applied to the command line and again to a replay header,
 * which is a file someone may have edited: an aux-max past AUX_CAP writes a
 * frame nobody reads the far end of and the lockstep hangs. */
static void
validate(void)
{
	if (opt.frames < 1 || opt.aux_max < 0 || opt.aux_max > AUX_CAP ||
	    opt.delay_max < 0 || opt.loss < 0 || opt.loss > 1 ||
	    opt.dup < 0 || opt.dup > 1 || opt.relay < 0 || opt.relay > 65535 ||
	    opt.partition_len < 0 || opt.rekey_data < 0 || opt.rekey_data > 1)
		usage();
}

/* The first trace line carries every argument the run depends on, so a
 * replay is the same run.  The two format strings differ only in the
 * double conversions, which printf and scanf spell differently. */
#define HEADER_(F) "h2loop seed=%" PRIu64 " frames=%ld aux-max=%ld delay-max=%ld" \
		   " loss=" F " dup=" F " halfclose-at=%ld disconnect-at=%ld" \
		   " reconnect-at=%ld corrupt-at=%ld\n"
#define HEADER_FMT  HEADER_("%.6f")
#define HEADER_SCAN HEADER_("%lf")

static void
read_replay_header(const char *path)
{
	FILE *f = fopen(path, "r");
	if (f == NULL) {
		perror(path);
		exit(2);
	}
	int n = fscanf(f, HEADER_SCAN, &opt.seed, &opt.frames, &opt.aux_max,
	    &opt.delay_max, &opt.loss, &opt.dup, &opt.halfclose_at,
	    &opt.disconnect_at, &opt.reconnect_at, &opt.corrupt_at);
	fclose(f);
	if (n != 10) {
		fprintf(stderr, "h2loop: %s: no run header\n", path);
		exit(2);
	}
	validate();
}

/* ---- the socket, and the daemon's actions on it ------------------------ */

static int kern_fd = -1;	/* the kernel's end: generator writes, receiver reads */
static int daemon_fd = -1;	/* the daemon's end: the simulator */
static int conn_eof;		/* the reader saw this connection end */
static FILE *tracef;
static long tick;

struct counts {
	long sent, delivered, dropped, dup, reordered, rejected, lost;
	long eof, epipe, disconnects, reconnects;
} ct;

static void
trace(const char *fmt, ...)
{
	va_list ap;
	va_start(ap, fmt);
	vfprintf(tracef, fmt, ap);
	va_end(ap);
}

static void
connect_pair(void)
{
	int sv[2];
	if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
		perror("socketpair");
		exit(2);
	}
	kern_fd = sv[0];
	daemon_fd = sv[1];
	conn_eof = 0;
}

static void
disconnect(void)
{
	/* what fp_shutdown(SHUT_RDWR) plus fdrop() do to the far side */
	shutdown(daemon_fd, SHUT_RDWR);
	close(daemon_fd);
	daemon_fd = -1;
	ct.disconnects++;
}

/* ---- the frame ---------------------------------------------------------- */

struct frame {
	struct dmsg_hdr hdr;
	uint8_t *ext;		/* the extended header past the base, hbytes - 64 */
	size_t ext_len;
	uint8_t *aux;		/* DMSG_DOALIGN(hdr.aux_bytes) bytes */
	long due;		/* virtual tick it is delivered at */
	struct frame *next;
};

static size_t
aux_alloc(const struct dmsg_hdr *h)
{
	return (DMSG_DOALIGN(h->aux_bytes));
}

static int
write_all(int fd, const void *buf, size_t len)
{
	const uint8_t *p = buf;
	while (len) {
		ssize_t n = write(fd, p, len);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			return (-1);
		}
		p += n;
		len -= n;
	}
	return (0);
}

/* Read exactly len bytes, as fp_read(all=1) does; 0 on EOF before any
 * byte, -1 on error or on a torn frame, 1 on a full read. */
static int
read_all(int fd, void *buf, size_t len)
{
	uint8_t *p = buf;
	size_t got = 0;
	while (got < len) {
		ssize_t n = read(fd, p + got, len - got);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			return (-1);
		}
		if (n == 0)
			return (got == 0 ? 0 : -1);
		got += n;
	}
	return (1);
}

static int
frame_write(int fd, const struct frame *f)
{
	/* kdmsg_iocom_thread_wr: the header, its extension, then the aligned aux */
	if (write_all(fd, &f->hdr, sizeof(f->hdr)) < 0)
		return (-1);
	if (f->ext_len && write_all(fd, f->ext, f->ext_len) < 0)
		return (-1);
	if (f->hdr.aux_bytes && write_all(fd, f->aux, aux_alloc(&f->hdr)) < 0)
		return (-1);
	return (0);
}

/* kdmsg_iocom_thread_rd's three reads and its three checks.  Returns 1
 * with *fp filled, 0 on a clean EOF, -1 on error or a frame the kernel
 * would refuse; *why names the refusal. */
static int
frame_read(int fd, struct frame **fp, const char **why)
{
	struct frame *f = calloc(1, sizeof(*f));
	int r;

	*why = NULL;
	r = read_all(fd, &f->hdr, sizeof(f->hdr));
	if (r <= 0) {
		free(f);
		*why = (r < 0) ? "torn header" : NULL;
		return (r);
	}
	if (f->hdr.magic != DMSG_HDR_MAGIC) {
		*why = "magic";
		goto bad;
	}
	/* The size the command encodes, in 64-byte units: the base header
	 * alone for the loopback's generator, an extension for the LNK_CONN
	 * and LNK_SPAN two kernels exchange through the relay.  The kernel's
	 * bounds are its own. */
	f->ext_len = (size_t)(f->hdr.cmd & DMSGF_SIZE) * DMSG_ALIGN;
	if (f->ext_len < sizeof(f->hdr) || f->ext_len > DMSG_HDR_MAX) {
		*why = "header size";
		goto bad;
	}
	f->ext_len -= sizeof(f->hdr);
	if (f->ext_len) {
		f->ext = malloc(f->ext_len);
		if (read_all(fd, f->ext, f->ext_len) != 1) {
			*why = "torn header";
			goto bad;
		}
	}
	if (f->hdr.aux_bytes > 1024 * 1024) {
		*why = "aux bound";
		goto bad;
	}
	if (f->hdr.aux_bytes) {
		f->aux = malloc(aux_alloc(&f->hdr));
		if (read_all(fd, f->aux, aux_alloc(&f->hdr)) != 1) {
			*why = "torn aux";
			goto bad;
		}
	}
	*fp = f;
	return (1);
bad:
	free(f->ext);
	free(f->aux);
	free(f);
	return (-1);
}

/* The two checks the kernel does not make and libdmsg does.  The header
 * CRC covers the whole header, extension included, with its field zero. */
static const char *
frame_verify(const struct frame *f)
{
	uint8_t h[DMSG_HDR_MAX];
	struct dmsg_hdr *hp = (struct dmsg_hdr *)h;
	memcpy(h, &f->hdr, sizeof(f->hdr));
	if (f->ext_len)
		memcpy(h + sizeof(f->hdr), f->ext, f->ext_len);
	hp->hdr_crc = 0;
	if (iscsi_crc32(h, sizeof(f->hdr) + f->ext_len) != f->hdr.hdr_crc)
		return ("hdr_crc");
	if (f->hdr.aux_bytes &&
	    iscsi_crc32(f->aux, aux_alloc(&f->hdr)) != f->hdr.aux_crc)
		return ("aux_crc");
	return (NULL);
}

static void
frame_free(struct frame *f)
{
	if (f) {
		free(f->ext);
		free(f->aux);
		free(f);
	}
}

static struct frame *
frame_dup(const struct frame *f)
{
	struct frame *g = calloc(1, sizeof(*g));
	g->hdr = f->hdr;
	if (f->ext_len) {
		g->ext = malloc(f->ext_len);
		memcpy(g->ext, f->ext, f->ext_len);
		g->ext_len = f->ext_len;
	}
	if (f->hdr.aux_bytes) {
		g->aux = malloc(aux_alloc(&f->hdr));
		memcpy(g->aux, f->aux, aux_alloc(&f->hdr));
	}
	return (g);
}

/* ---- the generator: the kernel's writer ------------------------------- */

static int
generate(uint64_t msgid)
{
	struct frame f;
	size_t alloc;
	int r;

	memset(&f, 0, sizeof(f));
	f.hdr.magic = DMSG_HDR_MAGIC;
	f.hdr.salt = (uint32_t)rng();
	f.hdr.msgid = msgid;
	f.hdr.cmd = 1;			/* one 64-byte header unit */
	f.hdr.aux_bytes = opt.aux_max ? (uint32_t)(rng() % (opt.aux_max + 1)) : 0;
	alloc = aux_alloc(&f.hdr);
	f.aux = alloc ? calloc(1, alloc) : NULL;
	for (size_t i = 0; i < f.hdr.aux_bytes; i++)
		f.aux[i] = (uint8_t)(msgid + i);
	f.hdr.aux_crc = alloc ? iscsi_crc32(f.aux, alloc) : 0;
	f.hdr.hdr_crc = 0;
	f.hdr.hdr_crc = iscsi_crc32(&f.hdr, sizeof(f.hdr));
	r = frame_write(kern_fd, &f);
	free(f.aux);
	if (r < 0) {
		/* what the kernel's writer sees after the daemon went away */
		ct.epipe++;
		trace("i=%" PRIu64 " msgid=%" PRIu64 " epipe t=%ld\n", msgid, msgid, tick);
		return (-1);
	}
	ct.sent++;
	return (0);
}

/* ---- the receiver: the kernel's reader -------------------------------- */

static uint64_t rx_max = 0;	/* highest msgid seen, for the order count */
static uint8_t *rx_seen;	/* one byte per msgid, for the dup count */

static void
receive_one(void)
{
	struct frame *f;
	const char *why;
	int r = frame_read(kern_fd, &f, &why);

	if (r == 0) {
		/* kdmsg_iocom_thread_rd exits on this; nothing reads after */
		ct.eof++;
		conn_eof = 1;
		trace("rx eof t=%ld\n", tick);
		return;
	}
	if (r < 0) {
		ct.rejected++;
		trace("rx rejected %s t=%ld\n", why ? why : "read", tick);
		return;
	}
	why = frame_verify(f);
	if (why) {
		ct.rejected++;
		trace("rx rejected %s msgid=%" PRIu64 " t=%ld\n", why, f->hdr.msgid, tick);
		frame_free(f);
		return;
	}
	if (f->hdr.msgid < (uint64_t)opt.frames && rx_seen[f->hdr.msgid]) {
		ct.dup++;
	} else {
		if (f->hdr.msgid < rx_max)
			ct.reordered++;
		if (f->hdr.msgid > rx_max)
			rx_max = f->hdr.msgid;
		if (f->hdr.msgid < (uint64_t)opt.frames)
			rx_seen[f->hdr.msgid] = 1;
		ct.delivered++;
	}
	frame_free(f);
}

/* ---- the simulator: the daemon ----------------------------------------- */

static struct frame *queue;	/* sorted by due, stable for equal dues */
static int corrupted;		/* --corrupt-at has fired */

static void
enqueue(struct frame *f, long due)
{
	struct frame **pp = &queue;
	f->due = due;
	while (*pp && (*pp)->due <= due)
		pp = &(*pp)->next;
	f->next = *pp;
	*pp = f;
}

/* Deliver everything due by now, one frame at a time with the receiver
 * reading each before the next is written, so one frame is the most that
 * is ever in flight in either direction and no socket buffer fills. */
static void
drain(int all)
{
	while (queue && (all || queue->due <= tick)) {
		struct frame *f = queue;
		queue = f->next;
		if (daemon_fd < 0) {
			ct.lost++;
			trace("i=%ld msgid=%" PRIu64 " lost t=%ld\n", tick, f->hdr.msgid, tick);
			frame_free(f);
			continue;
		}
		if (f->hdr.msgid == (uint64_t)opt.corrupt_at && !corrupted) {
			corrupted = 1;	/* one bit in one copy: one rejection */
			f->hdr.aux_crc ^= 1;
			trace("i=%ld msgid=%" PRIu64 " corrupt t=%ld\n", tick, f->hdr.msgid, tick);
		}
		if (frame_write(daemon_fd, f) == 0) {
			if (!conn_eof)
				receive_one();
			else {
				/* written after the reader exited */
				ct.lost++;
				trace("i=%ld msgid=%" PRIu64 " lost t=%ld\n", tick, f->hdr.msgid, tick);
			}
		} else {
			/* the daemon's send side is shut; the kernel never sees it */
			ct.lost++;
			trace("i=%ld msgid=%" PRIu64 " lost t=%ld\n", tick, f->hdr.msgid, tick);
		}
		frame_free(f);
	}
}

static void
decide(struct frame *f, long i)
{
	double r = rng_unit();
	long d;

	if (r < opt.loss) {
		ct.dropped++;
		trace("i=%ld msgid=%" PRIu64 " drop t=%ld\n", i, f->hdr.msgid, tick);
		frame_free(f);
		return;
	}
	d = opt.delay_max ? (long)(rng() % (opt.delay_max + 1)) : 0;
	if (r < opt.loss + opt.dup) {
		long d2 = opt.delay_max ? (long)(rng() % (opt.delay_max + 1)) : 0;
		trace("i=%ld msgid=%" PRIu64 " dup t=%ld d=%ld d2=%ld\n", i, f->hdr.msgid, tick, d, d2);
		enqueue(frame_dup(f), tick + d2);
	} else {
		trace("i=%ld msgid=%" PRIu64 " deliver t=%ld d=%ld\n", i, f->hdr.msgid, tick, d);
	}
	enqueue(f, tick + d);
}

static int
run(void)
{
	long i;

	rng_state = opt.seed | 1;
	rx_seen = calloc(opt.frames, 1);
	connect_pair();
	trace(HEADER_FMT, opt.seed, opt.frames, opt.aux_max, opt.delay_max,
	    opt.loss, opt.dup, opt.halfclose_at, opt.disconnect_at,
	    opt.reconnect_at, opt.corrupt_at);

	for (i = 0; i < opt.frames; i++) {
		struct frame *f;
		const char *why;

		tick = i;
		if (i == opt.reconnect_at && daemon_fd < 0) {
			/* a fresh pair, as a new RECLUSTER would hand the kernel */
			close(kern_fd);
			connect_pair();
			ct.reconnects++;
			trace("i=%ld reconnect t=%ld\n", i, tick);
		}
		if (generate(i) < 0)
			continue;
		if (daemon_fd >= 0) {
			int r = frame_read(daemon_fd, &f, &why);
			if (r == 1)
				decide(f, i);
			else
				trace("i=%ld sim read %s t=%ld\n", i, why ? why : "eof", tick);
		}
		drain(0);
		if (i == opt.halfclose_at && daemon_fd >= 0) {
			/* the daemon stops sending; the kernel's reader sees EOF
			 * while its writer still has a reader */
			drain(1);
			shutdown(daemon_fd, SHUT_WR);
			trace("i=%ld halfclose t=%ld\n", i, tick);
			if (!conn_eof)
				receive_one();
		}
		if (i == opt.disconnect_at && daemon_fd >= 0) {
			drain(1);
			disconnect();
			trace("i=%ld disconnect t=%ld\n", i, tick);
			if (!conn_eof)
				receive_one();
		}
	}
	tick = opt.frames;
	drain(1);
	if (daemon_fd >= 0) {
		disconnect();
		if (!conn_eof)
			receive_one();	/* the EOF at the end of every run */
	}
	close(kern_fd);
	printf("h2loop: sent %ld delivered %ld dropped %ld dup %ld reordered %ld"
	    " rejected %ld lost %ld eof %ld epipe %ld disconnects %ld reconnects %ld\n",
	    ct.sent, ct.delivered, ct.dropped, ct.dup, ct.reordered, ct.rejected,
	    ct.lost, ct.eof, ct.epipe, ct.disconnects, ct.reconnects);
	return (0);
}

/* ---- the relay: two kernels in the loop --------------------------------- */

/* The relay's clock, milliseconds since its start; delay is real here. */
static long
now_ms(void)
{
	static struct timespec t0;
	struct timespec t;

	clock_gettime(CLOCK_MONOTONIC, &t);
	if (t0.tv_sec == 0 && t0.tv_nsec == 0)
		t0 = t;
	return ((t.tv_sec - t0.tv_sec) * 1000 + (t.tv_nsec - t0.tv_nsec) / 1000000);
}

struct side {
	const char *name;	/* "A" or "B" */
	int fd;
	int eof;		/* its reader saw EOF: nothing more comes from it */
	struct frame *queue;	/* frames due to it, sorted by due */
	long sent;		/* frames read from it */
};

static void
side_enqueue(struct side *to, struct frame *f, long due)
{
	struct frame **pp = &to->queue;
	f->due = due;
	while (*pp && (*pp)->due <= due)
		pp = &(*pp)->next;
	f->next = *pp;
	*pp = f;
}

static int rekeyed;		/* --rekey-data has fired */

/*
 * A feed frame (DMSG_HM2_FEED, sys/sys/dmsg.h) whose extended header opens
 * with the fed chain's blockref: type at byte 0, key at byte 8.  The first
 * one of a data block with its data aboard has its key moved one 64 KiB
 * block up and its header CRC computed again, the aux untouched.
 */
static int
rekey(struct frame *f)
{
	uint8_t h[DMSG_HDR_MAX];
	uint64_t key;

	if ((f->hdr.cmd & 0x00FFFF00U) != 0x00203000U || f->ext_len < 128 ||
	    f->ext[0] != 3 || f->hdr.aux_bytes == 0)
		return (0);
	memcpy(&key, f->ext + 8, sizeof(key));
	key += 65536;
	memcpy(f->ext + 8, &key, sizeof(key));
	memcpy(h, &f->hdr, sizeof(f->hdr));
	memcpy(h + sizeof(f->hdr), f->ext, f->ext_len);
	((struct dmsg_hdr *)h)->hdr_crc = 0;
	f->hdr.hdr_crc = iscsi_crc32(h, sizeof(f->hdr) + f->ext_len);
	return (1);
}

/* One frame read from `from`, decided for `to`.  The index i counts every
 * frame the relay read in either direction, so a partition or a disconnect
 * scripted at K lands at the Kth frame of the run and not of one side. */
static void
relay_decide(struct side *from, struct side *to, struct frame *f, long i)
{
	double r = rng_unit();
	long d, t = now_ms();

	if (opt.partition_at >= 0 && i >= opt.partition_at &&
	    i < opt.partition_at + opt.partition_len) {
		ct.dropped++;
		trace("%s>%s i=%ld msgid=%" PRIu64 " partition t=%ld\n",
		    from->name, to->name, i, f->hdr.msgid, t);
		frame_free(f);
		return;
	}
	if (r < opt.loss) {
		ct.dropped++;
		trace("%s>%s i=%ld msgid=%" PRIu64 " drop t=%ld\n",
		    from->name, to->name, i, f->hdr.msgid, t);
		frame_free(f);
		return;
	}
	d = opt.delay_max ? (long)(rng() % (opt.delay_max + 1)) : 0;
	if (r < opt.loss + opt.dup) {
		long d2 = opt.delay_max ? (long)(rng() % (opt.delay_max + 1)) : 0;
		trace("%s>%s i=%ld msgid=%" PRIu64 " dup t=%ld d=%ld d2=%ld\n",
		    from->name, to->name, i, f->hdr.msgid, t, d, d2);
		side_enqueue(to, frame_dup(f), t + d2);
	} else {
		trace("%s>%s i=%ld msgid=%" PRIu64 " deliver t=%ld d=%ld\n",
		    from->name, to->name, i, f->hdr.msgid, t, d);
	}
	if (f->hdr.msgid == (uint64_t)opt.corrupt_at && !corrupted) {
		corrupted = 1;
		f->hdr.aux_crc ^= 1;
		trace("%s>%s i=%ld msgid=%" PRIu64 " corrupt t=%ld\n",
		    from->name, to->name, i, f->hdr.msgid, t);
	}
	if (opt.rekey_data && !rekeyed && rekey(f)) {
		rekeyed = 1;
		trace("%s>%s i=%ld msgid=%" PRIu64 " rekey t=%ld\n",
		    from->name, to->name, i, f->hdr.msgid, t);
	}
	side_enqueue(to, f, t + d);
}

/* Write everything due to `to`; a side that went away loses them. */
static void
side_drain(struct side *to, int all)
{
	long t = now_ms();

	while (to->queue && (all || to->queue->due <= t)) {
		struct frame *f = to->queue;
		to->queue = f->next;
		if (to->fd < 0 || frame_write(to->fd, f) < 0) {
			ct.lost++;
			trace(">%s msgid=%" PRIu64 " lost t=%ld\n", to->name,
			    f->hdr.msgid, t);
		} else {
			ct.delivered++;
		}
		frame_free(f);
	}
}

static void
side_close(struct side *s)
{
	if (s->fd >= 0) {
		shutdown(s->fd, SHUT_RDWR);
		close(s->fd);
		s->fd = -1;
	}
	while (s->queue) {
		struct frame *f = s->queue;
		s->queue = f->next;
		ct.lost++;
		frame_free(f);
	}
}

static int
relay_accept(int lfd, struct side *s)
{
	int one = 1;

	s->fd = accept(lfd, NULL, NULL);
	if (s->fd < 0) {
		perror("accept");
		return (-1);
	}
	setsockopt(s->fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
	s->eof = 0;
	s->queue = NULL;
	trace("%s connected t=%ld\n", s->name, now_ms());
	return (0);
}

/* One pair, from both connected to both gone or the scripted disconnect.
 * Returns the frame index after the pair. */
static long
relay_pair(struct side *a, struct side *b, long i)
{
	struct side *sides[2] = { a, b };

	for (;;) {
		struct pollfd pfd[2];
		long wait = -1, t = now_ms();
		int k, n;

		for (k = 0; k < 2; k++) {
			struct side *s = sides[k];
			pfd[k].fd = (s->eof || s->fd < 0) ? -1 : s->fd;
			pfd[k].events = POLLIN;
			if (s->queue) {
				long w = s->queue->due - t;
				if (w < 0)
					w = 0;
				if (wait < 0 || w < wait)
					wait = w;
			}
		}
		if (pfd[0].fd < 0 && pfd[1].fd < 0 && a->queue == NULL &&
		    b->queue == NULL)
			break;
		n = poll(pfd, 2, (int)wait);
		if (n < 0) {
			if (errno == EINTR)
				continue;
			perror("poll");
			break;
		}
		for (k = 0; k < 2; k++) {
			struct side *from = sides[k], *to = sides[1 - k];
			struct frame *f;
			const char *why;
			int r;

			if (!(pfd[k].revents & (POLLIN | POLLHUP | POLLERR)))
				continue;
			r = frame_read(from->fd, &f, &why);
			if (r == 1) {
				from->sent++;
				relay_decide(from, to, f, i++);
				if (i == opt.disconnect_at) {
					trace("disconnect i=%ld t=%ld\n", i, now_ms());
					side_drain(a, 1);
					side_drain(b, 1);
					side_close(a);
					side_close(b);
					ct.disconnects++;
					return (i);
				}
			} else {
				/* EOF or a torn frame: the far side's reader
				 * sees the same once the queue to it drains */
				trace("%s %s t=%ld\n", from->name,
				    r == 0 ? "eof" : (why ? why : "error"), now_ms());
				from->eof = 1;
				if (r == 0)
					ct.eof++;
				else
					ct.rejected++;
				side_drain(to, 1);
				if (to->fd >= 0)
					shutdown(to->fd, SHUT_WR);
			}
		}
		side_drain(a, 0);
		side_drain(b, 0);
	}
	side_close(a);
	side_close(b);
	return (i);
}

static int
relay(void)
{
	struct side a = { "A", -1, 0, NULL, 0 }, b = { "B", -1, 0, NULL, 0 };
	struct sockaddr_in sin;
	int lfd, one = 1;
	long i = 0;

	rng_state = opt.seed | 1;
	lfd = socket(AF_INET, SOCK_STREAM, 0);
	if (lfd < 0) {
		perror("socket");
		return (2);
	}
	setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
	memset(&sin, 0, sizeof(sin));
	sin.sin_family = AF_INET;
	sin.sin_addr.s_addr = htonl(INADDR_ANY);
	sin.sin_port = htons((uint16_t)opt.relay);
	if (bind(lfd, (struct sockaddr *)&sin, sizeof(sin)) < 0 ||
	    listen(lfd, 2) < 0) {
		perror("bind");
		return (2);
	}
	trace("h2loop relay port=%d seed=%" PRIu64 " delay-max=%ld loss=%.6f"
	    " dup=%.6f partition-at=%ld partition-len=%ld disconnect-at=%ld"
	    " corrupt-at=%ld rekey-data=%d\n", opt.relay, opt.seed, opt.delay_max,
	    opt.loss, opt.dup, opt.partition_at, opt.partition_len,
	    opt.disconnect_at, opt.corrupt_at, opt.rekey_data);
	fflush(tracef);
	printf("h2loop: relay listening on %d\n", opt.relay);
	fflush(stdout);
	for (;;) {
		if (relay_accept(lfd, &a) < 0)
			break;
		if (relay_accept(lfd, &b) < 0) {
			side_close(&a);
			break;
		}
		i = relay_pair(&a, &b, i);
		fflush(tracef);
		printf("h2loop: pair done frames %ld delivered %ld dropped %ld dup %ld"
		    " lost %ld eof %ld rejected %ld disconnects %ld\n",
		    i, ct.delivered, ct.dropped, ct.dup, ct.lost, ct.eof,
		    ct.rejected, ct.disconnects);
		fflush(stdout);
	}
	close(lfd);
	return (0);
}

static int
files_equal(const char *a, const char *b)
{
	FILE *fa = fopen(a, "r"), *fb = fopen(b, "r");
	int ca, cb;
	if (fa == NULL || fb == NULL)
		return (0);
	do {
		ca = fgetc(fa);
		cb = fgetc(fb);
	} while (ca == cb && ca != EOF);
	fclose(fa);
	fclose(fb);
	return (ca == cb);
}

int
main(int argc, char **argv)
{
	char tmp[] = "/tmp/h2loop.XXXXXX";
	int rc = 0;

	crc_init();
	signal(SIGPIPE, SIG_IGN);	/* the generator reads EPIPE, as the kernel does */
	parse_args(argc, argv);
	if (opt.relay) {
		if (opt.replay)
			usage();
		tracef = opt.trace ? fopen(opt.trace, "w") : fopen("/dev/null", "w");
		if (tracef == NULL) {
			perror(opt.trace ? opt.trace : "/dev/null");
			return (2);
		}
		rc = relay();
		fclose(tracef);
		return (rc);
	}
	if (opt.replay) {
		read_replay_header(opt.replay);
		if (opt.trace == NULL) {
			int fd = mkstemp(tmp);
			if (fd < 0) {
				perror("mkstemp");
				return (2);
			}
			close(fd);
			opt.trace = tmp;
		}
	}
	tracef = opt.trace ? fopen(opt.trace, "w") : fopen("/dev/null", "w");
	if (tracef == NULL) {
		perror(opt.trace ? opt.trace : "/dev/null");
		return (2);
	}
	run();
	fclose(tracef);
	if (opt.replay) {
		if (files_equal(opt.replay, opt.trace)) {
			printf("h2loop: replay of %s reproduces\n", opt.replay);
		} else {
			printf("h2loop: replay of %s DIFFERS\n", opt.replay);
			rc = 1;
		}
		if (opt.trace == tmp)
			unlink(tmp);
	}
	return (rc);
}
