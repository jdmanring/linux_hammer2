Testing
=======

Sight gates run today, all cheap. Most fall into two groups, and the split
matters when you are deciding which to run: the compile gates need a
toolchain and a kernel tree, the repository gates need neither. Two belong
to neither group and are described below, `test-vectors-contract.sh` and
`test-posix.sh`. No count of them is written in this file: the lists below
are the statement of record, and a number beside a list is a second claim
about one population with nothing checking the two against each other,
which this file has already recorded happening twice.

Compile gates:

    $ bash script/test-shim.sh        # needs only a C compiler
    $ bash script/test-syntax.sh      # needs kernel headers and clang
    $ bash script/test-checkpatch.sh  # needs scripts/checkpatch.pl

Repository gates, POSIX sh over grep, sed and git, no kernel and no
network:

    $ bash script/test-inventory.sh   # the lists covering src/ and test/, and the DEFER ledger
    $ bash script/test-citations.sh   # the file:line citations in doc/ tables
    $ bash script/test-history.sh     # every roadmap row's commit hash
    $ bash script/test-provenance.sh  # every file under src/ has an origin row
    $ bash script/test-absence.sh     # every "X() is not carried" claim resolves

Prose gate, needs vale and nothing else:

    $ bash script/test-doc-prose.sh   # vale over doc/, any finding is a failure

`test-absence.sh` resolves a claim rather than a citation. Where a document
says a named function is not carried, it asks `src/` whether that function
is defined and fails when it is. The vocabulary is the origin table's:
carried means imported substantially unchanged, and a function this port
rewrote is rewritten, so a symbol that is present here has not been "not
carried" whatever else is true of it. Its first run found one, in
`hammer2_inode.c`, where `hammer2_igetv()` was called uncarried after this
port rewrote it on `iget5_locked()`. It reads only the claims that name a
symbol, which is a fraction of the class it belongs to, and it says so on
every run rather than leaving the rest to inherit its credibility.

`test-shim.sh` compiles `hammer2_os.h` and `hammer2_compat.h` against the
stubs in `test/stub`, in both positions of the `HAMMER2_INVARIANTS` knob,
plus a negative control: the header is broken on a copy and the compile
must fail. Without that control a gate whose healthy signature is silence
cannot be told from a gate that never opened the file.

## The gates run against a built tree, and until 2026-09-02 none had

`make` was first run on 2026-09-02. It put thirteen objects and their
`.cmd` files beside the sources, and `test-provenance.sh` and
`test-inventory.sh` went red on the spot: the first asked for an origin row
for each of thirty files kbuild had just written, the second read `XXX` out
of the strings inside `hammer2.o` and asked the status table for a row.
Neither had a bug that could pass something wrong. Both enumerated `src/`
and had never seen anything there that was not source.

`test-checkpatch.sh` and `test-citations.sh` had the same shape without
having tripped. The one that bites latest is the `*.c` glob: kbuild writes
`hammer2.mod.c`, which no build has reached, because modpost stops first.

All four now exclude kbuild's output, and the patterns match `.gitignore`'s.
The permanent guard is not a new gate but an ordering: CI builds the module
before it runs any gate, so every gate runs against the tree a developer
actually has. Until 2026-09-03 this paragraph also said that step asserts
the undefined set is exactly the four named in `doc/README.status.md`.
Nothing asserted that. The step read `modinfo` and counted warnings, and a
fifth undefined reference would have been a failed link with no list, which
is a red run but not the one described here.

What it does assert is in `script/build-check.sh`, which is not a gate and
is named `build-check` rather than `test-` for that reason: the build fails,
or the build is not warning-clean, or the build reports success and there is
no `hammer2.ko`. It lives in a script because it has two callers now, the
kernel of record and the floor, and a check copied into a second caller can
rot in one copy while the other stays right. Its three failing directions
were driven on 2026-09-02 and 2026-09-03, by giving `hammer2_io.c` a call to
an undefined function, then an unused static, and by pointing it at a
directory holding no kernel, which is COULD-NOT-RUN and not a pass.

Its warning pattern requires `file:line:column`, because a bare `warning:`
also matches kbuild's banner about the runner's compiler differing from the
kernel's, which is a fact about the machine. That failed the step for two
runs while the build was clean. The pattern is therefore checked against a
line built to match before it is trusted on a log that should have none,
since no warnings and a pattern that stopped matching print the same number.

## The declared floor is built, since 2026-09-03

