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

FIXDIR=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2")}
HAMMER2=${H2_HAMMER2:-$(command -v hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/hammer2")}
FSCK=${H2_FSCK:-$(command -v fsck_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2")}
RUN="timeout ${H2_RUN_TIMEOUT:-600} ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
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
make -s KDIR="$KDIR" >/dev/null 2>&1 || {
	echo "quorum: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko

# What the kernel tree configures against what the module actually carries,
# so a sanitizer reading on the wrong module cannot pass in silence.
# grep -c prints its count and exits 1 on no match, so the count is kept and
# the status discarded.
want_asan=$(sed -n 's/^CONFIG_KASAN=//p' "$KDIR/.config" 2>/dev/null)
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
for img in "$QA" "$QB"; do
	truncate -s 2G "$img" && "$NEWFS" -L ROOT "$img" >/dev/null 2>&1 || {
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

cat > "$W/guest.sh" <<'GUEST'
set -u
# An earlier run's sums would be copied back if this one stopped before
# writing its own, so a comparison could pass on files it never made.
rm -f /tmp/q.want /tmp/q.sums
rmmod hammer2 2>/dev/null; dmesg -C
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
sync
umount /mnt/h2q && echo "cluster-umount ok" || exit 1
umount /mnt/h2b && umount /mnt/h2a || exit 1
echo "threads-after $(ps -eo comm | grep -c '^h2nod')"
echo "kernel-warnings $(dmesg | grep -c -E 'WARNING|BUG:|UBSAN:|circular locking|possible recursive')"
# Before rmmod, so the report's %pS resolves the module's own symbols, and
# after a wait past the scanner's own age rule (kmemleak.c MSECS_MIN_AGE,
# 5000 ms), so what the teardown just freed is old enough to be reported.
# A scan that refuses is what an earlier control run's `echo off` leaves
# behind until a reboot; a refusal is not an empty report.
sleep 6
if echo scan > /sys/kernel/debug/kmemleak 2>/dev/null; then
	echo "kmemleak $(grep -c hammer2 /sys/kernel/debug/kmemleak)"
else
	echo "kmemleak unusable"
fi
rmmod hammer2 && echo "rmmod ok"
echo "scrapped $(dmesg | grep -c unmount_scrap)"
dmesg | tail -40 > /tmp/q.log
GUEST

scp -q "$KO" "$W/guest.sh" "$GUEST_SSH:/tmp/" || { echo "quorum: COULD-NOT-RUN: copy to $GUEST failed" >&2; exit 2; }
$RUN "$GUEST_SSH" "mv /tmp/guest.sh /tmp/h2quorum.sh; CONTROL=${H2_QUORUM_CONTROL:-0} sh /tmp/h2quorum.sh" > "$W/out" 2>&1
rc=$?
[ "$rc" = 124 ] && { echo "  FAIL  the guest run hung past ${H2_RUN_TIMEOUT:-600}s"; exit 1; }
scp -q "$GUEST_SSH:/tmp/q.sums" "$W/sums" >/dev/null 2>&1
scp -q "$GUEST_SSH:/tmp/q.want" "$W/want" >/dev/null 2>&1
for d in vdb vdc; do
	$VIRSH detach-disk "$GUEST" $d --live >/dev/null 2>&1
	$VIRSH detach-disk "$GUEST" $d --config >/dev/null 2>&1
done

val() { sed -n "s/^$1 //p" "$W/out" | head -1; }
fail=0; checks=0
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
# kernel built without kmemleak has no file to write and fails the same
# way, which is right for the two kernels this runs on, both built with
# it. No value at all means the guest stopped before this point.
l=$(val kmemleak)
case "$l" in
0) check "kmemleak reports nothing of hammer2's" 0 "$l" ;;
unusable) check "kmemleak is usable, so a leak would be reported" 1 "the scan refused; an earlier control run switched it off and only a reboot turns it back on" ;;
"") ;;
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

echo "quorum: $checks check(s), $fail failed"
[ "$fail" = 0 ] || exit 1
exit 0
