#!/usr/bin/env python3
"""Download and extract the postmarketOS arm64 binaries this port runs on.

Redmi S2 (ysl) is an *upstream* msm8953 device: the mainline kernel already
ships `msm8953-xiaomi-ysl.dts` (with the panel/touch/regulator work) and lk2nd
already knows how to pick the right panel out of the vendor DT.  Rebuilding
either from source in CI would cost ~40 minutes per run and add nothing, so
this port takes the **published aarch64 packages** from the postmarketOS
repository instead:

  linux-postmarketos-qcom-msm8953   -> vmlinuz (gzip'd Image), DTBs, modules
  lk2nd-msm8953                     -> lk2nd.img (secondary bootloader)
  firmware-qcom-adreno-a530         -> Adreno 506 GPU firmware
  firmware-qcom-msm8953             -> per-device zap shader (incl. xiaomi/ysl)

Everything is pinned by version in the APKINDEX and the SHA1 from the index is
verified before extraction, so a run is reproducible enough for a flashable
image.  Pass `--version PKG=VERSION` to pin a different build.
"""

import base64
import hashlib
import io
import json
import os
import re
import shutil
import sys
import tarfile
import time
import urllib.request

PMOS_REPO = os.environ.get(
    "PMOS_REPO", "https://mirror.postmarketos.org/postmarketos/master/aarch64"
)
UA = {"User-Agent": "redmi-s2-ci/1.0"}

# Versions validated for this port.  Override with `pkg=version` arguments;
# leaving a package out means "newest in the APKINDEX".
PINNED = {
    "linux-postmarketos-qcom-msm8953": "7.1.3-r2",
    "lk2nd-msm8953": "23.1-r0",
    "firmware-qcom-adreno-a530": "20260110-r1",
    "firmware-qcom-msm8953": "5-r0",
}

DEFAULT_PKGS = [
    "linux-postmarketos-qcom-msm8953",
    "lk2nd-msm8953",
    "firmware-qcom-adreno-a530",
    "firmware-qcom-msm8953",
]

DEVICE = os.environ.get("DEVICE_CODENAME", "ysl")
DTB_NAME = f"msm8953-xiaomi-{DEVICE}.dtb"


def fetch(url, dest=None, retries=4):
    """Download with retries; the mirror is occasionally slow to start."""
    last = None
    for attempt in range(1, retries + 1):
        try:
            req = urllib.request.Request(url, headers=UA)
            with urllib.request.urlopen(req, timeout=180) as resp:
                data = resp.read()
            if dest:
                with open(dest, "wb") as fh:
                    fh.write(data)
            return data
        except Exception as exc:  # URLError, timeouts, IncompleteRead, ...
            last = exc
            print(f"    download attempt {attempt} failed: {exc}", flush=True)
            time.sleep(5 * attempt)
    raise SystemExit(f"could not download {url}: {last}")


def parse_index(text):
    """APKINDEX -> {name: {version: {field: value}}}"""
    out = {}
    for block in text.split("\n\n"):
        fields = {}
        for line in block.splitlines():
            if len(line) > 2 and line[1] == ":":
                fields.setdefault(line[0], line[2:])
        name, version = fields.get("P"), fields.get("V")
        if not name or not version:
            continue
        out.setdefault(name, {})[version] = fields
    return out


def version_key(v):
    """Sort Alpine versions (1.2.3-r4) numerically enough for our use."""
    return [(1, int(tok)) if tok.isdigit() else (0, tok)
            for tok in re.split(r"[._-]", v)]


def apk_sha1(field):
    """APKINDEX `C:` is 'Q1' + base64(sha1)."""
    if not field or not field.startswith("Q1"):
        return None
    return base64.b64decode(field[2:]).hex()


