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
# H2_WIRE_END=aborted, noeof or lost is the control on how B reads the end
# of a reply. B lists an empty directory of A's before anything else is listed,
# and the relay rewrites the closing frames of the two getdents calls that
# listing makes, since the first has emitted . and .. and so hides its
# error: aborted sets their error to ABORTED, the code a server ends a
# request with while its unmount drains it, and noeof clears their error
# and EOF flag, a close with no end fed, and lost sets the closing frame's
# byte count, a closing feed carrying a chain. Neither is an answer about the
# directory, so the listing must fail not connected and B's readdir end
# ENOTCONN. Taken as an answer, aborted fails the listing with ABORTED's
# own EINTR and noeof leaves the element counted in progress, EINPROGRESS.
# Lost is answered one level up: the kernel ends the whole link at the
# first such close, so the run rewrites one close and reads nothing after.
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
case $END in ''|aborted|noeof|lost) ;; *) echo "wire: COULD-NOT-RUN: H2_WIRE_END is aborted, noeof or lost" >&2; exit 2;; esac
case $STALL in ''|*[!0-9]*) echo "wire: COULD-NOT-RUN: H2_WIRE_STALL is milliseconds" >&2; exit 2;; esac
[ "$STALL" = 0 ] || [ "$STALL" -gt 2000 ] || { echo "wire: COULD-NOT-RUN: H2_WIRE_STALL must exceed B's 2000 ms bound" >&2; exit 2; }
nctl=0
for c in "$REKEY" "$DIRENT" "$REFUSE"; do [ "$c" = 1 ] && nctl=$((nctl + 1)); done
[ "$STALL" = 0 ] || nctl=$((nctl + 1))
[ -z "$END" ] || nctl=$((nctl + 1))
[ "$nctl" -le 1 ] || { echo "wire: COULD-NOT-RUN: one control per run" >&2; exit 2; }
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2")}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
RUN="timeout ${H2_RUN_TIMEOUT:-300} $SSH"
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
		timeout 45 $SSH "$2" 'umount -f /mnt/h2c 2>/dev/null; umount -f /mnt/h2r 2>/dev/null; rmmod hammer2 2>/dev/null; true' >/dev/null 2>&1
	fi
	$VIRSH detach-disk "$1" vdb --live >/dev/null 2>&1
	$VIRSH detach-disk "$1" vdb --config >/dev/null 2>&1
}

