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
# H2_DMSG_TLS=1 runs only the TLS link, on a second volume attached as
# vdc: a PSK handshake answered by the guest's tlshd between a server end
# into vdb's mount and a client end into vdc's, with kTLS, tlshd's log and
# a capture of the loopback port as three readings of one claim, then a
# wrong PSK, a key only in .nvme, a plaintext control for the capture and
# a revoked key, and with tlshd stopped a missing agent and a stub agent
# that never answers, under a timeout and two unmounts. The host block
# below lists the arms.
#
# Exit 2 is COULD-NOT-RUN. Needs the guest fleet, a kernel tree at KDIR
# matching the guest's kernel, newfs_hammer2 and hammer2 on this host,
# and hammer2 on the guest; H2_DMSG_TLS=1 also needs tlshd supervised by
# s6 at a debug loglevel of 1 or more, nvme-keyring, tcpdump, keyctl and
# the handshake tracepoints.
set -u
cd "$(dirname "$0")/.." || exit 2
# H2_DMSG_CLUSTERFD and H2_DMSG_TLS are written into the guest's ssh
# command line, so each is 0 or 1 before anything else reads it, and they
# name two modes, so at most one is set.
case ${H2_DMSG_CLUSTERFD:-0}${H2_DMSG_TLS:-0} in
00|01|10) ;;
11) echo "dmsg: COULD-NOT-RUN: H2_DMSG_CLUSTERFD and H2_DMSG_TLS are two modes; set one" >&2; exit 2 ;;
*) echo "dmsg: COULD-NOT-RUN: H2_DMSG_CLUSTERFD and H2_DMSG_TLS are each 0 or 1" >&2; exit 2 ;;
esac

FIXDIR=${H2_FIXTURE_DIR:-$HOME/Projects/linux_hammer2-data/fixtures}
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2")}
# The bound scales on a KASAN tree, as cluster-sync.sh's does, so a slower
# kernel is not read as a hang.
RUNSECS=600; grep -qx 'CONFIG_KASAN=y' "$KDIR/.config" 2>/dev/null && RUNSECS=$((RUNSECS * 4))
RUN="timeout ${H2_RUN_TIMEOUT:-$RUNSECS} ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
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
		    'umount -f /mnt/h2d 2>/dev/null; umount -f /mnt/h2e 2>/dev/null; rmmod hammer2 2>/dev/null; true' >/dev/null 2>&1
	fi
	for t in vdb vdc; do
		$VIRSH detach-disk "$GUEST" $t --live >/dev/null 2>&1
		$VIRSH detach-disk "$GUEST" $t --config >/dev/null 2>&1
	done
}