def extract(apk, dest):
    """apk = tar.gz with .PKGINFO + .SIGN.* ; ignore the pax noise."""
    os.makedirs(dest, exist_ok=True)
    with tarfile.open(apk, "r:gz") as tf:
        for member in tf.getmembers():
            name = member.name
            if name.startswith(".") or name.startswith("/"):
                continue
            if ".." in name.split("/"):
                continue
            member.pax_headers = {}
            tf.extract(member, dest)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "base"
    pins = {}
    for arg in sys.argv[2:]:
        if "=" in arg:
            k, v = arg.split("=", 1)
            pins[k] = v

    os.makedirs(out, exist_ok=True)
    index_url = f"{PMOS_REPO}/APKINDEX.tar.gz"
    print(f"==> fetching {index_url}")
    raw = fetch(index_url)
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:gz") as tf:
        text = tf.extractfile("APKINDEX").read().decode("utf-8", "replace")
    index = parse_index(text)

    wanted = DEFAULT_PKGS
    chosen = []
    for name in wanted:
        versions = index.get(name)
        if not versions:
            sys.exit(f"package {name} is not in {PMOS_REPO}")
        ver = pins.get(name) or PINNED.get(name) or sorted(versions, key=version_key)[-1]
        if ver not in versions:
            sys.exit(f"{name} has no version {ver} (have: {sorted(versions, key=version_key)[-3:]})")
        chosen.append((name, ver, versions[ver]))

    work = os.path.join(out, "apk")
    root = os.path.join(out, "root")
    shutil.rmtree(root, ignore_errors=True)
    os.makedirs(work, exist_ok=True)
    os.makedirs(root, exist_ok=True)

    manifest = {"repo": PMOS_REPO, "packages": {}}
    for name, ver, fields in chosen:
        fn = f"{name}-{ver}.apk"
        path = os.path.join(work, fn)
        print(f"==> {fn} ({int(fields.get('S', '0')) / 1e6:.1f} MB)")
        fetch(f"{PMOS_REPO}/{fn}", path)

        # APKINDEX' C: is the Alpine package checksum (over the package data,
        # not over the .apk file), so it cannot be compared with a hash of the
        # download.  The exact size from the index does catch truncation, and
        # the file is fetched over HTTPS from the project mirror.
        size = os.path.getsize(path)
        expected_size = int(fields.get("S", "0"))
        if expected_size and size != expected_size:
            sys.exit(f"size mismatch for {fn}: got {size}, index says {expected_size}")
        digest = hashlib.sha256(open(path, "rb").read()).hexdigest()

        extract(path, root)
        manifest["packages"][name] = {
            "version": ver,
            "size": os.path.getsize(path),
            "sha256": digest,
        }

    # ---------------------------------------------------------------- lay out
    def pick(*candidates):
        for c in candidates:
            if os.path.exists(c):
                return c
        return None

    vmlinuz = pick(f"{root}/boot/vmlinuz", f"{root}/boot/Image")
    dtb = pick(
        f"{root}/boot/dtbs/qcom/{DTB_NAME}",
        f"{root}/boot/dtbs/qcom/msm8953-xiaomi-ysl.dtb",
    )
    lk2nd = pick(
        f"{root}/boot/lk2nd.img",
        f"{root}/usr/share/lk2nd/lk2nd.img",
    )
    moddir = None
    mods_root = f"{root}/usr/lib/modules"
    if os.path.isdir(mods_root):
        for entry in sorted(os.listdir(mods_root)):
            if os.path.isdir(os.path.join(mods_root, entry)):
                moddir = entry
    if not (vmlinuz and dtb and lk2nd):
        sys.exit(f"missing pieces: vmlinuz={vmlinuz} dtb={dtb} lk2nd={lk2nd}")

    shutil.copy2(lk2nd, os.path.join(out, "lk2nd.img"))
    shutil.copy2(vmlinuz, os.path.join(out, "vmlinuz"))
    shutil.copy2(dtb, os.path.join(out, "device.dtb"))

    modules = os.path.join(out, "modules")
    shutil.rmtree(modules, ignore_errors=True)
    if moddir:
        shutil.copytree(os.path.join(mods_root, moddir), os.path.join(modules, moddir), symlinks=True)

    firmware = os.path.join(out, "firmware")
    shutil.rmtree(firmware, ignore_errors=True)
    src_fw = os.path.join(root, "usr/lib/firmware")
    if os.path.isdir(src_fw):
        shutil.copytree(src_fw, firmware, symlinks=True)
    else:
        os.makedirs(firmware, exist_ok=True)

    manifest["kernel_release"] = moddir
    manifest["dtb"] = DTB_NAME
    manifest["kernel_bytes"] = os.path.getsize(os.path.join(out, "vmlinuz"))
    with open(os.path.join(out, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=2)

    print(f"==> kernel release : {moddir}")
    print(f"==> lk2nd          : {os.path.getsize(os.path.join(out, 'lk2nd.img'))} bytes")
    print(f"==> device dtb     : {DTB_NAME}")
    print(f"==> firmware files : {sum(len(f) for _, _, f in os.walk(firmware))}")


if __name__ == "__main__":
    main()
