# Operators' Capabilities and Limitations Matrix

A single authoritative matrix of supported features, operational flags, and known limits in `linux_hammer2` (version 1.0.72).

| Feature / Subsystem | Status | Operational Flags / Mount Options | Known Limitations / Caveats |
|---|---|---|---|
| **Single-Volume Formatting** | Supported | `mkfs.hammer2 /dev/sdX` | Requires raw block device or image. |
| **Multi-Device Spanning** | Supported | `mkfs.hammer2 -L name /dev/sdA /dev/sDB` | Up to `HAMMER2_MAX_VOLUMES` devices per pool. |
| **PFS Label Mounting** | Supported | `-t hammer2 -o label=ROOT` | PFS root discovery depends on valid super-root metadata. |
| **Snapshots** | Supported | `hammer2 -d <dir> snapshot <name>` | Read-only copy-on-write clones; reclamation via `script/bulkfree.sh`. |
| **Deduplication** | Active by Default | Automatic on write path | Block hash checking happens inline during allocation. |
| **Compression** | Supported | `-o compress=lz4` or `zlib` | LZ4 and ZLIB supported for block storage. |
| **Local Synchronization** | Supported | Automatic via `hammer2_synchro.c` | Requires matching cluster ID between local MASTER and SLAVE PFS. |
| **NFS Export** | Supported | standard `exportfs` over exported mount | Uses `export_operations` (`hammer2_export.c`) for handle mapping. |
| **Clustering / Remote XOPs** | Experimental / Scratch | `script/cluster-wire.sh`, `script/cluster-sync.sh` | Plaintext transport currently; TLS staging underway. |
| **Atime Recording** | Opt-In | `HAMMER2_INVARIANTS=1` or atime build flags | Defaults to returning mtime per Dragonfly BSD spec unless atime mount/build knob is active. |
