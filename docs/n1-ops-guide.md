# N1 上线后运维折腾全记录（功能 / 过程 / 踩坑）

> 本篇是主指南 `README.md`（刷机 → 旁路由）的**续集**：N1 已经跑起来之后，上面陆续堆了哪些东西、怎么堆的、以及每个功能踩过的坑。
> 适合已经按主指南装好 N1、想在它身上继续加功能的同学。
>
> ⚠️ **安全说明**：本仓库是公开仓库，文中所有密钥、密码、订阅节点参数（UUID / public_key / short_id / SS 密码 / root 口令）均已**打码**，只保留架构、流程与坑位。需要复现请用自己的订阅与凭证替换占位符。

---

## 0. 当前家底（一台 N1 上跑了什么）

| 功能 | 说明 | 监听 / 路径 |
|------|------|------|
| iStoreOS 旁路由 | 全家网关 + DNS + 代理入口 | `192.168.0.2` |
| PassWall + sing-box 故障转移 | 透明代理，anytls 4 节点池 urltest 自动切换 | nft `:11211` 入、`SOCKS :11111` 出 |
| Home Assistant | Docker host 网络，米家/设备中枢 | `:8123`，数据 `/mnt/mmc1-4/homeassistant` |
| HomeKit 桥 | HA 内置，唯一对外语音/控制通道 | `:21063`，mDNS `Home Assistant Bridge 6D194F` |
| xiaomi_home 集成 | 米家设备接入 HA | config entry |
| 工作站门户 | nginx:alpine 反代 LuCI/HA/MC + 状态页 | `:8888` |
| Outline Server | Shadowbox（arm64），独立 VPN | API `:19001`（规避 PassWall 抢占）|
| pw_adblock | dnsmasq 广告域名黑洞 | 写 `/etc/dnsmasq.conf` |
| 每日备份 | NAS 日志自动备份 | `backup-to-nas.sh` 每 05:00 → `/mnt/nas/n1-backup` |

**硬件 / 网络拓扑**

```
                公网 (南京移动动态 IP, 非 CGNAT)
                        │
            TP-Link TL-7DR3630 (主路由, 192.168.0.1)
            ├─ DHCP: 下发网关/DNS = 192.168.0.2 (N1)
            └─ 端口映射: 把公网端口转给 N1 (暴露公网必须在这做)
                        │
            斐讯 N1 (旁路由, 192.168.0.2)
            ├─ ARM A53 四核 / 2GB / Docker 27.3.1
            ├─ eMMC: p4 = /mnt/mmc1-4 (存 HA / docker / 配置)
            └─ U 盘: /dev/sda 保留作回退 (勿删 sda4/n1-emmc-backup)
```

> 关键认知：**N1 兼任全家网关 + HA，绝不能被打满 CPU**，否则全家断网。改任何 N1 配置后每日 03:15 自动同步 overlay，无需手动。

---

## 1. 硬规则（防灾难 · 先读这段再动任何东西）

以下任一条踩中都是 **P0 全家断网 / 数据全丢**，务必背熟：

| # | 规则 | 后果 |
|---|------|------|
| 1 | **绝不在 N1 部署 Minecraft / box64 / amd64 服务** | 曾拖垮网关，全家断网。MC 改 x86 / 树莓派 / 云 |
| 2 | **禁用 `/usr/sbin/install-to-emmc.sh`** | 它会 `dd` 清 eMMC 引导区并抹掉 p4（HA/docker 数据）。系统已迁 eMMC，U 盘只作回退 |
| 3 | **改 HA `.storage/*.json` 必须先 `docker stop homeassistant`** | 否则 HA 退出时用内存态覆盖文件，改动丢失 |
| 4 | **passwall 热重载（reload/restart/stop+start）会 OOM 卡死 N1** | 改代理模式只 `uci set` + `uci commit`，靠物理重启冷启动生效 |

补充：N1 只有 2GB RAM，PassWall 重载有 OOM 风险窗口，任何重载操作尽量放在无人用网时段，且准备好「拔电冷启」兜底。

---

## 2. PassWall 旁路由 & 透明代理

### 2.1 透明代理生效前提

透明代理**不是自动对所有设备生效**，它依赖一条铁律：

> **设备网关必须是 N1（192.168.0.2）**。

做法：在主路由 TP-Link 的 DHCP 里把「默认网关 / DNS」都改成 `192.168.0.2`。这样设备的流量才会被 N1 的 nftables 接管、按规则分流。

> ⚠️ 坑位：手机的「网关」和「DNS」是**两个独立项**。即使 DNS 填了 `.2`，只要网关还是主路由 `.1`，境外流量就从主路由直出 → 被墙。排查「某设备不通」第一步永远是先看它的**网关**是不是 `.2`。

### 2.2 代理模式切换（正确姿势）

当前模式 = **proxy 全局（绕过国内）**。切换位置有两处且**必须同步**：

```sh
uci set passwall.@global[0].tcp_proxy_mode='xxx'
uci set passwall.@global[0].udp_proxy_mode='xxx'
uci set passwall.@acl_rule[1].tcp_proxy_mode='xxx'   # ACL 规则也要同步
uci set passwall.@acl_rule[1].udp_proxy_mode='xxx'
uci commit passwall
# ⚠️ 只 commit，不要 reload/restart（见硬规则 #4）
```

