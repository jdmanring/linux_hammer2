#!/bin/sh
# WHAT A FULL VOLUME DOES, WHICH NOTHING HERE HAD EVER ASKED.
#
# Every write measurement in this tree was taken on a volume with room
# in it. This one fills a volume until the first write fails, then calls
# sync(2), and reads lockdep on both sides of each step.
#
# Its first runs found a circular lock dependency: lockdep stayed
# enabled through 583 files and 2 GiB of writing and disabled itself
# during the sync that followed. The report named two orders,
#
#   hammer2_write_end -> hammer2_inode_chain_sync   holds h2ip, takes h2ch_inode
#   hammer2_vfs_sync_pmp                            holds h2ch_inode, takes h2ip
#
# and the cause was hammer2_chain_create() clearing a caller's chain
# pointer on the ENOSPC path, which skipped the caller's own release and
# left the chain locked. Eight runs reported the cycle before that fix
# and none has since. doc/README.status.md carries the whole account.
#
# The report is read by streaming /dev/kmsg for the whole run, because
# the ring wraps before a fill ends, and it is printed before the
# unmount, because the unmount is where a bad run loses the log.
#
# WHAT IS STILL OPEN, and why this is not a gate: lockdep reported a
# held lock freed during the fill on two runs before the unmount fix,
# neither captured past the banner nor tied to a build. A recurrence
# fails this script, is captured whole, and names its build.
#
# NOTHING HERE IS JUDGED BY A PROCESS'S EXIT STATUS ALONE. The unmount
# is judged by whether the filesystem went away, because the unmount
# process is killed on these runs by something outside this script and
# the status alone read for several runs as an unmount that hung.
#
# EXIT 2 IS COULD-NOT-RUN AND IS NEVER A PASS, as in test-fixtures.sh.
set -u
cd "$(dirname "$0")/.." || exit 2

