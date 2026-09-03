#!/bin/sh
# Vale over doc/, with the same styles ArtNix uses.
#
# WHY THIS EXISTS. doc/research/ arrived on 2026-08-29 from ArtNix, where it
# had been governed by that repo's prose gates since 2026-08-25. It was added
# there because those documents had been structure-checked and never read by
# vale, and twelve British spellings were sitting in them when the corpus
# finally widened. Moving prose out of a governed tree and leaving it
# ungoverned recreates that defect exactly, so the gate moved with the files.
set -u
cd "$(dirname "$0")/.." || exit 2
command -v vale >/dev/null || { echo "doc-prose: COULD-NOT-RUN: no vale"; exit 2; }
n=$(find doc -name '*.md' | wc -l)
[ "$n" -gt 0 ] || { echo "doc-prose: FAIL: no documents found, an empty sweep cannot pass"; exit 1; }
out=$(vale --no-exit --config .vale.ini $(find doc -name '*.md') 2>&1)
printf '%s\n' "$out"
# Vale's own status is nonzero for errors only, so a corpus carrying nothing but
# warnings printed twelve findings and exited 0 on every run from 2026-08-29 to
# 2026-09-02. The gate counts the findings itself rather than reading that status.
hits=$(printf '%s\n' "$out" | grep -cE ' (error|warning|suggestion) ')
echo "doc-prose: $n document(s) examined, $hits finding(s)"
[ "$hits" -eq 0 ] || { echo "doc-prose: FAIL: the corpus is governed, so a finding is a failure"; exit 1; }
exit 0
