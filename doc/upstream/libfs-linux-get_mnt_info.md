# libfs: `get_mnt_info()` returns nothing on Linux

Draft for a report against Tomohiro Kusumi's `libfs`, the crate
hammer2-utils uses for its operating-system calls. Not filed.

## What happens

`hammer2 pfs-delete LABEL` with no `-s` selector fails on Linux with
`LABEL not found` for a PFS that exists, while `hammer2 -s /mount
pfs-delete LABEL` deletes it. The command finds the mount to issue the
ioctl at by asking `libhammer2::subs::get_hammer2_mounts()`, which filters
`libfs::os::get_mnt_info()` on the filesystem type. On Linux that function
is a stub:

    // src/os/linux.rs
    pub fn get_mnt_info() -> Result<Vec<(String, String, String)>, std::string::FromUtf8Error> {
        Ok(vec![])
    }

so the mount list is always empty, the lookup never runs, and every
command that routes by mount reports the PFS as missing. The FreeBSD
implementation beside it calls `getmntinfo(3)` and returns every mount.

Measured 2026-09-05 with hammer2-utils at the checkout in
`~/.cargo/git/checkouts/libfs-4bceadabbcd60859/74266fe` against the Linux
port at 0.7.0, on a volume with `TEST`, `SNAP1` and `NEWPFS` present and
listed by `pfs-list`.

## Suggested change

Read `/proc/self/mounts`, which lists every mount visible to the process
in `fstab(5)` form: device, mount point, type, options, and two numbers.
Octal escapes in the first two fields (`\040` for a space) want decoding
to match what `getmntinfo` returns on the BSDs.

    pub fn get_mnt_info() -> Result<Vec<(String, String, String)>, std::string::FromUtf8Error> {
        let mut v = vec![];
        if let Ok(s) = std::fs::read_to_string("/proc/self/mounts") {
            for line in s.lines() {
                let f: Vec<&str> = line.split_whitespace().collect();
                if f.len() >= 3 {
                    v.push((f[2].to_string(), unescape(f[1]), unescape(f[0])));
                }
            }
        }
        Ok(v)
    }

with `unescape` decoding `\ooo`. The tuple order follows the FreeBSD
implementation: type, mount point, device.

## Why it matters to this port

The Linux kernel driver now answers the PFS ioctls, and the documented
way to delete a PFS or a snapshot, `hammer2 pfs-delete LABEL`, cannot
reach it without the selector. Until this lands the port's documentation
tells testers to pass `-s`.

## Standing at upstream

Checked 2026-09-06 against `kusumi/libfs` at its head, `74266fe`
(2026-06-01), the same commit the local checkout carries: `src/os/linux.rs`
still returns the empty list, and the FreeBSD implementation beside it
still pushes `(fstypename, mntonname, mntfromname)`, the order the change
above keeps. The one consumer, `libhammer2::subs::get_hammer2_mounts()`,
reads the first two fields and ignores the third. The repository has
issues disabled, no pull requests and no forks, so nothing can be
concluded from silence there and the report cannot be filed on the
forge; it goes to the author directly or rides a hammer2-utils thread.
