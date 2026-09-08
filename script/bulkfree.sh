#!/bin/sh
# A delete frees nothing on hammer2 until bulkfree runs twice. The
# freemap is rebuilt by a scan, not decremented by a remove: the first
# pass moves a block nothing references from allocated to staged, and
# the next pass frees what stayed staged, so a volume that has had
# files removed reports the same free count until two scans have
# walked it, with a sync between. The storage model's collection row
# and its space accounting both turn on that scan running here, and it
# never had: the ioctl was carried and answered, and no run had asked
# for it. The first run of this script asked once and read nothing
# freed; DragonFly's pass over the same volume then freed the set,
# which is the second pass doing what the second pass does.
#
# Linux writes a set of files, removes them, and reads the free count
# after each step and after each of two passes, with the pass
# statistics the kernel prints; then writes the set again and removes
# it. DragonFly mounts the result and runs one pass, which should
# stage the second set and free nothing, and its count says whether
# this side's two passes left anything staged.
#
# Exit 2 without the two guests, the tools or a kernel tree. One guest at
# a time: the Linux guest writes and is shut down, then DragonFly reads.
set -u
FIXDIR=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}
IMG=${H2_BF_IMAGE:-$FIXDIR/bulkfree.img}
ROOT=${H2_BF_ROOT:-ROOT}
MB=${H2_BF_MB:-800}	# the set, in 1 MB random files; the volume is 2G
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
DFLY=${H2_DFLY_GUEST:-dragonflybsd642}
DFLY_SSH=${H2_DFLY_SSH:-root@192.168.122.42}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2")}
FSCK=${H2_FSCK:-$(command -v fsck_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2")}
W=$(mktemp -d) || exit 2
# The long runs are bounded from this side. A guest whose task hangs, on a
# hung mount or a wedged unmount, keeps sshd answering and the ssh open,
# and the script would wait on it forever; the fuzzer bounds each image
# the same way. 124 from timeout is reported as the guest hanging, which
# is a finding, not a pass and not a skip.
RUN="timeout ${H2_RUN_TIMEOUT:-1800} ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
trap 'rm -rf "$W"' EXIT

# The negative control for every host fsck verdict, as the other fleet
# scripts carry it: a sparse copy with one header byte complemented must
# fail the same checker naming the header CRC.
fsck_control() {	# image
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

command -v virsh >/dev/null 2>&1 || { echo "bulkfree: COULD-NOT-RUN: no virsh" >&2; exit 2; }
[ -x "$NEWFS" ] || { echo "bulkfree: COULD-NOT-RUN: no newfs_hammer2 (H2_NEWFS)" >&2; exit 2; }
[ -x "$FSCK" ] || { echo "bulkfree: COULD-NOT-RUN: no fsck_hammer2 (H2_FSCK)" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "bulkfree: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -d "$KDIR" ] || { echo "bulkfree: COULD-NOT-RUN: no kernel tree at $KDIR" >&2; exit 2; }
for g in "$GUEST" "$DFLY"; do
	$VIRSH domstate "$g" >/dev/null 2>&1 || { echo "bulkfree: COULD-NOT-RUN: no guest $g" >&2; exit 2; }
done
[ -z "$($VIRSH list --name | tr -d ' \n')" ] || {
	echo "bulkfree: COULD-NOT-RUN: a guest is running: $($VIRSH list --name | tr '\n' ' ')" >&2; exit 2; }

make -s clean >/dev/null 2>&1
make -s KDIR="$KDIR" >/dev/null 2>&1 || {
	echo "bulkfree: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko

rm -f "$IMG"
truncate -s 2G "$IMG" && "$NEWFS" -L "$ROOT" "$IMG" >/dev/null 2>&1 || {
	echo "bulkfree: COULD-NOT-RUN: newfs_hammer2 failed on $IMG" >&2; exit 2; }

fail=0
boot() {	# boot <guest> <ssh>; the image is attached first
	$VIRSH attach-disk "$1" "$IMG" vdb --targetbus virtio --config >/dev/null 2>&1
	$VIRSH start "$1" >/dev/null 2>&1 || { echo "  COULD-NOT-RUN  $1 did not start"; return 1; }
	n=0
	until ssh -o ConnectTimeout=3 -o BatchMode=yes "$2" true 2>/dev/null; do
		sleep 5; n=$((n + 1)); [ $n -gt 60 ] && { echo "  COULD-NOT-RUN  $1 did not answer ssh in 5 minutes, host load $(cut -d" " -f1-3 /proc/loadavg)"; return 1; }
	done
	return 0	# not the status of the loop's last test
}
down() {	# down <guest> <ssh>
	ssh -o ConnectTimeout=5 "$2" 'sync; poweroff' >/dev/null 2>&1
	n=0
	until [ "$($VIRSH domstate "$1")" = "shut off" ]; do
		sleep 3; n=$((n + 1)); [ $n -gt 60 ] && { $VIRSH destroy "$1" >/dev/null 2>&1; break; }
	done
	$VIRSH detach-disk "$1" vdb --config >/dev/null 2>&1
}

# 1. Linux writes, removes, scans, and writes again.
cat > "$W/linux.sh" <<GUEST
command -v hammer2 >/dev/null 2>&1 || { echo "no hammer2 utility on the guest"; exit 3; }
dev=\$(ls /dev/vd? | tail -1); mkdir -p /mnt/bf
rmmod hammer2 2>/dev/null; insmod /tmp/hammer2.ko || exit 1; dmesg -C
mount -t hammer2 \$dev@$ROOT /mnt/bf || { echo "mount failed"; exit 1; }
free() { stat -f -c %f /mnt/bf; }
echo "free at mount \$(free)"
write_set() {
	i=0; n=0; while [ \$i -lt $MB ]; do
		dd if=/dev/urandom of=/mnt/bf/\$1.\$i bs=1M count=1 status=none 2>/dev/null && n=\$((n + 1))
		i=\$((i + 1))
	done
	sync; echo "\$1 wrote \$n of $MB files, free \$(free)"
}
write_set first
rm -f /mnt/bf/first.*; sync
echo "after remove free \$(free)"
for pass in 1 2; do
	dmesg -C
	t0=\$(date +%s); hammer2 -s /mnt/bf bulkfree /mnt/bf > /tmp/bf.out 2>&1; bst=\$?; t1=\$(date +%s)
	sync; echo "pass \$pass exit \$bst in \$((t1 - t0)) s, free \$(free)"
	sed -n '1,4p' /tmp/bf.out
	dmesg | sed -n 's/^\[[^]]*\] *//p' | grep -E 'bulkfree pass statistics|transition->|CRC|aborted' | sed "s/^/pass \$pass: /"
done
write_set second
rm -f /mnt/bf/second.*; sync
umount /mnt/bf; echo "umount exit \$?"
echo "debug_locks \$(awk '/debug_locks:/{print \$2}' /proc/lockdep_stats)"; echo "kmsg lines \$(dmesg | wc -l)"; dmesg | grep -c -i 'WARNING\|BUG\|hung task' | sed 's/^/reports /'
rmmod hammer2; echo "rmmod exit \$?"
GUEST
boot "$GUEST" "$GUEST_SSH" || { down "$GUEST" "$GUEST_SSH"; exit 2; }
scp -q -o ConnectTimeout=5 "$KO" "$W/linux.sh" "$GUEST_SSH:/tmp/" || { echo "bulkfree: COULD-NOT-RUN: scp failed" >&2; down "$GUEST" "$GUEST_SSH"; exit 2; }
out=$($RUN "$GUEST_SSH" 'sh /tmp/linux.sh' 2>&1); st=$?
printf '%s\n' "$out" | sed 's/^/  linux   /'
down "$GUEST" "$GUEST_SSH"
[ $st = 3 ] && { echo "bulkfree: COULD-NOT-RUN: the Linux guest has no hammer2 utility" >&2; exit 2; }
[ $st = 124 ] && { echo "  FAIL  the guest hung: the run exceeded ${H2_RUN_TIMEOUT:-1800}s"; fail=$((fail + 1)); }
f0=$(printf '%s\n' "$out" | sed -n 's/^free at mount //p')
f1=$(printf '%s\n' "$out" | sed -n 's/^first wrote .* free //p')
f2=$(printf '%s\n' "$out" | sed -n 's/^after remove free //p')
f3=$(printf '%s\n' "$out" | sed -n 's/^pass 2 exit .* free //p')
staged=$(printf '%s\n' "$out" | sed -n 's/^pass 1: .*transition->staged *//p')
freed=$(printf '%s\n' "$out" | sed -n 's/^pass 2: .*transition->free *//p')
f4=$(printf '%s\n' "$out" | sed -n 's/^second wrote .* free //p')
printf '%s\n' "$out" | grep -q "^first wrote $MB of $MB files" || { echo "  FAIL  the first set did not all write"; fail=$((fail + 1)); }
# The control: the remove alone must not have freed the set, or the scan
# is not what is being measured.
if [ -n "$f1" ] && [ -n "$f2" ] && [ "$f2" -lt $((f1 + MB * 4)) ]; then
	echo "  ok    the remove freed nothing: $f1 blocks free before, $f2 after"
else
	echo "  FAIL  the remove itself moved the free count from '$f1' to '$f2', so the scan is not what is measured"; fail=$((fail + 1))
fi
for pass in 1 2; do
	printf '%s\n' "$out" | grep -q "^pass $pass exit 0 " || { echo "  FAIL  bulkfree pass $pass did not exit 0"; fail=$((fail + 1)); }
done
[ -n "$staged" ] && [ -n "$freed" ] && echo "  ok    the kernel's statistics: pass 1 staged $staged, pass 2 freed $freed" || {
	echo "  FAIL  the kernel printed no pass statistics, so the scan is not known to have run"; fail=$((fail + 1)); }
if [ -n "$f3" ] && [ -n "$f0" ] && [ "$f3" -ge $((f0 - MB)) ]; then
	echo "  ok    two passes returned the set: $f3 blocks free against $f0 at mount"
else
	echo "  FAIL  two passes left $f3 blocks free against $f0 at mount"; fail=$((fail + 1))
fi
printf '%s\n' "$out" | grep -q "^second wrote $MB of $MB files" || { echo "  FAIL  the second set did not all write, so the freed space was not usable"; fail=$((fail + 1)); }
for want in "^umount exit 0$" "^rmmod exit 0$" "^debug_locks 1$" "^kmsg lines [1-9]" "^reports 0$"; do
	printf '%s\n' "$out" | grep -q "$want" || { echo "  FAIL  wanted $want"; fail=$((fail + 1)); }
done
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "  ok    host fsck_hammer2 after linux" || { echo "  FAIL  host fsck_hammer2 after linux"; fail=$((fail + 1)); }
fsck_control "$IMG" || fail=$((fail + 1))

# 2. DragonFly checks the volume and runs its own scan over it.
cat > "$W/dfly.sh" <<GUEST
mkdir -p /mnt/bf
mount_hammer2 /dev/vbd1@$ROOT /mnt/bf || { echo "mount failed"; exit 1; }
echo "dragonfly free at mount \$(df -k /mnt/bf | awk 'NR==2{print \$4}') KiB"
hammer2 -s /mnt/bf bulkfree /mnt/bf > /tmp/bf.out 2>&1; echo "dragonfly bulkfree exit \$?"
sed -n '1,8p' /tmp/bf.out | sed 's/^/dragonfly says: /'
echo "dragonfly free after \$(df -k /mnt/bf | awk 'NR==2{print \$4}') KiB"
umount /mnt/bf
fsck_hammer2 /dev/vbd1 >/dev/null 2>&1 && echo "dragonfly fsck clean"
GUEST
boot "$DFLY" "$DFLY_SSH" || { down "$DFLY" "$DFLY_SSH"; exit 2; }
scp -q -o ConnectTimeout=5 "$W/dfly.sh" "$DFLY_SSH:/tmp/" || { echo "bulkfree: COULD-NOT-RUN: scp failed" >&2; down "$DFLY" "$DFLY_SSH"; exit 2; }
out=$($RUN "$DFLY_SSH" 'sh /tmp/dfly.sh' 2>&1)
[ $? = 124 ] && { echo "  FAIL  the guest hung: the run exceeded ${H2_RUN_TIMEOUT:-1800}s"; fail=$((fail + 1)); }
printf '%s\n' "$out" | sed 's/^/  dfly    /'
down "$DFLY" "$DFLY_SSH"
printf '%s\n' "$out" | grep -q "^dragonfly bulkfree exit 0$" || { echo "  FAIL  DragonFly's bulkfree"; fail=$((fail + 1)); }
d0=$(printf '%s\n' "$out" | sed -n 's/^dragonfly free at mount \([0-9]*\) KiB/\1/p'); d1=$(printf '%s\n' "$out" | sed -n 's/^dragonfly free after \([0-9]*\) KiB/\1/p')
if [ -n "$d0" ] && [ -n "$d1" ] && [ $((d1 - d0)) -lt $((MB * 1024 / 4)) ]; then
	echo "  ok    DragonFly's pass found little to free after this side's two: $d0 KiB before, $d1 after"
else
	echo "  FAIL  DragonFly's pass freed what this side's two passes should have: $d0 KiB before, $d1 after"; fail=$((fail + 1))
fi
printf '%s\n' "$out" | grep -q "dragonfly fsck clean" || { echo "  FAIL  DragonFly's checker"; fail=$((fail + 1)); }
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "  ok    host fsck_hammer2 after dragonfly" || { echo "  FAIL  host fsck_hammer2 after dragonfly"; fail=$((fail + 1)); }
fsck_control "$IMG" || fail=$((fail + 1))

make -s clean >/dev/null 2>&1
echo "bulkfree: $MB MB written, removed, scanned twice and written again, $fail failure(s)"
[ $fail = 0 ]
