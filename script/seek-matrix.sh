#!/bin/sh
# SEEK_DATA and SEEK_HOLE across a snapshot, a hard stop and a dedup,
# the three cases of P1 that need the guest's lifecycle rather than a
# file on a mounted volume. test/hammer2-seek.c on the enospc gate owns
# the rest: unsynced, boundary, regrown, mapped and compressed.
#
# Each answer is checked against a file whose shape the guest just made:
# one 64 KiB block of data, one of hole, one of data, a truncate past it.
#
#   snapshot  the file is written and not synced, and a snapshot taken.
#             The snapshot ioctl syncs the filesystem first (the
#             non-NOSYNC branch of hammer2_ioctl_pfs_snapshot()), so the
#             snapshot holds the data and both trees answer with it.
#   crash     a file synced, then a second written on top of it and not
#             synced, then a hard stop. The synced prefix answers in
#             full after the reboot, and the file itself still exists, so
#             agree() reads the recovered file: no range SEEK_HOLE calls
#             a hole may read back nonzero. That is the branch the case
#             is for, and it only runs if the file survives, so what was
#             synced is a prefix that stays.
#   dedup     two files of 16 incompressible blocks, the second asked
#             while unsynced and again once its blocks have deduplicated
#             against the first's. That they did is read from the free
#             count, as test/hammer2-dedup.c reads it: the second file
#             must cost under a quarter of what the first did, or the
#             case is about nothing. Sixteen blocks rather than the seek
#             shape's three, because a first file costing one block makes
#             the rule pass without the sharing being measured.
#
# Exit 2 without the guest, newfs_hammer2 or a kernel tree, never 1.
set -u
cd "$(dirname "$0")/.." || exit 2
FIXDIR=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}
IMG=$FIXDIR/seek-matrix.img
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2}
FSCK=${H2_FSCK:-$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2}
KO=src/sys/fs/hammer2/hammer2.ko

