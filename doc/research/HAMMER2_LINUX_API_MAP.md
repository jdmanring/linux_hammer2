# HAMMER2 to Linux API map (H0 deliverable)

Part of the archaeology work package (`proposals/artnix_filesystem/`, document
07 section 5). Measured 2026-08-25 by the specification session from the
DragonFly core and the FreeBSD port on this disk; every count is from a
command, every mapping is tied to a file and function. The proposal's matrix
called every row "archaeology required"; this document fills the rows and
says which are design decisions rather than mappings.

The reading that reframes the map: the FreeBSD port is a **full read-write
port** (`.vop_write = hammer2_write`, `hammer2_vnops.c:2675`), so every
difference between it and DragonFly is a deliberate reshaping that worked,
not an unported gap. Where FreeBSD made a choice, the Linux port has a
tested precedent.

## 1. VFS entry

DragonFly registers three vop tables in `hammer2_vnops.c` (vnode 33 entries,
special 11, fifo 9) and a 13-entry `vfsops` in `hammer2_vfsops.c`. FreeBSD
has two vop tables (vnode 30, fifo 13) and a 9-entry `vfsops`.

| DragonFly | FreeBSD did | Linux |
|---|---|---|
| ten namecache vops (`vop_nresolve`, `ncreate`, `nmkdir`, `nmknod`, `nremove`, `nrmdir`, `nrename`, `nlink`, `nsymlink`, `nlookupdotdot`) | classic forms: `vop_cachedlookup` plus `vfs_cache_lookup`, and `create`, `mkdir`, `mknod`, `remove`, `rmdir`, `rename`, `link`, `symlink`; the largest reshape in the port | `inode_operations` (`lookup`, `create`, `mkdir`, `mknod`, `unlink`, `rmdir`, `rename`, `link`, `symlink`) with the dentry cache doing what DragonFly's namecache did; `lookup` returns a dentry, and `hammer2_vop_nresolve`'s "resolve into the namecache" becomes `d_splice_alias` |
| `vop_read`, `vop_write` through the buffer cache (`hammer2_read_file`, `hammer2_write_file`) | same, over FreeBSD's buffer cache | `file_operations` over the page cache: `read_iter`, `write_iter` with `address_space_operations` (`read_folio`, `writepages`, `write_begin`/`write_end` or iomap); the DragonFly functions do not survive, the chain logic under them does |
| `vop_getattr`, `vop_getattr_lite`, `vop_setattr` | `getattr`, `setattr`; `getattr_lite` dropped | `getattr`, `setattr` in `inode_operations`; `_lite` has no counterpart and is dropped as FreeBSD did |
| `vop_readdir` | `readdir` with a 64-bit cookie gate (`FREEBSD_READDIR_COOKIES_64`) | `iterate_shared` with `ctx->pos` as the cookie; HAMMER2 keys are 64-bit, which fits `loff_t` |
| `vop_readlink`, `vop_open`, `vop_close`, `vop_access`, `vop_fsync` | kept; `fdatasync` added (`vop_stdfdatasync_buf`) | `get_link`, `open`, `release`, `permission` (or generic), `fsync` with `datasync` |
| `vop_inactive`, `vop_reclaim` | kept, with a version gate on vnode state (`FREEBSD_VNODE_STATE`, `hammer2_inode.c:664`): even two BSDs disagreed on the lifecycle | `drop_inode` and `evict_inode`; the ordering differs from BSD's inactive-then-reclaim, and DragonFly's inactive-time `nvtruncbuf` of unlinked files (`hammer2_vop_inactive`, `hammer2_vnops.c:123`) moves into `evict_inode` after `truncate_inode_pages_final` |
| `vop_strategy`, `vop_bmap` | strategy on `struct buf`, `bmap` kept | no strategy entry: block I/O is issued from the address-space operations and `hammer2_io.c` (section 2); `bmap` maps to `bmap` in `address_space_operations` only if needed |
| `vop_ioctl`, `vop_mountctl` | `ioctl` kept, `mountctl` dropped | `unlocked_ioctl`; the HAMMER2 ioctl set (`hammer2_ioctl.h`) is redesigned as Linux ioctls with `_IOWR` numbering, which document 07 lists as "interface redesign" |
| `vop_advlock`, `vop_kqfilter`, `vop_markatime`, `vop_putpages`, the special-file table | all dropped | POSIX locks are the VFS's (`locks_lock_inode_wait` through generic code), kqueue has no analog, atime is the VFS's, writeback is `writepages`, special files are the VFS's `init_special_inode` |
| `vfs_mount`, `vfs_unmount`, `vfs_root`, `vfs_statfs`, `vfs_sync`, `vfs_vget`, `vfs_fhtovp`, `vfs_init`, `vfs_uninit` | kept | `fs_context_operations` (`parse_param`, `get_tree` through `get_tree_bdev`), `super_operations` (`put_super`, `statfs`, `sync_fs`, `alloc_inode`, `destroy_inode`), `export_operations` (`fh_to_dentry`, `encode_fh`) for `vptofh`/`fhtovp`, `register_filesystem` for init |
| `vfs_statvfs`, `vfs_checkexp`, `vfs_modifying`, `vfs_flags` | dropped | none needed |

