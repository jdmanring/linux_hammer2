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
# The snapshot pass added its own readings: the source and target
# snapshots listed as PFSes while a pass runs, the mutation phase reading
# the slave's media against the snapshot's state rather than the live
# master's, the verify rounds, the idle window after the resume settles,
# which waits for two idle lines after the last idle stamp rather than a
# fixed number of seconds, and the two root tids once idle. H2_CRASH=1
# cuts the guest's power inside the backlog copy and reads both media as
# the cut left them before the restart. H2_SYNC_SNAPSHOT=0 is the negative
# control: the live pass, which must list no snapshot and must write the
# master's state of the mutated set. The run's own report is kept beside
# the klog it copies off, under one stamp, in the fixtures directory.
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
# H2_PASS_TREE=N replaces the phases with one question: what one
# snapshot-form pass costs over a tree of N files when one file changed,
# read against the thread's cadence of 5.12 s, which a commit acknowledged
# by a pass would wait out (doc/CLUSTER_PROTOCOL_DESIGN.md, candidate 5).
# The tree is written through the cluster, whose frontend writes both
# elements, in H2_TREE_FANOUT directories by H2_TREE_WRITERS shells as
# million-tree.sh writes it; then H2_PASS_CHANGES times one file is
# rewritten on the master alone and the slave returned, and the thread's
# next pass is read from its begin, pass, verdict and end lines.
TREE=${H2_PASS_TREE:-0}
TREE_FAN=${H2_TREE_FANOUT:-1000}
TREE_WRITERS=${H2_TREE_WRITERS:-4}
PASS_CHANGES=${H2_PASS_CHANGES:-3}
if [ "$TREE" = 0 ]; then IMGSIZE=2G; RUNSECS=600; else IMGSIZE=8G; RUNSECS=14400; fi
RUN="timeout ${H2_RUN_TIMEOUT:-$RUNSECS} ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
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
STOP_DEPTH_MS=${H2_STOP_DEPTH_MS:-240000}
# Phase 2b, the refused copy: how many allocations the freemap refuses
# inside the thread's first pass (0 leaves the phase out). Needs
# H2_LOCKDEBUG=1, which builds the knob. H2_KO names a module built elsewhere to load instead of building one,
# which is how a run against the tree before a fix is made.
FAULT=${H2_FAULT:-0}
LOCKDEBUG=${H2_LOCKDEBUG:-0}
# Two arms of the tree run, each 0 or 1 and each needing H2_LOCKDEBUG=1's
# knob. H2_FORCE_RESCAN=1 starts the first change's pass as if the rescan
# set had overflowed, so it compares every inode; the set holds 64 entries
# and nothing else here fills it. H2_FAIL_STAMP=1 fails the second change's
# PFS-root stamp, whose pass must then not read verified. H2_COLLAPSE=1 or
# 2, with the same knob build and outside the tree run, collapses the
# indirect parent of one insert of phase 4's backlog copy into its own
# parent while the insert has it unlocked, after (1) or before (2) the
# insert, as the flusher can; the scan must then end failed with its guard's
# line and the copy still complete. The tree run's cluster mount writes both
# elements, so its passes insert nothing.
FORCE_RESCAN=${H2_FORCE_RESCAN:-0}
FAIL_STAMP=${H2_FAIL_STAMP:-0}
COLLAPSE=${H2_COLLAPSE:-0}
# The module's debug mask. 0x8000 prints a pass's bracket and an inode's
# marking; 0x0001 adds the carried prints in hammer2_sync_insert(),
# _replace() and _destroy(), one line per chain the thread writes, which
# is the only count of the copy itself. That bit is off by default because
# a large phase prints tens of thousands of lines.
H2DEBUG=${H2_DEBUG:-0x8000}
# The module's sync_snapshot parameter: 1 reads each pass from a snapshot
# of the master element, 0 is the carried live-to-live pass. The default
# follows the module's own, so a run that sets neither reads what a user
# gets; H2_SYNC_SNAPSHOT=0 is the negative control for the snapshot phase.
H2SNAP=${H2_SYNC_SNAPSHOT:-1}
# The tree arm times the snapshot pass by its begin and end lines, which
# only that pass prints, under bit 0x8000.
if [ "$TREE" != 0 ] && { [ "$H2SNAP" != 1 ] || [ $(( H2DEBUG & 0x8000 )) = 0 ] || [ $(( TREE % TREE_FAN )) != 0 ]; }; then
	echo "cluster: COULD-NOT-RUN: H2_PASS_TREE needs H2_SYNC_SNAPSHOT=1, H2_DEBUG with 0x8000 and a count H2_TREE_FANOUT divides" >&2
	exit 2
fi
case $FORCE_RESCAN$FAIL_STAMP in 00|01|10|11) ;; *)
	echo "cluster: COULD-NOT-RUN: H2_FORCE_RESCAN and H2_FAIL_STAMP are 0 or 1" >&2; exit 2 ;;
esac
case $COLLAPSE in 0|1|2) ;; *)
	echo "cluster: COULD-NOT-RUN: H2_COLLAPSE is 0, 1 or 2" >&2; exit 2 ;;
esac
if [ "$COLLAPSE" != 0 ] && { [ "$TREE" != 0 ] || { [ "$LOCKDEBUG" != 1 ] && [ -z "${H2_KO:-}" ]; }; }; then
	echo "cluster: COULD-NOT-RUN: H2_COLLAPSE needs the default shape, not H2_PASS_TREE, and H2_LOCKDEBUG=1 (or an H2_KO built with it)" >&2
	exit 2
fi
if [ "$FORCE_RESCAN$FAIL_STAMP" != 00 ] && { [ "$TREE" = 0 ] || { [ "$LOCKDEBUG" != 1 ] && [ -z "${H2_KO:-}" ]; } || { [ "$FAIL_STAMP" = 1 ] && [ "$PASS_CHANGES" -lt 2 ]; }; }; then
	echo "cluster: COULD-NOT-RUN: H2_FORCE_RESCAN and H2_FAIL_STAMP need H2_PASS_TREE, H2_LOCKDEBUG=1 (or an H2_KO built with it), and H2_FAIL_STAMP two changes" >&2
	exit 2
fi
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

# The run's own report is kept beside the klog it copies off at the end,
# under one stamp, so the numbers a record cites live where the images do.
# MEASURED 2026-10-19: the reports of twenty-five runs, written to /tmp by
# the launcher's redirect, were lost to a host reboot; the klogs, kept here
# by the script itself, were not. A fifo and tee keep the launcher's
# redirect working as before.
STAMP=$(date +%Y%m%d-%H%M%S)
mkfifo "$W/report" || exit 2
tee "$FIXDIR/cluster-run-$STAMP.log" < "$W/report" &
exec > "$W/report" 2>&1
echo "  kept  this report beside the images as cluster-run-$STAMP.log"
# The build the run read, named in its report: two pass timing runs
# began before the commit of the source they built and kept no hash, so
# their identity rested on the session's order. The harness is copied
# beside the report, since the frozen script/.run-*.sh copies are reused.
# A module given by H2_KO is named by its own hash, since HEAD is not its
# source.
git diff --quiet HEAD -- src/ 2>/dev/null; dirty=$?
if [ -n "${H2_KO:-}" ]; then
	ko="$H2_KO sha256=$(sha256sum < "$H2_KO" 2>/dev/null | cut -c1-16)"
else
	ko=built
fi
echo "  raw   build head=$(git rev-parse --short=7 HEAD 2>/dev/null) src-dirty=$dirty ko=$ko harness=$(sha256sum < "$0" | cut -c1-16)"
cp "$0" "$FIXDIR/cluster-run-$STAMP.sh"

if [ -n "${H2_KO:-}" ]; then
	[ -f "$H2_KO" ] || { echo "cluster: COULD-NOT-RUN: no module at H2_KO=$H2_KO" >&2; exit 2; }
	KO=$H2_KO
