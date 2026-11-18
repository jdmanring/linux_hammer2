#!/bin/sh
# The control for the kernel ring's start marker, run through a real fleet
# script on the guest.
#
# A fleet script that counts kernel reports from the guest's ring writes a
# marker after its clear and reads it back before its count; a marker that
# is gone is exit 2, since the ring drops its oldest records first and a
# count over a ring that wrapped counts only what survived. The check runs
# /var/lib/h2ring-flood when the file exists, and this script installs it:
# a file on the guest's disk, so it survives the reboot a fleet script may
# do, which deletes itself before it does anything else and so fires once.
#
# The file plants a line every report counter reads, "BUG: KASAN: h2ring
# planted", and in the flood arm then writes 100000 records of about a
# hundred bytes each, well past the guest's 8 MiB ring, at level 7 with the
# console level lowered so the serial console does not carry them. Each
# record is its own open of /dev/kmsg, because in its default mode,
# printk.devkmsg=ratelimit, the kernel limits a writer to ten records per
# five seconds per open (kernel/printk/printk.c, devkmsg_open(),
# devkmsg_write()); printk.devkmsg=on lifts it.
#
# A fleet script that streams the log through kmsg-stream.sh is controlled
# the same way through /var/lib/h2stream-flood, which kmsg-stream.sh --end
# runs before it writes its end marker. In the flood arm the file first
# stops every reader of /dev/kmsg, so the plant and the flood land while
# nothing reads them and the reader, resumed, meets records the ring has
# already overwritten. The mutant arm ships a reader without its loss
# detection: it opens /dev/kmsg again where cat stopped, which resumes at
# the oldest record left as dmesg -w does, and prints no gap. A script
# controlled this way must ship the reader under its own name, so the
# mutant's copy can name another file in its place.
#
#   script/ring-flood.sh plant  <fleet script> [args]   must fail: the count reads the plant
#   script/ring-flood.sh flood  <fleet script> [args]   must exit 2: the plant is erased
#   script/ring-flood.sh mutant <fleet script> [args]   must exit 0: a copy with its refusal
#                                                        removed passes over the erased plant
#
# Each arm prints the fleet script's status, whether the file fired, and
# how many planted lines the guest's ring still holds afterwards. Exit 0
# when the arm read what it must, 1 when it did not, 2 when it could not
# run. The guest must be up and answer ssh; the fleet script's own
# requirements are its own.
set -u
cd "$(dirname "$0")/.." || exit 2
ARM=${1:-}; SUBJ=${2:-}
case $ARM in plant|flood|mutant) ;; *) echo "ring-flood: COULD-NOT-RUN: arm plant, flood or mutant" >&2; exit 2 ;; esac
[ -f "script/$SUBJ" ] || { echo "ring-flood: COULD-NOT-RUN: no script/$SUBJ" >&2; exit 2; }
shift 2
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
REFUSE="the guest's kernel ring lost its start marker"; HOOK=/var/lib/h2ring-flood
if ! command grep -qF "$REFUSE" "script/$SUBJ"; then
	REFUSE="the guest's kernel log stream lost records"; HOOK=/var/lib/h2stream-flood
	command grep -qF "$REFUSE" "script/$SUBJ" || {
		echo "ring-flood: COULD-NOT-RUN: script/$SUBJ carries no ring or stream refusal" >&2; exit 2; }
fi
stop=0; [ "$HOOK" = /var/lib/h2stream-flood ] && [ "$ARM" != plant ] && stop=1
ssh -o ConnectTimeout=4 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null || {
	echo "ring-flood: COULD-NOT-RUN: the guest does not answer ssh" >&2; exit 2; }

