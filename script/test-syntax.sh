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

# --selftest: A PRINT WITH NO TEST IS A CLAIM ABOUT OUTPUT NOBODY CHECKS.
# The override warning below is the only thing separating a loosened run
# from a real one, it was added on 2026-08-26 to fix exactly that class,
# and nothing read it - the defect arriving inside its own repair. This
# runs the gate against the local tree under H2_KERNEL_REF and requires the
# warning, then requires an unoverridden run not to carry it. Two seconds.
if [ "${1:-}" = "--selftest" ]; then
	k=${KDIR:-/lib/modules/$(uname -r)/build}
	[ -f "$k/Makefile" ] || { echo "selftest: COULD-NOT-RUN: no kernel tree"; exit 2; }
	lv=$(sed -n 's/^VERSION *= *//p' "$k/Makefile" | head -1)
	lp=$(sed -n 's/^PATCHLEVEL *= *//p' "$k/Makefile" | head -1)
	# NORMALIZED FIRST, because the warning WRAPS: "WHICH IS NOT" ends one
	# line and "THE KERNEL OF RECORD" starts the next, so a line-at-a-time
	# matcher reports the warning missing while it is plainly there. This
	# fixture failed that way on its first run, which is the same defect
	# the inventory gate's document reader was fixed for hours earlier -
	# a rule about matching wrapped prose did not fire while writing a
	# matcher for wrapped prose.
	flat() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' '; }
	out=$(H2_KERNEL_REF="$lv.$lp" sh "$0" 2>&1)
	if flat "$out" | command grep -q 'NOT THE KERNEL OF RECORD'; then
		echo "  ok    an overridden run says so in its summary"
	else
		echo "  FAIL  an overridden run printed no override warning:"
		printf '%s\n' "$out" | tail -2 | sed 's/^/        /'
		exit 1
	fi
	# The other direction. On a machine whose tree IS the kernel of record
	# this is the meaningful half; here that run is COULD-NOT-RUN, which
	# also carries no warning, so this is weaker than it looks and says so.
	out2=$(sh "$0" 2>&1)
	if flat "$out2" | command grep -q 'NOT THE KERNEL OF RECORD'; then
		echo "  FAIL  an unoverridden run carried the override warning"
		exit 1
	fi
	echo "  ok    an unoverridden run does not (weak here: it is COULD-NOT-RUN)"

	# A GUARD NOBODY DESIGNED IS A GUARD NOBODY MAINTAINS. This gate reads
	# VERSION and PATCHLEVEL from a build tree's own Makefile, so the
	# linux-api-headers package - 7.2-1 here, giving
	# /usr/include/linux/version.h a LINUX_VERSION_MAJOR of 7 and a
	# PATCHLEVEL of 2 with no Makefile and nothing to compile against -
	# cannot satisfy it. That immunity was luck of construction until this
	# check existed. A UAPI-shaped tree is the specimen: it answers the
	# version question correctly and about a different subject, which is
	# worse than an inert reading because it VARIES properly and would say
	# 7.3 the day Artix ships 7.3, so even a longitudinal check confirms it.
	fake=$(mktemp -d) || exit 2
	mkdir -p "$fake/include/linux"
	printf '#define LINUX_VERSION_MAJOR 7\n#define LINUX_VERSION_PATCHLEVEL 2\n' \
		> "$fake/include/linux/version.h"
	out3=$(KDIR="$fake" sh "$0" 2>&1); rc3=$?
	rm -rf "$fake"
	if [ "$rc3" = 2 ] && flat "$out3" | command grep -q 'COULD-NOT-RUN'; then
		echo "  ok    a UAPI-shaped tree claiming 7.2 is COULD-NOT-RUN, not a pass"
	else
		echo "  FAIL  a tree with only a version.h was accepted (rc=$rc3):"
		printf '%s\n' "$out3" | tail -2 | sed 's/^/        /'
		exit 1
	fi
	echo "selftest: 3 check(s), 0 failed"
	exit 0
fi

# WHICH BRANCH WAS TAKEN, NOT WHICH ONE WOULD BE. A fallback that has never
# fired is indistinguishable from a fallback that works, and this one had
# never fired: IO_MODEL.md described the nix-store branch as the source of
# the kernel of record while /lib/modules/$(uname -r)/build was present on
# every run, so the document and this script agreed in wording and
# disagreed in behaviour with nothing between them to notice. The
# resolution is reported in the header line now, so every run says which
# path it took, including the runs delegated from another repository.
if [ -n "${KDIR:-}" ]; then
	K=$KDIR; ksrc="KDIR"
else
	K=/lib/modules/$(uname -r)/build; ksrc="/lib/modules/\$(uname -r)/build"
