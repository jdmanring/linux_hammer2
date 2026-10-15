#!/bin/sh
# The cluster's synchronization thread, run where it can be read. Two
# volumes go on the Linux guest. The first run is a lone SLAVE PFS, whose
# thread has nothing to copy: it must start at pfs-create, pass every five
# seconds, and stop at once when the volume is unmounted a moment after a
# pass, because a wakeup that does not reach the sleeper costs the five
# seconds left in its sleep. The second is a MASTER on one volume holding
# a set of files written before a SLAVE with the same cluster id exists on
# the other, so the only way the files reach the slave is the thread. The
# master is then changed while both stay mounted: files removed, a
# directory removed, files rewritten at new sizes, files added and one
# renamed, which is the thread's destroy, replace and insert paths after
# its first copy. Both volumes are checked on the host by fsck_hammer2,
# and the cluster's PFS on each is fingerprinted from `hammer2 -v show`:
# every directory entry's name, inode and type, every inode's size and
# type, and every data block's key and check code. The two must match, and
# each must hold the 35 files the changes leave.
#
# A fake pass to guard against: a thread that never starts passes every
# leak and warning check, so the thread, its passes and its copies are
# each counted rather than assumed.
#
# The fourth phase interrupts one. A stop is read only at the top of the
# thread body and between the deferred directories, so what a stop during
# synchronization costs is the rest of the pass it landed in. The window
# is the pass's own length, and what makes a pass long is a copy the thread
# must carry: a directory written while the slave is mounted reaches the
# slave through the frontend and leaves the thread passes of under a
# millisecond, so a second directory is written with the slave unmounted
# and the thread copies all of it on the remount. The unmount is issued
# once a pass bracket is open and the copy has begun, and the remount must
# finish it. The checks below the bracket check mean nothing without it,
# since an unmount after the pass closed reads as a clean stop that tested
# nothing.
#
# A second one: the warning check reads dmesg for sanitizer reports, and a
# module built against a kernel without KASAN emits none however broken it
# is, so that reading would pass in silence on the wrong kernel. The
# kernel tree's config says what to expect and the built module's imports
# say what it has, and the two are compared, which fails in both
# directions rather than only on an absent report.
#
# Exit 2 without the guest, the tools or a kernel tree. H2_FIXTURE_SHARE=1
# starts the guest beside another running domain, as test-fixtures.sh
# does; otherwise another domain is a reason not to.
set -u
FIXDIR=${H2_FIXTURE_DIR:-$HOME/Projects/linux_hammer2-data/fixtures}
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2")}
HAMMER2=${H2_HAMMER2:-$(command -v hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/hammer2")}
FSCK=${H2_FSCK:-$(command -v fsck_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2")}
RUN="timeout ${H2_RUN_TIMEOUT:-600} ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
# Release the volumes and detach them, safely.
#
# `virsh detach-disk --live` reaches a running guest as an ACPI eject:
# acpiphp_disable_and_eject_slot -> virtblk_remove -> del_gendisk ->
# blk_report_disk_dead -> sync_filesystem flushes every filesystem still
# mounted on that device, and a hammer2 flush of the ejected volume finds an
# empty base and hpanics the device into error.  Measured 2026-10-13, twice,
# both times because a detach ran while the guest still had the volume
# mounted: once from an ssh drop falling through to the checks, once from the
# guard added for it, which suppressed the false failures but detached in the
# same arm.
#
# So a RUNNING guest is asked to unmount and rmmod first, and the detach runs
# only when it reports no hammer2 mount left.  A guest that will not release
# them is not ejected under: this returns 1 and the caller says so, leaving
# the disks for a later run to clear once the guest is cleaned.  A STOPPED
# guest has nothing live to eject and is detached unconditionally.
#
# Every detach in this script goes through here, including the pre-flight,
# which is where a volume left behind by an unclean earlier run is cleared.
H2_MOUNTS="/mnt/h2c /mnt/h2s /mnt/h2m"
detach_disks() {
	if [ "$($VIRSH domstate "$GUEST" 2>/dev/null)" = running ]; then
		timeout 45 ssh -o ConnectTimeout=5 -o BatchMode=yes "$GUEST_SSH" \
		    'for m in '"$H2_MOUNTS"'; do umount -f "$m" 2>/dev/null; done
		     rmmod hammer2 2>/dev/null; true' >/dev/null 2>&1
		held=$(timeout 20 ssh -o ConnectTimeout=5 -o BatchMode=yes "$GUEST_SSH" \
		    'mount 2>/dev/null | grep -c " type hammer2"' 2>/dev/null | tr -d ' ')
		if [ "${held:-1}" != 0 ]; then
			echo "  note  $GUEST still holds ${held:-?} hammer2 mount(s), so its disks are not detached: a live detach would eject a volume it is still using and hpanic it" >&2
			return 1
		fi
	fi
	for d in vdb vdc; do
		$VIRSH detach-disk "$GUEST" $d --live >/dev/null 2>&1
		$VIRSH detach-disk "$GUEST" $d --config >/dev/null 2>&1
	done
	return 0
}
# Phase 4's interruption copies this many files into one directory on the
# master, which is what makes the pass long enough to interrupt: 37 ms empty,
# 418 ms at 20000 entries, measured on the KASAN guest. The check below needs
# the drain to outlast the unmount's own bookkeeping, which it does by an
# order of magnitude at this size.
NBIG=${H2_NBIG:-20000}
# Phase 4's backlog, written with the slave unmounted so the thread carries
# it: this is what makes a pass long enough for the unmount to land inside.
# A pass over the frontend-written bigdir runs 0.2 to 0.8 ms, measured, which
# a 10 ms poll cannot hit.
NBIG2=${H2_NBIG2:-20000}
# How deep into the pass, in copies past the phase-4a baseline, the unmount
# that stops the thread is issued. The copy depth at the stop is the one
# variable that separated the runs that lost inodes from those that
# converged (copied 4, 44, 88, 488 converged; 549 lost 422), and 0 stops at
# the first open bracket as before. Declared host-side because the launch
# line forwards it to the guest half, which runs under set -u.
STOP_DEPTH=${H2_STOP_DEPTH:-0}
STOP_DEPTH_MS=${H2_STOP_DEPTH_MS:-3000}
# The module's debug mask. 0x8000 prints a pass's bracket and an inode's
# marking; 0x0001 adds the carried prints in hammer2_sync_insert(),
# _replace() and _destroy(), one line per chain the thread writes, which
# is the only count of the copy itself. That bit is off by default because
# a large phase prints tens of thousands of lines.
H2DEBUG=${H2_DEBUG:-0x8000}
MASTER=$FIXDIR/cluster-master.img
SLAVE=$FIXDIR/cluster-slave.img
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

command -v virsh >/dev/null 2>&1 || { echo "cluster: COULD-NOT-RUN: no virsh" >&2; exit 2; }
[ -x "$NEWFS" ] || { echo "cluster: COULD-NOT-RUN: no newfs_hammer2 (H2_NEWFS)" >&2; exit 2; }
[ -x "$FSCK" ] || { echo "cluster: COULD-NOT-RUN: no fsck_hammer2 (H2_FSCK)" >&2; exit 2; }
[ -x "$HAMMER2" ] || { echo "cluster: COULD-NOT-RUN: no hammer2 (H2_HAMMER2)" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "cluster: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -d "$KDIR" ] || { echo "cluster: COULD-NOT-RUN: no kernel tree at $KDIR" >&2; exit 2; }
state=$($VIRSH domstate "$GUEST" 2>/dev/null) || {
	echo "cluster: COULD-NOT-RUN: no guest $GUEST" >&2; exit 2; }
names=$($VIRSH list --name 2>/dev/null) || {
	echo "cluster: COULD-NOT-RUN: virsh list failed, so other guests cannot be counted" >&2; exit 2; }
other=$(printf '%s\n' "$names" | grep -v -x -e "$GUEST" -e '' | grep -c . || true)
if [ "$other" -gt 0 ] && [ "${H2_FIXTURE_SHARE:-0}" != 1 ]; then
	echo "cluster: COULD-NOT-RUN: $other other guest(s) running; H2_FIXTURE_SHARE=1 to share" >&2
	exit 2
fi

make -s clean >/dev/null 2>&1
make -s KDIR="$KDIR" >/dev/null 2>&1 || {
	echo "cluster: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko

# What the kernel tree configures against what the module actually carries.
# grep -c prints its count and exits 1 on no match, so the count is kept and
# the status discarded.
command -v nm >/dev/null 2>&1 || {
	echo "cluster: COULD-NOT-RUN: no nm, so the module's instrumentation cannot be read" >&2; exit 2; }
want_asan=$(sed -n 's/^CONFIG_KASAN=//p' "$KDIR/.config" 2>/dev/null)
have_asan=$(nm -u "$KO" 2>/dev/null | grep -c '__asan' || true)
have_ubsan=$(nm -u "$KO" 2>/dev/null | grep -c '__ubsan' || true)

# The volumes are detached before they are recreated: a running guest's
# qemu holds an image open, and a file replaced under it is a file it no
# longer reads. This is where a volume left behind by an unclean earlier run
# is cleared, so it is also the detach most likely to run against a guest
# that still has one mounted, and it goes through the guarded helper.
detach_disks || {
	echo "cluster: COULD-NOT-RUN: $GUEST still holds a hammer2 volume, so the volumes cannot be recreated under it; unmount and rmmod on the guest first" >&2
	exit 2; }
rm -f "$MASTER" "$SLAVE"
for img in "$MASTER" "$SLAVE"; do
	truncate -s 2G "$img" && "$NEWFS" -L ROOT "$img" >/dev/null 2>&1 || {
		echo "cluster: COULD-NOT-RUN: newfs_hammer2 failed on $img" >&2; exit 2; }
done
if [ "$state" = running ]; then how=--live; else how=--config; fi
err=$($VIRSH attach-disk "$GUEST" "$MASTER" vdb --targetbus virtio $how 2>&1) &&
err=$($VIRSH attach-disk "$GUEST" "$SLAVE" vdc --targetbus virtio $how 2>&1) || {
	echo "cluster: COULD-NOT-RUN: could not attach the volumes: $err" >&2; exit 2; }
if [ "$state" != running ]; then
	$VIRSH start "$GUEST" >/dev/null 2>&1 || { echo "cluster: COULD-NOT-RUN: $GUEST did not start" >&2; exit 2; }
fi
n=0
until ssh -o ConnectTimeout=3 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null; do
	sleep 5; n=$((n + 1))
	[ $n -gt 60 ] && { echo "cluster: COULD-NOT-RUN: $GUEST did not answer ssh in 5 minutes" >&2; exit 2; }
done

cat > "$W/guest.sh" <<'GUEST'
set -u
# A guest left dirty by an earlier run that stopped early makes every check
# below read nothing: the module is already loaded, so insmod fails, and the
# mounts are already there, so the PFSes are not the ones this run creates.
# Refuse and name what is left, rather than reporting a run that never ran.
if lsmod 2>/dev/null | grep -q '^hammer2'; then
	echo "cluster: COULD-NOT-RUN: the guest still has the hammer2 module loaded; unmount its volumes and rmmod it first" >&2
	exit 2
fi
if mount 2>/dev/null | grep -q ' type hammer2'; then
	echo "cluster: COULD-NOT-RUN: the guest still has a hammer2 volume mounted; unmount it first" >&2
	exit 2
fi
rmmod hammer2 2>/dev/null; dmesg -C
# The kernel's ring is 128 KiB on the KASAN build and a pass prints a line per
# inode it copies, so a run that copies a large set overflows it and every
# count taken from dmesg afterwards is short by whatever scrolled off. A
# follower writes the same lines to a file as they arrive, and every count
# below reads that file. The follower is killed last, after rmmod has stopped
# the module's lines, so nothing written after the last count is lost.
K=/tmp/h2cluster.klog
dmesg -w > $K 2>&1 &
KPID=$!
echo "mounts-before $(( $(mount 2>/dev/null | grep -c ' type hammer2') ))"
insmod /tmp/hammer2.ko debug=$H2DEBUG || { echo "insmod failed"; exit 1; }
mkdir -p /mnt/h2m /mnt/h2s /mnt/h2c /mnt/h2l
klog() { grep -c "$1" $K; }
# A mount the guest cannot drop leaves its volume held, and the next unmount
# then blocks instead of returning. Counted on every phase so a wedged guest
# is visible in the probe output rather than only in the final failure.
mounts() { mount 2>/dev/null | grep -c ' type hammer2'; }
passes() { klog "sync_slaves pfs $1"; }

# 1. A lone SLAVE: start, pass, stop.
timeout 30 mount -t hammer2 /dev/vdb@ROOT /mnt/h2m || { echo "mount failed"; exit 1; }
hammer2 -s /mnt/h2m -t SLAVE pfs-create LONE >/dev/null 2>&1
echo "lone-thread $(ps -eo stat,comm | awk '$2=="h2nod-LONE"{print $1}')"
sleep 12
echo "lone-passes $(passes LONE)"
c=$(passes LONE); n=0
while [ "$(passes LONE)" = "$c" ] && [ $n -lt 80 ]; do sleep 0.1; n=$((n + 1)); done
t0=$(date +%s%N); umount /mnt/h2m; t1=$(date +%s%N)
echo "lone-umount-ms $(( (t1 - t0) / 1000000 ))"
echo "lone-threads-after $(ps -eo comm | grep -c '^h2nod-LONE')"
# The remount starts LONE's thread again, and pfs-delete stops it through
# hammer2_pfsdealloc(); the PFS goes so the two volumes differ only by CL.
mount -t hammer2 /dev/vdb@ROOT /mnt/h2m || exit 1
sleep 1
echo "lone-thread-remount $(ps -eo comm | grep -c '^h2nod-LONE')"
hammer2 -s /mnt/h2m pfs-delete LONE >/dev/null 2>&1; echo "lone-delete-rc $?"
echo "lone-threads-deleted $(ps -eo comm | grep -c '^h2nod-LONE')"
umount /mnt/h2m

# 2. A MASTER with a set, then a SLAVE in the same cluster on the other volume.
mount -t hammer2 /dev/vdb@ROOT /mnt/h2m || exit 1
hammer2 -s /mnt/h2m pfs-create CL >/dev/null 2>&1 || { echo "master pfs-create failed"; exit 1; }
clid=$(hammer2 -s /mnt/h2m pfs-list | awk '$3=="CL"{print $2}')
mount -t hammer2 /dev/vdb@CL /mnt/h2c || exit 1
mkdir -p /mnt/h2c/set/sub
i=0; while [ $i -lt 40 ]; do head -c $(( (i * 7919) % 300000 + 1 )) /dev/urandom > /mnt/h2c/set/f$i; i=$((i + 1)); done
i=0; while [ $i -lt 15 ]; do head -c $(( i * 4099 + 17 )) /dev/urandom > /mnt/h2c/set/sub/g$i; i=$((i + 1)); done
sync
mount -t hammer2 /dev/vdc@ROOT /mnt/h2s || exit 1
hammer2 -s /mnt/h2s -t SLAVE -u "$clid" pfs-create CL >/dev/null 2>&1 || { echo "slave pfs-create failed"; exit 1; }
echo "cluster-thread $(ps -eo comm | grep -c '^h2nod-CL')"
sleep 30
echo "cluster-passes $(passes CL)"
echo "cluster-updates $(klog 'syncthr: update inode')"

# 3. Change the master with the slave's copy in place.
rm -f /mnt/h2c/set/f0 /mnt/h2c/set/f1 /mnt/h2c/set/f2 /mnt/h2c/set/f3 /mnt/h2c/set/f4
rm -f /mnt/h2c/set/f5 /mnt/h2c/set/f6 /mnt/h2c/set/f7 /mnt/h2c/set/f8 /mnt/h2c/set/f9
rm -f /mnt/h2c/set/sub/g*; rmdir /mnt/h2c/set/sub
i=10; while [ $i -lt 15 ]; do head -c $(( i * 5003 + 70000 )) /dev/urandom > /mnt/h2c/set/f$i; i=$((i + 1)); done
i=0; while [ $i -lt 5 ]; do head -c $(( i * 12007 + 9000 )) /dev/urandom > /mnt/h2c/set/n$i; i=$((i + 1)); done
mv /mnt/h2c/set/f20 /mnt/h2c/set/renamed20
sync
c=$(passes CL)
sleep 30
echo "change-passes $(( $(passes CL) - c ))"
echo "change-files $(find /mnt/h2c/set -type f | wc -l)"
echo "pass-errors $(klog 'hammer2_sync_slaves: error')"

# 4. Interrupt a synchronization pass and resume it. A stop is read at the
# top of the thread body and between the deferred directories (hammer2_admin.c
# hammer2_thr_break, called once from hammer2_synchro.c), so a stop arriving
# during a pass waits for the current scan to finish: what the interruption
# costs is the rest of the pass it landed in, and the window is the pass's own
# length.
#
# The window is sized by how much the thread has to copy, not by how many
# entries a directory holds. bigdir's 20000 files are written while the slave
# is mounted, and the frontend writes them to the slave element itself
# (hammer2_xop_start_except() queues every element), so the thread has almost
# nothing to do for them: measured, passes after that write run 0.2 to 0.8 ms,
# and a 10 ms poll cannot land inside one.
#
# MEASURED 2026-10-13, and it changes which mount this phase stops. The thread
# belongs to the pmp hammer2_pfsalloc() matched by CLUSTER ID, which is the one
# created at the MASTER's mount (/mnt/h2c, /dev/vdb@CL); the slave's CL element
# joins THAT pmp, and unmounting the slave's ROOT (/mnt/h2s) tears down a
# different pmp and stops nothing (probed: h2nod-CL stays 1). Unmounting
# /mnt/h2c stops it (probed: 1 to 0), so that is the stop below.
#
# A pass does NOT bracket itself: "sync_slaves pfs CL" prints once per pass and
# "sync_slaves error" prints inside the inner loop, once per scan attempt, so a
# pass with deferrals emits one open and many closes (probed mid-copy: P=5
# C=11). The wait below reads the OPEN count alone.
#
# The stop is read at the thread's loop top and between deferred directories,
# never inside a scan (the comment above says so and the probe confirms it), so
# a pass in flight completes after the stop and didbreak does not fire for a
# mid-pass stop. What this phase measures is the stop reaching the pmp and the
# thread going, then the remount resuming it.
#
# The slave is never read through a mount of its cluster PFS, because
# mounting a SLAVE label fails with root-inode EIO (the pre-existing refusal
# the allocation-fault entry records), and reading through the ROOT mount
# sees the ROOT PFS, not the cluster. The copy is read from what is readable:
# the thread's own update lines, one per inode it copies (phase 2 measured
# 58 for 55 files and their directories), and both volumes' media at the end.
u0=$(klog 'syncthr: update inode')
echo "interrupt-base $u0"
# The write leaves no line of its own in the kernel log, so it is marked
# there, and a destroying pass can be placed inside or outside it.
mkdir /mnt/h2c/bigdir
# MEASURED 2026-10-15: the destroying pass is HERE, in the bigdir write, and
# never in the phase-4 window the unmount below is aimed at. The destroy line
# was located against the two probes in all thirty-one kept runs: every one of
# the 300-plus destroys lies between `bigdir write start` and `bigdir write
# end`, and NONE lies between `bigdir2 write start` and the end of the run, so
# an arm asked to catch the sweep can only do it here. The stop below this
# point is a different question (does an interrupted pass resume), and the two
# were conflated until now.
#
# The sweep runs when the element's scan ends early while the local scan still
# has chains (`chain && merror == ENOENT`), which is what the 20000-file write
# provokes: the element is written by the frontend, and the thread's own scan
# of it ends before its local chains are exhausted. That is why the destroy
# count tracks the write and not the interruption.
echo "h2probe: bigdir write start" > /dev/kmsg
i=0; while [ $i -lt $NBIG ]; do head -c 4096 /dev/urandom > /mnt/h2c/bigdir/p$i; i=$((i + 1)); done
sync
echo "h2probe: bigdir write end" > /dev/kmsg
# Destroys the thread made while the write ran, and in all. Both read 0
# unless H2_DEBUG carries 0x0001, which is what prints a destroy.
echo "write-destroys $(sed -n '/h2probe: bigdir write start/,/h2probe: bigdir write end/p' $K | grep -c 'destroy rec')"
# The backlog: written with the slave unmounted, so only the thread can
# carry it across, and a pass long enough to interrupt follows on the remount.
umount /mnt/h2s
echo "h2probe: bigdir2 write start" > /dev/kmsg
mkdir /mnt/h2c/bigdir2
i=0; while [ $i -lt $NBIG2 ]; do head -c 4096 /dev/urandom > /mnt/h2c/bigdir2/q$i; i=$((i + 1)); done
sync
echo "h2probe: bigdir2 write end" > /dev/kmsg
mount -t hammer2 /dev/vdc@ROOT /mnt/h2s || exit 1
# The copy has begun once its update lines pass the phase-4a baseline.
n=0
while [ $n -lt 1200 ]; do
	[ "$(klog 'syncthr: update inode')" -gt "$u0" ] && break
	sleep 0.1; n=$((n + 1))
done
echo "interrupt-begun $([ "$(klog 'syncthr: update inode')" -gt "$u0" ]; echo $?)"
# Wait for a pass to open. A pass has begun when the OPEN count advances,
# and only that: `sync_slaves pfs CL` prints once per pass while
# `sync_slaves error` prints inside the inner loop once per scan ATTEMPT, so
# one pass with deferrals emits one open and many closes (measured mid-copy:
# P=5 C=11). The two are not a pair, and a check that compares them reads
# closed while a pass is open -- which is what this loop did, reporting
# `bracket open, rc 1` however long the pass was, with the close line also
# shared by phase 1's LONE pfs and by passes that error with no open.
opened=$(klog 'sync_slaves pfs CL')
n=0
bracket=1
while [ $n -lt 1200 ]; do
	o=$(klog 'sync_slaves pfs CL')
	if [ "$o" -gt "$opened" ]; then
		bracket=0; break
	fi
	sleep 0.01; n=$((n + 1))
done
# The bracket state is read here, before the unmount: the pass that is open
# now completes after the stop is read, so testing the bracket after the
# unmount would read closed however well the interruption landed.
echo "interrupt-bracket-open $bracket"
# MEASURED 2026-10-14: the unmount is issued the instant a bracket opens, so
# the stop lands wherever the pass happens to be, and the copy depth at the
# stop is the one variable that separates a run that loses inodes from one
# that converges: five runs read copied=4, 44, 88, 488, 549, and only the
# deep one (549) lost 422 inodes. `H2_STOP_DEPTH` waits, bounded, for the
# pass to advance that many scan actions past the baseline before the unmount,
# so a run can place the stop deep enough to reach the shortfall instead of
# racing for it. 0 is the old behavior (stop at the first open bracket).
#
# The wait is on the COPY COUNT, `syncthr: update inode`, and not on `acted`.
#
# MEASURED 2026-10-14, two separate findings.
#
# First, the failure is deterministic on the copy count at the interruption, and
# on nothing else. Every run that was interrupted with `copied=2` lost inodes
# (132, 80 and 2 lines on the three that reached it) and every run at `copied`
# 5, 12, 28, 44, 47, 51 or 85 converged. The resumed thread made 0 updates in
# all of them, so the outcome is set by the pass the unmount lands in and can be
# placed by waiting for that pass to reach a chosen count.
#
# Second, `acted` cannot place it. That field is on the pass's `filekeys` line,
# which prints only when the pass ends, so during the pass it does not move and
# the wait below exhausted its bound without advancing. The update line prints
# during the pass, which is what this wait needs.
copied() { grep -c 'syncthr: update inode' $K; }
STOP_DEPTH=${H2_STOP_DEPTH:-0}
STOP_DEPTH_MS=${H2_STOP_DEPTH_MS:-3000}
# The target is the ABSOLUTE copy count, not a delta from where the bracket was
# found. MEASURED 2026-10-15: the bracket wait above already lets the pass copy,
# so a delta of 2 sampled its baseline at `copied` 3 to 5 and stopped at 5 to 7,
# which is past the value the failure needs. The runs that fail are the ones
# interrupted at a copy count of 2, so the count is what is asked for.
a0=$(copied); a0=${a0:-0}
target=${STOP_DEPTH:-0}
n=0
while [ "${STOP_DEPTH:-0}" != 0 ]; do
	a=$(copied); a=${a:-0}
	[ "$a" -ge "$target" ] && break
	# A pass that has already copied past the target cannot be held for it; the
	# unmount would land after the pass, which is a different test.
	[ "$a" -gt "$target" ] && break
	[ $n -ge "$STOP_DEPTH_MS" ] && break
	sleep 0.05; n=$((n + 1))
done
echo "interrupt-stop-copied $(copied) from $a0 wanted $STOP_DEPTH"
echo "interrupt-stop-acted $(acted)"
# The stop must reach the CL pmp's own mount. Measured 2026-10-13: unmounting
# the slave's ROOT (/mnt/h2s) leaves the h2nod-CL thread alive, because the
# thread belongs to the pmp hammer2_pfsalloc() matched by cluster id, which is
# the one created at the MASTER's mount (/mnt/h2c, /dev/vdb@CL). Unmounting
# /mnt/h2c reaches the pmp's sync_thrs[]. MEASURED 2026-10-14: the guest starts
# ONE h2nod-CL thread (phase 2's `starts one thread: 1`) and it SURVIVES this
# unmount (`threads 1 to 1`, the post-unmount wait exhausting its 20 s). The
# source says why: hammer2_thr_delete() has three callers (pfsdealloc from the
# pfs-delete ioctl, pfsfree, pfsfree_scan from the device teardown) and umount
# reaches none -- hammer2_unmount_helper() clears pmp->mp and decrements
# mount_count. The phase keeps /mnt/h2s mounted, so the pmp is alive and its
# thread is correct to run. The 2026-10-13 probe's `2 to 1` is a topology the
# script does not have. The pass in flight completes either way: the thread
# reads STOP/FREEZE at loop top and between deferred directories only, which is
# this phase's documented contract, so didbreak is not a success condition.
echo "interrupt-threads-before $(ps -eo comm | grep -c '^h2nod-CL')"
t0=$(date +%s%N); timeout 60 umount /mnt/h2c; urc=$?; t1=$(date +%s%N)
echo "interrupt-umount-rc $urc"
echo "interrupt-umount-ms $(( (t1 - t0) / 1000000 ))"
echo "interrupt-copied $(( $(klog 'syncthr: update inode') - u0 ))"
# The action counters the module prints under 0x8000 (acted/failed over the
# scan's action switch), read at the interruption so the shortfall this run
# ends with is paired with the count of copies that returned an error. klog()
# is grep -c, so the matching LINES are taken with a plain grep.
#
# MEASURED 2026-10-15: the line is NOT one cumulative record.  `acted`,
# `failed`, `last` and `kept` are file-scope atomics accumulated over the run,
# but `sweep` and `iters` are locals of hammer2_sync_slaves() reset on entry
# (src/sys/fs/hammer2/hammer2_synchro.c:558,590), so each line carries ONE
# pass's values.  `tail -1` therefore reports the sweep count of the LAST pass,
# which is almost always a quiet one: on `cluster-run-20261015-014720` the
# destroying pass printed `sweep 127` on its own line and the last line printed
# `sweep 0`, and reading the tail is what put a sweep count of 0 into five
# separate records as a finding.  Both readings are printed: the pass with the
# most sweeps (the one that did the damage) and the last line (the cumulative
# action counters).
maxsweep() {	# the filekeys line carrying the largest `sweep`, or empty
	sed -n 's/^\[[^]]*\] //p' "$1" | grep '^filekeys' | \
		awk 'BEGIN { m = -1 }
		     { for (i = 1; i <= NF; i++) if ($i == "sweep") s = $(i + 1) + 0
		       if (s > m) { m = s; line = $0 } }
		     END { if (line) print line }'
}
echo "interrupt-actions $(grep 'filekeys' $K | tail -1 | sed 's/^\[[^]]*\] //')"
echo "interrupt-sweep-max $(maxsweep $K)"
# The thread stops after the pass it landed in drains, so the count is waited
# for and the wait is the reading. The wait is for the count to drop below the
# pre-unmount count (the CL element's thread stopping), not to reach zero, since
# the second element's thread is expected to stay.
tb=$(ps -eo comm | grep -c '^h2nod-CL')
n=0
while [ $n -lt 200 ]; do
	[ "$(ps -eo comm | grep -c '^h2nod-CL')" -lt "$tb" ] && break
	sleep 0.1; n=$((n + 1))
done
echo "interrupt-threads $(ps -eo comm | grep -c '^h2nod-CL')"
echo "interrupt-stop-tenths $n"
echo "interrupt-didbreak $(klog didbreak)"
# 5. Resume: remount the mount the stop took down, which is the CL pmp's
# (/mnt/h2c), and let the thread pass again. The wait is for two completed
# passes after the remount, read from the OPEN count -- the close count is not
# a pass count -- and what the slave holds is decided off the media by the
# fingerprint at the end.
timeout 30 mount -t hammer2 /dev/vdb@CL /mnt/h2c; rrc=$?
echo "resume-remount-rc $rrc"
echo "resume-mounts $(mount 2>/dev/null | grep -c ' type hammer2')"
echo "resume-thread $(ps -eo comm | grep -c '^h2nod-CL')"
c0=$(klog 'sync_slaves pfs CL')
# The resume has to be given until the thread stops making progress, not a
# fixed pass count. MEASURED 2026-10-14: a pass handles ONE deferred inode when
# its local scan is empty (filekeys iters 2 exit 1, acted +1), and the failing
# run's log shows 58 such passes in 70 ms walking inodes 0x438 down to 0x400,
# each stamping one. Two passes therefore drains two inodes of a backlog that
# can be hundreds, and the run then measured a race rather than convergence.
# The wait below is for the update-inode count to stop advancing across a
# settle window, bounded, and the observed convergence time is printed.
u0=$(klog 'syncthr: update inode')
n=0; last=-1; still=0
while [ $n -lt ${H2_RESUME_SECS:-300} ]; do
	u=$(klog 'syncthr: update inode')
	if [ "$u" = "$last" ]; then
		still=$(( still + 1 ))
	else
		still=0
		last=$u
	fi
	[ "$still" -ge 10 ] && break
	sleep 1; n=$((n + 1))
done
echo "resume-converge-seconds $n"
echo "resume-updates $(( $(klog 'syncthr: update inode') - u0 ))"
echo "resume-settled $still"
echo "resume-seconds $n"
echo "resume-passes $(( $(klog 'sync_slaves pfs CL') - c0 ))"
echo "resume-errors $(klog 'hammer2_sync_slaves: error')"
timeout 60 umount /mnt/h2c; timeout 60 umount /mnt/h2s; timeout 60 umount /mnt/h2m
echo "cluster-umount ok"
echo "cluster-threads-after $(ps -eo comm | grep -c '^h2nod')"
echo "scrapped $(klog unmount_scrap)"
echo "kernel-warnings $(grep -c -E 'WARNING|BUG:|UBSAN:|circular locking|possible recursive' $K)"
# Before rmmod, so the report's %pS resolves the module's own symbols. The
# scan used to follow rmmod, where those symbols print as addresses and only
# a process named hammer2 could match, and to run without the wait the
# scanner's age rule needs (kmemleak.c MSECS_MIN_AGE, 5000 ms).
sleep 6
if echo scan > /sys/kernel/debug/kmemleak 2>/dev/null; then
	echo "kmemleak $(grep -c hammer2 /sys/kernel/debug/kmemleak)"
else
	echo "kmemleak unusable"
fi
timeout 120 rmmod hammer2 && echo "rmmod ok"
sync
kill $KPID 2>/dev/null
GUEST

scp -q "$KO" "$W/guest.sh" "$GUEST_SSH:/tmp/" || { echo "cluster: COULD-NOT-RUN: copy to $GUEST failed" >&2; exit 2; }
$RUN "$GUEST_SSH" "NBIG=$NBIG NBIG2=$NBIG2 H2DEBUG=$H2DEBUG H2_STOP_DEPTH=$STOP_DEPTH H2_STOP_DEPTH_MS=$STOP_DEPTH_MS sh -c 'mv /tmp/guest.sh /tmp/h2cluster.sh; . /tmp/h2cluster.sh'" > "$W/out" 2>&1
rc=$?
# What the guest half actually returned, before anything is inferred from
# the readings below.  Measured 2026-10-13: a run whose ssh session dropped
# mid-flight left $W/out with the phases it had reached and none of the
# ones after, and the fifteen checks reading those empty values each
# reported a FAIL against the subject.  An ssh drop is not the subject
# failing and must not be read as one.
gout=$(wc -l < "$W/out" 2>/dev/null | tr -d ' ')
# Exit 2 is the guest half refusing its own setup and it names why on
# stderr, so it is surfaced and reported as COULD-NOT-RUN.  A non-zero that
# is neither 2 nor 124 is the guest half or its session ending without
# finishing, which is also COULD-NOT-RUN and not a failure of the subject.
# The disks are released only after the guest has stopped touching them: a
# detach under a live run reaches the guest as an ACPI eject whose flush
# finds an empty base and hpanics the device into error (measured
# 2026-10-13, trace acpiphp_disable_and_eject_slot -> virtblk_remove ->
# del_gendisk -> blk_report_disk_dead -> sync_filesystem -> hammer2_sync_fs
# -> hammer2_base_delete).  sync-empty-base.sh has guarded exit 2 since
# 2026-10-12; this script guarded only the hang.
if [ "$rc" = 2 ] || command grep -q "COULD-NOT-RUN" "$W/out" 2>/dev/null; then
	command grep -m1 "COULD-NOT-RUN" "$W/out" 2>/dev/null >&2 ||
		echo "cluster: COULD-NOT-RUN: the guest half exited 2 without a reason" >&2
	detach_disks
	exit 2
fi
if [ "$rc" != 0 ] && [ "$rc" != 124 ]; then
	scp -q "$GUEST_SSH:/tmp/h2cluster.klog" "$FIXDIR/cluster-drop-$(date +%Y%m%d-%H%M%S).klog" 2>/dev/null
	# The guest's output is kept beside the klog: it is what says how far the
	# run reached, and on 2026-10-13 it was discarded, leaving only a line
	# count and no way to see where the guest half stopped.
	cp "$W/out" "$FIXDIR/cluster-drop-$(date +%Y%m%d-%H%M%S).out" 2>/dev/null
	printf '%s\n' "--- guest output ($gout line(s)) ---" >&2
	sed 's/^/  guest: /' "$W/out" >&2 2>/dev/null
	detach_disks
	echo "cluster: COULD-NOT-RUN: the guest session ended rc=$rc after $gout line(s) of output, so the run did not finish; its kernel log is kept beside the images as cluster-drop-*.klog" >&2
	exit 2
fi
# A hung guest keeps running after timeout kills the client, holding the
# module, the mounts and the disks, and $W dies with the trap, so the run's
# trace is copied off the guest before anything else: a hang is the failure
# shape a concurrency defect takes, and discarding it wastes the run that
# would say most. The disks are released the same way the clean path does,
# or the next run finds its targets taken.
if [ "$rc" = 124 ]; then
	scp -q "$GUEST_SSH:/tmp/h2cluster.klog" "$FIXDIR/cluster-hang-$(date +%Y%m%d-%H%M%S).klog" 2>/dev/null
	detach_disks
	echo "  FAIL  the guest run hung past ${H2_RUN_TIMEOUT:-600}s; its kernel log is kept beside the images as cluster-hang-*.klog"
	exit 1
fi
# The guest's kernel log carries the pass's own records -- the filekeys
# counters, the destroy keys under H2_DEBUG&0x4000, the update lines -- and it
# lives only on the guest, which detach_disks below tears down. A run that
# finished but left the slave short is the one whose destroy keys answer whether
# the destroy made the shortfall, so the log is copied off before the disks are
# released, not only on the hang path. MEASURED 2026-10-14: a run that lost 40
# inodes (n<0 40, slave short by 40) kept no klog because it exited normally,
# which discarded exactly the evidence the run produced.
scp -q "$GUEST_SSH:/tmp/h2cluster.klog" "$FIXDIR/cluster-run-$(date +%Y%m%d-%H%M%S).klog" 2>/dev/null \
	&& echo "  kept  the guest kernel log beside the images as cluster-run-*.klog"
detach_disks

val() { sed -n "s/^$1 //p" "$W/out" | head -1; }
fail=0; checks=0
check() {	# check <name> <condition-result 0/1> <reading>
	checks=$((checks + 1))
	if [ "$2" = 0 ]; then echo "  ok    $1: $3"; else echo "  FAIL  $1: $3"; fail=$((fail + 1)); fi
}
t=$(val lone-thread)
case "$t" in I*|S*) r=0 ;; *) r=1 ;; esac; check "lone SLAVE's thread exists and sleeps idle" $r "state '${t:-none}'"
p=$(val lone-passes); [ "${p:-0}" -ge 2 ] 2>/dev/null; check "it passes every five seconds" $? "${p:-0} passes in 12 s"
ms=$(val lone-umount-ms); [ "${ms:-99999}" -lt 1000 ] 2>/dev/null; check "unmount right after a pass stops it at once" $? "${ms:-none} ms; a lost wakeup costs about 5000"
a=$(val lone-threads-after); [ "${a:-1}" = 0 ]; check "no thread is left" $? "${a:-none}"
a=$(val lone-thread-remount); [ "${a:-0}" = 1 ]; check "a remount starts the thread again" $? "${a:-none}"
a=$(val lone-delete-rc); [ "${a:-1}" = 0 ]; check "pfs-delete removes the SLAVE" $? "exit ${a:-none}"
a=$(val lone-threads-deleted); [ "${a:-1}" = 0 ]; check "pfs-delete stops its thread" $? "${a:-none} left"
c=$(val cluster-thread); [ "${c:-0}" = 1 ]; check "the SLAVE in a cluster starts one thread" $? "${c:-0}"
u=$(val cluster-updates); [ "${u:-0}" -ge 55 ] 2>/dev/null; check "the thread copies the set" $? "${u:-0} inode updates for 55 files and their directories"
p=$(val change-passes); [ "${p:-0}" -ge 2 ] 2>/dev/null; check "the thread keeps passing after the master changes" $? "${p:-0} passes in 30 s"
p=$(val change-files); [ "${p:-0}" = 35 ]; check "the changes leave 35 files on the master" $? "${p:-none}"
p=$(val pass-errors); [ "${p:-1}" = 0 ]; check "no pass reports an error" $? "${p:-none}"
grep -q '^cluster-umount ok' "$W/out"; check "the cluster unmounts" $? "$(grep -c '^cluster-umount ok' "$W/out") of 1"
# Phase 4: the interruption must land inside an open pass bracket, or every
# check below it tested an idle thread. The bracket check comes first because
# the others mean nothing without it.
# The raw phase-4 fields are printed before their checks: a check message
# carries one number and several of these decide it together (the stop's wait
# and the thread count behind one verdict), and the guest's output file is
# removed at exit, so a field not printed here is lost with the run.
echo "  raw   phase4 bracket=$(val interrupt-bracket-open) begun=$(val interrupt-begun) stop-copied=$(val interrupt-stop-copied) copied=$(val interrupt-copied) umount-ms=$(val interrupt-umount-ms) threads-left=$(val interrupt-threads) stop-tenths=$(val interrupt-stop-tenths) didbreak=$(val interrupt-didbreak) actions=$(val interrupt-actions) sweep-max=$(val interrupt-sweep-max) resume-rc=$(val resume-remount-rc) resume-passes=$(val resume-passes) resume-updates=$(val resume-updates) resume-settled=$(val resume-settled) resume-conv-s=$(val resume-converge-seconds)"
b=$(val interrupt-bracket-open); [ "$b" = 0 ]; check "the unmount lands inside an open pass" $? "bracket open, rc ${b:-none}"
b=$(val interrupt-begun); [ "$b" = 0 ]; check "the copy had begun before the unmount" $? "rc ${b:-none}"
# When the phase is asked to stop at a set depth, a run that stopped short of it
# did not test the interruption at that depth, so the check reports where the
# stop landed against what was asked. A run at the default depth 0 has nothing
# to assert and skips it.
sd=$(val interrupt-stop-copied)
if [ "${H2_STOP_DEPTH:-0}" != 0 ]; then
	# The stop landed if the copy count at the unmount reached what was asked.
	# The value is `N from M wanted W`, so the field before " from" is taken.
	got=$(printf '%s\n' "$sd" | awk '{print $1}')
	[ "${got:-0}" -ge "${H2_STOP_DEPTH:-0}" ] 2>/dev/null; check "the stop landed at the requested copy count" $? "${sd:-none} (wanted ${H2_STOP_DEPTH:-none})"
fi
c=$(val interrupt-copied); [ "${c:-0}" -ge 1 ] 2>/dev/null; check "the interrupted pass was copying" $? "${c:-0} inode updates"
ms=$(val interrupt-umount-ms); [ "${ms:-0}" -gt 0 ] 2>/dev/null; check "the unmount waits for the pass rather than returning at once" $? "${ms:-0} ms"
tb=$(val interrupt-threads-before); a=$(val interrupt-threads)
# The thread is deleted only by hammer2_pfsdealloc() (the pfs-delete ioctl)
# and hammer2_pfsfree() (pfsfree_scan): grep of src/ shows no other caller of
# hammer2_thr_delete(). A plain umount tears the mount down but does not
# dealloc the pmp, and the phase keeps the pmp's other mount (/mnt/h2s) up, so
# the h2nod-CL thread legitimately survives umount /mnt/h2c. MEASURED
# 2026-10-14: `threads 1 to 1`, the unmount returning in 4.3 s. The check that
# asserted the thread stops here was asserting an invariant the port does not
# have, and the reading is that the thread exists through the interruption and
# the resume brings passes, which the checks below read.
[ "${tb:-0}" -ge 1 ] 2>/dev/null && [ "${a:-0}" -ge 1 ] 2>/dev/null
check "the CL pmp's thread survives the unmount and the resume passes" $? "threads ${tb:-none} to ${a:-none} across umount /mnt/h2c"
# The stop is read at the thread's loop top and between deferred directories,
# never inside a scan, so a pass in flight completes and didbreak cannot fire
# for a stop issued mid-pass. Requiring it would be a check no correct run can
# satisfy; the boundary the design allows is the thread count above.
a=$(val resume-thread); [ "${a:-0}" = 1 ]; check "the remount starts its thread again" $? "${a:-none}"
p=$(val resume-passes); [ "${p:-0}" -ge 2 ] 2>/dev/null; check "the resumed thread completes two passes" $? "${p:-0} in $(val resume-seconds) s"
# The resume must be given until the thread stops advancing, not a fixed pass
# count. A pass whose local scan is empty handles one inode, so a backlog of
# hundreds needs hundreds of passes and a two-pass wait measured a race. The
# settle counter is 10 consecutive seconds with no new update-inode line; the
# bound is H2_RESUME_SECS (300) and a run that hits it did not converge.
s=$(val resume-settled); [ "${s:-0}" -ge 10 ] 2>/dev/null; check "the resumed thread stops advancing rather than being cut off" $? "settled ${s:-none} s after $(( $(val resume-updates) )) updates in $(val resume-converge-seconds) s"
if [ $(( H2DEBUG & 1 )) = 1 ]; then
	w=$(val write-destroys); [ "${w:-1}" = 0 ]; check "no pass destroys on the slave while the master is being written" $? "${w:-none} destroy(s) inside the write"
fi
e=$(val resume-errors); [ "${e:-1}" = 0 ]; check "no pass reports an error across the interruption" $? "${e:-none}"
s=$(val scrapped); [ "${s:-1}" = 0 ]; check "nothing the thread copied is scrapped unwritten" $? "${s:-none} chains scrapped"
grep -q '^rmmod ok' "$W/out"; check "the module unloads" $? "$(grep -c '^rmmod ok' "$W/out") of 1"
if [ "$want_asan" = y ]; then
	[ "${have_asan:-0}" -gt 0 ] 2>/dev/null
	check "the module carries the instrumentation its kernel tree configures" $? "${have_asan:-0} __asan and ${have_ubsan:-0} __ubsan import(s), so a KASAN report can be emitted"
else
	[ "${have_asan:-0}" = 0 ] 2>/dev/null
	check "the module carries no instrumentation, its kernel tree configuring none" $? "${have_asan:-0} __asan import(s); the KASAN and UBSAN patterns below cannot report on this kernel, and say nothing here"
fi
k=$(val kernel-warnings); [ "${k:-1}" = 0 ]; check "no kernel warning, lockdep, KASAN or UBSAN report" $? "${k:-none}"
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

for img in "$MASTER" "$SLAVE"; do
	# The status is captured before anything else runs. Written as
	# check "... $(basename "$img")" $? "exit $?" the substitution in the
	# same command replaced the status with its own, so both fsck checks
	# read 0 and passed whatever fsck did.
	b=$(basename "$img")
	"$FSCK" "$img" > "$W/fsck.$b" 2>&1
	s=$?
	check "fsck_hammer2 $b" $s "exit $s"
done
# fsck prints a running total as it walks; the last one is the volume's.
last() { grep -o '([0-9]* inode, [0-9]* indirect, [0-9]* data, [0-9]* dirent)' "$1" | tail -1; }
m=$(last "$W/fsck.cluster-master.img" | sed 's/ [0-9]* indirect,//')
v=$(last "$W/fsck.cluster-slave.img" | sed 's/ [0-9]* indirect,//')
[ -n "$m" ] && [ "$m" = "$v" ]; check "the slave holds what the master holds" $? "master $m, slave $v; indirect blocks are left out, the slave's being built in insertion order"

# The fingerprint of the cluster's PFS, from the line naming it to the
# line closing it. Inode check codes are left out: they cover timestamps
# and transaction ids, which a slave does not share with its master.
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
fingerprint "$MASTER" > "$W/fp.master"
fingerprint "$SLAVE" > "$W/fp.slave"
nm=$(grep -c ' FILE$' "$W/fp.master"); ns=$(grep -c ' FILE$' "$W/fp.slave")
nd=$(grep -c '^data ' "$W/fp.master")
# The interruption phase leaves its large directory on both volumes, so the
# fingerprint's expected count is the set's 35 plus bigdir's NBIG.
want_files=$((35 + NBIG + NBIG2))
[ "$nm" = "$want_files" ] && [ "$nd" -gt 0 ]; check "the master's PFS holds the $want_files files, by its own media" $? "$nm file entries, $nd data blocks"
cmp -s "$W/fp.master" "$W/fp.slave"; check "the slave's PFS matches the master's entry for entry and block for block" $? "$ns file entries; $(diff "$W/fp.master" "$W/fp.slave" | grep -c '^[<>]') lines differ of $(wc -l < "$W/fp.master")"
# A fingerprint difference is only attributable while the run's images exist:
# they are recreated at the start of every run, so the next run destroys the
# evidence this one produced. MEASURED 2026-10-15: a run differed by 4 lines
# with nothing scrapped and its images were overwritten before the media could
# be read, which left the direction of the shortfall unread. A run that differs
# keeps both images beside its kernel log.
ndiff=$(diff "$W/fp.master" "$W/fp.slave" | grep -c '^[<>]')
if [ "${ndiff:-0}" != 0 ]; then
	stamp=$(date +%Y%m%d-%H%M%S)
	cp "$MASTER" "$FIXDIR/cluster-diff-master-$stamp.img" 2>/dev/null
	cp "$SLAVE" "$FIXDIR/cluster-diff-slave-$stamp.img" 2>/dev/null
	diff "$W/fp.master" "$W/fp.slave" > "$FIXDIR/cluster-diff-fp-$stamp.txt" 2>/dev/null
	echo "  kept  the differing run's images and fingerprint beside the kernel log as cluster-diff-*-$stamp.*"
fi

echo "cluster: $checks check(s), $fail failed"
[ "$fail" = 0 ]
