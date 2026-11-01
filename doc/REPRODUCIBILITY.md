# Reproducibility Guide: Stock Linux to Green Verification Suite

How to take a stock Linux machine (Kernel 7.3 or newer, QEMU/KVM, root access) and run the complete `linux_hammer2` verification suite from zero to green.

## 1. Prerequisites and Build Environment
- **Operating System**: Linux kernel 7.3.0 or newer (or kernel of record source tree configured via `KDIR`).
- **Dependencies**: `make`, `gcc`, `clang`, `git`, `bash`, `coreutils`, `qemu-system-x86_64`, `libvirt` (`virsh`), `bc`, `jq`.
- **Kernel of Record Source**: The kernel of record (7.3) is obtained from upstream Linux (`git://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git` at tag `v7.3` or equivalent pinned in `script/test-syntax.sh` as `KERNEL_REF`). Configure with standard x86_64 defconfig plus `CONFIG_TRANSPARENT_HUGEPAGE=y`, `CONFIG_LZ4_COMPRESS=y`, `CONFIG_LZ4_DECOMPRESS=y`, `CONFIG_ZLIB_DEFLATE=y`, `CONFIG_ZLIB_INFLATE=y`, and `CONFIG_XXHASH=y`.

Pinned kernel `.config` fragment (append to `arch/x86/configs/x86_64_defconfig` before `make olddefconfig`):
```
CONFIG_TRANSPARENT_HUGEPAGE=y
CONFIG_TRANSPARENT_HUGEPAGE_ALWAYS=y
CONFIG_LZ4_COMPRESS=y
CONFIG_LZ4_DECOMPRESS=y
CONFIG_ZLIB_DEFLATE=y
CONFIG_ZLIB_INFLATE=y
CONFIG_XXHASH=y
```

- **Source Clone**:
  ```bash
  git clone https://github.com/jdmanring/linux_hammer2.git
  cd linux_hammer2
  ```

## 2. Building the Module
Build against the running kernel headers:
```bash
make
```
Or against an explicit kernel build tree:
```bash
make KDIR=/path/to/linux-7.3/build
```

## 3. Running the Fast Gate Suite (Local Machine)
The eighteen automated gates in `script/` test provenance, inventory, citations, syntax, checkpatch baseline, and shim behavior:
```bash
H2_FIXTURE_START=1 KDIR=/path/to/linux-7.3/build bash script/pre-push-check.sh
```
A clean run verifies module compilation, checkpatch compliance, shim stubs, and inventory consistency, ending with: `pre-push: gates and selftests pass, 0 could not run`.

## 4. Setting up QEMU/KVM Guest Fleet for Fleet Gates
Fleet gates (`cluster-sync.sh`, `cluster-wire.sh`, `test-enospc.sh`, `test-fixtures.sh`) require QEMU/KVM guest virtual machines:

Minimal `guest.xml` example (one guest, 4 GiB RAM, 12 vCPUs, virtio disk):
```xml
<domain type='kvm'>
  <name>hammer2-guest-a</name>
  <memory unit='GiB'>4</memory>
  <vcpu>12</vcpu>
  <os><type arch='x86_64'>hvm</type><boot dev='hd'/></os>
  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='/var/lib/libvirt/images/hammer2-guest-a.qcow2'/>
      <target dev='vda' bus='virtio'/>
    </disk>
    <interface type='network'><source network='default'/></interface>
  </devices>
</domain>
```

Provision and run:
1. Define and start two guest domains (e.g., `hammer2-guest-a` and `hammer2-guest-b`) via `virsh`:
   ```bash
   virsh define guest-a.xml
   virsh start hammer2-guest-a
   ```
2. Ensure passwordless SSH (`root@<guest-ip>` or configured `H2_GUEST_SSH`) is active for automated provisioning during test runs.
3. Execute fleet exercisers:
   ```bash
   H2_FIXTURE_START=1 bash script/cluster-sync.sh
   H2_FIXTURE_START=1 bash script/cluster-wire.sh
   ```
4. Shut down guests cleanly:
   ```bash
   virsh shutdown hammer2-guest-a
   ```


