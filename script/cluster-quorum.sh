#!/bin/sh
# Two MASTERs of one cluster, which is the configuration the quorum code
# decides for and which no run here had ever made. A PFS with one master
# short-circuits: hammer2_cluster_check() agrees with the only chain there
# is. With two, pfs_nmasters is 2, the quorum is pfs_nmasters / 2 + 1 = 2,
# and every lookup has to agree across both chains before it is answered.
#
# Two volumes go on the Linux guest, a MASTER PFS named CL is created on
# the first, and a second MASTER with the same cluster id is created on the
# other. Mounting both volumes' ROOT is what assembles them: the super-root
# scan calls hammer2_pfsalloc() once per PFS root chain it finds, and the
# second call appends at nchains. A file set is then written through the
# cluster's own mount and read back, both volumes are checked on the host
# by fsck_hammer2, and the CL PFS on each is fingerprinted from
# `hammer2 -v show` and compared, as cluster-sync.sh does for a slave.
#
# The fake pass to guard against is the one that matters most here: if the
# second volume were ignored, the mount would be an ordinary single-master
# PFS, every write and read would succeed, both fsck runs would pass, and
# nothing would have exercised a quorum at all. Two readings detect it.
# The thread count is the first: hammer2_vfsops.c skips the support thread
# for a MASTER element only when pfs_nmasters <= 1, so one master and one
# slave give one thread, and two masters must give two. The second volume's
# own media is the second: it is fingerprinted and fsck'd separately, so a
# volume that never received the set cannot be mistaken for one that did.
#
# Exit 2 without the guest, the tools or a kernel tree. H2_FIXTURE_SHARE=1
# starts the guest beside another running domain, as test-fixtures.sh does;
# otherwise another domain is a reason not to.
set -u
cd "$(dirname "$0")/.." || exit 2

FIXDIR=${H2_FIXTURE_DIR:-$HOME/Projects/linux_hammer2-data/fixtures}
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2")}
HAMMER2=${H2_HAMMER2:-$(command -v hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/hammer2")}
FSCK=${H2_FSCK:-$(command -v fsck_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2")}
# The hold is added to the bound, so a long H2_QUORUM_IDLE is not read as a hang.
IDLE=${H2_QUORUM_IDLE:-0}
case $IDLE in ''|*[!0-9]*|0?*) echo "quorum: COULD-NOT-RUN: H2_QUORUM_IDLE is not a number of seconds without a leading zero" >&2; exit 2 ;; esac
# H2_QUORUM_CONTEND=n prints a writer's wait beside a SEEK_HOLE loop through
# the quorum on a dense file of n MiB, a rate, so read on h2release-7.3tls.
QCONTEND=${H2_QUORUM_CONTEND:-0}
# H2_QUORUM_SEEKVOTE=1 builds the module with HAMMER2_LOCKDEBUG and checks
# the seek walk on both masters against the forced scan, with the masters
# agreeing and then made to disagree by writing blocks on one alone
# (write_except), and the comparison's own control (seek_agree_break); and
# the order (hammer2.h): a seek and a map beside a writeback held between
# the masters (xop_gap_ms, Q1), a read, FIBMAP and write_begin's read in
# the same window (Q2), and a SEEK_HOLE and FIEMAP loop beside the
# writeback of a 256 MiB stream (Q3), each with the order taken out as its
# control (xop_order_off). Q3 fails COULD-NOT-RUN where nothing exercised
# what it checks.
QVOTE=${H2_QUORUM_SEEKVOTE:-0}
# Q1's and Q2's window: the gap held between the masters, and how long
# after the writeback begins each call is made. A call that slept through
# the gap ends at least QGAP - QDELAY ms after the writeback began.
QGAP=2000; QDELAY=500
case $QVOTE in 0|1) ;; *) echo "quorum: COULD-NOT-RUN: H2_QUORUM_SEEKVOTE is 0 or 1" >&2; exit 2 ;; esac
case $QCONTEND in ''|*[!0-9]*|0?*) echo "quorum: COULD-NOT-RUN: H2_QUORUM_CONTEND is not a count of MiB without a leading zero" >&2; exit 2 ;; esac
# H2_QUORUM_SPLIT=1, with H2_QUORUM_SEEKVOTE=1 and H2_QUORUM_CONTEND=n, times
# the writer again with one block past the n MiB held by the two masters at
# two tids, so every SEEK_HOLE disagrees in its last batch and the scan
# answers that batch: what masters that disagree cost a writer.
QSPLIT=${H2_QUORUM_SPLIT:-0}
case $QSPLIT in 0|1) ;; *) echo "quorum: COULD-NOT-RUN: H2_QUORUM_SPLIT is 0 or 1" >&2; exit 2 ;; esac
if [ "$QSPLIT" = 1 ] && { [ "$QVOTE" != 1 ] || [ "$QCONTEND" = 0 ]; }; then
	echo "quorum: COULD-NOT-RUN: H2_QUORUM_SPLIT needs H2_QUORUM_SEEKVOTE=1 and H2_QUORUM_CONTEND" >&2; exit 2
fi
# H2_QUORUM_RULE_MS=m, with H2_QUORUM_CONTEND, fails the run when the
# two-master SEEK_HOLE's median, and under H2_QUORUM_SPLIT the split one's,
# exceeds m ms: the rule seek-matrix.sh holds one element to.
QRULE=${H2_QUORUM_RULE_MS:-0}
case $QRULE in ''|*[!0-9]*|0?*) echo "quorum: COULD-NOT-RUN: H2_QUORUM_RULE_MS is not a count of ms without a leading zero" >&2; exit 2 ;; esac
if [ "$QRULE" != 0 ] && [ "$QCONTEND" = 0 ]; then
	echo "quorum: COULD-NOT-RUN: H2_QUORUM_RULE_MS needs H2_QUORUM_CONTEND" >&2; exit 2
fi
# The bound scales on a KASAN tree, as cluster-sync.sh's does, so a slower
# kernel is not read as a hang.
# Q3's five writebacks of 256 MiB add 600 s under H2_QUORUM_SEEKVOTE=1.
RUNSECS=600; [ "$QVOTE" = 1 ] && RUNSECS=1200
grep -qx 'CONFIG_KASAN=y' "$KDIR/.config" 2>/dev/null && RUNSECS=$((RUNSECS * 4))
RUN="timeout $(( ${H2_RUN_TIMEOUT:-$RUNSECS} + IDLE )) ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
QA=$FIXDIR/cluster-qa.img
QB=$FIXDIR/cluster-qb.img
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

