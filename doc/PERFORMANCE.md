# Performance Expectations

Dated performance guidance for `linux_hammer2` (version 1.0.72, recorded 2026-10-31).

## Methodology and Environment
- **Environment**: Guest fleet running on KVM/QEMU with 12 vCPUs and 4 to 8 GiB RAM per guest, under host load of ~0.7 load average on 24 cores (93 GiB host memory).
- **Kernels Tested**: Kernel of record `7.3` across debug (`h2debug-7.3`), sanitizer/KASAN (`h2kasan-7.3`), and release (`h2release-7.3`) builds.
- **Exercisers**: `script/throughput.sh` (single large-file timing), `script/latency.sh` (fsync/read beside ext4 and btrfs), `script/storm.sh` (mapped and fsync writers against readers on one file set), and `script/nix-closure.sh` (cold read of a real package closure beside squashfs and erofs).
- **Controls**: Rates are meaningful only beside an in-run control on the same host and kernel; a host-cache read is guarded by the ext4 control in the same boot.

## Controlled Rate Measurements
| Workload / Instrument | Kernel / Guest Config | Measured Performance | Baseline Reference |
|---|---|---|---|
| **Sequential throughput** (`throughput.sh`) | `h2release-7.3` (Release build) | 1 large file: matches or approaches ext4 on write after block allocator stabilization; read rates exceed host cache primitive | `ext4` control in-run |
| **Snapshot pass cost** (`cluster-sync.sh`) | `h2release-7.3` at 1,000,000 files | Lever 1 narrowed pass: **12.7 s** (compared to carried ~32.8 s unoptimized); 100,000 files: **0.90 to 0.95 s** | Carried baseline (~32.8 s / ~2.3 s) |
| **Read and fsync latency** (`latency.sh`) | `h2debug-7.3` / `h2release-7.3` | Fsync cost follows the volume flush path (`->fsync` / `blkdev_issue_flush`) | `ext4` and `btrfs` in-run |
| **Mixed mapped plus fsync writers** (`storm.sh`) | `h2kasan-7.3` (KASAN build) | 800 cycles of storm load with `writepages` queuing inodes | Same shape on `ext4` |
| **Cold package closure read** (`nix-closure.sh`) | `h2release-7.3` | 200,000 files copied and read back cold | `squashfs` and `erofs` in-run |

## Caveats
- No single committed number ships here: rates move with the kernel of record (7.3), the guest kind (`h2debug`, `h2kasan`, `h2release`), and host load. Each record entry in `doc/history/verification-record.md` carries its build hash, start state, and repeat count beside any number it cites.
- Sequential device mapping read-ahead uses `page_cache_sync_ra` with the BSD hint; a measured jump (353 to 683 MiB/s in one dated reading) held only after the host cache was primed, so an unprimed host-cache read is not a result.

