#!/bin/sh
# Run locally what CI runs, before the push rather than after it.
#
# This exists because CI was being used as a compiler: one push per
# question, each answer arriving as a failure notification on someone
# else's phone. Twenty-six such runs between 2026-08-29 and 2026-09-03,
# and two more on 2026-09-04 when a pin move was pushed without running
# the gate selftests, which CI runs as a step of its own.
#
# It sits under script/ so a clone gets it, since .git/hooks is never
# versioned, and is deliberately not named test-*.sh: the gates are
# run individually on purpose and CI enumerates them by that glob, so a
# runner named like one would be picked up as a gate itself and would
# also invite reading one exit status for many questions. This is local
# hygiene, not a gate. Install it with
#
#     ln -sf ../../script/pre-push-check.sh .git/hooks/pre-push
#
# H2_SKIP_PREPUSH=1 git push  skips it, for a push that is deliberately
# ahead of a green tree. Exit 2 from a gate is COULD-NOT-RUN and is a
# warning here exactly as it is in CI, never a pass and never a failure.
set -u

[ "${H2_SKIP_PREPUSH:-0}" = "1" ] && exit 0

root=$(git rev-parse --show-toplevel) || exit 1
cd "$root" || exit 1

rc=0
warned=0

# The style gate needs the checker the baseline was produced with, or it
# reports COULD-NOT-RUN rather than attributing a moved deviation set to
# this code. That is right of the gate and wrong for a pre-push check:
# without it a real style regression warns instead of blocking. CI solves
# this by fetching the pinned checker; do the same, once, and cache it by
# the sha the baseline records so the cache cannot go stale silently.
if [ -z "${CHECKPATCH:-}" ]; then
	bsha=$(sed -n 's/^# sha256 //p' doc/checkpatch-baseline.txt | head -1)
	bref=$(sed -n '1s/.*linux \(v[0-9][^ ]*\).*/\1/p' doc/checkpatch-baseline.txt)
	cache=${XDG_CACHE_HOME:-$HOME/.cache}/linux_hammer2
	cp_cached=$cache/checkpatch-$bsha.pl
	if [ -n "$bsha" ] && [ ! -f "$cp_cached" ] && [ -n "$bref" ]; then
		mkdir -p "$cache"
		curl -sSfL -o "$cp_cached.tmp" \
		    "https://raw.githubusercontent.com/torvalds/linux/$bref/scripts/checkpatch.pl" \
		    2>/dev/null &&
		    [ "$(sha256sum "$cp_cached.tmp" | cut -d' ' -f1)" = "$bsha" ] &&
		    mv "$cp_cached.tmp" "$cp_cached"
		rm -f "$cp_cached.tmp"
	fi
	if [ -f "$cp_cached" ]; then
		CHECKPATCH=$cp_cached
		export CHECKPATCH
	else
		echo "pre-push: no checker matching the baseline; the style gate" >&2
		echo "          will report COULD-NOT-RUN and prove nothing" >&2
	fi
fi

for g in script/test-*.sh; do
	out=$(bash "$g" 2>&1)
	s=$?
	case "$s" in
	0) ;;
	2)
		# The gate says why it could not run and the reason was being
		# dropped, so a harness defect that stopped a gate from running
		# read exactly like a machine that was not available. Print the
		# gate's own reason, or say plainly that it gave none.
		warned=$((warned + 1))
		printf 'pre-push: COULD-NOT-RUN %s\n' "$g" >&2
		why=$(printf '%s\n' "$out" | command grep -i 'COULD-NOT-RUN' |
		    command sed 's/^[^:]*: *COULD-NOT-RUN: *//' | head -3)
		if [ -n "$why" ]; then
			printf '%s\n' "$why" | command sed 's/^/          /' >&2
		else
			echo "          the gate gave no reason" >&2
		fi
		;;
	*)
		rc=1
		printf 'pre-push: FAILED %s\n' "$g" >&2
		printf '%s\n' "$out" | tail -12 >&2
		;;
	esac
done

# Anchored on the implementation and not on the name, the way CI does it:
# matching the bare flag picks up a gate that only MENTIONS --selftest in
# a comment.
for g in $(command grep -l '"${1:-}" = "--selftest"' script/test-*.sh); do
	out=$(bash "$g" --selftest 2>&1)
	s=$?
	case "$s" in
	0) ;;
	2)
		warned=$((warned + 1))
		printf 'pre-push: COULD-NOT-RUN %s --selftest\n' "$g" >&2
		;;
	*)
		rc=1
		printf 'pre-push: FAILED %s --selftest\n' "$g" >&2
		printf '%s\n' "$out" | tail -12 >&2
		;;
	esac
done

if [ "$rc" != 0 ]; then
	echo "pre-push: refusing the push. CI would report this." >&2
	echo "          H2_SKIP_PREPUSH=1 git push overrides deliberately." >&2
	exit 1
fi

printf 'pre-push: gates and selftests pass, %d could not run\n' "$warned" >&2
exit 0
