#!/bin/bash
# Build the flashable "boot" partition image for the Redmi S2.
#
# Layout (this is what lk2nd expects, see lk2nd Documentation/boot.md):
#
#   0x000000  lk2nd.img          Android boot image, loaded by the stock ABL
#   0x080000  ext2 filesystem    /extlinux/extlinux.conf + kernel + dtb
#             ^ 512 KiB offset, so updating the kernel never overwrites lk2nd
#
# lk2nd reads the ext2 filesystem at that offset, picks the panel out of the
# vendor DT and boots the mainline kernel with the patched device tree.  The
# kernel then mounts the ext4 root filesystem from the userdata partition.
#
#   make-boot.sh <base-dir> <out-dir>
set -euo pipefail

BASE=${1:?usage: make-boot.sh <base-dir> <out-dir>}
OUT=${2:?usage: make-boot.sh <base-dir> <out-dir>}
BASE=$(readlink -m "$BASE")
OUT=$(readlink -m "$OUT")
mkdir -p "$OUT"

ROOTFS_UUID=${ROOTFS_UUID:-8f3a5c1e-1d2b-4a5f-9c3e-7b6d2a4f8e11}
KREL=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kernel_release"])' "$BASE/manifest.json")
DTB=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dtb"])' "$BASE/manifest.json")
OFFSET=$((512 * 1024))

# The kernel Image is ~30 MiB decompressed and lk2nd's extlinux loader has a
# hard 32 MiB kernel limit, so keep the gzip'd vmlinuz as-is (lk2nd unpacks it).
KERNEL_BYTES=$(stat -c %s "$BASE/vmlinuz")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

bootfs="$work/bootfs"
mkdir -p "$bootfs/extlinux"
cp "$BASE/vmlinuz" "$bootfs/vmlinuz"
cp "$BASE/device.dtb" "$bootfs/$DTB"
chmod -R a+rX "$bootfs"

cat > "$bootfs/extlinux/extlinux.conf" <<EOF
# lk2nd reads only these keywords; everything else is ignored.
timeout 1
default Debian13
label Debian13
    linux /vmlinuz
    fdt /$DTB
    append root=UUID=$ROOTFS_UUID rootwait rw console=ttyMSM0,115200n8 loglevel=7 lk2nd.pass-simplefb
EOF

# ext2 (not ext3/4): lk2nd's ext2 driver understands only the ext2 feature set.
# 24 MiB fits a 12 MiB kernel plus the dtb with room to spare; the Redmi S2
# boot partition is 64 MiB.
FS_BYTES=$((24 * 1024 * 1024))
rm -f "$work/bootfs.img"
truncate -s "$FS_BYTES" "$work/bootfs.img"
mkfs.ext2 -q -F -L boot -b 4096 -d "$bootfs" "$work/bootfs.img" 6144

# Two artifacts:
#   bootfs.img  the ext2 boot filesystem alone.  Flash it *from lk2nd's
#               fastboot* (`fastboot flash boot bootfs.img`): lk2nd writes the
#               next stage at its 512 KiB offset, so lk2nd itself survives.
#   boot.img    lk2nd + bootfs in one image, for a *stock* fastboot (the very
#               first install, when lk2nd is not on the phone yet).
cp "$work/bootfs.img" "$OUT/bootfs.img"
cp "$BASE/lk2nd.img" "$OUT/lk2nd.img"

total=$((OFFSET + FS_BYTES))
rm -f "$OUT/boot.img"
truncate -s "$total" "$OUT/boot.img"
dd if="$BASE/lk2nd.img" of="$OUT/boot.img" bs=4096 conv=notrunc status=none
dd if="$work/bootfs.img" of="$OUT/boot.img" bs=4096 seek=$((OFFSET / 4096)) conv=notrunc status=none

echo "==> bootfs.img    : $OUT/bootfs.img ($((FS_BYTES / 1024 / 1024)) MiB)"
echo "==> boot.img      : $OUT/boot.img ($((total / 1024 / 1024)) MiB, lk2nd + bootfs)"
echo "    lk2nd         : $(stat -c %s "$BASE/lk2nd.img") bytes"
echo "    kernel        : $((KERNEL_BYTES / 1024 / 1024)) MiB gzip ($KREL)"
echo "    dtb           : $DTB"
echo "    root uuid     : $ROOTFS_UUID"