[ -x "$NEWFS" ] || { echo "seek-matrix: COULD-NOT-RUN: no newfs_hammer2 at $NEWFS" >&2; exit 2; }
[ -x "$FSCK" ] || { echo "seek-matrix: COULD-NOT-RUN: no fsck_hammer2 at $FSCK" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "seek-matrix: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -f "$KDIR/Makefile" ] || { echo "seek-matrix: COULD-NOT-RUN: KDIR=$KDIR is not a kernel tree" >&2; exit 2; }
command -v virsh >/dev/null 2>&1 || { echo "seek-matrix: COULD-NOT-RUN: no virsh" >&2; exit 2; }
make KDIR="$KDIR" >/dev/null 2>&1 || { echo "seek-matrix: FAIL: the module does not build against $KDIR"; exit 1; }
[ -f "$KO" ] || { echo "seek-matrix: FAIL: $KO was not produced"; exit 1; }
cc -static -O2 -o /tmp/h2seekprobe.$$ test/hammer2-seekprobe.c 2>/dev/null || {
	echo "seek-matrix: COULD-NOT-RUN: the seek probe did not compile" >&2; exit 2; }
trap 'rm -f /tmp/h2seekprobe.$$' EXIT

guest_up() {
	i=0
	while [ "$i" -lt 60 ]; do
		ssh -o ConnectTimeout=4 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null && return 0
		sleep 5; i=$((i + 1))
	done
	return 1
}
guest_up || { echo "seek-matrix: COULD-NOT-RUN: $GUEST does not answer ssh" >&2; exit 2; }
guest_rel=$(ssh "$GUEST_SSH" 'uname -r' 2>/dev/null)
ko_rel=$(modinfo -F vermagic "$KO" 2>/dev/null | awk '{print $1}')
[ "$guest_rel" = "$ko_rel" ] || {
	echo "seek-matrix: COULD-NOT-RUN: the module is for $ko_rel and $GUEST runs $guest_rel" >&2; exit 2; }

rm -f "$IMG"
truncate -s 1G "$IMG" && "$NEWFS" -L SM "$IMG" >/dev/null 2>&1 || {
	echo "seek-matrix: COULD-NOT-RUN: newfs_hammer2 failed" >&2; exit 2; }
attach() {
	$VIRSH attach-disk "$GUEST" "$IMG" vdb --targetbus virtio >/dev/null 2>&1 &&
	    ssh "$GUEST_SSH" 'i=0; while [ ! -b /dev/vdb ] && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done; [ -b /dev/vdb ]'
}
detach() { $VIRSH detach-disk "$GUEST" vdb --live >/dev/null 2>&1; $VIRSH detach-disk "$GUEST" vdb --config >/dev/null 2>&1; }
detach
attach || { echo "seek-matrix: COULD-NOT-RUN: could not attach $IMG" >&2; exit 2; }
scp -q "$KO" "$GUEST_SSH:/tmp/h2.ko" && scp -q /tmp/h2seekprobe.$$ "$GUEST_SSH:/tmp/h2seekprobe" || {
	detach; echo "seek-matrix: COULD-NOT-RUN: copy to the guest failed" >&2; exit 2; }

# Phase one, on the running guest: snapshot and dedup, then the crash
# setup ending in the write the hard stop interrupts. Every line the
# guest prints is prefixed with what it reports so the host counts it.
# The two guest scripts are named values rather than literals after the
# ssh command, because test-posix.sh reads a remote block as the text from
# an ssh invocation's opening quote to the next line that is a lone quote.
# A second literal block in one file would be read as part of the first
# and its own quotes counted against it. Passing the script as a variable
# keeps each block a single-quoted string with no quote of its own inside
# it, which is the property that gate is there to check.
pre_stop='
dmesg -C
insmod /tmp/h2.ko || { echo "SETUP insmod failed"; exit 0; }
mkdir -p /mnt/sm
mount -t hammer2 /dev/vdb@SM /mnt/sm || { echo "SETUP mount failed"; exit 0; }
P=/tmp/h2seekprobe
$P make /mnt/sm/live
hammer2 snapshot /mnt/sm SNAP >/dev/null 2>&1; echo "snapshot exit $?"
$P check /mnt/sm/live "live after the snapshot"
mkdir -p /mnt/snap
mount -t hammer2 /dev/vdb@SNAP /mnt/snap || echo "seekm-fail the snapshot did not mount"
$P check /mnt/snap/live "the snapshot"
umount /mnt/snap
free() { stat -f -c %f /mnt/sm; }
sync -f /mnt/sm; f0=$(free)
$P dedup /mnt/sm/dedup-a 16
sync -f /mnt/sm; f1=$(free)
$P dedup /mnt/sm/dedup-b 16
sync -f /mnt/sm; f2=$(free)
echo "dedup cost first $((f0 - f1)) second $((f1 - f2))"
$P make /mnt/sm/shared-a rand
$P make /mnt/sm/shared-b rand
sync -f /mnt/sm
$P check /mnt/sm/shared-b "data shared with a sibling"
$P make /mnt/sm/crash-synced
$P make /mnt/sm/crash
sync -f /mnt/sm
head -c 65536 /dev/zero | tr "\0" B | dd of=/mnt/sm/crash bs=65536 seek=5 count=1 conv=notrunc 2>/dev/null
echo "SETUP ready for the stop"
'
out=$(ssh "$GUEST_SSH" "$pre_stop" 2>&1)
printf '%s\n' "$out" | sed 's/^/  /'
case $out in *"SETUP ready for the stop"*) ;; *)
	detach; echo "seek-matrix: COULD-NOT-RUN: the guest did not reach the stop" >&2; exit 2 ;; esac