fi
if [ ! -d "$K" ]; then
	# Nix: the newest realized kernel dev output. Exercise this branch with
	# KDIR pointing at a path that does not exist.
	K=$(ls -d /nix/store/*-linux-*-dev/lib/modules/*/build 2>/dev/null | sort -V | tail -1)
	ksrc="nix store fallback"
fi
[ -n "$K" ] && [ -d "$K" ] || { echo "syntax: COULD-NOT-RUN: no kernel build dir ($ksrc)"; exit 2; }
S=$(dirname "$K")/source
[ -d "$S" ] || S=$K

# THE KERNEL OF RECORD IS THE LATEST RELEASE, AND NOTHING COMPARED IT.
# This tree compiles against the newest Linux, and the pin below is bumped
# when one ships rather than left to age; 6.15 in hammer2_os.h is the FLOOR
# the code requires and is a different claim from this one.
# This gate has always printed the kernel it used in its header line, and
# every document said the port is developed against 7.2, and nothing put
# those two strings next to each other. On this workstation the newest tree
# is 7.1.9 - there is no 7.2 in /lib/modules, /usr/src or the store - so
# every green run here was measured against a kernel that is not the one of
# record, and read as though it were. The header line was not hiding it.
# Nobody reads a header line for a verdict; they read "0 failed".
#
# So a tree that is not the kernel of record is COULD-NOT-RUN, the same
# status test-checkpatch.sh gives a checkpatch.pl that is not the baseline's
# version, and for the same reason: a result produced by the wrong
# instrument cannot be attributed to the code. Set H2_KERNEL_REF to compile
# against another version deliberately - it must be typed, so a wrong tree
# can never be mistaken for a pass.
#
# BUMPING THIS IS THE WHOLE MAINTENANCE BURDEN AND IT IS ONE LINE: when a
# new Linux ships, install its headers, raise KERNEL_REF, run this gate.
# A pin that is not bumped stops the gate rather than quietly aging, which
# is the direction that gets noticed.
KERNEL_REF=7.2
kver=""
if [ -f "$K/Makefile" ]; then
	v=$(sed -n 's/^VERSION *= *//p' "$K/Makefile" | head -1)
	pl=$(sed -n 's/^PATCHLEVEL *= *//p' "$K/Makefile" | head -1)
	[ -n "$v" ] && [ -n "$pl" ] && kver="$v.$pl"
fi
want=${H2_KERNEL_REF:-$KERNEL_REF}
if [ -z "$kver" ]; then
	echo "syntax: COULD-NOT-RUN: no VERSION/PATCHLEVEL in $K/Makefile, so" >&2
	echo "  the kernel of record ($want) cannot be confirmed" >&2
	exit 2
fi
if [ "$kver" != "$want" ]; then
	echo "syntax: COULD-NOT-RUN: this tree is linux $kver and the kernel of" >&2
	echo "  record is $want. A pass here would be a claim about the wrong" >&2
	echo "  kernel. Point KDIR at a $want tree, or set H2_KERNEL_REF=$kver" >&2
	echo "  to check that version deliberately." >&2
	echo "  $K" >&2
	exit 2
fi

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
# An absent .config leaves this empty, and empty is also what a kernel that
# does not need the flag produces. The two are indistinguishable in the
# variable and distinguishable here, so say which.
if [ -f "$K/.config" ]; then
	dsrc="${DIALECT:-none needed}"
else
	dsrc="UNKNOWN, no .config in the tree"
fi

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

echo "hammer2 against $(basename "$(dirname "$K")") via $ksrc, dialect $dsrc, with $("$CC" --version | head -1):"
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

# AN OVERRIDDEN RUN MUST NOT PRINT WHAT A REAL ONE PRINTS. Until 2026-08-26
# it did, byte for byte: "syntax: 7 check(s), 0 failed" whether the tree was
# the kernel of record or a version somebody typed into H2_KERNEL_REF to get
# a green line. Every such line reported from this workstation that day came
# from an overridden run, because there is no 7.2 tree here - so the summary
# was true about the checks and silent about what they were checked against.
# The override is the loosened threshold; the summary is where it hides.
if [ "$want" != "$KERNEL_REF" ]; then
	echo "syntax: $ran check(s), $fail failed AGAINST LINUX $want, WHICH IS NOT"
	echo "        THE KERNEL OF RECORD ($KERNEL_REF). H2_KERNEL_REF was set, so"
	echo "        this run is a reading about $want and not evidence about the"
	echo "        kernel this tree targets."
else
	echo "syntax: $ran check(s), $fail failed against the kernel of record ($KERNEL_REF)"
fi
[ "$fail" = 0 ]
