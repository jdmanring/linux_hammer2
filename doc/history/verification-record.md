Verification record
===================

The measurements behind `doc/README.status.md`, in the order they were
taken, from the first build to the last closure run. Each section names
the instrument that produced its reading and the date it was taken, and
the `file:line` citations in its tables are checked against the source
by `script/test-citations.sh` on every run. A sentence here is a dated
observation: it says what was true at the commit it names and is not
rewritten when the tree moves, so a floor described as unwritten in one
section is written in a later one. The current state is the status
file's, and `CHANGELOG.md` is the enumeration.

## The build

The module builds, warning-clean, and loads. `make`
produces `src/sys/fs/hammer2/hammer2.ko`: thirteen objects, license
`Dual BSD/GPL`, alias `fs-hammer2`, no module dependencies on a kernel
that builds the LZ4 and ZLIB codecs and xxhash in, which the guest does
and a `defconfig` does not: it leaves `CONFIG_LZ4_COMPRESS` out, and the
day the write XOP linked `LZ4_compress_default()` CI's build at the old
6.15 floor went red at modpost and stayed red for three pushes, 0.4.8 to
0.4.10, each of which took a changelog row while it was. The Makefile
now names a missing option in the kbuild pass. That is 0.3's
first criterion, and the second was exercised on 2026-09-03 on the
`fedora44` guest, at 7.2.3-300.fc45 and again at
7.3.0-0.rc0.260819gbd5f485f3f02: `insmod` returns 0, `/proc/filesystems`
lists `hammer2`, the reference count reads 0, `rmmod` returns 0 and
`/sys/module/hammer2` is gone afterwards. The log carries the two taint
lines an unsigned out-of-tree module always produces and nothing else.
What the criterion asks beyond that was measured on 2026-09-04 on
`artix-s6-kde` at 7.3.0-rc1 with `CONFIG_PROVE_LOCKING` and
`CONFIG_DEBUG_KMEMLEAK`, and the section on lockdep below is the record.

It reached that state on 2026-09-02, in one day and two steps. The first
`make` ever run reported four undefined symbols out of modpost:
`hammer2_xop_strategy_read`, `hammer2_xop_strategy_write` and
`hammer2_dedup_clear`, which upstream defines in `hammer2_strategy.c`, and
`hammer2_vfs_sync_pmp`, which this port had declared and deliberately left
undefined. `hammer2_strategy.c` now carries all of it: the dedup
functions, both strategy handlers and the six statics beneath the write
one, since 0.4.8; and the sync is carried since 0.4.7, see "Sync,
carried" below.

**No entry point is a floor now.** The write handler is carried and
started by `hammer2_writepages()` since 0.5. What the undefined symbols bought was a build
nobody could load; what a floor bought, while there was one, was a module
that loads and says what it
cannot do.

It has been linked against the running kernel and against both trees of the
kernel of record: 7.1.9 with gcc 16.2.1, 7.2.0 with clang 22.1.8, and
7.3.0-rc1 in its mainline and its cachyos build. The 7.2.0 and cachyos
trees come from the store the syntax gate already finds, and are built with
`LLVM=1`, since they were built by clang and kbuild passes the compiler's
own flags to whatever builds against it. It also builds at 6.18, which is
what exercises the `inode_state_read_once` shim below. All are
warning-clean. The loads above were of a module built for the guest's own
kernels, and neither 7.3-rc1 tree has been loaded, since a module built
against one kernel is refused by another before any of its code runs.

## Under lockdep and kmemleak at 7.3.0-rc1

A mainline `v7.3-rc1` kernel built here with `CONFIG_PROVE_LOCKING`,
`CONFIG_DEBUG_KMEMLEAK` and `CONFIG_TRANSPARENT_HUGEPAGE`, configured from
the Artix guest's own `/proc/config.gz` and installed on it. Both
instruments were confirmed live before the module was loaded, `/proc/lockdep`
and `/sys/kernel/debug/kmemleak` both present, because an option that
silently failed to enable produces a clean result that means nothing.

This is the first run on which the 7.3 device-open shim executed. Every
earlier mount was at 7.2.3, which takes `bdev_file_open_by_path()` with the
kernel's `fs_holder_ops`; at 7.3 the guard selects
`fs_bdev_file_open_by_path()`, and that branch had never run. The image was
attached as a virtio disk rather than through a loop device, so the mount
opened a real block device.

    mount -t hammer2 -o ro /dev/vdb@TEST /mnt/h2   ->  0

**Lockdep reported `possible recursive locking` on that mount.** Two
different chain locks, at different addresses, are both class `&p->lock#4`,
and the report names its own cause: `May be due to missing lock nesting
notation`. The ledger row at `hammer2_mtx_init()` carries the detail. It is
not a deadlock. It is lockdep being unable to tell a parent chain from its
child, because every chain lock shares one class.

**The instrument then switched itself off.** `debug_locks` reads 0
afterwards, which is what lockdep does after its first complaint, so
nothing this port locked for the rest of that boot was validated. The rest
of this run was measured with lockdep already disabled, and no absence of
findings below is evidence about locking. Both are history: the section
"Lockdep, end to end" below records how every lock came to carry a class
and a level, and the run in which lockdep stayed enabled throughout.

**kmemleak found nothing**, two scans with a gap after the unmount and two
more after the unload, `0 unreferenced object`. That is a real reading and
a narrow one: one mount of one image, whose readdir and read both failed
early, so most of the allocation paths a working filesystem uses were never
entered.

The rest of the sequence behaves at 7.3.0-rc1 as it does at 7.2.3 after the
lock fix: `stat` on the root gives a directory at inode 1, `readdir` gives
`ENOTDIR`, a read gives `EINVAL`, `umount` and `rmmod` both return 0, no
task is left in `D` state and `h2race2` is printed zero times.

## The first mount, and the livelock it found

A `makefs` image mounted read-only on the `fedora44` guest at
7.2.3-300.fc45, the module built against that kernel in the guest:

    mount -t hammer2 -o ro /dev/loop0@TEST /mnt/h2   ->  0, no log output
    /dev/loop0@TEST on /mnt/h2 type hammer2 (ro,relatime)

What the mount can do, measured one call at a time:

| operation | result |
|---|---|
| `stat` the root | `directory`, inode 1, mode `drwxr-xr-x` |
| `statfs` | `ENOSYS`, `->statfs` was not written at `1f025fe` |
| `readdir` | `ENOTDIR`, `->iterate_shared` was not written at `1f025fe` |
| open and read a file | `EINVAL`, the read path was not carried at `1f025fe`; livelocked before the lock fix below |

The first three are floors behaving as recorded. The fourth is a defect.
`cat` sits in `D` state in `hammer2_chain_unlock()` printing
`hammer2_chain_unlock: h2race2` every two seconds without end. The task
cannot be killed, `umount` reports the target busy, and the guest was
rebooted to clear it.

The cause was `hammer2_mtx_upgrade_try()` in `hammer2_os.h`, which was a
predicate and not an upgrade:

    return (hammer2_mtx_owned(p) ? 0 : 1);

It reported success only when the lock was already held exclusively. The
loop in `hammer2_chain_unlock()` takes the shared path, asks for an
upgrade, is refused, and retries forever. DragonFly's `mtx` upgrades a
shared hold to exclusive; a Linux `rw_semaphore` has no atomic upgrade,
and the shim answered a missing primitive with a test rather than an
implementation. The carried loop is upstream's and was not the defect.

The comment above it asserted that every caller of a `_try` handles
failure by dropping and re-acquiring, so a predicate was correct and
merely slow. That caller does not, which is what the mount measured.

It now releases the read side and takes the write side, restoring the
caller's shared hold if it cannot, which is what the OpenBSD port does at
the same place. Against the same reproducer on the same guest: the read
returns `EINVAL` at once, `dmesg` carries no `h2race2` line at all, no
task is left in `D` state, and `umount` and `rmmod` both return 0.
`EINVAL` is the read path not being carried, and is the answer expected
until `->read_folio` lands.

Style baseline 924 to 925, the one hit `return is not a function`.

## Listing a mount, and the use after free it found

Listing a subdirectory oopsed with a NULL dereference in
`hammer2_xop_unset_ipdep()`, reached from `hammer2_xop_retire()` at the
end of `->iterate_shared`. Listing the mount root did not. A probe
placed before the retire read `ip->pmp` as NULL and `ip->cluster.nchains`
as zero on the subdirectory and correct on the root, which is the state
`hammer2_inode_drop()` leaves behind on its last drop: it clears `pmp`,
repoints the cluster at NULL and returns the structure to a zeroing
allocator.

The cause was in `->lookup` and not in the new operation. It called
`hammer2_inode_unlock()` and then `hammer2_inode_drop()`, and
`hammer2_inode_unlock()` already drops, in this port as in DragonFly. So
every successful lookup released one reference more than it held. The
comment above `hammer2_inode_get()` is carried from DragonFly and says
the caller may dispose of both via `hammer2_inode_unlock()` plus
`hammer2_inode_drop()`, where both is the lock and the reference rather
than two references.

The root directory survived it because `pmp->iroot` holds a reference of
its own, so the count never reached zero. A subdirectory has the two the
lookup itself created, which is why the defect needed an operation that
uses a looked-up inode before it could be seen at all. Static gates
cannot see a reference count, and no earlier operation used one.

After the fix, on `artix-s6-kde` at 7.3.0-rc1 with lockdep and kmemleak:

| operation | result |
|---|---|
| `ls` the root | three entries and the two dots |
| `ls` a subdirectory | its one entry |
| `ls` two levels down | its one entry |
| `find` over the whole mount | every one of the five paths, exit 0 |
| `getdents64` with a 64-byte buffer | the root in 3 calls and the subdirectory in 2, each name once |
| open and read a file | `EINVAL`, the read path was not carried at `e76ad21` |
| `readlink` a symlink | `EINVAL` at `e76ad21`, `->get_link` not being written then; the fixture gate reads `f1`'s symlink back since it was |
| `umount`, `rmmod` | 0 and 0 |

kmemleak reported nothing after a scan. `dmesg` carried the recorded
`->sync_fs` `WARN_ONCE` on unmount and one recursive-locking report from
lockdep in `hammer2_chain_lock()`, which was the single lockdep class
every chain lock then shared and not a finding about this code. That
class is gone; see "Lockdep, end to end" below.

Nothing about the mount path itself failed. The device opened, the volume
header was read, the PFS was matched by label and a root inode was built,
all on code that had never executed.

Also observed, and not a defect: mounting without a label fails with
`PFS label "DATA" not found`, since `makefs` writes the label it is given
and the port defaults to `DATA` as upstream does. The failure path then
ran the recorded `->sync_fs` floor, which until 0.4.5 printed a
`WARN_ONCE` and a stack trace on a mount that merely named the wrong
PFS; the floor is silent on a read-only mount now, since there is
nothing it could have failed to sync.

## Reading a file, and the sizes it was measured at

A second `makefs` fixture was built on the boundaries the completion
branches on rather than on a convenient tree, since the first fixture's
largest file was 16 bytes and reached only the embedded case:

| file | size | what it reaches |
|---|---|---|
| `e511.bin` | 511 | inside the embedded bound |
| `d512.bin` | 512 | the last size that fits in the inode, the bound being inclusive |
| `d4k.bin` | 4096 | exactly one folio, and the first file here on media |
| `d64k.bin` | 65536 | one full logical block |
| `d200k.bin` | 200000 | several blocks, so the offset inside a block is not zero |

All five compare byte for byte with the tree the image was made from, as
does a hundred byte read at offset 100000 inside the largest, which is the
case where the folio starts partway through a block.

This table said `d512.bin` was the first file on media, which the block
counts added later disproved: it reports zero blocks, so 512 bytes is
still embedded. `hammer2_inode.c:1664` compares
`size > HAMMER2_EMBEDDED_BYTES`, strictly greater, so the bound is
inclusive and the pair that straddles it is 512 and 4096 rather than 511
and 512. The two small files test the same branch as each other, which is
the kind of claim a checksum cannot correct and a block count can. `dmesg` carries no
finding from this module, kmemleak reports nothing after a scan, and both
fixtures unmount and the module unloads with status 0.

Since 0.4.9 a file's folios are whole logical blocks: `hammer2_igetv()`
sets the mapping's minimum folio order to `HAMMER2_PBUFRADIX`, the
mechanism the DIO layer already uses on the device mapping, and the
mount already refuses a kernel whose page cache cannot hold one. Measured
on the guest with the kernel's function tracer, reading `f6`'s
176000-byte ZLIB file after dropping the caches: 43 `->read_folio` calls
before, one per page and each decompressing the whole block, and 3
after, one per block, with the same checksum, lockdep enabled and no
warning. Since 2026-09-07 the minimum order is a page and the block is
what the mapping asks for first, so a write under memory pressure gets
a smaller folio rather than `ENOMEM`, and the carried write handler
assembles the block around it; `IO_MODEL.md` has the design and the
closure run that measured it. The device mapping stays pinned to the
block, since `hammer2_io_data()` hands the core one pointer to it, so
when its grab returns `ENOMEM` the dio holds the block in a `vmalloc`
buffer of its own, read and written through a bio, and offered back
to the page cache at its dirty last drop. The module parameter
`io_buf_only=1` forces every block through that path: the fixture gate
read all eleven images, 43 files and the refused corrupt one, through
it with 0 failures on 2026-09-07, the parameter read back from the
module as 1, and the full-volume gate filled 2G through it the same
way with 0 failures.

## Compressed blocks, and the fixture that was said not to exist

Both compression methods are written and measured. This paragraph
previously said neither floor had been reached and recorded them as a
`DEFER`, which described the two fixtures rather than the tool: `makefs`
takes a `CompressionType` option, so media holding LZ4 or ZLIB blocks was
one flag away the whole time. An unreachable floor and one nobody had
tried to reach produce the same observation.

`f3.img` is written with `CompressionType=lz4` and `f4.img` with `zlib`,
over a tree chosen so that one file compresses and one cannot:

| file | size | what it reaches |
|---|---|---|
| `lz4_text.bin` | 200000 | repeating text, so the block really is stored compressed |
| `random128k.bin` | 131072 | incompressible, so the compressor falls back and the block is raw inside a compressed volume |
| `zeros64k.bin` | 65536 | a run of zeroes |
| `sparse.bin` | 135168 | a 128 KiB hole then 4 KiB of data, which is the `ENOENT` path |

Before either decoder was written, the floors were run against these
images and behaved as designed: `lz4_text.bin` failed with `EIO` and named
the method in `dmesg`, while the other three read correctly, which is what
proves the floor refuses rather than corrupts and that the image genuinely
holds compressed blocks. After both landed, all four files on both images
compare byte for byte with the tree they were made from, across five full
passes and again with the page cache dropped. kmemleak reports nothing
after two scans, which is the check that matters for these two paths since
each allocates per folio and the ZLIB one also allocates an inflate
workspace.

The kernel's zlib is where the shape differs from upstream rather than the
name: there is no `inflateInit()`, `zlib_inflateInit()` is a macro over
`zlib_inflateInit2()`, and both require the caller to have placed a
workspace of `zlib_inflate_workspacesize()` bytes in the stream, where
upstream's allocates its own.

## What statfs reports, and how each number was checked

`->statfs` is upstream's `hammer2_vfs_statfs()` with its two loops
collapsed and its credential check replaced by the field Linux already
has for it. Upstream subtracts a 5% reserve from all three block counts
when the caller is not root; Linux answers that with the fields
themselves, `f_bfree` being what is free and `f_bavail` what an
unprivileged writer may have, so the reserve is subtracted from one and
not the other and no caller identity is consulted. `f_fsid` is the PFS
uuid rather than the device, since a device carries more than one PFS and
each is a separate filesystem to the VFS.

Against both fixtures at 7.3.0-rc1, every number resolved rather than
eyeballed:

| field | reported | checked against |
|---|---|---|
| `f_type` | `0x48414d32` | the high half of `HAMMER2_VOLUME_ID_HBO`, which spells HAM2 |
| `f_bsize` | 65536 | `HAMMER2_PBUFSIZE`, which is what upstream reports and the unit its allocator counts in |
| `f_blocks` | 125440 | `allocator_size` over that, 7.66 GiB of an 8 GiB image |
| `f_bfree` minus `f_bavail` | 6272 | exactly 5% of `f_blocks`, which is the reserve upstream's comment names |
| `f_files` | 5 | the five entries each fixture holds |
| `f_namelen` | 255 | `HAMMER2_INODE_MAXNAME - 1`, the core comparing strictly less |
| `f_fsid` | differs per mount | the two fixtures are separate PFSes, which is what this field has to distinguish |

`df` reports 320 KiB used on the second fixture for 270,655 bytes of
file data, which is five 64 KiB blocks and the rounding that implies.

## DragonFly-written media

0.4's claim is media DragonFly wrote, not a Linux tool's output, and until
now every measurement had been against `makefs`. `dragonflybsd642` was
booted, a 2 GiB raw disk attached, and the filesystem created by
DragonFly 6.4-RELEASE's own `newfs_hammer2` and written through
DragonFly's own HAMMER2 while mounted read-write. The guest was then shut
down, the same image attached to `artix-s6-kde`, and read by this module
at 7.3.0-rc1 under lockdep and kmemleak.

All six files compare byte for byte with the checksums DragonFly itself
reported before unmounting, across three passes and again with the page
cache dropped, and `find` returns all ten paths.

What makes the run worth more than the compare is that `stat` says which
branch each file took, `i_blocks` carrying the on-media count:

| file | logical | on media | what that proves |
|---|---|---|---|
| `hello.txt` | 21 | 0 | embedded in the inode |
| `compressible.txt` | 144000 | 3072 | 47 to 1, so DragonFly wrote LZ4 blocks and they decoded |
| `random128k.bin` | 131072 | 131072 | incompressible, so the compressor fell back and the block is raw |
| `sparse.bin` | 135168 | 4096 | the 128 KiB hole occupies nothing, so the `ENOENT` path ran |

So the embedded case, the LZ4 case, the uncompressed case and the hole
were each reached on one image, by a writer this project does not control,
rather than on media built to reach them. ZLIB was not exercised on that
image, DragonFly's default being LZ4, so a second one was written the
same way with `hammer2 setcomp zlib` on the mount root before any file
existed, and it is `f6`. DragonFly's own `hammer2 stat` reports
`zlib:default` on every file and `comp_algo=0x03` on the root, which is
the only reading of the compressor this tree has, the block counts being
the same for either. On it a 176000-byte text file occupies 3 KB and
decodes here, so a ZLIB block DragonFly wrote is read; a 64 KiB file of
zeros and a file that is one byte after 65535 of hole both occupy nothing.
Every checksum and every block count matches what DragonFly reported, and
for this image the counts are DragonFly's numbers, not this reader's.

DragonFly's own `fsck_hammer2` was then run over both images on the
DragonFly guest, after they had been mounted and read here. Both exit 0.
`f5` reports 29 blockrefs, 12 inodes, 2 indirect, 6 data and 9 dirents;
`f6` 28, with 5 data, the 64 KiB of zeros occupying no block. The one
message either prints is `zone.1 exceeds volume size`, which is the
checker finding that a 2 GiB volume holds only the first of the four
volume-header zones, spaced 2 GiB apart, and is not a fault. A read-only
mount here leaves media DragonFly's checker accepts, which is the verdict
0.4 asked for.

The multi-PFS case is `f7`: one device on which DragonFly created a
second PFS with `pfs-create`, so `ROOT` and `DATA` are two superblocks on
one block device. Both mount here at once, every file in each verifies
against DragonFly's checksums, they unmount in either order, and after a
module reload the device mounts again, so no claim on it survived. At 7.3
the kernel registers `{device, superblock}` pairs, and its own comment
names the holder for "a device shared by several superblocks of that
type" as the `file_system_type`, which is what this port now passes; each
mounted PFS then claims every device it spans for its own superblock and
releases the claim at unmount, so the device's freeze, thaw, sync and
mark_dead callbacks reach every mount on it rather than the first.

That reach is measured, with a control. Device-mapper's suspend calls
`bdev_freeze()` on the device it wraps, which is the path that runs the
holder's freeze callback, and `fsfreeze -u` on a mount exits 0 only if
that superblock is frozen. With `f7` behind a linear `dm` target and
both PFSes mounted read-only, `dmsetup suspend` followed by a thaw of
each mount gives, on `artix-s6-kde` at 7.3.0-rc1:

| module | thaw `ROOT` | thaw `DATA` |
|---|---|---|
| with the per-mount claim | 0 | 0 |
| the commit before it | 0 | `EINVAL`, not frozen |

So before the change the second mount never heard the device freeze,
and after it both do. The same run measured the mount, the compare,
both unmount orders, the remount after a reload, an empty kmemleak scan
and a `dmesg` holding only the two floors then recorded, the lockdep
recursion and the sync warning, both gone since.

The deferral this closes had over-claimed. It said that at 7.3 the first
mount's superblock was freed while its table entry lived on. Reading
`super_dev_insert()` shows a registration takes a passive reference on
its superblock, so the entry kept the memory alive and the callbacks
skipped it as inactive. The defect was the one the deferral had first
named, callbacks reaching one mount and not the other, and not a
use-after-free.

A second reader has now read the same images. Kusumi's FreeBSD port at
`3df307f7db9d`, the revision this tree was compared against, built on
the `freebsd15` guest and mounted `f1` through `f7` and `f7`'s `DATA`
PFS read-only. Its output is
`/mnt/storage/hammer2-fixtures/freebsd-port-read.txt`. Every one of the
30 manifest checksums, all 30 block counts, the symlink target and the
three `DATA` files agree with what this module reads. Two readers
agreeing is agreement and not correctness, which is why the DragonFly
checksums stay the reference; what the agreement rules out is a defect
shared with the writer that both readers would have to repeat.

`dmesg` carries one finding, the recursive-locking report in
`hammer2_chain_lock()`, which is the single lockdep class recorded below.
kmemleak reports nothing. Both guests were shut down afterwards; only one
ran at a time, each holding 4 GiB.

## The installed root, read cold, and two readers beside this one

0.4's second criterion is the F2 root image: a tree the DragonFly kernel
wrote in ordinary use rather than a fixture made to be read. `f8.img` is
the `dragonflybsd642` guest's own installed root, cut from its shut-off
disk the way `doc/research/HAMMER2_TEST_FIXTURE_PLAN.md` describes: the
Label64 slice at LBA 264192, the HAMMER2 magic at byte 673185792, 29 GiB
apparent and about 780 MiB real. DragonFly's `fsck_hammer2` over it
reports 83002 blockrefs, 28167 inodes and 28209 dirents with no error
line.

This module mounted it read-only on `artix-s6-kde` at 7.3.0-rc1 and
Saxum's own manifest walker, `hammer2-f2-manifest.py`, ran over the mount
as root: 28209 entries, 1140 directories, 20188 files hashed, 6878
symlinks, 2 sockets, and one file over the walker's 256 MiB bound, the
4 GiB swapfile, recorded as `nohash`. Kusumi's FreeBSD port read the same
extraction on `freebsd15` with the same walker and every one of the 28209
rows is identical, path, size, hash and symlink target. Against Saxum's
manifest of the same root taken on 2026-08-25 through `hammer2-fuse` as an
unprivileged user, 28123 rows are identical; the 58 rows that read
`readfail` there are hashed here, since this walk ran as root, which is
what criterion 2 asks for; 5 rows differ because they are logs and
`utmpx` the guest has written to since; and 23 paths exist now that did
not then, under `/root`, `/mnt`, `/var/games` and `/var/cron`, which the
unprivileged walk could not enter or the guest has created since. Nothing
differs that the date does not explain. The three manifests are beside the
images in `/mnt/storage/hammer2-fixtures/`.

Kusumi's NetBSD port at `64095c3947f2`, built on NetBSD 10.1 by the
workbench session, agrees on the 17 files of `f1`, `f2`, `f3` and `f5` it
read, and then panicked with a NULL `VOP_STRATEGY` on its first read of
`f6`'s compressed file, reproducibly, before reading `f4`, `f7` or `f8`.
That is recorded in `netbsd-port-failure.txt` beside the images as a
reader that could not finish, and it says nothing about this tree. The
report for Kusumi is staged in `doc/upstream/netbsd-10.1-read-panic.md`.

Kusumi's OpenBSD port at `a3747df9`, built into a custom kernel on
OpenBSD 7.9 by the workbench session, read all seven fixtures and `f7`'s
`DATA` PFS and agrees with the FreeBSD port on every one of its 35 rows,
including the ZLIB file the NetBSD port wedges on. Three readers now
agree on the fixtures; the NetBSD failure is that port's alone.

## Ownership, modes, hard links and statfs, from DragonFly's own stat

0.4's first criterion asked for hard-link identity, `stat` fields and
`statfs` to be checked by hand until the manifest carried a column for
each. It does now. A `# stat` row carries the octal mode with its type
bits, the link count, owner, group and inode number as DragonFly's
`stat` printed them for a path, and a `# statfs` row carries DragonFly's
`df` as root: 1 KiB blocks in total, used and free, and inodes in use.
The gate prints the guest's `stat` and `statfs` in the same shape and
compares. `f11` was written for it: three names on one inode, a setuid
file, a file owned by an unprivileged user with mode 0600, and a 0750
directory owned by that user and group wheel.

On the guest at 7.3.0-rc1 all 29 rows across `f5`, `f6`, `f7` and `f11`
match, and so do the four `statfs` rows. The three hard-linked names
report inode 1024 and a link count of 3 here as they do there, which is
hard-link identity seen from outside the filesystem. Driven the other
way, one mode altered and one used-blocks figure altered, the gate
failed each image and printed the diff.

## The same tree written by makefs and by the kernel

0.4's sixth criterion asks for every difference between a `makefs`-written
volume and a kernel-written one for the same tree shapes. `f1` is the
five-path tree as Kusumi's `makefs` wrote it; `f12` is the same tree
copied into a fresh `newfs_hammer2` volume by DragonFly's own kernel,
with `cp -Rp` from a read-only mount of `f1` on the DragonFly guest. Both
were then described from DragonFly's side with the same commands, and
the listing is short:

| what | `f1`, makefs | `f12`, kernel |
|---|---|---|
| paths, checksums, modes, owners, link counts | identical | identical |
| `hammer2 stat`: compression and check method per path | `lz4:default`, `xxhash64` on all five | the same |
| blockrefs, from `fsck_hammer2` | 14: 8 inode, 1 indirect, 5 dirent, 12 KB | the same |
| inode numbers | `hello.txt` 1027, `link` 1028 | `hello.txt` 1028, `link` 1027 |
| volume size and header zones | 8 GiB, four headers, header 1 current | 2 GiB, one header |
| statfs | 8028160 KiB, 64 used, 5 inodes | 1957888 KiB, 64 used, 5 inodes |

Two inode numbers swap, because `makefs` numbers files in the order it
walks the source tree and the kernel numbers them in the order `cp`
creates them, and `link` is created after `hello.txt` by one and before
it by the other. The size and header rows are the image sizes chosen
here, not the writers. Nothing else differs, and this module reads both
with every row of both manifests matching, `f12`'s rows being what
DragonFly reported. That is the listing: for a tree of small files the
two writers agree on the format down to the compression and check
methods and the blockref topology, and disagree only where allocation
order shows.

One thing the run taught about the instrument. A disk attached to
DragonFly with libvirt's `--mode readonly` fails a `mount -o ro` with
`EINVAL`: DragonFly's HAMMER2 opens the device for writing whatever the
mount asks, so a read-only attachment is refused before the label is
read. The Linux gate attaches read-only; the DragonFly side cannot.

## Media altered on purpose, and what refuses it

0.4's fourth criterion is F3: corrupt media detected and refused, or
detected and reported, without modification, and the verdict agreeing
with `fsck_hammer2`'s recorded one. Two images, both copies of `f5`, the
checker's verdict taken on DragonFly before any Linux read:

| image | alteration | `fsck_hammer2` on DragonFly | this module |
|---|---|---|---|
| `f9` | one byte of `random128k.bin`'s data block, at byte 151126016 | one data blockref `Bad HAMMER2_CHECK_XXHASH64` at `0x9020010`, the rest clean | mounts, the other five files verify, reading that file fails with `EIO` and `hammer2_chain_testcheck` names the same block, `0000000009020010`, in `dmesg` |
| `f10` | one bit of the volume header at byte 64, inside sector 0's crc | `volume header crc mismatch sect0`, then `No valid volume headers found!` | mount refused: `failed to read /dev/vdb's volume header` |

The gate reads both from their manifests: a `# corrupt relpath` row names
a file whose read must fail, and `# refuse` names an image whose mount
must fail, and the summary line counts the refusals so a zero is visible.
Both attachments are read-only at the libvirt layer, and the images are
2 GiB copies, so the unmodified-media half of the criterion is held by
construction rather than re-hashed every run.

## The version floor is the kernel of record

The floor is 7.3, one tree with the kernel the port is developed and
tested against, and there is no conditional compilation on the kernel
version anywhere under `src/`. It was 6.15 from the first import, by
`BLK_MAX_BLOCK_SIZE`, with four guards above it, each dated by reading
the header at the tag:

| symbol | absent at | present at |
|---|---|---|
| `BLK_MAX_BLOCK_SIZE` | v6.14 | v6.15 |
| `struct sha256_ctx` | v6.16 | v6.17 |
| `const struct kiocb *` in `->write_begin` | v6.16 | v6.17 |
| `inode_state_read_once` | v6.18 | v6.19 |
| `kzalloc_obj` | v6.19 | v7.0 |
| `fs_bdev_file_open_by_path` and the per-mount claim | v7.2 | v7.3 |
| `->create` without the `excl` argument | v7.2 | v7.3 |

The guards, the second CI job that built a 6.15 tree to compile them, and
`script/floor-symbols.py` that swept called names against that tree's
headers all left on 2026-09-05 with the floor's move, and
`doc/README.porting.md` records the ruling and what the day at 6.15 cost.
The table stays because it is the record of where each facility arrived,
which a future move of the pin will want again.

The floor is a measurement and not only a pin. On 2026-09-05 the syntax
gate was run against a mainline 7.2.0 tree, unpacked from the kernel.org
tarball and prepared with the 7.3-rc1 configuration, under the
deliberate override:

    hammer2 against 7.2.0 (mainline) via KDIR, dialect -fms-extensions, with clang version 22.1.8, NOT the tree's own, which is "gcc (GCC) 16.2.1 20260810":
    syntax: 46 check(s), 44 failed AGAINST LINUX 7.2, WHICH IS NOT THE KERNEL OF RECORD

The `#error` in `hammer2_os.h` fires in every one of the fifteen files,
and the compiler goes on past it, so the failures underneath it are
the whole list of what 7.2 lacks: `fs_bdev_file_open_by_path()` and
`fs_bdev_unregister()` implicitly declared at `hammer2_ondisk.c:114`
and `:116`, and the `.create` initializer at `hammer2_vnops.c:747`
rejected because 7.2's `->create` still takes the `excl` flag that the
7.3 lookup pull removed. The two checks that pass are the negative
controls. So the floor is 7.3 for exactly two reasons, both from the
7.3 VFS pulls, and every name the port calls resolves in a 6.15 tree
except those two, `inode_state_read_once()` from 6.19 and
`kzalloc_obj()` from 7.0. A sweep of every call-shaped name in `src/`
against the 6.15 and 7.3-rc1 headers, run by hand the same day, found
nothing else; against 7.3-rc1 the only names it cannot attribute are
compiler builtins and the tree's own.

The rest of what 7.3 changed for a filesystem was read from the pull
merges themselves and is either already in use or does not apply. The
superblock pull's device-to-superblock table is the shared-device open
above, which is why a device carrying several mounted PFSes works. The
writeback pull's `.sync_inode_metadata` and `simple_fsync()` serve
filesystems that track metadata in buffer heads; this port has none,
and `fsync` runs the carried flush. The iomap pull's iterator rework
does not reach a port on classic address-space operations. The block
pull's `RWF_DONTCACHE` for block devices is the one facility with a
foothold here: `->write_begin` now takes its folio from
`write_begin_get_folio()`, which honors the uncached flag when an iocb
carries it and otherwise does what the open-coded lookup did, the
mapping's folio order being pinned to the block. With that build, eight
files of 511 bytes to 1000000, one overwritten at the last byte of its
first block and one appended across a block boundary, matched their
checksums after a read-only remount on the guest, with no kernel report
and the host's `fsck_hammer2` clean. The port does not yet
set `FOP_DONTCACHE`, so no caller can pass the flag; that is a
measurement to make, not a line to add. The slab and memory-management
pulls change nothing this port calls.

The kernel of record is a different claim: this tree compiles against the
latest Linux, pinned in `script/test-syntax.sh` as `KERNEL_REF` and bumped
when a release ships.

Until 2026-08-26 this file said "the gates run on 7.2" and nothing checked
it. They did not. The newest kernel tree on the workstation was 7.1.9, with
no 7.2 in `/lib/modules`, `/usr/src` or the store, and the gate has always
printed the kernel it used in its header line while nobody compared that
string to the rule. A verdict is read off "0 failed". The gate now refuses a
tree that is not the kernel of record, with COULD-NOT-RUN rather than a
pass.

What has actually been compiled, measured rather than assumed, on
2026-08-26 under the deliberate `H2_KERNEL_REF` override:

| kernel tree | result |
|---|---|
| **7.2.0-cachyos**, the kernel of record at the time | **7 checks, 0 failed, both compilers, no override** |
| 7.1.9-artix1-2 | 7 checks, 0 failed, both compilers, under the override |
| 6.18.46-1-lts | 7 checks, 0 failed, both compilers, under the override |

A 7.2 version string can be present with no 7.2 build tree behind it. Where
`linux-api-headers 7.2-1` is installed, `/usr/include/linux/version.h` reads
`LINUX_VERSION_MAJOR 7` and `LINUX_VERSION_PATCHLEVEL 2` beside no build tree
at all: UAPI headers, no `Makefile`, nothing to compile a module against. Anything answering "is 7.2 here" by grepping for a version string
finds that and is wrong. `script/test-syntax.sh` reads `VERSION` and
`PATCHLEVEL` from the build tree's own `Makefile` instead.

**The port type-checks against its kernel of record**, measured 2026-08-26
after the chaotic 7.2.0-cachyos `dev` output was substituted into the store
(679 MB, `sil5r7r2a25nsshkqpd5jjjd0g7ywyi7`). The gate's own line, quoted
rather than summarized:

    hammer2 against 7.2.0-cachyos via the store, matching the kernel of record,
      dialect -fms-extensions, with clang version 22.1.8, matching the tree's own:
    syntax: 7 check(s), 0 failed against the kernel of record (7.2)

measured at `ca4c07a`. The revision matters because this tree is a live
checkout another repository reads while work is being committed to it:
Saxum's delegator once saw 6 gates where it expected 7, having walked the
tree mid-commit, which is indistinguishable from broken unless the revision
is printed beside the count.

The compiler is a pin too, and the tree says which one instead of this
repository asserting one. kbuild records what built the kernel in
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

**The kernel of record moved to 7.3 on 2026-09-03**, `KERNEL_REF` in
`script/test-syntax.sh`. Two 7.3-rc1 trees are measured, and the pin cannot
tell them apart, so each is named with the run that used it.

The unoverridden run takes the unpatched tree, which is the port's own
claim:

    syntax: 46 check(s), 0 failed against the kernel of record (7.3), 7.3.0-rc1, mainline

The kernel the port is to be tested on is the one Saxum ships, its own
build of CachyOS 7.3-rc1 with `-march=znver4` and BBR3, reporting as
`7.3.0-rc1-saxum`. That build exists in the Nix store with its `-dev`
output and no guest has booted it, so nothing is measured on it. The patched tree
measured so far is the store's stock build, which is a superseded
measurement and not the shipping kernel:

    syntax: 46 check(s), 0 failed against the kernel of record (7.3), 7.3.0-rc1-cachyos, patched

`EXTRAVERSION` is `-rc1` on the mainline tree and carries a suffix on any
built kernel, and that is the whole of the difference the pin cannot see:
it compares `VERSION` and `PATCHLEVEL` only, so every one of them satisfies
it, as would 7.3 final. The build claim is made against mainline and the
runtime claim against the shipping kernel; neither substitutes for the
other, and a stock distribution kernel substitutes for neither.

The module links against both. `make KDIR=<mainline>` produces a
`hammer2.ko` with `vermagic: 7.3.0-rc1`; the store tree yields
`7.3.0-rc1-cachyos`, and the two are not interchangeable at load.

The mainline tree is built here from the `v7.3-rc1` tarball, whose
`sha256` is `8d36fbfc7c8906ccfa1ebacc30f84998406504c3f13733a040bb3a3fbe8ac270`
and which is byte-identical to the one in the store. It did not come from a
kernel.org mirror: release candidates are published as git tags and not as
tarballs there, so a `mirror://` URL returns 404 for any -rc.

That tree's first build refused, and correctly. A plain `defconfig` sets
no `CONFIG_TRANSPARENT_HUGEPAGE`, `BLK_MAX_BLOCK_SIZE` is then `PAGE_SIZE`,
and the `static_assert` in `hammer2_io.c` failed the build naming the
option. It is the first time that assert has fired against a real kernel
rather than a constructed one, and it is the refusal 0.3's third criterion
asks to see exercised. Enabling the option and rebuilding gives the mainline
figures above.

Two properties of a nixpkgs kernel `dev` output that any later measurement
has to know. Its `source/` directory is pruned hard: the recipe rsyncs the
tree, deletes `drivers` wholesale, deletes unused arches, then deletes every
file it did not mark read-only. Measured here: 10,944 headers, 81 `.c` files,
no `drivers` directory. A grep of that tree for implementation code measures
the prune, not the kernel, so absence there is the normal case and not
evidence. And `checkpatch.pl` lives under `source/scripts`; `build/scripts`
holds gdb helpers.

That checker is not mainline's: its `sha256` differs from the one the
baseline records. Run against this tree it has twice produced the deviation
set unchanged, at 764 hits on 2026-08-26 and at 856 after `hammer2_ondisk.c`
landed the same day, so cachyos's patches do not move this tree's style
figures. Both readings are of the tree as it stood, not of a constant. The
gate says the hash does not match while accepting the version its own tree
reports, and prints the two halves separately.

The first run against the real tree failed, and the guard was wrong rather
than the tree. A nix dev output's `build/Makefile` is a three-line stub
that sets `KBUILD_OUTPUT` and includes the real Makefile from the `source`
directory beside it, so `VERSION` and `PATCHLEVEL` are not in the file the
gate was reading. It follows the `include` line the stub itself names now,
which is derived from the artifact rather than assuming a sibling
directory, and `linux-api-headers` still fails because it has no `Makefile`
at all to follow.

## Lockdep, end to end

Until 0.4.2 every chain lock took its lockdep class from the one
`init_rwsem()` call site that initialized it, so the first mount reported
`possible recursive locking` and lockdep disabled itself, and every
lockdep claim in this file carried the caveat that the instrument was
blind. It is not blind now. The notation was built one report at a time
on the installed DragonFly root, `f8`, 28210 paths, each step measured
under `CONFIG_PROVE_LOCKING` at 7.3.0-rc1 and each removing the report
before it:

| step | the report it removed | the next report |
|---|---|---|
| a class per blockref type and keybits, set by the shim when the core initializes a chain lock | `possible recursive locking`, every chain | an inversion between the inode lock and the inode chain |
| the lock taken on an unpublished inode records no order | that inversion | an inode chain under an inode chain, a directory above its entry |
| a nesting level per chain, the parent's plus one under an inode, set where `hammer2_chain_get()` first knows the parent | that, for chains | the same shape for inode locks |
| an inode lock nests at its chain's level | that | a false cycle between the mount lock and a PFS XOP lock, one class by init site |
| a static key per lock initializer, as `mutex_init()` has | that | the PFS root inode locked under its chain at mount |
| that mount-time lock is the unpublished kind too | that | a core spinlock under a core spinlock, child then parent |
| a level on the core spinlock, running the other way, since upstream takes them bottom-up | that | a dirent's and an indirect block's core spinlocks at one level |
| the core spinlock classed by type and keybits as the chain lock is | that | the same inode chain locked shared twice by one task, reading an embedded-data file |
| `LOCKAGAIN` becomes a credited re-lock that does not touch the rwsem | that | the volume root and the freemap root, one pseudo-type class, at unmount |
| the two pseudo-types are two classes | that | none |

Two of those were findings and not notation. The mount-time inversion is
real in the core's order and harmless only because the inode is
unreachable, which the acquire now asserts. The shared re-lock was a
latent deadlock: upstream's `LOCKAGAIN` assumes a shared lock recurses,
DragonFly's does, and a Linux rwsem's does not once a writer has queued,
so a task reading an embedded-data file could have blocked on its own
lock. The two BSD ports differ here, read from their kernels rather than
assumed. FreeBSD's `sx` admits a shared acquire past a queued writer when
the thread already holds a shared `sx` lock, `__sx_can_read()` in
`kern_sx.c` testing `td_sx_slocks`, which is that deadlock avoided by
design, so the FreeBSD port's `sx_slock()` under `LOCKAGAIN` is safe.
NetBSD's `rwlock(9)` states that callers must not recursively acquire
read locks, and the NetBSD port's `rw_enter(RW_READER)` under `LOCKAGAIN`
does exactly that on every embedded-data read; it is staged for Kusumi
beside the read panic in `doc/upstream/netbsd-10.1-read-panic.md`.

The run that closed it: `debug_locks` reads 1 before the module loads,
after the mount, after `find` over all 28210 paths, after `md5sum` over
two thousand files, and after the unmount, with no lockdep report in
`dmesg`. The fixture gate now reads `debug_locks` before its first mount
and after its last unmount and fails if it dropped, so a run that
silenced the instrument cannot pass.

## Sync, carried

`->sync_fs` is upstream's `hammer2_vfs_sync_pmp()` as the FreeBSD port
carries it, with four vnode calls translated and marked in place:
`vget()` is `igrab()` with no lock, since the vnode lock it took is
`i_rwsem` here and the write path will hold that above the inode lock;
`vput()` is `iput()`; `vn_fsync_buf()` is `filemap_write_and_wait()` on
the inode's mapping; and `wakeup(&ip->flags)` is the syncq condition
variable, as elsewhere in `hammer2_inode.c`. `hammer2_bioq_sync()` is
empty, as it is in the FreeBSD port. The unmount path's three calls and
the VFS's `->sync_fs` both reach it.

On a read-only mount the syncq is empty and no chain carries a flush
flag, so the walk enters the transaction, flushes the PFS root, finds
nothing modified and writes nothing: the volume header is written only
when a flushed chain set `VOLUMESYNC`, read from `hammer2_flush.c`.
Measured on the installed root at 7.3.0-rc1: `sync` and `sync -f` on the
mount return 0, lockdep stays enabled through the transaction and the
flush traversal, kmemleak is empty after two scans, and `dmesg` holds no
warning. That is the sync's read-only half; its write half is 0.5's, and
the first write is what will show whether the flush orders its writes as
the roadmap requires.

## The first read-write mount, on a scratch copy

0.5 starts with a read-write mount, and the refusal that stood since
0.3 is a deferral: mount-time recovery writes and had never run. `make
HAMMER2_RW_EXPERIMENT=1` builds a module with the refusal lifted, never
installed, for measuring exactly that on a scratch copy. `f13.img` is a
byte copy of `f5`, DragonFly-written media, attached writable to
`artix-s6-kde` at 7.3.0-rc1 under lockdep:

| step | result |
|---|---|
| `mount -t hammer2 /dev/vdb@DFLY` with no `ro` | 0, `/proc/mounts` says `rw` |
| `hammer2_recovery()` | `freemap_tid` at `mirror_tid`, nothing to replay, no write |
| `ls`, `md5sum hello.txt` | the manifest's checksum |
| `touch new` | `EACCES` from the VFS, there being no `->create` |
| `sync`, `umount` | 0 and 0 |
| lockdep, warnings | enabled throughout, none |
| `cmp f5.img f13.img` on the host | byte-identical |

So a read-write mount of clean media opens the device for writing, runs
the carried recovery, and writes nothing, which is what upstream does on
clean media too. The refusal stays in the shipped module: what lifts it
is the case the deferral names, a volume whose flush was cut short, which
needs a fixture DragonFly writes and is interrupted writing, so that the
replay has something to replay and the result can be checked against
DragonFly's own recovery of the same image.

## The first write, and the three defects between it and the disk

The write path is `->write_iter`, `->write_begin`, `->write_end` and
`->writepages` in `hammer2_vnops.c` over the carried write XOP, in the
same `HAMMER2_RW_EXPERIMENT` build on the same scratch copy `f13.img`.
The first write was the smallest one DragonFly could check: five bytes
overwritten at the start of `hello.txt`, a 21-byte file whose data lives
in its inode, then nineteen bytes appended, then `sync`. It took four
runs to reach the disk, and each stop was a defect the read path could
not have found:

| run | where it stopped | what the instrument said | the defect |
|---|---|---|---|
| 1 | `sync`, forever | the hung-task detector at 122 s: the writeback worker `blocked on an rw-semaphore likely owned by` itself, in `hammer2_chain_lock()` from `hammer2_chain_lookup()` under `hammer2_assign_physical()`; lockdep had already reported `possible recursive locking` on `h2ch_inode/2` at that line and turned itself off | the core's lookup returns the inode chain itself, locked again and exclusively, for an inode whose data is embedded, which DragonFly's `mtx` counts and this port's `rw_semaphore` wrapper did not. Fixed in the shim, following the FreeBSD port's `SX_RECURSE`: the two locks initialized with `hammer2_mtx_init_recurse()` carry a depth |
| 2 | `sync`, the ssh session reset, the guest gone | nothing: the guest's disk held no log and the reboot was the panic's own `Shutting down cpus with NMI`. What said so was the serial console, turned on for run 3 | none yet; the instrument was missing, and `doc/README.testing.md` now says to attach it first |
| 3 | `sync`, panic | lockdep first: `possible recursive locking` on `h2ch_dio` at `hammer2_chain_modify()` under `hammer2_freemap_alloc()` under `hammer2_chain_modify()`, with the inode's chain lock, its `diolk`, and the freemap root and leaf held. Then `hammer2_io_alloc: illegal base: 0000000000000000 0000000000000000+00010000` from `hammer2_xop_inode_flush()` under `hammer2_vfs_sync_pmp()` | two. `chain->diolk` took one lockdep class from its one `init` call site, so an inode's under a freemap leaf's read as the same lock twice; it is now classed by type and keybits as the chain lock is. And the flush wrote volume header 0 through the DIO layer, which refuses a physical base of zero by design; DragonFly and FreeBSD write the header through `getblk()` on the device, and this port now writes it through the block device's mapping, the one mount reads the headers from |
| 4 | nowhere | the file read back after `umount` and a read-only remount, `debug_locks` 1, kmemleak 0, no warning on the serial line | none, and one more found by reading the media, below |

Run 4's image, read on the host with hammer2-utils' `hammer2 show` and
diffed against `f5`, is what a copy-on-write flush should leave: the
volume header's `mirror_tid` advanced by one, and the four chains on the
path from the super-root to the file (the super-root inode, the PFS root
inode, the indirect block above the directory, and the file's inode) each
rewritten at a new offset with the new `mirror_tid` and a new XXH64,
nothing else touched, 3002 bytes different in 2 GiB. Two of its numbers
were wrong. The file's `modify_tid` read 1 where the tree's read `0x4f`,
and the PFS root's `pfs_inum`, the next inode number to hand out, read 0
where it had read `0x409`. Both came from `hammer2_get_tree()` never
seeding `pmp->inode_tid` and `pmp->modify_tid` from the PFS root, which
upstream's `hammer2_vfs_root()` and the FreeBSD port both do with the
`ipcluster` XOP at the mount root; that block is now carried there.
With it the file carries `modify_tid 0x51` and the root `pfs_inum 0x40a`,
and the next created inode will be numbered above `HAMMER2_INODE_START`
rather than colliding with the root's.

On DragonFly, with the image attached to `dragonflybsd642`:

| check | result |
|---|---|
| `cat hello.txt` | `HELLOen by dragonfly` then ` appended by linux`, the bytes Linux wrote |
| `stat` | size 40, blocks 0 (still embedded), the mtime Linux set |
| `md5 random128k.bin` | unchanged from the manifest |
| `fsck_hammer2 /dev/vbd1` | exit 0, the same lines as the untouched `f5` gives the host's `fsck_hammer2` |
| `hammer2 show` on the host | the diff above; `fsck_hammer2` on the host, exit 0 on both images |

That is F4 in one direction, Linux writing and DragonFly reading, for one
file whose data never left its inode. The final module's own Linux-side
runs, two of them on fresh copies, read the same: `overwrite exit 0`,
`append exit 0`, `sync exit 0`, `umount exit 0`, the file's 40 bytes
back after a read-only remount with `blocks 0` and the new mtime,
`random128k.bin` at its manifest checksum, `debug_locks 1`, kmemleak 0,
no `hammer2` line in the log beyond the module's own two, and 3002 bytes
different from `f5` both times.

## Truncate, extend, chmod, utimes and fsync

`->setattr` and `->fsync` are upstream's `hammer2_setattr()` and
`hammer2_fsync()` with the permission checks and the attribute copy
handed to `setattr_prepare()` and `setattr_copy()`, over the carried
`hammer2_inode_chain_sync()` and `hammer2_inode_chain_flush()`. The test
is `random128k.bin` on a fresh copy of `f5`, a 128 KiB file DragonFly
wrote in two 64 KiB blocks: shrink to 100000, grow to 200000, shrink to
100, `chmod 640`, `touch` to a 2020 date, append four bytes, then
`fsync` on `hello.txt` after an overwrite, `sync`, `umount`, a read-only
remount. Three runs:

| run | what the instrument said | the defect |
|---|---|---|
| 1 | after `echo 3 > drop_caches`, the region the grow added read 30951 non-zero bytes of 100000; in the page cache, before the drop, it had read zero. And lockdep, at the first `truncate`: `possible circular locking dependency`, `h2ip_tr` held and `h2ip/2` wanted in `hammer2_vop_setattr()`, against the order `h2ip/2` then `h2ip_tr` the same function had taken a moment earlier | two. A block is stored whole, so the bytes past a shrunken end stayed on the media and a grow read them back as data; DragonFly zeroes them in the buffer cache in `nvtruncbuf()` and `nvextendbuf()`, and this port now does the same in `hammer2_zero_tail()`, reading the block through `->read_folio` and dirtying it. And upstream's `hammer2_truncate_file()` drops and retakes `ip->lock` around `vtruncbuf()` while holding `truncate_lock`, which is the reverse of the order every other path takes them in; here the page cache truncation runs under the VFS's `i_rwsem` before `ip->lock` is taken at all, and the retake is gone |
| 2 | the same, before the fix was complete; not counted | |
| 3 | every step exit 0; the grown region 0 non-zero bytes before and after `drop_caches`, the same md5 both times; after remount size 104, mode 640, the first 100 bytes at the checksum they had before the shrink and `tail` after them; `debug_locks` 1, no `hammer2` line in the log beyond the module's own, kmemleak 0 | none |

The mtime is the append's, not the `touch`'s, as it should be; the
atime is the `touch`'s and `hammer2 show` on the host reads it as
`01-Feb-2020 19:02:02`. On DragonFly the file reads size 104, mode 640,
the same mtime, the same md5, the same first 100 bytes and the same
tail; `fsck_hammer2` exits 0 there and on the host. The host's `hammer2
show` diff against `f5` is the copy-on-write path as before, with the
file's inode now carrying `size 104`, `data_count 1024` and one data
chain where it had two, the block past the new end deleted by the chain
sync.

## Creating and removing names

`->create`, `->mknod`, `->mkdir`, `->symlink`, `->unlink` and `->rmdir`
are upstream's six entry points over the carried
`hammer2_inode_create_normal()`, whose owner rule is written against
the idmap where FreeBSD's reads `struct ucred`, `hammer2_dirent_create()`
and the unlink XOP; `hammer2_evict_inode()` now does what upstream's
`hammer2_inactive()` does for an inode whose last name is gone. The
test, on a fresh copy of `f5`: `mkdir newdir`, a 17-byte file and a
70000-byte file in it, a symlink to the file, a character device 1:3,
a directory with a file created and both removed, `hello.txt` removed,
`sync`, `umount`, a read-only remount. Three runs:

| run | what the instrument said | the defect |
|---|---|---|
| 1 | every step exit 0 but the symlink, which hit a name `f5` already carries; lockdep at the first `mkdir`: `possible circular locking dependency`, `h2ch_inode` wanted in `hammer2_chain_create()` under `hammer2_xop_inode_create_det()` with `h2ch_indirect#3/2` held, against `h2ch_inode --> h2ch_inode/1 --> h2ch_indirect#3/2` from mount | a chain created rather than read never got its nesting level, so it locked at level 0, the super-root's, under an indirect block at level 2. `hammer2_chain_create()` now takes the level from the parent it is created under before its first lock |
| 2 | the symlink step exit 0 and read back through it; the same lockdep report | the inode chain the create XOP makes is detached, created with no parent, so the level set from a parent never applied. Its first lock now records no order, as a fresh inode's does, and `hammer2_xop_inode_create_det()` gives it the level of a chain under the parent it looked up |
| 3 | every step exit 0; after remount the directory lists the three entries, the 70000-byte file at the checksum it was written with, the symlink resolved through, the device node with its numbers, the removed names gone, `debug_locks` 1, no `hammer2` line in the log beyond the module's own, kmemleak 0 | none |

On DragonFly the same tree reads the same: the removed names absent,
the file contents and checksum equal, the symlink followed, the
directory's link count 2, and DragonFly then creates a file inside the
directory Linux made. `fsck_hammer2` exits 0 there and on the host. The
host's `hammer2 show` diff against `f5` lists the four new inodes with
`iparent` set, the device inode with `rmajor 1` and `rminor 3`, the new
directory entries, and `pfs_inum` advanced past them. DragonFly's `ls`
shows the device as `255, 0xffff00ff`, which is DragonFly's own:
`hammer2_vop_getattr()` in its tree sets `va_rmajor` to 0 for every
inode, so no device node on a HAMMER2 volume reports its numbers there.

A directory's link count is the media's, not the VFS's own tally.
HAMMER2 stops counting links on a directory whose count reads 1, the
value `newfs_hammer2` writes on a PFS root, and the core guards every
change with `nlinks != 1`; `->mkdir` here raised the VFS count on the
parent every time and `->rmdir` lowered it every time, so a root that
held a thousand directories reported 1001 links until a remount
reloaded it as 1, after which the second `rmdir` under it tripped the
kernel's zero-link warning in `drop_nlink()`. Found on 2026-09-06 by
the tree instrument's delete pass at twenty thousand files, on the
first run to remove a directory after a remount. The three sites that
change a directory's VFS count, `->mkdir`, `->rmdir` and the two
directories of a cross-directory `->rename`, now copy the media's
count after the core has changed it; the same twenty thousand files
then deleted with no warning and both checkers clean.

## Rename and hard link

`->rename` is upstream's `hammer2_rename()` from its transaction on.
Everything before that point in the FreeBSD port is its vnode layer,
four vnodes relocked in an order that can fail and restart and both
names resolved again; Linux calls `->rename` with the directories and
the target locked and the dentries resolved, so the body here starts
where upstream's locking dance ends: `hammer2_inode_lock4()`, the
collision scan for the target hash, the carried nrename XOP, the moved
inode's name and parent, the replaced target's link, the directories'
times and link counts. `->link` is `hammer2_link()` as it is. The test,
on a fresh copy of `f5`: two directories with three files, a rename in
place, across directories, over an existing file, a directory moved to
the other parent and back with a rename inside it meanwhile, a file
renamed over a fixture file in the root, a hard link made and one of its
two names removed, `mv -n` onto a free name, `sync`, `umount`, a
read-only remount. Two runs:

| run | what the instrument said | the defect |
|---|---|---|
| 1 | every step exit 0 and every count right; lockdep at the first rename: `possible circular locking dependency`, `h2ch_inode/2` wanted in `hammer2_inode_chain()` from the nrename XOP with `h2ch_dirent/3` held, against the parent-before-child order every lookup records | the XOP deletes the entry from its directory and holds it, now detached, while it takes the target directory's inode chain to insert it there; upstream does the same. Nothing else can reach a detached chain, so the order is safe, and lockdep is told so by `lock_set_subclass()` on the held lock, moving it to the one subclass no tree level uses; levels now stop one short of lockdep's last |
| 2 | the same steps and counts; `debug_locks` 1, no `hammer2` line in the log beyond the module's own, kmemleak 0 | none |

The counts, from the second run and read the same after the remount:
the directory that received the subdirectory at link count 3 and the
one that lost it at 2, both moved back when the subdirectory returned,
the hard link at 2 on both names and at 1 after one was removed with
the content still there, the file renamed over the fixture's `tiny.txt`
reading as the renamed file. On DragonFly the same tree lists the same
names in the same directories, the same contents, the same three link
counts, and DragonFly then renames a file inside it. `fsck_hammer2`
exits 0 there and on the host.

## The order the flush writes in, from the block layer

0.5's criterion for the flush is that the volume header becomes durable
only after everything it references, shown by a write trace rather than
by reading the source. The trace is the kernel's own `block_rq_issue`
and `block_rq_complete` tracepoints, enabled through tracefs on the
guest (the guest kernel has `CONFIG_BLK_DEV_IO_TRACE` and no `blktrace`
binary, and tracefs is not mounted there by default), around a 9-byte
file and a 70000-byte file created on a fresh copy of `f5` and then
`sync`. Every request to the scratch device, in order, with the sector
and length in 512-byte units and the `sync` markers written from the
test itself:

| time | request | sector | who |
|---|---|---|---|
| 24.19 | `R` 65536, three of them | 286720, 768, 1408 | the write path's lookups |
| 24.20 | marker | | `written, syncing` |
| 24.20 | `W` 65536, two | 1408, 278528 | writeback of the DIO layer's dirty pages, from the sync's first pass |
| 24.21 | `WS` 65536, `R` 65536, `WS` 65536 | 295296, 294912, 294912 | the file's two data blocks, one of them read first because the write covered part of it |
| 24.22 | `WS` 65536, three | 1408, 278528, 286720 | `hammer2_dev_writeback()`, the freemap, inode and indirect blocks |
| 24.223 | `FF` | | `hammer2_dev_cache_flush()`, a flush request with no data |
| 24.227 | `FF` complete | | |
| 24.227 | `WS` 65536 | 0 | the volume header, the last request |
| 24.298 | marker | | `synced` |

The header is the last write and is issued only after the flush
request that precedes it completes, so on a device that honors flush
every block it references is durable before it is. Thirteen requests
reached the scratch device in the whole run and 380 the root disk; the
counts are in the transcript so a filter that matched nothing would
show. Two things the trace also says, recorded rather than argued: the
header write carries `WS` and not FUA, and no flush follows it, which
is what DragonFly and the FreeBSD port do as well, `bwrite()` after
`BIO_FLUSH`; the copy-on-write design tolerates it, since the previous
header stays valid until the new one is durable, and a flush before
the next header write orders them. The whole sequence took 100 ms on
the virtio disk.

## Mutated media against the mount path

0.5's corpus is `script/fuzz-mount.sh`, described in
`doc/README.testing.md`: copies of a 64 MiB seed volume, formatted by
hammer2-utils' `newfs_hammer2` and populated through the write path with
44 files across four directories, a symlink and a hard link, each copy
with one to sixty-four bytes changed at recorded offsets, hot-plugged
read-only into the guest and mounted, listed and read end to end under
the shipped build. The first sixty images, mutated at uniformly random
offsets, went 56 mounted and 4 refused with every mounted image reading
all 44 files: a 64 MiB image is almost entirely zero and absorbed the
hits, which is why the mutator now samples until it lands on a byte
that is not zero. Six runs since, 690 images, and every verdict in
them:

| run | images | mounted, all 44 files read | mounted, one or two files `EIO` | mounted, the listing cut short | refused | kernel report |
|---|---|---|---|---|---|---|
| seed 2, by hand | 100 | 36 | 43 | 2 (3 files listed, and 2) | 19 | 0 |
| seed 3, the script, with its two controls | 40 | 22 | 12 | 1 (0 files listed) | 5 | 0 |
| seed 1, before the bias | 60 | 56 | 0 | 0 | 4 | 0 |
| seed 4, after `hpanic` became `BUG()` | 100 | 36 | 52 (48 with one, 3 with two, 1 with three) | 1 (0 files listed) | 12 | 0 |
| seed 5, the generator that redraws | 100 | 45 | 42 (one each) | 1 (3 files listed, one `EIO`) | 13 | 0 |
| seed 6, the build with the reserve | 300 | 120 | 110 (107 with one, 3 with two) | 2 (0 files listed) | 68 | 0 |
| seed 1 again, the shim's own lock | 50 | 22 | 18 (one each) | 0 | 10 | 0 |
| seed 1, the write side, `hpanic` returning | 50 | 22 | 18 (one each) | 0 | 10 | 0 |

The last row is the first run of `H2_FUZZ_WRITE=1`, at `ce59742`:
the same fifty images mounted read-write and written into after the
read. Of the forty that mounted, thirty refused every write with `EIO`
and dirtied nothing, ten took a file, 256 KiB of random data, a
directory and an unlink and synced them, none reached an `hpanic`
site, and every `umount` and `rmmod` returned 0. The thirty are
mutations in the freemap's reserved zone: a leaf whose check fails is
refused at the allocation. `README.testing.md` has the mode.

The seed 4 row was the first run after `hpanic` stopped calling
`panic()`, and its purpose was the kernel report column: a mutation
reaching one of the fifty-four `hpanic` sites had been a dead guest with
an empty log and is now an oops that column counts. None did, in one
hundred images, which is the same reading the three earlier rows gave
under the old mapping and says nothing about whether a mutation can
reach one.

Reading that run's log found a defect in the generator that every row
above shares. A mutation is recorded as `offset:old>new`, and in one
recorded mutation of five the two bytes are equal: 99 of 508 on seed 3
and 356 of 1704 on seed 4, from zero written over a zero the sampling
never escaped, `ff` over `ff`, and a random draw that hit. An image all
of whose mutations are of that kind is the unmodified seed, and it
reads as "mounted, all 44 files read": four of seed 3's forty images and
five of seed 4's hundred were that. The generator now redraws until the
byte changes, which alters what every seed and index produce, so the
first four rows reproduce only from the generator at `7957583`, and
seed 5 onwards from the one that redraws. The counts in the four rows
stand as recorded; the images they exercised are fewer than they say
by the figures here. Seed 5 is the redraw's validation: 0 equal pairs
in 1190 recorded mutations, the total printed beside the zero because
a run that recorded nothing would read as zero too.

A refusal is a volume header or super-root the mount could not check;
an `EIO` is a data or dirent block whose XXH64 no longer matches, named
in `dmesg` by `hammer2_chain_testcheck()` as the F3 images are; a
listing cut short is a directory whose entries or whose inode failed
its check, after which the walk has nothing under it. None of the 200
produced a `WARNING`, `BUG`, oops, hung task or lockdep report, and the
guest answered every time. The two controls of the scripted run held:
the unmodified seed read all 44 files, and one bit in the header crc
was refused. The log of each run carries every image's mutations as
`offset:old>new`, so any of the 200 reproduces from its seed and index.

## The round trip both ways, on a volume made here

F4 is a tree written by this port, mounted and verified on DragonFly,
then the reverse; `script/f4-roundtrip.sh` runs it. Every earlier write landed on media DragonFly had
formatted; this one starts from a 2 GiB image formatted on the host by
hammer2-utils' `newfs_hammer2 -L LINUX`, so nothing on it was written by
DragonFly until DragonFly's turn. Linux, in the experimental build,
writes two directories with 306 files across them, 300 of them
one-line, one of 200000 random bytes, one of a million zeros, one
compressible, a symlink and a hard link, records every file's checksum
into the tree, syncs, unmounts, remounts read-only and checks its own
manifest. DragonFly then mounts the image, checks the same manifest,
follows the symlink, and writes a tree of its own: a 300000-byte file
from `/dev/random` in 1000-byte writes, 200 one-line files, a file
moved out of Linux's tree and one removed, with its own manifest.
Linux mounts last and checks DragonFly's manifest and what is left of
its own. Four runs:

| run | Linux writes, re-reads | DragonFly checks, writes | Linux re-reads DragonFly's | lockdep | the defect |
|---|---|---|---|---|---|
| 1 | 306 files, all match | 0 mismatches of 305; 204 files written | 202 of 203 match: `back/rand300k` differs | `possible recursive locking`, `h2ch_inode/2` twice under `hammer2_chain_create_indirect()` in `sync` | two. The read: that file's fourth 64 KiB block read as zeros on a whole-file read and correctly when read alone, and the FUSE reader agreed with DragonFly, so the port's read was wrong; the file mapping set only a minimum folio order, so readahead grew a folio to two blocks and the read filled it from the one chain at its start and zeroed the rest. Both orders are the block's now. The lock: an indirect block created under the PFS root inode to hold 300 new inodes takes over the root's children, locking each sibling while the flush holds one, the same class and level; the parent is held exclusively there, so the moved children lock one level below with `HAMMER2_RESOLVE_SIBLING` |
| 2 | 306, all match | 0 of 305; 204 written | all 203 match | `possible circular locking dependency`, `h2ch_indirect#5/2` then `h2ch_inode/2` in the flush against the reverse in `hammer2_xop_inode_create_ins()` | the inode chain being inserted is detached until that insert and held while its new parent indirect block is created and locked. First answer: annotate it as the rename's detached entry is annotated |
| 3 | the same | the same | the same | the same report with `h2ch_inode/7`, the annotated subclass, and `lock_set_class()` in the chain | the annotation itself: `lock_set_class()` re-registers the held lock as an acquisition under the parent already held, so the edge it was meant to remove came back with a new number. The acquisition that has no order to record is the new indirect block's first lock in `hammer2_chain_create_indirect()`, a chain nothing else can reach, the case `hammer2_chain_create()` already treats as fresh; it takes `HAMMER2_RESOLVE_FRESH` now and the annotation is gone |
| 4 | 306, all match | 0 of 305; 204 written | all 203 match | `debug_locks` 1 through both Linux phases, kmemleak 0 | none |

Both DragonFly reads of the Linux-written tree and both `fsck_hammer2`
runs there were clean in every run, 1056 blockrefs after DragonFly's
own writes, and the host's `fsck_hammer2` on the image after Linux's
turn exits 0 each time.

## A flush cut off, and what each recovery made of it

The deferral at the read-write refusal named this, and
`script/cut-flush.sh` runs it: DragonFly writing,
cut off mid-flush, the image mounted here read-write so the carried
`hammer2_recovery()` runs, and the result compared with DragonFly's own
recovery of the same image. On a fresh copy of `f5` attached to the
DragonFly guest, a loop wrote files of 4 to 80 KiB from `/dev/random`
and a `last` marker, with `sync` every 200 files; after 25 seconds the
host ran `virsh destroy`, which is the power going out as far as the
guest is concerned. The image was then copied, one copy for each
recovery.

| | the cut-off image | after this port | after DragonFly |
|---|---|---|---|
| header `mirror_tid`, `freemap_tid` | `0x64`, `0x64` | `0x65`, `0x65` | |
| `fsck_hammer2` on the host | exit 0 | exit 0 | |
| read-write mount here | `hammer2_recovery()` ran; `sync_tid >= mirror_tid`, so nothing to replay | | |
| `crash/` entries | | 16401, `last` 16399, all readable | 16401, `last` 16399 |
| a write after recovery, then `sync` | | exit 0, `crash/linux-after` | |
| DragonFly mounting the result | | 16402 entries, the new file read back, `fsck_hammer2` exit 0, 52838 blockrefs | `fsck_hammer2` exit 0, 52836 blockrefs |
| `debug_locks`, kmemleak | | 1, 0 | |

What the fixture shows is the property the trace above predicts: the
header is written last, after a flush, so a cut at any point leaves the
previous header and everything it references intact, and the two tids
in it agree. Eighty-two flushes had completed in the 25 seconds
(`0x12` to `0x64`), and the files those flushes covered are all there,
16400 of them plus the marker; what the cut lost is what no flush had
reached. The carried recovery is the freemap rebuild for the case
where the header's `freemap_tid` lags its `mirror_tid`, and this cut
did not produce that case; the code ran and found nothing to do, which
is the correct answer on this image and not a test of the replay
itself. Producing the lagging case needs a cut between the freemap
flush and the header write inside one `sync`, a window of milliseconds
that `virsh destroy` from the host does not hit on purpose.

So the script's fourth stage makes the case deliberately. DragonFly's
recovered copy has its header's `freemap_tid` lowered by four
transactions and the two checksums over that sector recomputed, a
rewrite the host's `fsck_hammer2` accepts, and both recoveries run on
it. In the recorded run the cut left the header at `0x6f`, `0x6f`; the
rewrite made it `0x6f`, `0x6b`; this port's read-write mount printed
`freemap recovery 6c-6f`, the four transactions it rescanned, read all
18401 entries, wrote one more and left the header at `0x70`, `0x70`,
with `debug_locks` 1 and no report; the host's `fsck_hammer2` and then
DragonFly's, after DragonFly's own mount of the same image, were both
clean. That is the replay running end to end on the case it exists
for, and the deferral at the read-write refusal, which named exactly
this, now names the decision that remains.

Everything the write side has was written by this point, reached only
in the `HAMMER2_RW_EXPERIMENT` build, and the shipped module still
refused the read-write mount. The crash matrix in the next section is
what lifted it.

## The crash matrix, calibrated against the FreeBSD port

0.6 asks for four ways of interrupting a writer, each leaving a volume
that mounts, recovers to a committed state and passes `fsck_hammer2`
with the same verdict a working port gets, and `script/crash-matrix.sh`
runs them. The writer is the same loop as the cut-flush fixture, files
of 4 to 80 KiB and a `last` marker with a `sync` every two hundred, on
an 8 GiB volume `newfs_hammer2` made on the host so that all four
volume header zones exist. After twenty seconds the cell happens: the
writing process is killed with `SIGKILL` and the volume unmounted
(kill), the guest kernel is made to panic, through `sysrq` here and
`debug.kdb.panic` on FreeBSD (panic), the host destroys the domain
(power), or the host destroys the domain and then zeroes the second
32 KiB of the newest valid header, which is what a 64 KiB header write
that reached the media in part looks like (torn). The cut-off image is
copied and each copy recovered separately: this port mounts one
read-write, reads every file, writes one more and syncs; Kusumi's FreeBSD port, v1.2.13 on the `freebsd15` guest at
FreeBSD 15.1, does the same to the other and runs its own
`fsck_hammer2`; the host's `fsck_hammer2` from hammer2-utils judges the
cut-off image and both results. The FreeBSD port wrote every cell first,
so what a working port leaves behind and recovers was on record before
this port was judged against it, and then this port wrote the same
cells. Every cell ran twice, and a cell is green only when both runs
gave the same verdicts.

Twenty rows, recorded 2026-09-05, sixteen from the first full run and
four from a second run of the torn cell alone, the header column being the
`mirror_tid` of the newest valid header at the cut and the entry count
what both recoveries listed under `crash/`, which agreed in every row:

| writer | cell | run | header at cut | entries, `last` | host `fsck_hammer2` on the cut-off image | this port's recovery | FreeBSD's recovery |
|---|---|---|---|---|---|---|---|
| FreeBSD | kill | 1 | `0x35` | 7211, 7208 | clean | all readable, wrote, unmounted, `debug_locks` 1, no report | all readable, wrote, unmounted, fsck clean |
| FreeBSD | kill | 2 | `0x3a` | 8259, 8256 | clean | same | same |
| FreeBSD | panic | 1 | `0x31` | 6601, 6599 | clean | same | same |
| FreeBSD | panic | 2 | `0x32` | 6801, 6799 | clean | same | same |
| FreeBSD | power | 1 | `0x2f` | 6201, 6199 | clean | same | same |
| FreeBSD | power | 2 | `0x32` | 6801, 6799 | clean | same | same |
| FreeBSD | torn | 1 | `0x33` in zone 3 torn, `0x32` newest valid | 6801, 6799 | reports zone 3, see below | same | same |
| FreeBSD | torn | 2 | `0x38` in zone 0 torn, `0x37` newest valid | 7801, 7799 | reports zone 0 | same | same |
| FreeBSD | torn | 3 | `0x36` in zone 2 torn, `0x35` newest valid | 7401, 7399 | reports zone 2 | same | same |
| FreeBSD | torn | 4 | `0x2f` in zone 3 torn, `0x2e` newest valid | 6001, 5999 | reports zone 3 | same | same |
| this port | kill | 1 | `0x27` | 4560, empty | clean | same | same |
| this port | kill | 2 | `0x26` | 4336, 4333 | clean | same | same |
| this port | panic | 1 | `0x26` | 4401, 4399 | clean | same | same |
| this port | panic | 2 | `0x24` | 4001, 3999 | clean | same | same |
| this port | power | 1 | `0x25` | 4201, 4199 | clean | same | same |
| this port | power | 2 | `0x26` | 4401, 4399 | clean | same | same |
| this port | torn | 1 | `0x25` in zone 1 torn, `0x24` newest valid | 4001, 3999 | reports zone 1 | same | same |
| this port | torn | 2 | `0x20` in zone 0 torn, `0x1f` newest valid | 3001, 2999 | reports zone 0 | same | same |
| this port | torn | 3 | `0x25` in zone 1 torn, `0x24` newest valid | 4001, 3999 | reports zone 1 | same | same |
| this port | torn | 4 | `0x25` in zone 1 torn, `0x24` newest valid | 4001, 3999 | reports zone 1 | same | same |

The host's `fsck_hammer2` after each of the 40 recoveries was clean, and
the summary found every cell's runs in agreement. Three things in
the table are worth reading rather than counting.

The entry counts of the panic, power and torn rows end in 01 with a
`last` two below, because the writer syncs after every two hundredth
file and those cuts land between one sync's header write and the next,
so the volume holds what the last flush covered and nothing the panic
or the power loss interrupted. The kill rows do not, because that cell
kills the process and then unmounts, and an unmount flushes, so the
volume holds everything written up to the signal: 7211 entries with
`last` 7208 is a writer killed after its 7210th file and before the
marker that follows it, and the first kill of this port's writer, 4560
entries and an empty `last`, is one killed with the marker opened and
truncated and not yet written. Both recoveries read the same names in
every row, and the second run of that cell, killed at a different
instant, has the shape of the other three.

The torn cell is where the two checkers part company with the two
mounts, and the harness had to learn the difference. Both kernel mounts
skip a header whose CRC fails and take the newest that passes, so the
recoveries above read the volume as of the previous flush with nothing
lost that flush covered: 6801 entries under a torn `0x33`, which the
valid `0x32` header references in full. `fsck_hammer2`, DragonFly's and
the Rust port of it alike, chooses its zone by `mirror_tid` before it
checks the CRC, reports `Bad volume header CRC` on that zone and stops,
exit 1; run with `-f` it scans the three intact zones clean and exits 0
with the report still printed. That is the checker doing its job, a
torn header is damage, and the harness records the cell as green when
the report names exactly the zone that was torn and both recoveries and
the checker after them are clean. It was first written to expect a
clean verdict on the cut-off image, and the first run's four torn rows
carried `FAIL` in that column on a result that was correct; runs 3 and
4 of each torn cell are the second run of that cell alone, with the
expectation corrected, and the harness reported it with no failure.

The headers rotate through the four zones, one per flush, so which zone
the torn cell destroys depends on how many flushes the writer reached,
and the eight torn rows above hit zones 3, 0, 2, 3, 1, 0, 1 and 1. A 2 GiB image
has one zone and the cell would leave nothing to fall back to, which is
why the volume is 8 GiB and why the harness prints every valid header's
tid at the cut.

The matrix is what the deferral at the read-write refusal was waiting
for after the interrupted flush, and it finds nothing the recovery gets
wrong on media either port wrote. So the refusal is gone: the shipped
module mounts read-write, runs the carried recovery on the way, and the
`HAMMER2_RW_EXPERIMENT` build flag that lifted the refusal for every
measurement from the first read-write mount to this matrix is retired
with it. What stays refused is the remount from read-only to
read-write, which upstream makes by reopening the volumes and running
the recovery a second time in `hammer2_remount_impl()`, a path this
port has not carried; the ledger below names it. The first mount of
the module built without the flag, on the image this port had
recovered in the last torn row: mounted read-write with `rw` in
`/proc/mounts`, a file written and synced, unmounted; mounted `ro`,
`mount -o remount,rw` refused with `EROFS` and the mount still `ro`,
the file read back, unmounted; `debug_locks` 1, no report, `rmmod` 0,
and the host's `fsck_hammer2` clean afterwards.

## The README's recipe, run as written

The six commands `README.md` gives a tester were run on the Artix guest
on 2026-09-05, from a `git archive` of the tree, before the section that
holds them was pushed. Two of them the guest cannot run: its kernel is
a test build with no headers behind `/lib/modules/7.3.0-rc1/build`, so
`make` stopped there, and it has no loop device support, so `losetup`
found nothing to open. The module was built on the host against the
same 7.3.0-rc1 tree and put where `make install` looks, and a virtio
disk stood in for the loop device. From there every step did what the
page says: `make install` 0, `modprobe hammer2` 0 with `lz4hc_compress`
loaded beside it, which is why the page says `modprobe` and not
`insmod`; `newfs_hammer2 -L TEST` 0; `mount -t hammer2 /dev/vdb@TEST`
0 with `rw` in `/proc/mounts`; a file written and synced; unmount 0;
mounted again with `-o ro`, the file read back and the mount `ro`;
unmount 0; `modprobe -r` 0; no kernel report; and the host's
`fsck_hammer2` clean on the disk afterwards. The image is
`readme.img` in the fixtures directory and is not kept.

## A full volume, and the two defects it found

Every write measurement above was taken on a volume with room in it, and
nothing in this tree had ever filled one. `script/test-enospc.sh` does, and
asking that question once produced two defects, both since fixed: a
chain lock stranded on the `ENOSPC` path, which made the `sync(2)` after
a fill trip a circular lock dependency, and a chain outliving its PFS,
which faulted the unmount of a filled volume.

Two more followed once the reproducer kept its whole log and checked
the media against what it wrote: the held lock freed during a fill,
attributed and fixed, and a fill that lost nearly all of itself to a
flush with no room left, fixed by carrying the free-space reserve every
other tree has. The `ENOSPC` reaches the writer at `open(2)` and
`write(2)`, and since 0.7.11 `fsync(2)` and `syncfs(2)` report it too
rather than `EIO`. A fifth arrived as the gate's rate, one fill in
about eight losing four files with the reserve in place: a page leaves
the dirty count when writeback starts on it and is given its block only
when the strategy runs, and a writer in that window was admitted into
space the writeback still needed. The pages under writeback are counted
now. A sixth was reached on demand rather than by rate: a chain whose
flush fails keeps its `UPDATE` flag and is parked at zero references
until a flush clears it, and the unmount, which is the last flush,
dropped the volume root and left every such chain allocated. The
unmount scraps them now, children first, naming each. A seventh was
the rate that remained, one fill in thirty-three, attributed when the
gate read what the final sync allocated against what the count
promised: a block held in page-sized folios was written back once per
folio onto fresh media each time, and the sync that commits the fill
ate the slack with media the reserve had not counted. The block folio
is allocated with a request that retries, and writeback gathers a
split block's dirty folios and writes it once; the section on the
reserve below has the readings. "No corruption
has been seen" stood in this
paragraph for a day on the strength of two clean checkers; the section
below is what looking found.

### What a fill kept, and the reserve that keeps it

The reproducer hashes every file as it writes it, off the volume, and
after the sync drops the page cache and reads every file back from the
media. A fill capped at one hundred files on a volume with room reads
back one hundred, which is the control: the check itself is sound.
On a volume filled to its last block, both checkers clean afterwards:

| build | files accepted | read back whole | lost |
|---|---|---|---|
| no reserve check | 533, 583 | 2, 2 | 531, 581 |
| `hammer2_vfs_enospace()` carried | 511, 496 | 474, 286 | 37, 210 |
| plus a data-sync write under twice the reserve | 487, 489 | 473, 474 | 14, 15 |
| plus the root writeback's dirty pages counted | not measured: the guest's writer is in another cgroup, so that counter read near zero | | |
| plus every writeback on the device counted | 463, 463 | 463, 463 | 0, 0 |
| plus the pages under writeback counted | 461 to 475, twenty runs | all | 0 in all twenty |

HAMMER2 allocates at writeback, not at `write(2)`, and needs free space
for the flush that commits what was written: indirect blocks, the
freemap, the volume header. DragonFly and the three ports keep a
reserve for that, a twentieth of the volume set at mount, and refuse a
write, a create, a link, a rename, a remove and a size change once the
free count is under it, through `hammer2_vfs_enospace()`. This port
declared that function in `hammer2.h`, computed the reserve at mount,
subtracted it in `statfs`, and never defined or called the check. So
`write(2)` accepted data until the freemap was empty and the flush
could not allocate its own blocks; the strategy writes that had
succeeded were never committed, and the checkers saw a consistent
volume because the metadata that did land was consistent.

Carrying the check was a third of the fix. Its free count moves when a
block is allocated, and the page cache holds what `write(2)` accepted
until writeback allocates it, so the count was judged against space
several hundred megabytes of accepted data had already spoken for.
Upstream's second threshold exists for this: under twice the reserve a
write becomes semi-synchronous, so its blocks are allocated before the
next write is judged. The page cache's form of that is a data-sync
write, `IOCB_DSYNC`, which goes through `->fsync` before it returns.
The remainder is the data accepted before that threshold, and the
write entry now counts the device's reclaimable dirty pages against the
reserve as well as the write in hand, walking every writeback on the
device under RCU as the kernel's own accounting does, because under
cgroup writeback the superblock's own is the root cgroup's alone and
the guest's writer sits in another.

Verified on the build that carries all of this, `9c6d30f` and after,
because the reserve check runs on every write, create, link, rename,
remove and size change: the fixture gate, 11 images, 43 files, 100
ioctl results, 0 failures; the round trip, both directions, 305 files
checked by DragonFly with 0 mismatches and 203 of DragonFly's read back
here, 0 failures; the interrupted flush, 14401 entries recovered here
and one written after, 14402 read by DragonFly, the lagging-header
replay announced and both checkers clean, 0 failures; and the
reproducer itself, a gate since 2026-09-06, fifteen runs across its
shapes since the reserve, every one keeping every accepted file. The fuzzer ran last, on the
build with the fault check: 300 images on seed 6, 232 mounted and 68
refused, 0 with a kernel report, 0 equal pairs in 5037 recorded
mutations, both controls passing first.

Verified again on `3d364be`, the build with the reclaim scope, the
throttle and syncer, and the device read-ahead, on 2026-09-06: the
round trip, 305 files checked by DragonFly with 0 mismatches and 203
of DragonFly's read back here, 0 failures; the interrupted flush at 25
seconds, 15601 entries recovered here and one written after, 15602
read by DragonFly, the lagging header replayed, 0 failures; the PFS
domains, three roots made here and 21 files checked by DragonFly in
each, 0 mismatches; and the fuzzer, 100 images on seed 7, 76 mounted
and 24 refused, 0 with a kernel report, 0 hung.

The PFS domains run gained a written snapshot on `fde07ba`, the same
day: a snapshot of `SYSTEM` taken here, mounted read-write by label,
one file changed in it and one added, 22 files in its manifest, the
live root's file unchanged after; DragonFly checked all four
manifests with 0 mismatches, read the changed file apart from the
live root's and found the added file absent from the live root, its
checker clean, 0 failures, lockdep intact and no kernel report. That
run is what the capability declaration's snapshot rows stand on.

The same run on `e173432` with `H2_PFS_VOLUMES=2`, the filesystem
formatted across two 1 GiB images: the port mounted the pair by its
colon-separated device list and `volume-list` reported 2; the first
root took a 1200 MB fill, 1231424 KiB used on the set, past what one
volume holds; the three roots and the snapshot verified on DragonFly
over the same pair, 87 files with 0 mismatches including the fill,
DragonFly reporting 2 volumes and its checker clean; the host's
checker over the pair clean after each side, with its control; 0
failures, lockdep intact and no kernel report.

The gate's first run under its own name turned up what every run before
it had carried uncounted. Its kmsg capture held a warning from the
compaction daemon, `hammer2_file_aops does not implement
migrate_folio` from `mm/migrate.c`, printed once per boot when
compaction first tries to move one of this port's folios; the fallback
refuses every dirty folio and warns. The gate reported no report,
because its readings name the faults it was written for, the lockdep
banners and an oops, and a plain kernel warning was none of them: 39
of the 62 kept run logs hold it, every one of them read as clean. The
mapping now carries `filemap_migrate_folio`, the helper xfs uses for
folios that carry no private data, which is the case here and the
reason there is no `->invalidate_folio` either. The gate counts every
`cut here` line as a kernel warning and fails on one, and its selftest
holds that pattern against the line the kernel prints. Two runs on
the build with the helper: no warning after the module loaded on
either, 472 files accepted and read back whole on both. The count's
first run fired on the guest kernel's own warning at boot, a DMA
allocation in the USB host controller before the module loaded, so
the count is scoped past the module's load line.

The periodic flush is carried since 2026-09-06, on a different trigger
than the one recorded for it. The source trees' syncer flushes every
thirty seconds and this port flushed metadata on `sync` alone, which
every fill survived; what did not was a tree of six hundred thousand
files created without a sync between them, which held 2.4 GiB of
unreclaimable slab in modified chains and dirty inodes until the write
path failed. DragonFly bounds that with `hammer2_pfs_memory_wait()`,
a stall at a dirty-chain and a dirty-inode limit that kicks the syncer
at half of each and sleeps at the limit with hysteresis; the BSD ports
dropped it and kept one of its limits as an unread local. It is
carried here, with a delayed work as the syncer, kicked by the stall
and otherwise every thirty seconds, running the same whole-filesystem
sync as `sync(2)`, canceled by the unmount before the superblock goes
and trying the superblock's lock rather than taking it so that an
unmount holding it cannot leave it to run afterwards.

The thresholds differ for root and for a user, root refused with half
the reserve free and a user with all of it, and every run above wrote
as root. `H2_ENOSPC_USER=1` fills as `nobody`, and both thresholds are
read after the sync, where the dirty pages the refusal counted have
become allocated blocks and what is free is under the fill's threshold
plus one 64 KiB step: two user fills, 461 and 453 files, the user
refused again after the sync and root accepted on both, 462 of 462
and 454 of 454 intact; one root fill, 472 files, user and root both
refused after the sync, 472 of 472 intact. The first form of that
reading, a root write right after the user's refusal and before the
sync, was discarded unrun: writeback between two writes moves the
dirty count by more than the gap between the thresholds, so an
acceptance there could not be attributed. The first run of it also
met the guest's `fs.protected_regular`, which had the VFS refuse root
the open of the file the user's refused write had left behind, so
the probes take fresh names.

A writer through a shared mapping never calls `write(2)`, so the check
in the write entry never sees it. The reproducer asked what such a
writer is told on the full volume, on a file made and sized while there
was room so that neither the create path nor the size change could be
what answered, and the answer was nothing: the mapping accepted every
byte where `write(2)` was refused, and the allocation failed later in
the strategy XOP with the faulting thread long gone. The port now
carries a `->page_mkwrite` of its own, as `ext4` and `xfs` do, which
asks the same reserve the write entry asks with the folio's size plus
what the page cache already holds dirty, and refuses with `SIGBUS`,
the convention the page-fault path has for it. The reproducer runs a
`write(2)` of the same size at the same moment as its control and
fails a run where one is refused and the other is not. The fill ends
in 64 KiB pieces for that comparison to mean anything: a fill in
4 MiB pieces stops with up to 4 MiB above the threshold, and on the
first two runs of the check a 128 KiB probe fit on one and not the
other. With the tail fill, three runs of three: `write(2)` refused
and the mapped write killed by `SIGBUS` on each, 465, 466 and 467
files accepted and every one read back whole from the media.

Both accounts below are kept, the wrong turns included, because the
method is the transferable part: three of the readings this section once
carried as findings were artifacts of the instrument rather than of the
driver.

Measured on `artix-s6-kde` at 7.3.0-rc1 with `CONFIG_PROVE_LOCKING`, on
a 2 GiB volume. 583 files of 4 MiB each are written before `dd` reports
`No space left on device`, `df` reads 100% and `statfs` reports zero
available, which is the part that behaves. `debug_locks` was 1 at that
point and the `sync(2)` that followed disabled it, on eight runs of
eight. The unmount failed on four of those eight; that was recorded here
as the unmount hanging, and it was not. The unmount completes, and the
process running it is killed by the fault the second half of this
section is about.

The report is a circular dependency between two orders:

    hammer2_write_end -> hammer2_inode_chain_sync
        holds h2ip/2, takes h2ch_inode/2
    hammer2_vfs_sync_pmp
        holds h2ch_inode/2, takes h2ip/2

The first is upstream's and is not in question: FreeBSD's
`hammer2_vop_fsync()` and its write path both lock the inode and then
call `hammer2_inode_chain_sync()`. The second is the one that should not
happen. The whole report is `doc/enospc-lockdep.txt`, streamed out of
`/dev/kmsg` and written down before the unmount that would lose it. It
is the capture from before the fix and is kept as that.

### What was established, and how

The sync task held one chain lock while it took an inode lock. It was a
single acquire and not a recursion the chain code had miscounted: the
chain lock is recursive, `hammer2_chain_init()` calling
`hammer2_mtx_init_recurse()`, and the measurement read depth 0,
`lockcnt` 1, owner the sync task, on a chain of type `INODE`. The same
chain was held at every probe of a run, so it was one chain held
throughout rather than an accumulation, which a leak per iteration would
have grown to 583.

The cause is `hammer2_chain_create()` clearing the caller's chain
pointer when it cannot create an indirect block, which on a full volume
is the first thing `hammer2_chain_modify()` refuses. Two of its callers
release the chain they passed in under `if (chain)`, and a cleared
pointer skips that release. Twenty-five runs whose logs are kept have
reached the fill state since the change and none has reported a cycle,
against eight of eight before it.

Two readings recorded here as findings were artifacts, and are kept
because they are the reason the method changed. The first placed the
missed release inside `hammer2_inode_chain_sync()` on a count of N, N,
N-1, N-1 across four probes; that arithmetic compared two different
builds, since the function runs its backend only when `RESIZED|MODIFIED`
is set, three times in a run rather than once per file, so the probes
being subtracted had not fired on the same occasions. Every probe went
into one build after that.

The second was the held chain reading key `0x402` while the insert
failing beside it named inode `0x403`, which was recorded as an open
question about identity. It is what the cause predicts: the chain
stranded by an earlier failed insert is still held while later inserts
fail in their turn, so the two are not expected to match. That is an
explanation offered after the fact and not an independent measurement.

On a later `sync_fs` pass of the same `sync(2)` the chain was already
held at `hammer2_vfs_sync_pmp()` entry, before `hammer2_trans_init()`.

Why the two orders meet at all is the port-specific half. In DragonFly
the flush runs on its own thread, so a chain the flush holds and an
inode the sync loop locks belong to different tasks and never form an
order. XOPs run synchronously here, so both land on the sync task. The
write side is upstream's and does not move; the sync loop is the side
that must not hold a chain when it takes `ip->lock`.

### What has been ruled out

Each of these was tested rather than reasoned about, and is recorded so
it is not tested again:

- An XOP body returning with a chain still locked.
  `hammer2_xop_inode_create_ins()`, `hammer2_xop_inode_chain_sync()` and
  `hammer2_xop_inode_destroy()` each reach one cleanup label that
  unlocks and drops both chains on every path, including the error ones.
- `hammer2_chain_unhold()` leaving the mutex held. A build with a
  `WARN_ONCE` on exactly that condition scored zero hits.
- lockdep subclass exhaustion. `hammer2_chain_lockdep_nest()` clamped
  to `MAX_LOCKDEP_SUBCLASSES - 2`. The one unclamped path,
  `hammer2_inode_lockdep_nest_under()`, was read here as reaching at
  most 7, which was wrong: it adds one to a parent inode's level, and a
  parent created through the same path carries its own parent's level
  plus one, so a directory nine deep on the media reached 8 and the
  Nix closure copy tripped `DEBUG_LOCKS_WARN_ON(subclass >=
  MAX_LOCKDEP_SUBCLASSES)` on a `setattr` at 99 s. The level is in
  the class now, not the subclass, and no path passes a level to
  lockdep; the closure section has the reading.
- `hammer2_flush_core()` replacing the chain it was given, so a caller
  would unlock the one it started with. It never reassigns `chain`.
- A lockdep shutdown from something other than a cycle. An unlock
  imbalance, a held lock freed and three lockdep ceilings all read as
  `debug_locks` 0, so the run reports which banner named the shutdown,
  and on every run of the cycle it named a circular dependency. The
  reproducer looked for the wrong text for one of the others: the kernel
  prints `WARNING: held lock freed!` where it looked for `BUG: held lock
  freed`, so a run whose log carried that fault reported none found. The
  patterns come from `kernel/locking/lockdep.c` now and the reproducer
  checks each of them against a line the kernel really prints.

### What is still open here

Nothing on the lock side. Lockdep reported `WARNING: held lock freed!`
on two runs, both after the chain lock fix and before the PFS one, and
neither was attributed: the run printed only the window following the
cycle banner, so a fault with a different banner left one line and no
backtrace, and no run recorded what it was built from. Once the log was
kept whole and every run stamped with its build, the next sighting
arrived whole: `dd` under `open(2)`, `hammer2_chain_create()` dropping
the directory-entry chain it had just allocated, still locked, when it
could not make room under the parent. Upstream's mutex tolerates a
locked chain being freed; here the drop took the lock again by
recursion and freed the chain with its rwsem held. The widened
last-drop guard fired on the same run and named the same chain, which
is what it was for. The chain is unlocked before the drop, marked as a
Linux edit, and every run since has kept lockdep alive.

`hammer2_chain_drop()` is a candidate for it and is guarded rather than
assumed: at its last drop it takes the chain's own lock, and this port's
chain mutex is recursive, so a caller already holding that lock succeeds
by recursion and frees a chain whose rwsem it still holds. A lock left
held by a task that has since dropped its reference reaches the same
banner by another route, and no task can hold the lock of a chain with
one reference, since the core never locks a chain it does not
reference. A warning names both where every caller passes, and says
which. It has not fired on any run, which makes it a guard and not
evidence in either direction. The one capture of the banner holds the
banner alone, from a run before the log was kept whole, and that run
cannot be tied to a build either side of the stranded-lock fix, because
no run recorded what it was built from until they all did.

The `ENOSPC` underneath all of this was written up here as dropped on
the floor, under upstream's own `XXX return error somehow?` in
`hammer2_inode.c`, with the caller told nothing. Measured, that was
wrong. The reproducer now records what `fsync(2)` on the last written
file and `syncfs(2)` on the volume return after the fill, and both
returned `EIO`: the strategy write's completion sets the mapping's
writeback error, which every tree does with `EIO` for any failure, and
the sync path reads it back from the mapping. What was lost was the
errno, not the error. The Linux side of that completion is this port's
own line, and it now hands the kernel the errno the core reports, as
ext4 and iomap do, so both calls return `ENOSPC` on the same fill.

The sync path's own returns were dropped, and that is carried and,
for a data write, without consequence on Linux; for the chain sync
and flush of an inode it was not, since a flush that cannot make room
for a PFS root's update on a full volume fails there and nowhere a
user reads, so the sync loop now records what those two return on
the inode's mapping, or on the superblock for an inode without one,
which is where `syncfs(2)` and `fsync(2)` look. The rest of this
paragraph is the reading that led there. The sync loop flushes each inode's
mapping with `filemap_write_and_wait()` and then discards what it
returns under an `XXX`, which is the line the `vnode flush failed 5`
messages come from: the failure is printed and the loop carries on.
That is the FreeBSD and NetBSD ports' `vn_fsync_buf()` line and its
`error = 0; /* XXX */` carried as they wrote it, and DragonFly ignores
what `vfsync()` returns at the same spot without a comment. It was
written up here as an upstream report to stage. It is not one: the two
callers a user reaches do not read that return. `sync(2)` returns zero
unconditionally in the kernel of record, and `syncfs(2)` reads the
superblock's writeback error sequence, which the strategy write's
completion sets through `mapping_set_error()` before the sync loop
runs, and which the `ENOSPC` reading above came from. A report with no
consequence to name is not filed. The return of
`hammer2_inode_chain_ins()` is discarded at the same site, and that
function clears `INODE_CREATING` before it attempts the insert, so an
inode whose insert failed for want of space is marked as one that has
been inserted. That is a candidate account of the references the module
holds after the filesystem has unmounted, and it is a candidate rather
than a finding until it is measured: the reference count has not yet
been captured on a run that failed, only on runs that did not.

That account is now superseded by the fault underneath it. The module
holding a reference after the filesystem unmounts is not a leak: the
unmount dies. `hammer2_flush_core()` takes a page fault during the
unmount of a filled volume, which kills the `umount` process, so
`deactivate_locked_super()` never finishes, the superblock is never
torn down and the module keeps the reference that `rmmod` then refuses
to release. `->kill_sb` is entered and dies partway: the fault is inside
it. Every failure recorded here as a
module that would not unload is that oops, three layers down:

    BUG: unable to handle page fault for address: ffffd3f284c01e28
    Oops: 0000 [#1] SMP NOPTI
    RIP: 0010:hammer2_flush_core+0x206/0x910 [hammer2]
    note: umount[2294] exited with irqs disabled

The faulting instruction is `cmpq $0x0,0x1e28(%rcx)` at
`hammer2_flush_core+0x206`, and both offsets resolve against the module's
own debug information: `chain+0x398` is `chain->pmp` and `pmp+0x1e28` is
`pmp->mp`. The source is the `chain->pmp && chain->pmp->mp` guard in
`hammer2_flush.c`. The guard passes because the pointer is not NULL; it
is freed. `hammer2_pfs` is 5255000 bytes, so it is vmalloc backed and
freeing it unmaps the pages, which is why the read faults rather than
returning rubbish.

The backtrace says which teardown step is running:

    hammer2_kill_sb
      hammer2_unmount_helper
        hammer2_pfsfree_scan
          hammer2_vfs_sync_pmp
            hammer2_inode_chain_flush -> hammer2_flush -> hammer2_flush_core
              hammer2_chain_tree_RB_SCAN -> hammer2_flush_recurse
                hammer2_flush_core

so a chain reached by the recursive flush still points at a PFS the free
in progress has already released.

That is now matched by address rather than inferred. A debug build logs
each PFS as `hammer2_pfsfree()` releases it, and the run reads:

    pfsfree_scan which 0 syncing pmp ffffd10a84400000
    freeing pmp ffffd10a84400000
    pfsfree_scan which 0 syncing pmp ffffd10a84c00000
    freeing pmp ffffd10a84c00000
    pfsfree_scan which 1 syncing pmp ffffd10a83c00000
    BUG: unable to handle page fault for address: ffffd10a84c01e28
    RCX: ffffd10a84c00000

The address the flush dereferences is the PFS freed two lines earlier in
the same scan, which frees a PFS and then `goto again` to sync the next
one. It is a use after free.

`hammer2_pfsfree()` carries upstream's guard against exactly this: it
counts leftover chains and refuses to free, printing `PFS still in use`,
when it finds any. The guard did not fire on any run. Its population is
`iroot->cluster.array[i].chain` with a non-empty rbtree, which is the
chains hanging directly under the PFS root inode's cluster and nothing
else, so a chain elsewhere in the topology that still carries `->pmp`
is invisible to it. Upstream also fixes up `hmp->vchain.pmp` and
`hmp->fchain.pmp` by hand when the super-root PFS goes, which is the
same hazard handled one case at a time.

The chain carrying the dead pointer is named by the same build. It is
`inode chain ed481bfef6b68000/0`, flags `004c6142`, which decodes as
`ALLOCATED | UPDATE | TESTEDGOOD | COUNTEDBREFS | ONRBTREE | BLKMAPPED |
BLKMAPUPD | PFSBOUNDARY`: a PFS root chain, still in the topology,
carrying an update the full volume never let complete. It is the same
key the fill reports over and over as
`hammer2_chain_create_indirect: inode chain ed481bfef6b68000/0 modify
error 00000020`, so the chain that outlives its PFS is the one the
`ENOSPC` was refused on.

`hammer2_pfsfree_scan()` takes that chain out of the PFS root inode's
cluster and drops it, and the drop does not free it because a reference
remains. It stays in the topology with `->pmp` pointing at storage the
next few lines release.

Clearing that pointer before the drop fixes it. A NULL `pmp` is a state
the chain code already expects: `hammer2_chain_alloc()` sets it for any
chain of the super-root topology, and every read of `chain->pmp` tests
it first, including the one that faults. It is also what this same
function already does by hand for `hmp->vchain.pmp` and
`hmp->fchain.pmp` when the PFS being freed is the super-root's.

Measured: fourteen runs after the change faulted on none, against five
faults in the seven runs before it. Ten of those fourteen are one batch
of the shipping build, with no debug knob set, and they are uniform:
each wrote 583 files to `ENOSPC`, each left `debug_locks` at 1 through
the sync, none reported a cycle, an oops or a held lock freed, and every
one unloaded the module. A batch of ten that never filled the volume
would read clean too, which is why the fill population is asserted per
run and printed above.

The fixture gate ran afterwards because this changes the teardown of
every unmount and not only a full one, and reported 11 images, 43 files,
100 ioctl results and 0 failures with lockdep enabled throughout.

The call shape and the site are upstream's: DragonFly and all three of
Kusumi's ports carry the same drop, and the patches are staged in
`doc/upstream/`, applying at zero fuzz against each of the four trees. It follows a run of `hammer2_flush_core: inode parent
0000000000000000/0 error 00000020` lines, the ENOSPC the flush is being
handed and not told what to do with, so the two are being read together
rather than separately.

The port's spin locks are ruled out as the source of the disabled
interrupts by reading: `hammer2_spin_ex()` and its family map onto
`rw_semaphore` in the shim and never touch the interrupt flag, so the
three regions `script/hammer2-spin-audit.py` reports as candidates
cannot produce this.

Both remaining faults are intermittent, so they are measured as rates
rather than runs. `H2_REPEAT=n` in the reproducer tallies n runs, keeps
each run's log, and resets the guest between them.

The gate is what the pre-push hook runs, and on the tree that carries
the closure's seventh fix it refused one push: 466 of 467 files intact,
one damaged, 34 chains left at the unmount. The hook kept twelve lines
of that run and lost the rest, so which file was damaged and what the
guest's log said are not on record; the hook now writes a failed gate's
whole output to a file under `.git` and says where, and the gate names
each damaged file with its size, so the next such run says whether the
loss was the last file the fill accepted or one long since flushed. The
same tree then ran the gate thirteen times with every log kept, three
and then ten through `H2_REPEAT`: twelve passed with every file intact
and zero inodes, chains, modified chains and dios outstanding at the
unmount, and one could not run because the guest did not answer ssh
within five minutes of its reset, the boot stall the fleet notes
already record, which the batch counts as neither pass nor fail. One
unrecorded failure in fourteen runs is the rate the tree carries until
the loss is seen again with its log, and it is not attributed: the
tree's last passing push was two write-path fixes and two lock fixes
ago, and no control at the earlier commit has been run at this rate.

The loss was seen again with its log on the next refused push, and
attributed. The hook's kept output has the whole shape: the fill
stopped at file 463 with 4067 blocks available, `syncfs(2)` returned
`ENOSPC`, the guest's log shows `hammer2_strategy_write` refused at a
block's offset for want of space, `vnode flush failed 28` for four
inodes and fourteen `hammer2_flush_core: inode parent ... error
00000020` lines, and four consecutive 4 MiB files, `fill.425` to
`fill.428`, read back damaged while `fill.463` and everything after
read back whole. Four files accepted forty files before the volume
was declared full is a writer admitted, not a flush that ran out: the
reserve count added the device's reclaimable dirty pages to the write
in hand, and a page leaves that count the moment writeback starts on
it, while the strategy allocates its block only when it runs. A
writer arriving in that window was judged against space the writeback
still needed. `hammer2_bdi_dirty_bytes()` counts `WB_WRITEBACK` as
well as `WB_RECLAIMABLE` now (`53aacb3`), which counts a page whose
block is already allocated twice for the rest of its writeback, an
early refusal that loses nothing. Both paths that admit data, the
write entry and the mapped-write fault, go through that one function;
the six metadata-only sites pass zero bytes, as upstream's do. Twenty
consecutive runs on the change, every log kept: 461 to 475 files
accepted, every one read back whole, zero inodes, chains, modified
chains and dios outstanding at every unmount, none could-not-run.
Against about one failure in eight before it, twenty clean is a rate
the change moved, not proof the window is closed, and the gate keeps
counting on every push.

It counted one more on 2026-09-07, in the hook of the push that carried
the returning `hpanic` (`b74a018`): the fill stopped at file 457 with
1268 blocks available, `syncfs(2)` returned `ENOSPC`, ten strategy
writes were refused at consecutive offsets, four inode flushes failed
with 28, and `fill.420` to `fill.423`, four consecutive 4 MiB files
thirty-four before the stop, read back damaged, the shape above
exactly. Five repeats on that tree and five on the tree before it, all
logs kept, read every file whole with nothing outstanding, so the loss
is not separated from the change by the control and is recorded as the
rate, one in thirty-three runs since `53aacb3` against one in eight
before it; the change it arrived with touches no reserve count.

Attributed the same day, once the gate could read what the sync took
against what the count promised. The freemap counts the bytes it
hands out for data and for metadata, the write entry's refusal names
the free count and the dirty bytes it judged by, and
`hammer2_assign_physical()` counts a data block that had media and
was given other media, all read by the gate around the sync that
commits the fill. Eight fills said: when the sync has nothing left to
write the count is exact, the leftover being the root slack of 766
blocks less about ten of metadata; and when it has, the leftover is
short by the number of blocks rewritten in that sync, 15 to 360 of
them a fill. Every rewritten block the debug log named was a block
held in 4 KiB folios, written back one folio at a time after the
whole block had been copied in, and each write after the first took
fresh media, since the core registers a data block for dedup as its
bytes go out and will not overwrite a registered block: sixteen
blocks of media for one block of data, none of it dirty bytes. The
folios were pages because the page cache asks for any order above a
mapping's minimum with `__GFP_NORETRY`, so the retry flag the mapping
carries never reached the block-sized request and it failed at once
under the fragmentation a fill leaves in a 4 GiB guest. The lost run
was a final sync with enough such blocks to eat the slack.

Two changes close it. `hammer2_write_begin()` allocates the block
folio itself with the mapping's mask, which retries reclaim and
compaction before failing, and asks the page cache only after that
fails or a folio already sits in the block; alone it still failed 37
and 22 times a fill in the last seconds before the refusal, and the
two fills rewrote 504 and 465 blocks, leftovers 345 and 295 of 766.
So `hammer2_writepages()` also takes a split block's other dirty
folios out of the dirty set and under writeback beside the first, and
the write XOP lays them all into the one block write. Two fills on
that: 0 rewritten blocks each, 67 and 42 block writes assembled around
a smaller folio, the block request refused 0 and 41 times, leftovers
756 and 753 of 766, every file intact. Overwriting a registered block
in place was not open to the port, since another chain can have
deduplicated to it in the meantime; the dedup lookup compares content
and nothing counts references.

What that run also showed and the change does not answer: two chains
outstanding at the unmount, with zero modified, after the strategy's
`ENOSPC`. The strategy's own callers of `hammer2_assign_physical()`
unlock and drop the chain on every error path, as DragonFly's do, and
the flush keeps the child's `UPDATE` flag and continues when the
parent's modify fails, by upstream's design, so the two references are
somewhere downstream of that and not yet named. The reserve now keeps
every run from reaching the path, so the reproduction has to be made
on demand: at the time, the kernel of record's guest trees were built
without `CONFIG_FAULT_INJECTION` (true of the debug and release trees
to this day; the KASAN tree has since gained it with `FAILSLAB`,
`FAIL_PAGE_ALLOC`, `FAIL_MAKE_REQUEST` and the debugfs controls, which
P4's `sync-alloc-fault.sh` uses), so the instrument is a module
parameter,
`fail_alloc_after`, under `HAMMER2_LOCKDEBUG` only, which counts
`hammer2_freemap_alloc()` calls and refuses every one past the number
with `ENOSPC`, the way a full freemap would; the freemap's own chains
take the reservation path above it and are not refused. It reaches
the guest through `H2_ENOSPC_MODARGS`, and the count at the unmount
is the reading.

Run with the allocator refusing from its 20,000th call, a third of the
way into the fill, the reading was four chains outstanding, the same
shape as the run of record and reproduced on the first attempt. The
debug build now keeps a list of every chain and prints what is left at
the unload, and the four were inode chains with zero references each,
in one line of descent: the super-root's inode, the PFS root inode
below it, and inodes `0x400` and `0x401` below that, three of them
flagged `UPDATE` and the top one `ONFLUSH`. That names the cause.
`hammer2_chain_lastdrop()` parks a chain that has a parent and `UPDATE`
or `MODIFIED` set at zero references on the parent's tree, by design,
because a later flush needs it; the flush clears the flag when the
parent's block table takes the child, and re-sets it when the parent's
modify fails with `ENOSPC`. The unmount's final sync is the last flush
there will be, and when it fails the same way the drop of the embedded
volume root leaves the parked subtree allocated, which DragonFly's
unmount and the three ports' do as well, read at their heads on
2026-09-07; only the unload check here counts it. `hammer2_unmount_helper()`
now walks the tree under the volume and freemap roots after that sync,
children first, takes the reference a parked chain does not hold,
clears the two flags and drops it, printing each as unflushed, since
nothing in it reached the disk and the writer was told so at the time.
The same run again read zero chains outstanding with the four named as
they went; a normal fill on the same build read 466 files whole and
zero outstanding with nothing scrapped, which is the control that the
walk is idle when the flush succeeds. Staged for upstream as
`doc/upstream/dragonfly-hammer2_vfsops-unmount-scrap-parked-chains.patch`
and the ports' pair.

## A million files, and where the writer stopped

0.9 asks for million-file trees with the number they produced.
`script/million-tree.sh` writes a tree of one-line files through the
write path, syncs, unmounts, remounts, drops the page cache and counts,
and has DragonFly count and check the same volume; every reading is a
number. The guest is the fleet's Linux guest, 4 GiB and twelve CPUs,
on a debug kernel with lockdep and kmemleak, the last of which holds
130 MiB of unmovable slab on its own. At a hundred thousand files the
port reads clean:

| files | create | sync | cold count here | DragonFly count | DragonFly fsck |
|---|---|---|---|---|---|
| 100000 | 24 s | 6 s | 100000 in 1 s | 100000 in 3 s | clean in 3 s |
| 100000, with the reclaim scope | 38 s | 14 s | 100000 in 2 s | 100000 in 5 s | clean in 3 s |

At a million it found two defects and one limit. The first run held
2.4 GiB of unreclaimable slab in modified chains and dirty inodes by
the six hundred thousandth file, because this port flushed metadata on
`sync` alone and the BSD ports had dropped upstream's throttle; the
throttle and a syncer are carried, and the same tree now holds 360
MiB. The second was the lock inversion against reclaim recorded above,
which the first hundred-thousand-file run reported three ways. The
limit is that every folio of a file mapping is a whole logical block,
an order-4 allocation, and on this guest the write path's grab for it
fails once the page cache has fragmented memory below 64 KiB:

| build | files before `ENOMEM` | unreclaimable slab at the refusal |
|---|---|---|
| no throttle | 598360 | 2.4 GiB |
| throttle and syncer, mapping mask without `__GFP_FS` | 730951 | 359 MiB |
| with `__GFP_RETRY_MAYFAIL` | 720266 | 360 MiB |
| the same, reclaim counters kept | 718666 | 352 MiB |
| mapping mask with `__GFP_FS` | 699172 | 355 MiB |
| the same, guest with kmemleak off | 1000000, no refusal | 237 MiB after the tree |

Every one of those runs counted every accepted file after a cold
remount and on DragonFly, with both checkers clean, DragonFly's in
113 s at 730951 files. The refusal is the kernel's page allocation
failure of order 4 in `hammer2_write_begin()`, with three gigabytes
available: at the last one, direct reclaim had scanned 237120 pages to
steal 10240, direct compaction had run five times with no success,
and the Normal zone held free 64 KiB blocks below a watermark boosted
by fragmentation. The retry flag, the mapping mask and the lock scope
were each varied and none moved the number by more than the run to run
spread, so the limit is the order and the environment together. The
number stands as this guest's: roughly seven hundred thousand
one-line files from a cold boot before the first `ENOMEM`, with 1.3
GiB of the volume used. What decides whether it is the environment's
is a run with `kmemleak=off`, one at 8 GiB, and one on a kernel
without the debug options. The first has been made, with the module
unchanged and kmemleak disabled through its debugfs node before the
module loaded: the writer reached a million files in 1007 s with no
refusal, 3.0 GiB still available, direct reclaim at 1632 pages stolen
of 93696 scanned and compaction stalled five times, and both sides
counted a million with both checkers clean. The limit is the guest's,
not the IO model's, and the design alternative, file mappings that
take smaller folios for blocks the strategy can still write whole,
stays `doc/IO_MODEL.md`'s question with nothing asking it. The
lock reading is not available at this scale: lockdep hits a chain
ceiling of the guest kernel's configuration near 300 s, which the
script reports as a ceiling and counts neither way.

The instrument then grew the rest of 0.9's tree rows: several writers
at once, a tenth of the tree deleted and written again while a
snapshot is taken through it, and the whole tree deleted. The first
run at a million found a deadlock. Two tasks sat unkillable, the sync
worker inserting an inode under the PFS root and an `rm` resolving a
name under it, and the hung-task report named each as the owner of
what the other waited on: the worker held the root's chain exclusive
and wanted an indirect block beneath it, the `rm` held that block
shared and wanted the root back. The core takes those two in one order
everywhere. The shim did not: its shared to exclusive upgrade, which
`hammer2_chain_unlock()` asks for on the last unlock of a chain and
which `hammer2_chain_lookup()` reaches on a parent while holding the
child it has just locked, was an `up_read()`, a write trylock and a
`down_read()` to restore, so for a moment the parent was held by
nobody, the queued writer took it and descended, and the restoring
read queued behind it. Lockdep could not see it: it had turned itself
off at 172 s on the chain table ceiling, and the cycle formed at about
400 s. The upgrade was then one compare and swap on the semaphore's
count, DragonFly's `mtx_upgrade_try()` on Linux's word with the layout
read back at module load, and is now the same compare and swap on a
lock word of the shim's own; `README.porting.md` has both decisions. The guest was read from outside through
the QEMU guest agent, ssh having hung on the wedged mount, and reset;
the media it left behind was consistent on both sides, which is the
snapshot row's reading and the crash matrix's again at this scale:

| after the forced power-off mid-churn | reading |
|---|---|
| `fsck_hammer2` on the host | clean |
| DragonFly count of the tree | 999000 files, one directory absent, the churn's last flushed deletion |
| DragonFly count of the snapshot taken under churn | 1000000 files, 200 spot checks, 0 wrong |
| DragonFly `fsck` | clean in 317 s |

The same configuration on the fixed module, kmemleak off, one run:

| phase | reading |
|---|---|
| create, four writers | 1000000 files in 248 s; one writer took 1007 s |
| churn, a tenth deleted and written again | 10 s, snapshot taken through it in under a second |
| sync and unmount | under a second each |
| cold count after remount | 1000000 in 6 s, 200 spot checks, 0 wrong |
| the snapshot, mounted by label | 999338 files, the churn's state at the moment it was taken, 200 spot checks, 0 wrong |
| whole tree deleted | 41 s, 0 files left |
| free blocks, before and after the delete | 90806 and 70097 of 125440 |
| kernel warnings | 0 |
| DragonFly, deleted tree | 0 files |
| DragonFly, snapshot | 999338 files in 20 s, 200 spot checks, 0 wrong |
| DragonFly `fsck` | clean in 151 s |

The delete frees nothing while the snapshot pins every block the tree
held, and its own metadata is new, so the volume is fuller after it.
The lock reading at this scale came with the guest kernel's chain
table raised from 16 to 20 bits, build #6 of the guest kernel: the same
configuration run once more kept lockdep on to the end, 78922 chains
used of 1048576 where the old table held 65536, with no report, zero
kernel warnings, the create in 327 s, the churn in 27 s, the delete in
110 s and both sides counting the snapshot at 999482, so the lock order
of the whole million-file churn has now been read once and was clean.
A lock cycle is a race, so
the fix was also read as a rate where lockdep stays on: the same
churn at twenty thousand files under a hundred directories, four
writers, run five times through `H2_REPEAT=5`, passed five of five
with lockdep alive to the end of each and zero kernel warnings, and
the million-file configuration itself, kmemleak off as above, run
three times through `H2_REPEAT=3`, passed three of three: the create
took 244, 275 and 250 s, the churn 10 to 11 s, the delete 42 to 45 s,
and DragonFly counted the deleted tree empty and the snapshot at this
side's count every time.

The same churn is the reading the roadmap named for the shim's own lock
primitive, the chain and inode locks moved from a wrapped
`rw_semaphore` to DragonFly's `mtx` on a lock word of the shim's own,
which `README.porting.md` records. Five of five passed on it with
lockdep alive to the end of each and zero kernel warnings, the create
in 12 to 13 s, the churn in 3 to 4 s and the delete in 6 to 7 s, both
checkers clean after each side every time; the full-volume gate ran on
it first, 472 files intact and nothing outstanding at the unmount.

## A real closure, and the eight defects it found

F6 asks for a real Nix closure of hundreds of thousands of paths read
at a measured cost beside the same read on squashfs or erofs.
`script/nix-closure.sh` takes the closure of a store path the host
already holds, writes it into a squashfs image and an erofs image,
and has the Linux guest copy it from the squashfs into an empty
HAMMER2 volume with `cp -a`, sync, unmount, remount, and read all
three cold with the page cache dropped between readings: a metadata
walk, a full read, and a hashed read that is also the content check.
DragonFly then counts the volume and runs its checker. The closure is
a KDE desktop system, 1978 store paths, 205871 files, 150219 symlinks
and 65985 directories, 11.8 GB. The guest is the fleet's Linux guest
at 7.3.0-rc1 with lockdep and kmemleak, 4 GiB and twelve CPUs, the
volume 48 GiB.

The first run's copy stopped in its first minutes, a worker asleep
in a link. The second run's copy
completed, and by the seventh the copy read back identical to its
source; the harness found eight defects in seventeen runs and an
eighteenth clean, none of
which a million one-line files in a hundred directories could have
reached:

1. **A lost XOP wakeup.** `hammer2_xop_testset_ipdep()` waits for its
   inode's slot in the per-PFS dependency table on a condition variable
   per index, but the flag that decides whether a retire wakes anyone,
   `HAMMER2_PMPF_WAITING`, is one bit for the whole PFS. A retire on
   one index cleared the bit for a sleeper on another and woke nobody,
   and a writeback worker slept for good with the copy behind it. The
   retire now wakes unconditionally; the fix is staged for upstream at
   `doc/upstream/ports-hammer2_admin-xop-ipdep-wakeup.patch`. Found in
   the first run; the second run's copy completing is its control.
2. **Lockdep's depth.** The inode lock's lockdep class was a subclass
   per directory level, and lockdep has eight. A store path is nine
   deep. A clamp put a parent and its child at one level past that
   depth, and lockdep reported the pair as a recursion at 78 s and
   turned itself off, so every lockdep reading past the second minute
   of a closure run was nothing. Fixed by putting the level in the
   class rather than the subclass: `hammer2_vfsops.c` registers a
   `lock_class_key` per (lock, blockref type, keybits, level) the
   first time one is seen, in an xarray, and unregisters them at
   module exit, so depth has no bound and every acquire is at subclass
   0; the detached, sibling and `lock4` positions keep theirs. The
   fifteenth run below is its reading: lockdep on from the first
   mount to the unload, 409 keys registered by the twelfth minute.
3. **`symlink(2)` returned a positive number.** The vnop stored
   `page_symlink()`'s negative errno and negated it on return, so a
   symlink whose target write failed went back to userspace as a
   success code no caller reads as an error. `cp` reported it with
   whatever errno the last failed call had left, which is why the
   second run printed `Cannot allocate memory` against files a symlink
   allocates nothing for. Negated at the call now; the other two sites in the vnops
   that take a Linux return hand it back unnegated and were right.
4. **Every symlink target sat in an unmovable folio.**
   `inode_nohighmem()`, which every filesystem calls on a symlink
   inode, replaces the mapping's whole allocation mask with
   `GFP_USER`, which drops `__GFP_MOVABLE` and the retry bit the port
   sets. 150219 symlinks were 150219 unmovable 64 KiB folios the
   allocator could not compact around. The port now clears the one
   bit the helper exists to clear.
5. **A lookup and an eviction waited on each other.**
   `hammer2_igetv()` held the inode lock across `iget5_locked()`, which
   waits for an older VFS inode of the same number to finish being
   freed, and `hammer2_evict_inode()` freeing it under kswapd wanted
   the same lock to disconnect it. `find` sat in
   `__wait_on_freeing_inode` and kswapd in `down_write`, the hung-task
   report naming each as the other's owner. The lock is released
   around the lookup and restored after it, which is what the FreeBSD
   port does around `vfs_hash_get()`; the field the lookup's set
   callback writes is safe with the lock released because the
   evicting inode cleared it under the lock before the hash let a new
   one in.

6. **A buffer freed under its holder.** `hammer2_io_putblk()` drops
   the last reference and then disposes of the buffer, still under the
   dio's lock. `hammer2_io_hash_cleanup()`, carried from the FreeBSD
   port, read the reference count under the hash lock alone, so a dio
   inside that window read as free, was unhashed and freed, and the
   holder's unlock landed on freed memory: the writeback worker
   released a reader it had never taken, `DEBUG_RWSEMS` reporting a
   count of zero and no owner. DragonFly keeps `DIO_INPROG` set across
   the window; the port takes the dio's lock before reading the count,
   in the order the hash lookup already uses. Four writers at once
   reached it at 76 s; one writer had not in nine runs. The three
   BSD ports carry the same cleanup, staged as
   `doc/upstream/ports-hammer2_io-hash-cleanup-lock-dio.patch`.
7. **A flush walked into a freed chain.** `RB_SCAN` reads the node it
   will visit next before each callback, and the flush's callback,
   `hammer2_flush_recurse()`, releases the parent's core spinlock to
   lock the child. A sibling removed and freed in that window, by a
   last drop or a delete under the same spinlock, was the next node,
   and the scan resumed on it: the fourteenth run's flush worker took
   a page fault in `hammer2_io_getblk()` at 113 s, the freed chain's
   `hmp` cleared, and died with interrupts off, after which every
   writer waited on the syncer it had killed. DragonFly's `tree.h`
   keeps the scans in progress on the tree head and its `RB_REMOVE`
   moves a scanner past the node it removes, which is what the core's
   "any item may be deleted while the scan is in progress" relies on;
   FreeBSD's `tree.h`, vendored here, has no such list, and the
   FreeBSD port's `RB_SCAN`, carried in `hammer2_rb.h`, never needed
   one because that port does not write. `hammer2_rb.h` now carries
   DragonFly's head, initializers and removal over the vendored tree,
   the list kept under the core spinlock every scan and removal
   already holds. Seen once, on the first run whose lockdep stayed on
   past the second minute; the reading of the mechanism is from the
   two headers, and the fifteenth run is its control: the same
   copy under the same four writers, the flush worker alive to the
   unload.
8. **A directory's entry in the directory's own lockdep class.** An
   inode lock is classed at its chain's level, and every inode fetched
   from disk hangs from the PFS root's inode tree whatever directory
   names it, so after a remount a directory and each of its entries
   sit at one level and share a class. Lookup and remove lock the
   directory and then the entry, the entry first as a trylock, which
   records no order; where the trylock missed, the blocking acquire of
   a same-class lock read to lockdep as one lock taken twice, and it
   turned itself off in the collection of the sixteenth and
   seventeenth runs below with nothing wrong in the locking. The
   seventeenth run had first moved the chain level rule to count the
   child's type and put both reports one level lower and still equal,
   which is what showed the level could not carry this. The entry's
   acquire in `hammer2_inode_get()` is now at subclass 1, as the VFS
   takes a child's `i_rwsem` at `I_MUTEX_CHILD` under its parent's;
   an annotation and not a lock, and the eighteenth run is its
   reading.

The fourth run, every fix in, on the guest as it is; the fifth with
kmemleak turned off before the module loaded (`H2_NC_GUESTPRE`); and
the seventh with the guest given 8 GiB, whose squashfs and erofs
columns are shown (at 4 GiB they read 58 and 40 s hashed):

| | HAMMER2, 4 GiB, kmemleak on | HAMMER2, 4 GiB, kmemleak off | HAMMER2, 8 GiB | squashfs, 8 GiB | erofs, 8 GiB |
|---|---|---|---|---|---|
| copy in, `cp -a` | 147 s | 113 s | 82 s | | |
| writes refused `ENOMEM` | 7 | 3 | 0 | | |
| cold walk, 422075 entries | 13 s | 9 s | 6 s | 3 s | 3 s |
| cold read, 11.8 GB | 37 s | 22 s | 15 s | 11 s | 6 s |
| cold hashed read, 205871 files | 64 s | 43 s | 39 s | 44 s | 27 s |
| hash list | differs by 7 | differs by 3 | `708a8df3` | `708a8df3` | `708a8df3` |
| symlinks, list hash | 150219, `4c2f5e2e` | 150219, `4c2f5e2e` | 150219, `4c2f5e2e` | 150219, `4c2f5e2e` | 150219, `4c2f5e2e` |
| hard-linked files | 83634 | 83636 | 83636 | 83636 | 83636 |

The symlink list is identical on every side. At 4 GiB each copy is
short by the writes `cp` was refused, and its hash list differs by
those files alone: each an order-4 folio the allocator could not find
with `__GFP_RETRY_MAYFAIL` set, between 118 and 166 s, now reported
under the right errno.
That is the refusal the million-file tree met at seven hundred
thousand files and attributed to the debug guest's kmemleak, and the
same control here does not clear it: the fifth run, kmemleak off
before the module loaded and the slab a third smaller for it, refused
the same order at 128 and 160 s. The allocator's report at the refusal
is in `IO_MODEL.md`: the Normal zone at its low watermark with nothing
free at 64 KiB or above in any migrate type, three gigabytes of file
cache on the inactive list with a quarter gigabyte dirty and under a
megabyte in writeback, compaction failing four stalls in ten. A 4 GiB
guest holding a 12 GB write stream beside its source's read stream is
where the kernel's own 64 KiB-block xfs meets the same refusal, and
the port retries longer than xfs before giving the same answer. The
reading that decides whether the answer stands is 0.9's low-memory
row. The sixth run lowered the dirty limit to 128 MB so writeback
would run ahead of the grab, and was refused twice more in a faster
copy of 99 s, once on a symlink's target, which `cp` now reports as
the failed link it is and which leaves a dirent with an empty target,
as the FreeBSD port leaves one when its target write fails. The
seventh run gave the guest 8 GiB and changed nothing else, and the
copy completed in 82 s with no refusal and no warning, every hash,
symlink and hard link at the source's; DragonFly counted and checked
it clean. The eighth, the same guest with an ext4 reference copy
beside it, refused one write at 120 s. So the refusal is the guest's
memory against the 64 KiB folio, and 8 GiB is where it becomes rare
for a 12 GB stream rather than where it stops: one run of three
clean, the ninth refusing one write as the eighth had.
What the port owes is 0.9's low-memory row: a write that cannot find
a 64 KiB folio is refused rather than retried into the OOM killer,
which is what the kernel's own large-block filesystems do, and the
rate at a given memory is the reading, not a pass.

The eighth run also took the reading the XOP pool decision waited on,
the same `cp -a` into ext4 on a fifth disk of the same guest:

| 8 GiB guest | HAMMER2 | ext4 |
|---|---|---|
| copy in, `cp -a` | 85 s | 79 s |
| cold walk | 8 s | 7 s |
| cold read | 17 s | 12 s |
| cold hashed read | 38 s | 47 s |

Synchronous XOPs, the FreeBSD port's choice, cost six seconds in
eighty-five against a filesystem with no XOP at all, and the port
reads back faster than ext4 on the same source. The pool stays
synchronous; the workqueue-backed pool is not built.

The tenth and eleventh runs dealt the store paths round four `cp`
processes (`H2_NC_JOBS=4`), 0.9's parallel-build row, on the 8 GiB
guest with kmemleak off, the eleventh on the build with the sixth fix
in; the ext4 column is the one-writer reference copy of the same run:

| 8 GiB guest | run 10, four writers | ext4 beside it | run 11, four writers | ext4 beside it |
|---|---|---|---|---|
| copy in, `cp -a` | 64 s | 78 s | 80 s | 96 s |
| writes refused `ENOMEM` | 3 | 0 | 1 | 0 |
| cold walk | 9 s | 6 s | 10 s | 6 s |
| cold read | 17 s | 16 s | 22 s | 14 s |
| cold hashed read | 44 s | 40 s | 44 s | 45 s |

Four writers put the closure in ahead of ext4's single writer on the
same guest both times, and ahead of the port's own single writer's 85
once; the refusals, three in one run and one in the other, are the
same 64 KiB folio, and each run's hash and symlink lists differ from
the source by exactly its refused writes.
A hard link across two writers' shares arrives as two files, which is
`cp`'s and not the port's, so the harness reports that count under
more than one writer and does not judge it. The same run found the
sixth defect, the buffer freed under its holder, at 76 s in the
writeback worker, and the eleventh, with the fix in, ran the same
four writers with no warning but the ceiling recursion, which every
run from the seventh to the twelfth had and the harness counts. The collection that followed each run removed 989 of the 1978
store paths in 14 s beside a reader, and DragonFly counted the 103693
files and 76012 symlinks that stayed, its checker clean in 57 s.

The twelfth run, on 2026-09-07, was the first on the write path that
assembles a block around a folio smaller than it, and it ran the
configuration that had refused writes: the 4 GiB guest, kmemleak off,
four writers. The copy went in at 66 s to ext4's 70 beside it, 1427
blocks were assembled around a smaller folio, counted from the
module's debug print, and no write was refused: the hash list matched
the source's and the squashfs, erofs and ext4 copies' on all 205871
files, and the volume was walked in 8 s, read in 15 and hashed in 44
to squashfs's 2, 11 and 49, erofs's 5, 9 and 29 and ext4's 6, 10 and
41. The failure moved to the read side: three order-4 grabs failed in
`hammer2_bread()`, on the device mapping, one at 251 s during the
hashed read, whose list still matched, and two during the collection's
reader, which exited 2 with 24 files unread; this side counted 103669
files after the collection where DragonFly counted 103693, and both
checkers were clean, DragonFly's in 55 s. The device mapping's minimum
order is still the block, and `IO_MODEL.md` names the buffer it needs
when the page cache cannot give one.

The thirteenth run, the same day, took the guest down to 2 GiB with
both fallbacks in, the DIO layer's buffer as well as the assembled
block: the copy went in at 65 s to ext4's 77 with four writers, 1727
blocks were assembled around a smaller folio and 144 held in the
dio's own buffer, no write was refused and no grab warned, every file
and every symlink hashed as its source on all four filesystems, the
collection removed 989 store paths in 12 s beside a reader that
exited 0 and its survivors hashed as theirs, and the harness exited
0; `IO_MODEL.md` has the reads beside the three references. Lockdep
was off at the end and the ring buffer, filled by the 1871 debug
lines that count the fallbacks, no longer said why. The fourteenth
run, without the debug prints, kept lockdep on past the second
minute for the first time and found the seventh defect above at
113 s.

The fifteenth run, the same day, with the lockdep classes and the
scan bookkeeping in, at 4 GiB with four writers, kmemleak off and no
debug prints: the copy went in at 97 s to ext4's 113 with no write
refused, both unmounts and the unload exited 0, and lockdep was on at
the end, `debug_locks` 1, the ceiling never reached, no kernel warning
in the saved log. Every file and every symlink hashed as its source
on all four filesystems, the cold read 61 s and the hash 96 to
squashfs's 23 and 71, erofs's 10 and 39 and ext4's 16 and 42, the
first read of the closure taken with lockdep on throughout where the
earlier readings had it off by then; the collection removed 989 store
paths in 37 s beside a reader that exited 0, its survivors hashed as
theirs, DragonFly counted the 103693 files and 76012 symlinks that
stayed and its checker was clean in 48 s, and the harness exited 0.
It is the first run of the closure in which nothing was refused and
lockdep read the whole run.

The sixteenth and seventeenth runs, on the shim's own lock primitive
(`README.porting.md`) with the same guest and writers, the seventeenth
with the chain level rule counting the child: the copies in at 89 and
95 s to ext4's 113 and 112, nothing refused, every file hashed as its
source at 115 and 97 s to squashfs's 70, erofs's 38 and 40 and ext4's
45 and 44, the collection removed 989 store paths in 39 and 38 s beside
a reader that exited 0, DragonFly counted the 103693 files and 76012
symlinks that stayed and its checker was clean in 62 and 57 s, and the
harness exited 0 both times; lockdep was off at the end of each, turned
off at 869 and 852 s by the eighth defect above, reported from `rm` in
the collection, so its silence past that point is not a reading.

The eighteenth run, with the entry's acquire at its subclass: the copy
in at 95 s to ext4's 113, nothing refused, every file hashed as its
source at 101 s to squashfs's 72, erofs's 37 and ext4's 46, the
collection removed 989 store paths in 42 s beside a reader that exited
0, `debug_locks` 1 after it and at the unload, no kernel warning,
DragonFly counted the 103693 files and 76012 symlinks that stayed and
its checker was clean in 52 s, the host's clean after each side with
its control, and the harness exited 0: the shim's own lock primitive
read by lockdep through the whole closure, copy, cold read and
collection.

DragonFly counted the fourth run's volume at the source's numbers,
205871 files and 150219 symlinks in 13 s, since a refused write leaves
its file, and its checker was clean in 87 s; the host's checker was
clean after each side and refused the header-byte control.

## The closure rerun on the fixed build

The closure rerun was launched from `bf314c6` on 2026-09-19 after the
sibling notation fix in `38c3998`. It used the 48 GiB HAMMER2 image, the
same 1978-path Nix closure, four writers, the debug kernel, lockdep and
kmemleak. The run copied the closure in 133 s, synced in 1 s, and copied
the ext4 reference in 188 s. The HAMMER2 walk took 39 s, the cold read
102 s, and the hashed read 139 s. The hash lists matched on HAMMER2,
squashfs and ext4 at `708a8df3c508a6dd`; the symlink lists matched at
`4c2f5e2e3a0b7df6`.

The collection removed 989 of 1978 store paths in 63 s while the reader
ran beside it. It left 103693 files and 76012 symlinks, and the survivor
list matched the source at `b61951160703aeb2`. `debug_locks` was 1 before
and after the run, the lockdep ceiling was 0, kernel warnings were 0,
both unmounts and `rmmod` exited 0, and the host checker was clean after
both Linux and DragonFly. DragonFly counted 103693 files and 76012
symlinks and its checker was clean in 60 s. The script reported
`0 failure(s)` and exited 0. `mkfs.erofs` was absent, so the erofs
reference was skipped.

| reading | result |
|---|---|
| source | 1978 store paths, 205871 files, 150219 symlinks, 11.8 GB |
| HAMMER2 copy | 133 s, copy exit 0 |
| ext4 copy | 188 s |
| HAMMER2 hash | `708a8df3c508a6dd` |
| squashfs hash | `708a8df3c508a6dd` |
| ext4 hash | `708a8df3c508a6dd` |
| symlink hash | `4c2f5e2e3a0b7df6` on all three |
| GC survivors | `b61951160703aeb2` on source and HAMMER2 |
| lockdep | `debug_locks` 1 before and after, ceiling 0 |
| checks | 0 kernel warnings, 0 failures, exit 0 |

## One large file, and what the BSD buffer cache gave for free

DragonFly's HAMMER2 reads ahead through `cluster_readx()` and writes
behind in file order through `cluster_write()`, both services of its
buffer cache, and the core's own comment says its allocation pattern
depends on the second. The port carried neither and no throughput
number existed, so `script/throughput.sh` was written to take the two
readings that decide them: a 512 MiB random file written from memory
to HAMMER2, ext4 and btrfs on the same 4 GiB debug guest, timed writes
with `fsync`, reads cold in the guest and warm on the host at 1 MiB
and 64 KiB requests, the HAMMER2 copy checked by hash after a remount,
DragonFly writing and reading the same on the same volume, and both
files' block placement read from the image with `hammer2 show`.

The allocation order needed no change. In key order the Linux-written
file's blocks are contiguous on the media at 8185 of 8191 steps, with
four forward and two backward jumps; DragonFly's own file on the same
volume, written by the same core under its buffer cache, is contiguous
at 2002 steps with 3182 forward and 3007 backward jumps. The
writeback path hands the strategy the blocks in file order.

The read rate was the finding. Profiled with the kernel's function
profiler, every one of the file's 8192 data blocks was a synchronous
device read: the DIO layer's `mapping_read_folio_gfp()` reads the one
folio asked for, and a comment beside it said the block device mapping
had the kernel's read-ahead behind it, which it does not. The port now
asks `page_cache_sync_ra()` on a miss for the BSD cluster hint's worth
of pages, `hammer2_cluster_data_read` blocks for data and
`hammer2_cluster_meta_read` for metadata, with a read-ahead state per
device. Measured 2026-09-06, MiB/s, one run each on the same guest and
images:

| filesystem | write | read, 1 MiB requests | read, 64 KiB requests |
|---|---|---|---|
| HAMMER2 before the change | 275 | 353 | 371 |
| HAMMER2 with device read-ahead | 289 | 602 | 683 |
| ext4 | 207 | 948 | 6400 |
| btrfs | 272 | 507 | 640 |
| DragonFly's HAMMER2, the Linux-written file | | 832 | |
| DragonFly's HAMMER2, its own file | | 671 | |

ext4's numbers are memcpy from the host's cache and no checksummed
copy-on-write filesystem reaches them; btrfs on the same guest is the
comparison, and the port now reads at its rate and at DragonFly's own.

Re-read on 2026-09-07 after the folio change of 0.9.1 and the shim's
own lock of 0.9.6, on the same guest and images, MiB/s, one run each
unless noted:

| build | write | read, 1 MiB | read, 64 KiB | `read_folio` calls, 8192 blocks |
|---|---|---|---|---|
| 154137d, folio change in, morning, two runs | 272, 265 | 557, 545 | 602, 595 | |
| 251cba9, before the folio change, same hour | 243 | 617 | 674 | |
| 2fe755c, the shim's own lock, three runs | 212, 209, 196 | 483, 528, 507 | 545, 595, 551 | 8228 |
| 154137d again, after those | 178 | 420 | 497 | 8228 |
| 574b82b, host load 2.7, a 17 GiB link running | 288 | 195 | 165 | 8228 |
| 7c7d6c4, host load 1.4, ext4 control 7314 | 277 | 557 | 602 | |

The folio change is not the read cost it looked like: a cold read
builds 8228 folios for 8192 blocks on either build, 36 more than one
per block, so the smaller folios the page cache may now use cost 36
decodes, not a tenth of the read. The host slowed the guest across
the session instead, the semaphore build reading 272 in the morning
and 178 at the end on the same image, and the last row names the
cause: a 17 GiB link on the host had taken the page cache, the ext4
read in that run fell from 7314 MiB/s to 240, so every read there was
the host's disk and not the driver's cost, while the write, which
does not go through the host's cache, was the day's highest. Every
comparison here is only as good as its host control, which the
instrument now prints and names when it is cold; the reading of
record above stands as not reproduced today rather than as regressed,
and the shim's own lock is charged with nothing on it. An owner spin before the sleep,
the rw_semaphore's own shape, was tried against the drop, moved
nothing and was not kept.

The last row is the quiet-host reading the earlier rows lacked: load
1.4 at launch, no build on the host, ext4 reading its file from the
host's cache at 7314 MiB/s, which is the control the instrument names.
The port read 557 and 602, the numbers of the 154137d morning runs,
so the reading of record above is reproduced and the range since the
read-ahead change is 545 to 683 across seven quiet runs. In the same
run btrfs read 3657 and 3938 and DragonFly's own kernel read the
Linux-written file at 868 and its own at 627, so on this run the port
reads at DragonFly's own rate and btrfs, served from the host's
cache like ext4, is no longer the comparison it was on 2026-09-06.
The run reads the file back with the source hash, zero kernel
warnings, both checkers clean with their negative controls. The
instrument's first two runs failed on their own readings before any
number was kept: the layout tool was called without its subcommand
and a long file name was looked up in the wrong block, each reading
zero blocks for both files, and the first read of each file after a
write went to the host's disk while the second hit the host's cache,
which read as a difference of ten times until a priming read was
added.

### The kernel every reading above was taken on

Every row above was taken on the guest's debug kernel, `PROVE_LOCKING`
with kmemleak, KFENCE and init-on-alloc, the configuration the defect
runs need. A `perf` profile of the 1 MiB read on that kernel, taken
2026-09-07 to answer why the port read at a twelfth of ext4, put 13%
of the reader's samples in `__lock_acquire`, 8% in
`lock_is_held_type`, 6% in `lock_release`, 7% in zeroing pages on
allocation, the rest of the top twenty in kmemleak's object tracking
and stack unwinding, and 3% in the module itself; the dd process spent
1.04 s of its 1.15 s wall in the kernel. ext4 and btrfs pay the same
tax per lock and per allocation and take far fewer of each per byte.
No release build of the kernel of record existed on the machine, so
one was built from the same source with the debug options off,
`7.3.0-rc1-release`, installed in the guest beside the debug kernel,
and the instrument was run on it, same host, same images, ext4
reading from the host's cache at 12800 MiB/s as the control, host
load 3.4, MiB/s:

| filesystem, release kernel | write | read, 1 MiB | read, 64 KiB |
|---|---|---|---|
| HAMMER2, this port at 69be912 | 582 | 2438 | 3012 |
| ext4 | 296 | 12800 | 12800 |
| btrfs | 277 | 10240 | 8533 |
| DragonFly's HAMMER2, the Linux-written file | | 877 | |
| DragonFly's HAMMER2, its own file | | 863 | |

The port writes at twice the rate of ext4 and btrfs and reads the
format at three times the rate of DragonFly's own kernel on the same
volume. On the release kernel the reader spends 0.12 s of CPU over a
0.19 s read and its profile is a third `xxh64`, a sixth the block copy
from the device mapping to the file's folio, a tenth the copy to user
space, and no lock bookkeeping; the rest of the wall is waiting on the
device. The wait was the read-ahead window: the DIO layer's read-ahead
state copies the device's `read_ahead_kb` at mount, 128 KiB, two
blocks. Measured on the release kernel with the device setting changed
before each mount and `cluster_data_read` at 4, 16 and 64, two reads
each at 1 MiB:

| device window | hint 4 | hint 16 | hint 64 |
|---|---|---|---|
| 128 KiB | 1720, 2141 | 2461, 2613 | 2738, 2770 |
| 512 KiB | 2456, 2417 | 2567, 2582 | 2763, 2746 |
| 2 MiB | 2743, 2713 | 2676, 2697 | 2738, 2756 |
| 4 MiB | 2936, 2908 | 2802, 2802 | 2778, 2773 |
| 16 MiB | 2914, 2966 | 3137, 3022 | 2989, 3007 |

The window is worth 40% at the shipped hint and nothing past 4 MiB,
so `hammer2_open_devvp()` raises the port's own read-ahead state to
at least 4 MiB at mount, which is what btrfs does to its backing
device, and leaves the device's sysfs value alone; the hint stays at
DragonFly's 4. With the change and the device at its default the read
measured 2686 and 2804 in two runs. What remains between the port and
btrfs is that btrfs verifies its checksums in bio completion on every
CPU while this port verifies and copies each block in the reader, one
block at a time; the profile says that ceiling is near 3 GiB/s on
this guest.

That ceiling was then tried, the same evening, on the branch
`strategy-readahead-workers`: a `->readahead` that hands each folio of
the window to an unbound workqueue, the superblock's bdi raised to the
same 4 MiB, and the read XOP allocated with `HAMMER2_XOP_STRATEGY`.
The first run read at 313 to 1159 MiB/s with several hundred workers
and 72% of every CPU's samples in `down_write`: the port's XOP start,
carried from the synchronous ports, serializes every XOP on an inode
through `hammer2_xop_testset_ipdep()`, so the workers queued on one
lock and spun while its holder was preempted. DragonFly serializes
only non-strategy XOPs and spreads strategy XOPs across its worker
groups by block, so the second run exempted strategy XOPs from the
dependency at start and retire, as DragonFly does, and bounded the
workers to the CPU count. It read at 2065 to 3246 MiB/s in three runs,
level with the synchronous path, with `xxh64` at 53% of all samples
and a spinlock at 13%, and the port's own check in
`hammer2_chain_drop()` fired once from a worker's retire: a data
chain reached its last drop while its lock was held. The inode's
chain cache in `hammer2_xop_retire()` assumes one XOP per inode at a
time, which the dependency guaranteed; concurrent retires replace and
drop each other's entries, the parent block is re-verified per data
block, and the drop race is the same assumption from the other side.
That reading of the cache was wrong, and the count that corrected it
was cheap: the retire code is DragonFly's line for line and runs under
the cluster spinlock. The debug kernel's function profiler, run on the
branch module, counted per 512 MiB read 8864 `read_folio` calls, one
per block, and 33588 chain allocations with 33587 checksum
verifications, four per block, against 8259 and 8258 on the
synchronous path. A kprobe on `hammer2_chain_alloc()` with a stack
trace put every one of them under `hammer2_chain_get()` from the
lookup in the strategy read: the chain is locked with its data, read
and verified, before the insert under its parent, and the insert is
checked against the parent's generation, which every sibling's insert
advances. DragonFly's own comment on that insert says get races occur
quite often when asynchronous read-aheads are spread across threads.
The chain is now locked without its data for the insert and resolved
once it is on the tree, which brought the verifications to 8292 per
read and the device reads from 39326 to 14793. The last-drop warning
turned out to be the guard's reading, not a defect: it read the
reference count and the lock word as two observations, and a lookup
that finds a chain on the tree takes its reference and then its lock
between them, so the guard printed an unlocked word beside a held
verdict. It now fires on the lock this task owns, which is exact, and
on a last drop that has spun a second on a lock nobody with a
reference holds, which is the stranded lock 39dc581 added it for. Two
runs on the debug kernel then read clean, one verification per block,
and four runs on the release kernel, MiB/s:

| run | read, 1 MiB | read, 64 KiB |
|---|---|---|
| 1 | 3747 | 5143 |
| 2 | 5368 | 5287 |
| 3 | 5267 | 4957 |
| 4 | 5194 | 5267 |

Zero kernel warnings, the reader at 0.035 s of CPU for the file, and
the profile a fifth `xxh64`, a seventh the copy, and a spinlock and an
rwsem at a tenth and a fourteenth, which is the next ceiling and is
named rather than measured. The change is on main; the branch is the
record of the shape that measured level with one reader before the
insert race was counted.

`O_DIRECT` stays unserved. DragonFly's `IO_DIRECT` means
semi-synchronous, set by the reserve check, and every read and write
there goes through the buffer cache because each block is checksummed
and possibly compressed on the way. The open flag is the one place the
two differ and it was read rather than assumed: DragonFly's direct open
is served from the buffer cache, while this port registers no
`->direct_IO`, so the kernel refuses the open itself with `EINVAL` at
`fs/open.c` (`FMODE_CAN_ODIRECT` is set only when the mapping carries the
operation) before any I/O is attempted. An earlier paragraph of
`doc/README.roadmap.md` said a direct open falls back to buffered I/O
here as it does there, which is true of the DragonFly half and false of
this one, and is corrected there.

### The write timed apart from its flush, on the release kernel

Every write number above is one figure, `dd conv=fsync`, which is the
page cache admitting the bytes, writeback allocating and writing them,
and the flush committing them, with no boundary between the three. On
2026-09-19 the instrument gained `H2_REPEAT=n` and times them apart:
a buffered write with no sync, then `syncfs` on its own, then the
combined figure every earlier row is. Each pass removes the file, drops
the guest's cache, draws a fresh 512 MiB from `/dev/urandom` and writes
it to all three filesystems, so a second pass cannot read as a dedup hit
or a warm overwrite. The first shape of the loop got both wrong: it
overwrote one file with the same bytes and sized the volume for one
pass, so the third pass hit the reserve, `dd` was refused, the empty
file read at the rate function's floor and the instrument printed 25600
MiB/s beside a hash of nothing; and its source buffer was drawn before
the cache drop, which tmpfs survives, so passes two and three of the
corrected run below admitted from a warm source on every filesystem.
The volume is `2 * REPEAT + 2` files now, a refused write is printed as
one and fails the run, and the source is drawn after the drop.

Release kernel, host load 4.3 at launch, `daecc89`, MiB/s except the
`syncfs` column in seconds. Pass 0 is the cold-source reading and the
one comparable to the rows above; passes 1 and 2 had a warm source:

| pass | | HAMMER2 | ext4 | btrfs |
|---|---|---|---|---|
| 0 | buffered write | 1280 | 883 | 1024 |
| 0 | `syncfs` | 0.88 | 2.17 | 1.03 |
| 0 | write with `fsync` | 966 | 272 | 441 |
| 1, 2 | buffered write | 5120, 5689 | 4267, 3938 | 4267, 4655 |
| 1, 2 | `syncfs` | 1.21, 1.18 | 1.64, 1.65 | 1.01, 1.02 |
| 1, 2 | write with `fsync` | 2048, 2133 | 371, 371 | 457, 457 |

The file read back with its source hash after a remount, no write was
refused, no kernel warning, both checkers clean with their controls,
DragonFly wrote its own file in 4 s and read the two at 801 and 658, and
the Linux-written file was contiguous at 6169 of 8191 steps, lower than
the 8185 above because two earlier copies had been removed on the same
volume before the pass that survived. The split says where the cost is:
the port admits the fastest of the three and flushes 512 MiB in 0.9 s
to ext4's 2.2 and btrfs's 1.0, so its combined figure leads by two to
four times, and on this workload the write path is not behind the
references. The one-bio-per-block synchronous submission in the DIO
layer, `submit_bio_wait()` with no plug where ext4 plugs the whole
`writepages` pass, iomap accumulates an ioend and btrfs a `bio_ctrl`,
is a real difference and this workload does not reach it: a 64 KiB
write to a host-cached virtio disk completes before batching would
matter. It will show on a device with queue latency, on many small
files and under concurrent writers, none of which this instrument
runs; `million-tree.sh` is the small-file reading.

The cold read is the other number that asked for an explanation, 5120
to 6400 here against ext4's 12800 and btrfs's 10240 on the same guest.
A raw read of the same 512 MiB region of `/dev/vdb`, no filesystem,
went at 533 MiB/s cold, so the guest's drop of its cache leaves the
image warm in the host's, and every "cold" read on this guest is the
host's memory: ext4 and btrfs copy it out with almost no per-byte work,
and the port adds the format's work, one xxh64 over every block and one
copy from the device mapping's folio into the file's. A system-wide
`perf` of the read put nine tenths of the samples in the readahead
workers, each worker's top symbols `xxh64` and `memcpy`, the reader
itself only `_copy_to_iter`, no lock at the top and no idle. Raising
the cluster hint from 4 to 16 and 64 moved nothing outside the run to
run spread, which at 0.08 s per read is the instrument's floor, not the
driver's. So the ceiling on this guest is twelve CPUs of portable-C
xxh64 plus one 64 KiB copy per block, about 6 GiB/s, and the one change
that would raise it is reading the device into the file's folio
directly and verifying there, as btrfs does, which removes the copy and
changes the DIO layer's ownership of data blocks. That is a design
change to size with a measurement first, not a knob. The release kernel
carries no tracefs, which is why every release-kernel row prints its
`read_folio` count as unavailable; the debug kernel is where that count
is read.

### The folio handed to the core, and what its safety costs

Measured 2026-09-19 on the release kernel, `6bcd011`, host load 5.13 at
launch against the run above's 4.29. The write XOP copied a whole 64 KiB
block out of the folio into a scratch buffer that every write XOP
allocated and zeroed up front, one of the two full-block copies per block
the section above names, and a sixth of a sync's samples. A folio that is
already the whole block needs none of that, so the block-aligned case now
hands the core `folio_address()` and the scratch buffer is allocated only
where a partial block is assembled.

That folio is not locked while the core reads it. `hammer2_writepages()`
calls `folio_start_writeback()` and then `folio_unlock()` before the XOP
runs, so with the copy removed a concurrent `write(2)` to the same offset
could change the bytes between the check code being computed over them and
their copy into the device buffer, and the block would fail verification
on a later read. `mapping_set_stable_writes()` on regular files closes
that window: `write_begin_get_folio()` passes `FGP_WRITEBEGIN`, which
carries `FGP_STABLE`, and `hammer2_page_mkwrite()` tails into
`filemap_page_mkwrite()`, so both write paths reach `folio_wait_stable()`,
which waits on the folio's writeback only when the flag is set. The flag
is a correctness requirement of the no-copy path, not a tuning knob, and
its cost is part of the change rather than separable from it.

MiB/s except the `syncfs` rows in seconds, against the `daecc89` run
above. The two runs were taken at different host loads, so the control
filesystems are given beside the port:

| pass | | `daecc89` | `6bcd011` | ext4 then, now | btrfs then, now |
|---|---|---|---|---|---|
| 0 | buffered write | 1280 | 914 | 883, 806 | 1024, 1024 |
| 0 | `syncfs` | 0.88 | 2.15 | 2.17, 1.78 | 1.03, 1.04 |
| 0 | write with `fsync` | 966 | 966 | 272, 344 | 441, 332 |
| 1 | write with `fsync` | 2048 | 2327 | 371, 423 | 457, 457 |
| 2 | write with `fsync` | 2133 | 2327 | 371, 434 | 457, 441 |

The cold-source pass, the only one the section above treats as
comparable, is unchanged at 966 MiB/s. The warm passes gained about a
tenth. The reading that asks for an explanation is pass 0's `syncfs`,
0.88 s to 2.15: the controls moved by a tenth to a fifth under the higher
load and in both directions, which does not account for a rise of that
size, so part of it is the stable-writes wait and how much is not
established here. One pass on a loaded host is too thin to attribute,
and the honest statement is that the copy is gone, the combined figure
did not move on the comparable pass, and the flush got slower by an
amount this run cannot separate from the machine.

The file read back with its source hash after a remount, no kernel
warning, `rmmod` clean, both checkers clean with their negative controls
on both the Linux-written and the DragonFly-written image, and DragonFly
6.4 mounted the volume and read the Linux-written file at 681 MiB/s
beside its own at 828. Allocation order is undisturbed: 8192 data blocks
in 6213 contiguous steps against the earlier run's 6169, still ahead of
DragonFly's own 1468 on the same volume. The full-volume fill passed on
this build as root and as a user, 463 and 458 files intact with no
damage and no warning.

### The flush with several writers at once

Measured 2026-09-19 on the release kernel, `eebb2db`, host load 2.64 at
launch. The reading above is one writer, and one writer rarely makes the
kernel wait: the stable-writes flag added by the no-copy path only costs
anything when a second writer arrives at a folio the core is hashing, so
the single-writer flush said nothing about its price under contention.
`throughput.sh` gained `H2_TP_WRITERS=n`, which splits the same total
between n writers at once, each on its own random source and its own
file, and times admission, `syncfs` and write-with-`fsync` for all three
filesystems the same way.

Four writers, 512 MiB split four ways, seconds for `syncfs` and MiB/s for
the combined write, three passes each, with the one-writer control from
the same instrument beneath:

| writers | | HAMMER2 | ext4 | btrfs |
|---|---|---|---|---|
| 4 | `syncfs` | 1.46, 1.14, 1.18 | 1.03, 1.05, 1.05 | 1.02, 1.07, 1.04 |
| 4 | write with `fsync` | 2048, 3413, 3012 | 465, 457, 465 | 470, 470, 236 |
| 1 | `syncfs` | 1.14, 1.13, 1.12 | 1.76, 1.98, 2.04 | 0.84, 0.99, 1.01 |
| 1 | write with `fsync` | 1089, 2133, 2438 | 247, 423, 438 | 465, 465, 457 |

The flush is the one column where the port is behind, and by how much is
what the control settles. Four writers put the port's `syncfs` at 1.14 to
1.46 s against ext4's 1.03 to 1.05 and btrfs's 1.02 to 1.07, so it trails
the references by a tenth to four tenths of a second on a 512 MiB flush,
while its combined write stays four to seven times theirs, 2048 to 3413
against 465 and 470. No writer was refused, all four files hashed back to
their own sources after the remount, and DragonFly read every one of them
at 520 to 1022 MiB/s. Allocation under four writers runs 1208 to 1466
contiguous steps of 2047 per file against 6271 of 8191 with one writer,
which is four allocators interleaving and not a regression.

Whether that tenth to four tenths is the no-copy path's or the
machine's is what a control settles, and the control says the machine's.
Two runs of the same instrument at four writers and two passes each, the
build before the no-copy change (`a0bb998`) at host load 21.11 and this
one (`3fff7f1`) at 17.14, so the pair is close enough in load to compare:

| build | | HAMMER2 | ext4 | btrfs |
|---|---|---|---|---|
| `a0bb998` | `syncfs` | 1.06, 1.26 | 1.92, 1.92 | 1.28, 1.12 |
| `3fff7f1` | `syncfs` | 1.47, 1.20 | 1.13, 2.24 | 1.12, 1.96 |
| `a0bb998` | write with `fsync` | 1600, 2438 | 453, 330 | 351, 449 |
| `3fff7f1` | write with `fsync` | 883, 2226 | 430, 361 | 397, 427 |

Every range overlaps, on the port and on both references, so the two
builds are not distinguishable on this instrument at four writers and
the difference from the references above is within what the host does
run to run. The single-writer rise the section above recorded, 0.88 s to
2.15 s, does not reproduce at four writers on a matched pair: the flag's
cost is not visible here at all. What would settle it is a pair taken on
a quiet host with more passes, since two passes at load 17 to 21 is a
thin comparison and this instrument's own run-to-run spread is the size
of the effect being looked for. That reading has not been taken and is
not claimed.

### What the no-copy build still does, measured on it

The question the numbers above leave open is whether the write path they
measure still writes correctly, so the build carrying the no-copy change
and the stable-writes flag was put through the gates that exercise it
rather than only the ones that time it. On `d4e5702`, the release kernel
for the rates and the debug kernel for the defect gates:

- the full-volume fill as root, 472 of 472 files intact, 0 damaged, 0
  kernel warnings, `rmmod` clean, exit 0;
- the same fill as a user, 453 of 453 intact, 0 damaged, 0 warnings,
  `rmmod` clean, exit 0;
- 13 repository and syntax gates green, checkpatch unchanged at 1140
  hits against the v7.3-rc1 baseline, syntax 65 checks 0 failed under
  clang, gcc and sparse;
- the throughput run's own checks on every pass: the file read back with
  its source hash after a remount, the host checker clean on the
  Linux-written and the DragonFly-written image with its negative
  control, `rmmod` exit 0, kernel warnings 0;
- DragonFly 6.4 mounted the volume and read every file this build wrote,
  one writer and four, which is the compatibility reading: the change
  alters what bytes the write path hands the core, and the other
  implementation still decodes them.

No defect was found in the no-copy path. It carries one measured cost,
the flush under four writers at a tenth to four tenths of a second
against the references, which the control above could not separate from
the host's own spread, and one real gain, one of two full-block copies
per block removed together with a per-XOP 64 KiB allocation. The gate
that found every write-path defect this port has had is
`test-enospc.sh`; it found none here, on either variant.

### The tail a truncate zeroes, which the guard did not reach

Found 2026-09-20, by reading rather than by a failing run, and fixed the
same day. Handing the core a whole-block folio instead of a copy puts the
folio's bytes in the core's hands while the folio is under writeback and
unlocked, and `mapping_set_stable_writes()` closes that window for the
writers that go through `write_begin()` and the write fault. It does not
close it for a writer that reaches a folio another way, and one does:
`hammer2_zero_tail()`, which a size change calls before it takes
`ip->lock`, reads the folio with `read_mapping_folio()`. That lands in
`do_read_cache_folio()`, which passes no `FGP_STABLE`, so the zeroing
that follows took the folio lock without waiting for the writeback the
core was in the middle of.

What that costs is worse than a torn block. A block whose bytes a
truncate changed while the core was reading it is copied to the media and
its check code is computed over the same bytes, so the mix verifies and
reads back as data the writer never wrote. The dedup probe is the sharper
one: the core compares the folio against a candidate block with `bcmp()`
and points the file at that block when they match, so a folio changing
under the compare can match a block it does not equal, and the file then
reads another block's content. Neither is reported by any check.

The fix is one call. `hammer2_zero_tail()` waits with
`folio_wait_stable()` after it takes the folio lock and before it zeroes,
which is the same wait the write paths already reach and needs no new
flag. Under the lock no writer can start while the wait runs, and the
zeroing then lands on a folio nobody is reading. Measured on the fix:
the full-volume fill 468 of 468 files intact as root and 459 of 459 as a
user, 0 damaged, 0 kernel warnings, `rmmod` clean, exit 0 on both; syntax
65 checks 0 failed under clang, gcc and sparse; checkpatch unchanged at
1140.

The first instrument written to catch this could not, and that is part
of the finding. It raced two writers over one block and checked that the
block read back as one writer's state or the other's, and against a
build with the guard deliberately removed, where the defect is
reachable, it reported 0 torn in 40 rounds. Media cannot show this
defect: the racing folio stays dirty and is written again after the
race, so what a later read sees is consistent whatever happened during
the core's read. A control that cannot fail on the build carrying the
defect proves nothing, and it was not committed.

What found it first was reading every place the port modifies a folio,
which is two: the truncate tail above, and the read path's own zeroing
of a folio the core has locked for its own decode, which is safe because
the core holds the lock across it. What confirms it is a counter, since
reading can find a defect and only a measurement can show whether it is
live.

### The counter that shows the window is real

Measured 2026-09-20 on `6a1a625` and on the same tree with the guard
removed, both on the debug kernel. The write XOP samples every folio it
reads with XXH64 immediately before and immediately after, and
increments a read-only module parameter on any difference. Both places
a file folio is read are sampled: the whole-block branch, where the core
reads the folio's own address, and the assemble branch, where the copy
out of the folio is what reads it while the folio is unlocked.

The trigger is in `test/hammer2-mmap-exercise.c`, in the harness the
other gates already build. It opens eight files, maps each shared and
writable, and stores through the mappings in a loop with no bound while
the parent drives writeback over the same ranges with
`sync_file_range(SYNC_FILE_RANGE_WRITE)`, which starts writeback and
does not wait for it. That is the writer that reaches a folio the core
may be reading; `write(2)` cannot, because `generic_file_write_iter()`
holds `i_rwsem` exclusively and a second writer waits. Earlier shapes
of the trigger read zero, and one of the explanations this record gave
for that was wrong. It said a write fault reaches only the assemble
branch, because the folio a fault creates is page-sized. That is false:
`hammer2_mapping_set_block_folios()` has given every file mapping a
minimum folio order of `HAMMER2_PBUFRADIX` since 0.4.9 (`118d787`), so
the page cache hands a fault a 64 KiB folio and the write entry
allocates the block folio itself with the mapping's retrying mask, which
is the whole-block branch. An earlier zero is real for a reason the code
shows: writers run to completion and writeback starts after, so the two
never overlap. Whether the window is reachable from the assemble branch
is not measured here, and that branch takes an order-4 grab failing,
which needs memory pressure this harness does not create.

| build | rounds | `folio_changed` |
|---|---|---|
| guard removed | 20000 | 14160919 |
| guard present | 20000 | 0 |

Fourteen million blocks changed while the core was reading them on the
build without the stable-writes marking, and none on the build with it.
That is the placement control the earlier instrument could not give: the
defect is real, it is reachable from a mapped writer, and
`mapping_set_stable_writes()` is what prevents it. The counter is
read-only and hashes twice per block, so it is the debug kernel's
reading, which is where the gates that read it run; a release build
prints it as unavailable, which is not a pass.

### The io hash lock, measured before it is changed

The io layer's lock is the FreeBSD port's arrangement rather than
DragonFly's: that port replaced DragonFly's lockless `INPROG` state
machine with a per-dio mutex and one lock for the whole device, and this
port carries what that port wrote. DragonFly locks nothing here, its
lookup taking a bucket spin shared and refs staying in a word the last
drop flips.

An added lock is worth a number before it is worth a change. Measured
2026-09-20 with `throughput.sh` at four writers, the debug kernel, the
same run that read `folio_changed 0` and hashed every file back to its
source: `iohash_waits 45736,1776264`, that is 45736 acquisitions that
had to wait out of 1776264, 2.6 percent. The script prints the pair, so
a later run reports the share rather than a count, and a share worth
acting on is what would justify departing from an arrangement three
ports share rather than assuming one. The `second umount` and `rmmod`
exits were 0 in this run, where the first carried both at 32 and 1 from
the race trigger leaving its files and its working directory behind;
that defect and its fix are in the commit that reported the pair.

The same pair run through `throughput.sh` at four writers, which is the
load the flag was added for and the only one where a second writer
arrives at a folio the core holds: 20000 rounds over the eight files,
`mmap race exit 0`, `hammer2 folio_changed 0`, and the script's own
verdict `ok no block changed under the core with 4 writers`, with all
four files hashing back to their sources and the run exiting 0. That is
the reading the single-writer control cannot give, and it is the one the
script prints, so a later run that reopens the window fails on the
counter rather than on a reader noticing.

## Mapped files, and the volume as a root filesystem

Measured 2026-09-05. `/bin/true` copied onto a HAMMER2 volume compared
identical with `cmp`, its md5 matched the source hot and after
`drop_caches`, and it would not run: the shell reported `cannot execute
binary file`, exit 126, while the same file copied off the volume onto
tmpfs ran. The bytes were right and the file could not be executed.

The cause was that `hammer2_file_fops` had no mapping operation at all.
The ELF loader maps the segments it is handed, that mapping is what
failed, and the failure reaches userland as `ENOEXEC` on a binary whose
contents are correct. Nothing in the tree had mapped a file, so nothing
had found it. `.mmap_prepare` is `generic_file_mmap_prepare()`, which
wants `->read_folio` and installs `generic_file_vm_ops`. That is what
`ext2`, `fat`, `jfs` and `hpfs` set unchanged. `ext4` and `xfs` do not:
both wrap it to install a `->page_mkwrite` of their own, which reserves
space while the faulting thread can still be told the answer, and the
paragraph below on a full volume is what this port does instead.

Shared libraries were the same defect, and are measured rather than
inferred: with the hook in place, `ld-linux-x86-64.so.2` copied onto a
volume, given `--library-path` into that volume and asked to run a
dynamically linked `ls` from it, exits 0 with every library mapped off
HAMMER2.

With it in place the same binary runs from the volume. A 128 KiB file,
two of this port's 64 KiB folios, was written entirely through a shared
writable mapping and `msync`ed: after `drop_caches` the media holds `A`
at the first byte and `B` at the last, the file is 131072 bytes, and the
checksum is the same after a fresh read-only mount. `debug_locks` stayed
1 and the log carried no report.

The volume then booted as a root filesystem, under qemu at 7.3.0-rc1
with a static init in an initramfs that loads the module, reads `root=`
from the kernel command line, mounts `/dev/vda@ROOT`, moves the mount
over `/` and executes `/sbin/init` from it. Every stage reported in
turn: the mount, the switch, and then PID 1 running off HAMMER2, which
wrote a file, `fsync`ed and `sync`ed it, read it back, and remounted the
root read-only through the transition above before powering the machine
off. The host's `fsck_hammer2` exited 0 on the image afterwards.

That is one boot of a single-purpose root, not a distribution. The
loader above was run off the volume, so that clause of this caveat was
false as first written and is corrected here; what has not run is a
service manager, a package manager, or a system built through
`ld.so.cache` rather than an explicit `--library-path`. Nothing here has
brought up a service, installed a package, or resolved a library through
the loader's cache from this filesystem.

## The remount from read-only to read-write

Measured 2026-09-05 on `artix-s6-kde` at 7.3.0-rc1 with
`CONFIG_PROVE_LOCKING`, on the 8 GiB volume this port formatted.

Mounted `-o ro`, a write is refused with `EROFS`. `mount -o remount,rw`
exits 0, `/proc/mounts` reads `rw`, and a file written and synced reads
back. `mount -o remount,ro` exits 0, the mount reads `ro` and a write is
refused again. A second `remount,rw` appends to the same file. After
`umount` and a fresh read-only mount the file holds both writes.
`debug_locks` read 1, the log carried no report, and the host's
`fsck_hammer2` exited 0 on the image afterwards.

The negative control is the same image attached write-protected, where
`/sys/block/vdb/ro` reads 1. There `mount -o remount,rw` fails, the
mount stays `ro`, and the log names the refusal: `read-write remount
refused 30`. That is the guard firing where the code executes rather
than a mount that happened not to write.

Upstream's `hammer2_remount_impl()` is carried without its two loops
over the device vnodes. Those take and drop a write reference, and
there is none here: the block device file is opened once at mount and
never reopened. That is what every filesystem in the tree does,
`sb_open_mode()` appearing in four of them and in each case at mount,
and it is also the only thing possible, since that macro always sets
`BLK_OPEN_RESTRICT_WRITES`, which leaves `bd_writers` negative and makes
`bdev_may_open()` refuse a second open asking for `BLK_OPEN_WRITE`. The
module's writes go out as its own bios, which do not consult the file's
`f_mode`; what stops them is the device being write-protected. So
`hammer2_access_devvp()`, which had been carried with no caller since
the import, asks `bdev_read_only()` on Linux, which is the question
ext4 asks in the same place, and the remount is its first caller.

`hmp->rdonly` is device-wide and is cleared once, on the first PFS to go
read-write; `pmp->rdonly` is per-mount. The read-write to read-only
direction syncs the PFS and sets its own flag only, so a sibling PFS on
the same device that is still read-write is unaffected. Upstream cannot
release the device's write reference when the last read-write PFS goes
back and carries an `XXX` saying so; there is nothing to release here,
and the device stays writable while it is mounted.

The recovery runs under `s_umount`, which `reconfigure_super()` holds.
`hammer2_recovery()` and `hammer2_fixup_pfses()` walk and flush chains
and reach nothing that takes that lock again.

## The ioctls, and a snapshot read back on DragonFly

Measured 2026-09-05 on `artix-s6-kde` at 7.3.0-rc1 with
`CONFIG_PROVE_LOCKING`, against the shipped module and Kusumi's
`hammer2` utility, on an 8 GiB volume this port formatted and wrote.

`pfs-list` prints the super-root scan; `snapshot` created `SNAP1` and
`pfs-create` created `NEWPFS`, both appearing in the next listing;
`pfs-clid` returned the snapshot's cluster id; `stat` reported the
inode's compression as `lz4:default` and its check as `xxhash64`;
`volume-list` reported version 2 and one 8.00 GB volume. `SNAP1` then
mounted read-only as a filesystem of its own and read `one` from the
file. The live PFS was changed to `two` and synced, `SNAP1` mounted
again, and it still read `one`, which is the property a snapshot is for.
`pfs-delete` removed both `NEWPFS` and `SNAP1`. `debug_locks` read 1
afterwards, the log carried no report, and `rmmod` returned 0.

The refusals were measured the same way. An unprivileged caller under
`setpriv --reuid=65534` was refused `pfs-list` and `snapshot` with
`EPERM`, the three read-only commands the entry point allows being the
exception. An unrecognized command number under HAMMER2's own type
letter and a command belonging to another driver both returned `ENOTTY`.

That second one is a port decision rather than a carry. HAMMER2's
dispatch answers an unknown command with `EOPNOTSUPP`, which a BSD's
ioctl layer turns into `ENOTTY` before userland sees it; nothing does
that on Linux, so the driver reported "Operation not supported" where
every other Linux driver reports "Inappropriate ioctl for device". The
default arm returns `ENOTTY` here, marked `XXX Linux`, and the
deliberate refusals above it stay `EOPNOTSUPP`. It was the ioctl
exerciser in the fixture gate that found it, not the hand run above,
which had read the number and not questioned it.

The gate covers the read-only half on every fixture:
`test/hammer2-ioctl-exercise.c` issues ten calls per image as root and
under `setpriv`, a hundred over the set, and compares each result
against a recorded value. The writing commands need a writable mount,
which the fixtures are not, so snapshot creation, PFS create and delete,
growfs and bulkfree are the hand run above and nothing else.

One thing testers hit immediately: `hammer2 pfs-delete LABEL` without
`-s <mount>` reports the PFS as not found however it exists. The utility
routes by mount through `libfs`, whose Linux `get_mnt_info()` returns an
empty list, so the lookup never runs.
`doc/upstream/libfs-linux-get_mnt_info.md` is the report against it,
drafted and unfiled; its standing section records the stub still at
upstream's head on 2026-09-06 and that the repository takes no issues.

## Space a remove does not free, and the two passes that do

Writing the capability declaration (`README.capabilities.md`) found
one row with no measurement behind it: on HAMMER2 a remove frees
nothing, the freemap being rebuilt by the bulkfree scan the ioctl
runs, and no run on Linux had ever asked for that scan. The ioctl was
carried from the FreeBSD port with the rest of `hammer2_ioctl.c` and
answered; whether the pass behind it did anything here was unknown.
`script/bulkfree.sh` asks. Measured 2026-09-06 on `artix-s6-kde` at
7.3.0-rc1 with lockdep, on a 2G volume this port formatted, 800
one-megabyte random files written, synced, removed and synced; the
free count is `statfs`'s in 64 KiB blocks, the transitions are the
kernel's own pass statistics in the freemap's 16 KiB units:

| step | blocks free | the pass said |
|---|---|---|
| at mount | 30592 | |
| after the set was written | 17574 | |
| after the set was removed | 17558 | |
| after the first pass | 17558 | 52134 allocated to staged, 0 freed |
| after the second pass | 30591 | 52134 staged to free, 0 staged |
| after the set was written again | 17574 | |

Both passes ran in under a second over 100% of the volume. One pass
alone reads as nothing freed, which is what the script's first run
reported before DragonFly's single pass over the same volume freed the
800 MB: that pass was the second, and the manual says in one line that
it takes two. The two-pass design is
what lets a pass run beside writers without a transaction, a block
freed in error by one pass being caught staged rather than reused.
The remove leaving the count where it was is the run's control: had
the count moved at the remove, the pass would not have been what was
measured. Both checkers were clean after each side.

## The folio the page cache can hold, asked at mount

The DIO layer hands the core one 64 KiB folio per buffer, so a kernel
whose page cache cannot hold one cannot mount this filesystem.
`hammer2_open_devvp()` asks `mapping_max_folio_size_supported()` before
`set_blocksize()`, which is the call `pagemap.h` names for a filesystem
with a folio-size requirement, and refuses with both numbers rather than
the bare `EINVAL` `set_blocksize()` returns. The `static_assert` on
`BLK_MAX_BLOCK_SIZE` in `hammer2_io.c` stays as the build-time guard for
a kernel without `CONFIG_TRANSPARENT_HUGEPAGE`.

The control is `make HAMMER2_FOLIO_CONTROL=1`, a module that asks for
twice what the kernel offers and so must refuse every mount. On
`artix-s6-kde` at 7.3.0-rc1 with THP `always`, the normal module mounts
`f7` and reads it; the control fails the mount with `EOPNOTSUPP` and
`dmesg` carries:

    hammer2: hammer2_open_devvp: this kernel caches at most 2097152 bytes in one folio and HAMMER2 needs 4194304: mount refused

That closes 0.3's third criterion, and with it the milestone.

## Two port decisions in carried files, as taken at 0.2

`hammer2_chain.c` landed on 2026-08-26 and the lock recursion it forced
was decided twice. The first decision followed the NetBSD port: no
recursive lock, `hammer2_mtx_init_recurse()` a plain init, the one path
that recursed to be closed at its call site. Every read agreed, because
the reading side of that path arrives with `HAMMER2_RESOLVE_LOCKAGAIN`
and is credited rather than re-acquired. The first buffered write did
not: `hammer2_chain_lookup()` under `hammer2_assign_physical()` returns
the inode chain itself, locked a second time and exclusively, for an
inode in DIRECTDATA mode, and the writeback worker deadlocked against
itself with lockdep naming the line. The shim now follows the FreeBSD
port, whose `SX_RECURSE` on those two locks is DragonFly's counted
exclusive recursion, and the paragraph in `doc/README.porting.md`
records both decisions and the measurement between them.

`hammer2_flush.c` landed on 2026-08-26 and took the port decision it needed
rather than a shim. Its OS-dependent surface is one function,
`hammer2_xop_inode_flush`, and everything else in the file is chain logic
that carried unchanged. Three edits, each marked `XXX` in place:

The device cache flush. DragonFly hands a zero-length `BUF_CMD_FLUSH` buf to
`vn_strategy()`, FreeBSD allocates a GEOM bio carrying `BIO_FLUSH`, and
NetBSD and OpenBSD both collapse it to one `VOP_IOCTL(DIOCCACHESYNC)`.
Linux has that single call, `blkdev_issue_flush()`, so this follows the two
ports that agree rather than the one this tree otherwise carries.

The per-device `VOP_FSYNC`, which writes back a device vnode's dirty
buffers. Linux writes back a block device's dirty pages with
`sync_blockdev()`, which needs no lock from the caller, so the
`vn_lock`/`VOP_UNLOCK` pair around it went with it.

The volume header write. FreeBSD uses `getblk`/`bwrite` on the buffer
cache; this port keeps the device's pages in the DIO layer, so it goes
through `hammer2_io_bread` and `hammer2_io_bwrite` instead. The DIO layer
does not export the read-skipping form of `getblk`, so the block is read
before all 64 KiB of it is overwritten. The write is the same size either
way, and the path does not execute until the write milestone.


## The `XXX` marks walked by site

The table in `doc/README.status.md` is the count. The paragraphs below
walk the marks file by file as they stood when each was written, and
the counts in them are those dates', not the table's.

it is the only place in this file that adds up to the column. The count
is prose because `test-inventory.sh` checks the total column only; the
sentence before this one said seventy-eight in nine files while the
column summed to more, so the sum was recomputed from the table on
2026-09-04 and three times on 2026-09-05, the second time when the mark in
`hammer2_vnops.c` left with the read-write refusal it described and the
third when the sentence was found reading one hundred and forty-six
against a column summing to one hundred and fifty-three before the
debug trigger for `hpanic` added one more, and again when the unlock
before the drop in `hammer2_chain_create()` added another, and the
reserve check carried into the write path two more and the dirty
count it reads a third.

Four of those nine files are then walked mark by mark below:
`hammer2_ondisk.c`, `hammer2_vfsops.c`, and the two files this port wrote
from nothing taken together. Forty-three of the seventy-seven are in those
paragraphs. The other thirty-four are not enumerated anywhere and do not
need to be: `hammer2_inode.c`'s seventeen, `hammer2_subr.c`'s seven,
`hammer2_flush.c`'s five and `hammer2.h`'s four are one-line
substitutions in carried files, which is what the `XXX` mark is for and
what a reviewer reads at the mark rather than here, and
`hammer2_strategy.c`'s one is the block at its two floors, which the
`DEFER` ledger already carries a row for. **Do not read the
paragraphs below as a decomposition of the count.** They were read that
way once, and the sentence that invited it said "the three largest sets"
while skipping the second largest.

Sixty-four sit in a file that holds upstream text. The other nine are
the two files this port wrote from nothing: eight in `hammer2_os.h`, and
two of `hammer2_io.c`'s four.

`hammer2.h` has a row for the first time. It is a carried header this port
edits in place rather than a file it wrote, so its two marks are counted
where the other carried files' are.


`hammer2_flush.c`'s five are the three port decisions above and the two
local variables those decisions changed the type of, all inside one
function. `hammer2_subr.c`'s seven are the densest set in the tree and the
file is the smallest carried one, which is what a file of small
OS-touching helpers looks like: two are the `timespec64` signatures the
carried `hammer2.h` had already chosen, one is the include line, one the
timestamp call, one the signal check, one the pair of functions that are
not carried at all, and one the local variable the timestamp changed.

`hammer2_ondisk.c`'s eighteen are the port's largest set and split ten
to eight, counted mark by mark on 2026-08-26 and listed here so the
number can be checked rather than taken. Ten are on the device
side, which is the half this port wrote: the file's opening comment; in
`hammer2_open_devvp()`, the `g_vfs_open()` mapping and the logical-size
comparison; the `g_vfs_close()` mapping in `hammer2_close_devvp()`; in
`hammer2_init_devvp()`, the unused superblock argument, the `strlcpy`
rename, and the `namei()` mapping onto `lookup_bdev()`; the `vrele()`
mapping in `hammer2_cleanup_devvp()`; and in
`hammer2_access_devvp()`, the `VOP_ACCESS()` mapping and the trace
through `blk_to_file_flags()` and `OPEN_FMODE()` that replaced a `DEFER`
once `block/bdev.c` was read at the tag the kernel of record is pinned
to. The other eight are in the carried half, and
every one of them is a one-line substitution rather than a change of
logic: four in `hammer2_verify_volumes_common()` (the GEOM consumer local,
the media size read off the block device, the `devvp` field name, and the
uuid comparison the kernel has no formatter for), two signature lines in
`hammer2_init_volumes()`, the read call in `hammer2_read_volume_header()`,
and the formatter in `hammer2_print_uuid_mismatch()`. That is the property
worth checking: no carried function here had its control flow edited, and
a reviewer can confirm it one mark at a time.

The other nine are in the two files this port writes: two in
`hammer2_io.c` and seven in `hammer2_os.h`, one of them the non-recursive
lock above, one the `M_WAITOK` contract and one `hstrdup()`, which was
allocating outside that contract until the mount path dereferenced it.
The `hammer2_os.h` count read six until 2026-08-26, written before the
two shim edits `hammer2_inode.c` needed, and seven for the few hours
before `M_WAITOK` was fixed.

`hammer2_vfsops.c`'s sixteen, as the file stood on 2026-08-26, were the largest set in the tree after
`hammer2_ondisk.c`'s, and the file is the fastest-moving in it, so they
are listed by site rather than counted: the file's opening comment; the
`sysctl(9)` block that became module parameters; the two `hashinit(9)`
substitutions and the helper they name; the `hashdestroy(9)` mark; the
`__maybe_unused` rename; the `desiredvnodes` derivation in
`hammer2_init_limits()`; the mount options; four in `hammer2_get_tree()`
for the `"from"` option, the `MNAMELEN` buffer, the device match and the
`vfs_mountedon()` check Linux answers at the open; the `void` return of
`->kill_sb`; `uma_zcreate(9)` being infallible where
`kmem_cache_create()` is not; and `hammer2_reconfigure()` being the
read-write refusal alone rather than FreeBSD's `MNT_UPDATE` branch. The read to make against that list is that
none of them is inside a carried function: the four in
`hammer2_get_tree()` are in the Linux entry point, not in the PFS body
it will call. This paragraph read "five" from 2026-08-26 until the
device half landed the same day, having been written when the file held
seven marks and not revisited as it tripled, and then read "fourteen"
while enumerating fifteen sites.

The other seven are upstream's own: two inside `hammer2_pfsalloc()`,
four `hprintf` strings in `hammer2_unmount_helper()`, and the one on the
unhandled error from the recovery call, all of which upstream already
spells `XXX`. The opening comment makes a deliberately
weaker claim than `hammer2_ondisk.c`'s: statements carry there and the
control flow does not move, but here the function boundary itself moves,
because Linux redistributes FreeBSD's `hammer2_mount()` across
`->init_fs_context`, `->parse_param`, `->get_tree` and a fill-super, with
`MNT_UPDATE` splitting off to `->reconfigure`. Claiming the reviewability
property `hammer2_ondisk.c` has would be false here at four times the
size.

## The `DEFER` ledger as it stood at 0.2

Five of the seven lift with the read-side VFS entry, which is the next
move on the roadmap and is now partly made: `->lookup` and
`->iterate_shared` are written and none of these rows was one of them. The `enum vtype` row's trigger was re-checked when
`hammer2_inode.c` landed and was found to name a file rather than the
thing that fires it: the BSDs convert in `hammer2_vinit()`, in
`hammer2_vnops.c`, but they reach it from `hammer2_igetv()`, and on Linux
that is one call. The trigger now names the function, which is true
whichever file the replacement ends up in. The gate below matches marker
text and cannot check a trigger's truth, so that is checked by hand at
each import.

## Stale state claims, and which of them a gate can see

Corrected 2026-09-20 in the roadmap: eight claims that had stopped being
true, six of them in the fixture table and the paragraph above it. The
table's F3 row read `unwritten` against images committed on 2026-09-04.
Its F2 row carried an inode count belonging to a different image and said
the rest of the row needed a guest, where `f5`, `f7` and `f12` are
committed and the gate mounts them. Its F5 row pointed at
`README.status.md` for a crash-matrix table that had moved to this record,
and undercounted it as sixteen where the table has twenty, an error the
0.6 section repeated. The paragraph on guests said no instrument in this
repository drives one and concluded that every runtime criterion from 0.3
on is unverifiable here; it was written 2026-08-26, the first fleet script
landed 2026-09-04, and two of them are gates. The 0.5 section said the
fuzzing corpus is seeded from F3, which it never was. A day later the 1.0
row still read `not started` while the section beneath it recorded the
criteria of its own bar already read, and the decision table still said
`the two upstream filings` against a staging directory holding twelve
patches and two reports.

Every gate was green through all of it. That is not a gate defect and not
a gap one more gate closes. The gates check that a citation resolves to a
line, that a count matches the source, that a "not carried" claim names a
symbol `src/` does not define, and that the prose is clean. None of them
can check whether a stated cause or a stated state is TRUE, and a
sentence of the shape "X does not exist" carries no fact a matcher can
resolve when the subject is a script count, an image set, or a property
of the repository.

What does catch it, in the order it worked here:

- Reading the source or artifact the claim names. Every one of the six
  the fixture table carried fell to `ls`, `git ls-files` or a grep of the
  script the row said would do the work.
- A dated observation instead of a present-tense state. The CHANGELOG's
  rows and the porting notes' past-tense justifications are the same
  claims, correctly frozen: they say what was true on a day, so they
  cannot rot.
- Refusing to write a count that a later commit falsifies. Two of the
  corrections made here are phrased to name the mechanism that
  enumerates a set rather than the size of the set, because the first
  replacement written for F5 carried a new count that the next
  crash-matrix run would have made false.

The population of each mechanical shape was measured before deciding
against a gate: zero sentences now match "nothing under DIR verbs TOOL",
and the "unwritten" shape matches four sites that are all correct. A gate
over either would have nothing to match and would report clean having
read nothing, which is the failure this repository's gates are built to
refuse.

## Deduplication, which was on by default and never run

Measured 2026-09-25 on `artix-s6-kde` at 7.3.0-rc1.

`hammer2_dedup_enable` defaults to 1 and the write path asks
`hammer2_dedup_lookup()` before allocating every data block, so a second
copy of a block is meant to point at the first one's media. No run in this
tree had ever written a duplicate block, and the tree was arranged so that
none would: `script/throughput.sh` is the only script naming dedup, and it
draws fresh random data every pass precisely so a run cannot read as a dedup
hit. `README.md`'s opening paragraph names block-level deduplication among
the format's features, so the feature was advertised and unmeasured at once.

`test/hammer2-dedup.c` measures it black-box, on free blocks from `statfs`,
which is what a consumer would use and needs no debug hook. It writes one
file, syncs, reads the count, writes a second file holding the same bytes,
syncs, reads again, and compares what the two cost. On the gate's volume at
64 KiB blocks: file A cost 64 blocks for 64 blocks of data, and the
duplicate cost 2 blocks against it, so the block was shared rather than
allocated.

Two things keep that reading from being an artifact. The data is
pseudo-random rather than zeros, so the zero-elision in
`hammer2_write_file_core()` (a write of all zeros calls `zero_write()`,
which deletes the chain) cannot be what made the second file cheap. And the
control is a filesystem with no dedup, which every machine has two of:
`tmpfs` charges the duplicate its full 1024 blocks, and `btrfs` charges 1032
against the first file's 1024, so both fail the third check while this port
passes it. Without that control the difference would be consistent with
anything that makes a second write cheap.

The exerciser reads its unit out of `statfs` rather than assuming 64 KiB,
because `btrfs` reports 4 KiB and a test that can only run on this port
cannot be controlled by a filesystem that is not this port. The same
correction the seek exerciser needed.

## SEEK_DATA and SEEK_HOLE, and the block count that was not refreshed

Two reader-visible defects, measured 2026-09-20 on `artix-s6-kde` at
7.3.0-rc1.

**The seek whences.** `hammer2_file_fops` had no `->llseek` of its own and
took `generic_file_llseek`, which treats a whole file as data. So
`SEEK_HOLE` on a HAMMER2 file answered end-of-file wherever the hole
actually was, and `SEEK_DATA` inside a hole answered the offset it was
asked about. That is not a refusal, which is why nothing caught it: a
sparse file copied with `cp --sparse=always`, archived with `tar -S`, or
read by any backup tool that asks where the data is comes out dense and
looks correct. The whences are in `lseek(2)`, and the BSDs reach the same
question through `FIOSEEKDATA`/`FIOSEEKHOLE` on `vn_bmap_seekhole()`.
That description is true of FreeBSD only, which is what an earlier draft
of this paragraph said the other three did. Read at the clones:
DragonFly's ioctl answers `EOPNOTSUPP` with the `vn_bmap_seekhole()` call
`#if 0` and commented "doesn't work correctly yet", NetBSD's answers
`EOPNOTSUPP`, and OpenBSD's is `#if 0` as well. This port had neither
facility, and the mechanism was already carried: `hammer2_xop_bmap()`
reads exactly the `data_off` a seek needs, and had no caller.

`->llseek` and `->bmap` are now built on that XOP, which is upstream's
`hammer2_bmap_impl()` with the parts Linux needs. `test/hammer2-seek.c`
writes a file of one block of data, one block of hole, one block of data
and a truncate into a fourth, and asks at twelve offsets: ten that locate
data or a hole, and `SEEK_SET`/`SEEK_CUR`/`SEEK_END`, which reach the
same entry point and have to keep working. Run against a module built
with the old `generic_file_llseek`, six of them fail, `SEEK_HOLE` at 0
answering 229376 where the hole ends at 65536, `SEEK_DATA in hole`
answering the offset asked about, and `SEEK_DATA past end` returning a
position instead of `ENXIO`. Against the shipped module all twelve pass on
a live mount, `ok seek 12 check(s) on a live mount, 0 failed`, run by
`test-enospc.sh` on its read-write volume. It cannot run in the fixture
gate, which attaches every image read-only because the fixture is the
claim, and the exerciser has to write the file it asks about.

**The first run of that exerciser proved nothing, and the reason is the
finding.** Two checks passed on this port and failed on `tmpfs` and
`btrfs`, both answering `65636` where the test wanted `65536`. The
exerciser had been written from this implementation's answers rather than
from the contract, so it agreed with the bug. `SEEK_HOLE` is "the next
hole greater than or equal to offset", and `lseek(2)` says an offset
inside a hole is answered with that offset; returning the hole's start
answers *below* the offset asked, and a tool stepping on it moves
backwards. The second: at `i_size` both whences are `ENXIO`, which is what
`generic_file_llseek()` does, what `iomap_seek_hole()` and `iomap_seek_data()`
do, and what btrfs and tmpfs do. The port answered the offset for
`SEEK_HOLE` and the size for a scan that ran off the end while seeking
one. Both were fixed in the driver and both expectations were fixed in the
test, which then read 12 of 12 on `tmpfs` and `btrfs` as well, and those
two filesystems are what made the wrong expectation visible.

What made it invisible was placement: the exerciser only runs on a live
HAMMER2 mount, inside a gate that needs the guest fleet, so there was no
build to compare against when it was written. Two reference filesystems
the machine already had, `/tmp` on tmpfs and `/home` on btrfs, would have
answered in a second. That is the check to run first the next time a
kernel-facing expectation is written here.

Two defects in this work were found by the instruments rather than by
reading. The first: `hammer2_error_to_errno()` returns a POSITIVE errno,
which is this module's convention inside the core, and the first version
compared it against a negative one, so every offset in the file answered
`ENOENT` as a position. The second: the scan did not snap to block
boundaries, so an offset inside a block answered with the offset instead
of the block. Both showed as wrong numbers in a run, not as a build
failure.

**The block count.** `st_blocks` is how `du`, `cp --sparse` and every
backup tool decide what a file occupies, and it is filled from
`inode->i_blocks`. This port set it once, in `hammer2_igetv()`, and never
recomputed it, so a file that grew in the same mount kept reporting the
allocation it had when the inode was first read: a 512 KiB file written
in one mount read `blocks=0` where ext4 on the same guest read 1024, and
the same file read 1056 after a remount. Upstream has no such window,
because `hammer2_getattr()` computes `va_bytes` inside getattr and every
stat re-derives it. `->getattr` is registered on the three inode tables
and recomputes the count the same way, and the same file reports 1056 in
the live mount.

The first version of that fix registered it on two of the three. A
directory and a regular file were covered and `hammer2_symlink_iops` was
not, so a symlink whose target exceeds `HAMMER2_EMBEDDED_BYTES` and
therefore owns a data block still reported the count it was created with.
The creation path is what makes that reachable rather than theoretical:
`hammer2_igetv()` fills `i_blocks` from the inode as it stands, and for a
symlink that runs before `page_symlink()` writes the target, so the count
is taken from an empty inode and nothing revisited it. On the BSDs one
`vop_getattr` covers every vnode type through the mount's vop vector, so
there is no per-type table to miss. The record said "all three" while the
code had two; the code was corrected, not the sentence.

Both are the shape this record has already named: a wrong answer that
reads as a right one, in a path no checksum and no read test looks at.

## Per-operation latency, the half that was never measured

Measured 2026-09-26 on `artix-s6-kde` at 7.3.0-rc1, `script/latency.sh`
driving `test/hammer2-latency.c` at 1500 operations over a 1024 MiB file.

Every performance number this tree had was sequential: one large file, a
closure, a fill, bulkfree. Sequential throughput is where a
copy-on-write filesystem with 64 KiB blocks and a checksum per block is
expected to look good, and the cost of a random small read and of making
one write durable is the other half. The gap was not that the
measurement was hard; it is that no milestone's exit criteria ever asked
for it, so nothing in the process would have produced it. Every
instrument here answered "is the data correct", and correctness
instruments do not report cost.

All figures are microseconds. `randwrite4k_fsync` is one write and its
commit; `fsync_batch8` is eight writes and one commit, so its per-op
figure is not comparable to the other two and is not read that way. The
page cache is dropped before the read pass, on a file larger than the
guest's RAM.

| filesystem | randread4k min/p50/p99 | randwrite4k_fsync min/p50/p99 | fsync_batch8 min/p50/p99 |
|---|---|---|---|
| HAMMER2 | 41 / 49 / 185 | 201 / 384 / 6092 | 1164 / 1386 / 1933 |
| ext4 | 5 / 11 / 28 | 5241 / 7119 / 20262 | 8061 / 8732 / 14602 |
| btrfs | 17 / 23 / 48 | 6446 / 7824 / 15120 | 7717 / 9249 / 21281 |

Reads: HAMMER2 is 2 to 4 times slower than btrfs and about 4.5 times
slower than ext4 at the median, which is what a 64 KiB block read
through a DIO cache costs against a 4 KiB page-cache read. That is the
expected direction and the expected size.

Writes: HAMMER2 commits in 384 us where ext4 takes 7119 and btrfs 7824,
about 18 times faster. That number was checked rather than published,
because a durability barrier that fast is a smell. It is not a defect
here: `hammer2_dev_cache_flush()`, the `blkdev_issue_flush()` wrapper in
`hammer2_os.h`, has no callers, and neither does its counterpart in the
tree it is carried from. DragonFly's own `hammer2_vop_fsync()` flushes
the file's buffers and the inode's chains and issues no device cache
flush, and the FreeBSD port does the same. Durability on that design
comes from the device layer's ordering, not from a barrier in `fsync`,
so this port reproduces upstream's behavior. The number is a statement
about what `fsync` does on this filesystem, not evidence that a flush was
skipped here and performed elsewhere.

Two things about the instrument are worth recording, both found by its
own controls. The first version created the ext4 and btrfs control images
with `truncate` and never formatted them, so both mounts failed, the
exerciser wrote to the empty mount points as directories on the guest's
root filesystem, and the two "controls" reported 39139 and 39581 op/s
with the same 24 us median. They were one filesystem measured twice and
read as two agreeing. The images are now formatted and asserted with
`file -b`, the guest takes no reading unless `mountpoint -q` holds for
the path, and the host fails the run on a skipped pass. The host also
runs the binary on `tmpfs` first, where it must report cache speed and
fail its own check, so the check is known to be live before the guest's
numbers are believed.

## The kernel of record advanced to 7.3-rc4

The pin is the 7.3 line, the newest candidate while the release is a
candidate, and on 2026-09-26 it advanced from rc1 to rc4 in `ac93478`:
`script/pre-push-check.sh` searches `~/kernels/linux-7.3-rc4` first, CI
fetches the checker from the `v7.3-rc4` tag, and the baseline's name
line says rc4. `KERNEL_REF` in `test-syntax.sh` did not move, since it
pins the family and reads the exact version off the tree it is pointed
at. Two trees were built from the `linux-7.3-rc4` tarball, a debug tree
with lockdep, kmemleak, BTF and DWARF 5 and a release tree with
`DEBUG_INFO_NONE`, each configured from the rc1 tree of the same kind
through `olddefconfig`, and both installed in `artix-s6-kde` beside the
rc1 pair, which stay for a reading that has to be repeated on the build
it was taken on.

What was read on rc4 the same day, from a tree at `d72017d`:

    syntax: 65 check(s), 0 failed against the kernel of record (7.3), 7.3.0-rc4, mainline
    checkpatch: deviation set unchanged (1142 hits, baseline: checkpatch.pl from linux v7.3-rc4)
    fixtures: 11 image(s), 43 file(s), 43 block count(s), 34 stat row(s), 5 statfs, 2 symlink(s), 1 corrupt file(s) refused, 100 ioctl result(s), 0 failure(s)
    enospc: filled 2G, 0 failure(s)

Both fleet gates were driven with `KDIR=~/kernels/linux-7.3-rc4` and
`H2_FIXTURE_START=1` against the debug rc4 kernel, the module's vermagic
`7.3.0-rc4` matching the guest's release by the gate's own check, every
unmount reporting 0 inodes, 0 chains, 0 modified and 0 dio still
allocated, and 0 kernel warnings after the module loaded; the fill's
seek and dedup checks passed, 12 and 3. Before that run both gates had
been COULD-NOT-RUN on every push since the move, because the guest was
shut off and a pre-push run does not start it, so the move had been
verified by a hand mount and a 1 MiB round trip only.

The checkpatch count did not move because it could not: `checkpatch.pl`
at `v7.3-rc1` and at `v7.3-rc4` are the same file, `sha256`
`2553cc1a601e70522e03fbce633d4e79fa5936f7f56a66de1899b7ddd247820a` on
both, so the baseline's sha line is unchanged and the gate still
identifies the checker by content. The latency table above was taken on
rc1 and says so; it is not repeated here, since a reading names the
build it ran on and rc4 was timed later the same day, below.

**The latency reading repeated on rc4.** `script/latency.sh` at 1500
operations over a 1024 MiB file on the rc4 debug kernel, the same
instrument and arguments as the rc1 table, the `tmpfs` control failing
its own check at a 441 ns median first, every guest pass taken with
`mountpoint -q` holding, 0 kernel warnings, and `fsck_hammer2` clean on
the host after the run. Microseconds, min / p50 / p99:

| filesystem | randread4k | randwrite4k_fsync | fsync_batch8 |
|---|---|---|---|
| HAMMER2 | 40 / 47 / 177 | 178 / 346 / 5412 | 1164 / 1332 / 1829 |
| ext4 | 5 / 11 / 32 | 5422 / 6840 / 14625 | 7826 / 8546 / 14245 |
| btrfs | 18 / 24 / 55 | 6425 / 7762 / 14686 | 7372 / 9152 / 23376 |

Every median is within a tenth of its rc1 figure and the ordering is
the same, so the rc1 table stands as the reading of record and this one
is the confirmation that the kernel move did not move it. The `fsync`
figure is the same finding as above and is not re-argued.

## A path-sensitive reader, and what it found

`script/analyze.sh` runs clang's static analyzer over the six files this
port edits most, with the syntax gate's kernel flag set and the core,
unix and deadcode checkers, and a control that must report a planted
null dereference before any file is read. First run 2026-09-26 against
`4189e35` on the rc4 tree: 7 candidates over 6 files, and each was read
against the origin tree before a disposition.

| where | candidate | disposition |
|---|---|---|
| `hammer2_io.c`, `hammer2_dedup_mask()` | left shift by 64 | false: the `bbeg + bits == 64` case takes the all-ones branch two lines above and the analyzer does not carry the constraint through the subtraction; upstream's function verbatim |
| `hammer2_io.c`, `hammer2_io_getblk()` | `error = 0` never read | upstream's store, the same line in the FreeBSD file; carried |
| `hammer2_strategy.c`, zlib branch | `ret` from `deflateEnd` never read | upstream's store, `ret = deflateEnd()` in the FreeBSD file; carried, and the `XXX Linux` mark on the line is for the renamed call, not the store |
| `hammer2_vfsops.c`, `hammer2_recovery()` | `sync_tid = elm->sync_tid` never read | upstream's store, the loop passes `freemap_tid` instead; carried |
| `hammer2_vfsops.c`, inode sync | `error = 0` after the vnode flush failed | this port's `XXX`, deliberate: upstream's `vn_fsync_buf()` has no return to check and the flush continues, so the reset is what keeps the carried control flow; the message before it is the record |
| `hammer2_ondisk.c` through `hstrdup()` | null passed to `strlen` | false: the path reaches `hstrdup()` from `hmalloc()` with `M_WAITOK`, which is `__GFP_NOFAIL` and cannot return null, and `kstrdup()` itself returns null for a null argument before `strlen` would run; the analyzer cannot see the GFP contract |
| `hammer2_ioctl.c`, PFS create | `nipdata` never read | upstream's store; carried |
| `hammer2_freemap.c`, `hammer2_freemap_adjust()` | `chain->error` read through a null `chain` | reachable: the early return covers a missing leaf only when `how` is not `DORECOVER`, and the recovery case falls through to the dereference; DragonFly and the three ports are identical there, and it needs a recovery pass over a leaf the volume does not hold, which is a damaged freemap; read on the second run, after the two sanitizer fixes below moved the file, and left as a staged-patch candidate rather than edited here; applied 2026-09-27, since the maintenance document's rule for a carried defect is to fix it here first and mark it `XXX` so the port does not wait on anyone, and the staging was the delay rather than a decision to leave it out; confirmed by the instrument that found it, `script/analyze.sh` over the file reporting 0 candidates with its planted-null control firing against 1 before the edit, and the syntax gate at 65 checks 0 failed. The reach condition was measured, not assumed: `script/cut-flush.sh` does run the freemap replay and the guest prints `hammer2_recovery: freemap recovery`, so no damaged volume is needed to reach the function, but reverting the guard and re-running it passes at 0 failures and no report, so that run cannot control this fix and the null branch is not what those images produce. The fix rests on the analyzer, which does exercise the path. The fleet readings on the applied fix, `test-enospc.sh` on the debug kernel: filled 2G, 0 failures, 465 of 465 files intact and 0 damaged, `cycles 0`, `lockdebug lines 0`, lockdep across every mount and unmount, `umount 0`, `rmmod 0`, no sanitizer report, the seek and dedup exercisers at 12 and 3 checks 0 failed; `test-fixtures.sh` 11 images 43 files 100 ioctl results 0 failures. Those say the applied guard does not disturb a recovery that was working, which is the whole of what a run can establish here |

Seven of the eight needed no change, each counted once from the
dispositions above: four are upstream's dead stores that a carried file
keeps, one is this port's own marked choice, and two are the analyzer
missing a constraint it cannot see. The eighth was a real defect in
carried code and is applied here as of 2026-09-27, marked `XXX`. The
first run's seven candidates were all non-defects; the second run added
the eighth, which was real, so the negative the first run read did not
hold until it was fixed. With it applied, the full run over the port's
files reports the same seven triaged non-defects and no new candidate,
and `hammer2_freemap.c` reports none at all, where the run before the
edit reported this one on that file. The negative that stands is
therefore the narrow one the control supports: the port's own six files
hold no null dereference, no use of an uninitialized value, no double
free and no leaked allocation along any path the analyzer can enumerate,
which two compilers and sparse do not ask.

## The sanitizer kernel, and what three weeks of green had not seen

The first fleet run on `7.3.0-rc4-kasan`, 2026-09-26 against `ca14d91`,
failed both gates, and neither failure was the port's Linux half.

**A read past a slab object in the volume list ioctl.** KASAN, on the
first fixture that carries a `volume-list` result:

    BUG: KASAN: slab-out-of-bounds in hammer2_ioctl_impl+0x1f39/0x4e08 [hammer2]
    Read of size 64 at addr ffff88811f767f40 by task h2ioctl/1146
    Allocated by task 1139: kstrdup ... hammer2_init_devvp ... hammer2_get_tree
    The buggy address is located 0 bytes inside of allocated 9-byte region

`addr2line` on the module puts the offset at `hammer2_ioctl_volume_list2()`,
`bcopy(vol->dev->path, entry->path, sizeof(entry->path))`: 64 bytes read
from the 9-byte `/dev/vdb`. The version-1 list does the same with 1024,
and both copy `pfs_names[0]` at 256 into `pfs_name`. All four are
upstream's, byte-identical in DragonFly and the three ports at their
heads today, and every one of the 100 ioctl results this gate had
reported since 2026-09-05 was taken with the read in it, because a read
past a slab object returns bytes, and neither lockdep nor kmemleak
watches a read. Fixed here with `strscpy_pad()`, marked `XXX`, and
staged upstream as `strlcpy()` in two patches.

**A pointer formed past the freemap array.** UBSAN, three times in the
first file the fill created, before the fixture run reached the ioctl:

    UBSAN: array-index-out-of-bounds in hammer2_freemap.c:401:31
    index -1 is out of range for type 'hammer2_bmap_data_t [256]'

`hammer2_freemap_try_alloc()` forms `&bmdata[n]` before testing `n`
against the array in both scan directions. The pointer is never
dereferenced when out of range, which the comment beside it says, so
nothing reads bad memory; forming it is still undefined and the
sanitizer is right to say so. Same four trees, same two lines. Fixed
here by forming the pointer inside the test, marked `XXX`, and staged
upstream the same way.

**What the gate did with the first report.** UBSAN's epilogue counts a
warning and KASAN's taints with `LOCKDEP_NOW_UNRELIABLE`, so lockdep
turned itself off and `test-fixtures.sh` failed on that, then printed
nothing, because the report it looks for is lockdep's own two forms.
The gate now prints a KASAN or UBSAN report beside them, which is the
row added to the testing guide's control table.

On the module with both fixes, the same kernel: fixtures 11 images, 43
files, 100 ioctl results, 0 failures, lockdep on throughout, 0 `cut
here` in a kernel log streamed to the host for the whole run.

**The fill gate on the same kernel did not finish.** It wrote 438 of
the files a 2 GiB fill takes, the volume at 98 percent, and then one
`dd` sat in D state for the rest of the hour with 0 sanitizer reports,
`debug_locks` 1, and the hung-task detector naming it at 122, 245 and
368 seconds. The `sysrq` lock dump is a cycle lockdep cannot see,
because one side of it is a folio lock, which is a page bit and not a
lockdep class:

    dd/2527          holds i_rwsem and a folio lock (write_end),
                     waits on h2ip/2 in hammer2_mtx_ex_nested
    kworker/2:0/35   hammer2_sync_work -> hammer2_vfs_sync_pmp
                     holds h2ip/2, waits in folio_wait_bit_common
                     under writeback_iter, for that folio

`hammer2_write_end()` extends the file under the folio lock and takes
`ip->lock` to do it, the order the read path already uses. The sync
loop took `ip->lock` and then called `filemap_write_and_wait()` on the
inode's mapping, which walks every dirty folio and waits for a locked
one. DragonFly's loop holds the same lock across `vfsync()` and is
safe there, because its vnode lock serializes the writer before any
buffer is touched; here the writer's `i_rwsem` is taken by
`generic_file_write_iter()` and the sync loop never takes it, so the
serialization that makes upstream's order safe is absent. The line the
loop takes the lock on already carried `XXX2 DragonFly takes inode lock
before vget` as the place the two trees differ.

Twenty-odd fills on the debug kernel never reached this and three
weeks of the fill gate read green. The sanitizer kernel is about twice
as slow, the writer's window between marking the folio dirty and
releasing it is wider, and the sync worker's periodic pass landed
inside it. The deadlock is real on any kernel; the slower one is what
made the timing land. The fix is in the sync loop, this port's side:
the mapping is flushed before `ip->lock` is taken, which is the order
`hammer2_fsync()` already had, and the flush under the lock is gone.

The fix is verified, on both kernels, by the pair `test-enospc.sh` was
made a gate on. On the sanitizer kernel, the run that had wedged at file
438: 464 of 464 files intact and 0 damaged, `cycles 0`,
`lockdebug lines 0`, lockdep enabled from the mount through the unmount,
`umount 0`, `rmmod 0`, and the fill stopped where a fill should, on the
volume filling rather than on anything waiting. On the debug kernel,
which had taken twenty-odd green fills before this cycle existed: 475 of
475 intact and 0 damaged, the same readings, 0 inode, 0 chain and 0 dio
still allocated after the unmount. Neither run reported KASAN, UBSAN or
a kernel warning. The two capture logs are
`doc/history/enospc-kasan-deadlock-fix-2026-09-26.log` and
`doc/history/enospc-rc4debug-deadlock-fix-2026-09-26.log`, beside this
record so that the claim above is read from a run and not from a patch.

The shape was searched for elsewhere, since one instance of it is a
class. The port blocks on a folio in seven places: the volume header
write and the device mapping's flush in `hammer2_xop_inode_flush()`, the
tail zeroing in `hammer2_zero_tail()`, the write path's two waits in
`hammer2_write_begin()` and `hammer2_write_end()`, and the two folio
grabs in `hammer2_io_putblk()`. None of the other six holds `ip->lock`
across its wait: `hammer2_zero_tail()` is documented as running before
the lock is taken, the write path takes the inode lock at the end of the
write under the folio, and the flush and io sites take no inode lock at
all. The sync loop was the only site, and the only blocking call in this
port that took the inode lock before a wait rather than after it.

The finding about the process is the one worth keeping. Every fleet
instrument in this tree asked about order and leaks and answered
correctly for three weeks; none asked about memory, and the two defects
that a memory question finds in the first minute were in the carried
core the whole time. A kernel with the sanitizers on is now the fourth
build in the guest and the one a fleet gate runs on when the question is
memory.


## The staged patches, read for whether their fix is applied here

On 2026-09-27, after the freemap null-chain fix was applied rather than
left staged, every patch under `doc/upstream/` was read for the other
half of the same question: a provenance entry records where the code
stands at upstream's head, and none of them recorded whether the fix had
been applied in this tree. `doc/README.maintenance.md` states the rule
without an exception, that a defect found here in carried code is fixed
here and marked `XXX` so the port does not wait on anyone, so a patch
that is staged and not applied is a defect this tree carries while its
fix sits in a file.

The reading was mechanical first and then read line by line, because a
mechanical one is wrong in both directions here. Each patch's added lines
were looked for under `src/sys/fs/hammer2/`, and the results include two
false negatives that a person has to resolve: the volume-list string
copies are applied as `strscpy_pad()` where the patch says `strlcpy()`,
since the BSD call does not exist on Linux and 0.9.32 fixed them that
way, and the freemap bmap ternaries are applied with the condition
wrapped across two lines, so a whole-line match misses them.

One patch was genuinely unapplied. `hammer2_chain_repchange()` takes
`reptrack->spin`, links the reptrack into the parent's list and returns
without releasing it; every pass through the loop leaks the write lock on
that reptrack and the next visitor to the structure blocks on it for
good. The only other release of a `reptrack->spin` in the tree is a
different local structure in `hammer2_chain_repparent()`, so nothing
releases this one, and DragonFly's own file at head reads the same way.
Applied as one line and an `XXX`, 5198 lines to 5200, with the `XXX`
table, the origin line count and the prose total moved and the syntax
gate at 65 checks 0 failed.

What that reading cannot claim: no run here drives
`hammer2_chain_repchange()` on a chain that carries a reptrack, which
needs the permanent deletion of an indirect block or a freemap node with
live children. The freemap fix at least had an instrument that exercised
its function, even though the branch itself was not taken. The other seven
patches are applied, in the port's form, and the sweep is what establishes
that rather than the assumption that staging means pending.

### The one instrument that does drive this fix, and why it is not a gate here

The reading above said no run drives the fix. That is true of every
script in this repository and false of the instrument that was on this
disk the whole time: `tests/storage/hammer2/reptrack_harness.c` in the
Saxum tree, run by `scripts/test-hammer2-reptrack.sh`. It reimplements
both functions' lock sequence as two threads with `hammer2_spin_ex` as an
ownerless non-recursive mutex, which is what DragonFly's `spin_lock` is,
and it carries its own negative control: the stock protocol must DEADLOCK
(`rc 3`) and the fixed protocol must complete (`rc 0`), so both wrong
means the harness is wrong rather than the source. Run on 2026-09-27, the
gate is green, 2 checks 0 failed, and the harness's `#ifdef FIX` release
sits at the identical position the port took, after the four field
updates and before the two chain spins are released.

The harness does not compile this tree. It has no `LINUX_HAMMER2`
reference and compiles its own statement-for-statement copy of the
function, so a green run is evidence that the PROTOCOL the port adopted
is correct and not that the port's file has it. The two are joined by
reading: the harness's body and `src/sys/fs/hammer2/hammer2_chain.c:2135`
agree hunk for hunk, which is what makes the harness's verdict bear on
this file at all. A model and its subject agreeing is weaker than
compiling the subject, and it is much stronger than the reading alone
this section first recorded. Copy and consumer drift independently, so
the agreement is a reading taken on a date, not a property the gate
enforces.

This is the same class as the two vector files recorded at 0.1.19: a
sweep for what runs a file, searched in this repository only, concludes
"run by nothing" about an instrument that lives in the distribution
consuming the port. Three of Saxum's gates reach this tree through
`LINUX_HAMMER2`; this one does not, so it belongs in the record as an
instrument over the protocol rather than as a gate over the file.

## The extent map and the freeze, and the count that nothing ran

`->fiemap` and `->freeze_fs`/`->unfreeze_fs` are Linux VFS operations
with no counterpart in the three BSD ports, so neither has an upstream
arrangement to compare against and the contract for both is the kernel's
own, read from `fs/ioctl.c` and `fs/open.c`. Both landed together at
0.9.38. FIEMAP had returned `EOPNOTSUPP` from `fs/ioctl.c` because no
`->fiemap` was registered, and `filefrag(8)` was told nothing about where
a file's blocks are. The port already had the mapping: `hammer2_xop_bmap()`
answers "does a chain cover this offset" one logical block at a time,
which is what `SEEK_DATA` and `SEEK_HOLE` reach through, so
`hammer2_fiemap()` walks the file a block at a time on the same call,
skips the offsets the XOP reports as holes, and coalesces the runs of
data into extents carrying the real `data_off`. It sets
`FIEMAP_EXTENT_MERGED` and no encoded flag, because the XOP returns the
offset alone and nothing in the call can tell whether the block is
compressed.

The freeze vops cancel the port's own syncer, `MPTOPMP(sb)->sync_work`,
which is the one writer a VFS freeze cannot see because it runs from a
workqueue rather than from a task the freeze blocks; `->unfreeze_fs`
schedules it again unless the mount is read-only.

**The freeze vops were written, wedged a volume, were withdrawn, and
were restored the same day.** The first exerciser wrote to the frozen
filesystem and then called the thaw from the same process, and a write
on a frozen filesystem blocks until the thaw, so the process deadlocked
itself in `D` state and never reached its own thaw. The vop was
condemned on the strength of that, and the withdrawal's source comment
named a lock order as the cause. Neither held up. Four probes on the
withdrawn build, on `h2debug-rc4` against a 2 GiB HAMMER2 volume:

| probe | reading |
|---|---|
| freeze and thaw alone, no I/O across them | both return, 10 of 10 iterations |
| a write while frozen, thawed by another process | the write BLOCKS and the cross-process thaw releases it |
| an unlink while frozen, thawed by another process | the unlink BLOCKS and the cross-process thaw releases it |
| freeze and unlink in one process, thawed from another | does NOT wedge |

The fourth probe is the shape that had wedged, run cross-process, and it
completed. The defect was the exerciser's. The lock-order cause the
withdrawal comment named was never reproduced by any probe and is
recorded in `hammer2_vfsops.c` as a defect of the comment rather than
deleted, because a cause written into a source comment without being
measured is its own defect and it stood in four documents for the length
of the withdrawal.

**The measurement.** `test/hammer2-fiemap.c` against a live HAMMER2
mount on `h2debug-rc4`, with every blocking call in a child so the thaw
is always reached by the parent that cannot block: 11 checks, 0
failures. The file opens its own hole with a sparse seek, asserts
against `st_blocks` that the hole is real before asking, then compares
the returned map against the shape it built. `filefrag -v`, a real
consumer rather than the exerciser reading itself, reports the same map
on the same media: extent 0 at block 0, extent 1 at block 2, the hole at
block 1 correctly absent, physical offsets 2244 and 2245, and 1 extent
for a dense file. `tmpfs` refuses FIEMAP outright, measured
`EOPNOTSUPP`.

**The defect the record is here for: the count had no instrument.**
That 11-checks figure was written into the 0.9.38 row of `CHANGELOG.md`
and into `doc/readiness-audit-2026-09-25.md`, and no script in this
repository ran `test/hammer2-fiemap.c`. `test-inventory.sh` reads the
reference-control table in `doc/README.testing.md` and the file list
under `test/`, so it knows a file is NAMED by a document and never that
anything RUNS it. This is the second time in two milestones: 0.9.37 put
the fallocate exerciser into `test/` and wired it into `test-enospc.sh`
for exactly this reason, and 0.9.38 recreated the gap with a new file.
`test/hammer2-fiemap.c` now runs in `test-enospc.sh` on the same volume
and on the same terms as the seek, dedup and fallocate exercisers beside
it, and its output prefix moved from `fm-` to `fiemap-` so the gate can
read it.

**Wiring it exposed a second defect, in the assertion.** The gate counts
the exerciser the way it counts the three beside it: fail if no check
ran, fail if any failed. Both are satisfied by a filesystem that
answered nothing. Run against `tmpfs` on the host, which refuses FIEMAP
and FIFREEZE, the exerciser prints:

    fiemap-ok   the file is sparse: 16 blocks for 12288 bytes
    fiemap-skip FIEMAP refused with errno 95
    fiemap-checks 1
    fiemap-failures 0
    fiemap-skipped 1

One check, zero failures, from a volume that refused everything, because
the assertion that the file is really sparse runs before the call it is
controlling. The count is what separates an answer from a refusal here,
so the gate pins it at eleven and fails any other value, in either
direction. The general rule this is an instance of: where the subject
can DECLINE rather than fail, the failure count cannot carry the
verdict, because refusal and success both print zero.

**The run of record.** `H2_FIXTURE_START=1 KDIR=~/kernels/linux-7.3-rc4
bash script/test-enospc.sh` on `artix-s6-kde`, twice, once before the
count was pinned and once after. Both reported `fiemap` 11 checks and 0
failed beside seek 12, dedup 3 and fallocate 12, all at zero, with
`fiemap-failures 0` and `fiemap-skipped 0`; the fill completed 2G with 0
failures, `oops 0`, `kernel warnings 0` after the module loaded, and the
unmount and the module unload clean. The first of the two is what showed
the format strings still emitting `fm-failures` after the prefix rename,
since the remote filter dropped the line and the gate read the missing
value as zero: the rename had matched only the quoted literals, and the
three multi-line `printf`s spelled the old prefix inside a string that
begins with a newline.

## The third exerciser with a published reading and no runner

The sweep that found the fiemap exerciser unwired was extended to every
file under `test/` on the same day, and asked a sharper question than the
first: not whether a script NAMES the file, which the inventory gate
already checks, but whether any line COMPILES or RUNS it. The first sweep
had matched a basename appearing anywhere in a script, including in a
comment, which is the named-against-run defect one level up from the one
it was looking for.

`test/getdents-resume.c` has no compile site in `script/`, the `Makefile`
or `.github/`, at any commit: `git log --oneline -S'getdents-resume' --
script/` returns nothing, so the file arrived in one commit (`7508b12`)
and was never wired to anything. Its row in `doc/README.testing.md` said
"the fleet's fixture run is the check" and the row above it carried a
reading, five entries over three calls in the root and three over two in
the subdirectory, taken against the five-path fixture on 2026-09-04. That
run was made by hand and nothing recorded or repeated it, so the row was
citing an instrument with no runner. This is the third of the class in
three milestones: the fallocate exerciser at 0.9.37, the fiemap exerciser
at 0.9.39, and this one, which is why the fix is a runner rather than a
fourth note.

**What it measures.** `->iterate_shared` must resume across calls. A
single `ls` cannot show it: a 32 KiB buffer takes a small directory in one
call, so the branch that stops mid-directory is never reached, and a
driver that restarts from offset zero on every call still lists every name
correctly when the caller's buffer is large enough. The exerciser reads
with a 64-byte buffer, one or two entries at a time.

**It has no check protocol, and saying so is part of the wiring.** It
prints each name and then `entries=N calls=M`, and exits nonzero on an
error or on a runaway past 100 calls. The gate therefore asserts the two
properties itself rather than reading a count the program does not print:
the CALLS exceeded one, which is the only thing that shows the
mid-directory stop was reached at all, and no name REPEATED, which is
what a read restarting from offset zero produces. The second is the
defect the file was written for, and the one-entry-per-call buffer makes
it visible as an exact duplicate each call.

**The run of record.** `KDIR=~/kernels/linux-7.3-rc4 bash
script/test-fixtures.sh` on `artix-s6-kde` against the shipped module:
`11 image(s), 43 file(s), 43 block count(s), 34 stat row(s), 5 statfs, 2
symlink(s), 1 corrupt file(s) refused, 100 ioctl result(s), 8 getdents
resume check(s), 0 failure(s)`, `EXIT=0`. The exerciser read 8 entries
over 4 calls on the first manifest that verified, `f11`, with each name
once.

**The negative control.** The exerciser was rebuilt with `lseek(fd, 0,
SEEK_SET)` forced before every `getdents64`, which is what a driver
restarting from zero does. It repeats the names, trips its own runaway
guard and exits 1, so the gate's run branch fails it rather than passing
it, which is the placement that matters: the break sits where the subject
executes. A variant that exits 0 with duplicate names would be caught by
the uniqueness branch instead, and the two branches are separate for that
reason.

The third exerciser in three milestones was found by asking what RUNS a
file rather than what NAMES it. That question is not gated, because a
search of this repository cannot see a consumer in another one: two of the
files under `test/` are compiled by a gate in Saxum through
`LINUX_HAMMER2`, and `doc/README.testing.md` holds that contract. It has
to be asked by hand on each sweep, and the tell to grep for is a doc row
that asserts a RUNNER rather than a property, since those are the rows
that can be true about the file and false about the tree.

## Upstream moved to a new candidate, and the port compiles against it

The kernel of record is a version, `KERNEL_REF=7.3` in
`script/test-syntax.sh`, and the tree it is read against is the newest
7.3 candidate. On 2026-09-29 the forge showed `v7.3-rc5`, tagged
2026-09-27, where the guest and the instruments had been on rc4. The
project's own rule is that the pin advances with each candidate, so the
question was whether the port still builds and passes its style gate at
the new one.

**Measured.** `v7.3-rc5` cloned from git.kernel.org at the tag, rc4's
`.config` copied in, `olddefconfig` and `prepare` run, then:

    KDIR=~/kernels/linux-7.3-rc5 bash script/test-syntax.sh
    syntax: 65 check(s), 0 failed against the kernel of record (7.3),
            7.3.0-rc5, mainline

65 checks, 0 failed, clang 22.1.8, no warnings in the port's files. The
style gate against the same tree reports the deviation set unchanged at
1145, and it reads the checker the baseline records by `sha256` rather
than rc5's own `checkpatch.pl`, so the count is comparable across the two
candidates. The port needs no change for rc5.

**What rc5 is, and why nothing here breaks.** `fs/super.c` is the file
that carries the shared block device open, one of the two facilities that
puts the floor at 7.3, and rc5 changes it: `2d2a2d7aa` moves
`hlist_del_init(&sb->s_instances)` out of `kill_super_notify()` and into
`put_super()`, and takes `sb_lock` around `super_wake(sb, SB_DEAD)`. The
facility the port depends on is the ability of several mounts to hold the
same block device, which is untouched; the change is to the order a
superblock leaves the instance list under concurrent mount, and the port
registers no mount-time walk of that list.

**What is not done, and is the next step rather than a claim.** The tree
of record for the guest and for the instruments was rc4
(`doc/README.testing.md` named `~/kernels/linux-7.3-rc4`), and this
section first recorded only that rc5 compiles. The guest was then
advanced, because a build-clean candidate is not a reading: rc5 was
built in the debug, release and kasan configurations with rc4's exact
configs carried forward, the three module trees and kernel images were
installed on `artix-s6-kde` beside rc1 and rc4, the mkinitcpio presets
and initramfs images were made, the grub default was pinned to
`h2debug-rc5` and the guest rebooted onto it.

**The run of record.** `uname -r` reads `7.3.0-rc5`, `uname -v`
`#1 SMP PREEMPT_DYNAMIC Tue Sep 29 19:37:32 PDT 2026`, lockdep reports
`debug_locks: 1` and kmemleak is present, so the debug configuration
carried. `KDIR=~/kernels/linux-7.3-rc5 bash script/test-enospc.sh`
against the rc5 guest:

    ok    seek 12 check(s) on a live mount, 0 failed
    ok    dedup 3 check(s) on a live mount, 0 failed
    ok    fallocate 12 check(s) on a live mount, 0 failed
    ok    fiemap 11 check(s) on a live mount, 0 failed
    oops 0
    kernel warnings 0 after the module loaded
    enospc: filled 2G, 0 failure(s)

Identical to the rc4 reading, every count. `script/build-check.sh`
against the rc5 tree links the module warning-clean, so the port is
current on the candidate the kernel of record names, and the candidate
is now the tree `KDIR` points at by default in the docs. The rc4 trees
and kernels remain installed, and `setkernel.sh` on the guest chooses
between them, so an rc4 reading can still be repeated.

**The fixture gate, a day late.** `doc/README.status.md` said the fixture
and fill gates were both run on rc5, and only the fill gate had been. The
fixture run was made on 2026-09-30 at `289c30a`, with
`KDIR=~/kernels/linux-7.3-rc5 H2_FIXTURE_START=1 bash script/test-fixtures.sh`.
The module's vermagic read `7.3.0-rc5`, and the gate refuses a run whose
vermagic differs from the guest's `uname -r`, so the guest was on rc5:

    fixtures: 11 image(s), 43 file(s), 43 block count(s), 34 stat row(s),
              5 statfs, 2 symlink(s), 1 corrupt file(s) refused,
              100 ioctl result(s), 8 getdents resume check(s), 0 failure(s)
    ok   lockdep stayed enabled across every mount, read and unmount

The `Input/output error` and `hammer2_chain_testcheck: failed` lines in the
log are f9's expected refusal of a data block flipped on media, which is
the corrupt file counted above. Every count matches the rc4 reading. The
gate shut the guest down after the run.

**The dependency check that prompted this, for the record.** Every tree
the port carries from was read at the forge on the same day:

| tree | head | moved since the carry |
|---|---|---|
| `kusumi/freebsd_hammer2` | `v1.2.13`, tag and branch head alike | no |
| `kusumi/netbsd_hammer2` | `v1.2.13`, the same | no |
| `kusumi/openbsd_hammer2` | `v1.2.13`, the same | no |
| `kusumi/hammer2-utils` | `v0.5.0`, the same | no |
| DragonFly `sys/vfs/hammer2/hammer2_disk.h` | no commit since `22b0532` | no |
| DragonFly `sys/vfs/hammer2/hammer2_ioctl.h` | no commit since `22b0532` | no |
| DragonFly `sys/vfs/hammer2/hammer2.h` | one commit, `30436b52c` | yes, harmless |
| `torvalds/linux` | `v7.3-rc5` | yes, measured clean above |

The two host tools are current for the box: clang 22.1.8 and gcc 16.2.1,
with Rust 1.98.1 for the userland, and `newfs_hammer2` is the
hammer2-utils v0.5.0 build.

## The rc5 pin reached the documents that name it, a step late

The rc5 section above recorded the move and the run of record. The commits
that carried it touched two files, this record and `doc/README.testing.md`,
so every other file naming the tree of record still named rc4. The rc4 move
on 2026-09-26 had a row in `CHANGELOG.md` for that reason, naming the files
that had to move with it: `script/pre-push-check.sh`, which searches for a
kernel to build the fleet gates against, and `CLAUDE.md`, which states which
checkpatch version CI fetches. The rc5 commits moved neither.

**What the stale pin controlled.** `script/pre-push-check.sh` searched
`~/kernels/linux-7.3-rc4` first, so the pre-push check would have built the
module against rc4 on every push while the record named rc5, which is a
second tree of record under a different name. `.github/workflows/ci.yml`
fetched the style checker from the `v7.3-rc4` tag. `CLAUDE.md` said CI
fetches the v7.3-rc4 copy "pinned to the kernel of record",
`doc/README.kernel-style.md` said v7.3-rc4 "is the version CI fetches", and
`doc/README.porting.md` said the pin was "at rc4 on 2026-09-26": three
present-tense statements about a pin that had moved. `doc/README.status.md`
still said the upstream section "does not yet say whether the port was run
against" rc5, which the run of record above had made false.

**The checker fetch was stale in the tag and correct in the bytes.**
`sha256sum` over `scripts/checkpatch.pl` at rc4 and rc5 gives the same
value, `2553cc1a601e70522e03fbce633d4e79fa5936f7f56a66de1899b7ddd247820a`,
which is the hash `doc/checkpatch-baseline.txt` records. The tag in the URL
named a retired candidate while the bytes it fetched were the pinned
checker, so no count was ever attributed to the wrong one. It is corrected
because a URL naming a retired tag stops resolving when that tag is pruned,
and because that line is what a reader takes for the pin.

**The correction.** Nine files name rc5 now: the CI fetch, the pre-push tree
search (rc5 first, rc4 and rc1 behind it so a machine holding only those
still behaves as before), `analyze.sh`'s usage line, `CLAUDE.md`,
`README.kernel-style.md`, `README.porting.md`, `README.capabilities.md`,
`README.status.md`, and the baseline's name line. The baseline's counts did
not move: 1145 before and after, the checker being the same bytes, which is
the result the rc4 move recorded for the same reason.

**Correction, read against the commit.** `CLAUDE.md` is in that list and
not in `2e64305`. It has been ignored by `.gitignore` and untracked since
`81d38f9` on 2026-08-26, so its rc5 edit exists on the machine that made it
and in no clone. The commit carries eight of the nine files above plus this
record. The same holds for the rc4 move's claim that it updated
`CLAUDE.md`. Neither changes a behavior: the two files that control one,
the pre-push search and the CI fetch, are tracked and moved.

**Measured after.** `CHECKPATCH=~/kernels/linux-7.3-rc5/scripts/checkpatch.pl
bash script/test-checkpatch.sh` reports the deviation set unchanged at 1145
with the baseline naming rc5, and its `--selftest` passes. The eleven host
gates are green: inventory 15 source files and 0 findings, syntax 65 checks
0 failed against 7.3.0-rc5, doc-prose 34 documents 0 findings, posix 65
checks 0 failed, provenance 32 checks 0 findings. The pre-push tree search
selects `~/kernels/linux-7.3-rc5`.

## The style gate could not see the tree of record, and said otherwise

Asking whether the documentation was current turned up a gate whose default
run did not do what `doc/README.status.md` says it does. The document
claims, of the state with no environment variables set, that "the syntax
gate finds that tree, and the style gate finds its `checkpatch.pl`", and on
this machine only the first half held: `test-syntax.sh` reported 65 checks
0 failed against rc5 while `test-checkpatch.sh` exited 2 refusing the host's
7.2 checker.

**The cause is a search list that was extended once and not twice.** Both
gates look for the kernel of record when `KDIR` is unset. The syntax gate
searches the host's build tree, `H2_KERNEL_TREES`, `$HOME/kernels/*/` and
the Nix store. The style gate searched the host's build tree and the store,
skipping `$HOME/kernels`, which is where `doc/README.testing.md` says the
trees of record are. The gate's own comment records the first half of this
class: it once looked only at the host tree and was widened to the store
because "the kernel the port targets sat in the store with a
`checkpatch.pl` in it". `$HOME/kernels` is the same defect one candidate
further down, and it is the location this repository's own document names,
so the machine most likely to run the gate is the one it could not help.

**Not a wrong verdict, a missing instrument.** The refusal is correct: 7.2's
checkpatch is not the checker the baseline records, and attributing this
code's deviation set to it would be wrong. Nothing was mis-measured. What
was wrong is that the documented unattended run did not happen.

**The correction, measured.** The candidate list gains the
`H2_KERNEL_TREES` directories and `$HOME/kernels/*/scripts/checkpatch.pl`,
in the same shape the syntax gate uses. With no environment variables
`bash script/test-checkpatch.sh` now reports the deviation set unchanged at
1145 and identifies the checker as the one the baseline records, by
`sha256`, derived from `$HOME/kernels/linux-7.3-rc5`; exit 0. The negative
control still refuses: pointed at the host's 7.2 checker alone it prints
COULD-NOT-RUN and exits 2, so the widening did not turn a refusal into a
pass. `--selftest` passes at 1 check 0 failed, a 7.3 checker reachable only
through `H2_KERNEL_TREES` is found with `$HOME` empty, and an explicit
`CHECKPATCH` still wins.




**An adversarial audit of the file-handle surface, 2026-10-01.** A
`silent-failure-hunter` pass over `hammer2_export.c`, told to assume three
earlier rounds had fixed the obvious and to hunt the subtle, returned
fourteen findings. Three were acted on and one was refuted; the rest are
recorded here so a later reader knows they were seen.

Acted on, each verified against the kernel of record first:

- The encoder wrote `inode->i_generation` into the handle and the decoder
  read it nowhere, so the field looked like a stale-handle check and enforced
  nothing. Now written as zero with the reason beside it (`9c284a7`).
- The encoder's comment said the caller retries a refused connectable handle
  with the size it reports. True of `name_to_handle_at(2)`, false of nfsd,
  where `_fh_update()` takes `fileid_type > 0 ? fileid_type : FILEID_INVALID`
  and `fh_compose()` answers `nfserr_stale`. The refusal is right for both;
  the comment now names which caller does which (`9c284a7`).
- A lookup failure other than ENOENT, which is a read error on an exported
  volume, was turned into a stale handle with nothing written down. It now
  prints (`9c284a7`).
- `hammer2_fh_to_parent()` decoded the handle's parent number without asking
  whether it named a directory. erofs and fuse do the same, so it is not a
  divergence, but a handle should resolve to the object it names or not at
  all. A non-directory parent is now refused (`9c284a7`).

Refuted. The audit's third finding held that `hammer2_get_parent()` can read
a stale `meta.iparent` because `hammer2_inode_lock()` does not refresh `meta`
from the chain, so a cached inode would carry a snapshot from before a
rename. `hammer2_vop_rename()` updates the in-memory copy directly:
`fip = VTOI(finode)` is the cached inode and `fip->meta.iparent =
tdip->meta.inum` is written under the inode lock (hammer2_vnops.c:516, :645),
which is the lock the read takes. No refresh is needed and the finding does
not hold.

Not acted on, with the reason. The parent number in a handle is not checked
against the child's, which the audit ranked highest; erofs and fuse decode
the same type the same way, `fh_to_parent` runs only on the nfsd
subtree-checked path, and the new directory test closes the part of it that
has an answer. `hammer2_vget()` short-circuits nothing for the PFS root, so a
root handle pays one guaranteed-to-fail lookup; real, unmeasured, and left
because it is a cost and not a correctness defect.

Both of the last two live on the one path this tree has no reading for:
`fh_to_parent` and the nfsd decode. `README.capabilities.md` names that as
the gap, and it is the same gap the whole surface has, so it is not new here.

**`fh_to_parent` is not reached by the syscall gate, measured 2026-10-01 and
corrected 2026-10-08.** The
capability row said its decode body runs in no test and left it there. That
understates it: it is unreachable from `name_to_handle_at`/`open_by_handle_at`
entirely, so no test written against those syscalls could reach it whatever it
did, and the reason is worth having on the record.

`exportfs_decode_fh_raw()` reaches `fh_to_parent` only from its
non-directory branch, and only after `find_acceptable_alias()` fails. For
`open_by_handle_at(2)` that cannot happen: the callback it passes,
`vfs_dentry_acceptable`, returns 1 without looking while `ctx->flags` is zero
(fs/fhandle.c), and `ctx->flags` is set only for a handle opened with
`O_DIRECTORY` (fs/fhandle.c:334, :338). A directory handle is also the one
form that encodes no parent, since `exportfs_encode_fh()` passes a parent to
the encoder only for a connectable non-directory. So the branch that calls
`fh_to_parent` is entered only for a non-directory, and a non-directory is
exactly what leaves the callback inert.

**Corrected 2026-10-08, and the correction corrected 2026-10-09.** The
paragraph above is wrong, and the probe below measured nothing.
`vfs_dentry_acceptable` returns 1 without looking when `ctx->flags` is
zero (fs/fhandle.c:210-212), and the gate runs as root, which holds
`CAP_DAC_READ_SEARCH`, so `may_decode_fh()` returns at once
(fs/fhandle.c:306-307) and sets no flag; root is the old permission model.
What changes it is the handle type: every handle the gate encodes is
connectable, and `handle_to_path()` adds `HANDLE_CHECK_SUBTREE` for any
handle whose type carries `FILEID_IS_CONNECTABLE`
(fs/fhandle.c:401-404). The callback then walks up from the decoded
dentry and accepts only if the walk reaches the mount directory
(fs/fhandle.c:230-252).

The first correction gave the wrong reason the walk accepts. It is not
the depth of the file, and it is not an alias search either: the decode
goes through `d_obtain_alias()`, which calls `d_find_any_alias()` first
and returns a cached dentry for the inode when one exists
(fs/dcache.c:2244). With the gate's warm cache the decode gets the
connected dentry the create left, the callback's walk reaches the mount
directory and accepts, and nothing is rejected anywhere.
`find_acceptable_alias()` (fs/exportfs/expfs.c:510) first offers the
decoded dentry to the callback (fs/exportfs/expfs.c:50); only if that is
rejected does it try the inode's other cached dentries
(fs/exportfs/expfs.c:54-66), and the decode falls to `fh_to_parent`
(fs/exportfs/expfs.c:518-523) when none is acceptable. A warm-cache
decode is accepted at the first offer, so the loop never runs.
On a cold cache the dentry would be disconnected (`d_parent` is itself,
fs/dcache.c:1953, so `IS_ROOT` holds, include/linux/dcache.h:31), the
walk would reject it wherever the file sits, no alias would exist, and
the decode would fall to `fh_to_parent`. The gate never drops the cache
and the record does not say whether caches were dropped, so the probe's
zero firings are the reading a warm cache predicts and not evidence
about the callback. The claim that `fh_to_parent` is unreachable through
the syscalls is true of this gate's warm cache only, not of the
interface: a cold cache through `open_by_handle_at(2)` would reach it
too.

Measured rather than argued. A probe line was placed at the top of
`hammer2_fh_to_parent()` that prints to the kernel ring, and every shape of
the syscall was driven against a live mount: a connectable file handle opened
plain, with `O_DIRECTORY`, with `O_PATH` and with `O_NOFOLLOW`, and a
directory handle (`type=0x30081`) opened with `O_DIRECTORY`. The probe fired
zero times. The file was restored and rebuilt after.

nfsd is the caller this tree's own gate cannot stand in for: it passes
`flags = 0` with `nfsd_acceptable`, which returns 0 unless the walk from the
decoded dentry reaches `exp->ex_path.dentry` (fs/nfsd/nfsfh.c), so on a
subtree-checked export `find_acceptable_alias()` can fail and the parent
decode runs. That is why the member is registered and why the syscall gate
does not exercise it;
the guest cannot serve an export because every kernel in the fleet and every
tree here is built with `CONFIG_NFSD` unset, and enabling it needs SUNRPC,
which the kernel of record does not build either.

**Seek on a sparse file is O(size), measured 2026-10-01.** `SEEK_DATA` and
`SEEK_HOLE` advance one block at a time through `hammer2_llseek()`, asking
`hammer2_bmap_lbn()` per 64 KiB block, and each of those allocates an XOP,
takes the inode lock, runs a `hammer2_chain_lookup()` for one key and retires.
The code comment says "one block at a time" and no reading anywhere had it.

Measured on `artix-s6-kde` at 7.3.0-rc5, a 4 GiB volume, an all-hole file:

| file size | `SEEK_DATA(0)` |
|---|---|
| 1 GiB | 0.349 s |
| 2 GiB | 0.697 s |
| 3 GiB | 1.030 s |

Linear at 0.343 to 0.349 s per GiB, which is the per-block cost: 16,384 XOPs
for the 1 GiB case, each a lookup and a lock cycle. `SEEK_HOLE` is not
affected in the same way because it stops at the first hole; `SEEK_DATA` is
the one that walks, and on a file whose data is past the hole it walks every block before the answer changes
before answering ENXIO.

The fix is bounded and uses a primitive the tree already has: `SEEK_DATA`
wants the NEXT allocated key at or after an offset, which is a forward scan
of the blockref tree, and `hammer2_chain_next()` is that scan, already used
in six places including `hammer2_xop_scanlhc()` and `hammer2_xop_scanall()`,
which is also how `readdir` walks a directory. One scan would replace the
per-block loop: the XOP memoizes its position and returns the next data key,
and the seek steps by that instead of by a block. Not done here, because it
changes the seek path's shape rather than its correctness and that is a
decision for the tree's author rather than one to take while measuring.

**It was done, the next day.** `hammer2_bmap_next_key()` and the rewrite of
`hammer2_llseek()` around it landed as `6f26d63` and are row 0.9.47, which
carries the result: 9,787.7 us to 2.1 us per `SEEK_DATA` on a 1 GiB
all-hole file, a factor of 4,660, with the answers unchanged. The paragraph
above is kept as the reading and the reasoning at the time, and the code
still carries `EXPERIMENT:` at both sites, which is the marker for work
whose value is not yet established; the measurement is taken and the
disposition of that marker is the author's.

Not a correctness finding. `test/hammer2-seek.c` passed throughout, and the
answers above are right: `SEEK_DATA(0)` on an all-hole file is ENXIO and it
is reported as ENXIO, just slowly.

**The write path, profiled for the first time, 2026-10-01.** The read path was
profiled and optimized (the read-ahead workers, 0.9.19), and no profile of the
write path existed anywhere in this tree. Taken on `artix-s6-kde` at
7.3.0-rc5 with the kernel's function profiler filtered to the module's own 303
symbols, a 200 MiB `dd` with `conv=fsync`, on the debug kernel (lockdep and
kmemleak on, so every figure is that build's):

| hammer2 function | calls | self time | per call |
|---|---|---|---|
| `hammer2_vop_fsync` | 1 | 819,764 us | 819,764 us |
| `hammer2_writepages` | 2 | 792,653 us | 396,326 us |
| `hammer2_xop_start` | 3,213 | 743,092 us | 231 us |
| `hammer2_xop_strategy_write` | 3,200 | 712,607 us | 223 us |
| `hammer2_write_file_core` | 3,200 | 621,223 us | 194 us |
| `hammer2_compress_and_write` | 3,200 | 620,624 us | 194 us |
| `hammer2_assign_physical` | 3,200 | 292,913 us | 92 us |
| `hammer2_chain_create` | 5,613 | 264,963 us | 47 us |
| `hammer2_file_write_iter` | 200 | 204,343 us | 1,022 us |

The one-call costs dominate: the flush at the end of `fsync` is 819 ms, and
`writepages` 396 ms per call, against 223 us for each of the 3,200 write XOPs.
Nothing here is out of line with the design: `fsync` syncs the inode's chain
and flushes, and the flush issues the device cache barrier `a235a5b` wired in;
`writepages` walks the folios of a 200 MiB file. The write XOP's per-block cost
is the carried strategy path, which 0.9.21 already took one full-block copy out
of.

`hammer2_chain_find_cmp` is the largest single self-time row in the whole
profile, 403 ms, and it is `RB_SCAN` over the chain rbtree. That is DragonFly's
own code and the FreeBSD port's, line for line, including the scan-in-progress
bookkeeping `hammer2_rb.h` explains; a linear scan is what finds the best
matching chain in a key range, and replacing it with a direct `RB_FIND` would
break the four-tree symmetry the port exists to keep.

What the profile settles: the write path's cost is where the design puts it,
in the two whole-file operations at the end rather than in the per-block path,
so there is no per-block win left to find here. What the profiles do not
settle, and what `doc/README.status.md` already names: every figure above is
the debug kernel's.

**A throughput reading is not takeable under host load, 2026-10-01.** Cold
reads on `7.3.0-rc5-release` measured 2.1 to 3.4 GiB/s for a 2 GiB file at
1 MiB requests against the 3.7 to 5.4 the record holds, and the host was at
load 19 on 24 CPUs with a Nix LTO build, several `lto1-wpa` and `nix`
processes at 100 percent. That is not a regression and is not recorded as
one: a rate measured on a saturated host is the host's, and the port's
throughput readings are taken and read with the comparison filesystems beside
them on the same guest in the same run for exactly this reason. The rate is
re-taken when the machine is idle; the number above is kept to date the
attempt, not to move the reading of record.

The release kernel carries no function profiler, so the profile of record
stays the debug build's: `CONFIG_FUNCTION_TRACER` is not in the release
config, which is what makes it the build to measure rates on and the wrong
build to profile. The seek figure below is a CPU measurement on one call and
is not load-sensitive the way a rate is.

**Seek forward scan, measured on the release kernel.** The debug-build figures
above (0.345 s per GiB) are that build's; the reading that ships was taken
2026-10-01 on `7.3.0-rc5-release` with no lockdep and no kmemleak, A/B against
the same tree's `main`, both modules built against
`~/kernels/linux-7.3-rc5-release`:

| build | `SEEK_DATA` over a 1 GiB all-hole file |
|---|---|
| `main`, the per-block loop | 9,787.7 us per call |
| the forward scan | 2.1 us per call |

4660 times faster on the build that ships, 0 kernel warnings, and
`test/hammer2-seek.c` 12 checks 0 failures on that same release module.

**Seek forward scan, on a branch.** `SEEK_DATA` had the one
algorithmic defect this audit found: it walked the file one 64 KiB block at a
time, one XOP each. Replacing the loop with the tree's own forward scan
(`hammer2_xop_scanall`, carried and unused) took it from 0.345 s per GiB,
linear, to 0.0001 s per GiB flat to 16 GiB, and a seek across a 1 GiB hole
from ~320 ms to 28 us. `test/hammer2-seek.c` passes 12 of 12 and
`test-enospc.sh` reports the full run green. It is on the branch
`seek-forward-scan` (`6f26d63`) rather than main: it changes the seek path's
shape, and that is the tree's decision rather than one to take while
measuring.

**The read path's named ceiling, identified, 2026-10-01.** The entry above left
the next ceiling as "a spinlock and an rwsem at a tenth and a fourteenth of
the profile, named rather than measured". Profiled on the debug kernel with
the full function set, a cold 512 MiB read of one file:

| function | calls | for 8,864 blocks |
|---|---|---|
| `hammer2_read_folio` | 8,864 | one per block, the floor |
| `hammer2_chain_testcheck` | 8,297 | under one verification per block |
| `hammer2_chain_get` | 43,357 | 4.9 per block |
| `hammer2_chain_lock` | 78,817 | 8.9 per block |
| `down_write` / `up_write` | 215,720 each | 24 per block |

The verification ratio is the one the fix above was for and it holds: under
one `chain_testcheck` per data block, so the "four verifications per block"
that the read-ahead rework found are still gone. What remains is the tree
walk: `chain_get` and `chain_lock` are the inode's chain descending through
its indirect blocks to the data block, and the 24 lock pairs per block are
that descent twice over, once each way. The read XOP takes its chain shared
(`HAMMER2_RESOLVE_SHARED`, one lookup per block), so the `down_write` count is
the exclusive acquires inside the traversal rather than the read's own lock.

None of this is a defect and none of it is fixable here: the depth is the
format's, the locks are DragonFly's arrangement, and the counter that would
have shown a redundant re-verification shows none. The ceiling is now a
number per block instead of an adjective, which is what the record asked for.

**The latency instrument's host control had never run, 2026-10-01.** The
`tmpfs` control is the fourth comparison in `script/latency.sh` and the one
that shows the exerciser's own cache check is live: a reading served from
memory must fail that check, or nothing proves a guest reading came from
media. It ran `/tmp/h2lat`, which is where the exerciser is copied **on the
guest**; on the host the binary is built at `$W/h2lat`, a temporary
directory. So the control printed `No such file or directory` on every run,
its output went through `sed` so its status was dropped, and nothing asserted
it had run. The check the whole instrument rests on was never exercised.

It runs `"$W/h2lat"` now, and the control's output is checked for a reading
before the run continues: a control that cannot run exits 2 rather than
letting the numbers below stand on nothing. Run by hand the check is what it
should be, `lat-fail randread4k median 471 ns is cache speed, so the cache
was not cold and this is not a media reading`.

This is the second instrument defect found the same day, after the throughput
run building against the debug tree while the guest ran the release kernel.
Both are the same shape: an instrument that reports a number without the
control that says the number means what it claims.

**HAMMER2's random-read latency moved between rc4 and rc5, cause open,
2026-10-01.** The latency table above is rc1's and rc4's, 49 us for
`randread4k` at the median. Re-run on rc5 the same instrument reports 74, and
a second run under a higher host load reports 81, against ext4 at 12 and
btrfs at 25 where the table holds 11 and 23. The controls moved nine percent
between the two builds; HAMMER2 moved fifty-one.

That asymmetry is why this is written down rather than dismissed as load. A
host that is busy slows every filesystem in the same guest through the same
CPU and the same disk; ext4 and btrfs barely moved and HAMMER2 moved by half.
Both readings were taken with the host between load 14 and 17 on 24 CPUs
under a Nix LTO build, so the absolute figures are not the reading of record
and are not offered as one. What they are is a reason to re-take it on an
idle host before anything else is concluded, which the entry above says the
same day's throughput attempt showed was not possible.

One code change touches the read path between the two readings:
`c70f4b7`, which released a reptrack spinlock that
`hammer2_chain_repchange()` had been leaking on every pass through the
indirect-block and freemap-node path. That is the path a random read
traverses when it descends to a data block, so it is the only candidate; it
also removes contention rather than adding it, which is the direction
opposite to the observation, so it is a candidate and not an explanation. No
measurement here separates it from the build or the host.

What would settle it: the same instrument on rc5 on an idle host, and a
profile of the random-read pass rather than a sequential one, since every
profile in this tree so far is sequential. Re-running the older kernel was
considered and dropped: 7.3-rc5 is the kernel of record and the floor, the
tree moves forward only, and characterising a previous build answers a
question nothing would act on. The reading to take is rc5's, on a quiet
machine.

**The random-read path profiled, and what it costs per 4 KiB, 2026-10-01.**
Every profile in this tree is sequential. The latency table measures random
4 KiB reads and the port loses there, so this profiles that pass instead:
`test/hammer2-latency.c` on a 1 GiB file of a 2 GiB volume on
`h2debug-rc5`, the function profiler filtered to the read path's own
functions, the page cache dropped first.

Per random 4 KiB read, over 7,458 `hammer2_read_folio` calls for 3,000
operations at one 64 KiB block read each:

| function | calls | per read_folio | average |
|---|---|---|---|
| `hammer2_read_folio` | 7,458 | 2.5 | 72.9 us |
| `hammer2_xop_strategy_read` | 7,458 | 2.5 | 46.9 us |
| `hammer2_chain_load_data` | 8,747 | 1.2 | per 1,000 ops |
| `hammer2_chain_lookup` | 5,393 | 5.4 | per 1,000 ops |
| `hammer2_io_bread` | 142,992 | 19 | per read_folio |
| `hammer2_bread` | 92,067 | 12 | per read_folio |
| `hammer2_chain_testcheck` | 17,828 | 2.4 | per read_folio |
| `hammer2_io_getblk` | 144,182 | 72 | per 2,000 ops |

The number that stands out is `hammer2_io_getblk`: seventy-two calls per
random read, and each takes `hmp->iohash_lock` **exclusively**
(`hammer2_mtx_ex_waits`, hammer2_io.c), a device-wide mutex. The port counts
these waits already and the throughput run reports them as
`iohash_waits 34198,1527628`, the second figure being microseconds spent
waiting on that one lock. A read that misses the cache walks the inode's
chain to the data block: `chain_lookup` and `chain_load_data` are that walk,
and each block it touches goes through `getblk`.

What this does not yet establish, and is not claimed: whether seventy-two is
the correct count for the walk or contains redundant lookups. It is the
coarse lock `doc/IO_MODEL.md` already records as a port decision: this port
carries the FreeBSD arrangement, one `iohash_lock` for the whole device,
where DragonFly locks nothing in the io layer and takes a per-bucket spinlock
shared for a lookup. The document names the price, the acquisitions that
wait, and measures it at 2.6 percent on the four-writer run; the same section
says the FreeBSD shape would have to change first. So the acquisitions are
known and accepted rather than a defect found here.

Attributed further: a page-cached read of the same offset measures 1.66 us,
so the module is not in the path when the page cache answers, and the
acquisitions are the price of a cold miss rather than redundant work the tree
could drop. The read walks the blockref tree under the lock the port chose.

For the open latency question above, this is the instrument that would
resolve it: the same profile is the reading a fix would move, and it is
load-tolerant in a way a rate is not.

**The io hash lock is contended and scales to a plateau, measured
2026-10-02.** The port takes one device-wide `iohash_lock` for a structure
that has 32,768 buckets (`HAMMER2_IOHASH_SIZE`), and the record's cost for it
was 2.6 percent of acquisitions waiting on a four-writer workload. Measured
with thread count as the variable instead, a 2 GiB file on a 4 GiB volume on
`h2debug-rc5`, the page cache dropped, each count reading the port's own
`iohash_waits` before and after:

| threads | ops/s | acquisitions | waiting |
|---|---|---|---|
| 1 | 3,096 | 23,822 | 0 (0.0%) |
| 2 | 6,894 | 45,591 | 1,898 (4.2%) |
| 4 | 10,248 | 84,954 | 10,117 (11.9%) |
| 8 | 17,545 | 142,745 | 42,793 (30.0%) |
| 12 | 17,210 | 179,052 | 68,604 (38.3%) |

Two things are in that table. The waiting share rises with concurrency, and
throughput stops scaling: 8 threads run 17,545 ops/s and 12 threads run
17,210, so fifty percent more threads buys nothing and takes a little back.

The control says the guest is not the ceiling. The same benchmark on a 64 MiB
file whose blocks are cache-resident, where the module is out of the path
entirely, runs 386,336 ops/s at one thread and 2,098,974 at twelve, scaling
cleanly. The cached path is a hundred and twenty times the cold one, so the
cold path's plateau is not the CPU and not the page cache.

What is held under the lock is not only a list scan: on a miss
`hammer2_io_alloc()` runs `hmalloc(..., M_WAITOK)` inside the critical
section, and `M_WAITOK` may sleep, so the device-wide lock is held across an
allocation. The release before the I/O is correct; the serialization is in
the lookup and the insert.

This is the evidence the record asked for before any change to code three
ports share. It says the coarse lock's acquisitions are contended and the
contention grows with threads, which the 2.6 percent figure on one workload
did not show.

**What it does not say, and the reading that corrected it.** The same
benchmark on ext4, same guest, same disk, same 4 KiB `pread` workload,
reports 14,479 ops/s at one thread and 88,209 at eight, against HAMMER2's
3,096 and 17,545. Read as ops/s that looks like a five-to-one gap, and it is
a units error: ext4 serves a 4 KiB request from a 4 KiB block while this port
reads and verifies a 64 KiB block for the same request, so the two counts are
not the same work. In media bytes they are 194 MiB/s to 1,097 for this port
against 57 to 345 for ext4, so the port moves three times the bytes at both
ends and scales 5.7 times against ext4's 6.1. The per-operation latency
confirms the units: ext4's 4 KiB random read measures 70.2 us by hand against
this port's 69.1, so both are real media access and the port is doing sixteen
times the media work at the same latency.

So the contention is real and the throughput ceiling it was read as causing
is not: both filesystems plateau near the same media rate, for the disk's
reason. No locking change is justified by this measurement, and the
per-bucket lock FreeBSD disabled is not shown to be worth taking. The
measurement stays because the contention figure is what the record asked for
and because the units error is the thing to not repeat.

**A 4 KiB random read pulls 256 KiB from the device, measured 2026-10-02.**
The device sectors read were counted across 500 random 4 KiB reads of a 2 GiB
file, before and after, on `h2debug-rc5` with the page cache dropped:
256,256 sectors for 500 reads, 256.3 KiB of device traffic for a 4 KiB
request, a 64-fold amplification.

The multiplier is `hammer2_cluster_data_read`, whose default is 4, passed to
`page_cache_sync_ra()` in `hammer2_io_readahead()` as a multiple of the
device's read-ahead window. It is read flat: the call is made for every data
read whether the access is sequential or random. Measured by setting the
multiplier at load, one pass each, the device traffic tracks it directly:

| `cluster_data_read` | device KiB per 4 KiB read |
|---|---|
| 4 (the default) | 256 |
| 2 | 135 |
| 1 | 73 |

DragonFly does not read flat. Its `hammer2_io.c` calls `cluster_readx()`
with an `hce` cluster estimate that the buffer cache derives from the access
pattern, and where `hce` is zero it calls `breadnx()` and reads the one block
with no read-ahead at all, so a random access over-reads nothing. The port
has no equivalent of `hce`: `page_cache_sync_ra()` is asked for the hint's
worth of pages on every miss.

The hint's value is itself measured and should not be lowered on its own: the
read-ahead table above found hint 4 with a 4 MiB device window the best of
the three hints tried (2936 and 2908 MiB/s against hint 16's 2802 and 2778),
so on a sequential read the constant earns its place and the missing piece is
the pattern test, not the constant.

**What this entry described as current was fixed the same day, and the
paragraphs above are kept as the reading rather than corrected.** The
multiplier is gone: `page_cache_sync_ra()` is now passed the block's own
pages, `dio->psize >> PAGE_SHIFT`, so a random read no longer over-reads
whatever the hint is set to, and the hint is a switch rather than a
multiplier. The entry below has the kernel reading that settles it and the
resulting traffic, 256 KiB down to 73 KiB per random 4 KiB read. The
measurement table above stands as taken, since the hint did scale the
window when it was measured; the sentence saying the port "has no
equivalent of `hce`" does not, and a reader should take the entry below.
This note exists because a stale statement of a live DEFECT is the most
costly kind to leave unmarked: a stale all-clear gets re-checked, and a
stale defect sends the next reader looking for something that is not
there.

**The read-ahead call passed the wrong quantity, 2026-10-02.**
`hammer2_io_readahead()` asks `page_cache_sync_ra()` for
`hint * (dio->psize >> PAGE_SHIFT)` pages on every device read. That argument
is the pages **this request needs**, not how far ahead to read: the kernel
reads it as-is for a standalone random read (mm/readahead.c, "Read as is, and
do not pollute the readahead state") and lets `ra->size`, bounded by
`ra_pages`, do the look-ahead on a stream. With `hint` at 4 and the block at
16 pages the argument was 64, so a random 4 KiB read asked the kernel for
64 pages and got 256 KiB from the device where the block it needs is 64 KiB.

Passing the block's own pages fixes it. Measured on the release build of the
kernel of record, both modules built against
`~/kernels/linux-7.3-rc5-release`, device sectors counted across 500 random
4 KiB reads with the page cache dropped, two runs each:

| build | device KiB per 4 KiB read | random, 1 thread |
|---|---|---|
| before | 256, 256 | 41.9, 45.0 us |
| after | 73, 73 | 28.5, 27.7 us |

Three and a half times less device traffic per random read and about a third
less latency, reproduced. The 73 KiB is one 64 KiB block plus the metadata
the walk touches, which is the floor for this format. Sequential read measured
4,884 and 5,100 MiB/s with the fix against 4,884 and 3,176 to 3,215 before,
so it is not paid for out of the sequential path; the pair runs under host
load above 13 and the sequential figure is not a controlled comparison.

`hammer2_cluster_data_read` stays at 4. It is the read-ahead distance the
kernel's own state machine uses, it is DragonFly's value, and the read-ahead
table above found it the best of the three tried; what was wrong was passing
it where the request size belongs.

**`cluster_write` is declared and read nowhere, and the mechanism it names
is already there, 2026-10-02.** Of the sixteen module parameters this port
declares, fifteen are read; `hammer2_cluster_write` is the one that is not.
It is DragonFly's physical write clustering, carried by all three BSD ports
as a parameter and used by FreeBSD (`cluster_write_vn()`, hammer2_io.c) and
by DragonFly (`cluster_write()`, hammer2_io.c), while NetBSD and OpenBSD
carry the parameter and read it nowhere, and this port follows them.

The question is whether the mechanism is missing. Measured on the release
build of the kernel of record, a 4 GiB volume, `dd` of 800 MiB with
`conv=fsync`, device writes and sectors counted from `/proc/diskstats`:

    800 MiB written, 4810 device writes, 1645184 sectors = 803 MiB
    average device write request: 171.0 KiB

For 64 KiB blocks that is 2.7 blocks per device request, so the writes are
already batched: Linux's block layer merges the adjacent bios the port
issues, which is the work `cluster_write()` does on the BSDs. The ordering
is right as well, the file landing contiguous on the media at 6503 of 8192
steps against DragonFly's own 2018 on the same volume.

So the parameter is dead rather than the feature being absent, and the two
are worth separating: a knob that is accepted and does nothing is the defect
this tree treats as a bug, while the batching it would have requested already
happens in the layer below. The parameter's disposition belongs with the
port's author: removing it changes the module's parameter list, and wiring it
would ask for a merge Linux already performs.

**Taken 2026-10-04: removed.** The reading above was made on 2026-10-02 and
left the call open; the call is removal, and `hammer2_cluster_write` is gone
from all three sites that carried it, the definition and the registration in
`hammer2_vfsops.c` and the declaration in `hammer2.h`. The module is one
parameter shorter. What the parameter named, physical write clustering, is
still not a facility this port lacks: the block layer merges the adjacent
dirty folios before the device sees them, at the 171 KiB average request the
measurement above records, so there is no work for a knob to do and none was
lost with it. A tree that lists its parameters is what reads this next, and
the parameter list is now sixteen, counted from the source's own
`module_param_named` lines; `modinfo` reports thirteen of them, the other
three sitting behind `#ifdef`.

**What DragonFly has that this port does not, taken as a set, 2026-10-02.**
The question behind three readings of one file is whether the port is a
thinner design than DragonFly's rather than a translated one. Compared by
file, DragonFly's `sys/vfs/hammer2` carries twenty `.c` files and this port
seventeen, two of which are its own (`hammer2_export.c`, and the generated
`hammer2.mod.c`). Five are absent:

| file | what it is |
|---|---|
| `hammer2_synchro.c` | the cluster state machine, twelve functions |
| `hammer2_iocom.c` | the cluster communication layer, twelve |
| `hammer2_msgops.c` | the cluster message operations |
| `hammer2_ccms.c` | the cluster cache management layer |
| `hammer2_lz4.c` | DragonFly's own LZ4 |

Four of the five are one subsystem. DragonFly's cluster synchronization is
what makes a HAMMER2 volume replicated, and every file it lives in is absent
here. That is not a gap found now: `doc/README.capabilities.md` declares
Replication, IncrementalReplication and RemoteCheckpoint `unavailable` and
says the same of seven of the eight `HAMMER2IOC_*` this port lacks, and the
same reason is given there, that none of the three BSD ports carries the
subsystem either.

The fifth is a substitution rather than a gap: this port uses the kernel's
LZ4 through `<linux/lz4.h>` where DragonFly ships its own, which
`hammer2_strategy.c` records as measured rather than assumed.

So the answer by file set is that the port is thinner in exactly one place,
the cluster subsystem, and that thinning is the BSD ports' as much as this
port's, taken deliberately and declared. Nothing else in the layer is
subtracted: read side by side, `hammer2_io.c`'s functions differ from
DragonFly's only by the leading underscore its debug-argument macro adds, and
`cluster_write` is the one parameter of sixteen that is declared and unread.

Where a difference *was* real it was in a call rather than in a file, and the
two found this session were both a Linux API used for a purpose its argument
did not carry: `page_cache_sync_ra()` given the cluster hint where the
request's page count belongs, and the seek loop asking for one block at a
time where the tree already had a forward scan.

**The rc5 latency reading, on an idle host, and what it corrects,
2026-10-02.** Taken with the host at load 0.33, the first time in this
session the machine was quiet, `script/latency.sh` on `h2debug-rc5`, a
1024 MiB file, 2000 operations, the page cache dropped before the read pass:

| filesystem | randread4k p50 | randwrite4k_fsync p50 | fsync_batch8 p50 |
|---|---|---|---|
| HAMMER2 | 64 | 357 | 1323 |
| ext4 | 17 | 6819 | 8696 |
| btrfs | 33 | 7854 | 9499 |

`lat-failures 0`, `kernel warnings 0`, and the host control reported cache
speed and failed its own check as it must.

This corrects two entries above. The first read the earlier rc5 runs (74, 81,
79 us) as HAMMER2 moving half again while the controls moved nine percent,
and called that an asymmetry needing an explanation. It is not: with the host
idle the medians are 64, 17 and 33 against the record's 49, 11 and 23, so
every filesystem reads slower in this guest than in the rc4 record, ext4 by
half again and HAMMER2 by a third. The earlier runs were taken under host
load between 13 and 19, and their controls were not cold: ext4 reported
439,506 ops/s, which is page cache, so the comparison in those runs was
between a media reading and a cached one. An environment that moves all
three together is a difference of environment; the asymmetry was an artifact
of the controls not being cold.

The write side agrees with the record rather than moving: 357 us against 384
for one write and its commit, 1323 against 1386 for a batch of eight.

**The punch walked the page cache by a page where the folio is a
block, 2026-10-02.** `hammer2_fallocate()`'s `PUNCH_HOLE` path looped
`pos += PAGE_SIZE` over `read_mapping_folio()`, and that call returns
the folio CONTAINING the index (`read_mapping_folio()` is
`read_cache_folio()`, mm/filemap.c, which resolves through
`filemap_get_folio()`). A block folio covers sixteen pages, so the loop
took the same folio sixteen times per block, the comment above it
saying "in folio-sized steps" while the code stepped by a page. The
walk now advances by `folio_next_index()`.

**The finding, as a class.** This is the third call in this session
where a Linux API was used for a purpose its argument did not carry,
and it is the first found by reading the kernel's own implementation of
the callee rather than by reading the port. The sweep that found it was
not a grep for the call names but the module's undefined-symbol list,
`nm -u hammer2.ko`, 217 entries, which names every kernel facility the
port enters with no guessing about where to look. The remaining entries
were checked against their implementations in linux-7.3-rc5 and are
correct as called; four that appeared to have no call site
(`read_cache_folio`, `d_parent_ino`, `page_get_link`, `file_ra_state_init`)
are reached through kernel inline helpers, `dir_emit_dotdot()` and
`read_mapping_folio()` among them, and resolve.

**What the measurement refused.** The arithmetic says sixteen repeats
became one and suggests sixteen times the work; the kernel refuses that
reading. Each repeat is a hash probe on a folio already present plus a
refcount, and the zeroing of pages already zeroed is a no-op, so the
cost removed is the walk and not a sixteenth of the work. Measured on
`h2debug-rc5` through a fresh 4 GiB image, `/tmp/h2punch3` punching
512 MiB, three runs each state, warm and with `/proc/sys/vm/drop_caches`
written between runs:

| build | 512 MiB punch, three runs | |
|---|---|---|
| page step (before) | 0.739, 0.734, 0.729 s warm; 0.733, 0.727, 0.768 s cold | 0.734 s |
| folio step (after) | 0.576, 0.578, 0.581 s warm; 0.583, 0.580, 0.576 s cold | 0.579 s |

0.734 s to 0.579 s, a factor of 1.27. The comment written into the
source first claimed the sixteen-times figure and was corrected against
this reading; a source comment asserting a cause no probe measured is
the defect this record names elsewhere, and it was about to be
committed a second time.

**An earlier reading of this probe was wrong and is recorded as the
instrument's fault.** A first version called `drop_caches` from inside
the static binary through `system(3)`; the guest has no shell for it, so
the write was never made and three "cold" runs at 6.4 s for 512 MiB
were warm ones against a cache the binary had failed to drop. The
correction is not the number but the shape: cache control belongs
outside the thing being timed, and a probe reporting a state it did not
establish is the same defect as a comment asserting an unmeasured
cause.

**The correctness check, and what it does not show.** A punch that
starts and ends inside block folios, spanning several whole blocks
between, must zero exactly the requested bytes and nothing outside
them. Checked byte for byte over 1 MiB on the final build, 1,048,576
bytes compared against the pattern the file was written with: 0 wrong.
Run against the pre-fix build as well, where it also passes, which is
what that check is: the correctness of the punch was never in question,
only how many times each folio was visited, so this is a regression
guard for the walk and not a discriminator for the change.

**The existing exerciser could not have found this.** `test/hammer2-fallocate.c`
punches one block, taken from `statvfs(dir).f_bsize`, which is the
filesystem's own block size; a one-block punch enters the loop once, so
neither the page step nor the folio step is distinguishable in its
timing and both are correct in its assertions. `fallocate 12 check(s),
0 failed` on the gate is a true reading about a case the defect does
not touch. That is the shape this repository names as the reason a test
must use the input the real caller passes, and here the real caller
punches ranges, not blocks.

**The mechanism answer: why the port is not doing what DragonFly does,
2026-10-02.** The file-set answer above says nothing is subtracted except
the cluster subsystem, and that is true of what is CARRIED. It is not
the same question as whether the carried code still does what DragonFly's
does, and three readings of one file had been standing in for it. Read
against the DragonFly tree at `250a8b4928`, the difference is where the
device I/O is issued from, and it is one call wide.

DragonFly issues device reads through `cluster_readx()` with the cluster
hint as its last argument, `HAMMER2_PBUFSIZE*hce`, 256 KiB with the hint
at 4, and end-of-file aligned down to `HAMMER2_SEGMASK64`. Linux has no
`cluster_readx()`: the nearest is `page_cache_sync_ra()`, and its
argument is the pages the request itself needs, which is the correction
0.9.49 made. The port's read-ahead distance is consequently the kernel's
`ra->size` bounded by `ra_pages`, which mount raises to 4 MiB, and not a
distance the filesystem sets per read. On a sequential stream the two
reach a similar window by different means; on a random read they differ,
and the measured result is on record, 73 KiB of device traffic per random
4 KiB read after the correction against 256 before.

The write side is the same shape and is the one place the port has a
parameter it does not use. DragonFly, when `HAMMER2_DIO_FLUSH` is set,
takes `hce = hammer2_cluster_write` and calls `cluster_write(bp, peof,
psize, hce)` after setting `B_CLUSTEROK`, so the buffer layer writes the
cluster as well as the buffer; when the hint is zero it clears the flag
and calls `bawrite()`, and when the flush bit is absent it calls
`bdwrite()` and lets the data accumulate. The port's equivalent is
`folio_mark_dirty_lock()` plus `filemap_fdatawrite_range()` over exactly
the one buffer, which is the delay-and-issue-now decision kept from
DragonFly's comment, and `hammer2_cluster_write` is declared and read
nowhere. So the port does not ask the block layer to merge anything.

That is the one real difference in mechanism, and the evidence says it
costs nothing: the block layer already merges adjacent dirty folios before
the device sees them, measured at 171 KiB average device write for 64 KiB
blocks, so wiring the parameter would request a merge Linux performs
anyway. The honest statement is not that the port is missing a DragonFly
mechanism but that the mechanism has no Linux counterpart to reach for,
and the layer below supplies it.

What this settles about the question itself: asking why the port is not
doing what DragonFly does has, three times, resolved to the same answer,
that a DragonFly facility named in the carried code is a facility Linux
does not have, and the port is not thinner so much as translated where
translation is possible and substituted where it is not. The yield from
the question is therefore not more porting. It is a reading of each place
the port calls a Linux facility and a check that the argument is what that
API expects, which is how all three defects found this session were found:
`page_cache_sync_ra()` given a hint, the seek loop asking per block, and
`read_mapping_folio()` walked by the page.

**The Linux counterpart that does exist, and why it does not apply,
2026-10-02.** The entry above concludes that DragonFly's clustered
device I/O has no Linux counterpart to reach for. That is half right and
the wrong half would have been left standing: `readahead_expand()` does
exist, it is the API for a filesystem that wants to set its own read-ahead
extent rather than accept the request it was handed, and four filesystems
in the tree of record use it (btrfs in `fs/btrfs/extent_io.c`, erofs in
`fs/erofs/zdata.c`, squashfs in `fs/squashfs/file.c`, and netfs in
`fs/netfs/buffered_read.c`). It is the closest thing Linux has to
`cluster_readx()`'s extent argument, so "no counterpart" was too strong a
claim to leave.

It does not apply here, and the reason is in this port's own words rather
than in the API. `readahead_expand()` expands the window over folios it
can add to the page cache; what it needs from the filesystem is a length
to expand TO, which is why every caller reads one out of an extent map.
btrfs passes `em_end - ra_pos` from its extent map, squashfs passes the
end of the decompression block it is already assembling, erofs passes the
end of the current cluster. HAMMER2 has no such quantity: the carried
bmap XOP returns a physical offset alone, with no length and no
compression flag, and the fiemap row above records the consequence
directly, that "two adjacent logical blocks are two allocations" and a
caller is being told a physical run rather than that the run was allocated
together. There is no extent whose end could be named, so there is nothing
to expand into, and inventing a length would be the port reporting a
contiguity the format does not promise.

The distinction matters because it changes what the finding IS. The port
is not withholding a Linux facility that would make it faster; the
facility needs a piece of filesystem metadata HAMMER2 does not carry. What
would carry it is a length in the blockref, which is a format change and
not a port change, and the format is DragonFly's to change.

**The remaining comparison, run to the end, 2026-10-02.** The two entries
above answer the file set and the device-I/O call. This one closes the
algorithmic layer between them, and the method was a function-by-function
diff of DragonFly's `hammer2_strategy.c` against the port's, since that
is the file where a performance choice would live that is neither a
missing file nor a missing kernel facility.

Every function in DragonFly's strategy file is carried. This port's
`hammer2_strategy.c` defines `hammer2_assign_physical`,
`hammer2_compress_and_write`, `hammer2_dedup_record`, `hammer2_write_bp`,
`hammer2_write_file_core` and `hammer2_zero_check_and_write`; the rest of
DragonFly's list, `hammer2_strategy_read`,
`hammer2_strategy_read_completion`, `hammer2_strategy_write`,
`hammer2_xop_strategy_read`, `hammer2_xop_strategy_write`,
`hammer2_dedup_lookup`, `hammer2_dedup_clear` and `hammer2_bioq_sync`,
resolve in the port at the same names in the same file or beside it. The
only two with no counterpart are `hammer2_vop_strategy` and
`hammer2_vop_bmap_impl`, and both are VFS entry points a port necessarily
re-expresses: Linux reaches them through `->read_folio`, `->writepages`
and `->bmap` in `hammer2_file_aops`, not through a `vop_strategy`.
Nothing algorithmic is absent. The tuning constants agree as well:
`HAMMER2_PBUFSIZE` is 65536 on both sides and `HAMMER2_EMBEDDED_BYTES`
512.

The one mechanism that IS DragonFly's and not the FreeBSD port's, the
threaded XOP backend, was already weighed and already has a number. This
port runs XOPs synchronously, which is the FreeBSD port's choice recorded
in `README.porting.md`, with the deliberate exception of strategy XOPs,
which run concurrently on one inode as DragonFly's worker groups do, so
the read-ahead workers verify a file's blocks on every CPU. The cost of
the synchronous pool was measured against a filesystem with no XOP at
all: six seconds in eighty-five, which is the reading that kept the pool
synchronous and left the workqueue-backed one unbuilt. What the
synchronous choice does NOT cost is scoped parallelism, because the
concurrency on metadata work comes from the callers rather than from a
per-operation thread pool: a million files took 248 s from four writers
against 1007 s from one, a factor of 4.06 in the one measurement of it.

So the answer to whether anything further can be taken from DragonFly is
no at the three layers a port can take it from: the file set is thin only
where the BSD ports are thin and it is declared, the device-I/O call has
no Linux counterpart and the nearest one needs metadata the format does
not carry, and the algorithms are all present with their constants. What
remains is not a DragonFly gap at all. It is the class this session found
three times, a Linux facility called with an argument that facility does
not mean, and the way to find the next one is to keep reading the kernel's
implementation of what the port calls rather than the port.

**What the cluster subsystem would cost, measured 2026-10-02.** The
capability table has declared Replication, IncrementalReplication and
RemoteCheckpoint `unavailable` since it was written, and the roadmap puts
clustering beyond H7 with the words "investigate after qualification". No
investigation had been recorded, so the declaration rested on the three
BSD ports having deleted the layer rather than on a measure of what
carrying it would take. The three ports were checked here rather than
taken on trust: `hammer2_synchro.c`, `hammer2_ccms.*`, `hammer2_iocom.c`
and `hammer2_msgops.c` are absent from the FreeBSD, NetBSD and OpenBSD
trees in this workspace, and no file in any of them names `kdmsg` or
`cluster_readx()`. The declaration is correct.

What follows is the cost the declaration was missing.

| what | lines |
|---|---|
| `hammer2_synchro.c` | 1069 |
| `hammer2_iocom.c` | 387 |
| `hammer2_msgops.c` | 87 |
| `hammer2_ccms.c` | 311 |
| `lib/libdmsg` | 5490 |

The 1,854 lines of cluster code are the smaller half and are portable:
read for their kernel dependencies, `hammer2_synchro.c` uses `kprintf`,
`KKASSERT` and `tsleep`/`wakeup`, all of which the shim already provides.

**Corrected, 2026-10-03.** This table first described `lib/libdmsg` as
"the layer all four call", and that is wrong: counted later and recorded
below, `hammer2_synchro.c` and `hammer2_ccms.c` call no `kdmsg` function
at all, and only `hammer2_iocom.c` with 25 calls and `hammer2_msgops.c`
with 4 reach it. The paragraph immediately below this table already said
the right thing about `synchro.c`, so the entry contradicted itself two
lines apart. The figures are unchanged; the parenthetical is gone, and
the entry below has the per-file counts.
The load-bearing dependency is `kdmsg` instead: `hammer2_iocom.c` builds
on it, the four files reach ten distinct entry points
(`kdmsg_iocom_init`, `_autoinitiate`, `_reconnect`, `_uninit`,
`kdmsg_msg_alloc`, `_reply`, `_result`, `_write`, `kdmsg_msg_t`,
`kdmsg_state_t`), and `lib/libdmsg` is a USERSPACE library, so a kernel
module cannot link it. A port means writing an in-kernel message
transport, the filesystem/message boundary and a link state machine
before the first line of cluster logic runs, since the kernel side of
`kdmsg` lives in `sys/kern/kern_dmsg.c`, which this workspace's partial
DragonFly tree does not carry.

The reason to decline is not the size. It is that the size buys no
capability that is measurable here and no peer to compare against: the
cluster is replication, incremental replication and remote checkpoints,
none of which any BSD port has, so there is no second implementation to
measure the port against and nothing in the performance record that a
cluster would move. Every reading this port has and the ports do not,
the million-file scaling, the closure copy, the seek rewrite and the
read-ahead correction, is on the single-volume path the cluster does not
touch.

**Every module parameter accounted for, and the one that is inert,
2026-10-02.** The tree's rule is that a setting accepted whether or not
it takes effect is a defect, and no document listed the module's
parameters or said which are read, so the rule had nothing to be checked
against. There are seventeen, and sixteen are read. The sweep is recorded
here because its first version was wrong in a way worth keeping: a search
over `.c` files alone reported `nofs_scope` as unread, and it is read in
`hammer2_os.h` at two sites, so a parameter's readers are not confined to
the file that declares it.

| parameter | read at | what it does |
|---|---|---|
| `nofs_scope` | `hammer2_os.h` x2 | the NFSSCOPE control around the allocation scopes |
| `io_buf_only` | `hammer2_io.c` x3 | forces the DIO layer's own buffer instead of the page cache |
| `cluster_meta_read`, `cluster_data_read` | `hammer2_io.c` | switches, below 1 turning read-ahead off |
| `dedup_enable`, `dio_limit`, `bulkfree_tps` | several | the named facilities |
| `limit_scan_depth`, `limit_saved_chains` | chain and inode | the scan bounds |
| `always_compress`, `alloc_data_bytes`, `alloc_meta_bytes`, `data_rewrites` | several | compression and the allocation counters |
| `folio_changed`, `debug_hpanic`, `fail_alloc_after` | several | the counters and the fault injections |

`hammer2_cluster_write` is declared at `hammer2_vfsops.c:81`, exported at
`hammer2.h:959`, and registered at `hammer2_vfsops.c:159` with mode 0644,
so it is settable at runtime, and no code reads it. The intent was
DragonFly's `cluster_write(bp, peof, psize, hce)`, which sets
`B_CLUSTEROK` and asks the buffer layer to write the cluster as well as
the buffer, and the port's write path does neither, marking the folio
dirty and issuing `filemap_fdatawrite_range()` over the one buffer.

The reading that decides its disposition is on record already: the block
layer merges adjacent dirty folios before the device sees them, measured
at 171 KiB average device write for 64 KiB blocks. So wiring the parameter
would request a merge Linux performs anyway, and the parameter is not a
capability that is missing but one that has no work to do. It should be
removed rather than wired, and until it is, it is a defect of the class
the tree names: a setting a user can set with nothing to observe. That is
the maintainer's to take, since removing it changes the module's
parameter list.

Taken 2026-10-04: removed rather than wired, the maintainer having ruled on
the 2026-10-02 reading. The parameter is absent from the source and from the
built module: the list stands at sixteen where this section's sweep found
seventeen, and all sixteen are read, so the defect this paragraph names is
the one the removal closes.

**The capability surface re-audited for what could be developed further,
2026-10-02.** The question is whether something beyond the current state
would surpass it in function or in efficiency and is being left undone.
The capability table is the tree's own answer and it was checked against
the sources rather than read.

Every row that is not `native` is one of two kinds, and neither is a
port shortfall. Nine are `unavailable` and each is absent on DragonFly
too or absent from the format: `Quota` is enforced by neither the port
nor the core, `Encryption` the format does not have, and `SelfHealing`
and `FailureDomains` need `ncopies` to be written by more than one
volume, which in DragonFly is done by `hammer2_synchro.c`, the cluster
file no BSD port carries. Four more are `limited`, and the limit was
traced to the format as well: `SpaceAccounting` reports
`hmp->voldata.allocator_free`, and DragonFly's `hammer2_vfs_statfs()`
reads that same stored counter, so the free count moving at allocation
and at the second bulkfree pass rather than at a remove is HAMMER2's
design and not a Linux choice; the 5% non-root reservation is on both
sides at `free_reserved`. `Scrub` is offline-only on both sides too,
`fsck_hammer2` over an unmounted volume.

The ioctl surface was audited the same way and produced one correction
and one non-finding. The non-finding is `HAMMER2IOC_BULKFREE_ASYNC`,
which the port does not carry: DragonFly reaches the same handler with a
NULL argument to avoid waiting, so a consumer that wants bulkfree
without blocking runs the synchronous ioctl on its own, and the table's
row says so. The correction is the count that surrounded it. The section
said DragonFly declares 27, this port implements 19, and 8 are missing,
and 27 less 8 is 19, so the arithmetic closed and the figure read as
checked. It is not: DragonFly's 27 names are 22 commands and 5
`HAMMER2IOC_INODE_FLAG_*` bits that `INODE_SET` reads out of `ino->flags`
rather than dispatching, and the port's 20 names are 15 commands and the
same 5 bits. Measured by comparing the two headers, the port is missing 8
DragonFly commands and carries one DragonFly does not have,
`HAMMER2IOC_VOLUME_LIST2`, so it implements 15 of DragonFly's commands
rather than 19. The section now states the split it can be checked
against instead of a total that was true of no definition: a figure whose
arithmetic closes over a mixed unit is the failure this class produces,
since it cannot fail the way a wrong subtotal does.

**A cluster may hold more than one chain, and the guard forbidding it,
2026-10-02.** The capability table has declared `SelfHealing` and
`FailureDomains` unavailable since it was written, with the reason that
"the copies mechanism is not carried in any port", and that reason was
doing two jobs at once: it was true of the ports AND it was hiding a
guard this port had added of its own. `hammer2_assert_cluster()` asserted
`nchains == 1` with the comment that a valid cluster can only have one,
and `hammer2_cluster_check()` carried DragonFly's first pass and the tail
of its third while dropping the quorum machinery between them, the
dropped tail asserting that every slot past the first was NULL. Between
them a multi-chain cluster was a `KASSERT` failure before any code could
reach it.

**What was ported rather than invented.** `hammer2_cluster_check()` is
now DragonFly's, all four passes: the first counting masters and slaves
and setting the soft and hard read and write flags, the second resolving
`nmasters`, `umasters` and `nmasters_keymatch` against a quorum-reduced
transaction id, the third validating the quorum-agreed elements, and the
fourth checking the elements not marked invalid against the focus. The
quorum is the PFS's master count halved plus one, so a single-master PFS
gets one and behaves exactly as it did when the check was single-chain,
which is why the readings elsewhere in this record are unchanged. The
returns name the port's positive error bits rather than upstream's
negative errnos, and upstream's three-way disagreement return collapses
to `EAGAIN` for "more replies may arrive" and `EIO` for the two settled
cases, since the port has no bit for `ESRCH` or `EDEADLK`.

**The defect the review found, which no gate could.** The commit that
removed the guard was reviewed adversarially and the review found that
`hammer2_xop_alloc()` allocated a FIFO for `collect[0]` alone while
`hammer2_xop_start()` walks every index below `nchains` and each storage
function feeds `collect[i]`, and `hammer2_xop_retire()` already freed
`collect[i]` for every `i`. The allocator was single-chain and the free
side was multi-chain; raising the bound let the two disagree on the
array's width. Eleven green gates, a clean `fsck_hammer2` and zero kernel
warnings all passed over it, because the single-chain path every test
exercises never touches `collect[1..]`. That is the shape worth keeping:
a bound relaxed without the state behind it is fail-open, and the guard
being relaxed was the one that used to catch the disagreement.

**What is carried and what is not, said plainly.** The read and
coordination half is now here: chains, quorum, and a FIFO per chain. The
writer that emits a second blockref for a block is absent, in this port
and in DragonFly both, and the format's own comment says so in DragonFly's
words: "When redundancy is desired a set may contain several duplicate
entries pointing to different copies of the same data. Up to 4 copies are
supported. Not implemented." No multi-chain volume has been built here,
so the multi-chain path is carried and reviewed and NOT exercised; the
single-chain path is what every measurement in this record runs.

**The measurements.** On 7.3.0-rc5 with the debug kernel: a 4 GiB volume
mounts, takes a directory, a file, a 4 MiB random write and a sparse
file, reads all of it back, seeks, syncs, remounts and reads again, with
0 kernel warnings, and unmounts at 0 inode, 0 chain, 0 modified and 0 dio
still allocated. After the FIFO fix a second run wrote a further
directory, file and 2 MiB random write, read back a file written by the
build BEFORE the fix, and unmounted the same way. `fsck_hammer2` on the
host reports the media clean on both, the second at 9 inodes and 86 data
blocks. Every one of those paths runs through `hammer2_cluster_check()`
at one of the 26 `xop_collect` call sites.

**How a multi-chain cluster is formed, and why this port cannot form
one, 2026-10-02.** The entry above says the multi-chain path is carried
and reviewed and not exercised, and the obvious next step was to build a
volume that has one. That was attempted and the attempt found why it
cannot be done from this side.

A cluster is the set of PFS roots sharing a `pfs_clid`, and the mount's
super-root scan appends one chain per `PFSROOT` inode it finds, matching
on that id. So two PFS roots with one `pfs_clid` is a two-chain cluster,
and the format explicitly expects it: `hammer2_disk.h` says
`{pfs_clid, pfs_fsid}` must be used to identify an instance because "a
mount may contain more than one copy of the PFS as a separate node".

The route taken was to create a second PFS with `HAMMER2IOC_PFS_CREATE`
and give it the first's `pfs_clid` through `HAMMER2IOC_INODE_SET`, which
carries the whole `hammer2_inode_data_t` and so appears to reach the
field. It does not, and the kernel is not at fault: `INODE_SET` writes
only `check_algo`, `comp_algo`, `inode_quota`, `data_quota` and
`ncopies`, each gated on its own `HAMMER2IOC_INODE_FLAG_*` bit, and
`pfs_clid` is in none of them. Read side by side at the kernel of record
and at DragonFly's `hammer2_ioctl.c`, the two are identical, so this is
upstream's behavior and not a port gap. The write succeeded, returned 0,
and changed nothing; the reading that caught it is `HAMMER2IOC_PFS_GET`
on the remounted volume, which reports MCFIX at
`00000000-0000-0000-0000-000000000000` beside MC2's own id.

Clusters are formed upstream by `HAMMER2IOC_REMOTE_ADD` and
`HAMMER2IOC_RECLUSTER`, which are 7 of the 8 ioctls the capability table
lists as absent, and which need the cluster subsystem: `kdmsg`, 5490
lines of userspace library with no kernel half in the tree this workspace
holds. So the chain of reasoning closes where the capability table
already said it would, and now it is measured rather than argued: a
two-chain cluster cannot be built here, and the reason is the same one
that leaves Replication unavailable, not the assertion the entry above
removed.

The method is worth recording too, since it is the second time this
session a hand-rolled probe reported a state it had not established. The
first probe's PFS walk reset `name_key` every pass and read one entry
forever; the second read the field it had written and believed it. What
settled the question was reading the kernel's own `hammer2_ioctl_pfs_get`
iteration protocol and then reading `hammer2_ioctl_inode_set` to see which
fields it acts on, not adding a third probe.

**Is DragonFly's cluster subsystem alive, and what would porting it
cost, 2026-10-03.** Both questions were answered by asking the forge
rather than the shallow clone in this workspace, which cannot answer
either: it is depth 1.

**It is stalled, and the stall is old.** By file, the last commits:
`hammer2_synchro.c` 2018-11-09, `hammer2_msgops.c` 2018-03-16,
`hammer2_ccms.c` 2018-03-16, `hammer2_iocom.c` 2020-03-28. Everything
after those dates on those files is trailing whitespace, unused header
includes, and unused-variable removal. The only cluster-adjacent commit
in 2026 is "fix `HAMMER2IOC_RECLUSTER` ioctl failing on local mounts",
which keeps the code compiling rather than extending it. HAMMER2 itself
IS under active maintenance: fifteen commits since June 2026, mtime
fixes, typos, error paths. The cluster subsystem is not part of that;
it has had no functional development in seven years. The DESIGN
document's own status list agrees and is the reason: the network message
core and network block device are "operational", while error handling,
the Quorum Protocol and Synchronization are all "under development", so
the transport exists and the consensus on top of it does not. Waiting for
upstream to lead on this is waiting on work that has not moved since
2018.

**The cost was overstated here and is corrected.** The earlier entry
priced the port at `kdmsg`'s userspace half plus an unwritten kernel
transport. Read from the forge, `sys/kern/kern_dmsg.c` is 2202 lines and
its kernel dependencies are four: `lwkt_create` and `lwkt_exit` for its
two threads, `wakeup`, and `kmalloc`, all of which the shim already
provides. The transport itself is `fp_read()` and `fp_write()` on a
`struct file` handed in by the caller, which is one call pair in the
kernel and has a direct Linux counterpart in `kernel_read()` and
`kernel_write()` over a file descriptor, the descriptor arriving the way
upstream's does, from the mounting side. That is not a network protocol
to be written from nothing; it is a message stream over a passed file.

**Compatibility is not the risk the earlier entry implied.** `kdmsg`
carries messages; it does not change the media. The on-disk format is
what makes two PFS roots sharing a `pfs_clid` one cluster, and it already
says so. A port that implements the transport changes nothing a DragonFly
mount reads.

What remains true is that the ten `kdmsg_*` entry points HAMMER2 calls
have to exist before the four cluster files link, and that no volume with
two chains can be built here until they do. That is a body of work, not a
wall, and the earlier entry called it a wall.


**What the cluster port actually is, read from the specification and the
forge, 2026-10-03.** The instruction is to implement the cluster: the
message core, the block device, error handling, the quorum protocol and
synchronization. What follows is what those are, read from DragonFly's
own DESIGN document and from the code, so the plan is the author's design
and not an inference from file names.

**The architecture, and it is the reason there is no systemd question.**
The socket lives in USERSPACE. `sbin/hammer2/cmd_service.c` creates it
with `socket(AF_INET, SOCK_STREAM, 0)`, sets `SO_REUSEADDR`, binds
`INADDR_ANY:DMSG_LISTEN_PORT`, `listen(50)`, forks, and accepts. The
accepted descriptor is passed INTO the kernel through the mount path,
which is what `mount_hammer2.c`'s own `socket()` call is for. The kernel
side then does `fp_read()` and `fp_write()` on that descriptor inside
`kern_dmsg.c` and never opens a socket itself. Grepped for the name, the
whole of `sys/vfs/hammer2` and `lib/libdmsg` contains no reference to
systemd, socket activation, or any init system: the transport is a file
descriptor that the operator's daemon owns, and on Linux that is
`kernel_read()` and `kernel_write()` over the same descriptor. Nothing in
this needs an init system to pass it, and nothing will use one.

**Refined below, 2026-10-03.** The sentence naming `kernel_read()` and
`kernel_write()` as the Linux form of that transport is the first answer
and not the one to implement: read later against the kernel's own
clustered filesystems and against nbd and nfsd, the descriptor resolves to
a `struct socket` and the calls are `kernel_recvmsg()` with `MSG_WAITALL`,
`kernel_sendmsg()` and `kernel_sock_shutdown()`. The reason is recorded
below and it is three things the file API cannot express, one of them the
shutdown that `kdmsg_iocom_uninit()` needs to wake a blocked reader. The
design paragraph above stands; only the mapping is superseded.

**The four protocols, from the DESIGN document.** There are four, and
only two of them run between master nodes:
- Quorum protocol, between MASTER nodes, to vote on operations, resolve
  deadlocks, determine the latest transaction id for an element, and
  commit.
- The Cache sub-protocol, a MESI protocol running UNDER the quorum one,
  maintaining cache state for sub-trees so operations stay coherent.
- The Proxy protocol, used by every node type that is not a MASTER or
  SOFT_MASTER, which forwards through one adjacent node rather than
  participating in the vote.
- The Media protocol, which is the physical media path.
The six node types are DUMMY, CACHE, SLAVE, MASTER, SOFT_SLAVE and
SOFT_MASTER, and the distinction that matters is that SOFT_* may source
and sink data locally WITHOUT quorum agreement because they are directly
mounted, which is the class this port is in today.

**What is genuinely left to build, by the DESIGN's own status.** The
network message core and the network block device are marked operational,
error handling, the Quorum Protocol and Synchronization are marked under
development. The stalled commits confirm it: the transport was finished
and the agreement above it was not. So the port is not writing a
protocol from nothing; it is carrying a finished transport and finishing
the part upstream never did, against a specification that exists.

**Compatibility.** None of the four touches the media. The cluster is
defined on disk already, as the set of PFS roots sharing a `pfs_clid`,
which `hammer2_disk.h` states outright. A port that implements the
transport and the quorum changes nothing a DragonFly mount reads, which
is the answer to whether this diverges: it does not.

**The cluster transport was built on the wrong Linux primitive, and a
published claim about its consumer is false, 2026-10-03.** Both were found
by an adversarial audit that read the kernel of record and the two
clustered filesystems already in it, and both are corrections to work
recorded above.

**The false claim.** Commit `9237966`'s message says the four cluster
files call `fp_read()` and `fp_write()` and that nothing links until they
exist. They do not. Read at the forge, `hammer2_iocom.c` contains no
`fp_read`, `fp_write` or `fp_shutdown` at all; it calls eight `kdmsg_*`
functions and passes its `struct file *` through
`kdmsg_iocom_reconnect(&hmp->iocom, fp, "hammer2")`. The `fp_*` callers
are in `sys/kern/kern_dmsg.c`, 2202 lines, which is not in this port. So
the shim's consumer is that file and not the four, and the entries above
describing the transport are right while the commit message that
introduced it is wrong. A commit message cannot be corrected in place, so
this entry is the correction.

**The wrong primitive.** The transport was written over
`kernel_read()` and `kernel_write()` on a `struct file`. The kernel's own
answer, read from `drivers/block/nbd.c` and `net/sunrpc/svcsock.c`, is to
resolve the descriptor to a `struct socket` and use the socket API:
- `MSG_WAITALL` is upstream's `all=1` performed by the protocol
  (`net/ipv4/tcp.c`, `net/unix/af_unix.c`, both setting
  `target = sock_rcvlowat(sk, flags & MSG_WAITALL, len)`), so
  `kernel_recvmsg(sock, &msg, &kv, 1, len, all ? MSG_WAITALL : 0)` is the
  loop the shim hand-rolled.
- Blocking belongs to the call and not to the daemon's descriptor. With
  `kernel_read()` it is inherited: `sock_read_iter()` sets `MSG_DONTWAIT`
  when the file carries `O_NONBLOCK`, so a daemon that passes a
  non-blocking descriptor gets `EAGAIN` under `all=1`, which the shim
  correctly does not forgive, and the read thread would die on its first
  read. That is a bug reachable only at run time.
- `fp_shutdown()` has no counterpart here at all. DragonFly's
  `kdmsg_iocom_uninit()` and the read thread's own exit both call
  `fp_shutdown(fp, SHUT_RDWR)` to wake a blocked reader, and on Linux
  that is `kernel_sock_shutdown(sock_from_file(fp), how)`, which works
  only on a socket. The shim has no `fp_shutdown`; `kern_dmsg.c` cannot
  link without it.
- The three acceptance checks are nbd's: reject a non-socket, a
  non-stream, and a socket whose `ops->shutdown == sock_no_shutdown`.
  A pipe would work through `kernel_read` but has no shutdown, so
  `kthread_stop()` would be its only unsticker, which is the reason nbd
  refuses one.

**The errno model in the shim comment is wrong at the one path teardown
uses.** The comment says `__kernel_read()` never returns an `ERESTART*`
and that `EINTR` is the restart case here. A blocking socket read
interrupted while waiting returns `-ERESTARTSYS`, from
`sock_intr_errno()` when the timeout is `MAX_SCHEDULE_TIMEOUT`, and a
pipe returns it from `fs/pipe.c`. The only interrupter a kthread has is
`kthread_stop()`, through `TIF_NOTIFY_SIGNAL`, which `signal_pending()`
reports and which is sticky for a kthread because the only clearers are
the return-to-user path a kthread never takes and io_uring. The behavior
happens to be right, any nonzero error breaking the read loop, and the
reason to write down is that a retry would spin forever rather than that
the error cannot arrive.

**Two more findings that change what comes next.** The `lwkt` shim must
be `kthread_create()` plus `get_task_struct()` plus `wake_up_process()`,
joined by `kthread_stop_put()`, which is what gfs2 does; DragonFly's own
thread exits on its first read error and `kdmsg_iocom_uninit()` polls a
NULL pointer it set, and carrying that poll on Linux is a use-after-free
against a freed `task_struct`. And `hammer2_ra_wq` is not usable for
cluster work: it is `WQ_UNBOUND` with no `WQ_MEM_RECLAIM` and is shared
with read-ahead, where both in-tree transports use a reclaim-capable
queue because the message path sits under writeback.

**What there is no substitute for.** A sweep of `mm/` and
`include/linux/` for cross-node cache state finds only hardware
interconnect and DMA maintenance, so DragonFly's `ccms.c` has no in-tree
analog to replace it. The kernel's own coherence model is the DLM lock
lattice that gfs2 and ocfs2 build on, and reaching for it would replace
`kdmsg`, the quorum protocol and the cache sub-protocol with corosync and
`dlm_controld`, which is a different architecture and not a port. The
cache sub-protocol is carried, as the DESIGN document specifies it.

**Most of the cluster is transport-free, and the plan changes, 2026-10-03.**
The fetched originals were counted for their real dependency on kdmsg, and
the count inverts what the earlier entries assume. Read at the forge and
counted here:

| file | lines | kdmsg calls |
|---|---|---|
| `hammer2_ccms.c` | 311 | 0 |
| `hammer2_synchro.c` | 1069 | 0 |
| `hammer2_msgops.c` | 87 | 4 |
| `hammer2_iocom.c` | 387 | 25 |

`hammer2_synchro.c` is the one that matters. It is the master and slave
synchronization thread, the largest of the four, and it calls no kdmsg
function at all: it is driven entirely through the core this port already
carries, `hammer2_chain_lock` and `_lookup` and `_modify` and `_create`
and `_delete` and `_next` and `_setcheck` and `_cmp` and `_resize`, with
`hammer2_inode_lock` and `_chain` and `_get` and `_ref` and `_drop`, and
the XOP cluster arrays. Its kernel facilities are `kprintf`, `KKASSERT`,
`tsleep` with the atomic-then-sleep pattern, `wakeup`, `kmalloc` and
`kfree`, every one of which the shim has. `hammer2_ccms.c` is the same
shape: the MESI cache-state machine over `hammer2_spin_ex`/`_unex` and
`ssleep`, no kdmsg, no locks the port lacks. Together they are 1380 lines
of the cluster that need no transport.

`hammer2_iocom.c` is the transport-facing file, 25 kdmsg calls, and
`hammer2_msgops.c` is 87 lines with 4, both of them leaf handlers over the
message layer. So the kdmsg work gates 474 lines, not 1854, and the 1380
that need only the carried core and two shim primitives can land first.

**The two primitives those files need and the port lacks** are `curthread`,
which DragonFly uses to identify the owning thread in a CST, and `ssleep`,
the sleep that releases a spinlock, sleeps and reacquires it. Both are
shim work of the size already done, not new architecture.

**What that means for order.** The plan recorded above put the transport
first because the four files were assumed to depend on it. They do not,
two of them overwhelmingly do not, and synchronization is the part that
makes a SLAVE converge, which is what Replication and SelfHealing both
need. Carrying `synchro.c` and `ccms.c` first is both smaller and closer
to the capability the tables call unavailable.

**The transport shim is dead code in the module, and the graph says which
symbols the next file needs, 2026-10-03.** Two instruments were used for
the first time here and both corrected something.

**The shim is not in the built module.** `fp_read` and `fp_write` are
`static inline` and nothing in the tree calls them, so the compiler drops
them and neither `kernel_read` nor `kernel_write` appears among the
module's undefined symbols. Checked rather than assumed: the module
carries 217 undefined symbols and neither name is among them, `nm` on the
object file finds no `fp_read`, and a grep of the tree finds the two
definitions and no caller. That is correct for an unused static inline and
it means the rows claiming the cluster transport's file I/O is
implemented describe a function that is not compiled into anything. It is
verified only by `test/syntax-check.c`, which references both by name so
the standalone compile checks them; nothing runs them and nothing links
to their kernel symbols until `kern_dmsg.c` lands. The rows below should
be read with that.

**The code graph says the density is where the next file plugs in.** Built
and queried in one breath, 1426 nodes and 3770 edges. The top of the
god-node ranking is `hammer2_chain_drop` 74, `hammer2_chain_unlock` 67,
`hammer2_chain_lookup` 46, `hammer2_chain_modify` 41, and those are
exactly the calls `hammer2_synchro.c` makes and nothing else: its 1069
lines drive the carried core and no transport. The graph also shows why
its degree is not a caller count: `hammer2_chain_drop`'s 74 edges include
`CHANGELOG.md`, because the extractor counts a document that mentions a
symbol as a referencing node. The authoritative caller set is the
semantic index's, which returns about 30 sites, all of them in
`hammer2_chain.c`, each with its enclosing symbol. Graph degree ranks what
to read first; it does not count callers.

**What `hammer2_synchro.c` needs, counted rather than guessed.** Its 35
distinct `hammer2_*` calls resolve against the port as follows: 26 exist
already, 5 are its own functions, and 4 are real gaps. Three of the four
are `hammer2_thr_break`, `hammer2_thr_signal` and `hammer2_xop_start_except`,
all of which live in DragonFly's `hammer2_admin.c`, a file this port
already carries: its XOP half is here and its thread-management half is
not, so the work is extracting a thread API over `kthread`, not writing
one. The fourth is `hammer2_primary_sync_thread` itself, which is the
file's own entry point.

So the plan holds and is now measured: `synchro.c` needs a thread API and
the two primitives already added, and no transport.

**The thread shim, and the same dead-code caveat as the transport,
2026-10-03.** The worker-group API the cluster's sync code needs is now
here, and like the transport shim it is not yet in the module.

`lwkt_create()` is DragonFly's thread creation, from its prototype at
`sys/sys/thread.h`: the function, its argument, where to store the
thread's identity, a template, flags, a cpu and a printf-style name.  It
is Linux's `kthread_create()` with two differences that matter rather
than being stylistic.  The kernel's call returns an ERR_PTR and does not
start the thread, so this stores the task and then wakes it.  And a
kthread that returns from its function has had its task_struct freed
unless someone holds a reference, so the create takes one with
`get_task_struct()` and the teardown is `kthread_stop_put()`, which is
the join.  That pair is gfs2's; DragonFly's own `kdmsg_iocom_uninit()`
instead polls a pointer its reader NULLs, and carrying that poll would be
a use-after-free on Linux.

The two function shapes differ and the adapter is explicit rather than a
cast.  DragonFly's thread bodies are `void (*)(void *)` ending by return,
which its `lwkt_exit()` turns into a thread exit; `kthread_create()` wants
`int (*)(void *)`.  A struct carrying the function and its argument, and a
trampoline that calls one and returns 0, is the whole of it.  The
arguments are freed by the thread itself, at the last moment it can still
use them, and by the create if the create fails: DragonFly has no such
object because its `struct hammer2_thread` carries everything and outlives
the thread, and this one does not.

**The caveat.** `nm` on the built module finds no `kthread_create`,
`get_task_struct` or `kthread_bind`, because nothing calls `lwkt_create()`
yet and the compiler drops an unreferenced static inline.  It is checked
by `test/syntax-check.c` and by the shim gate, which counts 61 inlines, all referenced. It is
not in the module.  The same is true of `fp_read`
and `fp_write`, recorded above.  That is the honest state of both: written
against their originals, type-checked, and not yet load-bearing.

**What this completes.** With `lwkt_create`, `ssleep` and `curthread`, the
port has every primitive `hammer2_synchro.c` and `hammer2_ccms.c` call
except the twelve `hammer2_thr_*` functions and `hammer2_xop_start_except`,
which live in DragonFly's `hammer2_admin.c`, a file this port already
carries in part.  Nothing in the transport is on their path.

**synchro.c's prerequisites, counted, and the one that is infrastructure
rather than a function, 2026-10-03.** The twelve `hammer2_thr_*` functions
are carried and `synchro.c`'s unresolved calls fell from nine to seven,
and six of those seven are the file's own functions, which arrive with it.
The seventh is `hammer2_xop_start_except`.

**It is not one function.** Read at the forge it is 106 lines whose real
dependencies are the worker-thread pool: `pmp->xop_groups[]`, an array of
thread groups each holding one thread per cluster element;
`pmp->has_xop_threads` and `hammer2_xop_helper_create(pmp)`, which builds
them; `xop->collect[i].thr`, a thread field on the XOP's FIFO; and the
partitioning constants `hammer2_xop_mod`, `_xgroups`, `_sgroups` and
`_xbase`, plus `mycpu->gd_cpuid`, `ip1->ihash` and
`hammer2_spread_workers`. None of the six is in this port, checked
rather than assumed.

That is the thing `README.porting.md` records as deliberately absent:
"the XOP thread pool replaced by synchronous XOPs", the FreeBSD port's
choice this one followed. So `hammer2_xop_start_except` cannot be carried
without either carrying the pool or writing its synchronous equivalent,
and that is a design decision and not a port step.

**What `synchro.c` uses it for decides which.** Three call sites, all
with a cluster index: two start an `ipcluster` XOP to fetch a peer's
chain for one element, and one starts a `scanall`. Each is a *targeted*
start, "every element except this one", which is what the `notidx`
argument means, and it is how a master reads what a slave holds without
reading its own copy. The port's synchronous `hammer2_xop_start()` has no
such argument and no per-element routing.

So the honest state of the plan is that the shim is complete and the next
step is a decision: carry the worker pool, or extend the synchronous
start with a targeted form. The reading that decides it is whether
`synchro.c`'s three callers need a thread per element or only the routing,
and that is answered by attempting the second and measuring, which has not
been done.

**The decision taken, and synchro.c's prerequisite set closed,
2026-10-03.** The entry above ends by naming the decision and not taking
it. It is taken here: the port carries the routing and not the pool.

`hammer2_xop_start_except()` is now the synchronous start with an excepted
index. Upstream needs that index because a worker thread drawn from a pool
must not be asked to fetch the cluster element it is itself standing on;
this port runs the storage function in the caller, so the index selects
which elements to run and nothing else. The three callers in `synchro.c`
start an `ipcluster` or `scanall` XOP for the elements other than their
own, which is how a master reads what a slave holds, and each of those now
runs here in turn.

What the pool would have bought is overlap, and the port does not overlap
XOPs except strategy ones. That is the same order recorded in
`README.porting.md` when the pool was replaced, and this is the second
place the choice pays: the first was the read path, where a pool would
have serialized a file's reads across the CPUs.

**The set is closed.** Recounted after this, `synchro.c`'s 35 distinct
`hammer2_*` calls leave six unresolved and all six are the file's own
functions: `hammer2_primary_sync_thread`, `hammer2_sync_destroy`,
`hammer2_sync_insert`, `hammer2_sync_replace`, `hammer2_sync_slaves` and
`hammer2_update_pfs_status`, each verified to be defined in `synchro.c` at
the forge. So the file has no external prerequisite left. What would land
it is `synchro.c` itself, 1069 lines, and with it the thread API and the
shim both become load-bearing for the first time.

**synchro.c carried, and the set above was not closed, 2026-10-03.** The
count above covered `hammer2_*` calls and nothing else. The first compile
of the file in the module found what it did not count: `tsleep_interlock`,
`PINTERLOCKED` and `wakeup`, DragonFly's three-argument `kmalloc` and
two-argument `kfree`, `kprintf`, `hammer2_debug`,
`HAMMER2_ERROR_EINPROGRESS`, a prototype, and the FreeBSD port's
six-argument `hammer2_chain_next()` against upstream's seven. The compiler
was the instrument the count should have been.

Carrying it found four defects in what the previous entries had written
and type-checked but never run. The shim's `tsleep` ignored its channel, so
the sync thread's frozen sleep, a timeout of zero, returned at once and
spun. `hammer2_lkc_sleep_nolock()` waited on a condition of `false`, so a
wake re-tested, found it false and slept on, and only the timeout or a
signal ended it. `hammer2_thr_wait_any()` compared the negative errno that
function returned against a positive one. `lwkt_create()` took the task
reference that makes `kthread_stop_put()` a join, and nothing called
`kthread_stop_put()`. All four are gone: `tsleep` and `wakeup` are the
`wake_up_var()` pool, the interlocked sites are `tsleep_word()`, the
thread API is upstream's text again with those sites marked, and
`hammer2_thr_delete()` joins. `README.porting.md` has the reasoning.

`printk` has no `j` length modifier (`lib/vsprintf.c` at v7.3-rc5 knows
`l L h H z t`), so upstream's four `%016jx` prints would have stopped at
the first conversion. `gcc -Wformat` said so and they are `%016llx`, the
FreeBSD port's spelling.

Upstream's `hammer2_sync_slaves()` discards the result of every
`sync_insert`, `sync_replace` and `sync_destroy` and of its own local scan,
then sets the slave inode's `modify_tid` to the master's, so a slave that
failed to take a chain is recorded as synchronized and no later pass
retries it. Its own comment asks for the rollup. The port keeps the first
such error and treats it as a failed collect, marked `XXX`.

Readings, `artix-s6-kde` on `h2debug-rc5` (lockdep, kmemleak), module
loaded with `debug=0x8000`:

| run | reading |
|---|---|
| `pfs-create -t SLAVE` before `ioctl.c` took every type | `EOPNOTSUPP`, the BSD ports' refusal, so the thread could not be reached |
| lone SLAVE `SL`, after | thread `h2nod-SL` in state `I` at creation; passes at 219.80, 224.93, 230.05 and 235.17 s, every 5.12 s, each `sync_slaves error 0` |
| unmount 0.1 s after a pass | 0.029 s, where a lost wakeup costs the 5 s left in the sleep; no `h2nod` afterwards; `rmmod` 0.19 s; `0 inode, 0 chain, 0 modified, 0 dio`; kmemleak, 0 hammer2 reports; no lockdep report |
| mounting the lone SLAVE | refused: no master, no quorum. The refusal reached the user as "permission denied", because the root-inode collect's `HAMMER2_ERROR_EIO`, bit 1, left the mount unconverted and read as `EPERM`. Converted; not re-run |
| MASTER `CL` on `vdb` with 55 files written, then SLAVE `CL` with the same cluster id created on `vdc` | `h2nod-CL` started; six passes and 59 `syncthr: update inode` lines in 30 s, the copy the files can only have had from the thread, since they were written before the slave existed |
| the unmount of that cluster | wedged. `sysrq-d`: the periodic sync's worker held the `CL` root's inode lock from `hammer2_vfs_sync_pmp()`; the sync thread and `umount` waited for it |

The wedge is `hammer2_xop_start()`, not `synchro.c`. It took the inode
dependency once per cluster element, as the FreeBSD port does, and the
retire releases it once; a second element found the first's set and slept
on it with a timeout of zero. Two MASTERs sharing a cluster id reached it
before this change. It now takes the dependencies once per XOP, which is
what the retire pairs with, and the same in `hammer2_xop_start_except()`.

**Not run:** the cluster test again after that fix, the slave's files read
back off its image by `hammer2 recover` and compared with the 55-entry
manifest, `fsck_hammer2` on both images, and the KASAN build. The guest
steps that would have run them were declined by the session's permission
classifier, and the run waits for one that is not. Replication stays
`unavailable` in the capability table until they pass.

**An adversarial read of the carry, 2026-10-03.** A second model read the
diff with the kernel source of record and upstream beside it, edited
nothing, and attacked the wake path, the join, the lock order and the
rollup. It refuted a lost wakeup in `tsleep_word()` against
`kernel/sched/wait_bit.c` and `prepare_to_wait_event()`, a double or early
`kthread_stop_put()`, and a deadlock between `hammer2_pfsfree_scan()`'s
freeze and the thread's pass. It found the per-element inode dependency
independently, in the tree before the fix above had landed in it. Its other
findings and what became of each:

| finding | disposition |
|---|---|
| `hammer2_pfsalloc()` takes the root inode with the acquire that warns if it waits, and an existing PFS's root can be held by its sync thread or a mount | fixed, but not as proposed. The proposal was to start the thread after the unlock, on the premise that `hammer2_mntlk` serializes every `pfsalloc()`; `hammer2_ioctl_pfs_create()` and `_snapshot()` call it without that lock, so the root inode's lock is what keeps two calls from starting two threads, and it stays. The root inode this call created keeps the warning acquire; one that existed takes `hammer2_mtx_ex_unordered()`, the same acquire without it |
| `pfsfree_scan()` syncs, then freezes, so a pass between them modifies chains the unmount's final sync never saw | fixed: freeze first, marked `XXX`; upstream has the original order |
| two comments false: "nor a thread that clears its own identity" in the `lwkt_create()` block, and `tsleep()` "at its one caller", where there are three | fixed |
| a slave that fails every pass logs every 5 s | kept: the cadence of upstream's own collect errors, and a degraded replica worth a line per pass |
| upstream reads `chain->bref.modify_tid` before testing `chain` for null in `hammer2_sync_slaves()` | recorded for the upstream note; unreachable here, the thread being deleted before its element's chain is cleared |

**A security review of `ec92e6b`, 2026-10-03.** An automated review named
four issues; a second reader reproduced each against the commit. The
`pfs-create` type check had been removed with nothing in its place, so
root could store NONE, which the cluster code reads as an empty slot,
SUPROOT, or any byte, on media: confirmed, and fixed by accepting the five
cluster-element types and no subtype past AUTOSNAP. The "authorization
regression" is the same finding; every write ioctl still requires
`CAP_SYS_ADMIN`. The use-after-free it proposed, a sibling device's sync
thread running on a PFS the scan frees, does not hold: `hammer2_pfsfree()`
runs only once `nchains` is zero, every element removed and each element's
thread deleted with it, so a sibling element still present keeps the PFS.
The fourth, a MAXPHYS scratch buffer and a thread per non-MASTER element,
is upstream's shape, reachable by root mounting such a volume, and is
recorded rather than changed. The unbounded thread waits it also named are
upstream's, and a wedged pass is what the earlier entry's dependency fix
closed.

**The slave's copies were never written, 2026-10-03.** With the unmount
wedge fixed, the two-device run unmounted, and the unmount reported
`250 modified` and scrapped every chain the sync thread had copied:
directory entries with `MODIFIED|UPDATE`, indirect blocks with `ONFLUSH`
set and nothing above them flagged. Two causes, one under the other.
`hammer2_chain_setflush()` stops at the first inode chain, because a
frontend change reaches the flusher through its `hammer2_inode` on the
sync queue, whose flush bridges the boundary; the thread changes chains
directly and queues no inode, so the path from the slave's PFS root down
to its copies was never flagged. Flagging the whole path was not enough
either, measured: the mounted PFS's periodic sync clears `ONFLUSH` on its
way down and stops at every child inode, so the first sync after a pass
erased the path again and the unmount scrapped the same 250 chains.
DragonFly does not reach this, its slave being an unmounted PFS whose
chains are under its own device's flush; on this port the run had the
slave's device mounted to create it. The thread now flushes its own
element at the end of each pass, from the slave's PFS root through every
inode, in a flush transaction, and flags the path above so the next device
flush writes the volume header.

`script/cluster-sync.sh` carries the run, 17 checks on `h2debug-rc5`: a
lone SLAVE's thread idle at `I`, three passes in 12 s, its unmount 284 ms
after a pass, no thread left, restarted by a remount and stopped by
`pfs-delete`; a MASTER with 55 files and a SLAVE created after them on a
second volume, 58 inode updates, the cluster unmounting with nothing
scrapped, `rmmod`, no warning or lockdep report, kmemleak empty, both
volumes clean by `fsck_hammer2`, and the slave's final count by `fsck`
equal to the master's, 61 inodes, 120 data blocks, 57 directory entries.
The indirect-block count is left out of that comparison, a slave building
its tree in insertion order. The first version of the check compared
whole volumes and failed by one inode, the lone SLAVE's root, which the
run had left on the master's volume; the run now removes it with
`pfs-delete`, which is also the teardown path that stops a thread through
`hammer2_pfsdealloc()`, so the comparison is the cluster's and the
failure was the test's.

`hammer2 recover` was tried for reading the slave's files back by path and
found nothing on either volume, the master's included, so it is not the
instrument for a volume written this way and the comparison is `fsck`'s
counts. Not run: the KASAN kernel, two masters, and a master changed while
the slave stays mounted.

**The cluster run on the sanitizer kernel, 2026-10-03.** `cluster-sync.sh`
on `h2kasan-rc5` (KASAN inline, UBSAN), module built against
`~/kernels/linux-7.3-rc5-kasan` with 20 `__asan` imports: 17 checks 0
failed, the same counts as the debug kernel, the lone SLAVE's unmount 374
ms after a pass, the slave's 61 inodes, 120 data blocks and 57 directory
entries equal to the master's. The script's report check read `WARNING`,
`BUG:` and lockdep's two phrases and not `UBSAN:`, so a UBSAN report would
have passed it; it reads all four now, and read 0. The guest's grub
default is back on `h2debug-rc5`.

**A slave kept in step through change, and three defects only that found,
2026-10-03.** Every run before this one copied files onto an empty slave,
which is `sync_insert` alone. `cluster-sync.sh` now changes the master
after the first copy, with both volumes mounted: ten files and a
directory removed, five files rewritten at new sizes, five added and one
renamed, which is the destroy, replace and insert paths. It compares the
cluster's PFS on the two volumes from `hammer2 -v show` rather than by
totals: every directory entry's name, inode and type, every inode's size
and type, every data block's key and check code. Planting a changed check
code or a missing entry in a copy of the fingerprint fails the comparison,
so a pass is not the comparison being blind.

The first run oopsed on the sanitizer kernel. `hammer2_xop_strategy_write`
ran its completion once per cluster element, so the second element ended
writeback on a folio the first had already ended it on, and
`folio_end_writeback()` met `VM_BUG_ON_FOLIO(!folio_test_writeback)`. The
debug kernel, without `CONFIG_DEBUG_VM`, does not check that. Upstream has
a `finished` flag that lets the first element to complete answer for the
rest; restored as written, the debug kernel run then showed the slave
missing every data block the master had rewritten or added, 17 of 103.
Upstream's elements run in parallel and the skip is a race; here they run
in order and the skip is every time, and the skipped slave is never
caught up, because the inode XOPs ran on it with the same transaction id
and the sync thread finds the inode current. The folio is now completed by
the last element with a chain, after every element has written it, and a
quorum still waiting at that point is an error, since no further reply
can come.

`hammer2_cluster_check()` returned `EAGAIN` for a quorum still in
progress, the port having had no `EINPROGRESS` bit until this work; the
sync thread reads `EAGAIN` as its request to drain deferrals and go
round, so it returns `EINPROGRESS`, as upstream does.

With those, the sanitizer kernel found a slab write past an array in
`hammer2_xop_feed()` from a readdir of 36 entries. The FIFO size and its
mask are the XOP's and the arrays are each element's, so growing one
element's FIFO left the other's arrays at the old size under the new mask.
Every element's FIFO now grows together, and the grow moves queued entries
to where the new mask reads them, a no-op while the start leaves a FIFO's
read index at zero. The three later NULL dereferences in that log were in
KASAN's own quarantine, freeing memory the overrun had corrupted.

Readings after all three, `cluster-sync.sh` 22 checks 0 failed on
`h2debug-rc5` and on `h2kasan-rc5`: the slave's PFS identical to the
master's entry for entry and block for block, 175 lines, 35 files and 103
data blocks; no warning, lockdep, KASAN or UBSAN report; kmemleak empty.
The single-device paths these changes run through were re-run on the
debug kernel: `test-fixtures.sh` 0 failures over 11 images, and
`test-enospc.sh` filled 2G with 0 failures, its seek, dedup, fallocate,
fiemap and file-handle exercisers all passing.

**A security review of `0fc0942`, 2026-10-03.** An automated review named
four issues and a second reader reproduced them against the commit. One
was real and is fixed: the write's completion decided whether its element
was the last by reading `ip->cluster` again, while `hammer2_xop_start()`
had chosen the elements by reading it at each iteration, and a strategy
XOP holds no inode lock, so a repoint between the two could leave the
folio completed twice, a second `folio_end_writeback()` and a second
`hammer2_trans_done()`, or never, the folio under writeback for good.
`hammer2_xop_start()` now records the elements to run in `chk_mask` once,
under the cluster spin, before any runs, and the write completes at the
highest recorded bit; an element whose chain left the cluster meanwhile
replies EIO and still reaches the completion. The FIFO relocation was
found correct, reproduced in C over windows with a zero, nonzero and
wrapped read index. The `EINPROGRESS` change was found unable to reach
userspace: every frontend collect follows a start in which each element
has fed, so no master is still in progress. A cluster grown after an
XOP's allocation would have its new element skipped silently; it warns
now. Readings: `cluster-sync.sh` 22 checks 0 failed on `h2debug-rc5` and
`h2kasan-rc5`, `test-fixtures.sh` 0 failures, `test-enospc.sh` filled 2G
with 0 failures.

**The sibling sweep after 0.9.64, 2026-10-03.** The fix in `baaa941`
closed one unsynchronized read of an inode's cluster, so the rest were
looked for: 73 reads of `nchains` across eight files, each one read. Two
sit outside the cluster spin where the inode lock is not certainly held.
One is upstream's, in `hammer2_xop_inode_flush()`, whose loop
deduplicating volume headers by `hmp` reads `ip->cluster.array[]`; its
body cannot run while a cluster has one element, the flush XOP is
serialized by its inode dependency and its caller holds the inode, and it
stays as upstream has it. The other was this port's own.

`hammer2_xop_start_except()` read `ip1->cluster.nchains` and the chain
array with no spin held, where `hammer2_inode_repoint()` writes both under
`ip->cluster_spin`, and it bounded its loop by the inode's element count
rather than the XOP's, so an element appended after `hammer2_xop_alloc()`
would be run and fed into a FIFO never allocated for it. Upstream reads
the same array under `pmp->xop_spin` and marks in place that it is not
stable without one; this port replaced the worker queue that spin also
covered and dropped the spin with it. Of the three implementations of
this selection, upstream's locked, the `hammer2_xop_start()` fixed in
`baaa941` locked, and this one did not.

Upstream's `hammer2_xop_start()` is `hammer2_xop_start_except()` at a
notidx of -1. This port's is now the same, so the selection, the inode
dependencies and the recorded `chk_mask` exist once rather than in two
copies free to drift. The fold also makes the `ECONNABORTED` feed on an
inactive XOP mandatory: with `chk_mask` recorded before any element runs,
the old `break` would leave recorded bits whose FIFOs nothing fills, and
a collect waits on them. `chk_mask` is a `uint32_t` and
`HAMMER2_MAXCLUSTER` is 8, so the completion's shift reaches 8 of 32
bits.

A stale claim went with it. `hammer2_assert_cluster()` in `hammer2.h`
said no multi-chain volume had been built here and that the single-chain
path was what every measurement in this file runs. `cluster-sync.sh` has
built a MASTER and a SLAVE sharing one cluster id across two devices
since 0.9.61, which is a PFS of two root chains, and its readings are
recorded above. What remains carried and reviewed rather than exercised
is more than one MASTER, where the quorum passes decide an answer instead
of agreeing with the only master present.

Two readings of the instruments came out of the same sweep, neither a
code defect. clang-tidy's `bugprone-sizeof-expression` fires on
`READ_ONCE(thr->td)` in `hammer2_thr_delete()`. `thread_t` is `struct
task_struct *`, and the `sizeof` the check objects to is inside
`compiletime_assert_rwonce_type()`, an assertion that the access size is
supported rather than a size computation; `__native_word` is already true
for a pointer, so that branch does not decide. One of the port's ten
`READ_ONCE` sites is on a pointer, so this is a single site and not a
class. Second, `compile_commands.json` held 16 of the module's 17 source
files, `hammer2_synchro.c` having been added after it was last generated,
and a caller search for `hammer2_xop_start_except()` through the semantic
index returned one of four callers rather than reporting that it could
not answer. `grep` had four. `make compile_commands.json` now builds it
from the `.cmd` files a build leaves, using the kernel of record's own
generator, and `doc/README.testing.md` carries the instrument with the
reason no gate can require it.

Readings: `cluster-sync.sh` 22 checks 0 failed on `h2debug-rc5` and again
on `h2kasan-rc5`, the slave's PFS identical to the master's entry for
entry and block for block, 0 of 175 lines differing, 40 inodes, 103 data
blocks and 36 directory entries on each, both volumes clean by
`fsck_hammer2`, nothing scrapped, no warning, lockdep, KASAN or UBSAN
report, kmemleak empty. That gate greps for report patterns and does not
check that the module carries the instrumentation which produces them, so
an uninstrumented build would pass it in silence; the module under the
sanitizer run was read instead, `vermagic 7.3.0-rc5-kasan` with 18
`__asan` and 3 `__ubsan` imports. The fold sits on the path every XOP
takes, so the single-device paths were re-run on the debug kernel:
`test-fixtures.sh` 11 images, 43 files, 0 failures, and
`test-enospc.sh` filled 2G with 0 failures, its seek, dedup, fallocate,
fiemap and file-handle exercisers 12, 3, 16, 11 and 9 checks with none
failed, the unmount leaving 0 inode, 0 chain, 0 modified and 0 dio
allocated. Eleven gates green, syntax 73 checks 0 failed, checkpatch
unchanged at 1240.

**Two of cluster-sync.sh's checks could not fail, 2026-10-03.** Both
`fsck_hammer2` checks were written

    check "fsck_hammer2 $(basename "$img")" $? "exit $?"

and the command substitution in the same command replaced the status the
`$?` was meant to read, so both reported `exit 0` whatever `fsck_hammer2`
returned. Reproduced against a command returning 8: the old shape prints
`ok ... exit 0`, the corrected shape, which captures the status into a
variable before anything else runs, prints `FAIL ... exit 8`. Every
reading of that gate recorded in this file before this entry therefore
counted 22 checks of which 20 could fail. Re-run after the fix, the two
checks evaluate and `fsck_hammer2` does exit 0 on both volumes, so the
claim they were carrying was true and merely untested. A sweep for the
shape across `script/*.sh` found this one line and no other: the safe
form, where the substitution sits in an earlier command and the `$?`
reads the test that follows it, is what the other 14 occurrences are.

**The sanitizer reading could not fail either.** The gate greps dmesg for
`KASAN:` and `UBSAN:` and never checked that the module carries the
instrumentation which emits them, so a module built against a kernel
without KASAN passes it in silence however broken it is. The kernel
tree's `CONFIG_KASAN` is now compared against the built module's `__asan`
imports, which fails in both directions rather than only on an absent
report: want and have disagreeing either way is a failure. Controls at
all four combinations: configured with 18 imports passes, configured with
0 fails, unconfigured with 0 passes, unconfigured with 18 fails. In
place, the debug kernel reports 0 `__asan` with the KASAN and UBSAN
patterns explicitly saying nothing there, and the sanitizer kernel
reports 18 `__asan` and 3 `__ubsan`. `cluster-sync.sh` is 23 checks, 0
failed on both kernels.

**The two-master quorum, 2026-10-03.** The configuration the quorum code
decides for had never been run. A PFS with one master short-circuits,
since `hammer2_cluster_check()` agrees with the only chain there is; with
two, `pfs_nmasters` is 2, the quorum is `pfs_nmasters / 2 + 1` and so
both, and every lookup has to agree across both chains.
`script/cluster-quorum.sh` builds it: a MASTER PFS on one volume and a
second MASTER of the same cluster id on the other, assembled by mounting
both volumes' ROOT, since the super-root scan calls `hammer2_pfsalloc()`
once per PFS root chain and the second call appends at nchains.

The fake pass that mattered here is a second volume silently unseen,
which would leave an ordinary single-master mount passing every write,
read and `fsck` in the run. Two readings separate them. The support
thread count is the first: `hammer2_vfsops.c` skips that thread for a
MASTER element only when `pfs_nmasters` is 1, so one master and one slave
give one thread and two masters must give two, and two is what the run
reads against `cluster-sync.sh`'s one. The second volume's own media is
the second, fingerprinted and `fsck`'d separately rather than through the
mount that would answer from either.

It passed on the first run, which the thread machinery in 0.9.61 did not.
Readings, 20 checks 0 failed on `h2debug-rc5` and on `h2kasan-rc5`: a
36-character cluster id shared, the second MASTER accepted, both volumes
recording their PFS as MASTER, 2 support threads, the cluster's PFS
mounting, 24 of 24 files written through the quorum and 24 of 24 read
back by checksum, a clean unmount with no thread left and nothing
scrapped, the module unloading, no warning, lockdep, KASAN or UBSAN
report, kmemleak empty, both volumes clean by `fsck_hammer2`, each
holding all 24 files by its own media with 38 data blocks, and the two
fingerprints differing on 0 of 88 lines. The sanitizer module carried 18
`__asan` and 3 `__ubsan` imports by the check above.

What this does not reach is a quorum that cannot be met: a master absent
from a cluster whose quorum counts it. That is the half of a quorum which
decides rather than agrees, and the question to settle before asserting
anything about it is what upstream does when a master leaves, since the
expectation has to come from the original rather than from what this port
happens to do.

**The quorum's read-back compared nothing, 2026-10-04.** An adversarial
audit of the documents describing 0.9.66 found that `cluster-quorum.sh`'s
"every file reads back through the quorum" counted the lines `md5sum`
printed and never compared them with anything: the sums were copied to
the host and not read, and the read ran in the same mount straight after
the write, so the page cache answered it rather than a lookup through the
cluster's chains. Any file that opened passed. The 0.9.66 readings above
that say 24 of 24 files read back by checksum are therefore 24 of 24
files that opened, which is weaker than they read.

The set is now made off the volume and summed before it is written,
copied in through the cluster's mount, read back after an unmount and
`drop_caches` with the PFS mounted again, and compared sum for sum on the
host, with both files required to hold 24 lines so two missing copies
cannot compare equal. `H2_QUORUM_CONTROL=1` appends a byte to one file
after its sum is taken, so what is written differs from what was summed.

Readings: `h2debug-rc5` 22 checks 0 failed, 0 of 24 sums differing from
the source's; the control on the same kernel 22 checks 1 failed, exactly
that check, 1 of 24 sums differing, exit 1; `h2kasan-rc5` 22 checks 0
failed, the module carrying 18 `__asan` and 3 `__ubsan` imports and no
report. The two masters agreed in every run, so this reads agreement
reached and not a disagreement decided.

What the cache drop establishes is narrower than "read from the media".
Unmounting the cluster's PFS frees its superblock, so its file pages and
inodes go and each lookup after the remount is a new XOP across both
chains. Both volumes' ROOT stay mounted throughout, so both devices and
the PFS itself live across the remount, and nothing here reads an I/O
count showing the blocks came off the device rather than from what the
devices still held. A second audit also found the guest never removed an
earlier run's sum files, so a run stopping before it wrote its own would
have compared the earlier pair; the run fails on its other checks then,
but this one check read ok. The guest script now removes both first. A
third audit found the cluster-PFS mounts before the write and before the
read-back carried no failure guard, so a failed mount left the set on the
guest's root filesystem, where the write and the read-back both read ok:
both now exit on a non-zero mount status. A fourth audit then
found the kmemleak check could report nothing on a real leak. A guest
whose kmemleak was switched off by an earlier control run answers every
`echo scan > /sys/kernel/debug/kmemleak` with `EPERM` until a reboot, and
nothing here read the scan's exit status; the `grep -c hammer2` then
printed 0 and the check read ok. In `cluster-sync.sh` `rmmod` ran
before the scan, so the report's `%pS` resolved the module's symbols to
`0x...` addresses and matched only allocations by a process named
`hammer2`, which the utility also is. Both scripts now scan once after a
6 s wait for the scanner's own 5 s age rule (kmemleak.c MSECS_MIN_AGE),
before rmmod, read the scan's exit status, and fail on a refusal. The
unmounts that end `cluster-quorum.sh`'s guest run now fail it on a
non-zero status, as `cluster-sync.sh`'s chained ones already did. Each
mount has its own superblock (`sget_fc()` with no test function, in
`hammer2_vfsops.c`), so a write mount that failed to unmount does not
serve the reread through a shared superblock; what it would share is the
PFS's chains in memory, which a cache drop leaves alone. That case is
caught by the thread count and the unload after it rather than by this
guard, which tops the stack and sees only the reread mount.

Readings, both on `h2debug-rc5` and `h2kasan-rc5`: `cluster-quorum.sh`
22 checks 0 failed, kmemleak 0 and usable; `cluster-sync.sh` 23 checks 0
failed, kmemleak 0 and usable. A KASAN control run with `echo off >
/sys/kernel/debug/kmemleak` first: 22 checks 1 failed, exactly the
kmemleak-unusable check, exit 1. A reboot restored kmemleak, so a fresh
kernel enlarges this check and the next run's passes.

Getting the run started found a second defect, in both cluster scripts.
A stopped guest is attached with `--config`, and both scripts detached
only with `--live`, which does nothing to a stopped domain, so a
persistent attachment left by an earlier run made the next attach fail
with "target vdb already exists", reported as COULD-NOT-RUN with virsh's
message sent to /dev/null. Both now detach both halves and print virsh's
error when an attach fails. `cluster-sync.sh` after that change: 23
checks 0 failed on `h2debug-rc5` and on `h2kasan-rc5`.

## SEEK_DATA on a file not yet written back called its data a hole

Upstream disabled `FIOSEEKHOLE` in `0d0182bdb4` (2025-11-17, "hammer2 -
disable FIOSEEKHOLE"): the blockref tree may lag a file's buffers just
after a write, so a seek between the write and the next flush can answer
wrongly, and `grep` on DragonFly's dports was the consumer that found it.
This port's `hammer2_llseek()` asks the same tree and nothing else, through
`hammer2_xop_scanall()`, and a written block enters that tree at writeback,
in `hammer2_xop_strategy_write()`, not at `write(2)`. The question was
whether that window is open here.

**`test/hammer2-seek.c` could not see it.** Its file was built and then
`fsync()`ed before the first probe, so every block was in the tree by the
time anything was asked. That is a test written to a shape the consumer
does not use: `cp` asks where the data is in a file it may have been handed
a moment after the write. The exerciser now builds the same file a second
time, one block of data, one of hole, one of data and a truncate past it,
and asks five questions of it before anything has synced it. `lseek(2)`
lets a filesystem report a hole as data, so the bounds are one-sided: a
SEEK_HOLE may land late and a SEEK_DATA early, but no answer may call
written data a hole. 12 checks became 17.

Controls, which need no module: `tmpfs` and `btrfs` on the host (`/tmp`,
`$HOME`) and on the guest (`/tmp`, `/root`), 17 checks 0 failed on each
of the four.

**Before the fix**, `KDIR=$HOME/kernels/linux-7.3-rc5 bash
script/test-enospc.sh` at `4cfa009` with the new exerciser, guest on
`h2debug-rc5`: the twelve synced checks passed and all five unsynced ones
failed.

| unsynced probe | answered | contract |
|---|---|---|
| `SEEK_DATA` at 0 | -1 (ENXIO) | 0 |
| `SEEK_DATA` inside block 2 | -1 | 131082 |
| `SEEK_DATA` inside the hole | -1 | 65636..131072 |
| `SEEK_HOLE` at 0 | 0 | 65536..229376 |
| `SEEK_HOLE` inside block 2 | 131082 | 196608..229376 |

The whole file read as a hole. A copy that trusts those answers produces
a file of the right size holding zeroes, and reports success.

**The fix** writes the mapping back from the offset's block before the
scan when any folio in it is tagged dirty or under writeback, and waits.
That suffices because `hammer2_xop_strategy_write()` ends a folio's
writeback only after `hammer2_write_file_core()` has assigned its chain,
inside the same synchronous XOP, so a folio whose writeback has ended is
in the tree. NFS 4.2 does the same in `_nfs42_proc_llseek()`
(`fs/nfs/nfs42proc.c` in the kernel of record). The alternative the
kernel's own seek helpers take, asking the page cache through
`mapping_seek_hole_data()`, is not open to a module: the symbol is not in
the kernel of record's `Module.symvers`, so it can be reached only from a
build that is part of the kernel, which is the state this port is headed
for and not the one it is in. `doc/README.roadmap.md` records the
deferral and the trigger. The wait is
`filemap_fdatawait_range_keep_errors()`, so a writeback error stays for
`fsync` to report; a failed writeback answers the whole file as data,
which the contract permits and which cannot call data a hole. A mapping
with nothing dirty costs two tag tests.

**After the fix**, the same gate on the same guest kernel: seek 17 checks
0 failed, the five unsynced answers exact rather than merely in bounds
(0, 131082, 131072, 65536, 196608), the 2 GiB fill 0 failures, kernel
warnings 0 and module faults 0 after the run marker, and dedup, fallocate,
FIEMAP and file-handle exercisers unchanged at 3, 16, 11 and 9 checks.
Lockdep was live for the new writeback-from-`llseek` path and reported
nothing. Not run: the KASAN build, a user-mode fill, and the rest of the
seek matrix the completion plan names (mapped writes, a snapshot taken
while dirty, compressed and deduplicated files, concurrent writers, a
crash between write and seek).

**P1's second reading.** Eighteen probes joined the exerciser: one byte at
65535, 65536 and 65537 in a file three blocks long, each asked synced and
not; a file written, synced, shrunk to half a block and grown back to
three, asked synced and not; and a byte written through a `MAP_SHARED`
mapping with no `msync()`, whose folio is dirtied at the fault. The first
draft bounded each `SEEK_HOLE` below by the end of HAMMER2's 64 KiB block,
and `tmpfs` and `btrfs` failed five checks against it, ending the data at
their own 4 KiB as `lseek(2)` allows; the bound was the driver's
granularity rather than the contract, so it became the byte after the one
written. Corrected, 35 checks 0 failed on `tmpfs` and `btrfs` on the host
and on the guest. On the port, the same gate on `h2debug-rc5` with the
fix in: seek 35 checks 0 failed, the mapped byte found at 131072 and its
hole at 196608, the 2 GiB fill 0 failures, kernel warnings 0 and module
faults 0 after the run marker. The mmap exerciser's SIGBUS in the log is
the refusal of a mapped write on the full volume, which the gate expects
and which every run of the day shows. The control is the same gate with
`hammer2_vnops.c` put back to `4cfa009`, the module without the fix and
the exerciser with all thirty-five: 13 failed, exactly the five original
unsynced probes, the six unsynced one-byte probes and both mapped ones,
every one answering ENXIO for data or a hole at the data's own offset,
while all the synced probes passed. The regrown file passed unsynced
there too, which is expected rather than a gap: it is synced before its
two truncates, and a truncate changes the tree directly.

**P1's third reading.** `script/seek-matrix.sh` covers the three cases a
file on a mounted volume cannot: a snapshot of a file that is still dirty,
a file sharing its blocks with a sibling, and a hard stop. Each runs on a
scratch volume attached to the guest, with `virsh destroy` for the stop
and `fsck_hammer2` on the image before the reboot. The first draft passed
37 probes and still asked too little in two places. Its dedup pair was one
64 KiB block each, so "the second file costs under a quarter of the
first" held at 1 block against 0, a reading consistent with sharing and
equally with luck. Its crash file was written and not synced, so recovery
dropped it and the case printed a pass on the file's absence. In that run
the hole walk the case exists for read nothing. The second draft wrote 16
blocks per dedup file from one generator restarted per block, and the
first file cost 1 block, the 16 blocks having deduplicated against each
other inside it; the case failed, rightly, since no sharing between the
two files had been measured. The generator now continues across blocks,
so each block in a file is distinct and the two files are identical. The
crash file is synced in the seek shape and then extended unsynced, so the
synced part survives and the walk reads the result. Measured 2026-10-06 on
`h2debug-rc5`: 31 checks, 0 failed. The second dedup file cost 1 block
against the first's 16. The file recovered from the stop was 229376 bytes
with 2 hole ranges, each reading back zero. `fsck_hammer2` was clean.
Unmount and unload returned 0, with no BUG, oops or warning in the log.
`test-posix.sh` refused the first version of the script, because it read
one remote block per file and took the second for part of the first; its
extractor now reads both, and a quote planted in the second block fails
it. Still open in P1: concurrent writers.

**P1's compression check was inverted.** The phase that proves
compression really happened before asking the seek questions under it read
`bz < 2 * bsize / 512 || bn < 0 || bn >= bz`: it failed when the zlib file
was SMALLER than the file under none and demanded the none file hold at
least two blocks, which is backwards for both tests. A reading of 256
blocks of 512 under none against 4 under zlib, compression working, was
reported as "nothing was compressed". The condition could pass only when
the zlib file was at least as large as the uncompressed one, so every
earlier green on it was green on a falsified premise, and the pre-push
hook refused the push that carried it. It is now
`bn < 2 * bsize / 512 || bz < 0 || bz >= bn`: the file under none must
hold both its data blocks, and the zlib file must be smaller. A truth
table over the five readings confirms the corrected form passes the
working case and still fails a setcomp that did nothing, a `written_blocks`
failure, and a none side that lost its data. Measured 2026-10-06 with the
correction, `KDIR=linux-7.3-rc5` on `h2debug-rc5`: compression 256 blocks
of 512 under none against 4 under zlib, seek-checks 41, seek-failures 0,
the fill 0 failures.

## SEEK_HOLE called every small file a hole, and cp wrote zeros

Found by running xfstests' `generic/001` against the port, which failed
with "Error: corruption for sub/j ... Binary files sub/j and sub/j.last
differ". Reproduced outside xfstests in three commands: `fill` a 512-byte
file, `cp` it, and compare. `dd` and `cat` copied it correctly, `cp` and
`cp -a` produced 512 zero bytes.

The discriminator was which operation asks where the holes are. `cp` calls
`SEEK_HOLE` at 0 to decide whether to read at all; `dd` and `cat` do not.
On a 512-byte file the port answered `SEEK_HOLE(0) = 0`, which says the
whole file is a hole from the start, so `cp` skipped the read, created a
file of the right length, wrote nothing, and reported success.

`SEEK_DATA(0)` on the same file answered 1338, and 1339 on the next call,
a different value for the same file. Both answers came from the scan in
`hammer2_llseek()` reading `sxop->head.cluster.focus->bref.key` after a
scan that found nothing. A file of 512 bytes or less keeps its data in the
inode's own metadata with `HAMMER2_OPFLAG_DIRECTDATA` set and has no
blockref tree, and `hammer2_chain_next()` reports EOF for such an inode
rather than walking sub-chains that do not exist. The scan had no answer
and returned an unset key anyway.

Measured before the fix on `h2debug-rc5`, `test/hammer2-seek.c` extended
with the embedded case: 49 checks, 8 failures, exactly the eight probes on
1-byte and 512-byte files, `SEEK_DATA at 0` reading 1338 and 1339 where 0
was asked. Files of 1024 bytes and larger were correct, so the defect is
bounded by `HAMMER2_EMBEDDED_BYTES`.

The fix answers from the format's own flag rather than from the tree: a
file with `HAMMER2_OPFLAG_DIRECTDATA` set is data from 0 to `i_size`, so
`SEEK_DATA` returns the offset asked and `SEEK_HOLE` returns `i_size` for
any offset below it. That is the same test `hammer2_chain.c` uses to
report EOF for the case, and it is one guard before the scan. Measured
after: 49 checks, 0 failures, and `cp` of a 512-byte file byte-identical
to its source. `tmpfs` and `btrfs` pass the same 43-check exerciser on the
host, which is where the expected answers came from rather than from this
port's own behavior.

The exerciser that existed before this did not catch it, and the reason is
worth keeping: its file is three 64 KiB blocks, so every probe was on a
file large enough to have a blockref tree. A test whose subject is always
past the boundary the defect lives behind does not test the boundary.

## fallocate failed on an empty file and destroyed data on a full one

Both found by xfstests, on the first batch run through `script/xfstests.sh`.

**An allocate on an empty file returned EIO.** generic/436, xfstests' own
`SEEK_DATA`/`SEEK_HOLE` sanity suite, aborted at its setup with "ERROR 5:
Failed to preallocate". The suite probes for unwritten extents with
`fallocate(fd, 0, 0, 2 * alloc_size)` on a new file. On this port the
call returned EIO, and the kernel log carried `chain key 0 above read at
1000` from the WARN_ONCE at `hammer2_read_folio()`, reached from
`hammer2_fallocate()` through `read_mapping_folio()`. The allocate read
and zeroed each folio of the range and only then extended the size, so on
a file of size 0 it asked for a block the inode did not yet have. A
controlled contrast confirmed the order: the same call on a file already
`ftruncate`d to 131072 returned 0 with no warning. The size change now
runs before the folios are touched.

**An allocate over existing data zeroed it.** generic/013's fsstress
tripped the same warning, at `read at 22000`, and reading why showed that
an allocate does not need to touch the folios at all. Its postcondition is
that the range is allocated and reads back, and the bytes already in it
stay. The folio loop zeroed every range for every mode. Measured: a plain
allocate over a written 200000-byte file left all 200000 bytes zero on
this port, while `tmpfs` kept them. The loop now runs for a punch and a
zero range only.

**Why the existing exerciser missed both.** `test/hammer2-fallocate.c`
ran its only plain allocate at offset `total`, past the end of the file,
so it exercised an extend and nothing else. It gains two checks: an
allocate over a range that holds data, compared with what the file held
just before the call, and an allocate on an empty file. The first draft of
the data check compared with the pattern the file was first written with,
which the earlier punches had already zeroed. It failed on `tmpfs` and
`btrfs` as well as here, and it now compares with a read taken just before
the allocate. With the correction both references pass all their checks,
16 on `tmpfs` and 18 on `btrfs`. On this port before the fix the data
check failed, 18 checks with 1 failure. After the fix it reads 18 checks,
0 failures, the 200000-byte reproducer keeps its data, and the kernel log
has no warning.

**xfstests before and after these three fixes**, the same thirteen generic
tests on `h2debug-rc5`. Before: 8 passed, 5 failed (013, 028, 285, 436,
445), and the kernel log held four warnings. After the seek fix and the
first fallocate fix: 11 passed, 2 failed. generic/028 failed with exit 127
because `src/t_getcwd` had not been built: the `make` that built the suite
stopped at `src/locktest`, which does not compile against the kernel of
record's `fcntl.h`. `make -k` builds every other target.

**The enospc gate could not attribute its counts after an early exit.**
The push carrying the fallocate fixes reported `test-enospc.sh`
COULD-NOT-RUN: "the run marker is not in the capture". The gate streams
`/dev/kmsg` into `/tmp/kmsg.log` on the guest and starts the stream before
`insmod` and `mount`. An earlier run that day had stopped at its mount,
because a scratch volume of this session's own held `/dev/vdb`. It
returned through the block's early `exit 0`, which never reached the
`kill $kpid` at the end, and that capture kept running. The next run
truncated the file, and the orphan went on writing at its own offset of
247957. The result held 68695 NUL bytes and two replays of the ring, so
`grep` called it a binary file and printed "binary file matches" instead
of the line number. The anchor came back empty, and both fault counts were
reported as could-not-run. That result was correct, but it came from the
gate's own leftover process. The capture is now stopped by a trap on every
exit from the block. A capture from an earlier run, found by the file it
writes, is stopped before the new one starts, and the anchor is read with
`grep -a`. The next run read kernel warnings 0 and module faults 0 after
the marker, seek 49 checks and fallocate 18 checks with 0 failures, and
the fill 0 failures. The five `hammer2_chain_testcheck: failed` lines in
that boot's ring name block `0x9020010`, which is f9's deliberately
flipped byte, recorded in the fixture table above. They are not a fault
of this run.

## smatch, first run, with each candidate triaged

`script/smatch.sh` runs smatch through kbuild's own checker hook, `make
C=2 CHECK="smatch --project=kernel"`, which is how the kernel's
`smatch_scripts/kchecker` runs it. A scratch module with a planted double
free is reported first, `error: double free of 'p'`. Without that control
a count of zero would show only that smatch printed nothing. Measured
2026-10-06 against linux-7.3-rc5: 17 files checked and 13 candidates.

Each candidate was checked against DragonFly's tree,
`dragonfly-hammer2-upstream/sys/vfs/hammer2`, by finding both the line
smatch read as a NULL test and the line it read as the dereference in the
upstream file, with whitespace ignored.

| candidate | both lines upstream | disposition |
|---|---|---|
| `hammer2_freemap.c:936` `hammer2_freemap_adjust()` | yes | carried |
| `hammer2_xops.c:1074` `hammer2_xop_inode_create_det()` | yes | carried |
| `hammer2_chain.c:668` `hammer2_chain_lastdrop()` | yes | carried |
| `hammer2_chain.c:2883` `hammer2_chain_create()` | yes | carried |
| `hammer2_flush.c:858` `hammer2_flush_core()` | yes | carried |
| `hammer2_flush.c:1058` `hammer2_flush_recurse()` | yes | carried |
| `hammer2_inode.c:451` `hammer2_inode_chain_and_parent()` | yes | carried |
| `hammer2_vfsops.c:400` `hammer2_pfsalloc()` | yes | carried |
| `hammer2_synchro.c:501` `hammer2_sync_slaves()` | yes | carried |
| `hammer2_cluster.c:201` `hammer2_cluster_check()` | no | port text, upstream's logic |
| `hammer2_synchro.c:828`, `:975`, `:1032` | yes | carried, layout only |

The `hammer2_cluster.c` row is the one place the text differs, and it
differs only in spelling. Upstream writes `cluster->pmp->pfs_types[i]`.
The port, restored from DragonFly at `a9a7a14`, writes `pmp->pfs_types[i]`
after `pmp = cluster->pmp`. Both trees carry the same `nquorum = pmp ? ...
: 0` and the same `KKASSERT(pmp != NULL || cluster->nchains == 0)` before
the loop, so the `switch` runs only when `nchains` is nonzero and `pmp` is
therefore set. Smatch reads the conditional as a NULL test and does not
connect it to the assertion, which compiles to nothing without
`HAMMER2_INVARIANTS`.

The rest follow two upstream shapes. One is a pointer tested in one
branch and dereferenced in another that only runs when it is set, for
example a `chain` checked after a lookup that the caller has already
established returns non-NULL. The other is a `hammer2_debug` print under
an `if` at the same indent, which is how DragonFly writes them. None of
the thirteen is a defect of this port. Because the code is carried, they
stay as upstream wrote them. That is the same rule `analyze.sh`'s
candidates follow.

One of them shows what a line comparison cannot. In
`hammer2_inode_chain_and_parent()` the loop reads `chain->parent` on a
path where `chain` was set to NULL, which happens when `clindex >=
ip->cluster.nchains`. Upstream has the identical loop. Every caller passes
an index below `nchains`, so the path is unreachable in both trees, but
nothing in the function enforces that. This is the same latent shape the
completion plan's P3 and P4 work on the cluster index will meet, and it
is recorded there rather than patched here.

## A negative offset answered EINVAL, and the probe could not tell

xfstests generic/448, the second half of its seek sanity suite, failed at
case 18, "Test file with negative SEEK_{HOLE,DATA} offsets". On a file of
size 0 it asks `SEEK_HOLE` and `SEEK_DATA` at -1 and at `LLONG_MIN` and
expects ENXIO for all four. The port answered EINVAL, from a
`return (-EINVAL)` on `offset < 0` at the top of `hammer2_llseek()`.

The references disagree, so the contract was read from the kernel of
record rather than taken from any one of them. `iomap_seek_hole()` and
`iomap_seek_data()` return ENXIO on `pos < 0 || pos >= size`, and ext4
and xfs reach both through iomap. `generic_file_llseek()` compares the
offset as unsigned in `must_set_pos()`, so a negative offset reads as past
the end and gets ENXIO. tmpfs answers ENXIO. btrfs answers 65536 for
`SEEK_HOLE` at -1: `btrfs_file_llseek()` makes no negative test and
`find_desired_extent()` takes its no-holes quick path before testing the
offset. That is btrfs's own departure and not the contract. The port now
returns ENXIO for any offset before the start or at or past the end.

**The port's own probe could not see the defect.** `probe_enxio()` in
`test/hammer2-seek.c` checked only that `lseek` returned -1, and every
lseek failure returns -1. The four new negative-offset probes passed on
a module built without the fix, which answers EINVAL to each, so the
check was satisfied by any refusal at all. The probe now checks errno as
well. With that change, the module without the fix fails all six
negative-offset probes with errno 22, the module with it fails none, and
tmpfs passes all 49 checks. btrfs fails the two `SEEK_HOLE` probes on a
non-empty file, for the reason above. Every earlier ENXIO probe in the
exerciser had the same blind spot, so none of the three at `i_size`
could ever have told ENXIO from EINVAL either.

**xfstests' `seek` group, all eight tests** (285, 286, 436, 445, 448,
490, 539, 706), measured 2026-10-06 on `h2debug-rc5` with the fix: 8 of 8
passed, kernel log `bug 0 oops 0 warn 0`. Before it, 448 was the one
failure.

## xfstests: the sized tests, a test that never ended, and a pass that was not one

**Every test was counted as passed, including those skipped.** `check` prints
"Passed all N tests" whether or not the N executed. A test that skips with
`_notrun` is counted among them. The first concurrency batch through
`script/xfstests.sh` (generic/038, 269, 300, 371, 391, 586, 748) read
"Passed all 7 tests" and the wrapper reported success, but all seven were
skipped. The wrapper now counts the executed tests as the tests run minus
those not run, and reports a batch where none executed as COULD-NOT-RUN.
Those seven skip for real reasons: O_DIRECT (300, 391, 586), user xattrs
(748), a 10 GB scratch (038). Two of them, 269 and 371, skipped because
the adapter had no sized format step.

**The sized format step.** `_try_scratch_mkfs_sized` had no hammer2 arm.
`newfs_hammer2 -s` takes a size with a unit suffix and refuses a volume
below 1 GiB, so a byte count failed with EINVAL. The arm passes the size
in MiB and reports a request below the floor as not runnable, which is
what it is. generic/269 asks for 512 MiB and 371 for 330 MiB, so both
remain skips, now for the right reason.

**generic/274 ran for an hour.** It fills a 2 GiB scratch volume with
`dd if=/dev/zero` and expects ENOSPC. This format stores no all-zero
block: `hammer2_write_file_core()` sends one to `zero_write()`, which
deletes the chain. The fill therefore never consumes space. After 44
minutes the file was 8.2 TB long with 0 blocks, the volume was 1% used,
the writer was in D state in `balance_dirty_pages`, and the flush worker
was at 40 minutes of CPU in `hammer2_xop_strategy_write()`, sampled
through sysrq-l at `hammer2_strategy.c:1555` and `:1557`. No lock was
held across the wait and no hung-task report was printed. It was a writer
being throttled behind writeback that could keep pace with it only by
doing nothing. The test cannot be met on this format. xfstests already
has the mechanism a filesystem uses for this, `_require_no_compress`,
which btrfs answers when compression would keep a fill from reaching
ENOSPC. The adapter answers it for hammer2, which compresses by default
and stores no zero block. Seven tests ask it: 027, 274, 275, 352, 427,
747 and 793, and each gives its reason as data-space usage the writes do
not consume.

**Each test now runs under its own bound**, `H2_XFSTESTS_TIMEOUT`,
default 900 s, and a test killed there is a failure. The control is the
bound set to 5 s against generic/001, which returns exit 1 and names
the test. Before the bound, a hung test left `check` running on the
guest after the host's ssh was killed. It held both scratch volumes
mounted, so the next run could not attach them and reported
COULD-NOT-RUN. The wrapper now stops a `check` left by an earlier run
before it starts.

**The quick group, measured 2026-10-08** on `h2debug-rc5`, the fixed
module: 646 tests, 590 passed, 26 failed, 30 not run, kernel log clean.
The failures are three classes and the not-runs are all declared
absences. Two of the classes are recorded elsewhere in this section and
one is new:

- `generic/393` was a real defect and is fixed: a truncate inside the
  inode left the embedded bytes past the new size in `u.data`, and a
  later extend read them back. `hammer2_inode_chain_sync()` now clears
  the embedded data on a shrink while DIRECTDATA is set, as it already
  did when the file grew past the embedded size. The exerciser's
  embedded case, run from a file that was never larger than the embedded
  size, failed 1 of 21 checks on the module before the fix and passes
  after, and `generic/393` passes.
- `generic/009`, `255` and `679` are the format's own answer: a
  preallocated range is not stored, so FIEMAP reports a hole where the
  expected output has an unwritten extent, and the file's content after
  the allocate, which is the part that detects corruption, matches byte
  for byte. This is the disposition recorded for 679 below, reached by
  two more tests.
- The rest are not this filesystem's to pass: `003`, `313`, `423` and
  `258` read `st_atime`/`st_ctime` and the nanosecond ordering of
  `statx` timestamps, which this port does not store as the tests
  expect; `131` needs `src/locktest`, which does not build against the
  kernel of record's `fcntl.h`; `228`, `306` and `409`/`410`/`411` are
  `->fallocate` past `s_maxbytes`, `->freeze` while read-only and the
  same device mounted twice, each a surface this port does not carry or
  declares; `092` and `467`/`478`/`519`/`604`/`610`/`634`/`732`/`738`
  and `796`/`797`/`798`/`676` are recorded with the test's own reason in
  the run's output. A reader should treat this list as the work queue
  for the next pass, not as a clean sheet.

**The sized batch, measured 2026-10-06** on `h2debug-rc5`: generic/269,
273, 274, 275, 488, 558 and 679. 273 and 488 passed. 269 skipped on the
1 GiB floor, 274 and 275 on `_require_no_compress`, and 558 because the
format has no fixed inode count. 679 failed on one line, the count of
unwritten extents after an allocate over a file with two holes: 0 here
where 2 are expected. That is the format's own answer, the one
`hammer2_fallocate()` describes. A preallocated range is not stored, so
it reads back as a hole and FIEMAP has no unwritten extent to report.
The file's content after the allocate, which is the part of the test
that detects corruption, matched byte for byte. Kernel log: bug 0, oops
0, warn 0.

## P1's last case: a writer and a seeker on the same file at once

`test/hammer2-seek.c` gains `concurrent()`. A forked writer fills 64
blocks of a file in order without syncing, pausing 2 ms after each, and
publishes how many it has finished through a shared counter. The seeker
reads the counter, then asks `SEEK_HOLE` and `SEEK_DATA` at 0. A block
below the counter was finished before the question was asked, so the hole
may not start inside it, and `SEEK_DATA` at 0 must be 0. The number of
questions that overlapped the writer is asserted to be at least the number
of blocks, since a seeker that never overlapped would pass without testing
the race. Before the pause was added, `tmpfs` finished all 64 blocks while
the seeker asked twice, in one run of three.

Measured 2026-10-06, five runs each. `tmpfs` gave 33723 to 38716 answers
and `btrfs` 46057 to 47695, none calling a finished block a hole. On
`h2debug-rc5` the current module gave 143 to 199 answers in five runs,
none wrong, and 56 checks with 0 failures each time. The answer count is
lower here because each question writes back what is dirty before it
scans. The control is the module built from `4cfa009`, before the
writeback-before-scan fix. It failed all five runs, every answer wrong,
3086 to 3146 of them. With one block done, `SEEK_HOLE` at 0 answered 0
and `SEEK_DATA` answered ENXIO. The kernel log had no warning in either.

That closes P1's list: unsynced, boundaries, regrown, mapped, compressed,
in the inode, negative offsets, concurrent writers, a dirty snapshot,
shared blocks and a hard stop. The six of those that the exerciser asks
on its own run in every enospc gate. The other three run under
`script/seek-matrix.sh`. xfstests' `seek` group passes, all eight tests.

## A storm cycle filled the volume before its time was up

`test/hammer2-storm.c` runs mapped writers, write-then-fsync writers,
fdatasync batchers and readers on one set of files at once and checks
every 4 KiB cell against the last write it received, after a remount with
the page cache dropped. `script/storm.sh` drives it in cycles, and the
first version sized a cycle by the clock, `H2_STORM_SECS` (300 by
default). A cycle then filled an 8G volume in seconds and died on the
allocator's reserve check: the run printed `storm-fail pwrite failed at
file 6 cell 110 (errno 28 No space left on device)`, `run exit 1` and
`storm-failures 73`, and every check after that was a reading about a run
that had been cut off rather than about the load.

The cost is the finding. Read from the module's own `alloc_data_bytes`
and `alloc_meta_bytes`, one 4 KiB cell write allocates about 80 KiB: the
write allocates a fresh 64 KiB block and rewrites the inode's indirect
blocks beside it, and nothing is freed until bulkfree runs. Measured over
10 s of the load, `data=4357521408 B` against `write-ops=53363`, which is
81658 B per write op. Upstream DragonFly allocates `chain->bytes` at the
identical site (`hammer2_freemap_alloc(chain, chain->bytes)` in
`hammer2_chain.c`, `chain_modify`), so this is the carried core's
behavior and not a port regression. The cost is read from the module's
own `alloc_data_bytes` and `alloc_meta_bytes`, which are cumulative, so
a cycle's spend is the delta across it.

An earlier version of this entry said `df` could not see the cost,
because `statfs` reports `voldata.allocator_free` and that field was
taken to be a bulkfree-only figure. That is wrong: `hammer2_freemap_alloc()`
decrements `allocator_free` on every allocation at bitmap granularity
(`hammer2_freemap.c`), and `hammer2_vfs_enospace()` reads the same field
to refuse a write, so the ENOSPC refusals this very run recorded could
not have fired if it were static. The reading that was taken as support
(`df` unchanged across a 512 MB write) was a write this format does not
store, since a block of zeros is not written. The correction is recorded
rather than the passage deleted, because the wrong reading is the kind
that reads as evidence.

A cycle is now bounded by the volume. The first cycle runs for
`H2_STORM_PROBE` seconds and its own cost counter says what a second of
the load spends; every cycle after it gets the seconds that half the
volume buys at the worst rate the run has seen, not at the probe alone.
A run sized from one probe produced cycles spending several times the
budget (its figures were from a run whose log was not kept, so they are
not repeated here as numbers); the worst rate, the largest spend over
the seconds that cycle ran, only ever shrinks the next cycle. The budget
is a target and not a cap, and the overshoot is not bounded: a cycle
whose rate rises above every rate the run has seen spends over the
budget by the ratio of the two, so a rate the run has never seen can
spend past the volume, which is why the run prints the most any cycle
has spent and a cycle that reaches the reserve fails its own checks
rather than passing quietly. An assumed rate is a rate that is
wrong on the machine the run is on: the first version of this sized a
cycle from 700 operations a second and the load did 5100, so the budget
arithmetic was fiction, and a second version that allowed four fifths of
the volume for data alone lost 9 of 24 cycles to ENOSPC by chance, a
cycle spending 7.95 GB against 7.81 usable above the reserve.
Measured 2026-10-08 on `h2debug-rc5`, 24 cycles: exit 0, every cell whole
after each remount and cache drop, `fsck_hammer2` clean, and the kernel
log clean on all six counters (`bug 0 oops 0 warn 0 kasan 0 ubsan 0
lockdep 0`), log kept at
`/mnt/storage/hammer2-fixtures/hammer2-verification-20261008/storm-soak-24cycle.log`.
The largest cycle spent 4.35 GB against a 4.29 GB budget,
which is a target and not a cap, so the run prints the most any cycle has
spent. The exerciser's own controls: `--selftest` is 6 cases including a
dead cell-lock holder, and a build with that check disabled fails it.

Re-measured 2026-10-09 on the script as it now stands, 8 cycles: 0 failures,
every cell whole after each remount and cache drop, `fsck_hammer2` clean,
kernel log clean on all six counters, and the run's output written beside
its image rather than to a path the next run overwrites. The per-cycle
spends, in GB: 2.68, 4.60, 4.29, 3.94, 4.49, 3.44, 3.70, 3.43, the worst
4.60 GB against the 4.29 GB budget, a seven percent overshoot, with
per-cycle rates from 535 to 641 MB/s. The earlier 8-cycle sizing run, log
kept at
`/mnt/storage/hammer2-fixtures/hammer2-verification-20261008/storm-sizing-check.log`,
shows rates from 197 to 217 MB/s and a worst spend of 4.12 GB, so the
rate moves between runs as well as between cycles; no single log shows
both extremes, so no factor is claimed from pairing them. The log is
kept at `/mnt/storage/hammer2-fixtures/storm.log`.

## An export served by nfsd, and a renamed file under subtree_check

`script/nfsd-export.sh` serves a HAMMER2 mount to the guest itself on
127.0.0.1 and works through the client mount, which is the path
`test/hammer2-fh.c` cannot reach: the syscalls drive the same
`export_operations` table but not nfsd's acceptance callback, and
the gate never drives `fh_to_parent`; this run reaches it from a
subtree-checked export's decode. The run
needs a kernel with `CONFIG_NFSD` and an NFS client, so a tree was built
with both (`7.3.0-rc5-nfsd`) and the guest booted it; the pinned trees are
untouched.

Measured 2026-10-08: 14 checks 0 failed, `fsck_hammer2` clean, kernel log
clean. The decode members are counted by the function tracer rather than
assumed: `no_subtree_check` reached `fh_to_dentry` 65 times and neither of
the other two, `subtree_check` reached `fh_to_dentry` 62 and
`fh_to_parent` once.

**Re-measured 2026-10-08 on the script as it now stands, 12 checks 0 failed.**
The deep file is no longer read by name before its handle is held, so the
cold-cache check is a decode of the handle and not a warm hit in nfsd's file
cache, and the run's output is written beside its image rather than to a path
the next run overwrites. `no_subtree_check` reached `fh_to_dentry` 54 times
and neither of the other two, `subtree_check` reached `fh_to_dentry` 51 and
`fh_to_parent` twice, with `get_parent` three times on the reconnect walk.
`fsck_hammer2` clean, kernel log clean on all six counters. The log is kept
at `/mnt/storage/hammer2-fixtures/nfsd-export.log`.

The first run failed one check, and the check was wrong rather than the
filesystem. Under `subtree_check` it expected a file renamed after the
client took its handle to read back through that handle; nfsd validates
the name against the parent on that export, the name is gone, and the
answer is stale. Read step by step: `get_parent` climbed inode 1026 to
1025 to 1024 to 1 and returned a dentry at every step, so the reconnect
walk succeeded; the stale answer comes from the generic
`exportfs_get_name`, which this port does not override and does not need
to, and which opens the parent and iterates it for the child's inode
number. ext4 under the same export answers the same stale, measured on
the guest, so the behavior is the export mode and not this port. The
check now asserts what the two modes are for: `subtree_check` answers
stale for a name that no longer resolves, `no_subtree_check` reads the
file because it never looks.

## The P2 readings, audited

The storm, export and voldata records above went through five rounds of an
independent adversarial audit, 2026-10-08 and 2026-10-09, each round reading
the documents, the kernel source of record and the kept logs, and mutating
the instruments. The subject findings ran 11, 8, 2, 1 and 0. Most of the
later ones were in the corrections themselves: a mechanism for
`fh_to_parent` that named file depth where the cause is a warm dentry cache,
a claimed bound on the storm's overshoot that nothing enforces, rate figures
from runs whose logs were not kept, and a cross-check in `h2-voldata.py`
that searched the wrong output and never fired. Round 5 signed off against
`4ad860d`.

What the audit did not cover: a soak of several hours on the debug and KASAN
builds. The longest kept run is 24 cycles; the 800-cycle run was stopped
before it finished. Both soaks below are that reading, and this paragraph is
superseded by them.

## The 800-cycle soak

`script/storm.sh` with `H2_STORM_CYCLES=800` on `h2debug-rc5`, an 8 GiB
volume, a 4.29 GB budget per cycle, ran 2 h 39 min to `storm: 800 cycles
over 8 files, 0 failures`. Every cycle checked all 2048 cells after a
remount with the cache dropped and reported `storm-failures 0` and
`verify-failures 0`; every cycle's two bulkfree passes and removal exited
0. One cycle of 800 spent over budget, 4.34 GB against 4.29 GB, which the
volume absorbed. The rate per cycle ran 197 to 666 MB/s. Cumulative
allocation reached 2.32 TB of data and 263 GB of meta. `fsck_hammer2` was
clean after the run, the module unloaded, and the kernel log read `bug 0
oops 0 warn 0 kasan 0 ubsan 0 lockdep 0`. Available memory after unload was
3,402,152 kB against 3,336,316 kB before. The run's own output, verdict
and `fsck_hammer2` line included, is kept at
`/mnt/storage/hammer2-fixtures/storm-soak-debug.out`; the per-cycle log it
wrote, `/mnt/storage/hammer2-fixtures/storm.log`, was overwritten by the
KASAN run below. This run was audited, and the audit is recorded below.

## The 800-cycle KASAN soak

The same command with `KDIR` pointed at the KASAN tree, on the guest booted
into `h2kasan-rc5`, ran 6 h 14 min to `storm: 800 cycles over 8 files, 0
failures`. Every cycle checked all 2048 cells after a remount with the
cache dropped and reported `storm-failures 0` and `verify-failures 0`;
every cycle's two bulkfree passes and removal exited 0. Two cycles of 800
spent over budget, 4.73 GB and 4.36 GB against 4.29 GB, both absorbed by
the volume. The rate ran 147 to 211 MB/s, about a third of the debug
build's, which is the sanitizer's own cost. Cumulative allocation reached
2.89 TB of data and 328 GB of meta. `fsck_hammer2` was clean after the
run, the module unloaded, and the kernel log read `bug 0 oops 0 warn 0
kasan 0 ubsan 0 lockdep 0`, the KASAN and UBSAN counters being the reason
this build exists. Available memory after unload was 2,606,788 kB against
2,493,792 kB before. The per-cycle log is
`/mnt/storage/hammer2-fixtures/storm-soak-kasan.log`, copied from the
overwritten `storm.log`; the script's own verdict and `fsck_hammer2` line
are printed on the host rather than into that log and are kept with the
run's full output at
`/mnt/storage/hammer2-fixtures/storm-soak-kasan.out`. This run was
audited, and the audit is recorded below.

## The busy-guest control, and both soak audits

The fixture gate's busy-guest verdict was verified live before its commit,
against a guest whose module was held by a mounted volume. The unchanged
gate at `d46b7f0^` printed `fixtures: FAIL: the module built for this
guest did not load` and exited 1; the changed gate printed `fixtures:
COULD-NOT-RUN: a hammer2 module is still in use on artix-s6-kde, so this
gate cannot load its own build` and exited 2. The held mount survived both
runs. The two control outputs are kept at
`/mnt/storage/hammer2-fixtures/fixtures-busy-control.out` and
`/mnt/storage/hammer2-fixtures/fixtures-unfixed-control.out`. With the
guest free the changed gate passed 11 images with 0 failures, its output
kept at `/mnt/storage/hammer2-fixtures/fixtures-clean-control.out`.

An independent adversarial audit of the two soak sections, the roadmap,
the capabilities table's flush row, the 1.0.4 changelog row and the
testing document's storm and fixture rows ran 2026-10-10 against
`d3419e4`: every figure recomputed from the kept log and the kept task
output, the script's sizing and verification mechanism read from its
source, and the same numbers cross-checked across every document stating
them. Round 1 returned six subject findings: the debug soak's duration
read from a log file's surviving birth time rather than the run's own
start (4 h 16 min stated for a 2 h 39 min run), the KASAN duration short
by a minute, a dead evidence pointer for the debug run's overwritten log,
a testing-document default log path that had moved, a superseded passage
not marked superseded, and an overshoot described as once when a later
rise can overshoot again. Two apparatus findings: the kept log cannot
back the verdict line the record cites it for, since the script prints
that on the host, and the busy-guest control rested on a commit message
with no log kept. All eight are corrected in this section's
neighborhood; the durations now read from the run task outputs' own
timestamps.

Round 2, against `309f2f9`, confirmed all six corrections and found one
more subject finding and two apparatus ones: two sentences still said the
soaks were not audited after they had been, the kept outputs were named
without a directory and sat on tmpfs, and the debug section pointed at a
log that cannot hold the verdict line. The run outputs and both control
outputs are now copied to `/mnt/storage/hammer2-fixtures/` beside the
per-cycle logs and named by full path, and the stale sentences are
corrected. Round 3, against `bbf25e5`, returned zero subject findings and
one apparatus finding, that the clean-run control was the one reading in
that section without a durable copy; it is now kept beside the other two.
The audit is signed off.

## The CCMS design note's state claims, re-read 2026-10-10

`doc/CCMS_DESIGN.md` was written before 1.0.6 carried the surviving
thread lock into the build, and three documents carried the sentence
that the lock "is not carried": the note's own "What the port carries
today", the capabilities table's CacheCoherence row, and the roadmap's
P3 row. All three were true when written and false from the moment
`hammer2_ccms.o` entered `hammer2-y`. No gate sees this class: the
inventory gate reads the origin table and the Makefile together, so a
carry moves both and stays consistent, and the absence gate resolves
"X is not carried" only against files that are absent, not against a
sentence in prose.

The claims the note rests on were re-read at the clone rather than
carried forward, and each resolved as recorded: `ccms_rstate_get()`'s
body at line 508 of `94491fa098^:sys/vfs/hammer2/hammer2_ccms.c` is
`cst->state = state;` under `/* XXX */`; that file is 516 lines with
its `#if 0` blocks; `topo_cst` is in `struct hammer2_inode` at
`hammer2.h` line 462; `data_cst[0]` appears at `hammer2_ccms.c` lines
117, 140, 141 and 165 and in no declaration in either file;
`94491fa098a9b62dd517fe5e5f0c8bf3315b9d5a` is dated 2015-03-22 with the
"used again when we get cache coherent in" sentence in its message.

Measured on this tree at the same date: `command grep` for the five
CCMS names over `src/` returns lines in exactly `hammer2_ccms.c` and
`hammer2_ccms.h`, 46 of them, and no line elsewhere;
`ccms_thread_lock()` is called only by `ccms_thread_lock_upgrade()` in
`hammer2_ccms.c`, so the carried lock has no caller; the origin table
records 323 and 177 lines for the two files and `hammer2-y` names
`hammer2_ccms.o`. Alternative A in the note now asks whether the lock
earns the place it has rather than whether to carry it, which is the
change the correction made to the design rather than to the record.

## The CCMS design document read, 2026-10-10

The P3 design note argued from the surviving source files alone and
concluded that the original never specified the grant protocol, offering
three positions for the maintainer to choose between. The primary source
says otherwise. Matthew Dillon's HAMMER2 design document, 2015-04-03
(v3), fetched from the DragonFly users list on this date, states the
shape directly: "Cache sub-protocol - This is the MESI sub-protocol which
runs under the Quorum protocol." Its first page carries the status
table "Quorum Protocol - under development / Cache coherency - not
specced yet," which is a statement that the protocol is documented as
spanning two halves and that this document covers one of them.

Readings taken from that document and now cited in the note: the cache
state is kept by "the servers hosting the MASTERs," so not by a separate
controller node; "the administrative controller may preemptively
downgrade a leaf with insufficient administrative rights without giving
it a chance to synchronize any modified state back," which is a
revocation path the note had listed as an undecided liveness question;
and "when the link is lost to the proxy, the proxy automatically
forwards a deletion of the state to the other nodes," which places the
burden of a dead leaf on the proxy rather than on an expiry timer.

The source was one link away, named in this repository's own
`proposals/hammer2-completion-handoff/SOURCE_REFERENCES.md`, and the
roadmap already cited the document for the direction past 1.0. The note's
error was reading the code and not the design, which is the same shape as
the error recorded above it: a claim written from one artifact without
reading the artifact that answers it. The handoff's Rule 11 forbids
weighing a modern replacement before the original is implemented and
validated, so alternative C is recorded as deferred by rule rather than
as a live option.

Two of the note's four alternatives are therefore not alternatives: B is
the design as written and C is deferred by the project's own rule. What
remains genuinely open is the quorum protocol's body (P8), which the
cache layer runs under, and the administrative-rights policy the design
leaves to administration.

## The CCMS sources are captured, 2026-10-10

Two readings in this record rest on a document that lived only on tmpfs
and a clone that is shallow: Dillon's design document, and the deleted
`hammer2_ccms.c` at `94491fa098^`. Both are now kept in the tree, under
`doc/research/primary/`, so that neither the fetch nor the object-store
read has to be repeated. The same directory holds the survey's primary
sources where they were fetched to disk.

- `DILLON_HAMMER2_DESIGN_2015.md`, from
  `https://lists.dragonflybsd.org/pipermail/users/2015-April/448614.html`,
  by `defuddle parse`. The design document begins at its own
  `HAMMER2 DESIGN DOCUMENT` heading and is dated 03-Apr-2015 (v3).
- `hammer2_ccms.c.deleted` and `hammer2_ccms.h.deleted`, from
  `git show 94491fa098^:sys/vfs/hammer2/...` in the clone at `250a8b4`.
- `hammer2.h.at-94491fa098-parent`, the same revision's header, for the
  `topo_cst` placement.
- `GFS-sosp2003.txt`, `Spanner-osdi2012.txt`, `Chubby-osdi06.txt`, the
  three source documents the survey's claims about those systems rest on.

The quorum reading was checked rather than taken from the survey. The
survey reported that no production system votes per cache grant; the
design document's `QUORUM OPERATIONS` section says the same thing in its
own terms, and the check resolved the apparent conflict between "the
cache sub-protocol runs under the quorum" and "coherence is per object."
The quorum is masters voting amongst themselves for commit, the client
excluded from that path on an explicit argument; cache state is obtained
by the client and shifted between clients under the masters'
serialization. So "under the quorum" means ordered by the commit
protocol, not granted by a vote. Both readings are now quoted in
`doc/CCMS_REFERENCE.md` with the section they come from.

Counted at the same date, over the tree at `94491fa098^`: `ccms_`
references number 19 in `hammer2_chain.c`, 18 in `hammer2_inode.c`, 10 in
`hammer2_vnops.c`, and `hammer2_ccms.c` was in the Makefile `SRCS` line
before the deletion and absent after. The lock was the core's lock
interface, not a coherency-only structure, which is the correction to the
"no caller" framing that the survey's arrival made worth restating.

## The survey's sources captured and its quotations checked, 2026-10-10

The comparable-systems survey behind `doc/CCMS_REFERENCE.md` cited twelve
documents, of which three had been kept. The other nine are now captured
in `doc/research/primary/`, each with its URL and extraction command in
that directory's `PROVENANCE.txt`, so the survey can be re-read without
re-fetching: the Lustre internals report, the Ceph, GPFS, Leases and
Dynamo papers, RFC 8881 and three MS-SMB2 sections. The reference now
cites every system section by section.

Seventeen of the survey's quotations were checked against the captures
rather than taken from the agent's report. Thirteen were found at once.
Four first read as missing (GFS's lease sentence, Spanner's lease-vote
sentence, GPFS's token-release sentence, Dynamo's slowest-replica
sentence), and each was present and verbatim, split across lines where
`pdftotext -layout` extracted a two-column page. A phrase search over
these captures has to join lines first, which the reference and
`PROVENANCE.txt` now both say. Section numbers were checked the same way;
one was wrong (the Leases paper's 10-second result is in 3.2, not 3) and
is corrected. One figure is marked as the survey's arithmetic rather than
the paper's: Spanner's Table 3 measures a 14.4 ms write and a 1.4 ms
read-only transaction, and the split of the write into Paxos and commit
wait is the survey's.

`test-doc-prose.sh` counted one finding as two. vale's closing summary
for a single finding reads "1 warning and 0 suggestions", and the gate's
pattern matched that line as well as the finding. It never let a defect
through, since any finding still failed the gate, but its number was
wrong and so was the selftest's ("2 finding(s)" for one planted
violation). Both counts now drop the summary line; one planted violation
reads one, a clean probe still fails the selftest, and a single real
finding planted in the corpus reads one and fails the gate.
The captures under `doc/research/primary/` include markdown (RFC 8881 and
the three MS-SMB2 sections), which `git ls-files '*.md'` put in the prose
gate's population: 246 findings, every one in text the IETF or Microsoft
wrote. The gate excludes that one directory by path, and the exclusion was
added only once it was measured to change the outcome; an earlier version
added before the RFC arrived changed nothing and was removed.

## The "not carried" claims swept after the CCMS carry, 2026-10-10

The carry of `hammer2_ccms.c` made one class of sentence false wherever it
appeared, so every tracked markdown file was swept for the "is not
carried", "absent", and "dropped by every" shapes rather than the four
files that had already been found. Four were still wrong and are
corrected; the rest were checked and hold.

- `doc/README.status.md` said the surviving thread lock "is not carried".
  It is carried and builds as `hammer2_ccms.o`. Corrected in place, since
  that document is a statement about this tree.
- `doc/research/HAMMER2_PORTABILITY_AUDIT.md` gave the file a row of
  "absent ... dropped by every port" and built its
  DRAGONFLY-INSEPARABLE conclusion on the deletion. The row is corrected
  in place and a dated correction appended, because `doc/research/README.md`
  draws the line at "a reference that resolves nowhere is a defect and a
  dated number is not": a line count from the audit's date stands, but a
  row asserting the file is absent from this port is a reference that
  resolves nowhere. The interesting result is the reverse of the audit's
  prediction, so the correction says so.
- `doc/research/H1_READING_1_SPIN_AUDIT.md` called seven sites "in
  `hammer2_ccms.c`, which no BSD port carries, so 62 are port-relevant".
  The seven are in this tree's build now; the port-relevant count is 69.
- `doc/research/HAMMER2_LICENSE_AUDIT.md` said the four clustering files
  "are not imported for H1 to H6". Two of the four are carried. The
  license half of the claim was and is correct.

Checked and left as written: `doc/README.porting.md`'s two
"not carried" claims, which `test-absence.sh` resolves against `src/` and
which resolve correctly (the two hits under `src/` are comments saying the
same thing), the capabilities table's `SelfHealing` and copies rows, the
portability audit's zero-row sentence, and `doc/research/HAMMER2_LINUX_API_MAP.md`'s
claim about FreeBSD's `hammer2.h`, which is a statement about FreeBSD and
is unaffected.

The class is only partly gateable, and it is worth naming what covers each
half: `test-absence.sh` covers a claim naming a function, and
`test-inventory.sh` covers the origin table and the Makefile together. A
sentence in prose that a file is not carried is covered by neither, which
is how all four of these survived a green sweep.

## P3 reopened, and the ports' framing taken out of the scope decisions, 2026-10-11

P3 was closed on 2026-10-10 on its design note. The work queue's exit
criteria for it are a full state-transition matrix, lockdep-clean,
concurrent access tests and a provenance record, and the verification plan
adds explicit pre- and postconditions with a negative test for every
transition. The note met one of the four. The roadmap had also rewritten
P4's dependency from P3 to P2 on the ground that P3 had nothing to carry,
which was wrong once the design document was read and wrong regardless of
it, since the carried lock owed its criteria either way.

Readings taken against the shipped `hammer2_ccms.c`:

- `doc/CCMS_TRANSITIONS.md` writes every transition the carried lock
  implements with its precondition and postcondition, and the four calls
  it refuses.
- `test-ccms-lock.sh` now extracts eight functions rather than four and
  checks 29 rows: the five release counts it had, twenty postconditions
  from that document, and four from a concurrency probe. Each
  postcondition row reads `count`, `td` and `upgrade` and requires every
  spin acquire matched by a release. A downgrade broken to leave `count`
  at 2 fails the two rows that follow it.
- `test/hammer2-ccms-concurrent.c` races the same functions across eight
  threads for 20,000 rounds each: 0 violations of mutual exclusion, the
  lock unlocked with no upgrade pending at the end, 4911 upgrades taken,
  0 sleeps ended by timeout rather than wakeup. Against the source broken
  so an exclusive acquire ignores shared holders it stranded seven
  waiters; broken so a shared acquire ignores a writer it let ten readers
  into an exclusive section and then stranded eight. The first form of
  the probe hung on both rather than reporting, so the joins are bounded
  at 60 s and a hang reports itself with the violations counted to that
  point.

Open: lockdep. Nothing in the module calls the lock, so a lockdep run on
the guest has nothing to observe. An in-kernel exercise path is P3's
remaining item, and P4 waits on it.

The same day the tree's scope decisions were read for the ports' framing.
`doc/DROPS_AND_DISABLES.md` classifies every behavior this port does not
carry against DragonFly, by Rule 12's four classes, and records that the
ports are a reference for mapping DragonFly onto an OS rather than a
ceiling on what to carry. Corrected where the framing had become a scope
claim: "Not on the roadmap: the cluster layer, before H7", the
portability audit's "dropped" rows for `hammer2_synchro.c` (carried since
0.9.61), `hammer2_iocom.c` and `hammer2_msgops.c` (P6), the capabilities
note that the seven cluster ioctls are carried by no BSD port, and the
porting and header notes that inherited the XOP thread pool's removal
without recording that multi-master needs it. The XOP pool is classified
deferred-with-trigger, the trigger being multi-master: DragonFly carries
27 references to it across three files at `250a8b4`, this port none.

One count was not reproducible and is corrected: the roadmap gave
`hammer2_iocom.c` 25 `kdmsg` calls and `hammer2_msgops.c` 4. The first
names `kdmsg` on 24 lines and calls 8 of its functions 14 times; the
second calls `kdmsg_msg_reply()` twice.

## P3's lockdep criterion: the exercise built, the guest run blocked, 2026-10-11

Nothing in the module calls the CCMS lock, so a lockdep run of the module
has nothing to observe. `hammer2_ccms.c` now carries, behind
`HAMMER2_CCMS_LOCKTEST`, two kernel threads that take the carried lock in
every way it implements, started from `hammer2_module_init()` and stopped
from `hammer2_module_exit()`, which prints the rounds they ran and the
lock's final count. `script/ccms-lockdep.sh` builds that module, loads it
on the guest, and reads lockdep, KASAN and BUG lines, with three fake
passes ruled out in its header: a lockdep already off, threads that never
took the lock, and a report read from an earlier run's window.

Measured on the host: the flagged build carries 7 `ccms_locktest`
symbols and builds warning-free against the kernel of record; the default
build carries none.

The guest run did not happen, and the reason is a reading, kept at
`doc/history/kernel-reports/2026-10-11-proc-lockdep-uaf.txt`. The guest
had been up a day and a half on the KASAN build with `debug_locks` already
0. The kernel log shows why: a KASAN slab-use-after-free in `string()`
under `print_name()` and `l_show()`, reached by a `grep` reading
`/proc/lockdep`, reading a name from a 64-byte object freed by
`load_elf_binary()`. The module was not loaded at the time and the
call trace has no frame of it; this port's lock names are string
literals or a `snprintf` into a class it keeps until unload, and none of
its `hammer2_spin_init()` calls passes anything else. So the report is
recorded as the kernel's, `/proc/lockdep` naming a class whose name
string a process image owned, not as this port's, and not filed. KASAN's
taint is what set `debug_locks` to 0, and a lockdep that is off reports
nothing on any lock, so the script refuses that state as could-not-run.

The guest was rebooted to clear it. It booted to an idle kernel, its
vCPUs halted, and did not open ssh in ten minutes; its serial console
shows `s6-log` failing to rotate `/var/log/udevd/current` in a loop, and
nothing else. That is the guest's own service state, not a module
question, since no module was loaded, and it is left for the maintainer.
P3's lockdep criterion stays open until `ccms-lockdep.sh` runs on a guest
whose `debug_locks` reads 1.

## P3 closed: the CCMS lock under lockdep, 2026-10-11

The guest that blocked the reading above was brought back with a hard
reset after an ACPI reboot left it idle on the old kernel; `debug_locks`
read 1 on the fresh boot. Its grub default had been moved to the KASAN
build once already and the reset arrived before the change was on disk,
so the guest came up on the debug build again; `grub-mkconfig` was rerun
and the root synced before the second reset. On this guest an ACPI
reboot does not complete, which is the guest's service state and is
recorded so the next run resets rather than waits.

`script/ccms-lockdep.sh`, 120 s per run:

- `h2debug-rc5`: 142,228,187 rounds, the lock ending `count 0 upgrade
  0`, `debug_locks` 1, 0 lockdep reports, 0 KASAN, 0 BUG lines, the
  module unloaded. A 60 s run before it read the same with 74,148,886
  rounds.
- `h2kasan-rc5`: 77,188,417 rounds, all seven checks the same, the module
  carrying 18 `__asan` imports by `nm`, so the instrumentation the clean
  reading depends on was present.

The control, run on `h2debug-rc5`: one `hammer2_spin_unex()` added after
each exclusive round, a release of a spin the thread does not hold, which
is the defect 1.0.6 fixed in the bad-state arms. It read 3 lockdep
reports, `DEBUG_RWSEMS_WARN_ON` and `WARNING: bad unlock balance
detected!` among them, `debug_locks` 0, the threads wedged in
`ccms_thread_lock_nonblock()` in D state and the unload refused: five of
seven checks failed. Its first run reported only a hang. The script had
read the log after `rmmod`, and `rmmod` blocked in `kthread_stop()` in D
state, which `timeout(1)` cannot kill, so the report never reached the
host. The log is now read before the unload, and the unload is attempted
in the background and judged on its own.

With this P3's four exit criteria are met for the carried thread lock:
transitions with pre- and postconditions in `doc/CCMS_TRANSITIONS.md`,
each checked with its negative cases by `test-ccms-lock.sh`, the same
functions raced on the host, and lockdep clean in the kernel on both
builds. The provenance record was met at 1.0.6. At this 2026-10-11 entry, P4 was next.

`doc/readiness-audit-2026-09-25.md` carried `->direct_IO` as an open next
step after the roadmap had decided it; it is marked decided, with the
reasoning cross-referenced.

## P4 begun: the synchronization thread's lifetime, read, 2026-10-11

The handoff's audit for P4 starts with thread lifetime and stop/join, and
this is the reading of it from the source, before any fault is injected.

- `hammer2_thr_create()` (`hammer2_admin.c`) can fail here where it cannot
  on DragonFly: `lwkt_create()` maps to `kthread_create()`, which fails on
  memory or a fatal signal to the mounting task. The carry handles that
  much, marked `XXX` in place: `thr->td` stays NULL and the scratch buffer
  is released.
- What the caller does with the failure is the open question.
  `hammer2_pfsalloc()` creates the thread only when `td == NULL`, so the
  next pfsalloc retries it, and between the two the cluster runs with no
  synchronization thread and nothing but a log line to say so. Whether
  that is correct is not decided by reading it; the handoff's
  "allocation faults" item is the measurement that decides it, and it is
  P4's first instrument.
- `hammer2_thr_delete()` signals STOP, waits for STOPPED, then
  `kthread_stop_put()`, reading `td` before the signal because the thread
  clears it itself. The thread body breaks out of its loop on STOP only at
  the top, so a stop arriving during `hammer2_sync_slaves()` waits for the
  pass or for `hammer2_thr_break()` inside the deferred loop. That bound is
  the time a pass takes, which is the second P4 measurement: an unmount or
  a `pfs-delete` during a long pass.
- The deletion sites are `hammer2_pfsdealloc()`, the PFS teardown loop over
  `cluster.nchains` and the per-device loop over `HAMMER2_MAXCLUSTER`.
  `cluster-sync.sh` covers the first two in the healthy case.

Nothing is changed yet. Each item above becomes a fault-injection reading
before it becomes a fix.

## P4 allocation faults: a failed thread create leaves a threadless SLAVE that heals on remount, 2026-10-11

`script/sync-alloc-fault.sh` is the instrument for the record's open
question above, and the question is now answered: the handling as carried
is correct and no code change is owed.

- The fault is one slab failure aimed at `hammer2_thr_create` during a
  SLAVE's `pfs-create`, through failslab on the KASAN guest (the only
  tree with `CONFIG_FAULT_INJECTION`, `FAILSLAB` and the debugfs
  controls; the debug and release trees have none). Aimed four ways:
  `ignore-gfp-wait=N`, without which the `GFP_KERNEL` allocation cannot
  fail; `task-filter` on the utility process; `require-start`/`end` on
  the function's own bytes from the built module's symbol table; and a
  large `times` budget, since a budget of one is consumed in silence by
  nested infrastructure allocations and the thread is created
  undisturbed. The landing proof is the module's own `cannot start
  thread` line.
- Nine runs aimed at the mount first and all nine measured a different,
  pre-existing failure: mounting a SLAVE label fails with root-inode EIO
  with no fault at all, which the no-fault control confirmed. The fault
  window is therefore the `pfs-create` ioctl, whose path to the create is
  ioctl, pfsalloc, thr_create.
- The reading, 10 checks 0 failed: 3 faults injected with the trace
  through `should_failslab`, 1 `cannot start thread` line, the SLAVE
  present in `pfs-list` with no `h2nod-SYNC` thread, the BASE master
  still round-tripping a write, no sync pass reporting an error, and a
  remount starting the thread, which is the retry the lifetime reading
  hypothesized. Unmount, `pfs-delete`, module unload and `kmemleak` all
  clean, no kernel warning, lockdep, KASAN or UBSAN report.
- What this decides: between a failed create and the next pfsalloc the
  cluster runs synchronization-less with only the log line, and that is
  safe, the volume stays usable, nothing leaks, and the next pfsalloc
  heals it. The `XXX` in `hammer2_thr_create()` stays as documentation of
  the difference from DragonFly, not as a defect marker.
- The second P4 measurement stands: the stop bound is one sync pass,
  still unmeasured under a long pass.

## P4 interruption: the probe built, the copy it needs not happening, 2026-10-11

`cluster-sync.sh` gained a fourth phase for the work queue's
`interrupt_resume` (the plan's interrupted and resumed convergence). It is
not closed, and this records why rather than what was hoped.

- What the phase does: create one large directory on the master with the
  slave mounted, wait for the copy to begin, wait for a pass bracket to
  open, unmount the slave, remount it, and require the copy to finish. The
  pass brackets itself in the log, `sync_slaves pfs CL` opening it and
  `sync_slaves error` closing it, and the stop is read at
  `hammer2_synchro.c:277`, the one call of `hammer2_thr_break()`, between
  deferred directories.
- A pass's length grows with the largest directory it walks. Measured on
  the KASAN guest by timing the bracket: 37 ms over an empty PFS, 40 ms at
  2000 entries, 65 ms at 8000, 418 ms at 20000. That is what makes the
  window real, and it is why the phase uses one large directory.
- The run, 33 checks 7 failed, and the failures are one finding. The copy
  of a 20000-file directory made 2 inode updates and stopped, with the
  thread alive and 113 passes over the next five minutes making none. The
  unmount therefore interrupted a copy that had already stalled, the
  remount copied nothing, and the slave ended 82 inodes short of the
  master. Nothing reported an error and no warning, lockdep, KASAN or
  UBSAN report was emitted.
- Two candidate causes were ruled out from the same run rather than
  argued. Starvation by the probe's own polling is not it: the thread ran
  113 passes and was scheduling normally while the copy made no progress.
  A guest left dirty by an earlier run is not it either, and that defect
  was found here and closed: the phase used to inherit a loaded module and
  stale mounts and report 27 failures from a run that never started, so
  the guest script now refuses with COULD-NOT-RUN and names what is left.
- What is not yet established: whether the stall is a defect in the
  thread's decision to synchronize, or a property of this workload that
  the existing phases do not exercise. Phase 3 writes to a directory that
  already exists on both sides and converges in 58 updates; this phase
  creates a directory that the slave has never seen, at the PFS root. The
  reading that separates them is the scan's own decision, which needs the
  invariants build and a print at the `want_update` test rather than
  another guess.
- The measurements this entry does carry: a pass's duration against
  directory size, the bracket as the pass's own evidence, and the fact
  that `interrupt_resume` cannot be measured on a copy that stops after
  two inodes. The probe stays in the script, failing, because a phase that
  reports the shape it cannot measure is worth more than one that was
  tuned until it passed.

## The interrupted copy's root is stamped synchronized while its subtree is short, 2026-10-11

This entry corrects the one above it. The copy of a new directory does not
stop after two inodes: the slave's media holds both directories, every
file of them, and the master's own root `modify_tid` exactly. What the
interruption leaves behind is a root whose tid has advanced past its
subtree, and the thread's gate then reads that state as synchronized
forever.

- The reading, from the volumes the interrupted run left: master root
  `mod=00000000000273b3 lfcnt=20039`, slave root
  `mod=00000000000273b3 lfcnt=19957`. Equal modify_tid, 82 fewer files.
  `fsck_hammer2`'s own totals give the shape: master 20041 inodes,
  20103 data blocks, 20037 dirents; slave 19959 inodes, 20021 data
  blocks, 20037 dirents. Every directory entry arrived and 82 inodes
  with their data did not, so the slave holds 82 names pointing at no
  file. Both volumes pass `fsck_hammer2` with exit 0, so that exit status
  does not check a dirent against the inode it names and is not evidence
  of a consistent slave; the fingerprint comparison in `cluster-sync.sh`
  is what fails on it.
  The thread's decision (`want_update = chain->bref.modify_tid != sync_tid`,
  `hammer2_synchro.c:500`) is correct for the state it reads. The state
  is wrong, and no later pass can see the gap, because the gate compares
  the root's tid and nothing below it.
- The thread's own log agrees with the media and not with the phase's
  earlier reading: 113 passes over five minutes made no further updates,
  which is what a correct gate does with an already-stamped root. The
  "copy stops at two inodes" reading was the same fact seen from the
  wrong side, and the phase's update count is not a copy count.
- The instrument that produced this was temporary and is reverted: a print
  at the `want_update` test in an `HAMMER2_INVARIANTS` build, which
  showed `want 0` on a slave whose root tid equalled the master's while
  its mounted view was empty. The print is in a carried file, so it is
  not committed.
- Two hypotheses were checked against the source and eliminated before
  being recorded. The `ENOENT` arm of the marking guard does not mark
  with deferrals outstanding: `needrescan` forces `HAMMER2_ERROR_EAGAIN`
  first (`hammer2_synchro.c:749`), so a scan that deferred content never
  stamps. And the isroot arm of `hammer2_sync_replace()` copies the
  limited field set upstream copies and nothing else, matching
  `sys/vfs/hammer2/hammer2_synchro.c` field for field, so the type change
  the slave's CL shows on media is not the sync overwriting it.
- What is not yet established: why the pass that stamped the root did not
  descend into the short directory. A second instrument run, with a print
  at the marking call and at the deferral drop (both reverted, in a
  carried file), reproduced the defect (slave 92 inodes short, dirents
  equal) and answered three things. The stop never reached the deferred
  loop: `didbreak` printed zero times, so no deferral was discarded and
  the unmount stopped the thread between passes. The root was stamped
  three times, each with an empty list on the root call
  (`STAMP inum 1 tid 51cf isroot 1 listcount 0` is the pass that copied
  the large directory's first inodes), and every non-root stamp drained
  its list in order. And the outer loop is correct as carried: it drains
  only on `HAMMER2_ERROR_EAGAIN` from the root call, which `needrescan`
  produces whenever the root scan deferred anything. The candidate this
  entry first named, the pre-recursion `sync_tid`, is refuted: the
  marking ran correctly for the state the scan saw.
- The log also contradicts this entry's own reading of the copy. After
  the pass that stamped `tid 382`, the thread scanned no inode but the
  root: 61 scans and 60 update lines in the whole run, no `START_SCAN`
  of the large directory, no deferral, no update of anything in it. Yet
  the slave's media holds 19949 of its inodes. The update line prints
  only for an inode's final marking, and `START_SCAN` only once per
  `hammer2_sync_slaves()` call, so neither counts the chains a scan
  inserts; the phase's "2 inode updates" were the root's own markings,
  not a measure of the copy. Which call copied the 19949 and why it
  stops 92 short is the open question. The instrument is already in the
  carried source: `hammer2_sync_insert()` and `hammer2_sync_replace()`
  print every chain they write under `hammer2_debug & 1`
  (`HAMMER2_SYNCHRO_DEBUG`), and the fleet loads the module with
  `debug=0x8000` alone, so that print has never run. The next run sets
  `debug=0x8001`.
- A separate fact the same runs established, and it belongs to the
  testing doc rather than to P4: a SLAVE's cluster PFS cannot be mounted
  by label at all. `hammer2_get_tree()` answers "PFS already mounted!" and
  the mount refuses, because the PFS joined a PMP at creation. Every
  reading of a cluster PFS has to come from the media, which is why the
  fingerprint checks exist.

## The missing inodes were copied and then destroyed by a root pass, 2026-10-11

The per-chain prints the carried source has always had, `insert rec`,
`replace rec` and `destroy rec` under `hammer2_debug & 1`, ran for the
first time, through `cluster-sync.sh`'s new `H2_DEBUG=0x8001`. No source
was changed. The defect reproduced (slave 81 inodes and 81 data blocks
short, 20037 dirents on both sides), and the prints account for the gap
exactly.

- The thread destroyed 81 inode chains on the slave, keys `0x10bc`
  through `0x110c`, all in one pass at 52923 s that scanned only the PFS
  root. Those keys are inode numbers of files in the large directory
  (`0x10bc` is `p3197` on the master). 81 destroyed is the 81 missing,
  and no insert of any of those keys follows.
- The destroy path is `hammer2_sync_destroy()`, which the scan takes when
  a local chain compares below the master's focus (`n < 0`), meaning the
  master's scan did not return a chain the slave held. The master's media
  holds every one of the 81, so at the moment of that pass the master's
  scan did not see inodes its own media now has.
- The thread wrote 234 chains in all, every one inside a single second,
  52831 s, during phase 2's initial copy and before the large directory
  existed. None of them names a file of that directory, and their keys
  (`0x0` to `0x5d`) share no range with the destroyed ones. So in this
  run the thread inserted none of the large directory's inodes at all,
  yet the slave's media holds 19960 of them, and the 81 the root pass
  destroyed were among those. The writer that put the directory on the
  slave is not the synchronization thread's insert path, and that is the
  next reading. A dirent key's parent cannot be read off the key itself
  (the parent's inode number is not encoded in it, as one attempt here
  assumed), so naming the directory the 81 belonged to needs the
  fingerprint's own walk rather than a key decode.
- The earlier entries' "copy stops after two inodes" and "the root is
  stamped past its subtree" both describe this from outside. The root's
  tid is the master's because the pass that destroyed the 81 completed
  without error and stamped it.

## A write through the cluster's mount lands on the slave directly, 2026-10-11

The writer the last entry asked for is the frontend itself. The slave's
CL is element 1 of the same PFS the master's CL mount serves (the thread
logs it as `clindex 1`), and `hammer2_xop_start_except()` queues an XOP
to every element with a chain, with no test of the element's type, as
DragonFly's does.

- The reading, on fresh volumes with the stock module: a SLAVE created
  in the cluster, then 300 files written through the master's CL mount
  and the volumes unmounted within seconds. `fsck_hammer2` totals are
  identical on both volumes, 305 inodes, 300 data blocks, 301 dirents.
  With the per-chain prints on, the thread made 1 pass and 0 inserts in
  that window, so every one of the 300 reached the slave through the
  frontend's own XOPs.
- That accounts for the earlier entries' puzzle: the large directory's
  19960 inodes on the slave came from the write itself, not from the
  thread, and the thread's 234 inserts were phase 2's initial copy.
- What remains open is the 81. Those inodes were written by the
  frontend to both elements, then destroyed on the slave by a later
  root-only pass of the thread, which found them absent from the
  master's view at that moment.
- A second per-chain run settles the order, and it rules the unmount
  out. 89 destroys this time, all inside one root pass at 59830 s, and
  the phase's unmount of the slave came at 60013 s, three minutes later.
  The destroying pass ran while the 20000-file write was still going on
  the master, with the slave mounted throughout. So a synchronization
  pass that overlaps a frontend write destroys inodes the frontend has
  already put on the slave and the master's scan does not yet return,
  and then stamps the root. The interruption is incidental: the
  defect is a pass racing an ordinary write, which is the plan's
  "source mutation during convergence" case, reached by accident.
- The next reading is the master side of that race: what the master's
  scan returns for the large directory during the write, against what
  its media holds after it. The interruption phase cannot close until
  that is understood, because any resumed pass can race a write the
  same way.

## A rerun hangs, and its log shows the probe waits on a count that cannot move, 2026-10-11

A rerun of the phase with `KDIR=$HOME/kernels/linux-7.3-rc5-kasan`
and `H2_DEBUG=0x8001` reported `FAIL the guest run hung past 600s`.
The guest's own output was lost with the host's work directory, so the
only record is the guest's follower log, copied off afterwards and kept
at `~/Projects/linux_hammer2-data/fixtures/cluster-hang-20261011-2320.klog`.
The script now copies that log and releases the disks itself when the
run times out.

What the log shows:

- One root pass at 70046 s destroyed 59 inodes on the slave, keys
  0xcfd through 0xd37, in 1.3 ms, completed with `sync_slaves error 0`,
  and replaced the slave's CL root with `mod=0000000000005182`. Every
  pass after it, every 5 s to 70532 s, opens and closes with no scan
  line. This is the shape of the 81 and 89 in the earlier entries.
- The thread logged 60 `syncthr: update inode` lines in the whole run.
  The two after 69955 s, at 70020 s and 70046 s, are both the CL root
  itself and no file. Phase 4's resume check waits for that count
  to grow by `NBIG + 1`, 20001. The entry above established that the
  frontend writes the large directory to the slave itself, so the
  thread has nothing to log for it and the count cannot reach the
  target. The wait is therefore its full 300 s on every run, whatever
  the slave holds.
- The three unmounts and the module's last lines come at 70534 s, about
  600 s after the log's first line at 69935 s.

Not established by this log: whether the destroying pass overlapped the
large-directory write, since the write leaves no line in the kernel log;
whether keys 0xcfd to 0xd37 are files of the large directory; and what
the master's scan returned for them. Inference, unmeasured: the hang is
the run's time budget (phases 1 to 3, a 20000-file write on the KASAN
guest, and the 300 s wait) exceeding the 600 s timeout, and not a hang
in the kernel.

Two things follow. The probe's convergence check counts the wrong
writer and must be replaced by a reading of what the slave holds. And
the next run must put the write's start and end into the kernel log, so
a destroying pass can be placed against it.

## The slave's missing inodes are the destroys made during the write, 2026-10-12

The phase now marks the large-directory write in the kernel log
(`h2probe: bigdir write start` and `end` through `/dev/kmsg`), counts
the thread's destroys between the marks, and judges the resume by two
completed passes rather than by the thread's update count, which the
entry above showed cannot grow with a set the frontend writes itself.
Run with `KDIR=$HOME/kernels/linux-7.3-rc5-kasan H2_DEBUG=0x8001
H2_RUN_TIMEOUT=1200`: 33 checks, 6 failed.

- `no pass destroys on the slave while the master is being written`:
  53 destroys inside the write.
- `the slave holds what the master holds`: master 20041 inodes, 20103
  data blocks, 20037 dirents; slave 19988, 20050, 20037. The slave is
  short 53 inodes and 53 data blocks, the number destroyed inside the
  write, and keeps every dirent. The fingerprint differs on 106 lines
  of 60177.
- `the resumed thread completes two passes`: 2 in 10 s. The remounted
  thread runs; it does not restore the 53, since nothing it compares
  says they are missing.
- `the unmount lands inside an open pass` failed, and with it
  `the interrupted slave leaves no thread` (1 left) and `the stop is
  read between deferred directories` (0 lines). Those two say nothing
  about an interruption until the unmount lands inside a pass, so the
  interruption itself is still untested.
- Kernel log clean, kmemleak 0, nothing scrapped, `fsck_hammer2` exit 0
  on both volumes, which again does not see a dirent whose inode is
  gone.

So the loss is the source-mutation case alone: a pass that runs during
a write on the master destroys inodes on the slave. What is still open
is why the pass sees them as absent on the master, and placing the
unmount inside a pass so the interruption is tested at all.

## Every destroy in the race is newer than the pass that made it, 2026-10-12

A temporary print at the `n < 0` branch of `hammer2_sync_slaves()`
(reverted, not committed) recorded each destroy's key, the destroyed
chain's `modify_tid`, `merror`, the master's focus key at that moment
and the pass's `sync_tid`. Run with `KDIR=$HOME/kernels/linux-7.3-rc5-kasan
H2_DEBUG=0x8001 H2_RUN_TIMEOUT=1200`, 33 checks, 6 failed; the guest's
log is kept at
`~/Projects/linux_hammer2-data/fixtures/cluster-destroyprobe-20261012.klog`.

- 82 destroys, all in one pass of the CL root at 75579 s, inside the
  write marked from 75548 s to 75725 s. 35 passes opened during the
  write; one destroyed anything.
- The destroyed keys are contiguous, 0xf2b through 0xf7c.
- Every line reads `merror=0` and the same focus,
  `952c5ca9c9858001`. The master's scan had not ended: it was holding
  a later key, and the slave's chains sorted before it, so the compare
  read them as extra on the slave.
- Every destroyed chain's `modify_tid` (0x7139 to 0x723d) is greater
  than the pass's `sync_tid` (0x4f31). The pass deleted chains written
  after the master state it set out to copy.
- The slave ended 82 inodes short: 19959 against the master's 20041,
  the dirents equal at 20037, the fingerprint 164 lines different.

Inference, not measured: 0x952c5ca9c9858001 has the shape of a
directory-entry hash key, and the destroyed keys are small sequential
inode numbers, so in this root the master's iterator was among the
directory entries while the slave's local iterator was among inodes
the frontend had just created, and the two sequences are compared
against each other key by key. Not established: whether these keys are
present in the master's root when its scan passes them, which the next
reading has to show.

What the measurement does settle is a guard the destroy branch lacks:
it deletes a slave chain whose `modify_tid` exceeds the `sync_tid` its
own pass synchronizes to, which no ordering of the scans can make
correct.

## The destroy guard keeps the frontend's chains and the slave converges, 2026-10-12

`hammer2_sync_slaves()` now keeps a slave chain whose `modify_tid`
exceeds the pass's `sync_tid` instead of destroying it, advances past
it, and ends the pass with `HAMMER2_ERROR_EINPROGRESS`, so the root is
not stamped and the next pass compares again. EINPROGRESS rather than
EAGAIN, because the caller re-enters the root pass at once on EAGAIN
with nothing deferred. Same command as the two entries above, the
log kept at
`~/Projects/linux_hammer2-data/fixtures/cluster-destroyguard-20261012.klog`.

| check | before (destroy probe run) | after |
|---|---|---|
| destroys inside the write | 82 | 0 |
| slave inode, data, dirent | 19959, 20021, 20037 | 20041, 20103, 20037 |
| master inode, data, dirent | 20041, 20103, 20037 | 20041, 20103, 20037 |
| fingerprint lines differing | 164 of 60177 | 0 of 60177 |
| checks failed | 6 of 33 | 3 of 33 |

No destroy at all in the run, no pass error, kernel log clean,
kmemleak 0, the resumed thread 2 passes in 10 s. The three still
failing are the unmount landing outside an open pass and the two
checks that depend on it, so the interruption is still untested.

## A flush of a PFS root finds an empty base, and the trigger is the unmount, not the write, 2026-10-12

The reworked phase 4 was meant to give the thread a backlog by writing
a second directory with the slave's ROOT unmounted. That run failed
with the guest's master mount returning EIO and 16 of 32 checks with
no data, because the guest script exited at the remount after the
host's ssh returned 255 rather than 124, so the host ran its checks,
the disk detach, with nothing to read.

The kernel log it left is real evidence. The fault is kept whole at
`doc/history/kernel-reports/hammer2-sync-work-empty-base-20261012.txt`.
An earlier file under the name
`doc/history/kernel-reports/hammer2-flush-corruption-20261012.txt` was a
232-line extract of it, and that extract is superseded and deleted, not
kept: it carried the 219 `hammer2_base_delete` lines and the ten `chain
error during flush` lines after them and nothing else, so it had no call
trace, no `WARNING`, no `Workqueue` line and none of the nine unmount
readings. Everything said below about the producer before 2026-10-12
came from frames that were not in it, and the whole log says the producer
is a different one, which is corrected here. The extract was sound for
the fault message, its repetition and the keys, and those readings stand.

The whole log is NOT the run the extract was first written up as. The
first version of this entry said the write to the master with the
slave's ROOT unmounted caused it, and the log says otherwise:

- The log carries no `h2probe` line at all, and phase 4 is what writes
  those markers, so this log cannot be from a phase-4 run. Its guest
  uptime runs 106 s to 1202 s; the marker runs run in the 76000s and
  78000s.
- No unmount of the slave's ROOT appears in it. The unmounts are at
  130, 180, 225, 259, 541, 711, 862, 977 and 1050 s, and the run's
  phases account for them.
- The run that did carry the markers, at 78526 to 78775 s, produced no
  `from empty base` at all. The mounted-slave and unmounted-slave
  controls are likewise clean.
- Reproductions built on the write (20000 files, slave mounted and
  unmounted, on both the current module and the one from `7a3c69d`)
  have not produced it either.

What the log does show, at its own times:

| guest time | event |
|---|---|
| 711.209 s | unmount |
| 720.437 s | `hammer2_chain_testcheck: failed: chain indirect 000000001709c00e ... flags 00144002`, repeating |
| 722.785, 723.041 s | two virtio-blk devices attached by the harness |
| 732.722 s | first `hammer2_base_delete: delete indirect elm 8100000000000000/56 from empty base 0000000000000000/0 not found at 128/128` |
| 733.970 s | last of 219 such lines |
| 862.796 s | next unmount |

`hammer2_unmount_scrap: scrapping unflushed data` appears at 180.652 s,
immediately after the unmount at 180.663 s, 10 times in the log. So the
first symptom follows an unmount rather than a write, and the cascade
that follows is one fault, not 219: `hpanic` marks the device in error
module-wide and returns, so every later flush drops its blocks
unwritten, which is what produces the ENOENT writes and the mount
hanging in `iterate_dir`.

**The producer is the periodic syncer, and this entry's earlier version
said the teardown.** The committed file above is a 232-line extract and
it does not carry the fault's call trace, which is what the frames were
being read from. The whole log is
`doc/history/kernel-reports/hammer2-sync-work-empty-base-20261012.txt`,
1784 lines, of which the extract is the `hammer2_base_delete` block plus
the ten lines after it; the trace is at 732.727 with the frames

    hammer2_base_delete  <- hammer2_flush_core <- hammer2_flush_recurse
      <- hammer2_chain_tree_RB_SCAN <- hammer2_flush_core
      <- hammer2_flush <- hammer2_xop_inode_flush
      <- hammer2_xop_start_except <- hammer2_inode_chain_flush
      <- hammer2_vfs_sync_pmp <- hammer2_sync_fs <- sync_filesystem
      <- hammer2_sync_work

and the line above the trace names the workqueue:
`Workqueue: events hammer2_sync_work`. `hammer2_pfsfree_scan` is not in
the log at all, so the teardown the frames were attributed to is not on
this path. What the shape is instead is this port's own syncer,
`hammer2_sync_work` at `hammer2_vfsops.c:2101`, a delayed work that
reschedules itself every `HAMMER2_SYNC_INTERVAL` and calls
`sync_filesystem()` from a workqueue thread. The flush that faults runs
22 s after an unmount that left 2602 modified chains, on a workqueue
thread rather than in the unmount that returned.

The keys deleted are block-table and directory keys, not a file range:
`8100000000000000/56`, `8200000000000000/56`, `8400000000000000/56`,
`0000000000005b80/7`, `0000000000005be6`. The 20000-file write is not
in evidence anywhere in this log.

What this leaves open, and the next reading: which unmount leaves the
PFS root's block table inconsistent with its children, and whether
`hammer2_unmount_scrap` is the path that scraps a chain the root's
block table still references. Until that is read, the write is not
implicated and no guard is written on it.

The whole log narrows that further than the extract did. It carries 455
`sync_slaves pfs CL` lines and no `LONE` line, so it is a two-element
cluster; the pass runs at 116.6 s and every pass closes with
`defer 0`; and the fault is at 732.7 s on a thread whose own `sync_fs`
is the thing that reaches it. The extract's `scrapping unflushed`
reading at 180.652 s is real but it is a second unmount's, after the
first at 130.464 s left 2510 modified chains, and the flush that faults
is 22 s past the third at 711.209 s. So the reading to take is not
"which unmount corrupts the root" but "what a syncer's `sync_filesystem`
does to a volume an earlier unmount of the same run left chains on",
which is what `kill_sb` prints unconditionally and what the counters
now let a run answer.

The module under test is named by build id, not assumed: the trace
carries `hammer2 3f6a8c17722e58602763a6b32f4504d3bdd9b699`, and the
build of `4d89d8d` against the same kernel tree carries
`srcversion 484910DDC5D95644E786D54`, so this log is not the current
tree. It is one run read twice: `stock-kasan.log` and `dbg6-dmesg.txt`
are two `dmesg` saves of the same ring, 1784 and 1828 lines with the
same nine unmounts, the same 219 misses and the same `mod 41468` chain,
the longer one ending 38 s later. Neither is the run `dbg6.klog` holds,
which is the phase-4 marker run at guest uptime 78526-78775 s and has
no `from empty base` line at all.

The probe's own defects, found by this run, are fixed in the same
commit: every mount, unmount and `rmmod` in the guest script is now
bounded with `timeout(1)`, so a wedged guest cannot leave the script
without readings; the unmount's exit status and the remount's are probe
lines of their own; and a `mounts-before` line is the first reading of
each run, so a guest that starts dirty is visible in the output rather
than only in the final count.

## Modified chains at unmount correlate with the corrupting log but do not reproduce it, 2026-10-12

The reading that separates the corrupting log from the clean runs is
the count `hammer2_kill_sb` prints after an unmount.

| run | `modified` chains at unmount |
|---|---|
| the corrupting log | 2510 at 130.5 s, 2602 at 711.2 s, 131 at 862.8 s and after |
| `dbg5` (the destroy guard run) | 0 at all six unmounts |
| `dbg6` (the marker run) | 0 at all three unmounts |
| a deliberate run with `sync` concurrent with the write | 751 at its unmount |

| guest time | event in the corrupting log |
|---|---|
| 130.464 s | unmount, 507 inode, 2515 chain, 2510 modified |
| 180.652 s | five inodes and their inline data scrapped unflushed |
| 541.915 s | unmount, 20008 inode, 40331 chain, 0 modified |
| 711.209 s | unmount, 30728 inode, 63489 chain, 2602 modified |
| 720.437 s | `hammer2_chain_testcheck` fails on `indirect 1709c00e` |
| 732.722 s | the root's flush finds the empty base |

The last row of the first table is the control that keeps the rest
honest: running `sync` every second beside the write left 751 modified
chains at its unmount, and that run then finished with 20000 files, no
`from empty base` and no `gave up`. So modified chains at unmount
correlate with the corrupting log and are neither sufficient nor, on
this evidence, the cause. The clean runs' zero is still the right
reading for a correct unmount, and the corrupting log's non-zero
counts are still unexplained.

`hammer2_unmount_scrap` is the port's own code at
`hammer2_vfsops.c:2520-2530`, run at device teardown on the VOLUME and
FREEMAP chains; the semantic index puts its only caller at
`hammer2_unmount_helper`, and the graph puts
`hammer2_pfsfree_scan -> hammer2_vfs_sync_pmp` at
`hammer2_vfsops.c:671`, so the teardown does flush through the sync
path. The scrap reports a failed flush rather than causing one.

Not established: what stops those flushes completing, whether the
corrupting log's counts and its later empty base are one fault or two,
and any reproduction on demand. The corrupting log's mount topology is
now known, and its write is not: 455 `sync_slaves pfs CL` lines and no
`LONE` line put a two-element cluster on the guest, and 30728 inode and
63489 chain at the unmount before the fault put a tree larger than the
phase's 20000 files. What wrote it is not in the log, since nothing
marks a write, and the module's own build id says this is not the
current tree; the guest was rebooted after and its uptime counter
restarted, so no later log can be placed beside it by time.

## A syncer flush over a slave's unmount does not find the empty base, and reaches a sync-insert lock cycle, 2026-10-12

The trace above says the producer is the syncer on a master mount that
stays up, so the state to build is a cluster whose master is mounted for
the whole run while the slave's volume is unmounted and left unmounted
past one `HAMMER2_SYNC_INTERVAL`. `script/sync-empty-base.sh` builds it:
4000 files written through the master's cluster mount, the slave element
joined on the other volume, 40 s for the thread to carry the set, then
unmount the slave and wait 40 s with the master still mounted, four
times.

The window opened and the empty base did not follow. At the slave's
unmount `hammer2_kill_sb` prints 3977 inode, 11908 chain and **7798
modified** chains against the failing log's 2510 and 2602, so the state
the reading asked for was reached and exceeded, the master's mount was
up throughout, the thread's syncer period elapsed four times, and
`from empty base` reads 0. The whole run's log is
`doc/history/kernel-reports/hammer2-sync-insert-lockcycle-20261012.txt`,
706 KB, and it carries no `from empty base` line, no `device in error`,
and no `gave up`.

What it does carry is three faults on the current module, which names
itself `8e4b641d441d7b9b2831a62ab2b5fe777b31aa28` where the failing log
names `3f6a8c17722e58602763a6b32f4504d3bdd9b699`, so none of them is the
log's fault:

| guest time | report |
|---|---|
| 25202.064 s | `WARNING: possible recursive locking detected`, `h2nod-CL` acquiring `h2core_indirect/2#2` while already holding it, at `hammer2_sync_insert+0x4f0` |
| 25206.991 s | `WARNING: hammer2_chain.c:4810 at hammer2_base_insert`, reached from `hammer2_sync_insert` |
| 25208.476 s | `Oops: general protection fault` in `xxh64`, `RIP: hammer2_chain_setcheck`, reached from `hammer2_flush_core` |

The first is the one to fix: `hammer2_sync_insert()` takes an indirect
chain's core lock twice. The deadlock scenario lockdep prints is
`lock(h2core_indirect/2#2)` then `lock(h2core_indirect/2#2)`, and it holds
`h2ch_inode/2`, `h2ch_indirect/2#2` and `h2core_indirect/2#2` at once,
with the second acquisition at the same `hammer2_sync_insert+0x4f0` as
the first. lockdep disabled itself on that report, so the two later
faults are reported without lock checking and cannot be attributed by
its silence.

This is a second, independent defect from the empty base, and it is on
the current tree rather than the log's older one. It is filed here as
found and not fixed: the guard belongs where the invariant is owned,
which is the insert path's own lock discipline, and the fix needs a
probe that fails before it and passes after, which is this script.

## A chain outliving its PFS, at two drop sites the 0.9.10 fix did not reach, 2026-10-12

The wedge at the end of the reproduction run is a use-after-free, and the
278 s between the flush that marked the device in error and the crash is
what hid it: the unmount had 4008 inodes to walk before it reached the
chain that faults. The KASAN report says exactly what it is.

    hammer2_chain_drop+0x147e   vmalloc-out-of-bounds, Read of size 8
      hammer2_inode_repoint
        hammer2_inode_drop
          evict
            dispose_list
              evict_inodes
                generic_shutdown_super
                  kill_anon_super
                    hammer2_kill_sb

`hammer2_chain_drop` reaches zero refs and calls `lastdrop`, which calls
`hammer2_pfs_memory_wakeup(chain->pmp, -1)` at `hammer2_chain.c:568`, and
that function dereferences its argument:
`atomic_fetchadd_int(&pmp->inmem_dirty_chains, count)`. `hammer2_pfs` is
5.2 MB and vmalloc-backed, which is why the read is reported as
out-of-bounds on vmalloc memory rather than as a page fault. The chain was
dropping long after the PFS it names had been freed.

The class is a chain that outlives its PFS while still carrying `->pmp`.
Every site that drops such a chain and every site that frees the PFS:

| site | drops a chain naming the PFS | clears `pmp` first |
|---|---|---|
| `pfsfree_scan()`, the PFS root's cluster (teardown) | yes | yes, 0.9.10 |
| `pfsdealloc()`, the root's cluster (`pfs-delete` ioctl) | yes | **no** |
| `inode_repoint(ip, NULL)`, every ordinary inode (eviction) | yes | **no** |
| `hmp->vchain` / `hmp->fchain` (device teardown) | yes | yes |

Two of four cleared it. The 0.9.10 entry in `full-volume-lock-cycle` fixed
the teardown path and recorded why: upstream's guard in `hammer2_pfsfree()`
counts `iroot->cluster.array[i].chain` and nothing else, so a chain dropped
later by another path is invisible to it. That reasoning was right and the
repair stopped one population short of it.

The second uncleared site is reachable with no cluster and no full volume:
`hammer2_ioctl_pfs_delete()` calls `hammer2_pfsdealloc()` at
`hammer2_ioctl.c:422`, which sets `HAMMER2_CHAIN_RELEASE` and drops the
root's chain with the pointer intact, and the ioctl then destroys the PFS.
All four origin trees carry that drop uncleared, so it is a carried defect
fixed here first and marked `XXX`, which is the maintenance rule.

The repair is at the invariant, not at the callers. `hammer2_chain_drop`
is reached from 59 sites across nine files, so clearing `pmp` at each is a
defect that returns with the next drop site. Instead:

  - `pfsdealloc()` clears `chain->pmp` before the drop, as `pfsfree_scan()`
    already does.
  - `pfsfree()` walks `pmp->inumhash` and clears the `pmp` of every chain
    in every inode's cluster and ccache before it frees the storage, which
    covers the population upstream's root-cluster guard cannot see.

MEASURED AFTER THE REPAIR, AND IT DID NOT FIX THE WEDGE. The run at
`sync-empty-base.sh` with both changes in the module crashed identically:
`hammer2_chain_drop+0x147e`, the same offset as before, and `umount`
exited with interrupts disabled at 271.824 s. The attribution below is
therefore WRONG as the cause of this wedge, and this entry is corrected
rather than left standing.

The faulting instruction was resolved against the build rather than read
off the stack: `addr2line` puts `chain_drop+0x147e` at
`hammer2_chain.c:646`, which is the `RB_REMOVE()` call, not the
`hammer2_pfs_memory_wakeup(chain->pmp, -1)` at line 568 that this entry
was written around. KASAN classifies the address as
`vmalloc-out-of-bounds` and says only that it "belongs to a vmalloc
virtual mapping": there is no `Allocated by task` and no `Freed by task`
block, which is not the signature of a freed object. The address sits
about one 4 KiB frame above RSP in the `umount` task, which had already
taken a fatal `Oops` earlier in the same run (`Tainted: D`).

What that means for the two changes: they are still correct on their own
merits, since a chain dropped after its PFS is freed does read a freed
`pmp` through the wakeup, and `pfsdealloc` does not clear the pointer
where all four origin trees also do not. They are kept and marked `XXX`.
They are NOT the fix for this wedge, and the sentence that called them
the repair was written before the run that tested it.

The next reading is at `RB_REMOVE()`'s own inputs, `parent->core.rbtree`
and `chain->rbe_link`, instrumented rather than guessed at a fourth time.
A fourth guess at the cause of this crash is the thing that produced the
three wrong ones.

Measured since, and it narrows the fault to a dangling pointer rather than
a deep stack: the second report in the same run is a plain page fault with
`CR2 ffffc90024ccf600`, which is the same address the KASAN report names,
and `RSP ffffc9000a02f538` in a DIFFERENT vmalloc region. A stack overrun
would have CR2 just below RSP in the same region. So the operand really is
a pointer into freed vmalloc memory, and `RB_REMOVE` is unlinking a chain
whose `rbe_link` leads into a structure that has already been freed, or a
parent whose `core.rbtree` was freed under it. That is a chain-lifetime
violation of the same family as the `pmp` one and not the same member: the
two changes clear `pmp`, which `RB_REMOVE` never reads, so neither could
have affected this address.

MEASURED, and it moves the defect out of `RB_REMOVE` and into the tree
it is handed. The probe prints the parent, the chain and its three link
words at that unlink, under `HAMMER2_LOCKDEBUG`, with the addresses hashed
through `%p` and the whole block behind the flag, since the fields it
reads are the ones that may have been freed.

The run that took it crashed exactly as before, and the operands it
printed are healthy. The last three lines before the fault are chains in
`ffff8881...`, and the fault address is `ffffc9002376f600`, a different
vmalloc region from every one of them:

    parent ffff88812e9b3800 count 125 | chain ffff88810d1b7800 key ...0403
      | link ffff8881135cf001 (null) ffff88810d1b7000
    parent ffff88812e9b3800 count 124 | chain ffff88810d1b7000 key ...0404
      | link ffff8881135cf000 (null) (null)
    BUG: KASAN: vmalloc-out-of-bounds in hammer2_chain_drop+0x1443/0x1a80
    Read of size 8 at addr ffffc9002376f600

So the operands are valid and the read is inside `RB_REMOVE` itself, which
takes the rebalance up the parent chain: `name##_RB_REMOVE()` loops on
`parent = RB_PARENT(parent, field)` at `src/sys/sys/tree.h:826` after
calling `name##_RB_REMOVE_COLOR()`. One upward step from a valid node
lands in freed memory only if a parent pointer in the tree is already
wrong, so THE TREE IS STRUCTURALLY CORRUPT BEFORE THIS UNLINK, not the
unlink's argument.

What corrupts it is consistent with everything above it in the same run:
every chain printed here carries `flags 00046102`, which is
`BLKMAPPED | BLKMAPUPD | UPDATE | COUNTEDBREFS | ONRBTREE | ALLOCATED`, and
the same run had already hit `hammer2_base_insert: insert indirect elm
0000000000000400/7 to indirect base 0000000000000400/5 overlapping at
0/32` at 114 s. Two chains left under one key in one parent's blockmap,
with one of them then linked into that parent's rbtree, is how an ordered
tree stops being ordered while every pointer in it still resolves to
something allocated. The 157 s between the `hpanic` and this fault is the
unmount walking 4008 inodes before it reached the damaged subtree.

MEASURED with `HAMMER2_LOCKDEBUG=1`, and it refutes the indirect-pair
reading. The run held the module with both probes compiled in (verified
by the format strings being present, 2 of them) and took the reading:
the held-chain dump fired ten times at `sync_insert` entry, and every one
is a SINGLE chain, `type 1` (INODE), `kb 0`, `class h2ch_inode/1`,
`depth 1`, `lockcnt 1`. The parent/focus comparison printed nothing,
because it only fires when both are INDIRECT and they never both were.

    sync_insert entry: chain type 1 key b6a9cb23fd8a8001 kb 0
      class h2ch_inode/1 depth 1 lockcnt 1     (ten lines, all alike)

So the `h2core_indirect/2#2` recursive-locking report at 110.169 s is not
two same-keybits indirect chains held at `sync_insert` ENTRY. The report's
own frames settle where they are: it names `hammer2_sync_insert+0x5dd`,
while this entry print is at `+0x4f0`, so the second indirect core is
acquired LATER in the same function, inside the `hammer2_chain_create()`
descent at `hammer2_synchro.c:879`, and is not on the stack when the
function is entered. Measuring at entry was the wrong place to catch it.

That also explains why the comparison was silent rather than negative: it
was written to fire on a parent/focus INDIRECT pair, and the pair does not
exist at the point it reads. An instrument placed where the state is
absent answers nothing, and its silence is not a refutation.

The same run wedged again: 30 `rbtree remove` lines, then the KASAN
out-of-bounds in `hammer2_chain_drop` and `umount` out with interrupts
disabled. The tree-corruption finding stands and is unaffected by this
reading.

RESOLVED, and the lock report is APPARATUS rather than a defect. The
`+0x5dd` frame resolves on the host, no guest needed, to
`hammer2_sync_setflush` at `hammer2_synchro.c:121`, reached from
`hammer2_sync_insert()` at `synchro.c:935`. That walk takes a chain's
parent's core lock while the caller still holds the chain's, i.e. child
then parent. `hammer2_spin_t` is not a Linux spinlock: it is this port's
`struct hammer2_spin_wrapper` around an `rw_semaphore`, and
`hammer2_spin_sh()` is `down_read()` on it (`hammer2_os.h:885-905`). The
comment beside it states the discipline it follows: a chain's core lock
is taken bottom-up, child before parent, which upstream's
`hammer2_chain_lastdrop()` states as the rule. So the acquisition is the
documented order being followed, not an inversion.

It is reported anyway because the class scheme keys a class on (family,
type, keybits, level) and the child and its parent here are both INDIRECT
at one keybits and one level, so two DISTINCT rwsems carry one class name
and lockdep cannot see the order between classes. The report is the cost
of that scheme, and it disables lockdep when it fires, which is why every
later fault in these runs is reported with no lock checking.

An earlier revision of this entry called that a real defect and a premise
failing. That was written from the frames alone and is wrong: the premise
it invoked is about keybits strictly decreasing ALONG one parent-child
walk, which is about the two locks' being in a nesting relation the tree
asserts, and the scheme's use of keybits as a class discriminator is a
separate, weaker thing that cannot distinguish two chains of one keybits.

What is still unmeasured, and now the whole of it: which descent inside
`hammer2_chain_create()` leaves two chains under one key in the parent's
blockmap, which is what `base_insert: overlapping at 0/32` reports and
what corrupts the rbtree the unmount later walks. The lock report is not
evidence about it and can be set aside.

`hammer2_chain_create_indirect()` was then read end to end for that
duplicate key, and what it yields is not a port defect. The new indirect
block's radix comes from `nbytes`, chosen by the parent's TYPE:
`HAMMER2_IND_BYTES_MIN` (4KB, 32 entries, keybits 5) when the parent is a
directory's inode, `HAMMER2_IND_BYTES_NOM` (16KB, 128 entries, keybits 7)
otherwise. The failing insert is `insert indirect elm 0x400/7 to indirect
base 0x400/5`, a keybits-7 child under a keybits-5 parent, and that is
exactly this selection: `ichain` was created with the keybits of a 16KB
block and inserted into the 32-entry blockmap of a directory inode. The
same computation verbatim is in DragonFly's tree, checked with `awk` over
both, so the shape is CARRIED and the design's, not this port's.

What that means for the rule at `hammer2_chain.c:3453` ("all elements
underneath it fit within its key space") is not settled here. Either the
rule holds only within one blockref type and this is a cross-type nesting
the code intends, or it is a genuine upstream defect reachable when a
directory inode's blockset splits while a data indirect is being built.
The `KKASSERT`s that would have said which are compiled out in every build
this tree ships, since `HAMMER2_INVARIANTS` is off by default, and the one
at `hammer2_chain.c:3827` (`parent->core.live_count < count`) is precisely
the precondition of the insertion that faults.

The next reading is a `HAMMER2_INVARIANTS=1` build on the same reproducer:
if the carried `KKASSERT`s hold, the insert's precondition was met and the
duplicate key arises later; if one fires, its location IS the answer and
it is upstream's. That build exists as a supported target
(`make HAMMER2_INVARIANTS=1`) and has not been run for this.

## The INVARIANTS build fires the carried assert, and it names the collision, 2026-10-12

The reading the entry above asked for has been taken. `sync-empty-base.sh`
was run with `HAMMER2_INVARIANTS=1 HAMMER2_LOCKDEBUG=1`, so the carried
`KKASSERT`s are compiled in, and it did not wedge the way the three
earlier runs did. It reached the fault and the fault announced itself.

    [  209.347182] WARNING: possible recursive locking detected
    [  209.351533] ffff888134c902a8 (h2core_indirect/2#2){++++}-{4:4}, at: hammer2_sync_insert+0x5b1/0x1150
    [  209.353972] but task is already holding lock:
    [  209.353972] ffff8881354e62a8 (h2core_indirect/2#2){++++}-{4:4}, at: hammer2_sync_insert+0x5b1/0x1150
    [  209.361947] locks held by h2nod-CL/5784: 3, last CPU#5:
    [  209.363294]  #0: ffff8881354e7090 (h2ch_inode/2){++++}-{4:4}, at: hammer2_sync_insert+0x3a9/0x1150
    [  209.366729]  #1: ffff8881354e6090 (h2ch_indirect/2#2){++++}-{4:4}, at: hammer2_chain_create_indirect+0x52a/0x1980
    [  209.368667]  #2: ffff8881354e62a8 (h2core_indirect/2#2){++++}-{4:4}, at: hammer2_sync_insert+0x5b1/0x1150
    [  212.555356] hammer2_chain_insert: collision 0000000000000400/7
    [  212.557300] kernel BUG at hammer2_chain.c:297!
    [  212.557323] Oops: invalid opcode: 0000 [#1] SMP KASAN NOPTI

with the call trace `hammer2_primary_sync_thread()` ->
`hammer2_sync_slaves()` -> `hammer2_sync_insert()` -> `hammer2_chain_insert()`.

`hammer2_chain.c:297` is the carried `KASSERTMSG(xchain == NULL,
"collision %016llx/%d", chain->bref.key, chain->bref.keybits)` guarding
the `RB_INSERT` that places a chain under its parent. It fired, so the
duplicate key is REAL and is not an artifact of the rbtree walk: two
chains of the same key were offered to one parent's tree, and the
assert's own message names them.

That sentence said "two chains of one key and one keybits" until it was
read against the comparator, and the comparator does not say that.
`hammer2_chain_cmp()` at `hammer2_chain.c:59` compares key RANGES:
it computes each chain's `[key, key + (1 << keybits) - 1]` and returns 0
when they overlap, with the comment "Overlaps are not supposed to happen
and catch any software issues early we count overlaps as a match". So a
returned non-NULL from `RB_INSERT` proves an overlap with something
already in the tree; it does not prove the two are equal, and the assert's
message prints only the NEW chain's key and keybits, not the incumbent's.
The keybits-7 block named there spans `0x400..0x47f`, and the flush lines
below show keybits-6 blocks at `0x400` and `0x440` spanning `0x400..0x43f`
and `0x440..0x47f`: the two exactly tile the 7's range. So the shape the
assert proves is one block whose range covers two siblings that were NOT
moved into it, which is rule (3) of the `create-indirect` contract ("any
elements in the current parent that fit within the new indirect block's
keyspace must be moved into the new indirect block") not holding, and not
the equal-key duplicate the earlier reading assumed.

Three things this settles.

First, the question the entry above left open is answered in the
direction that made it a defect rather than a design: the topology rule
at `hammer2_chain.c:3453` is violated. The collision key is
`0000000000000400`, keybits 7, and the log shows the indirect blocks
being flushed around it in the same seconds:

    flush indirect chain 0000000008c0000c 0000000000000400/5
    flush indirect chain 0000000008c0100c 0000000000000420/5
    flush indirect chain 0000000008c0200c 0000000000000400/6
    flush indirect chain 0000000008c0400e 0000000000000400/7
    flush indirect chain 0000000008c0300c 0000000000000440/6
    collision 0000000000000400/7

A keybits-7 block spans 128 keys; its neighbors here are keybits 5 and 6,
spanning 32 and 64. The 7 is the value `create_indirect()` picks for any
parent that is not a directory inode (`nbytes = HAMMER2_IND_BYTES_NOM`,
128 blockrefs), and the 5 is the value it picks for a directory inode
(`HAMMER2_IND_BYTES_MIN`, 32 entries). So a block built at the
non-directory radix is being placed where a directory's radix owns the
keyspace, which is the `else` branch's stated intent, "at least as large
as its parent", not being enforced against the parent's actual size.

Second, the lock report is NOT the cause and the record should stop
treating it as one. It fires at `hammer2_sync_insert+0x5b1` on
`h2core_indirect/2#2`, and `0x5b1` is the same offset that appears in the
BUG's own trace for the inlined `hammer2_spin_sh(&parent->core.spin)`
inside `hammer2_sync_setflush()`. The nesting `#0 h2ch_inode` ->
`#1 h2ch_indirect` -> `#2 h2core_indirect` is the ordinary path down to
the insertion, and the class scheme names both INDIRECT chains in it
identically because it prints type and level and not keybits, which is
what the held-chain dump beside it was added to separate. It is a
reporting artifact of the class scheme, as `b2b8e3a` recorded, and the
assert is the thing that actually broke.

Third, and this is why the fault presented as silent corruption in a
shipping kernel rather than as a crash: the `KKASSERT` that catches it is
compiled out unless `HAMMER2_INVARIANTS` is set, which no shipping build
sets. A default build offers the duplicate to `RB_INSERT`, which returns
the chain already in the tree, and the code does not read the return
value outside the assert, so the second chain is inserted-or-not into a
tree that has no room for it and the blockmap underneath keeps the two.
That is the `base_insert: overlapping at 0/32` in the earlier log and the
corrupt rbtree the unmount later walks.

Provenance: the code that builds the colliding block is carried. The
`nbytes` selection and the `create_key`/`create_bits` arguments
`hammer2_sync_insert()` passes are byte-identical to DragonFly's. That
claim was inherited from the entry above and has now been re-checked
against the clone on this machine rather than repeated:
`~/Projects/dragonfly-hammer2-upstream` is at `250a8b4928` and
`git show HEAD:sys/vfs/hammer2/hammer2_chain.c` holds the same `nbytes`
selection at its line 3778 (the directory-inode arm taking
`HAMMER2_IND_BYTES_MIN` and the `else` taking `HAMMER2_IND_BYTES_NOM`),
and `hammer2_synchro.c` line 761 passes `focus->bref.key,
focus->bref.keybits, focus->bref.type` to the same `hammer2_chain_create`
call this port's line 924 does. `doc/provenance.csv` records `hammer2_chain.c` as
`derived` from `freebsd-hammer2-upstream` and `hammer2_synchro.c` as
`derived` from `dragonfly-hammer2-upstream`. So the defect is upstream's
and is reachable in any tree that runs this sync path; it is not a port
regression.

No fix is written yet, and the paragraph above said one was for one
revision of this entry. That was wrong in the direction rule 3 forbids: a
claim of a fix with nothing in the tree behind it. What exists is a
measured defect with a location and a message, which is the evidence a
fix starts from. The repair belongs in carried core under `XXX` and is
staged rather than filed, since the maintainer files upstream; the
staging rule in `doc/upstream/README-provenance.md` requires a patch here
plus a document saying what upstream holds, and neither is written.

The reading is 4 runs of `sync-empty-base.sh` under `HAMMER2_INVARIANTS`,
this one the first to reach the assert rather than hang; the kernel log
is `sync-empty-hang-20261012-162434.klog` beside the images in
`~/Projects/linux_hammer2-data/fixtures/`, 424110 bytes.

## The incumbent is keybits 5, and the hypothesis it refutes, 2026-10-12

The assert at `hammer2_chain.c:297` computes the chain it collided with
and throws it away: `RB_INSERT` returns the incumbent, and the
`KASSERTMSG` prints only the chain being inserted. A probe now prints
both, and it fires only on the collision path. It reads:

    hammer2_chain_insert(h2nod-CL|5776): collision 0000000000000400/7 hits 0000000000000420/5

That is the answer to why the move loop skipped a sibling, and it
refutes the reading this record carried an hour earlier. The entry above
predicted, from the three `flush indirect chain` lines in the earlier
log, that the keybits-7 block at `0x400` spanned the keybits-6 pair at
`0x400` and `0x440` and that both should have been moved into it. The
incumbent is not keybits 6. It is keybits 5, at key `0x420`:

    new:       0x400/7  covers [0x400, 0x47f]
    incumbent: 0x420/5  covers [0x420, 0x43f]

so the overlap is with one narrower sibling that sits strictly inside the
new block's range, and there is no pair to tile anything. The 0x400/5 and
0x440/6 lines in the old log are neighbors of the collision, not its
parties, which is what reading them as the parties assumed.

The mechanism is now checked arithmetically rather than reasoned. The new
block's radix is `keybits`, which `hammer2_chain_indkey_dir()` raises in a
`while (((hammer2_key_t)1 << keybits) < (hammer2_key_t)ncount) ++keybits`
loop, so it is at least `ceil(log2(ncount))`. `ncount = nbytes /
sizeof(hammer2_blockref_t)`, and `nbytes` is `HAMMER2_IND_BYTES_MIN`
(4096, 32 entries, keybits 5) only when the parent is a directory inode,
`HAMMER2_IND_BYTES_NOM` (16384, 128 entries, keybits 7) otherwise. The
move loop's own skip test is
`rounddown2(key ^ bref->key, (hammer2_key_t)1 << keybits) != 0`, and for
`key=0x400`, `bref->key=0x420`, `keybits=7` that is
`rounddown2(0x20, 0x80) == 0`, which does NOT skip: the element is
within the new block's keyspace by that test and should have been moved.

So the skip test does not explain the miss, and neither does the radix
being 7 by itself. The remaining distinction is the one the next probe
takes: whether the parent whose blockmap is being scanned at that moment
is the directory inode the 4096 path was chosen for, or a *different*
parent, which is what an `else`-branch `nbytes` of 16384 would produce.
The value printed is `parent->bref.keybits` beside `nbytes`'s derived
`ncount` and the caller's `create_bits`, so a new keybits above the
parent's own is visible directly rather than inferred from the log.

The lesson is recorded because it is the second time this defect was
mis-read from the source: a hypothesis reached by reading
`create_indirect` end to end was wrong in its central claim, and the
value that refuted it was one `RB_INSERT` return away from the assert
that had been printing since the first INVARIANTS run.

### The create_indirect probe: a wrapped ring buffer, not a negative yet

A second run of the same reproducer under the same build reproduced the
collision exactly, `0x400/7` against the incumbent `0x420/5`, and added
one thing the first could not: a RIP for the fault,
`hammer2_chain_insert.cold+0x75/0x1cd`, which is the `KASSERTMSG`'s BUG
landing rather than a fault inside `RB_INSERT`. It carried no hammer2
frames, so it does not by itself add a call chain.

The `create_indirect` probe printed nothing. That is tempting to read as
"the colliding chain was not created there", and the reading is not
available: `hprintf` is `pr_info_ratelimited` and, more decisively, the
guest's ring buffer had WRAPPED. Its oldest retained line is `t=136.35`,
the collision is `t=136.51`, and even the `Linux version` boot line is
gone from `dmesg`; the whole buffer is 1643 lines. A probe that fired
before the retained window would be invisible, so zero firings here is
what a dropped line looks like as much as what a never-called function
looks like. The `hammer2_flush_core: 3442 callbacks suppressed` lines
confirm the buffer is under a flood from this path, which is what wrapped
it.

The measurement that settles it is the run's own capture, which
`sync-empty-base.sh` copies off the guest beside the images rather than
reading `dmesg` on it, so it is the full record and not the retained
window. It had not been written when this was noted; the next entry
reads it.

### The move loop did not skip the sibling: it never ran

The question this entry set out to answer was "why did the move loop skip
those siblings", and the measurement refutes the premise. The loop did
not skip anything, because `hammer2_chain_create_indirect()` was not
executing when the collision happened. The probe printed 50 times, which
is a floor and not a total: `hprintf` is `pr_info_ratelimited`, and the
capture carries three `hammer2_chain_create_indirect: N callbacks
suppressed` markers, so firings were dropped. The markers are what makes
the floor usable: they sit at t=101.37, t=124.87 and t=133.44, all before
the last observed invocation, and there is none within 100 lines of the
collision, so the limiter had recovered by then and a firing in that
window would have printed rather than been suppressed. With that caveat
the timing splits cleanly:

    the collision         t=136.517
    last create_indirect  t=133.938   (2.58 s earlier, different keys)
    next create_indirect  none for the rest of the run

Between `hammer2_vfs_sync_pmp: FILESYSTEM SYNC STAGE 2 BEGIN` at
t=136.515 and the collision at t=136.517 there are two milliseconds and
no call to `create_indirect` of any kind. The colliding chain was not
built by that function in this window.

Every one of the 50 invocations, read for the inversion the question
assumed, kept the new block's keybits strictly below its parent's:
parent 60 -> new 59, 58 -> 57, 61 -> 60, 9 -> 8, 8 -> 7, and so on, with
one shape that is not an inversion at all, `parent 0x400/0 -> keybits
62`, which is an inode: an inode's bref carries keybits 0 and its
children are keyed at the inode radix (62 for the ones here, the
`8000000000000000`-family keys). So `create_indirect` is behaving, and
the radix-7 block at `0x400` that collided with `0x420/5` came from
somewhere else on the sync path.

What that leaves, and what the log says about it: the collision is in
`hammer2_chain_insert`, called from the sync path, on a chain whose
keybits is 7 over inum keyspace, and the incumbent is `0x420/5` whose
range `[0x420,0x43f]` sits inside `[0x400,0x47f]`. A keybits-7 chain
over inode keys arrives from the master's media through
`hammer2_sync_insert()`, which passes `focus->bref.keybits` straight to
`hammer2_chain_create()`. So the next measurement is the focus the sync
thread inserts at that moment: its key, its keybits, its type, and
which element of the cluster it came from. The probe for that is not yet
written.

Two readings were wrong before this one, both reached by reading
`create_indirect` instead of instrumenting it: that the incumbent was
keybits 6, and that the loop should have moved a sibling. The values
that refuted both were one print each, and each print was cheaper than
the argument it ended.

## The collapse moves a child into a parent that does not cover it, 2026-10-12

The producer and the shape are both measured now. `print_backtrace()` at
the rbtree collision gives the call path:

    hammer2_flush_recurse -> hammer2_flush_core
      -> hammer2_chain_indirect_maintenance
      -> hammer2_chain_rename_obref -> hammer2_chain_rename
      -> hammer2_chain_create -> hammer2_chain_insert

and an entry print in `hammer2_chain_indirect_maintenance()` gives the
two parties. The line immediately before the collision reads:

    indirect_maint: parent 0000000000000440/6 collapsing 0000000000000400/7
    collision 0000000000000400/7 hits 0000000000000420/5 parent 0000000000000400/7 type 2/2

with the ranges being

    parent 0x440/6  covers [0x440, 0x47f]
    child  0x400/7  covers [0x400, 0x47f]

The child's keyspace extends to the LEFT of its parent's. The collapse
deletes the keybits-7 indirect block, marks the parent modified, and
moves the block's children up into the parent with
`hammer2_chain_rename_obref(&parent, sub, ..., HAMMER2_INSERT_SAMEPARENT,
&bsave)`. That rename re-enters each moved child through
`hammer2_chain_create()` -> `hammer2_chain_insert()`, which places it in
the parent's rbtree. A child whose key range is not inside the parent's
range does not belong there, and the rbtree says so: `0x400/7` overlaps
the `0x420/5` already present.

The guard the function does not have, in the port and at upstream both:
the collapse is gated only on live_count hysteresis,

    if (parent->core.live_count + chain->core.live_count - 1 > count)
        return (0);
    chain_count = chain->bytes / sizeof(hammer2_blockref_t);
    if (chain->core.live_count > chain_count * 3 / 4)
        return (0);

Neither test asks whether `chain`'s keyspace is contained in `parent`'s.
Diffed against DragonFly at `250a8b4928`, `hammer2_chain_indirect_maintenance()`
is carried: the two differ only in BSD-versus-Linux style (`return (1)`
against `return 1`, declaration grouping, and the wording of two
rate-limited error prints). So the missing containment test is upstream's,
and the port's own comment at `hammer2_chain.c:2121` already names this
function as the case that makes rename a no-win situation.

This is why the fault is silent on a shipping build and why two rounds of
reading got it wrong: the assert that catches it is compiled out, the
function is called from the flusher rather than the sync path the timing
suggested, and the keybits-7 block that collides is built by an ordinary
split rather than by `create_indirect`, which is behaving correctly.

### The missing containment test, and where the child is re-parented

`hammer2_chain_indirect_maintenance()` collapses a sparse indirect block
into its parent by moving the block's children up one level. Each move is
`hammer2_chain_rename_obref(&parent, sub, ...)`, which reaches
`hammer2_chain_rename()` and then `hammer2_chain_create(parentp, ...)`,
passing `sub`'s own `bref->key` and `bref->keybits`.

`hammer2_chain_create()` at `hammer2_chain.c:3110` has a second path that
the earlier reading did not see. When the parent's blockmap is full
(`parent->core.live_count == count`) it calls
`hammer2_chain_create_indirect()` and, if that returns a different
parent, re-points the caller's pointer:

    if (parent != nparent) {
            hammer2_chain_unlock(parent);
            hammer2_chain_drop(parent);
            parent = *parentp = nparent;
    }
    goto again;

So the parent a child is finally inserted into is not necessarily the one
the collapse chose. That is the whole fault:

1. The flusher collapses `chain = 0x400/7` into `parent = 0x440/6`. The
   child's range `[0x400, 0x47f]` extends left of the parent's
   `[0x440, 0x47f]`, which the collapse never checks.
2. Moving the first child finds the parent's blockmap full, so
   `create_indirect()` builds a new keybits-7 block and `chain_create`
   re-points `*parentp` to it. The new parent is `0x400/7`.
3. The next move inserts a chain of key `0x400` and keybits 7 into that
   parent, whose key and keybits are also `0x400/7`, and the rbtree finds
   `0x420/5` already in the range. Measured, both from the collision line:
   `collision 0000000000000400/7 hits 0000000000000420/5 parent
   0000000000000400/7`. What is NOT yet measured is which child `sub` at
   step 3 carries those values, and whether it is the collapse's moved
   child or the new indirect block itself; the print for that is the
   loop's `sub` beside `parent` per iteration.

The guard that would prevent step 1 is absent from both this port and
DragonFly: the collapse tests only `parent->core.live_count +
chain->core.live_count - 1 > count` and `chain->core.live_count >
chain_count * 3 / 4`, and neither asks whether `chain`'s keyspace is
contained in `parent`'s. That is the defect to fix, under `XXX`, in
carried core, staged rather than filed.

## The root cause: a collapse re-points its own parent to the block it is collapsing, 2026-10-12

The move-loop print settles the last unknown. Three consecutive lines,
one millisecond apart, from the run's capture:

    indirect_maint: move sub 0000000000000420/5 to parent 0000000000000400/7
    indirect_maint: parent 0000000000000440/6 collapsing 0000000000000400/7
    indirect_maint: move sub 0000000000000400/7 to parent 0000000000000400/7
    collision 0000000000000400/7 hits 0000000000000420/5 parent 0000000000000400/7

Read in order. A collapse put `0x420/5` into the block `0x400/7`. Then a
second collapse begins with `parent = 0x440/6` and `chain = 0x400/7` --
the block the first one had just filled. On its FIRST loop iteration the
destination printed is not `0x440/6` but `0x400/7`: the local `parent`
the function entered with has been replaced by the block being collapsed.
The child it is moving is `0x400/7`, so the block's own children are
being moved into the block, and `0x420/5` is already in there.

`parent` is a value parameter, so it cannot be assigned directly. It is
changed through the pointer: `hammer2_chain_rename_obref(&parent, sub,
...)` passes `&parent`, which reaches `hammer2_chain_rename(parentp, ...)`
and then `hammer2_chain_create(parentp, ...)`, where
`hammer2_chain.c:3148` runs

    parent = *parentp = nparent;

when the destination's blockmap is full and `create_indirect()` has built
a replacement. So the collapse's own `parent` variable is re-pointed to
the new indirect block, and every later iteration of the collapse loop
uses it. When that new block is the very chain being collapsed, the
function is filling a block with its own contents.

The missing guard is the one the collapse has never had, in this port and
at DragonFly: it tests live_count hysteresis only, and never that
`chain`'s keyspace is contained in `parent`'s. Here they are disjoint on
the left -- `0x400/7` covers `[0x400,0x47f]` and `0x440/6` covers
`[0x440,0x47f]` -- so the collapse should not have started at all.

Fix, under `XXX` in carried core, staged rather than filed: refuse the
collapse unless `chain`'s keyspace fits inside `parent`'s, which is the
condition the moved children need for the destination's rbtree to accept
them. The measurement that confirms it is the same reproducer reaching
`unmount` with no collision and no BUG.

### The containment guard fires on the measured case and is not sufficient

The guard above was built and run, and it fires exactly where the
measurement said it should:

    indirect_maint: refusing collapse of 0000000000000400/7 into 0000000000000440/6, keyspace not contained
    indirect_maint: move sub 0000000005afeae1 0000000000000400/7 to parent 000000004336fe81 0000000000000400/7 chain 00000000820d4744
    hammer2_chain_insert: collision 0000000000000400/7 hits 0000000000000420/5 parent 0000000000000400/7 type 2/2

so the collapse it refuses is a real one and the refusal is correctly
aimed. The run collides anyway, from a second collapse in the same
window, and the pointers say why. That collapse is
`parent 0x4336fe81 0x400/7` collapsing `chain 0x820d4744 0x440/6`, and it
passes the containment test: `[0x440,0x47f]` IS inside `[0x400,0x47f]`.
But the child it moves, `sub 0x5afeae1 0x400/7`, has a range
`[0x400,0x47f]` identical to the destination's, and the destination
already holds `0x420/5` from the earlier move at the top of this log.

Two things follow, and both are readings rather than inference.

First, the malformation is in `chain`, not in the destination or the
move: `chain 0x440/6` covers `[0x440,0x47f]` and is holding a child
`0x400/7` covering `[0x400,0x47f]`, which is not inside it. A child
outside its parent is what the tree's keybits invariant forbids, and the
move relocates an existing violation rather than creating one.

Second, `create_indirect` did not build that pair. Every transition it
logged in this run kept the new block's keybits strictly below its
parent's (60->59, 58->57, 61->60, 12->7, 9->7, 0->62 and so on), and none
of them has a parent at keybits 6. So the bad parent-child pair is not
something this run's splits produced through the path that is probed.

What that leaves open, and it is narrower than before: either the pair is
already on the media the run started from, or a path builds it that no
probe covers. The check that separates them is `fsck_hammer2` on the
slave's image before the run and the master's after it, which is a
read-only reading and the next one to take. The guard here stays in the
tree: it is correct on its own terms, it refuses a collapse that must not
happen, and it is not yet the whole fix.

## The fix: create_indirect inserts a block that does not fit its parent, 2026-10-12

The invariant probe at the one insert path every builder routes through
named the producer directly, and it is the function two earlier readings
cleared. `hammer2_chain_create_indirect()` builds a new indirect block
`ichain` and inserts it into `parent` at `hammer2_chain.c:3903` without
checking that `ichain` fits inside `parent`. The stack that catches it:

    insert: child 0000000000000400/7 outside parent 0000000000000440/6
      hammer2_chain_create_indirect+0x12a7  (addr2line: hammer2_chain.c:3907)
      hammer2_chain_create+0x46e

and the same probe caught a second shape six seconds later,

    insert: child 0000000000000480/7 outside parent 0000000000000480/7

where the ranges are identical rather than disjoint, so only a keybits
test catches it. `ichain`'s radix comes from the indkey helper, which
sizes the block to hold its own contents and has no view of the parent's
keyspace, so it can be wider than the parent it goes into. The rbtree
cannot hold that: `hammer2_chain_cmp()` counts overlapping ranges as a
match, the insert returns the incumbent, and the carried `KASSERTMSG` at
`hammer2_chain.c:297` takes the device into error.

The guard added at that insert refuses the block rather than inserting
it, freeing `ichain`, setting `EIO` and returning NULL, which is the
error path the caller already handles. It tests both the range and the
keybits, because neither implies the other, and skips a parent of keybits
0, which is a directory inode holding children of its own radix rather
than a range.

Measured, three runs of the same reproducer with the same build knobs:

| run | guard | recursive-lock report | collision / BUG |
|---|---|---|---|
| `inv3` | none | 1 | 1 |
| `inv9` | collapse containment | 1 | 1 |
| `inv11` | create_indirect fit | 1 | **0** |

The recursive-lock report is present in all three and is not this
defect's; the collision and the `kernel BUG` are gone from the guarded
run, which then continued 458 seconds of healthy sync work where every
earlier run died by t=152. 71 sync stages completed, and the guest is
idle at load 0.16 when the run's own 900 s window closes, so the
reproducer no longer reaches the crash at all. It still does not reach
the unmount inside that window, which is the original empty-base fault
this script was built to chase and is a separate defect.

`create_indirect` is carried. Diffed against DragonFly at `250a8b4928`
the function is 415 lines here against 361 there, and the 54 are not a
logic divergence: declarations split one per line, the port's own `hpanic`
shim replacing `panic` (adding the `keybits = -1` and `return (NULL)`
exits a returning panic needs), the port's error prints, and the probes
and guard added by this session. The keybits selection and the create
arguments are unchanged, so the missing fit check is upstream's. Fixed
here under `XXX`, staged rather than filed.

## The crash is gone; what it was hiding is a sync-side wait, 2026-10-12

The full-window run of the same reproducer under the `create_indirect` fix
reaches t=1279 with none of the fault:

| reading | count |
|---|---|
| `collision 0000000000000400/7 hits` | 0 |
| `kernel BUG` | 0 |
| `device in error` | 0 |
| `from empty base` | 0 |
| the fit guard refusing a block | 1 |

and the guest is healthy at the end: three hammer2 mounts up, 4200 files
written, load 0.09. The guard fires once, the run continues past it, and
the collision and the device-in-error never happen. On the two earlier
runs of the same build the collision arrived at t=118 and t=136.

The run does not reach a slave unmount, and the reason is measured rather
than inferred. `sync(1)` on the guest is blocked 20 minutes in
`hammer2_trans_init`, and two kernel stacks name a wait:

    kworker/10:1   hammer2_sync_work -> sync_filesystem -> hammer2_vfs_sync_pmp
                   -> hammer2_inode_chain_flush -> hammer2_xop_testset_ipdep
    kworker/u48:1  virtblk_remove -> del_gendisk -> blk_report_disk_dead
                   -> sync_filesystem -> hammer2_vfs_sync_pmp
                   -> hammer2_trans_init

The first holds the PFS's flush transaction and waits on an inode
dependency; the second wants that transaction and waits on the first.
`hammer2_trans_init` with `HAMMER2_TRANS_ISFLUSH` blocks on
`pmp->trans_cv` while another flush holds `pmp->trans.flags`
(`hammer2_flush.c:91`).

That reading said `hammer2_trans_init` waits appear in the unguarded runs
too, which is wrong and is corrected here: the occurrences in `inv3`,
`inv9` and `inv10` are `__pfx_hammer2_trans_init`, the function-prefix
symbol a trace prints when it lists a candidate, not a blocked call. The
blocked `hammer2_trans_init+0x2ab` is unique to this run, which is the
first to survive long enough to reach the sync path at all; the crashed
runs died at t=152 with the wait behind the crash.

The second stack is not the port at all. It is the host's own
detach-disk reaching the guest as an ACPI hotplug:

    virtblk_remove -> del_gendisk -> blk_report_disk_dead
      -> sync_filesystem -> hammer2_vfs_sync_pmp -> hammer2_trans_init

so the host side was ejecting the volume while the run was still going,
and the guest's `sync` then blocked behind the flush that eject wanted.
The run ended at the bound rather than reporting a stall of its own
because the host had already begun tearing the disks down.

So the state is: the collision and the device-in-error are fixed and
measured; the next fault is a flush-transaction wait between the syncer
and a second `sync_filesystem` on the same PFS, and it is the one this
script was built to reach. The convergence check added to
`script/sync-empty-base.sh` -- fsck on both images and
`cluster-sync.sh`'s PFS fingerprint comparison, copied whole -- has not
yet produced a reading, because no run has reached the end of the cycles.

## The unmount is not reached: sync(1) deadlocks against the port's own syncer, 2026-10-12

The run started from a verified-clean guest -- the new pre-flight guard
refused the dirty one and the cycle above it cleared the state -- and it
still does not reach a slave unmount. The cause is not the harness this
time. A `sync(1)` on the guest blocks in the port, and the two tasks that
name hammer2 are the whole population, enumerated over every pid:

    pid 268   kworker/10:2+events
      hammer2_xop_testset_ipdep+0x2a8
      hammer2_xop_start_except+0x4fe
      hammer2_inode_chain_flush+0x67
      hammer2_vfs_sync_pmp+0xf3d
      hammer2_sync_fs -> sync_filesystem        (the port's own syncer)

    pid 5928  sync
      hammer2_trans_init+0x2ab
      hammer2_vfs_sync_pmp+0xb7
      hammer2_sync_fs -> __iterate_supers -> ksys_sync

So the syncer holds the PFS's flush transaction and sleeps in
`hammer2_xop_testset_ipdep()` waiting to add an inode whose entry is
already in `pmp->ipdep_lists[idx]`, while `sync(1)` waits in
`hammer2_trans_init()` for that same `HAMMER2_TRANS_ISFLUSH` to clear
(`hammer2_flush.c:91`). The retire that would remove the ipdep entry and
wake the sleeper belongs to a task that no longer exists: no third thread
holds a hammer2 frame, at any state, so the inode cannot be retired and
the flush cannot finish.

This is the lost-wakeup class the `XXX` above `hammer2_xop_testset_ipdep`
already records, in a second shape. That entry is about
`HAMMER2_PMPF_WAITING`, one bit for the whole PFS against one condition
variable per index, where "a retire on another index cleared it on behalf
of a sleeper it did not wake". Here the sleeper waits on the list itself,
and the waker has to be a live task holding the inode; when the holder is
gone the wait is unbounded, and the condition variable has no one left to
signal it.

Reachable with a plain `sync(1)`, no cluster involved: the deadlock
reproduces while the reproducer is still writing its set, before any
slave unmount, and it is what kept every full-window run from reaching
the cycles. It is not caused by the collision fix; that fix removed the
crash that ended the earlier runs at t=152 and this is what sat behind it.

Not fixed here. The next measurement is which task added the ipdep entry
and why it retired without calling `hammer2_xop_unset_ipdep()`, which is a
print at the insert and at the unset rather than a reading of the caller.

### The bucket reading was wrong: the collision is the same inode

This section said the inode-dependency index, `inum % 32`, made the wait a
BUCKET wait, and that unrelated inodes sharing a bucket blocked each other.
That is false and is corrected here. `xop_testset_ipdep()` tests
`iptmp == ip` -- POINTER equality (`hammer2_admin.c:254`, and the same test
at 271 in the unset) -- so two different inodes that hash to one bucket
both go on the list and neither waits. The index selects which LOCK guards
the list, which is all a hash bucket is for. The same test is in the
FreeBSD port at its lines 224 and 241.

What the measurement does establish is narrower and more useful: the
collision is the SAME inode offered twice. A task already holding an ipdep
entry for an inode reaches `hammer2_xop_testset_ipdep()` for that inode
again and sleeps until the first entry is retired. The syncer's flush is
in that state, so the dependency it waits on is one it took itself.

### The ipdep entry is held for the XOP's whole life, and the retire is carried

The unset side is reached only on the LAST retire. `hammer2_xop_retire()`
returns early unless the mask it is retiring completes the XOP
(`hammer2_admin.c:489`):

    omask = atomic_fetchadd_32(&xop->run_mask, -mask);
    if ((omask & HAMMER2_XOPMASK_ALLDONE) != mask)
            return;

and the four `hammer2_xop_unset_ipdep()` calls are at lines 564, 569, 575
and 581, all past that return. So an ipdep entry is held from
`hammer2_xop_start_except()` until the XOP's last collector retires, and
any task that hits the same bucket in the meantime sleeps in
`hammer2_xop_testset_ipdep()` for that whole span. When the last collector
never arrives, the span is unbounded -- which is the state the run is in:
the syncer holds the entry, no third task holds a hammer2 frame, so no
retire is coming.

This is carried, not a port divergence. The FreeBSD port at `3df307f` is
byte-identical here, early return at its line 370 and the four unsets at
444, 449, 455 and 461, and this port's provenance row for
`hammer2_admin.c` records the file as carried. So the shape is upstream's,
and the two candidate repairs are upstream decisions:

  - hold the dependency per inode rather than per `inum % 32` bucket, so a
    waiter is never made to wait for a task it has no stake in;
  - or release the entry at the element's own retire rather than the last
    one, so the span is one element and not one XOP.

Neither is written. The `XXX` above `hammer2_xop_testset_ipdep` already
records the first shape of this lost wakeup (the `HAMMER2_PMPF_WAITING`
bit), and this is the second; both want the same decision, and it belongs
against the FreeBSD text and the staged-filing rule rather than taken here
from the record alone.

## A DIRENT chain with bytes but no data faults the flush, 2026-10-12

The run that went looking for the ipdep holder found a fault upstream of
it first. In the sync thread's flush, `h2nod-CL` takes a general
protection fault in `xxh64`, KASAN reading "null-ptr-deref in range
[0x0-0x7]" with `RDX` zero, and `addr2line` puts the faulting call at

    hammer2_chain_setcheck+0x2a1
    -> XXH64(bdata, chain->bytes, XXH_HAMMER2_SEED)
    hammer2_flush_core+0xe58  ==  hammer2_flush.c:754

Line 754 is the `HAMMER2_BREF_TYPE_DIRENT` arm:

    case HAMMER2_BREF_TYPE_DIRENT:
            if (chain->bytes)
                    hammer2_chain_setcheck(chain, chain->data);
            break;

so `chain->bytes` is non-zero and `chain->data` is NULL. The arm checks
the one and not the other. The `HAMMER2_BREF_TYPE_INDIRECT` arm just above
it calls `setcheck(chain, chain->data)` with no guard at all, and the
`VOLHDR` arm carries `KKASSERT(chain->data != NULL)`, which is compiled out
of every build this tree ships. So the DIRENT arm's `bytes` test is reading
as a data test and is not one.

This is a real fault in the flush path, reached by a plain write load, and
it lands in the same thread whose wait the previous entry describes. It is
the next thing to fix, ahead of the ipdep question: a fault in `setcheck`
leaves the flush half-done, and a half-done flush is a candidate explanation
for why the ipdep entry the syncer waits on is never retired.

The ipdep print added for the other question did fire, and it says the
waiter holds the entry itself:

    ipdep wait: ip ... inum 0000000000000001 idx 1, list: <same ip>/1

inum 1 is the root directory inode and the list holds exactly that one
entry, so the task is waiting to add an inode it already added. It printed
eight times about a quarter second apart, so the waiter is re-entering and
re-testing rather than sleeping through, which is the shape
`hammer2_xop_testset_ipdep()`'s `goto again` produces when the retire
happens but the entry returns. Not yet explained.

## The first guard refused after moving, and that was this session's own defect, 2026-10-12

The xxh64 fault recorded above was not in the port. It was introduced by
the fit guard added earlier in this session, and removing it is the fix.

That guard sat AFTER the loop that moves the parent's blockrefs into the
new indirect block, next to the insert it was protecting. Refusing there
freed `ichain` with every moved child still pointing at it, and the next
flush dereferenced a DIRENT whose `bytes` and `data` no longer agreed:
null-ptr-deref in `xxh64` at `hammer2_flush.c:754`. The reading that
established it is a count across runs, not an argument:

| log | `RIP: xxh64` | guard fires |
|---|---|---|
| `inv3`, `inv9`, `inv10` (before the guard) | 0 | 0 |
| `converge`, `ipdep` (guard after the move loop) | 2 | 1 |
| `moved` (guard before the move loop) | 0 | 10 |

The guard now stands immediately after `ichain` is allocated and modified
and before the move loop begins (`hammer2_chain.c:3768`, loop at 3779), so
a refusal leaves the parent exactly as it was, which is the state the
caller's error path already expects. With it there the xxh64 fault does
not occur in any run.

Its own cost is measured and is not yet acceptable: the guard fires ten
times in 1.7 ms on the same key (`0x400/7` into `0x440/6`) instead of once,
the caller retries rather than giving up, and `sync_slaves error 256`
follows -- the EIO from the refusal surfacing as a sync-pass error. A
general protection fault in `hammer2_inode_chain_and_parent+0xfe`, called
from `hammer2_sync_slaves`, appears in this run and in no other, so it is
downstream of the refusal and not yet explained.

So the state is: the collision is stopped, the corruption this session
introduced is removed, and the refusal's own consequences are open. The
guard is a candidate fix with a measured cost, not a finished one, and
the next reading is the caller: why the same create is attempted ten times
and what `sync_slaves` does with the error, which is a print at the caller
rather than a reading of it.

## The unmount reaches hammer2_thr_wait and never leaves it, 2026-10-12

The relocated guard let the reproducer get further than any run before it:
the first cycle's slave unmount completed (t=162.65), the master's syncer
ran on, and the slave was remounted at t=202.7. It then hung on the NEXT
unmount, and the stack says where:

    hammer2_thr_wait+0x1ea
    hammer2_pfsfree_scan+0x29e
    hammer2_unmount_helper+0x2b9
    hammer2_kill_sb+0xb5
    deactivate_locked_super -> cleanup_mnt

and the whole population of tasks holding a hammer2 frame is that one
`umount`. So the unmount waits for a thread-state bit that no live thread
will set.

`hammer2_thr_wait()` (`hammer2_admin.c:870`) is the wait:

    for (;;) {
            oflags = thr->flags;
            if ((oflags & flags) == flags)
                    break;
            nflags = oflags | HAMMER2_THREAD_WAITING;
            if (atomic_cmpset_int(&thr->flags, oflags, nflags))
                    tsleep_word(&thr->flags, nflags, 0, "h2twait", hz*60);
    }

The sleep has a 60-second bound and the loop has none, so a bit that never
arrives is a permanent wait. `hammer2_pfsfree_scan()` reaches it twice:
directly through `hammer2_thr_freeze()` and `hammer2_thr_freeze_async()` on
the PFS's sync threads, which wait on `HAMMER2_THREAD_FROZEN`
(`hammer2_admin.c:1058`), and through the delete path's
`hammer2_thr_wait(thr, HAMMER2_THREAD_STOPPED)` (`hammer2_admin.c:1015`).

The comment on `hammer2_thr_wait_any()`, the next function, already records
this class in the port's own words: "Upstream's test is for ETIMEDOUT, and
DragonFly's tsleep() reports a timeout as EWOULDBLOCK, so as written the
timeout never ends the wait." That note is scoped to `_any`, whose two
callers are absent here. `hammer2_thr_wait()` has the same shape, is called
from the unmount teardown, and is what this run is stuck in.

This is P4's "thread lifetime and stop/join" item arriving as a measured
hang rather than a reading. It is a candidate defect with a stack, not a
diagnosis: what is not yet measured is which bit was being waited on and
why the thread did not set it, and the print for that is the flags
recorded at entry and on each loop of `hammer2_thr_wait()`. Fixing the
flush path is not the same fix as making the unmount refuse to wait
forever, and the second one is worth having on its own.

## The empty slave column is the whole column, and the unmount stops hanging, 2026-10-12

Three prints were added in one build, because runs here cost twenty
minutes and the previous three runs each answered one question that the
next run then invalidated:

- `hammer2_thr_wait()` (`hammer2_admin.c:870`) prints the requested
  `flags` and `thr->td` at entry and once per return of the sleep, whose
  timeout is `hz*60`.
- `hammer2_inode_chain_and_parent()` (`hammer2_inode.c:451`) prints the
  inode, the cluster index and `nchains` when the selected element has no
  chain, and returns NULL with `*parentp` NULL rather than dereferencing.
- `hammer2_sync_slaves()` (`hammer2_synchro.c:500` and `:820`) no longer
  reads `chain->bref.modify_tid` before testing `chain`, and skips a pass
  whose parent is NULL instead of asserting.

`script/sync-empty-base.sh` on the KASAN guest, `H2_RUN_TIMEOUT=1500`:

| reading | value |
| --- | --- |
| checks | 17 run, 5 failed |
| `Oops:` | 0 |
| `kernel BUG` | 0 |
| `device in error` | 0 |
| `soft lockup` | 2, both on the sync guest's idle task |
| `thr_wait:` | 2 |
| `chain_and_parent:` NULL skips | 60,672, all `clindex 1 nchains 2` |
| `create_indirect: new ... does not fit` | 230 |
| unmount/remount cycles recorded | 7 |
| `from empty base` | 0 |
| slave against master, by media | 4,800 against 4,800 entries, 8,000 of 14,402 lines differ |
| `fsck_hammer2`, both volumes | exit 0 |

The run completed all four cycles and did not hang. Both `fsck_hammer2`
passes exit 0, so both volumes are structurally sound; the five failures
are the fault this script exists to reproduce (no miss, no give-up, no
device in error), the kernel-warning check, and the convergence check.

The two `thr_wait:` lines are the print working and they say the ordinary
teardown is healthy:

    thr_wait: thr 00000000a0424b41 want 0040 td 00000000babd4d3c flags 0060
    thr_wait: thr 00000000a0424b41 want 0100 td 00000000babd4d3c flags 0050

The first wants `HAMMER2_THREAD_FROZEN` and finds it already set, so it
breaks at once; the second wants `HAMMER2_THREAD_STOPPED` with a non-NULL
`td`, so the thread was still a live task, and it resolved without
spending the full timeout. Neither is the earlier hang, and a NULL `td`
never appeared. The hang the previous run died in is therefore still
unreproduced, and the record keeps it as a candidate: a sync thread that
faults inside a kthread never sets `STOPPED`, and `hammer2_pfsfree_scan()`
waits for that bit in a loop with no bound, so a fault there and a hang
there would be one event. Nothing in this run sets the fault, so nothing
in it can settle that.

The deref is DragonFly's. Upstream's `hammer2_inode_chain_and_parent()`
reads `parent = chain->parent` with no NULL test, and the field at that
offset, 0x370, is `parent` in this build's DWARF, not the
`bref.modify_tid` the caller reads in its own frame. Upstream's
`hammer2_sync_slaves()` also reads `chain->bref.modify_tid` above its own
`if (chain)`; the second call site tests with `KKASSERT(parent != NULL)`,
which is compiled out unless `HAMMER2_INVARIANTS` is set and so tested
nothing in a shipping build. What this port adds is a path that can reach
an empty element: a `create_indirect()` refusal declines to build a block
that cannot fit its parent, where upstream panicked at the insert instead.

Superseded, 2026-10-13, by the decomposition below. The two sentences this
paragraph replaced read the skips as an empty slave column for every inode
and blamed the two candidate mechanisms it named. The images say otherwise.

What the media actually hold, from `hammer2 -v show`'s cluster fingerprint
on both images with the population asserted first, taken by hand after the
run rather than from its cached mount:

| cluster PFS, by type | master | slave |
| --- | --- | --- |
| `inode` | 4,801 | 801 |
| `dirent` | 4,801 | 4,801 |
| `data` | 4,800 | 800 |

All 4,801 directory entries reached the slave and 4,000 inodes and their
4,000 data blocks did not. The line count the run printed, "8,000 differ of
14,402", is the whole `diff` delta between a 14,402-line fingerprint and a
6,402-line one, not 8,000 disagreements: on two sides holding different
numbers of lines the two numbers are not the same, and only the per-type
counts say which. The 60,672 skips are `clindex 1` on a 2-chain inode over
128 distinct inodes sampled, and they are the 4,000 inodes whose element
the pass then declined to build, not every inode in the PFS.

The cause is in this port rather than inferred: `hammer2_sync_slaves()`
returns early when `want_update` is 0, and the commit being recorded here
set `want_update` to 0 whenever the chain was NULL. `want_update` is what
reaches the scan that creates the missing element, so testing the NULL
chain before reading it, and then skipping the update for exactly that
case, turned a loud fault into a quiet loss of 4,000 inodes' data. A missing
element is a reason to update. That is now what the code does, and the next
run is what says whether it converges.

The counter added in this commit replaces an unconditional print that was
itself a defect: 60,672 `printk` calls to the guest's serial console, and
two soft lockups on the CPU whose hardirq time crossed 50% at the rate
those calls peaked. An instrument that changes the system it measures is
not a reading, and the run that produced this table had both.

## The hang is reproduced and the chain behind it is measured end to end, 2026-10-13

One run, `H2_RUN_TIMEOUT=1500` on the KASAN guest, reproduced the fault the
handoff named and measured the whole chain in it. It hung past its 1500 s
bound, which is what the first run after the guard did not do, and the
difference is one line: `want_update` for a NULL chain was 1 in this run and
0 in the previous one.

The state bit, at last measured:

    thr_wait: thr 2..c44c0 want 0040 td 2..e83bb flags 0020   t=3695
    thr_wait: thr 2..c44c0 want 0040 td 2..e83bb flags 0024   t=3757  +62s
    thr_wait: thr 2..c44c0 want 0040 td 2..e83bb flags 0024   t=3819  +62s
    thr_wait: thr 2..c44c0 want 0040 td 2..e83bb flags 0024   t=3880  +61s

`want 0040` is `HAMMER2_THREAD_FROZEN`; `td` is non-NULL, so the thread is
still a task; `flags 0024` is `FREEZE|WAITING`, unchanged across three
sleeps. The bit was never set, and the loop that waits for it has no bound.
The wait is real, it is on FROZEN, and the thread it waits for is alive and
not answering.

Why the thread stopped answering, from the same log: an oops at t=3403 in
`hammer2_chain_lookup+0x15b`, reached `hammer2_sync_slaves+0x3f0` <-
`hammer2_primary_sync_thread`. `RBP` is 0 and the faulted range is
`0x28-0x2f`, so the operand is a NULL chain's field. The line is
`hammer2_sync_slaves()` at `hammer2_synchro.c:556`, which reads
`parent = hammer2_inode_chain(ip, idx, ...)` and then passes that parent,
NULL when the element is absent, to `hammer2_chain_lookup()` at
`hammer2_synchro.c:560`. A fault inside the sync kthread never sets FROZEN
or STOPPED, so the fault and the hang are one event: the previous entry
recorded that as a candidate, and this run is the run that sets the fault
and hangs in the same breath.

The two exits from an empty element are now both measured, and neither is a
fix:

| `want_update` for a NULL chain | what the run did |
| --- | --- |
| 0, skip the element | no fault, no hang, slave loses 4,000 inodes' data (2026-10-13 images) |
| 1, ask for the update | faults in `hammer2_chain_lookup`, thread dies, unmount hangs (this run) |

The empty element is therefore the defect, and the guard that creates it is
its producer. `hammer2_chain_create_indirect()` refuses a block that does not
fit its parent and unwinds, which leaves the destination's cluster element
unbuilt; upstream never has that state, which is why the core has no case
for it and why enforcing upstream's invariant here produces a state the rest
of the carried code cannot hold. The fix belongs where the block's radix is
chosen, the `ncount` loop in `hammer2_chain_indkey_dir()`
(`hammer2_chain.c:3631`), so the block is sized to fit rather than built and
refused. That is a change on carried core and is taken deliberately, not as
another guard downstream of this one.

The tree ships `want_update` 0: a copy that does not converge and says so in
its check beats a fault that wedges an unmount, and the convergence check
measures the loss rather than hiding it.

**Superseded on 2026-10-13 on the second clause only.** The line is still
`want_update = chain ? (chain->bref.modify_tid != sync_tid) : 0` in
`hammer2_synchro.c`, so what the tree ships is unchanged; the copy does converge
now, by the split bound recorded below, and the rationale above is the account of
a choice made while it did not. The choice was not re-decided on convergence: what
the ternary avoids is a fault on the sync thread when the element is absent, which
the bound does not address.

## Correction to the entry above, same day, 2026-10-13

The entry above says the empty element that faults `hammer2_chain_lookup()`
is a data block's and that the guard creates it. That is wrong on which tree,
and the log says so in two lines 0.7 ms apart:

    [ 3403.312863] chain_and_parent: ip a7c845f4 clindex 1 nchains 2 chain NULL, 1 so far
    [ 3403.313578] Oops: ... KASAN: null-ptr-deref in range [0x28-0x2f]

`hammer2_sync_slaves()` at line 556 calls `hammer2_inode_chain(ip, idx, ...)`,
which reads `ip->cluster.array[idx].chain` and nothing else, so the NULL it
hands `hammer2_chain_lookup()` two lines later is the INODE's cluster element,
not a block in the data tree. The one `chain_and_parent` print in the whole
log is that inode, `clindex 1`, and it is 0.7 ms before the fault.

An inode's slave element being NULL is ordinary here, which the record
already says elsewhere: `hammer2_pfsfree_scan()` clears the slave's element
for every inode when the slave's volume is unmounted, and this script
unmounts and remounts the slave four times, so a master-side pass that runs
inside that window sees NULL elements for inodes that are perfectly healthy.
The correct handling is therefore to SKIP such an inode until the element is
back, which is what `want_update` 0 does, and what the tree ships. Asking for
the update is what faults, which is now measured.

So the two defects this session found are separate and only the first is
understood:

- The inode element is transienly NULL inside the slave's unmount window, and
  the scan must skip it. The tree does. `want_update` 1 faults.
- The data tree gets a block whose radix does not fit its parent, which the
  guard refuses, which is where the 4,000 inodes and 4,000 data blocks the
  slave is missing come from.

The entry above is left as written, per this file's rule that a dated
observation is not rewritten in place, and this paragraph is what supersedes
its "data block" reading. What remains unmeasured is whether skipping the
inode for the whole window is why the copy never catches up, or whether the
guard's loss is, and separating them needs a run with the guard's radix fix
in place and the skip unchanged.

## Capping the block's radix to its parent was tried and does not work, 2026-10-13

The entry two above this one ends by saying the fix belongs at the radix
choice in `hammer2_chain_indkey_dir()`. That was implemented, run, and
reverted within the hour, and the run says why in one line of its own
output.

The cap lowered `keybits` to one below the parent's when the `ncount` loop
had raised it that far. The refused create is for a KEY outside the parent,
not for a range merely wider than it. Every one of the run's 210 caps was
`7->5` against a parent holding `0x440/6`, and the create is at key `0x400`:
a keybits-5 block at `0x400` covers `0x400-0x41f`, which is still outside
`0x440-0x47f`. Lowering the radix does not bring the key into the parent's
range, so the cap does not fix the fit it was written for.

What it does instead is make the capped block shallower than its own parent,
so when that block becomes a parent its children cap again one radix further
down, and the tree gains a level per create. The run reached
`hpanic("flush depth limit")` at `hammer2_flush.c:493` after 210 caps, with
two oopses behind it in the flush worker: `hammer2_flush_core.cold` and
`hammer2_chain_lookup`. Upstream panics at the same depth limit, so this is
not a port defect; it is the cap's own consequence.

The lesson is narrow and worth keeping: the invariant that fails at the
insert is about the KEY, and `indkey_dir` is given the key as an input and
returns it unchanged, so no change to the radix can make a key belong to a
parent it does not belong to. The question is one layer further up, in
whatever asked `hammer2_chain_create()` for a key outside the parent it named,
and that is not yet instrumented. `create_indirect`'s fit guard stays as the
assertion that this held, and it is what made the refusal visible rather than
leaving a silent rbtree collision.

## The guard's cost is measured, and the caller is the next print, 2026-10-13

The run on the reverted tree with `hammer2_thr_wait()` bounded reported 17
checks with 1 failed, against 5 failed for the run before it, and the
difference is which way the fault's signature counts rather than any change
in the fault: `H2_SYNC_EXPECT` now reads a flush that finds an empty base, a
chain check that gives up and a device in error as the readings wanted when
the fault is fixed, and all three are 0. The kernel-warning check is 0 as
well, where the previous run's 60,672 prints had caused two soft lockups.
Both `fsck_hammer2` passes exit 0 on both volumes, all seven unmounts are
recorded and the module unloads.

The one failure is convergence, and the fingerprints say what it costs:

| cluster PFS, by type | master | slave |
| --- | --- | --- |
| `inode` | 4,801 | 801 |
| `dirent` | 4,801 | 4,801 |
| `data` | 4,800 | 800 |

4,000 inodes and their 4,000 data blocks do not reach the slave, and every
directory entry does. That is the price the refusal pays with the guard on.
With the guard off the same create reaches the insert and the carried
`KASSERTMSG` takes the device into error, which is the fault `sync-empty-base.sh`
exists to reproduce.

So the guard converts a fatal, visible failure into a quiet 4,000-inode loss,
and the fix is neither: it is the caller that asks for a key outside the
parent it names. `indkey_dir` is handed the key and returns it unchanged, so
no change at the radix can help, which the reverted cap measured. The guard
now prints `print_backtrace()` beside the values, and the next run's stack is
what names the caller. That is the print this entry is waiting on, and until it lands the convergence criterion is unmet and stays recorded as unmet.

**Superseded on 2026-10-13: convergence is met.** The split bound in `hammer2_chain_create_indirect()` bounds `ncount` below `2^(parent keybits - 1)`, and the slave then matches its master entry for entry and block for block, inode 4801/4801, data 4800/4800, dirent 4801/4801, 0 lines differ, 18 checks 0 failed. This entry's own sentence is left as written, since the record is the dated account of how the state was reached.

## The caller that builds the unfit block is named by the stack, 2026-10-13

The guard's backtrace was taken and it names the producer, which is what the
previous three fixes were trying to reach without:

    hammer2_chain_create_indirect   <-- the refusal
    hammer2_chain_create
    hammer2_sync_insert
    hammer2_sync_slaves
    hammer2_primary_sync_thread

`hammer2_sync_insert()` at `hammer2_synchro.c:968` is the caller. It creates
a missing chain with the FOCUS's key and radix:

    error = hammer2_chain_create(parentp, &chain, NULL, thr->pmp,
                                 focus->bref.methods,
                                 focus->bref.key, focus->bref.keybits,
                                 focus->bref.type, focus->bytes, ...)

`focus` is the chain from the other device, so the key and radix come from the
MASTER's tree. `parentp` is where the slave's scan currently stands, an
intermediate block of the SLAVE's tree. In the measured case the master's
chain is key `0x400` radix 7, spanning `0x400-0x47f`, and the slave's parent
holds `0x440-0x47f`. The child's range reaches below its parent's: the key
does not belong under that parent, and `hammer2_chain_lookup()` immediately
above returns NULL rather than finding it, precisely because it is not there.

So the defect is not the radix (ruled out by the reverted cap) and not the
guard (which only reports it): it is that `hammer2_sync_insert()` inserts the
master's key under whichever parent the slave's scan has reached, and those
two are not the same place once the two trees have diverged. The scan at
`hammer2_sync_slaves()` compares chains by walking the slave and looking the
corresponding master chain up by key, so the two trees agreeing on key does
not mean they agree on the parent that key sits under.

Three candidate remedies, none measured, listed so the next session starts
from the shape of the problem rather than from a guard:

- Resolve the parent for `focus->bref.key` by looking it up on the slave from
  the inode, rather than reusing whatever `*parentp` the scan holds.
- Detect the mismatch before the create and treat the inode as unsynchronized
  for the pass, the way a slave chain newer than the pass's `sync_tid` already
  is, leaving it for a later pass with the trees further converged.
- Establish whether upstream can reach this at all. Its `hammer2_sync_insert()`
  is the same code, and its `hammer2_chain_create()` would insert the same
  unfit block, so if the divergence it needs is reachable upstream the panic
  is upstream's too. That is a reading against the DragonFly clone at
  `~/Projects/dragonfly-hammer2-upstream`, which has not been done.

The instrument that produced this is `print_backtrace()` at the refusal,
bounded to the first two firings, and it stays until the caller is fixed.

## The refused block encloses its parent, and the range test cannot see it, 2026-10-13

The guard's values, read as arithmetic rather than as a message, give the
mechanism without another run.

    create_indirect: new 0000000000000400/7 does not fit parent 0000000000000440/6
    create_indirect: new 0000000000000480/7 does not fit parent 0000000000000480/7

Take the first. A block of key `0x400` and keybits 7 spans `0x400-0x47f`. The
parent of key `0x440` and keybits 6 spans `0x440-0x47f`. The block being
inserted ENCLOSES its parent: it covers everything the parent covers and
`0x400-0x43f` besides. A child that contains its parent is the insert the
rbtree cannot express.

Why `create_indirect` builds it is visible in its own tail. Having built the
block it decides what to return with

    if (rounddown2(create_key ^ key, (hammer2_key_t)1 << keybits) != 0)
            ... return the original parent ...

which tests `create_key` against the key the block was built AT, not against
the parent it will be inserted into. When `indkey_dir` has produced a key
equal to `create_key` the xor is zero, the test reads "in the range", and the
enclosing block is returned for insertion. The test cannot fail for the case
that matters, because it never looks at the parent's range at all.

The parent is wrong before any of that. `hammer2_sync_insert()` builds a
missing chain from the master's key and radix under whichever parent the
slave's scan holds, and `0x400` is not inside `0x440-0x47f`. Measured on the
same run, `sync_insert` is called 110 times with an INODE parent of keybits 0
and 90 times with an INDIRECT parent of keybits 7, so it is reached for both
shapes. The second refusal above, `0x480/7` under `0x480/7`, is the same key
and radix on both sides, which is the enclosing case with zero containment.

So there are two defects, and only the second is in carried code:

- The guard refuses a block that `create_indirect` built, and the refusal
  costs the slave 4,000 inodes' data. This one is the port's.
- `create_indirect` can hand back a block that encloses its parent, because
  its range test compares the create key against the built block rather than
  against the parent. Upstream carries the same test, so this is reachable
  there too, and its `hammer2_chain_insert()` would take the device into
  error on the same input. Whether upstream's callers can produce that input
  is the reading this record still owes: `sync_insert` is byte-identical to
  upstream's, but the slave's scan position that supplies the parent depends
  on how this port walks the two trees, and that is the part not yet read.

Neither is a fix to write from here. The first is a guard the port added and
can remove once the second stops producing its input; the second is a range
test in carried code that needs the caller's contract established first,
since changing it without that would move the failure rather than remove it,
which four attempts at this site have now demonstrated.

## The new block inherits the master's radix, and that is why it does not fit, 2026-10-13

Printed at the refusal, not reconstructed from another function:

    create_indirect: new 0000000000000400/7 does not fit parent 0000000000000440/6
      (parent type 2, child type 2, create 0000000000000460/0 for_type 1)

Read as arithmetic:

- `parent type 2` is `HAMMER2_BREF_TYPE_INDIRECT`, so `0x440/6` really is a
  keyspace: `0x440-0x47f`. The parent is not an inode, and the "inode parent"
  reading of the previous entry is wrong.
- `create 0x460/0` is INSIDE that range. The create the caller asked for is
  legitimate and fits.
- The block actually built is `0x400/7`, spanning `0x400-0x47f`, which
  encloses the parent. So the block did not have to be built at radix 7 to
  satisfy the create; it was built at 7 because its radix came from
  somewhere other than the parent.

Where it came from is one line in `hammer2_chain_create_indirect()`:

    int maxloops = 300000, keybits = create_bits;

`keybits` is seeded from `create_bits` and is never checked against the
parent. The caller is `hammer2_sync_insert()` at `hammer2_synchro.c:968`,
which passes the FOCUS's radix as `create_bits`:

    error = hammer2_chain_create(parentp, &chain, NULL, thr->pmp,
                                 focus->bref.methods,
                                 focus->bref.key, focus->bref.keybits, ...

`focus` is the chain from the other device. So the new block is built at the
MASTER chain's radix, for insertion under whichever parent the SLAVE's scan
holds. When the two trees differ in radix at that point, the block is born
wider than its parent, `hammer2_chain_insert()` cannot hold it, and before
the guard existed the carried `KASSERTMSG` took the device into error.

This is the first mechanism in this chain to come from values printed at the
decision point, and it supersedes the two readings before it: the parent is
INDIRECT, not inode, and the defect is not that `indkey_dir` sizes a block
badly but that its input radix came from the other tree. `indkey_dir` is
given the key and the radix and returns both, so it can only be as right as
its caller.

That reading was taken, and it FALSIFIES the mechanism above. The print added
at the caller reports the focus beside the parent, and what it shows is:

    sync_insert: focus 0000000000000400/0 into parent b6a9cb23fd8a8001/0 type 1
    sync_insert: focus 0000000000000405/0 into parent 0000000000000400/5 type 2

The focus radix is 0, not 7. The new block does not inherit a master radix of
7, because the master chain's radix at that point is 0. So `create_bits` is 0,
`keybits` is seeded at 0, and whatever raised it to 7 is the indkey helper
sizing the block from `ncount` alone. The paragraph above is left in place as
the fourth mechanism this chain produced and the fourth to be refuted by its
own instrument, which is the pattern worth recording on its own.

Two things the same lines do establish, because they are printed and not
inferred. The first pair is a create with a TYPE 1 (INODE) parent whose key is
`b6a9cb23fd8a8001` and whose radix is 0: a nonzero key, so an inode parent
carries a key that is not merely a hash of its contents and cannot be assumed
to bound nothing. The second is a TYPE 2 (INDIRECT) parent at radix 5 for a
focus whose radix is 0. Both are ordinary `sync_insert` positions, so the
empty-element and unfit-block paths are reached for inode parents as well as
indirect ones.

What is NOT yet measured, and is the next print rather than the next guess:
which input raised `keybits` from 0 to 7 in the block that was refused, since
neither the caller's `create_bits` nor the focus's radix supplies it. The
values that would settle it are `ncount` and the `keybits` the helper returned,
printed together at the point the helper returns.

## Where the radix is raised and where the insert happens, 2026-10-13

Read from the source and from the printed inputs, not inferred. Three facts,
each with its line.

The radix is raised in `hammer2_chain_indkey_dir()`. Its last loop expands
`keybits` until the block is large enough for `ncount`, and its earlier loop
raises it again over the keys it scans, so a parent whose children span the
hashed keyspace yields the wide radix the run printed:

    parent 0000000000000400/0 create_bits 0 ncount 32 count 4 -> keybits 62
    parent c000000000000000/62 create_bits 0 ncount 128 count 32 -> keybits 61

Neither loop consults the parent's own `bref.keybits`, and `create_bits` is 0
on every line, so the caller is not what supplies the width either. That is
what the previous entry's falsified mechanism had backwards.

The insert is unconditional. `hammer2_chain_create_indirect()` calls

    hammer2_chain_insert(parent, ichain,
        HAMMER2_CHAIN_INSERT_SPIN | HAMMER2_CHAIN_INSERT_LIVE, 0);

and only AFTER that decides what to return, returning the original `parent`
when `create_key` falls outside the range of the block it just built. So the
new block is inserted under `parent` before anything tests whether it fits,
which is why the fit guard has to sit before that line rather than at the
return, and why refusing there leaves the caller without the chain it asked
for.

The bound the previous run proved inert could not have worked for a third
reason: it tested `create_bits`, which is 0. The place a bound can hold is
`indkey_dir`'s return, where the value the two loops produced is in hand, and
the value it must stay under is `parent->bref.keybits`. That is one line, and
it is not written here: three bounds have been tried at this site and the runs
have named why each failed, so the fourth is left to a session that starts
from these three readings rather than from scratch.

## Both directions at the radix site are now measured, and the arithmetic says why, 2026-10-13

Two runs closed the fourth attempt at `hammer2_chain_indkey_dir()`, and the
arithmetic from the port's own printed values closes the whole avenue. A
`hammer2_blockref_t` is 128 bytes, so the refusal

    create_indirect: parent 0000000000000440/6 create_bits 0 ncount 128 count 32
      -> keybits 7 key 0000000000000400

reads as sizes rather than as a message. The parent `0x440/6` is a 4 KiB
block: 32 slots over a 64-key span. Sparse is legal and the count column
proves it; over-dense is not, since a block cannot hold more entries than
the keys its span covers. The block being built is 16 KiB, so `ncount` 128
drives `keybits` to 7 for 128 slots over a 128-key span. A 128-key block
cannot fit under a 64-key parent for ANY key, so no mask and no radix can
make it fit; the key follows the radix out of range rather than leading it
there. That is why three caps applied at the mask changed nothing, and it
retires the site: the radix is not the lever.

Both remaining directions were then built and run, and both fail, so the
pair is what a later session needs rather than either alone.

- Capping `keybits` to one below the parent and leaving `ncount` at 128
  (`e25ca9e`): the block keeps a 16 KiB allocation for a 32-key span, holds
  32 entries, fills at once, splits again, and the freemap dies --
  `no block of radix 14 for type 2`, then `no block of radix 10 for type 1`
  ten times, `modify error 00000020` on `0x440/5` and nine times on `0x4c0/6`,
  and `hpanic("flush depth limit")` at `hammer2_flush.c:493` at t=131 s.
- Capping `keybits` and reducing `ncount` with it so the block holds exactly
  its span: the 16 KiB request is gone and so is the depth panic, but the
  block is then too small for what the move loop puts in it. The last two
  lines before the BUG are the same in both runs --

        indirect_maint: move sub 0x400/5 to parent 0x400/7
        indirect_maint: move sub 0x420/5 to parent 0x400/7
        hammer2_base_insert: no room

  -- and `hpanic("no room")` at `hammer2_chain.c:5210` follows.

The move lines and the panic are adjacent in the log but they are not the
same event, and reading them as one names the wrong function. The stack the
run printed under the panic is

    hammer2_base_insert
    hammer2_flush_core
    hammer2_flush_recurse

so the insert that found no room is the FLUSH's own blockmap update, at
`hammer2_flush.c:962`, not the move loop. The flush derives its entry count
straight from the block it is writing into --

    count = parent->bytes / sizeof(hammer2_blockref_t);

-- and that count was set when the block was allocated. A block whose entry
count and whose span disagree is one `hammer2_base_insert()` cannot fill at
the flush, whatever the move loop did or did not put in it. This is the
second time this session a stack has corrected a mechanism read off adjacent
print lines; the first is the pair of readings above it.

`no room` appears in none of the sixteen logs kept before this session and in
both of the runs above, so it is produced by the sizing and not by the refusal.
One of the two runs also removed the fit guard, and because two changes moved
together that run could not attribute the result on its own; the second run
kept the guard and reproduced the same `no room`, which is what settles it.

What the pair leaves as the target is the block's ENTRY COUNT against the span
it was allocated with, decided where the block is allocated and read straight
back by the flush as `parent->bytes / sizeof(hammer2_blockref_t)`. The two runs
above are the two ways to get that pair wrong: too many entries for the span,
so the freemap dies and the flush depth limit follows, or a span whose block
cannot hold what the flush then inserts, so `no room`. The control is the
master built by this same code: read off its own media every indirect block it
holds satisfies `2^keybits >= count`, keybits 7 with 128 slots, keybits 6 with
32, keybits 62 and 63 with 32. The next reading is the one that pairs
`ichain->bytes` with `ichain->bref.keybits` at the allocation site, on the
slave where the two trees differ, rather than any further arithmetic at the
mask.

A separate entry belongs to the move loop and does not get one here. The only
guard against `create_indirect()` being re-entered from
`hammer2_chain_indirect_maintenance()`'s move loop is
`KKASSERT((flags & HAMMER2_INSERT_SAMEPARENT) == 0)` at `hammer2_chain.c:3172`,
which every shipping build compiles out, and that assert is upstream's. No
measurement this session reached it; nothing here should be read as evidence
about it either way.

## The block's size and its radix come from different places, measured at the allocation, 2026-10-13

A probe at `hammer2_chain_create_indirect()`'s allocation, where `nbytes` and
`keybits` are both in hand for the first time, printed the defect directly:

    create_alloc: parent 0000000000000480/7 bytes 4096 | new 0000000000000480/7
                  nbytes 16384 ncount 128

The block is built at the PARENT's own key and keybits, `0x480/7` under
`0x480/7`. It cannot be anyone's child, and `hammer2_chain_insert()`'s carried
`KASSERTMSG` is what catches it. The two numbers that produced it are in the
line: the parent is 4096 bytes, 32 slots, while the block is 16384 bytes,
128 slots.

The size and the radix are decided by different rules and nothing reconciles
them. `nbytes` is `HAMMER2_IND_BYTES_NOM` for any non-inode parent, fixed
before the helper runs; the helper then raises `keybits` until the block holds
`ncount` entries, 128 of them for a 16 KiB block. A keybits-7 block is where
that lands, and a parent that is itself keybits 7 cannot take it.

The control is the master, built by this same code and read off its own media:
every one of its indirect blocks has 128 slots at keybits 7 to 12, and 32 slots
at keybits 62 and 63. The slave differs at exactly this point -- it holds
keybits 7 blocks with 32 slots, and keybits 5 and 6 blocks the master does not
have at all -- so the shape divergence the refusals come from is the slot
count a block is built with, not its keyspace.

The probe as written also proved its own defect: its second condition,
`keybits >= parent->bref.keybits`, is true for every ordinary inode parent
whose keybits is 0, so it printed 43,106 lines and buried the four that
mattered. That is the ring-buffer class the earlier runs were read in, and the
condition needs the parent's keybits to be nonzero before it means anything.

Still unmeasured, and the next reading: `parent->core.live_count` beside
`count` at the flush's own `hammer2_base_insert()` call, `hammer2_flush.c:962`,
which is the pair the compiled-out `KASSERTMSG` at `hammer2_chain.c:3157`
tests and the pair that would name the block `no room` was raised for.

## The convergence reading was measuring the wrong pair, 2026-10-13

P4's synchronization criterion is read by `sync-empty-base.sh`'s own
`fingerprint()` comparison off the two images. Read against the images kept
from the run, that comparison had two defects, and both are in the
instrument rather than the filesystem.

The two sides come from the filenames, and the filenames are swapped.
`repro-master.img` carries its `CL` element as `pfs_type 3 (SLAVE)` and
`repro-slave.img` as `pfs_type 6 (MASTER)`. Three readings agree that this
is not a reading error: the media states it directly; `pfs-create` defaults
to MASTER with no uuid and to SLAVE with one, and only the vdc volume is
given `-u` in this harness; and the volume that was unmounted and remounted
four times is the one carrying 4,008 inodes at teardown, which is the slave
mount's topology. So the volume the harness writes the set into, and names
`MASTER`, is the SLAVE element, and every directional reading taken from
those names was reversed.

The count was also wrong in kind. `nm=$(grep -c ' FILE$' ...)` greps the
whole fingerprint, and the fingerprint emits dirent lines as
`print "dirent", name, dinum, $2`, so the pattern matches the dirent lines
whose type is FILE. On these images it read 4,800 "file entr(ies)" on a
volume holding 400 file inodes. The population assertion that exists so two
empty fingerprints cannot read as agreement therefore passed on a tree that
was 90 percent absent.

Read correctly, with each side taken by the role its own media states:

| element | short side (SLAVE) | full side (MASTER) |
| --- | --- | --- |
| file inode | 401 | 4401 |
| data block | 400 | 4400 |
| dirent | 4401 | 4401 |

Every directory entry arrived and the inode and data trees did not. Which
files went missing is not random: the short side holds all 400 `g*` files,
written during the unmount cycles while both elements existed, and none of
the 4000 `f*` files, written before the SLAVE element was created. The set
that predates the element is the set that did not cross; the set written
while the element was live did.

The remaining comparison is `cmp -s` captured into the check's status where
three command substitutions now run between it and the check, so the check
reported the status of a `grep -c`, which is always 0. The convergence check
passed unconditionally on any pair of images, including a pair that differs
by 8,000 lines. Fixed to capture the comparison into a variable first.

The trees also differ in radix, not only in coverage: the slave's `CL` root
is `0x0/12` over a `0x400/5` indirect, 32 slots, where the master's is
`0x0/63` over `0x400/7`, 128 slots. Both reach the same `0x400/0` inode with
`f2327` and `f2141` under it, so the content is shared and the shape is not.
That is the same slot-count divergence the refusals were traced to, seen
from the other end: the destination builds its indirect blocks narrow.

Unmeasured, and what would separate the two remaining causes: whether the
copied chains were written and then lost at the unmount, or never written.
The unmount prints `122239 modified` chains still allocated as it leaves,
which says the volume held modifications it did not write, but that is the
SLAVE volume's teardown under the ROOT mount whose element the scan uses,
so it does not say whether those are the copied inodes. A run that reads the
slave image before any unmount, with the master mount still up and the sync
thread quiesced, separates them.

## The refusals cannot account for the loss, and the arithmetic says so, 2026-10-13

The run of 2026-10-13, read with the corrected instrument, reports the two
sides by role and the shortfall by element class:

    slave/master by type: inode 801/4801, data 800/4800, dirent 4801/4801

Every directory entry arrived; 4000 of the inode tree and 4000 of the data
tree did not. The count of refused blocks in the same run is 340
(`create_indirect: new ... does not fit parent ...`, 320 at `0x400/7` under
`0x440/6` and 20 at `0x480/7` under `0x480/7`). A refusal that loses a block
can lose at most the copies that block carried, so 340 refusals cannot be the
source of a 4000-inode absence. The guard is a contributor, not the cause.

What the same log says instead is `syncthr: update inode` 3873 times: 3873
inodes were reached and marked synchronized, against 801 that exist on the
slave's media. The copies were made, the stamp was set, and the flush did not
carry them. The unmount agrees, printing `122239 modified` chains still
allocated as it leaves. That is a write-back failure in the sync thread's own
element, which is the path this port's two sync helpers exist to bridge, and
it is where the reading now points rather than at the radix.

Which files went missing fixes the timing. The short side holds all 400 `g*`
files, written during the unmount cycles while both elements existed, and none
of the 4000 `f*` files, written before the SLAVE element was created. The set
that predates the element is the set that did not cross.

The run also produced five soft lockups, and they are not a filesystem
reading. All five are on `irq#4 ttyS0`, the serial console, in `swapper` on an
otherwise idle CPU, and they appear only in the run whose log reached 22 MB,
against zero in the twelve runs before it. The cause is an ungated `kprintf`
in `hammer2_sync_insert()`, one line per copied element, 102,370 lines for
this set; the print is gated on the same bit as `START_SCAN` now. A probe that
floods its own console and then reports the watchdog's complaint as a
filesystem defect is measuring itself.

## The copies are stamped done in one pass and never written, 2026-10-13

The sync thread's own counts, per pass, from the 2026-10-13 run:

    passes (sync_slaves pfs CL): 37
    update inode events:        3873
    pass 1 updates 3873
    pass 2 updates 0
    ... passes 2 through 37: 0

Every inode the thread ever marked synchronized, it marked in the first pass.
The remaining 36 passes found nothing to do. The volume ends with 801 file
inodes on media against 4801 on the master, so 3873 stamps were set for a set
that only partly arrived: the thread copied, stamped, and the flush did not
carry the copies, after which no later pass had anything left to try. That is
why the loss is total for the set present when the element was created and
zero for the set written later: by the time the later files existed the thread
had already decided the inode was synchronized.

The count of refusals in the same run is 340 and the count of failed passes is
745. Neither can produce a 4000-inode absence from a 4000-file set, so the
radix guard is a contributor and the write-back is the defect, in this order:
the copies do not reach media, and the thread's stamp hides that.

## The whole loss happens in one pass, and the stamp is what stops the retry, 2026-10-13

The pass-resolved counts settle the mechanism the earlier note inferred from
totals. The sync thread ran 37 passes and emitted 3873 `syncthr: update inode`
events, and every one of them is in pass 1:

    pass 1 updates 3873
    pass 2 updates 0
    pass 3 updates 0
    ...
    pass 37 updates 0

`update inode` is emitted once per inode whose modify_tid is set to the
focus's, so 3873 is a count of distinct inodes stamped synchronized, not a
count of retries. The slave's media ends with 801 file inodes. 3873 were
stamped and about 800 arrived, so roughly 3000 stamps were set for inodes
whose chains were never written, and the 36 passes after the first found
`want_update == 0` for all of them and did nothing.

That closes the chain. The thread copies and stamps in one pass; the flush
does not carry the copies to media, and the unmount leaves `122239 modified`
chains allocated; and because the stamp already equals the focus's
modify_tid, no later pass retries. A stamp set before the flush proves the
copy reached media is what converts a write-back failure into a permanent
absence, and it is why the loss is total rather than partially repaired.

The 340 refusals in the same run are a contributor and not the cause: each
one can lose at most the copies its block carried, so they cannot produce a
3000-inode shortfall. The order is the stamp and the write-back first, the
radix divergence second.

## The initial synchronization of a joined element copies none of the tree that predates it, 2026-10-13

The images from the run that carried the corrected instrument separate by
file, not by count, and the separation is total. Every file in the set is
named either `f<n>`, written to the master's cluster mount before the SLAVE
element was created, or `g<c>-<n>`, written during the unmount cycles while
both elements existed. Reading each side's inode tree by those two prefixes:

    MASTER:  f* 4000, g* 799
    SLAVE:   f*    0, g* 799

Zero of the 4000 files that predate the element reached the slave's inode
tree. All 799 written while the element was live did. The boundary is not the
key, the radix, the file size or the block type; it is whether the file
existed at the moment the element joined the cluster.

That is the defect, and it is narrower than the three radix readings and the
write-back note above taken alone: the INITIAL full synchronization of a
newly joined element copies nothing of the master's existing tree, while the
incremental synchronization after it copies everything. The radix guard and
the stamp both act inside that first pass, which is where all 3873
`syncthr: update inode` events fall, and the 320 refusals of a keybits-7 block
under a keybits-6 parent are all in it. Which of the two is the producer is
still open; the pass boundary says both are confined to the pass that has to
copy the pre-existing tree, and no later pass is offered another chance at it
because the stamp is already set.

## The write-back helper was a no-op on every pass, and the flag proves it, 2026-10-13

`hammer2_sync_flush()` gated its work on `chain->flags & HAMMER2_CHAIN_FLUSH_MASK`
and did nothing when the test failed. A print added at that gate, in the
run now in flight, reports which way it went on every pass:

    sync_flush: clindex 1 chain 000000006443b1d2 not flagged (00046102)

Decoding `0x00046102` against the header: ALLOCATED, TESTEDGOOD, COUNTEDBREFS,
ONRBTREE, BLKMAPPED. None of the four `FLUSH_MASK` bits (MODIFIED 0x00000001,
UPDATE 0x00000040, ONFLUSH 0x00000200, DESTROY 0x00000004) is set. So the
helper took its empty branch and returned without calling `hammer2_flush()`.

The pass count and the skip count are equal on every reading: 22 passes and
22 `not flagged`, then 26 and 26. One skipped write-back per pass, every
pass, with no exception. That is a total write-back failure matching the
observed loss, and it is larger than the 340 refusals and consistent with the
3873 stamps against 801 inodes on media.

The flag is gone because `hammer2_chain_setflush()` stops at the first inode
chain, the descending flush clears ONFLUSH on its way down, and no inode is on
the sync queue to bridge this thread's own changes. The port's comment above
the helper predicted exactly this; what it did not have was the value of the
flag at the gate, which is what the print supplies. The test could not see the
state it existed to detect.

The repair is to set ONFLUSH on the element root before the test rather than
asking whether another path already did, and to keep `FLUSH_ALL`, which is what
makes the descent pass through PFS roots instead of stopping at them. Whether
that alone converges is the next run's reading.

## 801 is the baseline the sync thread never added to, 2026-10-13

Two runs with the corrected instrument, read off their own media:

| | run 1 | run 2 |
| --- | --- | --- |
| sync passes (`sync_slaves pfs CL`) | 37 | 50 |
| `not flagged` (the write-back no-op) | 22 of 22 | 50 of 50 |
| `syncthr: update inode` (stamps) | 3873 | 0 |
| `sync_insert: focus` (copies attempted) | 102370 | 8837 |
| `does not fit` (refusals) | 340 | 30 |
| soft lockups | 5 | 0 |
| slave file inodes on media | 801 | 801 |
| master file inodes on media | 4801 | 4801 |

The slave's inode tree is 801 in both, and the master's is 4801 in both, while
the sync thread's own work differs completely between them: 3873 stamps in one
run and none in the other, 102370 copies attempted against 8837. The 801 does
not move with anything the sync thread does, so it is not what the thread
delivered. It is the set written on the master's cluster mount after the SLAVE
element was created, which reaches the slave through the normal mount and
flush path rather than through the synchronization pass; the 4000 that predate
the element are what the pass was supposed to carry and never did.

The write-back gate is a total no-op in both runs, 22 of 22 and 50 of 50 passes,
which is the defect itself and does not depend on how much the pass copied.
The zero soft lockups in run 2 confirm the five in run 1 came from the console
flood and not from the filesystem.

## The probe still floods its own console, and the source is a second print, 2026-10-13

Gating the `sync_insert:` print did not remove the console flood, because the
guest's debug bit has to stay on for two checks to read their counts. The
largest producer in the run with the write-back fix is a different print, and
it is ungated:

    103979  sync_insert:        (gated on 0x8000, and the bit is on)
     92233  create_indirect:     (NOT gated)
      3873  syncthr:
      1170  indirect_maint:

`create_indirect:` reports the inputs of the radix decision, and its condition
is `parent->bref.keybits > 0 && (keybits >= parent->bref.keybits || key <
parent->bref.key || key > parent_end)`. Every ordinary create from a parent
with a nonzero radix satisfies the second clause, so it prints on nearly every
call rather than on the refusal it was written for: 92233 lines against 440
refusals. This is the same shape as the 43,106-line mistake the record already
carries for an earlier version of this print.

So the five soft lockups on irq#4 ttyS0 in the 2026-10-13 runs are the probe
measuring itself, and the count is not a reading about the filesystem. The
check that reports them cannot be satisfied until the print is bounded to the
case it names, which is the next change to this script rather than to the
driver.

## The radix divergence, counted, 2026-10-13

The diagnostic at the radix decision printed its inputs on every create whose
result fell outside the parent's own radix, and the two shapes between them
are the whole of the divergence:

    88393  create_indirect: parent KEY/7 create_bits 0 ncount 128 count 32 -> keybits 7
    29440  create_indirect: parent KEY/6 create_bits 0 ncount 128 count 32 -> keybits 7

Both produce a keybits-7 block, from `ncount 128` over a parent holding 32
elements. The first builds a block at the parent's OWN radix, so it cannot be
that parent's child; the second builds one a level wider than its parent. The
refusal guard fires on 440 of these 117833, so the great majority are creates
that are placed somewhere other than the parent they were printed against.

Read together with the size rule, which is upstream's own and unchanged, the
number is what the rule produces: `nbytes` is `HAMMER2_IND_BYTES_NOM` for any
non-inode parent and for a file inode, 128 slots, and the keybits loop then
raises the radix until the block holds them. A directory inode gets 32 slots
instead, so the same tree split under an inode is narrow and split under an
indirect is wide. The master's own media shows both widths, 128 slots at
keybits 7 to 12 and 32 slots at keybits 62 and 63, so neither is wrong on its
own; what differs is which level happened to be full when the split was made.

## Forcing the write-back to run does not converge the slave, 2026-10-13

The no-op was repaired and the repair measured. Setting ONFLUSH on the element
root before the gate makes `hammer2_sync_flush()` call `hammer2_flush()` on
every pass instead of on none, and the flag print confirms the change from the
inside: 22 of 22 and 50 of 50 `not flagged` in the two runs before it, 0 in the
run with it. The flush runs, reports no error, and the run ends with 0 kernel
fatal.

Convergence is unchanged, to the digit:

| | before the repair | after it |
| --- | --- | --- |
| `not flagged` (skipped write-back) | 22/22 and 50/50 | 0 |
| flush error | 0 | 0 |
| slave file inodes on media | 801 | 801 |
| slave data blocks | 800 | 800 |
| slave dirents | 4801 | 4801 |

So the write-back helper being a no-op was a real defect and is not the cause
of the loss. The 801 is invariant across all three runs, including one with no
stamps at all and one whose flush ran on every pass, which is what says the
sync thread's copies are not what puts those 801 inodes on the slave. The
cause of the 4000-inode absence remains unfound, and the earlier notes naming
the radix guard or the write-back are both refuted as the cause by this run.

## The sync thread livelocks on 180 inodes and never reaches the rest, 2026-10-13

Counting the sync thread's own insert lines by the key it inserts, in the run
that stamped nothing (run 2, 50 passes, 0 stamps, 801 inodes on the slave):

    distinct focus keys inserted:        180
    key range of those:                  0x400 .. 0x4ff
    insert attempts per key:             69
    distinct defer pointers:             69, each seen once
    sync_slaves error 256 (EAGAIN):      69

Every one of the 180 keys is attempted 69 times, always into the same parent
`0x480/7`, and every pass returns EAGAIN. So the thread re-copies the same 180
inodes over and over and never advances to the remaining 3800 files. That is
why the slave holds the same 801 inodes in every run: the synchronization pass
never reaches the rest of the tree, regardless of whether the write-back runs.

The 801 itself is the set written to the master after the element was created,
which arrives by the normal mount path; the sync pass adds nothing because it
spins on a key range 256 keys wide out of the whole tree.

The loop that hides this has no progress guard. `hammer2_sync_slaves()` returns
EAGAIN when it defers an inode, the caller re-runs the scan, and the drain loop
at `hammer2_synchro.c:295` removes a deferral only when it is still the list
head, so each iteration defers the next inode and leaves the previous entry in
place. The deferral count never reaches the 1000 that would break the scan:
119 deferral events against a threshold of 1000. Upstream's loop is line-for-
line the same, so this is carried behavior reached by a condition this port
creates, not a port rewrite of the loop.

## The pass livelock dates from the slave-newer branch, 2026-10-13

The livelock has a commit. The branch `if (n < 0 && chain->bref.modify_tid >
sync_tid)` was added by `a2804b9` on 2026-10-12, and every log showing the
livelock postdates it. Counting the keys the sync thread inserts, per log:

| log | distinct focus keys | attempts per key | key range reached |
| --- | --- | --- | --- |
| before `a2804b9` | (none kept) | | |
| the 04:40 hang log | 1001 | 1 | 0x400 .. 0x7e8 |
| run 2, after it | 180 | 69 | 0x400 .. 0x4ff |

The thread that runs without the branch walks 1001 distinct keys and never
repeats one; the thread that runs with it repeats 180 keys 69 times and stops
at 0x4ff. The branch advanced the local scan and not the XOP, where every other
arm of the same switch advances both, so the master's scan stayed on the same
focus and the next iteration compared the same pair again.

`36d664b` reverts it to upstream's unguarded `n < 0` arm, which destroys the
stale local chain and lets the scan move on. The run to confirm it is in
flight; the reading that decides is the distinct-key count and the maximum key
reached, not the total number of inserts.

**Corrected 2026-10-14: the 180-key count does not isolate this branch.** The
same session's summary, a few hundred lines below, lists the slave-side error
rollup as a mechanism that "converts a per-key failure into a whole-pass abort,
and the next pass retries the same keys" (`hammer2_synchro.c` summary of
attempts, item 4). That is the same signature: a pass that aborts early retries
the same early keys on the next pass, and 180 keys attempted 69 times is 69
aborted passes. Both changes were in the tree on 2026-10-13 and both were
reverted within 35 minutes of each other, so the count in the table above reads
the two together and does not attribute the livelock to this branch alone. The
branch is not exonerated by this; see the entry below, which measures it
directly and finds it deadly for a different reason.

## The pass runs two turns and ends at the end of both scans, measured 2026-10-14

The `iters` and `exit` fields answer the question the one-action reading left
open, and the answer is not an error. From the run's own log,
`cluster-run-20261014-205625.klog`, consecutive passes read:

    filekeys ... acted 9769   ... iters 2 exit 1
    filekeys ... acted 9770   ... iters 2 exit 1
    ...
    filekeys ... acted 9776   ... iters 2 exit 1
    filekeys ... acted 17532  ... iters 7757  exit 1
    filekeys ... acted 65368  ... iters 20041 exit 1

`exit 1` is the loop-head break `chain == NULL && merror == HAMMER2_ERROR_ENOENT`,
which the code comments describe as both scans done. So the one-action passes are
not an error (exit 2 never appears) and not the deferral threshold (exit 3 never
appears). They run **two turns**: the first performs one action and advances,
the second finds the local scan exhausted and the XOP scan exhausted together
and leaves. One action, then both ends.

That is the shape of the failing run as well: its passes creep `acted` by one and
its `START_SCAN` carries the NULL sentinel, which is the same thing seen from the
start of the pass rather than the end.

The same run also contains passes of 7757 and 20041 turns, which walk the tree
and move `acted` by thousands. So one run holds both shapes, and the pass is not
uniformly shallow: it starts shallow and deepens as the tree it is offered
grows. A run that loses inodes is one where the interruption and the two resumed
passes all land among the two-turn passes, before the deep pass arrives.

Two things follow, and neither is a fix yet:

1. The two-turn pass is the object to explain. Both scans ending together after
   one action means the two cursors were at the last key each had, so the
   question is why the slave's element and the master's scan each present one
   key at that moment -- whether the element genuinely holds one chain then, or
   the scan is not shown the rest.
2. `sweep` is 0 again on this run, which converged. It remains 0 on every run
   that converged and has still never been read on a run that failed.

## The failing run's passes are one action deep, and its local scan starts empty, 2026-10-14

Read from the failing run's own saved log, `cluster-run-20261014-171347.klog`,
which is the input the counters were added for and which carries none of them.

Its 61 passes, by the cumulative `acted` field of each pass's `filekeys` line,
creep upward one at a time: `acted 58`, `59`, `60`, `61` ... `84` over the first
twenty passes, with `n>0 1` (one file key inserted) and `n<0 0` on each. One
action per pass. In 58 of the 61 passes the pass's own `START_SCAN` prints
`chain=00000000... (0xffffffffffffffff)`, which is the print's NULL sentinel:
the local scan began with no chain at all, so the slave's element root held
nothing to iterate.

With the 5-second sleep between passes, one key per pass is a tree of 4000 file
keys copied at 5 s per key. The pass never gets deep enough to do the bulk
copy, and the interruption arrives 8 s in. That, and not the destroy, is the
shape of the failure: the resumed thread completes its two passes (the phase
check reads `resume-passes=2`), and they are two more one-key passes.

This also explains why the destroy cannot be the whole story and why the
earlier key match was a subset. The 66 keys destroyed in that run are a
consequence of a shallow scan meeting an element that changes underneath it,
not the producer of the shortfall. The producer is that the pass does not
proceed past its first key per invocation.

What is not yet read: why the pass takes one action and returns. The two exits
that fit are the deferral threshold (`needrescan && list->count > 1000`, which
would need 1000 deferrals and does not match one action) and the loop head
`chain == NULL && merror == HAMMER2_ERROR_ENOENT`, which ends the pass when both
scans are done and is consistent with a local element that holds one key. The
next instrument is a per-pass count of loop iterations beside the reason the
loop left, which is one counter and one print, not a theory.

## The destroy is not the cause, and the shortfall tracks the pass's own progress, 2026-10-14

The counters added earlier in the day were read, and they refute the two entries
above them. Every phase-4 run of 2026-10-14, correlated:

| run | `n<0` | `sweep` | copied | acted | lines differ |
| --- | --- | --- | --- | --- | --- |
| `cluster-keys2` | 66 | - | 2 | 1878 | 132 |
| `cluster-deepstop2` | 40 | - | 2 | 1695 | 80 |
| `cluster-deepstop` | 25 | - | 28 | 42663 | 0 |
| `cluster-destroy-keys` | 41 | - | 44 | 41804 | 0 |
| `cluster-arm2` (instrumented) | 81 | 0 | 85 | 32610 | 0 |

Two readings follow. The second is a measurement; the first is a correction of
the entry above, and it is itself weaker than it first looked.

**The sweep arm is untested, not refuted.** `cluster-arm2` reads `newer 81 sweep
0`, and it also converged. It is the only run that carries the `sweep` counter,
and the failing runs predate it, so the counter has never been read on a failure.
A counter that reads 0 on the runs that pass says nothing about the runs that
fail. The burst shape that motivated the entry is still real in
`cluster-run-20261014-171347`, which carries no `sweep` counter at all, and its
`n<0 66` could be 66 compares or 66 sweeps. The two are separated only by running
a failure with the counter on, and that has not been done.

**More destroys converge.** `cluster-arm2` destroyed 81 keys -- more than the 66
that were lost in the run the earlier entry matched by key -- and its slave
matches the master entry for entry, 0 lines differ of 120179. So destroyed keys
are not lost keys: the earlier match was a subset, not an equality. A destroy
that the same pass re-creates is not a loss, and the compare arm's destroy is
exactly that. This reading holds regardless of the sweep question, because the
two runs it compares differ in `copied` too (85 against 2), so it is confounded
with progress and is stated as such.

**What separates the runs is how far the pass got before the interruption.** The
two failing runs read `copied=2` and `acted` of 1878 and 1695; the three that
converge read `copied` 28 to 85 and `acted` 32610 to 42663. The pass that is cut
almost at once leaves the slave behind, and the resume does not close it. The
`stop-depth` field does not explain it: `cluster-keys2` and `cluster-arm2` both
read `stop-depth=0 wanted 0` and land on opposite sides, where
`cluster-deepstop` reads `wanted 400` and lands at 28. The interruption is a race
on when the unmount reaches the running pass.

The failing run's own inode stamps say what it never reached: 61 passes and 60
`syncthr: update inode` events, every one for the PFS root `00000000db48b7e1`
and none for a file inode. The pass processed 57 keys ahead of the local scan
and 66 behind it and then stopped, and the directory's file keys, which are
4000 of them, were never offered to it at all.

So the loss is not established to be the destroy and not established to be a scan
that ends early. What is established is that the losing pass stops after about
123 keys and never reaches the file keys, and that the passes after it do not
reopen the question. The next measurement is a failure with the `sweep` counter
on, and it decides which of the two the `n<0 66` was.

## The guard livelocks the sweep path by construction, measured 2026-10-14

The guard was restored and run, and the pass hung. The mechanism is structural
and does not depend on the 2026-10-13 attribution at all.

The `n < 0` arm is entered from two places. One is the compare, where `n` comes
from `hammer2_chain_cmp()`. The other is the end-of-scan arm, `chain && merror
== HAMMER2_ERROR_ENOENT`, which sets `n = -1` on **every** iteration for as long
as the local scan has chains left and the XOP still reports ENOENT. On that
path `n` is not a comparison result; it is a constant that selects this arm
until the local scan empties.

So a guard here that skips the destroy and sets neither `advance_local` nor
`advance_xop` does not stall one iteration. It re-enters the same arm on the
same chain with the same `n = -1`, forever. There is no state that changes
between iterations.

The run's own evidence:

    [  148.229360] START_SCAN IP=b6a9cb23fd8a8001 chain=0000000051b2c542 (0000000000000400)
    [  370.385810] INFO: task kworker/5:1:115 blocked for more than 122 seconds.
    [  370.385844] Workqueue: events hammer2_sync_work [hammer2]
    [  370.386294]  hammer2_flush_core ... hammer2_inode_chain_flush ... hammer2_vfs_sync_pmp

The pass's own `START_SCAN` is 222 s before the hung-task report, the guest load
never falls below 4, and the unmount never returns: `umount /mnt/h2c` reports
"target is busy" on every attempt, and only a guest restart clears it. This is
the "worst case" the NULL-chain note at `hammer2_synchro.c:640` describes as
worse than a copy that does not converge.

Two consequences:

1. The guard is not re-addable in the shape it had, and the two measurements
   separate into a hard hang and a slow stall, distinguished by one line.
   `a2804b9` set `advance_local = 1` inside the guard. A reproduction of the
   guard that omitted that line (the shape committed at `ccb7b1c`) re-entered the
   same arm on the same chain with the same `n = -1` and never left it: the pass
   hung in 122 s and the unmount stayed busy until the guest restarted. Restoring
   the line removes the hang, and does not remove the stall: with it,
   `a2804b9`'s own reading is 180 distinct keys attempted 69 times, which is the
   XOP side of the pair never moving. So the two fields are load-bearing and
   neither is sufficient -- `advance_local` alone stops the hang and leaves the
   XOP static, and no advance at all hangs outright.
2. A fix for the sweep path has to move both cursors. The candidate, not yet
   tested, is the guard with `advance_local = 1` and `advance_xop = 1`, plus a
   restart of the XOP scan from the local scan's key on that path. The scan's
   position is `xop->key_beg` (`hammer2_synchro.c:669`, set to
   `HAMMER2_KEY_MIN` at start), not `collect_key`, which only tells the
   collector which FIFO entries are behind; so the restart is a retire and a
   fresh start with `key_beg = chain->bref.key`. That is what returns a focus for
   a key the local scan is holding and turns the sweep back into the compare it
   was meant to be. `advance_xop` with no new scan re-reads the same focus, which
   is the 180-key stall; the restart is what gives it a new one.

## Reverting the branch restores the key advance, 2026-10-13

The revert is measured against the livelock, on the same reading that named
it, one pass into the run:

| reading | with the branch | reverted |
| --- | --- | --- |
| distinct focus keys inserted | 180 | 8041 |
| maximum key reached | 0x4ff | 0xffedec6993848001 |
| attempts at the most repeated key | 69 | 1 |
| refusals (`does not fit`) | 340 in a full run | 120 by the first pass |
| soft lockups | 5 | 0 |

The scan walks the whole key space now instead of spinning on the first 256
keys, and the inode stamps follow it: 3911 by the first pass against 0 in the
run that livelocked. The refusal count falls with it, 340 to 120, which is what
would be expected if the refusals were a symptom of the scan failing to place
its blocks rather than a cause in their own right.

Convergence is not yet read; this is the reading that says the livelock is
repaired, and the run is still in its cycles.

## The action switch is upstream's again, checked by diff, 2026-10-13

The revert leaves the port's scan switch byte-identical to DragonFly's, which
`diff` between the two trees' `hammer2_sync_slaves()` from "Take action based
on comparison results" to the first `advance_xop = 1` reports as no difference
at all. That is the port's own rule for a carried file: an edit upstream would
not recognize is a defect even when it works, and this one did not work. The
two remaining port additions in this function are the `want_update` ternary,
which skips a null chain where the carried code dereferenced it, and the
slave-side error rollup; neither is in the switch that advances the scan.

## The scan livelock and the write-back no-op are independent, 2026-10-13

The two repairs were tested one at a time, and each moves a different number.
Reading the slave's file inodes off its own media after each run:

| tree | distinct keys | soft lockups | slave file inodes |
| --- | --- | --- | --- |
| the livelock branch, write-back not forced | 180 | 5 | 801 |
| the branch reverted, write-back not forced | 8061 | 0 | 728 |
| the branch reverted, write-back forced | 8041 | 0 | 801 |

Reverting the branch repairs the scan: it walks 8061 distinct keys where it
walked 180, and the watchdog stops complaining. The slave's inode count does
not follow, 801 to 728, so the scan reaching a key and the inode arriving on
media remain two different things. Forcing the write-back on the repaired scan
is the pairing not yet run, and it is the run in flight.

The 3911 inodes the repaired scan stamps against the 728 that arrive is the
same gap the earlier runs showed, 3873 against 801, which is why the two
defects have to be read separately: the scan determines how many inodes are
stamped, and the write-back determines how many of those reach media.

## Three configurations, three different mechanisms, and 801 does not move, 2026-10-13

The repairs were tested one at a time and then together. Reading the slave's
file inodes off its own media after each run:

| tree | distinct keys | stamps | skipped write-back | slave file inodes |
| --- | --- | --- | --- | --- |
| the livelock branch, write-back not forced | 180 | 3873 | 22 of 22 | 801 |
| the branch reverted, write-back not forced | 8061 | 3911 | 50 of 50 | 728 |
| the branch reverted, write-back forced | 8003 | 3873 | 0 | 801 |

Each repair does what it was written to do, and the number that decides P4
does not move. The stamps range over 3873 to 3911 while the inodes that arrive
range over 728 to 801, so the two are not connected the way the earlier notes
assumed: if 3873 stamped inodes were reaching the slave's media there would be
3873, and if the write-back were the gate then forcing it on the repaired scan
would have moved the count, which is what the third run tests and it does not.

The slave's media also holds LESS data than the master's, 17.1 MB of non-zero
bytes against 20.9 MB, so it is not carrying written-but-unreferenced copies
that the tree fails to point at. The copies are not on the media at all.

What remains to be read is where the chain the scan copies lands. The scan's
parent comes from the slave's element, and `hammer2_sync_insert()` passes
`thr->pmp` to `hammer2_chain_create()`, so the new chain is built under the
slave's CL tree; whether the flush of that tree reaches vdc's own hmp is the
next question, and it is the first one this session has been able to state
without also having to guess which defect it belongs to.

## The chain lands on the right device, checked at the allocation, 2026-10-13

The last place the copies could have gone was the wrong hmp, and that is
ruled out by reading the two functions rather than by a run.
`hammer2_chain_create()` overwrites its `hmp` argument with the parent's:
`if (parent) { ... hmp = parent->hmp; }`. The scan's parent comes from
`hammer2_inode_chain(ip, idx, ...)`, which returns
`cluster->array[clindex].chain`, and the sync thread's `idx` is its own cluster
element, so the parent is the slave's element chain and its hmp is vdc's. The
created chain, the flush, and the media write are all directed at the slave's
own device.

So the copies are attached to the slave's element on the slave's device, the
write-back runs on every pass, the scan walks the whole key space, and 801
inodes arrive where 3873 are stamped. Every mechanism this session could state
has been tested and none of them accounts for the gap between the two numbers.
What is missing is a reading the run does not currently take: whether the
chains that the scan stamps are still attached to the slave's element when the
flush walks it, or have been detached between the stamp and the flush. That is
the next instrument, and it belongs in `hammer2_sync_flush()` beside the
existing flag print, counting the element's children against the number the
pass stamped.

## Every directory entry crosses and no inode behind them does, 2026-10-13

The sharpest reading of the session is the per-name split, taken from the
images of the run that carried both repairs, and it is the same before and
after them:

    MASTER:  f* inodes 4000, g* inodes 799
    SLAVE:   f* inodes    0, g* inodes 799
    both:    dirents 4801, f* dirents included

The slave holds all 4801 directory entries, the entries naming the 4000 `f*`
files among them, and holds no inode for any of those 4000 files. A directory
entry that names an inode the volume does not hold is the shape of the loss:
the scan creates the dirent in the destination's directory and does not create
the inode the dirent refers to.

That is why the two repairs move nothing. They both act on the inode copy: the
scan's advance decides how many inodes are reached, and the write-back decides
whether a reached inode is written. Neither creates the inode for a dirent that
arrived without one, and the 799 `g*` files show the path works when the
frontend creates the pair together on the destination. The failure is specific
to the pair being created by the synchronization instead.

Unmeasured still, and the next reading: whether `hammer2_sync_insert()` is
called at all for an `f*` key, or whether the scan reaches the key, finds the
dirent already present, and advances without creating its inode. The
`sync_insert:` print counts calls, not keys, and the two have to be separated
by a print at the insert site naming the key and whether the chain was created.

## The dirents ride in the indirect blocks and the inodes are never inserted, 2026-10-13

The sync thread's own insert calls, classified by the type it passes to
`hammer2_chain_create()`, from the run that carried both repairs (44 passes):

    type 2 INDIRECT   35576 calls
    type 1 INODE       3946 calls over 75 DISTINCT keys
    type 0 DIRENT         0 calls

Two things follow that no earlier reading had. The dirents are never inserted
one at a time; they arrive inside the INDIRECT blocks the thread copies whole,
which is why all 4801 of them reach the slave and why their arrival says
nothing about the inodes. And the inode inserts cover 75 keys, each retried
about 52 times, which is roughly once per key per pass across 44 passes: the
same small set of inodes is attempted every pass and never sticks.

The 4000 files that predate the element have inode-number keys well outside
those 75, and the scan never presents them, so no insert is attempted and no
inode is created for the dirents that already arrived. That is the loss in the
terms the media shows it: a dirent present with no inode behind it.

What is not yet measured is why the 75 keys fail and why the rest are never
presented. Both are scan-coverage questions inside `hammer2_sync_slaves()`,
and both need a print at the insert site that names the key and whether the
chain was created, rather than a count of calls.

## The scan presents 75 inode keys and the set has 4001, 2026-10-13

The inode-type inserts, broken down by the key they carry, in the run with both
repairs (44 passes):

    key 0000000000000000/16   3872 calls   (once per pass)
    key 0000000000000400/0       1 call
    key 0000000000000401/0       1 call
    ... 73 more, each once ...

75 distinct keys in all, against the 4001 file inodes the set holds. The keys
present are the low inode numbers, `0x400` upwards through `0x42x`, and the
3872 calls at key 0 are the same key re-tried on every pass.

So the scan does present inode keys, and it presents a fixed small set of them.
The 4000 files whose inodes are missing are keyed by inode number in the same
low range and one directory level down, and the scan does not present them:
`chain` advances by `hammer2_chain_next()` after each comparison, so it walks
whatever the local tree holds, and the local tree is the slave's own, which
holds the inodes it already has. The scan compares local against focus and the
master's extra inodes never enter it, because the iteration is driven from the
local side.

That is the last measured fact of the session and it needs no new mechanism to
state: the scan cannot copy an inode it never iterates, and it iterates the
slave's tree. Whether the carried loop is meant to iterate the focus instead
for the create side is the one question left, and it is a question about
`hammer2_sync_slaves()`'s iteration, not about any of the four mechanisms this
session tested and refuted.

## The thread inserts the index and not the inodes, by type, 2026-10-13

Splitting the sync thread's insert calls by the blockref type it passes and by
the focus key it copies, in the run that carried both repairs:

| insert type | calls | distinct focus keys | of those, hash-shaped |
| --- | --- | --- | --- |
| INDIRECT (2) | 35576 | 7928 | 3960 |
| INODE (1) | 3946 | 75 | 41 |
| DIRENT (0) | 0 | 0 | 0 |

The file keys are hash-shaped (a `f<n>` name hashes to something like
`0xa8d14a5762868000`). The thread inserts 3960 of those as INDIRECT blocks and
41 as INODE records, while the set holds 4001 files. So the structure that
names the files is copied and the inodes the names refer to are not: 3960
against 4001, and the 41 that do get an inode insert are re-tried about 52
times each across the passes, which is why they never settle either.

That is the same statement the media makes from the other end, and now it is
located in the code: the dirents arrive inside the copied indirect blocks, and
no INODE insert covers the keys those dirents name. The scan reaches the key,
compares, and takes an arm of the switch that moves the block rather than the
`n > 0` arm that calls `hammer2_sync_insert()` with `focus->bref.type`, which
for a file inode's index is INDIRECT and for the inode itself is INODE. Which
arm is taken for the 4001 file inodes is the question, and the `n` it computes
comes from `hammer2_chain_cmp(chain, focus)` over the local tree.

## Three port additions in the sync path were each a livelock, 2026-10-13

The scan now matches upstream: `diff` between the two trees' bodies from "Take
action based on comparison results" to the closing brace reports only the
port's two mechanical shim substitutions, `kmalloc` for the three-argument
DragonFly call and the FreeBSD port's `chain_next()` without a `key_beg`.
Everything else in that body, including the arms that advance the scan, is
DragonFly's again.

Three additions had to come out, and each had the same shape, a pass that
cannot finish its walk:

- `if (n < 0 && chain->bref.modify_tid > sync_tid)` advanced the local scan and
  not the XOP, where every other arm advances both. The master's scan stayed on
  the same focus.
- The `rerror` rollup latched the first slave-side failure and returned it as
  `merror`, which aborts the pass at the `merror` test. One failing insert then
  ended the pass and the next pass retried the same early keys: 75 inode keys
  attempted about 52 times each across 44 passes.
- The `want_update` ternary skips a null chain rather than dereferencing it,
  which is a fault fix rather than a livelock, and stays.

Upstream discards `nerror` and `serror` precisely so that a per-key failure
stays per-key. Both rollups were attempts to improve on that, and both
converted a local failure into a whole-pass retry loop.

## A known fail-open in the sync path, restored deliberately, 2026-10-13

Removing the `rerror` rollup restores upstream's behavior, and upstream's
behavior is fail-open: `hammer2_sync_slaves()` assigns `nerror` from every arm
of its switch and never reads it, so a slave-side failure to copy a chain is
discarded, the inode's `modify_tid` is still set to the master's below, and
every later pass sees the two equal and does not retry. A destination that did
not receive a chain is reported as synchronized.

That is worth stating plainly rather than leaving implied. The rollup that
would have closed it was written, run, and reverted, because it converted the
discarded per-key failure into a whole-pass abort and the next pass re-tried
the same early keys forever: the livelock signature of 75 inode keys attempted
about 52 times each across 44 passes. A fix that prevents one silent loss and
stops the copy entirely is not a fix.

So the tree carries a known fail-open at that site, with the reason it is there
in a comment beside it and here. It is not a shipping state; it is the state
the current reading is taken in, and closing it needs the failure to be
recorded per key without ending the pass, which the deferral list already
exists to do.

## The rollup was not the cause either, 2026-10-13

Removing the `rerror` rollup and the pass-abort it fed leaves the reading
unchanged: 75 distinct inode keys, 4023 inode-type inserts, 3950 stamps, 8080
distinct focus keys presented, against 4001 files in the set. So the third port
addition in this path is also not the cause of the missing inodes.

Four mechanisms have now been proposed for this defect and four have been
refuted by a run:

1. the radix guard's refusals (340, too few)
2. the write-back being a no-op (repaired, count unmoved)
3. the scan livelocking on 180 keys (repaired, count unmoved)
4. the slave-side error rollup aborting the pass (removed, count unmoved)

The numbers that have not moved through all four are 75 distinct inode keys and
4001 files. The scan presents 8080 distinct focus keys, of which 4001 are
hash-shaped, so the keys are being offered; the insert path creates inode-type
chains for 75 of them. Where the other 3925 inode keys go, and why the same 75
recur about 54 times each, is the question none of the four mechanisms answers.

## The sync builds one full-width indirect per key and wedges, 2026-10-13

The hang log of the run that removed the error rollup is 115 MB and 1,109,698
lines, and 1,083,951 of them are two prints repeating the same pair:

    sync_insert: focus 00000000000004e7/0 into parent 0000000000000480/7 type 2
    create_indirect: parent 0000000000000480/7 create_bits 0 ncount 128 count 32 -> keybits 7 key 00000000000004e7
    sync_insert: focus 00000000000004e8/0 ...
    create_indirect: parent 0000000000000480/7 ... keybits 7 key 00000000000004e8

A keybits-7 block spans 128 keys, and the parent `0x480/7` spans exactly
`0x480` to `0x4ff`. So each new indirect block the thread creates at keybits 7
covers the parent's whole range, has to absorb every other child to be
representable, and is rebuilt on the next key: 547,925 `sync_insert` calls and
536,026 `create_indirect` calls, one full-width block per key from `0x400` to
`0x4ff`, before the run wedged past 1500 s with the guest holding three mounts,
the module busy, and five tasks in D state.

That is the same defect the refusals and the 75 inode keys have been pointing
at from three directions. `hammer2_chain_create_indirect()` chooses the new
block's radix from `ncount`, which is 128 for a 16 KiB block under any
non-inode parent, and then raises keybits until the block holds them. Under a
parent that is itself keybits 7, the result is a child the same width as its
parent, which cannot be its child. The port's guard refuses that block and the
refusal leaves the element unbuilt; without the refusal the block is built and
the tree is rebuilt per key until the run wedges.

Which of the two the fix belongs at is now a single question with two measured
outcomes, and the four mechanisms tested earlier were all symptoms of it: the
refusals are the guard declining these blocks, the 75 inode keys are the ones
whose blocks were declined, and the write-back has nothing to write because the
blocks it would write were never validly placed.

## The cap sits on the computed keybits, under a nonzero-keybits parent only, 2026-10-13

`hammer2_chain_indkey_dir()` returns the radix of the new indirect block, and
the cap applied to it is scoped by `parent->bref.keybits > 0`. Only an INDIRECT
or FREEMAP_NODE parent has a nonzero keybits; an inode parent has 0, so the cap
is skipped for it and a directory inode's children keep their own radix. That
is the case the invariant does not constrain, and the guard matches it.

The cap is placed between the `ncount` expansion loop and the mask, so the mask
below realigns the key to the narrowed radix rather than leaving the two out of
step. That is the piece the two earlier attempts lacked: both tested the
caller's `create_bits`, which `hammer2_chain_create_indirect()` is passed as 0
on every call, so neither could ever fire, and both were reverted on that
reading rather than on the radix being wrong to cap.

A `hprintf` counts the fires, so a run reports whether the cap acted at all
instead of leaving it to be inferred from the outcome. The run to read it is in
flight.

## The cap removes both failure modes, 2026-10-13

With the radix cap applied on the computed keybits, one pass into the run, and
read against the same counters in the runs before it:

| reading | before the cap | with the cap |
| --- | --- | --- |
| `create_indirect` calls | 536026 | 1001 |
| `does not fit` refusals | 340 | 0 |
| `sync_insert` calls | 547925 | 1001 |
| inode-typed inserts | 4023 | 762 |
| distinct focus keys | 8080 | 1001, none repeated |
| soft lockups | 5 | 0 |

The cap fires on the exact shape the hang log showed, `capped keybits 7 -> 5
under parent 0x440/6`, and after it nothing is refused and nothing is rebuilt
per key. The scan walks 1001 distinct keys once each, which is the pattern the
healthiest log of the day showed and the livelocked runs did not.

So the equal-keybits child was the mechanism behind all of it: the refusals
were the guard declining such a block, the 536026 recreations were the tree
rebuilt once per key when it was allowed, and the four mechanisms tested
earlier were its symptoms. The convergence reading is still pending, and it is
the one that decides whether the inodes now follow the keys.

## The cap stops the storm and loses the file keys, 2026-10-13

The cap removes the refusals and the per-key rebuilds, and it also changes
which keys the scan presents. Read from the run carrying it:

| reading | before the cap | with the cap |
| --- | --- | --- |
| distinct keys presented | 8080 | 1001 |
| of those, hash-shaped (file keys) | 4001 | **0** |
| `does not fit` refusals | 340 | 0 |
| `create_indirect` calls | 536026 | 1001 |

Zero of the 1001 keys is a file key. The scan no longer reaches the directory
hash space at all. So the cap is not a fix: it silences the refusal storm and
the wedging by keeping the tree narrow enough that the same-width block is
never asked for, and the price is that the file keys are never presented
either. A narrower tree means fewer keys, and the 4000 files live in the wide
hash space the narrower tree no longer covers.

That is a cleaner statement of the actual problem than any of the four
mechanisms tested before it: the destination has to represent a directory of
4001 entries whose keys span the full 64-bit hash space, and every route this
session tried either refuses the wide blocks it needs, rebuilds them per key,
or narrows the tree until the keys fall outside it. What is missing is the
route upstream takes, and it is not in any of the branches that have been
edited here. The next reading is upstream's own directory-split behavior,
which this port has never exercised because no test before this one drove a
single directory past 4000 entries.

## Summary of the P4 synchronization attempts, 2026-10-13

**Superseded by the 2026-10-14 list below, which is the one to read before
changing this path.** Kept because the 4000-file reading at its end still holds.

Five changes were made to the cluster synchronization path and five were
measured and reverted or reduced. Recorded together so none is re-tried:

1. **Radix cap on the caller's create_bits** (pre-existing note). It cannot
   fire: the caller passes 0 on every call.
2. **Radix cap on the computed keybits.** It fires, 30 times in one pass, and
   removes the refusals and the per-key rebuilds, but the narrowed tree covers
   no file keys: 0 of 1001 presented against 4001 of 8080 without it.
3. **Forcing ONFLUSH in `hammer2_sync_flush()`.** Makes the write-back run on
   every pass instead of none, and moves the slave's inode count 728 to 801
   against 4801. Not the gate the copies wait on.
4. **The slave-side error rollup.** Converts a per-key failure into a
   whole-pass abort, and the next pass retries the same keys.
5. **The slave-newer branch in the scan's action switch.** Advances the local
   scan and not the XOP; reverting it restores the walk from 180 keys to 8061.

What stands in the tree from the session: only the discarded flush error being
read, and the notes recording why each of the five is not the fix. The switch
in `hammer2_sync_slaves()` is upstream's again, verified by diff.

The one reading that has not changed through all five: the slave holds all
4801 dirents and 801 of the 4801 inodes, and the 4000 files that predate the
element are the ones missing. Every change above moves a counter that is not
that number.

## The cap does not prevent the teardown wedge, 2026-10-13

The run carrying the radix cap reached its fourth unmount and then wedged the
same way run 6 did: the log stops at `hammer2_kill_sb: after unmount: 4008
inode, 126312 chain, 122179 modified, 499 dio still allocated` at t=447, with
`umount` in D state, three mounts held and the module busy, until the guest was
hard-cycled. So the cap removes the refusal storm and the per-key rebuild
inside a pass and does not remove the wedge at teardown, which is a second
failure on the same path.

Two runs have now wedged in teardown, both at the fourth unmount, both with the
same `122179 modified` and `499 dio still allocated` and the same 4008 inodes.
That number is the master's cluster mount, which holds the whole 4008-inode
set, and the wedge is in the unmount of the volume whose element the scan uses.

## The scan restarts from key 0 on every deferral and never completes one walk, 2026-10-13

The START_SCAN print names the inode being scanned, and the counts separate the
two cases completely, from the run with both repairs:

    217  START_SCAN IP=b6a9cb23fd8a8001   <- the CL directory, restarted 217 times
      1  START_SCAN IP=00000000000013a0   <- each child inode, scanned once
    ... one each for 000000000000139f down to 0000000000000400 ...

    sync_slaves error 0     50 times   (the passes outside the cycles)
    sync_slaves error 256  217 times   (EAGAIN, each with a defer pointer)

`HAMMER2_ERROR_EAGAIN` is set at `hammer2_synchro.c:838` whenever a pass defers
a child inode, and the caller answers EAGAIN by re-entering the drain loop,
which calls `hammer2_sync_slaves()` on the PFS root again. The root scan
starts at `HAMMER2_KEY_MIN`, so it restarts the CL directory from key 0 every
time. 217 deferrals, 217 restarts, and the directory's own walk never reaches
the 4000 file keys that live above the inode-number range.

The drain loop is upstream's, checked by diff, so this is carried design
reached by a condition this port creates. The three port additions that could
have been the trigger have all been removed and the restart count did not
change, so the condition is not in the scan's own code.

## Three consecutive runs wedge before a pass completes, 2026-10-13

Runs 6, 7 and 8 all ended the same way: the guest stopped answering ssh, the VM
stayed running with the module loaded and mounts held, and the harness's guest
half never returned, so no verdict and no kernel log were produced. Run 8's own
out file is empty for that reason.

That is the constraint the diagnosis is now under, and it is not a property of
any one change:

- run 6 removed the error rollup and wedged
- run 7 carried the radix cap, which removes the refusal storm and the per-key
  rebuild, and wedged too
- run 8 carried only the arm-counting instrument, with every port addition
  reverted, and wedged

The three runs differ in what the sync path does and agree in where they end,
so the wedge is upstream of all of them. It is also why the arm counter added
in run 8 printed nothing: it reports at the end of a root scan, and no root
scan reached its end in a run that wedged.

The reading that has to come before any further change is therefore the wedge
itself rather than the missing inodes: what blocks the final unmount. Two of
the wedged logs are kept beside the images and both stop at `hammer2_kill_sb:
after unmount: 4008 inode, 126312 chain, 122179 modified, 499 dio still
allocated`, which is the master's cluster mount holding the whole set with
122179 chains still modified as the volume is being torn down.

## The sync copies the master's indirect blocks at the master's radix, 2026-10-13

The wedged log's last lines are the sync thread doing this without end:

    sync_insert: focus 00000000000004ec/0 into parent 0000000000000480/7 type 2
    create_indirect: parent 0000000000000480/7 ... ncount 128 count 32 -> keybits 7 key 00000000000004ec

The insert calls, counted by the type and key they carry:

    type 2 INDIRECT   543902 calls, focus keybits 0, keys 0x405 .. 0xffedec6993848001
                      into parents 0x440/6 (134022 of them), 0x400/5, 0x420/5
    type 1 INODE        3946 calls over 75 distinct keys
    type 0 DIRENT          0

`hammer2_sync_insert()` passes `focus->bref.type` to `hammer2_chain_create()`,
and focus is the MASTER's chain. For a directory the master indexes its entries
with INDIRECT blocks, so the sync asks the slave to create an INDIRECT chain at
the master's key and keybits. The slave's parent there is keybits 6, so the new
block comes out keybits 7 -- wider than the parent it is inserted into and the
same width as the parent's own parent. Every such insert therefore has to
absorb its neighbors, and the next key rebuilds it: 543902 inserts and 536026
`create_indirect` calls, one full-width block per key, until the run wedges.

That is the whole defect and it explains the four counter readings that have not
moved: the guards refuse these blocks (340 refusals), the refused keys get no
inode (75 created of 4001), the tree cannot be walked to completion (217 root
restarts), and the write-back has nothing valid to write. The fix belongs where
the sync chooses the destination radix, and it is not the caller's or the
computed keybits -- it is that the destination's own tree decides the radix, not
the source's.

## The clamp belongs in the sync path, not in the shared radix helper, 2026-10-13

The radix cap failed when it was placed in `hammer2_chain_indkey_dir()`, and the
reason is that the function is shared. Capping there narrowed the MASTER's own
inserts as well, and the slave's scan then covered no file keys at all: 0 of
1001 presented against 4001 of 8080 without it. Both trees were shaped by one
change, and the narrower shape could not hold the set.

The clamp applied instead in `hammer2_sync_insert()`, on the arguments it hands
`hammer2_chain_create()`, touches only the path that copies a chain FROM another
device. That is the only path in the tree that can be given a radix belonging to
a different tree, so it is the only one that needs the destination's parent to
have a say. The key is renormalized to the narrowed radix with the same mask the
radix helpers use, or the block would land on a boundary the parent does not
hold.

Checked against the three shapes the wedged log actually contains:

| parent | focus | clamped | inside parent | child end vs parent end |
| --- | --- | --- | --- | --- |
| 0x440/6 | 0x460/7 | 0x460/5 | yes | 0x47f <= 0x47f |
| 0x480/7 | 0x4e7/7 | 0x4c0/6 | yes | 0x4ff <= 0x4ff |
| 0x400/5 | 0x405/0 | 0x400/4 | yes | 0x40f <= 0x41f |

In each the narrowed block is strictly inside its parent, which is the property
the shared-helper cap could not give when it also shrank the source tree.

## The clamp works and the write-back defect is separate, 2026-10-13

The run carrying the sync-path clamp reached 23 passes with the counters below,
the healthiest of the session and the first since run 5 not to wedge:

| reading | before the clamp | with the clamp |
| --- | --- | --- |
| passes | 1 | 23 and climbing |
| `syncthr: update inode` stamps | 3873 | 4004 |
| `does not fit` refusals | 340 | 90 |
| `create_indirect` calls | 536026 | 28032 |
| `sync_insert` calls | 547925 | 40040 |
| fatal | 0 | 0 |

In the same run, and on every pass, the write-back helper still reports:

    sync_flush: clindex 1 chain 00000000728ee707 not flagged (00046102)

which is the same empty branch measured before the clamp, with none of
MODIFIED, UPDATE, ONFLUSH or DESTROY set. So the two defects are separate and
both are now measured in one run: the clamp fixes the radix and the refusals,
and the write-back remains a no-op. The convergence number from this run
measures the clamp alone, with the write-back still unable to write.

## The clamp clears the teardown wedge, 2026-10-13

The sync-path clamp is the first change of the session to get a run through its
four unmounts. Runs 6, 7 and 8 all wedged at the fourth, with the log stopping
at `hammer2_kill_sb: after unmount: 4008 inode, 126312 chain, 122179 modified,
499 dio still allocated`, `umount` in D state and the guest unanswering. The run
carrying the clamp reports:

    t=359  unmounts=4  mounts=2  D-state tasks 0  passes=38

Four unmounts, no stuck task, 38 passes, and 90 refusals against 340 without it.
So the same-width child block was what wedged the teardown as well as inflating
the refusal count: with the block strictly inside its parent the tree can be
walked and torn down, and without it the flush and the unmount both spin.

That is the first mechanism of the seven tried that changes the run's ability to
finish, and it is the one the earlier readings pointed at without naming:
the destination's radix has to come from the destination's tree, not from the
chain being copied.

## With the clamp the scan reaches every file key and the write-back is the only gap, 2026-10-13

The run carrying the clamp is the first of the session to complete rather than
wedge, and its log gives the cleanest separation yet:

| reading | value |
| --- | --- |
| distinct keys offered | 8134 |
| of those, hash-shaped (the file keys) | 4001 |
| distinct inode STAMPS | 4004 |
| distinct inode-INSERT keys | 75 |
| inserts INODE / INDIRECT | 4077 / 35963 |
| refusals | 90 |
| slave inodes on media | 834 |
| master inodes on media | 4801 |

The file keys are all offered (4001 of them) and the inode stamps all but match
them (4004). Before the clamp the scan presented 180 keys and stamped nothing;
now it walks the whole directory and stamps every inode. So the scan is no
longer the constraint.

What is left is one number apart from that: 4004 inodes are stamped
synchronized and 834 are on the slave's media, in a run that completes its
unmounts cleanly with `0 inode, 0 chain, 0 modified` at teardown. A stamp set
before the flush proves the copy is on media is the last defect, and it is the
one the `not flagged (00046102)` print names on every pass: the write-back
helper finds none of MODIFIED, UPDATE, ONFLUSH or DESTROY set on the element
root the scan just changed, so it returns without flushing.

The 75 distinct inode-insert keys against 4004 stamps says the inserts are the
DIRECTORY's own inodes and the 4004 stamps are the child inodes reached by the
deferral walk, which is consistent with the deferral design: a child inode is
stamped when its subtree is synchronized rather than inserted as a chain.

## Seven changes to the sync path, and which of them hold, 2026-10-13

Recorded together so none is re-tried. Ordered by what each was meant to fix.

| change | fired | outcome |
| --- | --- | --- |
| radix cap on `create_bits` | never | the caller passes 0, so the test is dead |
| radix cap on the computed keybits, in the shared helper | 30/pass | kills the storm, but narrows the MASTER too: 0 of 1001 keys hash-shaped |
| forced ONFLUSH, before the scan was fixed | every pass | 728 to 801 inodes, too small a move to read |
| slave-side error rollup | every key | aborts the pass; the next pass retries the same keys |
| slave-newer branch in the action switch | every pass | advances the local scan and not the XOP: 180 keys instead of 8061 |
| **radix clamp in `hammer2_sync_insert()`** | every copy | **run completes, teardown clean, all 4001 file keys offered, 4004 stamps** |
| forced ONFLUSH, on the fixed scan | in flight | the combination never measured |

One holds. The clamp is in the path that copies a chain from another device, so
it is the only site where a foreign radix can reach a tree that cannot hold it,
and it is the change that took the run from wedging to completing with
`0 inode, 0 chain, 0 modified` at teardown.

The other six are in the record with their numbers, and the two that were most
plausible on a static reading -- the write-back being a no-op, and the scan's
action switch -- were both real defects that moved the count by less than the
measurement's noise.

## The forcing makes the flush run and triples the refusals, 2026-10-13

Read from the run carrying the clamp and the forced ONFLUSH together, one pass
into it:

    passes 1, stamps 4019, not-flagged 0, flush-error 0, refusals 350

`not-flagged 0` is the change the forcing was written for: the write-back helper
no longer takes its empty branch, so the flush runs on a pass for the first
time with the scan repaired. In the same reading the refusals go from 90, which
the clamp alone produced, back to 350.

So forcing the flag is not free: marking the element root every pass drives more
work through `hammer2_chain_create_indirect()`, and more of that work meets the
guard. Whether the run still completes and what it converges to is the verdict,
but the refusal count alone says the forcing costs what it gains.

## The remaining refusals are in upstream's rename path, 2026-10-13

With the sync-path clamp in place the refusal count falls from 340 to 90, and
the 90 that remain are all one shape:

    does not fit parent 0000000000000440/6 (parent type 2, child type 2,
    create 0000000000000469/0 for_type 1)

`for_type 1` is INODE and the parent is an INDIRECT at keybits 6, so this is
`hammer2_chain_create()` being asked for an inode chain under an indirect block
too narrow to hold it. The caller is `hammer2_chain_rename()`, which re-creates
a chain under a new parent with `bref->keybits` -- the chain's OWN radix, not
the receiving parent's -- and `diff` against the upstream tree shows that call
is carried byte for byte, apart from formatting and a commented-out assert.

So this refusal is not a port invention at either end: the call is upstream's,
and the guard that refuses the result is this port's. Upstream has the same
call and no guard, so upstream allows the insertion and relies on the rbtree
comparison to treat the overlap as a match. Whether that is safe is the question
the guard exists to ask, and the reading so far says the refusal is what keeps
the tree walkable: removing the guard earlier produced `no room` and a flush
depth panic rather than a converged volume.

## The clamp is necessary and not sufficient, 2026-10-13

Two runs of the SAME clamp-only source, `git diff` reporting no difference in
`src/` between the two commits they were built from:

| run | outcome |
| --- | --- |
| run 9 | completes: 4 unmounts, `0 inode, 0 chain, 0 modified` at teardown, module unloads, inodes 834/4801 |
| run 11 | stalls at the first unmount: t=413, unmounts=1, passes=1, refusals climbing 270 to 320, `D` tasks appearing and clearing |

So the clamp takes the run from "always wedges" to "sometimes completes", and
the outcome is decided by timing rather than by the source. The refusals that
climb while it stalls are the `hammer2_chain_rename()` shape, which is upstream's
call with this port's guard on the result, and the guard is not reached in run 9
in the same order.

What that means for P4: neither run converges, so the clamp is not the fix even
where it lets the run finish. It is a real improvement on a real defect, and
the convergence number is unchanged at 834 of 4801 in the run that completed.

Unmeasured and now the sharpest open question: which of the two arms run 9 took
that run 11 does not. Both runs offer 4001 file keys and stamp about 4000
inodes, so the difference is in the flush or the collapse rather than the scan,
and it is the collapse that refuses (`hammer2_chain_rename()` into a narrower
indirect parent).

## Where the sync convergence stands at the end of 2026-10-13

Two clamps are in the tree, both applying one rule: the receiving parent decides
a new chain's radix, and the key is renormalized to it.

- `hammer2_sync_insert()`: the radix comes from `focus`, the other device's
  chain, so this is the only path that can be handed a foreign radix.
- `hammer2_chain_rename()`: the radix comes from `bref`, the chain's own, and
  the chain is being re-created under a parent that may be narrower.

Measured effect of the first: the run completes teardown with `0 inode, 0 chain,
0 modified` where three consecutive runs before it wedged at `4008 inode,
122179 modified`; refusals fall 340 to 90; the scan offers all 4001 file keys
and stamps about 4000 inodes where it previously walked 180 keys.

Not converged. The slave holds 834 of 4801 inodes in the run that completed,
because about 4000 inodes are stamped synchronized and 834 reach media: the
write-back does not carry them. Forcing it was tried twice and makes things
worse, most recently wedging the run outright.

Open, in the order the evidence puts them:

1. the write-back helper takes its empty branch on every pass because the
   descending flush clears the flag before a pass ends;
2. `hammer2_chain_rename()` refuses 90 to 320 times a run into a narrower
   indirect parent, which is the shape upstream's rename call produces and this
   port's guard declines;
3. whether the outcome depends on timing: two runs of identical source
   completed and stalled respectively.

## The setflush walk cannot reach the element root, and the code says why, 2026-10-13

`hammer2_sync_flush()` tests the element root's own flags for `FLUSH_MASK` and
finds none set -- `not flagged (00046102)` on 22 of 22 and 50 of 50 passes. The
flag is meant to be placed there by walking up from the chain the scan changed,
through `hammer2_sync_setflush()`, which is this port's own helper because the
carried `hammer2_chain_setflush()` stops at the first inode:

    if (chain->bref.type == HAMMER2_BREF_TYPE_INODE)
            break;

Both walks follow `chain->parent`, and `chain->parent` is set to NULL in exactly
three places, all of them deletion:

    hammer2_chain.c:770, 3451, 3511   chain->parent = NULL;

Every one is inside a delete or a rename's delete half, where the chain is
removed from its parent's rbtree. So a chain the scan just inserted keeps its
parent, and the walk should reach the root; a chain that was deleted and
re-inserted during the same pass loses its parent and the walk terminates at it
with the root unflagged.

That is the shape the port's own comment above `hammer2_sync_setflush()` predicts
and it is why the print was added there: a walk that stops at a NULL parent is a
different defect from one that stops at an inode, and the two want different
fixes. The run in flight reads which it is.

## The setflush walk reaches the volume root, and the no-op gate is gone, 2026-10-13

The instrument placed at the end of `hammer2_sync_setflush()`'s walk answers the
question the earlier `not flagged (00046102)` readings left open, and it answers
it the opposite way from the first guess:

    stopped at 0000000000000000/0 type 255 (NULL parent)   15619
    stopped at any type other than 255                         0
    not-flagged                                                0
    stamps                                                  3873

`255` is `HAMMER2_BREF_TYPE_VOLUME`, the volume chain, whose parent is NULL
because it is the top of the tree. So every walk terminates at the volume root
rather than at an inode or at a detached chain, which means the flag is
propagated the whole way up and the element root the flush helper tests IS
flagged. `not-flagged` is 0, so the write-back helper is not taking its empty
branch.

That is a change from the runs before the sync clamp, where the same print read
`not flagged (00046102)` on 22 of 22 and 50 of 50 passes. The clamp did not just
reduce the refusals: it is what makes the copy the scan makes reach the flush
that writes it.

The count of 15619 walks against 3873 stamps is the deferral walk calling
`sync_setflush` per copied chain, not per inode.

## The clamp alone completes once in three runs, 2026-10-13

Three runs of identical clamp-only source, `git diff` reporting no difference:

| run | outcome |
| --- | --- |
| run 9 | completes: 4 unmounts, `0 inode, 0 chain, 0 modified` at teardown, 834 inodes on the slave |
| run 11 | stalls at the first unmount: refusals climbing 270 to 320, D tasks appearing |
| run 13 | stalls at the first unmount: t=565, 1 unmount, 1 pass, 11 D tasks |

So the clamp is real and it is not deterministic. It removes the always-wedge
that ran from run 6 to run 8, and the run then either completes or hangs on the
same source. The refusal count and the D tasks climb in the runs that hang and
not in the one that finished, which says the hang is the refusal path taken
repeatedly rather than a different failure.

Recorded plainly because the previous note called the clamp necessary and not
sufficient on two runs; three puts the rate at one in three and the hang on the
same mechanism as the stalling run before it.

## The hang is a split that cannot relieve its parent, 2026-10-13

The pre-clamp hang log's insert count, grouped:

    547925 inserts total
    parent 0000000000000480/7 type 2 : 402059
    parent 0000000000000440/6 type 2 : 134022
    distinct focus keys: 8080
    focus 0000000000000460/0 : 4188 attempts
    focus 0000000000000461/0 : 4188 attempts
    focus 0000000000000462/0 : 4188 attempts

Each key is inserted about 4188 times, one key after another, into the same
parent. The create_indirect line beside each says what happens:

    create_indirect: parent 0000000000000480/7 create_bits 0 ncount 128 count 32 -> keybits 7

Read with the size rule, that is a split which cannot succeed. The parent is
`0x480/7`, so it spans keys `0x480` to `0x4ff`. Its slot count is 32, which is
a 4096-byte block -- `HAMMER2_IND_BYTES_MIN`, the size chosen for a DIRECTORY
INODE parent. The new block is asked for `ncount 128`, a 16384-byte block,
because its parent is now an INDIRECT rather than an inode, and the keybits loop
lands it at 7 again.

A keybits-7 child covers exactly its keybits-7 parent's range, so it is not a
child at all: `hammer2_chain_cmp()` returns 0 for the pair. Splitting therefore
cannot reduce the parent's occupancy, the parent stays full, and the next insert
splits again. 4188 times per key, per pass, until the run wedges.

The inconsistency is the size rule's dependence on the parent's TYPE. Under a
directory inode the first split makes a 32-slot block spanning 128 keys; under
the INDIRECT that results, the next split makes a 128-slot block spanning the
same 128 keys. The second cannot hold more than the first, and neither is
narrower than its parent.

## The hang, proven: a same-keybits split that cannot relieve its parent, 2026-10-13

The pre-clamp hang log, counted by what the sync thread inserts:

    547925 inserts
    focus key 0x460/0 : 4188 attempts
    focus key 0x461/0 : 4188 attempts
    focus key 0x462/0 : 4188 attempts      (and so on, keys advancing)
    parent 0x480/7 type 2 : 402059 of them

Each key is inserted thousands of times into the same parent, and the
`create_indirect` line beside each says why:

    create_indirect: parent 0x480/7 create_bits 0 ncount 128 count 32 -> keybits 7

The arithmetic closes it. `count 32` is the parent's slot count, and an
INDIRECT's count is `parent->bytes / sizeof(hammer2_blockref_t)`, so the parent
is 32 * 128 = 4096 bytes: `HAMMER2_IND_BYTES_MIN`, the size the rule picks for a
DIRECTORY INODE parent. The new block is asked for `ncount 128`, which is 16384
bytes, `HAMMER2_IND_BYTES_NOM`, the size for any other parent. The keybits loop
then raises the new block to keybits 7 -- the parent's own radix.

A keybits-7 child spans exactly a keybits-7 parent's keyspace, so it is not a
child that can absorb any of the parent's occupancy: the split moves elements
into a block that covers the same range, the parent is full again, and the next
insert splits again. 4188 attempts per key, 547925 in the pass, until the run
wedges. The clamps reduce how often this happens and do not remove it, because
the block that is asked for is still the wrong WIDTH for the parent it must fit
under.

The divergence is the size rule's dependence on the parent's TYPE. Under a
directory inode the first split makes a 4096-byte, 32-slot block; under the
INDIRECT that results, every later split makes a 16384-byte, 128-slot block. The
two cannot both be right for the same parent, and the second is wider than the
parent it must fit under rather than narrower.

## A hung run's log is lost when the guest is reset first, 2026-10-13

Twice a run wedged and the guest was hard-cycled to recover it before the
harness's own timeout copied `/tmp/h2empty.klog` off the guest. The harness's
hang path does save it as `sync-empty-hang-<timestamp>.klog` beside the images,
and nothing else does, so the reset threw away the one artifact the hang
produced. Runs 11 and 13 are read only through their counters for that reason.

The order that keeps the evidence: let the harness's `H2_RUN_TIMEOUT` fire first
(it copies the log, detaches the disks and reports `hung past`), and reset the
guest only after the run reports. A reset is needed when the harness itself
cannot proceed, which has not been the case -- the harness has always recovered
on its own once its timeout expires.

## The split bound, and why the clamps alone did not hold, 2026-10-13

The clamps in `hammer2_sync_insert()` and `hammer2_chain_rename()` narrow the
radix of a chain being copied or moved, and the hang continued in two runs of
three. The reason is that the hang is not produced by a copied radix: it is
produced by `hammer2_chain_create_indirect()` choosing the NEW BLOCK's size, and
that happens after any clamp has done its work.

The bound added there is on `ncount`, the slot count the new block is sized for,
because the keybits helper raises the radix until the block holds that many
slots. Bounding `ncount` below `2^(parent keybits - 1)` therefore lands the block
one radix level below its parent at every level:

| parent keybits | ncount bounded to | keybits floor | narrower than parent |
| --- | --- | --- | --- |
| 7 | 64 | 6 | yes |
| 6 | 32 | 5 | yes |
| 5 | 16 | 4 | yes |
| 4 | 8 | 3 | yes |

The capacity requirement still holds, which is the part that has to be checked
because the block must be able to receive what the split moves into it: the
helper takes the half with more elements, so at most half the parent's elements
move, and the block holds `2^(parent-1)` slots. At a keybits-7 parent that is at
most 64 moved into 64 slots, which fits exactly.

A parent at keybits 0 is a directory inode's blockset rather than a key range and
is left alone, which is the case the carried helper is normally called for.

## The ncount bound removes the split loop entirely, 2026-10-13

One pass into the run carrying the bound, against the same counters in the runs
before it:

| reading | without the bound | with the bound |
| --- | --- | --- |
| `create_indirect` calls | 536026 | 0 |
| `does not fit` refusals | 340 | 0 |
| `sync_insert` calls | 547925 | 11675 |
| stamps | 3873 | 3676 |

Zero split calls and zero refusals in the first pass. The inserts fall by a
factor of 47. The loop that wedged three consecutive runs is the split calling
`create_indirect` to build a block the same width as its parent; with the block
bounded one radix level below its parent, no split is needed to place the
copies, and the refusals that guard those blocks never fire because no such
block is built.

The master's tree is shaped by the same call, so the bound applies to both
sides. That is required rather than a side effect: the two trees converge entry
for entry only if both are built by the same sizing rule, and the rule as
carried produced a 4KB level under a directory inode and a 16KB level under the
INDIRECT that followed it.

## The bound's run is stable through its cycles, 2026-10-13

The clean run carrying the ncount bound -- one harness, no other process on the
guest -- reads at t=263, two unmounts into its four:

    create_indirect calls   0
    does not fit refusals   0
    D-state tasks           0
    passes                 27
    mounts cycling normally

Runs 6 through 13 showed refusals climbing and D tasks appearing at the first
unmount. This run shows neither at the second, with the same set size and the
same cycle structure, which is the difference the bound makes: no block is built
that its parent cannot hold, so no refusal fires and nothing waits on a lock
held across a rebuild.

## P4 convergence: the slave matches its master, entry for entry and block for block, 2026-10-13

The ncount bound converges the cluster. Read three ways, all agreeing.

The harness, on a single clean run with no other process on the guest:

    the SLAVE converged to its MASTER, entry for entry and block for block:
    slave/master by type: inode 4801/4801, data 4800/4800, dirent 4801/4801;
    0 line(s) differ of 14402

The same run's self-checks that caught two contaminated results earlier in the
day all pass here, so the verdict is not the false pass they were: the device
tie matches (`guest 89e63b58-... image 89e63b58-...`), `the master holds the
set: 4000 file(s)` at the correct N, `2 mounted`, and `the module unloads: 1 of
1`.

Read independently off the media with this session's corrected fingerprint
instrument:

    slave lines 14402, master lines 14402
    cmp -s rc=0, differing lines 0
    inode  4801 / 4801
    data   4800 / 4800
    dirent 4801 / 4801

`cmp -s` returning 0 is the reading that was meaningless before the instrument
was fixed, because its status was being overwritten by the counts that followed
it. It is taken here with the status captured first, and the population is
counted from inode lines rather than from a `FILE$` match that also matched
dirents.

The two checks that still fail are not convergence: `an unmount left modified
chains` reads 0 with modified chains because the sync now completes cleanly and
the window the run was built to open no longer opens, and one kernel warning
from the ungated `create_indirect:` print remains. Both are the probe's own
expectations, not the filesystem's.

## The bound's own defect, caught by UBSAN after it had already converged a run, 2026-10-13

Run 17 converged (inode 4801/4801, 0 lines differ) while carrying a defect of
its own that the KASAN build reported and the shipping build did not:

    UBSAN: shift-out-of-bounds in hammer2_chain.c:3698:26
    shift exponent 61 is too large for 32-bit type 'unsigned int'

The bound computed `unsigned int pmax = 1U << (parent->bref.keybits - 1)`, and a
parent at keybits 62 exists in this tree: the master's own media carries blocks
at keybits 62 and 63. The shipping build does not shift-check, so it computed a
garbage bound silently and converged anyway; the UBSAN build reported it. The
shift is on `hammer2_key_t` now.

The first correction written for this was a `pmax < 64` guard, and it was wrong
in the direction that matters. At keybits 7 pmax is exactly 64, so the guard
disabled the bound at the very radix the defect was measured at and would have
silently restored the bug while looking like a safety check. It was caught by
enumerating the bound at every parent radix before building, which is the
cheapest form of the check and the one that should happen before the build:

| parent keybits | pmax | ncount bounded to | new keybits | below parent |
| --- | --- | --- | --- | --- |
| 2 | 2 | 2 | 1 | yes |
| 4 | 8 | 8 | 3 | yes |
| 6 | 32 | 32 | 5 | yes |
| 7 | 64 | 64 | 6 | yes |
| 8 | 128 | 128 | 7 | yes |
| 62 | 128 (clamped) | 128 | 7 | yes |

`pmax` is clamped to 128 rather than guarded, because `ncount` never exceeds 128:
a parent wide enough to allow 128 slots needs no bound and a narrower one still
gets one.

## The widened shift reports no UBSAN and the run stays healthy, 2026-10-13

One pass into the run carrying the 64-bit shift and the clamped pmax, against
the run that carried the 32-bit one:

    UBSAN reports     1 -> 0
    create_indirect   0 -> 0
    D-state tasks     0 -> 0
    refusals          0 -> 0

The KASAN/UBSAN build is the one that reported `shift exponent 61 is too large
for 32-bit type 'unsigned int'` at the bound, and it reports nothing at that
line now. The run clears its four unmounts with no stuck task, which is the
same shape as the run before it, so widening the shift did not change the
convergence result -- it only removed the undefined behavior that the shipping
build was silently computing through.

## P4 closes: 18 checks, 0 failed, 2026-10-13

The final verification run reports every check passing, including the two that
were cleaned up in this session and the one the fix's own defect had raised:

    ok  an unmount left modified chains: 7 unmount reading(s), 0 with modified chains, expected fixed
    ok  no kernel warning, BUG or UBSAN report: 0
    ok  the SLAVE converged to its MASTER, entry for entry and block for block:
        slave/master by type: inode 4801/4801, data 4800/4800, dirent 4801/4801;
        0 line(s) differ of 14402
    ok  MASTER=repro-master.img is the volume the guest mounted as vdb:
        guest 4c28decc-... image 4c28decc-...
    sync-empty: 18 check(s), 0 failed

The run's own checks that caught the contaminated verdicts earlier in the day all
pass here, so the convergence is not the false pass they were: the device tie
matches, the set reads 4000 file(s) at the correct N, 2 mounted, and the module
unloads 1 of 1.

The three changes this session ends with:

* the `ncount` bound in `hammer2_chain_create_indirect()`, which is what
  converges the slave to its master;
* the bound's shift on `hammer2_key_t` and `pmax` clamped to 128, which removes
  the UB that the shipping build was computing through silently;
* the two clamps kept from the refuted work, in `hammer2_sync_insert()` and
  `hammer2_chain_rename()`, which narrow copied and moved chains to the parent
  that must hold them.

## test-enospc.sh reports one dedup failure, and whose it is is being measured, 2026-10-13

The gate run at 15:2x reports `filled 2G, 1 failure(s)`, and the failure is the
dedup exerciser, which has passed on this tree before (`dedup 3 check(s) 0
failed` on 2026-09-27, recorded in this file). So it is a regression of
something and not a known state.

    dedup-ok   free blocks before: 26411
    dedup-ok   free blocks after file A: 26024
    dedup-ok   free blocks after file B: 25700
    dedup-ok   file A allocated 387 blocks for 64 blocks of data
    dedup-ok   the duplicate cost 324 blocks against file A's 387
    dedup-fail the duplicate allocated its own media: 324 against 387 blocks for identical content

The bar is a quarter of file A's growth and the duplicate cost 324 against 387,
which is 84 percent, so the failure is not a threshold artifact: the duplicate
took its own media.

Two facts say the split bound does not reach this path, and neither is being
trusted as the answer:

* the dedup exerciser's path is `hammer2_chain_modify()` and the duplicate with a
  `dedup_off`, not a split, and the split bound sits inside
  `hammer2_chain_create_indirect()`;
* the non-comment lines this session added to `hammer2_chain.c` are the bound and
  one diagnostic condition, with no `dedup`, `nradix`, `modify` or `duplicate`
  line among them.

The attribution is being measured rather than argued: the session's own starting
commit `2511e7a` is built in a worktree and the same gate run against it. If the
baseline fails too, the failure predates this work; if it passes, the bound is
the cause and the bound is what gets changed.

## The bound's second defect: it shrank the allocation, not just the radix, 2026-10-13

The split bound converged the cluster and broke block allocation, and a gate
found it. `test-enospc.sh` on the bound reported one failure, the dedup
exerciser, which passes on this tree. Attributed by measurement rather than
argument: the session's own starting commit `2511e7a` was built in a worktree
and the same gate run against it.

    baseline 2511e7a:  file A allocated 64 blocks for 64 blocks of data
                       the duplicate cost 3 blocks  -> shared   -> 0 failures
    with the bound:    file A allocated 387 blocks for 64 blocks of data
                       the duplicate cost 324 blocks -> not shared -> 1 failure

File A taking six times its data says the allocator is compensating for blocks
that are too small, and the bound was the cause: it wrote `nbytes` as well as
`ncount`, and `nbytes` is what the new block is ALLOCATED at, through
`dummy.data_off = hammer2_getradix(nbytes)`. Shrinking it shrank the block on
media.

`ncount` is what the keybits helpers read, so the bound now writes `ncount`
alone and leaves `nbytes` at the size the rule chose. Verified at every parent
radix: the new block's keybits is strictly below its parent's from keybits 4
through 62.

The lesson is the one the shift defect taught an hour earlier and it has now
cost two rounds: **the fix's own inputs have to be enumerated at every class the
tree contains before it is believed**, and a gate that covers a different
subsystem is the cheapest place to find out. This one was found by running a
gate whose subject is not the cluster, on the reasoning that a change to
`hammer2_chain.c` is a change to everything that allocates through it.

## The corrected bound restores the baseline allocation, measured, 2026-10-13

`test-enospc.sh` on the corrected build, against the baseline and the broken one:

| tree | file A blocks for 64 of data | duplicate cost | dedup | failures |
| --- | --- | --- | --- | --- |
| baseline `2511e7a` | 64 | 3 | shared | 0 |
| bound writing nbytes too | 387 | 324 | own media | 1 |
| bound writing ncount alone | 64 | 3 | shared | 0 |

The corrected build is identical to the baseline on this gate, so the bound no
longer disturbs allocation. The convergence run is in flight and is the check
that the bound is still doing its job: a fix that restored dedup by disabling
the bound would be worthless, and the `ncount = (int)pmax` line is verified
present in the tree before that run was started.

Two things this cost and should not have:

* the bound was written without enumerating what else `nbytes` feeds. It feeds
  the allocation, through `dummy.data_off = hammer2_getradix(nbytes)`, and the
  only thing the bound needed to change was `ncount`, which the keybits loop
  reads on its own line.
* it was found by a gate whose subject is not the cluster, which is the cheapest
  place these turn up: a change to `hammer2_chain.c` is a change to everything
  that allocates through it, and `test-enospc.sh` is the gate that measures
  allocation under pressure.

## The corrected bound converges and leaves allocation alone, 2026-10-13

Both gates pass on the corrected tree, which is the pairing that had to be
measured rather than argued: a bound that restored dedup by disabling itself
would pass `test-enospc.sh` and fail convergence.

    test-enospc.sh:        filled 2G, 0 failure(s); dedup 3 checks 0 failed,
                           file A 64 blocks for 64 of data, duplicate cost 3
    sync-empty-base.sh:    18 checks 0 failed; slave converged to its master,
                           inode 4801/4801, data 4800/4800, dirent 4801/4801,
                           0 lines differ of 14402; UBSAN report 0

The two properties are independent, which is why one line carries both: the new
block's RADIX comes from `ncount`, which the keybits loop reads on its own line
(`while ((1<<keybits) < ncount) ++keybits`), and its ALLOCATION comes from
`nbytes`, through `dummy.data_off = hammer2_getradix(nbytes)`. Bounding `ncount`
alone narrows the radix and leaves the allocation at the size the rule chose.

The convergence run also confirms the bound is still doing its work: 0
`create_indirect` calls and 0 refusals across its passes, where the tree without
it records 536026 and 340.

## Four prose citations were stale and the gate reported them all along, 2026-10-13

`test-citations.sh` reads citations in TABLE ROWS. A `file:line` written in
prose is matched by nothing, and the gate says so: it prints an `unchecked`
line for each one, with the count beside its pass line. Four of them were stale
in live documents, and the gate had been listing all four on every run:

    doc/README.testing.md  hammer2_chain.c:646   -> 766   RB_REMOVE, lastdrop
    doc/README.testing.md  hammer2_chain.c:3903  -> 4134  the insert, create_indirect
    doc/README.roadmap.md  hammer2_chain.c:297   -> 381   KASSERTMSG collision
    doc/README.roadmap.md  hammer2_chain.c:3903  -> 4134  the insert, create_indirect

Every one was drifted by this session's own edits to `hammer2_chain.c`, and all
four are corrected to a SYMBOL and a line, which is the shape `00c554e` used
when it fixed this same class before: that commit's subject is "A prose citation
pointed at a function that had moved 150 lines", and it removed the line numbers
it could not keep true.

The reading was in the output the whole time. `test-citations.sh` prints its
`unchecked` list and an `uncovered` count deliberately, because a citation
naming another tree -- `doc/research/` and `doc/upstream/` describe DragonFly
and the BSD ports -- must not be checked against this one. What was missing was
not the instrument but reading its report rather than its pass line: every
fifteen-gate sweep this session ended on the counts and never on the list.

Measured over the documents this tree owns, the prose citations resolve as:
120 in range, 3 out of range and all three in `doc/research/` or `doc/upstream/`
where they name another tree's line numbers, and 7 naming a file that does not
exist here for the same reason. `doc/research/HAMMER2_LINUX_API_MAP.md`'s
`hammer2_flush.c:1496` was checked against the DragonFly clone and lands on
`vn_strategy(hmp->devvp, &bp->b_bio1)`, which is the text its sentence
describes, so it is correct where it was written and stays as it is.

## Narrowing the create-indirect diagnostic was tried and changes nothing, 2026-10-13

The entry above on the console flood says the check "cannot be satisfied until
the print is bounded to the case it names". That was acted on and it is wrong,
and the measurement is what refutes it.

The print's condition was moved after the key mask and onto the masked key, so
it tests the value the new block actually carries rather than the pre-mask one.
Applied to the hang log's lines:

    create_indirect lines   536026
    pre-mask condition      536026 fires
    post-mask condition     536026 fires
    refusals in that log       480

Both conditions fire on every line, so the move changes nothing. The clause
that fires is `keybits >= parent->bref.keybits`, and the keybits distribution
over those 536026 lines is `{7: every line}`: the block being built and the
block being refused are the same keybits-7 event, so a condition that selects
refusals selects creates as well.

What is therefore restored is the debug-bit gate, which is a control rather than
a narrowing: the count it reaches under the bit is the number of blocks BUILT,
not the number refused, and a run that splits with the bit on prints one line
per block. The record's own sentence is left as written, since it is the account
of a reading taken on 2026-10-13, and this section is the correction.

## An ssh drop read as a failure, and the detach under the live guest hpanics it, 2026-10-13

`cluster-sync.sh`'s phase 4 was run to take P4's `interrupt_resume` reading on
the fixed tree. It reported 31 checks and 15 failed, and the failures are one
finding with two halves.

What the log shows. The host's fifteen FAILs all read `none` or `0`, where
`none` is the value `val()` returns for a key that is not in the guest's
output. The guest's own kernel log contradicts them: it runs to completion,
its last lines are the phase-5 unmounts, and its `interrupt-*` and `resume-*`
keys were printed. So the guest half finished and the host read an output file
that did not contain what the guest printed. That is an ssh session ending
before its output arrived, which `cluster-sync.sh` did not handle: it tested
the guest's exit against 124 and nothing else, so any other non-zero fell
through to the checks.

What the fall-through then did is the second half, and it is a fault this
script caused. The unconditional detach released both disks while the guest
was still running. libvirt reaches the guest as an ACPI eject, and the trace
is the whole account of it:

    hammer2_base_delete
      <- hammer2_flush_core <- hammer2_flush_recurse
      <- hammer2_chain_tree_RB_SCAN <- hammer2_flush_core
      <- hammer2_flush <- hammer2_xop_inode_flush
      <- hammer2_xop_start_except <- hammer2_inode_chain_flush
      <- hammer2_vfs_sync_pmp <- hammer2_sync_fs <- sync_filesystem
      <- fs_bdev_mark_dead <- bdev_mark_dead <- blk_report_disk_dead
      <- __del_gendisk <- del_gendisk <- virtblk_remove
      <- virtio_dev_remove <- ... <- acpiphp_disable_and_eject_slot
      <- acpiphp_hotplug_notify <- acpi_device_hotplug
      <- acpi_hotplug_work_fn

with `Workqueue: kacpi_hotplug` above it, and the hpanic message
`delete indirect elm 0000000000005000/12 from empty base 0000000000000000/0
not found at 128/128` marks the device in error, after which the flush drops
its blocks unwritten. The producer is therefore not this port's syncer and not
the teardown: it is the ejection of the volume itself, whose `sync_filesystem`
flushes a filesystem whose device is already going away.

The times order it beyond doubt. The fault is at guest-uptime 20151 s; the
guest's script ran on to 20270 s; the host's log was written at 20:01:43, at
which point the ssh had already returned and the detach had run. The eject is
the host's own, under a guest that had not finished.

The record's 2026-10-12 entry already has this frame set, from a run under
`HAMMER2_INVARIANTS`: `virtblk_remove -> del_gendisk -> blk_report_disk_dead
-> sync_filesystem -> hammer2_vfs_sync_pmp -> hammer2_trans_init`, read there
as a flush-transaction wait. The same eject reaches a different sink here,
the empty-base hpanic, which is what the record's separate entry describes
from the syncer's side. One trigger, two sinks, and both are this script's
detach landing during a live run.

The fix is in two commits, `8f985ef` for `cluster-sync.sh` and `ae71c74` for
`cluster-quorum.sh`, which carried the identical `rc=$?` followed by only the
124 test and then an unconditional detach. Both now read the guest half's exit
before anything is inferred from its output: exit 2 and a COULD-NOT-RUN line
are surfaced as COULD-NOT-RUN, a non-zero that is neither 2 nor 124 is the
same and keeps the kernel log beside the images as `cluster-drop-*.klog`, and
only rc 0 reaches the checks. `sync-empty-base.sh` has guarded exit 2 since
2026-10-12; this closes that class in its sibling rather than inventing it.
The guest's kernel log for this run is kept at
`cluster-phase4-eject-emptybase-20261013-200714.klog` beside the images.

Not yet established, and left as the next reading rather than guessed: whether
phase 4 reaches the interrupt and the resume on a run whose session completes.
The two failures this entry explains were the harness's, so the phase's own
checks have not yet been read on the fixed tree.

## The guard against the live detach still detached, 2026-10-13

`8f985ef` read the guest half's exit before inferring failures from its
output. That half of it worked: the same run shape came back as one
COULD-NOT-RUN line rather than fifteen FAILs. It also detached the disks in
the same arm, which is the fault the guard was written to prevent, and the
run after it shows the cost.

The readings: the run returned
`COULD-NOT-RUN: the guest session ended rc=127 after 17 line(s) of output`,
and on the guest `/dev/vdb` and `/dev/vdc` were gone while `/mnt/h2c` and
`/mnt/h2m` still listed as hammer2 mounts and the sync thread was still
passing every five seconds. A mount whose device has been ejected is the
state the guard exists to avoid, and the guard produced it.

Two things were wrong, and both are mine:

* the arm that reads a non-zero exit and reports COULD-NOT-RUN ended with the
  same unconditional `detach-disk --live` the old code had, so the report was
  correct and the action under it was not. Suppressing the wrong verdict did
  nothing about the wrong action.
* the guest's output was discarded. `rc` and a line count survived; the
  seventeen lines that say where the guest half stopped did not. `rc=127` is
  not the 255 an ssh drop returns, so the run stopped for a different reason,
  and the evidence that would have named it was thrown away by the same
  commit that was written to preserve evidence.

`6dfba0c` routes every detach in the script through `detach_disks`, which
asks a running guest to unmount and rmmod and detaches only when the guest
reports no hammer2 mount left; a guest that will not release them is left
alone and the helper returns 1. The drop arm keeps the guest's output beside
the kernel log.

Measured against the real guest, the two states that matter: with no mount
the helper detaches and returns 0; with a mount it unmounts first, detaches,
returns 0, and the guest's log carries no `device in error`, no
`from empty base` and no `cut here`, where the old path produced all three.
The control is the case that produced the fault, run again through the new
path, so the guard is checked where the defect occurs rather than where it is
convenient.

The lesson is the one this session keeps re-learning at this site: the
sentence describing a fix and the fix are separate artifacts, and a guard
that reports the right thing while doing the wrong thing is the shape to
check for. The comment above it said the disks were released only after the
guest stopped touching them; the code under the comment detached anyway.

## A detached parent NULLs the re-flush loop's ref, and the port faults, 2026-10-13

The guarded `cluster-sync.sh` run reached phase 4 and faulted in the port
rather than in the harness. The kernel report is kept whole at
`doc/history/kernel-reports/hammer2-chain-ref-null-sync-20261013.txt`, and the
fault is on the port's own periodic syncer, not on an eject this time:

    Workqueue: events hammer2_sync_work [hammer2]
    Oops: general protection fault ... KASAN: null-ptr-deref in range
      [0x0000000000000378-0x000000000000037f]
    RIP: hammer2_chain_ref+0x24
      hammer2_flush+0x175
      hammer2_xop_inode_flush -> hammer2_xop_start_except
      -> hammer2_inode_chain_flush -> hammer2_vfs_sync_pmp
      -> hammer2_sync_fs -> sync_filesystem -> hammer2_sync_work

`RAX=0` and `RDI=0x378`: the argument to `hammer2_chain_ref()` is NULL and the
first access is `chain->refs` at `0x378`.

The two lines printed immediately before it name the mechanism:

    hammer2: hammer2_flush_core: lost child3
    hammer2: hammer2_flush: lost child4

`hammer2_flush_core()` reports that the chain's parent changed under it, and
`hammer2_flush()`'s re-flush loop then does:

    if (info.parent != chain->parent) {
            hprintf("lost child4\n");
            hammer2_chain_drop(info.parent);
            info.parent = chain->parent;
            hammer2_chain_ref(info.parent);      /* hammer2_flush.c:328 */
    }

`chain->parent` is set to NULL in three places, all deletion
(`hammer2_chain.c:770, 3451, 3511`). So the parent the flush is holding was
detached during the pass, `info.parent` is assigned NULL, and the ref
dereferences it. The function's own entry guards the same pointer with the
comment that says it can be NULL:

    if ((info.parent = chain->parent) != NULL)
            hammer2_chain_ref(info.parent);      /* hammer2_flush.c:309 */

so the loop contradicts the contract the entry states, twenty lines apart in
one function.

The disassembly confirms the two paths rather than the source's shape alone:
`hammer2_flush+0x90` tests RDI for the entry ref (`test %rdi,%rdi; je`), and
`hammer2_flush+0x170` loads the loop's operand with no test before the call
whose return address is `+0x175`.

**This is carried, not introduced.** FreeBSD's own `hammer2_flush.c:332` is the
identical unguarded `hammer2_chain_ref(info.parent)`, and its
`hammer2_chain_ref()` dereferences unconditionally too, so upstream has the
same latent fault at the same line. What the port supplies is the reachability:
a chain whose parent is detached while a flush of it is in flight is the plan's
source-mutated-during-convergence case, and the phase-4 write under the slave's
unmount is what produced it here.

The consequence is not a wrong number. The guest wedged: ssh stopped
answering (`guest-dmesg.sh` through the agent read it), and the teardown
reported `15751 inode left`, `86570 chain left`, `82718 modified chain left`,
with `kmem_cache_destroy h2xopszone: Slab cache still objects`. The sync
thread that faulted is the one that flushes the cluster, so a run that takes
this path leaves its volumes unflushed and its caches undestroyed.

The failing probe is the run: phase 4's own write-then-unmount reaches it, and
the run is kept as `cluster-chainref-null-20261013.klog` beside the images.
The fix is the NULL guard the entry already has, applied to the loop, marked
`XXX` because the file is carried.

## The run that proves the fix is the run the guard let through, 2026-10-13

The fix for the chain_ref NULL fault is in `e3db258`, and the proof run for it
is the run the concurrent-run guard should have blocked.

Two `cluster-sync.sh` runs started at once: pid 8794 from the monitor's own
launch and pid 25775 from a foreground run issued to diagnose the first. They
shared the guest, its volumes and the two image files, which is the
corruption `~/.claude/hooks/guard_concurrent_run_launch.py` was written for on
this same day. The guard is a `PreToolUse(Bash)` deny tier and it did not fire.

The pattern matched a command position as `^`, `;`, `&` or `|`, and `^`
without `re.MULTILINE` matches only the start of the whole string. The
diagnosing command was

    cd /home/james/Projects/linux_hammer2 || exit 1
    env KDIR=... bash script/cluster-sync.sh > /tmp/h2-fg.out 2>&1

and `bash` on its own line after the `cd` has no character the pattern can
anchor on. The guard's own comment names the form it was written against,
`nohup ... &`, and the form a multi-line Bash command actually takes has a
newline there.

The command-position class now includes `\n`, and the battery that was missing
is written: `~/.claude/hooks/test_guard_concurrent_run_launch.py`, whose first
case is that command verbatim. The hook was untracked and untested until this
commit, which is why nothing measured its coverage; `.gitignore` now
allowlists both files the way every other governed hook is allowlisted.

The pair was killed once it was visible, and neither run's readings are kept.
The lesson is the one the same session already learned twice at this site: a
guard is checked against the shape its author had in mind, and the shape that
defeats it is the one a later command happens to use.

## Phase 4 has never run: NBIG2 was not forwarded, 2026-10-13

The run that was meant to prove the chain_ref fix instead answered a
different question, and it did so because the drop arm began keeping the
guest's output an hour earlier. The output ends:

    guest: interrupt-base 58
    guest: write-destroys 0
    guest: /tmp/h2cluster.sh: line 127: NBIG2: unbound variable
    cluster: COULD-NOT-RUN: the guest session ended rc=127 after 17 line(s)

`rc=127` is `sh`'s unbound-variable exit under `set -u`, which the guest half
carries. The host sets `NBIG2=${H2_NBIG2:-20000}` and the guest uses it to
size phase 4's backlog, but the launch line forwarded

    NBIG=$NBIG H2DEBUG=$H2DEBUG

and not `NBIG2`. So the backlog loop at line 300 was the first use of an
unset variable and the guest half died there. Every phase-4 run died there.

This is why `interrupt_resume` has no reading, and the record's earlier
entries read the symptom from the other side. The 2026-10-11 entry says "the
copy of a new directory made 2 inode updates and stopped" and the correction
after it says the copy did not stop but the root's tid advanced past its
subtree; both describe a pass that had copied the first directory. The run
did reach phase 3 and the `bigdir` write; it never reached the `bigdir2`
backlog, the unmount, or the remount. The failure was reported as a phase
that ran and did not converge, when the phase had not started.

The host's own check carried the fingerprint of it and was read as a
different thing. `want_files=$((35 + NBIG + NBIG2))` is 40035, and the run
before this one reported `20035 file entries, 20103 data blocks` and failed
the count. 20035 is 35 plus `bigdir` alone -- `NBIG2`'s 20000 files were
never written. The count was right and the reason for it was one line up in
the guest half.

`5ab69a0` forwards `NBIG2`. The check that would have caught it earlier is
the one already there: a `set -u` variable used in the guest half and not in
the `$RUN` argument list is a name the host can compare, and nothing does.

## Phase 4's workload does not fit its own guest timeout, 2026-10-13

With `NBIG2` forwarded, phase 4 ran for the first time and the timing is now
readable. The klog of the run before it gives one 20000-file write:

    19857.879  h2probe: bigdir write start
    20150.561  h2probe: bigdir write end        292.7 s

Phase 4 writes two such directories -- `bigdir` with the slave mounted and
`bigdir2` with it unmounted -- so the writes alone are about 585 s before the
unmount and the remount are reached. `RUN` is
`timeout ${H2_RUN_TIMEOUT:-600} ssh ...`, and the default is 600 s, so the
default expires inside the second write and the run reports the guest hung
when it is doing exactly what the phase asked.

The run started on 2026-10-13 with `H2_RUN_TIMEOUT=1800` (the two writes, the
interruption and the remount, with headroom). This was measured rather than
chosen from the default, and the phase's sizes had never been checked against
the timeout because the phase had never started: a timeout that is smaller
than the workload it bounds is indistinguishable from a hang in the reading,
and the run before this one would have been reported as one.

`NBIG2` and the timeout are the same shape: a host-side value phase 4 depends
on that nothing compared against what the phase actually does.

## The NBIG2 gap is a regression, not a mis-read claim, 2026-10-13

The P4 row in `doc/README.roadmap.md` describes the 2026-10-11 interrupted
phase as "built and failed on a measured convergence defect", and the NBIG2
defect found on 2026-10-13 does not make that false. `git log -S"NBIG2"`
puts the variable's introduction at `05b859f`, 2026-10-12, a day after the
run the row is about:

    05b859f  2026-10-12  The interrupt probe bounds its mounts and finds a
                         flush defect
    5ab69a0  2026-10-13  Phase 4 could never run

`05b859f` added `NBIG2` in three places -- the host default, the guest's
backlog loop, and the host's own `want_files=$((35 + NBIG + NBIG2))` count --
and not to the `$RUN` line, which still read `NBIG=$NBIG H2DEBUG=$H2DEBUG`.
So the phase was reachable before that commit and unreachable from it, for
one day, until `5ab69a0`.

That is why the two readings of this phase disagree and neither is wrong:
the 2026-10-11 entries describe a phase that ran and reached the copy, and
every entry from 2026-10-12 onward describes a phase that never started. The
row was not corrected for this, because its sentence is about its own run;
the regression is recorded here instead, which is where a dated observation
belongs rather than in a live row whose claim is still true.

The class this belongs to is the same one `5ab69a0` and the sweep closed:
a value the host computes, the guest half evaluates under `set -u`, and the
forwarding list does not carry. Three scripts quote their heredoc, so the
guest evaluates their variables; all three now forward every name their
guest half reads, and the nine the sweep flagged use unquoted heredocs where
the host expands them at write time.

## Phase 4 runs and completes for the first time, 2026-10-13

With `NBIG2` forwarded and the run given a timeout that fits its workload,
`cluster-sync.sh` phase 4 completed. It is the first phase-4 run that has
reached its interruption and its resume, and it answers the question the
phase exists for.

    cluster: 32 check(s), 3 failed
      ok    the unmount waits for the pass rather than returning at once: 50 ms
      ok    the remount starts its thread again: 1
      ok    the resumed thread completes two passes: 2 in 7 s
      ok    no pass reports an error across the interruption: 0
      ok    nothing the thread copied is scrapped unwritten: 0 chains scrapped
      ok    the master's PFS holds the 40035 files, by its own media: 40035 entries
      ok    the slave's PFS matches the master's entry for entry and block for
            block: 40035 file entries; 0 lines differ of 120179

**The convergence half is met.** After the interruption and the remount the
slave matches its master entry for entry and block for block, 0 lines differ
of 120179, read off the media; both volumes `fsck_hammer2` clean; no pass
reports an error; nothing the thread copied is scrapped unwritten; the module
unloads with 0 kmemleak and 0 kernel warning. That is the plan's
interrupted-and-resumed convergence, and it is measured rather than asserted.

**The interruption half is not met, and the three failures are one finding.**
The phase is built so the unmount lands while a pass is in flight, and it did
not:

    FAIL  the unmount lands inside an open pass: bracket open, rc 1
    FAIL  the interrupted slave leaves no thread: 1 left
    FAIL  the stop is read between deferred directories: 0 line(s)

The brackets in the completing run open and close within the same millisecond
(`sync_slaves pfs CL` at 895.246878, `sync_slaves error` at 895.247121), so no
pass was open when the unmount ran; `hammer2_thr_break()`, the one call whose
reading the third check takes, therefore never ran, and the thread was alive
to be counted by the second.

Why the pass is short is in the same log and is the phase's own design input.
The backlog is written with the slave **unmounted**, so the thread must carry
it on the remount, and the phase sizes that backlog (`NBIG2` = 20000) to make
a pass long enough to interrupt. The measured `syncthr: update inode` count is
2 across the whole interruption window, and the print at
`hammer2_synchro.c:944` is gated on `hammer2_debug & 0x8000` **and on `focus`
being non-NULL**, so it counts focus inodes rather than every chain the thread
copies. The count is a probe limit, not a copy count, and the same limit is
why `write-destroys` reads 0 without the 0x0001 bit.

So the reading is: the phase now runs, its interruption window is not opening
at the current sizes, and the convergence it measures after the resume is met.
The window is the thing to widen, and the instrument for it is the phase's own
sizes against a pass's measured length rather than the debug print.

    bigdir  write:  149.3 -> 456.4 s   (307.1 s)
    bigdir2 write:  456.5 -> 817.1 s   (360.6 s)

Those are the phase's two writes, and they are also the timeout finding
beside this: 667.7 s of work under a 600 s default, which is why the run is
given `H2_RUN_TIMEOUT=1800`.

## Phase 4's interruption probe waits on a condition that is never true, 2026-10-13

Phase 4's `interrupt_resume` fails three checks because the probe never
detects an open pass, and the log says why: the condition it waits on can
never be true.

    `sync_slaves error` lines: 182      `sync_slaves pfs CL` lines: 176

The probe waits for a bracket with `o > opened && o > c`, where `o` and `c`
are the CUMULATIVE counts of `sync_slaves pfs CL` and `sync_slaves error`.
The close line is shared: phase 1's `LONE` pfs emits it too (its own opens
are `sync_slaves pfs LONE`), and a pass that errors closes with no matching
open at all. Six such closes exist before phase 4, so `c` leads `o` by six
for the rest of the run and `o > c` is false at every poll. `bracket` is
never cleared, the loop runs out its 1200 iterations, and the check reports
`bracket open, rc 1` -- the two checks below it then fail as its
consequence, since no stop was read and the thread stayed alive.

That is the reading, and the rest of this entry is the second fact: even if
the bracket had been seen, the copy the phase means to interrupt is not
where the phase puts it.

    pass durations, 176 of them:  min 0.160 ms   median 0.210 ms   max 1072.7 ms

One pass in the whole run was long enough to interrupt, and it is the only
long one:

    at 464.7 s   1072.7 ms

and 464.7 s is inside `bigdir2`'s write (456.5 to 817.1), not after the
remount. So the phase's premise -- that a directory written with the slave
unmounted is carried by the thread at the remount, giving a long pass to
interrupt -- does not hold. The thread carried the backlog **during** the
write, on the master's side, while the slave's ROOT was unmounted, and the
remount's passes are 0.2 ms like every other.

The pass counts per window, from the same log, are the second reading:

    bigdir  write (slave mounted)     149-456 s:  59 passes, 5.25 s apart
    bigdir2 write (slave unmounted)   456-817 s:  68 passes, 5.28 s apart
    after the remount                 817-895 s:  15 passes, 5.12 s apart
    after the interrupt unmount       895-998 s:  21 passes, 5.12 s apart

The thread passes every five seconds throughout, and the single 1072 ms pass
is the one that did the copy in the unmounted window. `syncthr: update inode`
agrees: one line in phase 4, at 465.727, inside that same pass.

Why the remount is not where the copy happens. The phase-4 comment says the
frontend writes every element, so `bigdir`'s files reach the slave without the
thread; `bigdir2` is written with the slave unmounted so the frontend cannot,
and the thread must. The thread does carry it, but not at the remount: it
carries it while `bigdir2` is still being written, and the remount's passes are
0.2 ms like every other.

What is measured about the thread's life: it keeps passing across every unmount
in the run and stops only at the final teardown. Read as pass counts after each
unmount's own line:

    unmount at  79.3 s -> 176 passes after, next 3.62 s later
    unmount at  81.5 s -> 176 passes after, next 1.35 s later
    unmount at 456.5 s -> 104 passes after, next 3.07 s later   (the slave ROOT)
    unmount at 895.4 s ->  20 passes after, next 5.00 s later   (the interrupt)
    unmount at 998.4 s ->   0 passes after

So unmounting the slave's ROOT does NOT stop the CL thread, and the phase's
comment that it does was written from phase 1, where the pmp IS the volume being
unmounted: there the lone SLAVE is created on `/mnt/h2m`, the volume that is then
unmounted, so its teardown reaches the thread and the run's own check reads
`no thread is left: 0`. In phase 4 the CL pfs is created twice, on the master's
volume (`/dev/vdb@CL`, `/mnt/h2c`) and on the slave's (`/dev/vdc@ROOT`,
`/mnt/h2s`), and unmounting one of them leaves the thread passing.

The mechanism -- which pmp owns the CL thread and why the slave's teardown does
not reach it -- is NOT traced here and is left open rather than asserted. What
the readings establish is that the thread outlives the slave's ROOT unmount, and
that the copy it makes of `bigdir2` happens during the write rather than on the
remount. The instrument that would place the copy where the phase means to
interrupt it, and the trace of the thread's ownership, are the next readings.

So the window is not too small to hit; it is in the wrong place. The pass that
carries the backlog runs during `bigdir2`'s write, and the window the probe
watches for -- a pass after the remount -- is 0.2 ms every time.

The instrument that would place it: bracket the copy the way the log already
does (one pass over a threshold length, printed with its brackets), or make
the backlog larger than the write's own window so the copy outlasts it. What
would not work is a larger `NBIG2` alone: the copy is bounded by the write,
which is bounded by the same value.

## The interrupt probe's condition is corrected, 2026-10-13

`cluster-sync.sh`'s phase-4 bracket wait now tests the DELTA of the two pass
counters since the loop began, not their cumulative values:

    opened=$(klog 'sync_slaves pfs CL')
    closed0=$(klog 'sync_slaves error')
    ...
    if [ "$o" -gt "$opened" ] && [ $(( o - opened )) -gt $(( c - closed0 )) ]

The old condition was `o > opened && o > c`, and the second clause compared a
CL-only open count against a close count that every pfs shares, so it was false
at every poll (182 closes to 176 opens). It is verified against the run's own
log rather than argued: replayed over the completing run, the corrected
condition sees the one 1072.7 ms pass open in 107 of the 140 ten-millisecond
polls inside it, where the old one saw none in the 8200 polls across the remount
window.

That correction makes the probe honest, and the honest reading is that the
window is still not where the phase expects it. The pass the corrected probe
would find is at 464.7 s, inside `bigdir2`'s write; the remount's passes are
0.2 ms, so the corrected probe correctly reports no open pass there too. The
probe now measures what it claims; what it measures says the phase's premise
needs revisiting, which is a design decision rather than a defect to patch.

## Why the thread copies during the write: the CL pmp is the master's, 2026-10-13

The trace the previous entry left open is answered, and the answer is that the
phase's premise is wrong about which pmp owns the thread.

`hammer2_pfsalloc()` locates an existing pmp BY CLUSTER ID, not by the mount it
is created from:

    TAILQ_FOREACH(pmp, &hammer2_pfslist, mntentry) {
            if (force_local != pmp->force_local)
                    continue;
            if (force_local == NULL &&
                bcmp(&pmp->pfs_clid, &ripdata->meta.pfs_clid,
                sizeof(pmp->pfs_clid)) == 0)
                    break;
    }                                       (hammer2_vfsops.c:301-313)

The master's CL is created first, at the `/mnt/h2c` mount (`/dev/vdb@CL`), and
gets a cluster id. The slave's CL is created with `-u "$clid"` -- the same id --
on `/mnt/h2s` (`/dev/vdc@ROOT`), so `hammer2_pfsalloc()` matches the master's
pmp and joins the SLAVE element to it. The pmp the thread belongs to is the one
whose mount is `/mnt/h2c`; its `pfs_hmps[1]` is the MASTER's device, and its
`sync_thrs[1]` -- named `h2nod-CL` from `pfs_names[1]` -- is created there.

That is why unmounting `/mnt/h2s` does not stop it. The per-PFS unmount branch
of `hammer2_unmount_helper()` clears `pmp->mp` and decrements each element's
`hmp->mount_count`, and only reaches the thread-deleting
`hammer2_pfsfree_scan()` when a device's `mount_count` falls to zero; the CL
pmp's mount is `/mnt/h2c`, which is still mounted. FreeBSD's own
`hammer2_unmount_helper()` has the identical shape, so the thread surviving a
per-PFS unmount is carried, not a port defect. Phase 1 differs because there the
SLAVE is the only element and its mount **is** the volume being unmounted, so
its `mount_count` does reach zero and the thread is deleted -- which is what the
phase-4 comment generalized from, wrongly.

Consequence for the phase: the thread runs while `bigdir2` is written, sees the
new files on its master element, and carries them then. There is no pass on the
remount to interrupt because the copy is already done. The phase cannot place
the copy where it intends by writing with the slave unmounted; the unmount does
not suspend the thread, and the phase's instrument is measuring a window that
its own action does not open.

Not a fix: enlarging `NBIG2`. The copy is bounded by the write that produces it,
so a larger directory makes a longer write and a longer copy in the same
overlap, and the remount stays 0.2 ms.

What a working phase 4 needs is a stop that reaches the thread's own pmp. The
thread reads those flags at two points in its body -- the top-of-loop test at
`hammer2_synchro.c:270` and the `hammer2_thr_break()` call at `:352`, between
deferred directories -- and the setters are `hammer2_pfsfree_scan()` (device
teardown), `hammer2_thr_freeze*()` (the remaster and freeze paths), and
`pfs-delete`. Unmounting the slave's ROOT sets
none of them on the master's pmp. `FIFREEZE` does not either: `hammer2_freeze_fs()`
cancels `pmp->sync_work`, the Linux syncer, and leaves `sync_thrs[]` running.
So the phase needs `pfs-delete` on the CL pfs, a remaster, or the teardown of the
volume the CL pmp was created from -- and the pass to land it in is the 1072.7 ms
one during `bigdir2`'s write, which the corrected bracket condition now sees.

## The interruption reading moves with the run, so the "2" was not the probe's limit, 2026-10-13

The entry above explains `the interrupted pass was copying: 2 inode updates`
as a fixed limit of the print -- `syncthr: update inode` gated on `focus`, so
it counts focus inodes rather than every chain the thread copies. The next run
refutes that as the whole explanation:

| run | `interrupt-copied` (`interrupt pass was copying`) |
| --- | --- |
| the first phase-4 completion | 2 inode updates |
| the run after the bracket fix | **62 inode updates** |

Same source, same phase, same sizes (`NBIG`/`NBIG2` 20000). The count moved
by a factor of thirty, so it is not a constant the print imposes; whatever
`focus` is at the moment of each copy decides how many are counted, and that
varies run to run. What the entry above says about the gate is true -- the
print IS gated on `focus` -- and what it concludes from it is not: a gated
print is a noisy count, not a fixed one, and a reading of 2 in one run is not
evidence of a count of 2 in another.

The correct statement: `interrupt-copied` is not a copy count in either run,
and its value carries no fact about how much the thread copied. The copy
count has to come from somewhere that is not gated, or from the media at the
end, which is what the fingerprint does. The convergence reading is unaffected
-- the slave matches the master entry for entry in both runs -- and so is the
bracket finding, which the same run confirms: `the unmount lands inside an
open pass: bracket open, rc 1` still fails, for the reason the entry two above
gives.

That the bracket still reads 1 after the fix is worth stating plainly. The fix
was verified by replaying the FIRST run's log, and the replay showed the
corrected condition would see that run's one long pass. This run has no pass
open when the probe looks, which is a different thing and not a refutation:
the probe now measures what it claims, and what it reports here is that this
run's copy did not happen in a pass the probe could bracket. The offline
replay answered whether the condition can fire; this run answers whether it
fires in this run's timing, and it does not.

## A two-minute probe answers what the run could not: which unmount stops the thread, 2026-10-13

The phase's interruption had been reasoned about four times and the reasoning
was wrong twice. A 22-line probe replaces it, on the same guest, mounting the
same three volumes and running no workload:

    start thread=2
    --- A: unmount /mnt/h2s   (the phase's action)
    A thread=2
    --- B: then unmount /mnt/h2c (the CL pmp's own mount)
    B thread=1
    --- C: remount h2c, does the thread come back?
    C thread=1

Three readings, and each corrects something:

**The first probe saw TWO `h2nod-CL` threads where the run sees one, and the
difference was the probe's own topology, not the phase's.** A second probe
printing the thread pids and names shows when they appear:

    after master pfs-create CL: threads=[]
    after mount h2c@CL:          threads=[]
    after mount h2s@ROOT:        threads=[22667 h2nod-CL 22668 h2nod-CL ]
    after slave pfs-create CL:   threads=[22667 h2nod-CL 22668 h2nod-CL ]

Both threads appear when `/mnt/h2s` mounts, not when the CL pmp is created.
The first probe ran the same three mounts but WITHOUT phase 1's LONE create
and its `pfs-delete`, so its guest was one pmp richer than the script's. The
run's `the SLAVE in a cluster starts one thread: 1` is the faithful reading
for the script's state, and a probe written to a topology the script does not
have measures something else -- the same defect the port's own notes record
for a test written to a shape the production data does not use.

**Unmounting the slave's ROOT stops nothing.** Both probes agree: the
phase's action, `/mnt/h2s`, leaves every `h2nod-CL` thread it found. This is
the reading the trace predicted from `pmp->mp`, and it is the one that holds
across both topologies.

**Unmounting the CL pmp's own mount stops a thread.** B reads 1 from 2:
`/mnt/h2c` is the CL pmp's mount, and its unmount is what reaches
`sync_thrs[]` for that pmp. Which of the two it removed is not settled here;
what is settled is that the slave's ROOT unmount removes none and this removes
one.

**The thread does not come back on remount.** C reads 1 after remounting
`/mnt/h2c`: a thread stopped by a teardown that removed its element stays
stopped, where phase 1's thread returns because its pmp was destroyed and
re-created. So the phase cannot remount to "resume" a thread stopped this way
-- the resume half of the phase needs the pmp alive.

The probe is kept as `script/` material when the phase is rewritten. What it
establishes for the rewrite: the interrupt must act on the CL pmp
(`/mnt/h2c`), not the slave's ROOT; there are two threads to account for, not
one; and a stop that removes an element is not undone by a remount.

## The join is where the backlog is copied, and it is a five-second window, 2026-10-13

Phase 4's premise is refuted at the mechanism level, and the replacement is
measured. A probe that joins a SLAVE element onto a master that already holds
a written backlog, with the mask the script uses (`debug=0x8000`):

    backlog-written updates=0 threads=0
    === join the SLAVE from the other volume
    pfs_create(CL): SUCCESS
    joined  updates=1000 threads=1
      t+3s  updates=3205
      t+6s  updates=6002
      t+9s  updates=6002      <- flat from here
    final   updates=6002

Three facts, each of which the phase needs:

**The thread is created by the join.** `threads=0` with the backlog written
and no SLAVE; `threads=1` the moment `pfs-create -t SLAVE` returns. The
thread belongs to the pmp the joining element lands in, which
`hammer2_pfsalloc()` matched by cluster id. Nothing before the join has a
thread to interrupt.

**The backlog is copied AT THE JOIN, in about five seconds.** 6002 update
lines are emitted by t+6 s and none after. The copy is not deferred to a
remount and does not depend on one; it is triggered by the element joining,
and it runs immediately. The phase writes its second directory with the
slave's ROOT unmounted and then remounts, waiting for the copy on the
remount, which is why it never sees it: the copy is already over before the
remount, and the remount's own passes are the 0.2 ms the phase has been
timing.

**The window is five seconds, not 200 microseconds.** A pass that carries
6000 files takes seconds; the passes the phase brackets are 0.2 ms. So the
interrupt the phase wants exists, at the join rather than at the
remount -- and a 10 ms poll lands inside it with room to spare, which is the
opposite of the premise that the window must be widened.

Two probe defects were made and fixed on the way, both the class this port's
notes already record:

* the first ran without `debug=`, so `hammer2_debug` was 0, every bracket and
  update print was suppressed, and every count read 0. A probe written to a
  shape the run does not use measures nothing; the script's own `insmod` line
  carries `debug=$H2DEBUG` for exactly this reason.
* before that, a probe reusing stale phase-4 images hit a leftover `/mnt/h2c/big`
  and joined under a name that did not take, and a probe that skipped phase
  1's LONE create ran one pmp richer than the script's, so its thread count
  was 2 where the script reads 1.

Each was caught by a reading disagreeing with an expectation and traced to the
probe rather than the subject. The rule that would have caught all three
sooner: run the probe against the same module knobs and the same guest state
the harness uses, and state before the run what a zero would mean.

## The bracket is not a pair, and the join pass is one eight-second pass, 2026-10-13

Two readings from the same probe, and both are structural.

**The two log lines are not a bracket.** `sync_slaves pfs CL` is printed once
per pass, at the top of the outer loop (`hammer2_synchro.c:324`).
`sync_slaves error` is printed INSIDE the inner `for (;;)` loop
(`hammer2_synchro.c:335`), which iterates while the scan returns
`HAMMER2_ERROR_EAGAIN`. So one pass emits one open and MANY closes, and a
count of the two is not a bracket at all:

    P=5  C=11        (one probe, mid-copy)

The phase's check, and the correction made to it earlier the same day, both
treat these as a pair. The correction (`o > opened && (o-opened) > (c-closed0)`)
at least tests the right thing -- an open with no close after it -- but it
still assumes one close per open, and a pass with deferrals breaks that
assumption in the direction that makes the check read closed when it is open.
What the check needs is the OPEN count alone advancing, which is what a
"pass began" means; the closes carry the error code and the deferral pointer,
which is a different fact.

**The join pass is one eight-second pass, with seven deferral retries.** The
raw sequence, from the probe that joined a SLAVE onto a 6000-file backlog:

    7810.289  sync_slaves pfs CL              <- pass opens
    7810.587  sync_slaves error 256  defer .. <- EAGAIN, retry
    7812.824  sync_slaves error 256  defer ..
    7813.888  sync_slaves error 256  defer ..
    7814.972  sync_slaves error 256  defer ..
    7816.127  sync_slaves error 256  defer ..
    7817.324  sync_slaves error 256  defer ..
    7818.341  sync_slaves error 0            <- pass ends, 8.05 s

`256` is `HAMMER2_ERROR_EAGAIN`: each retry is a deferral, and the pass takes
8.05 seconds to drain them. That is the window P4's interruption needs, and it
is at the join.

This also explains every earlier reading. The 0.2 ms passes the phase has been
bracketing are ordinary idle passes on a converged cluster -- 176 of them in
the first phase-4 completion, median 0.210 ms. The one long pass that run did
show (1072.7 ms at t=464.7 s) was the copy of `bigdir2` in progress, and the
phase's design put its unmount somewhere else entirely. There was never a
window to widen; there was an eight-second window at a place the phase does
not look.

**What follows for the rewrite.** Stop watching for a bracket. A pass has
begun when `sync_slaves pfs CL` increments; the pass that carries the backlog
is that pass, and it lasts seconds. The interruption is: write the backlog,
join the SLAVE, wait for the open count to increment, and stop while it is
still the same open -- with the stop reaching the CL pmp, which unmounting the
slave's ROOT does not do.

## A stop waits for the pass to drain, so `interrupt_resume` measures something narrower than "mid-pass", 2026-10-13

The rewrite probe issued the stop at the only moment that matters -- inside the
8-second join pass -- and the copy ran to completion past it:

    backlog: P=0 T=0
    joined:  P=1 T=1
    mid-pass: P=1 T=1 U=2068      <- the copy is 1/3 done
    stop-issued rc=0              <- umount /mnt/h2c, mid-pass
    after-stop: T=1 didbreak=0 P=1 U=5005
    late: T=1 didbreak=0 P=1 U=6002   <- finished anyway

`didbreak` never prints and every file is copied. The reading is not a probe
failure; it is `hammer2_thr_break()` doing what the script's own phase-4
comment already said -- "a stop arriving during a pass waits for the current
scan to finish: what the interruption costs is the rest of the pass it landed
in, and the window is the pass's own length" -- which the probe confirmed
rather than discovered. The
thread reads `HAMMER2_THREAD_STOP`/`FREEZE` at two points only: the top of the
outer loop (`hammer2_synchro.c:270`) and, via `hammer2_thr_break()`, between
deferred directories (`:352`). Neither is inside `hammer2_sync_slaves()`, so a
stop arriving during a scan is seen when that scan **finishes**, and the pass
that was running completes.

What this means for the criterion. P4's `interrupt_resume` cannot mean "stop
the thread in the middle of a pass" in this tree, because nothing can: the
stop is honored at pass boundaries, by design, in carried code that upstream
shares. What the phase can measure, and what the earlier 30-second idle pass
test already measured, is a stop **observed at the next read point** and the
resume that follows it -- with the stop reaching the thread's own pmp, which
the current phase's unmount does not do.

So the rewrite's target narrows to the honest one:

* the stop reaches the CL pmp (`umount /mnt/h2c`); the thread reads it at the
  next pass boundary, so the pass that was running completes and the thread
  survives the unmount (the probe above reads `after-stop: T=1`; carried code
  honors STOP at pass boundaries only, and `hammer2_thr_delete()` is reached by
  pfs-delete and the device teardown, not by `umount`. The earlier `T 1 to 0`
  written here was wrong and is corrected on 2026-10-14);
* the thread is observed stopping at the pass boundary the design allows;
* whatever the pass copied before the boundary is on the slave's media, and
  nothing copied is scrapped unwritten;
* the remount resumes it and the slave converges to its master.

Whether "the pass completed before the stop was seen" is a defect or the
documented contract is a question for the criterion's wording, not for this
run. The plan's step 5 (issue a stop mid-pass) is replaced by this: issue the
stop, then read the boundary. The design note in `proposals/` carries it.

## The probe defects of 2026-10-13, and the rule that catches each, 2026-10-13

Five probes were written this day for the phase-4 interruption, and four of
them were wrong in ways that read as readings about the subject. They are
listed here because each is a distinct shape, and the rule beside each is what
would have caught it before the run.

| probe defect | what it read | the rule |
| --- | --- | --- |
| ran `insmod` without `debug=`; `hammer2_debug` was 0 | every bracket and update count 0, read as "the thread copied nothing" | run the probe against the same module knobs the harness uses; the script's own `insmod` carries `debug=$H2DEBUG` |
| built the topology without phase 1's LONE create and `pfs-delete` | `h2nod-CL` = 2 where the script reads 1 | reproduce the harness's guest STATE, not just its mounts; a probe on a different state measures a different system |
| reused stale phase-4 images with a leftover `/mnt/h2c/big`, and joined under a name that did not take | backlog "written" that was already there, and a join that never happened | build the fixture the probe needs; check the join's own exit, not the absence of an error |
| waited for a SECOND pass (`o > opened` where `opened` was already 1) | timed out at 3 s while a pass was open the whole time | state, before the run, what the first non-zero reading will be, and read the counter's value rather than its delta from a stale baseline |

The common shape: a probe encodes an expectation about the system, and when
the reading is wrong the expectation is the first suspect, not the subject.
The two probes that produced this day's real findings were the ones whose
readings were checked against the source before they were believed -- `P=5
C=11` sent me to the print sites, and `U` continuing past the stop sent me to
`hammer2_thr_break`.

The rule that would have caught all four: **state before the run what a zero
means, and run the probe against the harness's own knobs and state.** A zero
from a probe that cannot see the subject and a zero from a subject that did
nothing are the same string.

## The reasoning loop, and what broke it, 2026-10-13

P4's phase-4 interruption was reasoned about four times across this day and the
reasoning was wrong on three of them, each time in the same way: a conclusion
drawn wider than the reading under it.

| what was concluded | the reading under it | what measurement showed |
| --- | --- | --- |
| "blocked behind the flush defect" | a kernel log with a flush fault in it | the block was `NBIG2` never forwarded; the guest exited 127 |
| "no pass was in flight; widen the window" | 0.2 ms passes on a converged cluster | the phase's stop reached the wrong pmp, and the pass it wanted is 8 s at the join |
| "the copy happens at the remount" | the phase's own comment saying so | the copy happens at the join, during the write |
| "interrupt-copied is capped at 2 by focus" | one run reading 2 | the next run reads 62; a gated print is noisy, not capped |
| "a stop issued mid-pass interrupts it" | `hammer2_thr_break`'s existence | the stop is read at loop top and between deferred dirs; the pass completes |

Each row is a real reading and a conclusion it does not support. What broke
the loop was not more reasoning but a cheaper instrument: a 22-line probe that
mounted the same volumes, ran no workload, and printed the thread count after
each action. It answered in two minutes a question four rounds of reading had
got wrong twice.

Two habits did the rest of the work, and both are worth naming:

* **reading the subject's own comments before deriving from its code.** The
  script's phase-4 comment already said a stop waits for the scan to finish;
  two entries here concluded the opposite from the code path, and the probe
  then confirmed the comment. `hammer2_synchro.c`'s own comment predicts the
  NULL-parent case the same way.
* **stating what a zero means before the run.** The probes that failed all
  failed by returning a reading that was indistinguishable from the subject
  doing nothing. The ones that worked had a number that only one explanation
  could produce (P=5 against C=11; U climbing past a stop).

The rule this leaves, for the next person at this phase: when a probe's
reading disagrees with a derivation, suspect the derivation, then the probe's
setup, and only then the subject -- and get a reading cheap enough to run
again, because the expensive run is what made four wrong conclusions look
final.

## The interruption lands and the slave loses 42 inodes, 2026-10-14

The rewritten phase 4 issues its stop inside an open pass, and the check that
failed in every previous run passes:

    ok    the unmount lands inside an open pass: bracket open, rc 0
    ok    the copy had begun before the unmount: rc 0
    ok    the interrupted pass was copying: 44 inode updates
    ok    the unmount waits for the pass rather than returning at once: 4707 ms

That is the first reading of P4's interruption at all, and it is 31 checks 4
failed. The four are not the harness:

    FAIL  the stop reaches the CL pmp and leaves no thread: 1 left after umount /mnt/h2c
    FAIL  nothing the thread copied is scrapped unwritten: 10 chains scrapped
    FAIL  the slave holds what the master holds: master (40042 inode, 40103 data,
          40038 dirent), slave (40000 inode, 40061 data, 40038 dirent)
    FAIL  the slave's PFS matches the master's entry for entry and block for
          block: 40035 file entries; 84 lines differ of 120179

**The defect: an interrupted pass loses what it had copied.** The slave is 42
inodes and 42 data blocks short of its master, 10 chains the thread copied are
scrapped unwritten, and 84 fingerprint lines differ. Before this rewrite the
same phase reported convergence met (`0 lines differ of 120179`) -- but that
reading was from a run whose stop never landed, so the pass it measured was the
uninterrupted one. The convergence the phase has been reporting all day was the
convergence of a pass nobody interrupted.

What is not yet established, and is left open rather than guessed: which of the
10 scrapped chains accounts for the 42 missing inodes, and whether the thread
count reading 1 is the same defect or the check's 20-second wait expiring
before a pass drains. The first probe (idle state) read the thread going to 0
on `umount /mnt/h2c`; this run (mid-pass) reads 1, so the two states differ and
that difference is the next thing to measure.

The run is kept whole at `cluster-interrupt-lands-20261014.log`, with its two
images beside it, and the script that produced it at hash `fdee0f93`, verified
unchanged across the run.

## The 2026-10-11 defect is reproduced, which it could not be before, 2026-10-14

The 42 missing inodes above are the defect the entry of 2026-10-11 describes,
and the identity is exact:

| reading | dirents | inodes | data | short |
| --- | --- | --- | --- | --- |
| 2026-10-11, master | 20037 | 20041 | 20103 | |
| 2026-10-11, slave | 20037 | 19959 | 20021 | -82, -82 |
| 2026-10-14, master | 40038 | 40042 | 40103 | |
| 2026-10-14, slave | 40038 | 40000 | 40061 | -42, -42 |

Both readings have the same shape: the directory entries all arrived and the
inodes and their data did not, by the same count each. The slave holds names
pointing at inodes that are not there, and the root's `modify_tid` has
advanced past the subtree it covers, so the thread's gate reads the state as
synchronized and no later pass repairs it.

What is different is that this run reproduces it ON DEMAND. The 2026-10-11
entry was written from volumes an interrupted copy happened to leave, and the
mechanism it describes could not be re-triggered because the phase's stop
never landed -- every phase-4 run until 2026-10-14 reported convergence met,
from a pass nobody interrupted. With the stop landing inside an open pass,
the defect appears on the first run and at a size the phase chooses (42
inodes against a 40000-file set, 82 against a 20000-file one).

So P4's `interrupt_resume` is not blocked on reaching the interruption any
more. It reaches it, and what it finds is a known defect, now reproducible,
with two readings of it from independent runs a day apart.

The next readings this makes possible, named rather than started. The
shortfall is neither fixed nor a function of the backlog: both runs wrote the
same `NBIG2` of 20000, and one lost 82 inodes and the other 42. What varies
between them is when the stop landed, so the next measurement is the shortfall
against the point in the pass the stop arrives -- the phase can place that
now, which it could not before. The mechanism is the root's `modify_tid`
advancing before its subtree is complete, so the question a fix has to answer
is what makes the root's tid advance past a partial copy.

## Two kernel fault injectors, two parsers, and one silent no-op, 2026-10-14

Writing `sync-io-fault.sh` cost one run to a defect the shell cannot see, and
it is worth recording because the same shape will meet the next person.

`failslab`'s attributes take `Y`/`N`. The block layer's
`/sys/block/<dev>/make-it-fail` takes an INTEGER:

    ssize_t part_fail_store(struct device *dev, struct device_attribute *attr,
                            const char *buf, size_t count)
    {
            int i;
            if (count > 0 && sscanf(buf, "%d", &i) > 0) {
                    if (i)
                            bdev_set_flag(dev_to_bdev(dev), BD_MAKE_IT_FAIL);
            ...
    }                                               (block/genhd.c:1189-1200)

`echo Y > /sys/block/vdb/make-it-fail` therefore parses to nothing, sets no
flag, and **returns 0**. The write reports success and does nothing. Measured
on the guest: after `echo Y` the attribute reads back 0; after `echo 1` it
reads back 1; `failslab`'s `task-filter` takes `Y` and reads back `Y`.

The first run of the instrument wrote `Y`, injected 0 failures, and every
check after that passed on I/O that never failed. What caught it was the
instrument's own fake-pass check -- `[ "${inj:-0}" -gt 0 ]` -- which is the
reason that check exists. The fix writes `1` and reads the flag back, because
a silent no-op is indistinguishable from a working arm by its exit status.

The rule, which is the same one the day's probe defects produced: when a
kernel interface is written to configure something, read back what it
configured, because two interfaces next to each other in the same
documentation can take different encodings and one of them fails silently.

## require-end resets to ULONG_MAX, and setting it to zero disables the fault, 2026-10-14

The I/O-fault instrument injected 0 across four runs while every gate read
open, and the cause is one line of `fail_stacktrace()`:

    bool found = (attr->require_start == 0 && attr->require_end == ULONG_MAX);
    if (depth == 0 || (found && !attr->reject_start && !attr->reject_end))
            return found;
    nr_entries = stack_trace_save(entries, depth, 1);
    for (n = 0; n < nr_entries; n++) {
            ...
            if (attr->require_start <= entries[n] &&
                            entries[n] < attr->require_end)
                    found = true;
    }
    return found;                       (lib/fault-inject.c:88-108)

With `require_end == 0`, `found` starts false and the range test compares
`entries[n] < 0`, which is never true, so `fail_stacktrace()` returns false and
**every** bio is rejected. The reset value is `ULONG_MAX`, not zero, and there
is nothing in the debugfs file or its name that says so.

Measured, on a flagged device with probability 100 and no other gate closed:
a kprobe counted **82 calls to `should_fail_bio`** and the injected count was
0; with `require-end` set to `0xffffffffffffffff` the next run injected on the
first bio and the trace printed.

Two lessons, and the second is the expensive one.

* **A disarm that writes a wrong reset value poisons the guest.** The first
  version of this instrument disarmed by writing `require-end 0`, which left
  the fault permanently off for every run after it -- including the runs that
  were meant to show the fix working. The symptom was four identical "0
  injected" readings with no indication that the previous run had caused them.
* **A facility that is configured, present, and called can still do nothing.**
  `CONFIG_FAIL_MAKE_REQUEST=y` in both the guest and the build tree,
  `should_fail_bio` in `/proc/kallsyms`, the kprobe showing 82 invocations,
  and zero failures: the check that would have caught it earlier is reading
  back the RESET value before arming, which the instrument does now, and
  reading the arm back after, which it also does now.

This is the third silent no-op found at this instrument in one day, after the
`Y`-versus-`1` encoding and the missing per-device flag. Each was found by a
check written for exactly that purpose -- the fake-pass assertion, the
readback -- which is the argument for writing the check before the run rather
than after.

## A failed bio crashes the port in freemap_alloc and then wedges the guest, 2026-10-14

P4's `io_faults` criterion has a reading, and the port fails it. The report is
kept whole at `doc/history/kernel-reports/hammer2-iofault-freemap-wedge-20261014.txt`.

The fault is one failed read of the freemap, aimed at the module's own `.text`:

    Buffer I/O error on dev vdb, logical block 6, async page read
    hammer2: hammer2_chain_modify: freemap_leaf blockref I/O error 5 at 000000000006000f
    hammer2: hammer2_chain_load_data: freemap_leaf blockref I/O error 5 at 000000000006000f
    Oops: general protection fault, probably for non-canonical address 0xdffffc0000000003
    KASAN: null-ptr-deref in range [0x0000000000000018-0x000000000000001f]
    RIP: hammer2_freemap_alloc+0xa31

The error is reported correctly at the first two lines -- the port names the
blockref and the errno -- and then the NULL dereference follows in
`hammer2_freemap_alloc()`, reached through
`hammer2_chain_modify -> hammer2_chain_create -> hammer2_xop_inode_create_det
-> hammer2_inode_create_normal -> hammer2_vop_ncreate`. So the port detects the
I/O error, reports it, and then dereferences a pointer it should have treated
as absent once the freemap could not be loaded.

**The guest does not merely crash; it wedges.** Two tasks are left in D state
afterwards, captured through the guest agent:

    D    kworker/6:2+eve   hammer2_vfs_sync_pmp
    D    bash              lookup_open

so the mount cannot be unmounted (`umount: /mnt/a: target is busy`) and the
module cannot be unloaded (`Module hammer2 is in use`), and the guest needs a
reset. That is the criterion's question answered in the negative: the port
neither recovers to a verified alternate state nor returns an error to the
caller. It fails
into a state that holds the kernel.

**What was actually run.** The instrument reported `0 injected` on this run and
four before it, because of three separate defects in the instrument -- the
`Y`/`1` encoding, a `require-end` of 0 instead of ULONG_MAX, and counting from
`times` instead of the trace. The fault DID fire on this run (the report is the
proof) and the guest's own log is where the reading came from. The instrument
is fixed for all three; a re-run through the fixed instrument is the next step
so the reading and the instrument agree.

Left open rather than guessed: which pointer in `hammer2_freemap_alloc()` is
NULL after a failed freemap read, and whether the wedge is a consequence of
that dereference or a second defect. The report's RIP and the two D-state
stacks are the evidence for whoever takes it.

## repeated_sync_cycles is met: eight cycles, 18 checks, 0 failed, 2026-10-14

P4's fifth criterion has a reading. `sync-empty-base.sh` already ran unmount
and remount cycles with a convergence reading at the end; the reading had
never been taken at more than the default four, and the criterion asks for
repeated cycles rather than one. Run with `H2_CYCLES=8`:

    ok    an unmount left modified chains: 11 unmount reading(s), 0 with modified chains, expected fixed
    ok    the thread copied the set to the slave element: 4002 inode update(s)
    ok    a flush finds an empty base: 0 miss(es), expected fixed
    ok    the chain check gives up, as the original log does: 0, expected fixed
    ok    the device is marked in error: 0, expected fixed
    ok    no pass reports an error: 0
    ok    no kernel warning, BUG or UBSAN report: 0
    ok    every mount is dropped: 0 left
    ok    the module unloads: 1 of 1
    ok    fsck_hammer2 exits 0 on repro-master.img: exit 0
    ok    fsck_hammer2 exits 0 on repro-slave.img: exit 0
    ok    the SLAVE converged to its MASTER, entry for entry and block for block:
          slave/master by type: inode 5601/5601, data 5600/5600, dirent 5601/5601;
          0 line(s) differ of 16802

    sync-empty: 18 check(s), 0 failed

The 11 unmount readings are the cycles: eight of its own plus the run's
set-up and teardown, every one leaving `0 modified` chains, and the
convergence read off the media at the end with the population asserted
first, so an empty fingerprint cannot read as agreement. The device tie
matches (guest `3af2517b` against the image's own fsid), the set is 4000
files, both volumes are `fsck_hammer2` clean, and the module unloads.

So `repeated_sync_cycles` is met. What it measures, stated plainly: repeated
unmount and remount of a slave's volume against a master whose mount stays
up, with the cluster thread carrying the set each time and the media
compared at the end. It does not measure repeated cycles *of the
interruption* -- that is `interrupt_resume`, which has its own reading and
its own open defect (the 42-inode loss). The two are separate criteria and
this entry is about the first.

## The io-fault budget was spent by the sync thread, not the writes, 2026-10-14

The instrument reported `times moved 0` on four runs with every gate reading
open -- probability 100, the device flag set, `require-end` ULONG_MAX, the
armed range read back exactly. The arm was correct and nothing fired.

The cause is the fixture, not the fault injector. The instrument creates a
`CL` pfs to have a cluster to synchronize, and that starts a synchronization
thread which submits its own bios. With `interval 1` and `probability 100`,
**the first four bios any task submits consume the whole `times` budget**, so
the thread ate it before the write loop began. A hand probe with no CL pfs
injected on its first write with the same attributes, which is what separated
the two.

`task-filter` fixes it: the fault then fires only for a task whose own
`/proc/<pid>/make-it-fail` is set, and the write loop runs in a child that
sets it. Verified on the guest, that configuration gives the first write an
`Input/output error` and the budget reaching zero -- the fault landing on the
write task rather than the thread. The sibling alloc-fault instrument uses the
same scoping, and its comment says why.

This is the fifth failure of this one instrument in a day, and the second
whose cause was the fixture rather than the injector:

| # | what read wrong | cause |
| --- | --- | --- |
| 1 | `times` moved, no trace | counted `times`, which moves without `fail_dump` |
| 2 | 0 injected | `echo Y` on an integer attribute, silent no-op |
| 3 | 0 injected | `require-end` 0 instead of ULONG_MAX, filter rejects all |
| 4 | arm state unreadable | the instrument did not print what it armed |
| 5 | 0 injected, arm correct | the sync thread spent the budget first |

Rows 2 and 3 are described above; row 4 is its own commit. The pattern across
all five: **each was found by reading back a gate the instrument had written
and finding it not what was intended.** The readback the instrument now prints
on every run is what turned row 5 from "the fault does not work" into "the
budget went somewhere else", and that is the argument for printing the arming
state unconditionally rather than on failure.

## io_faults is met: the freemap guard holds and the run is clean, 2026-10-14

The fix of 2026-10-14 (a freemap leaf whose read failed is dereferenced as if
it had data) is verified by the instrument that found the defect. Same aimed
fault, same 4 injections, same write workload:

    ok    the fault was injected: 4 forcing line(s), times moved 4
    ok    the failure lands in the port's I/O: 46 hammer2 frame(s) in the trace
    ok    the set written before the fault is still there: 240 file(s), 200 written
    ok    every file written before the fault still reads: 0 unreadable
    ok    the volume unmounts after the fault rather than wedging: umount-ok
    ok    the module unloads: 1 of 1
    ok    no kernel warning, KASAN or UBSAN report: 0
    ok    kmemleak reports nothing of hammer2's: 0

    sync-io: 8 check(s), 0 failed

Before the guard: a NULL dereference in `hammer2_freemap_alloc()` and a guest
left with a kworker in `hammer2_vfs_sync_pmp` and `bash` in `lookup_open`, the
mount un-unmountable and the module unloadable. After it: every file written
before the fault reads, the volume unmounts, the module unloads, and the
kernel log is clean.

**So P4's `io_faults` criterion is met.** What it measures, stated plainly:
one injected block-I/O failure aimed at the port's own text during a synced
write, and whether the media already written survives and the port fails
rather than wedging. It does not measure a fault during the cluster thread's
own pass (the fault is scoped to the writing task, which is what keeps the
sync thread's bios from spending the budget) and it does not measure a device
that fails every bio. Those are separate readings and neither is taken.

The instrument needed six fixes to get here, every one of them in the
instrument and none in the port: the `Y`/`1` encoding, `require-end` 0 rather
than ULONG_MAX, counting `times` rather than the trace, printing what it
armed, scoping the fault to the writing task, and taking the range from the
`.text` section rather than from an alphabetically-first symbol. The last two
are the same shape as each other and as the day's probe defects: an
instrument that fails silently and a subject that did nothing produce the
same reading.

## crash_during_sync gets its reading, and four checks that threw away evidence, 2026-10-14

P4's fifth criterion has no reading until this run. The `sync` cell of
`script/crash-matrix.sh` cuts power once the guest reports a task blocked in
the flush path (a D-state `sync` or the port's `h2nod` thread), rather than at
a fixed time, so the crash lands while a flush is outstanding rather than
between two of them. The task set is the signal, not a stack: the cell does
not read `/proc/PID/stack`, so what is established is that a task in the
flush path was blocked when the power went, not that it stood inside a
hammer2 frame. For this port the detector catches the condition, power is cut
with the flush outstanding, and the port recovers clean:

    == linux sync run 1
      sync-in-flight yes  (in-sync D    sync)
      cut   headers zone2:0x16 zone1:0x15 zone0:0x14 zone3:0x13
      linux   entries 1201 last 1199
      linux   unreadable 0
      linux   write after recovery exit 0
      linux   free /dev/vdb@CRASH  7.7G   61M  7.3G   1% /mnt/c
      linux   umount exit 0
      linux   debug_locks 1
      linux   reports 0
      ok    host fsck_hammer2 after linux
      fbsd    freebsd fsck clean
      row   linux sync 1 host=ok linux=0 fbsd=0 miss=no

Power removed with the flush outstanding, and every file readable, the volume
mounting read-write, accepting a write, unmounting, `fsck_hammer2` clean on
the host and on DragonFly's own port reading the same image. That is the rerun,
after the fixes below; the first run read as this but was weaker than it read.

**The first run's reading was weaker than it read.** It reported "0 failure(s)"
for a pair whose FreeBSD half never reached the condition and whose recovered
write failed under a check that passed. None of that is the port's verdict;
all of it is the instrument reporting a condition it did not reach as one it
did, which is the reading the cell itself exists to refuse.

**Four defects, every one in the instrument.**

The recovered write's status was `sync`'s, not the write's:
`echo ... > /mnt/c/crash/linux-after; sync; echo "write after recovery exit
$?"` prints the status of the `sync`, which succeeds even when the write
before it was refused with `No space left on device`. The check
`^write after recovery exit 0$` therefore passed beside a write that failed.
Captured now with `if echo ... > file; then wst=0; else wst=$?; fi`, with the
free space printed beside it. This affects all five cells and both ports, and
it is the same shape as the day's other two: a status that belongs to the last
command in a pipeline is read as the subject's.

The detector's timeout produced a row. `sync-in-flight no-poll-timeout` cut
power anyway and the run counted as an agreement. Why the FreeBSD half missed
is now measured, and it is the cell's design rather than its timing. The
candidates are refuted one by one: the sampling rate, since a guest-side poll
of 4000 samples misses where the old per-ssh poll did too; a full volume,
since the second run's FreeBSD recovery read `free /dev/vtbd1@CRASH 7.7G 4.4G
3.2G 58%` and wrote without trouble; and the task name, since a probe of the
FreeBSD guest under a sync-every-five-files hammer2 workload sampled its
D-state set every second for ten seconds and found only the permanent kernel
threads (`crypto`, `cam`, `busdma`, `zfskern`, `rand_harvestq`, `pagedaemon`,
`vmdaemon`, `audit`, `geom`, `usb`, `bufdaemon`, `vnlru`, `syncer`), the same
set in every sample with no transient flush task in it. `syncer` and
`bufdaemon` are in D state whether or not a flush is outstanding, so a
detector keyed on them would match every sample and be a false positive rather
than a signal. The cell's detector is a Linux-port instrument: this port's
flush path blocks the writing task (`in-sync D sync`, this port's `h2nod` when
the cluster thread flushes), and the FreeBSD port's flush runs in kernel
threads that are always D. So the FreeBSD half is COULD-NOT-RUN by design, and
the row says so. What was wrong regardless of cause is the reporting: a miss
is the instrument not reaching its condition, which is neither a pass nor a
failure, so the row carries `miss=yes`, the summary counts it apart from
`$fail`, and the script exits 2. Where several runs of a cell disagree and
some missed, the runs that landed are still compared.

The detector threw away what it caught and sampled slowly. It took one ssh
round trip per sample, so its "5 ms poll" was tens of milliseconds and its
window narrow; it printed a bare `yes`/`no` with no task. It is now one
guest-side ssh of ~4000 samples that prints the task it caught
(`in-sync D sync`), so the evidence survives the run and a near-miss is
visible as one.

A count check cannot see a truncated file. `^entries [1-9]` passed on 19181
entries while a later write on the same volume was refused for space. The
count is not the question in the sync cell; whether what landed is readable is,
and `unreadable 0` is the check that answers it.

**The finding the masked status was hiding, now read.** In the first run every
FreeBSD-cell recovery printed `No space left on device` and reported exit 0.
The corrected check prints the write's status beside the free space, and the
second run's pair reads `free /dev/vdb@CRASH 7.7G 61M 7.3G 1%` and
`free /dev/vtbd1@CRASH 7.7G 4.4G 3.2G 58%` with both writes at exit 0. So the
volume was neither full nor mis-accounted: the first run's `entries 19181`,
against the second's 11401 and 1201, is the difference. A HAMMER2 volume under
a long copy-on-write write fills with superseded blocks that bulkfree has not
reclaimed, and 19181 files of 3 to 80 KiB was enough to reach that on this
image where the lighter runs were not. That is the reading the masked status
discarded: not a recovery defect, but a workload that fills a volume the cell
does not size for, and a check that could not tell the difference.

**P4's `crash_during_sync`, stated plainly.** One power cut with the port's
flush outstanding, from a run whose detector caught the condition and printed
the task, recovered clean on both ports and the host: every file readable, the
volume mounting read-write, accepting a write, unmounting, `fsck_hammer2`
clean. It is one run of one writer, and the FreeBSD half of the same cell did
not reach the condition. The criterion is reached, and the row records it as
met with those two limits rather than as a sweep.

## A failed copy is not what the interrupted pass loses, and the row's rollup claim was stale, 2026-10-14

The record's open question for the interrupted pass was what makes the root's
`modify_tid` advance past a partial copy. The candidate with the most support
was that a child copy fails, its `nerror` is discarded at
`hammer2_synchro.c`'s action switch, and the pass then stamps the element
root's `modify_tid` to the master's, so every later pass reads
`want_update == 0` at the gate above the scan and does not retry. Three
counters were added over the switch (`acted`, the arms that ran; `failed`, the
non-zero `nerror`; `last`, the most recent value), printed with the file-key
counters the pass already emits.

**The hypothesis is refuted.** Over one instrumented run:

    filekeys n<0 42  n==0 7  n>0 57  acted 9351 failed 0 last 0
    ...
    filekeys n<0 42  n==0 14 n>0 57  acted 44729 failed 0 last 0

44729 actions and zero non-zero `nerror`. No copy the action switch made
returned an error, so a failed-and-masked copy is not what the interrupted
pass loses. The gate and the stamp are real -- `want_update` at line 630 does
end the pass on an equal `modify_tid`, and the inode path does defer through
`dodefer` -- but the thing the stamp hides is not, in this run, a copy that
failed.

**A stale claim in a gated document, found on the way.** The origin table in
`doc/README.status.md` described this file's marks as including "the slave-side
errors upstream discards rolled up, so a slave that failed to take a chain is
not marked synchronized and the next pass retries it". The rollup was tried
and reverted on 2026-10-13 (`a591c19`, "The slave-side error rollup aborted the
pass and is reverted"), because aborting the pass on the first slave-side
failure retried the same early keys. The row now states the counts and the
reverted rollup instead. `test-inventory.sh` reads the line count and the mark
count against the source and cannot see this sentence, so the claim outlived
the code it described, in the document whose job is to say what the marks mean.

**The run hung, and that is separate.** The instrumented run was stopped at its
600 s bound still churning in `indirect_maint` (a parent collapsing a child,
`b6a9cb23fd8a8001/0 collapsing 0000000058aa848b 0000000000000000/63`, with the
parent re-inserted by the same `create_indirect` bound the 2026-10-13 entry
records as the convergence fix). It read no shortfall because it never
finished, so the question the counters were built to answer -- where the
shortfall comes from -- is still open. What the counters settled is only the
negative: no failed copy. The log is kept whole at
`cluster-hang-20261014-101039.klog`.

**The open question is not new, and this entry first mis-stated it twice.** It
belongs to the 2026-10-11 section "The missing inodes were copied and then
destroyed by a root pass", which reached a mechanism with the carried per-chain
prints under `HAMMER2_SYNCHRO_DEBUG` (`debug=0x8001`): the thread destroyed
exactly the missing inodes on the slave, in one pass that scanned only the PFS
root, through `hammer2_sync_destroy()` and its `n < 0` arm, which is taken when
the master's scan does not return a chain the slave holds though the master's
own media has it. In that run the thread inserted none of the large
directory's inodes at all, and the slave's media held 19960 of them anyway, so
the writer that put them there is not the sync thread's insert path. If the
destroy still accounts for the shortfall, the stamp is what conceals it: the
pass that destroyed the inodes completed without error and stamped the root, so
no later pass retries, and "the root is stamped past its subtree" is the
consequence rather than the cause.

**But that finding predates the code that changed the insert path, and it does
not transfer on its own.** The 2026-10-11 run was written before the two clamps
of 2026-10-13: the `ncount` bound in `hammer2_chain_create_indirect()` that
made the slave converge, and the clamp in `hammer2_sync_insert()` that narrows
a copied radix to the receiving parent. Both changed what the insert path does,
and the 2026-10-11 entry says the insert path copied none of those inodes,
which is exactly what a clamp on that path could change. So the destroy is a
lead carried across a code change, not a settled cause: what holds today is
that a failed copy is out (the counters above) and the destroy path is where
the 2026-10-11 evidence points, which the next run re-confirms rather than
assumes.

The instrument for that is in the carried source and needs only the mask: the
per-chain prints the 2026-10-11 entry used under `debug=0x8001`, which the
runs above did not carry (they ran at `0x8000`). It answers the two things that
entry left open. Which call puts the large directory on the slave, since the
thread's insert path is not it. And which directory the destroyed inodes
belonged to, read from the fingerprint's own walk, because a dirent key does
not encode its parent. The counters added here stay for the negative they
establish: no copy failed.

## The interrupted pass loses 422 inodes at the timeout the phase requires, and a verbose run hides it, 2026-10-14

Three runs of phase 4 this session, and the reading moves with the timeout and
the debug mask rather than with the port:

| run | `H2_RUN_TIMEOUT` | `H2_DEBUG` | inode updates before the stop | slave short | verdict |
| --- | --- | --- | --- | --- | --- |
| earlier | 600 (default) | 0x8000 | 44 | 42 inode | hung at the bound |
| controlled | 1800 | 0x8000 | 549 | 422 inode, 422 data | `interrupt_resume` fails |
| verbose | 1800 | 0x8001 | 2 | 0 | reads converged |

**The earlier 42-inode reading was truncated, not the defect's size.** Phase 4's
two writes are 307.1 s and 360.6 s and the run is 667.7 s of work, so under the
600 s default the run is cut mid-phase and the shortfall it reads is whatever
the interrupted pass had reached, not what the pass loses when it runs to its
stop. At the 1800 s the testing row already says phase 4 is given, the same
workload loses 422 inodes: master `40042 inode, 40103 data`, slave `39620
inode, 39681 data`, 10 chains scrapped unwritten, 844 lines differ of 120179.
Two runs this session used the default and hung, and both readings of 42 and 82
come from that truncation.

**A verbose run reads as convergence and is not.** At `H2_DEBUG=0x8001` the
carried per-chain prints run for every insert, replace and destroy, which slows
the pass until the stop lands after 2 inode updates and the slave converges to
0 lines differ. That is the near-miss the phase exists to avoid reading as
success: the window it interrupts is the pass's length, and the prints stretch
that length past the stop's arrival, so the interruption has almost nothing to
lose. The convergence is an artifact of the instrument, not the port. It is
recorded here so the run is not cited as `interrupt_resume` met. It also means
the destroy lead the 2026-10-11 entry carries is NOT tested by it: 2 copies
before the stop is not a pass that reaches the shortfall.

**The thread-left reading is resolved: the unmount does not delete a thread,
and the check asserted an invariant the port does not have.** Both non-truncated
runs read `threads 1 to 1` across `umount /mnt/h2c`, the unmount returning in
4.3 s and the guest's post-unmount wait then exhausting its 20 s with the thread
still named. The 2026-10-13 probe read `2 to 1` for this unmount, but the record
itself notes that probe ran a topology the script does not, so its two threads
are not the script's one.

The source settles it, and no run was needed to see it: `hammer2_thr_delete()`
has exactly two callers in `src/`, `hammer2_pfsdealloc()` from the pfs-delete
ioctl and `hammer2_pfsfree()` from `pfsfree_scan()`. A plain `umount` reaches
neither. `hammer2_unmount_helper()` clears `pmp->mp` and decrements the device's
`mount_count`, which is the unmount's work; it does not deallocate the pmp. The
phase keeps the pmp's other mount, `/mnt/h2s`, up through the interruption, so
the CL pmp is alive and its thread is correct to keep running. This matches the
carried code, so it is not a port defect. The check that read the thread's
absence was asserting a stop the unmount is not supposed to perform.

Three readings of that check were wrong in turn this session: assert zero
(unmet), assert a drop from two (the run read `1 to 1`, and that was read as a
refutation when the assertion it carried would have held), and then the
teardown-path hunt for a defect that is not there. The lesson is the record's
own: the reading moved with the reasoning, and the reasoning was settled by
reading the two callers, which cost nothing and should have come first.

The check asserts the measured behavior now: the thread exists through the
interruption and the resume brings passes back. The raw fields behind the
verdict (`interrupt-threads`, `interrupt-stop-tenths`) are printed by the host,
since it parsed them and printed only the check's one-number message before, and
the guest's output file is removed at exit.

What the runs settle: the shortfall reproduces at 422 inodes under the timeout
phase 4 requires, the 42-inode figure was a truncation artifact, and a verbose
run cannot be read as convergence. What they do not settle: the destroy lead,
which needs a run that both carries the per-chain prints and reaches the
shortfall. The `1 left` thread reading is not open: it is the two-element pmp
keeping the second element's thread, which the 2026-10-13 probe measured, and
the phase's check asserts an invariant that topology does not support.

## The shortfall is intermittent at a fixed config, and the destroy arm fires in a converged run, 2026-10-14

A fourth phase-4 run, at the same `H2_DEBUG=0x8000` and `H2_RUN_TIMEOUT=1800`
as the 422-inode run, converged: slave `40042 inode, 40103 data` equal to the
master, 0 lines differ of 120179, 0 chains scrapped. Its raw line, which the
host now prints:

    raw phase4 bracket=0 begun=0 copied=88 umount-ms=4285 threads-left=1
        stop-tenths=200 didbreak=0 actions=148 resume-rc=0 resume-passes=2

Three readings follow, and one is a defect in the capture itself.

**The shortfall is intermittent at one configuration.** Two runs at
`0x8000`/1800 differed: one lost 422 inodes with `copied=549`, this one
converged with `copied=88`. So the shortfall is not a function of the config
alone; it depends on where in the pass the stop lands, which the phase cannot
yet place. The record already had this open ("two runs of identical source
completed and stalled respectively", 2026-10-13); this is a second instance of
it, now with both runs' copy counts beside their outcomes.

**A destroy count does not by itself cause the shortfall.** The live kernel log
of this converged run reads `filekeys n<0 83` while its slave converged: the
destroy arm was taken 83 times and the run still matched. The 2026-10-11 entry
found a run where the destroyed keys were exactly the missing ones, which is a
strong correlation on that run, but a destroy count of 83 in a run that
converged means the count is not sufficient. Whether the 2026-10-11 run's
destroy was the cause or another symptom of the same race is open.

**The stop's wait is exhausted, not read early.** `stop-tenths=200` is the
guest's 20 s wait running to its bound with the CL thread still named, and
`umount /mnt/h2c` itself returned in 4285 ms. So this is not a check sampling
before the pmp's teardown completes: the unmount returns and the thread is
still there twenty seconds later. It separates by the pmp's element count, as
the earlier entry says; here the wait is shown to be exhausted rather than
short.

**The capture was wrong and is fixed.** `actions=148` was the count of
`filekeys` lines, not the `acted` field, because `klog()` is `grep -c`. The
field is taken with a plain `grep | tail -1` now. The counters themselves are
sound: read live from the kernel log, this run's `acted` climbed past 7667 with
`failed 0`. The failed-copy hypothesis stays refuted across four runs.

What the four runs settle so far: no copy returns an error (`failed 0`, four
runs); the destroy arm fires in runs that converge and runs that do not; the
shortfall is intermittent at a fixed config and tracks where the stop lands;
and the CL pmp's thread outlives its unmount by at least twenty seconds while
the lone pmp's does not. The instrument that places the stop, or that reads the
destroy's keys against the shortfall's keys in one run, is what is missing.

## The thread check is corrected and the run is clean, 2026-10-14

The check asserts the measured behavior, and the run that verifies it is the
before-and-after a fix needs:

    FAIL  the stop reaches the CL pmp and leaves no thread: 1 left after umount /mnt/h2c   (before)
    ok    the CL pmp's thread survives the unmount and the resume passes: threads 1 to 1    (after)
    cluster: 31 check(s), 0 failed

`threads 1 to 1` is the reading the source predicts: `hammer2_thr_delete()` is
reached by pfs-delete and the device teardown, not by `umount`, so a plain
unmount of one of the CL pmp's mounts leaves its thread running and the pass
completes at the boundary the carried code honors. The run also converged
(slave `40042 inode, 40103 data` equal to the master, 0 lines differ of
120179), and the raw line's `copied=4` says why this run does not test the
shortfall: the stop landed after four copies, so there was almost nothing to
lose. The intermittent shortfall needs a run where the stop lands deep in the
pass, which the same raw line's `copied` field now reports and this run's own
`copied=549` run showed is not the same every time.

So the thread reading is closed and the shortfall reading stays open, and the
two are separable by the `copied` field the host prints.

## Copy depth is not the lever, and the destroy count tracks the shortfall, 2026-10-14

A run of phase 4 that copied almost nothing lost inodes, which refutes the
depth theory and puts the destroy arm back at the center:

    raw phase4 copied=2 stop-depth=0 wanted 400 ... actions=filekeys n<0 40
        n==0 5 n>0 57 acted 1695 failed 0
    FAIL  the slave holds what the master holds: master (40042 inode, ...),
          slave (40002 inode, ...)
    FAIL  the slave's PFS matches the master's ... 80 lines differ of 120179

**Copy depth is refuted.** The five earlier runs read copied=4, 44, 88, 488,
549 and only the deep one lost inodes, which made depth the candidate. This run
stopped at copied=2 -- the shallowest of all -- and lost 40 inodes. So the depth
the pass reached is not what decides the shortfall; the deep run's loss and the
shallow runs' convergence were coincidence, and the depth knob built for it
controls nothing about the outcome. The knob and its check stay: they report
where the stop landed, which is a reading, and the check caught a shallow run
that would otherwise have passed as a depth test.

**The destroy count tracks the shortfall.** This run reads `n<0 40` and the
slave is short by exactly 40 (40042 - 40002). The destroy-keys run read `n<0 41`
and converged. So the count of `hammer2_sync_destroy()` firings is not fixed and
not by itself a loss: 41 destroys with no loss, 40 destroys with 40 lost. That
is the shape of a race in the compare the destroy arm is taken on -- `n < 0`
means the master's scan did not return a chain the slave holds -- and whether
the keys destroyed this run are the keys missing is the comparison the next run
makes, which the previous run could not because its kernel log was discarded.

**The harness discarded that evidence, and did it for every completed run.** The
guest's kernel log is copied off only when the run hangs (`rc=124`); a run that
finished with the slave short exited and `detach_disks` released the guest with
its `filekeys`, destroy keys and update lines still on it. The log is copied
before the disks are released now, on the normal path, so a short-slave run
keeps what it produced. This is the same defect the session has been fixing in
its checks -- a run that throws away the reading it exists to collect -- in the
harness's own teardown.

What the runs settle: copy depth does not decide the shortfall; the destroy arm
fires 40 to 41 times in both a losing and a converging run; no copy returns an
error. What the next run adds: the destroyed keys against the missing keys, from
one run, now that its kernel log survives it.

## The destroyed keys are exactly the missing keys, confirmed from the media, 2026-10-14

The run kept its kernel log and the comparison the previous entry could not
make is made, from the run's own destroy keys against the images' fingerprints:

    destroy rec ... 1.0000000000000a24      <- first
    ...
    destroy rec ... 1.0000000000000a65      <- last, 66 keys in one 3 ms burst
    filekeys n<0 66 ...
    slave (39976 inode, 40037 data) against master (40042 inode, 40103 data)

    missing inode keys (on the master, absent on the slave), read from the
    two saved images with hammer2 -v show:
    0x0a24 0x0a25 ... 0x0a64 0x0a65         <- the same 66 keys

Sixty-six destroyed, sixty-six missing, and the keys are the same set, read
independently: the destroy log from the kernel, the fingerprints from the
media. This is the defect the 2026-10-11 entry named, reproduced with both
sides' keys, which that entry could not do because no run had kept them
together.

The mechanism the keys point at: `hammer2_sync_destroy()` is taken on the
`n < 0` arm, which fires when the master's XOP scan returns a focus the slave's
chain compares below, meaning the scan did not return a chain the slave holds.
The master's media holds all 66, so at that moment the master's scan did not
see inodes its own media now has. The destroy is not spurious on its own terms:
given a scan that omitted those keys, removing the slave's copies of them is
what the compare instructs. The defect is upstream of the destroy, in a scan
that omits keys the master holds -- and the 2026-10-12 entry "the destroy guard
keeps the frontend's chains" is the guard that was added for exactly this, so
whether it is still in the tree and still covers this path is the next thing to
read, from the source rather than a run.

What is now settled, by keys: the destroy arm removes exactly the inodes that
go missing, so the loss is the destroy, and the destroy follows from a master
scan that did not return those keys. What is open: why the scan omits them, and
whether the guard reaches this path.

## The shortfall's cause, end to end: the destroy arm, and the guard that fixed it was reverted for a fixable reason, 2026-10-14

The chain is complete and every link is a measurement or a commit. **This entry
is superseded in full by "The destroy is not the cause, and the shortfall tracks
the pass's own progress" below, which refutes links 1 and 2.** Kept rather than
deleted, because the key-identity reading in it is sound and it is what the
refutation was measured against.

1. The interrupted pass destroys slave chains on the `n < 0` arm of the action
   switch, `hammer2_sync_destroy()`, which the record's 2026-10-11 entry reached
   from the per-chain prints and this session confirmed by keys: 66 destroyed,
   and the same 66 keys on the master and absent from the slave.
2. `n < 0` means the master's XOP scan did not return a chain the slave holds,
   though the master's own media holds it. The destroy is what the compare
   instructs; the defect is upstream, in a scan that omits keys the master
   holds. **This reads the arm as one condition and it is two.** See "The
   key-losing destroy has two arms" below: the compare arm is not the arm that
   lost these keys.
3. A guard was written for exactly this: `a2804b9`, 2026-10-12, "A sync pass
   keeps a slave chain newer than the state it copies",
   `if (n < 0 && chain->bref.modify_tid > sync_tid)` keep it and leave the inode
   unstamped. Its own reading: destroys inside the write 82 to 0, the slave's
   inode, data and dirent equal to the master's, 0 lines differing.
4. The guard was reverted: `36d664b`, 2026-10-13, "The slave-newer branch
   livelocked the pass and is reverted". The reason is mechanical and specific:
   it set `advance_local = 1` and not `advance_xop`, where every other arm of
   the same switch advances both, so the master's scan stayed on the same focus
   and the next iteration compared the same pair -- 180 keys repeated 69 times
   against 1001 distinct without it.

So the loss is the destroy, the guard that stops the destroy worked, and it was
reverted for one line: it advanced one side of the scan and not the other. The
next change has a shape and two readings already measured -- the 2026-10-12
guard's (destroys 82 to 0, the slave converged) and the revert's livelock
(180 keys repeated 69 times against 1001 distinct) -- so a corrected guard is
tested against both rather than a new number.

**It is not written, and the reason is the one piece not yet settled.** Keeping
the newer slave chain and advancing both sides is the obvious correction, but
the revert's own stated cause does not survive reading the code, so the livelock
is not yet explained well enough to fix blind. `36d664b` says the guard "advanced
the local scan alone" and the master's scan "stayed on the same focus"; but
`hammer2_chain_next()` computes `key_beg = chain->bref.key + (1 <<
chain->bref.keybits)`, so the local scan does move past a kept chain by key.
Either the reverted arm's `advance_local` did not reach `chain_next` on the path
the log shows, or the XOP cursor re-offers a focus the local scan has passed,
and which it is decides the fix: if the local scan skips the kept chain, the
change is the neighbor arm's shape; if the XOP re-offers it, the guard needs the
per-key record the deferral list was built to carry. Both readings are in the
2026-10-13 log (`cluster-hang-20261013-203945.klog`, 180 keys repeated 69 times,
an EAGAIN every pass), and neither has been read against `chain_next`'s key
arithmetic. Writing the guard here would be a seventh mechanism stacked on the
six the record already refuted in this arm, so it is left as the next piece of
reading rather than a guess.

## The key-losing destroy has two arms, and the compare arm is not the one that lost the keys, 2026-10-14

The entry above reads `n < 0` as a single condition: the compare found the local
chain left of the master's focus. It is two conditions reached by two paths, and
the losing run separates them.

The run that lost the 66 keys is `cluster-run-20261014-171347.klog`, 65649
lines, and the destroy burst and the pass counters are adjacent in it:

    [ 3016.495968] START_SCAN IP=b6a9cb23fd8a8001 chain=00000000241acf7e (0000000000000400)
    [ 3016.541646] destroy rec ... slave 1 1.0000000000000a24     <- first
    [ 3016.544901] destroy rec ... slave 1 1.0000000000000a65     <- last, 66 keys in 3 ms
    [ 3016.545184] filekeys n<0 66  n==0 5  n>0 57  acted 1878 failed 0 last 0

Every pass before it reads `n<0 0` (the eight `filekeys` lines at 2924.190161,
2924.195162, 2924.204322, 2924.206185, 2995.969598 and their siblings), and in
the losing pass `n>0` is flat at 57 and `n==0` moves only 3 to 5. Sixty-six keys
sorted before the focus with no compare between them is not the shape a compare
produces; it is one sweep of a scan that has ended.

That sweep is the arm at the top of the compare, `chain && merror ==
HAMMER2_ERROR_ENOENT`, which sets `n = -1` for every key still local without
comparing anything. It fires whenever the XOP scan ends while the local scan has
not, and this run cannot say why the scan ended where it did:

- A normal end is consistent with the burst. If the scan stopped at a key the
  master's media holds, the sweep deletes the 66 the master has and the slave
  does not, which is the measured image diff.
- An early end is also consistent. `hammer2_xop_scanall()` (`hammer2_xops.c:871`)
  prints `NULL parent` and feeds NULL with `error` still 0 when
  `hammer2_inode_chain()` cannot resolve its element, and
  `hammer2_xop_collect()` reads the all-NULL cluster as ENOENT exactly as it
  reads a completed scan. **This path is a candidate and not a reading.** The
  losing log carries no `NULL parent` line from the scanall path at all, and the
  364 `NULL parent` lines in it are `sync_setflush`'s own message, "stopped at
  0000000000000000/0 type 255 (NULL parent)". The scanall print is
  `pr_info_ratelimited` (`hammer2_os.h:114`), so its absence is weak evidence
  rather than a refutation, and no run so far has distinguished the two.

What is settled is the arm, not the reason the scan ends: the destroyed keys are
taken by the end-of-scan sweep, not by the compare, and the sweep does not look
at what it deletes.

Consequence for the fix: the guard that worked (`a2804b9`) tested
`chain->bref.modify_tid > sync_tid` at the top of the `n < 0` arm, which covers
both paths into it, but the record's attribution of the loss to the compare arm
named the wrong path. The counters added here (`newer`, `sweep` in the `filekeys`
line) count each path separately, so the next run says which one fired rather
than leaving it inferred from the burst. Whether the guard is the right fix is a
separate question this run does not answer: keeping a newer chain leaves it
uncopied and the element unstamped on the sweep path too, which is a retry
rather than a convergence, and a scan that ends early needs the scan repaired
rather than the delete guarded.


## Summary of the P4 synchronization attempts, 2026-10-14

Second edition. Each entry is a change that was made to the cluster
synchronization path, measured, and reverted or reduced, or a mechanism that was
proposed and then refuted by a reading. Recorded together so none is tried
again. The list above is the 2026-10-13 edition and is superseded by this one.

### Changes reverted

1. **The slave-newer guard, as written at `a2804b9`.** Kept a chain whose
   `bref.modify_tid` exceeded the pass's `sync_tid`, set `advance_local = 1`, and
   returned without destroying. `a2804b9`'s reading: destroys inside the write
   82 to 0, the slave converged. Later the same day the record blamed it for a
   livelock; see items 2 and 3.
2. **The same guard with the advance line dropped** (committed `ccb7b1c`).
   Re-enterable on the end-of-scan path, which sets `n = -1` on every iteration,
   so skipping the destroy with no advance re-enters the same arm on the same
   chain forever. Measured 2026-10-14: the pass hung, `kworker/5:1 blocked 122 s`
   in `hammer2_chain_lock` under `hammer2_inode_chain_flush`, the unmount busy
   until the guest restarted. The advance line is load-bearing; its absence is
   the difference between a hang and a stall.
3. **The slave-side error rollup** (`a591c19`, tried, reverted). Rolls a slave
   error up to abort the pass; the next pass retries the same early keys. Also
   the better candidate for the 2026-10-13 180-keys-69-times count, which was
   attributed to item 1 alone without isolating the two.
4. **The deferral of the `n < 0` arm.** Deferring the destroyed directory and
   returning EINPROGRESS leaves the local scan past the focus with `n > 0` on
   the next entry, which then *recreates* it. Reverted.
5. **Radix cap on the computed keybits.** Fires, removes the refusals and the
   per-key rebuilds, and narrows the tree until no file key is presented: 0 of
   1001 against 4001 of 8080. Reverted.

### Mechanisms refuted, do not propose again

6. **Masked failed copies.** `nerror` is discarded by upstream and by this port.
   The counters show `failed 0` across every run of both days, so no copy in
   these passes returned an error. The rollup was built for this and is not
   needed.
7. **Copy depth as the lever.** The shortfall does not follow the depth knob:
   runs at `copied` 2, 28, 44 and 87 converge or not independently of it, and
   two runs that both read `stop-depth=0 wanted 0` land on opposite sides.
8. **The compare arm as the arm that loses the keys.** The keys are not lost by
   the compare's destroy. A run that destroyed 81 keys converged with 0 lines
   differing, against the 66-key run that lost 132; destroyed keys are recreated
   by the same pass, so the earlier key match was a subset, not an equality.
9. **The end-of-scan sweep as the arm that loses the keys.** The `sweep` counter
   has run three times and read 0 every time. **It has still never been read on
   a run that failed**, so the arm is untested rather than refuted; do not
   record it as either.
10. **The `xop->collect_key` re-seed** as the sweep-path fix. The scan's position
    is `xop->key_beg` (`hammer2_synchro.c:669`), not `collect_key`, which only
    tells the collector which FIFO entries are behind.

### Test-harness defects, which read as subject failures

11. **The 600 s default run timeout** truncating a phase whose writes take
    307 s + 360 s, which produced a bogus "42 inode" shortfall. Use
    `H2_RUN_TIMEOUT=1800`.
12. **A verbose guest log slowing the pass**, which made a losing run read as
    converged. The failure is reproducible only at the quiet settings.
13. **Waiting for two resume passes and unmounting.** A pass whose local scan is
    empty handles one inode, and the failing run's log shows 58 such passes in
    70 ms walking 0x438 to 0x400. Two passes drains two inodes of a backlog of
    hundreds, so the check measured a race. Replaced by a wait for the
    update-inode count to stop advancing.
14. **`H2_STOP_DEPTH` cannot place the stop at a shallow depth.** It polls the
    `acted` field of the pass's `filekeys` line, which prints only at the end of
    a pass, so it does not advance during the pass it is trying to interrupt. A
    request for depth 4 measured 0.

### What still holds

15. The slave holds all 4801 dirents and 801 of the 4801 inodes; the 4000 files
    that predate the element are the ones missing. Every change above moves a
    counter that is not that number. This has not changed through both days.
16. The failing pass runs two loop turns and leaves through the loop-head break
    for both scans done (`iters 2 exit 1`), not an error and not the deferral
    threshold. It inserts one key, stamps the inode, and returns.

## The next measurement on `interrupt_resume`, and what each outcome decides, 2026-10-14

Written as a decision procedure so the step after this one is read off a result
rather than chosen. The subject is the two-turn pass: one key inserted, the
inode stamped, both scans reported done.

Instrument, one run: count, per pass, how many chains the XOP scan offered
against how many the local scan held. Two counters and one print, no theory. The
counters go beside `iters`/`exit` on the `filekeys` line.

- **XOP offers many, local holds one, loop leaves after two turns.** The two
  cursors are not being compared: the pass is taking the loop-head break while
  the XOP still has chains, which means `merror` read ENOENT with a focus still
  pending. That is the end-of-scan arm, and item 9 of the list above is what to
  read it with.
- **XOP offers one, local holds one, and the pass returns.** The element
  genuinely holds one key and the master's scan agrees on it. Then the pass is
  correct and the defect is *upstream of it*: whatever decides the element has
  only one key to offer. That is the 4000-file reading (item 15) and the next
  subject is the element's own construction, not the scan.
- **XOP offers one and the local scan holds many.** The scan is not walking the
  local tree; the defect is in `hammer2_chain_lookup`/`chain_next` on this
  element, and item 5's radix narrowing is the first thing to re-read.

Stop condition: the run converges with the thread settled and 0 lines
differing. That closes `interrupt_resume`; no further mechanism is needed,
because the criterion is final-state convergence, not an explanation.

Do not run the deep-stop knob to reach the failure. Item 14: it cannot place a
shallow stop. The failure is reached by the default (stop at the first open
bracket) repeated, which is why it is intermittent.

## The stamp is the defect, proven from the failing run's own pass accounting, 2026-10-14

The 2026-10-13 entry above reached this from totals and it is confirmed here from
the failing run's own log, `cluster-run-20261014-171347.klog`, by a discriminator
inside the source rather than a count.

`sync_slaves pfs CL` prints at `hammer2_synchro.c:337`, before the `want_update`
test. `START_SCAN` prints at `:703`, after the early return at `:672`. A pass that
returns at `want_update == 0` therefore shows the first line and not the second,
and the two counts separate "passing" from "scanning" with no arithmetic.

In the failing run, after its last destroy at line 1906:

    sync_slaves pfs CL      116 passes, t=3022.59 to the end, one every 5.12 s
    START_SCAN                0

One hundred and sixteen passes, none of which entered the scan. The thread is
awake and running; it looks at the element root, reads its `modify_tid` equal to
the pass's `sync_tid`, and returns. The slave's media is missing 66 keys, and no
pass will ever look at them again.

That is the mechanism, and it is the one the 2026-10-13 entry states:

> A stamp set before the flush proves the copy reached media is what converts a
> write-back failure into a permanent absence, and it is why the loss is total
> rather than partially repaired.

So the interrupt is not the defect and neither is the destroy. The passes before
the interruption stamped the root synchronized; the interrupted pass then
destroyed keys without completing its scan; the stamp it left and the stamps
before it mean the state it left is called synchronized, and the resume has
nothing to do. The shortfall is the gap between what the stamp asserts and what
the media holds.

Two consequences for the fix, both narrower than the guard that was tried:

1. The stamp must not be set for a pass that did not complete, which is what the
   existing `needrescan`/`EAGAIN` path at the end of the function already exists
   to express: that path suppresses the stamp, and the interrupted pass did not
   take it.
2. The destroyed keys need re-examining against the master rather than being
   assumed gone, because the destroy ran inside a pass whose scan had not
   finished, on a compare against a partial view.

The counters proposed in the decision procedure above are not needed for this.
The discriminator was already in the source and in the log.

## The convergence-wait run is green, and the fix the stamp needs, 2026-10-14

The run that waited for the resumed thread to stop advancing, rather than
unmounting after two passes:

    raw phase4 copied=47 umount-ms=4180 ... n<0 44 ... iters 2615 exit 1
        resume-passes=2 resume-updates=0 resume-settled=10 resume-conv-s=10
    ok the slave's PFS matches the master's entry for entry and block for block:
       40035 file entries; 0 lines differ of 120179
    cluster: 32 check(s), 0 failed

The resumed thread made zero update-inode calls and settled after ten seconds,
and the slave matches the master. That is the correct result for this run: the
interruption was shallow in action count (copied 47) but the root's stamp was
true, so there was nothing for the resume to find, and doing nothing converged.

It is not evidence the resume works, because it never had work to do. The run
that did have work -- the failing one -- had 116 passes that never entered the
scan. So the two runs read together say the resume is faithful to the stamp, and
the stamp is what lies when a pass is interrupted before it finishes the tree.

The fix is therefore in the stamp, and the pass already has the shape for it.
`needrescan` sets `HAMMER2_ERROR_EAGAIN` at the end of `hammer2_sync_slaves()`
and that path returns before the stamp is set, so a pass that did not finish does
not claim to have. The interrupted pass reached the end of its loop with no
deferral and took the stamp. What the interrupted pass has, and the ordinary
pass does not, is the destroy: it removed 66 chains on a compare against a scan
it had not finished. So the condition to add is narrow -- a pass that destroyed
chains and whose scan did not reach the master's end must not stamp -- and it is
provable by the same discriminator used above, since a pass that does not stamp
prints `START_SCAN` on its next invocation and one that does does not.

This is not written. It is the next change, and its before-and-after is the
count of `START_SCAN` after the interruption: 0 before, more than 0 after, on a
run that reaches the failure.

## The sweep counter cannot see the sweep, and both runs' destroys are the newer arm, 2026-10-14

The stamp fix was written against a reading that does not survive its own probe,
and this entry records the refutation before the fix is reconsidered.

The `sweep` counter is incremented in the `n < 0` arm when `merror ==
HAMMER2_ERROR_ENOENT`. The end-of-scan path sets `n = -1` **without** setting
`merror`, so that condition is false on the very path the counter was added to
count, and no value of the counter can distinguish the compare from the sweep.
`sweep 0` on a run means the counter's condition never held, which is its normal
state, not that the sweep did not run. The counter is withdrawn.

What the two runs' full accounting actually shows, and it is the same in both:

| field | failing run | stamp-fix run (converged) |
| --- | --- | --- |
| destroy burst | 66 keys in 3 ms | 46 keys in ~2 ms, same shape |
| `n<0` | 66 | 46 |
| `newer` | 66 | 46 |
| `sweep` (withdrawn) | 66 | 46 |
| `per-pass swept` | - | 111 passes all 0 |
| lines differing | 132 | 0 |

`n<0` equals the destroy count and equals `newer` in both, and no pass swept. So
both runs destroyed through the **newer** arm --
`chain->bref.modify_tid > sync_tid` on the compare -- which is the condition
`a2804b9` guarded. The failing run's `n<0 66` is 66 compare destroys, not a
sweep, and the entry that read it as a sweep is refuted here.

That also means the burst shape ("no compare between the destroys") was never
evidence of the sweep arm: the compare arm destroys a run of consecutive keys
with nothing printed between them when the master's scan offers no focus for
them, which is the same appearance.

Consequences:

1. The stamp fix as committed fires on `swept`, a local that counts a path that
   does not occur. On both runs it is dead code, and the run that "passed" with
   it did nothing different. It must be reverted or reconditioned on `newer`.
2. The two runs converge and do not converge with the **same** destroy path and
   the same stamp. So the destroy path is not what separates them, and neither is
   the stamp on its own: the failing run's 116 passes without a scan need a cause
   the two runs share but that only stops the passing run from scanning. That
   cause is not yet read.

## The newer arm keeps its key and the shallow interruption converges, 2026-10-14

The fix at `de483a9` was run and it fired, which is the before-and-after the
earlier entries lacked.

| | before the fix | with the fix |
| --- | --- | --- |
| `newer` arm on the compare | 46 and 66 chains destroyed | 56 chains kept |
| `destroy rec` in the run | 46 and 66 | 2 |
| `copied` at the interruption | 2 (the failing run) | 5 |
| slave against master | 132 lines differ | 0 lines differ of 120179 |
| checks | - | 32, 0 failed |

The run's log, `cluster-run-20261014-215937.klog`, reads `kept 56` and two
destroys, and its phase-4 line reads `copied=5 ... resume-updates=0
resume-settled=10`. That last pair is the point: it converged with the resumed
thread doing nothing, because there was nothing left to do.

It is the condition that failed before. The failing run was `copied=2` and lost
132; this one is `copied=5` and lost none, with the arm that destroyed 46 to 66
keys in every earlier run now keeping them instead. The interruption is as early
and the outcome is the opposite, which is the control the earlier runs did not
have.

Two counters are left in a state the run explains:

- `h2dbg_newer_kept`, printed as `kept`, is the count of chains the arm kept. It
  was named `destroy_newer` when the arm still destroyed, and the name would now
  read as its opposite.
- `h2dbg_destroy_dead`, printed as `dead`, is incremented in the `n < 0` arm when
  `merror == HAMMER2_ERROR_ENOENT`. The end-of-scan path sets `n = -1` without
  setting `merror`, so the condition is unreachable and the field is dead. It is
  kept as a labeled dead counter rather than removed so a later run does not
  re-add it as live; it reads 0 in every run and says nothing.

What is not yet done: a second run, because the failure was intermittent at a
fixed configuration and one converged run from the same path is a reading and not
a rate. The next run is the same command; the two together are the rate.

## The fix is partial: two dirents are still lost at the shallowest interruption, 2026-10-14

The second run of the same command, `cluster-run-20261014-221402.klog`, reached
the failing depth and did not converge:

    raw phase4 copied=2 ... kept 53 ... resume-updates=0 resume-settled=10
    FAIL the slave holds what the master holds: master (... 40038 dirent),
         slave (... 40036 dirent)
    FAIL the slave's PFS matches the master's entry for entry and block for
         block: 40035 file entries; 2 lines differ of 120179

The three runs together, which is the rate the single reading could not give:

| run | `copied` | kept | destroys | slave against master |
| --- | --- | --- | --- | --- |
| before the fix (`...171347`) | 2 | - | 66 | 132 lines differ |
| with the fix (`...215937`) | 5 | 56 | 2 | 0 lines differ |
| with the fix (`...221402`) | 2 | 53 | 2 | **2 dirents differ** |

So the fix takes the loss from 132 lines to 2 at the same `copied=2`, and 2 is
not 0. `interrupt_resume` is not met.

What the two lines are: the inode and data counts match the master's exactly
(40042 inode, 40103 data) and the dirent count is short by two (40036 against
40038). So the loss is now two directory entries and no inodes, where before it
was every kind at once.

The two destroys that remain are not the `newer` arm: `kept 53` accounts for the
newer chains and the dead counter reads 0, so these two went through the plain
compare arm with `modify_tid <= sync_tid` -- chains the compare read as leftovers
the master no longer holds, which the master does hold. The `newer` guard does not
cover them because the condition it tests is false for an old chain whose key the
master's scan did not present.

That is the next sub-case, and it is narrower than the last: an old chain, whose
key the master's scan did not offer, that the master still holds. Whether the scan
omits the key or the compare mis-associates it is the reading to take, and the
`kept`/`destroy rec` pair with the two keys is what it needs.

## The two keys that remain are the root's own subdirectory dirents, 2026-10-14

The two lines the partial run differs by are named, read from the saved images by
the fingerprint:

    < dirent "bigdir" 0x000000000000043e DIR
    < dirent "set"    0x0000000000000400 DIR

Both are present on the master and absent from the slave. They are the PFS
root's dirents for its two subdirectories, at the two lowest keys in the root's
space, and they are the only thing missing: the inode and data counts are equal
to the master's (40042 inode, 40103 data) and the two directories' inodes exist
on the slave. What is gone is the parent's naming entries for them.

That accounts for the two `destroy rec` the run recorded. The compare arm read
each as a leftover the master no longer holds -- `modify_tid <= sync_tid`, so the
newer guard does not cover it -- and destroyed it, and the master holds it.

Two things this narrows. The loss is not in the file keys, which is where every
earlier reading looked; it is the root's own child dirents, the first two keys a
root scan presents. And the two destroyed chains are the ones the deferral
mechanism exists for: a directory's dirent is deferred and recursed, so a pass
interrupted before its deferrals drain can destroy the very entries it was about
to defer. The next reading is whether these two were deferred and the pass left
before draining them, which the deferral count and the pass's exit reason
together decide.

## The two missing keys were never destroyed, which refutes the entry above, 2026-10-14

The entry above attributes the two missing root dirents to the run's two
`destroy rec` lines. That is wrong, and the run's own log refutes it.

The two destroys are at `slave 1 4.952c5ca9c9858001` and
`slave 1 4.b77f7af1cd8e8001`: type 4 (DIRENT), in the file-hash space at the top
of the 64-bit range. The two missing entries are at `0x0000000000000400` and
`0x000000000000043e`, the root's own inode-number space at the bottom. Different
keys, different space, and neither destroyed key appears in either image's
fingerprint, so they are chains that were created and removed within the pass
rather than the loss.

A search of the whole run for a destroy or a delete of either missing key returns
nothing. So the two root dirents were **never destroyed -- they were never
copied**. What the run does show for one of them is an insert that did happen:

    [ 6676.630773] sync_insert: focus 0000000000000400/0 into parent b6a9cb23fd8a8001/0 type 1

`0x400` was inserted into the root (`b6a9cb23fd8a8001`) at t=6676, near the start
of the run. The slave's image does not hold it at the end. So a chain that was
inserted is absent from the media the run leaves, which is the write-back
question and not the destroy question.

The pass that holds the two destroys also reads `acted 2006 failed 53 last 2048`,
and 2048 is `HAMMER2_ERROR_EINPROGRESS` (`hammer2.h:312`), the code this session's
own newer-arm guard returns when it keeps a chain and advances. So that run's
`failed` count is 53 of this port's keeps being reported as failures through the
same discarded `nerror` the file's own comment describes, and the `failed`
counter is not a count of slave-side errors when the guard is active.

Corrected reading of the partial result: the fix took the loss from 132 lines to
two root dirents, the two were never destroyed, at least one was inserted and did
not reach the slave's media, and the next instrument is the write-back of an
inserted chain rather than any arm of the compare.

## The destroyed dirents are the missing dirents, and the refutation was drawn from an instrument that cannot express it, 2026-10-14

The entry above retracts the causal link between the run's two destroys and its
two missing keys. That retraction is itself wrong, and the raw media says so.

    master: dirent.1  key 952c5ca9c9858001   filename "set"    inum 0x400
            dirent.2  key b77f7af1cd8e8001   filename "bigdir" inum 0x43e
    slave:  neither key present

Those are exactly the two keys the run destroyed:

    destroy rec ... slave 1 4.952c5ca9c9858001
    destroy rec ... slave 1 4.b77f7af1cd8e8001

So the original entry was right: the root's two dirents were destroyed by the
compare and they are the two the slave is missing. The root's dirents hash their
filenames into the top of the 64-bit space, which is why their keys look like
file keys and not like the `0x400`/`0x43e` inode keys of the same entries.

**The retraction's instrument could not have produced its answer.** The
fingerprint is built by the awk in `script/cluster-sync.sh` and prints dirents as
`dirent <name> <inum> <type>`: it carries the filename, the inum and the type,
and never the dirent's own key. A search of that file for `952c5ca9c9858001`
matches nothing on either side by construction, so "absent from both images"
was a fact about the fingerprint's columns and not about the media. The
conclusion drawn from it, that the destroyed chains were transient, is void.

That is the sharper lesson of the two entries: **a negative from an instrument is
only a reading if the instrument can express the positive.** The fingerprint
answers "what does this volume hold" in names and inums; it cannot answer "does
this volume hold key K", and it was used for the second question.

The mechanism, restored and now with keys: the slave held the root's dirents for
"set" and "bigdir" -- it had copied them, `sync_insert` for `0x400` and the
dirents' presence in the slave's tree before the destroying pass -- and the
compare read each as a key the master no longer holds and destroyed it, while the
master holds both. Their `modify_tid` is at or below the pass's `sync_tid`, so
the newer guard does not cover them, and this is the same class as the 66-key
loss with the guard's condition false: **the compare destroys a chain the master
holds because the master's own scan did not present its key.** The master's scan
omitting master-present keys is the mechanism, and it is in the scan, not the
destroy.

## The sweep counter was blind, and the sweep is the arm after all, 2026-10-14

Two entries above retract the end-of-scan sweep as the key-losing arm, both on
the strength of a counter reading 0. The counter could not read what it was named
for, and the geometry of the keys says the sweep is the arm.

The counter was incremented inside the `n < 0` arm on
`merror == HAMMER2_ERROR_ENOENT`. The sweep is the arm **above** that one:

    if (chain && merror == HAMMER2_ERROR_ENOENT) { n = -1; focus = NULL; }
    ...
    if (n < 0) { ... }

The sweep sets `n = -1` and enters the `n < 0` arm with `merror` still ENOENT, so
the test inside the arm is true -- but only because the sweep put it there. Every
entry into that arm from the sweep is counted, and the value is the sweep's count,
not a discriminator. A counter can only separate two paths if its test is true on
one and false on the other; this one was true on both whenever a sweep had
occurred, and 0 whenever none had. It is moved to the sweep itself, so it now
reads 0 only when the sweep does not run.

**The geometry is what settles the arm.** The two dirents the slave lost are the
root's entries for "set" and "bigdir", and a directory's dirent key is the hash
of the filename:

    dirent "set"    key 952c5ca9c9858001
    dirent "bigdir" key b77f7af1cd8e8001

Both are near the top of the 64-bit space, and a scan offers keys in ascending
order, so they are the **last** keys a scan presents. For the compare to have
destroyed them as `n < 0`, the master's focus would have to have been at a key
above them, and there is none: they are the top of the space. The only way the
arm runs on them with a `-1` is `n` forced to `-1` -- the sweep, which fires when
the local scan still holds chains and the XOP scan has ended. The compare cannot
produce it for the highest keys in the tree.

So the original reading was right and both retractions were wrong, and their
shared cause is one instrument: `sweep` reported 0 because it was placed where it
could not distinguish, and two entries treated its 0 as a finding about the
sweep rather than about the counter. Restored: the loss is the end-of-scan sweep
destroying chains the master holds, and the question is why the XOP scan ends
while the local scan still holds them -- which is the master-side scan omitting
master-present keys, as the entry above this one concludes from the same dirents.

## The cause is the master's scan, and the arm is not determined, 2026-10-14

Six entries above oscillate over which arm of the `n < 0` switch destroys the
keys. This one states what the evidence supports and stops there.

**What is proven, by the media:**

- The slave lost the root's dirents for "set" and "bigdir", keys
  `952c5ca9c9858001` and `b77f7af1cd8e8001`.
- The master holds both.
- The pass recorded two `destroy rec` in the slave's element at exactly those two
  keys (`slave 1 4.952c5ca9c9858001`, `slave 1 4.b77f7af1cd8e8001`), so the slave
  held them and the pass removed them.

So the pass destroyed slave chains whose keys the master holds. That is the
defect, it is the same defect the 66-key run showed, and it has been stated the
same way since `1e18971`: **the master-side scan does not present a key the
master's media holds, so the pass reads the slave's copy as a key the master no
longer has and deletes it.**

**What is not proven, and what this entry withdraws:** which arm deletes them.
Two entries ruled out the end-of-scan sweep by a counter, and the last entry
reinstated it by a geometry argument. Both are withdrawn:

- The counter was incremented inside the `n < 0` arm on `merror ==
  HAMMER2_ERROR_ENOENT`, where the sweep arrives with that merror set, so it
  measured the sweep's entries rather than separating it from the compare. It is
  now placed on the sweep itself, where it reads 0 -- but only on runs that
  converged, so it still does not say what a failing run does.
- The geometry argument claimed `bigdir` is at the top of the key space so no
  compare focus can sit above it. The master holds thousands of dirent keys above
  it (`b77facf89b878001`, `b78066b551358001`, ...). A compare focus above `bigdir`
  exists, so the compare can destroy it and the argument is void.

The arm is therefore undetermined. Both the compare and the sweep are consistent
with the evidence, and the counter that would separate them has not been read on
a failing run.

**What does not depend on the arm** is the cause: a master-present key missing
from the master's scan. That is where the next reading belongs, and it is
independent of which arm then acts on the absence -- the sweep acts on it when the
scan ends, the compare when the scan skips it, and both are the scan failing to
present a key it holds.

The record's own lesson from the day, now stated once: an instrument's reading is
only about its subject when its test is true on one path and false on the other,
and a geometry is only an argument after the population it assumes has been
counted. Both of this entry's retractions were the same error, made twice in
opposite directions.

## Reproduction attempted and not achieved, and a lockdep report that is not this port's, 2026-10-15

Six runs of the same command were made back to back to reach the failing
condition on purpose. All six converged, and the condition was not reached:

| attempt | `copied` | slave against master |
| --- | --- | --- |
| 1 | 5 | 0 lines differ |
| 2 | 4 | 0 lines differ |
| 3 | 4 | 0 lines differ |
| 4 | 4 | 0 lines differ |
| 5 | 5 | 0 lines differ |
| 6 | 3 | 0 lines differ |

Six runs at `copied` 3 to 5, none at 2. Every failing run of the two days was at
`copied=2`, and this harness, whose stop knob still did not place the unmount
(the raw lines read `stop-depth=0 wanted 0`), never produced that value. The
`copied=2` reading therefore remains a correlation across thirteen runs and is
not yet a controlled result: the failing condition has not been driven, only
observed when the race happened to land there.

**The sixth attempt's failure is not this port's defect.** It exited 1 on `no
kernel warning, lockdep, KASAN or UBSAN report: 1`, and the report is:

    BUG: MAX_STACK_TRACE_ENTRIES too low!
    turning off the locking correctness validator.
    Workqueue: writeback wb_workfn (flush-hammer2-104)
     dump_stack_lvl / save_trace / __lock_acquire
     bad_range / get_page_from_freelist / __alloc_frozen_pages_noprof
     hammer2_writepages

That is lockdep exhausting its per-lock stack-trace entry budget while recording
an allocation on the writeback path, not a hAMMER2 fault: no KASAN report, no
UBSAN report, and the same run's slave matched its master with 0 lines differing.
A debug kernel under memory pressure turns the validator off and says so; the
run's data was correct. The check that failed is the one that greps for `BUG:` in
the log, and it cannot tell this from a filesystem defect. It is recorded here so
the next session does not read `BUG:` in attempt 6's log as a hammer2 bug.

Two instruments are now known to be unable to place the interruption, and the
reproduction harness must not be trusted for its `copied` value: the stop knob
polls a field that does not move in the window, and the default depth 0 stops
wherever the race lands.

## A driven failing run settles the arm: it is the compare, and the destroys are the missing keys, 2026-10-15

A run failed with the counters live, and it answers the question six entries above
oscillated over. `cluster-run-20261015-014720.klog`:

    raw phase4 stop-copied=64 from 64 wanted 2 copied=6 ... acted 102842
        failed 126 last 2048 kept 126 sweep 0 iters 35012 exit 1
    FAIL the slave's PFS matches the master's entry for entry and block for
         block: 40035 file entries; 2 lines differ of 120179

The two differing keys, read from the images:

    < inode 0x00000000000012fe FILE 4096      (filename "p3775")
    < data  0x00000000000012fe

The run destroyed three chains:

    destroy rec ... slave 1 1.00000000000012fe
    destroy rec ... slave 1 4.952c5ca9c9858001
    destroy rec ... slave 1 4.b77f7af1cd8e8001

**The destroys are the missing keys.** `1.00000000000012fe` is type 1, the
inode, and it is the inode the slave no longer holds; the two dirents are the
"set" and "bigdir" entries that were lost in the earlier runs and that this run
re-copied. So the destroyed set and the lost set are the same chains, read by key
from both the log and the media, which is what the destroy detour of 2026-10-14
never established.

**The arm is the compare.** Three counters on this one failing run:

- `sweep 0` -- the end-of-scan arm did not run, so the sweep is ruled out on a
  failing run rather than on runs that passed.
- `kept 126` -- the newer arm fired 126 times and these three were not among them;
  the chains it kept are not the ones lost.
- `n<0 4`, three destroys -- the plain compare arm, `modify_tid <= sync_tid`.

So the compare read each of the three as a key the master's scan did not present,
destroyed the slave's copy, and the master's media holds all three. The defect is
the master-side scan omitting keys its own media holds, and it has been stated
that way since `1e18971`; what was missing was a failing run with the counters
on, which this is.

**Two earlier claims are refuted by the same run.**

- The `copied=2` threshold is not the rule. This run failed at `copied=6`, and
  `copied` 4, 4, 4, 5, 5, 3 in the six-run harness converged, so the separation
  is not a copy count.
- The stop knob still did not place the unmount: `stop-copied=64 from 64 wanted
  2`. The bracket wait let the pass copy 64 inodes before the wait began, past
  the target, and the wait broke on its own guard immediately. The failure came
  from the race again, not from the knob, so the reproduction is still not driven.

What the run does give is the arm, on a failure, by key. That is the durable
result of the day.

## The destroying arm's focus is non-NULL, so n < 0 means the scan jumped a key, 2026-10-15

A narrowing that holds whichever run confirms it, read from the code.

The action switch tests the sweep first:

    if (chain && merror == HAMMER2_ERROR_ENOENT) { n = -1; focus = NULL; }
    else if (chain == NULL) { n = 1; ... }
    else { focus = xop->head.cluster.focus; n = hammer2_chain_cmp(chain, focus); }

So the compare arm -- the one that fires when `sweep` reads 0 and `kept` does not
account for the destroyed keys, which is what a failing run shows -- is reached
only with `merror != HAMMER2_ERROR_ENOENT`. `merror` there is
`hammer2_xop_collect()`'s return, and `hammer2_cluster_check()` returns EIO rather
than leaving the cluster without a focus once its quorum agrees. On that arm,
therefore, **`focus` is non-NULL**, and `hammer2_chain_cmp(chain, focus)`
returning -1 means the master's focus key is **higher** than the local chain's
key. It does not mean the master lacks the key.

That is a third mechanism, distinct from the two the day tested: the sweep is the
scan *ending* at the local key, the newer guard is a chain *newer* than the
snapshot, and this is the scan **jumping over** a live key partway through and
presenting a higher one. The local chain's key was never offered.

The instrument is a print on the destroy, `destroy focus <key>/<type> local
<key>/<type>` (`285cc2f`), and it is a reading either way: a focus key above the
destroyed key confirms the jump, and a focus equal to or overlapping the local
key refutes this entry and puts the defect back on the compare itself. Both
outcomes are recorded here so the print is not read as confirming a theory.

## The sweep is confirmed, and the counters were read off the wrong line, 2026-10-15

The arm question is settled and the answer is the one this file first reached and
then retracted twice: **the end-of-scan sweep**.

Two readings, both from the same converged run, `cluster-run-20261015-030740.klog`:

    destroy focus 0000000000000000/-1 local 952c5ca9c9858001/4
    destroy focus 0000000000000000/-1 local b77f7af1cd8e8001/4

`focus` is NULL, and only the sweep arm sets `focus = NULL` with `n = -1`; the
compare always has a focus. So these destroys are the sweep's.

And the counter does fire -- read from **all** the pass lines rather than the
last one:

    filekeys n<0 4  n==0 3  n>0 57  acted 4105  failed 97  last 2048  kept 97  sweep 97  iters 3778  exit 1

`sweep 97` on the pass that destroys, against `61 sweep 0` on the idle passes that
follow it.

**How two entries came to retract the sweep, and it is a reading defect, not a code
defect.** The counter was incremented in the `n < 0` arm; the earlier reasoning
called that blind because the sweep enters that arm with `merror` already ENOENT.
That was wrong -- the counter is incremented on the sweep path itself, and it
reads 97 there. What went wrong is that every reading of it took `tail -1` of the
run's `filekeys` lines, which is the **last** pass of the run, an idle one, and
always 0. The value was on the line for the pass that destroyed, thousands of
lines earlier. This is the same defect as reading `acted` for the stop knob: the
instrument was sound and the line it was read from was not the line that carried
the answer.

So, settled:

- The arm is the **end-of-scan sweep**: the XOP scan reports done while the local
  scan still holds chains, `n = -1` is forced for each, and they are destroyed
  without a compare.
- `sweep 97` and `focus NULL` are the two independent confirmations, a counter and
  a print.
- The destroyed keys in a converged run are the same two root dirents a failing run
  loses. They are re-created in the converged run and not in the failing one, which
  is why one converges: the sweep's damage is repairable only if a later pass
  re-copies what it removed.
- The open question is unchanged and is the right one: **why the XOP scan reports
  done while the local scan still holds chains the master has.**

## The sweep fires in the converged run too, and the fix has to ask the master, 2026-10-15

Both runs sweep. Read from each run's pass line:

    converged  cluster-run-20261015-030740: kept 97  sweep 97  iters 3778
    failing    cluster-run-20261015-014720: kept 126 sweep 127 iters 3816

So the sweep is not the difference between converging and not. It fires in both,
and in the converged run the two root dirents it destroys are re-copied by a later
pass. The failing run destroys the same two plus the inode `0x12fe`, and that one
is not re-copied. The defect is the sweep; the intermittency is whether its damage
is repaired.

**A stamp fix cannot repair it, which rules out the shape tried earlier.** The
chains are destroyed at destroy time, so by the time the pass reaches the stamp the
keys are already gone from the slave. Suppressing the stamp changes only whether a
later pass rescans, and that pass finds the keys absent from the local scan as well
as the master, so the sweep does not fire and it stamps having converged on a tree
that is missing them. Not stamping is necessary but not sufficient, and on its own
it is not a fix.

**The fix has to decide, per swept chain, whether the master holds it.** At the
sweep the pass cannot tell a genuine leftover from a key the master holds, because
the authority on the master -- the XOP scan -- ended without presenting the key.
That is the whole of the defect: the pass destroys on the strength of an absence it
has no way to check.

The author it can check against is the master's own element, which is exactly what
`hammer2_xop_scanall()` reads and what is available here. So the design is a direct
lookup of each swept key on the master element before `hammer2_sync_destroy()`:

- master holds the key -> the scan's absence was wrong; keep the chain and advance,
  the same disposition the newer guard gives.
- master does not hold it -> a genuine leftover; destroy as now.

97 lookups in a pass is the cost, and it replaces an inference with a reading of the
authority itself. It is not written: it needs the master element's chain lock and
the same `HAMMER2_RESOLVE_*` flags the scan uses, and it should be written with the
before-and-after already in hand (the failing log's 116 scanless passes and the
converged run's swept-and-repaired dirents) rather than against a guess.

This supersedes the earlier `swept`-conditioned stamp, which is not re-added: it
cannot repair damage already done.

## The scanall fix removes the sweep and hangs the pass, 2026-10-15

The fix at `e5a6ca7` (`error = HAMMER2_ERROR_EIO` when
`hammer2_inode_chain()` cannot resolve the element) does what it says and the run
shows the cost.

Measured on `cluster-hang-20261015-040639.klog`:

- `hammer2: NULL parent` reads **0**. The hprintf the fix removed is gone, so the
  path it guards was taken at least once and no longer feeds a NULL at error 0.
- The pass does not sweep. Every `sync_slaves error` line reads 0 and the run
  reports no fingerprint at all: it hung past `H2_RUN_TIMEOUT=1800`.
- The 297 `NULL parent)` lines in the same log are `sync_setflush`'s own message,
  a different string from the `NULL parent` this fix removed. The harness printed
  them as the fix's counter and they measure nothing about it; the count is
  `grep -c 'NULL parent'`, which matches both.

So the sweep is gone and the pass spins instead. With `merror = EIO` the loop
leaves the sweep and re-enters at the `chain == NULL` insert arm every iteration,
inserting the key the element did not offer, and never reaches the loop-head break
because `merror` is neither 0 nor ENOENT. That is upstream's arm, reached by a
condition this port now creates; the same class as the 2026-10-13 livelock, and the
same reason it must not ship.

The lesson this run re-proves, twice in one harness: **an empty result is not a
pass.** Attempts 3 and 4 of the verification produced no `lines differ` line --
one hung, one was COULD-NOT-RUN on a guest the hung run left dirty -- and the
harness counted both as converged because its test was `! grep -q '0 lines
differ'` rather than `grep -q '0 lines differ'`. The fix is reverted; the next
change has to handle the unresolvable-element case without leaving the loop with a
live local scan and a non-ENOENT `merror`.

## Where the scanall fix hung, read from its stack, 2026-10-15

The hung run's own stack names the site, so the next change does not have to guess
it:

    h2nod-CL      state:D
     __schedule
     hammer2_inode_get+0x1cca
     hammer2_sync_slaves+0xafe
     hammer2_primary_sync_thread+0x24f

`hammer2_sync_slaves+0xafe` with `hammer2_inode_get` above it is the **deferral
push** -- the `hammer2_inode_get(pmp, &xop->head, -1, idx)` the pass runs to record
an inode for bottom-up synchronization. Two other tasks (`kworker/4:0`, `sh`)
blocked behind it, so the thread is not spinning in the insert arm as first
written here; it is blocked in the deferral push.

The deferral is guarded by `merror == 0`, so the pass that blocked was not the one
carrying the new EIO. What the change did was alter which passes reach that push
and how many, and the run then blocked there. The exact interaction is not read,
and this entry does not claim one: a hang in the deferral machinery reached by a
timing change is the third distinct way this pass has been made to hang, and the
next change has to be checked against all three -- no advance and it re-enters the
same arm, an advance with a stale XOP stalls, and the deferral push blocks.

State: the change is reverted (`3dec73b`), the tree carries only the newer-arm
keep, and the producer of the sweep -- `hammer2_xop_scanall()` reporting completion
for an element it could not resolve -- is proven and unfixed.

## The local scan has no element, and that is the producer, 2026-10-15

The per-iteration print found it on its first run, and it is neither of the two
mechanisms the day argued over. From `cluster-run-20261015-043115.klog`:

    sweepstate it 1 chain 0000000000000000/-1 localp 0000000000000000 masterp 00000000830f2c6b n 1 focus 0000000000000400/1
    sweepstate it 2 chain 0000000000000000/-1 localp 0000000000000000 masterp 00000000830f2c6b n 1 focus 0000000000000401/1
    ...

**`localp` is NULL on every turn.** `hammer2_inode_chain(ip, idx, ...)` at
`hammer2_synchro.c:691` returns NULL for the SLAVE's own element, so the local scan
is empty for the whole pass: `chain` is NULL every iteration, the loop takes its
`chain == NULL` insert arm on every key, and the master's focus walks 0x400, 0x401,
0x402 upward while the pass inserts against a NULL parent.

The line above it is the whole defect:

    parent = hammer2_inode_chain(ip, idx, RESOLVE_ALWAYS | RESOLVE_SHARED);
    hammer2_inode_unlock(ip);
    chain = hammer2_chain_lookup(&parent, &key_next, ...);   <- parent may be NULL

Upstream does not test for it. This is the same producer on the other side of the
scan: an element that cannot be resolved is read as an empty element, and the pass
then acts on a view with no local side at all -- here inserting every master key,
on the master side of the earlier finding destroying every local key. Both are the
same question asked of two different elements.

The guard added returns EINPROGRESS and leaves the element unsynchronized, which is
the disposition the function's own NULL-chain note already describes, rather than
acting on a view that has no local side. EINPROGRESS and not EAGAIN, so the pass
ends and the thread sleeps instead of re-entering on an element that stays
unresolved.

Run under it: `cluster-run-20261015-043115.klog` itself is the failing reading with
10 checks failed and 2 lines differing, so the probe has its before.

## The "local scan has no element" reading was my own print, 2026-10-15

The entry above reads `localp 0000000000000000` as the slave's element being
unresolvable. It is not. The print is:

    kprintf("... localp %p masterp %p ...", ..., chain, parent, ...);

so `localp` prints **`chain`** and `masterp` prints **`parent`**. On the insert arm
`chain` is NULL by definition and `n` is 1, and `masterp` -- the actual parent,
`hammer2_inode_chain()`'s result -- is **non-NULL** in both runs (`00000000830f2c6b`,
`000000002e5f6980`). The element resolves; the local *scan* is exhausted, which is
the ordinary state the insert arm exists for.

So the guard added at `becb470` is dead code: it tests `parent == NULL`, and
`parent` is never NULL on this path. It is reverted, and the print is corrected to
label its two fields for what they hold (`focus`, `local`) rather than for the
pointer that happened to be passed.

**This is the fifth reading defect of the two days and the second of the same
kind:** a print whose argument order did not match its label, read as a fact about
the subject. The others were `tail -1` on the wrong pass line for `sweep`, the same
for `acted`, a counter incremented where its test was always true, and a
fingerprint searched for a field it does not print. Every one was caught by
checking the instrument against its own definition, and every one had already been
written into the record as a finding.

What survives from the run: it converged (0 lines differing, 32 checks with 7
failed on the phase's own progress checks, not the fingerprint), so it is a green
run and says nothing about the failing case either way.

## The instrument, read correctly: the insert arm walks the master with no local chain, 2026-10-15

With the field labels corrected, the per-turn print reads the same in a converged
run and the state is not an artifact:

    sweepstate it 1  n 1  merror 00000000  focus 0000000000000400/1  local 0000000000000000/-1
    sweepstate it 2  n 1  merror 00000000  focus 0000000000000401/1  local 0000000000000000/-1
    sweepstate it 3  n 1  merror 00000000  focus 0000000000000402/1  local 0000000000000000/-1

`focus` prints with a key and a type, so the sweep arm did not run: `focus` is set
only by the compare, and the sweep NULLs it. `n 1` is the insert arm, `merror` is 0,
and `local` is 0/-1 because `chain` is NULL. The loop does not set `advance_local`
on that arm, so `chain` stays NULL and `local` stays 0/-1 for 708 turns while the
master's focus walks 0x400, 0x401, 0x402 upward.

So in this pass the local scan is exhausted from its first turn and `advance_xop`
carries the master alone: the loop inserts every focus key against a local scan
that has nothing left to give, up to the 1000-deferral cap. That is what the insert
arm is for and it is not by itself a defect. What it does establish is that a pass
can walk the master's whole key range with no local chain at all, which is the state
in which a wrong `merror` -- or a focus the local side cannot reach -- has no local
evidence to contradict it.

It also disposes of the entry two above: `focus` is non-NULL here, so `n < 0` with a
non-NULL focus exists on the compare arm as that entry predicted, and the sweep
(`focus` NULL) is a separate, later state. Both are reachable, and which one a
failing run takes is still unread because **four consecutive runs have converged**:
0 lines differing in all four, no failure to read the print on.

## The loss is the unmount scrapping unwritten copies, and the interruption is not involved, 2026-10-15

`interrupt_resume` has been attributed to the synchronization thread's sweep arm
for two days. The evidence says the direction is wrong, and it was already in the
harness output of every run.

**The counter that separates the two classes is `scrapped`, and it separates
perfectly.** `hammer2_unmount_scrap()` prints one `scrapping unflushed` line per
chain parked with `UPDATE` or `MODIFIED` after the final unmount sync
(`hammer2_vfsops.c:835`), and the harness has read it as
`nothing the thread copied is scrapped unwritten` on every run. Across the 40 runs
whose harness logs are on this machine:

    scrapped 0   38 runs   0 lines differ
    scrapped 7    1 run    2 lines differ   cluster-run-20261015-014720
    scrapped 8    1 run    2 lines differ   cluster-run-20261015-043115

No other reading separates them. `sweep` on the destroying pass runs 0 to 127,
`destroy rec` 0 to 6, `kept` 0 to 126, and every one of those ranges is spanned by
runs on both sides of the verdict. `scrapped` is not: it is zero on every
converged run and non-zero on both failing ones.

**The scrapped chains are the lost keys.** The failing run lost `1.00000000000012fe`
and two root dirents. Its scrap list in its own kernel log:

    scrapping unflushed data     0000000000000000/16  flags 00004243
    scrapping unflushed inode    00000000000012fe/0   flags 00006243
    scrapping unflushed indirect 0000000000001280/7   flags 00046102
    scrapping unflushed indirect 0000000000001000/12  flags 00046102

`0x6243 & HAMMER2_CHAIN_FLUSH_MASK` is `MODIFIED | UPDATE`: the inode was copied
into the slave's element, was never written, and the unmount discarded it. The
second failing run's list is the same shape one inode lower (`0000000000000996`).

**The failing runs did not need the interruption.** `cluster-run-20261015-043115`
reports `bracket=1 begun=1 copied=0`: the phase-4 checks that require an open pass
bracket and a copy in flight both FAILED, so nothing was interrupted, and the run
still differed by two lines. Whatever produces the loss does so on a run the
interruption never touched. The earlier failing run is the same shape at the other
end: its stop landed at `copied=6`, 6 updates between the remount and the unmount,
and the destroy it is blamed on had already happened 30 s earlier inside the bigdir
write.

**The destroy is not the cause and it is upstream's intended delete.** All 31
destroys in the 12 runs that printed them carry `destroy focus 0000000000000000/-1`,
which is the state the sweep arm sets (`focus = NULL; n = -1`,
`hammer2_synchro.c:741-742`) falling into the shared `n < 0` arm. Zero destroys in
any kept log carry a non-NULL focus, so the compare arm has never produced one.
The sweep is reached when the element's own scan ends early while the local scan
still has chains (`chain && merror == ENOENT`), and a converged run performs it
too: `cluster-run-20261015-060330` destroys `4.952c5ca9c9858001` and
`4.b77f7af1cd8e8001`, the same two root dirents, and converges. Those two run 31 of
31 destroys.

**Where the copies are lost, on the failing run's own log.** The flush this path
exists to run gates on the element root's flags and reads it unflagged on every
pass:

    [20170.584663] sync_flush: clindex 1 chain 0000000017bed331 not flagged (00046102)
    [20175.705029] sync_flush: clindex 1 chain 0000000017bed331 not flagged (00046102)
    [20180.824827] sync_flush: clindex 1 chain 0000000017bed331 not flagged (00046102)
    [20185.269363] hammer2_kill_sb: after unmount: 7 inode, 13 chain, 2 modified, 469 dio still allocated

The element root's word holds none of `MODIFIED`, `UPDATE`, `ONFLUSH` or `DESTROY`,
so `hammer2_sync_flush()` takes its `not flagged` branch and never calls
`hammer2_flush()`. The chains the pass flagged are its children, not the root, and
the root's word is cleared by the descending flush on the way down. The copies stay
in memory, the unmount scraps them, and the next mount reads a slave that is short
by exactly those keys. This is the defect the helper's own comment at
`hammer2_synchro.c:134` calls "a different defect" and leaves.

**Three instruments were wrong, and one of them was mine.** The `sweep` counter on
the `filekeys` line is a local of `hammer2_sync_slaves()` reset per call, so the
pass's own value is on its own line and `tail -1` reports the next pass's zero; the
failing run's destroying pass printed `sweep 127` and the last line printed
`sweep 0`, and five records were written from that zero. `sweepstate` is gated
`iters < 64` while the destroying pass ran 3816 turns, so it could not print the
turn that took the sweep arm. And the roadmap row's central claim, that the
failing run's `sweep` read 0, is the `tail -1` defect written down as a finding.

**What this changes.** The phase-4 stop knob cannot be aimed at the sweep: a destroy
is emitted only inside the bigdir write, and zero destroys in 31 kept runs fall in
the phase-4 window, so a stop-on-sweep wait there exhausts its bound and reports a
timeout as if the sweep had not come. The `H2_STOP_ON_SWEEP` knob written toward that
was removed rather than relocated, since the sweep is not the cause. The measurement
that decides this defect is `scrapped`, which every run already carries.

## The reading defects of P4, consolidated, 2026-10-15

Seven instruments were read as facts about the subject when they were facts about
the instrument. They are gathered here because they were written into the record
one at a time, each as a finding, and the pattern is what a later session needs:
every one was caught by checking the instrument against its own definition, and
every one had already been published before that check.

1. **`sweep` read with `tail -1`.** `swept` is a local of `hammer2_sync_slaves()`
   reset on entry, so each `filekeys` line carries ONE pass's count. The last line
   is almost always a quiet pass. The failing run's destroying pass printed
   `sweep 127`; the last line printed `sweep 0`. A count of 0 was written into
   five records as a finding and two of them retracted the sweep on its strength.
   The counter was also placed inside the `n < 0` arm on `merror == ENOENT`, where
   its test was true only if the counter was already there, so it read 0 on every
   run for a second reason.

2. **`acted` polled as a stop knob.** It prints on the pass's `filekeys` line, at
   pass end, so it does not move during the pass it is asked to interrupt. A
   request for depth 4 measured 0, three times, and each 0 became a finding.

3. **The fingerprint searched for a field it does not print.** It prints a dirent
   as `name inum type` and never the dirent's own key, so grepping it for a dirent
   key matched nothing on either side by construction. A true claim was retracted
   from that emptiness.

4. **A counter incremented where its test was always true.** The first `sweep`
   placement, above.

5. **A print whose argument order did not match its label.** `sweepstate` printed
   `localp/masterp` against arguments that were `chain, parent`, so the two were
   swapped in every reading taken from it.

6. **`sweepstate` capped out of the region the defect lives in.** The print was
   gated `iters < 64` while the destroying pass ran 3816 turns, so it covered the
   head of a healthy pass and could not show the turn that took the arm.

7. **A geometry asserted without counting the population.** "`bigdir` is the last
   key in the space" was argued without counting; the master held thousands of keys
   above it.

An eighth is recorded below, found while reading a post-fix run: the `n<0`
counter counts file-hash keys only, while the destroys printed beside it carry
dirent and inode keys, so the two fields on one line are different populations.

Three more were found while closing this out and are of the same kind: the
`H2_STOP_ON_SWEEP` knob written toward the sweep was aimed at the phase-4 window
while every destroy in 31 kept runs falls inside the bigdir write and none falls
there, so it would have timed out and reported the timeout as the sweep not
coming; the `maxsweep` helper first written to replace defect 1 had `m` start
empty, so a log whose passes all read `sweep 0` returned nothing and collapsed
"the destroying pass did not run" into "no pass line at all"; and the roadmap
row's central claim, that the failing run's `sweep` read 0, was defect 1 written
down as a finding.

The rule the seven share: **before reading a counter's zero, state what a zero
would have to mean and whether the instrument could produce a non-zero at all.**
A counter that cannot fire and a knob that cannot place both read 0, and a zero
from either is indistinguishable from the state never occurring.

## The flush gate's fix, and what it is measured by, 2026-10-15

The fix moves the re-mark of the topology above the element root to BEFORE the
flush gate, which is upstream's own order in `hammer2_xop_inode_flush()`. The
gate reads the element root's flags, the descending flush clears the root's
`ONFLUSH` before a pass ends, and a pass whose copies are still unwritten below
the root therefore reads the root as unflagged. Re-marking after the flush could
not make the gate reachable, so the flush was skipped and the unmount scrapped
the copies.

**The measure is `scrapped`,** the count `hammer2_unmount_scrap()` prints, and it
is the only reading that separates the two classes across the 40 runs recorded
here: 0 on the 38 that converged, 7 and 8 on the two that differed. Before the
fix a run reported `7 chains scrapped` and `2 lines differ of 120179`.

**The fix's first run, read on the guest while it ran,** because the harness
writes its log only when the guest phase completes:

    126 passes, 126 walks, 126 `not flagged`, 0 `flush error`, 0 `scrapping unflushed`

The walk runs once per pass and the gate still skips the flush on every idle
pass, which is what the earlier revert of an unconditional flush objected to: it
moved the slave's inode count 728 to 801 and cost a full tree walk per pass. The
walk is not that: it takes a lock per chain on the path and stops at the volume
root, and the flush itself still runs only when the element root is flagged.

`scrapping unflushed` reads 0 at the point in the run where the failing runs had
already scrapped their 7 and 8, which is the before-and-after the fix needs. The
harness's own fingerprint verdict is recorded beside this entry when the run
completes.

## The fix holds its measure and a third run still differs, 2026-10-15

Four runs after the flush-gate fix, `scrapped` as the measure:

    attempt 1   scrapped 0   0 lines differ of 120179
    attempt 2   scrapped 0   0 lines differ of 120179
    attempt 3   scrapped 0   4 lines differ of 120179
    attempt 4   scrapped 0   0 lines differ of 120179

The fix does what it was written to do: `scrapped` is 0 in all four, against 7
and 8 on the two runs that differed before it, and attempt 3 carries 137 passes,
137 walks, 0 flush errors. The fingerprint converged in three of the four, so the
defect is reduced and not closed. **The fingerprint can still differ with nothing
scrapped, so the scrap count was necessary and is not sufficient.** The 1.0.27
row's claim that the fix is verified is corrected by this entry.

**Attempt 3's difference is a different shape from the two that preceded it.**
The earlier failing runs were short on the slave by the keys they scrapped. This
one differs by 4 lines of 120179 with the slave short ONE inode (40041 against
40042) and two dirents (40036 against 40038). Its own kernel log shows the pass
that did it:

    [40355.608405] START_SCAN IP=b6a9cb23fd8a8001 chain=00000000aff591ab (0000000000000400)
    [40355.656516] destroy focus 0000000000000000/-1 local 0000000000000a4d/1
    [40355.656697] destroy focus 0000000000000000/-1 local 952c5ca9c9858001/4
    [40355.656774] destroy focus 0000000000000000/-1 local b77f7af1cd8e8001/4
    [40355.656877] filekeys n<0 4  n==0 3  n>0 57  acted 1917 failed 57 last 2048 kept 57 sweep 58 iters 1591 exit 1

All three destroys carry `focus 0000000000000000/-1`, which is the sweep arm's
own state (`focus = NULL; n = -1`), so this is the sweep and not the compare. The
sweep deletes local chains when the element's scan ends early, and the run's
`n<0 4` against `kept 57` says four keys took that arm. The sweep is upstream's
intended delete of local extras and a converged run performs it, so the question
this entry leaves open is whether the four keys it took here were genuinely
extras or were master-present keys the element's scan failed to present.

**What is not yet read.** Attempt 3's images were overwritten by attempt 4 before
the media could be read, so which side holds the differing keys is unread. The
next run that differs keeps its images: the harness copies the kernel log off the
guest but the images are recreated at the start of every run, and a fingerprint
difference is only attributable while they exist.

## The `n<0` counter counts file-hash keys only, 2026-10-15

An eighth reading defect, and it was nearly published. Attempt 3's destroying
pass printed both `n<0 4` and three `destroy focus .../-1` lines, and the two were
about to be read as one population with a missing print. They are different
populations: `h2dbg_file_nlt` is incremented only when the turn's key is a file
hash (`kh > 0x8000000000000000`, `hammer2_synchro.c:830-835`), so it counts the
`n < 0` turns among FILE keys. The three printed destroys carry keys `0xa4d`,
`952c5ca9c9858001` and `b77f7af1cd8e8001`, all below 2^63, so none of them is in
that counter's population.

The counter's own comment says the three counters are for file keys and prints
them "once per pass at the end of the root scan", and the pass's other counters on
the same line (`acted`, `failed`, `kept`) are whole-pass totals. Reading four
counters off one line as though they shared a population is the defect. The rule
it joins: a line's fields can have different scopes, so read each field's own
guard before comparing two of them.

## A differing run caught with its media, and the flush fix is incomplete, 2026-10-15

The loop that runs until a fingerprint differs produced one on its second attempt,
and the harness kept the images, so this is the first differing run whose direction
is read off the media rather than inferred.

    attempt 1   scrapped 0    0 lines differ of 120179
    attempt 2   scrapped 10   4 lines differ of 120179

**The direction is master-only, and the keys are the scrapped ones.** The kept
fingerprint diff is 4 lines, all `<` (master-only), 0 `>`:

    < data  0x0000000000000a54 0000000000000000/16 b3245a7507a24260
    < data  0x0000000000004535 0000000000000000/16 d44ae2b367673c20
    < inode 0x0000000000000a54 FILE 4096
    < inode 0x0000000000004535 FILE 4096

The slave is short two files, inode and data each, and the run's own kernel log
names both as chains the unmount discarded unwritten:

    scrapping unflushed inode 0000000000000a54/0 flags 00006243
    scrapping unflushed inode 0000000000004535/0 flags 00006243
    scrapping unflushed data  0000000000000000/16 flags 00004243

`0x6243 & HAMMER2_CHAIN_FLUSH_MASK` is `MODIFIED | UPDATE`: copied, never written.
This is the same defect the flush-gate fix targeted, so the fix is incomplete
rather than wrong.

**Why it is incomplete, read from the same log, and a first attribution refuted
by it.** The first reading of this run was that the pass making the lost copies was
interrupted before its flush ran. The log refutes that: the two passes before the
unmount both COMPLETED, each running the flush gate:

    [44182.223878] sync_slaves pfs CL clindex 1
    [44182.224064] sync_slaves error 0 defer 0000000000000000
    [44182.224084] sync_flush: clindex 1 chain 000000001cc9f8e5 not flagged (00046102)
    [44187.343905] sync_slaves pfs CL clindex 1
    [44187.344394] sync_slaves error 0 defer 0000000000000000
    [44187.344424] sync_flush: clindex 1 chain 000000001cc9f8e5 not flagged (00046102)
    [44190.825279] hammer2_kill_sb: after unmount: 7 inode, 18 chain, 4 modified, 493 dio still allocated

`sync_slaves error 0` is the pass returning normally, and the flush gate ran after
each one. So the copies were made by a pass that completed, and the gate read the
element root unflagged anyway. The re-mark the fix moved above the gate did not make
the gate reachable on this run, so either the walk does not reach the chain the gate
reads, or the flag it sets is cleared before the gate runs. That is the reading the
next run takes.

**The measure and its limit.** `scrapped` was 0 on four consecutive runs after the
fix and 10 on this one, so four clean runs did not establish the fix and the
earlier reading of "reduced and not closed" was the right one to write. The loop's
stop condition is the fingerprint, and it took two attempts to differ, which is
consistent with the 2-in-40 rate the defect had before the fix.

**What the next fix has to reach.** The copies must reach media when the pass is
interrupted, not only when it completes. The unmount path already runs a final
flush (`hammer2_vfs_sync_pmp()` and the device teardown), and the chains are
`MODIFIED | UPDATE` with a parent, so the question is why that final flush does not
carry them: either the element's topology is not flagged on the path the unmount
walks, or the flush stops at a boundary above them. That is the reading the next
run takes, and the kept images make it attributable.

## Why the unmount's final flush does not carry the element's copies, 2026-10-15

The next fix needs to know why the copies survive to the unmount, and the unmount
path answers it. `hammer2_vfs_sync_pmp()` (`hammer2_vfsops.c:2686`) flushes the
inodes on the PFS's **sync queue**: it moves inodes from `depq`/`sideq` to `syncq`
and flushes those, one inode at a time. The synchronization thread's chains are
not on that queue and have no inode on it at all, which is the port's own recorded
reason for `hammer2_sync_flush()` existing (`hammer2_synchro.c:100-108`: "This
thread changes chains directly and puts no inode on the sync queue, so nothing
bridged them").

So the unmount's three `hammer2_vfs_sync_pmp()` calls (`hammer2_vfsops.c:3082-3084`)
walk the inode queue and never reach the element's chains. The device teardown's
own flush (`:2529-2537`) flushes `hmp->vchain` and `hmp->fchain` only, and it is
gated on those two static chains' flags. The only thing in the tree that flushes
the element's chains is the pass-end `hammer2_sync_flush()`, and a pass that is
interrupted before its end never reaches it.

**That is the whole shape of the remaining defect:** the copies reach media when a
pass completes, and not when it is interrupted. The flush-gate fix closed the case
where a completed pass leaves unwritten copies below an unflagged root; it does not
close the case where the pass never completes.

**The fix has to give the interrupted pass's copies a path to media.** Three
candidates, and the reading that separates them:

1. **Flush on the way out of the thread's stop.** The thread reads STOP/FREEZE at
   its loop top and between deferred directories, so a stop that arrives mid-pass
   is honoured at the next boundary. Running `hammer2_sync_flush()` at that point
   would carry the copies the interrupted pass made. It is the smallest change and
   it uses the helper that already exists.
2. **Flag the element's topology when a pass copies, not only at its end.** The
   three `hammer2_sync_setflush()` call sites in the insert, replace and destroy
   paths already flag the path to the volume root per chain, so the question is
   whether the unmount's teardown flush would then carry them; it flushes vchain
   and fchain, and the element's chains hang below a PFS root, so what would settle
   whether this alone is enough is reading whether the teardown's flush reaches a
   PFS root's subtree at all; `hammer2_flush_core()` skips a PFS boundary when
   FLUSH_ALL is clear and the PFS is mounted, and this call passes FLUSH_ALL.
3. **Have the unmount walk the element's chains.** The largest change, and it
   duplicates what the thread already does.

Candidate 1 is the one to try first: it is the smallest, it uses the existing
helper, and the stop path already exists and is exercised by phase 4.

## The re-mark flagged the parent and the gate reads the root, 2026-10-15

A ninth finding, and it is in the fix, not an instrument. The previous commit
moved the re-mark above the flush gate but passed `chain->parent`. The walk
flags the chain it is given and then walks up, so the element root -- the word
the gate tests -- was never given the flag. The walk then stopped immediately at
a NULL parent on every pass, setting ONFLUSH on an orphan and returning.

**The run's own log proves it, in three lines 20 microseconds apart:**

    [44182.224064] sync_slaves error 0 defer 0000000000000000
    [44182.224078] sync_setflush: stopped at 0000000000000000/0 type 255 (NULL parent)
    [44182.224084] sync_flush: clindex 1 chain 000000001cc9f8e5 not flagged (00046102)

The pass returns, the walk runs, and the gate reads the root six microseconds
later as unflagged. The walk's own print says why: it stopped at a NULL parent
at once, so nothing above the orphan was reached. 131 passes, 131 walks, 131
unflagged reads, and the flush never ran.

This also refutes the interrupted-pass attribution written beside the differing
run: the two passes before the unmount both COMPLETED (`sync_slaves error 0`),
and each ran the gate. The copies were made by a pass that finished, and the gate
never fired.

The correction is one word: `hammer2_sync_setflush(chain)` instead of
`hammer2_sync_setflush(chain->parent)`. The gate reads `chain->flags`, so the
walk must be given `chain`. What this run decides is in the attempt table below.

**Attempt table, corrected fix, 2026-10-16.** Eight phase-4 runs, each one
interrupting an open pass mid-copy and resuming to convergence:

    attempt  scrapped  fingerprint lines differ of 120179
    1 - 8    0         0

These are symptom readings only. The claimed mechanism confirmation was
invalid: `hammer2_sync_flush()` called `hammer2_sync_setflush(chain)` and then
tested `chain->flags & HAMMER2_CHAIN_FLUSH_MASK`. The helper's first loop
iteration sets `HAMMER2_CHAIN_ONFLUSH` on that same chain, and ONFLUSH is in
the mask. Thus every non-NULL root passes; zero `not flagged` lines are
entailed by the code and do not prove a selective dirty gate. The eight runs
still establish eight interrupted/resumed convergences with zero chains
scrapped, but do not establish the idle-pass cost or a selective gate. The
earlier 7 and 8 scrapped chains and the later 4-line fingerprint difference
remain their original recorded observations. P4 is reopened pending an
independent flush-decision reading and repair of the failed-copy stamp path.

## The flush-gate diagnostic measures the bit it sets, 2026-10-16

An independent code review found the gate tautological. This entry records the
instrumentation now in the tree and the first post-instrumentation guest run below. With
`hammer2_debug & 0x8000`, `hammer2_sync_flush()` prints the element-root flags
before `hammer2_sync_setflush()`, after the walk, at the flush decision, and
after `hammer2_flush()` returns. The post-mark flags and decision are not
independent evidence: the walk sets ONFLUSH on the root, which is included in
`HAMMER2_CHAIN_FLUSH_MASK`.

The first attempt to identify root clears inside `hammer2_flush_core()` by
comparing against `sync_thrs[0].clindex` was rejected before testing: that is
not the active element index and the cluster-array access lacked its
synchronization. It was removed. A safe, low-volume correlation from the
recursive flush path to the per-clindex root remains unresolved. Do not infer
which flush clears the root from timestamp proximity alone.

**Readings from the existing cluster-sync harness with the pass-end diagnostic,
2026-10-16.** `KDIR=/home/james/kernels/linux-7.3-rc5-kasan`,
`H2_FIXTURE_START=1`, `H2_RUN_TIMEOUT=1800`, `H2_DEBUG=0x8000`. The run reports
32 checks, zero failed; phase 4 interrupted after four inode updates, resumed,
`scrapped 0`, both fsck checks clean, and 0 lines differ of 120179.

The added readings separate two root states before marking:

    idle CL pass:  root-before 00046102; root-after-mark 00046302;
                   decision flush; completed flags 00046102, error 0
    active pass:  root-before 000c6343; root-after-mark 000c6343;
                   decision flush

Counts across the whole run: 94 flush decisions, 0 skips, 89 at `clindex 1`
and 5 at `clindex 0`. Pre-mark roots read `00046102` on 82 passes but `00046302`
on 3 and `000c6343` on 4; the `00046302` and `000c6343` passes all sit inside
the bigdir/indirect-maintenance activity in the log, so none of those is an
idle pass. The counts, not the samples alone, are the reading.

**Flush cost, read from the same run's own timestamps.** The interval from
`root-before` to `completed flags` on the 82 passes entering at `00046102`
(idle-classified: no insert/replace/destroy in their windows) has median
0.94 ms, p90 1.34 ms, max 2.62 ms. The busy-class passes are the expensive
ones: the `000c6343` passes reach 18.6 ms, all of it inside `indirect_maint`
work the flush itself kicked off, and one `clindex 0` pass at a remount read
16.1 ms. Pass cadence is 5.12 s median. So the unconditional pass-end flush
costs an idle pass about one millisecond, not the tree walk the reverted
forcing change measured at 728 to 801 inodes: `hammer2_flush()` on an unflagged
root returns after its own flags test, and the flush work only exists when
descendants are dirty. The earlier revert's cost was from the unconditional
re-mark making every pass a flushing pass on a tree that HAD dirty work
queued, not from the flush call itself on a clean tree.

This is still one debug-enabled run, so it bounds rather than settles the
idle cost; a controlled run without `0x8000`'s per-action prints remains the
cleaner reading. But the millisecond-class idle cost removes the pressure to
gate the flush at all before the stamp repair: the unconditional flush's
per-pass price is two orders below the 5 s cadence.

The active pass has insert actions immediately before its flush; idle passes show
no insert/replace/destroy action in their pass window. This independently shows
the pre-mark word differs between observed idle and active cases, but the current
code marks before deciding, so both take the same flush path. The run therefore
does not validate selectivity, nor does it prove which flush cleared ONFLUSH.
Because `0x8000` also enables existing per-action diagnostics, this was not a
controlled idle-cost measurement. The flush return was zero and the media
converged in this run; this is a recovery reading, not a repair of the
tautological gate or the failed-copy stamp path.

The same review confirmed a separate fail-open requiring its own design: the
per-key `nerror` is counted then discarded before the element-root
`modify_tid` stamp. However, helper return values do not encode mutation
reliably: insert creates before its later modify can fail, replace may resize
before later work, and destroy returns its cursor re-lookup status. The
existing inode deferral list represents recursive inode work, not arbitrary
failed keys. The measured whole-pass error rollup livelocked; no new retry
policy is accepted yet. The next change must classify each action's mutation
and retry semantics before touching the stamp.
## The failed copy is retried, measured by a refused allocation, 2026-10-16

The second defect the review named is closed with a probe that failed before
the change and passed after it. `hammer2_sync_slaves()` discarded each key's
`nerror` and stamped the element root's `modify_tid` whatever the arms had
returned, so a key whose copy failed compared equal on every later pass. The
record is now one bit, `failed`, on the `hammer2_deferred_list_t` every call
of a pass shares, set at the point the carried code discarded the error and
read at the stamp: a pass with a failed key stamps no inode root after it, so
the next pass rescans and reaches the key again, and the scan goes on past the
failure, which is what the reverted whole-pass rollup of 2026-10-13 did not
do. Reading the three action helpers for what they return found two more
fail-opens: `hammer2_sync_insert()` assigned `chain->error` at its relock,
which a refused `hammer2_chain_modify()` does not set, so a refused insert
returned 0; and `hammer2_sync_destroy()` discarded `hammer2_chain_delete()`'s
return and returned the cursor re-lookup's. Both now return the first error.
`EINPROGRESS` from the kept-newer arm sets the bit too, which is what that
arm's own comment promised and the discard did not deliver. The bit is
pass-wide, and the cost of that is written as a `DEFER` beside it.

**The probe.** `cluster-sync.sh` gains `H2_FAULT=N`, which arms the debug
build's `fail_alloc_after` before the SLAVE's `pfs-create` with a new
`fail_alloc_count=N` that clears the refusal on the Nth, so the first N
allocations the thread's first pass makes are refused through the freemap
path a full volume refuses them on, and nothing on the host times the window.
`H2_KO` loads a module built elsewhere, which is how the control was run: the
tree at `7f458c2` with only the knob added. Two placements of the phase were
wrong first and are kept in the script's comment: with the files written after
phase 2, mounted or with the slave's ROOT unmounted, the thread copied nothing
at all (`cluster-run-20261016-062330`, `-063323`: 0 updates after phase 2 in
each), because the slave's element has joined the master's pmp and the
frontend writes every later file to it directly. That is also why phase 4's
backlog reads `begun rc 1` and 0 updates at `H2_NBIG2=200` on every run here,
control and fixed alike: the harness has one copy that goes through the sync
thread, the first pass, and that is where the fault is armed.

**Before**, `cluster-hang-20261016-065003.klog`, pre-fix module, `H2_FAULT=8`:
`flush_core ... error 00000020` as the window opened, `filekeys ... failed 3`
on the first pass, then a general protection fault, `KASAN: null-ptr-deref in
range [0x50-0x57]` in `hammer2_chain_lookup+0x5da` from
`hammer2_sync_slaves+0x40a`, `h2nod-CL` dead, a second oops in `rm` 45 s
later, and the run hung past 900 s. The scan recursed into a deferred inode
whose insert had been refused: `hammer2_inode_chain()` returned NULL for the
element and the lookup dereferenced it, the fault the comment at the
`want_update` ternary had predicted for a NULL chain.

**After**, `cluster-run-20261016-070537.klog`, the fixed module built with
`H2_LOCKDEBUG=1`, same knobs: `failed 7` of 8 refusals, no fault, 0 kernel
warnings, KASAN or UBSAN reports, kmemleak 0. The deferral is skipped for a
key whose arm failed, so the recursion that faulted the control is not
entered; a guard for a scan handed an inode with no element chain returns EIO
instead of faulting, and did not fire in this run. One
`hammer2_sync_slaves: error 64` at 395.02 is ENOENT, the scan's own end
leaking: the stamp block used to absorb it by reissuing the collect, and with
the stamp withheld it reached the caller, which read it as a failed pass,
drained the deferrals (`didbreak`) and flushed. The pass at 400.14 scanned the
root again (`START_SCAN IP=...8001 chain=... (0x407)`) and completed the set
at 400.21. Both fsck clean; master and slave (442 inode, 503 data, 438 dirent)
each; the cluster PFS fingerprint 0 lines differ of 1379. The leak is closed
in the same change (a withheld stamp returns 0 as a completed scan does), and
a clean run at the default size, `cluster-run-20261016-072144.klog`, read the
same two leaked ENOENTs on passes whose `kept` count (the EINPROGRESS arm)
withheld the stamp, with the media converged, 0 lines differ of 120179,
scrapped 0, 0 kernel reports; before the change those passes returned 0 by
way of the stamp's collect, so the zero pass-error readings of earlier runs
did not see them either.

What this does not show: the retry under a persistent failure, where the
pass-wide bit rewrites every inode after the failed one on each pass (the
`DEFER`); and whether the pre-fix module's stamp would have left the slave
short had it not faulted first, since it faulted first. The fault is the
stronger before-reading, and the stamp's fail-open is read from the code
rather than from a converged-short media here. The replace and destroy arms
were written here as unreachable by this harness; the next entry drives them.

**The withheld stamp livelocked the pass.** The second fault run on the
module with the ENOENT leak closed, `cluster-hang-20261016-074222.klog`,
hung past 900 s with no kernel report of hammer2's own: 4492 `sync_slaves
error 256` lines (`EAGAIN`) between 2066.6 and 2828 s, each a root scan that
pushed one deferral, drained it, and was called again, until `h2nod-CL`, a
kworker and the harness's `rm` were reported blocked at 2459 s. The pass loop
in `hammer2_primary_sync_thread()` calls the root scan again after each
deferral drain and stops only when it returns something other than `EAGAIN`,
which the carried design reaches by stamping each deferred directory so the
rescan compares it equal. With `failed` set, no directory is stamped, so every
rescan defers the same ones. Run 070537 did not meet it because its root scan
pushed no deferral: the leaked ENOENT ended the loop. The fix is in the loop,
not the stamp: a failing pass drains its deferrals once and ends, each entry
scanned at most once (`scanned` on `hammer2_deferred_ip_t`, since a deferred
directory's rescan has the same shape one level down), and the next pass five
seconds later retries the key, which is what the withheld stamp is for.

**After the loop fix**, `cluster-run-20261016-075820.klog`, `H2_FAULT=8`,
`H2_LOCKDEBUG=1`, `H2_NBIG=200`: the fault phase opens at 318.92 s; the pass
at 318.96 ends on its one `error 256` line with `acted 58 failed 7` and no
rescan; the pass at 324.08 reads `acted 232 failed 7`, 174 more actions
with no new failure, stamps the 58 inode roots (`syncthr: update inode`) and
returns 0 at 324.14; every later pass returns 0 with no deferral. The harness
reads 34 checks, 2 failed, the two being phase 4's `begun`/`copying` items
the size limit above explains; pass errors 0 on both counts, 7 of 8 refusals
failed copies, 0 lines differ of 1379, scrapped 0, 0 kernel warning, lockdep,
KASAN or UBSAN reports. The clean run at the default size on the same tree,
`cluster-run-20261016-081110.klog`: 32 checks, 0 failed, 0 lines differ of
120179, scrapped 0, 0 reports, pass errors 0, with `kept 49` passes (the
`EINPROGRESS` arm) withholding their stamps and converging on the next.

## The pass-end flush is unconditional, by the measured cost of gating it, 2026-10-16

The flush gate P4 was reopened on is removed rather than repaired, and the
decision is recorded on three readings already in this file. A test of the
element root's flags before the re-mark skipped the flush on the pass that
needed it, because a mounted PFS's sync clears the root's `ONFLUSH` on its way
down and stops at each child inode (the 2026-10-15 entries above: 3873 copied,
801 on media). A test after the re-mark reads the bit `hammer2_sync_setflush()`
set a line earlier, which is the tautology the 2026-10-16 review found. And the
flush the tautological gate let through on every pass costs an idle pass 0.94
ms median, 1.34 ms p90, 2.62 ms max over 82 idle-classified passes against a
5.12 s cadence (`7f458c2`). A gate that chose would need a per-pass reading of
every mutation the pass can make, actions and stamps both, and the plan refused
a parallel dirty bit without that coverage proved; at two orders below the
cadence the proof is not worth its risk, and `hammer2_vfs_sync_pmp()` spends the
same flush every sync interval for the same reason. The test and the three
prints that measured it are gone; `root-before` and `completed` stay, since the
idle cost is read from their timestamps. The trigger that reopens the question
is a `DEFER` in the status document's ledger: an idle flush measured above a
tenth of the cadence.

**After**, `cluster-run-20261016-142120.klog`, the ungated flush with
`H2_LOCKDEBUG=1` at the default size: 32 checks, 0 failed, 0 lines differ of
120179, scrapped 0, pass errors 0, 0 kernel warning, lockdep, KASAN or UBSAN
reports. Re-read from `root-before` to `completed` with the two prints that
stood between them removed, 153 idle passes (no insert, replace, destroy or
stamp since the previous flush) take 0.03 ms median, 0.05 ms p90, 25.45 ms
max; the 4 busy passes 0.17 ms median, 11.45 ms max. The 0.94 ms of `7f458c2`
was the cost of two serial-console prints inside its own window, as that
entry's last sentence allowed; the decision above was taken on the larger
number and holds by a wider margin on the smaller.

## The replace and destroy arms are driven, and the replace arm over-read, 2026-10-16

The failed-copy entry above called a refusal inside `hammer2_sync_replace()`
or `hammer2_sync_destroy()` out of this harness's reach, because a slave's
first pass is all inserts and every later write reaches its element by the
frontend. That was a limit of the script, not of the system, and the script
is the instrument. Phase 2c of `cluster-sync.sh` now makes the slave stale
behind the master's back: five files written while clustered, so the slave
holds them; `/mnt/h2c` and `/mnt/h2s` unmounted, both, since the slave's
device stays known while its ROOT is mounted and its element stays in the
pmp; the MASTER mounted alone, the five deleted and five others rewritten
at a smaller size; the cluster unmounted; `H2_FAULT2=N` armed; the slave's
device mounted, whose element joining the pmp starts the thread, measured
by the thread count going 0 to 1. The first pass then finds five keys the
master lacks and five whose `modify_tid` differs. Two per-arm counters were
added to the `filekeys` line, and the first run with them read 0 for both
while the arms demonstrably ran (`destroy focus` printed five times, the
report below sat inside `hammer2_sync_replace()`): the edits that added
them had matched nothing and been written unchecked, and were placed again.

**Before**, `cluster-run-20261016-152207.klog`, `H2_FAULT2=8`: 5 of 8
refusals failed actions and no pass error leaked, both as designed, but
`KASAN: slab-use-after-free in hammer2_sync_replace`, a read of 65536 bytes
whose valid region ended 6144 bytes in (the poison begins at `...70000`
and the read at `...6e800`), from `hammer2_sync_slaves()` on the thread;
the slave's PFS differed from the master's by 4 lines of 120165. Not a
stale pointer: an over-read. `hammer2_sync_replace()` on a chain whose size
differs from the focus's resizes it to `hammer2_getradix(chain->bytes)`,
the slave's own size, which changes nothing, and the DATA case then copies
`chain->bytes` out of the master's block. The rewritten files went from
about 237 KB to about 60 KB, so the slave's 64 KiB block was filled from a
master block of the same radix but the copy of a last block ran past it.
DragonFly's `hammer2_synchro.c` has the same three lines at its head on
this date, read through the mirror, and none of the BSD ports carries the
file. The fix takes the radix of `focus->bytes`, marked `XXX`, and is
staged as `doc/upstream/dragonfly-hammer2_synchro-replace-resize-to-focus.patch`
with its standing in `README-provenance.md`.

**After**, `cluster-run-20261016-153559.klog`, same knobs: 38 checks, 0
failed. 27 destroys for 5 deleted files (their inodes, their dirents and the
shrunk files' trailing blocks) and 19 replaces for 5 rewritten, both read
from the per-arm counters; 5 of 8 refusals failed actions in that pass with
0 pass errors; threads 0 with the cluster down and 1 on the slave's return;
0 lines differ of 120165; scrapped 0; 0 kernel warning, lockdep, KASAN or
UBSAN reports. The clean run without `H2_FAULT2`,
`cluster-run-20261016-154916.klog`, which every run now carries as its
phase 2c: 36 checks, 0 failed, 24 destroyed and 13 replaced for the same
ten files, `failed 0`, 0 lines differ of 120165, scrapped 0, 0 reports.

## The cluster transport's loopback, measured on the host, 2026-10-16

P5 asked for a transport interface and a deterministic loopback with seven
exit criteria: delay, loss, duplication, reordering, disconnect, reconnect
and a reproducible event trace. What the interface is was read from the
sources before anything was designed. DragonFly's kernel never opens a
connection: `hammer2 service` makes a `pipe()`, hands one end in through
`HAMMER2IOC_RECLUSTER` (`sbin/hammer2/cmd_service.c:803-840`), and the
kernel's `kern_dmsg.c` makes exactly ten calls into that descriptor,
`fp_read` three times a frame, `fp_write` twice, `fp_shutdown(SHUT_RDWR)`
three times at teardown and `fdrop` twice (read through
`git cat-file` on the mirror at `250a8b4`, since the kernel half is not
checked out). The shim already carries the first two (`hammer2_os.h:1477`).
The frame is a 64-byte header with magic `0x4832` and 64-byte aligned aux,
and the kernel checks neither CRC; `lib/libdmsg/msg.c` does.

Two Linux facts were read in the rc5 tree and decide the descriptor's
type: `pipe_read()` leaves only on data or a signal (`fs/pipe.c:463`) and
`kthread_stop()` sends none, while a stream socket's reader leaves on
`RCV_SHUTDOWN` (`net/unix/af_unix.c:2731`), which `unix_shutdown()` sets and
wakes (`:3219-3224`). So the loopback is an `AF_UNIX` stream socketpair and
the P6 intake will refuse a pipe. An architect review of the shape before
code (one round, 2026-10-16) settled three things this entry rests on: the
frame reader stays in `kern_dmsg.c` and arrives with it, since lifting it
into the shim is a divergence P6 would undo; the simulator belongs in
userland, where the daemon is; and no kernel echo scaffolding, since the
three shim primitives the intake needs would have had no caller, which the
work queue's `no_compile_equals_done` forbids. P5 therefore ships no file
under `src/`.

`test/h2loop.c` sits where the daemon sits, holding its end of one
socketpair; the kernel's end is played by a generator writing frames as
`kdmsg_iocom_thread_wr` does and a receiver reading them as
`kdmsg_iocom_thread_rd` does, plus the two CRCs. Delay is virtual (a frame
sent at tick i is due at i + d, the queue drains in tick order), so nothing
sleeps and reordering is what differing delays produce. Every decision is
one trace line from one seeded xorshift64*, and `--replay FILE` reruns the
header's arguments and requires byte equality.

`test-transport.sh`, after the audit below: 34 checks, 0 failed, 0.2 s.
The readings at seed 7, 200 frames: delay-max 50 delivers 200 with 160
reordered against 0 plain; loss 0.2 drops 43 with 157 delivered, receiver
and trace agreeing; dup 0.2 duplicates 43; half-close at 50 delivers 51,
one EOF, 0 EPIPE, 149 lost at the daemon; disconnect at 50 delivers 51
and the writer sees EPIPE 149 times; reconnect at 60 delivers 191 with 9
EPIPE; a flipped `aux_crc` bit is one rejection named `hdr_crc`, since the
header CRC covers that field (the gate first expected `aux_crc` and the
receiver was right); same seed gives identical traces, seed 8 differs,
replay reproduces, and a trace with one delay edited exits 1. Under ASan
and UBSan with every knob on, including 64 KiB aux: clean. Negative
controls placed in the subject: the loss branch disabled fails "dropped >
0" and nothing else; the replay comparison forced true fails its edited
trace control and nothing else. A first attempt at the second control
removed the comparison function and failed the compile instead, which
proved nothing about the replay, so it was placed inside the comparison.

One class finding on the way: the `DEFER` ledger gate's population was
`src/`, `script/` and `.github/`, so the simulator's marker in `test/` was
invisible to it in both directions. `test/` joined the population and the
row was added; the gate reads 7 markers, 7 rows.

An independent adversarial round over `fbcc31e` (one round, 2026-10-16,
rule 10) refused sign-off with six findings, all six applied here, the
first by correcting this entry. The first was this entry's own: it published 156 reordered, 41
dropped with 159 delivered and 41 duplicated as seed 7 readings, and the
committed simulator prints 160, 43 with 157, and 43 at seed 7 under every
compiler tried. The numbers were from exploratory runs at the default
seed 1, taken before the gate fixed its seed, and the gate had let them
stand because it asserts only that each is above zero. They are
corrected above and the changelog row is corrected to match. Second,
`--replay` applied a trace header's values without the command line's
bounds, so a header edited to a 4 MB aux wrote a frame nobody read and
hung the lockstep; the bounds now run after the header read and the gate
requires exit 2 on such a header. Third, the gate's `traced()` turned a
missing trace into 0, which is the verdict two controls accept, and the
population check read only the summaries; it reports "missing" now and
the population includes every trace. Fourth, the one arithmetic check
aborted uncounted on an empty operand; it substitutes a value no
equality accepts. Fifth, the porting section said a pipe reader leaves
only on data or a signal, where `pipe_readable()` also returns on the
last writer closing, and omitted that a Linux pipe is one-directional
where `kern_dmsg.c` reads and writes one descriptor; both corrected.
Sixth, `--corrupt-at` corrupted every copy under `--dup` and the
half-close model read a second EOF the kernel's reader, which exits on
the first, would never see; the bit now flips in one copy and a
connection reports one EOF, so the half-close reading above is one EOF
where the first run's was two. A second round found that claim false
where a half-close and a disconnect land on one connection, since those
two paths read the socket unguarded (`--halfclose-at 10 --disconnect-at
20` read 2); both are guarded and the same run reads 1. Controls for the gate fixes: an emptied
trace fails the population check, an emptied `dropped` field fails three
checks and the count stays 34.
