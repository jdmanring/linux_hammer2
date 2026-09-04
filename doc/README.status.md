Status
======

The module mounts a HAMMER2 volume read-only, lists it and reads it. Every
file in a `makefs` fixture compares byte for byte with the tree it was
made from, across the sizes the code branches on, and so does every file
on media DragonFly itself created and wrote. LZ4 and ZLIB blocks decode
and symlinks resolve. Nothing can be written.
Getting here found and fixed two defects that no amount of compiling would
have caught, one a livelock and one a use after free. This file is the one to correct rather than to argue
with: if a claim here is stale, it is a defect.

## The build

The module builds, warning-clean, and loads. `make`
produces `src/sys/fs/hammer2/hammer2.ko`: thirteen objects, license
`Dual BSD/GPL`, alias `fs-hammer2`, no module dependencies. That is 0.3's
first criterion, and the second was exercised on 2026-09-03 on the
`fedora44` guest, at 7.2.3-300.fc45 and again at
7.3.0-0.rc0.260819gbd5f485f3f02: `insmod` returns 0, `/proc/filesystems`
lists `hammer2`, the reference count reads 0, `rmmod` returns 0 and
`/sys/module/hammer2` is gone afterwards. The log carries the two taint
lines an unsigned out-of-tree module always produces and nothing else.
What the criterion asks beyond that is unmeasured: no kernel measured so
far sets `CONFIG_DEBUG_KMEMLEAK` or `CONFIG_PROVE_LOCKING`.

It reached that state on 2026-09-02, in one day and two steps. The first
`make` ever run reported four undefined symbols out of modpost:
`hammer2_xop_strategy_read`, `hammer2_xop_strategy_write` and
`hammer2_dedup_clear`, which upstream defines in `hammer2_strategy.c`, and
`hammer2_vfs_sync_pmp`, which this port had declared and deliberately left
undefined. `hammer2_strategy.c` now exists with the dedup function carried
and both handlers as floors, and the sync is a floor too.

**Three of the module's entry points are floors**, and one of the three
is reachable: `hammer2_vfs_sync_pmp()` is called three times by
`hammer2_unmount()`, which `->kill_sb` reaches after a mount that
succeeds. The two strategy handlers are not, because no vnode operation
starts an XOP yet. Each floor warns once and fails; the `DEFER` ledger
below carries a row for each. A floor here is not a stub returning success:
`hammer2_vfs_sync_pmp()` is the one whose replacement was argued about,
because its two call sites discard the return value, so the warning is the
only channel it has. What the undefined symbol bought was a build nobody
could load; what the floor buys is a module that loads and says what it
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
findings below is evidence about locking.

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
lockdep in `hammer2_chain_lock()`, which is the single lockdep class
recorded below and not a finding about this code: lockdep cannot
distinguish a chain from its parent here, so a clean run would have meant
nothing either.

Nothing about the mount path itself failed. The device opened, the volume
header was read, the PFS was matched by label and a root inode was built,
all on code that had never executed.

Also observed, and not a defect: mounting without a label fails with
`PFS label "DATA" not found`, since `makefs` writes the label it is given
and the port defaults to `DATA` as upstream does. The failure path then
runs the recorded `->sync_fs` floor, which is why a `WARN_ONCE` and a
stack trace appear on a mount that merely named the wrong PFS.

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
still embedded. `hammer2_inode.c:1507` compares
`size > HAMMER2_EMBEDDED_BYTES`, strictly greater, so the bound is
inclusive and the pair that straddles it is 512 and 4096 rather than 511
and 512. The two small files test the same branch as each other, which is
the kind of claim a checksum cannot correct and a block count can. `dmesg` carries no
finding from this module, kmemleak reports nothing after a scan, and both
fixtures unmount and the module unloads with status 0.

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
and a `dmesg` holding only the two recorded floors.

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

## What is in the tree

