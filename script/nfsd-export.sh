#!/bin/sh
# A HAMMER2 volume exported by a running nfsd and used through the export.
#
# test/hammer2-fh.c drives export_operations through name_to_handle_at(2)
# and open_by_handle_at(2), and README.capabilities.md is explicit that
# this is not an export: nfsd checks a different acceptance callback, and
# ->fh_to_parent runs only from nfsd's subtree check.  This is the export.
# The guest serves a HAMMER2 mount over NFS to itself on 127.0.0.1, works
# through the client mount, and reads the answers back on the server side.
#
# Two exports, because the two differ in the code they reach:
#   no_subtree_check  the common one: handles carry no parent, so the
#                     decode is ->fh_to_dentry and, for a directory, the
#                     reconnect walk through ->get_parent
#   subtree_check     nfsd_acceptable() walks the decoded dentry up to the
#                     export root, and when no acceptable alias is cached
#                     the decode falls back to ->fh_to_parent, the one
#                     member no syscall can reach
# Each is checked from a cold server cache (the client keeps its handles,
# the server's dentries are dropped), which is what makes the server
# decode the handle rather than find the dentry already in memory.
#
# The guest must be running a kernel with CONFIG_NFSD; the pinned kernels
# are not, so KDIR names the nfsd build and the guest boots it.
#
# Not a gate.  Exit 2 without the guest, the tools, an nfsd kernel or the
# NFS userspace.
set -u
cd "$(dirname "$0")/.." || exit 2
FIXDIR=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}
IMG=$FIXDIR/nfsd-export.img
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2}
FSCK=${H2_FSCK:-$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2}
KO=src/sys/fs/hammer2/hammer2.ko

