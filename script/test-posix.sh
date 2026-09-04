#!/bin/sh
# The gates that declare #!/bin/sh are parsed by shells that are not bash.
#
# Every gate here is normally run by bash, by hand and by CI, so a bash-only
# construct in a script declaring #!/bin/sh runs fine forever and breaks the
# day something honours the shebang. On 2026-08-26 both --selftest paths
# re-invoked their gate with `sh "$0"`, which works where /bin/sh is bash and
# is a syntax error under dash: they passed on the workstation and failed on
# the runner with `Syntax error: "(" unexpected`. Grepping for the usual tells
# had reported all four clean, because a grep is not a parse.
#
# What a clean run is worth. A parse reaches less than it appears to, so the
# gate measures its own reach on every run and prints it. The table below is
# one dated observation of that, kept for a reader and not relied on by the
# code. Observed 2026-08-26:
#
#   construct                  dash        busybox ash
#   process substitution       REJECT      accept
#   array assignment a=(1 2)   REJECT      REJECT
#   function f { }             REJECT      accept
#   here-string <<< x          REJECT      REJECT
#   [[ -n x ]]                 accept      accept
#   declare -A m               accept      accept
#   local x=1                  accept      accept
#   a+=2                       accept      accept
#
# Four constructs in dash and two in ash, and blind to [[, declare, local, +=,
# arithmetic, ANSI-C quoting and brace expansion, which are ordinary words to a
# POSIX shell and fail only at runtime. A clean run means no bash syntax, never
# no bashisms.
#
# Exit 2 is COULD-NOT-RUN: no shell realized. Exit 1 is a parse failure.
set -u
cd "$(dirname "$0")/.." || exit 2

# PATH first, then the store, because a nix machine keeps its software
# where PATH cannot see it and nothing is installed here to serve a target
# system.
# H2_DASH and H2_BUSYBOX override, which is what makes the COULD-NOT-RUN
# branch below drivable at all: the store lookup finds a shell on any
# machine that has one, so without an override that branch is an untested
# path wearing the costume of a safety net. Point them at something that
# does not exist to drive it.
DASH=${H2_DASH-$(command -v dash 2>/dev/null)}
[ -n "$DASH" ] || DASH=$(ls -d /nix/store/*-dash-*/bin/dash 2>/dev/null | head -1)
BB=${H2_BUSYBOX-$(command -v busybox 2>/dev/null)}
[ -n "$BB" ] || BB=$(ls -d /nix/store/*-busybox-*/bin/busybox 2>/dev/null | head -1)

shells=""
[ -n "$DASH" ] && [ -x "$DASH" ] && shells="dash"
[ -n "$BB" ] && [ -x "$BB" ] && shells="$shells ash"
[ -n "$shells" ] || {
	echo "posix: COULD-NOT-RUN: no dash and no busybox, in PATH or the store"
	exit 2
}

parse() { # shell file -> status
	case "$1" in
	dash) "$DASH" -n "$2" 2>&1 ;;
	ash) "$BB" ash -n "$2" 2>&1 ;;
	esac
}

fail=0 ran=0

# The reach is measured on every run and printed as observed, never asserted.
# An earlier version hardcoded the table above as expectations, which is a gate
# stating its own coverage: a claim nothing checks, in the one place a reader
# uses to decide whether a clean run means anything, and wrong the next time a
# shell version moves. It was wrong when written too, claiming three constructs
# in dash where there are four.
#
# What is asserted instead are two properties of a working checker, which hold
# whatever the reach turns out to be:
#
#   1. each shell must reject at least one probe, or it is inert here and
#      a clean result means nothing;
#   2. a plain POSIX script must be accepted, or the instrument refuses
#      everything and a clean result is unreachable rather than earned.
#
# The design is taken from the equivalent gate in the Saxum tree.
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
probe() { printf '%s\n' "$2" > "$tmp/probe-$1.sh"; probes="${probes:-} $1"; }
probes=""
probe procsub    'cat <(echo x)'
probe array      'a=(1 2)'
probe funckw     'function f { :; }'
probe herestring 'cat <<< hi'
probe dbracket   'if [[ -n x ]]; then :; fi'
probe declare    'declare -A m'
probe append     'a=1; a+=2'
printf 'x=1\nif [ "$x" = 1 ]; then :; fi\n' > "$tmp/plain.sh"

# The probe set is itself a population: an empty one would make every
# reach line vacuous and both invariants unfalsifiable.
[ -n "$probes" ] || { echo "posix: FAIL: no probes defined" >&2; exit 1; }

echo "hammer2 POSIX parse, with $shells:"
for sh in $shells; do
	rejected=0 reach=""
	for pr in $probes; do
		if parse "$sh" "$tmp/probe-$pr.sh" >/dev/null 2>&1; then
			:
		else
			rejected=$((rejected + 1)); reach="$reach $pr"
		fi
	done
	ran=$((ran + 1))
	if [ "$rejected" -gt 0 ]; then
		echo "  ok    $sh reaches:$reach ($rejected of $(set -- $probes; echo $#) probes)"
	else
		echo "  FAIL  $sh rejected NOTHING, so it is inert here and a clean"
		echo "        parse below would mean nothing"
		fail=$((fail + 1))
	fi
	ran=$((ran + 1))
	if parse "$sh" "$tmp/plain.sh" >/dev/null 2>&1; then
		echo "  ok    $sh accepts a plain POSIX script"
	else
		echo "  FAIL  $sh refuses a plain POSIX script, so a clean parse is"
		echo "        unreachable rather than earned"
		fail=$((fail + 1))
	fi
done

# Assert the population. A glob that matches nothing parses nothing and prints
# a clean count of failures among no files, which is what this gate looks like
# when it is broken.
n=0
for f in script/*.sh; do
	case "$(head -1 "$f")" in *bash*) continue ;; esac
	n=$((n + 1))
	for sh in $shells; do
		ran=$((ran + 1))
		out=$(parse "$sh" "$f") || {
			echo "  FAIL  $sh: $(basename "$f")"
			printf '%s\n' "$out" | head -3 | sed 's/^/        /'
			fail=$((fail + 1))
			continue
		}
		echo "  ok    $sh: $(basename "$f")"
	done
done
[ "$n" -gt 0 ] || {
	echo "posix: FAIL: no #!/bin/sh scripts found in script/ at all" >&2
	exit 1
}

echo "posix: $n sh-declared script(s), $ran check(s), $fail failed"
[ "$fail" = 0 ] || exit 1
