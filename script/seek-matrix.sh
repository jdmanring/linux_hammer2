#!/bin/sh
# SEEK_DATA and SEEK_HOLE across a snapshot, a hard stop and a dedup,
# the three cases of P1 that need the guest's lifecycle rather than a
# file on a mounted volume. test/hammer2-seek.c on the enospc gate owns
# the rest: unsynced, boundary, regrown, mapped and compressed.
#
# Each answer is checked against a file whose shape the guest just made:
# one 64 KiB block of data, one of hole, one of data, a truncate past it.
#
#   snapshot  the file is written and not synced, and a snapshot taken.
#             The snapshot ioctl syncs the filesystem first (the
#             non-NOSYNC branch of hammer2_ioctl_pfs_snapshot()), so the
#             snapshot holds the data and both trees answer with it.
#   crash     a file synced, then a second written on top of it and not
#             synced, then a hard stop. The synced prefix answers in
#             full after the reboot, and the file itself still exists, so
#             agree() reads the recovered file: no range SEEK_HOLE calls
#             a hole may read back nonzero. That is the branch the case
#             is for, and it only runs if the file survives, so what was
#             synced is a prefix that stays.
#   dedup     two files of 16 incompressible blocks, the second asked
#             while unsynced and again once its blocks have deduplicated
#             against the first's. That they did is read from the free
#             count, as test/hammer2-dedup.c reads it: the second file
#             must cost under a quarter of what the first did, or the
#             case is about nothing. Sixteen blocks rather than the seek
#             shape's three, because a first file costing one block makes
#             the rule pass without the sharing being measured.
#
# Two modes replace the three cases and stop no guest:
#
#   H2_SEEK_RACE=1  a truncate aimed inside a held SEEK_HOLE (seekprobe
#                   race). The module is built with HAMMER2_LOCKDEBUG=1
#                   and seek_hold_ms=300 holds the seek after it reads
#                   i_size. The line says whether the truncate returned
#                   inside the seek or after it, and the answer; the
#                   check is only that the hold ran (its klog line, and
#                   the seek taking 250 ms or more), since the answer is
#                   the reading. H2_SEEK_RACE_WANT=inside|after makes
#                   the ordering a check.
#   H2_SEEK_TIME=1  the cost of a seek (seekprobe time), sparse, dense
#                   and dirty, each H2_REPEAT times (5 by default) on a
#                   file made once per repeat; raw lines and medians,
#                   checked only for right answers. A rate, so run it on
#                   h2release-7.3tls.
#
# H2_KO loads a module built elsewhere instead of building one. H2_REPEAT
# repeats the race too (1 by default); the three cases ignore it, so it is
# refused there.
#
# Exit 2 without the guest, newfs_hammer2 or a kernel tree, never 1.
set -u
cd "$(dirname "$0")/.." || exit 2
FIXDIR=${H2_FIXTURE_DIR:-$HOME/Projects/linux_hammer2-data/fixtures}
IMG=$FIXDIR/seek-matrix.img
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2}
FSCK=${H2_FSCK:-$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2}
KO=src/sys/fs/hammer2/hammer2.ko
RACE=${H2_SEEK_RACE:-0}
TIME=${H2_SEEK_TIME:-0}
case "$RACE$TIME" in
00) [ -z "${H2_REPEAT:-}" ] || { echo "seek-matrix: COULD-NOT-RUN: H2_REPEAT needs H2_SEEK_RACE=1 or H2_SEEK_TIME=1" >&2; exit 2; } ;;
10|01) ;;
*) echo "seek-matrix: COULD-NOT-RUN: H2_SEEK_RACE and H2_SEEK_TIME are 0 or 1, one at a time" >&2; exit 2 ;;
esac
REPEAT=${H2_REPEAT:-$([ "$TIME" = 1 ] && echo 5 || echo 1)}
case "$REPEAT" in ''|*[!0-9]*|0) echo "seek-matrix: COULD-NOT-RUN: H2_REPEAT=$REPEAT is not a count" >&2; exit 2 ;; esac
WANT=${H2_SEEK_RACE_WANT:-}
case "$WANT" in ''|inside|after) ;; *) echo "seek-matrix: COULD-NOT-RUN: H2_SEEK_RACE_WANT is inside or after" >&2; exit 2 ;; esac

