#!/bin/sh
# Every file under src/ has a provenance row, and every row claiming a
# byte-for-byte carry is re-checked with cmp.
#
# 0.2's first exit criterion is that no file under src/sys/fs/hammer2/ is
# there without a recorded origin, commit and licence. That rule was prose in
# doc/README.roadmap.md until this gate existed, so it held as long as whoever
# added a file remembered it. A port's licence story is the first thing an
# upstream reviewer reads and the last thing anyone can reconstruct.
#
# What a green run is worth. Two of the three checks are about the table: no
# file without a row, no row without a file. Both sides come out of this tree,
# so neither can be wrong about it. The third has teeth. A row saying
# `identical` is a claim about another repository, and this re-runs cmp
# against that clone instead of trusting the word. With no clone on the
# machine the claim is reported unverified by name, never counted as passing.
#
# What it cannot do: `derived` and `ours` rows are unfalsifiable here, there
# being no mechanical test for "edited here". Their count is printed rather
# than checked, and a wrong origin on one is a review finding.
#
# Exit 2 is COULD-NOT-RUN: no CSV. Exit 1 is a count of findings.
set -u
cd "$(dirname "$0")/.." || exit 2

# --selftest drives the branches a green run never reaches. Three of the
# four findings this gate can emit are invisible on a healthy tree, and a
# branch that has never executed is a comment, not a check.
if [ "${1:-}" = "--selftest" ]; then
	t=$(mktemp -d) || exit 2
	trap 'rm -rf "$t"' EXIT
	mkdir -p "$t/src" || exit 2
	echo x > "$t/src/listed.c"; echo y > "$t/src/unlisted.c"
	printf 'file,origin,origin_commit,license,carry,note\n' > "$t/p.csv"
	printf '%s/src/listed.c,,,BSD-3-Clause,ours,\n' "$t" >> "$t/p.csv"
	printf '%s/src/gone.c,,,BSD-3-Clause,ours,\n' "$t" >> "$t/p.csv"
	sfail=0
	out=$(H2_PROVENANCE_CSV="$t/p.csv" H2_SRC_DIR="$t/src" sh "$0" 2>&1); rc=$?
	for want in 'unlisted.c has no row' 'which is not in the tree'; do
		if printf '%s\n' "$out" | command grep -q "$want"; then
			echo "  ok    selftest: reports \"$want\""
		else
			echo "  FAIL  selftest: no \"$want\" in the output"; sfail=$((sfail + 1))
		fi
	done
	[ "$rc" = 1 ] && echo "  ok    selftest: exits 1 on findings" || {
		echo "  FAIL  selftest: exited $rc, wanted 1"; sfail=$((sfail + 1)); }

	# The cmp branch, in both directions, against this tree's real CSV:
	# a clone directory that does not exist must be COULD-NOT-RUN, and a
	# row whose file was swapped must be a finding rather than a pass.
	out=$(H2_CLONE_DIR=/nonexistent sh "$0" 2>&1); rc=$?
	[ "$rc" = 2 ] && echo "  ok    selftest: COULD-NOT-RUN with no clone present" || {
		echo "  FAIL  selftest: exited $rc with no clone, wanted 2"; sfail=$((sfail + 1)); }

	# A clone at the wrong commit is the likelier way the cmp half stops
	# meaning anything, the clone being a working tree somebody pulls. It
	# must read UNVER, never FAIL: a carry compared against a commit the
	# row does not name answers a question nobody asked.
	sed 's/,3df307f7db9d5106b857afeb877613fd12a19101,/,0000000deadbeef0000000000000000000000000,/' \
		doc/provenance.csv > "$t/wrongc.csv"
	out=$(H2_PROVENANCE_CSV="$t/wrongc.csv" sh "$0" 2>&1)
	if printf '%s\n' "$out" | command grep -q 'not the 0000000... this row names'; then
		echo "  ok    selftest: a clone at the wrong commit reads UNVER"
	elif printf '%s\n' "$out" | command grep -q '^  UNVER'; then
		echo "  ok    selftest: no clone here, so the wrong-commit branch is moot"
	else
		echo "  FAIL  selftest: a wrong-commit clone was treated as a carry"
		sfail=$((sfail + 1))
	fi
	#
	# The last check needs an origin clone and says so when it has none.
	# It swaps one row's filename so a row claiming a carry points at a
	# file that is not that carry, and requires cmp to catch it. With no
	# clone on the machine there is nothing to compare against, and the
	# honest report is COULD-NOT-RUN for the selftest as a whole. Passing
	# on the strength of the four checks that did run would put this
	# gate's own could-not-run defect in the instrument that exists to
	# prove the gate works.
	sfran=5
	sed 's#^src/sys/fs/hammer2/hammer2_xops.c,#src/sys/fs/hammer2/hammer2_io.c,#' \
		doc/provenance.csv > "$t/swap.csv"
	out=$(H2_PROVENANCE_CSV="$t/swap.csv" sh "$0" 2>&1)
	if printf '%s\n' "$out" | command grep -q 'says identical but differs'; then
		echo "  ok    selftest: cmp catches a wrong identical claim"
		sfran=6
	elif printf '%s\n' "$out" | command grep -q '^  UNVER'; then
		echo "selftest: $sfran check(s), $sfail failed; COULD-NOT-RUN: no"
		echo "          origin clone here, so cmp was never exercised"
		[ "$sfail" = 0 ] || exit 1
		exit 2
	else
		echo "  FAIL  selftest: a wrong identical claim passed cmp"; sfail=$((sfail + 1))
		sfran=6
	fi
	echo "selftest: $sfran check(s), $sfail failed"
	[ "$sfail" = 0 ] || exit 1
	exit 0
