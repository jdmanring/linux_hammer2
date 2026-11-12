# HAMMER2 design, as upstream wrote it, and where this port stands

This is Matthew Dillon's design document for HAMMER2, carried whole, with a
note after each part saying where the Linux port stands against it. The
upstream text is DragonFly's `sys/vfs/hammer2/DESIGN`, version 6 of
08-Dec-2018, last changed upstream by `a4cea70ee4` (2023-05-12, a wording
fix; read from the forge's mirror `DragonFlyBSD/DragonFlyBSD` on
2026-11-12, since the clone here is shallow, and checked by no gate). It
sits in the fenced `upstream` blocks below exactly as DragonFly ships it,
typing errors included. `script/test-provenance.sh` reassembles those 35
blocks and checks their 999 lines against git blob
`5570027ee6f50edaa6da82c56b4cf54e920a6fc6`, and fails on a Markdown fence
that opens a line, behind a blockquote or list marker, and is tagged
upstream other than on the exact opener line or tagged with anything but
a plain word, so the text inside them cannot drift; raw HTML is not read.
Everything outside those blocks is this port's, and is edited here in
place. The license is DragonFly's
BSD license, the same as the carried sources'; the upstream file carries no
notice of its own, and the repository's `COPYRIGHT` covers it.

The notes say what is built and which step of the completion plan in
`doc/README.roadmap.md` ("Beyond 1.0") owns what is not, and they point to
the document that holds the readings rather than repeating them:
`doc/README.status.md` is the authority on state, `doc/README.capabilities.md`
on what each capability is backed by, and the design notes
(`doc/SYNC_DESIGN.md`, `doc/CLUSTER_PROTOCOL_DESIGN.md`, `doc/CCMS_DESIGN.md`)
on the cluster work. Where the port's code and this text differ, the note
says which the code follows; in several places upstream's own code differs
from its text too, and the note says that as well.

## Which version the other notes read

The synchronization and cache-coherency notes were written against version
3 of this document (2015-04-03), the copy Dillon posted to `users@` and this
tree keeps as `doc/research/primary/DILLON_HAMMER2_DESIGN_2015.md`; the
cluster note reads version 3 for the quorum protocol and version 6 for
`update_tid`. Version 6 rewrote parts of the text. Four of the changes are
worth stating, three because a note relies on the older form and one to
show a note unaffected:

- Version 3 drives synchronization by `modify_tid`, which propagates
  upward and is skipped on a match. Version 6 stops `modify_tid` at the
  changed block and gives that job to a third field, `update_tid`
  (MIRROR_TID, MODIFY_TID, UPDATE_TID below). The carried thread, in this
  tree and upstream's, compares `modify_tid` and never sets or reads
  `update_tid`, so on this point the code is version 3's.
  `doc/SYNC_DESIGN.md` describes the version 3 scheme and now says so.
- Version 3 says every cluster element is treated by its type whichever
  one is mounted; version 6 drops that sentence. `doc/SYNC_DESIGN.md`
  quotes it, now marked as version 3's.
- Version 3's directory entries were inodes, with a hardlinked file's
  inode hidden in the closest common parent directory; version 6 has
  directory entries apart from inodes, which are indexed by number under
  the PFS root. The carried core is version 6's.
- Version 3 kept `attr_tid` and `dirent_tid` in the inode "as an aid for
  the cache coherency subsystem"; version 6 has neither. `doc/CCMS_DESIGN.md`
  does not rely on them.

Checking the notes against both versions found one claim neither carries:
`doc/CCMS_DESIGN.md` said "the design document says the lock carries a key
range". Neither version says that; the key range is the `ccms_lock`'s
`key_beg` to `key_end` in `hammer2_ccms.h` before `94491fa098` (kept as
`doc/research/primary/hammer2_ccms.h.deleted`), which that note reads in its
own section on the two lock layers. The carried `hammer2_ccms.h` keeps
`ccms_cst` and no lock, and the sentence now names the deleted header.

## Status, as upstream left it

```upstream

			    HAMMER2 DESIGN DOCUMENT

				Matthew Dillon
			     dillon@backplane.com

			       08-Dec-2018 (v6)
			       24-Jul-2017 (v5)
			       09-Jul-2016 (v4)
			       03-Apr-2015 (v3)
			       14-May-2013 (v2)
			       08-Feb-2012 (v1)

			Current Status as of document date

* Filesystem Core	- operational
  - bulkfree		- operational
  - Compression		- operational
  - Snapshots		- operational
  - Deduper		- live operational, batch specced
  - Subhierarchy quotas - scrapped (still possible on a limited basis)
  - Logical Encryption	- not specced yet
  - Copies		- not specced yet
  - fsync bypass	- not specced yet
  - FS consistency	- operational

* Clustering core
  - Network msg core	- operational
  - Network blk device	- operational
  - Error handling	- under development
  - Quorum Protocol	- under development
  - Synchronization	- under development
  - Transaction replay	- not specced yet
  - Cache coherency	- not specced yet

			Recent Document Changes

* Reorganized the feature list to indicate currently operational features
  first, and moving the future features to another section (since they
  are taking so long to implement).

```

Version 6's table against this port. "Carried" means the code is
upstream's, compiled here with the changes the origin table in
`doc/README.status.md` records for its file. A row naming a file, a
script, a design note or a plan step from the completion plan takes its
state from that record, and the rest agree with
`doc/README.capabilities.md`.

| upstream row | upstream | this port |
|---|---|---|
| bulkfree | operational | carried; the synchronous `HAMMER2IOC_BULKFREE_SCAN` only, answered to `CAP_SYS_ADMIN` alone where DragonFly answers any user; `HAMMER2IOC_BULKFREE_ASYNC` is not carried; two passes return a removed set (`script/bulkfree.sh`) |
| Compression | operational | carried; LZ4 written here and read on DragonFly (`script/f4-roundtrip.sh`), LZ4 and ZLIB written by DragonFly and read here; a ZLIB block this module writes has not been read on DragonFly |
| Snapshots | operational | carried; a snapshot written here is mounted read-write and read back on DragonFly (`script/pfs-domains.sh`) |
| Deduper | live operational, batch specced | the live deduper is carried and on by default; no batch deduper exists in either tree |
| Subhierarchy quotas | scrapped | the inode's quota fields are stored and set by ioctl and enforced by neither tree; enforcement is P13 |
| Logical Encryption | not specced | none; P14 |
| Copies | not specced | the inode's `ncopies` is stored and nothing writes a second copy, here or upstream; P10 |
| fsync bypass | not specced | none; P15, a design review first |
| FS consistency | operational | carried; a flush cut off is read by `script/cut-flush.sh` and the crash matrix against the FreeBSD port by `script/crash-matrix.sh` |
| Network msg core | operational | carried since 1.0.33 (P6): `kern_dmsg.c`, `hammer2_iocom.c` and `hammer2_msgops.c`, behind `HAMMER2IOC_RECLUSTER` and the `cluster_fd=` mount option |
| Network blk device | operational | not built: `sys/dmsg.h` carries the `BLK` message definitions and no client or server of them is carried; a master on another host is reached by a chain-level protocol instead (`doc/SYNC_DESIGN.md`, the ruling of 2026-10-19; `doc/CLUSTER_PROTOCOL_DESIGN.md`) |
| Error handling | under development | `hpanic()` prints, marks the module in error and returns, so every mount on the machine stops writing where the BSD ports panic; under `HAMMER2_INVARIANTS` it is `BUG()` (`hammer2_os.h`; `script/hpanic-contain.sh` reads what a device in error keeps off the media) |
| Quorum Protocol | under development | the local quorum `hammer2_cluster_check()` decides between two MASTERs is read by `script/cluster-quorum.sh`; across hosts it is P8, and a PFS with a remote master is read-only until P8's lease |
| Synchronization | under development | `hammer2_synchro.c` carried since 0.9.61 and extended: a pass reads a snapshot of the master and keeps a snapshot of the slave until it verifies, locally and from a master on another host (P4 and P7 closed) |
| Transaction replay | not specced | none; P9 |
| Cache coherency | not specced | nothing is granted; `doc/CCMS_DESIGN.md` is the P3 note, and MESI over the wire is deferred by P8's decision D |

