#!/bin/sh
# Whether an unmount can free the PFS a PFS create or snapshot is joining.
# hammer2_pfsalloc() walks hammer2_pfslist for the PFS of the new root's
# cluster id and then joins the root to it. An unmount that tears down the
# last device of that cluster in between frees that PFS in
# hammer2_pfsfree_scan(); the create ioctl holds hammer2_mntlk across the
# call so the unmount waits for it.
#
# H2_SNAP_RACE=1 adds the snapshot arm: `pfsalloc_walk_hold_ms` stops the
# pfsalloc list walk after one entry is read, an unmount of the vdc PFS
# frees that entry, and the NOSYNC snapshot on vdb resumes the walk. The
# unfixed module faults reading freed memory; the fix releases the
# snapshot's transaction and bulklk before registering under mntlk, so
# the unmount waits, the snapshot returns 0 and its root mounts. A run
# that never reaches the hold is COULD-NOT-RUN, not a pass.
#
# Two volumes on the guest, ROOT on each. On vdc a MASTER named CLn is
# created and ROOT unmounted, so vdc's one mount is vdc@CLn; on vdb ROOT is
# mounted, and a MASTER of CLn's cluster id is created there, which the
# walk resolves to CLn's PFS. Two arms in one boot, the race first, on
# volumes no cluster spans yet. An arm run before it leaves a PFS mastered
# on both volumes, and the teardown of vdc syncs every PFS with an element
# there (hammer2_pfsfree_scan()); with the plain arm first, the unmount on
# 7d92a705 waited out the held create and the arm passed, on both builds.
#
#   race   pfsalloc_hold_ms=5000 holds the create after its walk; the
#          unmount of vdc@CL1 is issued once the hold's start line is in
#          the log. The unmount must wait: the create has exited by the
#          time the unmount returns, and the unmount took most of the
#          hold. Without the lock the unmount returns at once, the create
#          is still held, and when the hold ends it reads the freed PFS
#          (a page fault on the debug build, a vmalloc-out-of-bounds read
#          in hammer2_pfsalloc() on KASAN, at 7d92a705).
#   plain  the create, then the unmount of vdc@CL2. The baseline: create 0,
#          unmount 0, vdb@CL2 mounts.
#
# The race's reading is taken in userland and does not need the kernel
# log: a control guest that faults after it still has printed it, and is
# judged a failure, not a run that could not read. The log is read for
# the hold's start line and for warnings, behind the ring marker.
# H2_KO names a module built with HAMMER2_LOCKDEBUG=1 for the guest's
# kernel. Needs the fleet; exits 2 without it, 1 on a failed check.
set -u
KO=${H2_KO:-}
[ -n "$KO" ] && [ -f "$KO" ] || { echo "COULD-NOT-RUN: H2_KO names no module"; exit 2; }
export LIBVIRT_DEFAULT_URI=${H2_LIBVIRT_URI:-qemu:///system}
command -v virsh >/dev/null 2>&1 || { echo "COULD-NOT-RUN: no virsh"; exit 2; }
GUEST=${H2_GUEST:-artix-s6-kde}; GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
FIX=${H2_FIXTURE_DIR:-$HOME/Projects/linux_hammer2-data/fixtures}
IA=$FIX/create-race-a.img IB=$FIX/create-race-b.img
SNAP_ARM=${H2_SNAP_RACE:-0}
NEWFS=${H2_NEWFS:-$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2}
SSH="ssh -o ServerAliveInterval=5 -o ServerAliveCountMax=6 -o ConnectTimeout=5 -o BatchMode=yes"
T=$(mktemp) || exit 2
trap 'rm -f "$T"' EXIT
nf=0; nc=0
want() {	# description, extended regex that a line of the run must match
	nc=$((nc + 1))
	grep -Eq -- "$2" "$T" && echo "  ok    $1" || { echo "  FAIL  $1"; nf=$((nf + 1)); }
}
down() {
	virsh detach-disk $GUEST vdc >/dev/null 2>&1; virsh detach-disk $GUEST vdb >/dev/null 2>&1
	virsh shutdown $GUEST >/dev/null 2>&1
	i=0; while [ "$(virsh domstate $GUEST)" != "shut off" ] && [ $i -lt 45 ]; do sleep 2; i=$((i+1)); done
	[ "$(virsh domstate $GUEST)" = "shut off" ] || { echo "guest did not shut down, destroyed"; virsh destroy $GUEST >/dev/null 2>&1; }
}
for img in "$IA" "$IB"; do
	rm -f "$img"; truncate -s $([ "$SNAP_ARM" = 1 ] && echo 2G || echo 1G) "$img" &&
	    "$NEWFS" -L ROOT "$img" >/dev/null 2>&1 ||
	    { echo "COULD-NOT-RUN: newfs"; exit 2; }
done
[ "$(virsh domstate $GUEST)" = "shut off" ] || { echo "COULD-NOT-RUN: $GUEST is $(virsh domstate $GUEST)"; exit 2; }
virsh start $GUEST >/dev/null 2>&1
i=0; until $SSH "$GUEST_SSH" true 2>/dev/null; do sleep 5; i=$((i+1)); [ $i -ge 60 ] && { echo "COULD-NOT-RUN: no ssh"; down; exit 2; }; done
kr=$($SSH "$GUEST_SSH" uname -r) vm=$(modinfo -F vermagic "$KO" | cut -d' ' -f1)
[ "$kr" = "$vm" ] || { echo "COULD-NOT-RUN: the module is for $vm, $GUEST runs $kr"; down; exit 2; }
# One lockdep report turns lockdep off until the next boot.
dl=$($SSH "$GUEST_SSH" "awk '/debug_locks:/ {print \$2}' /proc/lockdep_stats 2>/dev/null")
[ "$dl" = 0 ] && { echo "COULD-NOT-RUN: lockdep is off on $GUEST since an earlier report"; down; exit 2; }
virsh attach-disk $GUEST "$IA" vdb --targetbus virtio >/dev/null 2>&1 &&
    virsh attach-disk $GUEST "$IB" vdc --targetbus virtio >/dev/null 2>&1 ||
    { echo "COULD-NOT-RUN: attach"; down; exit 2; }
scp -q "$KO" "$GUEST_SSH:/tmp/h2.ko" || { echo "COULD-NOT-RUN: copy"; down; exit 2; }
echo "pfs-create-race: module $(sha256sum "$KO" | cut -c1-16) on $kr"
timeout 300 $SSH "$GUEST_SSH" "SNAP_ARM=$SNAP_ARM sh" <<"REMOTE" 2>&1 | sed "s/^/  guest /" | tee -a "$T"
dmesg -C; echo h2ring-start > /dev/kmsg
insmod /tmp/h2.ko || { echo "insmod failed"; exit 9; }
P=/sys/module/hammer2/parameters/pfsalloc_hold_ms
test -w $P || { echo "no pfsalloc_hold_ms: not a HAMMER2_LOCKDEBUG module"; exit 9; }
W=/sys/module/hammer2/parameters/pfsalloc_walk_hold_ms
[ "$SNAP_ARM" != 1 ] || test -w $W ||
    { echo "no pfsalloc_walk_hold_ms: not a HAMMER2_LOCKDEBUG module"; exit 9; }
mkdir -p /mnt/h2a /mnt/h2c /mnt/h2q
mount -t hammer2 /dev/vdb@ROOT /mnt/h2a || { echo "mount vdb ROOT failed"; exit 9; }
now() { date +%s%N; }
for arm in race plain; do
	n=CL2; [ $arm = race ] && n=CL1
	mount -t hammer2 /dev/vdc@ROOT /mnt/h2c || { echo "$arm mount vdc ROOT failed"; exit 9; }
	hammer2 -s /mnt/h2c pfs-create $n >/dev/null 2>&1 || { echo "$arm pfs-create on vdc failed"; exit 9; }
	clid=$(hammer2 -s /mnt/h2c pfs-clid $n 2>/dev/null)
	umount /mnt/h2c && mount -t hammer2 /dev/vdc@$n /mnt/h2q || { echo "$arm remount vdc@$n failed"; exit 9; }
	if [ $arm = race ]; then
		echo 5000 > $P
		hammer2 -s /mnt/h2a -t MASTER -u "$clid" pfs-create $n > /tmp/create.out 2>&1 &
		cpid=$!
		i=0; until dmesg | grep -q "hammer2: pfsalloc held" || [ $i -ge 60 ]; do sleep 0.5; i=$((i+1)); done
		dmesg | grep -q "hammer2: pfsalloc held" && echo "$arm hold started" ||
		    { echo "$arm no hold within 30 s"; echo 0 > $P; wait $cpid; exit 9; }
		t0=$(now); umount /mnt/h2q; u=$?; t1=$(now)
		kill -0 $cpid 2>/dev/null && echo "$arm create running when the unmount returned" ||
		    echo "$arm create done when the unmount returned"
		echo "$arm unmount $u after $(( (t1 - t0) / 1000000 )) ms"
		i=0; while kill -0 $cpid 2>/dev/null && [ $i -lt 120 ]; do sleep 0.5; i=$((i+1)); done
		kill -0 $cpid 2>/dev/null && { echo "$arm create still running 60 s later"; exit 9; }
		wait $cpid; echo "$arm create $?"
		echo 0 > $P
	else
		hammer2 -s /mnt/h2a -t MASTER -u "$clid" pfs-create $n > /tmp/create.out 2>&1
		echo "$arm create $?"
		umount /mnt/h2q; echo "$arm unmount $? after 0 ms"
	fi
	mount -t hammer2 /dev/vdb@$n /mnt/h2q; echo "$arm mount vdb@$n $?"
	umount /mnt/h2q
done
if [ "$SNAP_ARM" = 1 ]; then
	mount -t hammer2 /dev/vdc@ROOT /mnt/h2c || { echo "snap mount vdc ROOT failed"; exit 9; }
	hammer2 -s /mnt/h2c pfs-create CL3 >/dev/null 2>&1 || { echo "snap pfs-create failed"; exit 9; }
	clid=$(hammer2 -s /mnt/h2c pfs-clid CL3 2>/dev/null)
	umount /mnt/h2c && mount -t hammer2 /dev/vdc@CL3 /mnt/h2q ||
	    { echo "snap remount vdc@CL3 failed"; exit 9; }
	echo 5000 > $W
	hammer2 -s /mnt/h2a snapshot-debug /mnt/h2a SNAP1 > /tmp/snap.out 2>&1 &
	spid=$!
	i=0; until dmesg | grep -q "hammer2: pfsalloc walk held" || [ $i -ge 60 ]; do sleep 0.5; i=$((i+1)); done
	dmesg | grep -q "hammer2: pfsalloc walk held" && echo "snap walk held" ||
	    { echo "snap no walk within 30 s"; echo 0 > $W; wait $spid; exit 9; }
	t0=$(now); umount /mnt/h2q; u=$?; t1=$(now)
	kill -0 $spid 2>/dev/null && echo "snap snapshot running when the unmount returned" ||
	    echo "snap snapshot done when the unmount returned"
	echo "snap unmount $u after $(( (t1 - t0) / 1000000 )) ms"
	i=0; while kill -0 $spid 2>/dev/null && [ $i -lt 120 ]; do sleep 0.5; i=$((i+1)); done
	kill -0 $spid 2>/dev/null && { echo "snap snapshot still running 60 s later"; exit 9; }
	wait $spid; echo "snap snapshot $? [$(tr '\n' ' ' < /tmp/snap.out)]"
	echo 0 > $W
	mount -t hammer2 /dev/vdb@SNAP1 /mnt/h2q; echo "snap mount vdb@SNAP1 $?"
	[ "$(dmesg | grep -c 'hammer2: pfsalloc walk held')" -ge 5 ] &&
	    echo "snap walk repeated under the unmount" || echo "snap walk did not repeat"
	umount /mnt/h2q 2>/dev/null
fi
umount /mnt/h2a; echo "umount vdb ROOT $?"
rmmod hammer2; echo "rmmod $?"
test -x /var/lib/h2ring-flood && /var/lib/h2ring-flood; dmesg | grep -q h2ring-start && echo ring whole || echo ring COULD-NOT-READ
echo "log: warn $(dmesg | grep -c "WARNING:") bug $(dmesg | grep -c "BUG:") kasan $(dmesg | grep -c "KASAN") circular $(dmesg | grep -c "circular") cut $(dmesg | grep -c "cut here")"
REMOTE
down
v=$(grep -E 'guest (insmod failed|no pfsalloc_hold_ms|no pfsalloc_walk_hold_ms|race no hold within|snap no walk within|snap (pfs-create failed|mount vdc|remount|snapshot running|still running)|snap walk held$)' "$T") && {
	echo "pfs-create-race: COULD-NOT-RUN: ${v#  guest }" >&2; exit 2; }
want "the plain create returned 0" 'guest plain create 0$'
want "the plain unmount returned 0" 'guest plain unmount 0 '
want "vdb@CL2 mounts after the plain arm" 'guest plain mount vdb@CL2 0$'
want "the race's hold started" 'guest race hold started$'
want "the create was done when the unmount returned" 'guest race create done when the unmount returned$'
want "the race's unmount waited most of the hold" 'guest race unmount 0 after ([4-9][0-9]{3}|[1-9][0-9]{4,}) ms$'
want "the race's create returned 0" 'guest race create 0$'
want "vdb@CL1 mounts after the race" 'guest race mount vdb@CL1 0$'
if [ "$SNAP_ARM" = 1 ]; then
	want "the snapshot's walk held" 'guest snap walk held$'
	want "the snapshot finished when the unmount returned" 'guest snap snapshot done when the unmount returned$'
	want "the snapshot's unmount waited for the walk" 'guest snap unmount 0 after ([4-9][0-9]{3}|[1-9][0-9]{4,}) ms$'
	want "the snapshot returned 0" 'guest snap snapshot 0 \[created snapshot SNAP1 \]$'
	want "SNAP1 mounts" 'guest snap mount vdb@SNAP1 0$'
	want "the walk repeated while the unmount waited" 'guest snap walk repeated under the unmount$'
fi
want "rmmod returned 0" 'guest rmmod 0$'
echo "pfs-create-race: $nc check(s), $nf failed"
# A failure above is read from userland and stands whether or not the
# ring survived; the warning count below is the ring's and needs it.
[ $nf = 0 ] || exit 1
grep -q 'ring whole' "$T" && ! grep -q 'ring COULD-NOT-READ' "$T" || {
	echo "pfs-create-race: COULD-NOT-READ: the guest's kernel ring lost its start marker" >&2; exit 2; }
want "no warning, BUG, KASAN, lockdep or cut-here line in the log" 'guest log: warn 0 bug 0 kasan 0 circular 0 cut 0$'
[ $nf = 0 ] || exit 1
exit 0
