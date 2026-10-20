#!/bin/sh
# The cluster message core, run with the kernel in the loop. One volume
# goes on the Linux guest with two PFSs under its super-root, and
# test/h2attach.c, built here and copied over, plays the daemon's end of
# a socketpair handed in through HAMMER2IOC_RECLUSTER, one scripted action
# per run. The work queue's five exit criteria for P6 are each read as
# numbers the guest prints:
#
#   loopback_message_tests   the kernel initiates LNK_CONN on attach; its
#                            LNK_SPAN count equals the PFS count the
#                            hammer2 utility reads on the same mount; a
#                            DBG_SHELL draws DMSG_ERR_NOSUPP
#   malformed_message_tests  a bad magic, a zero header size and an aux
#                            over 1 MiB each end the connection: the
#                            daemon reads EOF and the kernel log names the
#                            reason, and the next attach connects again
#   cancellation             the daemon closes the kernel's CONN and one
#                            SPAN and each is answered; the same CONN
#                            DELETE sent again is not, and the log says
#                            why
#   reconnect                a second attach while connected: a new CONN
#                            on the new pair, EOF on the old, and one pair
#                            of message threads afterwards, not two
#   socket_faults            a half-close and a hard close each leave no
#                            thread behind; and the unmount with the daemon
#                            holding its end open and silent completes,
#                            because the kernel's uninit path shuts its own
#                            socket down after ten retries, which the log
#                            records and the unmount time shows
#
# What a fake pass looks like, and what rules it out: a daemon that never
# sees a frame passes any check that reads only "no error", so every count
# here is a number and the span count is compared with a reading taken by
# another program. A kernel that ignored a malformed frame would deliver
# no EOF, and a reader that died without shutting the socket would leave
# the daemon blocked, which the two-second bound turns into a failure.
# Threads leaked by a reconnect would show as two pairs by name. The
# unmount-while-held reading has a control: the daemon closing first must
# make the unmount fast and the shutdown line absent, so the slow case
# proves the retry branch and not the daemon.
#
# The pipe refusal is the port's own decision and is read too: a pipe end
# and an unconnected stream socket handed to RECLUSTER must each be EINVAL.
#
# Exit 2 is COULD-NOT-RUN. Needs the guest fleet, a kernel tree at KDIR
# matching the guest's kernel, newfs_hammer2 and hammer2 on this host,
# and hammer2 on the guest.
set -u
cd "$(dirname "$0")/.." || exit 2

FIXDIR=${H2_FIXTURE_DIR:-$HOME/Projects/linux_hammer2-data/fixtures}
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2")}
RUN="timeout ${H2_RUN_TIMEOUT:-600} ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
IMG=$FIXDIR/cluster-dmsg.img
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

