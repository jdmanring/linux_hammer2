Status
======

The module mounts a HAMMER2 volume read-only, lists it and reads it. Every
file in a `makefs` fixture compares byte for byte with the tree it was
made from, across the sizes the code branches on, and so does every file
on media DragonFly itself created and wrote, including the DragonFly
guest's own installed root. LZ4 and ZLIB blocks decode, symlinks resolve,
a block whose check code does not match is refused on read, and a volume
header that fails its crc is not mounted. It mounts read-write and
every write operation, from a byte written to a directory renamed, has
been read back and checked by DragonFly; a writer killed, a kernel
panicked, the power cut and a header torn each left a volume both this
port and the FreeBSD port recovered, and the refusal that stood on the
read-write mount from 0.3 is gone, as is the refusal on the read-only to
read-write remount, which now runs the same recovery the mount path runs
and is refused only when the device itself is write-protected. HAMMER2's
ioctls answer as Linux ioctls, so `hammer2-utils` drives the volume, and
files on it can be mapped and executed, which is what lets a volume boot
as a root filesystem: a snapshot this port takes
mounts on DragonFly and reads back the tree as it stood.
Getting here found and fixed defects no amount of compiling would have
caught: a livelock on the first mount, a use after free found by listing
one, a stranded chain lock that made a full volume trip a circular lock
dependency, a second use after free that faulted the unmount of a
full volume, a chain freed with its lock held on the same path, and a
fill lost nearly whole to a flush with no room, because the free-space
reserve every other tree keeps was declared here and never carried, a
mapped write accepted on a full volume where `write(2)` was refused,
and a file mapping that refused every dirty folio to compaction with a
warning that sat uncounted in 39 of 62 kept logs of the gate that now
counts it.
A write near full is refused now, as the other trees refuse it.
A million files went in and were counted on both sides, and a large
file reads back at the rate btrfs and DragonFly's own HAMMER2 reach on
the same guest, both readings taken for 0.9 and recorded below.
`CHANGELOG.md` is the enumeration; this paragraph names kinds and does
not carry the count. This file is the one to correct
rather than to argue with: if a claim here is stale, it is a defect.

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
warning. The carried write handler depends on the same contract, since it
refuses a folio smaller than the block it would write.

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

## What is in the tree

