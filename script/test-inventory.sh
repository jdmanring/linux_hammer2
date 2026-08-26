#!/bin/sh
# The directory is the population. Three lists claim to cover it, none of them
# derived from it, so each can fall behind without saying so:
#
#   1. README.status.md's origin table - what each file is, where it came
#      from, and how long it is. A carried file with no row has no recorded
#      provenance, which is the one thing this port cannot reconstruct
#      later. The line count in that row is checked too, being the one column
#      that goes stale on an ordinary edit rather than on an import: measured
#      2026-08-25, hammer2_os.h had drifted 471 -> 473 and hammer2_compat.h
#      112 -> 111 with nothing to notice.
#   2. the Makefile's `hammer2-y` - what actually gets compiled into the
#      module. A .c absent from it is dead code that still passes review.
#   3. script/test-syntax.sh - which files the compile gate names. It names
#      them one by one rather than enumerating, so a .c nobody adds to it is
#      never compiled and the gate still reports every check passing.
#
# All three fail quietly, in the direction that reads as healthy, and they do
# it during an import, when files arrive in bulk. So this gate was written
# before the 0.2 import rather than after it.
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

# Assert the population before checking anything. A glob that matches nothing
# makes every loop below vacuous, and zero findings is also what this gate
# looks like when it is working.
[ -n "$srcs" ] || { echo "inventory: FAIL: no .c files in $DIR at all" >&2; exit 1; }
[ -n "$hdrs" ] || { echo "inventory: FAIL: no .h files in $DIR at all" >&2; exit 1; }

fail=0; nc=0; nh=0

for f in $srcs $hdrs; do
	case "$f" in *.c) nc=$((nc+1));; *) nh=$((nh+1));; esac
	# The origin table backticks the bare filename. sys/tree.h and
	# sys/queue.h are vendored one directory up and are listed together,
	# which is why this asks about $DIR's own files only.
	#
	# Anchored on the first column. An unanchored match plus `head -1`
	# takes whichever row mentions the file first, and a row's origin
	# note names other files: hammer2_chain.c landed on 2026-08-26 and
	# this read hammer2_mount.h's row, whose note says "hammer2_chain.c
	# includes it", then reported the new 4929-line file as 58 lines.
	# The wrong row is worse than no row, since it compares one real
	# number against another and so reads as a finding about the file.
	# `command grep` because only it honours no ignore file.
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

# The second population is test/, which nothing counted until 2026-08-26.
# crc32c-vectors.c and xxh64-vectors.c are tracked, named by no gate and no
# document here, and one includes a header that is not in this tree. A test
# file nothing runs reads the same as one that passes.
#
# This gate cannot tell whether anything runs a file, only whether something
# here names it. Both of those two are compiled by a gate in another
# repository, which no search of this tree can see; README.testing.md holds
# that contract. A finding here means unaccounted-for, never unused.
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

# The third population is the gate count itself, stated in prose by five
# documents and derived by nothing. At 0.1.10 three gates existed that no
# document mentioned, and adding a seventh on 2026-08-26 falsified the word
# "six" in five files at once.
#
# The documents are read as one line, because prose wraps: "All six" ended a
# line in CONTRIBUTING.md with "gates are cheap" on the next, where a
# line-at-a-time matcher sees no phrase at all.
#
# The count and the list are separate claims. A document can say "eight gates"
# correctly and enumerate seven, which is what the agent instructions file did
# on 2026-08-26 before it was untracked: the count passed while the list a
# reader actually runs was missing the newest gate. The documents below print
# runnable command lists, so every gate must appear in each. Documents that
# only mention a gate in passing are not in this set.
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

# EVERY `DEFER(` IN src/ IS A ROW IN doc/README.status.md's LEDGER, AND
# EVERY ROW IS A MARKER THAT STILL EXISTS. A deferral is only pragmatism
# while its trigger is written down, and the ledger is the only place the
# four are collected; a marker deleted from the source leaves a row that
# reads as outstanding work forever, which is the reassuring direction.
#
# The population is asserted first. A tree with no DEFER markers at all is
# a possible and correct state, but it is also what a broken pattern looks
# like, so the two are separated: zero markers is reported, not passed
# over in silence.
# mktemp with a trap, matching test-posix.sh, rather than $$ in /tmp: a
# predictable name in a shared directory is another user's to create, and
# the errors from the loops below are not discarded, since a gate that can
# fail silently is the thing this check exists to prevent.
LEDGER=doc/README.status.md
dtmp=$(mktemp -d) || exit 2
trap 'rm -rf "$dtmp"' EXIT
defers=$(command grep -rhoE 'DEFER\([^)]*\)' src/ | LC_ALL=C sort -u)
ndefer=$(printf '%s' "$defers" | command grep -c . || true)
if [ "$ndefer" = 0 ]; then
	echo "  note src/ holds no DEFER markers, so the ledger check below"
	echo "       compared nothing"
else
	printf '%s\n' "$defers" | while IFS= read -r d; do
		command grep -qF -- "$d" "$LEDGER" ||
			echo "  FAIL $LEDGER: no ledger row for $d"
	done > "$dtmp/missing"
	if [ -s "$dtmp/missing" ]; then
		cat "$dtmp/missing"
		fail=$((fail + $(command grep -c . "$dtmp/missing")))
	fi

	# The other direction. A marker deleted from the source leaves a row
	# that reads as outstanding work forever, and nothing else here would
	# notice: the check above only walks src/.
	rows=$(command grep -oE 'DEFER\([^)]*\)' "$LEDGER" | LC_ALL=C sort -u)
	nrows=$(printf '%s' "$rows" | command grep -c . || true)
	if [ "$nrows" = 0 ]; then
		echo "  FAIL $LEDGER: src/ holds $ndefer DEFER marker(s) and the"
		echo "       ledger table has no row at all, so the check above"
		echo "       matched against nothing"
		fail=$((fail + 1))
	else
		printf '%s\n' "$rows" | while IFS= read -r r; do
			command grep -rqF -- "$r" src/ ||
				echo "  FAIL $LEDGER: row for $r, which src/ no longer holds"
		done > "$dtmp/stale"
		if [ -s "$dtmp/stale" ]; then
			cat "$dtmp/stale"
			fail=$((fail + $(command grep -c . "$dtmp/stale")))
		fi
	fi
fi

echo "inventory: $nc source file(s), $nh header(s), $nt test file(s), $ngates gate(s), $ndefer DEFER(s), $fail finding(s)"
[ "$fail" = 0 ] || exit 1
