# Readiness audit, 2026-09-25

What the port is, what it is not, and where the instruments stop. Taken after
`1eda038`, which corrected a `SEEK_HOLE` bug that a shipped test had been
certifying, so the audit starts from the assumption that a green gate here has
been wrong before.

## Answer to the question asked

**Not ready to be a distribution's root filesystem, and no, not beyond doubt.**
That is not a hedge: four defects were found in the last hour in work already
called verified, one of them a shipped test that passed because it was written
from the implementation instead of the contract. A tree that has just done that
once cannot claim infallibility on the strength of its own gates.

What follows is what would have to change, in order.

## 1. Unverified features, and the instruments that are missing

Cross-referenced the declared capabilities against every file under `test/` and
`script/`. A feature with no instrument is not "working"; it is untested code
that compiles.

| feature | instrument | state |
|---|---|---|
| Deduplication | `test-enospc.sh` | **Closed 2026-09-25.** `test/hammer2-dedup.c` measures it on free blocks from `statfs`; a 4 MiB duplicate cost 2 blocks against the first file's 64 on a live mount. The controls (`tmpfs`, `btrfs`) both charge full price, so the reading is specific to this port. |
| Scrub | none (offline `fsck_hammer2` only) | Declared `limited`; nothing scrubs a mounted volume. |
| Quota | none | Declared `unavailable`; the core enforces none, on DragonFly either. |
| Compression | fixtures + closure | Exercised, LZ4 and ZLIB both read and written. |
| Snapshot / PFS | `pfs-domains.sh` | Exercised on both sides. |
| Bulkfree | `bulkfree.sh` | Exercised. |
| Growfs | ioctl exercise, fixtures | Partly: the ioctl is driven, the growth is not measured. |

Dedup was the gap that mattered most relative to its billing: `README.md`'s
opening paragraph names "block-level deduplication" among the format's features
a reader is meant to find here, and it had no instrument. It does now, and it
passes, with controls that fail. A feature advertised in the first paragraph
and exercised by nothing is the shape this project has a rule about.

## 2. Performance: the sequential half measured, the per-operation half now too

What is measured, on the release kernel of record:

- one large file, sequential, 512 MiB, 1 and 4 writers: writes at twice ext4's
  and btrfs's rate; reads at six times DragonFly's own kernel on the same volume.
- a Nix closure, 1978 paths / 205871 files, cold read beside squashfs, erofs,
  ext4.
- a full-volume fill, and bulkfree's two passes.
- **per-operation latency, added 2026-09-26**: random 4 KiB reads and
  write-then-`fsync`, on this port and on ext4 and btrfs in the same guest,
  with the page cache dropped and a `tmpfs` cache control that must fail its
  own check. `script/latency.sh`, from `test/hammer2-latency.c`.

What that closes: this section previously named random 4 KiB and `fsync`
latency as unmeasured, which was the half of the picture where a 64 KiB-block
copy-on-write design is expected to pay rather than win. The gap was not that
the measurement was hard; it is that nothing in the roadmap's exit criteria
ever asked for it, so the process had no step that would produce it. Every
instrument this tree had answered "is the data correct", and correctness
instruments do not report cost.

What is **still** not measured anywhere in the tree, searched by name:

- small-file create/delete rate (the million-file tree measures a walk, not a rate);
- mixed read/write workloads;
- sustained multi-hour load, or behavior past the 2 GiB/4 GiB guests.

Sequential throughput is where a copy-on-write filesystem with 64 KiB blocks and
a checksum per block is expected to look good. The unmeasured set is where the
same design is expected to cost.

## 3. Missing VFS surface, checked against what a root filesystem needs

Checked by reading the kernel's own fallback for each, not from memory:

