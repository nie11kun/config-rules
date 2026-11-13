# OpenWrt 安装 OpenClash 教程（Fake-IP + TUN）

用 OpenClash（mihomo / Meta 内核）替代原来的 v2ray + dnsmasq nftset 透明代理方案。配置文件是同目录的 [`openclash.yaml`](openclash.yaml)。

## 目录

1. [环境与方案选择](#1-环境与方案选择)
2. [远程操作前：回滚定时器](#2-远程操作前回滚定时器)
3. [安装依赖](#3-安装依赖)
4. [停用旧的 v2ray 方案](#4-停用旧的-v2ray-方案)
5. [安装 OpenClash](#5-安装-openclash)
6. [下载内核](#6-下载内核)
7. [插件设置](#7-插件设置)
8. [准备配置文件](#8-准备配置文件)
9. [启动与验证](#9-启动与验证)
10. [开机自启与计划任务](#10-开机自启与计划任务)
11. [升级备份列表](#11-升级备份列表)
12. [控制面板说明](#12-控制面板说明)
13. [故障排查](#13-故障排查)
14. [回滚到 v2ray 方案](#14-回滚到-v2ray-方案)

---

## 1. 环境与方案选择

本文基于以下环境：

| 项目 | 值 |
| --- | --- |
| 系统 | OpenWrt 23.05.3 |
| 架构 | x86_64 |
| 防火墙 | firewall4（nftables） |
| DNS | dnsmasq-full |
| 远程管理 | 通过 Tailscale 访问路由器 |

**为什么选 OpenClash，不选 Nikki**

Nikki（原 luci-app-mihomo）更轻量，但只支持 OpenWrt 24.10 及以上。在 23.05 上运行它的安装脚本会报 `unsupported release: 23.05.3`。如果你已经是 24.10，可以考虑 Nikki；23.05 用 OpenClash。

**相比 v2ray + dnsmasq 的好处**

- fake-ip 模式下，所有 DNS 都由内核接管，连接时按域名匹配规则，分流不再依赖 dnsmasq 把 IP 写进 nftset 的时机。
- 有策略组和 rule-provider，规则集由内核每天自动更新，不再需要自己写更新脚本。
- TCP 和 UDP 都能经 TUN 统一处理。

---

## 2. 远程操作前：回滚定时器

如果你是远程登录路由器（比如通过 Tailscale），代理一旦启动出错，可能连远程连接一起断掉。**每次启动、重启 OpenClash 或改它的设置之前**，先在后台埋一个 5 分钟后自动停掉 OpenClash 的定时器：

```bash
pkill -f "openclash-guard" 2>/dev/null; kill $(cat /tmp/openclash-guard.pid) 2>/dev/null
(sleep 300; /etc/init.d/openclash stop; logger -t openclash-guard "auto stopped") >/dev/null 2>&1 &
echo $! > /tmp/openclash-guard.pid
```

第一行先清掉之前没取消的定时器。如果不清，旧的定时器会在你确认一切正常之后照样到点停掉 OpenClash。

确认一切正常后，取消定时器：

```bash
kill $(cat /tmp/openclash-guard.pid) 2>/dev/null; jobs
```

`jobs` 没有输出，说明后台已经没有定时器了。如果断线了，就等 5 分钟，OpenClash 会自动停掉，网络随之恢复。

---

## 3. 安装依赖

```bash
opkg update && opkg install kmod-tun kmod-nft-tproxy ip-full ca-bundle curl
```

确认 TUN 设备可用，并查看内存和存储空间：

```bash
ls /dev/net/tun && free -m && df -h /overlay
```

内存至少 256MB，规则多的话最好 512MB 以上。存储方面，内核加规则集需要几十 MB 空间。

**dnsmasq 必须是 dnsmasq-full**

```bash
opkg list-installed | grep dnsmasq
```

如果显示的是 `dnsmasq-full`，跳过这一步。如果只有 `dnsmasq`，先把 dnsmasq-full 下载到本地再替换。顺序不能反：先删掉 dnsmasq 的话，路由器自己就没法解析域名，也就下载不了新包。

```bash
cd /tmp && opkg download dnsmasq-full
opkg remove dnsmasq && opkg install /tmp/dnsmasq-full_*.ipk
[ -f /etc/config/dhcp-opkg ] && mv /etc/config/dhcp-opkg /etc/config/dhcp; /etc/init.d/dnsmasq restart
```

OpenClash 的其余依赖：

```bash
opkg install bash coreutils-nohup libcap libcap-bin ruby ruby-yaml unzip kmod-inet-diag luci-compat
```

---

## 4. 停用旧的 v2ray 方案

两套透明代理同时运行，防火墙规则和 DNS 会互相冲突。旧方案必须先清干净。

**停止服务，删除 nft 表**

```bash
/etc/init.d/transparent stop; /etc/init.d/transparent disable
/etc/init.d/v2ray stop; /etc/init.d/v2ray disable
nft delete table ip v2ray 2>/dev/null
```

**删除每日更新任务**

先看一眼要删的是哪一行，再删：

```bash
grep v2ray-update /etc/crontabs/root
sed -i '/v2ray-update/d' /etc/crontabs/root && /etc/init.d/cron restart
```

**清理 dnsmasq 配置**

OpenClash 用 fake-ip 时，dnsmasq 会把所有查询转给 Clash。`/etc/dnsmasq/` 里的下面这些文件会跟它冲突：

| 文件 | 处理 | 原因 |
| --- | --- | --- |
| `proxy-gfwlist.conf`、`proxy-added.conf` | 移走 | 里面的 `nftset` 指向已经删掉的 v2ray 表，分流改由 Clash 规则负责 |
| `apple-server.conf` | 移走 | `server=/apple.com/223.5.5.5` 这类配置会绕过 Clash DNS |
| `base.conf` | 删掉 `all-servers` 和所有 `server=` 行，**保留** `address=/*.home.marco/...` | 内网域名还要靠它解析 |
| `reject-*.conf` | 删除 | 去广告改由 Clash 的 `ads` 规则集负责（🛑 广告拦截 组默认 REJECT，每天自动更新）；`custom_reject` 已包含 360 等域名。dnsmasq 的列表不会自动更新，保留只会越来越旧 |

```bash
mkdir -p /etc/dnsmasq.bak && cd /etc/dnsmasq
mv proxy-gfwlist.conf proxy-added.conf apple-server.conf reject-*.conf /etc/dnsmasq.bak/
cp base.conf /etc/dnsmasq.bak/ && sed -i '/^all-servers/d;/^server=/d' base.conf
/etc/init.d/dnsmasq restart
```

dnsmasq 重启时可能输出 `udhcpc: no lease, failing`。这是启动脚本在检测局域网里有没有别的 DHCP 服务器，"no lease" 表示没有，属于正常输出。

---

## 5. 安装 OpenClash

到 GitHub 上 `vernesong/OpenClash` 的 Releases 页面，下载最新的 `luci-app-openclash_*_all.ipk`，用 scp 传到路由器的 `/tmp`，然后安装：

```bash
opkg install /tmp/luci-app-openclash_*_all.ipk
```

安装结束时输出的 `cfgXXXXXX` 是 OpenClash 初始化 uci 配置时打印的，不是报错。装完刷新 LuCI，菜单里会出现 **服务 → OpenClash**。

---

## 6. 下载内核

在 **服务 → OpenClash → 插件设置 → 版本更新**：

| 选项 | 设置 | 说明 |
| --- | --- | --- |
| 编译版本 | `linux-amd64-v1` 或 `v3` | 见下方 AVX2 检查 |
| 更新分支 | Master | 默认下载 Meta alpha 内核 |
| Smart 内核 | 停用 | 见下方说明 |

**选 v1 还是 v3**

```bash
grep -o -w avx2 /proc/cpuinfo | head -1
```

- 有输出：CPU 支持 AVX2，可以用 `v3`，性能会稍好一些。
- 没有输出：只能用 `v1`。选 `v3` 的话，内核根本起不来。

**Smart 内核是什么**

Smart 内核是 OpenClash 作者维护的 mihomo 分支，多了一种 `smart` 策略组，会根据各节点过去的延迟、成功率等数据自动挑选节点。它适合节点很多的机场订阅。只有一个自建节点时用不上，保持停用即可。

下载失败的话，可以在同一页换一个下载地址（jsdelivr 等 CDN），或者手动上传内核安装包。

---

## 7. 插件设置

### 7.1 模式设置

| 选项 | 设置 |
| --- | --- |
| 运行模式 | **Fake-IP（TUN）模式**，对应 uci 里的 `en_mode='fake-ip-tun'` |
| TUN 堆栈 | **Mixed**（见下表） |
| 路由本机代理 | **关闭** |

**TUN 堆栈怎么选**

| 堆栈 | TCP 处理 | UDP 处理 | 性能 | 兼容性 |
| --- | --- | --- | --- | --- |
| System | 内核协议栈 | 内核协议栈 | 最好 | 个别环境下 UDP 有问题 |
| gVisor | 用户态协议栈 | 用户态协议栈 | CPU 和内存占用高 | 最好 |
| **Mixed** | 内核协议栈 | 用户态协议栈 | 接近 System | 接近 gVisor |

一般选 Mixed。游戏或语音的 UDP 不正常时换 gVisor；追求最高吞吐时试 System。

> ⚠️ 已知问题：在界面上保存堆栈设置时，可能被写成无效值 `mips`，导致 TUN 网卡起不来。每次在界面改完设置都检查一下：
>
> ```bash
> uci get openclash.config.stack_type
> ```
>
> 如果不是 `mixed`，用命令行改回来：
>
> ```bash
> uci set openclash.config.stack_type='mixed' && uci commit openclash && /etc/init.d/openclash restart
> ```

**为什么要关闭"路由本机代理"**

关掉后，路由器自己的流量（`tailscaled`、opkg 等）不经过 Clash，只有局域网设备的流量会走代理。这样即使 OpenClash 出了问题，Tailscale 远程访问也不会断。

### 7.2 DNS 设置

| 选项 | 设置 |
| --- | --- |
| 本地 DNS 劫持 | 开启，方式选 **使用 Dnsmasq 转发** |
| 覆写设置 → 自定义上游 DNS 服务器 | **不要启用**，否则配置文件里 `dns` 段的上游会被替换掉 |

### 7.3 GEO 数据库订阅

`openclash.yaml` 的分流全部用 `.mrs` 规则集，没有 `GEOIP`、`GEOSITE`、`IP-ASN` 规则，所以用不到 GEO 数据库。在 **插件设置 → GEO 数据库订阅** 里，把 GeoIP、GeoSite、GeoIP Dat、GeoASN 的自动更新都关掉。

这些任务不要去 crontab 里手动删。带 `#openclash-cron-task` 标记的行由 OpenClash 自己管理，保存或重启时会重新写回去。

---

## 8. 准备配置文件

以 [`openclash.yaml`](openclash.yaml) 为基础，把节点信息里的占位符换成你自己的：

| 占位符 | 替换为 |
| --- | --- |
| `111.111.111.111` | 服务器地址或域名 |
| `uuid-uuid-uuid-uuid` | UUID |
| `xxx.com` | TLS SNI 和 WebSocket 的 Host |
| `/path` | WebSocket 路径，与服务端、nginx 保持一致 |

在 **配置文件管理** 上传这个文件。上传后它存放在 `/etc/openclash/config/` 下。

### 配置要点

- **端口、`tun` 段、DNS 监听、`enhanced-mode`、`fake-ip-range`**：这些由 OpenClash 界面管理，启动时会覆盖，配置文件里不用写。
- **YAML 1.1 的坑**：OpenClash 会先用 Ruby（YAML 1.1）改写配置。不加引号的 `off`、`on`、`yes`、`no` 会被当成布尔值，所以必须加引号，比如 `find-process-mode: "off"`。不加引号的话，内核会报 `invalid find process mode`。
- **规则集路径**：OpenClash 会把 rule-providers 的 `path` 统一改到 `./rule_provider/`，实际文件位于 `/etc/openclash/rule_provider/`。
- **`*.home.marco` 内网域名**：
  - 在 `fake-ip-filter` 里，所以返回真实 IP，不会被分配假地址；
  - `nameserver-policy` 把它交给本机的 dnsmasq（`127.0.0.1`）解析；
  - 嗅探的 `skip-domain` 也包含它，避免直连时拿域名去国内 DNS 解析而失败。
- **Tailscale 和内网网段**：`100.64.0.0/10`、`fd7a:115c:a1e0::/48`、`192.168.x.x` 都在 `private_ip` 规则集里，这是第一条规则，全部直连。
- **未匹配的 UDP 直连**：Tailscale、RustDesk 打洞以及 BT、游戏 P2P 大多是直接连 IP 的 UDP。送进代理会导致打洞失败，所以兜底规则前面加了 `NETWORK,UDP,DIRECT`。
- **自定义列表只放上游规则集没收录的域名**：增删前可以先查一下域名是否已在 `geolocation-!cn`、`cn` 等规则集里，避免重复。
- **GLOBAL 组**：配置里重新定义了内置的 GLOBAL 组，只列出 🚀 节点选择、out-vmess、DIRECT。它只在全局模式下起作用。

---

## 9. 启动与验证

先埋好[回滚定时器](#2-远程操作前回滚定时器)，然后在 LuCI 的 **运行状态** 页点"启动"，或者执行：

```bash
/etc/init.d/openclash start
```

启动日志里出现"OpenClash 启动成功"就可以开始验证。

**1. 远程连接**

新开一个 SSH 或 LuCI 会话（用 Tailscale 地址或 `openwrt.home.marco`），确认还能连上。

**2. DNS**

```bash
nslookup nas.home.marco 127.0.0.1; nslookup google.com 127.0.0.1; nslookup baidu.com 127.0.0.1
```

| 域名 | 预期结果 |
| --- | --- |
| `nas.home.marco` | `192.168.122.5`，真实内网 IP |
| `google.com` | `198.18.x.x`，fake-ip 生效 |
| `baidu.com` | `198.18.x.x` 也正常，连接时会被 `cn_domain` 规则匹配后直连 |

**3. 进程、TUN、堆栈**

```bash
pgrep -af clash | head -3
ip addr show utun | grep inet
grep -A2 "^tun:" /etc/openclash/*.yaml
```

正常的话会看到：

- 内核进程 `/etc/openclash/clash -d /etc/openclash ...` 和守护进程 `openclash_watchdog.sh`；
- `inet 198.18.0.1/30`；
- `stack: mixed`。

**4. 规则集**

```bash
ls -la /etc/openclash/rule_provider/
grep -iE "provider|rule-set" /tmp/openclash.log | tail
```

目录里应该有 19 个 `.mrs` 文件（inline 规则集不生成文件），日志里没有报错。规则集是通过 🚀 节点选择 下载的，能下载下来也说明节点是通的。

**5. 分流**

在局域网设备上分别打开 google.com、chatgpt.com、baidu.com，然后在控制面板的"连接"页核对它们走的策略组：

| 网站 | 预期策略组 |
| --- | --- |
| google.com | 🚀 节点选择 |
| chatgpt.com | 🤖 AI 服务 |
| baidu.com | DIRECT |

全部正常后，[取消回滚定时器](#2-远程操作前回滚定时器)。

---

## 10. 开机自启与计划任务

**开机自启**

```bash
ls /etc/rc.d/ | grep -i openclash; uci get openclash.config.enable
```

需要看到 `S99openclash`、`K15openclash` 和 `1`。缺哪项就补上：

```bash
/etc/init.d/openclash enable; uci set openclash.config.enable='1'; uci commit openclash
```

确认旧方案不会开机启动：

```bash
ls /etc/rc.d/ | grep -iE "v2ray|transparent"
```

这条应该没有输出。

找个方便的时间运行一次 `reboot` 实测。1～2 分钟后连回来，确认 `pgrep -af clash` 和 `utun` 都正常。

**每周定时重启**（可选）

每周一凌晨 1 点重启，排在 OpenClash 周一 0 点的 GEO 更新之后：

```bash
sed -i 's|^0 1 \* \* \* /sbin/reboot|0 1 * * 1 /sbin/reboot|' /etc/crontabs/root && /etc/init.d/cron restart
crontab -l
```

第 5 个字段是星期几：`0` 是周日，`1` 是周一，依此类推。cron 用的是路由器本地时区，可以检查一下：

```bash
uci get system.@system[0].zonename; date
```

正常应该显示 `Asia/Shanghai`，`date` 的时间也应该和本地一致。

---

## 11. 升级备份列表

`/etc/sysupgrade.conf` 里列出的文件，会在系统升级或用 LuCI 备份时保留。`/etc/config/openclash` 在 `/etc/config/` 下，系统默认就会保留，但上传的配置文件和自定义规则要手动加进来。`core/` 和 `rule_provider/` 能重新下载，不用备份。

```bash
cat > /etc/sysupgrade.conf <<'EOF'
## This file contains files and directories that should
## be preserved during an upgrade.

# 系统
/etc/crontabs/
/etc/ethers
/etc/installed_packages.txt

# dnsmasq（base.conf 内网域名；.bak 是旧 v2ray 代理列表）
/etc/dnsmasq/
/etc/dnsmasq.bak/
/etc/dnsmasq.conf

# OpenClash（/etc/config/openclash 默认已保留；core、rule_provider 可重新下载，不备份）
/etc/openclash/config/
/etc/openclash/custom/

# 旧 v2ray 方案，留作回滚；OpenClash 稳定运行一段时间后可删除这几行
/etc/init.d/transparent
/etc/init.d/v2ray
/etc/v2ray/
EOF
```

检查实际会备份哪些文件：

```bash
sysupgrade -l | grep -E "openclash|dnsmasq|v2ray|crontabs"
```

---

## 12. 控制面板说明

OpenClash 自带 MetaCubeXD 等控制面板，可以切换规则、全局、直连模式，选节点，查看连接和日志。

**面板上改的设置只对当前运行有效。** 面板是通过 API 直接改正在运行的内核，不会写回 OpenClash。OpenClash 一重启（开机、更新规则、在 LuCI 里点"应用"），就会按 uci 设置重新生成配置，面板上的改动会被覆盖。

- 长期设置（TUN、堆栈、端口）：在 OpenClash 的 LuCI 页面或用 uci 改。
- 分流规则：改 `openclash.yaml`。

**GLOBAL 组**只在全局模式下起作用，规则模式下选什么都不影响分流。全局模式会把内网和 Tailscale 的流量也送进代理，只建议临时排查问题时用。

---

## 13. 故障排查

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| Nikki 安装脚本报 `unsupported release: 23.05.3` | Nikki 只支持 24.10 及以上 | 改用 OpenClash，或者先升级系统 |
| 内核日志报 `Parse config error: invalid find process mode` | 不加引号的 `off` 被 Ruby 改写成了 `false` | 改成 `find-process-mode: "off"` |
| 界面上的"TUN 转发"自动关闭，`utun` 不存在 | `stack_type` 被保存成了 `mips` | 用 `uci set openclash.config.stack_type='mixed'` 改回，然后重启 |
| `/etc/openclash/ruleset/` 目录不存在 | OpenClash 把路径改成了 `rule_provider/` | 去 `/etc/openclash/rule_provider/` 下看 |
| `rule_provider/` 是空的 | 节点不通，规则集经代理下载失败 | 检查节点配置，看 `/tmp/openclash.log` |
| `*.home.marco` 返回 `198.18.x.x` | fake-ip-filter 没生效 | 在 覆写设置 → DNS → Fake-IP-Filter 里再加一遍 |
| OpenClash 莫名其妙停了 | 之前的回滚定时器没取消，到点执行了 stop | 先清掉旧定时器再埋新的（见第 2 节）；守护进程通常会自动把内核拉起来 |
| 游戏或语音的 UDP 不正常 | 堆栈兼容性问题 | 把 TUN 堆栈换成 gVisor 试试 |
| Tailscale 远程连接断开 | 开了路由本机代理，或者用了全局模式 | 关闭路由本机代理，切回规则模式 |

常用日志：

```bash
tail -50 /tmp/openclash.log
logread | grep -iE "openclash|openclash-guard" | tail -30
```

---

## 14. 回滚到 v2ray 方案

```bash
/etc/init.d/openclash stop; /etc/init.d/openclash disable; uci set openclash.config.enable='0'; uci commit openclash
mv /etc/dnsmasq/base.conf /etc/dnsmasq/base.conf.openclash
cp /etc/dnsmasq.bak/* /etc/dnsmasq/
/etc/init.d/dnsmasq restart
/etc/init.d/v2ray enable; /etc/init.d/v2ray start
/etc/init.d/transparent enable; /etc/init.d/transparent start
echo '0 5 * * * sh /etc/v2ray/script/v2ray-update.sh update 2>&1 | logger -t v2ray-update' >> /etc/crontabs/root && /etc/init.d/cron restart
```

`/etc/dnsmasq.bak/` 里存着原来的 `base.conf` 和三个代理列表，复制回去就恢复了原来的 DNS 分流。
