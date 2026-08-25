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
# WHAT IT CANNOT CATCH, said here so a green run is read for what it is: a row
# whose anchor is a bare identifier common throughout the cited file (`dio`,
# `folio`) will match a neighbouring line as readily as the right one, so a
# small drift is invisible for that row. The counts printed at the end separate
# symbol-anchored from literal-anchored from unanchored precisely so the
# strength of a pass is visible rather than averaged into one number.
#
# Exit 0 pass, 1 one or more citations wrong, 2 could not run.
set -u
cd "$(dirname "$0")/.." || exit 2

docs=$(ls doc/*.md 2>/dev/null) || true
[ -n "$docs" ] || { echo "citations: COULD-NOT-RUN: no doc/*.md" >&2; exit 2; }

fail=0
checked=0
unanchored=0
weakpass=0
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
		# The anchor is the first backticked token in the prose column. A token
		# that is a plain identifier (with or without call parens) is a STRONG
		# anchor. Anything else -- `struct hammer2_dev`, `dio->psize`, a whole
		# KKASSERT expression -- would anchor on its first word, which matches
		# almost any line in the file and passes vacuously, so it is matched in
		# full and reported as weak when its leading identifier is all that is
		# left. A weak pass is named, never counted as a strong one.
		tok=$(printf '%s\n' "$line" | sed 's/^| *`[^`]*` *|//' \
			| sed -n 's/[^`]*`\([^`]*\)`.*/\1/p' | head -1)
		# Reset both per row: a case with no matching branch leaves the
		# previous row's value in place, which reads as a real mismatch on a
		# line that was never asked about.
		weak=0
		sym=
		case "$tok" in
		"") ;;
		*"()") sym=${tok%"()"} ;;
		*[!A-Za-z0-9_]*) sym=$tok; weak=1 ;;
		*) sym=$tok ;;
		esac
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
			if sed -n "${lo},${hi}p" "$path" | command grep -qF -- "$sym"; then
				if [ "$weak" -eq 1 ]; then
					weakpass=$((weakpass + 1))
					echo "note $d: $cite -- anchored on the literal '$sym', which is prose rather than a symbol"
				else
					checked=$((checked + 1))
				fi
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

echo "citations: $rows row(s), $checked symbol-anchored pass(es), $weakpass literal-anchored, $unanchored unanchored, $fail failure(s)"
[ "$fail" -eq 0 ] || exit 1
exit 0
