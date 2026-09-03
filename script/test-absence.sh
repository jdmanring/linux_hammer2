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

fail=0

# The matcher flattens each file first. These claims wrap across lines
# constantly, and a line-at-a-time pattern is blind to a continuation: the
# phrase that started this gate's existence, "Nothing mounts yet" in
# CLAUDE.md, broke across lines 8 and 9 and survived a hand sweep that
# matched it nowhere.
files=$(ls doc/README*.md doc/ARCHITECTURE.md doc/IO_MODEL.md 2>/dev/null)
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

echo "absence: $nfile file(s), $sites claim(s), $checked symbol(s) resolved, $fail failure(s)"
# What this gate does NOT read, named rather than counted, because a gate
# that covers a subset and says nothing about the rest lends its credibility
# to claims it never looked at.
echo "absence: claims that name no symbol are not read here: \"the module"
echo "         does not link\", \"nothing mounts\" and \"none of them is"
echo "         reachable\" were all defects of this class and none of them"
echo "         is checkable this way"
[ "$fail" -eq 0 ] || exit 1
exit 0
