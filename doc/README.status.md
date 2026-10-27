Status
======

The driver mounts DragonFly-written HAMMER2 media read-write on Linux
7.3 and newer, and every operation it carries has been read back by
DragonFly itself. The tree is at 1.0.60 in `CHANGELOG.md`; the newest tag is
`v1.0.4`, which is the last release rather than the tree's version. The
release shape holds: eighteen gates invoked from a `git
archive`, fourteen run and pass, and the four that report could-not-run do
so for the reasons a tarball has: two need a guest, and two read `git`
history, which an archive does not carry. The staged filings under
`doc/upstream/` are the maintainer's to file, with their state recorded
beside each; the throughput reading is taken,
and the write path's one invariant that no check code can see is now
measured rather than argued, a count of folios changed under the core
reading 14160919 on a build with its guard removed and 0 with it. The cluster's synchronization thread is carried and keeps
a SLAVE on a second local device in step with its MASTER, measured by
`script/cluster-sync.sh`, and the quorum a two-MASTER cluster is decided
by is reached and read by `script/cluster-quorum.sh`, which builds the
`pfs_nmasters` of 2 that makes the quorum bind; members on other hosts
wait on the kernel's intake of the cluster transport, whose interface
and loopback P5 closed on the host and whose message core is P6, and a
quorum that cannot be met is unrun. P4, local synchronization hardening, is closed on the Linux
reading since 2026-10-16: a refused copy's key is retried by the next pass,
measured by a refused allocation that faulted the module before the change
and converged after it, and the pass-end flush runs on every pass, since the
root's flags cannot gate it and an idle pass's flush measures a few
hundredths of a millisecond against a five-second cadence. The thread's
replace and destroy arms, which a slave's first pass never takes, are
driven by changing the MASTER while the slave's device is away; the first
drive found the replace arm copying the slave's old length out of a
smaller master block, DragonFly's own line, fixed here and staged under
`doc/upstream/`. The crash cell's FreeBSD half is
COULD-NOT-RUN by the detector's design. P5, the cluster transport's
interface and deterministic loopback, is closed on the host since
2026-10-16: `test-transport.sh` drives `test/h2loop.c`, which sits where
DragonFly's service daemon sits and decides each frame's fate from a seed,
and reads every knob beside a control that must read zero. P6, the message
core, is closed since 2026-10-16: `kern_dmsg.c`, `hammer2_iocom.c` and
`hammer2_msgops.c` are carried whole behind `HAMMER2IOC_RECLUSTER` and the
mount's `cluster_fd=`, and `cluster-dmsg.sh` reads the five exit criteria
on the guest with `test/h2attach.c` playing the daemon, 32 checks and 0
failed on the KASAN and lockdep kernels at P6's close and 55 checks and
0 failed on both at P8 stage 1's close, which added the CRC, protocol
and span table checks, and 79 checks and 0 failed on both at stage 2b's
close (`dmsg-run-20261025-121901` on the lockdep kernel,
`dmsg-run-20261025-155025` on the KASAN kernel; the run before them
read 4 failed, three of them the readdir's, since the stage 2a client
asked for a count the server had bounded four days earlier and nothing
had run the harness since, and one the kmemleak marker the host never
counted), with kmemleak scanned clean
before the module unloads, an unmount under a held, silent daemon completing by the core's
own ten-retry shutdown in about eleven seconds against under a tenth of a
second when the daemon closes first. The remote PFS layer above the core is P7's remote reach, ruled B and designed with P8's quorum protocol at `doc/CLUSTER_PROTOCOL_DESIGN.md`, whose stage 1 is built (the kernel verifies both CRCs on a connection whose peer announced `DMSG_SPAN_PROTO_2`, lists that peer's spans, and ends a `PROTO_1` connection on a frame in the HM2 space), whose stage 2a is built (the kernel announces `PROTO_2` itself and serves the eight read descriptors of the XOP API to such a peer from `hammer2_remote.c`, each reply read on both 7.3 kernels beside `stat`, `sha256sum` and the `hammer2` utility's own reading of the volume), and whose remote element's read side, stage 2b, is built (a `PROTO_2` link is a connection device whose chains are proxies for the peer's, and the slave's `CL` lists the master's files with every digest equal to the master's own, `cluster-wire.sh` 29 checks and 0 failed on both 7.3 kernels, `wire-run-20261025-211338` on the lockdep kernel and `wire-run-20261025-214847` on the KASAN kernel, with the five controls the roadmap row lists driven beside it), and whose slave's pass over the wire is built and read since 1.0.47 (under `H2_WIRE_PASS=1` the slave's device stays writable and its pass copies the master's `CL` through the remote element onto its own media, the two images then equal entry for entry and data block for data block by `hammer2 -v show` on the host and both clean by `fsck_hammer2`, `cluster-wire.sh` 31 checks and 0 failed on both 7.3 kernels, `wire-run-20261026-015358` on the lockdep kernel and `wire-run-20261026-015707` on the KASAN kernel) while the rest of stage 2b is not; the detach from the local device's unmount is driven since 1.0.51 (under `H2_WIRE_LINKDEV=1` the slave's row and link go through a second volume, so its `ROOT` and `CL` unmount with the link up and the run reads the element detached once by the unmount on both 7.3 kernels, where a plain wire run reads the detach by the connection's end and `H2_WIRE_END=lost` the one by the span's deletion; a span its peer withdraws over a link that stays up takes that path too and no run drives it); a local element holding an older copy of a block is driven since 1.0.52 (under `H2_WIRE_STALE=1` the slave's device is opened read-only again after its pass and the master rewrites the 512 KiB file's first block, so `fiemap` on the slave reports that block `unknown_loc` and the rest at the slave's own addresses, the two images differing by that block alone and the slave reading the master's new digest, `cluster-wire.sh` 38 checks and 0 failed on both 7.3 kernels); a `scanall` feed of the wrong shape under the pass is refused, read since 1.0.53 (under `H2_WIRE_RETYPE=1` the relay turns the first directory entry fed to one of the slave's scans into a data block and signs the frame again; the slave refuses it, the scan ends `ENOTCONN`, that pass is unverified and a later one brings the slave level, `cluster-wire.sh` 34 checks and 0 failed on both 7.3 kernels; the first run faulted the sync thread on deferrals a failed root scan had left for the next pass, which the pass now drains before it ends); a link cut inside the pass is resumed after both sides dial again, read since 1.0.54 (under `H2_WIRE_CUT=disconnect` the relay ends both connections at the close of a `scanall` call of the pass; the slave detaches by the span's deletion, the pass ends unverified with its target kept, every pass in the gap finds no quorum, and the first pass after the dial verifies on that target, `cluster-wire.sh` 36 checks and 0 failed on both 7.3 kernels, its control withholding the dial and leaving the slave short of the master, 25 and 0); a power cut of either guest inside the pass is resumed after the cut guest boots and both sides dial, read since 1.0.56 (under `H2_WIRE_CUT=slave` and `=master` the host destroys the guest once the slave's pass has updated 1000 inodes of 5310; the cut image reads clean by `fsck_hammer2`, the survivor's keepalive ends the link, and the pass after the dials verifies on the slave's kept target with the images equal by fingerprint and digest, `cluster-wire.sh` 36 and 37 checks and 0 failed on both 7.3 kernels); a reply frame lost, repeated, reordered, trailing its call's close or delivered on the next call ends the link at receipt, read since 1.0.59 (under `H2_WIRE_CUT=loss`, `dup`, `reorder`, `trail` and `late` the relay faults the last feed of a `scanall` call inside the pass; the slave prints the line of the sequence check `35e3ca2` added, the pass ends unverified with its target kept unless a `trail` copy found its call gone and did nothing, and the pass after the dials verifies with the images equal, `cluster-wire.sh` 36 checks and 0 failed on both 7.3 kernels, the checks compiled out under `HAMMER2_NOCLIENTSEQ` leaving a lost feed and a feed from the previous call verified on a slave unequal to its master); the five negative controls the note names for stage 2's own mechanisms, a sixth for the snapshot command and a seventh for the order in which a reconnect reads the peer's `LNK_CONN` are run since 2026-10-26 by `cluster-wire.sh`, each reading the opposite of its plain run on both 7.3 kernels, the routing's control reading `EOPNOTSUPP` on every attempt at the refusal now in front of the snapshot body on a connection device, where the body had faulted under KASAN; the keepalive is built and read since 1.0.48 (a `LNK_PING` transaction every half of `remote_timeout_ms` on a work item of its own, a ping unanswered for the bound ending the link by the reader's own shutdown, read under `H2_WIRE_SILENCE=1` as the slave's line once with the peer silent 2047 ms against a 2000 ms bound and the next listing not connected in 10 and 34 ms with no request timed out, `cluster-wire.sh` 31 checks and 0 failed on both 7.3 kernels, `wire-run-20261026-031847` on the lockdep kernel and `wire-run-20261026-025848` on the KASAN kernel, beside the control built with `HAMMER2_NOKEEPALIVE`, 32 and 0 on both, whose listing waits out the bound, 4121 and 4102 ms, with its request ending `ETIMEDOUT`); the master-side snapshot command is built and read since 1.0.49 (`DMSG_HM2_SNAPSHOT` and `DMSG_HM2_SNAPDEL` past the descriptors, the master taking a snapshot of the pass's suffix under its mount lock at the slave's request and feeding its root, the slave registering that root as a PFS of its own by the snapshot's cluster id, so P7's `snapshot_source`, `initial_convergence` and `incremental_convergence` are read over the wire: `cluster-wire.sh` under `H2_WIRE_PASS=1` 34 checks and 0 failed on both 7.3 kernels, the snapshot taken, verified and deleted, a second set reaching the slave by a later pass with the master then passed idle, and no snapshot left on either image; the run ids are in the record's entry); P7's local half, the synchronization pass reading a snapshot of the master element and keeping a snapshot of the slave as the last known-good copy, is built and read by `cluster-sync.sh` since 1.0.40 (`doc/README.porting.md`, the snapshot section). Cache coherency is a design note rather than code:
`doc/CCMS_DESIGN.md` records that the coherency half was deleted
upstream before it was written, and that Dillon's design document puts it
under the quorum protocol, which no tree has written either. The surviving
thread lock is carried and builds as `hammer2_ccms.o`, with nothing here
calling it; `doc/CCMS_REFERENCE.md` holds the sources.

