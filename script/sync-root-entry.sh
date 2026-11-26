#!/bin/sh
# Whether a sync writes a PFS root's directory entries ahead of the inodes
# they name. Stage 2 of hammer2_vfs_sync_pmp() flushes the root last, and a
# frontend operation that edits the root after stage 1 processed it leaves
# the inodes it paired with for the next sync; flushed then, the root
# carries an entry whose inode is not on the media, a name gone whose inode
# is, or a link count its names disagree with, and a snapshot taken from
# that sync keeps it. The check before stage 2's flush restarts stage 1 for
# the root, at most rootsync_free + 1 times per sync.
#
# The window arm (the default) puts each mode on its own volume, found on
# the guest by its virtio serial, and per kind runs one churner in the
# PFS root through H2_ROOT_ROUNDS snapshots, each snapshot's sync held
# rootsync_hold_ms (200) before stage 2 so an edit lands in the window:
#   create  mkdir of new names in the root
#   unlink  files made in the root, each unlinked 200 creates later
#   rename  a file from the root to sub/ and back
#   link    sub/l linked into the root and unlinked
# The host then reads every snapshot on each image with h2-dangling.py.
# Mode 1 (the fix) must leave 0 snapshots failing and no sync with more
# root restarts than rootsync_free + 1; mode 0 (upstream's flush, the
# control) must fail, every create round while the gap is nonzero, or the
# hold is not opening the window and the run could not judge. H2_ROOT_GAP
# is the us between a churner's operations; 0, with H2_ROOT_KINDS=link and
# more rounds, keeps a frontend queued on the root's lock whenever the
# sync holds it.
#
# The measure arm (H2_ROOT_ARM=measure) puts one 16 GiB volume under N
# root loops for 20 s beside a back-to-back syncfs(2) loop, per spec of
# H2_ROOT_MSPECS (mode or mode:free, default "1:8 1:0 0"), mkdir at N = 1,
# 8, 32 and rename between the root and sub/ at N = 1, 8, 64, and prints
# operations, syncs and the restart and hold counters; it judges only the
# bound and that no churner failed. Nothing runs bulkfree, so the volume
# is sized for the specs.
#
# H2_KO names a module built with HAMMER2_LOCKDEBUG=1 for the guest's
# kernel, and H2_BOOT (h2debug-7.3tls, h2kasan-7.3tls), when set, the
# kernel the guest must have booted. Needs the fleet; exits 2 without it,
# 1 on a failed check.
set -u
cd "$(dirname "$0")/.." || exit 2
KO=${H2_KO:-}
[ -n "$KO" ] && [ -f "$KO" ] || { echo "COULD-NOT-RUN: H2_KO names no module"; exit 2; }
export LIBVIRT_DEFAULT_URI=${H2_LIBVIRT_URI:-qemu:///system}
command -v virsh >/dev/null 2>&1 || { echo "COULD-NOT-RUN: no virsh"; exit 2; }
GUEST=${H2_GUEST:-artix-s6-kde}; GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
FIX=${H2_FIXTURE_DIR:-$HOME/Projects/linux_hammer2-data/fixtures}
NEWFS=${H2_NEWFS:-$HOME/Projects/hammer2-utils-upstream/target/release/newfs_hammer2}
ARM=${H2_ROOT_ARM:-window}
MODES=${H2_ROOT_MODES:-1 0} KINDS=${H2_ROOT_KINDS:-create unlink rename link}
ROUNDS=${H2_ROOT_ROUNDS:-20} GAP=${H2_ROOT_GAP:-5000} FREE=${H2_ROOT_FREE:-}
MSPECS=${H2_ROOT_MSPECS:-1:8 1:0 0}
case $ROUNDS$GAP$FREE in *[!0-9]*) echo "COULD-NOT-RUN: H2_ROOT_ROUNDS, _GAP and _FREE are numbers"; exit 2 ;; esac
case $ARM in
window) DISKS='' SPECS='' i=0; SIZE=2G
	for m in $MODES; do
		case $m in 0|1) ;; *) echo "COULD-NOT-RUN: H2_ROOT_MODES holds 0 or 1"; exit 2 ;; esac
		d=vd$(echo bcd | cut -c$((i + 1))); [ "$d" = vd ] && { echo "COULD-NOT-RUN: three modes at most"; exit 2; }
		DISKS="$DISKS $d" SPECS="$SPECS $m:$d" i=$((i + 1))
	done ;;
