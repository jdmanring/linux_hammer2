# The cluster protocol: a master on another host, the quorum between masters, and the seven cluster ioctls

The joint design note for the remote reach of P7 and for P8. The
completion plan's rules say a decision that would change the media
format, the security model or distributed commit semantics stops at a
design note with alternatives and what each would have to prove, and that
the original protocol is reproduced before any replacement is weighed.
The remote reach was ruled B on 2026-10-19, a chain-level protocol in the
reserved `dmsg` space designed together with P8's quorum protocol as one
wire format, the daemon that holds the keys specified before any kernel
code (`doc/SYNC_DESIGN.md`, "Ruling, 2026-10-19"). This note is that
design. It settles what the research settles, and it records four
decisions that change commit semantics or the security model, each with
its alternatives and its proof obligations; where a decision turned out
to be an order of work rather than a choice between ends it is taken
inside the delegated work and said to be, and nothing is parked.

Read against the DragonFly clone at `250a8b4` with `lib/libdmsg` and
`sbin/hammer2` in its sparse checkout, Dillon's 2015 design document in
`doc/research/primary/DILLON_HAMMER2_DESIGN_2015.md`, the handoff's sixth
work package and security model under `proposals/hammer2-completion-handoff/`
(`HAMMER2_AGENT_HANDOFF.md`, sections 10 and 19), its cluster state model
(`HAMMER2_CLUSTER_STATE_MODEL.md`, invariants S1 to S10 and L1 to L4), the
kernel of record's `net/handshake/`, and this tree at `3ba554c`. Every
`file:line` below was read at that commit; the ones in tables are checked
by `script/test-citations.sh`.

## What the research established

Nothing remote exists in any tree. Upstream's seven cluster ioctls are
`copyinfo[]` bookkeeping: `REMOTE_SCAN`, `REMOTE_ADD` and `REMOTE_DEL`
read and write `voldata.copyinfo[]` and send one `LNK_HAMMER2_VOLCONF`
through `hammer2_volconf_update()`, `REMOTE_REP` and `SOCKET_SET` return
without doing anything, and `SOCKET_GET` returns `EOPNOTSUPP`
(`sys/vfs/hammer2/hammer2_ioctl.c:244-408` upstream); `RECLUSTER` takes
a descriptor and is the intake the port has since 1.0.33. The HM2 command
space has one `#define`, `DMSG_HM2_OPENPFS`, whose structure
`dmsg_hm2_openpfs` is defined nowhere; the VOP space has no command. The
kernel handles `LNK_CONN`, `LNK_SPAN`, `LNK_HAMMER2_VOLCONF` and
`DBG_SHELL` and nothing else. Kusumi's three ports carry none of it.

The original's own design for a remote element is written in a comment
the port carries, `hammer2_iocom.c:282-292`: remote PFSs "look similar to
local (direct storage) PFSs", "are merged with local PFSs", and "are
object-based and operate using an (inode,key) DMSG API instead of
hammer2_chain's + direct I/O. A high level XOP API is employed to retain
integrity across operations such as rename()s." The older comment in
`dmsg.h` lists chain-level operations (`LOOKUP`, `NEXT`, `LOCK`, `UNLOCK`,
`RESIZE`, `MODIFY`, `CREATE`, `DUPLICATE`, `DELDUP`, `DELETE`,
`SNAPSHOT`). Both are inside B. The `iocom` comment is the later intent,
it names the XOP layer the port already has, and it says remote PFSs do
not use chain operations; the chain-op list is the alternative this note
records and declines.

The port's XOP layer is synchronous and element-indexed, and every
property the remote element depends on was read:

| where | what it fixes |
|---|---|
| `hammer2_admin.c:393` | `hammer2_xop_start_except()` runs each element's storage function inline, in slot order, holding the inode dependency it took first |
| `hammer2_admin.c:456` | `chain` must be set on `ip1->cluster.array[i]` for the element to enter `chk_mask`, so a slot with no chain is never run |
| `hammer2_admin.c:467` | an element that joins under a running XOP is not run, and `pr_notice_once()` says so once; registration can race a frontend XOP on a PFS mounted read-only, so it is not a warning |
| `hammer2_admin.c:658` | `hammer2_xop_feed()` indexes `collect[clindex]`, takes `hammer2_chain_ref_hold()`, and doubles every FIFO rather than refusing |
| `hammer2_admin.c:750` | the collect's advance drops the previous chain with `hammer2_chain_drop_unhold()` |
| `hammer2_admin.c:503` | `hammer2_xop_retire()` caches the XOP's chains on the inode past the XOP, with a reference |
| `hammer2_cluster.c:179` | `nquorum` is `pfs_nmasters / 2 + 1` |
| `hammer2_cluster.c:285` | `umasters` counts a master slot with no chain and no `CITEM_NULL` flag |
| `hammer2_cluster.c:355` | `HAMMER2_ERROR_EINPROGRESS` is returned while enough masters are still in progress to reach the quorum |
| `hammer2_cluster.c:364` | too few masters agreeing on the key returns `ESRCH`, and the tid disagreement `EDEADLK` below it |
| `hammer2_cluster.c:382` | a quorum whose agreeing masters all errored returns `EIO`, reachable only with a quorum |
| `hammer2_chain.c:849` | `hammer2_chain_drop_data()` panics "data not NULL" for a chain with data and no `dio`, every type but VOLUME and FREEMAP |
| `hammer2_chain.c:1164` | `hammer2_chain_unlock()` calls it on every last unlock |
| `hammer2_chain.c:1027` | `hammer2_chain_load_data()` returns before touching the device when `chain->data` is set or the block part of `data_off` is zero, and reads through `hammer2_io_bread()` otherwise, an I/O error becoming the chain's `EIO` |
| `hammer2_io.c:882` | `hammer2_io_bread()` is the read path from a chain to its device; `hammer2_io_new()` is the path for a chain being created, and `load_data` takes it for an `INITIAL` chain |
| `hammer2_io.c:226` | `hammer2_get_volume()` is reached on a dio-hash miss before the dio is allocated, and panics with no volume for the offset; `hpanic` sets the host-wide `hammer2_device_error` |
| `hammer2_io.c:803` | `buf`, the no-folio block, is freed at the dio's last drop, and a dirty one is written through `bdev_file`'s mapping first |
| `hammer2_synchro.c:1537` | `hammer2_xop_start_except()` with the pass's own index excludes the target element from the source scan |
| `hammer2_synchro.c:1612` | a pass ends on any collect error but `ENOENT` |
| `hammer2_vfsops.c:314` | `hammer2_pfsalloc()` merges every PFS root sharing a `pfs_clid` into one `pmp`, and a later mount joins an existing one |
| `hammer2_vfsops.c:459` | `pfs_nmasters` is raised to the on-disk field and then to the count of visible masters |
| `hammer2_vfsops.c:497` | `pfs_nmasters` at one or below is the only case in which a MASTER element gets no sync thread |
| `hammer2_vfsops.c:801` | `pfs_hmps` selects the slots the unmount removes, those of the device going away; each slot's thread is deleted and the `pmp` freed when no slot remains |

No tree writes the on-disk `pfs_nmasters` at creation. Upstream reads it
at mount and decrements it on destroy (`hammer2_vfsops.c:535-550`,
`:635-636` upstream); the port writes it nowhere. So a master today counts
the masters it can see, and a master cut off from its peer has a quorum of
one. Dillon's quorum section (`DILLON_HAMMER2_DESIGN_2015.md:683-781`)
says the hard-block form "is easy to deal with" when "your MASTERs are
all local mounts"; on a network "masters cannot rely on clients to
moderate quorum transactions", masters "run a 2-phase commit amongst
themselves", a client "can submit modifying operations to a single
master" and "must still validate the quorum" for reads, with four client
acknowledgment modes, and the transaction log is "a separate development
task", which is P9.

The kernel verifies no CRC and keeps no span table. `kdmsg_iocom_thread_rd()`
checks the magic, the header size and the 1 MiB aux bound
(`kern_dmsg.c:342-378`); the CRCs are generated on transmit over the
aligned header with `hdr_crc` zeroed and over the aligned aux
(`:2053-2060`), which is what `libdmsg` computes too, and `dmsg_icrc32` is
`iscsi_crc32`, the port's CRC-32C mapping (`hammer2_compat.h:156`).
Received spans are open transactions under `state0`, and
`hammer2_autodmsg()` monitors them (`hammer2_iocom.c:296`): a span whose
`peer_type` is not HAMMER2 or whose `proto_version` is not
`DMSG_SPAN_PROTO_1` is closed with a reply, and only a `PROTO_1` HAMMER2
span, since stage 1 also a `PROTO_2` span from a connection that
announced it, is left open with a result (`:357-393`). The kernel fills its own
spans with `peer_id` set to the PFS's `pfs_clid`, `pfs_id` to its
`pfs_fsid`, `pfs_type` from the root inode and `proto_version` 1
before stage 2a, `PROTO_2` since (`:451-455`); a span carries no root inode. `msgid` is the kernel
address of the transaction's state (`kern_dmsg.c:1849`), and
`link_verifier` is read nowhere in `kern_dmsg.c`.

Two kernels are needed to test remoteness, since `hammer2_pfsalloc()`
makes two volumes in one kernel local elements of one cluster; the host
kernel is below the floor, so the second kernel is a second guest. The
deterministic loopback `test/h2loop.c` plays both kernel roles itself and
`test/h2attach.c` puts one kernel against a userland peer; neither relays
between two kernels yet.

Linux's native key and cipher mechanism for a kernel socket is kernel TLS
with the handshake upcall: `tls_client_hello_x509()`, `_psk()`, `_anon()`
and the server forms in `include/net/handshake.h`, used by NVMe-TCP and
sunrpc, where the agent `tlshd` holds the certificates or PSKs and
promotes the socket to the TLS ULP, so the kernel never sees a key.
`CONFIG_NET_HANDSHAKE` is a `bool` with `default y` and no prompt,
depending on `SUNRPC || NVME_TARGET_TCP || NVME_TCP`, none of which the
guest kernels set, and `CONFIG_TLS` and `CONFIG_CRYPTO_GCM` are unset in
them. DragonFly's `/etc/hammer2/remote/<name>.pub` and `<name>.none`,
with "auth failure: unknown host" when neither exists
(`lib/libdmsg/crypto.c:390-398` upstream), are the admission semantics
to preserve.

## The wire format

**The frame is DragonFly's.** `dmsg_hdr` is unchanged: magic, salt,
`msgid`, `circuit`, `link_verifier`, `cmd` with its flags and size,
`aux_crc`, `aux_bytes`, `error`, `aux_descr`, `hdr_crc`, 64-byte
alignment, `DMSG_HDR_MAX` 2048 and `DMSG_AUX_MAX` 1 MiB. A frame in a
protocol space the connection's peer did not announce ends the
connection as a bad magic does today.

**The vocabulary is the XOP API, in the HM2 space.** The 21 descriptors
`hammer2_admin.c` declares with `H2XOPDESCRIPTOR` are the commands, in
declaration order:

| index | descriptor | command | stage |
|---|---|---|---|
| 0 | `ipcluster` | `DMSG_HM2(0x010, dmsg_hm2_ipcluster)` | 2 |
| 1 | `readdir` | `DMSG_HM2(0x011, dmsg_hm2_readdir)` | 2 |
| 2 | `nresolve` | `DMSG_HM2(0x012, dmsg_hm2_nresolve)` | 2 |
| 3 | `unlink` | `DMSG_HM2(0x013, ...)` | 3 |
| 4 | `nrename` | `DMSG_HM2(0x014, ...)` | 3 |
| 5 | `scanlhc` | `DMSG_HM2(0x015, dmsg_hm2_scanlhc)` | 2 |
| 6 | `scanall` | `DMSG_HM2(0x016, dmsg_hm2_scanall)` | 2 |
| 7 | `lookup` | `DMSG_HM2(0x017, dmsg_hm2_lookup)` | 2 |
| 8 | `delete` | `DMSG_HM2(0x018, ...)` | 3 |
| 9 to 16 | `inode_mkdirent`, `inode_create`, `inode_create_det`, `inode_create_ins`, `inode_destroy`, `inode_chain_sync`, `inode_unlinkall`, `inode_connect` | `DMSG_HM2(0x019 ... 0x020, ...)` | 3 |
| 17 | `inode_flush` | `DMSG_HM2(0x021, ...)` | 3 |
| 18 | `strategy_read` | `DMSG_HM2(0x022, dmsg_hm2_strategy)` | 2 |
| 19 | `strategy_write` | `DMSG_HM2(0x023, dmsg_hm2_strategy)` | 3 |
| 20 | `bmap` | `DMSG_HM2(0x024, dmsg_hm2_bmap)` | 2 |
| reply | `dmsg_hm2_feed` | `DMSG_HM2(0x030, dmsg_hm2_feed)` | 2 |