command -v virsh >/dev/null 2>&1 || { echo "dmsg: COULD-NOT-RUN: no virsh" >&2; exit 2; }
[ -x "$NEWFS" ] || { echo "dmsg: COULD-NOT-RUN: no newfs_hammer2 (H2_NEWFS)" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "dmsg: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -d "$KDIR" ] || { echo "dmsg: COULD-NOT-RUN: no kernel tree at $KDIR" >&2; exit 2; }
state=$($VIRSH domstate "$GUEST" 2>/dev/null) || { echo "dmsg: COULD-NOT-RUN: no guest $GUEST" >&2; exit 2; }

detach_disk() {
	if [ "$($VIRSH domstate "$GUEST" 2>/dev/null)" = running ]; then
		timeout 45 ssh -o ConnectTimeout=5 -o BatchMode=yes "$GUEST_SSH" \
		    'umount -f /mnt/h2d 2>/dev/null; rmmod hammer2 2>/dev/null; true' >/dev/null 2>&1
	fi
	$VIRSH detach-disk "$GUEST" vdb --live >/dev/null 2>&1
	$VIRSH detach-disk "$GUEST" vdb --config >/dev/null 2>&1
}

make -s clean >/dev/null 2>&1
# H2_CRC_CONTROL=1 builds the module with its PROTO_2 CRC check compiled out,
# the negative control: the bad frame must then be accepted, and every
# other check must still hold.  Never install that module.
make -s KDIR="$KDIR" ${H2_CRC_CONTROL:+HAMMER2_NOCRC=1} >/dev/null 2>&1 || { echo "dmsg: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko
cc -static -O2 -Isrc/sys/fs/hammer2 -o "$W/h2attach" test/h2attach.c 2>"$W/cc.err" || {
	echo "dmsg: COULD-NOT-RUN: test/h2attach.c did not build:" >&2; sed 's/^/        /' "$W/cc.err" >&2; exit 2; }

detach_disk
rm -f "$IMG"
truncate -s 1G "$IMG" && "$NEWFS" -L ROOT "$IMG" >/dev/null 2>&1 || {
	echo "dmsg: COULD-NOT-RUN: newfs_hammer2 failed on $IMG" >&2; exit 2; }
if [ "$state" = running ]; then how=--live; else how=--config; fi
err=$($VIRSH attach-disk "$GUEST" "$IMG" vdb --targetbus virtio $how 2>&1) || {
	echo "dmsg: COULD-NOT-RUN: could not attach the volume: $err" >&2; exit 2; }
if [ "$state" != running ]; then
	$VIRSH start "$GUEST" >/dev/null 2>&1 || { echo "dmsg: COULD-NOT-RUN: $GUEST did not start" >&2; exit 2; }
fi
n=0
until ssh -o ConnectTimeout=3 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null; do
	sleep 5; n=$((n + 1))
	[ $n -gt 60 ] && { echo "dmsg: COULD-NOT-RUN: $GUEST did not answer ssh in 5 minutes" >&2; exit 2; }
done
guest_rel=$(ssh -o BatchMode=yes "$GUEST_SSH" uname -r 2>/dev/null)
ko_rel=$(modinfo -F vermagic "$KO" 2>/dev/null | cut -d' ' -f1)
[ "$guest_rel" = "$ko_rel" ] || {
	echo "dmsg: COULD-NOT-RUN: the module is built for $ko_rel and $GUEST runs $guest_rel; point KDIR at the guest's kernel" >&2; exit 2; }

cat > "$W/guest.sh" <<'GUEST'
set -u
command -v hammer2 >/dev/null 2>&1 || { echo "dmsg: COULD-NOT-RUN: no hammer2 utility on the guest" >&2; exit 2; }
if lsmod 2>/dev/null | grep -q '^hammer2' || mount 2>/dev/null | grep -q ' type hammer2'; then
	echo "dmsg: COULD-NOT-RUN: the guest still has hammer2 loaded or mounted" >&2; exit 2
fi
dmesg -C
K=/tmp/h2dmsg.klog
pkill -x dmesg 2>/dev/null; sleep 0.2
dmesg -w > $K 2>&1 &
KPID=$!
trap 'kill $KPID 2>/dev/null' EXIT
klog() { grep -c "$1" $K; }
threads() { ps -eo comm | grep -c '^hammer2-msg'; }
A=/tmp/h2attach
M=/mnt/h2d
insmod /tmp/hammer2.ko || { echo "insmod failed"; exit 1; }
echo 256 > /sys/module/hammer2/parameters/debug 2>/dev/null
echo "debug $(cat /sys/module/hammer2/parameters/debug 2>/dev/null)"
mkdir -p $M
mount -t hammer2 /dev/vdb@ROOT $M || { echo "mount failed"; exit 1; }
hammer2 -s $M pfs-create SP >/dev/null 2>&1
echo "pfs-count $(hammer2 -s $M pfs-list 2>/dev/null | awk 'NR>1' | grep -c .)"
echo "threads-before $(threads)"

# the refusal, then each action; a second after each for the threads to go
out=$($A --attach $M --action refuse 2>&1); echo "refuse-rc $?"; echo "refuse $out"
for act in conn cancel badmagic badsize badaux halfclose close reconnect proto2 badcrc badcrc1 spanlist; do
	out=$($A --attach $M --action $act --trace /tmp/h2attach-$act.trace 2>&1); rc=$?
	echo "$act-rc $rc"; echo "$act $out"
	sleep 1
	echo "$act-threads $(threads)"
done
echo "log-badmagic $(klog 'bad magic')"
echo "log-badsize $(klog 'bad header size')"
echo "log-badaux $(klog 'illegal msg payload size')"
echo "log-badcrc $(klog 'bad crc')"
echo "log-proto2 $(klog 'peer speaks DMSG_SPAN_PROTO_2')"
echo "log-spantab3 $(klog 'H2 SPANTAB 3')"
echo "log-spantab0 $(klog 'H2 SPANTAB 0')"
echo "log-nostate $(klog 'no state match for REPLY|DELETE')"
echo "log-shitcan-before $(klog shitcanning)"

# the held connection: the daemon neither reads nor writes while the
# volume is unmounted under it
$A --attach $M --action hold --hold-max-ms 40000 > /tmp/hold.out 2>&1 &
HPID=$!
n=0; until grep -q holding /tmp/hold.out 2>/dev/null; do sleep 0.2; n=$((n+1)); [ $n -gt 50 ] && break; done
echo "hold-threads-before $(threads)"
t0=$(date +%s%N); timeout 60 umount $M; urc=$?; t1=$(date +%s%N)
echo "hold-umount-rc $urc"
echo "hold-umount-ms $(( (t1 - t0) / 1000000 ))"
wait $HPID; echo "hold-rc $?"
echo "hold $(grep 'eof=' /tmp/hold.out | head -1)"
echo "hold-threads-after $(threads)"
echo "log-shitcan-after $(klog shitcanning)"

# the control: the daemon closes first, and the unmount has nothing to wait for
mount -t hammer2 /dev/vdb@ROOT $M || { echo "remount failed"; exit 1; }
out=$($A --attach $M --action close 2>&1); echo "ctl-close-rc $?"; echo "ctl-close $out"
sleep 1
t0=$(date +%s%N); timeout 60 umount $M; urc=$?; t1=$(date +%s%N)
echo "ctl-umount-rc $urc"
echo "ctl-umount-ms $(( (t1 - t0) / 1000000 ))"
echo "ctl-threads-after $(threads)"
echo "log-shitcan-final $(klog shitcanning)"

echo "kernel-warnings $(grep -c -E 'WARNING|BUG:|UBSAN:|KASAN|circular locking|possible recursive' $K)"
# Before rmmod, so the report's %pS resolves the module's own symbols, and
# after the wait the scanner's age rule needs (kmemleak.c MSECS_MIN_AGE,
# 5000 ms), as cluster-sync.sh does. The message core allocates a state and
# a message per frame and frees them from two threads that exit on their
# own, which is where a leak would sit.
sleep 6
if echo scan > /sys/kernel/debug/kmemleak 2>/dev/null; then
	echo "kmemleak $(grep -c hammer2 /sys/kernel/debug/kmemleak)"
else
	echo "kmemleak unusable"
fi
timeout 120 rmmod hammer2 && echo "rmmod ok"
echo "threads-final $(threads)"
kill $KPID 2>/dev/null
GUEST

scp -q "$KO" "$GUEST_SSH:/tmp/hammer2.ko" && scp -q "$W/h2attach" "$GUEST_SSH:/tmp/h2attach" && scp -q "$W/guest.sh" "$GUEST_SSH:/tmp/h2dmsg.sh" || {
	echo "dmsg: COULD-NOT-RUN: copy to $GUEST failed" >&2; exit 2; }
$RUN "$GUEST_SSH" "sh /tmp/h2dmsg.sh" > "$W/out" 2>&1
rc=$?
if [ "$rc" = 2 ] || command grep -q "COULD-NOT-RUN" "$W/out" 2>/dev/null; then
	command grep -m1 "COULD-NOT-RUN" "$W/out" >&2 || echo "dmsg: COULD-NOT-RUN: the guest half exited 2 without a reason" >&2
	detach_disk; exit 2
fi
stamp=$(date +%Y%m%d-%H%M%S)
scp -q "$GUEST_SSH:/tmp/h2dmsg.klog" "$FIXDIR/dmsg-run-$stamp.klog" 2>/dev/null && echo "  kept  the guest kernel log beside the images as dmsg-run-$stamp.klog"
{ echo "guest-kernel $guest_rel"; echo "module-vermagic $(modinfo -F vermagic "$KO" 2>/dev/null)"; cat "$W/out"; } > "$FIXDIR/dmsg-run-$stamp.out" 2>/dev/null
if [ "$rc" != 0 ]; then
	sed 's/^/  guest: /' "$W/out" >&2
	detach_disk
	echo "dmsg: COULD-NOT-RUN: the guest session ended rc=$rc, so the run did not finish" >&2
	exit 2
fi
detach_disk

val() { sed -n "s/^$1 //p" "$W/out" | head -1; }
field() { printf '%s\n' "$1" | sed -n "s/.*[ :]$2=\([-0-9]*\).*/\1/p" | head -1; }
fail=0; checks=0
check() {	# check <name> <0 ok / 1 fail> <reading>
	checks=$((checks + 1))
	if [ "$2" = 0 ]; then echo "  ok    $1: $3"; else echo "  FAIL  $1: $3"; fail=$((fail + 1)); fi
}
num() { case "$1" in ''|*[!0-9-]*) echo "$2";; *) echo "$1";; esac; }

