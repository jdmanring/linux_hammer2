#!/bin/sh
# THE VOLUME AS A ROOT FILESYSTEM, AND THE MAPPING THAT LETS IT BE ONE.
#
# A file on this filesystem could read back byte for byte correct and
# still not execute, because hammer2_file_fops carried no mapping
# operation and the ELF loader maps what it loads. cmp and md5sum both
# say a copied binary is intact, so no checksum gate could see it; only
# running the binary could. This script runs it, and then goes the whole
# way: it boots a kernel whose root filesystem is a HAMMER2 volume, with
# PID 1 executing from that volume.
#
# Four stages, each printed:
#   1. a static binary copied onto a volume and executed from it
#   2. a 128 KiB file, two of this port's 64 KiB folios, written entirely
#      through a shared writable mapping, msynced, and compared on media
#      after drop_caches and again after a fresh mount
#   3. the boot: an initramfs holding the module and test/rootfs's init,
#      which reads root= from the kernel command line, mounts the volume,
#      moves the mount over / and executes /sbin/init from it
#   4. the negative control, the same boot against a label that is not on
#      the volume, which must fail at the mount and must not reach PID 1
#
# Stage 4 is where this script would otherwise prove nothing. The boot
# prints its own progress, so a script that only grepped for the last
# line would pass on a kernel that never mounted anything, and the
# control is placed at the mount because that is the step under test.
#
# EXIT 2 IS COULD-NOT-RUN AND IS NEVER A PASS, as in test-fixtures.sh.
set -u
cd "$(dirname "$0")/.." || exit 2

