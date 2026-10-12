#!/bin/sh
# A kernel report committed under doc/history/kernel-reports/ is evidence,
# so it must be the whole capture and not an extract of one.
#
# Why it exists. The empty-base fault was attributed for two days to the
# unmount teardown on the strength of call-trace frames that the committed
# evidence file does not contain: that file is a 232-line slice holding 219
# `hammer2_base_delete` lines and the ten lines after them, with no trace at
# all. The claim and its evidence were read as one artifact, and the whole
# 1784-line log that decides the producer had been sitting in /tmp the whole
# time. A hand sweep cannot see this, because the extract is real evidence
# for the message it quotes; what is missing is what makes it whole.
#
# The invariant the fault carries. `hpanic` prints its message and then,
# immediately, `WARN_ONCE`'s line "device in error, see the message above",
# one per module load, so a capture that includes a fault's message and runs
# past the boot must include that line or the capture was cut. The two
# faults in this tree's reports carry 219 and 1 messages against 1 companion
# line each; the extract carries 219 against 0. That is the whole test, and
# it is a property of the macro, not of any one log.
#
# The second failure shape is a report cited nowhere. Three of the four
# reports here are named by a document or a script and one is the extract
# that was cited AS the whole log.
#
# Exit 2 means the population is empty, which would make a clean run a claim
# about nothing.
set -u

# The selftest runs BEFORE the chdir into the repository, because it drives
# this script against a fixture in its own temporary tree: with the chdir
# first, every direction below would read this repository instead of the
# fixture and three of the four would report the same real finding, which is
# what the first version of this gate did.

# --selftest drives every direction this gate can fail in, on a fixture
# rather than on this repository, so it asserts the gate and not today's
# files. CI enumerates the gates carrying one by matching this line.
if [ "${1:-}" = "--selftest" ]; then
	here=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
	t=$(mktemp -d) || exit 2
	trap 'rm -rf "$t"' EXIT
	mkdir -p "$t/doc/history/kernel-reports" "$t/script"
	# The copy is what makes the inner call read the fixture: the gate
	# resolves its root from its own path, so invoked in place it would
	# chdir back to this repository and test that instead, which is what
	# the first version of this selftest did for three of four directions.
	# The target is stated, not "$t/script", because an earlier version put
	# the directory in the source list as well and cp warned that the file
	# and its copy were the same file, which read as a broken gate.
	cp "$here" "$t/script/test-report.sh" 2>/dev/null ||
	    { echo "  FAIL selftest: could not stage the gate at $t/script" >&2; exit 2; }
	# A whole capture: a fault's message, the companion line, and a trace.
	cat > "$t/doc/history/kernel-reports/whole.txt" <<-'EOF'
	[  1.000000] hammer2: hammer2_base_delete: delete indirect elm 8100000000000000/56 from empty base 0000000000000000/0 not found at 128/128
	[  1.001000] hammer2: device in error, see the message above
	[  1.002000] Call Trace:
	EOF
	# A report with no fault in it at all, which the check must not touch.
	cat > "$t/doc/history/kernel-reports/clean.txt" <<-'EOF'
	[  1.000000] hammer2: loading out-of-tree module taints kernel.
	EOF
	printf '%s\n' "see doc/history/kernel-reports/whole.txt and clean.txt" > "$t/doc/README.fixture.md"
	sfail=0
	run() {	# run <expected-exit> <name>
		( cd "$t" && sh script/test-report.sh >/dev/null 2>&1 )
		got=$?
		if [ "$got" -ne "$1" ]; then
			echo "  FAIL selftest: $2: expected exit $1, got $got"
			sfail=$((sfail + 1))
		else
			echo "  ok   selftest: $2 (exit $got)"
		fi
	}
	run 0 "a whole capture and a clean report pass"
	# The same message with the companion line cut, and cited, so the only
	# direction under test is the cut and not the citation.
	cat > "$t/doc/history/kernel-reports/extract.txt" <<-'EOF'
	[  1.000000] hammer2: hammer2_base_delete: delete indirect elm 8100000000000000/56 from empty base 0000000000000000/0 not found at 128/128
	EOF
	printf '%s\n' "see doc/history/kernel-reports/extract.txt" >> "$t/doc/README.fixture.md"
	run 1 "an extract with the companion line cut fails"
	rm "$t/doc/history/kernel-reports/extract.txt"
	# A whole capture that nothing names.
	mv "$t/doc/history/kernel-reports/whole.txt" \
	   "$t/doc/history/kernel-reports/whole2.txt"
	run 1 "a report cited nowhere fails"
	rm -f "$t/doc/history/kernel-reports"/*
	run 2 "an empty population is COULD-NOT-RUN, never a pass"
	[ "$sfail" -eq 0 ] || exit 1
	echo "report: selftest: 4 direction(s), 0 failed"
	exit 0
fi

cd "$(dirname "$0")/.." || exit 2

RDIR=doc/history/kernel-reports
[ -d "$RDIR" ] || { echo "report: COULD-NOT-RUN: no $RDIR" >&2; exit 2; }

# The population is asserted before it is checked, so a directory that
# matched nothing cannot report clean. The count is kept and the status
# discarded, since grep prints its count and exits 1 on no match.
nreport=0
for f in "$RDIR"/*; do
	[ -f "$f" ] || continue
	nreport=$((nreport + 1))
done
if [ "$nreport" -eq 0 ]; then
	echo "report: COULD-NOT-RUN: no file under $RDIR, so this gate" >&2
	echo "         would report clean having read nothing" >&2
	exit 2
fi

fail=0
for f in "$RDIR"/*; do
	[ -f "$f" ] || continue
	base=$(basename "$f")
	msgs=$(command grep -cE 'hammer2: .*(not found at|overlapping at|flush depth limit|bad blockref|maxloops)' "$f" 2>/dev/null || true)
	comp=$(command grep -c 'device in error, see the message above' "$f" 2>/dev/null || true)
	if [ "${msgs:-0}" -gt 0 ] && [ "${comp:-0}" -eq 0 ]; then
		echo "  FAIL $base: carries ${msgs} hpanic message(s) and not the"
		echo "        'device in error, see the message above' line hpanic"
		echo "        prints with them, so this capture was cut somewhere"
		echo "        after the fault. Commit the whole log, not the block."
		fail=$((fail + 1))
	fi
	# Named by a document or a script that is not the report itself.
	if ! command grep -rqF -- "$base" doc/ README.md CHANGELOG.md CONTRIBUTING.md 2>/dev/null; then
		echo "  FAIL $base: no document names it, so nothing here says"
		echo "        where it stands or what it is evidence for"
		fail=$((fail + 1))
	fi
done

echo "report: $nreport file(s), $fail finding(s)"
[ "$fail" = 0 ]
