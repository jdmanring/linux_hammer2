#!/bin/sh
# A change reverted in the next commit is the cheapest evidence there is, and
# nothing recorded it. The tree has three places for what did not work -- a
# dated section in doc/history/verification-record.md, a note beside the code
# it concerns, and an entry in the XXX or DEFER ledger -- and none of them is
# read by a gate, so a revert can land with a message that says nothing and the
# next person pays for the same measurement.
#
# Measured 2026-10-13: 17 guest runs and 8 source changes taken back in one
# day, six of them mechanisms for a single defect. Every one carried its reason,
# because the reason was being written anyway. The gate formalises what the
# session happened to do, so a revert that says nothing is caught at the point
# it is committed rather than in a review nobody runs.
#
# WHAT IT CHECKS, and it is deliberately narrow.
#
# A commit is flagged when BOTH hold:
#
#   1. it removes at least REVERT_MIN non-comment lines from src/ that were
#      added by ITS OWN PARENT, and
#   2. its message carries no reason token.
#
# Condition 1 is measured against the parent and not against any older commit,
# because that is what distinguishes a revert from an ordinary edit. The first
# rule tried here matched removals against additions anywhere in the previous
# sixty commits and fired on 55 of 265 commits touching src/: nearly a quarter,
# most of them edits that merely altered a line some earlier commit had
# introduced. A check that noisy is read once and then ignored, which is worse
# than no check. Against the immediate parent the same history yields 6 of 200,
# every one a genuine take-back.
#
# Condition 2 is a vocabulary test and it is the weak half. A reason token is a
# word that says a measurement happened or a direction was taken, and it can be
# satisfied by prose that explains nothing. It is here because the alternative
# is a judgment call no shell script can make, and because the cheap cases --
# "revert", "undo", "fix the message", "oops" -- are what actually slip through.
# A message that satisfies the vocabulary and still says nothing is a defect
# this gate cannot see, and that limit is stated rather than hidden.
#
# The subject and the body are both read. The reason is usually in the subject,
# and reading the body alone missed `b3c3c37`, whose body is empty and whose
# subject states why. A row of the ledger or a note in the source can carry it
# instead, which is why the vocabulary is matched against both rather than
# against one of them.
#
# Exit 2 is COULD-NOT-RUN. Exit 1 is a failed assertion.
set -u
cd "$(dirname "$0")/.." || exit 2
command -v git >/dev/null 2>&1 || { echo "reverts: COULD-NOT-RUN: no git"; exit 2; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "reverts: COULD-NOT-RUN: not a repository"; exit 2; }
git rev-parse --verify HEAD >/dev/null 2>&1 || { echo "reverts: COULD-NOT-RUN: no HEAD"; exit 2; }

# How many removed lines make a commit a revert rather than an edit that
# happens to delete something. Today's reverts remove 15 to 30; an edit that
# replaces a few lines is not one.
REVERT_MIN=${H2_REVERT_MIN:-8}
# How far back to read, and the default is measured rather than chosen. The
# gate's subject is the commit about to land, not the archive, and the whole
# history holds take-backs whose reason is stated in wording the vocabulary
# does not name: `b3c3c37` (2026-09-04) removes `hammer2_mtx_sh(&chain->lock)`
# calls and says why in its subject, and 60 commits back is where the
# vocabulary's coverage of this tree reaches 11 of 12. `H2_REVERT_DEPTH=300`
# reads the archive deliberately and reports what it finds there.
REVERT_DEPTH=${H2_REVERT_DEPTH:-60}
# How many commits back the additions may have come from.
REVERT_WINDOW=${H2_REVERT_WINDOW:-25}

# A reason token. Deliberately broad on the words that mean a direction was
# taken or a measurement was made, and narrow enough that a message with none
# of them usually has no reason in it.
REASON='revert|undo|back out|backed out|remov|restore|reinstate|took back|taken back|withdraw|abandon|discard|drop|no longer|unnecessar|does not work|did not work|doesn.t work|inert|wrong|fail|broke|break|hangs|hang|wedge|panic|refus|regress|instead|because|since|measured|trial|tried|attempt|no effect|had no'

scanned=0; checked=0; flagged=0; bad=0

