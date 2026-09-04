Roadmap
=======

The path from a tree that type-checks to a driver that can be trusted with a
root filesystem. Milestones, the exit criteria for each, and the gate that
verifies them. No dates: a milestone ships when its criteria are met and the
named gate says so on a clean tree.

What exists and what has been verified today is `README.status.md`. Design
decisions and their reasoning are `README.porting.md`, `ARCHITECTURE.md` and
`IO_MODEL.md`. Point releases are `../CHANGELOG.md`.

## Where we are

No module has been mounted, so no filesystem behavior here has been observed running. The
OS shim, the DIO layer and the whole carried core type-check against real
kernel headers under two compilers, with controls that fail when they
should, and `make` produces a warning-clean `hammer2.ko`. What exists of the
mount path and what has been verified is `README.status.md`; the vnode path has one
operation, `->lookup`.

The first compile of a module against a kernel tree is the maintainer's
authorization, not a contributor's. `src/sys/fs/hammer2/Makefile` already
invokes the kernel's build system, so running `make` is that act. Everything
in 0.2 can be prepared without it.

### Next moves

1. Done on 2026-08-26. `hammer2_cluster.c` went in unedited,
   `hammer2_subr.c` with seven `XXX` marks, `hammer2_ondisk.c` with its
   device half rewritten on `bdev_file_open_by_path()`, and
   `hammer2_inode.c` carried apart from `hammer2_igetv()` and the create
   path. This list said `hammer2_inode.c` was deliberately not next,
   because the VFS entry shapes its inode lifecycle. That reason still
   holds and is why those two functions are `DEFER`red; what changed the
   order is a dependency measurement, that `hammer2_pfsalloc()` in the
   VFS entry calls four `hammer2_inode_*` functions, so reading the file
   first is what lets the entry be written against something real.
   Nothing else can be imported: the four files left are rewrites.
2. In progress. The read-side VFS entry (`fs_context`,
   `super_operations`, `lookup`, `getattr`, `iterate_shared`,
   `read_folio`, `statfs`) against the F1 manifests. This is also what
   resolves the inode and dentry lifecycle question. It is listed second
   because it is the first thing here that cannot be written by reading
   the BSD ports side by side, and the three files above are the ones it
   calls.

    Those seven entry points span three files, so no single file finishes
    this row: `hammer2_vfsops.c` owns `fs_context`, `super_operations` and
    `statfs`, `hammer2_vnops.c` owns `lookup`, `getattr` and
    `iterate_shared`, and `read_folio` lands with `hammer2_strategy.c`.
    `lookup` and `iterate_shared` are written, so what is left of this row
    is `statfs`, `read_folio` and the DIO read path beneath it.
    The PFS half of `hammer2_vfsops.c` and the mount path are written:
    `->get_tree` performs device and volume probing, reads the super-root,
    looks up the PFS label under `spmp->iroot`, allocates the `pmp`, and
    runs the Linux fill-super (`super_setup_bdi`, `sb->s_op` pointing to
    `hammer2_sops` with `->evict_inode`, `hammer2_igetv` on `pmp->iroot`,
    and `d_make_root` for `sb->s_root`). Upstream's mount-time flush recovery
    is carried and called, but it writes and has never been run, so a
    read-write mount and a read-write remount are both refused. What
    remains in `hammer2_vfsops.c` is `->statfs`, `->sync_fs`, the real
    `->reconfigure` where only the refusal stands, and lifting those two
    refusals once the recovery has been exercised on a device. The next
    files are `hammer2_vnops.c` and `hammer2_strategy.c`.
3. The module builds. The first `make` ran on 2026-09-02 against 7.1.9
   with gcc 16.2.1 and reported four undefined symbols; `hammer2_strategy.c`
   landed the same day with `hammer2_dedup_clear()` carried and both XOP
   handlers as floors, and `hammer2_vfs_sync_pmp()` became a floor too. The
   result is `hammer2.ko`, warning-clean, license `Dual BSD/GPL`, alias
   `fs-hammer2`, no module dependencies. That is 0.3's first criterion.
   Loading and unloading are the other two and need a guest, which exists:
   see the guest section below, where the version this was blocked on was a
   misreading of what loading a module requires. The
   build also found seven warnings the syntax gate did not carry the flags
   for, and gates that read kbuild's output as source.
