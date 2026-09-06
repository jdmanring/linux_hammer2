#!/bin/sh
# EVERY READ-PATH RESULT THIS TREE RECORDS WAS TYPED AT A GUEST BY HAND.
# This gate is the same measurements without a person driving them: it builds
# the module, puts it on a guest, mounts each fixture image and compares every
# file against a manifest committed here.
#
# WHY THE MANIFESTS ARE IN THIS REPOSITORY AND THE IMAGES ARE NOT. An image is
# 2 to 8 GiB and fully allocated, so it cannot be carried; a manifest is the
# part that constitutes the claim. f5's manifest holds checksums DragonFly
# itself reported before unmounting, which is the only form in which that
# measurement can be kept: taking them on Linux afterwards would compare this
# module against itself.
#
# EXIT 2 IS COULD-NOT-RUN AND IS NEVER A PASS. Most machines have no guest and
# no images, CI has neither, and a gate that quietly passes there would make
# the whole read path look tested by CI when nothing ran.
set -u
cd "$(dirname "$0")/.." || exit 2

FIXDIR=${H2_FIXTURE_DIR:-/mnt/storage/hammer2-fixtures}
GUEST=${H2_GUEST:-artix-s6-kde}
GUEST_SSH=${H2_GUEST_SSH:-root@192.168.122.16}
VIRSH="virsh --connect ${H2_LIBVIRT_URI:-qemu:///system}"
KDIR=${KDIR:-/lib/modules/$(uname -r)/build}

if [ "${1:-}" = "--selftest" ]; then
	fail=0
	t=$(mktemp -d) || exit 2
	trap 'rm -rf "$t"' EXIT
	# The comparison this gate rests on is md5sum -c. Drive it both ways
	# on a fixture built here, because a comparison that cannot fail is
	# the whole class of defect this gate exists to avoid.
	printf 'content\n' > "$t/a"
	( cd "$t" && md5sum a > good.manifest )
	sed '1{s/^0/1/;t;s/^./0/}' "$t/good.manifest" > "$t/bad.manifest"
	if ! ( cd "$t" && md5sum -c --quiet good.manifest >/dev/null 2>&1 ); then
		echo "  FAIL selftest: a correct manifest did not verify"
		fail=$((fail + 1))
	else
		echo "  ok   selftest: a correct manifest verifies"
	fi
	if ( cd "$t" && md5sum -c --quiet bad.manifest >/dev/null 2>&1 ); then
		echo "  FAIL selftest: a corrupted manifest verified, so the"
		echo "       comparison below proves nothing"
		fail=$((fail + 1))
	else
		echo "  ok   selftest: a corrupted manifest fails"
	fi
	# Every manifest committed here must parse and name at least one file.
	n=0
	for m in test/fixtures/*.manifest; do
		[ -f "$m" ] || continue
		n=$((n + 1))
		c=$(command grep -c '^[0-9a-f]\{32\}  ' "$m")
		lbl=$(sed -n 's/^# label //p' "$m" | head -1)
		command grep -q '^# refuse$' "$m" && c=refuse
		if [ "$c" = 0 ] || [ -z "$lbl" ]; then
			echo "  FAIL selftest: $m names $c file(s) and label '$lbl'"
			fail=$((fail + 1))
		fi
	done
	if [ "$n" -eq 0 ]; then
		echo "  FAIL selftest: no manifest found, so the loop above read nothing"
		fail=$((fail + 1))
	else
		echo "  ok   selftest: $n manifest(s) parse and name a label and files"
	fi
	# The alteration itself, driven on a hash that already begins with 0,
	# which is the input that made the old one a no-op.
	for h in 0bc 1bc abc; do
		g=$(printf '%s  x\n' "$h" | sed '1{s/^0/1/;t;s/^./0/}')
		if [ "$g" = "$h  x" ]; then
			echo "  FAIL selftest: altering '$h' changed nothing, so"
			echo "       the per-image control would pass its own copy"
			fail=$((fail + 1))
		fi
	done
	[ "$fail" -eq 0 ] || exit 1
	echo "  ok   selftest: the alteration changes a hash whatever it starts with"
	echo "fixtures: selftest: 4 direction(s), 0 failed"
	exit 0
fi

# Prerequisites. Each one is COULD-NOT-RUN and says which, because "the gate
# passed" and "the gate found no machine" must never read the same.
command -v "${VIRSH%% *}" >/dev/null || {
	echo "fixtures: COULD-NOT-RUN: no virsh" >&2; exit 2; }
command -v ssh >/dev/null || {
	echo "fixtures: COULD-NOT-RUN: no ssh" >&2; exit 2; }
[ -d "$FIXDIR" ] || {
	echo "fixtures: COULD-NOT-RUN: no $FIXDIR" >&2; exit 2; }
[ -f "$KDIR/Makefile" ] || {
	echo "fixtures: COULD-NOT-RUN: KDIR=$KDIR is not a kernel build tree" >&2
	exit 2; }
# A tree below the floor cannot build the module, and that is a fact about
# the tree and not the module: the default KDIR is the host's kernel, and
# the host is not the guest. The floor is read from where it is enforced.
floor=$(sed -n 's/^#define LINUX_HAMMER2_FLOOR[[:space:]]*KERNEL_VERSION(\([0-9]*\), \([0-9]*\), .*/\1.\2/p' src/sys/fs/hammer2/hammer2_os.h)
kver=$(make -s -C "$KDIR" kernelversion 2>/dev/null)
[ -n "$floor" ] && [ -n "$kver" ] || {
	echo "fixtures: COULD-NOT-RUN: could not read the floor or the KDIR release" >&2
	exit 2; }
