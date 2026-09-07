#!/bin/sh
# What a device in error keeps off the media. On the debug build,
# debug_hpanic=2 has sync_fs call hpanic on the second call after the
# knob is set; files synced before that must be on the media after a
# hard stop, files written after it must not, and fsck must be clean.
# Run once with the knob and once with H2_KNOB=0, the control that
# shows the after-files land without it. H2_KO names a module built
# with HAMMER2_LOCKDEBUG=1. Needs the fleet; exits 2 without it.
set -u
KNOB=${H2_KNOB:-2}
KO=${H2_KO:-}
[ -n "$KO" ] && [ -f "$KO" ] || { echo "COULD-NOT-RUN: H2_KO names no module"; exit 2; }
export LIBVIRT_DEFAULT_URI=qemu:///system
command -v virsh >/dev/null 2>&1 || { echo "COULD-NOT-RUN: no virsh"; exit 2; }
GUEST=artix-s6-kde; GUEST_SSH=root@192.168.122.16
IMG=/mnt/storage/hammer2-fixtures/hpanic.img
NEWFS=$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2
FSCK=$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2
rm -f "$IMG"; truncate -s 1G "$IMG"; "$NEWFS" -L HP "$IMG" >/dev/null 2>&1 || { echo "COULD-NOT-RUN: newfs"; exit 2; }
waitssh() { i=0; while [ $i -lt 60 ]; do ssh -o ConnectTimeout=4 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null && return 0; sleep 5; i=$((i+1)); done; return 1; }
[ "$(virsh domstate $GUEST)" = "shut off" ] || { echo "COULD-NOT-RUN: $GUEST is $(virsh domstate $GUEST)"; exit 2; }
virsh start $GUEST >/dev/null 2>&1; waitssh || { echo "COULD-NOT-RUN: no ssh"; exit 2; }
virsh attach-disk $GUEST "$IMG" vdb --targetbus virtio >/dev/null 2>&1 || { echo "COULD-NOT-RUN: attach"; exit 2; }
scp -q "$KO" "$GUEST_SSH:/tmp/h2.ko"
ssh "$GUEST_SSH" "echo $KNOB > /tmp/h2knob"
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
' 2>&1 | sed 's/^/  guest /'
echo "hard stop"; virsh destroy $GUEST >/dev/null 2>&1; sleep 3
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "host fsck clean" || echo "host fsck NOT clean"
virsh start $GUEST >/dev/null 2>&1; waitssh || { echo "COULD-NOT-RUN: no ssh after restart"; exit 2; }
virsh attach-disk $GUEST "$IMG" vdb --targetbus virtio >/dev/null 2>&1
scp -q "$KO" "$GUEST_SSH:/tmp/h2.ko"
ssh "$GUEST_SSH" sh <<"REMOTE" 2>&1 | sed "s/^/  guest /"
insmod /tmp/h2.ko || exit 9
mkdir -p /mnt/hp; mount -t hammer2 /dev/vdb@HP /mnt/hp || { echo "remount failed"; exit 9; }
echo "on media: before $(ls /mnt/hp | grep -c before) after $(ls /mnt/hp | grep -c after)"
umount /mnt/hp; rmmod hammer2; echo "rmmod $?"
REMOTE
virsh detach-disk $GUEST vdb >/dev/null 2>&1; virsh shutdown $GUEST >/dev/null 2>&1
echo "done"
