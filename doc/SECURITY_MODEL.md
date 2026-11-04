# Security Model

What the port protects, what it assumes, and where the cluster link
stands. The cluster's security design, with every item of the handoff's
security list, is the security table of `doc/CLUSTER_PROTOCOL_DESIGN.md`;
this page summarizes the parts an operator meets today.

## Integrity on the media

- Every block reference carries a check method, XXH64 by default, on data
  blocks and on every blockref, inode and indirect block, verified on
  read. `hammer2 setcheck` chooses another (`crc32`, `sha192`) or none
  at all, and no script here runs it. One byte changed in a data block
  is refused naming the check, and a volume header failing its CRC is not mounted
  (`doc/README.capabilities.md`, DataChecksum and MetadataChecksum).
- Writes are copy-on-write: a modified block is written to a new
  location and committed by the volume header, so a crash leaves the
  last committed tree. Space is reused only after the bulkfree scan.
- Scrubbing is offline only, `fsck_hammer2` over an unmounted volume.
- Built with `HAMMER2_INVARIANTS=1`, the carried core's assertions run;
  without it they are compiled out, and the port's own code fails an
  operation with an errno rather than asserting.

## What the device must do

The volume flush issues a device cache flush before it writes the volume
header (`hammer2_flush.c`, the `VOLUMESYNC` arm), the order DragonFly
uses. A device or virtual disk that acknowledges a cache flush without
making the data durable can lose the last committed transaction on
power loss, as with any filesystem that commits through a header.

