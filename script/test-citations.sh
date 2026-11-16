#!/bin/sh
# Every `file:line` citation in a table of doc/*.md or doc/history/*.md
# resolves, and where the row names a symbol, that symbol is ON the line.
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
# A row whose first cell names a function beside its line is read for
# whether the line is inside that function, at the tree or, inside a
# pinned region, at the region's commit. See the comment at twocell().
#
# The dated records under doc/history are held the other way round: a
# commit that changes a line of one in a line citation alone fails, since
# such a record says what was read at a commit and is not renumbered. See
# the comment at rmark below.
#
# What it cannot catch: a row anchored on a bare identifier common throughout
# the cited file (`dio`, `folio`) matches a neighbouring line as readily as the
# right one. The counts at the end separate symbol-anchored from
# literal-anchored from unanchored so the strength of a pass stays visible.
#
# Exit 0 pass, 1 one or more citations wrong, 2 could not run.
set -u
# --selftest builds a scratch repository whose history holds a citation
# for each way the rot check dates or maps one, a row for each way a line
# sits against the function named beside it, each region marker a dated
# record can get wrong, a dated record renumbered by a commit and by
# the working tree, and one added past the floor and renumbered after;
# it runs this script against it and checks every
# expected line. Then it runs it again: with git show, diff, ls-tree,
# log and the two blames each failing in turn through a shim, with a
# setting git cannot parse stopping git show or git blame, with the
# renumber reader printing nothing, with a
# line in the log that no diff holds; with an external diff tool and an
# ignored-revisions file configured, with git's color forced on, with a
# textconv driver and a binary attribute configured for every file, with
# each setting that changes the prefix the renumber reader takes a file's
# name from, with hunks merged across unchanged lines, with a diff
# algorithm configured and named by an attribute on shapes the algorithm
# decides, with the indent heuristic configured off on a shape it
# decides, with a hash length configured, with rename detection
# configured off and with a rename limit below what a commit renames;
# with the prose reader stopping on a
# status; on trees that fail in one half alone, on trees with no row
# (with and without a failing function row), no prose citation and more
# rows than citations counted, on living documents wrong in each way the
# prose half reads for and on the shapes it must pass, on a tree whose
# one dated citation is a note, on a clone whose blame answers nothing,
# answers and dates nothing, or answers a blame of one line with nothing,
# on a shallow clone and with a configuration git cannot parse. Each
# run that reaches the counts is held to
# them: the failures printed in each half are the failures that half
# counted. Exit 0 pass, 1 fail, 2 could not build.
#
# The selftest's status, from the file its checks printed to and the
# status they exited with: 0 only for a status of 0, no FAIL line and a
# verdict of pass last, 2 only for a build that stopped with no FAIL
# line, and 1 for anything else. The status is all pre-push and CI
# read, so it is made from the lines as well as from the checks.
# selfstatus decides from the status and the last line; selfverdict
# reads them from the file, and a FAIL line it reads there gives 1
# whatever selfstatus gave, so a selfstatus giving 0 to everything
# cannot pass a run that printed a failure. The selftest reads
# selfverdict from a table of printed files, one row for each way its
# tests can be told apart.
selfstatus() { # the checks' status, the last line they printed
	if [ "$1" -eq 0 ] && [ "$2" = 'citations selftest: pass' ]; then
		echo 0
	elif [ "$1" -eq 2 ]; then
		echo 2
	else
		echo 1
	fi
}
selfverdict() { # the file the checks printed to, their status
	vn=$(command grep -c '^  FAIL ' "$1")
	vl=$(tail -n 1 "$1")
	vs=$(selfstatus "$2" "$vl")
	case "$vs" in 0|2) ;; *) vs=1 ;; esac
	[ "$vn" = 0 ] || vs=1
	echo "$vs"
}
if [ "${1:-}" = "--selftest" ]; then
	# The checks run in a subshell whose output is kept for selfverdict.
	sto=$(mktemp) || exit 2
	(
	realgit=$(command -v git) || exit 2
	realawk=$(command -v awk) || exit 2
	case "$realawk" in /*) ;; *) echo "citations selftest: COULD-NOT-RUN: awk is not a file on PATH ($realawk)" >&2; exit 2 ;; esac
	me=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
	t=$(mktemp -d) || exit 2
	trap 'rm -rf "$t"' EXIT
	# The subshell is a command of its own and not the condition of an
	# `if`, where the shell ignores `set -e`.
	(
		set -e
		# A fixture edit that changes nothing leaves an expectation
		# below met by a line that was never built, so each edit is
		# one expression and has to change its file.
		edit() { # file, sed expression
			sed -e "$2" "$1" > edit.new
			if cmp -s "$1" edit.new; then
				echo "citations selftest: the fixture edit [$2] changed nothing in $1" >&2
				return 1
			fi
			mv edit.new "$1"
		}
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
		# Two functions in the BSD layout, for the rows that name a
		# function beside a line: fn_a on lines 2 to 5, fn_b on 8 to 11.
		# After them fn_c's name at column 0 with no body, and fn_d,
		# whose body a reader taking that name line for a definition
		# would give to fn_c, and whose arguments run onto a second
		# line. Last xfn_a, whose name ends in fn_a's.
		printf '%s\n' 'int' 'fn_a(void)' '{' '	return (1);' '}' '' \
		    'int' 'fn_b(void)' '{' '	return (2);' '}' '' \
		    'int' 'fn_c(void);' '' \
		    'int' 'fn_d(int a,' '    int b)' '{' '	return (4);' '}' '' \
		    'int' 'xfn_a(void)' '{' '	return (5);' '}' > src/sys/fs/hammer2/ff.c
		# fb.c, never changed: fb_a's prototype at column 0 is followed
		# by a struct whose brace is not at column 0, so fb_a has no
		# definition; fb_b's body holds a block whose closing brace is
		# indented, and its line 13 after that block is still inside it.
		printf '%s\n' 'int' 'fb_a(void);' 'struct fb_s {' '	int x;' '};' '' \
		    'int' 'fb_b(int a)' '{' '	if (a) {' '		a = 2;' '	}' '	return (a);' '}' > src/sys/fs/hammer2/fb.c
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
		    'Ctxsix in `zz.c` see' 'a line between that names nothing,' '`:65` there.' \
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
		one=$(git rev-parse --short HEAD)
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
		# ff.c gains five lines above its functions, the first of them
		# fn_b's prototype: fn_a is now 7 to 10, fn_b 13 to 16, fn_c's
		# name on 19, fn_d 22 to 26 and xfn_a 29 to 32.
		{ printf '%s\n' 'static int fn_b(void);' 'int pad_2;' 'int pad_3;' 'int pad_4;' 'int pad_5;'
		  cat src/sys/fs/hammer2/ff.c; } > ff.new
		mv ff.new src/sys/fs/hammer2/ff.c
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
		# its bare line, Ctxsix's file named two lines above its bare
		# line and kept, Shrink collapsed to its start, the first Twin, Solo
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
		    'Ctxsix in `zz.c` see' 'a line between that names nothing,' '`:65` there.' \
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
		# Rows naming a function beside a line, in a dated record as
		# the real ones are. t.md holds each way one is wrong and is
		# removed from every clone, two of which must exit 2; u.md
		# holds only right ones. A region pinned to the first commit is read
		# from that commit's ff.c.
		mkdir doc/history doc/research
		# A row in a document neither half reads, which the unchecked
		# list names.
		printf '%s\n' '| site | what |' '|---|---|' '| `zz.c:1` | `l_001` |' '| `ys.py:3` | `ys` |' > doc/research/x.md
		printf '%s\n' '| site | what |' '|---|---|' \
		    '| `ff.c:9` `fn_a()` | inside |' \
		    '| `ff.c:4` `fn_a()` | where it was before the file moved |' \
		    '| `ff.c:9` `fn_b()` | a line of another function |' \
		    '| `ff.c:9` `fn_gone()` | no definition |' \
		    '| `ff.c:1` `fn_b()` | its prototype |' \
		    '| `ff.c:14`, `:15` `fn_b()` | two lines inside |' \
		    '| `ff.c:14` `fn_b()`, and `:8` | the second line outside |' \
		    '| `ff.c:9-10` `fn_a()` | a range, which the reader does not take |' \
		    '| `ff.c:24` `fn_c()` | a name at column 0 that opens no body, the line in the function after it |' \
		    '| `gone.c:3` `fn_a()` | a file the tree does not hold |' \
		    '| `ff.c:25` `fn_d()` | inside a function whose arguments take two lines |' \
		    '| `ff.c:31` `fn_a()` | inside a function whose name ends in the one named |' \
		    '| `fb.c:4` `fb_a()` | a prototype followed by a brace not at column 0 |' \
		    '| `fb.c:13` `fb_b()` | inside, after an indented closing brace |' \
		    '' "<!-- citations at $one -->" '' '| site | what |' '|---|---|' \
		    '| `ff.c:4` `fn_a()` | inside at the pin |' \
		    '| `ff.c:10` `fn_a()` | outside at the pin |' \
		    '' '<!-- citations end -->' '' '| site | what |' '|---|---|' \
		    '| `ff.c:15` `fn_b()` | after the region, the tree again |' \
		    '' '| site | what |' '|---|---|' \
		    '| `absent.c:3` | `fn_a` |' \
		    '| `ff.c:999` | `fn_a` |' \
		    '| `ff.c:9` | `fn_b` |' \
		    '| `../../../../../../../etc/hostname:1` | `fn_a` |' \
		    '| `/etc/hostname:1` | `fn_a` |' \
		    '| `../escaped.c:1` `fn_a()` | a path out of the tree in the two-cell shape |' \
		    '| `:5` | `fn_a` |' \
		    '| `x;z.c:2` | `fn_a` |' \
		    '| `y;w.c:2` `fn_a()` | a file name outside the plain set in the two-cell shape |' \
		    '| `/etc/hostname:1` `fn_a()` | an absolute path in the two-cell shape |' \
		    > doc/history/t.md
		printf '%s\n' '| site | what |' '|---|---|' \
		    '| `ff.c:9` `fn_a()` | inside |' \
		    '' "<!-- citations at $one -->" '' '| site | what |' '|---|---|' \
		    '| `ff.c:4` `fn_a()` | inside at the pin |' \
		    '' '<!-- citations end -->' \
		    > doc/history/u.md
		# The markers a dated record can get wrong, which the prose
		# half does not read there.
		printf '%s\n' 'x' '<!-- citations end -->' '<!-- citations at HEAD -->' \
		    '<!-- citations end -->' '<!-- citations at 0000000 -->' \
		    "<!-- citations at $one -->" '<!-- citations here -->' \
		    > doc/history/v.md
		# A dated record that a later commit and the working tree will
		# change, in digits alone and in words too. Its blank lines are
		# many enough that git stops matching one with four changed
		# lines on each side and no other blank line beside them, and
		# prints it on both sides of their hunk.
		{ printf '%s\n' 'Renum see (`:30`) here.' 'Edit see (`:31`) here.' \
		    'Tree see (`:32`) here.' 'Keep see (`:33`) here.' \
		    'Range see (`:70-75`) here.' 'List see (`:90, 95`) here.' \
		    'Bare see `zz.c` 12-14 here.' 'Head see `zz.h` 7 here.'
		  i=1; while [ "$i" -le 12 ]; do printf '\nPad %s.\n' "$i"; i=$((i + 1)); done
		  printf '%s\n' 'Gap a1.' 'Gap a2.' 'Gap a3.' 'Gap a4.' '' 'Gap b1.' 'Gap b2.' 'Gap b3.' 'Gap b4.' 'End.'; } > doc/history/w.md
		git add -A
		git commit -qm three
		# vv.c moves after the line naming it changed, and Ctxfour's bare
		# line is reworded a commit after its file changed above it, so
		# it dates from that change and not from the line's first commit,
		# where `:95` was yy.c's.
		# Ctxfive's is reworded in the same commit that moves vv.c, so
		# once dated it is read and fails.
		edit doc/a.md 's/^`:95` there./`:95` there, reread./'
		edit doc/a.md 's/^`:30` there./`:30` there, reread./'
		{ printf 'int v_new;\n'; printf 'int v_new;\n'; printf 'int v_new;\n'; printf 'int v_new;\n'; printf 'int v_new;\n'; cat src/sys/fs/hammer2/vv.c; } > vv.new
		mv vv.new src/sys/fs/hammer2/vv.c
		git commit -qam four
		git rev-parse HEAD~1 > '.ignore revs'
		# Not committed: a stale citation reworded, which is carried from
		# HEAD, a citation of a line rewritten in place reworded, which
		# retires its note, and a citation written now, which is fresh.
		edit doc/a.md 's/^Gone `zz.c:100` here./Gone, reworded, `zz.c:100` here./'
		edit doc/a.md 's/^Inplacetwo `zz.c:2` here./Inplacetwo, reread, `zz.c:2` here./'
		printf '%s\n' 'Fresh `zz.c:22` here.' >> doc/a.md
		git clone -q --depth 1 "file://$t/r" "$t/shallow"
		git -C "$t/shallow" rm -q "doc/b'c.md" doc/history/t.md doc/history/v.md
		git clone -q "file://$t/r" "$t/clean"
		git -C "$t/clean" rm -q "doc/b'c.md" doc/history/t.md doc/history/v.md
		# A clone with nothing wrong in it, since every other tree here
		# fails for its prose and its status says nothing more.
		git clone -q "file://$t/r" "$t/pure"
		(
			cd "$t/pure"
			git rm -q "doc/b'c.md" doc/history/t.md doc/history/v.md
			printf '%s\n' '| site | what |' '|---|---|' '| `zz.c:1` | `l_001` |' '' 'Fine `zz.c:1` here.' > doc/a.md
			git -c user.name=selftest -c user.email=selftest@localhost -c commit.gpgsign=false commit -qam pure
		)
		# Clones of that one for the exits a failing tree never reaches.
		# norows has no row for the table half. noprose has a row citing
		# a script, which the prose half leaves alone, and nothing else
		# cited. pop has two rows citing a file whose name the count of
		# citation-shaped tokens does not take, and one token it does.
		for c in norows noprose pop; do
			git clone -q "file://$t/pure" "$t/$c"
			git -C "$t/$c" config user.email selftest@localhost
			git -C "$t/$c" config user.name selftest
			git -C "$t/$c" config commit.gpgsign false
		done
		printf '%s\n' 'Fine `zz.c:1` here.' > "$t/norows/doc/a.md"
		git -C "$t/norows" commit -qam norows
		printf '%s\n' '| site | what |' '|---|---|' '| `script/test-citations.sh:1` | `sh` |' > "$t/noprose/doc/a.md"
		git -C "$t/noprose" rm -q -r doc/history
		git -C "$t/noprose" commit -qam noprose
		printf '%s\n' 'alpha' 'beta' > "$t/pop/src/sys/fs/hammer2/Listing"
		printf '%s\n' '| site | what |' '|---|---|' '| `Listing:1` | `alpha` |' '| `Listing:2` | `beta` |' '' 'Fine `zz.c:1` here.' > "$t/pop/doc/a.md"
		git -C "$t/pop" rm -q -r doc/history doc/research
		git -C "$t/pop" add -A
		git -C "$t/pop" commit -qm pop
		# Two more clones of it. liv has a living document holding each
		# marker, fence and file name a living document can get wrong,
		# one citing each kind of line a citation must not land on, one
		# holding a closed fence, a word that only starts like a file
		# name, a quoted kernel message and a pinned region whose line
		# later moves, none of which is a failure, a line whose history
		# passes through a document name the reader does not pass to
		# git, and a line reworded in as many commits as the carry
		# follows, built by one fast-import stream. edt has one citation
		# the rot check dates, of
		# a line since rewritten in place, which is a note and no failure,
		# and three rows citing a script, which the prose half leaves
		# alone: one anchored on a symbol, one on a literal, one on none.
		for c in liv edt; do
			git clone -q "file://$t/pure" "$t/$c"
			git -C "$t/$c" config user.email selftest@localhost
			git -C "$t/$c" config user.name selftest
			git -C "$t/$c" config commit.gpgsign false
		done
		(
			cd "$t/liv"
			printf '%s\n' '<!-- citations end -->' '<!-- citations here -->' \
			    'Gone `gone.c:3` here.' 'Name `gone.c` see `:5` here.' \
			    '<!-- citations at 0000000 -->' '<!-- citations end -->' \
			    "<!-- citations at $one -->" '```' > doc/m.md
			printf '%s\n' 'Pad one.' 'Pad two.' 'Pad three.' 'Pad four.' 'Pad five.' 'Was `zz.c:1` here.' > 'doc/q=r.md'
			printf '%s\n' 'Pad one.' 'Pad two.' 'Pad three.' 'Pad four.' 'Pad five.' 'Carry `zz.c:1` here, step 0.' > doc/k.md
			# A citation that reaches a file of the tree only by
			# climbing out of the directory it names, and one that
			# leaves the tree. Both are refused rather than opened.
			printf '%s\n' 'Esc src/sys/fs/hammer2/../secret.c:2 here.' \
			    'Out src/sys/fs/hammer2/../../../../../outside.c:1 here.' > doc/esc.md
			printf 'esc\n' > src/sys/fs/secret.c
			# ff.c's line 11 is blank, 10 a closing brace, and it has 32;
			# pl.c's line 2 closes a declaration and 3 a comment; pq.h,
			# under src/sys/sys/ alone, is found by its name, and its
			# line 2 is a closing brace.
			printf '%s\n' 'int pl;' '};' ' */' > src/sys/fs/hammer2/pl.c
			mkdir -p src/sys/sys
			printf '%s\n' 'int pq;' '}' > src/sys/sys/pq.h
			printf '%s\n' 'Blank `ff.c:11` here.' 'Brace `ff.c:10` here.' 'Past `ff.c:99` here.' 'Range `ff.c:30-40` here.' \
			    'Semi `pl.c:2` here.' 'Comment `pl.c:3` here.' 'Header `pq.h:2` here.' > doc/p.md
			printf '%s\n' '```' 'Fenced `zz.c:1` here.' '```' 'In `zz.c` see head.cluster and `:5` there.' \
			    'Quoted: kernel BUG at gone.c:12 here.' "<!-- citations at $one -->" 'Pinned `zz.c:30` here.' \
			    '<!-- citations end -->' 'Above in `zz.c` see head.cluster' '`:6` there.' > doc/f.md
			git add -A
			git commit -qm liv
			edit src/sys/fs/hammer2/zz.c 's/^int n_10;$/int n_10;\
int n_11;/'
			git commit -qam moved
			git mv 'doc/q=r.md' doc/q.md
			edit doc/q.md 's/^Was `zz.c:1` here./Was, reworded, `zz.c:1` here./'
			git commit -qam renamed
			ref=$(git symbolic-ref HEAD)
			from=$(git rev-parse HEAD)
			now=$(git log -1 --format=%ct)
			i=1
			while [ "$i" -le 200 ]; do
				printf 'commit %s\ncommitter selftest <selftest@localhost> %s +0000\ndata <<E\nstep %s\nE\n' "$ref" "$((now + i))" "$i"
				[ "$i" -gt 1 ] || printf 'from %s\n' "$from"
				printf 'M 100644 inline doc/k.md\ndata <<E\n'
				printf '%s\n' 'Pad one.' 'Pad two.' 'Pad three.' 'Pad four.' 'Pad five.' "Carry \`zz.c:1\` here, step $i."
				printf 'E\n\n'
				i=$((i + 1))
			done > fi.stream
			git fast-import --quiet < fi.stream
			rm fi.stream
			git reset -q --hard
			[ "$(git rev-list --count "$from..HEAD")" -eq 200 ]
		)
		(
			cd "$t/edt"
			printf '%s\n' '| site | what |' '|---|---|' '| `script/test-citations.sh:1` | `sh` |' \
			    '| `script/test-citations.sh:1` | `/bin/sh` |' '| `script/test-citations.sh:1` | the shell |' \
			    '' 'Edit `zz.c:5` here.' > doc/a.md
			git commit -qam cite
			edit src/sys/fs/hammer2/zz.c 's/^int l_005;$/int l_005x;/'
			git commit -qam rewrite
		)
		# alg: shapes git's diff algorithm decides. In al.md a line
		# renumbered among other edits shares a hunk with its old line
		# under myers and not under patience; am.md is the same in the
		# working tree. al.c's line 5 is outside every hunk under myers
		# and inside one under patience, so the citation of it is right
		# under one and moved under the other. bl.md is the same shape
		# again, so git blame gives its last two lines to the first
		# commit under myers and to the last under patience, across a
		# move of the line they cite. ah.md holds a citation changed
		# from one hunk to another, a stated miss, and an.md no final
		# newline, whose marker line is part of a diff. ak.md's one hunk
		# is the last of its file, ap.md's the last of its commit, and
		# ao.md's one removed line has two renumbered lines beside it,
		# of which only one is its own. ih.c gains two lines that fit
		# either side of its line 4, and git's indent heuristic picks
		# the side: on, git's default, the line moves to 6; off, it
		# stays, so the citation of it in ih.md is moved under one and
		# right under the other.
		git clone -q "file://$t/pure" "$t/alg"
		(
			cd "$t/alg"
			git config user.email selftest@localhost
			git config user.name selftest
			git config commit.gpgsign false
			printf '%s\n' x '}' '}' 'Alg see (`:18`) here.' '' z '' > doc/history/al.md
			cp doc/history/al.md doc/history/am.md
			printf '%s\n' 'Split see (`:1`) here.' 'Pad 1.' 'Pad 2.' 'Pad 3.' 'Pad 4.' 'Other line.' > doc/history/ah.md
			printf 'One.' > doc/history/an.md
			printf '%s\n' 'Flush see (`:1`) here.' > doc/history/ak.md
			printf '%s\n' 'Last see (`:1`) here.' > doc/history/ap.md
			printf '%s\n' 'Twin see (`:1`) here.' > doc/history/ao.md
			printf '%s\n' 'int b;' 'int b;' 'int a;' 'return;' 'return;' 'return;' 'int b;' > src/sys/fs/hammer2/al.c
			printf '%s\n' 'Alg `al.c:5` here.' > doc/al.md
			printf '%s\n' 'int a;' 'int b;' 'int a;' 'f()' '' '}' > src/sys/fs/hammer2/ih.c
			printf '%s\n' 'Heur `ih.c:4` here.' > doc/ih.md
			printf '%s\n' 'Cite b `zz.c:1`.' 'Cite b `zz.c:1`.' 'Cite a `zz.c:1`.' 'Cite r `zz.c:5`.' \
			    'Cite r `zz.c:5`.' 'Cite r `zz.c:5`.' 'Cite b `zz.c:1`.' > doc/bl.md
			git add -A
			git commit -qm alg
			printf '%s\n' x '}' z '}' 'Alg see (`:19`) here.' '' '' > doc/history/al.md
			printf '%s\n' 'Pad 1.' 'Pad 2.' 'Pad 3.' 'Pad 4.' 'Split see (`:2`) here.' > doc/history/ah.md
			printf 'Two.' > doc/history/an.md
			printf '%s\n' 'Flush see (`:2`) here.' > doc/history/ak.md
			printf '%s\n' 'Twin see (`:2`) here.' 'Twin see (`:3`) here.' > doc/history/ao.md
			printf '%s\n' 'int b;' 'int a;' 'return;' 'int b;' 'return;' 'return;' > src/sys/fs/hammer2/al.c
			printf '%s\n' 'int a;' 'int b;' 'int a;' 'f()' '	return;' 'f()' '' '}' > src/sys/fs/hammer2/ih.c
			edit src/sys/fs/hammer2/zz.c 's/^int l_004;$/int l_004;\
int l_004b;/'
			git commit -qam alg2
			printf '%s\n' 'Cite b `zz.c:1`.' 'Cite a `zz.c:1`.' 'Cite r `zz.c:5`.' 'Cite b `zz.c:1`.' \
			    'Cite r `zz.c:5`.' 'Cite r `zz.c:5`.' > doc/bl.md
			printf '%s\n' 'Last see (`:2`) here.' > doc/history/ap.md
			git commit -qam alg3
			printf '%s\n' x '}' z '}' 'Alg see (`:19`) here.' '' '' > doc/history/am.md
		)
		printf '%s\n' '* diff=h2alg' > "$t/attrs-alg"
		# A textconv driver that prints nothing, and two attribute files
		# for the reader's configuration: one naming the driver for every
		# file, one marking every file binary.
		printf '#!/bin/sh\n' > "$t/tc-empty"
		chmod +x "$t/tc-empty"
		printf '%s\n' '* diff=h2tc' > "$t/attrs-tc"
		printf '%s\n' '* -diff' > "$t/attrs-bin"
		# A clone whose one commit renames the dated record and changes
		# one citation in it, which is a renumbering only to a reader
		# that follows the rename.
		git clone -q "file://$t/r" "$t/mv"
		(
			cd "$t/mv"
			git rm -q "doc/b'c.md" doc/history/t.md doc/history/v.md
			git mv doc/history/w.md doc/history/x.md
			edit doc/history/x.md 's/^Renum see (`:30`)/Renum see (`:40`)/'
			git -c user.name=selftest -c user.email=selftest@localhost -c commit.gpgsign=false commit -qam moved
		)
		# A clone whose last two commits add a dated record after the
		# floor and then change one citation in it: the commit adding
		# it has no old text to pair, and the one after is read as a
		# change to any other record.
		git clone -q "file://$t/pure" "$t/nf"
		(
			cd "$t/nf"
			git config user.email selftest@localhost
			git config user.name selftest
			git config commit.gpgsign false
			printf '%s\n' 'New see (`:5`) here.' > doc/history/n.md
			git add doc/history/n.md
			git commit -qm added
			edit doc/history/n.md 's/^New see (`:5`)/New see (`:6`)/'
			git commit -qam renumbered
		)
		# After those clones, which must read no renumbering: one line
		# of the dated record changed in its citation alone, a range
		# and a list each changed past their first number, one line
		# reworded with its citation, and eight reworded around a blank
		# line, which is one hunk holding that blank line on both sides
		# and is no renumbering, committed; then a clone that commit is
		# the only failure of; then another line changed in the working
		# tree. The same commit names the mark once more in the script,
		# so two commits change how often it occurs and the floor has to
		# be the first of them.
		printf '# %s, named again\n' H2CIT-RENUMBER-FLOOR >> script/test-citations.sh
		edit doc/history/w.md 's/^Renum see (`:30`)/Renum see (`:40`)/'
		edit doc/history/w.md 's/^Range see (`:70-75`)/Range see (`:70-85`)/'
		edit doc/history/w.md 's/^List see (`:90, 95`)/List see (`:90, 96`)/'
		edit doc/history/w.md 's/^Bare see `zz.c` 12-14/Bare see `zz.c` 13-15/'
		edit doc/history/w.md 's/^Head see `zz.h` 7/Head see `zz.h` 8/'
		edit doc/history/w.md 's/^Edit see (`:31`)/Edit, reread, see (`:41`)/'
		edit doc/history/w.md 's/^Gap \([ab][1-4]\)\./Gap \1, reread./'
		git commit -qm five doc/history/w.md script/test-citations.sh
		git clone -q "file://$t/r" "$t/ren"
		(
			cd "$t/ren"
			git rm -q "doc/b'c.md" doc/history/t.md doc/history/v.md
			printf '%s\n' '| site | what |' '|---|---|' '| `zz.c:1` | `l_001` |' '' 'Fine `zz.c:1` here.' > doc/a.md
			git -c user.name=selftest -c user.email=selftest@localhost -c commit.gpgsign=false commit -qam pure
		)
		edit doc/history/w.md 's/^Tree see (`:32`)/Tree see (`:42`)/'
		mkdir "$t/shim"
		# A git that fails one kind of read, named by H2CIT_FAIL, by
		# running it and then exiting 1, so its output is whole and only
		# its status says it failed; or answers a read with nothing; or
		# answers a blame with a line that dates nothing, or a blame of
		# one line with nothing; or adds a line to a log that no diff
		# holds. Everything else passes through.
		cat > "$t/shim/git" <<-SHIM
		#!/bin/sh
		sub=; skip=0; hasl=0
		for a do
			if [ \$skip = 1 ]; then skip=0; continue; fi
			case \$a in -c) skip=1 ;; -L) hasl=1 ;; -*) ;; *) [ -n "\$sub" ] || sub=\$a ;; esac
		done
		case "\${H2CIT_FAIL:-}:\$sub:\$hasl" in
		show:show:*|diff:diff:*|ls-tree:ls-tree:*|blame-L:blame:1|blame:blame:0|log:log:*) "$realgit" "\$@"; exit 1 ;;
		blame-empty:blame:0|log-empty:log:*) exit 0 ;;
		blame-junk:blame:0) echo 'h2cit: a line no blame prints'; exit 0 ;;
		blame-L-empty:blame:1) exit 0 ;;
		log-junk:log:*) "$realgit" "\$@"; echo 'h2cit: a line no diff holds'; exit 0 ;;
		esac
		exec "$realgit" "\$@"
		SHIM
		# And an awk that prints nothing where the renumber reader runs,
		# or runs the prose reader whole and then exits 3.
		cat > "$t/shim/awk" <<-SHIM
		#!/bin/sh
		case "\${H2CIT_FAIL:-}:\$*" in
		awk:*renumbered*) exit 1 ;;
		awk-prose:*'is never closed'*) "$realawk" "\$@"; exit 3 ;;
		esac
		exec "$realawk" "\$@"
		SHIM
		chmod +x "$t/shim/git" "$t/shim/awk"
	)
	built=$?
	if [ "$built" -ne 0 ]; then
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
		expect "$(at Moved\ )zz.c:30 moved since $(git -C "$t/r" rev-parse HEAD~4 | cut -c1-10), where the citation was written; now at 40" 'naming the commit and the line it went to'
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
		expect "$(at '`:65`')zz.c:65 moved since" 'a bare citation whose file is named two lines above, past a line naming none, is dated and read'
		absent "$(at '`:95`')zz.c:95" 'and once its line is reworded it dates from that change, not from where it cited another file'
		expect "$(at '`:30`')vv.c:30 moved since" 'and is read from then on, failing a move after that change'
		expect "note: $(at '`:20`')vv.c:20 belongs to a file its line did not cite" 'and so is one whose new file has since moved'
		absent "$(at '`:20`')vv.c:20 moved" 'which is not read'
		absent "$(at Collapse)zz.c:115 moved" 'a range collapsed to one end is not carried, a stated miss'
		absent "$(at Shrink)zz.c:41 moved" 'so a correct collapse to its start does not fail'
		absent "$(at Inplacetwo)zz.c:2 rewritten in place" 'a citing line being reworded now retires its note'
		expect "FAIL doc/b'c.md: a document name with a character outside [A-Za-z0-9_./-] is not read" 'a document name outside the plain set is refused by the marker loop, before anything is read from it'
		expect '1 whose file the dating commit lacks' 'a file absent from the dating commit is counted, not read'
		expect '2 not dated and named above' 'and both are counted'
		# The rows naming a function beside a line. The second is the
		# negative control: the line fn_a's body was on before the file
		# moved, which a row never renumbered would still cite.
		tw='FAIL doc/history/t.md: ff.c'
		expect "$tw:4 -- line 4 is outside fn_a(), which is ff.c:7-10" 'a line outside the function its row names fails, and the body is named'
		expect "$tw:9 -- line 9 is outside fn_b(), which is ff.c:13-16" 'so does a line inside another function'
		expect "$tw:9 -- no definition of fn_gone() at column 0 in ff.c" 'and a function the file does not define'
		expect "$tw:1 -- line 1 is outside fn_b()" 'a prototype is not a definition'
		expect "$tw:8 -- line 8 is outside fn_b()" 'a second line in the cell is read too'
		expect "$tw:24 -- no definition of fn_c() at column 0 in ff.c" 'a name at column 0 that opens no body is not a definition, and the function after it is not its body'
		absent 'fn_d()' 'a definition whose arguments run onto an indented line is one, and its row is read inside it'
		expect "$tw:31 -- line 31 is outside fn_a(), which is ff.c:7-10" 'a function whose name ends in the one named is not it'
		expect '  unchecked  doc/research/x.md: zz.c:1' 'a row in a document the table half does not read is named as read by neither half'
		expect '  unchecked  doc/research/x.md: ys.py:3' 'and so is one citing a file the readers take by an extension other than .c or .h'
		expect 'citations: 3 of 59 citation-shaped tokens in doc/ are read by neither half' 'and both are in the count of tokens, with the range row the table half does not take'
		expect 'FAIL doc/history/t.md: fb.c:4 -- no definition of fb_a() at column 0 in fb.c' 'a prototype followed by a brace not at column 0 is not a definition'
		absent 'FAIL doc/history/t.md: fb.c:13 ' 'and a closing brace not at column 0 does not end a body'
		expect 'FAIL doc/history/t.md: absent.c:3 -- no such file (src/sys/fs/hammer2/absent.c)' 'a row citing a file the tree does not hold fails'
		expect 'FAIL doc/history/t.md: ff.c:999 -- line 999 past end of src/sys/fs/hammer2/ff.c (32 lines)' 'and one citing a line past the end of its file'
		expect "FAIL doc/history/t.md: ff.c:9 -- 'fn_b' is not on ff.c:9" 'and one whose symbol is not on its line'
		expect 'FAIL doc/history/t.md: gone.c:3 -- no such file (src/sys/fs/hammer2/gone.c)' 'a row naming a file the tree does not hold fails'
		expect "FAIL doc/history/t.md: ../../../../../../../etc/hostname:1 -- '../../../../../../../etc/hostname' is not a path of this tree" 'and one whose path leaves the tree is refused rather than read, since a row is as untrusted as the document holding it'
		expect "FAIL doc/history/t.md: /etc/hostname:1 -- '/etc/hostname' is not a path of this tree" 'and one naming an absolute path'
		expect "FAIL doc/history/t.md: ../escaped.c:1 -- '../escaped.c' is not a path of this tree" 'and a path out of the tree in the two-cell shape, which reads its file through its own resolver'
		expect "FAIL doc/history/t.md: :5 -- '' is not a path of this tree" 'and a row with an empty file cell is refused, not taken as the port own directory'
		expect 'FAIL doc/history/t.md: x;z.c:2 -- no such file (src/sys/fs/hammer2/x;z.c)' 'and a row whose file name holds a character outside the plain set is read and fails, where it was silently unread'
		expect 'FAIL doc/history/t.md: y;w.c:2 -- no such file (src/sys/fs/hammer2/y;w.c)' 'and the same in the two-cell shape, whose pattern is widened for it too'
		expect "FAIL doc/history/t.md: /etc/hostname:1 -- '/etc/hostname' is not a path of this tree" 'and an absolute path in the two-cell shape, where the entry test is the only one that sees it'
		absent "$tw:14 " 'and a first line inside passes beside it'
		expect "$tw:10 -- line 10 is outside fn_a(), which is ff.c:2-5 at $one" 'a pinned row is read at its commit, where it fails'
		absent "$tw:4 -- line 4 is outside fn_a(), which is ff.c:2-5" 'and passes there where the tree would fail it'
		absent 'FAIL doc/history/u.md' 'a document of right rows has no failure'
		expect "doc/history is not renumbered when the tree moves" 'a failing row of a dated record says to pin it'
		tv='FAIL doc/history/v.md'
		expect "$tv:2: a region end with no region open" 'in a dated record an end with no region open fails'
		expect "$tv:3: not a region marker: <!-- citations at HEAD -->" 'a marker naming no hash fails'
		expect "$tv:5: region pinned to 0000000, which is not a commit here" 'a hash that is no commit fails'
		expect "$tv:6: a region opened inside the one open" 'a region opened inside another fails'
		expect "$tv:7: not a region marker: <!-- citations here -->" 'a line shaped like a marker fails'
		expect "$tv:7: a region left open at the end of the document" 'and so does a region left open'
		expect "FAIL $five: doc/history/w.md renumbered: Renum see (\`:40\`) here." 'a dated record changed by a commit in citation digits alone fails'
		expect 'FAIL worktree: doc/history/w.md renumbered: Tree see (`:42`) here.' 'and so does one changed in the working tree'
		expect "FAIL $five: doc/history/w.md renumbered: Range see (\`:70-85\`) here." 'and one changed in the end of a range'
		expect "FAIL $five: doc/history/w.md renumbered: List see (\`:90, 96\`) here." 'and one changed in the second number of a list'
		expect "FAIL $five: doc/history/w.md renumbered: Bare see \`zz.c\` 13-15 here." 'and one that names its file and then its lines, with no colon between'
		expect "FAIL $five: doc/history/w.md renumbered: Head see \`zz.h\` 8 here." 'of a header as of a source file'
		absent 'renumbered: Edit' 'a line reworded with its number is not one'
		expect "6 line(s) of doc/history changed in citation digits alone, in 2 of 3 change(s) to it read over $one..HEAD and the working tree" 'and the changes read are counted from the first commit to name the mark, where a later one names it again'
		expect '22 row(s) shaped `file:N` `symbol()` and 21 read' 'a row of the shape that the reader does not take fails the count'
		expect '21 row(s) naming a function beside 23 cited line(s), 10 inside it, 0 pinned and not read' 'and the counts are the rows built'
	}
	one=$(git -C "$t/r" rev-parse --short HEAD~4)
	five=$(git -C "$t/r" rev-parse --short HEAD)
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
	# Every failure the status is made from is a line printed, and every
	# such line is counted once, in the count of its half. The tree most
	# runs here read fails in both halves, so the status of such a run
	# says nothing about a failure of either that is printed and not
	# counted.
	counted() {
		cn=$(printf '%s\n' "$out" | sed -n 's/^citations: .* unanchored note(s), \([0-9]*\) failure(s)$/\1/p')
		cm=$(printf '%s\n' "$out" | command grep -cE '^(FAIL |citations: FAIL: )' || true)
		pn=$(printf '%s\n' "$out" | sed -n 's/^citations: [0-9]* prose citation(s) .*, \([0-9]*\) failure(s)$/\1/p')
		pm=$(printf '%s\n' "$out" | command grep -c '^  FAIL prose ' || true)
		if [ -n "$cn" ] && [ "$cn" = "$cm" ] && [ -n "$pn" ] && [ "$pn" = "$pm" ]; then
			echo "  ok    $cm failure line(s) printed and $cm counted, $pm of the prose and $pm counted$1"
		else
			echo "  FAIL  $cm failure line(s) printed and [$cn] counted, $pm of the prose and [$pn] counted$1"
			sf=1
		fi
	}
	exits() {
		if [ "$rc" -eq "$1" ]; then
			echo "  ok    and exits $1"
		else
			echo "  FAIL  exit $rc, where $1"
			sf=1
		fi
	}
	out=$(cd "$t/r" && sh script/test-citations.sh 2>&1)
	rc=$?
	main
	expect 'citations: 63 prose citation(s) of the source in the living documents, 18 failure(s)' 'and the prose half counts every citation it read, those that hold with those that fail'
	counted ''
	tally ', so the correct remaps, the fresh line and the stated misses pass'
	expect 'rot read on 43 cited line(s), 17 of them dated past a later edit of their line, 18 moved or deleted since written, 1 rewritten in place, 1 whose file the dating commit lacks, 2 not dated and named above' 'and each count of the rot check is the citations built'
	base=$(printf '%s\n' "$out" | command grep '^citations: rot read on')
	out=$(cd "$t/r" && git config diff.external true && git config blame.ignoreRevsFile '.ignore revs' &&
	    GIT_EXTERNAL_DIFF=true sh script/test-citations.sh 2>&1)
	rc=$?
	tally ' with an external diff tool and an ignored-revisions file configured'
	main
	counted ' with them configured'
	expect "$base" 'and every count of the rot check the same'
	(cd "$t/r" && git config --unset diff.external && git config --unset blame.ignoreRevsFile)
	# Color configured on: every line git prints of a diff then opens
	# with an escape, and a reader given that would know none of them.
	out=$(cd "$t/r" && git config color.ui always && sh script/test-citations.sh 2>&1)
	rc=$?
	(cd "$t/r" && git config --unset color.ui)
	tally ' with color configured on'
	main
	counted ' with color on'
	# The reader's configuration naming a textconv driver that prints
	# nothing, or marking every file binary, with nothing in the tree;
	# then each of the three settings that change the prefix the
	# renumber reader takes a file's name from, and hunks merged across
	# ten unchanged lines.
	for a in tc bin; do
		out=$(cd "$t/r" && git config core.attributesFile "$t/attrs-$a" && git config diff.h2tc.textconv "$t/tc-empty" &&
		    sh script/test-citations.sh 2>&1)
		rc=$?
		(cd "$t/r" && git config --unset core.attributesFile && git config --unset diff.h2tc.textconv)
		[ "$a" = tc ] && w='a textconv driver' || w='a binary attribute'
		tally " with $w configured for every file"
		main
		counted " with $w configured"
		expect "$base" 'and every count of the rot check the same'
	done
	for p in 'diff.noprefix true' 'diff.mnemonicPrefix true' 'diff.dstPrefix z/' 'diff.interHunkContext 10'; do
		# shellcheck disable=SC2086
		out=$(cd "$t/r" && git config $p && sh script/test-citations.sh 2>&1)
		rc=$?
		(cd "$t/r" && git config --unset "${p% *}")
		tally " with $p configured"
		main
		counted " with $p configured"
	done
	for m in show diff ls-tree blame-L blame; do
		out=$(cd "$t/r" && H2CIT_FAIL=$m PATH="$t/shim:$PATH" sh script/test-citations.sh 2>&1)
		rc=$?
		counted " with a failing $m read"
		case $m in
		show) w='git show' ;;
		diff) w='git diff' ;;
		ls-tree) w='git ls-tree' ;;
		blame-L) w='git blame of' ;;
		blame) w='git blame failed' ;;
		esac
		if [ "$m" = diff ]; then
			expect 'FAIL: git diff of doc/history failed, so the working tree is not read for a renumbered record' 'a failing diff read fails the renumber check'
		fi
		if [ "$m" = show ]; then
			expect "FAIL doc/history/u.md: ff.c:4 -- git show $one:src/sys/fs/hammer2/ff.c failed" 'a pinned row whose commit cannot be read fails'
		fi
		if [ "$m" = ls-tree ]; then
			absent 'moved since' 'a citation whose dating commit cannot be read for its file is not mapped'
		fi
		if [ "$rc" -eq 1 ] && printf '%s\n' "$out" | command grep -q "FAIL prose.*$w"; then
			echo "  ok    a failing $m read fails the gate"
		else
			echo "  FAIL  a failing $m read: exit $rc, no line naming [$w]"
			sf=1
		fi
	done
	out=$(cd "$t/r" && H2CIT_FAIL=log PATH="$t/shim:$PATH" sh script/test-citations.sh 2>&1)
	expect 'FAIL: git log of script/test-citations.sh failed, so no commit is read for a renumbered record' 'a failing log read fails the renumber check'
	absent 'renumbered: Renum' 'and reads nothing'
	counted ' with a failing log read'
	out=$(cd "$t/r" && H2_RENUMBER_RANGE="$one..$five^" sh script/test-citations.sh 2>&1)
	expect "0 line(s) of doc/history changed in citation digits alone, in 0 of 1 change(s) to it read over $one..$five^" 'a range given is the range read, without the working tree'
	counted ' over a range given'
	out=$(cd "$t/r" && H2_RENUMBER_RANGE='--all' sh script/test-citations.sh 2>&1)
	expect 'FAIL: H2_RENUMBER_RANGE is not a revision range: --all' 'a range that is an option is refused'
	counted ' with a range refused'
	out=$(cd "$t/r" && H2CIT_FAIL=log H2_RENUMBER_RANGE="$one..HEAD" PATH="$t/shim:$PATH" sh script/test-citations.sh 2>&1)
	expect "FAIL: git log of doc/history failed over $one..HEAD, so no commit is read for a renumbered record" 'and so does a failing read of the range'
	counted ' with a failing read of a range'
	out=$(cd "$t/r" && H2CIT_FAIL=awk PATH="$t/shim:$PATH" sh script/test-citations.sh 2>&1)
	expect 'FAIL: the renumber reader printed no total' 'a reader that prints nothing fails the renumber check'
	absent 'renumbered: Renum' 'and reads nothing'
	counted ' with a reader that prints nothing'
	out=$(cd "$t/r" && H2CIT_FAIL=log-junk PATH="$t/shim:$PATH" sh script/test-citations.sh 2>&1)
	expect 'FAIL: 1 line(s) of the history of doc/history are no diff line the renumber reader knows' 'a line of the log that no diff holds fails the renumber check'
	counted ' with a line no diff holds'
	out=$(cd "$t/r" && H2CIT_FAIL=log-empty PATH="$t/shim:$PATH" sh script/test-citations.sh 2>&1)
	expect 'FAIL: no commit introduces H2CIT-RENUMBER-FLOOR, so the renumber check has no floor' 'a committed check that no commit introduces fails'
	counted ' with no floor'
	cp -R "$t/clean" "$t/dev"
	echo '# edited' >> "$t/dev/script/test-citations.sh"
	out=$(cd "$t/dev" && H2CIT_FAIL=log-empty PATH="$t/shim:$PATH" sh script/test-citations.sh 2>&1)
	expect 'no commit read for a renumbered record: this check is not committed yet' 'an edited check that no commit introduces says it is not committed'
	absent 'so the renumber check has no floor' 'and does not fail for it'
	counted ' with the check edited'
	# The same state reached by changing the mark's value on a clone
	# whose history holds a renumbering: no commit names the new value,
	# so the history since the floor goes unread until it is committed.
	# The new value is made at run time: one written here would be in
	# the scratch history's copy of this script, and a commit would
	# name it.
	cp -R "$t/ren" "$t/wm"
	sed "s/^rmark=H2CIT-RENUMBER-FLOOR\$/rmark=H2CIT-RENUMBER-FLOOR-$$/" "$t/ren/script/test-citations.sh" > "$t/wm/script/test-citations.sh"
	if cmp -s "$t/ren/script/test-citations.sh" "$t/wm/script/test-citations.sh"; then
		echo "  FAIL  the mark's value is not on a line of its own in the script"
		sf=1
	fi
	out=$(cd "$t/wm" && sh script/test-citations.sh 2>&1)
	rc=$?
	expect 'no commit read for a renumbered record: this check is not committed yet' "a mark changed in the working tree reads as a check not committed"
	absent 'renumbered:' 'and reads no renumbering of the history, its committed one included'
	counted ' with the mark changed in the working tree'
	exits 0
	out=$(cd "$t/clean" && sh script/test-citations.sh 2>&1)
	expect "0 line(s) of doc/history changed in citation digits alone, in 0 of 2 change(s) to it read over $one..HEAD and the working tree" 'a history with no renumbering has none, its two changes read'
	counted ' with no renumbering'
	out=$(cd "$t/pure" && sh script/test-citations.sh 2>&1)
	rc=$?
	expect "0 line(s) of doc/history changed in citation digits alone, in 0 of 2 change(s) to it read over $one..HEAD and the working tree" 'nor has a tree with nothing wrong in it'
	expect 'citations: 2 prose citation(s) of the source in the living documents, 0 failure(s)' 'and its two prose citations are counted as read'
	counted ' with nothing wrong'
	if [ "$rc" -eq 0 ]; then echo "  ok    which exits 0"; else echo "  FAIL  a tree with nothing wrong exits $rc, where 0"; printf '%s\n' "$out" | sed 's/^/        /'; sf=1; fi
	# A document name outside the plain set outside doc/, which the
	# marker loop never lists. The prose half refuses it and counts it
	# there; counted as the marker loop's would leave the line printed
	# and the run green.
	git clone -q "file://$t/pure" "$t/oddtop"
	(
		cd "$t/oddtop" || exit 2
		printf '# t\n' > 'README;odd.md'
		git add 'README;odd.md'
		git -c user.name=selftest -c user.email=selftest@localhost -c commit.gpgsign=false commit -qm odd
	)
	out=$(cd "$t/oddtop" && sh script/test-citations.sh 2>&1)
	rc=$?
	expect '  FAIL prose README;odd.md: a document name with a character outside [A-Za-z0-9_./-] is not read' 'a name outside the plain set outside doc/ is refused by the prose half'
	expect 'citations: 3 prose citation(s) of the source in the living documents, 1 failure(s)' 'and counted by it, where the marker loop never listed it'
	counted ' with such a name'
	exits 1
	# Two such names under doc/, which the marker loop lists. Each is
	# reported once, by the loop, and skipped by the prose half: a skip
	# that matched one of them by its shape would report the other a
	# second time, and a name read as words would be read as the
	# documents its fragments spell and never opened.
	git clone -q "file://$t/pure" "$t/oddtwo"
	(
		cd "$t/oddtwo" || exit 2
		printf 'a\n' > 'doc/a;1.md'
		printf 'b\n' > 'doc/b;2.md'
		git add -A
		git -c user.name=selftest -c user.email=selftest@localhost -c commit.gpgsign=false commit -qm odd
	)
	out=$(cd "$t/oddtwo" && sh script/test-citations.sh 2>&1)
	rc=$?
	expect 'FAIL doc/a;1.md: a document name with a character outside [A-Za-z0-9_./-] is not read' 'of two odd names the marker loop refuses, the first is reported by it'
	expect 'FAIL doc/b;2.md: a document name with a character outside [A-Za-z0-9_./-] is not read' 'and the second'
	absent 'FAIL prose doc/a;1.md' 'and neither is reported a second time by the prose half'
	absent 'FAIL prose doc/b;2.md' 'not even the last name the loop recorded'
	exits 1
	# A tracked name holding a space, whose fragments are documents of
	# the tree. Read as words it is two documents read and the name
	# never opened, so its body, holding a marker that fails in every
	# other fixture, would pass unnoticed.
	git clone -q "file://$t/pure" "$t/oddspace"
	(
		cd "$t/oddspace" || exit 2
		printf 'a\n' > doc/a.md
		printf 'x\n' > doc/x.md
		printf 'a\n<!-- citations here -->\n' > 'doc/a.md x.md'
		git add -A
		git -c user.name=selftest -c user.email=selftest@localhost -c commit.gpgsign=false commit -qm spaced
	)
	out=$(cd "$t/oddspace" && sh script/test-citations.sh 2>&1)
	rc=$?
	expect 'FAIL doc/a.md x.md: a document name with a character outside [A-Za-z0-9_./-] is not read' 'a name holding a space is refused whole, not read as its fragments'
	absent 'not a region marker' 'so its body is not read either'
	exits 1
	# A name holding a tab. Both lists name it, and one spelling serves
	# both, so it is refused once; read from the filesystem in one and
	# from git in the other it would be two names and two refusals, git
	# quoting the tab and ls printing it.
	git clone -q "file://$t/pure" "$t/oddtabs"
	(
		cd "$t/oddtabs" || exit 2
		printf 'a\n' > "doc/t$(printf '\t')b.md"
		git add -A
		git -c user.name=selftest -c user.email=selftest@localhost -c commit.gpgsign=false commit -qm tab
	)
	out=$(cd "$t/oddtabs" && sh script/test-citations.sh 2>&1)
	rc=$?
	if printf '%s\n' "$out" | command grep -qF -- "$(printf 'FAIL doc/t\tb.md: a document name')"; then
		echo "  ok    a name holding a tab is refused"
	else
		echo "  FAIL  a name holding a tab is not refused by that name:"
		printf '%s\n' "$out" | command grep 'document name' | sed 's/^/        /'
		sf=1
	fi
	if [ "$(printf '%s\n' "$out" | command grep -c 'document name with a character')" -eq 1 ]; then
		echo "  ok    once, by one half, where two spellings of the name would print it twice"
	else
		echo "  FAIL  the tab-named document is refused $(printf '%s\n' "$out" | command grep -c 'document name with a character') time(s), where once: the two lists spell it differently"
		sf=1
	fi
	# A name on both halves' lists: a top-level doc/*.md outside the
	# plain set, which the table half lists and the prose half reads too.
	# One refusal, by the table half, which lists it and runs first, and
	# the prose half skips it as a document on that list.
	git clone -q "file://$t/pure" "$t/oddboth"
	(
		cd "$t/oddboth" || exit 2
		printf 'a\n' > 'doc/r;1.md'
		git add -A
		git -c user.name=selftest -c user.email=selftest@localhost -c commit.gpgsign=false commit -qm both
	)
	out=$(cd "$t/oddboth" && sh script/test-citations.sh 2>&1)
	rc=$?
	if [ "$(printf '%s\n' "$out" | command grep -c 'document name with a character')" -eq 1 ]; then
		echo "  ok    a name on both halves' lists is refused once"
	else
		echo "  FAIL  a name on both halves' lists is refused $(printf '%s\n' "$out" | command grep -c 'document name with a character') time(s), where once: the half that did not list it reported it too"
		printf '%s\n' "$out" | command grep 'document name' | sed 's/^/        /'
		sf=1
	fi
	exits 1
	# The records git lists under one pathspec in one clone.
	nrecs() { (cd "$1" && git ls-files -z "$2" | tr -cd '\0' | wc -c | tr -d ' '); }
	# A name holding a newline, which a line-per-name list cannot carry.
	# Read as two lines it is the two documents its fragments spell, and
	# where those are tracked the run reads them and never the name. The
	# listing is held to its record count instead, so the run says it
	# cannot report rather than passing over the document.
	git clone -q "file://$t/pure" "$t/oddnl"
	(
		cd "$t/oddnl" || exit 2
		printf 'x\n' > "doc/IO_MODEL.md
README.md"
		git add -A
		git -c user.name=selftest -c user.email=selftest@localhost -c commit.gpgsign=false commit -qm nl
	)
	out=$(cd "$t/oddnl" && sh script/test-citations.sh 2>&1)
	rc=$?
	nwide=$(nrecs "$t/oddnl" '*.md*')
	expect "$nwide tracked name(s) list as $((nwide + 1)) line(s)" 'a name holding a newline is a run that cannot report, not one that reads its fragments'
	exits 2
	# A name that ENDS in a newline, which '*.md' does not list since such
	# a name does not end in .md. Read through that pathspec the document
	# was gone before any count saw it, and the run passed over it in
	# silence. The listing is taken wide enough to hold it, so the record
	# count sees it and the run refuses to report rather than reading
	# every other document and none of this one. This fixture fails if
	# the pathspec goes back to '*.md'.
	git clone -q "file://$t/pure" "$t/trailnl"
	(
		cd "$t/trailnl" || exit 2
		printf 'x\n' > "doc/IO_MODEL.md
"
		git add -A
		git -c user.name=selftest -c user.email=selftest@localhost -c commit.gpgsign=false commit -qm trail
	)
	# The name is in the index, which a pathspec ending in ? reads since
	# ? takes the newline, and the wide pathspec lists one record more
	# than the narrow one: both halves of the control, so a change to
	# either the fixture or git's matching is visible here rather than in
	# a green run.
	nin=$(nrecs "$t/trailnl" 'doc/IO_MODEL.md?')
	nmd=$(nrecs "$t/trailnl" '*.md')
	nwide=$(nrecs "$t/trailnl" '*.md*')
	if [ "$nin" -eq 1 ] && [ "$nwide" -eq $((nmd + 1)) ]; then
		echo "  ok    a name ending in a newline is one record git lists and the '*.md' pathspec leaves out"
	else
		echo "  FAIL  the trailing-newline name is [$nin] record(s) of the index, [$nmd] under '*.md' and [$nwide] under '*.md*', where 1 and the last one more than the one before"
		sf=1
	fi
	out=$(cd "$t/trailnl" && sh script/test-citations.sh 2>&1)
	rc=$?
	expect "$nwide tracked name(s) list as $((nwide + 1)) line(s)" 'a name ending in a newline is a run that cannot report, not one that passes over the document'
	exits 2
	# A name the wide pathspec lists that does not end in .md is no
	# document. This one is outside the plain set, so a run that took it
	# for a document would refuse it by name and exit 1.
	git clone -q "file://$t/pure" "$t/oddext"
	(
		cd "$t/oddext" || exit 2
		printf 'a\n' > 'doc/r;1.mdx'
		git add -A
		git -c user.name=selftest -c user.email=selftest@localhost -c commit.gpgsign=false commit -qm ext
	)
	out=$(cd "$t/oddext" && sh script/test-citations.sh 2>&1)
	rc=$?
	if [ "$(nrecs "$t/oddext" '*.md*')" -eq $(($(nrecs "$t/oddext" '*.md') + 1)) ]; then
		echo "  ok    a name ending in .mdx is one record the wide pathspec adds"
	else
		echo "  FAIL  the .mdx name is not the one record '*.md*' lists past '*.md'"
		sf=1
	fi
	absent 'document name with a character' 'and it is not read as a document'
	exits 0
	# One trap removes both files the gate makes. A second `trap ... EXIT`
	# replaces the first, so a trap beside each mktemp left the first file
	# behind on every run of the gate. The directory is the fixture's own
	# and empty, so a file in it after the run is one the run left: it
	# fails if a file is added without the trap or the trap stops naming
	# one. A run given a TMPDIR makes its files there (mktemp with no
	# template reads it), and the shared /tmp moves under such a reading
	# for every other process that writes one: in eight selftests run
	# side by side, five reported a file they never made.
	tdir=$t/tdir
	mkdir "$tdir" || exit 2
	out=$(cd "$t/pure" && TMPDIR="$tdir" sh script/test-citations.sh 2>&1)
	na=$(ls "$tdir" | wc -l | tr -d ' ')
	if [ "$na" -eq 0 ]; then
		echo "  ok    a run leaves no temporary file behind"
	else
		echo "  FAIL  a run left $na temporary file(s) behind"
		sf=1
	fi
	# Without the blank line on both sides of one hunk, the count below
	# says nothing about a line a hunk carries unchanged.
	gap=$(git -C "$t/ren" log -1 --format= -U0 -p --grep='^five$' -- doc/history/w.md | command grep -c '^[-+]$' || true)
	if [ "$gap" -eq 2 ]; then echo "  ok    git prints a frequent blank line on both sides of the hunk around it"; else echo "  FAIL  git printed the blank line $gap time(s) in the fixture's hunk, where 2: the pairing of unchanged lines is not exercised"; sf=1; fi
	out=$(cd "$t/ren" && sh script/test-citations.sh 2>&1)
	rc=$?
	expect "5 line(s) of doc/history changed in citation digits alone, in 1 of 3 change(s) to it read over $one..HEAD and the working tree" 'a renumbering as the only failure is its five lines, the blank line its hunk carries on both sides not a sixth'
	absent 'FAIL prose' 'with no other failure beside it'
	if [ "$rc" -eq 1 ]; then echo "  ok    and exits 1"; else echo "  FAIL  the renumbered clone exits $rc, where 1"; sf=1; fi
	counted ' with a renumbering alone'
	# The halves fail apart as well as together: each of the two exits
	# that read both counts is reached with one of them zero.
	out=$(cd "$t/ren" && git config blame.ignoreRevsFile no-such-file && sh script/test-citations.sh 2>&1)
	rc=$?
	(cd "$t/ren" && git config --unset blame.ignoreRevsFile)
	expect 'the rot check did not run' 'the same renumbering where the rot check cannot run still fails'
	counted ' with a renumbering alone and no rot check'
	exits 1
	out=$(cd "$t/pure" && H2CIT_FAIL=awk-prose PATH="$t/shim:$PATH" sh script/test-citations.sh 2>&1)
	rc=$?
	expect '  FAIL prose doc/a.md: the prose reader stopped with status 3' 'a prose reader that stops with a status fails its document'
	counted ' with a failure of the prose alone'
	exits 1
	out=$(cd "$t/pure" && git config blame.ignoreRevsFile no-such-file && H2CIT_FAIL=awk-prose PATH="$t/shim:$PATH" sh script/test-citations.sh 2>&1)
	rc=$?
	(cd "$t/pure" && git config --unset blame.ignoreRevsFile)
	expect 'the rot check did not run' 'the same failure where the rot check cannot run still fails'
	counted ' with a failure of the prose alone and no rot check'
	exits 1
	# A record renamed and renumbered in one commit, read by a user
	# whose configuration turns rename detection off.
	six=$(git -C "$t/mv" rev-parse --short HEAD)
	out=$(cd "$t/mv" && git config diff.renames false && sh script/test-citations.sh 2>&1)
	expect "FAIL $six: doc/history/x.md renumbered: Renum see (\`:40\`) here." 'a dated record renumbered in the commit that renames it fails with rename detection configured off'
	expect "1 line(s) of doc/history changed in citation digits alone, in 1 of 2 change(s) to it read over $one..HEAD and the working tree" 'and is its one line'
	counted ' with a record renamed'
	# The same commit read with rename detection on and a rename limit
	# of 1, below the three removed files times the one added.
	out=$(cd "$t/mv" && git config --unset diff.renames && git config diff.renameLimit 1 && sh script/test-citations.sh 2>&1)
	expect "FAIL $six: doc/history/x.md renumbered: Renum see (\`:40\`) here." 'and with a rename limit configured below what the commit renames'
	expect "1 line(s) of doc/history changed in citation digits alone, in 1 of 2 change(s) to it read over $one..HEAD and the working tree" 'and is its one line'
	counted ' with a rename limit'
	# A record added after the floor and renumbered in the commit
	# after.
	nfadd=$(git -C "$t/nf" rev-parse --short HEAD~1)
	nfren=$(git -C "$t/nf" rev-parse --short HEAD)
	out=$(cd "$t/nf" && sh script/test-citations.sh 2>&1)
	rc=$?
	expect "FAIL $nfren: doc/history/n.md renumbered: New see (\`:6\`) here." 'a record added after the floor and renumbered in a later commit fails'
	absent "FAIL $nfadd:" 'and the commit adding it is no renumbering'
	expect '1 line(s) of doc/history changed in citation digits alone' 'and is its one line'
	counted ' with a record added after the floor'
	exits 1
	# The exits a failing tree never reaches.
	out=$(cd "$t/norows" && sh script/test-citations.sh 2>&1)
	rc=$?
	expect 'COULD-NOT-RUN: no file:line citation rows found' 'documents with no row for the table half are no run of it'
	exits 2
	out=$(cd "$t/norows" && sed 's/`ff.c:9` `fn_a()`/`ff.c:9` `fn_b()`/' doc/history/u.md > u.new && mv u.new doc/history/u.md &&
	    sh script/test-citations.sh 2>&1)
	rc=$?
	expect 'FAIL doc/history/u.md: ff.c:9 -- line 9 is outside fn_b(), which is ff.c:13-16' 'and a function row wrong there'
	expect 'COULD-NOT-RUN: no file:line citation rows found' 'beside no row for the table half'
	exits 1
	out=$(cd "$t/noprose" && sh script/test-citations.sh 2>&1)
	rc=$?
	expect 'COULD-NOT-RUN: no prose citation of the source found' 'documents with no prose citation of the source are no run of the prose half'
	exits 2
	out=$(cd "$t/noprose" && sed 's/`sh`/`nosuchword`/' doc/a.md > a.new && mv a.new doc/a.md && sh script/test-citations.sh 2>&1)
	rc=$?
	expect "FAIL doc/a.md: script/test-citations.sh:1 -- 'nosuchword' is not on" 'and a row wrong there is still a failure'
	exits 1
	out=$(cd "$t/pop" && sh script/test-citations.sh 2>&1)
	rc=$?
	expect 'FAIL: counted 1 citation-shaped tokens in doc/ but' 'more rows read than citation-shaped tokens counted fails the count'
	exits 1
	out=$(cd "$t/liv" && sh script/test-citations.sh 2>&1)
	rc=$?
	expect '  FAIL prose doc/m.md:1: a region end with no region open' 'in a living document an end with no region open fails'
	expect '  FAIL prose doc/m.md:2: not a region marker: <!-- citations here -->' 'and a line shaped like a marker'
	expect '  FAIL prose doc/m.md:3: gone.c:3 names no file of the port' 'and a citation of a file the port does not hold'
	expect '  FAIL prose doc/esc.md:1: src/sys/fs/hammer2/../secret.c:2 names no file of the port' 'a prose citation that climbs out of the directory it names is refused, not opened'
	expect '  FAIL prose doc/esc.md:2: src/sys/fs/hammer2/../../../../../outside.c:1 names no file of the port' 'and so is one that leaves the tree'
	expect '  FAIL prose doc/m.md:4: :5 follows gone.c, which names no file of the port' 'and a bare line after the name of one'
	expect '  FAIL prose doc/m.md:5: region pinned to 0000000, which is not a commit here' 'and a region pinned to no commit'
	expect "  FAIL prose doc/m.md:7: region pinned to $one is never closed" 'and a region never closed'
	expect '  FAIL prose doc/m.md:8: a fenced block opened by ``` is never closed' 'and a fence never closed'
	expect '  FAIL prose doc/q.md:6: a path in its history (doc/q=r.md, doc/q.md) is not one the reader passes to git' 'a line whose history passes through such a document name fails'
	expect '  FAIL prose doc/k.md:6: zz.c:1 carried through 200 or more edits' 'and so does a line carried through as many edits as the carry follows'
	expect '  FAIL prose doc/p.md:1: ff.c:11 lands on []' 'a citation of a blank line fails'
	expect '  FAIL prose doc/p.md:2: ff.c:10 lands on [}]' 'and of a closing brace'
	expect '  FAIL prose doc/p.md:3: ff.c:99 lands on [past the end]' 'and of a line past the end of its file'
	expect '  FAIL prose doc/p.md:4: ff.c:30-40 ends past the end of the file' 'and a range ending past it'
	expect '  FAIL prose doc/p.md:5: pl.c:2 lands on [};]' 'and a line closing a declaration'
	expect '  FAIL prose doc/p.md:6: pl.c:3 lands on [*/]' 'and a line closing a comment'
	expect '  FAIL prose doc/p.md:7: pq.h:2 lands on [}]' 'and a header named alone, found under src/sys/sys/'
	absent 'FAIL doc/m.md:' 'the markers of a living document are not read as a dated record'
	absent 'doc/f.md' 'a closed fence, a word starting like a file name, a quoted kernel message and a pinned line since moved are no failure'
	counted ' with a living document wrong in each of those ways'
	exits 1
	# The same with an ignored-revisions file naming one of the commits
	# the carry crosses, which the carry's blames must not skip.
	git -C "$t/liv" rev-parse HEAD~50 > "$t/liv-ignore"
	out=$(cd "$t/liv" && git config blame.ignoreRevsFile "$t/liv-ignore" && sh script/test-citations.sh 2>&1)
	rc=$?
	(cd "$t/liv" && git config --unset blame.ignoreRevsFile)
	expect '  FAIL prose doc/k.md:6: zz.c:1 carried through 200 or more edits' 'a carry with an ignored-revisions file configured still crosses each commit'
	exits 1
	a2=$(git -C "$t/alg" rev-parse --short HEAD~1)
	a3=$(git -C "$t/alg" rev-parse --short HEAD)
	out=$(cd "$t/alg" && sh script/test-citations.sh 2>&1)
	rc=$?
	alg=$out
	expect "FAIL $a2: doc/history/al.md renumbered: Alg see (\`:19\`) here." 'a renumbering whose hunk the diff algorithm decides fails under the pinned one'
	expect 'FAIL worktree: doc/history/am.md renumbered: Alg see (`:19`) here.' 'in the working tree as in a commit'
	expect "FAIL $a2: doc/history/ak.md renumbered: Flush see (\`:2\`) here." 'a renumbering in the last hunk of a file is named with its file'
	expect "FAIL $a3: doc/history/ap.md renumbered: Last see (\`:2\`) here." 'and in the last hunk of a commit with its commit'
	n=$(printf '%s\n' "$out" | command grep -c 'renumbered: Twin' || true)
	if [ "$n" -eq 1 ]; then echo "  ok    a removed line pairs with one added line only"; else echo "  FAIL  $n line(s) renumbered: Twin, where 1"; sf=1; fi
	n=$(printf '%s\n' "$out" | command grep -e "^FAIL $a2: doc/history/ak.md" -e "^FAIL $a3: doc/history/ap.md" | cut -d' ' -f2 | tr -d : | tr '\n' ' ')
	if [ "$n" = "$a2 $a3 " ]; then echo "  ok    and the commits are read oldest first"; else echo "  FAIL  the commits are read in the order [$n], where [$a2 $a3]"; sf=1; fi
	absent 'renumbered: Split' 'a citation changed from one hunk to another is not one, a stated miss'
	absent 'no diff line the renumber reader knows' 'and a file with no final newline has no line the reader does not know'
	absent 'doc/al.md' 'a line the pinned algorithm leaves in place is no failure'
	expect "  FAIL prose doc/bl.md:3: zz.c:5 moved since" 'a line blame dates before the move it cites fails'
	expect "  FAIL prose doc/bl.md:6: zz.c:5 moved since" 'by the pinned algorithm'
	expect "  FAIL prose doc/ih.md:1: ih.c:4 moved since" 'a line the indent heuristic moves fails under the pinned heuristic'
	counted ' with the diff algorithm deciding'
	exits 1
	out=$(cd "$t/alg" && git config core.attributesFile "$t/attrs-alg" && git config diff.h2alg.algorithm patience &&
	    sh script/test-citations.sh 2>&1)
	rc=$?
	(cd "$t/alg" && git config --unset core.attributesFile && git config --unset diff.h2alg.algorithm)
	if [ "$out" = "$alg" ]; then echo "  ok    and an attribute naming another algorithm changes no line"; else echo "  FAIL  an attribute naming another algorithm changes the output:"; printf '%s\n' "$alg" > "$t/alg-a.out"; printf '%s\n' "$out" > "$t/alg-b.out"; diff "$t/alg-a.out" "$t/alg-b.out" | sed 's/^/        /'; sf=1; fi
	exits 1
	out=$(cd "$t/alg" && git config diff.algorithm patience && sh script/test-citations.sh 2>&1)
	rc=$?
	(cd "$t/alg" && git config --unset diff.algorithm)
	if [ "$out" = "$alg" ]; then echo "  ok    nor does a configured algorithm"; else echo "  FAIL  a configured algorithm changes the output:"; printf '%s\n' "$alg" > "$t/alg-a.out"; printf '%s\n' "$out" > "$t/alg-b.out"; diff "$t/alg-a.out" "$t/alg-b.out" | sed 's/^/        /'; sf=1; fi
	exits 1
	out=$(cd "$t/alg" && git config diff.indentHeuristic false && sh script/test-citations.sh 2>&1)
	rc=$?
	(cd "$t/alg" && git config --unset diff.indentHeuristic)
	if [ "$out" = "$alg" ]; then echo "  ok    nor does the indent heuristic configured off"; else echo "  FAIL  the indent heuristic configured off changes the output:"; printf '%s\n' "$alg" > "$t/alg-a.out"; printf '%s\n' "$out" > "$t/alg-b.out"; diff "$t/alg-a.out" "$t/alg-b.out" | sed 's/^/        /'; sf=1; fi
	exits 1
	out=$(cd "$t/alg" && git config core.abbrev 4 && sh script/test-citations.sh 2>&1)
	rc=$?
	(cd "$t/alg" && git config --unset core.abbrev)
	if [ "$out" = "$alg" ]; then echo "  ok    nor does a configured hash length"; else echo "  FAIL  a configured hash length changes the output:"; printf '%s\n' "$alg" > "$t/alg-a.out"; printf '%s\n' "$out" > "$t/alg-b.out"; diff "$t/alg-a.out" "$t/alg-b.out" | sed 's/^/        /'; sf=1; fi
	exits 1
	out=$(cd "$t/edt" && sh script/test-citations.sh 2>&1)
	rc=$?
	expect 'note: re-read, the cited line was edited: doc/a.md:7: zz.c:5 rewritten in place since' 'a citation of a line rewritten in place is a note'
	expect 'rot read on 1 cited line(s), 0 of them dated past a later edit of their line, 0 moved or deleted since written, 1 rewritten in place' 'and is the one line the rot check read'
	expect 'citations: 3 row(s) read, 1 symbol-anchored pass(es), 1 literal-anchored, 1 unanchored note(s), 0 failure(s)' 'a row anchored on a literal and one on nothing pass, each counted as what it is'
	counted ' with one note'
	exits 0
	out=$(cd "$t/r" && H2CIT_FAIL=blame-L-empty PATH="$t/shim:$PATH" sh script/test-citations.sh 2>&1)
	rc=$?
	expect ' failed (0)' 'a blame of one line that answers nothing with status 0 fails the carry'
	counted ' with a blame of one line answering nothing'
	exits 1
	out=$(cd "$t/pure" && H2CIT_FAIL=blame-junk PATH="$t/shim:$PATH" sh script/test-citations.sh 2>&1)
	rc=$?
	expect 'the rot check dated no cited line (1 document(s) blamed)' 'a blame that answers and dates nothing dates nothing'
	counted ' with a blame that dates nothing'
	exits 2
	out=$(cd "$t/clean" && H2CIT_FAIL=blame-empty PATH="$t/shim:$PATH" sh script/test-citations.sh 2>&1)
	rc=$?
	expect 'the rot check dated no cited line' 'a blame that answers nothing dates nothing'
	counted ' with a blame that answers nothing'
	if [ "$rc" -eq 2 ]; then echo "  ok    and exits 2"; else echo "  FAIL  exit $rc, where 2"; sf=1; fi
	out=$(cd "$t/clean" && git config blame.ignoreRevsFile no-such-file && sh script/test-citations.sh 2>&1)
	rc=$?
	(cd "$t/clean" && git config --unset blame.ignoreRevsFile)
	expect 'blame.ignoreRevsFile names a file that does not exist' 'a configured ignored-revisions file that is missing is named'
	counted ' with the ignored-revisions file missing'
	if [ "$rc" -eq 2 ]; then echo "  ok    and exits 2"; else echo "  FAIL  exit $rc, where 2"; sf=1; fi
	out=$(cd "$t/shallow" && sh script/test-citations.sh 2>&1)
	rc=$?
	expect 'a shallow clone, so no citation can be dated' 'a shallow clone does not run the rot check'
	expect "note doc/history/u.md: ff.c:4 -- pinned at $one, which a shallow clone cannot read" 'and does not read a pinned row, which it says'
	expect '2 row(s) naming a function beside 2 cited line(s), 1 inside it, 1 pinned and not read' 'and counts'
	expect 'no commit read for a renumbered record: a shallow clone' 'and reads no commit for a renumbered record, which it says'
	counted ' in a shallow clone'
	if [ "$rc" -eq 2 ]; then echo "  ok    and exits 2"; else echo "  FAIL  shallow clone exit $rc, where 2"; sf=1; fi
	# core.bigFileThreshold is read only for a packed object, so its run
	# is on a clone, whose objects are packed, where r's are loose.
	for k in 'r:log.diffMerges=false:git show HEAD:script/test-citations.sh' \
	    'clean:core.bigFileThreshold=zz-bogus:git show HEAD:script/test-citations.sh' \
	    'r:core.maxTreeDepth=0:git log -1 -p -U0 HEAD -- script/test-citations.sh' \
	    'r:index.threads=zz-bogus:git diff -U0 HEAD -- script/test-citations.sh'; do
		c=${k%%:*}; k=${k#*:}; w=${k#*:}; k=${k%%:*}
		out=$(cd "$t/$c" && git config "${k%%=*}" "${k#*=}" && sh script/test-citations.sh 2>&1)
		rc=$?
		(cd "$t/$c" && git config --unset "${k%%=*}")
		expect "citations: COULD-NOT-RUN: $w exits 128 in this repository and its configuration, so no citation is read" "a configuration git cannot parse, $k, is no run"
		absent 'FAIL' 'and reads no citation'
		if [ "$rc" -eq 2 ]; then echo "  ok    and exits 2"; else echo "  FAIL  $k exit $rc, where 2"; sf=1; fi
	done
	out=$(cd "$t/clean" && git config blame.date zz-bogus && sh script/test-citations.sh 2>&1)
	rc=$?
	(cd "$t/clean" && git config --unset blame.date)
	expect 'git blame exits 128 in this repository and its configuration; the rot check did not run' 'a blame setting git cannot parse stops the rot check alone'
	absent 'git blame failed' 'and no blame is read as a citation failure'
	counted ' with a blame setting git cannot parse'
	if [ "$rc" -eq 2 ]; then echo "  ok    and exits 2"; else echo "  FAIL  blame.date=zz-bogus exit $rc, where 2"; sf=1; fi
	# Rows: the checks' status, FAIL lines printed, the last line, and
	# the status wanted; then, with selfstatus replaced by one giving 0
	# and by one giving no status, the status selfverdict must still
	# give. Each row's lines go to a file of their own, not to this
	# output.
	for k in '0 0 pass 0' '1 0 pass 1' '3 0 pass 1' '0 1 pass 1' \
	    '0 0 none 1' '0 0 FAIL 1' '2 0 none 2' '2 1 FAIL 1' \
	    '1 0 none 1' '1 3 FAIL 1' 'zero:0 1 pass 1' 'junk:0 0 pass 1'; do
		kf=; case "$k" in *:*) kf=${k%%:*}; k=${k#*:} ;; esac
		ks=${k%% *}; kr=${k#* }; kn=${kr%% *}; kr=${kr#* }
		kv=${kr%% *}; kw=${kr#* }
		i=0
		while [ "$i" -lt "$kn" ]; do echo "  FAIL  row"; i=$((i + 1)); done > "$t/printed"
		case "$kv" in
		pass) echo 'citations selftest: pass' >> "$t/printed" ;;
		FAIL) echo 'citations selftest: FAIL' >> "$t/printed" ;;
		esac
		case "$kf" in
		zero) kg=$(selfstatus() { echo 0; }; selfverdict "$t/printed" "$ks") ;;
		junk) kg=$(selfstatus() { echo; }; selfverdict "$t/printed" "$ks") ;;
		*) kg=$(selfverdict "$t/printed" "$ks") ;;
		esac
		if [ "$kg" = "$kw" ]; then
			echo "  ok    checks exiting $ks with $kn FAIL line(s) and [$kv] last give the selftest $kw${kf:+, selfstatus giving $kf}"
		else
			echo "  FAIL  checks exiting $ks with $kn FAIL line(s) and [$kv] last give the selftest [$kg], where $kw${kf:+, selfstatus giving $kf}"
			sf=1
		fi
	done
	# A name git blame refreshes inside the carry loop, in its own
	# repository so no other check's commit hashes move. The cited line
	# was written under a safe name, rewritten under an unsafe one, and
	# rewritten again after the rename back, so the document's own blame
	# names only safe paths and the loop's refresh is what reads the
	# unsafe one. Only the test after that refresh refuses it.
	git init -q "$t/unsafe"
	(
		cd "$t/unsafe" || exit 2
		mkdir -p src/sys/fs/hammer2 script doc
		printf 'a\nb\nc\nd\ne\n' > src/sys/fs/hammer2/zz.c
		printf '%s\n' '| site | what |' '|---|---|' '| `zz.c:1` | `a` |' '' \
		    'Pad.' 'Pad.' 'Was `zz.c:1` here, a line long enough for blame to follow it.' > doc/m.md
		cp "$me" script/test-citations.sh
		c() { git -c user.name=selftest -c user.email=selftest@localhost -c commit.gpgsign=false "$@"; }
		git add -A && c commit -qm one
		git mv doc/m.md 'doc/x;y.md' && c commit -qm two
		printf '%s\n' '| site | what |' '|---|---|' '| `zz.c:1` | `a` |' '' \
		    'Pad.' 'Pad.' 'Was reworded under the odd name, `zz.c:1`, a line long enough for blame.' > 'doc/x;y.md'
		c commit -qam three
		git mv 'doc/x;y.md' doc/n.md && c commit -qm four
		printf '%s\n' '| site | what |' '|---|---|' '| `zz.c:1` | `a` |' '' \
		    'Pad.' 'Pad.' 'Was reread after the rename, `zz.c:1`, a line long enough for blame.' > doc/n.md
		c commit -qam five
	)
	out=$(cd "$t/unsafe" && sh script/test-citations.sh 2>&1)
	expect '  FAIL prose doc/n.md:7: a path in its history (doc/x;y.md, doc/x;y.md) is not one the reader passes to git' 'a name git blame refreshes inside the carry loop is refused there, where the document own blame gave only safe ones'
	echo "citations selftest: $([ "$sf" -eq 0 ] && echo pass || echo FAIL)"
	exit "$sf"
	) > "$sto"
	src=$?
	cat "$sto"
	st=$(selfverdict "$sto" "$src")
	# A line saying why, where the checks' own last lines do not: this
	# prints only, and the status is st's.
	if [ "$st" = 1 ] && ! { [ "$src" -eq 1 ] && command grep -q '^  FAIL ' "$sto"; }; then
		echo "  FAIL  the checks exited $src, and their lines read as a failure"
		echo 'citations selftest: FAIL'
	fi
	rm -f "$sto"
	exit "$st"
