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
CYCLES=${H2_STORM_CYCLES:-1}
# A 4 KiB cell write costs about 80 KiB of allocation here: the write
# allocates a new 64 KiB block and the inode's indirect blocks are
# rewritten beside it, and nothing is freed until bulkfree runs.  A cycle
# is therefore sized from the volume rather than from the clock, because
# a cycle that outruns the allocator dies on the reserve check and its
# checks are then about a run that was cut off.  The budget is a tenth of
# the volume, which leaves the reserve and the metadata room.
#
# The op RATE is not a constant: it is whatever the load does on the
# machine, and a cycle sized from an assumed rate is a cycle that either
# wastes the budget or overruns it.  The first cycle therefore runs for
# PROBE seconds and its own cost counter says what a second of this load
# spends; every cycle after it gets the seconds that budget buys at that
# measured rate.  H2_STORM_PEROP overrides the per-op cost, which is the
# only figure that is a property of the format rather than of the run.
PEROP=${H2_STORM_PEROP:-81920}
PROBE=${H2_STORM_PROBE:-5}
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2}
FSCK=${H2_FSCK:-$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2}
KO=src/sys/fs/hammer2/hammer2.ko

case $SECS in ''|*[!0-9]*) echo "storm: COULD-NOT-RUN: H2_STORM_SECS is not a number" >&2; exit 2 ;; esac
case $CYCLES in ''|0|*[!0-9]*) echo "storm: COULD-NOT-RUN: H2_STORM_CYCLES is not a positive number" >&2; exit 2 ;; esac
case $PEROP in ''|0|*[!0-9]*) echo "storm: COULD-NOT-RUN: H2_STORM_PEROP is not a positive number" >&2; exit 2 ;; esac
case $PROBE in ''|0|*[!0-9]*) echo "storm: COULD-NOT-RUN: H2_STORM_PROBE is not a positive number" >&2; exit 2 ;; esac
# The volume's size in bytes, so the budget is a fraction of the volume
# the run was actually given and not of a size named here.
case $SIZE in
*G|*g) VOL=$(( ${SIZE%[Gg]} * 1024 * 1024 * 1024 )) ;;
*M|*m) VOL=$(( ${SIZE%[Mm]} * 1024 * 1024 )) ;;
*K|*k) VOL=$(( ${SIZE%[Kk]} * 1024 )) ;;
*) VOL=$SIZE ;;
esac
case $VOL in ''|0|*[!0-9]*) echo "storm: COULD-NOT-RUN: H2_STORM_SIZE=$SIZE is not a size" >&2; exit 2 ;; esac
# A cycle may spend half the volume, data and meta together.  Every cycle
# is bulkfreed and removed before the next, so nothing carries over, but
# the probe's rate is lower than a full cycle's (the load is still ramping
# in its first seconds) and the allocator keeps a twentieth in reserve.
# At four fifths of data alone, a 24-cycle run on 8G spent 7.95 GB a cycle
# against 7.81 usable and lost 9 cycles to ENOSPC by chance.
BUDGET=$((VOL / 2))
echo "storm: a cycle may spend $BUDGET B of $VOL B"
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
ALLOC=/sys/module/hammer2/parameters
[ -r "$ALLOC/alloc_data_bytes" ] || { echo "SETUP the module has no alloc counters, so a cycle cost cannot be read"; exit 0; }
echo "before: $(mem)"
# A cell rewritten in place costs a block, and nothing is freed until
# bulkfree has run twice, so a fixed set of files fills any volume: an
# 8G one in about a minute of this load.  Each cycle therefore runs for
# a bounded time, is checked after a remount, and is then reclaimed by
# the two bulkfree passes that are the only way this filesystem frees.
# The set is removed after the passes, not before, because a remove on
# a full volume is refused by the reserve check upstream carries too.
for cyc in $(seq 1 NCYC); do
	echo "== cycle $cyc of NCYC"
	# df reads voldata.allocator_free, which only bulkfree recomputes,
	# so it reports the number the last bulkfree left and not what a run has
	# spent.  The module counters move on every allocation and are
	# the reading the cost of a cycle is taken from.
	d0=$(($(cat $ALLOC/alloc_data_bytes) + $(cat $ALLOC/alloc_meta_bytes)))
	echo "cost before cycle $cyc: data $(cat $ALLOC/alloc_data_bytes) meta $(cat $ALLOC/alloc_meta_bytes)"
	# The first cycle is the probe: it runs for PROBE seconds and what it
	# spent is what a second of this load costs, which sizes every cycle
	# after it.  An assumed rate is a rate that is wrong on the machine
	# the run is on.
	if [ "$cyc" = 1 ]; then runsecs=PROBESEC; else runsecs=$cycsecs; fi
	/tmp/h2storm /mnt/storm $runsecs FILES
	echo "run exit $?"
	d1=$(($(cat $ALLOC/alloc_data_bytes) + $(cat $ALLOC/alloc_meta_bytes)))
	spent=$((d1 - d0))
	[ "$spent" -gt "${maxspent:-0}" ] && maxspent=$spent
	echo "cycle spend $spent B, most any cycle spent ${maxspent:-0} B of BUDGET B"
	if [ "$cyc" = 1 ]; then
		rate=$((spent / PROBESEC))
		[ "$rate" -gt 0 ] || rate=1
		# The probe is the first seconds of the load and its rate is lower
		# than the steady one, so a cycle sized from it alone overruns.
		# The budget is halved for that, which covers the ramp measured
		# on 2026-10-08 (6.7 GB in the first full cycle against 7.2 GB
		# once the four write roles had all started).
		cycsecs=$((BUDGET / rate))
		[ "$cycsecs" -ge 1 ] || cycsecs=1
		echo "probe: $spent B in PROBESEC s is $rate B/s, so $cycsecs s per cycle"
	fi
	umount /mnt/storm; echo "umount exit $?"
	sync; echo 3 > /proc/sys/vm/drop_caches
	mount -t hammer2 /dev/vdb@STORM /mnt/storm || { echo "SETUP remount failed"; exit 0; }
	/tmp/h2storm --verify /mnt/storm FILES | sed "s/^storm-/verify-/"
	for n in 1 2; do
		hammer2 -s /mnt/storm bulkfree /mnt/storm >/dev/null 2>&1
		echo "bulkfree $n of cycle $cyc exit $?"
		sync
	done
	rm -f /mnt/storm/storm.*; echo "remove of cycle $cyc exit $?"
	sync
	echo "cost after cycle $cyc: data $(cat $ALLOC/alloc_data_bytes) meta $(cat $ALLOC/alloc_meta_bytes)"
	umount /mnt/storm; echo "second umount exit $?"
	if [ "$cyc" -lt NCYC ]; then
		mount -t hammer2 /dev/vdb@STORM /mnt/storm || { echo "SETUP remount failed"; exit 0; }
	fi
