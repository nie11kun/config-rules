# 配合 dnsmasq 对需要代理的域名和ip地址走 redirect 的 nftables 规则 需要安装 dnsmasq-full
# v2ray dokodemo-door 需要设置 "tproxy": "redirect"

# 阻止 QUIC 流量
nft add rule inet fw4 input udp dport 443 drop
nft add rule inet fw4 forward udp dport 443 drop
nft add rule inet fw4 output udp dport 443 drop

# 新建路由表
nft add table ip v2ray

# 添加 set 表
nft add set ip v2ray gfwlist { type ipv4_addr \; flags interval \; }

# 读取读取文件中的 ip 地址到 gfwlist 表中
for ip in $(awk '{print $1}' /etc/dnsmasq/proxy_ip.txt);
    do nft add element ip v2ray gfwlist { $ip };
done

# 局域网流量转发
# 局域网流量目标地址是外部地址时传输路径为 prerouting -> forward -> postrouting hooks
nft add chain ip v2ray prerouting { type nat hook prerouting priority 0 \; policy accept \; }
nft add rule ip v2ray prerouting ip daddr @gfwlist ip protocol tcp redirect to 1081

# 本机网关流量转发
# 本机网关流量目标地址时外部地址时传输路径为 本机 -> output -> postrouting hooks
nft add chain ip v2ray output { type nat hook output priority 0 \; policy accept \; }
nft add rule ip v2ray output ip daddr @gfwlist ip protocol tcp redirect to 1081
