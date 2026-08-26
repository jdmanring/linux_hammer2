Status
======

Nothing mounts yet. This is the state as of the initial import, and it is
the file to correct rather than to argue with: if a claim here is stale, it
is a defect.

## What is in the tree

| file | lines | origin |
|---|---|---|
| `hammer2.h` | 1315 | DragonFly, in the FreeBSD port's shape, OS-facing types rewritten |
| `hammer2_disk.h` | 1198 | DragonFly, carried; `struct uuid` defined locally |
| `hammer2_ioctl.h` | 221 | DragonFly, carried; `<linux/ioctl.h>`, `HAMMER2_MAXPATHLEN` pinned |
| `hammer2_admin.c` | 629 | FreeBSD port, carried byte-for-byte; the xop allocation zone is shimmed |
| `hammer2_freemap.c` | 1000 | FreeBSD port, carried byte-for-byte |
| `hammer2_xops.c` | 1449 | FreeBSD port, carried byte-for-byte |
| `hammer2_bulkfree.c` | 1239 | FreeBSD port, carried byte-for-byte; `printf` and `tsleep` shimmed |
| `hammer2_chain.c` | 4929 | FreeBSD port, carried byte-for-byte; the recursive lock is NetBSD's non-recursive answer, `pause` and `__diagused` shimmed |
| `hammer2_mount.h` | 58 | FreeBSD port, carried; `hammer2_chain.c` includes it |
| `hammer2_xxhash.h` | 60 | ours: the kernel's `xxh64()` under the core's `XXH64` name and HAMMER2's seed |
| `hammer2_io.c` | 943 | hash and dedup halves carried; OS half written on the page cache |
| `hammer2_os.h` | 620 | ours, the OS shim |
| `hammer2_compat.h` | 134 | ours, kernel look-alikes |
| `hammer2_rb.h` | 146 | FreeBSD port's `RB_SCAN`, carried |
| `sys/tree.h`, `sys/queue.h` | 2165 | vendored from freebsd-src, unchanged but for `__unused` |
| `sys/cdefs.h` | 36 | ours, three names the two vendored headers need |

## What has been verified

All sight gates pass, and as of 2026-08-26 they pass HERE with no
environment variables set: the kernel of record is in the store, the
syntax gate finds it, and the style gate finds that tree's own
`checkpatch.pl`. ArtNix's delegator, which runs these same gates from
another repository, reports 7 ran and 0 could not run where it read 5 and
2 an hour earlier. Each prints its own
count; the gates are the authority, and the dated figures below are
snapshots of a particular run rather than the record.
`test-checkpatch.sh` is the one that commonly cannot run: it needs
`checkpatch.pl`, which no kernel headers package ships, so it returns exit
2 unless `CHECKPATCH` or `KDIR` points at a full source tree. That is
could-not-run and not a pass, which is the distinction the exit code
exists to keep.

- `script/test-shim.sh` and `script/test-syntax.sh`: 3 and 7 on 2026-08-25,
  three of the ten being controls that must fail and do.
- `script/test-checkpatch.sh`: holds the style deviation set at its recorded
  583 hits under the checkpatch.pl the baseline names, and under the
  kernel of record's own patched copy too, which differs from it by sha256
  and produces the identical set. Neither figure travels without the
  checker that produced it: 583 quoted bare reads as a mainline number and
  is only half one. It refuses rather
  than writing one when it finds no baseline.
- `script/test-history.sh`: resolves every commit the roadmap's history
  table pins and checks its subject still matches, then prints how many
  commits touching `src/` or `script/` have landed since the newest row.
  That second half never fails: whether a commit deserves a version row is a
  judgment and not a gate's to make.
- `script/test-inventory.sh`: the directory itself is the population, and three
  lists that claim to cover it are each maintained by hand - the origin
  table in this file, the Makefile's `hammer2-y`, and the filenames
  `script/test-syntax.sh` names one by one. A `.c` missing from the second
  is dead code; missing from the third is a file no compiler ever sees while
  every check still reports passing. Written before the core import rather
  than after it, which is the only useful time. `test/` is a second
  population, added 2026-08-26 after two vector files were found tracked and
  named in no document here; every file there is now either named by a gate
  or listed in `README.testing.md`. Both turned out to be run by a gate in
  ArtNix rather than by nothing, which no search of this repository could
  have said, so what that table records is a contract with a consumer this
  tree does not reference. It also checks the origin
  table's LINE COUNT against the file, which is the column that rots on an
  ordinary edit rather than on an import: two rows had drifted before the
  check existed. A row whose count column is not a number is left alone
  rather than guessed at.