echo "hammer2 message core on $GUEST ($guest_rel):"
npfs=$(num "$(val pfs-count)" 0)
[ "$npfs" -ge 2 ]; check "the volume has two PFSs for the span count" $? "$npfs"

r=$(val refuse); pe=$(num "$(field "$r" pipe_errno)" -1); se=$(num "$(field "$r" sock_errno)" -1)
[ "$pe" = 22 ] && [ "$se" = 22 ]; check "a pipe and an unconnected socket are refused EINVAL" $? "pipe errno $pe, socket errno $se"

c=$(val conn)
[ "$(num "$(field "$c" conn)" 0)" = 1 ]; check "loopback: the kernel initiates LNK_CONN on attach" $? "$(field "$c" conn)"
sp=$(num "$(field "$c" spans)" -1)
[ "$sp" = "$npfs" ]; check "loopback: one LNK_SPAN per PFS, counted against pfs-list" $? "$sp spans, $npfs PFSs"
[ "$(num "$(field "$c" shell_reply)" 0)" = 1 ] && [ "$(num "$(field "$c" shell_error)" 0)" = 32 ]; check "loopback: DBG_SHELL is answered DMSG_ERR_NOSUPP" $? "reply $(field "$c" shell_reply), error $(field "$c" shell_error) (0x20 is 32)"
[ "$(num "$(field "$c" ping_replies)" 1)" = 0 ]; check "loopback: a one-off PING draws no reply, as upstream's core ignores one" $? "$(field "$c" ping_replies) frames"
[ "$(num "$(val conn-threads)" 9)" = 0 ]; check "loopback: both message threads exit once the daemon closes" $? "$(val conn-threads) left"

