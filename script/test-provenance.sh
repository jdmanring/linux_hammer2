#!/bin/sh
# Every file under src/ has a provenance row, and every row claiming a
# byte-for-byte carry is re-checked with cmp.
#
# 0.2's first exit criterion is that no file under src/sys/fs/hammer2/ is
# there without a recorded origin, commit and licence. That rule was prose in
# doc/README.roadmap.md until this gate existed, so it held as long as whoever
# added a file remembered it. A port's licence story is the first thing an
# upstream reviewer reads and the last thing anyone can reconstruct.
#
# What a green run is worth. Two of the four checks are about the table: no
# file without a row, no row without a file. Both sides come out of this tree,
# so neither can be wrong about it. The third has teeth. A row saying
# `identical` is a claim about another repository, and this re-runs cmp
# against that clone instead of trusting the word. With no clone on the
# machine the claim is reported unverified by name, never counted as passing.
# The fourth, numbered 4 below, checks a document carrying upstream text
# against the blob it pins.
#
# What it cannot do: `derived` and `ours` rows are unfalsifiable here, there
# being no mechanical test for "edited here". Their count is printed rather
# than checked, and a wrong origin on one is a review finding.
#
# Exit 2 is COULD-NOT-RUN: no CSV. Exit 1 is a count of findings.
set -u
cd "$(dirname "$0")/.." || exit 2