[ -x "$NEWFS" ] || { echo "seek-matrix: COULD-NOT-RUN: no newfs_hammer2 at $NEWFS" >&2; exit 2; }
[ -x "$FSCK" ] || { echo "seek-matrix: COULD-NOT-RUN: no fsck_hammer2 at $FSCK" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "seek-matrix: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -f "$KDIR/Makefile" ] || { echo "seek-matrix: COULD-NOT-RUN: KDIR=$KDIR is not a kernel tree" >&2; exit 2; }
command -v virsh >/dev/null 2>&1 || { echo "seek-matrix: COULD-NOT-RUN: no virsh" >&2; exit 2; }
if [ -n "${H2_KO:-}" ]; then
	[ -f "$H2_KO" ] || { echo "seek-matrix: COULD-NOT-RUN: no module at H2_KO=$H2_KO" >&2; exit 2; }
	KO=$H2_KO
elif [ "$RACE" = 1 ]; then
	HAMMER2_LOCKDEBUG=1 make KDIR="$KDIR" >/dev/null 2>&1 || { echo "seek-matrix: FAIL: the module does not build against $KDIR"; exit 1; }
else
	make KDIR="$KDIR" >/dev/null 2>&1 || { echo "seek-matrix: FAIL: the module does not build against $KDIR"; exit 1; }
fi
[ -f "$KO" ] || { echo "seek-matrix: FAIL: $KO was not produced"; exit 1; }
echo "  module $KO sha256 $(sha256sum "$KO" | cut -c1-16) head $(git rev-parse --short HEAD) src-dirty $(git status --porcelain -- src | wc -l)"
cc -static -O2 -o /tmp/h2seekprobe.$$ test/hammer2-seekprobe.c 2>/dev/null || {
	echo "seek-matrix: COULD-NOT-RUN: the seek probe did not compile" >&2; exit 2; }
trap 'rm -f /tmp/h2seekprobe.$$' EXIT

guest_up() {
	i=0
	while [ "$i" -lt 60 ]; do
		ssh -o ConnectTimeout=4 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null && return 0
		sleep 5; i=$((i + 1))
	done
	return 1
}
guest_up || { echo "seek-matrix: COULD-NOT-RUN: $GUEST does not answer ssh" >&2; exit 2; }
guest_rel=$(ssh "$GUEST_SSH" 'uname -r' 2>/dev/null)
ko_rel=$(modinfo -F vermagic "$KO" 2>/dev/null | awk '{print $1}')
[ "$guest_rel" = "$ko_rel" ] || {
	echo "seek-matrix: COULD-NOT-RUN: the module is for $ko_rel and $GUEST runs $guest_rel" >&2; exit 2; }
# One lockdep report turns lockdep off until the next boot, and a run
# on that boot reads "no report" with nothing checking.
dl=$(ssh -o BatchMode=yes "$GUEST_SSH" "awk '/debug_locks:/ {print \$2}' /proc/lockdep_stats 2>/dev/null")
[ "$dl" = 0 ] && {
	echo "seek-matrix: COULD-NOT-RUN: lockdep is off on $GUEST since an earlier report; boot it again" >&2; exit 2; }

rm -f "$IMG"
truncate -s 1G "$IMG" && "$NEWFS" -L SM "$IMG" >/dev/null 2>&1 || {
	echo "seek-matrix: COULD-NOT-RUN: newfs_hammer2 failed" >&2; exit 2; }
attach() {
	$VIRSH attach-disk "$GUEST" "$IMG" vdb --targetbus virtio >/dev/null 2>&1 &&
	    ssh "$GUEST_SSH" 'i=0; while [ ! -b /dev/vdb ] && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done; [ -b /dev/vdb ]'
}
detach() { $VIRSH detach-disk "$GUEST" vdb --live >/dev/null 2>&1; $VIRSH detach-disk "$GUEST" vdb --config >/dev/null 2>&1; }
detach
attach || { echo "seek-matrix: COULD-NOT-RUN: could not attach $IMG" >&2; exit 2; }
scp -q "$KO" "$GUEST_SSH:/tmp/h2.ko" && scp -q /tmp/h2seekprobe.$$ "$GUEST_SSH:/tmp/h2seekprobe" || {
	detach; echo "seek-matrix: COULD-NOT-RUN: copy to the guest failed" >&2; exit 2; }

# The two modes: one mounted volume, no stop, then the verdict and exit.
mode_open='
dmesg -C
insmod /tmp/h2.ko || { echo "SETUP insmod failed"; exit 0; }
mkdir -p /mnt/sm
mount -t hammer2 /dev/vdb@SM /mnt/sm || { echo "SETUP mount failed"; exit 0; }
'
mode_close='
umount /mnt/sm; echo "umount exit $?"
rmmod hammer2; echo "rmmod exit $?"
echo "log: bug $(dmesg | grep -c "kernel BUG") oops $(dmesg | grep -ci oops) warn $(dmesg | grep -c "WARNING:")"
echo "debug_locks $(awk "/debug_locks:/ {print \$2}" /proc/lockdep_stats 2>/dev/null)"
'
race_body='
K=/sys/module/hammer2/parameters/seek_hold_ms
[ -e $K ] || { echo "SETUP knob failed: no seek_hold_ms, the module was built without HAMMER2_LOCKDEBUG"; umount /mnt/sm; rmmod hammer2; exit 0; }
echo 300 > $K
i=0; while [ $i -lt $REPEAT ]; do /tmp/h2seekprobe race /mnt/sm/race; rm -f /mnt/sm/race; i=$((i + 1)); done
echo 0 > $K
echo "held $(dmesg | grep -c "hammer2: seek held")"
'
time_body='
for k in sparse dense dirty; do
	case $k in dense) n=1000 ;; *) n=100 ;; esac
	i=0; while [ $i -lt $REPEAT ]; do /tmp/h2seekprobe time /mnt/sm/t $k $n; i=$((i + 1)); done
