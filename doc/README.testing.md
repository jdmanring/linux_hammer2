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

    $ bash script/test-doc-prose.sh   # vale over tracked .md, any finding is a failure
    $ bash script/test-fixtures.sh    # every fixture mounted on a guest, files compared to manifests

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

It reads a second claim shape since 2026-09-04: `->method is not written`,
resolved against the operations tables by asking whether that member is
initialized at the start of a line under `src/`. That shape was added
because the first one could not see the defect that kept recurring. Three
documents described `->iterate_shared` as unwritten after it was, and the
README's opening paragraph said the port does not mount anything for four
days after it began mounting. Its first run found `->reconfigure`
described as unwritten while it is wired into `hammer2_fs_context_ops`
and deliberately returns `-EROFS`, which is a stronger statement than the
prose was making.

Only the arrow form is read, a bare method name not being distinguishable
from ordinary prose, and only the present tense. A claim written in the
past with the commit it was true at is a dated observation and cannot go
stale, which is why `README.status.md` records the readdir floor as "was
not written at `1f025fe`". The gate carries a `--selftest` driving six
directions, including that one, on a fixture tree rather than on this
repository's own prose.

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
The permanent guard is not a new gate but an ordering: the pre-push hook
builds the module before it runs any gate, so every gate runs against the
tree a developer actually has. Until 2026-09-03 this paragraph also said that step asserts
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

## One kernel, one tree

The floor and the kernel of record are the same release, 7.3, built on
the maintainer's machine, so the syntax gate and `build-check.sh` against
that tree, both run by the pre-push hook on every push, are the only
builds there are. Hosted CI builds nothing: the runner has neither that
tree nor headers at the floor, and fetching and building a kernel there
only repeated what the push had done. From 2026-09-03 to 2026-09-05 a second CI job fetched a 6.15
tarball, built the kernel and linked the module against it, because the
floor was 6.15 and nothing had ever compiled there. It found two spellings
the floor lacked, then a type rename, then a codec `defconfig` leaves out,
then a config edit `olddefconfig` silently undid, then the `->write_begin`
signature, and the floor moved to 7.3 with the job deleted;
`README.porting.md` has the ruling. What that job taught survives it:
`build-check.sh` takes a `KDIR`, so a build against any tree is one
command, and a build that has never been run against the tree the
`#error` names is an assertion and not a constraint.

Between 2026-08-29 and 2026-09-03 this repository sent twenty-six failed
CI runs, counted by asking the API which step failed in each rather than
by remembering: twenty-one at a module build, three at the repository
gates, and two at the floor job's own assertion that its kernel tree
carries a symbol table. Two of the twenty-six were the gate's fault, a
bare `warning:` matching kbuild's compiler banner; every other one was a
real defect, in the tree or in the workflow being written at the time. So
the gates were right and the volume was a working habit rather than a
defect rate: CI was being used as a compiler, one push per question, and
each answer arrived as a failure notification to the maintainer.

`test-doc-prose.sh` runs vale over every tracked `.md` file with the
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
close, one layer out. A third was wrong until 2026-09-04: the population
was `find doc`, which is every document except the four a reader meets
first, so `README.md`, `CONTRIBUTING.md`, `CHANGELOG.md` and the pull
request template were ungoverned. That is the same defect the gate's own
header records about `doc/research/`, applied to the directory that
prompted it rather than to the tree. The README's opening paragraph said
this port does not mount anything for four days after it began mounting,
and when the population widened those four files held seven British
spellings. The population is now `git ls-files`, so a new document is
governed the day it is committed, and the three root files are asserted
by name rather than counted: a population that narrowed back to `doc/`
would still be non-empty and would still pass, which is how this gate
read past the README. CI now installs vale pinned by version and sha256,
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

It runs what CI runs, and CI's result still has to be read on the forge
after the push: three pushes on 2026-09-04 were red there on one
undefined symbol while every local gate was green, and each got its
changelog row. `gh run list` after a push is part of the push.

It fetches the checker the baseline records and caches it under
`$XDG_CACHE_HOME/linux_hammer2`, keyed by the sha256 the baseline names.
Without that the style gate finds whatever checker the machine has, cannot
attribute a moved deviation set to this code, and reports COULD-NOT-RUN,
which this check would report as a warning: a real style regression would
then pass a push. Both directions were driven before it was committed. On
a clean tree it exits 0; with one category count altered in the baseline
it names the moved line and exits 1.

