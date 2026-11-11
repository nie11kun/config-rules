#!/bin/sh
# OpenWrt 上一键更新 v2ray（在 OpenWrt 23.05 x86_64 上编写，需要 root）：
#   1. 确保 v2ray 正在运行（路由器本机访问 GitHub 要靠它代理）
#   2. 先把所有文件下载到 /tmp：最新 ipk（与已安装包同名：v2ray-core 或 v2ray-core-mini）、
#      Loyalsoldier 加强版 geoip.dat / geosite.dat（校验 sha256）。任何一个下载失败都直接退出，不做任何改动
#   2.5 dnsmasq 模式下调用同目录的 gfwlist.sh 更新 /etc/dnsmasq/proxy-gfwlist.conf，有变化则重启 dnsmasq
#      （失败只记警告并保留旧文件，不影响 v2ray 的更新）
#   3. 安装 ipk（旧进程会继续运行到重启为止），再用加强版 geo 覆盖 ipk 自带的原版 geo
#      新程序校验配置失败则恢复旧程序
#   4. 检查 /etc/config/v2ray 是 jsonv5 格式，/etc/init.d/v2ray 与 install 时备份的一致，否则恢复
#   5. 有变化时才重启 v2ray
#
# 用法：
#   sh v2ray-update.sh                         # 立即更新一次
#   sh v2ray-update.sh update http://ip:port   # 通过指定的 HTTP 代理下载
#   sh v2ray-update.sh install                 # 备份当前确认可用的 init.d / config，并启用每日自动更新（cron）
#   sh v2ray-update.sh uninstall               # 取消每日自动更新
#
# 查看自动更新日志：logread -e v2ray-update

set -u

REPO_API="https://api.github.com/repos/nie11kun/openwrt-v2ray/releases/latest"
GEO_BASE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"

V2RAY_BIN="/usr/bin/v2ray"
CONFIG="/etc/v2ray/config.json"
GEO_DIR="/usr/share/v2ray"
INIT="/etc/init.d/v2ray"
UCI_CONF="/etc/config/v2ray"
BACKUP_DIR="/etc/v2ray/backup"
CRON_FILE="/etc/crontabs/root"
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
GFW_SCRIPT="$SCRIPT_DIR/gfwlist.sh"
GFW_DEST="/etc/dnsmasq/proxy-gfwlist.conf"
# 每天 05:00（路由器本地时间）
CRON_TIME="0 5 * * *"

