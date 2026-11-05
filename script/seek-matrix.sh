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
# Four modes replace the three cases and stop no guest:
#
#   H2_SEEK_RACE=1  a truncate aimed inside a held SEEK_HOLE (seekprobe
#                   race). The module is built with HAMMER2_LOCKDEBUG=1
#                   and seek_hold_ms=300 holds the seek after it reads
#                   i_size. The line says whether the truncate returned
#                   inside the seek or after it, and the answer; the
#                   check is only that the hold ran (its klog line, and
#                   the seek taking 250 ms or more), since the answer is
#                   the reading. H2_SEEK_RACE_WANT=inside|after makes
#                   the ordering a check. A truncate that began after
#                   the seek returned reads "late" and fails. The hold
#                   sits after the i_size read and before the tag read
#                   and the scan, so "after" shows the lock spans the
#                   hold; that it spans the scan too is the code's scope.
#                   Then a writeback aimed inside a held seek (seekprobe
#                   wbrace, hole, data and map, H2_REPEAT times each;
#                   map asks FIEMAP held the same way):
#                   seek_tag_hold_ms=300 holds the seek between its page
#                   cache tag read and its tree read, a block moves from
#                   a dirty folio into the tree inside the hold, and the
#                   answer must still call it data. The hold's klog line
#                   must print, and a writeback returning after the seek
#                   fails, since it tested nothing.
#                   Then a file dumped by the walk and by the forced scan
#                   must match, and the module's seek_walked counter must
#                   move on the first dump and stay on the second, or
#                   both dumps came from one reader. Then seek_depth_max=0
#                   refuses the walk's first indirect block, and both
#                   seeks and FIEMAP must fail EIO (seekprobe refuse).
#                   Last, after the fsck, a second boot of the module: one
#                   byte of a file's first indirect block, found by
#                   `hammer2 show`, is flipped on the device, the volume
#                   mounted read-only, and the seeks and FIEMAP must fail
#                   EIO, as a block failing its check is to the VFS, and
#                   the read must fail too.
#   H2_SEEK_TIME=1  the cost of a seek (seekprobe time), sparse, dense,
#                   dirty and hole, each H2_REPEAT times (5 by default) on a
#                   file made once per repeat, H2_SEEK_TIME_N seeks each
#                   (100 by default); raw lines and medians,
#                   H2_SEEK_DENSE_MB sizing the dense file (64 MiB by
#                   default) for this mode and the next,
#                   checked for right answers, and with H2_SEEK_RULE_MS
#                   set, failed when the dense kind's median of medians
#                   passes that many milliseconds. A rate, so run it on
#                   h2release-7.3tls.
#   H2_SEEK_COLD=1  a SEEK_HOLE at 0 across a dense file of
#                   H2_SEEK_DENSE_MB (64 by default) with nothing in
#                   memory, H2_REPEAT times (5 by default): before each,
#                   the guest unmounts and drops its caches, the host
#                   syncs the image and drops its pages
#                   (POSIX_FADV_DONTNEED, resident pages printed after),
#                   and the guest mounts. Medians as the time mode's,
#                   H2_SEEK_RULE_MS applying to them.
#   H2_SEEK_CONTEND=1  what a seek costs a writer (seekprobe contend):
#                   H2_SEEK_TIME_N one-block writes to a 64 MiB file,
#                   timed alone and beside a SEEK_HOLE loop, H2_REPEAT
#                   times (3 by default); median and worst of each, and a
#                   run whose seek loop began after the first write fails. A
#                   rate, so h2release-7.3tls too. H2_SEEK_CONTEND=gap
#                   puts a hole of the same size before the data and loops
#                   SEEK_DATA at 0 instead, so each seek crosses the hole
#                   into the data while the writes wait.
#
# H2_KO loads a module built elsewhere instead of building one. H2_REPEAT
# repeats the race too (1 by default); the three cases ignore it, so it is
# refused there. On a kernel without lockdep the modes read debug_locks as
# none, which passes; 0, lockdep turned off by a report, fails.
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
H2=${H2_HAMMER2:-$HOME/Projects/hammer2-utils-upstream/target/release/hammer2}
KO=src/sys/fs/hammer2/hammer2.ko
RACE=${H2_SEEK_RACE:-0}
TIME=${H2_SEEK_TIME:-0}
CONTEND=${H2_SEEK_CONTEND:-0}
COLD=${H2_SEEK_COLD:-0}
case "$RACE$TIME$CONTEND$COLD" in
0000) [ -z "${H2_REPEAT:-}" ] || { echo "seek-matrix: COULD-NOT-RUN: H2_REPEAT needs H2_SEEK_RACE, H2_SEEK_TIME, H2_SEEK_CONTEND or H2_SEEK_COLD" >&2; exit 2; } ;;
1000|0100|0010|00gap0|0001) ;;
*) echo "seek-matrix: COULD-NOT-RUN: H2_SEEK_RACE, H2_SEEK_TIME, H2_SEEK_CONTEND and H2_SEEK_COLD are 0 or 1 (H2_SEEK_CONTEND also gap), one at a time" >&2; exit 2 ;;
esac
REPEAT=${H2_REPEAT:-$( [ "$TIME$COLD" != 00 ] && echo 5 || { [ "$CONTEND" != 0 ] && echo 3 || echo 1; } )}
RULE=${H2_SEEK_RULE_MS:-}
case "$RULE" in ''|*[!0-9]*|0) [ -z "$RULE" ] || { echo "seek-matrix: COULD-NOT-RUN: H2_SEEK_RULE_MS=$RULE is not a count of ms" >&2; exit 2; } ;; esac
[ -z "$RULE" ] || [ "$TIME$COLD" != 00 ] || { echo "seek-matrix: COULD-NOT-RUN: H2_SEEK_RULE_MS needs H2_SEEK_TIME=1 or H2_SEEK_COLD=1" >&2; exit 2; }
case "$REPEAT" in ''|*[!0-9]*|0) echo "seek-matrix: COULD-NOT-RUN: H2_REPEAT=$REPEAT is not a count" >&2; exit 2 ;; esac
NSEEK=${H2_SEEK_TIME_N:-100}
case "$NSEEK" in ''|*[!0-9]*|0) echo "seek-matrix: COULD-NOT-RUN: H2_SEEK_TIME_N=$NSEEK is not a count" >&2; exit 2 ;; esac
WANT=${H2_SEEK_RACE_WANT:-}
case "$WANT" in ''|inside|after) ;; *) echo "seek-matrix: COULD-NOT-RUN: H2_SEEK_RACE_WANT is inside or after" >&2; exit 2 ;; esac
[ -z "$WANT" ] || [ "$RACE" = 1 ] || { echo "seek-matrix: COULD-NOT-RUN: H2_SEEK_RACE_WANT needs H2_SEEK_RACE=1" >&2; exit 2; }
[ -z "${H2_SEEK_TIME_N:-}" ] || [ "$TIME$CONTEND" != 00 ] || { echo "seek-matrix: COULD-NOT-RUN: H2_SEEK_TIME_N needs H2_SEEK_TIME=1 or H2_SEEK_CONTEND=1" >&2; exit 2; }
DMB=${H2_SEEK_DENSE_MB:-}
case "$DMB" in ''|*[!0-9]*|0) [ -z "$DMB" ] || { echo "seek-matrix: COULD-NOT-RUN: H2_SEEK_DENSE_MB=$DMB is not a count of MiB" >&2; exit 2; } ;; esac
[ -z "$DMB" ] || [ "$TIME$CONTEND$COLD" != 000 ] || { echo "seek-matrix: COULD-NOT-RUN: H2_SEEK_DENSE_MB needs H2_SEEK_TIME=1, H2_SEEK_CONTEND=1 or H2_SEEK_COLD=1" >&2; exit 2; }
# The scratch volume holds the dense file twice over, and 1 GiB at least.
IMGMB=1024; [ -n "$DMB" ] && [ $((DMB * 2)) -gt $IMGMB ] && IMGMB=$((DMB * 2))

