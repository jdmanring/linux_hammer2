# Architecture

How the DragonFly source is carried on Linux: what is vendored unchanged,
what is shimmed, and where the boundary is. `doc/IO_MODEL.md` covers the I/O layer specifically; this is the
shape around it.

## System Topology and Data Flow

```
+-----------------------------------------------------------------------+
|                        Linux VFS Layer                                |
|   (sys_open, sys_read, sys_write, sys_mmap, ->fsync, ->freeze_fs)     |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                    Linux / OS Shim Layer                              |
|   - hammer2_os.h      (locks, allocations, print primitives)          |
|   - hammer2_compat.h  (KKASSERT, atomics, kernel look-alikes)         |
|   - hammer2_export.c  (NFS export_operations & file handle mapping)   |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                 DragonFly BSD HAMMER2 Core                            |
|   - hammer2_chain.c   (block reference tree, modify, lookup, delete)  |
|   - hammer2_inode.c   (inode lifecycle, direct data, PFS root create) |
|   - hammer2_flush.c   (topology flush, mirror_tid advancement)        |
|   - hammer2_freemap.c (block allocator, ref-counts, recovery)         |
|   - hammer2_xops.c    (synchronous extended operations / scanall)     |
+-----------------------------------------------------------------------+
           |                                           |
           v                                           v
+-----------------------+                   +---------------------------+
| Synchronization Pass  |                   | Cluster Message Core      |
|   - hammer2_synchro.c |                   |   - kern_dmsg.c (dmsg)    |
|   - Snapshots (.src/.t)|                   |   - hammer2_iocom.c       |
|   - Lever 1a/1b walks |                   |   - hammer2_remote.c      |
|   - Lever 2 (prune)   |                   |   - XOP API (PROTO_2)     |
+-----------------------+                   +---------------------------+
           |                                           |
           +-----------------------+-------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                      Boundary I/O Layer                               |
|   - hammer2_io.c      (64 KiB physical buffers, dio hash, bvecs)      |
|   - hammer2_ondisk.c  (block device open, lookup_bdev, superblock)    |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                   Linux Block Layer & Storage                         |
|           (blkdev_issue_flush, submit_bio_wait, physical disks)       |
+-----------------------------------------------------------------------+
```

## The rule the whole port turns on

The filesystem core is DragonFly's and is kept readable as DragonFly's. The
Linux work lives in a shim beneath it, so that a diff against upstream shows
the port and not a rewrite, and so Kusumi can take a fix in either
direction.

Concretely: a change to `hammer2_chain.c` that upstream would not recognize
is a defect here even when it works. Where Linux and DragonFly disagree, the
shim absorbs it. Where the shim cannot, the site is marked `/* Linux */` on
the line and `XXX` if it is a compromise rather than a translation.

## Layers

    src/sys/fs/hammer2/     the filesystem, DragonFly's, minimally touched
    src/sys/fs/hammer2/hammer2_os.h      OS primitives: locks, malloc, print
    src/sys/fs/hammer2/hammer2_compat.h  kernel look-alikes: KKASSERT, atomics
    src/sys/sys/{queue,tree}.h           vendored BSD data structures

The two-file shim split is Kusumi's, from the FreeBSD and NetBSD ports, and
it is followed here rather than invented: `hammer2_compat.h` holds things
that look like DragonFly kernel facilities and are implemented on Linux
primitives, `hammer2_os.h` holds the primitives themselves. Section order
inside `hammer2_os.h` follows the other ports exactly, so the three read
side by side.

## The vendored headers must not collide with the kernel's

`src/sys/sys/queue.h` and `tree.h` are BSD's, and the kernel has its own
macros with the same names. Any collision is latent rather than loud:
`hammer2_io.c` includes four kernel headers after the vendored ones, so a
BSD definition is live for the rest of the translation unit and the break
appears somewhere unrelated to either file.