for act in badmagic badsize badaux; do
	m=$(val $act)
	[ "$(num "$(field "$m" eof)" 0)" = 1 ]; check "malformed: $act ends the connection, the daemon reads EOF" $? "eof $(field "$m" eof) after $(field "$m" ms) ms"
	[ "$(num "$(val $act-threads)" 9)" = 0 ]; check "malformed: $act leaves no thread" $? "$(val $act-threads)"
done

# Stage 1 of the cluster protocol note: the peer's LNK_CONN announcing
# DMSG_SPAN_PROTO_2 turns the kernel's CRC check on for that connection and
# lists the peer's PROTO_2 spans; a PROTO_1 connection keeps upstream's
# behavior.  Under H2_CRC_CONTROL=1 the check is compiled out and the bad
# frame must pass, which is what proves the check is what ends it.
m=$(val proto2)
[ "$(num "$(field "$m" conn2_reply)" 0)" = 1 ] && [ "$(num "$(field "$m" shell_error)" 0)" = 32 ]; check "PROTO_2: the peer's LNK_CONN is answered and a verified frame is served" $? "conn2_reply $(field "$m" conn2_reply), shell_error $(field "$m" shell_error)"
[ "$(num "$(val log-proto2)" 0)" -ge 1 ]; check "PROTO_2: the kernel names the peer's protocol in its log" $? "$(val log-proto2) line(s)"
m=$(val badcrc)
if [ -n "${H2_CRC_CONTROL:-}" ]; then
	[ "$(num "$(field "$m" eof)" 1)" = 0 ] && [ "$(num "$(val log-badcrc)" 1)" = 0 ]; check "control: with the CRC check compiled out the bad frame is accepted" $? "eof $(field "$m" eof), $(val log-badcrc) log line(s)"