fi
cd "$(dirname "$0")/.." || exit 2
# A setting git cannot parse stops each command that reads it with
# status 128 whatever is passed after it (git 2.56.0), so each kind of
# read the gate makes is tried once on this script first:
# log.diffMerges=false stops git show of a file, core.bigFileThreshold=zz
# the same read of a packed one and every diff (so the show where the
# script's newest copy is packed and the log where it is loose),
# core.maxTreeDepth=0 a diff between commits, index.threads=zz a diff
# of the working tree, and blame.date=zz git blame alone, which is read
# below. That is the instrument unable to run, as a missing
# blame.ignoreRevsFile is, and not a tree of wrong citations. A
# repository whose HEAD does not hold this script stops at the show as
# well: its history has no floor to read.
stops() {
	"$@" > /dev/null 2>&1
	[ $? -eq 128 ] || return 0
	echo "citations: COULD-NOT-RUN: $* exits 128 in this repository and its configuration, so no citation is read" >&2
	exit 2
}
stops git show HEAD:script/test-citations.sh
stops git log -1 -p -U0 HEAD -- script/test-citations.sh
stops git diff -U0 HEAD -- script/test-citations.sh

# The documents this gate reads, one per line, as git spells them. Every
# list comes from here, so one name has one spelling: a name read from
# the filesystem and a name read from git differ for a tab, a newline, a
# quote, a backslash and every byte above 127, which git quotes by
# default, and a name held in two spellings is refused twice.
#
# A name holding a space is refused whole below rather than read as the
# two documents its fragments spell, which would be the fragments read
# while the name itself was never opened. A newline is the one character
# a line-per-name list cannot carry: it splits a name into the fragments
# it spells, and where those are documents too the split reads them and
# never the name. So the stream is written once and its records are
# counted against the lines it makes, and a mismatch is a name holding a
# newline, or ending in one, in a run that says it cannot report rather
# than passing over the document.
#
# The pathspec is '*.md*' and not '*.md'. A pathspec asks a name to END
# with what it names, so '*.md' does not list a name that ends in a
# newline: such a name was gone before any count could see it, and the
# document behind it was read as nothing and reported as nothing. The
# wider pathspec lists it, so the record count sees it and the guard
# fires. Past the guard no name holds a newline, so each line of the
# listing is one name, and the documents are the lines ending in .md: a
# name the wider pathspec adds that does not end there is not one.
nl=$(mktemp) || exit 2
blame=$(mktemp) || exit 2
# One trap for both files. A second `trap ... EXIT` replaces the first
# rather than adding to it, so a trap set beside each mktemp left the
# first file behind on every run.
trap 'rm -f "$nl" "$blame"' EXIT
git ls-files -z '*.md*' > "$nl" || exit 2
nrec=$(tr -cd '\0' < "$nl" | wc -c | tr -d ' ')
nline=$(tr '\0' '\n' < "$nl" | wc -l | tr -d ' ')
if [ "$nline" -ne "$nrec" ]; then
	echo "citations: COULD-NOT-RUN: $nrec tracked name(s) list as $nline line(s), so a name holds a newline, at its end or inside it, and no name can be read whole" >&2
	exit 2
