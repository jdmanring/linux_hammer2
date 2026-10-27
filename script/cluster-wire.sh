#!/bin/sh
# Two kernels on the wire: stage 2b of doc/CLUSTER_PROTOCOL_DESIGN.md, the
# first run of the cluster transport on a network, permitted because the
# loopback stages passed. Guest A carries MASTER CL, guest B carries SLAVE
# CL with the same cluster id, each volume's ROOT mounted on its own guest;
# test/h2service.c on each guest dials test/h2loop.c's relay on this host,
# which pairs the two connections and relays frames under its seeded knobs
# with every decision traced. Two guests on one cpuset read function and
# never a rate.
#
# Phase 1, the link: each kernel's LNK_CONN announces DMSG_SPAN_PROTO_2 and
# the peer's log says so; each kernel's span table lists the peer's PFSs,
# one span per PFS the peer's own `hammer2 pfs-list` counts, the CL span
# among them with the shared cluster id and the peer's type; the connection
# outlives the VOLCONF frames each kernel sends on its CONN; the first
# unmount sends one DELETE per span and the peer's table empties by them;
# both modules unload with no message thread, no kernel warning and
# kmemleak clean. The fake pass: a relay that pairs nothing leaves both
# tables empty, so the span count is compared with the peer's PFS count,
# and the CL span is required by cluster id, which only the peer knows.
#
# H2_WIRE_REKEY=1 is the control on the read side's range check: the relay
# moves the key of the first data block fed with its data one block up and
# signs the frame again, so it passes both CRCs and only B's check of what
# a feed can answer refuses it. That block is the bmap of the 512 KiB
# file's first block, fiemap being the run's first read of file data, and
# bmap takes the data arm a read takes. The run must then read one rekey
# line in the trace and that one bmap feed refused, the FIEMAP call failing
# so that filefrag falls back to FIBMAP (e2fsprogs misc/filefrag.c, "FIEMAP
# failed, try FIBMAP instead") and lists no extent and no unknown_loc, and
# every file's digest still equal to A's, warm and cold, since the knob
# fires once; a check that refused nothing would list the one unknown_loc
# extent the plain run reads. The same fallback is why the plain run's
# fiemap check reads unknown_loc, which only FIEMAP reports, and not
# filefrag's status alone.
#
# H2_WIRE_DIRENT=1 is the control on what a lookup takes: the relay turns
# the inode answering the first nresolve, B's stat of small.txt, into a
# directory entry with no bytes and signs it again. Its caller reads the
# answer as an inode, so a check taking any entry hands it a chain with no
# data and the stat faults on B. The run must read one bare-dirent line in
# the trace, that stat failing, that one nresolve feed refused and no
# other, and every digest equal to A's, warm and cold, since only the first
# lookup of the name was answered so.
#
# H2_WIRE_REFUSE=1 is the control on what B counts as a master's answer:
# the relay answers the first nresolve, B's stat of small.txt, with the
# refusal a server sends when it cannot take a request, and drops A's real
# answer. A refusal says nothing of the name, so B must read A as
# unreachable and the stat must fail "not connected". Read as an answer,
# the refusal is the lookup's result: with this one master the stat fails
# with the refusal's own "Operation not supported", and with two the
# quorum reads the name as absent. The run must read one refuse line in
# the trace, that stat failing not connected and neither absent nor
# unsupported, B's nresolve ending ENOTCONN, and every digest equal to A's.
#
# H2_WIRE_STALL=MS is the control on B's bound: B's reply bound is set to
# 2000 ms and the relay holds every frame due to B from the first readdir
# answer, B's listing of CL's root, for MS ms in order. A answers in full
# and B's call must end at its bound with the master read as unreachable:
# the listing fails not connected, B's readdir ends ETIMEDOUT, and the
# reads after the stall find every digest equal to A's. MS must exceed the
# 2000 ms bound.
#
# H2_WIRE_END=aborted, noeof, lost or onefed is the control on how B reads
# the end of a reply. Under the first three B lists an empty directory of
# A's before anything else is listed, and the relay rewrites the closing
# frames of the two getdents calls that listing makes, since the first
# has emitted . and .. and so hides its error: aborted sets their error
# to ABORTED, the code a server ends a request with while its unmount
# drains it, and noeof clears their error and EOF flag, a close with no
# end fed. Neither is an answer about the directory, so the listing must
# fail not connected and B's readdir end ENOTCONN. Taken as an answer,
# aborted fails the listing with ABORTED's own EINTR and noeof leaves the
# element counted in progress, EINPROGRESS. lost sets the closing frames'
# byte count instead, a closing feed carrying a chain, which the kernel
# answers one level up by ending the whole link; the relay arms both
# closes as in every mode, but the link ends at the first, so the second
# call's request never reaches the wire and ends ENOTCONN at the slave
# with no frame, and the run reads one rewrite in the trace and nothing
# after it. onefed is noeof on a listing of the 300-entry
# directory one entry per getdents call, a buffer with room for one entry
# making every readdir ask for one, so each rewritten close follows one
# fed chain: the rule that takes a clean close with no end as an answer
# only from a one-chain descriptor must read ENOTCONN on both, where the
# rule it replaced, keyed on the count, took the chain as the answer. The
# caller sees neither: each call has emitted its one entry before the end
# is judged and the kernel returns the entries written, so the listing
# completes, and the reading is the element's own log line.
#
# H2_WIRE_SILENCE=1 reads the keepalive: after every read above, B's bound
# is set to 2000 ms and B looks up a name A does not have, whose answer
# arms the relay's silence, a partition that drops every frame both ways
# with the sockets left open. No request is in flight, so only the
# keepalive can see it: B's kernel must end the link by its own line
# within the bound and a half of the next ping, the element detached by
# the span's deletion before any request, and B's next listing must fail
# not connected at once, under the bound, where a listing that waits out
# the bound times out instead. H2_WIRE_SILENCE=control builds the module
# with HAMMER2_NOKEEPALIVE, which arms no keepalive, and must read the
# opposite: no line, the listing timing out no sooner than the bound, the
# element still registered at B's unmount and detached by the connection's
# end. The caller reads not connected under both, since a timed-out
# element is no answer, so the time and the element's own ETIMEDOUT line
# tell them apart. Under either the plain reads before the silence hold.
#
# H2_WIRE_WINDOW=1 is the control on B's window count: A loads a module
# built with HAMMER2_NOWINDOW, whose server sends every chain of a readdir
# with no continuation, and B a plain one. B's first listing of the
# 300-entry directory must end the link at the seventeenth feed by its own
# line, the readdir ending ENOTCONN and the listing failing not connected;
# every read after it finds the link gone, as under lost. The listings
# before it stay inside sixteen feeds and pass. H2_WIRE_WINDOW=control
# builds B's module with HAMMER2_NOCLIENTWINDOW, which takes those feeds,
# says so once, and lists the directory whole: the failure the count exists
# to stop. The fake pass, a link ended by anything else, lacks the line; a
# server that kept its window gives neither line, so the control is not
# satisfied by a run whose A was built plain.
#
# Four more controls switch off one refusal each in a scratch build of one
# side (the HAMMER2_CTL_ terms in hammer2_os.h) and read what the refusal
# exists to stop; the plain runs read the refusal itself.
# H2_WIRE_ROGATE=control builds B with HAMMER2_NOROGATE: B's CL remounts
# read-write beside the remote master, the live pass then fills the slave,
# and a chmod of small.txt there must reach the slave's inode on B's media
# and not the master's on A's. A create is refused ENOSPC before it gets
# that far, since the reserve check counts masters and the connection
# device reports no free space, so the write is a chmod in emergency mode,
# which the setattr check lets through.
# H2_WIRE_PASSREFUSE=control builds B with HAMMER2_NOPASSREFUSE and loads
# it with sync_snapshot=0: the live pass must write A's files onto B's
# device opened read-only with no refusal line, B's image then holding
# A's file entries by fingerprint.
# H2_WIRE_SNAPROUTE=control builds B with HAMMER2_NOSNAPROUTE under the
# pass: the pass's snapshot of the remote master falls through to the
# local snapshot, which must refuse the connection device before its body
# with EOPNOTSUPP, the snapshot failing by that errno alone and the slave
# copying nothing. Without that refusal the body faults under KASAN, which
# is how the refusal came to exist; any kernel warning fails the run.
# H2_WIRE_SNAPDEL=1 runs the pass with a PFS ZZ.h2sync-src made on A, a
# name of the pass's suffix the link never took, and the relay gives the
# first SNAPDEL that name: A must delete nothing and say so, the PFS still
# on A's image at the end. H2_WIRE_SNAPDEL=control builds A with
# HAMMER2_NOSNAPSCOPE, which must delete it.
# H2_WIRE_ADMIT=1 removes B's .none marker before its dial: h2service
# must refuse the row as DragonFly's daemon refuses an unknown host, and
# the dial then made with the marker back proceeds as a plain run.
# H2_WIRE_ADMIT=control builds B's h2service with H2SERVICE_NOADMIT, which
# must dial with no marker and no key, and B registers A's master.
# H2_WIRE_CONNWAIT=1 builds B with HAMMER2_CONNWAIT, which holds B's
# reconnect a second between its reader's start and the rest of its setup,
# so A's LNK_CONN, queued at the relay since A dialed, is read in the hold:
# with the callback installed before the reader, B must still read A's
# PROTO_2 and the run pass as a plain one. H2_WIRE_CONNWAIT=control adds
# HAMMER2_NOCONNFIX, which installs the callback where upstream does,
# after the hold: B must then answer the CONN with no callback, never read
# PROTO_2, close A's spans and register nothing, the link failure seen
# once by chance in wire-run-20261026-060929. Each reads B's hold line, so
# a module built without the hold passes neither.
#
# H2_WIRE_LINKDEV=1 reads the third way an element leaves. B's row and dial
# go through a second volume, vdc, mounted beside B's own, so the link is
# vdc's and the element's local device is vdb. The unmount helper ends a
# device's connection before it scans the PFSes, so on one volume the
# connection's end always detaches the element first; here B's vdb leaves
# with the link still up, and the element must be detached once, by the
# unmount's own detach in hammer2_pfsfree_scan(), before vdc's unmount ends
# the link. The plain run reads "connection ended" and no other path
# prints "unmount".
#
# H2_WIRE_STALE=1 reads bmap's answer with a local element behind the focus.
# It runs the pass, then B's device is opened again read-only and both sides
# dial again, so B's pass refuses and the slave keeps what it copied; A then
# rewrites the first 64 KiB block of the 512 KiB file. fiemap on B must report
# that block with no address, since the slave's copy is older than the
# master's, and the file's other blocks and an unchanged file at the slave's
# own address. The images must differ by that one data block. A slave brought
# level by its pass reports every address, which is the fake pass this mode
# rules out, and a slave matched to nothing reports none for the unchanged file.
#
# H2_WIRE_RETYPE=1 is the control on the shape the slave's pass reads, under
# the pass: the relay gives the first directory entry A feeds in answer to
# one of B's scanall requests the type of a data block and signs the frame
# again. B must refuse that feed, end the scan ENOTCONN and fail that pass
# with no verdict of verified, and a later pass must bring the slave level
# with the master all the same; a pass that took the block beneath the
# directory would leave a data block on B's media the master's has not.
#
# Exit 2 is COULD-NOT-RUN. Needs both guests (H2_GUEST_A, H2_GUEST_B), a
# kernel tree at KDIR matching the kernel both run, newfs_hammer2 here and
# hammer2 on the guests. Every run keeps both kernel logs and the relay's
# trace under the fixture directory.
set -u
cd "$(dirname "$0")/.." || exit 2

FIXDIR=${H2_FIXTURE_DIR:-$HOME/Projects/linux_hammer2-data/fixtures}
GA=${H2_GUEST_A:-artix-s6-kde}
GB=${H2_GUEST_B:-artix-s6-h2b}
SA=${H2_GUEST_A_SSH:-root@192.168.122.16}
SB=${H2_GUEST_B_SSH:-root@192.168.122.64}
HOST_ADDR=${H2_HOST_ADDR:-192.168.122.1}
PORT=${H2_RELAY_PORT:-4800}
SEED=${H2_WIRE_SEED:-11}
REKEY=${H2_WIRE_REKEY:-0}
DIRENT=${H2_WIRE_DIRENT:-0}
REFUSE=${H2_WIRE_REFUSE:-0}
STALL=${H2_WIRE_STALL:-0}
END=${H2_WIRE_END:-}
# H2_WIRE_PASS=1 runs the slave's synchronization pass over the wire: B's
# device stays writable (no second read-only open between the row and the
# dial), and the pass copies A's CL onto B's media, read by the host from
# both images after the guests are down, fingerprinted as cluster-sync.sh
# fingerprints its two volumes and checked by fsck_hammer2.  The pass reads
# a snapshot the master takes on its own device at B's request and serves
# over the link, deleted at B's request when the pass has verified; a
# second set written on A after the first pass must reach B's media by a
# later pass, and at the end neither image holds a snapshot of the pass.
PASS=${H2_WIRE_PASS:-0}
SILENCE=${H2_WIRE_SILENCE:-0}
WINDOW=${H2_WIRE_WINDOW:-0}
ROGATE=${H2_WIRE_ROGATE:-0}; PASSREFUSE=${H2_WIRE_PASSREFUSE:-0}; SNAPROUTE=${H2_WIRE_SNAPROUTE:-0}
SNAPDEL=${H2_WIRE_SNAPDEL:-0}; ADMIT=${H2_WIRE_ADMIT:-0}; CONNWAIT=${H2_WIRE_CONNWAIT:-0}
LINKDEV=${H2_WIRE_LINKDEV:-0}
STALE=${H2_WIRE_STALE:-0}
RETYPE=${H2_WIRE_RETYPE:-0}
# H2_WIRE_CUT=disconnect ends the link inside the pass: the relay closes
# both sides at the close of the first scanall call from the Kth on
# (H2_WIRE_CUT_AT) that fed 2 to 15 chains, so the scan stops partway; then,
# past the thread's idle sleep, both dial again and a later pass must
# converge.  control is the same cut with the dial withheld, which must
# leave the slave short of the master.  H2_WIRE_CUT_AT=1000000 alone under
# H2_WIRE_PASS=1 traces every call and reaches none, which is how K is read.
#
# H2_WIRE_CUT=slave and =master cut a guest's power inside the pass instead:
# A's CL is given 5000 more files, and once B's pass has updated
# H2_WIRE_CUT_DEPTH inodes (default 1000) the host destroys B or A.  The cut
# guest's image is read here while it is down, the survivor's keepalive ends
# its side of the link, the relay is started again on the same port with a
# second trace, and the cut guest boots again, loads the module on what the
# cut left and dials; the pass after the dial must verify and the slave
# converge as after the disconnect.
#
# The protocol cells fault the same call's last feed and leave the link to
# B: loss drops it, dup sends it twice, reorder sends it after the close,
# trail sends it, the close and a copy of it in one write, and late sends
# both as they came and delivers a copy of the feed as the first frame of
# B's next scanall call, its msgid rewritten to that call's and the frame
# signed again.  B's own end
# of the link is waited for, 10 s or 60 s for late, and failing it the relay
# hangs the pair up; then both dial as after the disconnect.  Each check of
# B's reply path ends the link with its own line, read as the cell's one HM2
# line; trail prints which of four things its copy did on B: ended the
# link, nothing, a refusal as not a proxy, or a KASAN report in
# hammer2_rcall_reply.  A late copy no later scanall call met makes the
# run void.
#
# H2_WIRE_SEQ=control builds B with HAMMER2_NOCLIENTSEQ, under loss, dup
# or late: with the tag, the index and the close's count unchecked the
# fault is taken, the link stays up to B's unmount and nothing dials.
CUT=${H2_WIRE_CUT:-}; CUTAT=${H2_WIRE_CUT_AT:-}; DEPTH=${H2_WIRE_CUT_DEPTH:-1000}
SEQ=${H2_WIRE_SEQ:-0}; VOID=
case $CUT in ''|disconnect|control|loss|dup|reorder|trail|late|slave|master) ;; *) echo "wire: COULD-NOT-RUN: H2_WIRE_CUT is disconnect, control, loss, dup, reorder, trail, late, slave or master" >&2; exit 2;; esac
case $SEQ$CUT in 0*|controlloss|controldup|controllate) ;; *) echo "wire: COULD-NOT-RUN: H2_WIRE_SEQ is control, under H2_WIRE_CUT=loss, dup or late" >&2; exit 2;; esac
FAULT=disconnect; PROTO=0
case $CUT in loss|dup|reorder|trail|late) FAULT=$CUT PROTO=1;; esac
POWER=0; case $CUT in slave|master) POWER=1;; esac
case $CUTAT in *[!0-9]*) echo "wire: COULD-NOT-RUN: H2_WIRE_CUT_AT is a call count" >&2; exit 2;; esac
case $DEPTH in ''|*[!0-9]*) echo "wire: COULD-NOT-RUN: H2_WIRE_CUT_DEPTH is an inode count" >&2; exit 2;; esac
[ "$DEPTH" -ge 1 ] && [ "$DEPTH" -lt 5000 ] || { echo "wire: COULD-NOT-RUN: H2_WIRE_CUT_DEPTH is 1 to 4999, inside the pass's 5310 files" >&2; exit 2; }
[ "$POWER" = 0 ] || [ -z "$CUTAT" ] || { echo "wire: COULD-NOT-RUN: a power cut is placed by H2_WIRE_CUT_DEPTH, not H2_WIRE_CUT_AT" >&2; exit 2; }
[ -z "$CUT" ] || [ "$POWER" = 1 ] || [ -n "$CUTAT" ] || { echo "wire: COULD-NOT-RUN: H2_WIRE_CUT needs H2_WIRE_CUT_AT" >&2; exit 2; }
[ -n "$CUT" ] || [ -z "$CUTAT" ] || [ "$CUTAT" -ge 1000000 ] || { echo "wire: COULD-NOT-RUN: H2_WIRE_CUT_AT without H2_WIRE_CUT only traces, at 1000000" >&2; exit 2; }
case $RETYPE in 0|1) ;; *) echo "wire: COULD-NOT-RUN: H2_WIRE_RETYPE is 1" >&2; exit 2;; esac
case $STALE in 0|1) ;; *) echo "wire: COULD-NOT-RUN: H2_WIRE_STALE is 1" >&2; exit 2;; esac
case $SILENCE in 0|1|control) ;; *) echo "wire: COULD-NOT-RUN: H2_WIRE_SILENCE is 1 or control" >&2; exit 2;; esac
case $WINDOW in 0|1|control) ;; *) echo "wire: COULD-NOT-RUN: H2_WIRE_WINDOW is 1 or control" >&2; exit 2;; esac
for c in "$ROGATE" "$PASSREFUSE" "$SNAPROUTE"; do
	case $c in 0|control) ;; *) echo "wire: COULD-NOT-RUN: H2_WIRE_ROGATE, _PASSREFUSE and _SNAPROUTE are control" >&2; exit 2;; esac
done
case $CONNWAIT in 0|1|control) ;; *) echo "wire: COULD-NOT-RUN: H2_WIRE_CONNWAIT is 1 or control" >&2; exit 2;; esac
case $LINKDEV in 0|1) ;; *) echo "wire: COULD-NOT-RUN: H2_WIRE_LINKDEV is 1" >&2; exit 2;; esac
case $SNAPDEL$ADMIT in 00|10|control0|01|0control) ;; *) echo "wire: COULD-NOT-RUN: H2_WIRE_SNAPDEL and H2_WIRE_ADMIT are 1 or control" >&2; exit 2;; esac
case $END in ''|aborted|noeof|lost|onefed) ;; *) echo "wire: COULD-NOT-RUN: H2_WIRE_END is aborted, noeof, lost or onefed" >&2; exit 2;; esac
case $STALL in ''|*[!0-9]*) echo "wire: COULD-NOT-RUN: H2_WIRE_STALL is milliseconds" >&2; exit 2;; esac
[ "$STALL" = 0 ] || [ "$STALL" -gt 2000 ] || { echo "wire: COULD-NOT-RUN: H2_WIRE_STALL must exceed B's 2000 ms bound" >&2; exit 2; }
nctl=0
for c in "$REKEY" "$DIRENT" "$REFUSE"; do [ "$c" = 1 ] && nctl=$((nctl + 1)); done
[ "$STALL" = 0 ] || nctl=$((nctl + 1))
[ -z "$END" ] || nctl=$((nctl + 1))
[ "$PASS" = 1 ] && nctl=$((nctl + 1))
[ "$SILENCE" = 0 ] || nctl=$((nctl + 1))
[ "$WINDOW" = 0 ] || nctl=$((nctl + 1))
[ "$LINKDEV" = 0 ] || nctl=$((nctl + 1))
[ "$STALE" = 0 ] || nctl=$((nctl + 1))
[ "$RETYPE" = 0 ] || nctl=$((nctl + 1))
[ -z "$CUT" ] || nctl=$((nctl + 1))
for c in "$ROGATE" "$PASSREFUSE" "$SNAPROUTE" "$SNAPDEL" "$ADMIT" "$CONNWAIT"; do [ "$c" = 0 ] || nctl=$((nctl + 1)); done
[ "$nctl" -le 1 ] || { echo "wire: COULD-NOT-RUN: one control per run" >&2; exit 2; }
# the two snapshot controls, the stale element and the retype run under the pass
{ [ "$SNAPROUTE" = control ] || [ "$SNAPDEL" != 0 ] || [ "$STALE" = 1 ] || [ "$RETYPE" = 1 ] || [ -n "$CUT" ]; } && PASS=1
# the pass the retype or the cut fails ends unverified, once
UNV=$RETYPE; [ -z "$CUT" ] || UNV=1
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
# H2_REPEAT=n runs the cell n times, each on guests booted for it, as
# test-enospc.sh does: KASAN reports once per boot and lockdep turns itself
# off after one report, so a run on a boot that has reported reads nothing.
# Each run's output is kept, and the trail cell's outcomes are tallied from
# the line each run prints.
repeat=${H2_REPEAT:-1}
case $repeat in ''|*[!0-9]*) echo "wire: COULD-NOT-RUN: H2_REPEAT is a run count" >&2; exit 2;; esac
if [ "$repeat" -gt 1 ]; then
	logdir=${H2_LOGDIR:-$HOME/Projects/linux_hammer2-data/p8-notes/wire-repeat-$(date +%Y%m%d-%H%M%S)}
	mkdir -p "$logdir" || exit 2
	# a batch runs this file once per run, so an edit made under it would
	# change the runs after the edit
	sum0=$(sha256sum < "$0") || exit 2
	pass=0; failed=0; cnr=0; i=1
	while [ "$i" -le "$repeat" ]; do
		$VIRSH destroy "$GA" >/dev/null 2>&1; $VIRSH destroy "$GB" >/dev/null 2>&1
		[ "$(sha256sum < "$0")" = "$sum0" ] || { echo "wire: COULD-NOT-RUN: this script changed while the batch was running" >&2; exit 2; }
		H2_REPEAT=1 sh "$0" > "$logdir/run-$i.log" 2>&1
		case $? in 0) pass=$((pass + 1)); v=pass;; 2) cnr=$((cnr + 1)); v=could-not-run;; *) failed=$((failed + 1)); v=fail;; esac
		echo "run $i: $v $(sed -n 's/^  trail-outcome //p' "$logdir/run-$i.log")"
		i=$((i + 1))
	done
	$VIRSH destroy "$GA" >/dev/null 2>&1; $VIRSH destroy "$GB" >/dev/null 2>&1
	echo "wire: $repeat runs, $pass passed, $failed failed, $cnr could not run; logs in $logdir"
	[ "$CUT" = trail ] && for o in closed silent notproxy kasan other; do
		echo "  trail-outcome $o $(cat "$logdir"/run-*.log | grep -c "^  trail-outcome $o\$")"
	done
	[ "$failed" = 0 ] && [ "$cnr" = 0 ]
	exit
