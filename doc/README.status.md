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
| `hammer2_io.c` | 899 | hash and dedup halves carried; OS half written on the page cache |
| `hammer2_os.h` | 471 | ours, the OS shim |
| `hammer2_compat.h` | 112 | ours, kernel look-alikes |
| `hammer2_rb.h` | 146 | FreeBSD port's `RB_SCAN`, carried |
| `sys/tree.h`, `sys/queue.h` | 2165 | vendored from freebsd-src, unchanged but for `__unused` |
| `sys/cdefs.h` | 36 | ours, three names the two vendored headers need |

## What has been verified

All five gates pass. Each prints its own count, so read that rather than a
figure here; this sentence said eight checks for a day after the gcc pair
landed with `8877e3f`, which is why the counts below are dated and the gates
are the authority.

- `script/test-shim.sh` and `script/test-syntax.sh`: 3 and 7 on 2026-08-25,
  three of the ten being controls that must fail and do.
- `script/test-checkpatch.sh`: holds the style deviation set at its recorded
  579 hits, and refuses rather than writing one when it finds no baseline.
- `script/test-history.sh`: resolves every commit the roadmap's history
  table pins and checks its subject still matches, then prints how many
  commits touching `src/` or `script/` have landed since the newest row.
  That second half never fails: whether a commit deserves a version row is a
  judgment and not a gate's to make.
- `script/test-inventory.sh`: the DIRECTORY is the population, and three
  lists that claim to cover it are each maintained by hand - the origin
  table in this file, the Makefile's `hammer2-y`, and the filenames
  `script/test-syntax.sh` names one by one. A `.c` missing from the second
  is dead code; missing from the third is a file no compiler ever sees while
  every check still reports passing. Written before the core import rather
  than after it, which is the only useful time.

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

Nothing between 6.15 and 7.2 has been compiled against; the gates run on
7.2. So 6.15 is the floor the code requires, not a floor that has been
exercised, and a report from anything older than 7.2 is useful.

## What is not here

Every remaining core file: `hammer2_chain.c`, `hammer2_flush.c`,
`hammer2_freemap.c`, `hammer2_inode.c`, `hammer2_subr.c`, `hammer2_xops.c`,
`hammer2_admin.c`, `hammer2_bulkfree.c`, `hammer2_cluster.c`,
`hammer2_ondisk.c`, `hammer2_strategy.c`, `hammer2_ioctl.c`,
`hammer2_vfsops.c`, `hammer2_vnops.c`, plus the check algorithms.

Six of those are the measured carried set: `hammer2_chain.c`,
`hammer2_flush.c`, `hammer2_freemap.c`, `hammer2_bulkfree.c`,
`hammer2_xops.c`, `hammer2_admin.c`, at 10,556 lines
(`H1_ESTIMATE.md` in the distribution's tree, which measured them against all
three BSD ports). Whether `hammer2_inode.c`, `hammer2_subr.c` and
`hammer2_ondisk.c` join them is what the provenance CSV's carry column
says file by file, and that CSV is unwritten: see the roadmap's 0.2.
`hammer2_strategy.c`, `hammer2_ioctl.c`, `hammer2_vfsops.c` and
`hammer2_vnops.c` are the OS-facing ones and are rewrites.

This paragraph read "the first eight of those are expected to carry"
until 2026-08-25, which put `inode` and `subr` in the carried set on no
cited authority and pre-decided what the roadmap routes to the CSV. It
also counted POSITIONS into a prose list, so reordering the list above
would have silently changed which files the sentence claimed.
