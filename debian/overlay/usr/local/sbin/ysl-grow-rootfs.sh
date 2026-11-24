#!/bin/sh
# Grow the root filesystem to the full userdata partition on first boot.
#
# The image is flashed as a fixed-size ext4 (4 GiB by default) because the
# partition table of every Redmi S2 variant is not known at build time.  The
# userdata partition itself is normally 48+ GiB, so the first boot grows the
# partition and the filesystem into it.  Best effort: on failure the phone
# still boots with the 4 GiB filesystem and the marker is not written.
set -u

MARKER=/var/lib/ysl-rootfs-grown
[ -e "$MARKER" ] && exit 0

src=$(findmnt -n -o SOURCE /)
case "$src" in
	/dev/mmcblk*p*) ;;
	*) echo "root is $src, not an eMMC partition; not growing"; exit 0 ;;
esac

disk=/dev/$(lsblk -no PKNAME "$src")
num=$(cat "/sys/class/block/$(basename "$src")/partition")

echo "growing $src (partition $num on $disk)"
growpart "$disk" "$num" || { echo "growpart failed"; exit 0; }
resize2fs "$src" || { echo "resize2fs failed"; exit 0; }

mkdir -p "$(dirname "$MARKER")"
date -Iseconds > "$MARKER"
echo "root filesystem grown: $(df -h / | tail -1)"
exit 0
