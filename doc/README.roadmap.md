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

0.5 to 0.9 are met, 0.9 on the fifteenth run of the real closure,
nothing refused and lockdep on from the first mount to the unload,
with the driver at 0.9.7 in `CHANGELOG.md`. The shipped module mounts
DragonFly-written media read-write: every write operation is carried
and read back by DragonFly, the crash matrix recovered every cell on
both ports, and the read-write refusal that stood since 0.3 is lifted
on that evidence. HAMMER2's ioctls answer as Linux ioctls, a snapshot
taken here mounts on DragonFly, files on a volume map and execute, and
a kernel has booted with a HAMMER2 root. The half of 0.8 that belongs
to this side is measured: PFS roots made here mount by label on both
sides and DragonFly checks what was written in each, a snapshot taken
here is written into and read apart from its root there, and the same
run holds on a filesystem across two volumes. `README.capabilities.md`
declares what the port provides, each row on a run, and the port depends
on no distribution's model for it. `README.status.md`
is the record of what was measured and how; this section says only
where the work stands.

The newest surface is the full volume. A volume filled to its last
block found six defects the write path on a volume with room never
reached, all fixed: a stranded chain lock that made the following
`sync(2)` trip a circular lock dependency, a chain outliving its PFS
that faulted the unmount, a chain freed with its lock held, a fill
lost nearly whole to a flush with no room because the free-space
reserve every other tree keeps was declared here and never carried, a
mapped write accepted where `write(2)` was refused, and a file mapping
that refused every dirty folio to compaction. The reproducer is a gate
now, `script/test-enospc.sh`, thirteenth of thirteen, and it found the
last of those on its first run under that name by counting a class of
kernel warning its readings had not named.

Since then the readings 0.9 asks for have started, on the 4 GiB debug
guest with the module unchanged between them. A million one-line files
went in and were counted on both sides, after a lock inversion against
reclaim and an unbounded dirty set were fixed and a folio refusal near
seven hundred thousand was attributed to the guest's kmemleak rather
than the IO model. A 512 MiB file read back at btrfs's rate and
DragonFly's own once the device mapping was asked for read-ahead, and
its blocks lie contiguous on the media. F6 has its harness and its
first real closure, 1978 store paths and 205871 files, which found
eight defects the million one-line files could not reach, all
fixed; the copy now completes and reads
back beside squashfs and erofs, clean at 4 GiB with lockdep on to
the unload and nothing refused at 2 GiB. 0.7 and 0.8 closed on the
port's own criteria once the milestones stopped naming a consumer's
adapter and installer as theirs.

The first compile of a module against a kernel tree is the maintainer's
authorization, not a contributor's. `src/sys/fs/hammer2/Makefile`
invokes the kernel's build system, so running `make` is that act.

### Next moves

1. 0.9's low-memory row: the order-4 folio refusal is attributed with
   its controls, and `IO_MODEL.md` sizes what removing it takes, a
   block assembled from every folio the cache holds before its write.
   That is the one design change left on this side before 1.0.
2. The syncer is carried: DragonFly's thirty-second period and its
   dirty-count trigger, added when the million-file tree showed the
   dirty set growing without bound between `sync` calls. The first
   real closure through the write path is in `README.status.md`.
3. The fuzzer on each build that moves the mount or write path; its
   last run is on the build with the device read-ahead, 100 images
   with no report, beside the other three fleet instruments.
4. The iomap decision stands: classic address space operations with
   block-sized folios, recorded under open decisions below with the
   reason.

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

**Current version: 0.9.x.** 0.3 was met in full when its third criterion
closed, 0.4 when its sixth did, 0.5 when the interrupted flush recovered
on both sides at 0.4.19, and 0.6 when the crash matrix ran, so the point
releases move with them by the rule `CHANGELOG.md` states; the rows
before each stay where they were, being records, and 0.5 has no rows of
its own because its last criterion and 0.6's gate closed a session
apart. The rows in the table below say what is done inside each
milestone; the numbered criteria under each heading are the contract,
and a milestone is met when all of them are.