## Making a fixture to mount

There is a Linux-native HAMMER2 writer on this machine and there has been
since 2026-08-25: Kusumi's `makefs` port, packaged by the distribution and
built in the store. `doc/research/HAMMER2_TEST_FIXTURE_PLAN.md` names it
and every other writer in the fleet. Nothing in this repository has to be
written to produce media, and a claim that media is unavailable is a claim
about a search, not about the machine.

    makefs -t hammer2 -o Label=TEST,MountLabel=TEST <image> <tree>

Both options or it fails: `Label=` creates the PFS and `MountLabel=` picks
where the tree lands, and with only the first the tool creates the PFS and
then tries to mount the default `DATA`.

Two costs measured rather than assumed. The image is fully allocated and
not sparse, so it occupies its full size on the filesystem holding it, and
the default size is 8 GiB. `-s 1g` is refused, and the tool reports
`trying default image size 8.00GB`, which does not agree with the
toolchain document's statement that images size in 1 GiB chunks and the
packaged test takes one. Whichever is right, an 8 GiB write per fixture is
what this machine does today, so fixtures belong on real storage and want
caching rather than regenerating.

The mount names the PFS, and a mount without one asks for `DATA`:

    mount -t hammer2 -o ro /dev/loop0@TEST /mnt/h2

An image made by `makefs` is a Linux tool's output. The milestone's claim
is about media DragonFly wrote, which is the `dragonflybsd642` guest in the
fleet, and the two are different measurements.

## The two fixtures

`f1.img` holds five paths and its largest file is 16 bytes, which is under
`HAMMER2_EMBEDDED_BYTES` and so lives in the inode. It proves the
directory operations and nothing about the on-media read path, because
every file in it takes the embedded branch.

`f2.img` exists for that reason and is built on the boundaries the read
completion branches on: 511 bytes, 512, 4096, 65536 and 200000. The pairs
matter more than the sizes. 511 and 512 straddle the embedded limit, so
one reaches the inode and the next reaches a data block, and 200000 is the
only one where a folio can begin partway through a block, which is the
arithmetic upstream has no counterpart for.

    makefs -t hammer2 -o Label=TEST2,MountLabel=TEST2 f2.img tree2

Compare with `md5sum` against the tree the image was made from rather than
by reading the files, and read at an unaligned offset inside the largest
with `dd skip=`, which no whole-file compare exercises.

`f3.img` and `f4.img` are the same tree written with
`CompressionType=lz4` and `CompressionType=zlib`. That option is why the
compressed floors stopped being unmeasurable: they had been recorded as
needing a fixture that did not exist, when the fixture was one flag away.
Before writing either decoder, run the floors against these images. The
compressible file must fail with `EIO` and name its method in `dmesg`
while the incompressible one reads, which proves in one run both that the
floor refuses rather than corrupts and that the image holds what its name
claims. A decoder written first would have had neither guarantee.

`tree3` is chosen so that one file compresses and one cannot, since a
compressor that falls back on incompressible data writes a raw block
inside a compressed volume, and that mixed case is the one a single
compressible file would miss.

    makefs -t hammer2 -o Label=TEST3,MountLabel=TEST3,CompressionType=lz4 \
        f3.img tree3

Check these two with the page cache dropped as well as cold, and scan
kmemleak twice: both decompression paths allocate per folio and the ZLIB
one also allocates an inflate workspace, so a leak here is per read rather
than per mount.

## The fixture gate

`script/test-fixtures.sh` is every read-path measurement in this document
run without a person typing them. It builds the module, starts the guest
if it is not already running, attaches each image in `H2_FIXTURE_DIR`
whose manifest is committed under `test/fixtures/`, mounts it read-only by
the label the manifest names, and compares every file with `md5sum -c`.

The manifests are here and the images are not, because an image is 2 to 8
GiB and fully allocated while the manifest is the part that constitutes
the claim. `f5.manifest` holds the checksums DragonFly itself reported
before unmounting, which is the only form that measurement can be kept in:
regenerating them on Linux would compare this module against itself.