4. Read-only mount of F1, then of the F2 root image: 0.4.

## Versioning

Versions are milestones, not calendar releases. A version is claimed when its
exit criteria are met, each verified by the named gate, and recorded in
`../CHANGELOG.md`. Until 1.0 the number says how far along this ladder the
driver is and nothing about stability.

The third number increments when a verified deliverable lands inside the
current milestone: a file imported with its gate, a gate added, a decision
taken and implemented.

Milestones carry the stage names H0 to H7 beside their version numbers. They
come from a port plan written before this repository existed and held outside
it, so they are defined here rather than cited: a name whose definition is one
directory away becomes unreachable the moment the tree is handed to someone
else, and these names are already in the source comments.

| stage | what it produces |
|---|---|
| H0 | archaeology: what the format is, what may be carried, under which license |
| H1 | a read-only driver that builds, loads and mounts DragonFly-written media |
| H2 | the write path, verified against DragonFly |
| H3 | crash recovery |
| H4 | snapshots and checkpoints |
| H5 | PFS as storage domains |
| H6 | hardening at scale |
| H7 | advanced storage: multi-device, replication, remote checkpoints |

H0 finished before the first commit here. What it produced that this tree
carries is the origin table in `README.status.md`, `provenance.csv` and the
vendored-library audit the xxHash header cites in place.

`H2` is two things in this file and in the source. As a stage it is the write
path; in a comment carried from DragonFly it is the filesystem's own
abbreviation. The stage is only ever written beside a version number.

**Current version: 0.2.x.**

| version | stage | milestone | state |
|---|---|---|---|
| 0.1 | H1, first slice | Shim and DIO layer type-check | met |
| 0.2 | H1 | Whole core type-checks, ready to build | met |
| 0.3 | H1 | Module builds, loads and unloads | builds, loads, registers and unloads at 7.2.3, at a 7.3 merge-window snapshot and at mainline 7.3.0-rc1. kmemleak reports no unreferenced object across a mount, unmount and unload. Lockdep cannot judge this port: every chain lock shares one class, so the first mount reports recursive locking and the instrument disables itself |
| 0.4 | H1 | Read-only mount of DragonFly-written media | a makefs image mounts read-only at 7.2.3 and the root inode is real; readdir and statfs are not written and a read returns EINVAL. The milestone's own claim needs media DragonFly wrote, which is the dragonflybsd642 guest and has not been done |
| 0.5 | H2 | Write path, verified on DragonFly | not started |
| 0.6 | H3 | Crash recovery | not started |
| 0.7 | H4 | Snapshots and checkpoints behind the storage model's adapter | waits on the storage model |
| 0.8 | H5 | PFS as storage domains | not started |
| 0.9 | H6 | Nix-scale hardening | not started |
| 1.0 | qualification | Flagship qualification | not started |

## Fixtures

A read test that compares one HAMMER2 reader against another proves the two
agree, not that either is right, so every fixture carries a manifest taken
from the source tree. A fixture is its writer, its version, its command line
and its manifest.

A manifest row is path, size and content hash for a file, the target for a
symlink, and a type marker for a directory. It carries no mode, owner, times,
link count or filesystem statistics. A criterion that needs one of those needs
the column first.

| set | what | written by | serves | state |
|---|---|---|---|---|
| F1 | six trees of known shape: empty, flat, deep, sizes at each block-size boundary, links, names at the length limit | `makefs -t hammer2` | 0.4 | generator run, output verified through `hammer2-fuse` against the source-tree manifest |
| F2 | the same trees from a DragonFly kernel, plus two PFS roots, a snapshot after modification, a tree after bulk-free, deleted files held by a snapshot | DragonFly 6.4.2 in a guest | 0.4, and the F1-against-F2 comparison | one image: a guest's installed root read cold, 28,171 inodes, `fsck_hammer2` clean. The rest needs the guest booted |
| F3 | F2 images with metadata deliberately damaged, with `fsck_hammer2`'s verdict on each recorded first | a script over F2 | 0.4 and 0.6 | unwritten |
| F4 | a tree written by this port, mounted and verified on DragonFly, then the reverse | this port and DragonFly | 0.5 | needs 0.5 |
| F5 | images captured mid-write under the crash matrix, calibrated first against the FreeBSD port | a crash harness in QEMU | 0.6 | needs 0.5 |
| F6 | a `makefs` image of a real Nix closure | `makefs -t hammer2` | 0.9 | needs a build host's closure |

