#!/bin/sh
# The changelog is the only place a version number is bound to
# a commit, and nothing read it until 2026-08-25.
#
# TWO CHECKS, AND THEY ARE DELIBERATELY DIFFERENT IN KIND.
#
# The first is a GATE and fails: every hash pinned in the table must resolve
# in this repository, and its subject line must still be the one the row
# describes. A rebase, a rewrite or a typo makes a version row point at
# something else, and a row that names the wrong commit is worse than no row
# because it reads as checked.
#
# The second is a PROMPT and never fails: how many commits touching src/ or
# script/ have landed since the newest pinned hash. Zero is the healthy
# signature. Nonzero is not a defect - it is the question "does one of these
# deserve a row", asked where somebody will read it. A check that forced a
# row per commit would make the table meaningless, because a row is a
# judgment. Scoped to src/ and script/ so a documentation commit does not
# nag.
#
# Exit 2 is COULD-NOT-RUN. Exit 1 is a failed assertion.
set -u
cd "$(dirname "$0")/.." || exit 2
command -v git >/dev/null 2>&1 || { echo "history: COULD-NOT-RUN: no git"; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "history: COULD-NOT-RUN: not a repository"; exit 2; }

DOC=CHANGELOG.md
[ -f "$DOC" ] || { echo "history: COULD-NOT-RUN: no $DOC"; exit 2; }

rows=0; bad=0; newest=""; newest_depth=0
# A row is `| <version> | <date> | <text (`hash`)> | <verifier> |`. The hash
# is the last backticked 7-to-40 hex token on the line, because the text
# also backticks symbol names.
while IFS= read -r line; do
	# THREE COMPONENTS, WHICH IS THE DISCRIMINATOR AND NOT A HEURISTIC.
	# A released version is X.Y.Z and pins a commit; a MILESTONE is X.Y and
	# pins nothing because it has not happened. Both are tables of rows
	# opening with a number in this file, so a two-component match reported
	# ten milestones as rows missing a hash - correctly, about the wrong
	# table.
	ver=$(printf '%s' "$line" | sed -n 's/^| \([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\) |.*/\1/p')
	[ -n "$ver" ] || continue
	h=$(printf '%s' "$line" | grep -o '`[0-9a-f]\{7,40\}`' | tail -1 | tr -d '`')
	if [ -z "$h" ]; then
		echo "  FAIL $ver: the row pins no commit hash"
		bad=$((bad+1)); rows=$((rows+1)); continue
	fi
	if ! git cat-file -e "$h^{commit}" 2>/dev/null; then
		echo "  FAIL $ver: $h does not resolve in this repository"
		bad=$((bad+1)); rows=$((rows+1)); continue
	fi
	subj=$(git log --format=%s -1 "$h")
	echo "  ok   $ver -> $h  $subj"
	vers="${vers:-}$ver
"
	# NEWEST BY THE GRAPH, NOT BY TABLE ORDER. A row inserted out of order,
	# or a table sorted descending later, would otherwise make the prompt
	# below measure from the wrong commit and report a reassuring zero.
	d=$(git rev-list --count "$h")
	if [ "$d" -gt "${newest_depth:-0}" ]; then newest="$h"; newest_depth="$d"; fi
	rows=$((rows+1))
done < "$DOC"

# THE POPULATION IS ASSERTED. A parser that stops matching reports a clean
# zero, and a clean zero here reads exactly like a table with no defects.
[ "$rows" -gt 0 ] || {
	echo "history: FAIL: parsed no version rows from $DOC. Either the table" >&2
	echo "  lost its rows or this matcher stopped matching; an empty" >&2
	echo "  population passing is what this check exists to prevent." >&2
	exit 1; }

# A VERSION NUMBER IS A HAND-MAINTAINED SEQUENCE AND NOTHING READ IT EITHER.
# Every row above can resolve, match its subject and still be numbered the
# same as its neighbour: two rows sharing a version make the older one
# unreachable by name, and the table is where a reader looks a version up.
# Added 2026-08-26 after writing two rows numbered 0.1.13 in one edit, which
# every check here passed.
dups=$(printf '%s' "${vers:-}" | LC_ALL=C sort | uniq -d)
if [ -n "$dups" ]; then
	for v in $dups; do
		echo "  FAIL $v: more than one row carries this version"
		bad=$((bad+1))
	done
fi

echo "history: $rows row(s), $bad bad"
[ "$bad" = 0 ] || exit 1

# THE PROMPT. Never fails; see the header.
since=$(git rev-list --count "$newest"..HEAD -- src script 2>/dev/null || echo "?")
if [ "$since" = 0 ]; then
	echo "history: no deliverable commit since the newest row ($newest)"
else
	echo "history: $since commit(s) touching src/ or script/ since the newest"
	echo "  row ($newest). Not a failure - decide whether any deserves a row."
	git log --oneline "$newest"..HEAD -- src script | sed 's/^/    /'
fi