make -s clean >/dev/null 2>&1
# H2_CRC_CONTROL=1 builds the module with its PROTO_2 CRC check and the HM2
# server's window compiled out, the negative controls: the bad frame must
# then be accepted and a reply must run past sixteen frames with no
# continuation, and every other check must still hold.  Never install that
# module.
make -s KDIR="$KDIR" ${H2_CRC_CONTROL:+HAMMER2_NOCRC=1 HAMMER2_NOWINDOW=1} >/dev/null 2>&1 || { echo "dmsg: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko
cc -static -O2 -Isrc/sys/fs/hammer2 -o "$W/h2attach" test/h2attach.c 2>"$W/cc.err" || {
	echo "dmsg: COULD-NOT-RUN: test/h2attach.c did not build:" >&2; sed 's/^/        /' "$W/cc.err" >&2; exit 2; }
# the copyinfo[] row the server requires for each cluster it serves (stage 5.5)
cc -static -O2 -Isrc/sys/fs/hammer2 -o "$W/h2service" test/h2service.c 2>"$W/cc.err" || {
	echo "dmsg: COULD-NOT-RUN: test/h2service.c did not build:" >&2; sed 's/^/        /' "$W/cc.err" >&2; exit 2; }
# The TLS peer is built on the guest; built here too, so a source error
# stops the run before a guest is touched.
if [ "${H2_DMSG_TLS:-0}" = 1 ]; then
	cc -O2 -DH2_GNUTLS -Isrc/sys/fs/hammer2 -o "$W/h2tlspeer" test/h2attach.c -lgnutls 2>"$W/cc-peer.err" || {
		echo "dmsg: COULD-NOT-RUN: test/h2attach.c did not build with -DH2_GNUTLS:" >&2; sed 's/^/        /' "$W/cc-peer.err" >&2; exit 2; }
fi

detach_disk
rm -f "$IMG"
# The TLS mode's vdb carries stage 5.5's names from newfs, since both
# ioctls refuse the suffixes: a MASTER CL, a MASTER of subtype none under
# CL's peer name, and an unmounted local source.
LABELS=ROOT; [ "${H2_DMSG_TLS:-0}" = 1 ] && LABELS=ROOT,CL,CL.h2sync-peer,CL.h2sync-src
truncate -s 1G "$IMG" && "$NEWFS" -L "$LABELS" "$IMG" >/dev/null 2>&1 || {
	echo "dmsg: COULD-NOT-RUN: newfs_hammer2 failed on $IMG" >&2; exit 2; }
if [ "$state" = running ]; then how=--live; else how=--config; fi
# The TLS mode's second volume, the client end's mount, attached first so
# a guest that is off boots with both.
if [ "${H2_DMSG_TLS:-0}" = 1 ]; then
	IMGC=$FIXDIR/cluster-dmsg-c.img
	rm -f "$IMGC"
	truncate -s 1G "$IMGC" && "$NEWFS" -L ROOT "$IMGC" >/dev/null 2>&1 || {
		echo "dmsg: COULD-NOT-RUN: newfs_hammer2 failed on $IMGC" >&2; exit 2; }
	err=$($VIRSH attach-disk "$GUEST" "$IMGC" vdc --targetbus virtio $how 2>&1) || {
		echo "dmsg: COULD-NOT-RUN: could not attach the second volume: $err" >&2; exit 2; }
fi
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
# One lockdep report turns lockdep off until the next boot, and a run
# on that boot reads "no report" with nothing checking.
dl=$(ssh -o BatchMode=yes "$GUEST_SSH" "awk '/debug_locks:/ {print \$2}' /proc/lockdep_stats 2>/dev/null")
[ "$dl" = 0 ] && {
	echo "dmsg: COULD-NOT-RUN: lockdep is off on $GUEST since an earlier report; boot it again" >&2; exit 2; }
# H2_DMSG_CLUSTERFD=1 passes on "no recursive-locking report", which a
# kernel without lockdep satisfies by having no /proc/lockdep_stats.
[ "${H2_DMSG_CLUSTERFD:-0}" = 1 ] && [ "$dl" != 1 ] && {
	echo "dmsg: COULD-NOT-RUN: H2_DMSG_CLUSTERFD=1 needs lockdep on, and $GUEST reads debug_locks '${dl:-absent}'" >&2; exit 2; }
# The mount's bound in that mode, in tenths of a second, scaled as RUNSECS is.
FDT=300; grep -qx 'CONFIG_KASAN=y' "$KDIR/.config" 2>/dev/null && FDT=$((FDT * 4))

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
{ echo scan > /sys/kernel/debug/kmemleak && echo scan > /sys/kernel/debug/kmemleak && echo clear > /sys/kernel/debug/kmemleak; } 2>/dev/null; echo "kmemleak-cleared"	# an earlier run's leaks are its own
insmod /tmp/hammer2.ko || { echo "insmod failed"; exit 1; }
echo 256 > /sys/module/hammer2/parameters/debug 2>/dev/null
echo "debug $(cat /sys/module/hammer2/parameters/debug 2>/dev/null)"
# The end of every mode: warnings, kmemleak before and after the unload.
finish() {
echo "kernel-warnings $(grep -c -E 'WARNING|BUG:|UBSAN:|KASAN|circular locking|possible recursive' $K)"
# Before rmmod, so the report's %pS resolves the module's own symbols, and
# after the wait the scanner's age rule needs (kmemleak.c MSECS_MIN_AGE,
# 5000 ms), as cluster-sync.sh does. The message core allocates a state and
# a message per frame and frees them from two threads that exit on their
# own, which is where a leak would sit.
sleep 6
if echo scan > /sys/kernel/debug/kmemleak 2>/dev/null && echo scan > /sys/kernel/debug/kmemleak; then
	echo "kmemleak $(grep -c hammer2 /sys/kernel/debug/kmemleak)"
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
echo "threads-final $(threads)"
}
# H2_DMSG_TLS=1: the TLS link with tlshd and a stub agent answering, one
# guest, vdb and vdc each mounted @ROOT; the host side's comment lists the
# arms and what each reads.
if [ "${H2_DMSG_TLS:-0}" = 1 ]; then
	M2=/mnt/h2e
	TL=/var/log/tlshd/current
	T=/sys/kernel/tracing
	CONF=/etc/tlshd/config; [ -e /etc/tlshd.conf ] && CONF=/etc/tlshd.conf
	tlshd_up() {	# the pid of a tlshd whose parent is s6-supervise, or nothing
		for p in $(pgrep -x tlshd); do
			[ "$(ps -o comm= -p "$(ps -o ppid= -p $p | tr -d ' ')")" = s6-supervise ] && echo $p
		done | head -1
	}
	[ "$(grep -c ' handshake_req_alloc$' /proc/kallsyms)" = 1 ] || { echo "dmsg: COULD-NOT-RUN: H2_DMSG_TLS=1 needs a kernel with the handshake upcall" >&2; exit 2; }
	[ -n "$(tlshd_up)" ] || { echo "dmsg: COULD-NOT-RUN: no tlshd running as a child of s6-supervise" >&2; exit 2; }
	ll=$(awk -F= '/^\[/ { s = $0 } s == "[debug]" && $1 ~ /^[ \t]*loglevel[ \t]*$/ { gsub(/[ \t]/, "", $2); print $2 }' $CONF | tail -1)
	[ "${ll:-0}" -ge 1 ] 2>/dev/null || { echo "dmsg: COULD-NOT-RUN: $CONF [debug] loglevel is '${ll:-unset}', below 1, so tlshd writes no completion line" >&2; exit 2; }
	modprobe nvme-keyring || { echo "dmsg: COULD-NOT-RUN: modprobe nvme-keyring failed" >&2; exit 2; }
	for c in tcpdump keyctl od cc; do command -v $c >/dev/null 2>&1 || { echo "dmsg: COULD-NOT-RUN: no $c on the guest" >&2; exit 2; }; done
	# The TLS peer, h2attach built against the guest's GnuTLS, which has no
	# static copy to build it with on the host.
	P=/tmp/h2tlspeer
	cc -O2 -DH2_GNUTLS -I/tmp/h2peer -o $P /tmp/h2peer/h2attach.c -lgnutls 2>/tmp/h2peer.err || {
		echo "dmsg: COULD-NOT-RUN: the TLS peer did not build on the guest: $(head -3 /tmp/h2peer.err | tr '\n' ' ')" >&2; exit 2; }
	echo "tls-peer-gnutls $(pacman -Q gnutls 2>/dev/null || echo unread)"
	grep -q " $T tracefs " /proc/mounts || mount -t tracefs nodev $T 2>/dev/null	# not mounted at boot on the Artix guests
	[ -e $T/events/handshake/handshake_cancel ] || { echo "dmsg: COULD-NOT-RUN: no $T/events/handshake/handshake_cancel" >&2; exit 2; }
	[ -r $TL ] || { echo "dmsg: COULD-NOT-RUN: no tlshd log at $TL" >&2; exit 2; }
	# tlshd is stopped for arms 6 to 9; whatever ends the run brings it back.
	# The keys go with the run: both rings and the .nvme key are unlinked.
	# A signal ends the run through exit, so the EXIT trap runs for it too.
	trap 'kill $KPID ${CPID:-} ${STPID:-} ${CLPID:-} 2>/dev/null; s6-rc -u change tlshd-srv >/dev/null 2>&1; for k in ${RING:-} ${WRING:-}; do keyctl unlink $k @u >/dev/null 2>&1; done; [ -n "${K3:-}" ] && keyctl unlink $K3 $((0x$NV)) >/dev/null 2>&1' EXIT
	trap 'exit 1' HUP INT TERM
	echo "tlshd-loglevel $ll ($CONF)"
	echo "remote-timeout $(echo 3000 > /sys/module/hammer2/parameters/remote_timeout_ms && cat /sys/module/hammer2/parameters/remote_timeout_ms)"
	echo "tls-timeout-ms $(cat /sys/module/hammer2/parameters/cluster_tls_timeout_ms)"
	echo "tls-required $(cat /sys/module/hammer2/parameters/cluster_tls_required)"

	# The keys: identities of one length, since the psk type matches a
	# description by prefix; each read back from a session that reaches
	# none of the rings, which is how tlshd reads a key by serial.
	hex() { od -An -N$1 -tx1 /dev/urandom | tr -d ' \n'; }
	mkkey() {	# mkkey <identity> <payload> <ring>: the serial
		k=$(printf %s "$2" | keyctl padd psk "$1" "$3") && keyctl setperm "$k" 0x3f0b0000 && echo "$k"
	}
	rdback() { [ "$(keyctl session - keyctl pipe "$1" 2>/dev/null)" = "$2" ] && echo ok || echo fail; }
	RING=$(keyctl newring hammer2-tls @u) && keyctl setperm $RING 0x3f1b0000 &&
	WRING=$(keyctl newring hammer2-tls-wrong @u) && keyctl setperm $WRING 0x3f1b0000 || {
		echo "dmsg: COULD-NOT-RUN: the keyrings could not be made" >&2; exit 2; }
	I1=hammer2-psk-$(hex 4); I3=hammer2-psk-$(hex 4); I4=hammer2-psk-$(hex 4)
	P1=$(hex 32); P2=$(hex 32); P3=$(hex 32); P4=$(hex 32)
	K1=$(mkkey $I1 $P1 $RING) && K2=$(mkkey $I1 $P2 $WRING) && K4=$(mkkey $I4 $P4 $RING) || {
		echo "dmsg: COULD-NOT-RUN: the keys could not be made" >&2; exit 2; }
	NV=$(awk '$8 == "keyring" && $9 == ".nvme:" { print $1 }' /proc/keys | head -1)
	# A key added straight into .nvme is not possessed by this session,
	# so setperm is refused on it; it is made here, then linked there.
	K3=
	if [ -n "$NV" ]; then
		K3=$(mkkey $I3 $P3 @s 2>/tmp/h2k3.err) && keyctl link $K3 $((0x$NV)) 2>>/tmp/h2k3.err && keyctl unlink $K3 @s >/dev/null 2>>/tmp/h2k3.err || K3=
	fi
	echo "tls-ring $RING wrong $WRING nvme ${NV:+$((0x$NV))}"
	echo "tls-key K1 $K1 $I1 read=$(rdback $K1 $P1)"
	echo "tls-key K2 $K2 $I1 read=$(rdback $K2 $P2)"
	if [ -n "$K3" ]; then echo "tls-key K3 $K3 $I3 read=$(rdback $K3 $P3)"
	else echo "tls-key K3 none $I3 read=fail refused=$(tr '\n' ' ' < /tmp/h2k3.err)"; fi
	echo "tls-key K4-before-revoke $K4 $I4 read=$(rdback $K4 $P4)"
	keyctl revoke $K4
	echo "tls-key K4 $K4 $I4 read=$(rdback $K4 $P4)"

	mkdir -p $M $M2
	mount -t hammer2 /dev/vdb@ROOT $M || { echo "mount failed"; exit 1; }
	mount -t hammer2 /dev/vdc@ROOT $M2 || { echo "mount vdc failed"; exit 1; }
	hammer2 -s $M pfs-create SP >/dev/null 2>&1
	echo "pfs-count-b $(hammer2 -s $M pfs-list 2>/dev/null | awk 'NR>1' | grep -c .)"
	echo "pfs-count-c $(hammer2 -s $M2 pfs-list 2>/dev/null | awk 'NR>1' | grep -c .)"
	echo "threads-before $(threads)"

	TL0=$(wc -l < $TL)
	tlog() { tail -n +$((TL0 + 1)) $TL | grep -cE "Handshake (with .*|request) $1"; }
	tlog_any() { tail -n +$((TL0 + 1)) $TL | grep -c "$1"; }
	tstat() {	# a counter of /proc/net/tls_stat, -1 when it cannot be read
		v=$(awk -v k=$1 '$1 == k { print $2 }' /proc/net/tls_stat 2>/dev/null); echo "${v:--1}"
	}
	handed() { klog 'cluster link handed to the message threads'; }
	refused() { klog "cluster link refused: ${1:-}"; }
	until_n() {	# until_n <tenths> <target> <command...>: wait for the count, print the seconds
		b=$1; g=$2; shift 2; t=0
		while [ "$("$@")" -lt "$g" ] && [ $t -lt "$b" ]; do sleep 0.1; t=$((t + 1)); done
		echo "$((t / 10)).$((t % 10))"
	}
	cap_start() {	# cap_start <port>
		tcpdump -i lo -U -w /tmp/h2tls-$1.pcap "tcp port $1" 2>/tmp/h2tls-$1.err &
		CPID=$!
		n=0; until grep -q listening /tmp/h2tls-$1.err 2>/dev/null; do sleep 0.1; n=$((n + 1)); [ $n -gt 50 ] && break; done
	}
	cap_stop() { sleep 0.5; kill $CPID 2>/dev/null; wait $CPID 2>/dev/null; }
	cap_count() {	# cap_count <port> <bytes>: byte-aligned occurrences in the capture
		od -An -v -tx1 /tmp/h2tls-$1.pcap | tr '\n' ' ' | tr -s ' ' | grep -o " $2" | wc -l
	}
	arm_link() {	# arm_link <arm> <port> <h2attach args>
		a=$1; p=$2; shift 2
		out=$($A --attach $M --attach2 $M2 --action tlslink --port $p "$@" 2>&1); echo "$a-rc $?"; echo "$a $out"
	}
	snap() {	# snap <arm>: the counts every arm is read against
		echo "$1-before handed=$(handed) refused=$(refused) ok=$(tlog succeeded) failed=$(tlog failed) threads=$(threads) silent=$(klog 'HM2 peer silent') terminated=$(klog 'CONN WAS TERMINATED') tx=$(tstat TlsCurrTxSw) rx=$(tstat TlsCurrRxSw)"
		h0=$(handed); r0=$(refused); s0=$(tlog succeeded); f0=$(tlog failed)
	}
	after() {	# after <arm>
		echo "$1-after handed=$(handed) refused=$(refused) ok=$(tlog succeeded) failed=$(tlog failed) threads=$(threads) silent=$(klog 'HM2 peer silent') terminated=$(klog 'CONN WAS TERMINATED') tx=$(tstat TlsCurrTxSw) rx=$(tstat TlsCurrRxSw) rxspan=$(klog 'H2 +RXSPAN') spanrefused=$(klog 'cluster link refused a span of cluster') proto2=$(klog 'peer speaks DMSG_SPAN_PROTO_2')"
	}

	# arm 1, the link with TLS on, server vdb and client vdc
	snap arm1; cap_start 7997
	arm_link arm1 7997 --keyring $RING --admit $K1 --key $K1
	echo "arm1-wait-handed $(until_n 150 $((h0 + 2)) handed)"
	echo "arm1-wait-tlshd $(until_n 50 $((s0 + 2)) tlog succeeded)"
	sleep 2; after arm1-up
	sleep 8; after arm1; cap_stop
	echo "arm1-capture magic=$(cap_count 7997 '32 48 00 00') tlsapp=$(cap_count 7997 '17 03 03') bytes=$(stat -c %s /tmp/h2tls-7997.pcap)"

	# arm 2, a wrong PSK under the identity the server admits, the first link live
	snap arm2; p0=$(refused 'the handshake failed')
	arm_link arm2 7996 --keyring $RING --admit $K1 --key $K2
	echo "arm2-wait-refused $(until_n 150 $((p0 + 2)) refused 'the handshake failed')"
	sleep 8; after arm2
	grep 'cluster link refused: the handshake failed' $K | tail -n +$((p0 + 1)) | sed 's/^/arm2-line /'

	# arm 4, a client identity held only in .nvme
	if [ -n "$K3" ]; then
		snap arm4; p0=$(refused 'the peer.s key is not one')
		arm_link arm4 7994 --keyring $RING --admit $K1 --key $K3
		echo "arm4-wait-refused $(until_n 150 $((p0 + 1)) refused 'the peer.s key is not one')"
		echo "arm4-wait-handed $(until_n 50 $((h0 + 1)) handed)"
		sleep 2; after arm4
		echo "arm4-k3 $K3"
		grep 'cluster link refused: the peer.s key is not one' $K | tail -n +$((p0 + 1)) | sed 's/^/arm4-line /'
	else
		echo "arm4-driven 0"
	fi

	# arm 3, the plaintext control for the capture: both links replaced
	snap arm3; cap_start 7995
	arm_link arm3 7995 --tls none
	echo "arm3-wait-handed $(until_n 150 $((h0 + 2)) handed)"
	t=0; while [ "$(tstat TlsCurrTxSw)$(tstat TlsCurrRxSw)" != 00 ] && [ $t -lt 50 ]; do sleep 0.1; t=$((t + 1)); done
	sleep 2; after arm3; cap_stop
	echo "arm3-capture magic=$(cap_count 7995 '32 48 00 00') tlsapp=$(cap_count 7995 '17 03 03') bytes=$(stat -c %s /tmp/h2tls-7995.pcap)"

	# arms 10 to 14, the reader on a TLS link: the kernel the client on vdb
	# with K1, the GnuTLS peer the server, one record each on a live link
	tpeer() {	# tpeer <arm> <record> <port>
		snap $1; rk0=$(tstat TlsRxRekeyReceived)
		$P --attach $M --action tlspeer --key $K1 --send $2 --port $3 > /tmp/h2peer-$1.out 2>&1; echo "$1-rc $?"
		sed "s/^/$1-out /" /tmp/h2peer-$1.out
		t=0; while [ "$(threads)" != 0 ] && [ $t -lt 50 ]; do sleep 0.1; t=$((t + 1)); done
		after $1
		echo "$1-lines dropped=$(klog 'TLS peer sent handshake message 4, dropped') keyupdate=$(klog 'TLS peer sent KeyUpdate') alert=$(klog 'TLS peer sent alert 2/80') ended=$(klog 'TLS peer ended the link (alert 90)') other=$(klog 'TLS peer sent a record of type\|TLS peer.s record unreadable') rekey=$(($(tstat TlsRxRekeyReceived) - rk0))"
	}
	tpeer arm10 none 7988
	tpeer arm11 ticket 7987
	tpeer arm12 keyupdate 7986
	tpeer arm13 alert 7985
	tpeer arm14 close 7984

	client() {	# client <arm> <mount> <key> <port>: the intake, its peer held in the background
		$A --attach $2 --action tlsclient --key $3 --port $4 --hold-max-ms 25000 > /tmp/h2tls-$1.out 2>&1 &
		CLPID=$!
		n=0; until grep -q 'errno=' /tmp/h2tls-$1.out 2>/dev/null; do sleep 0.1; n=$((n + 1)); [ $n -gt 50 ] && break; done
		echo "$1-intake $(grep -m1 'errno=' /tmp/h2tls-$1.out)"
	}
	client_end() { wait $CLPID; echo "$1-client rc=$? $(grep 'eof=' /tmp/h2tls-$1.out)"; }

	# arm 5, a revoked client key
	snap arm5; kf0=$(tlog_any 'Key has been revoked')
	client arm5 $M $K4 7993
	echo "arm5-wait-refused $(until_n 150 $((r0 + 1)) refused)"
	sleep 1; after arm5; client_end arm5
	echo "arm5-keyfail $(($(tlog_any 'Key has been revoked') - kf0))"
	grep 'cluster link refused' $K | tail -1 | sed 's/^/arm5-line /'

	# arm 6, no agent at all
	s6-rc -d change tlshd-srv
	t=0; while pgrep -x tlshd >/dev/null && [ $t -lt 100 ]; do sleep 0.1; t=$((t + 1)); done
	echo "arm6-tlshd $(pgrep -x tlshd | wc -l)"
	snap arm6
	client arm6 $M $K1 7992
	sleep 1; after arm6; client_end arm6
	echo "arm6-notsubmitted $(refused 'the handshake was not submitted (3)')"

	# arms 7 to 9, the stub agent; the cancel tracepoint read per arm
	echo 1 > $T/events/handshake/handshake_cancel/enable
	cancels() { grep -c 'handshake_cancel:' $T/trace; }
	stub() {	# stub <accept>
		$A --action hsstub --accept $1 --hold-max-ms 120000 > /tmp/h2stub-$1.out 2>&1 &
		STPID=$!
		n=0; until grep -q joined /tmp/h2stub-$1.out 2>/dev/null; do sleep 0.1; n=$((n + 1)); [ $n -gt 50 ] && break; done
		echo "stub$1-start $(head -1 /tmp/h2stub-$1.out)"
	}
	stub_end() { kill $STPID 2>/dev/null; wait $STPID; echo "stub$1-end $(tail -1 /tmp/h2stub-$1.out)"; }
	stub 0

	# arm 7, a request no agent accepts, ended by the intake's deadline
	: > $T/trace; snap arm7; to0=$(refused 'the handshake timed out')
	t0=$(date +%s%N)
	client arm7 $M $K1 7991
	until_n 250 $((to0 + 1)) refused 'the handshake timed out' >/dev/null
	echo "arm7-ms $(( ($(date +%s%N) - t0) / 1000000 ))"
	sleep 1; after arm7; client_end arm7
	echo "arm7-cancels $(cancels)"
	grep 'cluster link refused: the handshake timed out' $K | tail -n +$((to0 + 1)) | sed 's/^/arm7-line /'

	# arm 8, an unmount under a pending request
	: > $T/trace; snap arm8; to0=$(refused 'the handshake timed out'); late0=$to0
	client arm8 $M $K1 7990
	sleep 2
	t0=$(date +%s%N); timeout 60 umount $M; urc=$?; t1=$(date +%s%N)
	echo "arm8-umount rc=$urc ms=$(( (t1 - t0) / 1000000 ))"
	client_end arm8
	t=0; while [ "$(threads)" != 0 ] && [ $t -lt 50 ]; do sleep 0.1; t=$((t + 1)); done
	after arm8
	echo "arm8-cancels $(cancels) timedout-new=$(($(refused 'the handshake timed out') - to0))"
	stub_end 0

	# arm 9, an unmount under a request the stub accepted and never answers
	stub 1
	: > $T/trace; snap arm9; to0=$(refused 'the handshake timed out')
	client arm9 $M2 $K1 7989; t9=$(date +%s)
	n=0; until grep -q 'accepted fd=' /tmp/h2stub-1.out 2>/dev/null; do sleep 0.1; n=$((n + 1)); [ $n -gt 50 ] && break; done
	echo "arm9-accepted $(grep -m1 'accepted fd=' /tmp/h2stub-1.out)"
	sleep 2
	t0=$(date +%s%N); timeout 60 umount $M2; urc=$?; t1=$(date +%s%N)
	echo "arm9-umount rc=$urc ms=$(( (t1 - t0) / 1000000 ))"
	client_end arm9
	after arm9
	echo "arm9-cancels $(cancels) timedout-new=$(($(refused 'the handshake timed out') - to0))"
	stub_end 1
	echo 0 > $T/events/handshake/handshake_cancel/enable
	# The timed-out count of arms 8 and 9 read again once the later
	# intake's deadline has passed: read right after the unmounts it is a
	# zero that could not have been anything else.
	w=$((t9 + $(cat /sys/module/hammer2/parameters/cluster_tls_timeout_ms) / 1000 + 2 - $(date +%s)))
	[ "$w" -gt 0 ] && sleep "$w"
	echo "late-timedout waited=${w}s new=$(($(refused 'the handshake timed out') - late0))"

	s6-rc -u change tlshd-srv
	t=0; while [ -z "$(tlshd_up)" ] && [ $t -lt 100 ]; do sleep 0.1; t=$((t + 1)); done
	echo "tlshd-restored $(tlshd_up | grep -c .)"

	# Stage 5.5's controls on one guest (the cluster note's list): what a
	# TLS link carries, what the server serves, and the names it makes
	# and keeps.  vdb holds CL, CL.h2sync-peer and CL.h2sync-src from
	# newfs, none bound to any key here.  0x8000 adds the snapshot lines.
	echo $((0x8100)) > /sys/module/hammer2/parameters/debug
	S=/tmp/h2service
	pc() { hammer2 -s $1 pfs-clid $2 2>/dev/null; }
	pl() { hammer2 -s $M pfs-list 2>/dev/null | grep -c -- "$1"; }
	lines() { awk -v p="$1" '{ print p "-" NR " " $0 }'; }
	hsnap() {	# hsnap <arm> <h2attach args>: hm2snap on vdb's ROOT mount
		a=$1; shift
		out=$($A --attach $M --action hm2snap "$@" 2>&1); echo "$a-rc $?"
		echo "$out" | lines $a
	}
	mount -t hammer2 /dev/vdb@ROOT $M && mount -t hammer2 /dev/vdc@ROOT $M2 || { echo "s55 remount failed"; exit 1; }
	XB=$(pc $M ROOT); XCL=$(pc $M CL); XSRC=$(pc $M CL.h2sync-src)
	Z=5a5a5a5a-0000-4000-8000-000000000001; W=5a5a5a5a-0000-4000-8000-000000000002
	echo "s55-clids rootb=$XB cl=$XCL src=$XSRC z=$Z w=$W pfs-b=$(hammer2 -s $M pfs-list 2>/dev/null | awk 'NR>1' | grep -c .)"

	# a key revoked after one completed handshake: the next fails and the
	# first link carries on
	I5=hammer2-psk-$(hex 4); P5=$(hex 32); K5=$(mkkey $I5 $P5 $RING)
	echo "s55rev-key $K5 read=$(rdback $K5 $P5)"
	snap s55rev; kf0=$(tlog_any 'Key has been revoked')
	arm_link s55rev1 7983 --keyring $RING --admit $K5 --key $K5
	echo "s55rev-wait-handed $(until_n 150 $((h0 + 2)) handed)"
	sleep 2; after s55rev-up
	keyctl revoke $K5
	arm_link s55rev2 7982 --keyring $RING --admit $K5 --key $K5
	echo "s55rev-wait-refused $(until_n 150 $((r0 + 1)) refused)"
	sleep 8; after s55rev
	echo "s55rev-keyfail $(($(tlog_any 'Key has been revoked') - kf0))"

	# the TLS peer bound to XB: a row for XB typed SLAVE and one for Z;
	# a MASTER span for XB and one for an unbound id; a row for W added
	# and deleted while the link lingers
	echo "s55peer-rows $($S add $M --clid $XB --label xb --path span:127.0.0.1:1 --type slave 2>&1 | tr '\n' ' ')$($S add $M --clid $Z --label z --path span:127.0.0.1:2 2>&1 | tr '\n' ' ')"
	snap s55peer; sr0=$(klog 'cluster link refused a span of cluster'); mon0=$(klog 'monitored: no enabled MASTER copyinfo row')
	$P --attach $M --action tlspeer --key $K1 --send none --port 7981 --spans 1 --linger-ms 9000 > /tmp/h2peer-s55.out 2>&1 &
	PPID5=$!
	n=0; until grep -q 'handshake=' /tmp/h2peer-s55.out 2>/dev/null; do sleep 0.1; n=$((n + 1)); [ $n -gt 150 ] && break; done
	sleep 4
	echo "s55peer-w-add $($S add $M --clid $W --label w --path span:127.0.0.1:3 2>&1 | tr '\n' ' ')"
	sleep 1
	echo "s55peer-w-del $($S del $M --path span:127.0.0.1:3 2>&1 | tr '\n' ' ')"
	wait $PPID5; echo "s55peer-rc $?"
	lines s55peer-out < /tmp/h2peer-s55.out
	t=0; while [ "$(threads)" != 0 ] && [ $t -lt 50 ]; do sleep 0.1; t=$((t + 1)); done
	after s55peer
	echo "s55peer-lines spanrefused=$(($(klog 'cluster link refused a span of cluster') - sr0)) monitored=$(($(klog 'monitored: no enabled MASTER copyinfo row') - mon0)) listed21=$(klog 'label=h2attach-span-21 ') listed22=$(klog 'label=h2attach-span-22 ')"
	for p in 1 2; do $S del $M --path span:127.0.0.1:$p >/dev/null 2>&1; done

	# the row requirement on a plaintext link: refused with no row,
	# served with one
	nr0=$(klog 'refused: no enabled copyinfo row for that cluster')
	out=$($A --attach $M --action hm2root 2>&1); echo "s55a-norow-rc $?"; echo "s55a-norow $out"
	sleep 1
	echo "s55a-row $($S add $M --clid $XB --label xb --path span:127.0.0.1:1 2>&1 | tr '\n' ' ')"
	out=$($A --attach $M --action hm2root 2>&1); echo "s55a-row-rc $?"; echo "s55a-served $out"
	echo "s55a-lines norow=$(($(klog 'refused: no enabled copyinfo row for that cluster') - nr0))"

	# SNAPSHOT of ROOT twice on one link, then once with SNAPDEL
	sleep 1; l0=$(klog 'left by the link deleted')
	hsnap s55b --pfs ROOT --count 2
	until_n 50 $((l0 + 1)) klog 'left by the link deleted' >/dev/null; sleep 1
	echo "s55b-left n=$(($(klog 'left by the link deleted') - l0)) err0=$(grep 'left by the link deleted' $K | tail -n +$((l0 + 1)) | grep -c 'ROOT.h2sync-peer left by the link deleted, error 0') listed=$(pl ROOT.h2sync-peer)"
	sleep 1; l0=$(klog 'left by the link deleted')
	hsnap s55c --pfs ROOT --snapdel 1
	sleep 2
	echo "s55c-left n=$(($(klog 'left by the link deleted') - l0)) listed=$(pl ROOT.h2sync-peer) deleted=$(klog 'peer deleted ROOT.h2sync-peer error 0')"

	# a SLAVE source: SL a MASTER on vdc and a SLAVE on vdb, one cluster
	# mounted through vdc
	hammer2 -s $M2 pfs-create SL >/dev/null 2>&1; U=$(pc $M2 SL)
	hammer2 -s $M -t SLAVE -u "$U" pfs-create SL >/dev/null 2>&1
	mkdir -p /mnt/h2sl; mount -t hammer2 /dev/vdc@SL /mnt/h2sl; echo "s55d-mount $? clid=$U"
	echo "s55d-row $($S add $M --clid $U --label sl --path span:127.0.0.1:4 2>&1 | tr '\n' ' ')"
	sleep 1; m0=$(klog 'refused a snapshot of SL, which is not a mounted MASTER element')
	hsnap s55d --pfs SL
	echo "s55d-lines notmaster=$(($(klog 'refused a snapshot of SL, which is not a mounted MASTER element') - m0)) listed=$(pl SL.h2sync-peer)"
	umount /mnt/h2sl

	# a local pass's source, unmounted, named by its cluster id
	sleep 1
	hsnap s55e --pfs nosuch --clid "$XSRC"
	echo "s55e-after listed=$(pl CL.h2sync-src)"

	# CL mounted with a row, its peer name held by a MASTER PFS of
	# subtype none; then SNAPDEL naming CL itself
	mkdir -p /mnt/h2cl; mount -t hammer2 /dev/vdb@CL /mnt/h2cl; echo "s55f-mount $?"
	echo "s55f-row $($S add $M --clid $XCL --label cl --path span:127.0.0.1:5 2>&1 | tr '\n' ' ')"
	sleep 1; k0=$(klog 'PFS CL.h2sync-peer kept: a stale delete takes only a snapshot')
	hsnap s55f --pfs CL
	echo "s55f-lines kept=$(($(klog 'PFS CL.h2sync-peer kept: a stale delete takes only a snapshot') - k0)) listed=$(pl CL.h2sync-peer)"
	sleep 1; no0=$(klog 'peer named CL, not this link')
	hsnap s55h2 --pfs CL --count 0 --delclid "$XCL"
	echo "s55h2-lines notours=$(($(klog 'peer named CL, not this link') - no0)) cl-listed=$(hammer2 -s $M pfs-list 2>/dev/null | awk '$NF == "CL"' | grep -c .)"
	umount /mnt/h2cl

	# a source whose label is 128 bytes
	LL=$(printf '%0128d' 0 | tr 0 L)
	hammer2 -s $M pfs-create "$LL" >/dev/null 2>&1; XLL=$(pc $M "$LL")
	mkdir -p /mnt/h2ll; mount -t hammer2 "/dev/vdb@$LL" /mnt/h2ll; echo "s55g-mount $? clid=$XLL"
	echo "s55g-row $($S add $M --clid "$XLL" --label ll --path span:127.0.0.1:6 2>&1 | tr '\n' ' ')"
	sleep 1; g0=$(klog 'whose label is 128 bytes')
	hsnap s55g --pfs "$LL" --clid "$XLL"
	echo "s55g-lines long=$(($(klog 'whose label is 128 bytes') - g0)) listed=$(pl "$LL.h2sync-peer")"
	umount /mnt/h2ll

	# SNAPDEL of a snapshot this link never took
	hammer2 snapshot $M ZZ.decoy-snap >/dev/null 2>&1; echo "s55h1-decoy-rc $?"; XZZ=$(pc $M ZZ.decoy-snap)
	sleep 1
	hsnap s55h1 --count 0 --delclid "$XZZ"
	echo "s55h1-after clid=$XZZ listed=$(pl ZZ.decoy-snap)"

	# the reserved names through both ioctls, and the mount option's order
	r1=0; hammer2 -s $M pfs-create a.h2sync-src >/dev/null 2>&1 || r1=$?
	r2=0; hammer2 -s $M pfs-create a.h2sync-peer >/dev/null 2>&1 || r2=$?
	r3=0; hammer2 snapshot $M a.h2sync-src >/dev/null 2>&1 || r3=$?
	r4=0; hammer2 snapshot $M a.h2sync-peer >/dev/null 2>&1 || r4=$?
	echo "s55i create-src=$r1 create-peer=$r2 snap-src=$r3 snap-peer=$r4 listed=$(pl 'a\.h2sync-')"
	mkdir -p /mnt/h2opt
	out=$(mount -t hammer2 -o "cluster_tls_clid=$XB,cluster_tls_key=5" /dev/vdb@ROOT /mnt/h2opt 2>&1); rc=$?
	echo "s55j rc=$rc said=$(echo "$out" | tr '\n' ' ') klog=$(klog 'cluster_tls_clid before any cluster_tls_key')"
	mountpoint -q /mnt/h2opt && umount /mnt/h2opt
	umount $M2; umount $M
	echo $((0x100)) > /sys/module/hammer2/parameters/debug
	echo "threads-end $(threads)"
	tail -n +$((TL0 + 1)) $TL | sed 's/^/tlshd-log /'	# kept whole in the report
	finish
	exit 0
fi
# H2_DMSG_CLUSTERFD=1: the mount intake alone, read and then the end of
# the run (the host side's comment says why).
if [ "${H2_DMSG_CLUSTERFD:-0}" = 1 ]; then
	command -v socat >/dev/null 2>&1 || { echo "dmsg: COULD-NOT-RUN: no socat on the guest" >&2; exit 2; }
	command -v bash >/dev/null 2>&1 || { echo "dmsg: COULD-NOT-RUN: no bash on the guest" >&2; exit 2; }
	mkdir -p $M
	socat -u TCP-LISTEN:7999,bind=127.0.0.1,reuseaddr,fork OPEN:/dev/null >/dev/null 2>&1 &
	SPID=$!
	i=0
	until bash -c 'exec 3<>/dev/tcp/127.0.0.1/7999' 2>/dev/null; do
		sleep 0.1; i=$((i + 1))
		[ $i -gt 50 ] && { echo "dmsg: COULD-NOT-RUN: socat did not listen on 127.0.0.1:7999" >&2; kill $SPID; exit 2; }
	done
	bash -c 'exec 3<>/dev/tcp/127.0.0.1/7999 || exit 99; exec mount -t hammer2 -o cluster_fd=3 /dev/vdb@ROOT /mnt/h2d' > /tmp/fdmount.out 2>&1 &
	MPID=$!
	t=0
	while kill -0 $MPID 2>/dev/null && [ $t -lt "${H2_FD_TENTHS:-300}" ]; do sleep 0.1; t=$((t + 1)); done
	if kill -0 $MPID 2>/dev/null; then
		echo "fdmount-returned no"
	else
		wait $MPID; echo "fdmount-returned yes rc=$?"
	fi
	echo "fdmount-seconds $((t / 10))"
	sed 's/^/fdmount-said /' /tmp/fdmount.out
	n=0
	for s in /proc/[0-9]*/stack; do
		grep -qE 'hammer2_cluster_reconnect|hammer2_link_work' "$s" 2>/dev/null || continue
		p=${s#/proc/}; p=${p%/stack}; n=$((n + 1))
		echo "fdmount-task pid=$p state=$(awk '{print $3}' /proc/$p/stat) comm=$(cat /proc/$p/comm)"
		sed 's/^/fdmount-frame /' "$s"	# whole: __sched frames such as the rwsem slowpath are not in it
	done
	echo "fdmount-tasks $n"
	sleep 1
	echo "fdmount-lockdep $(grep -c 'possible recursive locking detected' $K)"
	echo "fdmount-mntlk-lines $(grep -c '(h2_mnt)' $K)"	# hammer2_mntlk's lockdep name
	echo "fdmount-badfd $(grep -c 'bad cluster_fd' $K)"
	if ! kill -0 $MPID 2>/dev/null; then
		# The link is up when its two message threads run, which only the
		# reconnect tail starts; the work runs after the mount returns.
		t=0
		while [ "$(threads)" != 2 ] && [ $t -lt "${H2_FD_TENTHS:-300}" ]; do sleep 0.1; t=$((t + 1)); done
		echo "fdmount-threads $(threads)"
		timeout 60 umount $M 2>/dev/null; echo "fdmount-umount $?"	# the host's detach_disk unloads
		echo "fdmount-threads-after $(threads)"
	fi
	kill $SPID 2>/dev/null
	exit 0
fi
mkdir -p $M
mount -t hammer2 /dev/vdb@ROOT $M || { echo "mount failed"; exit 1; }
hammer2 -s $M pfs-create SP >/dev/null 2>&1
echo "pfs-count $(hammer2 -s $M pfs-list 2>/dev/null | awk 'NR>1' | grep -c .)"
echo "threads-before $(threads)"

# stage 2a: a tree the HM2 client reads back beside what the guest itself
# sees of it: forty entries so a readdir crosses the window twice, three
# blocks of random bytes so the data is stored as written and its digest
# is the file's.  The server's bound is shortened so the window reading
# does not wait ten seconds.
mkdir -p $M/d
i=1; while [ $i -le 40 ]; do echo "$i" > $M/d/f$i; i=$((i + 1)); done
dd if=/dev/urandom of=$M/big bs=65536 count=3 2>/dev/null
sync
# The server serves a mounted PFS only with an enabled copyinfo[] row for
# its cluster id (stage 5.5, rule 4); the path is never dialed here.
echo "hm2-row $(/tmp/h2service add $M --clid "$(hammer2 -s $M pfs-clid ROOT 2>/dev/null)" --label peer --path span:127.0.0.1:1 2>&1 | tr '\n' ' ')"
echo 3000 > /sys/module/hammer2/parameters/remote_timeout_ms 2>/dev/null
echo "remote-timeout $(cat /sys/module/hammer2/parameters/remote_timeout_ms 2>/dev/null)"
RI=$(stat -c %i $M); DI=$(stat -c %i $M/d); BI=$(stat -c %i $M/big)
echo "root-inum $RI"; echo "dir-inum $DI"; echo "big-inum $BI"
echo "big-sha $(sha256sum $M/big | cut -d' ' -f1)"
echo "f7-inum $(stat -c %i $M/d/f7)"
echo "f7-size $(stat -c %s $M/d/f7)"
stat -c '%i %n' $M/d/* | sed 's| .*/| |' | sort > /tmp/stat-d.txt
echo "dir-entries $(wc -l < /tmp/stat-d.txt)"

# the refusal, then each action; a second after each for the threads to go
out=$($A --attach $M --action refuse 2>&1); echo "refuse-rc $?"; echo "refuse $out"
# each refusal of the TLS intake, one socket each, then its eight lines
out=$($A --attach $M --action tlsrefuse 2>&1); echo "tlsrefuse-rc $?"; echo "tlsrefuse $out"
sleep 1
echo "handshake-upcall $(grep -c ' handshake_req_alloc$' /proc/kallsyms)"
echo "log-tlsrefuse lines: all=$(klog 'cluster link refused:') tcp=$(klog 'refused: TLS needs a TCP socket') mode=$(klog 'refused: unknown cluster_tls mode') nkeys=$(klog 'refused: more key serials') client=$(klog 'refused: a client takes exactly one') server=$(klog 'refused: a server needs a keyring') role=$(klog 'refused: unknown cluster_tls_role') key=$(klog 'refused: a key serial must be positive') ulp=$(klog 'refused: the socket already carries') required=$(klog 'refused: cluster_tls_required is set') upcall=$(klog 'refused: this kernel has no handshake upcall') nobind=$(klog 'refused: a TLS intake binds no cluster id') dup=$(klog 'refused: a key serial is listed twice')"
for act in conn cancel badmagic badsize badaux halfclose close reconnect proto2 badcrc badcrc1 auxok auxbad spanlist span2on1 hm2proto1 hm2proto2; do
	out=$($A --attach $M --action $act --trace /tmp/h2attach-$act.trace 2>&1); rc=$?
	echo "$act-rc $rc"; echo "$act $out"
	sleep 1
	echo "$act-threads $(threads)"
done

# stage 2a: the HM2 XOP API, each reply beside the guest's own reading
hm2() {	# hm2 <name> <h2attach args>: the summary line, the output kept, the threads after
	n=$1; shift
	out=$($A --attach $M "$@" 2>&1); echo "$n-rc $?"
	printf '%s\n' "$out" > /tmp/$n.out
	echo "$n $(grep '^h2attach' /tmp/$n.out | head -1)"
	sleep 1; echo "$n-threads $(threads)"
}
hm2 hm2root --action hm2root --inum $RI
hm2 hm2readdir --action hm2readdir --inum $DI
sed -n 's/^ent inum=\([0-9]*\) .* name=\(.*\)$/\1 \2/p' /tmp/hm2readdir.out | sort > /tmp/hm2-d.txt
echo "hm2readdir-entries $(wc -l < /tmp/hm2-d.txt)"
if cmp -s /tmp/stat-d.txt /tmp/hm2-d.txt; then echo "hm2readdir-match 1"; else echo "hm2readdir-match 0"; fi
hm2 hm2nowindow --action hm2readdir --inum $DI --nocont 1 --wait-ms 8000
k=$(sed -n 's/^ent .* key=\([0-9a-f]*\) name=f7$/\1/p' /tmp/hm2readdir.out | head -1)
echo "f7-key $k"
hm2 hm2scanlhc --action hm2scanlhc --inum $DI --key 0x${k:-0}
echo "hm2scanlhc-f7 $(grep -c '^ent .* name=f7$' /tmp/hm2scanlhc.out)"
hm2 hm2nresolve --action hm2nresolve --inum $DI --name f7
hm2 hm2nresolve-missing --action hm2nresolve --inum $DI --name nosuch
hm2 hm2read --action hm2read --inum $BI --count 3 --out /tmp/hm2read.bin
echo "hm2read-sha $(sha256sum /tmp/hm2read.bin 2>/dev/null | cut -d' ' -f1)"
hm2 hm2scanall --action hm2scanall --inum $BI
echo "hm2scanall-keys $(sed -n 's/^blk key=\([0-9a-f]*\) .*/\1/p' /tmp/hm2scanall.out | tr '\n' ' ')"
echo "hm2scanall-off1 $(sed -n 's/^blk key=0000000000010000 .* data_off=\([0-9a-f]*\).*/\1/p' /tmp/hm2scanall.out | head -1)"
hm2 hm2lookup --action hm2lookup --inum $BI --key 0x10000
hm2 hm2bmap --action hm2bmap --inum $BI --key 1
hm2 hm2refuse --action hm2refuse --inum $RI
echo "log-serve $(klog 'H2 SERVE')"
echo "log-refused $(klog 'HM2 request .* refused: a modifying')"
echo "log-oneshot $(klog 'HM2 request .* refused: one-shot')"
echo "log-nopfs $(klog 'no mounted PFS of that cluster')"
echo "log-badmagic $(klog 'bad magic')"
echo "log-badsize $(klog 'bad header size')"
echo "log-badaux $(klog 'illegal msg payload size')"
echo "log-badcrc $(klog 'bad crc')"
echo "log-proto2 $(klog 'peer speaks DMSG_SPAN_PROTO_2')"
echo "log-spantab3 $(klog 'H2 SPANTAB 3')"
echo "log-spantab0 $(klog 'H2 SPANTAB 0')"
echo "log-spanlabels $(grep -o 'H2 SPAN type=6 label=h2attach-span-[123] pfs' $K | sort -u | wc -l)"
echo "log-span9 $(klog 'label=h2attach-span-9 ')"
echo "log-hm2proto1 $(klog 'on a PROTO_1 connection')"
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
echo "hold-start $(grep 'holding' /tmp/hold.out | head -1)"
echo "hold-threads-after $(threads)"
echo "log-shitcan-after $(klog shitcanning)"
echo "log-spantab0-after-hold $(klog 'H2 SPANTAB 0')"
echo "log-spanleft $(klog 'left after the connection closed')"
# the utility's own reading of the second block's offset, off the unmounted media
# the line is pinned to the utility's own shape (type.index data_off key/keybits)
# and kept whole beside the value read from it, so a changed shape is visible
echo "show-line $(hammer2 -v show /dev/vdb 2>/dev/null | grep -E '^ *data\.[0-9]+ +[0-9a-f]{16} +0000000000010000/' | head -1)"
echo "show-off1 $(hammer2 -v show /dev/vdb 2>/dev/null | grep -E '^ *data\.[0-9]+ +[0-9a-f]{16} +0000000000010000/' | head -1 | awk '{print $2}')"

# the control: the daemon closes first, and the unmount has nothing to wait for
mount -t hammer2 /dev/vdb@ROOT $M || { echo "remount failed"; exit 1; }
out=$($A --attach $M --action close 2>&1); echo "ctl-close-rc $?"; echo "ctl-close $out"
sleep 1
t0=$(date +%s%N); timeout 60 umount $M; urc=$?; t1=$(date +%s%N)
echo "ctl-umount-rc $urc"
echo "ctl-umount-ms $(( (t1 - t0) / 1000000 ))"
echo "ctl-threads-after $(threads)"
echo "log-shitcan-final $(klog shitcanning)"

finish
kill $KPID 2>/dev/null
GUEST

scp -q "$KO" "$GUEST_SSH:/tmp/hammer2.ko" && scp -q "$W/h2attach" "$W/h2service" "$GUEST_SSH:/tmp/" && scp -q "$W/guest.sh" "$GUEST_SSH:/tmp/h2dmsg.sh" || {
	echo "dmsg: COULD-NOT-RUN: copy to $GUEST failed" >&2; exit 2; }
if [ "${H2_DMSG_TLS:-0}" = 1 ]; then
	$RUN "$GUEST_SSH" 'rm -rf /tmp/h2peer && mkdir /tmp/h2peer' && scp -q test/h2attach.c src/sys/fs/hammer2/hammer2_ioctl.h src/sys/fs/hammer2/hammer2_disk.h "$GUEST_SSH:/tmp/h2peer/" || {
		echo "dmsg: COULD-NOT-RUN: copying the TLS peer's source to $GUEST failed" >&2; exit 2; }
fi
$RUN "$GUEST_SSH" "H2_DMSG_CLUSTERFD=${H2_DMSG_CLUSTERFD:-0} H2_DMSG_TLS=${H2_DMSG_TLS:-0} H2_FD_TENTHS=$FDT sh /tmp/h2dmsg.sh" > "$W/out" 2>&1
rc=$?
if [ "$rc" = 2 ] || command grep -q "COULD-NOT-RUN" "$W/out" 2>/dev/null; then
	command grep -m1 "COULD-NOT-RUN" "$W/out" >&2 || echo "dmsg: COULD-NOT-RUN: the guest half exited 2 without a reason" >&2
	detach_disk; exit 2
fi
stamp=$(date +%Y%m%d-%H%M%S)
scp -q "$GUEST_SSH:/tmp/h2dmsg.klog" "$FIXDIR/dmsg-run-$stamp.klog" 2>/dev/null && echo "  kept  the guest kernel log beside the images as dmsg-run-$stamp.klog"
{ echo "guest-kernel $guest_rel"; echo "module-vermagic $(modinfo -F vermagic "$KO" 2>/dev/null)"; cat "$W/out"; } > "$FIXDIR/dmsg-run-$stamp.out" 2>/dev/null
# H2_DMSG_CLUSTERFD=1 runs only the mount intake, cluster_fd=, which no other
# harness drives: a TCP connection to a silent listener on the guest's
# loopback is handed to the mount as descriptor 3. The mount holds
# hammer2_mntlk across that intake, and the reconnect tail's quiesce took it
# again on the same task until the tail moved to the device's work item
# (hammer2_iocom.c's hammer2_link_work()), which takes it by try-lock after
# the mount drops it. Absence passes trivially, so two checks are positive:
# the link's two message threads run after the mount, and the unmount then
# completes with none left. A mount still in the kernel is called the
# recursion only when a task sits in the intake or the link's work and
# lockdep reported it;
# otherwise the stop line says it is stuck elsewhere, beside the whole stack.
# Either way the guest is left as it is but for the listener, which is
# stopped; it is read live and reset by hand, never by this script.
if [ "${H2_DMSG_CLUSTERFD:-0}" = 1 ]; then
	sed -n 's/^fdmount-\(task\|frame\|said\) /  guest: \1 /p' "$W/out"
	v() { sed -n "s/^$1 //p" "$W/out" | head -1; }
	f=0
	r=$(v fdmount-returned)
	if [ "$r" = "yes rc=0" ]; then echo "  ok    the cluster_fd= mount returns: $r in $(v fdmount-seconds) s"
	else echo "  FAIL  the cluster_fd= mount returns: ${r:-unread} after $(v fdmount-seconds) s"; f=1; fi
	if [ "$(v fdmount-badfd)" = 0 ]; then echo "  ok    the descriptor was accepted"
	else echo "  FAIL  the descriptor was accepted: $(v fdmount-badfd) bad cluster_fd line(s)"; f=1; fi
	if [ "$(v fdmount-lockdep)" = 0 ]; then echo "  ok    no recursive-locking report"
	else echo "  FAIL  no recursive-locking report: $(v fdmount-lockdep), hammer2_mntlk (h2_mnt) named on $(v fdmount-mntlk-lines) line(s), $(v fdmount-tasks) task(s) in the intake or the link's work"; f=1; fi
	if [ "$(v fdmount-threads)" = 2 ]; then echo "  ok    the link's two message threads run after the mount"
	else echo "  FAIL  the link's two message threads run after the mount: $(v fdmount-threads | grep . || echo unread)"; f=1; fi
	if [ "$(v fdmount-umount)" = 0 ] && [ "$(v fdmount-threads-after)" = 0 ]; then echo "  ok    the unmount completes with no thread left"
	else echo "  FAIL  the unmount completes with no thread left: umount $(v fdmount-umount), threads $(v fdmount-threads-after)"; f=1; fi
	if [ "$r" = no ]; then
		if [ "$(v fdmount-tasks)" -ge 1 ] 2>/dev/null && [ "$(v fdmount-lockdep)" -ge 1 ] 2>/dev/null; then
			echo "dmsg: the mount is still in the kernel on $GUEST, in the intake or the link's work with lockdep's recursion reported; read it live, then $VIRSH destroy $GUEST and start it" >&2
		else
			echo "dmsg: the mount is still in the kernel on $GUEST but not as the recursion ($(v fdmount-tasks) task(s) in the intake or the link's work, $(v fdmount-lockdep) report(s)); read the stack above live, then $VIRSH destroy $GUEST and start it" >&2
		fi
		exit 1
	fi
	detach_disk
	echo "dmsg: cluster_fd= intake, $f failed"
	exit "$f"
fi
if [ "$rc" != 0 ]; then
	sed 's/^/  guest: /' "$W/out" >&2
	detach_disk
	echo "dmsg: COULD-NOT-RUN: the guest session ended rc=$rc, so the run did not finish" >&2
	exit 2
fi
detach_disk

val() { sed -n "s/^$1 //p" "$W/out" | head -1; }
nval() { grep -c -E "^$1( |$)" "$W/out"; }	# how many lines carry the name, with or without a value
field() { printf '%s\n' "$1" | sed -n "s/.*[ :]$2=\([-0-9]*\).*/\1/p" | head -1; }
fail=0; checks=0
check() {	# check <name> <0 ok / 1 fail> <reading>
	checks=$((checks + 1))
	if [ "$2" = 0 ]; then echo "  ok    $1: $3"; else echo "  FAIL  $1: $3"; fail=$((fail + 1)); fi
}
num() { case "$1" in ''|*[!0-9-]*) echo "$2";; *) echo "$1";; esac; }
# The end of every mode: warnings, kmemleak and the unload.
final_checks() {
[ "$(num "$(val kernel-warnings)" 1)" = 0 ]; check "no kernel warning, lockdep or sanitizer report" $? "$(val kernel-warnings)"
# Read as cluster-sync.sh reads it: a count is the reading, "unusable" is a
# failure on the kernels this runs on, which are built with it, and no
# value at all means the guest stopped before the scan.
c=$(grep -o kmemleak-cleared "$W/out" | wc -l); l=$(val kmemleak); m=$(nval kmemleak); u=$(val kmemleak-unloaded); n=$(nval kmemleak-unloaded); r=$(nval kmemleak-unloaded-range)	# counted by occurrence, so a second marker glued to a line or beside the first on one line is a second clear
case "$l" in
0) [ "$c" = 1 ] && [ "$m" = 1 ] && [ "$n" = 1 ] && [ "$r" = 1 ] && [ "${u:-1}" = 0 ]; check "kmemleak reports nothing of hammer2's" $? "cleared $c time(s), $l printed $m time(s), after the unload ${u:-unread}, printed $n time(s) after $r range line(s)" ;;
unusable) check "kmemleak is usable, so a leak would be reported" 1 "the scan refused" ;;
"") check "kmemleak was read before the unload" 1 "no reading before the unload, $n after it with $r range line(s)" ;;
*) check "kmemleak reports nothing of hammer2's" 1 "$l" ;;
esac
[ "$(val rmmod)" = ok ] && [ "$(num "$(val threads-final)" 9)" = 0 ]; check "the module unloads with no thread left" $? "rmmod $(val rmmod), $(val threads-final) threads"
}

