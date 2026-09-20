#!/bin/sh
# Sequential throughput and allocation order, the two readings that decide
# whether the port adds ->readahead and changes its writeback order.
# DragonFly's HAMMER2 reads ahead through cluster_readx() and writes behind
# in file order through cluster_write(), and the core's own comment says
# the allocation pattern depends on the second because the compressed size
# is unknown until the strategy runs; the port carries neither, and until
# this ran no throughput number of any kind existed.
#
# The Linux guest writes one large random file to a HAMMER2 volume and the
# same file to ext4 and btrfs on two more disks, btrfs being the checksummed
# copy-on-write filesystem a fair comparison needs, times the write and two cold reads
# (1 MiB and 64 KiB requests) on each, and checks the HAMMER2 copy by hash
# after a remount. DragonFly then writes a file of the same size to the same
# volume and reads both files cold, so the host can read both layouts from the image with `hammer2
# show`: every data blockref in key order with its media offset, and the
# count of steps that are contiguous, forward or backward is the allocation
# order reading, DragonFly's file being the reference the core was written
# against. Throughput is printed, never judged; a run fails on a hash
# mismatch, a kernel warning, a checker verdict or a missing reading.
#
# Exits 2 without the fleet or the tools. Not a gate.
#
#   H2_TP_MIB=512            total bytes per filesystem, MiB
#   H2_TP_WRITERS=1          concurrent writers, each writing an equal share
#   H2_TP_IMAGE, H2_TP_EXT4  the two images (H2_FIXTURE_DIR by default)
#   H2_TP_MODARGS            module parameters for the guest's insmod
#   KDIR                     the kernel of record's build tree, required

# Run from a private copy so an edit to this file during a run cannot be
# read by the shell mid-way; million-tree.sh does the same. The copy runs
# from the repository root, since its own name says nothing about it.
if [ -z "${H2_TP_COPY:-}" ]; then
	cd "$(dirname "$0")/.." || exit 2
	c=$(mktemp) || exit 2
	cp "$0" "$c" || exit 2
	H2_TP_COPY=$c exec sh "$c" "$@"
fi
trap 'rm -f "$H2_TP_COPY"' EXIT

FIXDIR=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}
IMG=${H2_TP_IMAGE:-$FIXDIR/throughput.img}
EXT4=${H2_TP_EXT4:-$FIXDIR/throughput-ext4.img}
BTRFS=${H2_TP_BTRFS:-$FIXDIR/throughput-btrfs.img}
MIB=${H2_TP_MIB:-512}
MODARGS=${H2_TP_MODARGS:-}
REPEAT=${H2_REPEAT:-1}
WRITERS=${H2_TP_WRITERS:-1}
case "$WRITERS" in
''|*[!0-9]*) echo "throughput: COULD-NOT-RUN: H2_TP_WRITERS is not a number" >&2; exit 2 ;;
esac
[ "$WRITERS" -gt 0 ] && [ "$WRITERS" -le 64 ] || {
	echo "throughput: COULD-NOT-RUN: H2_TP_WRITERS must be between 1 and 64" >&2; exit 2; }
[ "$MIB" -gt 0 ] || { echo "throughput: COULD-NOT-RUN: H2_TP_MIB must be positive" >&2; exit 2; }
[ $((MIB % WRITERS)) -eq 0 ] || {
	echo "throughput: COULD-NOT-RUN: H2_TP_MIB must divide evenly by H2_TP_WRITERS" >&2; exit 2; }
PER_MIB=$((MIB / WRITERS))
RACE_ROUNDS=${H2_TP_RACE_ROUNDS:-4000}
# The names of the files the Linux side leaves behind: one per writer
# when writers run at once, one otherwise.  Both the read phase and the
# DragonFly leg walk this list, so neither looks for a name no run made.
files="big.0"
w=1
while [ "$w" -lt "$WRITERS" ]; do
	files="$files big.$w"
	w=$((w + 1))
done
[ "$WRITERS" -gt 1 ] || files="big"
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
DFLY=${H2_DFLY_GUEST:-dragonflybsd642}
DFLY_SSH=${H2_DFLY_SSH:-root@192.168.122.42}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
UTILS=$HOME/Projects/hammer2-utils-upstream/target/release
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$UTILS/newfs_hammer2")}
FSCK=${H2_FSCK:-$(command -v fsck_hammer2 2>/dev/null || echo "$UTILS/fsck_hammer2")}
SHOW=${H2_SHOW:-$(command -v hammer2 2>/dev/null || echo "$UTILS/hammer2")}
W=$(mktemp -d) || exit 2
RUN="timeout ${H2_RUN_TIMEOUT:-1800} ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
trap 'rm -rf "$W" "$H2_TP_COPY"' EXIT

