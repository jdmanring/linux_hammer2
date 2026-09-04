#!/bin/sh
# A DOCUMENT THAT SAYS A SYMBOL IS NOT CARRIED IS MAKING A CHECKABLE CLAIM.
# This gate resolves every one of them against src/ and fails when the symbol
# is there.
#
# Why it exists. Between 2026-09-02 and 2026-09-03 thirteen sentences in this
# tree asserted a state the code had moved past: recovery was not carried
# after it was, the module did not link after it did, a deferral argued its
# own gap was unreachable because every mount failed after mounts began
# succeeding, and two of them told a user in dmesg that flush recovery is not
# implemented. Ten gates were green through all of it, because no gate reads
# prose for truth. Most of that class is not mechanically checkable. This
# subset is: the claims name a symbol, and whether a symbol is defined under
# src/ is a fact.
#
# A SECOND CLAIM SHAPE, added 2026-09-04. On that day the README's opening
# paragraph said the port does not mount anything, four days after it began
# mounting, and three documents said `->iterate_shared` is not written after
# it was. The same sweep found `->reconfigure` described as not written while
# it is wired into hammer2_fs_context_ops and deliberately returns -EROFS.
# A claim of the form "->method is not written" names a member of an
# operations table, and whether that member is initialized under src/ is as
# much a fact as whether a symbol is defined. Both halves of this gate exist
# because the same defect recurred and no instrument could see it.
#
# The vocabulary matters and is the tree's own. "Carried" means imported from
# a BSD tree substantially unchanged; a function this port rewrote is
# "rewritten", which the origin table in doc/README.status.md distinguishes
# by file. So a symbol that IS defined here has not been "not carried",
# whatever else is true of it, and saying so reads to anyone outside this
# repository as saying the code is absent.
#
# Population. doc/README*.md, doc/ARCHITECTURE.md, doc/IO_MODEL.md and the
# module sources. CHANGELOG.md is excluded ON PURPOSE: it is a dated
# append-only record, so its rows are claims about the day they were written
# and cannot go stale. doc/research/ and doc/upstream/ are excluded for the
# same reason, being imported deliverables and filing drafts against other
# trees, where "not carried" is a statement about that tree and not this one.
set -u

# --selftest builds a tree with the shapes this gate reads and drives every
# direction it can fail in. It runs on a fixture rather than on this
# repository, so it asserts the gate's behaviour and not today's prose, and
# it writes nothing outside its own temporary directory. CI enumerates the
# gates that carry one by matching this line.
if [ "${1:-}" = "--selftest" ]; then
	here=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
	t=$(mktemp -d) || exit 2
	trap 'rm -rf "$t"' EXIT
	mkdir -p "$t/doc" "$t/src"
	cat > "$t/src/f.c" <<-'EOF'
	hammer2_chain_lookup(void)
	{
	}

	const struct inode_operations fixture_iops = {
		.lookup		= fixture_lookup,
	};
	EOF
	base='`hammer2_igetv()` is not carried. `->statfs` is not written.'
	sfail=0
	run() {
		printf '%s\n' "$2" > "$t/doc/README.fixture.md"
		( cd "$t" && sh "$here" >/dev/null 2>&1 )
		got=$?
		if [ "$got" -ne "$1" ]; then
			echo "  FAIL selftest: $3: expected exit $1, got $got"
			sfail=$((sfail + 1))
		else
			echo "  ok   selftest: $3 (exit $got)"
		fi
	}
	# Each addition is single-quoted on its own line. A backtick inside a
	# double-quoted string is command substitution, which is what the first
	# run of this selftest did instead of testing anything.
	m_now='`->lookup` is not written.'
	m_past='`->lookup` was not written at `abc1234`.'
	s_false='`hammer2_chain_lookup()` is not carried.'
	only_sym='`hammer2_igetv()` is not carried.'
	only_meth='`->statfs` is not written.'
	run 0 "$base" "a fixture making only true claims passes"
	run 1 "$base $m_now" "a wired method claimed unwritten fails"
	run 0 "$base $m_past" "the same claim dated in the past tense passes"
	run 1 "$base $s_false" "a defined symbol claimed uncarried fails"
	run 1 "$only_sym" "no method claim at all trips the second floor"
	run 1 "$only_meth" "no symbol claim at all trips the first floor"
	[ "$sfail" -eq 0 ] || exit 1
	echo "absence: selftest: 6 direction(s), 0 failed"
	exit 0
