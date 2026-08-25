Roadmap
=======

The path from a tree that type-checks to a driver other people can trust
with a root filesystem. Read this first if you want to know what this port
is trying to become, what is done, what is next, and where to help.

- **Audience:** anyone deciding whether to build on, review, or contribute
  to this port; the maintainers of the trees it comes from. It assumes you
  know what a filesystem driver is and nothing about this tree.
- **What it is:** milestones with exit criteria, the gate that verifies
  each, the fixtures each needs, and who owns what. It is the one place
  the order of the whole port is written down.
- **What it is not:** the status ledger (`README.status.md`, which says
  what exists and what has been verified today), the design record
  (`README.porting.md`, `ARCHITECTURE.md`, `IO_MODEL.md`), the
  contribution rules (`../CONTRIBUTING.md`), or a schedule. No dates are
  promised here; a milestone ships when its exit criterion is met and
  verified by the named gate.
- **How it is kept current:** every milestone names the instrument that
  reads its state, so the state is measured rather than remembered. The
  file is revised whenever a milestone closes, a decision below is taken,
  or a gate is added or retired. Anything that can drift is a pointer to
  where the truth is read, never a copy of it.

## How this file was built, and how to check it

Rewritten 2026-08-25 from the table of steps and checks this file used to
be, which named nothing else: no fixtures, no owners, no decisions, no
risks, no record of what had already shipped. Every part of it has a
source a reader can open, and the file is wrong wherever it disagrees
with that source.

