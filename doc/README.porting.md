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
deadlocking one of them.

This paragraph used to argue that a wrapper which fails unless the caller
already holds the lock exclusively is safe by the shape of the interface,
every caller of a `_try` handling failure and re-acquiring. The first
mount disproved it. `hammer2_chain_unlock()` takes the shared path, asks
for an upgrade and retries on refusal, so a wrapper that could never grant
one made the first read of a file spin without end, unkillable, holding
the mount until the guest was rebooted. A predicate is not an
implementation, and the interface's shape was an argument for not writing
one.

It now releases the read side and takes the write side, restoring the
caller's shared hold when it cannot, which is what the OpenBSD port does
at the same place. The window between the two is real and is what the
caller revalidates after.

Recursion was decided twice. The first decision followed NetBSD: a Linux
`rw_semaphore` deadlocks against its own holder as a NetBSD `krwlock`
does, so `hammer2_mtx_init_recurse()` was a plain init and the one path
that recursed was to be closed at its call site. That held for every
read, because the reading side of that path arrives with
`HAMMER2_RESOLVE_LOCKAGAIN` and is credited rather than re-acquired (the
`hammer2_mtx_sh_again()` note in `hammer2_os.h`).

The first buffered write reversed it. `hammer2_chain_lookup()`, under
`hammer2_assign_physical()` in the write XOP, returns the inode chain
itself, locked a second time and exclusively, for an inode in DIRECTDATA
mode, where the inode's own block holds the file's data. The caller
already holds that chain exclusively. Lockdep reported `possible
recursive locking` on `h2ch_inode/2` at that line, the writeback worker
sat in `rwsem_down_write_slowpath` against itself, and `sync` never
returned. DragonFly's `mtx` counts a second exclusive acquire by its
holder (`kern_mutex.c`, `__mtx_lock_ex`), and the FreeBSD port keeps that
by initializing the chain lock and the inode lock with `SX_RECURSE`. The
shim now does what the FreeBSD port does: the two locks initialized with
`hammer2_mtx_init_recurse()` carry a depth, `hammer2_mtx_ex()` by the
owner increments it without touching the rwsem, and `hammer2_mtx_unlock()`
releases the rwsem at depth zero. Lockdep is told nothing about the inner
acquires, which is exact, since they are one hold. A lock initialized with
`hammer2_mtx_init()` that recurses warns once and is admitted, where sx
without `SX_RECURSE` would panic; the alternative is the hang. The shared
side does not recurse under an exclusive hold, on DragonFly either.

The DIRECTDATA flag itself is on disk, so a filesystem written by
DragonFly or a BSD port has such inodes whoever mounts it, and the lookup
reads the flag off the media. NetBSD's `#if 0` around the flag's setter
in `hammer2_inode_create_normal()` is therefore not needed here and will
not be carried with that function; the setter is what DragonFly does.

## The DIO layer

On the BSDs a `hammer2_io` holds a `struct buf *`, and the DIO layer
decides when it is written and released. Here `hammer2_open_devvp()` calls
`set_blocksize(bdev_file, HAMMER2_PBUFSIZE)` on each device as it opens it,
which reaches
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

That assert is a bootstrap instrument and not the intended one. The kernel
supplies `mapping_max_folio_size_supported()` (`linux/pagemap.h`), whose
own comment reads: "The filesystem should call this function at mount time
if there is a requirement on the folio mapping size in the page cache." It
returns `PAGE_SIZE` without `CONFIG_TRANSPARENT_HUGEPAGE` and
`1U << (PAGE_SHIFT + MAX_PAGECACHE_ORDER)` with it, so the compile-time
test reaches the correct answer on today's kernels by asking the wrong
question: it reads a config symbol where the kernel offers a capability.

**The mount path must call it and refuse by name**, rather than inheriting
a build-time assert. The block layer's own direction is to derive the
ceiling from the maximum supported folio size rather than from a THP test,
so "THP required" is a fact about a range of releases and not an
architecture. The range is 6.16 through 7.3-rc1, measured by reading
`include/linux/blkdev.h` at each tag: v6.15 defines `BLK_MAX_BLOCK_SIZE`
as `SZ_64K` unconditionally, and v6.16 is the first to put it behind
`#ifdef CONFIG_TRANSPARENT_HUGEPAGE` with `PAGE_SIZE` on the other side.
Every release the floor admits needs the option. What must never happen is silently splitting one HAMMER2
physical buffer, which would change on-disk semantics.

## The device layer