command -v virsh >/dev/null 2>&1 || { echo "throughput: COULD-NOT-RUN: no virsh" >&2; exit 2; }
for t in mkfs.ext4 mkfs.btrfs; do
	command -v $t >/dev/null 2>&1 || { echo "throughput: COULD-NOT-RUN: no $t" >&2; exit 2; }
done
for t in "$NEWFS" "$FSCK" "$SHOW"; do
	[ -x "$t" ] || { echo "throughput: COULD-NOT-RUN: no $t" >&2; exit 2; }
done
[ -d "$FIXDIR" ] || { echo "throughput: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -d "$KDIR" ] || { echo "throughput: COULD-NOT-RUN: no kernel tree at $KDIR" >&2; exit 2; }
for g in "$GUEST" "$DFLY"; do
	$VIRSH domstate "$g" >/dev/null 2>&1 || { echo "throughput: COULD-NOT-RUN: no guest $g" >&2; exit 2; }
done
[ -z "$($VIRSH list --name | tr -d ' \n')" ] || {
	echo "throughput: COULD-NOT-RUN: a guest is running: $($VIRSH list --name | tr '\n' ' ')" >&2; exit 2; }

make -s clean >/dev/null 2>&1
make -s KDIR="$KDIR" >/dev/null 2>&1 || {
	echo "throughput: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko
built=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
[ -z "$(git status --porcelain -- src 2>/dev/null)" ] || built="$built-dirty"

# Each pass writes the file twice on HAMMER2, once in place and once
# after dd's truncate, and copy-on-write gives both fresh media: a
# truncated block goes back to the freemap at bulkfree, not before, so
# H2_REPEAT passes need 2*REPEAT files of room plus DragonFly's one.
# The first sizing held one pass four times over and a third pass hit
# the reserve, which refused the write and left an empty file.
vol=$((MIB * (2 * REPEAT + 2) + 256))
rm -f "$IMG" "$EXT4" "$BTRFS"
truncate -s "${vol}M" "$IMG" && "$NEWFS" -L ROOT "$IMG" >/dev/null 2>&1 || {
	echo "throughput: COULD-NOT-RUN: newfs_hammer2 failed on $IMG" >&2; exit 2; }
truncate -s "${vol}M" "$EXT4" && mkfs.ext4 -q -F "$EXT4" >/dev/null 2>&1 || {
	echo "throughput: COULD-NOT-RUN: mkfs.ext4 failed on $EXT4" >&2; exit 2; }
truncate -s "${vol}M" "$BTRFS" && mkfs.btrfs -q -f "$BTRFS" >/dev/null 2>&1 || {
	echo "throughput: COULD-NOT-RUN: mkfs.btrfs failed on $BTRFS" >&2; exit 2; }

fail=0
boot() {	# boot <guest> <ssh> [ext4 image] [btrfs image]; the images are attached first
	$VIRSH attach-disk "$1" "$IMG" vdb --targetbus virtio --config >/dev/null 2>&1
	[ -n "${3:-}" ] && $VIRSH attach-disk "$1" "$3" vdc --targetbus virtio --config >/dev/null 2>&1
	[ -n "${4:-}" ] && $VIRSH attach-disk "$1" "$4" vdd --targetbus virtio --config >/dev/null 2>&1
	$VIRSH start "$1" >/dev/null 2>&1 || { echo "  COULD-NOT-RUN  $1 did not start"; return 1; }
	n=0
	until ssh -o ConnectTimeout=3 -o BatchMode=yes "$2" true 2>/dev/null; do
		sleep 5; n=$((n + 1)); [ $n -gt 60 ] && { echo "  COULD-NOT-RUN  $1 did not answer ssh in 5 minutes, host load $(cut -d" " -f1-3 /proc/loadavg)"; return 1; }
	done
	return 0
}
down() {	# down <guest> <ssh>
	ssh -o ConnectTimeout=5 "$2" 'sync; poweroff' >/dev/null 2>&1
	n=0
	until [ "$($VIRSH domstate "$1")" = "shut off" ]; do
		sleep 3; n=$((n + 1)); [ $n -gt 60 ] && { $VIRSH destroy "$1" >/dev/null 2>&1; break; }
	done
	$VIRSH detach-disk "$1" vdb --config >/dev/null 2>&1
	$VIRSH detach-disk "$1" vdc --config >/dev/null 2>&1
	$VIRSH detach-disk "$1" vdd --config >/dev/null 2>&1
}
fsck_control() {	# image; the negative control every host fsck verdict carries
	c=$FIXDIR/control.img
	cp --sparse=always "$1" "$c" || { echo "  FAIL  could not copy $1 for the fsck control"; return 1; }
	b=$(dd if="$c" bs=1 skip=256 count=1 status=none | od -An -tu1 | tr -d ' ')
	printf "\\$(printf %o $((b ^ 255)))" | dd of="$c" bs=1 seek=256 conv=notrunc status=none
	o=$("$FSCK" "$c" 2>&1); s=$?
	rm -f "$c"
	if [ "$s" != 0 ] && printf '%s\n' "$o" | grep -q "volume header crc mismatch"; then
		echo "  ok    host fsck_hammer2 refuses the same image with one header byte changed"
		return 0
	fi
	echo "  FAIL  host fsck_hammer2 accepted the image with one header byte changed, so its pass proves nothing"
	return 1
}

# 1. Linux: the same file to both filesystems, timed; the source sits in
# memory so the reading is the filesystem's and not the random device's.
# Rates are MiB per second from /proc/uptime, which has centiseconds.
cat > "$W/linux.sh" <<GUEST
set -u
rmmod hammer2 2>/dev/null; insmod /tmp/hammer2.ko $MODARGS || exit 1; dmesg -C
mkdir -p /mnt/h2 /mnt/e4 /mnt/bt
mount -t hammer2 /dev/vdb@ROOT /mnt/h2 || { echo "hammer2 mount failed"; exit 1; }
mount -t ext4 /dev/vdc /mnt/e4 || { echo "ext4 mount failed"; exit 1; }
mount -t btrfs /dev/vdd /mnt/bt || { echo "btrfs mount failed"; exit 1; }
now() { awk '{print \$1}' /proc/uptime; }
rate() { awk -v b="\$1" -v t0="\$2" -v t1="\$3" 'BEGIN{d=t1-t0; if (d<=0) d=0.01; printf "%.0f", b/d}'; }
# The kernel timed on is part of the reading: a lockdep kernel charges
# every lock the port takes per block, which is what put a third of a
# read's samples in lock bookkeeping and the port at 3% of its own profile.
echo "kernel \$(uname -r) lockdep \$(zcat /proc/config.gz 2>/dev/null | grep -c '^CONFIG_PROVE_LOCKING=y')"
# Every pass is a first write of new bytes into a cold cache: the files
# are removed, the guest cache dropped and fresh sources drawn again, so a
# second pass cannot read as a dedup hit or a warm overwrite. A refused
# dd prints as a refusal, never as a rate over the time it took to fail.
i=0
while [ \$i -lt $REPEAT ]; do
	# The source is drawn after the cache drop, not before: tmpfs is
	# not evicted by drop_caches, so a buffer drawn first is warm for
	# the second pass and every filesystem's admission read four times
	# faster on passes two and three of the first run of this loop.
	sync; echo 3 > /proc/sys/vm/drop_caches
	if [ "$WRITERS" -gt 1 ]; then
		w=0
		while [ \$w -lt $WRITERS ]; do
			rm -f /dev/shm/h2tp.src.\$w
			head -c $((PER_MIB * 1024 * 1024)) /dev/urandom > /dev/shm/h2tp.src.\$w || {
				echo "no source for writer \$w"; exit 1; }
			md5sum < /dev/shm/h2tp.src.\$w | cut -c1-32 > /dev/shm/h2tp.src.\$w.md5
			w=\$((w + 1))
		done
		echo "source $MIB MiB drawn in $WRITERS files (run \$i)"
		for fs in h2 e4 bt; do
			w=0
			while [ \$w -lt $WRITERS ]; do
				rm -f /mnt/\$fs/big.\$w
				w=\$((w + 1))
			done
			rm -f /tmp/h2tp.\$fs.*.rc
			t0=\$(now); w=0
			while [ \$w -lt $WRITERS ]; do
				(dd if=/dev/shm/h2tp.src.\$w of=/mnt/\$fs/big.\$w bs=1M conv=notrunc status=none
					echo \$? > /tmp/h2tp.\$fs.\$w.rc) &
				w=\$((w + 1))
			done
			wait; t1=\$(now)
			refused=0; w=0
			while [ \$w -lt $WRITERS ]; do
				rc=\$(cat /tmp/h2tp.\$fs.\$w.rc)
				[ \$rc -ne 0 ] && refused=\$((refused + 1))
				w=\$((w + 1))
			done
			echo "\$fs concurrent buffered_write \$(rate $MIB \$t0 \$t1) MiB/s (run \$i, $WRITERS writers)"
			echo "\$fs concurrent write refusals \$refused (run \$i, $WRITERS writers)"
			t0=\$(now); sync -f /mnt/\$fs; sr=\$?; t1=\$(now)
			echo "\$fs concurrent syncfs \$(awk -v t0=\$t0 -v t1=\$t1 'BEGIN{printf "%.2f", t1-t0}') s (run \$i, $WRITERS writers)"
			echo "\$fs concurrent syncfs exit \$sr (run \$i, $WRITERS writers)"
			rm -f /tmp/h2tp.\$fs.*.rc
			t0=\$(now); w=0
			while [ \$w -lt $WRITERS ]; do
				(dd if=/dev/shm/h2tp.src.\$w of=/mnt/\$fs/big.\$w bs=1M conv=fsync status=none
					echo \$? > /tmp/h2tp.\$fs.\$w.rc) &
				w=\$((w + 1))
			done
			wait; t1=\$(now)
			refused=0; w=0
			while [ \$w -lt $WRITERS ]; do
				rc=\$(cat /tmp/h2tp.\$fs.\$w.rc)
				[ \$rc -ne 0 ] && refused=\$((refused + 1))
				w=\$((w + 1))
			done
			echo "\$fs concurrent write \$(rate $MIB \$t0 \$t1) MiB/s (run \$i, $WRITERS writers)"
			echo "\$fs concurrent write refusals \$refused (run \$i, $WRITERS writers)"
			bad=0; w=0
			while [ \$w -lt $WRITERS ]; do
				src=\$(cat /dev/shm/h2tp.src.\$w.md5)
				got=\$(md5sum < /mnt/\$fs/big.\$w | cut -c1-32)
				[ "\$src" = "\$got" ] || bad=\$((bad + 1))
				w=\$((w + 1))
			done
			echo "\$fs concurrent hash mismatches \$bad (run \$i, $WRITERS writers)"
		done
	else
		rm -f /mnt/h2/big /mnt/e4/big /mnt/bt/big
		head -c $((MIB * 1024 * 1024)) /dev/urandom > /dev/shm/h2tp.src.0 || { echo "no source"; exit 1; }
		src=\$(md5sum < /dev/shm/h2tp.src.0 | cut -c1-32)
		echo "\$src" > /dev/shm/h2tp.src.0.md5
		echo "source $MIB MiB md5 \$src (run \$i)"
		for fs in h2 e4 bt; do
			# The page cache admission and the flush, timed apart.
			t0=\$(now); dd if=/dev/shm/h2tp.src.0 of=/mnt/\$fs/big bs=1M conv=notrunc status=none || echo "\$fs write refused (run \$i)"; t1=\$(now)
			echo "\$fs buffered_write \$(rate $MIB \$t0 \$t1) MiB/s (run \$i)"
			t0=\$(now); sync -f /mnt/\$fs; t1=\$(now)
			echo "\$fs syncfs \$(awk -v t0=\$t0 -v t1=\$t1 'BEGIN{printf "%.2f", t1-t0}') s (run \$i)"
			# The combined number every earlier reading of record is.
			t0=\$(now); dd if=/dev/shm/h2tp.src.0 of=/mnt/\$fs/big bs=1M conv=fsync status=none || echo "\$fs write refused (run \$i)"; t1=\$(now)
			echo "\$fs write \$(rate $MIB \$t0 \$t1) MiB/s (run \$i)"
		done
	fi
	i=\$((i + 1))
done
umount /mnt/h2; echo "hammer2 umount exit \$?"; umount /mnt/e4; umount /mnt/bt
mount -t hammer2 /dev/vdb@ROOT /mnt/h2 || { echo "hammer2 remount failed"; exit 1; }
mount -t ext4 /dev/vdc /mnt/e4; mount -t btrfs /dev/vdd /mnt/bt
# One unmeasured read of each file first: the images are files on the
# host, and the first read of one after a write goes to the host's disk
# while the next hits the host's cache, a difference of ten times that
# is the host's and not the driver's.  Every timed read below is cold
# in the guest and warm on the host, which is the driver's own cost.
for fs in h2 e4 bt; do for f in $files; do dd if=/mnt/\$fs/\$f of=/dev/null bs=1M status=none; done; done
sync; echo 3 > /proc/sys/vm/drop_caches
# The port's ->read_folio decodes a whole block for whatever folio it is
# handed, so the number of calls a cold read makes is the number of
# folios the page cache built for it: one per block is the floor, and
# more says smaller folios each cost a block's decode.  Counted with the
# function profiler, which the kernel of record carries, and printed as
# unavailable where the guest kernel does not.
T=/sys/kernel/tracing
P=\$T/function_profile_enabled
[ -e \$P ] || mount -t tracefs nodev \$T 2>/dev/null
prof_start() { [ -e \$P ] || return 0; echo hammer2_read_folio > \$T/set_ftrace_filter; echo 0 > \$P; echo 1 > \$P; }
prof_count() { [ -e \$P ] || { echo unavailable; return 0; }; echo 0 > \$P; cat \$T/trace_stat/function* 2>/dev/null | awk '/hammer2_read_folio/ {n+=\$2} END{print n+0}'; }
for fs in h2 e4 bt; do
	for bs in 1M 64k; do
		echo 3 > /proc/sys/vm/drop_caches
		[ \$fs = h2 ] && prof_start
		t0=\$(now)
		for f in $files; do dd if=/mnt/\$fs/\$f of=/dev/null bs=\$bs status=none; done
		t1=\$(now)
		echo "\$fs read \$bs \$(rate $MIB \$t0 \$t1) MiB/s"
		[ \$fs = h2 ] && echo "h2 read \$bs read_folio calls \$(prof_count)"
	done
done
bad=0; k=0
for f in $files; do
	src=\$(cat /dev/shm/h2tp.src.\$k.md5 2>/dev/null)
	got=\$(md5sum < /mnt/h2/\$f | cut -c1-32)
	[ -n "\$src" ] && [ "\$src" = "\$got" ] || bad=\$((bad + 1))
	k=\$((k + 1))
done
echo "hammer2 md5 \$bad wrong of $WRITERS file(s)"
# The trigger, run against the mounted volume before the counter is read:
# a shared writable mapping of one block faulted on one side while
# writeback runs on the same file from the other, which is the writer
# that can reach a folio the core is reading.  A write(2) cannot, since
# generic_file_write_iter() holds i_rwsem exclusively.
if [ -x /tmp/h2mmaptest ]; then
	# The trigger writes one file per writer, named from the path it is
	# given, so the cleanup takes the whole set by glob and not the bare
	# name.  The subshell keeps the cd out of this shell: a cwd left
	# inside the mount makes the umount below report the volume busy and
	# the module stay in use, which reads as a defect in the driver.
	raceout=\$( (cd /mnt/h2 && /tmp/h2mmaptest /mnt/h2/raced race $RACE_ROUNDS) 2>&1 )
	rc=\$?
	printf '%s\n' "\$raceout" | sed 's/^/race /'
	echo "mmap race exit \$rc"
	rm -f /mnt/h2/raced /mnt/h2/raced.*
	sync -f /mnt/h2
else
	echo "mmap race exit unavailable"
fi
# The write XOP samples the block it hands the core before and after the
# core reads it and counts any change.  A non-zero count is a folio that
# changed while the core was reading it, which is the defect the
# stable-writes rule exists to prevent and which no check code reports:
# the block verifies, and the file can read back content nobody wrote.
# Read after the trigger above and before the module is unloaded, since
# the counter lives on the module.
echo "hammer2 folio_changed \$(cat /sys/module/hammer2/parameters/folio_changed 2>/dev/null || echo unavailable)"
# How often the device-wide io hash lock had to wait, which is the
# reading that decides whether it should be per-bucket as DragonFly's is.
# A relaxed add on the wait path only, so an uncontended acquire costs the
# same as before and a zero here says the coarser lock is not being paid
# for.  Printed, not judged: it is a measurement, not a threshold.
echo "hammer2 iohash_waits \$(cat /sys/module/hammer2/parameters/iohash_waits 2>/dev/null || echo unavailable)"
umount /mnt/h2; echo "second umount exit \$?"; umount /mnt/e4; umount /mnt/bt
echo "kernel warnings \$(dmesg | grep -c 'cut here\|page allocation failure')"
dmesg | grep -m1 -A30 'cut here\|page allocation failure' | head -32
rmmod hammer2; echo "rmmod exit \$?"
GUEST
echo "  built from $built, a $MIB MiB file on a ${vol} MiB volume, ext4 beside it"
# The timed reads are cold in the guest and warm on the host, so the host
# is part of the reading: its load and its free memory are printed with
# the numbers, and the ext4 read below is the control, memcpy from the
# host's cache when the cache is warm and the host's disk when it is not.
echo "  host    load $(cut -d' ' -f1-3 /proc/loadavg), MemAvailable $(awk '/MemAvailable/ {printf "%d", $2/1048576}' /proc/meminfo) GiB"
boot "$GUEST" "$GUEST_SSH" "$EXT4" "$BTRFS" || { down "$GUEST" "$GUEST_SSH"; exit 2; }
# The mmap race trigger, from the harness the other gates already build:
# a shared writable mapping faulted in a loop while writeback runs on
# the same file, which is the one writer that reaches a folio the core
# is reading.  The counter read below is what this run is for; where the
# trigger cannot be built the reading is reported as unavailable rather
# than silently skipped.
MMAPTEST=
if cc -static -O2 -o "$W/mmaptest" test/hammer2-mmap-exercise.c 2>/dev/null; then
	MMAPTEST="$W/mmaptest"
fi
scp -q -o ConnectTimeout=5 "$KO" "$W/linux.sh" "$GUEST_SSH:/tmp/" || { echo "throughput: COULD-NOT-RUN: scp failed" >&2; down "$GUEST" "$GUEST_SSH"; exit 2; }
[ -n "$MMAPTEST" ] && scp -q -o ConnectTimeout=5 "$MMAPTEST" "$GUEST_SSH:/tmp/h2mmaptest" || true
out=$($RUN "$GUEST_SSH" 'sh /tmp/linux.sh' 2>&1); st=$?
printf '%s\n' "$out" | sed 's/^/  linux   /'
down "$GUEST" "$GUEST_SSH"
[ $st = 124 ] && { echo "  FAIL  the guest hung: the run exceeded ${H2_RUN_TIMEOUT:-1800}s"; fail=$((fail + 1)); }
e4=$(printf '%s\n' "$out" | sed -n 's/^e4 read 1M \([0-9]*\) MiB.*/\1/p')
printf '%s\n' "$out" | grep -q "^kernel .* lockdep 1$" && echo "  note  the guest kernel carries CONFIG_PROVE_LOCKING: every number above is the debug kernel's, and a read on the release build of the same kernel measured four times faster"
[ -n "$e4" ] && [ "$e4" -lt 2000 ] && echo "  note  ext4 read $e4 MiB/s: the host's cache was cold, so every read above is the host's disk and compares only with a run that says the same"
if [ "$WRITERS" -gt 1 ]; then
	printf '%s\n' "$out" | grep -q "^hammer2 md5 0 wrong of $WRITERS file(s)$" && {
		echo "  ok    every file reads back from hammer2 with its source hash after a remount"
	} || { echo "  FAIL  the files did not read back with their source hashes after a remount"; fail=$((fail + 1)); }
	# The counter is a checked reading, not a printed one: a folio that
	# changed under the core while writers ran is the defect, and a run
	# that saw none says so here.  A kernel without the counter (a
	# release build of the module) reads "unavailable", which is not a
	# pass and not a failure: it is the instrument saying it cannot
	# answer, and it is why this reading is taken on the debug kernel.
	fc=$(printf '%s\n' "$out" | sed -n 's/^hammer2 folio_changed \([0-9]*\)$/\1/p')
	# The io hash lock's wait count, reported beside the flush seconds so
	# the coarser lock's cost is read where it would show.  Zero is a
	# finding here rather than a pass: it says the lock never waited.
	# The lock's wait count beside its total acquisitions, so the number
	# is a rate and not a raw count: whether the coarser lock costs
	# anything is the share of acquisitions that had to wait, and a
	# reading of the count alone cannot say.
	iw=$(printf '%s\n' "$out" | sed -n 's/^hammer2 iohash_waits \([0-9]*\),\([0-9]*\)$/\1 \2/p')
	echo "  note  io hash lock waited ${iw:-unavailable} of ${iw:+$(printf '%s' "$iw" | cut -d" " -f2)} acquisition(s) with $WRITERS writer(s)"
	case "${fc:-unavailable}" in
	0) echo "  ok    no block changed under the core with $WRITERS writers" ;;
	unavailable) echo "  note  folio_changed is not in this module: the reading is the debug kernel's" ;;
	*) echo "  FAIL  $fc block(s) changed while the core was reading them"; fail=$((fail + 1)) ;;
	esac
	for fs in h2 e4 bt; do
		expected=0
		while [ "$expected" -lt "$REPEAT" ]; do
			for want in "^$fs concurrent buffered_write [0-9]* MiB/s (run $expected, $WRITERS writers)$" \
			    "^$fs concurrent write refusals 0 (run $expected, $WRITERS writers)$" \
			    "^$fs concurrent syncfs [0-9.]* s (run $expected, $WRITERS writers)$" \
			    "^$fs concurrent syncfs exit 0 (run $expected, $WRITERS writers)$" \
			    "^$fs concurrent write [0-9]* MiB/s (run $expected, $WRITERS writers)$" \
			    "^$fs concurrent hash mismatches 0 (run $expected, $WRITERS writers)$"; do
				printf '%s\n' "$out" | grep -q "$want" || { echo "  FAIL  wanted $want"; fail=$((fail + 1)); }
			done
			expected=$((expected + 1))
		done
	done