Each manifest also records the on-media block count for every file, which
`i_blocks` carries, and the gate compares those too. A `# link target
relpath` row records a symlink, which `md5sum` follows and so never reads;
the gate compares `readlink` against it. That is an assertion
about the fixture rather than about the code: a set of matching checksums
cannot tell you that an image still holds compressed blocks, so an image
regenerated without compression would pass every checksum while the
compressed path silently stopped being exercised. What the counts do not
distinguish is one compressor from another, `f3` at LZ4 and `f4` at ZLIB
reporting the same numbers because both compress below the smallest
allocation; the floors run before either decoder existed are what
established which image is which.

The counts corrected a claim in `README.status.md` on their first run.
`d512.bin` was described there as the first file on media, and it reports
zero blocks: `hammer2_inode.c` compares `size > HAMMER2_EMBEDDED_BYTES`,
so the bound is inclusive and 512 bytes is still embedded. Two fixture
files were testing the same branch while the document said they straddled
it.

It carries a negative control per image rather than only in the selftest.
After a manifest verifies, one hash in it is altered and the same mount is
compared again, which must fail. Without that, an empty sums file, a
silent `md5sum` and a mount that landed somewhere else all read as a pass.

It leaves the machine as it found it: what it attached is detached, and
the guest is shut down only if the gate started it. It will not start one
unless `H2_FIXTURE_START=1` says so, because `script/pre-push-check.sh`
runs every gate on every push and a gate that boots a 4 GiB domain when it
finds one stopped spends that on every push, on a machine whose memory
somebody else is using.

Exit 2 is COULD-NOT-RUN and is reported for a missing guest, a stopped one
without that variable, missing images, no `KDIR` and a guest that does not
answer ssh, because most machines have none of these and CI has none at
all. A gate that passed there would make the whole read path look covered
by CI when nothing ran.

The module has two build-time controls of its own, neither ever
installed. `make HAMMER2_FOLIO_CONTROL=1` produces a module whose
mount-time folio-size check asks for twice what the kernel offers, so it
must refuse every mount and name both numbers. `make
HAMMER2_RW_EXPERIMENT=1` produces one with the read-write mount refusal
lifted, for mounting a scratch copy read-write and comparing the image
byte for byte afterwards; `README.status.md` records the first such run.
Build, load on the guest, run, read `dmesg`.

One of those is worth its own line. `KDIR` defaults to the host's own
build tree, so the first pre-push run of this gate built for the host and
reported the guest refusing to load it as a failure. `insmod` rejects a
module on vermagic, which is knowable before the attempt, so the gate now
compares the module's vermagic with the guest's release and reports
COULD-NOT-RUN naming both. A verdict reached against the wrong kernel is
an artifact of the setup and not a finding about the code.

    KDIR=~/kernels/linux-7.3-rc1 H2_FIXTURE_START=1 \
        bash script/test-fixtures.sh

Measured on 2026-09-04: eleven images, 43 files, 34 stat rows, 5 statfs
rows, 2 symlinks, one corrupt file refused, one mount refused, 0 failures.
`f12` is `f1`'s tree written by DragonFly's kernel, for the listing in
`README.status.md`.
A `# stat mode nlink uid gid inode relpath` row and a `# statfs size used
free inodes-used` row carry what DragonFly's own `stat` and `df` reported,
and `f11` exists to hold hard links, a setuid bit, an owner and a 0750
directory. The ten are `f11`, `makefs`
output, `makefs` at LZ4 and at ZLIB, the boundary tree, media DragonFly
wrote at its LZ4 default, media DragonFly wrote after `hammer2 setcomp
zlib` on the mount root, a device carrying two PFSes of which the gate
mounts `ROOT`, and two copies of the LZ4 image altered on purpose: `f9`
with one data byte flipped, whose manifest carries `# corrupt
random128k.bin` and whose other files must still verify, and `f10` with
one volume-header bit flipped, whose manifest is `# refuse` and no file
rows. `f8`, the installed DragonFly root, has no manifest here: it is
read by Saxum's walker as root and compared against two other readers,
recorded in `README.status.md`. Mounting both of `f7`'s PFSes at once is
a measurement recorded there too, since a manifest names one label.

The gate starts its guest only when no other domain is running, since
each holds 4 GiB and the host is shared with other sessions' benches;
`H2_FIXTURE_SHARE=1` overrides that. It attaches one image at a time,
always as `vdb`, and releases it before the next. It used to hold every image attached and the guest ran
out of virtio slots at the eighth, which the gate reported as an attach
failure of its own making. For `f6` the block counts in the
manifest are DragonFly's own `stat` output, so that image compares this
reader against the writer rather than against itself.