fi
allmd=$(tr '\0' '\n' < "$nl" | command grep -E '\.md$')
# The documents the table half reads: doc/*.md and doc/history/*.md, and
# no deeper.
tabledocs=$(printf '%s\n' "$allmd" | command grep -E '^doc/(history/)?[^/]+\.md$')
[ -n "$tabledocs" ] || { echo "citations: COULD-NOT-RUN: no doc/*.md" >&2; exit 2; }
# Every tracked .md outside the two directories not read as living
# documents. The table half's documents are a subset of these.
alldocs=$(printf '%s\n' "$allmd" | command grep -v -e '^doc/history/' -e '^doc/research/' -e '^doc/upstream/' -e '^CHANGELOG.md$')

fail=0
checked=0
unanchored=0
weakpass=0
rows=0

# A row whose first cell is `file:N` `symbol()`, the form a checker's
# candidate table takes, says the cited line is in that function, and no
# symbol need be on the line. The function is found as the BSD style lays
# it out: its name at column 0, any indented lines of arguments after it,
# an opening brace at column 0, to the next closing brace at column 0. So
# a prototype is not a definition, whether it carries its type on the
# same line or has the name at column 0, and neither is a macro invoked
# at column 0. Outside a region opened by `<!-- citations at HASH -->` the
# file is the tree's; inside one it is that commit's, so a table of what a
# run read stays held to the source it read and is not renumbered as the
# tree moves, which no hunk arithmetic gets right once the function has
# been rewritten around the candidate.
# What it cannot catch: a line that drifted and is still in its function;
# which of two definitions of one name a row means, since a line inside
# either passes; and a function whose closing brace is not at column 0,
# which is read on to the next one that is.
tworows=0
twolines=0
twook=0
twoskip=0
twohist=0
tworead=
shallow=0
[ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = false ] || shallow=1
# The file a row cites, as a path under this tree, or nothing. A row is a
# line of a document, so its path is as untrusted as the document: without
# this, a row citing a path that climbs out of the tree is read, and one
# whose number happens to land on something passes. A bare name is under
# the port's own directory; a path is taken as written unless it is
# absolute or holds a `..` component (`a/..b/c` is a name, not a
# component).
citepath() {
	case "$1" in
	"") return ;;
	/*) return ;;
	esac
	case "/$1/" in
	*/../*) return ;;
	esac
	case "$1" in
	*/*) printf '%s\n' "$1" ;;
	*) printf 'src/sys/fs/hammer2/%s\n' "$1" ;;
	esac
}