## Semantics and the radix tree

```upstream
			    Current Features List

* Standard filesystem semantics with full hardlink and softlink support.
  64-bit hardlink count field.

* The topology is indexed with a dynamic radix tree rooted in several
  places:  The super-root, the PFS root inode, and any inode boundary.
  Index keys are 64-bits.  Each element is referenced with a blockref
  structure (described below) that is capable of referencing a power-of-2
  sized block.  The block size is currently capped at 64KB to play
  nice(r) with the buffer cache and SSDs.

  The dynamic radix tree pushes elements into new indirect blocks only
  when the current level fills up, and will delete empty indirect blocks
  when a level is cleaned out.

```

The format is upstream's, unchanged. Two Linux facts sit under it. The link count is 64 bits
on the media and 32 in the kernel's `i_nlink`, and the port sets no
`s_max_links`, so the VFS's own guard is off; the module refuses with
`EMLINK` itself, in `hammer2_vop_link()` and where a directory's count
grows, against the literal `U32_MAX` where the FreeBSD port uses
`HAMMER2_LINK_MAX`, a constant this tree defines and does not use. Those
guards keep `set_nlink()` from truncating the 64-bit media count. The 64 KiB
block is the format's, and on Linux a 64 KiB device buffer needs the block
layer to hold a 64 KiB folio: `doc/IO_MODEL.md` describes the mechanism, and
`doc/README.roadmap.md` records 6.15 as the hard floor it sets for a second
kernel tier.

## Copy-on-write and the volume headers

```upstream
* Block-copy-on-write filesystem mechanism for both the main topology
  and for the freemap.  Media-level block frees are deferred and flushes
  rotate between (up to) 4 volume headers (capped at 4 if the filesystem
  is > ~8GB).  Recovery will choose the most recent fully-valid volume
  header and can thus work around failures which cause partial volume
  header writes.

  Modifications issue copy-on-write updates up to the volume root.

```

The format is upstream's, unchanged. What a flush cut off leaves, the newest valid volume
header and the tree it names, is read by `script/cut-flush.sh` with
DragonFly writing and this port mounting the result.

## Blockrefs, inodes and directory entries

```upstream
* Utilizes a fat blockref structure (128 bytes) which can store up to
  64 bytes (512 bits) of check code data for each referenced block.
  In the original implementation I had gone with 64 byte blockrefs,
  but I eventually decided that I wanted to support up to a 512-bit
  hash (which eats 64 bytes), so I bumped it up to 128 bytes.  This
  turned out to be fortuitous because it made it possible to store
  most directory entries directly in the blockref structure without
  having to reference a separate data block via the blockref structure.

* 1KB 'fat' inode structure.  The inode structure directly embeds four
  blockrefs so small files and directories can be represented without
  requiring an indirect block to be allocated.  The inode structure can
  also overload the same space to store up to 512 bytes of direct
  file data (for files which are <= 512 bytes long).

  The super-root and PFS root inodes are directly represented in the
  topology, without the use of directory entries.  A combination of
  normal directory entries and separtely-indexed inodes are implemented
  under each PFS.

  Normal filesystem inodes (other than inode 1) are indexed under the PFS
  root inode by their inode number.  Directory entries are indexed under the
  same PFS root by their filename hash.  Bit 63 is used to distinguish and
  partition the two.  Filename hash collisions are handled by incrementing
  reserved low bits in the filename hash code.

* Directory entries representing filenames that are less than 64 bytes
  long are directly stored AS blockrefs.  This means that an inode
  representing a small directory can store up to 4 directory entries in
  the inode itself before resorting to indirect blocks, and then those
  indirect blocks themselves can directly embed up to 512 directory entries.
  Directory entries with long filenames reference an indirect data block
  to hold the filename instead of directly-embedding the filename.

  This results in *very* compact directories in terms of I/O bandwidth.
  Not as compact as e.g. UFS's variable-length directory entries, but still
  very good with a nominal 128 real bytes per directory entry.

  Because directory entries are represented using a dynamic radix tree via
  its blockrefs, directory entries can be randomly looked up without having
  to scan the whole directory.
```

The format is upstream's, unchanged. The port computes the check codes the core
has: ISCSI32, XXHASH64, SHA192 and the freemap's CRC (the check switch in
`hammer2_chain.c`); none of them fills more than 192 of the 512 bits the
text describes, here or upstream. The CRC32C reference value and XXH64
values measured against xxhsum and libxxhash 0.8.3 are held in
`test/crc32c-vectors.c` and `test/xxh64-vectors.c`; neither is compiled or
run in this tree, and `script/test-vectors-contract.sh` freezes the
interface a gate in Saxum reads them through.

## PFSs and snapshots

```upstream

* Multiple PFSs.  In HAMMER2, all PFSs are implemented the same way, with
  the kernel choosing a default PFS name for the mount if none is specified.
  For example, "ROOT" is the default PFS name for a root mount.  You can
  create as many PFSs as you like and you can specify the PFS name in the
  mount command using the <device_path>@<pfs_name> notation.

* Snapshots are implemented as PFSs.  Due to the copy-on-write nature of
  the filesystem, taking a snapshot is a trivial operation requiring only
  a normal filesystme sync and copying of the PFS root inode (1KB), and
  that's it.

  On the minus side, can complicate the bulkfree operation that is responsible
  for freeing up disk space.  It can take significantly longer when many
  snapshots are present.

* SNAPSHOTS ARE READ-WRITE.  You can mount any PFS read-write, including
  snapshots.  For example, you can revert to an earlier 'root' that you
  made a snapshot of simply by changing what the system mounts as the root
  filesystem.

```

A mount names its PFS as `<device>@<label>`. A mount naming none asks for
`DATA`, where DragonFly chooses `BOOT`, `ROOT` or `DATA` from the last
character of the device name (the label default in `hammer2_vfsops.c`
says so). A snapshot is a PFS mounted
by its label, read-write: `script/pfs-domains.sh` changes a snapshot and
DragonFly reads the change apart from the live root, and
`script/root-boot.sh` boots a kernel on a HAMMER2 root.

## Coherency, and the asynchronous flush

```upstream
* Full filesystem coherency at both the radix tree level and the filesystem
  semantics level.  This is true for all filesystem syncs, recovery after
  a crash, and snapshots.

  The filesystem syncs fully vfsync the buffer cache for the files
  that are part of the sync group, and keeps track of dependencies to
  ensure that all inter-dependent inodes are flushed in the same sync
  group.  Atomic filesystem ops such as write()s are guaranteed to remain
  atomic across a sync, snapshot, and crash.

* Flushes and syncs are almost entirely asynchronous and will run concurrent
  with frontend operations.  This feature is implemented by adding inodes
  to the sync group currently being flushed on-the-fly as new dependencies
  are created, and reordering inodes in the sync queue to prioritize inodes
  which the frontend is stalled on.

  By reprioritizing inodes in the syncq, frontend stalls are minimized.

  The only synchronous disk operations is the final sync of the volume
  header which updates the ultimate root of the filesystem.  A disk flush
  command is issued synchronously, then the write of the volume header is
  issued synchronously.  All other writes to the disk, regardless of the
  complexity of the dependencies, occur asynchronously and can make very
  good use of high-speed I/O and SSD bandwidth.

```

The sync groups are carried: `hammer2_vfs_sync_pmp()` walks the depq,
moves each dependency's sideq onto the syncq and empties the depq, and an
inode the frontend blocks on is moved to the head of the syncq (`hammer2_inode.c`). Linux reaches it through
`->sync_fs`, and `->fsync` flushes the one inode. File data reaches chains
through `->writepages`, which runs the strategy XOPs and queues the inode
for the next sync (`hammer2_inode_delayed_sideq()`, a line upstream does
not have: without it a folio dirtied through a mapping reached the
strategy with its inode on no queue, and the comment at
`hammer2_writepages()` records what that lost); `script/storm.sh` reads
every fsynced cell whole after a remount. The text's claim that a `write()` stays atomic across a crash has
no reading here: the crash runs read what a cut flush leaves, not one
write cut in half.