| file | lines | origin |
|---|---|---|
| `hammer2.h` | 1385 | DragonFly, in the FreeBSD port's shape, OS-facing types rewritten |
| `hammer2_disk.h` | 1205 | DragonFly, carried; `struct uuid` defined locally |
| `hammer2_ioctl.h` | 221 | DragonFly, carried; `<linux/ioctl.h>`, `HAMMER2_MAXPATHLEN` pinned |
| `hammer2_admin.c` | 629 | FreeBSD port, carried byte-for-byte; the xop allocation zone is shimmed |
| `hammer2_freemap.c` | 1000 | FreeBSD port, carried byte-for-byte |
| `hammer2_xops.c` | 1453 | FreeBSD port, carried byte-for-byte but two `XXX` lines, the lock level of the inode chain the detached create makes and the subclass of the entry the rename holds detached |
| `hammer2_ioctl.c` | 1159 | FreeBSD port, carried with fifteen `XXX`: the seek ioctls and GEOM dropped, the read-only test and the copy-out on Linux primitives, growfs clearing headers through the DIO layer, the mount-wide sync through the kernel's, an unrecognized command answered ENOTTY rather than EOPNOTSUPP, and the snapshot's lock order corrected under lockdep |
| `hammer2_bulkfree.c` | 1239 | FreeBSD port, carried byte-for-byte; `printf` and `tsleep` shimmed |
| `hammer2_chain.c` | 4992 | FreeBSD port, carried byte-for-byte but twelve `XXX` lines, the lockdep class set where a chain lock is initialized, the nesting level handed to the shim where a chain is first placed under its parent or created under one, the level below for the children an indirect block takes over, the new block's own first lock recording no order, the caller's chain left alone when an indirect block cannot be created, and the last drop of a chain naming the caller that still holds its lock; the recursive lock is NetBSD's non-recursive answer, `pause` and `__diagused` shimmed |
| `hammer2_flush.c` | 1348 | FreeBSD port, carried; the device flush and the volume header write are the port decision below, marked `XXX` in place |
| `hammer2_cluster.c` | 188 | FreeBSD port, carried byte-for-byte; nothing in it touches the OS |
| `hammer2_subr.c` | 450 | FreeBSD port, carried; the timestamp, the signal check and the two `timespec64` signatures are marked `XXX` in place, and `hammer2_getnewfsid()` is not carried |
| `hammer2_inode.c` | 1880 | FreeBSD port; carried, `hammer2_inode_create_normal()` with the owner rule written against the idmap. `hammer2_igetv()` is this port's, written on `iget5_locked()` |
| `hammer2_vfsops.c` | 3038 | FreeBSD port; the PFS half and the recovery carried, the module entry, globals, mount path, mount helper, evict_inode, and sops this port's. A rewrite with a carried body, since Linux redistributes `hammer2_mount()` across four `fs_context` callbacks |
| `hammer2_strategy.c` | 1338 | this port's; `hammer2_dedup_clear()` carried, both XOP handlers are floors |
| `hammer2_vnops.c` | 1397 | this port's; `->lookup` is upstream's `hammer2_lookup()` with the dcache's own cases and the nameiop pre-checks dropped, and the four operations tables have no BSD counterpart, a vnode taking its vop vector from the mount rather than from its type |
| `hammer2_ondisk.c` | 1030 | FreeBSD port; the volume-header verification half carried, the device half rewritten on `lookup_bdev()` and `bdev_file_open_by_path()`, and four functions not carried: `hammer2_lookup_device()` and the three GEOM access helpers |
| `hammer2_mount.h` | 58 | FreeBSD port, carried; `hammer2_chain.c` includes it |
| `hammer2_xxhash.h` | 60 | ours: the kernel's `xxh64()` under the core's `XXH64` name and HAMMER2's seed |
| `hammer2_io.c` | 1003 | hash and dedup halves carried; OS half written on the page cache |
| `hammer2_os.h` | 1174 | ours, the OS shim |
| `hammer2_compat.h` | 198 | ours, kernel look-alikes; the BSD `vtype` enum and the `MNT_WAIT` pair, which no Linux header has |
| `hammer2_rb.h` | 146 | FreeBSD port's `RB_SCAN`, carried |
| `sys/tree.h`, `sys/queue.h` | 2165 | vendored from freebsd-src, unchanged but for `__unused` |
| `sys/cdefs.h` | 36 | ours, three names the two vendored headers need |

## What has been verified

Eleven of the thirteen gates pass with no environment variables set on a
machine that has the kernel of record installed, as they have since
2026-08-26: the syntax gate finds that tree, and the style gate finds its
`checkpatch.pl`. The other two, `test-fixtures.sh` and `test-enospc.sh`,
report COULD-NOT-RUN there and on every machine without a guest, a set of
fixture images and a `KDIR` matching the guest's kernel, which is most of
them and all of CI.
What that unattended style run can say is narrower than it looks, and the
narrow half is the useful one: the found checker's `sha256` does not match
the baseline's, so an unchanged set is reportable and a moved set is not.
The gate exits 2 rather than charge a move to the code, which means the
one run that matters, the run after a carried file lands, needs
`CHECKPATCH` pointed at the checker the baseline names. That happened
twice on 2026-08-26. Saxum's delegator, which runs these same gates from another
repository, enumerates `script/test-*.sh` instead of naming them, so a gate
added here is picked up there without an edit. Each gate prints its own
count, and the gates are the authority; the dated figures below are snapshots
of one run.

`test-checkpatch.sh` is the one that commonly cannot run. It needs
`checkpatch.pl`, which no kernel headers package ships, so it exits 2 unless
`CHECKPATCH` or `KDIR` points at a full source tree. That is could-not-run,
not a pass.

- `script/test-shim.sh` and `script/test-syntax.sh`: 6 and 28 on 2026-08-26,
  two of the thirty-four being controls that must fail and do. The shim
  gate's sixth check is the one that reads its own coverage: an inline the
  driver never calls is barely checked by the compile, and the count says
  whether any are missed.
- `script/test-checkpatch.sh`: holds the style deviation set at its recorded
  856 hits under the checkpatch.pl the baseline names, and under the kernel
  of record's own patched copy, which differs by sha256 and produces an
  identical set. Neither figure travels without the checker that produced it;
  856 quoted bare reads as a mainline number and is not one. With no baseline
  present the gate refuses rather than writing one.
- `script/test-history.sh`: resolves every commit the roadmap's history
  table pins and checks its subject still matches, then prints how many
  commits touching `src/` or `script/` have landed since the newest row.
  That second half never fails, since whether a commit deserves a version row
  is a judgment.
