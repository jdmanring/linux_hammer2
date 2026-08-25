#!/usr/bin/env bash
# hammer2.h and hammer2_io.c compile against the REAL kernel headers.
#
# Proves: every kernel call in the DIO layer (filemap_grab_folio,
# read_mapping_folio, folio_*, filemap_fdatawrite_range,
# BLK_MAX_BLOCK_SIZE) type-checks against the include tree this system's
# modules are built from, and that hammer2.h with the vendored sys/tree.h
# and sys/queue.h behind it expands cleanly where a header alone would
# not be exercised (test/hammer2-header.c instantiates RB_GENERATE,
# RB_SCAN and the queue and atomic families).
#
# Cannot prove: that the code is correct at runtime. -fsyntax-only
# compiles nothing and links nothing.
#
# Exit 2 is COULD-NOT-RUN: no kernel headers or no compiler. That is not
# a verdict on the files.
set -u
cd "$(dirname "$0")/.." || exit 2

K=${KDIR:-/lib/modules/$(uname -r)/build}
if [ ! -d "$K" ]; then
	# Nix: the newest realized kernel dev output.
	K=$(ls -d /nix/store/*-linux-*-dev/lib/modules/*/build 2>/dev/null | sort -V | tail -1)
fi
[ -n "$K" ] && [ -d "$K" ] || { echo "syntax: COULD-NOT-RUN: no kernel build dir"; exit 2; }
S=$(dirname "$K")/source
[ -d "$S" ] || S=$K

# TWO COMPILERS, because they disagree about what is worth saying and a
# single one is a single opinion. Both found the LIST_HEAD and RB_ROOT
# collisions independently, which is what made those credible rather than
# stylistic. gcc is optional: if it is absent the clang pass still runs and
# the count below says how many compilers were used.
CC=${CC:-clang}
command -v "$CC" >/dev/null 2>&1 || { echo "syntax: COULD-NOT-RUN: no $CC"; exit 2; }
RES=$("$CC" -print-file-name=include)
CC2=${CC2:-gcc}
command -v "$CC2" >/dev/null 2>&1 || CC2=""

# CC_FLAGS_DIALECT from the kernel's own Makefile. Linux 7.x declares
# tagged anonymous struct members (struct __filename_head in fs.h) and
# needs -fms-extensions for them; without it fs.h's own static_assert on
# sizeof(struct filename) fails and every check below reads FAIL
# uniformly, which is how this line was found.
DIALECT=$(sed -n 's/^CONFIG_CC_MS_EXTENSIONS=//p' "$K/.config" 2>/dev/null | tr -d '"')

CFLAGS=(-fsyntax-only --target=x86_64-linux-gnu -std=gnu11 $DIALECT
	-Wno-gnu -Wno-microsoft-anon-tag
	-nostdinc -isystem "$RES"
	-I "$S/arch/x86/include" -I "$K/arch/x86/include/generated"
	-I "$S/include" -I "$K/include"
	-I "$S/arch/x86/include/uapi" -I "$K/arch/x86/include/generated/uapi"
	-I "$S/include/uapi" -I "$K/include/generated/uapi"
	-include "$S/include/linux/compiler-version.h"
	-include "$S/include/linux/kconfig.h"
	-include "$S/include/linux/compiler_types.h"
	-D__KERNEL__ -DMODULE -DKBUILD_MODNAME='"hammer2"' -DKBUILD_BASENAME='"hammer2_io"'
	-mcmodel=kernel -mno-red-zone -mno-sse -mno-mmx -fno-PIE -fno-strict-aliasing
	-Wall -Werror=implicit-function-declaration -Werror=implicit-int
	-Werror=incompatible-pointer-types -Wno-unused-function
	# W=1 class. The kernel's own W=1 is a kbuild target we cannot reach
	# without building, so this is the subset that works under
	# -fsyntax-only. It is what found the two macro redefinitions.
	-Wextra -Wmissing-prototypes -Wold-style-definition
	-Wno-unused-parameter -Wno-sign-compare
	-I src/sys/fs/hammer2 -I src/sys -I test)

