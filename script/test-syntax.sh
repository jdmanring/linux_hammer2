#!/usr/bin/env bash
# hammer2.h and hammer2_io.c compile against the real kernel headers.
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

# --selftest. The override warning below is the only thing separating a
# loosened run from a real one, and until this existed nothing read it, so the
# repair for that class carried the defect it was fixing. This runs the gate
# against the local tree under H2_KERNEL_REF and requires the warning, then
# requires an unoverridden run not to carry it. Two seconds.
if [ "${1:-}" = "--selftest" ]; then
	k=${KDIR:-/lib/modules/$(uname -r)/build}
	[ -f "$k/Makefile" ] || { echo "selftest: COULD-NOT-RUN: no kernel tree"; exit 2; }
	lv=$(sed -n 's/^VERSION *= *//p' "$k/Makefile" | head -1)
	lp=$(sed -n 's/^PATCHLEVEL *= *//p' "$k/Makefile" | head -1)
	# Normalize first, because the warning wraps: "WHICH IS NOT" ends one
	# line and "THE KERNEL OF RECORD" starts the next, so a line-at-a-time
	# matcher reports it missing while it is plainly there. This fixture
	# failed that way on its first run, the same defect the inventory
	# gate's document reader was fixed for hours earlier.
	flat() { printf '%s' "$1" | tr '\n' ' ' | tr -s ' '; }
	out=$(H2_KERNEL_REF="$lv.$lp" bash "$0" 2>&1)
	if flat "$out" | command grep -q 'NOT THE KERNEL OF RECORD'; then
		echo "  ok    an overridden run says so in its summary"
	else
		echo "  FAIL  an overridden run printed no override warning:"
		printf '%s\n' "$out" | tail -2 | sed 's/^/        /'
		exit 1
	fi
	# The other direction, meaningful only since the kernel of record
	# arrived in the store on 2026-08-26. Before that an unoverridden run
	# was COULD-NOT-RUN and carried no warning either way, so the check
	# was vacuous and said so. Now such a run compiles and must not carry
	# the warning.
	out2=$(bash "$0" 2>&1)
	if flat "$out2" | command grep -q 'NOT THE KERNEL OF RECORD'; then
		echo "  FAIL  an unoverridden run carried the override warning"
		exit 1
	fi
	# This ran a third time and asserted nothing until 2026-08-26: it
	# tested `[ -n "$(... | grep -c ...)" ]`, and grep -c always prints a
	# number, so the condition held whatever the gate did. The run above
	# already holds the reading, and requiring it to have compiled is what
	# stops a COULD-NOT-RUN satisfying this direction trivially.
	if flat "$out2" | command grep -q 'check(s), .* failed against the kernel of record'; then
		echo "  ok    an unoverridden run compiles and does not carry it"
	elif flat "$out2" | command grep -q 'COULD-NOT-RUN'; then
		# Neither a failure nor a pass. On a machine without the kernel
		# of record, which is every hosted runner, this direction cannot
		# be exercised, and failing it there would turn an environment
		# difference into a red gate. Named rather than counted, the way
		# the gate names an absent second compiler.
		echo "  note  an unoverridden run is COULD-NOT-RUN here, so this"
		echo "        direction was NOT exercised"
	else
		echo "  FAIL  an unoverridden run neither compiled nor declined:"
		printf '%s\n' "$out2" | tail -2 | sed 's/^/        /'
		exit 1
	fi

	# A guard nobody designed is a guard nobody maintains. This gate reads
	# VERSION and PATCHLEVEL from a build tree's own Makefile, so the
	# linux-api-headers package cannot satisfy it: 7.2-1 here, giving
	# /usr/include/linux/version.h a LINUX_VERSION_MAJOR of 7 and a
	# PATCHLEVEL of 2 with no Makefile and nothing to compile against.
	# That immunity was luck of construction until this check existed. A
	# UAPI-shaped tree is the specimen because it answers the version
	# question correctly and about a different subject, and it varies
	# properly: it would say 7.3 the day Artix ships 7.3, so even a
	# longitudinal check confirms it.
	fake=$(mktemp -d) || exit 2
	mkdir -p "$fake/include/linux"
	printf '#define LINUX_VERSION_MAJOR 7\n#define LINUX_VERSION_PATCHLEVEL 2\n' \
		> "$fake/include/linux/version.h"
	out3=$(KDIR="$fake" bash "$0" 2>&1); rc3=$?
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