- `script/test-inventory.sh`: the directory is the population, and three
  hand-maintained lists claim to cover it: the origin table in this file, the
  Makefile's `hammer2-y`, and the filenames `script/test-syntax.sh` names one
  by one. A `.c` missing from the second is dead code; missing from the third
  is a file no compiler ever sees while every check reports passing. It also
  checks the origin table's line count against the file, which is the column
  that rots on an ordinary edit, and two rows had drifted before the check
  existed. A count column that is not a number is left alone.

  `test/` is a second population, added 2026-08-26 after two vector files
  were found tracked and named in no document here. Every file there is now
  either named by a gate or listed in `README.testing.md`. Both vector files
  turned out to be compiled by a gate in Saxum, which no search of this
  repository could have said, so that table records a contract with a
  consumer this tree does not reference.

- `script/test-citations.sh`: every `file:line` citation in a `doc/` table
  resolves, and where the row names a symbol, that symbol is on the line. The
  64 KiB inventory is thirteen such rows and nothing had ever read them. A
  line number rots on the next edit while still looking like a citation, and
  the 0.2 import edits exactly those files. It compares against the source
  line, never a stored baseline, and a row naming no symbol is reported as
  unanchored rather than dropped.

That the gates pass means the shim is valid C in both knob positions, and
that `hammer2.h` and `hammer2_io.c` type-check against the real kernel
headers of the kernel of record with both clang and gcc.

It does not mean anything runs. `-fsyntax-only` compiles nothing and links
nothing, which is why the section above records what `make` does instead,
and why everything observed running, from the first mount to the round
trip, is in the sections that follow with the instrument that observed
it. The shipped build mounts read-write and remounts read-write from
read-only, and upstream's recovery is carried and runs on both paths.

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
that is not zero. Five runs since, 640 images, and every verdict in
them:

| run | images | mounted, all 44 files read | mounted, one or two files `EIO` | mounted, the listing cut short | refused | kernel report |
|---|---|---|---|---|---|---|
| seed 2, by hand | 100 | 36 | 43 | 2 (3 files listed, and 2) | 19 | 0 |
| seed 3, the script, with its two controls | 40 | 22 | 12 | 1 (0 files listed) | 5 | 0 |
| seed 1, before the bias | 60 | 56 | 0 | 0 | 4 | 0 |
| seed 4, after `hpanic` became `BUG()` | 100 | 36 | 52 (48 with one, 3 with two, 1 with three) | 1 (0 files listed) | 12 | 0 |
| seed 5, the generator that redraws | 100 | 45 | 42 (one each) | 1 (3 files listed, one `EIO`) | 13 | 0 |
| seed 6, the build with the reserve | 300 | 120 | 110 (107 with one, 3 with two) | 2 (0 files listed) | 68 | 0 |

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
rather than `EIO`. "No corruption has been seen" stood in this
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
- lockdep subclass exhaustion. `hammer2_chain_lockdep_nest()` clamps to
  `MAX_LOCKDEP_SUBCLASSES - 2`, and the one unclamped path,
  `hammer2_inode_lockdep_nest_under()`, reaches at most 7, which is
  legal.
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

The sync path's own returns are still dropped, and that is carried
and, on Linux, without consequence. The sync loop flushes each inode's
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
400 s. The upgrade is now one compare and swap on the semaphore's
count, DragonFly's `mtx_upgrade_try()` on Linux's word, with the layout
read back at module load; `README.porting.md` has the decision and the
one that supersedes it at 1.0. The guest was read from outside through
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
The run reads the file back with the source hash, zero kernel
warnings, both checkers clean with their negative controls. The
instrument's first two runs failed on their own readings before any
number was kept: the layout tool was called without its subcommand
and a long file name was looked up in the wrong block, each reading
zero blocks for both files, and the first read of each file after a
write went to the host's disk while the second hit the host's cache,
which read as a difference of ten times until a priming read was
added.

`O_DIRECT` stays unserved. DragonFly's `IO_DIRECT` means
semi-synchronous, set by the reserve check, and every read and write
there goes through the buffer cache because each block is checksummed
and possibly compressed on the way; a direct open falls back to
buffered I/O here as it does there.

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

That is one boot of a single-purpose root, not a distribution: nothing
here has run a service manager, a package manager or a shared-library
loader off the volume.

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

## What is not here

