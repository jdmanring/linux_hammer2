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
#
# A budget bounds the whole run, because a fleet gate against a guest that
# is up but wedged spends its own five-minute ssh wait and returns 2, and
# two such gates outlive the window the remote keeps an idle connection
# open: the push then dies before it sends anything, with no gate having
# failed. The eleven gates that need only this machine take about
# forty-five seconds together, so the budget is never reached on a healthy
# tree and only ever ends a push the fleet was going to refuse anyway.
# H2_PREPUSH_BUDGET=<seconds> raises it for a run that means to wait.
set -u

[ "${H2_SKIP_PREPUSH:-0}" = "1" ] && exit 0

root=$(git rev-parse --show-toplevel) || exit 1
cd "$root" || exit 1

rc=0
warned=0

budget=${H2_PREPUSH_BUDGET:-400}
case $budget in
''|*[!0-9]*) echo "pre-push: H2_PREPUSH_BUDGET is not a number" >&2; exit 1 ;;
esac
began=$(date +%s)

# Run one gate under the remaining budget. Past it the gate is reported
# rather than run, so a wedged guest cannot hold the push open: the state
# of the tree is not the question at that point, only the machine's.
run_gate() {
	gate=$1
	shift
	now=$(date +%s)
	left=$((budget - (now - began)))
	if [ "$left" -le 0 ]; then
		warned=$((warned + 1))
		printf 'pre-push: COULD-NOT-RUN %s\n' "$gate" >&2
		printf '          the %ss budget elapsed, so this gate was not run;\n' "$budget" >&2
		printf '          run it by hand, or raise H2_PREPUSH_BUDGET\n' >&2
		return 0
	fi
	out=$(timeout "$left" bash "$gate" "$@" 2>&1)
	s=$?
	if [ "$s" -eq 124 ]; then
		warned=$((warned + 1))
		printf 'pre-push: COULD-NOT-RUN %s\n' "$gate" >&2
		printf '          it did not finish in the %ss left of the budget\n' "$left" >&2
		return 0
	fi
	case "$s" in
	0) ;;
	2)
		warned=$((warned + 1))
		printf 'pre-push: COULD-NOT-RUN %s\n' "$gate" >&2
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
		printf 'pre-push: FAILED %s\n' "$gate" >&2
		printf '%s\n' "$out" | tail -12 >&2
		keep=".git/pre-push-failed-$(basename "$gate" .sh).log"
		printf '%s\n' "$out" > "$keep"
		printf 'pre-push: full output kept in %s\n' "$keep" >&2
		;;
	esac
	return 0
}

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

# The kernel tree the fleet gates build against. Without one they fall back
# to the host's headers, which on this machine is below the floor, so the
# two gates that actually build the module and boot it reported
# COULD-NOT-RUN on every push and were covered only by a hand run. KDIR is
# only set when the caller has not set it and the tree of record is where
# the testing document says it is, so a machine without it behaves as
# before rather than failing for a new reason.
if [ -z "${KDIR:-}" ]; then
	for d in "$HOME/kernels/linux-7.3-rc5" "$HOME/kernels/linux-7.3" \
		 "$HOME/kernels/linux-7.3-rc4" "$HOME/kernels/linux-7.3-rc1"; do
		[ -d "$d" ] && { KDIR=$d; export KDIR; break; }
	done
fi

# The reason a COULD-NOT-RUN gate gives is kept: it was being dropped, so
# a harness defect that stopped a gate from running read exactly like a
# machine that was not available.
# A push checks the tree, not the guest fleet. The two fleet gates wait five
# minutes for a guest that does not answer ssh, and a guest that is up but
# wedged is indistinguishable from a slow one to the gate; two of those waits
# are what killed a push whose every other gate was green. The check that the
# fleet gates perform is worth having when they can run, and it costs nothing
# when the guest answers at once, so the wait is cut to ten seconds here and
# the gates return COULD-NOT-RUN as they would anyway. Both remain hand
# runnable at their own five minutes, which is the run that means something.
H2_GUEST_WAIT=${H2_GUEST_WAIT:-2}
export H2_GUEST_WAIT

for g in script/test-*.sh; do
	run_gate "$g"
done

# Anchored on the implementation and not on the name, the way CI does it:
# matching the bare flag picks up a gate that only MENTIONS --selftest in
# a comment.
for g in $(command grep -l '"${1:-}" = "--selftest"' script/test-*.sh); do
	run_gate "$g" --selftest
done

if [ "$rc" != 0 ]; then
	echo "pre-push: refusing the push. CI would report this." >&2
	echo "          H2_SKIP_PREPUSH=1 git push overrides deliberately." >&2
	exit 1
fi

printf 'pre-push: gates and selftests pass, %d could not run\n' "$warned" >&2
exit 0
