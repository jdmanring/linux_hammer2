# Reproducing the Verification

How to go from a clone to the gates, and from the gates to the fleet
runs. `doc/README.testing.md` is the authority: every gate and fleet
script, what each proves, and the guest kernels' configuration.

## 1. The host

- A kernel build tree of the kernel of record, 7.3, the version
  `script/test-syntax.sh` pins as `KERNEL_REF`. The module imports
  `crc32c`, `xxh64`, LZ4 and zlib, so that tree needs `CONFIG_CRC32`,
  `CONFIG_XXHASH`, `CONFIG_LZ4_COMPRESS`, `CONFIG_LZ4_DECOMPRESS`,
  `CONFIG_ZLIB_DEFLATE` and `CONFIG_ZLIB_INFLATE`.
- `make`, `gcc`, `clang`, `git`, `bash`, `dash`, `busybox`, `vale`,
  `python3`, and for the fleet `qemu`, `libvirt` (`virsh`) and `ssh`.
- For `test-provenance.sh`, clones of the origin trees its rows name;
  without one, a row claiming a byte-for-byte carry reports
  COULD-NOT-RUN.
- [hammer2-utils](https://github.com/kusumi/hammer2-utils) built, for
  `newfs_hammer2`, `hammer2` and `fsck_hammer2`.

```sh
git clone https://github.com/jdmanring/linux_hammer2.git
cd linux_hammer2
make KDIR=/path/to/linux-7.3
```

## 2. The gates

One script per gate, each run on its own; there is no aggregate
runner. Most need only this machine and the prerequisites above:
`test-syntax.sh` needs the 7.3 tree and both compilers,
`test-checkpatch.sh` the checker its baseline names, and each reports
COULD-NOT-RUN (exit 2) without them. Two need a guest:

```sh
for g in script/test-*.sh; do bash "$g"; echo "$g exit $?"; done
```

Exit 0 passes, 1 fails, and 2 means the instrument could not run, which
is neither. `script/pre-push-check.sh` runs what a push needs without a
guest: the module build (`script/build-check.sh`), every gate but the
two fleet gates, and the selftest of every gate that has one. It
fetches `checkpatch.pl` at the baseline's kernel version when no cached
copy matches the baseline's hash.

## 3. The guests

The fleet gates (`test-fixtures.sh`, `test-enospc.sh`) and the fleet
scripts (`cluster-sync.sh`, `cluster-wire.sh` and the rest the testing
document lists) drive libvirt guests over ssh as root:

- `H2_GUEST` names the libvirt domain and `H2_GUEST_SSH` its ssh target
  (`cluster-wire.sh` takes `H2_GUEST_A`, `H2_GUEST_B` and their `_SSH`
  variables for its two guests).
- `H2_FIXTURE_START=1` lets a gate start a guest that is off;
  `H2_FIXTURE_DIR` is where images and kept reports go.
- Each script builds the module itself against `KDIR`, which must be the
  tree of the kernel the guest booted, and copies it in.
- The maintainer's Linux guests are Artix Linux with 4 GiB and 12 vCPUs
  each, booting debug (lockdep, kmemleak), KASAN and release builds of
  7.3, each also built with kernel TLS; `doc/README.testing.md` records
  each build's configuration.
- Several fleet scripts also drive a DragonFly 6.4.2 guest
  (`f4-roundtrip.sh`, `pfs-domains.sh`, `bulkfree.sh`, `cut-flush.sh`,
  `million-tree.sh`, `nix-closure.sh`, `throughput.sh`), and
  `crash-matrix.sh` runs against the FreeBSD port;
  `doc/README.roadmap.md`'s guests table lists what each milestone
  needs.

```sh
H2_FIXTURE_START=1 KDIR=/path/to/linux-7.3 bash script/test-fixtures.sh
H2_FIXTURE_START=1 KDIR=/path/to/linux-7.3 bash script/test-enospc.sh
```

A green run reads its own report, kept under `H2_FIXTURE_DIR`, since a
gate prints little on success.
