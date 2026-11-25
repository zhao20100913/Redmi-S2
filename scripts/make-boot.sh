#!/bin/bash
# Build the two small images the Redmi S2 needs besides the root filesystem.
#
#   make-boot.sh <base-dir> <out-dir>
#
#   lk2nd.img    the secondary bootloader.  Goes to the **boot** partition and
#                is what the stock ABL loads.  Upstream lk2nd already knows
#                this phone (`msm8953-xiaomi-ysl`): it reads the vendor DT the
#                bootloader hands over, picks the real panel (ili9881c /
#                h8394f / ili7807d) and patches the kernel DT - without that
#                the mainline kernel has no display at all.
#
#   bootfs.img   a 24 MiB **ext2** filesystem holding extlinux.conf, the
#                kernel and the device tree.  Goes to the *recovery* partition.
#
# Why the recovery partition: lk2nd, after starting, scans every partition
# bigger than 16 MiB for /extlinux/extlinux.conf and boots it.  It cannot read
# ext4-with-extents, so the Debian root filesystem (userdata) is not usable for
# that, and the boot partition is occupied by lk2nd itself.  recovery is a
# spare 64 MiB partition on this phone, ext2 is exactly what lk2nd's tiny
# filesystem driver understands, and updating the kernel later is one
# `fastboot flash recovery bootfs.img` that never touches lk2nd or the data.
set -euo pipefail

BASE=${1:?usage: make-boot.sh <base-dir> <out-dir>}
OUT=${2:?usage: make-boot.sh <base-dir> <out-dir>}
BASE=$(readlink -m "$BASE")
OUT=$(readlink -m "$OUT")
mkdir -p "$OUT"

ROOTFS_UUID=${ROOTFS_UUID:-8f3a5c1e-1d2b-4a5f-9c3e-7b6d2a4f8e11}
KREL=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kernel_release"])' "$BASE/manifest.json")
DTB=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dtb"])' "$BASE/manifest.json")

# The kernel Image is ~30 MiB decompressed and lk2nd's extlinux loader has a
# hard 32 MiB buffer, so keep the gzip'd vmlinuz as-is (lk2nd unpacks it).
KERNEL_BYTES=$(stat -c %s "$BASE/vmlinuz")

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

bootfs="$work/bootfs"
mkdir -p "$bootfs/extlinux"
cp "$BASE/vmlinuz" "$bootfs/vmlinuz"
cp "$BASE/device.dtb" "$bootfs/$DTB"
chmod -R a+rX "$bootfs"

cat > "$bootfs/extlinux/extlinux.conf" <<EOF
# lk2nd reads only linux/fdt/initrd/append; everything else is ignored.
timeout 1
default Debian13
label Debian13
    linux /vmlinuz
    fdt /$DTB
    append root=UUID=$ROOTFS_UUID rootwait rw console=ttyMSM0,115200n8 loglevel=7
EOF

# ext2 (not ext4): lk2nd's filesystem driver only understands ext2.
FS_BYTES=$((24 * 1024 * 1024))
rm -f "$OUT/bootfs.img"
truncate -s "$FS_BYTES" "$OUT/bootfs.img"
mkfs.ext2 -q -F -L bootfs -b 4096 -d "$bootfs" "$OUT/bootfs.img" 6144

cp "$BASE/lk2nd.img" "$OUT/lk2nd.img"

echo "==> lk2nd.img  : $OUT/lk2nd.img ($(stat -c %s "$OUT/lk2nd.img") bytes)"
echo "==> bootfs.img : $OUT/bootfs.img ($((FS_BYTES / 1024 / 1024)) MiB ext2)"
echo "    kernel     : $((KERNEL_BYTES / 1024 / 1024)) MiB gzip ($KREL)"
echo "    dtb        : $DTB"
echo "    cmdline    : root=UUID=$ROOTFS_UUID"
