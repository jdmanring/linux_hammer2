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
#   H2_TP_MIB=512            size of the file, MiB
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

# Both volumes hold the file four times over, so neither fills.
vol=$((MIB * 4 + 256))
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
	$VIRSH start "$1" >/dev/null 2>&1 || { echo "  FAIL  $1 did not start"; return 1; }
	n=0
	until ssh -o ConnectTimeout=3 -o BatchMode=yes "$2" true 2>/dev/null; do
		sleep 5; n=$((n + 1)); [ $n -gt 60 ] && { echo "  FAIL  $1 did not answer ssh"; return 1; }
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
head -c $((MIB * 1024 * 1024)) /dev/urandom > /dev/shm/src || { echo "no source"; exit 1; }
src=\$(md5sum < /dev/shm/src | cut -c1-32)
echo "source $MIB MiB md5 \$src"
for fs in h2 e4 bt; do
	t0=\$(now); dd if=/dev/shm/src of=/mnt/\$fs/big bs=1M conv=fsync status=none; t1=\$(now)
	echo "\$fs write \$(rate $MIB \$t0 \$t1) MiB/s"
done
umount /mnt/h2; echo "hammer2 umount exit \$?"; umount /mnt/e4; umount /mnt/bt
mount -t hammer2 /dev/vdb@ROOT /mnt/h2 || { echo "hammer2 remount failed"; exit 1; }
mount -t ext4 /dev/vdc /mnt/e4; mount -t btrfs /dev/vdd /mnt/bt
# One unmeasured read of each file first: the images are files on the
# host, and the first read of one after a write goes to the host's disk
# while the next hits the host's cache, a difference of ten times that
# is the host's and not the driver's.  Every timed read below is cold
# in the guest and warm on the host, which is the driver's own cost.
for fs in h2 e4 bt; do dd if=/mnt/\$fs/big of=/dev/null bs=1M status=none; done
sync; echo 3 > /proc/sys/vm/drop_caches
for fs in h2 e4 bt; do
	for bs in 1M 64k; do
		echo 3 > /proc/sys/vm/drop_caches
		t0=\$(now); dd if=/mnt/\$fs/big of=/dev/null bs=\$bs status=none; t1=\$(now)
		echo "\$fs read \$bs \$(rate $MIB \$t0 \$t1) MiB/s"
	done
done
echo "hammer2 md5 \$(md5sum < /mnt/h2/big | cut -c1-32)"
umount /mnt/h2; echo "second umount exit \$?"; umount /mnt/e4; umount /mnt/bt
echo "kernel warnings \$(dmesg | grep -c 'cut here\|page allocation failure')"
dmesg | grep -m1 -A30 'cut here\|page allocation failure' | head -32
rmmod hammer2; echo "rmmod exit \$?"
GUEST
echo "  built from $built, a $MIB MiB file on a ${vol} MiB volume, ext4 beside it"
boot "$GUEST" "$GUEST_SSH" "$EXT4" "$BTRFS" || { down "$GUEST" "$GUEST_SSH"; exit 2; }
scp -q -o ConnectTimeout=5 "$KO" "$W/linux.sh" "$GUEST_SSH:/tmp/" || { echo "throughput: COULD-NOT-RUN: scp failed" >&2; down "$GUEST" "$GUEST_SSH"; exit 2; }
out=$($RUN "$GUEST_SSH" 'sh /tmp/linux.sh' 2>&1); st=$?
printf '%s\n' "$out" | sed 's/^/  linux   /'
down "$GUEST" "$GUEST_SSH"
[ $st = 124 ] && { echo "  FAIL  the guest hung: the run exceeded ${H2_RUN_TIMEOUT:-1800}s"; fail=$((fail + 1)); }
src=$(printf '%s\n' "$out" | sed -n 's/^source .* md5 //p')
got=$(printf '%s\n' "$out" | sed -n 's/^hammer2 md5 //p')
if [ -n "$src" ] && [ "$src" = "$got" ]; then
	echo "  ok    the file reads back from hammer2 with the source hash after a remount"
else
	echo "  FAIL  hammer2 hash '$got' is not the source hash '$src'"; fail=$((fail + 1))
fi
for want in "^h2 write [0-9]* MiB/s" "^e4 write [0-9]* MiB/s" "^h2 read 1M [0-9]* MiB/s" "^h2 read 64k [0-9]* MiB/s" "^e4 read 1M [0-9]* MiB/s" "^e4 read 64k [0-9]* MiB/s" "^bt write [0-9]* MiB/s" "^bt read 1M [0-9]* MiB/s" "^bt read 64k [0-9]* MiB/s" "^hammer2 umount exit 0$" "^second umount exit 0$" "^rmmod exit 0$" "^kernel warnings 0$"; do
	printf '%s\n' "$out" | grep -q "$want" || { echo "  FAIL  wanted $want"; fail=$((fail + 1)); }
done
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
for f in big big.dfly; do dd if=/mnt/tp/\$f of=/dev/null bs=1m 2>/dev/null; done
umount /mnt/tp; mount_hammer2 /dev/vbd1@ROOT /mnt/tp || { echo "remount failed"; exit 1; }
for f in big big.dfly; do
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
for want in "^dragonfly read big [1-9][0-9]* MiB/s" "^dragonfly read big.dfly [1-9][0-9]* MiB/s"; do
	printf '%s\n' "$dout" | grep -q "$want" || { echo "  FAIL  wanted $want"; fail=$((fail + 1)); }
done
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
for f in big big.dfly; do
	set -- $(layout "$f")
	echo "  layout  $f: $1 data blocks, $2 contiguous steps, $3 forward jumps, $4 backward jumps"
	[ "$1" = "$((MIB * 16))" ] || { echo "  FAIL  $f has $1 data blocks, not $((MIB * 16))"; fail=$((fail + 1)); }
done

rm -f "$EXT4" "$BTRFS"
echo "throughput: a $MIB MiB file written both ways and read back, $fail failure(s)"
[ $fail = 0 ]