| file | lines | origin |
|---|---|---|
| `hammer2.h` | 1367 | DragonFly, in the FreeBSD port's shape, OS-facing types rewritten |
| `hammer2_disk.h` | 1205 | DragonFly, carried; `struct uuid` defined locally |
| `hammer2_ioctl.h` | 221 | DragonFly, carried; `<linux/ioctl.h>`, `HAMMER2_MAXPATHLEN` pinned |
| `hammer2_admin.c` | 629 | FreeBSD port, carried byte-for-byte; the xop allocation zone is shimmed |
| `hammer2_freemap.c` | 1000 | FreeBSD port, carried byte-for-byte |
| `hammer2_xops.c` | 1449 | FreeBSD port, carried byte-for-byte |
| `hammer2_bulkfree.c` | 1239 | FreeBSD port, carried byte-for-byte; `printf` and `tsleep` shimmed |
| `hammer2_chain.c` | 4929 | FreeBSD port, carried byte-for-byte; the recursive lock is NetBSD's non-recursive answer, `pause` and `__diagused` shimmed |
| `hammer2_flush.c` | 1315 | FreeBSD port, carried; the device flush and the volume header write are the port decision below, marked `XXX` in place |
| `hammer2_cluster.c` | 188 | FreeBSD port, carried byte-for-byte; nothing in it touches the OS |
| `hammer2_subr.c` | 450 | FreeBSD port, carried; the timestamp, the signal check and the two `timespec64` signatures are marked `XXX` in place, and `hammer2_getnewfsid()` is not carried |
| `hammer2_inode.c` | 1707 | FreeBSD port; carried except the create path, which is `DEFER`red on the write path. `hammer2_igetv()` is this port's, written on `iget5_locked()` |
| `hammer2_vfsops.c` | 2078 | FreeBSD port; the PFS half and the recovery carried, the module entry, globals, mount path, mount helper, evict_inode, and sops this port's. A rewrite with a carried body, since Linux redistributes `hammer2_mount()` across four `fs_context` callbacks |
| `hammer2_strategy.c` | 499 | this port's; `hammer2_dedup_clear()` carried, both XOP handlers are floors |
| `hammer2_vnops.c` | 332 | this port's; `->lookup` is upstream's `hammer2_lookup()` with the dcache's own cases and the nameiop pre-checks dropped, and the four operations tables have no BSD counterpart, a vnode taking its vop vector from the mount rather than from its type |
| `hammer2_ondisk.c` | 998 | FreeBSD port; the volume-header verification half carried, the device half rewritten on `lookup_bdev()` and `bdev_file_open_by_path()`, and four functions not carried: `hammer2_lookup_device()` and the three GEOM access helpers |
| `hammer2_mount.h` | 58 | FreeBSD port, carried; `hammer2_chain.c` includes it |
| `hammer2_xxhash.h` | 60 | ours: the kernel's `xxh64()` under the core's `XXH64` name and HAMMER2's seed |
| `hammer2_io.c` | 944 | hash and dedup halves carried; OS half written on the page cache |
| `hammer2_os.h` | 799 | ours, the OS shim |
| `hammer2_compat.h` | 166 | ours, kernel look-alikes; the BSD `vtype` enum and the `MNT_WAIT` pair, which no Linux header has |
| `hammer2_rb.h` | 146 | FreeBSD port's `RB_SCAN`, carried |
| `sys/tree.h`, `sys/queue.h` | 2165 | vendored from freebsd-src, unchanged but for `__unused` |
| `sys/cdefs.h` | 36 | ours, three names the two vendored headers need |

## What has been verified

Eleven of the twelve gates pass with no environment variables set on a
machine that has the kernel of record installed, as they have since
2026-08-26: the syntax gate finds that tree, and the style gate finds its
`checkpatch.pl`. The twelfth is `test-fixtures.sh`, which reports
COULD-NOT-RUN there and on every machine without a guest, a set of fixture
images and a `KDIR` matching the guest's kernel, which is most of them and
all of CI.
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
headers of a 7.2 tree with both clang 22 and gcc.

It does not mean anything runs. `-fsyntax-only` compiles nothing and links
nothing, which is why the section above records what `make` does instead.
The module has not been loaded and there is no fsck integration, so
nothing here has been observed running. The VFS layer and the mount path
exist: `hammer2_get_tree()` probes the device, reads the super-root,
builds a root dentry and returns success. It refuses a read-write mount,
and refuses the read-write remount too: upstream's recovery is carried and
called, but it writes and has never been run, which is what
`DEFER(recovery is exercised on a device)` names.

## The version floor, and how it was established

`BLK_MAX_BLOCK_SIZE` is the binding constraint, at **6.15**. Each symbol
was dated by reading the header at the tag rather than from memory:

