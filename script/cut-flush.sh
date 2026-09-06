#!/bin/sh
# A FLUSH CUT OFF, AND WHAT EACH RECOVERY MAKES OF IT.
# DragonFly writes small files continuously to a copy of a fixture, syncing
# every two hundred; after SECONDS the host destroys the domain, which is
# the power going out as far as the guest is concerned. The cut-off image
# is copied. This port mounts one copy read-write,
# so the carried hammer2_recovery() runs, reads every file, writes one more
# and syncs; DragonFly then mounts that result, and recovers the other copy
# itself. Both trees and every fsck_hammer2 verdict are printed.
#
# What the cut shows is that the header written last keeps everything it
# references; it does not, on its own, drive the freemap replay, which needs
# the header's freemap_tid to lag its mirror_tid, a window inside one sync
# that a cut from the host does not hit on purpose. So a fourth stage makes
# that state deliberately: DragonFly's recovered copy has its header's
# freemap_tid lowered by H2_CUT_LAG transactions and its two checksums over
# that sector recomputed, and both recoveries run on it. The replay then has
# chains to scan, and its message and both fsck verdicts are printed.
# EXIT 2 IS COULD-NOT-RUN AND IS NEVER A PASS, as in test-fixtures.sh.
set -u
cd "$(dirname "$0")/.." || exit 2