Images are never committed, and cannot be. `makefs -t hammer2` writes 8 GiB
and exposes no way to shrink it: `-s` sets a maximum, so it conflicts with the
default rather than lowering it, and there is no `-o Size=`. This is not a
format floor, since `HAMMER2_ZONE_BYTES64` is 2 GiB and `FREEMAP_LEVEL1_RADIX`
is 30; a smaller image is an upstream change. The generator builds, verifies
and deletes each image before starting the next, so peak cost is one image.
`test/fixtures/` therefore holds the scripts, the manifests and the provenance
CSV. Every gate from 0.4 on runs a generator before it has anything to read,
and exits 2 until then.

## Guests

Every milestone from 0.3 on needs a machine this repository does not contain:

| guest | needed by | for |
|---|---|---|
| Linux in the supported range | 0.4 | every mount |
| the same, `CONFIG_DEBUG_KMEMLEAK` on | 0.3 | the allocation half of criterion 2 |
| the same, `CONFIG_PROVE_LOCKING` on | 0.3, 0.4 | the lock order this port's shim imposes on a carried core |
| DragonFly 6.4.2 | 0.4 | writing the F2 reference media |
| DragonFly or FreeBSD | 0.5, 0.6 | the F4 round trip, and calibrating the crash matrix |
| FreeBSD, NetBSD, OpenBSD | any milestone | reading a port against the host it was written for |

The Linux guest is 0.3's real dependency. Until 2026-09-03 this paragraph
said it does not exist and that 0.3 is therefore blocked. That was a claim
about the maintainer's machine that nothing in this repository rechecks, and
it was wrong: `virsh list --all` on that machine returns sixty guests,
`dragonflybsd642` among them, which is the F2 guest this paragraph correctly
said already exists, and a dozen Linux ones including CachyOS, NixOS,
Fedora, Debian and openSUSE. They are documented in a separate repository,
`virtual-workbench`, which this one had never named.

The row above was one row until 2026-09-03 and it read `CONFIG_PROVE_LOCKING`
as a condition of loading the module. It is not. Loading and unloading are
0.3's two open criteria and a stock kernel runs them; lockdep makes that test
worth more, and its absence makes the test weaker rather than impossible.
Coupling the two is what has had 0.3 recorded as blocked while kernels in the
supported range sat on the same disk.

Criterion 2 was exercised on 2026-09-03, on the `fedora44` guest carrying two
kernels installed for the purpose. At 7.2.3-300.fc45 and again at
7.3.0-0.rc0.260819gbd5f485f3f02: `insmod` returns 0, `/proc/filesystems`
lists `hammer2`, the module's reference count reads 0, `rmmod` returns 0 and
`/sys/module/hammer2` is gone afterwards. The kernel log carries the two
taint lines an unsigned out-of-tree module always produces and nothing else.
What the criterion asks for beyond that, no leaked allocation under kmemleak
and no lockdep report, is unmeasured: neither `CONFIG_DEBUG_KMEMLEAK` nor
`CONFIG_PROVE_LOCKING` is set in any kernel measured so far, the Fedora
7.3 build included.

`PROVE_LOCKING` is genuinely absent from stock kernels, which is now measured
rather than supposed. Five configs read straight out of the guest images with
`virt-cat`, no guest booted: Fedora 44 at 7.1.6, Nobara at 7.1.3, Void at
6.18.42, Gentoo at 6.18.41 and the maintainer's own host at 7.1.9. Every one
is `# CONFIG_PROVE_LOCKING is not set`. Four other guests keep `/boot`
somewhere this sweep did not read, which is unread and not absent. So the
lockdep half needs a debug kernel package or a build, and the loading half
needs neither: Nobara at 7.1.3 and Void at 6.18.42 are both inside the range
this module compiles for.

