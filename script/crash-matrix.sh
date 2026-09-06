#!/bin/sh
# THE CRASH MATRIX, CALIBRATED AGAINST THE FREEBSD PORT.
# Four ways a write workload stops, two writers, and three verdicts on
# what each leaves behind. A writer mounts a copy of a host-made volume
# read-write and writes small files with a sync every two hundred; after
# SECONDS the cell happens: the writing process is killed and the volume
# unmounted (kill), the guest kernel panics (panic), the host destroys the
# domain (power), or it destroys the domain and then zeroes the second
# half of the newest volume header, which is a header write that reached
# the media only in part (torn). The image is then copied and judged:
# the host's fsck_hammer2 on the cut-off image, which must be clean, or
# in the torn cell must report the torn zone and nothing else, since it
# chooses its zone by mirror_tid before checking the CRC as DragonFly's
# fsck does; then this port mounting one copy read-write, reading every
# file, writing one more and syncing, and the FreeBSD port doing the
# same to the other copy and running its own fsck_hammer2. The host
# checks both results.
#
# The FreeBSD port writes first, every cell, so its recovery of its own
# crash is on record before this port is judged against it; then this
# port writes the same cells and the FreeBSD port reads what it left.
# Every cell runs REPS times. One row per run is printed, and the
# summary counts cells whose runs all agree; a cell that does not repeat
# is named, never averaged. A row fails when any verdict does.
# EXIT 2 IS COULD-NOT-RUN AND IS NEVER A PASS, as in test-fixtures.sh.
set -u
cd "$(dirname "$0")/.." || exit 2

