#!/bin/sh
# A real Nix closure through the port, read cold beside squashfs and erofs.
# 0.9's first criterion: F6, a Nix closure of hundreds of thousands of
# paths, reads at a measured cost recorded beside the same read on
# squashfs or erofs. The closure is one the host's Nix store already
# holds, named by its top-level store path in H2_CLOSURE, and its paths
# go into a squashfs image and an erofs image here, cached by the store
# hash, since a closure is immutable. The Linux guest mounts both beside
# an empty HAMMER2 volume, copies the closure from the squashfs into the
# volume through the write path with cp -a, so hard links, symlinks and
# modes travel, syncs, unmounts, remounts, and then takes the same three
# cold readings on each of the three filesystems with the page cache
# dropped between: a metadata walk, a full read, and a hashed read that
# is also the content check, every file's SHA-256 in path order compared
# between the copy and its source. DragonFly mounts the volume, counts
# it and runs its checker. Rates are printed, never judged; a run fails
# on a count or hash that differs, a kernel warning, a checker verdict
# or a missing reading.
#
# Exit 2 without the two guests, the tools, a kernel tree or a closure.
# Not a gate. One guest at a time.
#
#   H2_CLOSURE      the top-level store path, required; its closure is the tree
#   H2_MKEROFS      mkfs.erofs; without it the erofs reference is skipped, said so
#   H2_NC_EXT4      0 skips the ext4 reference copy, the same cp -a into ext4 on
#                   a fifth disk, which is what decides the XOP pool question
#   H2_NC_JOBS      writers copying the closure in at once, default 1; the store
#                   paths are dealt round the writers, 0.9's parallel-build row
#   H2_NC_GC        0 skips the collection: every other store path removed while
#                   a reader walks the rest, what remains hashed and counted on
#                   both sides, 0.9's garbage collection row
#   H2_NC_MODARGS   module parameters for the guest's insmod
#   H2_NC_GUESTPRE  run on the guest before insmod, for a control
#                   (echo off > /sys/kernel/debug/kmemleak)
#   H2_CLOSURE_DMESG where the guest's whole dmesg is saved
#   KDIR            the kernel of record's build tree, required
set -u
if [ -z "${H2_NC_COPY:-}" ]; then
	cd "$(dirname "$0")/.." || exit 2
	c=$(mktemp) || exit 2
	cp "$0" "$c" || exit 2
	H2_NC_COPY=$c exec sh "$c" "$@"
fi
trap 'rm -f "$H2_NC_COPY"' EXIT

FIXDIR=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}
CLOSURE=${H2_CLOSURE:-}
SIZE=${H2_NC_SIZE:-48G}
MODARGS=${H2_NC_MODARGS:-}
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
DFLY=${H2_DFLY_GUEST:-dragonflybsd642}
DFLY_SSH=${H2_DFLY_SSH:-root@192.168.122.42}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
UTILS=$HOME/Projects/hammer2-utils-upstream/target/release
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$UTILS/newfs_hammer2")}
FSCK=${H2_FSCK:-$(command -v fsck_hammer2 2>/dev/null || echo "$UTILS/fsck_hammer2")}
MKEROFS=${H2_MKEROFS:-$(command -v mkfs.erofs 2>/dev/null || true)}
GUESTPRE=${H2_NC_GUESTPRE:-:}
ext4=${H2_NC_EXT4:-1}; command -v mkfs.ext4 >/dev/null 2>&1 || ext4=0
gc=${H2_NC_GC:-1}
jobs=${H2_NC_JOBS:-1}
W=$(mktemp -d) || exit 2
# Twelve gigabytes through a debug kernel on a 4 GiB guest is hours of
# work, not minutes, so the bound is two of them.
RUN="timeout ${H2_RUN_TIMEOUT:-7200} ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
trap 'rm -rf "$W" "$H2_NC_COPY"' EXIT