| what | state | read by |
|---|---|---|
| mount read-only by PFS label, list, read, symlinks, LZ4 and ZLIB blocks | every fixture file compares byte for byte with the tree it was made from, on `makefs` media and on media DragonFly wrote, including a DragonFly guest's installed root | `test-fixtures.sh` |
| media that fails its checks | a block whose check code does not match is refused on read; a volume header that fails its crc is not mounted | `fuzz-mount.sh` |
| mount read-write, every write operation from a byte written to a directory renamed | written here, read back and checked by DragonFly | `f4-roundtrip.sh` |
| a writer killed, a kernel panicked, the power cut, a header torn | each left a volume that both this port and the FreeBSD port recovered to the same tree | `crash-matrix.sh`, `cut-flush.sh` |
| remount from read-only to read-write | runs the same recovery the mount path runs; refused only when the device itself is write-protected | `doc/history/verification-record.md` |
| HAMMER2's ioctls | answer as Linux ioctls, so `hammer2-utils` drives the volume; a snapshot taken here mounts on DragonFly and reads back the tree as it stood | `pfs-domains.sh` |
| a file handle, as a file is looked up by number rather than by name | `name_to_handle_at(2)` and `open_by_handle_at(2)` open the object a handle names and no other: two files' handles open two different inodes, a handle with a bit flipped in its inode number is refused, one to a removed file goes stale and does not answer the file made after it, and a directory handle reopens and lists | `test-enospc.sh`, `test/hammer2-fh.c` |
| mmap and exec | files map and execute; a kernel has booted with a HAMMER2 root | `root-boot.sh` |
| a full volume | the fill is refused as the other trees refuse it, and the volume unmounts clean; the defects the fill found are in the record | `test-enospc.sh` |
| a million files, and a Nix closure of two hundred thousand | written through the write path, counted on both sides, identical on both, lockdep on throughout | `million-tree.sh`, `nix-closure.sh` |
| one large file | on the release build of the kernel of record, writes at twice the rate of ext4 and btrfs and reads at six times the rate of DragonFly's own kernel on the same volume, every block verified on its own CPU; every reading before 2026-09-07 was the debug kernel's | `throughput.sh` |
| space a remove does not free | the bulkfree scan frees it | `bulkfree.sh` |
| a device in error | `hpanic` marks the device and returns; the writer is told `EIO`, the mount goes read-only, the media stays at the last good sync | `hpanic-contain.sh` |
| where a file's data is, and what it occupies | `SEEK_DATA` and `SEEK_HOLE` answer the whences of `lseek(2)` and `->bmap` is registered, so a sparse file copies and archives as one, including a file asked about before it has been written back, which the blockref tree alone reported as all hole until the seek wrote the dirty range back first; `st_blocks` is recomputed on every stat, so a file that grew in the mount reports what it holds, on a regular file and a symlink alike; `->fiemap` answers FIEMAP from the same bmap XOP, so `filefrag -v` reads this port's layout and reports the hole as a gap | `test-enospc.sh`, `test/hammer2-fiemap.c` |
| a filesystem freeze | `fsfreeze(8)` freezes and thaws (`->freeze_fs`/`->unfreeze_fs`), canceling the port's own syncer while frozen; a write to a frozen volume blocks and is released by the thaw | `test/hammer2-fiemap.c` |
| two files holding the same data | the second copy points at the first one's media; a 4 MiB duplicate cost 2 blocks against the first copy's 64, with `tmpfs` and `btrfs` charging it full price as the control | `test-enospc.sh` |

Every row above was measured, and the measurements are in
`doc/history/verification-record.md`, section by section in the order
they were taken, with the instrument, the date and the defects each one
found. `CHANGELOG.md` is the enumeration of what landed. This file is the
one to correct rather than to argue with: if a claim here is stale, it is
a defect.

## What is in the tree

