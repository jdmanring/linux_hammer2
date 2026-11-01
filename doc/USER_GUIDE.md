# HAMMER2 on Linux: User Guide

A practical guide to mounting, formatting, snapshotting, deduplicating, and synchronizing HAMMER2 filesystems on Linux 7.3 and newer.

## 1. Formatting and Mounting

HAMMER2 volumes are managed via `hammer2-utils` (`mkfs.hammer2`, `mount.hammer2`, `hammer2`).

### Formatting a Single Volume
To format a block device or image as a HAMMER2 volume:
```bash
mkfs.hammer2 /dev/vdb
```

On Linux, `newfs_hammer2` in `hammer2-utils` performs the same operation:
```bash
sudo newfs_hammer2 -L TEST /dev/vdb
```

### Formatting Across Multiple Devices (Multi-Device)
To format a filesystem across two volumes:
```bash
mkfs.hammer2 -L mypool /dev/vdb /dev/vdc
```

### Mounting by PFS Label
HAMMER2 organizes filesystems into Pseudo-Filesystems (PFS). Mount a PFS by its label:
```bash
mount -t hammer2 -o label=ROOT /dev/vdb /mnt/hammer2
```

Loop devices use the `@LABEL` selector:
```bash
sudo losetup -f --show scratch.img
sudo mount -t hammer2 /dev/loop0@TEST /mnt
```

### Mounting with the Correct Utility Syntax
Give `-s <mount>` before the subcommand, which is required on Linux even though it is optional on the BSDs. Without it the utility looks the mount up through `libfs`, whose Linux build reports no mounted filesystems at all:
```bash
sudo hammer2 -s /mnt pfs-list
sudo hammer2 -s /mnt snapshot /mnt before-upgrade
```

## 2. Taking and Managing Snapshots

Snapshots are full copy-on-write clones of a PFS root inode under the super-root.

### Creating a Snapshot
```bash
hammer2 -d /mnt/hammer2 snapshot snap1
```
This creates a read-only snapshot point. You can mount it directly by its label (`snap1`).

### Deleting a Snapshot
```bash
hammer2 -d /mnt/hammer2 pfs-delete snap1
```
Space is reclaimed across subsequent bulkfree passes (`script/bulkfree.sh`).

## 3. Deduplication and Compression

### Deduplication
Deduplication is active by default. When writing data, the write path checks block hashes before allocating new physical blocks. Identical blocks share storage transparently.

### Compression
Enable compression at mount or via mkfs (supports LZ4 and ZLIB):
```bash
mount -t hammer2 -o compress=lz4 /dev/vdb /mnt/hammer2
```

## 4. Local Synchronization (P7 Local Replication)

HAMMER2 includes a built-in synchronization thread (`hammer2_synchro.c`) that keeps a SLAVE PFS in sync with a MASTER PFS on another device.

### Setting Up Local Replication
1. Ensure both devices are attached.
2. The synchronization thread automatically starts for any SLAVE PFS whose cluster ID matches a MASTER on another local device.
3. Pass verification uses a per-pass snapshot of the master element (`.h2sync-src`) and maintains a last known-good target (`.h2sync-tgt`) on failure.

## 5. File Handles & NFS Export

HAMMER2 registers `export_operations` (`hammer2_export.c`), supporting `name_to_handle_at(2)` and `open_by_handle_at(2)`. It can also be exported over NFS via a running `nfsd` (`script/nfsd-export.sh`), supporting both `subtree_check` and `no_subtree_check` modes.
```bash
exportfs -o rw,no_subtree_check *:/mnt/hammer2
```
