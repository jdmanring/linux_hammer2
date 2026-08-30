# H1 reading 2: who owns the 64 KiB physical buffer

The second of the three readings `HAMMER2_LINUX_PORT_PLAN.md` puts before
any H1 estimate. It is a design rather than a measurement, and reading 1
gave it a constraint before it started: no `hammer2_spin_*` site may be
entered from atomic context, or `rw_semaphore` becomes illegal at the
seven hottest sites in the driver.

The plan's own provisional answer was "the DIO layer over `submit_bio`
owning 64 KiB physical buffers". That is one of two designs, and the
kernel turns out to offer the other one at exactly the size HAMMER2 uses.

## What the format asks for

`hammer2_disk.h` fixes the topological block size:

    #define HAMMER2_PBUFRADIX   16      /* physical buf (1<<16) bytes */
    #define HAMMER2_PBUFSIZE    65536
    #define HAMMER2_LBUFSIZE    16384   /* nominal, for I/O rollups */

and `struct hammer2_io` in `hammer2.h` holds one such buffer, as
`struct buf *bp` behind `struct vnode *devvp`, with a FreeBSD-only
`struct vn_clusterw *clusterw` beside it. Those three fields are the
whole of what a Linux port must replace in that structure.

## The two designs

Private pages under `submit_bio`. The DIO layer allocates its own
memory, builds bios, and owns caching, writeback and reclaim. Total
control, and it reimplements the BSD buffer cache in a kernel that
already has one. Its completion is `bi_end_io`, which runs in softirq, so
it lands on reading 1's constraint and needs every DIO hash operation
deferred to a workqueue to stay legal.

The block device page cache. Linux 7.1's `set_blocksize()` ends with

    mapping_set_folio_min_order(inode->i_mapping, get_order(size));

(`block/bdev.c:210`, `EXPORT_SYMBOL`), and `sb_set_blocksize()` wraps it
for a filesystem. So a filesystem that declares its block size gets
folios of at least that order from the block device's mapping, and the
page cache does the caching, the writeback and the reclaim.

## The ceiling is the format's own number

`bdev_validate_blocksize()` refuses anything above `BLK_MAX_BLOCK_SIZE`,
and in `include/linux/blkdev.h`:

    #ifdef CONFIG_TRANSPARENT_HUGEPAGE
    #define BLK_MAX_BLOCK_SIZE      SZ_64K
    #else
    #define BLK_MAX_BLOCK_SIZE      PAGE_SIZE
    #endif

64 KiB, which is `HAMMER2_PBUFSIZE` exactly. The format sits on the
ceiling rather than under it, so this design works and has no headroom:
a format with a 128 KiB physical buffer could not use it at all, and
`sb_set_blocksize` would return `-EINVAL`.

Read from `torvalds/linux` at `v7.1`, which is the line this system runs.

Corrected the same day it was written, because the first version of this
document cited `v6.18` and a `System.map` from `linux-6.18.44` in the
store. Neither is this system's kernel. `artnix-server`'s
`passthru.boot.kernel.package` is `linux-x86_64-unknown-linux-gnu-7.1.8`,
`modDirVersion` `7.1.8-cachyos`; the 6.18.44 outputs are some other
consumer's and were taken for ours because they were the ones a store
glob found. The conclusion survives unchanged, which is luck rather than
method: the guard, the macro and the exports are identical at both
versions. Read the version from the system's own attribute, never from
what a `ls /nix/store/*linux*` happens to return.

## Therefore

`sb_set_blocksize(sb, HAMMER2_PBUFSIZE)` at mount, and one
`hammer2_io` holds one folio:

- `struct buf *bp` becomes `struct folio *folio`, one folio per physical
  buffer, virtually contiguous under `kmap_local_folio`, with no page
  array to stitch. `HAMMER2_LBUFSIZE` accesses are a sub-folio offset.
- `struct vnode *devvp` becomes the `struct file *` the block device is
  opened through, which is what `set_blocksize` takes, with
  `I_BDEV(file->f_mapping->host)` where the `block_device` itself is
  wanted.
- `struct vn_clusterw *clusterw` goes. `blk_start_plug` is the Linux
  mechanism for the same job and belongs at the flush path's callers
  rather than in the structure.
- reads are `filemap_grab_folio` plus a wait, writes are
  `folio_mark_dirty` with `filemap_fdatawrite_range` on the flush path.
- the DIO hash in `hammer2_io.c` stays and changes meaning: it caches
  `hammer2_io` metadata, refcounts and dedup state, and no longer owns
  the memory.