if [ "$(printf '%s\n%s\n' "$floor" "$kver" | sort -V | head -1)" != "$floor" ]; then
	echo "fixtures: COULD-NOT-RUN: KDIR=$KDIR is $kver, below the $floor floor;" >&2
	echo "          point KDIR at the guest's kernel tree" >&2
	exit 2
fi

manifests=""
for m in test/fixtures/*.manifest; do
	[ -f "$m" ] || continue
	img=$FIXDIR/$(basename "$m" .manifest).img
	[ -f "$img" ] || continue
	manifests="$manifests $m"
done
if [ -z "$manifests" ]; then
	echo "fixtures: COULD-NOT-RUN: no manifest in test/fixtures has an" >&2
	echo "          image beside it in $FIXDIR" >&2
	exit 2
fi

$VIRSH domstate "$GUEST" >/dev/null 2>&1 || {
	echo "fixtures: COULD-NOT-RUN: no guest $GUEST" >&2; exit 2; }

# ONE IMAGE ATTACHED AT A TIME, always as vdb, released before the next is
# attached. Holding every image at once ran out of the guest's virtio slots
# at the eighth, which the gate reported as an attach failure it had caused;
# the twenty-five-target ceiling this used to check was never the limit.
nman=$(printf '%s\n' $manifests | command grep -c .)

# Build first. A gate that boots a guest before finding out the module does
# not compile has spent four gigabytes to tell you what make would have.
if ! make KDIR="$KDIR" >/dev/null 2>&1; then
	echo "fixtures: FAIL: the module does not build against $KDIR"
	exit 1
fi
KO=src/sys/fs/hammer2/hammer2.ko
[ -f "$KO" ] || { echo "fixtures: FAIL: $KO was not produced"; exit 1; }

# STARTING A GUEST IS A SIDE EFFECT, NOT A PREREQUISITE THIS GATE MAY TAKE
# ON ITS OWN. script/pre-push-check.sh runs every gate on every push, so a
# gate that boots a 4 GiB domain when it finds one stopped spends that on
# every push, on a machine whose memory somebody else is using. It is opt in.
started=no
# Leave the machine as it was found: detach what this attached and shut the
# guest down only if this started it. A gate that leaves 4 GiB held is one
# nobody runs twice.
attached=""
cleanup() {
	ssh -o ConnectTimeout=5 "$GUEST_SSH" \
	    'cd /; for m in /mnt/h2gate*; do umount "$m" 2>/dev/null; done;
	     rmmod hammer2 2>/dev/null' >/dev/null 2>&1
	for d in $attached; do
		$VIRSH detach-disk "$GUEST" "$d" >/dev/null 2>&1
	done
	[ "$started" = yes ] && $VIRSH shutdown "$GUEST" >/dev/null 2>&1
	rm -f "${tmpb:-}" "${tmpx:-}" "${tmpi:-}"
	return 0
}
trap 'cleanup' EXIT

# A guest that answers ssh is usable whatever the domain says. One that is
# listed running and does not answer is either booting, which another
# script leaves it doing, or shutting down; waiting tells them apart,
# because the first answers within the wait and the second turns to shut
# off inside it and can then be started. Only a guest that stays listed
# running and silent for the whole wait is given up on. This gate starts
# a guest only when H2_FIXTURE_START=1 says so, and then only alone.
i=0
while [ "$i" -lt 60 ]; do
	ssh -o ConnectTimeout=4 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null && break
	state=$($VIRSH domstate "$GUEST" 2>/dev/null) || { echo "fixtures: COULD-NOT-RUN: no guest $GUEST" >&2; exit 2; }
	if [ "$state" != "running" ]; then
		if [ "${H2_FIXTURE_START:-0}" != "1" ]; then
			echo "fixtures: COULD-NOT-RUN: $GUEST is $state, and this" >&2
			echo "          gate does not start one unless H2_FIXTURE_START=1" >&2
			exit 2
		fi
		# ONE GUEST AT A TIME ON THIS HOST. Each holds 4 GiB and the host
		# is shared with other sessions' benches, so a second domain
		# already running is a reason not to start this one, not a reason
		# to race it. A virsh that fails must stop this, not count as no
		# other guest: that fallback would supply the answer that lets a
		# second domain start.
		names=$($VIRSH list --name 2>/dev/null) || {
			echo "fixtures: COULD-NOT-RUN: virsh list failed, so other guests cannot be counted" >&2; exit 2; }
		other=$(printf '%s\n' "$names" | command grep -c . || true)
		if [ "$other" -gt 0 ] && [ "${H2_FIXTURE_SHARE:-0}" != 1 ]; then
			echo "fixtures: COULD-NOT-RUN: $other other guest(s) running:" >&2
			printf '%s\n' "$names" | sed 's/^/          /' >&2
			echo "          set H2_FIXTURE_SHARE=1 to start $GUEST beside them" >&2
			exit 2
		fi
		$VIRSH start "$GUEST" >/dev/null 2>&1 || { echo "fixtures: COULD-NOT-RUN: $GUEST would not start" >&2; exit 2; }
		started=yes
	fi
	sleep 5
	i=$((i + 1))
done
if [ "$i" -ge 60 ]; then
	echo "fixtures: COULD-NOT-RUN: $GUEST did not answer ssh in 5 minutes; it is listed $state" >&2
	exit 2
fi

# A MODULE BUILT FOR ANOTHER KERNEL IS A CONFIGURATION MISMATCH AND NOT A
# DEFECT IN THIS TREE. The first run of this gate under pre-push built
# against the host's KDIR, since that is the default, and reported the
# refusal to load on a guest running something else as a failure. insmod
# rejects it on vermagic, so the answer is knowable before the attempt and
# reads as COULD-NOT-RUN naming both kernels.
guest_rel=$(ssh "$GUEST_SSH" 'uname -r' 2>/dev/null)
ko_rel=$(modinfo -F vermagic "$KO" 2>/dev/null | awk '{print $1}')
if [ -z "$guest_rel" ] || [ -z "$ko_rel" ]; then
	echo "fixtures: COULD-NOT-RUN: could not read the guest release or the" >&2
	echo "          module's vermagic, so a load could not be attributed" >&2
	exit 2
fi
if [ "$guest_rel" != "$ko_rel" ]; then
	echo "fixtures: COULD-NOT-RUN: the module is built for $ko_rel and" >&2
	echo "          $GUEST runs $guest_rel, so insmod would refuse it on" >&2
	echo "          vermagic. Point KDIR at the guest's kernel." >&2
	exit 2
fi

# LOCKDEP MUST STILL BE ALIVE WHEN THIS GATE ENDS. The instrument disables
# itself after its first report and validates nothing from then on, so a
# clean dmesg after that point is silence and not evidence. On a guest
# with CONFIG_PROVE_LOCKING, debug_locks is read before the module loads
# and again after the last unmount; a drop from 1 to 0 fails the gate and
# prints the report that caused it. Without lockdep the file is absent and
# the check is skipped by name.
locks_before=$(ssh "$GUEST_SSH" 'sed -n "s/^ *debug_locks: *//p" /proc/lockdep_stats' 2>/dev/null)
ssh "$GUEST_SSH" 'dmesg -C' >/dev/null 2>&1