else
	printf '%s\n' "$out" | grep -q "^hammer2 md5 0 wrong of 1 file(s)$" && {
		echo "  ok    the file reads back from hammer2 with the source hash after a remount"
	} || { echo "  FAIL  the file did not read back with its source hash after a remount"; fail=$((fail + 1)); }
	printf '%s\n' "$out" | grep -q " write refused " && { echo "  FAIL  a write was refused: $(printf '%s\n' "$out" | grep ' write refused ' | tr '\n' ';')"; fail=$((fail + 1)); }
	nw=$(printf '%s\n' "$out" | grep -c "^h2 write [0-9]* MiB/s (run [0-9]*)$")
	[ "$nw" = "$REPEAT" ] || { echo "  FAIL  $nw hammer2 write readings for $REPEAT run(s)"; fail=$((fail + 1)); }
	for want in "^h2 write [0-9]* MiB/s (run 0)" "^e4 write [0-9]* MiB/s (run 0)" "^h2 buffered_write [0-9]* MiB/s (run 0)" "^h2 syncfs [0-9.]* s (run 0)" "^h2 read 1M [0-9]* MiB/s" "^h2 read 64k [0-9]* MiB/s" "^e4 read 1M [0-9]* MiB/s" "^e4 read 64k [0-9]* MiB/s" "^bt write [0-9]* MiB/s (run 0)" "^bt read 1M [0-9]* MiB/s" "^bt read 64k [0-9]* MiB/s" "^hammer2 umount exit 0$" "^second umount exit 0$" "^rmmod exit 0$" "^kernel warnings 0$" "^kernel [0-9].* lockdep [01]$"; do
		printf '%s\n' "$out" | grep -q "$want" || { echo "  FAIL  wanted $want"; fail=$((fail + 1)); }
	done