# --selftest: THE CONTROL THIS SCRIPT DID NOT HAVE. Every gate in this
# tree carries one; the reproducer did not, and its readings are exactly
# the kind that fail silently. Several have never been observed to take a
# value other than their default, so any of them could have stopped
# matching and every run would still have read clean. Three did stop
# matching: a banner spelled from memory rather than from
# kernel/locking/lockdep.c, a fallback bound to a command that cannot
# fail, and a count taken before the event it counted.
#
# Each reading is checked in BOTH directions against a line the kernel
# really prints: the pattern must match that line, and must not match an
# empty log. The pattern is then required to appear in this file, because
# the remote block is one quoted string and cannot share a variable with
# the host half, so these are copies and copies drift. A pattern edited
# there and not here fails this check rather than going quiet.
if [ "${1:-}" = --selftest ]; then
	t=$(mktemp -d) || exit 2
	trap 'rm -rf "$t"' EXIT
	sfail=0 nread=0
	# This file without the selftest, so a pattern is looked for where
	# the run uses it and not where this block names it.
	command sed '/^if \[ "${1:-}" = --selftest \]; then$/,/^fi$/d' "$0" \
	    > "$t/rest"
	[ -s "$t/rest" ] || {
		echo "enospc: FAIL: the selftest could not separate itself" >&2
		exit 1; }
	check() { # label pattern sample-line
		nread=$((nread + 1))
		printf '%s\n' "$3" > "$t/pos"
		# A log of ordinary lines, not an empty one. Almost any
		# pattern fails to match nothing, so an empty file tests
		# nothing; what matters is that a pattern does not fire on
		# a healthy run's log, which is what this is.
		printf '%s\n' \
		    "6,100,1,-;hammer2: hammer2_vfs_mount: mounted vdb" \
		    "6,101,1,-;hammer2: hammer2_vfs_statfs: 0 blocks free" \
		    "4,102,1,-;EXT4-fs (vda1): mounted filesystem" \
		    "6,103,1,-;systemd: Reached target Local File Systems" \
		    > "$t/neg"
		command grep -q "$2" "$t/pos" || {
			echo "  FAIL  $1: the pattern does not match the line"
			echo "        it is there to read"
			sfail=$((sfail + 1)); }
		if command grep -q "$2" "$t/neg"; then
			echo "  FAIL  $1: the pattern fires on a healthy"
			echo "        run's log, so it cannot report absence"
			sfail=$((sfail + 1))
		fi
		# Searched in the run's half of this file only. A search
		# whose pattern sits in its own command line finds itself,
		# and both the argument below and the sample beside it
		# contain the pattern, so neither a match nor a count of
		# them says anything about the code that runs.
		command grep -qF "$2" "$t/rest" || {
			echo "  FAIL  $1: this pattern is not the one the run"
			echo "        uses; they have drifted apart"
			sfail=$((sfail + 1)); }
		[ "$sfail" -eq 0 ] && echo "  ok    $1"
	}
	check "the cycle count" \
	    "possible circular locking dependency" \
	    "4,1043,34351285,-;WARNING: possible circular locking dependency detected"
	check "a held lock freed" \
	    "held lock freed" \
	    "4,900,1,-;WARNING: held lock freed!"
	check "a lockdep ceiling" \
	    "BUG: MAX_[A-Z_]* too low!" \
	    "4,901,1,-;BUG: MAX_LOCKDEP_KEYS too low!"
	check "an unlock imbalance" \
	    "bad unlock balance" \
	    "4,902,1,-;WARNING: bad unlock balance detected!"
	check "an out of memory kill" \
	    "Out of memory: Killed" \
	    "3,903,1,-;Out of memory: Killed process 2300 (umount)"
	check "the chain dropped under its own lock" \
	    "holds its lock" \
	    "4,904,1,-;hammer2: last drop of inode chain 0000000000000402 while this task holds its lock"
	check "what the module still holds" \
	    "after unmount: .*" \
	    "6,905,1,-;hammer2: hammer2_kill_sb: after unmount: 0 inode, 4 chain, 0 modified, 0 dio still allocated"
	check "a kernel fault" \
	    "Oops: " \
	    "4,1073,1,-;Oops: Oops: 0000 [#1] SMP NOPTI"
	check "where it faulted" \
	    "RIP: [0-9]*:[a-zA-Z0-9_]*+0x[0-9a-f]*" \
	    "4,1077,1,-;RIP: 0010:hammer2_flush_core+0x206/0x910 [hammer2]"
	check "a chain on a freed PFS" \
	    "holds freed pmp" \
	    "6,910,1,-;hammer2: hammer2_flush_core: inode chain 0000000000000402/0 holds freed pmp, flags 00144002"
	check "a busy inode" \
	    "Busy inodes after unmount" \
	    "4,906,1,-;VFS: Busy inodes after unmount of vdb (hammer2)"
	check "a held chain" \
	    "sync_pmp entry" \
	    "6,907,1,-;hammer2: __hammer2_dbg_held_chains: sync_pmp entry: chain type 1 key 0000000000000402"
	[ "$nread" -gt 0 ] || {
		echo "enospc: FAIL: the selftest checked no reading at all" >&2
		exit 1; }
	echo "enospc: selftest, $nread reading(s), $sfail failure(s)"
	[ "$sfail" -eq 0 ]
	exit $?
fi

