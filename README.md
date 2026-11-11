# Configs

My personal used proxy configs.

## 目录

| 目录 | 用途 |
| --- | --- |
| `Clash/clash-verge.yaml` | Clash Verge Rev（mihomo 内核）桌面端配置 |
| `Stash/stash.yaml` | Stash 配置（macOS 4.3+ / iOS 3.6+），由 Clash 配置移植 |
| `Shadowrocket/*.conf` | Shadowrocket 配置：`part_proxy`（分流）、`all_proxy`（全局代理）、`all_direct`（全局直连） |
| `Shadowrocket/modules/` | Shadowrocket 模块，`common.module` 是三份配置共用的规则 |
| `v2ray/V5/client/conf.d/` | v2ray v5 客户端配置（jsonv5，多文件） |
| `v2ray/V5/client/openwrt/` | OpenWrt 透明代理：配置、init.d、iptables / dnsmasq 脚本 |
| `v2ray/V5/server/` | 服务端配置、nginx 反代、systemd 单元 |
| `v2ray/V5/client/openwrt/script/v2ray-update.sh` | OpenWrt 一键更新：安装最新 ipk、检查 v5 启动配置、更新加强版 geo 和 dnsmasq 代理域名列表（需同目录的 `gfwlist.sh`）、重启；`install` 参数启用每日自动更新 |
| `v2ray/V5/server/v2ray-update.sh` | VPS 一键更新：升级 v2ray、固定 jsonv5 启动、更新加强版 geo、重启；`install` 参数启用每日自动更新 |
| `v2ray/update_geo.sh` / `update_geo.bat` | 下载最新 `geoip.dat` / `geosite.dat`（仓库不保存这两个文件），`.bat` 为 Windows 版 |
| `v2ray/system_file_location.md` | 各平台 geo 数据文件的存放路径 |

## 使用前需要替换的占位符

仓库里不保存真实的节点信息，使用前按自己的服务器修改：

- 服务器地址：`111.111.111.111`、域名 `xxx.com`
- UUID：Clash / Stash 里是 `uuid-uuid-uuid-uuid`，v2ray 配置里按各文件注释填写
- WebSocket 路径：Clash / Stash 里是 `/path`，v2ray 里是 `/proxypath`（客户端、服务端、nginx 三处需保持一致）
- `hosts` / DNS 里的 `1.2.3.4`：示例映射，按需修改或删除
- Shadowrocket 规则里的节点名 `NIEKUN.NET VMESS`：需要与 App 内的节点名称一致

## geo 数据

```bash
bash v2ray/update_geo.sh                        # 直连下载
bash v2ray/update_geo.sh http://127.0.0.1:1082  # 通过代理下载
```

Windows：

```bat
.\v2ray\update_geo.bat
.\v2ray\update_geo.bat http://127.0.0.1:1082
```