command -v virsh >/dev/null 2>&1 || { echo "quorum: COULD-NOT-RUN: no virsh" >&2; exit 2; }
command -v nm >/dev/null 2>&1 || { echo "quorum: COULD-NOT-RUN: no nm, so the module's instrumentation cannot be read" >&2; exit 2; }
[ -x "$NEWFS" ] || { echo "quorum: COULD-NOT-RUN: no newfs_hammer2 (H2_NEWFS)" >&2; exit 2; }
[ -x "$FSCK" ] || { echo "quorum: COULD-NOT-RUN: no fsck_hammer2 (H2_FSCK)" >&2; exit 2; }
[ -x "$HAMMER2" ] || { echo "quorum: COULD-NOT-RUN: no hammer2 (H2_HAMMER2)" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "quorum: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -d "$KDIR" ] || { echo "quorum: COULD-NOT-RUN: no kernel tree at $KDIR" >&2; exit 2; }
state=$($VIRSH domstate "$GUEST" 2>/dev/null) || {
	echo "quorum: COULD-NOT-RUN: no guest $GUEST" >&2; exit 2; }
names=$($VIRSH list --name 2>/dev/null) || {
	echo "quorum: COULD-NOT-RUN: virsh list failed, so other guests cannot be counted" >&2; exit 2; }
other=$(printf '%s\n' "$names" | grep -v -x -e "$GUEST" -e '' | grep -c . || true)
if [ "$other" -gt 0 ] && [ "${H2_FIXTURE_SHARE:-0}" != 1 ]; then
	echo "quorum: COULD-NOT-RUN: $other other guest(s) running; H2_FIXTURE_SHARE=1 to share" >&2
	exit 2
fi

make -s clean >/dev/null 2>&1
LD=; [ "$QVOTE" = 1 ] && LD="HAMMER2_LOCKDEBUG=1"
make -s KDIR="$KDIR" $LD >/dev/null 2>&1 || {
	echo "quorum: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko
cc -static -O2 -o "$W/h2seekprobe" test/hammer2-seekprobe.c >/dev/null 2>&1 || {
	echo "quorum: COULD-NOT-RUN: the seek probe did not compile" >&2; exit 2; }
# What the module was built from, so a kept log names its own build.
echo "  read  module from $(git rev-parse --short HEAD) with src/ $(git diff --quiet HEAD -- src/ && echo clean || echo modified), against $KDIR"

# What the kernel tree configures against what the module actually carries,
# so a sanitizer reading on the wrong module cannot pass in silence.
# grep -c prints its count and exits 1 on no match, so the count is kept and
# the status discarded.
# An unreadable .config read as no KASAN and skipped the sanitizer check.
[ -r "$KDIR/.config" ] || {
	echo "quorum: COULD-NOT-RUN: $KDIR/.config is not readable, so what the tree configures is unknown" >&2; exit 2; }
want_asan=$(sed -n 's/^CONFIG_KASAN=//p' "$KDIR/.config")
have_asan=$(nm -u "$KO" 2>/dev/null | grep -c '__asan' || true)
have_ubsan=$(nm -u "$KO" 2>/dev/null | grep -c '__ubsan' || true)

# The volumes are detached before they are recreated: a running guest's
# qemu holds an image open, and a file replaced under it is a file it no
# longer reads.
# Both halves: a stopped guest is attached with --config, which --live
# does not remove, and a persistent attachment left behind by an earlier
# run makes the next attach fail with the target already taken.
for d in vdb vdc; do
	$VIRSH detach-disk "$GUEST" $d --live >/dev/null 2>&1
	$VIRSH detach-disk "$GUEST" $d --config >/dev/null 2>&1
done
rm -f "$QA" "$QB"
# 2 GiB, or room for the contend file and a quarter more: the scan's cost
# grows with the file, so its wait is read at the size the walk's is.
QSIZE=$(( QCONTEND * 5 / 4 / 1024 + 2 ))G
for img in "$QA" "$QB"; do
	truncate -s "$QSIZE" "$img" && "$NEWFS" -L ROOT "$img" >/dev/null 2>&1 || {
		echo "quorum: COULD-NOT-RUN: newfs_hammer2 failed on $img" >&2; exit 2; }
done
if [ "$state" = running ]; then how=--live; else how=--config; fi
err=$($VIRSH attach-disk "$GUEST" "$QA" vdb --targetbus virtio $how 2>&1) &&
err=$($VIRSH attach-disk "$GUEST" "$QB" vdc --targetbus virtio $how 2>&1) || {
	echo "quorum: COULD-NOT-RUN: could not attach the volumes: $err" >&2; exit 2; }
if [ "$state" != running ]; then
	$VIRSH start "$GUEST" >/dev/null 2>&1 || { echo "quorum: COULD-NOT-RUN: $GUEST did not start" >&2; exit 2; }
fi
n=0
until ssh -o ConnectTimeout=3 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null; do
	sleep 5; n=$((n + 1))
	[ $n -gt 60 ] && { echo "quorum: COULD-NOT-RUN: $GUEST did not answer ssh in 5 minutes" >&2; exit 2; }
done
# One lockdep report turns lockdep off until the next boot, and a run
# on that boot reads "no report" with nothing checking.
dl=$(ssh -o BatchMode=yes "$GUEST_SSH" "awk '/debug_locks:/ {print \$2}' /proc/lockdep_stats 2>/dev/null")
[ "$dl" = 0 ] && {
	echo "quorum: COULD-NOT-RUN: lockdep is off on $GUEST since an earlier report; boot it again" >&2; exit 2; }

cat > "$W/guest.sh" <<'GUEST'
set -u
# An earlier run's sums would be copied back if this one stopped before
# writing its own, so a comparison could pass on files it never made.
rm -f /tmp/q.want /tmp/q.sums
rmmod hammer2 2>/dev/null; dmesg -C
# The marker the host looks for at the head of the kept log: a ring that
# wrapped during the run has lost it, and the counts read from it are short.
echo "h2quorum: start" > /dev/kmsg
echo "guest-kernel $(uname -r) $(uname -v)"
{ echo scan > /sys/kernel/debug/kmemleak && echo scan > /sys/kernel/debug/kmemleak && echo clear > /sys/kernel/debug/kmemleak; } 2>/dev/null; echo "kmemleak-cleared"	# an earlier run's leaks are its own
insmod /tmp/hammer2.ko debug=0x8000 || { echo "insmod failed"; exit 1; }
mkdir -p /mnt/h2a /mnt/h2b /mnt/h2q

# A MASTER on the first volume, then a second MASTER of the same cluster id
# on the other. Mounting both ROOTs is what assembles them into one PFS.
mount -t hammer2 /dev/vdb@ROOT /mnt/h2a || exit 1
hammer2 -s /mnt/h2a pfs-create CL >/dev/null 2>&1 || { echo "master-a pfs-create failed"; exit 1; }
clid=$(hammer2 -s /mnt/h2a pfs-clid CL 2>/dev/null)
echo "clid-len $(printf %s "$clid" | wc -c)"
mount -t hammer2 /dev/vdc@ROOT /mnt/h2b || exit 1
hammer2 -s /mnt/h2b -t MASTER -u "$clid" pfs-create CL >/dev/null 2>&1
echo "master-b-rc $?"
echo "type-a $(hammer2 -s /mnt/h2a pfs-list | awk '$3=="CL"{print $1}')"
echo "type-b $(hammer2 -s /mnt/h2b pfs-list | awk '$3=="CL"{print $1}')"

# hammer2_vfsops.c skips the support thread for a MASTER element only when
# pfs_nmasters <= 1, so two masters must each have one. One thread here
# would mean the second volume was not seen and this is a lone master.
sleep 2
echo "quorum-threads $(ps -eo comm | grep -c '^h2nod-CL')"

# The cluster's own mount. Every lookup through it is answered by the
# quorum rather than by a single chain.
mount -t hammer2 /dev/vdb@CL /mnt/h2q; rc=$?
echo "cluster-mount-rc $rc"
# A failed mount leaves /mnt/h2q on the guest's root filesystem, where
# the set would be written and read back and compare equal to itself.
[ "$rc" = 0 ] || exit 1
# The set is made off the volume and summed before anything touches it, so
# the sums read back are compared against what was written rather than
# merely counted. CONTROL=1 changes one file after its sum is taken, which
# the comparison on the host must report.
rm -rf /tmp/qsrc; mkdir -p /tmp/qsrc /mnt/h2q/set
i=0; while [ $i -lt 24 ]; do head -c $(( (i * 6151) % 200000 + 1 )) /dev/urandom > /tmp/qsrc/q$i; i=$((i + 1)); done
( cd /tmp/qsrc && md5sum q* | LC_ALL=C sort ) > /tmp/q.want
[ "${CONTROL:-0}" = 1 ] && printf x >> /tmp/qsrc/q0
cp /tmp/qsrc/q* /mnt/h2q/set/
sync
echo "write-files $(find /mnt/h2q/set -type f | wc -l)"

# Read every file back after an unmount and a cache drop, so each lookup
# and each block is answered through the cluster's chains rather than
# from the page cache the write left behind.
umount /mnt/h2q
echo 3 > /proc/sys/vm/drop_caches
mount -t hammer2 /dev/vdb@CL /mnt/h2q; rc=$?
echo "reread-mount-rc $rc"
[ "$rc" = 0 ] || exit 1
( cd /mnt/h2q/set && md5sum q* 2>/dev/null | LC_ALL=C sort ) > /tmp/q.sums
echo "read-sums $(grep -c . /tmp/q.sums)"
# The seek and the map through the quorum, which a cluster of several
# elements answers by the chunked scan rather than the walk: the seek
# probe's shape (data, hole, data, a half block) written, read after a
# remount with the caches dropped, both seeks asked and FIEMAP dumped.
/tmp/h2seekprobe make /mnt/h2q/seekf >/dev/null 2>&1
sync
umount /mnt/h2q
echo 3 > /proc/sys/vm/drop_caches
mount -t hammer2 /dev/vdb@CL /mnt/h2q || exit 1
/tmp/h2seekprobe check /mnt/h2q/seekf "the two-master cluster" > /tmp/q.seek 2>&1
echo "seek-ok $(grep -c '^seekm-ok' /tmp/q.seek) seek-fail $(grep -c '^seekm-fail' /tmp/q.seek)"
grep '^seekm-fail' /tmp/q.seek | head -5
/tmp/h2seekprobe dump /mnt/h2q/seekf > /tmp/q.dump 2>&1; s=$?
echo "map-exit $s map-extents $(sed -n 's/^seekm-dump extents //p' /tmp/q.dump)"
# Removed again, so the media checks below count the set's 24 files.
rm -f /mnt/h2q/seekf
# VOTE=1 (H2_QUORUM_SEEKVOTE, a HAMMER2_LOCKDEBUG module): each MASTER walks
# and the frontend compares the walks (hammer2_seek_vote()). Every file is
# dumped by the walk and by the forced scan and compared, and the counters
# say which reader answered.
if [ "${VOTE:-0}" = 1 ]; then
P=/sys/module/hammer2/parameters
for k in seek_scanall seek_walked seek_fellback seek_agree_break seek_depth_max seek_fail_elm scan_fail_elm write_except xop_gap_ms xop_gap_desc xop_reruns xop_order_off; do
	[ -e $P/$k ] || { echo "vote-setup no $k"; exit 1; }
done
for t in xfs_io filefrag; do
	command -v $t >/dev/null 2>&1 || { echo "quorum: COULD-NOT-RUN: no $t on the guest"; exit 2; }
done
vdump() {	# file tag
	w0=$(cat $P/seek_walked); b0=$(cat $P/seek_fellback)
	/tmp/h2seekprobe dump "$1" > /tmp/qv-walk.$2
	w1=$(cat $P/seek_walked); b1=$(cat $P/seek_fellback)
	echo 1 > $P/seek_scanall
	/tmp/h2seekprobe dump "$1" > /tmp/qv-scan.$2
	echo 0 > $P/seek_scanall
	echo "vote $2 lines $(wc -l < /tmp/qv-walk.$2) extents $(grep -c '^seekm-dump extent ' /tmp/qv-walk.$2) differ $(cmp -s /tmp/qv-walk.$2 /tmp/qv-scan.$2 && echo 0 || echo 1) walked $((w1 - w0)) fellback $((b1 - b0)) maperr $(sed -n 's/^seekm-fail dump: FIEMAP errno //p' /tmp/qv-walk.$2 | head -1 | grep . || echo none)"
	diff /tmp/qv-walk.$2 /tmp/qv-scan.$2 | head -5 | sed "s/^/vote $2 diff /"
}
vseek() {	# tag d|h offset: one SEEK_DATA or SEEK_HOLE through xfs_io, the fallbacks it took, and whether it failed EIO
	b0=$(cat $P/seek_fellback)
	o=$(xfs_io -r -c "seek -$2 $3" /mnt/h2q/dis 2>&1)
	r=$(printf '%s\n' "$o" | awk '$1 ~ /^(DATA|HOLE)$/ {print $2}')
	echo "vote $1 answer ${r:-none} fellback $(( $(cat $P/seek_fellback) - b0 )) eio $(printf '%s\n' "$o" | grep -c 'Input/output error')"
}
vshow() {	# tag: each data block of dis with its modify_tid, from each volume's own media
	ino=$(stat -c %i /mnt/h2q/dis)
	umount /mnt/h2q
	for v in a:vdb b:vdc; do
		hammer2 -v show /dev/${v#*:} 2>/dev/null | awk -v p="$1" -v t=${v%%:*} -v n="$(printf '0x%016x' "$ino")" '
		/^ *inode\.[0-9]/ { mode = "inode"; next }
		mode == "inode" && $1 == "inum" { inum = $2 }
		/^ *data\.[0-9]/ { mode = "data"; key = $3; next }
		mode == "data" && /mod=/ { m = $0; sub(/.*mod=/, "", m); sub(/ .*/, "", m); if (inum == n) print p, t, key, m; mode = "" }'
	done
	echo 3 > /proc/sys/vm/drop_caches
	mount -t hammer2 /dev/vdb@CL /mnt/h2q || exit 1
}
# Agreeing masters: a file across the walk's 1024-block batch edge, the
# probe's shape, and a file held in its inode.
/tmp/h2seekprobe layout /mnt/h2q/lay >/dev/null 2>&1
/tmp/h2seekprobe make /mnt/h2q/shp >/dev/null 2>&1
printf x > /mnt/h2q/emb
sync; umount /mnt/h2q; echo 3 > /proc/sys/vm/drop_caches
mount -t hammer2 /dev/vdb@CL /mnt/h2q || exit 1
vdump /mnt/h2q/lay agree-lay
vdump /mnt/h2q/shp agree-shp
vdump /mnt/h2q/emb agree-emb
# The walk's error on several masters is the collect's error, and no
# fallback: seek_depth_max=0 refuses the first indirect block.
d0=$(cat $P/seek_depth_max); b0=$(cat $P/seek_fellback)
echo 0 > $P/seek_depth_max
/tmp/h2seekprobe refuse /mnt/h2q/lay > /tmp/qv.refuse 2>&1; s=$?
echo $d0 > $P/seek_depth_max
echo "vote refuse exit $s eio $(grep -c '^seekm-ok   refuse' /tmp/qv.refuse) fellback $(( $(cat $P/seek_fellback) - b0 ))"
# One element failing while the other answers: the call's error is the
# collect's, the first master's error that is not zero, here the second
# master's, with no fallback. seek_fail_elm fails the second element's
# walk alone.
b0=$(cat $P/seek_fellback)
echo 1 > $P/seek_fail_elm
/tmp/h2seekprobe refuse /mnt/h2q/lay > /tmp/qv.fail1 2>&1; s=$?
echo -1 > $P/seek_fail_elm
echo "vote failone exit $s eio $(grep -c '^seekm-ok   refuse' /tmp/qv.fail1) fellback $(( $(cat $P/seek_fellback) - b0 ))"
# One master's scan failing before a key the other holds: a file whose only
# block is block 2, SEEK_HOLE from 0 through the forced scan, scan_fail_elm
# ending the second master's scan of a regular file on EIO. The second has
# said nothing of any key, so the call fails with its error rather than
# answering the hole at 0; with the knob unset, the control, it answers 0.
dd if=/dev/urandom of=/mnt/h2q/sf bs=64k seek=2 count=1 2>/dev/null; sync
echo 1 > $P/seek_scanall
for e in on:1 off:-1; do
	echo ${e#*:} > $P/scan_fail_elm
	o=$(xfs_io -r -c "seek -h 0" /mnt/h2q/sf 2>&1)
	r=$(printf '%s\n' "$o" | awk '$1 == "HOLE" {print $2}')
	echo "vote scanfail-${e%%:*} answer ${r:-none} eio $(printf '%s\n' "$o" | grep -c 'Input/output error')"
done
echo -1 > $P/scan_fail_elm
echo 0 > $P/seek_scanall
rm -f /mnt/h2q/sf
rm -f /mnt/h2q/lay /mnt/h2q/shp /mnt/h2q/emb
# Masters made to disagree: blocks 0-7 and 16-23 of 24 on both, then block
# 10 on the first only, block 12 on the second only, and block 2 rewritten
# on the first only, so its two copies carry two modify_tids.
dd if=/dev/urandom of=/mnt/h2q/dis bs=64k count=8 2>/dev/null
dd if=/dev/urandom of=/mnt/h2q/dis bs=64k seek=16 count=8 conv=notrunc 2>/dev/null
sync
for xb in 1:10 0:12 1:2; do
	echo ${xb%%:*} > $P/write_except
	dd if=/dev/urandom of=/mnt/h2q/dis bs=64k seek=${xb#*:} count=1 conv=notrunc 2>/dev/null
	sync
done
echo -1 > $P/write_except
vshow "vote show"
vdump /mnt/h2q/dis disagree
vseek inside d $((8 * 65536))
vseek outside h $((16 * 65536))
vseek hole0 h 0
# Each block the masters disagree on read on its own, and block 0, which
# they agree on, beside them: dd's status, the bytes it read and how many
# of them are not zero. Debug bit 0x0100 prints each failed read with what
# every element fed, and dd's own message is kept, so a failure names its
# errno.
echo $((0x8000 | 0x0100)) > /sys/module/hammer2/parameters/debug
for b in 0 2 10 12; do
	rm -f /tmp/qv.blk
	dd if=/mnt/h2q/dis of=/tmp/qv.blk bs=64k skip=$b count=1 2>/tmp/qv.err; s=$?
	echo "vote read $b exit $s bytes $(wc -c < /tmp/qv.blk 2>/dev/null || echo none) nonzero $(tr -d '\000' < /tmp/qv.blk 2>/dev/null | wc -c)"
	[ "$s" = 0 ] || echo "vote readerr $b $(tr '\n' ' ' < /tmp/qv.err)"
done
echo $((0x8000)) > /sys/module/hammer2/parameters/debug
# The comparison's control: 1 drops the tid from it, 2 trusts the first
# walk unread; either must make the walk's dump differ from the scan's.
# Before the partial write, which would end the disagreement at block 2
# if it went through.
for k in 1 2; do
	echo $k > $P/seek_agree_break
	vdump /mnt/h2q/dis break$k
done
echo 0 > $P/seek_agree_break
# A 4 KiB write into block 2, after the reads above left the block's pages
# in the cache as page-sized folios, none uptodate: the write covers its
# own folio whole, so only hammer2_write_begin()'s read of a folio smaller
# than its block goes through the quorum. It must fail and leave both
# masters' copies as they were, read again from the media.
echo $((0x8000 | 0x0100)) > /sys/module/hammer2/parameters/debug
dd if=/dev/urandom of=/mnt/h2q/dis bs=4k seek=$((2 * 16 + 1)) count=1 conv=notrunc 2>/tmp/qv.err; s=$?
echo "vote pwrite exit $s eio $(grep -c 'Input/output error' /tmp/qv.err)"
echo $((0x8000)) > /sys/module/hammer2/parameters/debug
sync
vshow "vote after"
rm /mnt/h2q/dis; echo "vote rm exit $?"
# Q1. A writeback beside the seek and the map. xop_gap_ms holds the
# strategy write between the first master and the second with the order
# held across the gap, so a call made 500 ms after the writeback began
# finds block 1 on the first alone, which the collect fails as a
# disagreement; the call then runs once more under the order's read side,
# which waits for the write. Each call prints its own xop_reruns delta and
# the probe's seek-ms, which runs from before the writeback and so
# includes the delay. xop_order_off, set, takes no order, and is the
# control: the same call must then fail EIO, or the window was never
# reached.
echo strategy_write > $P/xop_gap_desc
echo $GAP > $P/xop_gap_ms
for off in 0 1; do
	echo $off > $P/xop_order_off
	for k in hole map; do
		r0=$(cat $P/xop_reruns)
		o=$(/tmp/h2seekprobe wbrace /mnt/h2q/wb $k $DELAY | sed -n 's/^seekm-wbrace //p')
		echo "vote wbrace$off-$o reruns $(( $(cat $P/xop_reruns) - r0 ))"
		rm -f /mnt/h2q/wb
	done
done
echo 0 > $P/xop_order_off
echo 0 > $P/xop_gap_ms
# Q2. The read, FIBMAP and hammer2_write_begin()'s read in the same window
# (the sixth review's finding 3). Block 1 of a file is written and synced,
# read cold one page with readahead off to leave a page folio at 64 KiB,
# rewritten 4 KiB at 68 KiB through the small path, and the clean page
# dropped, so the block's writeback is that one folio. It is held 2 s
# between the masters (sync &), and 500 ms in one call is made, each in a
# window of its own so its xop_reruns delta is its own: dd of the
# uncached page at 72 KiB (read_folio), filefrag -B (FIBMAP), and a 4 KiB
# pwrite at 76 KiB, uncached (the read under i_rwsem, the folio lock and
# a transaction). Milliseconds run from before the sync, as the probe's
# do. The page read must be the one written before, and the block read
# back cold the splice of the writes that answered. With xop_order_off
# set each call must fail EIO.
dd if=/dev/zero bs=4k count=1 2>/dev/null | tr '\000' '\132' > /tmp/q2.5a
dd if=/dev/zero bs=4k count=1 2>/dev/null | tr '\000' '\245' > /tmp/q2.a5
q2() {	# off tag
	rm -f /mnt/h2q/q2 /tmp/q2.rd
	dd if=/dev/urandom of=/mnt/h2q/q2 bs=64k seek=1 count=1 2>/dev/null; sync
	dd if=/mnt/h2q/q2 of=/tmp/q2.want bs=64k skip=1 count=1 2>/dev/null
	echo 3 > /proc/sys/vm/drop_caches
	xfs_io -c 'fadvise -r' -c 'pread 64k 4k' /mnt/h2q/q2 >/dev/null 2>&1
	xfs_io -c 'pwrite -S 0x5a 68k 4k' /mnt/h2q/q2 >/dev/null 2>&1
	dd if=/tmp/q2.5a of=/tmp/q2.want bs=4k seek=1 count=1 conv=notrunc 2>/dev/null
	echo 1 > /proc/sys/vm/drop_caches
	echo $1 > $P/xop_order_off
	echo $GAP > $P/xop_gap_ms
	r0=$(cat $P/xop_reruns); t0=$(date +%s%N)
	sync & sp=$!
	sleep $((DELAY / 1000)).$(printf %03d $((DELAY % 1000)))
	case $2 in
	read)	dd if=/mnt/h2q/q2 of=/tmp/q2.rd bs=4k skip=18 count=1 > /tmp/q2.out 2>&1 ;;
	fibmap)	filefrag -B /mnt/h2q/q2 > /tmp/q2.out 2>&1 ;;
	pwrite)	xfs_io -c 'pwrite -S 0xa5 76k 4k' /mnt/h2q/q2 > /tmp/q2.out 2>&1 ;;
	esac
	s=$?
	t1=$(date +%s%N); r1=$(cat $P/xop_reruns)
	wait $sp
	echo 0 > $P/xop_gap_ms
	echo 0 > $P/xop_order_off
	grep -q 'wrote 4096/4096' /tmp/q2.out && dd if=/tmp/q2.a5 of=/tmp/q2.want bs=4k seek=3 count=1 conv=notrunc 2>/dev/null
	same=-
	[ "$2" = read ] && { dd if=/tmp/q2.want bs=4k skip=2 count=1 2>/dev/null | cmp -s - /tmp/q2.rd && same=1 || same=0; }
	sync; echo 3 > /proc/sys/vm/drop_caches
	dd if=/mnt/h2q/q2 bs=64k skip=1 count=1 2>/dev/null | cmp -s - /tmp/q2.want && final=1 || final=0
	echo "vote q2$1-$2 exit $s eio $(grep -c 'Input/output error' /tmp/q2.out) wrote $(grep -c 'wrote 4096/4096' /tmp/q2.out) reruns $((r1 - r0)) ms $(( (t1 - t0) / 1000000 )) same $same final $final"
	rm -f /mnt/h2q/q2
}
echo strategy_write > $P/xop_gap_desc
for off in 0 1; do
	for k in read fibmap pwrite; do
		q2 $off $k
	done
done
# Q3. The stream (the sixth review's finding 1, the fifth's case): a 1 GiB
# file whose first 256 MiB are written, then synced in the background
# with a SEEK_HOLE and FIEMAP loop until the sync exits: with no gap, with
# a 5 ms gap between the masters, and with that gap and the order taken
# out, the control; and the writeback alone with each gap, for its
# seconds beside the loop's.
q3() {	# tag gap off loop
	rm -f /mnt/h2q/q3; sync
	truncate -s 1G /mnt/h2q/q3
	dd if=/dev/urandom of=/mnt/h2q/q3 bs=1M count=256 conv=notrunc 2>/dev/null
	echo $2 > $P/xop_gap_ms
	echo $3 > $P/xop_order_off
	n=0; eio=0
	r0=$(cat $P/xop_reruns); t0=$(date +%s%N)
	sync & sp=$!
	while [ "$4" = 1 ] && kill -0 $sp 2>/dev/null; do
		o=$(xfs_io -r -c 'seek -h 0' -c 'fiemap' /mnt/h2q/q3 2>&1)
		n=$((n + 1))
		case $o in *'Input/output error'*) eio=$((eio + 1)) ;; esac
	done
	wait $sp
	t1=$(date +%s%N); r1=$(cat $P/xop_reruns)
	echo 0 > $P/xop_gap_ms
	echo 0 > $P/xop_order_off
	echo "vote q3-$1 calls $n eio $eio reruns $((r1 - r0)) ms $(( (t1 - t0) / 1000000 ))"
	rm -f /mnt/h2q/q3
}
echo strategy_write > $P/xop_gap_desc
q3 a-alone 0 0 0
q3 a 0 0 1
q3 b-alone 5 0 0
q3 b 5 0 1
q3 c 5 1 1
sync
# order_check counts a modify of an inode chain made without its order;
# it exists only where lockdep does.
echo "vote order-check $(cat $P/order_check 2>/dev/null || echo absent)"
fi
# CONTEND=n prints what a seek through the quorum costs a writer: a dense
# file of n MiB, writes timed alone and beside a SEEK_HOLE loop.
[ "${CONTEND:-0}" -gt 0 ] && /tmp/h2seekprobe contend /mnt/h2q/contend 20 "$CONTEND" | grep -v '^seekm-contend [a-z]* [0-9]'
# and the seek itself on a dense file of the same size, by the probe's
# time mode: SEEK_HOLE from an offset in the first 16 MiB, ten of twenty
[ "${CONTEND:-0}" -gt 0 ] && /tmp/h2seekprobe time /mnt/h2q/tdense dense 20 "$CONTEND" | grep '^seekm-time dense-hole median'
# SPLIT=1 (VOTE=1): contend's dense file of n MiB, made by the probe's fill
# with the same pattern, gains one block past its n MiB, which is then
# rewritten on the first master alone (write_except), so the two hold it at
# two tids and the collect fails it. Every SEEK_HOLE from 0 then walks to
# the last batch, disagrees there, and takes the scan from that batch's
# cursor to the block, where it fails EIO; the writes stay below the block,
# so none mends it (contendeio).
if [ "${SPLIT:-0}" = 1 ]; then
	P=/sys/module/hammer2/parameters
	b=$((CONTEND * 16))
	/tmp/h2seekprobe fill /mnt/h2q/contend "$CONTEND" >/dev/null 2>&1 &&
	    dd if=/dev/urandom of=/mnt/h2q/contend bs=64k seek=$b count=1 conv=notrunc 2>/dev/null; s1=$?
	sync
	echo 1 > $P/write_except
	dd if=/dev/urandom of=/mnt/h2q/contend bs=64k seek=$b count=1 conv=notrunc 2>/dev/null; s2=$?
	sync
	echo -1 > $P/write_except
	f0=$(cat $P/seek_fellback)
	/tmp/h2seekprobe contendeio /mnt/h2q/contend 20 "$CONTEND" | grep -v '^seekm-contend [a-z]* [0-9]' | sed 's/^seekm-contend /seekm-split /'
	echo "split-write exit $s1 $s2 fellback $(( $(cat $P/seek_fellback) - f0 ))"
fi
rm -f /mnt/h2q/contend /mnt/h2q/tdense
sync
# IDLE=n holds the cluster mounted n seconds after the read-back, so each
# thread runs several passes, whose counts are printed at the end.
[ "${IDLE:-0}" -gt 0 ] && sleep "$IDLE"
umount /mnt/h2q && echo "cluster-umount ok" || exit 1
umount /mnt/h2b && umount /mnt/h2a || exit 1
echo "threads-after $(ps -eo comm | grep -c '^h2nod')"
echo "kernel-warnings $(dmesg | grep -c -E 'WARNING|BUG:|UBSAN:|circular locking|possible recursive')"
echo "hung-task $(dmesg | grep -c 'blocked for more than')"
echo "debug-locks-after $(awk '/debug_locks:/ {print $2}' /proc/lockdep_stats 2>/dev/null)"
# Before rmmod, so the report's %pS resolves the module's own symbols, and
# after a wait past the scanner's own age rule (kmemleak.c MSECS_MIN_AGE,
# 5000 ms), so what the teardown just freed is old enough to be reported.
# A scan that refuses is what an earlier control run's `echo off` leaves
# behind until a reboot; a refusal is not an empty report.
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
rmmod hammer2 && echo "rmmod ok"
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
echo "scrapped $(dmesg | grep -c unmount_scrap)"
dmesg | tail -40 > /tmp/q.log
dmesg > /tmp/q.klog
GUEST

scp -q "$KO" "$W/guest.sh" "$W/h2seekprobe" "$GUEST_SSH:/tmp/" || { echo "quorum: COULD-NOT-RUN: copy to $GUEST failed" >&2; exit 2; }
$RUN "$GUEST_SSH" "mv /tmp/guest.sh /tmp/h2quorum.sh; chmod 755 /tmp/h2seekprobe; CONTROL=${H2_QUORUM_CONTROL:-0} IDLE=$IDLE CONTEND=$QCONTEND VOTE=$QVOTE SPLIT=$QSPLIT GAP=$QGAP DELAY=$QDELAY sh /tmp/h2quorum.sh" > "$W/out" 2>&1
rc=$?
# The guest half's exit, read before anything is inferred from its output.
# A non-zero that is not 124 means the guest or its session ended without
# finishing, and the checks below would read empty values as the subject
# failing. It is surfaced as COULD-NOT-RUN, and the disks are released
# only after the guest has stopped touching them: a detach under a live
# guest reaches it as an ACPI eject, and the flush of the ejected volume
# hpanics the device into error (measured 2026-10-13 in cluster-sync.sh,
# trace acpiphp_disable_and_eject_slot -> sync_filesystem ->
# hammer2_base_delete). cluster-sync.sh carries the same guard.
if [ "$rc" = 2 ] || command grep -q "COULD-NOT-RUN" "$W/out" 2>/dev/null; then
	command grep -m1 "COULD-NOT-RUN" "$W/out" 2>/dev/null >&2 ||
		echo "quorum: COULD-NOT-RUN: the guest half exited 2 without a reason" >&2
	for d in vdb vdc; do
		$VIRSH detach-disk "$GUEST" $d --live >/dev/null 2>&1
		$VIRSH detach-disk "$GUEST" $d --config >/dev/null 2>&1
	done
	exit 2
fi
if [ "$rc" != 0 ] && [ "$rc" != 124 ]; then
	for d in vdb vdc; do
		$VIRSH detach-disk "$GUEST" $d --live >/dev/null 2>&1
		$VIRSH detach-disk "$GUEST" $d --config >/dev/null 2>&1
	done
	echo "quorum: COULD-NOT-RUN: the guest session ended rc=$rc, so the run did not finish" >&2
	exit 2
fi
[ "$rc" = 124 ] && { echo "  FAIL  the guest run hung past ${H2_RUN_TIMEOUT:-$RUNSECS}s"; exit 1; }
scp -q "$GUEST_SSH:/tmp/q.sums" "$W/sums" >/dev/null 2>&1
scp -q "$GUEST_SSH:/tmp/q.want" "$W/want" >/dev/null 2>&1
# The guest's whole kernel log for the run, kept beside the images.
STAMP=$(date +%Y%m%d-%H%M%S)
scp -q "$GUEST_SSH:/tmp/q.klog" "$FIXDIR/quorum-run-$STAMP.klog" >/dev/null 2>&1 &&
	echo "  kept  the guest's kernel log as $FIXDIR/quorum-run-$STAMP.klog"
for d in vdb vdc; do
	$VIRSH detach-disk "$GUEST" $d --live >/dev/null 2>&1
	$VIRSH detach-disk "$GUEST" $d --config >/dev/null 2>&1
done

val() { sed -n "s/^$1 //p" "$W/out" | head -1; }
nval() { grep -c -E "^$1( |$)" "$W/out"; }	# how many lines carry the name, with or without a value
fail=0; checks=0; cnr=
check() {	# check <name> <condition-result 0/1> <reading>
	checks=$((checks + 1))
	if [ "$2" = 0 ]; then echo "  ok    $1: $3"; else echo "  FAIL  $1: $3"; fail=$((fail + 1)); fi
}

a=$(val clid-len); [ "${a:-0}" -ge 32 ] 2>/dev/null; check "the first MASTER has a cluster id to share" $? "${a:-0} characters"
a=$(val master-b-rc); [ "${a:-1}" = 0 ]; check "a second MASTER of that cluster id is accepted" $? "exit ${a:-none}"
a=$(val type-a); [ "${a:-none}" = MASTER ]; check "the first volume records its PFS as a MASTER" $? "${a:-none}"
a=$(val type-b); [ "${a:-none}" = MASTER ]; check "the second volume records its PFS as a MASTER" $? "${a:-none}"
a=$(val quorum-threads); [ "${a:-0}" = 2 ]; check "both MASTER elements have a support thread, so pfs_nmasters is 2" $? "${a:-0} thread(s); one would mean a lone master and no quorum"
a=$(val cluster-mount-rc); [ "${a:-1}" = 0 ]; check "the cluster's PFS mounts" $? "exit ${a:-none}"
a=$(val write-files); [ "${a:-0}" = 24 ]; check "a set written through the quorum lands" $? "${a:-0} of 24 file(s)"
a=$(val reread-mount-rc); [ "${a:-1}" = 0 ]; check "the cluster's PFS mounts again with the caches dropped" $? "exit ${a:-none}"
a=$(val read-sums); [ "${a:-0}" = 24 ]; check "every file reads back through the quorum" $? "${a:-0} of 24 checksum(s)"
# A count of sums says each file opened; only this says what it held. Both
# files must hold 24 lines, so two missing or empty copies cannot compare equal.
w=$(grep -c . "$W/want" 2>/dev/null); s=$(grep -c . "$W/sums" 2>/dev/null)
[ "${w:-0}" = 24 ] && [ "${s:-0}" = 24 ] && cmp -s "$W/want" "$W/sums"
check "every file read back holds what was written" $? "$(diff "$W/want" "$W/sums" 2>/dev/null | grep -c '^>') of ${w:-0} sum(s) differ from the source's"
a=$(sed -n 's/^seek-ok \([0-9]*\) seek-fail \([0-9]*\)$/\1 \2/p' "$W/out"); [ "$a" = "6 0" ]
check "both seeks through the quorum answer the probe's shape after a remount" $? "${a:-no line} (ok, failed of 6)"
a=$(sed -n 's/^map-exit \([0-9]*\) map-extents \([0-9]*\)$/\1 \2/p' "$W/out"); [ "$a" = "0 2" ]
check "FIEMAP through the quorum maps the shape's two data blocks" $? "${a:-no line} (exit, extents)"
grep '^seekm-fail' "$W/out" | sed 's/^/        /'
[ "$QCONTEND" = 0 ] || sed -n 's/^seekm-contend /  contend /p; s/^seekm-time dense-hole /  time dense-hole /p' "$W/out"
if [ "$QCONTEND" != 0 ]; then
	sed -n 's/^seekm-split /  split /p; s/^split-write /  split-write /p' "$W/out"
	a=$(grep -c '^seekm-fail contend' "$W/out")
	[ "$a" = 0 ] && grep -q '^seekm-contend seeking ' "$W/out"
	check "every seek beside the writer answered as the probe required" $? "${a:-none} failure line(s)"
	if [ "$QRULE" != 0 ]; then
		a=$(sed -n 's/^seekm-time dense-hole median-ns \([0-9]*\) n .*/\1/p' "$W/out" | head -1)
		[ -n "$a" ] && [ "$a" -le $((QRULE * 1000000)) ]
		check "the two-master dense SEEK_HOLE median is within $QRULE ms" $? "${a:-none} ns"
		# The writer beside the loop has waited 1.68 to 2.09 times the
		# seek's median in the readings doc/README.status.md lists,
		# unattributed, so the bound held on it is three times the
		# rule rather than a figure inferred from the seek's.
		w=$(sed -n 's/^seekm-contend seeking median-ns \([0-9]*\) .*/\1/p' "$W/out" | head -1)
		[ -n "$w" ] && [ "$w" -le $((3 * QRULE * 1000000)) ]
		check "the writer's median beside the SEEK_HOLE loop is within $((3 * QRULE)) ms" $? "${w:-none} ns"
	fi
	if [ "$QSPLIT" = 1 ]; then
		a=$(sed -n 's/^split-write exit \([0-9]*\) \([0-9]*\) fellback \([0-9]*\)$/\1 \2 \3/p' "$W/out"); set -- $a
		[ "$1" = 0 ] && [ "$2" = 0 ] && [ "${3:-0}" -gt 0 ]
		check "the split block was written on both, then on the first alone, and the seeks fell back" $? "${a:-no line} (exits, fallbacks)"
		h=$(sed -n 's/^seekm-split hole median-ns \([0-9]*\) n [0-9]* answer \([0-9-]*\) errno \([0-9]*\)$/\1 \2 \3/p' "$W/out"); set -- $h
		[ "$2" = -1 ] && [ "$3" = 5 ]
		check "SEEK_HOLE fails EIO at the split block, which the masters disagree on" $? "${h:-no line} (median-ns, answer, errno)"
		w=$(sed -n 's/^seekm-split seeking median-ns \([0-9]*\) .*/\1/p' "$W/out")
		[ -n "$w" ]
		check "a writer was timed beside the split SEEK_HOLE loop" $? "${w:-none} ns"
		if [ "$QRULE" != 0 ]; then
			[ -n "$1" ] && [ "$1" -le $((QRULE * 1000000)) ]
			check "the split SEEK_HOLE median is within $QRULE ms" $? "${1:-none} ns"
			[ -n "$w" ] && [ "$w" -le $((3 * QRULE * 1000000)) ]
			check "the writer's median beside the split SEEK_HOLE loop is within $((3 * QRULE)) ms" $? "${w:-none} ns"
		fi
	fi
fi
if [ "$QVOTE" = 1 ]; then
	vote() { sed -n "s/^vote $1 //p" "$W/out" | head -1; }	# vote <tag>: the line's fields after the tag
	vf() { vote "$1" | awk -v k="$2" '{ for (i = 1; i < NF; i++) if ($i == k) { print $(i + 1); exit } }'; }
	sed -n 's/^vote \([a-z0-9-]*\) diff /  vote diff \1: /p' "$W/out"
	# Agreeing masters: the walk answered every tree read and matched the scan.
	for t in agree-lay agree-shp; do
		l=$(vf $t lines); d=$(vf $t differ); w=$(vf $t walked); b=$(vf $t fellback)
		[ "${l:-0}" -gt 0 ] && [ "$d" = 0 ] && [ "${w:-0}" -gt 0 ] && [ "$b" = 0 ]
		check "$t: both masters walk, agree, and answer as the scan" $? "lines ${l:-none} differ ${d:-none} walked ${w:-none} fellback ${b:-none}"
	done
	# A file held in its inode has no blockref tree: the seek and the map
	# answer from the inode before either reader (hammer2_seek_data_hole(),
	# hammer2_fiemap()), under either setting of seek_scanall, so the two
	# dumps are one early return and neither counter moves.
	l=$(vf agree-emb lines); d=$(vf agree-emb differ); w=$(vf agree-emb walked); b=$(vf agree-emb fellback)
	[ "${l:-0}" -gt 0 ] && [ "$d" = 0 ] && [ "$w" = 0 ] && [ "$b" = 0 ]
	check "agree-emb: a file held in its inode answers from the inode, before any walk or scan" $? "lines ${l:-none} differ ${d:-none} walked ${w:-none} fellback ${b:-none}"
	a=$(vote refuse); set -- $a
	[ "$2" = 0 ] && [ "$4" = 3 ] && [ "$6" = 0 ]
	check "a walk's error on two masters is the call's EIO, with no fallback" $? "${a:-no line}"
	a=$(vote failone); set -- $a
	[ "$2" = 0 ] && [ "$4" = 3 ] && [ "$6" = 0 ]
	check "one master's walk failing while the other answers is the call's EIO, with no fallback" $? "${a:-no line}"
	a=$(vf scanfail-on answer); e=$(vf scanfail-on eio)
	[ "$a" = none ] && [ "$e" = 1 ]
	check "one master's scan failing before a key the other holds fails SEEK_HOLE with EIO, not a hole" $? "answer ${a:-none} eio ${e:-none}"
	a=$(vf scanfail-off answer); e=$(vf scanfail-off eio)
	[ "$a" = 0 ] && [ "$e" = 0 ]
	check "with scan_fail_elm unset the same SEEK_HOLE answers the hole at 0, its control" $? "answer ${a:-none} eio ${e:-none}"
	# The disagreement made, read from each volume's own media.
	key() { sed -n "s/^vote show $1 $2\/[0-9]* \([0-9a-f]*\)$/\1/p" "$W/out" | head -1; }	# volume, the key as show prints it
	key2() { sed -n "s/^vote after $1 $2\/[0-9]* \([0-9a-f]*\)$/\1/p" "$W/out" | head -1; }	# the same, read after the partial write
	xa=$(key a 00000000000a0000); xb=$(key b 00000000000a0000)
	ya=$(key a 00000000000c0000); yb=$(key b 00000000000c0000)
	za=$(key a 0000000000020000); zb=$(key b 0000000000020000)
	[ -n "$xa" ] && [ -z "$xb" ] && [ -z "$ya" ] && [ -n "$yb" ] && [ -n "$za" ] && [ -n "$zb" ] && [ "$za" != "$zb" ]
	check "the masters disagree on media: block 10 on the first only, 12 on the second only, 2 at two tids" $? "10 ${xa:-absent}/${xb:-absent} 12 ${ya:-absent}/${yb:-absent} 2 ${za:-absent}/${zb:-absent}"
	# The map crosses block 2 whichever reader answers, so both dumps end
	# in FIEMAP's EIO; the seeks between them must still answer alike.
	l=$(vf disagree lines); d=$(vf disagree differ); b=$(vf disagree fellback); m=$(vf disagree maperr)
	[ "${l:-0}" -gt 0 ] && [ "$d" = 0 ] && [ "${b:-0}" -gt 0 ] && [ "$m" = 5 ]
	check "masters that disagree fall back to the scan and answer as it does, the map failing EIO" $? "lines ${l:-none} differ ${d:-none} fellback ${b:-none} map errno ${m:-none}"
	a=$(vf inside fellback); b=$(vf outside fellback); o=$(vf outside answer)
	[ "${a:-0}" -gt 0 ] && [ "$b" = 0 ] && [ "$o" = $((24 * 65536)) ]
	check "only a call whose range holds a disagreement falls back" $? "inside ${a:-none} outside ${b:-none}, SEEK_HOLE from block 16 ${o:-none}"
	a=$(vf hole0 answer); e=$(vf hole0 eio)
	[ "$a" = none ] && [ "$e" = 1 ]
	check "SEEK_HOLE from 0 fails EIO at block 2, held at two tids" $? "answer ${a:-none} eio ${e:-none}"
	a=$(vf inside answer); e=$(vf inside eio)
	[ "$a" = none ] && [ "$e" = 1 ]
	check "SEEK_DATA from block 8 fails EIO at block 10, held by the first master alone" $? "answer ${a:-none} eio ${e:-none}"
	# Each disputed block's read fails with EIO, not EINPROGRESS and not
	# zeros, while block 0 of the same file, which both hold at one tid,
	# reads whole.
	bad=0; rd=
	x=$(sed -n "s/^vote read 0 //p" "$W/out" | head -1); set -- $x
	{ [ "$2" = 0 ] && [ "$4" = 65536 ] && [ "${6:-0}" -gt 0 ]; } 2>/dev/null || bad=$((bad + 1))
	rd=" 0: ${x:-no line};"
	for blk in 2 10 12; do
		x=$(sed -n "s/^vote read $blk //p" "$W/out" | head -1); set -- $x
		e=$(sed -n "s/^vote readerr $blk //p" "$W/out" | head -1)
		[ -n "$2" ] && [ "$2" != 0 ] && case $e in *'Input/output error'*) true ;; *) false ;; esac || bad=$((bad + 1))
		rd="$rd $blk: ${x:-no line} (${e:-no message});"
	done
	[ "$bad" = 0 ]
	check "each block the masters disagree on fails its read with EIO, and block 0 reads whole" $? "$rd"
	a=$(vote pwrite); set -- $a
	za2=$(key2 a 0000000000020000); zb2=$(key2 b 0000000000020000)
	[ -n "$2" ] && [ "$2" != 0 ] && [ "$4" = 1 ] && [ -n "$za" ] && [ "$za2" = "$za" ] && [ "$zb2" = "$zb" ]
	check "a partial write into block 2 fails EIO and leaves both masters' copies" $? "${a:-no line}; block 2 before ${za:-absent}/${zb:-absent} after ${za2:-absent}/${zb2:-absent}"
	for k in 1 2; do
		d=$(vf break$k differ)
		[ "$d" = 1 ]
		check "seek_agree_break=$k makes the walk differ from the scan, so the comparison is what decides" $? "differ ${d:-none}"
	done
	a=$(vote rm); [ "$a" = "exit 0" ]
	check "the file the masters disagree on is removed through the quorum" $? "${a:-no line}"
	# Q1. A block on one master because its write has not reached the next
	# is not a disagreement: the call runs once more under the order and
	# answers. Each call's own xop_reruns delta and milliseconds are
	# required, so a call made after the window closed, which answers
	# without having met anything, fails here. With the order out the same
	# call fails EIO, which shows the call met the held window. Whether
	# the writeback returned before the call is printed and not required.
	for k in hole map; do
		a=$(vf wbrace0-$k answer); w=$(vf wbrace0-$k want); e=$(vf wbrace0-$k errno); y=$(vf wbrace0-$k sync)
		r=$(vf wbrace0-$k reruns); m=$(vf wbrace0-$k seek-ms)
		[ -n "$a" ] && [ "$a" = "$w" ] && [ "$e" = 0 ] && [ "${r:-0}" -ge 1 ] 2>/dev/null && [ "${m:-0}" -ge $((QGAP - QDELAY)) ] 2>/dev/null
		check "Q1 $k beside a writeback held between the masters reruns under the order and answers" $? "answer ${a:-none} want ${w:-none} errno ${e:-none} reruns ${r:-none} ms ${m:-none} (at least $((QGAP - QDELAY))) sync ${y:-none}"
		a=$(vf wbrace1-$k answer); e=$(vf wbrace1-$k errno); r=$(vf wbrace1-$k reruns)
		[ -n "$a" ] && [ "$a" -lt 0 ] 2>/dev/null && [ "$e" = 5 ]
		check "Q1 $k with xop_order_off fails EIO in the held window, so the call met it" $? "answer ${a:-none} errno ${e:-none} reruns ${r:-none}"
	done
	# Q2. Each call in a window of its own answers, having rerun and slept
	# through the gap; the page read is the one written before, and the
	# block read back cold is the splice of the writes. A sibling served
	# from the page cache would answer with no rerun, which the delta
	# catches. With the order out each fails EIO.
	for k in read fibmap pwrite; do
		x=$(vote "q20-$k")
		s=$(vf q20-$k exit); e=$(vf q20-$k eio); r=$(vf q20-$k reruns); m=$(vf q20-$k ms); sm=$(vf q20-$k same); f=$(vf q20-$k final); wr=$(vf q20-$k wrote)
		ok=1
		[ "$s" = 0 ] && [ "$e" = 0 ] && [ "${r:-0}" -ge 1 ] 2>/dev/null && [ "${m:-0}" -ge $((QGAP - QDELAY)) ] 2>/dev/null && [ "$f" = 1 ] && ok=0
		case $k in read) [ "$sm" = 1 ] || ok=1 ;; pwrite) [ "$wr" = 1 ] || ok=1 ;; esac
		check "Q2 $k beside a writeback held between the masters reruns under the order and answers" $ok "${x:-no line} (want exit 0, eio 0, reruns at least 1, ms at least $((QGAP - QDELAY)), final 1)"
		x=$(vote "q21-$k"); e=$(vf q21-$k eio)
		[ "${e:-0}" -ge 1 ] 2>/dev/null
		check "Q2 $k with xop_order_off fails EIO in the held window, so the call met it" $? "${x:-no line}"
	done
	# Q3. A delta of 0 with no gap is a reading and not a check; with the
	# gap and the order on, no rerun means nothing exercised the order,
	# and with the order out no EIO means the control did not fire: both
	# make the run COULD-NOT-RUN rather than a pass.
	xa=$(vote q3-a); xb=$(vote q3-b); xc=$(vote q3-c)
	n=$(vf q3-a calls); e=$(vf q3-a eio); r=$(vf q3-a reruns)
	if [ "${r:-0}" -ge 1 ] 2>/dev/null; then
		[ "${n:-0}" -ge 10 ] 2>/dev/null && [ "$e" = 0 ]
		check "Q3(a) a SEEK_HOLE and FIEMAP loop beside a 256 MiB writeback answers every call" $? "${xa:-no line} (want calls at least 10, eio 0)"
	else
		echo "  note  Q3(a) is a reading, not a check: no call met a write in flight (${xa:-no line})"
	fi
	e=$(vf q3-b eio); r=$(vf q3-b reruns)
	if [ "${r:-0}" -ge 1 ] 2>/dev/null; then
		[ "$e" = 0 ]
		check "Q3(b) the loop beside the writeback held 5 ms between the masters answers every call" $? "${xb:-no line} (want eio 0)"
	else
		cnr="${cnr:+$cnr; }Q3(b) exercised no rerun (${xb:-no line})"
	fi
	e=$(vf q3-c eio)
	if [ "${e:-0}" -ge 1 ] 2>/dev/null; then
		check "Q3(c) with xop_order_off the loop fails EIO, so it met the window" 0 "$xc"
	else
		cnr="${cnr:+$cnr; }Q3(c)'s control did not fire (${xc:-no line})"
	fi
	echo "  read  Q3 writeback ms: no gap alone $(vf q3-a-alone ms) beside the loop $(vf q3-a ms); 5 ms gap alone $(vf q3-b-alone ms) beside the loop $(vf q3-b ms)"
	ba=$(vf q3-b-alone ms); bl=$(vf q3-b ms)
	[ -n "$ba" ] && [ -n "$bl" ] && [ "$bl" -gt $((2 * ba)) ] 2>/dev/null &&
		echo "  note  Q3(b)'s writeback beside the loop took more than twice its time alone: the trigger to scope the seek's guard to its chunk (doc/README.porting.md)"
	o=$(vote order-check)
	case $o in
	absent|'') echo "  note  order_check not read: ${o:-no line}, a module or kernel without lockdep" ;;
	*) [ "$o" = 0 ]; check "order_check: every modify of a hashed inode's chain was made under its order" $? "$o" ;;
	esac
	hd=$(val hung-task)
	[ "${hd:-1}" = 0 ]; check "no task was reported hung" $? "${hd:-none} hung-task line(s)"
	da=$(val debug-locks-after)
	if [ -n "$dl" ]; then
		[ "$da" = 1 ]; check "lockdep is still on at the end, so no report turned it off" $? "debug_locks ${da:-none} at the end, ${dl} at the start"
	else
		echo "  note  debug_locks not read: the guest's kernel has no lockdep"
	fi
