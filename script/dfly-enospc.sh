#!/bin/sh
# A volume filled to ENOSPC on the DragonFly guest and unmounted: the
# reproducer test-enospc.sh runs here, on the tree the staged patches
# under doc/upstream/ are written against. Needs a DragonFly kernel
# built from a source tree carrying the two sysctls the provenance
# document describes, vfs.hammer2.fail_alloc_after and
# vfs.hammer2.alloc_count; the release kernel has neither and the run
# reports the refusal count as 0. Reads the kernel's config for
# INVARIANTS, what each writer was told, what the volume kept, the
# kernel messages the fill produced, and fsck afterwards. The writers
# read /dev/random because HAMMER2 stores nothing for an all-zero block,
# so a zero fill never ends. H2_KNOB is the allocation count after which
# the allocator refuses, H2_KNOB_LIFT the seconds after which the refusal
# is lifted, since a refusal left in place wedges the syncer and the fill
# never reaches the unmount. Needs the fleet; exits 2 without it.
set -u
DFLY=${H2_DFLY_GUEST:-dragonflybsd642}
DFLY_SSH=${H2_DFLY_SSH:-root@192.168.122.42}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
NEWFS=${H2_NEWFS:-$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2}
FSCK=${H2_FSCK:-$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2}
W=$(mktemp -d "${TMPDIR:-/tmp}/dfly-enospc.XXXXXX") || exit 2
IMG=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}/dfly-enospc.img; SIZE=${H2_ENOSPC_SIZE:-2G}; LABEL=ENOSPC
WRITERS=${H2_WRITERS:-4}

rm -f "$IMG"; truncate -s "$SIZE" "$IMG" || exit 2
"$NEWFS" -L "$LABEL" "$IMG" >/dev/null 2>&1 || { echo "COULD-NOT-RUN: newfs failed"; exit 2; }

state=$($VIRSH domstate "$DFLY" 2>/dev/null) || { echo "COULD-NOT-RUN: no guest $DFLY"; exit 2; }
[ "$state" = "shut off" ] || { echo "COULD-NOT-RUN: $DFLY is $state"; exit 2; }
err=$($VIRSH attach-disk "$DFLY" "$IMG" vdb --targetbus virtio --config 2>&1) || { echo "COULD-NOT-RUN: could not attach: $err"; exit 2; }
trap '$VIRSH shutdown "$DFLY" >/dev/null 2>&1; sleep 20; $VIRSH detach-disk "$DFLY" vdb --config >/dev/null 2>&1' EXIT
err=$($VIRSH start "$DFLY" 2>&1) || { echo "COULD-NOT-RUN: would not start: $err"; exit 2; }
i=0; while [ $i -lt 60 ]; do ssh -o ConnectTimeout=4 -o BatchMode=yes "$DFLY_SSH" true 2>/dev/null && break; sleep 5; i=$((i+1)); done
[ $i -lt 60 ] || { echo "COULD-NOT-RUN: $DFLY did not answer ssh in 5 minutes"; exit 2; }

cat > "$W/guest.sh" <<GUEST
uname -a
sysctl -n kern.conftxt 2>/dev/null | grep -c INVARIANTS | sed 's/^/invariants options: /'
sysctl -n kern.version | head -1
vmstat -m | grep HAMMER2-chains | sed "s/^/chains before mount: /"
mark=\$(dmesg | wc -l | tr -d ' ')
mkdir -p /mnt/e; mount_hammer2 /dev/vbd1@$LABEL /mnt/e || { echo "mount failed"; exit 1; }
sysctl vfs.hammer2.alloc_count=0; sysctl vfs.hammer2.fail_alloc_after='${H2_KNOB:-20000}'
( sleep '${H2_KNOB_LIFT:-120}'; sysctl vfs.hammer2.fail_alloc_after=0 ) &
cd /mnt/e; mkdir kept
n=0; while [ \$n -lt $WRITERS ]; do
  ( i=0; while dd if=/dev/random of=kept/w\$n-\$i bs=1m count=16 2>/dev/null; do i=\$((i+1)); done; echo "writer \$n stopped after \$i files, last: \$(dd if=/dev/random of=kept/w\$n-x bs=1m count=1 2>&1 | tail -1)" ) &
  n=\$((n+1))
done; wait
echo "small files after full: \$(i=0; while [ \$i -lt 200 ] && echo x > kept/s\$i 2>/dev/null; do i=\$((i+1)); done; echo \$i) of 200"
sysctl vfs.hammer2.fail_alloc_after=0; sync; sleep 2
files=\$(find kept -type f | wc -l | tr -d ' '); echo "files present before unmount: \$files"
df -k /mnt/e | tail -1
cd /; if umount /mnt/e; then echo unmounted; else echo "UNMOUNT FAILED"; fi; sysctl vfs.hammer2.alloc_count; sysctl vfs.hammer2.fail_alloc_after=0; vmstat -m | grep HAMMER2-chains | sed "s/^/chains after unmount: /"
echo "kernel messages since mount:"; dmesg | tail -n +\$((mark+1)) | grep -v '^$' | tail -120
mount_hammer2 /dev/vbd1@$LABEL /mnt/e && echo "remount ok, files: \$(find /mnt/e/kept -type f | wc -l | tr -d ' ')"; umount /mnt/e
fsck_hammer2 /dev/vbd1 >/dev/null 2>&1 && echo "dragonfly fsck clean" || echo "dragonfly fsck NOT clean"
GUEST
scp -q "$W/guest.sh" "$DFLY_SSH:/tmp/guest.sh" || { echo "COULD-NOT-RUN: scp failed"; exit 2; }
out=$(timeout "${H2_RUN_TIMEOUT:-1800}" ssh "$DFLY_SSH" 'sh /tmp/guest.sh' 2>&1); rc=$?
printf '%s\n' "$out" | sed 's/^/  dfly  /'
echo "run exit $rc"