done
rmmod hammer2; echo "rmmod exit $?"
echo "after unload: $(mem)"
echo "log: bug $(dmesg | grep -c "kernel BUG") oops $(dmesg | grep -ci oops) warn $(dmesg | grep -c "WARNING:") kasan $(dmesg | grep -c "BUG: KASAN") ubsan $(dmesg | grep -c "UBSAN:") lockdep $(dmesg | grep -c "possible circular locking")"
'
run=$(printf '%s' "$run" | sed "s/SECS/$SECS/; s/FILES/$FILES/g; s/NCYC/$CYCLES/g; s/PROBESEC/$PROBE/g; s/BUDGET/$BUDGET/g")
# The bound is each cycle's run, a fifth of it again, and ten minutes
# for its remount, checks and two bulkfree passes: one 300 s cycle is
# called hung at 960 s, where an hour's margin once let a hang sit
# unread for an hour.  H2_STORM_BOUND overrides.
BOUND=${H2_STORM_BOUND:-$((CYCLES * (SECS + SECS / 5 + 600)))}
echo "storm: $CYCLES cycles of $SECS s, called hung at $BOUND s"
out=$(timeout "$BOUND" ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=8 "$GUEST_SSH" "$run" 2>&1)
rc=$?
printf '%s\n' "$out" | sed 's/^/  /'
if [ "$rc" -eq 124 ]; then
	# What the guest holds is read before anything is torn down, through
	# the agent since ssh may be wedged with the mount: the workers'
	# CPU time and wait channel tell a spin from a sleep, and the sysrq
	# dumps say what each is waiting on.
	echo "storm: FAIL: the guest did not finish within $BOUND s"
	sh "$(dirname "$0")/guest-dmesg.sh" "$GUEST" 2>&1 | sed 's/^/  hang    /'
	detach
	exit 1
fi
detach
case $out in *SETUP*) echo "storm: COULD-NOT-RUN: $(printf '%s\n' "$out" | command grep -m1 SETUP)" >&2; exit 2 ;; esac

fail=0
# A worker that died is named with its role and signal by the exerciser.
printf '%s\n' "$out" | command grep '^storm-fail worker ' | sed 's/^/  FAIL  /'
# Each per-cycle line has to appear once per cycle and every one of them
# has to read clean: a grep for one clean line would pass a run whose
# first cycle was clean and whose last was not.
for want in '^storm-failures 0$' '^verify-failures 0$' '^run exit 0$' '^umount exit 0$' \
    '^second umount exit 0$' '^bulkfree 1 of cycle [0-9]* exit 0$' \
    '^bulkfree 2 of cycle [0-9]* exit 0$' '^remove of cycle [0-9]* exit 0$'; do
	n=$(printf '%s\n' "$out" | command grep -c "$want")
	[ "$n" -eq "$CYCLES" ] || {
		echo "  FAIL  $n lines matching $want where $CYCLES are wanted"; fail=$((fail + 1)); }
done
for want in '^rmmod exit 0$' '^log: bug 0 oops 0 warn 0 kasan 0 ubsan 0 lockdep 0$'; do
	printf '%s\n' "$out" | command grep -q "$want" || {
		echo "  FAIL  no line matching $want"; fail=$((fail + 1)); }
done
printf '%s\n' "$out" | command grep '^cost after cycle ' | sed 's/^/  note  /'
# Each cycle has to have spent data and meta bytes: a cycle whose counters
# did not move is a cycle that allocated nothing, which would make its
# clean checks a reading about an idle filesystem.  The per-op figure is
# printed because it is the amplification this load costs, and a change
# in it is what a write-path regression looks like from here.
for cyc in $(seq 1 "$CYCLES"); do
	d=$(printf '%s\n' "$out" | sed -n "s/^cost after cycle $cyc: data \([0-9]*\) .*/\1/p")
	[ -n "$d" ] || d=0
	[ "$d" -gt 0 ] || { echo "  FAIL  cycle $cyc allocated no data bytes"; fail=$((fail + 1)); }
done
# A run whose roles did nothing would pass every check above, so each
# role's count is required to be non-zero here as well as in the exerciser.
printf '%s\n' "$out" | command grep -q '^storm-ops .* 0$' && {
	echo "  FAIL  a role completed no operation"; fail=$((fail + 1)); }
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "  ok    fsck_hammer2 clean after the run" || {
	echo "  FAIL  fsck_hammer2 after the run"; fail=$((fail + 1)); }
echo "storm: $CYCLES cycles of $SECS s over $FILES files, $fail failures"
[ "$fail" -eq 0 ]