fi
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "  ok    host fsck_hammer2 after linux" || { echo "  FAIL  host fsck_hammer2 after linux"; fail=$((fail + 1)); }
fsck_control "$IMG" || fail=$((fail + 1))

# 2. DragonFly writes the reference file to the same volume.
cat > "$W/dfly.sh" <<GUEST
mkdir -p /mnt/tp
mount_hammer2 /dev/vbd1@ROOT /mnt/tp || { echo "mount failed"; exit 1; }
t0=\$(date +%s)
dd if=/dev/random of=/mnt/tp/big.dfly bs=1m count=$MIB 2>/dev/null; sync; t1=\$(date +%s)
echo "dragonfly wrote $MIB MiB in \$((t1 - t0)) s"
umount /mnt/tp; mount_hammer2 /dev/vbd1@ROOT /mnt/tp || { echo "remount failed"; exit 1; }
for f in $files big.dfly; do dd if=/mnt/tp/\$f of=/dev/null bs=1m 2>/dev/null; done
umount /mnt/tp; mount_hammer2 /dev/vbd1@ROOT /mnt/tp || { echo "remount failed"; exit 1; }
for f in $files big.dfly; do
	r=\$(dd if=/mnt/tp/\$f of=/dev/null bs=1m 2>&1 | sed -n 's/.*(\\([0-9]*\\) bytes\\/sec).*/\\1/p')
	echo "dragonfly read \$f \$((\${r:-0} / 1048576)) MiB/s"
