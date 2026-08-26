#!/usr/bin/env bash
# Kernel style, bounded rather than clean.
#
# This tree is BSD style, because it carries DragonFly code and tracks
# Kusumi's BSD ports: `return (x);`, typedef'd lock types, tabs at four
# columns of intent. Converting that now would create a large diff against
# the trees this port is meant to stay readable beside, and buy nothing
# until an actual mainline submission, which converts the whole thing in
# one mechanical pass.
#
# So the gate is not "checkpatch is silent". It is "the deviation set is
# the one we recorded, and it did not grow". A new category, or more hits
# in an existing one, fails. doc/README.kernel-style.md lists them.
#
# Exit 2 is COULD-NOT-RUN: no checkpatch.pl. Point CHECKPATCH at one, or
# set KDIR to a full kernel source tree.
#
# LC_ALL=C on both sorts, because the baseline is compared byte for byte
# and glibc collation differs between machines: the first CI run failed
# with every count identical and four lines in a different order.
#
# A BASELINE IS A CLAIM ABOUT A CHECKER VERSION. checkpatch.pl changes with
# the kernel, so the same tree scores differently under different copies of
# it: measured 2026-08-25, this tree is 579 hits under torvalds/master and
# 582 under v6.15, the difference being three more `Argument 'X' is not
# used in function-like macro`. Comparing a byte-exact baseline against a
# moving checker fails red for a reason that is not this code, and, worse,
# goes quietly green when a check is dropped upstream. So the version is
# recorded in the first line of the baseline file, where it cannot drift
# away from the numbers it qualifies, and comment lines are stripped from
# both sides before the comparison.
set -u
cd "$(dirname "$0")/.." || exit 2

# --selftest: the sha256 provenance line, which nothing read either. It
# copies the checker it was given, appends a comment so the CONTENT differs
# while the behaviour does not, and requires the gate to notice. The
# assertion branch is the one that mattered: a wrong checker carrying
# CHECKPATCH_REF for the right version was reported as a style regression
# against this code until 2026-08-26.
if [ "${1:-}" = "--selftest" ]; then
	cp0=${CHECKPATCH:-${KDIR:-/lib/modules/$(uname -r)/build}/scripts/checkpatch.pl}
	[ -f "$cp0" ] || { echo "selftest: COULD-NOT-RUN: no checkpatch.pl at $cp0"; exit 2; }
	t=$(mktemp -d) || exit 2
	trap 'rm -rf "$t"' EXIT
	cp "$cp0" "$t/cp.pl" || exit 2
	printf '# selftest: content changed, behaviour identical\n' >> "$t/cp.pl"
	out=$(CHECKPATCH="$t/cp.pl" CHECKPATCH_REF=v7.2 bash "$0" 2>&1)
	if printf '%s' "$out" | command grep -q 'sha256 does NOT match'; then
		echo "  ok    a checker whose content differs is named as such"
		echo "selftest: 1 check(s), 0 failed"
		exit 0
	fi
	echo "  FAIL  a modified checker was not distinguished from the recorded one:"
	printf '%s\n' "$out" | tail -2 | sed 's/^/        /'
	exit 1
fi

# WHICH BRANCH FOUND THE CHECKER, PRINTED AND NOT PINNED. Which one is
# right depends on the machine, so constraining it would break the case the
# fallback exists for; naming it is the whole fix.
# THE DEFAULT MUST REACH THE KERNEL OF RECORD, the same defect the syntax
# gate had: this looked only at the host's build tree, so it reported
# COULD-NOT-RUN on a machine where the kernel the port targets was sitting
# in the store with a checkpatch.pl in it. A nixpkgs kernel dev output
# keeps the script under source/scripts - build/scripts holds gdb helpers.
#
# The candidate whose sha256 MATCHES THE BASELINE is preferred, because
# that is the checker the recorded deviation set was produced with and the
# only one whose disagreement is attributable to this code. Otherwise the
# first that exists, whose provenance is then printed as unmatched.
base=doc/checkpatch-baseline.txt
basesha=$(sed -n 's/^# sha256 //p' "$base" 2>/dev/null | head -1)
CP=${CHECKPATCH:-}
if [ -n "$CP" ]; then
	cpsrc="CHECKPATCH"