No instrument in this repository drives a guest: nothing under `script/` or
`test/` invokes `qemu`, `virsh` or `virt-install`. This paragraph used to
offer a wider claim, that `doc/` does not mention them either, which was
already false when written, the F5 row above and the crash-matrix section
below both naming QEMU. Discussing a tool and running one are different
claims and only the second is the one that matters here. The gates are
compile-time and repository-time, which is why every runtime criterion from
0.3 on is unverifiable in this repository whatever machines exist elsewhere.

## Milestones

Each states what a stranger can measure and the gate that measures it. "Gate"
means a script that exits 0 on pass, nonzero on fail, and 2 when it could not
run, which is not a verdict. "Maintainer" is the owner of this repository;
"contributor" is anyone else sending a change.

### 0.2 Whole core type-checks, ready to build

1. Every file the provenance CSV classifies as carried is in
   `src/sys/fs/hammer2/`, and every file under `src/` has a row in that CSV
   naming its origin tree, commit and license.
2. `script/test-syntax.sh` covers every `.c` under `src/` and passes under
   both compilers with the W=1 warning set, with its two controls still
   failing.
3. `src/sys/fs/hammer2/Makefile`'s `hammer2-y` lists every object. The build
   itself is 0.3.
4. Every `XXX` mark this port adds is counted apart from the marks the carried
   files arrive with, and the count is in `README.status.md`. Met 2026-08-26:
   eleven, five of them in `hammer2_flush.c` and the rest in the two shim
   files.

Gate: `script/test-syntax.sh`, extended file by file as each lands, and
`script/test-provenance.sh` for criterion 1. The provenance gate fails on a
file with no row and on a row with no file, and re-runs `cmp` for every row
claiming a byte-for-byte carry. Without an origin clone on the machine it
reports COULD-NOT-RUN rather than passing on a table that only agrees with
itself.

Remaining work, all for contributors, the maintainer merging:

- `hammer2_inode.c`, the last non-entry file. Everything else here is in:
  `hammer2_flush.c` on 2026-08-26 with the flush decision above,
  `hammer2_cluster.c` unedited, `hammer2_subr.c` with seven `XXX` marks,
  and `hammer2_ondisk.c` half carried and half rewritten. Whether `inode`
  joins the carried set is what the CSV's carry column will say.
- the check algorithms, using the kernel's own xxHash, LZ4 and zlib, which a
  vendored-library audit found stock. xxHash is in as `hammer2_xxhash.h`; LZ4
  and zlib wait on a compression path to call them.

Depends on nothing. This is desk work against the FreeBSD port's tree, whose
shape `hammer2.h` already follows.

Risk: a carried file will not type-check without a core edit. The edit goes in
the shim if the shim can express it, otherwise in place with an `XXX`, and
criterion 4's count is what keeps that visible. It does not block the
milestone.

### 0.3 Module builds, loads and unloads

1. `make` produces `hammer2.ko` against the pinned kernel's headers with no
   warning in a file under `src/`.
2. `insmod hammer2.ko` succeeds, `/proc/filesystems` lists `hammer2`, and
   `rmmod` leaves no reference, no leaked allocation under `kmemleak`, and no
   lockdep report, in a guest with `CONFIG_PROVE_LOCKING`.
3. The mount path calls `mapping_max_folio_size_supported()`, and a kernel
   that cannot supply a 64 KiB folio is refused by name with the kernel's
   answer in the message. A control exercises the refusal. Whether the
   build-time assert stays as a second guard on `BLK_MAX_BLOCK_SIZE` is
   decided then, and the syntax gate's ceiling control moves or retires with
   it.

Gate: a build-and-load script, unwritten, that runs in a disposable guest and
exits 2 without one. Its first run is the compile authorization.

Work: the first `make` (maintainer); the build-and-load gate, written by a
contributor and run by the maintainer, printing each of criterion 2's
observations; the mount-time capability check and its control.

Depends on 0.2 and on a guest with the kernel of record and the debug options.

