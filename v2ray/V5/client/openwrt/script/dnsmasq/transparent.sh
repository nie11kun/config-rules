#!/usr/bin/env bash

# 配合 dnsmasq 对需要代理的域名和ip地址走 redirect 的 nftables 规则 需要安装 dnsmasq-full
# v2ray dokodemo-door 需要设置 "tproxy": "redirect"

# 先删除上一次运行留下的表，保证脚本可重复执行（nft add rule 每执行一次都会追加一份，重启服务时规则会叠加）
# 注意：表删除重建后，dnsmasq 之前动态加入 gfwlist 的 IP 会清空，需等对应域名重新解析后才会再加入
nft delete table ip v2ray 2>/dev/null

# 新建路由表
nft add table ip v2ray

# 添加 set 表
nft add set ip v2ray gfwlist { type ipv4_addr \; flags interval \; }

# 读取文件中的 ip 地址到 gfwlist 表中（跳过空行和 # 开头的注释行）
for ip in $(awk 'NF && $1 !~ /^#/ {print $1}' /etc/dnsmasq/proxy_ip.txt);
    do nft add element ip v2ray gfwlist { $ip };
done

# 局域网流量转发
# 局域网流量目标地址是外部地址时传输路径为 prerouting -> forward -> postrouting hooks
nft add chain ip v2ray prerouting { type nat hook prerouting priority 0 \; policy accept \; }
nft add rule ip v2ray prerouting ip daddr @gfwlist ip protocol tcp redirect to 1081
# 阻止 QUIC 流量
nft add rule ip v2ray prerouting udp dport { 80, 443 } drop

# 本机网关流量转发
# 本机网关流量目标地址时外部地址时传输路径为 本机 -> output -> postrouting hooks
nft add chain ip v2ray output { type nat hook output priority 0 \; policy accept \; }
nft add rule ip v2ray output ip daddr @gfwlist ip protocol tcp redirect to 1081
# 阻止 QUIC 流量
nft add rule ip v2ray output udp dport { 80, 443 } drop
