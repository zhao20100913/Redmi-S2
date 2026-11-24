#!/bin/sh
# Bring up the USB gadget: RNDIS (network) + ACM (serial console).
#
# The kernel mounts the root filesystem directly, so unlike the pmOS ports
# there is no initramfs setting up a gadget for us.  Without this the phone
# has no network at all on a fresh install (WiFi firmware comes from the
# Android partitions and may not be there yet), and no serial console either.
#
# Host side: the phone is 172.16.42.1/24, the host gets 172.16.42.20-30 by
# DHCP (ysl-usb-dhcpd.service), so `ssh ysl@172.16.42.1` just works.
set -eu

CFG=/sys/kernel/config/usb_gadget/g1
UDC_DIR=/sys/class/udc

modprobe libcomposite 2>/dev/null || true
[ -d /sys/kernel/config/usb_gadget ] || { echo "no configfs usb_gadget"; exit 0; }
[ -d "$UDC_DIR" ] || { echo "no UDC"; exit 0; }

if [ -d "$CFG" ] && [ -n "$(cat "$CFG/UDC" 2>/dev/null || true)" ]; then
	echo "gadget already bound to $(cat "$CFG/UDC")"
	exit 0
fi

mkdir -p "$CFG"
cd "$CFG"

echo 0x18d1 > idVendor          # Google
echo 0xd001 > idProduct         # generic "phone as network+serial"
echo 0x0100 > bcdDevice
echo 0x0200 > bcdUSB

mkdir -p strings/0x409
printf 'redmi-s2-debian13\n' > strings/0x409/serialnumber
printf 'Xiaomi\n' > strings/0x409/manufacturer
printf 'Redmi S2 (Debian 13 + Denial)\n' > strings/0x409/product

mkdir -p configs/c.1/strings/0x409
printf 'RNDIS + ACM\n' > configs/c.1/strings/0x409/configuration
echo 250 > configs/c.1/MaxPower

mkdir -p functions/rndis.usb0
mkdir -p functions/acm.usb0
ln -sf functions/rndis.usb0 configs/c.1/rndis.usb0
ln -sf functions/acm.usb0 configs/c.1/acm.usb0

# RNDIS wants a locally administered MAC
printf '%s\n' '02:1a:7d:da:71:13' > functions/rndis.usb0/dev_addr
printf '%s\n' '02:1a:7d:da:71:14' > functions/rndis.usb0/host_addr

UDC=$(ls "$UDC_DIR" | head -1)
[ -n "$UDC" ] || { echo "no UDC name"; exit 0; }
echo "$UDC" > UDC
echo "bound gadget to $UDC"
sleep 1
ip link show usb0 >/dev/null 2>&1 || echo "warning: usb0 did not appear"
exit 0
