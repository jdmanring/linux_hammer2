# Remote synchronization: what the design defines, what the tree carries, and what reaching a master on another host has to prove

The P7 design note. The completion plan's row reads "remote
synchronization from an immutable source snapshot into a forked target,
replaced only once verified", and the plan's rules say a decision that
would change the media format, the security model or distributed commit
semantics stops at a design note with alternatives and what each would
have to prove. P7 touches two of the three: a master on another host puts
a network peer behind the synchronization thread, and the immutable source
the row asks for is a snapshot the format already defines but the code does
not treat as one. This document is that stop for the remote reach. The
local half of the fork, verify and replace protocol has since been built
on two devices of one host, behind the `sync_snapshot` module parameter,
and the section "What the implementation decided" below records the
decisions the code took; the rest of the note fixes what the original
design specifies, what the wire protocol actually defines, what the port
carried before that half, and what each way of reaching a master on
another host would have to prove before it is
written.

Read against the DragonFly clone at `250a8b4`, with `sys/dev/disk/xdisk`,
`sbin/hammer2` and `lib/libdmsg` added to its sparse checkout for this
reading, Dillon's 2015 design document in
`doc/research/primary/DILLON_HAMMER2_DESIGN_2015.md`, the handoff's work
package and state model under `proposals/hammer2-completion-handoff/`, and
this tree at `5078090`, on 2026-10-17. The line citations in the
sections from here to "What the implementation decided" are those of that
reading, and `script/test-citations.sh` checks them against that tree
rather than against the tree as it moves; sentences added to those
sections later carry their own dates and cite no line. Four of the
findings have since changed: the wire protocol carries HAMMER2 commands
(`DMSG_HM2_XOP`, `DMSG_HM2_FEED`, `DMSG_HM2_SNAPSHOT`;
`doc/CLUSTER_PROTOCOL_DESIGN.md`), the thread scans a snapshot of its
source, the snapshot copies the blockset of the element the thread names
rather than element 0's, and `hammer2_remote_snapshot_take()` reads
`pfs_subtype` to check the snapshot a peer took for it.

<!-- citations at 5078090 -->
## The findings that make this note necessary

Three readings, each of which changes what "remote synchronization" can
mean here.

**The original protocol for remote PFS access was never written.** The
wire protocol reserves seven protocol spaces (`src/sys/sys/dmsg.h:302-308`)
and defines commands in four. The link layer has `PAD`, `PING`, `AUTH`,
`CONN`, `SPAN` and `ERROR` (`:372-377`) plus HAMMER2's `VOLCONF` (`:383`).
The debug layer has `DBG_SHELL` (`:543`), which the kernel answers with
`DMSG_ERR_NOSUPP`. The block-device layer has `OPEN`, `CLOSE`, `READ`,
`WRITE`, `FLUSH`, `FREEBLKS` and `ERROR` (`:594-600`). The HAMMER2 layer
has one command, `DMSG_HM2_OPENPFS` (`:570`), and the four the comment
above it names,
`HM2_DUPLICATE`, `HM2_DELDUP`, `HM2_DELETE` and `HM2_SNAPSHOT`, are defined
nowhere; the `VOP` layer has its macro (`:338`) and no command. Dillon's
2015 roadmap puts this in order: error handling, then "synchronization to
out-of-sync masters and slaves (w/local storage)", then "multi-master with
local storage", and "once I have it working well with local storage I will
start on the higher-level network protocols which themselves are quite
complex" (design document lines 24-30). Upstream HEAD is where that
sentence left it. The plan's rule that the original protocol is reproduced
before a replacement is weighed is therefore satisfiable for exactly one
remote protocol, the block device, and for none of the chain-level
operations a synchronization pass performs.

**The synchronization thread synchronizes live to live.** Dillon's design
is explicit that the source is forked and read from the fork, and that
the target is forked, updated, verified and swapped in (design document
lines 628-662). `hammer2_synchro.c`, carried since 0.9.61 and hardened
by P4, 1749 lines here to upstream's 1069 with 66 `XXX Linux` marks,
keeps upstream's scan, source and target and does neither:
`hammer2_primary_sync_thread()`
(`src/sys/fs/hammer2/hammer2_synchro.c:257`) scans from `pmp->iroot` at
`:343`, and `hammer2_sync_slaves()` (`:580`) takes its source from the
cluster's focus, `xop2->head.cluster.focus` at `:649`, which is the chain
the quorum code selected among the live MASTER elements, and writes into
the live element at `thr->clindex`. The 2015 status table lists
"Synchronization - under development" (line 77), and the roadmap's
2026-10-03 reading of the forge, in its section past 1.0, found no
functional commit to the four cluster files since 2018. So the fork, the
verify and the replace are not an original to reproduce; they are a
design to implement from the document's sentences, and the thread as
carried is the
increment inside them.

**A snapshot leaves its cluster.** The media defines a snapshot as a PFS
root with `pfs_subtype` `HAMMER2_PFSSUBTYPE_SNAPSHOT`
(`src/sys/fs/hammer2/hammer2_disk.h:918`, `:1066`), which is the design
document's "SLAVE sub-type that is no longer synchronized against current
masters" (lines 561-563). `hammer2_ioctl_pfs_snapshot()`
(`src/sys/fs/hammer2/hammer2_ioctl.c:493`) sets that subtype on a root of
type MASTER (`:580-581`) and gives it a fresh `pfs_fsid` and a fresh
`pfs_clid` (`:586-587`). The comment above it says the same cluster id is
used "when snapshotting a PFS root, which theoretically allows the snapshot
to be used as part of the same cluster" (`:544-547`); the code below the
comment does not do that, in this tree or upstream, where the branch that
would is under `#if 0` with the sentence "As a snapshot no further
synchronization with the original cluster will be done." The cluster is
assembled by `pfs_clid` (`src/sys/fs/hammer2/hammer2_vfsops.c:313-314`),
so a snapshot is not an element of the cluster it was taken from, and no
line of the assembly, the thread, the cluster code or the admin code reads
`pfs_subtype` (`command grep` over `src/`, 2026-10-17: the field appears
in `hammer2_disk.h` and `hammer2_ioctl.h` as a definition, and in
`hammer2_ioctl.c` on five lines that report it, bound it and set it). The
thread's XOPs address `pmp->iroot->cluster`, so the thread as carried
cannot read a snapshot at all. "An immutable source snapshot" is therefore
not a configuration of what exists; it needs either a snapshot that stays
in its cluster, which changes what a shared `pfs_clid` means on media, or a
thread that reads a tree outside its cluster. The snapshot also copies one
element's blockset, `pfs_iroot_blocksets[0]` at `:594`, under upstream's
own `/* XXX doesn't work with real cluster */` (`:591`).

## What the original defines

### Node types and the four protocols

A cluster is the set of PFS roots sharing a `pfs_clid`, wherever their
media is (design document lines 525-533): mounting any one of them
integrates every entry under that media's super-root, and "ALL CLUSTER
ELEMENTS ARE TREATED ACCORDING TO TYPE NO MATTER WHICH ONE YOU MOUNT". The
types are DUMMY, CACHE, SLAVE, MASTER, SOFT_SLAVE and SOFT_MASTER (lines
546-559), with SNAPSHOT and AUTOSNAP as SLAVE sub-types, and any copy can
become its own MASTER by taking a new cluster id (lines 561-567). The four
protocols are the quorum protocol between MASTERs, the cache sub-protocol
under it, the proxy protocol by which every other type reaches a MASTER
through one adjacent node, and the media protocol (lines 569-626). The
document also says the cluster connections used to live "in the volume
header's configuration space" and no longer do (lines 537-539); the
`copyinfo[]` array of 256 `hammer2_volconf` entries is still in the volume
header (`hammer2_disk.h:1223`, the structure at `:506-519`) and
`hammer2_iocom.c` still sends each enabled entry as a `VOLCONF` message on
`LNK_CONN`, so the format kept the field the document retired.

### Synchronization

Lines 628-681 of the document. Consistency is guaranteed by forking: the
source is forked and the fork is read; the target is forked and the fork
is updated; when synchronization is complete the forked source is thrown
away and the forked target replaces the original. A fork is a copy of the
PFS root inode under the super-root, "virtually free". For a SLAVE the
replacement is a delete and a rename, unless the SLAVE is mounted and not
optioned as a static mount, in which case "a reconciliation must occur on
the live mount to clean up the vnode, inode, and chain caches and shift
any remaining vnodes over to the updated copy", typically every 30 to 60
seconds. A MASTER that fell out of the quorum is synchronized by the same
mechanic, with passes concurrent with modifying operations and a final
pass with quorum operations blocked. Synchronization is logical and
incremental, driven by `modify_tid` (lines 327-348): a sub-tree whose root
`modify_tid` matches is skipped, an out-of-sync node is updated bottom-up,
the pass can be interrupted and restarted at any time, and media flushes
can and must occur while it runs. The carried thread has every one of
those four properties on local elements; `cluster-sync.sh` measured them.

### The network block device

The one remote protocol that exists. On the exporting host,
`sys/kern/subr_diskiocom.c` (669 lines) answers `DIOCRECLUSTER` on a disk
device (`:116`, routed from `sys/kern/subr_disk.c:1191`) by running a
`kdmsg` iocom on the descriptor it is handed, advertising the disk as a
`LNK_SPAN` and serving `BLK_OPEN`, `BLK_READ`, `BLK_WRITE`, `BLK_FLUSH` and
`BLK_FREEBLKS` against it. On the importing host, `sys/dev/disk/xdisk/xdisk.c`
(1347 lines) is a control device whose `XDISKIOCATTACH` (`:271`) takes a
descriptor, watches the `LNK_SPAN`s that arrive on it (`:401`), creates a
`/dev/xa%d` disk for each remote device (`disk_create` at `:473`), and
issues each `BLK_OPEN` under the best span it holds (`:1307-1327`). The
`hammer2 service` daemon (`sbin/hammer2/cmd_service.c`, 1074 lines) ties
the two together: it is a UDP discovery protocol, a TCP rendezvous that
authenticates against `/etc/hammer2/remote/<label>.pub`, and a spanning
tree of relayed links (`:108-147`); it hands one pipe end to `/dev/xdisk`
(`xdisk_connect()` at `:948`) and one to each mounted HAMMER2 through
`HAMMER2IOC_RECLUSTER` (`:246-251`, `master_reconnect()` at `:803`). Its
head comment says what it is not: "This daemon does not run the higher
level quorum or locking protocols." Encryption and authentication of a
link are the library's, `lib/libdmsg/crypto.c` (777 lines, AES-256-GCM),
and nothing in the kernel checks a frame beyond its magic, header size and
aux bound; the CRCs are verified in `lib/libdmsg/msg.c` alone. The port
kept that until stage 1 of `doc/CLUSTER_PROTOCOL_DESIGN.md`, 1.0.44: on
a connection whose peer announced `DMSG_SPAN_PROTO_2` the kernel
verifies both CRCs, and on any other it checks what upstream checks
(`doc/README.porting.md`, the transport section).

