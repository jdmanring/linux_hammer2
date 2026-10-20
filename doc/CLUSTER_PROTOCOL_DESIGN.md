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
design. It settles what the research settles, and it stops at four
decisions that change commit semantics or the security model, each with
its alternatives, its proof obligations and a recommendation, presented
rather than parked.

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
the port carries, `hammer2_iocom.c:171-184`: remote PFSs "look similar to
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
| `hammer2_admin.c:463` | an element that joins under a running XOP is not run, and `WARN_ONCE` says so |
| `hammer2_admin.c:653` | `hammer2_xop_feed()` indexes `collect[clindex]`, takes `hammer2_chain_ref_hold()`, and doubles every FIFO rather than refusing |
| `hammer2_admin.c:745` | the collect's advance drops the previous chain with `hammer2_chain_drop_unhold()` |
| `hammer2_admin.c:498` | `hammer2_xop_retire()` caches the XOP's chains on the inode past the XOP, with a reference |
| `hammer2_cluster.c:178` | `nquorum` is `pfs_nmasters / 2 + 1` |
| `hammer2_cluster.c:282` | `umasters` counts a master slot with no chain and no `CITEM_NULL` flag |
| `hammer2_cluster.c:340` | `HAMMER2_ERROR_EINPROGRESS` is returned while enough masters are still in progress to reach the quorum |
| `hammer2_cluster.c:342` | too few masters agreeing on the key returns `ESRCH`, and the tid disagreement `EDEADLK` below it |
| `hammer2_cluster.c:360` | a quorum whose agreeing masters all errored returns `EIO`, reachable only with a quorum |
| `hammer2_chain.c:845` | `hammer2_chain_drop_data()` panics "data not NULL" for a chain with data and no `dio`, every type but VOLUME and FREEMAP |
| `hammer2_chain.c:1160` | `hammer2_chain_unlock()` calls it on every last unlock |
| `hammer2_chain.c:1023` | `hammer2_chain_load_data()` returns before touching the device when `chain->data` is set or the block part of `data_off` is zero, and reads through `hammer2_io_bread()` otherwise, an I/O error becoming the chain's `EIO` |
| `hammer2_io.c:795` | `hammer2_io_bread()` is the read path from a chain to its device; `hammer2_io_new()` is the path for a chain being created, and `load_data` takes it for an `INITIAL` chain |
| `hammer2_io.c:219` | `hammer2_get_volume()` is reached on a dio-hash miss before the dio is allocated, and panics with no volume for the offset; `hpanic` sets the host-wide `hammer2_device_error` |
| `hammer2_io.c:722` | `buf`, the no-folio block, is freed at the dio's last drop, and a dirty one is written through `bdev_file`'s mapping first |
| `hammer2_synchro.c:1517` | `hammer2_xop_start_except()` with the pass's own index excludes the target element from the source scan |
| `hammer2_synchro.c:1592` | a pass ends on any collect error but `ENOENT` |
| `hammer2_vfsops.c:306` | `hammer2_pfsalloc()` merges every PFS root sharing a `pfs_clid` into one `pmp`, and a later mount joins an existing one |
| `hammer2_vfsops.c:451` | `pfs_nmasters` is raised to the on-disk field and then to the count of visible masters |
| `hammer2_vfsops.c:489` | `pfs_nmasters` at one or below is the only case in which a MASTER element gets no sync thread |
| `hammer2_vfsops.c:785` | `pfs_hmps` selects the slots the unmount removes, those of the device going away; each slot's thread is deleted and the `pmp` freed when no slot remains |