`hammer2_os.h` has carried an `#error` asserting 6.15 for as long as there
has been a shim, and nothing had ever put a compiler on that kernel. The
lowest build in existence was CI's, two releases above it. A floor nothing
compiles is an assertion, and it failed as one twice in a day:
`inode_state_read_once()` needs 6.19 and `kzalloc_obj()` needs 7.0, and each
surfaced as an implicit declaration in the middle of a build against a newer
kernel rather than at the `#error` written to report a kernel that is too
old.

A second CI job fetches the 6.15 tarball, runs `modules_prepare` once and
caches the prepared tree on the tag, then builds the module against it
through the same `build-check.sh`. The tag is immutable, so the expensive
half is paid once; a cache miss costs minutes and changes no verdict. The
tree is asserted to report 6.15 before anything is built against it, because
a cache restored under a bumped key would otherwise report a green floor
build against some other kernel. COULD-NOT-RUN is a real failure in that job
rather than a skip: the steps above it exist to provide the tree, so its
absence means one of them silently did nothing.

Run it before pushing, not after. Between 2026-08-29 and 2026-09-03 this
repository sent twenty-six failed CI runs, counted by asking the API which
step failed in each rather than by remembering: twenty-one at a module
build, three at the repository gates, and two at the floor job's own
assertion that its kernel tree carries a symbol table. The build failures
were symbols undefined at modpost, then a 6.19 spelling against the 6.15
floor, then a 7.0 one, then that job's own iterations. Two of the
twenty-six were the gate's fault, a bare `warning:` matching kbuild's
compiler banner; every other one was a real defect, in the tree or in the
workflow being written at the time.

So the gates were right and the volume was still a working habit rather
than a defect rate. CI was being used as a compiler, one push per question,
and each answer arrived as a failure notification to the maintainer.

`build-check.sh` takes a `KDIR`, so the floor job reproduces on any machine
with a built 6.15 tree:

    $ cd ~/kernels && curl -sSLO https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.15.tar.xz
    $ tar -xf linux-6.15.tar.xz && cd linux-6.15
    $ make defconfig && make -j"$(nproc)"        # bc, bison, flex, libelf, openssl
    $ cd /path/to/linux_hammer2
    $ sh script/build-check.sh ~/kernels/linux-6.15

The full build is what writes `Module.symvers`, per the kbuild note above,
and it is the only slow part. Once it exists the check is seconds, and the
question CI answers in four minutes is answerable before the commit.

`script/floor-symbols.py` bounds the same class from the other side by
resolving every identifier the tree calls and does not define against the
floor tree's `include/`. It does not compile, so a signature that changed
while keeping its name, or a macro that stopped expanding, is invisible to
it. The job is what closes what the sweep can only bound.

`test-doc-prose.sh` runs vale over every `.md` under `doc/` with the
styles in `styles/`, which are house YAML rather than a downloaded package
so the gate needs no network and no `vale sync`. It arrived on 2026-08-29
with `doc/research/`, which had been governed in Saxum since 2026-08-25
and was moved here on the rule that a component owns its own development.

Two things about it were wrong until 2026-09-02 and are worth recording,
because both are the shape where a gate prints and still passes. Vale's own
exit status is nonzero for errors only, and every rule in `styles/Saxum`
is a warning, so the gate printed twelve findings and exited 0 on every run
it ever made. It now counts the findings itself and fails on any of them;
the twelve, eleven British spellings and one wordy phrase, were fixed in
the same change. And CI never installed vale, so the gate reported
COULD-NOT-RUN on every push, which is the same defect the move was meant to
close, one layer out. CI now installs vale pinned by version and sha256,
for the reason checkpatch is pinned: a different checker reports a
different finding set on unchanged prose. The version of record is 3.18.0.

The gate asserts a non-empty population before it reads anything, so a
`doc/` that has moved fails rather than passing on an empty sweep, and it
carries no negative control of its own because the failing direction was
driven by hand: a one-line document containing a British spelling turns
the run red and its removal turns it green again.

`test-provenance.sh` reads `doc/provenance.csv` and asks three things:
that no file under `src/` lacks a row, that no row names a file that is
gone, and that every row claiming a byte-for-byte carry still IS one.
Only the third asks a question this repository cannot answer alone, and it
is the reason the gate exists: an origin, commit and license claim is the
first thing an upstream reviewer checks and the last thing anyone can
reconstruct afterwards. So it is re-run with `cmp` against the origin
clone rather than read. Where no clone is on the machine, nothing was
verified that this tree could not verify about itself, and the gate exits
2 rather than passing on a table that only agrees with itself; CI clones
the origin at the commit the CSV names so that check runs on every push.
What it cannot do is in its own header: `derived` and `ours` rows have no
mechanical test, so they are counted in the summary rather than checked.