| version | stage | milestone | state |
|---|---|---|---|
| 0.1 | H1, first slice | Shim and DIO layer type-check | met |
| 0.2 | H1 | Whole core type-checks, ready to build | met |
| 0.3 | H1 | Module builds, loads and unloads | met. Builds, loads, registers and unloads at 7.2.3, at a 7.3 merge-window snapshot and at mainline 7.3.0-rc1; kmemleak reports no unreferenced object across a mount, unmount and unload; the mount path asks the page cache for a 64 KiB folio and refuses by name, with `HAMMER2_FOLIO_CONTROL` driving the refusal; and lockdep, every lock carrying a class and a nesting level since 0.4.3, stays enabled across mount, a 28210-path walk, two thousand reads and unmount |
| 0.4 | H1 | Read-only mount of DragonFly-written media | met. Criterion 1: hash, size, block count, symlink target, mode, link count, owner, group, inode number and statfs compared against what DragonFly reported, hard-link identity included. Criterion 2: the installed DragonFly root read cold, 28209 rows identical between this reader and Kusumi's FreeBSD port. Criterion 3: PFS roots mountable by label, `f7` carrying two. Criterion 4: a corrupted data block refused on read with `EIO` and a corrupted volume header refused at mount, each with `fsck_hammer2`'s verdict recorded first. Criterion 5: clean unmount with kmemleak empty, lockdep enabled throughout since 0.4.3. Criterion 6: `f1`'s tree written by the kernel as `f12`, the two volumes identical down to compression, check method and blockref topology, differing only in two inode numbers where allocation order shows. The read rate was not a criterion and was first measured under 0.9 on 2026-09-06, when the device mapping was found to read nothing ahead; `README.status.md` has the table |
| 0.5 | H2 | Write path, verified on DragonFly | met. Every operation in the list is carried and read back by DragonFly; F4 ran both ways on a volume formatted here; the flush order is taken from the block tracepoints with the header last; 200 mutated images through the mount path with no report; the interrupted flush recovered on both sides, and the freemap replay driven on a header made to lag. The allocation order of a large file was not a criterion and was first read under 0.9 on 2026-09-06 from the image beside DragonFly's own file: contiguous at 8185 of 8191 steps where DragonFly's is scattered, so the writeback order needed nothing |
| 0.6 | H3 | Crash recovery | met. Kill, panic, power and torn header, twice each, on media the FreeBSD port wrote and on media this port wrote: every image mounted and recovered on both ports, every file readable, `fsck_hammer2` clean after each recovery, and each cell's runs in agreement |
| 0.7 | H4 | Snapshots and checkpoints | met at 0.7.49, on 2026-09-06. The ioctl surface is delivered and gated: snapshot create, PFS create, delete, list and lookup, the inode and volume queries, growfs and bulkfree. A snapshot taken here mounts by label on both sides, read-write; a write into it leaves its root unchanged and DragonFly reads the two apart. `README.capabilities.md` declares what the port provides, every row on a recorded run. The milestone was gated on one consumer's adapter until 2026-09-06; the port is independent of any distribution, so that adapter is the consumer's milestone |
| 0.8 | H5 | PFS as storage domains | met at 0.7.50, on 2026-09-06. `script/pfs-domains.sh` creates SYSTEM, STORE and CACHE through the port's own ioctl, mounts each by label here and on DragonFly, and DragonFly checks what was written in each, 21 files per root with 0 mismatches on three runs, a snapshot of one root written into and read apart, and all of it again on a filesystem across two volumes. Which labels a consumer lays down and its installer are the consumer's |
| 0.9 | H6 | Nix-scale hardening | met at 0.9.5, on 2026-09-07. The million-file row has its instrument and its first numbers: a hundred thousand files clean on both sides, and at a million two defects found and fixed, the unbounded dirty set and the reclaim inversion, and one limit measured and attributed: roughly seven hundred thousand one-line files on the 4 GiB debug guest before the write path's order-4 folio grab fails, and a million with no refusal on the same guest with kmemleak off, so the limit is the debug guest's and not the IO model's; and the large-file row: sequential read held to 353 MiB/s by a device mapping with no read-ahead, now 602 to 683 with the kernel's read-ahead asked for the BSD cluster hint, at btrfs's rate and DragonFly's own on the same guest, with the Linux-written file contiguous on the media where DragonFly's is scattered; `README.status.md` has both tables. F6's harness has run a real closure, a KDE desktop of 1978 store paths and 205871 files, and found eight defects in seventeen runs, the fifteenth and eighteenth clean: a lost XOP wakeup, lockdep's eight subclasses against a store path nine deep, a symlink failure returned as a positive number, unmovable symlink folios, a lookup deadlocked against kswapd's eviction, a buffer freed by the cache cleanup under the writeback worker still holding it, and a flush scan resumed on a sibling freed while the callback had the spinlock released, and a directory's entry in the directory's own lockdep class after a remount, an annotation and not a lock; all eight fixed, the depth by a lockdep class per level registered as the tree is walked and the scan by DragonFly's own bookkeeping carried over the vendored tree. The fifteenth run at 4 GiB, lockdep on from the first mount to the unload, put the copy in at 97 s with nothing refused and read it back hashed at 96 s against squashfs's 71 and erofs's 39, every hash and symlink at the source's and DragonFly's checker clean after the collection; the low-memory row is measured at 2 GiB with both page-cache fallbacks in, 1727 blocks assembled and 144 buffered, nothing refused and nothing lost, with the controls that attribute the refusals in `IO_MODEL.md`. The XOP pool stays synchronous: the same copy into ext4 on the same guest took 79 s to the port's 85. Four writers put the same closure in at 64 and 80 s on two runs, ahead of ext4's single writer beside them, and the collection row is measured: 989 of 1978 store paths removed beside a reader, DragonFly counting what stayed. Every row has its number |
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
| F4 | a tree written by this port, mounted and verified on DragonFly, then the reverse | this port and DragonFly | 0.5 | `script/f4-roundtrip.sh`, run both ways on a volume formatted here |
| F5 | images captured mid-write under the crash matrix, calibrated first against the FreeBSD port | a crash harness in QEMU | 0.6 | `script/crash-matrix.sh` makes them per run; sixteen recorded in `README.status.md`, none kept |
| F6 | a real Nix closure copied in through the write path | `script/nix-closure.sh` | 0.9 | run; clean at 4 GiB with lockdep on to the unload, `README.status.md` has the readings |

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