fi
grep -q '^cluster-umount ok' "$W/out"; check "the cluster unmounts" $? "$(grep -c '^cluster-umount ok' "$W/out") of 1"
a=$(val threads-after); [ "${a:-1}" = 0 ]; check "no thread is left" $? "${a:-none}"
a=$(val scrapped); [ "${a:-1}" = 0 ]; check "nothing is scrapped unwritten" $? "${a:-none} chain(s) scrapped"
grep -q '^rmmod ok' "$W/out"; check "the module unloads" $? "$(grep -c '^rmmod ok' "$W/out") of 1"
if [ "$want_asan" = y ]; then
	[ "${have_asan:-0}" -gt 0 ] 2>/dev/null
	check "the module carries the instrumentation its kernel tree configures" $? "${have_asan:-0} __asan and ${have_ubsan:-0} __ubsan import(s), so a KASAN report can be emitted"
else
	[ "${have_asan:-0}" = 0 ] 2>/dev/null
	check "the module carries no instrumentation, its kernel tree configuring none" $? "${have_asan:-0} __asan import(s); the KASAN and UBSAN patterns below cannot report on this kernel, and say nothing here"
fi
a=$(val kernel-warnings); [ "${a:-1}" = 0 ]; check "no kernel warning, lockdep, KASAN or UBSAN report" $? "${a:-none}"
# A scan that refused is not an empty report. An earlier control run can
# switch kmemleak off, after which it reports nothing and stays off until a
# reboot, so a refusal fails here rather than reading as a clean scan. A
# kernel built without kmemleak has no file to write either, and fails
# the same way unless KDIR's own .config configures no kmemleak, which is
# h2release-7.3tls under H2_QUORUM_CONTEND: there the reading is noted as
# not taken. No value at all means the guest stopped before this point.
kml=$(sed -n 's/^CONFIG_DEBUG_KMEMLEAK=//p' "$KDIR/.config")
c=$(grep -o kmemleak-cleared "$W/out" | wc -l); l=$(val kmemleak); m=$(nval kmemleak); u=$(val kmemleak-unloaded); n=$(nval kmemleak-unloaded); r=$(nval kmemleak-unloaded-range)	# counted by occurrence, so a second marker glued to a line or beside the first on one line is a second clear
case "$l" in
0) [ "$c" = 1 ] && [ "$m" = 1 ] && [ "$n" = 1 ] && [ "$r" = 1 ] && [ "${u:-1}" = 0 ]; check "kmemleak reports nothing of hammer2's" $? "cleared $c time(s), $l printed $m time(s), after the unload ${u:-unread}, printed $n time(s) after $r range line(s)" ;;
unusable) if [ "$kml" = y ]; then check "kmemleak is usable, so a leak would be reported" 1 "the scan refused; an earlier control run switched it off and only a reboot turns it back on"
	else echo "  note  kmemleak not read: $KDIR configures none"; fi ;;
