#!/bin/sh
# THE DIRECTORY IS THE POPULATION. Three lists claim to cover it and none of
# them is derived from it, so each can silently fall behind:
#
#   1. README.status.md's origin table - what each file is and where it came
#      from. A carried file with no row has no recorded provenance, which is
#      the one thing this port cannot reconstruct later.
#   2. the Makefile's `hammer2-y` - what actually gets compiled into the
#      module. A .c absent from it is dead code that still passes review.
#   3. script/test-syntax.sh - which files the compile gate names. It names
#      them one by one rather than enumerating, so a .c nobody adds to it is
#      never compiled and the gate still reports every check passing.
#
# All three fail the same way: quietly, in the direction that reads as
# healthy. That matters most during an import, which is exactly when files
# arrive in bulk - so this gate exists BEFORE the import rather than after
# it, which is the only useful time to write it.
#
# Exit 2 is COULD-NOT-RUN. Exit 1 is a count of failed assertions.
set -u
cd "$(dirname "$0")/.." || exit 2

DIR=src/sys/fs/hammer2
[ -d "$DIR" ] || { echo "inventory: COULD-NOT-RUN: no $DIR"; exit 2; }
STATUS=doc/README.status.md
MK=$DIR/Makefile
SYN=script/test-syntax.sh
for f in "$STATUS" "$MK" "$SYN"; do
	[ -f "$f" ] || { echo "inventory: COULD-NOT-RUN: no $f"; exit 2; }
done

srcs=$(ls "$DIR"/*.c 2>/dev/null | xargs -r -n1 basename)
hdrs=$(ls "$DIR"/*.h 2>/dev/null | xargs -r -n1 basename)

# THE POPULATION IS ASSERTED BEFORE ANYTHING IS CHECKED. A glob that matches
# nothing makes every loop below vacuous, and a run with zero findings is
# what this gate looks like when it is working.
[ -n "$srcs" ] || { echo "inventory: FAIL: no .c files in $DIR at all" >&2; exit 1; }
[ -n "$hdrs" ] || { echo "inventory: FAIL: no .h files in $DIR at all" >&2; exit 1; }

fail=0; nc=0; nh=0

for f in $srcs $hdrs; do
	case "$f" in *.c) nc=$((nc+1));; *) nh=$((nh+1));; esac
	# The origin table backticks the bare filename. sys/tree.h and
	# sys/queue.h are vendored one directory up and are listed together,
	# which is why this asks about $DIR's own files only.
	grep -q "\`$f\`" "$STATUS" || {
		echo "  FAIL $f: no origin row in $STATUS"; fail=$((fail+1)); }
done

for f in $srcs; do
	o=$(printf '%s' "$f" | sed 's/\.c$/.o/')
	grep -q "hammer2-y.*$o\|^[[:space:]]*hammer2-y[[:space:]]*+=[[:space:]]*$o" "$MK" || {
		echo "  FAIL $f: not in hammer2-y, so it is not compiled into the module"
		fail=$((fail+1)); }
	grep -q "$DIR/$f" "$SYN" || {
		echo "  FAIL $f: not named in $SYN, so no compiler ever sees it"
		fail=$((fail+1)); }
done

echo "inventory: $nc source file(s), $nh header(s), $fail finding(s)"
[ "$fail" = 0 ] || exit 1