Nothing remains. `hammer2_inode.c` is carried, the CSV's carry column
says so, and the check and compression algorithms use the kernel's own
xxHash, LZ4 and zlib, called from the read path.

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

Gate: `script/test-fixtures.sh`, which builds the module, starts the guest
and loads it before mounting anything, and exits 2 without a guest. The
folio control is a build flag driven by hand, recorded in
`README.status.md`.

Work: the first `make` (maintainer); the build-and-load gate, written by a
contributor and run by the maintainer, printing each of criterion 2's
observations; the mount-time capability check and its control.

Depends on 0.2 and on a guest with the kernel of record and the debug options.

Risks: the module links but the load oopses in init, which blocks until fixed.
The init path is the shim's, not the core's, so the fault is in fewer
than a thousand lines and the guest console is the instrument. Separately, if
the floor is wrong in the exercised direction, the bump is made at
`KERNEL_REF` in the syntax gate and the `#error` together and the gate
re-run before the floor is quoted again.

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

Gate: `script/test-fixtures.sh`, which builds the module, starts the guest,
attaches every image whose manifest is committed one at a time, mounts
it, compares files, checksums, block counts, ownership and `statfs`
against the manifest, expects the corrupt fixtures to be refused, asserts
that lockdep is still enabled afterwards, and exits 2 without a guest. It
took the tree's own naming rather than the working name
`test-hammer2-linux-ro.sh` recorded here, that name having been chosen
while the gate was expected to live in Saxum.

Met at 0.4.1 by its criteria, on 2026-09-04, with the closing measurement
for each in `README.status.md`: F1 and F2 on every fixture, the DragonFly
guest's installed root walked at 28210 paths, DragonFly's own `stat` and
`statfs` beside the module's, three other readers of the same media
agreeing, and F3 refusing what it should. The one risk this section named
that came true was the second: the inode and dentry lifecycle did not fit
the core's refcounting as first written, and the use after free it caused
is the second defect the status file records finding at the first mount.

### 0.5 Write path, verified on DragonFly

Create, write, truncate, `mkdir`, `unlink`, `rename`, `setattr`,
`fsync` and `sync`, then clean unmount, on a volume this port created. Xattrs
were in this list until 2026-09-05 and are not a HAMMER2 feature: DragonFly's
own driver has no extended attribute operations, and neither BSD port adds
any, NetBSD's `vfs_extattrctl` being the stub every filesystem there
carries; a port cannot verify against DragonFly what DragonFly does not
store. F4 is
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

