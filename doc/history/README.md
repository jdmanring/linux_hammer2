# Rewritten history

This repository's history was rewritten on 2026-08-25, before it had any
forks, stars or watchers, and once more on 2026-08-26, when a private
instructions file and a symbol index were purged from every commit; the
0.2.7 row in `CHANGELOG.md` records that one, and its 47 remapped
citations were checked against a pre-rewrite mirror. The map here is
the first rewrite's. `2026-08-25-rewrite-commit-map.txt` is the
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
directly; `script/test-history.sh` fails on any changelog row whose commit
does not resolve, so a missed one is caught rather than merely unlikely.
The map is here for readers holding a hash from outside the tree.

## The third rewrite, 2026-10-16

`2026-10-16-rewrite-commit-map.txt` is the map of the third rewrite, same
format: 1337 entries, of which 321 changed. Only commit messages changed;
the tree at every commit is the one it was, checked by comparing the
final tree objects. The cause was the pre-push hook: 89 of 329 unpushed
commits carried a subject over 72 characters, the commit's own date in
the body, or a quoted first person, and the branch had not been pushed
since the first of them. The 89 messages were rewritten (subjects
shortened, the date phrase replaced by "the same day", the quote
paraphrased) and every commit after the earliest took a new hash. The 61
hash citations in `CHANGELOG.md` and `doc/history/verification-record.md`
were remapped through this file by unique prefix, and `test-history.sh`
and `test-citations.sh` read 0 bad on the result. A `commit-msg` hook
now runs the same checks when a commit is made, so the number cannot
grow again behind the push gate.
