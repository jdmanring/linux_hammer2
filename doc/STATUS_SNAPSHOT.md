# Current Status Snapshot (1.0.72)

A concise, single-page summary of what is built, tested, and verified in `linux_hammer2`.

## 1. Core Implementation Status

- **Filesystem Core**: DragonFly BSD HAMMER2 core carried verbatim (`src/sys/fs/hammer2/`).
- **OS Shim**: Two-file shim (`hammer2_compat.h`, `hammer2_os.h`) mapping BSD primitives to Linux kernel facilities.
- **VFS Integration**: `->init_fs_context`, `->parse_param`, `->get_tree`, `->reconfigure`, and multi-device volume management (`sget_fc()`).
- **I/O Subsystem**: 64 KiB physical buffer management (`hammer2_io.c`), dio hash under `iohash_lock`, bvecs, and block device open/superblock handling.
- **Sync & Clustering**: Local synchronization thread (`hammer2_synchro.c`), dmsg core (`kern_dmsg.c`), remote XOPs (`hammer2_remote.c`), and loopback clustering.

## 2. Tested Gates & Verification

Eighteen automated gates run via `script/test-*.sh`:
1. `test-inventory.sh`  -  file lists, test runners, and DEFER ledger.
2. `test-citations.sh`  -  citation resolution in `doc/` tables.
3. `test-history.sh`  -  changelog and commit hash validation.
4. `test-provenance.sh`  -  `src/` file origin tracking.
5. `test-absence.sh`  -  uncarried feature claims.
6. `test-shim.sh`  -  stub parser tests with negative controls.
7. `test-ccms-lock.sh`  -  CCMS thread lock release counts.
8. `test-syntax.sh`  -  multi-compiler warning-free build check against the kernel of record (7.3).
9. `test-checkpatch.sh`  -  checkpatch baseline compliance.
10. `test-vectors-contract.sh`  -  Saxum gate interface contract.
11. `test-posix.sh`  -  POSIX sh compliance across dash and busybox ash.
12. `test-doc-prose.sh`  -  Vale prose linting over tracked `.md` files.
13. `test-tools.sh`  -  analysis tool self-tests.
14. `test-report.sh`  -  kernel report verification.
15. `test-reverts.sh`  -  revert commit reason token check.
16. `test-transport.sh`  -  cluster loopback transport replay.
17. `test-fixtures.sh`  -  guest guest-mounted fixture manifest comparison.
18. `test-enospc.sh`  -  full-volume behavior and reserve counts.

## 3. Known Limitations & Gaps

- **Encryption & Auth**: Clustering currently runs plaintext with marker-file peer admission; TLS and lease protocol integration are in active staging (Stage 5/P7c).
- **Root-FS Surface**: Fallocate and O_DIRECT coverage are active targets; full multi-hour soak and swap/suspend flows remain under review.
- **Production Status**: Evaluated for scratch media and multi-device testing; not yet recommended for unattended single-node root deployment without backup.
