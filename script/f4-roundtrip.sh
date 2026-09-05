#!/bin/sh
# F4, BOTH DIRECTIONS, ON A VOLUME FORMATTED HERE.
# A tree written by this port, mounted and verified on DragonFly, then the
# reverse. The image is formatted on the host by hammer2-utils' newfs_hammer2
# so nothing on it is DragonFly's until DragonFly's turn: Linux writes a tree
# and its manifest, DragonFly checks the manifest, writes a tree of its own
# with a manifest, moves one of Linux's files and removes another, and Linux
# checks DragonFly's manifest and what is left of its own. Every checksum on
# both sides comes from the writer, so neither reader is compared against
# itself.
#
# This needs the experimental build: the shipped module refuses a read-write
# mount. It boots each guest in turn, one at a time, and shuts each down.
# EXIT 2 IS COULD-NOT-RUN AND IS NEVER A PASS, as in test-fixtures.sh.
set -u
cd "$(dirname "$0")/.." || exit 2

FIXDIR=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}
IMG=${H2_F4_IMAGE:-$FIXDIR/f4-roundtrip.img}
LABEL=${H2_F4_LABEL:-LINUX}
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
DFLY=${H2_DFLY_GUEST:-dragonflybsd642}
DFLY_SSH=${H2_DFLY_SSH:-root@192.168.122.42}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2")}
FSCK=${H2_FSCK:-$(command -v fsck_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2")}
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

command -v virsh >/dev/null 2>&1 || { echo "f4: COULD-NOT-RUN: no virsh" >&2; exit 2; }
[ -x "$NEWFS" ] || { echo "f4: COULD-NOT-RUN: no newfs_hammer2 (H2_NEWFS)" >&2; exit 2; }
[ -x "$FSCK" ] || { echo "f4: COULD-NOT-RUN: no fsck_hammer2 (H2_FSCK)" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "f4: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -d "$KDIR" ] || { echo "f4: COULD-NOT-RUN: no kernel tree at $KDIR" >&2; exit 2; }
for g in "$GUEST" "$DFLY"; do
	$VIRSH domstate "$g" >/dev/null 2>&1 || { echo "f4: COULD-NOT-RUN: no guest $g" >&2; exit 2; }
done
[ -z "$($VIRSH list --name | tr -d ' \n')" ] || {
	echo "f4: COULD-NOT-RUN: a guest is running: $($VIRSH list --name | tr '\n' ' ')" >&2; exit 2; }

make -s clean >/dev/null 2>&1
make -s KDIR="$KDIR" HAMMER2_RW_EXPERIMENT=1 >/dev/null 2>&1 || {
	echo "f4: COULD-NOT-RUN: experimental module did not build against $KDIR" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko

rm -f "$IMG"
truncate -s 2G "$IMG" && "$NEWFS" -L "$LABEL" "$IMG" >/dev/null 2>&1 || {
	echo "f4: COULD-NOT-RUN: newfs_hammer2 failed on $IMG" >&2; exit 2; }

fail=0
boot() {	# boot <guest> <ssh>; the image is attached first
	$VIRSH attach-disk "$1" "$IMG" vdb --targetbus virtio --config >/dev/null 2>&1
	$VIRSH start "$1" >/dev/null 2>&1 || { echo "  FAIL  $1 did not start"; return 1; }
	n=0
	until ssh -o ConnectTimeout=3 -o BatchMode=yes "$2" true 2>/dev/null; do
		sleep 5; n=$((n + 1)); [ $n -gt 60 ] && { echo "  FAIL  $1 did not answer ssh"; return 1; }
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

# 1. Linux writes.
cat > "$W/linux-write.sh" <<GUEST
dev=\$(ls /dev/vd? | tail -1); mkdir -p /mnt/f4
rmmod hammer2 2>/dev/null; insmod /tmp/hammer2.ko || exit 1; dmesg -C
mount -t hammer2 \$dev@$LABEL /mnt/f4 || { echo "mount failed"; exit 1; }
cd /mnt/f4
mkdir -p tree/sub; echo "made on linux" > tree/hello
head -c 200000 /dev/urandom > tree/rand200k; head -c 1000000 /dev/zero > tree/zeros1m
printf 'x%.0s' \$(seq 1 3000) > tree/sub/compressible; ln -s ../hello tree/sub/link; ln tree/hello tree/hard
i=0; while [ \$i -lt 300 ]; do echo \$i > tree/sub/f\$i; i=\$((i+1)); done
find tree -type f | sort | xargs md5sum > /tmp/linux.md5; cp /tmp/linux.md5 tree/linux.md5
echo "written \$(find tree -type f | wc -l) files"
cd /; sync; umount /mnt/f4 || exit 1
mount -t hammer2 -o ro \$dev@$LABEL /mnt/f4 || exit 1
cd /mnt/f4 && md5sum -c --quiet tree/linux.md5 && echo "linux re-read: all match"; cd /; umount /mnt/f4
echo "debug_locks \$(awk '/debug_locks:/{print \$2}' /proc/lockdep_stats)"; dmesg | grep -c -i 'WARNING\|BUG\|hung task' | sed 's/^/reports /'
rmmod hammer2
GUEST
boot "$GUEST" "$GUEST_SSH" || { down "$GUEST" "$GUEST_SSH"; exit 2; }
scp -q -o ConnectTimeout=5 "$KO" "$W/linux-write.sh" "$GUEST_SSH:/tmp/" || { echo "f4: COULD-NOT-RUN: scp failed" >&2; down "$GUEST" "$GUEST_SSH"; exit 2; }
out=$(ssh "$GUEST_SSH" 'sh /tmp/linux-write.sh' 2>&1)
printf '%s\n' "$out" | sed 's/^/  linux   /'
printf '%s\n' "$out" | grep -q "linux re-read: all match" || fail=$((fail + 1))
printf '%s\n' "$out" | grep -q "^debug_locks 1$" || fail=$((fail + 1))
printf '%s\n' "$out" | grep -q "^reports 0$" || fail=$((fail + 1))
down "$GUEST" "$GUEST_SSH"
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "  ok    host fsck_hammer2 after linux" || { echo "  FAIL  host fsck_hammer2 after linux"; fail=$((fail + 1)); }

# 2. DragonFly checks and writes.
cat > "$W/dfly.sh" <<GUEST
mkdir -p /mnt/f4; mount_hammer2 /dev/vbd1@$LABEL /mnt/f4 || { echo "mount failed"; exit 1; }
cd /mnt/f4
bad=0; n=0; while read sum path; do n=\$((n+1)); [ "\$(md5 -q "\$path")" = "\$sum" ] || bad=\$((bad+1)); done < tree/linux.md5
echo "dragonfly checked \$n files, \$bad mismatches"
[ "\$(cat tree/sub/link)" = "made on linux" ] && echo "symlink followed"
mkdir -p back/deep; echo "made on dragonfly" > back/hello; dd if=/dev/random of=back/rand300k bs=1000 count=300 2>/dev/null
i=0; while [ \$i -lt 200 ]; do echo \$i > back/deep/g\$i; i=\$((i+1)); done
mv tree/sub/f0 back/moved; rm tree/sub/f1
find back -type f | sort | xargs md5 -r | sed 's/ /  /' > back/dfly.md5; echo "dragonfly wrote \$(find back -type f | wc -l | tr -d ' ') files"
cd /; umount /mnt/f4; fsck_hammer2 /dev/vbd1 >/dev/null 2>&1 && echo "dragonfly fsck clean"
GUEST
boot "$DFLY" "$DFLY_SSH" || { down "$DFLY" "$DFLY_SSH"; exit 2; }
scp -q -o ConnectTimeout=5 "$W/dfly.sh" "$DFLY_SSH:/tmp/" || { echo "f4: COULD-NOT-RUN: scp failed" >&2; down "$DFLY" "$DFLY_SSH"; exit 2; }
out=$(ssh "$DFLY_SSH" 'sh /tmp/dfly.sh' 2>&1)
printf '%s\n' "$out" | sed 's/^/  dfly    /'
printf '%s\n' "$out" | grep -q "files, 0 mismatches" || fail=$((fail + 1))
printf '%s\n' "$out" | grep -q "symlink followed" || fail=$((fail + 1))
printf '%s\n' "$out" | grep -q "dragonfly fsck clean" || fail=$((fail + 1))
down "$DFLY" "$DFLY_SSH"

# 3. Linux reads DragonFly's.
cat > "$W/linux-read.sh" <<GUEST
dev=\$(ls /dev/vd? | tail -1); mkdir -p /mnt/f4
rmmod hammer2 2>/dev/null; insmod /tmp/hammer2.ko || exit 1; dmesg -C
mount -t hammer2 -o ro \$dev@$LABEL /mnt/f4 || exit 1
cd /mnt/f4
md5sum -c --quiet back/dfly.md5 && echo "linux read dragonfly's \$(wc -l < back/dfly.md5) files: all match"
sed '/sub\/f0\$/d;/sub\/f1\$/d' tree/linux.md5 | md5sum -c --quiet && echo "linux's own tree still matches"
[ -e tree/sub/f1 ] || echo "removed file is gone"
cd /; umount /mnt/f4
echo "debug_locks \$(awk '/debug_locks:/{print \$2}' /proc/lockdep_stats)"; dmesg | grep -c -i 'WARNING\|BUG\|hung task' | sed 's/^/reports /'
rmmod hammer2
GUEST
boot "$GUEST" "$GUEST_SSH" || { down "$GUEST" "$GUEST_SSH"; exit 2; }
scp -q -o ConnectTimeout=5 "$KO" "$W/linux-read.sh" "$GUEST_SSH:/tmp/" || { echo "f4: COULD-NOT-RUN: scp failed" >&2; down "$GUEST" "$GUEST_SSH"; exit 2; }
out=$(ssh "$GUEST_SSH" 'sh /tmp/linux-read.sh' 2>&1)
printf '%s\n' "$out" | sed 's/^/  linux   /'
printf '%s\n' "$out" | grep -q "files: all match" || fail=$((fail + 1))
printf '%s\n' "$out" | grep -q "own tree still matches" || fail=$((fail + 1))
printf '%s\n' "$out" | grep -q "^debug_locks 1$" || fail=$((fail + 1))
printf '%s\n' "$out" | grep -q "^reports 0$" || fail=$((fail + 1))
down "$GUEST" "$GUEST_SSH"

make -s clean >/dev/null 2>&1
echo "f4: both directions on $IMG, $fail failure(s)"
[ $fail = 0 ]
