#!/bin/sh
# The CCMS thread lock under lockdep, on the guest.
#
# Nothing in the module calls the CCMS lock, so a lockdep run of the
# ordinary module has nothing to observe.  This builds the module with
# HAMMER2_CCMS_LOCKTEST=1, which starts two kernel threads at load that
# take the carried lock in every way it implements (shared, exclusive,
# upgrade and downgrade, nonblock), loads it on the guest, lets it run, and
# reads what lockdep reported.  P3's fourth exit criterion is this reading.
#
# What a fake pass looks like, and what stops each one:
#   - lockdep off.  A kernel without it, or one where a taint has already
#     turned it off (debug_locks 0), reports nothing on any lock.  The run
#     requires CONFIG_PROVE_LOCKING in the tree the module is built against
#     and debug_locks 1 on the guest both before the load and after the
#     unload; 0 before is could-not-run, 0 after is a failure, since this
#     run turned it off.
#   - the threads never took the lock.  The unload prints the rounds the
#     threads ran; zero rounds is a failure, because a clean report about a
#     lock nobody took says nothing.
#   - the report read from the wrong window.  dmesg is cleared before the
#     load and read after the unload, so nothing from an earlier run counts.
#
# Cannot prove: anything about a caller of this lock, since there is none;
# it proves lockdep's view of the lock on its own.
#
# Exit 0 pass, 1 fail, 2 could not run.  Needs the guest fleet.
set -u
cd "$(dirname "$0")/.." || exit 2

KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
SECS=${H2_CCMS_LOCKTEST_SECS:-60}
RUN="timeout $((SECS + 300)) ssh -o ServerAliveInterval=15 -o ServerAliveCountMax=4"

command -v virsh >/dev/null 2>&1 || { echo "ccms-lockdep: COULD-NOT-RUN: no virsh" >&2; exit 2; }
[ -d "$KDIR" ] || { echo "ccms-lockdep: COULD-NOT-RUN: no kernel tree at $KDIR" >&2; exit 2; }
grep -q '^CONFIG_PROVE_LOCKING=y' "$KDIR/.config" 2>/dev/null || {
	echo "ccms-lockdep: COULD-NOT-RUN: $KDIR is not a PROVE_LOCKING kernel" >&2; exit 2; }
state=$($VIRSH domstate "$GUEST" 2>/dev/null) || {
	echo "ccms-lockdep: COULD-NOT-RUN: no guest $GUEST" >&2; exit 2; }
[ "$state" = running ] || { echo "ccms-lockdep: COULD-NOT-RUN: $GUEST is $state" >&2; exit 2; }
ssh -o ConnectTimeout=5 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null || {
	echo "ccms-lockdep: COULD-NOT-RUN: $GUEST does not answer ssh" >&2; exit 2; }


krel=$(cat "$KDIR/include/config/kernel.release" 2>/dev/null)
grel=$($RUN "$GUEST_SSH" uname -r 2>/dev/null)
[ -n "$krel" ] && [ "$krel" = "$grel" ] || {
	echo "ccms-lockdep: COULD-NOT-RUN: the module is for ${krel:-?} and $GUEST runs ${grel:-?}" >&2
	exit 2; }