# H2_DMSG_TLS=1, the TLS link (doc/CLUSTER_PROTOCOL_DESIGN.md, the TLS
# link; the expected readings were written before the first run).  One
# guest, vdb and vdc each mounted @ROOT, keys made on the guest and read
# back from a fresh session, tlshd answering for arms 1 to 5 and nothing
# or a stub for 6 to 9:
#   1  TLS on, server vdb and client vdc: both handed, tlshd's two
#      completions, kTLS installed on both sockets, the spans of both
#      volumes, and no frame magic in a capture holding TLS records; the
#      link read again after five keepalive intervals
#   2  a wrong PSK under the admitted identity, the first link live: both
#      ends refused as a failed handshake with a status, the first link
#      unchanged
#   4  a client identity held only in .nvme: tlshd completes, the server
#      refuses the reported serial as one it does not admit
#   3  the capture's control, both ends plaintext: the frame magic present
#   5  a revoked client key: one refusal, nothing handed
#   6  tlshd stopped: the intake refused ESRCH, not submitted
#   7  a stub that never accepts: the intake's deadline ends it, the
#      handshake cancelled once
#   8  the same, unmounted 2 s in: the unmount returns and cancels once
#   9  a stub that accepts and never answers, unmounted: the same
# The fake pass is two "handed" lines from two plaintext intakes, which
# kTLS's own counters, tlshd's two lines and the capture rule out.
if [ "${H2_DMSG_TLS:-0}" = 1 ]; then
	for p in 7997 7995; do
		scp -q "$GUEST_SSH:/tmp/h2tls-$p.pcap" "$FIXDIR/dmsg-run-$stamp-$p.pcap" 2>/dev/null && echo "  kept  the port $p capture as dmsg-run-$stamp-$p.pcap"
	done
	echo "hammer2 TLS link on $GUEST ($guest_rel):"
	rd() { sed -n "s/^tls-key $1 .* read=\([a-z]*\).*/\1/p" "$W/out" | head -1; }
	ser() { sed -n "s/^tls-key $1 \([^ ]*\) .*/\1/p" "$W/out" | head -1; }
	d() { echo $(( $(num "$(field " $(val "$1-after")" "$3")" -99) - $(num "$(field " $(val "$2-before")" "$3")" 99) )); }	# d <after-arm> <before-arm> <field>
	a() { num "$(field " $(val "$1-after")" "$2")" -1; }
	k4b=$(sed -n 's/^tls-key K4-before-revoke .* read=\([a-z]*\).*/\1/p' "$W/out" | head -1)
	[ "$(rd K1)" = ok ] && [ "$(rd K2)" = ok ] && [ "$k4b" = ok ] && [ "$(rd K4)" = fail ]; check "the keys read back from a fresh session, the revoked one refused after reading before" $? "K1 $(rd K1), K2 $(rd K2), K4 ${k4b:-unread} before its revoke and $(rd K4) after"
	nb=$(num "$(val pfs-count-b)" 0); nc=$(num "$(val pfs-count-c)" 0)

	r=$(val arm1)
	[ "$(field "$r" server)" = 0 ] && [ "$(field "$r" client)" = 0 ]; check "arm 1: both TLS intakes return 0" $? "$r"
	[ "$(d arm1-up arm1 handed)" = 2 ]; check "arm 1: both ends are handed to the message threads" $? "$(d arm1-up arm1 handed) line(s) in $(val arm1-wait-handed) s"
	[ "$(d arm1 arm1 ok)" = 2 ] && [ "$(d arm1 arm1 failed)" = 0 ]; check "arm 1: tlshd completes both handshakes and fails none" $? "$(d arm1 arm1 ok) succeeded, $(d arm1 arm1 failed) failed"
	[ "$(d arm1-up arm1 tx)" = 2 ] && [ "$(d arm1-up arm1 rx)" = 2 ]; check "arm 1: kTLS is installed on both sockets" $? "TlsCurrTxSw and TlsCurrRxSw up by $(d arm1-up arm1 tx) and $(d arm1-up arm1 rx)"
	# Each key is bound to both ROOTs (stage 5.5), so each end announces
	# its ROOT alone, whatever else its volume holds.
	[ "$(a arm1-up rxspan)" = 2 ] && [ "$(a arm1-up spanrefused)" = 0 ] && [ "$(a arm1-up proto2)" = 2 ]; check "arm 1: each end receives the other volume's bound span, its ROOT, over PROTO_2" $? "$(a arm1-up rxspan) spans of 2, against $nb + $nc PFSs on the volumes, $(a arm1-up spanrefused) refused, $(a arm1-up proto2) PROTO_2 line(s)"
	[ "$(a arm1 threads)" = 4 ] && [ "$(d arm1 arm1 silent)" = 0 ] && [ "$(d arm1 arm1 terminated)" = 0 ]; check "arm 1: the link is up after five keepalive intervals" $? "threads $(a arm1 threads), peer-silent $(d arm1 arm1 silent), terminated $(d arm1 arm1 terminated)"
	c=$(val arm1-capture)
	# The handshake's own encrypted messages are three type-23 records
	# (EncryptedExtensions and two Finished), so data needs a fourth.
	[ "$(field " $c" magic)" = 0 ] && [ "$(num "$(field " $c" tlsapp)" 0)" -ge 4 ]; check "arm 1: the capture holds type-23 TLS records past the handshake's three and no frame magic" $? "$c"

	r=$(val arm2)
	[ "$(field "$r" server)" = 0 ] && [ "$(field "$r" client)" = 0 ]; check "arm 2: the wrong-PSK intakes return 0, the handshake being asynchronous" $? "$r"
	n=$(grep '^arm2-line ' "$W/out" | grep -vc 'status 0,')
	[ "$(d arm2 arm2 refused)" = 2 ] && [ "$n" = 2 ] && [ "$(d arm2 arm2 failed)" = 2 ]; check "arm 2: both ends are refused as a failed handshake with a status, tlshd failing both" $? "$(d arm2 arm2 refused) refusal(s), $n with a nonzero status, tlshd $(d arm2 arm2 failed) failed"
	[ "$(a arm2 threads)" = 4 ] && [ "$(d arm2 arm2 silent)" = 0 ] && [ "$(d arm2 arm2 handed)" = 0 ] && [ "$(a arm2 tx)" = 2 ] && [ "$(a arm2 rx)" = 2 ]; check "arm 2: the first link carries on" $? "threads $(a arm2 threads), peer-silent $(d arm2 arm2 silent), handed $(d arm2 arm2 handed), kTLS $(a arm2 tx)/$(a arm2 rx)"

	if [ "$(val arm4-driven)" = 0 ]; then
		echo "  skip  arm 4: no key could be made in .nvme: $(sed -n 's/^tls-key K3 none .*refused=//p' "$W/out")"
		skipped=1
	else
		k3=$(ser K3); r=$(val arm4)
		[ "$(field "$r" server)" = 0 ] && [ "$(field "$r" client)" = 0 ] && [ "$(rd K3)" = ok ]; check "arm 4: the .nvme key reads back and both intakes return 0" $? "K3 $(rd K3), $r"
		n=$(grep '^arm4-line ' "$W/out" | grep -c "(status 0, peer key $k3)")
		[ "$(d arm4 arm4 refused)" = 1 ] && [ "$n" = 1 ] && [ "$(d arm4 arm4 ok)" = 2 ]; check "arm 4: tlshd completes and the server refuses the .nvme serial it reports" $? "$(d arm4 arm4 refused) refusal(s), $n naming K3 $k3, tlshd $(d arm4 arm4 ok) succeeded"
		[ "$(d arm4 arm4 handed)" = 1 ]; check "arm 4: the client end, whose handshake succeeded, is handed" $? "$(d arm4 arm4 handed)"
	fi

	r=$(val arm3); c=$(val arm3-capture)
	[ "$(field "$r" server)" = 0 ] && [ "$(field "$r" client)" = 0 ] && [ "$(d arm3 arm3 handed)" = 2 ] && [ "$(a arm3 threads)" = 4 ]; check "arm 3: the plaintext control replaces both links" $? "$r, handed $(d arm3 arm3 handed), threads $(a arm3 threads)"
	[ "$(num "$(field " $c" magic)" 0)" -ge 2 ]; check "arm 3: the plaintext capture holds the frame magic, so the reading in arm 1 can see it" $? "$c"
	[ "$(a arm3 tx)" = 0 ] && [ "$(a arm3 rx)" = 0 ]; check "arm 3: kTLS is released with the TLS sockets" $? "TlsCurrTxSw $(a arm3 tx), TlsCurrRxSw $(a arm3 rx)"

	# Arms 10 to 14, the reader on a TLS link.  The line counts are the
	# whole log's, so each arm reads all five and a stray line fails it.
	po() { sed -n "s/^$1-out h2attach tlspeer: //p" "$W/out" | grep "$2" | head -1; }
	lc() { field " $(val $1-lines)" $2; }
	for arm in arm10 arm11 arm12 arm13 arm14; do
		h=$(po $arm 'handshake='); x=$(po $arm 'send=')
		[ "$(field " $(po $arm 'errno=')" errno)" = 0 ] && [ "$(field " $h" handshake)" = 0 ] && [ "$(field " $h" match)" = 1 ] && [ "$(field " $x" conn)" = 1 ] && [ "$(field " $x" spans)" = 1 ] && [ "$(field " $x" shell1)" = 1 ] && [ "$(field " $x" err1)" = 32 ] && [ "$(field " $x" rc)" = 0 ]
		check "$arm: tlshd and the GnuTLS peer agree on K1, the link serves a DBG_SHELL, and the record is sent" $? "${h:-no handshake line}; ${x:-no result line}"
		[ "$(a $arm threads)" = 0 ] && [ "$(d $arm $arm handed)" = 1 ]; check "$arm: the link is handed once and leaves no thread" $? "handed $(d $arm $arm handed), threads $(a $arm threads)"
	done
	x=$(po arm10 'send=')
	[ "$(field " $x" shell2)" = 1 ] && [ "$(field " $x" err2)" = 32 ] && [ "$(lc arm10 dropped)$(lc arm10 keyupdate)$(lc arm10 alert)$(lc arm10 ended)$(lc arm10 other)" = 00000 ]; check "arm 10: with no record sent the link serves a second DBG_SHELL and names no record" $? "shell2 $(field " $x" shell2) err2 $(field " $x" err2); $(val arm10-lines)"
	x=$(po arm11 'send=')
	[ "$(field " $x" shell2)" = 1 ] && [ "$(field " $x" err2)" = 32 ] && [ "$(lc arm11 dropped)$(lc arm11 keyupdate)$(lc arm11 alert)$(lc arm11 ended)$(lc arm11 other)" = 10000 ]; check "arm 11: a NewSessionTicket is dropped with its line and the link serves on" $? "shell2 $(field " $x" shell2) err2 $(field " $x" err2); $(val arm11-lines)"
	x=$(po arm12 'send=')
	[ "$(field " $x" eof)" = 1 ] && [ "$(num "$(field " $x" ms)" 99999)" -lt 2000 ] && [ "$(lc arm12 dropped)$(lc arm12 keyupdate)$(lc arm12 alert)$(lc arm12 ended)$(lc arm12 other)" = 11000 ] && [ "$(lc arm12 rekey)" = 1 ]; check "arm 12: a KeyUpdate ends the link with its line, kTLS counting it received" $? "eof $(field " $x" eof) after $(field " $x" ms) ms; $(val arm12-lines)"
	x=$(po arm13 'send=')
	[ "$(field " $x" eof)" = 1 ] && [ "$(num "$(field " $x" ms)" 99999)" -lt 2000 ] && [ "$(lc arm13 dropped)$(lc arm13 keyupdate)$(lc arm13 alert)$(lc arm13 ended)$(lc arm13 other)" = 11100 ]; check "arm 13: a fatal alert ends the link with its line" $? "eof $(field " $x" eof) after $(field " $x" ms) ms; $(val arm13-lines)"
	x=$(po arm14 'send=')
	[ "$(field " $x" eof)" = 1 ] && [ "$(num "$(field " $x" ms)" 99999)" -lt 2000 ] && [ "$(lc arm14 dropped)$(lc arm14 keyupdate)$(lc arm14 alert)$(lc arm14 ended)$(lc arm14 other)" = 11110 ]; check "arm 14: user_canceled then close_notify end the link cleanly, with no error line" $? "eof $(field " $x" eof) after $(field " $x" ms) ms; $(val arm14-lines)"

	w5=$(val arm5-wait-refused); case "$(val arm5-line)" in *'the handshake failed'*) l5=1 ;; *) l5=0 ;; esac
	[ "$l5" = 1 ] && [ "$(num "$(val arm5-keyfail)" 0)" -ge 1 ] && [ "${w5%%.*}" -lt 10 ] 2>/dev/null; check "arm 5: the refusal is a failed handshake within 10 s, tlshd unable to read the revoked key" $? "line '$(val arm5-line | sed 's/.*refused: //')', $(val arm5-keyfail) revoked-key line(s) in tlshd, after $w5 s"
	[ "$(field "$(val arm5-intake)" errno)" = 0 ] && [ "$(d arm5 arm5 refused)" = 1 ] && [ "$(d arm5 arm5 handed)" = 0 ] && [ "$(a arm5 threads)" = "$(num "$(field " $(val arm5-before)" threads)" -2)" ]; check "arm 5: a revoked key is refused once, nothing handed, the link kept" $? "$(val arm5-intake), $(d arm5 arm5 refused) refusal(s), handed $(d arm5 arm5 handed), threads $(a arm5 threads)"
	echo "        arm 5 line: $(val arm5-line)"

	[ "$(val arm6-tlshd)" = 0 ] && [ "$(field "$(val arm6-intake)" errno)" = 3 ] && [ "$(val arm6-notsubmitted)" = 1 ]; check "arm 6: with no agent the intake is refused ESRCH, not submitted" $? "tlshd $(val arm6-tlshd), $(val arm6-intake), $(val arm6-notsubmitted) line(s)"

	tm=$(num "$(val tls-timeout-ms)" 10000); ms=$(num "$(val arm7-ms)" 0)
	[ "$(grep -c '^stub0-start .*joined' "$W/out")" = 1 ]; check "the stub agent joins the handshake family's tlshd group" $? "$(val stub0-start)"
	n=$(grep '^arm7-line ' "$W/out" | grep -c '(status -115, peer key 0)')
	[ "$(field "$(val arm7-intake)" errno)" = 0 ] && [ "$n" = 1 ] && [ "$ms" -ge $((tm - 500)) ] && [ "$ms" -le $((tm + 3000)) ]; check "arm 7: a request no agent accepts times out at the intake's deadline" $? "$n line(s) at status -115, after $ms ms against $tm"
	[ "$(val arm7-cancels)" = 1 ]; check "arm 7: the timeout cancels the request once" $? "$(val arm7-cancels) handshake_cancel event(s)"

	for arm in arm8 arm9; do
		u=$(val $arm-umount); c=$(val $arm-cancels)
		case $arm in arm8) what="arm 8: the unmount under a pending request" ;; *) what="arm 9: the unmount under an accepted request" ;; esac
		[ "$(field " $u" rc)" = 0 ] && [ "$(num "$(field " $u" ms)" 99999)" -lt 5000 ] && [ "$(echo "$c" | cut -d' ' -f1)" = 1 ]; check "$what returns and cancels it once" $? "$u, $(echo "$c" | cut -d' ' -f1) handshake_cancel event(s)"
	done
	[ "$(a arm8 threads)" = 0 ]; check "arm 8: no message thread is left after the unmount" $? "$(a arm8 threads)"
	lt=$(val late-timedout)
	[ "$(num "$(field " $lt" new)" 1)" = 0 ] && [ "$(echo "$lt" | sed -n 's/^waited=\(-*[0-9]*\)s.*/\1/p')" != "" ]; check "arms 8 and 9: no timed-out line once the later deadline has passed" $? "$lt"
	[ "$(num "$(sed -n 's/.*accepted fd=\([0-9-]*\).*/\1/p' "$W/out" | head -1)" -1)" -ge 0 ]; check "arm 9: the stub accepted the request and held its descriptor" $? "$(val arm9-accepted)"
	[ "$(val tlshd-restored)" = 1 ]; check "tlshd is running again under s6-supervise" $? "$(val tlshd-restored)"

	# Stage 5.5's controls, the committed side of each; the expected
	# readings are p7-notes/n9-5-controls-expected.md in the data tree.
	dd() { echo $(( $(a "$1" "$3") - $(a "$2" "$3") )); }	# dd <later> <earlier> <field>, both after lines
	ids=$(val s55-clids); xb=$(printf '%s\n' "$ids" | sed -n 's/.*rootb=\([^ ]*\).*/\1/p')
	[ "$(num "$(val pfs-count-b)" 0)" -ge 5 ] && [ "$(a arm1-up rxspan)" = 2 ]; check "stage 5.5: vdb's PFSs no key binds are not announced on the TLS link" $? "$(val pfs-count-b) PFSs on vdb, $(a arm1-up rxspan) spans received in all"
	[ "$(d s55rev-up s55rev handed)" = 2 ]; check "s55rev: a fresh key's link is handed at both ends" $? "handed +$(d s55rev-up s55rev handed)"
	[ "$(dd s55rev s55rev-up handed)" = 0 ] && [ "$(dd s55rev s55rev-up refused)" -ge 1 ] && [ "$(num "$(val s55rev-keyfail)" 0)" -ge 1 ]; check "s55rev: once the key is revoked the next handshake fails and nothing is handed" $? "handed +$(dd s55rev s55rev-up handed), refused +$(dd s55rev s55rev-up refused), tlshd revoked-key lines $(val s55rev-keyfail)"
	[ "$(a s55rev threads)" = 4 ] && [ "$(dd s55rev s55rev-up terminated)" = 0 ] && [ "$(dd s55rev s55rev-up silent)" = 0 ]; check "s55rev: the first link carries on after the revoked key's failure" $? "threads $(a s55rev threads), terminated +$(dd s55rev s55rev-up terminated), silent +$(dd s55rev s55rev-up silent)"
	sp=$(sed -n 's/^s55peer-out-[0-9]* h2attach tlspeer: spans //p' "$W/out" | head -1)
	vcs=$(printf '%s\n' "$sp" | sed -n 's/.* volconf=\([^ ]*\).*/\1/p')
	case "$(val s55peer-w-add)$(val s55peer-w-del)" in *'added copyid='*'deleted copyid='*) r=0 ;; *) r=1 ;; esac
	check "s55peer: the unbound row W is added and deleted while the link lingers" $r "$(val s55peer-w-add) / $(val s55peer-w-del)"
	[ -n "$xb" ] && [ "$vcs" = "$xb:1" ]; check "s55peer: the TLS link carries the bound cluster's row once, and no row of Z or W" $? "volconf $vcs, bound $xb"
	l=$(val s55peer-lines)
	[ "$(num "$(field " $sp" conn2)" 0)" = 1 ] && [ "$(num "$(field " $l" spanrefused)" -1)" = 1 ] && [ "$(num "$(field " $l" listed22)" -1)" = 0 ] && [ "$(num "$(field " $l" listed21)" 0)" -ge 1 ]; check "s55peer: a span for a cluster the key does not bind is refused and never listed, the bound one listed" $? "$l"
	[ "$(num "$(field " $l" monitored)" -1)" = 1 ] && [ "$(num "$(field " $sp" hm2rx)" -1)" = 0 ]; check "s55peer: a MASTER span over a SLAVE row is monitored, not registered" $? "monitored $(field " $l" monitored), HM2 requests received $(field " $sp" hm2rx)"
	n=$(val s55a-norow); s=$(val s55a-served)
	[ "$(num "$(field "$n" refused)" 0)" = 1 ] && [ "$(num "$(val s55a-lines | sed 's/.*norow=//')" 0)" = 1 ]; check "s55a: a plaintext peer is refused a mounted PFS with no copyinfo row, with its line" $? "$n; $(val s55a-lines)"
	[ "$(num "$(field "$s" found)" 0)" = 1 ] && [ "$(num "$(field "$s" error)" 1)" = 0 ]; check "s55a: with an enabled row for its cluster the same request is served" $? "$s"
	sb() { sed -n "s/^$1-[0-9]* h2attach hm2snap: //p" "$W/out" | grep -- "$2" | head -1; }
	served() { [ "$(num "$(field "$1" closed)" 0)" = 1 ] && [ "$(num "$(field "$1" refused)" 1)" = 0 ] && [ "$(num "$(field "$1" error)" 1)" = 0 ] && [ "$(num "$(field "$1" inodes)" 0)" = 1 ]; }
	unserved() { [ "$(num "$(field "$1" closed)" 0)" = 1 ] && [ "$(num "$(field "$1" error)" 0)" != 0 ] && [ "$(num "$(field "$1" inodes)" 1)" = 0 ]; }
	b1=$(sb s55b 'n=1 '); b2=$(sb s55b 'n=2 '); bl=$(val s55b-left)
	served "$b1" && served "$b2" && [ "$(num "$(field " $b2" on_media)" 0)" = 1 ] && [ "$(num "$(field " $b2" subtype)" -1)" = 1 ]; check "s55b: a MASTER source with a row is snapshotted twice on one link, as ROOT.h2sync-peer of subtype snapshot" $? "$b1 / $b2"
	[ "$(num "$(field " $bl" n)" -1)" = 1 ] && [ "$(num "$(field " $bl" err0)" -1)" = 1 ] && [ "$(num "$(field " $bl" listed)" -1)" = 0 ]; check "s55b: the link's end deletes its one snapshot of the source once, error 0" $? "$bl"
	c1=$(sb s55c 'n=1 '); cd=$(sb s55c 'done '); cl=$(val s55c-left)
	served "$c1" && [ "$(num "$(field " $cd" del_closed)" 0)" = 1 ] && [ "$(num "$(field " $cd" del_refused)" 1)" = 0 ] && [ "$(num "$(field " $cd" after_del)" 1)" = 0 ] && [ "$(num "$(field " $cl" n)" -1)" = 0 ] && [ "$(num "$(field " $cl" listed)" -1)" = 0 ]; check "s55c: SNAPDEL by the snapshot's own cluster id deletes it, and the link's end has nothing left" $? "$c1 / $cd / $cl"
	d1=$(sb s55d 'n=1 '); dl=$(val s55d-lines)
	[ "$(val s55d-mount | cut -d' ' -f1)" = 0 ] && unserved "$d1" && [ "$(num "$(field " $dl" notmaster)" -1)" = 1 ] && [ "$(num "$(field " $dl" listed)" -1)" = 0 ]; check "s55d: a mounted SLAVE element with a row is refused a snapshot, with its line" $? "mount $(val s55d-mount); $d1; $dl"
	e1=$(sb s55e 'n=1 ')
	[ "$(num "$(field "$e1" refused)" 0)" = 1 ] && [ "$(num "$(val s55e-after | sed 's/.*listed=//')" 0)" = 1 ]; check "s55e: an unmounted local source named by its cluster id is refused and survives" $? "$e1; $(val s55e-after)"
	f1=$(sb s55f 'n=1 '); fl=$(val s55f-lines)
	[ "$(val s55f-mount)" = 0 ] && unserved "$f1" && [ "$(num "$(field " $fl" kept)" -1)" = 1 ] && [ "$(num "$(field " $fl" listed)" -1)" = 1 ] && [ "$(num "$(field " $f1" subtype)" -1)" = 0 ]; check "s55f: a MASTER PFS holding the peer name is kept and the snapshot refused" $? "mount $(val s55f-mount); $f1; $fl"
	h2=$(sb s55h2 'done '); hl=$(val s55h2-lines)
	[ "$(num "$(field " $h2" del_closed)" 0)" = 1 ] && [ "$(num "$(field " $h2" del_error)" 1)" = 0 ] && [ "$(num "$(field " $hl" notours)" -1)" = 1 ] && [ "$(num "$(field " $hl" cl-listed)" -1)" = 1 ]; check "s55h2: SNAPDEL naming a mounted PFS the link never took deletes nothing" $? "$h2; $hl"
	g1=$(sb s55g 'n=1 '); gl=$(val s55g-lines)
	[ "$(val s55g-mount | cut -d' ' -f1)" = 0 ] && unserved "$g1" && [ "$(num "$(field " $gl" long)" -1)" = 1 ] && [ "$(num "$(field " $gl" listed)" -1)" = 0 ]; check "s55g: a source labeled 128 bytes is refused a snapshot, with its line" $? "mount $(val s55g-mount); $g1; $gl"
	h1=$(sb s55h1 'done ')
	[ "$(val s55h1-decoy-rc)" = 0 ] && [ "$(num "$(field " $h1" del_refused)" 0)" = 1 ] && [ "$(num "$(val s55h1-after | sed 's/.*listed=//')" 0)" = 1 ]; check "s55h1: SNAPDEL of an unmounted snapshot the link never took is refused and the snapshot kept" $? "decoy rc $(val s55h1-decoy-rc); $h1; $(val s55h1-after)"
	i=$(val s55i); ok=0
	for f in create-src create-peer snap-src snap-peer; do [ "$(num "$(field " $i" $f)" 0)" != 0 ] || ok=1; done
	[ "$(num "$(field " $i" listed)" -1)" = 0 ] || ok=1
	check "s55i: pfs-create and the snapshot ioctl refuse both reserved suffixes" $ok "$i"
	j=$(val s55j)
	[ "$(num "$(field " $j" rc)" 0)" != 0 ] && printf '%s\n' "$j" | grep -q 'cluster_tls_clid before any cluster_tls_key'; check "s55j: a mount naming cluster_tls_clid before any cluster_tls_key is refused, with its reason" $? "$j"
	final_checks
	echo "dmsg: TLS link, $checks check(s), $fail failed${skipped:+, arm 4 not driven}"
	[ "$fail" -eq 0 ] || exit 1
	[ -z "${skipped:-}" ] || exit 2
	exit 0