Risks: the module links but the load oopses in init, which blocks until fixed.
The init path is the shim's, not the core's, so the fault is in fewer
than a thousand lines and the guest console is the instrument. Separately, if
the 6.15 floor is wrong in the exercised direction, the bump is made at
`KERNEL_REF` in the syntax gate and the gate re-run before the floor is quoted
again.

### 0.4 Read-only mount of DragonFly-written media

The first milestone that proves anything about the format, and H1's exit.

1. Every F1 fixture mounts read-only, and path, size, content hash and symlink
   target match the manifest for every row. Hard-link identity, `stat` fields
   and `statfs` are checked by hand, and the claim says so, until the manifest
   carries a column for each.
2. The F2 root image mounts read-only and every manifest row matches. The 67
   paths unreadable to an unprivileged user are read as root, and the 58 files
   and 9 directories gain their hashes and contents in the manifest from that
   read.
3. PFS roots and snapshots are discoverable and mountable by label.
4. Each F3 corruption is detected and refused, or detected and reported,
   without modifying the media. The media's hash is unchanged, and the verdict
   agrees with `fsck_hammer2`'s recorded one.
5. Clean unmount leaves no dirty folio, no leaked `hammer2_io` and no lockdep
   report.
6. F1 against F2 for the same tree shapes: every difference between a
   `makefs`-written volume and a kernel-written one is listed.

Gate: a read-only fixture gate, unwritten, that builds the module, boots a
guest, mounts every F1 and F2 fixture, compares manifests, runs F3, and exits
2 without a guest. Working name `test-hammer2-linux-ro.sh`.

Work: the read-side VFS entry. `lookup` and `iterate_shared` are written and
a `makefs` tree lists correctly at every depth, which leaves F1 `empty` and
`flat` to be run against the manifests rather than to be made possible; `read_folio` and the DIO read path end to
end, until F1 `sizes` matches at every boundary; the manifest's link-count,
mode and owner columns, from the tree that holds the generator; F3, with
`fsck_hammer2`'s verdicts recorded first; the remaining F2 images, which need
the maintainer to boot the guest; the gate itself.

Depends on 0.3. Criterion 1 needs nothing but F1.

Risks. If the guest never boots, F1 carries criterion 1 and the single F2 root
carries criterion 2; criteria 3 and 6 are recorded as unrun rather than
assumed, and the milestone is claimed with that qualifier stated. If the inode
and dentry lifecycle does not fit the core's refcounting, the milestone blocks
until it is designed; this is the one unknown the H1 estimate could not size by
reading, which is why `lookup` is written against F1 before `read_folio`. A
manifest mismatch on one fixture with the others clean is what the fixtures are
for: `sizes` puts a file one byte under, on, and one byte over each block-size
boundary, so an off-by-one shows at a boundary file and its two neighbors and
nowhere else.

### 0.5 Write path, verified on DragonFly

Create, write, truncate, `mkdir`, `unlink`, `rename`, `setattr`, xattrs,
`fsync` and `sync`, then clean unmount, on a volume this port created. F4 is
the round trip in both directions, and it is the only test that separates the
format from a dialect of it: HAMMER2's default per-blockref check is XXH64, so
a subtly wrong writer reads as corruption on DragonFly rather than as a bug.
The format fuzzing corpus, seeded from F3, runs against the mount path with no
crash before any writable root is offered. The flush path must order its
writes so the root checkpoint becomes durable only after everything it
references, shown by a write trace rather than by reading the source.

Gate: the 0.4 gate extended with F4 and the corpus. Depends on 0.4, a
DragonFly or FreeBSD guest, and the iomap decision below, taken at the start
of the milestone.

The risk that decides the shape of this milestone is that the freemap
allocation path, carried from the core, assumes the BSD buffer cache's write
ordering. The DIO layer's dirty tracking is where the ordering is expressed on
Linux, and the write trace is what shows whether it holds. If the round trip
fails in one direction only, that direction names the defect: DragonFly
refusing ours is a writer bug here, ours refusing DragonFly's is a reader bug
that 0.4 missed and 0.4 reopens.

### 0.6 Crash recovery

