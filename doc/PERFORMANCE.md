# Performance Expectations

Dated performance guidance for `linux_hammer2` (version 1.0.72, recorded 2026-10-31).

## Methodology
- Guest fleet testing uses `script/throughput.sh` (single large-file timing), `script/latency.sh` (fsync/read beside ext4 and btrfs), `script/storm.sh` (mapped and fsync writers against readers on one file set), and `script/nix-closure.sh` (cold read of a real package closure beside squashfs and erofs).
- Rates are meaningful only beside an in-run control on the same host and kernel; a host-cache read is guarded by the ext4 control in the same boot.

## Expected Ranges
| Workload | HAMMER2 Behavior | Baseline Reference |
|---|---|---|
| **Sequential single-file throughput** (`throughput.sh`) | Allocation order read from the image beside DragonFly's; rate below ext4 on first cold pass while the block allocator fills | ext4 control in-run |
| **Read and fsync latency** (`latency.sh`) | Reads beside ext4 and btrfs; fsync cost follows the flush path, not the VFS fast path | ext4 and btrfs in-run |
| **Mixed mapped plus fsync writers** (`storm.sh`) | Writers against readers on one file set; writepages queues the inode | Same shape on the control filesystem |
| **Cold package closure read** (`nix-closure.sh`) | Read cold beside squashfs and erofs | squashfs and erofs in-run |

## Caveats
- No single committed number ships here: rates move with the kernel of record (7.3), the guest kind (`h2debug`, `h2kasan`, `h2release`), and host load. Each record entry in `doc/history/verification-record.md` carries its build hash, start state, and repeat count beside any number it cites.
- Sequential device mapping read-ahead uses `page_cache_sync_ra` with the BSD hint; a measured jump (353 to 683 MiB/s in one dated reading) held only after the host cache was primed, so an unprimed host-cache read is not a result.
