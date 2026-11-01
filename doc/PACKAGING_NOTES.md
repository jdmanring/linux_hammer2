# Packaging Notes

What a packager needs to know about the module. Nothing here is packaged
by this repository; `make install` and `make uninstall` (README.md,
"Install") are the supported installation.

## Kernel

The module builds against the kernel of record, 7.3, and refuses an
older one at compile time (`hammer2_os.h`). It imports `crc32c`, `xxh64`,
SHA-256, LZ4 and zlib from the kernel's libraries (`nm -u hammer2.ko`),
so the kernel needs `CONFIG_CRC32`, `CONFIG_XXHASH`,
`CONFIG_CRYPTO_LIB_SHA256`, `CONFIG_LZ4_COMPRESS`,
`CONFIG_LZ4_DECOMPRESS`, `CONFIG_ZLIB_DEFLATE` and `CONFIG_ZLIB_INFLATE`.
It also needs `CONFIG_TRANSPARENT_HUGEPAGE`, without which the block
layer caps the block size below the format's 64 KiB and the build
stops at an assertion (`hammer2_io.c`). The kernels this port is tested
on build all eight in; on a kernel that builds the libraries as modules,
`modprobe hammer2` loads them first, and `insmod` does not.

## Userland

Formatting, PFS management, snapshots and checking come from
[hammer2-utils](https://github.com/kusumi/hammer2-utils):
`newfs_hammer2`, `hammer2` and `fsck_hammer2`. No `mount.hammer2` helper
is needed: the source is `<device>@LABEL`, or `<dev1>:<dev2>@LABEL` for
a filesystem across volumes, and the module's own options are `emerg`
and `cluster_fd=`.

## Root on HAMMER2

`script/root-boot.sh` boots a kernel whose root filesystem is a HAMMER2
volume: an initramfs holding the module and an init that reads `root=`
from the kernel command line (`root=/dev/vda@LABEL rootfstype=hammer2`),
mounts the volume, moves the mount over `/` and executes `/sbin/init`
from it. Its control boots against a label not on the volume and must
fail at the mount. No distribution initramfs generator (mkinitcpio,
dracut) has been configured or read here.

## Not provided

No DKMS configuration, udev rules or distribution package is shipped or
tested.
