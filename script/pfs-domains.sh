#!/bin/sh
# PFS ROOTS CREATED HERE, MOUNTED BY LABEL HERE, READ BACK BY DRAGONFLY.
# 0.8 maps the storage model's domains onto PFS roots and gates them by
# the read-only gate mounting each PFS by label. The model and its
# installer belong to the consumer; what belongs here is the half a
# volume written on Linux has to satisfy: PFSes this port creates through
# its own ioctl, each mounting by label as a filesystem of its own, each
# holding a tree DragonFly checks against this side's manifest, and the
# volume passing both checkers afterwards. f7 covered PFSes DragonFly
# made; this covers PFSes this port made.
#
# Exit 2 without the two guests, the tools or a kernel tree. One guest at
# a time: the Linux guest writes and is shut down, then DragonFly reads.
set -u
FIXDIR=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}
IMG=${H2_PFS_IMAGE:-$FIXDIR/pfs-domains.img}
ROOT=${H2_PFS_ROOT:-ROOT}
DOMAINS=${H2_PFS_DOMAINS:-"SYSTEM STORE CACHE"}
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
DFLY=${H2_DFLY_GUEST:-dragonflybsd642}
DFLY_SSH=${H2_DFLY_SSH:-root@192.168.122.42}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2")}
FSCK=${H2_FSCK:-$(command -v fsck_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2")}
W=$(mktemp -d) || exit 2
# THE LONG RUNS ARE BOUNDED FROM THIS SIDE. A guest whose task hangs, on a
# hung mount or a wedged unmount, keeps sshd answering and the ssh open,
# and the script would wait on it forever; the fuzzer bounds each image
# the same way. 124 from timeout is reported as the guest hanging, which
# is a finding, not a pass and not a skip.
RUN="timeout ${H2_RUN_TIMEOUT:-1800} ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
trap 'rm -rf "$W"' EXIT

# THE NEGATIVE CONTROL FOR EVERY HOST fsck VERDICT, as the other fleet
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

command -v virsh >/dev/null 2>&1 || { echo "pfs: COULD-NOT-RUN: no virsh" >&2; exit 2; }
[ -x "$NEWFS" ] || { echo "pfs: COULD-NOT-RUN: no newfs_hammer2 (H2_NEWFS)" >&2; exit 2; }
[ -x "$FSCK" ] || { echo "pfs: COULD-NOT-RUN: no fsck_hammer2 (H2_FSCK)" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "pfs: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -d "$KDIR" ] || { echo "pfs: COULD-NOT-RUN: no kernel tree at $KDIR" >&2; exit 2; }
for g in "$GUEST" "$DFLY"; do
	$VIRSH domstate "$g" >/dev/null 2>&1 || { echo "pfs: COULD-NOT-RUN: no guest $g" >&2; exit 2; }
done
[ -z "$($VIRSH list --name | tr -d ' \n')" ] || {
	echo "pfs: COULD-NOT-RUN: a guest is running: $($VIRSH list --name | tr '\n' ' ')" >&2; exit 2; }

make -s clean >/dev/null 2>&1
make -s KDIR="$KDIR" >/dev/null 2>&1 || {
	echo "pfs: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko

rm -f "$IMG"
truncate -s 2G "$IMG" && "$NEWFS" -L "$ROOT" "$IMG" >/dev/null 2>&1 || {
	echo "pfs: COULD-NOT-RUN: newfs_hammer2 failed on $IMG" >&2; exit 2; }

fail=0
ndom=$(printf '%s\n' $DOMAINS | grep -c .)
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

# 1. Linux creates the PFSes, mounts each by label, writes a tree in each.
cat > "$W/linux.sh" <<GUEST
command -v hammer2 >/dev/null 2>&1 || { echo "no hammer2 utility on the guest"; exit 3; }
dev=\$(ls /dev/vd? | tail -1); mkdir -p /mnt/root
rmmod hammer2 2>/dev/null; insmod /tmp/hammer2.ko || exit 1; dmesg -C
mount -t hammer2 \$dev@$ROOT /mnt/root || { echo "root mount failed"; exit 1; }
created=0
for d in $DOMAINS; do hammer2 -s /mnt/root pfs-create \$d >/dev/null 2>&1 && created=\$((created+1)); done
echo "created \$created"
echo "pfs-list on linux: \$(hammer2 -s /mnt/root pfs-list 2>/dev/null | awk 'NR>1{print \$NF}' | tr '\n' ' ')"
mounted=0
for d in $DOMAINS; do
	mkdir -p /mnt/\$d
	mount -t hammer2 \$dev@\$d /mnt/\$d || { echo "mount by label \$d failed"; continue; }
	mounted=\$((mounted+1))
	cd /mnt/\$d
	mkdir -p tree; dd if=/dev/urandom of=tree/rand100k bs=1000 count=100 2>/dev/null
	i=0; while [ \$i -lt 20 ]; do echo "\$d \$i" > tree/f\$i; i=\$((i+1)); done
	find tree -type f | sort | xargs md5sum > manifest.md5
	echo "wrote \$d \$(wc -l < manifest.md5) files"
	cd /
done
echo "mounted by label \$mounted"
sync
for d in $DOMAINS; do umount /mnt/\$d 2>/dev/null; done
umount /mnt/root; echo "umount exit \$?"
echo "debug_locks \$(awk '/debug_locks:/{print \$2}' /proc/lockdep_stats)"; echo "kmsg lines \$(dmesg | wc -l)"; dmesg | grep -c -i 'WARNING\|BUG\|hung task' | sed 's/^/reports /'
rmmod hammer2; echo "rmmod exit \$?"
GUEST
boot "$GUEST" "$GUEST_SSH" || { down "$GUEST" "$GUEST_SSH"; exit 2; }
scp -q -o ConnectTimeout=5 "$KO" "$W/linux.sh" "$GUEST_SSH:/tmp/" || { echo "pfs: COULD-NOT-RUN: scp failed" >&2; down "$GUEST" "$GUEST_SSH"; exit 2; }
out=$($RUN "$GUEST_SSH" 'sh /tmp/linux.sh' 2>&1); st=$?
printf '%s\n' "$out" | sed 's/^/  linux   /'
down "$GUEST" "$GUEST_SSH"
[ $st = 3 ] && { echo "pfs: COULD-NOT-RUN: the Linux guest has no hammer2 utility" >&2; exit 2; }
[ $st = 124 ] && { echo "  FAIL  the guest hung: the run exceeded ${H2_RUN_TIMEOUT:-1800}s"; fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q "^created $ndom$" || { echo "  FAIL  not every PFS was created"; fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q "^mounted by label $ndom$" || { echo "  FAIL  not every PFS mounted by label"; fail=$((fail + 1)); }
for d in $DOMAINS; do
	printf '%s\n' "$out" | grep -q "^pfs-list on linux: .*\b$d\b" || { echo "  FAIL  $d missing from pfs-list here"; fail=$((fail + 1)); }
	printf '%s\n' "$out" | grep -q "^wrote $d [1-9][0-9]* files" || { echo "  FAIL  nothing written in $d"; fail=$((fail + 1)); }
done
for want in "^umount exit 0$" "^rmmod exit 0$" "^debug_locks 1$" "^kmsg lines [1-9]" "^reports 0$"; do
	printf '%s\n' "$out" | grep -q "$want" || { echo "  FAIL  wanted $want"; fail=$((fail + 1)); }
done
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "  ok    host fsck_hammer2 after linux" || { echo "  FAIL  host fsck_hammer2 after linux"; fail=$((fail + 1)); }
fsck_control "$IMG" || fail=$((fail + 1))

# 2. DragonFly mounts each by label and checks this side's manifests.
cat > "$W/dfly.sh" <<GUEST
listed=
for d in $DOMAINS; do
	mkdir -p /mnt/\$d
	mount_hammer2 /dev/vbd1@\$d /mnt/\$d || { echo "mount by label \$d failed"; continue; }
	# pfs-list wants a mount to route through, so it runs on the first.
	[ -n "\$listed" ] || { listed=1; echo "pfs-list on dragonfly: \$(hammer2 -s /mnt/\$d pfs-list 2>/dev/null | awk 'NR>1{print \$NF}' | tr '\n' ' ')"; }
	cd /mnt/\$d
	bad=0; n=0; while read sum path; do n=\$((n+1)); [ "\$(md5 -q "\$path")" = "\$sum" ] || bad=\$((bad+1)); done < manifest.md5
	echo "dragonfly checked \$d \$n files, \$bad mismatches"
	cd /; umount /mnt/\$d
done
fsck_hammer2 /dev/vbd1 >/dev/null 2>&1 && echo "dragonfly fsck clean"
GUEST
boot "$DFLY" "$DFLY_SSH" || { down "$DFLY" "$DFLY_SSH"; exit 2; }
scp -q -o ConnectTimeout=5 "$W/dfly.sh" "$DFLY_SSH:/tmp/" || { echo "pfs: COULD-NOT-RUN: scp failed" >&2; down "$DFLY" "$DFLY_SSH"; exit 2; }
out=$($RUN "$DFLY_SSH" 'sh /tmp/dfly.sh' 2>&1)
[ $? = 124 ] && { echo "  FAIL  the guest hung: the run exceeded ${H2_RUN_TIMEOUT:-1800}s"; fail=$((fail + 1)); }
printf '%s\n' "$out" | sed 's/^/  dfly    /'
down "$DFLY" "$DFLY_SSH"
for d in $DOMAINS; do
	printf '%s\n' "$out" | grep -q "^pfs-list on dragonfly: .*\b$d\b" || { echo "  FAIL  $d missing from pfs-list on DragonFly"; fail=$((fail + 1)); }
	printf '%s\n' "$out" | grep -q "^dragonfly checked $d [1-9][0-9]* files, 0 mismatches" || { echo "  FAIL  $d did not verify on DragonFly"; fail=$((fail + 1)); }
done
printf '%s\n' "$out" | grep -q "dragonfly fsck clean" || { echo "  FAIL  DragonFly's checker"; fail=$((fail + 1)); }
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "  ok    host fsck_hammer2 after dragonfly" || { echo "  FAIL  host fsck_hammer2 after dragonfly"; fail=$((fail + 1)); }
fsck_control "$IMG" || fail=$((fail + 1))

make -s clean >/dev/null 2>&1
echo "pfs: $ndom PFS roots made here, mounted by label on both sides, $fail failure(s)"
[ $fail = 0 ]
