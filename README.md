# 红米 S2（ysl）的 Debian 13 + Denial 桌面

给 **Xiaomi Redmi S2 / Redmi Y2（`ysl`，MSM8953 / 骁龙 625，720x1440）** 的刷机包：
**Debian 13（trixie）arm64 + [Denial](https://denialwm.org/) 0.6.8** 桌面环境，
全部由 **GitHub Actions** 构建。

不是「把安卓换个内核」：这是主线 Linux + Debian 用户空间。

| 部件 | 来源 |
| --- | --- |
| bootloader | [lk2nd](https://github.com/msm8916-mainline/lk2nd)（postmarketOS 官方 aarch64 包），刷进 BOOT 分区，保留原 ABL |
| 内核 | `linux-postmarketos-qcom-msm8953`（msm8953-mainline）官方 aarch64 包，含 `msm8953-xiaomi-ysl.dtb`、面板/触摸/电源驱动 |
| 用户空间 | 本仓库用 debootstrap 现场生成的 Debian 13 arm64 |
| 桌面 | Denial 0.6.8（Flutter Wayland compositor，官方 arm64 deb） |

启动链：

```
原厂 ABL → BOOT 分区里的 lk2nd → BOOT 分区 512 KiB 处的 ext2 小分区
        → extlinux.conf → 主线内核 + ysl DTB（lk2nd 按原厂 DT 选面板）
        → 内核直接挂 USERDATA 上的 ext4（root=UUID=…）→ systemd → Denial
```

**没有 initramfs**，没有 postmarketOS 用户空间。内核直接挂根。

## 产物

工作流 `Build Debian 13 + DenialWM for Redmi S2 (ysl)` 产出 artifact `redmi-s2-<run>`：

| 文件 | 刷到哪 | 说明 |
| --- | --- | --- |
| `boot.img` | BOOT | lk2nd + ext2 启动分区（512 KiB 偏移）合成镜像，**首次安装**用原厂 fastboot 刷 |
| `bootfs.img` | BOOT | 只有 24 MiB 的 ext2 启动分区（内核 + dtb + extlinux.conf），**已装 lk2nd 后**更新内核用 |
| `lk2nd.img` | BOOT | 单独的 lk2nd，原厂 fastboot 刷 |
| `root.img.gz` | USERDATA | Debian 13 + Denial，解压后约 4 GiB，首次启动自动扩到整个分区 |
| `SHA256SUMS` `verify.log` `manifest.json` | – | 校验、镜像结构自检、用了哪个内核/lk2nd 版本 |

## 怎么构建

Actions → **Build Debian 13 + DenialWM for Redmi S2 (ysl)** → Run workflow。

- 只做用户空间，内核/lk2nd/固件直接下载 postmarketOS 的官方 aarch64 包，**一次约 20 分钟**。
- `rootfs_size_gb`：初始镜像大小，默认 4。
- `denial_version`：默认 `0.6.8`。
- `kernel_version`：留空＝用 APKINDEX 里最新的 `linux-postmarketos-qcom-msm8953`，也可以钉死版本。

本地也能跑（Linux + qemu-user-static + binfmt）：

```sh
sudo apt install debootstrap qemu-user-static binfmt-support e2fsprogs kmod
sudo update-binfmts --enable qemu-aarch64
python3 scripts/fetch-base.py base
sudo ./scripts/build-rootfs.sh rootfs base
bash scripts/make-boot.sh base out
sudo bash scripts/make-rootfs-image.sh rootfs out/root.img 4
sudo python3 scripts/verify.py out/boot.img out/root.img
```

## 怎么刷

详见 [docs/FLASHING.md](docs/FLASHING.md)。简要版：

```sh
# 1) 首次安装（原厂 fastboot：关机后电源+音量下）
fastboot flash boot boot.img
fastboot flash userdata root.img          # 先 gunzip root.img.gz
fastboot reboot

# 2) 以后只更新内核（进 lk2nd fastboot：开机震动后按住音量下）
fastboot flash boot bootfs.img
```

**USERDATA 会被整块覆盖，手机上原有数据全丢。** 不要动 SYSTEM / VENDOR / PERSIST /
EFS / MODEM / BOOTLOADER，否则基带、序列号、传感器标定就没了。

## 第一次启动

1. 屏幕先出内核的 framebuffer 控制台（lk2nd 把原厂 splash 的 framebuffer 传给内核）。
2. systemd 起来后 `ysl-usb-gadget` 建好 RNDIS + 串口：电脑上出现一块网卡，
   手机是 `172.16.42.1`，`ssh ysl@172.16.42.1` 直接进。
3. `ysl-firmware-loader` 从 `firmware` / `vendor` / `persist` 分区里把 WCNSS、调制解调器
   固件拷进 `/lib/firmware`，然后 `ysl-wifi` 加载 `wcn36xx`。
4. tty1 自动登录 `ysl`，`~/.bash_profile` 启动 `denial-session`，出桌面。

| 项目 | 值 |
| --- | --- |
| 用户 / 密码 | `ysl` / `147147` |
| sudo | 免密 |
| ssh | 开，密码登录，`PermitRootLogin no` |
| 串口 | `ttyMSM0`（115200 8N1）、`ttyGS0`（USB 串口） |
| 时区 / 语言 | `Asia/Shanghai` / `zh_CN.UTF-8` |

## 已知限制（实话）

- **面板**靠 lk2nd 从原厂 DT 里读型号（auo/ili7807d、sc/ili9881c、truly/hx8394f），
  主线内核三种都有驱动。原厂 DT 异常的机器可能出现黑屏——串口日志里
  `lk2nd` 会打印选中的 panel 名。
- **WiFi** 依赖原厂分区里的 WCNSS 固件；loader 拷不到时 `journalctl -u ysl-firmware-loader`
  会直说原因，此时 USB 网络仍然可用。
- **GPU** 需要 `a506_zap.mdt`（镜像里已带 ysl 的），缺了就是 llvmpipe 软渲染。
- **音频、摄像头、指纹、通话**没有接：需要内核驱动 + UCM 配置，不是 rootfs 能补的。
- **modem** 主线支持不完整，移动数据可能起不来。
- 首次启动要扩分区 + 第一次起 Denial 会慢（几分钟），之后就正常。

## 排障

```sh
journalctl -b -u ysl-firmware-loader -u ysl-wifi -u ysl-usb-gadget -u ysl-grow-rootfs
dmesg | grep -Ei 'msm|dsi|panel|ft5406|wcnss|adreno'
ls /sys/class/drm /sys/class/input /dev/dri
cat ~/.local/state/denial/session.log
```

- **黑屏但能 ssh**：`/dev/dri/card0` 在不在？不在就是面板没绑上（DTB/panel 不对）。
- **Denial 起不来**：`session.log` 里有 `--check` 的输出；失败时 tty1 会退回 bash，不会崩循环。
- **卡在 lk2nd**：它自己有 fastboot（开机震动后按音量下），`fastboot getvar all` 能看分区。
- **想回安卓**：小米官方线刷包 + MiFlash 直接刷回，或者 `fastboot flash boot` 原厂 boot.img。

## 仓库结构

| 路径 | 用途 |
| --- | --- |
| `.github/workflows/build.yml` | 整条流水线 |
| `scripts/fetch-base.py` | 从 postmarketOS 仓库取内核 / lk2nd / 固件（校验 SHA1） |
| `scripts/build-rootfs.sh` | debootstrap Debian 13 + Denial + 设备层 |
| `scripts/make-boot.sh` | 生成 `boot.img` / `bootfs.img` / `lk2nd.img` |
| `scripts/make-rootfs-image.sh` | 生成固定 UUID 的 ext4 根镜像 |
| `scripts/verify.py` | 镜像结构自检（不需要真机） |
| `debian/overlay/` | systemd 单元、USB gadget、固件加载、Denial 启动脚本 |
| `docs/FLASHING.md` | 刷机细节与回滚 |

## 致谢

- [msm8953-mainline](https://github.com/msm8953-mainline)（内核、lk2nd 设备树）
- [postmarketOS / Nura](https://postmarketos.org)（aarch64 包、msm-firmware-loader 思路）
- [Denial](https://denialwm.org)（Flutter Wayland compositor）
