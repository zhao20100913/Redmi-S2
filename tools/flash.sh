#!/usr/bin/env bash
# Flash a Redmi S2 (ysl) with the Debian 13 + Denial bundle from a release.
#
#   tools/flash.sh first    lk2nd -> boot, root -> userdata   (整机安装)
#   tools/flash.sh root     only root -> userdata             (重装系统，数据全丢)
#   tools/flash.sh kernel   把新内核推到手机里（不动 fastboot 分区）
#   tools/flash.sh check    只看手机（fastboot getvar all）
#
# 只需要 lk2nd.img 和 root.img(.gz) 两个文件——内核和设备树在 root.img 里面，
# 不占 recovery/system 分区。
#
# 手机要先进 **fastboot**：关机，按住 电源 + 音量下，直到屏幕出现 FASTBOOT。
set -euo pipefail

ACTION=${1:-first}
IMAGE_DIR=${IMAGE_DIR:-.}
cd "$IMAGE_DIR"

need() { command -v "$1" >/dev/null 2>&1 || { echo "缺少 $1：apt install android-tools-fastboot" >&2; exit 1; }; }

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }

check_device() {
	need fastboot
	say "检查设备"
	local dev
	dev=$(fastboot devices 2>/dev/null | awk 'NF{print $1; exit}')
	if [ -z "$dev" ]; then
		cat >&2 <<'EOF'
没有发现 fastboot 设备。请确认：
  1. 手机已关机，按住 电源 + 音量下 开机，屏幕出现 FASTBOOT
  2. USB 线插在电脑上（尽量用 USB 2.0 口/原装线）
  3. Linux 下 `lsusb` 能看到 Qualcomm/Google 设备
  4. BL 已解锁（设置里 OEM 解锁 + fastboot oem unlock）
EOF
		exit 1
	fi
	echo "设备：$dev"
}

flash_boot() {
	say "刷 lk2nd 到 BOOT 分区"
	fastboot flash boot lk2nd.img
}

flash_root() {
	local img=root.img
	if [ ! -f "$img" ]; then
		[ -f root.img.gz ] || { echo "找不到 root.img / root.img.gz" >&2; exit 1; }
		say "解压 root.img.gz（约 4 GiB）"
		gunzip -k root.img.gz
	fi
	say "刷 Debian 到 USERDATA 分区（手机上原有数据会全部丢失）"
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
		flash_root
		say "完成，重启"
		fastboot reboot
		;;
	root)
		check_device
		flash_root
		fastboot reboot
		;;
	kernel)
		cat <<'EOF'
内核不占独立分区，它就在手机的 /boot 里（还有 /extlinux/extlinux.conf）：

  scp vmlinuz root@172.16.42.1:/boot/vmlinuz
  scp msm8953-xiaomi-ysl.dtb root@172.16.42.1:/boot/
  ssh root@172.16.42.1 reboot

（Debian 里是普通文件，替换完重启就生效，lk2nd 每次开机都会重新读。）
重刷整个系统用：tools/flash.sh root
EOF
		;;
	*)
		sed -n '2,12p' "$0"
		exit 1
		;;
esac
