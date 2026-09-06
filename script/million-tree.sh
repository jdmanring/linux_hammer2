#!/bin/sh
# A MILLION-FILE TREE, WRITTEN HERE, COUNTED AFTER A REMOUNT AND BY DRAGONFLY.
# 0.9 asks for million-file trees with the number they produced, and a run
# without a number is not a pass. This is the first of its criteria that
# needs only the fleet: a tree of H2_TREE_FILES files under H2_TREE_FANOUT
# directories is created through the write path, synced, unmounted and
# remounted here, and every reading is a number: the create rate, the sync
# and unmount times, the memory the tree took, the count after the remount
# with the page cache dropped, the cold walk time, and DragonFly's count of
# the same volume. The kernel-warning count is scoped past the module load
# as test-enospc.sh scopes it, and lockdep is read on both sides.
#
# Exit 2 without the two guests, the tools or a kernel tree. One guest at
# a time: the Linux guest writes and is shut down, then DragonFly reads.
set -u
# Run from a private copy: the shell reads a script as it goes, so an
# edit to this file during a run lands in the middle of the run, and did.
if [ -z "${H2_TREE_COPY:-}" ]; then
	c=$(mktemp) || exit 2
	cat "$0" > "$c"
	H2_TREE_COPY=$c exec sh "$c" "$@"