`hammer2_ondisk.c` landed on 2026-08-26 and is the first file where the OS
half was rewritten rather than carried. FreeBSD reaches the device through
GEOM: `namei()` resolves a path to a vnode, `vn_isdisk_error()` checks it
is a disk, `VOP_ACCESS()` checks the permission, and `g_vfs_open()` later
attaches a consumer. Linux has one call that does the first three,
`bdev_file_open_by_path()`, and it opens as well as resolves.

That collapses two functions and splits one differently:

- `hammer2_lookup_device()` is not carried. It is the three checks the one
  Linux call already performs.
- `hammer2_init_devvp()` here parses the colon-separated device list and
  records paths, opening nothing. `hammer2_open_devvp()` does the opening.
  FreeBSD splits it the other way, holding a vnode reference from `init`
  and calling `g_vfs_open()` from `open`. The `struct super_block *` the
  header declares on `init_devvp` is unused and kept so the four trees read
  side by side. The error reporting moved with the resolution: FreeBSD
  diagnoses a bad device path in `init_devvp`, and here nothing in that
  function can fail, so a bad path is diagnosed at open.
- `hammer2_gaccess_devvp()`, `hammer2_getw_devvp()` and
  `hammer2_putw_devvp()` are not carried. They adjust a GEOM consumer's
  write count around a volume-header write. Linux states the access it
  wants once, as a `blk_mode_t` at open time, and has nothing to adjust
  afterwards.
- `hammer2_access_devvp()` is declared in the carried `hammer2.h` and so
  has a body, but not FreeBSD's. `VOP_ACCESS()` plus
  `priv_check(PRIV_VFS_MOUNT_PERM)` asks two questions Linux answered
  earlier: the mount capability before `->get_tree()` ran, and the device
  permission inside `bdev_file_open_by_path()`. What is left is whether
  the file that call returned is open for writing, which is what a caller
  passing `rdonly == 0` means.

The holder passed to the open is the superblock and the holder ops are the
kernel's own `fs_holder_ops`, which is what every in-tree filesystem
passes and what makes the device's freeze, sync and `mark_dead` callbacks
reach a mounted filesystem at all.

Two reads replace GEOM provider fields: `bdev_logical_block_size()` for
the sector-size check `hammer2_open_devvp()` inherits from FreeBSD, and
`bdev_nr_bytes()` for the media size that both `hammer2_read_volume_header()`
and `hammer2_verify_volumes_common()` compare volume sizes against.

`hammer2_read_volume_header()` runs before any `hammer2_dev_t` exists, so
it cannot use the DIO layer. It reads the same block device page cache
directly with `read_mapping_folio()`, which is legal for the same reason
the DIO layer's reads are: process context, and the mapping's minimum
folio order already set. It also length-checks the folio it gets, for the
same reason `hammer2_io_folio_check()` does.

The kernel has no in-kernel uuid formatter or parser of the shape the BSDs
use. `snprintf_uuid(9)` appears twice in this file, once to compare the
filesystem type uuid against `HAMMER2_UUID_STRING` and once to print a
mismatch. The comparison is done as bytes against a `static const struct
uuid` spelled out beside the string it equals, and both print paths use
the kernel's `%pUl` extension, which reads the DCE layout `struct uuid`
already has.

## Reading the kernel, not guessing at it

The kernel tree of record on this machine is a headers package: the
`include/` hierarchy is complete and the `fs/` and `block/` directory
skeletons are there, but no `.c` file is. Both trees present were checked
on 2026-08-26 and neither ships one.

That is a fact about the tree and not about the question. Every one of
those files is published at the tag `KERNEL_REF` names, so a question
about what a kernel function actually does is answerable in one fetch,
and the answer is the kernel of record's rather than a nearby version's.
Three questions were settled that way the same day: whether HAMMER2 can
mount through `get_tree_bdev()` (`fs/super.c`, `fs/btrfs/super.c`),
whether `M_WAITOK` can be made not to fail (`mm/slub.c`), and whether
`bdev_file_open_by_path()` reflects `BLK_OPEN_WRITE` into `f_mode`
(`block/bdev.c`, `fs/file_table.c`). The last had been a `DEFER` on the
grounds that the file could not be read.

So: a question about kernel behavior is not a `DEFER` candidate merely
because the source is not on disk. Compiling proves a field exists and
never what sets it, and reading a BSD port proves what BSD does. Cite the
file and the tag in the comment, as those sites do, since a reading from
an unnamed version is worth about as much as a guess.

## Types and conventions

