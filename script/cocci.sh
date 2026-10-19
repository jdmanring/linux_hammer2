#!/bin/bash
# The kernel's Coccinelle semantic patches (make coccicheck) over the
# module, one patch at a time: coccicheck's own loop ends the sweep at the
# first patch that cannot run, and one patch here needs an OCaml compiler.
# Not a gate, for analyze.sh's reason: the carried core keeps upstream's
# lines, so a report is a candidate list to triage against the origin tree
# in doc/history/verification-record.md.
#
#   KDIR=~/kernels/linux-7.3 bash script/cocci.sh
#
# 73 of the kernel's 76 patches report through python rules, which import
# coccilib, and the coccinelle-bin package does not install it: point
# COCCINELLE_HOME at an unpacked release, the directory that holds
# python/coccilib. The two patches with OCaml rules need an ocamlopt
# matching spatch's own build and are listed as not run without one.
# Exit 2 when nothing can run; 1 when a control fails, a patch fails for
# any other reason, or spatch raised on a file.
set -u
ROOT=$(git rev-parse --show-toplevel) || exit 2
cd "$ROOT" || exit 2
K=${KDIR:-/lib/modules/$(uname -r)/build}
M=$ROOT/src/sys/fs/hammer2
[ -d "$K/scripts/coccinelle" ] || { echo "cocci: COULD-NOT-RUN: KDIR=$K has no scripts/coccinelle" >&2; exit 2; }
grep -q '^PATCHLEVEL = 3' "$K/Makefile" && grep -q '^VERSION = 7' "$K/Makefile" ||
	{ echo "cocci: COULD-NOT-RUN: KDIR is not 7.3, the kernel of record" >&2; exit 2; }
command -v spatch >/dev/null || { echo "cocci: COULD-NOT-RUN: no spatch" >&2; exit 2; }
T=$(mktemp -d) || exit 2
trap 'rm -rf "$T"' EXIT
mkdir "$T/py" "$T/ctl"
printf '@script:python@\n@@\nimport coccilib\n' > "$T/py/py.cocci"
echo 'int f(void);' > "$T/py/py.c"
spatch --very-quiet --cocci-file "$T/py/py.cocci" "$T/py/py.c" >/dev/null 2>&1 ||
	{ echo "cocci: COULD-NOT-RUN: spatch cannot import coccilib; set COCCINELLE_HOME" >&2; exit 2; }
# spatch cannot parse a structure whose member is a BSD queue macro, and
# then knows none of its fields' types, which a patch matching on a type
# needs. These are the member forms the vendored queue.h and tree.h give
# the core's structures; the whole headers do not parse as a macro file.
printf '%s\n' \
	'#define TAILQ_ENTRY(t) struct { struct t *tqe_next; struct t **tqe_prev; }' \
	'#define TAILQ_HEAD(n, t) struct n { struct t *tqh_first; struct t **tqh_last; }' \
	'#define LIST_ENTRY(t) struct { struct t *le_next; struct t **le_prev; }' \
	'#define BSD_LIST_HEAD(n, t) struct n { struct t *lh_first; }' \
	'#define RB_ENTRY(t) struct { struct t *rbe_left; struct t *rbe_right; struct t *rbe_parent; int rbe_color; }' \
	'#define RB_HEAD(n, t) struct n { struct t *rbh_root; }' > "$T/macros.h"
# coccicheck exits 0 without running anything when DEBUG_FILE exists, so
# every run gets a name no earlier run used, and a run counts only when
# coccicheck wrote the spatch command line into that file. The caller
# advances i: check() runs in a command substitution, a subshell, and a
# count kept there never reaches the next call. spatch exits 0 when it
# raises on one file and drops that file's reports, writing an EXN line
# into the same file, so raised() is read after every run.
i=0
check() {
	make -s -C "$K" M="$1" coccicheck MODE=report ${J:+J=$J} COCCI="$2" \
		SPFLAGS="--macro-file $T/macros.h" DEBUG_FILE="$T/$i.err" 2>&1
}
ran_spatch() { grep -q '^/[^ ]*spatch ' "$T/$i.err" 2>/dev/null; }
raised() { grep '^EXN' "$T/$i.err" 2>/dev/null; }
# The controls go through the same make target with python report rules.
# A planted NULL check before kfree must be reported, or a clean list says
# only that the patches ran. Then a rule that raises on boom.c alone must
# be read as raised while ctl.c beside it is still reported, or a file
# spatch dropped would read as clean.
printf 'void kfree(const void *);\nvoid f(void *p)\n{\n\tif (p)\n\t\tkfree(p);\n}\n' > "$T/ctl/ctl.c"
cp "$T/ctl/ctl.c" "$T/ctl/boom.c"
printf '%s\n' 'virtual report' '@r depends on report@' 'position p;' '@@' 'kfree@p(...)' '' \
	'@script:python depends on report@' 'p << r.p;' '@@' \
	'if p[0].file.endswith("boom.c"):' '    raise Exception("planted")' \
	'coccilib.report.print_report(p[0], "planted")' > "$T/boom.cocci"