else
	# Three tiers, strongest first: the file the baseline was produced
	# with, identified by content; then any checker whose own tree reports
	# the baseline's version, which is what makes a distribution's patched
	# copy usable; then whatever exists, so the refusal can name it.
	refver=$(sed -n '1s/.*linux \(v[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' "$base" 2>/dev/null)
	CP=""; cpsrc=""; cpver_cand=""
	for cand in "${KDIR:-/lib/modules/$(uname -r)/build}/scripts/checkpatch.pl" \
		$(ls /nix/store/*-linux-*-dev/lib/modules/*/source/scripts/checkpatch.pl 2>/dev/null | sort -V -r); do
		[ -f "$cand" ] || continue
		[ -z "$CP" ] && { CP=$cand; cpsrc="first found, version unmatched"; }
		if [ -n "$basesha" ] && [ "$(sha256sum "$cand" 2>/dev/null | cut -d' ' -f1)" = "$basesha" ]; then
			CP=$cand; cpsrc="the checker the baseline records, by sha256"
			break
		fi
		cmk=$(dirname "$cand")/../Makefile
		if [ -n "$refver" ] && [ -f "$cmk" ]; then
			cv="v$(sed -n 's/^VERSION *= *//p' "$cmk" | head -1).$(sed -n 's/^PATCHLEVEL *= *//p' "$cmk" | head -1)"
			if [ "$cv" = "$refver" ] && [ "$cpver_cand" != matched ]; then
				CP=$cand; cpsrc="a $refver tree's own checker, hash unmatched"; cpver_cand=matched
			fi
		fi
	done
	[ -n "$CP" ] || { CP=${KDIR:-/lib/modules/$(uname -r)/build}/scripts/checkpatch.pl; cpsrc="none found"; }
fi
[ -f "$CP" ] || { echo "checkpatch: COULD-NOT-RUN: no checkpatch.pl at $CP"; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "checkpatch: COULD-NOT-RUN: no perl"; exit 2; }

# THE VERSION IS A THIRD WAY THIS GATE CANNOT ANSWER, and until now it was
# the only one that exited 1. The block above already says a baseline is a
# claim about a checker version, and the failure text below already tells
# the reader to check their checkpatch.pl is that version FIRST - so the
# version was known to matter, was printed, and was still not tested. A
# wrong-version run and a real style regression left by the same exit code,
# which is the status a runner reads.
#
# `checkpatch.pl` carries no version of its own, so it is taken from the
# kernel tree it sits in: `scripts/checkpatch.pl` puts the Makefile two
# levels up. `CHECKPATCH_REF` overrides, for a copy pulled out of its tree.
# THE VERSION HAS TWO SOURCES AND THEY ARE NOT THE SAME KIND OF THING.
# CHECKPATCH_REF is a human ASSERTION; the Makefile two levels up is
# DERIVED from the tree the checker sits in. The comparison below treats
# them identically, which is correct - but a reader who sees "v7.2" cannot
# tell whether the gate measured it or was told, and every run of this gate
# on this workstation was told, because the pinned copy lives outside a
# kernel tree. So the origin is printed beside the version.
# THE STRONGEST IDENTITY IS THE ONE THE FILE ANSWERS FOR ITSELF. A version
# taken from the tree the checker was cut from does not survive the checker
# being copied out of that tree, which is the condition that created the
# problem here: the pinned copy lives outside a kernel tree, so every run
# fell back to an ASSERTION and the gate printed agreement with itself. A
# content hash cannot be asserted wrong and travels with the file.
#
# checkpatch.pl's own `my $V = '0.32'` is not a discriminator: it reads
# 0.32 in v6.15, v7.2 and this workstation's 7.1 copy alike. A version
# field that never changes reads like an instrument and is not one.
base=doc/checkpatch-baseline.txt
cpsha=$(sha256sum "$CP" 2>/dev/null | cut -d' ' -f1)
basesha=$(sed -n 's/^# sha256 //p' "$base" 2>/dev/null | head -1)
cpver=${CHECKPATCH_REF:-}
if [ -n "$cpsha" ] && [ -n "$basesha" ] && [ "$cpsha" = "$basesha" ]; then
	# The file IS the one the baseline was produced with. Nothing a
	# Makefile or an environment variable says can improve on that.
	cpver=$(sed -n '1s/.*linux \(v[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' "$base")
	versrc="derived from the checker's own content, sha256 matches the baseline"
elif [ -n "$cpver" ]; then
	versrc="asserted via CHECKPATCH_REF; the checker's sha256 does NOT match the baseline's"
else
	versrc="derived from the checker's own tree; the checker's sha256 does not match the baseline's"
fi
if [ -z "$cpver" ]; then
	mk=$(dirname "$CP")/../Makefile
	if [ -f "$mk" ]; then
		v=$(sed -n 's/^VERSION *= *//p' "$mk" | head -1)
		pl=$(sed -n 's/^PATCHLEVEL *= *//p' "$mk" | head -1)
		[ -n "$v" ] && [ -n "$pl" ] && cpver="v$v.$pl"
	fi
fi