| file | lines | origin |
|---|---|---|
| `hammer2.h` | 1745 | DragonFly, in the FreeBSD port's shape, OS-facing types rewritten, DragonFly's two quorum error codes restored with their errno mapping, the synchronization thread carrying its previous snapshot cut, the set of inodes to rescan with the pass that noted each, the snapshot an unmount's hold of the mount lock kept it from deleting, the last verified snapshot's root blockset and root fields for the idle test, and whether its target snapshot stands; the `kdmsg_iocom_t` and its zone restored to `hammer2_dev` for the message core; the snapshot and delete helpers the synchronization thread calls declared beside the ioctl entry; the span table of stage 1 of the cluster protocol note, `struct hammer2_span` with `spanq` and `nspans` on `hammer2_dev`, one entry per open `PROTO_2` span from the peer; for stage 2b, `HAMMER2_ERROR_ENOTCONN` with its errno mapping both ways, a quorum with a master absent or cut off, decision C of the note; the span's cluster id, PFS name and registration marks and a spin lock over the table, since the registration work item reads it beside the reader thread; the connection device pointer on `hammer2_dev`; and `hammer2_chain_alloc()` declared as DragonFly declares it, where the FreeBSD port made it static |
| `hammer2_disk.h` | 1297 | DragonFly, carried; `struct uuid` defined locally, and the `LNK_VOLCONF` section the FreeBSD port deleted carried back for `hammer2_iocom.c`, the `copyinfo[]` array taking the 32768 bytes the port had kept as reserved |
| `hammer2_ioctl.h` | 253 | DragonFly, carried; `<linux/ioctl.h>`, `HAMMER2_MAXPATHLEN` pinned; `HAMMER2IOC_RECLUSTER` restored for the message core, and the six remote ioctls with `hammer2_ioc_remote_t` as upstream declares them, for stage 2b of the cluster protocol note |
| `hammer2_admin.c` | 1150 | FreeBSD port, carried with nineteen `XXX` lines: `hammer2_xop_collect()` skipping a key the quorum of masters does not hold or holds at differing transaction ids, as upstream's does, which the port had collapsed to `EIO` and which stopped a directory listing through a cluster at a slave's leftover entry; `hammer2_xop_start_except()` reads the elements to run once, under the cluster spin, before any runs, since a strategy XOP holds no inode lock and the write's completion asks which element is last, and it runs no element past the FIFOs the allocation made; the XOP inode dependencies are taken once per XOP rather than once per cluster element, since the retire releases them once and a second element slept on the first's for good; a FIFO that grows grows every element's, since the size is the XOP's and a sibling left at the old size was written past, and the grow moves queued entries to where the new mask reads them; the XOP inode dependency wait no longer sets the PFS-wide waiting flag and its retire wakes unconditionally, since the flag was cleared by a retire on another index and a writeback worker slept for good; strategy XOPs are exempt from that dependency at start and retire, as they are in DragonFly, so the readahead workers read one file on every CPU; the xop allocation zone is shimmed; the twelve `hammer2_thr_*` functions are DragonFly's, carried with an `XXX` at each of their three interlocked sleeps, at the thread start that can fail and at the join that waits for the task to exit, and `hammer2_xop_start_except()` is carried as the routing over the synchronous XOP rather than upstream's worker pool, with `hammer2_xop_start()` wrapping it at a notidx of -1 as upstream's does rather than carrying a second copy of the selection; and since stage 2b the element loop hands a slot whose device is a connection device to the remote storage function, `hammer2_remote_xop()` |
| `hammer2_freemap.c` | 1102 | FreeBSD port, carried; its `XXX` lines are the allocation refusal the debug build takes from `fail_alloc_after`, the print of what a refusal saw, the return after `hpanic`, the two `bmdata[]` pointers formed only inside the array's bounds, which UBSAN caught being formed one past either end, and the recovery pass testing the freemap chain for null as well as for an error before reading through it. The two allocation sites gain the same null test on `chain->data` on 2026-10-14: a freemap leaf whose I/O failed is returned with error EIO and its data still NULL, and `&chain->data->bmdata[n]` then points into NULL. The allocation path's three `hammer2_chain_modify()` calls read their error again as DragonFly's do, which the FreeBSD port dropped, and the recovery pass handles a failed leaf create and a failed modify where upstream carries "XXX handle error": a modify whose new block cannot be had returns with `chain->data` NULL, and each of the five went on to write or read through it. Counted in the table below |
| `hammer2_xops.c` | 1498 | FreeBSD port, carried byte-for-byte but five `XXX` lines, the lock level of the inode chain the detached create makes, the subclass of the entry the rename holds detached, the readdir backend's stop one short of a full FIFO with the key the next XOP resumes from, since the backend runs in the frontend's thread and a scan to the end made every getdents(2) walk the whole directory, and the inode sync keeping a PFS root element's own type, sub-type and ids, since the carried assignment of the focus's meta wrote the master's identity over a slave's root (read off the kept slave images of 2026-10-15, 10-16 and 10-18) |
| `hammer2_ioctl.c` | 1637 | FreeBSD port, carried with forty-three `XXX`, the snapshot and delete bodies callable by the synchronization thread, the thread's snapshot carrying the source root's own fields where upstream's carries a new PFS's defaults, a PFS found by name on a device for the delete and for the thread's check that a target snapshot stands (the snapshot's create walks the hash collision space to an unused key and would make a second PFS of the name), the snapshot's refusal of an unmounted PFS kept for the ioctl's `hammer2_sync()` and lifted for the thread's PFS flush, which needs no mount, the first snapshotting a named element where upstream hard-wires element 0 and the second freeing a PFS left with no element and running under a caller that already holds the mount lock, the unmount deleting a thread's snapshot, `hammer2_ioctl_recluster()` restored from DragonFly without the `VFS_ROOT()` pin an open file of the super block already supplies: `pfs-create` takes the five types a cluster element can be, where the three BSD ports refuse all but MASTER for want of a sync thread and DragonFly tests nothing, and refuses a subtype past AUTOSNAP; the seek ioctls and GEOM dropped, the read-only test and the copy-out on Linux primitives, growfs clearing headers through the DIO layer, the mount-wide sync through the kernel's, an unrecognized command answered ENOTTY rather than EOPNOTSUPP, the snapshot's lock order corrected under lockdep, and the four string copies in the volume lists that read `sizeof` the destination from a source `kstrdup()` sized to its length, which KASAN caught reading 64 bytes of a 9-byte allocation; the six remote ioctls carried from DragonFly for stage 2b of the cluster protocol note, `REMOTE_SCAN`, `_ADD` and `_DEL` the `copyinfo[]` bookkeeping through `hammer2_volconf_update()` with a row's strings terminated and its type and flags checked before the volume header takes it, `REMOTE_REP` and `SOCKET_SET` upstream's returns of nothing and `SOCKET_GET` upstream's `EOPNOTSUPP`, each acting on the first slot whose device is a block device, as `RECLUSTER` now does in place of the focus's device, since with a remote master registered the focus is a proxy on a connection device; and a snapshot on a connection device that is not the synchronization pass's, routed to the master, refused with `EOPNOTSUPP` before a body that takes locks such a device never initialized |
| `hammer2_bulkfree.c` | 1246 | FreeBSD port, carried, with one `XXX` of this port's: the bigmask scan's last shift of each element, by the element's own width, is skipped, since its value is never read and UBSAN reports the shift (exponent 64 for a 64-bit type) on the first bulkfree scan the synchronization harness runs; DragonFly and FreeBSD carry the same line. `printf` and `tsleep` shimmed |
| `hammer2_chain.c` | 5670 | FreeBSD port, carried byte-for-byte but the `XXX` lines below, the debug build's list of every chain and the print of what is left at the unload, the lockdep class set where a chain lock is initialized, the nesting level handed to the shim where a chain is first placed under its parent or created under one, the level below for the children an indirect block takes over, the new block's own first lock recording no order, the caller's chain left alone when an indirect block cannot be created, the reptrack spin released before the chain is dropped where the port took it and never let it go, the emptied block's core taken after its parent's in `hammer2_chain_repchange()` told to lockdep as a subclass, since every other holder of two cores takes the child's first and nothing can stand beneath an emptied block, the last drop of a chain naming the caller that still holds its lock and, in its spin, a lock stranded by a task that let go, a new chain's data resolved after its insert rather than before so a lost insert race costs no read, and the way out after each of its `hpanic` sites, and a print of the chain an `RB_INSERT` collided with, which the carried assert computes and discards, and the bound the cluster's convergence needed, which is `ncount` against the parent's span at the allocation: capping the radix after the helpers returned was tried and reverted on 2026-10-13, since a narrower block under a parent whose keyspace it must cover gains a level per create, and with `ncount` left at 128 a 32-key parent is asked for a 128-slot child whose keyspace is its own, so the split frees nothing and the pass repeats it 4188 times per key; bounding `ncount` below `2^(parent keybits - 1)` lands the block one radix level under its parent, which converged the slave to its master entry for entry and block for block at 18 checks 0 failed; the recursive lock is NetBSD's non-recursive answer, `pause` and `__diagused` shimmed; `hammer2_chain_alloc()` is public again as DragonFly has it, and a chain allocated on a connection device takes a reference on the device that its free drops, the two `XXX` lines of stage 2b of the cluster protocol note |
| `hammer2_flush.c` | 1380 | FreeBSD port, carried; the device flush and the volume header write are the port decision below, marked `XXX` in place, the header write reads the device-in-error bit, and the three `hpanic` sites record their error |
| `hammer2_cluster.c` | 510 | FreeBSD port, with `hammer2_cluster_check()` restored from DragonFly's, its three-way early return (`EINPROGRESS`, `ESRCH`, `EDEADLK`) included since 2026-10-18: the port carried the first pass and the tail of the third and dropped the quorum between them, and its dropped tail asserted every slot past the first was NULL, which is what made `nchains > 1` impossible. The three passes, the quorum from the PFS's master count and the fourth validation pass are now upstream's, with the error returns in the port's own positive-bit convention. Nothing in it touches the OS; its `XXX` lines are a quorum still waiting on a master returned as upstream's `EINPROGRESS` rather than the `EAGAIN` the sync thread reads as a request to go round again, the two codes upstream splits, and, for stage 2b of the cluster protocol note, a master whose element ended timed out or with its link closed counted as unreachable rather than agreeing on the end of a scan, and `ENOTCONN` returned when a master the PFS counts is unreachable or absent, decision C of the note |
| `hammer2_synchro.c` | 2791 | DragonFly, carried, with one hundred and twenty-eight `XXX` lines, the snapshot pass among them (the source read through the carried XOPs over an inode of the snapshot PFS with no element excluded, since the slave is no element of that inode and excluding its index would exclude the snapshot itself when the slave is element 0, the slave found by inode number with its chain pinned across the deferral, a source that cannot be read making the pass one that cannot verify, the pass body shared with the live pass, the pass that takes and deletes the snapshot, and two guards the live pass has no need of: a slave key absent from the snapshot is destroyed only if it predates the previous pass's snapshot cut, and a slave chain newer than the snapshot's is kept, since writers are not interlocked against the snapshot's flush here, as is a whole inode whose slave chain is newer than the snapshot's, which a scan would otherwise pull back toward a snapshot the frontend has since passed; a kept key puts its inode on the rescan set and withholds no stamp, where a refused copy withholds every stamp of the rest of the pass), its idle test (the master root's flushed blockset and the root fields the PFSROOT arm copies, against the last verified snapshot's, so a quiet master costs no snapshot, with the live pass run once as the idle stamp while the two root tids still differ), its verify rounds (the pass run again against the same snapshot with the root on the rescan set, up to three, verified when a round acts on nothing and fails nothing, and ended early when a round kept a key the frontend wrote after the snapshot, which the next snapshot settles) and its target snapshot (the slave before the first pass after a verified one, on its own device, deleted when a pass verifies and kept across a failed or interrupted pass, a crash and an unmount), the thread's rescan set (the inodes whose last scan kept or failed a key, scanned by the next pass whether or not their tids agree and never by the pass that noted them, which holds the snapshot the key was kept against, since the flush raises a parent's tid to the newest child it writes back and a block replaced beside one kept left the slave's inode at the master's tid with the kept block still under it) and the unmount's deletion of a snapshot the last pass's try-lock could not: its two interlocked sleeps on `tsleep_word()`, the deferral allocations on `hmalloc()`, the FreeBSD port's `hammer2_chain_next()` without `key_beg`, four prints whose `%jx` printk does not implement, and five counters over the action switch's `nerror`, added 2026-10-14 to separate the two ways into the `n < 0` arm; that `nerror`, which upstream discards, is read since 2026-10-16 into one bit on the pass's deferral list that withholds every inode root's `modify_tid` stamp for the rest of the pass and ends the pass after one deferral drain, since a rescan of unstamped directories defers them forever (measured, 4492 rescans), so a key whose copy failed is reached again by the next pass, with two per-arm counters on the `filekeys` line for the replace and destroy arms a first pass never takes; `hammer2_sync_replace()` resizes a changed block to the master's size rather than the slave's own, upstream's line having read the slave's old length out of a shorter master block (KASAN, staged under `doc/upstream/`); and two of the three action helpers are corrected to return the failure (the insert read a fresh chain's `error` over a failed modify, the destroy discarded the delete's); the `destroy rec` print fires on `0x4000` as well as the carried `0x0001`; and the sync thread's direct chain copies require a pass-end flush because they have no inode on the VFS sync queue, and that flush re-flags the path above every inode the pass deferred before it runs, since a mounted PFS's sync skips each inode child it meets and pre-clears `ONFLUSH` on the blocks above it without re-flagging them, which upstream's inode-driven flushes never need: measured 2026-10-18 as 22201 copied chains scrapped unflushed at a device teardown after the cluster's unmount had synced mid-pass. That flush is unconditional since 2026-10-16: the root's flags cannot gate it, and an idle pass's flush measures a few hundredths of a millisecond against a five-second cadence, recorded as a `DEFER` below. See `doc/history/verification-record.md`. Stage 2b of the cluster protocol note adds four `XXX` lines: a pass whose source master is a remote element runs live rather than snapshotting on a connection device, a pass on a device opened read-only refuses, with a log line, since nothing below it consults the open mode, and `hammer2_sync_insert()` refuses with `EIO` a block beneath an inode whose data is embedded, where the carried create would take the embedded bytes for a blockset, with a log line; a file the master grew between its directory's scan, which replaces the inode, and its own reaches that insert, and a remote master can feed one on purpose. A fifth drains the deferral list when a root scan fails other than by `EAGAIN`: the carried loop leaves the list to the next pass, which is harmless over the live PFS and is not over a snapshot, whose PFS the pass deletes, and the next pass's drain allocated an XOP on an inode of that freed PFS (a scanall feed refused under the pass, the sync thread's fault in `hammer2_trans_sub()`). Two more `XXX` lines print, under `hammer2_debug` 0x8000, each key the pass keeps on the slave because the slave's copy is newer than the source or absent from the snapshot, with both tids, which the wire harness counts after a resumed pass. Two lines under the same bit bracket the snapshot form, `begin` before the stale snapshot's delete and `end` after the pass's own snapshot's delete is tried, printed whether or not the lock admits it, so the span from the verdict to `end` holds that delete and, on a verified pass, the target's; the pair is what the tree arm of `cluster-sync.sh` times against the thread's cadence.
| `kern_dmsg.c` | 2244 | DragonFly's `sys/kern/kern_dmsg.c`, the dmsg message core, carried whole with twenty-seven `XXX` lines: `kmalloc`/`kfree` on `hmalloc()`/`hfree()` at ten sites, the `kdmsg_debug` sysctl as a module parameter, `ticks` as `getticks()`, `RB_ROOT` as the vendored `BSD_RB_ROOT`, `%jx` as `%llx`, the include block, and four of behavior: `kdmsg_iocom_reconnect()` shuts the descriptor it is replacing down before waiting for the threads, since the read thread leaves `fp_read()` only on data, EOF or that shutdown and the wait is an uninterruptible sleep inside an ioctl; the reader verifies both CRCs of a frame on a connection whose peer announced `DMSG_SPAN_PROTO_2` and ends the connection on a mismatch, stage 1 of `doc/CLUSTER_PROTOCOL_DESIGN.md`; the reader ends a connection on a frame in the HM2 space when its peer announced nothing, that space being `PROTO_2`'s vocabulary; and the reconnect clears that protocol flag, which is the connection's and not the device's |
| `hammer2_iocom.c` | 533 | DragonFly, carried, with twenty-four `XXX` lines: the FreeBSD port's `hammer2_chain_next()` without `key_beg`, the node name from `utsname`, the include block, and the cluster protocol note's stages 1 and 2: the peer's `LNK_CONN` announcing `DMSG_SPAN_PROTO_2` sets the connection's flag, a `PROTO_2` span is admitted beside `PROTO_1` and kept in a per-device span table, with its count and its lock, printed under `hammer2_debug` 0x0100, the table is emptied with the span's `DELETE` and with the connection, the kernel's own `LNK_CONN` and spans announce `PROTO_2` since the kernel serves the HM2 space, every frame in that space goes to `hammer2_remote.c`, the per-frame `RCVMSG` print is debug-gated, and the server is initialized, closed to new requests and drained before the message threads are stopped at a teardown or replaced at a reconnect, reopened when the new connection's peer announces `PROTO_2`, and freed after the reader is gone; the callback that reads the peer's `LNK_CONN` is installed before the reconnect starts the reader, where upstream installs it after, since a `LNK_CONN` already in the socket was otherwise answered with no callback and its `PROTO_2` never read, and a control build holds the reconnect a second at that point; the remote element's registration and keepalive are enabled only after the kernel's own `LNK_CONN` is queued, which that hold showed a span read first could precede; and two in `hammer2_update_spans()`, which upstream carries as written: the loop skipped a non-inode with a `continue` that never advanced the chain, and read the data of an inode whose read had failed, and the jump taken when the super-root has no chain passed the inode unlock |
| `hammer2_msgops.c` | 81 | DragonFly, carried whole but for the include block; its two functions have no caller upstream either |
| `hammer2_ccms.c` | 429 | DragonFly, carried, the state machine whole. The lockdep `LOCKENTER`/`LOCKEXIT` annotations are dropped; `panic()` becomes `hpanic()`, which marks the device in error and returns, at four sites; and the dead `int ccms_debug = 0` nobody reads is gone. Three `XXX` lines: upstream's own inside `ccms_cst_uninit()`, and the two bad-state arms of `ccms_thread_lock()` and `ccms_thread_lock_nonblock()`, which return after `hpanic()` rather than falling through to release the spin a second time, upstream's `panic()` never having returned. Its four `ssleep()` calls are the primitive the shim already had for it: a sleep that releases the CST's spin, which works because that spin is a `rw_semaphore` here and may be released, FreeBSD's choice whose `sx(9)` sleeps too. Behind `HAMMER2_CCMS_LOCKTEST`, 105 lines of this port's own: two kernel threads that take the lock so lockdep can see its class, started and stopped from `hammer2_module_init()` and `hammer2_module_exit()`; a default build compiles none of it |
| `hammer2_ccms.h` | 183 | DragonFly, carried; the `<sys/...>` includes dropped for this port's single `"hammer2.h"`, the guard renamed, and the `#ifdef _KERNEL` wrapper around the API dropped, there being no such split here |
| `hammer2_subr.c` | 458 | FreeBSD port, carried; the timestamp, the signal check and the two `timespec64` signatures are marked `XXX` in place, and `hammer2_getnewfsid()` is not carried |
| `hammer2_inode.c` | 2032 | FreeBSD port; carried, `hammer2_inode_create_normal()` with the owner rule written against the idmap. `hammer2_igetv()` is this port's, written on `iget5_locked()`, and its atime is reported, and a read's stored, under the `HAMMER2_ATIME` gate the three BSD ports carry, since HAMMER2 does not maintain atime and DragonFly reports the mtime in its place; it gives a device node, fifo or socket `init_special_inode()` with the device number the create stored, where until 2026-10-17 every type but a directory and a symlink took the regular-file operations. `hammer2_inode_get()` releases and retakes the holds of every element but the caller's own, marked `XXX`: the synchronization pass puts its slave chain there locked and not held, and the release of it spun forever the first time the inode lock was contended, a hang the remote element of stage 2b exposed. The slave chain stays locked while the pass waits for the inode lock, as it does on DragonFly by a reading of its `hammer2_chain_unhold()` (an owner's try-lock recurses there, so the release leaves the outer lock held), so a frontend holding that inode's lock whose XOP needs the same slave chain would wait on the pass: a candidate deadlock of DragonFly's own shape, which lockdep cannot see, since the pass takes the inode lock at subclass 1, and which no run has reproduced |
| `hammer2_vfsops.c` | 3915 | FreeBSD port, with DragonFly's sync-thread lines restored in `hammer2_pfsalloc()`, `hammer2_pfsdealloc()`, `hammer2_pfsfree()` and `hammer2_pfsfree_scan()`, the last freezing the threads before its sync rather than after, marked `XXX`, and deleting the snapshot a frozen thread's last pass could not, under the mount lock that refused it, `hammer2_pfsdealloc()` freeing the removed element's name, which upstream leaves to a teardown that never runs for a PFS freed at its last element, and its `debug` tunable and `sync_snapshot`, the synchronization pass's source (1, the default since both kernels read it clean, a snapshot of the master element; 0, the carried live pass, kept as the fallback), as module parameters; the PFS half and the recovery carried, the module entry, globals, mount path, mount helper, evict_inode, and sops this port's. A rewrite with a carried body, since Linux redistributes `hammer2_mount()` across four `fs_context` callbacks. `folio_changed` and `iohash_waits` are exported read-only beside `data_rewrites`, the first counting a block that changed between the write XOP's two reads of it and the second counting an acquisition of the device-wide io hash lock that had to wait; `->freeze_fs` and `->unfreeze_fs` are this port's, canceling the syncer a VFS freeze cannot see, and the comment there records the wedge they were wrongly withdrawn for and the probes that cleared them. For stage 2b of the cluster protocol note, five `XXX` lines: the mount and unmount accounting skip a connection device, `hammer2_pfsfree_scan()` detaches a PFS's remote elements before its local device leaves, and a read-write mount or remount is refused while a remote element is registered, under `hammer2_mntlk`. Two more read a lookup's inode only when its read left data, where upstream reads through NULL after an I/O error: the search for a PFS by label stops at an unreadable inode, which the error print after it names, and the recovery scan returns the inode's error as it does for an indirect block; and `hammer2_fixup_pfses()`, run on every read-write mount, skipped a non-inode under the super-root with a `continue` that never advanced the chain, as upstream's span update does |
| `hammer2_strategy.c` | 1640 | this port's; `hammer2_dedup_clear()` carried, `->readahead` hands each folio of the window to a worker, and the write XOP hands the core a whole-block folio's address rather than a copy, sampling every folio it reads around the read so a folio changed under the core is counted rather than argued about; the write XOP completes its folio at the last cluster element, after every element has written it, marked `XXX`, where upstream's first completing element lets the rest skip the write; a folio read that fails prints, under `hammer2_debug` 0x0100, what each cluster element fed, so a failure on a cluster names its element |
| `hammer2_vnops.c` | 2580 | this port's, the readdir position advancing past an emitted entry so a scan ended by an error does not hand the next getdents(2) the same entry; `->lookup` is upstream's `hammer2_lookup()` with the dcache's own cases and the nameiop pre-checks dropped, the seven operations tables have no BSD counterpart, a vnode taking its vop vector from the mount rather than from its type, `hammer2_zero_tail()` waits for a folio's writeback before zeroing it, since the write XOP hashes the folio itself, and `->llseek` and `->bmap` are built on the carried `hammer2_xop_bmap()`, which the BSDs reach through `vn_bmap_seekhole()` and `FIOSEEK*` and Linux reaches through the whences of `lseek(2)`; `->getattr` is on all four inode tables, including the symlink one, since a symlink's target past `HAMMER2_EMBEDDED_BYTES` owns a data block, `->fallocate` is marked `XXX` because no BSD port carries the vop at all: on this format a write whose block is all zeros is not stored, so a hole and a zeroed range are the same thing and a punch is a zeroing that deletes the chain, and `->fiemap` is built on the same bmap XOP the seeks use; `->setlease` is the kernel's `generic_setlease()` on the file and directory tables, since 7.2 refuses every lease and delegation on a filesystem that leaves it unset; a device node, fifo or socket gets the kernel's own file operations from `init_special_inode()` and its device number from the `rmajor` and `rminor` the create stored, as DragonFly gives a device node the spec vnode ops and a fifo the fifo ops; `->update_time` on all four inode tables stores the stamp `file_update_time()` asks for, from the one clock every stamp here is read from, since the kernel's own reading runs ahead of it by the multigrain floor and a write through a mapping otherwise never reached the media (`doc/README.porting.md`, "One clock for every time stamp") |
| `hammer2_ondisk.c` | 1044 | FreeBSD port; the volume-header verification half carried, the device half rewritten on `lookup_bdev()` and `bdev_file_open_by_path()`, and four functions not carried: `hammer2_lookup_device()` and the three GEOM access helpers |
| `hammer2_export.c` | 381 | this port's; the Linux file-handle surface, which no BSD tree has in this shape: the interface is the kernel's `export_operations` where DragonFly reaches NFS through `vfsops`, and the encoding is DragonFly's (`hammer2_vfs_vptofh()`), the inode number masked with `HAMMER2_DIRHASH_USERMSK`; the reverse lookup is the FreeBSD port's `hammer2_vget()`, built on the carried `hammer2_lookup_desc` XOP |
| `hammer2_mount.h` | 59 | FreeBSD port, carried, with DragonFly's `cluster_fd` restored; `hammer2_chain.c` includes it |
| `hammer2_xxhash.h` | 60 | ours: the kernel's `xxh64()` under the core's `XXH64` name and HAMMER2's seed |
| `hammer2_io.c` | 1379 | hash and dedup halves carried; OS half written on the page cache; a connection device's block is fetched from the peer before any lock and held in the dio's buffer, and its creation and its write are refused, three sites marked `/* Linux */` |
| `hammer2_remote.c` | 2814 | this port's; the HM2 XOP API server of `doc/CLUSTER_PROTOCOL_DESIGN.md`, stage 2a: a `PROTO_2` peer's read requests, queued by the reader thread to a per-device ordered workqueue, run the carried storage functions on a handle whose one element is this device's, with the inode found by number, no inode dependency taken and `hammer2_mntlk` held for the request so its PFS cannot be freed under it, each fed chain one reply frame under a window of sixteen, and the final error on the transaction's `DELETE`; and the client side of stage 2b: a connection device per `PROTO_2` link whose chains are proxies for the peer's, each block stashed by its feed and fetched again by handle when a later load needs it, the remote storage function the XOP loop runs for a slot on that device, each proxy classed for lockdep apart from the media's chains at its level on the peer, the work item that registers a master's admitted span as an element of a PFS with a local element and detaches it when the span, the link or the local device goes, and the keepalive on a work item of its own, a `LNK_PING` transaction every half of the bound whose refusal is the answer, a ping unanswered for the bound ending the link by the reader's own shutdown. The server sets the handle's `chk_mask` as the XOP loop does, since the retire drains only the FIFOs it names and a request ended early otherwise kept a reference on every chain it had fed; the client's `DELETE` goes out on a link already ended, since the message threads free a state only once both directions close and the exiting writer waits for every state, so a withheld `DELETE` wedged the redial and the unmount behind it; and a request on a link whose reader has exited is refused at once rather than at the writer's next half-second tick. No BSD tree has a remote element |
| `hammer2_os.h` | 1919 | ours, the OS shim |
| `hammer2_compat.h` | 224 | ours, kernel look-alikes; the BSD `vtype` enum and the `MNT_WAIT` pair, which no Linux header has |
| `hammer2_rb.h` | 207 | FreeBSD port's `RB_SCAN`, carried, with DragonFly's scan bookkeeping over the vendored tree |
| `sys/tree.h`, `sys/queue.h` | 2165 | vendored from freebsd-src, unchanged but for `__unused` |
| `sys/dmsg.h` | 942 | DragonFly's `sys/sys/dmsg.h`, the dmsg wire format and the kdmsg kernel structures, carried with fourteen `XXX` lines: `uuid_t` as `struct uuid` at five fields, the include block, the two `_KERNEL` guards opened, the two stage 1 of the cluster protocol note added, `DMSG_SPAN_PROTO_2` and the connection flag `KDMSG_IOCOMF_PROTO2`, and stage 2's three, the comment opening the HM2 XOP API and its two frames in the message union; the HM2 request and feed frames of stage 2, with the feed's end flag, a readdir's stopping key, and the call's tag and feed count that every reply frame echoes, are the port's own lines beside the carried ones |
| `sys/cdefs.h` | 36 | ours, three names the two vendored headers need |

