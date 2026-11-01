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
  it (`hammer2_remote_admitted()`); the serving side checks no row. The
  kernel verifies no peer identity, and the test harness's
  `test/h2service.c` chooses whom to connect by a marker file. Run a
  cluster only between hosts on a network you control.
- **What a connected peer can do**: a device announces a span for every
  PFS under its super-root, cluster id included, and the server serves
  any mounted PFS with an element on the device whose cluster id a peer
  names (`hammer2_remote_pfs()`), so a peer can read every mounted PFS on
  it, and every unmounted PFS whose name ends `.h2sync-src`, among them a
  local pass's source snapshot. The server refuses every modifying
  descriptor. Two snapshot commands outside the descriptor table do
  write the serving side's media, whatever the peer's type or the PFS's:
  a peer can have it snapshot any PFS it can read under any name ending
  `.h2sync-src`, which first deletes an existing unmounted PFS of that
  name (a mounted one makes the command fail; read from the code, a
  pass's source of that name is not protected), and can delete a
  snapshot that same link took. Each snapshot costs space until it is
  deleted and the bulkfree scan has run. A PFS with a remote master
  mounts read-only.
- **Next**: kernel TLS through the kernel's handshake upcall, with
  `tlshd` holding the keys, is P8's TLS stage.

## Not read here

Layering beneath dm-crypt or dm-integrity has not been run. Encryption
of the filesystem itself is P14 on the roadmap.
