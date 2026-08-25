Porting notes
=============

The decisions a reader of the source will want justified, in one place so
the headers can stay terse.

## The shape

The three BSD ports carry the DragonFly core and put every OS difference
in `hammer2_os.h` and `hammer2_compat.h`. This port does the same, with
the same file names, the same section order and the same symbol names, so
that a person who knows one of those trees can read this one. Where a
mapping is not mechanical it is marked `XXX` in place, as they do.

`hammer2.h` follows the FreeBSD port rather than DragonFly directly,
because that port already performs the surgery every port repeats: the
dmsg/iocom/ccms cluster layer deleted, the XOP thread pool replaced by
synchronous XOPs, the vnode-lifecycle gates.

## Locks

`hammer2_spin_*` is a `rw_semaphore`, not a `spinlock_t`. FreeBSD maps the
family onto `sx(9)`, which sleeps, so this is not a Linux liberty. All 62
port-relevant acquire sites were audited: none sleeps under the lock, and
none is reachable from an I/O completion path, because the strategy code
takes no spin lock at all and `hammer2_io.c`'s are on the submission side
of the DIO hash. If a future change puts one under `bi_end_io`, the
typedef is the thing that has to move.

`hammer2_mtx_owned()` has no Linux primitive. `rwsem_is_locked()` says
whether a lock is held and never by whom, and the core asks the second
question, so the wrapper tracks the owning task itself. FreeBSD gets this
from `sx_xlocked()` for free.

`hammer2_mtx_upgrade_try()` has no Linux primitive either, and the
omission is deliberate upstream: `downgrade_write()` exists and no upgrade
does, because upgrading a lock two readers hold can only succeed by
deadlocking one of them. So it fails unless the caller already holds the
lock exclusively. That is safe by the shape of the interface: every caller
of a `_try` handles failure, and the core's failure path drops and
re-acquires exclusively, revalidating what it read. OpenBSD unlocks and
retries for the same reason.

Recursion is the remaining gap. DragonFly and FreeBSD allow the inode and
chain locks to recurse; a Linux `rw_semaphore` deadlocks against itself
and lockdep says so. NetBSD has the same problem and solves it at the two
call sites rather than in the shim, and this port will follow NetBSD
there when those files land.

## The DIO layer

On the BSDs a `hammer2_io` holds a `struct buf *`, and the DIO layer
decides when it is written and released. Here the mount calls
`sb_set_blocksize(sb, HAMMER2_PBUFSIZE)`, which reaches
`mapping_set_folio_min_order()` on the block device's mapping, so every
folio in that mapping is a 64KB folio and one `hammer2_io` holds exactly
one. Caching, writeback, readahead and reclaim belong to the page cache;
this file holds a folio reference for the life of `DIO_GOOD`, dirties it
on a dirty last drop, and kicks writeback on `DIO_FLUSH`. The DIO hash
therefore caches metadata and no longer owns memory.

`hammer2_io_data()` hands the core a pointer it keeps across sleeps, so
the folio must be permanently mapped: `folio_address()`, not
`kmap_local_folio()`. True on every 64-bit target; a 32-bit HIGHMEM
kernel would need mapping around every access, and a `static_assert`
refuses that build rather than corrupting quietly.

`HAMMER2_PBUFSIZE` sits exactly on `BLK_MAX_BLOCK_SIZE`, which is 64KB
only under `CONFIG_TRANSPARENT_HUGEPAGE`. Without it the mount fails
`EINVAL` saying nothing about why, so a second `static_assert` moves that
to the build.

## Types and conventions

Errnos inside the module are **positive**, the BSD convention the carried
core assumes (`hammer2_chain.c` returns `EAGAIN` bare). The VFS entry
points negate at the boundary, and `hammer2_io.c` negates what the page
cache returns. `hammer2_error_to_errno()` therefore returns a positive
value and its callers negate.

`hammer2_inode` keeps the FreeBSD port's *pointer* to the VFS object,
reached the other way through `i_private`, rather than embedding `struct
inode`. Embedding is the Linux idiom and saves an allocation, but it would
hand the lifetime to `alloc_inode`/`evict`, and the core creates inodes
before any VFS object exists and after it is gone.

`<sys/uuid.h>` gives the BSDs the DCE 1.1 `struct uuid`. The kernel's
`<linux/uuid.h>` defines an unrelated opaque `uuid_t` and no `struct
uuid`, and the core reaches `uuid->node[2]` by name, so the BSD layout is
defined in `hammer2_disk.h` and checked by size assertions.

`RB_*` and `TAILQ_*` come from `sys/tree.h` and `sys/queue.h`, vendored
from freebsd-src. Linux's `rbtree.h` is a different interface and the core
has twelve `RB_` sites in `hammer2_chain.c` alone; converting them turns a
carry into a rewrite for no gain. The `makefs` port vendors the same two
files for the same reason.

The one edit to those vendored files is that `__unused` is spelled
`__always_unused`. `__unused` is a *field name* in the Linux uapi headers
(`struct stat`, `struct icmphdr`, `struct __sysctl_args`); defining it as
an attribute macro makes an array field so declared a compile error and a
scalar one vanish with only a warning, silently changing the struct's
layout.