Errnos inside the module are **positive**, the BSD convention the carried
core assumes (`hammer2_chain.c` returns `EAGAIN` bare). The VFS entry
points negate at the boundary, and `hammer2_io.c` negates what the page
cache returns. `hammer2_error_to_errno()` therefore returns a positive
value and its callers negate.

One value does not cross the boundary unchanged. Upstream maps a check
code mismatch, and any error it has no name for, to `EDOM`, and
DragonFly's `read(2)` hands that to the caller. Linux's `read(2)` has no
such value: a block that failed its checksum is `EIO` to every filesystem
in the tree, and `EDOM` out of a read presents as a libm failure to
anyone who sees it. `hammer2_vfs_errno()` in `hammer2_os.h` translates
`EDOM` to `EIO` and negates, and every entry point the VFS calls returns
through it, lookup, readdir, the folio read and the root inode at mount,
so a corrupted directory block presents the same way a corrupted data
block does. The core keeps its own mapping, which is the pattern for
every such difference: the carried function stays upstream's and the
Linux entry point owns what Linux sees. Measured on `f9`, the fixture
with one data byte altered: before the translation `cat` reported
"Numerical argument out of domain"; after it, "Input/output error", with
`hammer2_chain_testcheck` naming the block in `dmesg` both times.

`hammer2_xop_strategy` carries a `struct folio *` where the BSD ports carry
a `struct buf *`. The initial import wrote `struct bio *` there, taken from
the H0 API map's row pairing BSD's `struct bio` with Linux's, which is a
mapping by name. The field is the destination of a logical file read, and
no caller that can produce this xop has a bio to put in it: `->read_folio`
is handed a folio and `->writepages` iterates them. A `bio` is the block
layer's request object, which is the layer beneath `hammer2_io.c`, not the
one above it. Nothing had used the field, so this cost nothing to correct;
it is recorded because the same reasoning applies to every remaining row of
that map, which was written before the DIO layer existed and pairs types by
name rather than by role.

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

Two names in those vendored files collide with the kernel's own macros and
are spelled `BSD_LIST_HEAD` and `BSD_RB_ROOT` here, with the two core use
sites updated (`hammer2.h`, `hammer2_rb.h`) and marked. Both compilers
reported the redefinition independently once the W=1 warning set was
turned on. This is not cosmetic: `hammer2_io.c` includes four kernel
headers *after* `sys/queue.h` and `sys/tree.h`, so the BSD definitions are
live for the rest of every translation unit, and the day a kernel header
uses `LIST_HEAD` or `RB_ROOT` at file scope the build breaks somewhere
that has nothing to do with either file. `sys/cdefs.h` states the rule the
vendored copies were violating: nothing here may be a name the kernel
uses.

The other edit to those vendored files is that `__unused` is spelled
`__always_unused`. `__unused` is a *field name* in the Linux uapi headers,
and defining it as an attribute macro makes an array field so declared a
compile error and a scalar one vanish with only a warning, silently
changing the struct's layout. Both shapes are real: a sweep of
`include/uapi` for a bare `__unused` field returns exactly two headers,
one of each. `struct icmphdr` has the scalar, `__be16 __unused` inside its
`frag` member; `struct __sysctl_args` has the array, `unsigned long
__unused[4]`. The `__unused4` and `__unused5` fields in `struct stat` are not instances: a
macro named `__unused` does not collide with them, and counting them would
overstate the exposure.

## The log a full volume writes

`hprintf` is this port's own macro and carries the module name for the
reason above it in `hammer2_os.h`. It is rate limited, which the BSD
ports have no equivalent of and which the carried core cannot ask for.

The core reports per object. That reads as a handful of lines while a
volume has room in it and as one line per inode when it does not:
`hammer2_chain_create_indirect()` and `hammer2_inode_chain_ins()` each
report on every inode that cannot be inserted, and a 2 GiB volume filled
to `ENOSPC` put 120 of them inside a 220-line window of one run, bounded
by nothing but the inode count. A filesystem that floods the kernel log
when a disk fills is a defect in the eyes of anyone reading that log to
find out why the disk filled.

The limit is printk's, so its state is per call site: a line printed
once at mount is untouched, only a flood is suppressed, and the printk
layer reports its own suppression, so a reader is told what was dropped
rather than shown a quiet log. 58 files under `fs/` in the kernel of
record limit their printks the same way. The alternative, editing the
call sites in the carried core, is the edit this tree exists to avoid,
and the shim is where a Linux answer belongs.