### 2.3 代理故障转移系统（sing-box anytls 4 节点池）

这是 N1 代理的「心脏」，配置文件 `/mnt/mmc1-4/pw-failover/pw-fo.json`：

```
设备流量 ──nft :11211 (TPROXY)──▶ sing-box 实例
                                      │  anytls 4 节点池 (urltest 10s 自动切换)
                                      ▼
                                 选中最优节点出网
SOCKS 出口 :11111 (供内部服务/调试用)
```

- **DNS 链路**：`:53 → 11401(dnsmasq) → 11501(chinadns) → 11311(dns2socks) → 1.1.1.1`
- **看门狗**：`watchdog-daemon.sh` 常驻 20s 轮询；`rc.local` 里 `sleep 180` 开机自愈
- **实时状态页**：`http://192.168.0.2:8888/pw-status/`

⚠️ **sing-box 配置坑位（版本相关）**：
- sing-box 1.13.14 **没有 `random` 组**（只有 `urltest`）→ 池只用 `urltest`
- 老配置里 `blackhole` 在新版要改成 `block`
- `dns2socks` 出站要 **3 个参数**（监听 / 上游 DNS / 出口标签），少一个起不来
- `vless-reality` 与 xray **不互通** → 池里统一只用 anytls，别混

### 2.4 NAS-ACL 修复（透明代理被架空）

NAS（`.114`）要走直连，但 nftables 的 `PSW_NAT/MANGLE` 里 `direct` 的 `return` **必须带源地址**，否则会把本该代理的流量也一起 return 掉，架空透明代理：

```
# 正确：direct 的 return 必须限定源
ip saddr 192.168.0.114 return
```

修复脚本挂 `rc.local`：`/mnt/mmc1-4/fix-passwall-nas-acl.sh`

---

### 2.5 实况核查：passwall 到底是"规则代理"还是"全局代理"？（2026-09-03）

**结论：都不是——它是 `disable` + ACL 驱动的「绕过中国大陆（chnroute 白名单）」准全局代理。**

#### 一、配置项实况

```sh
uci show passwall.@global[0] | grep -iE "proxy_mode"
# passwall.cfg023fd6.tcp_proxy_mode='disable'   ← 主引擎关闭
# passwall.cfg023fd6.udp_proxy_mode='disable'   ← 主引擎关闭
# passwall.cfg023fd6.dns_mode='xray'
# passwall.cfg023fd6.dns_redirect='1'
# passwall.cfg023fd6.chn_list='direct'
```

| ACL | 备注 | TCP | UDP | 源 |
|---|---|---|---|---|
| `@acl_rule[0]` | NAS-114-direct | `direct` | `direct` | 192.168.0.114 |
| `@acl_rule[1]` | cfg2730ec（默认，无源限制=全部设备） | **`proxy`** | **`proxy`** | 全部 |

即：**passwall 的全局开关是 `disable`，真正干活的是默认 ACL（cfg2730ec）生成的 nft 规则段。**

#### 二、`PSW_NAT`（TCP）实际判定顺序（带实测命中数）

| # | 规则 | 行为 | 命中 |
|---|---|---|---|
| 1 | `ip saddr 192.168.0.114 tcp` | return（NAS 直连） | — |
| 2 | `@psw_lan` | return | 179933 |
| 3-4 | `@psw_vps` / `@psw_wan` | return | 10 / 0 |
| 5 | `@psw_block` | drop | 0 |
| 6 | `@psw_white` | return | 2334 |
| 7 | 端口表 + `@psw_cfg1330ec_black` | redirect → `:11211` | 490 |
| 8 | 端口表 + `@psw_cfg1330ec_gfw` | redirect → `:11211` | **23098** |
| 9 | 端口表 + `@psw_chn` | **return（国内直连）** | **111238** |
| 10 | **端口表（无条件）** | **redirect → `:11211`（兜底全代理）** | **9713** |
| 11-17 | 「默认」段（`disable` 无代理规则） | return | 29195 |

**第 10 条是决定性的**：它没有任何 `daddr` 条件——凡是目的地不在内网/白名单/国内集合、且端口在表内的，**一律代理**。所以这不是 gfwlist「规则代理」（只在列表内才代理），而是**「非中国即代理」的 chnroute 白名单模式**。

#### 三、`PSW_MANGLE`（UDP）同理

```
udp daddr @psw_chn  return                       # 国内直连
udp daddr @psw_lan  return                       # 内网直连
udp（无条件）        tproxy → :11212              # 兜底全代理，15438 包  ← 我们加的 udp-all-proxy
udp dport 443 @psw_cfg1330ec_gfw  tproxy → :1041 # FB/IG QUIC，379 包   ← fix-ig-quic
```

#### 四、gfw 集合为什么那么大？

