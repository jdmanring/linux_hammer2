# Kusumi's three ports against the Linux port so far: what to adopt, what to keep

Measured 2026-08-25 from the clones on this disk (`freebsd_hammer2` 3df307f,
`netbsd_hammer2` 64095c3, `openbsd_hammer2` a3747df, all `v1.2.13`) and from
his `makefs` and `hammer2-utils` repositories on the forge. James's
question, verbatim: "What is the difference between his ports and ours? Is
ours better? Don't blindly adhere." The aim behind it: Tomohiro Kusumi
should open this tree, recognize it, and want it. His own index README
(`kusumi/hammer2`) lists `### Linux *TBD*`, so the slot is his and empty.

The answer is not one verdict. Row by row, one side is better, and the
plan takes each row from the side that is.

## What his ports are

Three repositories with one skeleton: `CHANGES`, `COPYRIGHT`, `Makefile`
(`SUBDIRS = src`), `README.md` (Requirements / Build / Install /
Uninstall, nothing else), `script/install.sh` and `uninstall.sh`, `src/sys/fs/hammer2/`
with the DragonFly core, and `src/sbin/` with the DragonFly userland.
Every commit is a version bump (`v1.2.13`), every release is "Sync with
DragonFly" plus a few lines, and the three are version-locked: the same
tag lands on all three the same week. He has done this since 2022 and it
is the routine he would expect a fourth port to join.

Inside `src/sys/fs/hammer2/` the OS surface is two files: `hammer2_compat.h`
makes the kernel look like FreeBSD's where it does not (NetBSD's carries
the atomics, `KKASSERT`, `cpu_pause`, `getticks`), and `hammer2_os.h`
(474 to 552 lines) is the HAMMER2 lock and malloc abstraction in a fixed
section order: version gates, `hprintf`/`hpanic`, `hammer2_lk`,
`hammer2_lkc`, `hammer2_mtx` (a wrapper struct with a `refs` field),
`hammer2_spin`, malloc types with `HAMMER2_MALLOC` leak accounting, the
vop table externs. Port-specific lines in the core carry a trailing
`/* FreeBSD */` (four in the whole tree) or a `#if __FreeBSD_version >=
FREEBSD_<NAME>` gate whose constant cites the upstream commit. Comments
are one line; doubts are `XXX` (80 to 98 per port). All three are
read-write ("Drop mandatory read-only mount" is in every CHANGES).

The kernel repositories carry no test or CI apparatus beyond
`fsck_hammer2/test.c`. `makefs` is where his Linux practice shows:
`src/sys/sys/{tree,queue}.h` vendored, `tree.h` edited under `#if defined
__linux__`, `queue.h` untouched, a `compat.h` beside them, and
`-I../../sys` so `<sys/tree.h>` resolves.

## Row by row

