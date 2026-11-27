# VPS 安装配置 sing-box 指南（VLESS + REALITY & Hysteria2）

在已有 Nginx 网站（`TCP 80/443`）与 V2Ray（`VMess + WS + TLS`）的 VPS 上，用单个轻量级 **`sing-box`** 进程并行部署 **VLESS + XTLS-Vision + REALITY** 与 **Hysteria2（含端口跳跃）**，并对现有网站、证书续签与 Docker 服务保持零影响。

配置文件模板见同目录 [`config.json`](config.json)。

## 目录

1. [架构与端口规划](#1-架构与端口规划)
2. [前置检查与系统调优](#2-前置检查与系统调优)
3. [安装 sing-box](#3-安装-sing-box)
4. [生成凭证与配置](#4-生成凭证与配置)
5. [配置 systemd 服务与证书续签联动](#5-配置-systemd-服务与证书续签联动)
6. [防火墙与 Hysteria2 端口跳跃](#6-防火墙与-hysteria2-端口跳跃)
7. [客户端接入与常见踩坑](#7-客户端接入与常见踩坑)
8. [验证、升级与排障](#8-验证升级与排障)

---

## 1. 架构与端口规划

若 VPS 上已运行大量 Nginx 虚拟主机，将 `TCP 443` 改为 SNI 前置分流往往需要全量调整站点监听端口和 `proxy_protocol`，改造面大、风险高。本方案采用 **“协议隔离 + 端口错开”** 架构：

| 协议与角色 | 监听端口 | 证书 / 伪装 | 与现有服务关系 |
| --- | --- | --- | --- |
| **VLESS + Vision + REALITY**（日常主力） | `TCP 8443` | 借用大站 TLS 1.3 指纹（`www.apple.com`） | 与 Nginx 零交集，消除 TLS-in-TLS 特征 |
| **Hysteria2**（晚高峰高速） | `UDP 443` + `40000-40500/udp` 跳跃 | 复用站点通配符/域名正式证书 | Nginx 仅监听 `TCP 443`，`UDP 443` 完全不冲突 |
| **原 VMess + WS + TLS**（保底备用） | `TCP 443` → Nginx → V2Ray | 原有配置保持不动 | 遇到严苛防火墙/封 UDP 时兜底 |

> 如果宿主机未启用路由级或本地 WARP，可将 `config.json` 中 `geosite-openai` 等 AI 分流规则改回 `direct` 出口。若本机已跑 Cloudflare WARP 本地 SOCKS5（`127.0.0.1:40000`），`sing-box` 可直接复用它解锁 AI 服务。

---

## 2. 前置检查与系统调优

**1. 确认公网网卡名与端口未被占用**

```bash
ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}'
ss -tulnp | grep -E ':(8443|443)\b'
```

确认输出中 `TCP 8443` 与 `UDP 443` 均无进程占用（仅看到 Nginx 占用 `TCP 443` 属正常）。若公网网卡不是 `eth0`（例如 `ens3`），后续配置端口跳跃规则时请替换为实际网卡名。

**2. 开启 BBR 与调大网络/UDP 缓冲区**

Hysteria2 基于 UDP/QUIC，若内核接收缓冲偏小容易在高速下载时丢包。建议在 `/etc/sysctl.d/99-singbox-optimize.conf` 中写入：

```ini
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
```

应用并核对生效：

```bash
sysctl --system
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max
```

**3. 确认 TLS 证书权限与 WARP（可选）**

```bash
ls -l /path/to/fullchain.pem /path/to/privkey.pem
ss -tlnp | grep 40000 || echo "无本地 WARP，请调整 config.json 路由"
```

后文会让 `sing-box` 以站点用户身份（如 `www-data`）运行，只要 `www-data` 对证书和私钥具备只读权限即可，**无需改动 Nginx 现有的证书文件权限**。

---

## 3. 安装 sing-box

从 GitHub 官方 Releases 下载最新的 Linux `amd64` 二进制并安装（以下以自动获取最新版为例）：

```bash
VER=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep -oE '"tag_name":\s*"v[^"]+"' | cut -d'"' -f4 | sed 's/^v//')
echo "Downloading sing-box v${VER}..."

TMPD=$(mktemp -d)
curl -fsSL -o "$TMPD/sing-box.tar.gz" "https://github.com/SagerNet/sing-box/releases/download/v${VER}/sing-box-${VER}-linux-amd64.tar.gz"
tar -xzf "$TMPD/sing-box.tar.gz" -C "$TMPD"
install -m 0755 "$TMPD"/sing-box-*/sing-box /usr/local/bin/sing-box
rm -rf "$TMPD"

sing-box version
```

创建配置目录与状态缓存目录（用于持久化 `.srs` 规则集缓存）：

```bash
install -d -m 0750 -o root -g www-data /etc/sing-box
install -d -m 0750 -o www-data -g www-data /var/lib/sing-box
```

---

## 4. 生成凭证与配置

**1. 实测挑选 REALITY 伪装目标（`server_name` / `handshake.server`）**

优先挑选支持 **TLS 1.3 + HTTP/2 (`h2`) + X25519** 且延迟最低、国内未被屏蔽的大型网站：

```bash
for host in www.apple.com www.microsoft.com addons.mozilla.org; do
    t=$(curl -so /dev/null -w "tcp=%{time_connect}s tls=%{time_appconnect}s code=%{http_code}" --max-time 4 "https://$host/")
    info=$(echo | openssl s_client -connect "$host:443" -servername "$host" -alpn h2 -tls1_3 2>/dev/null | grep -E 'ALPN protocol|Server Temp Key' | tr '\n' ' ')
    echo "$host => $t | $info"
done
```

选出返回 `200`/`301`、协商出 `X25519` 与 `ALPN protocol: h2` 且握手最快的目标（通常 `www.apple.com` 或 `www.microsoft.com` 仅 25–40 ms）。

**2. 使用内置命令生成密钥与随机数**

```bash
sing-box generate uuid
sing-box generate reality-keypair
sing-box generate rand --hex 4    # 用作 short_id（8 位十六进制）
sing-box generate rand --hex 16   # 用作 Hysteria2 密码
```

注意保存好输出结果：
- **`PrivateKey`** 填进服务端 `config.json` 的 `reality.private_key`；
- **`PublicKey`** 填进客户端配置的 `public-key`（不要把私钥填到客户端）。

**3. 写入 `/etc/sing-box/config.json` 并校验**

参照同目录 [`config.json`](config.json)，将占位符替换为实际值后写入 `/etc/sing-box/config.json`：

- `uuid-here` → 生成的 UUID
- `your-reality-private-key` → 生成的 `PrivateKey`
- `1234abcd` → 生成的 8 位 `short_id`
- `your-hy2-password` → 生成的 Hysteria2 密码
- `/path/to/fullchain.pem`、`/path/to/privkey.pem` → 你的域名证书链与私钥路径
- `up_mbps` / `down_mbps` → 建议贴合家庭宽带上/下行能力适当留余量（例如家宽 1000M 下行 / 50M 上行，服务端可设 `"up_mbps": 100, "down_mbps": 300`，既能拉满日常下载又防单核 VPS CPU 过载或过度消耗流量）

设定只读组权限并校验语法：

```bash
chown root:www-data /etc/sing-box/config.json
chmod 0640 /etc/sing-box/config.json
sing-box check -c /etc/sing-box/config.json
```

看到无报错返回即表示配置合法。

---

## 5. 配置 systemd 服务与证书续签联动

**1. 创建 `/etc/systemd/system/sing-box.service`**

以 `www-data` 身份运行，仅赋予绑定特权端口（`UDP 443`）所需的最小 capability：

```ini
[Unit]
Description=sing-box service
After=network-online.target nss-lookup.target warp-svc.service
Wants=network-online.target

[Service]
User=www-data
Group=www-data
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

**2. 配置证书变更自动重载（不改动 `acme.sh` 与 Nginx）**

通过 systemd `.path` 单元直接监听证书文件改动并触发重启加载新证书：

```bash
cat > /etc/systemd/system/sing-box-cert-reload.service <<'EOF'
[Unit]
Description=Restart sing-box when SSL certificate changes

[Service]
Type=oneshot
ExecStart=/bin/systemctl restart sing-box.service
EOF

cat > /etc/systemd/system/sing-box-cert-reload.path <<'EOF'
[Unit]
Description=Watch SSL certificate for sing-box reload

[Path]
PathChanged=/path/to/fullchain.pem

[Install]
WantedBy=multi-user.target
EOF
```

*(记得将 `/path/to/fullchain.pem` 替换为与 `config.json` 中一致的证书实际路径。)*

---

## 6. 防火墙与 Hysteria2 端口跳跃

**1. UFW 放行端口**

```bash
ufw allow 8443/tcp comment 'VLESS REALITY'
ufw allow 443/udp comment 'Hysteria2 QUIC'
ufw allow 40000:40500/udp comment 'Hysteria2 Port Hopping'
```

**2. 持久化端口跳跃转发（`40000:40500/udp → 443/udp`）**

> **为什么不推荐直接改 `/etc/ufw/before.rules`？**
> 若 VPS 上同时运行了 Docker（例如 RustDesk、自建容器），Docker 会维护自己的 `nat` 链；直接把 `*nat :PREROUTING ACCEPT` 写死在 `before.rules` 并在重载 UFW 时刷新规则，容易干扰甚至冲掉容器的端口转发。使用独立的 systemd oneshot 服务幂等追加一条 `REDIRECT` 规则更安全、可随时启停。

创建 `/etc/systemd/system/sing-box-hy2-hop.service`（若第 2 节查到的公网网卡不是 `eth0`，请同步替换 `-i eth0`）：

```ini
[Unit]
Description=Hysteria2 UDP Port Hopping (40000-40500 -> 443)
After=network-online.target ufw.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'iptables -t nat -C PREROUTING -i eth0 -p udp --dport 40000:40500 -j REDIRECT --to-ports 443 2>/dev/null || iptables -t nat -A PREROUTING -i eth0 -p udp --dport 40000:40500 -j REDIRECT --to-ports 443'
ExecStop=/bin/sh -c 'iptables -t nat -D PREROUTING -i eth0 -p udp --dport 40000:40500 -j REDIRECT --to-ports 443 2>/dev/null || true'

[Install]
WantedBy=multi-user.target
```

**3. 全部启用并启动**

```bash
systemctl daemon-reload
systemctl enable --now sing-box.service sing-box-cert-reload.path sing-box-hy2-hop.service
```

---

## 7. 客户端接入与常见踩坑

**1. Clash Verge / OpenClash / Stash 节点片段**

```yaml
proxies:
  - name: out-reality
    type: vless
    server: 111.111.111.111
    port: 8443
    uuid: uuid-uuid-uuid-uuid
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: www.apple.com
    client-fingerprint: chrome
    reality-opts:
      public-key: your-reality-public-key
      short-id: "1234abcd" # 必须加双引号！OpenClash 的 Ruby YAML 1.1 解析器遇到纯数字或特定字符的裸 short-id 会报错失败

  - name: out-hy2
    type: hysteria2
    server: 111.111.111.111
    port: 443
    ports: 40000-40500
    password: your-hy2-password
    sni: xxx.com
    up: "50 Mbps"
    down: "300 Mbps"
    skip-cert-verify: false
```

- **OpenClash 踩坑提醒**：OpenClash 启动时会通过 Ruby 脚本改写配置，**`short-id` 务必用双引号括起**，否则若 `short-id` 凑巧是纯数字或含特殊前缀，`Step 3` 格式校验会直接报错并停止服务。
- **Hysteria2 限速填写**：客户端 `up` 填写家里真实的**上行带宽**（如 `"50 Mbps"`），不要虚高填写，否则 Brutal 拥塞控制会过量重传导致严重丢包和断流。

**2. Shadowrocket 分享链接模板**

将占位符替换后直接复制导入 Shadowrocket：

```text
vless://uuid-here@111.111.111.111:8443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.apple.com&fp=chrome&pbk=your-reality-public-key&sid=1234abcd&type=tcp&headerType=none#REALITY

hysteria2://your-hy2-password@111.111.111.111:443/?sni=xxx.com&mport=40000-40500&upmbps=50&downmbps=300#HY2
```

---

## 8. 验证、升级与排障

**1. 服务端全面检查**

```bash
# 查看服务状态
systemctl is-active sing-box sing-box-cert-reload.path sing-box-hy2-hop nginx

# 核对监听端口（Nginx 仍在 TCP 443，sing-box 在 TCP 8443 + UDP 443）
ss -tulnp | grep -E 'sing-box|:8443|:443'

# 核对 NAT 端口跳跃规则与 Docker 共存情况
iptables -t nat -L PREROUTING -n

# 确认原有网站访问正常
curl -so /dev/null -w "%{http_code}\n" https://xxx.com/
```

**2. 平滑升级 sing-box**

重复第 3 节下载新版二进制覆盖 `/usr/local/bin/sing-box` 后执行：

```bash
sing-box check -c /etc/sing-box/config.json && systemctl restart sing-box
```

**3. 常见日志与排查**

```bash
journalctl -u sing-box -n 50 --no-pager
```

- **看到少量公网扫描 IP 报 `TLS handshake: REALITY: processed invalid connection`**：属于正常现象，说明扫描器未携带正确 `short_id`/公钥，已被 REALITY 拦截并回落伪装站点。
- **Hysteria2 无法建连**：依次检查 ① UFW 是否放行了 `443/udp` 与 `40000:40500/udp`；② 商家后台安全组是否放行了 UDP；③ 客户端 `sni` 与服务端 `certificate_path` 证书域名是否匹配；④ 客户端 `up`/`down` 是否超过了线路承载能力。
- **REALITY 连不上或延迟高**：检查 VPS 到 `handshake.server`（如 `www.apple.com`）是否能正常返回 `200` 及 `h2`；若使用 IP 直连请确认 `server` 填的是 VPS 公网 IP。
