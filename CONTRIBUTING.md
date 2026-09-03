Contributing
============

This is a port, not a new filesystem. That shapes what is useful here.

## The most useful thing you can do

Read a port decision and tell us it is wrong. `doc/README.porting.md`
lists them, each with the reasoning. Several are load-bearing and only one
person has looked at them: the sleeping locks behind `hammer2_spin_*`, the
upgrade that cannot upgrade, the folio held for the life of `DIO_GOOD`,
the positive errnos. An argument against any of those is worth more than a
patch right now.

Reports of the form "this cannot work because X" are welcome even without
a fix, and especially from anyone who has ported this filesystem before.

## Ground rules

**Follow the BSD ports.** When there is a choice, do what
[freebsd_hammer2](https://github.com/kusumi/freebsd_hammer2),
[netbsd_hammer2](https://github.com/kusumi/netbsd_hammer2) or
[openbsd_hammer2](https://github.com/kusumi/openbsd_hammer2) does, and say
which one you followed. The aim is a fourth port that reads like the other
three, so that fixes travel between them. A cleverer Linux-native approach
that breaks that symmetry needs to earn it in the commit message.

**Do not edit the carried core to make it Linux-shaped.** The carried
files exist to be replaceable by the next sync with DragonFly. Anything
that has to differ goes in `hammer2_os.h` or `hammer2_compat.h`. If a core
edit is genuinely unavoidable, mark it `XXX` in place, as the BSD ports
do, so the next sync can find it.

**Style is BSD, deliberately.** See `doc/README.kernel-style.md` before
sending a patch that converts `return (x);` to `return x;`. The whole tree
converts at once, at submission, or not at all.

**Every new check comes with the run that showed it failing**, recorded in
`doc/README.testing.md`. A check nobody has seen fail is not known to test
anything, and its own green run is not evidence: three fixtures across
these repositories passed on 2026-08-26 while testing nothing, each caught
by running it against the defect rather than by reading it.

**Every change comes with the gate that would have caught it.** All eleven
gates are cheap, and `test-absence.sh` exists because that rule was kept for
code and not for prose. `test-shim.sh`, `test-syntax.sh` and
`test-absence.sh` carry built-in controls that must fail on every run; the others buy the same assurance
differently, and `doc/README.testing.md` says how for each. A patch that
changes behavior with no way to observe the change is hard to review and
harder to keep.

## Before sending

    $ bash script/test-inventory.sh
    $ bash script/test-citations.sh
    $ bash script/test-history.sh
    $ bash script/test-provenance.sh
    $ bash script/test-absence.sh
    $ bash script/test-shim.sh
    $ bash script/test-syntax.sh
    $ bash script/test-checkpatch.sh
    $ bash script/test-vectors-contract.sh
    $ bash script/test-posix.sh
    $ bash script/test-doc-prose.sh
    $ bash script/test-syntax.sh --selftest
    $ bash script/test-checkpatch.sh --selftest
    $ bash script/test-provenance.sh --selftest

The first three are POSIX sh over grep, sed and git. They need no kernel
and no network, they take about a second, and they are what a
documentation-only patch breaks: they check that the lists claiming to
cover `src/` are complete, that every `file:line` citation in `doc/`
resolves to the line it names, and that every roadmap row's commit hash
resolves with a matching subject.

The last three need a toolchain. `test-syntax.sh` wants the kernel of
record, which is the latest release and is pinned as `KERNEL_REF` in that
script; anything else is COULD-NOT-RUN rather than a pass, because a
result from the wrong kernel is not a result about this code. 6.15 is the
module's floor and a separate claim. Set `KDIR` to point at another tree,
and `H2_KERNEL_REF` to check another version deliberately. `test-checkpatch.sh`
needs `checkpatch.pl`, so point `CHECKPATCH` or `KDIR` at one.

All sight gates exit 2 when the instrument itself could not run, which is
not a failure and must not be recorded as one.

## Licensing

BSD-3-Clause, matching DragonFly and the BSD ports, and listed in the
kernel's own `LICENSES/preferred/`. By sending a patch you agree to it
being distributed under that license. Add yourself to `CONTRIBUTORS` in
the same patch if you want to be listed.

## Upstream

HAMMER2 is Matthew Dillon's, and the three existing ports are Tomohiro
Kusumi's. This port exists to be handed over. If it ends up living in one
of their trees instead of this one, that is the intended outcome and not a
loss.
