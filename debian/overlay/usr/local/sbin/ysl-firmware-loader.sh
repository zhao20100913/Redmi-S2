#!/bin/sh
# Copy firmware out of the Android partitions that MIUI left on the phone.
#
# Qualcomm firmware (WCNSS/WiFi, modem, ADSP, Venus) is not redistributable and
# is not shipped in the image on purpose: the phone already has it in its stock
# partitions.  This is the same idea as postmarketOS' msm-firmware-loader, only
# in a form that fits a Debian root with no initramfs.
#
# Nothing here is fatal.  If a partition is missing or encrypted the script
# logs it and moves on; the phone still boots (screen, touch, USB networking).
set -u

FW=/lib/firmware
LOG=/run/ysl-firmware-loader.log
: > "$LOG"

log() { echo "$*" | tee -a "$LOG"; }

for part in firmware vendor modem bluetooth dsp persist; do
	dev="/dev/disk/by-partlabel/$part"
	[ -e "$dev" ] || { log "skip $part: no partition label"; continue; }
	mnt="/run/android-$part"
	mkdir -p "$mnt"
	if ! mount -o ro "$dev" "$mnt" 2>>"$LOG"; then
		log "skip $part: mount failed (see log)"
		continue
	fi
	log "scanning $part"

	# firmware partition: /image/*.mbn + *.b0X
	[ -d "$mnt/image" ] && cp -an "$mnt/image/." "$FW/" 2>>"$LOG"
	# vendor: /firmware_mnt/image (when it is a directory, not a mountpoint)
	[ -d "$mnt/firmware_mnt/image" ] && cp -an "$mnt/firmware_mnt/image/." "$FW/" 2>>"$LOG"
	[ -d "$mnt/firmware" ] && cp -an "$mnt/firmware/." "$FW/" 2>>"$LOG"
	# WiFi calibration (WCNSS_qcom_wlan_nv.bin) and friends
	for d in "$mnt/etc/wifi" "$mnt/wifi" "$mnt"; do
		[ -d "$d" ] || continue
		find "$d" -maxdepth 1 -type f \( -name 'WCNSS*' -o -name '*wlan_nv*' -o -name '*.bin' \) \
			-exec cp -an {} "$FW/" \; 2>>"$LOG"
	done
	umount "$mnt" 2>/dev/null || true
done

# The GPU needs the per-device zap shader under qcom/msm8953/xiaomi/ysl/; the
# pmOS firmware package already provides it, this is only a sanity check.
[ -e "$FW/qcom/msm8953/xiaomi/ysl/a506_zap.mdt" ] || \
	log "warning: no ysl zap shader in $FW (GPU acceleration will be off)"

log "firmware files now in $FW: $(find "$FW" -type f | wc -l)"
exit 0
