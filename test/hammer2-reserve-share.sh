#!/bin/sh
# Whether the free-space reserve counts the dirty pages of every PFS that
# allocates on a device, run on the guest by script/test-enospc.sh with
# the module loaded. Two shapes, each on fresh volumes:
#
#   pfs      ROOT and P2 on one volume, each mounted. 1.0.107 fixed this:
#            each PFS superblock had its own bdi and counted only its own
#            pages, so both writes below were admitted and writeback lost
#            blocks of both files.
#   cluster  ROOT on each of two volumes and CL a MASTER on both, mounted
#            from the first. 1.0.108 fixed this: CL's pages sit on the
#            first device's bdi and allocate on both, and a PFS on the
#            second counted only the second's bdi; CL's file lost blocks.
#
# Each shape fills one volume through its ROOT until root's margin is
# near 4.3 times the reserve, then, as root, with dirty limits raised and
# clean caches dropped, writes X = free - 2R - 24 MiB through one PFS and
# X through the other, no sync between. One X fits under the margin and
# two do not, so the second write must be refused. The files are hashed
# from the page cache, synced, unmounted, the caches dropped, remounted
# and hashed again from the media.
#
# The window must hold up to the second write: if writeback allocated
# the first file's blocks before then, a refusal comes from the free count
# and says nothing about the dirty count. Three writers can do that, and
# each is shut out (inc7/window-probe-hold*-d533dda7.out, traced):
#
#   reclaim     wakes the flusher on a guest full of clean pages, as the
#               KASAN build did before the caches were dropped.
#   the flusher wakes five seconds after a bdi's first dirty page, and
#               writes in the background once the bdi's own dirty count
#               passes its share of the background threshold
#               (wb_over_bg_thresh()). A bdi with no writeout history
#               gets about an eighth of the global threshold, under one X,
#               so each bdi's min_ratio is set to 40 for the window: a
#               share of 640 MB, above the two X the unfixed module
#               leaves on one bdi, and the two bdis of the cluster stay
#               under the sum of 100 the kernel allows.
#   the syncer  hammer2_sync_work() runs sync_filesystem() every 30 s from
#               each PFS's mount, at a phase the fill leaves anywhere,
#               so the shape's mounts are remounted just before the
#               window and both writes end well inside its first 30 s.
#
# Every hammer2 bdi's BdiWritten is read before the first write and after
# it, and the host refuses a reading where it moved. Writeback during the
# second write is the check working, not leaking: a write whose dirty
# sum puts free under twice the reserve is made data-sync
# (hammer2_file_write_iter()), so it allocates as it goes and the
# refusal that follows reads a current free count. The unfixed module
# never counts the other PFS's pages, never reaches that line, and
# admits the second write whole.
#
# Prints lines beginning "multi <shape> "; the host judges them. Devices,
# found by the serials the host attached them with since the guest names
# hot-added disks in probe order: h2share-a and -b for the cluster, -c for
# the two PFS, each a fresh volume labelled ROOT.
set -u
TARGET=431048619 MLO=410000000 MHI=452000000
h1='' h2='' clid=''
db=$(sysctl -n vm.dirty_background_bytes) dbr=$(sysctl -n vm.dirty_background_ratio)
dy=$(sysctl -n vm.dirty_bytes) dyr=$(sysctl -n vm.dirty_ratio)
cleanup() {
	cd /
	for m in /mnt/h2mq /mnt/h2mp /mnt/h2ma /mnt/h2mb /mnt/h2mc; do
		umount $m 2>/dev/null
	done
	if [ "$db" = 0 ]; then sysctl -qw vm.dirty_background_ratio=$dbr; else sysctl -qw vm.dirty_background_bytes=$db; fi
	if [ "$dy" = 0 ]; then sysctl -qw vm.dirty_ratio=$dyr; else sysctl -qw vm.dirty_bytes=$dy; fi
}
trap cleanup EXIT
mount -t debugfs none /sys/kernel/debug 2>/dev/null
mkdir -p /mnt/h2ma /mnt/h2mb /mnt/h2mc /mnt/h2mq /mnt/h2mp
for d in a b c; do
	n=0
	while [ ! -b /dev/disk/by-id/virtio-h2share-$d ] && [ $n -lt 30 ]; do sleep 1; n=$((n + 1)); done
	[ -b /dev/disk/by-id/virtio-h2share-$d ] || { echo "multi setup VOID no disk with serial h2share-$d"; exit 0; }