Two things this does not fix and does not hide. The messages go out at
`pr_info`, which is the level the carried core's own wording implies and
is below what an I/O error deserves; separating the error sites from the
informational ones means classifying every call site in the core and is
not done. And the `ENOSPC` behind these lines is dropped under upstream's
own `XXX return error somehow?`, so the log knows the volume is full and
the caller is not told.

## Crashing the kernel: KKASSERT, hpanic, and what Linux expects

The mapping is the BSD ports' and the consequence is not. All three map
DragonFly's `KKASSERT` onto their own `KASSERT`, gated on the kernel's
assertion build (`freebsd_hammer2` defines `KKASSERT(exp)` as `KASSERTMSG`,
`netbsd_hammer2` as bare `KASSERT`, both in their own
`src/sys/fs/hammer2/hammer2_compat.h`), and all three define `hpanic` as
`panic()`
verbatim. This port follows both.

| site | what it is |
|---|---|
| `hammer2_compat.h:93` | `KKASSERT`, `BUG_ON` under `HAMMER2_INVARIANTS`, nothing without |
| `hammer2_compat.h:94` | `KASSERTMSG`, which panics under the same knob |
| `hammer2_os.h:116` | `hpanic`, `panic()` unconditionally |

Measured 2026-08-26: eight `BUG_ON` and four `panic()` sites under `src/`.

What differs is the host. A BSD `panic` drops to the debugger or reboots,
and the operator of a machine running an assertion kernel expects that.
Linux `panic()` halts or reboots the machine unconditionally, in every
build, and `BUG()` kills the calling task with an oops while whatever locks
it held stay held. Neither is how a Linux filesystem is expected to react
to a corrupt volume or a broken invariant: the convention is to fail the
operation and take the mount read-only, as `ext4_error()` and btrfs do,
because the volume being wrong must not take the rest of the machine with
it. `checkpatch.pl` says the same thing in one line, AVOID_BUG, and the
style gate cannot see it (`doc/README.kernel-style.md`).

The decision, split by which half the code is in:

- **The carried core keeps its `KKASSERT`s.** They are DragonFly's, they
  are compiled out in the default build, and rewriting hundreds of them
  into recovery paths is the rewrite this port exists to avoid. A wrong
  one is upstream's bug in all four trees.
- **The OS half this port writes uses `WARN_ONCE` plus recovery**, and
  fails the operation with an errno instead of asserting. The first
  instance is `hammer2_io_folio_check()` in `hammer2_io.c`, which replaced
  a `KKASSERT` on a length that a buffer overrun depends on.
- **`hpanic` stays `panic()` until there is a mount to fail instead.**
  It had two call sites when this was written, both reporting a corrupt
  block reference with no mount to invalidate. The carried core brought
  its own, fifty-four across seven files on 2026-09-04, forty of them in
  `hammer2_chain.c`. It was written here that when `hpanic` becomes
  the place that marks the mount in error, every one of them becomes
  that at once. Measured on 2026-09-05, that is false: not one of the
  fifty-four is followed by a `return` or a `goto`. Twenty-seven sit in
  a `switch` default arm followed by `break`, so the code after the
  switch runs on; twenty-three run straight into code that reads the
  thing the panic said was wrong; four close a block. Every site is
  written on the assumption that `hpanic` does not return, so a
  returning `hpanic` is fifty-four core edits in all four trees, and
  the one name buys nothing until each has a return path. What one
  name does still buy is the choice of what a non-returning `hpanic`
  does: `panic()` takes the machine, and the Linux-shaped alternative
  that keeps the contract is to mark the superblock in error and kill
  the task with `BUG()`, which leaves the mount wedged with its locks
  held rather than the machine down. That is a policy choice about
  what an operator would rather have, `errors=panic` against
  `errors=remount-ro` in ext4's terms, and it is recorded here as open
  rather than taken.

  What one costs was measured on 2026-09-04: the first flush of a
  written file reached the `hpanic` in `hammer2_io_alloc()`, the guest
  printed the panic and sat in it with `kernel.panic` at 0, nothing
  reached its disk, and the message existed only because the serial
  console had been turned on for that run. `doc/README.testing.md`
  records the capture.

DEFER(every hpanic site has an error its caller propagates): `hpanic` on
Linux is a machine-wide event standing in for a per-mount one. The
super_block to mark has existed since 0.4, so that is no longer what
lifts this. The fifty-four sites are written as not returning, and each
needs an error its caller carries out before `hpanic` can stop calling
`panic()`, which is an edit to carried core in every tree.

