#!/bin/sh
# WHAT A FULL VOLUME DOES, WHICH NOTHING HERE HAD EVER ASKED.
#
# Every write measurement in this tree was taken on a volume with room
# in it. This one fills a volume until the first write fails, then calls
# sync(2), and reads lockdep on both sides of each step.
#
# Its first run, 2026-09-05, found a circular lock dependency: lockdep
# stayed enabled through 583 files and 2 GiB of writing and disabled
# itself during the sync that followed, after which the unmount hung and
# the module could not be removed. The report names two orders,
#
#   hammer2_write_end -> hammer2_inode_chain_sync   holds h2ip, takes h2ch_inode
#   hammer2_vfs_sync_pmp                            holds h2ch_inode, takes h2ip
#
# and hammer2_vfs_sync_pmp() locks no chain at any of its three inode-lock
# sites, so the chain lock it is holding was taken by something that did
# not release it on this thread. XOPs run synchronously here, so an XOP
# body that returns with a chain still locked leaves it on the caller.
# doc/README.status.md carries the report and what is known about it.
#
# THE FAILURE IS THE POINT OF THIS SCRIPT. It exits non-zero while the
# defect stands, which is what a known defect's reproducer should do.
#
# EXIT 2 IS COULD-NOT-RUN AND IS NEVER A PASS, as in test-fixtures.sh.
set -u
cd "$(dirname "$0")/.." || exit 2

FIXDIR=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}
IMG=$FIXDIR/enospc.img
SIZE=${H2_ENOSPC_SIZE:-2G}
LABEL=ENOSPC
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2")}

[ -x "$NEWFS" ] || { echo "enospc: COULD-NOT-RUN: no newfs_hammer2 at $NEWFS" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "enospc: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
command -v ssh >/dev/null 2>&1 || { echo "enospc: COULD-NOT-RUN: no ssh" >&2; exit 2; }

make KDIR="$KDIR" >/dev/null 2>&1 || {
	echo "enospc: FAIL: the module does not build against $KDIR"; exit 1; }
KO=src/sys/fs/hammer2/hammer2.ko
[ -f "$KO" ] || { echo "enospc: FAIL: $KO was not produced"; exit 1; }

rm -f "$IMG"
truncate -s "$SIZE" "$IMG" || exit 2
"$NEWFS" -L "$LABEL" "$IMG" >/dev/null 2>&1 || {
	echo "enospc: COULD-NOT-RUN: newfs_hammer2 failed" >&2; exit 2; }

started=no
if ! $VIRSH domstate "$GUEST" 2>/dev/null | grep -q running; then
	$VIRSH start "$GUEST" >/dev/null 2>&1 || {
		echo "enospc: COULD-NOT-RUN: $GUEST would not start" >&2; exit 2; }
	started=yes
fi
i=0
while [ "$i" -lt 60 ]; do
	ssh -o ConnectTimeout=4 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null && break
	i=$((i + 1))
done
[ "$i" -lt 60 ] || { echo "enospc: COULD-NOT-RUN: $GUEST did not answer ssh" >&2; exit 2; }

guest_rel=$(ssh "$GUEST_SSH" 'uname -r' 2>/dev/null)
ko_rel=$(modinfo -F vermagic "$KO" 2>/dev/null | awk '{print $1}')
if [ "$guest_rel" != "$ko_rel" ]; then
	echo "enospc: COULD-NOT-RUN: the module is for $ko_rel and $GUEST runs $guest_rel" >&2
	exit 2
fi

$VIRSH attach-disk "$GUEST" "$IMG" vdb --targetbus virtio >/dev/null 2>&1 || {
	echo "enospc: COULD-NOT-RUN: could not attach $IMG" >&2; exit 2; }
scp -q -o ConnectTimeout=5 "$KO" "$GUEST_SSH:/tmp/h2.ko" >/dev/null 2>&1

# The unmount is given a bound, because the defect this script exists for
# hangs it: without one the ssh never returns and the run reads as a
# machine that went away rather than as the failure it is.
out=$(ssh "$GUEST_SSH" '
	rmmod hammer2 2>/dev/null
	insmod /tmp/h2.ko || { echo "SETUP insmod failed"; exit 0; }
	mkdir -p /mnt/h2enospc
	mount -t hammer2 /dev/vdb@ENOSPC /mnt/h2enospc ||
	    { echo "SETUP mount failed"; exit 0; }
	echo "locks after mount $(sed -n "s/^ *debug_locks: *//p" /proc/lockdep_stats)"
	i=0
	while [ $i -lt 8000 ]; do
		dd if=/dev/urandom of=/mnt/h2enospc/fill.$i bs=1M count=4 \
		    status=none 2>/dev/null || break
		i=$((i + 1))
	done
	echo "files written $i"
	echo "locks after fill $(sed -n "s/^ *debug_locks: *//p" /proc/lockdep_stats)"
	dmesg -C
	sync
	echo "locks after sync $(sed -n "s/^ *debug_locks: *//p" /proc/lockdep_stats)"
	dmesg | grep -c "DEADLOCK\|circular" | sed "s/^/cycles /"
	timeout 60 umount /mnt/h2enospc; echo "umount $?"
	timeout 30 rmmod hammer2; echo "rmmod $?"
' 2>&1)
printf '%s\n' "$out" | sed 's/^/  /'
$VIRSH detach-disk "$GUEST" vdb >/dev/null 2>&1
[ "$started" = yes ] && $VIRSH shutdown "$GUEST" >/dev/null 2>&1

# A guest left wedged by a previous run of this very script cannot load
# the module, and that is COULD-NOT-RUN rather than five failures
# describing a filesystem that was never mounted. The defect this script
# reproduces hangs the unmount, so the wedged guest is the expected state
# after a failing run and has to be told apart from the defect itself.
if printf '%s\n' "$out" | command grep -q '^SETUP '; then
	printf '%s\n' "$out" | sed -n 's/^SETUP /enospc: COULD-NOT-RUN: /p' >&2
	echo "          $GUEST may still hold the module from an earlier run;" >&2
	echo "          it needs a hard reset, since the defect hangs the unmount" >&2
	exit 2
fi

fail=0
n=$(printf '%s\n' "$out" | sed -n 's/^files written //p')
[ -n "$n" ] && [ "$n" -gt 0 ] 2>/dev/null || {
	echo "  FAIL  nothing was written, so the volume never filled"; fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q '^locks after fill 1$' ||
	{ echo "  FAIL  lockdep was already off after the fill"; fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q '^locks after sync 1$' ||
	{ echo "  FAIL  lockdep disabled itself during the sync on a full volume"
	  fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q '^umount 0$' ||
	{ echo "  FAIL  the unmount did not finish"; fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q '^rmmod 0$' ||
	{ echo "  FAIL  the module could not be removed"; fail=$((fail + 1)); }

make -s clean >/dev/null 2>&1
echo "enospc: filled $SIZE, $fail failure(s)"
[ "$fail" -eq 0 ]