实测 `www.iana.org` / `www.kernel.org` / `ftp.debian.org` 三个与"翻墙"毫无关系的域名，解析出的 IP **都在 `@psw_cfg1330ec_gfw` 集合里**。
原因：chinadns-ng 走远端（代理）DNS 解析出的境外 IP，会被 `add-taggfw-ip` **动态打进 gfw 集合**。
→ 所以「经 N1 解析的境外域名」几乎必然落进 gfw 集合、走第 8 条代理；第 10 条兜底则覆盖**不经过 N1 DNS** 的情况（例如设备直接用 `.1` 解析、或 App 硬编码 IP）。

> ⚠️ 这也正是 3.6.2 那个坑的另一面：设备若用被投毒的 `.1` 解析，IP 虽会被第 10 条兜底代理，**但代理到一个根本不存在的假 IP 上，照样连不通**。

#### 五、⚠️ 一个真实缺口：端口白名单之外的端口不走代理

第 8/9/10 条都带端口表：

```
{ 22, 25, 53, 80, 143, 443, 465, 587, 853, 873, 993, 995, 5222, 8080, 8443, 9418 }
```

**不在这个表里的 TCP 端口一律不代理、直连**（会落到第 17 条 return）。
受影响的典型：FCM 推送 `5228`、STUN/TURN `3478`、部分游戏与 VoIP 端口、非标准 HTTPS 端口（如 `4443`）。
若某个 App"能连上但功能半残"，先查它用的端口在不在表里。

#### 六、一键自查命令

```sh
ssh root@192.168.0.2 '
uci show passwall.@global[0] | grep -iE "proxy_mode"
n=0; while uci show passwall.@acl_rule[$n] >/dev/null 2>&1; do
  echo "[$n] $(uci get passwall.@acl_rule[$n].remarks) tcp=$(uci get passwall.@acl_rule[$n].tcp_proxy_mode) udp=$(uci get passwall.@acl_rule[$n].udp_proxy_mode)"
  n=$((n+1)); done
nft list chain inet passwall PSW_NAT | grep -E "redirect|return|drop"
'
```

---

### 2.6 国内直连保障核查：「国内软件会不会偷跑我的机场流量？」（2026-09-03）

**结论：不会。已用实测确认国内流量不进代理。**

#### 一、架构上就是防泄漏的

`chn_list='direct'` + `PSW_NAT` 的 `@psw_chn return` 规则，配合「非中国即代理」的兜底规则（见 2.5），
等价于 **chnroute 白名单模式**——只有不在中国大陆 IP 段内的流量才会走机场。

#### 二、核查方法与实测结果

**1）`psw_chn` 是完整的大陆网段表（不是零散 IP）**

```sh
nft list set inet passwall psw_chn | head -6
#   type ipv4_addr
#   flags interval,timeout     ← interval = 存 CIDR 网段，能覆盖整个大陆
#   auto-merge
#   timeout 2d                 ← 集合默认，但元素实际 expires ≈ 362d
# 元素数: 6253
```

元素实测 `expires 362d11h10s156ms`（约一年），**不存在"2 天过期导致国内 IP 掉出集合、被误代理"的问题**。

**2）双向健全性检查**

| 方向 | 测试 | 结果 |
|---|---|---|
| 境外不应在国内集合 | `8.8.8.8` `1.1.1.1` `172.66.0.227` `57.144.64.34` `209.9.200.1` | 5/5 均**不在**集合 ✓ |
| 冷门国内 IP 应在集合 | `61.135.169.125` `202.108.22.5` `121.14.77.221` `218.60.32.1` `1.2.4.8` `211.98.2.4` `58.63.236.1` | 7/8 在集合（直连）✓ |
| 主流国内域名 | 百度/QQ/淘宝/京东/抖音/B站/知乎/163/美团/支付宝/微信/`i0.hdslb.com`/`gw.alicdn.com` | 13/13 全部直连 ✓ |

> `219.76.10.1` 是唯一未命中的，但该段很可能本就属境外（港/台），chnroute 只含大陆段，属预期行为。

**3）流量实测（决定性）**

用 `PSW_NAT` 里三条 `redirect to :11211` 的计数器做增量对比：

| 阶段 | 代理规则包数增量 |
|---|---|
| 空闲 12 秒（基线噪声，含全屋其他设备） | **+2 包** |
| 连续访问 7 个国内站点（百度/淘宝/京东/B站/163/微信/`gw.alicdn.com`） | **+1 包** ← 低于空闲噪声 |
| 对照：访问 3 个境外站点（Google/YouTube/X） | +3 包 |

**国内访问的代理增量（1 包）低于空闲噪声（2 包/12s）= 零泄漏。**

**4）UDP 同样不泄漏**

在 `PSW_MANGLE` 顶部插了一个纯计数探针（`udp-chn-probe`，不改变任何行为）：

```
访问国内（DNS 查 223.5.5.5 / 114.114.114.114 ×3 + 打开 B 站）
  国内 UDP 直连  +6 包
  走代理 UDP     +0 包   ← 零
```

另：`ip -6`/conntrack 里 UDP 目标按段聚合，绝大多数是 `192`（内网）/ `127`（本机）/ 国内段（`36`/`223`/`112`/`221`/`114`），无国内误代理迹象。

#### 三、以后自查（探针已持久化到 `fix-gfw-acl-set.sh`）