fi

CSV=${H2_PROVENANCE_CSV-doc/provenance.csv}
SRC=${H2_SRC_DIR-src}
CLONES=${H2_CLONE_DIR-$HOME/Projects}

[ -f "$CSV" ] || { echo "provenance: COULD-NOT-RUN: no $CSV"; exit 2; }
[ -d "$SRC" ] || { echo "provenance: COULD-NOT-RUN: no $SRC directory"; exit 2; }

# Assert both populations before comparing anything. Either one empty makes
# every loop below vacuous, and a vacuous run prints zero findings, which is
# indistinguishable from a clean tree.
files=$(find "$SRC" -type f | LC_ALL=C sort)
rows=$(command grep -v '^#' "$CSV" | command grep -v '^file,origin,' | command grep -v '^[[:space:]]*$')
[ -n "$files" ] || { echo "provenance: FAIL: no files under $SRC at all" >&2; exit 1; }
[ -n "$rows" ] || { echo "provenance: FAIL: $CSV has no rows at all" >&2; exit 1; }

fail=0 ran=0 nident=0 nunver=0 nother=0

echo "provenance: $(printf '%s\n' "$files" | wc -l | tr -d ' ') file(s) under $SRC, $(printf '%s\n' "$rows" | wc -l | tr -d ' ') row(s) in $CSV"

# 1. No file without a row.
for f in $files; do
	ran=$((ran + 1))
	printf '%s\n' "$rows" | command grep -q "^$f," || {
		echo "  FAIL  $f has no row in $CSV"
		fail=$((fail + 1))
	}
done

# 2. No row without a file. A row for a deleted file is how a licence
#    table starts describing a tree that no longer exists.
# The loop runs in a subshell because of the pipe, so its counters would
# not survive it; the findings go to a file and are counted here. `grep
# -c` prints 0 and exits 1 on no match, so its status is discarded on purpose
# instead of ending the script under set -e or feeding a second value into the
# arithmetic below.
orphans="${TMPDIR:-/tmp}/h2prov.$$"
printf '%s\n' "$rows" | while IFS= read -r r; do
	rf=${r%%,*}
	[ -f "$rf" ] || echo "  FAIL  $CSV names $rf, which is not in the tree"
done > "$orphans"
cat "$orphans"
norph=$(command grep -c . "$orphans" 2>/dev/null) || :
norph=${norph:-0}
rm -f "$orphans"
fail=$((fail + norph))
ran=$((ran + norph))

