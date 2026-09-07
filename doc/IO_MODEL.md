# The Linux I/O model

What the DIO layer does on Linux, which assumptions are the on-disk format
and which are this port's choice, and what mainline offers instead. Written
for handoff section 37 items 3 and 4. Nothing here is designed: it is a
reading of the current tree and of the kernel headers the gate compiles
against, with the version of record stated so it can be re-measured.

Kernel of record: 7.3, pinned as `KERNEL_REF` in `script/test-syntax.sh`,
which refuses any other tree rather than reporting a pass against it. The
kernel expressions quoted below were read at 7.1.9 on 2026-08-26 and are
cited by expression rather than by line for that reason: the expressions do
not move between those versions and the line numbers do.

## The object

One `hammer2_io` wraps one 64 KiB physical buffer. On the BSD ports that
buffer is a `struct buf`; here it is a `struct folio` in the block device's
page cache, held by reference for the life of `DIO_GOOD`.

    struct hammer2_io {
        struct file   *bdev_file;   /* was struct vnode *devvp */
        struct folio  *folio;       /* was struct buf *bp      */
        uint64_t       refs;        /* DIO_ flags in the top bits */
        ...
    };

Ownership splits cleanly and that is the point of the design: the page cache
owns the memory, the writeback and the reclaim; this file owns a reference,
a dirty bit and a flush. `refs` is 64 bits so the `DIO_` flag values are
DragonFly's rather than FreeBSD's 32-bit ones.

Lifetime, in the order it happens:

1. `hammer2_io_getblk()` finds or creates the `hammer2_io` in the per-device
   hash, under `hammer2_io_hash.spin`.
2. On first real use the folio is looked up at
   `(pbase - dbase) >> PAGE_SHIFT` in `bdev_file->f_mapping` and referenced.
   `DIO_GOOD` is then set and `dio->folio` is stable.
3. The core reaches the bytes through `hammer2_io_data()`, which returns
   `folio_address()` plus an offset.
4. The last drop with `DIO_DIRTY` marks the folio dirty; with `DIO_FLUSH` it
   kicks writeback.

## The one assumption that shapes everything

`hammer2_io_data()` hands the core a pointer it keeps across sleeps. That
single fact is why the buffer must be one contiguous, permanently mapped
allocation, and it is upstream of every other decision below. Two static
asserts guard it:

    static_assert(HAMMER2_PBUFSIZE <= BLK_MAX_BLOCK_SIZE, ...);
    static_assert(!IS_ENABLED(CONFIG_HIGHMEM), ...);

The second is why `folio_address()` is correct rather than
`kmap_local_folio()`, and it is true on every 64-bit target.

## Inventory: format versus bootstrap

Handoff section 37 item 3 asks which 64 KiB and THP assumptions are
permanent and which are bootstrap. A prior review put the count at two
sites. It is not two, and the split does not fall where a grep for
`TRANSPARENT_HUGEPAGE` suggests: most of the 64 KiB in this tree is the
on-disk format and has nothing to do with folios.

Permanent, being DragonFly's on-disk format. Changing any of these
changes the filesystem, not the port.

| site | what |
|---|---|
| `hammer2_disk.h:111` | `HAMMER2_ALLOC_MAX` 65536 |
| `hammer2_disk.h:128` | `HAMMER2_PBUFSIZE` 65536 |
| `hammer2_disk.h:1162` | `HAMMER2_VOLUME_BYTES` 65536 |
| `hammer2_disk.h:1170` | `HAMMER2_VOLUME_ICRCVH_SIZE` 65536 - 4 |
| `hammer2_disk.h:447` | maximum radix 16, which is 64 KiB |
| `hammer2_disk.h:229,247` | freemap leaf and node geometry in the 64 KiB slot |
| `hammer2.h:532` | `HAMMER2_DEDUP_HEUR_SIZE`, a multiple of it |

Bootstrap, being this port's page-cache strategy, and a different
strategy would meet the same format.

| site | what |
|---|---|
| `hammer2_io.c:43-47` | one folio per `hammer2_io`, via a 64 KiB block size |
| `hammer2_io.c:76` | the `BLK_MAX_BLOCK_SIZE` static assert |
| `hammer2_io.c:93-101` | `hammer2_io_index()` assuming the mapping's folio order |
| `hammer2_io.c:127` | `hammer2_io_folio_check()`, which fails the I/O when a folio is shorter than the physical buffer |
| `hammer2_os.h:55-67` | the version floor, 7.3, the kernel of record |
| `test/contract/ctl-shrink-ceiling.h` | the control that shrinks the ceiling |

`HAMMER2_LIMIT_DIRTY_INODES` in `hammer2.h` is 65536 and is neither: it
bounds a count of inodes and merely shares the number. It is defined and not
yet referenced anywhere in this tree. Listed so the next sweep does not
classify it as either.

