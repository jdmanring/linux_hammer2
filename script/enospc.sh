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
# and the sync task's backtrace holds nothing of this module between
# ksys_sync and the lock, so the chain lock was acquired in a call that
# has already returned. Two explanations were tested and both were wrong:
# every XOP the sync path drives is balanced, and a scratch build proved
# hammer2_chain_unhold() does not leave the mutex held. The report is read
# by streaming /dev/kmsg for the whole run, because the ring wraps before
# a fill ends, and it is printed before the unmount, because the unmount
# hangs on most of these runs. doc/README.status.md carries all of it.
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

# H2_LOCKDEBUG=1 builds the module with hammer2_dbg_held_chains() live and
# summarizes what it printed. It exists so a run can ask which chain locks
# the sync task holds without a hand-edited copy of this script, which is
# how the question was asked five times while chasing this defect and how
# one of those runs ended up executing in the wrong directory.
lockdebug=${H2_LOCKDEBUG:-0}
if [ "$lockdebug" = 1 ]; then
	make -s clean >/dev/null 2>&1
	HAMMER2_LOCKDEBUG=1 make KDIR="$KDIR" >/dev/null 2>&1 || {
		echo "enospc: FAIL: no build with HAMMER2_LOCKDEBUG"; exit 1; }
else
	make KDIR="$KDIR" >/dev/null 2>&1 || {
		echo "enospc: FAIL: the module does not build against $KDIR"; exit 1; }
fi
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
# A guest that is booting refuses the connection rather than dropping it,
# and a refusal returns at once, so a bare retry loop spends its whole
# budget in about a second and reports a machine that never answered. The
# wait has to be in the loop, not in the connect timeout.
i=0
while [ "$i" -lt 60 ]; do
	ssh -o ConnectTimeout=4 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null && break
	sleep 5
	i=$((i + 1))
done
[ "$i" -lt 60 ] || { echo "enospc: COULD-NOT-RUN: $GUEST did not answer ssh in 5 minutes" >&2; exit 2; }

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
	# The ring wraps before a fill run ends, so the report is streamed
	# out of /dev/kmsg from before the module is loaded rather than read
	# back with dmesg afterwards. Everything derived from it is printed
	# BEFORE the unmount, because the unmount hangs on the majority of
	# these runs and takes the evidence with it when it does.
	: > /tmp/kmsg.log
	cat /dev/kmsg > /tmp/kmsg.log 2>/dev/null &
	kpid=$!
	insmod /tmp/h2.ko || { echo "SETUP insmod failed"; exit 0; }
	mkdir -p /mnt/h2enospc
	mount -t hammer2 /dev/vdb@ENOSPC /mnt/h2enospc ||
	    { echo "SETUP mount failed"; exit 0; }
	echo "locks after mount $(sed -n "s/^ *debug_locks: *//p" /proc/lockdep_stats)"
	# THE POPULATION THIS SCRIPT CLAIMS IS "THE VOLUME FILLED", and a
	# bare break on a failed dd cannot tell ENOSPC from a wedged mount,
	# a read-only remount or an I/O error. Every check below would then
	# describe a volume that never filled. Keep the reason dd gave and
	# read the free space afterwards, and let the host assert both.
	i=0
	why=
	while [ $i -lt 8000 ]; do
		why=$(dd if=/dev/urandom of=/mnt/h2enospc/fill.$i bs=1M \
		    count=4 status=none 2>&1) || break
		i=$((i + 1))
	done
	echo "files written $i"
	echo "fill stopped because ${why:-no error reported}"
	echo "blocks available $(stat -f -c %a /mnt/h2enospc)"
	echo "locks after fill $(sed -n "s/^ *debug_locks: *//p" /proc/lockdep_stats)"
	sync
	echo "locks after sync $(sed -n "s/^ *debug_locks: *//p" /proc/lockdep_stats)"
	kill $kpid 2>/dev/null

	# A count of REPORTS, one banner line each. Counting every line that
	# says DEADLOCK or circular counts a single report three times over,
	# which is how one report came to be recorded as three.
	echo "cycles $(command grep -c "possible circular locking dependency" /tmp/kmsg.log)"

	# lockdep disables itself for several reasons and only one of them is
	# a cycle: an unlock imbalance, a held lock freed, and the three
	# resource ceilings (MAX_LOCKDEP_KEYS, MAX_LOCKDEP_CHAINS,
	# MAX_LOCK_DEPTH) all read as debug_locks 0 at the same site. The
	# reason is what tells them apart, so it is reported rather than
	# assumed.
	echo "shutdown-reason $(command grep -m1 -o "BUG: MAX_[A-Z_]* too low!\|possible circular locking dependency\|WARNING: bad unlock balance\|BUG: held lock freed" /tmp/kmsg.log || echo none-found)"

	# The instrument prints through hprintf, so its lines carry the
	# module name; summarize them by site rather than repeating each.
	if command grep -q "sync_pmp entry" /tmp/kmsg.log; then
		echo "lockdebug lines $(command grep -c "sync_pmp entry" /tmp/kmsg.log)"
		command grep -o "sync_pmp entry: chain type [0-9]* key [0-9a-f]* .*" \
		    /tmp/kmsg.log | sort | uniq -c | sort -rn | head -4
	else
		echo "lockdebug lines 0"
	fi

	echo "=== first report begins"
	command sed -n "/possible circular locking dependency/,+220p" /tmp/kmsg.log |
	    command sed "s/^[0-9,;]*;//"
	echo "=== first report ends"

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
# The volume must actually be full. Without this a run that stopped
# writing for any other reason reads exactly like the one this script
# exists to produce.
printf '%s\n' "$out" | command grep -qi 'fill stopped because.*no space left' ||
	{ echo "  FAIL  the fill did not stop on ENOSPC:"
	  printf '%s\n' "$out" | sed -n 's/^fill stopped because /        /p'
	  fail=$((fail + 1)); }
printf '%s\n' "$out" | command grep -q '^blocks available 0$' ||
	{ echo "  FAIL  the volume reports free space, so it never filled"
	  fail=$((fail + 1)); }

# lockdep has to be alive going into the sync or its silence afterwards
# would mean nothing. This is the control for the instrument, not a
# property of the driver.
printf '%s\n' "$out" | grep -q '^locks after fill 1$' ||
	{ echo "  FAIL  lockdep was already off after the fill"; fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q '^locks after sync 1$' ||
	{ echo "  FAIL  lockdep disabled itself during the sync on a full volume"
	  fail=$((fail + 1)); }
# debug_locks reads 0 for a cycle and for four other faults alike, so a
# shutdown this script cannot attribute is not evidence of the cycle it
# was written for. Nothing is counted against the defect until the banner
# names it.
if printf '%s\n' "$out" | command grep -q '^locks after sync 0$' &&
   printf '%s\n' "$out" | command grep -q '^shutdown-reason none-found$'; then
	echo "enospc: COULD-NOT-RUN: lockdep shut down during the sync and the" >&2
	echo "          reason was not in the captured log, so the cycle is" >&2
	echo "          neither confirmed nor ruled out for this run" >&2
	exit 2
fi

printf '%s\n' "$out" | grep -q '^umount 0$' ||
	{ echo "  FAIL  the unmount did not finish"; fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q '^rmmod 0$' ||
	{ echo "  FAIL  the module could not be removed"; fail=$((fail + 1)); }

make -s clean >/dev/null 2>&1
echo "enospc: filled $SIZE, $fail failure(s)"
[ "$fail" -eq 0 ]