# --selftest drives the branches a green run never reaches. Every finding
# but the table's agreement with itself is invisible on a healthy tree, and a
# branch that has never executed is a comment, not a check.
if [ "${1:-}" = "--selftest" ]; then
	t=$(mktemp -d) || exit 2
	trap 'rm -rf "$t"' EXIT
	mkdir -p "$t/src" || exit 2
	echo x > "$t/src/listed.c"; echo y > "$t/src/unlisted.c"
	printf 'file,origin,origin_commit,license,carry,note\n' > "$t/p.csv"
	printf '%s/src/listed.c,,,BSD-3-Clause,ours,\n' "$t" >> "$t/p.csv"
	printf '%s/src/gone.c,,,BSD-3-Clause,ours,\n' "$t" >> "$t/p.csv"
	sfail=0
	out=$(H2_PROVENANCE_CSV="$t/p.csv" H2_SRC_DIR="$t/src" sh "$0" 2>&1); rc=$?
	for want in 'unlisted.c has no row' 'which is not in the tree'; do
		if printf '%s\n' "$out" | command grep -q "$want"; then
			echo "  ok    selftest: reports \"$want\""
		else
			echo "  FAIL  selftest: no \"$want\" in the output"; sfail=$((sfail + 1))
		fi
	done
	[ "$rc" = 1 ] && echo "  ok    selftest: exits 1 on findings" || {
		echo "  FAIL  selftest: exited $rc, wanted 1"; sfail=$((sfail + 1)); }

	# The cmp branch needs a carry and an origin clone to compare it
	# against, and the live table supplies neither reliably: a tree whose
	# every carry has been edited holds no `identical` row, which is a
	# true state of the table, and three checks built on the live table
	# went vacuous when it reached that state. The fixture is the
	# selftest's own, a one-file origin clone under the temp directory
	# committed by git, so the branch runs the same way on every machine
	# and in CI. The gate composes the clone path as clone/origin/file
	# with the row's file path, which is absolute here, so the clone
	# mirrors that path under itself.
	command -v git >/dev/null 2>&1 || {
		echo "selftest: COULD-NOT-RUN: no git to commit the origin clone"
		exit 2; }
	o="$t/clones/fakeorigin"
	mkdir -p "$o/${t#/}/tree/src" "$t/tree/src" || exit 2
	printf 'carried line\n' > "$o/${t#/}/tree/src/carry.c"
	cp "$o/${t#/}/tree/src/carry.c" "$t/tree/src/carry.c"
	git -C "$o" init -q && git -C "$o" add -A && \
		git -C "$o" -c user.name=selftest -c user.email=selftest@localhost \
			commit -q -m fixture || exit 2
	fc=$(git -C "$o" rev-parse HEAD) || exit 2
	printf 'file,origin,origin_commit,license,carry,note\n' > "$t/ok.csv"
	printf '%s/tree/src/carry.c,fakeorigin,%s,BSD-3-Clause,identical,\n' \
		"$t" "$fc" >> "$t/ok.csv"
	# The full mode also checks the document carry, so the cmp controls
	# run it over the selftest's own document, built here, rather than
	# over doc/DESIGN.md, whose state is no business of theirs.
	printf 'line one\n\tline two\n' > "$t/up.txt"
	ub=$(git hash-object "$t/up.txt") || exit 2
	printf '# T\n\nCommit 0123456789abcdef0123456789abcdef01234567 counted those 9 blocks, their 9 lines.\n`script/test-provenance.sh` reassembles those 2 blocks and checks their 2 lines against git blob `%s`, i.e. the pin.\n\nA note on the opener: ```upstream is the opener.\n\n```upstream\nline one\n```\n\n```inline``` and\n\n```c\nint x;\n```\n\n```upstream\n\tline two\n```\n' "$ub" > "$t/carry.md"
	run() { H2_PROVENANCE_CSV="$1" H2_SRC_DIR="$t/tree/src" \
		H2_CLONE_DIR="$2" H2_DOC_CARRIES="$t/carry.md $ub 2 2" sh "$0" 2>&1; }

	# The positive control comes first. The three refusals below must
	# come from the branch under test, and a fixture whose clone path
	# never resolved would produce the first of them for a reason that
	# is not the one being checked.
	out=$(run "$t/ok.csv" "$t/clones"); rc=$?
	if [ "$rc" = 0 ] && printf '%s\n' "$out" | command grep -q 'identical to fakeorigin'; then
		echo "  ok    selftest: a true identical claim is re-verified by cmp"
	else
		echo "  FAIL  selftest: the fixture's carry exited $rc, not re-verified"
		sfail=$((sfail + 1))
	fi

	# A clone directory that does not exist must be COULD-NOT-RUN, and
	# by the no-clone line rather than any other way to exit 2.
	out=$(run "$t/ok.csv" /nonexistent); rc=$?
	if [ "$rc" = 2 ] && printf '%s\n' "$out" | command grep -q 'no fakeorigin clone at /nonexistent'; then
		echo "  ok    selftest: COULD-NOT-RUN with no clone present"
	else
		echo "  FAIL  selftest: exited $rc with no clone, wanted 2 by the no-clone line"
		sfail=$((sfail + 1))
	fi

	# A clone at the wrong commit is the likelier way the cmp half stops
	# meaning anything, the clone being a working tree somebody pulls. It
	# must read UNVER, never FAIL: a carry compared against a commit the
	# row does not name answers a question nobody asked.
	sed "s/,$fc,/,0000000deadbeef0000000000000000000000000,/" "$t/ok.csv" > "$t/wrongc.csv"
	out=$(run "$t/wrongc.csv" "$t/clones"); rc=$?
	if [ "$rc" = 2 ] && printf '%s\n' "$out" | command grep -q 'not the 0000000... this row names'; then
		echo "  ok    selftest: a clone at the wrong commit reads UNVER"
	else
		echo "  FAIL  selftest: a wrong-commit clone was treated as a carry"
		sfail=$((sfail + 1))
	fi

	# A row claiming a carry over a file that is not that carry must be a
	# finding, and the run must fail on it.
	printf 'edited here\n' > "$t/tree/src/carry.c"
	out=$(run "$t/ok.csv" "$t/clones"); rc=$?
	if [ "$rc" = 1 ] && printf '%s\n' "$out" | command grep -q 'says identical but differs'; then
		echo "  ok    selftest: cmp catches a wrong identical claim"
	else
		echo "  FAIL  selftest: a wrong identical claim passed cmp"
		sfail=$((sfail + 1))
	fi
	# The document carry: a fixture whose two upstream blocks reassemble
	# to the blob it pins must pass, the same with one line edited must
	# fail, and a document with no upstream block must fail on the count
	# before any hash is compared.
	dc() { H2_DOC_CARRIES="$1 $ub 2 ${2:-2}" sh "$0" --doc-carries 2>&1; }
	out=$(dc "$t/carry.md"); rc=$?
	if [ "$rc" = 0 ] && printf '%s\n' "$out" | command grep -q 'reassemble to'; then
		echo "  ok    selftest: a document's upstream blocks reassemble to their pin"
	else
		echo "  FAIL  selftest: a true document carry exited $rc"; sfail=$((sfail + 1))
	fi
	sed 's/^line one$/line 1/' "$t/carry.md" > "$t/edited.md"
	out=$(dc "$t/edited.md"); rc=$?
	if [ "$rc" = 1 ] && printf '%s\n' "$out" | command grep -q 'not the blob'; then
		echo "  ok    selftest: one edited upstream line fails the document carry"
	else
		echo "  FAIL  selftest: an edited document carry exited $rc"; sfail=$((sfail + 1))
	fi
	# The full mode reads the document carry too: with the cmp fixture
	# true again, an edited carry must fail the whole gate.
	cp "$o/${t#/}/tree/src/carry.c" "$t/tree/src/carry.c"
	out=$(H2_PROVENANCE_CSV="$t/ok.csv" H2_SRC_DIR="$t/tree/src" H2_CLONE_DIR="$t/clones" \
		H2_DOC_CARRIES="$t/edited.md $ub 2 2" sh "$0" 2>&1); rc=$?
	if [ "$rc" = 1 ] && printf '%s\n' "$out" | command grep -q 'not the blob'; then
		echo "  ok    selftest: the full mode fails on an edited document carry"
	else
		echo "  FAIL  selftest: the full mode over an edited document carry exited $rc"; sfail=$((sfail + 1))
	fi
	printf '# T\n\ngit blob `%s`, those 2 blocks, their 2 lines\n\nno blocks\n' "$ub" > "$t/empty.md"
	out=$(dc "$t/empty.md"); rc=$?
	if [ "$rc" = 1 ] && printf '%s\n' "$out" | command grep -q 'upstream block(s), the pin says 2'; then
		echo "  ok    selftest: a document with no upstream block fails on its count"
	else
		echo "  FAIL  selftest: a document with no upstream block exited $rc"; sfail=$((sfail + 1))
	fi
	# Each control drives one check: a note fenced inside a block, the
	# line count kept, moves the block count; a final block left open
	# fails the open-or-nested check; a blockquoted opener, and a fence
	# tagged with a character reference, fail the fence check; a
	# document not naming this script, or naming it twice, fails the
	# name count; a wrong blob or a count in words inside the sentence
	# the pin builds fails the sentence check; a stray pin token fails
	# the pin's parse.  The fixture's commit hash, its past count in
	# another sentence, the abbreviation after the sentence, the opener
	# named mid-line, the inline fence span and the c block are
	# legitimate and must not fail the true document, which the first
	# control above reads.
	awk '$0 == "line one" { print; print "```"; print "port prose"; print "```upstream"; next } { print }' "$t/carry.md" > "$t/fenced.md"
	out=$(dc "$t/fenced.md"); rc=$?
	if [ "$rc" = 1 ] && printf '%s\n' "$out" | command grep -q '3 upstream block(s), the pin says 2'; then
		echo "  ok    selftest: a fence pair planted inside a block fails on the block count"
	else
		echo "  FAIL  selftest: a planted fence pair exited $rc"; sfail=$((sfail + 1))
	fi
	sed '$d' "$t/carry.md" > "$t/open.md"
	out=$(dc "$t/open.md"); rc=$?
	if [ "$rc" = 1 ] && printf '%s\n' "$out" | command grep -q 'left open or nested'; then
		echo "  ok    selftest: a block left open fails"
	else
		echo "  FAIL  selftest: a block left open exited $rc"; sfail=$((sfail + 1))
	fi
	command grep -v 'test-provenance.sh. reassembles' "$t/carry.md" > "$t/unnamed.md"
	out=$(dc "$t/unnamed.md"); rc=$?
	if [ "$rc" = 1 ] && printf '%s\n' "$out" | command grep -q 'names script/test-provenance.sh 0 time'; then
		echo "  ok    selftest: a document not naming the gate fails"
	else
		echo "  FAIL  selftest: a document not naming the gate exited $rc"; sfail=$((sfail + 1))
	fi
	cp "$t/carry.md" "$t/look.md"
	printf 'note\n> ```upstream\n> port prose\n> ```\n' >> "$t/look.md"
	out=$(dc "$t/look.md"); rc=$?
	if [ "$rc" = 1 ] && printf '%s\n' "$out" | command grep -q 'fence tagged upstream other than'; then
		echo "  ok    selftest: a lookalike fence opener fails"
	else
		echo "  FAIL  selftest: a lookalike fence opener exited $rc"; sfail=$((sfail + 1))
	fi
	sed 's/ reassembles / reassembles git blob `0000000000000000000000000000000000000000`, /' "$t/carry.md" > "$t/late.md"
	out=$(dc "$t/late.md"); rc=$?
	if [ "$rc" = 1 ] && printf '%s\n' "$out" | command grep -q 'does not carry before its first block'; then
		echo "  ok    selftest: a wrong blob in the gate's sentence fails"
	else
		echo "  FAIL  selftest: a wrong second blob exited $rc"; sfail=$((sfail + 1))
	fi
	sed 's/ reassembles those 2 blocks / reassembles those two blocks /' "$t/carry.md" > "$t/words.md"
	out=$(dc "$t/words.md"); rc=$?
	if [ "$rc" = 1 ] && printf '%s\n' "$out" | command grep -q 'does not carry before its first block'; then
		echo "  ok    selftest: a count given in words in the sentence naming the gate fails"
	else
		echo "  FAIL  selftest: a count given in words exited $rc"; sfail=$((sfail + 1))
	fi
	sed '3s/$/ See script\/test-provenance.sh./' "$t/carry.md" > "$t/twice.md"
	out=$(dc "$t/twice.md"); rc=$?
	if [ "$rc" = 1 ] && printf '%s\n' "$out" | command grep -q 'names script/test-provenance.sh 2 time'; then
		echo "  ok    selftest: a document naming the gate twice before its first block fails"
	else
		echo "  FAIL  selftest: a document naming the gate twice exited $rc"; sfail=$((sfail + 1))
	fi
	cp "$t/carry.md" "$t/entity.md"
	printf '```&#117;pstream\nport prose\n```\n' >> "$t/entity.md"
	out=$(dc "$t/entity.md"); rc=$?
	if [ "$rc" = 1 ] && printf '%s\n' "$out" | command grep -q 'not a plain word'; then
		echo "  ok    selftest: a fence tagged with a character reference fails"
	else
		echo "  FAIL  selftest: a fence tagged with a character reference exited $rc"; sfail=$((sfail + 1))
	fi
	sed 's/checks their 2 lines/checks their 3 lines/' "$t/carry.md" > "$t/lines3.md"
	out=$(H2_DOC_CARRIES="$t/lines3.md $ub 3 2" sh "$0" --doc-carries 2>&1); rc=$?
	if [ "$rc" = 1 ] && printf '%s\n' "$out" | command grep -q 'upstream line(s), the pin says 3'; then
		echo "  ok    selftest: a pin naming another line count fails on the population"
	else
		echo "  FAIL  selftest: a pin naming another line count exited $rc"; sfail=$((sfail + 1))
	fi
	out=$(dc "$t/absent.md"); rc=$?
	if [ "$rc" = 1 ] && printf '%s\n' "$out" | command grep -q 'is not in the tree'; then
		echo "  ok    selftest: a pinned document missing from the tree fails"
	else
		echo "  FAIL  selftest: a missing pinned document exited $rc"; sfail=$((sfail + 1))
	fi
	out=$(H2_DOC_CARRIES="" sh "$0" --doc-carries 2>&1); rc=$?
	if [ "$rc" = 1 ] && printf '%s\n' "$out" | command grep -q 'no document carry was checked'; then
		echo "  ok    selftest: an empty pin checks nothing and fails"
	else
		echo "  FAIL  selftest: an empty pin exited $rc"; sfail=$((sfail + 1))
	fi
	out=$(H2_DOC_CARRIES="$t/carry.md $ub 2 2 extra" sh "$0" --doc-carries 2>&1); rc=$?
	if [ "$rc" = 1 ] && printf '%s\n' "$out" | command grep -q 'stray token'; then
		echo "  ok    selftest: a stray pin token fails"
	else
		echo "  FAIL  selftest: a stray pin token exited $rc"; sfail=$((sfail + 1))
	fi
	echo "selftest: 23 check(s), $sfail failed"
	[ "$sfail" = 0 ] || exit 1
	exit 0