twocell() { # document, file:N, symbol, pin
	twolines=$((twolines + 1))
	tworead="$tworead
$1: $2"
	file=${2%%:*}
	n=${2#*:}
	path=$(citepath "$file")
	if [ -z "$path" ]; then
		echo "FAIL $1: $2 -- '$file' is not a path of this tree"
		fail=$((fail + 1))
		return
	fi
	if [ -n "$4" ]; then
		where=" at $4"
		if [ "$shallow" -eq 1 ]; then
			twoskip=$((twoskip + 1))
			echo "note $1: $2 -- pinned at $4, which a shallow clone cannot read"
			return
		fi
		if ! src=$(git show "$4:$path" 2>/dev/null); then
			echo "FAIL $1: $2 -- git show $4:$path failed, so the row is not read"
			fail=$((fail + 1))
			return
		fi
	else
		where=
		if [ ! -f "$path" ]; then
			echo "FAIL $1: $2 -- no such file ($path)"
			fail=$((fail + 1))
			return
		fi
		src=$(cat "$path")
	fi
	got=$(printf '%s\n' "$src" | awk -v s="$3" -v n="$n" '
		!f && index($0, s "(") == 1 { p = NR; next }
		!f && p && /^[ \t]/ { next }
		!f && p && /^[{]/ { st = p; f = 1; p = 0; next }
		!f { p = 0 }
		f && /^}/ { r = r " " st "-" NR; if (n + 0 >= st && n + 0 <= NR) ok = 1; f = 0 }
		END { if (r == "") print "none"; else print (ok ? "in" : "out") r }')
	case "$got" in
	in\ *) twook=$((twook + 1)) ;;
	out\ *)
		echo "FAIL $1: $2 -- line $n is outside $3(), which is ${file}:$(printf '%s' "${got#out }" | sed 's/ /, /g')$where"
		fail=$((fail + 1)) ;;
	*)
		echo "FAIL $1: $2 -- no definition of $3() at column 0 in $file$where"
		fail=$((fail + 1)) ;;
	esac
	case "$got$4:$1" in in\ *) ;; *:doc/history/*) [ -n "$4" ] || twohist=1 ;; esac
}

# The prose half below checks the region markers of the living documents
# and leaves the dated records out, so this loop checks theirs: a marker
# that names no commit, one opened inside another, an end with none open
# and a region left open at the end of the document all fail, since each
# would leave rows read at the wrong source and say nothing. A fenced
# block is not followed here, so a marker shown as an example in a dated
# record must not sit at the start of its line.
badmark() { echo "FAIL $1"; fail=$((fail + 1)); }
# Whether a document name may be read, and the one place that decides
# it. Returns 0 to read it, 1 to refuse it, or 2 to skip it as a
# document on the other half's list: the halves' lists overlap, and the
# table half runs first, so each name is refused once, by the half whose
# list it is on. `$2` is the indent its failure lines begin with, which
# is how the two halves' lines are counted apart; `$3` is the other
# half's list, empty for the table half. Every name comes from the one
# listing above, one per line, so a name holding a space is refused
# whole rather than read as its fragments.
readname() { # name, indent, the other half's list of names
	case "$1" in
	*[!A-Za-z0-9_./-]*) ;;
	*) return 0 ;;
	esac
	if printf '%s\n' "$3" | command grep -qxF -- "$1"; then
		return 2
	fi
	echo "$2 $1: a document name with a character outside [A-Za-z0-9_./-] is not read" >&2
	return 1
}
while IFS= read -r d; do
	# A document name is tested before anything is read from it or
	# asked of git about it. `done < "$d"` below quotes the name, so
	# the shell does not expand it; what an odd name costs is that every
	# command taking it as a word sees a different name, and a marker
	# check silently skipped.
	# The empty list: this half lists every name under doc/, so it is
	# the one that refuses them, and no name here is another half's.
	if ! readname "$d" "FAIL" ""; then
		fail=$((fail + 1))
		continue
	fi
	pin=
	open=0
	lno=0
	case "$d" in doc/history/*) rec=1 ;; *) rec=0 ;; esac
	while IFS= read -r line; do
		lno=$((lno + 1))
		case "$line" in
		'<!-- citations at '*' -->')
			[ "$rec" -eq 0 ] || [ "$open" -eq 0 ] || badmark "$d:$lno: a region opened inside the one open"
			pin=${line#'<!-- citations at '}; pin=${pin%' -->'}
			case "$pin" in *[!0-9a-f]*|"") pin= ;; esac
			open=1
			[ "$rec" -eq 1 ] || continue
			if [ -z "$pin" ]; then
				badmark "$d:$lno: not a region marker: $line"
			elif [ "$shallow" -eq 0 ] && ! git cat-file -e "$pin^{commit}" 2>/dev/null; then
				badmark "$d:$lno: region pinned to $pin, which is not a commit here"
			fi
			continue ;;
		'<!-- citations end -->')
			[ "$rec" -eq 0 ] || [ "$open" -eq 1 ] || badmark "$d:$lno: a region end with no region open"
			pin=; open=0; continue ;;
		'<!-- citations'*)
			[ "$rec" -eq 0 ] || badmark "$d:$lno: not a region marker: $line"
			continue ;;
		'|'*) ;;
		*) continue ;;
		esac
		# The first cell opens with `file:N` and names one `symbol()`;
		# further lines of the same function may sit beside them, each
		# a bare `:N` (a dereference and the check after it).
		two=$(printf '%s\n' "$line" | sed -n 's/^| *\(`[^`]*:[0-9][0-9]*`[^|]*\)|.*/\1/p')
		sym=
		[ -z "$two" ] || sym=$(printf '%s\n' "$two" | sed -n 's/.*`\([A-Za-z_][A-Za-z0-9_]*\)()`.*/\1/p')
		if [ -n "$sym" ]; then
			tworows=$((tworows + 1))
			cite=${two#?}; cite=${cite%%\`*}
			twocell "$d" "$cite" "$sym" "$pin"
			for n in $(printf '%s\n' "$two" | command grep -oE '`:[0-9]+`' | tr -d '`:'); do
				twocell "$d" "${cite%%:*}:$n" "$sym" "$pin"
			done
			continue
		fi
		cite=$(printf '%s\n' "$line" | sed -n 's/^| *`\([^`]*:[0-9][0-9,-]*\)` *|.*/\1/p')
		[ -n "$cite" ] || continue
		rows=$((rows + 1))
		file=${cite%%:*}
		spec=${cite#*:}
		path=$(citepath "$file")
		if [ -z "$path" ]; then
			echo "FAIL $d: $cite -- '$file' is not a path of this tree"
			fail=$((fail + 1))
			continue
		fi
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
	[ "$rec" -eq 0 ] || [ "$open" -eq 0 ] || badmark "$d:$lno: a region left open at the end of the document"
done <<EOF
$tabledocs
EOF
# The remedy for a dated record is not the one a living document takes,
# so it is said where the failure prints.
if [ "$twohist" -ne 0 ]; then
	echo "     doc/history is not renumbered when the tree moves: wrap the table in '<!-- citations at HASH -->' and '<!-- citations end -->', naming the commit its run read"
fi

# A population of zero would pass silently, which is the whole failure this
# gate is written against.
if [ "$rows" -eq 0 ]; then
	echo "citations: COULD-NOT-RUN: no file:line citation rows found in doc/*.md" >&2
	# A function row or a region marker already failed is a failure, not
	# an instrument that could not run.
	[ "$fail" -eq 0 ] || exit 1
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
# `$blame` is made with `$nl` above, and both are removed by the one trap
# there.
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
# A blame setting git cannot parse (blame.date=zz, say) stops git blame
# alone with status 128, whatever flag is passed: the rot check cannot
# run, and the rest is read.
if [ "$norot" -eq 0 ]; then
	git blame --no-textconv --ignore-revs-file= --porcelain -L 1,1 HEAD -- script/test-citations.sh > /dev/null 2>&1
	[ $? -ne 128 ] || norot=3
fi
# The history reads pin the settings of the reader's configuration that
# change what they print. An external diff tool or a textconv driver
# answers a diff with no hunks and status 0, and so does a file marked
# binary by an attribute: every citation would read as unmoved. An
# ignored revision list, a diff algorithm, the indent heuristic, which
# picks where among equal lines an insertion goes, or merged hunks would
# move the dating. With rename detection off, or a rename limit too
# small for the files a commit removes and adds, a dated record renamed
# and renumbered in one commit reads as one file removed and another
# added, whose lines are never paired; a limit of 0 is none. The
# renumber reader takes a file's name from its b/ prefix, which three
# settings change, and prints the floor and each commit it fails by a
# short hash whose length core.abbrev sets. An attribute can come from
# the reader's core.attributesFile or $GIT_DIR/info/attributes with
# nothing in the tree, and one can name a diff algorithm, which git
# diff and git log take over the configured one while git blame takes
# only the configured one. So the diffs pass
# --no-ext-diff, --no-textconv, --text and --diff-algorithm=myers, the
# blames and the pickaxe that finds the floor pass --no-textconv, and G
# pins the rest. A setting not named here is read as configured, a clean
# filter among them: one an attribute names changes the working tree's
# text before git diff reads it.
# A configured blame.ignoreRevsFile is cleared only by the blame flag
# --ignore-revs-file= (a -c with an empty value leaves it in force, git
# 2.56.0), so both blames pass that flag.
G="git -c diff.algorithm=myers -c diff.indentHeuristic=true -c diff.interHunkContext=0 -c diff.renames=true -c diff.renameLimit=0 -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.dstPrefix=b/ -c core.abbrev=auto"
prosefail=0
prosechecked=
while IFS= read -r d; do
	# A document name goes into git commands below, so one with a
	# character outside the plain set is refused rather than quoted.
	# The name is read a whole line at a time, since a word split reads
	# a name holding a space as the documents its fragments spell and
	# never opens the one it is.
	rn=0
	readname "$d" "  FAIL prose" "$tabledocs" || rn=$?
	if [ "$rn" -eq 1 ]; then
		prosefail=$((prosefail + 1))
		continue
	fi
	[ "$rn" -eq 0 ] || continue
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
	# The file a prose citation names, or nothing. A path is taken only
	# under src/sys/ and only with no parent component, since the reader
	# opens it: a citation written across `..` would read a file the
	# port does not hold and judge it as if it did.
	function srcpath(f) {
		if (f ~ /\//) {
			if (f !~ /^src\/sys\//) return ""
			if (("/" f "/") ~ /\/\.\.\//) return ""
			return (exists(f) ? f : "")
		}
		if (exists("src/sys/fs/hammer2/" f)) return "src/sys/fs/hammer2/" f
		if (exists("src/sys/sys/" f)) return "src/sys/sys/" f
		return ""
	}
	function lineof(p, n) { return lineat(at, p, n) }
	function safe(x) { return (x ~ /^[A-Za-z0-9_.\/:-]+$/) }
	# A read that fails is told apart from a file that is short: every
	# git command here ends its output with its own exit status.
	#
	# Its two names go into a shell command. The commit is a marker the
	# document sets and is read as hex before it gets here; the path is
	# the document own citation or one git blame refreshed, and age()
	# asks safe() of both before every read it makes, the first and
	# each the carry loop makes after a refresh.
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
	# The hunks of a git diff, cached by its arguments: hs, hc, hn, hd
	# are the old start, old count, new start and new count of each.
	function hunks(args,   cmd, l, n, rc, m, h, x) {
		if (args in nh) return nh[args] >= 0
		n = 0; rc = ""
		cmd = G " diff -U0 --no-color --no-ext-diff --no-textconv --text --diff-algorithm=myers " args " 2>/dev/null; echo @@h2cit-rc@@ $?"
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
	# correct citation. An old line cited alone matches any role. A bare
	# `:N` belongs to the file last named before it, on its line or on
	# the lines above it (cb, from ctxfile()), as the
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
		# Both names go into a shell command below, and both can be one
		# a document wrote: the path is the citation or the one git
		# blame refreshed from a rename. Asked here, before the first
		# read, since a check after it has already interpolated.
		if (!safe(path) || (pp != "" && !safe(pp))) {
			print "BAD " doc ":" NR ": a path in its history (" pp ", " path ") is not one the reader passes to git"
			return ""
		}
		# The line must have cited this file at its blame commit. A bare
		# `:N` whose file changed around it (a line naming another file
		# rewritten, or deleted, above an untouched line) cites the new
		# file from a commit no line records, so it is not dated and is
		# named instead; rewording its own line, once read, dates it.
		if (sha !~ /^0+$/ && !hasunit(lineat(sha, path, ol), b, n, role, ctxfile(sha, path, ol))) {
			print "UNDATED " doc ":" NR ": " cf ":" n " belongs to a file its line did not cite when written, so it is not dated; reword the line once it is read"
			return ""
		}
		# The selftest holds this bound from above only: a line reworded
		# in 200 commits fails, and nothing holds that 199 pass.
		for (steps = 0; steps < 200; steps++) {
			if (p == "") return (sha ~ /^0+$/) ? "" : sha
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
			# Fresh names: the blame above may have named a file the
			# document did not, so the test made at the loop entry is
			# made again on what it just read, before the next read
			# interpolates it.
			if (!safe(path) || (pp != "" && !safe(pp))) {
				print "BAD " doc ":" NR ": a path in its history (" pp ", " path ") is not one the reader passes to git"
				return ""
			}
			# The same test at each commit the carry reaches: a bare
			# `:N` reworded after its file changed above it cited
			# another file where its old line was written, so it dates
			# from q, the latest commit known to cite this unit, which
			# can only miss a move and never invent one.
			if (!hasunit(lineat(sha, path, ol), b, n, role, ctxfile(sha, path, ol))) return q
		}
		print "BAD " doc ":" NR ": " cf ":" n " carried through 200 or more edits"
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
		if (system("git cat-file -e " at "^{commit} 2>/dev/null") != 0) {
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
		echo "  FAIL prose $d: the prose reader stopped with status $s" >&2
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
done <<EOF
$alldocs
EOF

# The dated records are not renumbered. A line of doc/history that a commit
# changes in nothing but the digits of a citation fails: it is a dated
# observation rewritten to follow the tree, or a number corrected in place
# where a dated correction belongs. The digits are a number after `:` or
# after a .c or .h name closed by a backtick and a space, with the rest of
# its range (`-N`) or list (`, N`), so a count or a date written in that
# place is read as one and fails the same way. A removed line and an
# added one of the same hunk are paired when they differ in nothing else,
# wherever they sit in it, once the lines the hunk carries unchanged are
# set aside.
#
# What is read is every commit after the floor, and the working tree. The
# floor is the first commit to name the mark below in this file, the
# commit the check arrived in, and it is not read itself. A commit that
# changes the mark's value is the first to name the new one and so becomes
# the floor: that is the one way past a renumbering already published,
# whose line put back in a later commit is a second change in digits
# alone and fails beside the first. No gate fails a commit that moves
# the floor, and nothing in the tree holds it where it is: the mark,
# the selftest's copy of it, any record of the floor, this script,
# script/pre-push-check.sh and the CI workflow are all text the commit
# that moves it can change. The range read is printed on
# every run that reaches the summary, and a floor that moved is seen there
# or not at all. A guard outside the tree would hold it: this script as
# last published, read from the upstream branch and run against the tree
# being pushed, whose floor no new commit can move. It is not built,
# since it would run on one machine and not in CI, a push without hooks
# passes it, and each deliberate move of the floor fails it once and
# needs an override at the push.
# H2_RENUMBER_RANGE names another range and reads no working tree, for a
# census: its findings fail the run like any other.
#
# What it cannot catch: a renumbering in a commit that also rewords the
# line, one whose old and new lines git puts in different hunks, one made
# in a merge, whose diff git log does not print, one made in a commit
# that moves the record out of doc/history or renames it with too little
# left alike for git to follow, and a line cited in any other form.
#
# git runs a textconv driver by default in log, diff and blame, and the
# attribute naming one, marking a file binary or naming a diff algorithm
# can come from the reader's configuration with nothing in the tree; see
# the comment at G. The selftest runs with each configured. Two flags
# guard a default and nothing drives them: git show of a file runs no
# textconv driver, and git log runs no external diff tool, unless asked
# to (git 2.56.0), so the show read's --no-textconv and the log's
# --no-ext-diff are there against those defaults changing.
rmark=H2CIT-RENUMBER-FLOOR
rrange=${H2_RENUMBER_RANGE-}
rwt=0
rwhy=
case "$rrange" in
-*|*[!A-Za-z0-9_.^~/-]*)
	echo "citations: FAIL: H2_RENUMBER_RANGE is not a revision range: $rrange" >&2
	fail=$((fail + 1)); rrange=; rwhy='the range given is not one' ;;
"")
	if [ "$shallow" -eq 1 ]; then
		rwhy='a shallow clone'
	elif ! rfloor=$($G log --reverse --no-textconv --format=%h -S"$rmark" -- script/test-citations.sh 2>/dev/null); then
		echo "citations: FAIL: git log of script/test-citations.sh failed, so no commit is read for a renumbered record" >&2
		fail=$((fail + 1)); rwhy='git log failed'
	elif [ -n "$rfloor" ]; then
		rrange="$(printf '%s\n' "$rfloor" | head -1)..HEAD"; rwt=1
	elif git diff --quiet HEAD -- script/test-citations.sh 2>/dev/null; then
		# The mark is in a committed file and no commit introduced it.
		echo "citations: FAIL: no commit introduces $rmark, so the renumber check has no floor" >&2
		fail=$((fail + 1)); rwhy='no floor'
	else
		# The script differs from HEAD's and no commit names its
		# mark: a check not committed yet, or a mark changed in the
		# working tree. Either way no commit and no working tree is
		# read, and nothing fails; the summary says so.
		rwhy='this check is not committed yet'
	fi ;;
esac
if [ -n "$rrange" ]; then
	# shellcheck disable=SC2086
	if ! rlog=$($G log --reverse --no-color --no-ext-diff --no-textconv --text --diff-algorithm=myers --format='@@C %h' -U0 -p $rrange -- doc/history/ 2>/dev/null); then
		echo "citations: FAIL: git log of doc/history failed over $rrange, so no commit is read for a renumbered record" >&2
		fail=$((fail + 1)); rlog=
	fi
	if [ "$rwt" -eq 1 ]; then
		if rdiff=$($G diff --no-color --no-ext-diff --no-textconv --text --diff-algorithm=myers -U0 HEAD -- doc/history/ 2>/dev/null); then
			[ -z "$rdiff" ] || rlog="$rlog
@@C worktree
$rdiff"
		else
			echo "citations: FAIL: git diff of doc/history failed, so the working tree is not read for a renumbered record" >&2
			fail=$((fail + 1))
		fi
	fi
	rout=$(printf '%s\n' "$rlog" | awk '
		function norm(s) {
			gsub(/:[0-9]+((-|, )[0-9]+)*/, ":N", s)
			gsub(/\.c` [0-9]+((-|, )[0-9]+)*/, ".c` N", s)
			gsub(/\.h` [0-9]+((-|, )[0-9]+)*/, ".h` N", s)
			return s
		}
		function flush(   i, j) {
			# A line the hunk carries unchanged on both sides, as git
			# prints a frequent one that changed lines surround, pairs
			# with itself first: it is no renumbering, and a line of
			# the same words elsewhere in the hunk is not its old text.
			for (i = 1; i <= np; i++) {
				pu[i] = 0
				for (j = 1; j <= nm; j++) if (!mu[j] && m[j] == p[i]) { mu[j] = 1; pu[i] = 1; break }
			}
			for (j = 1; j <= nm; j++) mn[j] = norm(m[j])
			for (i = 1; i <= np; i++) {
				if (pu[i]) continue
				k = norm(p[i])
				for (j = 1; j <= nm; j++) if (!mu[j] && mn[j] == k) {
					mu[j] = 1
					print "FAIL " c ": " f " renumbered: " substr(p[i], 1, 100)
					if (!(c in cnt)) order[++nc] = c
					cnt[c]++; tot++
					break
				}
			}
			for (j = 1; j <= nm; j++) mu[j] = 0
			nm = np = 0
		}
		# Between a file header and its first hunk every line is the
		# header; after a hunk header every line is a removed or an
		# added one, or the note that a file ends without a newline.
		# A line that is none of these is one this reader does not
		# know, as every line is when git colors its output, and it
		# is counted: a diff not understood must not read as a diff
		# with nothing in it.
		/^@@C / { flush(); c = substr($0, 5); nread++; hdr = 0; next }
		/^diff --git / { flush(); hdr = 1; f = "a file of doc/history"; next }
		/^@@/ { flush(); hdr = 0; next }
		hdr && /^\+\+\+ b\// { f = substr($0, 7); next }
		hdr || /^$/ || /^\\/ { next }
		/^-/ { m[++nm] = substr($0, 2); next }
		/^\+/ { p[++np] = substr($0, 2); next }
		{ odd++ }
		END {
			flush()
			for (i = 1; i <= nc; i++) print "     renumbered in " order[i] ": " cnt[order[i]] " line(s)"
			print "TOTAL " tot + 0 " " nc + 0 " " nread + 0 " " odd + 0
		}')
	printf '%s\n' "$rout" | command grep -v '^TOTAL ' || true
	rtot=$(printf '%s\n' "$rout" | sed -n 's/^TOTAL \([0-9]*\) \([0-9]*\) \([0-9]*\) \([0-9]*\)$/\1/p')
	rodd=$(printf '%s\n' "$rout" | sed -n 's/^TOTAL \([0-9]*\) \([0-9]*\) \([0-9]*\) \([0-9]*\)$/\4/p')
	case "$rtot" in
	""|*[!0-9]*)
		echo "citations: FAIL: the renumber reader printed no total" >&2
		fail=$((fail + 1)); rtot=0 ;;
	*)
		if [ "$rodd" -ne 0 ]; then
			echo "citations: FAIL: $rodd line(s) of the history of doc/history are no diff line the renumber reader knows, so what it read is not what git printed" >&2
			fail=$((fail + 1))
		fi ;;
	esac
	if [ "$rtot" -ne 0 ]; then
		fail=$((fail + rtot))
		echo "     a dated record is not edited to follow the tree or to correct a number in place: put the line back, in the working tree or in its commit while that can still be amended, then pin its table or append a dated correction"
	fi
	rsum="$rtot line(s) of doc/history changed in citation digits alone, in $(printf '%s\n' "$rout" | sed -n 's/^TOTAL [0-9]* \([0-9]*\) \([0-9]*\) [0-9]*$/\1 of \2/p') change(s) to it read over $rrange$([ "$rwt" -eq 0 ] || echo ' and the working tree')"
else
	rsum="no commit read for a renumbered record: $rwhy"
fi

# Print what neither half reads beside what they do. An unmentioned citation
# sitting among checked ones inherits their credibility: one naming a kernel
# file or another port's tree, or one in a dated record. Measured 2026-08-26,
# before the prose half: 20 citation-shaped tokens in doc/, 15 of them in rows
# this gate reads. The floor below exists because a broken counting pattern
# also prints zero, which reads as "nothing uncovered" instead of "nothing
# asked".
allcites=$(command grep -roE '`[A-Za-z0-9_./-]+\.(c|h|sh|py|pl|md|txt|yaml):[0-9]+' doc/ 2>/dev/null | wc -l | tr -d ' ')
if [ "$allcites" -lt "$rows" ]; then
	echo "citations: FAIL: counted $allcites citation-shaped tokens in doc/ but" >&2
	echo "  read $rows table rows, so the counting pattern has stopped" >&2
	echo "  matching and the uncovered figure below would understate" >&2
	exit 1
fi
# The two-cell rows are counted a second way, by a looser shape, since a
# reading pattern that stopped matching would report none read and none
# wrong.
twoshape=$(printf '%s\n' "$tabledocs" | while IFS= read -r f; do cat -- "$f"; done | command grep -cE '^\| *`[^`|]+:[0-9][^`|]*`[^|]*\(\)`[^|]*\|' || true)
if [ "$twoshape" -ne "$tworows" ]; then
	echo "citations: FAIL: $twoshape row(s) shaped \`file:N\` \`symbol()\` and $tworows read" >&2
	fail=$((fail + 1))
fi
echo "citations: $rows row(s) read, $checked symbol-anchored pass(es), $weakpass literal-anchored, $unanchored unanchored note(s), $fail failure(s)"
echo "citations: $tworows row(s) naming a function beside $twolines cited line(s), $twook inside it, $twoskip pinned and not read"
echo "citations: $rsum"
# Name them, do not just count them. A bare number leaves the reader guessing
# which citations it means.
unchecked=$(command grep -roE '`[A-Za-z0-9_./-]+\.(c|h|sh|py|pl|md|txt|yaml):[0-9]+[0-9,-]*`' doc/ 2>/dev/null |
	sed 's/`//g' | while IFS=: read -r doc rest; do
		cited=$rest
		# A row is read only in a document the table half reads.
		printf '%s\n' "$tabledocs" | command grep -qxF -- "$doc" &&
		    command grep -qF -- "| \`$cited\` |" "$doc" && continue
		printf '%s\n' "$prosechecked" | command grep -qxF -- "$doc: $cited" && continue
		printf '%s\n' "$tworead" | command grep -qxF -- "$doc: $cited" && continue
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
	elif [ "$norot" -eq 2 ]; then
		echo "citations: COULD-NOT-RUN: blame.ignoreRevsFile names a file that does not exist, so git blame cannot run; the rot check did not run" >&2
	else
		echo "citations: COULD-NOT-RUN: git blame exits 128 in this repository and its configuration; the rot check did not run" >&2
	fi
	[ "$fail" -eq 0 ] && [ "$prosefail" -eq 0 ] || exit 1
	exit 2
fi
echo "citations: rot read on $((rotok + rotbad + rotedit)) cited line(s), $rotcarried of them dated past a later edit of their line, $rotbad moved or deleted since written, $rotedit rewritten in place, $rotskip whose file the dating commit lacks, $rotundated not dated and named above"
# Zero dated lines beside prose citations read means the history read
# came back empty while git itself answered, and every citation would
# pass the check unread. Said even when a failure above sets the exit.
norun=0
if [ $((rotok + rotbad + rotedit)) -eq 0 ]; then
	echo "citations: COULD-NOT-RUN: the rot check dated no cited line ($blamed document(s) blamed)" >&2
	norun=1
fi
[ "$fail" -eq 0 ] && [ "$prosefail" -eq 0 ] || exit 1
[ "$norun" -eq 0 ] || exit 2
exit 0
