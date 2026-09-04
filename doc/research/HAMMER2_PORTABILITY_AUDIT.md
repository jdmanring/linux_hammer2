# HAMMER2 portability audit (H0 deliverable)

Part of the archaeology work package (`proposals/saxum_filesystem/`, document
07 section 4). Measured 2026-08-25 by the specification session over the
four trees on this disk; every number is from a command run against them, and
the method is stated so the table can be re-run.

Trees (revisions in `HAMMER2_LICENSE_AUDIT.md`):

- DF: `~/Projects/dragonfly-hammer2-upstream/sys/vfs/hammer2/`
- FB: `~/Projects/freebsd-hammer2-upstream/src/sys/fs/hammer2/`
- NB: `~/Projects/netbsd-hammer2-upstream/src/sys/fs/hammer2/`
- OB: `~/Projects/openbsd-hammer2-upstream/src/sys/fs/hammer2/`

## The correction this audit makes to what was said before it

Tracker addenda 920 and 945 read the ports as "the full DragonFly core carried
unchanged behind a small shim". The line counts support "full" and the diffs
refute "unchanged": the ports keep every core file and rewrite the ones that
face the operating system. That is the useful finding, because it says which
files a Linux port rewrites (the same ones, a fourth time) and which it
carries.

## Method

For each DragonFly core file, `diff DF/file PORT/file | grep -cE '^[<>]'`,
which counts changed lines on both sides; the ratio is that count over the
sum of both files' lengths. Thresholds: under 2% CORE-REUSABLE, 2 to 15%
PORTABLE-WITH-ADAPTER, over 15% or port-only OS-SPECIFIC, no counterpart in
any port UNKNOWN. The ratio counts comment and whitespace churn as change, so
it overstates the semantic diff; it never understates it.

## Per-file table, DragonFly against the three ports

| file | DF lines | FB lines | FB diff | NB diff | OB diff | ratio (FB) |
|---|---|---|---|---|---|---|
| hammer2_vnops.c | 2496 | 2713 | 3267 | 3279 | 3509 | 62.7% |
| hammer2_admin.c | 1262 | 629 | 1133 | 1133 | 1135 | 59.9% |
| hammer2.h | 2007 | 1300 | 1957 | 1970 | 1964 | 59.2% |
| hammer2_cluster.c | 736 | 188 | 618 | 618 | 618 | 66.9% |
| hammer2_io.c | 963 | 784 | 951 | 958 | 957 | 54.4% |
| hammer2_vfsops.c | 3127 | 2247 | 2670 | 2921 | 2695 | 49.7% |
| hammer2_strategy.c | 1623 | 1132 | 1089 | 1119 | 1128 | 39.5% |
| hammer2_ioctl.c | 1454 | 1143 | 1023 | 1044 | 1044 | 39.4% |
| hammer2_ondisk.c | 740 | 808 | 596 | 575 | 609 | 38.5% |
| hammer2_subr.c | 473 | 460 | 317 | 314 | 314 | 34.0% |
| hammer2_ioctl.h | 231 | 205 | 136 | 136 | 136 | 31.2% |
| hammer2_inode.c | 1831 | 1637 | 1058 | 1093 | 1043 | 30.5% |
| hammer2_freemap.c | 1276 | 1000 | 638 | 638 | 638 | 28.0% |
| hammer2_bulkfree.c | 1447 | 1239 | 740 | 740 | 740 | 27.6% |
| hammer2_chain.c | 5848 | 4929 | 2627 | 2646 | 2627 | 24.4% |
| hammer2_xops.c | 1686 | 1449 | 755 | 755 | 755 | 24.1% |
| hammer2_flush.c | 1538 | 1310 | 628 | 618 | 618 | 22.1% |
| hammer2_mount.h | 59 | 58 | 23 | 26 | 64 | 19.7% |
| hammer2_xxhash.h | 43 | 45 | 14 | 14 | 14 | 15.9% |
| hammer2_disk.h | 1323 | 1173 | 222 | 222 | 222 | 8.9% |
| hammer2_lz4.c | 525 | 542 | 25 | 25 | 27 | 2.3% |
| hammer2_lz4_encoder.h | 467 | 467 | 0 | 0 | 0 | 0.0% |
| hammer2_lz4.h | 93 | 93 | 0 | 0 | 0 | 0.0% |
| hammer2_ccms.c / .h | 311 / 194 | absent | | | | dropped by every port |
| hammer2_iocom.c | 387 | absent | | | | dropped |
| hammer2_msgops.c | 87 | absent | | | | dropped |
| hammer2_synchro.c | 1069 | absent | | | | dropped |

