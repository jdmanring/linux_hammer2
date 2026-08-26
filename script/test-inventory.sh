#!/bin/sh
# THE DIRECTORY IS THE POPULATION. Three lists claim to cover it and none of
# them is derived from it, so each can silently fall behind:
#
#   1. README.status.md's origin table - what each file is, where it came
#      from, and how long it is. A carried file with no row has no recorded
#      provenance, which is the one thing this port cannot reconstruct
#      later. The LINE COUNT in that row is checked too, because it is the
#      one column that goes stale on an ordinary edit rather than on an
#      import: measured 2026-08-25, hammer2_os.h had drifted 471 -> 473 and
#      hammer2_compat.h 112 -> 111 with nothing to notice. A number in a
#      published table that nothing derives is a number that rots.
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
	#
	# ANCHORED ON THE FIRST COLUMN. An unanchored match plus `head -1`
	# takes whichever row MENTIONS the file first, and a row's origin
	# note names other files: on 2026-08-26 hammer2_chain.c landed and
	# this read hammer2_mount.h's row, whose note says "hammer2_chain.c
	# includes it", then reported the new 4929-line file as a 58-line
	# one. The wrong row is a worse failure than no row, because it
	# compares a real number against a real number and so reads as a
	# finding about the file rather than about this line. `command grep`
	# because only it ignores no ignore file.
	row=$(command grep "^| \`$f\` |" "$STATUS" | head -1)
	if [ -z "$row" ]; then
		echo "  FAIL $f: no origin row in $STATUS"; fail=$((fail+1))
		continue
	fi
	# The row is `| \`name\` | <lines> | <origin> |`, so the leading pipe
	# makes the line count the THIRD pipe-delimited field, not the second.
	# Take the text between the second and third pipes. A field that is
	# not a number is not a count row and is left alone rather than
	# guessed at, so a table that changes shape reports nothing here
	# instead of reporting every file wrong.
	want=$(printf '%s' "$row" | sed -n 's/^[^|]*|[^|]*|\([^|]*\)|.*/\1/p' | tr -d ' ')
	case "$want" in
	''|*[!0-9]*) ;;
	*)
		have=$(wc -l < "$DIR/$f")
		[ "$want" = "$have" ] || {
			echo "  FAIL $f: origin row says $want lines, file has $have"
			fail=$((fail+1)); }
		;;
	esac
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

# THE SECOND POPULATION IS test/, AND IT HAD NOBODY COUNTING IT. Measured
# 2026-08-26: crc32c-vectors.c and xxh64-vectors.c are tracked, are named by
# no gate here and by no document, and one of them includes a header that is
# not in this tree. A test file that nothing runs reads exactly like a test
# file that passes, which is the failure this whole gate exists to close -
# and the population it was written against was src/ only, so the class
# stayed open one directory away.
#
# WHAT THIS GATE CANNOT SEE, stated because the first version of this
# comment asserted the opposite: it cannot tell whether anything runs a
# file, only whether something here NAMES it. Both of those two are
# compiled by a gate in another repository, which no search of this tree
# could report; README.testing.md holds that contract. So a finding here
# means unaccounted-for, never unused.
#
# Accounted for means one of two things, and the second is deliberate: a
# gate names it (directly, or by a directory a gate passes with -I), or
# README.testing.md lists it as staged and says what it waits for. A file
# that is neither is a finding.
TESTDIR=test
TESTDOC=doc/README.testing.md
[ -d "$TESTDIR" ] || { echo "inventory: COULD-NOT-RUN: no $TESTDIR"; exit 2; }
[ -f "$TESTDOC" ] || { echo "inventory: COULD-NOT-RUN: no $TESTDOC"; exit 2; }

tests=$(find "$TESTDIR" -type f | LC_ALL=C sort)
[ -n "$tests" ] || { echo "inventory: FAIL: no files under $TESTDIR at all" >&2; exit 1; }

nt=0
for f in $tests; do
	nt=$((nt+1))
	# Walk the path's own prefixes, because a gate that passes
	# `-I test/stub` names the directory and never the headers in it.
	# The walk stops before the bare top directory on purpose: `test`
	# alone is a substring of every `script/test-*.sh` filename, so
	# testing it would pass every file in the tree on a coincidence.
	ref=
	p=$f
	while [ "${p%/*}" != "$p" ]; do
		if command grep -q -F -- "$p" script/*.sh; then ref=$p; break; fi
		p=${p%/*}
	done
	[ -n "$ref" ] && continue
	command grep -q -F -- "$f" "$TESTDOC" || {
		echo "  FAIL $f: no gate names it and $TESTDOC does not list it"
		fail=$((fail+1)); }
done

# THE THIRD POPULATION IS THE GATE COUNT ITSELF, which five documents state
# in prose and nothing derived. This repository has already been bitten by
# it once (0.1.10: three gates existed that no document mentioned), and
# adding a seventh on 2026-08-26 falsified the word "six" in five files at
# the same instant. A count in a published document that nothing derives is
# a number that rots - the same sentence the origin table's line count is
# checked for, one level up.
#
# The documents are READ AS ONE LINE, because prose wraps: "All six" ended a
# line in CONTRIBUTING.md with "gates are cheap" on the next, and a
# line-at-a-time matcher cannot see the phrase at all. A rule about writing
# does not fire while you are reading output; this one is about reading.
# THE COUNT AND THE LIST ARE DIFFERENT CLAIMS. A document can say "eight
# gates" correctly and enumerate seven of them, which is what the agent
# instructions file did on 2026-08-26 before it was untracked: the count
# check passed while the list a future reader runs was missing the newest
# gate. These print runnable command lists, so every gate must appear in
# each; documents that merely MENTION a gate are not in this set, since
# requiring all of them there would be wrong.
LIST_DOCS="README.md CONTRIBUTING.md"
for d in $LIST_DOCS; do
	[ -f "$d" ] || continue
	for g in script/test-*.sh; do
		command grep -qF -- "$(basename "$g")" "$d" || {
			echo "  FAIL $d: does not name $(basename "$g")"
			fail=$((fail+1)); }
	done
done

COUNT_DOCS="README.md CONTRIBUTING.md doc/README.testing.md doc/README.status.md"
ngates=$(ls script/test-*.sh 2>/dev/null | wc -l | tr -d ' ')
[ "$ngates" -gt 0 ] || { echo "inventory: FAIL: no test-*.sh in script/ at all" >&2; exit 1; }
word=$(awk -v n="$ngates" 'BEGIN{split("one two three four five six seven eight nine ten",w," "); print (n>=1 && n<=10) ? w[n] : ""}')
for d in $COUNT_DOCS; do
	[ -f "$d" ] || continue
	# Any number word immediately before "gate"/"gates" is a claim about
	# this count. Partial counts must not be written in that shape; say
	# "the compile gates" rather than "three gates".
	claims=$(tr '\n' ' ' < "$d" | tr -s ' ' |
		command grep -oiE '(one|two|three|four|five|six|seven|eight|nine|ten) gates?' |
		awk '{print tolower($1)}' | LC_ALL=C sort -u)
	for c in $claims; do
		[ "$c" = "$word" ] && continue
		echo "  FAIL $d: says \"$c gates\" where script/ holds $ngates"
		fail=$((fail+1))
	done
done

echo "inventory: $nc source file(s), $nh header(s), $nt test file(s), $ngates gate(s), $fail finding(s)"
[ "$fail" = 0 ] || exit 1
