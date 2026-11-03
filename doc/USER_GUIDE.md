# User Guide

How to format, mount, snapshot, compress and replicate with this port.
The commands below follow the README and the scripts under `script/`,
except `setcomp`, which only `test/hammer2-seek.c` runs here; the userland is [hammer2-utils](https://github.com/kusumi/hammer2-utils)
(`newfs_hammer2`, `hammer2`, `fsck_hammer2`). Use scratch media: the
port is not yet recommended for data you cannot restore.

## Build, load, format, mount

```sh
make && sudo make install
sudo modprobe hammer2
truncate -s 8G scratch.img
newfs_hammer2 -L TEST scratch.img
sudo losetup -f --show scratch.img
sudo mount -t hammer2 /dev/loop0@TEST /mnt
```

`losetup` prints the device it chose. A PFS is mounted by its label,
with the source written `<device>@<label>`. A mount that names no PFS asks for `DATA`, which
`newfs_hammer2` creates only when it is given no `-L`, so after the
format above name `@TEST`. Add
`-o ro` to read without writing; `mount -o remount,rw` goes the other
way. A volume DragonFly made mounts the same way.

## The `hammer2` utility

Give `-s <mount>` before a subcommand that acts on a mounted
filesystem, as `pfs-list`, `pfs-create`, `pfs-delete`, `snapshot` and
`bulkfree` do. It is optional on the BSDs and needed here, because the
utility otherwise looks the mount up through a library whose Linux
build reports no mounted filesystems. `setcomp` opens the path it is
given and needs none.

```sh
sudo hammer2 -s /mnt pfs-list
sudo hammer2 -s /mnt pfs-create WORK
sudo mount -t hammer2 /dev/loop0@WORK /mnt/work
```

## Snapshots

```sh
sudo hammer2 -s /mnt snapshot /mnt before-upgrade
sudo mount -t hammer2 /dev/loop0@before-upgrade /mnt/snap
sudo hammer2 -s /mnt pfs-delete before-upgrade
```

A snapshot is a PFS of its own and mounts by its label. Deleting one
returns its space only after the bulkfree scan has run twice:

```sh
sudo hammer2 -s /mnt bulkfree /mnt
```

## Compression and deduplication

Compression is set per directory and applies to what is written below
it afterwards; there is no mount option for it.

```sh
sudo hammer2 setcomp lz4 /mnt/logs      # or zlib, autozero, none
```

Deduplication is on by default: the write path looks for an identical
block before it allocates a new one.

## Replication between two local volumes

A second PFS created with the first's cluster id joins its cluster, and
the synchronization thread keeps a SLAVE equal to its MASTER. This is
the sequence `script/cluster-sync.sh` runs, with the master on `vdb` and
the slave on `vdc`:

```sh
mount -t hammer2 /dev/vdb@ROOT /mnt/m
hammer2 -s /mnt/m pfs-create CL
clid=$(hammer2 -s /mnt/m pfs-list | awk '$3 == "CL" { print $2 }')
mount -t hammer2 /dev/vdb@CL /mnt/cl
mount -t hammer2 /dev/vdc@ROOT /mnt/s
hammer2 -s /mnt/s -t SLAVE -u "$clid" pfs-create CL
```

Writes go through `/mnt/cl`. Each pass reads a snapshot of the master
named `<pfs>.h2sync-src`, which refuses any mount, and keeps the slave's
last verified copy as `<pfs>.h2sync-tgt` until a pass verifies again.
A master changed while the slave is mounted reaches the slave's media
at the slave's unmount.

Replication from a master on another host exists, read-only, its pass
read so far over a plaintext link (the link itself also runs over kTLS
with a pre-shared key), and is driven today by the test harness
(`script/cluster-wire.sh`); `doc/STATUS_SNAPSHOT.md` says where it stops.

## Export

A mounted PFS can be exported by `nfsd` as any filesystem is, under
either `subtree_check` or `no_subtree_check`, and supports
`name_to_handle_at(2)` and `open_by_handle_at(2)`.

## Checking a volume

```sh
sudo umount /mnt
fsck_hammer2 scratch.img
```

`fsck_hammer2` is offline only; nothing scrubs a mounted volume yet.
