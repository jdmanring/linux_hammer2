#!/usr/bin/env bash
# The cluster transport's deterministic loopback does what each knob says,
# and a run replays from its recorded seed.
#
# Proves: test/h2loop.c, the userland simulator that sits where DragonFly's
# hammer2 service daemon sits, delivers frames over a real AF_UNIX stream
# socketpair with the framing kern_dmsg.c reads, and that its seven knobs
# each move the one count that measures them: delay, loss, duplication,
# reordering, disconnect, reconnect, and a trace that reproduces from its
# first line.  Each knob is read beside a control with the knob off, whose
# count must be zero, and the replay is read beside a trace edited by hand,
# which must not reproduce.  Those controls exist because a simulator that
# delivers everything prints the same summary as one whose loss knob works
# when loss is 0, and a replay that agrees with its input instead of
# reading it passes any file.
#
# Cannot prove: that the kernel reads what the receiver here reads.  The
# kernel's end of the socketpair is played by a generator and a receiver in
# the same process until the message core is carried (P6); the frame the
# receiver checks is the frame kdmsg_iocom_thread_rd checks, plus the two
# CRCs the kernel leaves to userland.  doc/README.porting.md has the
# transport contract this measures against.
#
# Needs nothing but a C compiler.  Runs in well under a second.
set -u
cd "$(dirname "$0")/.." || exit 2
CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || { echo "transport: COULD-NOT-RUN: no $CC"; exit 2; }

T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT

fail=0 ran=0
ok()   { ran=$((ran + 1)); echo "  ok    $1"; }
bad()  { ran=$((ran + 1)); fail=$((fail + 1)); echo "  FAIL  $1"; }
check() { # name test...
	local name="$1"; shift
	if [ "$@" ]; then ok "$name"; else bad "$name"; fi
}

echo "hammer2 transport loopback, with $("$CC" --version | head -1):"
if ! "$CC" -std=c11 -Wall -Wextra -Werror -O1 -o "$T/h2loop" test/h2loop.c >"$T/cc.out" 2>&1; then
	echo "  FAIL  test/h2loop.c compiles"
	sed 's/^/        /' "$T/cc.out" | head -10
	echo "transport: 1 check(s), 1 failed"
	exit 1
fi
ok "test/h2loop.c compiles with -Wall -Wextra -Werror"

# run NAME ARGS...: one run, its summary in $T/NAME.sum and trace in
# $T/NAME.trace.  Every run is 200 frames of seed 7 unless the args say
# otherwise, so the controls differ from their subjects by one knob.
run() {
	local name="$1"; shift
	"$T/h2loop" --seed 7 --frames 200 "$@" --trace "$T/$name.trace" >"$T/$name.sum" 2>&1
	echo "$?" >"$T/$name.rc"
}
# n NAME FIELD: the count after FIELD on the summary line.  A missing line
# or field yields an empty string, which every numeric test below refuses;
# the one arithmetic check substitutes a value no equality accepts, since
# bash aborts a command on an empty arithmetic operand and the check would
# otherwise vanish uncounted.
n() { sed -n "s/^h2loop: .*\b$2 \([0-9]*\).*/\1/p" "$T/$1.sum" | head -1; }
# traced NAME PATTERN: how many trace lines match; the count, not the status.
# A missing trace is "missing", not 0: a zero here is a verdict several
# controls accept, so the fallback has to fail toward fault.
traced() {
	local c
	[ -s "$T/$1.trace" ] || { echo missing; return; }
	c=$(grep -c -E "$2" "$T/$1.trace"); echo "$c"
}

run plain
run delay       --delay-max 50
run loss        --loss 0.2
run dup         --dup 0.2
run halfclose   --halfclose-at 50
run disconnect  --disconnect-at 50
run reconnect   --disconnect-at 50 --reconnect-at 60
run corrupt     --corrupt-at 7
run combined    --halfclose-at 10 --disconnect-at 20
run again       --delay-max 50
run otherseed   --delay-max 50 --seed 8

# The population: every run printed a summary line, before anything is read
# from one.  A run that crashed leaves no line and would read as every count
# zero, which half the controls below accept.
for r in plain delay loss dup halfclose disconnect reconnect corrupt combined again otherseed; do
	if grep -q '^h2loop: sent' "$T/$r.sum" && grep -q '^h2loop seed=' "$T/$r.trace"; then :; else
		bad "run $r printed a summary and a trace (rc $(cat "$T/$r.rc"))"
		sed 's/^/        /' "$T/$r.sum" | head -3
	fi
done
[ "$fail" -eq 0 ] || { echo "transport: $ran check(s), $fail failed"; exit 1; }
ok "11 runs, 11 summaries, 11 traces"

# Every knob off: everything sent arrives once, in order, intact, and the
# one EOF is the daemon closing at the end of the run.
check "plain: 200 sent, 200 delivered"       "$(n plain sent)" = 200 -a "$(n plain delivered)" = 200
check "plain: nothing dropped, duplicated, reordered or rejected" \
	"$(n plain dropped)" = 0 -a "$(n plain dup)" = 0 -a "$(n plain reordered)" = 0 -a "$(n plain rejected)" = 0
check "plain: one EOF, at the end"           "$(n plain eof)" = 1 -a "$(n plain epipe)" = 0
check "plain: control, no delay in the trace"  "$(traced plain ' d=[1-9]')" = 0