## Media DragonFly wrote

Everything above is `makefs` output, which is a Linux tool. For the
milestone's own claim the writer has to be DragonFly:

    virsh start dragonflybsd642
    virsh attach-disk dragonflybsd642 <image> vdb --targetbus virtio
    virsh reboot dragonflybsd642        # no virtio-blk hotplug there
    newfs_hammer2 -L DFLY /dev/vbd1
    mount -t hammer2 /dev/vbd1@DFLY /mnt/h2w

To ask whether a device callback reaches every PFS mounted on it, wrap
the device in a linear `dm` target on the Linux guest, mount two PFSes
from `/dev/mapper/<name>@<label>`, `dmsetup suspend` it, and `fsfreeze -u`
each mount: the thaw exits 0 on a frozen superblock and fails with
`EINVAL` on one the freeze never reached. `README.status.md` records the
result for `f7` with and without the per-mount claim.

Attach without `--mode readonly` on the DragonFly side: its HAMMER2 opens
the device for writing whatever the mount asks, and a read-only
attachment fails the mount with `EINVAL`.

For `f6` the same, with the disk attached to the shut-off domain under
`--config` so no reboot is needed, and `hammer2 setcomp zlib /mnt/h2w`
run before the first file is written, since the setting is inherited by
new inodes and does not rewrite existing ones. Root over ssh works with
the key; the unprivileged user's `doas` asks for a password.

Two things about that guest cost time. Its root shell is csh, where
`2>&1` is a syntax error rather than a redirect, so run anything with
redirection through `sh -c` or copy a script over. And it does not hotplug
virtio-blk, so a disk attached to the running domain needs a reboot to be
enumerated; `virsh reboot` keeps the same QEMU process, so a live
attachment survives it where a shutdown would lose it.

Take the checksums on DragonFly before unmounting. They are the ground
truth, and taking them afterwards on Linux would compare this module
against itself.

Run one guest at a time. Each holds 4 GiB, both together are most of what
this machine has spare, and the two halves of the test never overlap:
DragonFly writes, then is shut down, then Linux reads.

Read `stat -c %b` on the result as well as the checksum. `i_blocks` is the
on-media count, so it says which branch of the read completion each file
took, and a set of matching checksums proves nothing about which paths
ran.

## Writing to a fixture, and reading the write back on DragonFly

The write path runs only in a module built with
`HAMMER2_RW_EXPERIMENT=1`, which lifts the read-write refusal and is never
installed. It is exercised on `f13.img`, a byte copy of `f5` made with
`cp` before every run, so the untouched `f5` is the baseline every
comparison is against:

    cp f5.img f13.img
    virsh attach-disk artix-s6-kde f13.img vdb --targetbus virtio --config
    virsh start artix-s6-kde

On the guest, mount without `ro`, write, `sync`, `umount`, remount `ro`
and read the file back; then power the guest off, detach the image, and
attach it to `dragonflybsd642` the same way. DragonFly's `cat` and
`stat`, then `fsck_hammer2 /dev/vbd1`, are the verdict, and the host's
`hammer2 show` from hammer2-utils over `f5.img` and `f13.img`, diffed,
says which chains the flush rewrote and with what transaction ids.
`README.status.md` records the first such run.

Three things about a write test that a read test never needed:

- **Capture the serial console before the write.** A carried `hpanic`
  is `panic()` here, and that guest sits in a panic with nothing written
  to its disk, so the message exists only if it left the machine. The
  guest's command line carries `console=ttyS0,115200`, and on the host

      script -q -f -c "virsh --connect qemu:///system console artix-s6-kde" \
          serial.log </dev/null

  records the line into `serial.log` until it is stopped. The first
  flush panicked, and without this the panic was an ssh connection
  reset and a guest that came back with an empty log. A panic and a
  hung-task report reach the line at the default console loglevel; the
  module's own `hprintf` lines are `KERN_INFO` and do not, so write 8
  to `/proc/sys/kernel/printk` first if the transcript is to carry
  them. Two runs recorded only the shutdown for want of that.
- **Detach the test from the ssh session.** Run it under `setsid` with
  its output on the guest's root disk, then read the file after; a
  guest that resets takes the session with it, and a session that ends
  kills a test still running.