measure) DISKS=vdb SPECS='' SIZE=16G ;;
*) echo "COULD-NOT-RUN: H2_ROOT_ARM is window or measure"; exit 2 ;;
esac
[ -n "$DISKS" ] && [ -n "$KINDS" ] || { echo "COULD-NOT-RUN: no modes or kinds"; exit 2; }
SSH="ssh -o ServerAliveInterval=5 -o ServerAliveCountMax=6 -o ConnectTimeout=5 -o BatchMode=yes"
T=$(mktemp) && W=$(mktemp -d) || exit 2
trap 'rm -rf "$T" "$W"' EXIT
cc -static -O2 -o "$W/rootchurn" test/rootchurn.c || { echo "COULD-NOT-RUN: test/rootchurn.c did not build"; exit 2; }
nf=0; nc=0
check() {	# description, status, detail
	nc=$((nc + 1))
	[ "$2" = 0 ] && echo "  ok    $1: $3" || { echo "  FAIL  $1: $3"; nf=$((nf + 1)); }
}
down() {
	for d in $DISKS; do virsh detach-disk $GUEST $d >/dev/null 2>&1; done
	virsh shutdown $GUEST >/dev/null 2>&1
	i=0; while [ "$(virsh domstate $GUEST)" != "shut off" ] && [ $i -lt 45 ]; do sleep 2; i=$((i+1)); done
	[ "$(virsh domstate $GUEST)" = "shut off" ] || { echo "guest did not shut down, destroyed"; virsh destroy $GUEST >/dev/null 2>&1; }
}
for d in $DISKS; do
	img=$FIX/root-entry-$ARM-$d.img
	rm -f "$img"; truncate -s $SIZE "$img" && "$NEWFS" -L ROOT "$img" >/dev/null 2>&1 ||
	    { echo "COULD-NOT-RUN: newfs"; exit 2; }
done
[ "$(virsh domstate $GUEST)" = "shut off" ] || { echo "COULD-NOT-RUN: $GUEST is $(virsh domstate $GUEST)"; exit 2; }
virsh start $GUEST >/dev/null 2>&1
i=0; until $SSH "$GUEST_SSH" true 2>/dev/null; do sleep 5; i=$((i+1)); [ $i -ge 60 ] && { echo "COULD-NOT-RUN: no ssh"; down; exit 2; }; done
# The debug and KASAN builds share a release string, so H2_BOOT, when set,
# names the kernel the guest must have booted.
boot=$($SSH "$GUEST_SSH" cat /proc/cmdline | grep -o 'BOOT_IMAGE=[^ ]*')
[ -n "$boot" ] || { echo "COULD-NOT-RUN: no BOOT_IMAGE on $GUEST"; down; exit 2; }
[ -z "${H2_BOOT:-}" ] || [ "${boot##*/vmlinuz-linux-}" = "$H2_BOOT" ] ||
    { echo "COULD-NOT-RUN: $GUEST booted $boot, not $H2_BOOT"; down; exit 2; }
kr=$($SSH "$GUEST_SSH" uname -r) vm=$(modinfo -F vermagic "$KO" | cut -d' ' -f1)
[ "$kr" = "$vm" ] || { echo "COULD-NOT-RUN: the module is for $vm, $GUEST runs $kr"; down; exit 2; }
# One lockdep report turns lockdep off until the next boot.
dl=$($SSH "$GUEST_SSH" "awk '/debug_locks:/ {print \$2}' /proc/lockdep_stats 2>/dev/null")
[ "$dl" = 0 ] && { echo "COULD-NOT-RUN: lockdep is off on $GUEST since an earlier report"; down; exit 2; }
# The guest names virtio disks in probe order, not by target; the serial
# names each image.
for d in $DISKS; do
	virsh attach-disk $GUEST "$FIX/root-entry-$ARM-$d.img" $d --targetbus virtio --serial h2re-$d >/dev/null 2>&1 ||
	    { echo "COULD-NOT-RUN: attach $d"; down; exit 2; }
done
scp -q "$KO" "$GUEST_SSH:/tmp/h2.ko" && scp -q "$W/rootchurn" "$GUEST_SSH:/tmp/rootchurn" ||
    { echo "COULD-NOT-RUN: copy"; down; exit 2; }
