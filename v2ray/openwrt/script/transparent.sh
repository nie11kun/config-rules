# https://xtls.github.io/document/level-2/transparent_proxy/transparent_proxy.html
# https://xtls.github.io/document/level-2/iptables_gid.html
# https://guide.v2fly.org/app/tproxy.html#%E8%A7%A3%E5%86%B3-too-many-open-files-%E9%97%AE%E9%A2%98

# *********************************************************

# 将标记有 1 的流量路由到本地网关  从而自动将网关设备的流量重新送入 PREROUTING 链上 进而使网关本身的流量也可以走代理局域网设备的路径进入 v2ray
# iptables-tproxy 不支持对OUTPUT链操作，可以通过配置策略路由，把OUTPUT链中相应的流量包重新路由到PREROUTING链上

# 添加策略路由: 标记为1的包，走路由表100
ip rule add fwmark 1 table 100
# 添加路由条目到路由表100: 所有路由表100的流量包路由到本地网关
ip route add local 0.0.0.0/0 dev lo table 100

# *********************************************************

# 代理局域网设备

# 新建路由链条
iptables -t mangle -N V2RAY

# 目标地址为本地网络的走直连
#  "网关所在ipv4网段" 通过运行命令"ip address | grep -w inet | awk '{print $2}'"获得，一般有多个
iptables -t mangle -A V2RAY -d 127.0.0.1/8 -j RETURN
iptables -t mangle -A V2RAY -d 192.168.244.1/24 -j RETURN
iptables -t mangle -A V2RAY -d 27.168.1.155/24 -j RETURN

# 组播地址/E类地址/广播地址直连
iptables -t mangle -A V2RAY -d 224.0.0.0/3 -j RETURN

#如果网关作为主路由，则加上这一句   源访问设备的地址不在本地网关内则直连 防止外网用户访问本地设备走代理
#网关LAN_IPv4地址段，运行命令"ip address | grep -w "inet" | awk '{print $2}'"获得，是其中的一个
iptables -t mangle -A V2RAY ! -s 127.0.0.1/8 -j RETURN
iptables -t mangle -A V2RAY ! -s 192.168.244.1/24 -j RETURN
iptables -t mangle -A V2RAY ! -s 27.168.1.155/24 -j RETURN

# 给 TCP 打标记 1，转发至 1081 端口
# mark只有设置为1，流量才能被V2RAY任意门接受
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
iptables -t mangle -A V2RAY_MASK -d 192.168.244.1/24 -j RETURN
iptables -t mangle -A V2RAY_MASK -d 27.168.1.155/24 -j RETURN

# 组播地址/E类地址/广播地址直连
iptables -t mangle -A V2RAY_MASK -d 224.0.0.0/3 -j RETURN

# 给路由链流量标记 1   用于最上面定义的策略路由识别本机流量
iptables -t mangle -A V2RAY_MASK -j MARK --set-mark 1

# output 链流量转发到 V2RAY_MASK 最后通过策略路由将流量包重新路由到本地网关 重新通过 PREROUTING 链转发到 V2RAY
iptables -t mangle -A OUTPUT -p tcp -j V2RAY_MASK
iptables -t mangle -A OUTPUT -p udp -j V2RAY_MASK