else
	make -s clean >/dev/null 2>&1
	if [ "$LOCKDEBUG" = 1 ]; then
		HAMMER2_LOCKDEBUG=1 make -s KDIR="$KDIR" >/dev/null 2>&1
	else
		make -s KDIR="$KDIR" >/dev/null 2>&1
	fi || { echo "cluster: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
	KO=src/sys/fs/hammer2/hammer2.ko
fi

# What the kernel tree configures against what the module actually carries.
# grep -c prints its count and exits 1 on no match, so the count is kept and
# the status discarded.
command -v nm >/dev/null 2>&1 || {
	echo "cluster: COULD-NOT-RUN: no nm, so the module's instrumentation cannot be read" >&2; exit 2; }
# An unreadable .config read as no KASAN and no kmemleak, and skipped both
# readings.
[ -r "$KDIR/.config" ] || {
	echo "cluster: COULD-NOT-RUN: $KDIR/.config is not readable, so what the tree configures is unknown" >&2; exit 2; }
want_asan=$(sed -n 's/^CONFIG_KASAN=//p' "$KDIR/.config")
have_asan=$(nm -u "$KO" 2>/dev/null | grep -c '__asan' || true)
have_ubsan=$(nm -u "$KO" 2>/dev/null | grep -c '__ubsan' || true)
# The release tree builds without kmemleak, and the tree arm's timing is
# read there; a refused scan is a note only where the tree says it is not
# set, and fails wherever the tree configures it or says nothing.
want_kmemleak=$(sed -n 's/^CONFIG_DEBUG_KMEMLEAK=//p; s/^# CONFIG_DEBUG_KMEMLEAK is not set$/n/p' "$KDIR/.config")

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
	truncate -s $IMGSIZE "$img" && "$NEWFS" -L ROOT "$img" >/dev/null 2>&1 || {
		echo "cluster: COULD-NOT-RUN: newfs_hammer2 failed on $img" >&2; exit 2; }
done
# Under H2_CRASH=1 the guest is destroyed and restarted mid-run, and a disk
# attached live alone does not survive that, so both forms are given.
if [ "$state" = running ] && [ "${H2_CRASH:-0}" = 1 ]; then how=--persistent
elif [ "$state" = running ]; then how=--live; else how=--config; fi
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
# One lockdep report turns lockdep off until the next boot, and a run
# on that boot reads "no report" with nothing checking.
dl=$(ssh -o BatchMode=yes "$GUEST_SSH" "awk '/debug_locks:/ {print \$2}' /proc/lockdep_stats 2>/dev/null")
[ "$dl" = 0 ] && {
	echo "cluster: COULD-NOT-RUN: lockdep is off on $GUEST since an earlier report; boot it again" >&2; exit 2; }

cat > "$W/tail.sh" <<'TAIL'
# The shared tail of the guest half and, under H2_CRASH=1, of its second half
# after the restart: the settle wait on the resumed thread and the readings
# that close a run. Sourced by both, so one definition serves two scripts.
# The settle bound is H2_RESUME_SECS, 900 by default since the resumed thread
# copies the backlog's remainder at the thread's own rate (measured about
# 15 ms a file on the debug kernel).
settle_wait() {
	c0=$(passes CL)
	# The resume has to be given until the thread stops making progress, not a
	# fixed pass count. MEASURED 2026-10-14: a pass handles ONE deferred inode when
	# its local scan is empty (filekeys iters 2 exit 1, acted +1), and the failing
	# run's log shows 58 such passes in 70 ms walking inodes 0x438 down to 0x400,
	# each stamping one. Two passes therefore drains two inodes of a backlog that
	# can be hundreds, and the run then measured a race rather than convergence.
	# The wait below is for the update-inode count to stop advancing across a
	# settle window, bounded, and the observed convergence time is printed.
	# The quiet window alone is not settling: a pass that copies nothing prints
	# no update, so a kernel slow enough that the resumed thread's first pass
	# over the tree outlasts the window read "settled 10 s after 0 updates" and
	# 0 passes. MEASURED 2026-10-18 on h2kasan-rc5, where a pass over 40000
	# inodes takes longer than the window. The wait ends on a quiet window
	# only once two passes have completed, so the two-pass check below reads
	# a wait and not a race, and a thread that never ran cannot read settled.
	u0=$(klog 'syncthr: update inode')
	n=0; last=-1; still=0
	while [ $n -lt ${H2_RESUME_SECS:-900} ]; do
		u=$(klog 'syncthr: update inode')
		if [ "$u" = "$last" ]; then
			still=$(( still + 1 ))
		else
			still=0
			last=$u
		fi
		# And only between passes: a verify round prints no update, so on
		# the KASAN kernel a round over 20000 entries outlasted the window
		# and the target was listed, and the idle window read, while the
		# pass that would delete it was still open. A pass is open while
		# its line has no verdict.
		[ "$still" -ge 10 ] && [ $(( $(passes CL) - c0 )) -ge 2 ] &&
		    [ "$(klog 'syncsnap: pass clindex')" = "$(( $(klog 'syncsnap: verified clindex') + $(klog 'syncsnap: newer clindex') + $(klog 'syncsnap: unverified clindex') + $(klog 'syncsnap: interrupted clindex') ))" ] && break
		sleep 1; n=$((n + 1))
	done
	echo "resume-converge-seconds $n"
	echo "resume-updates $(( $(klog 'syncthr: update inode') - u0 ))"
	echo "resume-settled $still"
	echo "resume-seconds $n"
	echo "resume-passes $(( $(passes CL) - c0 ))"
	echo "resume-errors $(klog 'hammer2_sync_slaves: error')"
	echo "resume-tgt-kept $(klog 'syncsnap: target .* kept')"
	echo "resume-tgt-listed $(hammer2 -s /mnt/h2s pfs-list 2>/dev/null | grep -c 'h2sync-tgt')"
	echo "mark-files $(ls /mnt/h2c/mark | wc -l)"
}
finish() {
	# The snapshot pass's own records, read once the resume has settled. The
	# idle window runs until two idle lines follow the last idle stamp,
	# bounded at 60 s: an idle master must cost idle passes and no snapshot
	# pass, and the last idle line carries both root tids, which must agree
	# for hammer2_cluster_check() to serve the slave; how many live passes it
	# took to get there is the idlestamp count, printed and not asserted. The
	# stamp is the live pass over the root, one level, and a fixed window of
	# 12 s begun before it read one idle line and the tids it had not yet
	# written: MEASURED 2026-10-19 on the KASAN kernel, 9.3 s for the stamp
	# over 20107 root entries after the resume, 0.4 s at most on the debug
	# kernel.
	p1=$(klog 'syncsnap: pass clindex'); l1=$(wc -l < $K); n=0
	idles() { tail -n +$((l1 + 1)) $K | awk '/syncsnap: idlestamp/ { n = 0 } /syncsnap: idle clindex/ { n++ } END { print n + 0 }'; }
	until [ "$(idles)" -ge 2 ] || [ $n -ge 60 ]; do sleep 1; n=$((n + 1)); done
	echo "idle-window-seconds $n"
	echo "idle-window-passes $(( $(klog 'syncsnap: pass clindex') - p1 ))"
	echo "idle-window-idles $(idles)"
	echo "snap-passes $(klog 'syncsnap: pass clindex')"
	echo "snap-idle $(klog 'syncsnap: idle clindex')"
	echo "snap-idlestamp $(klog 'syncsnap: idlestamp')"
	echo "snap-verified $(klog 'syncsnap: verified')"
	echo "snap-unverified $(klog 'syncsnap: unverified')"
	echo "snap-newer $(klog 'syncsnap: newer')"
	echo "snap-interrupted $(klog 'syncsnap: interrupted')"
	echo "snap-target-taken $(klog 'syncsnap: target .* taken')"
	echo "snap-target-kept $(klog 'syncsnap: target .* kept')"
	echo "snap-target-errors $(klog 'syncsnap: target .* error')"
	echo "snap-verify-rounds $(grep 'syncsnap: verified' $K | sed 's/.*rounds //' | sort -n | tail -1)"
	echo "snap-last-idle $(grep 'syncsnap: idle clindex' $K | tail -1 | sed 's/.*master //')"
	# The master device's free blocks at the end and after two bulkfree
	# scans (a delete frees nothing until the second, script/bulkfree.sh),
	# beside the count at the first mount: every snapshot pass creates and
	# deletes a PFS root, garbage until a scan, and the run that keeps the
	# live pass (H2_SYNC_SNAPSHOT=0) over the same work is the control the
	# difference is read against. The scans run with the thread up, which
	# is the interaction the thread's try-lock on hammer2_mntlk is for.
	echo "space-end $(stat -f -c %f /mnt/h2m)"
	for bf in 1 2; do hammer2 -s /mnt/h2m bulkfree /mnt/h2m > /tmp/h2bf.$bf 2>&1; echo "space-bulkfree-rc-$bf $?"; sync; done
	echo "space-after-bulkfree $(stat -f -c %f /mnt/h2m)"
	timeout 60 umount /mnt/h2c; timeout 60 umount /mnt/h2s; timeout 60 umount /mnt/h2m
	echo "cluster-umount ok"
	echo "cluster-threads-after $(ps -eo comm | grep -c '^h2nod')"
	# The scrap print is rate-limited, so the lines under-read it: one run
	# printed 20 and "22201 callbacks suppressed" (2026-10-18). Both counted.
	echo "scrapped $(( $(grep -c 'unmount_scrap: scrapping' $K) + $(grep 'unmount_scrap: [0-9]* callbacks suppressed' $K | awk '{s += $(NF-2)} END {print s + 0}') ))"
	# The guest's virtual GPU times out waiting for a vblank under a heavy
	# write (drm_vblank.c and drm_atomic_helper.c WARNINGs, two in one run on
	# 2026-10-18), which is the guest's and not the port's. Those lines name
	# drivers/gpu/drm/ and are counted apart, so they neither hide a report of
	# the port's nor fail the run on their own.
	echo "kernel-warnings $(grep -E 'WARNING|BUG:|UBSAN:|circular locking|possible recursive' $K | grep -vc 'drivers/gpu/drm/')"
	echo "gpu-warnings $(grep -c 'WARNING.*drivers/gpu/drm/' $K)"
	# Before rmmod, so the report's %pS resolves the module's own symbols. The
	# scan used to follow rmmod, where those symbols print as addresses and only
	# a process named hammer2 could match, and to run without the wait the
	# scanner's age rule needs (kmemleak.c MSECS_MIN_AGE, 5000 ms).
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
	timeout 120 rmmod hammer2 && echo "rmmod ok"
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
	sync
	kill $KPID 2>/dev/null
}
TAIL

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
# A follower from a run that exited early is still writing, and two of them
# write the ring twice into one file, which doubles every count below and
# turns the deltas negative: measured 2026-10-16, three strays from three
# refused runs and a klog holding the ring four times over. Any earlier one
# is stopped first, and this one goes when the shell does.
pkill -x dmesg 2>/dev/null; sleep 0.2
dmesg -w > $K 2>&1 &
KPID=$!
trap 'kill $KPID 2>/dev/null' EXIT
echo "mounts-before $(( $(mount 2>/dev/null | grep -c ' type hammer2') ))"
{ echo scan > /sys/kernel/debug/kmemleak && echo scan > /sys/kernel/debug/kmemleak && echo clear > /sys/kernel/debug/kmemleak; } 2>/dev/null; echo "kmemleak-cleared"	# an earlier run's leaks are its own
insmod /tmp/hammer2.ko debug=$H2DEBUG sync_snapshot=$H2SNAP || { echo "insmod failed"; exit 1; }
echo "sync-snapshot $(cat /sys/module/hammer2/parameters/sync_snapshot)"
mkdir -p /mnt/h2m /mnt/h2s /mnt/h2c /mnt/h2l
klog() { grep -c "$1" $K; }
# A mount the guest cannot drop leaves its volume held, and the next unmount
# then blocks instead of returning. Counted on every phase so a wedged guest
# is visible in the probe output rather than only in the final failure.
mounts() { mount 2>/dev/null | grep -c ' type hammer2'; }
# A pass is a scan line, or an idle line the snapshot pass prints in place
# of one when the master has not changed; an idle pass that stamps the root
# prints both and is counted once. MEASURED 2026-10-18: the resume wait read
# 0 passes in 300 s from the scan lines alone against a thread that had
# converged and was passing idle every five seconds.
passes() { echo $(( $(klog "sync_slaves pfs $1") + $(klog 'syncsnap: idle clindex') - $(klog 'syncsnap: idlestamp') )); }
. /tmp/h2cluster-tail.sh

# 7. H2_PASS_TREE=N, in place of every phase below: one snapshot-form pass
# over a tree of N files with one file changed, timed. The change reaches
# the slave only through the thread in phase 4b's shape: both mounts down,
# the master written alone, the slave's device returned to the unmounted
# cluster pmp, whose new thread's first pass carries it. A new thread's cut
# is 0, which decides only whether a key the slave holds and the snapshot
# lacks is kept, and here there is none. bracket() reads the first pass
# that ends after line $1 of the log: the milliseconds from its begin to
# its pass line (the stale delete, the snapshot and the target with its
# sync), from there to its verdict (the verify rounds), and from the
# verdict to its end (the snapshot's delete), then the verdict, the rounds
# and the largest root scan's iteration count. A begin that a busy lock or
# a refused snapshot closes without an end is passed over, so the reading
# is the last begin before the first end.
bracket() {
	tail -n +$(($1 + 1)) $K | awk '
	{ t = $0; sub(/^\[ */, "", t); sub(/\].*/, "", t) }
	/syncsnap: begin clindex/ { b = t; p = ""; v = ""; w = "none"; r = 0; mx = 0; next }
	b == "" { next }
	/syncsnap: pass clindex/ && p == "" { p = t }
	/^\[[^]]*\] filekeys / { for (i = 1; i < NF; i++) if ($i == "iters" && $(i + 1) + 0 > mx) mx = $(i + 1) + 0 }
	/syncsnap: (verified|newer|unverified|interrupted) clindex/ && v == "" {
		v = t; w = $0; sub(/.*syncsnap: /, "", w); sub(/ .*/, "", w)
		r = $0; sub(/.* rounds /, "", r); sub(/ .*/, "", r) }
	/syncsnap: end clindex/ {
		if (p == "") p = t; if (v == "") v = t
		printf "%d %d %d %d %s %s %d\n", (p - b) * 1000, (v - p) * 1000, (t - v) * 1000, (t - b) * 1000, w, r, mx
		found = 1; exit }
	END { if (!found) print "none" }'
}
if [ "$TREE" != 0 ]; then
	mount -t hammer2 /dev/vdb@ROOT /mnt/h2m || { echo "mount failed"; exit 1; }
	echo "space-start $(stat -f -c %f /mnt/h2m)"
	hammer2 -s /mnt/h2m pfs-create CL >/dev/null 2>&1 || { echo "master pfs-create failed"; exit 1; }
	clid=$(hammer2 -s /mnt/h2m pfs-list | awk '$3=="CL"{print $2}')
	mount -t hammer2 /dev/vdb@CL /mnt/h2c || exit 1
	mount -t hammer2 /dev/vdc@ROOT /mnt/h2s || exit 1
	hammer2 -s /mnt/h2s -t SLAVE -u "$clid" pfs-create CL >/dev/null 2>&1 || { echo "slave pfs-create failed"; exit 1; }
	echo "cluster-thread $(ps -eo comm | grep -c '^h2nod-CL')"
	# The tree, one shell per writer, each taking the directories congruent
	# to its number, as million-tree.sh does. Each file is past the 512 bytes
	# an inode embeds, so its content has a data block the fingerprint
	# compares by xxh; embedded, only its size would be compared.
	t0=$(date +%s)
	mkdir /mnt/h2c/t
	w=0; wp=
	while [ $w -lt $TREE_WRITERS ]; do
		( d=$w
		while [ $d -lt $TREE_FAN ]; do
			mkdir /mnt/h2c/t/d$d; f=0
			while [ $f -lt $(( TREE / TREE_FAN )) ]; do printf '%s.%s %0600d\n' $d $f 0 > /mnt/h2c/t/d$d/f$f; f=$((f + 1)); done
			d=$((d + TREE_WRITERS))
		done ) &
		wp="$wp $!"; w=$((w + 1))
	done
	# Only the writers: a bare wait also waits on the dmesg -w at KPID.
	wait $wp
	sync
	echo "tree-write-seconds $(( $(date +%s) - t0 ))"
	echo "tree-files $(find /mnt/h2c/t -type f | wc -l)"
	# Settled once two idle lines follow the last idle stamp, as finish()
	# reads the idle window, bounded by H2_TREE_SECS.
	l1=$(wc -l < $K); n=0
	idles() { tail -n +$((l1 + 1)) $K | awk '/syncsnap: idlestamp/ { n = 0 } /syncsnap: idle clindex/ { n++ } END { print n + 0 }'; }
	until [ "$(idles)" -ge 2 ] || [ $n -ge "$TREE_SECS" ]; do sleep 1; n=$((n + 1)); done
	echo "tree-settle-seconds $n"
	echo "tree-settle-idles $(idles)"
	echo "tree-snap-passes $(klog 'syncsnap: end clindex')"
	echo "kept-absent $(klog 'syncsnap: kept absent')"
	# A sweep destroy whose source last key sorts at or above the
	# destroyed local key is the same skip seen from the other side: the
	# source had not ended below that key, so the key was passed over, not
	# swept. Equal is the shape measured, the source holding the key.
	echo "kept-absent-skips $(awk '
	/filekeys |START_SCAN|sync_slaves |syncsnap: pass |syncthr: update inode/ { pf = "" }
	/syncsnap: kept absent / {
		l = $0; sub(/.*kept absent /, "", l); sub(/\/.*/, "", l)
		f = $0; sub(/.* focus /, "", f)
		if (pf != "" && f != pf && ("x" l) < ("x" pf)) s++
		pf = f }
	/destroy focus 0000000000000000\/-1 local .* last / {
		l = $0; sub(/.* local /, "", l); sub(/\/.*/, "", l)
		a = $0; sub(/.* last /, "", a)
		if (("x" a) >= ("x" l)) s++ }
	END { print s + 0 }' $K)"
	c=1
	while [ $c -le "$PASS_CHANGES" ]; do
		timeout 600 umount /mnt/h2c; timeout 600 umount /mnt/h2s
		echo "change-$c-threads-down $(ps -eo comm | grep -c '^h2nod-CL')"
		mount -t hammer2 /dev/vdb@CL /mnt/h2c || { echo "master-alone mount failed"; exit 1; }
		# The same length as the file it replaces, so only the block's xxh
		# tells the two apart.
		printf '%s.%s %0600d\n' $c $c $c > /mnt/h2c/t/d$c/f$c
		sync
		timeout 600 umount /mnt/h2c
		l0=$(wc -l < $K); e0=$(klog 'syncsnap: end clindex')
		# The arms are set before the slave's device returns, so the knob
		# is read at the first pass of the thread it starts.
		knob=
		[ $c = 1 ] && [ "$H2_FORCE_RESCAN" = 1 ] && knob=sync_force_rescan
		[ $c = 2 ] && [ "$H2_FAIL_STAMP" = 1 ] && knob=sync_fail_stamp
		if [ -n "$knob" ]; then
			[ -e /sys/module/hammer2/parameters/$knob ] || {
				echo "cluster: COULD-NOT-RUN: no $knob knob; the module needs H2_LOCKDEBUG=1" >&2; exit 2; }
			echo 1 > /sys/module/hammer2/parameters/$knob
		fi
		mount -t hammer2 /dev/vdc@ROOT /mnt/h2s || exit 1
		n=0
		until [ "$(klog 'syncsnap: end clindex')" -gt "$e0" ] || [ $n -ge "$TREE_SECS" ]; do sleep 1; n=$((n + 1)); done
		echo "change-$c-wait-seconds $n"
		echo "change-$c-pass $(bracket $l0)"
		[ -n "$knob" ] && echo "change-$c-knob-left $(cat /sys/module/hammer2/parameters/$knob)"
		echo "change-$c-rescan-all $(tail -n +$((l0 + 1)) $K | grep -c 'syncthr: rescan all')"
		echo "change-$c-root-scans $(tail -n +$((l0 + 1)) $K | awk '/syncsnap: verify clindex .* round 1 / { exit } /sync_slaves error/ { n++ } END { print n + 0 }')"
		echo "change-$c-stamp-failed $(tail -n +$((l0 + 1)) $K | grep -c 'root stamp failed on demand')"
		c=$((c + 1))
	done
	echo "tree-errors $(klog 'hammer2_sync_slaves: error')"
	mount -t hammer2 /dev/vdb@CL /mnt/h2c || { echo "resume mount failed"; exit 1; }
	finish
	exit 0
