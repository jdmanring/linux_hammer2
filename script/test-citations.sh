#!/bin/sh
# Every `file:line` citation in a doc/ table resolves, and where the row names
# a symbol, that symbol is ON the cited line.
#
# WHY THIS EXISTS. doc/IO_MODEL.md's 64 KiB inventory is thirteen rows of
# `hammer2_disk.h:111`-style citation, and version 0.1.5 claims each site is
# "cited to a line". Nothing read them. Line numbers rot the moment a file is
# edited, and the 0.2 import edits exactly these files -- so a citation that
# has drifted still LOOKS like a citation, and the reader who follows it lands
# on a neighbouring define and believes it.
#
# It does NOT compare against a stored baseline. The source line is the truth;
# a baseline here would be this repository's own output compared against
# itself, which is the class doc/README.roadmap.md 0.1.6 records.
#
# A row whose prose names no backticked symbol cannot be anchored beyond
# existence. Those are REPORTED as unanchored rather than skipped: a filter
# that silently drops rows makes the pass count a fact about the filter.
#
# Exit 0 pass, 1 one or more citations wrong, 2 could not run.
set -u
cd "$(dirname "$0")/.." || exit 2

docs=$(ls doc/*.md 2>/dev/null) || true
[ -n "$docs" ] || { echo "citations: COULD-NOT-RUN: no doc/*.md" >&2; exit 2; }

fail=0
checked=0
unanchored=0
rows=0

for d in $docs; do
	while IFS= read -r line; do
		cite=$(printf '%s\n' "$line" | sed -n 's/^| *`\([A-Za-z0-9_./-]*:[0-9][0-9,-]*\)` *|.*/\1/p')
		[ -n "$cite" ] || continue
		rows=$((rows + 1))
		file=${cite%%:*}
		spec=${cite#*:}
		case "$file" in
		*/*) path=$file ;;
		*) path=src/sys/fs/hammer2/$file ;;
		esac
		if [ ! -f "$path" ]; then
			echo "FAIL $d: $cite -- no such file ($path)"
			fail=$((fail + 1))
			continue
		fi
		total=$(wc -l < "$path")
		# The anchor is the first backticked identifier in the prose column.
		sym=$(printf '%s\n' "$line" | sed 's/^| *`[^`]*` *|//' \
			| sed -n 's/.*`\([A-Za-z_][A-Za-z0-9_]*\).*/\1/p' | head -1)
		for n in $(printf '%s\n' "$spec" | tr ',' ' '); do
			case "$n" in
			*-*) lo=${n%%-*}; hi=${n##*-} ;;
			*) lo=$n; hi=$n ;;
			esac
			if [ "$hi" -gt "$total" ]; then
				echo "FAIL $d: $cite -- line $hi past end of $path ($total lines)"
				fail=$((fail + 1))
				continue
			fi
			if [ -z "$sym" ]; then
				unanchored=$((unanchored + 1))
				echo "note $d: $cite -- row names no symbol, existence checked only"
				continue
			fi
			if sed -n "${lo},${hi}p" "$path" | command grep -q -- "$sym"; then
				checked=$((checked + 1))
			else
				echo "FAIL $d: $cite -- '$sym' is not on ${file}:${n}"
				fail=$((fail + 1))
			fi
		done
	done < "$d"
done

# A population of zero would pass silently, which is the whole failure this
# gate is written against.
if [ "$rows" -eq 0 ]; then
	echo "citations: COULD-NOT-RUN: no file:line citation rows found in doc/*.md" >&2
	exit 2
fi

echo "citations: $rows row(s), $checked anchored check(s) passed, $unanchored unanchored, $fail failure(s)"
[ "$fail" -eq 0 ] || exit 1
exit 0
