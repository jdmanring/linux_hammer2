# Upstream Engagement Plan

Concrete steps and protocols for engaging upstream maintainers (Matthew Dillon for DragonFly BSD HAMMER2, Tomohiro Kusumi for FreeBSD/NetBSD/OpenBSD ports and userland `hammer2-utils`).

## 1. Principles of Engagement
- **Respect the Core Symmetery**: Every patch submitted upstream or shared with Kusumi's ports must preserve the invariant that `src/sys/fs/hammer2/` remains readable as DragonFly's core. Linux-specific adaptations live strictly in `hammer2_os.h`, `hammer2_compat.h`, or the shim layer.
- **Provenance First**: Every file under `doc/upstream/` must carry a provenance record stating whether upstream has already fixed the sibling defect, rejected a similar approach, or been notified.

## 2. Action Plan for Upstream Handover
1. **Sync Verification**: Ensure all local bug fixes in `src/sys/fs/hammer2/` have been verified against the FreeBSD port (`freebsd_hammer2`) where applicable.
2. **Staging & Review**: Stage proposed core patches in `doc/upstream/` with full provenance notes and test outputs from the local verification gates and guest fleet runs.
3. **Contact Points**:
   - **Matthew Dillon**: Core filesystem design, on-disk format extensions, quorum/clustering architecture.
   - **Tomohiro Kusumi**: Porting symmetry, FreeBSD/NetBSD sync, `hammer2-utils` and `hammer2-fuse` coordination.
4. **Milestone Execution**: Complete P7 (kernel TLS clustering) and P8 (lease protocol / multi-master quorum) verification before initiating direct merge discussions for mainline Linux submission.
