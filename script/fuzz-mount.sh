#!/bin/sh
# MUTATED MEDIA AGAINST THE MOUNT PATH, WITH NO CRASH AS THE VERDICT.
# 0.5 asks for a fuzzing corpus run against the mount path before any
# writable root is offered. This is that run: N copies of a seed image, each
# with a few bytes changed at recorded offsets, hot-plugged read-only into a
# running guest, mounted, listed and read end to end. The mount may succeed
# or be refused, a file may read or fail with EIO; what may not happen is a
# WARNING, BUG, oops, hung task, lockdep report or a guest that stops
# answering. The corpus is the generator and its seed: every mutation is
# printed as offset:old>new, so a finding reproduces from its seed and index
# without keeping the images.
#
# THE SEED IS NOT MADE HERE. It is a small volume formatted by newfs_hammer2
# and populated through the write path; doc/README.testing.md has the
# procedure. The mutator samples until it hits
# a byte that is not zero, so a 64 MiB image that is mostly empty does not
# absorb the hits.
#
# TWO CONTROLS RUN FIRST. The seed itself must mount with every file
# readable, or the reader is broken and nothing below means anything; and
# the seed with one bit of its volume header crc changed must be refused,
# or the refusal this run counts cannot be told from a silent pass.
#
# EXIT 2 IS COULD-NOT-RUN AND IS NEVER A PASS, as in test-fixtures.sh.
set -u
cd "$(dirname "$0")/.." || exit 2

N=${1:-50}
SEED=${2:-1}
FIXDIR=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}
SEEDIMG=${H2_FUZZ_SEED:-$FIXDIR/fz-seed.img}
LABEL=${H2_FUZZ_LABEL:-FUZZ}
WORK=${H2_FUZZ_WORK:-/var/tmp/hammer2-fuzz}
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}
LOG=${H2_FUZZ_LOG:-$WORK/fuzz-$SEED.log}

command -v virsh >/dev/null 2>&1 || { echo "fuzz: COULD-NOT-RUN: no virsh" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "fuzz: COULD-NOT-RUN: no python3" >&2; exit 2; }
[ -f "$SEEDIMG" ] || { echo "fuzz: COULD-NOT-RUN: no seed image $SEEDIMG" >&2; exit 2; }
[ -d "$KDIR" ] || { echo "fuzz: COULD-NOT-RUN: no kernel tree at $KDIR" >&2; exit 2; }
mkdir -p "$WORK" || { echo "fuzz: COULD-NOT-RUN: cannot make $WORK" >&2; exit 2; }
case "$N" in ''|*[!0-9]*|0) echo "fuzz: COULD-NOT-RUN: count must be a positive integer" >&2; exit 2;; esac

# The shipped build, read-only, which is the one the corpus is about.
make -s clean >/dev/null 2>&1
make -s KDIR="$KDIR" >/dev/null 2>&1 || { echo "fuzz: COULD-NOT-RUN: module did not build against $KDIR" >&2; exit 2; }
KO=src/sys/fs/hammer2/hammer2.ko
# What the module was built from, printed with the summary, as
# test-enospc.sh prints it: a run that cannot be tied to a source state
# cannot be dated against a fix.
built=$(git rev-parse --short HEAD 2>/dev/null || echo unknown)
[ -z "$(git status --porcelain -- src 2>/dev/null)" ] || built="$built-dirty"
[ -f "$KO" ] || { echo "fuzz: COULD-NOT-RUN: no $KO after make" >&2; exit 2; }

