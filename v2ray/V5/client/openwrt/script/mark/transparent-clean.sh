#!/usr/bin/env bash

# 删除策略路由
ip rule del fwmark 1 table 100
ip route del local 0.0.0.0/0 dev lo table 100

# ********************************

# 先删除跳转规则
iptables -t mangle -D PREROUTING -j V2RAY

# 先清除链中所有规则 否则删除链会报错 iptables: Directory not empty.
iptables -t mangle -F V2RAY
iptables -t mangle -X V2RAY

# ********************************

# 先删除跳转规则
iptables -t mangle -D OUTPUT -p tcp -j V2RAY_MASK
iptables -t mangle -D OUTPUT -p udp -j V2RAY_MASK

# 先清除链中所有规则 否则删除链会报错 iptables: Directory not empty.
iptables -t mangle -F V2RAY_MASK
iptables -t mangle -X V2RAY_MASK

# ********************************

# 先删除跳转规则
iptables -t mangle -D PREROUTING -p tcp -m socket -j DIVERT

# 先清除链中所有规则 否则删除链会报错 iptables: Directory not empty.
iptables -t mangle -F DIVERT
iptables -t mangle -X DIVERT