The final step is ordered as the text says, but in two calls rather than
one command: the volume flush writes back the device's page cache
(`hammer2_dev_writeback()`, `sync_blockdev()`), then asks the drive to
empty its cache (`hammer2_dev_cache_flush()`, `blkdev_issue_flush()`), then
writes the header. DragonFly's `BUF_CMD_FLUSH` is the second of those;
`hammer2_os.h` says which BSD port each follows. `fsync(2)` writes the
device's dirty pages and issues no cache flush, as DragonFly's and the
FreeBSD port's do not.

The cluster's synchronization thread is the one writer outside this
scheme. Its copies have no `hammer2_inode` on any queue, so nothing above
reaches them: the thread flags the path from each copy to the volume root
itself (`hammer2_sync_setflush()`), re-flags each kept copy's path inside
the pass-end flush's transaction, since a mounted PFS's own sync clears the
flag above the inodes it stops at (`hammer2_sync_reflag()`), and runs its
own flush from the element's root with `HAMMER2_FLUSH_ALL`. Upstream's
thread does none of that; the comments above `hammer2_sync_setflush()` and on
`hammer2_deferred_list.done` in `hammer2_synchro.c` say what each was
measured to lose without it.

## Memory footprint

```upstream
* Low memory footprint.  Except for the volume header, the buffer cache
  is completely asynchronous and dirty buffers can be retired by the OS
  directly to backing store with no further interactions with the filesystem.

```

A DIO buffer is normally a 64 KiB folio of the block device's page cache,
held by reference, the page cache owning the memory, its writeback and its
reclaim; where the mapping yields no such folio the port falls back to a
`vmalloc()`ed buffer of its own, submitted as a bio, the one place the
memory is the port's (`doc/IO_MODEL.md`, "The object"). The volume header is held in memory
apart from them, as upstream holds it.

## Compression

```upstream
* Compression support.  Multiple algorithms are supported and can be
  configured on a subdirectory hierarchy or individual file basis.
  Block compression up to 64KB will be used.  Only compression ratios at
  powers of 2 that are at least 2:1 (e.g. 2:1, 4:1, 8:1, etc) will work in
  this scheme because physical block allocations in HAMMER2 are always
  power-of-2.

  Modest compression can be achieved with low overhead, is turned on
  by default, and is compatible with deduplication.

  Compression is extremely useful and often gives you anywhere from 25%
  to 400% the logical storage as you have physical blocks, depending.
  Of course, .tgz and other pre-compressed files cannot be compressed
  further by the filesystem.

  The usefulness shnould not be underestimated, our users are constantly
  being surprised at things the filesystem is able to compres that just
  makes life a lot easier.  For example, 30GB core dumps tend to contain
  a great deal of highly compressable data.  Source trees, web files,
  executables, general data... this is why HAMMER2 turns modest compression
  on by default.  It just works.

```

Carried. `hammer2 setcomp` sets it per directory (LZ4, ZLIB, `autozero` or
none); there is no mount option. Whether a new volume compresses by
default is the formatting tool's choice; a PFS made by `pfs-create` takes
the module's `HAMMER2_COMP_DEFAULT` (LZ4) and `HAMMER2_CHECK_DEFAULT`
(XXHASH64).

## De-duplication

```upstream
* De-duplication support.  HAMMER2 uses a relatively simple freemap
  scheme that allows the filesystem to discard block references
  asynchronously.  The same scheme allows essentially unlimited references
  to the same data block in the hierarchy.  Thus, both live de-duplication
  and bulk deduplication are relatively easy to implement.

  HAMMER2 currently implements only live de-duplications.  This means that
  typical situations such as when copying files or whole directory hierarchies
  will naturally de-duplicate.  Simply reading filesystem data in makes
  it available for deduplication later.  HAMMER2 will index a potentially
  very large number of blocks in memory, even beyond what the buffer cache
  can hold, for deduplication purposes.

```

Carried and on by default: the write path asks before every data block is
allocated, and the heuristic table is upstream's
(`doc/README.capabilities.md`, the Deduplication row, has the reading).
Only live de-duplication exists, as the text says.

## Zero-fill detection

```upstream
* Zero-fill detection on write (writing all-zeros), which requires the data
  buffer to be scanned, is fully supported.  This allows the writing of 0's
  to create holes.

  Generally speaking pre-writing zerod blocks to reserve space doesn't work
  well on copy-on-write filesystems.  However, if both compression and
  check codes are disabled on a file, H2 will also disable zero-detection,
  allowing the file blocks to be pre-reserved (by actually zeroing them and
  reusing them later on), and allow data overwrites to write to the same
  sector.  Please be aware that DISABLING THE CHECK CODE IN THIS MANNER ALSO
  MEANS THAT SNAPSHOTS WILL NOT WORK.  The snapshot will contain the latest
  data for the file and not the data as-of the snapshot.  This is NOT turned
  on by default in HAMMER2 and is not recommended except in special
  well-controlled circumstances.

```