state=$($VIRSH domstate "$GUEST" 2>/dev/null) || { echo "fuzz: COULD-NOT-RUN: no guest $GUEST" >&2; exit 2; }
# A guest that answers ssh is usable whatever the domain says. One that is
# listed running and does not answer is either booting, which a batch
# reset or another script leaves it doing, or shutting down; waiting tells
# them apart, because the first answers within the wait and the second
# turns to shut off inside it and can then be started. Only a guest that
# stays listed running and silent for the whole wait is given up on.
started=0
# A guest this script started is shut down on every exit, not only the last
# line: a COULD-NOT-RUN after the start left it running for the next script
# to refuse.
trap '[ "$started" = 1 ] && $VIRSH shutdown "$GUEST" >/dev/null 2>&1' EXIT
i=0
while [ "$i" -lt 60 ]; do
	ssh -o ConnectTimeout=4 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null && break
	state=$($VIRSH domstate "$GUEST" 2>/dev/null) || { echo "fuzz: COULD-NOT-RUN: no guest $GUEST" >&2; exit 2; }
	if [ "$state" != "running" ]; then
		[ "${H2_FIXTURE_START:-0}" = 1 ] || {
			echo "fuzz: COULD-NOT-RUN: $GUEST is $state; set H2_FIXTURE_START=1 to start it" >&2; exit 2; }
		$VIRSH start "$GUEST" >/dev/null 2>&1 || { echo "fuzz: COULD-NOT-RUN: $GUEST would not start" >&2; exit 2; }
		started=1
	fi
	sleep 5
	i=$((i + 1))
done
[ "$i" -lt 60 ] || { echo "fuzz: COULD-NOT-RUN: $GUEST did not answer ssh in 5 minutes; it is listed $state, host load $(cut -d" " -f1-3 /proc/loadavg)" >&2; exit 2; }

# The guest side: mount whatever the last virtio disk is, read everything,
# report one line. Written here so the guest carries nothing between runs.
cat > "$WORK/one.sh" <<'GUEST'
#!/bin/sh
dev=$(ls /dev/vd? | tail -1); mkdir -p /mnt/fz; dmesg -C
n=0; until [ -b "$dev" ]; do sleep 1; n=$((n + 1)); [ $n -gt 15 ] && { echo "no device"; exit 0; }; done
if mount -t hammer2 -o ro "$dev@LABEL" /mnt/fz 2>/dev/null; then
	files=0; bad=0
	for f in $(find /mnt/fz -type f 2>/dev/null); do
		files=$((files + 1)); cat "$f" > /dev/null 2>&1 || bad=$((bad + 1))
	done
	ls -laR /mnt/fz > /dev/null 2>&1; find /mnt/fz -type l -exec readlink {} \; > /dev/null 2>&1
	umount /mnt/fz 2>/dev/null; u=$?
	v="mounted files=$files eio=$bad umount=$u"
else
	v="refused"
fi
w=$(dmesg | grep -c -i "WARNING\|BUG\|Oops\|hung task\|panic\|lockdep\|circular")
echo "$v warn=$w"
[ "$w" -gt 0 ] && dmesg | grep -i -A12 "WARNING\|BUG\|Oops\|hung task\|panic\|circular" | head -40
exit 0
GUEST
sed -i "s/@LABEL/@$LABEL/" "$WORK/one.sh"
scp -q -o ConnectTimeout=5 "$WORK/one.sh" "$KO" "$GUEST_SSH:/tmp/" || { echo "fuzz: COULD-NOT-RUN: scp to $GUEST failed" >&2; exit 2; }
ssh "$GUEST_SSH" 'rmmod hammer2 2>/dev/null; insmod /tmp/hammer2.ko' 2>/dev/null || {
	echo "fuzz: COULD-NOT-RUN: module did not load on $GUEST" >&2; exit 2; }

# Attach one image, run the guest side, detach. Prints the verdict line.
one() {
	$VIRSH attach-disk "$GUEST" "$1" vdz --targetbus virtio --mode readonly >/dev/null 2>&1 || {
		echo "attach failed"; return 0; }
	v=$(timeout 120 ssh -o ConnectTimeout=5 "$GUEST_SSH" 'sh /tmp/one.sh' 2>&1); rc=$?
	$VIRSH detach-disk "$GUEST" vdz >/dev/null 2>&1
	n=0
	until ! $VIRSH domblklist "$GUEST" 2>/dev/null | grep -q vdz; do
		sleep 1; n=$((n + 1)); [ $n -gt 20 ] && break
	done
	[ $rc -eq 124 ] && v="guest hung: $v"
	printf '%s\n' "$v"
}