make -s clean >/dev/null 2>&1
make -s KDIR="$KDIR" >/dev/null 2>&1 || { echo "wire: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko
# What was built, taken now: the tree can move before the report is written.
SRC_REV=$(git describe --always --dirty); KO_SUM=$(sha256sum < "$KO" | cut -d' ' -f1)
RELAY_SUM=$(sha256sum < test/h2loop.c | cut -d' ' -f1); WIRE_SUM=$(sha256sum < script/cluster-wire.sh | cut -d' ' -f1)
cc -static -O2 -Isrc/sys/fs/hammer2 -o "$W/h2service" test/h2service.c 2>"$W/cc.err" || {
	echo "wire: COULD-NOT-RUN: test/h2service.c did not build:" >&2; sed 's/^/        /' "$W/cc.err" >&2; exit 2; }
cc -std=c11 -O1 -o "$W/h2loop" test/h2loop.c 2>"$W/cc.err" || {
	echo "wire: COULD-NOT-RUN: test/h2loop.c did not build:" >&2; sed 's/^/        /' "$W/cc.err" >&2; exit 2; }

guest_off "$GA" "$SA"
guest_off "$GB" "$SB"
for g in a b; do
	img=$FIXDIR/wire-$g.img
	rm -f "$img"
	truncate -s 2G "$img" && "$NEWFS" -L ROOT "$img" >/dev/null 2>&1 || {
		echo "wire: COULD-NOT-RUN: newfs_hammer2 failed on $img" >&2; exit 2; }
done
attach() {	# attach <domain> <image>
	state=$($VIRSH domstate "$1" 2>/dev/null)
	if [ "$state" = running ]; then how=--live; else how=--config; fi
	err=$($VIRSH attach-disk "$1" "$2" vdb --targetbus virtio $how 2>&1) || {
		echo "wire: COULD-NOT-RUN: could not attach $2 to $1: $err" >&2; exit 2; }
	if [ "$state" != running ]; then
		$VIRSH start "$1" >/dev/null 2>&1 || { echo "wire: COULD-NOT-RUN: $1 did not start" >&2; exit 2; }
	fi
}
attach "$GA" "$FIXDIR/wire-a.img"
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
ko_rel=$(modinfo -F vermagic "$KO" 2>/dev/null | cut -d' ' -f1)
for pair in "$GA:$SA" "$GB:$SB"; do
	g=${pair%%:*}; s=${pair#*:}
	rel=$($SSH "$s" uname -r 2>/dev/null)
	[ "$rel" = "$ko_rel" ] || {
		echo "wire: COULD-NOT-RUN: the module is built for $ko_rel and $g runs $rel; point KDIR at the guests' kernel" >&2; exit 2; }
	$SSH "$s" 'command -v hammer2 >/dev/null 2>&1' || { echo "wire: COULD-NOT-RUN: no hammer2 utility on $g" >&2; exit 2; }
	# One lockdep report turns lockdep off until the next boot, and a run
	# on that boot reads "no report" with nothing checking.
	dl=$($SSH "$s" "awk '/debug_locks:/ {print \$2}' /proc/lockdep_stats 2>/dev/null")
	[ "$dl" = 0 ] && {
		echo "wire: COULD-NOT-RUN: lockdep is off on $g since an earlier report; boot it again" >&2; exit 2; }
	scp -q "$KO" "$s:/tmp/hammer2.ko" && scp -q "$W/h2service" "$s:/tmp/h2service" || {
		echo "wire: COULD-NOT-RUN: copy to $g failed" >&2; exit 2; }
done

stamp=$(date +%Y%m%d-%H%M%S)
"$W/h2loop" --relay "$PORT" --seed "$SEED" \
    ${H2_WIRE_DELAY:+--delay-max "$H2_WIRE_DELAY"} ${H2_WIRE_LOSS:+--loss "$H2_WIRE_LOSS"} \
    ${H2_WIRE_DUP:+--dup "$H2_WIRE_DUP"} --rekey-data "$REKEY" --bare-dirent "$DIRENT" \
    --refuse-nresolve "$REFUSE" --stall-ms "$STALL" \
    --end-readdir "$(case $END in aborted) echo 1;; noeof) echo 2;; lost) echo 3;; *) echo 0;; esac)" \
    --trace "$FIXDIR/wire-run-$stamp.trace" > "$W/relay.out" 2>&1 &
RELAY_PID=$!
sleep 0.5
grep -q "relay listening" "$W/relay.out" || { echo "wire: COULD-NOT-RUN: the relay did not listen on $PORT" >&2; cat "$W/relay.out" >&2; exit 2; }

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
cat > "$W/setup.sh" <<'GUEST'
# setup <type> [<clid>]: load, mount ROOT, create CL, print its id
if lsmod 2>/dev/null | grep -q '^hammer2' || mount 2>/dev/null | grep -q ' type hammer2'; then
	echo "wire: COULD-NOT-RUN: the guest still has hammer2 loaded or mounted" >&2; exit 2
fi
dmesg -C
pkill -f 'dmesg -w' 2>/dev/null
setsid -f sh -c 'exec dmesg -w > /tmp/h2wire.klog 2>&1'
{ echo scan > /sys/kernel/debug/kmemleak && echo scan > /sys/kernel/debug/kmemleak && echo clear > /sys/kernel/debug/kmemleak; } 2>/dev/null	# an earlier run's leaks are its own
insmod /tmp/hammer2.ko || { echo "insmod failed"; exit 1; }
echo 256 > /sys/module/hammer2/parameters/debug 2>/dev/null
mkdir -p $R $C /tmp/h2keys
mount -t hammer2 /dev/vdb@ROOT $R || { echo "mount failed"; exit 1; }
if [ "$1" = master ]; then
	hammer2 -s $R pfs-create CL >/dev/null 2>&1 || { echo "pfs-create failed"; exit 1; }
else
	hammer2 -s $R -t SLAVE -u "$2" pfs-create CL >/dev/null 2>&1 || { echo "slave pfs-create failed"; exit 1; }
fi
echo "clid $(hammer2 -s $R pfs-clid CL 2>/dev/null)"
echo "pfs-count $(hammer2 -s $R pfs-list 2>/dev/null | awk 'NR>1' | grep -c .)"
# which utility reads the media: the C show and the Rust one stop short differently
echo "utility $(command -v hammer2) $(hammer2 --version 2>&1 | head -1)"
GUEST
cat > "$W/dial.sh" <<'GUEST'
# dial <clid> <host> <port> [ro]: one admitted row, then the dial; with ro
# the device is opened again read-only between the two, so the slave's pass
# refuses to run and every read on B's CL is the remote element's alone
touch /tmp/h2keys/peer.none
/tmp/h2service add $R --clid "$1" --label peer --path "span:$2:$3" | sed 's/^/add /'
if [ "${4:-}" = ro ]; then
	umount $R && mount -t hammer2 -o ro /dev/vdb@ROOT $R || { echo "ROOT read-only failed"; exit 1; }
	echo "root-ro 1"
fi
/tmp/h2service dial $R --keys /tmp/h2keys | sed 's/^/dial /'
echo "dial-rc $?"
GUEST
cat > "$W/fill.sh" <<'GUEST'
# fill: A's MASTER CL mounted read-write and given a known tree
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
cat > "$W/read.sh" <<'GUEST'
# read [<stall ms> [<end mode>]]: B reads A's files through the element
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
# the end control's listing, the run's first
if [ -n "${2:-}" ]; then
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
sed 's/^/frag /' /tmp/h2wire.frag
(cd $C && find . -type f | sort | xargs sha256sum) 2>&1 | sed 's/^\([0-9a-f]*\)  \(.*\)/sum \2 \1/'
mount -o remount,rw $C 2>/dev/null; echo "remount-rc $?"
echo "log-remount-refused $(klog1 'read-write remount refused: a remote element')"
echo 3 > /proc/sys/vm/drop_caches
(cd $C && find . -type f | sort | xargs sha256sum) 2>&1 | sed 's/^\([0-9a-f]*\)  \(.*\)/cold \2 \1/'
echo "remote-xops $(klog 'H2 REMOTE ')"
echo "pass-refused $(klog 'sync pass refused on clindex')"
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
echo "log-peer-sent $(klog 'HM2 peer sent')"
echo "log-nresolve-notconn $(klog 'H2 REMOTE nresolve .* end=00080000')"
echo "log-readdir-timedout $(klog 'H2 REMOTE readdir .* end=00040000')"
echo "readdir-timedout-ms $(kl | sed -n 's/.*H2 REMOTE readdir .* end=00040000 ms=\([0-9]*\).*/\1/p' | sort -n | head -1)"
echo "log-readdir-notconn $(klog 'H2 REMOTE readdir .* end=00080000')"
echo "log-bmap-notconn $(klog 'H2 REMOTE bmap .* end=00080000')"
GUEST
cat > "$W/link.sh" <<'GUEST'
# link <peer clid> <peer type>: what the log and the table say of the peer
echo "log-proto2 $(klog 'peer speaks DMSG_SPAN_PROTO_2')"
echo "log-conn-terminated $(klog 'CONN WAS TERMINATED')"
echo "spans-rx $(klog 'H2 +RXSPAN')"
echo "span-cl $(kl | grep 'H2 +RXSPAN' | grep -c "cl=$1 .*type=$2")"
echo "spantab $(kl | grep '^\[.*H2 SPANTAB' | tail -1 | sed 's/.*SPANTAB //')"
echo "threads $(threads)"
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
echo "log-detached $(klog 'remote element CL at clindex 1 detached')"
echo "detached-why $(kl | grep 'remote element CL at clindex 1 detached' | sed 's/.*detached: //' | tr '\n' ' ')"
echo "spans-del $(klog 'H2 -RXSPAN')"
echo "spantab-end $(kl | grep '^\[.*H2 SPANTAB' | tail -1 | sed 's/.*SPANTAB //')"
# A proxy is classed apart from the media's chains, at its level on the
# peer; on level 0, the super-root's class, a contended inode lock in the
# sync pass read as a cycle through the mount's order. The classes are
# listed until the unload, and a kernel without lockdep has no file.
if [ -r /proc/lockdep ]; then
	echo "lockdep-remote $(grep -o 'h2ch_remote_[a-z]*/[0-9]*' /proc/lockdep | sort -u | tr '\n' ' ')"
else
	echo "lockdep-remote no-lockdep"
fi
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
# A lockdep table that fills turns lockdep off and says BUG; that is the
# guest kernel's table size (the KASAN build keeps the default, 2^15), not
# a report on the subject, so it is counted apart and named in the check,
# which it still fails: lockdep checks nothing for the rest of that run.
echo "kernel-warnings $(kl | grep -v 'MAX_LOCKDEP_ENTRIES too low' | grep -c -E 'WARNING|BUG:|UBSAN:|KASAN|circular locking|possible recursive|enqueued on deprecated workqueue')"
echo "lockdep-saturated $(klog 'MAX_LOCKDEP_ENTRIES too low')"
echo "threads-final $(threads)"
pkill -f 'dmesg -w' 2>/dev/null
GUEST
for s in "$SA" "$SB"; do
	scp -q "$W/common.sh" "$W/setup.sh" "$W/fill.sh" "$W/lone.sh" "$W/reg.sh" "$W/ro.sh" "$W/read.sh" "$W/dial.sh" "$W/link.sh" "$W/down.sh" "$s:/tmp/" || {
		echo "wire: COULD-NOT-RUN: copy to $s failed" >&2; exit 2; }
done
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
: > "$W/out"
phase A setup.sh master || { guest_off "$GA" "$SA"; guest_off "$GB" "$SB"; exit 2; }
clid=$(val A clid)
[ -n "$clid" ] || { echo "wire: COULD-NOT-RUN: A's CL has no cluster id" >&2; guest_off "$GA" "$SA"; guest_off "$GB" "$SB"; exit 2; }
phase B setup.sh slave "$clid" || { guest_off "$GA" "$SA"; guest_off "$GB" "$SB"; exit 2; }
phase A fill.sh
phase B lone.sh
phase A dial.sh "$clid" "$HOST_ADDR" "$PORT"
phase B dial.sh "$clid" "$HOST_ADDR" "$PORT" ro
sleep 3
phase A link.sh "$clid" 3	# A sees B's SLAVE CL
phase B link.sh "$clid" 6	# B sees A's MASTER CL
phase B reg.sh
phase B ro.sh && phase B read.sh "$STALL" "$END"
phase B down.sh
sleep 2
phase A link.sh "$clid" 3	# after B's unmount: its spans deleted
phase A down.sh
kill "$RELAY_PID" 2>/dev/null; wait "$RELAY_PID" 2>/dev/null; RELAY_PID=
scp -q "$SA:/tmp/h2wire.klog" "$FIXDIR/wire-run-$stamp-a.klog" 2>/dev/null
scp -q "$SB:/tmp/h2wire.klog" "$FIXDIR/wire-run-$stamp-b.klog" 2>/dev/null
{ echo "source $SRC_REV"; echo "relay-sha256 $RELAY_SUM"; echo "harness-sha256 $WIRE_SUM"; echo "module-sha256 $KO_SUM"; echo "guest-kernel $ko_rel"; echo "module-vermagic $(modinfo -F vermagic "$KO" 2>/dev/null)"; cat "$W/out"; cat "$W/relay.out"; } > "$FIXDIR/wire-run-$stamp.out" 2>/dev/null
echo "  kept  both kernel logs and the relay trace beside the images as wire-run-$stamp-{a,b}.klog and .trace"
guest_off "$GA" "$SA"
guest_off "$GB" "$SB"

fail=0; checks=0
check() {	# check <name> <0 ok / 1 fail> <reading>
	checks=$((checks + 1))
	if [ "$2" = 0 ]; then echo "  ok    $1: $3"; else echo "  FAIL  $1: $3"; fail=$((fail + 1)); fi
}
num() { case "$1" in ''|*[!0-9-]*) echo "$2";; *) echo "$1";; esac; }
# A's link.sh ran twice; the first reading is the paired one, the second
# the one after B's unmount, so the second's values are read from the tail.
val2() { sed -n "s/^$1 $2 //p" "$W/out" | tail -1; }

