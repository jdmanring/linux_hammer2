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
	sed 's/^./0/' "$t/good.manifest" > "$t/bad.manifest"
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
		if [ "$c" -eq 0 ] || [ -z "$lbl" ]; then
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
	[ "$fail" -eq 0 ] || exit 1
	echo "fixtures: selftest: 3 direction(s), 0 failed"
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

# Build first. A gate that boots a guest before finding out the module does
# not compile has spent four gigabytes to tell you what make would have.
if ! make KDIR="$KDIR" >/dev/null 2>&1; then
	echo "fixtures: FAIL: the module does not build against $KDIR"
	exit 1
fi
KO=src/sys/fs/hammer2/hammer2.ko
[ -f "$KO" ] || { echo "fixtures: FAIL: $KO was not produced"; exit 1; }

started=no
if [ "$($VIRSH domstate "$GUEST" 2>/dev/null)" != "running" ]; then
	$VIRSH start "$GUEST" >/dev/null 2>&1 || {
		echo "fixtures: COULD-NOT-RUN: $GUEST would not start" >&2; exit 2; }
	started=yes
fi

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
	return 0
}
trap 'cleanup' EXIT

i=0
while [ "$i" -lt 60 ]; do
	ssh -o ConnectTimeout=4 -o BatchMode=yes "$GUEST_SSH" true 2>/dev/null && break
	i=$((i + 1))
done
if [ "$i" -ge 60 ]; then
	echo "fixtures: COULD-NOT-RUN: $GUEST did not answer ssh" >&2
	exit 2
fi

scp -o ConnectTimeout=5 "$KO" "$GUEST_SSH:/tmp/hammer2.ko" >/dev/null 2>&1 || {
	echo "fixtures: COULD-NOT-RUN: could not copy the module" >&2; exit 2; }
ssh "$GUEST_SSH" 'rmmod hammer2 2>/dev/null; insmod /tmp/hammer2.ko' 2>/dev/null || {
	echo "fixtures: FAIL: the module did not load on $GUEST"; exit 1; }

fail=0
images=0
files=0
dev=b
for m in $manifests; do
	base=$(basename "$m" .manifest)
	img=$FIXDIR/$base.img
	label=$(sed -n 's/^# label //p' "$m" | head -1)
	want=$(command grep -c '^[0-9a-f]\{32\}  ' "$m")
	if [ -z "$label" ] || [ "$want" -eq 0 ]; then
		echo "  FAIL $base: manifest names no label or no file"
		fail=$((fail + 1)); continue
	fi

	vd=vd$dev
	$VIRSH attach-disk "$GUEST" "$img" "$vd" --targetbus virtio \
	    >/dev/null 2>&1 || {
		echo "  FAIL $base: could not attach $img as $vd"
		fail=$((fail + 1)); continue; }
	attached="$attached $vd"
	dev=$(printf '%s' "$dev" | tr 'b-y' 'c-z')

	mnt=/mnt/h2gate-$base
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
	files=$((files + want))

	# THE NEGATIVE CONTROL, ON EVERY RUN AND ON THIS IMAGE. A manifest
	# with one hash altered must fail against the same mount that just
	# passed. Without it a silent md5sum, an empty sums file or a mount
	# that landed somewhere else all read as a pass.
	ctl=$(ssh "$GUEST_SSH" "cd $mnt && \
	    sed '1s/^./0/' /tmp/$base.sums > /tmp/$base.bad && \
	    md5sum -c --quiet /tmp/$base.bad" 2>&1)
	if [ $? -eq 0 ]; then
		echo "  FAIL $base: an altered manifest also verified, so the"
		echo "        comparison above proves nothing"
		fail=$((fail + 1))
		continue
	fi
	echo "  ok   $base: $want file(s), $(sed -n 's/^# writer //p' "$m" | head -1)"
done

if [ "$images" -eq 0 ]; then
	echo "fixtures: FAIL: no image was mounted, so this read nothing" >&2
	exit 1
fi

echo "fixtures: $images image(s), $files file(s) verified, $fail failure(s)"
echo "fixtures: not read here: the on-media block counts that say which"
echo "          branch each file took, and anything a second mount of the"
echo "          same device would show"
[ "$fail" -eq 0 ] || exit 1
exit 0