A reviewer who has not read this file will raise this, and should: the source
shows `BUG_ON` and `panic` with nothing beside them saying the objection was
considered.

## The module license, and why it is Dual BSD/GPL

`MODULE_LICENSE("Dual BSD/GPL")`, `MODULE_AUTHOR` and
`MODULE_DESCRIPTION` are in `hammer2_vfsops.c`, added with the module
entry on 2026-08-26. They were recorded here and left out of the tree
until then, because a license tag on a module that cannot be built is a
claim nothing exercises.

What decides the value is not sentiment about the code's origin. The file
data path this port was heading for was iomap, reversed in
`README.roadmap.md` on 2026-09-05 for classic address-space operations;
the license reasoning stands either way. `iomap_read_folio`,
`iomap_file_buffered_write` and `iomap_writepages` are all
`EXPORT_SYMBOL_GPL`: a module that does not declare a GPL-compatible
license cannot link them, and the failure is at load time rather than at
compile time. The carried code is DragonFly's under a BSD license, so the
declaration that keeps both true is `MODULE_LICENSE("Dual BSD/GPL")` - the
kernel treats it as GPL-compatible for symbol purposes and it does not
relicense anything. Settled by reading xfs at v6.15, the one mainline
filesystem above page size, which runs its data path on iomap; the tag
outlives the iomap ruling because a later need for any other GPL-only
symbol would put the port back in the same position.

## The module entry, and the four things FreeBSD's vfs_init does that Linux does not

`hammer2_vfsops.c` gained `module_init`, `module_exit` and
`register_filesystem` on 2026-08-26. That is the point at which the tree
has an entry point at all: until then every tunable and counter the
carried core reads was declared `extern` in `hammer2.h` and defined
nowhere, so nothing could have linked. Four decisions came with it, and
none of them is a translation.

**The read-write half of the sysctl block becomes module parameters, and
the read-only half cannot.** FreeBSD exports fifteen values under
`vfs.hammer2`, read-write for the tunables and read-only for the four
allocation counters and `supported_version`. Linux's nearest mechanism
that costs nothing to build is `module_param_named()`, which puts the
nine tunables under `/sys/module/hammer2/parameters/` at 0644 and drops
the `hammer2_` prefix exactly as `sysctl` does.

The counters are not there, and the reason is that `perm` is visibility
in sysfs and nothing else. `include/linux/moduleparam.h` says it in as
many words at the kernel of record: `@perm` is 0 if the variable is not
to appear in sysfs, and the name "becomes the module parameter, or
(prefixed by `KBUILD_MODNAME` and a `.`) the kernel commandline
parameter." So a 0444 parameter is still settable at `insmod`. A counter
that can be handed a value at load is a counter `hammer2_assert_clean()`
cannot trust in either direction: a positive one at load reports a leak
that never happened, and a negative one hides a real leak under a sum
that reaches zero. That is precisely the check this file moved to the
unload path to make it work, so exposing the counters this way
would have taken it straight back. `supported_version` goes with them
rather than being settable to a version the code does not support, and
there is no variable for it at all until there is somewhere read-only to
put it.

The upgrade for all of it is `/sys/fs/hammer2/`, where ext4 and btrfs put
theirs. It is the only place the counters can go and the only place a
*per-mount* value can live, and it carries a `DEFER` naming the second
trigger. A module parameter is one value for every mount on the machine,
which is what `sysctl` gave upstream too, so nothing is lost on the
tunables until a knob wants to differ between two mounts.

**`hammer2_assert_clean()` moves from load to unload.** Upstream calls it
from `vfs_init`. On Linux the module loader has just zeroed every global
at that point, so the check can only ever read zero and can only ever
pass: it would be a leak check that cannot report a leak. At unload the
counters can be anything, which is the only place the check discriminates.
Zero is the healthy signature in one place and the inert one in the other,
and the two are indistinguishable from the check's own output. It runs
before the two `uma_zdestroy()` calls, not after: a nonzero counter means
live objects in a cache about to be destroyed, `kmem_cache_destroy()`
complains about that itself, and the message naming which counter is more
use ahead of the one saying the cache was not empty.

**`uma_zcreate(9)` cannot fail and `kmem_cache_create()` can.** Upstream
asserts the zone pointer is non-NULL. `kmem_cache_create()` returns NULL
on failure, so the assertion becomes an error path with an unwind, and
`hammer2_module_init()` is the one place in the shim's `uma_` mapping
where the Linux primitive is weaker than the BSD one rather than equal to
it. Everywhere else the mapping is exact; see the `M_WAITOK` note above.