`test-syntax.sh` compiles `hammer2.h` and `hammer2_io.c` against the real
kernel headers **with two compilers**, clang and gcc, under a W=1-class
warning set. Two compilers because they disagree about what is worth
saying, and a single one is a single opinion: both independently reported
the `LIST_HEAD` and `RB_ROOT` redefinitions, which is what made those
credible rather than stylistic. A warning in a file under `src/` fails the
gate; one in a kernel header does not, since we do not own those and
cannot fix them. gcc is optional and the gate says so when it is absent.
Its header line names WHICH resolution it took - `KDIR`,
`/lib/modules/$(uname -r)/build`, or the nix-store fallback - because a
fallback that has never fired is indistinguishable from one that works.
That is not hypothetical here: `IO_MODEL.md` described the nix branch as
the source of the kernel of record while the `/lib/modules` path was
present on every run, so the document and the script agreed in wording and
disagreed in behavior, and nothing could notice. Point `KDIR` at a path that
does not exist to exercise the fallback: it then resolves nothing and returns
COULD-NOT-RUN naming itself.

It also refuses a kernel that is not the one of record: this tree compiles
against the latest Linux, the pin is `KERNEL_REF` in the script, and a
tree of any other version is COULD-NOT-RUN. `H2_KERNEL_REF` checks another
version deliberately, which is the only way that reads as a pass.
It carries two more controls: a wrong folio call that the
same headers must refuse, and the 64KB ceiling guard, which must fire when
the ceiling is shrunk. Set `KDIR` to test against a tree other than the
running kernel's.

`test-checkpatch.sh` is the odd one: it does not ask for silence, it asks
that the recorded deviation set has not grown. It identifies its checker by
`sha256` against the baseline's second line, and prints where every value
came from, because an ASSERTED version and a DERIVED one used to render
identically: pointed at the v6.15 checker with `CHECKPATCH_REF=v7.2`, it
reported a real style regression, the assertion having laundered a wrong
checker into a verdict about this code. A content mismatch is
COULD-NOT-RUN now whatever names the checker carries. See
[README.kernel-style.md](README.kernel-style.md) for why this tree is BSD
style on purpose and what that means for mainline. Both of its sorts are
`LC_ALL=C`, because the baseline is compared byte for byte and glibc
collation differs between machines; the first CI run failed with every
count identical and four lines in a different order.

None of the compile gates runs anything. `-fsyntax-only` compiles nothing
and links nothing, which is the honest limit of what can be checked before
a module builds.

The repository gates check the documentation against the tree rather than
the tree against a compiler. `test-inventory.sh` reads the three
hand-maintained lists that claim to cover `src/sys/fs/hammer2/`, reports a
file missing from any of them, and compares the origin table's line count
against the file it names. `test-citations.sh` reads the `file:line` citations that sit in a
`doc/` table row against the line each names, comparing against the source
rather than a stored baseline, and grades each pass by how specific its
anchor is, so a row anchored on a common token is reported as weak rather
than counted with the strong ones. It checks table rows only, and prints
how many citation-shaped tokens it left alone: 33 on 2026-09-02, of which
32 are in `doc/research/` and name line numbers in DragonFly's own tree,
which this repository cannot resolve. That is why the exclusion exists,
and the count is printed rather than assumed so a prose citation into
`src/` cannot hide in it. The one that is such a citation,
`hammer2_chain.c:2189` in `doc/README.porting.md`, was read by hand on the
same day and lands on the `LOCKAGAIN` branch the sentence describes.
`test-history.sh` checks that every roadmap row's commit hash resolves
with a matching subject, and names any deliverable commit that has no row.
`test-inventory.sh` also reads the `DEFER` ledger in
`doc/README.status.md` against `src/` in both directions: a marker with no
row, and a row whose marker the source no longer holds. The second is the
one nothing else would catch, since a deleted marker leaves a row reading
as outstanding work forever. The match is on the marker text verbatim, so
rewording a trigger in one place and not the other is a failure rather
than a drift. Both directions were driven on 2026-08-26 by making each
break in turn.

