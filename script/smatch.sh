#!/bin/sh
# smatch over the module through kbuild's own checker hook, the way the
# kernel's smatch_scripts/kchecker runs it: make C=2 CHECK="smatch
# --project=kernel". It reads what sparse and clang's analyzer do not:
# a pointer tested for NULL and then dereferenced on another path, a
# double free, a missing error code.
#
# Not a gate, for the reason analyze.sh is not: the carried core carries
# upstream's own patterns, and every finding of the first run was one of
# them, so the reading is a candidate list to triage against the origin
# tree, and the triage is what doc/history/verification-record.md keeps.
#
#   KDIR=~/kernels/linux-7.3-rc5 bash script/smatch.sh
#
# A clean reading is believed only if the negative control fires first: a
# scratch module with a double free must be reported, or smatch is not
# running as a checker here and a count of zero is about nothing.
#
# Exit 2 without a kernel tree or a smatch binary (H2_SMATCH, or a build at
# ~/Projects/smatch), 1 if the control is not reported, 0 otherwise with
# the candidates printed.
set -u
ROOT=$(git rev-parse --show-toplevel) || exit 2
K=${KDIR:-/lib/modules/$(uname -r)/build}
SM=${H2_SMATCH:-$HOME/Projects/smatch/smatch}
[ -f "$K/Makefile" ] || { echo "smatch: COULD-NOT-RUN: KDIR=$K is not a build tree" >&2; exit 2; }
[ -x "$SM" ] || { echo "smatch: COULD-NOT-RUN: no smatch at $SM" >&2; exit 2; }
CHECK="$SM --project=kernel --succeed"

ctl=$(mktemp -d) || exit 2
trap 'rm -rf "$ctl"' EXIT
cat > "$ctl/ctl.c" <<'EOF'
#include <linux/module.h>
#include <linux/slab.h>
static int __init ctl_init(void)
{
	char *p = kmalloc(16, GFP_KERNEL);

	kfree(p);
	kfree(p);
	return 0;
}
module_init(ctl_init);
MODULE_LICENSE("GPL");
EOF
echo 'obj-m := ctl.o' > "$ctl/Makefile"
make -C "$K" M="$ctl" C=2 CHECK="$CHECK" > "$ctl/out" 2>&1
if command grep -q 'error: double free' "$ctl/out"; then
	echo "  ok    negative control: smatch reports a planted double free"
else
	echo "  FAIL  negative control: smatch did not report a planted double free"
	exit 1
fi

out=$(make -C "$K" M="$ROOT/src/sys/fs/hammer2" C=2 CHECK="$CHECK" 2>&1)
n=$(printf '%s\n' "$out" | command grep -c '  CHECK ')
[ "$n" -gt 0 ] || { echo "smatch: COULD-NOT-RUN: kbuild checked no file" >&2; exit 2; }
c=$(printf '%s\n' "$out" | command grep -E ' (warn|error): ' | sed 's|^.*/hammer2/||')
printf '%s\n' "$c" | command grep -v '^$' | sed 's/^/  /'
echo "smatch: $(printf '%s\n' "$c" | command grep -c .) candidate(s) over $n file(s); triage each against the origin tree"