fi
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2")}
HAMMER2=${H2_HAMMER2:-$(command -v hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/hammer2")}
FSCK=${H2_FSCK:-$(command -v fsck_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2")}
{ [ "$PASS" != 1 ] && [ "$ROGATE" = 0 ] && [ "$PASSREFUSE" = 0 ]; } || { [ -x "$HAMMER2" ] && [ -x "$FSCK" ]; } || { echo "wire: COULD-NOT-RUN: H2_WIRE_PASS and the controls reading an image need hammer2 and fsck_hammer2 on the host (H2_HAMMER2, H2_FSCK)" >&2; exit 2; }
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
# a power cut's reads cross 5310 files over the wire, warm and cold
RUN="timeout ${H2_RUN_TIMEOUT:-$([ "$POWER" = 1 ] && echo 900 || echo 300)} $SSH"
W=$(mktemp -d) || exit 2
RELAY_PID=
cleanup() {
	[ -n "$RELAY_PID" ] && kill "$RELAY_PID" 2>/dev/null
	rm -rf "$W"
}
trap cleanup EXIT

command -v virsh >/dev/null 2>&1 || { echo "wire: COULD-NOT-RUN: no virsh" >&2; exit 2; }
[ -x "$NEWFS" ] || { echo "wire: COULD-NOT-RUN: no newfs_hammer2 (H2_NEWFS)" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "wire: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -d "$KDIR" ] || { echo "wire: COULD-NOT-RUN: no kernel tree at $KDIR" >&2; exit 2; }
for g in "$GA" "$GB"; do
	$VIRSH domstate "$g" >/dev/null 2>&1 || { echo "wire: COULD-NOT-RUN: no guest $g" >&2; exit 2; }
done

guest_off() {	# guest_off <domain> <ssh>: unmount, unload, detach its volume
	if [ "$($VIRSH domstate "$1" 2>/dev/null)" = running ]; then
		timeout 45 $SSH "$2" 'umount -f /mnt/h2c 2>/dev/null; umount -f /mnt/h2r 2>/dev/null; umount -f /mnt/h2k 2>/dev/null; rmmod hammer2 2>/dev/null; true' >/dev/null 2>&1
	fi
	for t in vdb vdc; do
		$VIRSH detach-disk "$1" $t --live >/dev/null 2>&1
		$VIRSH detach-disk "$1" $t --config >/dev/null 2>&1
	done
}

build() {	# build <out> [make variables]: the module, kept as <out>
	out=$1; shift
	make -s clean >/dev/null 2>&1
	make -s KDIR="$KDIR" "$@" >/dev/null 2>&1 && cp src/sys/fs/hammer2/hammer2.ko "$out" || {
		echo "wire: COULD-NOT-RUN: module did not build against $KDIR${*:+ with $*}" >&2; exit 2; }
}
# One module for both guests, but a control switches a refusal off on the
# side that makes it: the window's on A's server, or with its count off
# B's client too, the keepalive on both, SNAPDEL's scope on A, and the
# read-only gate, the pass's refusal and the snapshot's routing on B, and
# the reconnect's hold on B, the side that dials second.
KO_A=$W/hammer2-a.ko; KO_B=$W/hammer2-b.ko
AFLAGS=; BFLAGS=
[ "$SILENCE" = control ] && AFLAGS=HAMMER2_NOKEEPALIVE=1 BFLAGS=HAMMER2_NOKEEPALIVE=1
[ "$WINDOW" = 0 ] || AFLAGS=HAMMER2_NOWINDOW=1
[ "$WINDOW" = control ] && BFLAGS=HAMMER2_NOCLIENTWINDOW=1
[ "$SNAPDEL" = control ] && AFLAGS=HAMMER2_NOSNAPSCOPE=1
[ "$ROGATE" = control ] && BFLAGS=HAMMER2_NOROGATE=1
[ "$PASSREFUSE" = control ] && BFLAGS=HAMMER2_NOPASSREFUSE=1
[ "$SNAPROUTE" = control ] && BFLAGS=HAMMER2_NOSNAPROUTE=1
[ "$CONNWAIT" = 1 ] && BFLAGS=HAMMER2_CONNWAIT=1
[ "$CONNWAIT" = control ] && BFLAGS="HAMMER2_CONNWAIT=1 HAMMER2_NOCONNFIX=1"
[ "$SEQ" = control ] && BFLAGS=HAMMER2_NOCLIENTSEQ=1
build "$KO_B" $BFLAGS
if [ "$AFLAGS" = "$BFLAGS" ]; then cp "$KO_B" "$KO_A"; else build "$KO_A" $AFLAGS; fi
# What was built, taken now: the tree can move before the report is written.
SRC_REV=$(git describe --always --dirty); KO_SUM=$(sha256sum < "$KO_B" | cut -d' ' -f1); KO_A_SUM=$(sha256sum < "$KO_A" | cut -d' ' -f1)
RELAY_SUM=$(sha256sum < test/h2loop.c | cut -d' ' -f1); WIRE_SUM=$(sha256sum < script/cluster-wire.sh | cut -d' ' -f1)
cc -static -O2 -Isrc/sys/fs/hammer2 -o "$W/h2service" test/h2service.c 2>"$W/cc.err" &&
    cc -static -O2 -Isrc/sys/fs/hammer2 $([ "$ADMIT" = control ] && echo -DH2SERVICE_NOADMIT) -o "$W/h2service-b" test/h2service.c 2>>"$W/cc.err" || {
	echo "wire: COULD-NOT-RUN: test/h2service.c did not build:" >&2; sed 's/^/        /' "$W/cc.err" >&2; exit 2; }
SVC_B_SUM=$(sha256sum < "$W/h2service-b" | cut -d' ' -f1)
cc -std=c11 -O1 -o "$W/h2loop" test/h2loop.c 2>"$W/cc.err" || {
	echo "wire: COULD-NOT-RUN: test/h2loop.c did not build:" >&2; sed 's/^/        /' "$W/cc.err" >&2; exit 2; }

guest_off "$GA" "$SA"
guest_off "$GB" "$SB"
for g in a b $([ "$LINKDEV" = 1 ] && echo k); do
	img=$FIXDIR/wire-$g.img
	rm -f "$img"
	truncate -s 2G "$img" && "$NEWFS" -L ROOT "$img" >/dev/null 2>&1 || {
		echo "wire: COULD-NOT-RUN: newfs_hammer2 failed on $img" >&2; exit 2; }
done
attach() {	# attach <domain> <image> [target]: a guest that is off starts after vdb
	state=$($VIRSH domstate "$1" 2>/dev/null)
	if [ "$state" = running ]; then how=--live; else how=--config; fi
	err=$($VIRSH attach-disk "$1" "$2" "${3:-vdb}" --targetbus virtio $how 2>&1) || {
		echo "wire: COULD-NOT-RUN: could not attach $2 to $1: $err" >&2; exit 2; }
	if [ "$state" != running ] && [ "${3:-vdb}" = vdb ]; then
		$VIRSH start "$1" >/dev/null 2>&1 || { echo "wire: COULD-NOT-RUN: $1 did not start" >&2; exit 2; }
	fi
}
attach "$GA" "$FIXDIR/wire-a.img"
[ "$LINKDEV" = 1 ] && attach "$GB" "$FIXDIR/wire-k.img" vdc
attach "$GB" "$FIXDIR/wire-b.img"
wait_ssh() {	# wait_ssh <domain> <ssh>
	n=0
	until $SSH "$2" true 2>/dev/null; do
		sleep 5; n=$((n + 1))
		[ $n -gt 60 ] && { echo "wire: COULD-NOT-RUN: $1 did not answer ssh in 5 minutes" >&2; exit 2; }
	done
}
wait_ssh "$GA" "$SA"
wait_ssh "$GB" "$SB"
ko_rel=$(modinfo -F vermagic "$KO_B" 2>/dev/null | cut -d' ' -f1)
to_guest() {	# to_guest <domain> <ssh>: its module and daemon, on a boot that can report
	g=$1; s=$2
	if [ "$g" = "$GA" ]; then ko=$KO_A svc=$W/h2service; else ko=$KO_B svc=$W/h2service-b; fi
	rel=$($SSH "$s" uname -r 2>/dev/null)
	[ "$rel" = "$ko_rel" ] || {
		echo "wire: COULD-NOT-RUN: the module is built for $ko_rel and $g runs $rel; point KDIR at the guests' kernel" >&2; exit 2; }
	$SSH "$s" 'command -v hammer2 >/dev/null 2>&1' || { echo "wire: COULD-NOT-RUN: no hammer2 utility on $g" >&2; exit 2; }
	# One lockdep report turns lockdep off until the next boot, and a run
	# on that boot reads "no report" with nothing checking.
	dl=$($SSH "$s" "awk '/debug_locks:/ {print \$2}' /proc/lockdep_stats 2>/dev/null")
	[ "$dl" = 0 ] && {
		echo "wire: COULD-NOT-RUN: lockdep is off on $g since an earlier report; boot it again" >&2; exit 2; }
	# KASAN reports once per boot (mm/kasan/report.c, without kasan_multi_shot)
	kb=$($SSH "$s" "dmesg | grep -c 'BUG: KASAN'")
	[ "${kb:-0}" = 0 ] || {
		echo "wire: COULD-NOT-RUN: $g's boot already holds $kb KASAN report(s), so it reports no more; boot it again" >&2; exit 2; }
	scp -q "$ko" "$s:/tmp/hammer2.ko" && scp -q "$svc" "$s:/tmp/h2service" || {
		echo "wire: COULD-NOT-RUN: copy to $g failed" >&2; exit 2; }
}
to_guest "$GA" "$SA"
to_guest "$GB" "$SB"

stamp=$(date +%Y%m%d-%H%M%S)
: > "$W/relay.out"
relay_start() {	# relay_start <trace>: a relay on the port, its output appended
	n0=$(grep -c "relay listening" "$W/relay.out")
	"$W/h2loop" --relay "$PORT" --seed "$SEED" \
	    ${H2_WIRE_DELAY:+--delay-max "$H2_WIRE_DELAY"} ${H2_WIRE_LOSS:+--loss "$H2_WIRE_LOSS"} \
	    ${H2_WIRE_DUP:+--dup "$H2_WIRE_DUP"} --rekey-data "$REKEY" --bare-dirent "$DIRENT" \
	    --refuse-nresolve "$REFUSE" --retype-scan "$RETYPE" --stall-ms "$STALL" \
	    --end-readdir "$(case $END in aborted) echo 1;; noeof|onefed) echo 2;; lost) echo 3;; *) echo 0;; esac)" \
	    --silence-on "$([ "$SILENCE" = 0 ] || echo keepalive-marker)" \
	    --rename-snapdel "$([ "$SNAPDEL" = 0 ] || echo ZZ.h2sync-src)" \
	    ${CUTAT:+--cut-on-scan "$CUTAT" --cut-fault "$FAULT"} \
	    --trace "$1" >> "$W/relay.out" 2>&1 &
	RELAY_PID=$!
	sleep 0.5
	[ "$(grep -c "relay listening" "$W/relay.out")" -gt "$n0" ] || { echo "wire: COULD-NOT-RUN: the relay did not listen on $PORT" >&2; cat "$W/relay.out" >&2; exit 2; }
}
relay_start "$FIXDIR/wire-run-$stamp.trace"

# The guest half, in phases the host sequences, since B's SLAVE needs A's
# cluster id and the dials must find the relay with A connected first.
# Every number a check reads is printed as `name value`.
cat > "$W/common.sh" <<'GUEST'
set -u
R=/mnt/h2r; C=/mnt/h2c
# The kernel log is streamed to a file from the load on, since a pass over
# the wire prints faster than the ring holds and dmesg alone loses the head.
K=/tmp/h2wire.klog
kl() { cat $K; }
klog() { kl | grep -c "$1"; }
# a line the module prints at an action read just after it: the stream to
# $K can trail the print, so wait for one, at most 5 s
klog1() { n=0; until [ "$(klog "$1")" -ge 1 ] || [ $n -ge 50 ]; do sleep 0.1; n=$((n + 1)); done; klog "$1"; }
threads() { ps -eo comm | grep -c '^hammer2-msg'; }
GUEST
# clmode.awk -v n='"<name>"': the mode of <name> in CL, from a show on
# stdin; an inode prints its mode before its inum, a dirent no mode, so the
# mode is taken only by the inum that follows it. Read on a guest and here.
cat > "$W/clmode.awk" <<'AWK'
/filename "CL"$/ && !on && !past { on = 1; next }
on && /^ *} \(inode\.[0-9]*, "CL"\)/ { on = 0; past = 1; next }
!on { next }
$1 == "filename" { want = ($2 == n); next }
want && $1 == "inum" { inum = $2; want = 0 }
$1 == "mode" { m = $2 }
$1 == "inum" { if (m != "") mode[$2] = m; m = "" }
END { print (inum in mode) ? mode[inum] : "none" }
AWK
cat > "$W/setup.sh" <<'GUEST'
# setup <type> [<clid> [<sync_snapshot> [<decoy>]]]: load, mount ROOT,
# create CL, and on a master a PFS of the name <decoy>, print CL's id
if lsmod 2>/dev/null | grep -q '^hammer2' || mount 2>/dev/null | grep -q ' type hammer2'; then
	echo "wire: COULD-NOT-RUN: the guest still has hammer2 loaded or mounted" >&2; exit 2
fi
dmesg -C
pkill -f 'dmesg -w' 2>/dev/null
setsid -f sh -c 'exec dmesg -w > /tmp/h2wire.klog 2>&1'
SNAP=${3:-1}	# sync_snapshot
{ echo scan > /sys/kernel/debug/kmemleak && echo scan > /sys/kernel/debug/kmemleak && echo clear > /sys/kernel/debug/kmemleak; } 2>/dev/null; echo "kmemleak-cleared"	# an earlier run's leaks are its own
insmod /tmp/hammer2.ko sync_snapshot=$SNAP || { echo "insmod failed"; exit 1; }
# the remote element's lines (0x100), and on a slave whose pass reads a
# snapshot the pass's own (0x8000), which name the snapshot's taking,
# verdict and deletion
dbg=256; { [ "$1" = slave ] && [ "$SNAP" = 1 ]; } || [ -n "${4:-}" ] && dbg=$((256 + 32768))
echo $dbg > /sys/module/hammer2/parameters/debug 2>/dev/null
echo "sync-snapshot $(cat /sys/module/hammer2/parameters/sync_snapshot 2>/dev/null)"
mkdir -p $R $C /tmp/h2keys
mount -t hammer2 /dev/vdb@ROOT $R || { echo "mount failed"; exit 1; }
if [ "$1" = master ]; then
	hammer2 -s $R pfs-create CL >/dev/null 2>&1 || { echo "pfs-create failed"; exit 1; }
	if [ -n "${4:-}" ]; then
		hammer2 -s $R pfs-create "$4" >/dev/null 2>&1; echo "decoy-rc $?"
	fi
else
	hammer2 -s $R -t SLAVE -u "$2" pfs-create CL >/dev/null 2>&1 || { echo "slave pfs-create failed"; exit 1; }
fi
echo "clid $(hammer2 -s $R pfs-clid CL 2>/dev/null)"
echo "pfs-count $(hammer2 -s $R pfs-list 2>/dev/null | awk 'NR>1' | grep -c .)"
# which utility reads the media: the C show and the Rust one stop short differently
echo "utility $(command -v hammer2) $(hammer2 --version 2>&1 | head -1)"
GUEST
cat > "$W/dial.sh" <<'GUEST'
# dial <clid> <host> <port> <ro|rw> [noadmit] [linkdev]: one admitted row,
# then the dial; with ro the device is opened again read-only between the
# two, so the slave's pass refuses to run and every read on B's CL is the
# remote element's alone; with noadmit a dial is made first with no
# marker; with linkdev the row and the link are a second volume's, vdc
L=$R
case " $* " in *" linkdev "*)
	mkdir -p /mnt/h2k
	mount -t hammer2 /dev/vdc@ROOT /mnt/h2k || { echo "mount vdc failed"; exit 1; }
	L=/mnt/h2k; echo "linkdev 1"
	# a connection spans its own device's PFSes, so A sees vdc's
	echo "link-pfs-count $(hammer2 -s $L pfs-list 2>/dev/null | awk 'NR>1' | grep -c .)";;
esac
touch /tmp/h2keys/peer.none
/tmp/h2service add $L --clid "$1" --label peer --path "span:$2:$3" | sed 's/^/add /'
# REMOTE_ADD only marks the volume data modified, as upstream's does, so
# the row is on media after the next 30 s syncer pass; a power cut sooner
# lost A's row on the lockdep kernel.  The ro remount below flushes B's.
sync -f $L; echo "add-sync-rc $?"
if [ "$4" = ro ]; then
	umount $R && mount -t hammer2 -o ro /dev/vdb@ROOT $R || { echo "ROOT read-only failed"; exit 1; }
	echo "root-ro 1"
fi
if [ "${5:-}" = noadmit ]; then
	rm -f /tmp/h2keys/peer.none
	/tmp/h2service dial $L --keys /tmp/h2keys > /tmp/h2wire.dial0 2>&1; r=$?
	echo "noadmit-dial-rc $r"
	echo "noadmit-refused $(grep -c 'auth failure: unknown host' /tmp/h2wire.dial0)"
	sed 's/^/dial0 /' /tmp/h2wire.dial0
	touch /tmp/h2keys/peer.none
	[ "$r" = 0 ] && { echo "dial-rc 0"; exit 0; }
fi
# the dial's own status, not a pipe's
/tmp/h2service dial $L --keys /tmp/h2keys > /tmp/h2wire.dial 2>&1; r=$?
sed 's/^/dial /' /tmp/h2wire.dial
echo "dial-rc $r"
GUEST
cat > "$W/fill.sh" <<'GUEST'
# fill [bulk]: A's MASTER CL mounted read-write and given a known tree; with
# "more", a second set written on the mounted CL after the slave's first
# pass, which a later pass must copy
if [ "${1:-}" = stale ]; then
	# the 512 KiB file's first block rewritten on the master alone, once
	# the slave's pass can no longer copy it
	dd if=/dev/urandom of=$C/big.bin bs=65536 count=1 conv=notrunc 2>/dev/null; echo "stale-write-rc $?"
	sync
	(cd $C && sha256sum ./big.bin) | sed 's/^\([0-9a-f]*\)  \(.*\)/stalesum \2 \1/'
	exit 0
fi
if [ "${1:-}" = more ]; then
	mkdir -p $C/more
	i=0; while [ $i -lt 5 ]; do head -c 4096 /dev/urandom > $C/more/m$i; i=$((i + 1)); done
	sync
	echo "more-media-files $(hammer2 -v show /dev/vdb 2>/dev/null | grep -c 'filename "m[0-9]')"
	echo "more-files $(find $C/more -type f | grep -c .)"
	(cd $C && find ./more -type f | sort | xargs sha256sum) | sed 's/^\([0-9a-f]*\)  \(.*\)/sum \2 \1/'
	exit 0
fi
mount -t hammer2 /dev/vdb@CL $C || { echo "mount CL failed"; exit 1; }
mkdir -p $C/dir1
printf 'the remote element reads this line\n' > $C/small.txt
head -c 524288 /dev/urandom > $C/big.bin
head -c 262144 /dev/zero > $C/zeros.bin
head -c 70000 /dev/urandom > $C/dir1/inner.bin
echo long > "$C/a-name-longer-than-the-sixty-four-bytes-a-blockref-embeds-for-a-dirent.txt"
# More entries than one readdir XOP takes (HAMMER2_READDIR_NMAX, 255), so
# a listing on B crosses the peer's stopping key.
mkdir -p $C/many $C/empty
i=0; while [ $i -lt 300 ]; do : > $C/many/e$i; i=$((i + 1)); done
# with "bulk", 5000 files of 1 KiB more, b0000 to b4999, so a power cut
# placed by the pass's count of inodes lands with most of them to copy
if [ "${1:-}" = bulk ]; then
	mkdir -p $C/bulk
	head -c 5120000 /dev/urandom | (cd $C/bulk && split -b 1024 -a 4 -d - b)
	echo "bulk $(find $C/bulk -type f | grep -c .)"
fi
sync
echo "many $(find $C/many -mindepth 1 | grep -c .)"
# the pattern B's empty slave is read with, matched on the master's media
echo "media-files $(hammer2 -v show /dev/vdb 2>/dev/null | grep -c 'filename "e[0-9]')"
echo "files $(cd $C && find . -type f | grep -c .)"
(cd $C && find . -type f | sort | xargs sha256sum) | sed 's/^\([0-9a-f]*\)  \(.*\)/sum \2 \1/'
GUEST
cat > "$W/lone.sh" <<'GUEST'
# lone: B's SLAVE CL alone has no master to answer its root, so it must not
# mount; what B later reads through CL can only have come over the wire
mount -t hammer2 -o ro /dev/vdb@CL $C 2>/dev/null; echo "lone-mount-rc $?"
mountpoint -q $C && umount $C
true
GUEST
cat > "$W/reg.sh" <<'GUEST'
# reg: B's kernel registered A's CL root as an element
echo "log-registered $(klog 'remote element CL registered at clindex 1')"
echo "log-nmasters $(kl | grep 'remote element CL registered' | tail -1 | sed 's/.*pfs_nmasters //')"
GUEST
cat > "$W/ro.sh" <<'GUEST'
# ro: B's SLAVE CL mounted read-only beside its read-write ROOT, once the
# remote master is registered
mount -t hammer2 -o ro /dev/vdb@CL $C || { echo "mount CL ro failed"; exit 1; }
echo "ro-mounted 1"
GUEST
cat > "$W/pass.sh" <<'GUEST'
# pass: B's slave element is written by its synchronization pass from A's
# master over the wire; wait on the media, not the clock, for the master's
# 300-entry directory to appear under B's CL, with a bound, and then for
# the pass's snapshot to be deleted, which is the pass's end.  With "more",
# the second set's five files, and a later pass's end.
if [ "${1:-}" = first ]; then
	# a control's pass: whether one copies A's files, read within 180 s,
	# and what refused or failed on the way
	n=0
	until [ "$(hammer2 -v show /dev/vdb 2>/dev/null | grep -c 'filename "e[0-9]')" -ge 300 ] || [ $n -ge 180 ]; do sleep 2; n=$((n + 2)); done
	echo "first-wait-seconds $n"
	echo "first-media-files $(hammer2 -v show /dev/vdb 2>/dev/null | grep -c 'filename "e[0-9]')"
	echo "first-refused-lines $(klog 'sync pass refused on clindex')"
	echo "first-snap-errors $(klog 'syncsnap: snapshot CL.h2sync-src error')"
	echo "first-remote-snaps $(klog 'syncsnap: remote snapshot CL.h2sync-src tid')"
	echo "first-snap-eopnotsupp $(klog 'syncsnap: snapshot CL.h2sync-src error 95$')"
	echo "first-sync-errors $(klog 'hammer2_sync_slaves: error')"
	exit 0
fi
if [ "${1:-}" = more ]; then
	# the first pass's own count, handed in: one read here, after the
	# fill, would already count a later pass that ended before it
	d0=${2:-$(klog 'syncsnap: remote delete .* error 00000000')}; n=0
	until [ "$(hammer2 -v show /dev/vdb 2>/dev/null | grep -c 'filename "m[0-9]')" -ge 5 ] || [ $n -ge 180 ]; do sleep 2; n=$((n + 2)); done
	echo "more-wait-seconds $n"
	echo "more-media-files $(hammer2 -v show /dev/vdb 2>/dev/null | grep -c 'filename "m[0-9]')"
	n=0; until [ "$(klog 'syncsnap: remote delete .* error 00000000')" -gt "$d0" ] || [ $n -ge 120 ]; do sleep 1; n=$((n + 1)); done
	echo "more-end-seconds $n"
	echo "more-snap-deleted $(( $(klog 'syncsnap: remote delete .* error 00000000') - d0 ))"
	echo "more-snap-verified $(klog 'syncsnap: verified clindex')"
	echo "more-snap-unverified $(klog 'syncsnap: unverified clindex')"
	# the idle test over the wire: with the master quiet again the thread
	# must stop snapshotting it, read as the taken count over 12 s
	t0=$(klog 'syncsnap: remote snapshot CL.h2sync-src tid'); sleep 12
	echo "more-snap-idle-taken $(( $(klog 'syncsnap: remote snapshot CL.h2sync-src tid') - t0 ))"
	echo "more-snap-idle-passes $(klog 'syncsnap: idle clindex')"
	exit 0
fi
n=0
until [ "$(hammer2 -v show /dev/vdb 2>/dev/null | grep -c 'filename "e[0-9]')" -ge 300 ] || [ $n -ge 240 ]; do sleep 2; n=$((n + 2)); done
echo "pass-wait-seconds $n"
echo "pass-media-files $(hammer2 -v show /dev/vdb 2>/dev/null | grep -c 'filename "e[0-9]')"
# a pass that fails still deletes its snapshot, so under a control that
# fails one the end is the second deletion ($1)
n=0; until [ "$(klog 'syncsnap: remote delete .* error 00000000')" -ge "${1:-1}" ] || [ $n -ge 240 ]; do sleep 1; n=$((n + 1)); done
echo "pass-end-seconds $n"
echo "pass-snap-taken $(klog 'syncsnap: remote snapshot CL.h2sync-src tid')"
echo "pass-snap-bad $(klog 'syncsnap: remote snapshot CL.h2sync-src fed')"
echo "pass-snap-passes $(klog 'syncsnap: pass clindex')"
echo "pass-snap-verified $(klog 'syncsnap: verified clindex')"
echo "pass-snap-unverified $(klog 'syncsnap: unverified clindex')"
echo "pass-unverified-first $(kl | grep -m1 'syncsnap: unverified clindex' | sed 's/.*syncsnap: unverified clindex [0-9]* //')"
echo "pass-snap-interrupted $(klog 'syncsnap: interrupted clindex')"
# the thread passes from the slave's pfs-create, before the element is
# registered, and those find no source; one after the first snapshot would
# mean the element went away
echo "pass-snap-noquorum $(kl | sed -n '/syncsnap: remote snapshot CL.h2sync-src tid/,$p' | grep -c 'syncsnap: noquorum clindex')"
echo "pass-snap-deleted $(klog 'syncsnap: remote delete .* error 00000000')"
echo "pass-snap-delete-errors $(kl | grep 'syncsnap: remote delete' | grep -vc 'error 00000000')"
echo "pass-snap-target-taken $(klog 'syncsnap: target .* taken')"
# the scan's own debug line, "sync_slaves error N defer", is every return of
# it; an error is one neither 0 nor the deferral's EAGAIN (256)
echo "pass-errors $(kl | grep 'sync_slaves error' | grep -vc -E 'error (0|256) defer')"
echo "pass-sync-errors $(klog 'hammer2_sync_slaves: error')"
echo "pass-refused-lines $(klog 'sync pass refused on clindex')"
echo "pass-remote-xops $(klog 'H2 REMOTE ')"
echo "pass-remote-ends $(kl | grep 'H2 REMOTE ' | grep -c -v 'end=00000000')"
echo "pass-warnings $(kl | grep -c -E 'WARNING|BUG:|UBSAN:|KASAN|circular locking|possible recursive')"
GUEST
cat > "$W/stale.sh" <<'GUEST'
# stale <down|up>: B's device opened again read-only after the pass, which
# ends the link, and dialed again, so the pass refuses on it and the slave
# keeps the copy it holds
if [ "$1" = down ]; then
	umount $C && umount $R || { echo "stale unmount failed"; exit 1; }
	echo "stale-detached $(klog1 'remote element CL at clindex 1 detached')"
	mount -t hammer2 -o ro /dev/vdb@ROOT $R || { echo "stale ROOT read-only failed"; exit 1; }
	exit 0
fi
/tmp/h2service dial $R --keys /tmp/h2keys > /tmp/h2wire.dial2 2>&1; r=$?
sed 's/^/redial /' /tmp/h2wire.dial2
echo "stale-dial-rc $r"
n=0; until [ "$(klog 'remote element CL registered at clindex 1')" -ge 2 ] || [ $n -ge 100 ]; do sleep 0.1; n=$((n + 1)); done
echo "stale-registered $(klog 'remote element CL registered at clindex 1')"
mount -t hammer2 -o ro /dev/vdb@CL $C || { echo "stale mount CL ro failed"; exit 1; }
GUEST
cat > "$W/redial.sh" <<'GUEST'
# redial: A dials again by the row already on its ROOT, once the link B's
# unmount ended has let its message threads go
n=0; until [ "$(threads)" = 0 ] || [ $n -ge 100 ]; do sleep 0.1; n=$((n + 1)); done
echo "redial-threads-before $(threads)"
/tmp/h2service dial $R --keys /tmp/h2keys > /tmp/h2wire.dial2 2>&1; echo "redial-rc $?"
GUEST
cat > "$W/cut.sh" <<'GUEST'
# cut <go|arm|mark|up|silent|wait|redial|resumed|peer [after]>: the link the relay closed inside
# the pass, read on B at the cut, on B again at the dial and after the pass
# that follows it, and on A for the snapshot the link left
V='syncsnap: (verified|newer|unverified|interrupted) clindex'
D='remote element CL at clindex 1 detached'
case $1 in
go)
	# the device read-only since the dial, the pass refused until now
	echo "cut-refused-before $(klog 'sync pass refused on clindex')"
	echo "cut-snap-before-go $(klog 'syncsnap: remote snapshot CL.h2sync-src tid')"
	# the count a power cut is placed from, before the pass can start
	echo "cut-update-base $(klog 'syncthr: update inode')"
	mount -o remount,rw $R; echo "cut-root-rw-rc $?"
	;;
arm)
	# arm <base> <depth>: a power cut's placement, once the pass has updated
	# <depth> inodes past <base> or ended; no sync, the cut takes what it finds
	n=0
	until [ $(( $(klog 'syncthr: update inode') - $2 )) -ge "$3" ] || [ "$(kl | grep -c -E "$V")" -ge 1 ] || [ $n -ge 2400 ]; do sleep 0.05; n=$((n + 1)); done
	echo "cut-arm-updates $(( $(klog 'syncthr: update inode') - $2 ))"
	echo "cut-arm-verdicts $(kl | grep -c -E "$V")"
	echo "cut-arm-snap $(klog 'syncsnap: remote snapshot CL.h2sync-src tid')"
	echo "cut-printk $(cat /proc/sys/kernel/printk | tr '\t' ' ')"
	;;
mark)
	# the host saw the relay's fault: a line in this log, and the pass's
	# snapshots and verdicts before it; the line trails the fault by the
	# host's poll and an ssh, about 0.4 s, as long as a verify round takes,
	# so its verdict count is printed and the placement is read from B's
	# own HM2 line or the relay's next call
	echo "h2wire fault seen" > /dev/kmsg
	n=0; until grep -q 'h2wire fault seen' $K || [ $n -ge 50 ]; do sleep 0.1; n=$((n + 1)); done
	echo "cut-mark-snap $(kl | awk '/h2wire fault seen/ { exit } /syncsnap: remote snapshot CL.h2sync-src tid/ { n++ } END { print n + 0 }')"
	echo "cut-mark-verdicts $(kl | awk -v v="$V" '/h2wire fault seen/ { exit } /syncsnap: remote snapshot CL.h2sync-src tid/ { s = 1 } s && $0 ~ v { n++ } END { print n + 0 }')"
	;;
hm2)
	# the verdicts before B's first HM2 line, which its check prints at the
	# frame's receipt: the fault on B's own clock, or none
	echo "cut-hm2-verdicts $(kl | awk -v v="$V" '/hammer2: HM2 / { h = 1; exit } /syncsnap: remote snapshot CL.h2sync-src tid/ { s = 1 } s && $0 ~ v { n++ } END { print h ? n + 0 : "none" }')"
	;;
up)
	# the link left up past the fault: the faulted pass's verdict, bounded,
	# and what B said of the link by then; read from the pass's snapshot,
	# which the placement check puts before the fault, since the mark can
	# trail the verdict
	nv() { kl | awk -v v="$V" '/syncsnap: remote snapshot CL.h2sync-src tid/ { s = 1 } s && $0 ~ v { n++ } END { print n + 0 }'; }
	n=0; until [ "$(nv)" -ge 1 ] || [ $n -ge 240 ]; do sleep 1; n=$((n + 1)); done
	echo "cut-up-seconds $n"
	echo "cut-up-verdict $(kl | awk -v v="$V" '/syncsnap: remote snapshot CL.h2sync-src tid/ { s = 1 } s && $0 ~ v { sub(/.*syncsnap: /, ""); print $1; exit }')"
	echo "cut-up-ending $(klog 'ending the link')"
	echo "cut-up-detached $(klog "$D")"
	echo "cut-up-notproxy $(klog 'not a proxy')"
	echo "cut-up-hm2 $(klog 'hammer2: HM2 ')"
	echo "cut-up-hm2-text $(kl | sed -n 's/.*hammer2: HM2 //p' | tr '\n' ';')"
	;;
silent)
	# the survivor's own end of the link, or 30 s, whichever came first
	t0=$(date +%s%N)
	n=0; until [ "$(klog 'HM2 peer silent')" -ge 1 ] || [ $n -ge 300 ]; do sleep 0.1; n=$((n + 1)); done
	echo "cut-silent-line $(klog 'HM2 peer silent')"
	echo "cut-silent-wait-ms $(( ($(date +%s%N) - t0) / 1000000 ))"
	echo "cut-silent-ms $(kl | sed -n 's/.*HM2 peer silent for \([0-9]*\) ms.*/\1/p' | head -1)"
	echo "cut-silent-detached $(klog "$D")"
	;;
