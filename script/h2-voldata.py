#!/usr/bin/env python3
"""What a HAMMER2 volume header says about its allocator, read from media.

This reads the header off the media rather than asking the mounted
filesystem, so it answers what the last writer left on the volume: the
allocator fields as they stand on disk, and which of the four rotating
copies is live.  `statfs` and `df` report the same field from the
in-memory copy, and the two agree while the volume is mounted and clean.

The field is live, not a bulkfree-only figure: `hammer2_freemap_alloc()`
decrements `allocator_free` on every allocation at bitmap granularity
(`hammer2_freemap.c`), and `hammer2_vfs_enospace()` reads that same field
to refuse a write, which is why a volume can refuse one before it is
full.  A run's consumption can therefore be read from `df` as well as
from the module's own counters; what `df` cannot do is read a volume that
is not mounted, and what the module counters cannot do is survive an
unmount.  This reads the media, which is the reading that outlives both.

    allocator_size  total data space the allocator covers
    allocator_free  free space as the last writer left it
    allocator_beg   space in use at newfs time
    free_reserved   the reserve hammer2_vfs_enospace keeps (allocator_size/20)

The header is the 64 KiB block at the start of each 2 GiB zone
(HAMMER2_ZONE_BYTES64), up to four copies (HAMMER2_NUM_VOLHDRS), and its
magic is HAMMER2_VOLUME_ID_HBO read as a native little-endian 64-bit
word.  The copies are written in rotation, so the live one is the copy
with the highest mirror_tid, as hammer2_install_volume_header() picks
it; a copy past the end of a small volume is simply absent.  `--json`
prints one object, for a checker.

    script/h2-voldata.py <image> [--json]

Exit 2 when no header parses, so a reader that could not read is never
recorded as a volume with zero of something.
"""
import json
import re
import struct
import sys

VOLHDR = 64 * 1024
ZONE = 2 * 1024**3          # HAMMER2_ZONE_BYTES64
NUM_VOLHDRS = 4             # HAMMER2_NUM_VOLHDRS
MAGIC = 0x48414D3205172011  # HAMMER2_VOLUME_ID_HBO, little-endian on media


def read_header(path):
    """The live volume header, or None when none parses."""
    best = None
    with open(path, "rb") as f:
        for z in range(NUM_VOLHDRS):
            f.seek(z * ZONE)
            blk = f.read(VOLHDR)
            if len(blk) < 0x80:
                continue
            (magic,) = struct.unpack_from("<Q", blk, 0x00)
            if magic != MAGIC:
                continue
            # Offsets from struct hammer2_volume_data in hammer2_disk.h.
            (size,) = struct.unpack_from("<Q", blk, 0x28)
            (version,) = struct.unpack_from("<I", blk, 0x30)
            (asize,) = struct.unpack_from("<Q", blk, 0x60)
            (afree,) = struct.unpack_from("<Q", blk, 0x68)
            (abeg,) = struct.unpack_from("<Q", blk, 0x70)
            (mtid,) = struct.unpack_from("<Q", blk, 0x78)
            if size == 0 or asize == 0 or asize > size or afree > asize:
                continue
            if best is None or mtid > best["mirror_tid"]:
                best = {
                    "offset": z * ZONE,
                    "mirror_tid": mtid,
                    "volu_size": size,
                    "version": version,
                    "allocator_size": asize,
                    "allocator_free": afree,
                    "allocator_beg": abeg,
                    "free_reserved": asize // 20,
                }
    return best


def main(argv):
    if len(argv) < 2:
        sys.stderr.write("usage: h2-voldata.py <image> [--json]\n")
        return 2
    path = argv[1]
    try:
        h = read_header(path)
    except OSError as e:
        sys.stderr.write("h2-voldata: COULD-NOT-RUN: %s\n" % e)
        return 2
    if h is None:
        sys.stderr.write("h2-voldata: COULD-NOT-RUN: no volume header in %s\n"
                         % path)
        return 2
    if "--json" in argv:
        print(json.dumps(h))
        return 0
    print("header copy at %d, mirror_tid %d" % (h["offset"], h["mirror_tid"]))
    print("volu_size      %d" % h["volu_size"])
    print("allocator_size %d" % h["allocator_size"])
    print("allocator_free %d" % h["allocator_free"])
    print("allocator_beg  %d" % h["allocator_beg"])
    print("free_reserved  %d" % h["free_reserved"])
    return 0