Two were found on 2026-08-25 by compiling with a second compiler and a
`W=1`-class warning set: `LIST_HEAD` and `RB_ROOT`, both real kernel macro
names, both actually used. They are `BSD_LIST_HEAD` and `BSD_RB_ROOT` now.
An earlier instance, `__unused`, had already been found the same way.

The rule this leaves: nothing in `src/sys/sys/` may define a name the kernel
defines. `script/test-syntax.sh` compiles with both compilers and fails on
any warning in a file under `src/`, which is what keeps the class closed.

## Object and lifetime model

Three objects matter and only one of them is ours.

`hammer2_chain` is the core's, unchanged, and its lifetime is DragonFly's.

`hammer2_io` is the boundary object. It wraps one 64 KiB physical buffer and
is the only place the filesystem meets Linux memory. See `doc/IO_MODEL.md`
for its lifetime, which is where the port's real design decisions are.

`hammer2_dev` holds the per-device state, the `struct file` for each
volume and the dio hash under its one `iohash_lock`, which
`doc/IO_MODEL.md` explains against DragonFly's lockless io layer. It
lives from the first mount of a PFS on the device to the last unmount,
and `hammer2_kill_sb()` prints what it left allocated, which the fleet
gates read as zero.

## Locking

`hammer2_mtx_t`, the chain lock and the inode lock, is DragonFly's `mtx`
carried as a primitive of the shim's own: the lock word in DragonFly's
layout, the exclusive bit over a count that is the shared holders or the
exclusive holder's depth, an owner, and one wait queue, annotated for
lockdep as a sleeping lock. It was a `rw_semaphore` inside a wrapper
until 0.9.6, and the wrapper was removed because the core asks three
things of this lock that a semaphore does not promise: who holds it,
an upgrade that turns the sole reader into the writer in one compare
and swap ahead of any queued writer, and recursion by the exclusive
holder. Each had been patched onto the semaphore separately as a mount
or a tree found it, and the upgrade ended up reading a count layout the
kernel keeps private, which is what made the semaphore go.
`README.porting.md`'s "Locks" section has the three answers that were
tried and why each fell.

Recursion is what DragonFly does: the exclusive holder's re-lock adds
one to the count, and a lock initialized without `hammer2_mtx_init_recurse()`
that recurses warns once and is admitted rather than hanging. The path
that needs it is `hammer2_chain_lookup()` returning the inode chain
itself for a DIRECTDATA inode, which the first buffered write to a
small file reached. The shared side does not recurse under an exclusive
hold, on DragonFly either.

`hammer2_spin_*` is a `rw_semaphore`, not a `spinlock_t`, as FreeBSD's
`sx(9)` mapping sleeps too; every acquire site was audited and none is
under an I/O completion.

## Build knobs

`HAMMER2_INVARIANTS` turns on `KKASSERT` and `KASSERTMSG`.
`HAMMER2_MALLOC` turns on the allocation leak counters.
`HAMMER2_ATIME` stores the atime a read stamps and reports it, rather than
the mtime in its place. HAMMER2 does not maintain atime, DragonFly returns
mtime for it and has its set path disabled, and all three BSD ports return
mtime unless this knob is set, which is why the default here does the same;
the knob here goes one step past theirs, since a build that reported the
stored atime without storing a read's read the create's back after every
remount.

All three are Kusumi's names from the other ports. Do not add a knob that
none of them has without saying why in the same commit.

## The mount, and what is deliberately not `get_tree_bdev()`

`hammer2_vfsops.c` is a rewrite with a carried body: FreeBSD's one
`hammer2_mount()` maps onto `->init_fs_context`, `->parse_param`,
`->get_tree` and a fill-super, with `MNT_UPDATE` split off to
`->reconfigure`. HAMMER2 spans up to `HAMMER2_MAX_VOLUMES` devices and
the carried `hammer2_open_devvp()` opens all of them with the superblock
as holder, so the port does not use `get_tree_bdev()`, which opens
exactly one device and takes `sb->s_bdev` for it; it follows btrfs, the
multi-device filesystem in tree, with `sget_fc()` and no `sb->s_bdev`.
The PFS half below the entry is DragonFly's and reads against the BSD
ports. The file's opening comment collects the differences.