wait)
	n=0; until [ "$(klog "$D")" -ge 1 ] || [ $n -ge 240 ]; do sleep 1; n=$((n + 1)); done
	echo "cut-detach-seconds $n"
	n=0; until [ "$(kl | grep -c -E "$V")" -ge 1 ] || [ $n -ge 120 ]; do sleep 1; n=$((n + 1)); done
	echo "cut-verdict-seconds $n"
	# past the thread's 5 s idle sleep, since nothing wakes it on a detach;
	# the gap is read on the printk clock, from the verdict to this line
	sleep 7
	echo "h2wire cut gap end" > /dev/kmsg
	n=0; until grep -q 'h2wire cut gap end' $K || [ $n -ge 50 ]; do sleep 0.1; n=$((n + 1)); done
	echo "cut-gap-ms $(kl | awk -F'[][]' -v v="$V" '$0 ~ v && t == "" { t = $2 } /h2wire cut gap end/ { if (t != "") printf "%d\n", ($2 - t) * 1000; exit }')"
	echo "cut-detached $(klog "$D")"
	echo "cut-detached-why $(kl | grep "$D" | sed 's/.*detached: //' | tr '\n' ' ')"
	echo "cut-verified $(klog 'syncsnap: verified clindex')"
	echo "cut-unverified $(klog 'syncsnap: unverified clindex')"
	echo "cut-unverified-line $(kl | grep -m1 'syncsnap: unverified clindex' | sed 's/.*syncsnap: unverified clindex [0-9]* //')"
	echo "cut-other-verdicts $(kl | grep -c -E 'syncsnap: (newer|interrupted) clindex')"
	# the placement: the pass's snapshot read before the cut, and no verdict
	# between the two, or the cut fell after a pass had already ended
	echo "cut-snap-before $(kl | awk -v d="$D" '$0 ~ d { exit } /syncsnap: remote snapshot CL.h2sync-src tid/ { n++ } END { print n + 0 }')"
	echo "cut-verdicts-before $(kl | awk -v d="$D" -v v="$V" '$0 ~ d { exit } /syncsnap: remote snapshot CL.h2sync-src tid/ { s = 1 } s && $0 ~ v { n++ } END { print n + 0 }')"
	# with the slot empty and pfs_nmasters unchanged every pass in the gap
	# finds no quorum and copies nothing
	echo "cut-noquorum $(kl | awk -v d="$D" '$0 ~ d { s = 1 } s && /syncsnap: noquorum clindex/ { n++ } END { print n + 0 }')"
	echo "cut-updates-before $(kl | awk -v d="$D" '$0 ~ d { exit } /syncthr: update inode/ { n++ } END { print n + 0 }')"
	# how each remote call that did not end clean ended, by its code
	echo "cut-remote-ends $(kl | grep 'H2 REMOTE ' | grep -v 'end=00000000' | sed 's/.*H2 REMOTE \([a-z_]*\) .* end=\([0-9a-f]*\).*/\1:\2/' | sort | uniq -c | awk '{ printf "%s=%s ", $2, $1 }')"
	# the remote calls that started after the link's end on B, the detach
	# or the first call to end ENOTCONN, whichever came first, and before
	# the verdict, a start being the line's time less its ms; a call ending
	# at its own deadline (ETIMEDOUT) is not the link's end, and a call
	# started after it waits on a link still up until the keepalive ends it;
	# the cut pass's verdict, the first after its snapshot, closes the
	# window even when it comes before the link's end
	kl | awk -F'[][]' -v d="$D" -v v="$V" '/syncsnap: remote snapshot CL.h2sync-src tid/ { p = 1 }
	    p && $0 ~ v { exit }
	    ($0 ~ d || (/H2 REMOTE / && /end=00080000/)) && t == "" { t = $2 + 0; next }
	    t != "" && /H2 REMOTE / { m = $0; sub(/.*ms=/, "", m); m += 0
		if ($2 - m / 1000 > t + 0.05) { n++; if (m >= 400) s++; if (m > x) x = m } }
	    END { printf "cut-after-calls %d\ncut-after-slow %d\ncut-after-max-ms %d\n", n, s, x }'
	echo "cut-target-taken $(klog 'syncsnap: target .* taken')"
	echo "cut-target-kept $(klog 'syncsnap: target .* kept')"
	echo "cut-scanall-notconn $(klog 'H2 REMOTE scanall .* end=00080000')"
	echo "cut-delete-errors $(kl | grep 'syncsnap: remote delete' | grep -vc 'error 00000000')"
	echo "cut-hm2 $(klog 'hammer2: HM2 ')"
	echo "cut-hm2-text $(kl | sed -n 's/.*hammer2: HM2 //p' | tr '\n' ';')"
	;;
redial)
	n=0; until [ "$(threads)" = 0 ] || [ $n -ge 100 ]; do sleep 0.1; n=$((n + 1)); done
	echo "cut-threads-before $(threads)"
	/tmp/h2service dial $R --keys /tmp/h2keys > /tmp/h2wire.dial3 2>&1; r=$?
	sed 's/^/cutdial /' /tmp/h2wire.dial3
	echo "cut-dial-rc $r"
	n=0; until [ "$(klog 'remote element CL registered at clindex 1')" -ge 2 ] || [ $n -ge 100 ]; do sleep 0.1; n=$((n + 1)); done
	echo "cut-registered $(klog 'remote element CL registered at clindex 1')"
	;;
resumed)
	# from the gap's line on: the first pass to read a snapshot is the
	# resumed one, and its target was taken before the cut
	kl | sed -n '/h2wire cut gap end/,$p' > /tmp/h2wire.after
	echo "cut-resumed-verdict $(awk -v v="$V" '/syncsnap: remote snapshot CL.h2sync-src tid/ { s = 1 } s && $0 ~ v { sub(/.*syncsnap: /, ""); print $1; exit }' /tmp/h2wire.after)"
	echo "cut-resumed-target $(grep -c 'syncsnap: target ' /tmp/h2wire.after)"
	echo "cut-resumed-kept $(grep -c 'syncsnap: target .* kept' /tmp/h2wire.after)"
	# the first two verdicts in order, and each key a pass kept by its
	# tid rather than compared (debug 0x8000); a newer pass also deletes
	# its source, which ends pass.sh's wait, so the next verdict is
	# waited for here, bounded, and the wait printed
	nv() { kl | sed -n '/h2wire cut gap end/,$p' | awk -v v="$V" '/syncsnap: remote snapshot CL.h2sync-src tid/ { s = 1 } s && $0 ~ v { n++ } END { print n + 0 }'; }
	n=0; if [ "$(nv)" = 1 ] && grep -q 'syncsnap: newer clindex' /tmp/h2wire.after; then
		until [ "$(nv)" -ge 2 ] || [ $n -ge 60 ]; do sleep 1; n=$((n + 1)); done
		kl | sed -n '/h2wire cut gap end/,$p' > /tmp/h2wire.after
	fi
	echo "cut-resumed-second-wait $n"
	echo "cut-resumed-verdicts $(awk -v v="$V" '/syncsnap: remote snapshot CL.h2sync-src tid/ { s = 1 } s && $0 ~ v { sub(/.*syncsnap: /, ""); printf "%s ", $1; if (++n == 2) exit }' /tmp/h2wire.after)"
	echo "cut-resumed-kept-keys $(grep -c 'syncsnap: kept ' /tmp/h2wire.after)"
	grep -m 20 'syncsnap: kept ' /tmp/h2wire.after | sed 's/^/cut-resumed-kept-line /'
	echo "cut-resumed-hm2 $(grep -c 'hammer2: HM2 ' /tmp/h2wire.after)"
	;;
peer)
	# the link's snapshot on A is deleted at the next connection's end,
	# the redial's or the unmount's, never at the cut
	if [ "${2:-}" = after ]; then c=$(klog1 'snapshot .* left by the link deleted'); else c=$(klog 'snapshot .* left by the link deleted'); fi
	echo "cut-link-left${2:+-$2} $c"
	echo "cut-peer-hm2${2:+-$2} $(klog 'hammer2: HM2 ')"
	echo "cut-stale-deleted${2:+-$2} $(klog 'syncsnap: stale .* deleted for a peer')"
	;;
esac
GUEST
cat > "$W/read.sh" <<'GUEST'
# read <stall ms> <end mode or 0> <silence or 0> <rogate or 0>: B reads A's
# files through the element; the arguments ride ssh's command line, so none
# is empty
mountpoint -q $C || { echo "CL not mounted"; exit 1; }
P=/sys/module/hammer2/parameters/remote_timeout_ms
[ "${1:-0}" = 0 ] || echo 2000 > $P
echo "remote-timeout-ms $(cat $P)"
# the run's first lookup, so the dirent control knows the name it answers
stat $C/small.txt >/dev/null 2>/tmp/h2wire.staterr; echo "first-stat-rc $?"
echo "first-stat-notconn $(grep -c 'not connected' /tmp/h2wire.staterr)"
echo "first-stat-enoent $(grep -c 'No such file' /tmp/h2wire.staterr)"
echo "first-stat-unsupported $(grep -c 'not supported' /tmp/h2wire.staterr)"
echo "first-stat-err $(sed -n '1s/.*: //p' /tmp/h2wire.staterr)"
# the end control's listing, the run's first: the empty directory, or
# under onefed the 300-entry directory one entry per getdents64 call, a
# 32-byte buffer holding one 24-byte entry, so every readdir asks for one
if [ "${2:-}" = onefed ]; then
	python3 - $C/many <<'PY' 2>/tmp/h2wire.emptyerr; echo "empty-ls-rc $?"
