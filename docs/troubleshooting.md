# N1 iStoreOS — 排错细节 & macOS 专属坑

## macOS bash 3.2 的坑（系统 `/bin/bash` 是老版本）

- `mapfile` 不存在（bash 4+ 才有）。用 `grep -oE` + 普通变量代替数组：
  ```sh
  diskutil list | grep -oE '/dev/disk[0-9]+ \(external, physical\)' | grep -oE 'disk[0-9]+'
  ```
- `diskutil info` 容量字段叫 **`Disk Size`**，不是 `Total Size`。
- 别把 shell 注释（`#`）和命令一起粘进 zsh 终端，会报
  `zsh: missing end of string` / `route: bad address: #`。每条命令单独粘、回车。
- `networksetup -setprimaryservice` 在 macOS **不存在**。改用：
  ```sh
  sudo networksetup -ordernetworkservices "Wi-Fi" "Ethernet" "Thunderbolt Bridge"
  ```
- WorkBuddy 沙箱里 `sudo` 不可用——需要 root 的网络/挂载命令必须在你自己的 Mac 上跑。

## 镜像完整性校验（解压后）

`gunzip` 可能打印 `trailing garbage ignored`（文件末尾多了几个字节）并退出码非零，
但镜像本身是好的。校验：

```sh
file istoreos_n1.img                 # "DOS/MBR boot sector"，含 3 个分区
xxd -s 510 -l 2 istoreos_n1.img      # 应为 55 aa（MBR 启动签名）
python3 -c "import sys;d=open('istoreos_n1.img','rb').read();print('squashfs' if b'hsqs' in d else 'NO squashfs')"
```

## 「链路通（en0 active，千兆全双工）但 192.168.1.1 不回应」

- 说明 L1/L2 正常，但 N1 网络栈不在那个地址。
- 最可能：N1 **没从 U 盘引导**（进了 eMMC / 原厂系统）。
  修复：U 盘插**靠近 HDMI 的口**，插好 U 盘再通电（冷启动覆盖 eMMC）。
- 或 N1 处于 **DHCP 客户端模式**（没当网关，没 `192.168.1.1`）。把它接到真实 DHCP 服务器
  （家里路由器），扫 `192.168.0.0/24` 找它租到的 IP。

## eMMC vs U 盘启动判定

进系统后 `ssh` 进去查：
```sh
cat /etc/os-release     # NAME 是否为 iStoreOS
ip -4 addr              # LAN 有没有拿到 IP
uci show network        # 网络配置
```
若不是 iStoreOS / LAN 没 IP = 从 eMMC 启动，不是你的 U 盘镜像。
iStoreOS 刷过 eMMC 后 u-boot 通常在插入 U 盘开机时优先 USB；若不行，用
`adb reboot update`（需运行中的系统开了 adb）或晶晨宝盒 USB 烧录（短接法）。

## 整段扫不到 N1（非 `192.168.1.1`）

给 en0 加候选网段别名（**不改默认路由**，Wi‑Fi 仍在上网）：
```sh
for n in 2 3 4 5 8 10 31 50 100 123; do
  sudo ifconfig en0 alias 192.168.$n.2 255.255.255.0
done
sudo ifconfig en0 alias 10.0.0.2 255.255.255.0
sudo ifconfig en0 alias 10.0.1.2 255.255.255.0
```
然后逐个 ping `192.168.N.1`。全空 = N1 是 DHCP 客户端（不是网关）→ 接路由器扫 `192.168.0.x`。

## 「接上 N1 后 Mac 断网」

- 原因：en0 残留 `Router: 192.168.1.1`，一插 N1 就让 en0 成了默认路由，指向一个死网关。
- 根防（接 N1 前做）：
  ```sh
  sudo networksetup -setmanual "Ethernet" 192.168.1.2 255.255.255.0 0.0.0.0
  ```
  `0.0.0.0` 网关是**必须的**——macOS 在你「省略网关」时不会清旧值。
- 急救（已断网）：`sudo route delete default 192.168.1.1`

## 镜像下载地址失效

koolcenter 的 N1 镜像从 `iStoreOS/22.03.6/` 挪到了 `iStoreOS/alpha/n1/`。
若脚本里的 URL 404，去 <https://fw.koolcenter.com/iStoreOS/alpha/n1/> 找最新的
`istoreos-*-phicomm_n1-squashfs.img.gz`，改 `scripts/download_image.sh` 里的 `URL` 即可。