Gate: `script/crash-matrix.sh`, which runs the four cells twice each, the
FreeBSD port writing first, and reports a cell green only when its runs
agree. It ran 2026-09-05 over sixteen rows with both recoveries clean on
every one; `doc/README.status.md` carries the table, and the torn cell's
verdict from `fsck_hammer2`, which reports a torn header rather than
skipping it as the mounts do, is recorded there as the expected verdict.

### 0.7 Snapshots and checkpoints

The ioctl surface is redesigned as Linux ioctls, so `hammer2-utils`
drives a mounted volume: snapshot creation, PFS creation, listing,
lookup and deletion, the inode and volume queries, growfs and the
bulkfree scan. A snapshot this port takes is a PFS of its own: it
mounts by label on both sides, read-write, a write into it leaves the
root it was taken of unchanged, and DragonFly reads the two apart.
`README.capabilities.md` declares what the port provides, each row at
one of six levels and each level read off a recorded run. Gated by
the exerciser in the read-only gate for the ioctls and by
`script/pfs-domains.sh` for the snapshot.

Until 2026-09-06 this milestone was also gated on an adapter and a
conformance suite belonging to one consumer's storage model. The port
is independent of any distribution: a consumer's adapter over these
ioctls is that consumer's milestone, written against the declaration,
and never a criterion of this tree. Met at 0.7.49.

### 0.8 PFS as storage domains

PFS roots are the port's storage domains: created here through its own
ioctl, each mounting by label as a filesystem of its own on both
sides, each holding what was written in it as DragonFly checks it, and
the same on a filesystem across more than one volume. Which labels a
consumer lays down, and the installer that lays them, are the
consumer's. Gated by `script/pfs-domains.sh`, in both its one-volume
and two-volume forms. Met at 0.7.50.

### 0.9 Nix-scale hardening

F6, a real Nix closure of hundreds of thousands of paths, reads at a measured
cost recorded beside the same read on squashfs or erofs. Million-file trees,
parallel builds, store garbage collection, snapshots retained under churn, low
memory and near-capacity operation each pass with the number they produced; a
run without a number is not a pass. Whether the XOP pool becomes
workqueue-backed is decided here, on F6's numbers.

Row by row, with the instrument that produced the number:

| row | instrument | number |
|---|---|---|
| F6, a real closure beside squashfs and erofs | `script/nix-closure.sh` | 205871 files in at 97 s, hashed read 96 s to squashfs's 71 and erofs's 39, 4 GiB, lockdep on throughout |
| million-file trees | `script/million-tree.sh` | a million files in 248 s, counted on both sides, three of three |
| parallel builds | `script/nix-closure.sh`, `H2_NC_JOBS` | four writers in at 64 and 80 s on two runs, ahead of ext4's single writer beside them each time; the first run found the sixth defect, a buffer freed under its holder, and the second ran clean of it with the fix in |
| store garbage collection | `script/nix-closure.sh`, the collection phase | 989 of 1978 store paths removed in 13 s beside a reader walking the rest; DragonFly counted the 103693 files that stayed and its checker was clean in 44 s |
| snapshots retained under churn | `script/million-tree.sh` | a tenth deleted and rewritten under a snapshot, the snapshot at this side's count on DragonFly, three of three |
| low memory | `script/nix-closure.sh` at 2, 4 and 8 GiB | a 12 GB stream refused three to seven writes at 4 GiB until the write path took folios smaller than the block, then none, with 1427 blocks assembled; three device-block reads then failed for want of a folio until the DIO layer took a buffer of its own, 179 of them on the next run with every file and the collection's survivors hashed as their source; at 2 GiB, 1727 assembled blocks and 144 buffers, nothing refused, nothing lost, exit 0 |
| near-capacity operation | `script/test-enospc.sh` | ten clean fills as root and as a user, a gate since 0.7.10 |
| the XOP pool | `script/nix-closure.sh`, the ext4 reference | synchronous stays, 85 s to ext4's 79 |

