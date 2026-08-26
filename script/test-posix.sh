#!/bin/sh
# The gates that declare #!/bin/sh are parsed by shells that are not bash.
#
# WHY THIS EXISTS. Every gate here is normally run by bash - by hand, by
# CI, and by ArtNix's delegator - so a bash-only construct in a script
# declaring #!/bin/sh runs fine forever and breaks the day something
# honours the shebang. That is not hypothetical: on 2026-08-26 both
# --selftest paths re-invoked their gate with `sh "$0"`, which works where
# /bin/sh is bash and is a syntax error under dash, so they passed on this
# workstation and failed on the runner with `Syntax error: "(" unexpected`.
# A local run could not reach it by construction.
#
# I THEN CLAIMED THESE FOUR WERE CLEAN AFTER GREPPING FOR THE USUAL TELLS,
# and a grep is not a parse. I also recorded that no POSIX shell existed
# here, having asked `command -v`, which reads PATH - and PATH is not the
# machine. Both shells were already realized in the store. The ArtNix
# session made the same two errors within the hour and found the store
# copies first.
#
# WHAT A CLEAN RUN HERE IS WORTH, measured rather than assumed, because a
# parse reaches far less than it appears to. Fed to both shells on
# 2026-08-26:
#
#   construct                  dash        busybox ash
#   process substitution       REJECT      accept
#   array assignment a=(1 2)   REJECT      REJECT
#   function f { }             REJECT      accept
#   [[ -n x ]]                 accept      accept
#   declare -A m               accept      accept
#   local x=1                  accept      accept
#   a+=2                       accept      accept
#
# So this catches three constructs in dash and one in ash, and is BLIND to
# [[, declare, local and += - which are ordinary words to a POSIX shell
# and only fail at runtime. A clean run means "no bash SYNTAX", never "no
# bashisms". The table prints on every run so nobody has to take that on
# trust.
#
# Exit 2 is COULD-NOT-RUN: no shell realized. Exit 1 is a parse failure.
set -u
cd "$(dirname "$0")/.." || exit 2

# PATH first, then the store, because a nix machine keeps its software
# where PATH cannot see it and nothing is installed here to serve a target
# system.
DASH=$(command -v dash 2>/dev/null)
[ -n "$DASH" ] || DASH=$(ls -d /nix/store/*-dash-*/bin/dash 2>/dev/null | head -1)
BB=$(command -v busybox 2>/dev/null)
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

# THE REACH IS ASSERTED, NOT DESCRIBED. The table above is a measurement
# and measurements rot; these controls re-take it on every run. If a shell
# stops rejecting what it rejected, the table is wrong and this says so
# rather than continuing to quote it.
tmp=$(mktemp -d) || exit 2
trap 'rm -rf "$tmp"' EXIT
printf 'cat <(echo x)\n' > "$tmp/procsub.sh"
printf 'a=(1 2)\n' > "$tmp/array.sh"
printf 'if [[ -n x ]]; then :; fi\n' > "$tmp/dbracket.sh"

expect() { # shell file want name
	ran=$((ran + 1))
	if parse "$1" "$2" >/dev/null 2>&1; then got=accept; else got=reject; fi
	if [ "$got" = "$3" ]; then
		echo "  ok    reach: $1 ${3}s $4"
	else
		echo "  FAIL  reach: $1 ${got}s $4, where this gate's table says ${3}"
		fail=$((fail + 1))
	fi
}
echo "hammer2 POSIX parse, with $shells:"
for sh in $shells; do
	case "$sh" in
	dash) expect dash "$tmp/procsub.sh" reject "process substitution" ;;
	ash) expect ash "$tmp/procsub.sh" accept "process substitution" ;;
	esac
	expect "$sh" "$tmp/array.sh" reject "array assignment"
	expect "$sh" "$tmp/dbracket.sh" accept "[[ ]], so this gate is blind to it"
done

# THE POPULATION IS ASSERTED. A glob that matches nothing parses nothing
# and prints a clean count of failures among no files, which is what this
# gate looks like when it is broken.
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