fi

# 1. A lone SLAVE: start, pass, stop.
timeout 30 mount -t hammer2 /dev/vdb@ROOT /mnt/h2m || { echo "mount failed"; exit 1; }
echo "space-start $(stat -f -c %f /mnt/h2m)"
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
# 2b. A copy that fails part-way through the pass, H2_FAULT=N (default 0,
# phase absent). The thread's first pass after the SLAVE is created is the
# one copy this harness drives through the sync thread: once the slave's
# element has joined the master's pmp the frontend writes every later file
# to it directly, whether or not the slave's ROOT is mounted, which two runs
# of this phase placed after phase 3 measured (0 updates after phase 2,
# with the slave unmounted for the write and without). So the freemap
# allocator is told to refuse the next N allocations HERE, before the
# pfs-create that starts the thread: the first allocations it sees are the
# thread's inserts, which fail through the path a full volume fails them
# on, and the knob clears itself on the Nth refusal. Needs the module built
# with H2_LOCKDEBUG=1, where the knob exists.
#
# What is read: `fault-failed` is the module's own count of actions that
# returned non-zero, and a zero there means the window never reached a copy,
# so the convergence read at the end was never in question and the phase
# fails rather than passes. If the window has not closed when the wait ends
# the knob is disarmed here, or its refusals land on whatever allocates
# next. Whether the failed keys are copied by a later pass is the end-of-run
# fingerprint. The fail-open this phase is for: before 2026-10-16 the scan
# discarded each key's error and stamped the inode root's modify_tid
# regardless, so a refused copy compared equal on every later pass and was
# never retried; that reads here as `fault-failed` above zero and the slave
# short by those keys at the end, with no pass reporting an error.
fcount() { grep 'filekeys' $K | tail -1 | sed -n 's/.* failed \([0-9]*\) .*/\1/p'; }
if [ "${H2_FAULT:-0}" != 0 ]; then
	[ -e /sys/module/hammer2/parameters/fail_alloc_count ] || {
		echo "cluster: COULD-NOT-RUN: H2_FAULT needs the fail_alloc_count knob, which only a module built with H2_LOCKDEBUG=1 has" >&2; exit 2; }
	echo "h2probe: fault phase begin" > /dev/kmsg
	echo "$H2_FAULT" > /sys/module/hammer2/parameters/fail_alloc_count
	echo 1 > /sys/module/hammer2/parameters/fail_alloc_after