# The hard stop. destroy, not shutdown: nothing gets to flush.
$VIRSH destroy "$GUEST" >/dev/null 2>&1
sleep 3
detach
"$FSCK" "$IMG" >/dev/null 2>&1; fsck_rc=$?
$VIRSH start "$GUEST" >/dev/null 2>&1
guest_up || { echo "seek-matrix: COULD-NOT-RUN: $GUEST did not come back after the stop" >&2; exit 2; }
attach || { echo "seek-matrix: COULD-NOT-RUN: could not reattach $IMG" >&2; exit 2; }
scp -q "$KO" "$GUEST_SSH:/tmp/h2.ko" && scp -q /tmp/h2seekprobe.$$ "$GUEST_SSH:/tmp/h2seekprobe"
post_stop='
insmod /tmp/h2.ko || { echo "SETUP insmod failed"; exit 0; }
mkdir -p /mnt/sm
mount -t hammer2 /dev/vdb@SM /mnt/sm || { echo "SETUP remount failed"; exit 0; }
P=/tmp/h2seekprobe
$P check /mnt/sm/crash-synced "synced before the stop"
if [ -e /mnt/sm/crash ]; then
	echo "crash file size $(stat -c %s /mnt/sm/crash)"
	$P agree /mnt/sm/crash "extended unsynced at the stop"
else
	echo "seekm-fail the synced file extended at the stop is gone"
fi
$P check /mnt/sm/live "live after recovery"
umount /mnt/sm; echo "umount exit $?"
rmmod hammer2; echo "rmmod exit $?"
echo "log: bug $(dmesg | grep -c "kernel BUG") oops $(dmesg | grep -ci oops) warn $(dmesg | grep -c "WARNING:")"
'
out2=$(ssh "$GUEST_SSH" "$post_stop" 2>&1)
printf '%s\n' "$out2" | sed 's/^/  /'
detach

all=$(printf '%s\n%s\n' "$out" "$out2")
fail=0
ok=$(printf '%s\n' "$all" | command grep -c '^seekm-ok')
bad=$(printf '%s\n' "$all" | command grep -c '^seekm-fail')
fail=$((fail + bad))
for want in "^snapshot exit 0$" "^umount exit 0$" "^rmmod exit 0$" "^log: bug 0 oops 0 warn 0$"; do
	printf '%s\n' "$all" | command grep -q "$want" || {
		echo "  FAIL  no line matching $want"; fail=$((fail + 1)); }
done
case $all in *SETUP*failed*) echo "  FAIL  $(printf '%s\n' "$all" | command grep -m1 'SETUP.*failed')"; fail=$((fail + 1)) ;; esac
# A check prints six lines and an agree one: the live file twice, the
# snapshot and the synced crash file are four checks, the shared-sibling
# file a fifth, and the extended crash file one agree, so 31 is the whole
# run. A count below it is a run that asked less than it says, so it is
# failed rather than read.
[ "$ok" -eq 31 ] || { echo "  FAIL  $ok probe check(s) passed where 31 are asked"; fail=$((fail + 1)); }
# Dedup has to have happened for its case to mean anything.
set -- $(printf '%s\n' "$all" | sed -n 's/^dedup cost first \([0-9-]*\) second \([0-9-]*\)$/\1 \2/p')
if [ $# -ne 2 ] || [ "$1" -le 0 ]; then
	echo "  FAIL  the dedup case moved no free count, so it is about nothing"; fail=$((fail + 1))
elif [ $(($2 * 4)) -ge "$1" ]; then
	echo "  FAIL  the second dedup file cost $2 blocks against the first's $1: not shared"; fail=$((fail + 1))
else
	echo "  ok    dedup shared: the second file cost $2 blocks against the first's $1"
fi
[ "$fsck_rc" -eq 0 ] && echo "  ok    fsck_hammer2 clean after the hard stop" || {
	echo "  FAIL  fsck_hammer2 exit $fsck_rc after the hard stop"; fail=$((fail + 1)); }
echo "seek-matrix: $ok probe check(s), $fail failure(s)"
rm -f "$IMG"
[ "$fail" -eq 0 ]
