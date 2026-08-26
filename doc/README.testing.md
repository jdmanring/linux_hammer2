Testing
=======

Seven gates run today, all cheap. Most fall into two groups, and the split
matters when you are deciding which to run: the compile gates need a
toolchain and a kernel tree, the repository gates need neither. The
seventh, `test-vectors-contract.sh`, is neither and is described below.

Compile gates:

    $ bash script/test-shim.sh        # needs only a C compiler
    $ bash script/test-syntax.sh      # needs kernel headers and clang
    $ bash script/test-checkpatch.sh  # needs scripts/checkpatch.pl

Repository gates, POSIX sh over grep, sed and git, no kernel and no
network:

    $ bash script/test-inventory.sh   # the three lists that claim to cover src/
    $ bash script/test-citations.sh   # every file:line citation in doc/
    $ bash script/test-history.sh     # every roadmap row's commit hash

`test-shim.sh` compiles `hammer2_os.h` and `hammer2_compat.h` against the
stubs in `test/stub`, in both positions of the `HAMMER2_INVARIANTS` knob,
plus a negative control: the header is broken on a copy and the compile
must fail. Without that control a gate whose healthy signature is silence
cannot be told from a gate that never opened the file.

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
disagreed in behaviour, and nothing could notice. Point `KDIR` at a path
that does not exist to exercise the fallback; on this workstation it
resolves nothing and returns COULD-NOT-RUN naming itself, which is the
first time that branch has ever run.

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
against the file it names. `test-citations.sh` reads every
`file:line` citation in `doc/` against the line it names, comparing
against the source rather than a stored baseline, and grades each pass by
how specific its anchor is, so a row anchored on a common token is
reported as weak rather than counted with the strong ones.
`test-history.sh` checks that every roadmap row's commit hash resolves
with a matching subject, and names any deliverable commit that has no row.
`test-inventory.sh` has a second population, `test/`, where every file
must either be named by a gate or be listed as staged below.
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
recognising: where the DEFAULT invocation and a deliberate one answer
different questions, the unattended run and the careful run disagree and
only the careful one is ever right, while both print the same summary. It
was live on 2026-08-26 in the syntax gate, which needed `KDIR` typed to
reach the kernel of record, and in the style gate, which read the host's
build tree while the record's own `checkpatch.pl` sat in the store. It was
latent in `test-shim.sh` and in the vectors contract, whose `cc` is gcc
here while a reviewer reaching for clang gets a different opinion by
construction.

That sentence opened with a count instead of naming them, and
`script/test-inventory.sh` failed it: a number word immediately before
"gates" is compared against how many gates exist, so a PARTIAL count in
that shape is a finding. The gate was right, and naming them costs
nothing. The first attempt to document this failed the same check again,
because writing the offending phrase in an explanation is still writing
it - the check reads the file, not the intent.

Exit 2 from any of the seven means the instrument could not run: no
compiler, no kernel headers, no `checkpatch.pl`, or a population that came
back empty. That is not a verdict on the code, and it should not be
recorded as a failure.

`test-vectors-contract.sh` is the seventh and belongs to neither group. It
asserts that this repository still keeps the promises the next section
describes: the `-DXXH_VECTORS_CONTROL` hook, the uppercase hex constants,
and the `printf` that writes `Castagnoli ... MATCH`. Where an xxHash is
available to link against it also runs the vectors and requires exit 0,
then compiles with the control define and requires nonzero, because a
status only ever observed as 0 is not tested. It carries a negative
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
| 2026-08-26 | the vectors negative control | the shared `matches()` made case-insensitive |
| 2026-08-26 | `an overridden run says so in its summary` | the override warning deleted, and again partially |
| 2026-08-26 | `a UAPI-shaped tree claiming 7.2 is COULD-NOT-RUN` | a `version.h` fallback added, the improvement a later maintainer plausibly writes |
| 2026-08-26 | the checkpatch selftest | the `sha256` mismatch text deleted |

**A DATE REPAIRS AGING AND NEVER FALSIFICATION**, and the two get treated
as one thing. A dated completeness claim still says something false the
moment the population grows: the date stays true while the sentence stops
being, so nothing about it looks stale. That is why this is a table of
what was done rather than a dated sentence about everything.

**No gate derives this table, and that is deliberate.** The population is
checks inside scripts. Counting invocations by grep is the
hand-maintained-list defect one level up wearing a regex, and running
every gate from inside another gate to read its printed count couples the
gates for a claim that is documentation rather than behaviour. Written
here rather than settled in conversation, because a decision not to build
something is invisible to the next reader unless it is in the tree they
grep. The specification repository reached the same answer about its own
typed list for a better reason: extensionless documents have no extension
to enumerate on.

The syntax selftest's second direction, that an unoverridden run carries
no override warning, was NOT in that table while it was vacuous: an
unoverridden run on this workstation was COULD-NOT-RUN and carried no
warning either way. It stopped being vacuous on 2026-08-26 when the kernel
of record arrived in the store and such a run began really compiling. The
comment describing it as weak was stale within minutes of the tree
landing, which is the price of a sentence about the current state.

## Run from outside this tree, by a gate in another repository

A test file nothing runs reads exactly like a test file that passes, so
these two were written up on 2026-08-26 as staged and unrun. That was
wrong within the hour, and wrongly reassuring in the direction that costs
most: no gate HERE runs them, and ArtNix's
`scripts/test-hammer2-checkalg.sh` compiles both, against the FreeBSD
port's vendored `xxhash` and its `icrc32.c`, reaching this tree through
`LINUX_HAMMER2`. The sweep that concluded "run by nothing" searched this
repository only, which is the whole of the mistake: a consumer one
directory over answers a question no local grep can.

**What that makes them.** The exit status of each, the wording of the
`Castagnoli ... MATCH` line, and the uppercase hex of the xxh64 constants
are an INTERFACE with a consumer that cannot be seen from here. The
rewrite that fixed their logic lowercased one constant, ArtNix's negative
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
to link either against; ArtNix links them against the BSD tree instead.
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