**`desiredvnodes` has no Linux equivalent, so the derivation moves to
physical memory.** Upstream sets its dirty-chain limit to
`desiredvnodes / 10`, clamped to `[1000, HAMMER2_LIMIT_DIRTY_CHAINS]`, and
multiplies by five for `hammer2_limit_saved_chains`, which is what
`hammer2_bulkfree.c` actually reads. `desiredvnodes` is FreeBSD's target
size for the vnode cache and is itself derived from physical memory, so
this port derives from `totalram_pages()` directly and keeps upstream's
clamp and factor unchanged. The clamp does most of the work: at
`pages / 10` the low end is reached only below 40 MiB of RAM and the high
end only above 40 TiB, so on any machine this module will run on the value
is one tenth of the page count.

`hammer2_mntlist`, the global list of `hammer2_dev`, was deliberately
left undefined here, because a static definition with no user is what the
syntax gate flags and silencing that warning would have hidden that the
file was part written. It got its user on 2026-08-26 with the teardown
path and is defined now; the paragraph is kept because the reasoning is
the reusable part, and the same trick is what will keep the next
half-written global honest. `hammer2_mntlk` was defined from the start,
since the module entry initializes and destroys it.

## The mount options: a numeric hflags becomes one named flag

FreeBSD's `mount_hammer2` hands the kernel an `int` of `HMNT2_*` bits
under the name `hflags`, because that is what `nmount(2)` gives it. Two
bits are defined and `hammer2_mount()` rejects one of them outright:
`HMNT2_LOCAL` is broken in DragonFly, so the whole of `hflags` a mount
can actually set is `HMNT2_EMERG`. A single named flag is how Linux
spells that, so `hammer2_fs_parameters[]` has exactly one entry,
`fsparam_flag("emerg", ...)`, and there is no numeric option to get
wrong. `hammer2_mount.h` keeps the bit definitions, because the carried
core tests `pmp->hflags` against them.

`source` is not in the table. Returning `-ENOPARAM` for a key the table
does not know sends the parameter to `vfs_parse_fs_param_source()`,
which is the generic handling and sets `fc->source`; read at v7.2 in
`fs/fs_context.c`, `vfs_parse_fs_param()`. The device-and-label split
FreeBSD does on its `from` option belongs where `fc->source` is final,
which is `->get_tree`.

The `fs_context` needs private state at all for a reason that is
structural rather than incidental: FreeBSD reads its options out of the
mount structure inside `hammer2_mount()`, with the whole set in hand at
once. Linux delivers them one at a time, before there is a
`super_block`, so anything parsed has to be kept somewhere until
`->get_tree` runs. That is `struct hammer2_fs_context`, freed by
`->free`.

`->reconfigure` is where the `MNT_UPDATE` branch of `hammer2_mount()`
goes, and upstream's `hammer2_remount_impl()` is what landed there at
0.7.1. It was written as a refusal first, and being written rather than
absent is what made that possible: `reconfigure_super()` applies
`SB_RDONLY` whether or not the operation exists, so a filesystem with no
`->reconfigure` reaches the read-write state sideways and without a
diagnostic.

The carry drops upstream's two loops over the device vnodes, which take
and drop a write reference. There is none to take here. The block device
file is opened once at mount and never reopened, which is what the four
filesystems calling `sb_open_mode()` all do, and reopening is not
available either: that macro always sets `BLK_OPEN_RESTRICT_WRITES`,
which leaves `bd_writers` negative and makes `bdev_may_open()` refuse a
second open asking for `BLK_OPEN_WRITE`. The module's writes leave as its
own bios and never consult the file's `f_mode`, so what stops a write is
the device being write-protected, and that is what `hammer2_access_devvp()`
asks through `bdev_read_only()`. It is the same question ext4 asks in the
same place, and the remount is that function's first caller: it had been
carried with no caller since the import, and its `f_mode` test would have
refused every transition.

## The teardown path, and the two things kill_anon_super() already did

`hammer2_kill_sb()` calls `kill_anon_super()` and then
`hammer2_unmount()`, which is the order `btrfs_kill_super()` uses at the
kernel of record: the generic call drops every inode and the root
dentry, and those hold the references the private teardown is about to
free.

