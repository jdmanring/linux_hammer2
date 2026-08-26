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

Every part of this file either names a source a reader can open, or is
stated here as this tree's own decision. Where it names a source and
disagrees with it, the file is wrong.

| part of this file | taken from | not taken from |
|---|---|---|
| the stages H0 to H7, the qualification bar, and the exit criteria per milestone | this file. They were drafted before this repository existed and are restated here, which makes this tree their statement of record | the roadmap's previous rows |
| the fixture set | the fixture table below, which is its statement of record. F1 and the first F2 image exist as of 2026-08-25 on the DragonFly guest that writes them. The images themselves cannot live here: `makefs -t hammer2` writes 8 GiB with no way to shrink it, so `test/fixtures/` holds the scripts and manifests that rebuild them | this tree, which holds no image |
| what is verified today | the gates' own printed counts, read by running them. No count is written here, because one written here is stale the next time a gate is added, and this row said six on a day the tree had nine. `README.status.md` points at the gates as the authority | memory, or a count written down here |
| the calibration | the commit dates of Kusumi's FreeBSD port on the forge (`kusumi/freebsd_hammer2`): v1.0.0, the first read-only mount, 2022-11-25; v1.1.5, mandatory read-only dropped, 2023-09-25. The local clone is shallow and its `CHANGES` carries no dates | any estimate of our own |
| decisions | `README.porting.md` for the ones taken; the decisions table below for the open ones | this file |

## Where we are

Nothing mounts. The OS shim, the DIO layer and the carried core type-check
against real kernel headers under two compilers, with controls that fail
when they should; no module has been built, loaded or run, and the
folio-ceiling check the mount path must make is recorded as the design
(`README.porting.md`) and not yet written, because there is no mount path.
One carried file, `hammer2_flush.c`, is still to be imported, and the
vnode, inode and mount paths have not been started at all.
`README.status.md` has the file-by-file inventory, the verified claims,
and the version floor (6.15,
required by `BLK_MAX_BLOCK_SIZE`; exercised only at 7.2).

The first compile of a module against a kernel tree is the maintainer's
authorization and not a contributor's, because it is the first thing in
this tree that is not a syntax check. `src/sys/fs/hammer2/Makefile`
already invokes the kernel's build system, so "run make" is that act and
not a preparatory one. Everything in the 0.2 milestone below can be
prepared without it.

### The next moves

In order, and each unblocked today:

1. Import `hammer2_flush.c`, the last of the H1 estimate's carried set
   (`chain`, `flush`, `freemap`, `bulkfree`, `xops`, `admin`), and extend
   the syntax gate to it. It needs a port decision rather than a shim:
   it issues a device cache flush, which FreeBSD does through GEOM and
   NetBSD through `DIOCCACHESYNC`, so there is no precedent to copy and
   Linux's answer is `blkdev_issue_flush()`. Whether `inode`, `subr` and
   `ondisk` join the carried set is what the provenance CSV's carry
   column says, file by file, and not this list. This closes 0.2 and
   needs no compile.
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
tree, and the verification recorded in `../CHANGELOG.md`. Until 1.0 the number
says how far along this ladder the driver is and nothing about stability.

The third number is the point release. It increments when a verified
deliverable lands inside the current milestone (a file imported with its
gate, a gate added, a decision taken and implemented) and is recorded in
`../CHANGELOG.md` with its date and the gate that verified it.

The milestones carry stage names, H0 to H7, beside their version numbers.
H0, archaeology, was finished before this repository existed and left no
artifact in it; this tree begins inside H1, and 0.1 is H1's first slice.

**Current version: 0.2.x.**

| version | stage | milestone | state |
|---|---|---|---|
| 0.1 | H1, first slice | Shim and DIO layer type-check | met |
| 0.2 | H1 | Whole core type-checks, ready to build | **in progress**: criteria 1, 2 and 4 met, criterion 3 waits on `hammer2_flush.c` |
| 0.3 | H1 | Module builds, loads and unloads | blocked on the compile authorization |
| 0.4 | H1 | Read-only mount of DragonFly-written media | the generators exist, the images are build output, and no gate here drives a guest |
| 0.5 | H2 | Write path, verified on DragonFly | not started |
| 0.6 | H3 | Crash recovery | not started |
| 0.7 | H4 | Snapshots and checkpoints behind the storage model's adapter | waits on the storage model (see decisions) |
| 0.8 | H5 | PFS as storage domains | not started |
| 0.9 | H6 | Nix-scale hardening | not started |
| 1.0 | qualification | Flagship qualification | not started |

