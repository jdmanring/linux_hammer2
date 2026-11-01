# Security Model and Threat Analysis

A summary of security guarantees, assumptions, and interaction boundaries in `linux_hammer2` (version 1.0.72).

## 1. Integrity and Data Protection
- **Block Checksums**: HAMMER2 calculates block checksums across metadata and data blocks, ensuring corruption or silent bit-rot on backing storage is detected on read.
- **Copy-on-Write (CoW)**: Atomic tree updates prevent partial-write corruption of filesystem topology; unreferenced blocks are never overwritten in place.
- **Invariants**: When compiled with `HAMMER2_INVARIANTS=1`, internal assertions (`KKASSERT`, `KASSERTMSG`) catch structural inconsistencies immediately.

## 2. Cluster Transport and Peer Admission
- **Transport Security**: Clustering traffic currently operates over plain TCP/dmsg sockets. Authentication and confidentiality rely on trusted local network boundaries or external VPN/tunnel layers until kernel TLS (kTLS) transport hardening (Stage 5) is fully active.
- **Peer Admission**: Peer node identity and admission are controlled via shared cluster configuration and marker verification (`h2service`). 

## 3. Storage Stack Stack Interaction
- **dm-integrity / dm-crypt**: Can be layered beneath HAMMER2 block devices (`/dev/mapper/...`). The filesystem's internal block validation complements underlying cryptographic confidentiality and physical integrity layers.
- **Root-on-Disk Assumptions**: Block devices must provide reliable ordered flushing (`blkdev_issue_flush`); virtualized or cache-only backing storage without persistent barriers may violate CoW durability assumptions under power loss.