SECONDS_WRITING=${1:-20}
REPS=${H2_CRASH_REPS:-2}
CELLS=${H2_CRASH_CELLS:-"kill panic power torn"}
WRITERS=${H2_CRASH_WRITERS:-"fbsd linux"}
FIXDIR=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}
LABEL=${H2_CRASH_LABEL:-CRASH}
BASE=$FIXDIR/crash-base.img
IMG=$FIXDIR/crash.img
IMGL=$FIXDIR/crash-linux.img
IMGF=$FIXDIR/crash-fbsd.img
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
FBSD=${H2_FBSD_GUEST:-freebsd15}
FBSD_SSH=${H2_FBSD_SSH:-freebsd}	# an ssh alias; a wheel user with passwordless doas
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2")}
FSCK=${H2_FSCK:-$(command -v fsck_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2")}
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

command -v virsh >/dev/null 2>&1 || { echo "crash: COULD-NOT-RUN: no virsh" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "crash: COULD-NOT-RUN: no python3" >&2; exit 2; }
[ -x "$NEWFS" ] && [ -x "$FSCK" ] || { echo "crash: COULD-NOT-RUN: no hammer2-utils (H2_NEWFS, H2_FSCK)" >&2; exit 2; }
[ -d "$KDIR" ] || { echo "crash: COULD-NOT-RUN: no kernel tree at $KDIR" >&2; exit 2; }
for g in "$GUEST" "$FBSD"; do
	$VIRSH domstate "$g" >/dev/null 2>&1 || { echo "crash: COULD-NOT-RUN: no guest $g" >&2; exit 2; }
done
[ -z "$($VIRSH list --name | tr -d ' \n')" ] || {
	echo "crash: COULD-NOT-RUN: a guest is running: $($VIRSH list --name | tr '\n' ' ')" >&2; exit 2; }

make -s clean >/dev/null 2>&1
make -s KDIR="$KDIR" >/dev/null 2>&1 || {
	echo "crash: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko

# 8 GiB so all four volume header zones exist, which the torn cell needs.
rm -f "$BASE" "$IMG" "$IMGL" "$IMGF"
truncate -s 8G "$BASE" && "$NEWFS" -L "$LABEL" "$BASE" >/dev/null 2>&1 || {
	echo "crash: COULD-NOT-RUN: newfs_hammer2 failed on $BASE" >&2; exit 2; }

boot() {	# domain ssh image
	$VIRSH attach-disk "$1" "$3" vdb --targetbus virtio --config >/dev/null 2>&1
	$VIRSH start "$1" >/dev/null 2>&1 || { echo "  FAIL  $1 did not start"; return 1; }
	n=0
	until ssh -o ConnectTimeout=3 -o BatchMode=yes "$2" true 2>/dev/null; do
		sleep 5; n=$((n + 1)); [ $n -gt 60 ] && { echo "  FAIL  $1 did not answer ssh"; return 1; }
	done
	return 0	# not the status of the loop's last test
}
down() {	# domain ssh
	ssh -o ConnectTimeout=5 "$2" 'sync; poweroff' >/dev/null 2>&1
	n=0
	until [ "$($VIRSH domstate "$1")" = "shut off" ]; do
		sleep 3; n=$((n + 1)); [ $n -gt 60 ] && { $VIRSH destroy "$1" >/dev/null 2>&1; break; }
	done
	$VIRSH detach-disk "$1" vdb --config >/dev/null 2>&1
}
chop() {	# domain: the power goes
	$VIRSH destroy "$1" >/dev/null 2>&1
	$VIRSH detach-disk "$1" vdb --config >/dev/null 2>&1
}
headers() {	# image: every valid header zone and its mirror_tid, best first
	python3 - "$1" <<'PY'
import struct, sys
tbl = []
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ 0x82F63B78 if c & 1 else c >> 1
    tbl.append(c)
def crc32c(d):
    c = 0xFFFFFFFF
    for b in d:
        c = tbl[(c ^ b) & 0xFF] ^ (c >> 8)
    return c ^ 0xFFFFFFFF
out = []
with open(sys.argv[1], 'rb') as f:
    for z in range(4):
        f.seek(z << 31); h = f.read(65536)
        if len(h) < 65536: break
        ok = struct.unpack_from('<I', h, 0x1FC)[0] == crc32c(h[0:508]) and \
             struct.unpack_from('<I', h, 0xFFFC)[0] == crc32c(h[0:65532])
        if ok: out.append((struct.unpack_from('<Q', h, 0x78)[0], z))
for tid, z in sorted(out, reverse=True):
    print(f"zone{z}:{tid:#x}", end=' ')
print()
PY
}
tear() {	# image: zero the second half of the newest valid header
	python3 - "$1" <<'PY'
import struct, sys
tbl = []
for i in range(256):
    c = i
    for _ in range(8):
        c = (c >> 1) ^ 0x82F63B78 if c & 1 else c >> 1
    tbl.append(c)
def crc32c(d):
    c = 0xFFFFFFFF
    for b in d:
        c = tbl[(c ^ b) & 0xFF] ^ (c >> 8)
    return c ^ 0xFFFFFFFF
best = None
with open(sys.argv[1], 'r+b') as f:
    for z in range(4):
        f.seek(z << 31); h = f.read(65536)
        if struct.unpack_from('<I', h, 0xFFFC)[0] != crc32c(h[0:65532]): continue
        tid = struct.unpack_from('<Q', h, 0x78)[0]
        if best is None or tid > best[0]: best = (tid, z)
    if best is None: sys.exit("no valid header to tear")
    f.seek((best[1] << 31) + 32768); f.write(bytes(32768))
print(f"zone{best[1]}:{best[0]:#x}")
PY
}

# Guest-side scripts. Each reports on stdout what the host greps for.
cat > "$W/write-linux.sh" <<GUEST
dev=\$(ls /dev/vd? | tail -1); mkdir -p /mnt/c
rmmod hammer2 2>/dev/null; insmod /tmp/hammer2.ko || exit 1; echo 8 > /proc/sys/kernel/printk
mount -t hammer2 \$dev@$LABEL /mnt/c || exit 1
cd /mnt/c; mkdir -p crash; i=0
while :; do
  dd if=/dev/urandom of=crash/f\$i bs=4096 count=\$((1 + i % 20)) 2>/dev/null
  echo \$i > crash/last
  [ \$((i % 200)) -eq 199 ] && sync
  i=\$((i+1))
done
GUEST
cat > "$W/write-fbsd.sh" <<GUEST
kldstat -q -m hammer2 || kldload hammer2 || exit 1
mkdir -p /mnt/c; mount_hammer2 /dev/vtbd1@$LABEL /mnt/c || exit 1
cd /mnt/c; mkdir -p crash; i=0
while :; do
  dd if=/dev/random of=crash/f\$i bs=4096 count=\$((1 + i % 20)) 2>/dev/null
  echo \$i > crash/last
  [ \$((i % 200)) -eq 199 ] && sync
  i=\$((i+1))
done
GUEST
cat > "$W/recover-linux.sh" <<GUEST
dev=\$(ls /dev/vd? | tail -1); mkdir -p /mnt/c
rmmod hammer2 2>/dev/null; insmod /tmp/hammer2.ko || exit 1; dmesg -C; echo 8 > /proc/sys/kernel/printk
echo 20 > /proc/sys/kernel/hung_task_timeout_secs
mount -t hammer2 \$dev@$LABEL /mnt/c || { echo "mount failed"; exit 1; }
dmesg | grep -i 'recovery' | sed 's/^\[[^]]*\] //'
echo "entries \$(ls /mnt/c/crash 2>/dev/null | wc -l) last \$(cat /mnt/c/crash/last 2>/dev/null || echo none)"
bad=0; for f in /mnt/c/crash/f*; do cat "\$f" > /dev/null 2>&1 || bad=\$((bad+1)); done; echo "unreadable \$bad"
echo "after the cut, by linux" > /mnt/c/crash/linux-after; sync; echo "write after recovery exit \$?"
umount /mnt/c; echo "umount exit \$?"
echo "debug_locks \$(awk '/debug_locks:/{print \$2}' /proc/lockdep_stats)"; dmesg | grep -c -i 'WARNING\|BUG\|hung task' | sed 's/^/reports /'
rmmod hammer2
GUEST
cat > "$W/recover-fbsd.sh" <<GUEST
kldstat -q -m hammer2 || kldload hammer2 || exit 1
mkdir -p /mnt/c; mount_hammer2 /dev/vtbd1@$LABEL /mnt/c || { echo "mount failed"; exit 1; }
echo "entries \$(ls /mnt/c/crash 2>/dev/null | wc -l | tr -d ' ') last \$(cat /mnt/c/crash/last 2>/dev/null || echo none)"
bad=0; for f in /mnt/c/crash/f*; do cat "\$f" > /dev/null 2>&1 || bad=\$((bad+1)); done; echo "unreadable \$bad"
echo "after the cut, by freebsd" > /mnt/c/crash/fbsd-after; sync; echo "write after recovery exit \$?"
umount /mnt/c; echo "umount exit \$?"
fsck_hammer2 /dev/vtbd1 > /dev/null 2>&1 && echo "freebsd fsck clean" || echo "freebsd fsck FAILED"
GUEST

fail=0; torn_zone=
run_writer() {	# writer cell -> the cut-off image in $IMG; prints the cut line
	cp --sparse=always "$BASE" "$IMG" || return 2
	case $1 in
	linux)	dom=$GUEST; sshto=$GUEST_SSH; files="$KO $W/write-linux.sh"; cmd='sh /tmp/write-linux.sh'
		panic='echo 1 > /proc/sys/kernel/sysrq; echo c > /proc/sysrq-trigger'
		stop='pkill -9 -f "[w]rite-linux.sh"; pkill -9 -x dd; sleep 1; umount /mnt/c; echo umount $?; rmmod hammer2' ;;
	fbsd)	dom=$FBSD; sshto=$FBSD_SSH; files="$W/write-fbsd.sh"; cmd='doas sh /tmp/write-fbsd.sh'
		panic='doas sysctl debug.kdb.panic=1'
		stop='doas pkill -9 -f "[w]rite-fbsd.sh"; doas pkill -9 -x dd; sleep 1; doas umount /mnt/c; echo umount $?' ;;
	esac
	boot "$dom" "$sshto" "$IMG" || { chop "$dom"; return 2; }
	# shellcheck disable=SC2086
	scp -q -o ConnectTimeout=5 $files "$sshto:/tmp/" || { echo "crash: COULD-NOT-RUN: scp failed" >&2; down "$dom" "$sshto"; return 2; }
	ssh -o ConnectTimeout=5 "$sshto" "$cmd" >/dev/null 2>&1 &
	wpid=$!
	sleep "$SECONDS_WRITING"
	case $2 in
	kill)	o=$(ssh -o ConnectTimeout=5 "$sshto" "$stop" 2>&1); printf '%s\n' "$o" | grep -q '^umount 0$' || echo "  note  unmount after the kill: $o"
		down "$dom" "$sshto" ;;
	panic)	timeout 15 ssh -o ConnectTimeout=5 "$sshto" "$panic" >/dev/null 2>&1; sleep 5; chop "$dom" ;;
	power)	chop "$dom" ;;
	torn)	chop "$dom"; torn_zone=$(tear "$IMG"); echo "  torn  $torn_zone" ;;
	esac
	kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null	# an ssh to a destroyed guest never returns by itself
	return 0
}
verdict_linux() {	# image -> prints lines, returns failures
	f=0
	boot "$GUEST" "$GUEST_SSH" "$1" || { down "$GUEST" "$GUEST_SSH"; return 9; }
	scp -q -o ConnectTimeout=5 "$KO" "$W/recover-linux.sh" "$GUEST_SSH:/tmp/" || { down "$GUEST" "$GUEST_SSH"; return 9; }
	out=$(ssh "$GUEST_SSH" 'sh /tmp/recover-linux.sh' 2>&1)
	printf '%s\n' "$out" | sed 's/^/  linux   /'
	for want in "^entries [1-9]" "^unreadable 0$" "write after recovery exit 0" "^umount exit 0$" "^debug_locks 1$" "^reports 0$"; do
		printf '%s\n' "$out" | grep -q "$want" || f=$((f + 1))
	done
	down "$GUEST" "$GUEST_SSH"
	"$FSCK" "$1" >/dev/null 2>&1 && echo "  ok    host fsck_hammer2 after linux" || { echo "  FAIL  host fsck_hammer2 after linux"; f=$((f + 1)); }
	return $f
}
verdict_fbsd() {
	f=0
	boot "$FBSD" "$FBSD_SSH" "$1" || { down "$FBSD" "$FBSD_SSH"; return 9; }
	scp -q -o ConnectTimeout=5 "$W/recover-fbsd.sh" "$FBSD_SSH:/tmp/" || { down "$FBSD" "$FBSD_SSH"; return 9; }
	out=$(ssh "$FBSD_SSH" 'doas sh /tmp/recover-fbsd.sh' 2>&1)
	printf '%s\n' "$out" | sed 's/^/  fbsd    /'
	for want in "^entries [1-9]" "^unreadable 0$" "write after recovery exit 0" "^umount exit 0$" "^freebsd fsck clean$"; do
		printf '%s\n' "$out" | grep -q "$want" || f=$((f + 1))
	done
	down "$FBSD" "$FBSD_SSH"
	"$FSCK" "$1" >/dev/null 2>&1 && echo "  ok    host fsck_hammer2 after freebsd" || { echo "  FAIL  host fsck_hammer2 after freebsd"; f=$((f + 1)); }
	return $f
}

