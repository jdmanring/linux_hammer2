Linux [HAMMER2](https://gitweb.dragonflybsd.org/dragonfly.git/blob/HEAD:/sys/vfs/hammer2/DESIGN)
========

[![CI](https://github.com/jdmanring/linux_hammer2/actions/workflows/ci.yml/badge.svg)](https://github.com/jdmanring/linux_hammer2/actions/workflows/ci.yml)
[![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](COPYRIGHT)
[![Status](https://img.shields.io/badge/status-1.0.72-blue.svg)](doc/README.status.md)
[![Kernel](https://img.shields.io/badge/linux-7.3%2B-informational.svg)](doc/README.status.md)

A port of DragonFly BSD's HAMMER2 filesystem to the Linux kernel.

HAMMER2 is Matthew Dillon's copy-on-write filesystem for DragonFly BSD, offering atomic snapshots, transparent compression, block-level deduplication, block integrity checksums, and multi-device spanning. This project brings the kernel driver to Linux (Kernel 7.3+) by carrying the DragonFly core verbatim and implementing a lightweight OS shim (`hammer2_os.h`, `hammer2_compat.h`) following Kusumi's FreeBSD/NetBSD/OpenBSD porting patterns.

---

## Core Features

- **Copy-on-Write & Snapshots**: Atomic read-only and writable PFS snapshots managed via `hammer2-utils`.
- **Deduplication & Compression**: Inline block-level deduplication and LZ4/ZLIB compression.
- **Multi-Device Spanning**: Pool formatting across multiple block devices (`mkfs.hammer2 -L pool /dev/vdb /dev/vdc`).
- **Local & Remote Replication**: Built-in synchronization thread (`hammer2_synchro.c`) for local master/slave replication and kernel TLS-backed remote replication.
- **VFS Integration**: Full POSIX read/write support, `SEEK_DATA`/`SEEK_HOLE`, `FIEMAP`, `fsfreeze`, and NFS export operations (`hammer2_export.c`).

---

## Documentation Index

For detailed guides, architectural references, and operator notes, consult the documentation set:

| Topic | Document | Description |
|---|---|---|
| **Current Status** | [doc/STATUS_SNAPSHOT.md](doc/STATUS_SNAPSHOT.md) | Concise executive summary of what is built and verified |
| **Capabilities & Limits** | [doc/CAPABILITIES_MATRIX.md](doc/CAPABILITIES_MATRIX.md) | Authoritative feature matrix and constraints |
| **Operator Guide** | [doc/USER_GUIDE.md](doc/USER_GUIDE.md) | Practical guide to formatting, mounting, and snapshotting |
| **Architecture** | [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md) | System topology, DIO lifetime, and lock hierarchy diagrams |
| **Security Model** | [doc/SECURITY_MODEL.md](doc/SECURITY_MODEL.md) | Integrity guarantees, CoW durability, and threat analysis |
| **Packaging & Initramfs** | [doc/PACKAGING_NOTES.md](doc/PACKAGING_NOTES.md) | Module load order, DKMS, and root-on-HAMMER2 setup |
| **Performance** | [doc/PERFORMANCE.md](doc/PERFORMANCE.md) | Throughput, latency, and soak test methodologies |
| **Verification** | [doc/REPRODUCIBILITY.md](doc/REPRODUCIBILITY.md) | Clean-machine guide to running the 18 automated gates |
| **Release & Roadmap** | [doc/RELEASE_POLICY.md](doc/RELEASE_POLICY.md) | Milestone versioning, tag policy, and upstream strategy |

---

## Quick Start & Installation

```bash
# Build against running kernel headers
make

# Install module (requires root / sudo)
sudo make install

# Format and mount a test image
dd if=/dev/zero of=test.img bs=1M count=1024
mkfs.hammer2 test.img
sudo mount -t hammer2 test.img /mnt/hammer2
```

## Verification & Testing

The repository includes eighteen automated gates in `script/` covering syntax, provenance, citations, and inventory (`test-absence.sh`, `test-ccms-lock.sh`, `test-checkpatch.sh`, `test-citations.sh`, `test-doc-prose.sh`, `test-enospc.sh`, `test-fixtures.sh`, `test-history.sh`, `test-inventory.sh`, `test-posix.sh`, `test-provenance.sh`, `test-report.sh`, `test-reverts.sh`, `test-shim.sh`, `test-syntax.sh`, `test-tools.sh`, `test-transport.sh`, `test-vectors-contract.sh`):

```bash
H2_FIXTURE_START=1 bash script/pre-push-check.sh
```
