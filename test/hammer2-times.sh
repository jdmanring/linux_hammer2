#!/bin/sh
# Every time stat shows on a HAMMER2 mount must be the time a remount
# reads back from the media.  Run on the guest as root, with the module to
# load and a scratch HAMMER2 device: sh test/hammer2-times.sh <ko> <dev>.
# A FAKE PASS is an object whose times the run never moved, so each one
# is stamped by a different operation: create, write, chmod, truncate(2)
# by path, ftruncate(2), link, unlink, rename, mkfifo and mknod.
# Measured 2026-10-17 on h2debug-rc5: 10 of 13 objects moved on the module
# before the fix and 0 of 13 in three runs after; the verification record
# has the entry.
set -u
KO=$1 D=$2 M=/mnt/tp
umount $M 2>/dev/null; rmmod hammer2 2>/dev/null
insmod "$KO" || { echo "probe: insmod failed"; exit 2; }
mkdir -p $M && mount -t hammer2 "$D" $M || { echo "probe: mount failed"; exit 2; }
rm -rf $M/p; mkdir $M/p && cd $M/p || exit 2
echo a > created
echo a > written; sleep 0.05; echo b >> written
echo a > chmodded; chmod 0600 chmodded
# truncate(2) by path, which passes ATTR_SIZE alone, and coreutils'
# truncate, which opens the file and calls ftruncate(2).
dd if=/dev/zero of=truncdown bs=4096 count=4 2>/dev/null
perl -e 'truncate("truncdown", 100) or die "truncate: $!"'
echo a > truncup; perl -e 'truncate("truncup", 100000) or die "truncate: $!"'
echo a > ftrunc; truncate -s 3 ftrunc
echo a > linked; ln linked linked2
echo a > unlinked; ln unlinked unlinked2; rm unlinked2
echo a > renamed; mkdir sub; mv renamed sub/renamed
mkfifo -m 0600 fifo
mknod -m 0600 cdev c 1 3
cd /
st() { (cd $M/p && for f in created written chmodded truncdown truncup ftrunc linked unlinked renamed sub sub/renamed fifo cdev .; do
	[ -e "$f" ] || [ -p "$f" ] || continue
	stat -c '%n %.9Y %.9Z' "$f"; done); }
st > /tmp/tp.before
sync; umount $M && mount -t hammer2 "$D" $M || { echo "probe: remount failed"; exit 2; }
st > /tmp/tp.after
n=$(wc -l < /tmp/tp.before)
d=$(diff /tmp/tp.before /tmp/tp.after | grep -c '^<')
echo "probe: $n objects, $d whose mtime or ctime moved across the remount"
diff /tmp/tp.before /tmp/tp.after | grep -E '^[<>]' | head -24
# ctime earlier than mtime on any object, read before the remount
awk '{ if ($3 < $2) print "probe: ctime before mtime: " $0 }' /tmp/tp.before
rm -rf $M/p; umount $M; rmmod hammer2
echo "probe: rmmod $?"