import ctypes, os, sys
libc = ctypes.CDLL(None, use_errno=True)
fd = os.open(sys.argv[1], os.O_RDONLY | os.O_DIRECTORY)
buf = ctypes.create_string_buffer(32)
n = 1
calls = 0
while n > 0:
    n = libc.syscall(217, fd, buf, 32)
    if n < 0:
        sys.exit("getdents64: " + os.strerror(ctypes.get_errno()))
    calls += n > 0
print("onefed-entries %d" % calls)
PY
	echo "empty-ls-notconn $(grep -c 'not connected' /tmp/h2wire.emptyerr)"
	echo "empty-ls-err $(sed -n '1s/.*: //p' /tmp/h2wire.emptyerr)"
elif [ "${2:-0}" != 0 ]; then
	ls $C/empty >/dev/null 2>/tmp/h2wire.emptyerr; echo "empty-ls-rc $?"
	echo "empty-ls-notconn $(grep -c 'not connected' /tmp/h2wire.emptyerr)"
	echo "empty-ls-err $(sed -n '1s/.*: //p' /tmp/h2wire.emptyerr)"
fi
# and the first listing otherwise, which the stall control holds
echo "files $(cd $C && find . -type f 2>/tmp/h2wire.finderr | grep -c .)"
echo "find-notconn $(grep -c 'not connected' /tmp/h2wire.finderr)"
if [ "${1:-0}" != 0 ]; then
	sleep $(($1 / 1000 + 2))
	echo 10000 > $P
fi
echo "many $(find $C/many -mindepth 1 2>/dev/null | grep -c .)"
# fiemap is the bmap XOP over the wire, past the first block
filefrag -v $C/big.bin > /tmp/h2wire.frag 2>&1; echo "fiemap-rc $?"
echo "fiemap-extents $(grep -c '^ *[0-9][0-9]*:' /tmp/h2wire.frag)"
echo "fiemap-unknown $(grep '^ *[0-9][0-9]*:' /tmp/h2wire.frag | grep -c unknown_loc)"
echo "fiemap-first-unknown $(grep '^ *0: *0\.\.' /tmp/h2wire.frag | grep -c unknown_loc)"
sed 's/^/frag /' /tmp/h2wire.frag
filefrag -v $C/dir1/inner.bin > /tmp/h2wire.frag2 2>&1; echo "fiemap2-rc $?"
echo "fiemap2-extents $(grep -c '^ *[0-9][0-9]*:' /tmp/h2wire.frag2)"
echo "fiemap2-unknown $(grep '^ *[0-9][0-9]*:' /tmp/h2wire.frag2 | grep -c unknown_loc)"
sed 's/^/frag2 /' /tmp/h2wire.frag2
# a soft lockup in the digests is read against cpu0's hardirq and steal
# ticks and the interrupts behind them, before and after
irqs() { echo "$1 $(awk '/^cpu0 / { print "irq", $7, "softirq", $8, "steal", $9 }' /proc/stat) $(awk '/ttyS0|^ *(CAL|LOC):/ { printf "%s %s ", $1, $2 }' /proc/interrupts)"; }
irqs digest-irqs-before
(cd $C && find . -type f | sort | xargs sha256sum) 2>&1 | sed 's/^\([0-9a-f]*\)  \(.*\)/sum \2 \1/'
mount -o remount,rw $C 2>/dev/null; echo "remount-rc $?"
echo "log-remount-refused $(klog1 'read-write remount refused: a remote element')"
echo 3 > /proc/sys/vm/drop_caches
(cd $C && find . -type f | sort | xargs sha256sum) 2>&1 | sed 's/^\([0-9a-f]*\)  \(.*\)/cold \2 \1/'
irqs digest-irqs-after
echo "remote-xops $(klog 'H2 REMOTE ')"
# a failed folio read names each element's feed (debug 0x100)
echo "read-failed $(klog 'H2 READ inum')"
kl | grep -m 12 'H2 READ ' | sed 's/^/read-failed-line /'
# a soft lockup in an idle guest is read beside the host's preemption of it
echo "steal-ticks $(awk '/^cpu / { print $9 }' /proc/stat)"
echo "pass-refused $(klog 'sync pass refused on clindex')"
# the read-only gate's control: CL was remounted read-write above, so once
# the live pass has put small.txt on the slave it is written through CL,
# after every digest is taken, and the slave's inode read back at once,
# before a later pass can bring it level again
if [ "${4:-0}" != 0 ]; then
	n=0; until [ "$(hammer2 -v show /dev/vdb 2>/dev/null | grep -c 'filename "small.txt"')" -ge 1 ] || [ $n -ge 60 ]; do sleep 2; n=$((n + 2)); done
	echo "rogate-wait-seconds $n"
	hammer2 emergency-mode-enable $C > /tmp/h2wire.emerg 2>&1; echo "rogate-emerg-rc $?"
	echo 3 > /proc/sys/vm/drop_caches
	chmod 600 $C/small.txt 2>/tmp/h2wire.rogerr; echo "rogate-write-rc $?"
	echo "rogate-write-err $(sed -n '1s/.*: //p' /tmp/h2wire.rogerr)"
	sync
	echo "rogate-slave-mode $(hammer2 -v show /dev/vdb 2>/dev/null | awk -v n='"small.txt"' -f /tmp/clmode.awk)"
fi
show=$(hammer2 -v show /dev/vdb 2>&1); echo "slave-show-rc $?"
echo "slave-files $(printf '%s\n' "$show" | grep -c 'filename "e[0-9]')"
echo "slave-cl $(printf '%s\n' "$show" | grep -c 'filename "CL"')"
# show prints a name before it recurses and stops short of a subtree on a
# failed check, saying "failed)", while its status stays 0; the C show
# says "(bad block size" too, and the Rust one fails a read with a status
echo "slave-show-failed $(printf '%s\n' "$show" | grep -c -E 'failed\)|bad block size')"
echo "refetches $(klog 'H2 REFETCH')"
echo "log-not-proxy $(klog 'not a proxy')"
echo "log-not-proxy-bmap $(klog 'HM2 bmap feed of type 3 not a proxy')"
echo "log-not-proxy-nresolve $(klog 'HM2 nresolve feed of type 4 not a proxy')"
echo "log-not-proxy-scanall $(klog 'HM2 scanall feed of type 3 not a proxy')"
echo "log-scanall-notconn $(klog 'H2 REMOTE scanall .* end=00080000')"
echo "log-peer-sent $(klog 'HM2 peer sent')"
echo "log-window-ended $(klog 'HM2 peer sent a feed past the window')"
echo "log-window-taken $(klog 'HM2 feed past the window taken')"
echo "log-nresolve-notconn $(klog 'H2 REMOTE nresolve .* end=00080000')"
echo "log-readdir-timedout $(klog 'H2 REMOTE readdir .* end=00040000')"
echo "readdir-timedout-ms $(kl | sed -n 's/.*H2 REMOTE readdir .* end=00040000 ms=\([0-9]*\).*/\1/p' | sort -n | head -1)"
echo "log-readdir-notconn $(klog 'H2 REMOTE readdir .* end=00080000')"
echo "log-readdir-first $(kl | grep -m1 'H2 REMOTE readdir ' | sed 's/.* fed=/fed=/; s/ ms=.*//')"
echo "log-readdir-other $(kl | grep 'H2 REMOTE readdir ' | grep -vc 'end=00080000')"
echo "log-readdir-onefed-notconn $(klog 'H2 REMOTE readdir .* fed=1 error=00080000 end=00080000')"
echo "log-bmap-notconn $(klog 'H2 REMOTE bmap .* end=00080000')"
# the keepalive: a name A does not have arms the relay's silence at its
# answer, so no request is in flight when the frames stop; the bound is
# 2000 ms from here, the keepalive reading it at its next tick
if [ "${3:-0}" != 0 ]; then
	echo 2000 > $P
	stat $C/keepalive-marker >/dev/null 2>/tmp/h2wire.silerr; echo "silence-stat-rc $?"
	echo "silence-stat-enoent $(grep -c 'No such file' /tmp/h2wire.silerr)"
	t0=$(date +%s%N)
	n=0; until [ "$(klog 'HM2 peer silent')" -ge 1 ] || [ $n -ge 200 ]; do sleep 0.1; n=$((n + 1)); done
	echo "silence-line $(klog 'HM2 peer silent')"
	echo "silence-wait-ms $(( ($(date +%s%N) - t0) / 1000000 ))"
	echo "silence-silent-ms $(kl | sed -n 's/.*HM2 peer silent for \([0-9]*\) ms.*/\1/p' | head -1)"
	echo "silence-detached $(klog1 'remote element CL at clindex 1 detached')"
	t0=$(date +%s%N)
	echo "silence-files $(cd $C && find . -type f 2>/tmp/h2wire.silerr | grep -c .)"
	echo "silence-find-ms $(( ($(date +%s%N) - t0) / 1000000 ))"
	echo "silence-find-notconn $(grep -c 'not connected' /tmp/h2wire.silerr)"
	echo "silence-find-err $(sed -n '1s/.*: //p' /tmp/h2wire.silerr)"
	# a request that waited out the bound ends ETIMEDOUT in the element's
	# own line; the caller reads not connected either way, so the time
	# and this count tell the two apart
	echo "silence-timedout-ends $(klog 'H2 REMOTE .* end=00040000')"
	echo "silence-peer-sent $(klog 'HM2 peer sent')"
fi
GUEST
cat > "$W/restart.sh" <<'GUEST'
# restart <master|slave> <clid> <host> <port>: the guest a power cut stopped,
# booted again: the module loaded on what the cut left with no pfs-create,
# ROOT mounted read-write (and on the master CL, for the second set), the
# row read back and added only if the cut lost it.  restart dial [slave]:
# the dial, and on the slave its registration.
mkdir -p $R $C /tmp/h2keys
touch /tmp/h2keys/peer.none
if [ "$1" = dial ]; then
	/tmp/h2service dial $R --keys /tmp/h2keys > /tmp/h2wire.dial3 2>&1; r=$?
	sed 's/^/restartdial /' /tmp/h2wire.dial3
	echo "restart-dial-rc $r"
	if [ "${2:-}" = slave ]; then
		n=0; until [ "$(klog 'remote element CL registered at clindex 1')" -ge 1 ] || [ $n -ge 100 ]; do sleep 0.1; n=$((n + 1)); done
		echo "restart-registered $(klog 'remote element CL registered at clindex 1')"
	fi
	exit 0
fi
dmesg -C
pkill -f 'dmesg -w' 2>/dev/null
setsid -f sh -c 'exec dmesg -w > /tmp/h2wire.klog 2>&1'
# the resumed pass is read from this line on, as after the relay's cut
echo "h2wire cut gap end" > /dev/kmsg
{ echo scan > /sys/kernel/debug/kmemleak && echo scan > /sys/kernel/debug/kmemleak && echo clear > /sys/kernel/debug/kmemleak; } 2>/dev/null; echo "kmemleak-cleared"	# the boot's own objects are not the module's
insmod /tmp/hammer2.ko sync_snapshot=1 || { echo "insmod failed"; exit 1; }
echo $((256 + 32768)) > /sys/module/hammer2/parameters/debug 2>/dev/null
echo "restart-debug $(cat /sys/module/hammer2/parameters/debug 2>/dev/null)"
mount -t hammer2 /dev/vdb@ROOT $R || { echo "restart mount failed"; exit 1; }
hammer2 -s $R pfs-list 2>/dev/null | sed 's/^/restartpfs /'
if [ "$1" = master ]; then
	mount -t hammer2 /dev/vdb@CL $C || { echo "restart mount CL failed"; exit 1; }
fi
/tmp/h2service scan $R > /tmp/h2wire.scan 2>&1; echo "restart-scan-rc $?"
sed 's/^/restartscan /' /tmp/h2wire.scan
rows=$(sed -n 's/^h2service: \([0-9]*\) row.*/\1/p' /tmp/h2wire.scan)
echo "restart-rows ${rows:-none}"
[ "${rows:-0}" -ge 1 ] || /tmp/h2service add $R --clid "$2" --label peer --path "span:$3:$4" | sed 's/^/restartadd /'
GUEST
cat > "$W/link.sh" <<'GUEST'
# link <peer clid> <peer type>: what the log and the table say of the peer
echo "log-proto2 $(klog 'peer speaks DMSG_SPAN_PROTO_2')"
echo "log-conn-terminated $(klog 'CONN WAS TERMINATED')"
echo "spans-rx $(klog 'H2 +RXSPAN')"
echo "span-cl $(kl | grep 'H2 +RXSPAN' | grep -c "cl=$1 .*type=$2")"
echo "spantab $(kl | grep '^\[.*H2 SPANTAB' | tail -1 | sed 's/.*SPANTAB //')"
echo "threads $(threads)"
echo "keepalive-line $(klog 'HM2 peer silent')"
echo "conn-held $(klog 'reconnect held a second')"
GUEST
cat > "$W/down.sh" <<'GUEST'
# down: unmount, the leak scan, unload
if mountpoint -q $C; then umount $C || echo "umount CL failed"; fi
# With CL unmounted the element stays registered while ROOT holds the
# device, so a read-write mount of CL is the mount path's own refusal; a
# write on the read-only mount is the VFS's, and tests nothing of it.
# -w: without it mount(8) retries read-only on EROFS and returns 0.
mount -w -t hammer2 /dev/vdb@CL $C 2>/dev/null; echo "rw-mount-rc $?"
echo "log-mount-refused $(klog1 'read-write mount refused: a remote element')"
if mountpoint -q $C; then umount $C; fi
umount $R || echo "umount failed"
# The link on vdc outlives B's own device, whose unmount detaches the
# element before the PFS is freed; the link ends at vdc's unmount.
if mountpoint -q /mnt/h2k; then
	echo "vdb-gone-detached $(klog1 'remote element CL at clindex 1 detached')"
	echo "vdb-gone-threads $(threads)"
	umount /mnt/h2k || echo "umount vdc failed"
fi
echo "log-detached $(klog 'remote element CL at clindex 1 detached')"
echo "detached-why $(kl | grep 'remote element CL at clindex 1 detached' | sed 's/.*detached: //' | tr '\n' ' ')"
echo "spans-del $(klog 'H2 -RXSPAN')"
echo "spans-rx-end $(klog 'H2 +RXSPAN')"
echo "spantab-end $(kl | grep '^\[.*H2 SPANTAB' | tail -1 | sed 's/.*SPANTAB //')"
# the server's side of a peer's snapshot: a snapshot it could not take, and
# one a lost link left for it to delete, both printed unconditionally
echo "snap-peer-errors $(klog 'syncsnap: snapshot .* for a peer error')"
echo "snap-link-left $(klog 'snapshot .* left by the link deleted')"
# a SNAPDEL for a name the link never took, refused or (in the control)
# carried out
echo "snapdel-not-ours $(klog 'syncsnap: peer named ZZ.h2sync-src, not this link')"
echo "snapdel-decoy-deleted $(klog 'syncsnap: peer deleted ZZ.h2sync-src')"
# blocks read through a page-cache folio larger than the block, which
# read-ahead on the device mapping makes; a block then sits at its offset
# in the folio, not at the folio's start
echo "io-large-folios $(cat /sys/module/hammer2/parameters/io_large_folios 2>/dev/null)"
# A proxy is classed apart from the media's chains, at its level on the
# peer; on level 0, the super-root's class, a contended inode lock in the
# sync pass read as a cycle through the mount's order. The classes are
# listed until the unload, and a kernel without lockdep has no file.
if [ -r /proc/lockdep ]; then
	echo "lockdep-remote $(grep -o 'h2ch_remote_[a-z]*/[0-9]*' /proc/lockdep | sort -u | tr '\n' ' ')"
else
	echo "lockdep-remote no-lockdep"
fi
# a report dates its object by jiffies and the log by the printk clock;
# the two read together here map one onto the other
echo "clock $(grep -m1 '^jiffies:' /proc/timer_list 2>/dev/null) $(grep -m1 '^now at' /proc/timer_list 2>/dev/null)"
sleep 6
if echo scan > /sys/kernel/debug/kmemleak 2>/dev/null && echo scan > /sys/kernel/debug/kmemleak; then
	echo "kmemleak $(grep -c hammer2 /sys/kernel/debug/kmemleak)"
	# kept while the module is loaded, so its frames have names
	grep -q hammer2 /sys/kernel/debug/kmemleak && sed 's/^/kmemleak-report /' /sys/kernel/debug/kmemleak | head -400
else
	echo "kmemleak unusable"
