#!/usr/bin/env bash

# 通过使用特定 gid 的用户运行 v2ray 过滤 v2ray 出来的流量 防止回环

# 使用透明代理通过内置 dns 解析后经过测试只能识别 router 中的 IP 规则，所有域名的规则都无效了
# 以下配置后 使用 fakedns 流量由于域名信息缺失导致访问不正常 需要删除dns中的 fakedns 配置， 调用配置 socks 或 http 代理可正常访问
# 通过日志可以看到 access.log 中本机访问的流量全是 ip 地址而没有域名 会导致 router 中的域名相关配置失效
# 本机或局域网设备可以手动配置网关 http_proxy 和 https_proxy 为网关 v2ray 监听的 socks5 http 端口，这样就可以正常使用基于域名的一些规则了 且日志也是域名

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

# 阻止 QUIC 流量
nft add rule inet fw4 input udp dport 443 drop
nft add rule inet fw4 forward udp dport 443 drop
nft add rule inet fw4 output udp dport 443 drop

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

# 目标地址为本地网络的走直连 不需要单独截获 dns 端口 因为 sniffing 会获取域名并二次判断是否重新获取真实 IP 地址
for i in "${LOCAL_IP[@]}"; do
        iptables -t mangle -A V2RAY -d $i -j RETURN
done

# ******以下配置可以使本机网关 dns 解析也走 v2ray 但会引起 CPU 占用高问题*****
# 目标地址为本地网络的 tcp 流量走直连
# for i in "${LOCAL_IP[@]}"; do
#         iptables -t mangle -A V2RAY -d $i -p tcp -j RETURN
# done
# # dns 53 端口请求要传入透明代理
# for i in "${LOCAL_IP[@]}"; do
#         iptables -t mangle -A V2RAY -d $i -p udp ! --dport 53 -j RETURN
# done
# **************************************

# 组播地址/E类地址/广播地址直连
iptables -t mangle -A V2RAY -d 224.0.0.0/3 -j RETURN

# 实际测试加上以下内容会导致主路由无法走代理
# 如果网关作为主路由，则加上这一句 源访问设备的地址不在本地网关 lan 网段内则直连 防止外网用户访问本地设备走代理
# iptables -t mangle -A V2RAY ! -s 192.168.244.1/24 -j RETURN

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

# 设置 iptables 规则不代理 gid 为 23333 的用户时的流量来让已经经过了 V2RAY 的流量直接发送出去 避免流量回环
# 需要提前将 v2ray 运行在 gid 为 23333 的用户上
iptables -t mangle -A V2RAY_MASK -m owner --gid-owner 23333 -j RETURN

# 目标地址为本地网络的走直连 不需要单独截获 dns 端口 因为 sniffing 会获取域名并二次判断是否重新获取真实 IP 地址
for i in "${LOCAL_IP[@]}"; do
        iptables -t mangle -A V2RAY_MASK -d $i -j RETURN
done

# ******以下配置可以使本机网关 dns 解析也走 v2ray 但会引起 CPU 占用高问题*****
# 目标地址为本地网络的tcp 流量走直连
# for i in "${LOCAL_IP[@]}"; do
#         iptables -t mangle -A V2RAY_MASK -d $i -p tcp -j RETURN
# done
# dns 53 端口请求要传入透明代理
# for i in "${LOCAL_IP[@]}"; do
#         iptables -t mangle -A V2RAY_MASK -d $i -p udp ! --dport 53 -j RETURN
# done
# **************************************

# 组播地址/E类地址/广播地址直连
iptables -t mangle -A V2RAY_MASK -d 224.0.0.0/3 -j RETURN

# 实际测试加上以下内容会导致主路由无法走代理
# 如果网关作为主路由，则加上这一句 源访问设备的地址不在本地网关 lan 网段内则直连 防止外网用户访问本地设备走代理
# iptables -t mangle -A V2RAY_MASK ! -s 192.168.244.1/24 -j RETURN

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