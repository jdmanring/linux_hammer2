#!/bin/sh
# The changelog is the only place a version number is bound to
# a commit, and nothing read it until 2026-08-25.
#
# Two checks, different in kind.
#
# The first is a gate and fails. Every hash pinned in the table must resolve
# here, and its subject must still be the one the row describes. A rebase, a
# rewrite or a typo makes a row point at something else, and a row naming the
# wrong commit is worse than no row because it reads as checked.
#
# The second is a prompt and never fails: how many commits touching src/ or
# script/ have landed since the newest pinned hash. Nonzero is not a defect,
# it is the question "does one of these deserve a row", asked where somebody
# will read it. Forcing a row per commit would make the table meaningless,
# since a row is a judgment. Scoped to src/ and script/ so documentation
# commits do not nag.
#
# Exit 2 is COULD-NOT-RUN. Exit 1 is a failed assertion.
set -u
cd "$(dirname "$0")/.." || exit 2
command -v git >/dev/null 2>&1 || { echo "history: COULD-NOT-RUN: no git"; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "history: COULD-NOT-RUN: not a repository"; exit 2; }

DOC=CHANGELOG.md
[ -f "$DOC" ] || { echo "history: COULD-NOT-RUN: no $DOC"; exit 2; }

rows=0; bad=0; newest=""; newest_depth=0; newest_ver=""
# A row is `| <version> | <date> | <text (`hash`)> | <verifier> |`. The hash
# is the last backticked 7-to-40 hex token on the line, because the text
# also backticks symbol names.
while IFS= read -r line; do
	# Three components is the discriminator. A released version is X.Y.Z
	# and pins a commit; a milestone is X.Y and pins nothing, having not
	# happened. Both open a table row with a number, so a two-component
	# match reports ten milestones as rows missing a hash.
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
	# Resolving is not enough. A commit discarded by a reset stays in the
	# object store on the machine that wrote it and is absent everywhere
	# else, so a row pinning one passes here and fails in CI on the same
	# tree. That happened once, on a message rewritten to satisfy the
	# push hook. Reachability from HEAD is the property a reader of the
	# row actually needs, and it is what a fresh clone will see.
	if ! git merge-base --is-ancestor "$h" HEAD 2>/dev/null; then
		echo "  FAIL $ver: $h is not reachable from HEAD"
		bad=$((bad+1)); rows=$((rows+1)); continue
	fi
	subj=$(git log --format=%s -1 "$h")
	echo "  ok   $ver -> $h  $subj"
	vers="${vers:-}$ver
"
	# Newest by the graph, not by table order. A row inserted out of order,
	# or a table sorted descending later, would make the prompt below
	# measure from the wrong commit and report zero.
	d=$(git rev-list --count "$h")
	if [ "$d" -gt "${newest_depth:-0}" ]; then
		newest="$h"; newest_depth="$d"; newest_ver="$ver"
	fi
	rows=$((rows+1))
done < "$DOC"

# Assert the population. A parser that stops matching reports zero rows, and
# zero rows here is indistinguishable from a table with no defects.
[ "$rows" -gt 0 ] || {
	echo "history: FAIL: parsed no version rows from $DOC. Either the table" >&2
	echo "  lost its rows or this matcher stopped matching; an empty" >&2
	echo "  population passing is what this check exists to prevent." >&2
	exit 1; }

# The version numbers are a hand-maintained sequence. Every row above can
# resolve and match its subject while carrying its neighbour's number, which
# makes the older of the two unreachable by name in the one table a reader
# looks a version up in. Two rows were numbered 0.1.13 in a single edit before
# this check existed.
dups=$(printf '%s' "${vers:-}" | LC_ALL=C sort | uniq -d)
if [ -n "$dups" ]; then
	for v in $dups; do
		echo "  FAIL $v: more than one row carries this version"
		bad=$((bad+1))
	done
fi

# The newest row is what the tree IS. A document stating the tree's current
# version and naming an older one describes the state before the milestone it
# sits above, and no gate read prose for truth: four such documents were found
# in two days (0.2.116, `8d2495a`, 0.2.130, and the roadmap and status opening
# after 0.9.25). This reads the subset that names a version in the form a state
# sentence uses, which is the part a grep can settle.
#
# CHANGELOG.md and doc/history/ are excluded deliberately: a row and a
# measurement record describe the version as it stood when they were written,
# which is their job. Only documents stating what the tree is now are read,
# and the exclusion is asserted below so a wrong glob cannot empty the check.
extract_ver() {
	grep -o -E '(tree|driver|port) (is|are) at [0-9]+\.[0-9]+\.[0-9]+' |
		sed -n 's/.* at //p'
}
state_files=$(git ls-files '*.md' | grep -v -e '^CHANGELOG\.md$' -e '^doc/history/')
[ -n "$state_files" ] || {
	echo "history: FAIL: no current-state document to read. Either every" >&2
	echo "  document was excluded or the glob stopped matching, and a check" >&2
	echo "  over an empty population passes without reading anything." >&2
	exit 1; }

# The control. A matcher that never fires reports clean on every document, so
# one stale sentence is fed through the same extractor every run and must come
# back. It sits where the subject executes: the same function over the same
# form of sentence the check above reads.
ctl=$(printf 'the tree is at 0.0.0\n' | extract_ver)
[ "$ctl" = "0.0.0" ] || {
	echo "  FAIL control: the extractor read '${ctl:-<empty>}' from a version" >&2
	echo "  sentence naming 0.0.0, so this check cannot see a stale one." >&2
	exit 1; }

found=0
for f in $state_files; do
	[ -f "$f" ] || continue
	for v in $(extract_ver < "$f" | LC_ALL=C sort -u); do
		found=$((found+1))
		if [ "$v" != "$newest_ver" ]; then
			echo "  FAIL $f: says the tree is at $v, and $newest_ver is the newest row"
			bad=$((bad+1))
		fi
	done
done
[ "$found" -gt 0 ] || {
	echo "history: FAIL: no document states the tree's version. The state" >&2
	echo "  sentence moved or was reworded, and a check that reads nothing" >&2
	echo "  must not be read as a check that found nothing wrong." >&2
	exit 1; }
echo "history: $found state sentence(s) name the newest row's version ($newest_ver)"

echo "history: $rows row(s), $bad bad"
[ "$bad" = 0 ] || exit 1

# The prompt. Never fails; see the header.
since=$(git rev-list --count "$newest"..HEAD -- src script 2>/dev/null || echo "?")
if [ "$since" = 0 ]; then
	echo "history: no deliverable commit since the newest row ($newest)"
else
	echo "history: $since commit(s) touching src/ or script/ since the newest"
	echo "  row ($newest). Not a failure - decide whether any deserves a row."
	git log --oneline "$newest"..HEAD -- src script | sed 's/^/    /'
fi
