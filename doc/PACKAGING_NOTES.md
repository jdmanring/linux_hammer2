# Packaging and Distribution Notes

Lightweight guidance for packaging `linux_hammer2` as an out-of-tree kernel module on Linux 7.3 and newer.

## 1. Module Loading Order
Load order is critical to satisfy codec and hashing symbols at `modprobe` time:

```sh
modprobe libcrc32c
modprobe xxhash
insmod hammer2.ko
```

`hammer2.ko` depends on `libcrc32c` for block checksum validation and `xxhash` for hash-tree operations.

## 2. DKMS Support
A `dkms.conf` can wrap the module build against `/lib/modules/$(uname -r)/build`. Recommended minimal DKMS stanza:

```
PACKAGE_NAME=hammer2
PACKAGE_VERSION=1.0.72
BUILT_MODULE_NAME[0]=hammer2
DEST_MODULE_LOCATION[0]=/extra
AUTOINSTALL=yes
```

## 3. udev and Rules
No custom `udev` rules are required for standard operation. Block device access via `blkid` and `/dev/disk/by-label` works for multi-volume management.

## 4. Initramfs and Root-on-HAMMER2
For root filesystem usage:
1. Include `hammer2.ko`, `libcrc32c.ko`, and `xxhash.ko` in `initramfs` via `/etc/mkinitcpio.conf` or `dracut`.
2. Specify root mount as `root=/dev/vdX rootfstype=hammer2` or via UUID.
3. Verify superblock availability before `switch_root` to avoid premature unmount panics.