fi

fail=0

# The matcher flattens each file first. These claims wrap across lines
# constantly, and a line-at-a-time pattern is blind to a continuation: the
# phrase that started this gate's existence, "Nothing mounts yet" in
# CLAUDE.md, broke across lines 8 and 9 and survived a hand sweep that
# matched it nowhere.
files=$(ls doc/README*.md doc/ARCHITECTURE.md doc/IO_MODEL.md README.md 2>/dev/null)
files="$files $(find src -name '*.c' -o -name '*.h' 2>/dev/null)"

nfile=0
for f in $files; do
	[ -f "$f" ] || continue
	nfile=$((nfile + 1))
done
if [ "$nfile" -eq 0 ]; then
	echo "absence: COULD-NOT-RUN: the population is empty, so this gate" >&2
	echo "         would report clean having read nothing" >&2
	exit 2
fi

sites=0
checked=0
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT

for f in $files; do
	[ -f "$f" ] || continue
	tr '\n' ' ' < "$f" | tr -s ' ' |
		command grep -oE '.{0,160}(is|are) not carried' > "$tmp/win" || continue
	while IFS= read -r win; do
		[ -n "$win" ] || continue
		sites=$((sites + 1))
		# Every function-shaped token in the window. A window can name
		# more than one symbol, and upstream's own prose lists three
		# in a row, so each is resolved rather than just the last.
		printf '%s\n' "$win" |
			command grep -oE '[a-z_][a-z0-9_]*\(\)' |
			sed 's/()$//' | LC_ALL=C sort -u > "$tmp/syms"
		while IFS= read -r sym; do
			[ -n "$sym" ] || continue
			checked=$((checked + 1))
			# BSD style puts the return type on its own line, so a
			# definition starts the line with the name. That is how
			# every function in this tree is written.
			def=$(command grep -rl "^$sym(" src/ 2>/dev/null | head -1)
			if [ -n "$def" ]; then
				echo "  FAIL $f: says \"$sym() is not carried\", but it is"
				echo "       defined in $def. If it was rewritten rather"
				echo "       than imported, the origin table's word for"
				echo "       that is \"rewritten\"."
				fail=$((fail + 1))
			fi
		done < "$tmp/syms"
	done < "$tmp/win"
done

# THE SECOND SHAPE: "->method is not written", resolved against the operations
# tables. Present tense only. A dated observation is written in the past with
# the commit it was true at ("was not written at 1f025fe"), which is a claim
# about that commit and cannot go stale, so it is deliberately not matched.
# Only the arrow form is read: a bare method name is not distinguishable from
# ordinary prose, and "the nine milestones are not written" is in this tree.
msites=0
mchecked=0
for f in $files; do
	[ -f "$f" ] || continue
	tr '\n' ' ' < "$f" | tr -s ' ' |
		command grep -oE '`?->[a-z_]+`?[^.]{0,80}?(is|are) not written' \
		> "$tmp/mwin" || continue
	while IFS= read -r win; do
		[ -n "$win" ] || continue
		msites=$((msites + 1))
		meth=$(printf '%s\n' "$win" |
			command grep -oE -- '->[a-z_]+' | head -1 | sed 's/^->//')
		[ -n "$meth" ] || continue
		mchecked=$((mchecked + 1))
		# The initializer form, anchored at the start of the line, which
		# is how every operations table in this tree is written. An
		# unanchored match would also read ordinary field assignment.
		wired=$(command grep -rlE "^[[:space:]]*\.$meth[[:space:]]*=" src/ \
			2>/dev/null | head -1)
		if [ -n "$wired" ]; then
			echo "  FAIL $f: says \"->$meth is not written\", but it is"
			echo "       initialized in an operations table in $wired."
			echo "       A method wired to a floor is written and refuses;"
			echo "       say what it does, or date the claim in the past"
			echo "       tense with the commit it was true at."
			fail=$((fail + 1))
		fi
	done < "$tmp/mwin"
done