fi

# 4. A document carrying upstream text verbatim. doc/DESIGN.md holds
#    DragonFly's DESIGN in fenced blocks opened by a line reading exactly
#    ```upstream, with the port's notes between them. The pin is four
#    tokens: the document, upstream's blob, its line count and the number
#    of blocks. The blocks' lines, in order, must be upstream's file byte
#    for byte: the block count is checked first, so a fence pair planted
#    inside a block, which would show a port line as upstream's with the
#    line count kept, fails, as does a block left open or a block opened
#    inside another; then the line count, so a document whose blocks went
#    missing fails on the population rather than on a hash nobody can read;
#    then git's blob hash of the reassembly against the pin. Before the
#    first block the document must name this script once and carry the
#    sentence the pin builds, "`script/test-provenance.sh` reassembles
#    those <n> blocks and checks their <n> lines against git blob
#    `<hex>`", so its account of the check cannot go stale apart from it. No clone is needed, the pin
#    being the blob itself. The pin moves only when the carried text is
#    deliberately updated from upstream.
DOC_CARRIES=${H2_DOC_CARRIES-doc/DESIGN.md 5570027ee6f50edaa6da82c56b4cf54e920a6fc6 999 35}
doc_carries() {
	dfail=0 dran=0
	command -v git >/dev/null 2>&1 || {
		echo "  UNVER document carries: no git to hash the reassembly"; return 2; }
	set -- $DOC_CARRIES
	while [ $# -ge 4 ]; do
		d=$1 blob=$2 want=$3 wblk=$4; shift 4
		dran=$((dran + 1))
		if [ ! -f "$d" ]; then
			echo "  FAIL  $d carries upstream text and is not in the tree"
			dfail=$((dfail + 1)); continue
		fi
		set -- $(awk '$0 == "```upstream" { if (f) bad = 1; f = 1; n++; next } f && $0 == "```" { f = 0; next } END { print n + 0, f + bad }' "$d") "$@"
		nblk=$1 open=$2; shift 2
		if [ "$open" != 0 ]; then
			echo "  FAIL  $d has an upstream block left open or nested in another"
			dfail=$((dfail + 1)); continue
		fi
		if [ "$nblk" != "$wblk" ]; then
			echo "  FAIL  $d holds $nblk upstream block(s), the pin says $wblk"
			dfail=$((dfail + 1)); continue
		fi
		# A Markdown fence opens a line once blockquote markers, list
		# markers and indentation are set aside.  One tagged upstream
		# anywhere but the exact opener line (a trailing space, four
		# backticks, tildes, a container prefix, any case) would show a
		# block attributed to upstream that none of the checks here
		# reads, and so would a tag a renderer decodes to upstream (a
		# character reference), so a tag must be a plain word.  A fence
		# with another plain tag or none is the port's.  A backtick run
		# whose rest holds a backtick is an inline span, not a fence.
		# Raw HTML is not read.
		if ! awk '{
			s = $0
			while (sub(/^([ \t>]|[-*+][ \t]|[0-9]+[.)][ \t])/, "", s)) ;
			if (s !~ /^(```|~~~)/ || $0 == "```upstream") next
			if (substr(s, 1, 1) == "`") { sub(/^`+/, "", s); if (index(s, "`")) next }
			else sub(/^~+/, "", s)
			sub(/^[ \t]+/, "", s); split(s, w, /[ \t]/); t = tolower(w[1])
			if (t != "" && (t == "upstream" || t !~ /^[a-z0-9_+.-]+$/)) bad = 1
		} END { exit bad }' "$d"; then
			echo "  FAIL  $d has a fence tagged upstream other than the exact opener line, or a tag that is not a plain word"
			dfail=$((dfail + 1)); continue
		fi
		# The document's own account: before the first block, with line
		# breaks and runs of blanks read as one space, it names this
		# script once and carries one sentence built from the pin,
		# "`script/test-provenance.sh` reassembles those <n> blocks and
		# checks their <n> lines against git blob `<hex>`".  No prose is
		# parsed: what else the head says, a past count say, is review's.
		head=$(awk '$0 == "```upstream" { exit } { print }' "$d" | tr '\n\t' '  ' | tr -s ' ')
		acct="\`script/test-provenance.sh\` reassembles those $wblk blocks and checks their $want lines against git blob \`$blob\`"
		nname=$(printf '%s\n' "$head" | awk -v k="script/test-provenance.sh" '{ s = $0; while ((i = index(s, k)) > 0) { n++; s = substr(s, i + length(k)) } } END { print n + 0 }')
		if [ "$nname" != 1 ]; then
			echo "  FAIL  $d names script/test-provenance.sh $nname time(s) before its first block, not once"
			dfail=$((dfail + 1)); continue
		fi
		case $head in *"$acct"*) ;; *)
			echo "  FAIL  $d does not carry before its first block the sentence: $acct"
			dfail=$((dfail + 1)); continue ;;
		esac
		body=$(awk '$0 == "```upstream" { f = 1; next } f && $0 == "```" { f = 0; next } f { print }' "$d"; echo x)
		body=${body%x}
		n=$(printf '%s' "$body" | wc -l | tr -d ' ')
		if [ "$n" != "$want" ]; then
			echo "  FAIL  $d holds $n upstream line(s), the pin says $want"
			dfail=$((dfail + 1)); continue
		fi
		got=$(printf '%s' "$body" | git hash-object --stdin)
		if [ "$got" = "$blob" ]; then
			echo "  ok    $d's $n upstream line(s) reassemble to $blob"
		else
			echo "  FAIL  $d's upstream blocks reassemble to $got, not the blob $blob"
			dfail=$((dfail + 1))
		fi
	done
	if [ $# -gt 0 ]; then
		echo "  FAIL  the document pin has $# stray token(s): $*"
		dran=$((dran + 1)); dfail=$((dfail + 1))
	fi
	return 0
}
if [ "${1:-}" = "--doc-carries" ]; then
	doc_carries; r=$?
	[ "$r" = 2 ] && exit 2
	[ "$dran" -gt 0 ] || { echo "  FAIL  no document carry was checked"; exit 1; }
	[ "$dfail" = 0 ] || exit 1
	exit 0
fi

CSV=${H2_PROVENANCE_CSV-doc/provenance.csv}
SRC=${H2_SRC_DIR-src}
CLONES=${H2_CLONE_DIR-$HOME/Projects}

[ -f "$CSV" ] || { echo "provenance: COULD-NOT-RUN: no $CSV"; exit 2; }
[ -d "$SRC" ] || { echo "provenance: COULD-NOT-RUN: no $SRC directory"; exit 2; }

# Assert both populations before comparing anything. Either one empty makes
# every loop below vacuous, and a vacuous run prints zero findings, which is
# indistinguishable from a clean tree.
# Build artifacts are not source. kbuild writes .o, .ko, .mod, .mod.c, .cmd,
# .o.d, modules.order and Module.symvers beside the sources it compiles, and
# this gate had never seen a built tree until the first `make` on 2026-09-02.
# Against one it read those files as though they were the port's own. The
# patterns match .gitignore's, and .mod.c is listed separately because it
# ends in .c and so enters a *.c glob. .o.d was left out of both lists until
# 2026-09-26, and a bare `make` below the kernel floor writes one before the
# version #error stops the compile, so a failed build left a file that made
# test-provenance.sh fail on the next run.
files=$(find "$SRC" -type f \
	! -name '*.o' ! -name '*.ko' ! -name '*.mod' ! -name '*.mod.c' \
	! -name '*.cmd' ! -name '*.o.d' ! -name '*.order' \
	! -name '*.symvers' \
	! -path '*/.tmp_versions/*' | LC_ALL=C sort)
rows=$(command grep -v '^#' "$CSV" | command grep -v '^file,origin,' | command grep -v '^[[:space:]]*$')
[ -n "$files" ] || { echo "provenance: FAIL: no files under $SRC at all" >&2; exit 1; }
[ -n "$rows" ] || { echo "provenance: FAIL: $CSV has no rows at all" >&2; exit 1; }

fail=0 ran=0 nident=0 nunver=0 nother=0

echo "provenance: $(printf '%s\n' "$files" | wc -l | tr -d ' ') file(s) under $SRC, $(printf '%s\n' "$rows" | wc -l | tr -d ' ') row(s) in $CSV"

# 1. No file without a row.
for f in $files; do
	ran=$((ran + 1))
	printf '%s\n' "$rows" | command grep -q "^$f," || {
		echo "  FAIL  $f has no row in $CSV"
		fail=$((fail + 1))
	}
done

# 2. No row without a file. A row for a deleted file is how a licence
#    table starts describing a tree that no longer exists.
# The loop runs in a subshell because of the pipe, so its counters would
# not survive it; the findings go to a file and are counted here. `grep
# -c` prints 0 and exits 1 on no match, so its status is discarded on purpose
# instead of ending the script under set -e or feeding a second value into the
# arithmetic below.
orphans="${TMPDIR:-/tmp}/h2prov.$$"
printf '%s\n' "$rows" | while IFS= read -r r; do
	rf=${r%%,*}
	[ -f "$rf" ] || echo "  FAIL  $CSV names $rf, which is not in the tree"
done > "$orphans"
cat "$orphans"
norph=$(command grep -c . "$orphans" 2>/dev/null) || :
norph=${norph:-0}
rm -f "$orphans"
fail=$((fail + norph))
ran=$((ran + norph))

# The vocabulary of the carry column, checked before it is read. A row
# whose fifth field is anything else is silently NOT an `identical` row:
# the loop below skips it, the cmp never runs, and the summary counts it
# among the rows that are unfalsifiable here. Writing `carry` where the
# format says `identical` is the obvious way to do that by hand, and it
# happened on 2026-08-26 when hammer2_cluster.c was added. The reassuring
# direction, since the gate stays green and the strongest check it has is
# what got turned off.
badvocab=$(printf '%s\n' "$rows" | awk -F, '$5 != "identical" && $5 != "derived" && $5 != "ours" { print $1 " -> " $5 }')
if [ -n "$badvocab" ]; then
	printf '%s\n' "$badvocab" | sed 's/^/  FAIL  carry column is not identical, derived or ours: /'
	nvocab=$(printf '%s\n' "$badvocab" | command grep -c .) || nvocab=1
	fail=$((fail + nvocab)); ran=$((ran + nvocab))
else
	ran=$((ran + 1))
	echo "  ok    every row's carry column is one of identical, derived, ours"
fi

# 3. The claim with teeth: `identical` is re-run, not read.
identlog="${TMPDIR:-/tmp}/h2ident.$$"
printf '%s\n' "$rows" | while IFS=, read -r rf origin commit lic carry rest; do
	[ "$carry" = identical ] || continue
	u="$CLONES/$origin/$rf"
	if [ ! -f "$u" ]; then
		echo "  UNVER $rf: no $origin clone at $CLONES, so identical is unverified"
		continue
	fi
	# Check the clone's commit, do not assume it. cmp against a working
	# tree at an unknown commit answers a different question confidently:
	# one `git pull` in the clone and this either goes red for a reason
	# that is not this repository's, or stays green having compared
	# against a commit the CSV does not name. Neither is a finding about
	# the carry, so a mismatch is UNVER and never FAIL.
	if [ -n "$commit" ] && command -v git >/dev/null 2>&1; then
		at=$(git -C "$CLONES/$origin" rev-parse HEAD 2>/dev/null) || at=""
		if [ -n "$at" ] && [ "$at" != "$commit" ]; then
			echo "  UNVER $rf: the $origin clone is at ${at%"${at#???????}"}..., not the ${commit%"${commit#???????}"}... this row names"
			continue
		fi
	fi
	if cmp -s "$rf" "$u"; then
		echo "  ok    $rf identical to $origin"
	else
		echo "  FAIL  $rf says identical but differs from $CLONES/$origin"
	fi
done > "$identlog"
cat "$identlog"
nident=$(command grep -c '^  ok ' "$identlog" 2>/dev/null) || :; nident=${nident:-0}
nunver=$(command grep -c '^  UNVER' "$identlog" 2>/dev/null) || :; nunver=${nunver:-0}
nbad=$(command grep -c '^  FAIL' "$identlog" 2>/dev/null) || :; nbad=${nbad:-0}
rm -f "$identlog"
fail=$((fail + nbad))
ran=$((ran + nident + nunver + nbad))

nother=$(printf '%s\n' "$rows" | awk -F, '$5 != "identical"' | command grep -c . 2>/dev/null) || :; nother=${nother:-0}

doc_carries; dr=$?
if [ "$dr" = 2 ]; then
	nunver=$((nunver + 1))
else
	[ "$dran" -gt 0 ] || { echo "  FAIL  no document carry was checked"; dfail=1; }
	fail=$((fail + dfail)); ran=$((ran + dran))
fi

# Name the unchecked claims in the summary. A count of findings alone reads
# as a count of the population.
echo "provenance: $ran check(s), $fail finding(s); $nident carry(s) re-verified by cmp, $(( dran > dfail ? dran - dfail : 0 )) document carry(s) re-verified by hash, $nunver unverified, $nother row(s) derived or ours and unfalsifiable here"
[ "$fail" = 0 ] || exit 1

# A run that verified no carry is not a pass. The two table checks read both
# sides out of this tree, so they hold with or without an origin clone; only
# cmp asks something this repository cannot answer alone. With every clone
# missing, all that survives is that the table agrees with itself, and calling
# that green would make the gate strongest on the machine that checked least,
# which is CI.
if [ "$nident" = 0 ] && [ "$nunver" != 0 ]; then
	echo "provenance: COULD-NOT-RUN: no origin clone under $CLONES at the"
	echo "            commit its row names, so no carry was re-verified and"
	echo "            only the table was checked. The lines above say which"
	echo "            of the two it was, per row."
	exit 2
fi