done
A=$(readlink -f /dev/disk/by-id/virtio-h2share-a)
B=$(readlink -f /dev/disk/by-id/virtio-h2share-b)
C=$(readlink -f /dev/disk/by-id/virtio-h2share-c)

# Root's margin on a mount, free and reserve, from statfs: f_bfree is the
# free count and f_bavail the free count less the whole reserve.
margin() {
	set -- $(stat -f -c "%f %a %S" "$1")
	f=$(($1 * $3)) r=$((($1 - $2) * $3))
	echo $((f - r / 2)) $f $r
}
written() {
	t=0
	for s in /sys/kernel/debug/bdi/hammer2-*/stats; do
		[ -r "$s" ] || continue
		t=$((t + $(sed -n "s/^BdiWritten: *\([0-9]*\) kB/\1/p" "$s")))
	done
	echo $t
}
# Not judged: each bdi's written count, the filled volume's free blocks,
# and the page and reclaim counters, for reading a window that did not
# hold.
wdiag() {
	for s in /sys/kernel/debug/bdi/hammer2-*/stats; do
		[ -r "$s" ] || continue
		d=${s%/stats}
		printf "%s %s/%s/%s " "${d##*/}" \
		    "$(sed -n "s/^BdiWritten: *\([0-9]*\) kB/\1/p" "$s")" \
		    "$(sed -n "s/^BdiDirtied: *\([0-9]*\) kB/\1/p" "$s")" \
		    "$(sed -n "s/^BdiWriteback: *\([0-9]*\) kB/\1/p" "$s")"
	done
	printf "avail %s " "$(stat -f -c %a "$1")"
	awk "/^(nr_dirty|nr_writeback|pgscan_kswapd|pgscan_direct) / {printf \"%s %s \", \$1, \$2}" /proc/vmstat
	awk "/^MemFree:/ {print \"MemFree\", \$2}" /proc/meminfo
}
# Every hammer2 bdi's min_ratio set to $1, read back; fails on none found
# or one that did not take, since a write the kernel refuses past the sum
# of 100 is accepted by the shell either way.
ratio() {
	n=0
	for r in /sys/class/bdi/hammer2-*/min_ratio; do
		[ -e "$r" ] || continue
		echo "$1" > "$r" 2>/dev/null
		[ "$(cat "$r")" = "$1" ] || return 1
		n=$((n + 1))
	done
	[ $n -gt 0 ]
}
remount_cluster() {
	umount /mnt/h2mq; umount /mnt/h2mb; umount /mnt/h2ma
	echo 3 > /proc/sys/vm/drop_caches
	mount -t hammer2 $A@ROOT /mnt/h2ma && mount -t hammer2 $B@ROOT /mnt/h2mb &&
	    mount -t hammer2 $A@CL /mnt/h2mq
}
remount_pfs() {
	umount /mnt/h2mp; umount /mnt/h2mc
	echo 3 > /proc/sys/vm/drop_caches
	mount -t hammer2 $C@ROOT /mnt/h2mc && mount -t hammer2 $C@P2 /mnt/h2mp
}
ddw() {
	o=$(dd if=/dev/urandom of="$1" bs=64k count=$2 2>&1)
	b=$(echo "$o" | sed -n "s/^\([0-9]*\) bytes.*/\1/p")
	echo "${b:-0} $(echo "$o" | grep -qi "no space" && echo ENOSPC || echo ok)"
}