log() { echo "[v2ray-update] $*"; }
die() { echo "[v2ray-update] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行"

# ---------- 下载：优先 curl，没有则用系统自带的 wget（uclient-fetch） ----------
fetch() { # fetch <url> <输出文件>
    if command -v curl > /dev/null 2>&1; then
        curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 600 \
            ${PROXY:+--proxy "$PROXY"} --output "$2" "$1"
    else
        # uclient-fetch 通过环境变量使用代理
        http_proxy="${PROXY:-}" https_proxy="${PROXY:-}" wget -q -T 30 -O "$2" "$1"
    fi
    [ -s "$2" ]
}

pkg_version() { # pkg_version <包名>
    opkg status "$1" 2> /dev/null | awk '/^Version:/ {print $2}'
}

replace_file() { # replace_file <新文件> <目标>：先复制成临时文件再改名，避免覆盖正在使用的文件
    cp -p "$1" "$2.new" && mv -f "$2.new" "$2"
}

# ---------- 准备阶段：只下载，不改动系统 ----------
ensure_running() {
    pidof v2ray > /dev/null && return 0
    log "v2ray 没有在运行，先启动它以便通过代理下载"
    "$INIT" start
    sleep 3
    pidof v2ray > /dev/null || log "警告：v2ray 启动失败，将尝试直连 GitHub 下载"
}

prepare_core() { # 有新版本时设置 IPK_FILE / NEW_VER
    local p arch url file
    PKG=""
    for p in v2ray-core v2ray-core-mini; do
        [ -n "$(pkg_version "$p")" ] && PKG="$p" && break
    done
    [ -n "$PKG" ] || die "没有找到已安装的 v2ray-core / v2ray-core-mini，请先手动安装一次"
    CUR_VER="$(pkg_version "$PKG")"

    arch="$(. /etc/os-release && echo "${OPENWRT_ARCH:-}")"
    [ -n "$arch" ] || arch="x86_64"

    fetch "$REPO_API" "$TMP/release.json" || die "获取最新 release 信息失败"
    url="$(jsonfilter -i "$TMP/release.json" -e '@.assets[*].browser_download_url' \
        | grep "/${PKG}_[^/]*_${arch}\.ipk$" | head -n 1)"
    [ -n "$url" ] || die "最新 release 中没有 ${PKG} 的 ${arch} 包"
    file="${url##*/}"
    NEW_VER="${file#${PKG}_}"
    NEW_VER="${NEW_VER%_${arch}.ipk}"

    log "$PKG 当前版本：$CUR_VER，最新版本：$NEW_VER"
    IPK_FILE=""
    [ "$CUR_VER" = "$NEW_VER" ] && return 0

    fetch "$url" "$TMP/$file" || die "下载 $file 失败，未做任何改动"
    IPK_FILE="$TMP/$file"
}

prepare_geo() {
    local f expect actual
    for f in geoip.dat geosite.dat; do
        fetch "$GEO_BASE/$f" "$TMP/$f" || die "下载 $f 失败，未做任何改动"
        fetch "$GEO_BASE/$f.sha256sum" "$TMP/$f.sha256sum" || die "下载 $f.sha256sum 失败，未做任何改动"
        expect="$(awk '{print $1}' "$TMP/$f.sha256sum")"
        actual="$(sha256sum "$TMP/$f" | awk '{print $1}')"
        [ -n "$expect" ] && [ "$expect" = "$actual" ] || die "$f sha256 校验失败，未做任何改动"
    done
}

# ---------- dnsmasq 代理域名列表（gfwlist） ----------
update_gfwlist() { # 失败只记警告，不中断 v2ray 的更新
    local before after
    if [ ! -f "$GFW_DEST" ]; then
        log "没有 $GFW_DEST（不是 dnsmasq 模式），跳过 gfwlist 更新"
        return 0
    fi
    if [ ! -f "$GFW_SCRIPT" ] || ! command -v bash > /dev/null 2>&1; then
        log "警告：需要 $GFW_SCRIPT 和 bash 才能更新 gfwlist，已跳过"
        return 0
    fi

    cp -p "$GFW_DEST" "$TMP/gfwlist.bak"
    before="$(md5sum "$GFW_DEST" | awk '{print $1}')"
    if ! bash "$GFW_SCRIPT" "$PROXY" "$GFW_DEST" > "$TMP/gfwlist.log" 2>&1; then
        cat "$TMP/gfwlist.log" >&2
        log "警告：gfwlist 更新失败，保留旧文件"
        return 0
    fi
    after="$(md5sum "$GFW_DEST" | awk '{print $1}')"
    if [ "$before" = "$after" ]; then
        log "gfwlist 已是最新"
        return 0
    fi

    # 新文件有语法问题时 dnsmasq 会起不来，整个局域网都没有 DNS，所以先检查
    if ! dnsmasq --test --conf-file="$GFW_DEST" > "$TMP/dnsmasq-test.log" 2>&1; then
        cat "$TMP/dnsmasq-test.log" >&2
        replace_file "$TMP/gfwlist.bak" "$GFW_DEST"
        log "警告：新的 gfwlist 没有通过 dnsmasq 检查，已恢复旧文件"
        return 0
    fi
    /etc/init.d/dnsmasq restart
    sleep 3
    if ! pidof dnsmasq > /dev/null; then
        replace_file "$TMP/gfwlist.bak" "$GFW_DEST"
        /etc/init.d/dnsmasq restart
        log "警告：使用新的 gfwlist 后 dnsmasq 没有启动，已恢复旧文件并重启 dnsmasq"
        return 0
    fi
    log "gfwlist 已更新（$(grep -c '^nftset=' "$GFW_DEST") 条），已重启 dnsmasq"
}

# ---------- 应用阶段 ----------
apply_core() { # 有更新时返回 0
    [ -n "$IPK_FILE" ] || return 1
    cp -p "$V2RAY_BIN" "$TMP/v2ray.bak"
    opkg install "$IPK_FILE" || die "opkg 安装 ${IPK_FILE##*/} 失败"

    # 新程序不能正常解析现有配置时，恢复旧程序，避免服务起不来
    if ! "$V2RAY_BIN" test -config "$CONFIG" -format jsonv5 > "$TMP/test.log" 2>&1; then
        cat "$TMP/test.log" >&2
        replace_file "$TMP/v2ray.bak" "$V2RAY_BIN"
        die "新版本 $NEW_VER 校验配置失败，已恢复旧程序（opkg 记录的版本仍是 $NEW_VER，下次不会自动重试）"
    fi
    log "$PKG 已更新到 $NEW_VER"
    return 0
}

apply_geo() { # 有改动时返回 0（ipk 会放回原版 geo，所以必须在 apply_core 之后执行）
    local changed=1 f
    mkdir -p "$GEO_DIR"
    for f in geoip.dat geosite.dat; do
        if cmp -s "$TMP/$f" "$GEO_DIR/$f"; then
            log "$f 已是最新"
        else
            chmod 644 "$TMP/$f"
            replace_file "$TMP/$f" "$GEO_DIR/$f"
            log "$f 已更新"
            changed=0
        fi
    done
    return $changed
}

check_service_files() { # 有改动时返回 0
    local changed=1 f b
    if [ "$(uci -q get v2ray.config.format)" != "jsonv5" ]; then
        uci set v2ray.config.format='jsonv5'
        uci commit v2ray
        log "已把 $UCI_CONF 的 format 改回 jsonv5"
        changed=0
    fi
    for f in "$INIT" "$UCI_CONF"; do
        b="$BACKUP_DIR/$(echo "$f" | tr / _)"
        [ -f "$b" ] || continue
        if ! cmp -s "$b" "$f"; then
            cp -p "$b" "$f"
            log "$f 与备份不一致，已恢复为 install 时备份的版本"
            changed=0
        fi
    done
    return $changed
}

# ---------- 主流程 ----------
do_update() {
    PROXY="${1:-}"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    local need_restart=0

    ensure_running
    prepare_core
    prepare_geo
    # 放在下载完成之后：重启 dnsmasq 期间 DNS 会短暂不可用，而后面的步骤不再需要联网
    update_gfwlist

    if apply_core; then need_restart=1; fi
    if apply_geo; then need_restart=1; fi
    if check_service_files; then need_restart=1; fi

    if [ "$need_restart" -eq 0 ]; then
        log "没有变化，无需重启"
        return 0
    fi

    "$V2RAY_BIN" test -config "$CONFIG" -format jsonv5 > "$TMP/test.log" 2>&1 \
        || { cat "$TMP/test.log" >&2; die "配置校验失败，未重启 v2ray"; }

    "$INIT" restart
    sleep 3
    pidof v2ray > /dev/null || die "v2ray 重启后没有在运行，请检查：logread -e v2ray"
    log "v2ray 已重启（$("$V2RAY_BIN" version 2> /dev/null | head -n 1)）"
}

do_install() {
    local self f p
    self="$(readlink -f "$0")"
    [ "$(uci -q get v2ray.config.format)" = "jsonv5" ] \
        || die "当前 $UCI_CONF 的 format 不是 jsonv5，请先改好再执行 install（install 会把当前文件当作正确版本备份）"

    mkdir -p "$BACKUP_DIR"
    for f in "$INIT" "$UCI_CONF"; do
        cp -p "$f" "$BACKUP_DIR/$(echo "$f" | tr / _)"
    done
    log "已备份 $INIT 和 $UCI_CONF 到 $BACKUP_DIR"

    touch "$CRON_FILE"
    sed -i '/v2ray-update/d' "$CRON_FILE"
    echo "$CRON_TIME sh $self update 2>&1 | logger -t v2ray-update" >> "$CRON_FILE"
    /etc/init.d/cron enable
    /etc/init.d/cron restart
    log "已启用每日自动更新：$CRON_TIME（cron 调用的是 $self，移动脚本后需重新 install）"

    # 系统升级（sysupgrade）时保留脚本目录（含 gfwlist.sh）、备份、dnsmasq 规则和 cron
    for p in "$SCRIPT_DIR" "$BACKUP_DIR" /etc/dnsmasq "$CRON_FILE"; do
        grep -qxF "$p" /etc/sysupgrade.conf 2> /dev/null || echo "$p" >> /etc/sysupgrade.conf
    done
}

do_uninstall() {
    [ -f "$CRON_FILE" ] && sed -i '/v2ray-update/d' "$CRON_FILE"
    /etc/init.d/cron restart
    log "已取消每日自动更新（$BACKUP_DIR 保留）"
}

case "${1:-update}" in
    update)    do_update "${2:-}" ;;
    install)   do_install ;;
    uninstall) do_uninstall ;;
    *)         die "未知参数：$1（可用：update [代理] / install / uninstall）" ;;
esac
