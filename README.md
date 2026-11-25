# 红米 S2（ysl）的 Debian 13 + Denial 桌面

给 **Xiaomi Redmi S2 / Redmi Y2（`ysl`，MSM8953 / 骁龙 625，720x1440）** 的刷机包：
**Debian 13（trixie）arm64 + [Denial](https://denialwm.org/) 0.6.8** 桌面环境，
全部由 **GitHub Actions** 构建。

不是「把安卓换个内核」：这是主线 Linux + Debian 用户空间。

## 状态

- **v0.3.0**：只刷两个分区——lk2nd 进 BOOT，Debian（**内含内核和设备树**）
  进 USERDATA。不占 recovery/system，`rec` 刷不进去也不影响。
- CI 的结构自检（`scripts/verify.py`）全过：lk2nd 是合法 Android boot 镜像且内含
  ysl 设备树、根镜像的文件系统特性在 lk2nd 能读的范围内、`/extlinux/extlinux.conf`
  与 `/boot` 里的内核/dtb 在位、Denial 与内核模块、ysl 的 GPU zap shader 都在。
- **还没有在真机上开过机。** 第一次刷机后的串口日志/现象是下一步唯一需要的东西。

## 它由什么组成

| 部件 | 来源 | 说明 |
| --- | --- | --- |
| lk2nd | postmarketOS 官方 aarch64 包（`lk2nd-msm8953` 23.1） | 二级引导，刷进 **BOOT**；从原厂 DT 读面板型号（ili9881c / h8394f / ili7807d）并补进内核设备树 |
| 内核 | `linux-postmarketos-qcom-msm8953` 7.1.3 | 主线 msm8953：DRM/DSI、ft5406 触摸、WCN36xx WiFi、a530 GPU |
| 内核+设备树 | 同上，直接放进根文件系统的 `/boot` + `/extlinux` | 不用单独分区，换内核就是替换两个文件 |
| 用户空间 | 本仓库 debootstrap 现场生成 | Debian 13 arm64、systemd、中文、ssh、NetworkManager |
| 桌面 | Denial 0.6.8 官方 arm64 deb | Flutter Wayland compositor，`DENIAL_SHELL_PROFILE=mobile`（带屏幕键盘） |

启动链：

```
原厂 ABL → BOOT 里的 lk2nd → 挂载 USERDATA → /extlinux/extlinux.conf
        → /boot/vmlinuz + ysl DTB（面板已由 lk2nd 补好）
        → 同一分区当根（root=UUID=…）→ systemd → Denial
```

根文件系统特意用「无 extent / 无 64bit / 无 metadata_csum」的 ext4（即 ext3 风格）：
lk2nd 的文件系统驱动只认这一套，它得能读出 `/extlinux` 和内核。

没有 initramfs，也没有 postmarketOS 用户空间；内核直接挂根。

## 产物

| 文件 | 刷到 | 说明 |
| --- | --- | --- |
| `lk2nd.img` | BOOT | 二级引导（约 350 KB） |
| `root.img.gz` | USERDATA | Debian 13 + Denial（内核与设备树在 `/boot`），约 4 GiB，首次启动自动扩满分区 |
| `SHA256SUMS` `verify.log` `manifest.json` | – | 校验 / 结构自检 / 用的内核与 lk2nd 版本 |

## 怎么刷（三条命令）

前提：BL 已解锁，电脑有 `fastboot`，手机关机后按住 **电源 + 音量下** 进 FASTBOOT。

```sh
gunzip root.img.gz

fastboot flash boot      lk2nd.img
fastboot flash userdata  root.img

fastboot reboot
```

或者用 `tools/flash.sh first`（会先检查设备再逐条确认）。

以后换内核：把新的 `vmlinuz` / dtb 拷进手机的 `/boot` 再重启即可
（lk2nd 每次开机都重新读），完全不用 fastboot、不动数据。

细节、对照表、回安卓的方法见 [docs/FLASHING.md](docs/FLASHING.md)。

**USERDATA 会被整块覆盖。** 不要动 SYSTEM / VENDOR / PERSIST / EFS / MODEM / BOOTLOADER。

## 第一次启动

1. lk2nd 菜单（会打印识别到的面板），1 秒后自动继续。
2. 内核日志滚过屏幕；systemd 起来后 USB 变网卡：`ssh ysl@172.16.42.1`。
3. `ysl-firmware-loader` 从 `firmware`/`vendor`/`persist` 分区把 WCNSS、modem 固件
   拷进 `/lib/firmware`，`ysl-wifi` 再加载 `wcn36xx`。
4. tty1 自动登录并启动 Denial（手机形态 shell，自带屏幕键盘）。

| 项目 | 值 |
| --- | --- |
| 用户 / 密码 | `ysl` / `147147` |
| sudo | 免密 |
| ssh | 开，密码登录，`PermitRootLogin no` |
| 串口 | `ttyMSM0`（115200 8N1）、`ttyGS0`（USB 串口） |
| 时区 / 语言 | `Asia/Shanghai` / `zh_CN.UTF-8` |

## 怎么构建

Actions → **Build Debian 13 + DenialWM for Redmi S2 (ysl)** → Run workflow。
内核/lk2nd/固件是 pinned 的 postmarketOS 包，CI 只做 Debian 用户空间，**一次约 25 分钟**；
打 tag 会自动发 release。

本地：

```sh
sudo apt install debootstrap qemu-user-static binfmt-support e2fsprogs kmod
sudo update-binfmts --enable qemu-aarch64
python3 scripts/fetch-base.py base
sudo ./scripts/build-rootfs.sh rootfs base
bash scripts/make-boot.sh base out
sudo bash scripts/make-rootfs-image.sh rootfs out/root.img 4
sudo python3 scripts/verify.py out/lk2nd.img out/root.img
```

## 已知限制（实话）

- **显示/触摸**依赖 lk2nd 选对面板；原厂 DT 异常的机器会黑屏，串口日志会直说。
- **WiFi** 依赖原厂分区里的 WCNSS 固件，拷不到时 `journalctl -u ysl-firmware-loader` 有原因，
  此时 USB 网络仍可用。
- **GPU** 需要 `a506_zap.mdt`（镜像已带 ysl 的），缺了就是 llvmpipe 软渲染。
- **音频、摄像头、指纹、通话**没有接；**移动数据**不保证。
- 首次启动要扩分区 + 第一次起 Denial 会慢（几分钟）。

## 排障

```sh
journalctl -b -u ysl-firmware-loader -u ysl-wifi -u ysl-usb-gadget -u ysl-grow-rootfs
dmesg | grep -Ei 'msm|dsi|panel|ft5406|wcnss|adreno'
cat ~/.local/state/denial/session.log
```

- **黑屏但能 ssh**：`/dev/dri/card0` 在不在？不在就是面板没绑上。
- **Denial 起不来**：`session.log` 里有 `denial-session --check` 输出；失败会退回 bash，不会崩循环。
- **卡在 lk2nd**：它自己有 fastboot（开机震动后按音量下），`fastboot getvar all` 看分区。

## 仓库结构

| 路径 | 用途 |
| --- | --- |
| `.github/workflows/build.yml` | 整条流水线（打 tag 自动发 release） |
| `scripts/fetch-base.py` | 取 postmarketOS 的内核 / lk2nd / 固件（版本钉死、校验大小） |
| `scripts/build-rootfs.sh` | debootstrap Debian 13 + Denial + 设备层 |
| `scripts/make-boot.sh` | 产出 `lk2nd.img` |
| `scripts/make-rootfs-image.sh` | 生成固定 UUID 的 ext4 根镜像 |
| `scripts/verify.py` | 三个镜像的结构自检（不需要真机） |
| `debian/overlay/` | systemd 单元、USB gadget、固件加载、Denial 启动脚本与会话配置 |
| `tools/flash.sh` | 刷机脚本（first / root / kernel / check） |
| `docs/FLASHING.md` | 刷机细节、对照表、回滚 |

## 致谢

- [msm8953-mainline](https://github.com/msm8953-mainline)（内核、lk2nd 设备树）
- [postmarketOS / Nura](https://postmarketos.org)（aarch64 包、msm-firmware-loader 思路）
- [Denial](https://denialwm.org)（Flutter Wayland compositor）
