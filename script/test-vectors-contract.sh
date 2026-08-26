#!/bin/sh
# The two vector files' output and spelling are an interface, frozen here
# rather than in the consumer that depends on it.
#
# test/xxh64-vectors.c and test/crc32c-vectors.c are compiled by a gate in
# another repository, which reaches in through an environment variable and,
# until 2026-08-26, perturbed one of these files' text to arm its own negative
# control. A legitimate edit here, the rewrite that fixed these files' logic,
# lowercased a hex constant and broke that control silently: this repository
# reported six green gates for an hour while the consumer reported, correctly,
# that it was comparing nothing.
#
# Nothing below knows the consumer exists at runtime, reads its variable, or
# touches anything outside this tree. What it does is declare that these three
# things are this repository's interface and freeze them, so an edit that
# breaks them fails in the tree where the edit happens instead of somewhere
# the author cannot see.
#
# It freezes this side only. It cannot detect the consumer changing how it
# reads these files. A contract wants an assertion at each end, and this is
# one of them.
#
# Exit 2 is COULD-NOT-RUN. Exit 1 is a count of failed assertions.
set -u
cd "$(dirname "$0")/.." || exit 2

XXH=test/xxh64-vectors.c
CRC=test/crc32c-vectors.c
for f in "$XXH" "$CRC"; do
	[ -f "$f" ] || { echo "vectors: COULD-NOT-RUN: no $f"; exit 2; }
done

fail=0 ran=0

# The comparison is case-sensitive on purpose. The defect that has actually
# occurred here was a lowercasing, so a case-insensitive check would pass the
# one failure this gate was written for. `command grep` because only it
# honours no ignore file.
#
# The control below shares this function so the two cannot diverge. Until
# 2026-08-26 it ran its own inline grep, so a `-i` added to src_check would
# have left the control green while every check it guards went case-blind,
# the expected status coming from a different statement than the one under
# test.
matches() { command grep -q -- "$2" "$1"; }

src_check() { # name file pattern
	name="$1" file="$2" pat="$3"
	ran=$((ran + 1))
	if matches "$file" "$pat"; then
		echo "  ok    $name"
	else
		echo "  FAIL  $name: $file no longer matches $pat"
		fail=$((fail + 1))
	fi
}

echo "hammer2 vector contract:"
# Named for the same reason the shim gate names its compiler: the
# behavioural half below links whatever xxHash the host provides, and a run
# that could not link one is a different run from one that did.
# 1. The consumer arms its control by defining this. Losing it silently
#    disarms a negative control in another tree.
# Anchored on the directive, not the name. Every pattern here matches the code
# that has the effect rather than a token, because these files document their
# own contract in comments and a token check passes on the prose after the
# code is gone. Measured while writing this gate: the crc32c check below
# matched a comment quoting the wording, so deleting the printf left it green
# and only the control found it.
src_check "xxh64: -DXXH_VECTORS_CONTROL hook present" "$XXH" '#ifdef XXH_VECTORS_CONTROL'
# 2. The two constants, frozen on their own merit rather than on the
#    consumer's behalf. Until 2026-08-26 the consumer armed its control by
#    `sed`-ing `0xEF46DB3751D8E999ULL`, and lowercasing it here broke that
#    silently. It now uses the compile-time hook above and reads neither
#    constant, so the original reason to freeze the case is gone. The
#    freeze stays because the values are what the file is for: the first
#    is xxHash's own reference digest for the empty input, the second is
#    HAMMER2's seed, and a vector file whose expected values drift is a
#    test that cannot fail. The case-sensitivity is now this tree's own
#    consistency rule.
src_check "xxh64: constants uppercase" "$XXH" '0xEF46DB3751D8E999ULL'
src_check "xxh64: HAMMER2 seed uppercase" "$XXH" '0x4D617474446C6C6EULL'
# 3. The wording the consumer greps, in the order it greps it.
src_check "crc32c: a printf writes 'Castagnoli' then 'MATCH'" "$CRC" 'printf(.*Castagnoli.*MATCH'

# Negative control, run every time. Lowercase the constant on a copy and
# require the check to fail: a case-sensitive comparison and a
# case-insensitive one are indistinguishable while both are passing, and
# the case-insensitive one cannot catch the defect that has happened.
ran=$((ran + 1))
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
tr 'A-F' 'a-f' < "$XXH" > "$tmp/lowered.c" || exit 2
if matches "$tmp/lowered.c" '0xEF46DB3751D8E999ULL'; then
	echo "  FAIL  negative control: a lowercased copy still matched, so the"
	echo "        comparison above is not case-sensitive"
	fail=$((fail + 1))
else
	echo "  ok    negative control (a lowercased copy fails)"
fi

# The behavioural half. The exit status is the other half of the contract
# and a status only ever seen as 0 is not tested, so both directions are
# required. It needs an xxHash to link against, which this tree does not
# carry until 0.2; the system library is used when present and its absence
# is COULD-NOT-RUN for this half only. crc32c has no local implementation
# to link at all, so its exit status is not exercised here.
if [ "$fail" -ne 0 ]; then
	echo "vectors: $ran check(s), $fail failed"
	exit 1
fi
CC=${CC:-cc}
if ! command -v "$CC" >/dev/null 2>&1; then
	echo "vectors: $ran source check(s) passed; no $CC, so the exit status"
	echo "         half did NOT run"
	exit 2
fi
if ! "$CC" -o "$tmp/probe" "$XXH" -lxxhash >/dev/null 2>&1; then
	echo "vectors: $ran source check(s) passed; no xxHash to link against,"
	echo "         so the exit status half did NOT run"
	exit 2
fi

ran=$((ran + 1))
if "$tmp/probe" >/dev/null 2>&1; then
	echo "  ok    exit status 0 on correct vectors, under $("$CC" --version | head -1)"
else
	echo "  FAIL  the vectors do not pass against the system xxHash"
	fail=$((fail + 1))
fi
ran=$((ran + 1))
if "$CC" -DXXH_VECTORS_CONTROL -o "$tmp/bad" "$XXH" -lxxhash >/dev/null 2>&1; then
	if "$tmp/bad" >/dev/null 2>&1; then
		echo "  FAIL  the control build still exited 0, so a wrong expected"
		echo "        value passes and the consumer's control is inert"
		fail=$((fail + 1))
	else
		echo "  ok    exit status nonzero under -DXXH_VECTORS_CONTROL"
	fi
else
	echo "  FAIL  the control build did not compile"
	fail=$((fail + 1))
fi

echo "vectors: $ran check(s), $fail failed"
[ "$fail" = 0 ] || exit 1
