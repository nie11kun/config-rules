#!/usr/bin/env bash
# VPS 上一键更新 v2ray（需要 root）：
#   1. 用官方 fhs-install-v2ray 脚本升级 v2ray 主程序（已是最新则跳过）
#   2. 写入 systemd drop-in，保证始终用 jsonv5 格式启动（安装脚本默认生成的是 v4 启动命令）
#   3. 下载 Loyalsoldier 加强版 geoip.dat / geosite.dat，校验 sha256 后替换
#   4. 校验配置，只有在确实有变化时才重启服务
#
# 用法：
#   bash v2ray-update.sh            # 立即执行一次更新
#   bash v2ray-update.sh install    # 安装到 /usr/local/bin 并启用每日自动更新（systemd timer）
#   bash v2ray-update.sh uninstall  # 取消每日自动更新
#
# 查看自动更新：
#   systemctl list-timers v2ray-update.timer
#   journalctl -u v2ray-update.service -n 50

set -euo pipefail

INSTALLER_URL="https://raw.githubusercontent.com/v2fly/fhs-install-v2ray/master/install-release.sh"
GEO_BASE="https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download"

V2RAY_BIN="/usr/local/bin/v2ray"
CONFIG="/usr/local/etc/v2ray/config.json"
GEO_DIR="/usr/local/share/v2ray"
DROPIN_DIR="/etc/systemd/system/v2ray.service.d"
# 文件名排在安装脚本的 10-donot_touch_single_conf.conf 之后，所以会覆盖它，且升级时不会被安装脚本改写
DROPIN="$DROPIN_DIR/20-jsonv5.conf"

SELF_DEST="/usr/local/bin/v2ray-update"
UNIT_SERVICE="/etc/systemd/system/v2ray-update.service"
UNIT_TIMER="/etc/systemd/system/v2ray-update.timer"

log() { echo "[v2ray-update] $*"; }
die() { echo "[v2ray-update] ERROR: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行"

fetch() { # fetch <url> <输出文件>
    curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 300 --output "$2" "$1"
}

v2ray_version() {
    [ -x "$V2RAY_BIN" ] && "$V2RAY_BIN" version 2>/dev/null | head -n 1 || echo "none"
}

# ---------- systemd drop-in：强制 jsonv5 启动 ----------
ensure_dropin() { # 有改动时返回 0
    local want
    want="$(printf '%s\n' \
        '# 由 v2ray-update.sh 维护：强制使用 jsonv5 格式启动' \
        '[Service]' \
        'ExecStart=' \
        "ExecStart=$V2RAY_BIN run -config $CONFIG -format jsonv5")"
    if [ -f "$DROPIN" ] && [ "$(cat "$DROPIN")" = "$want" ]; then
        return 1
    fi
    mkdir -p "$DROPIN_DIR"
    printf '%s\n' "$want" > "$DROPIN"
    systemctl daemon-reload
    log "已写入 $DROPIN"
    return 0
}

# ---------- geo 数据 ----------
update_geo() { # 有改动时返回 0
    local changed=1 f expect actual
    mkdir -p "$GEO_DIR"
    for f in geoip.dat geosite.dat; do
        # 本函数在 if 条件里被调用，set -e 不生效，所以下载失败要显式退出
        fetch "$GEO_BASE/$f" "$TMP/$f" || die "下载 $f 失败，保留旧文件"
        fetch "$GEO_BASE/$f.sha256sum" "$TMP/$f.sha256sum" || die "下载 $f.sha256sum 失败，保留旧文件"
        expect="$(awk '{print $1}' "$TMP/$f.sha256sum")"
        actual="$(sha256sum "$TMP/$f" | awk '{print $1}')"
        [ -n "$expect" ] && [ "$expect" = "$actual" ] || die "$f sha256 校验失败，保留旧文件"
        if [ -f "$GEO_DIR/$f" ] && cmp -s "$TMP/$f" "$GEO_DIR/$f"; then
            log "$f 已是最新"
        else
            install -m 644 "$TMP/$f" "$GEO_DIR/$f.new"
            mv -f "$GEO_DIR/$f.new" "$GEO_DIR/$f"
            log "$f 已更新"
            changed=0
        fi
    done
    return $changed
}

# ---------- 主流程 ----------
do_update() {
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    local need_restart=0 before after

    # 先保证 drop-in 存在，这样安装脚本升级后自动重启时用的就是 jsonv5 命令
    if ensure_dropin; then need_restart=1; fi

    before="$(v2ray_version)"
    log "当前版本：$before"
    fetch "$INSTALLER_URL" "$TMP/install-release.sh"
    bash "$TMP/install-release.sh"
    after="$(v2ray_version)"
    if [ "$before" != "$after" ]; then
        log "主程序已升级：$after"
        need_restart=1
    fi

    # 安装脚本可能改动 unit 文件，再检查一次
    if ensure_dropin; then need_restart=1; fi

    # 安装脚本升级时会放回官方原版 geo 文件，所以放在它之后执行
    if update_geo; then need_restart=1; fi

    if [ "$need_restart" -eq 0 ]; then
        log "没有变化，无需重启"
        return 0
    fi

    if ! "$V2RAY_BIN" test -config "$CONFIG" -format jsonv5; then
        die "配置校验失败，未重启服务，请检查 $CONFIG"
    fi

    systemctl restart v2ray
    sleep 3
    systemctl is-active --quiet v2ray || die "v2ray 重启后未处于运行状态：journalctl -u v2ray -n 50"
    log "v2ray 已重启并正常运行（$after）"
}

# ---------- 每日自动更新 ----------
do_install() {
    install -m 755 "$0" "$SELF_DEST"
    cat > "$UNIT_SERVICE" <<EOF
[Unit]
Description=Update v2ray binary and geo data
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$SELF_DEST
EOF
    cat > "$UNIT_TIMER" <<EOF
[Unit]
Description=Daily v2ray update

[Timer]
# 每天 04:30（服务器本地时间），随机延后最多 30 分钟；关机错过的会在开机后补跑
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now v2ray-update.timer
    log "已安装到 $SELF_DEST，并启用每日自动更新"
    systemctl list-timers v2ray-update.timer --no-pager || true
}

do_uninstall() {
    systemctl disable --now v2ray-update.timer 2>/dev/null || true
    rm -f "$UNIT_SERVICE" "$UNIT_TIMER"
    systemctl daemon-reload
    log "已取消每日自动更新（$SELF_DEST 和 $DROPIN 保留）"
}

case "${1:-update}" in
    update)    do_update ;;
    install)   do_install ;;
    uninstall) do_uninstall ;;
    *)         die "未知参数：$1（可用：update / install / uninstall）" ;;
esac