# NO GATE IS TRUSTED ON SILENCE. Zero sites is a possible and correct state
# of the tree, and it is also exactly what a broken pattern looks like, so
# the two are separated rather than both reported as a pass.
if [ "$sites" -eq 0 ]; then
	echo "absence: FAIL: $nfile file(s) read and no absence claim matched at" >&2
	echo "         all. The tree has carried such claims continuously since" >&2
	echo "         2026-08-26, so zero means the pattern has stopped" >&2
	echo "         matching, not that the claims are gone. Check it against" >&2
	echo "         doc/README.porting.md, which names four uncarried" >&2
	echo "         functions in its device-layer section." >&2
	exit 1
fi

# The second shape gets its own floor. Folded into the first counter, a
# pattern that had stopped matching would hide behind the other shape's
# matches and the gate would report a clean tree having read nothing.
if [ "$msites" -eq 0 ]; then
	echo "absence: FAIL: no \"->method is not written\" claim matched at all." >&2
	echo "         doc/README.status.md records the ->statfs and ->get_link" >&2
	echo "         floors in that form, so zero means the pattern has" >&2
	echo "         stopped matching rather than that the floors are gone" >&2
	exit 1
fi

# The negative control runs on every invocation rather than under a flag, so
# a pattern that has stopped matching cannot report a clean tree. It asserts
# the checkable half of the gate, that a symbol which IS defined is caught,
# which the population assertion above does not: that one only proves
# something matched.
ctl=$(printf 'hammer2_chain_lookup() is not carried' |
	command grep -oE '.{0,160}(is|are) not carried' |
	command grep -oE '[a-z_][a-z0-9_]*\(\)' | sed 's/()$//')
if [ "$ctl" != "hammer2_chain_lookup" ]; then
	echo "absence: FAIL: the negative control did not extract a symbol from" >&2
	echo "         a sentence built to contain one, so the extraction above" >&2
	echo "         proves nothing" >&2
	exit 1
fi
command grep -rq "^hammer2_chain_lookup(" src/ || {
	echo "absence: FAIL: the negative control's symbol is not defined under" >&2
	echo "         src/, so the resolution above would pass anything" >&2
	exit 1
}

# The method half resolves a different fact with a different grep, so the
# control for the symbol half above proves nothing about it. This one asserts
# both steps: that a sentence built to name a method yields it, and that a
# method which IS wired is found, which is what makes a silent pass impossible.
mctl=$(printf '`->lookup` is not written' |
	command grep -oE '`?->[a-z_]+`?[^.]{0,80}?(is|are) not written' |
	command grep -oE -- '->[a-z_]+' | head -1 | sed 's/^->//')
if [ "$mctl" != "lookup" ]; then
	echo "absence: FAIL: the method control did not extract a name from a" >&2
	echo "         sentence built to contain one, so the extraction above" >&2
	echo "         proves nothing" >&2
	exit 1
fi
command grep -rqE "^[[:space:]]*\.lookup[[:space:]]*=" src/ || {
	echo "absence: FAIL: the method control's member is not initialized" >&2
	echo "         under src/, so the resolution above would pass anything" >&2
	exit 1
}
# And the tense discrimination, which is a property this gate relies on
# rather than assumes: a dated past-tense claim must not be read as current.
printf '`->statfs` was not written' |
	command grep -qE '`?->[a-z_]+`?[^.]{0,80}?(is|are) not written' && {
	echo "absence: FAIL: the pattern matched a past-tense claim, so a dated" >&2
	echo "         observation would be failed for being out of date" >&2
	exit 1
}

echo "absence: $nfile file(s), $sites claim(s), $checked symbol(s) resolved, $msites method claim(s), $mchecked resolved, $fail failure(s)"
# What this gate does NOT read, named rather than counted, because a gate
# that covers a subset and says nothing about the rest lends its credibility
# to claims it never looked at.
echo "absence: claims that name no symbol and no ->method are not read"
echo "         here: \"the module does not link\", \"nothing mounts\" and"
echo "         \"none of them is reachable\" were all defects of this class"
echo "         and none is checkable this way. The README opening that said"
echo "         this port does not mount anything, four days after it did,"
echo "         is the same blind spot and stayed wrong through four pushes."
[ "$fail" -eq 0 ] || exit 1
exit 0
