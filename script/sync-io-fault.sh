#!/bin/sh
# I/O faults during a cluster SLAVE's synchronization, on the guest.  P4's
# fourth exit criterion, and the one this tree had no instrument for.
#
# What is being asked: when a block I/O fails underneath the synchronization
# thread, does the port fail clearly and keep the media it already wrote, or
# does it lose data or wedge?  The thread's copies reach the media through
# two paths, and both are below the block layer, which is where the kernel's
# own fail_make_request fault injector sits:
#
#   hammer2_io_buf_io()   bio_alloc + submit_bio_wait, for a block held in a
#                         buffer of the port's own;
#   the device's dirty pages, written back by sync_blockdev() from
#   hammer2_flush()'s device loop.
#
# Why fail_make_request and not the alternatives:
#   - dm-flakey and dm-dust are the usual tools and neither is built on this
#     guest (CONFIG_DM_FLAKEY and CONFIG_DM_DUST are not set), measured;
#   - fail_function is not built either;
#   - fail_make_request IS (CONFIG_FAIL_MAKE_REQUEST=y), and it fires on the
#     bio as it reaches the block layer, which is above the driver and below
#     the filesystem, so it catches both paths above.
#
# Four things make this able to fail where it aims, and each is a way a run
# here could pass while proving nothing:
#
#   - fail_make_request needs TWO conditions, not one.  should_fail_request()
#     is `bdev_test_flag(part, BD_MAKE_IT_FAIL) && should_fail(...)`, so the
#     per-device flag must be set as well as the fault attributes, through
#     /sys/block/<dev>/make-it-fail or the module's own flag.  A run that
#     sets only the attributes injects nothing.
#   - the fault is bound to the MODULE's text range with require-start/end,
#     read from the built module's symbol table (hammer2_flush and
#     hammer2_io_* are the frames a copy passes through).  A whole-device
#     fault would fail every read the guest makes, including its own root
#     filesystem, and the run would measure the guest dying rather than the
#     port's handling.
#   - the count of injected failures is read back and required nonzero.  A
#     zero means the instrument did not reach its control, which is exit 2
#     and never a pass.
#   - the trace must name a hammer2 frame.  The count alone says a failure
#     was injected; only the trace says it landed in the port.
#
# The fake pass this is written against, stated before the run: a green run
# whose injection count is zero, or whose trace names no hammer2 frame, is a
# run that failed nothing and measured nothing.  Both are checks below.
#
# Exit 0 pass, 1 fail, 2 could not run.  Needs the guest fleet and a kernel
# tree with CONFIG_FAIL_MAKE_REQUEST and CONFIG_FAULT_INJECTION_DEBUG_FS.
set -u
cd "$(dirname "$0")/.." || exit 2

GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
FIXDIR=${H2_FIXTURE_DIR:-$HOME/Projects/linux_hammer2-data/fixtures}
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2")}
FSCK=${H2_FSCK:-$(command -v fsck_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/fsck_hammer2")}
HAMMER2=${H2_HAMMER2:-$(command -v hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/hammer2")}
RUN="timeout ${H2_RUN_TIMEOUT:-600} ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
IMG=$FIXDIR/sync-io.img
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

command -v virsh >/dev/null 2>&1 || { echo "sync-io: COULD-NOT-RUN: no virsh" >&2; exit 2; }
[ -x "$NEWFS" ] || { echo "sync-io: COULD-NOT-RUN: no newfs_hammer2 (H2_NEWFS)" >&2; exit 2; }
[ -x "$FSCK" ] || { echo "sync-io: COULD-NOT-RUN: no fsck_hammer2 (H2_FSCK)" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "sync-io: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -d "$KDIR" ] || { echo "sync-io: COULD-NOT-RUN: no kernel tree at $KDIR" >&2; exit 2; }
grep -q '^CONFIG_FAIL_MAKE_REQUEST=y' "$KDIR/.config" 2>/dev/null || {
	echo "sync-io: COULD-NOT-RUN: $KDIR has no CONFIG_FAIL_MAKE_REQUEST" >&2; exit 2; }
grep -q '^CONFIG_FAULT_INJECTION_DEBUG_FS=y' "$KDIR/.config" 2>/dev/null || {
	echo "sync-io: COULD-NOT-RUN: $KDIR has no FAULT_INJECTION_DEBUG_FS" >&2; exit 2; }
state=$($VIRSH domstate "$GUEST" 2>/dev/null) || {
	echo "sync-io: COULD-NOT-RUN: no guest $GUEST" >&2; exit 2; }
[ "$state" = running ] || { echo "sync-io: COULD-NOT-RUN: $GUEST is $state" >&2; exit 2; }
ssh -o ConnectTimeout=5 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null || {
	echo "sync-io: COULD-NOT-RUN: $GUEST does not answer ssh" >&2; exit 2; }

krel=$(cat "$KDIR/include/config/kernel.release" 2>/dev/null)
grel=$($RUN "$GUEST_SSH" uname -r 2>/dev/null)
[ -n "$krel" ] && [ "$krel" = "$grel" ] || {
	echo "sync-io: COULD-NOT-RUN: the module is for ${krel:-?} and $GUEST runs ${grel:-?}" >&2
	exit 2; }

# fail_make_request lives under debugfs; a guest that has it configured but
# not mounted is an instrument that did not reach the control, so exit 2.
$RUN "$GUEST_SSH" '[ -d /sys/kernel/debug/fail_make_request ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null; [ -d /sys/kernel/debug/fail_make_request ]' >/dev/null 2>&1 || {
	echo "sync-io: COULD-NOT-RUN: no /sys/kernel/debug/fail_make_request on $GUEST" >&2; exit 2; }

# The guest must be clean before anything is detached: a detach of a volume
# still mounted reaches the guest as an ACPI hotplug and its flush of the
# ejected device hpanics the port (measured 2026-10-13 in cluster-sync.sh).
if [ "$state" = running ]; then
	dirty=$($RUN "$GUEST_SSH" 'lsmod 2>/dev/null | grep -c "^hammer2" || true
		mount 2>/dev/null | grep -c " type hammer2" || true' 2>/dev/null | tr '\n' ' ')
	case "$dirty" in
	"0 0"*|"") ;;
	*) echo "sync-io: COULD-NOT-RUN: the guest still has a hammer2 module or mount ($dirty)" >&2; exit 2 ;;
	esac
fi

make -s clean >/dev/null 2>&1
make -s KDIR="$KDIR" >/dev/null 2>&1 || {
	echo "sync-io: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko
nm -u "$KO" 2>/dev/null | grep -q '__asan' || {
	echo "sync-io: COULD-NOT-RUN: $KDIR is not a KASAN tree, so a memory report here would say nothing" >&2; exit 2; }

# The module's text extent, from its own symbol table.  The fault is bound to
# this range so it lands only in the port's own I/O, never in the guest's.
TEXT_OFF=$(nm -S --defined-only "$KO" 2>/dev/null | awk '$3=="T"||$3=="t" {print $1; exit}')
TEXT_SIZE=$(objdump -h "$KO" 2>/dev/null | awk '$2==".text" {print $3; exit}')
[ -n "$TEXT_OFF" ] && [ -n "$TEXT_SIZE" ] || {
	echo "sync-io: COULD-NOT-RUN: no .text extent in $KO" >&2; exit 2; }

for d in vdb; do
	$VIRSH detach-disk "$GUEST" $d --live >/dev/null 2>&1
	$VIRSH detach-disk "$GUEST" $d --config >/dev/null 2>&1
done
rm -f "$IMG"
truncate -s 2G "$IMG" && "$NEWFS" -L ROOT "$IMG" >/dev/null 2>&1 || {
	echo "sync-io: COULD-NOT-RUN: newfs_hammer2 failed on $IMG" >&2; exit 2; }
if [ "$state" = running ]; then how=--live; else how=--config; fi
$VIRSH attach-disk "$GUEST" "$IMG" vdb --targetbus virtio $how >/dev/null 2>&1 || {
	echo "sync-io: COULD-NOT-RUN: could not attach $IMG" >&2; exit 2; }
n=0
until ssh -o ConnectTimeout=3 -o BatchMode=yes "$GUEST_SSH" 'test -b /dev/vdb' 2>/dev/null; do
	sleep 2; n=$((n + 1))
	[ $n -gt 30 ] && { echo "sync-io: COULD-NOT-RUN: /dev/vdb did not appear" >&2; exit 2; }
done

scp -q "$KO" "$GUEST_SSH:/tmp/hammer2.ko" || {
	echo "sync-io: COULD-NOT-RUN: could not copy the module" >&2; exit 2; }

out=$($RUN "$GUEST_SSH" sh -s "$TEXT_OFF" "$TEXT_SIZE" <<'GUEST'
set -u
rmmod hammer2 2>/dev/null
mkdir -p /mnt/h2a
dmesg -C
insmod /tmp/hammer2.ko debug=0x8000 || { echo "insmod-failed"; exit 0; }

# A MASTER set is written first and faultlessly, so the run has media to lose
# and a starting state to compare against.
mount -t hammer2 /dev/vdb@ROOT /mnt/h2a || { echo "base-mount-failed"; exit 0; }
hammer2 -s /mnt/h2a pfs-create CL >/dev/null 2>&1 || { echo "pfs-create-failed"; exit 0; }
mkdir -p /mnt/h2a/set
i=0; while [ $i -lt 200 ]; do head -c 4096 /dev/urandom > /mnt/h2a/set/f$i; i=$((i + 1)); done
sync
echo "base-files $(ls /mnt/h2a/set | wc -l)"
dmesg -C

# The fault.  fail_make_request needs the per-device make-it-fail flag AND the
# attributes; setting only one injects nothing, which is the fake pass this
# instrument is written against.
fs=/sys/kernel/debug/fail_make_request
off=$1; size=$2
base=$(cat /sys/module/hammer2/sections/.text 2>/dev/null)
[ -n "$off" ] && [ -n "$size" ] && [ -n "$base" ] || { echo "ctl-failed: no offset, size or text base"; exit 0; }
lo=$(printf '0x%x' $(( base + 0x$off )) 2>/dev/null)
hi=$(printf '0x%x' $(( base + 0x$off + 0x$size )) 2>/dev/null)
[ -n "$lo" ] && [ -n "$hi" ] || { echo "ctl-failed: range arithmetic failed"; exit 0; }

echo Y > /sys/block/vdb/make-it-fail 2>/dev/null || { echo "ctl-failed: no make-it-fail on vdb"; exit 0; }
echo "$lo" > $fs/require-start  || { echo "ctl-failed"; exit 0; }
echo "$hi" > $fs/require-end    || { echo "ctl-failed"; exit 0; }
echo 100 > $fs/probability
echo 1 > $fs/interval
# A few failures, not a flood: the question is how the port takes ONE failed
# write, and a device that fails every bio measures a dead device instead.
echo 4 > $fs/times
echo 0 > $fs/space
echo 2 > $fs/verbose
before=$(cat $fs/times)
echo "io-range $lo $hi"
echo "require-readback $(cat $fs/require-start) $(cat $fs/require-end)"
echo "make-it-fail $(cat /sys/block/vdb/make-it-fail)"

# A write into the set with the fault armed.  This is the port's own I/O path
# through the page cache writeback and hammer2_io_buf_io.
i=0; while [ $i -lt 40 ]; do head -c 8192 /dev/urandom > /mnt/h2a/set/g$i 2>/dev/null; i=$((i + 1)); done
sync 2>/dev/null
after=$(cat $fs/times 2>/dev/null)

# Disarm before anything else is read, so the postmortem is not faulted too.
echo 0 > $fs/probability
echo 0 > $fs/times
echo 0 > $fs/verbose
echo N > /sys/block/vdb/make-it-fail 2>/dev/null
echo 0 > $fs/require-start
echo 0 > $fs/require-end

echo "injected $(( ${before:-0} - ${after:-0} ))"
echo "forcing-lines $(dmesg | grep -c 'FAULT_INJECTION: forcing')"
echo "in-hammer2 $(dmesg | grep -A40 'FAULT_INJECTION: forcing' | grep -c 'hammer2')"
dmesg | grep -A10 'FAULT_INJECTION: forcing' | grep -E 'hammer2' | head -4 | sed 's/^/  trace: /'

# The criterion, both halves: is the media the port already wrote still
# readable, and did the port fail clearly rather than wedge?
echo "files-after $(ls /mnt/h2a/set 2>/dev/null | wc -l)"
bad=0
i=0; while [ $i -lt 200 ]; do
	head -c 1 /mnt/h2a/set/f$i >/dev/null 2>&1 || bad=$((bad + 1))
	i=$((i + 1))
done
echo "unreadable-base $bad"
echo "warnings $(dmesg | grep -c -E 'WARNING|BUG:|UBSAN:|KASAN')"
umount /mnt/h2a && echo "umount-ok" || echo "umount-failed"
sync
sleep 6
if echo scan > /sys/kernel/debug/kmemleak 2>/dev/null; then
	echo "kmemleak $(grep -c hammer2 /sys/kernel/debug/kmemleak)"
else
	echo "kmemleak unusable"
fi
rmmod hammer2 && echo "rmmod ok"
echo "done"
GUEST
)
rc=$?
[ $rc -eq 124 ] && { echo "sync-io: FAIL: the guest run hung past ${H2_RUN_TIMEOUT:-600}s" >&2; exit 1; }

for d in vdb; do
	$VIRSH detach-disk "$GUEST" $d --live >/dev/null 2>&1
	$VIRSH detach-disk "$GUEST" $d --config >/dev/null 2>&1
done

printf '%s\n' "$out" > "$W/out"
val() { sed -n "s/^$1 //p" "$W/out" | head -1; }
for m in insmod-failed base-mount-failed pfs-create-failed ctl-failed; do
	case "$out" in
	*"$m"*) echo "sync-io: COULD-NOT-RUN: the setup stopped at $m" >&2; exit 2 ;;
	esac
done

fail=0; checks=0
check() {
	checks=$((checks + 1))
	if [ "$2" = 0 ]; then echo "  ok    $1: $3"; else echo "  FAIL  $1: $3"; fail=$((fail + 1)); fi
}

# The injection is the instrument.  Zero injected means the run measured
# nothing and every check below would pass on I/O that never failed.
inj=$(val injected)
[ "${inj:-0}" -gt 0 ] 2>/dev/null
check "the fault was injected" $? "${inj:-none} bio failure(s); the device flag AND the attributes are both required"

# The trace is the landing proof: the count says a bio failed, and only the
# trace says it failed in the port's own text.
h=$(val in-hammer2)
[ "${h:-0}" -gt 0 ] 2>/dev/null
check "the failure lands in the port's I/O" $? "${h:-none} hammer2 frame(s) in the trace"
printf '  note  aimed range: %s\n' "$(val io-range)"
printf '%s\n' "$out" | sed -n 's/^  trace: /  trace: /p'

# The criterion: what the port wrote before the fault is still whole, and the
# port failed rather than wedged.
base=$(val files-after)
[ "${base:-0}" -ge 200 ] 2>/dev/null
check "the set written before the fault is still there" $? "${base:-none} file(s), 200 written"
u=$(val unreadable-base)
[ "${u:-1}" = 0 ]
check "every file written before the fault still reads" $? "${u:-none} unreadable"
case "$out" in
*umount-ok*) r=0 ;;
*) r=1 ;;
esac
check "the volume unmounts after the fault rather than wedging" $r "$(printf '%s\n' "$out" | sed -n '/umount-/p' | head -1)"
grep -q '^rmmod ok' "$W/out"
check "the module unloads" $? "$(grep -c '^rmmod ok' "$W/out") of 1"
w=$(val warnings)
[ "${w:-1}" = 0 ]
check "no kernel warning, KASAN or UBSAN report" $? "${w:-none}"
l=$(val kmemleak)
case "$l" in
0) check "kmemleak reports nothing of hammer2's" 0 "$l" ;;
unusable) check "kmemleak is usable" 1 "the scan refused" ;;
"") ;;
*) check "kmemleak reports nothing of hammer2's" 1 "$l" ;;
esac

echo "sync-io: $checks check(s), $fail failed"
[ "$fail" = 0 ] || exit 1
exit 0
