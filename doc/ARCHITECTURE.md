# Architecture

How the DragonFly source is carried on Linux: what is carried, what is
shimmed, and where the boundary is. `doc/IO_MODEL.md` covers the I/O layer specifically; this is the
shape around it.

## System Topology and Data Flow

```
+-----------------------------------------------------------------------+
|                        Linux VFS                                      |
|   (open, read, write, mmap, ->fsync, ->freeze_fs, NFS file handles)   |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                 VFS entry points (the port's own half)                |
|   - hammer2_vfsops.c   (mount API, superblock operations)             |
|   - hammer2_vnops.c    (inode, file and address-space operations)     |
|   - hammer2_strategy.c (read_folio, readahead, strategy XOPs)         |
|   - hammer2_export.c   (export_operations, file handles)              |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                 DragonFly HAMMER2 core (carried)                      |
|   - hammer2_chain.c   (block reference tree, modify, lookup, delete)  |
|   - hammer2_inode.c   (inode lifecycle, direct data, PFS root create) |
|   - hammer2_flush.c   (topology flush, mirror_tid advancement)        |
|   - hammer2_freemap.c (block allocator)                               |
|   - hammer2_xops.c    (XOP backends, scanall)                         |
+-----------------------------------------------------------------------+
           |                                           |
           v                                           v
+-----------------------+                   +---------------------------+
| Synchronization pass  |                   | Cluster message core      |
|   - hammer2_synchro.c |                   |   - kern_dmsg.c (dmsg)    |
|   - .h2sync-src/-tgt  |                   |   - hammer2_iocom.c       |
|   - Lever 1a/1b walks |                   |   - hammer2_remote.c      |
|                       |                   |   - over a TCP socket     |
+-----------------------+                   +---------------------------+
           |                                           |
           +-----------------------+-------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                      Boundary I/O                                     |
|   - hammer2_io.c      (64 KiB physical buffers, dio hash)             |
|   - hammer2_ondisk.c  (device open, volume header verification)       |
+-----------------------------------------------------------------------+
                                   |
                                   v
+-----------------------------------------------------------------------+
|                   Linux block layer and storage                       |
|           (blkdev_issue_flush, submit_bio_wait, physical disks)       |
+-----------------------------------------------------------------------+
```

`hammer2_os.h` and `hammer2_compat.h`, the shim, sit beside the stack
rather than in it: `hammer2.h` includes them, so both halves are built
on them. The message core reads and writes its socket through the
shim's wrappers over `kernel_read()` and `kernel_write()`, not through
`hammer2_io`.

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
inside `hammer2_os.h` follows the other ports exactly, so this file and
theirs read side by side.

## The vendored headers must not collide with the kernel's

`src/sys/sys/queue.h` and `tree.h` are BSD's, and the kernel has its own
macros with the same names. Any collision is latent rather than loud:
`hammer2_io.c` includes kernel headers after the vendored ones, so a
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

`hammer2_chain` is the core's, carried byte for byte but the `XXX`
lines the origin table lists, and its lifetime is DragonFly's.

`hammer2_io` is the boundary object. It wraps one 64 KiB physical buffer and
is where the core's metadata meets Linux memory; the strategy write
path also hands the core a whole-block folio's address. See `doc/IO_MODEL.md`
for its lifetime, which is where the port's real design decisions are.

`hammer2_dev` holds the per-device state, the `struct file` for each
volume and the dio hash under its one `iohash_lock`, which
`doc/IO_MODEL.md` explains against DragonFly's lockless io layer. A
block device's lives from the first mount of a PFS on it to the last
unmount; a cluster link has one with no media, the connection device,
made at the link's first registration and freed after its last chain,
which the chain cache and the inode clusters can hold past the link. After each unmount `hammer2_kill_sb()`
prints the module's allocation counters, which describe the whole
module rather than that superblock; `test-enospc.sh` prints the line
when a run fails and asserts nothing on it.

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
`sx(9)` mapping sleeps too. An audit of the acquire sites found none
under an I/O completion; `script/hammer2-spin-audit.py` is the tool, and
no gate runs it over the tree, so a site added since is unaudited.

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

These three are the knobs a user builds with, and all three are
Kusumi's names from the other ports. Do not add one that none of them
has without saying why in the same commit. The Makefile also defines
test builds, which its comments say never to install and nothing
enforces, since `make install` installs the last module built:
`HAMMER2_LOCKDEBUG` for the fault and probe parameters,
`HAMMER2_CCMS_LOCKTEST`, `HAMMER2_CONNWAIT`, a delay, and negative
controls such as `HAMMER2_FOLIO_CONTROL` and the `HAMMER2_NO*` set,
each of which takes back a check so that a harness can show the check
is what passes it.

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
table has a row for every file here. The `DEFER` markers are collected
in that document's ledger, which
`test-inventory.sh` compares against the source in both directions.

