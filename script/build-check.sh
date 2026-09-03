#!/bin/sh
#
# Build the module and require the build to be warning-clean.
#
# This lived inline in .github/workflows/ci.yml, in one job. It is two jobs
# now, the kernel of record and the declared floor, and a check copied into
# a second caller is a check that can rot in one copy while the other stays
# right. It is also the only place the warning pattern is written, and that
# pattern has already been wrong once: a bare "warning:" matched kbuild's
# banner about the runner's compiler differing from the kernel's, which is a
# fact about the machine and not a diagnostic about this code, and it failed
# the step for two runs while the build itself was clean.
#
# Usage: script/build-check.sh [KDIR]
#
# With no argument it builds against /lib/modules/$(uname -r)/build, which
# is what a developer runs. Exit 0 clean, 1 a real failure, 2 COULD-NOT-RUN
# when there is no build directory to compile against, which is neither.

set -u

KDIR=${1:-/lib/modules/$(uname -r)/build}

if [ ! -f "$KDIR/Makefile" ]; then
	echo "build-check: COULD-NOT-RUN: no kernel build tree at $KDIR" >&2
	exit 2
fi

log=$(mktemp) || exit 2
trap 'rm -f "$log"' EXIT

make KDIR="$KDIR" > "$log" 2>&1
rc=$?
if [ "$rc" != 0 ]; then
	echo "build-check: FAIL: the module did not build against $KDIR"
	command grep -E "^ERROR|error:" "$log" | head -20
	exit 1
fi

# Every compiler diagnostic carries file:line:column and kbuild's banner does
# not. A warning raised inside a kernel header still matches, deliberately:
# it is raised by this code including that header.
pat='^[^ ].*:[0-9][0-9]*:[0-9][0-9]*: warning:'

# The pattern is checked against a line built to match before it is trusted
# on a log that should have none, since "no warnings" and "the pattern
# stopped matching" print the same number.
if ! printf 'f.c:1:1: warning: x\n' | command grep -qE "$pat"; then
	echo "build-check: FAIL: the warning pattern no longer matches a warning," >&2
	echo "             so a count of zero below would prove nothing" >&2
	exit 1
fi

# grep -c prints 0 and exits 1, so the count is captured and the status
# discarded rather than read as the verdict.
n=$(command grep -cE "$pat" "$log")
if [ "$n" != 0 ]; then
	echo "build-check: FAIL: $n warning(s) building against $KDIR"
	command grep -E "$pat" "$log" | head -20
	exit 1
fi

ko=src/sys/fs/hammer2/hammer2.ko
if [ ! -f "$ko" ]; then
	echo "build-check: FAIL: the build reported success and there is no $ko"
	exit 1
fi

echo "build-check: links warning-clean against $KDIR"