flood=0; [ "$ARM" = plant ] || flood=1
ssh "$GUEST_SSH" "cat > $HOOK; chmod 755 $HOOK; rm -f $HOOK.fired" <<EOF || {
#!/bin/sh
rm -f $HOOK
echo fired > $HOOK.fired
[ $stop = 0 ] || pkill -STOP -f '^cat /dev/kmsg'
echo "<3>BUG: KASAN: h2ring planted" > /dev/kmsg
[ $flood = 1 ] || exit 0
read lvl rest < /proc/sys/kernel/printk
echo 1 > /proc/sys/kernel/printk
i=0
while [ \$i -lt 100000 ]; do
	echo "<7>h2ring-flood \$i ................................................................................." > /dev/kmsg
	i=\$((i + 1))
done
echo \$lvl > /proc/sys/kernel/printk
[ $stop = 0 ] || pkill -CONT -f '^cat /dev/kmsg'
exit 0
EOF
	echo "ring-flood: COULD-NOT-RUN: could not install the file on the guest" >&2; exit 2; }

subj=script/$SUBJ
if [ "$ARM" = mutant ] && [ "$HOOK" = /var/lib/h2ring-flood ]; then
	subj=script/.run-ringmut-$SUBJ
	command grep -vF "$REFUSE" "script/$SUBJ" > "$subj" || exit 2
	trap 'rm -f "$subj"' EXIT
elif [ "$ARM" = mutant ]; then
	subj=script/.run-ringmut-$SUBJ; mr=script/.run-ringmut-kmsg-stream.sh
	trap 'rm -f "$subj" "$mr"' EXIT
	command grep -qF 'script/kmsg-stream.sh "$GUEST_SSH:/tmp/kmsg-stream.sh"' "script/$SUBJ" || {
		echo "ring-flood: COULD-NOT-RUN: script/$SUBJ does not ship the reader under its own name" >&2; exit 2; }
	sed 's|script/kmsg-stream.sh "$GUEST_SSH:/tmp/kmsg-stream.sh"|'"$mr"' "$GUEST_SSH:/tmp/kmsg-stream.sh"|' "script/$SUBJ" > "$subj"
	sed "s|src='exec cat /dev/kmsg 2>&1'|src='while :; do cat /dev/kmsg 2>/dev/null; done'|; s|else if (seen \&\& h\[2\] + 0 != last + 1)|else if (0)|" \
	    script/kmsg-stream.sh > "$mr"
	cmp -s script/kmsg-stream.sh "$mr" || [ "$(diff script/kmsg-stream.sh "$mr" | command grep -c '^>')" = 2 ] || {
		echo "ring-flood: COULD-NOT-RUN: the mutant reader is not the two-line change it must be" >&2; exit 2; }
	! cmp -s script/kmsg-stream.sh "$mr" && ! cmp -s "script/$SUBJ" "$subj" || {
		echo "ring-flood: COULD-NOT-RUN: the mutant changed nothing" >&2; exit 2; }
fi
sh "$subj" "$@" > /tmp/ring-flood.$$ 2>&1; st=$?
sed 's/^/  | /' /tmp/ring-flood.$$
refused=0; command grep -qF "$REFUSE" /tmp/ring-flood.$$ && refused=1
rm -f /tmp/ring-flood.$$

r=$(ssh -o ConnectTimeout=5 "$GUEST_SSH" "test -e $HOOK.fired && echo fired || echo unfired; echo \"planted \$(dmesg | grep -c 'h2ring planted')\"; rm -f $HOOK $HOOK.fired" 2>/dev/null)
fired=$(printf '%s\n' "$r" | command grep -c '^fired$')
planted=$(printf '%s\n' "$r" | sed -n 's/^planted //p')
echo "ring-flood: arm $ARM, $SUBJ exit $st, refusal printed $refused, file fired $fired, planted lines in the ring ${planted:-unread}"
[ "$fired" = 1 ] || { echo "ring-flood: COULD-NOT-RUN: the file never fired, so the run reached no check" >&2; exit 2; }
case $ARM in
plant)	[ "$st" = 1 ] && [ "$refused" = 0 ] && [ "${planted:-x}" != 0 ] ;;
flood)	[ "$st" = 2 ] && [ "$refused" = 1 ] && [ "${planted:-x}" = 0 ] ;;
mutant)	[ "$st" = 0 ] && [ "${planted:-x}" = 0 ] ;;
esac || { echo "ring-flood: FAIL: arm $ARM did not read what it must"; exit 1; }
echo "ring-flood: ok"
