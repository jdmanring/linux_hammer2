#!/bin/sh
# The CCMS thread lock's release count, against the shipped file.
#
# hammer2_ccms.c is carried from DragonFly, where the bad-state arm of
# ccms_thread_lock() and ccms_thread_lock_nonblock() releases the CST's
# spin, calls panic(), and falls through to the release after the
# if/else chain.  panic() never returns there, so that is one release.
# This port's hpanic() returns, so the same shape releases the spin
# twice, and the spin is a rw_semaphore here: the second up_write() on a
# lock nobody holds corrupts the count.
#
# The functions under test are the shipped ones.  This gate extracts them
# from src/sys/fs/hammer2/hammer2_ccms.c by name into a generated header
# and fails if any extraction is empty, so a renamed or deleted function
# is a could-not-run rather than a probe that tests nothing.  A copy of
# the functions here would drift from the shipped text, and the defect
# was in the shipped text.
#
# Cannot prove: that the kernel's rw_semaphore behaves as the stand-in
# does, or that any caller reaches these paths.  It proves the release
# count, which is the property the carry got wrong.
#
# Needs nothing but a C compiler.
set -u
cd "$(dirname "$0")/.." || exit 2
CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || { echo "ccms-lock: COULD-NOT-RUN: no $CC"; exit 2; }

SRC=src/sys/fs/hammer2/hammer2_ccms.c
[ -f "$SRC" ] || { echo "ccms-lock: COULD-NOT-RUN: no $SRC" >&2; exit 2; }

tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT INT TERM

# Extract one function by name: the line that opens its body back to the
# return type above it, which in this file's BSD style sits on its own
# line.  awk rather than sed so the brace depth is counted rather than
# guessed, since the bodies have nested braces and a line range would
# drift the moment a comment above one changed.
extract() {
	awk -v fn="$1" '
		index($0, fn "(") == 1 { inb = 1; print prev; print; next }
		inb {
			print
			n = gsub(/\{/, "{")
			m = gsub(/\}/, "}")
			depth += n - m
			if (depth == 0 && n + m > 0) exit
		}
		{ prev = $0 }
	' "$SRC"
}

# The four functions the probe calls.  Each must come back non-empty and
# must carry the body, not just the signature.
missing=0
for fn in ccms_thread_lock ccms_thread_lock_nonblock \
	  ccms_thread_lock_upgrade ccms_thread_unlock; do
	body=$(extract "$fn")
	if [ -z "$body" ]; then
		echo "ccms-lock: COULD-NOT-RUN: $fn not found in $SRC" >&2
		missing=1
		continue
	fi
	case "$body" in
	*"{"*"}"*) : ;;
	*) echo "ccms-lock: COULD-NOT-RUN: $fn extracted without a body" >&2
	   missing=1 ;;
	esac
	printf '%s\n\n' "$body" >> "$tmp/hammer2-ccms-extracted.h"
done
[ "$missing" -eq 0 ] || exit 2

# ccms_thread_lock_nonblock() calls ccms_thread_lock(), and
# ccms_thread_unlock() is called by the control, so all four are in the
# generated header.  A prototype for each keeps the order they appear in
# the source from mattering.
{
	printf 'void ccms_thread_lock(ccms_cst_t *, ccms_state_t);\n'
	printf 'int ccms_thread_lock_nonblock(ccms_cst_t *, ccms_state_t);\n'
	printf 'ccms_state_t ccms_thread_lock_upgrade(ccms_cst_t *);\n'
	printf 'void ccms_thread_unlock(ccms_cst_t *);\n\n'
	cat "$tmp/hammer2-ccms-extracted.h"
} > "$tmp/extracted.h"
mv "$tmp/extracted.h" "$tmp/hammer2-ccms-extracted.h"

# The probe includes the generated header by that name, so it is compiled
# from a copy of the test directory with the generated file beside it.
cp test/hammer2-ccms-lock.c "$tmp/"
if ! $CC -std=gnu11 -Wall -Wextra -Wno-unused-parameter \
	    -I "$tmp" -o "$tmp/ccmslock" "$tmp/hammer2-ccms-lock.c" 2>"$tmp/cc.log"
then
	echo "ccms-lock: FAIL: the probe did not compile" >&2
	sed 's/^/        /' "$tmp/cc.log" | head -20 >&2
	exit 1
fi

if ! "$tmp/ccmslock"; then
	echo "ccms-lock: FAIL"
	exit 1
fi

# The control.  A probe whose extraction silently produced empty
# functions would compile and report zero releases on every path, which
# reads as a pass.  The count on the good path is the evidence that the
# extracted text runs, and it is asserted in the probe itself; this
# asserts the extraction found the fix, by requiring the two bad-state
# arms to carry the return the fix added.
n=$(extract ccms_thread_lock | command grep -c 'hpanic returns')
m=$(extract ccms_thread_lock_nonblock | command grep -c 'hpanic returns')
if [ "$n" -ne 1 ] || [ "$m" -ne 1 ]; then
	echo "ccms-lock: FAIL: the bad-state arms do not return after hpanic()" >&2
	echo "        ccms_thread_lock $n, ccms_thread_lock_nonblock $m (expected 1 each)" >&2
	exit 1
fi

echo "ccms-lock: 5 check(s), 0 failed"
exit 0