echo "hammer2 cluster transport on the wire, $GA and $GB ($ko_rel), relay seed $SEED, source $SRC_REV, module sha256 $(printf %.16s "$KO_SUM"):"
npa=$(num "$(val A pfs-count)" 0); npb=$(num "$(val B pfs-count)" 0)
[ "$npa" -ge 3 ] && [ "$npb" -ge 3 ]; check "each volume has ROOT, LOCAL and CL" $? "A $npa, B $npb"
[ "$(num "$(val A dial-rc)" 1)" = 0 ] && [ "$(num "$(val B dial-rc)" 1)" = 0 ]; check "link: both dials hand a connected TCP socket in" $? "A rc $(val A dial-rc), B rc $(val B dial-rc)"
[ "$(num "$(val A log-proto2)" 0)" = 1 ] && [ "$(num "$(val B log-proto2)" 0)" = 1 ]; check "link: each kernel reads the peer's PROTO_2 announcement once" $? "A $(val A log-proto2), B $(val B log-proto2)"
[ "$(num "$(val A spantab)" 0)" = "$npb" ]; check "link: A's span table holds one span per PFS of B, counted against B's pfs-list" $? "$(val A spantab) spans, $npb PFSs"
[ "$(num "$(val B spantab)" 0)" = "$npa" ]; check "link: B's span table holds one span per PFS of A" $? "$(val B spantab) spans, $npa PFSs"
[ "$(num "$(val A span-cl)" 0)" = 1 ] && [ "$(num "$(val B span-cl)" 0)" = 1 ]; check "link: each sees the other's CL span by the shared cluster id and the peer's type" $? "A sees SLAVE $(val A span-cl), B sees MASTER $(val B span-cl)"
[ "$(num "$(val A log-conn-terminated)" 1)" = 0 ] && [ "$(num "$(val B log-conn-terminated)" 1)" = 0 ]; check "link: the connection outlives the VOLCONF frames" $? "terminated A $(val A log-conn-terminated), B $(val B log-conn-terminated)"
[ "$(num "$(val A threads)" 0)" = 2 ] && [ "$(num "$(val B threads)" 0)" = 2 ]; check "link: one pair of message threads on each guest" $? "A $(val A threads), B $(val B threads)"
[ "$(num "$(val2 A spantab)" 9)" = 0 ] && [ "$(num "$(val B spans-del)" 0)" = "$npb" ]; check "unmount: B's unmount deletes its spans and A's table empties" $? "A's table $(val2 A spantab) after, B sent $(val B spans-del)"
# The read side: B's empty SLAVE answers nothing, so every file B reads
# came through the remote element; the digests are A's own, taken on A.
sums() { sed -n "s/^$1 $2 //p" "$W/out" | sort; }
nfa=$(num "$(val A files)" 0)
[ "$(num "$(val B lone-mount-rc)" 0)" != 0 ]; check "remote: B's SLAVE CL alone does not mount, having no master" $? "rc $(val B lone-mount-rc)"
[ "$(num "$(val B log-registered)" 0)" = 1 ] && [ "$(num "$(val B log-nmasters)" 0)" = 1 ]; check "remote: B registers A's CL root as clindex 1, one master" $? "registered $(val B log-registered), pfs_nmasters $(val B log-nmasters)"
# Lost ends the link at the first rewritten close, so every read after it
# finds nothing: the live-link checks below do not apply to that mode.
[ "$END" = lost ] || [ "$STALL" != 0 ] || { [ "$nfa" -ge 5 ] && [ "$(num "$(val B files)" 0)" = "$nfa" ]; check "remote: B lists A's files through the element" $? "A $nfa, B $(val B files)"; }
[ "$END" = lost ] || { [ "$(num "$(val A many)" 0)" = 300 ] && [ "$(num "$(val B many)" 0)" = 300 ]; check "remote: B lists a directory larger than one readdir XOP takes" $? "A $(val A many), B $(val B many) of 300"; }
[ "$(num "$(val B pass-refused)" 0)" -ge 1 ] && [ "$(num "$(val B slave-show-rc)" 1)" = 0 ] && [ "$(num "$(val B slave-cl)" 0)" -ge 1 ] && [ "$(num "$(val B slave-show-failed)" 1)" = 0 ] && [ "$(num "$(val B slave-files)" 1)" = 0 ] && [ "$(num "$(val A media-files)" 0)" -ge 300 ]; check "remote: B's pass refuses its read-only device and the slave copies nothing" $? "refusal lines $(val B pass-refused), slave files $(val B slave-files) by $(val B utility)'s show rc $(val B slave-show-rc) reaching CL's root $(val B slave-cl) with $(val B slave-show-failed) failed reads, the pattern matching $(val A media-files) on A's media"
# The file is on A alone, so no block has an address on B: every extent
# says so rather than reporting the 0 no local element supplied.
fx=$(num "$(val B fiemap-extents)" 0)
[ "$REKEY" = 1 ] || [ "$END" = lost ] || { [ "$(num "$(val B fiemap-rc)" 1)" = 0 ] && [ "$fx" -ge 1 ] && [ "$(num "$(val B fiemap-unknown)" 0)" = "$fx" ]; check "remote: fiemap of a 512 KiB file runs bmap over the wire and claims no address" $? "rc $(val B fiemap-rc), $fx extent(s), $(val B fiemap-unknown) unknown_loc"; }
if [ "$REKEY" = 1 ]; then
	rk=$(grep -c ' rekey ' "$FIXDIR/wire-run-$stamp.trace" 2>/dev/null)
	[ "$(num "$rk" 0)" = 1 ] && [ "$(num "$(val B log-not-proxy)" 0)" = 1 ] && [ "$(num "$(val B log-not-proxy-bmap)" 0)" = 1 ] && [ "$(num "$(val B fiemap-extents)" 1)" = 0 ] && [ "$(num "$(val B fiemap-unknown)" 1)" = 0 ] && [ -n "$(sums A sum)" ] && [ "$(sums A sum)" = "$(sums B sum)" ] && [ "$(sums A sum)" = "$(sums B cold)" ] && [ "$(num "$(val B log-peer-sent)" 1)" = 0 ] && [ "$(num "$(val B log-bmap-notconn)" 0)" -ge 1 ]; check "control: a data feed moved off its key passes the CRCs and B refuses it" $? "rekey lines $(num "$rk" 0), bmap ended ENOTCONN $(val B log-bmap-notconn), not-proxy $(val B log-not-proxy) of which bmap $(val B log-not-proxy-bmap), peer-sent $(val B log-peer-sent), fiemap $(val B fiemap-extents) extent(s) $(val B fiemap-unknown) unknown_loc, $(sums B sum | grep -c .) warm and $(sums B cold | grep -c .) cold of $(sums A sum | grep -c .) equal"