- `script/test-citations.sh`: every `file:line` citation in a `doc/` table
  resolves, and where the row names a symbol that symbol is ON the line. The
  64 KiB inventory is thirteen such rows and nothing had ever read them; a
  line number rots on the next edit while still looking like a citation, and
  the 0.2 import edits exactly those files. It compares against the source
  line, never a stored baseline. A row naming no symbol is reported as
  unanchored rather than dropped.

That the gates pass means the shim is valid C in both knob positions, and
that `hammer2.h` and `hammer2_io.c` type-check against the real kernel
headers of a 7.2 tree with both clang 22 and gcc.

It does not mean anything runs. `-fsyntax-only` compiles nothing and links
nothing, and no module has been built or loaded. There is no VFS layer, no
mount path and no fsck integration, so there is nothing to run yet.

## The version floor, and how it was established

`BLK_MAX_BLOCK_SIZE` is the binding constraint, at **6.15**. Each symbol
was dated by reading the header at the tag rather than from memory:

| symbol | absent at | present at |
|---|---|---|
| `bdev_file_open_by_path` | | v6.10 |
| three-argument `kvrealloc` | v6.11 | v6.12 |
| `folio_mark_dirty_lock` | v6.12 | v6.13 |
| `BLK_MAX_BLOCK_SIZE` | v6.14 | v6.15 |

6.15 is the floor the code requires and not a floor that has been
exercised. The kernel of record is a different claim: this tree compiles
against the LATEST Linux, the pin lives in `script/test-syntax.sh` as
`KERNEL_REF`, and it is bumped when a release ships.

Until 2026-08-26 this file said "the gates run on 7.2" and nothing checked
it. They did not. The newest kernel tree on the development workstation is
7.1.9, there is no 7.2 in `/lib/modules`, `/usr/src` or the store, and the
gate has always printed the kernel it used in its header line while nobody
compared that string to the rule - a verdict is read off "0 failed", not
off a header. The gate now refuses a tree that is not the kernel of
record, with COULD-NOT-RUN rather than a pass.

What has actually been compiled, measured rather than assumed, on
2026-08-26 under the deliberate `H2_KERNEL_REF` override:

| kernel tree | result |
|---|---|
| **7.2.0-cachyos**, the kernel of record | **7 checks, 0 failed, both compilers, no override** |
| 7.1.9-artix1-2 | 7 checks, 0 failed, both compilers, under the override |
| 6.18.46-1-lts | 7 checks, 0 failed, both compilers, under the override |

A 7.2 VERSION STRING IS ALREADY ON THIS MACHINE AND MEANS NOTHING FOR THIS
GATE. `linux-api-headers 7.2-1` is installed, so
`/usr/include/linux/version.h` reads `LINUX_VERSION_MAJOR 7` and
`LINUX_VERSION_PATCHLEVEL 2` with no build tree anywhere near it: UAPI
headers, no `Makefile`, nothing to compile a module against. Anything that
answers "is 7.2 here" by grepping for a version string finds that and is
wrong. `script/test-syntax.sh` reads `VERSION`/`PATCHLEVEL` from the build
tree's own `Makefile`, which is why it cannot be fooled by this, and it is
recorded because the next reader will not know the difference exists.

**The port type-checks against its kernel of record**, measured 2026-08-26
after the chaotic 7.2.0-cachyos `dev` output was substituted into the store
(679 MB, `sil5r7r2a25nsshkqpd5jjjd0g7ywyi7`). The gate's own line, quoted
rather than summarised:

    hammer2 against 7.2.0-cachyos via the store, matching the kernel of record,
      dialect -fms-extensions, with clang version 22.1.8, matching the tree's own:
    syntax: 7 check(s), 0 failed against the kernel of record (7.2)

measured at `ee4a8fc`. A gate result quoted without the revision it ran
against is a figure without its scope, and this tree is a live checkout
that another session reads while this one commits to it: ArtNix's
delegator saw 6 gates where it expected 7 because it walked the tree
mid-commit, which is indistinguishable from broken unless the revision is
printed beside the count.