Port-only files: `hammer2_os.h` (FB 552, NB 489, OB 474), `hammer2_compat.h`
(59, 121, 127), `hammer2_rb.h` (140 in each).

The three ports agree with each other to within a few lines on every file
except `hammer2_vnops.c` (OpenBSD +242) and `hammer2_mount.h`; the port is
one design applied three times, which is the strongest evidence on this disk
that a fourth application is a bounded job.

## Classification

- **CORE-REUSABLE**: `hammer2_lz4_encoder.h`, `hammer2_lz4.h`; and by
  intent though not by the 2% line, `hammer2_disk.h` (8.9%, the on-disk
  format; the diff is include and type churn, to be confirmed line by line
  in H1 because a format header that differs semantically between ports is
  a compatibility defect).
- **PORTABLE-WITH-ADAPTER**: `hammer2_lz4.c`, `hammer2_disk.h`; and the
  algorithm files whose ratio is dominated by the shim's renamed primitives
  rather than by logic: `hammer2_flush.c`, `hammer2_xops.c`,
  `hammer2_chain.c`, `hammer2_bulkfree.c`, `hammer2_freemap.c`,
  `hammer2_inode.c` (22 to 31%). Table 3 below is the evidence: the port's
  extra references in these files are `hprintf`, `hpanic`, `hmalloc`,
  `hfree`, `KKASSERT` and the `hammer2_mtx_*` / `hammer2_spin_*` wrappers,
  which is renaming, not redesign. H1 confirms this by diffing with the
  wrappers normalized.
- **OS-SPECIFIC** (rewritten by every port; the Linux port rewrites them
  too): `hammer2_vnops.c`, `hammer2_vfsops.c`, `hammer2_io.c`,
  `hammer2_strategy.c`, `hammer2_admin.c`, `hammer2_ioctl.c` and `.h`,
  `hammer2_ondisk.c`, `hammer2_subr.c`, `hammer2.h`, `hammer2_mount.h`,
  `hammer2_cluster.c` (gutted), plus the port-only shim files.
- **DRAGONFLY-INSEPARABLE**, by the ports' own decision: `hammer2_ccms.*`,
  `hammer2_iocom.c`, `hammer2_msgops.c`, `hammer2_synchro.c`. Every port
  dropped them; they are the clustering and cache-coherency layer, and
  document 02's question of whether `libdmsg` clustering is separable is
  answered: the ports separated it by deletion. A Linux port does the same
  and clustering is H7.
- **UNKNOWN**: none at file granularity. Within the OS-SPECIFIC files, which
  functions are port logic and which are carried is the H1 reading.

## The shim, measured (FreeBSD `hammer2_os.h` and `hammer2_compat.h`)

Defined names by concern:

- locking: `hammer2_lk_*` (4), `hammer2_lkc_*` (4), `hammer2_mtx_*` (12
  including temp_release/restore), `hammer2_spin_*` (6)
- asserts and reporting: `KKASSERT`, `KASSERTMSG`, `hpanic`, `hprintf`,
  `debug_hprintf`, `HFMT`, `HARGS`, `print_backtrace`, and the
  `*_assert_*` family for lk, mtx and spin
- memory: `hmalloc`, `hrealloc`, `hfree`, `hstrdup`, `hstrfree`,
  `adjust_malloc_leak`, two `MALLOC_DECLARE` types
- timing: `getticks`, and sleep/wakeup through the lock wrappers
- cpu: `cpu_ccfence`, `cpu_pause`
- buffer and cluster I/O: `cluster_init_vn`, `cluster_write_vn`,
  `FREEBSD_CLUSTERW_STRUCTURE`
- vnode/VFS version gates: `FREEBSD_VNODE_STATE`, `FREEBSD_NDINIT_ARGUMENT`,
  `FREEBSD_READDIR_COOKIES_64`