- **A hung `sync` is not a hung guest.** The hung-task detector reports
  it at `kernel.hung_task_timeout_secs`, lowered to 20 for these runs,
  and names the lock and the holder, which is how the first deadlock
  was read. `virsh destroy` is then the only way out, and it costs a
  core like a shutdown does.

## Tracing what the flush writes, and in what order

The guest kernel carries `CONFIG_BLK_DEV_IO_TRACE` but no `blktrace`
binary, and tracefs is not mounted at boot, so the trace is taken with
the block tracepoints directly:

    mount -t tracefs nodev /sys/kernel/tracing
    T=/sys/kernel/tracing
    echo > $T/trace
    echo 1 > $T/events/block/block_rq_issue/enable
    echo 1 > $T/events/block/block_rq_complete/enable
    # ... the writes ...
    echo "written, syncing" > $T/trace_marker; sync; echo synced > $T/trace_marker
    echo 0 > $T/events/block/block_rq_issue/enable
    echo 0 > $T/events/block/block_rq_complete/enable
    dn=$(lsblk -nd -o MAJ:MIN /dev/vdb | tr -d ' ' | tr : ,)
    grep -E "$dn |tracing_mark" $T/trace

The tracepoints name a device by major and minor with a comma between,
`254,16`, not by its name, and a filter written for `vdb` matches
nothing: the first two runs of this reported no events and looked like
an empty write. Print the per-device counts alongside, so an empty
filter shows against the root disk's hundreds. `doc/README.status.md`
carries the trace for one write and `sync`, in which the volume header
at sector 0 is the last request and follows a completed flush.

## Mutated media against the mount path

`script/fuzz-mount.sh N SEED` is the corpus 0.5 asks for: `N` copies of a
seed image, each with a few bytes changed at recorded offsets, hot-plugged
read-only into the running guest one after another, mounted, listed and
read end to end under the shipped build. A mount may succeed or be
refused and a file may read or fail with `EIO`; what fails the run is a
`WARNING`, `BUG`, oops, hung task or lockdep report in the guest's log,
or a guest that stops answering. The corpus is the generator and the
seed number: every image's mutations are written to the log as
`offset:old>new`, so a finding reproduces from its seed and index and no
image is kept. Two controls run before the corpus, the seed itself which
must mount with every file readable, and the seed with one bit of its
volume header crc changed which must be refused; a run whose controls
fail is a run whose reader or whose refusal detection is broken, and
its counts mean nothing.

The seed is a small volume, because the mutator samples until it hits a
byte that is not zero and a 2 GiB fixture is almost entirely zero. It
is made on the host by hammer2-utils and populated through the write
path, which needs the experimental build:

    truncate -s 64M /mnt/storage/hammer2-fixtures/fz-seed.img
    newfs_hammer2 -L FUZZ /mnt/storage/hammer2-fixtures/fz-seed.img
    # on the guest, with the HAMMER2_RW_EXPERIMENT build loaded and the
    # image attached: mount, create a few directories, files at several
    # sizes, a symlink and a hard link, sync, unmount

The image is copied under `/var/tmp/hammer2-fuzz` for each mutation,
because libvirt takes ownership of a file it attaches and the next copy
over it in the fixtures directory is refused. The script builds the
module against `KDIR`, exits 2 without a guest, a seed or a kernel tree,
and starts the guest only under `H2_FIXTURE_START=1`, as the fixture
gate does.

## The round trip both ways, from the tree

`script/f4-roundtrip.sh` is F4 as a script: it formats a 2 GiB image on
the host with hammer2-utils' `newfs_hammer2`, builds the experimental
module, boots the Linux guest to write a tree and its manifest, boots
the DragonFly guest to check that manifest and write a tree of its own,
and boots the Linux guest again to check DragonFly's manifest and what
is left of its own. Every checksum is the writer's, so neither reader
is compared against itself. It refuses to run beside a running guest,
exits 2 without both guests, the tools or a kernel tree, and shuts each
guest down when its turn is over. `KDIR` names the kernel tree, and
`H2_NEWFS` and `H2_FSCK` name the tools when they are not on `PATH`.