done
umount /mnt/tp; echo "dragonfly umount exit \$?"
GUEST
boot "$DFLY" "$DFLY_SSH" || { down "$DFLY" "$DFLY_SSH"; exit 2; }
scp -q -o ConnectTimeout=5 "$W/dfly.sh" "$DFLY_SSH:/tmp/" || { echo "throughput: COULD-NOT-RUN: scp failed" >&2; down "$DFLY" "$DFLY_SSH"; exit 2; }
dout=$($RUN "$DFLY_SSH" 'sh /tmp/dfly.sh' 2>&1); st=$?
printf '%s\n' "$dout" | sed 's/^/  dfly    /'
down "$DFLY" "$DFLY_SSH"
for f in $files; do
	printf '%s\n' "$dout" | grep -q "^dragonfly read $f [1-9][0-9]* MiB/s" || {
		echo "  FAIL  wanted ^dragonfly read $f [1-9][0-9]* MiB/s"; fail=$((fail + 1)); }
done
printf '%s\n' "$dout" | grep -q "^dragonfly read big.dfly [1-9][0-9]* MiB/s" || {
	echo "  FAIL  wanted ^dragonfly read big.dfly [1-9][0-9]* MiB/s"; fail=$((fail + 1)); }
printf '%s\n' "$dout" | grep -q "^dragonfly umount exit 0$" || { echo "  FAIL  dragonfly did not write and unmount the reference file"; fail=$((fail + 1)); }
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "  ok    host fsck_hammer2 after dragonfly" || { echo "  FAIL  host fsck_hammer2 after dragonfly"; fail=$((fail + 1)); }
fsck_control "$IMG" || fail=$((fail + 1))

