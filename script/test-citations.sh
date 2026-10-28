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

docs=$(ls doc/*.md doc/history/*.md 2>/dev/null) || true
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
					elsewhere=$(command grep -rlF \
						--exclude='*.o' --exclude='*.ko' \
						--exclude='*.mod' --exclude='*.mod.c' \
						--exclude='*.cmd' --exclude='*.o.d' \
						--exclude='*.order' \
						--exclude='*.symvers' \
						-- "$sym" src doc script test 2>/dev/null |
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


# DO NOT "fix" a stale-looking citation in doc/history/verification-record.md.
# That file's header states its contract: a sentence there says what was true
# at the commit it names and is not rewritten when the tree moves. Measured
# 2026-10-13, 19 of its prose citations point at lines the tree has since
# moved, and every one is correct as written because it records what was read
# at the time -- an `addr2line` resolution against a build, a symbol's line on
# the day a defect was found. Rewriting one falsifies the record of the
# measurement the sections around it were reasoned from. The prose half below
# leaves that file out for this reason.
#
# Prose citations of the port's source in the living documents, which the
# rows above leave unchecked. Each `file.c:N` or `file.h:N` names a file in
# the port, found by its name under src/sys/fs/hammer2/ or src/sys/sys/, or
# by a path starting src/sys/; a path into another tree (a kernel's, an
# upstream's) is not this repository's to check and is left alone. A bare
# .c or .h name, or a src/sys/ path, that resolves nowhere fails, since that
# is what a renamed or removed file leaves behind, and so does a bare `:N`
# after it. A file name ends where a word does, so `head.cluster` names no
# file. A bare `:N` is the last named file's, the way a reader reads it, and
# is left alone when that file is a script, a document or another tree's.
# Every number of a list (`:N, M`) is checked, and the end of a range must
# lie inside the file. A cited line fails when it is past the end of its
# file, blank, a closing brace or the close of a comment, which is where a
# citation lands when the lines it named moved. That is a placement check and
# no more: a citation moved onto other code, or into the middle of a comment,
# still passes, and only reading its sentence finds it. Kusumi's FreeBSD port
# keeps the same src/sys/fs/hammer2/ path, so a citation into it must name
# its tree some other way or it is read as this port's.
#
# The dated records (doc/history, doc/research, doc/upstream, CHANGELOG.md)
# say what was true at a commit and are left out. A section of a living
# document whose line citations were read against one commit opens with the
# line `<!-- citations at HASH -->` and closes with the line
# `<!-- citations end -->`, and its citations are checked against that
# commit's files, so the record is held to what it records rather than to
# the tree as it moves. A region left open, a fenced block left open, an
# end with no region open and a line that resembles a marker without being
# one all fail, and a marker inside a fenced block, delimited as CommonMark
# delimits one, is an example and opens nothing. A quoted kernel message
# (`kernel BUG at file.c:N!`) is a line of the build that printed it and is
# left out. Run against the documents of b12aaae it fails 34 of 387, 32 of
# them in the two design notes.
proseok=0
prosefail=0
prosechecked=
for d in $(git ls-files '*.md' | command grep -v -e '^doc/history/' -e '^doc/research/' -e '^doc/upstream/' -e '^CHANGELOG.md$'); do
	out=$(awk -v doc="$d" '
	function exists(p) {
		if (at != "")
			return (system("git cat-file -e " at ":" p " 2>/dev/null") == 0)
		if ((getline l < p) >= 0) { close(p); return 1 }
		return 0
	}
	function srcpath(f) {
		if (f ~ /\//) return ((f ~ /^src\/sys\// && exists(f)) ? f : "")
		if (exists("src/sys/fs/hammer2/" f)) return "src/sys/fs/hammer2/" f
		if (exists("src/sys/sys/" f)) return "src/sys/sys/" f
		return ""
	}
	function lineof(p, n,   i, l, k, cmd) {
		k = at SUBSEP p
		if (!(k in loaded)) {
			i = 0
			if (at != "") {
				cmd = "git show " at ":" p
				while ((cmd | getline l) > 0) text[k, ++i] = l
				close(cmd)
			} else {
				while ((getline l < p) > 0) text[k, ++i] = l
				close(p)
			}
			nlines[k] = i; loaded[k] = 1
		}
		if (n > nlines[k]) return "\001past"
		return text[k, n]
	}
	function check(spec,   e, ne, i, a, b, l, s) {
		print "SEEN " doc ": " cf ":" spec
		ne = split(spec, e, ", *")
		for (i = 1; i <= ne; i++) {
			a = e[i]; b = ""
			if (a ~ /-/) { b = a; sub(/-.*/, "", a); sub(/.*-/, "", b) }
			l = lineof(cur, a + 0)
			s = l; gsub(/^[ \t]+|[ \t]+$/, "", s)
			if (l == "\001past" || s == "" || s == "}" || s == "};" || s == "*/")
				bad("lands on [" (l == "\001past" ? "past the end" : s) "]", a)
			else if (b != "" && lineof(cur, b + 0) == "\001past")
				bad("ends past the end of the file", a "-" b)
			else
				print "OK"
		}
	}
	function bad(why, n) {
		print "BAD " doc ":" NR ": " cf ":" n " " why (at != "" ? " at " at : "")
	}
	# A marker is a line of its own outside a fenced block, so one quoted
	# in prose or shown in an example opens nothing, and its hash is hex
	# before it reaches the shell. A line that looks like a marker and is
	# not one, or an end with no region open, fails rather than leaving
	# citations read against the wrong tree. Fences are as in CommonMark: a run
	# of three or more backticks or tildes indented at most three spaces, a
	# backtick run with no backtick after it on the line (so an inline code
	# span opens nothing), closed only by a bare run of the same character
	# at least as long, so a shorter run inside is content; a fence left
	# open fails. A fence indented further is not one, and a marker shown
	# in it fails rather than being skipped.
	{
		f = ""
		if ($0 ~ /^(   |  | )?(```+[^`]*|~~~+.*)$/) {
			f = $0; sub(/^ */, "", f); match(f, /^(`+|~+)/); f = substr(f, 1, RLENGTH)
		}
		if (fence == "") {
			if (f != "") { fence = f; fenceline = NR }
		} else if (f != "" && $0 ~ /^(   |  | )?(`+|~+)[ \t]*$/ &&
		    substr(f, 1, 1) == substr(fence, 1, 1) && length(f) >= length(fence))
			fence = ""
	}
	fence == "" && /^<!-- citations at [0-9a-f]+ -->$/ {
		at = $0; sub(/^<!-- citations at /, "", at); sub(/ -->$/, "", at)
		if (at !~ /^[0-9a-f]+$/ ||
		    system("git cat-file -e " at "^{commit} 2>/dev/null") != 0) {
			print "BAD " doc ":" NR ": region pinned to " at ", which is not a commit here"
			at = ""
		}
		atline = NR; cur = ""; next
	}
	fence == "" && /^<!-- citations end -->$/ {
		if (atline == 0)
			print "BAD " doc ":" NR ": a region end with no region open"
		at = ""; atline = 0; cur = ""; next
	}
	fence == "" && /^[ \t]*<!-- *citations/ {
		print "BAD " doc ":" NR ": not a region marker: " $0
		next
	}
	{
		rest = $0
		while (match(rest, /`:[0-9]+(-[0-9]+)?(, *[0-9]+(-[0-9]+)?)*|[A-Za-z0-9_.\/-]*\.(c|h|sh|py|pl|md|txt|yaml)(:[0-9]+(-[0-9]+)?(, *[0-9]+(-[0-9]+)?)*)?/)) {
			t = substr(rest, RSTART, RLENGTH)
			pre = substr(rest, 1, RSTART - 1)
			rest = substr(rest, RSTART + RLENGTH)
			if (t ~ /^`:/) {
				if (cur == "\001none") {
					print "BAD " doc ":" NR ": " substr(t, 2) " follows " cf ", which names no file of the port" (at != "" ? " at " at : "")
					continue
				}
				if (cur == "") continue
				check(substr(t, 3))
				continue
			}
			# A file name ends where a word does: `head.cluster` and
			# `github.com` are not files.
			if (t !~ /:/ && rest ~ /^[A-Za-z0-9_]/) continue
			f = t; sub(/:.*/, "", f)
			if (pre ~ /kernel BUG at $/) { cur = ""; continue }
			cur = srcpath(f); cf = f
			# A source name, bare or under src/sys/, that
			# resolves nowhere is what a renamed or removed file leaves;
			# a bare `:N` after it fails with it.
			if (cur == "" && (f ~ /^src\/sys\// || (f !~ /\// && f ~ /\.[ch]$/))) {
				cur = "\001none"
				if (t ~ /:/)
					print "BAD " doc ":" NR ": " t " names no file of the port" (at != "" ? " at " at : "")
				continue
			}
			if (t !~ /:/ || cur == "") continue
			spec = t; sub(/^[^:]*:/, "", spec)
			check(spec)
		}
	}
	END {
		if (at != "")
			print "BAD " doc ":" atline ": region pinned to " at " is never closed"
		if (fence != "")
			print "BAD " doc ":" fenceline ": a fenced block opened by " fence " is never closed"
	}' "$d")
	s=$?
	if [ "$s" -ne 0 ]; then
		echo "citations: FAIL: the prose reader stopped with status $s on $d" >&2
		prosefail=$((prosefail + 1))
	fi
	proseok=$((proseok + $(printf '%s\n' "$out" | command grep -c '^OK' || true)))
	prosechecked="$prosechecked
$(printf '%s\n' "$out" | sed -n 's/^SEEN //p')"
	bad=$(printf '%s\n' "$out" | command grep '^BAD' || true)
	if [ -n "$bad" ]; then
		printf '%s\n' "$bad" | sed 's/^BAD /  FAIL prose /' >&2
		prosefail=$((prosefail + $(printf '%s\n' "$bad" | wc -l)))
	fi
done

# Print what neither half reads beside what they do. An unmentioned citation
# sitting among checked ones inherits their credibility: one naming a kernel
# file or another port's tree, or one in a dated record. Measured 2026-08-26,
# before the prose half: 20 citation-shaped tokens in doc/, 15 of them in rows
# this gate reads. The floor below exists because a broken counting pattern
# also prints zero, which reads as "nothing uncovered" instead of "nothing
# asked".
allcites=$(command grep -roE '`[A-Za-z0-9_./-]+\.(c|h|sh|md|txt|pl):[0-9]+' doc/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$allcites" -lt "$rows" ]; then
	echo "citations: FAIL: counted $allcites citation-shaped tokens in doc/ but" >&2
	echo "  read $rows table rows, so the counting pattern has stopped" >&2
	echo "  matching and the uncovered figure below would understate" >&2
	exit 1
fi
echo "citations: $rows row(s) read, $checked symbol-anchored pass(es), $weakpass literal-anchored, $unanchored unanchored note(s), $fail failure(s)"
# Name them, do not just count them. A bare number leaves the reader guessing
# which citations it means.
unchecked=$(command grep -roE '`[A-Za-z0-9_./-]+\.(c|h|sh|md|txt|pl):[0-9]+[0-9,-]*`' doc/ 2>/dev/null |
	sed 's/`//g' | while IFS=: read -r doc rest; do
		cited=$rest
		command grep -qF -- "| \`$cited\` |" "$doc" && continue
		printf '%s\n' "$prosechecked" | command grep -qxF -- "$doc: $cited" && continue
		echo "  unchecked  $doc: $cited"
	done)
echo "citations: $(printf '%s' "$unchecked" | command grep -c unchecked || true) of $allcites citation-shaped tokens in doc/ are read by neither half"
[ -n "$unchecked" ] && printf '%s\n' "$unchecked"

if [ $((proseok + prosefail)) -eq 0 ]; then
	echo "citations: COULD-NOT-RUN: no prose citation of the source found in the living documents" >&2
	# A table failure already read is a failure, not an instrument that
	# could not run.
	[ "$fail" -eq 0 ] || exit 1
	exit 2
fi
echo "citations: $((proseok + prosefail)) prose citation(s) of the source in the living documents, $prosefail failure(s)"
[ "$fail" -eq 0 ] && [ "$prosefail" -eq 0 ] || exit 1
exit 0