### Upstream heads, as last read

Read from the forge on 2026-10-04, the check `doc/README.maintenance.md`
names and the one made before a tagged release: the FreeBSD, NetBSD and
OpenBSD ports are all at v1.2.13, tag and branch head alike, which is what
the snapshots beside this repository hold (`3df307f`, `64095c3`,
`a3747df`), so nothing there has moved since the carry.
`kusumi/hammer2-utils` is at v0.5.0, also tag and head alike.
DragonFly's newest commit under `sys/vfs/hammer2` is `40e5c5625` of
2026-09-02, which puts the unmount chain dump under `#if 0` in
`hammer2_vfsops.c`, and the one before it, `30436b52c` of 2026-09-01,
touches `hammer2_vnops.c` and `hammer2.h`. Nothing had moved since the
reading of 2026-09-29 below; the four figures are the same and the date is
the only change.

The earlier reading of this section said those commits touch nothing in the
carried set, and that is wrong: `hammer2.h` is carried from DragonFly at
`22b0532`, so the claim was false for a file the sync decision turns on.
The commit is harmless here, which was checked rather than assumed:
`30436b52c` removes `struct lockf advlock` from `struct hammer2_inode` and
replaces the port's `hammer2_vop_advlock` with `vop_stdadvlock`, and this
port's copy of the struct carries no `lockf` member and has no advlock vop,
because the BSD-only type is not the format. It is recorded because a
decision that rests on a wrong reading of which files are carried is a
decision that will be wrong the first time a change is not harmless.

