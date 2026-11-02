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

## The cluster link

- **Transport**: plaintext TCP carrying DragonFly's `dmsg` frames. On a
  link whose peer announced `DMSG_SPAN_PROTO_2` both CRCs of every frame
  are verified and a mismatch ends the link; that is integrity against
  corruption, not authentication.
- **Admission**: an enabled `copyinfo[]` row with the cluster id gates
  only the registration of a remote master, on the side that registers
  it (`hammer2_remote_admitted()`); the serving side checks no row. On
  a plaintext link the kernel verifies no peer identity, and the test
  harness's
  `test/h2service.c` chooses whom to connect by a marker file. Run a
  cluster only between hosts on a network you control.
- **What a connected peer can do**: the server serves any PFS with an
  element on the device whose cluster id a peer names, mounted or
  unmounted and named `*.h2sync-src` (`hammer2_remote_pfs()`), and the
  device announces every PFS present when the link's `LNK_CONN` arrives,
  cluster id included. So a peer can read every PFS of those two kinds
  that existed when the link came up. A snapshot taken later carries a
  fresh random cluster id no span announces, so a local pass's source
  snapshot is readable only if it existed then. The server refuses every
  modifying descriptor. Two snapshot commands outside the descriptor table do
  write the serving side's media, whatever the peer's type or the PFS's:
  a peer can have it snapshot any PFS it can read under any name ending
  `.h2sync-src`, which first deletes an existing unmounted PFS of that
  name (a mounted one makes the command fail). The delete is by name, and
  a pass's source name is its PFS's label with that suffix, so read from
  the code a pass's source can be deleted at any time. The same link can
  also delete a snapshot it took. Each snapshot costs space until it is
  deleted and the bulkfree scan has run. Each request holds the host's
  global mount lock (`hammer2_mntlk`) until it is answered, since a PFS
  carries no reference count that could hold it instead: up to
  `remote_timeout_ms` for the request plus the storage call's own run,
  whose length the peer chooses by the inode it names, during which a
  mount, unmount, pfs-delete or bulkfree on the host waits and the
  synchronization thread skips its pass. A PFS with a remote master
  mounts read-only.
- **TLS, in progress**: an intake can ask for a PSK handshake through
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
  kernels. No link between two guests runs TLS: every link
  `test/h2service.c` dials is plaintext, since it asks for no
  handshake. The
  `cluster_tls_required` module parameter (0 by default) refuses a
  plaintext intake when set to 1. The rest is P8's TLS stage.

## Not read here

Layering beneath dm-crypt or dm-integrity has not been run. Encryption
of the filesystem itself is P14 on the roadmap.
