#!/usr/bin/env bash
# The OS shim is valid C and both branches of the knob compile.
#
# Proves: hammer2_os.h and hammer2_compat.h parse, their macros and braces
# balance, and every static inline they define is internally consistent.
# Every inline is referenced from test/syntax-check.c, because an unused
# static inline in a header is not fully checked by every compiler and a
# gate that skips half the file reads the same as one that passes.
#
# Cannot prove: that any kernel function is called correctly, or that the
# header compiles against a real kernel. It runs against test/stub, and a
# stub agreeing with the shim proves the two agree with each other.
# script/test-syntax.sh answers the rest.
#
# Needs nothing but a C compiler.
set -u
cd "$(dirname "$0")/.." || exit 2
CC=${CC:-cc}
command -v "$CC" >/dev/null 2>&1 || { echo "shim: no $CC"; exit 2; }

fail=0 ran=0
check() { # name expect cflags... source
	local name="$1" expect="$2"; shift 2
	ran=$((ran + 1))
	if $CC -fsyntax-only -std=gnu11 -I test/stub "$@" >/tmp/h2shim.$$ 2>&1
	then got=pass; else got=fail; fi
	if [ "$got" = "$expect" ]; then echo "  ok    $name ($expect)"
	else
		echo "  FAIL  $name: expected $expect, got $got"
		sed 's/^/        /' /tmp/h2shim.$$ | head -5
		fail=$((fail + 1))
	fi
	rm -f /tmp/h2shim.$$
}

# WHICH COMPILER, because the default and a deliberate run answer different
# questions and the output could not say which happened. cc here is gcc and
# a reviewer reaching for clang gets a different opinion by construction -
# that difference is the whole reason the syntax gate runs two of them.
echo "hammer2 shim, syntax and guards, with $("$CC" --version | head -1):"
check "compiles, invariants off" pass -Wall -Wextra -Wno-unused-parameter test/syntax-check.c
check "compiles, invariants on"  pass -Wall -Wextra -Wno-unused-parameter -DHAMMER2_INVARIANTS test/syntax-check.c

# Negative control. A syntax gate whose healthy signature is silence
# cannot be told from one that never opened the file, so break the header
# on a copy and require the failure.
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
cp -r src test "$tmp/" || exit 2
sed -i 's/^hammer2_mtx_refs(hammer2_mtx_t \*p)$/hammer2_mtx_refs(hammer2_mtx_t *p) THIS_IS_NOT_C/' \
	"$tmp/src/sys/fs/hammer2/hammer2_os.h"
ran=$((ran + 1))
if $CC -fsyntax-only -std=gnu11 -I "$tmp/test/stub" "$tmp/test/syntax-check.c" \
	>/dev/null 2>&1; then
	echo "  FAIL  negative control: a broken header still passed, so this"
	echo "        gate is not reading the header it claims to check"
	fail=$((fail + 1))
else
	echo "  ok    negative control (a broken header fails)"
fi

echo "shim: $ran check(s), $fail failed"
[ "$fail" = 0 ]