Two services DragonFly's buffer cache gives HAMMER2 for free,
`cluster_readx()`'s read-ahead and `cluster_write()`'s ordered
write-behind, which the core's comment says its allocation depends on,
were measured with `script/throughput.sh` rather than assumed. The
write order needed nothing: the Linux-written file is contiguous at
8185 of 8191 steps where DragonFly's own on the same volume is
scattered. The read rate did: the DIO layer read the device one folio
at a time with nothing ahead of it, 353 MiB/s, and asking the kernel's
read-ahead on the device mapping for the BSD cluster hint took it to
602 to 683, btrfs's rate and DragonFly's on the same guest.
`README.status.md` has the table.

The rows that need no closure are measured: a million files written
by four writers in 248 s, a tenth of them deleted and rewritten with a
snapshot taken through it, the whole tree deleted, and every state
counted on both sides with both checkers clean. The first run of that
configuration deadlocked in the shim's shared to exclusive upgrade,
which is fixed and recorded in `README.status.md` with the run that
passed after it, three of three in that configuration, and five of
five at twenty thousand files with lockdep alive. The lock order of
the whole million-file churn was read once the guest kernel's chain
table was raised, and was clean.

F6 has run. `script/nix-closure.sh` copies the closure of a store path
the host already holds into the port and reads it cold beside squashfs
and erofs; the first closure, a KDE desktop of 1978 paths, 205871
files and 150219 symlinks, found eight defects in seventeen runs,
none of them reachable by a million one-line files, and the fifteenth
run at 4 GiB reads it back clean with lockdep on to the unload, a
hashed 96 s against squashfs's 71 and erofs's 39.
`README.status.md` has the defects and the table. The XOP pool
decision is taken: the same copy into ext4 on the same guest took
79 s to the port's 85, and the port read back faster, so the pool
stays synchronous and the workqueue-backed pool is not built.

Gate: `script/nix-closure.sh`, run on the fleet, exit 0.

### 1.0 Flagship qualification

The bar, in this tree's own terms and gated by this tree's own
instruments: correct crash recovery, the 0.6 matrix; stable metadata
behavior at Nix scale, the million-file tree and the closure; resource
accounting a consumer can predict, the full-volume gate and the bulkfree
reading; snapshot semantics that hold on both sides, the PFS domains
run; sustained performance beside ext4, squashfs and erofs on the same
guest; reproducible builds; clean provenance; and a credible upstream
maintenance plan. A distribution that names this port its flagship
applies its own conformance suite on its own side; passing one is that
distribution's criterion, never this tree's. No relaxed standard.