else
	[ "$(num "$(field "$m" eof)" 0)" = 1 ]; check "PROTO_2: a flipped header CRC ends the connection" $? "eof $(field "$m" eof) after $(field "$m" ms) ms"
	[ "$(num "$(val log-badcrc)" 0)" -ge 1 ]; check "PROTO_2: the log names the bad CRC" $? "$(val log-badcrc) line(s)"
fi
m=$(val badcrc1)
[ "$(num "$(field "$m" eof)" 1)" = 0 ]; check "PROTO_1: the same bad CRC is ignored, as upstream's core checks none" $? "eof $(field "$m" eof) after $(field "$m" ms) ms"
m=$(val spanlist)
[ "$(num "$(field "$m" spans_acked)" 0)" = 3 ]; check "PROTO_2: three spans from the peer are each answered" $? "$(field "$m" spans_acked) of 3"
[ "$(num "$(val log-spantab3)" 0)" -ge 1 ]; check "PROTO_2: the span table lists the three" $? "$(val log-spantab3) line(s) at three"
[ "$(num "$(val log-spantab0)" 0)" -ge 1 ]; check "PROTO_2: the table empties when the connection closes" $? "$(val log-spantab0) line(s) at zero"
for act in proto2 badcrc badcrc1 spanlist; do
	[ "$(num "$(val $act-threads)" 9)" = 0 ]; check "stage 1: $act leaves no thread" $? "$(val $act-threads)"
done
[ "$(num "$(val log-badmagic)" 0)" -ge 1 ] && [ "$(num "$(val log-badsize)" 0)" -ge 1 ] && [ "$(num "$(val log-badaux)" 0)" -ge 1 ]; check "malformed: the kernel log names each reason" $? "bad magic $(val log-badmagic), bad header size $(val log-badsize), illegal payload $(val log-badaux)"
[ "$(num "$(field "$(val halfclose)" conn)" 0)" = 1 ]; check "malformed: the attach after the three connects again" $? "halfclose run conn=$(field "$(val halfclose)" conn)"

k=$(val cancel)
[ "$(num "$(field "$k" conn_deleted)" 0)" = 1 ]; check "cancellation: the daemon's CONN DELETE is answered" $? "$(field "$k" conn_deleted)"
[ "$(num "$(field "$k" span_deleted)" 0)" = 1 ]; check "cancellation: a SPAN DELETE is answered" $? "$(field "$k" span_deleted)"
[ "$(num "$(field "$k" second_delete_answered)" 1)" = 0 ]; check "cancellation: control, the same DELETE again draws nothing" $? "$(field "$k" second_delete_answered) answered"
[ "$(num "$(val log-nostate)" 0)" -ge 1 ]; check "cancellation: the log says the state is gone (no state match for REPLY|DELETE)" $? "$(val log-nostate) line(s)"

