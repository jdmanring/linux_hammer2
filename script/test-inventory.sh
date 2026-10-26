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

# Build artifacts are not source. kbuild writes .o, .ko, .mod, .mod.c, .cmd,
# .o.d, modules.order and Module.symvers beside the sources it compiles, and
# this gate had never seen a built tree until the first `make` on 2026-09-02.
# Against one it read those files as though they were the port's own. The
# patterns match .gitignore's, and .mod.c is listed separately because it
# ends in .c and so enters a *.c glob. .o.d was left out of both lists until
# 2026-09-26, and a bare `make` below the kernel floor writes one before the
# version #error stops the compile, so a failed build left a file that made
# test-provenance.sh fail on the next run.
NOTSRC='\.mod\.c$'
BUILT="--exclude=*.o --exclude=*.ko --exclude=*.mod --exclude=*.mod.c \
--exclude=*.cmd --exclude=*.o.d --exclude=*.order \
--exclude=*.symvers \
--exclude-dir=.tmp_versions"

srcs=$(ls "$DIR"/*.c 2>/dev/null | command grep -v "$NOTSRC" | xargs -r -n1 basename)
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

# The vendored headers under src/sys/sys have rows keyed `sys/NAME`, and
# the loop above never saw them: `sys/dmsg.h` carried 870 against a file
# of 875 for two commits with every sibling row exact.  Same check, same
# shape, over that directory.
for f in src/sys/sys/*.h; do
	[ -f "$f" ] || continue
	k=sys/$(basename "$f")
	# The origin row, not the XXX table's row for the same key: the
	# origin row's third field is prose, the XXX row's is a number.
	row=$(command grep "^| \`$k\` |" "$STATUS" |
		awk -F'|' '$4 !~ /^ *[0-9]+ *$/' | head -1)
	[ -n "$row" ] || continue	# the combined tree.h/queue.h row is a sum and has no single key
	want=$(printf '%s' "$row" | sed -n 's/^[^|]*|[^|]*|\([^|]*\)|.*/\1/p' | tr -d ' ')
	case "$want" in
	''|*[!0-9]*) ;;
	*)
		have=$(wc -l < "$f")
		[ "$want" = "$have" ] || {
			echo "  FAIL $k: origin row says $want lines, file has $have"
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

# The fourth population is the runner behind each runnable file under test/,
# and it exists because the check above cannot see one. A name in a document
# or a gate says the file is ACCOUNTED FOR, never that anything RUNS it, and
# three exercisers in three milestones were cited by a document with no
# runner at all: the fallocate one at 0.9.37, the fiemap one at 0.9.39 and
# test/getdents-resume.c at 0.9.40. Each was found by a hand sweep, which is
# why the class kept recurring; this is that sweep as a gate.
#
# Every .c under test/ that is not built by another repository must appear
# in script/*.sh somewhere other than a comment, which is where a run, a
# compile or a read of it lives. The two files compiled by Saxum through
# LINUX_HAMMER2 are named here and skipped, because neither a search of this
# tree nor this gate can see that consumer; README.testing.md holds that
# contract. Everything else under test/ is data a gate reads by path (the
# fixture manifests), a header reached through -I (test/stub), or a fixture
# whose path is built rather than named, so a .c is the right population and
# asserting it is non-empty is what keeps a sweep that matched nothing from
# passing.
FOREIGN_C="test/crc32c-vectors.c test/xxh64-vectors.c"
nrun=0
for f in $(find "$TESTDIR" -name '*.c' | LC_ALL=C sort); do
	case " $FOREIGN_C " in *" $f "*) continue;; esac
	nrun=$((nrun+1))
	# A commented-out mention reads the same as a live one, so comments are
	# stripped first. The invocation itself is what remains.
	command grep -h -F -- "$(basename "$f")" script/*.sh 2>/dev/null |
	    command grep -vE '^[[:space:]]*#' > /dev/null || {
		echo "  FAIL $f: no script compiles, runs or reads it, so"
		echo "        nothing here exercises it and its output is a"
		echo "        memory of a run rather than a reading. Wire it into"
		echo "        a gate, or name it in \$FOREIGN_C above if a"
		echo "        consumer outside this repository builds it."
		fail=$((fail+1)); }
done
[ "$nrun" -ge 8 ] || {
	echo "  FAIL: only $nrun runnable .c file(s) under $TESTDIR were checked,"
	echo "        so the runner sweep matched far less than it should"
	fail=$((fail+1)); }

# The fifth population is the build knobs. Every -D the Makefile passes must
# be read by a source file, because a knob that is defined and read by
# nothing is a documented no-op: HAMMER2_ATIME was defined, described in
# ARCHITECTURE.md, CLAUDE.md and README.md as turning atime updates on, and
# referenced by no line of C in the tree, so it changed nothing and the
# stored atime was reported whether it was set or not. No compile can catch
# this, because a knob that gates nothing compiles both ways; the gate is
# the reference count. The population is asserted non-empty so a Makefile
# whose -D lines moved cannot make this check vacuous.
knobs=$(command grep -oE '^ccflags-y \+= -D[A-Z_0-9]+' "$MK" |
    sed 's/.*-D//' | LC_ALL=C sort -u)
nk=$(printf '%s\n' "$knobs" | command grep -c . || true)
[ "${nk:-0}" -ge 3 ] || {
	echo "  FAIL: only ${nk:-0} build knob(s) were read from $MK, so this"
	echo "        sweep matched far less than the Makefile defines"
	fail=$((fail+1)); }
for k in $knobs; do
	command grep -rq "$k" "$DIR"/*.c "$DIR"/*.h 2>/dev/null || {
		echo "  FAIL $k: $MK defines it and no source file reads it, so"
		echo "        the knob is a documented no-op. Gate something with"
		echo "        it, or stop defining and documenting it."
		fail=$((fail+1)); }
done

# The third population is the gate count itself, stated in prose by the three
# documents below that carry such a sentence and derived by nothing. The count
# is a claim about four candidate documents and the gate asserts the population
# it actually read, because a wording change can quietly empty it: CONTRIBUTING
# said "Twelve of the fourteen are cheap" until 2026-10-13, which this matcher
# never saw, and README.testing.md refuses to state a count at all. At 0.1.10
# three gates existed that no document mentioned, and adding a seventh on
# 2026-08-26 falsified the word "six" in five files at once.
#
# The documents are read as one line, because prose wraps: "All six" ended a
# line in CONTRIBUTING.md with "gates are cheap" on the next, where a
# line-at-a-time matcher sees no phrase at all.
#
# The count and the list are separate claims. A document can say "eight gates"
# correctly and enumerate seven, which one instruction file did before it was
# untracked: the count passed while the list a
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
# The number words run past ten because the count does. The list stopped at
# `ten` while the gate count grew to sixteen, so every claim in every one of
# these documents sat above the pattern: the matcher found no claims at all
# and the loop below compared nothing, which read as a clean count. The
# documents said "Fifteen gates" and "Fourteen" against a tree holding
# sixteen, and this check reported 0 findings through all of it. A pattern
# narrower than the population is the same defect as a glob that matches
# nothing, so the word list is built to a number the gate count cannot pass
# without the count being noticed, and a claimed word that the list cannot
# name is a failure rather than a skip.
word=$(awk -v n="$ngates" 'BEGIN{
	split("one two three four five six seven eight nine ten",w," ");
	split("eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty",t," ");
	for (i = 1; i <= 10; i++) word[i] = w[i];
	for (i = 1; i <= 10; i++) word[i + 10] = t[i];
	print (n >= 1 && n <= 20) ? word[n] : ""}')
# The vocabulary the matcher can name, in the same order, so a document
# claim above it is caught rather than passed over.
vocab="one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty"
pat=$(printf '%s' "$vocab" | tr ' ' '|')
for d in $COUNT_DOCS; do
	[ -f "$d" ] || continue
	# Any number word immediately before "gate"/"gates" is a claim about
	# this count. Partial counts must not be written in that shape; say
	# "the compile gates" rather than "three gates".
	claims=$(tr '\n' ' ' < "$d" | tr -s ' ' |
		command grep -oiE "($pat) gates?" |
		awk '{print tolower($1)}' | LC_ALL=C sort -u)
	for c in $claims; do
		[ "$c" = "$word" ] && continue
		echo "  FAIL $d: says \"$c gates\" where script/ holds $ngates"
		fail=$((fail+1))
	done
	# The population, asserted. The check above can only see a count whose
	# word is in the vocabulary, so a document claiming a count outside it
	# would be invisible in exactly the way `fifteen` was while the list
	# stopped at ten. Catch that with the number words the language has
	# past twenty, and with the ordinals and quantifiers that read as a
	# count. Deliberately NOT `[a-z]+ gates?`: `shim gate`, `style gate`
	# and `fill gates` are noun phrases, not counts, and a sweep that
	# broad fails on the prose this family of documents is written in.
	unnamed=$(tr '\n' ' ' < "$d" | tr -s ' ' |
		command grep -oiE '\b(twenty-one|twenty-two|twenty-three|twenty-four|thirty|forty|fifty|sixty|dozens of|hundreds of) gates?\b' |
		LC_ALL=C sort -u)
	if [ -n "$unnamed" ]; then
		echo "  FAIL $d: states a gate count above this check's vocabulary:"
		printf '        %s\n' $unnamed
		fail=$((fail+1))
	fi
done
# The set above is a hand list, and a counted sentence in a document outside
# it is checked by nothing: doc/README.maintenance.md said "seventeen gates"
# for three days after the tree held eighteen, with every listed document
# correct. So every document that states the present, the top level and
# doc/, is read for the same phrase, and one carrying it must be in the set.
# CHANGELOG.md, doc/history/ and doc/README.roadmap.md hold dated readings
# of past trees and are not the present; doc/README.roadmap.md's live
# sections state no count for this reason.
for d in *.md doc/*.md; do
	[ -f "$d" ] || continue
	case " $COUNT_DOCS CHANGELOG.md doc/README.roadmap.md " in *" $d "*) continue;; esac
	stray=$(tr '\n' ' ' < "$d" | tr -s ' ' |
		command grep -oiE "($pat) gates?" | LC_ALL=C sort -u)
	[ -z "$stray" ] || {
		echo "  FAIL $d: states a gate count and is not in the count check's set:"
		printf '        %s\n' "$stray"
		fail=$((fail+1)); }
done

# Every `DEFER(` in the tree is a row in doc/README.status.md's ledger, and
# every row is a marker that still exists. A deferral is only pragmatism
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
# The population is src/, script/, test/ and .github/, not src/ alone. A
# deferral in a gate or a workflow is a deferral: CI grew one on 2026-09-02,
# where the module build asserts a link failure and has to invert once the
# module links. Scanning src/ only would have left that trigger written
# down nowhere the ledger could see, which is the condition DEFER exists to
# prevent. test/ joined on 2026-10-16, when the transport simulator carried
# the first marker there and this population did not see it. doc/ is
# excluded because the ledger itself lives there and would match every row.
# Three or more characters inside the parentheses, because this gate's own
# summary line ends with "DEFER(s)" and a pattern that can match the command
# that carries it reports itself. Every real trigger is a phrase.
defers=$(command grep -rhoE $BUILT 'DEFER\([^)]{3,}\)' src/ script/ test/ .github/ |
	LC_ALL=C sort -u)
ndefer=$(printf '%s' "$defers" | command grep -c . || true)
if [ "$ndefer" = 0 ]; then
	echo "  note src/ holds no DEFER markers, so the ledger check below"
	echo "       compared nothing"
else
	# Only ledger rows count. This read the whole document and any
	# mention satisfied it, so a marker whose row had been rewritten
	# under a new trigger stayed green on a sentence of narrative prose
	# elsewhere in the file that happened to name the old one. That is
	# the condition this check exists to catch, passing because the
	# population it compared against was the wrong one.
	#
	# The anchor is the ledger's own column shape, a trigger in the
	# SECOND column, the way test-citations.sh anchors on a citation in
	# the first. Every table in this file starts its rows with a `|`,
	# and the origin table's third column is free prose that may name a
	# trigger while explaining what a file defers, so "any table row"
	# is a population that admits the same failure through a different
	# sentence.
	command grep -E '^\|[^|]*\| *`DEFER\([^)]{3,}\)` *\|' "$LEDGER" \
		> "$dtmp/rows" || :
	if [ ! -s "$dtmp/rows" ]; then
		echo "  FAIL $LEDGER: no ledger rows matched the table's own"
		echo "       column shape, so the checks below would compare"
		echo "       against nothing"
		fail=$((fail + 1))
	fi
	printf '%s\n' "$defers" | while IFS= read -r d; do
		command grep -qF -- "$d" "$dtmp/rows" ||
			echo "  FAIL $LEDGER: no ledger row for $d"
	done > "$dtmp/missing"
	if [ -s "$dtmp/missing" ]; then
		cat "$dtmp/missing"
		fail=$((fail + $(command grep -c . "$dtmp/missing")))
	fi

	# The other direction. A marker deleted from the source leaves a row
	# that reads as outstanding work forever, and nothing else here would
	# notice: the check above only walks the population.
	rows=$(command grep -oE 'DEFER\([^)]{3,}\)' "$dtmp/rows" | LC_ALL=C sort -u)
	nrows=$(printf '%s' "$rows" | command grep -c . || true)
	if [ "$nrows" = 0 ]; then
		echo "  FAIL $LEDGER: the tree holds $ndefer DEFER marker(s) and the"
		echo "       ledger table has no row at all, so the check above"
		echo "       matched against nothing"
		fail=$((fail + 1))
	else
		printf '%s\n' "$rows" | while IFS= read -r r; do
			command grep -rqF $BUILT -- "$r" src/ script/ test/ .github/ ||
				echo "  FAIL $LEDGER: row for $r, which the tree no longer holds"
		done > "$dtmp/stale"
		if [ -s "$dtmp/stale" ]; then
			cat "$dtmp/stale"
			fail=$((fail + $(command grep -c . "$dtmp/stale")))
		fi
	fi
fi

# The `XXX` table in doc/README.status.md is a count, and 0.2's fourth exit
# criterion turns on it. Its total column is `grep -c XXX` and nothing more,
# so it is mechanically checkable and was drifting instead: measured
# 2026-08-26, the table omitted `hammer2_disk.h` and `src/sys/sys/tree.h`,
# both of which carry a mark, while listing `hammer2_cluster.c` at zero,
# which is what makes the table read as a full inventory of a population it
# did not cover.
#
# What is checked and what deliberately is not. The `upstream's` and `this
# port's` columns are a subtraction against the FreeBSD tree at 3df307f,
# which is not on most machines, so a gate over them would exit 2 forever
# and never actually run. They stay prose carrying their dated measurement.
# The total, and the population, are checked here.
#
# The scope is two rules, because one would not do. Every .c and .h under
# src/sys/fs/hammer2/ needs a row whatever its count, which is what makes
# the zero rows meaningful rather than arbitrary; and any file anywhere
# under src/ that HOLDS a mark needs one, which is what caught the vendored
# header. A file outside the port directory with no mark needs no row.
#
# A fake pass here looks exactly like a real one: a table with no rows and a
# glob matching no files both compare nothing and print zero findings. Both
# populations are asserted before either is used.
xtmp=$(mktemp -d) || exit 2
trap 'rm -rf "$dtmp" "$xtmp"' EXIT
sed -n '/^| file | `XXX` | upstream.s | this port.s |$/,/^$/p' "$LEDGER" |
	sed -n 's/^| `\([^`]*\)` | \([0-9][0-9]*\) |.*/\1 \2/p' \
	> "$xtmp/rows"