| op | absent | consequence (read at 7.3-rc1) |
|---|---|---|
| `->fallocate` | yes | `-EOPNOTSUPP` from `fs/open.c`. An installer and a package manager expect it; this is the largest real gap. |
| `->direct_IO` | yes | `O_DIRECT` returns `-EINVAL` (`fs/open.c` sets `FMODE_CAN_ODIRECT` only when the op exists). Databases and VM images use it. |
| `->splice_read` | yes | **Not a defect**: `do_splice_read()` falls back to `copy_splice_read()`. Checked rather than assumed. |
| `->fiemap` | **built 2026-09-29** | Was `-EOPNOTSUPP` from `fs/ioctl.c`, so `filefrag` reported nothing. The bmap XOP already answered the question a block at a time, which is what `SEEK_HOLE` uses, so the map is built on it and `test/hammer2-fiemap.c` checks it against a file whose hole it opens itself. Measured on a live mount: 11 checks 0 failures, and `filefrag -v` on the same media reports the same two extents at the same blocks with the hole correctly absent. Run by `test-enospc.sh` on the volume with room, before the fill. |
| `->freeze_fs`/`->unfreeze_fs` | **built 2026-09-29** | Was absent, so `ioctl_fsfreeze()` returned `EOPNOTSUPP` and `fsfreeze(8)` said the filesystem does not support freeze. The vop cancels the port's own syncer, which is the one writer the VFS freeze cannot see, and restarts it on thaw. **A first attempt was withdrawn the same day after it wedged a volume, and restoring it required reproducing that wedge and attributing it**: four probes on the withdrawn build showed freeze and thaw alone returning 10 of 10 times, a write and an unlink while frozen both blocking and both released by a cross-process thaw, and the exact wedging shape (freeze and unlink in one process, thawed from another) not wedging on its own. The wedge was the exerciser's: it wrote and unlinked from the same process that had to thaw, and a write on a frozen filesystem blocks until the thaw, so it deadlocked itself. `test/hammer2-fiemap.c` measures the operation with every blocking call in a child and is run by `test-enospc.sh`, whose refusal to accept a zero check is what keeps the count from going quiet. The withdrawal's own comment named a lock-order cause that no probe reproduced, and that is recorded in `hammer2_vfsops.c` as a defect of the comment rather than quietly dropped: a cause written into a source comment without being measured is its own defect, and it stood for the length of the withdrawal. |
| `->remap_file_range` | yes | No `FICLONE`/reflink. Cheap on a CoW filesystem and expected of one; btrfs and xfs have it. |
| super ops | 3 (`evict_inode`, `statfs`, `sync_fs`) | btrfs carries 17. Not all are needed, but `put_super`, `show_options`, `shutdown` are normal. |

## 4. What is genuinely established

Stated precisely, because the negative claims above need a fair positive:

- Mount, read, write, mmap, exec, symlinks, crash recovery, snapshots, PFS
  domains, compression, bulkfree, and a volume as root under qemu, each with a
  run of record on a named build.
- 13 gates, none trusted on silence, plus 12 fleet instruments.
- Reproducible build verified by hash with its own control.
- The port's own capabilities document is honest: it declares nine capabilities
  `unavailable` rather than overclaiming.

## 4a. Every vnode and superblock operation, DragonFly's set against this port's

The table above answers "which operations are absent", and an absent list is
only as good as the population it was drawn from. This is that population:
every operation in DragonFly's `hammer2_vnodeops` vector, all 32 of them,
each mapped to what this port registers in its place or to the reason it
needs no counterpart. It was produced by reading the two vectors, not by
recalling them, and a port that is missing an operation upstream has shows
up here as a row with an empty right-hand column.

The framework entries are the ones worth stating, because they are the rows
that look like omissions and are not: DragonFly's `vop_open`, `vop_close`
and `vop_access` are `vop_stdopen`, `vop_stdclose` and
`vop_helper_access` rather than HAMMER2 code, so Linux performs the same
work in its generic paths, and `vop_inactive`/`vop_reclaim` are that
framework's inode teardown where Linux has `->evict_inode`. The `n`-prefixed
names are DragonFly's component-name operations (`ncreate`, `nresolve`,
`nremove` and the rest), each of which this port reaches through the
path-based operation Linux names without the prefix.