done
'
if [ "$RACE$TIME" != 00 ]; then
	if [ "$RACE" = 1 ]; then body=$race_body; else body=$time_body; fi
	out=$(ssh "$GUEST_SSH" "REPEAT=$REPEAT; $mode_open $body $mode_close" 2>&1)
	printf '%s\n' "$out" | command grep -v '^seekm-time [a-z]* [0-9]* ' | sed 's/^/  /'
	detach
	"$FSCK" "$IMG" >/dev/null 2>&1; fsck_rc=$?
	fail=0
	case $out in *SETUP*failed*) echo "  FAIL  $(printf '%s\n' "$out" | command grep -m1 'SETUP.*failed')"; fail=$((fail + 1)) ;; esac
	for want in "^umount exit 0$" "^rmmod exit 0$" "^log: bug 0 oops 0 warn 0$" "^debug_locks 1$"; do
		printf '%s\n' "$out" | command grep -q "$want" || {
			echo "  FAIL  no line matching $want"; fail=$((fail + 1)); }
	done
	bad=$(printf '%s\n' "$out" | command grep -c '^seekm-fail')
	[ "$bad" -eq 0 ] || { echo "  FAIL  $bad seekm-fail line(s)"; fail=$((fail + 1)); }
	if [ "$RACE" = 1 ]; then
		lines=$(printf '%s\n' "$out" | command grep '^seekm-race ')
		n=$(printf '%s\n' "$lines" | command grep -c '^seekm-race ')
		[ "$n" -eq "$REPEAT" ] || { echo "  FAIL  $n race line(s) for $REPEAT run(s)"; fail=$((fail + 1)); }
		printf '%s\n' "$out" | command grep -q '^held 1$' || {
			echo "  FAIL  the seek hold did not print once, so nothing held"; fail=$((fail + 1)); }
		short=$(printf '%s\n' "$lines" | awk '$5 < 250' | wc -l)
		[ "$short" -eq 0 ] || { echo "  FAIL  $short seek(s) returned under 250 ms, so the hold did not run in them"; fail=$((fail + 1)); }
		if [ -n "$WANT" ]; then
			off=$(printf '%s\n' "$lines" | awk -v w="$WANT" '$9 != w' | wc -l)
			[ "$off" -eq 0 ] || { echo "  FAIL  $off of $n truncate(s) not $WANT the seek"; fail=$((fail + 1)); }
		fi
		echo "  race: $(printf '%s\n' "$lines" | awk '{print $9}' | sort | uniq -c | tr -s ' ' | tr '\n' ';') answers $(printf '%s\n' "$lines" | awk '{print $3}' | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
	else
		for k in sparse dense dirty; do
			m=$(printf '%s\n' "$out" | sed -n "s/^seekm-time $k median-ns \([0-9]*\) n .*/\1/p")
			c=$(printf '%s\n' "$m" | command grep -c .)
			[ "$c" -eq "$REPEAT" ] || { echo "  FAIL  $c $k median(s) for $REPEAT repeat(s)"; fail=$((fail + 1)); }
			echo "  time $k median-ns per repeat: $(printf '%s\n' "$m" | tr '\n' ' ')median of medians $(printf '%s\n' "$m" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')"
		done
		raw=$(printf '%s\n' "$out" | command grep -c '^seekm-time [a-z]* [0-9]* ')
		echo "  time: $raw raw seek line(s) kept below"
		printf '%s\n' "$out" | command grep '^seekm-time [a-z]* [0-9]* ' | sed 's/^/  raw /'
	fi
	[ "$fsck_rc" -eq 0 ] && echo "  ok    fsck_hammer2 clean" || {
		echo "  FAIL  fsck_hammer2 exit $fsck_rc"; fail=$((fail + 1)); }
	echo "seek-matrix: $([ "$RACE" = 1 ] && echo race || echo time), $REPEAT repeat(s), $fail failure(s)"
	rm -f "$IMG"
	[ "$fail" -eq 0 ]
	exit