Citations into the kernel's own headers are by expression throughout this
document, never by line. They cannot be checked by
`script/test-citations.sh`, which reads this tree only, so a line number
in one is precision no instrument backs, and a sibling repository's
`blkdev.h` citation carried a line matching neither the tag it named nor the
one before it. Read against the 7.1.9 headers on 2026-08-26, every kernel
expression named here resolves. At 7.3 the lines differ and the
expressions do not.

## Why the bootstrap choice needs THP

`BLK_MAX_BLOCK_SIZE` is `SZ_64K` inside `#ifdef CONFIG_TRANSPARENT_HUGEPAGE`
and `PAGE_SIZE` otherwise, in `include/linux/blkdev.h`. Cited by the
expression and not by a line: this is the one citation in these documents
that points outside the tree, so `script/test-citations.sh` cannot check
it and a number here would be precision no instrument backs. It read `:286`
and `:288` in the 7.1.9 headers on 2026-08-26, while a sibling repository's
citation of `:287 at v7.2` matched no tag at all. The substance is
byte-identical wherever it sits.
With 4 KiB pages and no THP the
ceiling is 4 KiB, `set_blocksize` refuses 64 KiB, and the mount fails EINVAL
saying nothing about why. That is what the build-time assert exists to move
forward.

So THP is a hard requirement of the CURRENT design and not of HAMMER2.

## The survey: what mainline offers

Handoff section 37 item 4 asks for the narrowest compatible design. Read at
the kernel of record:

`mapping_max_folio_size_supported()` in `include/linux/pagemap.h` returns
`1U << (PAGE_SHIFT + MAX_PAGECACHE_ORDER)` under THP and `PAGE_SIZE`
otherwise. Its own comment says the filesystem should call it at mount time
when it has a folio-size requirement, which is exactly our case.

Two ceilings exist and they are not the same number, which is the part worth
knowing before writing the mount path:

- `BLK_MAX_BLOCK_SIZE` is 64 KiB, and its comment says so deliberately:
  "We should strive for 1 << (PAGE_SHIFT + MAX_PAGECACHE_ORDER) however we
  constrain this to what we can validate and test." A policy cap.
- `mapping_max_folio_size_supported()` is the capability, and under THP with
  4 KiB pages it is larger than 64 KiB.

Every folio of a file mapping and of the device mapping is a whole
logical block, an order-4 allocation, which the allocator calls costly
and abandons after one round of reclaim and compaction unless
`__GFP_RETRY_MAYFAIL` is set. Measured 2026-09-06 on a guest with 4 GiB:
a tree of small files filled memory with clean cache fragmented below
64 KiB, and the write path's folio grab returned `ENOMEM` at 598360 and
at 730951 files with three gigabytes available, reported by the kernel
as a page allocation failure of order 4. Both mappings now carry the
retry flag, the file mapping's in its mask and the device mapping's on
each grab since that mask is the block layer's; the flag keeps the
allocator reclaiming and compacting and still fails rather than
invoking the OOM killer. The same tree on the same guest with kmemleak
disabled reached a million files with no refusal, the module unchanged,
so at that scale the fragmentation was the debug guest's.

A real Nix closure, 11.8 GB in 205871 files copied in with `cp -a`,
is past that scale, and there the attribution does not hold: with
kmemleak off the guest refused two order-4 grabs in the copy's third
minute, as it had with kmemleak on. The allocator's own report at
the refusal says why: the Normal zone was at its low watermark with
65 MB free and nothing in it at 64 KiB or above in any migrate type,
three gigabytes of file cache on the inactive list, 250 MB of it dirty
and under a megabyte of it in writeback, and compaction failing four
stalls in ten over a run. That is a 4 GiB guest holding a 12 GB write
stream beside its source's read stream, and it is the same refusal the
kernel's own large-block filesystems meet: xfs with a 64 KiB block
pins the same minimum order on its mapping, `__filemap_get_folio()`
steps the order down only as far as that minimum, and at the minimum
a costly order without `__GFP_RETRY_MAYFAIL` leaves the slow path
after one reclaim and compaction pass. The port keeps the retry bit,
so it tries longer than xfs would before the same answer. Whether the
answer stands is 0.9's low-memory row. Lowering the dirty limit to
128 MB so writeback ran ahead of the grab changed nothing; giving the
guest 8 GiB and changing nothing else took the copy through in 82 s
with no refusal, so the limit is the guest's memory against the folio
and not the port's writeback.

The device mapping carries no read-ahead of its own: a folio absent
from it is one synchronous read of one block, which held a sequential
read of a large file to 353 MiB/s on a guest where btrfs read at 507.
On a miss `hammer2_bread()` now asks the kernel's read-ahead for the
BSD cluster hint's worth of pages first, with a `file_ra_state` per
device, and reads at 602 to 683 MiB/s on the same guest, DragonFly's
own rate for the same files. `doc/README.status.md` has the table.