"") check "kmemleak was read before the unload" 1 "no reading before the unload, $n after it with $r range line(s)" ;;
*) check "kmemleak reports nothing of hammer2's" 1 "$l" ;;
esac

for img in "$QA" "$QB"; do
	# The status is captured before anything else runs, since a command
	# substitution in the same command replaces it with its own.
	b=$(basename "$img")
	"$FSCK" "$img" > "$W/fsck.$b" 2>&1
	s=$?
	check "fsck_hammer2 $b" $s "exit $s"
done

# The fingerprint of the cluster's PFS on each volume, as cluster-sync.sh
# reads it. Inode check codes are left out: they cover timestamps and
# transaction ids, which two masters need not share.
fingerprint() {	# image
	"$HAMMER2" -v show "$1" 2>/dev/null | awk '
	/filename "CL"$/ && !on { on = 1; next }
	on && /^ *} \(inode\.[0-9]*, "CL"\)/ { exit }
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
fingerprint "$QA" > "$W/fp.a"
fingerprint "$QB" > "$W/fp.b"
na=$(grep -c ' FILE$' "$W/fp.a" || true)
nb=$(grep -c ' FILE$' "$W/fp.b" || true)
nda=$(grep -c '^data ' "$W/fp.a" || true)
[ "${na:-0}" = 24 ]; check "the first MASTER holds the 24 files by its own media" $? "${na:-0} file entries, ${nda:-0} data blocks"
[ "${nb:-0}" = 24 ]; check "the second MASTER holds them too, so the write reached both" $? "${nb:-0} file entries; 0 would mean only one master was written"
d=$(diff "$W/fp.a" "$W/fp.b" 2>/dev/null | grep -c '^[<>]' || true)
[ "${d:-1}" = 0 ]; check "the two MASTERs match entry for entry and block for block" $? "${d:-none} line(s) differ of $(grep -c . "$W/fp.a" || true)"