# H2_REPEAT=n runs the whole thing n times and tallies the outcomes.
# BOTH DEFECTS LEFT ON THIS REPRODUCER ARE INTERMITTENT: the module has
# held references after unmount on five runs of seven and lockdep has
# reported a held lock freed on two of nine, so a single run is the
# wrong instrument for either and answers only about itself. A wedged
# guest also costs the NEXT run, which is COULD-NOT-RUN rather than a
# result, so each iteration resets the guest rather than inheriting
# whatever the last one left. Nothing is summed that was not counted:
# the tally asserts it saw as many outcomes as it ran.
repeat=${H2_REPEAT:-1}
case $repeat in
''|*[!0-9]*) echo "enospc: COULD-NOT-RUN: H2_REPEAT is not a number" >&2; exit 2 ;;
esac
if [ "$repeat" -gt 1 ]; then
	GUEST=${H2_GUEST:-artix-s6-kde}
	VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
	pass=0; failed=0; cnr=0; seen=0; i=1
	# Each run's whole output is kept. The first version reused one
	# temporary file, so every question the tally did not already answer
	# cost another batch to ask: the logs that would have said whether
	# the failing runs were the ones whose unmount was killed had been
	# overwritten by the runs that followed them.
	logdir=${H2_LOGDIR:-$(mktemp -d)} || exit 2
	mkdir -p "$logdir" || exit 2
	# Each iteration re-reads this file, so an edit made while a batch
	# is running changes the runs after it, and a half-written file
	# gives them a syntax error scored as a driver failure. That
	# happened: two runs of a six-run batch were lost to it. The
	# checksum is taken once and re-checked every iteration, so the
	# batch refuses rather than reporting on code nobody chose to run.
	sum0=$(sha256sum < "$0") || exit 2
	while [ "$i" -le "$repeat" ]; do
		$VIRSH destroy "$GUEST" >/dev/null 2>&1
		sleep 6
		$VIRSH start "$GUEST" >/dev/null 2>&1
		sumn=$(sha256sum < "$0")
		[ "$sumn" = "$sum0" ] || {
			echo "enospc: COULD-NOT-RUN: this script changed while the" >&2
			echo "          batch was running, so the runs after the" >&2
			echo "          change would not be the run that started" >&2
			exit 2; }
		log=$logdir/run-$i.log
		H2_REPEAT=1 sh "$0" > "$log" 2>&1
		st=$?
		seen=$((seen + 1))
		case $st in
		0) pass=$((pass + 1)); verdict=pass ;;
		2) cnr=$((cnr + 1)); verdict=could-not-run ;;
		*) failed=$((failed + 1)); verdict=fail ;;
		esac
		echo "run $i: $verdict"
		# The readings that separate the two open defects from each
		# other, printed per run so the tally is not the only record.
		command sed -n "s/^  \(locks after sync [0-9]*\)$/      \1/p;\
		    s/^  \(files written [0-9]*\)$/      \1/p;\
		    s/^  \(built from .*\)$/      \1/p;\
		    s/^  \(fsync of the last file returned .*\)$/      \1/p;\
		    s/^  \(syncfs returned .*\)$/      \1/p;\
		    s/^  \(cycles [0-9]*\)$/      \1/p;\
		    s/^  \(drop-with-lock warns [0-9]*\)$/      \1/p;\
		    s/^  \(oops [0-9]*\)$/      \1/p;\
		    s/^  \(faulted in .*\)$/      \1/p;\
		    s/^  \(still mounted [0-9]*\)$/      \1/p;\
		    s/^  \(umount [0-9]*\)$/      \1/p;\
		    s/^  \(umount left at .*\)$/      \1/p;\
		    s/^  \(module refs .*\)$/      \1/p;\
		    s/^  \(outstanding .*\)$/      \1/p;\
		    s/^  \(busy inodes [0-9]*\)$/      \1/p;\
		    s/^  \(rmmod [0-9]*\)$/      \1/p;\
		    s/^  \(shutdown-reason .*\)$/      \1/p" "$log"
		command grep "^  FAIL" "$log" | command sed "s/^  /      /"
		i=$((i + 1))
	done
	echo "enospc: $seen run(s), $pass pass, $failed fail, $cnr could-not-run"
	echo "enospc: the runs are kept in $logdir"
	[ "$seen" -eq "$repeat" ] || {
		echo "enospc: FAIL: ran $repeat but tallied $seen" >&2; exit 1; }
	[ "$failed" -eq 0 ] && [ "$cnr" -eq 0 ]
	exit $?
fi

# The control runs on every run, not when someone remembers it. It costs
# a fraction of a second, and a reading that has silently stopped
# matching is the failure mode this whole script has actually had.
sh "$0" --selftest > /dev/null 2>&1 || {
	echo "enospc: COULD-NOT-RUN: a reading no longer matches the line" >&2
	echo "          it reads, so this run could report clean by not" >&2
	echo "          seeing. Run: sh script/enospc.sh --selftest" >&2
	exit 2; }

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
# What the module was built from, printed with the readings: a sighting
# on a run that cannot be tied to a source state cannot be dated against
# a fix, and one was not.
built=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
[ -z "$(git status --porcelain -- src 2>/dev/null)" ] || built="$built-dirty"
[ -f "$KO" ] || { echo "enospc: FAIL: $KO was not produced"; exit 1; }

rm -f "$IMG"
truncate -s "$SIZE" "$IMG" || exit 2
"$NEWFS" -L "$LABEL" "$IMG" >/dev/null 2>&1 || {
	echo "enospc: COULD-NOT-RUN: newfs_hammer2 failed" >&2; exit 2; }

started=no
# A domain listed as running can be one another script is still shutting
# down, which refuses ssh for as long as that takes; the fuzzer read that
# state as usable once and spent its whole wait on it. The guest is usable
# when it answers, so ask that first and the domain only when it does not.
if ssh -o ConnectTimeout=3 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null; then
	:
