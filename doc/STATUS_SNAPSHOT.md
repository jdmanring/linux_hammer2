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
  one host copies a master on another.

## How it is verified

The gates are `script/test-*.sh`, listed with what each proves in
`doc/README.testing.md`, and the fleet scripts there that need guest
VMs. Every write operation, from a byte written to a directory renamed,
has been read back by DragonFly and the other way round
(`script/f4-roundtrip.sh`); the cluster's writes have not.
`doc/history/verification-record.md` holds the readings.

## Known limits

- **Cluster link**: plaintext. An enabled `copyinfo` row gates only the
  registration of a remote master, the test harness's `h2service`
  chooses peers by a marker file, and a connected peer can read every
  mounted PFS on the serving device (`doc/SECURITY_MODEL.md`). Kernel TLS is P8's TLS stage, and P7 closes once the pass
  runs over it.
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
