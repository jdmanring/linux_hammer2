# The H1 estimate

`HAMMER2_LINUX_PORT_PLAN.md` assigns this to the implementation session
and puts it after the three first-week readings, not before. All three
are now recorded in this directory. This is what they add up to.

It is stated as scope and named unknowns rather than as a date. The
upstream strategy's refusal to give a maintainer a timeline is right and
is a different question from whether we size our own work; what follows
is for James, and nothing in it goes outside this project.

## What H1 has to produce

The plan's exit criterion: mounts DragonFly-created media read-only,
walks directories, reads files, discovers PFS roots and snapshots,
`stat` and `statfs`, clean unmount, passes F1 and F2 and detects the F3
corruptions without modifying media.

## Scope, from reading 3

Starting from Kusumi's FreeBSD tree rather than from DragonFly, because
the DragonFly-to-port transition is already paid and a second port
changed 8% of the core:

| | lines | what H1 does with it |
|---|---|---|
| `chain`, `flush`, `freemap`, `bulkfree`, `xops`, `admin` | 10,556 | carried; three of these were identical between two ports and `chain` differed by 10 statements |
| `vnops`, `vfsops`, `ondisk`, `io`, `strategy`, `inode` | 9,321 | the rewrite zone, of which H1 needs the read half |
| `hammer2_os.h`, `hammer2_compat.h` | 611 | a fourth version, Linux |
| headers, vendored LZ4/xxHash/zlib, `ioctl.c` | the remainder | carried or deferred; `ioctl.c` is redesigned in H4, not ported |

H1 does not need the whole rewrite zone. The write half of `vnops`, the
dirty tracking in `io`, and the write path in `strategy` are H2's. A
read-only driver is the shim, the DIO layer, `fs_context` and
`super_operations`, `lookup` and `getattr`, `iterate_shared`,
`read_folio`, and `statfs`.

## What the readings removed from the risk

Reading 1: no spin region sleeps under its lock, so `rw_semaphore` is
legal at all 62 port-relevant sites, and the audit the plan scheduled as
a per-site sweep of 177 regions (177 was a token count, never a region
count) is a sweep of 62 that is already done and recorded. Two sites
need `__acquires()` and `__releases()`; one is an upstream question for
Dillon that does not block the port.

Reading 2: the block device page cache supplies 64 KiB folios at exactly
`HAMMER2_PBUFSIZE`, so the DIO layer is a mapping onto an existing
mechanism rather than a reimplementation of the BSD buffer cache, and it
satisfies reading 1's constraint without a workqueue. This is the single
largest reduction the three readings made: the plan's provisional design
had us owning memory, caching, writeback and reclaim.

Reading 3: the algorithm core is OS-agnostic in practice, measured rather
than assumed, so the carried 10,556 lines are genuinely carried.

## What they did not remove

The rewrite zone is a rewrite and not a diff. Reading 3's 8% is a floor
taken between two kernels that share a vnode, a `struct buf` and the same
lock idioms. Linux shares none of that, so `hammer2_vnops.c` at 28%
between two BSDs is a new file against Linux, and `hammer2_vfsops.c`
nearly so. The honest scope for H1 is: carry 10,556 lines, write a 611
line shim, and write the read half of roughly 9,300 lines of OS-facing
code against an unfamiliar VFS.

Three unknowns remain, each with the thing that resolves it:

- the inode and dentry lifecycle against HAMMER2's chain and inode
  refcounting, which no reading here touched. Resolved by writing
  `lookup` and `iterate_shared` against F1, not by more archaeology.
- whether the vendored LZ4, xxHash and zlib copies are unmodified, so the
  module can use Linux's own. Open inside H0 by the audit's own list; one
  diff each.
- `sys/libkern` helpers from a full DragonFly clone, also open inside H0.

## The one external calibration

Kusumi's FreeBSD port reached a mounting read-only driver at `v1.0.0`
(2022-11-25) and dropped the mandatory read-only mount at `v1.1.5`
(2023-09-25). Ten months for H1 through H2, one developer, part-time, on
a port between two BSD VFS layers with the DragonFly transition being
made for the first time as he went.

Every term of that cuts a different way here and they do not cancel. He
was paying the DragonFly transition that reading 3 shows we inherit, and
he was writing the first shim rather than a fourth; against that, he
already knew the format, and his target VFS was the familiar one. It
bounds nothing and it is the only interval of this shape that exists.

## What this says to James

H1 is a bounded piece of kernel work, not a research program: about ten
thousand lines carried without modification, six hundred written fresh,
and the read half of nine thousand rewritten against Linux's VFS. It
needs no decision from you to begin and no compile authorization, since
nothing here builds until the package exists.

What it does need from you, when H1 reaches its gate rather than now: the
DragonFly guest booted for F2 fixtures, and the upstream contact about
`hammer2_chain.c:2324`.

## Specification session's reading, 2026-08-25

Verified against `torvalds/linux` at `v6.18` from the forge, which their
5148d91 then showed was not this system's kernel (linux-7.1.8-cachyos; 6.18
was the pin until 2026-08-09, and this reader checked the old pin note
rather than the current kernel); their re-verification at v7.1 and v7.2
is the one that counts, and reading 2's dependency is now a range: `set_blocksize`
validates against `BLK_MAX_BLOCK_SIZE`, which is `SZ_64K` under
`CONFIG_TRANSPARENT_HUGEPAGE` and `PAGE_SIZE` without it, and ends in
`mapping_set_folio_min_order`; reading 2's mechanism is the kernel's own,
which is the ladder's rung 4 and the largest thing the readings removed.
The estimate's shape (scope and named unknowns, no date, the calibration
carried with every term that cuts against it) is the right one, and it goes
to James as it stands, with one correction to its own wording.

"Carried without modification" and "genuinely carried" overstate what
reading 3 measured, and by the rule this tree's `docs/errata.md` wrote the
same day: two ports derived from one ancestor agree because they were
derived from each other. Reading 3 is a sibling comparison and its own
numbers show the core moving between two BSDs that share a vnode and a
buffer cache: 8.0% over the whole core, `chain` by 10 statements of 2412,
every changed line in the OS-facing files. That is the floor for a kernel
that shares neither. So the honest form is: about ten thousand lines
carried through the shim with an 8% floor of touched lines, and the floor
measured between kernels closer to each other than either is to Linux. The
scope does not change; the word "unmodified" does, because a reader who
takes it literally will budget zero for the core and find the first
`chain` change on day one.
