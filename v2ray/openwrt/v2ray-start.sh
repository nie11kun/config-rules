#!/bin/sh /etc/rc.common
START=100
start() {
    /usr/bin/v2ray -confdir /etc/v2ray/conf.d &
}