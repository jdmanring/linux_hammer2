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
| `hammer2_io.c` | 953 | hash and dedup halves carried; OS half written on the page cache |
| `hammer2_os.h` | 486 | ours, the OS shim |
| `hammer2_compat.h` | 111 | ours, kernel look-alikes |
| `hammer2_rb.h` | 146 | FreeBSD port's `RB_SCAN`, carried |
| `sys/tree.h`, `sys/queue.h` | 2165 | vendored from freebsd-src, unchanged but for `__unused` |
| `sys/cdefs.h` | 36 | ours, three names the two vendored headers need |

## What has been verified

All seven gates pass on a machine that can run them all. Each prints its own
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
  583 hits under the checkpatch.pl the baseline names, and refuses rather
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
| 7.1.9-artix1-2 | 7 checks, 0 failed, both compilers, under the override |
| 6.18.46-1-lts | 7 checks, 0 failed, both compilers, under the override |
| 7.2 | no build tree on this machine, and the sentence needs the qualifier: the HOST runs 7.1.9-artix1-2 and Artix offers no newer kernel, while the STORE holds the 7.2.0-cachyos derivation with neither output realized. The `dev` output is prebuilt and signed in `nyx-cache.chaotic.cx` at 687 MB, so reaching it is a substitution and its closure, not a kernel build. The gate reports COULD-NOT-RUN until it is here |

A 7.2 VERSION STRING IS ALREADY ON THIS MACHINE AND MEANS NOTHING FOR THIS
GATE. `linux-api-headers 7.2-1` is installed, so
`/usr/include/linux/version.h` reads `LINUX_VERSION_MAJOR 7` and
`LINUX_VERSION_PATCHLEVEL 2` with no build tree anywhere near it: UAPI
headers, no `Makefile`, nothing to compile a module against. Anything that
answers "is 7.2 here" by grepping for a version string finds that and is
wrong. `script/test-syntax.sh` reads `VERSION`/`PATCHLEVEL` from the build
tree's own `Makefile`, which is why it cannot be fooled by this, and it is
recorded because the next reader will not know the difference exists.

So the current state is that the port is UNVERIFIED against its own kernel
of record, and says so out loud instead of printing green. An overridden
run says so in its own summary line too: until 2026-08-26 it printed
`syntax: 7 check(s), 0 failed`, identical to what a real reading would
print, and every such line reported from this workstation that day came
from an overridden run. The override is a loosened threshold and the
summary line is where a loosened threshold hides.

## What is not here

Every remaining core file: `hammer2_chain.c`, `hammer2_flush.c`,
`hammer2_freemap.c`, `hammer2_inode.c`, `hammer2_subr.c`, `hammer2_xops.c`,
`hammer2_admin.c`, `hammer2_bulkfree.c`, `hammer2_cluster.c`,
`hammer2_ondisk.c`, `hammer2_strategy.c`, `hammer2_ioctl.c`,
`hammer2_vfsops.c`, `hammer2_vnops.c`, plus the check algorithms.

Six of those are the measured carried set: `hammer2_chain.c`,
`hammer2_flush.c`, `hammer2_freemap.c`, `hammer2_bulkfree.c`,
`hammer2_xops.c`, `hammer2_admin.c`, at 10,556 lines
(measured against all three BSD ports). Whether `hammer2_inode.c`, `hammer2_subr.c` and
`hammer2_ondisk.c` join them is what the provenance CSV's carry column
says file by file, and that CSV is unwritten: see the roadmap's 0.2.
`hammer2_strategy.c`, `hammer2_ioctl.c`, `hammer2_vfsops.c` and
`hammer2_vnops.c` are the OS-facing ones and are rewrites.

