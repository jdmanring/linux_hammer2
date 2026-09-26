#!/bin/sh
# Per-operation latency: random 4 KiB and fsync, on this port and on the
# reference filesystems beside it.
#
# Every performance number this tree had was sequential.  Sequential
# throughput is where a copy-on-write filesystem with 64 KiB blocks and a
# checksum per block is expected to look good; random small I/O and the
# cost of making one write durable are where the same design is expected
# to pay, and neither was measured anywhere here.  The instrument that
# says nothing about the other half is `throughput.sh`, so this is the
# other half rather than an edit to it.
#
# The measurement itself lives in `test/hammer2-latency.c` because
# percentiles over per-operation timings cannot be taken honestly in
# shell.  That binary runs on three filesystems in one guest: HAMMER2,
# ext4 and btrfs.  On the last two it is the negative control, since a
# reading that could not come out any other way is not a measurement, and
# `tmpfs` is refused on the host as a fourth because a latency served
# from the page cache is not a filesystem's.
#
# A cache reading is the failure this is built around.  A random read
# answered from memory reports hundreds of nanoseconds and would flatter
# every filesystem equally, so the exerciser asserts a median above a
# microsecond and the driving side drops the caches before each pass,
# with the file sized well above the guest's RAM.
#
# Throughput is printed, never judged: a run fails on a kernel warning, a
# missing reading, a hash mismatch or a filesystem that did not answer.
# The numbers are a comparison, and the comparison is the point.
#
# Exits 2 without the fleet or the tools. Not a gate.
#
#   H2_LAT_MIB=1024          file size, MiB (must exceed the guest's RAM)
#   H2_LAT_OPS=2000          operations per pass
#   H2_LAT_IMAGE             the HAMMER2 image (H2_FIXTURE_DIR by default)
#   H2_LAT_MODARGS           module parameters for the guest's insmod
#   KDIR                     the kernel of record's build tree, required

# Run from a private copy so an edit to this file during a run cannot be
# read by the shell mid-way; throughput.sh does the same.
if [ -z "${H2_LAT_COPY:-}" ]; then
	cd "$(dirname "$0")/.." || exit 2
	c=$(mktemp) || exit 2
	cp "$0" "$c" || exit 2
	H2_LAT_COPY=$c exec sh "$c" "$@"
fi
trap 'rm -f "$H2_LAT_COPY"' EXIT

FIXDIR=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}
IMG=${H2_LAT_IMAGE:-$FIXDIR/latency.img}
EXT4=${H2_LAT_EXT4:-$FIXDIR/latency-ext4.img}
BTRFS=${H2_LAT_BTRFS:-$FIXDIR/latency-btrfs.img}
MIB=${H2_LAT_MIB:-1024}
OPS=${H2_LAT_OPS:-2000}
MODARGS=${H2_LAT_MODARGS:-}
REPEAT=${H2_REPEAT:-1}
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
UTILS=$HOME/Projects/hammer2-utils-upstream/target/release
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$UTILS/newfs_hammer2")}
FSCK=${H2_FSCK:-$(command -v fsck_hammer2 2>/dev/null || echo "$UTILS/fsck_hammer2")}
W=$(mktemp -d) || exit 2
RUN="timeout ${H2_RUN_TIMEOUT:-3600} ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
fail=0

# The numbers are compared between filesystems, so the guest and its
# memory are part of the reading: a latency taken on a guest whose page
# cache holds the whole file is a cache reading whatever the exerciser
# does, and the file size below is chosen against the guest's RAM so that
# cannot happen.  Both are printed.
case "$MIB" in ''|*[!0-9]*) echo "latency: COULD-NOT-RUN: H2_LAT_MIB is not a number" >&2; exit 2 ;; esac
case "$OPS" in ''|*[!0-9]*) echo "latency: COULD-NOT-RUN: H2_LAT_OPS is not a number" >&2; exit 2 ;; esac
[ "$MIB" -gt 0 ] || { echo "latency: COULD-NOT-RUN: H2_LAT_MIB must be positive" >&2; exit 2; }
[ "$OPS" -gt 0 ] || { echo "latency: COULD-NOT-RUN: H2_LAT_OPS must be positive" >&2; exit 2; }
[ "$MIB" -ge 256 ] || { echo "latency: COULD-NOT-RUN: H2_LAT_MIB below 256 MiB cannot exceed a guest's cache" >&2; exit 2; }