That order deletes two things from upstream's `hammer2_unmount()`.
`vflush()`, which flushes a mount's vnodes and is what upstream fails
the unmount on, has nothing left to do; and with it goes the return
value, because Linux's `->kill_sb` returns `void` and is called after
the unmount has already been decided. `MNT_FORCE`, whose only use
upstream is to add `FORCECLOSE` to that `vflush()` call, goes with it.

The three `hammer2_vfs_sync_pmp()` calls stay. Until 0.4.7 that symbol
was declared in `hammer2.h` and defined nowhere, deliberately, and then
a floor; it is upstream's sync now. The choice it recorded was the same
choice `hammer2_pfsfree_scan()` already makes: nothing in this tree
links yet, and a missing symbol is visible at link time where a stub
returning success would be silent on the one path that decides whether
an unmount lost data. Three is upstream's number, and its comment says
why: freemap updates lag a flush by one, plus one for safety.

`mp->mnt_data` becomes `sb->s_fs_info`, which is the slot the VFS hands
a filesystem for exactly this. `MNT_LOCAL`, which upstream sets and
clears on the mount, has no carried equivalent: Linux has no per-mount
flag a filesystem sets for that and works it out from the absence of a
network superblock.

`hammer2_mount_helper()` is the other half of `hammer2_unmount_helper()`,
and connects a PFS to a superblock: it sets `sb->s_fs_info = pmp` and
`pmp->mp = sb`, and bumps the `mount_count` on all underlying device
chains. It landed with the PFS half of `->get_tree` and `hammer2_sops`
(`->evict_inode`). Nothing mechanical enforces that a helper lands only
with its caller: `script/test-syntax.sh` passes `-Wno-unused-function`,
because the carried files arrive with statics whose unported callers would
have used them, so an unused static *variable* fails the gate and an unused
static *function* does not. The rule that no unreachable helper lands ahead
of its caller is a discipline here rather than a check, and that is written
into the file's opening comment so the next reader is not misled by the
one it can see enforced.

The converse is a check, and it is worth knowing which half is which,
because reaching the conclusion from one direction gets the other
backwards. A static *declared and never defined* is
`-Wundefined-internal` under clang and "used but never defined" under
gcc, neither suppressed here, and the gate caught a missing carry that
way the first time this file used a forward declaration. So the gate is
silent about a helper that arrives too early and loud about one that
never arrives at all.

## The gate needed a Kbuild define before a file could include <linux/module.h>

`arch/x86/include/asm/ftrace.h` refuses to compile under
`CONFIG_FUNCTION_TRACER` unless `CC_USING_FENTRY` is defined, and that
header is reached the moment a file includes `<linux/module.h>`. Kbuild
defines it beside `-mfentry` (the kernel `Makefile`, `CC_FLAGS_USING`,
read at the kernel of record). `script/test-syntax.sh` now passes the
define and not the flag: `-mfentry` is codegen and the gate is
`-fsyntax-only`, and gcc rejects `-mfentry` outright without `-pg`, which
would have taken the second compiler out of the gate to buy nothing.

## Why the device is resolved twice, and why the open cannot come first

FreeBSD's `hammer2_init_devvp()` calls `namei()` on each device path and
holds the vnode it gets back. Two things in the mount path need that
vnode before anything is opened. A bad path is diagnosed there, before
the mount lock is taken. And the second-or-later mount of the same
device is recognized by matching `devvp->v_rdev` against the devices
already on `hammer2_mntlist`, which is what tells the mount path to reuse
an existing `hmp` instead of building one.

The obvious Linux reading is that `bdev_file_open_by_path()` does all of
`namei()` plus `vn_isdisk_error()` plus `VOP_ACCESS()` in one call, so
`hammer2_init_devvp()` has nothing left to do but record the path. That
was this port's first reading and it is wrong on both counts, because it
makes the resolution and the open one event when the mount path needs
them to be two.

The reason they cannot be one event is the holder. Opening a block
device claims it for a holder, and the holder ops every filesystem passes
are `fs_holder_ops`, whose four callbacks all begin at `bdev_super_lock()`
in `fs/super.c`, which does `sb = bdev->bd_holder` and then requires
`sb->s_root` and `SB_ACTIVE`. The holder is dereferenced as a
`struct super_block *`, so it has to be one, and there is no superblock
until `sget_fc()` has run. btrfs does exactly this ordering:
`sget_fc()` first, then `btrfs_open_devices(fs_devices, mode, sb)` with
the superblock as the holder. Both read at the kernel of record.