Carried. A block of zeros becomes a hole, which is why a punch or a zero
range here zeroes its range rather than reserving it, why a plain
`fallocate(2)` leaves the range holding the bytes already in it, and why
xfstests' preallocation tests are listed in `test/xfstests/hammer2.exclude`.
The exception the text describes is narrower in the code than in the text:
both trees skip zero detection when the check code is `NONE`, whatever the
compression (the two `test_block_zeros()` calls in `hammer2_strategy.c`,
the same as DragonFly's). No run here sets a check code of `NONE`, so the
in-place path is carried and not read.

## Kernel threads

```upstream
* Multiple supporting kernel threads, breaking up frontend VOP operation
  from backend I/O, compression, and decompression operation.  Buffer cache
  I/O and VOP ops message the backend.  Actual I/O is handled by the backend
  and not by the frontend, which will theoretically allow us to survive
  stalled devices and nodes when implementing multi-node support.

```

Not carried. This port runs an XOP in the calling thread, one element
after another, as the FreeBSD port does; only strategy XOPs, the file
data's reads and writes, run concurrently. The pool is deferred with
multi-master as its trigger and the decision is not taken
(`doc/DROPS_AND_DISABLES.md`, "The XOP thread pool"): a cluster operation
pays its fan-out across elements serially until it is. The worker pool upstream
partitions by inode and element is absent, so compression and
decompression run in the caller too, and a stalled device stalls its
caller. `hammer2_xop_start_except()` in `hammer2_admin.c` says what the
synchronous form keeps, and `doc/README.roadmap.md` holds the reading the
synchronous form was kept on.

## Pending: a filesystem across nodes

```upstream
			    Pending Features
			  (not yet implemented)

* Constructing a filesystem across multiple nodes.  Each low-level H2 device
  would be able to accommodate nodes belonging to multiple cluster components
  as well as nodes that are simply local to the device or machine.

  CURRENT STATUS: Not yet operational.

```

Begun. An element on another host is the remote element of
`doc/CLUSTER_PROTOCOL_DESIGN.md`, reached over the message core: a
SLAVE's thread copies from a master on another host, and a PFS with a
remote master is read-only until P8's lease protocol.

## Pending: incremental synchronization

```upstream
* Incremental synchronization via highest-transaction id propagation
  within the radix tree.  This is a queueless, incremental design.

  CURRENT STATUS: Due to the flat inode hierarchy now being employed,
  the current synchronization code which silently recurses indirect nodes
  will be inefficient due to the fact that all the inodes are at the
  same logical level in the topology.  To fix this, the code will need
  to explicitly iterate indirect nodes and keep track of the related
  key ranges to match them up on an indirect-block basis, which would
  be incredibly efficient.

```

The carried thread compares `modify_tid` per inode, and the inefficiency
the text predicts is measured: a pass walks every inode the PFS indexes
whatever changed, so one rewritten file on a million-file tree costs a
pass of about 33 s (`doc/README.capabilities.md`, the Replication row).
The indirect-block skip the text proposes is designed in
`doc/SYNC_DESIGN.md`, "Skipping unchanged subtrees", and not built.

## Pending: background synchronization

```upstream
* Background synchronization and mirroring occurs at the logical layer
  rather than the physical layer.  This allows cluster components to
  have differing storage arrangements.

  In addition, this mechanism will fully correct any out of sync nodes
  in the cluster as long as a sufficient number of other nodes agree on
  what the proper state should be.

  CURRENT STATUS: Not yet operational.

```

Built in the form this paragraph names: the thread copies inodes,
directory entries and data between elements, logically, so the two may
sit on differently arranged media. Correcting a node by what a quorum
agrees on is the local quorum's today; bringing back a MASTER that fell out
of it is P9.

## Pending: encryption

```upstream
* Encryption.  Whole-disk encryption is supported by another layer, but I
  intend to give H2 an encryption feature at the logical layer which works
  approximately as follows:

  - Encryption controlled by the client on an inode/sub-tree basis.
  - Server has no visibility to decrypted data.
  - Encrypt filenames in directory entries.  Since the filename[] array
    is 256 bytes wide, client can add random bytes after the normal
    terminator to make it virtually impossible for an attacker to figure
    out the filename.
  - Encrypt file size and most inode contents.
  - Encrypt file data (holes are not encrypted).
  - Encryption occurs after compression, with random filler.
  - Check codes calculated after encryption & compression (not before).

  - Blockrefs are not encrypted.
  - Directory and File Topology is not encrypted.
  - Encryption is not sub-topology validation.  Client would have to keep
    track of that itself.  Server or other clients can still e.g. remove
    files, rename, etc.

  In particular, note that even though the file size field can be encrypted,
  the server does have visibility on the block topology and thus has a pretty
  good idea how big the file is.  However, a client could add junk blocks
  at the end of a file to make this less apparent, at the cost of space.

  If a client really wants a fully validated H2-encrypted space the easiest
  solution is to format a filesystem within an encrypted file by treating it
  as a block device, but I digress.

  CURRENT STATUS: Not yet operational.

```

None; P14, which waits until its interaction with copies and dedup is
specified. The link between two hosts can run over kernel TLS
with a pre-shared key since 1.0.78, which protects the transport and is
not the logical encryption described here.

## Pending: ganging and copies

```upstream
* Device ganging, copies for redundancy, and file splitting.

  Device ganging - The idea here is not to gang devices into a single
  physical volume but to instead format each device independently
  and allow crossover-references in the blockref to other devices in
  the set.

  One of the things we want to accomplish is to ensure that a failed
  device does not prevent access to radix tree elements in other devices
  in the gang, and that the failed device can be reconstructed.  To do
  this, each device implements complete reachability from the node root
  to all elements underneath it.  When a device fails, the sychronization
  code can theoretically reconstruct the missing material in other
  devices making up the gang.  New devices can be added to the gang and
  existing devices can be removed from the gang.

  Redundant copies - This is actually a fairly tough problem.  The
  solution I would like to implement is to use the device ganging feature
  to also implement redundancy, that way if a device fails within the
  gang there's a good chance that it can still remain completely functional
  without having to resynchronize.  But making this work is difficult to say
  the least.

  CURRENT STATUS: Not yet operational.

```

None. A filesystem may span up to 64 volumes as one device set
(`HAMMER2_MAX_VOLUMES`), which `script/pfs-domains.sh` reads with two;
that is the format's volume list, not the ganging described here, and no
volume has been added to a mounted filesystem. Copies are P10 and device
add, remove and replace are P12.

## Pending: MESI cache coherency

```upstream
* MESI Cache coherency for multi-master/multi-client clustering operations.
  The servers hosting the MASTERs are also responsible for keeping track of
  the cache state.

  This is a feature that we would need to implement coherent cross-machine
  multi-threading and migration.

  CURRENT STATUS: Not yet operational.

```

None. `doc/CCMS_DESIGN.md` found that the MESI layer was never written
upstream and records what is reproducible; P8's decision D defers MESI
over the wire.

## Pending: unverified de-duplication

```upstream
* Implement unverified de-duplication (where only the check code is tested,
  avoiding having to actually read data blocks to calculate a de-duplication.
  This would make use of the blockref structure's widest check field
  (512 bits).

  Out of necessity this type of feature would be settable on a file or
  recursive directory tree basis, but should only be used when the data
  is throw-away or can be reconstructed since data corruption (mismatched
  duplicates with the same hash) is still possible even with a 512-bit
  check code.

  The Unverified dedup feature is intended only for those files where
  occasional corruption is ok, such as in a web-crawler data store or
  other situations where the data content is not critically important
  or can be externally recovered if it becomes corrupt.

  CURRENT STATUS: Not yet operational.

```

In neither tree, and not a step of the completion plan.

## General design: the block table

```upstream
				GENERAL DESIGN

HAMMER2 generally implements a copy-on-write block design for the filesystem,
which is very different from HAMMER1's B-Tree design.  Because the design
is copy-on-write it can be trivially snapshotted simply by making a copy
of the block table we desire to snapshot.  Snapshotting the root inode
effectively snapshots the entire filesystem, whereas snapshotting a file
inode only snapshots that one file.  Snapshotting a directory inode is
generally unhelpful since it only contains directory entries and the
underlying files are not arranged under it in the radix tree.

The copy-on-write design implements a block table as a radix-tree,
with a small fan-out in the volume header and inode (typically 4x) and
a large fan-out for indirect blocks (typically 128x and 512x depending).
The table is built bottom-up.  Intermediate radixes are only created when
necessary so small files and directories will have a much shallower radix
tree.

```

The format is upstream's, unchanged.

## General design: space optimizations

```upstream
HAMMER2 implements several space optimizations:

  1. Directory entries with filenames <= 64 bytes will fit entirely
     in the 128-byte blockref structure and do not require additional data
     block references.  Since blockrefs are the core elements making up
     block tables, most directories should have good locality of reference
     for directory scans.

     Filenames > 64 bytes require a 1KB data-block reference, which
     is clearly less optimal, but very few files in a filesystem tend
     to be larger than 64 bytes so it works out.  This also simplifies
     the handling for large filenames as we can allow filenames up to
     1023 bytes long with this mechanism with no major changes to the
     code.

  2. Inodes embed 4 blockrefs, so files up to 256KB and directories with
     up to four directory entries (not including "." or "..") can be
     accommodated without requiring any indirecct blocks.

  3. Indirect blocks can be sized to any power of two up to 65536 bytes,
     and H2 typically uses 16384 and 65536 bytes.  The smaller size is
     used for initial indirect blocks to reduce storage overhead for
     medium-sized files and directories.

  4. The File inode itself can directly hold the data for small
     files <= 512 bytes in size, overloading the space also used
     by its four 128 bytes blockrefs (which are not needed if the
     file is <= 512 bytes in size).  This works out great for small
     files and directories.

  5. The last block in a file will have a storage allocation in powers
     of 2 from 1KB to 64KB as needed.  Thus a small file in excess of
     512 bytes but less than 64KB will not waste a full 64KB block.

  6. When compression is enabled, small physical blocks will be allocated
     when possible.  However, only reductions in powers of 2 are supported.
     So if a 64KB data block can be compressed to (16KB+1) to 32KB, then
     a 32KB block will be used.  This gives H2 modest compression at very
     low cost without too much added complexity.

  7. Live de-dup will attempt to share data blocks when file copying is
     detected, significantly reducing actual physical writes to storage
     and the storage used.  Bulk de-dup (when implemented), will catch
     other cases of de-duplication.

```

The format is upstream's, unchanged, and each of the seven mechanisms is
the core's code. The port's Linux edits here are the compression calls
inside `hammer2_compress_and_write()`, which reach LZ4 and zlib through
the kernel's own libraries with work memory the caller allocates, and
the chain pointer cleared before the error paths, which leave through
`hpanic` where upstream panics.

## General design: directories

```upstream
Directories contain directory entries which are indexed using a hash of
their filename.  The hash is carefully designed to maintain some natural
sort ordering.  The directory entries are implemented AS blockrefs.  So
an inode can contain up to 4 before requiring an indirect block, and
each indirect block can contain up to 512 entries, with further data block
references required for any directory entry whos filename is > 64 bytes.
Because the directory entries are blockrefs, random access lookups are
maximally efficient.  The directory hash is designed to very loosely try
to retain some alphanumeric sorting to bundle similarly-named files together
and reduce random lookups.

```

Carried. Linux hands `readdir` a buffer, and the port sizes each chunk of
the directory scan from it (`dir_context.count`); the position is the
directory hash, as upstream's cookie is.

## General design: copy-on-write to the volume header

```upstream
The copy-on-write nature of the filesystem means that any modification
whatsoever will have to eventually synchronize new disk blocks all the way
to the super-root of the filesystem and then to the volume header itself.
This forms the basis for crash recovery and also ensures that recovery
occurs on a completed high-level transaction boundary.  All disk writes are
to new blocks except for the volume header (which cycles through 4 copies),
thus allowing all writes to run asynchronously and concurrently prior to
and during a flush, and then just doing a final synchronization and volume
header update at the end.  Many of HAMMER2s features are enabled by this
core design feature.

The Freemap is also implemented using a radix tree via a set of pre-reserved
blocks (approximately 4MB for every 2GB of storage), and also cycles through
multiple copies to ensure that crash recovery can restore the state of the
filesystem quickly at mount time.

```

The format is upstream's, unchanged. DragonFly reads back what this port writes and the
reverse (`script/f4-roundtrip.sh`).

## General design: the buffer cache

```upstream
HAMMER2 tries to maintain a small footprint and one way it does this is
by using the normal buffer cache for data and meta-data, and allowing the
kernel to asynchronously flush device buffers at any time (even during
synchronization).  The volume root is flushed separately, separated from
the asynchronous flushes by a synchronizing BUF_CMD_FLUSH op.  This means
that HAMMER2 has very low resource overhead from the point of view of the
operating system and is very much unlike HAMMER1 which had to lock dirty
buffers into memory for long periods of time.  HAMMER2 has no such
requirement.

Buffer cache overhead is very well bounded and can handle filesystem
operations of any complexity, even on boxes with very small amounts
of physical memory.  Buffer cache overhead is significantly lower with H2
than with H1 (and orders of magnitude lower than ZFS).

```

The block device's page cache stands where the buffer cache stands (the
note after "Memory footprint" above). File data uses the classic
address-space operations, not iomap; `doc/README.roadmap.md` has the decision and why iomap cannot hold
the check codes, compression and de-duplication between the folio and the
device.

