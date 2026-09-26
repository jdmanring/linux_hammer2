# Architecture

How the DragonFly source is carried on Linux: what is vendored unchanged,
what is shimmed, and where the boundary is. `doc/IO_MODEL.md` covers the I/O layer specifically; this is the
shape around it.

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
`HAMMER2_ATIME` turns on atime updates.

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
