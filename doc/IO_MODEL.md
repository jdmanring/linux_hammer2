# The Linux I/O model

What the DIO layer does on Linux, which assumptions are the on-disk format
and which are this port's choice, and what mainline offers instead. Written
for handoff section 37 items 3 and 4. Nothing here is designed: it is a
reading of the current tree and of the kernel headers the gate compiles
against, with the version of record stated so it can be re-measured.

Kernel of record: 7.2. Everything below was read against the 7.1.9 headers
on this workstation, which is not that, and the difference is stated
because it is the point.

This paragraph said "7.2.0-cachyos, the newest realized `linux-*-dev`
output in the store" until 2026-08-26 and closed by telling the reader to
re-read rather than cite it. Nobody did, and both halves were wrong.
Measured that day: no such output is realized, in the store or anywhere on
this machine; and the nix fallback it names fires only when
`/lib/modules/$(uname -r)/build` is ABSENT, which it is not, so that path
had never once been taken. The gate was compiling against 7.1.9 while this
line named the kernel it was supposed to be. It now refuses any tree that
is not the kernel of record rather than reporting a pass.

The 7.2.0-cachyos `dev` output exists, prebuilt and signed, in the
CachyOS project's own cache: `nyx-cache.chaotic.cx`, store path
`sil5r7r2a25nsshkqpd5jjjd0g7ywyi7-...-7.2.0-dev`, `NarSize` 687385816,
deriver matching the `.drv` in this machine's store. Confirmed by reading
the narinfo on 2026-08-26. So reaching the kernel of record is a download
and its closure, not a kernel build, which is a different decision from
the one this tree recorded an hour earlier.

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

PERMANENT, because it is DragonFly's on-disk format. Changing any of these
changes the filesystem, not the port.

| site | what |
|---|---|
| `hammer2_disk.h:111` | `HAMMER2_ALLOC_MAX` 65536 |
| `hammer2_disk.h:128` | `HAMMER2_PBUFSIZE` 65536 |
| `hammer2_disk.h:1155` | `HAMMER2_VOLUME_BYTES` 65536 |
| `hammer2_disk.h:1163` | `HAMMER2_VOLUME_ICRCVH_SIZE` 65536 - 4 |
| `hammer2_disk.h:447` | maximum radix 16, which is 64 KiB |
| `hammer2_disk.h:229,247` | freemap leaf and node geometry in the 64 KiB slot |
| `hammer2.h:515` | `HAMMER2_DEDUP_HEUR_SIZE`, a multiple of it |

BOOTSTRAP, because it is this port's page-cache strategy and a different
strategy would meet the same format.

| site | what |
|---|---|
| `hammer2_io.c:43-47` | one folio per `hammer2_io`, via a 64 KiB block size |
| `hammer2_io.c:82` | the `BLK_MAX_BLOCK_SIZE` static assert |
| `hammer2_io.c:102-110` | `hammer2_io_index()` assuming the mapping's folio order |
| `hammer2_io.c:132` | `hammer2_io_folio_check()`, which fails the I/O when a folio is shorter than the physical buffer |
| `hammer2_os.h:54-62` | the 6.15 version floor, which exists only for the above |
| `test/contract/ctl-shrink-ceiling.h` | the control that shrinks the ceiling |

`HAMMER2_LIMIT_DIRTY_INODES` in `hammer2.h` is 65536 and is neither: it
bounds a count of inodes and merely shares the number. It is defined and not
yet referenced anywhere in this tree. Listed so the next sweep does not
classify it as either.

Citations into the kernel's own headers are by expression throughout this
document, never by line. They cannot be checked by
`script/test-citations.sh`, which reads this tree only, so a line number
in one is precision no instrument backs - and the sibling repository's
`blkdev.h` citation, carrying a line that matched neither the tag it named
nor the one before it, is what that costs. Read against the 7.1.9 headers
on this workstation on 2026-08-26, every kernel expression named here
resolves; the kernel of record is 7.2, where the lines will differ and the
expressions will not.

## Why the bootstrap choice needs THP

`BLK_MAX_BLOCK_SIZE` is `SZ_64K` inside `#ifdef CONFIG_TRANSPARENT_HUGEPAGE`
and `PAGE_SIZE` otherwise, in `include/linux/blkdev.h`. Cited by the
expression and not by a line: this is the one citation in these documents
that points OUTSIDE the tree, so `script/test-citations.sh` cannot check
it and a number here would be precision no instrument backs. It read
`:286` and `:288` in the 7.1.9 headers on this workstation on 2026-08-26,
and a sibling repository's citation of `:287 at v7.2` matched no tag at
all while naming one. The substance is byte-identical wherever it sits.
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
otherwise. Its own comment says the filesystem SHOULD call it at mount time
when it has a folio-size requirement, which is exactly our case.

Two ceilings exist and they are not the same number, which is the part worth
knowing before writing the mount path:

- `BLK_MAX_BLOCK_SIZE` is 64 KiB, and its comment says so deliberately:
  "We should strive for 1 << (PAGE_SHIFT + MAX_PAGECACHE_ORDER) however we
  constrain this to what we can validate and test." A policy cap.
- `mapping_max_folio_size_supported()` is the capability, and under THP with
  4 KiB pages it is larger than 64 KiB.

For `sb_set_blocksize` the policy cap is the binding one, so the existing
static assert names the right constant. The RUNTIME refusal that section 6
asks for should consult the capability helper as its comment instructs, and
say the name. Neither is written yet: `sb_set_blocksize` appears in this
tree only inside a comment, because there is no mount path.

`mapping_set_folio_min_order()` and `mapping_set_folio_order_range()`
(both `static inline` in `include/linux/pagemap.h`) are how a filesystem
states the requirement rather
than inferring it. They are the right call sites when the mount path lands.

### The narrower design, and its cost

Decoupling is possible and is not free. The 64 KiB buffer is the format; ONE
FOLIO is not. A port that set the block size to `PAGE_SIZE` and assembled
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