# shape name fill-mount first-file second-file remount-command
shape() {
	name=$1 fm=$2 f1=$3 f2=$4 remount=$5
	set -- $(margin "$fm"); m=$1
	i=0
	while [ $i -lt 30 ] && [ "$m" -gt "$MHI" ]; do
		n=$(( (m - TARGET) / 2 / 65536 )); [ $n -lt 1 ] && n=1
		dd if=/dev/urandom of="$fm/fill.$i" bs=64k count=$n status=none 2>/dev/null
		sync
		i=$((i + 1)); set -- $(margin "$fm"); m=$1
	done
	set -- $(margin "$fm"); m=$1 free=$2 res=$3
	if [ "$m" -lt "$MLO" ] || [ "$m" -gt "$MHI" ]; then
		echo "multi $name VOID margin $m after $i fill steps, outside $MLO to $MHI"
		return
	fi
	x=$(( (free - 2 * res - 25165824) / 65536 ))
	sysctl -qw vm.dirty_background_bytes=1600000000 vm.dirty_bytes=2400000000
	$remount || { echo "multi $name VOID remount failed"; return; }
	ratio 40 || { echo "multi $name VOID min_ratio 40 did not take"; return; }
	sync; echo 3 > /proc/sys/vm/drop_caches
	w0=$(written)
	echo "multi $name window go: $(wdiag "$fm")"
	set -- $(ddw "$f1" $x); b1=$1 e1=$2
	w1=$(written)
	echo "multi $name window first: $(wdiag "$fm")"
	set -- $(ddw "$f2" $x); b2=$1 e2=$2
	echo "multi $name window second: $(wdiag "$fm")"
	echo "multi $name RESULT margin $m free $free reserve $res X $((x * 65536)) first $b1 $e1 second $b2 $e2 written-before-second $((w1 - w0)) kB"
	h1=$(sha256sum "$f1" "$f2" 2>/dev/null | cut -d" " -f1)
	sync
	ratio 0
}

# The cluster: A and B, CL a MASTER on both, mounted from A; B's
# ROOT is filled, so CL's free count is vdd's.
mount -t hammer2 $A@ROOT /mnt/h2ma &&
    hammer2 -s /mnt/h2ma pfs-create CL >/dev/null 2>&1 &&
    clid=$(hammer2 -s /mnt/h2ma pfs-clid CL 2>/dev/null) &&
    mount -t hammer2 $B@ROOT /mnt/h2mb &&
    hammer2 -s /mnt/h2mb -t MASTER -u "$clid" pfs-create CL >/dev/null 2>&1 &&
    mount -t hammer2 $A@CL /mnt/h2mq ||
    { echo "multi cluster VOID setup failed"; clid=; }
if [ -n "$clid" ]; then
	shape cluster /mnt/h2mb /mnt/h2mq/w1 /mnt/h2mb/w2 remount_cluster
	remount_cluster &&
	    h2=$(sha256sum /mnt/h2mq/w1 /mnt/h2mb/w2 2>/dev/null | cut -d" " -f1)
	echo "multi cluster hashes $(echo "$h1" | grep -c .) before, $(echo "${h2:-}" | grep -c .) read back, $( [ "$h1" = "${h2:-}" ] && echo same || echo differ)"
	umount /mnt/h2mq; umount /mnt/h2mb; umount /mnt/h2ma
fi

# Two PFS on one volume: C's ROOT and P2, ROOT filled.
h1='' h2=''
mount -t hammer2 $C@ROOT /mnt/h2mc &&
    hammer2 -s /mnt/h2mc pfs-create P2 >/dev/null 2>&1 &&
    mount -t hammer2 $C@P2 /mnt/h2mp ||
    { echo "multi pfs VOID setup failed"; exit 0; }
shape pfs /mnt/h2mc /mnt/h2mp/w1 /mnt/h2mc/w2 remount_pfs
remount_pfs &&
    h2=$(sha256sum /mnt/h2mp/w1 /mnt/h2mc/w2 2>/dev/null | cut -d" " -f1)
echo "multi pfs hashes $(echo "$h1" | grep -c .) before, $(echo "${h2:-}" | grep -c .) read back, $( [ "$h1" = "${h2:-}" ] && echo same || echo differ)"