scp -o ConnectTimeout=5 "$KO" "$GUEST_SSH:/tmp/hammer2.ko" >/dev/null 2>&1 || {
	echo "fixtures: COULD-NOT-RUN: could not copy the module" >&2; exit 2; }
ssh "$GUEST_SSH" 'rmmod hammer2 2>/dev/null; insmod /tmp/hammer2.ko' 2>/dev/null || {
	echo "fixtures: FAIL: the module built for this guest did not load"; exit 1; }

# THE IOCTL EXERCISER, WHICH IS PART OF THIS GATE AND NOT A PREREQUISITE OF
# IT. test/hammer2-ioctl-exercise.c is built here rather than on the guest,
# which has no toolchain, and statically, because a host binary linked
# against this machine's glibc against another distribution's loader fails
# in a way that reads as a filesystem defect. If either step fails the
# exerciser is skipped by name and the summary line's count goes to zero,
# which is why that count is printed.
IOCTL_EX=
tmpx=$(mktemp) || exit 2
tmpi=$(mktemp) || exit 2
if cc -static -O2 -Isrc/sys/fs/hammer2 -o "$tmpx" \
    test/hammer2-ioctl-exercise.c >/dev/null 2>&1 &&
    scp -o ConnectTimeout=5 "$tmpx" "$GUEST_SSH:/tmp/h2ioctl" >/dev/null 2>&1