`DMSG_HM2_OPENPFS` at `0x001` stays reserved and unused. `DMSG_HM2()`
encodes the structure's size into the command, so every command names
its structure: the request structure is one for all 21, `dmsg_hm2_xop`,
128 bytes, the header followed by the cluster id of the PFS the request
is for, the inode number the XOP runs under, two keys, two flag words
and a count, which the XOP arguments below reduce to; the reply
structure is `dmsg_hm2_feed`, 256 bytes, the header followed by a
`hammer2_blockref_t`, `bytes` and `error`, under its own command
`DMSG_HM2_FEED` at `0x030`, since a frame's size is the one its command
encodes and a feed is larger than a request. A request frame is the
command with `DMSGF_CREATE` and without `DELETE`, since the continuation
below needs the peer's direction open and a one-shot request is refused,
carrying the XOP's arguments that are not
pointers: the inode's key, the directory's key, `lkey` and `rkey` and
`nmax` for `readdir`, `lhc` for `scanlhc` and `lookup`, `key_beg`,
`key_end`, `resolve_flags` and `lookup_flags` for `scanall`, `lbase` for
`strategy_read`, `lbn` for `bmap`, the name as aux where the XOP carries
one. The lock modes a scan runs under come from no frame: `scanall` runs
shared, resolving data, as the slave's own source scans do, and the
request's `lookup_flags` contribute `HAMMER2_LOOKUP_NODIRECT` alone,
whether a direct-data inode answers a scan beneath it as itself;
`NODATA` would change nothing, since the server's scan runs with
`HAMMER2_LOOKUP_ALWAYS`, which resolves data whatever else is asked, and
is not carried. The first version carried `NODATA` alone, and the first wire run read the consequence: the
slave's pass asks for `NODIRECT`, the server's scan of a direct-data file
fed the file's own inode as its child, the pass inserted inode 0x405
beneath itself 1091 times ("parent set for direct-data pkey
0000000000000405 ckey 0000000000000405"), and the unmount's flush
recursed to its depth limit and put the device in error. The
reply is a transaction of frames on the same `msgid`: each
`DMSGF_REPLY` frame is a `dmsg_hm2_feed`, one chain's `hammer2_blockref_t`
and its `bytes` and `error`, with the chain's data as aux when the XOP
returns data, at most one logical block of 64 KiB;
the transaction's `DELETE` is a feed frame with no chain. With
`DMSG_HM2_FEEDF_EOF` in its `flags` its `error` is the element's final
one, the one `hammer2_xop_feed()` would have been given with a `NULL`
chain, or the server's own error ending the scan; without it the element
fed only chains, as `ipcluster` and `lookup` do, its `error` is zero, and
the client feeds no end, so the collect sees the element as a local one
ending the same way would leave it. The closing frame of a `readdir`
also carries `rkey`, the key the server's scan stopped before after
`nmax` entries, or the request's own `key_end` echoed when it did not
stop before it, which the client lowers its own `rkey` to: the frontend emits no entry at or past
it and starts its next XOP there, as it does for a local element that
stopped first, so an entry the peer has not fed is never passed over.
Without it a directory of more than `nmax` entries on the master listed
only the first `nmax` through a slave holding none of it: the wire run's
control, the client's lowering removed, listed 255 of 300
(`wire-run-20261020-234654`). The client takes the key only from a
clean end after a full batch, and only when it lies past every key the
peer fed, and every key a readdir feeds lies at or past the request's
start, so each XOP starts beyond the last: a peer's key at or below
what it fed would restart the frontend's loop at the same key without
end, uninterruptibly, holding the directory's lock, and an entry keyed
below the start would let the stopping key fall back to it. A
descriptor that answers one chain takes one feed and a readdir `nmax`,
and every descriptor's keys rise, each above the one fed before it, as
a scan of leaves feeds them, which with the hash range check bounds a
`scanlhc` to `HAMMER2_DIRHASH_LOMASK` + 1 feeds; the window bounds the frames in flight and not their total, so
a peer past any of these is refused like a frame that is not a proxy.
The server holds a peer's `nmax` to between 1 and 255, the frontend's
own bound, since a count of 0 or less would never stop its scan. A
`scanall` has no count but its range: the seek scan
(`hammer2_bmap_next_key()`) feeds every block from the offset to the
end of the file, on a local element as on a remote one, and over the
wire each block is a transfer with its data under the bound. SEEK_DATA
runs it once; SEEK_HOLE runs it once per block until a hole, so a
dense file of n blocks costs about n²/2 block feeds. Whether a large
remote file's seek outruns the bound is a candidate, unmeasured; its
trigger is the first SEEK_DATA or SEEK_HOLE through a remote element.
The scan needs only keys, but asking for none is not yet an upgrade:
the server's scan runs with `HAMMER2_LOOKUP_ALWAYS`, which resolves
data whatever else is asked, its feed ships every chain's data, and a
proxy needs data to be fed, so the request carries no `NODATA` and the
upgrade is those three together. A request the server will not serve is closed
by kern_dmsg's own `LNK_ERROR` reply carrying `DMSG_ERR_NOSUPP`, so the
peer tells a served request from a refused one by the closing frame's
command, and a served scan that found nothing reads as zero feeds and
error zero rather than as a refusal. A reply
frame with no data for a type that has data is a protocol error and ends
the connection.

**Versioning rides `proto_version`.** `DMSG_SPAN_PROTO_2` means "HM2 XOP
API version 1, CRCs verified". Today the carried test at
`hammer2_iocom.c:375-380` closes every span that is not `PROTO_1`, so
admitting `PROTO_2` edits that test, marked `XXX` as a core edit the
port could not avoid; a `PROTO_1` span stays open as today and never
becomes an element, and a span at a version the kernel does not know is
closed as today. A frame in the HM2 space on a connection whose peer
announced `PROTO_1` ends the connection, and a `PROTO_2` span on such a
connection is closed rather than listed, so nothing enters the span
table from a connection whose frames are not verified. The announcement
is the peer's `LNK_CONN`, read once: the flag it sets is the
connection's for its life, cleared by a reconnect and not by a `CONN`
`DELETE`, so a later `CONN` on the same connection can turn it on and
nothing turns it off. In stage 1 the kernel's own `LNK_CONN` and spans
stayed at `PROTO_1`, since it had no HM2 vocabulary to announce; since
stage 2a gave it the server side both announce `PROTO_2`
(`hammer2_iocom.c:190`, `:455`). `libdmsg` reads neither field
(no occurrence of `proto_version` under `lib/libdmsg/` at the DragonFly
clone's head), so the daemon relays them unchanged, and a DragonFly
kernel reading the span closes it. That is the compatibility plan the
extension rule asks for: an old reader sees spans and nothing else, as
it does now, and a `PROTO_1` kernel reading a `PROTO_2` span closes it.

**The kernel verifies `hdr_crc` and `aux_crc` on every frame of a
`PROTO_2` connection**, because it acts on those frames. A mismatch ends
the connection with a named log line, as a bad magic does. `PROTO_1`
connections keep today's behavior, so `cluster-dmsg.sh`'s existing
readings hold. The porting document's paragraph calling this "a protocol
change weighed on its own" is rewritten with this weighing.

**Flow control** is a window of `HAMMER2_XOPFIFO` (16) feeds per request:
the server stops at the window until a continuation frame (the request
command with `DMSGF_REPLY` clear and `CREATE` clear, on the same `msgid`)
arrives. The window bounds frames in flight on the link. It does not
bound the XOP's memory, since `hammer2_xop_feed()` grows every FIFO
rather than refusing and nothing drains a FIFO while a storage function
runs, so a reply's chains are all held before the collect, as a local
element's are. The window is enforced where it can be read, at the
client's receive: a server past the window ends the connection with a
named log line and the element errored.

## The remote element

**A remote element is a span-derived element**, as the carried comment
says. A `LNK_SPAN` with `peer_type` HAMMER2 and `proto_version`
`PROTO_2`, whose `peer_id` (the peer's `pfs_clid`) names a cluster id a
local `pmp` carries and is admitted by a `copyinfo[]` row with that
`pfs_clid`, and whose `pfs_type` is MASTER, is a candidate; a SLAVE's
span is monitored and never registered, since the only consumer of a
remote element in P8 is a quorum vote or a synchronization source and a
remote slave is neither. A per-connection registration work item, never the
server's queue, then fetches the remote PFS root (one `ipcluster`
request, the same frame shape as every reply) and registers the slot
with the root chain in hand, through
the steps a later local mount takes in `hammer2_pfsalloc()`
(`hammer2_vfsops.c:417-445`): `chain->pmp`, the reference, `array[j]`,
`pfs_types[j]` and `pfs_names[j]` from the root inode's data as that
path reads them from `ripdata`, with the span's `pfs_type` and `pfs_id`
checked against the root's `pfs_type` and `pfs_fsid` and a mismatch
registering nothing, `pfs_hmps[j]` the connection's device,
`pfs_iroot_blocksets[j]` from the root's data. Two steps of that path
are not taken for a remote slot: `mount_count` is not incremented,
since the device has no mount, the mount's and the unmount's loops
skipping a connection device by a test marked `XXX`
(`hammer2_vfsops.c:2103`, `:2667`), and **no sync thread is created**,
the registration in `hammer2_remote.c` not starting one. The thread would be the remote host's job for its own
element, and here it would walk its element by chains
(`hammer2_inode_chain()` at `hammer2_synchro.c:1560`, `chain_lookup` at
`:1578`, `chain_create` at `:2360`) through blockrefs that carry the
peer's real media offsets, and the first dio-hash miss would reach
`hammer2_get_volume()`'s panic, which sets the host-wide
`hammer2_device_error` and stops every device on the host writing. The
path also dereferences the chain, and a slot registered without one
would never run and would hold every collect on the PFS at
`EINPROGRESS`, so a span whose root cannot be read registers nothing,
logs once, and is retried when the connection is re-established, which
is the only retry the protocol offers: `hammer2_autodmsg()` has arms for
a span's `CREATE` and `DELETE` only (`hammer2_iocom.c:357, 395`) and
`libdmsg` sends `LNK_SPAN` only with `CREATE`, so there is no status
update to retry on. The fetch runs off the server's queue because two masters
span each other at once (the kernel spans every PFS,
`hammer2_iocom.c:440-444`), and a registration that waited on the one
thread that also serves the peer's requests would wait on a peer
waiting on it, both registrations failing at the bound. A span registers
against a `pmp` that holds an element on a block device of this host,
mounted or not. The first version of this note required a mounted
`pmp`, and the first wire run refuted it: a SLAVE alone has no master to
answer its root inode's collect, so its mount fails with `ENOENT`
(`hammer2_vfsops.c:1748-1752`, "failed to get root inode: 2"), and a
registration waiting for that mount waited for itself. DragonFly's mount
loops on that collect until a master appears; here the element comes
first and the mount follows it, which the harness reads as a SLAVE `CL`
that does not mount before the dial and does after. A remote slot on an
unmounted `pmp` would hold the `pmp` on `hammer2_pfslist` after its last
local device left, since `hammer2_pfsfree_scan()` removes only the
departing device's slots, so that function detaches every remote slot of
a `pmp` it touches before it removes the local one. In stage 2 a span
against a PFS mounted read-write is monitored and not registered, so the
read-only requirement holds at registration, and the mount and
`->reconfigure` hold it after, all three under `hammer2_mntlk` (the
client side section). The mount-time
`mount_count` increment for every slot (`hammer2_vfsops.c:2097-2105`)
skips a connection device by the same test as the other two sites.

Teardown is a port function, `hammer2_remote_detach(pmp, j)`, marked
`/* Linux */`: under `iroot->lock` it drops the slot's chain, clears
`iroot->cluster.focus` when that chain was the focus, as
`hammer2_pfsfree_scan()` does (`hammer2_vfsops.c:831-832`), clears
`array[j]`, sets `pfs_types[j]` to NONE, frees the name and the
`pfs_hmps` entry and recomputes `nchains` from the highest remaining
slot, the steps that function takes for a local device's slots
(`:799-842`) and nothing else of it, which freezes every thread, cleans
snapshots under `hammer2_mntlk`, syncs the PFS and remasters, and cannot
be called for one slot. It never frees a `pmp`: registration requires a
local element, and `hammer2_pfsfree_scan()` detaches every remote slot
of a `pmp` before it removes the last local one, so a detach cannot
empty a cluster, and `hammer2_pfsfree()` would in any case
assert `iroot->refs == 1` (`hammer2_vfsops.c:648-650`) on a mounted one;
the detach asserts that a slot remains. It runs under `hammer2_mntlk`,
the lock every walker of `hammer2_pfslist` holds (`:329`, `:731`,
`:3302`), and therefore never on the connection's reader thread: the
device unmount holds that lock through `hammer2_iocom_uninit()`
(`:2695`), which waits for the reader and writer threads to exit
(`kern_dmsg.c:257`), so a reader blocked on the lock would hang the
unmount with no bound. The reader queues the detach to the connection's
work item (the one registration uses). The work item takes the lock by
try-lock and requeues itself after a delay when refused, as the sync
pass retries on its next cadence (`hammer2_synchro.c:819`), so a refusal
does not spin a worker through a bulkfree scan's hold, because every
caller of
`hammer2_unmount_helper()` holds `hammer2_mntlk` (`hammer2_vfsops.c:1203`,
`:3302`) and that helper both tears the connection down
(`hammer2_iocom_uninit()` at `:2695`) and may drop a slot's last chain,
so a wait there on an item blocked in `hammer2_lk_ex()` would hold the
lock the item needs. The item is one per connection, on the device
carrying the link, and holds a reference on the connection device only
while it runs; it reads the span table afresh each run, registers what
is untried and detaches what has lost its span, so a run that finds the
work already done does nothing.
The device's free flushes nothing; the connection's teardown disables
the item, delayed work, with `disable_delayed_work_sync()`
(`kernel/workqueue.c:4729` in the kernel of record), since
`cancel_delayed_work_sync()` re-enables the work on return and refuses a
requeue only while it runs, and the teardown loses
nothing by it because it detaches every remote slot itself. The
teardown runs where `hammer2_mntlk` can be taken: in
`hammer2_unmount_helper()`, which holds it, and on a `RECLUSTER` that
replaces a connection, on the ioctl caller's thread, never on the
reader.
A long holder of the lock delays a detach that long: a bulkfree scan
holds it for its whole run (the comment at `hammer2_synchro.c:833`), and
the reader is not blocked by it. The detach runs on a span
`DELETE`, on a lost connection (`kern_dmsg.c` simulates the `DELETE`s at
link loss), and from `hammer2_pfsfree_scan()`, under the same lock,
for every remote slot of a PFS whose local device is leaving, since a
remote slot's `pfs_hmps` never equals that device and the `pmp` would
otherwise keep a slot and outlive its last local element. Registration
pins nothing across its round trip: the work item fetches the root
holding only the connection, then takes `hammer2_mntlk`, finds the `pmp`
again by `pfs_clid` on `hammer2_pfslist` as the mount's own walk does
(`hammer2_vfsops.c:329`), checks under the lock that it still has a
local element and is not mounted read-write, and registers; a `pmp`
freed between the fetch and the lock is not found and nothing
registers. Every inode's `ip->cluster.focus` is a copy
of the root cluster's taken without a reference
(`hammer2_inode.c:1596`); it is refreshed by the next collect and read
by no consumer between, and `RECLUSTER` no longer reads any focus (the
ioctls section). The connection's device is on no mount list: the
helper's `mount_count` accounting (`hammer2_vfsops.c:2662-2669`) skips
it by the same test, its `devvp_list` is initialized empty because
`hammer2_register_sb()` walks every slot's list
(`hammer2_ondisk.c:139-143`), and it is freed by a reference count the connection device alone
carries (`struct hammer2_dev` has none, `hammer2.h:919-969`, only
`mount_count` and `iofree_count`): one reference per chain allocated on
it, taken in `hammer2_chain_alloc()` (`hammer2_chain.c:176`) and dropped
where the chain is freed (`:837`, not at `hammer2_chain_lastdrop()`'s
entry, which returns early for a chain that keeps children), two marked
lines, the link's own, dropped by its teardown, and the registration
item's, taken only while it runs.
The device's dios are not counted: a dio stays in the hash at its last
release (`hammer2_io.c:803-822`) and is freed by
`hammer2_io_hash_cleanup_all()` in the device's own free, as the block
device's are at `hammer2_vfsops.c:2781`, so a count on them would hold
the device forever.

**Replies become ordinary chains of a media-less device, and
`hammer2_chain.c` is not edited for them.** The note's marked lines in
that file are listed in one place, under the test topology, so the XXX
table's count can be read against them. Each connection owns a `hammer2_dev` with no
block device, no `spmp` (`hammer2_chain_alloc()` compares the PFS it is
given with the device's `spmp` and keeps a non-`NULL` one), a dio hash,
and a handle table. A reply's chain is allocated against the device
with the peer's blockref and a synthetic `data_off`, a per-connection
handle number in 64 KiB units, never zero, with the block's radix; the
handle table maps the number to what the peer needs to find the chain
again: for an inode chain its own inode number, fetched by `ipcluster`,
and for a data or directory chain the inode the request ran under and
the chain's key, fetched by `lookup`. A handle stands for one block
version, the peer's `data_off`, which the peer's media does not reuse
while the block is live, under one of those identities: a deduplicated
block is live under two files' keys, and a refetch by the first file's
key would hand the second file the first file's current block, so a
feed whose block has a handle under another identity takes one of its
own. Two feeds of one version under one identity share a handle and
its dio, and the table grows with the versions a connection sees; it is
freed with the device, and pruning it is recorded at the definition
with the reading that would call for it. Only leaves are fed, since
`chain_lookup` and `chain_next` return leaves, so no indirect block is
ever a proxy.

**What a client refuses of a feed.** A blockref from the peer reaches
carried code that trusts the media for what the media's own writer
guarantees, so every block is checked where it enters, at the feed and
again at a refetch, since a block's check code is tested at its first
load and not after. Refused, and fed as a feed that is not a proxy,
which ends the element with `EIO`: a type other than an inode, a data
block or a dirent; a check method `testcheck` does not know, whose
default arm `hpanic`s every device on the host; a compression the
decode does not know; `keybits` past 63 or a key not aligned to it,
which the slave's pass copies into its own media and the core shifts
by; a dirent whose name is not where the media keeps it, in the
blockref up to its 64 bytes and in a block of at least its length past
them, since readdir picks one by the length; an inode block shorter
than an inode or whose name is longer than its 256-byte array; a block
whose size its radix does not give; a chain the request could not be
answered with, by its type and key: for `ipcluster` an inode of the
number asked for, for `readdir` and `scanlhc` a directory entry or an
inode, the first at or past its start key and the second in its hash
range, for `nresolve` an inode or an entry carrying an error, for
`scanall` its key range, for `lookup` an inode of the number asked for,
and for a read or `bmap` the data block covering the offset or
the file's own inode, which the core's lookup returns for every key of
a direct-data file, for a read only at offset 0 since the read
completion refuses an inode anywhere else (`hammer2_strategy.c:417-420`);
an errored inode is taken as the file's, since its frame carries no
number to check; a refetched block whose
compression and check methods differ from the blockref the proxy keeps,
which the consumer decodes it under; and a feed of an inode or data
block with neither bytes nor an error. The wire harness's two controls
drive two of these refusals. Under `H2_WIRE_REKEY=1` its relay moves
the key of the first data block fed, the `bmap` of a file's first
block, one block up and signs the frame again, and the slave refuses
that feed and fails the call, so fiemap reports the error
(`wire-run-20261021-013407`, debug kernel); a check refusing nothing
would have listed the block as an extent. Under `H2_WIRE_DIRENT=1` the
relay turns the inode answering the first `nresolve`, the slave's stat of
a file, into a directory entry with no bytes, and the slave refuses that
feed and fails that one lookup, every file then reading equal to the
master's (`wire-run-20261021-022837` at `2c06405`, debug kernel); with `nresolve`
taking any entry, as it did before this check, the same control faulted
the slave through a null pointer in `hammer2_inode_get()`
(`wire-run-20261021-020154`). What is not checked is what the media does not constrain either:
an inode's other fields, a data block's content and a directory's
entries are the peer's, as a local volume's are whoever wrote it.
That includes content that reaches a warning: a compressed block whose
length word or stream does not decode (`hammer2_strategy.c:211`, `:219`,
`:290`) and an inode with no links (`hammer2_inode.c:850`) each warn
once through `WARN_ONCE` and fail the read with `EIO` or answer one
link, as the same bytes on a local volume do. A host booted with
`panic_on_warn` therefore admits a peer only on the terms it mounts a
volume it did not write, trusting the writer. A frame's shape is the
other kind: an inode fed for a read past a file's base is a frame no
honest peer sends, and the range check refuses it before the read
completion's warning sees it (`hammer2_strategy.c:417-420`). So is a
directory entry answering `nresolve` or `lookup`: both callers read the
answer as an inode (`hammer2_inode.c:1021-1022`, `:2006`), and an entry
with its name in the blockref has no data, so the read is through a
null pointer, a fault rather than a warning. The local storage
functions never feed one, since `nresolve` resolves its entry to the
inode (`hammer2_xops.c:267-272`) and `lookup` runs on the PFS root,
whose children by number are inodes.

**A block only the peer holds has no address here.** `bmap` answers
with the offset of the local element's block, and a remote element has
none to give. The XOP's offset is whichever element ran last, which
may lack the block or hold an older one, so the address is the focus's
own; with a remote focus it is taken from a local element the quorum
check matched to the focus by key and `modify_tid`, and a file or a
block no local element matches reports no physical address: fiemap marks its extents
`FIEMAP_EXTENT_UNKNOWN` and FIBMAP returns 0, as for a hole
(`hammer2_bmap_offset()`). The wire run drives the case with no local
element, its slave held empty. A local element matched to the focus,
and one holding the inode but lacking the block or holding an older
one, are in the code and not driven by a run, since each needs the slave
to have copied from the master, and no run on the code committed reads
a slave that copied: the wire run holds the slave empty. Two kept runs
had the pass copy the master's tree into the slave over the wire,
`wire-run-20261020-200029` and `-203127`, on uncommitted code before
`0d0717d`; the first shows the direct-data insertion described above, ending in
the flush's depth limit, and the second ended in a circular locking
report, so neither is a reading of the pass. `1eae1d3`'s message says no
run has driven the pass over the wire, which those two contradict; the
true statement is this one. The run that reads the pass is what the
roadmap lists as the rest of stage 2b.
That run is the trigger, and it has the hold the stale case needs: the
pass refuses on a device opened read-only, so the slave's device
reopened read-only after the copy and dialed again, with the file then
changed on the master, reads the stale case, and a file left unchanged
the matched one, whose address the old code reported too.

The reply's data is copied off the reader thread into the frame, and
the feed stashes it on the handle before it locks the new chain; the
lock's `load_data` reaches the device's `hammer2_io_getblk()`, which
takes the stash, so the first load costs no round trip. The block then
lives in a `hammer2_io_t` whose `buf` field, the form the port already
has for "the block when the page cache had no folio for it", holds it,
served by `hammer2_io_data()`. `hammer2_io_putblk()` frees `buf` at the
dio's last drop (`hammer2_io.c:803-816`), so a proxy kept past its XOP
(the retire's ccache, `ip->cluster` through `hammer2_inode_repoint()`,
the registered root) has no data, and **every later load refetches**: the
device's read looks the handle up and issues one request under the
bound. The refetch fills the block and nothing else: the proxy keeps the
blockref it was fed, and a load after the first does not test the check
code again (`hammer2_chain.c:1115-1119` tests it only while
`HAMMER2_CHAIN_TESTEDGOOD` is clear), so a block the peer has rewritten
since reads its current content under the old blockref, as a local
chain read under another thread reads what that thread has made it. A
handle the peer no longer resolves reads `EIO` through the path
`load_data` already has (`hammer2_chain.c:1079-1085`) and the element is
errored, never a fault; the next XOP feeds a fresh proxy. The count
varies between runs of one module: two runs of the wire harness on the
debug kernel with the module built from `1eae1d3`'s source (sha256
`8b22d977871bbec1`), kept as `wire-run-20261021-005246` and `-013044`,
read 1 and 0 refetches, each in 879 remote XOPs.

**The round trip holds no dio lock and no hash lock.**
`hammer2_io_alloc()` runs under `iohash_lock` exclusive and
`hammer2_io_hash_lookup()` takes `dio->lock` under it, so a wait inside
the DIO layer would hold `dio->lock` for the round trip while a second
thread on the same handle waited for it holding `iohash_lock`, which
serializes every DIO lookup on the device for a round trip. The
connection device's read path therefore fetches before it touches the
hash: `hammer2_io_getblk_conn()` looks the dio up and returns a GOOD one
at once, takes a reference on one that is not GOOD and drops its lock,
performs the fetch with no DIO lock held, and only then enters or
relocks the dio and fills it; a dio another thread filled meanwhile
keeps its block and the fetched one is freed. Two threads refetching one
handle send two requests; sharing one is recorded at the fetch with the
reading that would call for it. That is the object-based `(inode,key)`
API the carried comment describes, in the DIO layer, and refetch is the
normal path rather than the upgrade. So `load_data`, `unlock`,
`drop_data`, `lastdrop`, the ccache and `repoint` all run the carried
code unchanged. The dispatch between the block-device and handle forms
is in `hammer2_io.c` at three sites, each marked `/* Linux */`: the entry
of `hammer2_io_getblk()`, which every read, quick read and create goes
through; `hammer2_io_alloc()` before `hammer2_get_volume()`
(`:218-235`), where a miss on the media-less device must never reach
the volume lookup's panic; and the last drop, where a dirty block on the
device is refused rather than written through a `bdev_file` it does not
have. A fourth site is outside the DIO layer: `statfs` took the first
non-NULL `pfs_hmps` and would have read the connection device if a
remote slot ever preceded the local ones, so it takes the first slot on
a block device, `hammer2_pfs_first_bdev()` (`hammer2_vfsops.c:2321`),
the pick the remote-row ioctls and `RECLUSTER` share. A chain being
created (`hammer2_io_new()`, the `INITIAL` path) is refused on the
device with `WARN_ONCE` and reads `EIO`, since proxies are never created
locally and no write is sent to it in stage 2. One dispatch sits above
the DIO layer: `hammer2_xop_start_except()` calls the descriptor's
storage function per slot (`hammer2_admin.c:477-481`), and the marked
test there runs `hammer2_remote_xop()` first, which answers for a slot
whose `pfs_hmps` is a connection device, read under the root inode's
cluster spin that the registration and the detach write it under, and
feeds the closed-connection code for a slot holding a proxy whose device
is no longer the slot's. A chain with data and no `dio` was the first
shape considered and is not one the core allows:
`hammer2_chain_drop_data()` panics on it at the first last unlock, which
the collect's advance reaches on the first two-entry `readdir`. The
device is counted by its chains, the link and the work item while it
runs, and freed after the last, not at disconnect, because the ccache
and `ip->cluster` hold proxies past the XOP and past the connection.

**Alternatives recorded and declined.** A `NULL` slot with a side table
for the remote state fails at `hammer2_admin.c:456`, which never runs it,
and at `hammer2_cluster.c:285`, which counts it in progress forever. A
chain-owned data buffer with `dio == NULL` fails at
`hammer2_chain.c:849`. Both are what a reader of the plan expected to
work, and both were refuted on the cited lines before any code.

## The server side

The reader thread never runs chain code. Each device has one ordered
workqueue, `hammer2_remote.c`, which is the design's service thread in
Linux's own form: one request runs at a time per connection, the reader
queues each HM2 request to it as a work item, and the connection's end
is a drain of that queue rather than a thread's lifecycle. A request
runs the local backend for the local element it names (the XOP's
storage function on the local chain for that slot alone), feeds one
reply frame per chain, honoring the window, and closes the transaction
with the element's final error. **The server resolves the request's
inode without an XOP.** The request names the inode by number; the
server resolves it with `hammer2_chain_inode_find()`
(`hammer2_chain.c:5479`), the nresolve hardlink arm's own path: it tries
`hammer2_inode_lookup()` (`hammer2_inode.c:556`),
which finds an inode already in memory and takes no dependency, and on
a miss finds the inode's chain by `hammer2_chain_lookup()` under the
local root, the PFS's inode tree keyed by inode number. The storage
function then runs on a server-side inode handle, a `hammer2_inode_t`
outside the inode hash holding that chain in the slot, its cluster set
in place since `hammer2_inode_repoint()` is the inode file's own, which
`hammer2_inode_chain()` reads under `cluster_spin` (`:404-428`, "The
inode does not have to be locked"), and the handle is dropped as any
inode is. `hammer2_inode_get()` is not used,
since it needs a collected XOP on the parent and that XOP takes the
dependency. The proof obligation, listed function by function in stage
2a's record, is that each read storage function reads nothing of `ip1`
but its cluster slot; the call sites are `hammer2_xops.c:141, 173, 244,
792, 891` and `hammer2_strategy.c`'s read. One of them indexes by slot:
`nresolve`'s hardlink arm calls `hammer2_chain_inode_find()` with the
request's `clindex` on the server's own `pmp` (`hammer2_xops.c:271`),
which reads that `pmp`'s inode at that slot (`hammer2_chain.c:5512`), so
the handle's slot is the server's own index for its element, never the
requester's. **The server takes no inode
dependency.** `hammer2_xop_testset_ipdep()` sleeps with no bound on any
XOP in flight on the inode (`hammer2_admin.c:278-300`), and a server
that took it would form a cycle across hosts: A's XOP on inode X holds
A's dependency while it waits on B, B's on X holds B's while it waits on
A, each server's queue sleeps in the test, and every other request on
both connections queues behind them until the bound breaks the cycle
and reports a healthy cluster as unreachable. The read commands of
stage 2 run under the chain locks the storage function takes itself,
shared, which is what a strategy XOP already runs under with no
dependency (`:414-419`). A modifying command is outside stage
2's set and is answered `DMSG_ERR_NOSUPP`; how the protocol note
serializes them against the inode dependency is that note's.
A request names its PFS by cluster id, and the server serves a mounted
PFS with an element on the connection's device, found on
`hammer2_pfslist` under `hammer2_mntlk`, which the request then holds
until it is answered: `struct hammer2_pfs` carries no reference count
and `hammer2_pfsfree()` asserts the root inode's, so the lock every
mount, unmount and pfs-delete takes is what holds the PFS, and a request
runs in milliseconds. The lock is taken by try-lock within the bound,
since the unmount holds it while it waits for the server's queue to
drain and a blocking take there would wait on the unmount waiting on it;
a bulkfree scan holds it for its whole run, so a request started under
one fails at the bound. The cost runs the other way too: a request holds
the lock through its window wait, so a peer that stops continuing holds
`hammer2_mntlk` for the bound, during which a mount, unmount, pfs-delete
or bulkfree on the host waits and the synchronization
thread's try-lock fails and its pass is skipped to its next cadence; the
bound is the host's protection against that peer, and stage 2b's
measured default is what sets it. A request for
any other PFS is answered
`DMSG_ERR_NOSUPP` and logged. A request for a command outside the stage's
set is answered the same way; the set is a property of the descriptor,
the eight read descriptors of the command table in stage 2 and never
the call's `HAMMER2_XOP_MODIFYING` flag, which the slave's pass sets on
its own source scans (`hammer2_synchro.c:715`, `:1404`, `:1529`,
`:2123`) and which would refuse them. A peer that stops continuing holds
the connection's queue only to `remote_timeout_ms`, which the server's
window wait and its try for `hammer2_mntlk` share with the client side's
bound below. The queue closes with the connection: admission and
queueing run under one lock, so a quiesce that sets the closing flag
under it refuses every later request and its flush covers every earlier
one; a reconnect closes and drains the queue before the message core
replaces the connection, and the new connection's peer reopens it by
announcing `PROTO_2`, on the reader that admits, since no request is
legal before that announcement and a reopen on the ioctl's thread could
follow a valid first request; the device's teardown closes it for good
and drains it before the message threads are stopped and frees it after
they are gone, since the reader may deliver a frame until then, and an
announcement read during the teardown reopens nothing. A
request in flight at an unmount closes its transaction before the
simulated `DELETE`s run, and
an unmount with a remote peer silent completes through the ten-retry
shutdown `cluster-dmsg.sh` already reads.

## The client side

The remote storage function sends the request and waits on its state with
a bound, since a wait with no exit wedges an unmount. The bound is the
module parameter `remote_timeout_ms` beside `sync_snapshot`, ten seconds
since stage 2a built it as the server's bound, its default set from the
round trip stage 2b measures. It covers the whole reply
transaction from request to its `DELETE` and is not re-armed per frame: a
peer trickling one frame inside each bound would otherwise hold a sync
pass, whose freeze is acknowledged only at the top of the thread loop
through a `thr_wait` that sleeps in `hz*60` steps with no exit, and the
unmount with it. A timed-out element feeds `HAMMER2_ERROR_ETIMEDOUT`
(`hammer2.h:312`), which the errno map returns as `ETIMEDOUT`
(`:1586-1587`), and retires normally; a connection that closes fails every
request pending on it at once with the same code. The aborted path at
`hammer2_admin.c:483` is not reused for this: it passes the POSIX
`ECONNABORTED` where `hammer2_xop_feed()` stores a `HAMMER2_ERROR_*`
bitmask, so 103 decodes as `EIO` at the first bit; the line is
upstream's (`hammer2_admin.c:1227` upstream) and is recorded for
`doc/upstream/` staging in stage 2 with the check that directory
requires. The wait sits inside the element loop, which runs each element to
completion in slot order holding the inode dependency, so a remote
element blocks every later slot and every other XOP on that inode for
the round trip; a remote master registered after a local slave runs last
by construction. That cost is measured in stage 2b against the local
pass. **A silent loss is detected within the bound, not at the next
request.** `kern_dmsg` has no keepalive: `LNK_PING` is sent only to
unstick the reader at teardown (`kern_dmsg.c:265-273`) and is otherwise
only answered (`:1175-1183`), and a span carries no status (C10), so a
partition that drops frames and keeps the socket would be seen only
when a request timed out. A `PROTO_2` connection carries a second work item for the
keepalive alone, delayed work that neither the registration and detach
item nor a server busy in a request can hold up; it sends `LNK_PING`
every half of `remote_timeout_ms` as a `CREATE|DELETE` transaction with
a state callback, since the carried kernel answers no one-way `PING`
(C15) and a transaction without `DELETE` would leak a state per ping,
takes the reader's `DMSG_ERR_NOSUPP` reply as the answer, and when one
goes unanswered for the bound ends the connection by the reader's own
shutdown path (`KILLRX`, `kern_dmsg.c:121-133`), never by the teardown,
which disables the items and would wait on itself. The keepalive is the
one part of this section the first remote-element commit of stage 2b does
not build; until it does, a partition that keeps the socket is seen when
a request reaches its bound. The reply printed `RCVMSG` on every frame,
debug-gated with the span table under 0x0100; at the wire run's rate
that print overran the guest's log ring and took the registration line
with it, so it has its own bit, 0x0400 (`hammer2_iocom.c:225-226`), one
marked line; "reachable" below means "answered within the
bound", and a write that arrives between the loss and its detection is
the protocol note's, named as such in the matrix.

**In stage 2 a PFS with a remote element is read-only at the VFS.** A
remote element registers on a PFS mounted read-only or not mounted at
all, so the property rests on three checks under one lock: registration
refuses a PFS mounted with `pmp->rdonly` clear, the mount refuses `rw`
while a remote slot exists, and `->reconfigure` refuses `rw` the same
way, taking `hammer2_mntlk` around its test and its write of
`pmp->rdonly`
(`hammer2_vfsops.c:2581-2596`; the read-only write at `:2565` takes no
lock, since it only restricts; the order `s_umount` then
`hammer2_mntlk` is the unmount's at `:3302`),
since without the lock a remount could pass its test, registration
install a slot, and the remount then clear the flag. That is Linux's
own refusal: `write(2)`,
`chmod`, `truncate` and every create return `EROFS` before a folio is
dirtied or an XOP is built (a mapped write cannot reach `page_mkwrite`
on a mount opened read-only), so nothing reaches
`writepages` and no page is left under writeback. A dispatch-time
refusal in the XOP layer was the first shape and is not the design: a
strategy write ends its folios only inside its storage function
(`hammer2_strategy.c:1597`, `:1609`, `:1612`), so a refusal before it
would leave every buffered write under writeback until unmount, and the
buffered writes and attribute changes dispatch no XOP at all
(`hammer2_vnops.c` starts one at `:133`, `:242`, `:515`, `:671`, `:710`,
`:1512`, `:1551` and `:2276`), so they would have returned 0 and lost
the update at the next `inode_chain_sync`, which clears `MODIFIED`
before it starts and on error only prints (`hammer2_inode.c:1842-1852`).
The slave's pass writes its element through chain calls and its own
flush (`hammer2_synchro.c:2360`, `:2369`, `:2518`, `:2583`, `:464-503`,
`:880`), which a read-only superblock does not refuse, and it needs the
device open for writing: the open mode is the first mount's
(`sb_open_mode()`, `hammer2_ondisk.c:147`, `:197`), so stage 2b mounts
B's `ROOT` read-write before its `CL`, as `cluster-sync.sh` mounts
`ROOT` today. A `CL` mounted alone opens its device read-only, and the
port's bios do not consult the file's mode (`hammer2_ondisk.c:1029-1037`;
the block layer tests the device's own read-only flag and not the open
mode, `block/blk-core.c:566-583`, so a writable disk opened read-only
draws no warning at all), so a pass on it
would write silently to a volume whose mount-time recovery never ran
(`hammer2_vfsops.c:1497`); the pass therefore refuses to run while
`hmp->rdonly` is set, with a log line, and that line is stage 2b's
control. `rw` through `->reconfigure` is refused by the port's own test while a
remote element is registered (`:2581-2586`), since the carried remount
otherwise accepts ro to rw (`:2587-2595`). A write let through by
a failed mount flag would run the local slave's storage function first
and modify its chain, the remote's `(NULL, EOPNOTSUPP)` feed would set
`CITEM_NULL`, the check would return `ESRCH` and then, on the
`CHECK_NULL` end of scan, the element's `EOPNOTSUPP`, and the slave's
created chain would flush with no master agreeing. `EIO` at
`hammer2_cluster.c:382` is reachable only with a quorum. The mount
becomes writable only under the protocol a later note settles.

**The slave's pass over a remote master takes its source from the
master.** The default pass snapshots its source on the source element's
device (`hammer2_synchro.c:808`, `:824`), and `hammer2_pfs_snapshot()`
takes `hmp` from `pfs_hmps[clindex]` (`hammer2_ioctl.c:812`) and asserts
its modify succeeded (`:890-891`): on the connection device, where a
create is refused, that is at best a pass that copies nothing and at
worst the assertion. So the guard at `hammer2_synchro.c:734` refuses a
local snapshot when the focus slot's device is a connection device, and
stage 2b adds one command outside the 21 descriptors, a request for the
master to take the snapshot on its own device and serve the pass from
its root, which is P7's immutable source over the wire; its deletion at
the pass's end is a second command, and a snapshot left by a dropped
connection is deleted by the master at the next request, as the local
pass deletes a crash's. Until that command is built the wire pass runs
in the live form `sync_snapshot=0` already names, and the
`snapshot_source` criterion is read only once it is.

## The quorum protocol: what the carried core imposes, and the decision taken on it

The completion plan's rule stops a decision that changes distributed
commit semantics at a design note with alternatives and what each would
have to prove. Seven audit rounds of this note tried four shapes of
that decision against the carried code and refuted each on cited lines,
and what they established is not another shape but the set of facts any
cross-host commit on this core has to respect. They are listed first,
each with the line that holds it, because every candidate below is
judged against them and because the next design starts from them
rather than from the design document alone.

- **C1. The flush propagates `modify_tid` by maximum, per host.** A
  parent's `modify_tid` is raised to the largest child written back and
  never lowered (`hammer2_flush.c:885-887, 932-933`, upstream's `:1018`,
  `:1066`); two hosts flush on their own schedules, so an inode chain,
  an indirect block or the root reads two tids on a healthy cluster
  between one host's flush and the other's, and a maximum cannot show a
  missed transaction below it. The format's own comment calls
  `modify_tid` a cluster-level identifier that is "not propagated"
  (`hammer2_disk.h:595-601`), and the carried synchronizer depends on
  the propagation the code does anyway.
- **C2. Carried helpers modify a parent at the transaction's tid for
  its blockmap alone, on a schedule the host's flush sets.**
  `_hammer2_chain_delete_helper()` (`hammer2_chain.c:3441`) and
  `hammer2_chain_rename_obref()` (`:3402`) take that branch when the
  child is, or was before the rename's delete, `BLKMAPPED` (`:5230`,
  `:2017`; the rename's `obref` is filled only by the delete helper's
  blockmapped arm, `:3498`, and `:3401` asserts the flag is already
  clear), that is, already flushed into the parent on that host; `hammer2_chain_create_indirect()` modifies
  the parent at the transaction's tid when it splits a full blockset
  (`:3607`), and whether two hosts split at the same transaction depends
  on the parent's block table as each host's flush has laid it out,
  which no round measured. So any stamp taken at
  `hammer2_chain_modify()` moves with the flush schedule too, and
  `update_tid`, the field the format reserves for the cluster
  (`hammer2_disk.h:597`, `:638`, written by no tree), would need those
  sites excluded and, stamped at creation as a protocol would, still
  meets C8 and C9. The caller set is the semantic index's
  (`find_referencing_symbols` on `hammer2_chain_modify`, repeated until
  its count stopped moving at the per-file counts `grep` gives): nine
  sites in `hammer2_xops.c`, two each in `hammer2_ioctl.c`,
  `hammer2_synchro.c` and `hammer2_strategy.c`, one in
  `hammer2_vfsops.c`, the freemap's and bulkfree's on freemap chains,
  the flush's at mtid 0, and the thirteen in `hammer2_chain.c` itself.
- **C3. The core has no undo.** A modify copies the chain in place
  (`hammer2_chain.c:1611-1672`); a delete has modified the parent and
  removed the blockref before any protocol step could refuse it; only a
  create can be dropped. A commit protocol that applies at prepare
  cannot abort a modify or a delete with the media and the memory as
  they were.
- **C4. Inode numbers are a per-host counter.** `pmp->inode_tid` is
  seeded at mount (`hammer2_vfsops.c:1736-1739`) and advanced by
  `hammer2_trans_newinum()` (`hammer2_flush.c:239-243`) from the VOP
  (`hammer2_vnops.c:385`); the flush writes it into the root's
  `pfs_inum` (`hammer2_flush.c:798`). Two coordinators issue the same
  inode numbers, and `hammer2_xop_inode_create()` answers the second
  `EEXIST` on every host (`hammer2_xops.c:1073-1077`).
- **C5. The frontend's inode is not refreshed by a chain commit.** A
  participant's `ip->meta` is written by its own VOPs and written back
  whole by `inode_chain_sync` (`hammer2_xops.c:1416`), so a commit that
  changed the chains under an inode on another host leaves this host's
  in-memory size, mode and times stale and its next sync overwrites the
  other's. `hammer2_inode_repoint()` moves chains, not meta.
- **C6. Elements run to completion before the collect, which waits on
  nothing and re-feeds nothing** (`hammer2_xop_start_except()` runs each
  storage function and retires it in the caller, `hammer2_admin.c:477-481`;
  the collect's comment at `:790-796` says so); a proxy's fields are its
  feed frame's. A visibility rule that asks the collect
  to wait for a peer's apply has no feed to wait on.
- **C7. The collect skips a key the check returns `ESRCH` or `EDEADLK`
  for and ends the scan in `ENOENT`** (`hammer2_admin.c:805-817`,
  carried), and `readdir` ends on any collect error at the position it
  reached (`hammer2_vnops.c:252-255`) and maps the scan's final `ENOENT`
  to success (`:335-337`), so a disputed key vanishes from a listing that
  otherwise succeeds, and any other collect error ends the listing from
  that position on.
- **C8. PFS roots are stamped from each host's super-root counter at
  creation** (`hammer2_ioctl.c:542`, `:549`), and a mount-time repair of
  a mis-flagged root re-stamps its `mirror_tid` on one host, keeping
  `modify_tid` (`hammer2_vfsops.c:1999-2002`), so two roots of one
  cluster differ on `modify_tid` and `mirror_tid` from birth, and a
  stamp a protocol took at `hammer2_chain_modify()` would differ there
  too.
- **C9. The slave's pass re-stamps an inode copy at the replace with the
  master's propagated tid** (`hammer2_synchro.c:1422`, `:2169`, `:2583`),
  and it snapshots its source on the source element's own device
  (`:808`, `:824`; `hammer2_ioctl.c:812`, `:890-891`), which for a
  remote source is the connection device, where a create is refused.
- **C10. A span carries no status update** (the only `LNK_SPAN` arms
  are `CREATE` and `DELETE`, `hammer2_iocom.c:357`, `:395`), so a
  connected master learns nothing the protocol does not send it, and a
  fence or an outcome one coordinator holds is held by that coordinator
  alone until it is carried.
- **C11. Storage functions read host-local inode state**:
  `hammer2_xop_inode_create()` takes the parent's compression and check
  methods from the in-memory inode (`hammer2_xops.c:1086-1087`), so the
  same request can produce different chains on two hosts.
- **C12. A read-only state set at run time does not stop a writer
  already holding a descriptor.** The kernel tests `sb_rdonly` at
  `open` and in the path calls through `mnt_want_write`, not on the
  `write(2)` or `ftruncate` path (`fs/open.c:170` tests only
  `FMODE_WRITE`), and the port's own arms test `pmp->rdonly`
  (`hammer2_vnops.c:374`, `:500`, `:619`, `:828`, `:1036`, `:1234`,
  `:1427`, `:1840`, `:2528`), which a mount sets and only a remount
  rewrites (`hammer2_vfsops.c:1707`, `:2565`, `:2595`);
  with it set, `fsync` returns 0 before the sync without reading the
  mapping's error (`hammer2_vnops.c:1350-1351`), and with it clear
  `fsync` syncs and flushes the inode's chain (`:1356-1361`). ext4 sets
  no `SB_RDONLY` at run time for this reason, keeping its own flag
  (`fs/ext4/super.c:742-749`); the port's one run-time flip sits inside
  `->sync_fs` with `s_umount` held (`hammer2_vfsops.c:3267`).
- **C13. Dirty data at the moment of a loss reaches the local master's
  media.** A strategy write runs the local storage function before the
  collect (`hammer2_strategy.c:1560-1563`), an inode sync clears
  `MODIFIED` and on error only prints (`hammer2_inode.c:1842-1852`), and
  the unmount's three syncs run on any superblock
  (`hammer2_vfsops.c:3314-3316`), so what was dirty when the quorum was
  lost is flushed to the local media with no peer agreeing, and C3 says
  it cannot be taken back. Fail-closed on the media under a loss is a
  property of the write path's design, not of a flag.
- **C14. A read served from the caches never reaches the quorum
  check.** Cached folios, the dentry cache and the in-memory inode
  answer `read`, `stat` and `getattr` (`hammer2_vnops.c:2468`) with no
  XOP; only an uncached lookup and `readdir`, which is an XOP per call
  (`:197`), reach the check. "A read under quorum loss" means those.
- **C15. The carried kernel answers no one-way `LNK_PING`.** The
  receive path builds its switch from `msg->state->icmd`
  (`kern_dmsg.c:1166`), which is zero on `state0`, so a bare `PING`
  falls through to `hammer2_rcvdmsg()`, which ignores a one-way message
  and answers a transaction `DMSG_ERR_NOSUPP` (`hammer2_iocom.c:254-267`).
  A keepalive is either a transaction whose refusal is the answer, or
  one marked arm there.

### A. What PREPARE and COMMIT are in chain terms, and who coordinates

The state model asks for explicit transaction states, `NEW`, `PREPARING`,
`PREPARED`, `COMMITTING`, `COMMITTED`, `FLUSHING`, `DURABLE`, with
`ABORTED`, `FAILED`, `REQUIRES_REPLAY` and `REQUIRES_RESYNC` beside them,
and says a transaction's final state is not inferred from one packet.
Five candidates, with what each met.

1. **The client drives every master through XOPs and
   `hammer2_cluster_check()` decides**, the carried hard-block form over
   the wire. Precedent: the local two-master shape `cluster-quorum.sh`
   measures. Must prove: nothing, it is what exists. Fails: Dillon rules
   it out for networks because a client that loses a master
   mid-transaction leaves masters out of sync without their knowing; the
   local master's storage function modifies its chain before the check
   runs, so with the peer gone the created chain stays and flushes
   whichever code the check returns, the fork `partition` must not show;
   and C1 makes the check itself disagree on inode chains between two
   hosts' flushes. It stays the measured baseline of stage 3's first run.
2. **The receiving master coordinates a two-phase commit, prepare being
   the modification applied to a chain flagged off the flush.**
   Precedent: Dillon's "masters will run a 2-phase commit amongst
   themselves". Refuted by C3: no abort for a modify or a delete, the
   "dies during prepare" cell could not hold both media unchanged, and
   the aborted tid would flush into the root; a prepared chain is also
   visible to a reader on its host.
3. **The receiving master coordinates, prepare being an intent held in
   memory and applied at commit in tid order.** Precedent: the state
   model's `PREPARED` as a state no chain has entered. It removes the
   undo problem and was refuted on the rest: C4 (two coordinators
   collide on inode numbers), C5 (a commit on one host leaves the other
   host's inode stale and its next sync overwrites the commit), C6 (no
   way to make a commit visible on every host at once, since the collect
   cannot wait for a peer's apply), C11 (the same intent applies
   differently), and C10 for the fence it needed, which one coordinator
   held and the others did not; in a two-master cluster that fence is
   always held alone.
4. **P9's durable record and a write path that applies commits to the
   frontend.** The prepare is a record with a media home (a format
   extension, designed under the first rule), the coordinator allocates
   inode numbers for the cluster or each master owns a disjoint range
   written into the root, a commit applied on a host refreshes that
   host's in-memory inode from the committed chain, every master applies
   in the same order, a committed transaction becomes visible on a host
   only when the record says every master has applied it, and the stamp
   compared by the check is written by the protocol's own apply, not by
   `hammer2_chain_modify()`. Must prove: each of C1 to C11 by a control
   that turns the answering mechanism off, and the record's home against
   the media rule. Fails: it is more than P8 and P9 as the roadmap splits
   them, and none of it can be read until stage 2's remote element runs.

5. **One writer per PFS under a lease, replicated by P7's pass.** Per
   PFS one master holds a write lease with a term; only its host mounts
   the PFS writable, every other master's host is read-only unless it
   holds the lease, which is stage 2's read-only mount generalized. In
   P8's term clients mount at the holder and the replicas' hosts mount
   the PFS for the pass alone, since a replica's own reads would run the
   quorum check across its lagging element and the holder's (C1 applies
   to exactly that comparison), and forwarding a write from a replica
   needs a VOP-level command with a reply carrying the holder's inode
   number and errno, which the wire format does not have (the VOP space
   has no command, and the inode number is allocated at the receiving
   VOP, `hammer2_vnops.c:385`); both are Dillon's "a client can submit
   modifying operations to a single master"
   (`DILLON_HAMMER2_DESIGN_2015.md:729-731`) and both are the protocol
   note's to add, with their cost. The other masters
   run P7's pass against the holder over stage 2b's snapshot command, in
   the slave direction, which reverses decision B's "no thread for a
   MASTER" for that direction only; within one term every compared tid
   comes from the holder's counter and the pass stamps the replica from
   the source (`hammer2_synchro.c:671-673`, `:2169`, `:2583`) where it
   replaces, so C1 and C8 do not arise within a term, and one frontend
   with no forwarding means C3, C4, C5 and C11 do not arise while that
   frontend is the only one; replicas serve no reads of their own in
   P8's term, so C6 does not arise. The holder's own mount must hold its
   element alone for the per-key check, so that a read at the holder
   never compares against a lagging replica, and nothing in stage 2's
   registration keeps it so: registration admits any span whose
   `pfs_clid` matches, and `pfs_nmasters` raised to the on-disk count
   starts a thread on the holder's own slot with three masters
   (`hammer2_vfsops.c:459`, `:488-503`), so the holder's refusal of
   elements in its term, and the membership change a demotion makes on a
   live mount, are obligations below; the quorum under 5 is the
   majority that acknowledges a pass, and decision C's `ENOTCONN` is
   what the stage-2 shape reads, a read-only mount whose cluster holds a
   remote master element, not what the holder's mount reads. C2 remains: the pass's inode
   insert and its destroy arm run at mtid 0 (`hammer2_synchro.c:1907-1910`, `:1818-1819`,
   `:2360-2383`), so the delete helper's and the split's stamps on a
   replica carry no source tid today, which is the first obligation
   below. An
   `fsync` on the holder returns when a majority including the holder
   has stamped at or above that flush's tid, Dillon's phase-2 mode.
   Failover: a majority persists term plus one durably, one field in
   `copyinfo`'s reserved space (`hammer2_disk.h:515`), a change of
   stated meaning under the first rule as `remote_pfs_type`'s is; the
   new holder is the member of that majority that is furthest along,
   which cannot be read from a tid the flush moves (C1 applies on a
   replica alone after a pass that kept a block, the status record's
   row on the kept block under a raised inode), so the election reads a stamp
   the pass would write on verification and the flush does not,
   `update_tid` being the format's candidate (decision B), which no tree
   writes today and whose stamping must first answer C2, C8 and C9; a replica refuses a source with a
   lower term; the old holder's unacknowledged writes are discarded by
   demoting it and letting the pass overwrite it. With two masters the majority is both, so losing either halts
   writes: fail closed (S1), and C10's two-master case is unavailability
   rather than a pretended fence. The demotion of a live holder is its
   hardest obligation and is unsolved here: a holder that lost its lease
   still has open descriptors and dirty folios (C12, C13), so "one
   frontend" holds only once it has stopped writing and the pass has
   overwritten it, and the mechanism that stops it is the shutdown
   state decision C names, raised by the loss of the term. Must prove:
   that demotion, read by a holder cut off mid-write whose media the
   pass then overwrites, and which the carried pass cannot do yet: the
   pass that overwrites the demoted holder runs on the demoted holder's
   own host with the PFS still mounted (the thread is per mount and per
   slot, `hammer2_vfsops.c:488-503`), that mount's frontend outlives
   the term while descriptors are open, its `MODIFIED` inodes are
   written back whole by the carried sync the pass itself calls on its
   mount (`hammer2_synchro.c:880`, `hammer2_inode.c:1842-1852`), which is
   C5 on that host and moves a carried line to stop, and the snapshot pass keeps a slave chain it
   reads as newer at three arms (`hammer2_synchro.c:1498`, `:1823-1836`,
   `:1766`), which a demoted holder's writes, stamped from its own
   counter, will be whenever that counter ran ahead, and decision B's
   raise cannot order them, since tids never carried to the majority are
   never raised past: the ordering across a term, by term or by a
   demotion pass that disables the keep arms, is an open obligation; the pass's insert and
   destroy arms carry the source's tid so C2's three sites stamp the
   replica as the source was stamped, which today's pass does not do;
   the pass deletes chains the source lacks, its guarded arm under a
   snapshot (`:1775-1795`) included; which `copyinfo[]` row of a
   three-master PFS holds the term and how the election's messages
   travel (C10) and reach the volume header before the acknowledgment;
   the term is read before any write after a mount; the holder's mount
   admits no element in its term and the demotion adds the new holder's
   as a membership change on a live mount; the pass stamps `update_tid`
   on verification, after C2, C8 and C9 are answered for it, so the
   election has a stamp to read. Fails: it is one writer and
   not Dillon's concurrent multi-master commit; an `fsync` costs one
   pass; a format field changes meaning; and it needs the snapshot
   command and a write-capable wire pass before its first reading.

**Decision: 5, as the stage that builds 4.** Three candidates were
refuted on the code. 4 is where Dillon's design ends and where this
port's ends too, and it cannot exist without the transaction log Dillon
himself made "a separate development task"
(`DILLON_HAMMER2_DESIGN_2015.md:779-781`), a media-format record, an
inode allocation that is the cluster's and not the host's (C4), and a
frontend refreshed by a remote commit (C5), none of which can be built
or measured before a remote element runs. 5 needs one durable field,
reuses P7's pass and stage 2's element as its instruments, is a line of
Dillon's design, and everything it builds is a prerequisite of 4: the
durable term is one field of the record of membership and last agreed
commit that S1 to S3 need (decision B), the write-capable pass against
a master is what P9's reintegration of a stale master needs, and the
snapshot command over the wire is P7's in any case. What 4 later
discards is 5's shape and not its parts: the single writer and the
lease, replication by the pass, clients mounting at the holder alone,
the acknowledgment that costs a pass, and the election by stamp. So 5
is the first stage of 4 as far as its parts go, and it is taken here as
the next
step with 4 as the row after it, inside the delegated work, since an
order of work is not a choice between ends. A sixth shape, closing P8 on
stage 2 with a read-only remote master and a remote slave and moving
the write quorum to a row of its own, was weighed and declined: it ships
replication sooner and builds nothing of the quorum, a shim rather than
a stage. The detailed protocol of 5 is designed in its own note over
stage 2's running remote element, where C5, C6 and C11 are measured to
confirm they do not arise under it and where the number 5 stands or
falls on, the cost of one incremental pass over the relay, is a reading
rather than an estimate; stage 2b builds its snapshot command and its
write-capable pass in that order because 5 is the direction. One
measurement can change the order before any code and needs only the
local fleet, as a new arm of `cluster-sync.sh`, since today it times a
convergence and an idle window and not one pass (`:275`, `:300`) and
builds volumes of its own: a volume of the million-tree size, one file
changed, and one snapshot-form pass (the create, the verify rounds and
the delete) timed against the thread's cadence of 5.12 s, which a
phase-2 `fsync` already waits out; a pass longer than the cadence makes
that `fsync` unusable as a default, and the next step is then the
latency question rather than the wire. Stages 1 and 2 need no part of this and proceed.

### B. Membership, epoch and stale rejection (S1 to S3)

**Membership is settled where the research settles it.** Today
`pfs_nmasters` is the masters a mount can see plus an on-disk field no
tree writes at creation (`hammer2_vfsops.c:448-470`), so a master cut off
from its peer has a quorum of one and the `partition` cell forks.
Candidates: (1) the masters visible, as carried; (2) the `copyinfo[]`
rows whose `pfs_clid` matches the PFS and whose `remote_pfs_type` is
MASTER, so a configured peer that is unreachable raises the quorum rather
than leaving it; (3) a written on-disk `pfs_nmasters` set by the
administrator. (2) reads an on-disk field documented as "probed direct
remote PFS type" (`hammer2_disk.h:514`) as configured membership, a change
of stated meaning recorded under the first rule. Its proof obligations:
the `pfs_clid` filter, without which ROOT and every snapshot on the
volume would read quorum 2 with one master visible; and that a master's
own synchronization pass never runs against a quorum it cannot meet,
since `hammer2_vfsops.c:497` skips the thread only at `pfs_nmasters <=
1`, and the pass for a MASTER target excludes its own slot
(`hammer2_synchro.c:1537-1538`), reads `EINPROGRESS` with two masters
and exits (`:1612-1614`), copying nothing today in any tree
(`cluster-quorum.sh` counts threads at `:131-135` and has never measured
a pass). **In P8 a MASTER element gets no synchronization thread**: the
creation at `hammer2_vfsops.c:497`, which today skips a MASTER slot only
when `pfs_nmasters` is at most one, skips every MASTER slot, one marked line with `DEFER(P9: reintegration of a
stale master)`, and `cluster-quorum.sh`'s check at `:235`, which asserts
two support threads as its only witness that `pfs_nmasters` is 2,
inverts to assert none and takes a new witness, a `hammer2_debug` print
of `pfs_nmasters` after `hammer2_pfsalloc()`'s count
(`hammer2_vfsops.c:468-469`), read from the klog as the harness reads its
other counts. A SLAVE's thread is unchanged on its host. **Taken:
(2) with both obligations.** Membership alone does not make a partition
fail closed: it gives the protocol a quorum to miss, and the protocol is
decision A's.

**`REMOTE_DEL` is a membership change made on one host**, which lowers
that host's quorum; it is the act the `partition` control uses to make a
fork, so under (2) it is a protocol operation the protocol note makes a
transaction, and until then the harness uses it only as that control.

**Level, epoch and the stale master are the protocol note's**, and this
note records what they cannot be. A master's level cannot be read from
any tid the flush moves (C1, C2, C8, C9): the root's `modify_tid`, the
modified chain's or its parent's, and a stamp taken at
`hammer2_chain_modify()` were each tried and each read two values on a
healthy cluster. A fence held in one coordinator's memory is not a
fence (C10): a three-master interleave with one restart left two masters
equal on a per-PFS commit measure with different applied sets, and in a
two-master cluster the only other master is the one being fenced. An
epoch derived from in-memory state is lost with every host, and the
all-restart case then falls back on media tids, which C1 excludes. So S1
to S3 need a durable record of membership and of the last agreed commit,
which is the record candidate 4 names and P9's extension provides, and
that record would also have to define the field the check compares;
`update_tid` is the format's candidate for it, and C2's three sites, C8
and C9 are what any stamping of it would have to answer first. Until that note, a master whose PFS is unmounted on its host
is offline: the server answers requests against an unmounted PFS
`DMSG_ERR_NOSUPP` and the registering side treats that as not available.
The Lamport raise the earlier rounds designed stands as a fact about any
future protocol: `pmp->modify_tid` is a per-PFS counter whose
`hammer2_trans_sub()` returns the value before the add
(`hammer2_flush.c:163`) and is seeded to the root's tid plus one
(`hammer2_vfsops.c:1740-1741`), so a participant that applies a carried
tid raises its counter to that tid plus one by compare-and-exchange, or
issues it twice.

### C. The errno of fail-closed

The three check codes map to `EINPROGRESS`, `ESRCH` and `EDEADLK`
(`hammer2.h:1561-1605`), and the collect turns `ESRCH` and `EDEADLK` at
the end of a scan into `ENOENT` (C7). With fewer than `nquorum` masters
agreeing the check returns at `hammer2_cluster.c:353-366`, before pass 3,
and `RDHARD` is set for a MASTER only in pass 3 (`:409-410`), so there is
no carried read of a local focus under quorum loss: today a `lookup`
under it reads `ENOENT`, "no such file", and a `readdir` reads empty.
Reads are already closed, with the wrong errno, and the state model
allows a local read only where the original semantics allow it and stale
data cannot be presented as current, which is Dillon's soft-master mode
and not a P8 mode. The handoff asks for one deterministic user-visible
value when a quorum cannot be formed. Candidates: the carried codes as
they fall out, which is `ENOENT` for reads and `ENOENT` or `EDEADLK` for
writes; `ENOTCONN` for no quorum reachable and `EIO` for a reachable
quorum that disagrees on media; `EAGAIN`, which the sync thread already
uses for its own retry and would be read as that. Precedent: NFS returns
`EIO` for a server it cannot reach by default and `ETIMEDOUT` under
`soft`. The design for `ENOTCONN` is independent of decision A and is
settled here: the check counts masters whose slot is absent or errored
with the connection class (`ETIMEDOUT`, the closed-connection code) and
returns a new `HAMMER2_ERROR_` bit, mapped to `ENOTCONN`, before the
`ESRCH`/`EDEADLK` split, so a read under quorum loss is `ENOTCONN` and
not "no such file"; the end-of-scan path that counts a `(NULL, error)`
master as agreeing (`hammer2_cluster.c:301-306`) excludes an unreachable
one. An absent master is counted against `pfs_nmasters`, which nothing
lowers (`hammer2_vfsops.c:459-469` only raise it) and which the detach
keeps: a detached slot is NONE and the check's passes never see it
(`hammer2_cluster.c:212-225`, `:259-267`), so a detach that lowered the
count would send the read back to today's `ESRCH` and `ENOENT`. The
errno is settled for the reads that reach the check and for nothing
else. A read served from the caches never reaches it (C14), so
the deterministic value is the uncached lookup's and `readdir`'s, and
the cell reads those with the caches dropped. Writes under a lost quorum
are the protocol note's: the check runs in the collect after every
element's storage function has run (C6), a refusal at XOP dispatch would
leave a strategy write's folios under writeback for good and would miss
the buffered writes that dispatch no XOP (the stage-2 paragraph records
both), a read-only state set at run time stops no writer already holding
a descriptor and makes `fsync` return 0 (C12), and what was dirty at the
loss reaches the local media regardless (C13). Each of those was a
design in an earlier round of this note and each was refuted on its
line, so this note records them as the facts the write half has to
answer. Linux has the mechanism those facts leave room for, and it is
not a flag on the superblock: a shutdown state of the kind ext4 and XFS
keep (`EXT4_IOC_SHUTDOWN`, `XFS_IOC_GOINGDOWN`, `fs/ext4/ioctl.c:858-868`,
`fs/xfs/xfs_fsops.c:451-475`), a flag of the port's own tested where
those two test theirs: every VOP that modifies, since the port's
create, unlink, rename, link, setattr, fallocate and time update modify
local chains before the collect (C6), `open` and `mmap` for writing (the port has no `.open` and its
`.read_iter` is the generic one, `hammer2_vnops.c:2037`, so those two are
new wrappers, and the mmap hook on the kernel of record is
`.mmap_prepare`, `:2041`), `write_iter`, `page_mkwrite`, `writepages`,
and the reads, which both refuse after a shutdown (`fs/ext4/file.c:136`, `fs/xfs/xfs_file.c:321`)
so that a cut-off holder never serves cached data as current; `fsync`
never returns 0 after the shutdown, as neither does (`fs/ext4/fsync.c:134`
returns `EIO`; `fs/xfs/xfs_file.c:137-142` returns the writeback's error
or `EIO`), and never the mapping's error alone, since a mapping
written locally before the loss is clean and would answer 0 for a write
no majority holds. The entries are in `hammer2_vnops.c` and
`hammer2_strategy.c`, which are the port's files and not carried
(`doc/README.status.md`, the origin table), so the refusals move no
carried line. What the state cannot do is take back what was dirty at
the loss (C13), nor stop the carried sync writing a `MODIFIED` inode's
meta back whole (`hammer2_inode.c:1842-1852`, a carried file); under
candidate 5 both are the demotion's problem, answered by the pass
overwriting the demoted holder once that sync is stopped, which does
move a carried line, and it stays hard in full only under 4. The shutdown state is therefore the
protocol note's to design as part of 5's demotion, with the constraints
above as its acceptance list, and this note designs nothing of it. Must prove, for the settled half:
the value is the same from every uncached read for the same cluster
state, read in the `quorum_loss` cell from `cat` and `ls` after the
caches are dropped and from a `stat` of an uncached inode, which stage
2's read-only remote element can already read. The `EIO` of disagreement
depends on what disagreement is, which is decision A's protocol: the
errno map has no `pmp` (`hammer2.h:1561-1562`), the collect's skip (C7)
would hide a disputed key and `readdir` would end at it, so where the
mapping lives and what it must never fire on is the protocol note's.
**Taken: `ENOTCONN` for an uncached read with no quorum
reachable, settled now; the write half, and `EIO` for a reachable
quorum that disagrees on media, with their mechanisms deferred to the
protocol note under C12 and C13.**

### D. The acknowledgment modes and MESI over the wire

Dillon's four client modes are fully async, phase-1 ack, phase-2 ack and
flush, selected by `sync` and `async` mount options the port already
parses. Candidates: all four in P8; phase-2 ack only; phase-1 ack as the
default with phase-2 under `sync`. Precedent: Dillon makes phase-2 the
`fsync` default "which at least guarantees that a network failure after
that point will not disrupt operations issued before the fsync". Must
prove: S5, that no client observes a transaction as committed
inconsistently with the mode it mounted with, read by a write and a
power cut between the phases. The cache sub-protocol over the wire (MESI,
S6 and S7) is named by one matrix cell and by no exit criterion.
**Recommendation: phase-2 ack as the default and the only mode in P8**,
async and phase-1 refused with `EINVAL` on a PFS with a remote element
until the mode is measured, the `async` option the port parses untouched
on every other mount, and the mode itself re-read by the protocol note,
since it fixes a write acknowledgment that candidate 5's pass implies, and
MESI over the wire deferred to its own step with its trigger named: the
first two-mount workload that reads stale data the quorum allowed.

## The security model

The handoff's section 19 lists what must be defined before remote cluster
functionality is exposed. Each item, and where the answer lives:

| item | answer |
|---|---|
| peer authentication | kernel TLS through the handshake upcall on the socket `RECLUSTER` hands in, x509 or PSK, requested when the mount option `cluster_tls=x509|psk` or the `copyinfo` row says so; a frame before the handshake completes is refused; `tlshd` holds the keys and the kernel none, DragonFly's boundary kept |
| peer identity | the span's `peer_id`, bound to the authenticated TLS identity once stage 5 lands; before it, self-asserted and admitted only by an explicit `.none` marker, as DragonFly's `.none` admits a peer with no key |
| cluster id validation | a span registers only against a local `pmp` whose `pfs_clid` the span's `peer_id` names and a `copyinfo[]` row with that `pfs_clid` admits, and only after the fetched root inode's `pfs_clid`, `pfs_fsid` and `pfs_type` match the span's `peer_id`, `pfs_id` and `pfs_type`; a reply frame carries no id, and binds to the element by the connection and the open request |
| replay protection | a new mechanism, named as one: `link_verifier`, which the kernel today neither sets nor reads, is a per-connection random value chosen at `LNK_CONN` on a `PROTO_2` connection and checked on every frame, a mismatch ending the connection; a `msgid` is the kernel address of its transaction state (`kern_dmsg.c:1849`), so an aborted request's state is kept allocated, marked abandoned, until the peer's `DELETE` arrives or the connection closes, and its address cannot name a new request while a late reply can still arrive; TLS adds the record layer's protection within a connection |
| message freshness | the request's bound, `remote_timeout_ms`; a reply after its request aborted matches the abandoned state and is dropped there |
| authorization by node type | a MASTER accepts modifying requests only from a MASTER of the same cluster id; a SLAVE's requests are read commands only and a modifying command from one is `DMSG_ERR_NOSUPP`; for a MASTER the check is its `pfs_type` as the fetched root inode states it, cross-checked against its span at registration; a SLAVE's span registers no slot and fetches no root, so a slave requester is admitted by its `copyinfo[]` row and its span alone, and the commands it may send are the read set in either case |
| connection admission | closed by default: `h2service` dials only a peer with a `.pub` key or an explicit `.none` marker in its directory, as `libdmsg` refuses "unknown host"; the kernel registers a span only with a matching `copyinfo[]` row; everything else is monitored and logged, not registered |
| removal and revocation | `REMOTE_DEL` clears the row, which under membership (2) is a membership change on one host (decision B); the slot is detached as the remote element section defines; the daemon drops the dial; a `.pub` removed revokes at the next handshake |
| key storage | `tlshd`'s, outside the kernel and outside this tree; `h2service`'s key directory is the harness's for stages before 5 |
| encrypted transport | kernel TLS, stage 5; `tcpdump` on the relay port must show no `0x4832` magic in the clear with TLS on and must show it with TLS off |
| a stale node rejoining as current | decision B: what reads "behind" on a reconnecting master is the protocol note's, with the durable record it carries; this note records that no tid the flush moves can read it (C1, C2, C8, C9) and that a fence one coordinator holds is not one (C10); until then a master whose PFS is unmounted on its host is offline and registers nothing |

## The failure matrix

The handoff's thirteen cells, written in the handoff's own terms, which
are those of a two-phase commit between masters. Under decision A's
choice of 5 most of the write cells change shape: there is no prepare
and no commit between masters, a transaction is a pass, and the cells
are rewritten around the lease's term changing hands and a holder being
demoted. The protocol note rewrites them before its first run, and the
count of thirteen is the handoff's and not evidence for 5. Each row here
names the invariant the cell holds the cluster to, from the state
model, what this note can say about it today, and the instrument that
reads it. The read
and transport rows are stage 2's and are read there.

| cell | topology | invariant and what is known | instrument |
|---|---|---|---|
| A dies during prepare | 2 masters | S1, S9: neither media changes and the client reads one errno; under candidate 1 the local master's chain is already modified before the check (fork, the baseline's expected result) | `fail_quorum_at=preparing` on A, both fingerprints against the pre-run, `fsck_hammer2` clean |
| A dies after prepare | 2 masters | S1, S5: no commit becomes visible on one side alone; the cell is the one that refuted candidate 2 (C3), and what B does with a half-finished transaction is the protocol note's | `fail_quorum_at=prepared`, B's kernel log after `remote_timeout_ms`, fingerprints |
| A dies before commit | 2 masters | as above, with the coordinator never sending commit | `fail_quorum_at=committing`, fingerprints |
| A dies after commit acknowledgment | 2 masters | S5, S9: the acknowledged write survives on B; A's state at restart is what the protocol note's level test must read, and C1 says it cannot be A's root tid | B's media holding the write, A's registration line, writes after it |
| B loses connectivity to A | 2 masters | S1: with the row present an uncached read returns `ENOTCONN` rather than the `ENOENT` the carried check gives today and the log names the transition once; what a write does after the loss, before and after the keepalive's detection, is the protocol note's (C12, C13) | relay partition for frames i..j, `cat` and `ls` with the caches dropped on both mounts after the keepalive's line, the errno and the log line; the write half's instruments are the protocol note's |
| A/B partition while C is reachable to one side | 3 masters | S1, S3: the side with two of three may commit, the lone side fails closed, and the lone master must not regain write authority on heal by reconnecting; the three-master interleave of round six is the schedule this cell runs | relay partition, writes on both sides, fingerprints: two equal and one behind, the lone master's registration line |
| all but one master disappear | 3 masters | S1: the survivor's uncached reads return `ENOTCONN` from the check and no read of its own focus is served, since the carried check has no such path and soft-master mode is not P8's; its writes are the protocol note's | relay disconnect of two, `cat` and `ls` with the caches dropped after the loss, the errno; the write half's instruments are the protocol note's |
| stale master reconnects | 2 masters, then 3 | S3, L1: with two masters nothing may commit while B is away and liveness must return on reconnect, both the protocol note's to deliver; with three, B returns behind and must neither vote nor be written through; what reads "behind" is the protocol note's | `stale_rejoin`: writes failing then succeeding on both sides; the three-master run's registration line on B, B's media unchanged, A's and C's unchanged by B |
| master storage is stale but reachable | 3 masters | S3, S8: a volume restored from an older image must not win a vote or be written through, and must not be the source of a repair | the restored image's registration line, its fingerprint unchanged, the two current masters continuing |
| client disappears during a transaction | 2 masters and a mount | S1, S5: the client's remount sees one outcome on both masters; under the baseline the client drives both and the cell is expected to show the half-done write the protocol note must prevent | the client guest's power cut between prepare and commit, both masters' fingerprints equal after settle |
| client reconnects after MESI state expiration | deferred with D | not in P8; the trigger is named | the row records the deferral and its trigger |
| transport reconnect during synchronization | a master and a slave on two hosts (stage 2b) | S10, L3: the slave's pass fails its in-flight copies, withholds its stamp, and the next pass after reconnect completes them; the source is the master's live root until the snapshot command exists, then its snapshot (C9) | relay disconnect mid-pass, the `H2_FAULT`-shaped reading `cluster-sync.sh` already has, under `H2_WIRE=1` |
| healthy | 2 and 3 masters | L1: every write commits on all, fingerprints equal, `fsck_hammer2` clean, no warning; the two-mount write race is the cell that reads C4 and C5 | the `2_master_matrix` and `3_master_matrix` baselines |

The instruments above are written for writes through every master's
mount; under candidate 5 the write cells run through the holder's mount
alone and the protocol note rewrites them. The `partition` cell's
negative control is the row removed on one side,
which gives that side a quorum of one under membership (2), so its write
commits locally through the partition: the fork the control exists to
show, and under the baseline (candidate 1) the cell is expected to fork
on both arms, since the local master modifies before the check. A second
arm removes both rows and writes on both sides; what the two sides read
of each other on heal is the protocol note's, and this note only requires
that neither media is changed by the other.

## The test topology

Stage 1 and stage 2a are the loopback the roadmap's rule asks for: one
kernel against a userland peer, every byte seeded, `test/h2attach.c`
playing a `PROTO_2` client. Stage 2b is the first run on a network,
permitted because 2a passed: `artix-s6-kde` cloned by `virt-clone` to a
second guest carrying the same three kernels; MASTER `CL` on guest A,
SLAVE `CL` on guest B with the same cluster id; `h2service` on each guest
dialing through `test/h2loop.c`'s relay mode on the host, which listens
for both guests, relays frames under the same seeded knobs and trace, and
replays. What the relay adds is the replayable trace and the scripted
faults, not determinism of two kernels' timing; two guests on one cpuset
read function, never a rate. The "dies at phase" cells use the in-kernel
knob `fail_quorum_at=<phase>` under `HAMMER2_LOCKDEBUG` beside P4's
`fail_alloc_after`. Every run keeps its log, the guests' kernel logs and
the relay's trace beside the images under
`~/Projects/linux_hammer2-data/fixtures/`.

Negative controls in the subject at every stage: the CRC check off in a
scratch build must pass the bad frame; the client's window count off must
accept a server scripted past the window; admission off must register a
peer with no `.none` and no key; the stage 2 read-only mount off must land
a write on the slave alone; the pass's refusal under `hmp->rdonly` off
must write a `CL`-alone volume silently, read by its fingerprint; the
snapshot guard at
`hammer2_synchro.c:734` off must make the wire pass attempt a create on
the connection device and read the refusal, never the assertion;
`fail_quorum_at` with the protocol's abort path disabled must leave the
two masters' media different, under whatever protocol the later note
settles, and the controls for that protocol's mechanisms are that
note's to name.

**The marked lines stages 1 and 2 add to carried files**, so the XXX
table in `doc/README.status.md` can be read against them: in
`hammer2_chain.c`, the connection device's reference in
`hammer2_chain_alloc()` and at the chain's free (`:225`, `:829`); in
`hammer2_cluster.c`, the unreachable-master count (`:163`), its test in
pass 2, which also keeps such a master out of the end-of-scan agreement
(`:290`), and the `ENOTCONN` return before the `ESRCH`/`EDEADLK` split
(`:357`), decision C's settled half; in `hammer2_admin.c`, the XOP-level
dispatch (`:478`); in `hammer2_iocom.c`, the span test admitting
`PROTO_2` (`:375-380`), the span table's count and lock at its
initialization (`:128-129`) and the debug gate on the `RCVMSG` print
(`:225`); in `hammer2_synchro.c`, the guard refusing a local snapshot of
a remote focus (`:734`, `:743`) and the pass's refusal on a device
opened read-only (`:1162`); in `hammer2_inode.c`, the release that skips
the caller's own element in `hammer2_inode_get()` (`:1043`), the hang
the first wire run with a remote master found; in `hammer2_vfsops.c`,
the remote slots' detach before a local device leaves (`:743`), the
refusal of a read-write mount (`:1694`) and of `rw` through
`->reconfigure` (`:2574`), both under `hammer2_mntlk`, and the mount and
unmount `mount_count` loops skipping a connection device (`:2103`,
`:2667`); and in `hammer2.h`, the `ENOTCONN` bit and its errno-map
entries, and the device's span lock and connection pointer
(`span_spin`, `rconn`). The registration itself, with its refusal of a PFS mounted
read-write, its skipped sync thread and its `pfs_nmasters` print, is in
`hammer2_remote.c`, the port's own file. The protocol note lists its
own. The dispatch sites in `hammer2_io.c` are `/* Linux */` and not
`XXX`, since that file's split is the port's.

## The seven ioctls

They are carried as upstream wrote them: `RECLUSTER` is 65 with
`hammer2_ioc_recluster`, which the port has, and the other six are 68
to 71, 76 and 77 of `_IOWR('h', ...)` with `hammer2_ioc_remote_t` as
upstream's `hammer2_ioctl.h:73-83` declares it (`copyid`, `nextid`,
`fd`, `reserved03`, `reserved04[8]`, two `hammer2_volconf_t` copies),
with the handoff's validation list: every
field validated, unknown enum values and bad lengths refused, stable
errnos, malformed buffers under KASAN, races with unmount. `REMOTE_SCAN`,
`REMOTE_ADD` and `REMOTE_DEL` are the `copyinfo[]` bookkeeping through
`hammer2_volconf_update()`, which the port already has at
`hammer2_iocom.c:498`. `REMOTE_REP` and `SOCKET_SET` stay upstream's
returns of nothing and `SOCKET_GET` stays `EOPNOTSUPP`, each recorded in
the capabilities table with the upstream line, since inventing semantics
for them is an extension no document asks for. `REMOTE_ADD`'s `path` is
what `h2service` dials. `RECLUSTER` is the intake the port has since
1.0.33, with one change marked `XXX`: upstream hands the descriptor to
`cluster->focus->hmp`, and with a remote master the focus is a proxy, so
the socket would go to the connection device, and after a detach on a
lost connection, which is when `h2service` re-dials, the focus is
cleared and upstream's ioctl returns `EINVAL` for a cluster of more than
one element. It hands the descriptor to the first slot whose `pfs_hmps`
is a block device (`hammer2_ioctl.c:107-111`), the pick
`hammer2_pfs_first_bdev()` makes for `statfs` too, and reads no focus.

## What this note does not settle

- Decision A's protocol in detail: the note takes candidate 5, a
  single writer under a durable lease replicated by P7's pass, as the
  stage that builds candidate 4, Dillon's concurrent commit with its
  durable record, and leaves the detailed protocol of 5 to its own note
  over stage 2's running remote element, where the cost of one pass over
  the relay is read rather than estimated. Decisions B (membership) and
  C (`ENOTCONN` for an uncached read in the stage-2 shape; the write
  half deferred) are taken, D's phase-2 acknowledgment is taken for P8
  and re-read by the protocol note; stages 1
  and 2 proceed on none of A.
- Level, epoch and the stale master (S1 to S3), which the protocol note
  carries with the record; this note records what they cannot be read
  from (C1, C2, C8, C9, C10).
- P9's durable record and replay, and the final blocked synchronization
  pass of reintegration.
- MESI over the wire, deferred under D with its trigger.
- The production daemon's packaging; `h2service` is the harness's
  program, and the consumer's package is the consumer's question.
- A third guest for the three-master cells, weighed by memory on the day.

## Provenance

Written 2026-10-20 from the plan approved the same day after three
review attempts: two lost to the inference gateway before writing
anything, the third returning ten findings against the plan, every one
verified on the lines it cited and folded in before this note was
written. The findings that shaped the design: a chain with data and no
`dio` panics in `hammer2_chain_drop_data()` at its first last-unlock,
which is why replies are ordinary chains of a media-less device served
by the DIO layer; a slot registered without a chain never runs and holds
the PFS at `EINPROGRESS`, which is why registration waits for the root;
a write beside a read-only remote master lands on the slave with
`EOPNOTSUPP`, which is why stage 2 mounts read-only; membership from
`copyinfo[]` changes who votes and the meaning of an on-disk field,
which is why it is decision B and not a settled point; `libdmsg`
refuses an unknown host, which is why admission is closed by default.
The first audit of this note (Claude Opus 5.5, 27 tool uses, 10.5 min,
2026-10-20) returned NO SIGN-OFF with nine findings and four wording
notes; every one was verified on the lines it cited and changed the
text: no sync thread for a remote slot and only MASTER spans register
(a thread on proxies would reach the volume lookup's host-wide panic);
reads under quorum loss fail closed already, with `ENOENT`, so decision
C gained the reachability code and two matrix rows lost their "reads
continue" result; a MASTER's pass in a two-master cluster copies
nothing today and the stale-rejoin instrument built a forked master, not
a behind one, so decision B gained the catch-up quorum and the
forked-versus-behind distinction and the matrix row moved its behind
case to three masters; `msgid` is a state address and `link_verifier`
unused, so the replay row names a new mechanism; the carried version
test closes every non-`PROTO_1` span, so admitting `PROTO_2` is a marked
core edit; the unmount's slot loop is the body of
`hammer2_pfsfree_scan()` and is not callable alone, so teardown is a
port function; the timeout feeds `ETIMEDOUT`, not the aborted path's
POSIX value in a bitmask field; the DIO dispatch is three sites and
`buf` is freed at the last drop, so refetch by handle is the normal
path; registration values come from the root inode, not the span. The
second audit (Claude Opus 5.5, 26 tool uses, 8.2 min) found all nine
fixes holding and returned NO SIGN-OFF on five new findings, each
verified and applied: the detach left a dangling focus that
`RECLUSTER` dereferences, so the detach clears it and the ioctl binds to
the first local device; the catch-up quorum of one let each master's
pass overwrite the other, so a master target copies forward only and
compares before it writes, with the two-direction signature as the fork
detector; registration on the service kthread deadlocked two masters
spanning each other, so it runs on a work item; a server taking the
inode dependency formed a cycle across hosts, so it takes none and the
prepare rule serializes; a remote slot on an unmounted PFS held it on
the list after its last device left, so registration requires a mounted
PFS and the detach frees an emptied one. Also from that round: the
handle records the parent inode and the tid, the waiter fills `buf`,
the mount-time `mount_count` site, `devvp_list`, and the XOP-level
dispatch at `hammer2_admin.c:477`. The third audit (Claude Opus 5.5, 28 tool uses, 11.2 min) found one of
the five round-two mechanisms holding and returned NO SIGN-OFF on six
new findings, three blocking, each verified and applied, and the
largest changed the note's shape: `modify_tid` is a per-PFS counter, so
the prepare carries the coordinator's tid and participants raise their
counter past it, a Lamport clock; the catch-up pass could not run from
a remote source under the default (the snapshot is taken on the source
element's device) and belonged to P9's reintegration exit, so P8 creates no synchronization thread for a MASTER element and, in
that round's text, fenced a master that is not level by its root tid,
which the fourth round refuted; the detach and registration had no named lock and the
obvious one deadlocks the unmount through `kdmsg_iocom_uninit()`'s wait
for the reader, so both run on the connection's work item under
`hammer2_mntlk` with the `pmp` found again under the lock, and the
detach never frees a `pmp`; the refetch under `dio->lock` serialized
the device and could cycle with the window, so the fetch precedes any
DIO lock; the server had no way to an inode without the dependency, so
it resolves the chain under the local root into a server-side handle;
a span has no status update, so the only retry is reconnect; a master
with its PFS unmounted is offline. The fourth audit (Claude Opus 5.5, 27 tool uses, 8.4 min) found five
of the six round-three mechanisms holding and returned NO SIGN-OFF on
six new findings, two blocking, each verified on the lines it cites and
applied: the root tid cannot say whether a master is level (the flush
raises by maximum on each host's own schedule, and a snapshot moves the
root at a local tid), so the fence by root tid and the FENCED
`pfs_types` value are gone and the prepare carries the tid of the chain
it modifies, refused where a participant's differs, the carried check's
own unit; the Lamport raise is to the carried tid plus one by
compare-and-exchange, since the counter holds the next tid to issue; a
work item flushed under `hammer2_mntlk` deadlocks the unmount, so the
item try-locks and requeues and the teardown cancels it; `hammer2 -v
show` cannot read a state the kernel holds, so the instrument is the log
line; the harness's thread check inverts and takes a `pfs_nmasters`
print as its witness; and the refetch fills the dio
`hammer2_io_putblk()` leaves in the hash rather than entering a second.
Its two notes without a finding, that `nresolve`'s hardlink arm indexes
the server's own slot and that a bulkfree scan holding the lock delays
a detach for its run, are recorded where they apply. The fifth audit (Claude Opus 5.5, 22 tool uses, 6.8 min) found four of
round four's six fixes holding and returned NO SIGN-OFF on six findings,
one blocking: the chain-level test compared parents and inode chains
whose `modify_tid` each host's flush raises on its own schedule, so a
healthy cluster would refuse creates and fail reads between two
flushes, and one tid cannot name what `nrename` or `inode_unlinkall`
touch; the late-commit repair leaned on the SLAVE thread's rescan set,
which a commit on another host cannot reach. Both led back to the
format's own distinction: `update_tid` is the cluster-level field,
written by no tree and not propagated by the flush, so the port writes
it at the core's one modify site and the check compares it; level is a
per-PFS `quorum_tid` raised only by commits and compared at a
registration transaction; commits apply in tid order with stale
prepares refused; a commit needs every connected unfenced master's
acknowledgment or fences the one that withheld it; an in-doubt
transaction holds and resolves against the coordinator's chain; and a
prepared chain counts as in flight to a reader. Also from that round:
the collect's skip on `EDEADLK` is carried and would hide a disputed
key, so the collect returns it on a PFS with a remote element;
`cancel_work_sync()` re-enables the work, so the teardown uses
`disable_work_sync()`; the eviction path means any hash miss enters a
dio; and the security table's row on a stale node named a catch-up P8
does not have. The sixth audit (Claude Opus 5.5, 20 tool uses, 7.9 min) found two of
round five's six mechanisms holding and returned NO SIGN-OFF on ten
findings, three blocking, which together refuted the comparison unit
and the level test a third time and the apply-at-prepare commit for the
first: `update_tid` stamped at every `chain_modify()` still moved with
the flush, because the carried delete and rename helpers modify a
parent at the transaction's tid only when the child is already
`BLKMAPPED` on that host; a fence held in one coordinator's memory let
a three-master interleave with one restart leave two masters equal on
`quorum_tid` with different applied sets; and a prepare applied to a
chain has no undo in the carried core for a modify or a delete, so an
abort could not hold the media unchanged and an aborted tid would have
flushed into the root. The design after that round is decision A's
candidate 3 with the record in memory: prepare is an intent, commit
applies it in tid order, a fence is a membership transaction every
unfenced master applies, the stamp excludes the two blockmap sites by
a modify flag, commit is visible only once every master has applied it,
an in-doubt intent resolves by the level the registration reads, the
connection device carries its own reference count, and the refetch
compares `update_tid` and takes the peer's `bref` whole. Also from that
round: the `EIO` mapping is the collect's, since the errno map has no
`pmp`; five negative controls for the new mechanisms; the marked lines
the design implies, listed per file; and the format's stated meaning
for `update_tid` recorded as changed under the first rule. The seventh
audit (Claude Opus 5.5, 21 tool uses, 7.5 min) found one half of one of
the six round-six mechanisms holding and returned NO SIGN-OFF on eleven
findings, four blocking: the intent model collides on per-host inode
numbers, leaves the other host's in-memory inode stale for its next
sync to overwrite, cannot be made visible on every host at once because
the collect re-feeds nothing, and applies the same request differently
where a storage function reads host-local state; the agreed fence
degenerates to one coordinator's memory in a two-master cluster and
admits an out-of-order prepare before it commits; the `update_tid`
stamp is moved by the slave's replace and differs on PFS roots from
birth; the slave's pass would snapshot on the connection device; and a
leftover candidate text presented two recommendations. The finding
count had not fallen in four rounds (6, 6, 10, 11), which the working
rules read as divergence, so this round's changes are not an eighth
mechanism: the quorum section now lists the eleven constraints the
carried core imposes, each with its line, records the four candidates
with the evidence against each, accepts none, recommends that the
protocol be designed in its own note over stage 2's running remote
element with P9's record weighed as a prerequisite, and puts that
resequencing to the maintainer; membership and `ENOTCONN` stay
recommended, the matrix states each cell's invariant and instrument,
the slave's pass takes its source from the master by a command, and the
device count leaves dios out. The eighth audit (Claude Opus 5.5, 21 tool uses, 10.1 min) verified
the eleven constraints on their lines, eight holding as written, two
overstated (the rename helper's condition is "was blockmapped before
the rename's delete", `hammer2_chain.c:3401` asserting the flag clear; the mount-time
repair keeps `modify_tid`) and one cited at the wrong line (`C10` at
`hammer2_iocom.c:498`, which is the volume configuration; the span arms
are `:357` and `:395`), each corrected, and returned NO SIGN-OFF on
seven findings, one blocking: three matrix rows promised unchanged
media under partition and quorum loss that an errno computed after the
storage functions have run cannot deliver. The fix is the audit's own:
a gate before dispatch that refuses a modifying XOP when the reachable
masters are below quorum, settled under decision C, and the stage-2
read-only gate moved to the same site so the slave's pass can still
write its element under a writable device. The round also put a fifth
candidate in front of decision A, one writer per PFS under a durable
lease replicated by P7's pass, which answers C1 to C11 at the price of
Dillon's concurrent commit; it is recorded with its obligations and
costs and recommended as where the protocol note starts, beside the
resequencing of P9. The finding count fell from eleven to seven. The
ninth audit (Claude Opus 5.5, 24 tool uses, 6.0 min) returned NO
SIGN-OFF on ten findings, two blocking, both in the gate the eighth
round added: a strategy write ends its folios only inside its storage
function, so a refusal at dispatch would leave every buffered write
under writeback until unmount, and buffered writes and attribute
changes dispatch no XOP, so they would have returned 0 and lost the
update at the next sync. The gate is gone; stage 2 mounts a PFS with a
remote element read-only at the VFS and decision C's write half is the
read-only state Linux already has, with queued writeback completed
through the strategy path's existing error arm. Also from that round: a
keepalive so a silent loss is detected within the bound; the modifying
set defined as the descriptors and not the call's flag, which the
slave's own scans carry; candidate 5 amended so that replicas serve no
reads of their own in P8's term and forwarding is named as a VOP-level
command the wire lacks, with the pass's mtid-0 arms as its first
obligation; the `update_tid` sentence in decision B reduced to a
candidate field; and three wording corrections. The tenth audit (Claude Opus 5.5, 22 tool uses, 7.6 min) verified the
stage-2 read-only mount on the kernel of record and the port's own arms,
and returned NO SIGN-OFF on nine findings, two blocking, both in the
run-time read-only state the ninth round's changes gave decision C: a
writer holding a descriptor is not stopped by `SB_RDONLY`, the port's
arms test a mount-time flag that makes `fsync` return 0 without the
mapping's error, ext4 keeps its own flag for the same reason, and what
was dirty at the loss is flushed to the local media by the unmount's
unconditional syncs. The write half under quorum loss is therefore
recorded as four more constraints, C12 to C15, and designed nowhere in
this note; decision C settles the uncached read's errno alone, since a
cached read never reaches the check. Also from that round: the carried
kernel answers no one-way `LNK_PING`, so the keepalive is a transaction
whose refusal is the answer, sent as delayed work; the `CL`-alone
control could not fire because the port's bios do not consult the
file's mode, so the pass refuses to run on a read-only device instead;
the matrix instruments are noted as the holder's alone under candidate
5; and the leftover word "gate" is gone. The eleventh audit (Claude Opus 5.5, 22 tool uses, 6.8 min) verified
C12 to C15 on their lines, the stage-2 read-only mount, the keepalive's
transaction shape and decision C's placement, and returned **SIGN-OFF**
with seven non-blocking findings, two medium and five low, which it
asked to be folded in before stage 2's code and which are applied in
the commit that records this: the remount's write of `pmp->rdonly` and
registration's test of it under one lock, since without it a remount
could pass its test while a slot was installed; the keepalive on a work
item of its own, as a `CREATE|DELETE` transaction with a state callback,
ending the connection by the reader's shutdown path and never by the
teardown; the detach's requeue after a delay; the `RCVMSG` print
debug-gated; C12's arm list and its remount sites completed; the one
remaining "gate" reworded; decision D's refusal scoped to a PFS with a
remote element and its mode left to the protocol note; and the detach
keeping `pfs_nmasters`, without which the read's errno would fall back
to today's. The text those seven changed was not audited again; it is
local to stage 2 and each change names its line. The finding counts
over the eleven rounds were 9, 5, 6, 6, 6, 10, 11, 7, 10, 9, 7, the
last with no blocking finding. After the sign-off a design review of
the decisions themselves (the architect role on Claude Opus 5.5, 6 tool
uses, 2.1 min), asked to weigh the choices as a senior developer rather
than to check citations, found that decision A's text carried two
recommendations at once, that candidate 5 was framed as possibly
against the mission when it is the stage that builds candidate 4 and
discards one rule, that the demotion of a live holder was 5's unsolved
obligation and unnamed, that the write half of fail-closed had a
mechanism in Linux's shutdown state the note had stopped short of, and
that the matrix's thirteen two-phase cells read as evidence for 5 when
they are the handoff's; and the maintainer, shown the decisions, read
A as an order of work and not a choice, which it is. The four defects
are fixed in the commit that records this and A is taken as 5 then 4.
The twelfth audit (Claude Opus 5.5, 17 tool uses, 4.3 min) read that
text and returned NO SIGN-OFF on nine findings, one blocking, each a
sentence or two and none touching stages 1 and 2: the shutdown
paragraph's `fsync` rule had reinstated the fsync-returns-0 defect
against the very precedent it cited, which returns `EIO`
unconditionally; the demotion's two supports were false on carried
lines, since the pass that overwrites a demoted holder runs on that
holder's own host under a frontend that outlives the term and whose
inodes the carried sync writes back whole, and the snapshot pass keeps
a chain it reads as newer at three arms; the election by "highest
stamp" met C1 on a replica alone; what 4 discards of 5 is its shape and
not one rule; the holder's mount and the check under 5 were unstated;
the measurement named a script that does not time a pass and a volume
it does not use; and two sentences still called A open. Each is applied
in the commit that records this. The thirteenth audit (Claude Opus 5.5,
16 tool uses, 4.5 min) verified every change of the twelfth on its
lines and returned **SIGN-OFF** with five non-blocking findings, all
inside the demotion and failover obligations the note calls unsolved,
applied in the commit that records this: decision B's raise cannot
order a demoted holder's tids, which were never carried, so the
ordering across a term is an open obligation; nothing in stage 2 keeps
the holder's mount to its own element, so that refusal and the
demotion's membership change are obligations; the frontend write-back
is the pass's own sync call and not the unmount's; the election's stamp
is one the pass would write and no tree writes today; and D's phase-2
acknowledgment is taken, not deferred. The counts over thirteen rounds
were 9, 5, 6, 6, 6, 10, 11, 7, 10, 9, 7, 9, 5, with the eleventh and
the thirteenth signed off.