# delay and reorder: the same knob, two readings.  Delivery is complete,
# the trace carries non-zero delays, and the receiver saw frames out of
# order; the control is the plain run above with both at zero.
check "delay: 200 delivered under delay"     "$(n delay delivered)" = 200
check "delay: trace carries non-zero delays" "$(traced delay ' d=[1-9]')" -gt 0
check "reorder: receiver saw frames out of order" "$(n delay reordered)" -gt 0
check "reorder: control, plain run saw none"  "$(n plain reordered)" = 0

# loss: dropped plus delivered is what was sent, and dropped is non-zero
# with the knob on and zero with it off.
d=$(n loss dropped); v=$(n loss delivered)
check "loss: dropped + delivered = sent" \
	"$(( ${d:-900000} + ${v:-900000} ))" = "$(n loss sent)"
check "loss: dropped > 0 with loss 0.2"      "$(n loss dropped)" -gt 0
check "loss: receiver and trace agree on the drops" "$(n loss dropped)" = "$(traced loss ' drop ')"
check "loss: control, 0 dropped with loss 0"  "$(n plain dropped)" = 0

# duplication: the receiver's dup count is the trace's, and non-zero.
check "dup: receiver saw duplicates"         "$(n dup dup)" -gt 0
check "dup: receiver and trace agree"        "$(n dup dup)" = "$(traced dup ' dup ')"
check "dup: control, 0 with dup 0"           "$(n plain dup)" = 0

# half-close: the daemon stops sending after frame 50 but keeps reading, so
# the kernel's reader sees EOF once and exits, as kdmsg_iocom_thread_rd
# does, while its writer never sees EPIPE and every later frame is lost on
# the daemon's side.
check "halfclose: 51 delivered then one EOF" "$(n halfclose delivered)" = 51 -a "$(n halfclose eof)" = 1
check "halfclose: writer never saw EPIPE"    "$(n halfclose epipe)" = 0 -a "$(n halfclose sent)" = 200
check "halfclose: the rest lost at the daemon" "$(n halfclose lost)" = 149

# a half-close and then a disconnect on one connection is still one EOF:
# the kernel's reader exited at the first and nothing reads after it.
check "combined: half-close then disconnect, one EOF" "$(n combined eof)" = 1 -a "$(n combined disconnects)" = 1

# disconnect: after frame 50 the daemon shuts both directions and closes;
# the reader sees EOF and the writer EPIPE on every frame after.
check "disconnect: 51 delivered, reader EOF"  "$(n disconnect delivered)" = 51 -a "$(n disconnect eof)" = 1
check "disconnect: writer saw EPIPE 149 times" "$(n disconnect epipe)" = 149
check "disconnect: control, plain run saw no EPIPE" "$(n plain epipe)" = 0

# reconnect: a new pair at frame 60, as a new RECLUSTER would hand in; the
# nine frames between are the ones lost to EPIPE and everything after lands.
check "reconnect: one reconnect in the summary and the trace" \
	"$(n reconnect reconnects)" = 1 -a "$(traced reconnect ' reconnect ')" = 1
check "reconnect: 51 + 140 delivered, 9 EPIPE" \
	"$(n reconnect delivered)" = 191 -a "$(n reconnect epipe)" = 9
check "reconnect: control, without it delivery stops at 51" "$(n disconnect delivered)" = 51

# the receiver checks what the kernel does not: one flipped CRC bit is one
# rejection and one frame short.  The bit is in aux_crc, which is a header
# field, so the header CRC is what catches it: the format's hdr_crc covers
# aux_crc, and a receiver that reported aux_crc here would be checking the
# aux before the header.
check "corrupt: one frame rejected"          "$(n corrupt rejected)" = 1 -a "$(n corrupt delivered)" = 199
check "corrupt: the rejection names hdr_crc, which covers aux_crc" \
	"$(traced corrupt 'rejected hdr_crc msgid=7 ')" = 1
check "corrupt: control, plain run rejected none" "$(n plain rejected)" = 0

# reproducible trace: the same arguments give the same bytes, a different
# seed does not, and --replay reads the header and reproduces the run.
check "trace: same seed, identical trace"    "$(cmp -s "$T/delay.trace" "$T/again.trace"; echo $?)" = 0
check "trace: different seed, different trace" "$(cmp -s "$T/delay.trace" "$T/otherseed.trace"; echo $?)" = 1
"$T/h2loop" --replay "$T/delay.trace" >"$T/replay.out" 2>&1; rc=$?
check "replay: reproduces, exit 0"           "$rc" = 0 -a "$(grep -c reproduces "$T/replay.out")" = 1
# the control: a trace edited by hand must not reproduce.  The edit is to
# a decision line, not the header, so the replay runs the same arguments
# and the difference is in what it reads back.
sed '5s/d=[0-9]*/d=99/' "$T/delay.trace" >"$T/edited.trace"
"$T/h2loop" --replay "$T/edited.trace" >"$T/replay2.out" 2>&1; rc=$?
check "replay: control, an edited trace does not reproduce, exit 1" \
	"$rc" = 1 -a "$(grep -c DIFFERS "$T/replay2.out")" = 1
# a header edited past the frame cap would write a frame nobody reads and
# hang the lockstep; the replay has to refuse it as the command line would.
sed '1s/aux-max=[0-9]*/aux-max=4000000/' "$T/delay.trace" >"$T/edited2.trace"
timeout 10 "$T/h2loop" --replay "$T/edited2.trace" >"$T/replay3.out" 2>&1; rc=$?
check "replay: a header past the frame cap is refused, exit 2" "$rc" = 2

echo "transport: $ran check(s), $fail failed"
[ "$fail" -eq 0 ]