`hammer2_strategy.c`, `hammer2_vfsops.c` and `hammer2_vnops.c`. All
three are OS-facing and all three are rewrites. That is what makes them
the remaining three; it is not a claim that nothing in them can be read
off a BSD port. `hammer2_strategy.c` in particular has chain logic
around its buffer handling, and how much of that carries is a question
for the file, not for this list.

`hammer2_ioctl.c` was in this list until 0.7.0 and is not a rewrite: it
came from the FreeBSD port whole and carries fifteen `XXX`, which is
where the OS shows through rather than a reimplementation.

The carried set is eight files at 11,204 lines, measured against all three BSD
ports: `hammer2_chain.c`, `hammer2_flush.c`, `hammer2_freemap.c`,
`hammer2_bulkfree.c`, `hammer2_xops.c`, `hammer2_admin.c`,
`hammer2_cluster.c` and `hammer2_subr.c`. `hammer2_ondisk.c` landed on
2026-08-26 and is not in it: half of it is carried and the device half is
this port's, which is what `doc/provenance.csv` records as `derived`.
Whether `hammer2_inode.c` joins the carried set is what that same carry
column will say.

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

None of the three is exercised. The whole core type-checks under both
compilers with warnings as failures, which is what 0.2 claims and all it
claims; nothing here has run.

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

It is not free. `pr_cont` deliberately does not apply `pr_fmt`, so a `printf`
that opens a line prints without the module name. Every plain
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
macro can be right at both kinds of site, since the discriminator is whether
the previous call ended in a newline, which is a runtime fact.
The `DEFER` in `hammer2_os.h` names the only mapping that is right at
both: build the line in a buffer and emit it once, which is a core edit.

checkpatch flags `pr_cont` deliberately and by name, and the deviation is
recorded in `README.kernel-style.md`.

### `DEFER` markers: the deliberate floors and what lifts each one

An `XXX` marks a mapping a reader should distrust. A `DEFER` marks
something this port chose not to build yet, and the rule the tree follows
is that a deferral without a named trigger is rot rather than pragmatism,
so each one carries the condition that lifts it. `test-inventory.sh`
checks that every `DEFER(` in `src/` appears in this table and that the
table has no row for a marker that is gone, because a ledger nothing reads
against the source is the same shape as an empty one.

| where | marker, verbatim | what is deferred |
|---|---|---|
| `hammer2_os.h`, at `hpanic` | `DEFER(every hpanic site has an error its caller propagates)` | `hpanic()` calls `panic()` where Linux would mark the filesystem dead and refuse further I/O. The super_block to mark has existed since 0.4; the fifty-four sites in seven files are written as not returning, and each needs a return path before the macro can stop panicking. Reasoning in `README.porting.md` |
| `hammer2_os.h`, at the print macros | `DEFER(a message is seen interleaved in a real mount)` | `pr_cont` is not the right mapping at both kinds of site; the table above measures the trade. The fix is a line buffer, which is a core edit |
| `script/hammer2-provenance.py`, in the scope note | `DEFER(a userland file is imported into the module tree)` | the CSV generator walks the kernel core only. `sbin/hammer2`, makefs, libhammer2 and hammer2-utils are packaged separately and audited in the license audit's own tables, so `TREES` widens the day one of their files is carried into `src/` |
| `src/sys/fs/hammer2/Makefile`, at `CARRIED_CFLAGS` | `DEFER(the tree is prepared for submission)` | kbuild's `-Wimplicit-fallthrough=5` reads only the `fallthrough` attribute and upstream marks its switches with a `/* fall through */` comment, and kbuild's `-Wunused` sees `hammer2_inode_lock_temp_release()` and `_restore()`, whose only caller in either upstream is `hammer2_igetv()`, the one function this port rewrote on `iget5_locked()`, where the dance they perform has nothing to race against. They have no caller here and are not expected to gain one; they stay because deleting two functions from a carried file is a core edit. Both are suppressed on the carried files rather than edited into Linux spelling, because converting either early splits the core into two dialects. They become edits in the single conversion that also settles BSD style |
| `hammer2_vfsops.c`, at the module parameters | `DEFER(a second filesystem-wide knob wants a per-mount value)` | the tunables are `module_param_named()` under `/sys/module/hammer2/parameters/`, one value for every mount on the machine, which is what `sysctl` gave upstream too. A per-mount knob needs `/sys/fs/hammer2/`, where ext4 and btrfs put theirs |

The middle column is the marker as it is spelled in the source, because
that is what the gate matches on: a reworded trigger in either place is a
failure rather than a drift.

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

