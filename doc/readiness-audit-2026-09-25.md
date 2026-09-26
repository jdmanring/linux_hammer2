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
| `->fiemap` | yes | `-EOPNOTSUPP` from `fs/ioctl.c`. Tools like `filefrag` report nothing. Low priority; `SEEK_HOLE` covers the common need. |
| `->freeze_fs`/`->unfreeze_fs` | yes | No filesystem freeze. Used by `fsfreeze`, some snapshot and backup tools. btrfs has them. |
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
2. ~~An instrument for dedup.~~ Done 2026-09-25: `test/hammer2-dedup.c`.
3. `->direct_IO`, if databases or VM images are a target.
4. ~~Random-4K and fsync latency.~~ Done 2026-09-26: `script/latency.sh` and
   `test/hammer2-latency.c`, on this port and on ext4 and btrfs beside it.
5. A gate that requires a reference-filesystem control for kernel-facing tests.

Items 1 and 3 change what a consumer can do; 4 and 5 change what this tree
can claim, and 2 and 4 are done. Item 5 is the one that generalizes: every
instrument added since it was written, including the two above, has needed a
filesystem that is not this port before its reading could be believed, and
nothing enforces that.