files=$(ls src/sys/fs/hammer2/*.c src/sys/fs/hammer2/*.h)
got=$(perl "$CP" --no-tree --file --terse --no-summary $files 2>/dev/null |
	sed 's/^.*: \(WARNING\|ERROR\): //' |
	sed "s/'[^']*'/'X'/g" |
	LC_ALL=C sort | uniq -c | awk '{$1=$1; print}' | LC_ALL=C sort -k2)

# AN ABSENT BASELINE IS COULD-NOT-RUN, NOT A LICENCE TO WRITE ONE. Until
# 2026-08-25 this line wrote the baseline from whatever the tree happened to
# produce and exited 0, so a run against a tree whose baseline had been
# deleted, or a partial checkout, PUBLISHED a new deviation set and reported
# success - a gate answering a question it had just made unanswerable. The
# file is tracked, so the window is narrow; the exit code was the problem,
# because 0 here means "the set did not move" and nothing had been compared.
# Found by sweeping what these gates WRITE rather than by a symptom.
if [ ! -f "$base" ]; then
	if [ "${1:-}" = "--write" ]; then
		printf '# checkpatch.pl from linux %s\n' "${CHECKPATCH_REF:-UNRECORDED - set CHECKPATCH_REF}" > "$base"
		printf '%s\n' "$got" >> "$base"
		echo "checkpatch: baseline WRITTEN from this tree, $(printf '%s\n' "$got" | awk '{s+=$1} END{print s+0}') hits."
		echo "            This run compared nothing. Read the file before committing it."
		exit 2
	fi
	echo "checkpatch: COULD-NOT-RUN: no baseline at $base, so there is nothing" >&2
	echo "            to compare against. Restore it (it is tracked), or pass" >&2
	echo "            --write to record a new one deliberately." >&2
	exit 2
fi

ref=$(sed -n '1s/^# *//p' "$base")
# Just the version out of "checkpatch.pl from linux vX.Y". Anything that is
# not that shape is left empty and read as unestablished, rather than being
# compared as a string and mismatching on formatting.
refver=$(printf '%s\n' "$ref" | sed -n 's/.*linux \(v[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p')

# A PROVEN MISMATCH CANNOT BE ATTRIBUTED TO THIS CODE, so it is
# COULD-NOT-RUN and not a failure. Measured 2026-08-25 on this workstation:
# baseline v6.15 against the Artix 7.1 checkpatch.pl gives one differing
# category, 18 hits against 15 of `Argument 'X' is not used in
# function-like macro`, every other line byte-identical - the same
# signature the block at the top of this file already records for
# master-against-v6.15.
if [ -n "$cpver" ] && [ -n "$refver" ] && [ "$cpver" != "$refver" ]; then
	echo "checkpatch: COULD-NOT-RUN: checkpatch.pl is from linux $cpver," >&2
	echo "            the baseline is from $refver, and the deviation set" >&2
	echo "            moves with the checker. Point CHECKPATCH at a $refver" >&2
	echo "            tree, or set CHECKPATCH_REF if you know better." >&2
	echo "            $CP" >&2
	exit 2
fi
if diff -u <(grep -v '^#' "$base") <(printf '%s\n' "$got"); then
	echo "checkpatch: deviation set unchanged ($(printf '%s\n' "$got" | awk '{s+=$1} END{print s+0}') hits, baseline: ${ref:-version unrecorded})"
	echo "checkpatch: checker from $cpsrc, version ${cpver:-unestablished} $versrc"
else
	# PROVENANCE PRINTS ON THIS BRANCH TOO. It only printed on the
	# passing path until 2026-08-26, which is the branch where nobody
	# needs it: on a diff the reader has to decide whether to blame the
	# code, and that decision IS the provenance question.
	echo "checkpatch: checker from $cpsrc, version ${cpver:-unestablished} $versrc"
	echo "checkpatch: the deviation set MOVED against ${ref:-an unrecorded version}."
	echo "            Check your checkpatch.pl is that version FIRST: a"
	echo "            different one moves the counts on unchanged code."
	echo "            If the change is deliberate, update"
	echo "            doc/checkpatch-baseline.txt, including its first"
	echo "            line, and say why in doc/README.kernel-style.md."
	# AN UNESTABLISHED VERSION IS ONLY DISQUALIFYING ON A DIFF. An
	# unchanged set is unchanged whatever produced it, so this never turns
	# a green into COULD-NOT-RUN; but a set that MOVED cannot be blamed on
	# the code unless the checker is known to be the baseline's.
	# AN ASSERTION IS NOT EVIDENCE, and on a diff that distinction decides
	# the exit code. A checker whose content does not match the baseline's
	# recorded sha256, carrying a CHECKPATCH_REF that names the right
	# version anyway, was reported as a real style regression: the
	# assertion laundered a wrong checker into a verdict about this code.
	# Measured 2026-08-26 by pointing the gate at the v6.15 copy with
	# CHECKPATCH_REF=v7.2, which exited 1.
	if [ -n "$basesha" ] && [ -n "$cpsha" ] && [ "$cpsha" != "$basesha" ]; then
		echo "            The checker's sha256 does not match the one the" >&2
		echo "            baseline records, so whatever names it carries," >&2
		echo "            this is not the checker that produced the" >&2
		echo "            baseline and the diff is not attributable to" >&2
		echo "            the code." >&2
		exit 2
	fi
	if [ -z "$cpver" ] || [ -z "$refver" ]; then
		echo "            The checker version could not be established" >&2
		echo "            (checkpatch ${cpver:-unknown}, baseline ${refver:-unrecorded})," >&2
		echo "            so this diff is not attributable to the code." >&2
		exit 2
	fi
	exit 1
fi