then
	ssh "$GUEST_SSH" 'chmod 755 /tmp/h2ioctl' >/dev/null 2>&1 && IOCTL_EX=1
fi
[ -n "$IOCTL_EX" ] ||
    echo "  note the ioctl exerciser did not build or copy, so no ioctl ran"

# The recorded results, measured on the guest against the shipped module.
# `unknown-h` is the dispatch's own default arm and `foreign-type` the
# entry point's check on the command's type letter, which is why both
# read ENOTTY from two different places. `zero-size` is reachable only as
# root, the capability being checked before the size, which is the quiet
# half of the argument guard and the reason it is exercised twice.
IOCTL_ROOT_EXPECT='version 0
pfs-get 0
inode-get 0
volume-list 0
unknown-h -25
foreign-type -25
zero-size -22'
IOCTL_UNPRIV_EXPECT='version 0
unpriv-pfs-get -1
unpriv-inode-set -1'

fail=0
images=0
files=0
blocks=0
links=0
corrupts=0
stats=0
statfss=0
ioctls=0
tmpb=$(mktemp) || exit 2
release_image() {
	[ -n "$attached" ] || return 0
	ssh "$GUEST_SSH" 'cd /; for m in /mnt/h2gate*; do umount "$m" 2>/dev/null; done' \
	    >/dev/null 2>&1
	$VIRSH detach-disk "$GUEST" "$attached" >/dev/null 2>&1
	attached=""
}
for m in $manifests; do
	release_image
	base=$(basename "$m" .manifest)
	img=$FIXDIR/$base.img
	label=$(sed -n 's/^# label //p' "$m" | head -1)
	want=$(command grep -c '^[0-9a-f]\{32\}  ' "$m")
	refuse=0; command grep -q '^# refuse$' "$m" && refuse=1
	corrupt=$(sed -n 's/^# corrupt //p' "$m")
	if [ -z "$label" ] || { [ "$want" -eq 0 ] && [ "$refuse" = 0 ]; }; then
		echo "  FAIL $base: manifest names no label or no file"
		fail=$((fail + 1)); continue
	fi

	vd=vdb
	# --mode readonly: the fixture is the claim, so the guest is not given
	# a way to write it, whatever the mount asks for.
	$VIRSH attach-disk "$GUEST" "$img" "$vd" --targetbus virtio \
	    --mode readonly >/dev/null 2>&1 || {
		echo "  FAIL $base: could not attach $img as $vd"
		fail=$((fail + 1)); continue; }
	attached="$vd"

	mnt=/mnt/h2gate-$base

	# F3, THE MEDIA THAT MUST BE REFUSED. `# refuse` says the mount has
	# to fail; the image is not modified by the attempt, which the
	# manifest's own md5 of the image would say but the gate does not
	# take, a 2 GiB checksum per run being the wrong price for a
	# read-only mount of a read-only attachment.
	if [ "$refuse" = 1 ]; then
		images=$((images + 1))
		if ssh "$GUEST_SSH" "mkdir -p $mnt && \
		    mount -t hammer2 -o ro /dev/$vd@$label $mnt" >/dev/null 2>&1; then
			ssh "$GUEST_SSH" "umount $mnt" >/dev/null 2>&1
			echo "  FAIL $base: corrupt media mounted, so nothing checked it"
			fail=$((fail + 1)); continue
		fi
		why=$(ssh "$GUEST_SSH" "dmesg | grep hammer2 | tail -1" 2>/dev/null)
		echo "  ok   $base: mount refused, $(sed -n 's/^# writer //p' "$m" | head -1)"
		echo "        ${why#*] }"
		continue
	fi

	scp -o ConnectTimeout=5 "$m" "$GUEST_SSH:/tmp/$base.manifest" \
	    >/dev/null 2>&1
	out=$(ssh "$GUEST_SSH" "mkdir -p $mnt && \
	    mount -t hammer2 -o ro /dev/$vd@$label $mnt && cd $mnt && \
	    command grep '^[0-9a-f]' /tmp/$base.manifest > /tmp/$base.sums && \
	    md5sum -c --quiet /tmp/$base.sums" 2>&1)
	rc=$?
	images=$((images + 1))
	if [ "$rc" -ne 0 ]; then
		echo "  FAIL $base: $want file(s) did not verify against the manifest"
		printf '%s\n' "$out" | sed 's/^/        /' | head -6
		fail=$((fail + 1))
		continue
	fi

	# THE READ-ONLY IOCTLS, ON A MOUNT THAT HAS JUST VERIFIED. Only the
	# read-only subset: the fixtures are attached read-only, so snapshot
	# create, PFS create and delete, growfs and bulkfree cannot be
	# reached from here and stay hand-verified on a guest.
	#
	# The fixed lines are compared literally and the two counts are
	# checked for being non-zero, because they differ per image and a
	# bound written here would be a second copy of the manifest. The
	# unprivileged run is a separate invocation under setpriv, since
	# `su nobody` cannot log in on this guest: the account is expired.
	if [ -n "$IOCTL_EX" ]; then
		iout=$(ssh "$GUEST_SSH" "/tmp/h2ioctl $mnt" 2>&1); irc=$?
		uout=$(ssh "$GUEST_SSH" \
		    "setpriv --reuid=65534 --regid=65534 --clear-groups \
		     /tmp/h2ioctl -u $mnt" 2>&1); urc=$?
		igot=$(printf '%s\n' "$iout" |
		    command grep -v '^\(version-number\|pfs-count\|volume-count\) ')
		npfs=$(printf '%s\n' "$iout" | sed -n 's/^pfs-count //p')
		nvol=$(printf '%s\n' "$iout" | sed -n 's/^volume-count //p')
		if [ "$irc" -ne 0 ] || [ "$urc" -ne 0 ]; then
			echo "  FAIL $base: the ioctl exerciser did not run:"
			printf '%s\n%s\n' "$iout" "$uout" |
			    sed 's/^/        /' | head -6
			fail=$((fail + 1)); continue
		fi
		if [ "$igot" != "$IOCTL_ROOT_EXPECT" ] ||
		    [ "$uout" != "$IOCTL_UNPRIV_EXPECT" ]; then
			echo "  FAIL $base: the ioctl results are not the recorded ones:"
			printf '%s\n%s\n' "$IOCTL_ROOT_EXPECT" \
			    "$IOCTL_UNPRIV_EXPECT" > "$tmpb"
			printf '%s\n%s\n' "$igot" "$uout" > "$tmpi"
			diff "$tmpb" "$tmpi" | sed 's/^/        /' | head -10
			fail=$((fail + 1)); continue
		fi
		if [ "${npfs:-0}" -lt 1 ] || [ "${nvol:-0}" -lt 1 ]; then
			echo "  FAIL $base: the scans returned $npfs PFS(s) and"
			echo "        $nvol volume(s), so they read nothing"
			fail=$((fail + 1)); continue
		fi
		ioctls=$((ioctls + $(printf '%s\n%s\n' "$igot" "$uout" |
		    command grep -c .)))
	fi
	files=$((files + want))

	# THE BLOCK COUNTS, WHICH ARE ABOUT THE FIXTURE AND NOT THE CODE.
	# i_blocks is the on-media count, so it says whether a file is
	# embedded in its inode, stored compressed, stored raw or a hole. A
	# set of matching checksums cannot say that: if an image were
	# regenerated without compression every checksum would still match
	# while the compressed path silently stopped being exercised. What
	# it does not distinguish is one compressor from another, f3 at LZ4
	# and f4 at ZLIB reporting the same counts because both compress
	# below the smallest allocation.
	bexp=$(sed -n 's/^# blocks //p' "$m" | sort -k2)
	nb=$(printf '%s\n' "$bexp" | command grep -c .)
	if [ "$nb" -eq 0 ]; then
		echo "  FAIL $base: the manifest records no block count, so the"
		echo "        branch each file takes is unasserted"
		fail=$((fail + 1)); continue
	fi
	printf '%s\n' "$bexp" | while read -r n rel; do
		printf '%s %s\n' "$n" "$rel"
	done > "$tmpb"
	scp -o ConnectTimeout=5 "$tmpb" "$GUEST_SSH:/tmp/$base.blocks" \
	    >/dev/null 2>&1
	bgot=$(ssh "$GUEST_SSH" "cd $mnt && while read -r n rel; do \
	    printf '%s %s\\n' \"\$(stat -c %b \"\$rel\")\" \"\$rel\"; \
	    done < /tmp/$base.blocks" 2>/dev/null)
	if [ "$bgot" != "$(cat "$tmpb")" ]; then
		echo "  FAIL $base: on-media block counts moved, so this image no"
		echo "        longer exercises the branches it was built for"
		diff "$tmpb" - <<-EOD 2>/dev/null | sed 's/^/        /' | head -8
		$bgot
		EOD
		fail=$((fail + 1)); continue
	fi

	# THE NEGATIVE CONTROL, ON EVERY RUN AND ON THIS IMAGE. A manifest
	# with one hash altered must fail against the same mount that just
	# passed. Without it a silent md5sum, an empty sums file or a mount
	# that landed somewhere else all read as a pass.
	# The alteration flips the first character between 0 and 1 rather
	# than setting it to 0. Setting it was a no-op one time in sixteen,
	# whenever the hash already began with 0, and then the unaltered
	# manifest verified and this gate reported that its own comparison
	# proves nothing. All five manifests here happen not to begin with
	# 0, which is luck and does not announce itself.
	#
	# A cmp of the two files does not belong in this chain. A chain that
	# fails because the alteration changed nothing is indistinguishable,
	# at the status, from one that failed because the altered manifest was
	# correctly rejected, so it would turn a visible wrong answer into a
	# silent right-looking one. The alteration is instead proved to change
	# any hash by --selftest, on 0, on 1 and on a letter.
	if ssh "$GUEST_SSH" "cd $mnt && \
	    sed '1{s/^0/1/;t;s/^./0/}' /tmp/$base.sums > /tmp/$base.bad && \
	    md5sum -c --quiet /tmp/$base.bad" >/dev/null 2>&1; then
		echo "  FAIL $base: an altered manifest also verified, so the"
		echo "        comparison above proves nothing"
		fail=$((fail + 1))
		continue
	fi
	blocks=$((blocks + nb))

	# F3, THE FILE THAT MUST NOT READ. `# corrupt relpath` names a file
	# whose data block was altered on media; the checksum on the block
	# has to catch it and the read has to fail, never return the bytes.
	for rel in $corrupt; do
		err=$(ssh "$GUEST_SSH" "cd $mnt && cat '$rel' 2>&1 > /dev/null; \
		    dmesg | grep hammer2 | tail -1" 2>/dev/null)
		if ssh "$GUEST_SSH" "cd $mnt && cat '$rel' > /dev/null" \
		    >/dev/null 2>&1; then
			echo "  FAIL $base: $rel read back, its altered block unnoticed"
			fail=$((fail + 1)); continue 2
		fi
		corrupts=$((corrupts + 1))
		printf '%s\n' "$err" | sed 's/^\[[^]]*\] //; s/^/        /'
	done

	# THE STAT FIELDS, FROM THE WRITER'S OWN stat. A `# stat` row carries
	# the octal mode with its type bits, the link count, owner, group and
	# inode number DragonFly reported for a path, and the guest's stat is
	# printed in the same shape: %f is the raw mode in hex, so it is
	# re-printed in octal. Two names sharing an inode number and a link
	# count of 3 is what hard-link identity looks like from outside.
	sexp=$(sed -n 's/^# stat //p' "$m")
	ns=$(printf '%s\n' "$sexp" | command grep -c . || true)
	if [ "$ns" -gt 0 ]; then
		printf '%s\n' "$sexp" > "$tmpb"
		scp -o ConnectTimeout=5 "$tmpb" "$GUEST_SSH:/tmp/$base.stat" \
		    >/dev/null 2>&1
		sgot=$(ssh "$GUEST_SSH" "cd $mnt && while read -r mode nl u g ino rel; do \
		    set -- \$(stat -c '%f %h %u %g %i' "\$rel"); \
		    printf '%o %s %s %s %s %s\\n' 0x\$1 \$2 \$3 \$4 \$5 "\$rel"; \
		    done < /tmp/$base.stat" 2>/dev/null)
		if [ "$sgot" != "$(cat "$tmpb")" ]; then
			echo "  FAIL $base: stat fields differ from what DragonFly reported"
			diff "$tmpb" - <<-EOD 2>/dev/null | sed 's/^/        /' | head -8
			$sgot
			EOD
			fail=$((fail + 1)); continue
		fi
		stats=$((stats + ns))
	fi

	# STATFS, AGAINST DragonFly's df AS ROOT: 1 KiB blocks in total, used
	# and free, and inodes in use. The free figure is f_bfree, the root
	# view, since the row was taken as root and the 5% reserve only moves
	# f_bavail here. Blocks and bsize come from the guest's statfs and
	# are folded to 1 KiB, the unit df prints on both sides.
	fexp=$(sed -n 's/^# statfs //p' "$m" | head -1)
	if [ -n "$fexp" ]; then
		fgot=$(ssh "$GUEST_SSH" "set -- \$(stat -f -c '%S %b %f %c %d' $mnt); \
		    echo \$((\$2 * \$1 / 1024)) \$(((\$2 - \$3) * \$1 / 1024)) \
		    \$((\$3 * \$1 / 1024)) \$((\$4 - \$5))" 2>/dev/null)
		if [ "$fgot" != "$fexp" ]; then
			echo "  FAIL $base: statfs differs from DragonFly's df: got '$fgot', DragonFly said '$fexp'"
			fail=$((fail + 1)); continue
		fi
		statfss=$((statfss + 1))
	fi

	# THE SYMLINKS, WHICH md5sum FOLLOWS AND SO NEVER READS. A symlink's
	# target is file data, embedded in the inode for every link here, and
	# ->get_link reads it through the same ->read_folio a file uses. The
	# rows are optional: an image with no symlink asserts none, and the
	# summary line carries the total so a count of zero is visible.
	lexp=$(sed -n 's/^# link //p' "$m")
	nl=$(printf '%s\n' "$lexp" | command grep -c . || true)
	if [ "$nl" -gt 0 ]; then
		printf '%s\n' "$lexp" > "$tmpb"
		scp -o ConnectTimeout=5 "$tmpb" "$GUEST_SSH:/tmp/$base.links" \
		    >/dev/null 2>&1
		lgot=$(ssh "$GUEST_SSH" "cd $mnt && while read -r target rel; do \
		    printf '%s %s\\n' \"\$(readlink \"\$rel\")\" \"\$rel\"; \
		    done < /tmp/$base.links" 2>/dev/null)
		if [ "$lgot" != "$(cat "$tmpb")" ]; then
			echo "  FAIL $base: a symlink did not read back as the manifest"
			echo "        records it"
			diff "$tmpb" - <<-EOD 2>/dev/null | sed 's/^/        /' | head -8
			$lgot
			EOD
			fail=$((fail + 1)); continue
		fi
		links=$((links + nl))
	fi
	echo "  ok   $base: $want file(s), $nb block count(s), $nl symlink(s), $(sed -n 's/^# writer //p' "$m" | head -1)"