[ -x "$NEWFS" ] || { echo "nfsd: COULD-NOT-RUN: no newfs_hammer2 at $NEWFS" >&2; exit 2; }
[ -x "$FSCK" ] || { echo "nfsd: COULD-NOT-RUN: no fsck_hammer2 at $FSCK" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "nfsd: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -f "$KDIR/Makefile" ] || { echo "nfsd: COULD-NOT-RUN: KDIR=$KDIR is not a kernel tree" >&2; exit 2; }
command grep -q '^CONFIG_NFSD=[ym]' "$KDIR/.config" 2>/dev/null || {
	echo "nfsd: COULD-NOT-RUN: KDIR=$KDIR is built without CONFIG_NFSD" >&2; exit 2; }
command -v virsh >/dev/null 2>&1 || { echo "nfsd: COULD-NOT-RUN: no virsh" >&2; exit 2; }
make KDIR="$KDIR" >/dev/null 2>&1 || { echo "nfsd: FAIL: the module does not build against $KDIR"; exit 1; }

ssh -o ConnectTimeout=4 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null || {
	echo "nfsd: COULD-NOT-RUN: $GUEST does not answer ssh" >&2; exit 2; }
guest_rel=$(ssh "$GUEST_SSH" 'uname -r' 2>/dev/null)
ko_rel=$(modinfo -F vermagic "$KO" 2>/dev/null | awk '{print $1}')
[ "$guest_rel" = "$ko_rel" ] || {
	echo "nfsd: COULD-NOT-RUN: the module is for $ko_rel and $GUEST runs $guest_rel" >&2; exit 2; }
ssh "$GUEST_SSH" 'command -v exportfs && command -v rpc.nfsd && command -v rpc.mountd && command -v rpcbind && command -v mount.nfs' >/dev/null 2>&1 || {
	echo "nfsd: COULD-NOT-RUN: the guest lacks the NFS userspace" >&2; exit 2; }

rm -f "$IMG"
truncate -s 2G "$IMG" && "$NEWFS" -L NFS "$IMG" >/dev/null 2>&1 || {
	echo "nfsd: COULD-NOT-RUN: newfs_hammer2 failed" >&2; exit 2; }
detach() { $VIRSH detach-disk "$GUEST" vdb --live >/dev/null 2>&1; }
detach
$VIRSH attach-disk "$GUEST" "$IMG" vdb --targetbus virtio --live >/dev/null 2>&1 || {
	echo "nfsd: COULD-NOT-RUN: could not attach $IMG" >&2; exit 2; }
scp -q "$KO" "$GUEST_SSH:/tmp/h2.ko" || { detach; echo "nfsd: COULD-NOT-RUN: copy failed" >&2; exit 2; }

run='
set -u
i=0; while [ ! -b /dev/vdb ] && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done
S=/mnt/h2nfs-srv; C=/mnt/h2nfs-cli
dmesg -C
umount -f $C 2>/dev/null; exportfs -ua 2>/dev/null; umount $S 2>/dev/null
rmmod hammer2 2>/dev/null
insmod /tmp/h2.ko || { echo "SETUP insmod failed"; exit 0; }
mkdir -p $S $C
mount -t hammer2 /dev/vdb@NFS $S || { echo "SETUP mount failed"; exit 0; }
# Each decode member is counted by the function tracer, so whether the
# subtree export reached ->fh_to_parent is read rather than assumed.
T=/sys/kernel/tracing
mountpoint -q $T || mount -t tracefs tracefs $T
echo 0 > $T/tracing_on; echo > $T/trace
echo nop > $T/current_tracer
printf "%s\n" hammer2_fh_to_dentry hammer2_fh_to_parent hammer2_get_parent > $T/set_ftrace_filter || { echo "SETUP the decode functions cannot be traced"; exit 0; }
echo function > $T/current_tracer
count() { grep -c "$1" $T/trace; }
modprobe nfsd || { echo "SETUP no nfsd module"; exit 0; }
mountpoint -q /proc/fs/nfsd || mount -t nfsd nfsd /proc/fs/nfsd
pgrep -x rpcbind >/dev/null || rpcbind
rpc.nfsd 4 || { echo "SETUP rpc.nfsd failed"; exit 0; }
pgrep -x rpc.mountd >/dev/null || rpc.mountd
# The tree the client walks: a file at the root, a file three directories
# down so the subtree walk has parents to climb, and one renamed under the
# client after its handle is held.
mkdir -p $S/a/b/c
echo root-file > $S/top
echo deep-file > $S/a/b/c/deep
echo before-rename > $S/a/b/old
sync
for mode in no_subtree_check subtree_check; do
	echo > $T/trace; echo 1 > $T/tracing_on
	echo "== $mode"
	exportfs -o rw,sync,no_root_squash,fsid=4242,$mode 127.0.0.1:$S || { echo "check export $mode refused"; continue; }
	echo "check export $mode accepted"
	mount -t nfs -o vers=3,proto=tcp,nolock,actimeo=0,lookupcache=none 127.0.0.1:$S $C || { echo "check client mount $mode failed"; exportfs -u 127.0.0.1:$S; continue; }
	[ "$(cat $C/top)" = root-file ] && echo "check $mode root file ok" || echo "check $mode root file wrong"
	[ "$(cat $C/a/b/c/deep)" = deep-file ] && echo "check $mode deep file ok" || echo "check $mode deep file wrong"
	ls $C/a/b/c | grep -qx deep && echo "check $mode readdir ok" || echo "check $mode readdir wrong"
	echo client-$mode > $C/a/b/c/new-$mode
	sync
	[ "$(cat $S/a/b/c/new-$mode)" = client-$mode ] && echo "check $mode create reached the server ok" || echo "check $mode create reached the server wrong"
	# Hold handles in the client, then drop the server dentry cache so
	# the next use is a decode of the handle, not a cache hit.
	exec 7<$C/a/b/c/deep
	exec 8<$C/a/b/old
	mv $S/a/b/old $S/a/b/c/renamed
	sync; echo 2 > /proc/sys/vm/drop_caches
	[ "$(cat <&7)" = deep-file ] && echo "check $mode deep file by handle after a cold cache ok" || echo "check $mode deep file by handle after a cold cache wrong"
	# The old name of a renamed file is what the client still holds, and the
	# two exports answer it differently on purpose.  subtree_check has
	# nfsd verify the name against the parent, and the name is gone, so
	# the answer is stale; no_subtree_check never looks and reads the
	# file.  ext4 answers subtree_check the same way, measured on the
	# guest, so this asserts the export mode and not the filesystem.
	case $mode in
	subtree_check)
		if cat <&8 >/dev/null 2>&1; then
			echo "check $mode renamed file still answered wrong"
		else
			echo "check $mode renamed file is stale by name ok"
		fi ;;
	*)
		[ "$(cat <&8)" = before-rename ] && echo "check $mode renamed file by its handle ok" || echo "check $mode renamed file by its handle wrong" ;;
	esac
	exec 7<&- 8<&-
	# A stale handle: removed on the server, its handle must not answer.
	exec 9<$C/a/b/c/new-$mode
	rm $S/a/b/c/new-$mode; sync; echo 2 > /proc/sys/vm/drop_caches
	if cat <&9 >/dev/null 2>&1; then echo "check $mode removed file still answered wrong"; else echo "check $mode removed file is stale ok"; fi
	exec 9<&-
	mv $S/a/b/c/renamed $S/a/b/old
	umount $C || umount -f $C
	exportfs -u 127.0.0.1:$S
	echo 0 > $T/tracing_on
	echo "decode $mode fh_to_dentry $(count hammer2_fh_to_dentry) fh_to_parent $(count hammer2_fh_to_parent) get_parent $(count hammer2_get_parent)"