fi
hammer2 -s /mnt/h2s -t SLAVE -u "$clid" pfs-create CL >/dev/null 2>&1 || { echo "slave pfs-create failed"; exit 1; }
echo "cluster-thread $(ps -eo comm | grep -c '^h2nod-CL')"
if [ "${H2_FAULT:-0}" != 0 ]; then
	n=0
	while [ "$(cat /sys/module/hammer2/parameters/fail_alloc_after)" != 0 ] && [ $n -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
	echo "fault-window-tenths $n"
	echo "fault-count-left $(cat /sys/module/hammer2/parameters/fail_alloc_count)"
	echo 0 > /sys/module/hammer2/parameters/fail_alloc_after
	echo 0 > /sys/module/hammer2/parameters/fail_alloc_count
fi
sleep 30
echo "cluster-passes $(passes CL)"
echo "cluster-updates $(klog 'syncthr: update inode')"
if [ "${H2_FAULT:-0}" != 0 ]; then
	# Until the copies settle, the same settle the resume uses.
	n=0; last=-1; still=0
	while [ $n -lt ${H2_RESUME_SECS:-300} ]; do
		u=$(klog 'syncthr: update inode')
		if [ "$u" = "$last" ]; then still=$(( still + 1 )); else still=0; last=$u; fi
		[ "$still" -ge 15 ] && break
		sleep 1; n=$((n + 1))
	done
	f=$(fcount)
	echo "fault-failed ${f:-0}"
	echo "fault-settle-seconds $n"
	echo "fault-errors $(klog 'hammer2_sync_slaves: error')"
	echo "h2probe: fault phase end" > /dev/kmsg
fi

# 2c. The slave goes stale behind the master's back, so the thread's REPLACE
# and DESTROY arms run. A first pass is all inserts, and every later write
# reaches the slave element by the frontend (2b above), so nothing else in
# this harness drives those two arms through hammer2_sync_slaves(). Five
# files are written while clustered so the slave holds them, then the cluster
# comes down, the MASTER is mounted alone (its own device only: /mnt/h2s must
# be unmounted too, or the slave's device stays known and its element stays
# in the pmp), the five are deleted and five others rewritten, and the slave's
# device comes back. Its element joining the pmp starts the thread, whose
# first pass then finds five keys the master lacks (destroy) and five whose
# modify_tid differs (replace). H2_FAULT2=N refuses the first N allocations
# that pass makes, armed before the device comes back, so the refusals land
# in those two arms rather than in inserts; the window and settle are 2b's.
# The counts are deltas of the module's own per-arm counters on the filekeys
# line; a zero delta means the arm never ran and the phase fails.
fieldc() { grep 'filekeys' $K | tail -1 | sed -n "s/.* $1 \([0-9]*\).*/\1/p"; }
i=0; while [ $i -lt 5 ]; do head -c $(( i * 3001 + 500 )) /dev/urandom > /mnt/h2c/set/d$i; i=$((i + 1)); done
sync
n=0; last=-1; still=0
while [ $n -lt 120 ]; do
	u=$(klog 'syncthr: update inode')
	if [ "$u" = "$last" ]; then still=$(( still + 1 )); else still=0; last=$u; fi
	[ "$still" -ge 10 ] && break
	sleep 1; n=$((n + 1))
done
r0=$(fieldc replaced); d0=$(fieldc destroyed); f0=$(fieldc failed); a0=$(fieldc acted)
rs0=$(fieldc rescan)
timeout 60 umount /mnt/h2c; timeout 60 umount /mnt/h2s
echo "diverge-threads-down $(ps -eo comm | grep -c '^h2nod-CL')"
mount -t hammer2 /dev/vdb@CL /mnt/h2c || { echo "master-alone mount failed"; exit 1; }
rm -f /mnt/h2c/set/d0 /mnt/h2c/set/d1 /mnt/h2c/set/d2 /mnt/h2c/set/d3 /mnt/h2c/set/d4
i=30; while [ $i -lt 35 ]; do head -c $(( i * 2003 + 777 )) /dev/urandom > /mnt/h2c/set/f$i; i=$((i + 1)); done
sync
timeout 60 umount /mnt/h2c
if [ "${H2_FAULT2:-0}" != 0 ]; then
	[ -e /sys/module/hammer2/parameters/fail_alloc_count ] || {
		echo "cluster: COULD-NOT-RUN: H2_FAULT2 needs the fail_alloc_count knob, which only a module built with H2_LOCKDEBUG=1 has" >&2; exit 2; }
	echo "h2probe: diverge fault begin" > /dev/kmsg
	echo "$H2_FAULT2" > /sys/module/hammer2/parameters/fail_alloc_count
	echo 1 > /sys/module/hammer2/parameters/fail_alloc_after
fi
p0=$(passes CL)
mount -t hammer2 /dev/vdc@ROOT /mnt/h2s || exit 1
echo "diverge-threads-up $(ps -eo comm | grep -c '^h2nod-CL')"
if [ "${H2_FAULT2:-0}" != 0 ]; then
	n=0
	while [ "$(cat /sys/module/hammer2/parameters/fail_alloc_after)" != 0 ] && [ $n -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
	echo "diverge-window-tenths $n"
	echo "diverge-count-left $(cat /sys/module/hammer2/parameters/fail_alloc_count)"
	echo 0 > /sys/module/hammer2/parameters/fail_alloc_after
	echo 0 > /sys/module/hammer2/parameters/fail_alloc_count
fi
n=0; last=-1; still=0
while [ $n -lt ${H2_RESUME_SECS:-300} ]; do
	u=$(fieldc acted)
	if [ "$u" = "$last" ]; then still=$(( still + 1 )); else still=0; last=$u; fi
	[ "$still" -ge 15 ] && [ $(( $(passes CL) - p0 )) -ge 2 ] && break
	sleep 1; n=$((n + 1))
done
echo "diverge-settle-seconds $n"
echo "diverge-passes $(( $(passes CL) - p0 ))"
echo "diverge-replaced $(( $(fieldc replaced) - ${r0:-0} ))"
echo "diverge-destroyed $(( $(fieldc destroyed) - ${d0:-0} ))"
echo "diverge-failed $(( $(fieldc failed) - ${f0:-0} ))"
echo "diverge-acted $(( $(fieldc acted) - ${a0:-0} ))"
echo "diverge-rescanned $(( $(fieldc rescan) - ${rs0:-0} ))"
echo "diverge-errors $(klog 'hammer2_sync_slaves: error')"
[ "${H2_FAULT2:-0}" != 0 ] && echo "h2probe: diverge fault end" > /dev/kmsg
mount -t hammer2 /dev/vdb@CL /mnt/h2c || exit 1

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
# 4b. A backlog the thread must copy: the one pass of the run long enough to
# mutate the master inside (3b), to interrupt (4c) and, under H2_CRASH=1, to
# crash (6). MEASURED 2026-10-18: with the cluster mounted the slave's device
# keeps a mount count from the cluster (hammer2_vfsops.c, the mount's and
# hammer2_pfsalloc()'s increments), so `umount /mnt/h2s` alone leaves the
# slave element in the cluster, the frontend writes the backlog to it, and the
# thread's pass after the remount is a root scan of 40042 inodes that acts on
# nothing (iters 40042, acted 0, 4.8 s; 70 inserts over the whole run, 64 in
# the step-2 run): the interruption of every run up to then landed inside
# such a scan. Phase 2c's topology is what makes the element leave: both
# mounts down, the master written alone, the slave's device returned to an
# UNMOUNTED cluster pmp, whose thread then copies at its own rate; `umount
# /mnt/h2s` in that state is a device teardown, which freezes the thread
# between deferrals: a real stop.
u1=$(klog 'syncthr: update inode')
timeout 60 umount /mnt/h2c; timeout 60 umount /mnt/h2s
echo "backlog-threads-down $(ps -eo comm | grep -c '^h2nod-CL')"
mount -t hammer2 /dev/vdb@CL /mnt/h2c || { echo "backlog master-alone mount failed"; exit 1; }
echo "h2probe: bigdir2 write start" > /dev/kmsg
mkdir /mnt/h2c/bigdir2
# The marked set the mutation below works on is created between the two
# halves of the backlog: inode numbers are given in creation order and the
# root scan walks them in that order, so the pass reaches the marked set
# after the first half, long after the mutation, and the stop below lands
# in the second half, after the pass has read the marked set.
i=0; while [ $i -lt $(( NBIG2 / 2 )) ]; do head -c 4096 /dev/urandom > /mnt/h2c/bigdir2/q$i; i=$((i + 1)); done
mkdir /mnt/h2c/mark
i=0; while [ $i -lt 20 ]; do head -c $(( 700 + i * 37 )) /dev/urandom > /mnt/h2c/mark/m$i; i=$((i + 1)); done
i=$(( NBIG2 / 2 )); while [ $i -lt $NBIG2 ]; do head -c 4096 /dev/urandom > /mnt/h2c/bigdir2/q$i; i=$((i + 1)); done
sync
echo "h2probe: bigdir2 write end" > /dev/kmsg
timeout 60 umount /mnt/h2c
verdicts() { echo $(( $(klog 'syncsnap: verified') + $(klog 'syncsnap: newer') + $(klog 'syncsnap: unverified') )); }
copied() { grep -c 'syncthr: update inode' $K; }
p0=$(passes CL); v0=$(verdicts); ins0=$(fieldc 'n>0'); k0=$(fieldc kept); ri0=$(klog 'syncsnap: reinsert'); nd0=$(klog 'syncsnap: newer inode')
# Set before the slave's device returns, so the knob is read by the copy.
if [ "$H2_COLLAPSE" != 0 ]; then
	[ -e /sys/module/hammer2/parameters/sync_collapse_parent ] || {
		echo "cluster: COULD-NOT-RUN: no sync_collapse_parent knob; the module needs H2_LOCKDEBUG=1" >&2; exit 2; }
	echo "$H2_COLLAPSE" > /sys/module/hammer2/parameters/sync_collapse_parent
fi
mount -t hammer2 /dev/vdc@ROOT /mnt/h2s || exit 1
echo "backlog-threads-up $(ps -eo comm | grep -c '^h2nod-CL')"
# The copy has begun once its update lines pass the baseline by more than a
# root stamp or two: each inode the thread inserts and recurses into is
# stamped and printed, so here the count is the copy's own, unlike the
# frontend-written directory above.
n=0
while [ $n -lt 1200 ]; do
	[ "$(copied)" -gt "$(( u1 + 5 ))" ] && break
	sleep 0.1; n=$((n + 1))
done
echo "interrupt-begun $([ "$(copied)" -gt "$(( u1 + 5 ))" ]; echo $?)"
echo "interrupt-bracket-open $([ $(( $(klog 'sync_slaves pfs CL') - p0 )) -ge 1 ]; echo $?)"
# The source snapshot is a PFS on the master's device while the pass runs
# and the target one a PFS on the slave's, each listed through its device's
# ROOT mount: the mechanism read as a PFS, not inferred. H2_SYNC_SNAPSHOT=0
# must read 0 and 0 here.
echo "pass-src-listed $(hammer2 -s /mnt/h2m pfs-list 2>/dev/null | grep -c 'h2sync-src')"
echo "pass-tgt-listed $(hammer2 -s /mnt/h2s pfs-list 2>/dev/null | grep -c 'h2sync-tgt')"
# 6. Crash recovery, under H2_CRASH=1 from the host. The copy is left running
# and the host cuts the guest's power once the copy has gone H2_CRASH_DEPTH
# updates past its start, which no command on the guest can do; the session
# ends with the guest. What the cut left on both media is read by the host
# while the guest is down and by the guest's second half after the restart.
# Nothing is synced first: the pass's copies are in memory until its end,
# and that is the state a cut must leave.
if [ "${H2_CRASH:-0}" = 1 ]; then
	n=0
	while [ $n -lt 6000 ]; do
		[ $(( $(copied) - u1 )) -ge "${H2_CRASH_DEPTH:-2000}" ] && break
		[ "$(verdicts)" != "$v0" ] && break
		sleep 0.05; n=$((n + 1))
	done
	echo "crash-copied $(( $(copied) - u1 ))"
	echo "crash-in-pass $([ "$(verdicts)" = "$v0" ]; echo $?)"
	echo "crash-last-target $(awk '/syncsnap: target/ { v = $NF } END { print v }' $K)"
	echo "crash-armed"
	sleep 600
	exit 0
fi
# 3b. Source mutation during convergence, and a media flush during it. The
# cluster is mounted while the pass runs, which brings the frontend to both
# elements: ten of the marked files are deleted and ten new ones written,
# then the media flushed twice. The snapshot the pass reads predates all of
# it. The ten new files are on the slave (the frontend put them there) and
# not in the snapshot, so the pass keeps them as newer and ends `newer`; the
# ten deleted are in the snapshot and not on the slave, and what the pass
# does with those is the `reinserts` and `newer-inodes` readings below. The
# negative control is H2_SYNC_SNAPSHOT=0: the live pass sees the mutation
# and keeps nothing.
timeout 30 mount -t hammer2 /dev/vdb@CL /mnt/h2c; mrc=$?
echo "mutate-mount-rc $mrc"
echo "mutate-in-pass $([ "$(verdicts)" = "$v0" ]; echo $?)"
rm -f /mnt/h2c/mark/m0 /mnt/h2c/mark/m1 /mnt/h2c/mark/m2 /mnt/h2c/mark/m3 /mnt/h2c/mark/m4 /mnt/h2c/mark/m5 /mnt/h2c/mark/m6 /mnt/h2c/mark/m7 /mnt/h2c/mark/m8 /mnt/h2c/mark/m9
i=0; while [ $i -lt 10 ]; do head -c $(( 900 + i * 41 )) /dev/urandom > /mnt/h2c/mark/new$i; i=$((i + 1)); done
sync; sleep 1; sync
echo "mutate-updates $(( $(copied) - u1 ))"
# 4c. The stop: once the copy has gone H2_STOP_DEPTH updates from its start,
# half the backlog and a thousand more by default, so the marked set has been
# read, or the pass has ended, the cluster is unmounted (the thread survives
# that, measured) and then the slave's device, whose count reaches zero now
# and tears it down. The stop landed inside the pass if no verdict has
# printed since the device came up. MEASURED 2026-10-18: a depth forwarded
# as 0 stopped the pass 0 updates after the mutation, before it reached the
# marked set, and the mutation's readings were of the next snapshot.
STOP_DEPTH=${H2_STOP_DEPTH:-0}
[ "$STOP_DEPTH" = 0 ] && STOP_DEPTH=$(( NBIG2 / 2 + 1000 ))
n=0
while [ $n -lt "${H2_STOP_DEPTH_MS:-240000}" ]; do
	[ $(( $(copied) - u1 )) -ge "$STOP_DEPTH" ] && break
	[ "$(verdicts)" != "$v0" ] && break
	sleep 0.05; n=$((n + 1))
done
echo "interrupt-stop-copied $(( $(copied) - u1 )) wanted $STOP_DEPTH"
echo "interrupt-in-pass $([ "$(verdicts)" = "$v0" ]; echo $?)"
echo "interrupt-threads-before $(ps -eo comm | grep -c '^h2nod-CL')"
timeout 60 umount /mnt/h2c
t0=$(date +%s%N); timeout 180 umount /mnt/h2s; urc=$?; t1=$(date +%s%N)
echo "interrupt-umount-rc $urc"
echo "interrupt-umount-ms $(( (t1 - t0) / 1000000 ))"
echo "interrupt-copied $(( $(copied) - u1 ))"
echo "interrupt-threads $(ps -eo comm | grep -c '^h2nod-CL')"
echo "interrupt-didbreak $(klog didbreak)"
echo "interrupt-src-cleaned $(klog 'syncsnap: unmount deleted CL.h2sync-src error 0')"
# The target the interrupted pass meant to keep is on the slave's media, read
# on the device the teardown closed.
echo "interrupt-tgt-on-media $(hammer2 -v show /dev/vdc 2>/dev/null | grep -c 'filename "CL.h2sync-tgt"')"
# What the interrupted pass wrote of the marked set, read on the slave's media:
# the pass reached it after the mutation, from a snapshot taken before it.
# The frontend's writes could not land on the slave, which held no such
# directory then, so the slave's marked set is the snapshot's state (the
# ten deleted files present, the ten new ones absent) under
# H2_SYNC_SNAPSHOT=1, and the live master's under 0, which read the master
# as it was when the pass reached the set. Both inode and dirent lines carry
# the filename, so a present file reads as 2.
echo "interrupt-mark-old $(hammer2 -v show /dev/vdc 2>/dev/null | grep -c 'filename "m[0-9]"$')"
echo "interrupt-mark-new $(hammer2 -v show /dev/vdc 2>/dev/null | grep -c 'filename "new[0-9]"$')"
echo "mutate-kept $(( $(fieldc kept) - ${k0:-0} ))"
# The filekeys line is NOT one cumulative record: `acted`, `failed`, `last`
# and `kept` are file-scope atomics accumulated over the run, but `sweep` and
# `iters` are locals of hammer2_sync_slaves() reset on entry, so each line
# carries ONE pass's values and `tail -1` reports the LAST pass's sweep.
# MEASURED 2026-10-15: the destroying pass printed `sweep 127` on its own
# line and the last line `sweep 0`, and reading the tail put a sweep count
# of 0 into five records as a finding. Both readings are printed.
maxsweep() {	# the filekeys line carrying the largest `sweep`, or empty
	sed -n 's/^\[[^]]*\] //p' "$1" | grep '^filekeys' | \
		awk 'BEGIN { m = -1 }
		     { for (i = 1; i <= NF; i++) if ($i == "sweep") s = $(i + 1) + 0
		       if (s > m) { m = s; line = $0 } }
		     END { if (line) print line }'
}
echo "interrupt-actions $(grep 'filekeys' $K | tail -1 | sed 's/^\[[^]]*\] //')"
echo "interrupt-sweep-max $(maxsweep $K)"
# 5. Resume: the slave's device returns, its thread starts, finds the target
# by name and copies the rest; the cluster is mounted on top for the run's
# end, which is the same mount-during-a-pass the mutation made.
mount -t hammer2 /dev/vdc@ROOT /mnt/h2s; drc=$?
echo "resume-device-rc $drc"
timeout 30 mount -t hammer2 /dev/vdb@CL /mnt/h2c; rrc=$?
echo "resume-remount-rc $rrc"
echo "resume-mounts $(mount 2>/dev/null | grep -c ' type hammer2')"
echo "resume-thread $(ps -eo comm | grep -c '^h2nod-CL')"
settle_wait
echo "backlog-inserts $(( $(fieldc 'n>0') - ${ins0:-0} ))"
echo "collapse-done $(klog 'syncsnap: collapse of .* on demand')"
echo "collapse-guard $(klog 'syncsnap: scan parent .* deleted')"
# The failures of the round the first such scan ended in, which must not
# verify: the next verify line after it.
echo "collapse-round-failed $(awk '/syncsnap: scan parent .* deleted/ { g = 1 } g && /syncsnap: verify clindex/ { sub(/.* failed /, ""); print $1 + 0; exit }' $K)"
[ "$H2_COLLAPSE" != 0 ] && echo "collapse-knob-left $(cat /sys/module/hammer2/parameters/sync_collapse_parent)"
echo "mutate-reinserts $(( $(klog 'syncsnap: reinsert') - ${ri0:-0} ))"
echo "mutate-newer-inodes $(( $(klog 'syncsnap: newer inode') - ${nd0:-0} ))"
finish
GUEST

cat > "$W/guestb.sh" <<'GUESTB'
set -u
# The second half of a crash run: the guest has restarted and holds nothing,
# and the kernel log before the cut is gone with it; the readings before the
# cut are the first half's own lines.
K=/tmp/h2cluster.klog
pkill -x dmesg 2>/dev/null; sleep 0.2
dmesg -C
dmesg -w > $K 2>&1 &
KPID=$!
trap 'kill $KPID 2>/dev/null' EXIT
{ echo scan > /sys/kernel/debug/kmemleak && echo scan > /sys/kernel/debug/kmemleak && echo clear > /sys/kernel/debug/kmemleak; } 2>/dev/null; echo "kmemleak-cleared"	# an earlier run's leaks are its own
insmod /tmp/hammer2.ko debug=$H2DEBUG sync_snapshot=$H2SNAP || { echo "insmod failed"; exit 1; }
klog() { grep -c "$1" $K; }
passes() { echo $(( $(klog "sync_slaves pfs $1") + $(klog 'syncsnap: idle clindex') - $(klog 'syncsnap: idlestamp') )); }
. /tmp/h2cluster-tail.sh
mkdir -p /mnt/h2m /mnt/h2s /mnt/h2c
mount -t hammer2 /dev/vdb@ROOT /mnt/h2m || { echo "recover master mount failed"; exit 1; }
mount -t hammer2 /dev/vdc@ROOT /mnt/h2s || { echo "recover slave mount failed"; exit 1; }
echo "recover-threads $(ps -eo comm | grep -c '^h2nod-CL')"
# The first pass deletes the source snapshot the cut left on the master and
# finds the target the interrupted pass left on the slave, by name.
n=0
while [ $n -lt 600 ]; do
	[ "$(klog 'syncsnap: pass clindex')" -ge 1 ] && break
	sleep 0.5; n=$((n + 1))
done
echo "recover-stale $(klog 'syncsnap: stale CL.h2sync-src deleted')"
echo "recover-tgt-kept $(klog 'syncsnap: target .* kept')"
echo "recover-tgt-listed $(hammer2 -s /mnt/h2s pfs-list 2>/dev/null | grep -c 'h2sync-tgt')"
timeout 30 mount -t hammer2 /dev/vdb@CL /mnt/h2c; rrc=$?
echo "resume-remount-rc $rrc"
echo "resume-thread $(ps -eo comm | grep -c '^h2nod-CL')"
settle_wait
finish
GUESTB

fingerprint() {	# image
	# The synchronization thread's snapshots are PFS roots named
	# <pfs>.h2sync-src and .h2sync-tgt beside CL under the super-root,
	# listed after CL's subtree, so the walk reads to the end rather than
	# stopping at CL's close, and counts them into snaps.<image>. One left
	# after a clean unmount was found by the volume count on 2026-10-18.
	"$HAMMER2" -v show "$1" 2>/dev/null | awk -v snapout="$W/snaps.$(basename "$1")" '
	/filename "[^"]*\.h2sync-(src|tgt)"$/ { snaps++ }
	END { print snaps + 0 > snapout }
	/filename "CL"$/ && !on && !past { on = 1; next }
	on && /^ *} \(inode\.[0-9]*, "CL"\)/ { on = 0; past = 1; next }
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

# The guest half loads /tmp/hammer2.ko by name, so a module given under
# another name through H2_KO is copied to that name.
scp -q "$KO" "$GUEST_SSH:/tmp/hammer2.ko" && scp -q "$W/guest.sh" "$W/tail.sh" "$GUEST_SSH:/tmp/" || { echo "cluster: COULD-NOT-RUN: copy to $GUEST failed" >&2; exit 2; }
GUEST_ENV="NBIG=$NBIG NBIG2=$NBIG2 H2_FAULT=$FAULT H2_FAULT2=${H2_FAULT2:-0} H2DEBUG=$H2DEBUG H2SNAP=$H2SNAP H2_STOP_DEPTH=$STOP_DEPTH H2_STOP_DEPTH_MS=$STOP_DEPTH_MS H2_CRASH=${H2_CRASH:-0} H2_CRASH_DEPTH=${H2_CRASH_DEPTH:-2000} H2_RESUME_SECS=${H2_RESUME_SECS:-900} H2_FORCE_RESCAN=$FORCE_RESCAN H2_FAIL_STAMP=$FAIL_STAMP H2_COLLAPSE=$COLLAPSE TREE=$TREE TREE_FAN=$TREE_FAN TREE_WRITERS=$TREE_WRITERS PASS_CHANGES=$PASS_CHANGES TREE_SECS=${H2_TREE_SECS:-3600}"
if [ "${H2_CRASH:-0}" = 1 ]; then
	# 6. The crash. The guest half runs to its armed line, the guest is
	# destroyed under it (a power cut, so the session ends with it), both
	# media are read by fsck here while the guest is down, the guest is
	# restarted and its second half run. The fake pass this guards: a cut
	# that landed after the pass had ended tests nothing, so the armed line
	# carries whether the pass was still open.
	# The session and this shell both write $W/out: the session's file
	# position is its own, so it is opened for append, or the message ssh
	# prints when the guest dies under it lands over the line appended here.
	: > "$W/out"
	$RUN "$GUEST_SSH" "$GUEST_ENV sh -c 'mv /tmp/guest.sh /tmp/h2cluster.sh; mv /tmp/tail.sh /tmp/h2cluster-tail.sh; . /tmp/h2cluster.sh'" >> "$W/out" 2>&1 &
	apid=$!
	n=0
	until grep -q '^crash-armed' "$W/out" 2>/dev/null || [ $n -ge 2400 ]; do sleep 1; n=$((n + 1)); done
	if grep -q '^crash-armed' "$W/out" 2>/dev/null; then
		$VIRSH destroy "$GUEST" >/dev/null 2>&1; echo "crash-destroyed $?" >> "$W/out"
	else
		echo "crash-destroyed 9" >> "$W/out"
	fi
	wait $apid; arc=$?
	echo "crash-session-rc $arc" >> "$W/out"
	for img in "$MASTER" "$SLAVE"; do
		b=$(basename "$img"); "$FSCK" "$img" > "$W/crashfsck.$b" 2>&1; echo "crash-fsck-$b $?" >> "$W/out"
	done
	# What the cut left on the slave's media, read here before any pass of
	# the restarted thread can take a target of its own: the recovery's
	# "kept" line is a claim about this count, not about a listing taken
	# after that pass.
	echo "crash-tgt-on-media $("$HAMMER2" -v show "$SLAVE" 2>/dev/null | grep -c 'filename "CL.h2sync-tgt"')" >> "$W/out"
	# And what it left on the master's, with the master's own PFS root as
	# the control a count of zero needs, since a show that fails reads as
	# none. The thread's sync after a taken target writes each device's
	# header and waits for it, so both names are on the media before such
	# a pass when it succeeds (the header write is skipped on a flush
	# error, a writeback error or a device in error, can itself fail,
	# and the sync's return is not read); a kept target leaves the
	# source's name to the next sync of a PFS mounted from the master's
	# device, its syncer's every thirty seconds or a caller's, so a cut
	# inside such a pass can leave the target by name and no source, the
	# first pass then having nothing stale to delete, which is how
	# cluster-run-20261025-193845 read with no target line printed. The
	# last target line the guest printed before the cut, taken as the cut
	# pass's, says which since.
	if m=$("$HAMMER2" -v show "$MASTER" 2>/dev/null); then
		echo "crash-master-pfs $(printf '%s\n' "$m" | grep -c 'filename "CL"')" >> "$W/out"
		echo "crash-src-on-media $(printf '%s\n' "$m" | grep -c 'filename "CL.h2sync-src"')" >> "$W/out"
	else
		echo "crash-master-pfs none" >> "$W/out"
	fi
	# How much of the pass the cut left on the slave's media. The thread
	# flushes once per pass, after its scan, and the volume header follows
	# with a mounted PFS's sync, so the slave's media holds all of a pass or
	# none of it; a count between the two would be a copy written piecemeal.
	echo "crash-backlog-on-media $(fingerprint "$SLAVE" | grep -c '^dirent "q[0-9]*" ')" >> "$W/out"
	$VIRSH start "$GUEST" >/dev/null 2>&1 || { echo "cluster: COULD-NOT-RUN: $GUEST did not restart after the cut" >&2; detach_disks; exit 2; }
	n=0
	until ssh -o ConnectTimeout=3 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null; do
		sleep 5; n=$((n + 1))
		[ $n -gt 60 ] && { echo "cluster: COULD-NOT-RUN: $GUEST did not answer ssh in 5 minutes after the cut" >&2; detach_disks; exit 2; }
	done
	echo "crash-restart-seconds $((n * 5))" >> "$W/out"
	scp -q "$KO" "$GUEST_SSH:/tmp/hammer2.ko" && scp -q "$W/guestb.sh" "$W/tail.sh" "$GUEST_SSH:/tmp/" || { echo "cluster: COULD-NOT-RUN: copy to $GUEST failed after the cut" >&2; detach_disks; exit 2; }
	$RUN "$GUEST_SSH" "$GUEST_ENV sh -c 'mv /tmp/guestb.sh /tmp/h2cluster-b.sh; mv /tmp/tail.sh /tmp/h2cluster-tail.sh; . /tmp/h2cluster-b.sh'" >> "$W/out" 2>&1
	rc=$?
else
	$RUN "$GUEST_SSH" "$GUEST_ENV sh -c 'mv /tmp/guest.sh /tmp/h2cluster.sh; mv /tmp/tail.sh /tmp/h2cluster-tail.sh; . /tmp/h2cluster.sh'" > "$W/out" 2>&1
	rc=$?
fi
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
	echo "  FAIL  the guest run hung past ${H2_RUN_TIMEOUT:-$RUNSECS}s; its kernel log is kept beside the images as cluster-hang-*.klog"
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
scp -q "$GUEST_SSH:/tmp/h2cluster.klog" "$FIXDIR/cluster-run-$STAMP.klog" 2>/dev/null \
	&& echo "  kept  the guest kernel log beside the images as cluster-run-*.klog"
detach_disks

val() { sed -n "s/^$1 //p" "$W/out" | head -1; }
nval() { grep -c -E "^$1( |$)" "$W/out"; }	# how many lines carry the name, with or without a value
fail=0; checks=0
check() {	# check <name> <condition-result 0/1> <reading>
	checks=$((checks + 1))
	if [ "$2" = 0 ]; then echo "  ok    $1: $3"; else echo "  FAIL  $1: $3"; fail=$((fail + 1)); fi
}
if [ "$TREE" != 0 ]; then
# The tree arm's reading is each changed pass's time against the cadence,
# printed rather than checked: a pass past 5120 ms is the finding the arm
# exists for, not a harness failure. What is checked is that the reading
# is of the shape it claims: the whole tree written, the thread idle on it
# before the change, the slave element gone while the master was written,
# and a pass that verified.
echo "  raw   tree files=$(val tree-files) write-s=$(val tree-write-seconds) settle-s=$(val tree-settle-seconds) idles=$(val tree-settle-idles) snapshot-passes=$(val tree-snap-passes)"
a=$(val cluster-thread); [ "${a:-0}" = 1 ]; check "the SLAVE in a cluster starts one thread" $? "${a:-0}"
a=$(val tree-files); [ "${a:-0}" = "$TREE" ]; check "the tree holds its $TREE files" $? "${a:-none} in $(val tree-write-seconds) s by $TREE_WRITERS writer(s)"
a=$(val tree-settle-idles); [ "${a:-0}" -ge 2 ] 2>/dev/null; check "the thread is idle on the tree before the change" $? "${a:-none} idle pass(es) after $(val tree-settle-seconds) s"
c=1
while [ $c -le "$PASS_CHANGES" ]; do
	a=$(val change-$c-threads-down); [ "${a:-1}" = 0 ]; check "change $c: the slave element leaves while the master is written" $? "${a:-none} thread(s)"
	set -- $(val change-$c-pass)
	if [ $c = 2 ] && [ "$FAIL_STAMP" = 1 ]; then
		a=$(val change-$c-stamp-failed); [ "${a:-0}" = 1 ]; check "change 2: the PFS root's stamp fails once on demand" $? "${a:-none} failure(s), knob left at $(val change-$c-knob-left)"
		[ "${5:-none}" = unverified ]; check "change 2: a pass whose root stamp failed does not verify" $? "${5:-none} after $(val change-$c-wait-seconds) s"
	else
		[ "${5:-none}" = verified ]; check "change $c: the thread's next pass verifies" $? "${5:-none} after $(val change-$c-wait-seconds) s"
	fi
	if [ $c = 1 ] && [ "$FORCE_RESCAN" = 1 ]; then
		a=$(val change-$c-rescan-all); [ "${a:-0}" -ge 1 ] 2>/dev/null; check "change 1: the pass is asked to compare every inode" $? "${a:-none} rescan-all line(s), knob left at $(val change-$c-knob-left)"
		echo "  read  change 1: $(val change-$c-root-scans) root scan(s) in the round that compared every inode"
	fi
	echo "  read  change $c: ${4:-none} ms against 5120 (snapshot and target ${1:-none}, verify ${2:-none} in ${6:-none} round(s), delete ${3:-none}), largest scan ${7:-none} iterations"
	c=$((c + 1))
done
a=$(val tree-errors); [ "${a:-1}" = 0 ]; check "no pass reports an error" $? "${a:-none}"
a=$(val kept-absent)
if [ "${a:-0}" -gt 0 ] 2>/dev/null; then
	b=$(val kept-absent-skips); [ "${b:-1}" = 0 ]; check "no kept-absent line or sweep destroy shows a source key passed over" $? "${b:-none} in $a kept-absent line(s)"
else
	echo "  read  the kept-absent arm did not run: ${a:-none} line(s)"
fi
grep -q '^cluster-umount ok' "$W/out"; check "the cluster unmounts" $? "$(grep -c '^cluster-umount ok' "$W/out") of 1"
else
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
# Phase 3b. The window must have reached a copy, or the convergence read at
# the end was never in question: a zero here is the phase not driving its
# condition, and fails. The window must also have closed inside the pass's
# actions rather than in its flush, which a pass error would show, since a
# refused flush retries by a different path from the one this phase is for.
if [ "$FAULT" != 0 ]; then
	f=$(val fault-failed); [ "${f:-0}" -gt 0 ] 2>/dev/null; check "the refused allocations failed copies inside the first pass" $? "${f:-none} action(s) returned non-zero of $FAULT refusals, window closed in $(val fault-window-tenths) tenths with $(val fault-count-left) left"
	# A refused copy is not a pass error: the key is withheld from the stamp
	# and retried, and the pass returns as a completed scan does. The
	# pre-fix module faulted here instead (measured 2026-10-16: a
	# null-ptr-deref in hammer2_chain_lookup from hammer2_sync_slaves,
	# h2nod-CL dead), and the first fixed build leaked the scan's ENOENT
	# as `error 64` once the stamp no longer absorbed it.
	e=$(val fault-errors); [ "${e:-1}" = 0 ]; check "the refused copies leave no pass error" $? "${e:-none}"
fi
# Phase 2c: both arms must have run, or the phase measured nothing. Five
# keys were deleted and five rewritten behind the slave's back; the per-arm
# counters are the module's own and count file keys and the directories
# above them, so the floor is five and the reading is printed.
a=$(val diverge-destroyed); [ "${a:-0}" -ge 5 ]; check "the stale slave's extra keys are destroyed by the thread" $? "${a:-none} destroyed for 5 deleted"
a=$(val diverge-replaced); [ "${a:-0}" -ge 5 ]; check "the stale slave's changed keys are replaced by the thread" $? "${a:-none} replaced for 5 rewritten"
# On a snapshot pass the thread's first pass after the slave's return has no
# previous snapshot cut, so the rewritten files' stale tail blocks are kept
# rather than destroyed and their inodes go on the rescan set; the next pass
# must scan them again although the flush left their tids equal to the
# master's. The floor is one; the ceiling catches a set stuck at "every
# inode", which would also converge but rescan the whole tree every pass.
if [ "$H2SNAP" = 1 ]; then
	a=$(val diverge-rescanned); [ "${a:-0}" -ge 1 ] && [ "${a:-0}" -le 64 ]; check "inodes whose keys were kept are scanned again on the next pass" $? "${a:-none} rescan(s) for the kept tails of 5 rewritten files"
fi
a=$(val diverge-threads-down); [ "${a:-1}" = 0 ]; check "the cluster down leaves no thread" $? "${a:-none}"
a=$(val diverge-threads-up); [ "${a:-0}" = 1 ]; check "the slave's return starts the thread again" $? "${a:-none}"
if [ "${H2_FAULT2:-0}" != 0 ]; then
	f=$(val diverge-failed); [ "${f:-0}" -gt 0 ]; check "refused allocations failed actions in the replace or destroy pass" $? "${f:-none} of $H2_FAULT2 refusals, window closed in $(val diverge-window-tenths) tenths with $(val diverge-count-left) left"
	e=$(val diverge-errors); [ "${e:-1}" = 0 ]; check "the refused replace or destroy leaves no pass error" $? "${e:-none}"
fi
grep -q '^cluster-umount ok' "$W/out"; check "the cluster unmounts" $? "$(grep -c '^cluster-umount ok' "$W/out") of 1"
if [ "${H2_CRASH:-0}" = 0 ]; then
# Phase 4b/4c: the backlog must be the thread's copy, the stop must land
# inside that copy, and the device teardown must stop the thread mid-pass.
# Without the first, every check below tested a root scan, which is what
# runs 8 to 11 measured. The raw fields are printed before their checks
# because several decide one verdict and the guest's output file is removed
# at exit.
echo "  raw   phase4 begun=$(val interrupt-begun) bracket=$(val interrupt-bracket-open) src-listed=$(val pass-src-listed) tgt-listed=$(val pass-tgt-listed) mutate-rc=$(val mutate-mount-rc) mutate-in-pass=$(val mutate-in-pass) stop-copied=$(val interrupt-stop-copied) in-pass=$(val interrupt-in-pass) copied=$(val interrupt-copied) umount-ms=$(val interrupt-umount-ms) threads=$(val interrupt-threads-before)-$(val interrupt-threads) didbreak=$(val interrupt-didbreak) src-cleaned=$(val interrupt-src-cleaned) tgt-on-media=$(val interrupt-tgt-on-media) resume-dev=$(val resume-device-rc) resume-rc=$(val resume-remount-rc) tgt-kept=$(val resume-tgt-kept) tgt-left=$(val resume-tgt-listed) inserts=$(val backlog-inserts) kept=$(val mutate-kept) mark-old=$(val interrupt-mark-old) mark-new=$(val interrupt-mark-new) reinserts=$(val mutate-reinserts) newer-inodes=$(val mutate-newer-inodes) passes=$(val resume-passes) updates=$(val resume-updates) settled=$(val resume-settled) conv-s=$(val resume-converge-seconds)"
echo "  raw   phase4 actions=$(val interrupt-actions) sweep-max=$(val interrupt-sweep-max)"
a=$(val backlog-threads-down); [ "${a:-1}" = 0 ]; check "both mounts down leave no thread, so the slave element has left" $? "${a:-none}"
a=$(val backlog-threads-up); [ "${a:-0}" = 1 ]; check "the slave's device returning starts the thread on the unmounted cluster" $? "${a:-none}"
b=$(val interrupt-begun); [ "$b" = 0 ]; check "the thread's copy of the backlog had begun" $? "rc ${b:-none}"
i=$(val backlog-inserts); [ "${i:-0}" -ge "$NBIG2" ] 2>/dev/null; check "the backlog is the thread's copy, not the frontend's" $? "${i:-none} file-key inserts for $NBIG2 files; the step-2 runs read 64 to 70 over a whole run"
if [ "$COLLAPSE" != 0 ]; then
	a=$(val collapse-done); [ "${a:-0}" = 1 ]; check "an insert's parent is collapsed once on demand" $? "${a:-none} collapse(s), knob left at $(val collapse-knob-left)"
	a=$(val collapse-guard); [ "${a:-0}" -ge 1 ] 2>/dev/null; check "the scan ends on its deleted parent" $? "${a:-none} line(s)"
	a=$(val collapse-round-failed); [ "${a:-0}" -ge 1 ] 2>/dev/null; check "the round that scan ended in does not verify" $? "${a:-none} failure(s) in that round"
else
	echo "  read  the scan's parent found deleted $(val collapse-guard) time(s) with no knob"
fi
m=$(val mutate-mount-rc); [ "${m:-1}" = 0 ] && [ "$(val mutate-in-pass)" = 0 ]; check "the master is mutated while the pass runs" $? "mount rc ${m:-none}, in-pass rc $(val mutate-in-pass)"
c=$(val interrupt-stop-copied | awk '{print $1}'); [ "${c:-0}" -ge 1 ] 2>/dev/null && [ "$(val interrupt-in-pass)" = 0 ]; check "the stop lands inside the copy" $? "${c:-none} updates past the mutation of $(val interrupt-stop-copied | awk '{print $3}') wanted, in-pass rc $(val interrupt-in-pass)"
ms=$(val interrupt-umount-ms); [ "${ms:-0}" -gt 0 ] 2>/dev/null; check "the device teardown waits for the pass to reach a stop point" $? "${ms:-0} ms"
d=$(val interrupt-didbreak); [ "${d:-0}" -ge 1 ] 2>/dev/null; check "the thread reads the stop between deferrals" $? "${d:-none} didbreak"
tb=$(val interrupt-threads-before); a=$(val interrupt-threads); [ "${tb:-0}" = 1 ] && [ "${a:-1}" = 0 ]; check "the device teardown stops the thread" $? "threads ${tb:-none} to ${a:-none}"
if [ "$H2SNAP" = 1 ]; then
	a=$(val pass-src-listed); [ "${a:-0}" -ge 1 ] 2>/dev/null; check "the source snapshot is a listed PFS on the master's device while the pass runs" $? "${a:-none} .h2sync-src listed"
	a=$(val pass-tgt-listed); [ "${a:-0}" -ge 1 ] 2>/dev/null; check "the target snapshot is a listed PFS on the slave's device while the pass runs" $? "${a:-none} .h2sync-tgt listed"
	[ "${H2_CRASH:-0}" = 1 ] || { a=$(val interrupt-src-cleaned); [ "${a:-0}" -ge 1 ] 2>/dev/null; check "the interrupted pass's source snapshot is deleted by the teardown" $? "${a:-none}" ; }
	[ "${H2_CRASH:-0}" = 1 ] || { a=$(val interrupt-tgt-on-media); [ "${a:-0}" = 1 ]; check "the interrupted pass's target snapshot survives on the slave's media" $? "${a:-none} .h2sync-tgt root(s) on /dev/vdc" ; }
	a=$(val resume-tgt-kept); [ "${a:-0}" -ge 1 ] 2>/dev/null; check "the resumed thread finds the kept target by name" $? "${a:-none} kept"
	a=$(val resume-tgt-listed); [ "${a:-1}" = 0 ]; check "the target is deleted once the resumed pass verifies" $? "${a:-none} listed after the settle"
	[ "${H2_CRASH:-0}" = 1 ] || { o=$(val interrupt-mark-old); w=$(val interrupt-mark-new); [ "${o:-0}" -ge 10 ] 2>/dev/null && [ "${w:-1}" = 0 ]; check "the interrupted pass wrote the snapshot's state of the marked set, not the live master's" $? "${o:-none} line(s) of the ten deleted files on the slave's media, ${w:-none} of the ten written; kept $(val mutate-kept)" ; }
else
	a=$(val pass-src-listed); b=$(val pass-tgt-listed); [ "${a:-1}" = 0 ] && [ "${b:-1}" = 0 ]; check "the live pass takes no snapshot" $? "${a:-none} src, ${b:-none} tgt listed"
	[ "${H2_CRASH:-0}" = 1 ] || { o=$(val interrupt-mark-old); w=$(val interrupt-mark-new); [ "${o:-1}" = 0 ] && [ "${w:-0}" -ge 10 ] 2>/dev/null; check "the live pass wrote the master's state of the marked set as it found it" $? "${o:-none} line(s) of the ten deleted files on the slave's media, ${w:-none} of the ten written" ; }
fi
f=$(val mark-files); [ "${f:-0}" = 20 ]; check "the marked set ends at 20 files on the master" $? "${f:-none}"
a=$(val resume-device-rc); [ "${a:-1}" = 0 ]; check "the slave's device returns" $? "rc ${a:-none}"
else
	echo "  raw   crash copied=$(val crash-copied) in-pass=$(val crash-in-pass) destroyed=$(val crash-destroyed) session-rc=$(val crash-session-rc) fsck=$(val crash-fsck-cluster-master.img)/$(val crash-fsck-cluster-slave.img) tgt-media=$(val crash-tgt-on-media) backlog-media=$(val crash-backlog-on-media) restart-s=$(val crash-restart-seconds) threads=$(val recover-threads) last-tgt=$(val crash-last-target) master-pfs=$(val crash-master-pfs) src-media=$(val crash-src-on-media) stale=$(val recover-stale) tgt-kept=$(val recover-tgt-kept) tgt-listed=$(val recover-tgt-listed) cluster-rc=$(val resume-remount-rc)"
	c=$(val crash-copied); [ "${c:-0}" -ge 1 ] 2>/dev/null && [ "$(val crash-in-pass)" = 0 ]; check "the power is cut inside the copy" $? "${c:-none} updates into the pass, in-pass rc $(val crash-in-pass)"
	a=$(val crash-destroyed); [ "${a:-9}" = 0 ]; check "the guest is destroyed at the armed line" $? "virsh destroy rc ${a:-none}, session rc $(val crash-session-rc)"
	a=$(val crash-fsck-cluster-master.img); b=$(val crash-fsck-cluster-slave.img); [ "${a:-1}" = 0 ] && [ "${b:-1}" = 0 ]; check "both media are consistent as the cut left them" $? "fsck_hammer2 exit ${a:-none} and ${b:-none} before recovery"
	n=$(val crash-backlog-on-media); [ "${n:-x}" = 0 ] || [ "${n:-x}" = "$NBIG2" ]; check "the cut leaves the slave's media at a whole pass's state" $? "${n:-none} of $NBIG2 backlog files on the slave's media at the cut; the pass's copies reach the media in one flush after its scan"
	a=$(val recover-threads); [ "${a:-0}" = 1 ]; check "the two devices returning start the thread" $? "${a:-none}"
	t=$(val crash-last-target); p=$(val crash-master-pfs); m=$(val crash-src-on-media); a=$(val recover-stale)
	case $t in
	taken) [ "${p:-0}" -ge 1 ] && [ "${m:-0}" -ge 1 ] && [ "${a:-0}" -ge 1 ] ;;
	kept) [ "${p:-0}" -ge 1 ] && { { [ "${m:-0}" -ge 1 ] && [ "${a:-0}" -ge 1 ]; } || { [ "${m:-x}" = 0 ] && [ "${a:-x}" = 0 ]; }; } ;;
	*) false ;;
	esac 2>/dev/null
	check "the source snapshot the cut left is deleted by the first pass: there after a taken target, and after a kept one deleted exactly when its name was there" $? "target ${t:-none} at the cut, ${m:-none} source(s) on the master's media beside ${p:-none} PFS root(s) read, ${a:-none} stale delete(s)"
	# Three readings make one claim: the target is on the slave's media as
	# the cut left it (read host-side while the guest was down), the first
	# pass finds it by name rather than taking one, and one is listed after
	# that pass, since a second beside it would be the create walking past
	# the name (hammer2_pfs_find_byname()).
	m=$(val crash-tgt-on-media); a=$(val recover-tgt-kept); l=$(val recover-tgt-listed); [ "${m:-0}" -ge 1 ] 2>/dev/null && [ "${a:-0}" -ge 1 ] 2>/dev/null && [ "${l:-0}" = 1 ]; check "the target snapshot the cut left is found by name" $? "${m:-none} on the media at the cut, ${a:-none} kept, ${l:-none} listed before the cluster mount"
