# 斐讯 N1 刷 iStoreOS · macOS 部署完整指南

> 一份从「买来一台斐讯 N1」到「在家庭网络里跑起旁路由」的全流程笔记。
> 所有操作都在 **macOS** 上完成，无需 Windows 虚拟机、无需 Rufus。
> 本指南是作者在真实踩坑中整理出来的，专门收录了那些官方文档不会告诉你的 macOS 坑。

---

## 目录

- [0. 这套方案解决什么问题](#0-这套方案解决什么问题)
- [1. 配件准备](#1-配件准备)
- [2. 下载 iStoreOS 镜像](#2-下载-istoreos-镜像)
- [3. 在 Mac 上把镜像写入 U 盘](#3-在-mac-上把镜像写入-u-盘)
- [4. 让 N1 从 U 盘启动](#4-让-n1-从-u-盘启动)
- [5. 网络接法 & 那个绕不开的 IP 撞车](#5-网络接法--那个绕不开的-ip-撞车)
- [6. Mac 侧网络配置（千万别把自家网弄断）](#6-mac-侧网络配置千万别把自家网弄断)
- [7. 找到 N1 的 IP](#7-找到-n1-的-ip)
- [8. 首次登录](#8-首次登录)
- [9. 忘了 root 密码？重写镜像重置](#9-忘了-root-密码重写镜像重置)
- [10. 配置成旁路由（单网口 N1 最佳实践）](#10-配置成旁路由单网口-n1-最佳实践)
- [11. 第一件安全大事：设 root 密码](#11-第一件安全大事设-root-密码)
- [12. 排错速查表](#12-排错速查表)
- [13. 常见问题 FAQ](#13-常见问题-faq)
- [附录：文件清单](#附录文件清单)

---

## 0. 这套方案解决什么问题

斐讯 N1（晶晨 Amlogic S905D）是一台性价比极高的「单网口 ARM 小主机」，刷上
[iStoreOS](https://iStoreOS.com)（基于 OpenWrt 的国产发行版）后能做：

- **旁路由 / 网关**：给家里指定设备做特殊网络分流（你懂的）；
- **轻量 NAS / 下载机**；
- **广告拦截、DNS 净化** 等。

N1 是**单网口**盒子：系统跑在 **U 盘**里，U 盘就是「系统盘」，拔掉 U 盘就恢复原厂——不伤盒子。
本指南聚焦 **macOS 用户**如何用一条命令把镜像写进 U 盘，并把它干净利落地接进已有家庭网。

---

## 1. 配件准备

| 物品 | 说明 |
|------|------|
| 斐讯 N1 一台 | 已解锁（能进 U 盘启动）。未解锁机器的解锁不在本指南范围 |
| U 盘 8GB+ | 建议 16GB 以上、USB 2.0 优先（N1 的 USB 口供电弱，3.0 大盘可能带不动） |
| Mac 一台 | 任意 macOS，脚本已兼容系统自带的老 bash 3.2 |
| 网线一根 | 直连 N1 用；或接家里路由器 |
| （可选）USB 转网口转接器 | 如果你 Mac 没有网口、且想直连 N1 调试 |
| （可选）HDMI 线 + 显示器 | 排错时看开机画面最稳 |

> N1 接口分辨：**宽口 RJ45 = 网口**；旁边两个**窄口 = USB**（插 U 盘用）。别插错。

---

## 2. 下载 iStoreOS 镜像

镜像地址会随版本更新而挪动。截至本指南整理时，N1 镜像位于 koolcenter 的 `alpha/n1/` 目录：

```
https://fw.koolcenter.com/iStoreOS/alpha/n1/istoreos-24.10.7-2026060510-phicomm_n1-squashfs.img.gz
```

老路径 `iStoreOS/22.03.6/istoreos-...-phicomm_n1-squashfs.img` **已失效**（官方下架/挪走）。
如果上面链接 404，去 [fw.koolcenter.com/iStoreOS/alpha/n1/](https://fw.koolcenter.com/iStoreOS/alpha/n1/)
找最新的 `istoreos-*-phicomm_n1-squashfs.img.gz`。

仓库里附带了一键下载脚本：

```bash
bash scripts/download_image.sh ~/Downloads/istoreos_n1.img
```

脚本会下载、解压、并校验（MBR 签名 `55AA` + squashfs 魔数 `hsqs`）镜像完整性。
> 注：`gunzip` 偶尔会报 `trailing garbage ignored`（文件末尾多了几个字节），**不影响**，镜像仍是完整的。

---

## 3. 在 Mac 上把镜像写入 U 盘

Windows 用 Rufus，macOS 用 `dd`。本仓库的 `scripts/write_n1_reset.sh` 封装好了：

```bash
# 镜像路径可传参；不传则默认 ~/Downloads/istoreos_n1.img
sudo bash scripts/write_n1_reset.sh ~/Downloads/istoreos_n1.img
```

脚本会：

1. **自动识别外置 U 盘**（`diskutil list` 里 `external, physical` 的盘），**绝不会碰内置 `disk0`**；
2. 若插了多块外置盘，会拒绝执行让你确认，避免误写；
3. 要求你输入 `YES` 才写（防手滑）；
4. 卸载 → `dd` 写入裸设备 `rdiskN` → 推出。

> ⏱ 16GB U 盘写 326MB 镜像约 1~2 分钟，无进度条属正常，耐心等跑完自动弹出。

### macOS 专属坑（已在本脚本处理，但值得知道）

- **系统 `/bin/bash` 是 3.2 老版本**，`mapfile` 不存在 → 改用 `grep -oE` 提取磁盘号。
- `diskutil info` 的容量字段叫 **`Disk Size`**（不是 `Total Size`）。
- `setmanual` 省略网关参数**不会**清空旧网关 → 重置密码那步要显式写 `0.0.0.0`（见第 9 节）。

---

## 4. 让 N1 从 U 盘启动

1. 把写好的 U 盘插进 N1 **靠近 HDMI 的那个 USB 口**（N1 通常只认特定口启动）；
2. **先插好 U 盘，再给 N1 通电**（冷启动，让 u-boot 优先从 USB 找系统）；
3. 等 1~2 分钟，蓝灯闪烁后稳定 = iStoreOS 起来了。

---

## 5. 网络接法 & 那个绕不开的 IP 撞车

N1 的 iStoreOS 默认 LAN 是 **`192.168.1.1`**。而**你家光猫 / 路由器往往也用 `192.168.1.1`**——

> ⚠️ **IP 撞车**：浏览器开 `192.168.1.1` 进的是光猫，不是 N1。这是 90% 新手卡住的根因。

两种接法：

| 接法 | 做法 | 适合 |
|------|------|------|
| **A. 接家里路由器（推荐）** | N1 网线插路由器/交换机 LAN 口，N1 从 DHCP 拿 `192.168.0.x` | 旁路由、最省事、不碰光猫 |
| **B. 直连 Mac 调试** | N1 网线直连 Mac 网卡（en0） | 临时调试、没路由器时 |

本指南主推 **A（旁路由）**：N1 留在家里网段，给需要分流的设备当网关，完全绕开 `192.168.1.1` 冲突区。

---

## 6. Mac 侧网络配置（千万别把自家网弄断）

如果你选**直连 Mac（接法 B）**，必须给 en0 设同网段 IP，**但绝不能设网关**——否则 macOS 会把 N1 当成默认出口，你的 Wi‑Fi 外网瞬间断掉。

```bash
# 给 en0 设 192.168.1.2，网关显式写成 0.0.0.0（本口不做出口）
sudo networksetup -setmanual "Ethernet" 192.168.1.2 255.255.255.0 0.0.0.0

# 让 Wi‑Fi 永远是主出口（注意：macOS 没有 -setprimaryservice，用下面这个）
sudo networksetup -ordernetworkservices "Wi-Fi" "Ethernet" "Thunderbolt Bridge"
```

> 关键：`0.0.0.0` 这个网关**不能省**。macOS 在你「省略网关」时不会清掉旧值，
> 残留的 `192.168.1.1` 网关会在你一插 N1 时抢走默认路由，把你家网掐了。
> 若已经断了，急救：`sudo route delete default 192.168.1.1`。

接法 A（接路由器）则什么都不用配，N1 自己会从家里 DHCP 拿地址。

---

## 7. 找到 N1 的 IP

- **接路由器（A）**：登录路由器后台看 DHCP 客户端列表；或用仓库的 `scripts/discover_n1.sh` 扫 `192.168.0.x`。
- **直连 Mac（B）**：N1 通常是 `192.168.1.1`。如果没响应，多半是 N1 处于 DHCP 客户端模式（没当网关），此时把 N1 改接路由器，或给 en0 加候选段别名后逐个 ping（详见 `docs/troubleshooting.md`）。

---

## 8. 首次登录

- **Web**：浏览器开 `http://<N1的IP>` → iStoreOS / LuCI 登录页，用户名 `root`，密码 `password`（或留空）。
- **SSH**：`ssh root@<N1的IP>`，密码同上。

首次进系统常会提示 `There is no root password defined`（没设密码），**务必尽快设置**（见第 11 节）。

---

## 9. 忘了 root 密码？重写镜像重置

暴力破解自定义密码基本没戏（字典里没有）。最干净的办法：**重写 U 盘镜像**，root 立刻回到默认 `password`。

就是重复第 3 节：下载最新镜像 → `sudo bash scripts/write_n1_reset.sh <镜像>` 写盘 → 按第 4 节插回 N1 冷启动。
写完后 `password` 即可登录（iStoreOS 也可能要求首次留空密码，进去再设）。

> 若写完后 `password` 仍登不进，说明这台 N1 是从**内置 eMMC** 启动、无视 U 盘。
> iStoreOS 刷过 eMMC 后 u-boot 通常优先 USB，所以「先插 U 盘再通电」多半能覆盖；
> 真不行就走 `adb reboot update` 或晶晨宝盒强制 USB 烧录（见排错表）。

---

## 10. 配置成旁路由（单网口 N1 最佳实践）

SSH 进 N1 后，执行（把 `192.168.0.x` 换成你家网段，IP 选 DHCP 池外的空闲地址，如 `.2`）：

```sh
uci set network.lan.proto='static'
uci set network.lan.ipaddr='192.168.0.2'     # 家里网段里的固定 IP
uci set network.lan.netmask='255.255.255.0'
uci set network.lan.gateway='192.168.0.1'    # 指回你家主路由
uci set network.lan.dns='192.168.0.1'
uci commit network

# 关掉 N1 自己的 DHCP，避免和你家路由器抢地址
if uci -q get dhcp.lan; then uci set dhcp.lan.ignore='1'; uci commit dhcp; fi

/etc/init.d/network restart
```

重启后 N1 管理地址变成 `192.168.0.2`。验证：

```sh
ip -4 addr show br-lan     # 看是否拿到 192.168.0.2
ip route | grep default    # 默认网关应是 192.168.0.1
ping 8.8.8.8               # 能通 = N1 自己能上网
ps w | grep uhttpd         # Web 服务在跑
```

**想让某台设备走 N1 分流**：把那台设备的网关 / DNS 手动设成 `192.168.0.2` 即可。
别急着改家里路由器的 DHCP——除非你确定要**全家**流量都过 N1。

---

## 11. 第一件安全大事：设 root 密码

刚刷好的系统默认无密码 / `password`，任何人连上你家网都能进 N1。登录后立刻：

- Web：`系统 → 管理权 → 修改密码`；
- 或 SSH：`passwd`。

---

## 12. 排错速查表

| 现象 | 处理 |
|------|------|
| 插 U 盘后 N1 网口灯不亮 | 换网线 / 换口；确认插的是 RJ45 网口不是 USB；确认通电 |
| 浏览器开 `192.168.1.1` 进的是光猫 | IP 撞车！按第 5 节改接法 A，或登录后把 LAN 改到非 `192.168.1.x` |
| 接上 N1 后 Mac 断网 | en0 残留 `Router: 192.168.1.1` 抢了默认路由。急救：`sudo route delete default 192.168.1.1`；根治：按第 6 节设 `0.0.0.0` 网关 |
| `192.168.1.1` 链路通但不回应 | N1 没从 U 盘引导（进了 eMMC / 原厂）。换 USB 口 + 插 U 盘冷启动；或接 HDMI 看开机画面 |
| N1 在 `192.168.1.1` 不回应、整段只有 Mac | N1 是 DHCP 客户端模式，没当网关。接路由器拿 `192.168.0.x` 再扫 |
| `password` 登不进 | 自定义密码 → 重写镜像重置（第 9 节）；或根本不是 N1（去路由器看 MAC/主机名确认） |
| `mapfile: command not found` | macOS 自带 bash 3.2 无 `mapfile`。用本仓库脚本（已规避） |
| `zsh: missing end of string` | 把 `#` 注释和命令一起粘进终端导致。每条命令单独粘、回车 |

更细的排查（镜像校验、eMMC vs U 盘启动判定、候选段别名扫 IP）见 [`docs/troubleshooting.md`](docs/troubleshooting.md)。

---

## 13. 常见问题 FAQ

**Q: 镜像必须 U 盘吗？能不能直接刷进 N1 内置存储？**
A: 可以。用顺了之后在 iStoreOS 里 `系统 → 晶晨宝盒 → 安装到 eMMC`，之后可拔 U 盘从内置启动。

**Q: 直连 Mac 和接路由器，哪种好？**
A: 调试用直连；长期使用选接路由器做旁路由，最稳且不冲突。

**Q: 为什么我的 Mac 设了静态 IP 还是上不了网？**
A: 八成是 en0 残了 `192.168.1.1` 网关。按第 6 节用 `0.0.0.0` 重设，或 `route delete default 192.168.1.1`。

**Q: N1 能当主路由替代光猫吗？**
A: 能。让 N1 单口做 WAN 接光猫（光猫改桥接），LAN 改到非冲突段（如 `192.168.2.1`）再接你原来的交换机/AP。本文主推旁路由，主路由玩法类似，只差 WAN/LAN 划分。

---

## 附录：文件清单

```
n1-istoreos-macos-guide/
├── README.md                      # 本文件：完整流程总结
├── LICENSE                        # MIT
├── scripts/
│   ├── download_image.sh          # 下载 + 校验最新 iStoreOS N1 镜像
│   ├── write_n1_reset.sh          # Mac 写盘脚本（自动识别 U 盘，重置为默认密码）
│   └── discover_n1.sh             # 局域网扫描找 N1（接路由器场景）
└── docs/
    └── troubleshooting.md         # 排错细节 + macOS 坑合集
```

---

## 致谢 & 许可证

- iStoreOS 项目：<https://iStoreOS.com>
- 镜像源：<https://fw.koolcenter.com/iStoreOS/>
- 本指南以 **MIT 许可证** 开源，欢迎 PR。
