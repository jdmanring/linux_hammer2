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
command -v "$CC" >/dev/null 2>&1 || { echo "shim: COULD-NOT-RUN: no $CC"; exit 2; }

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

# Print which compiler ran. cc is gcc here, and a reviewer reaching for clang
# gets a different opinion by construction, which is why the syntax gate runs
# both.
echo "hammer2 shim, syntax and guards, with $("$CC" --version | head -1):"
check "compiles, invariants off" pass -Wall -Wextra -Wno-unused-parameter test/syntax-check.c
check "compiles, invariants on"  pass -Wall -Wextra -Wno-unused-parameter -DHAMMER2_INVARIANTS test/syntax-check.c

# Read the log prefix out of the expansion. A filesystem's log lines have to
# name the filesystem, and nothing that compiles can tell you whether they do:
# an empty pr_fmt is valid C and prints a bare message forever, which was true
# of every carried file on 2026-08-26. So both macros are preprocessed and the
# result inspected.
#
# The second half is the easier one to get wrong. printf must expand to
# pr_cont, not pr_info, because the core builds one log line out of several
# calls and pr_info would close a record between them. A missing name and a
# split line are both invisible in a compile and in a diff review.
tmp_pfx=$(mktemp -d) || exit 2
printf '#include "%s/src/sys/fs/hammer2/hammer2_os.h"\n' "$PWD" > "$tmp_pfx/pfx.c"
printf 'void f(void) { hprintf("r %%d\\n", 1); printf("(cont)\\n"); }\n' >> "$tmp_pfx/pfx.c"
ran=$((ran + 1))
if exp=$($CC -E -std=gnu11 -DKBUILD_MODNAME='"hammer2"' -I test/stub \
	"$tmp_pfx/pfx.c" 2>/dev/null | command grep 'void f(void)'); then
	if printf '%s\n' "$exp" | command grep -q 'pr_info("hammer2" ": "'; then
		echo "  ok    hprintf expansion carries the module name"
	else
		echo "  FAIL  hprintf expands without the module name, so every"
		echo "        log line this module prints is anonymous:"
		printf '%s\n' "$exp" | sed 's/^/        /'
		fail=$((fail + 1))
	fi
	ran=$((ran + 1))
	if printf '%s\n' "$exp" | command grep -q 'pr_cont("(cont)'; then
		echo "  ok    printf expands to pr_cont, so a continued line stays one line"
	else
		echo "  FAIL  printf does not expand to pr_cont, so the core's"
		echo "        multi-call log lines break into separate records:"
		printf '%s\n' "$exp" | sed 's/^/        /'
		fail=$((fail + 1))
	fi
else
	echo "  FAIL  the preprocessor produced no expansion to read"
	fail=$((fail + 1))
fi

# Negative control. A syntax gate whose healthy signature is silence
# cannot be told from one that never opened the file, so break the header
# on a copy and require the failure.
tmp=$(mktemp -d) || exit 2
# One trap, both directories. A second `trap ... EXIT` replaces the first
# instead of adding to it, so the earlier temporary would leak on every run.
trap 'rm -rf "$tmp" "$tmp_pfx"' EXIT
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