On top of that: every milestone from 0.4 through 0.9 claimed with its gate
green on a clean tree and no milestone carrying a qualifier; the provenance
CSV covering every file with origin, copyright and license, the carried files
keeping their upstream notices unchanged; the two findings staged for upstream
filed by the maintainer and their state recorded here; and an out-of-tree
release a distribution can package, meaning a tagged version, a
`../CHANGELOG.md` entry, and the gates runnable from the tarball. Read
on 2026-09-07 from a `git archive` of `b06fe74` with the kernel of
record's tree named: ten gates ran and passed, and three reported
could-not-run for the reasons a tarball has, the history gate wanting
a repository and the two fleet gates a guest; the prose gate had failed
there, its population being the tracked set, and reads the tree where
there is no repository since. A filing that
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
| the first compile of a module against a kernel tree | 0.3 and everything after | taken: the module has built against the kernel of record since 0.3, and the pre-push hook builds it on every push |
| booting the DragonFly guest for the rest of F2 | 0.4 criteria 3 and 6 | taken: the DragonFly guest boots for every fleet script, and both 0.4 criteria closed on it |
| iomap versus classic address-space operations for file data | 0.5's first commit would otherwise settle it by default | ruled 2026-09-05: classic address-space operations, reversing the iomap ruling of 2026-08-25. iomap exists for filesystems whose file extents map onto device ranges: given that mapping it does the folio handling, direct I/O, `SEEK_HOLE` and `FIEMAP` once, and xfs, the one mainline filesystem above page size, runs on it. Every one of those services assumes the kernel submits the bio to the device itself. HAMMER2 cannot allow that: each data block is checksummed, possibly compressed, possibly deduplicated, and read and written through the module's own DIO cache inside `hammer2_xop_strategy_write()` on one logical block, so `iomap_writepages` would either bypass that cache, splitting reads from writes across two caches, or be wrapped until nothing of it was used. The read path landed as `->read_folio` driving the strategy XOP, and the 0.5 write path landed on the same operations with the file mapping's folio order set to `HAMMER2_PBUFRADIX`, so every folio is a whole logical block, the BSD buffer-cache strategy model the core was written against and the mechanism the DIO layer already uses. `MODULE_LICENSE` stays `Dual BSD/GPL`: the tag exists because the kernel demands it for symbols the port may yet need, BSD is the license, and it must never hinder what can be done with the code or its distribution |
| a second kernel tier below the kernel of record | testers on longterm distribution kernels cannot try the module | ruled 2026-09-05: the target stays 7.3, and if backward compatibility is ever provided it goes to 6.18 alone, revisited after 1.0.0. Measured that day: the hard floor is 6.15, where the block layer first holds a 64 KiB folio for a block device; 6.18 needs two compat conditionals, the `->create` signature and the inode state accessor, and the port acting as its own device holder; 6.12 is below the block layer's size limit and would need a second DIO layer. Of that range only 6.18 is maintained, to December 2028. `README.status.md` holds the 7.2 build that measured the floor from below |
| a workqueue-backed XOP pool against synchronous XOPs | 0.9 | synchronous, the FreeBSD port's choice, kept: the closure copy is 85 s against ext4's 79 on the same guest and the port reads back faster |
| where the fixture scripts and the provenance CSV live | every gate from 0.4 on | confirmed by the maintainer 2026-08-25: this tree, `test/fixtures/`, so the port carries its own evidence when it changes hands. Scripts, manifests and CSV only; images are build output. Moved: the manifests are in `test/fixtures/`, the CSV in `doc/research/`, and the fixture scripts in `script/` |
| a lock primitive of the shim's own against the `rw_semaphore` | 1.0 | closed: the chain and inode locks are DragonFly's `mtx` carried as a primitive of the shim's own, the lock word in DragonFly's layout over an owner and one wait queue, annotated for lockdep; the recursive exclusive hold, the shared re-lock and the shared to exclusive upgrade are what DragonFly does on its own word, and the read of the `rw_semaphore` count layout, its check at module load and the `PREEMPT_RT` build stop are gone with the semaphore. `README.porting.md` has the history. Judged on the reading named for it: the churn of twenty thousand files under a hundred directories with four writers, five of five with lockdep alive to the end and zero warnings, create 12 to 13 s, churn 3 to 4 s, delete 6 to 7 s, both checkers clean each time; the full-volume gate passed on it first |
| the debug guest's lockdep chain table | the lock reading of every tree run past about 300 s | taken: `CONFIG_LOCKDEP_CHAINS_BITS` raised from 16 to 20 on the guest kernel, sixteen times the chain and held-lock slots. The default table filled at 172 s of a million-file run, after which nothing lockdep would have reported was reported; the port makes many distinct chains by design, a class per chain type and key size at up to eight levels, and `hammer2_io_getblk()` releases the hash lock under a buffer lock taken beneath it, which lockdep re-validates on every fetch. The million-file churn then used 78922 chains of 1048576 with lockdep on to the end; `README.testing.md` records the guest kernel's configuration |
| the two upstream filings | 1.0 | drafted, unfiled |
| in-tree submission | nothing before 1.0 | deferred past qualification |

## Not on the roadmap

- Porting the DragonFly kernel, or any part of it beyond what the core needs
  from the shim.
- The cluster layer, before H7.
- 32-bit or HIGHMEM kernels. `hammer2_io_data()` hands the core a pointer it
  holds across sleeps, so the folio must be permanently mapped, and a
  `static_assert` refuses that build rather than corrupting quietly.
- Kernels older than the kernel of record. The floor is 7.3 and moves with
  the pin; there is no conditional compilation on the version in the tree.
- Serving `O_DIRECT`. DragonFly's HAMMER2 has no direct path either: its
  `IO_DIRECT` means semi-synchronous, set by the reserve check, and every
  read and write goes through the buffer cache because each block is
  checksummed and possibly compressed on the way. A direct open falls back
  to buffered I/O, as it does there. Revisited only if a mission-profile
  workload in 1.0 needs it.
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