fail=0
: > "$LOG"

# Control 1: the seed itself, every file readable.
rm -f "$WORK/fz.img"; cp "$SEEDIMG" "$WORK/fz.img"
v=$(one "$WORK/fz.img")
case "$v" in
mounted*" eio=0 "*"warn=0") echo "  ok    control: the seed mounts and every file reads ($v)";;
*) echo "  FAIL  control: the seed did not read clean: $v"; fail=$((fail + 1));;
esac
echo "control seed :: $v" >> "$LOG"

# Control 2: one bit in sector 0's crc region, which must be refused.
rm -f "$WORK/fz.img"; cp "$SEEDIMG" "$WORK/fz.img"
printf '\001' | dd of="$WORK/fz.img" bs=1 seek=64 conv=notrunc 2>/dev/null
v=$(one "$WORK/fz.img")
case "$v" in
"refused warn=0") echo "  ok    control: a volume header crc change is refused";;
*) echo "  FAIL  control: the damaged header was not refused: $v"; fail=$((fail + 1));;
esac
echo "control header :: $v" >> "$LOG"

mounted=0; refused=0; warned=0; hung=0; ran=0
i=1
while [ $i -le "$N" ]; do
	rm -f "$WORK/fz.img"; cp "$SEEDIMG" "$WORK/fz.img"
	mut=$(python3 - "$WORK/fz.img" "$SEED" "$i" <<'PY'
import os, random, sys
p, seed, i = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
r = random.Random(seed * 100000 + i)
size = os.path.getsize(p)
k = r.choice([1, 1, 2, 4, 8, 32, 64])
out = []
with open(p, 'r+b') as f:
    for _ in range(k):
        for _ in range(200):
            off = r.randrange(0, min(size, 4 << 20)) if r.random() < 0.7 else r.randrange(0, size)
            f.seek(off); old = f.read(1)[0]
            if old:
                break
        # A byte replaced by its own value is no mutation, and one in
        # five recorded ones was, over two seeds: zero written over a
        # zero the sampling never escaped, ff over ff, a random draw
        # that hit. Redraw until the byte changes.
        while True:
            mode = r.choice(['flip', 'zero', 'ff', 'rand'])
            new = {'flip': old ^ (1 << r.randrange(8)), 'zero': 0, 'ff': 0xff, 'rand': r.randrange(256)}[mode]
            if new != old:
                break
        f.seek(off); f.write(bytes([new]))
        out.append(f"{off:#x}:{old:02x}>{new:02x}")
print(f"k={k} " + ",".join(out))
PY
)
	v=$(one "$WORK/fz.img")
	ran=$((ran + 1))
	printf '%s %s :: %s\n' "$i" "$mut" "$v" >> "$LOG"
	case "$v" in
	*"warn=0") ;;
	*) warned=$((warned + 1)); echo "  FAIL  image $i ($mut): $v";;
	esac
	case "$v" in
	mounted*) mounted=$((mounted + 1));;
	refused*) refused=$((refused + 1));;
	"guest hung"*) hung=$((hung + 1)); echo "  FAIL  image $i ($mut): the guest stopped answering"; break;;
	*) echo "  ??    image $i: $v";;
	esac
	i=$((i + 1))
done
fail=$((fail + warned + hung))

if [ $started = 1 ]; then
	ssh -o ConnectTimeout=5 "$GUEST_SSH" 'rmmod hammer2; poweroff' >/dev/null 2>&1
	n=0
	until [ "$($VIRSH domstate "$GUEST")" = "shut off" ]; do
		sleep 3; n=$((n + 1)); [ $n -gt 60 ] && { $VIRSH destroy "$GUEST" >/dev/null 2>&1; break; }
	done
fi
rm -f "$WORK/fz.img"

[ "$ran" = "$N" ] || { echo "  FAIL  ran $ran of $N images"; fail=$((fail + 1)); }
echo "fuzz: seed $SEED, $ran image(s): $mounted mounted, $refused refused, $warned with a kernel report, $hung hung; built from $built; log $LOG"
[ $fail = 0 ]