`script/cut-flush.sh SECONDS` is the interrupted-flush fixture: DragonFly
writes small files to a copy of `f5` with a `sync` every two hundred,
the host destroys the domain after `SECONDS`, and the cut-off image is
copied. This port mounts one copy read-write in the experimental build,
which runs the carried `hammer2_recovery()`, reads every file, writes
one more and syncs; DragonFly mounts that result and then recovers the
other copy itself. The header's two tids are printed at each stage, so
a run that cut inside the window where `freemap_tid` lags is visible;
none has yet. So the script's fourth stage makes that state on purpose:
DragonFly's recovered copy has its header's `freemap_tid` lowered by
`H2_CUT_LAG` transactions, four by default, and the sector's two CRC32C
checksums recomputed, and both recoveries run on it; the run fails
unless this port's mount announces `freemap recovery` over those
transactions and both checkers are clean afterwards. The checksum
routine is checked against the stored values before the rewrite, so a
wrong header layout stops the stage rather than making a corrupt image
that would be refused for the wrong reason.

## Listing a fixture, and what a clean run does not say

The fixture under `/mnt/storage/hammer2-fixtures/tree` is five paths: a
file, a symlink, a directory, a directory inside it and a file inside
that. It is deliberately deeper than one level, because the defect that
`->iterate_shared` found was invisible at the root: the mount root holds a
reference through `pmp->iroot` that a subdirectory does not, so an
unbalanced reference count only shows below it.

Attach the image as a disk rather than through a loop device. The Artix
guest's kernel is configured by `localmodconfig` against its own loaded
modules, which trims `CONFIG_BLK_DEV_LOOP`, and a virtio disk exercises
the 7.3 device-open shim as well:

    virsh attach-disk artix-s6-kde /mnt/storage/hammer2-fixtures/f1.img vdb \
        --targetbus virtio
    mount -t hammer2 -o ro /dev/vdb@TEST /mnt/h2
    find /mnt/h2

The attachment is live and not persistent, which `virsh dumpxml
artix-s6-kde --inactive` reports by not naming the image at all. It
survives `virsh reset`, which is why a run of resets can pass without the
disk ever being in the domain's stored configuration, and it is gone after
a shutdown. Add `--persistent` to keep it, or expect to attach it again.

A `find` is the check worth running rather than one `ls`, since it walks
every directory and reaches each one through a lookup on its parent. At
`e76ad21` it returns all five paths and exits 0, `umount` and `rmmod` both
return 0, and kmemleak reports nothing after a scan.

Two results in that run were floors and not failures: reading a file
returned `EINVAL`, `->read_folio` not being written, and `readlink` on the
symlink returned `EINVAL`, `->get_link` not being written, so `ls -l` on
a directory holding a symlink exited 1 while listing correctly. Both are
written since. A symlink's target is file data on this filesystem, so
`->get_link` is `page_get_link()` over the same `->read_folio`, which is
how the DragonFly and NetBSD ports read it too, through
`hammer2_read_file()`. The fixture gate's `# link target relpath` rows
are the check, `f1` carrying the one symlink the fixtures hold.

A clean lockdep run on this meant nothing until 0.4.3: every chain lock
took its class from one `init_rwsem()` call site, so lockdep reported
recursion at the first mount and cleared `debug_locks`. Every lock now
carries a class and a nesting level, `README.status.md` records the
measurement, and the fixture gate reads `debug_locks` before its first
mount and after its last unmount and fails if it dropped.

## Build against mainline, test against the kernel that ships

The port claims to build against an unpatched Linux, and it runs on the
kernel the consuming distribution actually ships, which is built with its
own configuration and optimization. Those are two claims and the version
pin cannot separate them, since it compares `VERSION` and `PATCHLEVEL` and
a patched tree satisfies it exactly as mainline does. Run both and record
both lines:

    bash script/test-syntax.sh
    KDIR=<the shipping kernel's build tree> bash script/test-syntax.sh

The first takes the unpatched tree, preferring it over a patched one at the
same version, and searches `/lib/modules/$(uname -r)/build`, then anything
in `H2_KERNEL_TREES`, then `$HOME/kernels/*`, then the store. The second
names the shipping kernel deliberately.

The shipping kernel is Saxum's own build, `7.3.0-rc1-saxum`, compiled from
CachyOS 7.3-rc1 with `-march=znver4` and BBR3. A stock distribution kernel
from a binary cache is not a substitute for it: it measures a configuration
nobody here runs. That kernel's `-dev` output is in the store and the
module builds against it:

    make KDIR=/nix/store/<hash>-linux-x86_64-unknown-linux-gnu-7.3-rc1-dev/lib/modules/7.3.0-rc1-saxum/build