fi
# hammer2's range as /proc/modules gives it before rmmod, its core text's
# base and its total size, so the scan after the unload counts its frames
# and not another module's; init text, freed after the load, is outside
# it. The size is added to the base's low half alone, since a base above
# INT64_MAX is past some shells' arithmetic, and a base printed as zero
# (kptr_restrict) or a size that carries leaves the range unread.
mrange=$(awk '$1 == "hammer2" { printf "%s %d\n", $6, $2 }' /proc/modules)
mb=${mrange% *}; ms=${mrange#* }; me=
case $mb in
0x00000000*|*[!0-9a-fx]*) ;;
0x????????????????)
	ml=$((0x${mb#0x????????} + ms))
	[ "$ms" -gt 0 ] && [ "$ml" -le 4294967295 ] && me=$(printf '%s%08x' "${mb%????????}" "$ml") ;;
esac
echo "kmemleak-unloaded-range ${mb:-none} ${me:-none}"
timeout 120 rmmod hammer2 && echo "rmmod ok"
# Scanned again after the unload, whose frames now print as addresses: an
# object a module global held and the unload never freed is a leak only
# from here. Each reading scans twice, since a scan greys an object whose
# checksum changed since the last one (mm/kmemleak.c, kmemleak_scan) and a
# new object's starts at ~0, so a leak is reported at its second scan.
# The scans wait out kmemleak's minimum age, 5 s, so an object the unload
# itself left is old enough to be reported.
sleep 6
if [ -z "$me" ]; then
	echo "kmemleak-unloaded unread"
elif echo scan > /sys/kernel/debug/kmemleak 2>/dev/null && echo scan > /sys/kernel/debug/kmemleak; then
	h2n=$(awk -v b="$mb" -v e="$me" '{ a = $1 "" } a ~ /^0x/ && a >= b && a < e' /sys/kernel/debug/kmemleak | wc -l)
	echo "kmemleak-unloaded $h2n"
	[ "$h2n" = 0 ] || sed 's/^/kmemleak-unloaded-report /' /sys/kernel/debug/kmemleak | head -200
fi
# Counted after the unload, whose own work (the connection device's free,
# the module's queues drained) can report too, from a stream shown alive by
# a line written after it.
sleep 2
echo "h2wire end of unload" > /dev/kmsg
n=0; until grep -q 'h2wire end of unload' /tmp/h2wire.klog || [ $n -ge 50 ]; do sleep 0.1; n=$((n+1)); done
echo "klog-alive $(grep -c 'h2wire end of unload' /tmp/h2wire.klog)"
# the connection device's balance of the blocks its frames carried, printed
# at its free: copied must equal framed plus replaced plus dropped plus
# diofreed plus devfreed, or a block was lost between two hands
echo "cdev-blocks $(kl | grep 'H2 CDEV freed: blocks' | tail -1 | sed 's/.*blocks //')"
# A lockdep table that fills turns lockdep off and says BUG; that is the
# guest kernel's table size (the KASAN build keeps the default, 2^15), not
# a report on the subject, so it is counted apart and named in the check,
# which it still fails: lockdep checks nothing for the rest of that run.
# The read-only gate's control enables emergency mode itself, and the
# carried ioctl says so in a line holding the word WARNING; that line is
# the harness's own act, not a report, so it is dropped by its full text.
echo "kernel-warnings $(kl | grep -v -e 'MAX_LOCKDEP_ENTRIES too low' -e 'hammer2_ioctl_emerg_mode: WARNING: Emergency mode enabled' | grep -c -E 'WARNING|BUG:|UBSAN:|KASAN|circular locking|possible recursive|enqueued on deprecated workqueue')"
echo "lockdep-saturated $(klog 'MAX_LOCKDEP_ENTRIES too low')"
# the connection device's own refusals, warnings by design
echo "conn-warnings $(kl | grep 'WARNING' | grep -c -E 'hammer2_io_getblk_conn|hammer2_io\.c:')"
echo "threads-final $(threads)"
pkill -f 'dmesg -w' 2>/dev/null
GUEST
to_scripts() {	# to_scripts <ssh>
	scp -q "$W/common.sh" "$W/clmode.awk" "$W/setup.sh" "$W/fill.sh" "$W/lone.sh" "$W/reg.sh" "$W/ro.sh" "$W/pass.sh" "$W/read.sh" "$W/dial.sh" "$W/link.sh" "$W/down.sh" "$W/stale.sh" "$W/redial.sh" "$W/cut.sh" "$W/restart.sh" "$1:/tmp/" || {
		echo "wire: COULD-NOT-RUN: copy to $1 failed" >&2; exit 2; }
}
to_scripts "$SA"
to_scripts "$SB"
phase() {	# phase <A|B> <script> [args]: run it on that guest, keep its output
	side=$1; script=$2; shift 2
	case $side in A) s=$SA;; B) s=$SB;; esac
	$RUN "$s" ". /tmp/common.sh; . /tmp/$script" "$@" > "$W/$side-$script.out" 2>&1
	rc=$?
	sed "s/^/$side /" "$W/$side-$script.out" >> "$W/out"
	if [ "$rc" = 2 ] || command grep -q "COULD-NOT-RUN" "$W/$side-$script.out"; then
		command grep -m1 "COULD-NOT-RUN" "$W/$side-$script.out" >&2 || echo "wire: COULD-NOT-RUN: $side $script exited 2 without a reason" >&2
		guest_off "$GA" "$SA"; guest_off "$GB" "$SB"; exit 2
	fi
	[ "$rc" = 0 ] || { echo "wire: $side $script ended rc=$rc:" >&2; sed 's/^/  guest: /' "$W/$side-$script.out" >&2; }
	return $rc
}
val() {	# val <A|B> <name>
	sed -n "s/^$1 $2 //p" "$W/out" | head -1
}
nval() {	# nval <A|B> <name>: how many lines carry it, with or without a value
	grep -c -E "^$1 $2( |$)" "$W/out"
}
: > "$W/out"
phase A setup.sh master 0 1 $([ "$SNAPDEL" = 0 ] || echo ZZ.h2sync-src) || { guest_off "$GA" "$SA"; guest_off "$GB" "$SB"; exit 2; }
clid=$(val A clid)
[ -n "$clid" ] || { echo "wire: COULD-NOT-RUN: A's CL has no cluster id" >&2; guest_off "$GA" "$SA"; guest_off "$GB" "$SB"; exit 2; }
phase B setup.sh slave "$clid" $([ "$PASSREFUSE" = control ] && echo 0 || echo 1) || { guest_off "$GA" "$SA"; guest_off "$GB" "$SB"; exit 2; }
phase A fill.sh $([ "$POWER" = 1 ] && echo bulk)
phase B lone.sh
phase A dial.sh "$clid" "$HOST_ADDR" "$PORT" rw
phase B dial.sh "$clid" "$HOST_ADDR" "$PORT" $([ "$PASS" = 1 ] && [ -z "$CUT" ] && echo rw || echo ro) $([ "$ADMIT" = 0 ] || echo noadmit) $([ "$LINKDEV" = 1 ] && echo linkdev)
sleep 3
phase A link.sh "$clid" 3	# A sees B's SLAVE CL
phase B link.sh "$clid" 6	# B sees A's MASTER CL
phase B reg.sh
if [ "$SNAPROUTE" = control ] || [ "$PASSREFUSE" = control ]; then PASSES=first
elif [ "$PASS" = 1 ]; then PASSES=full; else PASSES=none; fi
[ -n "$CUT" ] && PASSES=cut
[ "$POWER" = 1 ] && PASSES=power
# The power cut: the cut guest's log kept up to the cut, its power cut with
# no sync, and its image read here while it is down; then, once the
# survivor has ended its side, a new relay on the port and the guest booted
# again on what the cut left.
if [ "$CUT" = slave ]; then cg=$GB cs=$SB cl=b; else cg=$GA cs=$SA cl=a; fi
ci=$FIXDIR/wire-$cl.img
power_cut() {
	scp -q "$cs:/tmp/h2wire.klog" "$FIXDIR/wire-run-$stamp-$cl-precut.klog" 2>/dev/null
	$VIRSH destroy "$cg" >/dev/null 2>&1 || { echo "wire: COULD-NOT-RUN: $cg did not stop" >&2; guest_off "$GA" "$SA"; guest_off "$GB" "$SB"; exit 2; }
	"$FSCK" "$ci" > "$FIXDIR/wire-run-$stamp-fsck-cut.txt" 2>&1; echo "H cut-fsck-rc $?" >> "$W/out"
	"$HAMMER2" -v show "$ci" > "$W/show.cut" 2>/dev/null
	{ echo "H cut-image-tgt $(grep -c 'filename "CL.h2sync-tgt"' "$W/show.cut")"
	  echo "H cut-image-src $(grep -c 'filename "CL.h2sync-src"' "$W/show.cut")"
	  echo "H cut-image-bulk $(grep -c 'filename "b[0-9]' "$W/show.cut")"
	  echo "H cut-precut-updates $(grep -c 'syncthr: update inode' "$FIXDIR/wire-run-$stamp-$cl-precut.klog" 2>/dev/null)"
	  echo "H cut-precut-verdicts $(grep -c -E 'syncsnap: (verified|newer|unverified|interrupted) clindex' "$FIXDIR/wire-run-$stamp-$cl-precut.klog" 2>/dev/null)"
	  echo "H cut-precut-hm2 $(grep -c 'hammer2: HM2 ' "$FIXDIR/wire-run-$stamp-$cl-precut.klog" 2>/dev/null)"
	  echo "H cut-precut-warnings $(grep -v 'MAX_LOCKDEP_ENTRIES too low' "$FIXDIR/wire-run-$stamp-$cl-precut.klog" 2>/dev/null | grep -c -E 'WARNING|BUG:|UBSAN:|KASAN|circular locking|possible recursive|enqueued on deprecated workqueue')"; } >> "$W/out"
}
power_on() {
	kill "$RELAY_PID" 2>/dev/null; wait "$RELAY_PID" 2>/dev/null; RELAY_PID=
	relay_start "$FIXDIR/wire-run-$stamp-2.trace"
	$VIRSH domblklist "$cg" --inactive 2>/dev/null | grep -qw vdb || $VIRSH attach-disk "$cg" "$ci" vdb --targetbus virtio --config >/dev/null 2>&1 &&
	    $VIRSH start "$cg" >/dev/null 2>&1 || { echo "wire: COULD-NOT-RUN: $cg did not start again on $ci" >&2; guest_off "$GA" "$SA"; guest_off "$GB" "$SB"; exit 2; }
	wait_ssh "$cg" "$cs"; to_guest "$cg" "$cs"; to_scripts "$cs"
}
# A protocol cell's fault: the relay's line for it, a mark in B's log at
# once, then 10 s, or 60 s for late's next scanall call, for B's own end
# of the link, which only a check on B makes; failing it the relay hangs
# the pair up, as nothing else would end a link left up, except under the
# control, whose link is read up.
fault_wait() {
	tr=$FIXDIR/wire-run-$stamp.trace
	n=0; until grep -q " $FAULT t=" "$tr" || [ $n -ge 2400 ]; do sleep 0.1; n=$((n + 1)); done
	echo "H fault-wait-ms $((n * 100))" >> "$W/out"
	t0=$(date +%s%N)
	grep -q " $FAULT t=" "$tr" && phase B cut.sh mark
	lim=10000; [ "$CUT" = late ] && lim=60000
	beof() { awk -v f=" $FAULT t=" 'index($0, f) { s = 1 } s && /^B eof / { n++ } END { print n + 0 }' "$tr"; }
	until [ "$(beof)" -ge 1 ] || [ $(( ($(date +%s%N) - t0) / 1000000 )) -ge $lim ]; do sleep 0.1; done
	if [ "$(beof)" -ge 1 ]; then first=eof; else first=timeout; [ "$SEQ" = control ] || kill -USR1 "$RELAY_PID"; fi
	echo "H fault-first $first" >> "$W/out"
	echo "H fault-first-ms $(( ($(date +%s%N) - t0) / 1000000 ))" >> "$W/out"
}
# The cut: B dialed with its device read-only, so no pass runs before the
# readings above and CL's mount, which a cut would otherwise race (a pass
# starts at the thread's next 5 s tick after the registration and the cut
# falls 1 to 2 s into it); B's ROOT remounted read-write starts the pass.
# Then where the cut fell, and A's snapshot before any dial; the cell dials
# A and then B, and the resumed pass is read as a plain one is.
phase B ro.sh && case $PASSES in
	cut)	phase B cut.sh go && { [ "$PROTO" = 0 ] || fault_wait; } &&
		if [ "$SEQ" = control ]; then phase B cut.sh up && phase B cut.sh hm2; else
		phase B cut.sh wait && { [ "$PROTO" = 0 ] || phase B cut.sh hm2; } && phase A cut.sh peer &&
		{ [ "$CUT" = control ] || { phase A redial.sh && phase A cut.sh peer after && phase B cut.sh redial &&
		    phase B pass.sh 1 && phase B cut.sh resumed && phase A fill.sh more && phase B pass.sh more "$(val B pass-snap-deleted)"; }; }; fi;;
	full)	phase B pass.sh $((RETYPE + 1)) && phase A fill.sh more && phase B pass.sh more "$(val B pass-snap-deleted)" &&
		{ [ "$STALE" = 0 ] || { phase B stale.sh down && phase A redial.sh && phase B stale.sh up && phase A fill.sh stale; }; };;
	first)	phase B pass.sh first;;
	power)	phase B cut.sh go && phase B cut.sh arm "$(val B cut-update-base)" "$DEPTH" && power_cut &&
		if [ "$CUT" = master ]; then
			phase B cut.sh silent && phase B cut.sh wait && power_on &&
			    phase A restart.sh master "$clid" "$HOST_ADDR" "$PORT" && phase A restart.sh dial && phase B cut.sh redial
		else
			phase A cut.sh silent && phase A cut.sh peer && power_on &&
			    phase B restart.sh slave "$clid" "$HOST_ADDR" "$PORT" && phase A redial.sh && phase A cut.sh peer after &&
			    phase B restart.sh dial slave && phase B ro.sh
		fi && phase B pass.sh 1 && phase B cut.sh resumed &&
		{ [ "$CUT" = slave ] || phase A cut.sh peer after; } &&
		phase A fill.sh more && phase B pass.sh more "$(val B pass-snap-deleted)";;
	*)	true;;
esac && [ "$CUT" != control ] && [ "$SEQ" != control ] && phase B read.sh "$STALL" "${END:-0}" "$SILENCE" "$([ "$ROGATE" = 0 ] && echo 0 || echo rogate)"
phase B down.sh
sleep 2
phase A link.sh "$clid" 3	# after B's unmount: its spans deleted
phase A down.sh
kill "$RELAY_PID" 2>/dev/null; wait "$RELAY_PID" 2>/dev/null; RELAY_PID=
scp -q "$SA:/tmp/h2wire.klog" "$FIXDIR/wire-run-$stamp-a.klog" 2>/dev/null
scp -q "$SB:/tmp/h2wire.klog" "$FIXDIR/wire-run-$stamp-b.klog" 2>/dev/null
{ echo "source $SRC_REV"; echo "relay-sha256 $RELAY_SUM"; echo "harness-sha256 $WIRE_SUM"; echo "module-sha256 $KO_SUM"; echo "module-a-sha256 $KO_A_SUM"; echo "h2service-b-sha256 $SVC_B_SUM"; echo "guest-kernel $ko_rel"; echo "module-vermagic $(modinfo -F vermagic "$KO_B" 2>/dev/null)"; cat "$W/out"; cat "$W/relay.out"; } > "$FIXDIR/wire-run-$stamp.out" 2>/dev/null
echo "  kept  both kernel logs and the relay trace beside the images as wire-run-$stamp-{a,b}.klog and .trace"
guest_off "$GA" "$SA"
guest_off "$GB" "$SB"

fail=0; checks=0
check() {	# check <name> <0 ok / 1 fail> <reading>
	checks=$((checks + 1))
	if [ "$2" = 0 ]; then echo "  ok    $1: $3"; else echo "  FAIL  $1: $3"; fail=$((fail + 1)); fi
}
num() { case "$1" in ''|*[!0-9-]*) echo "$2";; *) echo "$1";; esac; }
# inpass <trace>: a protocol cell's fault fell inside the pass: no verdict
# before B's first HM2 line, which its check prints at the frame's receipt,
# or with no such line the relay's next call opening within 1 s of the
# fault, against the thread's 5 s idle between passes; sets hv and fgap
inpass() {
	hv=$(val B cut-hm2-verdicts)
	ft=$(sed -n "s/.* $FAULT t=\([0-9]*\) call=.*/\1/p" "$1" 2>/dev/null | head -1)
	fgap=$(awk -v f=" $FAULT t=" -v ft="$ft" 'index($0, f) { s = 1; next } s && / open t=/ { sub(/.* t=/, ""); print $1 - ft; exit }' "$1" 2>/dev/null)
	if [ "$hv" = none ]; then [ "$(num "$fgap" 9999)" -lt 1000 ]; else [ "$(num "$hv" 1)" = 0 ]; fi
}
# A's link.sh ran twice; the first reading is the paired one, the second
# the one after B's unmount, so the second's values are read from the tail.
val2() { sed -n "s/^$1 $2 //p" "$W/out" | tail -1; }

echo "hammer2 cluster transport on the wire, $GA and $GB ($ko_rel), relay seed $SEED, source $SRC_REV, module sha256 $(printf %.16s "$KO_SUM")$([ "$KO_A_SUM" = "$KO_SUM" ] || printf ', A'"'"'s %.16s' "$KO_A_SUM"):"
npa=$(num "$(val A pfs-count)" 0); npb=$(num "$(val B pfs-count)" 0)
# under LINKDEV B's link is vdc's, which spans vdc's PFSes and not B's CL
slv=1
nlb=$npb
[ "$LINKDEV" = 1 ] && { nlb=$(num "$(val B link-pfs-count)" 0); slv=0; }
[ "$npa" -ge 3 ] && [ "$npb" -ge 3 ]; check "each volume has ROOT, LOCAL and CL" $? "A $npa, B $npb"
[ "$(num "$(val A dial-rc)" 1)" = 0 ] && [ "$(num "$(val B dial-rc)" 1)" = 0 ]; check "link: both dials hand a connected TCP socket in" $? "A rc $(val A dial-rc), B rc $(val B dial-rc)"
# The callback's install off: B's reader answers A's LNK_CONN, read in the
# hold, with no callback, so B never reads PROTO_2 and closes every span of
# A's while A, whose CONN from B came after B's install, reads B's whole.
# The fake pass, a module with no hold, has no hold line on B.
if [ "$CONNWAIT" = control ]; then
	[ "$(num "$(val B conn-held)" 0)" = 1 ] && [ "$(num "$(val B log-proto2)" 1)" = 0 ] && [ "$(num "$(val B spans-rx)" 1)" = 0 ] && [ "$(num "$(val B log-registered)" 1)" = 0 ] && [ "$(nval B ro-mounted)" = 0 ] && [ "$(num "$(val A log-proto2)" 0)" = 1 ] && [ "$(num "$(val A spantab)" 0)" = "$nlb" ]; check "control: with the callback installed where upstream installs it B reads A's LNK_CONN in the hold, never reads PROTO_2 and closes A's spans" $? "B held $(val B conn-held), read PROTO_2 $(val B log-proto2), spans admitted $(val B spans-rx), table $(val B spantab), registered $(val B log-registered), CL mounted $(nval B ro-mounted); A read PROTO_2 $(val A log-proto2) and holds $(val A spantab) of $nlb spans; terminated A $(val A log-conn-terminated), B $(val B log-conn-terminated)"
else
[ "$CONNWAIT" = 1 ] && { [ "$(num "$(val B conn-held)" 0)" = 1 ]; check "control: B's reconnect held a second after its reader's start" $? "hold lines $(val B conn-held)"; }
[ "$(num "$(val A log-proto2)" 0)" = 1 ] && [ "$(num "$(val B log-proto2)" 0)" = 1 ]; check "link: each kernel reads the peer's PROTO_2 announcement once" $? "A $(val A log-proto2), B $(val B log-proto2)"
[ "$(num "$(val A spantab)" 0)" = "$nlb" ]; check "link: A's span table holds one span per PFS of B's link device, counted against its pfs-list" $? "$(val A spantab) spans, $nlb PFSs"
[ "$(num "$(val B spantab)" 0)" = "$npa" ]; check "link: B's span table holds one span per PFS of A" $? "$(val B spantab) spans, $npa PFSs"
[ "$(num "$(val A span-cl)" 9)" = "$slv" ] && [ "$(num "$(val B span-cl)" 0)" = 1 ]; check "link: each sees the other's CL span by the shared cluster id and the peer's type" $? "A sees SLAVE $(val A span-cl) of $slv, B sees MASTER $(val B span-cl)"
[ "$(num "$(val A log-conn-terminated)" 1)" = 0 ] && [ "$(num "$(val B log-conn-terminated)" 1)" = 0 ]; check "link: the connection outlives the VOLCONF frames" $? "terminated A $(val A log-conn-terminated), B $(val B log-conn-terminated)"
[ "$(num "$(val A threads)" 0)" = 2 ] && [ "$(num "$(val B threads)" 0)" = 2 ]; check "link: one pair of message threads on each guest" $? "A $(val A threads), B $(val B threads)"
# under STALE B's device is unmounted twice, each time with A's spans held,
# and under the cut's disconnect B holds them over two links
nlk=$((STALE + 1)); case $CUT in disconnect|master|loss|dup|reorder|trail|late) nlk=2;; esac
[ "$SEQ" = control ] && nlk=1
# A restarted on the cut media advertises the pass's source snapshot when
# the cut left it there; the stale delete that follows sends no span
# DELETE, as upstream's spans go out once at the LNK_CONN, so B holds it
# to the unmount
nsx=0; [ "$CUT" = master ] && nsx=$(num "$(val H cut-image-src)" 0)
[ "$(num "$(val2 A spantab)" 9)" = 0 ] && [ "$(num "$(val B spans-del)" 0)" = $((npa * nlk + nsx)) ]; check "unmount: B's unmount deletes its spans and A's table empties" $? "A's table $(val2 A spantab) after, B deleted $(val B spans-del) of A's $npa times $nlk and $nsx left on the cut media"
# The read side: B's empty SLAVE answers nothing, so every file B reads
# came through the remote element; the digests are A's own, taken on A.
sums() { sed -n "s/^$1 $2 //p" "$W/out" | sort; }
nfa=$(( $(num "$(val A files)" 0) + $(num "$(val A more-files)" 0) ))	# the pass mode's second set, read after it
[ "$(num "$(val B lone-mount-rc)" 0)" != 0 ]; check "remote: B's SLAVE CL alone does not mount, having no master" $? "rc $(val B lone-mount-rc)"
[ "$(num "$(val B log-registered)" 0)" = 1 ] && [ "$(num "$(val B log-nmasters)" 0)" = 1 ]; check "remote: B registers A's CL root as clindex 1, one master" $? "registered $(val B log-registered), pfs_nmasters $(val B log-nmasters)"
# Lost ends the link at the first rewritten close, and the window control
# at the first listing past sixteen feeds, so every read after it finds
# nothing: the live-link checks below do not apply to those modes, nor to
# the cut's control or the sequence control, which never dial again and
# read nothing after.
LINKLOST=0; { [ "$END" = lost ] || [ "$WINDOW" = 1 ] || [ "$CUT" = control ] || [ "$SEQ" = control ]; } && LINKLOST=1
[ "$LINKLOST" = 1 ] || [ "$STALL" != 0 ] || { [ "$nfa" -ge 5 ] && [ "$(num "$(val B files)" 0)" = "$nfa" ]; check "remote: B lists A's files through the element" $? "A $nfa, B $(val B files)"; }
[ "$LINKLOST" = 1 ] || { [ "$(num "$(val A many)" 0)" = 300 ] && [ "$(num "$(val B many)" 0)" = 300 ]; check "remote: B lists a directory larger than one readdir XOP takes" $? "A $(val A many), B $(val B many) of 300"; }
# The pass wrote B under the pass and under the pass-refusal control,
# whose live pass writes B's read-only device.
WRITTEN=0; { { [ "$PASS" = 1 ] && [ "$SNAPROUTE" = 0 ]; } || [ "$PASSREFUSE" = control ]; } && WRITTEN=1
# Both images read here with the guests down: the slave's CL against
# the master's entry for entry and block for block, as cluster-sync.sh
# reads its two volumes, and both clean by fsck. Inode check codes are
# left out, as there: a slave does not share its master's stamps.
fingerprint() {	# image
	"$HAMMER2" -v show "$1" 2>/dev/null | awk '
	/filename "CL"$/ && !on && !past { on = 1; next }
	on && /^ *} \(inode\.[0-9]*, "CL"\)/ { on = 0; past = 1; next }
	!on { next }
	/^ *inode\.[0-9]/ { mode = "inode"; next }
	/^ *dirent\.[0-9]/ { mode = "dirent"; name = ""; next }
	/^ *data\.[0-9]/ { mode = "data"; key = $3; next }
	/^ *(indirect|empty)\.[0-9]/ { mode = ""; next }
	mode == "dirent" && $1 == "filename" { name = $2 }
	mode == "dirent" && $1 == "inum" { dinum = $2 }
	mode == "dirent" && $1 == "type" { print "dirent", name, dinum, $2 }
	mode == "inode" && $1 == "inum" { inum = $2 }
	mode == "inode" && $1 == "type" { itype = $2 }
	mode == "inode" && $1 == "size" { print "inode", inum, itype, $2 }
	mode == "data" && /xxh=/ { sub(/.*xxh=/, ""); print "data", inum, key, $1 }
	' | LC_ALL=C sort
}
if [ "$WRITTEN" = 1 ]; then
	fingerprint "$FIXDIR/wire-a.img" > "$W/fp.a"; fingerprint "$FIXDIR/wire-b.img" > "$W/fp.b"
	nfpa=$(grep -c ' FILE$' "$W/fp.a"); nfpb=$(grep -c ' FILE$' "$W/fp.b"); ndata=$(grep -c '^data ' "$W/fp.a")
	"$FSCK" "$FIXDIR/wire-a.img" > "$W/fsck.a" 2>&1; fa=$?; "$FSCK" "$FIXDIR/wire-b.img" > "$W/fsck.b" 2>&1; fb=$?
	cp "$W/fp.a" "$FIXDIR/wire-run-$stamp-fp-a.txt"; cp "$W/fp.b" "$FIXDIR/wire-run-$stamp-fp-b.txt"