## History

Every point release, with the commit that delivered it and the gate that
verified it, is in `../CHANGELOG.md`. It lives at the root rather than
here because it is the record a packager and a reviewer look for first,
and because this file is about what has not happened yet.

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
| F1 | six trees of known shape (empty, flat, deep, sizes one byte under, on and over each block-size boundary, links, names at the length limit) | `makefs -t hammer2` from Kusumi's port | 0.4 | generator run and its output read back through `hammer2-fuse` against the source-tree manifest, byte-identical. The images were deleted as they were written, per the section below; nothing is on disk to point a gate at |
| F2 | the same trees written by a DragonFly kernel, plus what only the kernel makes: two PFS roots, a snapshot after modification, a tree after bulk-free, deleted files held by a snapshot | DragonFly 6.4.2 in a guest | 0.4, and the F1-against-F2 format-drift comparison | the installed ROOT of a DragonFly guest, read cold: 28,171 inodes, `fsck_hammer2` clean; 67 paths unreadable to an unprivileged user, 58 files recorded with size and `readfail` in place of a hash and 9 directories recorded by type with their contents unlisted; the rest needs the guest booted |
| F3 | F2 images with metadata deliberately damaged; `fsck_hammer2`'s verdict on each recorded first | a script over F2 | 0.4 (detection without modifying media) and 0.6 | unwritten |
| F4 | a tree written by this port, mounted and verified on DragonFly, then the reverse | this port and DragonFly | 0.5 | needs 0.5 |
| F5 | images captured mid-write under the crash matrix, first from the FreeBSD port as calibration | a crash harness in QEMU | 0.6 | needs 0.5 |
| F6 | a `makefs` image of a real Nix closure, hundreds of thousands of paths | `makefs -t hammer2` | 0.9 | needs a build host's closure |

### What "the fixtures exist" means, and what moves here

The generators exist and have been run; the images do not sit anywhere
waiting to be read, and cannot. Measured 2026-08-26 from the F1
generator's own header: `makefs -t hammer2` writes an 8 GiB image and
exposes no way to shrink it -- `-s` sets a maximum and so conflicts with
the default rather than lowering it, and there is no `-o Size=`. It is
not a format floor: `HAMMER2_ZONE_BYTES64` is 2 GiB and
`FREEMAP_LEVEL1_RADIX` is 30, so a smaller image is an upstream change
and not a flag. The generator therefore builds, verifies and DELETES each
image before starting the next, and peak cost is one image rather than
the set.

So the decision below that fixtures live in this tree's `test/fixtures/`
is about the SCRIPTS, the manifests and the provenance CSV, which are
small, and never about the images, which are build output no repository
can hold. This paragraph used to say "F1 and the first F2 image exist",
which reads as though a gate from 0.4 on could be pointed at a file. It
cannot: it has to run a generator first. Nothing here has moved yet, and
every gate from 0.4 on exits 2 until it does.

### The guests this needs, and which exist

The milestones below say "a guest" without saying whether one exists,
which leaves the reader unable to tell a scheduling question from a
blocking one. Measured 2026-08-26 on this workstation, `virsh -c
qemu:///system`:

| what a milestone asks for | what exists |
|---|---|
| DragonFly, to write the F2 reference media | `dragonflybsd642`, DragonFly 6.4.2, 12 CPUs and 4 GiB, shut off |
| the three BSD ports' own systems, for reading a port against its host | `freebsd15`, `netbsd10-1`, `openbsd79` |
| Linux with the kernel of record and `CONFIG_PROVE_LOCKING`, for 0.3 and 0.4 | NOT PRESENT. Sixty domains exist and none is built for this: the debug options are a kernel build, not a distribution image |

That last row is 0.3's real dependency and it is a build rather than a
download, so it is named here rather than discovered when 0.3 starts.
QEMU, libvirt and `virt-install` are all on this machine, so nothing
about the harness is blocked on tooling.