# Report which branch was taken, not which one would be. A fallback that has
# never fired is indistinguishable from one that works, and this one had never
# fired: IO_MODEL.md described the nix-store branch as the source of the
# kernel of record while /lib/modules/$(uname -r)/build was present on every
# run, so the document and this script agreed in wording and disagreed in
# behaviour. Every run now says which path it took, including runs delegated
# from another repository.
# The version a tree reports, following the stub a nix dev output leaves in
# build/Makefile: three lines setting KBUILD_OUTPUT and including the real
# Makefile from the source directory beside it. The stub NAMES that file,
# so it is followed instead of a sibling being assumed. linux-api-headers has
# no Makefile at all and so answers here with nothing, which keeps it out.
treemk() { # dir -> the Makefile holding the version, or empty
	mk=$1/Makefile
	[ -f "$mk" ] || return 0
	inc=$(sed -n 's/^include \(.*\/Makefile\)$/\1/p' "$mk" | head -1)
	[ -n "$inc" ] && [ -f "$inc" ] && mk=$inc
	printf '%s' "$mk"
}

treever() { # dir -> "X.Y" or empty
	mk=$(treemk "$1")
	[ -n "$mk" ] || return 0
	v=$(sed -n 's/^VERSION *= *//p' "$mk" | head -1)
	pl=$(sed -n 's/^PATCHLEVEL *= *//p' "$mk" | head -1)
	[ -n "$v" ] && [ -n "$pl" ] && printf '%s.%s' "$v" "$pl"
}

# The full release string, which is what distinguishes two trees the pin
# cannot tell apart. The pin compares VERSION and PATCHLEVEL, so a patched
# 7.3 satisfies it exactly as mainline does, and for one release the header
# line was the only place the difference appeared while the status file
# claimed the other tree.
treerel() { # dir -> "X.Y.Z<EXTRAVERSION>" or empty
	mk=$(treemk "$1")
	[ -n "$mk" ] || return 0
	v=$(sed -n 's/^VERSION *= *//p' "$mk" | head -1)
	pl=$(sed -n 's/^PATCHLEVEL *= *//p' "$mk" | head -1)
	sl=$(sed -n 's/^SUBLEVEL *= *//p' "$mk" | head -1)
	ev=$(sed -n 's/^EXTRAVERSION *= *//p' "$mk" | head -1)
	[ -n "$v" ] && [ -n "$pl" ] && printf '%s.%s.%s%s' "$v" "$pl" "${sl:-0}" "$ev"
}

# Patch provenance, read from the tree rather than from a list of names.
# EXTRAVERSION is empty on a mainline release and "-rcN" on a candidate;
# anything left after stripping a leading -rcN was added by whoever built
# it. A more optimized kernel built here later classifies by the same rule
# without being named, since it will carry a suffix too.
treepatched() { # dir -> "yes" or "no"
	ev=$(treerel "$1" | sed 's/^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*//; s/^-rc[0-9][0-9]*//')
	[ -n "$ev" ] && echo yes || echo no
}

KERNEL_REF=7.3
want=${H2_KERNEL_REF:-$KERNEL_REF}

# The default has to find the kernel of record, not the one the host happens
# to run. Until the 7.2 tree was substituted in, "the newest thing present"
# and "the kernel of record" were the same question here by accident. This
# workstation is the case that separates them: the host runs 7.1.9 while the
# tree the port targets sits in the store. A gate needing KDIR typed to reach
# the right kernel reports COULD-NOT-RUN in CI and in the delegator that runs
# it from another repository, both of which invoke it with no arguments.
#
# So an explicit KDIR always wins, and otherwise the first candidate whose own
# Makefile reports the wanted version is taken. The running kernel comes
# before the store, so an ordinary machine behaves as it always did and never
# pays for a store scan it does not need.
if [ -n "${KDIR:-}" ]; then
	K=$KDIR; ksrc="KDIR"