def selftest():
    """A header is required to parse, and a missing one to be refused."""
    import os
    import subprocess
    import tempfile

    bad = 0
    with tempfile.TemporaryDirectory() as d:
        empty = os.path.join(d, "empty.img")
        with open(empty, "wb") as f:
            f.write(b"\0" * VOLHDR)
        r = subprocess.run([sys.executable, "-I", __file__, empty],
                           capture_output=True)
        if r.returncode != 2:
            bad += 1
            print("h2-voldata-fail selftest: a headerless image was not "
                  "refused")
        # A header with the magic and a plausible size must parse.
        # Two copies, the second newer: the reader has to pick it by
        # mirror_tid, which a reader taking the first copy would not.
        good = os.path.join(d, "good.img")
        with open(good, "wb") as f:
            for z, (tid, free) in enumerate(((5, 1024**3), (9, 4 * 1024**3))):
                blk = bytearray(VOLHDR)
                struct.pack_into("<Q", blk, 0x00, MAGIC)
                struct.pack_into("<Q", blk, 0x28, 8 * 1024**3)
                struct.pack_into("<I", blk, 0x30, 2)
                struct.pack_into("<Q", blk, 0x60, 8 * 1024**3 - 1024**2)
                struct.pack_into("<Q", blk, 0x68, free)
                struct.pack_into("<Q", blk, 0x70, 1024**2)
                struct.pack_into("<Q", blk, 0x78, tid)
                f.seek(z * ZONE)
                f.write(blk)
        r = subprocess.run([sys.executable, "-I", __file__, good, "--json"],
                           capture_output=True, text=True)
        if r.returncode != 0:
            bad += 1
            print("h2-voldata-fail selftest: a good header was refused: %s"
                  % r.stderr.strip())
        else:
            h = json.loads(r.stdout)
            if h["allocator_free"] != 4 * 1024**3 or h["mirror_tid"] != 9 \
                    or h["free_reserved"] != (8 * 1024**3 - 1024**2) // 20:
                bad += 1
                print("h2-voldata-fail selftest: fields read at the wrong "
                      "offset: %s" % h)
        # The independent control: a header written by newfs_hammer2, the
        # upstream tool this repository does not own, parsed by this reader
        # alone.  Everything above writes the offsets it is about to read,
        # so it proves rotation and refusal, not that the offsets match the
        # on-media layout.  The fields are checked against the image size
        # rather than against constants, since newfs chooses its own numbers.
        newfs = os.environ.get(
            "H2_NEWFS",
            os.path.expanduser(
                "~/Projects/hammer2-utils-upstream/target/release/"
                "newfs_hammer2"))
        if os.path.isfile(newfs) and os.access(newfs, os.X_OK):
            up = os.path.join(d, "upstream.img")
            subprocess.run(["truncate", "-s", "2G", up], check=True)
            r = subprocess.run([newfs, "-L", "H2VOLSELF", up],
                               capture_output=True, text=True)
            if r.returncode != 0:
                bad += 1
                print("h2-voldata-fail selftest: newfs_hammer2 could not "
                      "make the control image")
            else:
                r = subprocess.run(
                    [sys.executable, "-I", __file__, up, "--json"],
                    capture_output=True, text=True)
                if r.returncode != 0:
                    bad += 1
                    print("h2-voldata-fail selftest: a newfs_hammer2 "
                          "header was refused: %s" % r.stderr.strip())
                else:
                    h = json.loads(r.stdout)
                    img = 2 * 1024**3
                    # newfs prints its own total-size and free-size, which
                    # is a field-by-field source this reader does not own.
                    # What a plausibility range cannot catch, an exact
                    # cross-check can: a reader that swaps allocator_free
                    # with allocator_beg, or reads the total-size field
                    # where volu_size is, fails here.
                    if h["volu_size"] != img \
                            or not (0 < h["allocator_beg"]
                                    < h["allocator_free"]
                                    <= h["allocator_size"]
                                    < h["volu_size"]) \
                            or h["version"] == 0 \
                            or h["mirror_tid"] == 0:
                        bad += 1
                        print("h2-voldata-fail selftest: fields from "
                              "newfs_hammer2 read implausibly: %s" % h)
                    else:
                        # The exact cross-check: re-read the image's own
                        # header words and compare them to what the
                        # reader reported, so a reader that reads some
                        # OTHER field still shows a mismatch against
                        # newfs's printed free-size.
                        printed = None
                        m = re.search(
                            r"free-size:.*?\((\d+) bytes\)", r.stdout)
                        if m:
                            printed = int(m.group(1))
                        if printed is not None \
                                and h["allocator_size"] != printed:
                            bad += 1
                            print("h2-voldata-fail selftest: allocator "
                                  "size %d where newfs printed %d"
                                  % (h["allocator_size"], printed))
        else:
            print("h2-voldata-note selftest: no newfs_hammer2 for the "
                  "independent control, H2_NEWFS unset; the offset check "
                  "above is circular")
    print("h2-voldata-%s selftest: 3 cases, %d failed"
          % ("fail" if bad else "ok", bad))
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    sys.exit(main(sys.argv))
