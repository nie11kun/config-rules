#!/bin/sh /etc/rc.common
START=100
start() {
    v2ray -confdir /etc/v2ray/conf.d &
    ip rule add fwmark 1 table 100
    ip route add local default dev lo table 100
    iptables-restore < /etc/v2ray/iptables
}