rc2=$(val reconnect)
[ "$(num "$(field "$rc2" conn2)" 0)" = 1 ]; check "reconnect: a new LNK_CONN arrives on the new pair" $? "$(field "$rc2" conn2), $(field "$rc2" spans2) spans"
[ "$(num "$(field "$rc2" old_eof)" 0)" = 1 ]; check "reconnect: the old pair reads EOF" $? "$(field "$rc2" old_eof)"
[ "$(num "$(val reconnect-threads)" 9)" = 0 ]; check "reconnect: no thread pair is left behind" $? "$(val reconnect-threads)"

h=$(val halfclose)
[ "$(num "$(field "$h" eof)" 0)" = 1 ] && [ "$(num "$(val halfclose-threads)" 9)" = 0 ]; check "socket_faults: a half-close ends the connection and both threads" $? "eof $(field "$h" eof), $(val halfclose-threads) threads"
[ "$(num "$(val close-rc)" 1)" = 0 ] && [ "$(num "$(val close-threads)" 9)" = 0 ]; check "socket_faults: a hard close leaves no thread" $? "$(val close-threads) threads"
hb=$(num "$(val hold-threads-before)" 0); hu=$(num "$(val hold-umount-ms)" 99999); ha=$(num "$(val hold-threads-after)" 9)
sb=$(num "$(val log-shitcan-before)" 0); sa=$(num "$(val log-shitcan-after)" 0)
[ "$hb" = 2 ]; check "socket_faults: the held connection has its two threads before the unmount" $? "$hb"
[ "$(num "$(val hold-umount-rc)" 1)" = 0 ] && [ "$hu" -lt 20000 ]; check "socket_faults: unmount completes under a silent daemon" $? "$hu ms, exit $(val hold-umount-rc)"
[ "$hu" -ge 9000 ] && [ "$sa" -gt "$sb" ]; check "socket_faults: the ten-retry shutdown branch is what unstuck it" $? "$hu ms and the log's shutdown line went $sb to $sa"
[ "$(num "$(field "$(val hold)" eof)" 0)" = 1 ] && [ "$ha" = 0 ]; check "socket_faults: the daemon then reads EOF and no thread is left" $? "eof $(field "$(val hold)" eof), $ha threads"
cu=$(num "$(val ctl-umount-ms)" 99999); sf=$(num "$(val log-shitcan-final)" 0)
[ "$cu" -lt 3000 ] && [ "$sf" = "$sa" ]; check "socket_faults: control, with the daemon closed first the unmount is fast and the line is absent" $? "$cu ms, line count $sa to $sf"

[ "$(num "$(val kernel-warnings)" 1)" = 0 ]; check "no kernel warning, lockdep or sanitizer report" $? "$(val kernel-warnings)"
# Read as cluster-sync.sh reads it: a count is the reading, "unusable" is a
# failure on the kernels this runs on, which are built with it, and no
# value at all means the guest stopped before the scan.
l=$(val kmemleak)
case "$l" in
0) check "kmemleak reports nothing of hammer2's" 0 "$l" ;;
unusable) check "kmemleak is usable, so a leak would be reported" 1 "the scan refused" ;;
"") ;;
*) check "kmemleak reports nothing of hammer2's" 1 "$l" ;;
esac
[ "$(val rmmod)" = ok ] && [ "$(num "$(val threads-final)" 9)" = 0 ]; check "the module unloads with no thread left" $? "rmmod $(val rmmod), $(val threads-final) threads"

echo "dmsg: $checks check(s), $fail failed"
[ "$fail" -eq 0 ]