`test-inventory.sh` has a second population, `test/`, where every file
must either be named by a gate or be listed as staged below. It also
checks two DIFFERENT claims about the gates themselves: that no document
states a wrong COUNT of them, and that the three documents printing
runnable command lists NAME every one. Those are not the same check -
The agent instructions file, since untracked, said "eight" correctly on
2026-08-26 while listing seven, so
the count passed and the list a future reader would run was short by the
newest gate.
What none of them can check is whether a row's CLAIM is true; that takes a
person reading the artifact the row names.

`test-syntax.sh --selftest` and `test-checkpatch.sh --selftest` check the
two prints that separate a loosened run from a real one: the override
warning and the checker's `sha256` provenance. Both prints were added on
2026-08-26 to fix the class where output nobody reads is trusted, and
neither was read by anything, which is that same defect arriving inside its
own repair. The syntax selftest failed on its first run because the warning
WRAPS and the matcher read one line at a time - a rule about matching
wrapped prose not firing while writing a matcher for wrapped prose. CI runs both, and derives which gates have a `--selftest` rather than
naming them. They re-invoke their own gate with `bash`, never `sh`: the
first version used `sh "$0"`, which works on a machine whose `/bin/sh` is
bash and is a syntax error under dash, so it passed here and failed on the
runner. That is the class of defect a local run cannot reach, and it is
what CI is for.

The syntax selftest's unoverridden direction is exercised only where the
kernel of record is present. Elsewhere it prints a note saying it was not
exercised, rather than failing: on a hosted runner that tree is absent, and
failing there would turn an environment difference into a red gate.

The syntax selftest's third check is a designed guard replacing an
accidental one. The gate reads `VERSION`/`PATCHLEVEL` from a build tree's
own `Makefile`, so `linux-api-headers` cannot satisfy it - and that
immunity was luck of construction, not intent, until the check existed. A
guard nobody designed is a guard nobody maintains. The specimen is a
directory holding nothing but an `include/linux/version.h` claiming 7.2,
which must be COULD-NOT-RUN. Falsified with the plausible improvement a
later maintainer makes, a `version.h` fallback when the `Makefile` is
missing: the gate then accepts the fake and prints `7 check(s), 5 failed
against the kernel of record (7.2)`, charging five failures to this code
on behalf of a kernel that does not exist.

Every gate that uses a toolchain names the one it used, and every gate
that resolves a tree names how it resolved it. The reason is a shape worth
recognizing: where the DEFAULT invocation and a deliberate one answer
different questions, the unattended run and the careful run disagree and
only the careful one is ever right, while both print the same summary. It
was live on 2026-08-26 in the syntax gate, which needed `KDIR` typed to
reach the kernel of record, and in the style gate, which read the host's
build tree while the record's own `checkpatch.pl` sat in the store. It was
live in `test-shim.sh` too, though not in the direction that sentence
guessed. It said a reviewer reaching for clang would get a different
opinion; what happened on 2026-08-26 is that two versions of the same
compiler disagreed. GCC 13 on the runner accepted a `struct file` the
stub tree never declared and GCC 16 here warned about it, so `346dac6`
was green in CI and red on the workstation. The gate names its compiler
in its header line and does not require one, which is the right trade for
a gate whose whole point is needing nothing but `cc`: two opinions are
worth more than one pinned opinion, as long as a disagreement is read as
a finding rather than a flake. It is still true of the vectors
contract.

That sentence opened with a count instead of naming them, and
`script/test-inventory.sh` failed it: a number word immediately before
"gates" is compared against how many gates exist, so a PARTIAL count in
that shape is a finding. The gate was right, and naming them costs
nothing. The first attempt to document this failed the same check again,
because writing the offending phrase in an explanation is still writing
it - the check reads the file, not the intent.

On a hosted runner `test-syntax.sh` is the only gate that declines, because
the kernel of record is the latest release and `ubuntu-latest` ships
headers years behind it. That is recorded as a skip and never as a pass.
Everything else runs there, including the vectors contract's behavioural
half, which had been declining for want of an xxHash to link until
`libxxhash-dev` was added to the runner on 2026-08-26.

`test-posix.sh` parses the gates declaring `#!/bin/sh` with dash and
busybox ash. It exists because every gate here is normally run by bash, so
a bash-only construct in such a script runs forever and breaks the day
something honors the shebang - which happened on 2026-08-26, when both
selftests re-invoked their gate with `sh "$0"` and failed on a runner
whose `/bin/sh` is dash.

It MEASURES its own reach on every run and prints it as observed, rather
than asserting a table. A gate stating its own coverage is a claim nothing
checks, sitting in the one place a reader uses to decide whether a clean
run means anything - and this one was wrong twice while being written,
first at one construct, then at three, where there are four. An UNDER-claim
is still a false claim and it is the one nobody re-checks, because a modest
statement about your own instrument reads as rigour.