fail=0 ran=0
# A WARNING IN OUR OWN FILES IS A FAILURE, and it has to be counted rather
# than made fatal: -Werror would also fail on the kernel headers, which we
# do not own and cannot fix. Anchoring on `src/` is what separates the two.
check() { # name expect file cflags...
	local name="$1" expect="$2" file="$3"; shift 3
	ran=$((ran + 1))
	if "$CC" "${CFLAGS[@]}" "$@" "$file" >/tmp/h2syn.$$ 2>&1; then got=pass; else got=fail; fi
	local ours
	ours=$(command grep -c "^src/.*warning:" /tmp/h2syn.$$ || true)
	if [ "$got" = "$expect" ] && { [ "$expect" = fail ] || [ "$ours" = 0 ]; }; then
		echo "  ok    $name ($expect)"
	elif [ "$got" = "$expect" ]; then
		echo "  FAIL  $name: $expect, but $ours warning(s) in our own files"
		command grep "^src/.*warning:" /tmp/h2syn.$$ | sed 's/^/        /' | head -5
		fail=$((fail + 1))
	else
		echo "  FAIL  $name: expected $expect, got $got"
		sed 's/^/        /' /tmp/h2syn.$$ | head -8
		fail=$((fail + 1))
	fi
	rm -f /tmp/h2syn.$$
}

echo "hammer2 against $(basename "$(dirname "$K")") with $("$CC" --version | head -1):"
check "hammer2.h: header TU expands (tree, queue, atomics)" pass test/hammer2-header.c
check "hammer2_io.c: invariants on"  pass src/sys/fs/hammer2/hammer2_io.c -DHAMMER2_INVARIANTS
check "hammer2_io.c: invariants off" pass src/sys/fs/hammer2/hammer2_io.c
# Negative control: a wrong kernel call must be refused by the same
# headers, or a pass above proves only that the compiler ran. Both
# controls are prefix headers applied AFTER the kernel header they
# subvert; a -D on the command line renames the declaration too and
# passed uniformly.
check "negative control: wrong folio call refused" fail \
	src/sys/fs/hammer2/hammer2_io.c -include test/contract/ctl-wrong-call.h
# Positive control of the ceiling guard: shrink the format's buffer
# ceiling and the static_assert must fire.
check "ceiling guard fires without THP" fail \
	src/sys/fs/hammer2/hammer2_io.c -include test/contract/ctl-shrink-ceiling.h

# The second compiler, over the same two subjects. Same rule: a warning in
# our files fails, one in a kernel header does not.
if [ -n "$CC2" ]; then
	# gcc rejects clang-only flags outright rather than ignoring them, so
	# the shared array is filtered rather than duplicated: one list stays
	# the source of truth for include paths and prefix headers.
	CFLAGS2=()
	for a in "${CFLAGS[@]}"; do
		case "$a" in
			--target=*|-Wno-gnu|-Wno-microsoft-anon-tag) ;;
			*) CFLAGS2+=("$a") ;;
		esac
	done
	for f in test/hammer2-header.c src/sys/fs/hammer2/hammer2_io.c; do
		ran=$((ran + 1))
		"$CC2" "${CFLAGS2[@]}" "$f" >/tmp/h2syn2.$$ 2>&1; rc=$?
		ours=$(command grep -c "^src/.*warning:" /tmp/h2syn2.$$ || true)
		if [ "$rc" = 0 ] && [ "$ours" = 0 ]; then
			echo "  ok    $CC2: $(basename "$f") (pass)"
		else
			echo "  FAIL  $CC2: $(basename "$f") rc=$rc, $ours warning(s) in our files"
			command grep -E "^src/|error:" /tmp/h2syn2.$$ | sed 's/^/        /' | head -6
			fail=$((fail + 1))
		fi
		rm -f /tmp/h2syn2.$$
	done
else
	echo "  note  second compiler absent, one opinion only"
fi

echo "syntax: $ran check(s), $fail failed"
[ "$fail" = 0 ]
