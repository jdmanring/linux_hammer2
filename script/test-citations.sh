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
# The prose half also reads each citation's age: the cited line at the
# commit the citation was written in against the same line now, so a
# file that moved under a citation fails even where the line it now
# names is code. See the comments at age() and rot() below.
#
# What it cannot catch: a row anchored on a bare identifier common throughout
# the cited file (`dio`, `folio`) matches a neighbouring line as readily as the
# right one. The counts at the end separate symbol-anchored from
# literal-anchored from unanchored so the strength of a pass stays visible.
#
# Exit 0 pass, 1 one or more citations wrong, 2 could not run.
set -u
# --selftest builds a scratch repository whose history holds a citation
# for each way the rot check dates or maps one, runs this script against
# it, and checks every expected line; then it runs it again with each git
# read failing in turn through a shim, with an external diff tool and an
# ignored-revisions file configured, on a clone whose blame answers
# nothing, and on a shallow clone. Exit 0 pass, 1 fail, 2 could not build.
if [ "${1:-}" = "--selftest" ]; then
	realgit=$(command -v git) || exit 2
	me=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
	t=$(mktemp -d) || exit 2
	trap 'rm -rf "$t"' EXIT
	if ! (
		set -e
		cd "$t"
		git init -q r
		cd r
		git config user.email selftest@localhost
		git config user.name selftest
		git config commit.gpgsign false
		mkdir -p script doc src/sys/fs/hammer2
		cp "$me" script/test-citations.sh
		i=1
		while [ "$i" -le 200 ]; do printf 'int l_%03d;\n' "$i"; i=$((i + 1)); done > src/sys/fs/hammer2/zz.c
		cp src/sys/fs/hammer2/zz.c src/sys/fs/hammer2/yy.c
		cp src/sys/fs/hammer2/zz.c src/sys/fs/hammer2/vv.c
		# Each case sits between lines no commit touches, so each is
		# its own hunk.
		printf '%s\n' '| site | what |' '|---|---|' '| `zz.c:1` | `l_001` |' '' \
		    'Inplace `zz.c:3` here.' 'Inplacetwo `zz.c:2` here.' 'Region `zz.c:7` here.' 'Edge `zz.c:15` here.' \
		    'Moved `zz.c:30` here.' 'MovedEdit `zz.c:20` here.' \
		    'A `zz.c:40` here.' 'B `zz.c:50` here.' \
		    'First `zz.c:70` here.' 'Second `zz.c:70` here.' \
		    'Gone `zz.c:100` here.' 'Prefix `zz.c:123` here.' \
		    'Bare `zz.c:140`, `:150` here.' \
		    'Reflow alpha `zz.c:45` beta.' 'Reflow gamma delta.' \
		    'List `zz.c:30, 60` here.' 'Range `zz.c:90-95` here.' \
		    'Seven `yy.c:5`, `:165` here.' 'Path `src/sys/fs/hammer2/zz.c:120` here.' \
		    'Span `zz.c:150-159` here.' \
		    'Ctx in `yy.c` see' '`:75` there.' \
		    'Ctxtwo in `yy.c` see' '`:85` there.' \
		    'Ctxthree in `yy.c` see' '`:20` there.' \
		    'Ctxfour in `yy.c` see' '`:95` there.' \
		    'Ctxfive in `yy.c` see' '`:30` there.' \
		    'Lead in `zz.c` see' '`:80` there, then `yy.c:3`.' \
		    'Retire `zz.c:2` here.' \
		    'Sep one.' 'Twin `zz.c:44` here.' 'Twin `zz.c:46` here.' \
		    'Sep two.' '(`zz.c:32, 62`,' \
		    'Sep three.' 'Solo `zz.c:33` gone.' \
		    'Sep four.' 'Long line plus many other words in this ratio cat dog sentence `zz.c:99` here.' 'Ratio cat `zz.c:26`.' \
		    'Sep five.' 'Newfile `ww.c:5` here.' \
		    'Sep six.' 'Collapse `zz.c:110-115` here.' 'Shrink `zz.c:41-47` here.' \
		    'Sep seven.' \
		    'Deep: a sentence long enough for blame to follow when it is moved, citing `zz.c:38` here.' \
		    'Movedline: the pass compares every key below the break at `zz.c:110` in a sentence long enough for blame to follow.' \
		    > doc/a.md
		git add -A
		git commit -qm one
		# The source moves: lines 2 and 3 rewritten in place, line 7
		# made two, line 9 deleted, ten lines after line 15, line 20
		# rewritten, line 100 deleted. So lines up to 15 stay, 16 to 99
		# move by ten and 101 on by nine. ww.c is new. The document's
		# Deep line moves up, unchanged.
		awk 'NR == 2 { print "int l_002x;"; next } NR == 3 { print "int l_003x;"; next }
		    NR == 7 { print "int l_007a;"; print "int l_007b;"; next }
		    NR == 9 || NR == 100 { next }
		    NR == 20 { print "int l_020x;"; next }
		    { print }
		    NR == 15 { for (k = 1; k <= 10; k++) printf "int n_%02d;\n", k }' \
		    src/sys/fs/hammer2/zz.c > zz.new
		mv zz.new src/sys/fs/hammer2/zz.c
		cp src/sys/fs/hammer2/yy.c src/sys/fs/hammer2/ww.c
		{ sed -n '1,4p' doc/a.md; command grep '^Deep' doc/a.md; sed -n '5,$p' doc/a.md | command grep -v '^Deep'; } > a.new
		mv a.new doc/a.md
		git add -A
		git commit -qm two
		# The documents after a remap, some of it partial. Correct:
		# A and B shifted together, First, Span by its own length, the
		# Prefix line, Seven's file changed under a kept `:165`, Ctx's
		# file changed with its bare line reworded, Ctxtwo's and
		# Ctxthree's files changed with their bare lines untouched (named,
		# not dated), Ctxfour's the same until the next commit rewords
		# its bare line, Shrink collapsed to its start, the first Twin, Solo
		# rewritten whole into two lines, Retire reread. The Twins keep
		# identical words, so only their places pair them. Not carried,
		# the stated misses: Reflow, and Collapse to its end.
		# Stale and carried: Second, Bare, a List member, a Range start,
		# Path respelled, Lead's bare line, the second Twin, the line of
		# citations alone, Ratio, Deep reworded. Movedline moves up
		# unchanged.
		printf '%s\n' '| site | what |' '|---|---|' '| `zz.c:1` | `l_001` |' '' \
		    'Movedline: the pass compares every key below the break at `zz.c:110` in a sentence long enough for blame to follow.' \
		    'Deep, reworded: a sentence long enough for blame to follow when it is moved, citing `zz.c:38` here.' \
		    'Inplace `zz.c:3` here.' 'Inplacetwo `zz.c:2` here.' 'Region `zz.c:7` here.' 'Edge `zz.c:15` here.' \
		    'Moved `zz.c:30` here.' 'MovedEdit `zz.c:20` here.' \
		    'A `zz.c:50` here.' 'B `zz.c:60` here.' \
		    'First `zz.c:80` here.' 'Second, reworded, `zz.c:70` here.' \
		    'Gone `zz.c:100` here.' 'Prefix `zz.c:12` and `zz.c:132` here.' \
		    'Bare, reworded, `zz.c:140`, `:150` here.' \
		    'Reflow alpha beta.' 'Reflow gamma `zz.c:45` delta.' \
		    'List `zz.c:30, 70` here.' 'Range `zz.c:90-105` here.' \
		    'Seven `zz.c:5`, `:165` here.' 'Path, reworded, `zz.c:120` here.' \
		    'Span `zz.c:159-168` here.' \
		    'Ctx in `zz.c` see' '`:75` there, reworded.' \
		    'Ctxtwo in `zz.c` see' '`:85` there.' \
		    'Ctxthree in `vv.c` see' '`:20` there.' \
		    'Ctxfour in `zz.c` see' '`:95` there.' \
		    'Ctxfive in `vv.c` see' '`:30` there.' \
		    'Lead in `zz.c` see' '`:80` there, reworded, then `yy.c:3`.' \
		    'Retire, reread, `zz.c:2` here.' \
		    'Sep one.' 'Twin `zz.c:54` here.' 'Twin `zz.c:46`, here.' \
		    'Sep two.' '(`zz.c:32, 72`,' \
		    'Sep three.' 'Fresh words entirely `zz.c:33`.' 'Another added line.' \
		    'Sep four.' 'Something unrelated entirely.' 'Ratio cat dog `zz.c:26`.' \
		    'Sep five.' 'Newfile `ww.c:5` here.' \
		    'Sep six.' 'Collapse `zz.c:115` here.' 'Shrink `zz.c:41` here.' \
		    'Sep seven.' \
		    > doc/a.md
		printf 'x\n' > "doc/b'c.md"
		git add -A
		git commit -qm three
		# vv.c moves after the line naming it changed, and Ctxfour's bare
		# line is reworded a commit after its file changed above it, so
		# it dates from that change and not from the line's first commit,
		# where `:95` was yy.c's.
		# Ctxfive's is reworded in the same commit that moves vv.c, so
		# once dated it is read and fails.
		sed -e 's/^`:95` there./`:95` there, reread./' \
		    -e 's/^`:30` there./`:30` there, reread./' doc/a.md > a.new
		mv a.new doc/a.md
		{ printf 'int v_new;\n'; printf 'int v_new;\n'; printf 'int v_new;\n'; printf 'int v_new;\n'; printf 'int v_new;\n'; cat src/sys/fs/hammer2/vv.c; } > vv.new
		mv vv.new src/sys/fs/hammer2/vv.c
		git commit -qam four
		git rev-parse HEAD~1 > '.ignore revs'
		# Not committed: a stale citation reworded, which is carried from
		# HEAD, a citation of a line rewritten in place reworded, which
		# retires its note, and a citation written now, which is fresh.
		sed -e 's/^Gone `zz.c:100` here./Gone, reworded, `zz.c:100` here./' \
		    -e 's/^Inplacetwo `zz.c:2` here./Inplacetwo, reread, `zz.c:2` here./' doc/a.md > a.new
		mv a.new doc/a.md
		printf '%s\n' 'Fresh `zz.c:22` here.' >> doc/a.md
		git clone -q --depth 1 "file://$t/r" "$t/shallow"
		git -C "$t/shallow" rm -q "doc/b'c.md"
		git clone -q "file://$t/r" "$t/clean"
		git -C "$t/clean" rm -q "doc/b'c.md"
		mkdir "$t/shim"
		# A git that fails one kind of read, named by H2CIT_FAIL, by
		# running it and then exiting 1, so its output is whole and only
		# its status says it failed; everything else passes through.
		cat > "$t/shim/git" <<-SHIM
		#!/bin/sh
		sub=; skip=0; hasl=0
		for a do
			if [ \$skip = 1 ]; then skip=0; continue; fi
			case \$a in -c) skip=1 ;; -L) hasl=1 ;; -*) ;; *) [ -n "\$sub" ] || sub=\$a ;; esac
		done
		case "\${H2CIT_FAIL:-}:\$sub:\$hasl" in
		show:show:*|diff:diff:*|ls-tree:ls-tree:*|blame-L:blame:1|blame:blame:0) "$realgit" "\$@"; exit 1 ;;
		blame-empty:blame:0) exit 0 ;;
		esac
		exec "$realgit" "\$@"
		SHIM
		chmod +x "$t/shim/git"
	); then
		echo "citations selftest: COULD-NOT-RUN: the scratch history did not build" >&2
		exit 2
	fi
	sf=0
	expect() {
		if printf '%s\n' "$out" | command grep -qF -- "$1"; then
			echo "  ok    $2"
		else
			echo "  FAIL  $2: no line with [$1]"
			sf=1
		fi
	}
	absent() {
		if printf '%s\n' "$out" | command grep -qF -- "$1"; then
			echo "  FAIL  $2: a line with [$1]"
			sf=1
		else
			echo "  ok    $2"
		fi
	}
	at() { printf 'doc/a.md:%s: ' "$(command grep -n "^$1" "$t/r/doc/a.md" | cut -d: -f1)"; }
	# Each expected failure, and the count they make with the refused
	# document name, so that nothing else fails.
	main() {
		expect "$(at Moved\ )zz.c:30 moved since" 'a line the source moved under fails'
		expect "$(at Moved\ )zz.c:30 moved since $(git -C "$t/r" rev-parse HEAD~3 | cut -c1-10), where the citation was written; now at 40" 'naming the commit and the line it went to'
		expect "$(at Region)zz.c:7 rewritten within a changed region" 'a line rewritten into two fails'
		expect "$(at MovedEdit)zz.c:20 rewritten within a changed region" 'a line rewritten and moved fails'
		expect "$(at Inplace)zz.c:3 rewritten in place" 'a line rewritten in place is a note'
		absent "$(at Retire)zz.c:2 rewritten in place" 'and a citing line rewritten since retires it'
		expect "$(at Gone)zz.c:100 deleted since" 'a deleted line fails, carried through a rewording not yet committed'
		expect "$(at Second)zz.c:70 moved since" 'the stale one of two equal citations, carried through a rewording, fails'
		expect "$(at Bare)zz.c:140 moved since" 'a carried citation fails'
		expect "$(at Bare)zz.c:150 moved since" 'and its carried bare continuation'
		expect "$(at List)zz.c:30 moved since" 'a list member beside a remapped one is carried'
		expect "$(at Range)zz.c:90 moved since" 'a range start beside a remapped end is carried'
		expect "$(at Path)zz.c:120 moved since" 'a citation respelled as another path of its file is carried'
		expect "$(at '`:80`')zz.c:80 moved since" 'a bare citation at the start of a line is carried by the file above it, not one after it'
		expect "$(at Movedline)zz.c:110 moved since" 'a line moved within its document keeps its age'
		expect "$(at Deep)zz.c:38 moved since" 'a line moved in one commit and reworded in the next keeps its age'
		expect "$(at 'Twin `zz.c:46`')zz.c:46 moved since" 'of two lines alike, each pairs with its own old line'
		expect "$(at '(`zz')zz.c:32 moved since" 'a line of citations alone pairs by its place'
		expect "$(at Ratio)zz.c:26 moved since" 'pairing scores the share of words, not their count'
		expect "note: $(at '`:85`')zz.c:85 belongs to a file its line did not cite" 'a bare citation whose file changed above it is named, not dated'
		absent "$(at '`:95`')zz.c:95" 'and once its line is reworded it dates from that change, not from where it cited another file'
		expect "$(at '`:30`')vv.c:30 moved since" 'and is read from then on, failing a move after that change'
		expect "note: $(at '`:20`')vv.c:20 belongs to a file its line did not cite" 'and so is one whose new file has since moved'
		absent "$(at '`:20`')vv.c:20 moved" 'which is not read'
		absent "$(at Collapse)zz.c:115 moved" 'a range collapsed to one end is not carried, a stated miss'
		absent "$(at Shrink)zz.c:41 moved" 'so a correct collapse to its start does not fail'
		absent "$(at Inplacetwo)zz.c:2 rewritten in place" 'a citing line being reworded now retires its note'
		expect "doc/b'c.md: a document name" 'a document name outside the plain set is refused'
		expect '1 whose file the dating commit lacks' 'a file absent from the dating commit is counted, not read'
		expect '2 not dated and named above' 'and both are counted'
	}
	nfail=18
	tally() {
		n=$(printf '%s\n' "$out" | command grep -c 'FAIL prose' || true)
		if [ "$n" -eq "$nfail" ] && [ "$rc" -eq 1 ]; then
			echo "  ok    $nfail failures and exit 1$1"
		else
			echo "  FAIL  $n failure line(s), exit $rc, where $nfail and 1 are expected$1:"
			printf '%s\n' "$out" | command grep 'FAIL prose' | sed 's/^/        /'
			sf=1
		fi
	}
	out=$(cd "$t/r" && sh script/test-citations.sh 2>&1)
	rc=$?
	main
	tally ', so the correct remaps, the fresh line and the stated misses pass'
	base=$(printf '%s\n' "$out" | command grep '^citations: rot read on')
	out=$(cd "$t/r" && git config diff.external true && git config blame.ignoreRevsFile '.ignore revs' &&
	    GIT_EXTERNAL_DIFF=true sh script/test-citations.sh 2>&1)
	rc=$?
	tally ' with an external diff tool and an ignored-revisions file configured'
	expect "$base" 'and every count of the rot check the same'
	(cd "$t/r" && git config --unset diff.external && git config --unset blame.ignoreRevsFile)
	for m in show diff ls-tree blame-L blame; do
		out=$(cd "$t/r" && H2CIT_FAIL=$m PATH="$t/shim:$PATH" sh script/test-citations.sh 2>&1)
		rc=$?
		case $m in
		show) w='git show' ;;
		diff) w='git diff' ;;
		ls-tree) w='git ls-tree' ;;
		blame-L) w='git blame of' ;;
		blame) w='git blame failed' ;;
		esac
		if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | command grep -q "FAIL prose.*$w"; then
			echo "  ok    a failing $m read fails the gate"
		else
			echo "  FAIL  a failing $m read: exit $rc, no line naming [$w]"
			sf=1
		fi
	done
	out=$(cd "$t/clean" && H2CIT_FAIL=blame-empty PATH="$t/shim:$PATH" sh script/test-citations.sh 2>&1)
	rc=$?
	expect 'the rot check dated no cited line' 'a blame that answers nothing dates nothing'
	if [ "$rc" -eq 2 ]; then echo "  ok    and exits 2"; else echo "  FAIL  exit $rc, where 2"; sf=1; fi
	out=$(cd "$t/clean" && git config blame.ignoreRevsFile no-such-file && sh script/test-citations.sh 2>&1)
	rc=$?
	(cd "$t/clean" && git config --unset blame.ignoreRevsFile)
	expect 'blame.ignoreRevsFile names a file that does not exist' 'a configured ignored-revisions file that is missing is named'
	if [ "$rc" -eq 2 ]; then echo "  ok    and exits 2"; else echo "  FAIL  exit $rc, where 2"; sf=1; fi
	out=$(cd "$t/shallow" && sh script/test-citations.sh 2>&1)
	rc=$?
	expect 'a shallow clone, so no citation can be dated' 'a shallow clone does not run the rot check'
	if [ "$rc" -eq 2 ]; then echo "  ok    and exits 2"; else echo "  FAIL  shallow clone exit $rc, where 2"; sf=1; fi
	echo "citations selftest: $([ "$sf" -eq 0 ] && echo pass || echo FAIL)"
	exit "$sf"