This repository holds no instrument that drives any of them: measured by
searching `doc/`, `script/` and `test/` for `qemu`, `virsh` and
`virt-install`, which return nothing. The gates here are compile-time and
repository-time, and every runtime criterion from 0.3 on is unverifiable
today for that reason rather than for want of a guest.

## Milestones

Each milestone states what a stranger can measure to confirm it is met,
the gate that measures it, who owns the work, what it depends on, and what
happens if a risk lands. "Gate" always means a script that exits 0 on
pass, nonzero on fail, and 2 when it could not run, which is not a
verdict. "Maintainer" is the owner of this repository; "contributor" is
anyone else sending a change.

### 0.2 Whole core type-checks, ready to build

Exit criteria:

1. Every file the provenance CSV's carry column classifies as carried is
   in `src/sys/fs/hammer2/`, and every file under `src/` has a row in
   that CSV naming its origin tree, commit and license. The CSV is the
   authority on which files are carried; an earlier wording pointed at a
   list of absent files in the status document, which that document has
   never held.
2. `script/test-syntax.sh` covers every `.c` under `src/` and passes under
   both compilers with the W=1 warning set, with its two controls still
   failing.
3. `src/sys/fs/hammer2/Makefile`'s `hammer2-y` lists every object,
   verified by reading it against the directory. The build itself is 0.3.
4. Every `XXX` mark this port adds (the BSD ports' convention for a
   non-mechanical mapping) is counted apart from the marks the carried
   files arrive with, and the count is recorded in `README.status.md` so
   the next reader knows how many places are not a carry. Met
   2026-08-26: six, all in the two shim files, none in any carried file.

Gate: `script/test-syntax.sh`, extended file by file as each lands, and
`script/test-provenance.sh` for criterion 1. That second gate was written
on 2026-08-26 and closed the hole this paragraph used to describe: the
import rule was prose, holding only as long as whoever added a file
remembered it. It reads `doc/provenance.csv`, fails on a file with no row
and on a row with no file, and re-runs `cmp` for every row claiming a
byte-for-byte carry. With no origin clone on the machine it verified
nothing that this tree could not verify about itself, and reports
COULD-NOT-RUN rather than passing on a table that only agrees with
itself.

Work items:

| item | owner | done when |
|---|---|---|
| ~~a check that every file under `src/sys/fs/hammer2/` has a provenance row, with a control that an unlisted file fails it~~ | done 2026-08-26 | `script/test-provenance.sh`, covering `src/` rather than that one directory; `--selftest` drives all four findings, and the unlisted-file control is one of them |
| import the estimate's six carried files, then `inode`, `subr`, `ondisk` as the CSV classifies them | contributor | each type-checks under both compilers; five of the six are in, `hammer2_flush.c` remains and needs the flush decision above |
| import the check algorithms, using the kernel's own xxHash, LZ4 and zlib as the vendored-library audit found them stock | contributor | the syntax gate covers them; xxHash is in as `hammer2_xxhash.h`, LZ4 and zlib wait on a compression path to call them |
| ~~count the `XXX` marks and record it~~ | done 2026-08-26 | `README.status.md`, `XXX` marks: six added by this port, counted apart from the marks the carried files arrive with |

Owners: contributors for every item; the maintainer for merging.

Depends on: nothing. This is desk work against the FreeBSD port's tree,
the shape `hammer2.h` already follows.

Risks and contingency:

| risk | contingency | blocks 0.2? |
|---|---|---|
| a carried file will not type-check without a core edit | the edit is made in the shim if the shim can express it, otherwise in place with an `XXX`, and the count in criterion 4 is what makes that visible rather than silent | no |
| the recursion the inode and chain locks need (`README.porting.md`, Locks) turns out to be reached in more than NetBSD's two call sites | landed 2026-08-26 without a core edit: the one recursing site was closed rather than accommodated, and `README.porting.md`, Locks, has the reading | no |

Last reviewed: 2026-08-26. Criteria 1 and 4 rewritten that day; see the
revisions section.

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
| the kernel floor of 6.15 is wrong in the exercised direction (a symbol used here changed after the kernel of record) | the syntax gate pins the kernel of record as `KERNEL_REF` and declines against any other, so the bump is made there and the gate re-run before the floor is quoted again | no |

