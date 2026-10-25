#!/bin/sh
# Allocation faults during a cluster SLAVE's creation and its
# synchronization, on the guest.  P4's third exit criterion.
#
# hammer2_pfsalloc() starts a PFS's synchronization thread with
# hammer2_thr_create(), whose lwkt_create() on Linux is kthread_create()
# and can fail where DragonFly's cannot.  The function handles that itself:
# it logs, frees the scratch buffer and leaves thr->td NULL.  What no
# reading of the source settles is what the cluster does next, so this
# measures it: with the thread create faulted, does the SLAVE exist
# without a thread, and does a remount heal it.
#
# The fault is injected with failslab rather than fail_function: the
# failure being asked about is an allocation failure, and failslab fails
# the allocation the thread create makes instead of returning an error
# from the function that makes it.
#
# The fault window is the pfs-create ioctl, not the mount.  Nine runs of
# this instrument aimed at the mount first, and the control they lacked
# showed why that cannot work: mounting a SLAVE label fails with
# root-inode EIO with no fault at all, so every mount-aimed run measured
# a pre-existing failure.  The ioctl path is shorter anyway: ioctl ->
# pfsalloc -> thr_create, with the utility process as the one task to
# filter on, and the module's own "cannot start thread" line names the
# landing where it happens.
#
# Four things make this instrument able to fail where it aims, and each
# is a way a run here could pass while proving nothing:
#   - failslab skips __GFP_DIRECT_RECLAIM allocations by default
#     (failslab.ignore_gfp_reclaim is true in mm/failslab.c), and
#     kthread_create() allocates GFP_KERNEL, which sets that flag.  A
#     default-configured run reports zero injections however the create
#     behaves, so ignore-gfp-wait is set to N for the injection window and
#     the count of injected failures is read back and required to be
#     nonzero.  That check is the difference between this and a fake pass.
#   - task-filter limits the failure to the process that creates, so the
#     guest's own writes to its root filesystem are not failed with it.
#     The utility runs with its own /proc/<pid>/make-it-fail set; the
#     absence of task filtering would fail the shell that started it.
#   - require-start/end bind the fault to hammer2_thr_create's own bytes,
#     read as offset and size from the built module's symbol table.  A
#     kallsyms-derived range cannot do this: only globals appear there and
#     the next global is 200 KiB away, a range that wide fired in the
#     superblock read instead, which the run's own check caught.
#   - the trace must name hammer2_thr_create and the module must log
#     "cannot start thread".  The count alone says the fault landed; only
#     those two say it landed in the thread create.  fail_dump's message
#     is suppressed for __GFP_NOWARN allocations and the counter still
#     decrements, so a run that counts an injection without either line
#     has not reached the code P4 asks about.
#
# Cannot prove: anything about a caller of the sync thread beyond this
# PFS, since the cluster here is one volume; the healthy multi-volume
# case is cluster-sync.sh's.
#
# Exit 0 pass, 1 fail, 2 could not run.  Needs the guest fleet and a
# kernel tree with CONFIG_FAILSLAB and CONFIG_FAULT_INJECTION_DEBUG_FS.
set -u
cd "$(dirname "$0")/.." || exit 2

GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
FIXDIR=${H2_FIXTURE_DIR:-$HOME/Projects/linux_hammer2-data/fixtures}
NEWFS=${H2_NEWFS:-$(command -v newfs_hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2")}
HAMMER2=${H2_HAMMER2:-$(command -v hammer2 2>/dev/null || echo "$HOME/Projects/hammer2-utils-upstream/target/release/hammer2")}
RUN="timeout ${H2_RUN_TIMEOUT:-600} ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
IMG=$FIXDIR/sync-alloc.img
W=$(mktemp -d) || exit 2
trap 'rm -rf "$W"' EXIT

command -v virsh >/dev/null 2>&1 || { echo "sync-alloc: COULD-NOT-RUN: no virsh" >&2; exit 2; }
[ -x "$NEWFS" ] || { echo "sync-alloc: COULD-NOT-RUN: no newfs_hammer2 (H2_NEWFS)" >&2; exit 2; }
[ -d "$FIXDIR" ] || { echo "sync-alloc: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -d "$KDIR" ] || { echo "sync-alloc: COULD-NOT-RUN: no kernel tree at $KDIR" >&2; exit 2; }
grep -q '^CONFIG_FAILSLAB=y' "$KDIR/.config" 2>/dev/null || {
	echo "sync-alloc: COULD-NOT-RUN: $KDIR has no CONFIG_FAILSLAB" >&2; exit 2; }
grep -q '^CONFIG_FAULT_INJECTION_DEBUG_FS=y' "$KDIR/.config" 2>/dev/null || {
	echo "sync-alloc: COULD-NOT-RUN: $KDIR has no FAULT_INJECTION_DEBUG_FS" >&2; exit 2; }
state=$($VIRSH domstate "$GUEST" 2>/dev/null) || {
	echo "sync-alloc: COULD-NOT-RUN: no guest $GUEST" >&2; exit 2; }
[ "$state" = running ] || { echo "sync-alloc: COULD-NOT-RUN: $GUEST is $state" >&2; exit 2; }
ssh -o ConnectTimeout=5 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null || {
	echo "sync-alloc: COULD-NOT-RUN: $GUEST does not answer ssh" >&2; exit 2; }

krel=$(cat "$KDIR/include/config/kernel.release" 2>/dev/null)
grel=$($RUN "$GUEST_SSH" uname -r 2>/dev/null)
[ -n "$krel" ] && [ "$krel" = "$grel" ] || {
	echo "sync-alloc: COULD-NOT-RUN: the module is for ${krel:-?} and $GUEST runs ${grel:-?}" >&2
	exit 2; }
# One lockdep report turns lockdep off until the next boot, and a run
# on that boot reads "no report" with nothing checking.
dl=$(ssh -o BatchMode=yes "$GUEST_SSH" "awk '/debug_locks:/ {print \$2}' /proc/lockdep_stats 2>/dev/null")
[ "$dl" = 0 ] && {
	echo "sync-alloc: COULD-NOT-RUN: lockdep is off on $GUEST since an earlier report; boot it again" >&2; exit 2; }

# failslab lives under debugfs.  A guest that has it configured but not
# mounted is not a failed run; it is an instrument that did not reach the
# control, so it is reported and the exit is 2.
$RUN "$GUEST_SSH" '[ -d /sys/kernel/debug/failslab ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null; [ -d /sys/kernel/debug/failslab ]' >/dev/null 2>&1 || {
	echo "sync-alloc: COULD-NOT-RUN: no /sys/kernel/debug/failslab on $GUEST" >&2; exit 2; }

KO=src/sys/fs/hammer2/hammer2.ko
make -s clean >/dev/null 2>&1
make -s KDIR="$KDIR" >/dev/null 2>&1 || {
	echo "sync-alloc: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
nm -u "$KO" 2>/dev/null | grep -q '__asan' || {
	echo "sync-alloc: COULD-NOT-RUN: $KDIR is not a KASAN tree, so a memory report here would say nothing" >&2; exit 2; }
# hammer2_thr_create's offset and size in the built module, read from its
# symbol table.  The guest adds the offset to the loaded module's .text
# base to aim the fault at exactly that function.  A kallsyms range cannot
# do this: only global symbols appear there, and the next global after
# hammer2_thr_create is 200 KiB away, so a kallsyms-derived range covered
# half the module and the fault landed in the superblock read instead.
THR_OFF=$(nm -S "$KO" 2>/dev/null | awk '$4=="hammer2_thr_create" && $3=="T" {print $1; exit}')
THR_SIZE=$(nm -S "$KO" 2>/dev/null | awk '$4=="hammer2_thr_create" && $3=="T" {print $2; exit}')
[ -n "$THR_OFF" ] && [ -n "$THR_SIZE" ] || {
	echo "sync-alloc: COULD-NOT-RUN: no hammer2_thr_create size in $KO" >&2; exit 2; }

for d in vdb; do
	$VIRSH detach-disk "$GUEST" $d --live >/dev/null 2>&1
	$VIRSH detach-disk "$GUEST" $d --config >/dev/null 2>&1
done
rm -f "$IMG"
truncate -s 2G "$IMG" && "$NEWFS" -L ROOT "$IMG" >/dev/null 2>&1 || {
	echo "sync-alloc: COULD-NOT-RUN: newfs_hammer2 failed on $IMG" >&2; exit 2; }
if [ "$state" = running ]; then how=--live; else how=--config; fi
$VIRSH attach-disk "$GUEST" "$IMG" vdb --targetbus virtio $how >/dev/null 2>&1 || {
	echo "sync-alloc: COULD-NOT-RUN: could not attach $IMG" >&2; exit 2; }
n=0
until ssh -o ConnectTimeout=3 -o BatchMode=yes "$GUEST_SSH" 'test -b /dev/vdb' 2>/dev/null; do
	sleep 2; n=$((n + 1))
	[ $n -gt 30 ] && { echo "sync-alloc: COULD-NOT-RUN: /dev/vdb did not appear" >&2; exit 2; }
done

scp -q "$KO" "$GUEST_SSH:/tmp/hammer2.ko" || {
	echo "sync-alloc: COULD-NOT-RUN: could not copy the module" >&2; exit 2; }

out=$($RUN "$GUEST_SSH" sh -s "$THR_OFF" "$THR_SIZE" <<'GUEST'
set -u
rmmod hammer2 2>/dev/null
mkdir -p /mnt/h2a
dmesg -C
{ echo scan > /sys/kernel/debug/kmemleak && echo scan > /sys/kernel/debug/kmemleak && echo clear > /sys/kernel/debug/kmemleak; } 2>/dev/null; echo "kmemleak-cleared"	# an earlier run's leaks are its own
insmod /tmp/hammer2.ko debug=0x8000 || { echo "insmod-failed"; exit 0; }

# Mount the ROOT PFS, which the control proved mounts clean, and create the
# BASE master unfaulted.  The fault window is the SLAVE's pfs-create
# below, not the mount: mounting a SLAVE label fails with root-inode EIO
# with no fault at all (measured, the control every earlier run of this
# instrument lacked), so a mount cannot carry the fault to the thread
# create.  The ioctl path is shorter anyway: ioctl -> pfsalloc ->
# thr_create, with the utility process as the one task to filter on.
mount -t hammer2 /dev/vdb@ROOT /mnt/h2a || { echo "base-mount-failed"; exit 0; }
hammer2 -s /mnt/h2a pfs-create BASE >/dev/null 2>&1 || { echo "pfs-create-failed"; exit 0; }
clid=$(hammer2 -s /mnt/h2a pfs-list | awk '$3=="BASE"{print $2}')
[ -n "$clid" ] || { echo "pfs-create-failed"; exit 0; }
# The base noise leaves the log; the fault window below is read on its own.
dmesg -C

# Inject one slab allocation failure into the process that mounts, with
# direct-reclaim allocations INCLUDED, which is what kthread_create()
# makes.  Default ignore-gfp-wait=Y would skip it and the run would inject
# nothing while reporting a clean mount.
#
# The first run of this instrument failed its own check: process-wide
# task filtering aimed at the mount failed the mount's own superblock read
# before hammer2_pfsalloc() ran, and the mount refused with no thread
# create on the path.  Binding the fault to the module's whole text range
# fixed that reading and produced a worse one: the trace shows the first
# module allocation in the mount is hammer2_init_fs_context's, at
# fsopen(), so the fault still never reached the thread create.  The range
# is therefore narrowed to hammer2_thr_create itself, read from the
# loaded module's symbol, which is the only frame the fault must find.
#
# fail_function, which would name the function directly, is not built on
# this guest, and kthread_create carries no ALLOW_ERROR_INJECTION, so a
# stack range is the only mechanism that can aim at the allocation the
# thread create makes.  The range is not read from kallsyms: only globals
# appear there, the next global after hammer2_thr_create is 200 KiB away,
# and a range that wide fired in the superblock read instead, which the
# run's own check caught.  The host passes the function's offset and size
# from the built module's symbol table as $1 and $2, and the guest adds
# the offset to the loaded module's .text base.  The kallsyms symbol is
# then only a sanity check that the loaded module is the built one.
fs=/sys/kernel/debug/failslab
off=$1; size=$2
base=$(cat /sys/module/hammer2/sections/.text 2>/dev/null)
[ -n "$off" ] && [ -n "$size" ] && [ -n "$base" ] || { echo "ctl-failed: no offset, size or text base"; exit 0; }
lo=$(printf '0x%x' $(( base + 0x$off )) 2>/dev/null)
hi=$(printf '0x%x' $(( base + 0x$off + 0x$size )) 2>/dev/null)
[ -n "$lo" ] && [ -n "$hi" ] || { echo "ctl-failed: range arithmetic failed"; exit 0; }
ksym=$(grep -m1 ' t hammer2_thr_create[[:space:]]' /proc/kallsyms 2>/dev/null | cut -d' ' -f1)
[ "0x$ksym" = "$lo" ] || { echo "ctl-failed: loaded hammer2_thr_create 0x$ksym is not the built $lo"; exit 0; }
echo N > $fs/ignore-gfp-wait        || { echo "ctl-failed"; exit 0; }
echo Y > $fs/task-filter            || { echo "ctl-failed"; exit 0; }
echo "$lo" > $fs/require-start      || { echo "ctl-failed"; exit 0; }
echo "$hi" > $fs/require-end        || { echo "ctl-failed"; exit 0; }
echo 100 > $fs/probability
echo 1 > $fs/interval
# A large budget, not one shot.  times=1 proved unable to reach the
# subject: the first matching allocation in hammer2_thr_create's tree is
# not always the thread's own.  Nested infrastructure allocations (KASAN
# stack depot and the like) run inside the same stack range, fail
# silently where their flags carry NOWARN or their caller recovers, and
# consume a budget of one while the thread is created undisturbed, which
# the run's own landing check caught.  A large budget fails every
# matching allocation in the window instead, so the thread create's own
# kzalloc fails with it, and that failure always logs.  The NOFAIL
# hmallocs either side are skipped by the instrument either way, so the
# budget cannot starve the calls the create needs for itself.
echo 1000000 > $fs/times
echo 0 > $fs/space
echo 2 > $fs/verbose
before=$(cat $fs/times)
echo "thr-create-range $lo $hi"
echo "require-readback $(cat $fs/require-start) $(cat $fs/require-end)"
echo "ratelimit $(cat $fs/verbose_ratelimit_burst 2>/dev/null) per $(cat $fs/verbose_ratelimit_interval_ms 2>/dev/null)ms"

# The SLAVE create runs in a child of this shell, so the filter names that
# child.  /proc/<pid>/make-it-fail is what task-filter reads, and the flag
# survives the exec into the utility, whose ioctl runs the create.
( echo 1 > /proc/self/make-it-fail; exec hammer2 -s /mnt/h2a -t SLAVE -u "$clid" pfs-create SYNC ) >/dev/null 2>&1 &
mpid=$!
wait $mpid; crc=$?
echo "create-rc $crc"
after=$(cat $fs/times 2>/dev/null)

echo 0 > $fs/probability
echo 0 > $fs/times
echo 0 > $fs/verbose
echo N > $fs/task-filter
echo Y > $fs/ignore-gfp-wait
echo 0 > $fs/require-start
echo 0 > $fs/require-end

# How many failures were actually injected.  times decrements, so the
# difference is the count; a run that injected nothing is not evidence.
# The trace must also name hammer2_thr_create: the count alone says the
# fault landed, and only the trace says where, which is what distinguishes
# this run from the two that preceded it.
echo "injected $(( ${before:-0} - ${after:-0} ))"
echo "forcing-lines $(dmesg | grep -c 'FAULT_INJECTION: forcing')"
echo "in-thread-create $(dmesg | grep -A40 'FAULT_INJECTION: forcing' | grep -c 'hammer2_thr_create')"
dmesg | grep -A12 'FAULT_INJECTION: forcing' | grep -E '^\[[ 0-9.]*\]  [a-z_]+' | head -14 | sed 's/^/  trace: /'
echo "start-thread-log $(dmesg | grep -c 'cannot start thread')"
echo "sync-exists $(hammer2 -s /mnt/h2a pfs-list 2>/dev/null | awk '$3=="SYNC"{print "yes"}')"
echo "sync-thread $(ps -eo comm | grep -c '^h2nod-SYNC')"

if [ "$crc" != 0 ]; then
	# The create refused.  The module must have said why, and no half
	# PFS may be left: a SLAVE entry with no thread is the threadless
	# shape below, arrived at by refusal rather than by success.
	echo "create-refused"
	echo "refusal-log $(dmesg | grep -c 'hammer2:')"
	dmesg | grep 'hammer2:' | tail -3 | sed 's/^/  log: /'
	echo "done-partial"
fi

echo "created"
# The create returned.  Now the criterion, both halves of it: does the
# SLAVE exist, and does its thread.  A PFS with no thread is the shape
# the record hypothesized, a cluster running synchronization-less on a
# log line; a PFS with a thread means the fault missed, which the
# in-thread-create check above already gates.
sleep 8
echo "passes $(dmesg | grep -c 'sync_slaves pfs')"
echo "pass-errors $(dmesg | grep -c 'hammer2_sync_slaves: error')"
# The volume must stay usable either way: a write into the BASE master
# and the bytes back.
if echo "hello" > /mnt/h2a/f 2>/dev/null; then
	got=$(cat /mnt/h2a/f 2>/dev/null)
	[ "$got" = "hello" ] && echo "write-roundtrip ok" || echo "write-roundtrip got '${got:-}'"
else
	echo "write-failed"
fi
# The retry the record hypothesized: a remount re-runs update_pmps, which
# creates the thread when td is NULL.  If the create left a threadless
# SLAVE, the remount must heal it; if it does not, the threadlessness is
# permanent until pfs-delete, which is a stronger claim and is reported
# as one.
umount /mnt/h2a
mount -t hammer2 /dev/vdb@ROOT /mnt/h2a && echo "remount ok" || echo "remount-failed"
echo "sync-thread-after-remount $(ps -eo comm | grep -c '^h2nod-SYNC')"
hammer2 -s /mnt/h2a pfs-delete SYNC >/dev/null 2>&1; echo "delete-rc $?"
echo "threads-after-delete $(ps -eo comm | grep -c '^h2nod')"
umount /mnt/h2a && echo "umount ok"
echo "threads-after $(ps -eo comm | grep -c '^h2nod')"
# Scans before rmmod so the report's symbols resolve to the module.
sleep 6
if echo scan > /sys/kernel/debug/kmemleak 2>/dev/null && echo scan > /sys/kernel/debug/kmemleak; then
	echo "kmemleak $(grep -c hammer2 /sys/kernel/debug/kmemleak)"
else
	echo "kmemleak unusable"
fi
# hammer2's range as /proc/modules gives it before rmmod, its core text's
# base and its total size, so the scan after the unload counts its frames
# and not another module's; init text, freed after the load, is outside
# it. The size is added to the base's low half alone, since a base above
# INT64_MAX is past some shells' arithmetic, and a base printed as zero
# (kptr_restrict) or a size that carries leaves the range unread.
mrange=$(awk '$1 == "hammer2" { printf "%s %d\n", $6, $2 }' /proc/modules)
mb=${mrange% *}; ms=${mrange#* }; me=
case $mb in
0x00000000*|*[!0-9a-fx]*) ;;
0x????????????????)
	ml=$((0x${mb#0x????????} + ms))
	[ "$ms" -gt 0 ] && [ "$ml" -le 4294967295 ] && me=$(printf '%s%08x' "${mb%????????}" "$ml") ;;
esac
echo "kmemleak-unloaded-range ${mb:-none} ${me:-none}"
rmmod hammer2 && echo "rmmod ok"
# Scanned again after the unload, whose frames now print as addresses: an
# object a module global held and the unload never freed is a leak only
# from here. Each reading scans twice, since a scan greys an object whose
# checksum changed since the last one (mm/kmemleak.c, kmemleak_scan) and a
# new object's starts at ~0, so a leak is reported at its second scan.
# The scans wait out kmemleak's minimum age, 5 s, so an object the unload
# itself left is old enough to be reported.
sleep 6
if [ -z "$me" ]; then
	echo "kmemleak-unloaded unread"
elif echo scan > /sys/kernel/debug/kmemleak 2>/dev/null && echo scan > /sys/kernel/debug/kmemleak; then
	h2n=$(awk -v b="$mb" -v e="$me" '{ a = $1 "" } a ~ /^0x/ && a >= b && a < e' /sys/kernel/debug/kmemleak | wc -l)
	echo "kmemleak-unloaded $h2n"
	[ "$h2n" = 0 ] || sed 's/^/kmemleak-unloaded-report /' /sys/kernel/debug/kmemleak | head -200
fi
echo "warnings $(dmesg | grep -c -E 'WARNING|BUG:|UBSAN:|KASAN|circular locking|possible recursive')"
echo "done"
GUEST
)
rc=$?
[ $rc -eq 124 ] && { echo "sync-alloc: FAIL: the guest run hung past ${H2_RUN_TIMEOUT:-600}s" >&2; exit 1; }

for d in vdb; do
	$VIRSH detach-disk "$GUEST" $d --live >/dev/null 2>&1
	$VIRSH detach-disk "$GUEST" $d --config >/dev/null 2>&1
done

printf '%s\n' "$out" > "$W/out"
val() { sed -n "s/^$1 //p" "$W/out" | head -1; }
nval() { grep -c -E "^$1( |$)" "$W/out"; }	# how many lines carry the name, with or without a value
case "$out" in
*"COULD-NOT-RUN"*) echo "sync-alloc: COULD-NOT-RUN: the guest refused the setup" >&2; exit 2 ;;
esac
for m in insmod-failed base-mount-failed pfs-create-failed ctl-failed; do
	case "$out" in
	*"$m"*) echo "sync-alloc: COULD-NOT-RUN: the base setup stopped at $m" >&2; exit 2 ;;
	esac
done

inj=$(val injected)
crc=$(val create-rc)
log=$(val start-thread-log)

fail=0; checks=0
check() {
	checks=$((checks + 1))
	if [ "$2" = 0 ]; then echo "  ok    $1: $3"; else echo "  FAIL  $1: $3"; fail=$((fail + 1)); fi
}

# The injection is the instrument.  Zero injected means the run measured
# nothing, and every check after it would pass on a create that was never
# faulted.  The module's own "cannot start thread" line is the landing
# proof: it prints only from hammer2_thr_create's failure arm, so the run
# reached the code P4 asks about if and only if that line is present.  The
# trace is a second witness where the allocator prints one; a NOWARN
# allocation decrements the counter in silence, so the count without
# either line is not evidence.
[ "${inj:-0}" -gt 0 ] 2>/dev/null; check "the fault was injected" $? "${inj:-none} allocation failure(s); ignore-gfp-wait=N is what lets a GFP_KERNEL allocation fail"
f=$(val forcing-lines)
i=$(val in-thread-create)
[ "${log:-0}" -gt 0 ] 2>/dev/null; check "the fault is in the thread create" $? "${log:-none} cannot-start-thread line(s), ${i:-none} trace line(s) of ${f:-none} forcing line(s)"
r=$(val thr-create-range)
printf '  note  aimed range: %s\n' "${r:-none}"
rb=$(val require-readback)
printf '  note  stored range: %s\n' "${rb:-none}"
printf '%s\n' "$out" | sed -n 's/^  trace: /  trace: /p'
printf '%s\n' "$out" | sed -n 's/^  log: /  log: /p'

case "$out" in
*create-refused*)
	# The create refused.  The module must have named the failure, and no
	# half PFS may be left behind it.
	d=$(val refusal-log)
	[ "${d:-0}" -gt 0 ] 2>/dev/null; check "the refusal is named in the log" $? "${d:-0} hammer2 line(s)"
	s=$(val sync-exists)
	[ "$s" != "yes" ]; check "no half SLAVE is left" $? "pfs-list shows ${s:-nothing}"
	;;
*created*)
	# The create returned.  The criterion is the pair: does the SLAVE
	# exist, and does its thread.  Existence without a thread is the
	# threadless shape; existence with one means the fault missed, which
	# the landing check above already fails.
	s=$(val sync-exists)
	t=$(val sync-thread)
	if [ "$s" = "yes" ] && [ "${t:-1}" = 0 ]; then
		check "the SLAVE exists with no thread" 0 "pfs-list names SYNC, ${t:-none} h2nod-SYNC thread(s): the cluster runs synchronization-less"
	elif [ "$s" = "yes" ]; then
		check "the SLAVE exists with no thread" 1 "the fault missed: ${t:-none} thread(s) running"
	else
		check "the SLAVE exists with no thread" 1 "pfs-list names no SYNC though the create returned $crc"
	fi
	case "$out" in
	*write-roundtrip\ ok*) r=0 ;;
	*write-failed*) r=1 ;;
	*) r=1 ;;
	esac
	check "a write into the BASE master succeeds" $r "$(printf '%s\n' "$out" | sed -n '/write-roundtrip\|write-failed/p' | head -1)"
	e=$(val pass-errors)
	[ "${e:-1}" = 0 ]; check "no synchronization pass reports an error" $? "${e:-none}"
	# The retry: the remount re-runs update_pmps, which the record says
	# heals a threadless SLAVE.  A thread after the remount confirms it;
	# none means the threadlessness survives a remount and is reported.
	rt=$(val sync-thread-after-remount)
	[ "${rt:-0}" -gt 0 ] 2>/dev/null; check "the remount heals the thread" $? "${rt:-none} h2nod-SYNC thread(s) after remount"
	grep -q '^umount ok' "$W/out"; check "the volume unmounts" $? "$(grep -c '^umount ok' "$W/out") of 1"
	;;
