#!/usr/bin/env bash
# 下载最新的 geoip.dat / geosite.dat（Loyalsoldier 加强版）到本脚本所在目录
# 用法：
#   bash v2ray/update_geo.sh                        # 直连下载
#   bash v2ray/update_geo.sh http://127.0.0.1:1082  # 通过代理下载
# 下载完成后按 system_file_location.md 中的路径复制到各平台

set -u

BASE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"
DIR="$(cd "$(dirname "$0")" && pwd)"
PROXY="${1:-}"

for f in geoip.dat geosite.dat; do
    echo "Downloading $f ..."
    tmp="$DIR/$f.tmp"
    if curl --fail --location --silent --show-error ${PROXY:+--proxy "$PROXY"} --output "$tmp" "$BASE/$f" && [ -s "$tmp" ]; then
        # 下载成功后才替换旧文件
        mv -f "$tmp" "$DIR/$f"
        echo "  saved to $DIR/$f"
    else
        rm -f "$tmp"
        echo "[ERROR] failed to download $f, existing file kept" >&2
        exit 1
    fi
done

echo "Done!"
