#!/usr/bin/env python3
"""Structural checks for the two images we publish.

Nothing here needs a device: it parses the boot partition composite (lk2nd +
ext2 boot filesystem), the ext4 root image (superblock + files through
debugfs), and fails loudly when the pieces the phone needs are missing.
"""

import json
import os
import re
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
    boot = sys.argv[1] if len(sys.argv) > 1 else "out/boot.img"
    root = sys.argv[2] if len(sys.argv) > 2 else "out/root.img"
    uuid = open(root + ".uuid").read().strip() if os.path.exists(root + ".uuid") else None

    # ---------------------------------------------------------------- boot.img
    data = open(boot, "rb").read(2 * 1024 * 1024)
    check("boot.img exists", os.path.exists(boot), f"{os.path.getsize(boot)} bytes")
    check("lk2nd android header at 0", data[:8] == b"ANDROID!", data[:8].hex())

    off = 512 * 1024
    sb = data[off + 1024: off + 1024 + 1024]
    magic = struct.unpack("<H", sb[56:58])[0] if len(sb) >= 58 else 0
    check("ext2 boot filesystem at 512 KiB", magic == 0xEF53, f"magic {magic:#x}")
    check("boot partition image fits 64 MiB", os.path.getsize(boot) < 64 * 1024 * 1024,
          f"{os.path.getsize(boot) / 1048576:.1f} MiB")

    # read the filesystem through debugfs on an extracted copy
    tmp = "/tmp/bootfs.img"
    with open(boot, "rb") as src, open(tmp, "wb") as dst:
        src.seek(off)
        dst.write(src.read(24 * 1024 * 1024))
    conf = run(["debugfs", "-R", "cat /extlinux/extlinux.conf", tmp]).stdout
    check("extlinux.conf readable", "linux /vmlinuz" in conf)
    if uuid:
        check("cmdline carries the root UUID", f"root=UUID={uuid}" in conf,
              conf.strip().splitlines()[-1][:90] if conf.strip() else "empty")
    listing = run(["debugfs", "-R", "ls -l /", tmp]).stdout
    check("kernel in boot fs", "vmlinuz" in listing)
    dtb_line = [l for l in listing.splitlines() if "msm8953-xiaomi-ysl.dtb" in l]
    check("device dtb in boot fs", bool(dtb_line))
    # lk2nd decompresses the kernel into a 32 MiB buffer; the gzip'd file is
    # small but the Image inside must fit, so keep the manifest's size check.

    # ----------------------------------------------------------------- root.img
    check("root.img exists", os.path.exists(root), f"{os.path.getsize(root)} bytes")
    dumpe2fs = run(["dumpe2fs", "-h", root]).stdout
    got_uuid = None
    for line in dumpe2fs.splitlines():
        if line.startswith("Filesystem UUID:"):
            got_uuid = line.split(":", 1)[1].strip()
    check("root filesystem UUID matches boot cmdline", got_uuid == uuid, str(got_uuid))
    check("root filesystem is ext4", "ext4" in dumpe2fs.lower())

    def ls(path):
        return run(["debugfs", "-R", f"ls -l {path}", root]).stdout

    def cat(path):
        return run(["debugfs", "-R", f"cat {path}", root]).stdout

    root_list = ls("/")
    for entry in ("etc", "usr", "lib", "home", "var"):
        check(f"/{entry} present", entry in root_list)

    osrel = cat("/etc/debian_version")
    check("Debian 13 (trixie)", "13" in osrel or "trixie" in osrel, osrel.strip())

    check("/usr/bin/denial-session installed", "denial-session" in ls("/usr/bin"))
    check("/usr/local/bin/ysl-start-denial", "ysl-start-denial" in ls("/usr/local/bin"))
    check("/usr/local/sbin/ysl-usb-gadget.sh", "ysl-usb-gadget.sh" in ls("/usr/local/sbin"))
    check("sshd drop-in", "10-redmi-s2.conf" in ls("/etc/ssh/sshd_config.d"))

    krel = cat("/etc/redmi-s2-kernel-release").strip()
    check("kernel release recorded", bool(krel), krel)
    if krel:
        mods = ls(f"/lib/modules/{krel}")
        check("kernel modules installed", "kernel" in mods or len(mods.splitlines()) > 5,
              krel)
        check("modules.dep generated", "modules.dep" in ls(f"/lib/modules/{krel}"))
    fw = ls("/lib/firmware/qcom")
    check("adreno firmware", "a530_pfp.fw" in fw or "msm8953" in fw)
    check("ysl zap shader", "ysl" in ls("/lib/firmware/qcom/msm8953/xiaomi"))

    if FAIL:
        print(f"\n{len(FAIL)} check(s) failed: {', '.join(FAIL)}")
        return 1
    print("\nall checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
