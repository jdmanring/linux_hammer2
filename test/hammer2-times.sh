#!/bin/sh
# Every time stat shows on a HAMMER2 mount must be the time a remount
# reads back from the media, and no object's ctime may precede its mtime.
# Run on the guest as root, with the module to load and a scratch HAMMER2
# device: sh test/hammer2-times.sh <ko> <dev>.
# A FAKE PASS is an object whose times the run never moved, so each one
# is stamped by a different operation: create, write, chmod, truncate(2)
# by path, ftruncate(2), link, unlink, rename, mkfifo, mknod, a write
# through a mapping and a write into the fifo.  The last two reach the
# media only through ->update_time.
# The second half drives the kernel's own clock.  A stat and then a write
# on tmpfs inside one tick raise the multigrain floor that current_time()
# returns past the coarse clock, so a stamp the kernel takes in that tick
# is ahead of one the module takes a moment later.  Two thousand rounds
# of a write, which the kernel stamps, and a rename, which the module
# stamps, as system calls from one perl process so most rounds land
# inside a tick; every renamed file whose ctime is behind its mtime is
# the two clocks disagreeing.  Zero on the module before the fix means
# the control did not fire, and the run says nothing about the fix.
# Measured 2026-10-17 on h2debug-rc5: 10 of 13 objects moved on the module
# before the first timestamp change and 0 of 13 in three runs after it;
# with the mapping, the fifo write and the floor race added, 2 of 14 moved
# on that module and 1993 of 2000 read ctime before mtime, and after the
# second change 0 of 14 and 0 of 2000 in three runs. The verification
# record has both entries.
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
# A write through a mapping, which stamps from filemap_page_mkwrite(),
# after a write(2) that stamped it 50 ms earlier.
xfs_io -f -c 'pwrite -q 0 4096' mmapped; sleep 0.05
xfs_io -c 'mmap -w 0 4096' -c 'mwrite 0 16' -c 'msync -s 0 4096' -c munmap mmapped
mkfifo -m 0600 fifo
mknod -m 0600 cdev c 1 3
# A write into the fifo, which stamps from pipe_write().
sleep 0.05; cat fifo > /dev/null & echo x > fifo; wait
# The floor race.
mkdir race; : > /tmp/h2tp-floor
perl -e '
my ($t, $d, $n) = @ARGV;
for my $i (1 .. $n) {
	my @s = stat($t);
	open(my $g, ">>", $t) or die "$t: $!"; print $g "x"; close $g;
	open(my $h, ">", "$d/f$i") or die "$d/f$i: $!"; print $h "x"; close $h;
	rename("$d/f$i", "$d/r$i") or die "rename: $!";
}' /tmp/h2tp-floor "$M/p/race" 2000
# The stamps are fixed-width, so a string comparison is exact where a
# number at nanosecond resolution is past what awk's double carries.
inv=$(stat -c '%.9Y %.9Z' $M/p/race/r* | awk '{ if (($2 "") < ($1 "")) n++ } END { print n + 0 }')
echo "probe: floor race, $inv of 2000 renamed files with ctime before mtime"
cd /
st() { (cd $M/p && for f in created written chmodded truncdown truncup ftrunc linked unlinked renamed sub sub/renamed mmapped fifo cdev .; do
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
awk '{ if (($3 "") < ($2 "")) print "probe: ctime before mtime: " $0 }' /tmp/tp.before
rm -rf $M/p /tmp/h2tp-floor; umount $M; rmmod hammer2
echo "probe: rmmod $?"
