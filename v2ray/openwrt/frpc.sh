#!/bin/sh /etc/rc.common
START=99
USE_PROCD=1
boot() {
    sleep 60
    rc_procd start_service
}
start_instance() {
	procd_open_instance "frpc.frpc"
	procd_set_param command "/usr/bin/frpc"
	procd_append_param command -c "/etc/frp/frpc.ini"
	procd_set_param respawn
	procd_set_param file "/etc/frp/frpc.ini"
	procd_set_param user "root"
	procd_close_instance
}
service_triggers() {
	procd_add_reload_trigger "frpc"
}

start_service() {
	config_load "frpc"
	config_foreach start_instance "frpc"
}