`doc/README.status.md` is the authority on what is done, and its origin
table has a row for every file here. The `DEFER` markers, four at this
writing, are collected in that document's ledger, which
`test-inventory.sh` compares against the source in both directions.

## Visual Reference & Diagrams

### 1. System Topology and Data Flow
```
+-----------------------------------------------------------------------+
|                        Linux VFS Layer                                |
|   (sys_open, sys_read, sys_write, sys_mmap, ->fsync, ->freeze_fs)     |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                    Linux / OS Shim Layer                              |
|   - hammer2_os.h      (locks, allocations, print primitives)          |
|   - hammer2_compat.h  (KKASSERT, atomics, kernel look-alikes)         |
|   - hammer2_export.c  (NFS export_operations & file handle mapping)   |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                 DragonFly BSD HAMMER2 Core                            |
|   - hammer2_chain.c   (block reference tree, modify, lookup, delete)  |
|   - hammer2_inode.c   (inode lifecycle, direct data, PFS root create) |
|   - hammer2_flush.c   (topology flush, mirror_tid advancement)        |
|   - hammer2_freemap.c (block allocator, ref-counts, recovery)         |
|   - hammer2_xops.c    (synchronous extended operations / scanall)     |
+-----------------------------------------------------------------------+
           |                                           |
           v                                           v
+-----------------------+                   +---------------------------+
| Synchronization Pass  |                   | Cluster Message Core      |
|   - hammer2_synchro.c |                   |   - kern_dmsg.c (dmsg)    |
|   - Snapshots (.src/.t)|                   |   - hammer2_iocom.c       |
|   - Lever 1a/1b walks |                   |   - hammer2_remote.c      |
|   - Lever 2 (prune)   |                   |   - XOP API (PROTO_2)     |
+-----------------------+                   +---------------------------+
           |                                           |
           +-----------------------+-------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                      Boundary I/O Layer                               |
|   - hammer2_io.c      (64 KiB physical buffers, dio hash, bvecs)      |
|   - hammer2_ondisk.c  (block device open, lookup_bdev, superblock)    |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                   Linux Block Layer & Storage                         |
|           (blkdev_issue_flush, submit_bio_wait, physical disks)       |
+-----------------------------------------------------------------------+
```

### 2. DIO Lifetime Model
```
write folio (page cache, up to 64 KiB)
  |
  v
hammer2_io (one per 64 KiB physical buffer, dio hash under iohash_lock)
  |-- get: lookup_bdev read, buffer pinned for the I/O
  |-- dirty: block marked through the chain modify path
  |-- flush: blkdev_issue_flush, buffer written back, then released
  v
block device (physical storage)
```
*A `hammer2_io` lives from first reference to last put. Fleet gates verify zero allocations remain on unmount.*

### 3. Lock Hierarchy (Leaf to Root)
```
chain lock (per hammer2_chain, sleeping, lockdep subclass by level)
  < inode lock (per hammer2_inode, same primitive)
    < pfs lock (per PFS mount state)
      < mntlk (per hammer2_mnt, serializes mount, remount, cluster reconnect)
```
*Order is strictly bottom-up: a chain lock never nests outside an inode lock held at the same level.*

### 4. Cluster Stages (Local to Remote)
```
stage 1: span table (PROTO_2 announce, peer spans listed)
stage 2a: read XOP server (peer reads served from this host)
stage 2b: remote element (proxy chains, slave pass over the link)
stage 5:  kernel TLS on the link (peer admitted by key)
P8 lease: holder election, verified-at acknowledgment, demotion
```