done

if [ "$images" -eq 0 ]; then
	echo "fixtures: FAIL: no image was mounted, so this read nothing" >&2
	exit 1
fi

release_image
if [ "${locks_before:-}" = 1 ]; then
	locks_after=$(ssh "$GUEST_SSH" 'sed -n "s/^ *debug_locks: *//p" /proc/lockdep_stats' 2>/dev/null)
	if [ "$locks_after" != 1 ]; then
		echo "  FAIL lockdep disabled itself during this run; its report:"
		ssh "$GUEST_SSH" 'dmesg | grep -A12 "^\[[^]]*\] WARNING: possible\|^\[[^]]*\] WARNING: inconsistent" | head -14' 2>/dev/null |
		    sed 's/^/        /'
		fail=$((fail + 1))
	else
		echo "  ok   lockdep stayed enabled across every mount, read and unmount"
	fi
else
	echo "  note lockdep is not built into $guest_rel, so lock order was not validated"
fi

echo "fixtures: $images image(s), $files file(s), $blocks block count(s), $stats stat row(s), $statfss statfs, $links symlink(s), $corrupts corrupt file(s) refused, $ioctls ioctl result(s), $fail failure(s)"
echo "fixtures: not read here: which compressor an image used, the counts"
echo "          being equal for LZ4 and ZLIB, anything a second mount of the"
echo "          same device would show, and the writing ioctls: snapshot,"
echo "          PFS create and delete, growfs and bulkfree need a writable"
echo "          mount and are verified by hand"
[ "$fail" -eq 0 ] || exit 1
exit 0