# The vocabulary of the carry column, checked before it is read. A row
# whose fifth field is anything else is silently NOT an `identical` row:
# the loop below skips it, the cmp never runs, and the summary counts it
# among the rows that are unfalsifiable here. Writing `carry` where the
# format says `identical` is the obvious way to do that by hand, and it
# happened on 2026-08-26 when hammer2_cluster.c was added. The reassuring
# direction, since the gate stays green and the strongest check it has is
# what got turned off.
badvocab=$(printf '%s\n' "$rows" | awk -F, '$5 != "identical" && $5 != "derived" && $5 != "ours" { print $1 " -> " $5 }')
if [ -n "$badvocab" ]; then
	printf '%s\n' "$badvocab" | sed 's/^/  FAIL  carry column is not identical, derived or ours: /'
	nvocab=$(printf '%s\n' "$badvocab" | command grep -c .) || nvocab=1
	fail=$((fail + nvocab)); ran=$((ran + nvocab))
else
	ran=$((ran + 1))
	echo "  ok    every row's carry column is one of identical, derived, ours"
fi

# 3. The claim with teeth: `identical` is re-run, not read.
identlog="${TMPDIR:-/tmp}/h2ident.$$"
printf '%s\n' "$rows" | while IFS=, read -r rf origin commit lic carry rest; do
	[ "$carry" = identical ] || continue
	u="$CLONES/$origin/$rf"
	if [ ! -f "$u" ]; then
		echo "  UNVER $rf: no $origin clone at $CLONES, so identical is unverified"
		continue
	fi
	# Check the clone's commit, do not assume it. cmp against a working
	# tree at an unknown commit answers a different question confidently:
	# one `git pull` in the clone and this either goes red for a reason
	# that is not this repository's, or stays green having compared
	# against a commit the CSV does not name. Neither is a finding about
	# the carry, so a mismatch is UNVER and never FAIL.
	if [ -n "$commit" ] && command -v git >/dev/null 2>&1; then
		at=$(git -C "$CLONES/$origin" rev-parse HEAD 2>/dev/null) || at=""
		if [ -n "$at" ] && [ "$at" != "$commit" ]; then
			echo "  UNVER $rf: the $origin clone is at ${at%"${at#???????}"}..., not the ${commit%"${commit#???????}"}... this row names"
			continue
		fi
	fi
	if cmp -s "$rf" "$u"; then
		echo "  ok    $rf identical to $origin"
	else
		echo "  FAIL  $rf says identical but differs from $CLONES/$origin"
	fi
done > "$identlog"
cat "$identlog"
nident=$(command grep -c '^  ok ' "$identlog" 2>/dev/null) || :; nident=${nident:-0}
nunver=$(command grep -c '^  UNVER' "$identlog" 2>/dev/null) || :; nunver=${nunver:-0}
nbad=$(command grep -c '^  FAIL' "$identlog" 2>/dev/null) || :; nbad=${nbad:-0}
rm -f "$identlog"
fail=$((fail + nbad))
ran=$((ran + nident + nunver + nbad))

nother=$(printf '%s\n' "$rows" | awk -F, '$5 != "identical"' | command grep -c . 2>/dev/null) || :; nother=${nother:-0}

# Name the unchecked claims in the summary. A count of findings alone reads
# as a count of the population.
echo "provenance: $ran check(s), $fail finding(s); $nident carry(s) re-verified by cmp, $nunver unverified, $nother row(s) derived or ours and unfalsifiable here"
[ "$fail" = 0 ] || exit 1

# A run that verified no carry is not a pass. The two table checks read both
# sides out of this tree, so they hold with or without an origin clone; only
# cmp asks something this repository cannot answer alone. With every clone
# missing, all that survives is that the table agrees with itself, and calling
# that green would make the gate strongest on the machine that checked least,
# which is CI.
if [ "$nident" = 0 ] && [ "$nunver" != 0 ]; then
	echo "provenance: COULD-NOT-RUN: no origin clone under $CLONES at the"
	echo "            commit its row names, so no carry was re-verified and"
	echo "            only the table was checked. The lines above say which"
	echo "            of the two it was, per row."
	exit 2
fi
