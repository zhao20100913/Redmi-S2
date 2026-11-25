#!/bin/bash
# Collect the one extra image the Redmi S2 needs: lk2nd.img.
#
#   make-boot.sh <base-dir> <out-dir>
#
# The boot chain is only two flashes:
#
#   boot     <- lk2nd.img          (secondary bootloader, stock ABL loads it)
#   userdata <- root.img           (Debian 13 + Denial, and the kernel inside
#                                   /boot + /extlinux/extlinux.conf)
#
# lk2nd starts, mounts the userdata filesystem, reads /extlinux/extlinux.conf
# and boots the kernel from it.  No recovery/system partition is involved --
# that is what makes a "failed to flash recovery" harmless on this port.
#
# lk2nd is what makes the display work: the mainline DTS only has a
# `compatible = "xiaomi,ysl-panel"` placeholder, and lk2nd replaces it with the
# real panel (ili9881c / h8394f / ili7807d) read out of the vendor DT the stock
# bootloader hands over.
set -euo pipefail

BASE=${1:?usage: make-boot.sh <base-dir> <out-dir>}
OUT=${2:?usage: make-boot.sh <base-dir> <out-dir>}
BASE=$(readlink -m "$BASE")
OUT=$(readlink -m "$OUT")
mkdir -p "$OUT"

KREL=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["kernel_release"])' "$BASE/manifest.json")
DTB=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["dtb"])' "$BASE/manifest.json")
cp "$BASE/lk2nd.img" "$OUT/lk2nd.img"

echo "==> lk2nd.img  : $OUT/lk2nd.img ($(stat -c %s "$OUT/lk2nd.img") bytes)"
echo "    kernel     : $(stat -c %s "$BASE/vmlinuz") bytes gzip ($KREL), goes inside root.img"
echo "    dtb        : $DTB, goes inside root.img"