done
echo nop > $T/current_tracer; echo > $T/set_ftrace_filter
exportfs -ua
rpc.nfsd 0
umount $S; echo "umount exit $?"
rmmod hammer2; echo "rmmod exit $?"
echo "log: bug $(dmesg | grep -c "kernel BUG") oops $(dmesg | grep -ci oops) warn $(dmesg | grep -c "WARNING:")"
'
out=$(timeout 1200 ssh "$GUEST_SSH" "$run" 2>&1)
rc=$?
printf '%s\n' "$out" | sed 's/^/  /'
if [ "$rc" -eq 124 ]; then
	# A hang is read through the agent before the disk is detached, or
	# its checks would be graded on whatever output preceded it.
	echo "nfsd: FAIL: the guest did not finish within 1200 s"
	sh "$(dirname "$0")/guest-dmesg.sh" "$GUEST" 2>&1 | sed 's/^/  hang    /'
	detach
	exit 1
fi
detach
case $out in *SETUP*) echo "nfsd: COULD-NOT-RUN: $(printf '%s\n' "$out" | command grep -m1 SETUP)" >&2; exit 2 ;; esac

ok=$(printf '%s\n' "$out" | command grep -c '^check .* ok$')
bad=$(printf '%s\n' "$out" | command grep -cE '^check .*(wrong|refused|failed)$')
fail=$bad
# Two exports of seven checks each; fewer is a run that asked less than it
# says.
[ "$ok" -eq 14 ] || { echo "  FAIL  $ok check(s) passed where 14 are asked"; fail=$((fail + 1)); }
# The decode has to have run through the handle at all, or the cold-cache
# checks were cache hits and prove nothing about export_operations.
for mode in no_subtree_check subtree_check; do
	n=$(printf '%s\n' "$out" | sed -n "s/^decode $mode fh_to_dentry \([0-9]*\) .*/\1/p")
	[ "${n:-0}" -gt 0 ] && echo "  ok    $mode decoded $n handle(s) through fh_to_dentry" || {
		echo "  FAIL  $mode never called fh_to_dentry, so no handle was decoded"; fail=$((fail + 1)); }
done
fp=$(printf '%s\n' "$out" | sed -n 's/^decode subtree_check .*fh_to_parent \([0-9]*\) .*/\1/p')
echo "  note  subtree_check reached fh_to_parent ${fp:-0} time(s)"
for want in '^umount exit 0$' '^rmmod exit 0$' '^log: bug 0 oops 0 warn 0$'; do
	printf '%s\n' "$out" | command grep -q "$want" || { echo "  FAIL  no line matching $want"; fail=$((fail + 1)); }
done
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "  ok    fsck_hammer2 clean after the exports" || {
	echo "  FAIL  fsck_hammer2 after the exports"; fail=$((fail + 1)); }
echo "nfsd: $ok check(s) passed, $fail failure(s)"
[ "$fail" -eq 0 ]
