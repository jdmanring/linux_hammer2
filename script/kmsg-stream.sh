#!/bin/sh
# Streams the kernel log in dmesg(1)'s default layout from a run's start
# marker onward, and says so in the stream when it lost records.
#
# A fleet script that counts from a stream of /dev/kmsg outgrows the guest's
# ring many times over (8 MiB, against kept klogs of 39 to 144 MB), so a
# marker in the ring cannot vouch for the stream, and dmesg -w cannot either:
# a reader that falls a whole ring behind gets EPIPE once and resumes at the
# oldest record left (kernel/printk/printk.c, devkmsg_read()), and dmesg
# retries that read without a word (util-linux sys-utils/dmesg.c,
# read_kmsg_one()). This reads the raw records, whose second field is the
# record's sequence number. cat, the reader, stops at the EPIPE and its error
# line comes through; a skipped number would print
# "h2kmsg: COULD-NOT-READ: records A to B were lost"; a reader that ends
# prints "h2kmsg: the reader ended". In each case the end marker never
# arrives, and --end says so.
#
# The layout is dmesg's with no options under the C locale: "[%5ld.%06ld] "
# and the text, the kernel's \xNN escapes undone for a newline (indented by
# the stamp's width, as dmesg does), a tab and a backslash, and kept for the
# rest, which is what dmesg prints for a byte the C locale cannot print;
# dictionary lines are dropped. dmesg would print a caller field under
# CONFIG_PRINTK_CALLER, which no guest kernel sets. A fresh read of
# /dev/kmsg replays the whole ring where dmesg -w after dmesg -C starts at
# the clear, so nothing before the start marker is printed, and the marker
# carries a value no earlier run's can.
#
#   sh kmsg-stream.sh --start > klog &        on the guest: writes the start
#                                             marker; $! is the reader to kill
#   sh kmsg-stream.sh --started klog          waits until the marker is read,
#                                             before the caller prints a line
#   sh kmsg-stream.sh --end klog              writes the end marker, waits up
#                                             to 30 s for it, prints "stream
#                                             whole" or "stream COULD-NOT-READ"
#   sh kmsg-stream.sh --read klog             the klog, once a marker written
#                                             now has reached it: every count
#                                             reads the klog this way
#   sh kmsg-stream.sh --render < raw          every raw record on stdin, no
#                                             marker, then the reader's line
#   sh kmsg-stream.sh --stop                  ends every reader on the guest
#   sh kmsg-stream.sh --selftest              on the host, no guest
set -u

PROG=$(cat <<'EOF'
function lit(s, a, b,   i, r) {
	r = ""
	while ((i = index(s, a)) > 0) { r = r substr(s, 1, i - 1) b; s = substr(s, i + length(a)) }
	return r s
}
function rec(l,   i, h, m, ts) {
	if (l ~ /^ /) return
	i = index(l, ";")
	if (i == 0 || substr(l, 1, i - 1) !~ /^[0-9]+,[0-9]+,[0-9]+,/) { print l; fflush(); return }
	split(substr(l, 1, i - 1), h, ",")
	m = substr(l, i + 1)
	if (!on) { if (m != start) return; on = 1 }
	else if (seen && h[2] + 0 != last + 1) printf "h2kmsg: COULD-NOT-READ: records %d to %d were lost\n", last + 1, h[2] - 1
	last = h[2] + 0; seen = 1
	ts =sprintf("[%5d.%06d] ", int(h[3] / 1000000), h[3] % 1000000)
	m = lit(m, "\\x0a", "\n" sprintf("%" length(ts) "s", ""))
	m = lit(m, "\\x09", "\t")
	m = lit(m, "\\x5c", "\\")
	print ts m; fflush()
}
BEGIN {
	on = (start == "")
	while ((src | getline l) > 0) rec(l)
	close(src)
	print "h2kmsg: the reader ended"; fflush()
}
EOF
)

# --end's verdict on a klog whose end marker it wrote, apart so the
# selftest reads it: whole only with both markers in the klog and no line
# from the reader saying it lost records or ended, nor from cat, and no
# count's wait for the reader that ran out (rd below).
verdict() {	# verdict <klog> <end marker>
	if grep -q "^\[ *[0-9]*\.[0-9]*\] $2\$" "$1" && grep -q '^\[ *[0-9]*\.[0-9]*\] h2kmsg-start ' "$1" && ! grep -q '^h2kmsg: \|^cat: ' "$1" && [ ! -e "$1.lag" ]; then
		echo "stream whole"
	else
		why=$(grep -m1 '^h2kmsg: \|^cat: ' "$1")
		if [ -n "$why" ]; then :
		elif [ -e "$1.lag" ]; then why=$(cat "$1.lag")
		elif ! grep -q '^\[ *[0-9]*\.[0-9]*\] h2kmsg-start ' "$1"; then why="the start marker is not in the klog"
		else why="the end marker did not arrive in 30 s"; fi
		echo "stream COULD-NOT-READ: $why"
	fi
}

