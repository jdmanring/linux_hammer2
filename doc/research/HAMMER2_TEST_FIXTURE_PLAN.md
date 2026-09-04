# HAMMER2 test fixture plan (H0 deliverable)

Part of the archaeology work package the storage proposal requires before any
Linux write path (`proposals/saxum_filesystem/04_AGENTIC_CODING_HANDOFF.md`,
H0; `03_TEST_SECURITY_RESOURCE_SPEC.md` section 9). Written 2026-08-25 by the
specification session from what is on this disk; every instrument named here
was checked to exist, and none was run that starts a guest.

## What a fixture is for

A fixture is a HAMMER2 image with known contents that a Linux implementation
is read against, written against, crashed against, or fuzzed against. The
proposal's rule is that format compatibility is proven on images made by
**DragonFly's** implementation, and a Linux port is proven by mounting and
reading those, then by writing what DragonFly can read back. A fixture made
only by the implementation under test proves self-consistency and nothing
else.

## Writers available, and what each can produce

| writer | where | produces | status |
|---|---|---|---|
| `makefs -t hammer2` | this workstation, packaged (`docs/hammer2-toolchain.md`) | an image from a directory tree, one PFS (`Label=`, `MountLabel=` both set or it fails, measured) | the only Linux-native writer; content-bearing trees of any shape |
| DragonFly `newfs_hammer2` + kernel | `dragonflybsd642` guest in the fleet (shut off) | the reference format: multi-PFS volumes, snapshots, bulk-free state, deleted-then-snapshotted trees, anything the kernel driver can do | the authority for format compatibility |
| FreeBSD port (v1.2.13, writes since v1.1.5) | `freebsd15` guest (shut off) | the same operations from a port, which is what a Linux port will resemble | second writer; differences from DragonFly output are findings |
| NetBSD, OpenBSD ports | `netbsd10-1`, `openbsd79` guests (shut off) | cross-port images for the interoperability matrix | optional; the FreeBSD port is the closest relative |
| the Linux port under test (H2 onward) | wherever it runs | write-side fixtures for DragonFly to verify | not before H2 |

## Fixture set, in the order the stages need them

1. **F1 read-only baseline** (H1): `makefs` images from trees of known shape,
   made here today: an empty tree; a flat tree of many small files (the Nix
   store's shape); a deep directory tree; large files past every block-size
   boundary the on-disk format names (read the sizes from `hammer2_disk.h`,
   never guess); files with xattrs; symlinks and hard links; names at the
   length limits. Each with a manifest (path, size, xxhash) produced from the
   source tree, so a read test compares against the tree and not against
   another HAMMER2 reader.
2. **F2 reference-format images** (H1): the same trees written by DragonFly
   in the guest, plus what only the kernel can make: two PFS roots, a
   snapshot after a modification, a tree after bulk-free, a volume with
   deleted files still referenced by a snapshot. These are the format
   interoperability set; the F1 images are compared against them file by
   file to establish what `makefs` output and kernel output share.
3. **F3 corruption set** (H1 and H3): F2 images with metadata deliberately
   damaged: a flipped bit in a blockref checksum, a truncated volume, a
   torn write in the freemap, a root checkpoint pointing past the end. What
   `fsck_hammer2` reports on each is recorded first, so the Linux port's
   detection is measured against the tool that already exists here.
4. **F4 write round-trip** (H2): the Linux port writes a known tree to an F2
   image; DragonFly mounts it and its manifest matches. Then the reverse.
   This is the test that decides whether the port writes the format or a
   dialect of it.
5. **F5 crash set** (H3): images captured mid-write under the crash matrix
   the test spec names (kill, panic, power-off, torn metadata), first from
   the FreeBSD port as the calibration (what a working port leaves behind),
   then from the Linux port.
6. **F6 Nix-scale** (H6): a `makefs` image of an actual Saxum closure tree
   (hundreds of thousands of paths), the workload class the storage program
   exists for; read performance and metadata behavior are measured on it
   before any claim about the flagship.

## Where fixtures live and how they are identified

Images are not committed to git. Each fixture is identified by the writer,
its version, the command line, and the source tree's manifest hash, recorded
in a fixture index next to the tests (`tests/storage/hammer2/fixtures.csv`
when the suite exists), and cached by content hash. A fixture without its
writer and command line recorded is not a fixture.

## What this plan does not decide

Whether the guests are booted for F2 is James's, since the fleet is kept
down to leave the implementation memory; F1 needs no guest and is the first
thing H1 tests against. The first F2 image needs no boot either, measured
below. Fuzzing corpora (the test spec requires format fuzzing
before any writable root) start from F3 and are the H3 stage's work.

## F2 without a boot: the DragonFly guest's disk read cold

Measured 2026-08-25 by the specification session, with the fleet down.
The guest `dragonflybsd642` (installed DragonFly 6.4.2) has its disk at
`/mnt/storage/VM_images/dragonflybsd642.qcow2`, 30 GiB virtual, 927 MiB
allocated, and that disk is a kernel-written HAMMER2 volume: GPT behind a
protective MBR, entry 0 the EFI system partition at LBA 2048, entry 1 a
DragonFly Label64 slice (`3d48ce54-1d16-11dc-8696-01301bb8a9f5`) at LBA
264192; the disklabel64 magic at slice offset 512; partition `a` (fstype 7,
0.5 GiB) and partition `e` (fstype 23) at byte 0x28200000 of the disk,
29.37 GiB, with the HAMMER2 volume-header magic at its first eight bytes.

The packaged tools read it, and none of them takes a partition offset, so
the partition is cut out first:

    qemu-img convert -f qcow2 -O raw dragonflybsd642.qcow2 dfly.raw   # 2 s, 869 MiB actual
    # copy from byte 0x28200000 with SEEK_DATA/SEEK_HOLE so holes stay holes: 692 MiB actual
    fsck_hammer2 dfly-e.raw            # 83,007 blockrefs, 28,171 inodes, 0.5 s, no error line
    hammer2-fuse dfly-e.raw@ROOT mnt   # the installed root; /etc lists 95 entries

`qemu-nbd -r --socket=<short path>` plus `nbdfuse` also exposes the disk
read-only to userspace without root, which is how the header was found;
the socket path must be under 108 bytes. Two readings of the same probe
were NO ANSWER and read as negatives before that: `qemu-img dd` cannot
`skip` on this qcow2, and with `of=/dev/stdout` it fails at output
creation and prints nothing on the stream, so a scan of every allocated
extent "found no header" while reading nothing.

Two things the probe gave beyond the image. The installed root PFS is
`ROOT`, and the default label `hammer2-fuse` tries is `DATA`; on that
miss libhammer2 0.5.0 (`e0b88b9`) returns the error and then panics in
`unmount` (`src/hammer2.rs:1206`, an assertion that the PFS root inode is
mapped, which it never was), a defect staged for upstream in
`HAMMER2_UPSTREAM_STRATEGY.md`. And the walk is the first measurement of
a DragonFly-kernel-written tree by the tools this system packages, so F1
against F2 file-by-file (the format-drift instrument in the port plan)
can start on this image.

What this does not give, and still needs a booted DragonFly: a snapshot
after a modification, a tree after bulk-free, a volume with deleted files
held by a snapshot, and F4's round trip. PFS enumeration through the
tools is unverified here, because `hammer2 pfs-list` is an ioctl against
a kernel mount and the FUSE mount does not carry it; the label lookup
proves `ROOT` present and `DATA` absent and nothing more.

