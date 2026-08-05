#!/bin/bash
# 在 Mac 上扫描局域网，定位斐讯 N1（接路由器 / DHCP 场景）
# 用法：bash discover_n1.sh
# 说明：对 Mac 各网卡所在私网段做 ping 探测，列出在线设备，方便你从路由器外再核一次。

echo "========== 1. 本机活动网卡与 IP =========="
for if in $(ifconfig -l); do
  ip=$(ipconfig getifaddr "$if" 2>/dev/null)
  [ -n "$ip" ] && echo "  $if -> $ip"
done

echo; echo "========== 2. 默认网关 =========="
gw=$(route -n get default 2>/dev/null | awk '/gateway/{print $2}')
echo "  网关: ${gw:-未知}"

# 收集要扫描的私有网段（/24）
subnets=""
for if in $(ifconfig -l); do
  ip=$(ipconfig getifaddr "$if" 2>/dev/null)
  case "$ip" in
    192.168.*|10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|169.254.*)
      net=${ip%.*}; subnets="$subnets $net" ;;
  esac
done
subnets=$(echo "$subnets" | tr ' ' '\n' | sort -u | tr '\n' ' ')

echo; echo "========== 3. 扫描网段（并行 ping）=========="
echo "  网段:$subnets"
for net in $subnets; do
  for i in $(seq 1 254); do
    ping -c1 -t1 "$net.$i" >/dev/null 2>&1 &
  done
  wait
done

echo; echo "========== 4. 在线设备（ARP 表）=========="
arp -a 2>/dev/null | sed 's/^/  /'

echo; echo "========== 完成 =========="
echo "提示：N1 常表现为 OpenWrt/iStoreOS 设备，主机名可能含 openwrt / istoreos /"
echo "      phicomm。也可去路由器后台 DHCP 列表按 MAC 厂商核对。"