# --read's wait, apart so the selftest drives it with a file for the
# device. The reader writes the klog behind the kernel, so a count read
# from it at once misses what is still on the way: a baseline read that
# way reads low and the delta after an act reads high, and a check that
# wants a delta above zero passes on an older line. A marker written now
# and seen in what the klog gained since says every record before it is
# in. A wait that runs out leaves <klog>.lag, which verdict refuses, and
# spares every later wait: a reader that far behind is not caught by
# waiting again. A read after a run's last --end that runs out is refused
# by nothing, and needs nothing: that --end vouched for the klog up to its
# marker, which is all such a count covers. --started removes the file.
rd() {	# rd <klog> <device> <secs>
	[ -e "$1.lag" ] && return 1
	m="h2kmsg-end $(cat /proc/sys/kernel/random/uuid)"
	o=$(wc -c < "$1")
	echo "$m" >> "$2"	# a record either way on the device; the selftest's file keeps its lines
	n=0
	until tail -c +$((o + 1)) "$1" | grep -q "^\[ *[0-9]*\.[0-9]*\] $m\$"; do
		[ $n -ge $(($3 * 10)) ] && { echo "a count's marker did not arrive in $3 s" > "$1.lag"; return 1; }
		sleep 0.1; n=$((n + 1))
	done
}

# Only a whole UUID is taken from a command line and only a whole marker
# line matches it: a shorter token, from any command line that names the
# marker's word, would match an earlier run's marker that begins with it.
started() {	# started <klog>: the marker of a reader now running is in it
	x='[0-9a-f]\{8\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{4\}-[0-9a-f]\{12\}'
	for u in $(pgrep -af 'h2kmsg[-]start ' | grep -o "h2kmsg-start $x" | sed 's/.* //'); do
		grep -q "^\[ *[0-9]*\.[0-9]*\] h2kmsg-start $u\$" "$1" 2>/dev/null && return 0
	done
	return 1
}

# The selftest is named in the form pre-push-check.sh and CI find it by.
[ "${1:-}" = "--selftest" ] || case ${1:-} in
--start)
	m="h2kmsg-start $(cat /proc/sys/kernel/random/uuid)" || exit 2
	echo "$m" > /dev/kmsg || exit 2
	exec awk -v start="$m" -v src='exec cat /dev/kmsg 2>&1' "$PROG" ;;
--started)
	# --start runs in the background and writes its marker on its own
	# time, and a line the caller prints before the marker is before the
	# stream: a run marker written just after --start was lost that way.
	# So a caller waits here, up to 10 s, for the marker of a reader now
	# running, read from its command line, to reach the klog; an earlier
	# run's marker left in a klog the new reader has yet to truncate does
	# not count. A wait that runs out says so as a stream line, which every
	# caller refuses.
	k=${2:-}; n=0; rm -f "$k.lag"
	until started "$k" || [ $n -ge 100 ]; do sleep 0.1; n=$((n + 1)); done
	started "$k" || echo "stream COULD-NOT-READ: no running reader's start marker reached $k in 10 s"
	exit 0 ;;
--end)
	k=${2:-}
	[ -f "$k" ] || { echo "stream COULD-NOT-READ: no klog $k"; exit 0; }
	m="h2kmsg-end $(cat /proc/sys/kernel/random/uuid)"
	# ring-flood.sh installs this file, which runs once, for its control
	test -x /var/lib/h2stream-flood && /var/lib/h2stream-flood
	echo "$m" > /dev/kmsg
	n=0; until grep -q "^\[ *[0-9]*\.[0-9]*\] $m\$" "$k" || [ $n -ge 300 ]; do sleep 0.1; n=$((n + 1)); done
	verdict "$k" "$m"
	exit 0 ;;
--read)
	k=${2:-}
	[ -f "$k" ] && rd "$k" /dev/kmsg 30
	exec cat "$k" ;;
--render)
	exec awk -v start= -v src='exec cat' "$PROG" ;;
--stop)
	# A reader is the awk --start became, whose arguments carry its
	# marker; its cat ends at the next record it cannot write. The
	# bracket keeps this pattern from matching a shell that names it.
	pkill -f 'h2kmsg[-]start ' 2>/dev/null
	exit 0 ;;
*)	echo "kmsg-stream: COULD-NOT-RUN: --start, --started, --end or --read <klog>, --render, --stop or --selftest" >&2; exit 2 ;;
esac