`fsync` issues no device cache flush. It flushes the file's buffers and
the inode's chains and writes the block device back
(`sync_blockdev()`), which is what DragonFly's `fsync` and the FreeBSD
port's do; a write `fsync` returned on is durable only as far as the
device keeps its write order, and the cache flush comes with the next
volume flush (`doc/history/verification-record.md`, "Per-operation
latency, the half that was never measured").

## Local callers

Every HAMMER2 ioctl wants `CAP_SYS_ADMIN` except the version query and
`HAMMER2IOC_INODE_GET`, which any user with a file open on the volume
may issue. DragonFly also lets any user start a bulkfree scan; the port
does not, since a scan syncs every PFS on the device holding the global
mount lock (`hammer2_mntlk`), during which mounts, unmounts, pfs-delete
and every cluster request on the host wait, and then holds the device's
bulkfree lock across a pass over its metadata, which delays any other
scan. `test-fixtures.sh` reads the refusal as an unprivileged user.

## The cluster link

- **Transport**: TCP carrying DragonFly's `dmsg` frames, plaintext unless
  the intake asks for TLS (the TLS bullet below). On a
  link whose peer announced `DMSG_SPAN_PROTO_2` both CRCs of every frame
  are verified and a mismatch ends the link; that is integrity against
  corruption, not authentication.
- **Admission**: the serving side serves a mounted PFS only while the
  device holds an enabled `copyinfo[]` row for its cluster id
  (`hammer2_remote_pfs()`, through `hammer2_remote_admitted()`), and an
  unmounted PFS only when it is a snapshot the same link took. Registering
  a remote master needs an enabled row whose type is MASTER. On a
  plaintext link the kernel verifies no peer identity, so any peer the
  userland service connects is admitted to every cluster the device has
  a row for; the test harness's `test/h2service.c` chooses whom to
  connect by a marker file. Run a plaintext cluster only between hosts on
  a network you control.
- **What a connected peer can do**: the server serves a PFS whose
  cluster id a peer names, under the admission above. On a plaintext
  link the device announces every PFS present when the peer answers the
  device's own `LNK_CONN`, cluster id included; on a TLS link it
  announces only the PFSs whose cluster ids the peer's key is bound to.
  The server refuses every modifying descriptor. Two snapshot commands
  outside the descriptor table do write the serving side's media,
  whatever the peer's span type. SNAPSHOT is served only from an
  admitted source that is mounted and is a MASTER element. The server
  names the snapshot itself, `<source label>.h2sync-peer`, so a link
  holds at most one per source PFS. A source label of 128 bytes or more
  is refused. Before taking it the server deletes an unmounted PFS of
  that name only if it is itself a snapshot; one of any other kind is
  kept and the command refused. SNAPDEL deletes only a snapshot the same
  link took, found by its cluster id. A link's snapshots are deleted when
  the link is torn down, at the next intake or the unmount, not when the
  peer closes its end. `pfs-create`, the snapshot ioctl and every mount
  refuse a PFS name ending `.h2sync-src` or `.h2sync-peer`; a local
  pass's own stale delete also takes only a snapshot. Each snapshot
  costs space until it is deleted and the bulkfree scan has run. Each
  request holds the host's
  global mount lock (`hammer2_mntlk`) until it is answered, since a PFS
  carries no reference count that could hold it instead: up to
  `remote_timeout_ms` for the request plus the storage call's own run,
  for a read as long as the inode it names takes and for a snapshot
  command a flush of the PFS and any stale snapshot's delete, during which a
  mount, unmount, pfs-delete or bulkfree on the host waits and the
  synchronization thread skips its pass. On a plaintext link the device
  also sends a peer every `copyinfo` row with a nonzero copyid as
  `VOLCONF` (on a TLS link only the rows of its key's bound clusters), its label and
  `span:HOST:PORT` path included, on the peer's reply to the device's own `LNK_CONN`
  and again on each `REMOTE_ADD` and `REMOTE_DEL`
  (`hammer2_volconf_update()`), so a peer learns every cluster peer the
  host is configured to dial. No kernel reads that message, but
  DragonFly's `hammer2 service` dials each row it receives. A PFS with a
  remote master mounts read-only.
- **TLS, with a pre-shared key**: an intake can ask for a PSK handshake through
  the kernel's handshake upcall (`cluster_tls=psk`, or `RECLUSTER`'s TLS
  inputs), with `tlshd` holding the keys and the kernel only their
  serials, and a server intake then admits only a peer whose key serial
  it named. Read on both guest kernels on one guest: a link between
  two volumes over TCP loopback completes the handshake with `tlshd`,
  runs with kTLS on both sockets and carries no frame in the clear; a
  wrong PSK is refused at both ends; and a server refuses a peer whose
  key `tlshd` found but the intake did not name. A TLS record that is
  not data is read by its type: a session ticket is dropped and the
  link serves on, and a KeyUpdate or an alert ends the
  link with a named line, read against a GnuTLS peer on both guest
  kernels. Between two guests, `test/h2service.c`'s dial takes the
  same TLS inputs, and `script/cluster-wire.sh H2_WIRE_TLS=1` runs that
  link through a relay that copies bytes, read on `h2debug-7.3tls` at
  1.0.78 (37 checks with 0 failed, run `wire-run-20261102-221701`, kept
  under `p7-notes/n9-5-wire-20261102-214846/` in the data tree); the two-host synchronization pass over TLS was read at 1.0.80 on both
  `-tls` kernels (`wire-run-20261103-111156` and `-113404`). Each key an intake
  admits is bound to the cluster ids the intake names for it
  (`RECLUSTER`'s key and cluster-id pairs, or `cluster_tls_clid=` after
  its `cluster_tls_key=` on the mount path); an intake naming a serial
  twice, binding no cluster id, or admitting a key it binds to no cluster
  id, is refused before any handshake. A
  TLS link records the key it proved and that set when its connection
  is installed, and refuses a span, a registration or a request for a
  cluster id outside the set, each with a named line (stage 5.5 of
  `doc/CLUSTER_PROTOCOL_DESIGN.md`). A revoked key is refused at its
  next handshake, but a link already up stays up, since TLS
  authenticates once per connection, and an intake that fails leaves the
  old link and its record running, an older and broader binding
  included when the new intake would have narrowed it. Unmounting the
  volume ends such a link, or
  removing the cluster's row stops its service at the next request, at
  the cost of every peer of that cluster. The
  `cluster_tls_required` module parameter (0 by default) refuses a
  plaintext intake when set to 1. Not built: x509 certificates, deferred
  in `doc/CLUSTER_PROTOCOL_DESIGN.md`'s TLS section with their trigger;
  `link_verifier`, the per-connection value its security table designs
  against a frame replayed onto another connection; revoking a live link
  without an unmount; and a rekey, so a KeyUpdate ends the link.

## Not read here

Layering beneath dm-crypt or dm-integrity has not been run. Encryption
of the filesystem itself is P14 on the roadmap.