```sh
ssh root@192.168.0.2 '
echo "国内UDP直连: $(nft list chain inet passwall PSW_MANGLE | grep udp-chn-probe | grep -oE \"packets [0-9]+\")"
echo "走代理UDP  : $(nft list chain inet passwall PSW_MANGLE | grep udp-all-proxy  | grep -oE \"packets [0-9]+\")"
echo "走代理TCP  : $(nft list chain inet passwall PSW_NAT | grep \"redirect to :11211\" | grep -oE \"packets [0-9]+\")"
'
```

**判据**：访问国内站点期间，「走代理」的计数增量应接近 0（不高于空闲噪声）。

#### 四、残留的、需要注意的点

1. **国内域名解析到境外 IP 时仍会走代理**（如部分 CDN、阿里云国际、腾讯香港节点）。这是设计如此，无法避免。
2. **UDP 代理历史累计 14MB > TCP 代理 2.1MB**，主要是 QUIC（YouTube/Google 类）。若想省机场流量，可考虑把 QUIC 改回 drop（强制回退 TCP），代价是首包延迟变高。
3. 端口白名单外的端口（见 2.5）一律直连——对国内流量是好事，不消耗机场。

---

## 3. 📱 手机打不开 X 的完整排障案例（数据中心 IP 被风控）

这是最经典、最容易被误判的一案，完整复盘一遍，因为排查路径本身就有好几处坑。

### 3.1 现象

- Mac 能开 X（走本地 ClashX 代理），**手机打不开**
- 手机「网关」显示 `192.168.0.2`（正确）、「DNS」也是 `.2`（正确）
- 手机**浏览器和 App 都打不开**，开飞行模式重连也没用

### 3.2 逐层排查（以及每一步的误判与自我修正）

| 步 | 怀疑 | 验证动作 | 结果 | 结论 |
|----|------|----------|------|------|
| 1 | DNS 污染 | `dig` 主路由 `.1` 与 N1 `.2` 解析 x.com，各连测 10+ 次 | 两边**都干净**（`.1`→`172.66.0.227` 12/12；`.2`→`151.101.66.146` 8/8 一致）| ❌ 排除 |
| 2 | 透明代理没接管手机 | N1 上 `tcpdump -i br-lan host 手机IP` 抓包 | 手机**双向流量都经 N1**，TCP 连接成功、传了 ~700KB 数据 | ❌ 排除代理入口 |
| 3 | IPv6 绕过代理 | 查 N1 `br-lan` 地址 + 手机 IPv6 邻居 + x.com AAAA | N1 只有链路本地、手机无全局 IPv6、x.com 无 AAAA | ❌ 排除 |
| 4 | PassWall ACL 把手机旁路 | `uci show passwall` 看 ACL | 只有 NAS(`.114`) 是直连，手机落在 `proxy` 规则 | ❌ 排除 |
| 5 | **出口 IP 类型不对** | 对比 Mac(ClashX) 与 手机(N1 sing-box) 的出口 IP | 🎯 见下 | ✅ **命中根因** |

> 第 1 步里有个**自我修正**：一开始 `dig +short | grep IP` 把非 A 记录过滤掉，误以为主路由 `.1` 无应答（以为污染）。加 `+comments +stats` 一看其实是 NOERROR、有 ANSWER——**是自己的过滤命令骗了自己**，不是 DNS 问题。教训：`+short` 配 `grep` 会漏记录，验证 DNS 一定要看完整 ANSWER SECTION。

### 3.3 根因（一句话）

**X / Twitter 对「数据中心 IP」风控极严。** N1 的 sing-box 节点池是闲快机场的美国节点（出口 `167.253.96.177`，美国 BAGE CLOUD 数据中心）。手机连上了 TCP、也收到部分响应，但核心 API 请求全被拒 → 界面永远转圈 → 你看到的就是「打不开」。

而 Mac 走 ClashX 的**香港 HKT 家宽节点**（出口 `209.9.200.1`）→ X 正常放行。

佐证：同环境下 facebook 老段 IP 走代理能 200，但 twitter 老段 IP 全超时——X 的风控比 FB 严得多。

### 3.4 解决（切到香港家宽出口）

1. **拿节点**：闲快订阅源当时 502 不可用 → 改从 Mac 的 Clash Verge（小草莓机场）订阅里提取**香港家宽节点**（vless reality，`server=ooww.appcli.cc`），参数齐全且 Mac 正在用它（证明端口可达）。
2. **备份**：`cp pw-fo.json pw-fo.json.bak-$(date +%Y%m%d)`
3. **改配置**：把香港节点（香港家庭 / 香港01 / 香港02）加入 sing-box 池，与美国家庭节点组成 urltest 池，final 指向池。
4. **重启主实例**：`kill <主实例PID>` → 看门狗 20s 内自动拉起新配置（**不要手动 restart passwall**）。
5. **验证**：
   - 出口 IP → `209.9.200.1`（香港 HKT 家宽，与 Mac 一致）
   - `x.com` → **200**（0.7s）、twitter 老段 IP → **301**、google → **302**