fi

echo "hammer2 message core on $GUEST ($guest_rel):"
npfs=$(num "$(val pfs-count)" 0)
[ "$npfs" -ge 2 ]; check "the volume has two PFSs for the span count" $? "$npfs"

r=$(val refuse); pe=$(num "$(field "$r" pipe_errno)" -1); se=$(num "$(field "$r" sock_errno)" -1)
[ "$pe" = 22 ] && [ "$se" = 22 ]; check "a pipe and an unconnected socket are refused EINVAL" $? "pipe errno $pe, socket errno $se"

# The TLS intake's refusals (doc/CLUSTER_PROTOCOL_DESIGN.md, the TLS link):
# each is made before anything is submitted, so no handshake agent is
# needed, and each prints its own line, unlimited (hprintf_each), so each
# is counted exactly.
t=$(val tlsrefuse); l=$(val log-tlsrefuse); hs=$(num "$(val handshake-upcall)" -1)
[ "$(num "$(field "$t" req_set)" -1)" = 1 ] && [ "$(num "$(field "$t" req_after)" -1)" = 0 ]; check "cluster_tls_required read 1 for its call and 0 after, so the suite after it runs with it clear" $? "set $(field "$t" req_set), after $(field "$t" req_after)"
[ "$(num "$(field "$t" plain)" -1)" = 0 ]; check "a plaintext intake with nkeys 1000 and positive bytes past keys[] is admitted, its key fields unread" $? "errno $(field "$t" plain)"
if [ "$hs" = 1 ]; then
	ok=0; for f in unix mode nkeys client server role key required; do [ "$(num "$(field "$t" $f)" -1)" = 22 ] || ok=1; done
	check "the TLS intake refuses PSK on AF_UNIX, an unknown mode, six keys, a keyless client, a ringless server, an unknown role, a key serial of 0 and no TLS under cluster_tls_required, each EINVAL" $ok "$(echo "$t" | sed 's/.*tlsrefuse: //')"
	[ "$(num "$(field "$t" ulp_set)" -1)" = 0 ] && [ "$(num "$(field "$t" ulp)" -1)" = 16 ]; check "a TCP socket already carrying the tls ULP is refused EBUSY" $? "ulp_set $(field "$t" ulp_set), errno $(field "$t" ulp)"
	[ "$(num "$(field "$t" nobind)" -1)" = 22 ] && [ "$(num "$(field "$t" dup)" -1)" = 22 ]; check "stage 5.5: a TLS intake binding no cluster id, and a server's listing one key serial twice, are each refused EINVAL" $? "nobind $(field "$t" nobind), dup $(field "$t" dup)"
	ok=0; [ "$(num "$(field "$l" all)" -1)" = 11 ] && [ "$(num "$(field "$l" upcall)" -1)" = 0 ] || ok=1
	for f in tcp mode nkeys client server role key ulp required nobind dup; do [ "$(num "$(field "$l" $f)" -1)" = 1 ] || ok=1; done
	check "the log names each of the eleven TLS intake refusals once and no other" $ok "$l"
