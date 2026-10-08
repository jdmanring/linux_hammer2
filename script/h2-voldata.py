#!/usr/bin/env python3
"""What a HAMMER2 volume header says about its allocator, read from media.

`statfs` reports `voldata.allocator_free`, and that field is only
recomputed by bulkfree: it does not move as blocks are handed out during
a run.  Measuring a run's consumption with `df` therefore returns the
number the last bulkfree left, and it reads 0 for any write on a volume
that has not been bulkfreed since.  A run measured that way reports
either nothing consumed or a volume "full" seconds after it was made.

This prints the fields the reserve check itself uses, so a run's cost is
a number read from the media rather than inferred:

    allocator_size  total data space the allocator covers
    allocator_free  free as the last bulkfree computed it
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
    print("h2-voldata-%s selftest: 2 cases, %d failed"
          % ("fail" if bad else "ok", bad))
    return 1 if bad else 0


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--selftest":
        sys.exit(selftest())
    sys.exit(main(sys.argv))