else
	# Trees built here are searched too. The port's own claim is against
	# an unpatched kernel, and until this list included one, the only tree
	# the search could reach at the wanted version was the store's patched
	# build: the unpatched run existed but had to be asked for by name, and
	# for one release nobody asked and the result was written down as if
	# somebody had. H2_KERNEL_TREES adds directories, colon separated.
	K=""; ksrc=""; alt=""; altsrc=""
	for cand in "/lib/modules/$(uname -r)/build" \
		$(IFS=:; for d in ${H2_KERNEL_TREES:-}; do echo "$d"; done) \
		$(ls -d "$HOME"/kernels/*/ 2>/dev/null | sort -V -r) \
		$(ls -d /nix/store/*-linux-*-dev/lib/modules/*/build 2>/dev/null | sort -V -r); do
		cand=${cand%/}
		[ -d "$cand" ] || continue
		[ "$(treever "$cand")" = "$want" ] || continue
		case "$cand" in
		/nix/store/*) src="the store, matching the kernel of record" ;;
		"/lib/modules/$(uname -r)/build") src="/lib/modules/\$(uname -r)/build" ;;
		*) src="a tree built here" ;;
		esac
		# An unpatched tree wins over a patched one at the same version,
		# so the default measures what the port claims. The patched tree
		# is still reached by pointing KDIR at it, which is the run the
		# consuming distribution needs.
		if [ "$(treepatched "$cand")" = no ]; then
			K=$cand; ksrc=$src; break
		fi
		[ -n "$alt" ] || { alt=$cand; altsrc=$src; }
	done
	[ -n "$K" ] || { K=$alt; ksrc=$altsrc; }
	# Nothing matched. Fall back to what is present so the refusal below
	# can name the version it found instead of reporting an empty path.
	if [ -z "$K" ]; then
		K=/lib/modules/$(uname -r)/build; ksrc="/lib/modules/\$(uname -r)/build, no candidate matched"
		if [ ! -d "$K" ]; then
			K=$(ls -d /nix/store/*-linux-*-dev/lib/modules/*/build 2>/dev/null | sort -V | tail -1)
			ksrc="nix store fallback"
		fi
	fi
fi
[ -n "$K" ] && [ -d "$K" ] || { echo "syntax: COULD-NOT-RUN: no kernel build dir ($ksrc)"; exit 2; }
S=$(dirname "$K")/source
[ -d "$S" ] || S=$K

# The kernel of record is the latest release, and nothing compared against it
# until this pin existed. The 6.15 floor in hammer2_os.h is what the code
# requires and is a different claim. This gate has always printed the kernel
# it used in its header line, and every document said the port is developed
# against 7.2, and nothing put those two strings next to each other. The
# newest tree on the development host was 7.1.9, with no 7.2 in /lib/modules,
# /usr/src or the store, so every green run was measured against a kernel that
# is not the one of record and read as though it were. Nobody reads a header
# line for a verdict; they read "0 failed".
#
# So a tree that is not the kernel of record is COULD-NOT-RUN, the same status
# test-checkpatch.sh gives a checkpatch.pl that is not the baseline's version,
# and for the same reason: a result from the wrong instrument cannot be
# attributed to the code. H2_KERNEL_REF compiles against another version
# deliberately, and it has to be typed, so a wrong tree cannot pass.
#
# Bumping the pin is the whole maintenance burden and it is one line. When a
# new Linux ships, install its headers, raise KERNEL_REF, run this gate. An
# unbumped pin stops the gate instead of aging quietly.
kver=""
kmk=$K/Makefile
# A nix dev output's build Makefile is a three-line stub that sets
# KBUILD_OUTPUT and includes the real Makefile from the source directory
# beside it, so VERSION and PATCHLEVEL are not in the file this points at.
# The first version of this check rejected the 7.2.0-cachyos tree for that
# reason, and that is a legitimate build tree with scripts/, arch/,
# Module.symvers and include/generated.
#
# The stub names the file it includes, so that name is followed instead of a
# sibling directory being assumed. linux-api-headers still fails here, having
# no Makefile at all and so nothing to follow.
if [ -f "$kmk" ]; then
	inc=$(sed -n 's/^include \(.*\/Makefile\)$/\1/p' "$kmk" | head -1)
	[ -n "$inc" ] && [ -f "$inc" ] && kmk=$inc
	v=$(sed -n 's/^VERSION *= *//p' "$kmk" | head -1)
	pl=$(sed -n 's/^PATCHLEVEL *= *//p' "$kmk" | head -1)
	[ -n "$v" ] && [ -n "$pl" ] && kver="$v.$pl"
