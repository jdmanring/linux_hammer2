Linux [HAMMER2](https://gitweb.dragonflybsd.org/dragonfly.git/blob/HEAD:/sys/vfs/hammer2/DESIGN)
========

[![CI](https://github.com/jdmanring/linux_hammer2/actions/workflows/ci.yml/badge.svg)](https://github.com/jdmanring/linux_hammer2/actions/workflows/ci.yml)
[![License: BSD-3-Clause](https://img.shields.io/badge/license-BSD--3--Clause-blue.svg)](COPYRIGHT)
[![Status](https://img.shields.io/badge/status-1.0.72-blue.svg)](doc/README.status.md)
[![Kernel](https://img.shields.io/badge/linux-7.3%2B-informational.svg)](doc/README.status.md)

A port of DragonFly BSD's HAMMER2 filesystem to the Linux kernel.

HAMMER2 is Matthew Dillon's copy-on-write filesystem for DragonFly BSD, offering atomic snapshots, transparent compression, block-level deduplication, block integrity checksums, and multi-device spanning. Tomohiro Kusumi has since ported it to [FreeBSD](https://github.com/kusumi/freebsd_hammer2), [NetBSD](https://github.com/kusumi/netbsd_hammer2) and [OpenBSD](https://github.com/kusumi/openbsd_hammer2), and written the Linux userland ([hammer2-utils](https://github.com/kusumi/hammer2-utils), [hammer2-fuse](https://github.com/kusumi/hammer2-fuse)). The kernel side on Linux is the piece that has been missing.

This port follows Kusumi's method: the DragonFly core is carried and kept readable as DragonFly's, with every port edit marked in place with `XXX`, and an OS shim (`hammer2_compat.h`, `hammer2_os.h`) maps BSD primitives to Linux kernel facilities. Same file names, same shim split, same section order, so a fix found here is legible to the other three ports and can travel.

---

## 1. What Works and What Remains

At a glance, on Linux kernel 7.3 or newer:

- **Works**: Read-write mount by PFS label; read, write, mmap and exec (it has booted as a root filesystem on a guest); snapshots and writes into them; multi-device pool spanning across two volumes; PFS create, delete, and list via `hammer2-utils`; LZ4 and ZLIB compression; inline block-level deduplication; crash recovery verified against the FreeBSD port; `SEEK_DATA`, `SEEK_HOLE`, `FIEMAP`, and `fsfreeze`.
- **Works with caution**: Filling a HAMMER2 volume to capacity correctly refuses new writes while keeping existing files whole (verified via `script/test-enospc.sh` after fixing prior circular locks and unmount page faults). A real Nix closure of 200,000 files copies in and reads back beside squashfs, erofs, and ext4 on a 4 GiB guest.
- **New and narrow**: Synchronization thread (`hammer2_synchro.c`) keeping a SLAVE PFS in step with a MASTER on a second local device; two-master quorum clustering; and P7 remote replication where a slave on one guest copies a master's PFS on another over plaintext (kernel TLS staging underway in P8).
- **Not verified / Unbuilt**: `O_DIRECT` (refused); small-file create/delete rates, mixed mmap/fsync storms, and `nfsd` exports (covered by dedicated exercisers `million-tree.sh`, `storm.sh`, `nfsd-export.sh`).

Every write operation has been run on scratch media and verified in both directions against DragonFly. The crash matrix (writer killed, kernel panicked, power cut, volume header torn) leaves media that both this port and the FreeBSD port recover to the identical tree.

---

## 2. Documentation Index

For operators, reviewers, and porters, the project maintains an authoritative documentation corpus:

| Topic | Document | Description |
|---|---|---|
| **Status Snapshot** | [doc/STATUS_SNAPSHOT.md](doc/STATUS_SNAPSHOT.md) | Concise executive summary of built and verified features |
| **Capabilities & Limits** | [doc/CAPABILITIES_MATRIX.md](doc/CAPABILITIES_MATRIX.md) | Authoritative capability levels and constraints |
| **User Guide** | [doc/USER_GUIDE.md](doc/USER_GUIDE.md) | Practical guide to formatting, mounting, and snapshotting |
| **Architecture** | [doc/ARCHITECTURE.md](doc/ARCHITECTURE.md) | System topology, DIO lifetime, and lock hierarchy diagrams |
| **Security Model** | [doc/SECURITY_MODEL.md](doc/SECURITY_MODEL.md) | Integrity guarantees, CoW durability, and threat analysis |
| **Packaging & Initramfs** | [doc/PACKAGING_NOTES.md](doc/PACKAGING_NOTES.md) | Module load order, DKMS, and root-on-HAMMER2 setup |
| **Performance** | [doc/PERFORMANCE.md](doc/PERFORMANCE.md) | Throughput, latency, and soak test methodologies |
| **Verification** | [doc/REPRODUCIBILITY.md](doc/REPRODUCIBILITY.md) | Clean-machine guide to running the 18 automated gates |
| **Release & Roadmap** | [doc/RELEASE_POLICY.md](doc/RELEASE_POLICY.md) | Milestone versioning, tag policy, and upstream strategy |
| **Changelog** | [CHANGELOG.md](CHANGELOG.md) | Point releases pinned to commits and verifying gates |
| **Status Authority** | [doc/README.status.md](doc/README.status.md) | Detailed verification status and file origin table |
| **Port Decisions** | [doc/README.porting.md](doc/README.porting.md) | Detailed rationale for every porting choice |

---

## 3. Quick Start & Installation

### Requirements
- Linux kernel 7.3 or higher (enforced by `#error`).
- Kernel headers for the running kernel (or `KDIR=/path/to/kernel/build`).
- `CONFIG_TRANSPARENT_HUGEPAGE` (required for 64 KiB physical buffers).
- `CONFIG_LZ4_COMPRESS`, `CONFIG_ZLIB_DEFLATE`, and `CONFIG_XXHASH`.
- [hammer2-utils](https://github.com/kusumi/hammer2-utils) installed in userland.

### Build and Install
```bash
make
sudo make install
sudo modprobe hammer2
```

### Formatting and Mounting
```bash
truncate -s 8G scratch.img
newfs_hammer2 -L TEST scratch.img
sudo losetup -f --show scratch.img
sudo mount -t hammer2 /dev/loop0@TEST /mnt
```

---

## 4. Verification & Testing

The repository contains eighteen automated gates in `script/` (`test-absence.sh`, `test-ccms-lock.sh`, `test-checkpatch.sh`, `test-citations.sh`, `test-doc-prose.sh`, `test-enospc.sh`, `test-fixtures.sh`, `test-history.sh`, `test-inventory.sh`, `test-posix.sh`, `test-provenance.sh`, `test-report.sh`, `test-reverts.sh`, `test-shim.sh`, `test-syntax.sh`, `test-tools.sh`, `test-transport.sh`, `test-vectors-contract.sh`):

```bash
H2_FIXTURE_START=1 bash script/pre-push-check.sh
```

---

## Credit & License

- **Matthew Dillon**: Designer and author of HAMMER2 for DragonFly BSD.
- **Tomohiro Kusumi**: Author of the FreeBSD, NetBSD, and OpenBSD kernel ports and Linux userland tools.
- **License**: BSD-3-Clause. See [COPYRIGHT](COPYRIGHT).