| symbol | absent at | present at |
|---|---|---|
| `bdev_file_open_by_path` | | v6.10 |
| three-argument `kvrealloc` | v6.11 | v6.12 |
| `folio_mark_dirty_lock` | v6.12 | v6.13 |
| `BLK_MAX_BLOCK_SIZE` | v6.14 | v6.15 |
| `struct sha256_ctx` | v6.16 | v6.17 |
| `inode_state_read_once` | v6.18 | v6.19 |
| `kzalloc_obj` | v6.19 | v7.0 |

`inode_state_read_once()` is the one that moved the other way. It is used
in `hammer2_igetv()` and is four releases above the floor, so the module
could not build on 6.15 through 6.18 at all, failing as an implicit
declaration in the middle of a build rather than at the `#error` that
exists to say so. `hammer2_os.h` defines it as `READ_ONCE()` below 6.19,
where `i_state` is a scalar rather than a struct behind accessors: `u32`
at v6.15, v6.16 and v6.17, `enum inode_state_flags_t` at v6.18.

`kzalloc_obj()` is the second of the same kind and was found the same way,
by CI failing to build at 6.17. Both were then swept for at once rather
than chased one CI round-trip at a time, by `script/floor-symbols.py`: it
resolves every identifier called in `src/sys/fs/hammer2` that the tree
does not define itself, sixty-one of them, against a floor tree's
`include/`. Two were missing, and both are the two above. It resolves a
name, so a function whose signature changed while keeping its name is
invisible to it, and it bounds this class rather than closing it. It is
not a gate: it needs a 6.15 tree, which is a download rather than
something a workstation has, so it is run when the floor moves or a file
lands. The three names the vendored `queue.h` and `tree.h` call that the
kernel does not provide, `atomic_load_ptr()`, `fprintf()` and `abort()`,
sit in macros this tree never expands.

`kzalloc_obj()`'s guard is `#ifndef` rather than a version comparison,
because stable series backport it: Arch's 6.18.46 has it where mainline
v6.18 does not, and the version guard redefined it there. Where the kernel
spells a facility as a macro, asking whether the macro exists is the exact
question.

6.15 is the floor the code requires, and since 2026-09-03 CI builds it: a
second job fetches the 6.15 tarball, builds the kernel once and caches the
tree on the tag, then links this module against it. The module links
warning-clean there, against a `Module.symvers` carrying 12591 symbols, on
a tree that reports 6.15.0. Both numbers are printed by the job on every
run rather than recorded here alone.