fi
if [ "$PASS" = 1 ] && [ "$SNAPROUTE" = 0 ] && [ -z "$CUT" ]; then
	[ "$(num "$(val B sync-snapshot)" 0)" = 1 ] && [ "$(num "$(val B root-ro)" 0)" = 0 ] && [ "$(num "$(val B pass-refused-lines)" 1)" = 0 ] && [ "$(num "$(val B pass-media-files)" 0)" -ge 300 ] && [ "$(num "$(val B pass-errors)" 1)" = "$UNV" ] && [ "$(num "$(val B pass-sync-errors)" 1)" = "$UNV" ]; check "pass: B's pass runs on its writable device and writes A's files to B's media" $? "$(val B pass-media-files) of A's files on B's media after $(val B pass-wait-seconds) s, sync_snapshot $(val B sync-snapshot), refusals $(val B pass-refused-lines), errors $(val B pass-errors) and $(val B pass-sync-errors), $(val B pass-remote-xops) remote XOPs of which $(val B pass-remote-ends) ended other than clean"
	if [ "$STALE" = 1 ]; then
		# the one block A rewrote after the slave's last pass, and nothing else
		fpd=$(diff "$W/fp.a" "$W/fp.b" | sed -n 's/^[<>] //p')
		fpk=$(printf '%s\n' "$fpd" | awk '$1 == "data" { print $2, $3 }' | sort -u)
		[ "$nfa" -ge 300 ] && [ "$nfpa" = "$nfa" ] && [ "$nfpb" = "$nfa" ] && [ "$(printf '%s\n' "$fpd" | grep -c .)" = 2 ] && [ "$(printf '%s\n' "$fpd" | grep -c '^data ')" = 2 ] && [ "$(printf '%s\n' "$fpk" | grep -c .)" = 1 ]; check "stale: the slave's CL differs from the master's by one data block alone, the one A rewrote" $? "A $nfpa file entries and $ndata data blocks, B $nfpb; $(printf '%s\n' "$fpd" | grep -c .) lines differ, at inum and key $(printf '%s' "$fpk" | tr '\n' ';')"
	else
	[ "$nfa" -ge 300 ] && [ "$nfpa" = "$nfa" ] && [ "$ndata" -gt 0 ] && cmp -s "$W/fp.a" "$W/fp.b"; check "pass: the slave's CL matches the master's entry for entry and block for block on the media" $? "A $nfpa file entries and $ndata data blocks, B $nfpb; $(diff "$W/fp.a" "$W/fp.b" | grep -c '^[<>]') lines differ of $(wc -l < "$W/fp.a")"
	fi
	[ "$fa" = 0 ] && [ "$fb" = 0 ]; check "pass: both volumes are clean by fsck_hammer2" $? "A rc $fa, B rc $fb"
	# The snapshot pass over the wire: the master took the pass's source
	# snapshot at B's request and B read it, the pass verified against it,
	# and B had it deleted; the fake pass, a live pass, has no snapshot
	# line and no verdict, and a snapshot the master refused leaves its
	# error line on A.
	[ "$(num "$(val B pass-snap-taken)" 0)" -ge 1 ] && [ "$(num "$(val B pass-snap-bad)" 1)" = 0 ] && [ "$(num "$(val B pass-snap-passes)" 0)" -ge 1 ] && [ "$(num "$(val B pass-snap-verified)" 0)" -ge 1 ] && [ "$(num "$(val B pass-snap-unverified)" 1)" = "$UNV" ] && [ "$(num "$(val B pass-snap-noquorum)" 1)" = 0 ] && [ "$(num "$(val B pass-snap-deleted)" 0)" -ge 1 ] && [ "$(num "$(val B pass-snap-delete-errors)" 1)" = 0 ] && [ "$(num "$(val A snap-peer-errors)" 1)" = 0 ]; check "pass: B's pass reads a snapshot the master takes at its request, verifies against it and has it deleted" $? "snapshots taken $(val B pass-snap-taken), bad $(val B pass-snap-bad), passes $(val B pass-snap-passes), verified $(val B pass-snap-verified), unverified $(val B pass-snap-unverified), no quorum $(val B pass-snap-noquorum), deleted $(val B pass-snap-deleted), delete errors $(val B pass-snap-delete-errors), target taken $(val B pass-snap-target-taken), A's errors $(val A snap-peer-errors), end after $(val B pass-end-seconds) s"
	# Incremental convergence: a set written on the master after the first
	# pass reaches the slave's media by a later pass, which also verifies
	# and deletes its snapshot; the digests read after include the set.
	[ "$(num "$(val A more-media-files)" 0)" = 5 ] && [ "$(num "$(val B more-media-files)" 0)" = 5 ] && [ "$(num "$(val B more-snap-deleted)" 0)" -ge 1 ] && [ "$(num "$(val B more-snap-unverified)" 1)" = "$UNV" ] && [ "$(num "$(val B more-snap-verified)" 0)" -gt "$(num "$(val B pass-snap-verified)" 0)" ] && [ "$(num "$(val B more-snap-idle-taken)" 9)" -le 1 ] && [ "$(num "$(val B more-snap-idle-passes)" 0)" -ge 1 ]; check "pass: five files written on the master after the first pass reach the slave's media by a later pass, and a quiet master is then passed idle" $? "A $(val A more-media-files) on its media, B $(val B more-media-files) after $(val B more-wait-seconds) s, passes verified $(val B pass-snap-verified) then $(val B more-snap-verified), snapshots deleted $(val B more-snap-deleted) more, then $(val B more-snap-idle-taken) taken in 12 s with $(val B more-snap-idle-passes) idle passes"
	# Neither image holds a snapshot of the pass at the end: the source on
	# the master's, deleted at B's request, and the target on the slave's,
	# deleted when a pass verified; a lost link's leftovers would show as
	# A's own deletion line.
	sa=$("$HAMMER2" -v show "$FIXDIR/wire-a.img" 2>/dev/null | grep -c 'filename "CL.h2sync-src"'); sb=$("$HAMMER2" -v show "$FIXDIR/wire-b.img" 2>/dev/null | grep -c 'filename "CL.h2sync-tgt"')
	[ "$sa" = 0 ] && [ "$sb" = 0 ] && [ "$(num "$(val A snap-link-left)" 1)" = 0 ]; check "pass: neither image holds a snapshot of the pass at the end" $? "CL.h2sync-src on A $sa, CL.h2sync-tgt on B $sb, left by the link $(val A snap-link-left)"
elif [ "$POWER" = 1 ]; then
	# Where the power cut fell: past the first snapshot the pass read, with
	# no verdict before it, and B's inode updates above the count at the
	# go and short of it plus 5000, read on B's log kept to the cut or, A
	# cut, B's updates before its detach, since none follows A's end.
	ub=$(num "$(val B cut-update-base)" 0)
	if [ "$CUT" = slave ]; then uc=$(num "$(val H cut-precut-updates)" 0); vc=$(num "$(val H cut-precut-verdicts)" 1)
	# A cut, B's pass outlives A's power and may end on its own request's
	# deadline before the keepalive detaches (wire-run-20261026-151912:
	# unverified at 104.6 s, the detach at 108.7 s), so the verdict
	# before the cut is the one read at the arm, taken just before it, and
	# the master check below requires the one after to be unverified.
	else uc=$(num "$(val B cut-updates-before)" 0); vc=$(num "$(val B cut-arm-verdicts)" 1); fi
	[ "$(num "$(val B cut-arm-updates)" 0)" -ge "$DEPTH" ] && [ "$(num "$(val B cut-arm-verdicts)" 1)" = 0 ] && [ "$(num "$(val B cut-arm-snap)" 0)" -ge 1 ] && [ "$vc" = 0 ] && [ $((uc - ub)) -gt 0 ] && [ $((uc - ub)) -lt 5000 ] && [ "$(num "$(val B cut-snap-before-go)" 1)" = 0 ] && [ "$(num "$(val B cut-root-rw-rc)" 1)" = 0 ]; check "power: $CUT's power is cut inside the pass, its snapshot read and no verdict, with inodes still to copy" $? "armed at $(val B cut-arm-updates) updates of depth $DEPTH, $((uc - ub)) by the cut of 5310 files, verdicts at the arm $(val B cut-arm-verdicts) and by the cut $vc, snapshots read $(val B cut-arm-snap), printk $(val B cut-printk)"
	[ "$(num "$(val H cut-fsck-rc)" 1)" = 0 ] && [ "$(num "$(val H cut-precut-warnings)" 1)" = 0 ] && { [ "$CUT" = master ] || [ "$(num "$(val H cut-image-tgt)" 0)" = 1 ]; }; rc=$?
	# the status is taken before the name, whose substitution would set $?
	check "power: the cut image is clean by fsck_hammer2$([ "$CUT" = slave ] && echo " and holds the pass's target")" $rc "fsck rc $(val H cut-fsck-rc), CL.h2sync-tgt $(val H cut-image-tgt), CL.h2sync-src $(val H cut-image-src), bulk entries $(val H cut-image-bulk), warnings before the cut $(val H cut-precut-warnings), HM2 lines before it $(val H cut-precut-hm2)"
	if [ "$CUT" = slave ]; then
		# A's keepalive ends its side, with no element to detach; B boots
		# on its cut media, its thread keeps the target the cut left, and
		# A drops the link's snapshot at its redial.
		[ "$(num "$(val A cut-silent-line)" 0)" = 1 ] && [ "$(num "$(val A cut-silent-detached)" 1)" = 0 ] && [ "$(num "$(val A cut-peer-hm2)" 0)" = 1 ] && [ "$(num "$(val A cut-link-left)" 1)" = 0 ]; check "power: A's keepalive ends the link to the cut slave, A detaches nothing and keeps the link's snapshot" $? "silent lines $(val A cut-silent-line) after $(val A cut-silent-wait-ms) ms (silent $(val A cut-silent-ms) ms), detach lines $(val A cut-silent-detached), A's HM2 lines $(val A cut-peer-hm2), left-by-the-link deletions $(val A cut-link-left)"
		[ "$(num "$(val B restart-rows)" 0)" -ge 1 ] && [ "$(num "$(val B restart-registered)" 0)" = 1 ] && [ "$(num "$(val A cut-link-left-after)" 0)" = 1 ] && [ "$(num "$(val A redial-rc)" 1)" = 0 ] && [ "$(num "$(val B restart-dial-rc)" 1)" = 0 ]; check "power: B boots on the cut media with its row, both dial, and A drops the link's snapshot at its redial" $? "rows $(val B restart-rows), registered $(val B restart-registered), A's deletions $(val A cut-link-left-after), dials A rc $(val A redial-rc) B rc $(val B restart-dial-rc)"
		[ "$(num "$(val B cut-resumed-kept)" 0)" = 1 ] && [ "$(num "$(val B cut-resumed-target)" 1)" = 1 ]; check "power: B's recreated thread keeps the target the cut pass took, taking none" $? "kept $(val B cut-resumed-kept), target lines $(val B cut-resumed-target)"
	else
		# B's keepalive ends the link to the cut master and the span's
		# deletion detaches the slot; A boots, deletes the stale source at
		# B's first snapshot request, and has no link to drop.
		[ "$(num "$(val B cut-silent-line)" 0)" = 1 ] && [ "$(num "$(val B cut-detached)" 0)" = 1 ] && [ "$(val B cut-detached-why | sed 's/ *$//')" = "span deleted" ] && [ "$(num "$(val B cut-unverified)" 0)" = 1 ] && [ "$(num "$(val B cut-verified)" 1)" = 0 ] && [ "$(num "$(val B cut-other-verdicts)" 1)" = 0 ] && [ "$(num "$(val B cut-target-taken)" 0)" = 1 ] && [ "$(num "$(val B cut-noquorum)" 0)" -ge 1 ] && [ "$(num "$(val B cut-hm2)" 0)" = 1 ]; check "power: B's keepalive ends the link to the cut master, the span's deletion detaches it, and the pass ends unverified" $? "silent lines $(val B cut-silent-line) after $(val B cut-silent-wait-ms) ms (silent $(val B cut-silent-ms) ms), detached $(val B cut-detached) by $(val B cut-detached-why)after $(val B cut-detach-seconds) s, unverified $(val B cut-unverified) ($(val B cut-unverified-line)) verified $(val B cut-verified) other $(val B cut-other-verdicts), target taken $(val B cut-target-taken), no quorum $(val B cut-noquorum), HM2 lines $(val B cut-hm2), remote ends $(val B cut-remote-ends)"
		# the requests the cut pass sends after the link's end, one per
		# deferred directory, each refused at once and not at the writer's
		# next tick (wire-run-20261026-145438: 149 calls, each 500 ms or the
		# 10 s bound, before the redial's quiesce let the pass end)
		# A pass that stops at its first failed call sends none, so the
		# count is printed and only their speed is checked.
		[ "$(num "$(val B cut-after-slow)" 1)" = 0 ]; check "power: every request B's pass sends after the link's end is refused at once" $? "calls started after the link's end $(val B cut-after-calls), 400 ms or longer $(val B cut-after-slow), longest $(val B cut-after-max-ms) ms"
		x=$(num "$(val H cut-image-src)" -1)
		[ "$(num "$(val A restart-debug)" 0)" = 33024 ] && [ "$(num "$(val A restart-rows)" 0)" -ge 1 ] && [ "$(num "$(val A restart-dial-rc)" 1)" = 0 ] && [ "$(num "$(val B cut-registered)" 0)" = 2 ] && [ "$(num "$(val A cut-stale-deleted-after)" -1)" = "$x" ] && [ "$(num "$(val A cut-link-left-after)" 1)" = 0 ] && [ "$(num "$(val A cut-peer-hm2-after)" 1)" = 0 ]; check "power: A boots on the cut media and deletes the stale source once per copy the cut left, with no link to drop" $? "debug $(val A restart-debug), rows $(val A restart-rows), dial rc $(val A restart-dial-rc), B registered $(val B cut-registered), stale deletions $(val A cut-stale-deleted-after) of $x on the cut image, left-by-the-link $(val A cut-link-left-after), A's HM2 lines $(val A cut-peer-hm2-after)"
		[ "$(num "$(val B cut-resumed-target)" 1)" = 0 ]; check "power: B's thread keeps its own target over the link's end, taking none" $? "target lines after $(val B cut-resumed-target)"
	fi
	sa=$("$HAMMER2" -v show "$FIXDIR/wire-a.img" 2>/dev/null | grep -c 'filename "CL.h2sync-src"'); sb=$("$HAMMER2" -v show "$FIXDIR/wire-b.img" 2>/dev/null | grep -c 'filename "CL.h2sync-tgt"')
	nl=0; [ "$CUT" = slave ] && nl=1; nu=1; [ "$CUT" = slave ] && nu=0
	# The resumed pass keeps a key whose slave tid is above the source's
	# (hammer2_synchro.c, the two kept arms) and reads `newer`; on a
	# slave mounted read-only no frontend wrote it, so a kept key here
	# compares one host's tid with the other's, a candidate held for the
	# lease note (wire-run-20261026-154118: newer with 4 kept, then
	# verified). Corrected before the rerun: the resumed pass verifies,
	# or reads newer and the next verifies.
	case "$(val B cut-resumed-verdicts)" in "verified "*|"newer verified ") rv=0;; *) rv=1;; esac
	[ "$rv" = 0 ] && [ "$(num "$(val B cut-resumed-hm2)" 1)" = 0 ] && [ "$(num "$(val B pass-snap-deleted)" 0)" -ge 1 ]; check "power: the resumed pass verifies, or reads newer and the next pass verifies" $? "verdicts $(val B cut-resumed-verdicts)after a wait of $(val B cut-resumed-second-wait) s, keys kept by tid $(val B cut-resumed-kept-keys), HM2 lines after $(val B cut-resumed-hm2), deleted $(val B pass-snap-deleted), passes $(val B pass-snap-passes), no quorum $(val B pass-snap-noquorum), errors $(val B pass-errors) and $(val B pass-sync-errors), end after $(val B pass-end-seconds) s"
	[ "$(num "$(val A more-media-files)" 0)" = 5 ] && [ "$(num "$(val B more-media-files)" 0)" = 5 ] && [ "$(num "$(val B more-snap-deleted)" 0)" -ge 1 ] && [ "$(num "$(val B more-snap-unverified)" 9)" = "$nu" ]; check "power: five files written on the master after the resumed pass reach the slave by a later pass" $? "A $(val A more-media-files), B $(val B more-media-files) after $(val B more-wait-seconds) s, deleted $(val B more-snap-deleted) more, unverified $(val B more-snap-unverified) of $nu"
	[ "$fa" = 0 ] && [ "$fb" = 0 ] && [ "$nfa" = 5310 ] && [ "$nfpa" = "$nfa" ] && [ "$ndata" -gt 0 ] && cmp -s "$W/fp.a" "$W/fp.b" && [ "$sa" = 0 ] && [ "$sb" = 0 ] && [ "$(num "$(val A snap-link-left)" 9)" = "$nl" ]; check "power: both images clean, the slave's CL the master's entry for entry and block for block, and no snapshot of the pass left" $? "fsck A rc $fa B rc $fb; A $nfpa file entries of $nfa and $ndata data blocks, B $nfpb; $(diff "$W/fp.a" "$W/fp.b" | grep -c '^[<>]') lines differ; CL.h2sync-src on A $sa, CL.h2sync-tgt on B $sb, A's left-by-the-link deletions $(val A snap-link-left) of $nl"
elif [ "$SEQ" = control ]; then
	# The sequence checks compiled out: the fault, placed as the cut's, is
	# taken, and the link stays up to B's unmount: no line of B's ending it,
	# no hangup, one pair, the cut call closed clean and a later call opened.
	# What B said is predicted per cell, late's from the two keys the relay
	# traced; the pass's verdict is printed.
	tr=$FIXDIR/wire-run-$stamp.trace
	ctr=$(sed -n "s/.* $FAULT t=[0-9]* call=\([0-9]*\) feeds=\([0-9]*\).*/\1 \2/p" "$tr" 2>/dev/null)
	cc=$(num "${ctr% *}" -1); cf=$(num "${ctr#* }" 0)
	cafter=$(awk -v c="$cc" '/ open t=/ { sub(/.*call=/, ""); if ($1 + 0 > c) n++ } END { print n + 0 }' "$tr" 2>/dev/null)
	ce=$(sed -n "s/.* close t=[0-9]* call=$cc feeds=[0-9]* error=\([0-9a-f]*\).*/\1/p" "$tr" 2>/dev/null | head -1)
	nh=$(grep -c '^hangup ' "$tr" 2>/dev/null); nbc=$(grep -c '^B connected ' "$tr" 2>/dev/null)
	inpass "$tr"; ip=$?
	[ "$(printf '%s\n' "$ctr" | grep -c .)" = 1 ] && [ "$cc" -ge "$CUTAT" ] && [ "$cf" -ge 2 ] && [ "$cf" -le 15 ] && [ "$(num "$(val B cut-mark-snap)" 0)" -ge 1 ] && [ "$ip" = 0 ] && [ "$(num "$(val B cut-refused-before)" 0)" -ge 1 ] && [ "$(num "$(val B cut-snap-before-go)" 1)" = 0 ] && [ "$(num "$(val B cut-root-rw-rc)" 1)" = 0 ]; check "control: the relay's $CUT fault falls inside the pass, in a scanall call from the ${CUTAT}th with 2 to 15 feeds" $? "call $cc of K $CUTAT with $cf feeds after $(val H fault-wait-ms) ms, $(num "$cafter" 0) calls opened after it, snapshots read before the mark $(val B cut-mark-snap), verdicts before B's HM2 line $hv, the next call $(num "$fgap" -) ms after it, verdicts before the mark $(val B cut-mark-verdicts); before the read-write remount (rc $(val B cut-root-rw-rc)) refusals $(val B cut-refused-before), snapshots $(val B cut-snap-before-go)"
	kc=$(sed -n 's/.* late-copy t=[0-9]* key=\([0-9a-f]*\).*/\1/p' "$tr" 2>/dev/null | head -1); kn=$(sed -n 's/.* late-new t=[0-9]* key=\([0-9a-f]*\).*/\1/p' "$tr" 2>/dev/null | head -1)
	case $CUT in
	loss) enp=0;;
	dup) enp=1;;
	# the copy is refused unless it is in the new call's range, and then
	# the call's own first feed unless its key is above the copy's
	# (hammer2_remote.c's feed loop); a call that feeds nothing of its own
	# leaves the copy its only frame
	late) kr=$(sed -n 's/.* late-copy t=[0-9]* key=[0-9a-f]* inrange=\([01]\).*/\1/p' "$tr" 2>/dev/null | head -1)
		lm=$(sed -n 's/.* msgid=\([0-9]*\) late-copy .*/\1/p' "$tr" 2>/dev/null | head -1)
		lf=$(awk -v m="msgid=$lm" '/ late-copy / { s = 1 } s && index($0, m " open ") { sub(/.*call=/, ""); c = $1 } c != "" && index($0, " close ") && index($0, " call=" c " ") { sub(/.*feeds=/, ""); print $1; exit }' "$tr" 2>/dev/null)
		if [ -z "$kc" ]; then enp=void; elif [ "$kr" != 1 ]; then enp=1; elif [ -n "$kn" ]; then [ "$(expr "x$kn" \> "x$kc")" = 1 ] && enp=0 || enp=1; elif [ "$lf" = 0 ]; then enp=0; else enp=void; fi;;
	esac
	if [ "$enp" = void ]; then
		VOID="late's copy met no scanall call after the fault, or that call's own feeds went unread (late-unspent $(grep -c '^late-unspent ' "$tr" 2>/dev/null), copy key ${kc:-none}, new key ${kn:-none}, the new call's feeds ${lf:-unread})"
	else
		[ "$(num "$(val B cut-up-notproxy)" -1)" = "$enp" ] && [ "$(num "$(val B cut-up-hm2)" -1)" = "$enp" ] && [ "$(num "$(val B cut-up-ending)" 1)" = 0 ] && [ "$(num "$(val B cut-up-detached)" 1)" = 0 ] && [ "$(val H fault-first)" = timeout ] && [ "$(num "$nh" 1)" = 0 ] && [ "$(num "$nbc" 0)" = 1 ] && [ "$ce" = 0 ] && [ "$(num "$cafter" 0)" -ge 1 ]; check "control: with the sequence checks off the $CUT fault is taken and the link stays up past it" $? "not a proxy $(val B cut-up-notproxy) of $enp, HM2 lines $(val B cut-up-hm2) ($(val B cut-up-hm2-text)), ending the link $(val B cut-up-ending), detached $(val B cut-up-detached), first $(val H fault-first) after $(val H fault-first-ms) ms, hangups $(num "$nh" 0), B's pairs $(num "$nbc" 0), the cut call's close error ${ce:-unread}, calls after $(num "$cafter" 0), keys copy ${kc:--} new ${kn:--}; verdict $(val B cut-up-verdict) after $(val B cut-up-seconds) s"
	fi
	# a fault the slave took leaves it unequal to the master under a verified
	# pass; printed, as the verdict is
	[ "$fa" = 0 ] && [ "$fb" = 0 ]; check "control: both volumes are clean by fsck_hammer2" $? "A rc $fa, B rc $fb; fingerprint lines only on A $(diff "$W/fp.a" "$W/fp.b" | grep -c '^<'), only on B $(diff "$W/fp.a" "$W/fp.b" | grep -c '^>')"
