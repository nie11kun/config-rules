ip route del local default dev lo table 100
ip rule del fwmark 1 lookup 100

ipset -X gfwlist
ipset -X gfwlist_ext

iptables -t mangle -D PREROUTING -p tcp -m set --match-set gfwlist dst -j TPROXY --on-port 1081 --tproxy-mark 1
iptables -t mangle -D PREROUTING -p udp -m set --match-set gfwlist dst -j TPROXY --on-port 1081 --tproxy-mark 1
iptables -t mangle -D OUTPUT -p tcp -m set --match-set gfwlist dst -j MARK --set-mark 1
iptables -t mangle -D OUTPUT -p udp -m set --match-set gfwlist dst -j MARK --set-mark 1

iptables -t mangle -D PREROUTING -p tcp -m set --match-set gfwlist_ext dst -j TPROXY --on-port 1081 --tproxy-mark 1
iptables -t mangle -D PREROUTING -p udp -m set --match-set gfwlist_ext dst -j TPROXY --on-port 1081 --tproxy-mark 1
iptables -t mangle -D OUTPUT -p tcp -m set --match-set gfwlist_ext dst -j MARK --set-mark 1
iptables -t mangle -D OUTPUT -p udp -m set --match-set gfwlist_ext dst -j MARK --set-mark 1

iptables -t mangle -D PREROUTING -d 198.18.0.0/15 -j TPROXY --on-port 1081 --tproxy-mark 1
iptables -t mangle -D OUTPUT -d 198.18.0.0/15 -j MARK --set-mark 1