What it asserts instead are two properties of a working checker, which hold
whatever the reach turns out to be: each shell must reject at least one
probe, or it is inert here and a clean result means nothing; and a plain
POSIX script must be accepted, or the instrument refuses everything and a
clean result is unreachable rather than earned. Falsified both ways -
making every probe inert, and making the plain script unparseable, each
fail naming which property broke. With no shell realized the gate exits 2.

Observed on 2026-08-26: dash rejects process substitution, arrays, the
`function` keyword and here-strings; busybox ash rejects arrays and
here-strings; both accept `[[ ]]`, `declare`, `local`, `+=`, arithmetic,
ANSI-C quoting and brace expansion as ordinary words. So a clean run means
"no bash SYNTAX" and never "no bashisms". The hosted runner reproduced
those figures exactly, on a different distribution.

Finding the shells was itself the lesson. This repository recorded that no
POSIX shell existed here, from `command -v`, which reads PATH - and PATH is
not the machine. Both were already in the nix store. Asking PATH about a
machine whose software lives in a store is the same error as asking a
package version about an artifact.

## Run what CI runs, before pushing

CI was being used as a compiler: one push per question, each answer
arriving as a failure notification. Twenty-six such runs between
2026-08-29 and 2026-09-03, and two more on 2026-09-04 when the checkpatch
pin moved and the gate selftests were not run locally, which CI runs as a
step of its own.

`script/pre-push-check.sh` runs every `script/test-*.sh` and every gate
selftest, the selftests enumerated by implementation rather than by name
the way CI enumerates them. Install it:

    $ ln -sf ../../script/pre-push-check.sh .git/hooks/pre-push

It is not named `test-*.sh` and does not live among the gates as an equal:
the eleven are run individually on purpose, and one exit status for eleven
questions is the thing this repository does not want. `H2_SKIP_PREPUSH=1`
overrides it for a push that is deliberately ahead of a green tree.

It fetches the checker the baseline records and caches it under
`$XDG_CACHE_HOME/linux_hammer2`, keyed by the sha256 the baseline names.
Without that the style gate finds whatever checker the machine has, cannot
attribute a moved deviation set to this code, and reports COULD-NOT-RUN,
which this check would report as a warning: a real style regression would
then pass a push. Both directions were driven before it was committed. On
a clean tree it exits 0; with one category count altered in the baseline
it names the moved line and exits 1.

## Two trees at the kernel of record, both required

