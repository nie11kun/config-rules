#!/bin/bash
# bash '/Users/marconie/Development/VPN/config-rules/v2ray/V5/client/openwrt/script/gfwlist.sh'
# 此脚本功能：
# 1. 下载 https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt 到临时文件
# 2. 检查文件是否存在及是否为空
# 3. 添加头部信息，并对每行进行转换，生成格式为：
#    nftset=/<域名>/4#ip#v2ray#gfwlist
# 4. 将结果写入目标文件（确保使用 UTF-8 编码，无 BOM）
# 5. 删除临时文件

# 定义 URL、目标文件和临时文件路径
URL="https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt"
DEST="v2ray/V5/client/openwrt/config/dnsmasq mode/dnsmasq/proxy-gfwlist.conf"
PROXY="$1"
TMPFILE="temp_download.txt"

echo "Downloading: ${URL}"
echo "Saving to: ${DEST}"
echo ""

# 如果未提供代理参数，直接下载；否则带代理下载
if [ -z "$PROXY" ]; then
    echo "No proxy..."
    curl --silent --output "$TMPFILE" "$URL"
else
    echo "Using proxy: ${PROXY}"
    curl --silent --proxy "$PROXY" --output "$TMPFILE" "$URL"
fi

# 检查临时文件是否存在
if [ ! -f "$TMPFILE" ]; then
    echo "[ERROR] \"$TMPFILE\" not found!"
    exit 1
fi

# 检查临时文件是否为空
if [ ! -s "$TMPFILE" ]; then
    echo "[ERROR] \"$TMPFILE\" is empty!"
    rm -f "$TMPFILE"
    exit 1
fi

echo "Processing lines..."

# 创建目标文件所在目录（如果不存在）
mkdir -p "$(dirname "$DEST")"

# 写入处理后的内容到目标文件：
# 1. 先写入固定的头部
# 2. 再逐行读取 TMPFILE，并对非空行生成 "nftset=/<行内容>/4#ip#v2ray#gfwlist"
{
  echo "# 更新自：https://github.com/Loyalsoldier/v2ray-rules-dat"
  echo "# 同步最新发布 gfwlist：https://raw.githubusercontent.com/Loyalsoldier/v2ray-rules-dat/release/gfw.txt"
  echo "#"
  while IFS= read -r line; do
      if [ -n "$line" ]; then
          echo "nftset=/${line}/4#ip#v2ray#gfwlist"
      else
          echo ""
      fi
  done < "$TMPFILE"
} > "$DEST"

# 删除临时文件
rm -f "$TMPFILE"

echo "Done!"
exit 0