| part of this file | taken from | not taken from |
|---|---|---|
| the stages H0 to H7 and the qualification bar | the port-stage section of the storage proposal this port serves (the distribution's storage proposal set, document 07, sections 6 and 8), restated here so this tree stands alone | this tree's own preferences |
| exit criteria per milestone | the distribution's `research/hammer2-linux/HAMMER2_LINUX_PORT_PLAN.md`, stage by stage | the roadmap's previous rows |
| the fixture set | `HAMMER2_TEST_FIXTURE_PLAN.md` in the same directory; F1 and the first F2 image exist as of 2026-08-25 (`tests/storage/hammer2/` in the distribution's tree) | this tree, which holds no fixture yet |
| what is verified today | the three gates, run on the day of writing: `test-shim.sh` 3 checks and `test-syntax.sh` 7, so 10 checks of which 3 are controls that must fail and do; the style gate COULD-NOT-RUN on a tree without `checkpatch.pl`; `README.status.md` says the same since `5638ec5` and points at the gates as the authority | memory |
| the calibration | the commit dates of Kusumi's FreeBSD port on the forge (`kusumi/freebsd_hammer2`): v1.0.0, the first read-only mount, 2022-11-25; v1.1.5, mandatory read-only dropped, 2023-09-25. The local clone is shallow and its `CHANGES` carries no dates | any estimate of our own |
| decisions | `README.porting.md` for the ones taken; the port plan's "decisions this plan takes, and the ones it leaves" for the open ones | this file |

## Where we are

Nothing mounts. The OS shim and the DIO layer type-check against real
kernel headers under two compilers, with controls that fail when they
should; no module has been built, loaded or run, and the folio-ceiling
check the mount path must make is recorded as the design
(`README.porting.md`) and not yet written, because there is no mount path.
The whole carried core is still to be imported. `README.status.md` has the
file-by-file inventory, the verified claims, and the version floor (6.15,
required by `BLK_MAX_BLOCK_SIZE`; exercised only at 7.2).

The first compile of a module against a kernel tree is the maintainer's
authorization and not a contributor's, because it is the first thing in
this tree that is not a syntax check. `src/sys/fs/hammer2/Makefile`
already invokes the kernel's build system, so "run make" is that act and
not a preparatory one. Everything in the 0.2 milestone below can be
prepared without it.

### The next moves

In order, and each unblocked today:

1. Import the carried core files with a provenance row for each, and
   extend the syntax gate to every one of them. The H1 estimate's carried
   set is `chain`, `flush`, `freemap`, `bulkfree`, `xops` and `admin`;
   whether `inode`, `subr` and `ondisk` join it is what the provenance
   CSV's carry column says, file by file, and not this list. This is the
   0.2 exit and needs no compile.
2. Write the read-side VFS entry (`fs_context`, `super_operations`,
   `lookup`, `getattr`, `iterate_shared`, `read_folio`, `statfs`) against
   the F1 fixtures' manifests, which is also what resolves the inode and
   dentry lifecycle unknown the H1 estimate names.
3. The first `make`, when authorized: 0.3.
4. The read-only mount of F1, then of the F2 root image: 0.4, the first
   milestone that proves the port reads the format.

## Versioning

Versions are milestones, not calendar releases. A version is claimed when
its exit criteria are all met, each verified by the named gate on a clean
tree, and the verification recorded in `CHANGES`. Until 1.0 the number
says how far along this ladder the driver is and nothing about stability.

The third number is the point release. It increments when a verified
deliverable lands inside the current milestone (a file imported with its
gate, a gate added, a decision taken and implemented) and is recorded in
the history table below with its date and the gate that verified it.

The milestones map onto the port stages of the plan this tree implements;
the stage names are kept beside the numbers so a reader of that plan and a
reader of this file are looking at the same thing. H0, archaeology, is
done in the plan's own terms and its deliverables live in the distribution's tree,
not here; this tree begins inside H1, and 0.1 is H1's first slice.

**Current version: 0.1.x.**

| version | stage | milestone | state |
|---|---|---|---|
| 0.1 | H1, first slice | Shim and DIO layer type-check | met |
| 0.2 | H1 | Whole core type-checks, ready to build | **next** |
| 0.3 | H1 | Module builds, loads and unloads | blocked on the compile authorization |
| 0.4 | H1 | Read-only mount of DragonFly-written media | fixtures exist; nothing reads them |
| 0.5 | H2 | Write path, verified on DragonFly | not started |
| 0.6 | H3 | Crash recovery | not started |
| 0.7 | H4 | Snapshots and checkpoints behind the storage model's adapter | waits on the storage model (see decisions) |
| 0.8 | H5 | PFS as storage domains | not started |
| 0.9 | H6 | Nix-scale hardening | not started |
| 1.0 | qualification | Flagship qualification | not started |

## History

What has shipped, assigned to point releases. Numbers before this file was
rewritten are assigned retroactively to the state at each commit; from
here on a row is added when the deliverable is verified.

| version | date | delivered | verified by |
|---|---|---|---|
| 0.1.0 | 2026-08-25 | initial import: OS shim, DIO layer on the block device page cache, format, ioctl and in-memory headers, vendored `sys/tree.h` and `sys/queue.h` (`8c84941`) | `script/test-shim.sh`, `script/test-syntax.sh` |
| 0.1.1 | 2026-08-25 | style gate's sort made locale-independent after a first CI run failed with every count identical and four lines reordered (`5269dd0`) | `script/test-checkpatch.sh` byte-comparing its baseline |
| 0.1.2 | 2026-08-25 | version floor corrected from memory to measurement, 6.15 by `BLK_MAX_BLOCK_SIZE`, each symbol dated at its tag (`bb9f2df`) | the table in `README.status.md` |
| 0.1.3 | 2026-08-25 | the folio ceiling's design recorded: a mount-time capability check by name, `mapping_max_folio_size_supported()`, with the build-time THP assert kept as the bootstrap instrument until a mount path exists (`0c80e3e`, documentation only; the check itself is 0.3 criterion 3) | `README.porting.md`, The DIO layer |
| 0.1.4 | 2026-08-25 | vendored headers stopped redefining the kernel's `LIST_HEAD` and `RB_ROOT`, found by adding gcc and a W=1 warning set beside clang (`8877e3f`) | `script/test-syntax.sh`, now 7 checks across two compilers |
| 0.1.5 | 2026-08-25 | the 64 KiB inventory: thirteen sites, seven the on-disk format and six the folio decision, in `IO_MODEL.md` (`3ad0dd4`) | the inventory itself, each site cited to a line |
| 0.1.6 | 2026-08-25 | this table got a reader, the module's absent `MODULE_LICENSE` was recorded with what decides its value (`d95e3aa`), and the style gate stopped writing a baseline and exiting 0 when it found none (`f42446e`) | `script/test-history.sh`, falsified on an unresolvable hash and on a table whose rows stop matching; the checkpatch branch exercised through a stub, all three cases read one invocation at a time |

## Fixtures, and which milestone each serves

A read test that compares one HAMMER2 reader against another proves that
the two agree, not that either is right, so every fixture carries a
manifest taken from the source tree. Images are never committed; a
fixture is its writer, its version, its command line and its manifest.

A manifest row today is path, size and content hash for a file, the
target for a symlink, and a type marker for a directory. It carries no
mode, owner, times, link count or filesystem statistics; a criterion that
needs one of those needs the column first, and says so below.

| set | what | written by | serves | state 2026-08-25 |
|---|---|---|---|---|
| F1 | six trees of known shape (empty, flat, deep, sizes one byte under, on and over each block-size boundary, links, names at the length limit) | `makefs -t hammer2` from Kusumi's port | 0.4 | exists; read back through `hammer2-fuse` against the source-tree manifest, byte-identical |
| F2 | the same trees written by a DragonFly kernel, plus what only the kernel makes: two PFS roots, a snapshot after modification, a tree after bulk-free, deleted files held by a snapshot | DragonFly 6.4.2 in a guest | 0.4, and the F1-against-F2 format-drift comparison | the installed ROOT of a DragonFly guest, read cold: 28,171 inodes, `fsck_hammer2` clean; 67 paths unreadable to an unprivileged user, 58 files recorded with size and `readfail` in place of a hash and 9 directories recorded by type with their contents unlisted; the rest needs the guest booted |
| F3 | F2 images with metadata deliberately damaged; `fsck_hammer2`'s verdict on each recorded first | a script over F2 | 0.4 (detection without modifying media) and 0.6 | unwritten |
| F4 | a tree written by this port, mounted and verified on DragonFly, then the reverse | this port and DragonFly | 0.5 | needs 0.5 |
| F5 | images captured mid-write under the crash matrix, first from the FreeBSD port as calibration | a crash harness in QEMU | 0.6 | needs 0.5 |
| F6 | a `makefs` image of a real Nix closure, hundreds of thousands of paths | `makefs -t hammer2` | 0.9 | needs a build host's closure |

The fixture plan, the scripts that produce F1 and F2, and the provenance
CSV (`research/hammer2-linux/legal/hammer2-provenance.csv`) live in the
the distribution tree today. Whether they move here is a decision below; until it
is taken the gates here name them by their path there.

## Milestones

Each milestone states what a stranger can measure to confirm it is met,
the gate that measures it, who owns the work, what it depends on, and what
happens if a risk lands. "Gate" always means a script that exits 0 on
pass, nonzero on fail, and 2 when it could not run, which is not a
verdict. "Maintainer" is the owner of this repository; "contributor" is
anyone else sending a change; "the storage program" is the distribution's storage model work, which this port serves and does not contain.

### 0.2 Whole core type-checks, ready to build

Exit criteria:

1. Every carried core file the status document lists as absent is in
   `src/sys/fs/hammer2/`, and every file under that directory has a row
   in the provenance CSV naming its origin tree, commit and license.
2. `script/test-syntax.sh` covers every `.c` under `src/` and passes under
   both compilers with the W=1 warning set, with its two controls still
   failing.
3. `src/sys/fs/hammer2/Makefile`'s `hammer2-y` lists every object,
   verified by reading it against the directory. The build itself is 0.3.
4. Every `XXX` mark in the carried files (the BSD ports' convention for a
   non-mechanical mapping) is counted, and the count is recorded in
   `README.status.md` so the next reader knows how many places are not a
   carry.

Gate: `script/test-syntax.sh`, extended file by file as each lands. The
check behind criterion 1, that no file under `src/sys/fs/hammer2/` lacks
a provenance row, is unwritten: the provenance script today scans the
upstream clones and answers about them, not about this tree, so the
import rule exists as prose until that check is the first work item
below.

Work items:

| item | owner | done when |
|---|---|---|
| a check that every file under `src/sys/fs/hammer2/` has a provenance row, with a control that an unlisted file fails it | contributor | it runs from `script/` and exits 2 without the CSV |
| import the estimate's six carried files, then `inode`, `subr`, `ondisk` as the CSV classifies them | contributor | each type-checks under both compilers |
| import the check algorithms, using the kernel's own xxHash, LZ4 and zlib as the vendored-library audit found them stock | contributor | the syntax gate covers them |
| count the `XXX` marks and record it | contributor | the number is in `README.status.md` |

Owners: contributors for every item; the maintainer for merging.

Depends on: nothing. This is desk work against the FreeBSD port's tree,
the shape `hammer2.h` already follows.

Risks and contingency:

| risk | contingency | blocks 0.2? |
|---|---|---|
| a carried file will not type-check without a core edit | the edit is made in the shim if the shim can express it, otherwise in place with an `XXX`, and the count in criterion 4 is what makes that visible rather than silent | no |
| the recursion the inode and chain locks need (`README.porting.md`, Locks) turns out to be reached in more than NetBSD's two call sites | the sites are listed before any is changed, and the shim's `rw_semaphore` decision is re-read against the list rather than patched around | no; yes for 0.3 if the count is large |

Last reviewed: 2026-08-25.

### 0.3 Module builds, loads and unloads

Exit criteria:

1. `make` produces `hammer2.ko` against the pinned kernel's headers with
   no warning in a file under `src/`.
2. `insmod hammer2.ko` succeeds, `/proc/filesystems` lists `hammer2`, and
   `rmmod` leaves no reference, no leaked allocation under `kmemleak`, and
   no lockdep report, in a guest with `CONFIG_PROVE_LOCKING` on.
3. The mount path calls `mapping_max_folio_size_supported()` and a kernel
   that cannot supply a 64 KiB folio is refused by name, with the
   kernel's answer in the message; the refusal is exercised by a control
   rather than read off the source; whether the build-time assert stays
   as a second guard on `BLK_MAX_BLOCK_SIZE` (a different ceiling, per
   `IO_MODEL.md`) is decided then, and the syntax gate's ceiling control
   moves or retires with it.

Gate: a build-and-load script, unwritten, that runs in a disposable guest
and exits 2 without one. The first run of it is the compile authorization
the maintainer holds.

Work items:

| item | owner | done when |
|---|---|---|
| the first `make` | maintainer | `hammer2.ko` exists |
| the build-and-load gate, with a guest that has the debug options on | contributor, run by the maintainer | each of criterion 2's observations is printed by the gate |
| the mount-time capability check and its control | contributor | criterion 3 |

Owners: the maintainer for the authorization and every run; contributors
for the gate and the check.

Depends on: 0.2; a guest with the pinned kernel and debug options.

Risks and contingency:

| risk | contingency | blocks 0.3? |
|---|---|---|
| the module links but the load oopses in init | the init path is the shim's, not the core's, so the fault is in fewer than a thousand lines and the guest's console is the instrument | yes, until fixed |
| the kernel floor of 6.15 is wrong in the exercised direction (a symbol used here changed after 7.2) | the syntax gate is run against the newest tree available, `KDIR` pointing at it, before the floor is quoted again | no |

Last reviewed: 2026-08-25.

### 0.4 Read-only mount of DragonFly-written media

This is the first milestone that proves anything about the format, and
the reason the port exists. It is the plan's H1 exit.

Exit criteria:

1. Every F1 fixture mounts read-only and path, size, content hash and
   symlink target match the source-tree manifest for every row. Hard-link
   identity, `stat` fields and `statfs` are compared once the manifest
   carries a column for each (a fixture work item below); until then they
   are checked by hand and the claim says so.
2. The F2 root image mounts read-only and every row of its manifest
   matches; the 67 paths unreadable to an unprivileged user are read as
   root, the 58 files gain a hash and the 9 directories their contents,
   added to the manifest from that read and compared from then on.
3. PFS roots and snapshots are discoverable and mountable by label.
4. Each F3 corruption is detected and refused, or detected and reported,
   without modifying the media; the media's hash is the same before and
   after, and the verdict agrees with `fsck_hammer2`'s recorded one.
5. Clean unmount leaves no dirty folio, no leaked `hammer2_io`, and no
   lockdep report.
6. F1 against F2 for the same tree shapes: every difference between a
   `makefs`-written volume and a kernel-written one is listed, so a later
   reader knows which of the two the port was developed against.

Gate: a read-only fixture gate, unwritten, that builds the module, boots a
guest, mounts every F1 and F2 fixture, compares manifests, runs F3, and
exits 2 without a guest. The distribution's plan names it
`test-hammer2-linux-ro.sh`; whichever tree it lands in, this file points at
it once it exists.

Work items:

| item | owner | done when |
|---|---|---|
| the read-side VFS entry, `lookup` and `iterate_shared` first | contributor | F1 `empty` and `flat` list correctly |
| `read_folio` and the DIO read path end to end | contributor | F1 `sizes` matches at every boundary |
| the manifest gains link-count, mode and owner columns, and the F1 generator writes them | the tree that holds the generator | criterion 1's second sentence retires |
| F3, with `fsck_hammer2`'s verdicts recorded first | contributor | criterion 4 has something to run |
| the remaining F2 images | maintainer (the guest boot) | F2's row above stops saying "the rest needs the guest booted" |
| the read-only gate | contributor | it runs in a guest and exits 2 without one |

Owners: contributors for the driver, the gate and F3; the maintainer for
the guest boot; the tree that holds the generator for the manifest
columns.

Depends on: 0.3; the F2 set beyond the first image needs the DragonFly
guest booted, which is the maintainer's call. Criterion 1 needs nothing
but F1, which exists.

Risks and contingency:

| risk | contingency | blocks 0.4? |
|---|---|---|
| the guest never boots, so F2 stays at one image | F1 carries criterion 1 and the single F2 root carries criterion 2; criteria 3 and 6 are recorded as unrun rather than assumed, and the milestone is claimed with that qualifier stated | no for 1 and 2; yes for 3 and 6 |
| the inode and dentry lifecycle does not fit the core's refcounting | this is the one unknown the H1 estimate could not size by reading; it is resolved by writing `lookup` against F1 first, before `read_folio`, so the failure is found on the smallest surface | yes, until designed |
| a manifest mismatch on one fixture with the others clean | read the underlying record before concluding: `sizes` puts a file one byte under, on, and one byte over each block-size boundary, so an off-by-one shows at a boundary file and its two neighbors and nowhere else | no; it is what the fixture is for |

Last reviewed: 2026-08-25.

### 0.5 Write path, verified on DragonFly

Exit criteria:

1. Create, write, truncate, `mkdir`, `unlink`, `rename`, `setattr`,
   xattrs, `fsync` and `sync`, then clean unmount, on a volume this port
   created.
2. F4 round trip: a tree written here mounts on DragonFly and its manifest
   matches; a tree written on DragonFly, modified here, mounts on
   DragonFly and matches. HAMMER2's default per-blockref check is XXH64,
   so a subtly wrong writer reads as corruption there rather than as a
   bug, and this is the only test that separates the format from a
   dialect of it.
3. The format fuzzing corpus, seeded from F3, runs against the mount path
   with no crash, before any writable root is offered.
4. The flush path orders its writes so that the root checkpoint is durable
   only after everything it references, verified by a write trace and not
   by reading the source.

Gate: the 0.4 gate extended with F4 and the fuzz corpus.

Owners: contributors for the write path, F4 and the corpus; the maintainer
for the DragonFly or FreeBSD guest the round trip needs and for the iomap
decision below.

Depends on: 0.4; a DragonFly or FreeBSD guest for the round trip; the
iomap-versus-address-space decision below, taken at the start of this
milestone.

Risks and contingency:

| risk | contingency | blocks 0.5? |
|---|---|---|
| the freemap allocation path, carried from the core, assumes the BSD buffer cache's write ordering | the DIO layer's dirty tracking is where the ordering is expressed on Linux (`IO_MODEL.md`), and criterion 4's trace is what shows whether it holds | yes |
| the round trip fails in one direction only | that direction names the defect: DragonFly refusing ours is a writer bug here; ours refusing DragonFly's is a reader bug that 0.4 missed, and 0.4 is reopened | yes |

Last reviewed: 2026-08-25.

### 0.6 Crash recovery

Exit criteria:

1. The crash matrix (process kill, kernel panic, power-off, torn metadata
   write) during a write workload, in QEMU with a disposable block
   device, leaves a volume that mounts, recovers to a committed state, and
   passes `fsck_hammer2` with the same verdict this port gives.
2. F5 fixtures exist for every cell of the matrix, captured first from the
   FreeBSD port so that "what a working port leaves behind" is measured
   before this port is judged against it.
3. A non-deterministic cell is recorded as such and never reported green.

Gate: the crash matrix harness, unwritten, calibrated against the FreeBSD
port first.

Owners: contributors for the harness and the recovery path; the maintainer
for the FreeBSD guest.

Depends on: 0.5; a FreeBSD guest for the calibration.

Risks and contingency:

| risk | contingency | blocks 0.6? |
|---|---|---|
| the matrix cannot be made deterministic in QEMU | criterion 3: a cell that cannot be made to repeat is listed with its repeat count, and the milestone is claimed only over the cells that do | yes, for those cells |

Last reviewed: 2026-08-25.

### 0.7 Snapshots and checkpoints behind the storage model's adapter

Exit criteria:

1. The ioctl surface is redesigned as Linux ioctls (the API map's
   interface-redesign row) and snapshot creation, listing and deletion
   work through it.
2. A backend adapter implements `prepare_checkpoint`, `verify`,
   `make_durable`, `activate`, `rollback`, `release` and
   `list_recovery_points` on HAMMER2 snapshots and passes the universal
   snapshot conformance suite of the storage model this port serves.

Gate: criterion 1 by an ioctl exerciser added to the read-only gate;
criterion 2 by the storage model's conformance suite, which belongs to
that program and not to this tree.

Owners: contributors for the ioctls; the storage program for the suite
and the adapter's contract.

Depends on: 0.6; the storage model's own epics S1 to S3 (the model, the
registry and the reference backend). This is where the port and the
storage program meet, and the plan does not let this milestone start
before those exist, because an adapter written against no model is a
second model. A contributor who wants HAMMER2 snapshots without the
storage model gets criterion 1 and stops there.

Risks and contingency:

| risk | contingency | blocks 0.7? |
|---|---|---|
| S1 to S3 do not exist when 0.6 closes | criterion 1 ships alone as 0.7's first point release, and 0.7 stays open on criterion 2 with that stated | yes, for criterion 2 |

Last reviewed: 2026-08-25.

### 0.8 PFS as storage domains

Exit criteria:

1. The domains the storage model names (SYSTEM, STORE, PERSISTENT, BUILD,
   CACHE, RECOVERY and BOOT among them) map to PFS roots, with the mapping
   derived from measurement on the workload rather than assumed.
2. An installer lays them down through the adapter.

Gate: the storage model's conformance suite over a volume laid down by the
installer, and the read-only gate mounting each PFS by label.

Owners: contributors for the mapping and its measurement; the storage
program for the installer.

Depends on: 0.7; an installer that selects a backend by declaration.

Risks and contingency:

| risk | contingency | blocks 0.8? |
|---|---|---|
| the model adds a domain | the mapping is derived per domain, so one more is one more measurement, not a redesign | no |

Last reviewed: 2026-08-25.

### 0.9 Nix-scale hardening

Exit criteria:

1. F6 (a real Nix closure, hundreds of thousands of paths) reads at a
   measured cost recorded beside the same read on squashfs or erofs.
2. Million-file trees, parallel builds, store garbage collection,
   snapshots retained under churn, low memory and near-capacity operation
   all pass, each with the number it produced.
3. The workqueue-backed XOP pool decision below is taken on F6's numbers.

Gate: an F6 harness, unwritten, that runs each workload in a guest and
records its number; a run without a number is not a pass.

Owners: contributors for the harness; the maintainer for the build host
that supplies the closure and the hours.

Depends on: 0.8; a build host with the workload.

Risks and contingency:

| risk | contingency | blocks 0.9? |
|---|---|---|
| synchronous XOPs are the bottleneck at scale | that is what criterion 3 decides, on the number rather than in advance; the pool is designed then, against the measurement | no; it is the milestone's own question |

Last reviewed: 2026-08-25.

### 1.0 Flagship qualification

The bar the storage proposal sets, restated here so this tree does not
depend on it: HAMMER2 becomes a flagship only after it passes the same
universal conformance suite as OpenZFS and Btrfs and demonstrates correct
crash recovery, stable Nix-scale metadata behavior, predictable resource
accounting, correct checkpoint and generation semantics, sustained
performance under the mission-profile workloads, reproducible builds,
clean provenance, and a credible upstream maintenance plan. The port
plan adds, and this file keeps: no relaxed standard for being the
flagship.

Exit criteria:

1. Every milestone 0.4 through 0.9 claimed with its gate green on a clean
   tree, and no milestone carrying a qualifier.
2. The provenance CSV covers every file with origin, copyright and
   license, and the carried files carry their upstream notices unchanged.
3. The two findings staged for upstream (the `reptrack->spin` release in
   `hammer2_chain_repchange()` in every tree that carries it, and
   libhammer2's `Drop` after a failed mount) have been filed by the
   maintainer and their state recorded here.
4. An out-of-tree release that a distribution can package: a tagged
   version, a `CHANGES` entry, and the gates runnable from the tarball.

Gate: the conformance suite plus every gate above.

Owners: the maintainer for criteria 3 and 4; everything else is what the
milestones above already own.

Depends on: everything above.

Risks and contingency:

| risk | contingency | blocks 1.0? |
|---|---|---|
| a filing in criterion 3 is refused or unanswered | the finding stays applied here with its provenance note, the refusal is recorded beside it, and the criterion is met by the record rather than by acceptance | no |

Last reviewed: 2026-08-25.

## Beyond 1.0

- H7, advanced storage: multi-device, replication, remote checkpoints,
  clustering. Every port dropped the cluster layer (`hammer2_ccms.c`,
  `hammer2_iocom.c`, `hammer2_msgops.c`, `hammer2_synchro.c`) and so does
  this one; investigate after qualification, not before.
- Mainline submission. The BSD license permits it, which OpenZFS's CDDL
  does not, and that is an asset to spend once, after qualification: a
  mainline submission of an immature filesystem driver is refused and
  remembered. The style conversion in `README.kernel-style.md` happens at
  that moment, whole tree at once, or not at all.
- Tracking DragonFly's core: the carried files exist to be replaceable by
  the next sync, and a sync cadence is decided when there is a driver to
  sync into.

## Decisions that gate the roadmap

Each is the maintainer's. Nothing here is decided by a contributor, and
each names what it blocks so the cost of leaving it open is visible.

| decision | blocks | taken so far |
|---|---|---|
| The first compile of a module against a kernel tree | 0.3 and everything after it | open |
| Booting the DragonFly guest for the rest of the F2 set | 0.4 criteria 3 and 6 | open; the first F2 image was taken with the guest shut off and needed no decision |
| iomap versus classic address-space operations for file data | 0.5's first commit would otherwise settle it by default; the plan's lean is iomap, which is what a mainline reviewer would ask for, unless the 64 KiB physical buffers argue otherwise | open, due at the start of 0.5 |
| A workqueue-backed XOP pool against synchronous XOPs | 0.9 criterion 3 | synchronous for 0.2 to 0.6, the FreeBSD port's choice; the pool is decided on F6's numbers |
| Where the fixtures, their generator scripts and the provenance CSV live: this tree, or the distribution's tree that holds them today | every gate from 0.4 on, and 0.2's provenance check, name a path there | open; they stay where they are until taken |
| The two upstream filings | 1.0 criterion 3 | drafted, unfiled |
| In-tree submission | nothing before 1.0 | deferred past qualification by the plan |

## Not on the roadmap

- Porting the DragonFly kernel, or any part of it beyond what the core
  needs from the shim.
- The cluster layer, before H7.
- 32-bit or HIGHMEM kernels: `hammer2_io_data()` hands the core a pointer
  it holds across sleeps, so the folio must be permanently mapped, and a
  `static_assert` refuses that build rather than corrupting quietly.
- Kernels older than 6.15, by `BLK_MAX_BLOCK_SIZE`.
- Replacing `hammer2-fuse`. It is an independent Rust reader of the same
  format over libhammer2, which is exactly what makes it useful as a
  second reader: a disagreement between the two is a finding about one of
  them.
- Converting the carried core to kernel style piecemeal.

## Revisions of this file

Dated, so a reader knows what changed in the plan and not only in the
driver. A revision is a change to structure, criteria, decisions or
non-goals; point releases go in the history table instead.

- 2026-08-25: written as a table of steps and checks (`8c84941`).
- 2026-08-25: row 3a, the folio capability check at mount (`0c80e3e`).
- 2026-08-25: rewritten in this shape: versions mapped to stages, history,
  fixtures, per-milestone criteria with gates, work items, owners,
  dependencies and risks, the decisions table, the non-goals, and this
  section. Then hostile audit rounds against the sources named above
  until one found nothing, all findings applied; the rounds are recorded
  in the distribution's tracker.

## Proposing a change

A change to a milestone's criteria is a change to what "done" means, and
it is made here, in one commit, with the source that justifies it. A
change to a port decision is made in `README.porting.md` first, and this
file follows. Everything else is `../CONTRIBUTING.md`.

## How to help

Pick a milestone, read its gate and its work items, and run the gates
before writing anything; they tell you what is true today and cost
seconds. Work that reaches for a compile is the maintainer's to authorize,
and a change that needs a decision above should say so rather than assume
it.