fi
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
fi
# The snapshot pass: every pass that took a snapshot verified against it,
# the target snapshot was on the slave's device while the pass was
# interrupted, an idle master costs idle passes and no snapshot, and once
# idle the two root tids agree. Each is a count the live pass cannot
# produce, so a thread that never took a snapshot fails here.
if [ "$H2SNAP" = 1 ]; then
	a=$(val snap-verified); p=$(val snap-passes); [ "${a:-0}" -ge 1 ] 2>/dev/null; check "a snapshot pass verified against its own snapshot" $? "${a:-none} verified of ${p:-none} snapshot pass(es), at most $(val snap-verify-rounds) round(s)"
	# A pass raced by a frontend write keeps the newer key and waits for the
	# next snapshot; that is printed as `newer` and is not a pass that ran
	# out of rounds. MEASURED 2026-10-18: 5 such passes in a run, every one
	# with 0 actions and 1 kept key, 4 of them under the 20000-file write.
	# H2_FAIL_STAMP's pass is unverified by design and is read above, so
	# it is subtracted here and no other is.
	a=$(val snap-unverified); fs=
	[ -n "$a" ] && [ "$FAIL_STAMP" = 1 ] && { a=$((a - 1)); fs=", the one H2_FAIL_STAMP fails not counted"; }
	[ "${a:-1}" = 0 ]; check "no snapshot pass ran out of verify rounds" $? "${a:-none} unverified, $(val snap-newer) waited for the next snapshot behind a frontend write, $(val snap-interrupted) stopped by an unmount$fs"
	a=$(val snap-target-errors); [ "${a:-1}" = 0 ]; check "every target snapshot was taken or kept" $? "${a:-none} error(s)"
	a=$(val idle-window-idles); b=$(val idle-window-passes); [ "${a:-0}" -ge 2 ] 2>/dev/null && [ "${b:-1}" = 0 ]; check "an idle master costs no snapshot" $? "${a:-none} idle pass(es), ${b:-none} snapshot pass(es) in $(val idle-window-seconds) s after the resume settled"
	l=$(val snap-last-idle); mt=$(printf '%s\n' "$l" | awk '{print $1}'); st=$(printf '%s\n' "$l" | awk '{print $3}')
	[ -n "$mt" ] && [ "$mt" = "$st" ]; check "the slave root's tid agrees with the master's once idle" $? "master ${mt:-none} slave ${st:-none}, after $(val snap-idlestamp) idle stamp(s)"