# The sync threads under debug 0x8000, per element, printed and not
# checked. Each thread's collect excludes its own element, so the other
# master alone cannot make a quorum of two: noquorum is expected on every
# pass, and idle or idlestamp would be the idle test reached.
K="$FIXDIR/quorum-run-$STAMP.klog"
echo "  read  $(val guest-kernel), lockdep debug_locks ${dl:-absent}"
if [ -r "$K" ]; then
	head -1 "$K" | grep -q 'h2quorum: start' && echo "  read  the kept log starts at the run's marker" ||
		echo "  read  the kept log does not start at the run's marker: the ring wrapped or the marker was never written, and the counts below may be short"
	for i in 0 1; do
		kc() { grep -c "$1 clindex $i" "$K"; }
		echo "  read  clindex $i: pass $(kc 'syncsnap: pass') idle $(kc 'syncsnap: idle') idlestamp $(kc 'syncsnap: idlestamp') noquorum $(kc 'syncsnap: noquorum') flush $(kc 'sync_flush:') verified $(kc 'syncsnap: verified')"
	done
	echo "  read  thread inode updates $(grep -c 'syncthr: update inode' "$K")"
fi
echo "quorum: $checks check(s), $fail failed"
[ "$fail" = 0 ] || exit 1
# A failure above is a finding whether or not a reading was exercised;
# with none, a reading that exercised nothing is no pass.
[ -z "$cnr" ] || { echo "quorum: COULD-NOT-RUN: $cnr" >&2; exit 2; }
exit 0