elif [ "$hs" = 0 ]; then
	# No NET_HANDSHAKE: the mode and the parameter are read first, and
	# every other PSK intake is refused EOPNOTSUPP before its socket is.
	ok=0; for f in mode required; do [ "$(num "$(field "$t" $f)" -1)" = 22 ] || ok=1; done
	for f in unix nkeys client server role key ulp nobind dup; do [ "$(num "$(field "$t" $f)" -1)" = 95 ] || ok=1; done
	check "without the handshake upcall every PSK intake is refused EOPNOTSUPP, an unknown mode and no TLS under cluster_tls_required EINVAL" $ok "$(echo "$t" | sed 's/.*tlsrefuse: //')"
	ok=0; [ "$(num "$(field "$l" all)" -1)" = 11 ] && [ "$(num "$(field "$l" upcall)" -1)" = 9 ] && [ "$(num "$(field "$l" mode)" -1)" = 1 ] && [ "$(num "$(field "$l" required)" -1)" = 1 ] || ok=1
	check "the log names nine upcall refusals, the mode's and the parameter's" $ok "$l"
else
	check "the guest's kernel symbols say whether it has the handshake upcall" 1 "handshake_req_alloc lines: $(val handshake-upcall)"
fi

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
# behavior, and a frame in the HM2 space on one ends it.  After a frame the
# kernel may refuse, h2attach sends a DBG_SHELL and reads whether its NOSUPP
# result comes, since "no EOF yet" and "consumed and still serving" read the
# same until the next frame is answered.  Under H2_CRC_CONTROL=1 the CRC
# check is compiled out and both bad frames must pass and the DBG_SHELL be
# served, which is what proves the check is what ends them.
m=$(val proto2)
[ "$(num "$(field "$m" conn2_reply)" 0)" = 1 ] && [ "$(num "$(field "$m" shell_error)" 0)" = 32 ]; check "PROTO_2: the peer's LNK_CONN is answered and the frame after it is served" $? "conn2_reply $(field "$m" conn2_reply), shell_error $(field "$m" shell_error)"
[ "$(num "$(val log-proto2)" 0)" -ge 1 ]; check "PROTO_2: the kernel names the peer's protocol in its log" $? "$(val log-proto2) line(s)"
m=$(val badcrc); a=$(val auxbad)
if [ -n "${H2_CRC_CONTROL:-}" ]; then
	[ "$(num "$(field "$m" conn2_reply)" 0)" = 1 ] && [ "$(num "$(field "$m" eof)" 1)" = 0 ] && [ "$(num "$(field "$m" shell_reply)" 0)" = 1 ] && [ "$(num "$(val log-badcrc)" 1)" = 0 ]; check "control: with the CRC check compiled out the bad header CRC is consumed and the next frame served" $? "conn2_reply $(field "$m" conn2_reply), eof $(field "$m" eof), shell_reply $(field "$m" shell_reply), $(val log-badcrc) log line(s)"
	[ "$(num "$(field "$a" aux_reply)" 0)" = 1 ] && [ "$(num "$(field "$a" eof)" 1)" = 0 ]; check "control: the bad aux CRC is served too" $? "aux_reply $(field "$a" aux_reply), eof $(field "$a" eof)"
