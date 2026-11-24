# 刷机与回滚

设备：**Xiaomi Redmi S2 / Redmi Y2**，代号 `ysl`，MSM8953（骁龙 625）。
系统：Debian 13 + Denial，主线内核，lk2nd 二级引导。

## 0. 前提

- **Bootloader 已解锁**（小米社区申请或 9008 方式），设置里「OEM 解锁」已开过。
  解锁后开机第一屏会有 unlocked 警告。
- 电脑有 `fastboot`（`apt install android-tools-fastboot` 或 platform-tools）。
- **备份**：`fastboot getvar all` 存一份；有条件的话先用 TWRP 备份 `persist`、`modem`、`efs`。
  这些分区丢了基带/序列号就回不来，而本系统完全不碰它们。

## 1. 首次安装

手机 **关机**，按住 **电源 + 音量下** 进原厂 fastboot（屏幕显示 FASTBOOT）。
`fastboot devices` 能看到设备再继续。

```sh
gunzip root.img.gz                     # 得到 root.img（约 4 GiB）

# BOOT：lk2nd + 内核 + dtb 合成镜像，一次性装好
fastboot flash boot boot.img

# USERDATA：Debian 根文件系统（会清空手机全部数据）
fastboot flash userdata root.img

fastboot reboot
```

第一次开机：

1. lk2nd 起来后按默认项启动（`timeout 1`，不需要按键）。
2. 内核 framebuffer 控制台出现滚动日志（720x1440）。
3. systemd 起来后 USB 变成一块网卡：电脑 `ssh ysl@172.16.42.1`（密码 `147147`）。
4. tty1 自动登录并启动 Denial。

> **USERDATA 会被整块覆盖。** 想保留数据就不能刷 `root.img`，但那样也就没有系统。

## 2. 以后更新

### 只更新内核（不丢数据）

内核和 dtb 在 BOOT 分区 512 KiB 处的 ext2 小分区里，lk2nd 在分区开头：

```sh
# 进 lk2nd 的 fastboot：开机震动后按住音量下
fastboot flash boot bootfs.img     # lk2nd 会把它写到 512 KiB 偏移处
fastboot reboot
```

### 更新用户空间

只能重刷 `root.img`（数据会没了）。想保留数据就在系统里 `apt` / 手工改。

### 重装 lk2nd

原厂 fastboot 下 `fastboot flash boot lk2nd.img`。

## 3. 恢复安卓

两种都可以：

- **MiFlash + 官方线刷包**（推荐，能回到出厂状态）：手机关机，进 fastboot，MiFlash 选包刷。
- **只回内核**：`fastboot flash boot <原厂 boot.img>`，再 `fastboot flash userdata <原厂 userdata.img>`。

刷机前 `fastboot getvar all` 的输出、原厂 `boot.img` / `userdata.img` 建议留着。

## 4. 进不去怎么办

| 现象 | 怎么查 |
| --- | --- |
| 卡在 lk2nd 菜单 | 音量键选择；`fastboot getvar all` 看分区；串口 `ttyMSM0` 有 lk2nd 日志 |
| 内核起来但黑屏 | 串口日志看 lk2nd 打印的 panel 名、`dmesg | grep -i panel` |
| 有内核日志但没到 systemd | 检查 `root=UUID=` 是否和 root.img 一致（`tune2fs -l root.img | grep UUID`） |
| 到 systemd 但没桌面 | `ssh ysl@172.16.42.1`，看 `~/.local/state/denial/session.log` |
| 完全没反应 | 长按电源 10 秒复位；还能进 fastboot 就重刷 `boot.img` |

**串口**：耳机口 UART（`ttyMSM0`，115200 8N1）从第一次开机就有日志，是最可靠的排障通道。
USB 串口（`ttyGS0`）要等 gadget 服务起来之后才有。

## 5. 为什么是 512 KiB

lk2nd 自己就是 BOOT 分区里被原厂 ABL 加载的「下一个 stage」，它把真正的系统启动镜像
放在同一个分区 512 KiB 偏移处，这样更新内核永远不会覆盖 lk2nd 本身。
`boot.img` 是这两段的合成镜像（给原厂 fastboot 用），`bootfs.img` 只是后半段（给 lk2nd
的 fastboot 用）。
