# 配合 dnsmasq 对需要代理的域名和ip地址走 tproxy 的 iptables 规则
# 可以避免全局透明代理时 v2ray router 中基于域名的规则都无效的问题
# 使用此模式可以精简 v2ray config 配置，只需要保留进入的流量都走 vmess 出口即可 dns 只保留 1.1.1.1 即可 防止域名污染

ip route add local default dev lo table 100
ip rule add fwmark 1 table 100

ipset -X gfwlist
ipset create gfwlist hash:ip

ipset -X gfwlist_ext
ipset create gfwlist_ext hash:net
for ip in $(cat /etc/dnsmasq/proxy_ip.txt);
    do ipset add gfwlist_ext $ip;
done

iptables -t mangle -A OUTPUT -j RETURN -m mark --mark 0x02 #防止v2ray处理过的流量回环 需放在第一句最先判断 v2ray outbound 中需要设置 mark 2

iptables -t mangle -A PREROUTING -p tcp -m set --match-set gfwlist dst -j TPROXY --on-port 1081 --tproxy-mark 1
iptables -t mangle -A PREROUTING -p udp -m set --match-set gfwlist dst -j TPROXY --on-port 1081 --tproxy-mark 1
iptables -t mangle -A OUTPUT -p tcp -m set --match-set gfwlist dst -j MARK --set-mark 1
iptables -t mangle -A OUTPUT -p udp -m set --match-set gfwlist dst -j MARK --set-mark 1

iptables -t mangle -A PREROUTING -p tcp -m set --match-set gfwlist_ext dst -j TPROXY --on-port 1081 --tproxy-mark 1
iptables -t mangle -A PREROUTING -p udp -m set --match-set gfwlist_ext dst -j TPROXY --on-port 1081 --tproxy-mark 1
iptables -t mangle -A OUTPUT -p tcp -m set --match-set gfwlist_ext dst -j MARK --set-mark 1
iptables -t mangle -A OUTPUT -p udp -m set --match-set gfwlist_ext dst -j MARK --set-mark 1