command -v virsh >/dev/null 2>&1 || { echo "latency: COULD-NOT-RUN: no virsh" >&2; exit 2; }
[ -f "$KDIR/Makefile" ] || { echo "latency: COULD-NOT-RUN: KDIR=$KDIR is not a build tree" >&2; exit 2; }
case "$(uname -r)" in
7.3*) ;;
*) grep -q '^VERSION = 7' "$KDIR/Makefile" 2>/dev/null || :
   grep -q '^PATCHLEVEL = 3' "$KDIR/Makefile" 2>/dev/null || {
	echo "latency: COULD-NOT-RUN: KDIR=$KDIR is below the 7.3 floor;" >&2
	echo "          point KDIR at the guest's kernel tree" >&2; exit 2; } ;;
esac

# The module has to be the one this tree builds, or the reading is of an
# older port.  Built here against the kernel of record, as every fleet
# script does, and the build is the gate that says it is sound.  The paths
# are relative to the repository root, which the re-exec above set as the
# cwd, so they resolve the same in the private copy as in the tree.
make -s clean >/dev/null 2>&1
make -s KDIR="$KDIR" >/dev/null 2>&1 || {
	echo "latency: COULD-NOT-RUN: the module did not build" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko
[ -f "$KO" ] || { echo "latency: COULD-NOT-RUN: no $KO" >&2; exit 2; }

# The exerciser, compiled on the host and run on the guest.  Static, since
# the guest need not carry a matching libc.
cc -static -O2 -o "$W/h2lat" test/hammer2-latency.c 2>/dev/null || {
	echo "latency: COULD-NOT-RUN: the latency exerciser did not compile" >&2; exit 2; }

# Three images.  HAMMER2 is this port's; ext4 and btrfs are the controls,
# and each is given a filesystem here.  The first version of this wrote
# the two control images with `truncate` alone and left them raw, so both
# refused to mount and the run produced no control readings at all while
# its own mount check, not this comment, was the only thing that said so.
vol=$((MIB * 3 + 512))
rm -f "$IMG" "$EXT4" "$BTRFS"
truncate -s "${vol}M" "$IMG" && "$NEWFS" -L ROOT "$IMG" >/dev/null 2>&1 || {
	echo "latency: COULD-NOT-RUN: newfs_hammer2 failed on $IMG" >&2; exit 2; }
truncate -s "${vol}M" "$EXT4" && mkfs.ext4 -q -F "$EXT4" >/dev/null 2>&1 || {
	echo "latency: COULD-NOT-RUN: mkfs.ext4 failed on $EXT4" >&2; exit 2; }
truncate -s "${vol}M" "$BTRFS" && mkfs.btrfs -q -f "$BTRFS" >/dev/null 2>&1 || {
	echo "latency: COULD-NOT-RUN: mkfs.btrfs failed on $BTRFS" >&2; exit 2; }
# Assert each image carries the filesystem just written.  A `mkfs` that
# wrote nothing leaves a file that looks right and mounts nowhere.  The
# match is case-insensitive because the two tools do not agree on case:
# `file` reports "ext4 filesystem data" but "BTRFS Filesystem".
for pair in "$EXT4:ext4" "$BTRFS:btrfs"; do
	i=${pair%:*}; want=${pair##*:}
	got=$(file -b "$i" 2>/dev/null)
	case "$(printf '%s' "$got" | tr 'A-Z' 'a-z')" in
	*"$want"*) ;;
	*) echo "latency: COULD-NOT-RUN: $i is '$got', not a $want filesystem" >&2; exit 2 ;;
	esac
