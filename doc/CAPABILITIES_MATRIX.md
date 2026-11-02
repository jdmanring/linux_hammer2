# Capabilities at a Glance

How to use each feature and where it stops. `doc/README.capabilities.md`
is the authority, one row per capability with the reading behind it;
this page is the operator's summary of it. The commands follow the
README and the scripts under `script/`; a row whose command neither runs
says so.

| Feature | State | How | Limit |
|---|---|---|---|
| Format a volume | supported | `newfs_hammer2 -L LABEL <device or image>` (hammer2-utils) | a filesystem across two volumes is one `newfs_hammer2 -L LABEL <dev1> <dev2>`; see the next row |
| Mount a PFS | supported | `mount -t hammer2 <device>@LABEL <dir>`; a mount naming no PFS asks for `DATA`, which `newfs_hammer2` creates only when given no `-L` | the module's own mount options are `emerg`, `cluster_fd=` and the link's TLS inputs `cluster_tls=psk`, `cluster_tls_role`, `cluster_tls_keyring` and `cluster_tls_key`, which only `cluster_fd=` reads; `-o ro` and `-o remount,rw` work as usual |
| More than one volume | supported | the device list `/dev/a:/dev/b@LABEL` | read by `script/pfs-domains.sh` with `H2_PFS_VOLUMES=2`, with DragonFly mounting the same pair; adding a volume to a mounted filesystem has not been run |
| Snapshots | supported | `hammer2 -s <mnt> snapshot <mnt> <name>`; each is a PFS of its own, mounted by its label | space comes back only after the bulkfree scan, `hammer2 -s <mnt> bulkfree <mnt>`, runs twice (`script/bulkfree.sh`) |
| Deduplication | on by default | the write path asks before every data block is allocated | |
| Compression | supported | per directory, `hammer2 setcomp lz4 <dir>` (or `zlib`, `autozero`, `none`) | no mount option; LZ4 and ZLIB read and written both ways with DragonFly; `setcomp` is run here only by `test/hammer2-seek.c`, with `none` and `zlib:9` |
| Local replication | limited | a second PFS created with the first's cluster id, `hammer2 -s <mnt> -t SLAVE -u <clid> pfs-create <name>`, both volumes mounted | a master that changes while the slave is mounted reaches the slave's media at its unmount |
| Replication from another host | limited | the remote element of `doc/CLUSTER_PROTOCOL_DESIGN.md`, driven by the test harness (`test/h2service.c`, `script/cluster-wire.sh`) | plaintext link; the PFS is read-only; no shipped daemon |
| NFS export | supported | `exportfs` of a mounted PFS | read by `script/nfsd-export.sh` under both subtree modes |
| `fallocate` | supported | `fallocate(1)`, including punch and zero range | no collapse or insert range (`EOPNOTSUPP`); an allocated range reserves no space and reads back as a hole, since the format stores no zero block |
| `O_DIRECT` | not served | | by decision, `doc/README.roadmap.md`, "Not on the roadmap" |
| Stored atime | build option | `make HAMMER2_ATIME=1` | the default reports mtime as atime, as DragonFly does |