echo "sync-root-entry: $ARM, module $(sha256sum "$KO" | cut -c1-16) on $kr ($boot), modes [$MODES] kinds [$KINDS] rounds $ROUNDS gap $GAP free [${FREE:-module}] mspecs [$MSPECS]"
# ssh hands the guest one command line, so the values travel inside it.
timeout 3000 $SSH "$GUEST_SSH" "ARM='$ARM' SPECS='$SPECS' KINDS='$KINDS' ROUNDS='$ROUNDS' GAP='$GAP' FREE='$FREE' MSPECS='$MSPECS' sh" <<"REMOTE" 2>&1 | sed "s/^/  guest /" | tee -a "$T"
dmesg -C; echo h2ring-start > /dev/kmsg
insmod /tmp/h2.ko || { echo "insmod failed"; exit 9; }
P=/sys/module/hammer2/parameters
test -w $P/rootsync_mode && test -w $P/rootsync_free || { echo "no rootsync_mode: not a HAMMER2_LOCKDEBUG module"; exit 9; }
[ -z "$FREE" ] || echo $FREE > $P/rootsync_free
echo "free $(cat $P/rootsync_free)"
byid() { n=0; until [ -b /dev/disk/by-id/virtio-h2re-$1 ] || [ $n -ge 30 ]; do sleep 1; n=$((n + 1)); done; [ -b /dev/disk/by-id/virtio-h2re-$1 ] && readlink -f /dev/disk/by-id/virtio-h2re-$1; }
zero() { for c in syncs restarts root_restarts root_max hold_ns hold_max_ns; do echo 0 > $P/rootsync_$c; done; }
counters() { echo "syncs $(cat $P/rootsync_syncs) restarts $(cat $P/rootsync_restarts) root_restarts $(cat $P/rootsync_root_restarts) root_max $(cat $P/rootsync_root_max) hold_ns $(cat $P/rootsync_hold_ns) hold_max_ns $(cat $P/rootsync_hold_max_ns)"; }
mkdir -p /mnt/re
if [ "$ARM" = window ]; then
	echo 200 > $P/rootsync_hold_ms
	for spec in $SPECS; do
		mode=${spec%:*} dev=${spec#*:}
		echo $mode > $P/rootsync_mode
		bd=$(byid $dev) || { echo "no disk with serial h2re-$dev"; exit 9; }
		mount -t hammer2 $bd@ROOT /mnt/re || { echo "mount $dev failed"; exit 9; }
		mkdir /mnt/re/sub
		for kind in $KINDS; do
			k=$(echo $kind | cut -c1)
			zero
			/tmp/rootchurn $kind /mnt/re 1 1800 $GAP > /tmp/churn.out 2>&1 &
			cp=$!
			sleep 1
			r=0 f=0
			while [ $r -lt $ROUNDS ]; do
				hammer2 snapshot /mnt/re $k$(printf %03d $r) >/dev/null 2>&1 || f=$((f + 1))
				r=$((r + 1))
			done
			kill $cp; wait $cp; c=$?
			echo "window mode $mode dev $dev kind $kind snapshots $r failed $f churn rc $c [$(cat /tmp/churn.out)] $(counters)"
		done
		umount /mnt/re || { echo "umount $dev failed"; exit 9; }
	done
	echo 0 > $P/rootsync_hold_ms
else
	bd=$(byid vdb) || { echo "no disk with serial h2re-vdb"; exit 9; }
	mount -t hammer2 $bd@ROOT /mnt/re || { echo "mount failed"; exit 9; }
	mkdir /mnt/re/sub
	run() {	# kind mode[:free] n
		case $2 in *:*) echo ${2#*:} > $P/rootsync_free ;; esac
		echo ${2%:*} > $P/rootsync_mode
		zero
		i=1; while [ $i -le $3 ]; do /tmp/rootchurn $1 /mnt/re $i 20 > /tmp/churn.$i 2>&1 & i=$((i + 1)); done
		/tmp/rootchurn sync /mnt/re 20 > /tmp/sync.out 2>&1; s=$?
		wait
		ops=$(cat /tmp/churn.* | awk '{s += $4} END {print s}') errs=$(cat /tmp/churn.* | awk '{s += $6} END {print s}')
		en=$(cat /tmp/churn.* | awk '$6 > 0 {print $8}' | sort -u | tr '\n' ',')
		echo "measure $1 spec $2 n $3 free $(cat $P/rootsync_free) churn ops $ops errors $errs errnos [$en] syncfs rc $s [$(cat /tmp/sync.out)] $(counters)"
		rm -f /tmp/churn.*
	}
	for spec in $MSPECS; do for n in 1 8 32; do run mkdir $spec $n; done; done
	for spec in $MSPECS; do for n in 1 8 64; do run rename $spec $n; done; done
	umount /mnt/re || { echo "umount failed"; exit 9; }
fi
rmmod hammer2; echo "rmmod $?"
test -x /var/lib/h2ring-flood && /var/lib/h2ring-flood; dmesg | grep -q h2ring-start && echo ring whole || echo ring COULD-NOT-READ
echo "log: warn $(dmesg | grep -c "WARNING:") bug $(dmesg | grep -c "BUG:") kasan $(dmesg | grep -c "KASAN") ubsan $(dmesg | grep -c "UBSAN") circular $(dmesg | grep -c "circular") hung $(dmesg | grep -c "INFO: task") cut $(dmesg | grep -c "cut here")"
REMOTE
down
v=$(grep -E 'guest (insmod failed|no rootsync_mode|no disk with serial|mount .*failed|mount failed)' "$T") && {
	echo "sync-root-entry: COULD-NOT-RUN: ${v#  guest }" >&2; exit 2; }
grep -q 'guest rmmod ' "$T" || { echo "sync-root-entry: COULD-NOT-RUN: the guest's run did not finish" >&2; exit 2; }
free=$(sed -n 's/^  guest free \([0-9]*\)$/\1/p' "$T")
[ -n "$free" ] || { echo "sync-root-entry: COULD-NOT-RUN: no rootsync_free read" >&2; exit 2; }
cnr=
# A churner that failed or did nothing, in either arm, leaves the run
# unable to judge its mode.
c=$(grep -E '^  guest (window .* churn rc [^0]|measure .* errors [1-9])' "$T") && cnr="a churner failed: ${c#  guest }"
if [ "$ARM" = window ]; then
	for spec in $SPECS; do
		mode=${spec%:*} d=${spec#*:}
		dg=$W/dangling-$d
		python3 -I script/h2-dangling.py "$FIX/root-entry-$ARM-$d.img" > "$dg" 2>&1; dr=$?
		[ $dr = 2 ] && { cnr="h2-dangling.py could not read $d: $(head -1 "$dg")"; continue; }
		for kind in $KINDS; do
			k=$(echo $kind | cut -c1)
			# A snapshot's line: name, then the counts h2-dangling.py
			# prints, of which these four are defects.
			set -- $(awk -v k=$k '$1 ~ "^" k "[0-9][0-9][0-9]:$" { n++; if ($6 + $10 + $15 + $23) f++ } END { print n + 0, f + 0 }' "$dg")
			n=$1 f=$2
			echo "  read  mode $mode kind $kind: $f of $n snapshots failing on media"
			[ "$n" = "$ROUNDS" ] || { cnr="mode $mode kind $kind: $n snapshots on media of $ROUNDS taken"; continue; }
			if [ "$mode" = 0 ]; then
				eval "ctl_$k=$f"
			else
				[ "$f" = 0 ]; check "mode $mode, $kind: no snapshot keeps a root entry ahead of its inodes" $? "$f of $n failing"
				m=$(sed -n "s/^  guest window mode $mode dev $d kind $kind .* root_max \([0-9]*\) .*/\1/p" "$T")
				[ -n "$m" ] && [ "$m" -le $((free + 1)) ]; check "mode $mode, $kind: no sync restarts for the root more than rootsync_free + 1 times" $? "most ${m:-none}, bound $((free + 1))"
			fi
		done
	done
	# The control must fail, or the arm is not aiming at the window: every
	# create round while the gap holds the window open, one snapshot at
	# least otherwise.
	case " $MODES " in *" 0 "*)
		tot=0; for k in $(for x in $KINDS; do echo $x | cut -c1; done); do eval "tot=\$((tot + \${ctl_$k:-0}))"; done
		[ "$tot" -ge 1 ] || cnr="the control failed no snapshot, so the arm is not aimed"
		case " $KINDS " in *" create "*)
			[ "$GAP" = 0 ] || [ "${ctl_c:-0}" = "$ROUNDS" ] || cnr="the control failed ${ctl_c:-0} of $ROUNDS create rounds, so the hold is not opening the window" ;;
		esac ;;
	esac
