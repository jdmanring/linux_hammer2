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

CC=${CC:-clang}
command -v "$CC" >/dev/null 2>&1 || { echo "syntax: COULD-NOT-RUN: no $CC"; exit 2; }
RES=$("$CC" -print-file-name=include)

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
	-I src/sys/fs/hammer2 -I src/sys -I test)

fail=0 ran=0
check() { # name expect file cflags...
	local name="$1" expect="$2" file="$3"; shift 3
	ran=$((ran + 1))
	if "$CC" "${CFLAGS[@]}" "$@" "$file" >/tmp/h2syn.$$ 2>&1; then got=pass; else got=fail; fi
	if [ "$got" = "$expect" ]; then echo "  ok    $name ($expect)"
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

echo "syntax: $ran check(s), $fail failed"
[ "$fail" = 0 ]