Shim references per port file (top three): chain 276 (KKASSERT 76, hpanic
40, spin_unex 40); vfsops 167 (KKASSERT 38, hprintf 35, debug_hprintf 16);
inode 101; ondisk 79 (hprintf 43); io 71 (mtx_unlock 16); vnops 71; flush
60; strategy 45; bulkfree 44 (hprintf 32); freemap 41 (KKASSERT 37); ioctl
41; admin 39; xops 19; cluster 8; subr 4; lz4 2. Against the DragonFly core
the same names count far lower (vfsops 45, ioctl 8, bulkfree 2): the gap is
the ports replacing `kprintf`, `panic`, `kmalloc` and `kfree` with wrappers,
which is what makes the algorithm files' diff ratios larger than their logic
changes.

## DragonFly kernel interfaces in the core, by file

Occurrences (substring counts, so `vop_` includes the `hammer2_vop_*`
definitions and `xop` includes the `hammer2_xop_*` idiom):

| file | struct buf | bread | bwrite | bdwrite | cluster_write | getblk | vop_ | VOP_ | lockmgr | lwkt_ | mtx_ | spin_ | kmalloc | kfree | objcache | tsleep | wakeup | xop |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| admin.c | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 2 | 5 | 0 | 8 | 5 | 5 | 4 | 12 | 7 | 299 |
| bulkfree.c | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 2 | 89 | 0 | 1 | 0 | 0 |
| chain.c | 1 | 2 | 0 | 0 | 0 | 1 | 0 | 0 | 3 | 0 | 29 | 80 | 2 | 3 | 0 | 5 | 4 | 0 |
| flush.c | 1 | 0 | 1 | 0 | 0 | 1 | 1 | 1 | 0 | 0 | 0 | 10 | 0 | 1 | 0 | 4 | 3 | 13 |
| inode.c | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 0 | 0 | 0 | 27 | 33 | 1 | 1 | 0 | 4 | 1 | 167 |
| io.c | 4 | 1 | 1 | 2 | 3 | 6 | 0 | 0 | 0 | 0 | 0 | 7 | 1 | 5 | 0 | 4 | 2 | 0 |
| ioctl.c | 1 | 1 | 1 | 0 | 0 | 0 | 0 | 2 | 10 | 0 | 0 | 2 | 0 | 16 | 0 | 0 | 0 | 44 |
| ondisk.c | 1 | 1 | 0 | 0 | 0 | 0 | 0 | 3 | 0 | 0 | 0 | 0 | 2 | 3 | 3 | 0 | 0 | 0 |
| strategy.c | 6 | 0 | 2 | 4 | 0 | 0 | 11 | 0 | 0 | 0 | 15 | 0 | 0 | 2 | 10 | 0 | 1 | 100 |
| synchro.c | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 1 | 3 | 0 | 4 | 2 | 87 |
| vfsops.c | 0 | 0 | 0 | 0 | 3 | 0 | 0 | 3 | 16 | 2 | 10 | 14 | 12 | 11 | 18 | 8 | 12 | 81 |
| vnops.c | 3 | 0 | 1 | 3 | 3 | 3 | 193 | 0 | 0 | 0 | 20 | 12 | 1 | 3 | 1 | 2 | 0 | 104 |
| xops.c | 0 | 0 | 0 | 0 | 0 | 0 | 6 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 327 |

Files with a zero row (ccms, cluster, freemap, iocom, lz4, msgops, subr) are
omitted except where they have one nonzero cell above.

What the table says for the Linux port: the buffer-cache surface (`struct
buf`, `bread`, `bwrite`, `bdwrite`, `cluster_write`, `getblk`) is confined
to `io.c`, `strategy.c`, `vnops.c`, `chain.c`, `flush.c`, `ioctl.c` and
`ondisk.c`, which is the buffer/cluster I/O concern's exact footprint; the
`xop` machinery (admin, xops, inode, vnops, strategy, synchro) is the
worker-thread model and is the second design item; `objcache` (vfsops 18,
strategy 10) is the third, mapped to `kmem_cache`. `lockmgr` in `vfsops`
and `ioctl` is vnode-lock use that Linux's inode locking replaces.

## What this audit does not decide

Which functions inside the OS-SPECIFIC files are port logic and which are
carried algorithm; how much of the chain, flush and inode diff survives
normalizing the wrapper names; and whether `hammer2_disk.h`'s 222 diff lines
are all non-semantic. Those three are H1's first reading, and the H1 estimate
is not written until they are done.