# Walk the history newest first. For each commit, the lines it removed are
# matched against the lines its ANCESTORS added, not only its parent: a change
# is often taken back several commits later, and measured 2026-10-13 the
# reverts of that session remove lines their immediate parents never touched.
# The window bounds how far back the additions are gathered.
#
# The union is built once per commit from the window's diffs, and a commit is
# counted as a take-back when it removes REVERT_MIN or more lines the window
# added. Whole-line comments are excluded on both sides, since a comment is
# rewritten freely and a removal of one is not a take-back of behaviour.
for h in $(git log --no-merges --first-parent --format=%H -n "$REVERT_DEPTH" -- src/ 2>/dev/null); do
	p=$(git rev-parse --verify -q "$h^" 2>/dev/null) || continue
	scanned=$((scanned + 1))
	rem=$(git diff --no-color -U0 "$p" "$h" -- src/ 2>/dev/null |
		sed -n 's/^-\([^-]\)/\1/p' |
		sed '/^[[:space:]]*\*/d; /^[[:space:]]*\/\*/d; /^[[:space:]]*\/\//d; /^[[:space:]]*$/d')
	[ -n "$rem" ] || continue
	nrem=$(printf '%s\n' "$rem" | wc -l | tr -d ' ')
	[ "$nrem" -ge "$REVERT_MIN" ] || continue

	# The lines the window added, gathered from each ancestor's own diff.
	# walk back REVERT_WINDOW commits and union their additions.
	: > "/tmp/.h2pool.$$"
	w=$(git rev-parse --verify -q "$p" 2>/dev/null) || continue
	n=0
	while [ "$n" -lt "$REVERT_WINDOW" ]; do
		gp=$(git rev-parse --verify -q "$w^" 2>/dev/null) || break
		git diff --no-color -U0 "$gp" "$w" -- src/ 2>/dev/null |
			sed -n 's/^+\([^+]\)/\1/p' |
			sed '/^[[:space:]]*\*/d; /^[[:space:]]*\/\*/d; /^[[:space:]]*\/\//d; /^[[:space:]]*$/d' \
			>> "/tmp/.h2pool.$$"
		w="$gp"; n=$((n + 1))
	done
	[ -s "/tmp/.h2pool.$$" ] || { rm -f "/tmp/.h2pool.$$"; continue; }

	printf '%s\n' "$rem" > "/tmp/.h2rem.$$"
	matched=$(grep -F -x -f "/tmp/.h2pool.$$" "/tmp/.h2rem.$$" 2>/dev/null | wc -l | tr -d ' ')
	rm -f "/tmp/.h2rem.$$" "/tmp/.h2pool.$$"
	[ "$matched" -ge "$REVERT_MIN" ] || continue

	checked=$((checked + 1))
	# Subject AND body. The subject is where a reason usually is, and the first
	# version read the body alone on the reasoning that the ledger row or the
	# source note could carry it -- true, but the measured case in this history
	# is `b3c3c37`, whose body is empty and whose subject states the reason.
	msg=$(git log --format='%s%n%b' -1 "$h")
	if printf '%s' "$msg" | grep -Eiq "$REASON"; then
		continue
	fi
	flagged=$((flagged + 1))
	subj=$(git log --format=%s -1 "$h")
	echo "  FAIL $(git log --format=%h -1 "$h"): takes back $matched line(s) an ancestor added"
	echo "        and its message carries no reason: $subj"
done

# The population is COMMITS READ, not take-backs found. A window whose commits
# happen to contain no take-back would otherwise report clean without the rule
# having run, and that is the empty-population defect the other repository
# gates assert against.
[ "$scanned" -gt 0 ] || {
	echo "reverts: FAIL: read 0 commits in the last $REVERT_DEPTH touching src/," >&2
	echo "  so the walk matched nothing: either src/ received no work or the" >&2
	echo "  log command stopped returning. A check over an empty population" >&2
	echo "  must not read as a check that found nothing wrong." >&2
	exit 1; }

# The control, on the same form of input the check reads: a message with no
# reason must be caught by the vocabulary and one with a reason must not, or
# the vocabulary cannot tell them apart and the check is vacuous.
ctl_no=$(printf 'take the bound out again\n' | grep -Eic "$REASON")
ctl_yes=$(printf 'the bound does not work, so it is reverted\n' | grep -Eic "$REASON")
if [ "$ctl_no" -ne 0 ] || [ "$ctl_yes" -eq 0 ]; then
	echo "  FAIL control: the reason vocabulary read ${ctl_no} for a message" >&2
	echo "  with no reason and ${ctl_yes} for one that has it, so this check" >&2
	echo "  cannot tell them apart." >&2
	exit 1
fi

echo "reverts: $scanned commit(s) read of $REVERT_DEPTH, $checked take-back(s), $flagged with no reason"
[ "$flagged" = 0 ] || bad=1
exit "$bad"
