#!/usr/bin/env bash
# Kernel style, bounded rather than clean.
#
# This tree is BSD style, because it carries DragonFly code and tracks
# Kusumi's BSD ports: `return (x);`, typedef'd lock types, tabs at four
# columns of intent. Converting that now would create a large diff against
# the trees this port is meant to stay readable beside, and buy nothing
# until an actual mainline submission, which converts the whole thing in
# one mechanical pass.
#
# So the gate is not "checkpatch is silent". It is "the deviation set is
# the one we recorded, and it did not grow". A new category, or more hits
# in an existing one, fails. doc/README.kernel-style.md lists them.
#
# Exit 2 is COULD-NOT-RUN: no checkpatch.pl. Point CHECKPATCH at one, or
# set KDIR to a full kernel source tree.
#
# LC_ALL=C on both sorts, because the baseline is compared byte for byte
# and glibc collation differs between machines: the first CI run failed
# with every count identical and four lines in a different order.
set -u
cd "$(dirname "$0")/.." || exit 2

CP=${CHECKPATCH:-}
[ -n "$CP" ] || CP=${KDIR:-/lib/modules/$(uname -r)/build}/scripts/checkpatch.pl
[ -f "$CP" ] || { echo "checkpatch: COULD-NOT-RUN: no checkpatch.pl at $CP"; exit 2; }
command -v perl >/dev/null 2>&1 || { echo "checkpatch: COULD-NOT-RUN: no perl"; exit 2; }

files=$(ls src/sys/fs/hammer2/*.c src/sys/fs/hammer2/*.h)
got=$(perl "$CP" --no-tree --file --terse --no-summary $files 2>/dev/null |
	sed 's/^.*: \(WARNING\|ERROR\): //' |
	sed "s/'[^']*'/'X'/g" |
	LC_ALL=C sort | uniq -c | awk '{$1=$1; print}' | LC_ALL=C sort -k2)

base=doc/checkpatch-baseline.txt
[ -f "$base" ] || { echo "checkpatch: no baseline; writing one"; printf '%s\n' "$got" > "$base"; exit 0; }

if diff -u "$base" <(printf '%s\n' "$got"); then
	echo "checkpatch: deviation set unchanged ($(printf '%s\n' "$got" | awk '{s+=$1} END{print s+0}') hits)"
else
	echo "checkpatch: the deviation set MOVED. If the change is deliberate,"
	echo "            update doc/checkpatch-baseline.txt and say why in"
	echo "            doc/README.kernel-style.md."
	exit 1
fi
