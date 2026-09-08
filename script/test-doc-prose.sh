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
hits=$(printf '%s\n' "$out" | grep -cE ' (error|warning|suggestion) ')
echo "doc-prose: $n document(s) examined, $hits finding(s)"
[ "$hits" -eq 0 ] || { echo "doc-prose: FAIL: the corpus is governed, so a finding is a failure"; exit 1; }
exit 0
