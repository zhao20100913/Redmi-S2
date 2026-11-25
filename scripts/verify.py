#!/usr/bin/env python3
"""Structural checks for the images we publish.

Nothing here needs a phone: it parses lk2nd.img (Android boot image containing
the msm8953 device database), the ext2 boot filesystem that goes to the
recovery partition, and the ext4 root image (superblock + files via debugfs).
"""

import json
import os
import struct
import subprocess
import sys

FAIL = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name}{('  -- ' + detail) if detail else ''}")
    if not ok:
        FAIL.append(name)


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def main():
    lk2nd = sys.argv[1] if len(sys.argv) > 1 else "out/lk2nd.img"
    root = sys.argv[2] if len(sys.argv) > 2 else "out/root.img"
    uuid = open(root + ".uuid").read().strip() if os.path.exists(root + ".uuid") else None

    # --------------------------------------------------------------- lk2nd.img
    blob = open(lk2nd, "rb").read()
    check("lk2nd.img exists", os.path.exists(lk2nd), f"{len(blob)} bytes")
    check("lk2nd is an Android boot image", blob[:8] == b"ANDROID!", blob[:8].hex())
    check("lk2nd fits a boot partition", len(blob) < 16 * 1024 * 1024,
          f"{len(blob) / 1048576:.1f} MiB")
    check("lk2nd knows the Redmi S2 device tree", b"Xiaomi Redmi S2" in blob)
    check("lk2nd knows the ysl panels", b"xiaomi,ysl-ili9881c" in blob)

    # ----------------------------------------------------------------- root.img
    # The root filesystem is what lk2nd mounts to find /extlinux/extlinux.conf,
    # so it must stay within the feature set the tiny lk2nd ext2 driver accepts.
    exists = os.path.exists(root)
    check("root.img exists", exists, f"{os.path.getsize(root)} bytes" if exists else "missing")
    if not exists:
        print("\ncannot check the root filesystem without it")
        return 1
    with open(root, "rb") as fh:
        fh.seek(1024)
        sb = fh.read(256)
    incompat = struct.unpack("<I", sb[0x60:0x64])[0]
    ro_compat = struct.unpack("<I", sb[0x64:0x68])[0]
    check("root is ext2/3-style (no extents, no 64bit, no metadata_csum)",
          (incompat & ~0x12) == 0 and (ro_compat & ~0x3) == 0,
          f"incompat={incompat:#x} ro={ro_compat:#x}")

    dumpe2fs = run(["dumpe2fs", "-h", root]).stdout
    got_uuid = None
    for line in dumpe2fs.splitlines():
        if line.startswith("Filesystem UUID:"):
            got_uuid = line.split(":", 1)[1].strip()
    check("root UUID matches boot cmdline", got_uuid == uuid, str(got_uuid))
    features = " ".join(l for l in dumpe2fs.splitlines() if l.startswith("Filesystem features:"))
    check("root filesystem has a journal", "has_journal" in features,
          features.replace("Filesystem features:", "").strip()[:80])

    def ls(path):
        return run(["debugfs", "-R", f"ls -l {path}", root]).stdout

    def cat(path):
        return run(["debugfs", "-R", f"cat {path}", root]).stdout

    entries = ls("/")
    for entry in ("etc", "usr", "lib", "home", "var"):
        check(f"/{entry} present", entry in entries)

    osrel = cat("/etc/debian_version")
    check("Debian 13 (trixie)", "13" in osrel or "trixie" in osrel, osrel.strip())
    check("/usr/bin/denial-session installed", "denial-session" in ls("/usr/bin"))
    check("mobile shell profile for Denial", "mobile" in cat("/etc/denial/session.conf"))
    check("/usr/local/bin/ysl-start-denial", "ysl-start-denial" in ls("/usr/local/bin"))
    check("/usr/local/sbin/ysl-usb-gadget.sh", "ysl-usb-gadget.sh" in ls("/usr/local/sbin"))
    check("sshd drop-in", "10-redmi-s2.conf" in ls("/etc/ssh/sshd_config.d"))

    conf = cat("/extlinux/extlinux.conf")
    check("extlinux.conf inside the rootfs", "linux /boot/vmlinuz" in conf)
    if uuid:
        check("cmdline carries the root UUID", f"root=UUID={uuid}" in conf,
              conf.strip().splitlines()[-1][:90] if conf.strip() else "empty")
    check("kernel inside the rootfs", "vmlinuz" in ls("/boot"))
    check("device dtb inside the rootfs", "msm8953-xiaomi-ysl.dtb" in ls("/boot"))

    krel = cat("/etc/redmi-s2-kernel-release").strip()
    check("kernel release recorded", bool(krel), krel)
    if krel:
        check("kernel modules installed", "kernel" in ls(f"/lib/modules/{krel}") or
              len(ls(f"/lib/modules/{krel}").splitlines()) > 5, krel)
        check("modules.dep generated", "modules.dep" in ls(f"/lib/modules/{krel}"))
    check("adreno firmware", "a530_pfp.fw" in ls("/lib/firmware/qcom") or
          "msm8953" in ls("/lib/firmware/qcom"))
    check("ysl zap shader", "ysl" in ls("/lib/firmware/qcom/msm8953/xiaomi"))

    if FAIL:
        print(f"\n{len(FAIL)} check(s) failed: {', '.join(FAIL)}")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