No tree writes the on-disk `pfs_nmasters` at creation. Upstream reads it
at mount and decrements it on destroy (`hammer2_vfsops.c:527-542`,
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
(`kern_dmsg.c:340-376`); the CRCs are generated on transmit over the
aligned header with `hdr_crc` zeroed and over the aligned aux
(`:2005-2012`), which is what `libdmsg` computes too, and `dmsg_icrc32` is
`iscsi_crc32`, the port's CRC-32C mapping (`hammer2_compat.h:156`).
Received spans are open transactions under `state0`, and
`hammer2_autodmsg()` monitors them (`hammer2_iocom.c:188`): a span whose
`peer_type` is not HAMMER2 or whose `proto_version` is not
`DMSG_SPAN_PROTO_1` is closed with a reply, and only a `PROTO_1` HAMMER2
span is left open with a result (`:240-258`). The kernel fills its own
spans with `peer_id` set to the PFS's `pfs_clid`, `pfs_id` to its
`pfs_fsid`, `pfs_type` from the root inode and `proto_version` 1
(`:316-320`); a span carries no root inode. `msgid` is the kernel
address of the transaction's state (`kern_dmsg.c:1801`), and
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
protocol space the connection did not negotiate ends the connection as
a bad magic does today.

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

`DMSG_HM2_OPENPFS` at `0x001` stays reserved and unused. `DMSG_HM2()`
encodes the structure's size into the command, so every command names
its structure: the request structure is one for all 21, `dmsg_hm2_xop`,
the header followed by the union of the XOP arguments below, and the
reply structure is `dmsg_hm2_feed`, the header followed by a
`hammer2_blockref_t`, `bytes` and `error`. A request frame is the
command with `DMSGF_CREATE`, carrying the XOP's arguments that are not
pointers: the inode's key, the directory's key, `lkey` and `rkey` and
`nmax` for `readdir`, `lhc` for `scanlhc` and `lookup`, `key_beg`,
`key_end`, `resolve_flags` and `lookup_flags` for `scanall`, `lbase` for
`strategy_read`, `lbn` for `bmap`, the name as aux where the XOP carries
one. The reply is a transaction of frames on the same `msgid`: each
`DMSGF_REPLY` frame is a `dmsg_hm2_feed`, one chain's `hammer2_blockref_t`
and its `bytes` and `error`, with the chain's data as aux when the XOP
returns data, at most one logical block of 64 KiB;
the transaction's `DELETE` carries the element's final error, the one
`hammer2_xop_feed()` would have been given with a `NULL` chain. A reply
frame with no data for a type that has data is a protocol error and ends
the connection.

**Versioning rides `proto_version`.** `DMSG_SPAN_PROTO_2` means "HM2 XOP
API version 1, CRCs verified". Today the carried test at
`hammer2_iocom.c:244-247` closes every span that is not `PROTO_1`, so
admitting `PROTO_2` edits that test, marked `XXX` as a core edit the
port could not avoid; a `PROTO_1` span stays open as today and never
becomes an element, and a span at a version the kernel does not know is
closed as today. A frame in the HM2 space on a connection whose peer
announced `PROTO_1` ends the connection. That is the compatibility plan
the extension rule asks for: an old reader sees spans and nothing else,
as it does now, and a `PROTO_1` kernel reading a `PROTO_2` span closes
it.

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
service kthread, then fetches the remote PFS root (one `ipcluster`
request, the same frame shape as every reply) and registers the slot
with the root chain in hand, through
the steps a later local mount takes in `hammer2_pfsalloc()`
(`hammer2_vfsops.c:409-437`): `chain->pmp`, the reference, `array[j]`,
`pfs_types[j]` and `pfs_names[j]` from the root inode's data as that
path reads them from `ripdata`, with the span's `pfs_type` and `pfs_id`
checked against the root's `pfs_type` and `pfs_fsid` and a mismatch
registering nothing, `pfs_hmps[j]` the connection's device,
`pfs_iroot_blocksets[j]` from the root's data. Two steps of that path
are not taken for a remote slot, by one test on `pfs_hmps[j]` being a
connection device, marked `/* Linux */`: `mount_count` is not
incremented, since the device has no mount, and **no sync thread is
created**. The thread would be the remote host's job for its own
element, and here it would walk its element by chains
(`hammer2_inode_chain()` at `hammer2_synchro.c:1540`, `chain_lookup` at
`:1558`, `chain_create` at `:2340`) through blockrefs that carry the
peer's real media offsets, and the first dio-hash miss would reach
`hammer2_get_volume()`'s panic, which sets the host-wide
`hammer2_device_error` and stops every device on the host writing. The
path also dereferences the chain, and a slot registered without one
would never run and would hold every collect on the PFS at
`EINPROGRESS`, so a span whose root cannot be read registers nothing,
logs once, and is retried when the connection is re-established, which
is the only retry the protocol offers: `hammer2_autodmsg()` has arms for
a span's `CREATE` and `DELETE` only (`hammer2_iocom.c:235, 260`) and
`libdmsg` sends `LNK_SPAN` only with `CREATE`, so there is no status
update to retry on. A span that arrived while the local PFS was
unmounted is registered when `RECLUSTER` next hands in a connection,
which `h2service` does after a mount of that PFS as it does after a
dial. The fetch runs off the service kthread because two masters
span each other at once (the kernel spans every PFS,
`hammer2_iocom.c:316-320`), and a registration that waited on the one
thread that also serves the peer's requests would wait on a peer
waiting on it, both registrations failing at the bound. A span registers only against a `pmp` that is mounted
(`pmp->mp` set): an unmounted `pmp` runs no XOP that could use the
element, and a remote slot on one would hold the `pmp` on
`hammer2_pfslist` after its last local device left, since
`hammer2_pfsfree_scan()` removes only the departing device's slots and
leaves gaps (`hammer2_vfsops.c:801-826`). In stage 2 a span against a
PFS mounted read-write is monitored and not registered, so the read-only
gate holds at registration as well as at mount. The mount-time
`mount_count` increment for every slot (`hammer2_vfsops.c:2068-2074`)
skips a connection device by the same test as the other two sites.

Teardown is a port function, `hammer2_remote_detach(pmp, j)`, marked
`/* Linux */`: under `iroot->lock` it drops the slot's chain, clears
`iroot->cluster.focus` when that chain was the focus, as
`hammer2_pfsfree_scan()` does (`hammer2_vfsops.c:815-816`), clears
`array[j]`, sets `pfs_types[j]` to NONE, frees the name and the
`pfs_hmps` entry and recomputes `nchains` from the highest remaining
slot, the steps that function takes for a local device's slots
(`:783-826`) and nothing else of it, which freezes every thread, cleans
snapshots under `hammer2_mntlk`, syncs the PFS and remasters, and cannot
be called for one slot. It never frees a `pmp`: registration requires a
mounted PFS, whose local slot outlives every remote one, so a detach
cannot empty a cluster, and `hammer2_pfsfree()` would in any case
assert `iroot->refs == 1` (`hammer2_vfsops.c:640-642`) on a mounted one;
the detach asserts that a slot remains. It runs under `hammer2_mntlk`,
the lock every walker of `hammer2_pfslist` holds (`:321`, `:722`,
`:3241`), and therefore never on the connection's reader thread: the
device unmount holds that lock through `hammer2_iocom_uninit()`
(`:2634`), which waits for the reader and writer threads to exit
(`kern_dmsg.c:255`), so a reader blocked on the lock would hang the
unmount with no bound. The reader queues the detach to the connection's
work item (the one registration uses). The work item takes the lock by
try-lock and requeues itself when refused, as the sync pass does
(`hammer2_synchro.c:811`), because every caller of
`hammer2_unmount_helper()` holds `hammer2_mntlk` (`hammer2_vfsops.c:1187`,
`:3241`) and that helper both tears the connection down
(`hammer2_iocom_uninit()` at `:2634`) and may drop a slot's last chain,
so a wait there on an item blocked in `hammer2_lk_ex()` would hold the
lock the item needs. Once in, the item re-validates that the slot still
holds the chain it was queued for, since the unmount may have detached
it first. A queued item holds one of the connection device's references
(the count the remote-element section defines), and the canceller drops
it when `disable_work_sync()` returns true;
the device's free flushes nothing; the connection's teardown disables
the item with `disable_work_sync()` (`kernel/workqueue.c:4677` in the
kernel of record), since `cancel_work_sync()` re-enables the work on
return and refuses a requeue only while it runs, and the teardown loses
nothing by it because it detaches every remote slot itself. The
teardown runs where `hammer2_mntlk` can be taken: in
`hammer2_unmount_helper()`, which holds it, and on a `RECLUSTER` that
replaces a connection, on the ioctl caller's thread, never on the
reader.
A long holder of the lock delays a detach that long: a bulkfree scan
holds it for its whole run (the comment at `hammer2_synchro.c:826`), and
the reader is not blocked by it. The detach runs on a span
`DELETE`, on a lost connection (`kern_dmsg.c` simulates the `DELETE`s at
link loss), and from `hammer2_unmount_helper()`, under the same lock,
for every remote slot of a PFS being unmounted, before
`hammer2_pfsfree_scan()` sees it, since a remote slot's `pfs_hmps` never
equals the device being unmounted and the `pmp` would otherwise keep a
slot and outlive the mount. Registration pins nothing across its round
trip: the work item fetches the root holding only the connection, then
takes `hammer2_mntlk`, finds the `pmp` again by `pfs_clid` on
`hammer2_pfslist` as the mount's own walk does (`hammer2_vfsops.c:321`),
checks `pmp->mp` under the lock, and registers; a `pmp` that was
unmounted between the fetch and the lock is not found and nothing
registers. Every inode's `ip->cluster.focus` is a copy
of the root cluster's taken without a reference
(`hammer2_inode.c:1579`); it is refreshed by the next collect and read
by no consumer between, and `RECLUSTER` no longer reads any focus (the
ioctls section). The connection's device is on no mount list: the
helper's `mount_count` accounting (`hammer2_vfsops.c:2603-2608`) skips
it by the same test, its `devvp_list` is initialized empty because
`hammer2_register_sb()` walks every slot's list
(`hammer2_ondisk.c:139-143`), and it is freed by a reference count the connection device alone
carries (`struct hammer2_dev` has none, `hammer2.h:895-930`, only
`mount_count` and `iofree_count`): one reference per chain allocated on
it and per dio, taken in `hammer2_chain_alloc()` (`hammer2_chain.c:176`)
and dropped at `hammer2_chain_lastdrop()` (`:562`), two marked lines, and
one per queued work item, dropped when the item completes or when
`disable_work_sync()` returns true for an item that will never run.

**Replies become ordinary chains of a media-less device, and
`hammer2_chain.c` is not edited for them.** The note's marked lines in
that file are listed in one place, under the test topology, so the XXX
table's count can be read against them. Each connection owns a `hammer2_dev`
with no block device, an `spmp` as `hammer2_chain_alloc()` requires, a
dio hash, and a handle table. A reply's chain is allocated against the
device with a synthetic `data_off`, a per-connection handle number in
block units with the block part non-zero, and the handle table maps it
to what the peer needs to find the chain again: the key of the parent
inode the request named (for the root chain and every inode chain
`ipcluster` fed, the inode's own parent, since `hammer2_xop_lookup()`
looks beneath its inode and never returns the inode's own chain), the
chain's key, keybits and type, its `modify_tid` and its `update_tid`,
and the in-flight flag of decision A. Only leaves are
fed, since `chain_lookup` and `chain_next` return leaves, so no indirect
block is ever a proxy. The reply's data lives in a
`hammer2_io_t` whose `buf` field, the form the port already has for "the
block when the page cache had no folio for it", holds the aux, served by
`hammer2_io_data()`; the feed puts that dio into the hash as GOOD before
the chain is fed. `hammer2_io_putblk()` frees `buf` at the dio's last
drop (`hammer2_io.c:722-729`), so a proxy kept past its XOP (the
retire's ccache, `ip->cluster` through `hammer2_inode_repoint()`, the
registered root) has no data, and **every relock refetches**: the
device's `hammer2_io_bread()` on a hash miss looks the offset up in the
handle table and issues one request for that handle under the bound, a
`lookup` beneath the parent inode for a data or directory chain and an
`ipcluster` for an inode chain; the waiting thread itself copies the
reply's aux into a new `buf` when it is woken, so the reader thread
takes no dio lock and the feed's hash entry is created only for a fresh
handle, never for an existing dio that is not GOOD. The wait runs under
`dio->lock` exclusive, which `hammer2_io_alloc()` takes and
`hammer2_io_getblk()`'s read path holds (`hammer2_io.c:576-595`), with
`iohash_lock` released, so nothing the reader or the service kthread
needs is held across the round trip. A handle the peer no longer
resolves, or that resolves to a chain whose `update_tid` differs from
the proxy's (not `modify_tid`, which the peer's flush raises on an inode
chain; and the refetch takes the peer's whole `bref`, since an inode's
embedded blockset is rewritten by the peer's flush and the old check
code would fail its own content), reads `EIO` through the path `load_data`
already has (`hammer2_chain.c:1075-1081`) and the element is errored,
never a fault; the next XOP feeds a fresh proxy. **The round trip holds
no dio lock and no hash lock.** `hammer2_io_alloc()` runs under
`iohash_lock` exclusive (`hammer2_io.c:196`) and
`hammer2_io_hash_lookup()` takes `dio->lock` under it (`:926-934`), so a
wait inside the DIO layer would hold `dio->lock` for the round trip
while a second thread on the same handle waited for it holding
`iohash_lock`, which serializes every DIO lookup on the device for a
round trip and, since a feed entering the hash needs that lock and a
stalled feed cannot send its continuation frame, stalls the peer's
server at the window and queues the refetch's own reply behind it, a
cycle only the bound breaks. The connection device's read path
therefore fetches before it touches the hash: `hammer2_io_bread()` on a
connection device looks the handle up in the handle table, whose own
lock covers an in-flight marker so two threads refetching one handle
share one request, performs the round trip with no DIO lock held, and
only then fills the dio under `dio->lock`. `hammer2_io_putblk()` frees
`buf` at the last reference and leaves the dio in the hash not GOOD
(`hammer2_io.c:722-735`), so after a handle's first fetch every refetch
finds that entry, looks it up as the carried path does and fills it
rather than inserting a second; any miss enters a new dio under
`iohash_lock`, the first fetch of a handle or one after
`hammer2_io_hash_cleanup()` evicted the entry (`:749-750`). A handle found already GOOD in the hash
takes the carried path directly. That is the
object-based `(inode,key)` API the carried comment describes, in the DIO
layer, and refetch is the normal path rather than the upgrade. So
`load_data`, `unlock`, `drop_data`, `lastdrop`, the ccache and
`repoint` all run the carried code unchanged. The dispatch between the
block-device and handle forms is in `hammer2_io.c` at three sites, each
marked `/* Linux */`: the entry of `hammer2_io_bread()` and
`hammer2_io_getblk()`, where a connection device takes the fetch path
above before any lock; `hammer2_io_alloc()` before `hammer2_get_volume()`
(`:218-226`), where a miss on the media-less device must never reach
the volume lookup's panic; and the first fetch's entry of a new dio
with `buf` into the hash. A fourth site is outside the DIO layer: the
loop `hammer2_vfsops.c:2328-2332` takes the first non-NULL `pfs_hmps`
for `statfs`, and reads the connection device if a remote slot ever
precedes the local ones, so it takes the first block device by the same
test. Two
paths are refused on the device with `WARN_ONCE` and `EIO`: a chain
being created (`hammer2_io_new()`, the `INITIAL` path), since proxies
are never created locally and stage 3's writes travel as XOP commands,
and a dirty dio, since `hammer2_io_buf_put()` would write through a
`bdev_file` the device does not have. One dispatch sits above the DIO
layer: `hammer2_xop_start_except()` calls the descriptor's storage
function per slot (`hammer2_admin.c:474`), and a slot whose `pfs_hmps`
is a connection device runs the remote storage function instead, one
marked test there. A chain with data and no `dio` was
the first shape considered and is not one the core allows:
`hammer2_chain_drop_data()` panics on it at the first last unlock, which
the collect's advance reaches on the first two-entry `readdir`. The
device is counted by its chains, dios and queued items and freed after the last,
not at disconnect, because the ccache and `ip->cluster` hold proxies
past the XOP and past the connection.

**Alternatives recorded and declined.** A `NULL` slot with a side table
for the remote state fails at `hammer2_admin.c:456`, which never runs it,
and at `hammer2_cluster.c:282`, which counts it in progress forever. A
chain-owned data buffer with `dio == NULL` fails at
`hammer2_chain.c:845`. Both are what a reader of the plan expected to
work, and both were refuted on the cited lines before any code.

## The server side

The reader thread never runs chain code. A `PROTO_2` connection has one
service kthread; the reader queues each HM2 request to it, and it runs
the local backend for the local element the request names (the XOP's
storage function on the local chain for that slot alone), feeding one
reply frame per chain, honoring the window, and closing the transaction
with the element's final error. **The server resolves the request's
inode without an XOP.** The request names the inode by number; the
server first tries `hammer2_inode_lookup()` (`hammer2_inode.c:556`),
which finds an inode already in memory and takes no dependency, and on
a miss finds the inode's chain by `hammer2_chain_lookup()` under the
local root, the PFS's inode tree keyed by inode number, and runs the
storage function on a server-side inode handle, a `hammer2_inode_t`
outside the inode hash holding that chain in the slot, which
`hammer2_inode_chain()` reads under `cluster_spin` (`:404-428`, "The
inode does not have to be locked"). `hammer2_inode_get()` is not used,
since it needs a collected XOP on the parent and that XOP takes the
dependency. The proof obligation, listed function by function in stage
2a's record, is that each read storage function reads nothing of `ip1`
but its cluster slot; the call sites are `hammer2_xops.c:141, 173, 244,
792, 891` and `hammer2_strategy.c`'s read. One of them indexes by slot:
`nresolve`'s hardlink arm calls `hammer2_chain_inode_find()` with the
request's `clindex` on the server's own `pmp` (`hammer2_xops.c:271`),
which reads that `pmp`'s inode at that slot (`hammer2_chain.c:5508`), so
the handle's slot is the server's own index for its element, never the
requester's. **The server takes no inode
dependency.** `hammer2_xop_testset_ipdep()` sleeps with no bound on any
XOP in flight on the inode (`hammer2_admin.c:278-300`), and a server
that took it would form a cycle across hosts: A's XOP on inode X holds
A's dependency while it waits on B, B's on X holds B's while it waits on
A, each service kthread sleeps in the test, and every other request on
both connections queues behind them until the bound breaks the cycle
and reports a healthy cluster as unreachable. The read commands of
stage 2 run under the chain locks the storage function takes itself,
shared, which is what a strategy XOP already runs under with no
dependency (`:414-419`). The modifying commands of stage 3 are
serialized by the two-phase protocol's own rule, in decision A: the
coordinator holds its local dependency for the transaction, a prepare on
another master runs under exclusive chain locks, and a prepare that
meets a chain already prepared by another transaction is refused.
A request for a PFS the connection's peer is not admitted to is answered
`DMSG_ERR_NOSUPP` and logged. A request for a command outside the stage's
set is answered the same way. The thread stops with the connection, and
an unmount with a remote peer silent completes through the ten-retry
shutdown `cluster-dmsg.sh` already reads.

## The client side

The remote storage function sends the request and waits on its state with
a bound, since a wait with no exit wedges an unmount. The bound is the
module parameter `remote_timeout_ms` beside `sync_snapshot`, its default
set from the round trip stage 2b measures. It covers the whole reply
transaction from request to its `DELETE` and is not re-armed per frame: a
peer trickling one frame inside each bound would otherwise hold a sync
pass, whose freeze is acknowledged only at the top of the thread loop
through a `thr_wait` that sleeps in `hz*60` steps with no exit, and the
unmount with it. A timed-out element feeds `HAMMER2_ERROR_ETIMEDOUT`
(`hammer2.h:312`), which the errno map returns as `ETIMEDOUT`
(`:1523`), and retires normally; a connection that closes fails every
request pending on it at once with the same code. The aborted path at
`hammer2_admin.c:478` is not reused for this: it passes the POSIX
`ECONNABORTED` where `hammer2_xop_feed()` stores a `HAMMER2_ERROR_*`
bitmask, so 103 decodes as `EIO` at the first bit; the line is
upstream's (`hammer2_admin.c:1227` upstream) and is recorded for
`doc/upstream/` staging in stage 2 with the check that directory
requires. The wait sits inside the element loop, which runs each element to
completion in slot order holding the inode dependency, so a remote
element blocks every later slot and every other XOP on that inode for
the round trip; a remote master registered after a local slave runs last
by construction. That cost is measured in stage 2b against the local
pass.

**In stage 2 a PFS with a remote element mounts read-only**, and `rw` or
a remount to it is refused with `EROFS` before any XOP runs. A write
through a slave beside a read-only remote master would run the local
slave's storage function first and modify its chain, the remote's
`(NULL, EOPNOTSUPP)` feed would set `CITEM_NULL`, the check would return
`ESRCH` and then, on the `CHECK_NULL` end of scan, the element's
`EOPNOTSUPP`, and the slave's created chain would flush with no master
agreeing. `EIO` at `hammer2_cluster.c:360` is reachable only with a
quorum. Stage 3 lifts the gate under the ruled protocol.

## The quorum protocol: four decisions presented

Each decision below changes distributed commit semantics or the security
model and stops here with its alternatives, what each must prove, a
precedent, a failure mode and a recommendation. None is the maintainer's
ruling until he gives it. Stages 1 and 2 need none of them; stages 3 to 5
need all four.

### A. What PREPARE and COMMIT are in chain terms, and who coordinates

The state model asks for explicit transaction states, `NEW`, `PREPARING`,
`PREPARED`, `COMMITTING`, `COMMITTED`, `FLUSHING`, `DURABLE`, with
`ABORTED`, `FAILED`, `REQUIRES_REPLAY` and `REQUIRES_RESYNC` beside them,
and says a transaction's final state is not inferred from one packet.

1. **The client drives every master through XOPs and
   `hammer2_cluster_check()` decides**, the carried hard-block form over
   the wire. Precedent: the local two-master shape `cluster-quorum.sh`
   measures. Must prove: nothing, it is what exists. Fails: Dillon rules
   it out for networks because a client that loses a master mid-transaction
   leaves masters out of sync without their knowing; and the local
   master's storage function modifies its chain before the check runs, so
   with the peer gone the created chain stays and flushes whichever code
   the check returns. This is the fork `partition` must not show.
2. **The master that receives the modifying XOP coordinates a two-phase
   commit with the other masters, prepare being the modification applied
   to a chain flagged off the flush until commit.** Precedent: Dillon's
   "masters will run a 2-phase commit amongst themselves". Must prove: a
   prepared chain never reaches the media before commit, and an abort
   leaves the memory as it was. Fails on the second: the carried core has
   no undo. A delete prepare has already modified the parent at the
   transaction's tid and removed the blockref
   (`_hammer2_chain_delete_helper()`, `hammer2_chain.c:3437` onward), a
   modify prepare has copied the chain in place (`:1608-1668`), and only
   a create can be dropped; the "dies during prepare" cell could not
   hold both media unchanged, and the aborted tid would flush into the
   root. A prepared chain is also visible to a reader on its host before
   commit, which the check cannot tell from a committed one.
3. **Prepare as an intent record and apply at commit.** The prepare
   carries the XOP's request, the same frame stage 2 defines, and every
   connected, unfenced master holds it as an intent: validated against
   the intents it already holds (another intent on the same inode is a
   conflict), against the coordinator's epoch and level (decision B), and
   against the tid order below, and acknowledged without touching a
   chain. Commit runs the XOP's storage function from the intent at the
   carried tid on each master, in tid order; abort drops the intent and
   nothing was modified. Dillon separated a durable log and its replay
   into their own task, and that is P9's: in P8 the record is the
   in-memory intent, lost with the host, and the loss is handled by the
   level test below rather than by replay. Precedent: the state model's
   `PREPARED` as a state no chain has entered, and its `REQUIRES_REPLAY`
   for the durable form. Must prove: no chain of a PFS with a remote
   element is modified outside a commit, read by the "dies during
   prepare" and "dies after prepare" cells with both fingerprints equal
   to the pre-run; the intent's validation refuses the two-coordinator
   write race one way (the healthy cell); the memory an intent pins is
   the request alone. Fails: a commit that runs the storage function on
   one host before another leaves a window in which the two hold
   different content, which is the in-flight rule below.

**Recommendation: 3**, with 1 kept as the measured baseline of stage 3's
first run, labeled as such, and never the shipped default; 2 is
recorded as the shape the first five audits refined and the sixth
refuted on the core's lack of an undo.

**The rules of the recommended protocol.** A quorum is the least number
of connected, unfenced masters under which the PFS is writable at all
(`nquorum`, `hammer2_cluster.c:178`), not the number of acknowledgments
a commit needs: a commit needs every connected, unfenced master's
acknowledgment of the prepare. A master that does not acknowledge within
the bound is not left out and forgotten: the coordinator first runs a
membership transaction that fences it (decision B), prepared on and
acknowledged by every other connected, unfenced master, and commits the
original transaction only once that has committed, so every master that
applies a commit knows the same fence set and a fenced master is never
sent a later prepare. Prepares are ordered by tid on every master: a
prepare whose tid is below a tid the participant has already applied is
refused as stale, the refusal carries the participant's applied tid, and
the coordinator reissues the intent above it; a commit is applied only
after every intent with a lower tid on that participant has resolved; so
every unfenced master applies the same transactions in the same order,
and the flush can never raise a parent past a commit it has not seen. A
reissue can lose again to a faster coordinator, so the obligation is a
bound on reissues read by the healthy cell's two-mount write race, and
the lower `pfs_fsid` wins a conflict of intents on one inode as before,
so two coordinators cannot refuse each other forever. **Commit is
visible only when every master has applied it.** The storage function
run at commit flags the chains it modified in flight; the coordinator
sends a release when every participant has acknowledged its apply and
the flag clears; the quorum check counts a flagged chain as it counts a
slot not yet fed (`umasters`, `hammer2_cluster.c:280-284`, one marked
test in pass 2), the feed frame carries the flag so a proxy shows it,
and the collect, which today has nothing to wait for on `EINPROGRESS`
(`hammer2_admin.c:790-791`), waits on a PFS with a remote element on
the connection's release wait queue, bounded by `remote_timeout_ms`, and
re-checks (one marked path beside the carried skips), so a read racing
a commit returns the committed content or the bound's errno, never one
host's content against the other's. **An intent whose outcome has not
arrived** by the bound, or whose coordinator's connection dropped, is in
doubt: the participant keeps it, fails every XOP on the PFS closed with
decision C's no-quorum errno, and resolves it at the next registration
by level alone: an intent whose tid is the level the registration
reads is applied, one just below that level is dropped (nothing applied
it anywhere), and a wider gap means the participant is behind and
registers fenced. No chain is read to resolve it, so a committed delete
and a lost create are not confused and a transaction touching several
keys needs no naming.
3. **Prepare as an intent record and apply at commit**, the transaction
   log Dillon separated into its own task. Precedent: the state model's
   `REQUIRES_REPLAY`. Must prove: the record's media home, which is a
   format extension. Fails: it is P9 arriving early, and the first rule
   stops it at an extension design.

**Recommendation: 2**, with 1 kept as the measured baseline of stage 3's
first run, labeled as such, and never the shipped default.

### B. Membership, epoch and stale rejection (S1 to S3)

Two linked questions. **Membership: who counts in `pfs_nmasters`.**

1. **The masters visible**, as carried. Precedent: every tree. Fails: a
   master that mounts without ever seeing its peer has a quorum of one
   and decides alone, and with A's protocol meets its quorum by itself.
   A master that saw its peer and lost it keeps `pfs_nmasters` 2, since
   the count is only ever raised (`hammer2_vfsops.c:451-461`) and slot
   teardown never lowers it, so it fails closed by the accident of a
   counter that forgets nothing until the next mount.
2. **The `copyinfo[]` rows whose `pfs_clid` matches the PFS and whose
   `remote_pfs_type` is MASTER.** A configured peer that is unreachable
   raises the quorum rather than leaving it, which is what gives A a
   quorum to miss. Precedent: `copyinfo[]` is the array the original
   kept for exactly the cluster's membership, on the media in the volume
   header already, so no format change. Must prove: the `pfs_clid`
   filter, without which ROOT and every snapshot on the volume would read
   quorum 2 with one master visible and the harness's ROOT mounts would
   stop working; and the sync thread a lone MASTER then gets, since
   `hammer2_vfsops.c:489` skips it only at `pfs_nmasters <= 1`, whose
   collect excluding itself reads an all-NULL cluster as `ENOENT`, the
   shape `hammer2_synchro.c` records as "deletes every key the element
   still holds", so a master's sync pass runs only with a second element
   present. Fails: the field `remote_pfs_type` is documented as "probed
   direct remote PFS type", and this reads it as configured membership,
   a change of on-disk meaning that is why the question stops here.
3. **A written on-disk `pfs_nmasters`** set by the administrator at
   `pfs-create` or by a new ioctl. Precedent: the field exists and
   upstream's comment says MASTERs "are authoritative" for it. Must
   prove: who writes it and when, and what a DragonFly reader does with
   a value above its visible count (it raises its quorum, as the port
   does). Fails: it is a second place for the same fact.

**One transaction id across hosts.** `hammer2_trans_sub()` allocates
`modify_tid` from a per-PFS counter (`hammer2_flush.c:159-166`), seeded
at mount from the local root (`hammer2_vfsops.c:1711-1712`); the local
two-master shape shares one `pmp` and so one counter, which is why its
quorum pass agrees. Across hosts two counters would differ on every
write, the equal-tid test of pass 2 (`hammer2_cluster.c:298-311`) would
never agree, and "behind" would mean nothing. So **the prepare carries
the coordinator's `mtid`, every participant applies the transaction at
that tid, and a participant first raises its own counter past it**
(`pmp->modify_tid` raised to the carried tid plus one when it is not
already above it, by a compare-and-exchange loop in one marked function
beside `hammer2_trans_sub()`, because the counter holds the next tid to
issue: `atomic_fetchadd_64` returns the value before the add
(`hammer2_flush.c:163`) and the mount seeds it to the root's tid plus
one (`hammer2_vfsops.c:1711-1712`), so a raise to the carried tid itself
would issue that tid twice), which makes the counter
a Lamport clock: a transaction that saw an earlier one carries a higher
tid, two writes to one key are strictly ordered because the second
coordinator took part in the first, and the flush's propagation of a
child's tid to its parents (the sync pass's gate) works as it does
locally, because decision A applies commits in tid order on every
master and refuses a stale prepare, so no commit is ever applied under
a parent the flush has already raised past its tid; the SLAVE thread's
rescan set (`hammer2_synchro.c:140-144`) is the thread's own and cannot
be reached from a commit on another host, so the order is a rule of the
protocol and not a repair after the fact. Every modifying storage function already writes
`xop->head.mtid` (`hammer2_xops.c:381, 408, 579, 604`), so the request
structure carries it.

**Catch-up is P9's, not P8's.** The roadmap puts "transaction replay and
the reintegration of a stale master" in P9 and its exit
`stale_master_reintegration` there; P8's `stale_rejoin` exit and S3 ask
that a stale master not regain authority by reconnecting, and L2's
"eventually converges" is P9's. Three readings put bringing a master
level outside P8: the carried pass for a MASTER target excludes its own
slot (`hammer2_synchro.c:1517-1518`), which the check counts as in
progress, so with two masters it returns `EINPROGRESS` and the pass
exits (`:1592-1594`), copying nothing today in any tree
(`cluster-quorum.sh` counts threads at `:126-130` and has never measured
a pass); the default snapshot pass snapshots the source on the source
element's own device (`:801`, `:817`), which for a remote source is the
connection device, where a create is refused; and a master whose PFS is
not mounted on its host registers nothing and runs no pass. **In P8 a
MASTER element gets no synchronization thread**: the creation at
`hammer2_vfsops.c:489` is skipped for MASTER slots whatever
`pfs_nmasters` says, one marked line with `DEFER(P9: reintegration of a
stale master)`, and `cluster-quorum.sh`'s check at `:230`, which asserts two support
threads as its only witness that `pfs_nmasters` is 2, inverts to assert
none and takes a new witness: a `hammer2_debug` print of
`pfs_nmasters` after `hammer2_pfsalloc()`'s count
(`hammer2_vfsops.c:460-461`), read from the klog as the harness reads
its other counts. A SLAVE's thread is unchanged.

**No propagated tid can say whether two masters agree, so the port
compares the one DragonFly reserved for it.** The flush raises a
parent's `modify_tid` to the largest child it writes back and never
lowers it (`hammer2_flush.c:885-887, 932-933`, carried from upstream's
`:1018` and `:1066`), on each host's own schedule, so between two hosts'
flushes an inode chain or a parent reads two tids on a healthy cluster,
and a snapshot modifies the root inode at a tid of its own
(`hammer2_ioctl.c:634-640`). A test on the root's tid and a test on the
modified chain's parent both fail for this reason, and the format's own
comment says why: `mirror_tid` is per cluster node and propagated by
the flush, `modify_tid` is a cluster-level identifier the design meant
not to propagate, and `update_tid` is the cluster-level field
"identical within the topology across all cluster nodes when fully
synchronized" (`hammer2_disk.h:595-601, 636-638`), which the flush does
not propagate (`hammer2_flush.c:270-271`) and no tree writes. **The port
writes `update_tid` and compares it.** `hammer2_chain_modify()` sets
`bref.update_tid` to the transaction's tid wherever it sets `modify_tid`
from one (`hammer2_chain.c:1667-1668`), except where the caller passes a
new `HAMMER2_MODIFY_NOCLC` flag, which the two carried sites that modify
a parent at the transaction's tid for its blockmap alone pass:
`_hammer2_chain_delete_helper()` (`:3437`) and
`hammer2_chain_rename_obref()` (`:3398`), both reached only when the
child is `BLKMAPPED`, that is, already flushed into the parent on that
host, so without the flag a directory's or the root's stamp would move
on the hosts whose flush had run and not on the others. Three marked
lines in `hammer2_chain.c` and one define; the stamp at the one site
with an exclusion was chosen over a stamp at each of the eleven
`chain_modify` and `chain_resize` calls in `hammer2_xops.c` and the two
in `hammer2_strategy.c` because a content site missed there is a chain
the check never compares, a safety hole, while a bookkeeping site missed
here is a stamp that moves with a flush, a liveness defect the control
below reproduces on purpose. The quorum check reads `update_tid` where
it reads `modify_tid`: the four expressions of pass 2
(`hammer2_cluster.c:300-305`) and pass 3's comparison (`:381`). A leaf's
`update_tid` equals its `modify_tid`, since a leaf is modified only under
a tid; an inode chain's is the tid of its last `inode_chain_sync`,
create or rename of its own meta on every host, whatever each host's
flush has since done to its `modify_tid`; the root's moves only with its
own meta; an indirect block is never fed. The two local elements of
`cluster-quorum.sh` are modified by one storage function at one tid and
agree as they do today, which that script reads unchanged. The slave's
pass inserts an inode copy with mtid 0 (`hammer2_synchro.c:1887-1889`)
and a leaf copy with the focus's `modify_tid` (`:1893-1895`), so a leaf
copy is stamped by `chain_modify` and an inode copy is stamped from the
focus's `update_tid` by one marked line there, since pass 3 validates a
slave on the same field (`hammer2_cluster.c:398-406`). The field is on
the media, in every blockref, non-zero where it was zero, and the format
comment gives it as "propagated upward on verification"
(`hammer2_disk.h:597`, `:638`) where the port uses it as an unpropagated
stamp of the record's last cluster-level change: a use of a reserved
cluster field and a change of its stated meaning, both under the first
rule, recorded here as `remote_pfs_type`'s was, with the alternative, a
tid held on `hammer2_chain_t` only, which a master returning from a
restart would read as zero against its peer's value and fail every inode
closed for good. DragonFly's `fsck_hammer2`, `hammer2`, `newfs_hammer2`
and `mount_hammer2` in the clone's sparse checkout read the field
nowhere; stage 1 reads a volume written with it under `fsck_hammer2` and
on the DragonFly guest. The slave's own pass keeps comparing
`modify_tid` as P7 built it (`:1455`, `:1746`), and a slave never votes.

**Level is a per-PFS measure the protocol alone raises, and a fence is
a transaction.** Each master keeps `quorum_tid`, the highest tid it has
committed through the protocol, raised at every commit it applies and
seeded at mount from its MASTER element's root `modify_tid` (its own
line: the seed at `hammer2_vfsops.c:1711-1712` reads the collect's focus,
which may be any element), which after a flush is the largest committed
tid on its media, since under decision A nothing is applied outside a
commit; nothing else moves it, not the flush, not a slave's pass on the
same host, whose tids land on the slave element alone, not bulkfree,
which touches the freemap. Each master also keeps the fence set and the
**epoch**, the count of membership transactions, both agreed: a fence is
prepared on and acknowledged by every other connected, unfenced master
before any commit excludes the fenced one, so every master that applies
a commit holds the same fence set and the same epoch, and a master's
fence is never a fact one coordinator alone knows. Under decision A's
ordering every unfenced master applies the same transactions in tid
order, so two masters with equal epoch and `quorum_tid` have applied the
same set, and a lower `quorum_tid` is a prefix of the other's.
**Registration is a transaction** on the PFS, coordinated by the lower
`pfs_fsid` of the two sides when both receive a span at once, prepared
on every connected, unfenced master, each of which answers after every
commit it holds has been applied; a held registration is not a held
commit and does not wait on one. The coordinator's epoch and
`quorum_tid` are the cluster's: if a connected, unfenced master answers
with other values the coordinator fences the lower side first, so the
value compared is always one every unfenced master agrees on. Equal
means level and the slot votes; lower means the registering master is
behind and registers fenced; higher means it wrote alone with its row
removed and the cluster it rejoins is behind, so both sides fence the
other and the PFS fails closed until P9's record says which side is
current, which is S1, and the `partition` cell's negative control reads
it. An in-doubt intent on either side is resolved by the same reading,
as decision A says. After every master has restarted, epoch and fence
set are empty on all and the media seeds decide, which is sound because
a fenced master applied nothing after its fence. A fenced slot is
counted in `pfs_nmasters` and never in `nmasters`, takes part in no
prepare, is never written through, and every XOP against its own mount
returns decision C's no-quorum errno; the fence is a slot state in
memory on every master, named once in the kernel log with both values
and readable through a `hammer2_debug` print, since `hammer2 -v show`
reads media and cannot see it. A fenced master is not caught up in P8:
reintegration is P9's, a durable record of the last quorum commit, the
catch-up pass over a remote source, and the final blocked pass. A
snapshot's modification of the root inode flushes through
`inode_chain_sync`, one of the 21 descriptors (`hammer2_inode.c:1828`),
so it is prepared and committed at the coordinator's tid on every master
like any other write, raises `quorum_tid` on each, and `pfs_lsnap_tid` is
a value carried, not a tid of its own; the snapshot's own tid goes to
the super-root's new chain (`hammer2_ioctl.c:634-690`). A behind master
whose PFS is unmounted on its host is offline: the server answers
requests against an unmounted PFS `DMSG_ERR_NOSUPP`, the registering
side treats that as not available, and with membership counting it the
quorum fails closed until it is mounted and, in P9, brought level.