Until that job existed nothing had ever compiled against the floor. The
lowest build in the world was 6.17, two releases above the kernel the
`#error` in `hammer2_os.h` names, and the floor was an assertion. Its first
run found what an assertion hides: `SHA256_CTX` was typedef'd to `struct
sha256_ctx`, which the kernel called `struct sha256_state` until 6.17. The
function names and their argument order are identical across that rename,
so `script/floor-symbols.py` resolved all three and reported nothing. Name
resolution cannot see a type, which is the gap between what that sweep
bounds and what this job closes.
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
| **7.2.0-cachyos**, the kernel of record | **7 checks, 0 failed, both compilers, no override** |
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

## What is not here

`hammer2_strategy.c`, `hammer2_ioctl.c`, `hammer2_vfsops.c`,
`hammer2_vnops.c`. All four are the OS-facing ones and all four are
rewrites. That is what makes them the remaining four; it is not a claim
that nothing in them can be read off a BSD port. `hammer2_strategy.c` in
particular has chain logic around its buffer handling, and how much of
that carries is a question for the file, not for this list.

The carried set is eight files at 11,204 lines, measured against all three BSD
ports: `hammer2_chain.c`, `hammer2_flush.c`, `hammer2_freemap.c`,
`hammer2_bulkfree.c`, `hammer2_xops.c`, `hammer2_admin.c`,
`hammer2_cluster.c` and `hammer2_subr.c`. `hammer2_ondisk.c` landed on
2026-08-26 and is not in it: half of it is carried and the device half is
this port's, which is what `doc/provenance.csv` records as `derived`.
Whether `hammer2_inode.c` joins the carried set is what that same carry
column will say.
`hammer2_strategy.c`, `hammer2_ioctl.c`, `hammer2_vfsops.c` and
`hammer2_vnops.c` are the OS-facing ones and are rewrites.

`hammer2_chain.c` landed on 2026-08-26 and the lock recursion it forced is
decided, following the NetBSD port: there is no recursive lock. A Linux
`rw_semaphore` deadlocks against its own holder exactly as a NetBSD
`krwlock` does, so `hammer2_mtx_init_recurse()` is a plain init in the
shim and the one path that recursed is closed instead of accommodated.
That path is `hammer2_chain_lookup()` reaching `chain->lock` again for an
inode in DIRECTDATA mode; NetBSD closes it by never setting
`HAMMER2_OPFLAG_DIRECTDATA`, which costs a data block for a tiny file and
costs no correctness. This port sets the flag nowhere at all, because its
only setter was in `hammer2_inode_create_normal()`, which is not carried.

That closes the creation half. It does not close the reading half, and
the wording here said otherwise until 2026-08-26: the flag lives in the
on-disk inode, so a filesystem written by DragonFly or by a BSD port has
DIRECTDATA inodes in it whoever mounts them, and the lookup reads the flag
off the media. Reading a small file on a foreign filesystem is therefore
an open question for the read-only mount at 0.4.
`doc/README.porting.md` has the reading it rests on, which is a reading
and not a run.

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
| `hammer2_os.h`, at `hpanic` | `DEFER(the VFS layer lands, giving a super_block to mark)` | `hpanic()` calls `panic()` where Linux would mark the filesystem dead and refuse further I/O. Reasoning in `README.porting.md` |
| `hammer2_os.h`, at the print macros | `DEFER(a message is seen interleaved in a real mount)` | `pr_cont` is not the right mapping at both kinds of site; the table above measures the trade. The fix is a line buffer, which is a core edit |
| `hammer2_inode.c`, where `hammer2_inode_create_normal()` would be | `DEFER(the write path is written, after hammer2_vnops.c)` | the create path, which is `struct vattr`, `struct ucred`, `VNOVAL`, `groupmember()` and `priv_check_cred()`, and which carries NetBSD's `#if 0` around the `DIRECTDATA` assignment when it lands |
| `hammer2_vfsops.c`, at three sites: the read-write refusal in `hammer2_get_tree()`, `hammer2_reconfigure()`, and the recovery call before `hammer2_update_pmps()` | `DEFER(recovery is exercised on a device)` | upstream's `hammer2_recovery()`, `hammer2_recovery_scan()` and `hammer2_fixup_pfses()` are carried and called where upstream calls them, so the code exists. What has not happened is running them: they WRITE, through `hammer2_freemap_adjust()` with `DORECOVER`, `hammer2_chain_modify()` and `hammer2_flush()`, and nothing has been loaded. Until they are exercised on a device carrying an interrupted flush, both refusals stay: `hammer2_get_tree()` returns `EROFS` before the device is opened, and `hammer2_reconfigure()` returns it for the remount that would otherwise arrive at the same state sideways, since `reconfigure_super()` applies `SB_RDONLY` whether or not the operation is present. All three sites lift together. The real `->reconfigure` is upstream's `hammer2_remount_impl()`, which is not carried and which runs these two a second time on the read-only to read-write transition |
| `script/hammer2-provenance.py`, in the scope note | `DEFER(a userland file is imported into the module tree)` | the CSV generator walks the kernel core only. `sbin/hammer2`, makefs, libhammer2 and hammer2-utils are packaged separately and audited in the license audit's own tables, so `TREES` widens the day one of their files is carried into `src/` |
| `hammer2_vfsops.c`, at `hammer2_vfs_sync_pmp()` | `DEFER(->sync_fs lands)` | the floor warns once and returns `EOPNOTSUPP`, and both call sites discard the value. It replaced a symbol deliberately left undefined, which made the absence visible at link time and also made the module unloadable. An unmount that does not sync loses nothing while nothing can be written; on the day the write path lands this is a data-loss bug rather than a deferral |
| `hammer2_strategy.c`, at `hammer2_xop_strategy_write()` | `DEFER(the write path lands: 0.5)` | the body is upstream's handler and the six statics beneath it, `hammer2_assign_physical()` through `hammer2_write_bp()`, plus `hammer2_dedup_record()` and `hammer2_dedup_lookup()`. Deferred because a read-only milestone that can write is not one |
| `src/sys/fs/hammer2/Makefile`, at `CARRIED_CFLAGS` | `DEFER(the tree is prepared for submission)` | kbuild's `-Wimplicit-fallthrough=5` reads only the `fallthrough` attribute and upstream marks its switches with a `/* fall through */` comment, and kbuild's `-Wunused` sees `hammer2_inode_lock_temp_release()` and `_restore()`, whose only caller in either upstream is `hammer2_igetv()`, the one function this port rewrote on `iget5_locked()`, where the dance they perform has nothing to race against. They have no caller here and are not expected to gain one; they stay because deleting two functions from a carried file is a core edit. Both are suppressed on the carried files rather than edited into Linux spelling, because converting either early splits the core into two dialects. They become edits in the single conversion that also settles BSD style |
| `hammer2_vfsops.c`, at the module parameters | `DEFER(a second filesystem-wide knob wants a per-mount value)` | the tunables are `module_param_named()` under `/sys/module/hammer2/parameters/`, one value for every mount on the machine, which is what `sysctl` gave upstream too. A per-mount knob needs `/sys/fs/hammer2/`, where ext4 and btrfs put theirs |
| `hammer2_os.h`, at `hammer2_mtx_init()` | `DEFER(chain locks carry nesting notation)` | every chain lock takes its lockdep class from that one `init_rwsem()` call site, so locking a parent chain and then its child is indistinguishable from taking one lock twice. The first mount under `CONFIG_PROVE_LOCKING` reports `possible recursive locking` and names the cause: `May be due to missing lock nesting notation`. Lockdep then sets `debug_locks` to 0 and validates nothing further that boot, so this warning costs the instrument rather than only printing. A `_nested` acquire needs a subclass, and what to key it on is measured: a chain carries no level or depth field, and `bref.type` has ten values of which eight can hold a lock, exactly `MAX_LOCKDEP_SUBCLASSES`, but `hammer2_chain.c` walks parents with a `while` loop over `INDIRECT` and `FREEMAP_NODE`, so those two nest within themselves and a type-keyed subclass returns the same report. The notation needs a depth the chain does not carry, which makes it a core edit |
| `hammer2_ondisk.c`, at `hammer2_bdev_open()` | `DEFER(7.3 ships a released -rc)` | the guard that chooses between `bdev_file_open_by_path()` with the kernel's `fs_holder_ops` and 7.3's `fs_bdev_file_open_by_path()` was measured against a merge-window snapshot, `7.3.0-0.rc0.260819gbd5f485f3f02`, and not a released candidate. Those names can still move before 7.3 final, so the comparison is re-measured against the release and pinned to what it shipped |

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
| `hammer2_chain.c` | 18 | 18 | 0 |
| `hammer2_freemap.c` | 6 | 6 | 0 |
| `hammer2_bulkfree.c` | 4 | 4 | 0 |
| `hammer2_xops.c` | 1 | 1 | 0 |
| `hammer2_io.c` | 4 | 2 | 2 |
| `hammer2_os.h` | 8 | 0 | 8 |
| `hammer2_flush.c` | 13 | 8 | 5 |
| `hammer2_subr.c` | 7 | 0 | 7 |
| `hammer2_cluster.c` | 0 | 0 | 0 |
| `hammer2_ondisk.c` | 20 | 1 | 19 |
| `hammer2_inode.c` | 25 | 6 | 19 |
| `hammer2_vfsops.c` | 23 | 7 | 16 |
| `hammer2_strategy.c` | 1 | 0 | 1 |
| `hammer2_vnops.c` | 0 | 0 | 0 |
| `hammer2.h` | 7 | 3 | 4 |
| `hammer2_disk.h` | 2 | 1 | 1 |
| `hammer2_admin.c` | 0 | 0 | 0 |
| `hammer2_compat.h` | 0 | 0 | 0 |
| `hammer2_ioctl.h` | 0 | 0 | 0 |
| `hammer2_mount.h` | 0 | 0 | 0 |
| `hammer2_rb.h` | 0 | 0 | 0 |
| `hammer2_xxhash.h` | 0 | 0 | 0 |
| `sys/tree.h` | 1 | 1 | 0 |

Seventy-eight are this port's, the right-hand column summed, and they
fall in nine files: nineteen in `hammer2_ondisk.c`, seventeen in
`hammer2_inode.c`, sixteen in `hammer2_vfsops.c`, seven in
`hammer2_subr.c`, eight in `hammer2_os.h`, five in `hammer2_flush.c`,
four in `hammer2.h`, two in `hammer2_io.c` and one in
`hammer2_strategy.c`. That is the whole of them, and it is the only place
in this file that adds up to the column.

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

