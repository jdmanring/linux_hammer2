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
   **The staged implementation works. The exerciser that failed it is wrong.**
   Both halves of that were got wrong here first, in the opposite direction,
   so this entry records the experiment and not only the answer.

   What was claimed and is withdrawn: that the punch never reaches the media,
   and that its zeroing does not take. Both came from counters, and one of
   those counters read past the end of the folio it had just zeroed, so it
   reported every zeroing attempt as a failure. Clamped to the range the call
   actually zeroed, the same probe reports the opposite:

       zeroed=256  zerook=256  nonzero=0     (a 1 MiB punch)

   Every zeroing attempt succeeded. A probe that reads beyond what it bounded
   will confirm whatever it was pointed at.

   What the pristine implementation does, measured on rc4 with nothing added
   but a call counter:

       punch 16384..49152, inside one block:  2080 blocks -> 2080
       punch 0..65536, exactly one block:     2080 blocks -> 1952
       punch 0..1048576, the whole file:      2080 blocks -> 0

   **Those three readings do not reproduce and must not be relied on.** The
   block-aligned punch was run again on later builds and gave 2080 -> 0 once
   and 2080 -> 2080 twice, on fresh volumes, with the host module hash
   checked against the guest's at each step. The whole-file punch has not
   been repeated at all. Until the same range, build and volume reproduce the
   same number, nothing here is established, and a cause built on it is
   worthless. That is the state this item is in and it is stated rather than
   dressed up.

   What does reproduce, and is the reason the first claim was withdrawn:
   zeroing every block of a range does NOT free it in the runs above, while
   `dd if=/dev/zero` over the same range does, and the reference filesystem
   behaves differently again. The range the exerciser punches, 32 KiB
   starting 16 KiB into the file, covers no whole 64 KiB block; on btrfs,
   whose block is 4 KiB, the same range takes 2048 blocks to 1984. That much
   is consistent across every run and is why the exerciser's check is
   suspect. It is not enough to conclude the implementation is correct.

   The next step is therefore not a rewrite and not an application. It is a
   reproducible measurement: one build, one fresh volume, the same range,
   repeated until it gives the same answer twice, with the module hash
   recorded beside each number. Nothing in this item should move until that
   exists, and the counter that would do it is the one used here, kept in the
   tree until the numbers settle rather than compiled out after one run.

   The lesson is on the measurement side, which is why this entry is long.
   Four readings of the source produced four wrong causes, and then the first
   counter meant to settle it was itself unbounded and produced a fifth. None
   of the five survived a repeat run. The control on a filesystem whose block
   size differs is what showed the exerciser's range is suspect, and it is
   also what showed that a difference between two filesystems is not by
   itself a finding: it is the gate item 5 below asks for, and this item is
   the demonstration of why that gate is needed.

   Space accounting, which several of the wrong attempts tripped on:
   `statvfs` moves at allocation and at the SECOND bulkfree pass, not at a
   remove, so a removed file is counted until two passes run. Measured on a
   2G volume in kb: 1859968 free, 1654720 after a 200 MB write, 1654720 still
   after `rm` and after the first pass, 1859968 after the second. The
   invocation matters, `hammer2 -s <mount> bulkfree <mount>`; without `-s`
   the utility exits with EINVAL, frees nothing, and a probe that swallows
   that line reports a pass that did nothing.

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
