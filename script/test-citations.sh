#!/bin/sh
# Every `file:line` citation in a doc/ table resolves, and where the row names
# a symbol, that symbol is ON the cited line.
#
# doc/IO_MODEL.md's 64 KiB inventory is thirteen rows of
# `hammer2_disk.h:111`-style citation. Line numbers rot the moment a file is
# edited, and the 0.2 import edits exactly these files. A drifted citation
# still looks like a citation, and whoever follows it lands on a neighbouring
# define and believes it.
#
# The source line is the truth, so there is no stored baseline to compare
# against; one here would be this repository checking its own output.
#
# A row whose prose names no backticked symbol can only be checked for
# existence. Those are reported as unanchored, not skipped, or the pass count
# becomes a fact about the filter.
#
# What it cannot catch: a row anchored on a bare identifier common throughout
# the cited file (`dio`, `folio`) matches a neighbouring line as readily as the
# right one. The counts at the end separate symbol-anchored from
# literal-anchored from unanchored so the strength of a pass stays visible.
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
		# The anchor is the first backticked token in the prose column. A
		# plain identifier, with or without call parens, is a strong anchor.
		# Anything else (`struct hammer2_dev`, `dio->psize`, a whole KKASSERT
		# expression) would anchor on its first word and match almost any line
		# in the file, so it is matched in full and reported as a weak pass.
		tok=$(printf '%s\n' "$line" | sed 's/^| *`[^`]*` *|//' \
			| sed -n 's/[^`]*`\([^`]*\)`.*/\1/p' | head -1)
		# Reset both per row. A case with no matching branch leaves the
		# previous row's value in place, which reads as a mismatch on a
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
				# Say where it went. A failure that only says
				# "not there" gets repaired by re-deriving the
				# line by hand. Line drift is survivable and
				# file drift is not, so the search widens to
				# the tree instead of stopping at the cited
				# path.
				at=$(command grep -nF -- "$sym" "$path" 2>/dev/null |
					cut -d: -f1 | tr '\n' ',' | sed 's/,$//')
				if [ -n "$at" ]; then
					echo "     it is on ${file}:${at}"
				else
					elsewhere=$(command grep -rlF -- "$sym" src doc script test 2>/dev/null |
						head -3 | tr '\n' ' ')
					if [ -n "$elsewhere" ]; then
						echo "     not in $file at all; found in: $elsewhere"
					else
						echo "     and '$sym' is nowhere in the tree, so the anchor is gone"
					fi
				fi
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

# Print what is not covered beside what is. This gate reads citations in
# table rows only. One in prose, or one naming a kernel header or another
# port's tree, is matched by nothing here, and an unmentioned citation sitting
# among checked ones inherits their credibility. Measured 2026-08-26: 20
# citation-shaped tokens in doc/, 15 of them in rows this gate reads.
#
# The floor below exists because a broken counting pattern also prints zero
# uncovered, which reads as "nothing uncovered" instead of "nothing asked".
allcites=$(command grep -roE '`[A-Za-z0-9_./-]+\.(c|h|sh|md|txt|pl):[0-9]+' doc/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$allcites" -lt "$rows" ]; then
	echo "citations: FAIL: counted $allcites citation-shaped tokens in doc/ but" >&2
	echo "  read $rows table rows, so the counting pattern has stopped" >&2
	echo "  matching and the uncovered figure below would understate" >&2
	exit 1
fi
uncovered=$((allcites - rows))

echo "citations: $rows row(s) read, $checked symbol-anchored pass(es), $weakpass literal-anchored, $unanchored unanchored note(s), $fail failure(s)"
echo "citations: $uncovered of $allcites citation-shaped tokens in doc/ are OUTSIDE a table row and unchecked here"
# Name them, do not just count them. A bare number leaves the reader guessing
# which citations it means.
if [ "$uncovered" -gt 0 ]; then
	command grep -roE '`[A-Za-z0-9_./-]+\.(c|h|sh|md|txt|pl):[0-9]+[0-9,-]*`' doc/ 2>/dev/null |
		sed 's/`//g' | while IFS=: read -r doc rest; do
			cited=$rest
			command grep -qF -- "| \`$cited\` |" "$doc" || echo "  unchecked  $doc: $cited"
		done
fi
[ "$fail" -eq 0 ] || exit 1
exit 0
