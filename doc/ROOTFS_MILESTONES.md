# Root-Filesystem Readiness Milestones (P0)

Explicit exit criteria for closing the remaining root-filesystem (VFS) gaps in `linux_hammer2` before single-node root deployment is recommended.

| Milestone | Subsystem | Exit Criteria & Verification Method | Status |
|---|---|---|---|
| **RFS-1: Fallocate / Punch Hole** | VFS / `->fallocate` | Fully exercise `fallocate(2)` zero/punch modes under `test/hammer2-fiemap.c` and xfstests generic suite; verify block reclamation via `bulkfree.sh`. | Experimental / Staged |
| **RFS-2: O_DIRECT Support** | VFS / Direct I/O | Implement or safely support `O_DIRECT` bypass for buffered folio cache without violating CoW allocation assumptions; verify via direct-io exercisers. | Refused / Deferred |
| **RFS-3: Sustained Mixed Soak** | VFS / Concurrency | Execute multi-hour mixed mmap, buffered write, and `fsync` storm exercisers (`storm.sh`) under KASAN with zero memory leaks or lockdep reports. | Active (Passing 800 cycles) |
| **RFS-4: Small-Memory Footprint** | Memory Management | Verify correct operation and reclaim behavior under memory pressure on guest VMs configured with <= 2 GiB RAM. | Unverified (4+ GiB tested) |
| **RFS-5: Swap and Suspend** | Power / Swapping | Validate swap-over-HAMMER2 and system suspend/resume integrity without deadlock under `freeze_fs`. | Not Started |