else
	[ "$(num "$(field "$m" eof)" 0)" = 1 ] && [ "$(num "$(field "$m" shell_reply)" 1)" = 0 ]; check "PROTO_2: a flipped header CRC ends the connection, the frame after it unanswered" $? "eof $(field "$m" eof), shell_reply $(field "$m" shell_reply), after $(field "$m" ms) ms"
	[ "$(num "$(field "$a" aux_reply)" 1)" = 0 ] && [ "$(num "$(field "$a" eof)" 0)" = 1 ]; check "PROTO_2: a flipped aux CRC ends the connection" $? "aux_reply $(field "$a" aux_reply), eof $(field "$a" eof), after $(field "$a" ms) ms"
	[ "$(num "$(val log-badcrc)" 0)" -ge 2 ]; check "PROTO_2: the log names the bad CRC, header and aux" $? "$(val log-badcrc) line(s)"
fi
m=$(val auxok)
[ "$(num "$(field "$m" aux_reply)" 0)" = 1 ] && [ "$(num "$(field "$m" aux_error)" 0)" = 32 ] && [ "$(num "$(field "$m" eof)" 1)" = 0 ]; check "PROTO_2: a frame with its aux CRC right is served" $? "aux_reply $(field "$m" aux_reply), aux_error $(field "$m" aux_error), eof $(field "$m" eof)"
m=$(val badcrc1)
[ "$(num "$(field "$m" eof)" 1)" = 0 ] && [ "$(num "$(field "$m" shell_reply)" 0)" = 1 ] && [ "$(num "$(field "$m" shell_error)" 0)" = 32 ]; check "PROTO_1: the same bad CRC is consumed and the next frame served, as upstream's core checks none" $? "eof $(field "$m" eof), shell_reply $(field "$m" shell_reply), shell_error $(field "$m" shell_error)"
m=$(val hm2proto1)
[ "$(num "$(field "$m" eof)" 0)" = 1 ] && [ "$(num "$(field "$m" shell_reply)" 1)" = 0 ] && [ "$(num "$(val log-hm2proto1)" 0)" -ge 1 ]; check "PROTO_1: a frame in the HM2 space ends the connection and the log names it" $? "eof $(field "$m" eof), shell_reply $(field "$m" shell_reply), $(val log-hm2proto1) log line(s)"
m=$(val hm2proto2)
[ "$(num "$(field "$m" eof)" 1)" = 0 ] && [ "$(num "$(field "$m" shell_reply)" 0)" = 1 ] && [ "$(num "$(field "$m" shell_error)" 0)" = 32 ]; check "PROTO_2: the same HM2 frame is ignored and the next frame served" $? "eof $(field "$m" eof), shell_reply $(field "$m" shell_reply), shell_error $(field "$m" shell_error)"
m=$(val spanlist)
[ "$(num "$(field "$m" spans_open)" 0)" = 3 ]; check "PROTO_2: three spans from the peer are each answered and left open" $? "$(field "$m" spans_open) of 3 open"
[ "$(num "$(val log-spantab3)" 0)" -ge 1 ] && [ "$(num "$(val log-spanlabels)" 0)" = 3 ]; check "PROTO_2: the span table lists the three by type and label" $? "$(val log-spantab3) line(s) at three, $(val log-spanlabels) distinct labels of 3"
[ "$(num "$(val log-spantab0)" 0)" -ge 1 ]; check "PROTO_2: the table empties when the connection closes" $? "$(val log-spantab0) line(s) at zero"
m=$(val span2on1)
[ "$(num "$(field "$m" closed)" 0)" = 1 ] && [ "$(num "$(val log-span9)" 1)" = 0 ]; check "PROTO_1: a PROTO_2 span on an unannounced connection is closed and never listed" $? "closed $(field "$m" closed), $(val log-span9) table line(s) with its label"
for act in proto2 badcrc badcrc1 auxok auxbad spanlist span2on1 hm2proto1 hm2proto2; do
	[ "$(num "$(val $act-threads)" 9)" = 0 ]; check "stage 1: $act leaves no thread" $? "$(val $act-threads)"