So the open stays in `hammer2_open_devvp()`, after the superblock exists,
and `hammer2_init_devvp()` recovers what `namei()` was doing with
`lookup_bdev()`, which resolves a path in the caller's namespace and
yields the `dev_t` without opening anything and without a reference to
release. `struct hammer2_devvp` gains a `devno` field, which is
`v_rdev` under the name Linux uses, and the mount path's device match is
the same comparison FreeBSD makes on the same quantity. `lookup_bdev()`
fails with `ENOTBLK` for a path that is not a block device and `EACCES`
under a `nodev` mount, which is the diagnosis FreeBSD gets from
`vn_isdisk_error()` and `VOP_ACCESS()` and gets in the same place.

There is a cost and it is worth naming: the path is resolved twice, once
here and once inside `bdev_file_open_by_path()`, and a device that is
renamed between the two calls is resolved to two different devices. The
window is the same one FreeBSD has between `namei()` and `g_vfs_open()`,
and it closes at the open, which is the call that decides what the
filesystem actually reads.

## An upstream defect was carried rather than fixed

`hammer2_fixup_pfses()` walks the super-root with `hammer2_chain_lookup()`
and `hammer2_chain_next()`, and its first statement inside the loop is

    while (chain) {
            if (chain->bref.type != HAMMER2_BREF_TYPE_INODE)
                    continue;

`continue` in a `while` returns to the condition with `chain` unchanged and
still non-NULL, so reaching that branch hangs the mounting thread with
`spmp->iroot` locked. DragonFly, and Kusumi's FreeBSD, NetBSD and OpenBSD
ports all carry it identically.

It is reachable, but only on a damaged image. `hammer2_chain_lookup()`
without `HAMMER2_LOOKUP_MATCHIND`, which is what this call passes, makes an
indirect block the new parent and loops on it rather than returning it, so
the walk yields leaves only, and every leaf directly under the super-root
of a well-formed filesystem is a PFS inode. A `DIRENT` or `DATA` bref there
is corruption, which is the case mount-time recovery exists to meet.

The code is carried unchanged anyway, because the rule that keeps the four
trees readable side by side does not have an exception for defects, and
because the refusals in `hammer2_get_tree()` and `hammer2_reconfigure()`
mean nothing calls it. The fix is staged in `doc/upstream/` as two patches,
one against DragonFly and one against the three ports, which is where work
for James to file upstream goes. They are not applied here.

## The kernel floor is the kernel of record

The floor is 7.3, the same kernel `KERNEL_REF` in `script/test-syntax.sh`
pins as the kernel of record, and the two move together when a release
ships. There is no conditional compilation on the kernel version in the
tree: the `#error` in `hammer2_os.h` is the whole of it.

It was 6.15 from the first import, chosen because `BLK_MAX_BLOCK_SIZE`
arrived there and is what lets a 64 KiB physical buffer reach the block
layer, and four guards accumulated above it as the tree used what newer
kernels offered: `struct sha256_ctx` at 6.17, `->write_begin` taking a
`kiocb` at 6.17, `inode_state_read_once()` at 6.19, `kzalloc_obj()` at
7.0, and the per-mount device claim at 7.3. Each was measured by reading
the header at the tags and each drew a `LINUX_VERSION_CODE` hit from
`checkpatch.pl`, which is right to draw it: a port carried across a
range of releases is not code for the version it will be merged into.

The earlier text here recorded the decision to move the floor to 7.3 on
its release, on the expectation that 7.3 becomes a longterm series, and
to keep 6.15 and the guards until then so that a released kernel could
build the tree. That reasoning held until the floor was first compiled.
CI's build at 6.15 went red on a codec a `defconfig` leaves out, then on
a config edit `olddefconfig` silently undid, then on the `->write_begin`
signature, and a day went to a kernel that nothing here runs, nothing in
Saxum runs, and no fixture has ever been mounted on. The maintainer's
ruling on 2026-09-05: a floor two releases below the features the code
uses is not worth a second tree, so raise it when a newer facility is
needed and stop carrying the range. 7.3 is at rc1 as this is written and
is expected to be longterm; if kernel.org's release table says otherwise
when it ships, that changes which release the pin names, not the rule.

What the move deleted: the second CI job that fetched, configured and
built a 6.15 tree on every cache miss, `script/floor-symbols.py`, which
resolved every called name against a floor tree's headers and could not
see a signature, and five `LINUX_VERSION_CODE` hits with two typedefs in
the style baseline. What it did not change: the mount-time folio check,
which is about the running kernel's page cache and not its version, and
the `CONFIG_TRANSPARENT_HUGEPAGE` requirement, which every release above
6.15 shares.