The `hammer2_vop_*` and `hammer2_vfs_*` functions are the port; what they
call (`hammer2_inode_*`, `hammer2_chain_*`, `hammer2_xop_*`) is carried.

## 2. Buffer and cluster I/O

This is the deep concern and the numbers say why. DragonFly's strategy path
is written on `struct bio` chained off the buf (`vn_strategy(hmp->devvp,
&bp->b_bio1)`, `hammer2_flush.c:1496`) with the fields `bio_buf`,
`bio_offset`, `bio_caller_info1/2` (the per-BIO carrier that threads XOP
state through the callback), `b_cmd`, `b_loffset`; FreeBSD rewrote it on
`struct buf` with `b_iocmd` and `BIO_READ`/`BIO_WRITE` (`hammer2_strategy.c:63`).

Call census, DragonFly:

- `hammer2_io.c` (the metadata I/O layer): `bkvasync` 6, `getblk` 2,
  `cluster_write` 2, `cluster_readx` 2, `breadnx` 2, `brelse` 2, `bdwrite`,
  `bawrite`, `bqrelse`, `BUF_KERNPROC` 1 each, all in `_hammer2_io_getblk`
  and `_hammer2_io_putblk`.
- `hammer2_strategy.c`: `biodone` 6, `bread` 2, `bkvasync` 2, `cluster_read` 1.
- `hammer2_vnops.c` (file data): `cluster_write` 3, `nvtruncbuf` 2,
  `nvextendbuf` 1, `getblk` 3, `bread_kvabio` 4, `bdwrite` 3, `bawrite` 2,
  `bqrelse` 3, `brelse` 4, `bwrite` 1, `bheavy` 2, `vfs_bio_clrbuf` 1,
  `vinitvmio` 2 (in `hammer2_inode.c`).

What FreeBSD did with each, which is the precedent:

