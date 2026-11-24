#!/bin/bash
# Build the Debian 13 (trixie) arm64 root filesystem for the Redmi S2 (ysl).
#
# The boot chain is deliberately boring: the kernel from
# linux-postmarketos-qcom-msm8953 mounts this ext4 image directly
# (root=UUID=...), so there is no initramfs and no pmOS user space anywhere.
# Everything in here is Debian: debootstrap, apt, systemd, DenialWM.
#
#   build-rootfs.sh <rootdir> <base-dir>
#
# <base-dir> is the directory produced by scripts/fetch-base.py (kernel
# modules, firmware, lk2nd.img, device.dtb).
set -euo pipefail

ROOT=${1:?usage: build-rootfs.sh <rootdir> <base-dir>}
BASE=${2:?usage: build-rootfs.sh <rootdir> <base-dir>}
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)

ROOT=$(readlink -m "$ROOT")
BASE=$(readlink -m "$BASE")
MIRROR=${MIRROR:-http://deb.debian.org/debian}
RELEASE=${RELEASE:-trixie}
USERNAME=${USERNAME:-ysl}
PASSWORD=${PASSWORD:-147147}
HOSTNAME=${HOSTNAME:-redmi-s2}
DENIAL_VERSION=${DENIAL_VERSION:-0.6.8}
ROOTFS_UUID=${ROOTFS_UUID:-8f3a5c1e-1d2b-4a5f-9c3e-7b6d2a4f8e11}
QEMU=${QEMU:-/usr/bin/qemu-aarch64-static}

log() { printf '\n==> %s\n' "$*"; }

[ -x "$QEMU" ] || { echo "$QEMU not found (apt install qemu-user-static)" >&2; exit 1; }

# binfmt_misc is what makes dpkg maintainer scripts run; qemu alone only runs
# the first process.  Fail early with a clear message instead of a mystery
# "Exec format error" halfway through the install.
BINFMT=1
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
	BINFMT=0
	echo "warning: binfmt_misc has no qemu-aarch64 entry; only the first" >&2
	echo "         process of every chroot call will run.  Install" >&2
	echo "         qemu-user-static + binfmt-support and run" >&2
	echo "         'update-binfmts --enable qemu-aarch64'." >&2
fi

cleanup() {
	for d in dev/pts dev/shm dev proc sys; do
		mountpoint -q "$ROOT/$d" && umount -R "$ROOT/$d" || true
	done
}
trap cleanup EXIT

# ---------------------------------------------------------------- debootstrap
log "debootstrap $RELEASE arm64 from $MIRROR"
if [ -f "$ROOT/etc/debian_version" ] && [ "${FRESH:-0}" != 1 ]; then
	log "reusing the existing root filesystem in $ROOT"
else
	rm -rf "$ROOT"
	mkdir -p "$ROOT"
	for attempt in 1 2 3; do
		if debootstrap --arch=arm64 --variant=minbase \
			--components=main,non-free-firmware \
			--include=ca-certificates,apt-utils,gnupg \
			"$RELEASE" "$ROOT" "$MIRROR"; then
			break
		fi
		echo "debootstrap attempt $attempt failed, retrying in $((attempt * 10))s"
		sleep $((attempt * 10))
	done
	[ -f "$ROOT/etc/debian_version" ] || { echo "debootstrap failed" >&2; exit 1; }
fi

cat > "$ROOT/etc/apt/sources.list" <<EOF
deb $MIRROR $RELEASE main contrib non-free-firmware
deb $MIRROR $RELEASE-updates main contrib non-free-firmware
deb $MIRROR $RELEASE-security main contrib non-free-firmware
EOF
# trixie images use the deb822 format; keep both in sync so that apt is happy
mkdir -p "$ROOT/etc/apt/sources.list.d"
cat > "$ROOT/etc/apt/sources.list.d/debian.sources" <<EOF
Types: deb
URIs: $MIRROR
Suites: $RELEASE $RELEASE-updates $RELEASE-security
Components: main contrib non-free-firmware
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF

cp "$QEMU" "$ROOT/usr/bin/qemu-aarch64-static"
chmod 0755 "$ROOT/usr/bin/qemu-aarch64-static"

# -------------------------------------------------------------------- chroot
mount --bind /dev "$ROOT/dev"
mount -t devpts devpts "$ROOT/dev/pts"
mount -t tmpfs tmpfs "$ROOT/dev/shm"
mount -t proc proc "$ROOT/proc"
mount -t sysfs sysfs "$ROOT/sys"

in_root() {
	if [ "$BINFMT" = 1 ]; then
		chroot "$ROOT" env -i \
			PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
			HOME=/root TERM=dumb DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 \
			SYSTEMD_OFFLINE=1 "$@"
	else
		chroot "$ROOT" /usr/bin/qemu-aarch64-static env -i \
			PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
			HOME=/root TERM=dumb DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 \
			SYSTEMD_OFFLINE=1 "$@"
	fi
}

# ---------------------------------------------------------------- packages
log "apt-get update"
in_root apt-get update

mapfile -t WANTED < <(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' -e 's/[[:space:]]//g' "$HERE/packages.txt")
INSTALL=()
MISSING=()
for pkg in "${WANTED[@]}"; do
	if in_root apt-cache show "$pkg" >/dev/null 2>&1; then
		INSTALL+=("$pkg")
	else
		MISSING+=("$pkg")
	fi
done
printf '   %d packages to install\n' "${#INSTALL[@]}"
if [ ${#MISSING[@]} -gt 0 ]; then
	log "warning: not available in $RELEASE: ${MISSING[*]}"
fi
log "installing packages (this is the slow part)"
in_root apt-get install -y --no-install-recommends "${INSTALL[@]}"

# -------------------------------------------------------------- DenialWM
log "installing DenialWM $DENIAL_VERSION (arm64 debs from GitHub releases)"
mkdir -p "$ROOT/tmp/denial"
for deb in denial_${DENIAL_VERSION}-1_arm64.deb \
	   denial-flutter-engine_${DENIAL_VERSION}-1_arm64.deb; do
	curl -fL --retry 3 --retry-delay 5 \
		-o "$ROOT/tmp/denial/$deb" \
		"https://github.com/denialwm/denial/releases/download/v$DENIAL_VERSION/$deb"
done
chmod 0644 "$ROOT/tmp/denial/"*.deb

# Denial pulls xserver-xorg-core (for Xwayland) etc. through apt; let apt do
# the dependency resolution so a trixie version bump does not break the build.
# Inside the chroot the downloads are at /tmp/denial/... (the $ROOT prefix
# only exists on the host side).
in_root apt-get install -y \
	"/tmp/denial/denial-flutter-engine_${DENIAL_VERSION}-1_arm64.deb" \
	"/tmp/denial/denial_${DENIAL_VERSION}-1_arm64.deb"
rm -rf "$ROOT/tmp/denial"

# Keep the image small: no documentation, no apt cache, no man pages.
in_root apt-get clean
rm -rf "$ROOT/var/lib/apt/lists"/* "$ROOT/var/cache/apt/archives"/*.deb
rm -rf "$ROOT/usr/share/doc"/* "$ROOT/usr/share/man"/* "$ROOT/usr/share/info"/*

# -------------------------------------------------------------- locales/time
log "locales + timezone"
cat > "$ROOT/etc/locale.gen" <<EOF
en_US.UTF-8 UTF-8
zh_CN.UTF-8 UTF-8
EOF
in_root locale-gen
cat > "$ROOT/etc/default/locale" <<EOF
LANG=zh_CN.UTF-8
LANGUAGE=zh_CN:zh:en_US:en
EOF
ln -sf /usr/share/zoneinfo/Asia/Shanghai "$ROOT/etc/localtime"
printf 'Asia/Shanghai\n' > "$ROOT/etc/timezone"
in_root dpkg-reconfigure -f noninteractive tzdata || true
printf '%s\n' "$HOSTNAME" > "$ROOT/etc/hostname"
cat > "$ROOT/etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	$HOSTNAME
::1		localhost ip6-localhost ip6-loopback
EOF

# --------------------------------------------------------------------- user
log "creating user $USERNAME"
for grp in sudo adm video audio input plugdev netdev dialout render gpio i2c; do
	in_root groupadd -f "$grp" 2>/dev/null || true
done
if ! in_root id -u "$USERNAME" >/dev/null 2>&1; then
	in_root useradd -m -s /bin/bash -G sudo,adm,video,audio,input,plugdev,netdev,dialout,render \
		"$USERNAME"
fi
printf '%s:%s\n' "$USERNAME" "$PASSWORD" | in_root chpasswd
in_root usermod -aG render "$USERNAME" 2>/dev/null || true
in_root passwd -l root || true
cat > "$ROOT/etc/sudoers.d/90-$USERNAME" <<EOF
$USERNAME ALL=(ALL) NOPASSWD: ALL
EOF
chmod 0440 "$ROOT/etc/sudoers.d/90-$USERNAME"

# ------------------------------------------------------------------- overlay
log "installing overlay"
cp -a "$HERE/overlay/." "$ROOT"/
# Resolve the user inside the chroot so the numeric ids match.
UID_=$(in_root id -u "$USERNAME")
GID_=$(in_root id -g "$USERNAME")
chown -R "$UID_:$GID_" "$ROOT/home/$USERNAME"
chmod 0755 "$ROOT/usr/local/bin/ysl-start-denial" \
	"$ROOT/usr/local/sbin/ysl-usb-gadget.sh" \
	"$ROOT/usr/local/sbin/ysl-firmware-loader.sh" \
	"$ROOT/usr/local/sbin/ysl-grow-rootfs.sh" 2>/dev/null || true
chmod 0600 "$ROOT/etc/NetworkManager/system-connections/usb0.nmconnection"
# The kernel cmdline carries the root UUID; keep it readable from user space too.
printf '%s\n' "$ROOTFS_UUID" > "$ROOT/etc/redmi-s2-root-uuid"

# ---------------------------------------------------- kernel modules/firmware
log "installing kernel modules and firmware from $BASE"
KREL=$(cat "$BASE/manifest.json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["kernel_release"])')
[ -n "$KREL" ] || { echo "no kernel release in $BASE/manifest.json" >&2; exit 1; }
mkdir -p "$ROOT/lib/modules"
cp -a "$BASE/modules/$KREL" "$ROOT/lib/modules/"
mkdir -p "$ROOT/lib/firmware"
cp -a "$BASE/firmware/." "$ROOT/lib/firmware/"
# depmod the host tool works on any target module tree
depmod -b "$ROOT" "$KREL"
printf '%s\n' "$KREL" > "$ROOT/etc/redmi-s2-kernel-release"

# ------------------------------------------------------------------ services
log "enabling services"
for unit in \
	ssh.service \
	NetworkManager.service \
	bluetooth.service \
	systemd-timesyncd.service \
	ysl-usb-gadget.service \
	ysl-usb-dhcpd.service \
	ysl-firmware-loader.service \
	ysl-grow-rootfs.service \
	ysl-wifi.service \
	getty@tty1.service \
	serial-getty@ttyMSM0.service \
	serial-getty@ttyGS0.service \
	; do
	if in_root systemctl enable "$unit" >/dev/null 2>&1; then
		echo "  enabled $unit"
	else
		echo "  warning: could not enable $unit"
	fi
done

# ------------------------------------------------------------------- cleanup
log "cleaning up"
rm -f "$ROOT/usr/bin/qemu-aarch64-static"
rm -f "$ROOT"/etc/ssh/ssh_host_*
: > "$ROOT/etc/machine-id"
rm -rf "$ROOT/var/tmp"/* "$ROOT/var/log"/* 2>/dev/null || true
rm -rf "$ROOT/tmp"/* 2>/dev/null || true
find "$ROOT/var/log" -type f -exec truncate -s 0 {} + 2>/dev/null || true

log "root fs size: $(du -sh --apparent-size "$ROOT" | cut -f1)"
log "done"