| axis | his ports | ours (2026-08-25) | better | plan |
|---|---|---|---|---|
| repository skeleton, README, CHANGES, COPYRIGHT, install scripts | one convention across three repos, three years of releases | a nix package directory with a status README | his: it is the thing he recognizes, and it costs nothing | adopt exactly: a `linux_hammer2/` tree in his layout that can become the fourth repository verbatim |
| shim split | `hammer2_compat.h` (kernel look-alikes) + `hammer2_os.h` (HAMMER2 abstraction), fixed section order | one `hammer2_linux.h` | his: two files with a known order is what a reader of the other three expects | adopt the split and the order; keep our content |
| source comments | one-liners, `/* FreeBSD */` tags, `XXX` | design prose in file headers | his, for the source; ours, for the reasoning | source goes terse with `/* Linux */` tags; the reasoning stays in `research/`, where it already is |
| lock primitives | sleeping rwlocks for `spin`, `mtx` and `lk` on all three (his os.h comment: "Normal synchronous non-abortable locks can be substituted for spinlocks") | `rw_semaphore` for all three, licensed by reading 1 | equal; ours has the audit written down | keep |
| `hammer2_mtx_owned` | FreeBSD `sx_xlocked`, NetBSD `rw_write_held`: by calling thread. OpenBSD `rrw_status == RW_WRITE`, with his own comment that the read case "doesn't necessarily mean read locked by calling thread" | wrapper tracks `owner`, because `rwsem_is_locked` cannot say who | ours equals his best two and beats OpenBSD's | keep |
| recursive `mtx` (two sites: `inode.c` "h2ip", `chain.c` "h2ch") | FreeBSD `SX_RECURSE`; OpenBSD `rrwlock` for every mtx; NetBSD has NO recursive lock and ships the two sites as plain `hammer2_mtx_init` with `/* XXX iplock */`, `/* XXX chlock */` and an added `vhold_lock` | `BUILD_BUG_ON` on `init_recurse` | NetBSD is the precedent for a non-recursive kernel and it is read-write in production | carry those two files from NetBSD's shape at those sites, not FreeBSD's; drop the `BUILD_BUG_ON` once they are |
| `hammer2_mtx_upgrade_try` | FreeBSD/NetBSD: native try-upgrade. OpenBSD: no primitive, so the shim UNLOCKS and calls `ex_try`, marked `/* XXX */` | no primitive; returns failure unless already exclusive, so the core's own failure path drops and revalidates | ours: the core already handles failure, and OpenBSD's shape returns to a caller that believes it still holds the shared lock when `ex_try` fails | keep; say so in one line where he would see it |
| physical buffers (`hammer2_io`) | the OS buffer cache: `bread`/`bwrite`/`cluster_write` through the device vnode, a second cache under the page cache | the block device's page cache: 64 KiB folios via `sb_set_blocksize`, the kernel owns caching, writeback, readahead and reclaim; the DIO hash holds metadata only (reading 2) | ours in design: no second cache, no copy, and Linux-native; his in evidence: three OSes, read-write, three years | keep, and be explicit that it is the unproven half; it is the one thing in the tree he has not already done, which is the reason to show it well |
| ceiling on buffer size | none | `CONFIG_TRANSPARENT_HUGEPAGE` for 64 KiB folios, asserted at build | his has no constraint | keep; a `#error` he can read is better than an `-EINVAL` at mount |
| assertions | `KKASSERT` -> `KASSERT`, compiled out without `INVARIANTS`; `HAMMER2_INVARIANTS` make knob adds file/line to `hprintf` | `BUG_ON` under `CONFIG_HAMMER2_DEBUG` | equal | adopt his knob names (`HAMMER2_INVARIANTS`, `HAMMER2_MALLOC`, `HAMMER2_ATIME`) so `make HAMMER2_INVARIANTS=1` means the same on four systems |
| malloc | `hmalloc(size, type, flags)` with per-type leak counters under `HAMMER2_MALLOC` | same signature, type discarded | his: it is his debugging tool and cheap | adopt the counters |
| errnos inside the module | positive | positive | same | keep |
| `hammer2_xop_gdata` refs | `atomic_add_32` on `focus_dio->refs`, DragonFly's lockless convention surviving into a port whose refs are lock-protected | `hammer2_io_ref()` under the dio lock | ours is consistent with the port's own rule | keep; one-line note |
| version gates | `#define FREEBSD_<NAME> <version>` with "See FreeBSD src <commit>", `#if __FreeBSD_version >= ...` | none; 7.2 only | his shape is right and ours has nothing to gate yet | `#error` below the tested kernel, README "Linux 7.2.x", and his constant shape the first time a gate is needed |
| BSD macro headers on Linux | `makefs`: vendored `sys/sys/{tree,queue}.h`, `tree.h` edited under `__linux__`, `compat.h` defines `__unused` with a note that headers naming it must come first | vendored the same way; `__unused` renamed to `__always_unused` in the two files rather than defined | ours, measured: in the kernel an array field named `__unused` fails to compile and a scalar one vanishes with a warning; his note is the same hazard handled by ordering, which a kernel module cannot promise | keep the rename; cite his note beside it so the difference reads as a measurement, not a disagreement |
| userland | `src/sbin/` C ports of the DragonFly tools | none | his `hammer2-utils` (Rust) already lists Linux with `newfs_hammer2`, `mount_hammer2`, `fsck_hammer2`, `hammer2` | no `src/sbin/`; README points at hammer2-utils, his own |
| provenance, license audit, check-algorithm vectors, syntax gates with negative controls, generator selftests | none in the kernel repos | all of it | ours | keep, OUTSIDE the upstreamable tree (`test/`, `scripts/`, `research/`), so his tree stays as lean as the other three and the evidence is one directory up |
| write path | shipped | H2 | his | not a design difference; the order of work |

## What this decides

Adopt from him, wholesale: the repository skeleton, the two-file shim
with its section order, the make knobs, the malloc counters, terse
source with `/* Linux */` tags, the version-gate shape, and hammer2-utils
as the userland. These are the things a fourth port has to share with
the other three to be one of them, and none of them costs a design.

Keep from ours, and present rather than hide: the page-cache DIO layer,
the ownership-tracking `mtx`, the explicit `upgrade_try` failure, the
`__unused` measurement, and the whole verification apparatus one
directory up. The DIO layer is the argument for the port existing at
all on Linux; the rest is what makes a reviewer trust it.

Follow NetBSD, not FreeBSD, at the two recursive-lock sites when those
two files are carried. That is the one place the comparison changed
what H1 was going to do.

## What was not compared

Runtime. His ports mount and write; ours has not been loaded. Every
"ours is better" above is a design reading and says nothing about
behavior until the first module build (James's) and the fixture plan's
mounts. Read the table with that in front of it.
