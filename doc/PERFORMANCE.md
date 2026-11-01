# Performance

Dated readings, each with the record entry or changelog row that holds
its run, its kernel and its caveats. A rate here is one run's reading on the
maintainer's guests, not a benchmark; it moves with the kernel build,
the guest and the host's load, and every figure below says which.

| what | reading | kernel | where it is recorded |
|---|---|---|---|
| one large file, sequential | writes at twice the rate of ext4 and btrfs, reads at six times the rate of DragonFly's own kernel on the same volume, every block verified | `7.3.0-rc1-release`, 2026-09-07; the read figure re-read with the readahead workers of 0.9.19 | `doc/README.status.md`, "one large file"; the record, "One large file, and what the BSD buffer cache gave for free" |
| per-operation latency | median `randread4k` 49 us against ext4's 11; median write-and-`fsync` 384 us against ext4's 7119 and btrfs's 7824 | 7.3.0-rc1, 2026-09-26 | the record, "Per-operation latency, the half that was never measured", which reads the read cost as a 64 KiB block against a 4 KiB page and the fsync figure against what `fsync` writes |
| a million files | written by four writers in 248 s and counted on both sides | debug build, kmemleak off, September 2026 | the record, "A million files, and where the writer stopped" |
| mixed mapped, fsync and fdatasync writers against readers | 800 cycles, 0 failures, 2 h 39 min on the debug build and 6 h 14 min on the KASAN build | `h2debug-rc5`, `h2kasan-rc5` | the record, "The 800-cycle soak" and "The 800-cycle KASAN soak" |
| a snapshot pass for one changed file, 1,000,000 files | 32.7 to 33.0 s carried (1.0.60); 12.7 s with lever 1 (1.0.71); 11.3 s on the TLS-capable build (1.0.72) | release build of 7.3, then `h2release-7.3tls` | `CHANGELOG.md` rows 1.0.60, 1.0.71, 1.0.72 |
| the same at 100,000 files | 2.5 to 3.8 s carried; 0.90 to 0.95 s with lever 1; 0.82 to 0.83 s on the TLS-capable build | as above | as above |

The snapshot pass is P7's synchronization, read against the thread's
5.12 s cadence; why it matters and what comes next is P8's plan in
`doc/README.roadmap.md`.