For `set_blocksize` the policy cap is the binding one, so the existing
static assert names the right constant. The runtime refusal that section 6
asks for is written, in `hammer2_ondisk.c` where the device is opened: it
asks `mapping_max_folio_size_supported()` before `set_blocksize()` and
refuses by name with both numbers, and `HAMMER2_FOLIO_CONTROL` is its
negative control, asking for twice what the kernel offers so that a
module built with it refuses every mount through that branch.

`hammer2_open_devvp()` calls `set_blocksize(bdev_file, HAMMER2_PBUFSIZE)`
on each device as it opens it, and fails the open on a non-zero return.
`sb_set_blocksize()` is the call an ordinary Linux filesystem makes here,
and it is the wrong one for HAMMER2: it acts on `sb->s_bdev_file`, and a
HAMMER2 filesystem spans up to `HAMMER2_MAX_VOLUMES` devices. This
paragraph said "of which only the root volume is ever `sb->s_bdev`" until
2026-08-26, when the mount design settled on an anonymous super following
btrfs, so no volume is ever `sb->s_bdev` and the field stays NULL. That
strengthens the conclusion rather than changing it, and it removes the
other half of the same trap: `get_tree_bdev()` is out for the same
reason, because what it runs is `setup_bdev_super()`, which opens one
device itself and ends in `sb_set_blocksize(sb, block_size(bdev))` -- the
device's block size, not `HAMMER2_PBUFSIZE`. The mount path still owes
`sb->s_blocksize` itself, and now owes it with nothing underneath to
infer it from. See the opening comment of `hammer2_vfsops.c`.

`mapping_set_folio_min_order()` and `mapping_set_folio_order_range()`
(both `static inline` in `include/linux/pagemap.h`) are how a filesystem
states the requirement rather than inferring it.

They are also why the refusal above has to be explicit, which is worth
reading before assuming the open path already covers it. As of the device
half of `->get_tree` landing on 2026-08-26, `hammer2_open_devvp()` calls
`set_blocksize()` for real, and that call reaches
`mapping_set_folio_min_order()` on its own. It cannot report the
condition. Read at the kernel of record: `set_blocksize()` validates
through `bdev_validate_blocksize()`, which checks `blk_validate_block_size()`
and the device's logical block size and nothing about folios; then
`mapping_set_folio_order_range()` returns immediately when
`CONFIG_TRANSPARENT_HUGEPAGE` is off, and clamps `min` down to
`MAX_PAGECACHE_ORDER` when it is on. Both are silent, and both leave
`set_blocksize()` returning 0. So a kernel that cannot give this
filesystem the folio it needs produces a successful open, which is the
shape a refusal has to be written against.

Two guards already stand between that and a wrong read, which is why the
refusal is a diagnosis improvement and not an open hole: the
`static_assert` on `HAMMER2_PBUFSIZE <= BLK_MAX_BLOCK_SIZE` in
`hammer2_io.c` fails the build outright without THP, and
`hammer2_io_folio_check()` re-checks at every read. The clamp case needs
`MAX_PAGECACHE_ORDER` below `get_order(65536)`, which no configuration
this module can currently build on reaches. It is roadmap item 3 rather
than a `DEFER`, because what makes it reachable is a kernel change and
not anything in this tree.

### The narrower design, and its cost

Decoupling is possible and is not free. The 64 KiB buffer is the format; one
folio is not. A port that set the block size to `PAGE_SIZE` and assembled
each buffer from sixteen folios would run without THP. It would then owe
`hammer2_io_data()` a contiguous mapping, and the options are all worse than
the current one:

- `vmap()` per dio: contiguous and permanently mapped, but it costs vmalloc
  address space and a TLB shootdown per teardown, on the hottest path there
  is.
- A bounce buffer: doubles the memory and makes writeback this file's
  problem again, which is the whole thing the folio design gave away.
- Change the core to scatter-gather: correct, and it is a change to shared
  DragonFly code that Kusumi's other ports would have to carry.

None is licensed by anything measured yet, and the handoff's section 33
warning stands: mainline has not moved off the THP gate at the kernel of
record, so nothing here is urgent. Recorded so the next person does not
re-derive it, and so that if THP ever stops being available the cost is
already priced.

## What would change this document

A kernel where `BLK_MAX_BLOCK_SIZE` is no longer gated on
`CONFIG_TRANSPARENT_HUGEPAGE`, or a `hammer2_io_data()` contract that no
longer holds a pointer across sleeps. Re-read `blkdev.h` around the
`BLK_MAX_BLOCK_SIZE` definition before trusting the survey above.