**Epoch.** A media field, an extension under the first rule; or derived.
The derived form is the pair above, the count of membership transactions
and `quorum_tid`, both raised only by commits, equal across unfenced
masters by decision A's ordering, and compared at the registration
transaction; the durable record that says which of two forked sides is
current is P9's extension.

**Recommendation: membership 2 with both obligations, one Lamport clock
carried in the prepare, no synchronization thread for a MASTER element
in P8, `update_tid` stamped at the core's one modify site with the two
blockmap sites excluded and compared by the check, level as epoch and
`quorum_tid` compared at a registration transaction, a fence as a
membership transaction every unfenced master applies, epoch derived,
and the reserved field's use the only media change.**

### C. The errno of fail-closed

The three check codes map to `EINPROGRESS`, `ESRCH` and `EDEADLK`
(`hammer2.h:1521-1535`), and the collect turns `ESRCH` and `EDEADLK` at
the end of a scan into `ENOENT` (`hammer2_admin.c:800-812`). With fewer
than `nquorum` masters agreeing the check returns at
`hammer2_cluster.c:338-344`, before pass 3, and `RDHARD` is set for a
MASTER only in pass 3 (`:387-388`), so there is no carried read of a
local focus under quorum loss: today a `lookup` under it reads
`ENOENT`, "no such file", and a `readdir` reads empty. Reads are
already closed, with the wrong errno, and the state model allows a
local read only where the original semantics allow it and stale data
cannot be presented as current, which is Dillon's soft-master mode and
not a P8 mode. The handoff asks for one deterministic user-visible value
when a quorum cannot be formed. Candidates: the carried codes as they
fall out, which is `ENOENT` for reads and `ENOENT` or `EDEADLK` for
writes; `ENOTCONN` for no quorum reachable and `EIO` for a reachable
quorum that disagrees on media; `EAGAIN`, which the sync thread already
uses for its own retry and would be read as that. Precedent: NFS returns
`EIO` for a server it cannot reach by default and `ETIMEDOUT` under
`soft`. The design for the recommended pair: the check counts masters
whose slot is absent or errored with the connection class
(`ETIMEDOUT`, the closed-connection code) and returns a new
`HAMMER2_ERROR_` bit, mapped to `ENOTCONN`, before the
`ESRCH`/`EDEADLK` split, so a read under quorum loss is `ENOTCONN` and
not "no such file"; the end-of-scan path that counts a `(NULL, error)`
master as agreeing (`hammer2_cluster.c:286-291`) excludes an
unreachable one. The `EIO` of disagreement needs a mechanism of its
own: the collect skips a key the check returns `EDEADLK` for and ends
the scan in `ENOENT` (`hammer2_admin.c:805-812`, carried from upstream),
so a disputed key would vanish from a `readdir` and read as absent to a
`lookup`; on a PFS with a remote element the collect returns `EIO` to the
XOP in place of the skip (the errno map at `hammer2.h:1533-1534` has no
`pmp` and returns `EDEADLK` as it is, so the mapping is the collect's),
one marked test beside the carried skip, while `ESRCH`, a key the quorum
does not hold, keeps the skip the port restored for `getdents`. Under
decision A's ordering and visibility rule unfenced masters never
disagree, so `EIO` is the mapping of a state the design says cannot
occur: no cell reads it, its appearance in a kernel log is a finding,
and the control that reverts the check to `modify_tid` must produce it
between two hosts' flushes. Must prove: the value is the same from every VOP for
the same cluster state, read in the `quorum_loss` cell from `touch`,
`mkdir`, `write`, `unlink`, `cat` and `ls`. **Recommendation:
`ENOTCONN` for no quorum reachable, for reads and writes alike, `EIO`
for a reachable quorum that disagrees on media**, each named in the
kernel log once per transition.

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
async and phase-1 refused with `EINVAL` until the mode is measured, and
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
| replay protection | a new mechanism, named as one: `link_verifier`, which the kernel today neither sets nor reads, is a per-connection random value chosen at `LNK_CONN` on a `PROTO_2` connection and checked on every frame, a mismatch ending the connection; a `msgid` is the kernel address of its transaction state (`kern_dmsg.c:1801`), so an aborted request's state is kept allocated, marked abandoned, until the peer's `DELETE` arrives or the connection closes, and its address cannot name a new request while a late reply can still arrive; TLS adds the record layer's protection within a connection |
| message freshness | the request's bound, `remote_timeout_ms`; a reply after its request aborted matches the abandoned state and is dropped there |
| authorization by node type | a MASTER accepts modifying requests only from a MASTER of the same cluster id; a SLAVE's requests are read commands only and a modifying command from one is `DMSG_ERR_NOSUPP`; the check is the requesting peer's `pfs_type` as the fetched root inode states it, cross-checked against its span at registration |
| connection admission | closed by default: `h2service` dials only a peer with a `.pub` key or an explicit `.none` marker in its directory, as `libdmsg` refuses "unknown host"; the kernel registers a span only with a matching `copyinfo[]` row; everything else is monitored and logged, not registered |
| removal and revocation | `REMOTE_DEL` clears the row and tears the slot down by the unmount's loop; the daemon drops the dial; a `.pub` removed revokes at the next handshake |
| key storage | `tlshd`'s, outside the kernel and outside this tree; `h2service`'s key directory is the harness's for stages before 5 |
| encrypted transport | kernel TLS, stage 5; `tcpdump` on the relay port must show no `0x4832` magic in the clear with TLS on and must show it with TLS off |
| a stale node rejoining as current | decision B: its `quorum_tid` reads below the cluster's at the registration transaction, it registers fenced, takes part in no prepare and is never written through; bringing it level is P9's |

## The failure matrix

The handoff's thirteen cells, each with its expected result under the
recommended decisions and the instrument that reads it. The expected
result is written before the run, and the run compares against it.

| cell | topology | expected result | instrument |
|---|---|---|---|
| A dies during prepare | 2 masters | B holds the intent in doubt and fails closed; at A's return the registration reads both level (nothing committed) and B drops the intent; neither media changed, the client read the ruled errno | `fail_quorum_at=preparing` on A, both fingerprints equal to the pre-run, `fsck_hammer2` clean, B's in-doubt line and its drop at registration |
| A dies after prepare | 2 masters | B holds the intent in doubt past the bound and fails closed, no chain modified on either; A's intent is lost with A; at A's return both read level and B drops the intent | `fail_quorum_at=prepared`, the in-doubt line on B after `remote_timeout_ms`, writes on B failing closed until A returns, fingerprints equal to the pre-run |
| A dies before commit | 2 masters | as above; the coordinator never sent commit, so no storage function ran anywhere | `fail_quorum_at=committing` on the coordinator, fingerprints equal to the pre-run |
| A dies after commit acknowledgment | 2 masters | B commits and flushes; the client's write succeeded; if A's media lacks the commit at restart (it died before its flush) A's `quorum_tid`, seeded from its root, reads below B's at the registration transaction, A registers fenced, and the cluster of two fails closed until P9 brings A level; if A's flush completed first the two read equal and the cluster continues | B's media holding the write; A's registration read as the fence line with both values or as level; writes after it failing closed or succeeding to match |
| B loses connectivity to A | 2 masters | with the row present, every write and every read on either side returns the ruled errno (decision C: `ENOTCONN`, not the `ENOENT` the carried check gives today); the log names the transition once | relay partition for frames i..j, `touch` and `cat` on both mounts, the errno and the log line, fingerprints unchanged |
| A/B partition while C is reachable to one side | 3 masters | the side with two of three commits, the lone master owing each commit it could not acknowledge; the lone side fails closed; on heal the lone master's `quorum_tid` reads below at registration, it registers fenced, the two continue, and bringing it level is P9's | relay partition, writes on both sides, fingerprints: two equal and one behind, the fence line on the lone master, writes continuing on the two |
| all but one master disappear | 3 masters | the survivor fails every write and every read closed with the ruled errno; no read of its own focus is served, since the carried check has no such path and soft-master mode is not P8's | relay disconnect of two, `touch` and `cat` errno, fingerprints unchanged |
| stale master reconnects | 2 masters, then 3 | with two masters nothing committed while B was away, since A alone is below quorum; a transaction B held prepared at the drop is in doubt on B and resolves against A's chain at reconnect, and the registration then reads both level and restores liveness (L1); with three, A and C commit while B is away, B reads below at registration, registers fenced, never votes and is never written through (S3), and the two continue; B is brought level in P9 | `stale_rejoin`: the two-master reconnect read as writes failing then succeeding on both sides, with the in-doubt line and its resolution on B when the drop falls between prepare and commit; the three-master run read as the fence line on B, B's media unchanged, A's and C's unchanged by B, writes continuing on the two |
| master storage is stale but reachable | 3 masters | a volume restored from an older image registers with a `quorum_tid` below the cluster's and is fenced; its stale chains never win a vote and it is never written through; bringing it level is P9's | the restored image's value below the cluster's in the fence line, its fingerprint unchanged, the two current masters continuing |
| client disappears during a transaction | 2 masters and a mount | the masters complete or abort among themselves; the client's remount sees one outcome on both | the client guest's power cut between prepare and commit, both masters' fingerprints equal after settle |
| client reconnects after MESI state expiration | deferred with D | not in P8; the trigger is named | the row records the deferral and its trigger |
| transport reconnect during synchronization | a master and a slave on two hosts (stage 2b) | the slave's pass fails its in-flight copies, withholds its stamp, and the next pass after reconnect completes them | relay disconnect mid-pass, the `H2_FAULT`-shaped reading `cluster-sync.sh` already has, under `H2_WIRE=1` |
| healthy | 2 and 3 masters | every write commits on all, fingerprints equal, `fsck_hammer2` clean, no warning | the `2_master_matrix` and `3_master_matrix` baselines |

The `partition` cell's negative control runs under the ruled protocol:
the row removed on one side gives that side a quorum of one, and its
write then commits locally through the partition, which is the fork the
control exists to show; on heal the other side, which committed nothing,
reads below at the registration transaction and registers fenced, and
bringing it level is P9's. A second arm removes both rows and writes on
both sides, the two-sided fork: on heal each side reads the other as
behind while being itself the one that advanced, both fence, every XOP
on either mount returns decision C's no-quorum errno, and neither media
is changed by the other (decision B).
Under the baseline (A's candidate 1) the cell is expected to fork on both
arms, since the local master modifies before the check.

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
peer with no `.none` and no key; the stage 2 read-only gate off must land
a write on the slave alone; `fail_quorum_at` with the protocol's abort
path disabled must leave the two masters' media different; the stale
prepare refusal off must apply a commit under a parent already raised
past it, read as the slave's missed key in stage 2b's wire shape; the
tid-ordered application off must let the three-master interleave leave
one master short of a transaction with `quorum_tid` equal; the
in-flight test off must let a read racing a commit return one host's
content against the other's, read as `EIO` in the healthy cell; the
check reverted to `modify_tid` must return `EIO` between two hosts'
flushes on a healthy cluster; and the fence applied on the coordinator
alone must let a fenced master accept a later prepare and read level at
registration with a transaction missing.

**The marked lines the design implies in carried files**, so the XXX
table in `doc/README.status.md` can be read against them when they land,
each stage adding its own: in `hammer2_chain.c`, the `update_tid` stamp
in `hammer2_chain_modify()` (`:1667-1668`), the `HAMMER2_MODIFY_NOCLC`
flag at the two blockmap sites (`:3398`, `:3437`), and the connection
device's reference in `hammer2_chain_alloc()` and
`hammer2_chain_lastdrop()` (`:176`, `:562`); in `hammer2_cluster.c`, the
four expressions of pass 2 and the one of pass 3 reading `update_tid`
(`:300-305`, `:381`), the in-flight flag counted with `umasters`
(`:280-284`), the reachability bit before the `ESRCH`/`EDEADLK` split
(`:338-344`) and the end-of-scan count excluding an unreachable master
(`:286-291`); in `hammer2_admin.c`, the collect's `EIO` in place of the
`EDEADLK` skip (`:805-812`), its wait on `EINPROGRESS` for a PFS with a
remote element (`:790-791`) and the XOP-level dispatch (`:474`); in
`hammer2_iocom.c`, the span test admitting `PROTO_2` (`:244-247`); in
`hammer2_synchro.c`, the inode copy's stamp (`:1887-1889`); in
`hammer2_vfsops.c`, the MASTER slot's skipped thread (`:489`, the
`DEFER`), the `quorum_tid` seed beside `:1711-1712`, the `statfs` loop
taking the first block device (`:2328-2332`) and `RECLUSTER`'s binding;
and in `hammer2.h`, the flag's define beside `HAMMER2_MODIFY_OPTDATA`
(`:369`). The dispatch sites in `hammer2_io.c` are `/* Linux */` and not
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
`hammer2_iocom.c:362`. `REMOTE_REP` and `SOCKET_SET` stay upstream's
returns of nothing and `SOCKET_GET` stays `EOPNOTSUPP`, each recorded in
the capabilities table with the upstream line, since inventing semantics
for them is an extension no document asks for. `REMOTE_ADD`'s `path` is
what `h2service` dials. `RECLUSTER` is the intake the port has since
1.0.33, with one change marked `XXX`: today it hands the descriptor to
`cluster->focus->hmp` (`hammer2_ioctl.c:99-100`), and with a remote
master the focus is a proxy, so the socket would go to the connection
device, and after a detach on a lost connection, which is when
`h2service` re-dials, the focus is cleared and the ioctl returns
`EINVAL` for a cluster of more than one element (`:103-112`). It hands
the descriptor to the first slot whose `pfs_hmps` is a block device,
the loop `hammer2_vfsops.c:2328-2332` already uses to pick a device, and
reads no focus.

## What this note does not settle

- The four decisions A to D, presented above with recommendations and
  waiting on the maintainer. Stages 1 and 2 proceed without them.
- P9's durable intent log and replay, and the final blocked
  synchronization pass of reintegration; the matrix's "dies after
  prepare" cell leans on the in-memory intent and the level test in P8,
  and on replay in P9.
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
dispatch at `hammer2_admin.c:474`. The third audit (Claude Opus 5.5, 28 tool uses, 11.2 min) found one of
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
audit's result is recorded here when it has run.