## What this settles, and the dependency it creates

Reading 1's constraint is met by the native mechanism rather than by a
workqueue we would have written. `filemap_grab_folio` and the wait for
the folio's lock both block in process context; the interrupt-context
half of the completion belongs to the page cache and never reaches a
`hammer2_spin_*` site. So `rw_semaphore` stays legal at all 62 sites and
the lock question closes without a deferral layer, which is one fewer
thing between the driver and the disk on every read.

The dependency is a hard one and it is a build-time property of the
kernel, not a runtime setting: without `CONFIG_TRANSPARENT_HUGEPAGE` the
ceiling is `PAGE_SIZE` and mount fails with `-EINVAL` for a reason
nothing in the failure text will explain. This system's kernel has it:
`linux-x86_64-unknown-linux-gnu-7.1.8`'s `System.map` carries 155
occurrences of the `khugepaged` and `transparent_hugepage` symbol
families, read from the built artifact this system actually boots rather
than from a config file we do not ship. Symbol presence proves the code
is compiled in, which is the exact property the macro keys on; whether
THP is enabled at runtime is a different question and not this one.

So the module tests `HAMMER2_PBUFSIZE <= BLK_MAX_BLOCK_SIZE` at compile
time with a `static_assert` naming this document, and refuses to build
rather than shipping a driver that cannot mount. A kernel without THP is
a supported configuration of Linux and an unsupported one for this
filesystem, and that belongs in the package's own metadata rather than in
a mount-time surprise.

## Left open, with the trigger

Whether file data goes through iomap or the classic address-space
operations is H2's, and the plan already leaves it there. This reading
narrows it: the metadata path is now folio-native on the device mapping,
so the argument that the 64 KiB physical buffers make iomap awkward is
weaker than it looked when the plan was written. Decide it in H2 against
a working read path, not before one.

## The kernel this depends on is a moving target, so the dependency is a range

James asked the right question of the version: 7.1.8 is not the latest.
From `kernel.org/releases.json`, read 2026-08-25: stable is **7.1.10**
(released 2026-08-23), mainline is 7.2 (2026-08-16), and the longterm
line nearest our own is 6.18.46. This system pins 7.1.8 through
chaotic-nyx's CachyOS build, so it is two point releases behind stable and
one minor behind mainline.

That matters here in a way it does not matter for most packages, because
an out-of-tree module is recompiled against whatever kernel it is loaded
into and its API dependencies are not frozen by our pin. So the honest
form of this reading's dependency is a RANGE rather than a version, and
the range was measured rather than assumed:

| kernel | `BLK_MAX_BLOCK_SIZE` | `mapping_set_folio_min_order` in `set_blocksize` | `EXPORT_SYMBOL(set_blocksize)` |
|---|---|---|---|
| v6.18 (longterm) | `SZ_64K` under THP | yes | yes |
| v7.1 (our line) | `SZ_64K` under THP | yes | yes |
| v7.2 (mainline) | `SZ_64K` under THP | yes | yes |

Three versions spanning the longterm line, the line we ship and the one
being written. The mechanism is not a recent addition we would be first to
use and it is not on its way out.

A single-version reading would have said the same thing and been worth
much less, because the question an out-of-tree module actually faces is
not "does this work today" but "how often will this break". That question
has an answer only from a range.

## The treadmill, and the escape HAMMER2 has and ZFS does not

Nothing in this program had written down the standing cost of shipping an
out-of-tree filesystem module, and it is the cost OpenZFS pays on every
Linux release: the kernel offers no stable internal API, so each version
can move a structure or a helper under the module, and somebody rebases.
For a distribution whose repository is a signed binary cache, that lands
as a kernel bump that silently produces a module nobody can load.

HAMMER2 has an escape ZFS structurally cannot take. The core is
BSD-3-Clause throughout, which is GPL-compatible, so an in-tree
submission is legal where CDDL makes it permanently impossible for ZFS.
In-tree means the API churn is fixed by whoever makes it, as a condition
of making it, which is the difference between a treadmill and a one-time
cost. `HAMMER2_UPSTREAM_STRATEGY.md` already sequences that submission
after qualification and is right to; what was missing is the reason it is
worth spending, which is this.

Until then, and it is the reason H1 carries a gate rather than a note: a
kernel bump must fail loudly. The module `static_assert`s that
`HAMMER2_PBUFSIZE` fits `BLK_MAX_BLOCK_SIZE`, so a kernel that narrowed
that ceiling refuses to build rather than producing a driver that cannot
mount.