fi
if [ "$TREE" = 0 ]; then
if [ $(( H2DEBUG & 1 )) = 1 ]; then
	w=$(val write-destroys); [ "${w:-1}" = 0 ]; check "no pass destroys on the slave while the master is being written" $? "${w:-none} destroy(s) inside the write"
fi
e=$(val resume-errors); [ "${e:-1}" = 0 ]; check "no pass reports an error across the interruption" $? "${e:-none}"
fi
echo "  raw   space start=$(val space-start) end=$(val space-end) after-bulkfree=$(val space-after-bulkfree) bulkfree-rc=$(val space-bulkfree-rc-1)/$(val space-bulkfree-rc-2) free blocks of the master's device, snapshot passes $(val snap-passes)"
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
g=$(val gpu-warnings); [ "${g:-0}" = 0 ] || echo "  note  the guest's GPU warned $g time(s) (drivers/gpu/drm/), counted apart from the port's"
# A scan that refused is not an empty report. An earlier control run can
# switch kmemleak off, after which it reports nothing and stays off until a
# reboot, so a refusal fails here rather than reading as a clean scan. A
# kernel built without kmemleak has no file to write and fails the same
# way, which is right for the two kernels this runs on, both built with
# it. No value at all means the guest stopped before this point.
c=$(grep -o kmemleak-cleared "$W/out" | wc -l); l=$(val kmemleak); m=$(nval kmemleak); u=$(val kmemleak-unloaded); n=$(nval kmemleak-unloaded); r=$(nval kmemleak-unloaded-range)	# counted by occurrence, so a second marker glued to a line or beside the first on one line is a second clear
case "$l" in
0) [ "$c" = $((1 + ${H2_CRASH:-0})) ] && [ "$m" = 1 ] && [ "$n" = 1 ] && [ "$r" = 1 ] && [ "${u:-1}" = 0 ]; check "kmemleak reports nothing of hammer2's" $? "cleared $c time(s), $l printed $m time(s), after the unload ${u:-unread}, printed $n time(s) after $r range line(s)" ;;
unusable) if [ "$want_kmemleak" = n ]; then echo "  note  the kernel tree configures no kmemleak, so this run takes no leak reading"; else check "kmemleak is usable, so a leak would be reported" 1 "the scan refused; an earlier control run switched it off and only a reboot turns it back on"; fi ;;
"") check "kmemleak was read before the unload" 1 "no reading before the unload, $n after it with $r range line(s)" ;;
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
	COLUMNS=4096 "$FSCK" -b "$img" < /dev/null > "$W/fsck-best.$b" 2>&1