else
	for spec in $MSPECS; do
		case $spec in 0) continue ;; esac
		for x in $(sed -n "s/^  guest measure [a-z]* spec $spec n [0-9]* free \([0-9]*\) .* root_max \([0-9]*\) .*/\1:\2/p" "$T"); do
			[ "${x#*:}" -le $((${x%:*} + 1)) ]; check "spec $spec: no sync restarts for the root more than rootsync_free + 1 times" $? "most ${x#*:}, bound $((${x%:*} + 1))"
		done
	done
fi
echo "sync-root-entry: $nc check(s), $nf failed"
[ $nf = 0 ] || exit 1
[ -z "$cnr" ] || { echo "sync-root-entry: COULD-NOT-RUN: $cnr" >&2; exit 2; }
grep -q 'ring whole' "$T" && ! grep -q 'ring COULD-NOT-READ' "$T" || {
	echo "sync-root-entry: COULD-NOT-READ: the guest's kernel ring lost its start marker" >&2; exit 2; }
l=$(grep 'guest log: ' "$T")
echo "$l" | grep -q 'warn 0 bug 0 kasan 0 ubsan 0 circular 0 hung 0 cut 0$'; check "no warning, BUG, KASAN, UBSAN, lockdep, hung-task or cut-here line in the log" $? "${l#  guest log: }"
[ $nf = 0 ] || exit 1
exit 0