done

# Stage 2a of the design note: the HM2 XOP API's read side, every reply read
# beside the guest's own reading of the same volume (stat, sha256sum and
# the hammer2 utility), never beside the kernel alone.
hexfield() { printf '%s\n' "$1" | sed -n "s/.*[ :]$2=\([0-9a-f]*\).*/\1/p" | head -1; }
case "$(val hm2-row)" in *'added copyid='*) r=0 ;; *) r=1 ;; esac
check "stage 2a: the root's copyinfo row is added, which the server requires (stage 5.5)" $r "$(val hm2-row)"
m=$(val hm2root)
[ "$(num "$(field "$m" conn_proto)" 0)" = 2 ] && [ "$(num "$(field "$m" span_proto)" 0)" = 2 ] && [ "$(num "$(field "$m" found)" 0)" = 1 ] && [ "$(num "$(field "$m" fsid_match)" 0)" = 1 ] && [ "$(num "$(field "$m" error)" 1)" = 0 ]; check "stage 2a: the kernel announces PROTO_2 and serves the PFS root inode, whose pfs_fsid is the span's" $? "conn_proto $(field "$m" conn_proto), span_proto $(field "$m" span_proto), found $(field "$m" found), fsid_match $(field "$m" fsid_match), error $(field "$m" error)"
m=$(val hm2readdir)
[ "$(num "$(field "$m" entries)" 0)" = "$(num "$(val dir-entries)" -1)" ] && [ "$(num "$(val hm2readdir-match)" 0)" = 1 ] && [ "$(num "$(field "$m" maxrun)" 99)" -le 16 ] && [ "$(num "$(field "$m" runs)" 0)" -ge 2 ] && [ "$(num "$(field "$m" error)" 1)" = 0 ]; check "stage 2a: readdir over the wire lists the directory as stat does, in windows of sixteen" $? "$(field "$m" entries) of $(val dir-entries) entries, inum and name match $(val hm2readdir-match), maxrun $(field "$m" maxrun), $(field "$m" runs) continuation(s)"
m=$(val hm2nowindow)
if [ -n "${H2_CRC_CONTROL:-}" ]; then
	[ "$(num "$(field "$m" frames)" 0)" = "$(num "$(val dir-entries)" -1)" ] && [ "$(num "$(field "$m" error)" 1)" = 0 ]; check "control: with the window compiled out every entry arrives with no continuation sent" $? "frames $(field "$m" frames) of $(val dir-entries), error $(field "$m" error)"
