#!/bin/sh
# Mixed load on a volume for a fixed time, and what it left behind.
#
# test/hammer2-storm.c runs mapped writers, write-then-fsync writers,
# fdatasync batchers and readers on one set of files at once and checks
# every cell it reads.  This builds the module and the exerciser, attaches
# a fresh volume to the guest, runs it for H2_STORM_SECS, then unmounts,
# drops the cache, remounts and has the exerciser check every cell against
# the last write each received, and checks the image with fsck_hammer2.
# Memory available and unreclaimable slab are printed before and after, so
# a long run reports growth as a number.  It is P2's mixed-load and
# storm reading, and with H2_STORM_SECS of hours its soak.
#
#   KDIR=~/kernels/linux-7.3-rc5 bash script/storm.sh
#   H2_STORM_SECS=10800 KDIR=... bash script/storm.sh     a three-hour soak
#
# Not a gate.  Exit 2 without the guest, the tools or a kernel tree.
set -u
cd "$(dirname "$0")/.." || exit 2
FIXDIR=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}
IMG=$FIXDIR/storm.img
SIZE=${H2_STORM_SIZE:-8G}
SECS=${H2_STORM_SECS:-300}
FILES=${H2_STORM_FILES:-8}
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2}
FSCK=${H2_FSCK:-$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2}
KO=src/sys/fs/hammer2/hammer2.ko

case $SECS in ''|*[!0-9]*) echo "storm: COULD-NOT-RUN: H2_STORM_SECS is not a number" >&2; exit 2 ;; esac
[ -x "$NEWFS" ] || { echo "storm: COULD-NOT-RUN: no newfs_hammer2 at $NEWFS" >&2; exit 2; }
[ -x "$FSCK" ] || { echo "storm: COULD-NOT-RUN: no fsck_hammer2 at $FSCK" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "storm: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -f "$KDIR/Makefile" ] || { echo "storm: COULD-NOT-RUN: KDIR=$KDIR is not a kernel tree" >&2; exit 2; }
command -v virsh >/dev/null 2>&1 || { echo "storm: COULD-NOT-RUN: no virsh" >&2; exit 2; }
make KDIR="$KDIR" >/dev/null 2>&1 || { echo "storm: FAIL: the module does not build against $KDIR"; exit 1; }
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
cc -static -O2 -o "$W/storm" test/hammer2-storm.c 2>/dev/null || {
	echo "storm: COULD-NOT-RUN: the exerciser did not compile" >&2; exit 2; }
# The exerciser's own checks have to be able to fail before its pass means
# anything.
"$W/storm" --selftest >/dev/null || { echo "storm: FAIL: the exerciser's selftest failed"; exit 1; }

ssh -o ConnectTimeout=4 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null || {
	echo "storm: COULD-NOT-RUN: $GUEST does not answer ssh" >&2; exit 2; }
guest_rel=$(ssh "$GUEST_SSH" 'uname -r' 2>/dev/null)
ko_rel=$(modinfo -F vermagic "$KO" 2>/dev/null | awk '{print $1}')
[ "$guest_rel" = "$ko_rel" ] || {
	echo "storm: COULD-NOT-RUN: the module is for $ko_rel and $GUEST runs $guest_rel" >&2; exit 2; }

rm -f "$IMG"
truncate -s "$SIZE" "$IMG" && "$NEWFS" -L STORM "$IMG" >/dev/null 2>&1 || {
	echo "storm: COULD-NOT-RUN: newfs_hammer2 failed" >&2; exit 2; }
detach() { $VIRSH detach-disk "$GUEST" vdb --live >/dev/null 2>&1; }
detach
$VIRSH attach-disk "$GUEST" "$IMG" vdb --targetbus virtio --live >/dev/null 2>&1 || {
	echo "storm: COULD-NOT-RUN: could not attach $IMG" >&2; exit 2; }
scp -q "$KO" "$GUEST_SSH:/tmp/h2.ko" && scp -q "$W/storm" "$GUEST_SSH:/tmp/h2storm" || {
	detach; echo "storm: COULD-NOT-RUN: copy to the guest failed" >&2; exit 2; }

run='
i=0; while [ ! -b /dev/vdb ] && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done
mem() { echo "mem available $(awk "/MemAvailable/{print \$2}" /proc/meminfo) kB, unreclaimable slab $(awk "/SUnreclaim/{print \$2}" /proc/meminfo) kB"; }
dmesg -C
rmmod hammer2 2>/dev/null
lsmod | command grep -q "^hammer2 " && { echo "SETUP a hammer2 module is in use on the guest"; exit 0; }
insmod /tmp/h2.ko || { echo "SETUP insmod failed"; exit 0; }
mkdir -p /mnt/storm
mount -t hammer2 /dev/vdb@STORM /mnt/storm || { echo "SETUP mount failed"; exit 0; }
echo "before: $(mem)"
/tmp/h2storm /mnt/storm SECS FILES
echo "run exit $?"
echo "after: $(mem)"
umount /mnt/storm; echo "umount exit $?"
sync; echo 3 > /proc/sys/vm/drop_caches
mount -t hammer2 /dev/vdb@STORM /mnt/storm || { echo "SETUP remount failed"; exit 0; }
/tmp/h2storm --verify /mnt/storm FILES | sed "s/^storm-/verify-/"
umount /mnt/storm; echo "second umount exit $?"
rmmod hammer2; echo "rmmod exit $?"
echo "after unload: $(mem)"
echo "log: bug $(dmesg | grep -c "kernel BUG") oops $(dmesg | grep -ci oops) warn $(dmesg | grep -c "WARNING:") kasan $(dmesg | grep -c "BUG: KASAN") ubsan $(dmesg | grep -c "UBSAN:") lockdep $(dmesg | grep -c "possible circular locking")"
'
run=$(printf '%s' "$run" | sed "s/SECS/$SECS/; s/FILES/$FILES/g")
# The bound is the run plus an hour for the remount and the checks.
out=$(timeout $((SECS + 3600)) ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=8 "$GUEST_SSH" "$run" 2>&1)
rc=$?
detach
printf '%s\n' "$out" | sed 's/^/  /'
[ "$rc" -eq 124 ] && { echo "storm: FAIL: the guest did not finish within $((SECS + 3600)) s"; exit 1; }
case $out in *SETUP*) echo "storm: COULD-NOT-RUN: $(printf '%s\n' "$out" | command grep -m1 SETUP)" >&2; exit 2 ;; esac

fail=0
for want in '^storm-failures 0$' '^verify-failures 0$' '^run exit 0$' '^umount exit 0$' \
    '^second umount exit 0$' '^rmmod exit 0$' \
    '^log: bug 0 oops 0 warn 0 kasan 0 ubsan 0 lockdep 0$'; do
	printf '%s\n' "$out" | command grep -q "$want" || {
		echo "  FAIL  no line matching $want"; fail=$((fail + 1)); }
done
# A run whose roles did nothing would pass every check above, so each
# role's count is required to be non-zero here as well as in the exerciser.
printf '%s\n' "$out" | command grep -q '^storm-ops .* 0$' && {
	echo "  FAIL  a role completed no operation"; fail=$((fail + 1)); }
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "  ok    fsck_hammer2 clean after the run" || {
	echo "  FAIL  fsck_hammer2 after the run"; fail=$((fail + 1)); }
echo "storm: $SECS s over $FILES files, $fail failure(s)"
[ "$fail" -eq 0 ]