done

boot() {
	# The start's own error is kept.  Swallowing it made a run report
	# "did not start" for three attempts with the cause nowhere, which is
	# the shape a check must not have: the message named the guest and
	# the reason was discarded before anyone could read it.
	$VIRSH attach-disk "$GUEST" "$IMG" vdb --targetbus virtio --config 2>&1 | sed 's/^/  attach vdb: /'
	$VIRSH attach-disk "$GUEST" "$EXT4" vdc --targetbus virtio --config 2>&1 | sed 's/^/  attach vdc: /'
	$VIRSH attach-disk "$GUEST" "$BTRFS" vdd --targetbus virtio --config 2>&1 | sed 's/^/  attach vdd: /'
	serr=$($VIRSH start "$GUEST" 2>&1)
	src=$?
	if [ "$src" != 0 ]; then
		printf '%s\n' "$serr" | sed 's/^/  start: /' >&2
		echo "latency: COULD-NOT-RUN: $GUEST did not start (rc=$src)" >&2
		return 1
	fi
	n=0
	until ssh -o ConnectTimeout=3 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null; do
		sleep 5; n=$((n + 1))
		[ $n -gt 60 ] && { echo "latency: COULD-NOT-RUN: $GUEST did not answer ssh in 5 minutes" >&2; return 1; }
	done
	return 0
}
down() {
	ssh -o ConnectTimeout=5 "$GUEST_SSH" 'sync; poweroff' >/dev/null 2>&1
	n=0
	until [ "$($VIRSH domstate "$GUEST" 2>/dev/null)" = "shut off" ]; do
		sleep 3; n=$((n + 1)); [ $n -gt 60 ] && { $VIRSH destroy "$GUEST" >/dev/null 2>&1; break; }
	done
	$VIRSH detach-disk "$GUEST" vdb --config >/dev/null 2>&1
	$VIRSH detach-disk "$GUEST" vdc --config >/dev/null 2>&1
	$VIRSH detach-disk "$GUEST" vdd --config >/dev/null 2>&1
}

state=$($VIRSH domstate "$GUEST" 2>/dev/null | tr -d '\r')
# A guest already running is refused rather than reused.  Its disks are
# whatever the last run attached, which may be nothing, and this script
# has no way to tell that apart from the set it is about to make: the
# first version of this read "running" as "already booted" and skipped the
# attach, so the run mounted nothing and reported COULD-NOT-RUN for a
# reason that named the guest instead of the missing disks.
case "$state" in
shut*|"") boot || exit 2 ;;
*) echo "latency: COULD-NOT-RUN: $GUEST is $state; the images this run made" >&2
   echo "        cannot be attached to it, so shut it down and rerun" >&2; exit 2 ;;
esac

scp -q -o ConnectTimeout=5 "$W/h2lat" "$GUEST_SSH:/tmp/h2lat" >/dev/null 2>&1 || {
	echo "latency: COULD-NOT-RUN: could not copy the exerciser to the guest" >&2
	down; exit 2; }
scp -q -o ConnectTimeout=5 "$KO" "$GUEST_SSH:/tmp/hammer2.ko" >/dev/null 2>&1 || {
	echo "latency: COULD-NOT-RUN: could not copy the module to the guest" >&2
	down; exit 2; }

# The host's tmpfs is the fourth control and needs no guest: it is what a
# reading served from memory looks like, and it must fail the exerciser's
# own cache check so that the check is known to be live.
echo "== tmpfs, the cache control (must report cache speed and fail its own check)"
mkdir -p /tmp/latctl
/tmp/h2lat /tmp/latctl tmpfs 64 200 2>&1 | sed 's/^/  /'
rmdir /tmp/latctl 2>/dev/null

