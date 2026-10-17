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
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define DMSG_HDR_MAGIC	0x4832
#define DMSG_ALIGN	64
#define DMSG_ALIGNMASK	(DMSG_ALIGN - 1)
#define DMSG_DOALIGN(n)	(((n) + DMSG_ALIGNMASK) & ~DMSG_ALIGNMASK)
#define DMSGF_SIZE	0x000000FF
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
} opt = { 1, 100, 4096, 0, 0.0, 0.0, -1, -1, -1, -1, NULL, NULL };

static void
usage(void)
{
	fprintf(stderr,
	    "usage: h2loop [--seed N] [--frames N] [--aux-max N] [--delay-max N]\n"
	    "              [--loss P] [--dup P] [--halfclose-at K]\n"
	    "              [--disconnect-at K] [--reconnect-at K] [--corrupt-at K]\n"
	    "              [--trace FILE] [--replay FILE]\n");
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
	    opt.dup < 0 || opt.dup > 1)
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
	/* kdmsg_iocom_thread_wr: the header, then the aligned aux */
	if (write_all(fd, &f->hdr, sizeof(f->hdr)) < 0)
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
	if ((f->hdr.cmd & DMSGF_SIZE) != 1) {
		/* the base header only; an extended header is a P6 message */
		*why = "header size";
		goto bad;
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
	free(f->aux);
	free(f);
	return (-1);
}

/* The two checks the kernel does not make and libdmsg does. */
static const char *
frame_verify(const struct frame *f)
{
	struct dmsg_hdr h = f->hdr;
	h.hdr_crc = 0;
	if (iscsi_crc32(&h, sizeof(h)) != f->hdr.hdr_crc)
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
		free(f->aux);
		free(f);
	}
}

static struct frame *
frame_dup(const struct frame *f)
{
	struct frame *g = calloc(1, sizeof(*g));
	g->hdr = f->hdr;
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