elif [ -n "$CUT" ]; then
	# Where the cut fell: in a scanall call from the Kth on, with 2 to 15
	# feeds, after the pass read its snapshot and before any verdict; under
	# disconnect the calls the relay counts after it on the next pair are
	# the upper bound, the pass having had more to scan.
	# A protocol cell's fault is its own trace line, read against the mark
	# written into B's log when the host saw it, since B's detach can follow
	# the fault by the 10 s wait; the disconnect is the cut line and the
	# relay's one disconnect, read against the detach.
	tr=$FIXDIR/wire-run-$stamp.trace
	fw=cut; sb4=cut-snap-before; ip=0; hv=-; fgap=-
	if [ "$PROTO" = 1 ]; then fw=$FAULT sb4=cut-mark-snap; inpass "$tr"; ip=$?; else [ "$(num "$(val B cut-verdicts-before)" 1)" = 0 ] || ip=1; fi
	ccut=$(sed -n "s/.* $fw t=[0-9]* call=\([0-9]*\) feeds=\([0-9]*\).*/\1 \2/p" "$tr" 2>/dev/null)
	cc=$(num "${ccut% *}" -1); cf=$(num "${ccut#* }" 0)
	cafter=$(awk -v c="$cc" '/ open t=/ { sub(/.*call=/, ""); if ($1 + 0 > c) n++ } END { print n + 0 }' "$tr" 2>/dev/null)
	ndisc=$(grep -c '^disconnect ' "$tr" 2>/dev/null); nd=1; [ "$PROTO" = 1 ] && nd=0
	[ "$(printf '%s\n' "$ccut" | grep -c .)" = 1 ] && [ "$cc" -ge "$CUTAT" ] && [ "$cf" -ge 2 ] && [ "$cf" -le 15 ] && [ "$(num "$ndisc" 9)" = "$nd" ] && { [ "$CUT" = control ] || [ "$(num "$cafter" 0)" -ge 1 ]; } && [ "$(num "$(val B $sb4)" 0)" -ge 1 ] && [ "$ip" = 0 ] && [ "$(num "$(val B cut-refused-before)" 0)" -ge 1 ] && [ "$(num "$(val B cut-snap-before-go)" 1)" = 0 ] && [ "$(num "$(val B cut-root-rw-rc)" 1)" = 0 ]; check "cut: the relay's $FAULT falls inside the pass, in a scanall call from the ${CUTAT}th with chains still to feed" $? "call $cc of K $CUTAT with $cf feeds, $(num "$cafter" 0) calls after it, disconnects $(num "$ndisc" 0), snapshots read before $(val B $sb4), verdicts between $(val B cut-verdicts-before) (B's HM2 line $hv, the next call $fgap ms after it, the mark $(val B cut-mark-verdicts)); before the read-write remount (rc $(val B cut-root-rw-rc)) refusals $(val B cut-refused-before), snapshots $(val B cut-snap-before-go)"
	# A protocol cell ends the link on B with the one line its check prints,
	# so B's reader ends the pair and no hangup follows; trail's copy may
	# instead find its state gone and do nothing, outcome (a), which only
	# the hangup ends. Late's copy meeting no later scanall call makes the
	# run void.
	pa=0; pv=0
	if [ "$PROTO" = 1 ]; then
		case $CUT in
		loss|reorder) el='peer closed a reply short, ending the link';;
		dup) el='peer sent a feed out of sequence, ending the link';;
		late) el="peer sent another call's feed, ending the link";;
		trail) el='peer sent a frame after its reply closed, ending the link';;
		esac
		nh=$(grep -c '^hangup ' "$tr" 2>/dev/null)
		bk=$FIXDIR/wire-run-$stamp-b.klog
		nk=$(num "$(grep -c 'BUG: KASAN' "$bk" 2>/dev/null)" -1)
		nkr=$(awk '/BUG: KASAN/ { r = 1 } r && /hammer2_rcall_reply/ { n++; r = 0 } /Allocated by task|Freed by task|The buggy address|=====/ { r = 0 } END { print n + 0 }' "$bk" 2>/dev/null)
		nkr=$(num "$nkr" -1); np=$(num "$(grep -c 'not a proxy' "$bk" 2>/dev/null)" -1)
		if [ "$(val B cut-hm2-text)" = "$el;" ] && [ "$(val H fault-first)" = eof ] && [ "$(num "$nh" 1)" = 0 ]; then to=closed
		elif [ "$CUT" = trail ] && [ "$(num "$(val B cut-hm2)" 1)" = 0 ] && [ "$(val H fault-first)" = timeout ] && [ "$(num "$nh" 0)" = 1 ]; then to=silent; pa=1
		else to=other; fi
		# A silent copy leaves the pass running through the wait, and a
		# pass that verifies there deletes the source by its own path: A
		# has no snapshot left for the link, and with the master idle no
		# pass after the dial need print a verdict.
		[ "$pa" = 1 ] && [ "$(num "$(val B cut-verified)" 0)" = 1 ] && pv=1
		[ "$CUT" = trail ] && echo "  trail-outcome $to"
		if [ "$CUT" = late ] && grep -q '^late-unspent ' "$tr" 2>/dev/null; then
			VOID="late's copy met no scanall call after the fault before the pair ended"
		else
			[ "$to" != other ] && [ "$nk" = 0 ] && [ "$np" = 0 ]; check "$CUT: B ends the link at the fault with the one line its check prints$([ "$CUT" = trail ] && echo ", or the copy does nothing and the relay hangs the pair up")" $? "outcome $to: HM2 lines $(val B cut-hm2) ($(val B cut-hm2-text)) of \"$el\", first $(val H fault-first) after $(val H fault-first-ms) ms, hangups $(num "$nh" 0), not a proxy $np, KASAN reports $nk of which in hammer2_rcall_reply $nkr, late keys $(sed -n 's/.* late-\(copy\|new\) t=[0-9]* key=/\1 /p' "$tr" 2>/dev/null | tr '\n' ' ')"
		fi
	fi
	# The link's end on B: the span's deletion detaches the slot, the call
	# in flight ends not connected, the pass unverified, its target kept,
	# and every pass in the gap finds no quorum. Under trail the copy can
	# end the link between calls with none in flight, and then the pass's
	# own ENOTCONN (0x00080000) is the reading.
	[ "$(num "$(val B cut-detached)" 0)" = 1 ] && [ "$(val B cut-detached-why | sed 's/ *$//')" = "span deleted" ] && { [ "$pa" = 1 ] || { { [ "$(num "$(val B cut-scanall-notconn)" 0)" -ge 1 ] || { [ "$CUT" = trail ] && [ "$(val B cut-unverified-line | sed 's/.* error //; s/ *$//')" = 524288 ]; }; } &&[ "$(num "$(val B cut-unverified)" 0)" = 1 ] && [ "$(num "$(val B cut-verified)" 1)" = 0 ] && [ "$(num "$(val B cut-other-verdicts)" 1)" = 0 ] && [ "$(num "$(val B cut-target-taken)" 0)" = 1 ] && [ "$(num "$(val B cut-target-kept)" 1)" = 0 ] && [ "$(num "$(val B cut-noquorum)" 0)" -ge 1 ]; }; } && [ "$(num "$(val B cut-gap-ms)" 0)" -ge 6000 ]; check "cut: B detaches by the span's deletion, the pass ends unverified with its target kept, and the gap finds no quorum" $? "detached $(val B cut-detached) by $(val B cut-detached-why)after $(val B cut-detach-seconds) s, scanall ended ENOTCONN $(val B cut-scanall-notconn), verdicts unverified $(val B cut-unverified) ($(val B cut-unverified-line)) verified $(val B cut-verified) other $(val B cut-other-verdicts), target taken $(val B cut-target-taken) kept $(val B cut-target-kept), no quorum $(val B cut-noquorum) in $(val B cut-gap-ms) ms, source deletions refused $(val B cut-delete-errors)"
	# Neither kernel says HM2 at a link the relay ended; A keeps the link's
	# snapshot until its next connection's end.
	{ [ "$PROTO" = 1 ] || [ "$(num "$(val B cut-hm2)" 1)" = 0 ]; } && [ "$(num "$(val A cut-peer-hm2)" 1)" = 0 ] && [ "$(num "$(val A cut-link-left)" 1)" = 0 ]; check "cut: no HM2 line on A$([ "$PROTO" = 1 ] || echo " or B"), and A keeps the link's snapshot past the cut" $? "B $(val B cut-hm2), A $(val A cut-peer-hm2) HM2 lines, A's left-by-the-link deletions $(val A cut-link-left)"
	sa=$("$HAMMER2" -v show "$FIXDIR/wire-a.img" 2>/dev/null | grep -c 'filename "CL.h2sync-src"'); sb=$("$HAMMER2" -v show "$FIXDIR/wire-b.img" 2>/dev/null | grep -c 'filename "CL.h2sync-tgt"')
	[ "$fa" = 0 ] && [ "$fb" = 0 ]; check "cut: both volumes are clean by fsck_hammer2" $? "A rc $fa, B rc $fb"
	if [ "$CUT" = control ]; then
		# No dial: the slave stays short of the master, its target listed,
		# and A deletes the link's snapshot at its own unmount.
		[ "$nfa" -ge 300 ] && [ "$nfpb" -lt "$nfpa" ] && [ "$sb" = 1 ] && [ "$(num "$(val A snap-link-left)" 0)" = 1 ]; check "control: with no dial after the cut the slave stays short of the master and keeps its target" $? "file entries A $nfpa B $nfpb, CL.h2sync-tgt on B $sb, A's left-by-the-link deletions at its unmount $(val A snap-link-left), CL.h2sync-src on A $sa"
	else
		[ "$(num "$(val A cut-link-left-after)" 0)" = $((1 - pv)) ] && [ "$(num "$(val A cut-peer-hm2-after)" 1)" = 0 ] && [ "$(num "$(val B cut-threads-before)" 1)" = 0 ] && [ "$(num "$(val B cut-dial-rc)" 1)" = 0 ] && [ "$(num "$(val B cut-registered)" 0)" = 2 ]; check "cut: A deletes the link's snapshot at its dial, and B dials again and registers A's root a second time" $? "A's deletions $(val A cut-link-left-after), A's HM2 lines $(val A cut-peer-hm2-after), B's threads before $(val B cut-threads-before), B rc $(val B cut-dial-rc), registered $(val B cut-registered)"
		{ [ "$(val B cut-resumed-verdict)" = verified ] || { [ "$pv" = 1 ] && [ -z "$(val B cut-resumed-verdict)" ]; }; } && { [ "$pa" = 1 ] || [ "$(num "$(val B cut-resumed-target)" 1)" = 0 ]; } && [ "$(num "$(val B cut-resumed-hm2)" 1)" = 0 ] && [ "$(num "$(val B pass-media-files)" 0)" -ge 300 ] && [ "$(num "$(val B pass-snap-deleted)" 0)" -ge 1 ]; rc=$?
		lbl="cut: the first pass after the dial verifies on the target the cut pass took"
		[ "$pv" = 1 ] && lbl="cut: the cut pass verified inside the relay's wait and deleted its own target"
		check "$lbl" $rc "resumed verdict $(val B cut-resumed-verdict), targets taken after $(val B cut-resumed-target), HM2 lines after $(val B cut-resumed-hm2), $(val B pass-media-files) of A's files on B's media, deleted $(val B pass-snap-deleted), passes $(val B pass-snap-passes), no quorum $(val B pass-snap-noquorum), errors $(val B pass-errors) and $(val B pass-sync-errors)"
		[ "$(num "$(val A more-media-files)" 0)" = 5 ] && [ "$(num "$(val B more-media-files)" 0)" = 5 ] && [ "$(num "$(val B more-snap-deleted)" 0)" -ge 1 ] && { [ "$pa" = 1 ] || [ "$(num "$(val B more-snap-unverified)" 0)" = 1 ]; }; check "cut: five files written on the master after the resumed pass reach the slave by a later pass" $? "A $(val A more-media-files), B $(val B more-media-files) after $(val B more-wait-seconds) s, deleted $(val B more-snap-deleted) more, unverified $(val B more-snap-unverified) in all"
		[ "$nfa" -ge 300 ] && [ "$nfpa" = "$nfa" ] && [ "$ndata" -gt 0 ] && cmp -s "$W/fp.a" "$W/fp.b" && [ "$sa" = 0 ] && [ "$sb" = 0 ] && [ "$(num "$(val A snap-link-left)" 0)" = $((1 - pv)) ]; check "cut: the slave's CL matches the master's on the media and neither image holds a snapshot of the pass" $? "A $nfpa file entries and $ndata data blocks, B $nfpb; $(diff "$W/fp.a" "$W/fp.b" | grep -c '^[<>]') lines differ; CL.h2sync-src on A $sa, CL.h2sync-tgt on B $sb, A's left-by-the-link deletions $(val A snap-link-left)"
	fi
elif [ "$PASSREFUSE" = control ]; then
	# The refusal off: the live pass writes the device opened read-only,
	# with no line saying so, and B's image holds A's file entries. The
	# image is the reading: the guest's own show of the device read none
	# of them in 180 s (ctl-kasan-passrefuse-ctl.log), so it is printed
	# beside and not judged.
	[ "$(num "$(val B root-ro)" 0)" = 1 ] && [ "$(num "$(val B sync-snapshot)" 1)" = 0 ] && [ "$(num "$(val B first-refused-lines)" 1)" = 0 ] && [ "$nfa" -ge 300 ] && [ "$nfpb" = "$nfpa" ]; check "control: with the pass's refusal off the live pass writes B's read-only device silently" $? "device read-only $(val B root-ro), refusal lines $(val B first-refused-lines), $(val B first-media-files) of A's files on B's media after $(val B first-wait-seconds) s, file entries A $nfpa B $nfpb by fingerprint, $(diff "$W/fp.a" "$W/fp.b" | grep -c '^[<>]') lines differ, fsck A rc $fa B rc $fb"
elif [ "$SNAPROUTE" = control ]; then
	# The routing off: the snapshot of the remote master runs the local
	# body on the connection device, which refuses the block it would
	# create; the pass takes no snapshot and copies nothing.
	[ "$(num "$(val B first-snap-eopnotsupp)" 0)" -ge 1 ] && [ "$(num "$(val B first-snap-eopnotsupp)" 0)" = "$(num "$(val B first-snap-errors)" 0)" ] && [ "$(num "$(val B first-remote-snaps)" 1)" = 0 ] && [ "$(num "$(val B first-media-files)" 1)" = 0 ]; check "control: with the snapshot's routing off the pass's snapshot reaches the connection device and is refused before the body" $? "snapshot errors $(val B first-snap-errors) of which EOPNOTSUPP $(val B first-snap-eopnotsupp), remote snapshots $(val B first-remote-snaps), $(val B first-media-files) files on B's media after $(val B first-wait-seconds) s"
elif [ "$ROGATE" = 0 ]; then
	# (under the gate's control CL is writable after its remount, and the
	# live pass fills the slave; its control check reads that)
	[ "$(num "$(val B pass-refused)" 0)" -ge 1 ] && [ "$(num "$(val B slave-show-rc)" 1)" = 0 ] && [ "$(num "$(val B slave-cl)" 0)" -ge 1 ] && [ "$(num "$(val B slave-show-failed)" 1)" = 0 ] && [ "$(num "$(val B slave-files)" 1)" = 0 ] && [ "$(num "$(val A media-files)" 0)" -ge 300 ]; check "remote: B's pass refuses its read-only device and the slave copies nothing" $? "refusal lines $(val B pass-refused), slave files $(val B slave-files) by $(val B utility)'s show rc $(val B slave-show-rc) reaching CL's root $(val B slave-cl) with $(val B slave-show-failed) failed reads, the pattern matching $(val A media-files) on A's media"
fi
# The file is on A alone, so no block has an address on B: every extent
# says so rather than reporting the 0 no local element supplied. After
# the pass the slave holds the block, and the address is the slave's,
# the local chain the check matched to the remote focus.
fx=$(num "$(val B fiemap-extents)" 0)
if [ "$STALE" = 1 ]; then
	# The slave's copy of the first block is older than the master's, so
	# the check leaves it out of the quorum and bmap has no local address
	# for that block; every other block, and every block of a file A left
	# alone, is the slave's own.
	[ "$(num "$(val B fiemap-rc)" 1)" = 0 ] && [ "$fx" -ge 2 ] && [ "$(num "$(val B fiemap-unknown)" 0)" = 1 ] && [ "$(num "$(val B fiemap-first-unknown)" 0)" = 1 ]; check "stale: fiemap of the rewritten file has no address for the block the slave holds stale and the slave's own for the rest" $? "rc $(val B fiemap-rc), $fx extent(s), $(val B fiemap-unknown) unknown_loc of which at logical 0 $(val B fiemap-first-unknown)"
	[ "$(num "$(val B fiemap2-rc)" 1)" = 0 ] && [ "$(num "$(val B fiemap2-extents)" 0)" -ge 1 ] && [ "$(num "$(val B fiemap2-unknown)" 1)" = 0 ]; check "stale: fiemap of a file A left alone reports the slave's own address for every block" $? "rc $(val B fiemap2-rc), $(val B fiemap2-extents) extent(s), $(val B fiemap2-unknown) unknown_loc"
elif [ "$WRITTEN" = 1 ]; then
	[ "$LINKLOST" = 1 ] || { [ "$(num "$(val B fiemap-rc)" 1)" = 0 ] && [ "$fx" -ge 1 ] && [ "$(num "$(val B fiemap-unknown)" 1)" = 0 ]; check "pass: fiemap of a 512 KiB file reports the slave's own address once the pass has written it" $? "rc $(val B fiemap-rc), $fx extent(s), $(val B fiemap-unknown) unknown_loc"; }
else
[ "$REKEY" = 1 ] || [ "$LINKLOST" = 1 ] || { [ "$(num "$(val B fiemap-rc)" 1)" = 0 ] && [ "$fx" -ge 1 ] && [ "$(num "$(val B fiemap-unknown)" 0)" = "$fx" ]; check "remote: fiemap of a 512 KiB file runs bmap over the wire and claims no address" $? "rc $(val B fiemap-rc), $fx extent(s), $(val B fiemap-unknown) unknown_loc"; }
fi
if [ "$RETYPE" = 1 ]; then
	rt=$(grep -c ' retype ' "$FIXDIR/wire-run-$stamp.trace" 2>/dev/null)
	[ "$(num "$rt" 0)" = 1 ] && [ "$(num "$(val B log-not-proxy)" 0)" = 1 ] && [ "$(num "$(val B log-not-proxy-scanall)" 0)" = 1 ] && [ "$(num "$(val B log-scanall-notconn)" 0)" -ge 1 ] && [ "$(num "$(val B log-peer-sent)" 1)" = 0 ] && [ "$(num "$(val B pass-snap-unverified)" 0)" = 1 ]; check "control: a directory entry a scanall feeds as a data block passes the CRCs and B's pass refuses it" $? "retype lines $(num "$rt" 0), not-proxy $(val B log-not-proxy) of which scanall $(val B log-not-proxy-scanall), scanall ended ENOTCONN $(val B log-scanall-notconn), peer-sent $(val B log-peer-sent), unverified passes $(val B pass-snap-unverified) ($(val B pass-unverified-first)), pass errors $(val B pass-errors) and $(val B pass-sync-errors)"
fi
if [ "$REKEY" = 1 ]; then
	rk=$(grep -c ' rekey ' "$FIXDIR/wire-run-$stamp.trace" 2>/dev/null)
	[ "$(num "$rk" 0)" = 1 ] && [ "$(num "$(val B log-not-proxy)" 0)" = 1 ] && [ "$(num "$(val B log-not-proxy-bmap)" 0)" = 1 ] && [ "$(num "$(val B fiemap-extents)" 1)" = 0 ] && [ "$(num "$(val B fiemap-unknown)" 1)" = 0 ] && [ -n "$(sums A sum)" ] && [ "$(sums A sum)" = "$(sums B sum)" ] && [ "$(sums A sum)" = "$(sums B cold)" ] && [ "$(num "$(val B log-peer-sent)" 1)" = 0 ] && [ "$(num "$(val B log-bmap-notconn)" 0)" -ge 1 ]; check "control: a data feed moved off its key passes the CRCs and B refuses it" $? "rekey lines $(num "$rk" 0), bmap ended ENOTCONN $(val B log-bmap-notconn), not-proxy $(val B log-not-proxy) of which bmap $(val B log-not-proxy-bmap), peer-sent $(val B log-peer-sent), fiemap $(val B fiemap-extents) extent(s) $(val B fiemap-unknown) unknown_loc, $(sums B sum | grep -c .) warm and $(sums B cold | grep -c .) cold of $(sums A sum | grep -c .) equal"
else
# under STALE A's digest of the rewritten file is the one taken after it
asums() { if [ "$STALE" = 1 ]; then sums A sum | sed "s|^\./big\.bin .*|$(val A stalesum)|" | sort; else sums A sum; fi; }
[ "$STALE" = 0 ] || { [ "$(num "$(val A stale-write-rc)" 1)" = 0 ] && [ -n "$(val A stalesum)" ] && [ "$(val A stalesum)" != "$(sums A sum | grep '^\./big\.bin ')" ]; check "stale: A's rewrite of the file's first block changed its digest" $? "dd rc $(val A stale-write-rc), $(sums A sum | grep '^\./big\.bin ' | cut -c1-28) then $(val A stalesum | cut -c1-28)"; }
[ "$LINKLOST" = 1 ] || { [ -n "$(asums)" ] && [ "$(asums)" = "$(sums B sum)" ]; check "remote: every file's digest on B equals A's" $? "$(sums B sum | grep -c .) of $(asums | grep -c .) equal by sha256, blocks read in folios larger than the block A $(val A io-large-folios) B $(val B io-large-folios)"; }
[ "$LINKLOST" = 1 ] || { [ -n "$(asums)" ] && [ "$(asums)" = "$(sums B cold)" ]; check "remote: the same digests after B drops its caches" $? "$(sums B cold | grep -c .) read cold, cpu0 $(val B digest-irqs-before) then $(val B digest-irqs-after)"; }
fi
if [ "$ROGATE" = control ]; then
	# The gate off: CL remounts read-write and a chmod through it reaches
	# the slave's inode on B's media and not the master's, B read live just
	# after the write and A from its image with the guests down; B's image
	# is printed beside, since a later pass may have brought it level.
	ma=$("$HAMMER2" -v show "$FIXDIR/wire-a.img" 2>/dev/null | awk -v n='"small.txt"' -f "$W/clmode.awk"); mb=$("$HAMMER2" -v show "$FIXDIR/wire-b.img" 2>/dev/null | awk -v n='"small.txt"' -f "$W/clmode.awk")
	[ "$(num "$(val B remount-rc)" 1)" = 0 ] && [ "$(num "$(val B log-remount-refused)" 1)" = 0 ] && [ "$(num "$(val B rogate-write-rc)" 1)" = 0 ] && [ "$(val B rogate-slave-mode)" = 600 ] && [ "$ma" = 644 ]; check "control: with the read-only gate off B's CL remounts read-write and a chmod lands on the slave alone" $? "remount rc $(val B remount-rc), refusal lines $(val B log-remount-refused), the pass's refusals before it $(val B pass-refused) and $(val B slave-files) files on the slave after, small.txt on the slave after $(val B rogate-wait-seconds) s, emergency mode rc $(val B rogate-emerg-rc), chmod rc $(val B rogate-write-rc) \"$(val B rogate-write-err)\", mode on B's media live $(val B rogate-slave-mode), in the images A $ma B $mb"
