#!/bin/bash
# Turn the root filesystem directory into a flashable ext4 image.
#
#   make-rootfs-image.sh <rootdir> <image> [size-gb]
#
# The UUID is fixed (same value as the one baked into boot.img's cmdline) so
# any boot.img from this repository boots any root image from it.  The image is
# created sparse: the first boot grows it to the full userdata partition.
set -euo pipefail

ROOTDIR=${1:?usage: make-rootfs-image.sh <rootdir> <image> [size-gb]}
IMAGE=${2:?usage: make-rootfs-image.sh <rootdir> <image> [size-gb]}
SIZE_GB=${3:-4}
ROOTFS_UUID=${ROOTFS_UUID:-8f3a5c1e-1d2b-4a5f-9c3e-7b6d2a4f8e11}

ROOTDIR=$(readlink -m "$ROOTDIR")
mkdir -p "$(dirname "$IMAGE")"
rm -f "$IMAGE"
truncate -s "${SIZE_GB}G" "$IMAGE"

# Feature set: lk2nd's tiny ext2 driver mounts this filesystem at boot to read
# /extlinux/extlinux.conf and the kernel, so it must stay inside what that
# driver understands:
#   incompat  only filetype/meta_bg  -> no extent, no 64bit, no flex_bg
#   ro_compat only sparse_super/large_file -> no metadata_csum, huge_file,
#                                              dir_nlink, extra_isize
# Journal stays on (this is a phone that gets its battery pulled); 256-byte
# inodes are kept so timestamps survive past 2038.
mkfs.ext4 -q -F -L redmi-s2 -U "$ROOTFS_UUID" -b 4096 -I 256 \
	-O ^extent,^64bit,^flex_bg,^metadata_csum,^huge_file,^dir_nlink,^extra_isize \
	-d "$ROOTDIR" "$IMAGE" "${SIZE_GB}G"

echo "==> root.img      : $IMAGE"
echo "    size          : $(stat -c %s "$IMAGE") bytes"
echo "    filesystem    : ext4, UUID $ROOTFS_UUID"
echo "    used          : $(du -sh --apparent-size "$ROOTDIR" | cut -f1)"
printf '%s\n' "$ROOTFS_UUID" > "$IMAGE.uuid"