`hammer2_disk.h` and `hammer2_ioctl.h`, the format and ioctl surfaces, have
had no commit since the carry, which is what the format being stable looks
like from here. The kernel of record is a separate pin and **has** moved:
`v7.3-rc5` was tagged 2026-09-27 and the port was run against it on
2026-09-29. The syntax gate reports 65 checks and 0 failed and the module
links warning-clean against the tree, so rc5 is a build-clean candidate;
the fixture and fill gates were then run on an rc5 guest kernel, whose
readings are in `doc/history/verification-record.md`. The two tags carry
the same `checkpatch.pl` byte for byte, so the style baseline moved only
its name line. 7.3 shipped on 2026-10-18 and the pin followed it on
2026-10-19: `KDIR=~/kernels/linux-7.3`, with the release and KASAN trees
beside it and the guest booting `7.3.0`, `7.3.0-release` and
`7.3.0-kasan` built from them. The release carries rc5's `checkpatch.pl`
byte for byte as well, so the baseline's name line moved a third time and
its counts did not; the syntax gate's reading against the release tree and
the first fleet runs on its kernels are in
`doc/history/verification-record.md`.

## What has been verified

Sixteen of the eighteen gates pass with no environment variables set on a
machine that has the kernel of record installed, as they have since
2026-08-26: the syntax gate finds that tree, and the style gate finds its
`checkpatch.pl`. The other two, `test-fixtures.sh` and `test-enospc.sh`,
report COULD-NOT-RUN there and on every machine without a guest, a set of
fixture images and a `KDIR` matching the guest's kernel, which is most of
them and all of CI. Measured on 2026-10-14 on this machine: 15 pass, 2
COULD-NOT-RUN, and both of those pass once `KDIR` names the guest's kernel
tree, which is what makes 17 the count of gates rather than of gates that
happen to run unattended.
What that unattended style run can say depends on which checker it finds.
The gate searches for the kernel of record the way the syntax gate does,
`/lib/modules/$(uname -r)/build` then `H2_KERNEL_TREES` then
`$HOME/kernels/*` then the store, and prefers the checker whose `sha256`
matches the baseline's, then one whose own tree reports the baseline's
version. Either can report an unchanged set. Only the first can charge a
moved set to the code: a version-matched checker with a different hash
exits 2 on a diff, because its counts are not the baseline's counts. So the
run after a carried file lands needs the baseline's checker reachable,
which on a machine holding the trees of record under `$HOME/kernels` it
now is, and otherwise `CHECKPATCH` pointed at it. `KDIR` does not select
the checker the way it selects the tree in the syntax gate: it is only the
first place searched, and a checker matching the baseline's `sha256`
anywhere else in the search wins over it. Before 2026-09-29 the
search skipped `$HOME/kernels`, so on that machine the unattended run
found only the host's 7.2 checker and refused outright. Saxum's delegator, which runs these same gates from another
repository, enumerates `script/test-*.sh` instead of naming them, so a gate
added here is picked up there without an edit. Each gate prints its own
count, and the gates are the authority; the dated figures below are snapshots
of one run.