fi
trap 'rm -f "$H2_TREE_COPY"' EXIT
FIXDIR=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}
IMG=${H2_TREE_IMAGE:-$FIXDIR/million-tree.img}
SIZE=${H2_TREE_SIZE:-8G}
N=${H2_TREE_FILES:-1000000}
MODARGS=${H2_TREE_MODARGS:-}	# module parameters for the guest's insmod, for a control
GUESTPRE=${H2_TREE_GUESTPRE:-:}	# run on the guest before insmod, for a control (echo off > /sys/kernel/debug/kmemleak)
FAN=${H2_TREE_FANOUT:-1000}
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
DFLY=${H2_DFLY_GUEST:-dragonflybsd642}
DFLY_SSH=${H2_DFLY_SSH:-root@192.168.122.42}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2")}
FSCK=${H2_FSCK:-$(command -v fsck_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2")}
W=$(mktemp -d) || exit 2
# Bounded from this side, as pfs-domains.sh bounds its runs: a guest whose
# task hangs keeps sshd answering. A million files take longer than the
# other scripts' work, so the default bound is an hour.
RUN="timeout ${H2_RUN_TIMEOUT:-3600} ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
trap 'rm -rf "$W" "$H2_TREE_COPY"' EXIT

fsck_control() {	# image; the negative control every host fsck verdict carries
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

command -v virsh >/dev/null 2>&1 || { echo "tree: COULD-NOT-RUN: no virsh" >&2; exit 2; }
[ -x "$NEWFS" ] || { echo "tree: COULD-NOT-RUN: no newfs_hammer2 (H2_NEWFS)" >&2; exit 2; }
[ -x "$FSCK" ] || { echo "tree: COULD-NOT-RUN: no fsck_hammer2 (H2_FSCK)" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "tree: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -d "$KDIR" ] || { echo "tree: COULD-NOT-RUN: no kernel tree at $KDIR" >&2; exit 2; }
for g in "$GUEST" "$DFLY"; do
	$VIRSH domstate "$g" >/dev/null 2>&1 || { echo "tree: COULD-NOT-RUN: no guest $g" >&2; exit 2; }
done
[ -z "$($VIRSH list --name | tr -d ' \n')" ] || {
	echo "tree: COULD-NOT-RUN: a guest is running: $($VIRSH list --name | tr '\n' ' ')" >&2; exit 2; }

make -s clean >/dev/null 2>&1
make -s KDIR="$KDIR" >/dev/null 2>&1 || {
	echo "tree: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko
built=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
[ -z "$(git status --porcelain -- src 2>/dev/null)" ] || built="$built-dirty"

rm -f "$IMG"
truncate -s "$SIZE" "$IMG" && "$NEWFS" -L ROOT "$IMG" >/dev/null 2>&1 || {
	echo "tree: COULD-NOT-RUN: newfs_hammer2 failed on $IMG" >&2; exit 2; }

fail=0
boot() {	# boot <guest> <ssh>; the image is attached first
	$VIRSH attach-disk "$1" "$IMG" vdb --targetbus virtio --config >/dev/null 2>&1
	$VIRSH start "$1" >/dev/null 2>&1 || { echo "  COULD-NOT-RUN  $1 did not start"; return 1; }
	n=0
	until ssh -o ConnectTimeout=3 -o BatchMode=yes "$2" true 2>/dev/null; do
		sleep 5; n=$((n + 1)); [ $n -gt 60 ] && { echo "  COULD-NOT-RUN  $1 did not answer ssh in 5 minutes, host load $(cut -d" " -f1-3 /proc/loadavg)"; return 1; }
	done
	return 0
}
down() {	# down <guest> <ssh>
	ssh -o ConnectTimeout=5 "$2" 'sync; poweroff' >/dev/null 2>&1
	n=0
	until [ "$($VIRSH domstate "$1")" = "shut off" ]; do
		sleep 3; n=$((n + 1)); [ $n -gt 60 ] && { $VIRSH destroy "$1" >/dev/null 2>&1; break; }
	done
	$VIRSH detach-disk "$1" vdb --config >/dev/null 2>&1
}

# 1. Linux writes the tree, syncs, unmounts, remounts and counts.
# Every file holds its own path, one line, so the tree is data as well as
# inodes and DragonFly can spot-check content. The shell writes with its
# own builtins, no process per file, so the rate is the driver's and not
# fork's. Times are whole seconds from date; the numbers are minutes.
per=$((N / FAN)); [ $per -gt 0 ] || per=1
cat > "$W/linux.sh" <<GUEST
dev=\$(ls /dev/vd? | tail -1); mkdir -p /mnt/tree
$GUESTPRE
rmmod hammer2 2>/dev/null; insmod /tmp/hammer2.ko $MODARGS || exit 1; dmesg -C
mem() { awk '/MemAvailable/{print \$2}' /proc/meminfo; }
mount -t hammer2 \$dev@ROOT /mnt/tree || { echo "mount failed"; exit 1; }
echo "memtotal \$(awk '/MemTotal/{print \$2}' /proc/meminfo) kB, kmemleak \$(echo stack=on > /sys/kernel/debug/kmemleak 2>/dev/null && echo on || echo off)"
echo "memavailable before \$(mem) kB"
echo "slab before \$(awk '/^Slab:/{print \$2}' /proc/meminfo) kB, unreclaimable \$(awk '/^SUnreclaim:/{print \$2}' /proc/meminfo) kB"
echo "debug_locks before \$(awk '/debug_locks:/{print \$2}' /proc/lockdep_stats)"
vm() { awk '/^(pgscan_direct|pgsteal_direct|pgscan_kswapd|pgsteal_kswapd|allocstall_normal|allocstall_movable|compact_stall|compact_fail|compact_success|nr_slab_unreclaimable|nr_file_pages|nr_dirty|workingset_refault_file) /{printf "%s=%s ", \$1, \$2}' /proc/vmstat; echo; }
echo "vmstat before \$(vm)"
t0=\$(date +%s)
d=0; n=0
while [ \$d -lt $FAN ] && [ \$n -lt $N ]; do
	mkdir /mnt/tree/d\$d || break
	i=0
	while [ \$i -lt $per ] && [ \$n -lt $N ]; do
		err=\$(echo "d\$d/f\$i" 2>&1 > /mnt/tree/d\$d/f\$i) || {
			echo "write refused at file \$n: \$err"
			# What reclaim did, read at the moment it mattered.
			echo "vmstat at refusal \$(vm)"
			echo "buddyinfo at refusal: \$(cat /proc/buddyinfo | tr -s ' ' | tr '\n' ';')"
			echo "top slabs at refusal: \$(awk 'NR>2{print \$1, \$3*\$4/1024}' /proc/slabinfo | sort -k2 -rn | head -6 | tr '\n' ';')"
			echo "inodes cached at refusal: \$(cut -d' ' -f1-2 /proc/sys/fs/inode-nr)"
			break 2; }
		i=\$((i + 1)); n=\$((n + 1))
	done
	d=\$((d + 1))
done
t1=\$(date +%s)
echo "created \$n files in \$d directories in \$((t1 - t0)) s"
echo "vmstat after create \$(vm)"
echo "nofs scope \$(cat /sys/module/hammer2/parameters/nofs_scope 2>/dev/null || echo unknown)"
echo "memavailable after create \$(mem) kB"
echo "slab after create \$(awk '/^Slab:/{print \$2}' /proc/meminfo) kB, unreclaimable \$(awk '/^SUnreclaim:/{print \$2}' /proc/meminfo) kB"
sync; t2=\$(date +%s)
echo "sync took \$((t2 - t1)) s"
echo "memavailable after sync \$(mem) kB"
echo "blocks used \$(stat -f -c '%b %a' /mnt/tree)"
umount /mnt/tree; s=\$?; t3=\$(date +%s)
echo "umount exit \$s in \$((t3 - t2)) s"
mount -t hammer2 \$dev@ROOT /mnt/tree || { echo "remount failed"; exit 1; }
echo 3 > /proc/sys/vm/drop_caches
t4=\$(date +%s)
c=\$(find /mnt/tree -type f | wc -l); t5=\$(date +%s)
echo "counted \$c files after remount, cold walk \$((t5 - t4)) s"
echo "memavailable after walk \$(mem) kB"
bad=0; k=0
while [ \$k -lt 200 ]; do
	dd=\$((k * 7919 % $FAN)); ff=\$((k * 104729 % $per))
	[ -f /mnt/tree/d\$dd/f\$ff ] && [ "\$(cat /mnt/tree/d\$dd/f\$ff)" = "d\$dd/f\$ff" ] || bad=\$((bad + 1))
	k=\$((k + 1))
done
echo "spot check 200 files, \$bad wrong"
umount /mnt/tree; echo "second umount exit \$?"
echo "debug_locks \$(awk '/debug_locks:/{print \$2}' /proc/lockdep_stats)"
# A lockdep ceiling is the guest kernel's configuration running out, not
# a report about the driver, and it reads as neither pass nor failure
# for the lock question; the host tells them apart by this line.
echo "lockdep ceiling \$(dmesg | grep -c 'BUG: MAX_LOCKDEP')"
# What turned lockdep off, when it is off: a ceiling prints no cut-here
# line and reads as nothing without this. The lockdep_stats counters
# say how close the run came even when it stayed on.
# The whole first report, not a grep of it: a lockdep report is the
# finding, and a dozen matched lines of one lose the two chains it
# names. A lockdep report prints no cut-here line, so the warning
# count below does not see it; this is what does.
dmesg | sed -n '/possible circular locking\|held lock freed\|MAX_LOCKDEP\|unlock balance\|possible recursive locking\|inconsistent lock state/,+160p' | head -170 | sed 's/^/lockdep: /'
grep -E 'lock-classes|direct dependencies|dependency chains|stack-trace entries' /proc/lockdep_stats | sed 's/^ */lockdep_stats: /'
echo "kmsg lines \$(dmesg | wc -l)"
echo "kernel warnings \$(dmesg | grep -c 'cut here\|page allocation failure')"
dmesg | grep -m1 -A30 'cut here\|page allocation failure' | head -32
rmmod hammer2; echo "rmmod exit \$?"
GUEST
echo "  built from $built, $N files under $FAN directories on a $SIZE volume"
boot "$GUEST" "$GUEST_SSH" || { down "$GUEST" "$GUEST_SSH"; exit 2; }
scp -q -o ConnectTimeout=5 "$KO" "$W/linux.sh" "$GUEST_SSH:/tmp/" || { echo "tree: COULD-NOT-RUN: scp failed" >&2; down "$GUEST" "$GUEST_SSH"; exit 2; }
out=$($RUN "$GUEST_SSH" 'sh /tmp/linux.sh' 2>&1); st=$?
printf '%s\n' "$out" | sed 's/^/  linux   /'
down "$GUEST" "$GUEST_SSH"
[ $st = 124 ] && { echo "  FAIL  the guest hung: the run exceeded ${H2_RUN_TIMEOUT:-3600}s"; fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q "^created $N files" || { echo "  FAIL  the tree was not created whole"; fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q "^counted $N files after remount" || { echo "  FAIL  the remount did not count every file"; fail=$((fail + 1)); }
for want in "^spot check 200 files, 0 wrong" "^umount exit 0 " "^second umount exit 0$" "^rmmod exit 0$" "^kmsg lines [1-9]" "^kernel warnings 0$"; do
	printf '%s\n' "$out" | grep -q "$want" || { echo "  FAIL  wanted $want"; fail=$((fail + 1)); }
done
if printf '%s\n' "$out" | grep -q "^debug_locks 0$"; then
	if printf '%s\n' "$out" | grep -q "^lockdep ceiling [1-9]"; then
		echo "  note  lockdep hit a ceiling of the guest kernel's configuration, so the"
		echo "        lock reading for this run is NOT available; not counted either way"
	else
		echo "  FAIL  lockdep turned itself off during the run"; fail=$((fail + 1))
	fi
fi
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "  ok    host fsck_hammer2 after linux" || { echo "  FAIL  host fsck_hammer2 after linux"; fail=$((fail + 1)); }
fsck_control "$IMG" || fail=$((fail + 1))

# 2. DragonFly counts the same tree and spot-checks content.
cat > "$W/dfly.sh" <<GUEST
mkdir -p /mnt/tree
mount_hammer2 /dev/vbd1@ROOT /mnt/tree || { echo "mount failed"; exit 1; }
t0=\$(date +%s)
c=\$(find /mnt/tree -type f | wc -l | tr -d ' '); t1=\$(date +%s)
echo "dragonfly counted \$c files, walk \$((t1 - t0)) s"
bad=0; k=0
while [ \$k -lt 200 ]; do
	dd=\$((k * 7919 % $FAN)); ff=\$((k * 104729 % $per))
	[ "\$(cat /mnt/tree/d\$dd/f\$ff)" = "d\$dd/f\$ff" ] || bad=\$((bad + 1))
	k=\$((k + 1))
done
echo "dragonfly spot check 200 files, \$bad wrong"
umount /mnt/tree
t2=\$(date +%s); fsck_hammer2 /dev/vbd1 >/dev/null 2>&1 && echo "dragonfly fsck clean in \$((\$(date +%s) - t2)) s"
GUEST
boot "$DFLY" "$DFLY_SSH" || { down "$DFLY" "$DFLY_SSH"; exit 2; }
scp -q -o ConnectTimeout=5 "$W/dfly.sh" "$DFLY_SSH:/tmp/" || { echo "tree: COULD-NOT-RUN: scp failed" >&2; down "$DFLY" "$DFLY_SSH"; exit 2; }
out=$($RUN "$DFLY_SSH" 'sh /tmp/dfly.sh' 2>&1)
[ $? = 124 ] && { echo "  FAIL  the guest hung: the run exceeded ${H2_RUN_TIMEOUT:-3600}s"; fail=$((fail + 1)); }
printf '%s\n' "$out" | sed 's/^/  dfly    /'
down "$DFLY" "$DFLY_SSH"
printf '%s\n' "$out" | grep -q "^dragonfly counted $N files" || { echo "  FAIL  DragonFly did not count every file"; fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q "^dragonfly spot check 200 files, 0 wrong" || { echo "  FAIL  DragonFly read wrong content"; fail=$((fail + 1)); }
printf '%s\n' "$out" | grep -q "^dragonfly fsck clean" || { echo "  FAIL  DragonFly's checker"; fail=$((fail + 1)); }
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "  ok    host fsck_hammer2 after dragonfly" || { echo "  FAIL  host fsck_hammer2 after dragonfly"; fail=$((fail + 1)); }
fsck_control "$IMG" || fail=$((fail + 1))

make -s clean >/dev/null 2>&1
echo "tree: $N files written here and counted on both sides, $fail failure(s)"
[ $fail = 0 ]