command -v virsh >/dev/null 2>&1 || { echo "closure: COULD-NOT-RUN: no virsh" >&2; exit 2; }
command -v nix >/dev/null 2>&1 || { echo "closure: COULD-NOT-RUN: no nix" >&2; exit 2; }
command -v mksquashfs >/dev/null 2>&1 || { echo "closure: COULD-NOT-RUN: no mksquashfs" >&2; exit 2; }
[ -x "$NEWFS" ] || { echo "closure: COULD-NOT-RUN: no newfs_hammer2 (H2_NEWFS)" >&2; exit 2; }
[ -x "$FSCK" ] || { echo "closure: COULD-NOT-RUN: no fsck_hammer2 (H2_FSCK)" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "closure: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -d "$KDIR" ] || { echo "closure: COULD-NOT-RUN: no kernel tree at $KDIR" >&2; exit 2; }
[ -n "$CLOSURE" ] && [ -e "$CLOSURE" ] || {
	echo "closure: COULD-NOT-RUN: H2_CLOSURE must name a store path that exists" >&2; exit 2; }
for g in "$GUEST" "$DFLY"; do
	$VIRSH domstate "$g" >/dev/null 2>&1 || { echo "closure: COULD-NOT-RUN: no guest $g" >&2; exit 2; }
done
[ -z "$($VIRSH list --name | tr -d ' \n')" ] || {
	echo "closure: COULD-NOT-RUN: a guest is running: $($VIRSH list --name | tr '\n' ' ')" >&2; exit 2; }

make -s clean >/dev/null 2>&1
make -s KDIR="$KDIR" >/dev/null 2>&1 || {
	echo "closure: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko
built=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
[ -z "$(git status --porcelain -- src 2>/dev/null)" ] || built="$built-dirty"

# The closure, and the two reference images, named by the store hash so
# a second run finds them. Every store path is a root of the image, which
# is the layout of a store, and paths inside the images are what they are
# in /nix/store, so a symlink's target compares as text on both sides.
hash=$(basename "$CLOSURE" | cut -c1-32)
nix path-info -r "$CLOSURE" > "$W/paths" 2>/dev/null || {
	echo "closure: COULD-NOT-RUN: nix path-info failed on $CLOSURE" >&2; exit 2; }
npaths=$(wc -l < "$W/paths")
[ "$npaths" -gt 0 ] || { echo "closure: COULD-NOT-RUN: the closure is empty" >&2; exit 2; }
SQ=$FIXDIR/closure-$hash.squashfs
ER=$FIXDIR/closure-$hash.erofs
IMG=$FIXDIR/closure-$hash.img
if [ ! -s "$SQ" ]; then
	# shellcheck disable=SC2046
	mksquashfs $(tr '\n' ' ' < "$W/paths") "$SQ" -noappend -comp zstd -no-progress -quiet >/dev/null 2>&1 || {
		echo "closure: COULD-NOT-RUN: mksquashfs failed" >&2; rm -f "$SQ"; exit 2; }
fi
erofs=1
if [ -z "$MKEROFS" ] || [ ! -x "$MKEROFS" ]; then
	erofs=0
elif [ ! -s "$ER" ]; then
	# mkfs.erofs takes one source tree or a tarball, so the roots go in
	# as a tar stream, which keeps their hard links and modes as cp -a
	# will keep them on the way into the volume.
	store=$(dirname "$(head -1 "$W/paths")")
	# shellcheck disable=SC2046
	if ! tar -cf - -C "$store" $(sed 's,.*/,,' "$W/paths" | tr '\n' ' ') | "$MKEROFS" --tar=f --quiet --workers=6 -zzstd -L closure "$ER" /dev/stdin >/dev/null 2>&1; then
		echo "closure: COULD-NOT-RUN: mkfs.erofs failed" >&2; rm -f "$ER"; exit 2
	fi
fi
rm -f "$IMG"
truncate -s "$SIZE" "$IMG" && "$NEWFS" -L ROOT "$IMG" >/dev/null 2>&1 || {
	echo "closure: COULD-NOT-RUN: newfs_hammer2 failed on $IMG" >&2; exit 2; }
EXT4=$FIXDIR/closure-ext4.img
if [ $ext4 = 1 ]; then
	rm -f "$EXT4"
	truncate -s "$SIZE" "$EXT4" && mkfs.ext4 -q -F "$EXT4" >/dev/null 2>&1 || {
		echo "closure: COULD-NOT-RUN: mkfs.ext4 failed on $EXT4" >&2; exit 2; }
fi

fail=0
boot() {	# boot <guest> <ssh> [squashfs] [erofs] [ext4]; the images are attached first
	$VIRSH attach-disk "$1" "$IMG" vdb --targetbus virtio --config >/dev/null 2>&1
	[ -n "${3:-}" ] && $VIRSH attach-disk "$1" "$3" vdc --targetbus virtio --config >/dev/null 2>&1
	[ -n "${4:-}" ] && $VIRSH attach-disk "$1" "$4" vdd --targetbus virtio --config >/dev/null 2>&1
	[ -n "${5:-}" ] && $VIRSH attach-disk "$1" "$5" vde --targetbus virtio --config >/dev/null 2>&1
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
	$VIRSH detach-disk "$1" vdc --config >/dev/null 2>&1
	$VIRSH detach-disk "$1" vdd --config >/dev/null 2>&1
	$VIRSH detach-disk "$1" vde --config >/dev/null 2>&1
}
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

# 1. Linux copies the closure in and reads all three cold.
# Times are whole seconds from date; the sizes are gigabytes.
fslist="h2 sq"; [ $erofs = 1 ] && fslist="h2 sq er"; [ $ext4 = 1 ] && fslist="$fslist ex"
# The guest names its disks in attach order, so the ext4 image is the
# fourth disk when no erofs image sits between it and the squashfs.
exdev=/dev/vdd; [ $erofs = 1 ] && exdev=/dev/vde
cat > "$W/linux.sh" <<GUEST
set -u
trap 'dmesg > /tmp/closure-dmesg.txt' EXIT
$GUESTPRE
rmmod hammer2 2>/dev/null; insmod /tmp/hammer2.ko $MODARGS || exit 1; dmesg -C
modprobe squashfs || { echo "no squashfs in the guest kernel"; exit 3; }
mkdir -p /mnt/h2 /mnt/sq /mnt/er
mount -t squashfs -o ro /dev/vdc /mnt/sq || { echo "squashfs mount failed"; exit 1; }
if [ $erofs = 1 ]; then
	modprobe erofs || { echo "no erofs in the guest kernel"; exit 3; }
	mount -t erofs -o ro /dev/vdd /mnt/er || { echo "erofs mount failed"; exit 1; }
fi
mount -t hammer2 /dev/vdb@ROOT /mnt/h2 || { echo "hammer2 mount failed"; exit 1; }
mem() { awk '/MemAvailable/{print \$2}' /proc/meminfo; }
echo "memtotal \$(awk '/MemTotal/{print \$2}' /proc/meminfo) kB"
echo "memavailable before \$(mem) kB"
echo "debug_locks before \$(awk '/debug_locks:/{print \$2}' /proc/lockdep_stats)"
echo "source \$(find /mnt/sq -type f | wc -l) files, \$(find /mnt/sq -type l | wc -l) symlinks, \$(find /mnt/sq -type d | wc -l) directories, \$(du -sb /mnt/sq | cut -f1) bytes"
sync; echo 3 > /proc/sys/vm/drop_caches
if [ $jobs = 1 ]; then
	t0=\$(date +%s); cp -a /mnt/sq/. /mnt/h2/; cpst=\$?; t1=\$(date +%s)
else
	# The store paths dealt round the writers, each cp -a its own set, so
	# every writer creates under the one root directory at once.
	ls /mnt/sq > /tmp/paths; t0=\$(date +%s); cpst=0
	j=0; pids=""; while [ \$j -lt $jobs ]; do
		(cd /mnt/sq && awk -v j=\$j -v n=$jobs 'NR % n == j' /tmp/paths | xargs cp -a -t /mnt/h2/) &
		pids="\$pids \$!"; j=\$((j + 1))
	done
	for pid in \$pids; do wait \$pid || cpst=1; done
	t1=\$(date +%s)
fi
echo "cp -a exit \$cpst in \$((t1 - t0)) s"
sync; t2=\$(date +%s); echo "sync took \$((t2 - t1)) s"
echo "memavailable after copy \$(mem) kB"
echo "slab after copy \$(awk '/^Slab:/{print \$2}' /proc/meminfo) kB"
umount /mnt/h2; echo "umount exit \$? in \$((\$(date +%s) - t2)) s"
mount -t hammer2 /dev/vdb@ROOT /mnt/h2 || { echo "hammer2 remount failed"; exit 1; }
echo "blocks \$(df -k /mnt/h2 | awk 'NR==2{print \$2, \$3}')"
if [ $ext4 = 1 ]; then
	mkdir -p /mnt/ex
	mount -t ext4 $exdev /mnt/ex || { echo "ext4 mount failed"; exit 1; }
	sync; echo 3 > /proc/sys/vm/drop_caches
	t0=\$(date +%s); cp -a /mnt/sq/. /mnt/ex/; exst=\$?; t1=\$(date +%s)
	echo "ext4 cp -a exit \$exst in \$((t1 - t0)) s"
	sync; t2=\$(date +%s); echo "ext4 sync took \$((t2 - t1)) s"
	umount /mnt/ex; echo "ext4 umount exit \$? in \$((\$(date +%s) - t2)) s"
	mount -t ext4 $exdev /mnt/ex || { echo "ext4 remount failed"; exit 1; }
fi
for fs in $fslist; do
	sync; echo 3 > /proc/sys/vm/drop_caches
	t0=\$(date +%s); n=\$(find /mnt/\$fs | wc -l); t1=\$(date +%s)
	echo "\$fs walk \$n entries in \$((t1 - t0)) s"
	sync; echo 3 > /proc/sys/vm/drop_caches
	t0=\$(date +%s); tar -cf /dev/null -C /mnt/\$fs . 2>/dev/null; t1=\$(date +%s)
	echo "\$fs read in \$((t1 - t0)) s"
	sync; echo 3 > /proc/sys/vm/drop_caches
	t0=\$(date +%s)
	(cd /mnt/\$fs && find . -type f -print0 | sort -z | xargs -0 sha256sum) > /tmp/sum.\$fs; t1=\$(date +%s)
	echo "\$fs hashed \$(wc -l < /tmp/sum.\$fs) files in \$((t1 - t0)) s, list \$(sha256sum < /tmp/sum.\$fs | cut -c1-16)"
	(cd /mnt/\$fs && find . -type l -printf '%p %l\n' | sort) > /tmp/links.\$fs
	echo "\$fs symlinks \$(wc -l < /tmp/links.\$fs), list \$(sha256sum < /tmp/links.\$fs | cut -c1-16)"
	echo "\$fs hardlinked \$(find /mnt/\$fs -type f -links +1 | wc -l)"
done
# Which entries differ, bounded, so a refused write and a wrong target
# are told apart without a second run.
diff /tmp/sum.sq /tmp/sum.h2 | grep '^[<>]' | head -20 | sed 's/^/hash differs /'
diff /tmp/links.sq /tmp/links.h2 | grep '^[<>]' | head -20 | sed 's/^/symlink differs /'
echo "memavailable after reads \$(mem) kB"
if [ $gc = 1 ]; then
	# Store garbage collection: every other store path goes while a
	# reader walks the ones that stay, then what stays is hashed against
	# its source and counted, and the count is what DragonFly must see.
	ls /mnt/h2 | awk 'NR % 2 == 0' > /tmp/gc.go; ls /mnt/h2 | awk 'NR % 2 == 1' > /tmp/gc.stay
	ntop=\$(ls /mnt/h2 | wc -l)
	(cd /mnt/h2 && tar -cf /dev/null \$(cat /tmp/gc.stay) 2>/dev/null; echo "gc reader exit \$?") &
	t0=\$(date +%s); (cd /mnt/h2 && xargs rm -rf < /tmp/gc.go); rmst=\$?; t1=\$(date +%s)
	wait
	echo "gc removed \$(wc -l < /tmp/gc.go) of \$ntop store paths in \$((t1 - t0)) s, rm exit \$rmst"
	sync; echo "gc sync took \$((\$(date +%s) - t1)) s"
	(cd /mnt/h2 && find . -type f -print0 | sort -z | xargs -0 sha256sum) > /tmp/sum.gc
	# A store path is a directory or one file; the first component after
	# ./ names it either way.
	awk 'NR == FNR { stay[\$0] = 1; next } { p = \$0; sub(/^[^ ]*  \.\//, "", p); sub(/\/.*/, "", p); if (p in stay) print }' /tmp/gc.stay /tmp/sum.sq > /tmp/sum.sq.stay
	echo "gc left \$(wc -l < /tmp/sum.gc) files, \$(find /mnt/h2 -type l | wc -l) symlinks, list \$(sha256sum < /tmp/sum.gc | cut -c1-16), source's \$(sha256sum < /tmp/sum.sq.stay | cut -c1-16)"
	diff /tmp/sum.sq.stay /tmp/sum.gc | grep '^[<>]' | head -20 | sed 's/^/gc differs /'
fi
umount /mnt/h2; echo "second umount exit \$?"
umount /mnt/sq; [ $erofs = 1 ] && umount /mnt/er
echo "debug_locks \$(awk '/debug_locks:/{print \$2}' /proc/lockdep_stats)"
echo "lockdep ceiling \$(dmesg | grep -c 'MAX_LOCKDEP')"
echo "kernel warnings \$(dmesg | grep -c 'cut here\|page allocation failure')"
dmesg | grep -n 'cut here\|page allocation failure\|MAX_LOCKDEP\|lockdep is turned off\|^\[.*\] WARNING:\|BUG:' | sed 's/^/warning at /'
dmesg | grep -m1 -A30 'cut here\|page allocation failure' | head -32
dmesg > /tmp/closure-dmesg.txt
rmmod hammer2; echo "rmmod exit \$?"
GUEST
echo "  built from $built, $npaths store paths from $(basename "$CLOSURE") on a $SIZE volume, erofs $erofs, ext4 $ext4, writers $jobs"
er_arg=""; [ $erofs = 1 ] && er_arg=$ER
ex_arg=""; [ $ext4 = 1 ] && ex_arg=$EXT4
boot "$GUEST" "$GUEST_SSH" "$SQ" "$er_arg" "$ex_arg" || { down "$GUEST" "$GUEST_SSH"; exit 2; }
scp -q -o ConnectTimeout=5 "$KO" "$W/linux.sh" "$GUEST_SSH:/tmp/" || { echo "closure: COULD-NOT-RUN: scp failed" >&2; down "$GUEST" "$GUEST_SSH"; exit 2; }
out=$($RUN "$GUEST_SSH" 'sh /tmp/linux.sh' 2>&1); st=$?
printf '%s\n' "$out" | sed 's/^/  linux   /'
# The whole guest log, since the run prints one warning and a second
# one is what says why lockdep went off.
DMESG=${H2_CLOSURE_DMESG:-$W/guest-dmesg.txt}
scp -q -o ConnectTimeout=5 "$GUEST_SSH:/tmp/closure-dmesg.txt" "$DMESG" 2>/dev/null && echo "  linux   dmesg saved to $DMESG"
if [ $st = 124 ]; then
	echo "  FAIL  the guest hung: the run exceeded ${H2_RUN_TIMEOUT:-7200}s"; fail=$((fail + 1))
	sh "$(dirname "$0")/guest-dmesg.sh" "$GUEST" 2>&1 | sed 's/^/  hang    /'
	$VIRSH destroy "$GUEST" >/dev/null 2>&1
fi
down "$GUEST" "$GUEST_SSH"
[ $st = 3 ] && { echo "closure: COULD-NOT-RUN: the guest kernel has no squashfs or erofs module" >&2; exit 2; }
h2sum=$(printf '%s\n' "$out" | sed -n 's/^h2 hashed .* list //p')
sqsum=$(printf '%s\n' "$out" | sed -n 's/^sq hashed .* list //p')
if [ -n "$h2sum" ] && [ "$h2sum" = "$sqsum" ]; then
	echo "  ok    every file in the copy hashes as its source, in the same order"
else
	echo "  FAIL  the copy's hash list '$h2sum' is not the source's '$sqsum'"; fail=$((fail + 1))
fi
h2l=$(printf '%s\n' "$out" | sed -n 's/^h2 symlinks .* list //p')
sql=$(printf '%s\n' "$out" | sed -n 's/^sq symlinks .* list //p')
[ -n "$h2l" ] && [ "$h2l" = "$sql" ] && echo "  ok    every symlink in the copy has its source's target" || {
	echo "  FAIL  the symlink lists differ"; fail=$((fail + 1)); }
h2h=$(printf '%s\n' "$out" | sed -n 's/^h2 hardlinked //p'); sqh=$(printf '%s\n' "$out" | sed -n 's/^sq hardlinked //p')
if [ $jobs != 1 ]; then
	echo "  note  $h2h hard-linked files against the source's $sqh: a link across two writers' shares is two files, not counted"
elif [ -n "$h2h" ] && [ "$h2h" = "$sqh" ]; then
	echo "  ok    $h2h hard-linked files on both"
else
	echo "  FAIL  hard-linked files: copy $h2h, source $sqh"; fail=$((fail + 1))
fi
nfiles=$(printf '%s\n' "$out" | sed -n 's/^source \([0-9]*\) files.*/\1/p')
for want in "^cp -a exit 0 in [0-9]* s" "^umount exit 0 " "^second umount exit 0$" "^rmmod exit 0$" "^kernel warnings 0$" "^h2 walk [1-9][0-9]* entries" "^sq walk [1-9][0-9]* entries" "^h2 read in [0-9]* s" "^sq read in [0-9]* s"; do
	printf '%s\n' "$out" | grep -q "$want" || { echo "  FAIL  wanted $want"; fail=$((fail + 1)); }
done
if [ $erofs = 1 ]; then
	for want in "^er walk [1-9][0-9]* entries" "^er read in [0-9]* s"; do
		printf '%s\n' "$out" | grep -q "$want" || { echo "  FAIL  wanted $want"; fail=$((fail + 1)); }
	done
else
	echo "  note  no erofs reference: mkfs.erofs was not found (H2_MKEROFS)"
fi
if [ $ext4 = 1 ]; then
	for want in "^ext4 cp -a exit 0 in [0-9]* s" "^ext4 umount exit 0 " "^ex walk [1-9][0-9]* entries" "^ex read in [0-9]* s"; do
		printf '%s\n' "$out" | grep -q "$want" || { echo "  FAIL  wanted $want"; fail=$((fail + 1)); }
	done
else
	echo "  note  no ext4 reference copy (H2_NC_EXT4)"
fi
if [ $gc = 1 ]; then
	gcl=$(printf '%s\n' "$out" | sed -n 's/^gc left .* list \([0-9a-f]*\), source.s \([0-9a-f]*\)$/\1 \2/p')
	if [ -n "$gcl" ] && [ "${gcl%% *}" = "${gcl##* }" ]; then
		echo "  ok    what the collection kept hashes as its source"
	else
		echo "  FAIL  the collection's survivors do not hash as their source: '$gcl'"; fail=$((fail + 1))
	fi
	printf '%s\n' "$out" | grep -q "^gc removed [1-9][0-9]* of [0-9]* store paths in [0-9]* s, rm exit 0$" || { echo "  FAIL  wanted a clean gc removal line"; fail=$((fail + 1)); }
	printf '%s\n' "$out" | grep -q "^gc reader exit 0$" || { echo "  FAIL  the reader beside the collection did not exit 0"; fail=$((fail + 1)); }
	nfiles=$(printf '%s\n' "$out" | sed -n 's/^gc left \([0-9]*\) files.*/\1/p')
	[ -n "$nfiles" ] || { echo "  FAIL  no gc count"; fail=$((fail + 1)); nfiles=-1; }
fi
printf '%s\n' "$out" | grep -q "^debug_locks 1$" || echo "  note  lockdep was off at the end of the run, so its silence is not a reading"
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "  ok    host fsck_hammer2 after linux" || { echo "  FAIL  host fsck_hammer2 after linux"; fail=$((fail + 1)); }
fsck_control "$IMG" || fail=$((fail + 1))

# 2. DragonFly counts the same volume and runs its checker.
cat > "$W/dfly.sh" <<GUEST
mkdir -p /mnt/nc
mount_hammer2 /dev/vbd1@ROOT /mnt/nc || { echo "mount failed"; exit 1; }
t0=\$(date +%s)
echo "dragonfly counted \$(find /mnt/nc -type f | wc -l | tr -d ' ') files, \$(find /mnt/nc -type l | wc -l | tr -d ' ') symlinks, walk \$((\$(date +%s) - t0)) s"
umount /mnt/nc; echo "dragonfly umount exit \$?"
t1=\$(date +%s); fsck_hammer2 /dev/vbd1 >/dev/null 2>&1 && echo "dragonfly fsck clean in \$((\$(date +%s) - t1)) s"
GUEST
boot "$DFLY" "$DFLY_SSH" || { down "$DFLY" "$DFLY_SSH"; exit 2; }
scp -q -o ConnectTimeout=5 "$W/dfly.sh" "$DFLY_SSH:/tmp/" || { echo "closure: COULD-NOT-RUN: scp failed" >&2; down "$DFLY" "$DFLY_SSH"; exit 2; }
dout=$($RUN "$DFLY_SSH" 'sh /tmp/dfly.sh' 2>&1); st=$?
[ $st = 124 ] && { echo "  FAIL  the guest hung: the run exceeded ${H2_RUN_TIMEOUT:-7200}s"; fail=$((fail + 1)); }
printf '%s\n' "$dout" | sed 's/^/  dfly    /'
down "$DFLY" "$DFLY_SSH"
printf '%s\n' "$dout" | grep -q "^dragonfly counted $nfiles files" || { echo "  FAIL  DragonFly did not count $nfiles files"; fail=$((fail + 1)); }
printf '%s\n' "$dout" | grep -q "^dragonfly umount exit 0$" || { echo "  FAIL  DragonFly unmount"; fail=$((fail + 1)); }
printf '%s\n' "$dout" | grep -q "^dragonfly fsck clean" || { echo "  FAIL  DragonFly's checker"; fail=$((fail + 1)); }
"$FSCK" "$IMG" >/dev/null 2>&1 && echo "  ok    host fsck_hammer2 after dragonfly" || { echo "  FAIL  host fsck_hammer2 after dragonfly"; fail=$((fail + 1)); }
fsck_control "$IMG" || fail=$((fail + 1))

make -s clean >/dev/null 2>&1
echo "closure: $npaths store paths, copied in and read cold on both sides, $nfiles files after the collection, $fail failure(s)"
[ $fail = 0 ]