fi

# Phase one, on the running guest: snapshot and dedup, then the crash
# setup ending in the write the hard stop interrupts. Every line the
# guest prints is prefixed with what it reports so the host counts it.
# The two guest scripts are named values rather than literals after the
# ssh command, because test-posix.sh reads a remote block as the text from
# an ssh invocation's opening quote to the next line that is a lone quote.
# A second literal block in one file would be read as part of the first
# and its own quotes counted against it. Passing the script as a variable
# keeps each block a single-quoted string with no quote of its own inside
# it, which is the property that gate is there to check.
pre_stop='
dmesg -C
insmod /tmp/h2.ko || { echo "SETUP insmod failed"; exit 0; }
mkdir -p /mnt/sm
mount -t hammer2 /dev/vdb@SM /mnt/sm || { echo "SETUP mount failed"; exit 0; }
P=/tmp/h2seekprobe
$P make /mnt/sm/live
hammer2 snapshot /mnt/sm SNAP >/dev/null 2>&1; echo "snapshot exit $?"
$P check /mnt/sm/live "live after the snapshot"
mkdir -p /mnt/snap
mount -t hammer2 /dev/vdb@SNAP /mnt/snap || echo "seekm-fail the snapshot did not mount"
$P check /mnt/snap/live "the snapshot"
umount /mnt/snap
free() { stat -f -c %f /mnt/sm; }
sync -f /mnt/sm; f0=$(free)
$P dedup /mnt/sm/dedup-a 16
sync -f /mnt/sm; f1=$(free)
$P dedup /mnt/sm/dedup-b 16
sync -f /mnt/sm; f2=$(free)
echo "dedup cost first $((f0 - f1)) second $((f1 - f2))"
$P make /mnt/sm/shared-a rand
$P make /mnt/sm/shared-b rand
sync -f /mnt/sm
$P check /mnt/sm/shared-b "data shared with a sibling"
$P make /mnt/sm/crash-synced
$P make /mnt/sm/crash
sync -f /mnt/sm
head -c 65536 /dev/zero | tr "\0" B | dd of=/mnt/sm/crash bs=65536 seek=5 count=1 conv=notrunc 2>/dev/null
echo "SETUP ready for the stop"
'
out=$(ssh "$GUEST_SSH" "$pre_stop" 2>&1)
printf '%s\n' "$out" | sed 's/^/  /'
case $out in *"SETUP ready for the stop"*) ;; *)
	detach; echo "seek-matrix: COULD-NOT-RUN: the guest did not reach the stop" >&2; exit 2 ;; esac

