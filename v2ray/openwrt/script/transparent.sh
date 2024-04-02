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
iptables -t mangle -A V2RAY -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A V2RAY -d 27.168.0.0/16 -j RETURN
iptables -t mangle -A V2RAY -d 172.19.0.1/16 -j RETURN
iptables -t mangle -A V2RAY -d 172.18.0.1/16 -j RETURN
iptables -t mangle -A V2RAY -d 172.17.0.1/16 -j RETURN

# 组播地址/E类地址/广播地址直连
iptables -t mangle -A V2RAY -d 224.0.0.0/3 -j RETURN

#如果网关作为主路由，则加上这一句   源访问设备的地址不在本地网关内则直连 防止外网用户访问本地设备走代理
#网关LAN_IPv4地址段，运行命令"ip address | grep -w "inet" | awk '{print $2}'"获得，是其中的一个
iptables -t mangle -A V2RAY ! -s 127.0.0.1/8 -j RETURN
iptables -t mangle -A V2RAY ! -s 192.168.0.0/16 -j RETURN
iptables -t mangle -A V2RAY ! -s 27.168.0.0/16 -j RETURN
iptables -t mangle -A V2RAY ! -s 172.19.0.1/16 -j RETURN
iptables -t mangle -A V2RAY ! -s 172.18.0.1/16 -j RETURN
iptables -t mangle -A V2RAY ! -s 172.17.0.1/16 -j RETURN

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

# 目标地址为本地网络的走直连
iptables -t mangle -A V2RAY_MASK -d 127.0.0.1/8 -j RETURN
iptables -t mangle -A V2RAY_MASK -d 192.168.0.0/16 -j RETURN
iptables -t mangle -A V2RAY_MASK -d 27.168.0.0/16 -j RETURN
iptables -t mangle -A V2RAY_MASK -d 172.19.0.1/16 -j RETURN
iptables -t mangle -A V2RAY_MASK -d 172.18.0.1/16 -j RETURN
iptables -t mangle -A V2RAY_MASK -d 172.17.0.1/16 -j RETURN

# 组播地址/E类地址/广播地址直连
iptables -t mangle -A V2RAY_MASK -d 224.0.0.0/3 -j RETURN

# mark设置为1，以应用上面创建的策略路由 流量才能内送入代理程序
iptables -t mangle -A V2RAY_MASK -j MARK --set-mark 1

# output 链流量转发到 V2RAY_MASK 最后通过策略路由将流量包重新路由到本地网关 重新通过 PREROUTING 链转发到 V2RAY
iptables -t mangle -A OUTPUT -p tcp -j V2RAY_MASK
iptables -t mangle -A OUTPUT -p udp -j V2RAY_MASK
