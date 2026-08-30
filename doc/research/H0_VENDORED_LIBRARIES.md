# The vendored LZ4, xxHash and zlib copies: measured, and all three drop

One of the three items `HAMMER2_LINUX_PORT_PLAN.md` leaves open inside H0.
Measured 2026-08-25 from the trees on this disk and from the kernel's own
headers at `v7.2`, so the question is answered rather than deferred into
H1's import.

The question: does the Linux module carry HAMMER2's vendored copies of
these three, or call Linux's own? It matters more than a build-time
convenience, because two of the three touch the ON-DISK FORMAT. The check
algorithm writes a value every other HAMMER2 implementation will verify,
and the decompressor reads bytes a DragonFly kernel wrote.

## xxHash: stock, and proved by test vector

HAMMER2 calls it in exactly three places, all the same shape:

    XXH64(bdata, chain->bytes, XXH_HAMMER2_SEED)

Linux's `include/linux/xxhash.h` declares
`uint64_t xxh64(const void *input, size_t length, uint64_t seed)`, which
is the same function with the same argument order.

Same NAME is not same VALUE, and a checksum is precisely where that
distinction is expensive: a modified xxHash would produce a digest this
implementation agrees with and no other does, and every volume it wrote
would fail its own check on any other HAMMER2. So the vendored copy was
compiled in userspace and run against the reference vector published with
Cyan4973's xxHash:

    XXH64("", 0, seed=0) = ef46db3751d8e999   (reference: ef46db3751d8e999)

It matches. HAMMER2's copy is stock xxHash64, Linux's is stock xxHash64,
and a `#define XXH64 xxh64` in the shim is the whole of the mapping. The
`xxhash/` directory does not enter the Linux tree.

The test is worth keeping rather than reporting: it is the only thing
standing between a silently divergent checksum and a volume nobody else
can read, and it costs one compile.

## LZ4: the decompressor is stock, the compressor is HAMMER2's own

`hammer2_lz4.c` is NOT unmodified LZ4. It carries a `MALLOC_DEFINE` and a
pair of HAMMER2 additions, `LZ4_createHeapMemory` and
`LZ4_compress_heap_limitedOutput`, which exist because the stock
compressor wants a hash table on the stack that a kernel cannot spare.
Those are on the COMPRESSION side.

The decompression side is stock and the call site proves the framing is
HAMMER2's rather than LZ4's:

    compressed_size = *(const int *)data;
    result = LZ4_decompress_safe(&data[sizeof(int)], buf,
                                 compressed_size, bp->b_bufsize);

A four-byte length written by HAMMER2, then a stock LZ4 block. Linux's
`LZ4_decompress_safe(const char *source, char *dest, int compressedSize,
int maxDecompressedSize)` has the identical signature but for a `const`
on the source, which is a widening.

So for H1, which reads and does not write, the whole of `hammer2_lz4.c`
and `hammer2_lz4_encoder.h` drops and Linux's decompressor is a drop-in.
H2 needs a compressor and does not get one from the vendored file either:
`LZ4_compress_heap_limitedOutput` has no Linux counterpart, and the
replacement is `LZ4_compress_destSize` with a caller-provided workspace.
That is call-site work rather than carried code, and it is H2's.

## zlib: the same functions behind a prefix

HAMMER2 calls `inflateInit`, `inflate`, `inflateEnd` and the three
`deflate` counterparts. Linux's `include/linux/zlib.h` exports
`zlib_inflateInit`, `zlib_inflate`, `zlib_inflateEnd`, `zlib_deflate` and
the rest: the same library under a prefix, so the mapping is a set of
defines.

One difference is not cosmetic and belongs in the shim's comment when the
code is written. Linux's `zlib_inflateInit` takes a workspace the caller
allocates, sized by `zlib_inflate_workspacesize()`, where the userspace
API allocates internally. That is a call-site change at each of the three
init sites, not a rename.

zlib's inflate output is defined by the format rather than by the
implementation, so unlike xxHash there is no digest to diverge, and
unlike LZ4 there is no HAMMER2-private entry point.

## What this removes from H1

Three files and a directory that the port would otherwise have carried,
reviewed for provenance, and kept in step with two upstreams:
`hammer2_lz4.c`, `hammer2_lz4_encoder.h`, `hammer2_lz4.h` and
`xxhash/`. In the license audit's terms it also removes the two anomalies
it flagged there, the zlib tables with no header and the vendored copies
whose license headers disagree with the toolchain's `meta.license`: a
file that does not enter the tree needs no provenance row.

The rung this takes is the pre-code ladder's fourth, the system's own
native mechanism, and it was reachable only by reading what the kernel
exports rather than by assuming a filesystem carries its own compression.

## The libkern helper, and a name that points at the wrong polynomial