n=0
while [ "$n" -lt "$REPEAT" ]; do
	i=0
	while [ "$i" -lt 3 ]; do
		fs=
		case $i in
		0) fs=h2 ;;
		1) fs=e4 ;;
		2) fs=bt ;;
		esac
		out=$($RUN "$GUEST_SSH" "
			set -u
			insmod /tmp/hammer2.ko $MODARGS 2>/dev/null || true
			mkdir -p /mnt/h2 /mnt/e4 /mnt/bt
			mount -t hammer2 /dev/vdb@ROOT /mnt/h2 2>/dev/null || echo 'h2 mount refused'
			mount -t ext4 /dev/vdc /mnt/e4 2>/dev/null || echo 'e4 mount refused'
			mount -t btrfs /dev/vdd /mnt/bt 2>/dev/null || echo 'bt mount refused'
			echo \"guest kernel \$(uname -r), mem \$(awk '/MemTotal/{printf \"%d\", \$2/1024}' /proc/meminfo) MiB\"
			# The measurement runs only if the filesystem under test is
			# actually mounted.  Without this the binary would write to
			# the mount point as an ordinary directory on the guest's
			# root filesystem and print a full set of readings that
			# describe the root filesystem instead: the first run of
			# this script did exactly that for ext4 and btrfs, whose
			# images had been created and never formatted, and the two
			# "controls" then agreed with each other to within one
			# percent because they were the same filesystem.
			if mountpoint -q /mnt/$fs; then
				# The cache is dropped before the pass that reads, so a
				# random read reaches the media.  It is not dropped before
				# the write passes, where it would only add noise.
				sync; echo 3 > /proc/sys/vm/drop_caches
				dmesg -C
				/tmp/h2lat /mnt/$fs $fs $MIB $OPS 2>&1
				echo \"kernel warnings \$(dmesg | grep -c 'cut here\|page allocation failure')\"
			else
				echo \"SKIP /mnt/$fs is not a mount point, so no reading was taken\"
			fi
			umount /mnt/h2 /mnt/e4 /mnt/bt 2>/dev/null
			rmmod hammer2 2>/dev/null || true
		" 2>&1)
		printf '%s\n' "$out" | sed 's/^/  /'
		# A pass whose own filesystem was not mounted took no reading,
		# and that is a failure rather than a skip to record: a missing
		# control is the reason to distrust every number beside it.
		if printf '%s\n' "$out" | grep -q "^SKIP /mnt/${fs} is not a mount point"; then
			echo "  FAIL  $fs was not mounted, so this pass took no reading"
			fail=$((fail + 1))
			i=$((i + 1)); continue
		fi
		printf '%s\n' "$out" | grep -q "^${fs} mount refused" && { echo "  FAIL  $fs did not mount"; fail=$((fail + 1)); }
		# A pass that ran must report its three readings.  A missing one
		# is the failure this catches: a loop that silently skipped the
		# measurement would otherwise read as a clean run.
		for m in randread4k randwrite4k_fsync fsync_batch8; do
			printf '%s\n' "$out" | grep -q "^lat-summary $fs $m " || {
				echo "  FAIL  $fs produced no $m reading"; fail=$((fail + 1)); }
		done
		printf '%s\n' "$out" | grep -q "^lat-failures 0" || {
			echo "  FAIL  $fs reported a failed check"; fail=$((fail + 1)); }
		printf '%s\n' "$out" | grep -q "^kernel warnings 0" || {
			echo "  FAIL  $fs run left a kernel warning"; fail=$((fail + 1)); }
		i=$((i + 1))
	done
	n=$((n + 1))
done

"$FSCK" "$IMG" >/dev/null 2>&1 && echo "  ok    host fsck_hammer2 after the run" || {
	echo "  FAIL  host fsck_hammer2 after the run"; fail=$((fail + 1)); }

down
rm -rf "$W"
echo "latency: $REPEAT pass(es) at $OPS op(s) over a $MIB MiB file, $fail failure(s)"
[ "$fail" = 0 ]