The compiler is a pin too, and the tree says which one rather than this
repository asserting one: kbuild records what built the kernel in
`CONFIG_CC_VERSION_TEXT`, which reads `clang version 22.1.8` here, and this
workstation's clang is byte-identical to it. So that version is the
matching one rather than an old one, and the gate prints the comparison on
every run - against the 6.18 and 7.1.9 trees it says `NOT the tree's own,
which is "gcc (GCC) 16.2.1 20260810"`.

Every syntax result recorded before that timestamp was measured against
7.1.9 and read as 7.2. An overridden run now says so in its own summary
line: until that day it printed `syntax: 7 check(s), 0 failed`, identical
to what a real reading prints, and the override is a loosened threshold
whose hiding place was that line.

**It is 7.2.0-cachyos and not mainline 7.2.** `EXTRAVERSION` is set by a
`sed` in the derivation's `postPatch`, so the release string is the
distribution's by recipe. "Against the kernel of record (7.2)" is what the
gate says and is true; "against mainline 7.2" would not be, and the two are
one word apart.

Two properties of a nixpkgs kernel `dev` output that any later measurement
against this tree has to know. Its `source/` directory is PRUNED HARD: the
recipe rsyncs the tree, deletes `drivers` wholesale, deletes unused arches,
then deletes every file it did not mark read-only. Measured here: 10,944
headers, 81 `.c` files, no `drivers` directory. So a grep of this tree for
implementation code measures the prune and not the kernel, and absence is
the normal case rather than evidence. And `checkpatch.pl` lives under
`source/scripts`, not `build/scripts`, which holds gdb helpers.

That checker is not mainline's: its `sha256` differs from the one the
baseline records. Run on 2026-08-26 it produces the deviation set
UNCHANGED at 583 hits, so cachyos's patches do not move this tree's style
figures, and the gate says the hash does not match while accepting the
version its own tree reports. That is the intended behaviour and the two
halves are printed separately.

The first run against the real tree FAILED, and the guard was wrong rather
than the tree. A nix dev output's `build/Makefile` is a three-line stub
that sets `KBUILD_OUTPUT` and includes the real Makefile from the `source`
directory beside it, so `VERSION` and `PATCHLEVEL` are not in the file the
gate was reading. It follows the `include` line the stub itself names now,
which is derived from the artifact rather than assuming a sibling
directory, and `linux-api-headers` still fails because it has no `Makefile`
at all to follow.

## What is not here

`hammer2_flush.c`, `hammer2_inode.c`, `hammer2_subr.c`,
`hammer2_cluster.c`, `hammer2_ondisk.c`, `hammer2_strategy.c`,
`hammer2_ioctl.c`, `hammer2_vfsops.c`, `hammer2_vnops.c`.

`hammer2_chain.c` landed on 2026-08-26 and the lock recursion it forced is
decided, following the NetBSD port: there is no recursive lock. A Linux
`rw_semaphore` deadlocks against its own holder exactly as a NetBSD
`krwlock` does, so `hammer2_mtx_init_recurse()` is a plain init in the
shim and the one path that recursed is closed instead of accommodated.
That path is `hammer2_chain_lookup()` reaching `chain->lock` again for an
inode in DIRECTDATA mode; NetBSD closes it by never setting
`HAMMER2_OPFLAG_DIRECTDATA`, which costs a data block for a tiny file and
costs no correctness. The flag is set in `hammer2_inode.c`, so that half
of the change lands when that file does, and until then the port has a
non-recursive lock and no code that recurses it.

`hammer2_flush.c` is next and needs a PORT DECISION rather than a shim: it
issues a device cache flush, FreeBSD through GEOM (`g_alloc_bio`,
`BIO_FLUSH`) and NetBSD through `DIOCCACHESYNC`. The ports already
disagree, so there is no precedent to follow and Linux's answer is
`blkdev_issue_flush()`.

### Logging

Every line `hprintf` prints names the module, and a line the core builds
out of several calls stays one line. Neither was true before 2026-08-26,
and neither is visible in a compile, so `test-shim.sh` reads both out of
the preprocessor's own output rather than taking a comment's word.

Linux's native mechanism for the first is `#define pr_fmt` at the top of
every `.c` file, ahead of the first kernel header. That is unavailable to
the files that do most of the logging here: they are carried
byte-for-byte, and adding a line to one is the edit this tree exists to
avoid. Measured with only `hammer2_io.c` carrying the define, five
carried files held every other call site and printed anonymously. The
name now lives in `hprintf` itself, which is this port's macro, so there
is one copy of it and no file has to remember anything.