> ✅ 切换后手机无需改任何设置，N1 透明代理自动走香港家宽出口，X 直接能开。

### 3.5 本案顺带发现的坑（都记下来）

- **机场节点域名会被 DNS 污染**：`xgbgpwww.appcli.cc` 被解析到假 IP `82.38.46.68`（英国），直连必超时。必须用**走代理的 DNS 通道**（`11311` dns2socks→1.1.1.1，或 Mac 的 ClashX 出口做 DoH）拿到真实 IP。
- **香港落地节点国内直连不可达**，但中转入口同 IP 段可达（服务器对裸 TCP 探测不响应，但对协议流量正常，所以 `nc` 测端口显示 CLOSED 是**误判**）。
- **N1 上 busybox `netstat` 显示不可靠**：核对监听端口用 `/proc/net/tcp` + 端口号十六进制（如 `11211` → `2BC3`、`11111` → `2B67`）。
- **`pkill -f "run -c /tmp/sb-test"` 会匹配到 ssh 自身 shell** 把会话杀掉 → 用 `pgrep` 拿精确 PID 再 `kill -9`。

### 3.6 手机打不开 Instagram（同网关 .2，但 QUIC 被默认 ACL gfw 集合 DROP）

现象：网关/DNS 都是 `.2`，`www.instagram.com` 能开，但 **IG App 打不开**（转圈/超时）。Mac（同网关）能连、手机不能——典型双端差异。

**根因（与 3.1 完全不同，别混）**：不是 DNS、不是出口 IP 类型、不是 IPv6 泄漏，而是 **Instagram 重度依赖 QUIC（UDP/443），而 PassWall 把「默认 ACL gfw 集合 `psw_cfg1330ec_gfw`」里的 UDP/443 流量直接 `drop`**。

排查关键证据链：
1. `dig api.i.instagram.com` 返回 **NXDOMAIN**——这是 IG 的 canary/探测域名（Facebook 权威 DNS 本就无此记录），**与打不开无关**，是干扰项；真正 API 域名是 `i.instagram.com`，N1 各 DNS 跳点都能解析出真实 FB IP `57.144.64.192`。
2. 强制走 sing-box HK 出口 `:11111` 时 `i.instagram.com` → HTTP=404（通）、FB/Twitter/Google/YouTube 全通 → **出口本身正常**，问题在透明代理的 QUIC 分流。
3. `nft list ruleset` 显示 `inet passwall PSW_MANGLE` 中存在 `ip daddr @psw_cfg1330ec_gfw udp dport 443 ... drop comment "cfg2730ec"`（已丢 126 包 / 220KB）。同集合 `psw_gfw` 的 QUIC 在另一规则是 `tproxy to :1041`（走代理）——**两条不对称**，FB/IG 的 QUIC 被静默丢弃，App 回退不及时即表现为打不开。
4. 注意：`.1`（TP-Link）作 DHCP 主 DNS 时 FB 域名曾被 GFW 污染（假 IP `108.160.169.186`）；但用户重置 TP-Link 并改好 DHCP 后 `.1` 已回到真实 FB IP，**所以本次根因是 QUIC 丢弃，不是 DNS**。Mac 只用 `.2` 所以一直正常。

**修复（零 reload、零 OOM 风险，仅 nft 运行时操作）**：
```sh
# 在 PSW_MANGLE 链顶部插入：FB/IG 的 QUIC 改走代理 :1041（与 psw_gfw 的 QUIC 处理对称）
nft insert rule inet passwall PSW_MANGLE \
  ip protocol udp udp dport 443 ip daddr @psw_cfg1330ec_gfw \
  counter meta mark set 0x50535731 tproxy ip to :1041 comment "fix-ig-quic"
```
验证：从内网发 UDP 包到 `57.144.64.192:443`，`fix-ig-quic` 计数器 `0 → 1`，证明命中、QUIC 已从「丢弃」转为「走代理」。

**持久化**：并入开机脚本 `/mnt/mmc1-4/fix-gfw-acl-set.sh`（rc.local `sleep 150` 后执行，幂等），新增 `fix-ig-quic` 块；同脚本原有的 TCP `fix-global-gfw` 与 QUIC `fix-quic-gfw` 块也顺便修了默认 ACL gfw 集合不填充的同类问题。

> ⚠️ **千万别**：为修 IG 去 `reload`/`restart passwall`——会 OOM 卡死 N1 全家断网。只用 `nft insert rule` 加运行时规则 + 开机脚本兜底。

### 3.6.1 根治修订（初版 `fix-ig-quic` 指向 `:1041` 实际不通）

初版把 FB/IG 的 QUIC 指向 `:1041`（sslocal），但实测 `:1041` / `xray :11201` 这两个 passwall 自带的 UDP 代理通道**对 X/IG 全部不通（curl 代理测试 `000`）**——它们是死通道。结果：IG 刷几条卡死、X 压根打不开（X 用 Cloudflare，IP `172.66.0.227` 不在 gfw 集合，QUIC 按默认 ACL 兜底直连被墙；而 TCP 走代理正常，所以 Mac 用 curl 测 X=200）。

