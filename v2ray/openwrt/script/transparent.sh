ip route add local default dev lo table 100
ip rule add fwmark 1 table 100

ipset -X gfwlist
ipset create gfwlist hash:ip

ipset -X gfwlist_ext
ipset create gfwlist_ext hash:net
for ip in $(cat /etc/dnsmasq/proxy_ip.txt);
    do ipset add gfwlist_ext $ip;
done

iptables -t mangle -A PREROUTING -p tcp -m set --match-set gfwlist dst -j TPROXY --on-port 1081 --tproxy-mark 1
iptables -t mangle -A PREROUTING -p udp -m set --match-set gfwlist dst -j TPROXY --on-port 1081 --tproxy-mark 1
iptables -t mangle -A OUTPUT -p tcp -m set --match-set gfwlist dst -j MARK --set-mark 1
iptables -t mangle -A OUTPUT -p udp -m set --match-set gfwlist dst -j MARK --set-mark 1

iptables -t mangle -A PREROUTING -p tcp -m set --match-set gfwlist_ext dst -j TPROXY --on-port 1081 --tproxy-mark 1
iptables -t mangle -A PREROUTING -p udp -m set --match-set gfwlist_ext dst -j TPROXY --on-port 1081 --tproxy-mark 1
iptables -t mangle -A OUTPUT -p tcp -m set --match-set gfwlist_ext dst -j MARK --set-mark 1
iptables -t mangle -A OUTPUT -p udp -m set --match-set gfwlist_ext dst -j MARK --set-mark 1

iptables -t mangle -A PREROUTING -d 198.18.0.0/15 -j TPROXY --on-port 1081 --tproxy-mark 1
iptables -t mangle -A OUTPUT -d 198.18.0.0/15 -j MARK --set-mark 1
