#!/bin/sh
# Vale over every tracked markdown file, with the same styles Saxum uses.
#
# WHY THIS EXISTS. doc/research/ arrived on 2026-08-29 from Saxum, where it
# had been governed by that repo's prose gates since 2026-08-25. It was added
# there because those documents had been structure-checked and never read by
# vale, and twelve British spellings were sitting in them when the corpus
# finally widened. Moving prose out of a governed tree and leaving it
# ungoverned recreates that defect exactly, so the gate moved with the files.
#
# AND THEN THIS GATE DID IT AGAIN. Until 2026-09-04 the population was
# `find doc`, which is every document except the four a reader meets first:
# README.md, CONTRIBUTING.md, CHANGELOG.md and the pull request template. The
# README's opening paragraph said this port does not mount anything for four
# days after it began mounting, and when the population finally widened those
# four files carried seven British spellings between them. The lesson the
# paragraph above records was applied to the directory that prompted it and
# not to the tree. The population is now the tracked set, so a new markdown
# file is governed the day it is committed rather than the day someone
# remembers to add it.
set -u
cd "$(dirname "$0")/.." || exit 2
command -v vale >/dev/null || { echo "doc-prose: COULD-NOT-RUN: no vale"; exit 2; }
# Tracked rather than found, so a file the repository does not carry cannot
# fail the gate and a file it does carry cannot escape it. git ls-files is the
# authority on what this repository ships.
command -v git >/dev/null || { echo "doc-prose: COULD-NOT-RUN: no git"; exit 2; }
files=$(git ls-files '*.md' 2>/dev/null)
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
