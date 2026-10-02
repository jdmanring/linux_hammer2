#!/bin/bash
# clang's static analyzer over the port's own files, with the syntax
# gate's kernel flag set, so a path-sensitive reader sees what two
# compilers and sparse cannot: a store never read, a shift past the
# type, a null reaching a string function. Not a gate: the carried core
# carries upstream's dead stores and this must not ask for them to be
# edited, so the reading is a candidate list to triage against the
# origin tree, and the triage is what the verification record keeps.
#
#   KDIR=~/kernels/linux-7.3-rc5 bash script/analyze.sh [file...]
#
# Exit 2 without a kernel tree or clang. The first run, 2026-09-26, is in
# doc/history/verification-record.md with each candidate's disposition.
set -u
ROOT=$(git rev-parse --show-toplevel) || exit 2
cd "$ROOT" || exit 2
K=${KDIR:-/lib/modules/$(uname -r)/build}
[ -f "$K/Makefile" ] || { echo "analyze: COULD-NOT-RUN: KDIR=$K is not a build tree" >&2; exit 2; }
command -v clang >/dev/null || { echo "analyze: COULD-NOT-RUN: no clang" >&2; exit 2; }
grep -q '^PATCHLEVEL = 3' "$K/Makefile" && grep -q '^VERSION = 7' "$K/Makefile" ||
	{ echo "analyze: COULD-NOT-RUN: KDIR is not 7.3, the kernel of record" >&2; exit 2; }
RES=$(clang -print-resource-dir)/include
DIALECT=$(sed -n 's/^CONFIG_CC_MS_EXTENSIONS=//p' "$K/.config" | tr -d '"')
FLAGS=(--analyze -Xanalyzer -analyzer-output=text --target=x86_64-linux-gnu -std=gnu11 $DIALECT
	-Wno-gnu -Wno-microsoft-anon-tag -nostdinc -isystem "$RES"
	-I "$K/arch/x86/include" -I "$K/arch/x86/include/generated" -I "$K/include"
	-I "$K/arch/x86/include/uapi" -I "$K/arch/x86/include/generated/uapi" -I "$K/include/uapi"
	-I "$K/include/generated/uapi"
	-include "$K/include/linux/compiler-version.h" -include "$K/include/linux/kconfig.h"
	-include "$K/include/linux/compiler_types.h"
	-D__KERNEL__ -DMODULE -DKBUILD_MODNAME='"hammer2"' -DCC_USING_FENTRY
	-mcmodel=kernel -mno-red-zone -mno-sse -mno-mmx -fno-PIE -fno-strict-aliasing
	-Xanalyzer -analyzer-checker=core,unix,deadcode -Wno-everything
	-I src/sys/fs/hammer2 -I src/sys)
run() { clang "${FLAGS[@]}" -DKBUILD_BASENAME="\"$(basename "$1" .c)\"" "$1" 2>&1 |
	grep -E 'warning:|error:' | grep -v '/include/' | sort -u; }
# The control: a planted null dereference must be reported, or a clean
# list below says only that the analyzer ran.
ctl=$(mktemp --suffix=.c); printf 'int f(void){int *p=0;return *p;}\n' > "$ctl"
if run "$ctl" | grep -q 'null pointer'; then echo "  ok    control: a planted null dereference is reported"
else echo "  FAIL  control: the planted null dereference was not reported"; rm -f "$ctl"; exit 1; fi
rm -f "$ctl"
[ $# -gt 0 ] || set -- src/sys/fs/hammer2/hammer2_io.c src/sys/fs/hammer2/hammer2_vnops.c \
	src/sys/fs/hammer2/hammer2_strategy.c src/sys/fs/hammer2/hammer2_vfsops.c \
	src/sys/fs/hammer2/hammer2_ondisk.c src/sys/fs/hammer2/hammer2_ioctl.c \
	src/sys/fs/hammer2/hammer2_export.c
n=0
for f in "$@"; do
	out=$(run "$f"); c=$(printf '%s' "$out" | grep -c . || true); n=$((n + c))
	echo "  $f: $c candidate(s)"; [ -n "$out" ] && printf '%s\n' "$out" | sed 's/^/        /'
done
echo "analyze: $n candidate(s) over $# file(s); triage each against the origin tree"