fi
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

# Two compilers, because they disagree about what is worth saying and one is
# one opinion. Both found the LIST_HEAD and RB_ROOT collisions independently,
# which is what made those credible rather than stylistic. gcc is optional: if
# it is absent the clang pass still runs and the count below says how many
# compilers were used.
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
	# arch/x86/include/asm/ftrace.h refuses to compile under
	# CONFIG_FUNCTION_TRACER unless this is defined, and it is reached
	# the moment a file includes <linux/module.h>.  Kbuild defines it
	# beside -mfentry (Makefile, CC_FLAGS_USING, read at the kernel of
	# record); only the define belongs here, because -mfentry is
	# codegen and this gate is -fsyntax-only.  gcc also rejects
	# -mfentry outright without -pg, so passing the pair would take
	# the second compiler out.
	-DCC_USING_FENTRY
	-mcmodel=kernel -mno-red-zone -mno-sse -mno-mmx -fno-PIE -fno-strict-aliasing
	-Wall -Werror=implicit-function-declaration -Werror=implicit-int
	-Werror=incompatible-pointer-types
	# -Wimplicit-fallthrough and -Wunused are both in the real build's flag
	# set, read from .hammer2_chain.o.cmd after the first `make` on
	# 2026-09-02, and neither was here. That made this gate WEAKER than the
	# build it stands in for, which is the opposite of the asymmetry the
	# -Wno-pointer-sign note below describes: seven warnings came out of
	# that build and none of them had ever appeared here. Both are
	# suppressed on the carried files and fatal on ours.
	-Wimplicit-fallthrough
	# W=1 class. The kernel's own W=1 is a kbuild target we cannot reach
	# without building, so this is the subset that works under
	# -fsyntax-only. It is what found the two macro redefinitions.
	-Wextra -Wmissing-prototypes -Wold-style-definition
	-Wno-unused-parameter -Wno-sign-compare
	-I src/sys/fs/hammer2 -I src/sys -I test)

# Carried files only, never hammer2_io.c, which is ours. gcc warns
# -Waddress-of-packed-member where hammer2_freemap.c takes the address of
# a field in the on-disk __packed struct; it warns categorically rather
# than by offset, and clang does not warn at all. The address is aligned:
# test/hammer2-header.c asserts the field is at 0x40, that 0x40 is a
# multiple of its own size, and that the struct is 128 bytes, so this
# suppression rests on a measurement the compiler re-takes every run and
# fails in the same build if the format moves.
#
# -Wno-pointer-sign is a different kind of entry: it is not a judgement
# call, it is what the kernel of record itself compiles every file with
# (scripts/Makefile.warn:68), so the module build cannot see this warning
# and a gate that fails on it is testing a build nobody performs. It is
# still confined to the carried files, which leaves this gate stricter
# than the real build on the half of the tree we write. What it hides
# upstream: hammer2_chain_base_and_count() takes `int *count` and two
# callers in hammer2_chain.c pass `unsigned int *`.
#
# -Wno-implicit-fallthrough and -Wno-unused-function are the two the first
# build found. Upstream marks its fallthroughs with a /* fall through */
# comment, which kbuild's -Wimplicit-fallthrough=5 does not read; and
# hammer2_inode_lock_temp_release() and _restore() have no caller in this
# port and are not expected to gain one, because their only caller in either
# upstream is hammer2_igetv(), which this port rewrote on iget5_locked().
# The reasoning is at that rewrite: the temp-release dance guards FreeBSD's
# two racing hash operations, and iget5_locked() does the lookup, the
# allocation and the insert in one call, so there is nothing to race. src/sys/fs/hammer2/Makefile suppresses the same two on the same
# files, so the gate and the build agree about which text is DragonFly's.
CARRIED="-Wno-address-of-packed-member -Wno-pointer-sign
	-Wno-implicit-fallthrough -Wno-unused-function"

fail=0 ran=0
# A warning in our own files is a failure, and it is counted rather than made
# fatal: -Werror would also fail on the kernel headers, which we do not own
# and cannot fix. Anchoring on `src/` separates the two.
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

