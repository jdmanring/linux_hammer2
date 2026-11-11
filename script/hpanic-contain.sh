#!/bin/sh
# What a device in error keeps off the media. On the debug build,
# debug_hpanic=2 has sync_fs call hpanic on the second call after the
# knob is set; files synced before that must be on the media after a
# hard stop, files written after it must not, and fsck must be clean.
# Run once with the knob and once with H2_KNOB=0, the control that
# shows the after-files land without it. H2_KNOB=3 is the acceptance
# reading for the returning hpanic, described where it runs below;
# H2_ACCEPT_CONTROL=1 H2_KNOB=0 runs that same sequence without the
# fault, where the sync passes and the device changes. H2_KO names a
# module built with HAMMER2_LOCKDEBUG=1. Needs the fleet; exits 2
# without it. Every reading is judged at the end against the mode's
# expectation, and a wrong one exits 1: the script printed its readings
# and exited 0 whatever they said until 2026-11-11.
set -u
KNOB=${H2_KNOB:-2}
KO=${H2_KO:-}
[ -n "$KO" ] && [ -f "$KO" ] || { echo "COULD-NOT-RUN: H2_KO names no module"; exit 2; }
export LIBVIRT_DEFAULT_URI=qemu:///system
command -v virsh >/dev/null 2>&1 || { echo "COULD-NOT-RUN: no virsh"; exit 2; }
GUEST=artix-s6-kde; GUEST_SSH=root@192.168.122.16
IMG=${H2_FIXTURE_DIR:-$HOME/Projects/linux_hammer2-data/fixtures}/hpanic.img
NEWFS=$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2
FSCK=$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2
T=$(mktemp) || exit 2
trap 'rm -f "$T"' EXIT
nf=0; nc=0
want() {	# description, extended regex that a line of the run must match
	nc=$((nc + 1))
	grep -Eq -- "$2" "$T" && echo "  ok    $1" || { echo "  FAIL  $1"; nf=$((nf + 1)); }
}
verdict() { echo "hpanic: knob $KNOB, $nc check(s), $nf failed"; [ $nf = 0 ] || exit 1; exit 0; }
rm -f "$IMG" "$IMG.pre"; truncate -s 1G "$IMG"; "$NEWFS" -L HP "$IMG" >/dev/null 2>&1 || { echo "COULD-NOT-RUN: newfs"; exit 2; }
waitssh() { i=0; while [ $i -lt 60 ]; do ssh -o ConnectTimeout=4 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null && return 0; sleep 5; i=$((i+1)); done; return 1; }
[ "$(virsh domstate $GUEST)" = "shut off" ] || { echo "COULD-NOT-RUN: $GUEST is $(virsh domstate $GUEST)"; exit 2; }
virsh start $GUEST >/dev/null 2>&1; waitssh || { echo "COULD-NOT-RUN: no ssh"; exit 2; }
# One lockdep report turns lockdep off until the next boot, and a run
# on that boot reads "no report" with nothing checking.
dl=$(ssh -o BatchMode=yes "$GUEST_SSH" "awk '/debug_locks:/ {print \$2}' /proc/lockdep_stats 2>/dev/null")
[ "$dl" = 0 ] && {
	echo "hpanic-contain: COULD-NOT-RUN: lockdep is off on $GUEST since an earlier report; boot it again" >&2; exit 2; }
virsh attach-disk $GUEST "$IMG" vdb --targetbus virtio >/dev/null 2>&1 || { echo "COULD-NOT-RUN: attach"; exit 2; }
scp -q "$KO" "$GUEST_SSH:/tmp/h2.ko"
ssh "$GUEST_SSH" "echo $KNOB > /tmp/h2knob"
if [ "$KNOB" = 3 ] || [ "${H2_ACCEPT_CONTROL:-0}" = 1 ]; then
# The acceptance reading for a returning hpanic: debug_hpanic=3 fires
# from hammer2_base_insert on the next block-table insert. The writer's
# sync gets EIO, the next create gets EIO, the mount reads ro, umount and
# rmmod return, no BUG or oops in the log, and the device reads back
# byte-identical to what the sync before the fault left.
# The guest pauses after its first sync; the host copies the image then
# and names each 64 KiB block that differs after the fault.
ssh "$GUEST_SSH" rm -f /tmp/h2pre
(until ssh "$GUEST_SSH" test -e /tmp/h2pre; do sleep 2; done
 cp "$IMG" "$IMG.pre"; ssh "$GUEST_SSH" rm -f /tmp/h2pre) &