else
[ "$END" = lost ] || { [ -n "$(sums A sum)" ] && [ "$(sums A sum)" = "$(sums B sum)" ]; check "remote: every file's digest on B equals A's" $? "$(sums B sum | grep -c .) of $(sums A sum | grep -c .) equal by sha256"; }
[ "$END" = lost ] || { [ -n "$(sums A sum)" ] && [ "$(sums A sum)" = "$(sums B cold)" ]; check "remote: the same digests after B drops its caches" $? "$(sums B cold | grep -c .) read cold"; }
fi
[ "$END" = lost ] || { [ "$(num "$(val B remount-rc)" 0)" != 0 ] && [ "$(num "$(val B log-remount-refused)" 0)" -ge 1 ]; check "remote: a read-write remount is refused while the element is registered" $? "remount rc $(val B remount-rc), refusal lines $(val B log-remount-refused)"; }
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
		[ "$(num "$en" 0)" = 1 ] && [ "$(num "$(val B empty-ls-rc)" 0)" != 0 ] && [ "$(num "$(val B empty-ls-notconn)" 0)" = 1 ] && [ "$(num "$(val B log-readdir-notconn)" 0)" = 2 ] && [ "$(num "$(val B log-peer-sent)" 1)" -ge 1 ] && [ "$(num "$(val B files)" 0)" = 0 ] && [ "$(num "$(val B find-notconn)" 0)" -ge 1 ]; check "control: a closing feed with a chain ends the link, not as its answer" $? "end lines $(num "$en" 0), listing rc $(val B empty-ls-rc) \"$(val B empty-ls-err)\", not connected $(val B empty-ls-notconn), readdir ended ENOTCONN $(val B log-readdir-notconn), peer-sent $(val B log-peer-sent), B listed $(val B files) after with $(val B find-notconn) not connected"
	else
		[ "$(num "$en" 0)" = 2 ] && [ "$(num "$(val B empty-ls-rc)" 0)" != 0 ] && [ "$(num "$(val B empty-ls-notconn)" 0)" = 1 ] && [ "$(num "$(val B log-readdir-notconn)" 0)" = 2 ]; check "control: a reply closed $END reads the master unreachable, not as its answer" $? "end lines $(num "$en" 0), listing rc $(val B empty-ls-rc) \"$(val B empty-ls-err)\", not connected $(val B empty-ls-notconn), readdir ended ENOTCONN $(val B log-readdir-notconn)"
	fi