**真正根因升级**：passwall 当前**完全没有可用的 UDP 代理出口**——sing-box 只配置了 TCP 入站（`:11211` redirect / `:11111` socks），没有任何 UDP 入站。所以所有 QUIC 流量要么直连被墙（X）、要么走死通道 `:1041`（IG 卡）。

**根治（一次性，已验证）**：给 sing-box 加一个 **UDP tproxy 入站 `:11212`**，让 QUIC 也走已验证健康的 sing-box 出口（HK 家宽），再把非国内 UDP 统一重定向过去。
1. 改 `/mnt/mmc1-4/pw-failover/pw-fo.json` 的 `inbounds`，追加：
   ```json
   { "type": "tproxy", "tag": "tproxy-udp", "listen": "0.0.0.0", "listen_port": 11212, "network": ["udp"] }
   ```
   （改完先 `sing-box check -c pw-fo.json` 校验；`kill` 主进程后看门狗会自动拉起，出口 IP 仍是 HK 家宽、TCP 代理不中断）
2. 在 `PSW_MANGLE` 链顶部插入全量 UDP 代理规则（国内/内网 UDP 直连、其余走 `:11212`）：
   ```sh
   nft insert rule inet passwall PSW_MANGLE ip protocol udp counter meta mark set 0x50535731 tproxy ip to :11212 comment "udp-all-proxy"
   nft insert rule inet passwall PSW_MANGLE ip protocol udp ip daddr @psw_lan return comment "udp-lan-return"
   nft insert rule inet passwall PSW_MANGLE ip protocol udp ip daddr @psw_chn return comment "udp-chn-return"
   ```
3. 验证：从内网发 QUIC 包到 X/IG 的 443，规则计数器增长（实测从 12 → 77 包，含真实手机流量）；X/IG App 恢复正常。

**持久化**：`udp-all-proxy` 块已并入 `/mnt/mmc1-4/fix-gfw-acl-set.sh`（rc.local `sleep 150` 执行，幂等）；`pw-fo.json` 的 `:11212` 入站已写盘。N1 重启后自动恢复。

> 这次教训：**排查 QUIC 要先确认 UDP 代理通道本身通不通**（`curl -x socks5h://127.0.0.1:<端口>` 实测），不能假设 passwall 自带的 `:1041` / `:11201` 一定可用。

---

### 3.6.2 真·根因（前面两版都被"假证据"带偏了）：**手机的 DNS 在 TP-Link 侧被 GFW 投毒**

做完 3.6 / 3.6.1 后 X 仍打不开、IG 刷几条就卡。重新排查才发现——**前面所有的"Mac 能通"结论全部是假证据**，真正的根因既不是 QUIC 也不是 N1 代理，而是手机的 DNS。

#### 一、为什么之前全判错了（三个连环坑，务必记牢）

**坑 1：Mac 上开着 Clash Verge（系统代理 127.0.0.1:7897）+ WorkBuddy 注入的 `HTTP_PROXY=127.0.0.1:61064`。**
`curl` 会读这些环境变量，所以每次"实测 X = 200"走的都是**本机代理，根本没经过 N1 的透明代理**。
→ **排障前必须先确认测试机没有本地代理**：

```sh
env | grep -i proxy
networksetup -getwebproxy Wi-Fi     # macOS 系统代理
ps aux | grep -i clash
```

**坑 2：`curl --resolve` 在走代理时完全失效。**
走 HTTP 代理时 curl 发的是 `CONNECT`，域名由**远端**解析，本地 `--resolve` 指定的 IP 根本不生效。
所以 3.6 里"逐个验证 `.1` 解析出的 IP 都可达（301/404/500/200/204）"是**幻觉**——实际测的是远端代理自己的解析结果。

**坑 3：判断 IP 真假，必须走"无本地代理"的真实路径。**

```sh
env -u HTTP_PROXY -u HTTPS_PROXY -u http_proxy -u https_proxy \
  curl --noproxy '*' -4 --max-time 7 -s -o /dev/null -w "%{http_code}\n" \
  --resolve <域名>:443:<待测IP> https://<域名>/
```

#### 二、真·根因：手机主 DNS 是 TP-Link（192.168.0.1），被 GFW 投毒

TP-Link 是唯一的 DHCP 服务器（N1 的 `dhcp.lan.ignore='1'`），下发给手机的**主 DNS 是 192.168.0.1**。
手机查 `.1` 时是**二层直连 TP-Link 的 MAC，数据包根本不经过 N1**，所以 N1 上加任何 nft 劫持规则都无效。
TP-Link 用南京移动上游 DNS，对境外域名返回 **GFW 投毒 IP**（稳定复现，非偶发）：

| 域名 | `.1` 解析（投毒，全死 `HTTP=000`） | `.2` 解析（N1 干净，全通） |
|---|---|---|
| `twitter.com` | `104.244.42.197` ✗ | `172.66.0.227` → 301 ✓ |
| `api.x.com` | `205.186.152.122` ✗ | `162.159.140.229` → 404 ✓ |
| `www.instagram.com` | `103.246.246.144` ✗ | `57.144.98.34` → 200 ✓ |
| `i.instagram.com` | `69.171.229.11` ✗ | `57.144.98.192` → 500 ✓ |
| `edge-chat.instagram.com` | `93.179.102.140` ✗ | `57.144.98.192` → 404 ✓ |
| `scontent.cdninstagram.com` | `199.16.156.75` ✗ | `57.144.64.192` → 204 ✓ |