ssh "$GUEST_SSH" sh <<"REMOTE" 2>&1 | sed "s/^/  guest /" | tee -a "$T"
dmesg -C
insmod /tmp/h2.ko || exit 9
mkdir -p /mnt/hp; mount -t hammer2 /dev/vdb@HP /mnt/hp || exit 9
i=0; while [ $i -lt 20 ]; do echo before > /mnt/hp/before-$i; i=$((i+1)); done
sync -f /mnt/hp; echo "first sync $?"
sha_before=$(dd if=/dev/vdb bs=1M iflag=direct 2>/dev/null | sha256sum | cut -c1-16)
echo "sha before $sha_before"
touch /tmp/h2pre
while [ -e /tmp/h2pre ]; do sleep 1; done
cat /tmp/h2knob > /sys/module/hammer2/parameters/debug_hpanic || { echo "knob not set"; exit 9; }
echo after > /mnt/hp/after-0
timeout 60 sync -f /mnt/hp; echo "armed sync $?"
echo after > /mnt/hp/after-1 2>/dev/null; echo "create after the fault $?"
echo "mount options $(findmnt -no OPTIONS /mnt/hp | cut -d, -f1)"
timeout 60 umount /mnt/hp; echo "umount $?"
timeout 60 rmmod hammer2; echo "rmmod $?"
sha_after=$(dd if=/dev/vdb bs=1M iflag=direct 2>/dev/null | sha256sum | cut -c1-16)
[ "$sha_before" = "$sha_after" ] && echo "device identical $sha_before" || echo "device CHANGED $sha_before $sha_after"
echo "log: bug $(dmesg | grep -c "kernel BUG") oops $(dmesg | grep -ci oops) warn $(dmesg | grep -c "WARNING:") hpanic $(dmesg | grep -c "insert stops here")"
REMOTE
virsh detach-disk $GUEST vdb >/dev/null 2>&1; virsh shutdown $GUEST >/dev/null 2>&1
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "host fsck clean" | tee -a "$T" || echo "host fsck NOT clean"
[ -f "$IMG.pre" ] || echo "no pre-fault copy, the block list below is empty for that reason"
echo "blocks changed after the fault: $(cmp -l "$IMG.pre" "$IMG" 2>/dev/null | awk '{ b = int(($1 - 1) / 65536); if (NR == 1 || b != last) { printf "%x ", b * 65536; last = b } }')"
want "the host's fsck is clean" '^host fsck clean$'
want "rmmod returned" 'guest rmmod 0$'
want "umount returned" 'guest umount 0$'
if [ "$KNOB" = 0 ]; then
	want "the sync passed without the fault" 'guest armed sync 0$'
	want "the sync changed the device" 'guest device CHANGED'
else
	want "the armed sync failed" 'guest armed sync [1-9]'
	want "the create after the fault failed" 'guest create after the fault [1-9]'
	want "the mount reads ro" 'guest mount options ro$'
	want "the device is byte-identical to the sync before the fault" 'guest device identical'
	want "no BUG and no oops in the log" 'guest log: bug 0 oops 0 '
fi
verdict
fi
ssh "$GUEST_SSH" '
dmesg -C
insmod /tmp/h2.ko || exit 9
mkdir -p /mnt/hp; mount -t hammer2 /dev/vdb@HP /mnt/hp || exit 9
i=0; while [ $i -lt 20 ]; do echo before > /mnt/hp/before-$i; i=$((i+1)); done
sync -f /mnt/hp; echo "first sync $?"
cat /tmp/h2knob > /sys/module/hammer2/parameters/debug_hpanic || { echo "knob not set"; exit 9; }
timeout 60 sync -f /mnt/hp; echo "armed sync $?"
i=0; while [ $i -lt 20 ]; do echo after > /mnt/hp/after-$i; i=$((i+1)); done
echo "after-files written: $(ls /mnt/hp | grep -c after)"
timeout 60 sync -f /mnt/hp; echo "second sync $?"
dmesg | grep -E "hammer2|BUG|device in error" | grep -v "Modules linked" | head -12
' 2>&1 | sed 's/^/  guest /' | tee -a "$T"
echo "hard stop"; virsh destroy $GUEST >/dev/null 2>&1; sleep 3
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "host fsck clean after the stop" | tee -a "$T" || echo "host fsck NOT clean"
virsh start $GUEST >/dev/null 2>&1; waitssh || { echo "COULD-NOT-RUN: no ssh after restart"; exit 2; }
virsh attach-disk $GUEST "$IMG" vdb --targetbus virtio >/dev/null 2>&1
scp -q "$KO" "$GUEST_SSH:/tmp/h2.ko"
ssh "$GUEST_SSH" sh <<"REMOTE" 2>&1 | sed "s/^/  guest /" | tee -a "$T"
insmod /tmp/h2.ko || exit 9
mkdir -p /mnt/hp; mount -t hammer2 /dev/vdb@HP /mnt/hp || { echo "remount failed"; exit 9; }
echo "on media: before $(ls /mnt/hp | grep -c before) after $(ls /mnt/hp | grep -c after)"
umount /mnt/hp; rmmod hammer2; echo "rmmod $?"
REMOTE
virsh detach-disk $GUEST vdb >/dev/null 2>&1; virsh shutdown $GUEST >/dev/null 2>&1
want "the host's fsck is clean after the hard stop" '^host fsck clean after the stop$'
want "the first sync passed" 'guest first sync 0$'
want "every file synced before the fault is on the media" 'guest on media: before 20 '
if [ "$KNOB" = 0 ]; then
	want "the control's after-files are on the media" 'guest on media: before 20 after 20$'
else
	want "the device was marked in error" 'device in error'
	want "no file written after the fault is on the media" 'guest on media: before 20 after 0$'
fi
verdict
