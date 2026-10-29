#!/bin/sh
# Reproduce the flush that finds an empty base, from the call trace that
# carries it rather than from the path it was first attributed to.
#
# The fault's trace at 732.727 in
# doc/history/kernel-reports/hammer2-sync-work-empty-base-20261012.txt runs
# hammer2_base_delete up through hammer2_flush_recurse,
# hammer2_xop_inode_flush and hammer2_vfs_sync_pmp to hammer2_sync_fs,
# sync_filesystem and hammer2_sync_work, and the line above it names the
# workqueue. So the producer is this port's own syncer, a delayed work that
# reschedules itself every HAMMER2_SYNC_INTERVAL (30 s) and flushes from a
# workqueue thread, and the teardown's hammer2_pfsfree_scan is not in the
# log at all.
#
# What that trace implies for a reproduction is the shape below, and it is
# the one thing the earlier reproductions did not do: the flush has an
# sb-backed pmp, so the MOUNT WHOSE SYNCER FAULTS MUST STAY MOUNTED. A
# cluster PFS is sb-backed only on the volume holding its MASTER, so the
# master mount is left up for the whole run and it is the SLAVE's volume
# that is unmounted and remounted underneath it.
#
# cluster-sync.sh's phase 4 already has that topology: /mnt/h2c is a master
# cluster mount held across the unmount of /mnt/h2s. What this adds is the
# WINDOW, and the window is the whole reason the earlier attempts read
# clean. That phase unmounts the slave once and remounts it within the same
# second, and dbg6 read 0 modified chains at every one of its unmounts; the
# failing log's flush arrives 22 s AFTER an unmount, inside a 30 s
# HAMMER2_SYNC_INTERVAL period, on a master mount that was still up. So the
# cycles here wait past one full syncer period with the slave still
# unmounted, rather than remounting at once.
#
# The readings are ordered so a run that reproduces nothing is
# distinguishable from a run that never reached the state:
#
#   - `unmount left` is what hammer2_kill_sb prints unconditionally after
#     every unmount, so a zero there means the unmount that is supposed to
#     leave chains did not, and nothing below it tested anything.
#   - `empty base` is the fault. A run with zero of these and a non-zero
#     `unmount left` is a reproducer that did not reproduce; a run with
#     zero of both never reached the state.
#   - the pass count and the `defer` count say the thread was running the
#     whole time, which is what makes the window the whole run rather than
#     a moment.
#
# A fake pass to guard against: a guest whose module was never loaded reads
# zero of everything. The insmod and the mount are each asserted before any
# reading is taken.
#
# Exit 2 without the guest, the tools or a kernel tree.
set -u
FIXDIR=${H2_FIXTURE_DIR:-$HOME/Projects/linux_hammer2-data/fixtures}
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH=${H2_VIRSH:-virsh --connect qemu:///system}
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2")}
# The convergence reading, taken off the media by the two tools
# cluster-sync.sh already uses for the same purpose, rather than invented
# here: fsck_hammer2 for each volume's health and the cluster PFS
# fingerprint from `hammer2 -v show` for entry-for-entry agreement. This
# script's guest-side checks are all fault detection -- empty base, gave
# up, device in error -- and none of them asks whether the slave ended up
# holding what the master holds, so a run that converges and a run that
# silently drops the copy both read the same without this.
HAMMER2=${H2_HAMMER2:-$(command -v hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/hammer2")}
FSCK=${H2_FSCK:-$(command -v fsck_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2")}
# The bound scales on a KASAN tree, as cluster-sync.sh's does, so a slower
# kernel is not read as a hang.
RUNSECS=900; grep -qx 'CONFIG_KASAN=y' "$KDIR/.config" 2>/dev/null && RUNSECS=$((RUNSECS * 4))
RUN="timeout ${H2_RUN_TIMEOUT:-$RUNSECS} ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
# The set written to the master. Big enough that the slave's copy leaves
# chains behind, small enough to write in seconds.
N=${H2_N:-4000}
# How many slave unmount/remount cycles to run. The fault in the log
# arrived 22 s after an unmount, inside one 30 s syncer period, so one
# cycle can reach it; more cycles widen the window cheaply.
CYCLES=${H2_CYCLES:-4}
# The debug bit the checks below depend on: `syncthr: update inode` and
# `sync_slaves pfs CL` are both gated on 0x8000, so it stays on. What made
# the run's console flood was a print in the sync path that was NOT gated;
# that one is gated in the driver now, which is where the 102,370 lines and
# the five soft lockups on ttyS0 came from.
H2DEBUG=${H2_DEBUG:-0x8000}
MASTER=$FIXDIR/repro-master.img
SLAVE=$FIXDIR/repro-slave.img
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

command -v virsh >/dev/null 2>&1 || { echo "sync-empty: COULD-NOT-RUN: no virsh" >&2; exit 2; }
[ -x "$NEWFS" ] || { echo "sync-empty: COULD-NOT-RUN: no newfs_hammer2 (H2_NEWFS)" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "sync-empty: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -d "$KDIR" ] || { echo "sync-empty: COULD-NOT-RUN: no kernel tree at $KDIR" >&2; exit 2; }
state=$($VIRSH domstate "$GUEST" 2>/dev/null) || {
	echo "sync-empty: COULD-NOT-RUN: no guest $GUEST" >&2; exit 2; }
names=$($VIRSH list --name 2>/dev/null) || {
	echo "sync-empty: COULD-NOT-RUN: virsh list failed" >&2; exit 2; }
other=$(printf '%s\n' "$names" | grep -v -x -e "$GUEST" -e '' | grep -c . || true)
if [ "$other" -gt 0 ] && [ "${H2_FIXTURE_SHARE:-0}" != 1 ]; then
	echo "sync-empty: COULD-NOT-RUN: $other other guest(s) running" >&2
	exit 2
fi

# The build knobs are forwarded rather than fixed, because the reading the
# run exists to take needs one of them: the collision this reproduces is
# caught only by the carried KASSERTMSG, and every build this tree ships
# compiles that out.  A run without HAMMER2_INVARIANTS reaches the fault
# and silently shows nothing, which is the state four earlier runs were
# read in.  The `make -s clean` below wipes any module built by hand, so a
# script that does not forward the knob rebuilds a default one and the
# instrumented reading is lost with no error anywhere.
MAKEOPTS=
[ "${HAMMER2_INVARIANTS:-0}" = 1 ] && MAKEOPTS="$MAKEOPTS HAMMER2_INVARIANTS=1"
[ "${HAMMER2_LOCKDEBUG:-0}" = 1 ] && MAKEOPTS="$MAKEOPTS HAMMER2_LOCKDEBUG=1"
make -s clean >/dev/null 2>&1
make -s KDIR="$KDIR" $MAKEOPTS >/dev/null 2>&1 || {
	echo "sync-empty: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko
[ -f "$KO" ] || { echo "sync-empty: COULD-NOT-RUN: no $KO" >&2; exit 2; }
# The knob is only a claim about the build unless the build is read back,
# and the two builds differ from one source in a way no timestamp shows.
# debug_hprintf is the knob's own signature rather than any one probe's:
# it is hprintf under HAMMER2_INVARIANTS and a discarded do-nothing
# otherwise, so its format strings are in the module exactly when the
# knob took.  Read from hammer2_flush.c, which is carried and not the
# file a running experiment edits, so the check cannot be satisfied or
# broken by adding a print somewhere.
if [ "${HAMMER2_INVARIANTS:-0}" = 1 ]; then
	strings -a "$KO" | command grep -q 'flush %s chain %016llx' || {
		echo "sync-empty: COULD-NOT-RUN: module carries no" >&2
		echo "  debug_hprintf string, so HAMMER2_INVARIANTS did not take" >&2
		exit 2; }
fi

# The guest must be clean BEFORE anything is detached, and the check has to
# be here rather than in the guest half below, which runs after this.  A
# detach-disk of a volume that is still mounted enters the guest as an ACPI
# hotplug and reaches blk_report_disk_dead -> sync_filesystem ->
# hammer2_vfs_sync_pmp -> hammer2_trans_init, where it blocks behind the
# mount's own flush; measured 2026-10-12, a sync left 36 minutes in
# hammer2_trans_init with the module loaded and three volumes mounted from
# the run before.  Detaching first and asking afterwards is what put the
# guest in that state, so the order is inverted and a dirty guest is
# COULD-NOT-RUN with the reason, not a detach that wedges it.
if [ "$state" = running ]; then
	# The status belongs to ssh, and it must be read from ssh alone. The
	# remote command ends in `grep -c`, which PRINTS 0 and EXITS 1 when it
	# matches nothing, so `cmd || echo ssh-failed` fires on a perfectly
	# healthy guest: the first version of this guard refused a clean guest
	# reading "0 0 ssh-failed".  A marker the remote command prints only on
	# success separates the two, and the counts are captured with their
	# status discarded, which is the same shape every other count in this
	# file uses.
	dirty=$($RUN "$GUEST_SSH" 'lsmod 2>/dev/null | grep -c "^hammer2" || true
		mount 2>/dev/null | grep -c " type hammer2" || true
		echo ssh-alive' 2>/dev/null) || dirty=""
	case "$dirty" in
	*ssh-alive)
		dirty=$(printf '%s\n' "$dirty" | sed '/^ssh-alive$/d' | tr '\n' ' ') ;;
	*)
		echo "sync-empty: COULD-NOT-RUN: the guest did not answer ssh, so" >&2
		echo "  whether it is clean cannot be established before the detach" >&2
		exit 2 ;;
	esac
	case "$dirty" in
	"0 0 "|"0 0") ;;
	*)
		echo "sync-empty: COULD-NOT-RUN: the guest still holds a module or a" >&2
		echo "  mounted volume ($dirty), and" >&2
		echo "  detaching a mounted volume deadlocks the guest in the port's" >&2
		echo "  own sync path. Unload and unmount it first (a hard cycle is" >&2
		echo "  the documented recovery for this guest)." >&2
		exit 2 ;;
	esac
fi

for d in vdb vdc; do
	# Bounded, so a wedged eject is a reported failure rather than a hang
	# of the host side. --config removes the definition so the next start
	# does not re-attach it; --live is what reaches the guest.
	timeout 60 $VIRSH detach-disk "$GUEST" $d --live >/dev/null 2>&1
	timeout 60 $VIRSH detach-disk "$GUEST" $d --config >/dev/null 2>&1
done
rm -f "$MASTER" "$SLAVE"
for img in "$MASTER" "$SLAVE"; do
	truncate -s 2G "$img" && "$NEWFS" -L ROOT "$img" >/dev/null 2>&1 || {
		echo "sync-empty: COULD-NOT-RUN: newfs_hammer2 failed on $img" >&2; exit 2; }
done
if [ "$state" = running ]; then how=--live; else how=--config; fi
err=$($VIRSH attach-disk "$GUEST" "$MASTER" vdb --targetbus virtio $how 2>&1) &&
err=$($VIRSH attach-disk "$GUEST" "$SLAVE" vdc --targetbus virtio $how 2>&1) || {
	echo "sync-empty: COULD-NOT-RUN: could not attach the volumes: $err" >&2; exit 2; }
if [ "$state" != running ]; then
	$VIRSH start "$GUEST" >/dev/null 2>&1 || { echo "sync-empty: COULD-NOT-RUN: $GUEST did not start" >&2; exit 2; }
fi
n=0
until ssh -o ConnectTimeout=3 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null; do
	sleep 5; n=$((n + 1))
	[ $n -gt 60 ] && { echo "sync-empty: COULD-NOT-RUN: $GUEST did not answer ssh in 5 minutes" >&2; exit 2; }
done
# One lockdep report turns lockdep off until the next boot, and a run
# on that boot reads "no report" with nothing checking.
dl=$(ssh -o BatchMode=yes "$GUEST_SSH" "awk '/debug_locks:/ {print \$2}' /proc/lockdep_stats 2>/dev/null")
[ "$dl" = 0 ] && {
	echo "sync-empty: COULD-NOT-RUN: lockdep is off on $GUEST since an earlier report; boot it again" >&2; exit 2; }

cat > "$W/guest.sh" <<'GUEST'
set -u
if lsmod 2>/dev/null | grep -q '^hammer2'; then
	echo "sync-empty: COULD-NOT-RUN: the guest still has the module loaded" >&2
	exit 2
fi
if mount 2>/dev/null | grep -q ' type hammer2'; then
	echo "sync-empty: COULD-NOT-RUN: the guest still has a volume mounted" >&2
	exit 2
fi
rmmod hammer2 2>/dev/null; dmesg -C
# The ring wraps, so the log is streamed to a file and every count reads it.
K=/tmp/h2empty.klog
dmesg -w > $K 2>&1 &
KPID=$!
klog() { grep -c "$1" $K; }
echo "mounts-before $(( $(mount 2>/dev/null | grep -c ' type hammer2') ))"

insmod /tmp/hammer2.ko debug=$H2DEBUG || { echo "insmod-failed"; exit 1; }
echo "module-loaded $(lsmod | grep -c '^hammer2')"
mkdir -p /mnt/m /mnt/s /mnt/c

# Which image /dev/vdb and /dev/vdc actually resolve to, read in the guest
# before anything is mounted. The harness attaches MASTER to vdb and SLAVE
# to vdc, and on 2026-10-13 the images afterwards showed the CL element of
# repro-master.img as pfs_type 3 (SLAVE) and of repro-slave.img as 6
# (MASTER), the reverse of the attach order. Whether that came from the
# guest's own device ordering or from the images being written back to the
# wrong files is the one fact every directional reading rests on, and no run
# had ever read it here. Both are named by serial-less virtio disks whose
# order is the guest's, so the device is identified by the SIZE and by a
# marker written and read back through the block device itself, not by its
# name alone.
echo "vdb-bytes $(blockdev --getsize64 /dev/vdb 2>/dev/null || echo none)"
echo "vdc-bytes $(blockdev --getsize64 /dev/vdc 2>/dev/null || echo none)"

# The master mount is the one whose syncer faults, so it is created first
# and never unmounted until the run is over.
timeout 30 mount -t hammer2 /dev/vdb@ROOT /mnt/m || { echo "master-root-mount-failed"; exit 1; }
hammer2 -s /mnt/m pfs-create CL >/dev/null 2>&1 || { echo "master-pfs-create-failed"; exit 1; }
clid=$(hammer2 -s /mnt/m pfs-list | awk '$3=="CL"{print $2}')
[ -n "$clid" ] || { echo "no-cluster-id"; exit 1; }
# The super-root's own fsid, read off the raw block device the master was
# mounted from. Every image carries a distinct one, so the same field read
# from the image at rest afterwards names which FILE /dev/vdb is, which is
# the one fact the master/slave naming of every reading below depends on.
echo "vdb-superroot-fsid $(hammer2 -v show /dev/vdb 2>/dev/null | awk '/pfs_fsid/{print $2; exit}')"
timeout 30 mount -t hammer2 /dev/vdb@CL /mnt/c || { echo "master-cluster-mount-failed"; exit 1; }
echo "master-mounted $(( $(mount 2>/dev/null | grep -c ' type hammer2') ))"
mkdir -p /mnt/c/set
i=0; while [ $i -lt $N ]; do head -c 4096 /dev/urandom > /mnt/c/set/f$i; i=$((i + 1)); done
sync
echo "set-written $(find /mnt/c/set -type f | wc -l)"

# The slave volume: a SLAVE element joined to the same cluster, on ROOT, so
# the volume can be unmounted and remounted under the live master mount.
timeout 30 mount -t hammer2 /dev/vdc@ROOT /mnt/s || { echo "slave-root-mount-failed"; exit 1; }
hammer2 -s /mnt/s -t SLAVE -u "$clid" pfs-create CL >/dev/null 2>&1 || { echo "slave-pfs-create-failed"; exit 1; }
echo "threads $(ps -eo comm | grep -c '^h2nod-CL')"

# Let the thread carry the set to the slave element once, so the slave's
# topology holds the chains the later flush recurses into.
sleep 40
echo "copied $(klog 'syncthr: update inode')"
echo "passes-before $(( $(klog 'sync_slaves pfs CL') ))"

# The cycles: unmount the slave's ROOT (whose teardown is what leaves the
# master's element marked) and remount it, with the master mount left up so
# its syncer keeps flushing the cluster across the whole window.
c=0
while [ $c -lt $CYCLES ]; do
	i=0; while [ $i -lt 200 ]; do head -c 4096 /dev/urandom > /mnt/c/set/g$c-$i; i=$((i + 1)); done
	sync
	timeout 60 umount /mnt/s; urc=$?
	echo "cycle-$c-umount-rc $urc"
	# The unbounded form: whatever kill_sb printed for this unmount, taken
	# from the log rather than from the guest's stdout. grep -c prints its
	# count and exits 1 on no match, so the count is kept and the status
	# discarded on every read below.
	echo "cycle-$c-unmount-left $(grep 'after unmount' $K | tail -1 | sed 's/.*after unmount: //')"
	echo "cycle-$c-empty-base $(klog 'from empty base')"
	[ "$(klog 'from empty base')" -gt 0 ] && break
	# The syncer's period is 30 s; wait past one so the master's sync_work
	# runs at least once against the just-left state before remounting.
	sleep 40
	echo "cycle-$c-after-wait $(klog 'from empty base')"
	[ "$(klog 'from empty base')" -gt 0 ] && break
	timeout 60 mount -t hammer2 /dev/vdc@ROOT /mnt/s; rrc=$?
	echo "cycle-$c-remount-rc $rrc"
	[ "$rrc" = 0 ] || { echo "remount-failed"; break; }
	sleep 20
	c=$((c + 1))
done

echo "empty-base $(klog 'from empty base')"
echo "passes-after $(( $(klog 'sync_slaves pfs CL') ))"
echo "pass-errors $(klog 'hammer2_sync_slaves: error')"
echo "defer-nonzero $(grep -c 'defer [1-9a-f]' $K)"
echo "device-in-error $(klog 'device in error')"
echo "gave-up $(klog 'gave up')"
echo "kernel-warnings $(grep -c -E 'WARNING|BUG:|UBSAN:' $K)"
# Leave the guest clean whatever happened.
timeout 60 umount /mnt/c 2>/dev/null
timeout 60 umount /mnt/s 2>/dev/null
timeout 60 umount /mnt/m 2>/dev/null
echo "mounts-after $(( $(mount 2>/dev/null | grep -c ' type hammer2') ))"
timeout 120 rmmod hammer2 && echo "rmmod ok"
sync
kill $KPID 2>/dev/null
GUEST

scp -q "$KO" "$W/guest.sh" "$GUEST_SSH:/tmp/" || { echo "sync-empty: COULD-NOT-RUN: copy to $GUEST failed" >&2; exit 2; }
$RUN "$GUEST_SSH" "N=$N CYCLES=$CYCLES H2DEBUG=$H2DEBUG sh -c 'mv /tmp/guest.sh /tmp/h2empty.sh; . /tmp/h2empty.sh'" > "$W/out" 2>&1
rc=$?
# A guest half that REFUSED is not a run that failed, and reporting it as
# thirteen failures is the probe failing at its own job: on 2026-10-12 a run
# whose guest still held the module (left loaded by an earlier run killed
# mid-build) printed "the module is loaded: none" and twelve more, and a
# reader scanning for FAIL lines cannot tell that from the subject failing.
# The guest half exits 2 and says why on stderr; that is surfaced verbatim
# and the script reports COULD-NOT-RUN.
if [ "$rc" = 2 ] || command grep -q "COULD-NOT-RUN" "$W/out" 2>/dev/null; then
	command grep -m1 "COULD-NOT-RUN" "$W/out" 2>/dev/null >&2 ||
		echo "sync-empty: COULD-NOT-RUN: the guest half exited 2 without a reason" >&2
	for d in vdb vdc; do
		$VIRSH detach-disk "$GUEST" $d --live >/dev/null 2>&1
		$VIRSH detach-disk "$GUEST" $d --config >/dev/null 2>&1
	done
	exit 2
fi
if [ "$rc" = 124 ]; then
	scp -q "$GUEST_SSH:/tmp/h2empty.klog" "$FIXDIR/sync-empty-hang-$(date +%Y%m%d-%H%M%S).klog" 2>/dev/null
	for d in vdb vdc; do
		$VIRSH detach-disk "$GUEST" $d --live >/dev/null 2>&1
		$VIRSH detach-disk "$GUEST" $d --config >/dev/null 2>&1
	done
	echo "  FAIL  the guest run hung past ${H2_RUN_TIMEOUT:-$RUNSECS}s; its kernel log is kept beside the images"
	exit 1
fi
# A non-zero that is neither 2 nor 124 is the guest half or its session
# ending without finishing -- an ssh drop returns 255, and 127 has been seen.
# It is COULD-NOT-RUN, not a run whose readings may be checked, and it must
# not fall through to the detach below: that detach of a volume the guest is
# still using is the ACPI hotplug the pre-flight guard at the top of this
# script refuses, and it wedges the guest in the port's own sync path. The
# guest's output and kernel log are kept, since they say how far the run
# reached. cluster-sync.sh and cluster-quorum.sh carry the same guard.
if [ "$rc" != 0 ]; then
	scp -q "$GUEST_SSH:/tmp/h2empty.klog" "$FIXDIR/sync-empty-drop-$(date +%Y%m%d-%H%M%S).klog" 2>/dev/null
	cp "$W/out" "$FIXDIR/sync-empty-drop-$(date +%Y%m%d-%H%M%S).out" 2>/dev/null
	for d in vdb vdc; do
		$VIRSH detach-disk "$GUEST" $d --live >/dev/null 2>&1
		$VIRSH detach-disk "$GUEST" $d --config >/dev/null 2>&1
	done
	echo "sync-empty: COULD-NOT-RUN: the guest session ended rc=$rc without finishing the run; its output and kernel log are kept beside the images as sync-empty-drop-*" >&2
	exit 2
fi
scp -q "$GUEST_SSH:/tmp/h2empty.klog" "$W/klog" 2>/dev/null
for d in vdb vdc; do
	$VIRSH detach-disk "$GUEST" $d --live >/dev/null 2>&1
	$VIRSH detach-disk "$GUEST" $d --config >/dev/null 2>&1
done

val() { sed -n "s/^$1 //p" "$W/out" | head -1; }
fail=0; checks=0
check() {
	checks=$((checks + 1))
	if [ "$2" = 0 ]; then echo "  ok    $1: $3"; else echo "  FAIL  $1: $3"; fail=$((fail + 1)); fi
}
m=$(val module-loaded); [ "${m:-0}" = 1 ]; check "the module is loaded" $? "${m:-none}"
# The devices the guest actually got, before any directional reading below
# is taken. Both images are 2 GiB so size cannot separate them; the super-root
# fsid the guest read off the raw device is compared against the same field
# on each image at rest, and THAT is what names which file /dev/vdb is. A run
# where the two do not match has every master/slave reading reversed.
vb=$(val vdb-bytes); vc=$(val vdc-bytes)
echo "  note  /dev/vdb=$vb /dev/vdc=$vc byte(s)"
gfsid=$(val vdb-superroot-fsid)
ifsid=$("$HAMMER2" -v show "$MASTER" 2>/dev/null | awk '/pfs_fsid/{print $2; exit}')
if [ -n "$gfsid" ] && [ -n "$ifsid" ]; then
	[ "$gfsid" = "$ifsid" ]
	check "MASTER=repro-master.img is the volume the guest mounted as vdb" $? \
		"guest $gfsid, image $ifsid"
else
	echo "  FAIL  the device-to-image tie was not read: guest '${gfsid:-none}' image '${ifsid:-none}'"
	fail=$((fail + 1))
fi
m=$(val master-mounted); [ "${m:-0}" -ge 2 ] 2>/dev/null; check "the master's ROOT and cluster mounts are both up" $? "${m:-none} mounted"
s=$(val set-written); [ "${s:-0}" = "$N" ]; check "the master holds the set" $? "${s:-none} file(s)"
t=$(val threads); [ "${t:-0}" -ge 1 ] 2>/dev/null; check "the cluster's thread is running" $? "${t:-none}"
cp=$(val copied); [ "${cp:-0}" -ge 1 ] 2>/dev/null; check "the thread copied the set to the slave element" $? "${cp:-none} inode update(s)"
# The three checks below read the ORIGINAL fault's signature: a flush that
# finds an empty base, a chain check that gives up, a device marked in
# error. They were written when the fault was live and a run that produced
# none of them had failed to reproduce it. Once the fault is FIXED those
# same three readings are the result wanted, and a script that still calls
# them failures cannot tell a fix from a broken probe: the run of
# 2026-10-13 reported "5 failed" for a tree that neither crashed nor hung.
# So which way each reading counts is stated rather than assumed, the same
# shape as test-enospc.sh's H2_ENOSPC_FILES control. H2_SYNC_EXPECT=fault
# runs the old judgement, for using this script to reproduce the fault in
# a tree that still has it.
H2_SYNC_EXPECT=${H2_SYNC_EXPECT:-fixed}
case "$H2_SYNC_EXPECT" in
fixed|fault) ;;
*) echo "sync-empty: COULD-NOT-RUN: H2_SYNC_EXPECT must be fixed or fault" >&2
   exit 2 ;;
esac
# want N: the reading is healthy when it is 0 under `fixed` and when it is
# at least 1 under `fault`. Passed the value and the label.
want() { # value label
	v=${1:-0}
	if [ "$H2_SYNC_EXPECT" = fault ]; then
		[ "$v" -ge 1 ] 2>/dev/null
	else
		[ "$v" = 0 ] 2>/dev/null
	fi
}
e=$(val empty-base)
want "$e" "a flush finds an empty base"; check "a flush finds an empty base" $? \
	"${e:-0} miss(es), expected $H2_SYNC_EXPECT"
r=$(val gave-up)
want "$r" "the chain check gives up"
check "the chain check gives up, as the original log does" $? \
	"${r:-0}, expected $H2_SYNC_EXPECT"
d=$(val device-in-error)
want "$d" "the device is marked in error"
check "the device is marked in error" $? "${d:-0}, expected $H2_SYNC_EXPECT"
# The window is the fourth reading of the same kind and was left out of the
# switch when the other three moved into it: this check required the window to
# OPEN, which is the fault condition. Once the sync completes cleanly no
# unmount leaves modified chains, so a converged run failed it. It is judged
# by H2_SYNC_EXPECT now, and the unmount-reading count is still printed so a
# run that never unmounted reads differently from one whose unmounts were clean.
left=$(grep -c 'after unmount' "$W/klog" 2>/dev/null || true)
nz=$(grep 'after unmount' "$W/klog" 2>/dev/null | grep -vc ', 0 modified' || true)
want "${nz:-0}" "an unmount left modified chains"
check "an unmount left modified chains" $? \
	"${left:-0} unmount reading(s), ${nz:-0} with modified chains, expected $H2_SYNC_EXPECT"
p=$(val pass-errors); [ "${p:-1}" = 0 ]; check "no pass reports an error" $? "${p:-none}"
k=$(val kernel-warnings); [ "${k:-1}" = 0 ]; check "no kernel warning, BUG or UBSAN report" $? "${k:-none}"
u=$(val mounts-after); [ "${u:-1}" = 0 ]; check "every mount is dropped" $? "${u:-none} left"
grep -q '^rmmod ok' "$W/out"; check "the module unloads" $? "$(grep -c '^rmmod ok' "$W/out") of 1"

# Convergence, off the media. The guest-side checks above all measure the
# fault; none of them asks whether the slave ended up holding what the
# master holds, which is what P4's synchronization step is for. The
# instrument is cluster-sync.sh's, unchanged: fsck_hammer2 for each
# volume's own health and the cluster PFS fingerprint from `hammer2 -v
# show` for entry-for-entry agreement, taken from the images after the run
# rather than from a mount, since a mounted volume answers from cache.
if [ -x "$FSCK" ] && [ -x "$HAMMER2" ]; then
	# Report each image by the role the media gives it, since the
	# filenames are what turned out to be wrong on 2026-10-13, so a line
	# naming "the master volume" was naming the wrong file.
	for b in master slave; do
		eval "img=\$$(echo "$b" | tr a-z A-Z)"
		"$FSCK" "$img" > "$W/fsck.$b" 2>&1
		check "fsck_hammer2 exits 0 on repro-$b.img" $? "exit $?"
	done
	last() { sed -n '$p' "$1"; }
	# The last running total fsck prints is the volume's own.
	fm=$(last "$W/fsck.master"); fs_=$(last "$W/fsck.slave")
	echo "  note  repro-master.img: $fm"
	echo "  note  repro-slave.img:  $fs_"
	# The fingerprint of the cluster's PFS, from the line naming it to the
	# line closing it, which is cluster-sync.sh's function copied whole so
	# the two scripts read side by side and agree on what convergence is.
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
	# Which image is the MASTER is a fact about the MEDIA, not about the
	# filename it happens to carry. 2026-10-13: repro-master.img held CL as
	# pfs_type 3 (SLAVE) and repro-slave.img held it as 6 (MASTER), so
	# every reading the two variables fed was inverted and the missing-tree
	# count was attributed to the volume that had it. pfs-create defaults
	# to MASTER with no uuid and to SLAVE with one, and only the vdc volume
	# is given -u, so the roles are readable from the invocation as well;
	# the media is the authority here and the roles decide which file is
	# compared to which, so a mislabelled pair cannot swap a verdict.
	role() {		# image -> MASTER | SLAVE | unknown
		t=$("$HAMMER2" -v show "$1" 2>/dev/null | awk '
		    /filename "CL"$/ && !on { on = 1; next }
		    on && /^ *} \(inode\.[0-9]*, "CL"\)/ { exit }
		    on && /^ *pfs_type / { print $2; exit }')
		case "$t" in
		6) echo MASTER ;;
		3) echo SLAVE ;;
		*) echo "unknown(type ${t:-none})" ;;
		esac
	}
	mr=$(role "$MASTER"); sr=$(role "$SLAVE")
	echo "  note  CL role by media: repro-master.img=$mr repro-slave.img=$sr"
	if [ "$mr $sr" = "MASTER SLAVE" ]; then
		MF=$MASTER; SF=$SLAVE
	elif [ "$mr $sr" = "SLAVE MASTER" ]; then
		MF=$SLAVE; SF=$MASTER
		# Named, not passed over: the file the run attached as the master
		# volume is the SLAVE element, so anything read from a device name
		# in this run's output is reversed. The comparison below is right
		# anyway, because it is taken by role.
		echo "  note  the images are the other way round from their names:" \
		     "the MASTER element is in repro-slave.img"
	else
		echo "sync-empty: COULD-NOT-RUN: neither image states a cluster role" >&2
		echo "  (repro-master.img=$mr repro-slave.img=$sr); the comparison" >&2
		echo "  would be between two volumes of unknown kind." >&2
		exit 2
	fi
	fingerprint "$MF" > "$W/fp.master"
	fingerprint "$SF" > "$W/fp.slave"
	# Counted from the INODE line, not by grepping ' FILE$' over the whole
	# fingerprint: that pattern matches the dirent lines too, because the
	# dirent print above ends in the entry's type, so on 2026-10-13 it read
	# 4,800 "file entr(ies)" on a volume holding 400 file inodes and the
	# population check passed on a tree that was 90% absent.
	nf() { command grep -c '^inode .* FILE' "$1" || true; }	# fingerprint
	nm=$(nf "$W/fp.master"); ns=$(nf "$W/fp.slave")
	nm=${nm:-0}; ns=${ns:-0}
	# The population first: a fingerprint that matched nothing on both
	# sides would compare equal and read as convergence.
	[ "$nm" -gt 0 ] 2>/dev/null
	check "the MASTER volume holds file inodes, by its own media" $? "$nm file inode(s)"
	# The comparison status is captured HERE, before anything else runs,
	# because `$?` belongs to the last command and the counts and the delta
	# below are commands too. Every one of them would otherwise overwrite
	# it and the convergence check would report the status of a `grep -c`
	# that always succeeds.
	cmp -s "$W/fp.master" "$W/fp.slave"; crc=$?
	# The differing-line count is printed as the WHOLE delta, not as a
	# count of content mismatches, because that is what `diff` computes
	# and the two are different numbers whenever the two sides hold a
	# different number of lines: on 2026-10-13 the full side's fingerprint
	# was 13,202 lines and the short side's 5,202, so "8,000 differ" was
	# the entire absence of 4,000 inode and 4,000 data lines rather than
	# 8,000 disagreements. The per-type counts are printed beside it so the
	# shortfall names the element class it is short of, which the single
	# "file entr(ies)" pair could not: it read 4,400 against 4,400 while
	# whole inode and data trees were absent.
	n_in() { command grep -c '^inode ' "$1" || true; }	# fingerprint
	n_dt() { command grep -c '^data ' "$1" || true; }
	n_de() { command grep -c '^dirent ' "$1" || true; }
	delta=$(diff "$W/fp.slave" "$W/fp.master" | command grep -c '^[<>]' || true)
	check "the SLAVE converged to its MASTER, entry for entry and block for block" $crc \
		"slave/master by type: inode $(n_in "$W/fp.slave")/$(n_in "$W/fp.master"), data $(n_dt "$W/fp.slave")/$(n_dt "$W/fp.master"), dirent $(n_de "$W/fp.slave")/$(n_de "$W/fp.master"); ${delta:-0} line(s) differ of $(wc -l < "$W/fp.slave")"
else
	echo "  FAIL  convergence not read: no fsck_hammer2 or hammer2 (H2_FSCK, H2_HAMMER2)"
	fail=$((fail + 1))
fi

echo "sync-empty: $checks check(s), $fail failed"
[ "$fail" = 0 ]
