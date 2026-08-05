#!/bin/bash
# 下载并解压最新 iStoreOS N1 镜像（macOS）
# 用法：bash download_image.sh [输出路径，默认 ~/Downloads/istoreos_n1.img]
set -e

OUT="${1:-$HOME/Downloads/istoreos_n1.img}"

# 镜像地址可能随版本更新而变动；若 404 去 https://fw.koolcenter.com/iStoreOS/alpha/n1/ 找最新
URL="https://fw.koolcenter.com/iStoreOS/alpha/n1/istoreos-24.10.7-2026060510-phicomm_n1-squashfs.img.gz"

echo ">>> 下载镜像: $URL"
curl -L --retry 3 -o "$OUT.gz" "$URL"

echo ">>> 解压..."
gunzip -f "$OUT.gz" || true   # "trailing garbage ignored" 属正常，不影响完整性

echo ">>> 校验镜像完整性:"
python3 - <<PY
import os, sys
f = "$OUT"
if not os.path.exists(f):
    print("  镜像文件不存在:", f); sys.exit(1)
d = open(f, 'rb').read()
print("  MBR 签名 55AA :", d[510:512] == b'\x55\xaa')
print("  squashfs 魔数 hsqs :", b'hsqs' in d)
print("  大小 (MiB) :", round(os.path.getsize(f) / 1048576, 1))
PY

echo ">>> 完成 -> $OUT"