**The literal prefix is `hammer2: `**, and a gate matching dmesg from 0.3
on should match that. It is `KBUILD_MODNAME`, which kbuild derives from
`obj-m += hammer2.o` in `src/sys/fs/hammer2/Makefile`, so it cannot drift
without the module's own filename drifting with it. Under
`HAMMER2_INVARIANTS` the function name, command and pid follow it; without
the knob, the function name alone. Both shapes start with `hammer2: `.

The second is `printf`, which on a BSD kernel appends to the open line;
`hammer2_bulkfree.c` prints a range with `hprintf` and no newline and
finishes it with `printf`. `pr_info` closes a record per call, so that
mapping turned one line into two and dropped the second's prefix.
`pr_cont` is Linux's name for the semantics the core is written against.

It is not free, and the cost is stated here rather than left for a reader
to find in dmesg. `pr_cont` deliberately does not apply `pr_fmt`, so a
`printf` that OPENS a line prints without the module name. Every plain
`printf` in the carried core was classified by hand on 2026-08-26, all
thirteen of them:

| where | sites | kind | under `pr_cont` |
|---|---|---|---|
| `hammer2_bulkfree.c` | 7 | continuations of an `hprintf` that opened the line | correct, and one line |
| `hammer2_chain.c`, in `hammer2_dump_chain` | 2 | continuations | correct, and one line |
| `hammer2_chain.c`, in `hammer2_dump_chain` | 4 | line starts | correct line structure, no module name |

So four lines in the tree print anonymously, all four inside one debug
tree dumper, and no status or error path is among them. The alternative
mapping reverses that trade: `pr_info` names those four and splits the
other nine into eighteen lines, half of them unprefixed anyway. Neither
macro can be right at both kinds of site, because the discriminator is
whether the PREVIOUS call ended in a newline, which is a runtime fact.
The `DEFER` in `hammer2_os.h` names the only mapping that is right at
both: build the line in a buffer and emit it once, which is a core edit.

checkpatch flags `pr_cont` deliberately and by name, and the deviation is
recorded in `README.kernel-style.md`.

### `XXX` marks: how much of the core is not a carry

0.2's fourth exit criterion asks for this count, because an `XXX` is the
BSD ports' mark for a mapping that is not mechanical, and the number is
how a reader knows how many places to distrust. Counting raw `XXX`
occurrences answers the wrong question: the carried files arrive with
upstream's own. Measured 2026-08-26 against the FreeBSD port at
`3df307f` (v1.2.13), by file, ours minus upstream's:

| file | `XXX` | upstream's | this port's |
|---|---|---|---|
| `hammer2_chain.c` | 18 | 18 | 0 |
| `hammer2_freemap.c` | 6 | 6 | 0 |
| `hammer2_bulkfree.c` | 4 | 4 | 0 |
| `hammer2_xops.c` | 1 | 1 | 0 |
| `hammer2_io.c` | 4 | 2 | 2 |
| `hammer2_os.h` | 4 | 0 | 4 |

Six, and none of them is in a carried file. The stronger statement is
available and was taken instead of inferred: `hammer2_admin.c`,
`hammer2_freemap.c`, `hammer2_xops.c`, `hammer2_bulkfree.c`,
`hammer2_chain.c` and `hammer2_mount.h` are byte-identical to that
upstream commit under `cmp`, so the carried core has no port edit of any
kind, marked or unmarked. The six are in the two files this port writes:
two in `hammer2_io.c` and four in `hammer2_os.h`, one of which is the
non-recursive lock above.

Six of those are the measured carried set: `hammer2_chain.c`,
`hammer2_flush.c`, `hammer2_freemap.c`, `hammer2_bulkfree.c`,
`hammer2_xops.c`, `hammer2_admin.c`, at 10,556 lines
(measured against all three BSD ports). Whether `hammer2_inode.c`, `hammer2_subr.c` and
`hammer2_ondisk.c` join them is what the provenance CSV's carry column
says file by file, and that CSV is unwritten: see the roadmap's 0.2.
`hammer2_strategy.c`, `hammer2_ioctl.c`, `hammer2_vfsops.c` and
`hammer2_vnops.c` are the OS-facing ones and are rewrites.

