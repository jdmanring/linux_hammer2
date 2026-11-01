# Security Model

What the port protects, what it assumes, and where the cluster link
stands. The cluster's security design, with every item of the handoff's
security list, is the security table of `doc/CLUSTER_PROTOCOL_DESIGN.md`;
this page summarizes the parts an operator meets today.

## Integrity on the media

- Every block reference carries a check code, XXH64 by default, on
  data blocks and on every blockref, inode and indirect block, verified
  on read; `hammer2 setcheck` chooses another (`none`, `crc32`,
  `sha192`), which no script here runs. One byte changed in a data block is refused naming
  the check, and a volume header failing its CRC is not mounted
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
- **Admission**: a remote master is registered only against an enabled
  `copyinfo[]` row with its cluster id. The peer's identity is not
  verified by the kernel; the test harness's `test/h2service.c` admits a
  peer by a marker file. Run a cluster only between hosts on a network
  you control.
- **What a remote peer can do**: a PFS with a remote master mounts
  read-only, and the server refuses every modifying descriptor from a
  peer. Two commands outside the descriptor table do write the master's
  media: a peer can have the master take a snapshot of its element,
  only under the pass's `<pfs>.h2sync-src` name (a stale one of that
  name is deleted first), and delete a snapshot that same link took
  (`hammer2_remote.c`, the snapshot commands). Each costs the master
  space until it is deleted and the bulkfree scan has run.
- **Next**: kernel TLS through the kernel's handshake upcall, with
  `tlshd` holding the keys, is P8's TLS stage.

## Not read here

Layering beneath dm-crypt or dm-integrity has not been run. Encryption
of the filesystem itself is P14 on the roadmap.