[ -x "$NEWFS" ] || { echo "seek-matrix: COULD-NOT-RUN: no newfs_hammer2 at $NEWFS" >&2; exit 2; }
[ -x "$FSCK" ] || { echo "seek-matrix: COULD-NOT-RUN: no fsck_hammer2 at $FSCK" >&2; exit 2; }
[ "$RACE" = 0 ] || [ -x "$H2" ] || { echo "seek-matrix: COULD-NOT-RUN: no hammer2 at $H2 to find an indirect block" >&2; exit 2; }
[ "$COLD" = 0 ] || { command -v python3 >/dev/null 2>&1 && command -v fincore >/dev/null 2>&1; } || {
	echo "seek-matrix: COULD-NOT-RUN: the cold mode drops the host's pages with python3 and reads them with fincore" >&2; exit 2; }
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
echo "  module $KO sha256 $(sha256sum "$KO" | cut -c1-16) head $(git rev-parse --short HEAD) dirty $(git status --porcelain -- src script test | wc -l) seek-matrix.sh $(sha256sum "$0" | cut -c1-16) seekprobe.c $(sha256sum test/hammer2-seekprobe.c | cut -c1-16)"
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
truncate -s "${IMGMB}M" "$IMG" && "$NEWFS" -L SM "$IMG" >/dev/null 2>&1 || {
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
echo "debug_locks $(awk "/debug_locks:/ {print \$2}" /proc/lockdep_stats 2>/dev/null || echo none)"
'
race_body='
K=/sys/module/hammer2/parameters/seek_hold_ms
[ -e $K ] || { echo "SETUP knob failed: no seek_hold_ms, the module was built without HAMMER2_LOCKDEBUG"; umount /mnt/sm; rmmod hammer2; exit 0; }
echo 300 > $K
i=0; while [ $i -lt $REPEAT ]; do /tmp/h2seekprobe race /mnt/sm/race; rm -f /mnt/sm/race; i=$((i + 1)); done
echo 0 > $K
echo "held $(dmesg | grep -c "hammer2: seek held")"
T=/sys/module/hammer2/parameters/seek_tag_hold_ms
[ -e $T ] || { echo "SETUP knob failed: no seek_tag_hold_ms"; umount /mnt/sm; rmmod hammer2; exit 0; }
echo 300 > $T
i=0; while [ $i -lt $REPEAT ]; do for w in hole data map; do /tmp/h2seekprobe wbrace /mnt/sm/wb $w; rm -f /mnt/sm/wb; done; i=$((i + 1)); done
echo 0 > $T
echo "tag-held $(dmesg | grep -c "hammer2: seek tag held")"
S=/sys/module/hammer2/parameters/seek_scanall
W=/sys/module/hammer2/parameters/seek_walked
D=/sys/module/hammer2/parameters/seek_depth_max
[ -e $S ] && [ -e $W ] && [ -e $D ] || { echo "SETUP knob failed: no seek_scanall, seek_walked or seek_depth_max"; umount /mnt/sm; rmmod hammer2; exit 0; }
/tmp/h2seekprobe layout /mnt/sm/lay
w0=$(cat $W)
/tmp/h2seekprobe dump /mnt/sm/lay > /tmp/h2dump-walk; echo "dump walk exit $?"
w1=$(cat $W)
echo 1 > $S
/tmp/h2seekprobe dump /mnt/sm/lay > /tmp/h2dump-scan; echo "dump scanall exit $?"
w2=$(cat $W)
echo 0 > $S
echo "dump lines $(wc -l < /tmp/h2dump-walk) extents $(grep -c "^seekm-dump extent " /tmp/h2dump-walk) differ $(cmp -s /tmp/h2dump-walk /tmp/h2dump-scan && echo 0 || echo 1) forced $(dmesg | grep -c "hammer2: seek scanall forced")"
echo "dump walked $((w1 - w0)) forced $((w2 - w1))"
diff /tmp/h2dump-walk /tmp/h2dump-scan | head -5 | sed "s/^/dump diff /"
d0=$(cat $D)
echo 0 > $D
/tmp/h2seekprobe refuse /mnt/sm/lay; echo "refuse depth exit $?"
echo $d0 > $D
rm -f /mnt/sm/lay /tmp/h2dump-walk /tmp/h2dump-scan
head -c 4194304 /dev/urandom > /mnt/sm/ind && sync -f /mnt/sm && echo "ind inum $(stat -c %i /mnt/sm/ind)"
'
# The corrupt pass, after the fsck: OFF is the byte the host chose inside
# the file's first indirect block. The byte is flipped through the block
# device before the module loads, and the device's buffers dropped, so
# the mount reads what the device holds.
corrupt_body='
dmesg -C
v=$(dd if=/dev/vdb bs=1 skip=$OFF count=1 2>/dev/null | od -An -tu1 | tr -d " ")
printf "\\$(printf %o $((v ^ 255)))" | dd of=/dev/vdb bs=1 seek=$OFF count=1 conv=notrunc,fsync 2>/dev/null
blockdev --flushbufs /dev/vdb
w=$(dd if=/dev/vdb bs=1 skip=$OFF count=1 2>/dev/null | od -An -tu1 | tr -d " ")
echo "corrupt flipped $v to $w at $OFF"
insmod /tmp/h2.ko || { echo "SETUP insmod failed"; exit 0; }
mount -t hammer2 -o ro /dev/vdb@SM /mnt/sm || { echo "SETUP corrupt mount failed"; rmmod hammer2; exit 0; }
/tmp/h2seekprobe refuse /mnt/sm/ind; echo "refuse corrupt exit $?"
e=$(dd if=/mnt/sm/ind of=/dev/null bs=65536 2>&1); s=$?
echo "corrupt read exit $s eio $(printf "%s\n" "$e" | grep -c "Input/output error")"
umount /mnt/sm; echo "corrupt umount exit $?"
rmmod hammer2; echo "corrupt rmmod exit $?"
echo "corrupt log: bug $(dmesg | grep -c "kernel BUG") oops $(dmesg | grep -ci oops) warn $(dmesg | grep -c "WARNING:")"
echo "corrupt debug_locks $(awk "/debug_locks:/ {print \$2}" /proc/lockdep_stats 2>/dev/null || echo none)"
'
cold_drop='
umount /mnt/sm; echo "cold umount exit $?"
echo 3 > /proc/sys/vm/drop_caches
'
cold_seek='
mount -t hammer2 /dev/vdb@SM /mnt/sm || { echo "SETUP cold mount failed"; exit 0; }
/tmp/h2seekprobe cold /mnt/sm/c
'
# The host's copy of the image, synced and dropped, so the guest's read
# reaches the disk; the resident page count after says whether it did.
hostdrop() {
	python3 -c 'import os, sys
fd = os.open(sys.argv[1], os.O_RDONLY)
os.fsync(fd)
os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)' "$IMG" || return 1
	echo "cold host-resident $(fincore -nb -o RES "$IMG" 2>/dev/null | tr -d ' ')"
}
time_body='
for k in sparse dense dirty hole deep; do
	i=0; while [ $i -lt $REPEAT ]; do /tmp/h2seekprobe time /mnt/sm/t $k $NSEEK $DMB; i=$((i + 1)); done