# The hard stop. destroy, not shutdown: nothing gets to flush.
$VIRSH destroy "$GUEST" >/dev/null 2>&1
sleep 3
detach
"$FSCK" "$IMG" >/dev/null 2>&1; fsck_rc=$?
$VIRSH start "$GUEST" >/dev/null 2>&1
guest_up || { echo "seek-matrix: COULD-NOT-RUN: $GUEST did not come back after the stop" >&2; exit 2; }
attach || { echo "seek-matrix: COULD-NOT-RUN: could not reattach $IMG" >&2; exit 2; }
scp -q "$KO" "$GUEST_SSH:/tmp/h2.ko" && scp -q /tmp/h2seekprobe.$$ "$GUEST_SSH:/tmp/h2seekprobe"
post_stop='
insmod /tmp/h2.ko || { echo "SETUP insmod failed"; exit 0; }
mkdir -p /mnt/sm
mount -t hammer2 /dev/vdb@SM /mnt/sm || { echo "SETUP remount failed"; exit 0; }
P=/tmp/h2seekprobe
$P check /mnt/sm/crash-synced "synced before the stop"
if [ -e /mnt/sm/crash ]; then
	echo "crash file size $(stat -c %s /mnt/sm/crash)"
	$P agree /mnt/sm/crash "extended unsynced at the stop"
else
	echo "seekm-fail the synced file extended at the stop is gone"
fi
$P check /mnt/sm/live "live after recovery"
umount /mnt/sm; echo "umount exit $?"
rmmod hammer2; echo "rmmod exit $?"
echo "log: bug $(dmesg | grep -c "kernel BUG") oops $(dmesg | grep -ci oops) warn $(dmesg | grep -c "WARNING:")"
'
out2=$(ssh "$GUEST_SSH" "$post_stop" 2>&1)
printf '%s\n' "$out2" | sed 's/^/  /'
detach

all=$(printf '%s\n%s\n' "$out" "$out2")
fail=0
ok=$(printf '%s\n' "$all" | command grep -c '^seekm-ok')
bad=$(printf '%s\n' "$all" | command grep -c '^seekm-fail')
fail=$((fail + bad))
for want in "^snapshot exit 0$" "^umount exit 0$" "^rmmod exit 0$" "^log: bug 0 oops 0 warn 0$"; do
	printf '%s\n' "$all" | command grep -q "$want" || {
		echo "  FAIL  no line matching $want"; fail=$((fail + 1)); }
done
case $all in *SETUP*failed*) echo "  FAIL  $(printf '%s\n' "$all" | command grep -m1 'SETUP.*failed')"; fail=$((fail + 1)) ;; esac
# A check prints six lines and an agree one: the live file twice, the
# snapshot and the synced crash file are four checks, the shared-sibling
# file a fifth, and the extended crash file one agree, so 31 is the whole
# run. A count below it is a run that asked less than it says, so it is
# failed rather than read.
[ "$ok" -eq 31 ] || { echo "  FAIL  $ok probe check(s) passed where 31 are asked"; fail=$((fail + 1)); }
# Dedup has to have happened for its case to mean anything.
set -- $(printf '%s\n' "$all" | sed -n 's/^dedup cost first \([0-9-]*\) second \([0-9-]*\)$/\1 \2/p')
if [ $# -ne 2 ] || [ "$1" -le 0 ]; then
	echo "  FAIL  the dedup case moved no free count, so it is about nothing"; fail=$((fail + 1))
elif [ $(($2 * 4)) -ge "$1" ]; then
	echo "  FAIL  the second dedup file cost $2 blocks against the first's $1: not shared"; fail=$((fail + 1))
else
	echo "  ok    dedup shared: the second file cost $2 blocks against the first's $1"
fi
[ "$fsck_rc" -eq 0 ] && echo "  ok    fsck_hammer2 clean after the hard stop" || {
	echo "  FAIL  fsck_hammer2 exit $fsck_rc after the hard stop"; fail=$((fail + 1)); }
echo "seek-matrix: $ok probe check(s), $fail failure(s)"
rm -f "$IMG"
[ "$fail" -eq 0 ]
