# Rewritten history

This repository's history was rewritten once, on 2026-08-25, before it had
any forks, stars or watchers. `2026-08-25-rewrite-commit-map.txt` is the
old-to-new commit map: two 40-character hashes per line, old then new,
after a header line. 32 entries, of which 21 changed. A line whose columns
are equal is a commit the rewrite did not touch.

## Why

Development of this port is driven by a Linux distribution that consumes
it. The port is not part of that distribution, and a kernel reviewer has
no reason to care which distribution paid for the work, so the project's
name did not belong in a public tree. It was removed from the working
tree first; the rewrite removed it from the history behind it, along with
two references to a private specification repository.

Nothing else was touched: no file was added or deleted, no authorship or
date changed, and the tree at the tip is byte-identical to the tree before
the rewrite. That last property is the check worth repeating, because it
is the one a purge can silently fail: the tip already carried no
occurrence, so a filter that reached anything it should not have would
have moved it.

## Reading a hash written before 2026-08-25

    awk '$1 ~ /^<old-prefix>/ {print $2}' doc/history/2026-08-25-rewrite-commit-map.txt

Citations inside this repository were swept at the time and resolve
directly; `script/test-history.sh` fails on any roadmap row whose commit
does not resolve, so a missed one is caught rather than merely unlikely.
The map is here for readers holding a hash from outside the tree.
