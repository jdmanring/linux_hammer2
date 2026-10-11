#!/bin/sh
# Vale over every tracked markdown file, with the house rules in styles/.
#
# The population is the tracked set, not doc/: the four files a reader meets
# first (README.md, CONTRIBUTING.md, CHANGELOG.md, the pull request template)
# went unread for six days while the sweep was `find doc`, and carried seven
# misspellings between them when it widened.
set -u
cd "$(dirname "$0")/.." || exit 2
command -v vale >/dev/null || { echo "doc-prose: COULD-NOT-RUN: no vale"; exit 2; }

# The control.  .vale.ini says the gate asserts that a finding survives a
# fence above it, and until 2026-10-10 it did not: the gate had no
# selftest at all, so that sentence described a check nobody had written.
# The claim is made true rather than deleted, because the mechanism it is
# about is load-bearing: a rule suppressed for the rest of a file would let
# every document pass behind a fence, and the only way to know it does not
# is to plant a violation after one and require the finding.
#
# Two probes, in a temporary directory so nothing here is governed by the
# run that follows: one in plain prose that must be found, and one under a
# fence that must also be found. The first is what separates "the rules
# stopped firing" from "the documents improved".
if [ "${1:-}" = "--selftest" ]; then
	tmp=$(mktemp -d) || exit 2
	trap 'rm -rf "$tmp"' EXIT INT TERM
	printf 'A sentence with in order to fail.\n' > "$tmp/plain.md"
	printf '```\ncode\n```\n\nA sentence with in order to fail.\n' > "$tmp/fenced.md"
	cp .vale.ini "$tmp/" && cp -r styles "$tmp/"
	p=$(cd "$tmp" && vale --no-exit --config .vale.ini plain.md 2>&1 | grep -vE '^(✖|✔) ' | grep -cE ' (error|warning|suggestion) ')
	f=$(cd "$tmp" && vale --no-exit --config .vale.ini fenced.md 2>&1 | grep -vE '^(✖|✔) ' | grep -cE ' (error|warning|suggestion) ')
	if [ "$p" -lt 1 ]; then
		echo "doc-prose: FAIL: a planted violation in plain prose was not found" >&2
		echo "         the rules are not firing, so a clean corpus means nothing" >&2
		exit 1
	fi
	if [ "$f" -lt 1 ]; then
		echo "doc-prose: FAIL: a planted violation after a fence was not found" >&2
		echo "         the rules stop at a fence, so a document could hide behind one" >&2
		exit 1
	fi
	echo "doc-prose: selftest: $p finding(s) in plain prose, $f after a fence, both required"
	exit 0
fi

# Tracked rather than found, so a file the repository does not carry cannot
# fail the gate and a file it does carry cannot escape it. git ls-files is the
# authority on what this repository ships.
# A release tarball is not a repository, and everything in it is what
# the release ships, so there the population is the tree itself; the
# root assertion below holds either way.
if command -v git >/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
	files=$(git ls-files '*.md' 2>/dev/null)
else
	files=$(find . -name '*.md' -not -path './.git/*' | sed 's|^\./||' | LC_ALL=C sort)
fi
# Captured primary sources are other people's text, kept so a claim in this
# repository's documents can be checked against them. The house rules
# cannot be applied there: editing RFC 8881 or the SMB2 specification to
# satisfy a style rule would falsify the evidence. Measured when this was
# added: 246 findings across doc/research/primary/, every one in the IETF's
# or Microsoft's prose. The exclusion is this one directory, by path,
# and everything that cites from it stays governed.
files=$(printf '%s\n' "$files" | grep -v '^doc/research/primary/')
n=$(printf '%s\n' "$files" | grep -c '\.md$')
[ "$n" -gt 0 ] || { echo "doc-prose: FAIL: no documents found, an empty sweep cannot pass"; exit 1; }
# The root is asserted by name, not counted. A population that silently
# narrowed back to doc/ would still be non-empty and would still pass, which
# is exactly how this gate read past the README for six days.
for must in README.md CONTRIBUTING.md CHANGELOG.md; do
	printf '%s\n' "$files" | grep -qx "$must" || {
		echo "doc-prose: FAIL: $must is tracked but not in the population," >&2
		echo "         so the files a reader meets first are ungoverned" >&2
		exit 1
	}
done
out=$(vale --no-exit --config .vale.ini $files 2>&1)
printf '%s\n' "$out"
# Vale's own status is nonzero for errors only, so a corpus carrying nothing but
# warnings printed twelve findings and exited 0 on every run from 2026-08-29 to
# 2026-09-02. The gate counts the findings itself rather than reading that status.
# vale's closing summary reads "1 warning and" for a single finding, which
# the pattern also matches, so one finding counted as two; the summary line
# is excluded by its leading mark rather than by its wording.
hits=$(printf '%s\n' "$out" | grep -vE '^(✖|✔) ' | grep -cE ' (error|warning|suggestion) ')
echo "doc-prose: $n document(s) examined, $hits finding(s)"
[ "$hits" -eq 0 ] || { echo "doc-prose: FAIL: the corpus is governed, so a finding is a failure"; exit 1; }
exit 0