The crash matrix, process kill through kernel panic, power-off and torn
metadata write, run during a write workload in QEMU against a disposable block
device. Every cell must leave a volume that mounts, recovers to a committed
state, and passes `fsck_hammer2` with the same verdict this port gives. F5
captures each cell from the FreeBSD port first, so that what a working port
leaves behind is measured before this one is judged against it. A cell that
cannot be made to repeat is listed with its repeat count and never reported
green; if the matrix cannot be made deterministic at all, the milestone is
claimed only over the cells that do repeat.

Gate: the crash matrix harness, unwritten. Depends on 0.5 and a FreeBSD guest
for the calibration.

### 0.7 Snapshots and checkpoints behind the storage model's adapter

The ioctl surface is redesigned as Linux ioctls, and snapshot creation,
listing and deletion work through it. A backend adapter then implements
`prepare_checkpoint`, `verify`, `make_durable`, `activate`, `rollback`,
`release` and `list_recovery_points` on HAMMER2 snapshots, and passes the
universal snapshot conformance suite of the storage model this port serves.

The ioctls are gated by an exerciser added to the read-only gate. The adapter
is gated by its consumer's conformance suite, which belongs with that
consumer, not here. This milestone does not start before a storage model exists,
because an adapter written against no model is a second model. If none exists
when 0.6 closes, the ioctls ship alone as 0.7's first point release and the
milestone stays open on the adapter.

### 0.8 PFS as storage domains

The domains the storage model names, SYSTEM, STORE, PERSISTENT, BUILD, CACHE,
RECOVERY and BOOT among them, map to PFS roots, with the mapping derived from
measurement on the workload, not assumed. An installer lays them down
through the adapter. Gated by the storage model's conformance suite over a
volume the installer wrote, and by the read-only gate mounting each PFS by
label. A domain added later is one more measurement, not a redesign.

### 0.9 Nix-scale hardening

F6, a real Nix closure of hundreds of thousands of paths, reads at a measured
cost recorded beside the same read on squashfs or erofs. Million-file trees,
parallel builds, store garbage collection, snapshots retained under churn, low
memory and near-capacity operation each pass with the number they produced; a
run without a number is not a pass. Whether the XOP pool becomes
workqueue-backed is decided here, on F6's numbers.

Gate: an F6 harness, unwritten. Depends on 0.8 and on a build host that
supplies the closure and the hours.

### 1.0 Flagship qualification

The bar the storage proposal sets, restated so this tree does not depend on
it: HAMMER2 becomes a flagship only after it passes the same universal
conformance suite as OpenZFS and Btrfs, and demonstrates correct crash
recovery, stable Nix-scale metadata behavior, predictable resource accounting,
correct checkpoint and generation semantics, sustained performance under the
mission-profile workloads, reproducible builds, clean provenance and a
credible upstream maintenance plan. No relaxed standard for being the
flagship.

On top of that: every milestone from 0.4 through 0.9 claimed with its gate
green on a clean tree and no milestone carrying a qualifier; the provenance
CSV covering every file with origin, copyright and license, the carried files
keeping their upstream notices unchanged; the two findings staged for upstream
filed by the maintainer and their state recorded here; and an out-of-tree
release a distribution can package, meaning a tagged version, a
`../CHANGELOG.md` entry, and the gates runnable from the tarball. A filing that
is refused or unanswered still meets its criterion: the finding stays applied
here with its provenance note and the refusal recorded beside it.

## Beyond 1.0

H7 is advanced storage: multi-device, replication, remote checkpoints,
clustering. Every port dropped the cluster layer (`hammer2_ccms.c`,
`hammer2_iocom.c`, `hammer2_msgops.c`, `hammer2_synchro.c`) and so does this
one. Investigate after qualification.

Mainline submission is an asset to spend once. The BSD license permits it,
which OpenZFS's CDDL does not, but a mainline submission of an immature
filesystem driver is refused and remembered. The style conversion in
`README.kernel-style.md` happens at that moment, whole tree at once, or not at
all.

The carried files exist to be replaceable by the next sync from DragonFly. A
sync cadence is decided when there is a driver to sync into.

## Open decisions

Each is the maintainer's, and each names what it blocks.