nxrow=$(command grep -c . "$xtmp/rows" || true)
if [ "$nxrow" = 0 ]; then
	echo "  FAIL $LEDGER: the XXX table has no parseable row, so the"
	echo "       comparison below would have nothing to compare against"
	fail=$((fail + 1))
else
	# The files needing a row, by the two rules above.
	{
		ls src/sys/fs/hammer2/*.c src/sys/fs/hammer2/*.h |
			command grep -v "$NOTSRC"
		command grep -rlF $BUILT XXX src/
	} 2>/dev/null | LC_ALL=C sort -u > "$xtmp/files"
	nxfile=$(command grep -c . "$xtmp/files" || true)
	if [ "$nxfile" = 0 ]; then
		echo "  FAIL src/ matched no file at all for the XXX table check"
		fail=$((fail + 1))
	else
		while IFS= read -r f; do
			# The table names a file by its path below src/sys/fs/hammer2/,
			# or by sys/<name> for the vendored headers.
			key=${f#src/sys/fs/hammer2/}
			[ "$key" = "$f" ] && key=${f#src/sys/}
			want=$(command grep -c XXX "$f" || true)
			got=$(awk -v k="$key" '$1 == k { print $2; found=1 }
				END { if (!found) print "-" }' "$xtmp/rows")
			case "$got" in
			-)  echo "  FAIL $LEDGER: XXX table has no row for $key ($want mark(s))" ;;
			"$want") continue ;;
			*)  echo "  FAIL $LEDGER: XXX table says $key has $got, src/ has $want" ;;
			esac
			fail=$((fail + 1))
		done < "$xtmp/files"

		# The other direction: a row for a file that is gone reads as
		# outstanding surface forever.
		while read -r k _; do
			[ -f "src/sys/fs/hammer2/$k" ] || [ -f "src/sys/$k" ] ||
				{ echo "  FAIL $LEDGER: XXX table row for $k, which src/ no longer holds"
				  fail=$((fail + 1)); }
		done < "$xtmp/rows"

		# The table's last row is its three sums, and the prose beneath
		# the table reads its port's figure off that row. The sums were
		# hand-added and read one low twice: a file with one mark was
		# left out of the per-file list both times. The row has no
		# backticks, so the per-file parse above never sees it.
		# The sum sees the same rows the per-file check parsed, and says
		# so by count: a row the filter drops is caught above as a file
		# with no row, not here, and a sum over fewer rows than were
		# parsed would be a second filter disagreeing with the first.
		sums=$(sed -n '/^| file | `XXX` | upstream.s | this port.s |$/,/^$/p' "$LEDGER" |
			awk -F'|' '$2 ~ /`/ && $3 ~ /^ *[0-9]+ *$/ { a += $3; b += $4; c += $5; n++ }
				END { printf "%d %d %d %d\n", n, a, b, c }')
		nsum=${sums%% *}; sums=${sums#* }
		trow=$(sed -n 's/^| total | \([0-9][0-9]*\) | \([0-9][0-9]*\) | \([0-9][0-9]*\) |$/\1 \2 \3/p' "$LEDGER" | head -1)
		if [ -z "$trow" ]; then
			echo "  FAIL $LEDGER: the XXX table has no total row"
			fail=$((fail + 1))
		elif [ "$nsum" != "$nxrow" ]; then
			echo "  FAIL $LEDGER: the XXX table's sum covered $nsum row(s) of the $nxrow parsed"
			fail=$((fail + 1))
		elif [ "$trow" != "$sums" ]; then
			echo "  FAIL $LEDGER: the XXX table's total row says $trow, its rows sum to $sums"
			fail=$((fail + 1))
		fi
	fi
fi

# Every staged file must say where it stands against upstream. Patches
# sat in doc/upstream/ describing a fix with nothing recorded about
# whether upstream had already made it, already rejected it, or already
# been told, and a patch with no such record invites the reader to assume
# somebody looked. Seven of eight had none the day this check was
# written. The gate cannot read whether a note is any good; it can insist
# one exists and is not the file talking about itself.
#
# The population is every file here rather than *.patch: this directory
# also holds reports, and a report saying where a defect stands against
# upstream is the same obligation. The rule was written over every file
# from the start, in CLAUDE.md and in README.maintenance.md's section on
# sending a defect back, and the glob was left at *.patch, so a report
# staged with no entry rode on the gap and the gate read a narrower set
# than every document describing it claimed.
npatch=0
for f in doc/upstream/*; do
	[ -f "$f" ] || continue
	[ -e "$f" ] || continue
	npatch=$((npatch + 1))
	b=$(basename "$f")
	if command grep -rlF "$b" --include="*.md" doc/ 2>/dev/null |
	    command grep -qv "^doc/upstream/$b\$"; then
		:
	else
		echo "  FAIL doc/upstream/$b is staged with no document saying"
		echo "       whether upstream already has it, has refused it, or"
		echo "       has been told; see doc/upstream/README-provenance.md"
		fail=$((fail + 1))
	fi
done
# The reference-control declarations, the readiness audit's item 5. Every
# file under test/ declares the reference it is checked against, or says it
# has none and why; the declaration is a row in README.testing.md's table
# and nothing is inferred from the file's own text. A lexical rule was tried
# first and was wrong in both directions in one pass, which is why this is
# an authored table with a gate rather than a pattern.
#
# Both directions are checked, because either alone is satisfiable
# trivially: a test file with no row is a finding, and a row naming a file
# that does not exist is a finding. The population is asserted first, so a
# table that lost its rows and a test tree that lost its files cannot both
# pass by comparing nothing.
nref=0
if [ -f "$TESTDOC" ]; then
	refs=$(sed -n '/^| test file | reference control |/,/^$/p' "$TESTDOC" |
		sed -n 's/^| `\([^`]*\)` |.*/\1/p' | LC_ALL=C sort)
	nref=$(printf '%s\n' "$refs" | command grep -c .) || nref=0
	[ "$nref" -gt 0 ] || {
		echo "  FAIL $TESTDOC: the reference-control table has no row,"
		echo "       so the check below would compare nothing"
		fail=$((fail + 1)); }
	nrefcheck=0
	for f in $tests; do
		case "$f" in
		*.c) ;;
		*) continue ;;
		esac
		nrefcheck=$((nrefcheck + 1))
		printf '%s\n' "$refs" | command grep -qxF -- "$f" || {
			echo "  FAIL $f: no reference-control row in $TESTDOC"
			fail=$((fail + 1)); }
	done
	[ "$nrefcheck" -gt 0 ] || {
		echo "  FAIL no .c file under $TESTDIR was checked for a"
		echo "       reference declaration"
		fail=$((fail + 1)); }
	for r in $refs; do
		[ -f "$r" ] || {
			echo "  FAIL $TESTDOC names $r, which does not exist"
			fail=$((fail + 1)); }
	done