| DragonFly | FreeBSD | Linux |
|---|---|---|
| `bkvasync`, `bread_kvabio` (KVA-lazy buffers) | dropped, nine uses to zero; FreeBSD bufs are always mapped | dropped; folios are mapped on demand with `kmap_local_folio` |
| `breadnx`, `cluster_readx` | collapsed to `bread` and `cluster_read` in a new `hammer2_bread` | metadata reads become `bio` submissions against the block device with a private buffer (the DIO layer in `hammer2_io.c` already abstracts "a 64 KiB physical buffer keyed by device offset"; it becomes the owner of those buffers, backed by `kmalloc`/`kmem_cache` pages and `submit_bio`, or by the block device's own page cache through `bdev` reads); this is the design decision of H1 |
| `getblk`, `cluster_write`, `bdwrite`, `bawrite`, `bqrelse`, `brelse`, `BUF_KERNPROC` | kept, in `hammer2_io_getblk`/`putblk`; `cluster_write`'s struct signature version-gated (`FREEBSD_CLUSTERW_STRUCTURE`) | the DIO layer's own dirty tracking and writeback thread; there is no Linux buffer-cache delayed-write for a raw device buffer, so `bdwrite` semantics (mark dirty, write later, cluster) are implemented inside `hammer2_io.c` on top of `submit_bio` |
| `biodone` | `bufdone` | `bio_endio` on the port's own bios; XOP completion state travels in `bio->bi_private`, which is what `bio_caller_info1/2` carried |
| `nvtruncbuf`, `nvextendbuf` | `vtruncbuf`, `vnode_pager_setsize` | `truncate_setsize` / `truncate_pagecache`, and `i_size_write` |
| `vinitvmio` | dropped | none: an inode's `i_mapping` exists from allocation |
| `bheavy`, `vfs_bio_clrbuf` | dropped / kept | none / `folio_zero_range` |
| file-data read and write through the buffer cache | same | the page cache: `hammer2_read_file` and `hammer2_write_file` are rewritten as `read_folio`/`readahead` and `write_begin`/`write_end` (or an iomap implementation, which is the modern shape and what a maintainer will ask for); the logical-block-to-chain lookup under them (`hammer2_xop_strategy_read`/`write` through the chain code) is carried |

## 3. Locking and threads

Census over the files FreeBSD compiles: `hammer2_spin_*` 177 tokens (69 acquire sites, 62 port-relevant; H1 reading 1, `H1_READING_1_SPIN_AUDIT.md`, 2026-08-25), `hammer2_mtx_*`
119, `lockmgr` 34, `tsleep` 27, `wakeup` 25, `lwkt_*` 9, atomics 201
(`atomic_set_int` 63, `atomic_clear_int` 55, `atomic_cmpset_int` 33,
`atomic_add_int` 24, `atomic_add_long` 18, `atomic_fetchadd_int` 5,
`atomic_set_long` 3). Clustering files add 24 spin, 5 sleep, 7 wakeup.

FreeBSD's shim (`hammer2_os.h`), quoted where it matters:

- `lockmgr` (vnode-scale lock): `typedef struct sx hammer2_lk_t;` (line 91),
  `sx_xlock`/`sx_unlock`. Linux: the inode's `i_rwsem` where it is a vnode
  lock, `rw_semaphore` where it is HAMMER2's own.
- `hammer2_mtx` (shared/exclusive with upgrade and a reference count):
  `struct sx_wrapper { struct sx lock; int refs; }` (line 174) because
  `hammer2_mtx_refs()` has no FreeBSD analog. Linux: `rw_semaphore` plus
  the same hand-rolled count; `hammer2_mtx_upgrade_try` has no direct
  Linux primitive (`downgrade_write` exists, upgrade does not) and its two
  call sites are redesigned, which FreeBSD did not have to do.
- `hammer2_spin` (69 acquire sites; 177 was the token count): **FreeBSD mapped spinlocks onto `sx`, a
  sleepable lock** (lines 106 to 110: "Normal synchronous non-abortable
  locks can be substituted for spinlocks. FreeBSD HAMMER2 currently uses
  sx(9) for both mtx and spinlock"). That was legal because no
  `hammer2_spin_*` region sleeps in a way that breaks, and it means the shim
  gives Linux no answer to `spinlock_t` versus `rw_semaphore`. Each of the
  69 acquire sites is audited for sleeping under the lock before the choice (done: none sleeps, `H1_READING_1_SPIN_AUDIT.md`); the
  default that mirrors FreeBSD is a `rw_semaphore`, and `spinlock_t` only
  where an audit shows atomic context.
- `tsleep`/`wakeup`: `sx_sleep` on an `int` cookie, `wakeup(c)`. Linux:
  `wait_event_interruptible` on a `wait_queue_head_t` embedded beside the
  lock, `wake_up`; `tsleep_interlock` (16 sites) is the prepare-to-wait
  pattern.
- `lwkt_gettoken(&vp->v_token)` (one site, `hammer2_vfsops.c:2715`): no shim
  in FreeBSD at all; on Linux it is whatever the surrounding vnode lock
  became.
- `kmalloc`/`kfree` with malloc types: `malloc` with `M_NOWAIT` forced under
  `HAMMER2_MALLOC` (line 439) and leak accounting; `uma_zone_t` for read and
  write buffers (lines 415 to 416). Linux: `kmalloc`/`kvmalloc`, `kmem_cache`
  for the zones; the per-type accounting and `kmalloc_raise_limit(M_HAMMER2,
  0)` ("unlimited", `hammer2_vfsops.c:255`) have no equivalent and are
  dropped.
- `cpu_pause`, `cpu_ccfence`, `getticks`: `cpu_relax`, `barrier`, `jiffies`.
  Mechanical.
- Assertions: `KKASSERT` to `KASSERT`, compiled out without `INVARIANTS`.
  Linux: `WARN_ON`/`BUG_ON` under a Kconfig debug option.

**Worker threads: the one decision the shims never made.** DragonFly fans
every metadata operation out to a pool of XOP threads: `hammer2_thr_create`
(`hammer2_admin.c:219`) over `lwkt_create`, sized in `hammer2_vfsops.c:260`
to `ncpus * 2` raised to at least 32 threads and 4 groups
(`HAMMER2_XOPTHREADS_MIN 32`, `HAMMER2_XOPGROUPS_MIN 4`), times the number
of cluster chains, with a 16-entry FIFO (`HAMMER2_XOPFIFO`) and backpressure.
**FreeBSD removed the pool**: `hammer2_xop_start` (`hammer2_admin.c:312`)
calls the storage function inline on the caller (`xop->desc->storage_func`,
lines 303 and 343) and retires the XOP; no `hammer2_thr_create`, no groups.
Its comment at line 70 keeps DragonFly's design as history. The Linux port
follows FreeBSD (synchronous XOPs) for H1 and H2; a workqueue-backed pool is
an optimization to measure later, not a port requirement. The remaining
threads are the per-mount sync thread and the bulkfree thread, which are
`kthread_run` with `kthread_should_stop`.

## 4. What the core assumes that no shim hides

1. **Clustering is removed by deleting files, not by a switch.** DragonFly's
   `Makefile` builds `hammer2_msgops.c`, `hammer2_iocom.c`,
   `hammer2_synchro.c`; FreeBSD's does not, and its `hammer2.h` has zero
   matches for `dmsg`, `iocom` or `ccms` where DragonFly's declares 18
   `hammer2_dmsg_*` prototypes (lines 1800 to 1820), embeds `kdmsg_iocom_t`
   in the mount (line 1135) and dispatch hooks in every XOP descriptor
   (872 to 873). The Linux port performs the same surgery on `hammer2.h`.
2. **64 KiB physical buffers.** `HAMMER2_PBUFSIZE 65536`,
   `HAMMER2_LBUFSIZE 16384` (`hammer2_disk.h:106,108`), asserted at compile
   time (794 to 795), an on-stack `char buf[HAMMER2_PBUFSIZE]` (1318), and
   the dedup granularity `HAMMER2_DEDUP_FRAG` derived from it. Larger than
   any base page; the DIO layer works in 64 KiB units regardless of page
   size, which is what makes it the right owner of the buffers on Linux.
3. **`MAXPHYS` scratch buffers per XOP** (`hammer2.h:823`,
   `hammer2_admin.c:325`): Linux has no `MAXPHYS`; the size becomes a port
   constant tied to the physical buffer size.
4. **`nbuf`-derived sizing**: `hammer2_dio_limit = nbuf * 2`
   (`hammer2_vfsops.c:283`). Re-derived from `totalram_pages` or a mount
   option.
5. **64-bit on-disk types** (`hammer2_tid_t`, `hammer2_off_t`,
   `hammer2_key_t`, `hammer2_disk.h:427`): fine on 64-bit Linux; the port
   does not build on 32-bit without an arithmetic audit.
6. **Credentials and `uio`**: `struct ucred` in `vfsops` (11), `ioctl` (3),
   `hammer2.h` (3), `inode.c` (1); `struct uio` in `vnops` (8). Neither shim
   touches them because the BSDs share them. Linux: `struct cred`, `kuid_t`
   and `kgid_t` with `from_kuid`/`make_kuid` at the on-disk boundary;
   `iov_iter` where `uio` fed reads and writes, which disappears into the
   page-cache path. The largest un-shimmed surface.
7. **Vnode lifecycle**: item 6 of section 1; the inactive/reclaim split
   needed a version gate even between BSDs.
8. **Malloc types as accounting units**: four `MALLOC_DEFINE`s; dropped.
9. **Sleepable-versus-atomic is unresolved by the precedent**: section 3.

## The status column, filled

| concern | evidence | Linux candidate | status after H0 |
|---|---|---|---|
| VFS mount | `hammer2_vfsops.c` 13 entries, FreeBSD 9 | `fs_context`, `super_block`, `export_operations` | mapped; `get_tree_bdev` is the shape |
| inode operations | 33 vops, 10 namecache-shaped | `inode_operations`, `file_operations` | mapped; namecache to dentry cache is the rewrite FreeBSD already did once |
| directory entry cache | `vop_nresolve` | dentry cache, `d_splice_alias` | mapped |
| buffer and page cache | section 2 census | DIO layer owns 64 KiB buffers over `submit_bio`; file data through the page cache or iomap | design required; the H1 decision |
| block I/O | `struct bio` chained off `struct buf` | `bio`, `bio_endio`, `bi_private` for XOP state | mapped |
| locking | 69 spin acquire sites (177 tokens), 119 mtx, 34 lockmgr | `rw_semaphore` default, `spinlock_t` only where audited | design required, per site |
| worker threads | XOP pool, 32 threads minimum | synchronous XOPs as FreeBSD; `kthread_run` for sync and bulkfree | decided by precedent |
| memory | four malloc types, two zones | `kmalloc`, `kmem_cache` | mapped |
| device events | `devvp` open through the vnode layer | `bdev_file_open_by_path` and the block device model | mapped; no device events beyond open and close in H1 |
| ioctls | `hammer2_ioctl.h`, 44 `xop` uses in `ioctl.c` | Linux ioctl numbering, redesigned | interface redesign, H4 onward |
| xattrs | `hammer2_vop_*` carries none as a vop | `xattr_handler` only if the format carries them (read `hammer2_disk.h` for the inode's extension fields) | archaeology required, small |
| quotas | none in vops | none in H1 to H3 | deferred |
| fsck | `fsck_hammer2` in userspace, packaged here | userspace, offline; the port's job is to refuse a volume the check condemns | architecture as the toolchain already has it |

## What is not decided here

The H1 estimate. It is written after three readings this map names: the
per-site audit of the 69 spin acquire sites (done, reading 1), the DIO layer's buffer ownership
design, and the diff of the algorithm files with the shim's renames
normalized (`HAMMER2_PORTABILITY_AUDIT.md`). Those are H1's first week, and
an estimate written before them is a number nobody measured.