## General design: the fsync shortcut

```upstream
At some point I intend to implement a shortcut to make fsync()'s run fast,
and that is to allow deep updates to blockrefs to shortcut to auxillary
space in the volume header to satisfy the fsync requirement.  The related
blockref is then recorded when the filesystem is mounted after a crash and
the update chain is reconstituted when a matching blockref is encountered
again during normal operation of the filesystem.

```

Not built in either tree; P15, "only if the current format still supports
it", after a design review.

## Filesystem sync sequencing

```upstream
			    FILESYSTEM SYNC SEQUENCING

HAMMER2 implements a filesystem sync mechanism that allows the frontend
to continue doing modifying operations concurrent with the sync.  The
general sync mechanism operates in four phases:

    1.	Individual file and directory inodes are fsync()d to disk,
	updated the blockrefs in the parent block above the inode, and
	removed from the syncq.

	Once removed from the syncq, the frontend can do a modifying
	operation on these file and directory inodes without further
	effecting the filesystem sync.  These modifications will be
	flushed to disk on the next filesystem sync.

	To reduce frontend stall times, an inode blocked on by the frontend
	which is on the syncq will be reordered to the front of the syncq
	to give the syncer a shot at it more quickly, in order to unstall
	the frontend ASAP.

	If a frontend operations creates an unavoidable dependency between
	an inode on the syncq and an inode not on the syncq, both inodes
	are placed on (or back onto) the syncq as needed to ensure filesystem
	consistency for the filesystem sync.  This can extend the filesystem
	sync time, but even under heavy loads syncs are still able to be
	retired.

    2.  The PFS ROOT is fsync()d to storage along with the subhierarchy
	representing the inode index (whos inodes were flushed in (1)).
	This brings the block copy-on-write up to the root inode.

    3.	The SUPER-ROOT inode is fsync()d to storage along with the
	subhierarchy representing the PFS ROOTs for the volume.

    4.	Finally, a physical disk flush command is issued to the storage
	device, and then the volume header is written to disk.  All
	I/O prior to this step occurred asynchronously.  This is the only
	step which must occur synchronously.

```

Carried, phase for phase: `hammer2_vfs_sync_pmp()` runs phase 1 over the
syncq with each inode flushed with `HAMMER2_XOP_INODE_STOP`, which the
flush turns into `HAMMER2_FLUSH_INODE_STOP`, and the
flush that writes the volume header (`HAMMER2_XOP_VOLHDR`) runs phases 2
to 4. Phase 4's two halves are the device writeback and the cache flush
described after "Coherency, and the asynchronous flush" above. The
synchronization thread's own flush, also described there, is the one
flush outside these phases.

## MIRROR_TID, MODIFY_TID, UPDATE_TID

```upstream
			MIRROR_TID, MODIFY_TID, UPDATE_TID

In HAMMER2, the core block reference is a 128-byte structure called a blockref.
The blockref contains various bits of information including the 64-bit radix
key (typically a directory hash if a directory entry, inode number if a
hidden hardlink target, or file offset if a file block), number of significant
key bits for ranged recursion of indirect blocks, a 64-bit device seek that
encodes the radix of the physical block size in the low bits (physical block
size can be different from logical block size due to compression),
three 64-bit transaction ids, type information, and up to 512 bits worth
of check data for the block being reference which can be anything from
a simple CRC to a strong cryptographic hash.

mirror_tid - This is a media-centric (as in physical disk partition)
	     transaction id which tracks media-level updates.  The mirror_tid
	     can be different at the same point on different nodes in a
	     cluster.

	     Whenever any block in the media topology is modified, its
	     mirror_tid is updated with the flush id and will propagate
	     upward during the flush all the way to the volume header.

	     mirror_tid is monotonic.  It is primarily used for on-mount
	     recovery and volume root validation.  The name is historical
	     from H1, it is not used for nominal mirroring.

modify_tid - This is a cluster-centric (as in across all the nodes used
	     to build a cluster) transaction id which tracks filesystem-level
	     updates.

	     modify_tid is updated when the front-end of the filesystem makes
	     a change to an inode or data block.  It does NOT propagate upward
	     during a flush.

update_tid - This is a cluster synchronization transaction id.  Modifications
	     made to the topology will clear this field to 0 as they propagate
	     up to the root.  This gives the synchronizer an easy way to
	     determine what needs revalidation.

	     The synchronizer revalidates the cluster bottom-up by validating
	     a sub-topology and propagating the highest modify_tid in the
	     validated sub-topology up via the update_tid field.

	     Update to this field may be optimized by the HAMMER2 VFS to
	     avoid the double-transition.

The synchronization code updates an out-of-sync node bottom-up and will
dynamically set update_tid as it goes, but media flushes can occur at any
time and these flushes will use mirror_tid for flush and freemap management.
The mirror_tid for each flush propagates upward to the volume header on each
flush.  modify_tid is set for any chains modified by a cluster op but does
not propagate up, instead serving as a seed for update_tid.

* The synchronization code is able to determine that a sub-tree is
  synchronized simply by observing the update_tid at the root of the sub-tree,
  on an inode-by-inode basis and also on a data-block-by-data-block basis.

* The synchronization code is able to do an incremental update of an
  out-of-sync node simply by skipping elements with a matching update_tid
  (when not 0).

* The synchronization code can be interrupted and restarted at any time,
  and is able to pick up where it left off with very low overhead.

* The synchronization code does not inhibit media flushes.  Media flushes
  can occur (and must occur) while synchronization is ongoing.

There are several other stored transaction ids in HAMMER2.  There is a
separate freemap_tid in the volume header that is used to allow freemap
flushes to be deferred, and inodes have a pfs_psnap_tid which is used in
conjunction with CHECK_NONE to allow blocks without a check code which do
not violate the most recent snapshot to be overwritten in-place.

Remember that since this is a copy-on-write filesystem, we can propagate
a considerable amount of information up the tree to the volume header
without adding to the I/O we already have to do.

```

