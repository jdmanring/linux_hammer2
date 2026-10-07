#!/bin/sh
# xfstests against this port on the guest, a list of tests at a time.
#
# xfstests is the conformance suite every Linux filesystem answers to, and
# the first test run here, generic/001, found a defect three weeks of this
# tree's own gates had not: SEEK_HOLE called every file small enough to
# live in the inode a hole, so cp wrote zeros. Its tests are written to
# the VFS contract rather than to this driver, so a result here is about
# the contract.
#
# The suite is upstream's, at the clone named by H2_XFSTESTS, with
# test/xfstests/hammer2.patch applied to a scratch copy: a common/hammer2
# naming newfs_hammer2 as the format step, and the two arms in common/config
# and common/rc that select it. The clone itself is never written to. The
# patch is the whole adapter because the port meets the rest of the device
# contract already: a bare device mounts the DATA PFS newfs_hammer2 makes by
# default, which is what xfstests hands it.
#
# Two scratch volumes are made and attached, since TEST_DEV and SCRATCH_DEV
# must differ, and found on the guest by their contents rather than by a
# device name: libvirt's target names and the guest's enumeration drift
# apart across attach cycles, and a run that formatted the guest's wrong
# disk would be the worst possible outcome of a test harness.
#
#   bash script/xfstests.sh generic/001 generic/013 ...
#   H2_XFSTESTS_TESTS="-g quick" bash script/xfstests.sh
#
# src/locktest does not build against the kernel of record's headers, whose
# fcntl.h now defines struct delegation; the four generic tests that use it
# (131, 571, 786, 787) report it missing and are not this port's result.
#
# Exit 2 without the guest, the clone, newfs_hammer2 or a kernel tree, and
# 1 on any test that failed. A test xfstests skips is neither.
set -u
cd "$(dirname "$0")/.." || exit 2
ROOT=$(pwd)
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
XFS=${H2_XFSTESTS:-$HOME/Projects/xfstests-dev}
NEWFS=${H2_NEWFS:-$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2}
FIXDIR=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}
PATCH=$ROOT/test/xfstests/hammer2.patch
KO=src/sys/fs/hammer2/hammer2.ko
TESTS=${H2_XFSTESTS_TESTS:-$*}