fi
if [ "$STALL" != 0 ]; then
	st=$(grep -c ' stall ' "$FIXDIR/wire-run-$stamp.trace" 2>/dev/null)
	[ "$(num "$st" 0)" = 1 ] && [ "$(num "$(val B remote-timeout-ms)" 0)" = 2000 ] && [ "$(num "$(val B find-notconn)" 0)" -ge 1 ] && [ "$(num "$(val B log-readdir-timedout)" 0)" -ge 1 ] && [ "$(num "$(val B readdir-timedout-ms)" 0)" -ge 2000 ]; check "control: a reply held past B's bound ends the call with the master unreachable" $? "stall lines $(num "$st" 0) for $STALL ms, bound $(val B remote-timeout-ms) ms, shortest timed-out readdir $(val B readdir-timedout-ms) ms, listing not connected $(val B find-notconn), readdir ended ETIMEDOUT $(val B log-readdir-timedout), B listed $(val B files) of $nfa"
fi
[ "$REKEY" = 1 ] || [ "$DIRENT" = 1 ] || [ "$END" = lost ] || { [ "$(num "$(val B log-not-proxy)" 1)" = 0 ] && [ "$(num "$(val B log-peer-sent)" 1)" = 0 ]; check "remote: no feed refused as a proxy, no protocol error" $? "not-proxy $(val B log-not-proxy), peer-sent $(val B log-peer-sent), $(val B remote-xops) remote XOPs, $(val B refetches) refetches"; }
[ "$END" = lost ] || { [ "$(num "$(val B rw-mount-rc)" 0)" != 0 ] && [ "$(num "$(val B log-mount-refused)" 0)" -ge 1 ]; check "remote: a read-write mount of B's CL is refused while the element is registered" $? "mount rc $(val B rw-mount-rc), refusal lines $(val B log-mount-refused)"; }
[ "$(num "$(val B log-detached)" 0)" = 1 ]; check "remote: B's device unmount detaches the element once" $? "$(val B log-detached), by $(val B detached-why)"
# The PFS root's proxy is at level 1 and a file's at 2, the media's own.
lr=$(val B lockdep-remote)
# Every inode lives under the PFS root, so an inode is at 1 (the root) or
# 2, a dirent at 2 or 3 and data at 3; any other class is a wrong level.
lbad=$(printf '%s\n' $lr | grep -v -x -E 'h2ch_remote_(inode/[12]|dirent/[23]|data/3)' | tr '\n' ' ')
case "$lr" in *h2ch_remote_inode/1*h2ch_remote_inode/2*) [ -z "$lbad" ];; *) false;; esac; check "remote: B classes its proxies apart, at their level on the peer" $? "${lr:-unread}${lbad:+; wrong level: $lbad}"
for sd in A B; do
	[ "$(num "$(val $sd kernel-warnings)" 1)" = 0 ] && [ "$(num "$(val $sd lockdep-saturated)" 1)" = 0 ] && [ "$(num "$(val $sd klog-alive)" 0)" = 1 ]; check "$sd: no kernel warning, lockdep or sanitizer report" $? "$(val $sd kernel-warnings), lockdep table full $(val $sd lockdep-saturated), log stream alive $(val $sd klog-alive)"
	k=$(val $sd kmemleak)
	u=$(val $sd kmemleak-unloaded)
	[ "$k" = 0 ] && [ "${u:-1}" = 0 ]; check "$sd: kmemleak finds nothing of hammer2's" $? "$k, after the unload ${u:-unread}"
	[ "$(val $sd rmmod)" = ok ] && [ "$(num "$(val $sd threads-final)" 9)" = 0 ]; check "$sd: the module unloads with no message thread" $? "rmmod $(val $sd rmmod), threads $(val $sd threads-final)"
done
relay_frames=$(sed -n 's/.*pair done frames \([0-9]*\).*/\1/p' "$W/relay.out" | tail -1)
[ "$(num "$relay_frames" 0)" -ge 8 ]; check "relay: the trace holds the exchange, every frame a decision line" $? "$relay_frames frames, trace wire-run-$stamp.trace"

echo "wire: $checks check(s), $fail failed"
[ "$fail" = 0 ]
