#!/bin/bash
# N1 iStoreOS 写盘脚本（Mac 版，自动识别 U 盘，兼容系统自带 bash 3.2）
# 用法：sudo bash write_n1_reset.sh [镜像路径，默认 ~/Downloads/istoreos_n1.img]
# 作用：把 iStoreOS 镜像写入外置 U 盘，重置为默认密码（password / 空）
set -e

IMG="${1:-$HOME/Downloads/istoreos_n1.img}"

echo "=================================================="
echo " N1 iStoreOS 重置写盘工具（Mac）"
echo "=================================================="

if [ ! -f "$IMG" ]; then
  echo "找不到镜像: $IMG"
  echo "请先运行 scripts/download_image.sh 下载，或把镜像路径作为参数传入。"
  exit 1
fi

# 找出所有外置物理盘（排除内置 disk0），兼容 bash 3.2（不用 mapfile / 数组）
EXT_LIST=$(diskutil list 2>/dev/null | grep -oE '/dev/disk[0-9]+ \(external, physical\)' | grep -oE 'disk[0-9]+')
EXT_LIST=$(echo "$EXT_LIST" | grep -v '^$')
COUNT=$(echo "$EXT_LIST" | grep -c .)

if [ "$COUNT" -eq 0 ]; then
  echo "没找到任何外置 U 盘。请确认 U 盘已插入 Mac 的 USB 口。"
  exit 1
fi

if [ "$COUNT" -gt 1 ]; then
  echo "检测到多块外置盘，请只保留目标 U 盘，避免误写："
  for d in $EXT_LIST; do
    echo "  $d  $(diskutil info "$d" 2>/dev/null | awk -F': ' '/Disk Size/{print $2}')"
  done
  exit 1
fi

DISK="$EXT_LIST"
RAW=$(echo "$DISK" | sed 's/disk/rdisk/')

echo "镜像文件 : $IMG"
echo "目标磁盘 : /dev/$DISK  (裸设备 /dev/$RAW)"
echo "磁盘容量 : $(diskutil info "$DISK" 2>/dev/null | awk -F': ' '/Disk Size/{print $2}')"
echo
echo "⚠️  此操作会【完全清空】/dev/$DISK，重置为默认密码（原 U 盘配置将丢失）。"
echo "    内置磁盘 disk0 (Macintosh HD) 不会被触碰。"
echo -n "确认把镜像写入 /dev/$DISK 吗？（输入 YES 继续，其它取消）: "
read ans
if [ "$ans" != "YES" ]; then
  echo "已取消，未做任何改动。"
  exit 1
fi

echo ">>> 1/3 卸载磁盘 /dev/$DISK ..."
diskutil unmountDisk "/dev/$DISK" 2>/dev/null || true

echo ">>> 2/3 写入镜像到 /dev/$RAW （请耐心等待，无进度条属正常）..."
dd if="$IMG" of="/dev/$RAW" bs=4m conv=sync status=progress

echo ">>> 3/3 推出磁盘 /dev/$DISK ..."
diskutil eject "/dev/$DISK"

echo
echo "完成！拔出 U 盘，插到斐讯 N1 靠近 HDMI 的 USB 口，先插 U 盘再通电开机。"
echo "开机后从路由器后台看 N1 拿到的新 IP，用 root / password 登录即可。"