fi
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
rotok=0
rotskip=0
rotbad=0
rotedit=0
rotcarried=0
rotundated=0
blamed=0
blame=$(mktemp) || exit 2
trap 'rm -f "$blame"' EXIT
# The age of a citation needs the whole history: a shallow clone dates
# every line to its boundary commit and reads every citation as fresh.
norot=0
[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = false ] || norot=1
# A configured blame.ignoreRevsFile that names a missing file makes every
# blame fatal whatever flag is passed (git 2.56.0), which is the
# instrument unable to run, not a citation wrong.
f=$(git config --type=path --get-all blame.ignoreRevsFile 2>/dev/null)
while IFS= read -r g; do
	[ -z "$g" ] || [ -f "$g" ] || norot=2
done <<EOF
$f
EOF
# The history reads take no shape from the user's configuration: an
# external diff tool or textconv driver answers a diff with no hunks
# and status 0, and every citation would read as unmoved; an ignored
# revision list, a diff algorithm or merged hunks would move the dating.
# A configured blame.ignoreRevsFile is cleared only by the blame flag
# --ignore-revs-file= (a -c with an empty value leaves it in force, git
# 2.56.0), so both blames pass that flag.
G="git -c diff.external= -c diff.algorithm=myers -c diff.interHunkContext=0"
prosefail=0
prosechecked=
for d in $(git ls-files '*.md' | command grep -v -e '^doc/history/' -e '^doc/research/' -e '^doc/upstream/' -e '^CHANGELOG.md$'); do
	# A document name goes into git commands below, so one with a
	# character outside the plain set is refused rather than quoted.
	case "$d" in
	*[!A-Za-z0-9_./-]*)
		echo "  FAIL prose $d: a document name with a character outside [A-Za-z0-9_./-] is not read" >&2
		prosefail=$((prosefail + 1))
		continue ;;
	esac
	# Who last wrote each line of the document, and the commit and path
	# before that, for the rot check below.
	: > "$blame"
	if [ "$norot" -eq 0 ]; then
		if ! $G blame -M --no-textconv --ignore-revs-file= --line-porcelain -- "$d" > "$blame" 2>/dev/null; then
			echo "  FAIL prose $d: git blame failed, so no citation in it is dated" >&2
			prosefail=$((prosefail + 1))
		fi
		[ -s "$blame" ] && blamed=$((blamed + 1))
	fi
	out=$(awk -v doc="$d" -v blame="$blame" -v norot="$norot" -v G="$G" '
	BEGIN {
		while ((getline l < blame) > 0) {
			if (l ~ /^[0-9a-f]+ [0-9]+ [0-9]+/) {
				split(l, w, " "); bsha = w[1]; borig = w[2]; bfin = w[3]
				origin[bfin] = bsha; oline[bfin] = borig
			} else if (l ~ /^previous /) {
				split(l, w, " "); prev[bfin] = w[2]; ppath[bfin] = w[3]
			} else if (l ~ /^filename /)
				bpath[bfin] = substr(l, 10)
		}
		close(blame)
	}
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
	function lineof(p, n) { return lineat(at, p, n) }
	# A read that fails is told apart from a file that is short: every
	# git command here ends its output with its own exit status.
	function lineat(rev, p, n,   i, l, k, cmd, rc) {
		k = rev SUBSEP p
		if (!(k in loaded)) {
			i = 0
			if (rev != "") {
				cmd = G " show --no-textconv " rev ":" p " 2>/dev/null; echo @@h2cit-rc@@ $?"
				rc = ""
				while ((cmd | getline l) > 0) {
					if (l ~ /^@@h2cit-rc@@ /) rc = substr(l, 14)
					else text[k, ++i] = l
				}
				close(cmd)
				if (rc != "0") print "BAD " doc ":" NR ": git show " rev ":" p " failed (" (rc == "" ? "no status" : rc) ")"
			} else {
				while ((getline l < p) > 0) text[k, ++i] = l
				close(p)
			}
			nlines[k] = i; loaded[k] = 1
		}
		if (n > nlines[k]) return "\001past"
		return text[k, n]
	}
	function safe(x) { return (x ~ /^[A-Za-z0-9_.\/:-]+$/) }
	# The hunks of a git diff, cached by its arguments: hs, hc, hn, hd
	# are the old start, old count, new start and new count of each.
	function hunks(args,   cmd, l, n, rc, m, h, x) {
		if (args in nh) return nh[args] >= 0
		n = 0; rc = ""
		cmd = G " diff -U0 --no-color --no-ext-diff --no-textconv " args " 2>/dev/null; echo @@h2cit-rc@@ $?"
		while ((cmd | getline l) > 0) {
			if (l ~ /^@@h2cit-rc@@ /) { rc = substr(l, 14); continue }
			if (l !~ /^@@ -/) continue
			h = l; sub(/^@@ -/, "", h); sub(/ @@.*/, "", h)
			split(h, m, " "); sub(/^[+]/, "", m[2])
			n++
			if (split(m[1], x, ",") > 1) { hs[args, n] = x[1] + 0; hc[args, n] = x[2] + 0 }
			else { hs[args, n] = x[1] + 0; hc[args, n] = 1 }
			if (split(m[2], x, ",") > 1) { hd[args, n] = x[1] + 0; hn[args, n] = x[2] + 0 }
			else { hd[args, n] = x[1] + 0; hn[args, n] = 1 }
		}
		close(cmd)
		if (rc != "0") {
			print "BAD " doc ":" NR ": git diff " args " failed (" (rc == "" ? "no status" : rc) ")"
			nh[args] = -1
			return 0
		}
		nh[args] = n
		return 1
	}
	# Whether a line of the document cites line n of a file whose base
	# name is b, read with the same tokens as the reader below: each
	# member of a list counts, a range start only as a start (role s) and
	# a range end only as an end (role e), since a remap by the length of
	# a range turns its old end into its new start; a line cited alone
	# (role x) matches only a line cited alone, since a range collapsed
	# to one of its ends cannot say which, and either guess fails some
	# correct citation. An old line cited alone matches any role. A bare `:N` belongs to the file last named before it, on
	# its line or on the lines above it (cb, from ctxfile()), as the
	# reader below assigns it. So a list member, a range end or a
	# citation respelled as another path of the same file is carried,
	# and a bare `:N` whose file changed is not.
	# The base name of the file last named above line k of an old copy
	# of the document, which is the file a bare `:N` at the start of
	# line k belongs to.
	function ctxfile(rev, p, k,   j, l, t, f, rest) {
		for (j = k - 1; j >= 1; j--) {
			l = lineat(rev, p, j); f = ""; rest = l
			while (match(rest, /[A-Za-z0-9_.\/-]*\.(c|h|sh|py|pl|md|txt|yaml)(:[0-9]+)?/)) {
				t = substr(rest, RSTART, RLENGTH)
				rest = substr(rest, RSTART + RLENGTH)
				if (t !~ /:/ && rest ~ /^[A-Za-z0-9_]/) continue
				f = t; sub(/:.*/, "", f); sub(/.*\//, "", f)
			}
			if (f != "") return f
		}
		return ""
	}
	function hasunit(l, b, n, role, cb,   rest, t, f, spec, e, ne, i, a, c) {
		rest = l
		while (match(rest, /`:[0-9]+(-[0-9]+)?(, *[0-9]+(-[0-9]+)?)*|[A-Za-z0-9_.\/-]*\.(c|h|sh|py|pl|md|txt|yaml)(:[0-9]+(-[0-9]+)?(, *[0-9]+(-[0-9]+)?)*)?/)) {
			t = substr(rest, RSTART, RLENGTH)
			rest = substr(rest, RSTART + RLENGTH)
			if (t ~ /^`:/) {
				spec = substr(t, 3); f = cb
			} else {
				if (t !~ /:/ && rest ~ /^[A-Za-z0-9_]/) continue
				f = t; sub(/:.*/, "", f); sub(/.*\//, "", f); cb = f
				if (t !~ /:/) continue
				spec = t; sub(/^[^:]*:/, "", spec)
			}
			if (f != b) continue
			ne = split(spec, e, ", *")
			for (i = 1; i <= ne; i++) {
				a = e[i]; c = a
				if (a ~ /-/) { sub(/-.*/, "", a); sub(/.*-/, "", c) }
				if (role == "x") { if (a == c && a + 0 == n) return 1; continue }
				if ((role != "e" || a == c) && a + 0 == n) return 1
				if ((role != "s" || a == c) && c + 0 == n) return 1
			}
		}
		return 0
	}
	# Rot. A citation of line n of a file is dated by the commit that
	# wrote it on its line: the blame of the line (with -M, so a line
	# moved within its document keeps its age), and then, while the
	# commit that last wrote the line already cited the same line of the
	# same file on a line it replaced, the blame of that old line, so a
	# citation carried through an edit of its line (a remap of its
	# neighbour, a rewording) keeps its own age. The old line is the one
	# pair() matches by its words. A citation a reflow moved onto the
	# next line is paired with the old text of that line and so is not
	# carried: it dates from the reflow, a miss the gate accepts, since
	# matching by number instead fails every correct uniform remap. A
	# line not yet committed dates
	# the same way from HEAD, and one whose citation is new is not dated.
	function age(b, n, role,   sha, ol, p, pp, path, a, i, k, L, args, cmd, l, w, steps, q) {
		sha = origin[NR]; ol = oline[NR]; p = prev[NR]; pp = ppath[NR]; path = bpath[NR]
		if (sha == "") return ""
		# The line must have cited this file at its blame commit. A bare
		# `:N` whose file changed around it (a line naming another file
		# rewritten, or deleted, above an untouched line) cites the new
		# file from a commit no line records, so it is not dated and is
		# named instead; rewording its own line, once read, dates it.
		if (sha !~ /^0+$/ && !hasunit(lineat(sha, path, ol), b, n, role, ctxfile(sha, path, ol))) {
			print "UNDATED " doc ":" NR ": " cf ":" n " belongs to a file its line did not cite when written, so it is not dated; reword the line once it is read"
			return ""
		}
		for (steps = 0; steps < 200; steps++) {
			if (p == "") return (sha ~ /^0+$/) ? "" : sha
			if (!safe(pp) || !safe(path)) {
				print "BAD " doc ":" NR ": a path in its history (" pp ", " path ") is not one the reader passes to git"
				return ""
			}
			args = (sha ~ /^0+$/) ? p " -- " doc : p ":" pp " " sha ":" path
			if (!hunks(args)) return ""
			L = ""
			for (i = 1; i <= nh[args]; i++) {
				if (ol < hd[args, i] || ol >= hd[args, i] + hn[args, i]) continue
				k = pair(args, i, ol, (sha ~ /^0+$/) ? "" : sha, (sha ~ /^0+$/) ? doc : path, p, pp)
				if (k != "" && hasunit(lineat(p, pp, k), b, n, role, ctxfile(p, pp, k))) L = k
				break
			}
			if (L == "") return (sha ~ /^0+$/) ? "" : sha
			carried = 1
			cmd = G " blame -M --no-textconv --ignore-revs-file= --line-porcelain -L " L "," L " " p " -- " pp " 2>/dev/null; echo @@h2cit-rc@@ $?"
			q = p; sha = ""; p = ""; a = ""
			while ((cmd | getline l) > 0) {
				if (l ~ /^@@h2cit-rc@@ /) a = substr(l, 14)
				else if (l ~ /^[0-9a-f]+ [0-9]+ [0-9]+/) { split(l, w, " "); sha = w[1]; ol = w[2] }
				else if (l ~ /^previous /) { split(l, w, " "); p = w[2]; pp = w[3] }
				else if (l ~ /^filename /) path = substr(l, 10)
			}
			close(cmd)
			if (a != "0" || sha == "") {
				print "BAD " doc ":" NR ": git blame of " pp ":" L " failed (" (a == "" ? "no status" : a) ")"
				return ""
			}
			# The same test at each commit the carry reaches: a bare
			# `:N` reworded after its file changed above it cited
			# another file where its old line was written, so it dates
			# from q, the latest commit known to cite this unit, which
			# can only miss a move and never invent one.
			if (!hasunit(lineat(sha, path, ol), b, n, role, ctxfile(sha, path, ol))) return q
		}
		print "BAD " doc ":" NR ": " cf ":" n " carried through more than 200 edits"
		return ""
	}
	# The words of a line outside its code spans, as a set in w.
	function words(l, w,   n, i, x) {
		gsub(/`[^`]*`/, " ", l)
		n = split(tolower(l), x, /[^a-z]+/)
		for (i = 1; i <= n; i++) if (x[i] != "") w[x[i]] = 1
	}
	# The old line of hunk i that new line ol replaced: the one sharing
	# the most words with it outside code spans, the nearer to its place
	# in the hunk on a tie. When no word is shared (a line made only of
	# citations, or one rewritten whole) the line in the same place of a
	# hunk that keeps its length, and none in a hunk that does not. Words and
	# not numbers, since a renumbering gives each citation the number
	# its neighbour had: in a uniform remap the numbers pair every line
	# with the wrong one, and the words pair it with its own.
	function pair(args, i, ol, nrev, npath, p, pp,   nw, ow, k, best, bs, sc, c, tot, home, d, bd, x) {
		split("", nw); words(lineat(nrev, npath, ol), nw)
		home = hs[args, i] + (ol - hd[args, i])
		best = ""; bs = 0; bd = 0
		for (k = hs[args, i]; k < hs[args, i] + hc[args, i]; k++) {
			split("", ow); words(lineat(p, pp, k), ow)
			c = 0; tot = 0
			for (x in nw) { tot++; if (x in ow) c++ }
			for (x in ow) if (!(x in nw)) tot++
			if (c == 0) continue
			sc = c / tot
			d = (k > home) ? k - home : home - k
			if (best == "" || sc > bs || (sc == bs && d < bd)) { best = k; bs = sc; bd = d }
		}
		if (best == "" && hc[args, i] == hn[args, i]) best = home
		return best
	}
	# Whether a file is in a commit, told apart from a read that failed.
	function intree(rev, p,   cmd, l, rc, found) {
		cmd = G " ls-tree --name-only " rev " -- " p " 2>/dev/null; echo @@h2cit-rc@@ $?"
		rc = ""; found = 0
		while ((cmd | getline l) > 0) {
			if (l ~ /^@@h2cit-rc@@ /) rc = substr(l, 14)
			else if (l == p) found = 1
		}
		close(cmd)
		if (rc != "0") {
			print "BAD " doc ":" NR ": git ls-tree " rev " " p " failed (" (rc == "" ? "no status" : rc) ")"
			return -1
		}
		return found
	}
	# The cited line mapped through the diff from the dating commit to
	# the tree. Outside every hunk it moves by the hunks before it, and a
	# move fails with the line it went to. Inside a hunk it was deleted,
	# which fails, or rewritten: a rewrite that keeps its place in a hunk
	# of the same length and start is a note to read the sentence again,
	# and any other fails with the range now there. A file absent from
	# the dating commit is counted and not read. Only outside a pinned
	# region, which is held to its pin instead.
	# Whether line n of the old side of a diff lies in a hunk that
	# changed it.
	function inhunk(args, n,   i) {
		for (i = 1; i <= nh[args]; i++)
			if (hs[args, i] <= n && n < hs[args, i] + hc[args, i])
				return 1
		return 0
	}
	function rot(n, role,   o, k, b, args, i, off, r, last) {
		n += 0
		if (at != "" || norot) return
		b = cur; sub(/.*\//, "", b)
		k = NR SUBSEP cur SUBSEP n SUBSEP role
		if (!(k in dated)) { carried = 0; dated[k] = age(b, n, role); wascarried[k] = carried }
		o = dated[k]
		if (o == "") return
		r = intree(o, cur)
		if (r < 0) return
		if (r == 0) { print "NOROT"; return }
		args = o " -- " cur
		if (!hunks(args)) return
		if (wascarried[k]) print "CARRIED"
		off = 0
		for (i = 1; i <= nh[args]; i++) {
			if (hc[args, i] == 0) { if (hs[args, i] < n) off += hn[args, i]; continue }
			if (hs[args, i] + hc[args, i] - 1 < n) { off += hn[args, i] - hc[args, i]; continue }
			if (hs[args, i] > n) break
			if (hn[args, i] == 0) { bad("deleted since " substr(o, 1, 10) ", where the citation was written", n); return }
			if (hd[args, i] != hs[args, i] || hn[args, i] != hc[args, i]) {
				bad("rewritten within a changed region since " substr(o, 1, 10) ", where the citation was written; that region is now " hd[args, i] "-" (hd[args, i] + hn[args, i] - 1), n)
				return
			}
			# A note never fails, and an edit of the citing line after
			# the rewrite (not committed yet, or committed past every
			# change to the cited line) is taken as its reading and
			# retires it, or nothing could. A failure takes no edit
			# as a reading: the carry above holds it to its first date.
			# So only a carried citation retires a note, and an
			# incidental rewording of its line retires it as well.
			last = origin[NR]
			if (last == "" || last ~ /^0+$/) { print "ROTOK"; return }
			if (hunks(last " -- " cur) && !inhunk(last " -- " cur, n)) { print "ROTOK"; return }
			print "ROTEDIT " doc ":" NR ": " cf ":" n " rewritten in place since " substr(o, 1, 10) ", where the citation was written"
			return
		}
		if (off == 0) { print "ROTOK"; return }
		bad("moved since " substr(o, 1, 10) ", where the citation was written; now at " (n + off), n)
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
			else {
				print "OK"
				rot(a, (b == "") ? "x" : "s")
				if (b != "") rot(b, "e")
			}
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
				tok = t
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
			tok = t
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
	rotok=$((rotok + $(printf '%s\n' "$out" | command grep -c '^ROTOK' || true)))
	rotskip=$((rotskip + $(printf '%s\n' "$out" | command grep -c '^NOROT' || true)))
	rotbad=$((rotbad + $(printf '%s\n' "$out" | command grep -c '^BAD .* where the citation was written' || true)))
	rotcarried=$((rotcarried + $(printf '%s\n' "$out" | command grep -c '^CARRIED' || true)))
	rotundated=$((rotundated + $(printf '%s\n' "$out" | command grep -c '^UNDATED' || true)))
	printf '%s\n' "$out" | sed -n 's/^UNDATED /note: /p'
	rotedit=$((rotedit + $(printf '%s\n' "$out" | command grep -c '^ROTEDIT' || true)))
	printf '%s\n' "$out" | sed -n 's/^ROTEDIT /note: re-read, the cited line was edited: /p'
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
if [ "$norot" -ne 0 ]; then
	if [ "$norot" -eq 1 ]; then
		echo "citations: COULD-NOT-RUN: a shallow clone, so no citation can be dated; the rot check did not run" >&2
	else
		echo "citations: COULD-NOT-RUN: blame.ignoreRevsFile names a file that does not exist, so git blame cannot run; the rot check did not run" >&2
	fi
	[ "$fail" -eq 0 ] && [ "$prosefail" -eq 0 ] || exit 1
	exit 2
fi
echo "citations: rot read on $((rotok + rotbad + rotedit)) cited line(s), $rotcarried of them dated past a later edit of their line, $rotbad moved or deleted since written, $rotedit rewritten in place, $rotskip whose file the dating commit lacks, $rotundated not dated and named above"
# Zero dated lines beside prose citations read means the history read
# came back empty while git itself answered, and every citation would
# pass the check unread. Said even when a failure above sets the exit.
norun=0
if [ "$blamed" -eq 0 ] || [ $((rotok + rotbad + rotedit)) -eq 0 ]; then
	echo "citations: COULD-NOT-RUN: the rot check dated no cited line ($blamed document(s) blamed)" >&2
	norun=1
fi
[ "$fail" -eq 0 ] && [ "$prosefail" -eq 0 ] || exit 1
[ "$norun" -eq 0 ] || exit 2
exit 0