The port claims to build against an unpatched Linux, and the distribution
that consumes it ships a patched and optimized one. Those are two claims and
the version pin cannot separate them, since it compares `VERSION` and
`PATCHLEVEL` and a patched tree satisfies it exactly as mainline does. Run
both and record both lines:

    bash script/test-syntax.sh
    KDIR=/nix/store/<hash>-linux-*-dev/lib/modules/*/build bash script/test-syntax.sh

The first takes the unpatched tree, preferring it over a patched one at the
same version, and searches `/lib/modules/$(uname -r)/build`, then anything
in `H2_KERNEL_TREES`, then `$HOME/kernels/*`, then the store. The second
names the patched tree deliberately.

Both the header line and the summary line carry the release string and
either `mainline` or `patched`, read from the tree's `EXTRAVERSION`:
anything left after stripping a leading `-rcN` was added by whoever built
the tree. A kernel built here with its own optimization carries a suffix
too and so classifies without being named.

The summary line is the one that gets quoted into a document, which is why
it carries the tree rather than the release series alone. A quotation that
named only the series was written into `README.status.md` describing a
mainline tree while the run behind it had used the store's patched one.

The same distinction applies to the module. `make KDIR=<tree>` against the
two produces `vermagic: 7.3.0-rc1` and `vermagic: 7.3.0-rc1-cachyos`, which
do not interchange: a module built against one is refused by the other
before any of its code runs.

## Getting a kernel newer than the distribution ships

The kernel of record moves faster than any guest in the fleet, so testing
against it means installing a kernel rather than finding one. Two routes
are known to work and neither needs a kernel build.

Fedora carries the current stable series and the development series side by
side, and its kernel packages have shallow enough dependencies to install
across a release. Both of the kernels this port has been loaded on came
from there, into a guest that was running Fedora 44:

    # dnf --releasever=45 --enablerepo=updates-testing -y \
        install kernel-7.2.3-300.fc45 kernel-devel-7.2.3-300.fc45
    # dnf --repofrompath=raw,https://dl.fedoraproject.org/pub/fedora/linux/development/rawhide/Everything/x86_64/os/ \
        --repo=raw --nogpgcheck -y install kernel-<exact-nevr> kernel-devel-<exact-nevr>
    # grubby --set-default /boot/vmlinuz-<version> && reboot

Name the exact version. `dnf install kernel` against a repository that
already has some kernel installed reports `Nothing to do` and exits 0,
which reads as success and installs nothing. List first, with
`list --showduplicates`, and install what the listing names.

Installing across a release upgrades what the kernel package depends on.
The 7.2.3 install above pulled Fedora 45's glibc, gcc and openssl into a
Fedora 44 guest. That is fine for a disposable test guest and is worth
knowing before doing it to one that is not.

The second route is the `chaotic-cx/nyx` nix flake, which packages the
CachyOS kernels and had a cached 7.3-rc1 build on 2026-09-03. It is a
substitution rather than a build. The CachyOS pacman repository is a
different channel with its own cadence and had no 7.3 kernel on the same
day, so a reading of one says nothing about the other.

## Every COULD-NOT-RUN branch has been driven

An error path nobody has driven is an untested branch wearing the costume
of a safety net: it reads as defensive prose rather than as code, so it is
the last thing anyone thinks to exercise. Every such branch was driven on
2026-08-26, in a scratch copy of the tree, by removing the input each one
names. The count is deliberately not written here: it would be a second
claim about the same population as the table below, with nothing checking
it, and this file has already recorded one instance of a count and a list
disagreeing. Read the table.

| gate | branch | how it was driven |
|---|---|---|
| `test-citations.sh` | no `doc/*.md` | the directory moved aside |
| `test-provenance.sh` | no origin clone, so no carry re-verified | `H2_CLONE_DIR` pointed at a path that does not exist |
| `test-history.sh` | not a repository | `.git` moved aside |
| `test-history.sh` | no roadmap | the file moved aside |
| `test-inventory.sh` | no `src/sys/fs/hammer2` | moved aside |
| `test-absence.sh` | the population is empty | `doc/` and `src/` moved aside |
| `test-absence.sh` | no claim matched, so the pattern has stopped | the phrase it matches renamed in a scratch copy of the gate |
| `test-absence.sh` | a claim naming a symbol that IS defined | `hammer2_chain_lookup()` and `hammer2_chain_scan()` appended to `README.porting.md`, the second wrapped across two lines |
| `test-inventory.sh` | no `test/` | moved aside |
| `test-checkpatch.sh` | no baseline | moved aside |
| `test-checkpatch.sh` | no `checkpatch.pl` | `CHECKPATCH` at a path that does not exist |
| `test-checkpatch.sh` | no perl | a `PATH` assembled from store paths holding none |
| `test-vectors-contract.sh` | a vector file missing | moved aside |
| `test-shim.sh` | no compiler | `CC` naming one that does not exist |
| `test-syntax.sh` | no kernel build dir | `KDIR` at a path that does not exist |
| `test-posix.sh` | no shell realized | `H2_DASH` and `H2_BUSYBOX` at paths that do not exist |
| `test-doc-prose.sh` | no vale | a `PATH` holding none, driven 2026-09-02 |

All exit 2 and name what was missing. Two defects fell out of driving
them: `test-shim.sh` was the only gate whose message omitted the
`COULD-NOT-RUN` prefix, so anything scanning output rather than status
would have missed it; and `test-posix.sh` had no way to reach its own
no-shell branch, because the store lookup finds a shell on any machine
that has one, which is why the override exists.

**An absent tool must decline, never pass.** A probe whose success is
cheap to satisfy trivially - an absent binary above all - reports a clean
run having examined nothing, and the summary looks identical either way.
Measured 2026-08-26 by naming a compiler that does not exist:
`test-shim.sh`, `test-syntax.sh` and `test-vectors-contract.sh` each exit
2 and name what was missing, and the vectors gate says which half it still
completed. `test-checkpatch.sh` exits 2 with `no perl` under a `PATH`
assembled from store paths for coreutils, sed, grep, diff, awk and bash,
which contains no perl.

That fourth one was recorded here as UNVERIFIED for an hour, on the
grounds that emptying `PATH` breaks the shell and perl cannot be hidden by
directory because it shares one with everything else the gate needs. Both
facts are true and the conclusion was wrong: a nix machine keeps each tool
in its own store path, so a `PATH` without perl is assembled rather than
subtracted. **"I cannot check this" is itself a claim about an
instrument** and decays like any other. The honest form is UNVERIFIED BY
THIS ROUTE with the route named, because naming the index is what lets the
next reader see the wrong one was asked - "perl cannot be hidden" carries
no trace of "by directory, on a PATH-shaped machine".

Exit 2 from any gate here means the instrument could not run: no
compiler, no kernel headers, no `checkpatch.pl`, or a population that came
back empty. That is not a verdict on the code, and it should not be
recorded as a failure.

`test-vectors-contract.sh` belongs to neither group. It
asserts that this repository still keeps the promises the next section
describes: the `-DXXH_VECTORS_CONTROL` hook, the uppercase hex constants,
the `printf` that writes `Castagnoli ... MATCH`, and the `printf` that
opens a line with `XXH64` and carries `want`. Where an xxHash is
available to link against it also runs the vectors and requires exit 0,
then compiles with the control define and requires nonzero, because a
status only ever observed as 0 is not tested. That run is also where the
wording is read out of the program's own output rather than only out of
its source, since stdout is the surface the consumer reads: a `printf`
left in the file but reached under a condition that never holds passes
every source check and prints nothing. It carries a negative
control that runs every time: a lowercased copy of the file must fail the
comparison, since a case-sensitive check and a case-insensitive one look
identical while both are passing, and only the case-sensitive one catches
the defect that actually happened.

Every pattern in it is anchored on the code rather than on a token. These
files describe their own contract in comments, so a check for
`Castagnoli.*MATCH` matched the comment quoting it and stayed green after
the `printf` was deleted. That was found by running the control, not by
reading the gate.

## What was falsified, and when

A fixture is not shown to work by its own green run, and reading a fixture
you just wrote is the least reliable way to answer whether it tests
anything. So each of these was run against the defect it exists for rather
than merely run. This is a LIST OF WHAT WAS DONE, not a claim that
everything has been done: an "every check has been falsified" sentence is
a claim about a population that grows, so it would be false the moment a
check is added rather than eventually, and nothing would notice. A new
check comes with the run that showed it failing, added here.

| falsified on | check | how |
|---|---|---|
| 2026-08-26 | `xxh64: -DXXH_VECTORS_CONTROL hook present` | the `#ifdef` replaced with `#if 0`, comment left in place |
| 2026-08-26 | `xxh64: constants uppercase` | the constant lowercased |
| 2026-08-26 | `xxh64: HAMMER2 seed uppercase` | that constant lowercased separately, because sharing a code path with something falsified is not being falsified |
| 2026-08-26 | `crc32c: a printf writes 'Castagnoli' then 'MATCH'` | the `printf` reworded, comment left in place |
| 2026-08-26 | `xxh64: a printf opens with XXH64 and carries 'want'` | the prefix renamed to `XXHASH64` in the source |
| 2026-08-26 | the wording negative control | the `printf` line stripped from a copy, which must stop the pattern matching |
| 2026-08-26 | `the output opens lines with XXH64 and carries 'want'` | the `printf` guarded by `if (0)`, so the source check passes and stdout is empty. Falsified separately from the source check for that reason: under a rename the gate exits on the source failure and never reaches this one |
| 2026-08-26 | the vectors negative control | the shared `matches()` made case-insensitive |
| 2026-08-26 | `an overridden run says so in its summary` | the override warning deleted, and again partially |
| 2026-08-26 | `a UAPI-shaped tree claiming 7.2 is COULD-NOT-RUN` | a `version.h` fallback added, the improvement a later maintainer plausibly writes |
| 2026-08-26 | the checkpatch selftest | the `sha256` mismatch text deleted |
| 2026-08-26 | `posix`: each shell rejects a probe | every probe body replaced with `echo`, which reports the shell inert |
| 2026-08-26 | `posix`: a plain script is accepted | the plain script made unparseable, which reports a clean result unreachable |
| 2026-08-26 | `test-checkpatch.sh` declines without perl | run under a `PATH` assembled from store paths holding no perl |

**A DATE REPAIRS AGING AND NEVER FALSIFICATION**, and the two get treated
as one thing. A dated completeness claim still says something false the
moment the population grows: the date stays true while the sentence stops
being, so nothing about it looks stale. That is why this is a table of
what was done rather than a dated sentence about everything.

**No gate derives this table, and that is deliberate.** The population is
checks inside scripts. Counting invocations by grep is the
hand-maintained-list defect one level up wearing a regex, and running
every gate from inside another gate to read its printed count couples the
gates for a claim that is documentation rather than behavior. Written
here rather than settled in conversation, because a decision not to build
something is invisible to the next reader unless it is in the tree they
grep. The specification repository reached the same answer about its own
typed list for a better reason: extensionless documents have no extension
to enumerate on.

The syntax selftest's second direction, that an unoverridden run carries
no override warning, was left out of that table while it was vacuous: with no
kernel of record installed, an unoverridden run is COULD-NOT-RUN and carries
no warning either way. It stopped being vacuous on 2026-08-26, when such a
run began really compiling.

## Run from outside this tree, by a gate in another repository

A test file nothing runs reads exactly like a test file that passes, so
these two were written up on 2026-08-26 as staged and unrun. That was
wrong within the hour, and wrongly reassuring in the direction that costs
most: no gate HERE runs them, and Saxum's
`scripts/test-hammer2-checkalg.sh` compiles both, against the FreeBSD
port's vendored `xxhash` and its `icrc32.c`, reaching this tree through
`LINUX_HAMMER2`. The sweep that concluded "run by nothing" searched this
repository only, which is the whole of the mistake: a consumer one
directory over answers a question no local grep can.

**What that makes them.** Four things are an interface with a consumer that
cannot be seen from here: the exit status of each file, the wording of the
`Castagnoli ... MATCH` line, the `XXH64` prefix and `want` that the consumer
counts its vectors by, and the uppercase hex of the xxh64 constants. The
rewrite that fixed their logic lowercased one constant, Saxum's negative
control seds on that literal, and its gate spent an hour reporting
correctly that it was comparing nothing. `-DXXH_VECTORS_CONTROL` exists so
that control never has to depend on this file's text again.

No gate here reaches into another repository to check any of that, and
none should: the port stands on its own. The contract is written down
instead, in the table below and in each file's header, and
`script/test-inventory.sh` fails on any file under `test/` that neither a
gate names nor this table lists.

| file | run locally when | state on 2026-08-26 |
|---|---|---|
| `test/crc32c-vectors.c` | `iscsi_crc32()`, which arrives with the check algorithms in 0.2 | the exit status accepted either CRC-32C or CRC-32 IEEE, so the one question it exists to ask went unanswered while it reported success. Now it accepts Castagnoli only, and names IEEE when it sees it |
| `test/xxh64-vectors.c` | an `xxhash.h` in this tree, same import | two of three cases asserted nothing, and the seeded case used xxHash's golden-ratio prime where HAMMER2 seeds with `0x4d617474446c6c6e`. Four vectors now, all four measured against xxhsum 0.8.3 and libxxhash 0.8.3, and compiled and run green against the system xxHash on 2026-08-26 |

Neither is wired into a gate HERE, because there is nothing in this tree
to link either against; Saxum links them against the BSD tree instead.
They get a local gate the day 0.2 imports the algorithms, and the
inventory gate is what remembers to ask. Until then, changing either
file's output shape or exit status breaks a gate in a repository this one
does not reference.

## What the real test will be

A volume created by DragonFly's `newfs_hammer2`, mounted here, compared
file by file; then the reverse. HAMMER2 writes an XXH64 digest into every
blockref and every implementation verifies it, so a subtly wrong port
produces volumes that read as corrupt on DragonFly rather than as buggy.
The cross-implementation round trip is the only test that catches that,
and no amount of self-consistency substitutes for it.

## The gates that will watch a running system

Every gate here reads a file that is not changing while it reads. The gates
0.3 and after do not: a build-and-load script watches a guest boot, and the
crash matrix watches a filesystem being cut off mid-write. Those gates can
fail in a way none of the current ones can, by sampling before the phase
they are about begins. A guest that has not yet loaded the module reads
clean for the same reason a healthy one does, and the sample carries no
timestamp saying which it was, so nothing in the output distinguishes them
afterwards.

It does not feel like guessing, because the activity is measuring, and it is
measuring, of the wrong phase. The reading that survives review is the one
that happened to be right anyway, which is invisible to anyone checking
answers rather than method.

So a gate that samples a running system carries a positive control: something
that MUST move during the phase under test, sampled in the same pass as the
measurement. A module load that has begun has a `dmesg` line; a write that
has begun has a growing device. An unchanging number with no such control is
unproven rather than reassuring, and a gate resting on one is asserting its
own conclusion.

This is the same requirement as the negative controls above, one axis over.
Those ask whether the instrument can fail at all. This asks whether it was
looking while there was anything to see.