done
'
contend_body='
i=0; while [ $i -lt $REPEAT ]; do /tmp/h2seekprobe $CVERB /mnt/sm/c $NSEEK $DMB; i=$((i + 1)); done
'
if [ "$RACE$TIME$CONTEND$COLD" != 0000 ]; then
	if [ "$COLD" = 1 ]; then
		out=$(ssh "$GUEST_SSH" "$mode_open /tmp/h2seekprobe cold /mnt/sm/c ${DMB:-64}" 2>&1)
		i=0
		while [ "$i" -lt "$REPEAT" ]; do
			o1=$(ssh "$GUEST_SSH" "$cold_drop" 2>&1)
			o2=$(hostdrop 2>&1) || o2="$o2
SETUP cold host drop failed"
			o3=$(ssh "$GUEST_SSH" "$cold_seek" 2>&1)
			out=$(printf '%s\n%s\n%s\n%s' "$out" "$o1" "$o2" "$o3")
			i=$((i + 1))
		done
		out=$(printf '%s\n%s' "$out" "$(ssh "$GUEST_SSH" "$mode_close" 2>&1)")
	else
		if [ "$RACE" = 1 ]; then body=$race_body; elif [ "$TIME" = 1 ]; then body=$time_body; else body=$contend_body; fi
		CVERB=contend; [ "$CONTEND" = gap ] && CVERB=contendgap
		out=$(ssh "$GUEST_SSH" "REPEAT=$REPEAT; NSEEK=$NSEEK; DMB=$DMB; CVERB=$CVERB; $mode_open $body $mode_close" 2>&1)
	fi
	printf '%s\n' "$out" | command grep -v '^seekm-time [a-z]* [0-9]* ' | sed 's/^/  /'
	detach
	"$FSCK" "$IMG" >/dev/null 2>&1; fsck_rc=$?
	if [ "$RACE" = 1 ]; then
		# The file's inode names its first indirect block in `hammer2
		# show`; the low six bits of its data_off are the block's radix,
		# and 64 bytes in is inside the first blockref of its array.
		inum=$(printf '%s\n' "$out" | sed -n 's/^ind inum \([0-9][0-9]*\)$/\1/p')
		ioff=
		[ -n "$inum" ] && ioff=$("$H2" show "$IMG" 2>/dev/null | awk -v want="\"0x$(printf %016x "$inum")\"" '
		    $1 == "filename" && $2 == want { f = 1; next }
		    f && $1 ~ /^indirect\./ { print $2; exit }
		    f && /\(inode\./ { exit }')
		if [ -n "$ioff" ] && attach; then
			OFF=$(( (0x$ioff & ~63) + 64 ))
			echo "  corrupt: inode $inum, indirect data_off $ioff, byte $OFF"
			out2=$(ssh "$GUEST_SSH" "OFF=$OFF; $corrupt_body" 2>&1)
			detach
		else
			out2="SETUP corrupt failed: inode ${inum:-none}, indirect ${ioff:-none}"
		fi
		printf '%s\n' "$out2" | sed 's/^/  /'
		out=$(printf '%s\n%s' "$out" "$out2")
	fi
	fail=0
	case $out in *SETUP*failed*) echo "  FAIL  $(printf '%s\n' "$out" | command grep -m1 'SETUP.*failed')"; fail=$((fail + 1)) ;; esac
	for want in "^umount exit 0$" "^rmmod exit 0$" "^log: bug 0 oops 0 warn 0$" "^debug_locks [1n]"; do
		printf '%s\n' "$out" | command grep -q "$want" || {
			echo "  FAIL  no line matching $want"; fail=$((fail + 1)); }
	done
	# A kernel without lockdep has no lockdep_stats and prints none, which
	# reads nothing; 0 is lockdep turned off by a report, and fails above.
	bad=$(printf '%s\n' "$out" | command grep -c '^seekm-fail')
	[ "$bad" -eq 0 ] || { echo "  FAIL  $bad seekm-fail line(s)"; fail=$((fail + 1)); }
	if [ "$RACE" = 1 ]; then
		lines=$(printf '%s\n' "$out" | command grep '^seekm-race ')
		n=$(printf '%s\n' "$lines" | command grep -c '^seekm-race ')
		[ "$n" -eq "$REPEAT" ] || { echo "  FAIL  $n race line(s) for $REPEAT run(s)"; fail=$((fail + 1)); }
		printf '%s\n' "$out" | command grep -q '^held [1-9][0-9]*$' || {
			echo "  FAIL  the seek hold never printed, so nothing held"; fail=$((fail + 1)); }
		short=$(printf '%s\n' "$lines" | awk '$5 < 250' | wc -l)
		[ "$short" -eq 0 ] || { echo "  FAIL  $short seek(s) returned under 250 ms, so the hold did not run in them"; fail=$((fail + 1)); }
		late=$(printf '%s\n' "$lines" | awk '$9 == "late"' | wc -l)
		[ "$late" -eq 0 ] || { echo "  FAIL  $late truncate(s) began after the seek returned, so they read nothing"; fail=$((fail + 1)); }
		if [ -n "$WANT" ]; then
			off=$(printf '%s\n' "$lines" | awk -v w="$WANT" '$9 != w' | wc -l)
			[ "$off" -eq 0 ] || { echo "  FAIL  $off of $n truncate(s) not $WANT the seek"; fail=$((fail + 1)); }
		fi
		wb=$(printf '%s\n' "$out" | command grep '^seekm-wbrace ')
		n=$(printf '%s\n' "$wb" | command grep -c '^seekm-wbrace ')
		[ "$n" -eq $((REPEAT * 3)) ] || { echo "  FAIL  $n writeback race line(s) for $REPEAT run(s) of three"; fail=$((fail + 1)); }
		printf '%s\n' "$out" | command grep -q '^tag-held [1-9][0-9]*$' || {
			echo "  FAIL  the tag hold never printed, so nothing held"; fail=$((fail + 1)); }
		out_wb=$(printf '%s\n' "$wb" | awk '$12 != "inside"' | wc -l)
		[ "$out_wb" -eq 0 ] || { echo "  FAIL  $out_wb writeback(s) returned after the seek, so they tested nothing"; fail=$((fail + 1)); }
		for w in walk scanall; do
			printf '%s\n' "$out" | command grep -q "^dump $w exit 0$" || {
				echo "  FAIL  the $w dump did not exit 0"; fail=$((fail + 1)); }
		done
		# 2201 seek lines from every half block of the 1100.5-block file,
		# at least three extents (1040 blocks, one, eight), the summary
		dl=$(printf '%s\n' "$out" | sed -n 's/^dump lines \([0-9]*\) extents \([0-9]*\) differ \([01]\) forced \([0-9]*\)$/\1 \2 \3 \4/p')
		set -- $dl
		if [ $# -ne 4 ] || [ "$1" -lt 2205 ] || [ "$2" -lt 3 ] || [ "$3" -ne 0 ] || [ "$4" -lt 1 ]; then
			echo "  FAIL  walk and scanall dumps: ${dl:-no line} (lines extents differ forced)"; fail=$((fail + 1))
		else
			echo "  ok    walk and scanall dumps identical: $1 lines, $2 extent(s), scanall forced"
		fi
		# Which reader answered each dump: the walk's counter moves on
		# the first and not on the forced one, or the comparison is of
		# one reader with itself.
		wk=$(printf '%s\n' "$out" | sed -n 's/^dump walked \([0-9]*\) forced \([0-9]*\)$/\1 \2/p')
		set -- $wk
		if [ $# -eq 2 ] && [ "$1" -gt 0 ] && [ "$2" -eq 0 ]; then
			echo "  ok    the walk answered $1 tree read(s) of the first dump and none of the forced one"
		else
			echo "  FAIL  seek_walked: ${wk:-no line} (walk dump, forced dump)"; fail=$((fail + 1))
		fi
		for want in "^refuse depth exit 0$" "^refuse corrupt exit 0$" \
		    "^corrupt read exit [1-9][0-9]* eio [1-9]" "^corrupt umount exit 0$" \
		    "^corrupt rmmod exit 0$" "^corrupt log: bug 0 oops 0 " "^corrupt debug_locks [1n]"; do
			printf '%s\n' "$out" | command grep -q "$want" || {
				echo "  FAIL  no line matching $want"; fail=$((fail + 1)); }
		done
		fl=$(printf '%s\n' "$out" | sed -n 's/^corrupt flipped \([0-9]*\) to \([0-9]*\) at [0-9]*$/\1 \2/p')
		set -- $fl
		if [ $# -eq 2 ] && [ "$2" -eq $(($1 ^ 255)) ]; then
			echo "  ok    the indirect block's byte was flipped on the device ($1 to $2)"
		else
			echo "  FAIL  the flip: ${fl:-no line}, so the corrupt pass read an unaltered block"; fail=$((fail + 1))
		fi
		echo "  wbrace: $(printf '%s\n' "$wb" | awk '{print $2"="$4}' | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
		echo "  race: $(printf '%s\n' "$lines" | awk '{print $9}' | sort | uniq -c | tr -s ' ' | tr '\n' ';') answers $(printf '%s\n' "$lines" | awk '{print $3}' | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
	elif [ "$CONTEND" != 0 ]; then
		for ph in alone seeking; do
			c=$(printf '%s\n' "$out" | command grep -c "^seekm-contend $ph ")
			[ "$c" -eq "$REPEAT" ] || { echo "  FAIL  $c $ph line(s) for $REPEAT repeat(s)"; fail=$((fail + 1)); }
			echo "  contend $ph: median-ns $(printf '%s\n' "$out" | sed -n "s/^seekm-contend $ph median-ns \([0-9]*\) .*/\1/p" | tr '\n' ' ')max-ns $(printf '%s\n' "$out" | sed -n "s/^seekm-contend $ph median-ns [0-9]* max-ns \([0-9]*\) .*/\1/p" | tr '\n' ' ')"
		done
		echo "  contend seeks begun: $(printf '%s\n' "$out" | sed -n 's/^seekm-contend seeking .* seeks \([0-9]*\)$/\1/p' | tr '\n' ' ')"
	elif [ "$COLD" = 1 ]; then
		m=$(printf '%s\n' "$out" | sed -n 's/^seekm-cold ns \([0-9]*\) size .*/\1/p')
		c=$(printf '%s\n' "$m" | command grep -c .)
		[ "$c" -eq "$REPEAT" ] || { echo "  FAIL  $c cold seek(s) for $REPEAT repeat(s)"; fail=$((fail + 1)); }
		mm=$(printf '%s\n' "$m" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')
		echo "  cold SEEK_HOLE ns: $(printf '%s\n' "$m" | tr '\n' ' ')median ${mm:-none}"
		echo "  cold host-resident pages after each drop: $(printf '%s\n' "$out" | sed -n 's/^cold host-resident //p' | tr '\n' ' ')"
		if [ -n "$RULE" ]; then
			if [ -n "$mm" ] && [ "$mm" -le $((RULE * 1000000)) ]; then
				echo "  ok    the cold SEEK_HOLE median is within $RULE ms"
			else
				echo "  FAIL  the cold SEEK_HOLE median ${mm:-none} ns passes $RULE ms"; fail=$((fail + 1))
			fi
		fi
	else
		for k in sparse dense dense-data dense-hole dirty hole deep; do
			m=$(printf '%s\n' "$out" | sed -n "s/^seekm-time $k median-ns \([0-9]*\) n .*/\1/p")
			c=$(printf '%s\n' "$m" | command grep -c .)
			[ "$c" -eq "$REPEAT" ] || { echo "  FAIL  $c $k median(s) for $REPEAT repeat(s)"; fail=$((fail + 1)); }
			mm=$(printf '%s\n' "$m" | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}')
			echo "  time $k median-ns per repeat: $(printf '%s\n' "$m" | tr '\n' ' ')median of medians $mm"
			[ "$k" = dense-hole ] && [ -n "$RULE" ] && {
				if [ -n "$mm" ] && [ "$mm" -le $((RULE * 1000000)) ]; then
					echo "  ok    the dense SEEK_HOLE median of medians is within $RULE ms"
				else
					echo "  FAIL  the dense SEEK_HOLE median of medians ${mm:-none} ns passes $RULE ms"; fail=$((fail + 1))
				fi; }
		done
		raw=$(printf '%s\n' "$out" | command grep -c '^seekm-time [a-z]* [0-9]* ')
		echo "  time: $raw raw seek line(s) kept below"
		printf '%s\n' "$out" | command grep '^seekm-time [a-z]* [0-9]* ' | sed 's/^/  raw /'
	fi
	[ "$fsck_rc" -eq 0 ] && echo "  ok    fsck_hammer2 clean" || {
		echo "  FAIL  fsck_hammer2 exit $fsck_rc"; fail=$((fail + 1)); }
	echo "seek-matrix: $([ "$RACE" = 1 ] && echo race || { [ "$TIME" = 1 ] && echo time || { [ "$COLD" = 1 ] && echo cold || echo contend; }; }), $REPEAT repeat(s), $fail failure(s)"
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