投毒 IP 段特征：`103.246.246.x`、`93.179.102.x`、`205.186.152.x`、`128.242.240.x`——**注意有些就落在 Facebook/Twitter 的真实 ASN 段内**（如 `104.244.42.0/24` 是 Twitter 自有段），所以**光看 IP 归属判断真假会误判，必须实测连通性**。

> 顺带：**IPv6 泄漏已排除**（全网 0 条全局 v6 邻居；TP-Link 虽发 RA 但无全局前缀）；
> **QUIC 通道已确认可用**（`ip rule` 有 `fwmark 0x50535731 lookup 999`，`table 999` 有 `local default dev lo`）。

#### 三、修复：必须在 **TP-Link 侧**改（N1 单方面修不了）

DNS 查询是二层直达 TP-Link，N1 劫持不到。**不要**用 proxy-ARP 抢 `192.168.0.1`，会打断 TP-Link 管理并引发全网震荡。

1. **（治本）TP-Link DHCP 下发 DNS 改为 N1**
   路由管理页 → **DHCP 服务器** → 首选 DNS `192.168.0.2`，备用 DNS `192.168.0.2`（**两个都填 .2**；备用不要填 `223.5.5.5` 之类，否则手机回退过去照样被投毒）。
2. **（双保险）TP-Link 自身上游 DNS 也改成 N1**
   **上网设置 / WAN 口设置** → 手动 DNS → `192.168.0.2`。这样即便设备仍指向 `.1`，TP-Link 也会转发给 N1 的干净 DNS。
3. **手机刷新租约**：改完后开关一次飞行模式，或"忽略此网络"后重连（旧租约可能还缓存着 `.1`）。
4. **在手机上核对**：WiFi → 点击当前网络 → **路由器** 应为 `192.168.0.2`，**DNS** 应为 `192.168.0.2`。

> 想彻底省事，可关掉 TP-Link 的 DHCP、改由 N1 下发（`uci set dhcp.lan.ignore=0`），单 DHCP 更干净——但同样要动 TP-Link，不如直接改 DNS 字段来得快。

#### 四、一句话总结

**网关对了不等于 DNS 对了。** 网关 `.2` 只保证流量过 N1；DNS 指向被投毒的 `.1`，手机拿到假 IP 仍会连不上。
排障铁律：**先确认测试机无本地代理，再用真实路径逐个实测域名解析出的 IP**。

---

## 4. Home Assistant

### 4.1 部署

- Docker **host 网络**，配置目录 `/mnt/mmc1-4/homeassistant`
- SSH：`root` / <密码见本地，勿入公库>

### 4.2 改 `.storage` 必须先停容器（P0，见硬规则 #3）

HA 退出时会把内存态写回 `.storage/*.json`。**任何直接改 `.storage` 文件的操作，必须先 `docker stop homeassistant`**，改完再起，否则白改。

### 4.3 xiaomi_home 集成（米家）

- ⚠️ **无 reauth 流程** → token 失效只能删 config entry 重授权。曾因 `96009 invalid refresh token` 一次挂掉 525 个实体。
- 重新授权用 `http://192.168.0.2:8123`（**`homeassistant.local` 解析不了**，别用于 OAuth 回调地址）。
- 小米 API 域名（`account.xiaomi.com` / `home.mi.com` 等）走 `psw_chn` **直连**，不受代理影响。
- 控制码 `ctrl_mode=auto`（本地优先 → 云端兜底）。
- 命令失败码 `-30012` / `-9999` = 传输/设备层无法送达（设备离线或本地控制未建立），**不是 HomeKit 问题**。
- 健康接入状态页：`http://192.168.0.2:8888/pw-status/`（探活 8123 + 日志匹配 `invalid refresh token` + config entry 存在性）。

### 4.4 HomeKit 桥（唯一对外语音/控制通道）

- 监听 `192.168.0.2:21063`，mDNS 名 `Home Assistant Bridge 6D194F`。
- **配对码每次 HA 重启随机生成**，在 HA 日志里（`logger: homeassistant.components.homekit: info`）。`paired_clients` 会保留 → iPhone 免重配。
- 暴露实体 ID 硬编码在 `homekit.<id>.options.filter.include_entities`，由 `厂商_cn_did_型号` 生成、**与 config entry 无关** → 重加小米集成后 ID 一致 → 自动回 HomeKit。
- **重置小米集成时 HomeKit 安全做法**：删 xiaomi config entry + 清 `.storage/xiaomi_home/cert/` 后干净重启，桥暴露列表不动。

---

## 5. 工作站门户（nginx, `192.168.0.2:8888`）