elif $VIRSH domstate "$GUEST" 2>/dev/null | grep -q running; then
	echo "enospc: COULD-NOT-RUN: $GUEST is listed running but does not answer ssh; it may be shutting down" >&2
	exit 2
else
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
	# BEFORE the unmount, because a bad unmount is where the evidence is
	# lost. The capture itself runs on across the unmount.
	: > /tmp/kmsg.log
	# Unbuffered, because cat block-buffers to a file: a line the kernel
	# prints during the unmount can still be sitting in the buffer when
	# this script greps for it, which reads as a line that was never
	# printed. Which form ran is reported, so a run says whether its
	# late lines can be trusted rather than leaving that to be assumed.
	if command -v stdbuf >/dev/null 2>&1; then
		stdbuf -o0 cat /dev/kmsg > /tmp/kmsg.log 2>/dev/null &
		kpid=$!
		echo "kmsg capture unbuffered"
	else
		cat /dev/kmsg > /tmp/kmsg.log 2>/dev/null &
		kpid=$!
		echo "kmsg capture buffered, late lines may be missing"
	fi
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
	# What the callers of fsync(2) and syncfs(2) are told about a volume
	# that has just refused a write. Measurements, not checks: the sync
	# path discards its errors under XXX comments in every tree this
	# port carries from, and this records what reaches userspace.
	# The refused write may have failed at open, leaving no file, so
	# the fsync goes to the last file that exists, and the error text
	# is kept, because an exit status of 1 from a missing path and one
	# from a failed fsync read the same.
	last=/mnt/h2enospc/fill.$i
	[ -e "$last" ] || last=/mnt/h2enospc/fill.$((i - 1))
	msg=$(sync "$last" 2>&1)
	echo "fsync of the last file returned $? ${msg:+: $msg}"
	msg=$(sync -f /mnt/h2enospc 2>&1)
	echo "syncfs returned $? ${msg:+: $msg}"
	sync
	echo "locks after sync $(sed -n "s/^ *debug_locks: *//p" /proc/lockdep_stats)"
	# The capture is NOT stopped here. Reading the log does not require
	# stopping it, and stopping it closed the window before the unmount,
	# so every message the unmount produces was invisible: the counters
	# the driver prints from ->kill_sb, a busy-inode warning, an
	# out-of-memory kill, a lockdep report during teardown. Everything
	# derived from the log below is still printed BEFORE the unmount,
	# which is the reason this ordering exists; the capture simply runs
	# on until the unmount is over.

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
	echo "shutdown-reason $(command grep -m1 -o "BUG: MAX_[A-Z_]* too low!\|possible circular locking dependency\|bad unlock balance\|held lock freed" /tmp/kmsg.log || echo none-found)"
	# A run that cannot name what shut lockdep down is refused rather than
	# scored, and a refusal that cannot say why costs a full fill and
	# teaches nothing. Print what the log holds whenever the four banners
	# above did not match, so the next reader starts from the evidence
	# instead of another reproduction. The kernel killing a process out
	# from under this script reads as a driver failure otherwise, so it is
	# counted whether or not anything else went wrong.
	echo "oom kills $(command grep -c "Out of memory: Killed\|oom-kill:" /tmp/kmsg.log || true)"
	echo "drop-with-lock warns $(command grep -c "holds its lock" /tmp/kmsg.log || true)"
	if [ "$(sed -n "s/^ *debug_locks: *//p" /proc/lockdep_stats)" = 0 ] &&
	   ! command grep -q "BUG: MAX_[A-Z_]* too low!\|possible circular locking dependency\|bad unlock balance\|held lock freed" /tmp/kmsg.log; then
		echo "=== unattributed begins"
		# head succeeds on empty input, so the emptiness is tested rather
		# than left to a || that could never fire.
		u=$(command grep -o "WARNING:.*\|BUG:.*\|INFO: task.*\|Out of memory:.*\|oom-kill:.*\|turning off the locking correctness validator.*" /tmp/kmsg.log | head -20)
		if [ -n "$u" ]; then
			printf "%s\n" "$u"
		else
			echo "the log holds no kernel fault line at all"
		fi
		echo "=== unattributed ends"
	fi

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
	# Follow whichever banner fired, not the cycle alone: a run whose
	# fault is a different one printed an empty section and read as a run
	# with nothing to show.
	command sed -n "/$(command grep -m1 -o "BUG: MAX_[A-Z_]* too low!\|possible circular locking dependency\|bad unlock balance\|held lock freed" /tmp/kmsg.log || echo possible circular locking dependency)/,+220p" /tmp/kmsg.log |
	    command sed "s/^[0-9,;]*;//"
	echo "=== first report ends"

	# An unmount that does not finish writes no report of its own, and a
	# deadlock and a loop making no progress leave the same exit status
	# behind. Sample the unmount twice: cumulative CPU that moves between
	# the samples is a loop, and cumulative CPU that stands still in D
	# state is a lock nobody will release. sysrq-w asks the kernel for the
	# stack of every blocked task, which lands in the kmsg stream this
	# script already captures. Nothing below may report by staying silent:
	# a stack that cannot be read and a dump that never arrived each say
	# so. Note there is not a single quote anywhere in this block, which
	# is itself one quoted string.
	# This script streams /dev/kmsg into /tmp, which is tmpfs and so is
	# RAM, while filling a 2 GiB volume. Report what is left and what the
	# capture cost, because a guest killed for memory by its own harness
	# reads as a driver that hung the unmount.
	echo "mem available $(sed -n "s/^MemAvailable: *//p" /proc/meminfo)"
	echo "kmsg capture $(wc -c < /tmp/kmsg.log) bytes"
	ustart=$(cut -d. -f1 /proc/uptime)
	umount /mnt/h2enospc & upid=$!
	for at in 15 30; do
		sleep 15
		if [ ! -d /proc/$upid ]; then
			echo "umount left at or before ${at}s"
			break
		fi
		set -- $(cat /proc/$upid/stat)
		echo "umount at ${at}s state ${3} cpu $((${14} + ${15}))"
		if [ -r /proc/$upid/stack ]; then
			command sed "s/^/  umount stack /" /proc/$upid/stack
		else
			echo "  umount stack is not readable"
		fi
	done
	if [ -d /proc/$upid ]; then
		echo w > /proc/sysrq-trigger 2>/dev/null
		sleep 5
		if command grep -q "Show Blocked State" /tmp/kmsg.log; then
			echo "=== blocked tasks begin"
			command sed -n "/Show Blocked State/,$p" /tmp/kmsg.log |
			    command sed "s/^[0-9,;]*;//" | head -80
			echo "=== blocked tasks end"
		else
			echo "blocked-task dump did not appear, so sysrq-w is off"
		fi
		kill -9 $upid 2>/dev/null
		echo "umount 137"
	else
		wait $upid; echo "umount $?"
	fi
	# Printed on every run, so a run that does not hang still reports how
	# close it came rather than nothing at all.
	echo "umount took $(( $(cut -d. -f1 /proc/uptime) - ustart ))s"
	# The oom count above is read before the unmount and so cannot see a
	# kill during it, which is where the unmount has been dying. Read it
	# again here, and show the end of the log whenever the unmount did not
	# return cleanly, since a process killed by something this script does
	# not name reads as a driver that hung.
	echo "oom kills after umount $(command grep -c "Out of memory: Killed\|oom-kill:\|Killed process" /tmp/kmsg.log || true)"
	# Whether the unmount was signalled and whether the filesystem went
	# away are different questions, and rmmod failing answers neither.
	# The failures downstream of an oops all describe the wreckage:
	# the module will not unload because the superblock survives
	# because the unmount died. Name the fault itself.
	echo "oops $(command grep -c "Oops: " /tmp/kmsg.log || true)"
	# Scoped to the oops. Taking the first match in the whole log reads
	# a RIP and an RCX out of whatever unrelated warning came first,
	# and it did: a healthy run reported a faulting address belonging
	# to a page-allocator warning it had printed hours of writing
	# earlier.
	command sed -n "/Oops: /,\$p" /tmp/kmsg.log > /tmp/oops.log
	echo "faulted in $(command grep -m1 -o "RIP: [0-9]*:[a-zA-Z0-9_]*+0x[0-9a-f]*" /tmp/oops.log || echo nowhere)"
	echo "faulted on $(command grep -m1 -o "page fault for address: [0-9a-f]*" /tmp/kmsg.log || echo nothing)"
	# Debug builds only: which PFS the teardown released, and which the
	# oops faulted on, in the same units so they can be compared.
	echo "faulting rcx $(command grep -m1 -o "RCX: [0-9a-f]*" /tmp/oops.log || echo none)"
	command grep -o "freeing pmp [0-9a-fx]*\|pfsfree_scan which [0-9] syncing pmp [0-9a-fx]*" \
	    /tmp/kmsg.log | tail -12
	# Which chain carries the dead pointer. The oops reports the
	# address and the instruction and nothing about the chain.
	echo "chains on a freed pmp $(command grep -c "holds freed pmp" /tmp/kmsg.log || true)"
	command grep -o "[a-z]* chain [0-9a-f]*/[0-9]* holds freed pmp, flags [0-9a-f]*" \
	    /tmp/kmsg.log | sort | uniq -c | head -6
	echo "still mounted $(command grep -c h2enospc /proc/mounts || true)"
	echo "module refs $(cat /sys/module/hammer2/refcnt 2>/dev/null || echo unreadable)"
	# What the module still holds, printed by the driver at unmount
	# because the check that reads these counters runs at unload and an
	# unload that is refused never reaches it.
	# The driver prints this at the END of ->kill_sb. No line on a run
	# whose module will not unload therefore says that function did not
	# get that far, which is what a fault inside it looks like; it does
	# not say the counters were clean, and it does not say the
	# superblock was never touched. The backtrace below says which.
	o=$(command grep -o "after unmount: .*" /tmp/kmsg.log | tail -1)
	if [ -n "$o" ]; then
		echo "outstanding $o"
	else
		echo "outstanding no line, so kill_sb did not reach its end"
	fi
	echo "busy inodes $(command grep -c "Busy inodes after unmount\|VFS: Busy" /tmp/kmsg.log || true)"
	echo "=== log tail begins"
	# Wide enough for a whole backtrace. At 25 lines this window cut
	# the head off the one oops that explains the failure and left the
	# register dump with nothing above it, on a guest since reset.
	tail -150 /tmp/kmsg.log | command sed "s/^[0-9,;]*;//"
	echo "=== log tail ends"
	timeout 30 rmmod hammer2; echo "rmmod $?"
	kill $kpid 2>/dev/null
' 2>&1)
echo "  built from $built"
printf '%s\n' "$out" | sed 's/^/  /'
$VIRSH detach-disk "$GUEST" vdb >/dev/null 2>&1
[ "$started" = yes ] && $VIRSH shutdown "$GUEST" >/dev/null 2>&1

# A guest left wedged by a previous run of this very script cannot load
# the module, and that is COULD-NOT-RUN rather than five failures
# describing a filesystem that was never mounted. The defect this script
# reproduced killed the unmount, so a guest left holding the module is a
# plausible state after a failing run and has to be told apart from the
# defect itself.
if printf '%s\n' "$out" | command grep -q '^SETUP '; then
	printf '%s\n' "$out" | sed -n 's/^SETUP /enospc: COULD-NOT-RUN: /p' >&2
	echo "          $GUEST may still hold the module from an earlier run;" >&2
	echo "          it needs a hard reset; a run that faults leaves it so" >&2
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

# The unmount is judged by whether the filesystem went away, not by the
# exit status of a process: on these runs the unmount completes and the
# process is then killed by something outside this script, which read as
# an unmount that never finished for as long as the status was the only
# thing being asked.
# An oops is the finding; everything below it is what the oops caused.
printf '%s\n' "$out" | command grep -q '^oops 0$' ||
	{ echo "  FAIL  the kernel faulted during this run:"
	  printf '%s\n' "$out" | sed -n 's/^oops /        oops count /p'
	  printf '%s\n' "$out" | sed -n 's/^faulted in /        at /p'
	  fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q '^still mounted 0$' ||
	{ echo "  FAIL  the filesystem is still mounted after the unmount"
	  fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q '^umount 0$' ||
	{ echo "  note  the unmount process did not exit 0:"
	  printf '%s\n' "$out" | sed -n 's/^umount \([0-9]*\)$/        status \1/p'
	  printf '%s\n' "$out" | sed -n 's/^still mounted /        still mounted /p'; }
printf '%s\n' "$out" | grep -q '^rmmod 0$' ||
	{ echo "  FAIL  the module could not be removed, so it still holds"
	  echo "        references after the filesystem unmounted:"
	  printf '%s\n' "$out" | sed -n 's/^module refs /        refcnt /p'
	  fail=$((fail + 1)); }

make -s clean >/dev/null 2>&1
echo "enospc: filled $SIZE, $fail failure(s)"
[ "$fail" -eq 0 ]