The port plan's third open H0 item is "the `sys/libkern` helpers from a
full DragonFly clone". Measured: there is one, `icrc32.c`, and it needs no
clone. HAMMER2 reaches it through two defines in `hammer2.h:1297`:

    #define hammer2_icrc32(buf, size)  iscsi_crc32((buf), (size))

used for the freemap check and the volume header, so it is on-disk-format
critical in the same way xxHash is.

The name is a trap and the file supports the trap. `iscsi_crc32` suggests
the iSCSI CRC, which is Castagnoli CRC-32C; but the file opens with a
comment block describing polynomial `$edb88320`, which is ordinary
CRC-32, and defines a `crc32_tab[]` from it. A reader who checks the
comment concludes CRC-32 and maps the call to Linux's `crc32_le()`.

That table is a decoy. `iscsi_crc32` calls `calculate_crc32c`, and the
vector settles it:

    iscsi_crc32("123456789") = e3069283

which is the CRC-32C reference. Ordinary CRC-32 of the same input is
`cbf43926`. So the mapping is Linux's `crc32c()` from
`include/linux/crc32c.h`, and taking the comment at its word would have
checksummed every freemap block and every volume header with the wrong
polynomial, on a path where the only symptom is that no other HAMMER2
accepts the volume.

Both vectors are in `scripts/test-hammer2-checkalg.sh`, which fails
specifically if `iscsi_crc32` stops being CRC-32C rather than merely
matching something.

With this, all three of H0's open items are closed or dissolved: the
vendored libraries above, this helper, and the provenance CSV, which
shrinks because none of these files enters the tree.

## The BSD macro headers, found by writing hammer2.h rather than by any audit

Added 2026-08-25, after the section above declared H0 closed.

The carried core is written against two headers every BSD ships and
Linux does not: `sys/tree.h` (Niels Provos's red-black tree macros,
`RB_*`) and `sys/queue.h` (Berkeley's `TAILQ_*`, `LIST_*`). Measured
over the DragonFly core that H1 carries: 12 `RB_` sites in
`hammer2_chain.c`, 2 in `hammer2_flush.c`; `TAILQ_` in bulkfree (12),
inode (12), admin (8), flush (1); and `hammer2_chain.c` also uses
`RB_SCAN`, which DragonFly's `tree.h` has natively and FreeBSD's does
not, so FreeBSD's port carries it as `hammer2_rb.h` (140 lines). None of
the five documents in this directory named either header, and the
portability audit's OS-specific classification could not have: the
headers are not files in any HAMMER2 tree, so no file-level measurement
sees them. They surfaced when `hammer2.h` was written and its include
list was read line by line.

Linux's `rbtree.h` is a different interface (explicit rebalancing
calls, no generated typed functions), so mapping to it would turn every
`carry` file that touches a tree into a `rewrite` for no gain. The port
vendors instead, the way the three BSD ports get them from their own
`sys/`:

- `sys/sys/tree.h` and `sys/sys/queue.h` from freebsd-src at
  `release/15.1.0` (commit `96841ea`), sparse-cloned at
  `~/Projects/freebsd-src-upstream` so the provenance CSV can name a
  commit. Tree `freebsd-src` in `scripts/hammer2-provenance.py`, rows
  `vendored`/`carry`; only the two listed files get rows, and the
  selftest's negative control is an unlisted file producing none.
- `hammer2_rb.h` from FreeBSD's port at `3df307f`, the one port-only
  file the Linux port carries (`CARRY_PORT_ONLY` in the script; the
  NetBSD and OpenBSD copies stay `reference`).
- A `sys/cdefs.h` of our own, because both vendored files open with
  `#include <sys/cdefs.h>`, supplying the three cdefs names they use.

Licenses: tree.h BSD-2-Clause (Provos), queue.h BSD-3-Clause (Regents),
both read from the text and both agreeing with their SPDX tags; the
generator's holder parser had to learn the Berkeley form, where the
holder is on the line after the years.

One edit to the vendored text, and the reason is worth the paragraph.
Both files spell the unused-parameter attribute `__unused`, a BSD cdefs
macro. Defining it as a macro for the kernel build looked like the
obvious shim, and it is wrong: `__unused` is a FIELD NAME in the uapi
`struct stat`, `struct icmphdr` and `struct __sysctl_args`. An array
field so declared is a compile error; a scalar one vanishes with a
warning, which changes the struct's layout silently, and
`CONFIG_WERROR` is not set on this kernel. The first version of the gate
carried an include-order rule and a control pair for it, and the pair
was vacuous twice (efi.h failed on its wide strings, sysctl.h was
already inside the include chain) before a three-line probe measured
the actual behavior. So the macro is gone: the eight `__unused` sites
in `tree.h` (5) and `hammer2_rb.h` (3) are spelled `__always_unused`,
the kernel's own, each file's PORT NOTE counts them, and `cdefs.h`
defines nothing the 7.2 include tree uses anywhere (grepped: zero
hits for `__predict_false`, `__containerof`, `__uintptr_t`).