| DragonFly vop | this port | note |
|---|---|---|
| `vop_default` | `vop_defaultop` | framework |
| `vop_open`, `vop_close` | generic | `vop_stdopen`/`vop_stdclose` upstream, which Linux's `->open`/`->release` defaults match |
| `vop_access` | generic | `vop_helper_access` upstream; Linux's permission path answers from the mode the port reports |
| `vop_chmod`, `vop_chown` | `->setattr` | one Linux operation for DragonFly's separate two |
| `vop_getattr`, `vop_getattr_lite` | `->getattr` | the lite form is DragonFly's cached variant, which Linux's `i_size`/`i_blocks` caching covers |
| `vop_setattr` | `->setattr` | |
| `vop_read` | `->read_iter` | |
| `vop_write` | `->write_iter` | |
| `vop_fsync` | `->fsync` | |
| `vop_readdir` | `->iterate_shared` | |
| `vop_readlink` | `->get_link` | renamed upstream in Linux |
| `vop_inactive`, `vop_reclaim` | `->evict_inode` | inode teardown |
| `vop_bmap` | `->bmap` | same name, `hammer2_bmap()` |
| `vop_ioctl` | `->unlocked_ioctl` | the HAMMER2 ioctl surface, 19 of 27 ioctls |
| `vop_strategy` | `->read_folio`/`->write_begin`/`->write_end`/`->writepages` | Linux splits the buffer-cache strategy entry point across the folio operations |
| `vop_getpages`, `vop_putpages` | `->read_folio`, `->readahead`, `->writepages` | DragonFly's page-in/page-out, which Linux's read and writeback paths perform |
| `vop_nlink` | `->link` | |
| `vop_ncreate` | `->create` | |
| `vop_nmknod` | `->mknod` | |
| `vop_nmkdir` | `->mkdir` | |
| `vop_nsymlink` | `->symlink` | |
| `vop_nremove` | `->unlink` | |
| `vop_nrmdir` | `->rmdir` | |
| `vop_nrename` | `->rename` | |
| `vop_nresolve` | `->lookup` | |
| `vop_nlookupdotdot` | generic | Linux resolves `..` in the dcache before the filesystem sees it |
| `vop_advlock` | generic | `vop_stdadvlock` upstream, Linux's `->lock` default |
| `vop_mountctl` | not applicable | DragonFly's mount-control channel has no Linux equivalent and no consumer here |
| `vop_kqfilter` | not applicable | kqueue is a BSD facility; Linux's equivalent is the `->poll` path, which the port does not need for a filesystem with no character device |

Nothing in the vector is left unmapped, and the two rows with no counterpart
are BSD-only facilities rather than HAMMER2 functions, so the operation
surface DragonFly implements is implemented here. What that does not say is
whether each one is correct under load: that is the per-operation evidence
in `doc/README.status.md`, and this table is the population that evidence is
drawn against, so an operation absent from both is visible rather than
counted as present.

**The superblock set is where that table is not clean.** DragonFly's
`vfsops` carries `vfs_vptofh`, `vfs_fhtovp` and `vfs_checkexp`, which
together are its NFS export surface, and each is a real implementation: the
file handle encodes the inode number and the reverse lookup finds the vnode
by number. This port registers no `export_operations`, so `s_export_op` is
NULL, `exportfs_may_export()` is false without `fh_to_dentry`, and nfsd
refuses the export with `EINVAL` (`fs/nfsd/export.c`). The other rows of
DragonFly's set have counterparts: `vfs_mount`/`vfs_unmount` are the
`fs_context` callbacks and `kill_sb`, `vfs_root` is `->get_tree`'s root
dentry, `vfs_statfs` is `->statfs`, `vfs_sync` is `->sync_fs`,
`vfs_vget` is `hammer2_igetv()`, and `vfs_init`/`vfs_uninit` are the module
init and exit. So NFS export is the one operation here that upstream has,
this port does not, and no document previously said so. It is a gap rather
than a decision, it is now a row of `README.capabilities.md`, and the
kernel sources named above are where the refusal was read.

## 5. The process finding, which outranks the rest

The `SEEK_HOLE` bug shipped with a test that passed, because the test asserted
the implementation's behavior. Two filesystems the machine already had (tmpfs
at `/tmp`, btrfs at `/home`) answered differently in one second and were the
whole detection. The lesson is not "be careful": it is that **every
kernel-facing expectation written here needs a reference filesystem as a
control before it is run on HAMMER2**, and no gate enforces that. `README.md`
currently lists `SEEK_DATA`/`SEEK_HOLE` under "works"; the corrected reading
supports that, but only after this.

## 6. Ordered next steps