SECONDS_WRITING=${1:-25}
LAG=${H2_CUT_LAG:-4}
FIXDIR=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}
BASE=${H2_CUT_BASE:-$FIXDIR/f5.img}
LABEL=${H2_CUT_LABEL:-DFLY}
IMG=$FIXDIR/cut-flush.img
IMG2=$FIXDIR/cut-flush-dfly.img
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
DFLY=${H2_DFLY_GUEST:-dragonflybsd642}
DFLY_SSH=${H2_DFLY_SSH:-root@192.168.122.42}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
FSCK=${H2_FSCK:-$(command -v fsck_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2")}
SHOW=${H2_SHOW:-$(command -v hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/hammer2")}
W=$(mktemp -d) || exit 2

# THE NEGATIVE CONTROL FOR EVERY HOST fsck VERDICT: a sparse copy of the
# same image with one volume header byte complemented must fail the same
# fsck_hammer2, naming the header CRC. Without it a checker that accepts
# anything, a wrong binary on the path, or a copy that landed elsewhere
# all read as a pass. The byte is complemented rather than set, so the
# alteration cannot be a no-op for a value it already had; offset 256 is
# inside the first CRC section and clear of the magic and the CRC itself.
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
trap 'rm -rf "$W"' EXIT

command -v virsh >/dev/null 2>&1 || { echo "cut: COULD-NOT-RUN: no virsh" >&2; exit 2; }
[ -f "$BASE" ] || { echo "cut: COULD-NOT-RUN: no base image $BASE" >&2; exit 2; }
[ -x "$FSCK" ] && [ -x "$SHOW" ] || { echo "cut: COULD-NOT-RUN: no hammer2-utils (H2_FSCK, H2_SHOW)" >&2; exit 2; }
[ -d "$KDIR" ] || { echo "cut: COULD-NOT-RUN: no kernel tree at $KDIR" >&2; exit 2; }
for g in "$GUEST" "$DFLY"; do
	$VIRSH domstate "$g" >/dev/null 2>&1 || { echo "cut: COULD-NOT-RUN: no guest $g" >&2; exit 2; }
done
[ -z "$($VIRSH list --name | tr -d ' \n')" ] || {
	echo "cut: COULD-NOT-RUN: a guest is running: $($VIRSH list --name | tr '\n' ' ')" >&2; exit 2; }

make -s clean >/dev/null 2>&1
make -s KDIR="$KDIR" >/dev/null 2>&1 || {
	echo "cut: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko

rm -f "$IMG" "$IMG2"
cp "$BASE" "$IMG" || { echo "cut: COULD-NOT-RUN: cannot copy $BASE" >&2; exit 2; }

fail=0
tids() {	# print header tids of an image
	"$SHOW" show "$1" 2>/dev/null | grep -m1 'freemap_tid' | sed 's/.*mirror_tid=\([0-9a-f]*\) freemap_tid=\([0-9a-f]*\).*/mirror_tid \1 freemap_tid \2/'
}
boot() {
	$VIRSH attach-disk "$1" "$3" vdb --targetbus virtio --config >/dev/null 2>&1
	$VIRSH start "$1" >/dev/null 2>&1 || { echo "  FAIL  $1 did not start"; return 1; }
	n=0
	until ssh -o ConnectTimeout=3 -o BatchMode=yes "$2" true 2>/dev/null; do
		sleep 5; n=$((n + 1)); [ $n -gt 60 ] && { echo "  FAIL  $1 did not answer ssh"; return 1; }
	done
	return 0	# not the status of the loop's last test
}
down() {
	ssh -o ConnectTimeout=5 "$2" 'sync; poweroff' >/dev/null 2>&1
	n=0
	until [ "$($VIRSH domstate "$1")" = "shut off" ]; do
		sleep 3; n=$((n + 1)); [ $n -gt 60 ] && { $VIRSH destroy "$1" >/dev/null 2>&1; break; }
	done
	$VIRSH detach-disk "$1" vdb --config >/dev/null 2>&1
}

# 1. DragonFly writes until the power goes.
cat > "$W/write.sh" <<GUEST
mkdir -p /mnt/c; mount_hammer2 /dev/vbd1@$LABEL /mnt/c || exit 1
cd /mnt/c; mkdir -p crash; i=0
while :; do
  dd if=/dev/random of=crash/f\$i bs=4096 count=\$((1 + i % 20)) 2>/dev/null
  echo \$i > crash/last
  [ \$((i % 200)) -eq 199 ] && sync
  i=\$((i+1))
done
GUEST
boot "$DFLY" "$DFLY_SSH" "$IMG" || { down "$DFLY" "$DFLY_SSH"; exit 2; }
scp -q -o ConnectTimeout=5 "$W/write.sh" "$DFLY_SSH:/tmp/" || { echo "cut: COULD-NOT-RUN: scp failed" >&2; down "$DFLY" "$DFLY_SSH"; exit 2; }
ssh -o ConnectTimeout=5 "$DFLY_SSH" 'sh /tmp/write.sh' >/dev/null 2>&1 &
sleep "$SECONDS_WRITING"
$VIRSH destroy "$DFLY" >/dev/null 2>&1 && echo "  ok    $DFLY destroyed after ${SECONDS_WRITING}s of writing"
$VIRSH detach-disk "$DFLY" vdb --config >/dev/null 2>&1
cp "$IMG" "$IMG2"
echo "  cut   $(tids "$IMG")"
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "  ok    host fsck_hammer2 on the cut-off image" || { echo "  FAIL  host fsck_hammer2 on the cut-off image"; fail=$((fail + 1)); }
fsck_control "$IMG" || fail=$((fail + 1))

# 2. This port recovers one copy.
cat > "$W/recover.sh" <<GUEST
dev=\$(ls /dev/vd? | tail -1); mkdir -p /mnt/c
rmmod hammer2 2>/dev/null; insmod /tmp/hammer2.ko || exit 1; dmesg -C; echo 8 > /proc/sys/kernel/printk
mount -t hammer2 \$dev@$LABEL /mnt/c || { echo "rw mount failed"; exit 1; }
dmesg | grep -i 'recovery' | sed 's/^\[[^]]*\] //'
n=\$(ls /mnt/c/crash | wc -l); echo "crash entries \$n last \$(cat /mnt/c/crash/last)"
bad=0; for f in /mnt/c/crash/f*; do cat "\$f" > /dev/null 2>&1 || bad=\$((bad+1)); done; echo "unreadable \$bad"
echo "after the cut, by linux" > /mnt/c/crash/linux-after; sync; echo "write after recovery exit \$?"
umount /mnt/c
echo "debug_locks \$(awk '/debug_locks:/{print \$2}' /proc/lockdep_stats)"; dmesg | grep -c -i 'WARNING\|BUG\|hung task' | sed 's/^/reports /'
rmmod hammer2
GUEST
boot "$GUEST" "$GUEST_SSH" "$IMG" || { down "$GUEST" "$GUEST_SSH"; exit 2; }
scp -q -o ConnectTimeout=5 "$KO" "$W/recover.sh" "$GUEST_SSH:/tmp/" || { echo "cut: COULD-NOT-RUN: scp failed" >&2; down "$GUEST" "$GUEST_SSH"; exit 2; }
out=$(ssh "$GUEST_SSH" 'echo 20 > /proc/sys/kernel/hung_task_timeout_secs; sh /tmp/recover.sh' 2>&1)
printf '%s\n' "$out" | sed 's/^/  linux   /'
# "unreadable 0" over zero entries is what an empty or wrong directory
# prints, so the entry count is asserted with it.
printf '%s\n' "$out" | grep -q "^crash entries [1-9]" || fail=$((fail + 1))
printf '%s\n' "$out" | grep -q "^unreadable 0$" || fail=$((fail + 1))
printf '%s\n' "$out" | grep -q "write after recovery exit 0" || fail=$((fail + 1))
printf '%s\n' "$out" | grep -q "^debug_locks 1$" || fail=$((fail + 1))
printf '%s\n' "$out" | grep -q "^reports 0$" || fail=$((fail + 1))
down "$GUEST" "$GUEST_SSH"
echo "  linux $(tids "$IMG")"
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "  ok    host fsck_hammer2 after linux" || { echo "  FAIL  host fsck_hammer2 after linux"; fail=$((fail + 1)); }

# 3. DragonFly reads that, then recovers its own copy.
cat > "$W/after.sh" <<GUEST
mkdir -p /mnt/c; mount_hammer2 /dev/vbd1@$LABEL /mnt/c || { echo "mount failed"; exit 1; }
echo "crash entries \$(ls /mnt/c/crash | wc -l | tr -d ' ') last \$(cat /mnt/c/crash/last) linux-after: \$(cat /mnt/c/crash/linux-after 2>/dev/null || echo absent)"
umount /mnt/c; fsck_hammer2 /dev/vbd1 >/dev/null 2>&1 && echo "dragonfly fsck clean"
GUEST
for img in "$IMG" "$IMG2"; do
	boot "$DFLY" "$DFLY_SSH" "$img" || { down "$DFLY" "$DFLY_SSH"; exit 2; }
	scp -q -o ConnectTimeout=5 "$W/after.sh" "$DFLY_SSH:/tmp/" || { echo "cut: COULD-NOT-RUN: scp failed" >&2; down "$DFLY" "$DFLY_SSH"; exit 2; }
	out=$(ssh "$DFLY_SSH" 'sh /tmp/after.sh' 2>&1)
	printf '%s\n' "$out" | sed "s|^|  dfly $(basename "$img" .img) |"
	printf '%s\n' "$out" | grep -q "dragonfly fsck clean" || fail=$((fail + 1))
	down "$DFLY" "$DFLY_SSH"
done
echo "  dfly  $(tids "$IMG2")"

# 4. The lagging header, made on purpose, and both recoveries on it.
python3 - "$IMG2" "$LAG" <<'PY' || { echo "  FAIL  could not rewrite the header"; fail=$((fail + 1)); }
import struct, sys
p, lag = sys.argv[1], int(sys.argv[2])
tbl = []
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ 0x82F63B78 if c & 1 else c >> 1
    tbl.append(c)
def crc32c(data):
    c = 0xFFFFFFFF
    for b in data:
        c = tbl[(c ^ b) & 0xFF] ^ (c >> 8)
    return c ^ 0xFFFFFFFF
with open(p, 'r+b') as f:
    hdr = bytearray(f.read(65536))
    mirror, = struct.unpack_from('<Q', hdr, 0x78)
    freemap, = struct.unpack_from('<Q', hdr, 0x90)
    if struct.unpack_from('<I', hdr, 0x1FC)[0] != crc32c(hdr[0:508]):
        sys.exit("sector 0 crc does not verify before the change; wrong layout")
    struct.pack_into('<Q', hdr, 0x90, max(0, mirror - lag))
    struct.pack_into('<I', hdr, 0x1FC, crc32c(hdr[0:508]))
    struct.pack_into('<I', hdr, 0xFFFC, crc32c(hdr[0:65532]))
    f.seek(0); f.write(hdr)
print(f"  lag   header freemap_tid {freemap:#x} -> {max(0, mirror - lag):#x}, mirror_tid {mirror:#x}")
PY
"$FSCK" "$IMG2" >/dev/null 2>&1 && echo "  ok    host fsck_hammer2 accepts the rewritten header" || { echo "  FAIL  host fsck_hammer2 rejects the rewritten header"; fail=$((fail + 1)); }
boot "$GUEST" "$GUEST_SSH" "$IMG2" || { down "$GUEST" "$GUEST_SSH"; exit 2; }
scp -q -o ConnectTimeout=5 "$KO" "$W/recover.sh" "$GUEST_SSH:/tmp/" || { echo "cut: COULD-NOT-RUN: scp failed" >&2; down "$GUEST" "$GUEST_SSH"; exit 2; }
out=$(ssh "$GUEST_SSH" 'echo 20 > /proc/sys/kernel/hung_task_timeout_secs; sh /tmp/recover.sh' 2>&1)
printf '%s\n' "$out" | sed 's/^/  linux   /'
printf '%s\n' "$out" | grep -q "freemap recovery" || { echo "  FAIL  the replay did not announce itself"; fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q "^unreadable 0$" || fail=$((fail + 1))
printf '%s\n' "$out" | grep -q "^debug_locks 1$" || fail=$((fail + 1))
printf '%s\n' "$out" | grep -q "^reports 0$" || fail=$((fail + 1))
down "$GUEST" "$GUEST_SSH"
echo "  linux $(tids "$IMG2")"
"$FSCK" "$IMG2" >/dev/null 2>&1 && echo "  ok    host fsck_hammer2 after the replay" || { echo "  FAIL  host fsck_hammer2 after the replay"; fail=$((fail + 1)); }
boot "$DFLY" "$DFLY_SSH" "$IMG2" || { down "$DFLY" "$DFLY_SSH"; exit 2; }
scp -q -o ConnectTimeout=5 "$W/after.sh" "$DFLY_SSH:/tmp/" || { echo "cut: COULD-NOT-RUN: scp failed" >&2; down "$DFLY" "$DFLY_SSH"; exit 2; }
out=$(ssh "$DFLY_SSH" 'sh /tmp/after.sh' 2>&1)
printf '%s\n' "$out" | sed 's/^/  dfly lag /'
printf '%s\n' "$out" | grep -q "dragonfly fsck clean" || fail=$((fail + 1))
down "$DFLY" "$DFLY_SSH"

make -s clean >/dev/null 2>&1
echo "cut: ${SECONDS_WRITING}s of writing, lag $LAG, $fail failure(s)"
[ $fail = 0 ]