`test-checkpatch.sh` is the one that commonly cannot run on a machine that
does not carry the kernel of record: `checkpatch.pl` ships with no kernel
headers package, so without a reachable tree it exits 2 unless `CHECKPATCH`
or `KDIR` points at one. That is could-not-run, not a pass.

- `script/test-shim.sh` and `script/test-syntax.sh`: 6 and 28 on 2026-08-26,
  two of the thirty-four being controls that must fail and do. The shim
  gate's sixth check is the one that reads its own coverage: an inline the
  driver never calls is barely checked by the compile, and the count says
  whether any are missed.
- `script/test-checkpatch.sh`: holds the style deviation set at its recorded
  856 hits under the checkpatch.pl the baseline names, and under the kernel
  of record's own patched copy, which differs by sha256 and produces an
  identical set. Neither figure travels without the checker that produced it;
  856 quoted bare reads as a mainline number and is not one. With no baseline
  present the gate refuses rather than writing one.
- `script/test-history.sh`: resolves every commit the changelog pins and
  checks its subject still matches, fails on any commit hash a tracked
  document names that is not on HEAD's history, since a message replay
  keeps every tree and moves every hash, then prints how many commits
  touching `src/` or `script/` have landed since the newest row. That last
  part never fails, since whether a commit deserves a version row is a
  judgment.
- `script/test-inventory.sh`: the directory is the population, and three
  hand-maintained lists claim to cover it: the origin table in this file, the
  Makefile's `hammer2-y`, and the filenames `script/test-syntax.sh` names one
  by one. A `.c` missing from the second is dead code; missing from the third
  is a file no compiler ever sees while every check reports passing. It also
  checks the origin table's line count against the file, which is the column
  that rots on an ordinary edit, and two rows had drifted before the check
  existed. A count column that is not a number is left alone.

  `test/` is a second population, added 2026-08-26 after two vector files
  were found tracked and named in no document here. Every file there is now
  either named by a gate or listed in `README.testing.md`. Both vector files
  turned out to be compiled by a gate in Saxum, which no search of this
  repository could have said, so that table records a contract with a
  consumer this tree does not reference.