# The selftest renders a fixture of raw records and compares the result
# with the layout dmesg prints for the same records. Where this host's
# dmesg reads a kmsg file (-K, which takes records separated by NUL), that
# layout is re-derived from util-linux itself rather than taken from the
# text below.
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
S=h2kmsg-start\ 11111111-2222-3333-4444-555555555555
{
	printf '%s\n' "6,90,1000000,-;h2kmsg-start 00000000-old-run" "6,91,1000001,-;an earlier run's line"
	printf '%s\n' "6,100,12345678,-;$S"
	printf '%s\n' '4,101,12345679,-;hammer2: a plain line' ' SUBSYSTEM=block' ' DEVICE=b8:0'
	printf '%s\n' '4,102,12400000,-;WARNING: CPU: 0 PID: 1\x0afirst\x0asecond' '6,103,99999999999,-;tab\x09and back\x5cslash and \x5cx0a literal'
	printf '%s\n' '3,104,7,-;ctl \x1b and \x7f kept' '6,105,123456789012,c;continued'
} > "$T/raw"
cat > "$T/want" <<'EOF'
[   12.345678] h2kmsg-start 11111111-2222-3333-4444-555555555555
[   12.345679] hammer2: a plain line
[   12.400000] WARNING: CPU: 0 PID: 1
               first
               second
[99999.999999] tab	and back\slash and \x0a literal
[    0.000007] ctl \x1b and \x7f kept
[123456.789012] continued
h2kmsg: the reader ended
EOF
fail=0
awk -v start="$S" -v src="cat $T/raw" "$PROG" > "$T/got" 2>&1
if cmp -s "$T/want" "$T/got"; then echo "  ok   the fixture renders as dmesg prints it, from its start marker"
else echo "  FAIL the fixture renders differently:"; diff "$T/want" "$T/got" | sed 's/^/        /'; fail=1; fi
# Each record keeps its newline before the NUL, as a read of /dev/kmsg
# returns it: dmesg drops a record's last byte as that newline.
printf '6,1,5,-;probe\n\0' > "$T/probe"	# dmesg cannot map an empty file
if dmesg -K "$T/probe" 2>/dev/null | command grep -qxF '[    0.000005] probe'; then
	command grep -v '^ ' "$T/raw" | sed -n '/h2kmsg-start 1111/,$p' |
	    while IFS= read -r l; do printf '%s\n\0' "$l"; done > "$T/nul"
	LC_ALL=C dmesg -K "$T/nul" > "$T/dm" 2>&1
	if sed '$d' "$T/want" | cmp -s - "$T/dm"; then echo "  ok   util-linux $(dmesg --version | sed 's/.* //') prints the fixture as expected above"
	else echo "  FAIL util-linux prints the fixture differently from the expectation:"; sed '$d' "$T/want" | diff - "$T/dm" | sed 's/^/        /'; fail=1; fi
else
	echo "  --   this host's dmesg reads no kmsg file, so the expectation is not re-derived here"
fi
# A gap in the sequence numbers is a line in the stream, and so is a reader
# that ends; --end refuses on either.
printf '%s\n' "6,1,1,-;$S" '6,2,2,-;a' '6,5,3,-;b' > "$T/gap"
awk -v start="$S" -v src="cat $T/gap" "$PROG" > "$T/gapk"
if command grep -qx 'h2kmsg: COULD-NOT-READ: records 3 to 4 were lost' "$T/gapk"; then echo "  ok   a skipped sequence number prints the records lost"
else echo "  FAIL a skipped sequence number printed nothing:"; sed 's/^/        /' "$T/gapk"; fail=1; fi
# A ring read whole from boot begins at sequence 0, which is no gap.
printf '%s\n' '6,0,1,-;first' '6,1,2,-;second' > "$T/zero"
awk -v start= -v src="cat $T/zero" "$PROG" > "$T/zerok"
if command grep -q '^h2kmsg: COULD' "$T/zerok"; then echo "  FAIL a stream from sequence 0 printed a gap:"; sed 's/^/        /' "$T/zerok"; fail=1
else echo "  ok   a stream from sequence 0 prints no gap"; fi
# --end's verdict, on a klog per case: whole only with both markers and
# nothing from the reader or cat between them.
E='h2kmsg-end 99999999-0000-0000-0000-000000000000'
st="[    1.000000] $S"; en="[    2.000000] $E"
for c in "whole:$st|[    1.500000] a line|$en" "COULD-NOT-READ: h2kmsg: COULD-NOT-READ: records 3 to 4:$st|h2kmsg: COULD-NOT-READ: records 3 to 4 were lost|$en" \
    "COULD-NOT-READ: h2kmsg: the reader ended:$st|h2kmsg: the reader ended" "COULD-NOT-READ: cat: /dev/kmsg: Broken pipe:$st|cat: /dev/kmsg: Broken pipe" \
    "COULD-NOT-READ: the end marker did not arrive:$st" "COULD-NOT-READ: the end marker did not arrive:$st|${en}0" "COULD-NOT-READ: the start marker is not in the klog:[    1.000000] an earlier line|$en"; do
	want=${c%%:\[*}; printf '%s\n' "${c#"$want":}" | tr '|' '\n' > "$T/v"
	got=$(verdict "$T/v" "$E")
	case "$got" in
	"stream $want"*) echo "  ok   a klog of $(wc -l < "$T/v") line(s) reads $got" ;;
	*) echo "  FAIL a klog of $(wc -l < "$T/v") line(s) read \"$got\", not stream $want"; fail=1 ;;
	esac
