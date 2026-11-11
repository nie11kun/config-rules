#!/bin/bash
# 用法：
#   bash gfwlist.sh [代理] [输出文件]
#   bash gfwlist.sh                                     # 直连下载，输出到默认位置
#   bash gfwlist.sh http://127.0.0.1:1082               # 通过代理下载
#   bash gfwlist.sh "" /tmp/proxy-gfwlist.conf          # 不用代理，输出到指定文件
# 默认输出位置：
#   在 OpenWrt 上运行（存在 /etc/openwrt_release）：/etc/dnsmasq/proxy-gfwlist.conf
#   其他系统（在仓库里运行）：脚本目录/../config/dnsmasq mode/dnsmasq/proxy-gfwlist.conf
# OpenWrt 上由 v2ray-update.sh 每天自动调用，更新后会重启 dnsmasq
#
# 此脚本功能：
# 1. 下载 https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt 到临时文件
# 2. 检查下载是否成功、文件是否为空
# 3. 添加头部信息，并对每行进行转换，生成格式为：
#    nftset=/<域名>/4#ip#v2ray#gfwlist
# 4. 检查生成的规则数量，正常后再替换目标文件（UTF-8 编码，无 BOM）
# 5. 删除临时文件

URL="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROXY="${1:-}"
if [ -n "${2:-}" ]; then
    DEST="$2"
elif [ -f /etc/openwrt_release ]; then
    DEST="/etc/dnsmasq/proxy-gfwlist.conf"
else
    DEST="$SCRIPT_DIR/../config/dnsmasq mode/dnsmasq/proxy-gfwlist.conf"
fi
TMPFILE="$(mktemp)"
OUTFILE="$(mktemp)"
trap 'rm -f "$TMPFILE" "$OUTFILE"' EXIT

# 生成的规则少于这个数量就认为下载内容不对，不替换目标文件（正常约 2.7 万条）
MIN_RULES=1000

# 定义需要跳过的完整域名列表（仅当完全匹配时跳过）
SKIP_DOMAINS=("apple.com" "qq.com")

echo "Downloading: ${URL}"
echo "Saving to: ${DEST}"
echo ""

# 优先用 curl；OpenWrt 默认没有 curl，则用系统自带的 wget（uclient-fetch，通过环境变量使用代理）
if [ -z "$PROXY" ]; then
    echo "No proxy..."
else
    echo "Using proxy: ${PROXY}"
fi
if command -v curl > /dev/null 2>&1; then
    curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 \
        ${PROXY:+--proxy "$PROXY"} --output "$TMPFILE" "$URL"
else
    http_proxy="$PROXY" https_proxy="$PROXY" wget -q -T 30 -O "$TMPFILE" "$URL"
fi
if [ $? -ne 0 ]; then
    echo "[ERROR] download failed!"
    exit 1
fi

# 检查临时文件是否为空
if [ ! -s "$TMPFILE" ]; then
    echo "[ERROR] downloaded file is empty!"
    exit 1
fi

echo "Processing lines..."

# 写入处理后的内容到临时输出文件：
# 1. 先写入固定的头部
# 2. 再逐行读取 TMPFILE，并对非空行生成 "nftset=/<行内容>/4#ip#v2ray#gfwlist"
{
  echo "# 更新自：https://github.com/Loyalsoldier/v2ray-rules-dat"
  echo "# 同步最新发布 proxy-list：https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/proxy-list.txt"
  echo "# proxy list 比 gfwlist 更全"
  echo "#"
  while IFS= read -r line || [ -n "$line" ]; do
      # 去除可能存在的 \r 回车符
      line="${line%$'\r'}"
      # 跳过 regexp: 开头的行
      case "$line" in regexp:*) continue ;; esac
      # 去除 full: 前缀
      line="${line#full:}"

      # 检查是否在需要跳过的域名列表中（完全匹配）
      skip=false
      for domain in "${SKIP_DOMAINS[@]}"; do
          if [ "$line" = "$domain" ]; then
              skip=true
              break
          fi
      done
      if [ "$skip" = true ]; then
          continue
      fi

      if [ -n "$line" ]; then
          echo "nftset=/${line}/4#ip#v2ray#gfwlist"
      else
          echo ""
      fi
  done < "$TMPFILE"
} > "$OUTFILE"

RULES="$(grep -c '^nftset=' "$OUTFILE")"
if [ "$RULES" -lt "$MIN_RULES" ]; then
    echo "[ERROR] only $RULES rules generated (expected >= $MIN_RULES), $DEST not changed"
    exit 1
fi

# 先写到同目录的临时文件再改名，避免 dnsmasq 读到写了一半的文件
mkdir -p "$(dirname "$DEST")"
cat "$OUTFILE" > "$DEST.tmp" && mv -f "$DEST.tmp" "$DEST" || { echo "[ERROR] failed to write $DEST"; exit 1; }

echo "$RULES rules written."
echo "Done!"
exit 0