`mirror_tid` and the freemap's `freemap_tid` are carried as described, and
so is the in-place overwrite the text gives `pfs_psnap_tid`: the field the
code carries and tests is `pfs_lsnap_tid` (`hammer2_disk.h`), against
`CHECK_NONE` (`hammer2_chain.c`), which no run here sets. Two parts of
this section are not what either tree's code does.

`modify_tid` does propagate during a flush: the flush raises a parent's
`modify_tid` to its child's where the child's is larger (the raise in
`hammer2_flush.c`, the FreeBSD port's file, the line upstream's own), so
the text's "It does NOT
propagate upward during a flush" describes the intent and not the code.
The port's XOP ordering accounts for that propagation
(`hammer2_admin.c`, the comment above the ordered descriptors).

`update_tid` is a field of the blockref and nothing more: no code in
either tree sets it or compares it, and the synchronization thread skips
by `modify_tid` as version 3 described. `doc/CLUSTER_PROTOCOL_DESIGN.md`
holds `update_tid` as the format's reserved candidate for cluster
validation, which is this section's intent.

## Directories and inodes

```upstream
			    DIRECTORIES AND INODES

Directories are hashed.  In HAMMER2, the PFS ROOT directory (aka inode 1 for
a PFS) can contain a mix of directory entries AND embedded inodes.  This was
actually a design mistake, so the code to deal with the index of inodes
vs the directory entries is slightly convoluted (but not too bad).

In the first iteration of HAMMER2 I tried really hard to embed actual
inodes AS the directory entries, but it created a mass of problems for
implementing NFS export support and dealing with hardlinks, so in a later
iteration I implemented small independent directory entries (that wound up
mostly fitting in the blockref structure, so WIN WIN!).  However, 'embedded'
inodes AS the directory entries still survive for the SUPER-ROOT and the
PFS-ROOTs under the SUPER-ROOT.  They just aren't used in the individual
filesystem that each PFS represents.

Hardlinks are now implemented normally, with multiple directory entries
referencing the same inode and that inode containing a nlinks count.

```

Carried as version 6 describes. NFS export reaches inodes by number
through `export_operations`, with DragonFly's handle encoding
(`hammer2_export.c`; `doc/README.capabilities.md`, the NFSExport row).

## Recovery

```upstream
				    RECOVERY

H2 allows freemap flushes to lag behind topology flushes.  This improves
filesystem sync performance.  The freemap flush tracks a separate
transaction id (via mirror_tid) in the volume header.

On mount, HAMMER2 will first locate the highest-sequenced check-code-validated
volume header from the 4 copies available (if the filesystem is big enough,
e.g. > ~8GB or so, there will be 4 copies of the volume header).

HAMMER2 will then run an incremental scan of the topology for mirror_tid
transaction ids between the last freemap flush tid and the last topology
flush tid in order to synchronize the freemap.  Because this scan is
incremental the time it takes to run will be relatively short and well-bounded
at mount-time.  This is NOT an fsck.  Freemap flushes can be avoided for any
number of normal topology flushes but should still occur frequently enough
to avoid long recovery times in case of a crash.

The filesystem is then ready for use.

```

Carried. A writable mount runs `hammer2_recovery()` and then
`hammer2_fixup_pfses()` (`hammer2_vfsops.c`); a read-only mount runs
neither.

## Disk I/O

```upstream
			    DISK I/O OPTIMIZATIONS

The freemap implements a 1KB allocation resolution.  Each 2MB segment managed
by the freemap is zoned and has a tendency to collect inodes, small data,
indirect blocks, and larger data blocks into separate segments.  The idea is
to greatly improve I/O performance (particularly by laying inodes down next
to each other which has a huge effect on directory scans).

The current implementation of HAMMER2 implements a fixed 64KB physical block
size in order to allow the mapping of hammer2_dio's in its IO subsystem
to consumers that might desire different sizes.  This way we don't have to
worry about matching the buffer cache / DIO cache to the variable block
size of underlying elements.  In addition, 64KB I/Os allow compatibility
with physical sector sizes up to 64KB in the underlying physical storage
with no change in the byte-by-byte format of the filesystem.  The DIO
layer also prevents ordering deadlocks between unrelated portions of the
filesystem hierarchy whos logical blocks wind up in the same physical block.

The biggest issue we are avoiding by having a fixed 64KB I/O size is not
actually to help nominal front-end access issue but instead to reduce the
complexity of having to deal with mixed block sizes in the buffer cache,
particularly when blocks are freed and then later reused with a different
block size.  HAMMER1 had to have specialized code to check for and
invalidate buffer cache buffers in the free/reuse case.  HAMMER2 does not
need such code.

That said, HAMMER2 places no major restrictions on mixing logical block
sizes within a 64KB block.  The only restriction is that a logical HAMMER2
block cannot cross a 64KB boundary.  The soft restrictions the block
allocator puts in place exist primarily for performance reasons (i.e. to
try to collect 1K inodes together).  The 2MB freemap zone granularity
should work very well in this regard.

HAMMER2 also utilizes OS support for ganging 64KB buffers together into even
larger blocks for I/O (OS buffer cache 'clustering'), OS-supported read-ahead,
OS-driven asynchronous retirement, and other performance features typically
provided by the OS at the block-level to ensure smooth system operation.

By avoiding wiring buffers/memory and allowing the OS's buffer cache to
run normally, HAMMER2 winds up with very low OS overhead.

```

The freemap's 1 KiB resolution and its zoning are upstream's, unchanged; the
image's allocation order is read beside DragonFly's by
`script/throughput.sh`. The fixed 64 KiB DIO is the port's too, normally a
64 KiB folio of the device's page cache (`doc/IO_MODEL.md`), with the
fallback the note after "Memory footprint" describes. The OS
features the last paragraphs name are Linux's: the block layer merges
adjacent dirty folios into larger device writes, which is why the
`cluster_write` parameter was removed rather than wired
(`doc/README.roadmap.md`, the decision that removed it), and the
device mapping's read-ahead is the kernel's `page_cache_sync_ra()`
(`hammer2_io.c`).

## Freemap notes

```upstream
				FREEMAP NOTES

The freemap is stored in the reserved blocks situated in the ~4MB reserved
area at the base of every ~1GB level-1 zone of physical storage.  The current
implementation reserves 8 copies of every freemap block and cycles through
them in order to make the freemap operate in a copy-on-write fashion.

    - Freemap is copy-on-write.
    - Freemap operations are transactional, same as everything else.
    - All backup volume headers are consistent on-mount.

The Freemap is organized using the same radix blockmap algorithm used for
files and directories, but with fixed radix values.  For a maximally-sized
filesystem the Freemap will wind up being a 5-level-deep radix blockmap,
but the top-level is embedded in the volume header so insofar as performance
goes it is really just a 4-level blockmap.

The freemap radix allocation mechanism is also the same, meaning that it is
bottom-up and will not allocate unnecessary intermediate levels for smaller
filesystems.  The number of blockmap levels not including the volume header
for various filesystem sizes is as follows:

	up-to		#of freemap levels
	1GB		1-level
	256GB		2-level
	64TB		3-level
	16PB		4-level
	4EB		5-level
	16EB		6-level

The Freemap has bitmap granularity down to 16KB and a linear iterator that
can linearly allocate space down to 1KB.  Due to fragmentation it is possible
for the linear allocator to become marginalized, but it is relatively easy
to reallocate small blocks every once in a while (like once a year if you
care at all) and once the old data cycles out of the snapshots, or you also
rewrite the snapshots (which you can do), the freemap should wind up
relatively optimal again.  Generally speaking I believe that algorithms can
be developed to make this a non-problem without requiring any media structure
changes.  However, touching all the freemaps will replicate meta-data whereas
the meta-data was mostly shared in the original snapshot.  So this is a
problem that needs solving in HAMMER2.

In order to implement fast snapshots (and writable snapshots for that
matter), HAMMER2 does NOT ref-count allocations.  All the freemap does is
keep track of 100% free blocks plus some extra bits for staging the bulkfree
scan.  The lack of ref-counting makes it possible to:

    - Completely trivialize HAMMER2s snapshot operations.
    - Completely trivialize HAMMER2s de-dup operations.
    - Allows any volume header backup to be used trivially.
    - Allows whole sub-trees to be destroyed without having to scan them.
      Deleting PFSs and snapshots is instant (though space recovery still
      requires two bulkfree scans).
    - Simplifies normal crash recovery operations by not having to reconcile
      a ref-count.
    - Simplifies catastrophic recovery operations for the same reason.

Normal crash recovery is simply a matter of doing an incremental scan
of the topology between the last flushed freemap TID and the last flushed
topology TID.  This usually takes only a few seconds and allows:

    - Freemap flushes to be be deferred for any number of topology flush
      cycles (with some care to ensure that all four volume headers
      remain valid).
    - Does not have to be flushed for fsync, reducing fsync overhead.

```