fi

# A harness that counts the guest's kernel reports must read debug_locks.
# One lockdep report turns lockdep off until the next boot, so a run on
# that boot counts no report with nothing checking and passes: the stage
# 2b wire harness did on 2026-10-20, and fourteen siblings had the same
# shape. A counter is a script with a grep carrying a count flag on a
# line naming a report: WARNING, BUG:, KASAN, a circular lock or a cut-here
# header. A count made through a wrapper function, with no grep -c on the
# line, is outside what this can see.
nrep=0
for s in script/*.sh; do
	command grep -q -E 'grep( +-[A-Za-z]+)* +-[A-Za-z]*c[A-Za-z]*( |$).*(WARNING|BUG:|KASAN|circular|cut here)' "$s" || continue
	case "$s" in
	script/test-inventory.sh) continue ;;
	esac
	nrep=$((nrep + 1))
	command grep -q debug_locks "$s" || {
		echo "  FAIL $s: counts kernel reports and never reads debug_locks,"
		echo "       so a guest whose lockdep is already off passes it"
		fail=$((fail + 1)); }
done
[ "$nrep" -gt 0 ] || {
	echo "  FAIL no script under script/ counts kernel reports, so the"
	echo "       debug_locks check above read nothing"
	fail=$((fail + 1)); }

# A harness that scans kmemleak must clear it before the load and scan it
# again after the unload, and every reading scans twice. Uncleared, the
# list carries an earlier run's leaks, which the count names "hammer2"
# only when the new module loads over their addresses: a stage 2b run on
# 2026-10-21 read 148 lines of a run two hours earlier. Scanned only
# before rmmod, an object a module global holds then and the unload never
# frees is seen by nobody. A scan greys an object whose checksum changed
# since the last one, and a new object's starts at ~0, so one scan reports
# nothing new (the kernel's own kmemleak-test read 0, then 1). Read on
# lines that are not comments, with the file's name and a load of the
# module read on comment lines too, since a `#` line inside a quote or a
# heredoc left open above it is a command: two scans and the clear on the line before each load.  Past
# the unload the whole block is compared byte for byte
# against the canonical copy below, modulo leading indent and the
# `timeout 120 ` some unloads carry: element matchers pass mutations that
# keep every substring (`+ 0`, `&& 0`, `{ a = "" }`, a guard moved below
# the 16-digit arm), a byte comparison fails on any of them.  The text of
# one block says nothing about what surrounds it, so the file is read
# around it too: the forms, the loads and the order of each clear and
# its load on lines that are not comments, and the file's name, the
# block, the unload and the producer counts on every line, comments
# among them, since no harness comment names the file as a path, the
# string or an unload: one `mrange=` line (a
# second is a decoy copy the comparison would read instead of the real
# one); one unload that reports, every other unload on a line, `rmmod`
# or `modprobe` followed in the same simple command by the name, after
# any flags or their arguments, quoted, with its suffix or by any path,
# matched by `rmmod hammer2 2>/dev/null` followed by `;` or the line's
# end (the cleanup before a load that every harness carries; a second
# reporting unload before the block, with a reload the load rule
# accepts, clears the first unload's leaks unread); every line naming
# the kmemleak file, `/kmemleak` as a whole word, one of the seven forms
# above, so a scan or a clear respelled, requoted or prefixed on its own
# line fails; a clear followed by anything but the load, which is
# `insmod /tmp/hammer2.ko`, its arguments each a `name=value` with no
# shell operator, brace, quote, backtick or backslash in the value, and
# the guard the harnesses carry, `|| { echo "insmod failed"; exit 1; }`
# or `insmod-failed` and `exit 0`, so a second load while the module is
# loaded ends the shell that runs it, the guest script or a substitution,
# pipeline element or subshell inside it, whose output then carries the
# marker to the `.out` or, discarded, does not, since a clear between
# the load and the reading greys every leak older than kmemleak's minimum age for
# both readings (mm/kmemleak.c, kmemleak_clear); the clear's own marker,
# `kmemleak-cleared`, named nowhere else but as the host's read, since
# the host requires one in the `.out` per load the run performs (two in
# cluster-sync.sh under H2_CRASH=1), counted by occurrence wherever it
# sits, so a second clear whose marker reaches the `.out` beside the
# first's, on its own line, glued to a line printed without its newline
# or beside the first on one line, fails the run with or without an
# unload and a reload around it; the guarded load lines
# counted, one, and two in cluster-sync.sh (GUEST and GUESTB), whose
# crash run boots the guest twice, so a second clear and load whose
# marker never reaches the `.out` (inside a group, a function, an `exec`
# or a pipe that redirects or filters their output) is read by the load
# line it adds; the reading before the unload once, its
# `if` form after a `sleep 6` and its count line after that, both above
# the reporting unload; a load spelled other than the guarded load
# wherever the word appears outside a comment line, the file's name and
# the word `insmod` read on the line whole and the form or the load
# compared on the line with its trailing comment stripped, since a form
# or the guarded load matched whole has balanced quotes, so what follows
# its ` # ` is a comment, and a line matching neither is read whole, so
# a quoted ` # ` before a clear or a load hides nothing; and
# `kmemleak-unl` outside the block
# matched by a `val` read of it on the same line, below the harness's
# `val()` definition where the host side is, since a producer that
# shares its line with a read is still a producer.  What passes the rule
# is named by class, each a mutation measured to pass it.  Three are
# met at run time: a second producer of the marker or either reading
# that does not spell the string in one token (`echo "kmemleak-""unloaded
# 0"`), since every harness's host side requires one `kmemleak-cleared`
# per load, counted by occurrence, one `kmemleak` line, one
# `kmemleak-unloaded` line and one range line in the `.out`, so a second
# fails the run however it is spelled, and a clear with a load or an
# unload around it is such a producer when its marker reaches the
# `.out`, and is read by the load line it adds when it does not;
# cluster-sync.sh's two load lines both in one of its two guest scripts,
# which the count per file admits and one of its two runs fails, the
# marker count no longer matching that run's boots; and the block
# kept from running with nothing
# forged or with one of its two lines forged, and the reading before the
# unload kept from running with nothing forged, since the host counts
# both lines and an empty reading before the unload fails the run.  The
# rest are the floor: the block kept from running with both its lines
# forged the same way, and the reading before the unload kept from
# running with its one line forged, which the counts cannot tell from
# the block or the reading; that reading moved above the work, before
# or after the load, which file order cannot place since cluster-sync.sh
# reads it in a function, and whose leaks the range reading after the
# unload still counts, without their names; the reading rewritten in
# transit, a filter on the guest's output or an edit of the `.out`,
# which leaves one line; the guest half run again by the harness with
# one run's output kept, the last's, whose second clear greys the
# first run's leaks before its reading, or the first's, the second
# run's reading discarded, neither of which the marker on `/dev/kmsg`
# below would read, the kept kernel log being one run's; a load the
# run performs from a file the rule does not read, a helper naming no
# kmemleak path, before the clear, which greys its leaks, or after the
# reading, which never sees them, and which runs no clear for that
# marker to count; the harness's one clear and load reused from a
# function or a loop the script runs twice, one of the two times with
# its output redirected or filtered, which adds no load line and keeps
# the marker count at one, the edit a quiet reload helper logging to a
# file is;
# DEFER(a harness's run reuses one clear and its load twice, once under a redirection):
# the marker written to `/dev/kmsg` and counted from the kept kernel
# log, which no enclosing redirection takes, at the cost of a follower
# and a host copy in the three harnesses that keep none, the ring clears
# the two fault harnesses run after the load moved, and the crash run's
# first half kept; a command,
# module or file name reaching its command other than
# as the next word in one token (a pipe, a list, a variable, `eval`,
# `cd` or `env -C` into the directory, a name split by quotes or built
# at run time); a form kept from running by the line before it (a
# continuation, an open quote, a heredoc), since the rule reads one line
# at a time; a command the block calls shadowed by a function, an alias
# or a PATH entry (`wc`, `sleep`); and the host's own check rewritten.
# A fourth class changes nothing the shell does: a trailing comment on
# a form line, after the marker or after `then`, and a write to a path
# beside the file that does not exist (`/kmemleak.`), which fails under
# the form's own `2>/dev/null` and clears nothing.
# The gate reads text and catches drift; a harness written against it
# is what the floor describes.  The controls below are copies of one
# harness with a line added, changed, moved or dropped, each failing
# the rule for the reason it carries, and the set of them is measured
# against every weakening of the rule tried: every weakening that
# admits a set of the mutation matrix is read by at least one control,
# and the weakenings no control reads (the load's clear read by its
# marker alone, the admission by the path alone, the guard's exit code
# widened to 3, a blank line allowed between the clear and its load,
# the clear-before-load test keyed on the guarded load, the comparison
# on the whole line where the stripped one matches nothing, the load on
# a comment line read by its fixed path alone) admit no
# set the matrix holds; the controls' number is asserted, a weakening none of them
# reads that admits a set is what the list grows by, and three parts
# have none: the forms list's count assertion and the controls' own,
# each guarding a list and admitting nothing until the list is edited,
# and the `exit` after each of pass 1's findings, which stops at the
# first and admits nothing when dropped.  The comment strips and pass
# 1's comment-line skip are read before any control runs, since every
# harness's clear line carries a trailing comment and cluster-sync.sh
# comments a line naming insmod, so a strip dropped fails the six
# harnesses themselves and the skip dropped fails cluster-sync.sh.
leak_canon=$(cat <<'LEAKEOF'
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
LEAKEOF
)
# Every line that names the kmemleak file is one of these seven, modulo
# leading indent and a trailing comment, so a scan or a clear respelled,
# quoted differently, kept from running by a prefix or on a comment
# line, which a quote or a heredoc left open above it runs, fails as a
# form the gate does not carry, the way the block does.
leak_forms=$(mktemp) || exit 2
cat > "$leak_forms" <<'FORMSEOF'
{ echo scan > /sys/kernel/debug/kmemleak && echo scan > /sys/kernel/debug/kmemleak && echo clear > /sys/kernel/debug/kmemleak; } 2>/dev/null; echo "kmemleak-cleared"
if echo scan > /sys/kernel/debug/kmemleak 2>/dev/null && echo scan > /sys/kernel/debug/kmemleak; then
elif echo scan > /sys/kernel/debug/kmemleak 2>/dev/null && echo scan > /sys/kernel/debug/kmemleak; then
echo "kmemleak $(grep -c hammer2 /sys/kernel/debug/kmemleak)"
grep -q hammer2 /sys/kernel/debug/kmemleak && sed 's/^/kmemleak-report /' /sys/kernel/debug/kmemleak | head -400
h2n=$(awk -v b="$mb" -v e="$me" '{ a = $1 "" } a ~ /^0x/ && a >= b && a < e' /sys/kernel/debug/kmemleak | wc -l)
[ "$h2n" = 0 ] || sed 's/^/kmemleak-unloaded-report /' /sys/kernel/debug/kmemleak | head -200
FORMSEOF
leak_fclear=$(head -1 "$leak_forms")
leak_fif='if echo scan > /sys/kernel/debug/kmemleak 2>/dev/null && echo scan > /sys/kernel/debug/kmemleak; then'
leak_fecho='echo "kmemleak $(grep -c hammer2 /sys/kernel/debug/kmemleak)"'
[ "$(grep -c -E '/kmemleak([^-_.a-zA-Z0-9]|$)' "$leak_forms")" = 7 ] && [ "$(grep -c . "$leak_forms")" = 7 ] || {
	echo "  FAIL the kmemleak forms list holds $(grep -c . "$leak_forms") line(s), not the seven the rule reads"
	fail=$((fail + 1)); }
leak_rule() {	# leak_rule <harness>: prints why it fails the rule, nothing when it passes
	lf=$1
	case $lf in */cluster-sync.sh) nwant=2 ;; *) nwant=1 ;; esac
	why=$(awk -v fclear="$leak_fclear" -v nwant="$nwant" '
		NR == FNR { forms[$0] = 1; next }
		/^[ \t]*#/ && /\/kmemleak([^-_.a-zA-Z0-9]|$)/ {
			print "line " FNR " naming kmemleak on a comment line, which a quote or a heredoc left open above it runs"; done = 1; exit }
		/^[ \t]*#/ && /insmod[ \t]+[^ \t]*hammer2/ {
			print "line " FNR " naming a load of hammer2 on a comment line, which a quote or a heredoc left open above it runs"; done = 1; exit }
		/^[ \t]*#/ { next }
		{ raw = $0; sub(/^[ \t]+/, "", raw); line = raw; sub(/[ \t]+# .*$/, "", line) }
		{ load = line ~ /^insmod \/tmp\/hammer2\.ko( [A-Za-z_][A-Za-z0-9_]*=[^ |;&#<>(){}"'"'"'`\\]+)* \|\| \{ echo "insmod[- ]failed"; exit [01]; \}$/ }
		load { nload++ }
		raw ~ /\/kmemleak([^-_.a-zA-Z0-9]|$)/ && !(line in forms) && !load {
			print "line " FNR " naming kmemleak in a form the gate does not carry"; done = 1; exit }
		raw ~ /(^|[^-_a-zA-Z0-9])insmod([^-_a-zA-Z0-9]|$)/ && !load && !(line in forms) {
			print "a load at line " FNR " not spelled insmod /tmp/hammer2.ko with the guard the harnesses carry"; done = 1; exit }
		line ~ /^insmod / && prev != fclear {
			print "a load at line " FNR " with no two scans and a clear on the line before it"; done = 1; exit }
		prev == fclear && line !~ /^insmod / {
			print "a clear at line " pl " followed by no load, which greys every leak before it"; done = 1; exit }
		{ prev = line; pl = FNR }
		END { if (!done && prev == fclear) print "a clear at line " pl " followed by no load, which greys every leak before it"
		      else if (!done && nload != nwant) print nload + 0 " guarded load line(s), not the " nwant " the harness carries" }' "$leak_forms" "$lf")
	if [ -z "$why" ]; then
		blk=$(awk '
			{ line = $0; sub(/^[ \t]+/, "", line); sub(/^timeout 120 /, "", line) }
			index($0, "mrange=$(awk ") { flag = 1 }
			flag && !tail { print line }
			flag && index($0, "kmemleak-unloaded-report ") { tail = 1; next }
			tail { print line; exit }' "$lf")
		[ "$blk" = "$leak_canon" ] || why="its post-unload block differs from the canonical copy"
	fi
	if [ -z "$why" ]; then
		why=$(awk -v fif="$leak_fif" -v fecho="$leak_fecho" -v fclear="$leak_fclear" '
			{ line = $0; sub(/^[ \t]+/, "", line); sub(/^timeout 120 /, "", line); sub(/[ \t]+# .*$/, "", line) }
			line ~ /^n?val\(\)/ { host = 1 }
			index(line, "mrange=$(awk ") { nblk++; inb = 1 }
			tail { tail = 0; inb = 0 }
			inb && index(line, "kmemleak-unloaded-report ") { tail = 1 }
			line == fif { nif++; lif = NR; if (prev != "sleep 6") bad = bad ", the reading before the unload at line " NR " with no sleep 6 on the line before it" }
			line == fecho { necho++; lecho = NR }
			{ prev = line }
			line == "rmmod hammer2 && echo \"rmmod ok\"" { nun++; lun = NR; next }
			{ t = $0; nu = gsub(/(rmmod|modprobe)[^;&|]*[ \t"'"'"'\/]hammer2(\.ko)?/, "", t); t = $0; nd = gsub(/rmmod hammer2 2>\/dev\/null(;|$)/, "", t) }
			nu > nd { bad = bad ", an unload at line " NR " that is not the block'"'"'s" }
			{ t = $0; nk = gsub(/kmemleak-unl/, "", t); t = $0; nv = host ? gsub(/val( [^ ]+)? kmemleak-unloaded(-range)?\)/, "", t) : 0 }
			!inb && nk > nv { bad = bad ", kmemleak-unloaded named at line " NR " outside the block and not as the host'"'"'s read" }
			{ t = $0; nc = gsub(/kmemleak-cleared/, "", t); t = $0; ncv = host ? gsub(/grep (-o kmemleak-cleared "\$W\/out"|"\^\$sd " "\$W\/out" \| grep -o kmemleak-cleared) \| wc -l\)/, "", t) : 0 }
			line != fclear && nc > ncv { bad = bad ", kmemleak-cleared named at line " NR " outside the clear and not as the host'"'"'s read" }
			END {
				if (nblk != 1) bad = bad ", " nblk + 0 " post-unload blocks"
				if (nun != 1) bad = bad ", " nun + 0 " reporting unloads"
				if (nif != 1 || necho != 1) bad = bad ", the reading before the unload on " nif + 0 " if line(s) and " necho + 0 " count line(s), not one each"
				else if (!(lif < lecho && lecho < lun)) bad = bad ", the reading before the unload at lines " lif " and " lecho " not before the reporting unload at line " lun
				if (bad != "") print substr(bad, 3) }' "$lf")
	fi
	printf '%s' "$why"
}
# Admitted by naming the file at all; the two that name it and do not
# scan (a knob's comment, a `stack=on` write) are excluded by name and
# counted, so a third such script is a decision and not a silent gap.
nleak=0; leak_first=; nleakskip=0
for s in script/*.sh; do
	command grep -q -E '/kmemleak([^-_.a-zA-Z0-9]|$)' "$s" || continue
	case "$s" in
	script/test-inventory.sh) continue ;;
	script/million-tree.sh|script/nix-closure.sh) nleakskip=$((nleakskip + 1)); continue ;;
	esac
	nleak=$((nleak + 1)); leak_first=${leak_first:-$s}
	why=$(leak_rule "$s")
	[ -z "$why" ] || {
		echo "  FAIL $s: kmemleak read with $why"
		fail=$((fail + 1)); }
done
# The controls, each a copy of one harness that must fail the rule for
# the reason it carries, their number asserted so a dropped one is read.
# Lines placed after the file's end and just above the block (a dash
# skips a placement the rule reads differently there), since a rule that
# counted only past the block would still fail every appended copy: the
# decoy, which the byte comparison takes for the block's first line, for
# the block count; the second reporting unload for its count; the
# val-riding producer, the comment and the val-shaped line read above
# the block alone, where no val() has been defined, for the producer
# rule, a marker line, a marker producer riding the host's count and a
# marker after the clear form's tail for the marker's; the flagged unload, the one
# by relative path behind a flag's argument, the quoted one, the one
# after a tab, the one whose status a list discards and the cleanup
# spelling followed by a report, for the unload pattern's parts and the
# exemption's exactness; the quoted load, the load that discards its
# failure, the guarded load with a `;` in its argument, the guard
# exiting 2, the guard inside a quoted argument, the guard inside a
# brace expansion and the load after a quoted ` # ` for the load's
# spelling, and the guarded load for the clear before it; the clear
# form and a guarded load after a line printed without its newline for
# the load count's upper side; the clear form's last command behind a
# `#` and a load behind one for the file's name and a load on a comment
# line; the host's count by line, for the count by occurrence; the full
# clear form behind `true ||`, a one-scan clear, the clear form with its
# path respelled and the clear form after a quoted ` # ` for the forms
# compared whole; the
# clear form alone for the load after it; a second `if` line and a
# second count line for the reading before the unload. Copies change a
# line instead: `sleep 6` made `sleep 0` and the count line's `$h2n`
# made `0` inside the block, before and after its sleep, for the byte
# comparison; the reading's `if` line and its count line each moved past
# the end, and the `if` line dropped, for its count and placement; the
# `sleep 6` before it dropped, made `sleep 1` and made `sleep 7` for the
# wait; the load's command made `xinsmod`, for the load the clear
# needs; and the clear and its load dropped, for the load count's lower
# side.
nctl=0
leak_ctl() {	# leak_ctl <copy> <want> <how>
	nctl=$((nctl + 1))
	why=$(leak_rule "$1")
	case "$why" in
	*"$2"*) ;;
	*) echo "  FAIL control: $leak_first with $3 read as ${why:-passing the kmemleak rule}, not as $2"
	   fail=$((fail + 1)) ;;
	esac
}
if [ -n "$leak_first" ]; then
	leak_tmp=$(mktemp -d) || exit 2
	for m in 'mrange=$(awk 1)::post-unload blocks::differs from the canonical copy' \
	    'rmmod hammer2 && echo "rmmod ok"::reporting unloads::reporting unloads' \
	    'echo "kmemleak-unloaded 0" # val kmemleak-unloaded)::kmemleak-unloaded named::kmemleak-unloaded named' \
	    '#kmemleak-unloaded 0::kmemleak-unloaded named::kmemleak-unloaded named' \
	    'printf "%s\n" "val kmemleak-unloaded) 0" | sed "s/^val //; s/)//"::-::kmemleak-unloaded named' \
	    'rmmod -v hammer2::an unload at line::an unload at line' \
	    'modprobe -r -d /lib/modules ../tmp/hammer2.ko::an unload at line::an unload at line' \
	    'rmmod hammer2 || true::an unload at line::an unload at line' \
	    'rmmod "hammer2"::an unload at line::an unload at line' \
	    "$(printf 'rmmod\thammer2')::an unload at line::an unload at line" \
	    'rmmod hammer2 2>/dev/null && echo "rmmod ok"::an unload at line::an unload at line' \
	    'echo "kmemleak-cleared"::kmemleak-cleared named::kmemleak-cleared named' \
	    'printf "%s\n" "kmemleak-cl""eared $(grep -o kmemleak-cleared "$W/out" | wc -l)"::-::kmemleak-cleared named' \
	    '{ :; } 2>/dev/null; echo "kmemleak-cleared"::kmemleak-cleared named::kmemleak-cleared named' \
	    'insmod "/tmp/hammer2.ko"::not spelled insmod::not spelled insmod' \
	    'insmod /tmp/hammer2.ko 2>/dev/null::not spelled insmod::not spelled insmod' \
	    'insmod /tmp/hammer2.ko ;true || { echo "insmod failed"; exit 1; }::not spelled insmod::not spelled insmod' \
	    'insmod /tmp/hammer2.ko || { echo "insmod failed"; exit 2; }::not spelled insmod::not spelled insmod' \
	    'insmod /tmp/hammer2.ko x='"'"' || { echo "insmod failed"; exit 1; } # '"'"'::not spelled insmod::not spelled insmod' \
	    'insmod /tmp/hammer2.ko x=${a+ || { echo "insmod failed"; exit 1; }::not spelled insmod::not spelled insmod' \
	    'echo "reload # new params"; insmod /tmp/hammer2.ko debug=1::not spelled insmod::not spelled insmod' \
	    'insmod /tmp/hammer2.ko || { echo "insmod failed"; exit 1; }::no two scans and a clear::no two scans and a clear' \
	    'true || { echo scan > /sys/kernel/debug/kmemleak && echo scan > /sys/kernel/debug/kmemleak && echo clear > /sys/kernel/debug/kmemleak; } 2>/dev/null; echo "kmemleak-cleared"::a form the gate does not carry::a form the gate does not carry' \
	    '{ echo scan > /sys/kernel/debug/kmemleak && echo clear > /sys/kernel/debug/kmemleak; } 2>/dev/null; echo "kmemleak-cleared"::a form the gate does not carry::a form the gate does not carry' \
	    '{ echo scan > /sys/kernel/debug//kmemleak && echo scan > /sys/kernel/debug//kmemleak && echo clear > /sys/kernel/debug//kmemleak; } 2>/dev/null; echo "kmemleak-cleared"::a form the gate does not carry::a form the gate does not carry' \
	    'echo "settle # 5 s"; { echo scan > /sys/kernel/debug/kmemleak && echo scan > /sys/kernel/debug/kmemleak && echo clear > /sys/kernel/debug/kmemleak; } 2>/dev/null::a form the gate does not carry::a form the gate does not carry' \
	    '# $(echo clear > /sys/kernel/debug/kmemleak)::naming kmemleak on a comment line::naming kmemleak on a comment line' \
	    '# $(insmod /tmp/hammer2.ko)::naming a load of hammer2 on a comment line::naming a load of hammer2 on a comment line' \
	    'c=$(grep -c kmemleak-cleared "$W/out")::kmemleak-cleared named::-' \
	    "$leak_fclear::followed by no load::followed by no load" \
	    "$(printf '%s\n%s\n%s' "printf 'reloading: '" "$leak_fclear" 'insmod /tmp/hammer2.ko || { echo "insmod failed"; exit 1; }')::2 guarded load line(s), not the 1::2 guarded load line(s), not the 1" \
	    "$leak_fif::not one each::not one each" \
	    "$leak_fecho::not one each::not one each"; do
		mut=${m%%::*}; rest=${m#*::}; after=${rest%::*}; above=${rest#*::}
		{ cat "$leak_first"; echo; printf '%s\n' "$mut"; } > "$leak_tmp/after.sh"
		awk -v mut="$mut" 'index($0, "mrange=$(awk ") && !done { print mut; done = 1 } { print }' "$leak_first" > "$leak_tmp/above.sh"
		for where in after above; do
			eval "want=\$$where"
			[ "$want" != - ] || continue
			leak_ctl "$leak_tmp/$where.sh" "$want" "\`$mut\` placed $where"
		done
	done
	for m in 'index($0, "mrange=$(awk ") { inb = 1 } inb && line == "sleep 6" { sub(/6/, "0") } { print }::differs from the canonical copy::sleep 0 inside the block' \
	    'index($0, "mrange=$(awk ") { inb = 1 } inb && index(line, "echo \"kmemleak-unloaded $h2n\"") { sub(/\$h2n/, "0") } { print }::differs from the canonical copy::a forged count inside the block' \
	    'line == fif { held = $0; next } { print } END { print held }::not before the reporting unload::the if line of the reading moved past the end' \
	    'line == fecho { held = $0; next } { print } END { print held }::not before the reporting unload::the count line of the reading moved past the end' \
	    'line == fif { next } { print }::not one each::the if line of the reading dropped' \
	    'n && line != fif { print held } { held = $0; n = 1 } END { print held }::no sleep 6 on the line before it::the sleep before the reading dropped' \
	    'n && line == fif && held ~ /sleep 6$/ { sub(/6$/, "1", held) } n { print held } { held = $0; n = 1 } END { print held }::no sleep 6 on the line before it::the sleep before the reading made sleep 1' \
	    'n && line == fif && held ~ /sleep 6$/ { sub(/6$/, "7", held) } n { print held } { held = $0; n = 1 } END { print held }::no sleep 6 on the line before it::the sleep before the reading made sleep 7' \
	    'line ~ /^insmod / { gsub(/insmod/, "xinsmod") } { print }::followed by no load::the load made xinsmod' \
	    'index(line, fclear) == 1 || line ~ /^insmod \/tmp\/hammer2\.ko / { next } { print }::0 guarded load line(s), not the 1::the clear and its load dropped'; do
		prog=${m%%::*}; rest=${m#*::}; want=${rest%::*}; how=${rest#*::}
		awk -v fif="$leak_fif" -v fecho="$leak_fecho" -v fclear="$leak_fclear" '{ line = $0; sub(/^[ \t]+/, "", line) } '"$prog" "$leak_first" > "$leak_tmp/changed.sh"
		leak_ctl "$leak_tmp/changed.sh" "$want" "$how"
	done
	rm -rf "$leak_tmp"
	[ "$nctl" = 73 ] || {
		echo "  FAIL $nctl kmemleak control(s) ran, not the 73 the gate lists"
		fail=$((fail + 1)); }
fi
rm -f "$leak_forms"
[ "$nleak" = 6 ] || {
	echo "  FAIL $nleak script(s) under script/ admitted to the kmemleak check, not the six harnesses;"
	echo "       one that stops naming the file by its path leaves the check unread"
	fail=$((fail + 1)); }
[ "$nleakskip" = 2 ] || {
	echo "  FAIL $nleakskip script(s) named as naming kmemleak without scanning it, not the two the gate lists"
	fail=$((fail + 1)); }

# The staged files are a population like the rest. A glob that matched
# nothing would check nothing and still print a clean count.
[ "$npatch" -gt 0 ] || {
	echo "  FAIL doc/upstream/ holds no staged file at all, so the"
	echo "       provenance check above read nothing"
	fail=$((fail + 1)); }

echo "inventory: $nc source file(s), $nh header(s), $nt test file(s), $ngates gate(s), $ndefer DEFER(s), $nxrow XXX row(s), $npatch staged file(s), $nref reference row(s), $nrep report counter(s), $nleak kmemleak scanner(s), $fail finding(s)"
[ "$fail" = 0 ] || exit 1