Last reviewed: 2026-08-25.

### 0.4 Read-only mount of DragonFly-written media

This is the first milestone that proves anything about the format, and
the reason the port exists. It is H1's exit.

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
exits 2 without a guest. Working name `test-hammer2-linux-ro.sh`; this
file points at it once it exists.

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
criterion 2 by the conformance suite of whatever storage model consumes
the adapter, which belongs with that consumer rather than in this tree.

Owners: contributors for the ioctls; the adapter's contract is settled
with its consumer.

Depends on: 0.6, and on a storage model existing to write the adapter
against. This milestone does not start before one does, because an
adapter written against no model is a second model. A contributor who
wants HAMMER2 snapshots and no adapter gets criterion 1 and stops
there.

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
   version, a `../CHANGELOG.md` entry, and the gates runnable from the tarball.

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
| iomap versus classic address-space operations for file data | 0.5's first commit would otherwise settle it by default; the lean was iomap, which is what a mainline reviewer would ask for, unless the 64 KiB physical buffers argue otherwise | recommended iomap, 2026-08-25, from source: xfs is the one mainline filesystem above page size and it is iomap, on the same folio-order mechanism the DIO layer uses; its entry points are `EXPORT_SYMBOL_GPL`, so the module's `MODULE_LICENSE` string must be "Dual BSD/GPL" (0.2). CONFIRMED by James, 2026-08-25: iomap. The license half was verified the same day against the target kernel family's own source rather than from training. `include/linux/license.h` enumerates the GPL-compatible tags and plain "BSD" is not among them, so it would block every `EXPORT_SYMBOL_GPL` symbol iomap needs and taint the module; `module.h` states that the tag "does neither replace the proper license identifiers in the corresponding source file nor amends them in any way". "Dual BSD/GPL" is therefore required by the kernel and changes nothing about the BSD grant. His condition, recorded: BSD is the license, the dual tag exists only because the kernel demands it, and it must never hinder what can be done with the code or its distribution |
| A workqueue-backed XOP pool against synchronous XOPs | 0.9 criterion 3 | synchronous for 0.2 to 0.6, the FreeBSD port's choice; the pool is decided on F6's numbers |
| Where the fixtures, their generator scripts and the provenance CSV live | every gate from 0.4 on, and 0.2's provenance check, name a path to them | CONFIRMED by James, 2026-08-25: this tree, `test/fixtures/`, so the port carries its own evidence when it changes hands. The generators take their toolchain from the environment. Scoped by the 8 GiB measurement of 2026-08-26 to the scripts, manifests and provenance CSV; the images are build output and never move. Not moved yet |
| The two upstream filings | 1.0 criterion 3 | drafted, unfiled |
| In-tree submission | nothing before 1.0 | deferred past qualification |

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

Dated, so a reader knows what changed in the roadmap and not only in the
driver. A revision is a change to structure, criteria, decisions or
non-goals; point releases go in `../CHANGELOG.md` instead.

- 2026-08-25: written as a table of steps and checks (`8c84941`).
- 2026-08-25: row 3a, the folio capability check at mount (`0c80e3e`).
- 2026-08-25: rewritten in this shape: versions mapped to stages, history,
  fixtures, per-milestone criteria with gates, work items, owners,
  dependencies and risks, the decisions table, the non-goals, and this
  section. Then hostile audit rounds against the sources named above
  until one found nothing, all findings applied.
- 2026-08-25: the iomap and fixture-home rows of the decisions table are
  confirmed by James. File data goes through iomap, and the fixture
  scripts move to this tree's `test/fixtures/`, not yet done. The
  `MODULE_LICENSE` question the iomap row raised was settled by reading
  the target kernel family's own headers rather than from training; the
  reading is in the decisions table above.
- 2026-08-26: two sections added, on what "the fixtures exist" means and
  on which guests this needs, both because a milestone that says "a
  guest" without saying whether one exists leaves a reader unable to tell
  a scheduling question from a blocking one.
- 2026-08-26: 0.2's criteria 1 and 4 rewritten to name authorities that
  exist. Criterion 1 pointed at a list of absent files the status
  document has never held, and criterion 4 asked for a count over the
  carried files, where the measured answer is zero and the number a
  reader wants is the count this port adds.

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