FIXDIR=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}
IMG=$FIXDIR/rootfs.img
LABEL=ROOT
SIZE=${H2_ROOT_SIZE:-4G}
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
BZIMAGE=${H2_BZIMAGE:-$KDIR/arch/x86/boot/bzImage}
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2")}
FSCK=${H2_FSCK:-$(command -v fsck_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2")}
QEMU=${H2_QEMU:-qemu-system-x86_64}

command -v cc >/dev/null 2>&1 || { echo "root-boot: COULD-NOT-RUN: no cc" >&2; exit 2; }
command -v cpio >/dev/null 2>&1 || { echo "root-boot: COULD-NOT-RUN: no cpio" >&2; exit 2; }
command -v "$QEMU" >/dev/null 2>&1 || { echo "root-boot: COULD-NOT-RUN: no $QEMU" >&2; exit 2; }
[ -x "$NEWFS" ] || { echo "root-boot: COULD-NOT-RUN: no newfs_hammer2 at $NEWFS" >&2; exit 2; }
[ -f "$BZIMAGE" ] || { echo "root-boot: COULD-NOT-RUN: no kernel image at $BZIMAGE" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "root-boot: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -r /dev/kvm ] || { echo "root-boot: COULD-NOT-RUN: no /dev/kvm" >&2; exit 2; }

# The module has to build before anything else is spent on this.
make KDIR="$KDIR" >/dev/null 2>&1 || {
	echo "root-boot: FAIL: the module does not build against $KDIR"; exit 1; }
KO=src/sys/fs/hammer2/hammer2.ko
[ -f "$KO" ] || { echo "root-boot: FAIL: $KO was not produced"; exit 1; }

W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT
fail=0

cc -static -O2 -o "$W/init" test/rootfs/h2root-init.c 2>/dev/null || {
	echo "root-boot: COULD-NOT-RUN: the init does not build static" >&2; exit 2; }
cc -static -O2 -o "$W/mmaptest" test/hammer2-mmap-exercise.c 2>/dev/null || {
	echo "root-boot: COULD-NOT-RUN: the mmap exerciser does not build static" >&2; exit 2; }

# A fresh volume every run: the boot writes to it and a second run must
# not be reading what the first one left.
rm -f "$IMG"
truncate -s "$SIZE" "$IMG" || exit 2
"$NEWFS" -L "$LABEL" "$IMG" >/dev/null 2>&1 || {
	echo "root-boot: COULD-NOT-RUN: newfs_hammer2 failed on $IMG" >&2; exit 2; }

# Stages 1 and 2 need a running guest, because this host's kernel is not
# the kernel of record and cannot load the module.
started=no
if ! $VIRSH domstate "$GUEST" 2>/dev/null | grep -q running; then
	$VIRSH start "$GUEST" >/dev/null 2>&1 || {
		echo "root-boot: COULD-NOT-RUN: $GUEST would not start" >&2; exit 2; }
	started=yes
fi
i=0
while [ "$i" -lt 60 ]; do
	ssh -o ConnectTimeout=4 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null && break
	i=$((i + 1))
done
[ "$i" -lt 60 ] || { echo "root-boot: COULD-NOT-RUN: $GUEST did not answer ssh" >&2; exit 2; }

guest_rel=$(ssh "$GUEST_SSH" 'uname -r' 2>/dev/null)
ko_rel=$(modinfo -F vermagic "$KO" 2>/dev/null | awk '{print $1}')
if [ "$guest_rel" != "$ko_rel" ]; then
	echo "root-boot: COULD-NOT-RUN: the module is for $ko_rel and $GUEST runs $guest_rel" >&2
	[ "$started" = yes ] && $VIRSH shutdown "$GUEST" >/dev/null 2>&1
	exit 2
fi

$VIRSH attach-disk "$GUEST" "$IMG" vdb --targetbus virtio >/dev/null 2>&1 || {
	echo "root-boot: COULD-NOT-RUN: could not attach $IMG" >&2; exit 2; }
scp -q -o ConnectTimeout=5 "$KO" "$GUEST_SSH:/tmp/h2.ko" >/dev/null 2>&1
scp -q -o ConnectTimeout=5 "$W/init" "$W/mmaptest" "$GUEST_SSH:/tmp/" >/dev/null 2>&1

out=$(ssh "$GUEST_SSH" '
	dmesg -C
	rmmod hammer2 2>/dev/null
	insmod /tmp/h2.ko || exit 1
	mkdir -p /mnt/h2root
	mount -t hammer2 /dev/vdb@ROOT /mnt/h2root || exit 1
	mkdir -p /mnt/h2root/sbin /mnt/h2root/proc /mnt/h2root/sys /mnt/h2root/dev
	cp /tmp/init /mnt/h2root/sbin/init; chmod 755 /mnt/h2root/sbin/init
	cp /bin/true /mnt/h2root/probe; sync
	cmp /bin/true /mnt/h2root/probe && echo "read identical"
	/mnt/h2root/probe --help >/dev/null 2>&1; echo "exec status $?"
	/tmp/mmaptest /mnt/h2root/mapped >/dev/null 2>&1; echo "mmap status $?"
	sync; echo 3 > /proc/sys/vm/drop_caches
	echo "mapped size $(stat -c %s /mnt/h2root/mapped)"
	echo "mapped sum $(md5sum /mnt/h2root/mapped | cut -d" " -f1)"
	umount /mnt/h2root
	mount -t hammer2 -o ro /dev/vdb@ROOT /mnt/h2root
	echo "mapped sum after remount $(md5sum /mnt/h2root/mapped | cut -d" " -f1)"
	umount /mnt/h2root
	echo "debug_locks $(sed -n "s/^ *debug_locks: *//p" /proc/lockdep_stats)"
	echo "reports $(dmesg | grep -ci "warn\|bug\|oops")"
	rmmod hammer2
' 2>&1)
printf '%s\n' "$out" | sed 's/^/  guest  /'
$VIRSH detach-disk "$GUEST" vdb >/dev/null 2>&1
[ "$started" = yes ] && $VIRSH shutdown "$GUEST" >/dev/null 2>&1

printf '%s\n' "$out" | grep -q '^read identical$' || {
	echo "  FAIL  the copied binary did not read back identical"; fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q '^exec status 0$' || {
	echo "  FAIL  a binary on the volume would not execute"; fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q '^mmap status 0$' || {
	echo "  FAIL  the shared writable mapping did not survive msync"; fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q '^mapped size 131072$' || {
	echo "  FAIL  the mapped file is not 131072 bytes on media"; fail=$((fail + 1)); }
# Anchored on the whole line: `s/^mapped sum //p` also matches the
# `mapped sum after remount` line, so the first capture came back as two
# lines and never equalled the second.
a=$(printf '%s\n' "$out" | sed -n 's/^mapped sum \([0-9a-f][0-9a-f]*\)$/\1/p')
b=$(printf '%s\n' "$out" | sed -n 's/^mapped sum after remount \([0-9a-f][0-9a-f]*\)$/\1/p')
if [ -z "$a" ] || [ "$a" != "$b" ]; then
	echo "  FAIL  the mapped file reads differently after a fresh mount"
	fail=$((fail + 1))
fi
printf '%s\n' "$out" | grep -q '^reports 0$' ||
	{ echo "  FAIL  the guest logged a kernel report"; fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q '^debug_locks 1$' ||
	echo "  note lockdep was not enabled on $GUEST, so lock order was not validated"

# The initramfs: the module and the init, and the four directories the
# init mounts onto.
mkdir -p "$W/irfs/proc" "$W/irfs/sys" "$W/irfs/dev" "$W/irfs/root"
cp "$W/init" "$W/irfs/init"
cp "$KO" "$W/irfs/hammer2.ko"
( cd "$W/irfs" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$W/initramfs.gz" ) ||
	{ echo "root-boot: COULD-NOT-RUN: could not build the initramfs" >&2; exit 2; }

boot() {
	timeout 240 "$QEMU" -enable-kvm -m 2048 -smp 2 -cpu host -nographic \
	    -kernel "$BZIMAGE" -initrd "$W/initramfs.gz" \
	    -append "console=ttyS0 root=/dev/vda@$1 rootfstype=hammer2 rootwait panic=10" \
	    -drive file="$IMG",if=virtio,format=raw \
	    -serial mon:stdio 2>&1
}

log=$(boot "$LABEL")
printf '%s\n' "$log" | grep '^H2ROOT' | sed 's/^/  boot   /'
for want in 'module loaded' 'hammer2 mounted as the new root' 'switched root' \
    'pid 1 is running from the hammer2 volume' 'read back: written by pid 1' \
    'remounted read-only'; do
	printf '%s\n' "$log" | grep -q "H2ROOT: $want" || {
		echo "  FAIL  the boot never reported: $want"; fail=$((fail + 1)); }
done
printf '%s\n' "$log" | grep -qi 'kernel panic' && {
	echo "  FAIL  the boot panicked"; fail=$((fail + 1)); }

# The control. A label the volume does not carry must stop the boot at
# the mount, which is the step every claim above rests on.
log=$(boot NOSUCHLABEL)
printf '%s\n' "$log" | grep '^H2ROOT' | sed 's/^/  ctrl   /'
if printf '%s\n' "$log" | grep -q 'H2ROOT: mount of the hammer2 root failed'; then
	echo "  ok    a label the volume does not carry stops the boot at the mount"
else
	echo "  FAIL  the control boot did not fail at the mount, so the boot"
	echo "        above proves nothing about the mount"
	fail=$((fail + 1))
fi
printf '%s\n' "$log" | grep -q 'H2ROOT: pid 1 is running' && {
	echo "  FAIL  the control boot reached PID 1"; fail=$((fail + 1)); }

if [ -x "$FSCK" ]; then
	if "$FSCK" "$IMG" >/dev/null 2>&1; then
		echo "  ok    host fsck_hammer2 on the volume the boot wrote"
	else
		echo "  FAIL  host fsck_hammer2 on the volume the boot wrote"
		fail=$((fail + 1))
	fi
else
	echo "  note no fsck_hammer2, so the volume was not checked from the host"
fi

make -s clean >/dev/null 2>&1
echo "root-boot: 2 boot(s), 1 control, $fail failure(s)"
[ "$fail" -eq 0 ]