i=$((i + 1))
out=$(check "$T/ctl" "$K/scripts/coccinelle/free/ifnullfree.cocci")
if printf '%s\n' "$out" | grep -q '^\./ctl\.c:5:' && ran_spatch; then
	echo "  ok    control: a planted NULL check before kfree is reported"
else echo "  FAIL  control: the planted NULL check before kfree was not reported"; exit 1; fi
i=$((i + 1))
out=$(check "$T/ctl" "$T/boom.cocci")
if printf '%s\n' "$out" | grep -q '^\./ctl\.c:5:' && raised | grep -q 'boom\.c'; then
	echo "  ok    control: a rule that raised on one file is reported as raised"
else echo "  FAIL  control: the planted raise was not reported"; exit 1; fi
# How much of each file spatch parsed, headers included since the patches
# read them: a function it cannot parse is matched by no patch and reads as
# clean, and a census that did not run must not read as one with nothing in
# it. The files are named here rather than found, since under --dir, which
# coccicheck uses, spatch passes over a file it cannot read without a word.
files=$(git ls-files 'src/sys/fs/hammer2/*.[ch]' | xargs -n1 basename)
nfiles=$(printf '%s\n' "$files" | grep -c .)
[ "$nfiles" -gt 0 ] || { echo "cocci: COULD-NOT-RUN: no source under src/sys/fs/hammer2" >&2; exit 2; }
(cd "$M" && spatch --parse-c --no-includes --macro-file "$T/macros.h" $files) > "$T/parse" 2>&1
s=$?
nb=$(grep -m1 'nb bad' "$T/parse")
tot=$(sed -n 's/^NB total files = \([0-9]*\);.*/\1/p' "$T/parse")
[ $s -eq 0 ] && [ -n "$nb" ] && [ "$tot" = "$nfiles" ] || {
	echo "cocci: COULD-NOT-RUN: the parse census exited $s and read ${tot:-no} of $nfiles files: $(tail -n 1 "$T/parse")" >&2; exit 2; }
echo "  parse: $nfiles files, $nb"
sed -n 's/^ = File "\(.*\)", line \([0-9]*\),.*/        unparsed: \1:\2/p' "$T/parse"
n=0 ran=0 notrun=0 bad=0 skip=0
for f in $(find "$K/scripts/coccinelle" -name '*.cocci' -type f | sort); do
	p=${f#"$K/scripts/coccinelle/"}
	grep -q 'virtual[[:space:]]\+report' "$f" || { skip=$((skip + 1)); continue; }
	i=$((i + 1))
	out=$(check "$M" "$f"); rc=$?
	if [ $rc -ne 0 ] || ! ran_spatch; then
		# Two reasons are this machine's configuration and not the
		# module's: no OCaml compiler, and coccicheck's own skip of a
		# patch that requires a newer spatch, which it prints and exits
		# 0 on. Any other reason fails the run.
		why=$(grep -v -m1 '^/' "$T/$i.err" 2>/dev/null)
		[ -n "$why" ] || why=$(printf '%s\n' "$out" | grep -m1 'requires:')
		case $why in
		*'No OCaml compiler found'*|*'requires:'*) notrun=$((notrun + 1)) ;;
		*) bad=$((bad + 1)); why="FAIL ${why:-no spatch run recorded}" ;;
		esac
		echo "  not run  $p: $why"
		continue
	fi
	ran=$((ran + 1))
	exn=$(raised)
	if [ -n "$exn" ]; then
		bad=$((bad + 1))
		echo "  FAIL  $p: spatch raised and dropped what it found in that file"
		printf '%s\n' "$exn" | sed 's/^/        /'
	fi
	hits=$(printf '%s\n' "$out" | grep -E '^\./[^ ]+:[0-9]+')
	[ -n "$hits" ] || continue
	n=$((n + $(printf '%s\n' "$hits" | wc -l)))
	echo "  $p"; printf '%s\n' "$hits" | sed 's/^/        /'
done
echo "cocci: $n candidate(s) from $ran patch(es), $notrun not run, $bad failed, $skip without a report mode; triage each against the origin tree"
[ $ran -gt 0 ] || exit 2
[ $bad -eq 0 ] || exit 1