done
# The totals come from the best zone alone, fsck -b, whose last running total
# is that zone's. The walk above covers all four headers, and an older one
# still holds the tree a pass's snapshot was in. MEASURED 2026-10-27: a tree
# run with no write after its last pass left zone 3 at twice the inodes of
# the best zone, which matched the slave.
#
# fsck cuts each running total to the width of a terminal on its stdout,
# stderr or stdin, else to $COLUMNS, else to 80, so stdin is taken off a
# terminal for $COLUMNS to count. At 80 a million-file tree's totals lost their closing
# parenthesis, and a pattern matching complete totals anywhere in the file
# took the last one that still fit, 100092 inodes of 1001005, and passed on
# a tenth of the walk. The width is set wide, and the last total is taken
# whole or not at all, so a cut one reads as no total and fails.
last() { tr '\r' '\n' < "$1" | grep 'blockref (' | tail -1 | grep -o '([0-9]* inode, [0-9]* indirect, [0-9]* data, [0-9]* dirent)'; }
m=$(last "$W/fsck-best.cluster-master.img" | sed 's/ [0-9]* indirect,//')
v=$(last "$W/fsck-best.cluster-slave.img" | sed 's/ [0-9]* indirect,//')
[ -n "$m" ] && [ "$m" = "$v" ]; check "the slave holds what the master holds" $? "master $m, slave $v; indirect blocks are left out, the slave's being built in insertion order"

