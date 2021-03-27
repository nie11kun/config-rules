#!/bin/sh /etc/rc.common
START=100
start() {
    /usr/bin/v2ray -confdir /etc/v2ray/conf.d &
    /sbin/ip rule add fwmark 1 table 100
    /sbin/ip route add local default dev lo table 100
    /usr/sbin/iptables-restore < /etc/iptables/v2ray-rules
}