*)
	echo "sync-alloc: FAIL: the guest run produced no reading" >&2
	cat "$W/out" >&2
	exit 1 ;;
esac

grep -q '^rmmod ok' "$W/out"; check "the module unloads" $? "$(grep -c '^rmmod ok' "$W/out") of 1"
k=$(val warnings); [ "${k:-1}" = 0 ]; check "no kernel warning, lockdep, KASAN or UBSAN report" $? "${k:-none}"
c=$(nval kmemleak-cleared); l=$(val kmemleak); m=$(nval kmemleak); u=$(val kmemleak-unloaded); n=$(nval kmemleak-unloaded); r=$(nval kmemleak-unloaded-range)
case "$l" in
0) [ "$c" = 1 ] && [ "$m" = 1 ] && [ "$n" = 1 ] && [ "$r" = 1 ] && [ "${u:-1}" = 0 ]; check "kmemleak reports nothing of hammer2's" $? "cleared $c time(s), $l printed $m time(s), after the unload ${u:-unread}, printed $n time(s) after $r range line(s)" ;;
unusable) check "kmemleak is usable" 1 "the scan refused; only a reboot turns it back on" ;;
"") check "kmemleak was read before the unload" 1 "no reading before the unload, $n after it with $r range line(s)" ;;
*) check "kmemleak reports nothing of hammer2's" 1 "$l" ;;
esac

echo "sync-alloc: $checks check(s), $fail failed"
[ "$fail" = 0 ] || exit 1
exit 0