rows=$W/rows
: > "$rows"
for writer in $WRITERS; do
	for cell in $CELLS; do
		r=1
		while [ $r -le "$REPS" ]; do
			echo "== $writer $cell run $r"
			run_writer "$writer" "$cell"; s=$?
			[ $s = 0 ] || { echo "crash: COULD-NOT-RUN: the $writer writer did not run" >&2; exit 2; }
			echo "  cut   headers $(headers "$IMG")"
			if [ "$cell" = torn ]; then
				# fsck_hammer2 picks its zone by mirror_tid before it checks the
				# CRC, as DragonFly's does, so the torn header is reported as
				# damage where a mount skips it. The expected verdict on the
				# cut-off image is that report, on that zone, and nothing else.
				z=${torn_zone#zone}; z=${z%%:*}
				o=$("$FSCK" "$IMG" 2>&1); s=$?
				hf=FAIL
				[ $s != 0 ] && printf '%s\n' "$o" | grep -q "#$z: volume header crc mismatch vh" \
					&& printf '%s\n' "$o" | grep -q "Bad volume header CRC" && hf=torn-reported
				echo "  $hf    host fsck_hammer2 on the cut-off image, zone $z torn"
			else
				hf=ok; "$FSCK" "$IMG" >/dev/null 2>&1 || hf=FAIL
				echo "  $hf    host fsck_hammer2 on the cut-off image"
				# The torn cell is this control's live form: a header
				# fsck must refuse, and does. The other cells get it here.
				fsck_control "$IMG" || hf=FAIL
			fi
			cp --sparse=always "$IMG" "$IMGL"; cp --sparse=always "$IMG" "$IMGF"
			verdict_linux "$IMGL"; lf=$?
			verdict_fbsd "$IMGF"; ff=$?
			[ $lf = 9 ] || [ $ff = 9 ] && { echo "crash: COULD-NOT-RUN: a judging guest did not boot" >&2; exit 2; }
			row="$writer $cell $r host=$hf linux=$lf fbsd=$ff"
			echo "  row   $row"; echo "$row" >> "$rows"
			{ [ "$hf" = ok ] || [ "$hf" = torn-reported ]; } && [ $lf = 0 ] && [ $ff = 0 ] || fail=$((fail + 1))
			r=$((r + 1))
		done
	done
done

make -s clean >/dev/null 2>&1
echo "crash: ${SECONDS_WRITING}s of writing, $REPS run(s) per cell"
for writer in $WRITERS; do
	for cell in $CELLS; do
		n=$(grep -c "^$writer $cell " "$rows")
		v=$(grep "^$writer $cell " "$rows" | cut -d' ' -f4- | sort -u | wc -l)
		if [ "$v" = 1 ]; then echo "  $writer $cell: $n run(s) agree: $(grep -m1 "^$writer $cell " "$rows" | cut -d' ' -f4-)"
		else echo "  $writer $cell: $n run(s) DISAGREE, not green"; fail=$((fail + 1)); fi
	done
done
echo "crash: $fail failure(s)"
[ $fail = 0 ]