- `nginx:alpine`，反向代理 LuCI / HA / MC。
- ⚠️ **CSP 必须含** `script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'`，否则页面脚本被拦。
- 重部署：`sh /mnt/mmc1-4/workstation/deploy.sh`
- 实时状态 `/api/status` ← `status-gen.sh`（rc.local 每 5s）→ `status.json`
- UI 方向：Apple **Liquid Glass** 玻璃拟态 + hover 缩放 + 点击涟漪式分层反馈。

---

## 6. Outline Server（Shadowbox, arm64）

- API 端口设为 **`19001`** 规避 PassWall 抢占（默认 1xxxx 会被代理逻辑吃到）。
- 用 arm64 社区镜像；部署在 N1 上作独立 VPN 通道。

---

## 7. 每日备份

- `/usr/local/bin/backup-to-nas.sh` 每 05:00 自动把 NAS 日志备份至 `/mnt/nas/n1-backup`。
- 改 N1 配置后每日 03:15 自动同步 overlay（无需手动）。

---

## 8. 磁盘拓扑与备份

```
/dev/sda        = U 盘（原启动盘，保留回退，勿删 sda4 / n1-emmc-backup）
/dev/mmcblk1    = eMMC（p4 = /mnt/mmc1-4 存 HA / docker / 配置）
备份位置：/mnt/mmc1-4/backup/、backup-n1/
```

> 回退策略：U 盘保留作「系统挂了能拔盘恢复原厂」的保命盘，别手痒格式化。

---

## 9. 总踩坑清单（P0 ~ P2）

| 严重度 | 坑 | 症状 | 正确做法 |
|--------|----|------|----------|
| **P0** | N1 跑 Minecraft/amd64 服务 | 全家断网 | 绝不部署，MC 移走 |
| **P0** | 执行 `install-to-emmc.sh` | eMMC 引导区被 dd、HA/docker 数据全没 | 禁用该脚本 |
| **P0** | 不停 HA 容器就改 `.storage` | 改动被内存态覆盖丢失 | 先 `docker stop homeassistant` |
| **P0** | passwall 热重载 | OOM 卡死 N1 | 只 `uci commit`，物理重启冷启 |
| **P1** | 设备网关不是 N1 | 国内通、境外 App 不通 | DHCP 网关/DNS 改 `.2` |
| **P1** | 节点池出口是数据中心 IP | X/Twitter 打不开（TCP 通但请求被拒）| 换香港/家宽节点 |
| **P1** | 机场域名被 DNS 污染 | 节点连不上/超时 | 走代理 DNS 解析真实 IP |
| **P1** | xiaomi_home token 失效 | 几百实体全挂 | 删 config entry 重授权（无 reauth）|
| **P2** | `dig +short\|grep` 验证 DNS | 误以为污染（漏非 A 记录）| 看完整 ANSWER SECTION |
| **P2** | busybox netstat 不可靠 | 误判端口未监听 | 查 `/proc/net/tcp` + hex 端口 |
| **P2** | `pkill -f` 匹配到 ssh 自身 | 会话被杀 | 用精确 PID |
| **P2** | sing-box 版本差异 | `random` 组/`blackhole` 报错 | 只用 `urltest`、`block` |
| **P2** | NAS-ACL direct 漏源地址 | 透明代理被架空 | return 带 `ip saddr 192.168.0.114` |

---

## 10. 常用命令速查

```sh
# —— N1 健康检查 ——
ssh root@192.168.0.2 'uptime; free -m | head -3; pgrep -c sing-box'
# 透明代理入口监听 (11211=0x2BC3, 11111=0x2B67)
ssh root@192.168.0.2 "grep -iE '2BC3|2B67' /proc/net/tcp"

# —— 代理出口 IP / X 可达性（走 sing-box SOCKS :11111）——
ssh root@192.168.0.2 "curl -x socks5h://127.0.0.1:11111 -s https://ipinfo.io/json"
ssh root@192.168.0.2 "curl -x socks5h://127.0.0.1:11111 -s -o /dev/null -w '%{http_code}' https://x.com"

# —— 切节点流程 ——
ssh root@192.168.0.2 "cp /mnt/mmc1-4/pw-failover/pw-fo.json /mnt/mmc1-4/pw-failover/pw-fo.json.bak-\$(date +%Y%m%d)"
# (编辑 pw-fo.json 加入家宽节点 →) kill 主实例 PID，等看门狗拉起

# —— DNS 污染验证（看完整 ANSWER，别只 grep IP）——
dig @192.168.0.1 x.com +comments +stats        # 主路由
dig @192.168.0.2 x.com +comments +stats        # N1

# —— 手机流量抓包 ——
ssh root@192.168.0.2 "tcpdump -i br-lan -nn host <手机IP> -w /tmp/phone.pcap"

# —— HA 安全改配置 ——
ssh root@192.168.0.2 "docker stop homeassistant && vi /mnt/mmc1-4/homeassistant/.storage/xxx && docker start homeassistant"
```

---

## 附录：本文与其他文档的关系

- `README.md`：刷机 → iStoreOS → 旁路由**初始化**（macOS 视角）
- `docs/troubleshooting.md`：初始化阶段的 macOS / 网络坑
- **`docs/n1-ops-guide.md`（本篇）**：N1 **上线后**各项功能运维、过程与踩坑

欢迎 PR 补充你自己的坑。
