#!/usr/bin/env bash
# Flash a Redmi S2 (ysl) with the Debian 13 + Denial bundle from a release.
#
#   tools/flash.sh first    lk2nd -> boot, bootfs -> recovery, root -> userdata
#   tools/flash.sh kernel   only bootfs -> recovery (keeps lk2nd and all data)
#   tools/flash.sh root     only root -> userdata (wipes data)
#   tools/flash.sh check    just look at the phone (fastboot getvar all)
#
# Put lk2nd.img, bootfs.img and root.img(.gz) in the current directory (or set
# IMAGE_DIR).  The phone must be in **fastboot**: power off, then hold
# Power + Volume Down until the FASTBOOT screen appears.
set -euo pipefail

ACTION=${1:-first}
IMAGE_DIR=${IMAGE_DIR:-.}
cd "$IMAGE_DIR"

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少 $1：apt install android-tools-fastboot" >&2; exit 1; }; }
need fastboot

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

check_device() {
	say "检查设备"
	local dev
	dev=$(fastboot devices 2>/dev/null | awk 'NF{print $1; exit}')
	if [ -z "$dev" ]; then
		cat >&2 <<'EOF'
没有发现 fastboot 设备。请确认：
  1. 手机已关机，按住 电源 + 音量下 开机，屏幕出现 FASTBOOT
  2. USB 线插在电脑上（尽量用 USB 2.0 口/原装线）
  3. Linux 下 `lsusb` 能看到 Qualcomm/Google 的设备
  4. 解锁过 BL（设置里 OEM 解锁 + fastboot oem unlock）
EOF
		exit 1
	fi
	echo "设备：$dev"
	fastboot getvar product 2>&1 | head -2 || true
}

flash_boot() {
	say "刷 lk2nd 到 BOOT 分区"
	fastboot flash boot lk2nd.img
}

# bootfs.img is just an ext2 filesystem, so any spare partition lk2nd scans
# will do.  Prefer recovery (64 MiB, spare); fall back to system when the
# phone has no recovery partition.
pick_bootfs_partition() {
	local vars
	vars=$(fastboot getvar all 2>&1 || true)
	if echo "$vars" | grep -q "partition-size:recovery:"; then
		echo recovery
	elif echo "$vars" | grep -q "partition-size:system:"; then
		echo system
	else
		echo recovery
	fi
}

flash_bootfs() {
	local part
	part=$(pick_bootfs_partition)
	say "刷 bootfs.img 到 ${part^^} 分区（内核 + 设备树，不动数据）"
	fastboot flash "$part" bootfs.img
}

flash_root() {
	local img=root.img
	if [ ! -f "$img" ]; then
		[ -f root.img.gz ] || { echo "找不到 root.img / root.img.gz" >&2; exit 1; }
		say "解压 root.img.gz（约 4 GiB）"
		gunzip -k root.img.gz
	fi
	say "刷 Debian 根文件系统到 USERDATA 分区（手机上原有数据会全部丢失）"
	read -r -p "确认继续？输入 yes： " ok
	[ "$ok" = "yes" ] || { echo "已取消"; exit 1; }
	fastboot flash userdata "$img"
}

case "$ACTION" in
	check)
		check_device
		fastboot getvar all 2>&1 | grep -Ev '^(fastboot: )?(Finished|OKAY)' | head -60 || true
		;;
	first)
		check_device
		flash_boot
		flash_bootfs
		flash_root
		say "完成，重启"
		fastboot reboot
		;;
	kernel)
		check_device
		flash_bootfs
		fastboot reboot
		;;
	root)
		check_device
		flash_root
		fastboot reboot
		;;
	*)
		sed -n '2,12p' "$0"
		exit 1
		;;
esac
