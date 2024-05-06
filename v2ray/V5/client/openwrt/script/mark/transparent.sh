#!/usr/bin/env bash

# 通过 iptables 识别特定 mark 标识的流量过滤 v2ray 出来的流量 防止回环  需要 v2ray 的 outbound 定义相同的 mark 标识

# 添加策略路由: 标记为1的包，走路由表100
ip rule add fwmark 1 table 100
# 添加一条路由规则到路由表100，将所有数据包的下一跳都指向本地 loopback，这样数据包才能被本地代理进程的 listener 看到
ip route add local 0.0.0.0/0 dev lo table 100

# *********************************************************

# "网关所在ipv4网段" 通过运行命令"ip address | grep -w inet | awk '{print $2}'"获得，一般有多个
LOCAL_IP=($(ip address | grep -w inet | awk '{print $2}'))

# 代理局域网设备

# 新建路由链条
iptables -t mangle -N V2RAY

# ******以下配置可以使本机网关 dns 解析也走 v2ray*****
 # 目标地址为本地网络的 tcp 流量走直连
 for i in "${LOCAL_IP[@]}"; do
         iptables -t mangle -A V2RAY -d $i -p tcp -j RETURN
 done
 # dns 53 端口请求要传入透明代理
 for i in "${LOCAL_IP[@]}"; do
         iptables -t mangle -A V2RAY -d $i -p udp ! --dport 53 -j RETURN
 done

# 组播地址/E类地址/广播地址直连
iptables -t mangle -A V2RAY -d 224.0.0.0/3 -j RETURN

iptables -t mangle -A V2RAY -j RETURN -m mark --mark 0xff  # 过滤 v2ray 出来的流量防止回环  需要 outbound 设置 mark 255

# 给流量打标记 1，转发至 1081 端口
# mark设置为1，以应用上面创建的策略路由 流量才能内送入代理程序
iptables -t mangle -A V2RAY -p tcp -j TPROXY --on-port 1081 --tproxy-mark 1
iptables -t mangle -A V2RAY -p udp -j TPROXY --on-port 1081 --tproxy-mark 1

# PREROUTING 链跳转到 V2RAY 链
iptables -t mangle -A PREROUTING -j V2RAY

# *********************************************************

# 代理网关本机  需要配合最上面的策略路由实现流量代理
# 新建路由链
iptables -t mangle -N V2RAY_MASK

# ******以下配置可以使本机网关 dns 解析也走 v2ray*****
# 目标地址为本地网络的tcp 流量走直连
 for i in "${LOCAL_IP[@]}"; do
         iptables -t mangle -A V2RAY_MASK -d $i -p tcp -j RETURN
 done
 # dns 53 端口请求要传入透明代理
 for i in "${LOCAL_IP[@]}"; do
         iptables -t mangle -A V2RAY_MASK -d $i -p udp ! --dport 53 -j RETURN
 done

# 组播地址/E类地址/广播地址直连
iptables -t mangle -A V2RAY_MASK -d 224.0.0.0/3 -j RETURN

iptables -t mangle -A V2RAY_MASK -j RETURN -m mark --mark 0xff  # 过滤 v2ray 出来的流量防止回环  需要 outbound 设置 mark 255

# mark设置为1，以应用上面创建的策略路由 流量才能内送入代理程序
iptables -t mangle -A V2RAY_MASK -j MARK --set-mark 1

# output 链流量转发到 V2RAY_MASK 最后通过策略路由将流量包重新路由到本地网关 重新通过 PREROUTING 链转发到 V2RAY
iptables -t mangle -A OUTPUT -p tcp -j V2RAY_MASK
iptables -t mangle -A OUTPUT -p udp -j V2RAY_MASK

# *********************************************************

# 新建 DIVERT 规则，避免已有连接的包二次通过 TPROXY，理论上有一定的性能提升
iptables -t mangle -N DIVERT
iptables -t mangle -A DIVERT -j MARK --set-mark 1
iptables -t mangle -A DIVERT -j ACCEPT
iptables -t mangle -I PREROUTING -p tcp -m socket -j DIVERT