# The fingerprint of the cluster's PFS, from the line naming it to the
# line closing it. Inode check codes are left out: they cover timestamps
# and transaction ids, which a slave does not share with its master.
fingerprint "$MASTER" > "$W/fp.master"
fingerprint "$SLAVE" > "$W/fp.slave"
nm=$(grep -c ' FILE$' "$W/fp.master"); ns=$(grep -c ' FILE$' "$W/fp.slave")
nd=$(grep -c '^data ' "$W/fp.master")
# The interruption phase leaves its large directory on both volumes, so the
# fingerprint's expected count is the set's 35, bigdir's NBIG, bigdir2's NBIG2 and
# the marked set's 20 (20 made, 10 deleted and 10 new during the pass).
want_files=$((35 + NBIG + NBIG2 + 20)); [ "$TREE" = 0 ] || want_files=$TREE
[ "$nm" = "$want_files" ] && [ "$nd" -gt 0 ]; check "the master's PFS holds the $want_files files, by its own media" $? "$nm file entries, $nd data blocks"
cmp -s "$W/fp.master" "$W/fp.slave"; check "the slave's PFS matches the master's entry for entry and block for block" $? "$ns file entries; $(diff "$W/fp.master" "$W/fp.slave" | grep -c '^[<>]') lines differ of $(wc -l < "$W/fp.master")"
# The thread's per-pass snapshot must be gone from both devices after a clean
# unmount; one left is a PFS root the fingerprint's walk counts. MEASURED
# 2026-10-18: the final unmount held hammer2_mntlk while the thread's delete
# tried for it, and CL.h2sync-src stayed on the master, read first as the
# volume holding twice the inodes of its PFS.
sm=$(cat "$W/snaps.$(basename "$MASTER")" 2>/dev/null); ss=$(cat "$W/snaps.$(basename "$SLAVE")" 2>/dev/null)
[ "${sm:-1}" = 0 ] && [ "${ss:-1}" = 0 ]; check "no synchronization snapshot is left on either device" $? "master ${sm:-unread}, slave ${ss:-unread} .h2sync-* PFS root(s)"
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
	# The direction is the first thing a differing run is read for, and the two
	# counts are not in the check's message. `diff master slave` marks a line
	# only the MASTER holds with `<` and one only the SLAVE holds with `>`, so
	# the two counts say which side is short without opening the media.
	# MEASURED 2026-10-15: a differing run's direction had to be inferred from
	# the inode totals because the counts were not printed and its images were
	# gone by then.
	monly=$(diff "$W/fp.master" "$W/fp.slave" | grep -c '^<')
	snly=$(diff "$W/fp.master" "$W/fp.slave" | grep -c '^>')
	echo "  diff  $monly line(s) only on the master, $snly only on the slave, of $(wc -l < "$W/fp.master")"
	echo "  kept  the differing run's images and fingerprint beside the kernel log as cluster-diff-*-$stamp.*"
fi

echo "cluster: $checks check(s), $fail failed"
[ "$fail" = 0 ]