done
# and refuses a klog whole by its markers when a count's wait ran out
printf '%s\n' "$st" "$en" > "$T/v"; echo "a count's marker did not arrive in 30 s" > "$T/v.lag"
got=$(verdict "$T/v" "$E")
case "$got" in
"stream COULD-NOT-READ: a count's marker did not arrive"*) echo "  ok   a whole klog beside a count's wait that ran out reads $got" ;;
*) echo "  FAIL a whole klog beside a count's wait that ran out read \"$got\""; fail=1 ;;
esac
# A count read through rd() waits for what is on the way. A file stands in
# for the device and a subshell for the reader, rendering what the file
# holds half a second later. A line written before the read is missing from
# the klog when the read starts, which is the lag a count read at once
# would take for the whole log, and must be in it when rd() returns.
: > "$T/k"; echo "act" > "$T/dev"
( sleep 0.5; sed 's/^/[    3.000000] /' "$T/dev" >> "$T/k" ) &
b=$(command grep -c 'act$' "$T/k")
rd "$T/k" "$T/dev" 5; r=$?
a=$(command grep -c 'act$' "$T/k"); wait	# read as rd() returns, not once the stand-in is done
if [ "$b" = 0 ] && [ "$r" = 0 ] && [ "$a" = 1 ] && [ ! -e "$T/k.lag" ]; then echo "  ok   a count through rd() reads a line the reader had yet to write (0 before, 1 after)"
else echo "  FAIL rd() status $r: the line read $b before and $a after, lag file $(test -e "$T/k.lag" && echo present || echo absent)"; fail=1; fi
# With no reader the wait runs out, leaves the lag file, and the next read
# returns at once rather than waiting again.
: > "$T/k"
rd "$T/k" "$T/dev" 1; r=$?
if [ "$r" = 1 ] && command grep -qx "a count's marker did not arrive in 1 s" "$T/k.lag"; then echo "  ok   a wait with no reader runs out and leaves the lag file"
else echo "  FAIL a wait with no reader returned $r, lag file: $(cat "$T/k.lag" 2>/dev/null || echo absent)"; fail=1; fi
( rd "$T/k" "$T/dev" 100 ) & rp=$!
sleep 1
if kill -0 "$rp" 2>/dev/null; then echo "  FAIL a read after a wait ran out waits again"; kill "$rp"; fail=1
else echo "  ok   a read after a wait ran out does not wait again"; fi
wait "$rp" 2>/dev/null
# --started waits for the marker of a reader now running: a stand-in whose
# command line carries one, beside an earlier run's marker in the klog.
U=0000aaaa-1111-2222-3333-444455556666
sh -c 'sleep 30; :' h2kmsg "h2kmsg-start $U" & sp=$!
# and a command line whose token is a prefix of the earlier run's marker
sh -c 'sleep 30; :' h2kmsg "h2kmsg-start 0000bbbb" & sq=$!
sleep 0.2
echo "[    1.000000] h2kmsg-start 0000bbbb-1111-2222-3333-444455556666" > "$T/s"
if started "$T/s"; then echo "  FAIL an earlier run's marker counts as the running reader's"; fail=1
else echo "  ok   an earlier run's marker does not count as the running reader's, nor for a prefix of it"; fi
kill "$sq" 2>/dev/null
echo "[    2.000000] h2kmsg-start $U" >> "$T/s"
if started "$T/s"; then echo "  ok   the running reader's marker counts"
else echo "  FAIL the running reader's marker does not count"; fail=1; fi
kill "$sp" 2>/dev/null
[ "$fail" = 0 ] || { echo "kmsg-stream: selftest FAILED"; exit 1; }
echo "kmsg-stream: selftest ok"