- `script/test-citations.sh`: every `file:line` citation in a `doc/` table
  resolves, and where the row names a symbol, that symbol is on the line. The
  64 KiB inventory is thirteen such rows and nothing had ever read them. A
  line number rots on the next edit while still looking like a citation, and
  the 0.2 import edits exactly those files. It compares against the source
  line, never a stored baseline, and a row naming no symbol is reported as
  unanchored rather than dropped.

That the gates pass means the shim is valid C in both knob positions, and
that `hammer2.h` and `hammer2_io.c` type-check against the real kernel
headers of the kernel of record with both clang and gcc.

It does not mean anything runs. `-fsyntax-only` compiles nothing and links
nothing, which is why `doc/history/verification-record.md` records what
`make` does, and everything observed running from the first mount on,
with the instrument that observed it. The shipped build mounts read-write and remounts read-write from
read-only, and upstream's recovery is carried and runs on both paths.

## What is not here

`hammer2_strategy.c`, `hammer2_vfsops.c` and `hammer2_vnops.c`. All
three are OS-facing and all three are rewrites. That is what makes them
the remaining three; it is not a claim that nothing in them can be read
off a BSD port. `hammer2_strategy.c` in particular has chain logic
around its buffer handling, and how much of that carries is a question
for the file, not for this list.

`hammer2_ioctl.c` was in this list until 0.7.0 and is not a rewrite: it
came from the FreeBSD port whole and carries fifteen `XXX`, which is
where the OS shows through rather than a reimplementation.

The carried set is eight files at 11,204 lines, measured against all three BSD
ports: `hammer2_chain.c`, `hammer2_flush.c`, `hammer2_freemap.c`,
`hammer2_bulkfree.c`, `hammer2_xops.c`, `hammer2_admin.c`,
`hammer2_cluster.c` and `hammer2_subr.c`. `hammer2_ondisk.c` landed on
2026-08-26 and is not in it: half of it is carried and the device half is
this port's, which is what `doc/provenance.csv` records as `derived`.
Whether `hammer2_inode.c` joins the carried set is what that same carry
column will say.

### Logging

Every line `hprintf` prints names the module, and a line the core builds
out of several calls stays one line. Neither was true before 2026-08-26,
and neither is visible in a compile, so `test-shim.sh` reads both out of
the preprocessor's own output rather than taking a comment's word.

Linux's native mechanism for the first is `#define pr_fmt` at the top of
every `.c` file, ahead of the first kernel header. That is unavailable to
the files that do most of the logging here: they are carried
byte-for-byte, and adding a line to one is the edit this tree exists to
avoid. Measured with only `hammer2_io.c` carrying the define, five
carried files held every other call site and printed anonymously. The
name now lives in `hprintf` itself, which is this port's macro, so there
is one copy of it and no file has to remember anything.

**The literal prefix is `hammer2: `**, and a gate matching dmesg from 0.3
on should match that. It is `KBUILD_MODNAME`, which kbuild derives from
`obj-m += hammer2.o` in `src/sys/fs/hammer2/Makefile`, so it cannot drift
without the module's own filename drifting with it. Under
`HAMMER2_INVARIANTS` the function name, command and pid follow it; without
the knob, the function name alone. Both shapes start with `hammer2: `.

The second is `printf`, which on a BSD kernel appends to the open line;
`hammer2_bulkfree.c` prints a range with `hprintf` and no newline and
finishes it with `printf`. `pr_info` closes a record per call, so that
mapping turned one line into two and dropped the second's prefix.
`pr_cont` is Linux's name for the semantics the core is written against.

It is not free. `pr_cont` deliberately does not apply `pr_fmt`, so a `printf`
that opens a line prints without the module name. Every plain
`printf` in the carried core was classified by hand on 2026-08-26, all
thirteen of them:

| where | sites | kind | under `pr_cont` |
|---|---|---|---|
| `hammer2_bulkfree.c` | 7 | continuations of an `hprintf` that opened the line | correct, and one line |
| `hammer2_chain.c`, in `hammer2_dump_chain` | 2 | continuations | correct, and one line |
| `hammer2_chain.c`, in `hammer2_dump_chain` | 4 | line starts | correct line structure, no module name |

So four lines in the tree print anonymously, all four inside one debug
tree dumper, and no status or error path is among them. The alternative
mapping reverses that trade: `pr_info` names those four and splits the
other nine into eighteen lines, half of them unprefixed anyway. Neither
macro can be right at both kinds of site, since the discriminator is whether
the previous call ended in a newline, which is a runtime fact.
The `DEFER` in `hammer2_os.h` names the only mapping that is right at
both: build the line in a buffer and emit it once, which is a core edit.

checkpatch flags `pr_cont` deliberately and by name, and the deviation is
recorded in `README.kernel-style.md`.

### `DEFER` markers: the deliberate floors and what lifts each one

An `XXX` marks a mapping a reader should distrust. A `DEFER` marks
something this port chose not to build yet, and the rule the tree follows
is that a deferral without a named trigger is rot rather than pragmatism,
so each one carries the condition that lifts it. `test-inventory.sh`
checks that every `DEFER(` in `src/`, `script/`, `test/` and `.github/` appears in this table and that the
table has no row for a marker that is gone, because a ledger nothing reads
against the source is the same shape as an empty one.

