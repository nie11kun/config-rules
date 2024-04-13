#!/usr/bin/env bash

# 通过 iptables 识别特定 mark 标识的流量过滤 v2ray 出来的流量 防止回环  需要 v2ray 的 outbound 定义相同的 mark 标识

# https://xtls.github.io/document/level-2/transparent_proxy/transparent_proxy.html
# https://xtls.github.io/document/level-2/iptables_gid.html
# https://guide.v2fly.org/app/tproxy.html#%E8%A7%A3%E5%86%B3-too-many-open-files-%E9%97%AE%E9%A2%98
# https://www.zhaohuabing.com/learning-linux/docs/tproxy/
# https://jimmysong.io/blog/what-is-tproxy/

# *********************************************************

# 要使用透明代理首先需要把指定的数据包使用 iptables 拦截到指定的网卡上，然后在该网卡监听并转发数据包
# 使用 tproxy 实现透明代理的步骤如下：
# 在 iptables 的 PREROUTING 链的 mangle 表中创建一个规则，拦截流量发送给 tproxy 处理 - 配置 tproxy 监听端口并给数据包打上标记 如：1
# 建一个路由规则，将所有带有标记 1 的数据包查找特定的路由表
# 将数据包映射到特定的本地地址 例如 ip rule add local 0.0.0.0/0 dev lo table 100，在 100 路由表中将所有 IPv4 地址转发到本地 lo 回环网卡
# 至此流量已被拦截到 tproxy 的监听端口

# 由于客户端发出的 IP 数据包的目的地址并不是代理服务器，因此请求缺省会被代理服务器内核 forward 出去
# 为了能将客户端请求重定向到代理进程，需要在代理服务器上创建下面的策略路由
# 将标记有 1 的流量路由到本地 lo 回环网卡

# 添加策略路由: 标记为1的包，走路由表100
ip rule add fwmark 1 table 100
# 添加一条路由规则到路由表100，将所有数据包的下一跳都指向本地 loopback，这样数据包才能被本地代理进程的 listener 看到
ip route add local 0.0.0.0/0 dev lo table 100

# *********************************************************

# 代理局域网设备

# 新建路由链条
iptables -t mangle -N V2RAY

# 目标地址为本地网络的走直连
#  "网关所在ipv4网段" 通过运行命令"ip address | grep -w inet | awk '{print $2}'"获得，一般有多个
iptables -t mangle -A V2RAY -d 127.0.0.1/8 -j RETURN
iptables -t mangle -A V2RAY -d 172.19.0.1/16 -j RETURN
iptables -t mangle -A V2RAY -d 172.18.0.1/16 -j RETURN
iptables -t mangle -A V2RAY -d 172.17.0.1/16 -j RETURN
iptables -t mangle -A V2RAY -d 192.168.0.0/16 -p tcp -j RETURN

# 组播地址/E类地址/广播地址直连
iptables -t mangle -A V2RAY -d 224.0.0.0/3 -j RETURN

iptables -t mangle -A V2RAY -d 192.168.0.0/16 -p udp ! --dport 53 -j RETURN # 直连局域网，53 端口除外（因为要使用 V2Ray 的 DNS)
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

# 目标地址为本地网络的走直连
iptables -t mangle -A V2RAY_MASK -d 127.0.0.1/8 -j RETURN
iptables -t mangle -A V2RAY_MASK -d 172.19.0.1/16 -j RETURN
iptables -t mangle -A V2RAY_MASK -d 172.18.0.1/16 -j RETURN
iptables -t mangle -A V2RAY_MASK -d 172.17.0.1/16 -j RETURN
iptables -t mangle -A V2RAY_MASK -d 192.168.0.0/16 -p tcp -j RETURN

# 组播地址/E类地址/广播地址直连
iptables -t mangle -A V2RAY_MASK -d 224.0.0.0/3 -j RETURN

iptables -t mangle -A V2RAY_MASK -d 192.168.0.0/16 -p udp ! --dport 53 -j RETURN # 直连局域网，53 端口除外（因为要使用 V2Ray 的 DNS）
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