else
[ "$LINKLOST" = 1 ] || { [ "$(num "$(val B remount-rc)" 0)" != 0 ] && [ "$(num "$(val B log-remount-refused)" 0)" -ge 1 ]; check "remote: a read-write remount is refused while the element is registered" $? "remount rc $(val B remount-rc), refusal lines $(val B log-remount-refused)"; }
fi
if [ "$DIRENT" = 1 ]; then
	bd=$(grep -c ' bare-dirent ' "$FIXDIR/wire-run-$stamp.trace" 2>/dev/null)
	[ "$(num "$bd" 0)" = 1 ] && [ "$(num "$(val B first-stat-rc)" 0)" != 0 ] && [ "$(num "$(val B log-not-proxy)" 0)" = 1 ] && [ "$(num "$(val B log-not-proxy-nresolve)" 0)" = 1 ] && [ "$(num "$(val B log-peer-sent)" 1)" = 0 ] && [ "$(num "$(val B log-nresolve-notconn)" 0)" -ge 1 ]; check "control: an nresolve answered by a directory entry with no bytes is refused, not read as an inode" $? "bare-dirent lines $(num "$bd" 0), nresolve ended ENOTCONN $(val B log-nresolve-notconn), first stat rc $(val B first-stat-rc), not-proxy $(val B log-not-proxy) of which nresolve $(val B log-not-proxy-nresolve), peer-sent $(val B log-peer-sent)"
fi
if [ "$REFUSE" = 1 ]; then
	rf=$(grep -c ' refuse ' "$FIXDIR/wire-run-$stamp.trace" 2>/dev/null)
	[ "$(num "$rf" 0)" = 1 ] && [ "$(num "$(val B first-stat-rc)" 0)" != 0 ] && [ "$(num "$(val B first-stat-notconn)" 0)" = 1 ] && [ "$(num "$(val B first-stat-enoent)" 1)" = 0 ] && [ "$(num "$(val B first-stat-unsupported)" 1)" = 0 ] && [ "$(num "$(val B log-nresolve-notconn)" 0)" -ge 1 ]; check "control: a lookup the server refused reads the master unreachable, not as its answer" $? "refuse lines $(num "$rf" 0), first stat rc $(val B first-stat-rc) \"$(val B first-stat-err)\", not connected $(val B first-stat-notconn), no such file $(val B first-stat-enoent), not supported $(val B first-stat-unsupported), nresolve ended ENOTCONN $(val B log-nresolve-notconn)"
fi
if [ -n "$END" ]; then
	en=$(grep -c ' end .*mode=' "$FIXDIR/wire-run-$stamp.trace" 2>/dev/null)
	if [ "$END" = lost ]; then
		[ "$(num "$en" 0)" = 1 ] && [ "$(num "$(val B empty-ls-rc)" 0)" != 0 ] && [ "$(num "$(val B empty-ls-notconn)" 0)" = 1 ] && [ "$(num "$(val B log-readdir-notconn)" 0)" -ge 1 ] && [ "$(val B log-readdir-first)" = "fed=0 error=00000001 end=00080000" ] && [ "$(num "$(val B log-readdir-other)" 1)" = 0 ] && [ "$(num "$(val B log-peer-sent)" 1)" -ge 1 ] && [ "$(num "$(val B files)" 0)" = 0 ] && [ "$(num "$(val B find-notconn)" 0)" -ge 1 ]; check "control: a closing feed with a chain ends the link, not as its answer" $? "end lines $(num "$en" 0), listing rc $(val B empty-ls-rc) \"$(val B empty-ls-err)\", not connected $(val B empty-ls-notconn), readdir ended ENOTCONN $(val B log-readdir-notconn) with the first \"$(val B log-readdir-first)\" and $(val B log-readdir-other) ending otherwise, peer-sent $(val B log-peer-sent), B listed $(val B files) after with $(val B find-notconn) not connected"
	elif [ "$END" = onefed ]; then
		[ "$(num "$en" 0)" = 2 ] && [ "$(num "$(val B log-readdir-onefed-notconn)" 0)" = 2 ] && [ "$(num "$(val B empty-ls-rc)" 1)" = 0 ] && [ "$(num "$(val B onefed-entries)" 0)" = 302 ] && [ "$(num "$(val B many)" 0)" = 300 ]; check "control: a clean close with no end after one fed chain is no answer from a readdir, which the entry it emitted hides from the caller" $? "end lines $(num "$en" 0), readdir with one chain fed ended ENOTCONN $(val B log-readdir-onefed-notconn), listing rc $(val B empty-ls-rc) over $(val B onefed-entries) entries with the dots, the directory listed whole after $(val B many)"
	else
		[ "$(num "$en" 0)" = 2 ] && [ "$(num "$(val B empty-ls-rc)" 0)" != 0 ] && [ "$(num "$(val B empty-ls-notconn)" 0)" = 1 ] && [ "$(num "$(val B log-readdir-notconn)" 0)" = 2 ]; check "control: a reply closed $END reads the master unreachable, not as its answer" $? "end lines $(num "$en" 0), listing rc $(val B empty-ls-rc) \"$(val B empty-ls-err)\", not connected $(val B empty-ls-notconn), readdir ended ENOTCONN $(val B log-readdir-notconn)"
	fi
fi
if [ "$STALL" != 0 ]; then
	st=$(grep -c ' stall ' "$FIXDIR/wire-run-$stamp.trace" 2>/dev/null)
	[ "$(num "$st" 0)" = 1 ] && [ "$(num "$(val B remote-timeout-ms)" 0)" = 2000 ] && [ "$(num "$(val B find-notconn)" 0)" -ge 1 ] && [ "$(num "$(val B log-readdir-timedout)" 0)" -ge 1 ] && [ "$(num "$(val B readdir-timedout-ms)" 0)" -ge 2000 ]; check "control: a reply held past B's bound ends the call with the master unreachable" $? "stall lines $(num "$st" 0) for $STALL ms, bound $(val B remote-timeout-ms) ms, shortest timed-out readdir $(val B readdir-timedout-ms) ms, listing not connected $(val B find-notconn), readdir ended ETIMEDOUT $(val B log-readdir-timedout), B listed $(val B files) of $nfa"
fi
[ "$REKEY" = 1 ] || [ "$DIRENT" = 1 ] || [ "$RETYPE" = 1 ] || [ "$LINKLOST" = 1 ] || [ "$PROTO" = 1 ] || { [ "$(num "$(val B log-not-proxy)" 1)" = 0 ] && [ "$(num "$(val B log-peer-sent)" 1)" = 0 ]; check "remote: no feed refused as a proxy, no protocol error" $? "not-proxy $(val B log-not-proxy), peer-sent $(val B log-peer-sent), $(val B remote-xops) remote XOPs, $(val B refetches) refetches"; }
if [ "$ROGATE" = control ]; then
	[ "$(num "$(val B rw-mount-rc)" 1)" = 0 ] && [ "$(num "$(val B log-mount-refused)" 1)" = 0 ]; check "control: with the read-only gate off a read-write mount of B's CL is taken beside the remote master" $? "mount rc $(val B rw-mount-rc), refusal lines $(val B log-mount-refused)"
else
[ "$LINKLOST" = 1 ] || [ "$SILENCE" = 1 ] || { [ "$(num "$(val B rw-mount-rc)" 0)" != 0 ] && [ "$(num "$(val B log-mount-refused)" 0)" -ge 1 ]; check "remote: a read-write mount of B's CL is refused while the element is registered" $? "mount rc $(val B rw-mount-rc), refusal lines $(val B log-mount-refused)"; }
fi
# SNAPDEL for a name of the pass's suffix on A that the link never took:
# A says so and the PFS stays, or in the control A deletes it.
if [ "$SNAPDEL" != 0 ]; then
	rn=$(grep -c ' rename-snapdel ' "$FIXDIR/wire-run-$stamp.trace" 2>/dev/null)
	za=$("$HAMMER2" -v show "$FIXDIR/wire-a.img" 2>/dev/null | grep -c 'filename "ZZ.h2sync-src"')
	if [ "$SNAPDEL" = 1 ]; then
		[ "$(num "$rn" 0)" = 1 ] && [ "$(num "$(val A decoy-rc)" 1)" = 0 ] && [ "$(num "$(val A snapdel-not-ours)" 0)" = 1 ] && [ "$(num "$(val A snapdel-decoy-deleted)" 1)" = 0 ] && [ "$za" = 1 ]; check "control: a SNAPDEL naming a snapshot the link never took deletes nothing" $? "renames $(num "$rn" 0), decoy created rc $(val A decoy-rc), A's not-ours lines $(val A snapdel-not-ours), deleted $(val A snapdel-decoy-deleted), ZZ.h2sync-src on A's image $za"
	else
		[ "$(num "$rn" 0)" = 1 ] && [ "$(num "$(val A decoy-rc)" 1)" = 0 ] && [ "$(num "$(val A snapdel-not-ours)" 1)" = 0 ] && [ "$(num "$(val A snapdel-decoy-deleted)" 0)" = 1 ] && [ "$za" = 0 ]; check "control: with SNAPDEL's scope off the master deletes a snapshot its link never took" $? "renames $(num "$rn" 0), decoy created rc $(val A decoy-rc), A's not-ours lines $(val A snapdel-not-ours), deleted $(val A snapdel-decoy-deleted), ZZ.h2sync-src on A's image $za"
	fi
fi
# Admission in the daemon: a row whose label has no .none and no key.
if [ "$ADMIT" = 1 ]; then
	[ "$(num "$(val B noadmit-dial-rc)" 0)" != 0 ] && [ "$(num "$(val B noadmit-refused)" 0)" = 1 ] && [ "$(num "$(val B dial-rc)" 1)" = 0 ] && [ "$(num "$(val B log-registered)" 0)" = 1 ]; check "control: a peer with no .none and no key is refused at the dial, and dialed once the marker is there" $? "unmarked dial rc $(val B noadmit-dial-rc) with $(val B noadmit-refused) refusal, marked dial rc $(val B dial-rc), registered $(val B log-registered)"
elif [ "$ADMIT" = control ]; then
	[ "$(num "$(val B noadmit-dial-rc)" 1)" = 0 ] && [ "$(num "$(val B noadmit-refused)" 1)" = 0 ] && [ "$(num "$(val B log-registered)" 0)" = 1 ]; check "control: with admission off a peer with no .none and no key is dialed and its master registered" $? "unmarked dial rc $(val B noadmit-dial-rc) with $(val B noadmit-refused) refusal, registered $(val B log-registered)"
fi
# The plain run's detach is the connection's end at B's unmount; under lost
# and under the keepalive's silence the link ended first and the peer's
# span deletion detached it. Each run reads the path it expects, not a
# count of one by either.
dw=$(val B detached-why | sed 's/ *$//')
if [ "$LINKDEV" = 1 ]; then
	[ "$(val B linkdev)" = 1 ] && [ "$(num "$(val B vdb-gone-detached)" 0)" = 1 ] && [ "$(num "$(val B vdb-gone-threads)" 0)" -ge 1 ] && [ "$(num "$(val B log-detached)" 0)" = 1 ] && [ "$dw" = "unmount" ]; check "remote: B's own device leaving first detaches the element once, by its unmount, with the link on vdc still up" $? "$(val B log-detached), by $dw, $(val B vdb-gone-detached) before vdc's unmount with $(val B vdb-gone-threads) link threads"
elif [ "$SEQ" = control ]; then
	[ "$(num "$(val B log-detached)" 0)" = 1 ] && [ "$dw" = "connection ended" ]; check "control: the link left up past the fault detaches the element once, by the connection's end at B's unmount" $? "$(val B log-detached), by $dw"
elif [ "$CUT" = disconnect ] || [ "$CUT" = master ] || [ "$PROTO" = 1 ]; then
	# the cut's by the span, the redial finding the slot already clear; the
	# second link's by B's unmount
	[ "$(num "$(val B log-detached)" 0)" = 2 ] && [ "$dw" = "span deleted connection ended" ]; check "cut: the element is detached once at the cut, by the span's deletion, and once at B's unmount" $? "$(val B log-detached), by $dw"
elif [ "$LINKLOST" = 1 ] || [ "$SILENCE" = 1 ]; then
	[ "$(num "$(val B log-detached)" 0)" = 1 ] && [ "$dw" = "span deleted" ]; check "remote: the link's end detaches the element once, by the span's deletion" $? "$(val B log-detached), by $dw"
elif [ "$STALE" = 1 ]; then
	[ "$(num "$(val B stale-detached)" 0)" = 1 ] && [ "$(num "$(val B log-detached)" 0)" = 2 ] && [ "$dw" = "connection ended connection ended" ]; check "stale: each of B's two device unmounts detaches the element once, by the connection's end" $? "$(val B stale-detached) at the first, $(val B log-detached) in all, by $dw"
	[ "$(num "$(val A redial-threads-before)" 1)" = 0 ] && [ "$(num "$(val A redial-rc)" 1)" = 0 ] && [ "$(num "$(val B stale-dial-rc)" 1)" = 0 ] && [ "$(num "$(val B stale-registered)" 0)" = 2 ]; check "stale: both sides dial again by their rows and B registers A's root a second time" $? "A's threads before $(val A redial-threads-before), A rc $(val A redial-rc), B rc $(val B stale-dial-rc), registered $(val B stale-registered)"
	[ "$(num "$(val B pass-refused)" 0)" -ge 1 ]; check "stale: B's pass refuses its read-only device, so the slave keeps what it copied" $? "refusal lines $(val B pass-refused)"
else
	[ "$(num "$(val B log-detached)" 0)" = 1 ] && [ "$dw" = "connection ended" ]; check "remote: B's device unmount detaches the element once, by the connection's end" $? "$(val B log-detached), by $dw"
fi
# The keepalive: the silence starts at the marker's answer, so nothing is
# in flight, and the link's end is the keepalive's own line or nothing.
# The fake pass, a link ended by anything else, is kept out by the line
# itself and by the protocol-error count; a listing that fails fast for
# another reason would still lack the line.
if [ "$SILENCE" != 0 ]; then
	sf=$(grep -c ' silence-from ' "$FIXDIR/wire-run-$stamp.trace" 2>/dev/null); sd=$(grep -c ' silence ' "$FIXDIR/wire-run-$stamp.trace" 2>/dev/null)
	[ "$(num "$sf" 0)" = 1 ] && [ "$(num "$sd" 0)" -ge 1 ] && [ "$(num "$(val B silence-stat-rc)" 0)" != 0 ] && [ "$(num "$(val B silence-stat-enoent)" 0)" = 1 ]; check "silence: the marker's lookup is answered absent and the relay drops every frame after its answer" $? "silence-from lines $(num "$sf" 0), dropped $(num "$sd" 0), stat rc $(val B silence-stat-rc) absent $(val B silence-stat-enoent)"
	if [ "$SILENCE" = 1 ]; then
		[ "$(num "$(val B silence-line)" 0)" = 1 ] && [ "$(num "$(val B silence-silent-ms)" 0)" -ge 2000 ] && [ "$(num "$(val B silence-wait-ms)" 99999)" -lt 20000 ] && [ "$(num "$(val B silence-peer-sent)" 1)" = 0 ]; check "silence: B's keepalive ends the link once, the peer silent for no less than the bound, with no request in flight" $? "line $(val B silence-line) after $(val B silence-wait-ms) ms, silent $(val B silence-silent-ms) ms against the 2000 ms bound, protocol errors $(val B silence-peer-sent); A's line $(val2 A keepalive-line)"
		[ "$(num "$(val B silence-detached)" 0)" -ge 1 ] && [ "$(num "$(val B silence-find-notconn)" 0)" -ge 1 ] && [ "$(num "$(val B silence-find-ms)" 99999)" -lt 2000 ] && [ "$(num "$(val B silence-timedout-ends)" 1)" = 0 ]; check "silence: the element is detached before the next listing, which fails not connected at once with no request timed out" $? "detached $(val B silence-detached), listing \"$(val B silence-find-err)\" in $(val B silence-find-ms) ms, not connected $(val B silence-find-notconn), requests timed out $(val B silence-timedout-ends), $(val B silence-files) files"
	else
		[ "$(num "$(val B silence-line)" 1)" = 0 ] && [ "$(num "$(val2 A keepalive-line)" 1)" = 0 ] && [ "$(num "$(val B silence-detached)" 1)" = 0 ]; check "control: with no keepalive armed the silence is seen by neither kernel and the element stays" $? "lines B $(val B silence-line), A $(val2 A keepalive-line), detached $(val B silence-detached)"
		[ "$(num "$(val B silence-timedout-ends)" 0)" -ge 1 ] && [ "$(num "$(val B silence-find-ms)" 0)" -ge 2000 ] && [ "$(num "$(val B silence-find-notconn)" 0)" -ge 1 ]; check "control: the next listing waits out the bound, its request ending timed out, before the caller reads not connected" $? "listing \"$(val B silence-find-err)\" in $(val B silence-find-ms) ms, requests timed out $(val B silence-timedout-ends), not connected $(val B silence-find-notconn)"
	fi
fi
# The window: A's server sends past it, so the count either ends the link
# by its own line at B's first listing of the 300-entry directory, or, in
# the control built without it, takes the feeds and says so once.
if [ "$WINDOW" = 1 ]; then
	[ "$(num "$(val B log-window-ended)" 0)" -ge 1 ] && [ "$(num "$(val B log-window-taken)" 1)" = 0 ] && [ "$(num "$(val B log-readdir-notconn)" 0)" -ge 1 ] && [ "$(num "$(val B find-notconn)" 0)" -ge 1 ] && [ "$(num "$(val B many)" 1)" = 0 ] && [ "$(num "$(val B first-stat-rc)" 1)" = 0 ]; check "control: a server past its window ends the link at B's count, not as an answer" $? "window lines $(val B log-window-ended), taken $(val B log-window-taken), readdir ended ENOTCONN $(val B log-readdir-notconn), listing not connected $(val B find-notconn) with $(val B files) of $nfa files, $(val B many) of 300 entries, the stat before it rc $(val B first-stat-rc)"
elif [ "$WINDOW" = control ]; then
	[ "$(num "$(val B log-window-taken)" 0)" = 1 ] && [ "$(num "$(val B log-window-ended)" 1)" = 0 ] && [ "$(num "$(val B many)" 0)" = 300 ]; check "control: with B's count off the feeds past the window are taken and the directory listed whole" $? "taken $(val B log-window-taken), window lines $(val B log-window-ended), $(val B many) of 300 entries"
fi
# The PFS root's proxy is at level 1 and a file's at 2, the media's own.
lr=$(val B lockdep-remote)
# Every inode lives under the PFS root, so an inode is at 1 (the root) or
# 2, a dirent at 2 or 3 and data at 3; any other class is a wrong level.
lbad=$(printf '%s\n' $lr | grep -v -x -E 'h2ch_remote_(inode/[12]|dirent/[23]|data/3)' | tr '\n' ' ')
case "$lr" in *h2ch_remote_inode/1*h2ch_remote_inode/2*) [ -z "$lbad" ];; *) false;; esac; check "remote: B classes its proxies apart, at their level on the peer" $? "${lr:-unread}${lbad:+; wrong level: $lbad}"
fi
for sd in A B; do
	# under the route control the connection device's refusal is a
	# warning by design, and the only one allowed
	kw=$(num "$(val $sd kernel-warnings)" 1)
	[ "$ROGATE" = control ] && [ "$sd" = B ] && kw=$((kw - $(num "$(val B conn-warnings)" 0)))
	[ "$kw" = 0 ] && [ "$(num "$(val $sd lockdep-saturated)" 1)" = 0 ] && [ "$(num "$(val $sd klog-alive)" 0)" = 1 ]; check "$sd: no kernel warning, lockdep or sanitizer report" $? "$(val $sd kernel-warnings) of which the connection device's refusals $(val $sd conn-warnings), lockdep table full $(val $sd lockdep-saturated), log stream alive $(val $sd klog-alive)"
	case "$CUT$sd" in masterA|slaveB) cw=2;; *) cw=1;; esac	# a power-cut guest loads twice, once per boot
	c=$(grep "^$sd " "$W/out" | grep -o kmemleak-cleared | wc -l); k=$(val $sd kmemleak); m=$(nval $sd kmemleak)	# counted by occurrence, so a second marker glued to a line or beside the first on one line is a second clear
	u=$(val $sd kmemleak-unloaded); n=$(nval $sd kmemleak-unloaded); r=$(nval $sd kmemleak-unloaded-range)
	[ "$c" = "$cw" ] && [ "$k" = 0 ] && [ "$m" = 1 ] && [ "$n" = 1 ] && [ "$r" = 1 ] && [ "${u:-1}" = 0 ]; check "$sd: kmemleak finds nothing of hammer2's" $? "cleared $c time(s), $k printed $m time(s), after the unload ${u:-unread}, printed $n time(s) after $r range line(s)"
	[ "$(val $sd rmmod)" = ok ] && [ "$(num "$(val $sd threads-final)" 9)" = 0 ]; check "$sd: the module unloads with no message thread" $? "rmmod $(val $sd rmmod), threads $(val $sd threads-final)"
done
relay_frames=$(sed -n 's/.*pair done frames \([0-9]*\).*/\1/p' "$W/relay.out" | tail -1)
[ "$(num "$relay_frames" 0)" -ge 8 ]; check "relay: the trace holds the exchange, every frame a decision line" $? "$relay_frames frames, trace wire-run-$stamp.trace"

echo "wire: $checks check(s), $fail failed"
[ "$fail" = 0 ] || exit 1
[ -z "$VOID" ] || { echo "wire: VOID: $VOID" >&2; exit 2; }
