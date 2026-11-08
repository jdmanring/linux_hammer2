# Status Snapshot

One page on where the port stands. `doc/README.status.md` is the
authority on what exists and what has been verified, and
`CHANGELOG.md`'s newest row names the version and the commit it pins;
where this page and either of them disagree, they are right and this
page is the defect.

## What is built

- **The core** is DragonFly's HAMMER2, carried from DragonFly, most of it
  through the FreeBSD port, and kept readable as DragonFly's. A line this
  port changed in a carried file is marked `/* Linux */`, and `XXX` where
  it is a compromise rather than a translation; `doc/README.status.md`'s
  `XXX` table counts the latter per file.
- **The shim** is two files, `hammer2_os.h` for the primitives (locks,
  allocation, print) and `hammer2_compat.h` for what looks like a
  DragonFly kernel facility, in the BSD ports' split.
- **The VFS half** is the port's own: the mount API (`->init_fs_context`,
  `->parse_param`, `->get_tree`, with `sget_fc()`), file operations,
  address-space operations, `fiemap`, `fsfreeze`,
  `SEEK_DATA`/`SEEK_HOLE`, `fallocate`, and NFS export
  (`hammer2_export.c`).
- **Clustering**: the local synchronization thread
  (`hammer2_synchro.c`), the message core (`kern_dmsg.c`), and a remote
  element over the wire (`hammer2_remote.c`) through which a slave on
  one host copies a master on another. Two MASTERs of one cluster id on
  two local volumes are read through DragonFly's quorum check: a block
  the masters disagree on fails its read, seek and map with EIO rather
  than reading as a hole or as one master's copy. A read, seek or map
  that meets a change on one master and not yet the next waits for it
  under the inode's order and answers (1.0.94). A lookup does not wait
  yet: one made between two masters' flushes or chain syncs of an inode
  can fail EIO on a healthy cluster, read from the code and not run.

## How it is verified

The gates are `script/test-*.sh`, listed with what each proves in
`doc/README.testing.md`, and the fleet scripts there that need guest
VMs. Every write operation, from a byte written to a directory renamed,
has been read back by DragonFly and the other way round
(`script/f4-roundtrip.sh`); the cluster's writes have not.
`doc/history/verification-record.md` holds the readings.

## Known limits

- **Cluster link**: a PSK handshake can be asked for at the intake. On
  one guest, a link between two volumes over TCP loopback completes it
  with `tlshd` and runs over kTLS, and a wrong or unadmitted key is
  refused, read on both guest kernels. Between two guests,
  `test/h2service.c`'s dial asks for it too, and `cluster-wire.sh
  H2_WIRE_TLS=1` runs the default shape through a relay that copies
  bytes, with no frame in the clear, read on both `-tls` builds at
  1.0.80, as was the synchronization pass over that link. A TLS
  record that is not data is read by its type: a session ticket is
  dropped and the link serves on, and a KeyUpdate or an alert ends the
  link with a named line, read against a GnuTLS peer on both guest
  kernels.
  The serving side serves a mounted PFS only while the device holds an
  enabled `copyinfo` row for its cluster id, and an unmounted one only as
  a snapshot the same link took; a peer's snapshot is named by the
  server, one per source per link, and a stale one is deleted only if it
  is itself a snapshot. A TLS key is bound to cluster ids at the intake,
  and the link refuses spans, registrations and requests outside that
  set. A revoked key is refused at its next handshake, but a link already
  up stays up until the volume is unmounted; removing or disabling the
  cluster's row stops that cluster's service on every link at the next
  request, at the cost of every peer of that cluster. An intake that
  fails leaves the old link and its binding running. On a plaintext link the kernel verifies no peer identity, so
  whoever the userland service connects is admitted to every cluster the
  device has a row for and is sent every configured peer row as
  `VOLCONF`, dial paths included; the test harness's `h2service` chooses
  peers by a marker file. Each request a peer sends holds the host's
  global mount lock until it is answered. Run a plaintext cluster only on
  a network you control (`doc/SECURITY_MODEL.md` has the rest). Not
  built: x509 certificates, a per-connection verifier against a frame
  replayed onto another connection, and a rekey, so a KeyUpdate ends a
  TLS link. A candidate read from the code and not driven: a peer that
  never closes a request the client gave up on keeps that request's
  state held until the link ends, with no bound found. P7 is closed at
  1.0.84, its closure mapping the pass's reading over TLS and the five
  criteria to their runs.
- **A SLAVE behind its MASTER under a partial write**: a write of less
  than a 64 KiB block into a block the slave holds stale leaves both
  volumes holding it at the master's tid with different contents,
  measured by `script/cluster-sync.sh` at 1.0.93; not fixed. From the
  code, the slave keeps its old bytes beside the new ones and the
  synchronization pass, which compares tids, never replaces them. Two MASTERs reach
  the same assembly, from the code, through a page cached before their
  block came to be disputed.
- **Writes through a cluster with a remote master**: refused; such a
  PFS mounts read-only until P8's lease protocol, whose design note is
  not yet written.
- **`O_DIRECT`**: not served, by decision (`doc/README.roadmap.md`, "Not
  on the roadmap").
- **Swap files**: not supported; the port has no `->swap_activate`.
- **More than one volume in one filesystem**: a filesystem formatted
  across two images mounts here by the device pair (`/dev/a:/dev/b@LABEL`)
  and DragonFly checks it (`script/pfs-domains.sh` with
  `H2_PFS_VOLUMES=2`); adding a volume to a mounted filesystem has not
  been run on either side.
- **Media**: every write so far has been to a scratch image on a guest;
  nothing is packaged.
