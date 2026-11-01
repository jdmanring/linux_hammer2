# Root Filesystem Readiness

What a HAMMER2 root needs from the VFS half, and where each stands.
P2 of the roadmap ("root filesystem and long-run readiness") holds the
readings; `doc/history/verification-record.md` holds the runs.

| need | state | reading |
|---|---|---|
| boot with a HAMMER2 root | read | `script/root-boot.sh`: an initramfs mounts `root=/dev/vda@LABEL rootfstype=hammer2`, moves it over `/` and runs `/sbin/init` from it; a label not on the volume fails at the mount |
| exec from the volume, shared writable mappings | read | the same script: a static binary executed from the volume, and a 128 KiB file written through a shared mapping compared on media after a fresh mount |
| `fallocate`, including punch | read | fixed at 0.9.36; `test/hammer2-fallocate.c`, run by `test-enospc.sh` since 0.9.37, read 12 checks and 0 failures then on the debug kernel of record, with its btrfs control the same, and 18 checks and 0 failures on `h2debug-rc5` after the xfstests fixes (the record, "fallocate failed on an empty file and destroyed data on a full one") |
| `O_DIRECT` | not served, by decision | DragonFly's HAMMER2 has no direct path either (`doc/README.roadmap.md`, "Not on the roadmap") |
| mixed load: mapped, fsync and fdatasync writers against readers | read | `script/storm.sh`, 800 cycles with 0 failures on the debug build (2 h 39 min) and the KASAN build (6 h 14 min) of a 7.3 release candidate; not repeated on the 7.3 release |
| low memory | read | a Nix closure copied in and read back at 2, 4 and 8 GiB of guest memory (`doc/README.roadmap.md`, the 0.9 row); at 2 GiB, with both page-cache fallbacks in, nothing was refused and nothing lost |
| filesystem freeze | read | `->freeze_fs` and `->unfreeze_fs` built at 0.9.38; `test/hammer2-fiemap.c` freezes and thaws a mount in `test-enospc.sh` since 0.9.39 |
| system suspend and resume | not read | |
| swap files | not supported | the port has no `->swap_activate` |
| export through `nfsd` | read | `script/nfsd-export.sh`, under both subtree modes |