It is built with clang 22 and thin LTO, so kbuild has to be told
`LLVM=1` or gcc rejects four of the kernel's own flags; the module
Makefile reads `CONFIG_CC_IS_CLANG` from the tree's config and adds it,
so the line above is enough. The result carries vermagic
`7.3.0-rc1-saxum` and loads on nothing else. No guest boots that kernel
yet; the Saxum server edition, which will, was not built when this was
written, so the fixture gate still runs on `artix-s6-kde` at plain
`7.3.0-rc1`. The store's `7.3.0-rc1-cachyos` figures are a superseded
measurement rather than a standing requirement.

Both the header line and the summary line carry the release string and
either `mainline` or `patched`, read from the tree's `EXTRAVERSION`:
anything left after stripping a leading `-rcN` was added by whoever built
the tree. A kernel built here with its own optimization carries a suffix
too and so classifies without being named.

The summary line is the one that gets quoted into a document, which is why
it carries the tree rather than the release series alone. A quotation that
named only the series was written into `README.status.md` describing a
mainline tree while the run behind it had used the store's patched one.

The same distinction applies to the module. `make KDIR=<tree>` writes the
tree's release into `vermagic`, and a module built against one kernel is
refused by another before any of its code runs, so the runtime test needs a
module built against the kernel it will be loaded on. The shipping kernel's
module directory is its release string, `7.3.0-rc1-saxum`, and installing
modules anywhere else leaves them where the running kernel does not search.

Building against that kernel inherits its flags through kbuild, including
`-march=znver4`, so the resulting module requires a Zen 4 host.

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
| `test-absence.sh` | a claim naming a `->method` that IS wired | `--selftest`, on a fixture tree rather than on this repository |
| `test-absence.sh` | no `->method` claim matched, so that pattern has stopped | `--selftest` |
| `test-inventory.sh` | no `test/` | moved aside |
| `test-doc-prose.sh` | a finding in a root document | a British spelling appended to `README.md` |
| `test-doc-prose.sh` | the population narrowed back to `doc/` | the file list filtered in a scratch copy of the gate |
| `test-checkpatch.sh` | no baseline | moved aside |
| `test-checkpatch.sh` | no `checkpatch.pl` | `CHECKPATCH` at a path that does not exist |
| `test-checkpatch.sh` | no perl | a `PATH` assembled from store paths holding none |
| `test-vectors-contract.sh` | a vector file missing | moved aside |
| `test-shim.sh` | no compiler | `CC` naming one that does not exist |
| `test-syntax.sh` | no kernel build dir | `KDIR` at a path that does not exist |
| `test-posix.sh` | no shell realized | `H2_DASH` and `H2_BUSYBOX` at paths that do not exist |
| `test-doc-prose.sh` | no vale | a `PATH` holding none, driven 2026-09-02 |
| `test-fixtures.sh` | no image, no guest, no `KDIR` | each driven by pointing the variable at a path that does not exist |
| `test-fixtures.sh` | a manifest that does not match the media | one hash altered in `f5.manifest`, which failed the image and named it |
| `test-fixtures.sh` | the comparison itself cannot fail | `--selftest`, and a per-image control on every run |
| `test-fixtures.sh` | a module built for another kernel | the default `KDIR`, which is the host's, against a guest at 7.3.0-rc1 |
| `test-fixtures.sh` | more images than there are target names | 26 manifests with an image beside each, which reports the ceiling rather than attaching over the last |

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
| `test/getdents-resume.c` | a directory can be listed, which it can, on a guest with a mount | `->iterate_shared` resumes across calls, which one `ls` cannot exercise: a 32 KiB buffer takes a small directory in a single call, so the branch that stops mid-directory never runs. It reads with a 64-byte buffer, one or two entries at a time, and fails on a runaway rather than hanging. Against the five-path fixture on 2026-09-04: the root gives 5 entries over 3 calls and the subdirectory 3 over 2, each name exactly once |

The first two are not wired into a gate HERE, because there is nothing in
this tree to link either against; Saxum links them against the BSD tree instead.
They get a local gate the day 0.2 imports the algorithms, and the
inventory gate is what remembers to ask. The third needs a booted guest
holding a mount, so it belongs to the read-only fixture gate the roadmap
names and is run by hand until that exists. Until then, changing either
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