else
	[ "$(num "$(val remote-timeout)" 0)" = 3000 ] && [ "$(num "$(field "$m" frames)" 0)" = 16 ] && [ "$(num "$(field "$m" error)" 0)" = 262144 ]; check "stage 2a: with no continuation sent the server stops at the window and times out at its bound" $? "frames $(field "$m" frames), error $(field "$m" error) (0x40000 is ETIMEDOUT), bound $(val remote-timeout) ms, after $(field "$m" ms) ms"
fi
m=$(val hm2scanlhc)
[ "$(num "$(val hm2scanlhc-f7)" 0)" = 1 ] && [ "$(num "$(field "$m" error)" 1)" = 0 ]; check "stage 2a: scanlhc on a dirent's hash returns that dirent" $? "f7 listed $(val hm2scanlhc-f7) time(s) among $(field "$m" ents), key $(val f7-key)"
m=$(val hm2nresolve)
[ "$(num "$(field "$m" found)" 0)" = 1 ] && [ "$(num "$(field "$m" inum)" 0)" = "$(num "$(val f7-inum)" -1)" ] && [ "$(num "$(field "$m" size)" -1)" = "$(num "$(val f7-size)" -2)" ]; check "stage 2a: nresolve returns the inode stat names, at its size" $? "inum $(field "$m" inum) vs $(val f7-inum), size $(field "$m" size) vs $(val f7-size)"
m=$(val hm2nresolve-missing)
[ "$(num "$(field "$m" found)" 1)" = 0 ] && [ "$(num "$(field "$m" closed)" 0)" = 1 ] && [ "$(num "$(field "$m" refused)" 1)" = 0 ]; check "stage 2a: a name that does not exist is served as no chain, not refused" $? "found $(field "$m" found), closed $(field "$m" closed), refused $(field "$m" refused), error $(field "$m" error)"
m=$(val hm2read)
[ "$(num "$(field "$m" datas)" 0)" = 3 ] && [ "$(num "$(field "$m" comp_none)" 0)" = 3 ] && [ "$(num "$(field "$m" full)" 0)" = 3 ] && [ -n "$(val hm2read-sha)" ] && [ "$(val hm2read-sha)" = "$(val big-sha)" ]; check "stage 2a: three strategy reads return the file's blocks, their digest the file's" $? "$(field "$m" datas) blocks, uncompressed $(field "$m" comp_none), full $(field "$m" full), sha $(val hm2read-sha | cut -c1-12) vs $(val big-sha | cut -c1-12)"
m=$(val hm2scanall)
[ "$(num "$(field "$m" datas)" 0)" = 3 ] && [ "$(val hm2scanall-keys)" = "0000000000000000 0000000000010000 0000000000020000 " ]; check "stage 2a: scanall under the file returns its three data chains in key order" $? "$(field "$m" datas) chains, keys $(val hm2scanall-keys)"
off1=$(val hm2scanall-off1)
m=$(val hm2lookup)
[ -n "$off1" ] && [ "$(num "$(field "$m" found)" 0)" = 1 ] && [ "$(hexfield "$m" data_off)" = "$off1" ]; check "stage 2a: lookup of the second block's key returns the chain scanall listed" $? "found $(field "$m" found), data_off $(hexfield "$m" data_off) vs $off1"
m=$(val hm2bmap)
[ -n "$off1" ] && [ "$(num "$(field "$m" found)" 0)" = 1 ] && [ "$(hexfield "$m" data_off)" = "$off1" ]; check "stage 2a: bmap of logical block one returns the same data offset" $? "found $(field "$m" found), data_off $(hexfield "$m" data_off)"
[ -n "$off1" ] && [ "$(val show-off1)" = "$off1" ]; check "stage 2a: the hammer2 utility reads that block at the same offset on the media" $? "show $(val show-off1) vs wire $off1, from the line \"$(val show-line)\""
m=$(val hm2refuse)
[ "$(num "$(field "$m" mod_refused)" 0)" = 1 ] && [ "$(num "$(field "$m" mod_error)" 0)" = 32 ] && [ "$(num "$(field "$m" nopfs_refused)" 0)" = 1 ] && [ "$(num "$(field "$m" nopfs_error)" 0)" = 32 ] && [ "$(num "$(field "$m" oneshot_refused)" 0)" = 1 ] && [ "$(num "$(field "$m" oneshot_error)" 0)" = 32 ] && [ "$(num "$(field "$m" noino_closed)" 0)" = 1 ] && [ "$(num "$(field "$m" noino_refused)" 1)" = 0 ] && [ "$(num "$(field "$m" noino_error)" 0)" != 0 ] && [ "$(num "$(field "$m" noino_frames)" 1)" = 0 ] && [ "$(num "$(field "$m" eof)" 1)" = 0 ] && [ "$(num "$(field "$m" shell_reply)" 0)" = 1 ]; check "stage 2a: a modifying command, an unknown cluster and a one-shot request are refused NOSUPP, an unknown inode is served as an error, and the connection outlives all four" $? "modifying $(field "$m" mod_refused)/$(field "$m" mod_error), cluster $(field "$m" nopfs_refused)/$(field "$m" nopfs_error), one-shot $(field "$m" oneshot_refused)/$(field "$m" oneshot_error), inode error $(field "$m" noino_error) with $(field "$m" noino_frames) frame(s), eof $(field "$m" eof), shell_reply $(field "$m" shell_reply)"
[ "$(num "$(val log-serve)" 0)" = 14 ] && [ "$(num "$(val log-refused)" 0)" = 1 ] && [ "$(num "$(val log-oneshot)" 0)" = 1 ] && [ "$(num "$(val log-nopfs)" 0)" = 1 ]; check "stage 2a: the log names the fourteen served requests, the one command refusal, the one one-shot refusal and the one cluster refusal" $? "$(val log-serve) served, $(val log-refused) command refusal(s), $(val log-oneshot) one-shot refusal(s), $(val log-nopfs) cluster refusal(s)"
for act in hm2root hm2readdir hm2nowindow hm2scanlhc hm2nresolve hm2nresolve-missing hm2read hm2scanall hm2lookup hm2bmap hm2refuse; do
	[ "$(num "$(val $act-threads)" 9)" = 0 ]; check "stage 2a: $act leaves no thread" $? "$(val $act-threads)"
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
[ "$(num "$(field "$(val hold-start)" spans_open)" 0)" = 3 ] && [ "$(num "$(val log-spantab0-after-hold)" 0)" -ge 2 ] && [ "$(num "$(val log-spanleft)" 1)" = 0 ]; check "stage 1: the unmount under three open PROTO_2 spans empties the table by the teardown's DELETEs, nothing left for the sweep" $? "spans_open $(field "$(val hold-start)" spans_open), $(val log-spantab0-after-hold) line(s) at zero, $(val log-spanleft) left"
cu=$(num "$(val ctl-umount-ms)" 99999); sf=$(num "$(val log-shitcan-final)" 0)
[ "$cu" -lt 3000 ] && [ "$sf" = "$sa" ]; check "socket_faults: control, with the daemon closed first the unmount is fast and the line is absent" $? "$cu ms, line count $sa to $sf"

final_checks

echo "dmsg: $checks check(s), $fail failed"
[ "$fail" -eq 0 ]