So the original design reaches a master on another host by making its
media a local disk, and the cluster code never knows the element is
remote. The 2015 status table lists "Network blk device - operational"
(line 74).

## What the port carries today

- `hammer2_synchro.c` since 0.9.61, hardened by P4: the thread starts for
  every element that is not a lone MASTER (`hammer2_vfsops.c:468-490`),
  passes every five seconds or on wakeup, and converges a SLAVE on a
  second local device with the master changed under it, interrupted,
  with allocations refused in its insert, replace and destroy arms
  (`H2_FAULT`, `H2_FAULT2`), 22 checks 0 failed on the debug and KASAN
  kernels by `script/cluster-sync.sh` as the roadmap's P4 row records it,
  the record also holding readings at 23 after a check was added;
  `doc/history/verification-record.md` holds the P4 entries.
- The two-MASTER local shape, `hammer2_cluster_check()` deciding between
  two elements that agree, 22 checks 0 failed by `script/cluster-quorum.sh`.
  A quorum that cannot be met is unrun; that is P8's.
- The message core and its intake since 1.0.33, P6: `kern_dmsg.c`,
  `hammer2_iocom.c`, `hammer2_msgops.c` and `sys/sys/dmsg.h`, behind
  `HAMMER2IOC_RECLUSTER` and `cluster_fd=`; a connected stream socket only,
  because the kernel's own teardown is `kernel_sock_shutdown()`; the kernel
  initiates `LNK_CONN`, advertises one `LNK_SPAN` per PFS, sends the
  `VOLCONF`s, answers `PING`, and runs DragonFly's two message threads;
  32 checks 0 failed on both kernels by `script/cluster-dmsg.sh` against
  `test/h2attach.c`, which plays the daemon's end, 55 since 1.0.44
  added the stage 1 checks of `doc/CLUSTER_PROTOCOL_DESIGN.md`, and 79
  since its stage 2a added the HM2 XOP API's read side.
- The snapshot ioctl, with the identity described above, and the PFS
  ioctls that create, list and delete roots, exercised by `pfs-domains.sh`
  on both sides.
- Multi-volume mounts, one filesystem spanning up to `HAMMER2_MAX_VOLUMES`
  (64, `hammer2_disk.h:1116`) devices; this is one `hammer2_dev` over
  several devices, not several elements.