### `XXX` marks: how much of the core is not a carry

0.2's fourth exit criterion asks for this count. An `XXX` is the BSD ports'
mark for a mapping that is not mechanical, so the number says how many places
a reader should distrust. Counting raw occurrences answers the wrong
question, the carried files arriving with upstream's own. Measured 2026-08-26
against the FreeBSD port at
`3df307f` (v1.2.13), by file, ours minus upstream's:

| file | `XXX` | upstream's | this port's |
|---|---|---|---|
| `hammer2_chain.c` | 36 | 18 | 18 |
| `hammer2_freemap.c` | 6 | 6 | 0 |
| `hammer2_bulkfree.c` | 4 | 4 | 0 |
| `hammer2_xops.c` | 3 | 1 | 2 |
| `hammer2_io.c` | 3 | 2 | 1 |
| `hammer2_os.h` | 5 | 0 | 5 |
| `hammer2_flush.c` | 15 | 8 | 7 |
| `hammer2_subr.c` | 7 | 0 | 7 |
| `hammer2_cluster.c` | 0 | 0 | 0 |
| `hammer2_ondisk.c` | 21 | 1 | 20 |
| `hammer2_inode.c` | 28 | 6 | 22 |
| `hammer2_vfsops.c` | 46 | 7 | 38 |
| `hammer2_ioctl.c` | 18 | 3 | 15 |
| `hammer2_strategy.c` | 19 | 0 | 19 |
| `hammer2_vnops.c` | 2 | 0 | 2 |
| `hammer2.h` | 10 | 3 | 7 |
| `hammer2_disk.h` | 2 | 1 | 1 |
| `hammer2_admin.c` | 0 | 0 | 0 |
| `hammer2_compat.h` | 0 | 0 | 0 |
| `hammer2_ioctl.h` | 0 | 0 | 0 |
| `hammer2_mount.h` | 0 | 0 | 0 |
| `hammer2_rb.h` | 0 | 0 | 0 |
| `hammer2_xxhash.h` | 0 | 0 | 0 |
| `sys/tree.h` | 1 | 1 | 0 |

One hundred and sixty-four are this port's, the right-hand column
summed, and they fall in fourteen files: thirty-eight in `hammer2_vfsops.c`, twenty-two in `hammer2_inode.c`, twenty in `hammer2_ondisk.c`, nineteen in `hammer2_strategy.c`, eighteen in `hammer2_chain.c`, fifteen in `hammer2_ioctl.c`, seven in `hammer2_subr.c`, seven in `hammer2_flush.c`, seven in `hammer2.h`, five in `hammer2_os.h`, two in `hammer2_xops.c`, one in `hammer2_io.c`, one in `hammer2_disk.h`, and two in `hammer2_vnops.c`. That is the whole of them, and
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

`hammer2_admin.c`, `hammer2_freemap.c`,
`hammer2_xops.c`, `hammer2_bulkfree.c`, `hammer2_chain.c`,
`hammer2_cluster.c` and `hammer2_mount.h` are still byte-identical to that
upstream commit under `cmp`, so most of the carried core has no port edit
of any kind, marked or unmarked.

The table covers every `.c` and `.h` under `src/sys/fs/hammer2/` whatever
its count, and any file elsewhere under `src/` that holds a mark, so
`src/sys/sys/queue.h` is absent by the rule rather than missing from it
while its sibling `tree.h` has a row;
`test-inventory.sh` checks the total column against `grep -c` and both
directions of that population. It did not until 2026-08-26, and had
drifted in the way an ungated count does: `hammer2_disk.h` and
`src/sys/sys/tree.h` were missing while both carry a mark, and
`hammer2_cluster.c` was listed at zero, which is what made a partial table
read as an inventory. Neither omission moved the count, which was fifty-two when this was measured. The two marks that prompted this
are their authors': `hammer2_disk.h`'s first is Dillon's note on the
reserved area, present in the FreeBSD commit above, and `tree.h`'s is
FreeBSD's own `XXXLAS`, which the vendoring left alone. `hammer2_disk.h`
gained a second, this port's, when `->statfs` landed and needed an
`f_type`: `<uapi/linux/magic.h>` carries no entry for this filesystem, so
the constant is the high half of the volume identifier, which spells HAM2. The two remaining columns are a
subtraction against a tree that is not on most machines, so they are not
gated and carry their measurement date instead.

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

`hammer2_vfsops.c`'s sixteen are the largest set in the tree after
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