The format is upstream's, unchanged. The text gives two sizes for the reserved area,
"approximately 4MB for every 2GB" under General Design and "every ~1GB
level-1 zone" here, and upstream's comments split the same way. The code
reserves the first 4 MiB of every 1 GiB: the leaf's reserve is taken from
`H2FMZONEBASE()`, which masks at the level-1 size, though the comment above
it says "each 2GB area" (`hammer2_freemap.c` and `hammer2_disk.h`, the same
in DragonFly's). The volume header copies sit at the start of the first
four 2 GiB zones. This is read from the code and not from an image.

## Freemap: bulkfree

```upstream
				FREEMAP - BULKFREE

Blocks are freed via a bulkfree scan, which is a two-stage meta-data scan.
Blocks are first marked as being possibly free and then finalized in the
second scan.  Live filesystem operations are allowed to run during these
scans and any freemap block that is allocated or adjusted after the first
scan will simply be re-marked as allocated and the second scan will not
transition it to being free.

The cost of not doing ref-count tracking is that HAMMER2 must perform two
bulkfree scans of the meta-data to determine which blocks can actually be
freed.  This can be complicated by the volume header backups and snapshots
which cause the same meta-data topology to be scanned over and over again,
but mitigated somewhat by keeping a cache of higher-level nodes to detect
when we would scan a sub-topology that we have already scanned.  Due to the
copy-on-write nature of the filesystem, such detection is easy to implement.

Part of the ongoing design work is finding ways to reduce the scope of this
meta-data scan so the entire filesystem's meta-data does not need to be
scanned (though in tests with HAMMER1, even full meta-data scans have
turned out to be fairly low cost).  In other words, its an area where
improvements can be made without any media format changes.

Another advantage of operating the freemap like this is that some future
version of HAMMER2 might decide to completely change how the freemap works
and would be able to make the change with relatively low downtime.

```

Carried. Two passes through `HAMMER2IOC_BULKFREE_SCAN` free a removed set,
the first staging and the second freeing (`script/bulkfree.sh`); the scan
is synchronous and answers `CAP_SYS_ADMIN` only.

## Clustering

```upstream
				  CLUSTERING

Clustering, as always, is the most difficult bit but we have some advantages
with HAMMER2 that we did not have with HAMMER1.  First, HAMMER2's media
structures generally follow the kernel's filesystem hierarchy which allows
cluster operations to use topology cache and lock state.  Second,
HAMMER2's writable snapshots make it possible to implement several forms
of multi-master clustering.

The mount device path you specify serves to bootstrap your entry into
the cluster.  This is typically local media.  It can even be a ram-disk
that only contains placemarkers that help HAMMER2 connect to a fully
networked cluster.

With HAMMER2 you mount a directory entry under the super-root.  This entry
will contain a cluster identifier that helps HAMMER2 identify and integrate
with the nodes making up the cluster.  HAMMER2 will automatically integrate
*all* entries under the super-root when you mount one of them.  You have to
mount at least one for HAMMER2 to integrate the block device in the larger
cluster.

For cluster servers every HAMMER2-formatted partition has a "LOCAL" MASTER
which can be mounted in order to make the rest of the elements under the
super-root available to the network.  (In a prior specification I emplaced
the cluster connections in the volume header's configuration space but I no
longer do that).

Connecting to the wider networked cluster involves setting up the /etc/hammer2
directory with appropriate IP addresses and keys.  The user-mode hammer2
service daemon maintains the connections and performs graph operations
via libdmsg.

Node types within the cluster:

    DUMMY	- Used as a local placeholder (typically in ramdisk)
    CACHE	- Used as a local placeholder and cache (typically on a SSD)
    SLAVE	- A SLAVE in the cluster, can source data on quorum agreement.
    MASTER	- A MASTER in the cluster, can source and sink data on quorum
		  agreement.
    SOFT_SLAVE	- A SLAVE in the cluster, can source data locally without
		  quorum agreement (must be directly mounted).
    SOFT_MASTER	- A local MASTER but *not* a MASTER in the cluster.  Can source
		  and sink data locally without quorum agreement, intended to
		  be synchronized with the real MASTERs when connectivity
		  allows.  Operations are not coherent with the real MASTERS
		  even when they are available.

    NOTE: SNAPSHOT, AUTOSNAP, etc represent sub-types, typically under a
	  SLAVE.  A SNAPSHOT or AUTOSNAP is a SLAVE sub-type that is no longer
	  synchronized against current masters.

    NOTE: Any SLAVE or other copy can be turned into its own writable MASTER
	  by giving it a unique cluster id, taking it out of the cluster that
	  originally spawned it.

There are four major protocols:

    Quorum protocol

	This protocol is used between MASTER nodes to vote on operations
	and resolve deadlocks.

	This protocol is used between SOFT_MASTER nodes in a sub-cluster
	to vote on operations, resolve deadlocks, determine what the latest
	transaction id for an element is, and to perform commits.

    Cache sub-protocol

	This is the MESI sub-protocol which runs under the Quorum
	protocol.  This protocol is used to maintain cache state for
	sub-trees to ensure that operations remain cache coherent.

	Depending on administrative rights this protocol may or may
	not allow a leaf node in the cluster to hold a cache element
	indefinitely.  The administrative controller may preemptively
	downgrade a leaf with insufficient administrative rights
	without giving it a chance to synchronize any modified state
	back to the cluster.

    Proxy protocol

	The Quorum and Cache protocols only operate between MASTER
	and SOFT_MASTER nodes.  All other node types must use the
	Proxy protocol to perform similar actions.  This protocol
	differs in that proxy requests are typically sent to just
	one adjacent node and that node then maintains state and
	forwards the request or performs the required operation.
	When the link is lost to the proxy, the proxy automatically
	forwards a deletion of the state to the other nodes based on
	what it has recorded.

	If a leaf has insufficient administrative rights it may not
	be allowed to actually initiate a quorum operation and may only
	be allowed to maintain partial MESI cache state or perhaps none
	at all (since cache state can block other machines in the
	cluster).  Instead a leaf with insufficient rights will have to
	make due with a preemptive loss of cache state and any allowed
	modifying operations will have to be forwarded to the proxy which
	continues forwarding it until a node with sufficient administrative
	rights is encountered.

	To reduce issues and give the cluster more breath, sub-clusters
	made up of SOFT_MASTERs can be formed in order to provide full
	cache coherent within a subset of machines and yet still tie them
	into a greater cluster that they normally would not have such
	access to.  This effectively makes it possible to create a two
	or three-tier fan-out of groups of machines which are cache-coherent
	within the group, but perhaps not between groups, and use other
	means to synchronize between the groups.

    Media protocol

	This is basically the physical media protocol.

```

A mount integrates every PFS root under its device's super-root, as here
described, so a cluster forms when a second PFS with the first's cluster
id is mounted from another volume; `script/cluster-sync.sh` and
`script/cluster-quorum.sh` build it that way. There is no Linux service
daemon and no `/etc/hammer2`: the kernel's intake is `HAMMER2IOC_RECLUSTER`
and the `cluster_fd=` mount option, handed a connected stream socket, and
`test/h2service.c` is the test harness's stand-in for the daemon. A
synchronization thread starts for every element that is not a lone
MASTER.

Of the four protocols: the quorum protocol is the local one
`hammer2_cluster_check()` runs, with the cross-host commit P8's; the cache
sub-protocol is not built (`doc/CCMS_DESIGN.md`); the proxy protocol is
not built, and the relay `test/h2loop.c` places between two guests is a
test instrument, not a proxy; and the media protocol between hosts is the
port's chain-level protocol, the XOP descriptors carried as commands in
the message core's reserved space (`doc/CLUSTER_PROTOCOL_DESIGN.md`, "The
wire format"), in place of DragonFly's network block device.

## Master and slave synchronization

```upstream
		       MASTER & SLAVE SYNCHRONIZATION

With HAMMER2 I really want to be hard-nosed about the consistency of the
filesystem, including the consistency of SLAVEs (snapshots, etc).  In order
to guarantee consistency we take advantage of the copy-on-write nature of
the filesystem by forking consistent nodes and using the forked copy as the
source for synchronization.

Similarly, the target for synchronization is not updated on the fly but instead
is also forked and the forked copy is updated.  When synchronization is
complete, forked sources can be thrown away and forked copies can replace
the original synchronization target.

This may seem complex, but 'forking a copy' is actually a virtually free
operation.  The top-level inode (under the super-root), on-media, is simply
copied to a new inode and poof, we have an unchanging snapshot to work with.

	- Making a snapshot is fast... almost instantanious.

	- Snapshots are used for various purposes, including synchronization
	  of out-of-date nodes.

	- A snapshot can be converted into a MASTER or some other PFS type.

	- A snapshot can be forked off from its parent cluster entirely and
	  turned into its own writable filesystem, either as a single MASTER
	  or this can be done across the cluster by forking a quorum+ of
	  existing MASTERs and transferring them all to a new cluster id.

More complex is reintegrating the target once the synchronization is complete.
For SLAVEs we just delete the old SLAVE and rename the copy to the same name.
However, if the SLAVE is mounted and not optioned as a static mount (that is
the mounter wants to see updates as they are synchronized), a reconciliation
must occur on the live mount to clean up the vnode, inode, and chain caches
and shift any remaining vnodes over to the updated copy.

	- A mounted SLAVE can track updates made to the SLAVE but the
	  actual mechanism is that the SLAVE PFS is replaced with an
	  updated copy, typically every 30-60 seconds.

Reintegrating a MASTER which has fallen out of the quorum due to being out
of date is also somewhat more complex.  The same updating mechanic is used,
we actually have to throw the 'old' MASTER away once the new one has been
updated.  However if the cluster is undergoing heavy modifications the
updated MASTER will be out of date almost the instant its source is
snapshotted.  Reintegrating a MASTER thus requires a somewhat more complex
interaction.

	- If a MASTER is really out of date we can run one or more
	  synchronization passes concurrent with modifying operations.
	  The quorum can remain live.

	- A final synchronization pass is required with quorum operations
	  blocked to reintegrate the now up-to-date MASTER into the cluster.


```

The fork of the source is built: each pass reads a snapshot of the
master's element, taken by the master when it is on another host. The
target is not forked and swapped: the slave is written in place, with a
snapshot of it kept as the last known-good copy until a pass verifies,
and the fork-and-swap of a live target is deferred until a consumer reads
a slave element directly (`doc/SYNC_DESIGN.md`, "What the implementation
decided"). Bringing back a MASTER that fell out of the quorum is P9.

## Quorum operations

```upstream
				QUORUM OPERATIONS

Quorum operations can be broken down into HARD BLOCK operations and NETWORK
operations.  If your MASTERs are all local mounts, then failures and
sequencing is easy to deal with.

Quorum operations on a networked cluster are more complex.  The problems:

    - Masters cannot rely on clients to moderate quorum transactions.
      Apart from the reliance being unsafe, the client could also
      lose contact with one or more masters during the transaction and
      leave one or more masters out-of-sync without the master(s) knowing
      they are out of sync.

    - When many clients are present, we do not want a flakey network
      link from one to cause one or more masters to go out of
      synchronization and potentially stall the whole works.

    - Normal hammer2 mounts allow a virtually unlimited number of modifying
      transactions between actual flushes.  The media flush rolls everything
      up into a single transaction id per flush.  Detection of 'missing'
      transactions in a concurrent multi-client setup when one or more client
      temporarily loses connectivity is thus difficult.

    - Clients have a limited amount of time to reconnect to a cluster after
      a network disconnect before their MESI cache states are lost.

    - Clients may proceed with several transactions before knowing for sure
      that earlier transactions were completely successful.  Performance is
      important, we won't be waiting for a full quorum-verified synchronous
      flush to media before allowing a system call to return.

    - Masters can decide that a client's MESI cache states were lost (i.e.
      that the transaction was too slow) as well.

The solutions (for modifying transactions):

    - Masters handle quorum confirmation amongst themselves and do not rely
      on the client for that purpose.

    - A client can connect to one or more masters regardless of the size of
      the quorum and can submit modifying operations to a single master if
      desired.  The master will take care of the rest.

      A client must still validate the quorum (and obtain MESI cache states)
      when doing read-only operations in order to present the correct data
      to the user process for the VOP.

    - Masters will run a 2-phase commit amongst themselves, often concurrent
      with other non-conflicting transactions, and will serialize operations
      and/or enforce synchronization points for 2-phase completion on
      serialized transactions from the same client or when cache state
      ownership is shifted from one client to another.

    - Clients will usually allow operations to run asynchronously and return
      from system calls more or less ASAP once they own the necessary cache
      coherency locks.  The client can select the validation mode to wait for
      with mount options:

      (1) Fully async		(mount -o async)
      (2) Wait for phase-1 ack	(mount)
      (3) Wait for phase-2 ack	(mount -o sync)		(fsync - wait p2ack)
      (4) Wait for flush	(mount -o sync)		(fsync - wait flush)

      Modifying system calls cannot be told to wait for a full media
      flush, as full media flushes are prohibitively expensive.  You
      still have to fsync().

      The fsync wait mode for network links can be selected, either to
      return after the phase-2 ack or to return after the media flush.
      The default is to wait for the phase-2 ack, which at least guarantees
      that a network failure after that point will not disrupt operations
      issued before the fsync.

    - Clients must adjust the chain state for modifying operations prior to
      releasing chain locks / returning from the system call, even if the
      masters have not finished the transaction.  A late failure by the
      cluster will result in desynchronized state which requires erroring
      out the whole filesystem or resynchronizing somehow.

    - Clients can opt to keep a record of transactions through the phase-2
      ack or the actual media flush on the masters.

      However, replaying/revalidating the log cannot necessarily guarantee
      success.  If the masters lose synchronization due to network issues
      between masters (or if the client was mounted fully-async), or if enough
      masters crash simultaniously such that a quorum fails to flush even
      after the phase-2 ack, then it is possible that by the time a client
      is able to replay/revalidate, some other client has squeeded in and
      committed something that would conflict.

      If the client crashes it works similarly to a crash with a local storage
      mount... many dirty buffers might be lost.  And the same happens in
      the cluster case.

```

Not built across hosts. `doc/CLUSTER_PROTOCOL_DESIGN.md` records the
constraints the carried core puts on a cross-host commit and four
decisions: who coordinates prepare and commit, presented open in
`doc/README.roadmap.md`, with one writer per PFS under a durable lease as
where its own protocol note starts; the
membership from the volume header's `copyinfo[]` rows; `ENOTCONN` for a
read no quorum can answer; and the phase-2 acknowledgment alone, so none
of the four mount modes listed here exists. Until the lease, a PFS with a
master on another host is mounted read-only.

## Transaction log

```upstream
				TRANSACTION LOG

Keeping a short-term transaction log, much less being able to properly replay
it, is fraught with difficulty and I've made it a separate development task.
For now HAMMER2 does not have one.

```

None, in either tree; P9.