1. `->fallocate` (marked `XXX`, built deliberately; no upstream port has it).
   **Done 2026-09-28.** The defect was one line of arithmetic and it is fixed
   in `hammer2_vnops.c`; the entry records the defect, the measurement that
   found it, and the six causes that were proposed and refuted before it, so
   the search is not walked again.

   **The defect.** Each folio's zero range was computed with
   `offset_in_folio()`, which is a MASK and not a subtraction,
   `((p) & (folio_size(folio) - 1))`. For a range ending exactly at a folio's
   end the mask wraps to zero, so the call became
   `folio_zero_segment(folio, 0, 0)`, which `zero_user_segments()` skips
   because the end is not past the start. Every punch covering whole 64 KiB
   blocks therefore zeroed nothing and freed nothing, and a punch covering
   only part of a block zeroed correctly and freed nothing because there was
   no whole block to elide. The two offsets are now the subtraction they were
   meant to be.

   **The measurement that found it**, after five readings of the source had
   failed: a `pr_info` inside the loop printing the computed range. It showed
   `zs=0 ze=65536 -> 0 .. 0 ... skips=1` for a whole-block punch and
   `zs=16384 ze=49152 -> 16384 .. 49152 ... skips=0` for a partial one. The
   kernel's `offset_in_folio` is in `include/linux/mm.h`; the answer was in
   the header the port compiles against, and reading it took one command.

   **What holds now.** A whole-block punch zeroes the block and frees it,
   2080 blocks to 1952; a whole-file punch takes it to 0; the exerciser
   reports 12 checks and 0 failures, and the same exerciser on btrfs reports
   12 and 0 with its range adapted to that filesystem's 4 KiB block, which is
   the reference-filesystem control item 5 below asks for. Syntax 65 checks
   0 failed and checkpatch moved by one, a new `return (x);` in the tree's own
   BSD style.

   **The siblings were checked rather than assumed.** `offset_in_folio()` is
   used in two other places in the port, and both are correct:
   `hammer2_zero_tail()` passes an offset strictly inside the folio, guarded
   by `off < folio_pos(folio) + folio_size(folio)`, so it can never reach the
   folio's end and wrap; and `hammer2_flush.c` masks a volume offset to write
   a 256 KiB header into a large folio, where the mask is what is wanted. The
   first was driven rather than reasoned about, since it is reachable from
   `->setattr`: a 1 MiB file truncated to 100000 bytes and extended to
   200000 re-exposes the tail as zeros with no warning, which is the
   behavior that fails if the offset is wrong.

   **The six causes that were wrong**, kept because each cost time:
   (1) the punch writes real zeros and allocates 64 MiB - the figure came
   from `df` and is a deferred free; (2) a page-sized step misses a
   block-sized elision - wrong arithmetic; (3) the punch never reaches the
   media - from an md5 taken after an `umount` that had failed; (4) the
   zeroing does not take - from a probe that read past the folio it had
   bounded; (5) `folio_zero_segment()` violates
   `BUG_ON(end > page_size(page))` - `page_size()` is the whole compound
   page, so it does not; (6) the two modes differ in `KEEP_SIZE` -
   `vfs_fallocate()` requires that flag for `PUNCH_HOLE`, so both carry it.
   Each was replaced only by measurement or by reading the kernel.

2. ~~An instrument for dedup.~~ Done 2026-09-25: `test/hammer2-dedup.c`.
3. `->direct_IO`, if databases or VM images are a target.
4. ~~Random-4K and fsync latency.~~ Done 2026-09-26: `script/latency.sh` and
   `test/hammer2-latency.c`, on this port and on ext4 and btrfs beside it.
5. ~~A gate that requires a reference-filesystem control for kernel-facing
   tests.~~ Done 2026-09-28. `README.testing.md` carries a table naming each   file under `test/` and the reference it is checked against, or saying it
   has none and why, and `test-inventory.sh` fails on a test file with no row
   and on a row naming a file that does not exist. Both directions are
   checked because either alone is satisfiable trivially, and the population
   is asserted first so a table that lost its rows cannot pass by comparing
   nothing. On its first run it found two files with no row, both
   kernel-facing harnesses, which is the check working rather than the table
   being complete.

   The declaration is authored and not inferred, and that was a decision made
   after trying the alternative: a lexical rule over the test files classified
   `hammer2-dedup.c` as pure when it measures a kernel behavior, and missed
   the same file in the same pass. A row that says "none" is a decision
   recorded, not a gap.

Items 1 and 3 change what a consumer can do; 4 and 5 change what this tree
can claim, and all four are now done. Item 5 is the one that generalizes: every
instrument added since it was written, including the two above, has needed a
filesystem that is not this port before its reading could be believed, and it
is enforced now rather than remembered.

6. The instrument for item 1 was outside the tree that cited it.
   **Done 2026-09-28.** The exerciser whose "12 checks and 0 failures" this
   audit and `CHANGELOG.md` 0.9.36 publish lived in a scratch directory
   beside the applied patch, and `test/` held no fallocate instrument at
   all, so neither document's figure could be reproduced from this
   repository. It is `test/hammer2-fallocate.c` and `test-enospc.sh` runs
   it, which is the rule item 5's own table now enforces for every
   kernel-facing test. Re-measuring rather than trusting the carried
   number found that the exerciser's header asserted `tmpfs` refuses
   `PUNCH_HOLE` and it does not: `tmpfs` accepts `PUNCH_HOLE` and refuses
   `ZERO_RANGE`, and the header and the reference row say what was
   observed. The numbers themselves held: btrfs re-measured at 12 checks
   0 failures, and this port at 12 and 0 with its punch range at 65536
   against btrfs's 4096, on a run that filled 2G with 462 of 462 files
   intact.