What it did not carry when this note was written: any way for an
element of a cluster to live on another host, carried since 1.0.46 as
the remote element of `doc/CLUSTER_PROTOCOL_DESIGN.md`; and a verify
step, carried since 1.0.40 (the decisions below), whose per-pass
snapshot of the master is the fork of the source. What it did not carry
on 2026-10-27: a Linux `hammer2 service`, or any userland that holds the
other end of the socket in production (`doc/README.porting.md` records that
none exists; `test/h2service.c` is the harness's); the block-device
protocol's client or server; a fork of the target, which is written in
place with a snapshot kept until a pass verifies; a replacement of a
target; and any
authentication or encryption in the kernel path, which on DragonFly are the daemon's and the library's, as
the CRC check was until 1.0.44 verified it for a `PROTO_2` peer.

## What "remote synchronization" has to decide

### 1. Where the remote master's bytes come from

Three answers are possible, and they are not interchangeable.

Block-level: the master's media appears on the slave's host as a block
device, and the cluster code sees a local element. This is the original's
own answer and the only one with a written protocol. On Linux it is
either the `BLK` client as a block driver, or a userland bridge from `BLK`
to the kernel's native network block device, `drivers/block/nbd.c` (2806
lines in the kernel of record; `CONFIG_BLK_DEV_NBD` is not set in the
guest kernels' configuration), or the native device alone with no `BLK`.

Chain-level: a protocol in the `HM2` or `VOP` space that answers a
lookup, a read and the chain operations the thread's arms perform. This is
what the document calls the higher-level network protocols and what
nobody wrote; it is an extension by the plan's own rule, since it is a new
wire protocol with a versioning obligation.

Logical, in userland: a sender on the master's host reads a snapshot and
a receiver on the slave's host writes through the frontend. That is P16,
snapshot send and receive, which the plan orders after P9 and P10; taking
it here inverts the dependency order the plan was written in.

### 2. What makes the source immutable

A snapshot on the master's host holds its blocks: the freemap does not
release a block a live snapshot references, so a reader of the snapshot's
tree reads one consistent state however long the pass takes. That is the
document's answer and the state model's S10. The alternative, pinning the
master's volume header and reading its live tree, is not immutable: a
block the master frees is reusable after a bulkfree pass, and a reader
holding the older root would read reused blocks under old blockrefs; the
check codes catch most of that and promise nothing. So the source is a
snapshot, and finding three above is the obstacle: a snapshot has its own
`pfs_clid` and the thread cannot address it.

Two ways through. Keep the snapshot in its cluster, as upstream's `#if 0`
branch once did, and teach the assembly and the thread that a MASTER-typed
root with `pfs_subtype` SNAPSHOT is a source and never a target and never
a vote: that changes what a shared `pfs_clid` means on media, so by the
plan's first rule it is an extension with a written design, and the
compatibility question is sharp, since every reader that exists today,
DragonFly and the three BSD ports, would mount such a snapshot as a second
MASTER element and count it toward `pfs_nmasters`
(`hammer2_vfsops.c:439-449` here, the same logic upstream). Or leave the
snapshot's identity alone and give the thread a source that is not the
focus: the snapshot is a PFS root under the super-root of the same
`hammer2_dev` as the master element, reachable by name through the
super-root the way the mount reaches any root, and `hammer2_sync_slaves()`
would take that chain where it takes `xop2->head.cluster.focus`. That
changes no media meaning, touches the carried file in one place the arms
already parameterize on, and leaves the quorum code untouched.

### 3. How the target is forked and replaced

The document forks the target too, so a failed pass leaves the last
known-good target intact, and replaces it by delete and rename when the
pass is verified. For an unmounted SLAVE, or one mounted static, that is
a super-root operation the PFS ioctls already perform. For a SLAVE mounted
live, the document requires the cache reconciliation, and the handoff says
not to treat it as a rename in the VFS. On Linux that is the dentry and
inode cache of the mount: every open file and cached dentry holds the old
root's chains, and the swap has to move them or invalidate them. Nothing
in any tree does this; it is the hardest part of the work package and the
part the exit criteria do not name.

### 4. Who authenticates the link

On DragonFly, the daemon and the library: keys under `/etc/hammer2`,
AES-256-GCM on the link, CRCs checked in userland. The kernel trusts the
descriptor it is handed. The port keeps that boundary for the peer's
identity: a connected socket arrives from whoever can issue the mount's
ioctl or the mount option, and the kernel verifies nothing about who the
peer is, though since 1.0.44 it verifies the frames of a peer that
announced `DMSG_SPAN_PROTO_2`, and since 1.0.46 it registers a remote
master only against an enabled `copyinfo[]` row with its cluster id.
Any alternative that puts a master on another host inherits this: the
remote end's identity is established outside the kernel, on 2026-10-27
by the harness's `test/h2service.c` from a marker file, and by `tlshd` once
the link runs over kernel TLS. A
design that reaches another host must say who holds the keys and where the
frames are checked before the first byte of a remote master's tree is
written into a local slave.

## Alternatives, and what each would have to prove

### A. The master's media as a local block device

Reproduces the original's network block device. The cluster code and the
thread are untouched; the element is local as far as either knows. It
would have to prove four things. That the slave's host mounts the remote
device without writing to it: a HAMMER2 mount writes volume headers on
flush and the freemap on bulkfree, and two writers of one volume header is
corruption, so a read-only element is a new mode of `hammer2_dev`, not a
mount flag, and every write path has to be shown closed. That the slave's
host sees the master's new roots: a `hammer2_dev` reads its volume header
at mount, so a read-only remote element would synchronize once and never
again unless the thread re-reads the remote volume header each pass, which
is new code in the thread or the device layer, and the page cache of the
block device has to be dropped or bypassed for it. That the source is
still immutable: it is not, by decision two, unless the master's host
takes a snapshot the slave's host can find, which brings finding three
back in full. And that the device layer is authenticated: the original
daemon does this; on Linux the native network block device has TLS in its
userland server and none in the kernel client, and a carried `BLK` client
would have neither. The cost is the smaller of the remote alternatives in
kernel code and the largest in new semantics, and it buys a one-shot
synchronization until the second obligation is met.

### B. A chain-level protocol in the reserved space

Defines the `HM2` or `VOP` commands the thread's arms need: a lookup by
key range, a read of a chain's data, and the three arms' operations, or
the source-side half of them only, with the writes staying local. It is
the document's "higher-level network protocols" and it is new design. It
would have to prove a wire format with a version and a compatibility
plan, which the plan's first rule asks of any extension; frame checking in
the kernel, since the kernel would act on these frames and today checks no
CRC; a flow-control story for a scan of a million-file tree over a stream
whose `aux` bound is 1 MiB; and the same authentication as A. It is the
right shape for the quorum protocol of P8, which also needs a peer that
answers chain-level questions, so its design should be weighed with P8's
rather than for P7 alone.

### C. Logical send and receive in userland

A sender reads the snapshot on the master's host and a receiver writes
through the frontend on the slave's host, over any transport userland
likes, authenticated by whatever that transport provides. It needs no
kernel protocol and no cluster element on another host. It is P16 in the
plan, after P9 and P10, and taking it as P7's answer would need the plan's
order rewritten with a reason; the reason the order exists is that the
distributed state machine is to be correct before anything leans on it,
and a userland copy leans on nothing, so the conflict is one of
sequencing rather than safety. What it would have to prove is that a
receiver writing through the frontend produces a slave the thread's
`modify_tid` comparison accepts as synchronized, since otherwise the next
local pass redoes the copy.

### D. Local first, as the original's own roadmap did

Build the fork, verify and replace protocol on two local devices, where
`cluster-sync.sh` already drives the thread and `fsck_hammer2` already
reads the result, and reach another host afterwards by A, B or C on
measurements. This is the order Dillon set for himself in 2015 and the
order the handoff's own section 27 argues for. Four of the work queue's
five exit criteria for P7 are measurable this way: initial convergence,
incremental convergence, interrupted resume and crash recovery are
properties of the pass and the fork, not of the wire, and
`snapshot_source` is the fifth and is local by decision two. What D has to
prove: that a source read from a snapshot rather than the focus converges
the slave to the snapshot's state and leaves the master's live writes
alone, read by `fsck_hammer2` and the fingerprint `cluster-sync.sh` already
takes; that a pass into a forked target leaves the original target intact
when the pass is killed at every arm, with the fault knobs P4 built; that
the replacement of an unmounted target is atomic on media, read by a
crash between the delete and the rename; and that a snapshot source and a
forked target cost what the document says they cost, an inode copy each,
measured against the live-to-live pass. The live-mount handoff of decision
three is the part D does not prove and says so.

The recommendation: D, with the second route of decision two for the
source, the fork and replace on an unmounted or static target first, and
the live handoff written as its own design question with the dentry and
inode cache named; then B weighed together with P8's protocol rather
than A, because A's second and third obligations lead back to the same
snapshot and the same protocol question, and A's read-only device mode
is new semantics the original never had either.

The remote reach stopped at this note under the plan's rules, since each
of A, B and C is a decision they reserve: A changes what a mount does
with a device another host writes, B is a new wire protocol and so an
extension under the first rule, and either puts a trust boundary in the
kernel that no Linux daemon holds yet, which is the security model the
third rule names. The local half of D meets none of those rules, changing
no media meaning, no trust boundary and no commit semantics, and was
built first.

**Ruling, 2026-10-19: B.** A chain-level protocol in the reserved space,
designed together with P8's quorum protocol as one wire format and one
design note, with the daemon that holds the keys specified in that note
before any kernel code. A was refused because its obligations lead back
to the snapshot and to the protocol question B answers directly, and it
adds a read-only device mode the original never had, so it would follow
the network block device only to add work. C was refused because it is
P16 arriving early: a userland copy leans on nothing in the distributed
state machine the plan exists to get right, and it would have stopped
the local half's target-side work.

## The compatibility and versioning position

Nothing in D changes what any byte on the media means: a snapshot keeps
its private `pfs_clid` and its SNAPSHOT subtype, a forked target is a
snapshot of the slave, and a replacement is the delete and rename the PFS
ioctls already perform, so DragonFly and the three BSD ports read a volume
that went through a pass exactly as they read one that did not. The first
route of decision two, a snapshot sharing its cluster's id, is the one
change on this page that would need the extension rule, and it is not
taken. B is a protocol extension and would carry a version in its frames
from the first one; the `dmsg` header has the room. A changes no media
and no protocol and changes the mount's semantics instead.
<!-- citations end -->

## What the implementation decided (2026-10-18)

The local half of the fork, verify and replace protocol is built on two
devices, behind the `sync_snapshot` module parameter, and these are the
decisions the code took where this note left a choice or where the
trace of the carried code closed one. The remote reach was ruled B on
2026-10-19; the ruling follows the alternatives above.

**The source is a per-pass snapshot of the master element, addressed by
chain.** The thread snapshots the element the root's quorum focus names
into `<name>.h2sync-src` under the super-root of that element's device,
reads it through the carried `ipcluster` and `scanall` XOPs over an inode
of the snapshot PFS, and deletes it after the pass. The snapshot keeps
its private `pfs_clid` and SNAPSHOT subtype; no media meaning changes.
The first form held a chain cursor locked across the arms and failed in
its first run on the lock classes, which carry a chain's type and level
and not its tree. The slave side is found by inode number under this
element, since the snapshot's inode holds no element of the cluster.

**The target is written in place, and a snapshot of it taken before the
first pass after a verified one is the last known-good copy.**
`<name>.h2sync-tgt` on the slave's own device, deleted when a pass
verifies, kept across a failed or interrupted pass, a crash and an
unmount, and found by name on the next mount; the thread runs the PFS
sync once more after taking it, since the snapshot helper's own flush
stops at the new inode and a cut before the next volume header would
leave the blocks of a target and no name. This meets the handoff's
"a failed transfer does not destroy the last known-good destination"
with the primitives the port has. The fork-and-swap of a live target
this note describes is not built: no tree can swap a cluster element's
root under a live mount (`hammer2_pfsalloc` appends, `hammer2_pfsdealloc`
leaves a hole, the inode cache has no repoint walk, there is no PFS
rename), and the reader-visible property it protects has no reader here.
A lone SLAVE label is refused at mount with ENOENT at the root inode,
beside a control mount of the same device's ROOT label that succeeds;
the cluster mount serves reads from the master, and `hammer2_cluster_check()`
serves a slave only when its root tid agrees with the quorum. `DEFER(a
consumer that reads a slave element directly, a static mount or a
standalone slave mount)`, the marker standing in `hammer2_synchro.c`
above the pass driver and in the ledger of `doc/README.status.md`.

**Verify is the pass re-run against the same snapshot at the root
level.** A pass that acted is run again with the root pushed onto the
thread's rescan set, so the tid gate cannot pass it, until a round acts
on nothing or three have run; a pass whose last round acted on nothing
and failed nothing is verified. A round that keeps a key as newer than
the snapshot ends the rounds with the verdict `newer`: the frontend
wrote the slave element after the snapshot was taken, and the next
snapshot holds what the slave holds. A re-run that compared every inode
would have deferred and re-stamped the whole slave tree per round; the
root-level compare by tid is what the rescan set already makes sound.

**The idle test is the master root's flushed blockset and copied
fields, not its tid.** The flush rewrites `pfs_iroot_blocksets[m]` for
any change it writes back under the root and nothing else does; the
fourteen root fields the PFSROOT arm copies are compared beside it, from
the snapshot that last verified, which carries the source root's fields
rather than a new PFS's defaults. The root's own `modify_tid` moves with
every snapshot's `pfs_lsnap_tid` write. An idle master whose root tid
still differs from the slave's gets the carried live pass once: its
root scan is one level by tid and its PFSROOT arm stamps the slave root
with the live tid. Measured over the eighteen kept klogs of the step
that carry an idle stamp, on the rc5 and 7.3 debug and KASAN kernels:
one such pass per burst in every one, the two root tids equal on the idle line after it, and an
idle pass costing no snapshot. The stamp's one-level scan is the cost
of an idle master after a change: 0.4 s at most on the debug kernel,
9.3 s over 20107 root entries on the KASAN kernel.

**Sync inside the snapshot is the PFS flush, not `hammer2_sync()`.**
`hammer2_sync()` takes `s_umount` for read, which an unmount holds for
write while it waits for the thread; the thread's snapshot flushes
through `hammer2_vfs_sync_pmp()`, which also lets the pass run on a
cluster whose devices are mounted and whose cluster is not. The
snapshot's own flush is what rewrites the master's blockset before the
copy, and the thread's pass-end flush writes the slave element alone.

**Two masters: no quorum, no snapshot pass.** The source element is the
one the root `ipcluster` focus names; without one the live pass runs
and copies nothing. The snapshot covers that element only, which is what
a snapshot is in both trees. Two-master convergence stays
`cluster-quorum.sh`'s and P8's. A thread's own flush of an element
root (`hammer2_sync_flush()`, unconditional each pass) does not refresh
that element's blockset slot, which the idle test compares and the
snapshot copies. On two local masters no pass reaches either: each
thread's collect excludes its own element, the other alone cannot make
a quorum of two, and `cluster-quorum.sh` with `H2_QUORUM_IDLE=40` read
19 passes, every one `noquorum` (18 with `EINPROGRESS`, the last with
`ENOTCONN` at the unmount), and no idle test (1.0.62). With a third
local element, a slave beside two masters or a third master, a thread
makes its quorum from masters other than its own element and reads a
slot whose master's thread may have flushed a frontend change past it,
so the stale slot is reachable there; it is a `candidate`, argued from
the code and unread, in the verification record's entry for 1.0.62.

**The frontend writes the slave element too.** A frontend write on the
mounted cluster lands on both elements at once, so a pass whose snapshot
predates one meets its own staleness: a key the frontend wrote is kept
as newer and the pass waits for the next snapshot; a key the frontend
deleted is absent on the slave and present in the snapshot, and the
insert arm has nothing to compare. That last case is closed one level
up (`6d43038`): an inode whose slave chain is newer than the snapshot's
is skipped whole and put on the rescan set, so a directory the frontend
changed after the snapshot is neither scanned nor refilled, and the
insert arm of `hammer2_sync_slaves()` counts the residue as
`syncsnap: reinsert` lines, which the harness reads as `reinserts`, 0
wanted: 0 in each of the 17 klogs kept since the print landed at
`6344999`, the mutation phase driving ten deletions and ten writes into
an open pass in the eight default-shape runs since it landed at `615c29c`;
the crash shape stops before that phase, and the live-pass control drives
it through a live pass, which the print does not count, since it fires
only on a snapshot pass.

## The walks a one-file pass repeats (design, 1.0.63)

A snapshot pass for one changed file costs three walks of the PFS
root's whole inode index, measured at 100,000 and 1,000,000 files
(1.0.60) and split into feed and merge at 100,000 (1.0.63): each root
scan feeds every chain of the root into the FIFO inside the XOP start
and then merges, 0.76 to 0.89 s a scan there and about 11 s at the
million. The lease's acknowledgment waits on a pass that verifies
(`doc/CLUSTER_PROTOCOL_DESIGN.md`, stage 3.0), so this is the cost the
lease inherits. Neither repeated walk is redundant today, and each is
named here by what it does. The design builds on the scan as it is,
including five defects found while it was audited and recorded as
candidates in the verification record (1.0.64): the kept-absent arm
passes over a source key, a pass with the whole rescan set asked for
never ends, the sweep once destroyed keys the first round had just
inserted, a pass verifies with its root's stamp failed or skipped, and
a read-only remount leaves dirty mappings to be written after it. Each is
fixed or closed by a placed reading before this design's code, and the
preconditions below keep the design clear of each meanwhile. Three are
fixed at 1.0.65, each read against its unfixed control: the kept-absent
arm advances the local cursor alone, a pass asked to compare every
inode defers each root key once, and a failed stamp fails the pass, as
does a stamp or a scan's entry that finds no slave element, which is
read from the code and not driven. The kept-absent skip is the candidate cause of
the third, read on another key of the same parent, and the read-only
remount's is refuted on its path, the remount calling
`sync_filesystem()` since.

**Two parts.** 1a replaces the root rescan after the drain and needs
no condition on other writers, since the carried second round stays as
its backstop. 1b narrows the second round, and is taken only where the
slave element can have no writer but its own thread by construction.

**1a, the root rescan after the drain.** `hammer2_sync_pass()` scans the
root (`hammer2_synchro.c:736`), drains the inodes that scan deferred,
and scans the root again until a root scan defers nothing. That rescan
does two jobs. It continues a root scan that stopped at the deferral
cap, which breaks the loop once more than 1000 deferrals are listed
(`:2589-2625`), before either cursor advances. And it stamps the root,
since a scan that deferred returns `EAGAIN` (`:2688-2689`) and the
stamp is taken only by a scan that did not (`:2699`). On a snapshot
pass whose root scan ended at the end of both key spaces (`exit` 1;
`exit` 2 is the source scan's error, `:2117-2120`), with nothing failed
and `rescan_now` clear, the second job is the only one: every root key
the scan found unequal was replaced, inserted, destroyed or deferred,
and every deferred inode was scanned and stamped by its own call, or
left unstamped as newer than the snapshot (`:1972-1978`, `:1993`),
before the drain removed it. A key the scan found equal is either still
equal, and the rescan finds nothing, or a writer changed it after the
scan. Then the two differ: the carried rescan would put back a key the
writer deleted (`:2432-2437`) and keep one it wrote, where 1a stamps the
root over both. The next pass scans the root whatever its tid (`:1321`),
and a change the master also took is in the next snapshot. One the
slave took alone is settled only in part, and the same under both
forms: a key it added is destroyed by the cut rule (`:2276`) once older
than the cut, but a key it rewrote is kept as newer at the key
(`:2346-2369`) and at the inode (`:1972-1978`), with no cut test, until
the master writes that key again. That is carried behavior, which 1a
neither causes nor cures. When round 1
acted on nothing no second round runs (`:1334`), so 1a's backstop is the
next pass and not the second round. The rescan is replaced by the stamp alone: the stamp block run for the root
with no iteration, with the first scan's count of kept and failed keys
passed to the root's rescan note (`:2795`), which a stamp with no scan
would otherwise clear. The carried rescan counts the root's kept keys a
second time, so `list->kept` reads lower under 1a, and the harness's
kept readings move with it. A scan that stopped at the cap is resumed
rather than repeated, from the lowest key not yet compared on either
cursor, since the cap's `break` comes before both cursors advance and
the destroy arm advances the local side alone; the stamp is taken only
when the final segment ends with `exit` 1, or stops at the cap with
neither cursor holding a key, and no segment was abandoned.
Resuming is scoped to snapshot passes: on the live pass, and with
`sync_snapshot` 0, the master moves between the segments, and a resumed
segment would stamp the root with a tid newer than the one the first
segment compared against, so the live pass keeps the carried rescan.
With `rescan_now` set the carried rescan never ended (the second defect
above, fixed at 1.0.65 by a watermark of the root keys it deferred), and
1a is not taken then either, since that pass compares every inode. Expected: two walks a one-file
pass where the carried pass takes three.

**1b, the second verify round.** Before each round the snapshot root is
put on the rescan set (`:1321`), and the rounds end at one that acts on
nothing (`:1334-1335`); that round is what "verified" means (`:1351`), and
on it the target, the slave's last known-good copy, is deleted. A
one-file pass acts in round 1 and pays a whole round 2 to show it is
done (1.0.63, acted 2 then 0). The narrowed round compares again only
the root keys round 1 replaced, inserted, destroyed or deferred, held in
a set of fixed size. What it catches that round 1's own counts cannot
was an inode stamp whose error the stamp block discarded (`nerror`,
`:2754`), caught by that inode's root key comparing unequal again; a
failed root stamp no round caught. Since 1.0.65 a failed stamp fails the
pass (`:2766-2769`), so the narrowed round need not catch it. The
narrowed round equals the carried one when all of these
hold, and the carried round runs otherwise:

- round 1's root scan ended with `exit` 1, every segment of it, and the
  pass did not end on a failed key (`:817-821`);
- `rescan_now` and `rescan_all` are clear, since with either set the
  carried round compares every inode (`:247-248`);
- the set of acted keys, 64 a round (`HAMMER2_SYNC_NARROW_MAX`), did not
  overflow and holds at least one key;
- the rescan set holds nothing but the snapshot root the rounds put
  there, since an inode it names is one the carried round scans whatever
  its tid; this condition was added when 1b was built and asks more than
  the argument below needs;
- a remote element is registered on the PFS when the pass starts and
  again when round 2 is chosen, a per-PFS count of slot detaches,
  raised in `hammer2_remote_detach()` (`hammer2_remote.c:2549`), the
  one function that clears a slot, reads the same at both, and
  `HAMMER2_CTL_NOROGATE` is off.

The count is read a third time at the verdict (`hammer2_synchro.c:1358-1364`). If it moved
since the pass began, a narrowed round that acted on nothing does
not verify: the pass ends `detached`, a print of its own beside
`newer` and `interrupted` (`hammer2_synchro.c:1406-1434`), so a harness does not read it
as a pass that ran out of rounds, the target stands, and the next pass
decides afresh. As built the choice of each round is printed under
`hammer2_debug` 0x8000, `syncsnap: narrowed` with its key count or
`syncsnap: carried round` with the first condition that failed. A narrowed round that acted is followed by a round
narrowed to the keys it replaced, inserted, destroyed or deferred, with
the conditions read again when it is chosen, within the carried limit
of three rounds (`hammer2_synchro.c:916`).

A narrowed round makes one root call per key, and only its first passes
the root's tid gate by the rescan set: that call takes the root off the
set, and round 1 has already stamped the slave root with the snapshot's
tid. Each later call, and a 1a segment resumed in a round after the
first, which meets the same gate, is let through as going on with the
round's walk (`list->root_cont`, `hammer2_synchro.c:1952-1954`). As first
built the later calls returned at the gate unscanned, so a round of two
or more keys compared only its first; every narrowed round the fleet had
read named one key, so nothing failed, and the review that read the code
found it. A narrowed call is bounded to its key on both cursors, and the
slave cursor is held to that bound after every arm
(`hammer2_synchro.c:2108-2112`), since `hammer2_sync_destroy()`
repositions to `HAMMER2_KEY_MAX` and the sweep would otherwise destroy
the slave keys past the one it was given.

The last is C_N, the condition that nothing but this thread writes a
root key of the slave element between the rounds, made structural
rather than detected. While a remote element is registered no frontend
can write the PFS: a read-write mount and a read-write remount are
refused (`hammer2_vfsops.c:1814-1820`, `:2740`), the vnode operations
refuse a write on a read-only PFS (`hammer2_vnops.c:374`, `:500`,
`:1431`), and the registration itself refuses a PFS mounted read-write
(`hammer2_remote.c:2488-2492`). A mapping a read-write mount dirtied before a read-only remount leaves no
gap: the write fault stamps the inode through `->update_time`, which
queues it (`hammer2_vnops.c:2537`), so the remount's sync walks it, and
since 1.0.65 the remount also calls `sync_filesystem()`
(`hammer2_vfsops.c:2719`), as ext4 does on that transition. The fifth
candidate is refuted on its path, with its probe kept in
`script/test-enospc.sh`. A slot can also be detached while the link stays up, when the
peer's span goes, and the pass's reads of its source snapshot continue
(`hammer2_remote.c:2713-2722`); the read-write gates open while it is
detached and the slot can be registered again later, which is why the
condition reads the detach count and not two samples of the slot.
Another element's sync thread reaches only chains of its own element,
each found by its `clindex` (`hammer2_synchro.c:307`, `:1897`, `:2051`),
and the pass's own snapshot, other threads' syncs and the remote
server's snapshot commands (`hammer2_remote.c:99-101`) touch the slave's
root chain (`:614`, `hammer2_ioctl.c:1003-1008`) and no root key. Under these a key round 1 found equal is still
equal: the source is the snapshot, and the thread's round-1 writes touch
the keys it acted on and the indirect blocks and root above them, while
a move of a key between indirect blocks keeps the leaf's bref, its
`modify_tid` included (the collapse, `hammer2_chain.c:4402-4403`; an
indirect block's creation, `:4098`, `:4109`; the reconnect of an
existing chain, `:3287-3288`), so a root scan's comparison of a leaf
reads the same. This is the lease's replica, which mounts for the pass
alone; locally the condition is never met, and the local shapes keep
the carried round unless the debug build's `sync_assert_cn` asserts it.

Three questions stayed open for 1b's code step, recorded here as
constraints rather than settled. The first, whether any write reaches
the slave element while its only master's slot is detached, is read: it
does. A detach keeps `pfs_nmasters`, so every collect fails
`ENOTCONN` (`hammer2_cluster.c:361-362`) and a create fails at its
lookup, but the gates open, and a change to an inode the mount already
holds needs no lookup: `hammer2_inode_chain_sync()` starts its modifying
XOP on every element before its collect fails (`hammer2_inode.c:1852-1853`).
Under `H2_WIRE_SILENCE=1 H2_WIRE_DETACHWRITE=1` in `script/cluster-wire.sh`
(`wire-run-20261028-164316`), after the keepalive detached the master's
element, B's `CL` remounted read-write, a `chmod` of its root returned 0
and moved the root's mode on B's media from 755 to 700, and to 711 in
emergency mode, with two inode syncs reported failed; a create failed
not connected and left no entry. So the detach count is needed, and the
narrowing's control can fail. The chmod's success with its sync failed
is the carried `XXX return error somehow?` of that function, upstream's.
Over the wire the source
snapshot is taken on the peer by the peer's server
(`hammer2_ioctl.c:958-961`) and is a PFS a mount there could write.
The refusal is built by name rather than by the server's list of the
snapshots it holds: a PFS whose name carries the pass's suffix,
`<pfs>.h2sync-src`, is refused any mount (`hammer2_remote_is_source()`,
`hammer2_remote.c:2614`, tested at `hammer2_vfsops.c:1829` under
`hammer2_mntlk`). The name covers the local pass's own source, which 1a's
resume and 1b's narrowing also take as immutable, and a crash's leftover,
which the next pass deletes by that name; a list would cover only a
peer's, is kept per connection while a mount names a PFS, and is edited
under its own lock. A read-only mount is refused too, since any mount
holds the PFS against the delete by name that begins every later pass
(`EBUSY`, `hammer2_ioctl.c:753-756`): the local pass then skips its pass,
printing only under bit 0x8000, and the server answers the peer's
snapshot `EIO`, so one read-only mount would stop the slave's passes.
With no mount of
a source there is no remount to refuse; an element of the suffix's name
can still join a mounted PFS by `pfs-create` with that PFS's cluster id,
a name collision rather than a pass's source, which takes a fresh cluster
id (`hammer2_ioctl.c:1108`). The suffix's name is still reserved: an
element named `<pfs>.h2sync-src` on the master's device is what that
PFS's pass deletes by name at its start, so while it is mounted every
pass stops as under a read-only mount, and unmounted it is deleted. The
`.h2sync-tgt` target is not gated: a pass deletes and retakes it and never
reads it as a source. And whether `hammer2 pfs-delete`
of the slave element through the device's super-root
(`hammer2_ioctl.c:807`) stops the thread before it writes is read from
the code. The local rate runs cannot reach 1b under its
own condition, so they read it through a `HAMMER2_LOCKDEBUG`-only
parameter that asserts C_N, set only by `cluster-sync.sh`'s tree arm,
which keeps the cluster PFS unmounted for the timed passes; both arms
of that comparison are then `HAMMER2_LOCKDEBUG` builds, unlike the
1.0.60 and 1.0.63 runs. The wire runs read 1b under the real
condition. `sync_walks` is read once at the
pass's start, since the parameter can change while a pass runs.

This is branch N. Branch K, a narrowed verification that keeps the
target with a full round every K passes, needs no proof but leaves an
acknowledging pass paying the full round, no saving for the lease.

**The idle stamp pass stays.** After a verified pass the next cadence
can find the master idle and run the live pass as the idle stamp
(`hammer2_synchro.c:1165-1174`). A shortcut taking the root's stamp without that walk was
weighed and dropped: of 336 idle stamps in the logs kept since
2026-10-20, 23 deferred or acted, 17 of them after a pass that verified
while keeping keys, which "verified" allows (`hammer2_synchro.c:1334-1351`). On
`fixtures/wire-run-20261026-151912-b.klog`, over the wire with
read-write mounts refused, an idle stamp at 255.684 s replaced one key
and deferred and scanned inode 0x534. The stamp pass is what settles
those keys, and nothing would revisit them once the root's stamp
equaled the master's (`hammer2_synchro.c:1162-1163`).

**Readings and controls.** With 1a and 1b a one-file snapshot pass is
one root walk plus the acted keys where the carried pass is three, a
third of its time read in the same boot and build, about 11 s at the
million on 1.0.60's per-walk time and still above the 5.12 s cadence,
so lever 2 is expected to follow. 1a is built at 1.0.67: a one-file
change, and one in each of 100 directories, read two walks where the
carried pass reads three, a removed or moved file one against two, and
4000 changed files one walk in four segments, three of them resumed,
where the carried pass makes five scans from key 0 in its first round; on
`h2release-7.3` a one-file pass took 19.9 s against 29.5 s at the
million in one boot
(`doc/history/verification-record.md`, "The root rescan replaced on a
snapshot pass"). 1b is built at 1.0.68: with C_N asserted, a one-file
change's second round scanned its one key and an eight-file change's its
eight, 2 iterations each against the root walk's 10,103, one walk from
key 0 where the carried pass makes three, and a change past the key set
kept the carried round (`doc/history/verification-record.md`, "The
second verify round narrowed").
The walks are counted from the scan itself: iterations summed per pass
against the root's key count, since a resumed segment prints its own
`START_SCAN`. The new behavior sits behind `sync_walks` (1 the design,
0 the carried), and the comparison is made within one boot, the same
tree read under each setting in turn, since times on a loaded host do
not compare across runs. A fake pass is a narrowed or stamp-only pass
that verifies a slave which differs from its snapshot; the fingerprints
at the end of every arm catch it, and each control is placed where its
change executes:

- the resume, in an arm that changes 4000 inodes, more than the 1001
  deferrals a capped segment takes (`hammer2_synchro.c:2589`) times the
  three verify rounds (`:916`), so the cap fires in every round, with a scratch build that drops both the resume
  and 1a's end-reached test, so the stamp is taken after a capped
  segment: each round after the first must then act again on the keys
  past the break, which the round's own `acted` count reads without a
  fingerprint, and the pass must end unverified where the design's
  verifies in two rounds (read on a scratch build of `57c5682` in
  1.0.67's record, acted 2002 in each of three rounds, then
  unverified);
- the narrowing, placed by the reading above, which found that a write
  can reach the slave with the master's slot detached. As built it is
  local: the debug build's `sync_narrow_alter` makes the first narrowed
  round of a change do what a detach and a write through the gates it
  opens would do, raising the PFS's detach count and destroying one
  slave inode outside the round's keys under a transaction of its own
  (`H2_NARROW_ALTER` in `script/cluster-sync.sh`). With the verdict's
  reading of the count the pass must end `detached`; with that one line
  removed in a scratch build it must verify a slave one inode short of
  its master, counted inside `CL`'s own block of `hammer2 -v show`, and
  the next change's pass, which compares every root key, puts it back.
  The design's wire form, a hold point between the rounds at which the
  harness deletes the peer's span with the link up and writes through
  the opened gate, is not built: no harness mode deletes a span with
  its link left up, and Linux has no single-element `local` mount to
  write the slave alone from a local cluster (`hammer2_vfsops.c:1065`).
  `DEFER(3.2.7, the first increment where an acknowledgment rests on a
  narrowed pass)`: until then the local control reads the verdict's
  count on the path the wire form would reach, and 1.0.70 read the walks
  of both levers on the wire without it;
- the resume on the live pass, allowed in a scratch build under
  `sync_snapshot=0`, with a hook writing the master alone below the
  break key during the drain and forcing a master flush before the
  resumed segment: the slave must stay unequal after the next pass.
  A scratch build of `57c5682` was read for 1.0.67's record without
  the hook, which is not built. It removed the scope test and also set
  the list's walks on the live branch, which `sync_snapshot` 0 never
  does: its live passes took 3 stamps alone and resumed 20 segments in
  one run, where the design's took none. That shows a live pass takes
  1a once the list's walks is set and the scope test is gone. The
  shipped exposure is a live pass inside a snapshot thread, the idle
  stamp among them, which inherits the list's walks from the snapshot
  pass before it; no run has driven one to defer, and the miss the scope
  prevents is not read.

## Skipping unchanged subtrees (design, 3.0b.2)

**Status, 2026-11-01: amended and audited to SIGN-OFF; the tree
carries only scaffolding (the `HAMMER2_LOOKUP_PRUNE` flag,
`hammer2.h:365`, two unused thread fields, `hammer2.h:1024-1025`, and
scanall clearing the flag, `hammer2_xops.c:902`) and no prune
predicate, and, under `HAMMER2_LOCKDEBUG` alone, an instrument that
prints what the capture and the veto below would read on each snapshot
(`hammer2_snap_gen()`, `hammer2_snap_queues()`, `hammer2_ioctl.c:854,
869`).** The plan review of 2026-11-01 (five rounds, served by Gemini 4
Argon, transcript kept as
`p8-notes/plan-review-20261101-a971c20377d8e83c7.jsonl` in the data
tree) found the residue veto unsound as the design of 2026-10-30 wrote
it: `hammer2_pfs_snapshot()` itself calls `hammer2_inode_modify()` on
the source PFS root inside the window (`hammer2_ioctl.c:1003`), which
queues that root on the PFS's sideq (`hammer2_inode.c:1802-1803`), so
the queue leg read after the copy would veto every pass. The failure is
closed (nothing would prune), not a wrong prune. The same review asked
for the generation to be bound to the attachment instance, since a
master restored from an older image can move it backwards, for the
capturing caller to be named, and for the remote veto and the harness
shape that can produce a pruned pass to be stated. The instrument,
read on `cluster-sync.sh`'s default shape at `0c4c709` (run
`cluster-run-20261101-120355`, 27 snapshot calls; the reading and its
per-call tally are `p7-notes/n8-0-instrument-reading.md` in the data
tree), confirmed the queue leg's failure and found the counter leg's
the same: the source root goes from neither queue to the sideq on
every call, and the module-wide dirty count rises by 2 or 3 across the
copy on every call outside the backlog window, the snapshot root's
create and modify under the super-root. The amendment below settles both
legs and the review's other points, and replaces the paragraphs of
2026-10-30 where they disagree. Its hostile audit, one reviewer resumed
across seven rounds and served by Claude Opus 5.5 (transcript kept as
`p8-notes/amend-review-20261101-a2a62f84f7ecea8fb.jsonl` in the data
tree), counted subject findings of 14 (1 blocking, 5 major), 7, 1, 1, 3,
2 and 0, and signed off on the seventh; every finding was checked on the
source before it was applied, and no lever-2 code precedes it.

**The amendment of 2026-11-01.** Each item says which text of
2026-10-30 it replaces, or that it adds what that text left out.

1. *Where the legs are read, and what they read.* Replaces "reads both
   legs after the snapshot copy" and the delta across the window. Every
   leg is read once, at the cut: after the PFS sync returns and before
   `hammer2_trans_sub()` (`hammer2_ioctl.c:995`), the point the
   instrument reads as `trans` (`:991`), with the source root's inode
   not yet locked (`:998`). A pass is pruned-eligible only if, at that
   point, both of the source PFS's queues are empty,
   `hammer2_count_chain_modified` is 0, the source device has never
   failed a flush since its mount (the latch below), and the
   blockset the copy will take, `pmp->pfs_iroot_blocksets[clindex]`
   (`:1120`), equals the source element's root chain's own blockset,
   both read inside the root chain's lock, which is the lock the flush
   holds when it refreshes the slot (`hammer2_flush.c:1170-1177`). The
   slot can still be refreshed between the cut and the copy, by an
   `fsync` of the PFS root directory (`hammer2_vnops.c:1364`) or any
   other flush of the root; what that brings into the copy was written
   after the cut, stamped `G + 1`, and harmless to the proof. These are
   absolute readings, not deltas. The body's own work all follows the cut (the source root's
   `hammer2_inode_modify()` at `:1003`, which touches no chain, and the
   snapshot root's create at `:1044`), so no leg can see it and no
   excuse for the body is needed. On the source calls of the run above
   the count read 0 at this point on all 8 calls outside the backlog
   window and 362 to 687 on the 7 inside it, which veto.

   Why the window after the cut needs no leg: the generation is read
   equal at the cut and after the copy, so every chain modified in
   between is stamped `G + 1` (`hammer2_chain.c:1670`), above the
   generation `G` the pass may adopt, and every ancestor a later flush
   restamps for it is stamped at that flush's generation plus one,
   higher still. Such a chain cannot fall inside a later pass's pruned
   range whether or not this snapshot holds it, and a frontend
   `setattr` on the source root inside the window need not veto. What
   can fall inside one is a chain stamped at or below `G` whose content
   this snapshot lacks, modified before the cut and not carried into
   the copied blockset. There are four ways to be there, one per leg:
   - still `MODIFIED`: the count sees it (incremented on every first
     modify, `hammer2_chain.c:1483`, and on the volume chain,
     `hammer2_vfsops.c:373`; decremented as the flush writes the chain,
     `hammer2_flush.c:642`). Two paths leave a chain changed with
     `MODIFIED` clear and `UPDATE` set: the dedup branch
     (`hammer2_chain.c:1601-1604`) and a rename into a new parent
     (`:3287-3288`, described at `hammer2_flush.c:832-834`). Both run
     under an inode the frontend has queued, which the queue leg sees.
     That rests on a premise: every modify below an inode queues that
     inode. The port's dirty-folio fix made it hold for the write path
     (`hammer2_writepages()` queues the inode), and `storm.sh` checks it;
     a path that modifies under an unqueued inode breaks this way and
     not the count's.
   - its inode still queued, including after an `fsync`, which leaves
     the inode on the sideq for the syncer (`hammer2_vnops.c:1340-1342`):
     the queues see it.
   - written, `MODIFIED` cleared, with the parent's update failed: a
     parent modify that fails in the flush sets `UPDATE` on the child
     again and skips the update (`hammer2_flush.c:922-930`), and nothing
     re-flags the path, since the sync's second stage clears `ONFLUSH`
     on its way down (`:538`) and stops at inode boundaries without
     re-flagging (`:501-516`). The chain then waits until its inode is
     next dirtied, while later syncs move the generation past its stamp,
     and the sync still returns 0, unconditionally
     (`hammer2_vfsops.c:3341`), its errors going only to
     `hammer2_sync_error()` (`:3011-3022`). The latch sees it: any
     `hammer2_flush()` that ends with an error for a chain of a device
     sets a flag in that device's `hammer2_dev_t`, set inside
     `hammer2_flush()` itself, since the lastdrop caller discards its
     return (`hammer2_chain.c:637`), and zeroed only when the structure
     is allocated at the device's mount. It is not tied to item 4's
     attachment instance: every snapshot registers its PFS through the
     same join (`hammer2_ioctl.c:1157` calls `hammer2_pfsalloc()`), so an
     attachment value moves on every pass, while the stranded chain lives
     as long as the device structure. After a flush failure, ENOSPC
     among them, lever 2 is off on that device until it is mounted
     again. That is availability, not correctness; a reading of
     `UPDATE`-pending chains by count would be finer and is not built.
   - flushed, but the copied blockset stale: the copy takes the cached
     slot, which is refreshed only when the root's inode flush finds a
     flush flag on the root chain (`hammer2_flush.c:1158-1178`), and a
     stale slot is a recorded candidate (the 1.0.62 idle-test entry,
     "The idle test on two masters", and the third-element reading the
     plan's track R item 6 owns). The equality leg sees it.
   The paragraph of this item's first draft that claimed the volume
   flush reaches every flagged path, and proposed the root chain's
   `ONFLUSH` as a third reading, was wrong on both counts: the volume
   recursion skips mounted PFS roots (`hammer2_flush.c:472-500`), the
   FREEMAP arm moves the generation too (`:694`), and a mounted PFS's
   sync clears the path it walks (`hammer2_synchro.c:574-580`). It is
   withdrawn.

2. *Adoption.* Replaces "adopted beside that arm", which left the vetoed
   pass unstated. A pass adopts its candidate (`last_gen = cand_gen`)
   only in the verified arm (`hammer2_synchro.c:1367`), and only when
   the candidate is valid: the two reads at each point agreed, the two
   points agreed, and every leg of item 1 was clear. A pass with an
   invalid candidate may still verify, unpruned, and keeps the
   `last_gen` it had: snapshot N-1's verification covered every chain
   stamped below that older generation, and nothing in pass N changed
   that. A pass that fails verification also keeps it.

3. *Which caller captures.* Adds what the 2026-10-30 text left out.
   `hammer2_pfs_snapshot()` has four callers: the user ioctl
   (`hammer2_ioctl.c:840`), the server for a remote slave
   (`hammer2_remote.c:614`), and the thread's source and target calls
   (`hammer2_synchro.c:1215, 1250`). It gains an out-parameter beside
   `mtidp` for the candidate and its validity; the ioctl and the target
   call pass NULL and capture nothing, so a target call, which reads
   the slave device's own unrelated generation (0x12 to 0x44 against
   the source's 0x14 to 0x5d in the run above), cannot overwrite the
   master's candidate. A source behind a connection is routed to
   `hammer2_remote_snapshot_take()` (`hammer2_ioctl.c:956-960`), which
   carries the same out-parameter and fills it from the closing frame
   (item 6).

4. *The attachment instance.* Replaces "reset whenever the source
   element changes". A module-wide 64-bit counter is drawn once for
   every element a PFS gains: at the local join
   (`pmp->pfs_hmps[j] = chain->hmp`, `hammer2_vfsops.c:499`) and at a
   remote registration (`hammer2_remote.c:2519`), into a per-slot field
   beside `pfs_hmps[]`. The candidate records the source slot's and the
   slave slot's values; `last_gen` is used only while both slots still
   carry them, and is zeroed otherwise, as it is at thread start
   (beside `thr->snap_cut = 0`, `hammer2_synchro.c:1547`). A volume
   cannot be replaced under a mounted device, so an older image swapped
   in for either element, flushed past `last_gen` or not, arrives
   through a detach (`hammer2_vfsops.c:901`, `hammer2_remote.c:2566`)
   and a new join, and a new value. A field every attach initializes
   alike, or the `hmp` pointer, which a later allocation can reuse,
   would match across that detach. The below-`last_gen` test is kept as
   a second guard. The slave's slot is bound too, since a slave element
   replaced by an older image holds keys inside ranges the thread no
   longer compares.

5. *The harness shape that produces a pruned pass.* Adds what the
   2026-10-30 text left out. The default shape has two pruned-eligible
   source passes under item 1's legs, at 68.2 s and 119.9 s of the
   instrument's run (a verified snapshot pass of the same thread before
   each, the count 0 at the cut, the source root on neither queue
   before the body's modify and the sideq after the copy holding only
   that root, the body's own). N8a's expected
   count for the default shape is those two, by phase; it rests also
   on the latch and equality legs, which the instrument never read, so
   a mismatch there is read first as a finding about those two legs.
   No shape that
   times a pass does: the tree arm unmounts both mounts on every change
   and reads that no thread is left (`cluster-sync.sh:1013-1014`), so
   each timed pass is a new thread's first pass and item 4 resets it,
   and a slave element left attached is written directly by the
   frontend (`cluster-sync.sh:1291-1295`), so a pass finds nothing to
   copy. The shape built for the local rates is the plan's candidate
   (i): a `HAMMER2_LOCKDEBUG` knob under which an XOP allocated with
   `HAMMER2_XOP_MODIFYING` skips every element whose `pfs_types[]` is
   `SLAVE` when its element set is built (`hammer2_admin.c:454-457`),
   with one exception: the PFS root's own inode flush in the sync's
   second stage, the `VOLHDR` call (`hammer2_vfsops.c:3332-3334`), runs
   on every element when the sync is the snapshot body's on the thread
   (`hammer2_ioctl.c:978`). Without it the target call's sync would
   leave the slave device's volume header unwritten, and that dirt would
   sit in the count at the next cut. It does not keep the slave's root
   slot current: the previous pass's `hammer2_sync_flush()` left the
   slave root clean without refreshing the slot (the paragraph "Two
   masters" above), and the slot is refreshed only inside the flush-flag
   test (`hammer2_flush.c:1161-1178`), so the exempt flush finds the root
   clean and skips it. Under the knob that would make every target after
   a pass that acted a copy of an old slot, and the kept target is the
   backstop branch K and N8d rest on. So lever 2's first increment,
   under `sync_prune` or the knob armed, so that with both off every
   carried path is unchanged and a carried arm run in the knob's shape
   still takes current targets, refreshes the slot in `hammer2_sync_flush()` right
   after its root flush, under the root chain's lock as
   `hammer2_flush.c:1170-1177` does, and applies item 1's equality test
   to the target call too. On a mismatch the target call flushes the
   slave root chain inside the body's own flush transaction, already
   open at the cut (`hammer2_ioctl.c:987`): `hammer2_sync_setflush()` on
   the root (static in `hammer2_synchro.c` today, so it gains a prototype
   in `hammer2.h`), then `hammer2_flush()` with `FLUSH_TOP`, `FLUSH_ALL`
   and `FLUSH_FSSYNC` under the root chain's lock, without calling
   `hammer2_sync_flush()`, whose own `HAMMER2_TRANS_ISFLUSH`
   (`hammer2_synchro.c:605`) would wait on the body's for good, since flush
   transactions on one PFS do not nest (`hammer2_flush.c:102-106`). It
   then refreshes the slot from the root after that flush, prints the
   mismatch, and takes the target
   from the refreshed slot, so the copy is always of a flushed root,
   never of a root the frontend dirtied after the call's sync. It
   cannot refuse the target: the thread runs no pass without one
   (`hammer2_synchro.c:1242-1244`), which would also stop the pass-end
   flush, the slot's other refresh. The same refresh made ungated, the
   answer to the stale-slot candidate in every build, belongs to the
   plan's track R item 6 with its own readings on a build with lever 2
   off. The exemption is no wider: the sync's
   first stage on the thread drains the frontend's queued inodes
   through the insert, destroy, sync and flush XOPs
   (`hammer2_inode.c:1879, 1917, 1822, 1947`;
   `hammer2_vfsops.c:3238-3273`), and run on the slave those would put
   a frontend change's metadata, at the master's transaction id, on a
   slave whose data the knob withheld, an inode the pass would then
   skip by its tid. Under the knob they skip the slave whoever starts
   them, and the pass copies the change, data included. Twenty-one
   allocation sites carry the flag, the strategy write
   (`hammer2_vnops.c:2275`) among them; the reads, lookups and readdirs
   still run on every element. The shape also reads both queues empty
   at every sync the thread starts while the knob is armed, so a stage
   1 that found work there is a reading, not an assumption. The shape has one slave; with two, the thread's
   election XOP (`hammer2_synchro.c:1068`), which excludes only its own
   index, would meet the other, and the knob's effect there is not
   designed. An inode the frontend creates under the knob gets its
   in-memory cluster from the XOP's elements, so its slave index holds
   no chain; a snapshot pass reaches the slave by inode number
   (`hammer2_sync_slave_chain()`, `hammer2_synchro.c:297`) and is not
   affected, while the live idle stamp pass reaches it through the
   inode (`:1897`) and finds NULL, which the ternary at `:1944-1945`
   reads as nothing to update: a skip, not a failure. The shape
   unmounts the cluster PFS before the timed pass, which evicts those
   inodes, and one idle stamp pass after a knob change is read with the
   fingerprints compared. The thread is frozen across the change and
   the unmount, the freeze trigger, its side effects and the timing as
   the plan's N8.0 states them. The wire (candidate (ii)) reads function
   only.

6. *The remote veto.* Replaces "travels on the snapshot reply's closing
   frame", which named no field. Over the wire the capture and every
   leg run in the master's server call (`hammer2_remote.c:614`), on the
   master's device. The snapshot reply's closing frame, `dmsg_hm2_feed`
   (`src/sys/sys/dmsg.h:599-610`), whose `tid` already carries the
   snapshot's transaction id (1.0.49), carries the candidate in eight
   bytes taken from `reserved[24]` and a new flag `DMSG_HM2_FEEDF_GEN`
   in `flags`, set only when the candidate is valid as item 2 defines
   it. A peer that predates the field sends zeroed reserved bytes and
   no flag, since a message is allocated zeroed
   (`hammer2/kern_dmsg.c:1838-1839`),
   so the slave adopts nothing and never prunes; the request needs no
   version for this field. The slave adopts the candidate in its own
   verified arm under item 2, and never one the master's legs refused,
   since a refused one is never sent.

7. *The shape of the skip.* Replaces "a lookup flag carrying the prune
   threshold into the carried lookup" in "Where a skip lives".
   `hammer2_chain_lookup()` takes no XOP (`hammer2_chain.c:2336`). The
   scan's XOP carries the threshold, and `hammer2_xop_scanall()` passes
   it to a lookup and a next variant only the scan calls (it iterates
   with both, `hammer2_xops.c:919, 925`, and `hammer2_chain_next()`
   re-enters the lookup), which return an indirect block whose
   `mirror_tid` is below the threshold as a range record, the way
   `LOOKUP_MATCHIND` returns one on an exact range
   (`hammer2_chain.c:2395-2405`), instead of recursing into it
   (`hammer2_chain.c:2602-2609`). The record travels
   through the feed and collect to the slave side, which suppresses its
   sweep inside the range. The clearing line at `hammer2_xops.c:902`
   goes with the variant: the variant is selected by the threshold, not
   by a lookup flag, and the flag `HAMMER2_LOOKUP_PRUNE` is removed with
   it rather than left defined and cleared. The carried lookup's body is
   shared with the variant, so the frontend gates and `xfstests.sh`
   still join N8b's readings.

8. *Scope, cited.* Replaces the uncited "Scope" paragraph's assertion.
   The threshold is set only on the snapshot pass's source scan, where
   `snap` is true (`hammer2_synchro.c:1827`, the scan's inode belonging
   to the snapshot PFS rather than the thread's), never on the live
   pass nor on the idle stamp pass, which is a live pass inside a
   snapshot thread (`:1159-1174`). A count of `syncsnap: prune` lines
   cannot carry the assertion, since only a snapshot pass prints one
   and it reads 0 under `H2_SYNC_SNAPSHOT=0` whatever the code does.
   The variant counts every range record it returns in a module-wide
   counter, printed by every pass, live and idle stamp passes included,
   beside the pass's kind; the assertion is that counter unmoved across
   every live pass of every run and across the whole of an
   `H2_SYNC_SNAPSHOT=0` run. Its positive control is the same build's
   pruned arm of N8b, which must move it; a counter that no path
   increments reads 0 in both, which is the fake pass this control
   exists to expose.

9. *Copy-on-write and EMERG.* Answers the review finding that the proof
   leaned on immutability without saying so. It does not: soundness
   rests on the stamp. An emergency-mode modify that cannot allocate
   reuses the block in place (`hammer2_chain.c:1629-1632`; the
   snapshot warning is at `:1625-1627`), and the in-place paths of
   `:1498-1522` are guarded by `pfs_lsnap_tid`, but every successful
   modify, in place or not, stamps the live chain (`:1670`) and sets
   `UPDATE`, so the next pass reads the changed range unpruned. A pass
   never reads a range it skipped, so an in-place change there cannot
   affect the pass that skipped it. What EMERG corrupts is the source
   device's snapshots themselves, with or without lever 2 (the kept
   target is a snapshot of the slave, on the slave's device); it is not
   excluded here.

10. *Controls under the cut-point reading.* Replaces the two
    `HAMMER2_LOCKDEBUG` controls of 2026-10-30, which the plan's N8a
    and N8c also name. Each is a hook of its own under
    `HAMMER2_LOCKDEBUG`, armed for one pass, and each vetoed pass prints
    unpruned with its leg.
    - The writer held between `hammer2_trans_sub()` and
      `hammer2_chain_modify()` across the snapshot, held before its
      `hammer2_inode_modify()` so that its inode is on no queue when the
      sync returns: it modifies after the cut, is stamped `G + 1`, moves
      no leg, and stays as a negative control reading eligible, a later
      pass still copying its key. Held after `hammer2_inode_modify()`
      instead, its inode is on the sideq at the cut and the queue leg
      must fire.
    - Queue leg: an inode put back on the sideq after the sync returns
      and before the cut.
    - Count leg: one source chain modified directly before the sync
      under an inode on no queue, so the sync leaves it `MODIFIED`; the
      hook flushes that chain after the vetoed pass, since no stage 2
      would reach it (`hammer2_flush.c:501-516`), and the next pass must
      then be eligible and still copy the key.
    - Latch: a flush error forced on the source device, after which
      every pass reads the latch until the device is mounted again.
    - Equality leg: the root slot overwritten with the blockset the
      previous pass copied, before the cut, which the leg must refuse.

The other paragraphs of this section are the design of 2026-10-30,
corrected where an item above names them.

A snapshot pass that can acknowledge still walks the whole root index once
a round even when one file changed. Lever 2 prunes subtrees the last
verified snapshot already compared, keyed on `mirror_tid` rather than the
cut: the cut is the snapshot flush transaction's id, taken right after
the PFS sync (`hammer2_ioctl.c:974-995`), and a writer that took its tid before cut N
can land in snapshot N+1 under blocks whose propagated `modify_tid` sits
below cut N, with no fixed slack bounding a stalled writer
(`hammer2_flush.c:118-121`, `hammer2.h:1014-1023`,
`hammer2_chain.c:2395-2405, 2602-2609, 3282-3289, 3844-3855, 4398-4403`).
`mirror_tid` is stamped at every modify from the device's flush generation
(`hammer2_chain.c:1670`) and is monotone per device
(`DILLON_HAMMER2_DESIGN_2015.md:299, 302-306, 332-335, 386-387`).

**The prune predicate and its proof.** The pass records a per-thread
last-verified generation, sampled as a candidate around the snapshot and
adopted only in the verified arm (`hammer2_synchro.c:1351` computes
`verified`, `:1365` sets the next pass's cut, `:1367-1398` is the verified
arm that deletes the target; the candidate is adopted beside that arm, and
`thr->snap_cut` cannot serve because `:1365` runs on every pass, verified
or not. Which pass adopts, and on what candidate, is the amendment's
item 2; the generation is zeroed at thread start (beside `:1547`) and
bound to the source's and the slave's attachment instances (item 4), and
under the lease a term or holder change is another device and counter.
The candidate is read from
`voldata.mirror_tid` at two points inside the shared snapshot helper
`hammer2_pfs_snapshot()` (`hammer2_ioctl.c:916`), past its early returns:
after the pre-snapshot PFS sync returns, before `hammer2_trans_sub()`
takes the cut (`:977-995`), and
after the snapshot copy before its flush transaction closes. A pass
prunes only when both read equal. The pre-snapshot PFS sync can itself
move the generation (`hammer2_vfs_sync_pmp()` stage 2 flushes with
`VOLHDR`, `hammer2_vfsops.c:3327-3334`, whose volume-root pass flushes
fchain and vchain when flagged, `hammer2_flush.c:1249-1275`, executing the
FREEMAP/VOLUME bump arms, `:694`, `:721-723`), which is why no read sits
before it: the candidate is the post-sync generation, and any inequality
across the snapshot window proper, from whatever flusher, runs that pass
unpruned. The check fails closed; its cost is availability (one unpruned
pass per syncer volume flush in-window), not correctness. Each read takes
the voldata lock (`hammer2_voldata_lock()`, `hammer2_vfsops.c:358`, declared at `hammer2.h:1580`) and is done
twice requiring equal: the FREEMAP bump runs outside that lock (taken
only in the VOLUME arm, `hammer2_flush.c:710`), so the reads rest on the counter's
monotonicity and double-read equality, not on exclusion. A subtree prunes only when its root's
`mirror_tid` is strictly below the adopted generation. Soundness rests on
one claim: any chain modified after the last verified snapshot's
comparison carries a `mirror_tid` above its generation. The stamp is
`voldata.mirror_tid + 1` read at modify time (`hammer2_chain.c:1670`), and
`voldata.mirror_tid` moves only at the volume flush, monotone
nondecreasing, so a later modify stamps strictly above a generation sampled
before the snapshot whose comparison verified. Two halves carry the content:

Source half: a `hammer2_chain_modify` restamps exactly one chain
(`hammer2_chain.c:1670-1672`): the rename-and-reinsert helper (`:3411`),
the destroy (`:3450`), the indirect create (`:3616`, its parent, and
`:3876`, the new indirect block that becomes the moved chains'
parent), and
the flush-time blockmap update with mtid 0 (`hammer2_flush.c:922`) each
restamp the immediate parent, and the collapse (`hammer2_chain.c:4316`)
likewise. Higher ancestors follow only through flush propagation: every
modify sets UPDATE (`hammer2_chain.c:1543-1545`), and flushing a child
modifies its parent with mtid 0 (`hammer2_flush.c:922`). A below-threshold
range root therefore proves no *flushed* structural change below it since
the generation was adopted; a destroy two levels down in-window does not
lift the root at modify time, but is stamped above the generation itself
and so cannot sit inside a later pass's pruned range (amendment, item 1).
What the residue veto excludes is dirt from before the cut that the sync
left out of the copied blockset, with four legs (amendment, item 1): the
PFS queues, the module-wide dirty-chain count, the device's flush-error
latch and the root slot's equality. An inode the sync requeues on a failed
vget (`hammer2_vfsops.c:3155-3181`, setting `dorestart`) or finds
re-dirtied mid-flush (`:3214-3222`) restarts the flush (`:3300-3314`), and
anything still queued or requeued when the sync returns leaves observable
residue in the PFS queues; anything dirtied with no queue entry still
keeps the module-wide `hammer2_count_chain_modified` above zero
(incremented on every first modify, `hammer2_chain.c:1483`, decremented
as the flush clears MODIFIED, `hammer2_flush.c:641-642`). The snapshot
helper already syncs before it cuts (`hammer2_ioctl.c:977-995`); lever 2
reads every leg at the cut, as absolute values, and prunes nothing on any
pass that finds a leg set there (amendment, item 1). The counter is
module-wide (a file-scope global across devices), so dirt on a sibling PFS
or a sibling device fires the veto too: fail-closed
availability, never a wrong prune, and the per-pass line below tells the two
apart. The controls, one per leg, are the amendment's item 10. Every
snapshot pass prints one
`syncsnap: prune` line naming pruned or unpruned and, when unpruned, which
leg vetoed or which generation read disagreed: a capture that never agrees
(a deterministic in-window bump) then reads as a count of unpruned passes,
not as a lever that silently never fires.

Slave half: the slave side iterates its own key space
(`hammer2_synchro.c:2125-2144, 2226-2229, 2240-2242`) and sweeps what the
source lacks, so a skipped source range must reach the slave as an explicit
record through the feed and collect, suppressing the sweep inside it. In
a local shape where the frontend writes the slave, the default shape's
and not the knob's of amendment item 5, that record is also what the
slave-side test reads: a slave key altered inside a pruned range
must survive to the K-th round and trip the detection line below. The
slave-side test is the half the local shape can fail while the source
half holds.

**Where a skip lives.** Indirect blocks recurse inside the carried lookup
(`hammer2_chain.c:2602-2609`), which every frontend path shares, and
`LOOKUP_MATCHIND` returns an indirect block only on an exact range
(`:2395-2405`). The skip is a lookup and next variant that only the
scan calls, selected by the threshold the scan's XOP carries
(amendment, item 7), and the frontend gates and `xfstests.sh` join the
readings since the variant shares the carried lookup's body. The forced
control is placed in that predicate: a source-only skip with the merge unchanged
must produce sweeps the fingerprints read.

**Scope.** Snapshot passes only: the live pass and the idle stamp pass
read in-memory chains whose parents the flush has not yet raised, so they
never prune. Where the threshold is set and what counts as the assertion
under `H2_SYNC_SNAPSHOT=0` are the amendment's item 8.

**Backstops and S5.** A wrong prune deletes the last known-good target
(the verified arm deletes it, `hammer2_synchro.c:1386-1398`; the snapshot
carries `pfs_lsnap_tid`, `hammer2_ioctl.c:1008, 1092`; the next pass's cut
is set at `hammer2_synchro.c:1365`), so the lever takes the target
lifecycle of branch K: the target is kept across pruned verifications and
retaken at an unpruned one every K passes and on any `rescan_all`, with
the target's staleness and held space stated; only an unpruned full round
deletes it. Like branch K's narrowed pass, a pruned pass neither
acknowledges an `fsync` nor stamps `update_tid`: both wait for the 3.2.7
machinery that can protect them, and the 3.0b exit reads the full round's
cost for the same reason. S5 then rests on the two-half proof without
spending it: no acknowledgment leaves the holder on a pruned "verified at
T", so a holder dying before the next full round leaves the election
reading an older stamp that no released write depends on. A full round
that acts after pruned verifications is still a safety event: one named
line, pruned passes disabled (unpruned verification only) until the design
is re-audited, and the K-th round retakes the target. The stamp is never
lowered here because a pruned pass writes none; any lowering belongs to
3.2.7b, where acknowledgments first exist, and is read there. Read in
3.0b.2 only what exists then: a slave key altered inside a pruned range,
then the K-th round, and the detection line and the retaken target must
read.

**The comment conflict.** Upstream says `modify_tid` "is not propagated"
(`hammer2_flush.c:269-271`) while `hammer2_flush.c:885-887, 932-933`
propagate it upward at flush time; the lever's dependence on the carried
flush's ancestor restamp is named and XXX-marked. Dillon's "skipping
elements with matching modify_tids" (`DILLON_HAMMER2_DESIGN_2015.md:341-342`)
relies on a syncing node raising `modify_tid` only when the whole
sub-hierarchy is synchronized (`:326-329, 320-322, 337-339`), which the
port's flush does not do; a generation cut is a different mechanism, and
the section states so rather than claiming his premise.

**The destroy bound and the resumed segment.** A destroy marks its parent
modified at its own tid (`hammer2_chain.c:3450`), restamping the parent,
with higher ancestors following only at flush time (see the source half
above). A below-threshold root therefore holds no *flushed* insert or
destroy since the last verification and needs no tombstone feed for keys
the skip never visits; an in-window destroy restamps its parent at
`G + 1` and so falls outside a later pass's pruned range (amendment,
item 1). The merge's destroy-before-sweep order
applies within traversed ranges, and the destroy-in-a-narrowed-call shape
the plan leaves undriven is driven here as the control: a destroy inside
a would-be-pruned range must either keep the range unpruned or arrive
through the traversed path, never vanish inside a skip. A
segment the 1000-deferral cap stops (`hammer2_synchro.c:2589-2595`)
resumes from the lowest key not yet compared on either cursor past the
cap's break, on snapshot passes only (the resume consumer is gated on
`walks` at `:830-836`, and `walks` is snapshot-only at `:696-704`); the
prune threshold and the resume key travel together
per round, and a 1a segment resumed in a round after the first is read
with pruning on, since no run has produced one.

**The wire record.** Over the wire the skip record is a feed the client
refuses today, so the feed type, the client's shape test and the version
gate move together. The generation does not fit `dmsg_hm2_xop.reserved`
(`dmsg.h:594`, size pinned at
`hammer2_remote.c:116-117, 326`, the new-type gate at `:319-323`, PROTO2
gates at `:254-255, 1397, 2644`, unknown-feed refusal at `:1997-2002`);
the request grows behind the version while `dmsg_hm2_feed` has room for
the record (`dmsg.h:599, 609`). A remote source's generation travels on
the snapshot reply's closing frame from the master's device, in the
field and under the flag the amendment's item 6 names, and the
last-verified generation is bound to the attachment instance (item 4),
since under the lease a term or holder change means another device and
counter.

## What this note does not settle

- B's design: the commands, the frame check, the flow control and the
  daemon. The ruling of 2026-10-19 chose B, and the joint note with P8's
  quorum protocol, `doc/CLUSTER_PROTOCOL_DESIGN.md`, is where it is
  designed: the XOP API as the HM2 commands, `DMSG_SPAN_PROTO_2`, CRCs
  verified by the kernel, a span-derived element whose replies are
  chains of a media-less device, and the quorum protocol's four
  decisions, the first taken in that note as one writer per PFS under a
  durable lease and the other three carrying recommendations. Its
  stages 1 and 2 are built and this note's pass runs over them.
- The live-mount handoff. Where the chains of an open file go when the
  root under it is swapped is unanswered in every tree. The local half
  did not build the swap: the slave is written in place and a snapshot
  of it is the last known-good copy, and the property the swap protects
  has no reader here, so it stands as `DEFER(a consumer that reads a
  slave element directly, a static mount or a standalone slave mount)`
  in the section above.
- Whether the snapshot's blockset copy, one element's at `hammer2_ioctl.c:1120` under
  upstream's "doesn't work with real cluster", is enough for a snapshot
  taken as a source. For a single-element master it is; for a two-master
  cluster the snapshot is of one element, and whether that is the right
  source is P8's question as much as P7's.
- Who holds the keys. The harness's daemon, `test/h2service.c`, dials
  only a peer with a `.pub` or `.none` file in its key directory, and
  every link today is the `.none` kind, plaintext; keys move to `tlshd`
  with kernel TLS in P8's TLS stage, after which P7 closes.
- The `copyinfo[]` array the document retired and the format kept now
  has a role: the kernel registers a remote master's span only against
  an enabled row whose cluster id matches (`hammer2_remote_admitted()`,
  `hammer2_remote.c`), and `HAMMER2IOC_REMOTE_ADD` writes the row.

## Provenance

- **Matthew Dillon's HAMMER2 design document, 2015-04-03 (v3)**, the
  local copy `doc/research/primary/DILLON_HAMMER2_DESIGN_2015.md`, captured
  2026-10-10 as `doc/research/primary/PROVENANCE.txt` records. Line
  numbers above are that file's: the roadmap at 24-30, the status table
  at 60-77, the logical synchronization bullet at 132-135, `modify_tid`
  at 327-348, cluster membership and node types at 519-567, the four
  protocols at 569-626, synchronization and reintegration at 628-681.
- **`src/sys/sys/dmsg.h`** in this tree, vendored from upstream's
  `sys/sys/dmsg.h` at `250a8b4`: the protocol spaces, the four command
  sets, `DMSG_HM2_OPENPFS` and the comment naming four undefined `HM2`
  commands.
- **The DragonFly clone at `250a8b4`**, `~/Projects/dragonfly-hammer2-upstream`,
  its sparse checkout widened on 2026-10-17 to `sys/dev/disk/xdisk`,
  `sbin/hammer2` and `lib/libdmsg`: `xdisk.c` 1347 lines,
  `subr_diskiocom.c` 669, `cmd_service.c` 1074, `libdmsg/crypto.c` 777,
  `libdmsg/msg.c` 2759, by `wc -l`; the `#if 0` cluster-id branch in
  `hammer2_ioctl_pfs_snapshot()` and its comment, read from
  `sys/vfs/hammer2/hammer2_ioctl.c` there.
- **This tree at `5078090`**: `hammer2_synchro.c`, `hammer2_vfsops.c`,
  `hammer2_ioctl.c` and `hammer2_disk.h` at the lines cited, and
  `command grep -rn pfs_subtype src/` for the reader count.
- **The kernel of record**, `~/kernels/linux-7.3` (read at rc5, unchanged at the
  release): `drivers/block/nbd.c`
  2806 lines by `wc -l`, and `CONFIG_BLK_DEV_NBD` unset in its `.config`.
- **The handoff**, `proposals/hammer2-completion-handoff/`: the P7 entry
  and its five exit criteria in `HAMMER2_AGENT_WORK_QUEUE.yaml`, section 9
  of `HAMMER2_AGENT_HANDOFF.md`, section C of `HAMMER2_COMPLETION_SPEC.md`,
  and S10, L2, L4 and the reintegration model of
  `HAMMER2_CLUSTER_STATE_MODEL.md`.
- **The port's own readings**: `cluster-sync.sh`, `cluster-quorum.sh` and
  `cluster-dmsg.sh` as recorded in `doc/README.roadmap.md`'s P4, P5 and P6
  rows and `doc/history/verification-record.md`, and the roadmap's
  2026-10-03 reading of the forge on the four cluster files' history.

**Audit.** An independent adversarial reading of this note, the 1.0.39
row, the roadmap and README edits and the two commit messages, before
any was published, refused sign-off on three counts and raised three
more, each checked against the sources before it was taken. A count of
five lines had been written as six; the debug protocol space, whose one
command the enumeration had left out, made the spaces with commands four
and not three; and `hammer2_synchro.c` had been called byte-identical to
upstream when it is 1749 lines to upstream's 1069 with 66 `XXX Linux`
marks, the three behavioral claims resting on it having been read true
independently. The roadmap naming the local half the next code while the
note disclaimed every decision is resolved above by the plan's own rules;
the 22-check figure is tied to the row it comes from; and the forge
reading on the file's history now cites the roadmap's recorded reading
rather than standing alone. Every citation, count and quotation the
reading verified is listed in its report, from the design document's
line ranges to the kernel configuration. The second round found one
defect the corrections had introduced, the provenance list still
counting three command sets where the body had been corrected to four,
and two wordings, a rule count and two lines past the wrap; the third
round read the corrected text.