# 3. The layouts, from the image. `hammer2 show` prints every blockref in
# key order with its media offset; the low six bits of the offset are the
# radix. A name longer than the inode's inline field lives in a directory
# entry that carries the inode number, and the inode body prints only
# that number, so the name is resolved first and the data blockrefs are
# counted under the inode whose number it is. A step is contiguous when
# the next block sits one block after the last, forward when it sits
# anywhere after, backward otherwise.
if "$SHOW" show "$IMG" > "$W/show" 2>&1; then :; else
	echo "  FAIL  hammer2 show exit $? on $IMG: $(head -3 "$W/show" | tr '\n' ' ')"; fail=$((fail + 1))
fi
layout() {	# layout <name>
	inum=$(awk -v name="$1" '
		/^ *filename "/ { pend = $0; sub(/^ *filename "/, "", pend); sub(/".*/, "", pend); next }
		/^ *inum +0x/ { if (pend == name) print $2; pend = "" }
	' "$W/show" | head -1)
	awk -v want="$inum" '
		/^ *inum +0x/ { cur = $2 }
		/^ *data\.[0-9]+ / { if (want != "" && cur == want) print $2 }
	' "$W/show" | awk '
		{ off = strtonum("0x" $1); off -= off % 64; n++
		  if (n > 1) { if (off == last + 65536) c++; else if (off > last) f++; else b++ }
		  last = off }
		END { printf "%d %d %d %d\n", n, c + 0, f + 0, b + 0 }'
}
for f in $files; do
	set -- $(layout "$f")
	echo "  layout  $f: $1 data blocks, $2 contiguous steps, $3 forward jumps, $4 backward jumps"
	[ "$1" = "$((PER_MIB * 16))" ] || { echo "  FAIL  $f has $1 data blocks, not $((PER_MIB * 16))"; fail=$((fail + 1)); }
done
set -- $(layout "big.dfly")
echo "  layout  big.dfly: $1 data blocks, $2 contiguous steps, $3 forward jumps, $4 backward jumps"
[ "$1" = "$((MIB * 16))" ] || { echo "  FAIL  big.dfly has $1 data blocks, not $((MIB * 16))"; fail=$((fail + 1)); }

rm -f "$EXT4" "$BTRFS"
echo "throughput: a $MIB MiB file written both ways and read back, $fail failure(s)"
[ $fail = 0 ]