[ -n "$TESTS" ] || { echo "xfstests: COULD-NOT-RUN: no tests named" >&2; exit 2; }
[ -x "$XFS/check" ] || { echo "xfstests: COULD-NOT-RUN: no xfstests clone at $XFS" >&2; exit 2; }
[ -f "$XFS/include/builddefs" ] || { echo "xfstests: COULD-NOT-RUN: $XFS is not configured" >&2; exit 2; }
[ -x "$NEWFS" ] || { echo "xfstests: COULD-NOT-RUN: no newfs_hammer2 at $NEWFS" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "xfstests: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -f "$KDIR/Makefile" ] || { echo "xfstests: COULD-NOT-RUN: KDIR=$KDIR is not a kernel tree" >&2; exit 2; }
command -v virsh >/dev/null 2>&1 || { echo "xfstests: COULD-NOT-RUN: no virsh" >&2; exit 2; }
make KDIR="$KDIR" >/dev/null 2>&1 || { echo "xfstests: FAIL: the module does not build against $KDIR"; exit 1; }

work=$(mktemp -d) || exit 2
TV=$FIXDIR/xfstests-test.img
SV=$FIXDIR/xfstests-scratch.img
detach() {
	for t in vdx vdy; do
		$VIRSH detach-disk "$GUEST" "$t" --live >/dev/null 2>&1
		$VIRSH detach-disk "$GUEST" "$t" --config >/dev/null 2>&1
	done
}
cleanup() { detach; rm -rf "$work"; rm -f "$TV" "$SV"; }
trap cleanup EXIT

# The adapter goes on a copy, so the clone stays upstream's.
tar -C "$XFS" --exclude=.git -cf - . | tar -C "$work" -xf - || exit 2
(cd "$work" && patch -p1 -s < "$PATCH") || {
	echo "xfstests: COULD-NOT-RUN: $PATCH does not apply to $XFS" >&2; exit 2; }

ssh -o ConnectTimeout=4 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null || {
	echo "xfstests: COULD-NOT-RUN: $GUEST does not answer ssh" >&2; exit 2; }
guest_rel=$(ssh "$GUEST_SSH" 'uname -r' 2>/dev/null)
ko_rel=$(modinfo -F vermagic "$KO" 2>/dev/null | awk '{print $1}')
[ "$guest_rel" = "$ko_rel" ] || {
	echo "xfstests: COULD-NOT-RUN: the module is for $ko_rel and $GUEST runs $guest_rel" >&2; exit 2; }

# Made with newfs_hammer2's defaults, so each has the DATA PFS a bare
# device mounts. xfstests reformats the scratch volume itself.
for img in "$TV" "$SV"; do
	rm -f "$img"; truncate -s 2G "$img"
	"$NEWFS" "$img" >/dev/null 2>&1 || {
		echo "xfstests: COULD-NOT-RUN: newfs_hammer2 failed on $img" >&2; exit 2; }
done
detach
$VIRSH attach-disk "$GUEST" "$TV" vdx --targetbus virtio --serial h2xtest >/dev/null 2>&1 &&
$VIRSH attach-disk "$GUEST" "$SV" vdy --targetbus virtio --serial h2xscratch >/dev/null 2>&1 || {
	echo "xfstests: COULD-NOT-RUN: could not attach the volumes" >&2; exit 2; }

ssh "$GUEST_SSH" 'rm -rf /root/h2xfstests; mkdir -p /root/h2xfstests' &&
tar -C "$work" -cf - . | ssh "$GUEST_SSH" 'tar -C /root/h2xfstests -xf -' &&
scp -q "$KO" "$GUEST_SSH:/tmp/h2.ko" || {
	echo "xfstests: COULD-NOT-RUN: copy to the guest failed" >&2; exit 2; }

# The devices are found by serial, which libvirt passes through unchanged,
# so the names below are the guest's own and cannot be another disk.
run='
set -u
i=0; while [ ! -e /dev/disk/by-id/virtio-h2xscratch ] && [ $i -lt 15 ]; do sleep 1; i=$((i+1)); done
T=$(readlink -f /dev/disk/by-id/virtio-h2xtest)
S=$(readlink -f /dev/disk/by-id/virtio-h2xscratch)
[ -b "$T" ] && [ -b "$S" ] && [ "$T" != "$S" ] || { echo "SETUP the volumes are not both present"; exit 0; }
rmmod hammer2 2>/dev/null; insmod /tmp/h2.ko || { echo "SETUP insmod failed"; exit 0; }
mkdir -p /mnt/h2xtest /mnt/h2xscratch
cd /root/h2xfstests || exit 0
printf "%s\n" "export FSTYP=hammer2" "export TEST_DEV=$T" "export TEST_DIR=/mnt/h2xtest" \
    "export SCRATCH_DEV=$S" "export SCRATCH_MNT=/mnt/h2xscratch" \
    "export NEWFS_HAMMER2=/root/h2xfstests/newfs_hammer2" > local.config
'
scp -q "$NEWFS" "$GUEST_SSH:/root/h2xfstests/newfs_hammer2" || exit 2
out=$(ssh "$GUEST_SSH" "$run
./check $TESTS 2>&1
umount /mnt/h2xtest /mnt/h2xscratch 2>/dev/null
rmmod hammer2; echo \"rmmod exit \$?\"
echo \"log: bug \$(dmesg | grep -c \"kernel BUG\") oops \$(dmesg | grep -ci oops) warn \$(dmesg | grep -c \"WARNING:\")\"" 2>&1)
printf '%s\n' "$out" | sed 's/^/  /'

case $out in *SETUP*) echo "xfstests: COULD-NOT-RUN: $(printf '%s\n' "$out" | command grep -m1 SETUP)" >&2; exit 2 ;; esac
ran=$(printf '%s\n' "$out" | sed -n 's/^Ran: //p')
failed=$(printf '%s\n' "$out" | sed -n 's/^Failures: //p')
[ -n "$ran" ] || { echo "xfstests: COULD-NOT-RUN: check ran no test" >&2; exit 2; }
fail=0
[ -n "$failed" ] && fail=1
printf '%s\n' "$out" | command grep -q '^log: bug 0 oops 0 warn 0$' || {
	echo "  FAIL  the kernel log is not clean"; fail=1; }
echo "xfstests: ran $ran; failed ${failed:-none}"
[ "$fail" -eq 0 ]
