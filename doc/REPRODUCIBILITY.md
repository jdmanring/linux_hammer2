# Reproducibility Guide: Stock Linux to Green Verification Suite

How to take a stock Linux machine (Kernel 7.3 or newer, QEMU/KVM, root access) and run the complete `linux_hammer2` verification suite from scratch.

## 1. Prerequisites and Build Environment
- **Operating System**: Linux kernel 7.3.0 or newer (or kernel of record source tree configured via `KDIR`).
- **Dependencies**: `make`, `gcc`, `clang`, `git`, `bash`, `coreutils`, `qemu-system-x86_64`, `virsh`.
- **Source Clone**:
  ```bash
  git clone https://github.com/jdmanring/linux_hammer2.git
  cd linux_hammer2
  ```

## 2. Building the Module
Build against the running kernel or a targeted kernel tree:
```bash
make
# Or with explicit kernel source path:
make KDIR=/path/to/linux/build
```

## 3. Running the Fast Gate Suite (Local Machine)
The eighteen automated gates in `script/` test provenance, inventory, citations, syntax, checkpatch baseline, and shim behavior:
```bash
H2_FIXTURE_START=1 KDIR=~/kernels/linux-7.3 bash script/pre-push-check.sh
```
A clean run prints: `pre-push: gates and selftests pass, 0 could not run`.

## 4. Running Fleet and Guest Verification
For guests running in QEMU/KVM (e.g., `artix-s6-kde`):
1. Start the guest fixture:
   ```bash
   H2_FIXTURE_START=1 virsh start artix-s6-kde
   ```
2. Execute the cluster sync or wire harness:
   ```bash
   bash script/cluster-sync.sh
   bash script/cluster-wire.sh
   ```
3. Shut down guests cleanly when finished:
   ```bash
   virsh shutdown artix-s6-kde
   ```
