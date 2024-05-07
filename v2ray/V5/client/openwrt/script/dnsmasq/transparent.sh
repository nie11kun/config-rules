# 配合 dnsmasq 对需要代理的域名和ip地址走 redirect 的 nftables 规则 需要安装 dnsmasq-full
# v2ray dokodemo-door 需要设置 "tproxy": "redirect"
# 只能接收局域网设备流量 本机网关流量不转发

# 新建路由表
nft add table v2ray

# 添加 set 表
nft add set ip v2ray gfwlist { type ipv4_addr\; }

# 读取读取文件中的 ip 地址到 gfwlist 表中
for ip in $(cat /etc/dnsmasq/proxy_ip.txt);
    do nft add element ip v2ray gfwlist { $ip };
done

nft add chain v2ray prerouting { type nat hook prerouting priority 0 \; policy accept \; }
nft add rule v2ray prerouting ip daddr @gfwlist ip protocol tcp redirect to :1081