# The compiler is a pin too, and the tree says which one it wants instead of
# this script asserting one: kbuild records the compiler that built the kernel
# in CONFIG_CC_VERSION_TEXT, and a module is built by comparison against that,
# not against whatever is newest. Printed and compared, not enforced, since
# which compiler is correct depends on the tree. Measured 2026-08-26: the
# 7.2.0-cachyos kernel of record was built with "clang version 22.1.8" and
# the development host's clang is byte-identical, which is why that version is
# the right one and not an old one.
ccv=$("$CC" --version | head -1)
kcc=$(sed -n 's/^CONFIG_CC_VERSION_TEXT="\(.*\)"$/\1/p' "$K/.config" 2>/dev/null | head -1)
if [ -z "$kcc" ]; then
	ccnote="the tree records no CONFIG_CC_VERSION_TEXT"
elif [ "$kcc" = "$ccv" ]; then
	ccnote="matching the tree's own"
else
	ccnote="NOT the tree's own, which is \"$kcc\""
fi
krel=$(treerel "$K")
[ -n "$krel" ] || krel=$(basename "$(dirname "$K")")
[ "$(treepatched "$K")" = yes ] && kpatch="patched" || kpatch="mainline"
echo "hammer2 against $krel ($kpatch) via $ksrc, dialect $dsrc, with $ccv, $ccnote:"
check "hammer2.h: header TU expands (tree, queue, atomics)" pass test/hammer2-header.c
check "hammer2_io.c: invariants on"  pass src/sys/fs/hammer2/hammer2_io.c -DHAMMER2_INVARIANTS
check "hammer2_io.c: invariants off" pass src/sys/fs/hammer2/hammer2_io.c
check "hammer2_admin.c: invariants on"  pass src/sys/fs/hammer2/hammer2_admin.c -DHAMMER2_INVARIANTS $CARRIED
check "hammer2_admin.c: invariants off" pass src/sys/fs/hammer2/hammer2_admin.c $CARRIED
check "hammer2_freemap.c: invariants on"  pass src/sys/fs/hammer2/hammer2_freemap.c -DHAMMER2_INVARIANTS $CARRIED
check "hammer2_freemap.c: invariants off" pass src/sys/fs/hammer2/hammer2_freemap.c $CARRIED
check "hammer2_xops.c: invariants on"  pass src/sys/fs/hammer2/hammer2_xops.c -DHAMMER2_INVARIANTS $CARRIED
check "hammer2_xops.c: invariants off" pass src/sys/fs/hammer2/hammer2_xops.c $CARRIED
check "hammer2_bulkfree.c: invariants on"  pass src/sys/fs/hammer2/hammer2_bulkfree.c -DHAMMER2_INVARIANTS $CARRIED
check "hammer2_bulkfree.c: invariants off" pass src/sys/fs/hammer2/hammer2_bulkfree.c $CARRIED
check "hammer2_chain.c: invariants on"     pass src/sys/fs/hammer2/hammer2_chain.c -DHAMMER2_INVARIANTS $CARRIED
check "hammer2_chain.c: invariants off"    pass src/sys/fs/hammer2/hammer2_chain.c $CARRIED
check "hammer2_flush.c: invariants on"      pass src/sys/fs/hammer2/hammer2_flush.c -DHAMMER2_INVARIANTS $CARRIED
check "hammer2_flush.c: invariants off"    pass src/sys/fs/hammer2/hammer2_flush.c $CARRIED
check "hammer2_cluster.c: invariants on"    pass src/sys/fs/hammer2/hammer2_cluster.c -DHAMMER2_INVARIANTS $CARRIED
check "hammer2_cluster.c: invariants off"  pass src/sys/fs/hammer2/hammer2_cluster.c $CARRIED
check "hammer2_subr.c: invariants on"       pass src/sys/fs/hammer2/hammer2_subr.c -DHAMMER2_INVARIANTS $CARRIED
check "hammer2_subr.c: invariants off"     pass src/sys/fs/hammer2/hammer2_subr.c $CARRIED
check "hammer2_ondisk.c: invariants on"     pass src/sys/fs/hammer2/hammer2_ondisk.c -DHAMMER2_INVARIANTS $CARRIED
check "hammer2_ondisk.c: invariants off"   pass src/sys/fs/hammer2/hammer2_ondisk.c $CARRIED
check "hammer2_inode.c: invariants on"      pass src/sys/fs/hammer2/hammer2_inode.c -DHAMMER2_INVARIANTS $CARRIED
check "hammer2_inode.c: invariants off"    pass src/sys/fs/hammer2/hammer2_inode.c $CARRIED
check "hammer2_vfsops.c: invariants on"     pass src/sys/fs/hammer2/hammer2_vfsops.c -DHAMMER2_INVARIANTS $CARRIED
check "hammer2_vfsops.c: invariants off"   pass src/sys/fs/hammer2/hammer2_vfsops.c $CARRIED
check "hammer2_strategy.c: invariants on"   pass src/sys/fs/hammer2/hammer2_strategy.c -DHAMMER2_INVARIANTS
check "hammer2_strategy.c: invariants off"  pass src/sys/fs/hammer2/hammer2_strategy.c
check "hammer2_vnops.c: invariants on"      pass src/sys/fs/hammer2/hammer2_vnops.c -DHAMMER2_INVARIANTS
check "hammer2_vnops.c: invariants off"     pass src/sys/fs/hammer2/hammer2_vnops.c
# Negative control: a wrong kernel call must be refused by the same
# headers, or a pass above proves only that the compiler ran. Both
# controls are prefix headers applied after the kernel header they
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
	# gcc's -Wimplicit-fallthrough defaults to level 3, which accepts a
	# comment; kbuild asks for 5, which accepts only the attribute. clang
	# has no levels and rejects the =5 spelling, so it is added here rather
	# than to the shared set.
	CFLAGS2+=(-Wimplicit-fallthrough=5)
	for f in test/hammer2-header.c src/sys/fs/hammer2/hammer2_io.c \
		src/sys/fs/hammer2/hammer2_admin.c \
		src/sys/fs/hammer2/hammer2_freemap.c \
		src/sys/fs/hammer2/hammer2_xops.c \
		src/sys/fs/hammer2/hammer2_bulkfree.c \
		src/sys/fs/hammer2/hammer2_chain.c \
		src/sys/fs/hammer2/hammer2_flush.c \
		src/sys/fs/hammer2/hammer2_cluster.c \
		src/sys/fs/hammer2/hammer2_subr.c \
		src/sys/fs/hammer2/hammer2_ondisk.c \
		src/sys/fs/hammer2/hammer2_inode.c \
		src/sys/fs/hammer2/hammer2_vfsops.c \
		src/sys/fs/hammer2/hammer2_strategy.c \
		src/sys/fs/hammer2/hammer2_vnops.c; do
		ran=$((ran + 1))
		# The packed-member suppression applies to the carried files
		# only, exactly as it does for the first compiler. Our own
		# hammer2_io.c and the header TU are held to the full set,
		# and the header TU is where the alignment is asserted.
		case "$f" in
		*/hammer2_io.c|*/hammer2_strategy.c|test/*) carried= ;;
		*) carried=$CARRIED ;;
		esac
		"$CC2" "${CFLAGS2[@]}" $carried "$f" >/tmp/h2syn2.$$ 2>&1; rc=$?
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

# An overridden run must not print what a real one prints. Until 2026-08-26 it
# did, byte for byte: "syntax: 7 check(s), 0 failed" whether the tree was the
# kernel of record or a version somebody typed into H2_KERNEL_REF to get a
# green line. Every such line reported that day came from an
# overridden run, there being no 7.2 tree here, so the summary was true about
# the checks and silent about what they were checked against.
if [ "$want" != "$KERNEL_REF" ]; then
	echo "syntax: $ran check(s), $fail failed AGAINST LINUX $want, WHICH IS NOT"
	echo "        THE KERNEL OF RECORD ($KERNEL_REF). H2_KERNEL_REF was set, so"
	echo "        this run is a reading about $want and not evidence about the"
	echo "        kernel this tree targets."
else
	# The release and its patch provenance go in the summary line and not
	# only in the header, because this is the line that gets quoted into a
	# document. Quoted without them it names a series that two different
	# trees satisfy, and one such quotation attributed a store tree's run
	# to a mainline one.
	echo "syntax: $ran check(s), $fail failed against the kernel of record ($KERNEL_REF), $krel, $kpatch"
fi
[ "$fail" = 0 ]
