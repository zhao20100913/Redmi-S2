# 刷机：红米 S2（ysl）

这条线的刷机方式和三星 C7 那条不一样，原因只有一个：**红米 S2 的屏幕面板要靠
lk2nd 才能选对**（`msm8953-xiaomi-ysl` 在主线内核里只留了一个占位的
`compatible = "xiaomi,ysl-panel"`，真面板型号是 lk2nd 从原厂 DT 里读出来再补进去的）。
所以这台机器必须多刷一个 lk2nd，C7 那种「一个 boot.img 打天下」在这里不成立。

整机只有三块分区被动：

| 分区 | 刷什么 | 什么时候动 |
| --- | --- | --- |
| BOOT | `lk2nd.img`（二级引导） | 只在第一次，或者 lk2nd 要升级时 |
| RECOVERY（没有就 SYSTEM） | `bootfs.img`（24 MiB ext2：extlinux + 内核 + 设备树） | 每次换内核 |
| USERDATA | `root.img`（Debian 13 + Denial） | 每次重装系统（数据全丢） |

SYSTEM / VENDOR / PERSIST / EFS / MODEM / BOOTLOADER **一律不碰**，基带、序列号、
传感器标定都在那里面。

## 0. 先把这三件事准备好

1. **解锁 BL**。设置里登录小米账号 → 打开「OEM 解锁」→ 用小米解锁工具解锁。
   解锁后开机会有 unlocked 警告，这是正常的。
2. **电脑装好 fastboot**：
   - Ubuntu/Debian：`sudo apt install android-tools-fastboot`
   - Windows/macOS：Google 的 platform-tools
3. **确认能认到手机**：关机，按住 **电源 + 音量下**，屏幕出现 `FASTBOOT` 后插 USB：

   ```sh
   fastboot devices        # 要能看到一行设备号
   ```

   看不到就是驱动/USB 口/没解锁的问题，先解决这个，再谈刷机。

## 1. 第一次安装（三条命令）

下载 release 里的 `lk2nd.img`、`bootfs.img`、`root.img.gz` 放到同一个目录，然后：

```sh
gunzip root.img.gz            # 约 4 GiB

fastboot flash boot      lk2nd.img      # 二级引导
fastboot flash recovery  bootfs.img     # 内核 + 设备树（没有 recovery 分区就换 system）
fastboot flash userdata  root.img       # Debian 13 + Denial（会清空手机）

fastboot reboot
```

`tools/flash.sh` 会先用 `fastboot getvar all` 看这台机器有哪些分区，自动在
`recovery` 和 `system` 之间选一个来放内核；手工刷的话就按上面写死 `recovery`。

```sh
tools/flash.sh first
```

`fastboot flash userdata` 要传 4 GiB，USB 2.0 大概 5–10 分钟，别拔线。

## 2. 刷完应该看到什么

1. 开机 → lk2nd 菜单（有一行 `Panel: xiaomi,ysl-ili9881c` 之类）。
   默认 1 秒后自动继续，也可以按音量键选。
2. 内核启动，屏幕出现滚动的内核日志（黑底白字，720x1440）。
3. Android 那个开机 logo 不会再出现——BOOT 分区里已经不是安卓内核了。
4. systemd 起来后，USB 变成一块网卡，手机是 `172.16.42.1`：

   ```sh
   ssh ysl@172.16.42.1      # 密码 147147
   ```

5. tty1 自动登录并启动 Denial，出桌面（手机形态的 shell，带屏幕键盘）。

进不去也别慌：**耳机口 UART（`ttyMSM0`，115200 8N1）从第一秒就有日志**，
比屏幕可靠得多。

## 3. 以后更新

### 只换内核（不动 lk2nd，不动数据）

```sh
fastboot flash recovery bootfs.img
fastboot reboot
```

因为内核和设备树放在 RECOVERY 这个独立的小分区里，所以换内核不需要碰 USERDATA。

### 重装系统

只能重刷 `root.img`（数据会没）。

### 升级 lk2nd

```sh
fastboot flash boot lk2nd.img
```

## 4. 为什么不是照 C7 那样只刷 boot.img

| | 三星 C7（已跑通） | 红米 S2（这条线） |
| --- | --- | --- |
| 引导 | 原厂 ABL 直接加载 boot.img（QCDT + `SEANDROIDENFORCE`） | 原厂 ABL 加载 **lk2nd**，lk2nd 再找 extlinux |
| 内核在哪 | boot.img 里 | RECOVERY 上的 ext2 小分区 |
| 屏幕面板 | 主线 DTS 里写死（S6E3FA3） | 必须由 lk2nd 从原厂 DT 里选（三种面板） |
| 刷机工具 | heimdall | fastboot |

两者**用户空间完全一样**：都是同一套 debootstrap 出来的 Debian 13 + Denial，
同样固定 root UUID、同样的用户/ssh/USB 网络/固件加载。差别只在引导那一段。

## 5. 想回安卓

- MiFlash + 官方线刷包（最干净，全恢复）。
- 或者只回内核：`fastboot flash boot <原厂 boot.img>`，再
  `fastboot flash recovery <原厂 recovery.img>`、`fastboot flash userdata <原厂 userdata.img>`。

## 6. 出问题对照表

| 现象 | 原因 / 下一步 |
| --- | --- |
| `fastboot devices` 空的 | 驱动、USB 口、没解锁。换口/换线，Linux 看 `lsusb` |
| 刷 `boot` 报 `FAILED (remote: 'size too large')` | lk2nd.img 比 boot 分区大（正常不会，lk2nd 只有 350 KB） |
| 卡在 lk2nd 菜单 | 它没找到 extlinux：`bootfs.img` 是否刷到 recovery？`fastboot getvar all` 看分区表 |
| lk2nd 起来了但内核黑屏 | 串口日志看 `Failed to find panel node` / `Unsupported panel`；把 lk2nd 菜单里打印的 Panel 名发我 |
| 内核日志滚完没到 systemd | `root=UUID=` 和 root.img 的 UUID 对不上（`tune2fs -l root.img | grep UUID`） |
| 到 systemd 但没桌面 | ssh 进去看 `~/.local/state/denial/session.log` |
| 完全没反应 | 长按电源 10 秒复位；还能进 fastboot 就重刷 `boot`/`recovery` |