| where | marker, verbatim | what is deferred |
|---|---|---|
| `hammer2_os.h`, at the print macros | `DEFER(a message is seen interleaved in a real mount)` | `pr_cont` is not the right mapping at both kinds of site; the table above measures the trade. The fix is a line buffer, which is a core edit |
| `script/hammer2-provenance.py`, in the scope note | `DEFER(a userland file is imported into the module tree)` | the CSV generator walks the kernel core only. `sbin/hammer2`, makefs, libhammer2 and hammer2-utils are packaged separately and audited in the license audit's own tables, so `TREES` widens the day one of their files is carried into `src/` |
| `src/sys/fs/hammer2/Makefile`, at `CARRIED_CFLAGS` | `DEFER(the tree is prepared for submission)` | kbuild's `-Wimplicit-fallthrough=5` reads only the `fallthrough` attribute and upstream marks its switches with a `/* fall through */` comment, and kbuild's `-Wunused` sees `hammer2_inode_lock_temp_release()` and `_restore()`, whose only caller in either upstream is `hammer2_igetv()`, the one function this port rewrote on `iget5_locked()`, where the dance they perform has nothing to race against. They have no caller here and are not expected to gain one; they stay because deleting two functions from a carried file is a core edit. Both are suppressed on the carried files rather than edited into Linux spelling, because converting either early splits the core into two dialects. They become edits in the single conversion that also settles BSD style |
| `hammer2_vfsops.c`, at the `sync_snapshot` parameter | `DEFER(a release read through the snapshot pass alone for a stated period)` | the carried live-to-live synchronization pass stays behind `sync_snapshot=0` as the fallback and as `cluster-sync.sh`'s negative control for the snapshot phase, since the snapshot pass is one release old; it goes when a release has read every fleet result through the snapshot pass alone for a stated period, and the loop in `hammer2_primary_sync_thread()` loses its branch |
| `hammer2_synchro.c`, at the target snapshot | `DEFER(a consumer that reads a slave element directly, a static mount or a standalone slave mount)` | the design note's fork-and-swap of a live target: the slave is written in place and its snapshot is the last known-good copy; no tree swaps a cluster element's root under a live mount, and nothing in this port reads a slave element's mixed state, the cluster mount serving reads from the master and a lone SLAVE label being refused at mount |
| `hammer2_vfsops.c`, at the module parameters | `DEFER(a second filesystem-wide knob wants a per-mount value)` | the tunables are `module_param_named()` under `/sys/module/hammer2/parameters/`, one value for every mount on the machine, which is what `sysctl` gave upstream too. A per-mount knob needs `/sys/fs/hammer2/`, where ext4 and btrfs put theirs |
| `hammer2_synchro.c`, where the scan reads each action's return | `DEFER(a failing pass is measured rewriting unrelated inodes)` | the record of a failed copy is one bit on the pass's deferral list, so once a key has failed no inode root is stamped for the rest of that pass, and the next pass replaces every one of those roots again as well as retrying the failed key. Scoping the bit to the failed key's ancestry needs each deferral entry to name its parent, which the carried list does not carry |
| `hammer2_vfsops.c`, above `hammer2_vfs_sync_devs()` | `DEFER(randwrite4k_fsync's median reads above ext4's in latency.sh)` | `fsync` writes the device through with `sync_blockdev()`, every dirty block of it and not the file's own, because the DIO layer keeps no per-inode set of device ranges. The reading that decides whether that costs anything a user sees is `script/latency.sh`'s fsync column beside ext4's |
| `hammer2_synchro.c`, above `hammer2_sync_flush()` | `DEFER(an idle pass's flush measured above a tenth of the cadence)` | the pass-end flush runs unconditionally. The root's flags cannot gate it, since a mounted PFS's sync clears the root's `ONFLUSH` on the way down (a pre-mark test skipped the flush that was needed) and a post-mark test reads the bit the walk set; a real gate needs a per-pass count of actions and stamps proved to cover every mutation. Measured 0.03 ms median idle (0.94 ms with two more prints in the window) against a 5.12 s cadence, so the count is not written until that ratio moves |
| `script/test-inventory.sh`, in the kmemleak rule's comment at the floor | `DEFER(a harness's run reuses one clear and its load twice, once under a redirection)` | the clear's marker is counted in the guest's `.out`, so the harness's one clear and load reused from a function or a loop with one run's output redirected or filtered keeps the host's count at one and adds no load line for the text rule to count; written to `/dev/kmsg` and counted from the kept kernel log, no enclosing redirection takes it, which costs a follower and a host copy in `cluster-quorum.sh` and the two fault harnesses, the ring clears those two run after the load moved, and the crash run's first half kept |
| `hammer2_remote.c`, at the flush descriptor in `hammer2_remote_xop()` | `DEFER(stage 3: a flush over the wire)` | a flush has no remote part in stage 2, whose remote element is read-only, so the element feeds a clean end without asking the peer, a vote of success no peer gave; every other end the element feeds is the peer's answer or reads as unreachable through `hammer2_remote_end()`. Stage 3, where a write reaches the peer, sends the flush and takes its end as the peer's. |

The middle column is the marker as it is spelled in the source, because
that is what the gate matches on: a reworded trigger in either place is a
failure rather than a drift.

Lifted 2026-09-07: `DEFER(every hpanic site has an error its caller
propagates)`, at `hpanic` in `hammer2_os.h`. Its trigger was the
reading `README.porting.md` names, a fault fired from
`hammer2_base_insert` with the writer told `EIO`, the mount read-only,
`umount` and `rmmod` returning and the device byte-identical to the
last good sync, and `script/hpanic-contain.sh` with `H2_KNOB=3` read
it that day against its control.

### `XXX` marks: how much of the core is not a carry

0.2's fourth exit criterion asks for this count. An `XXX` is the BSD ports'
mark for a mapping that is not mechanical, so the number says how many places
a reader should distrust. Counting raw occurrences answers the wrong
question, the carried files arriving with upstream's own. Measured 2026-08-26
against the FreeBSD port at
`3df307f` (v1.2.13), by file, ours minus upstream's; the first column
re-read 2026-09-07 after every `hpanic` site got its way out and
`hpanic` returned, seventy lines in eight files, each a mark, and again
2026-09-20 for the two marks that describe the io hash lock, which is one
for the device where DragonFly has one per bucket:

| file | `XXX` | upstream's | this port's |
|---|---|---|---|
| `hammer2_chain.c` | 111 | 18 | 93 |
| `hammer2_freemap.c` | 17 | 5 | 12 |
| `hammer2_bulkfree.c` | 5 | 4 | 1 |
| `hammer2_xops.c` | 6 | 1 | 5 |
| `hammer2_io.c` | 12 | 2 | 10 |
| `hammer2_os.h` | 3 | 0 | 3 |
| `hammer2_flush.c` | 20 | 8 | 12 |
| `hammer2_subr.c` | 7 | 0 | 7 |
| `hammer2_cluster.c` | 5 | 0 | 5 |
| `hammer2_ccms.c` | 3 | 1 | 2 |
| `hammer2_ccms.h` | 0 | 0 | 0 |
| `hammer2_synchro.c` | 135 | 7 | 128 |
| `hammer2_ondisk.c` | 22 | 1 | 21 |
| `hammer2_inode.c` | 32 | 6 | 26 |
| `hammer2_vfsops.c` | 69 | 9 | 60 |
| `hammer2_ioctl.c` | 46 | 3 | 43 |
| `hammer2_strategy.c` | 26 | 0 | 26 |
| `hammer2_vnops.c` | 4 | 0 | 4 |
| `hammer2.h` | 35 | 3 | 32 |
| `hammer2_export.c` | 0 | 0 | 0 |
| `hammer2_remote.c` | 0 | 0 | 0 |
| `hammer2_disk.h` | 6 | 1 | 5 |
| `hammer2_admin.c` | 19 | 0 | 19 |
| `hammer2_compat.h` | 0 | 0 | 0 |
| `hammer2_ioctl.h` | 0 | 0 | 0 |
| `hammer2_mount.h` | 0 | 0 | 0 |
| `hammer2_rb.h` | 3 | 0 | 3 |
| `hammer2_xxhash.h` | 0 | 0 | 0 |
| `sys/tree.h` | 1 | 1 | 0 |
| `sys/dmsg.h` | 16 | 2 | 14 |
| `kern_dmsg.c` | 32 | 5 | 27 |
| `hammer2_iocom.c` | 29 | 3 | 26 |
| `hammer2_msgops.c` | 1 | 0 | 1 |
| total | 665 | 80 | 585 |

Five hundred and eighty-five are this port's, the right-hand column
summed in the table's last row, which `test-inventory.sh` checks against
the rows, and they fall in twenty-five files: one hundred and twenty-eight in `hammer2_synchro.c`, ninety-three in `hammer2_chain.c`, sixty in `hammer2_vfsops.c`, forty-three in `hammer2_ioctl.c`, thirty-two in `hammer2.h`, twenty-seven in `kern_dmsg.c`, twenty-six in `hammer2_inode.c`, twenty-six in `hammer2_strategy.c`, twenty-six in `hammer2_iocom.c`, twenty-one in `hammer2_ondisk.c`, nineteen in `hammer2_admin.c`, fourteen in `sys/dmsg.h`, twelve in `hammer2_flush.c`, twelve in `hammer2_freemap.c`, ten in `hammer2_io.c`, seven in `hammer2_subr.c`, five in `hammer2_xops.c`, five in `hammer2_cluster.c`, five in `hammer2_disk.h`, four in `hammer2_vnops.c`, three in `hammer2_os.h`, three in `hammer2_rb.h`, two in `hammer2_ccms.c`, one in `hammer2_bulkfree.c`, and one in `hammer2_msgops.c`. That is the whole of them, and
it is the only place in this file that adds up to the column. The count
is prose because `test-inventory.sh` checks the total column only, and
the per-file figures here are read off that column rather than
recounted, which had left the total two low and `hammer2.h` two short.

`hammer2_admin.c`,
`hammer2_xops.c`, `hammer2_bulkfree.c`, `hammer2_chain.c`,
`hammer2_cluster.c` and `hammer2_mount.h` are still byte-identical to that
upstream commit under `cmp`, so most of the carried core has no port edit
of any kind, marked or unmarked.

The table covers every `.c` and `.h` under `src/sys/fs/hammer2/` whatever
its count, and any file elsewhere under `src/` that holds a mark, so
`src/sys/sys/queue.h` is absent by the rule rather than missing from it
while its sibling `tree.h` has a row;
`test-inventory.sh` checks the total column against `grep -c` and both
directions of that population. It did not until 2026-08-26, and had
drifted in the way an ungated count does: `hammer2_disk.h` and
`src/sys/sys/tree.h` were missing while both carry a mark, and
`hammer2_cluster.c` was listed at zero, which is what made a partial table
read as an inventory. Neither omission moved the count, which was fifty-two when this was measured. The two marks that prompted this
are their authors': `hammer2_disk.h`'s first is Dillon's note on the
reserved area, present in the FreeBSD commit above, and `tree.h`'s is
FreeBSD's own `XXXLAS`, which the vendoring left alone. `hammer2_disk.h`
gained a second, this port's, when `->statfs` landed and needed an
`f_type`: `<uapi/linux/magic.h>` carries no entry for this filesystem, so
the constant is the high half of the volume identifier, which spells HAM2. The two remaining columns are a
subtraction against a tree that is not on most machines, so they are not
gated and carry their measurement date instead.
