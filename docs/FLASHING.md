# 刷机：红米 S2（ysl）

**只刷两个分区**，不需要 recovery，也不需要 system：

| 分区 | 刷什么 | 说明 |
| --- | --- | --- |
| BOOT | `lk2nd.img` | 二级引导（约 350 KB），原厂 ABL 加载它 |
| USERDATA | `root.img` | Debian 13 + Denial；**内核和设备树也在里面**（`/boot` + `/extlinux`） |

启动时 lk2nd 会挂载 USERDATA 这个文件系统，读 `/extlinux/extlinux.conf`，
再把 `/boot/vmlinuz` 和 `/boot/msm8953-xiaomi-ysl.dtb` 读进内存启动内核 ——
所以内核不占独立分区，`rec` 分区刷不进去也完全不影响。

SYSTEM / VENDOR / PERSIST / EFS / MODEM / BOOTLOADER / RECOVERY **一律不碰**。

> 为什么必须要有 lk2nd：主线内核的 ysl 设备树里，屏幕只有一个占位
> `compatible = "xiaomi,ysl-panel"`。真面板型号（ili9881c / h8394f / ili7807d）
> 是 lk2nd 从原厂 DT 里读出来、再补进内核设备树的。没有它，系统能跑但屏幕是黑的。

## 0. 准备

1. **BL 已解锁**（设置里开 OEM 解锁 → 小米解锁工具）。
2. 电脑有 `fastboot`：`sudo apt install android-tools-fastboot`（Windows/macOS 用 platform-tools）。
3. 手机关机，按住 **电源 + 音量下**，出现 `FASTBOOT` 后插 USB：

   ```sh
   fastboot devices     # 必须能看到一行设备号，看不到先解决驱动/USB/解锁
   ```

## 1. 安装

下载 release 里的 `lk2nd.img` 和 `root.img.gz` 放同一目录：

```sh
gunzip root.img.gz

fastboot flash boot      lk2nd.img
fastboot flash userdata  root.img

fastboot reboot
```

或者用仓库里的脚本（会先检查设备，刷 userdata 前要输入 yes）：

```sh
tools/flash.sh first
```

`fastboot flash userdata` 要传 4 GiB，USB 2.0 大约 5–10 分钟，别拔线。

## 2. 刷完应该看到什么

1. 开机 → lk2nd 菜单，会打印 `Panel: xiaomi,ysl-ili9881c` 这类信息；
   默认 1 秒后自动继续（也可以按音量键选）。
2. 内核日志开始滚屏（黑底白字）。
3. Android 的开机 logo 不会再出现 —— BOOT 分区里已经不是安卓内核。
4. systemd 起来后 USB 变网卡，手机 `172.16.42.1`：

   ```sh
   ssh ysl@172.16.42.1      # 密码 147147
   ```

5. tty1 自动登录并启动 Denial（手机形态 shell，带屏幕键盘）。

屏幕不亮时，**耳机口 UART（`ttyMSM0`，115200 8N1）从第一秒就有日志**，比屏幕可靠。

## 3. 换内核（不动数据、不用 fastboot）

内核就是手机里的两个普通文件，替换后重启即可（lk2nd 每次开机都会重新读）：

```sh
scp vmlinuz                 ysl@172.16.42.1:/tmp/
scp msm8953-xiaomi-ysl.dtb  ysl@172.16.42.1:/tmp/
ssh ysl@172.16.42.1
sudo cp /tmp/vmlinuz /boot/vmlinuz
sudo cp /tmp/msm8953-xiaomi-ysl.dtb /boot/
sudo reboot
```

嫌麻烦就直接重刷系统：`tools/flash.sh root`（数据会全丢）。

## 4. 想回安卓

- MiFlash + 官方线刷包（最干净）。
- 或者手上有原厂镜像：`fastboot flash boot <原厂 boot.img>` +
  `fastboot flash userdata <原厂 userdata.img>`。

## 5. 这条线为什么和三星 C7 不一样

| | 三星 C7（已跑通） | 红米 S2（这条线） |
| --- | --- | --- |
| 引导 | ABL 直接加载 boot.img（QCDT） | ABL 加载 **lk2nd**，lk2nd 读 extlinux |
| 内核在哪 | boot.img 里 | USERDATA 的 `/boot` 里 |
| 屏幕面板 | 主线 DTS 写死 | 必须由 lk2nd 从原厂 DT 里选 |
| 刷机 | heimdall：boot + userdata | fastboot：boot + userdata |

用户空间两边**完全同源**：同一套 debootstrap 的 Debian 13 + Denial，同样的固定
root UUID、用户、ssh、USB 网络、固件加载。区别只在引导那一段。

## 6. 出问题对照表

| 现象 | 下一步 |
| --- | --- |
| `fastboot devices` 空的 | 驱动 / USB 口 / 没解锁。换口换线，Linux 看 `lsusb` |
| `fastboot flash recovery ...` 报错 | **不用刷 recovery**，这条线不需要它 |
| 卡在 lk2nd 菜单 | 它没读到 extlinux：确认 USERDATA 刷的是 root.img（不是解压前的 .gz） |
| lk2nd 起来了但黑屏 | 串口看 lk2nd 打印的 `Panel:` 和 `Failed to find panel node`，把那几行发我 |
| 内核日志滚完没到 systemd | `root=UUID=` 与 root.img 的 UUID 不一致（`tune2fs -l root.img | grep UUID`） |
| 到 systemd 但没桌面 | ssh 进去看 `~/.local/state/denial/session.log` |
| 完全没反应 | 长按电源 10 秒复位；还能进 fastboot 就重刷 boot + userdata |