make -s clean >/dev/null 2>&1
make -s KDIR="$KDIR" HAMMER2_CCMS_LOCKTEST=1 >/dev/null 2>&1 || {
	echo "ccms-lockdep: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko
n=$(nm "$KO" 2>/dev/null | grep -c 'ccms_locktest_start' || true)
[ "$n" -gt 0 ] || { echo "ccms-lockdep: FAIL: the built module carries no lock exercise" >&2; exit 1; }
scp -q "$KO" "$GUEST_SSH:/tmp/hammer2.ko" || {
	echo "ccms-lockdep: COULD-NOT-RUN: could not copy the module" >&2; exit 2; }

out=$($RUN "$GUEST_SSH" sh -s "$SECS" <<'GUEST'
secs=$1
dl() { awk '/debug_locks:/{print $2}' /proc/lockdep_stats; }
lsmod | grep -q '^hammer2 ' && { echo "busy"; exit 0; }
echo "debug-locks-before $(dl)"
dmesg -C
insmod /tmp/hammer2.ko || { echo "insmod-failed"; exit 0; }
sleep "$secs"
rmmod hammer2 || { echo "rmmod-failed"; exit 0; }
echo "debug-locks-after $(dl)"
dmesg | grep 'ccms locktest rounds' | sed 's/.*ccms locktest rounds /rounds /'
echo "lockdep-reports $(dmesg | grep -cE 'possible circular locking|possible recursive locking|inconsistent lock state|bad unlock balance|held lock freed|BUG: sleeping function called|WARNING: .*lock')"
echo "kasan $(dmesg | grep -c 'BUG: KASAN')"
echo "bug $(dmesg | grep -cE '^\[[ 0-9.]*\] (BUG|kernel BUG):')"
echo "---report---"
dmesg | grep -A40 -E 'possible circular locking|possible recursive locking|inconsistent lock state|bad unlock balance|held lock freed|BUG:' | head -80
GUEST
)
rc=$?
[ $rc -eq 124 ] && { echo "ccms-lockdep: FAIL: the guest run hung" >&2; exit 1; }

get() { printf '%s\n' "$out" | sed -n "s/^$1 //p" | head -1; }
case "$out" in
*busy*) echo "ccms-lockdep: COULD-NOT-RUN: hammer2 is already loaded on $GUEST" >&2; exit 2 ;;
*insmod-failed*) echo "ccms-lockdep: FAIL: the module did not load" >&2; exit 1 ;;
*rmmod-failed*) echo "ccms-lockdep: FAIL: the module did not unload, the threads may not have stopped" >&2; exit 1 ;;
esac

before=$(get debug-locks-before)
after=$(get debug-locks-after)
rounds=$(printf '%s\n' "$out" | sed -n 's/^rounds \([0-9]*\),.*/\1/p')
fstate=$(printf '%s\n' "$out" | sed -n 's/^rounds [0-9]*, \(.*\)/\1/p')
reports=$(get lockdep-reports)
kasan=$(get kasan)
bug=$(get bug)

if [ "$before" != 1 ]; then
	echo "ccms-lockdep: COULD-NOT-RUN: debug_locks is ${before:-?} on $GUEST before the load," >&2
	echo "         so lockdep is already off and a clean run would say nothing; reboot it" >&2
	exit 2
fi

bad=0
check() {
	if [ "$2" = ok ]; then printf '  ok     %s\n' "$1"
	else printf '  FAIL   %s\n' "$1"; bad=$((bad + 1)); fi
}
[ "${rounds:-0}" -gt 0 ] && r=ok || r=no
check "the threads took the lock: ${rounds:-0} round(s), ending $fstate" $r
[ "$fstate" = "count 0 upgrade 0" ] && r=ok || r=no
check "the lock ends unlocked with no upgrade pending" $r
[ "$after" = 1 ] && r=ok || r=no
check "lockdep still on after the run: debug_locks $after" $r
[ "${reports:-1}" = 0 ] && r=ok || r=no
check "lockdep reports: ${reports:-?}" $r
[ "${kasan:-1}" = 0 ] && r=ok || r=no
check "KASAN reports: ${kasan:-?}" $r
[ "${bug:-1}" = 0 ] && r=ok || r=no
check "BUG lines: ${bug:-?}" $r

if [ $bad -ne 0 ]; then
	printf '%s\n' "$out" | sed -n '/^---report---$/,$p'
	echo "ccms-lockdep: $bad failed"
	exit 1
fi
echo "ccms-lockdep: 6 check(s), 0 failed, $SECS s on $grel"
exit 0