| decision | blocks | where it stands |
|---|---|---|
| the first compile of a module against a kernel tree | 0.3 and everything after | open |
| booting the DragonFly guest for the rest of F2 | 0.4 criteria 3 and 6 | open. The first F2 image was taken with the guest shut off |
| iomap versus classic address-space operations for file data | 0.5's first commit would otherwise settle it by default | confirmed by the maintainer 2026-08-25: iomap. xfs is the one mainline filesystem above page size and it is iomap, on the same folio-order mechanism the DIO layer uses. Its entry points are `EXPORT_SYMBOL_GPL`, so `MODULE_LICENSE` must read "Dual BSD/GPL"; `include/linux/license.h` does not list plain "BSD" as GPL-compatible, and `module.h` states the tag neither replaces nor amends the license identifiers in the source. The maintainer's condition: BSD is the license, the dual tag exists because the kernel demands it, and it must never hinder what can be done with the code or its distribution |
| a workqueue-backed XOP pool against synchronous XOPs | 0.9 | synchronous through 0.6, the FreeBSD port's choice; decided on F6's numbers |
| where the fixture scripts and the provenance CSV live | every gate from 0.4 on | confirmed by the maintainer 2026-08-25: this tree, `test/fixtures/`, so the port carries its own evidence when it changes hands. Scripts, manifests and CSV only; images are build output. Not moved yet |
| the two upstream filings | 1.0 | drafted, unfiled |
| in-tree submission | nothing before 1.0 | deferred past qualification |

## Not on the roadmap

- Porting the DragonFly kernel, or any part of it beyond what the core needs
  from the shim.
- The cluster layer, before H7.
- 32-bit or HIGHMEM kernels. `hammer2_io_data()` hands the core a pointer it
  holds across sleeps, so the folio must be permanently mapped, and a
  `static_assert` refuses that build rather than corrupting quietly.
- Kernels older than 6.15, by `BLK_MAX_BLOCK_SIZE`.
- Replacing `hammer2-fuse`. It is an independent Rust reader of the same
  format over libhammer2, which is what makes it useful as a second reader: a
  disagreement between the two is a finding about one of them.
- Converting the carried core to kernel style piecemeal.

## How this file was built

An upstream maintainer receiving this port will ask who decided the shape of
its roadmap and against what. The answer, once, rather than on request.

The genre is Kusumi's. The `freebsd_hammer2`, `netbsd_hammer2` and
`openbsd_hammer2` trees are the three working precedents for porting this
filesystem, and their READMEs and CHANGES files are what a maintainer taking
this one will read it beside. The shape here is theirs: what is done, what is
next, what is known broken, in the author's own sentences, with no
per-milestone template and no reviewed-on dates.

An earlier version of this file was written from a template with seven
headings per milestone, a revisions list duplicating `git log`, and a section
explaining its own epistemology. It was rejected on sight by the maintainer on
2026-08-26 and rewritten at `e1df2ed`, 632 lines to 390. The nine milestones
are not written to a uniform depth on purpose: 0.2 through 0.4 can be started
today and carry criteria, gate and risks, while 0.5 through 1.0 are a paragraph
each because detail there would be invention.

What makes it checkable is distributed rather than collected here. Six of the
nine milestones carry a `Gate:` line, and one of those names a gate that exists
today; the rest name what has to be written and what it must exit 2 without.
Every commit hash in the version table is resolved and subject-matched by
`script/test-history.sh`, every `file:line` by `script/test-citations.sh`, and
no two rows may carry the same version. The stage names are defined under
"Versioning" rather than cited, because the plan that defined them is not in
this repository and will not travel with it.

What this file deliberately does not carry: dates promised for anything,
progress bars, effort estimates in time, and any milestone marked done that a
gate cannot show is done. A milestone's state comes from running the gates,
which cost seconds.

## Changing this file

A change to a milestone's criteria is a change to what "done" means. Make it
here, in one commit, with the source that justifies it. A change to a port
decision goes in `README.porting.md` first, and this file follows. Everything
else is `../CONTRIBUTING.md`.

To pick up work: choose a milestone, read its gate, and run the gates before
writing anything. They cost seconds and tell you what is true today. Work that
reaches for a compile is the maintainer's to authorize, and a change that needs
a decision above should say so instead of assuming it.
