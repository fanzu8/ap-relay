<p align="center">
  <img src="assets/icon.svg" width="88" height="88" alt="ap-relay icon">
</p>

# ap-relay

[![License: General Pleasure League 1.0](https://img.shields.io/badge/license-General%20Pleasure%20League%201.0-blue.svg)](https://github.com/fanzu8/General-Pleasure-League)
[![Platform: Linux](https://img.shields.io/badge/platform-Linux-informational.svg)](#硬件要求)
[![Shell: POSIX sh](https://img.shields.io/badge/shell-POSIX%20sh-4EAA25.svg)](#脚本幂等性)
[![Version: v0.2.0](https://img.shields.io/badge/version-v0.2.0-blue.svg)](#状态)
[![Docs: English | 中文](https://img.shields.io/badge/docs-English%20%7C%20%E4%B8%AD%E6%96%87-success.svg)](README.md)
[![GitHub: fanzu8/ap-relay](https://img.shields.io/badge/GitHub-fanzu8%2Fap--relay-181717.svg?logo=github)](https://github.com/fanzu8/ap-relay)

[English](README.md) | **中文**

把任意一台 Linux 设备变成 **Wi-Fi 中继 + 透明代理**。

**连上热点即可实现代理 —— 客户端无需任何软件和配置。（交给 AI，很快即可搞定 relay 配置）**

> Turn any Linux box with an AP-capable interface into a Wi-Fi relay with a
> transparent proxy. Clients just connect to the hotspot: no apps, no settings.

本项目是一套**经过实机验证的脚本 + 配置模板 + 踩坑记录**，不包含任何第三方二进制或节点订阅。
参考平台是 OnePlus 6（postmarketOS 25.12 / ath10k），但**手机只是其中一种用法**。

---

## 它解决什么问题

```
[客户端] --WiFi--> [本机: AP] --策略路由--> [mihomo TUN] --代理--> [上行] --> 外网
```

一句话：**客户端零配置**。连上热点，代理和 DNS 自动生效。

具体含义：

- 客户端**不用装任何软件**（不需要 Clash / v2rayNG 之类的客户端）
- 客户端**不用做任何设置**（不设系统代理、不改 DNS）
- 同一台设备**同时**提供 AP 与上行（WiFi STA 或以太网）
- TCP 与 DNS 全覆盖；UDP 是否可用取决于上游机场（见坑 21）
- **本机自身流量不进代理**（策略路由只匹配 `iif <AP 接口>`），代理挂了也不会断 SSH

边界说明：

- 这是**透明代理**，不是 VPN：HTTPS 的端到端加密仍然由客户端与目标站点完成
- “零配置”指客户端；服务端仍然需要装依赖、放配置

## 硬件要求

真正的必要条件只有两条：**一个能做 AP 的接口 + 一个能上网的上行接口**。两者可以是一张卡，也可以是两张。

| 形态 | 可用性 | 说明 |
|---|---|---|
| 单网卡，支持 **AP+STA 并发** | ✅ | 参考平台就是这种；同射频分时，吞吐/延迟打折 |
| **两张网卡**（内置 STA + USB AP） | ✅ 更好 | 空口互不争抢 |
| **以太网 uplink + 一张 AP 网卡** | ✅ 最稳 | 把 `UPLINK_IF` 改成 `eth0`，不涉及并发 |
| 单网卡，不支持 AP+STA 并发 | ❌ | 硬门槛，只能换硬件 |

检查方法见 [docs/porting_zh.md](docs/porting_zh.md)。

## 依赖（不随仓库分发）

| 组件 | 作用 | 备注 |
|---|---|---|
| [mihomo](https://github.com/MetaCubeX/mihomo) | 代理内核 + TUN + 规则 | 官方静态二进制，GPL-3.0 |
| hostapd | 开热点 | 发行版包 |
| dnsmasq | DHCP + DNS 转发 | 发行版包 |
| nftables 或 iptables | NAT + 过滤 | 脚本优先用 nft，缺失时自动回退 iptables |
| iproute2 / iw | 路由与无线管理 | 发行版包 |

面板（zashboard / metacubexd）是可选的静态文件，同样不随仓库分发。

## 目录结构

```
ap-relay/
├── scripts/            # AP 脚本 + mihomo 配置/能力/渲染/校验/编排分层（装到 /usr/local/bin）
├── templates/          # 配置模板（全局变量 / 热点 / mihomo / nft / systemd）
├── platforms/
│   └── padavan/        # MI-R3G 路由器运行时脚本、钩子、变量（原 mihomo-padavan）
├── docs/
│   ├── architecture.md # 数据流与分层理由（英文）
│   ├── architecture_zh.md
│   ├── pitfalls.md     # 21 个坑（本项目的核心价值，英文）
│   ├── pitfalls_zh.md
│   ├── pitfalls_padavan_zh.md   # Padavan 侧踩坑记录
│   ├── troubleshooting.md
│   ├── troubleshooting_zh.md
│   ├── porting.md
│   └── porting_zh.md
└── examples/
    ├── README.md       # 从零到能用的完整步骤（英文）
    └── README_zh.md
```

手机与路由器共用同一份 `templates/mihomo.config.yaml` 和同一套
`scripts/mihomo-*.sh`；平台差异只在变量文件里（手机 `/etc/ap-relay.conf`，
路由器 `/etc/storage/mihomo.conf`）。

共用脚本按职责分层，一个文件只做一件事：

| 层 | 文件 | 职责 |
|---|---|---|
| 配置层 | `mihomo-vars.sh` | 载入平台/私有变量并补默认值；只有数据，没有逻辑 |
| 能力层 | `mihomo-lib.sh` | 定位配置/二进制、读 `secret`、重启、等端口、调用 REST API |
| 纯转换层 | `mihomo-render.sh`、`mihomo-verify.sh` | 模板 → 配置、配置 → 通过/失败；不碰线上状态 |
| 编排层 | `mihomo-apply.sh`、`mihomo-reload.sh`、`mihomo-refresh.sh` | 组合上面各层；只有这三个会操作运行中的实例 |

Padavan 另有一层平台环境 `platforms/padavan/scripts/mihomo-env.sh`
（路径、端口、PID/日志位置、iptables 链名），平台脚本不再各自重抄这些常量。

## 快速开始（概览）

1. 装依赖（mihomo / hostapd / dnsmasq / nftables）
2. 把 `scripts/*.sh` 复制到 `/usr/local/bin`，`templates/ap-relay.conf` 复制到 `/etc/`
3. 按你的环境改 `/etc/ap-relay.conf` 和 `/etc/ap-hotspot.conf`
4. 在 `/etc/ap-relay.local.conf` 写入 `SECRET` 与 `SUB_URL`（权限 600）
5. 用 `mihomo-apply.sh --dry-run` 预览渲染结果，确认后 `mihomo-apply.sh` 生效
6. `systemctl enable --now ap-hostapd ap-dnsmasq ap-mihomo ap-firewall`

完整步骤与验证命令见 **[examples/README_zh.md](examples/README_zh.md)**。

> 端口变量集中在 `/etc/ap-relay.conf`：`GLOBAL_PORT`、`UI_PORT`、`DNS_PORT`、
> `DNS_STD_PORT`、`DHCP_PORT`、`QUIC_PORT`，以及 sniffer 用的
> `HTTP_PORT` / `HTTP_ALT_START` / `HTTP_ALT_END` / `TLS_PORT` / `TLS_ALT_PORT`。
> 默认值是实机验证过的一套：`1008`（mixed）、`7070`（面板/API）、
> `1053`（mihomo DNS，避开上游可能劫持的 53）。mihomo 配置由
> `mihomo-render.sh` 从 `templates/mihomo.config.yaml` 渲染，不再用 `ap-render.sh`
> 直接替换（渲染脚本会校验未定义占位符并强制 600 权限）。

## 设计要点

1. **只抓 AP 接口进来的转发流量**：`ip rule iif <AP> lookup $TABLE_ID` → `default dev <TUN>`。
   本机流量 `iif` 不是 AP，天然绕过代理。
2. **fake-ip + 域名规则前置**：`GEOSITE,google` 必须排在 `GEOIP,CN` 之前，否则 Google 系域名会被
   国内 DNS 解析出的 CDN IP 判成直连（见坑 19）。
3. **QUIC 是否封锁取决于机场**：机场 UDP 中继不可用时必须封（坑 21），可用时不要封。

## 订阅与 geo 自动更新

- `proxy-providers` 用 `type: http`：mihomo 内核按 `SUB_INTERVAL`（默认 6h）自己拉订阅，
  不需要 cron，也不需要外部更新脚本。
- `GEO_AUTO_UPDATE=true` / `GEO_UPDATE_INTERVAL=2160`（90 天）让 geo 库自动更新。
  前提是部署目录里至少已有一个 geo 文件（如 `geoip.metadb`），否则定时器不会注册。
- `SUB_URL` 与 `SECRET` 只写在设备本机：手机 `/etc/ap-relay.local.conf`，
  路由器 `/etc/storage/mihomo.local.conf`（权限 600）。仓库、模板、平台变量文件里都没有真实值。
- 想立刻拉一次订阅：`mihomo-refresh.sh`；只改规则/分组：`mihomo-reload.sh`；
  改了变量或启用项：`mihomo-apply.sh`（会重启并等待端口）。

## 脚本幂等性

所有脚本都可以**重复执行**，不会叠加规则、不会产生重复接口、不会因为“已经存在”而失败：

| 脚本 | 幂等机制 |
|---|---|
| `ap-prep.sh` | 接口已存在则跳过；地址用 `ip addr replace` 而不是 `add` |
| `ap-gen.sh` | 每次全量重渲染；先写临时文件再 `mv`（原子替换，避免 hostapd 读到半截） |
| `ap-render.sh` | 每次全量重渲染；先写临时文件再 `mv`，重复执行结果一致 |
| `ap-fw.sh` | nft 路径整体重建 `inet ap_relay` 表；iptables 路径带 `comment "ap-relay"` 先删后加 |
| `ap-tun-route.sh` | `ip rule` / `ip route` 先删后加；删除用 `while` 循环，能清掉历史重复项 |
| `ap-tun-unroute.sh` | 删除用 `while` 循环，规则不存在也不报错 |
| `ap-mode.sh` | 只改 `BAND` 一行；用 0.2s 轮询等待，而不是固定 `sleep` |

配置的一致性约束（网段、TUN 名、DNS 端口）写在 `templates/ap-relay.conf` 顶部。

## 已知限制

- 单射频设备做 AP+STA 会有空口争用，吞吐和延迟都会打折
- UDP/QUIC 是否可用完全取决于机场，本项目无法修复上游
- 首发只提供 **systemd** unit；OpenRC / runit 需要自己写
- 面板 `secret`、热点密码必须自己改，模板里都是占位符
- 长期插电的电池健康不在本项目范围内，见下方「配套」

## 配套：长期插电运行

把设备当常驻热点，意味着长期插电。电池和电源管理不在本项目范围内，
建议配合 **[chargecap](https://github.com/fanzu8/chargecap)** 使用：

- **充电上限**：限制到 45–50%，避免长期满电导致电池鼓包
- **温度 / 电源通知**：过热、掉电、充满时告警
- **抑制休眠（inhibit sleep）**：保持网络不断，避免系统休眠后热点消失

> chargecap 支持 postmarketOS（mainline 内核）与 Android 7+；
> 手机长期插电做热点时，这三项基本是必需品。

## 文档

| 文档 | 内容 |
|---|---|
| [docs/architecture_zh.md](docs/architecture_zh.md) | 数据流、服务依赖、端口与地址 |
| [docs/pitfalls_zh.md](docs/pitfalls_zh.md) | 21 个真实踩过的坑与验证方法 |
| [docs/pitfalls_padavan_zh.md](docs/pitfalls_padavan_zh.md) | Padavan / MI-R3G 侧踩坑记录 |
| [docs/troubleshooting_zh.md](docs/troubleshooting_zh.md) | 症状 → 命令 → 判断 |
| [docs/porting_zh.md](docs/porting_zh.md) | 换机器/换发行版要改什么 |

> 英文版使用默认文件名（如 `README.md`、`docs/pitfalls.md`）；
> 中文版统一使用 `_zh.md` 后缀。

## 状态

`v0.2.0` —— 在两端完整验证：OnePlus 6（postmarketOS 25.12 / ath10k）与
MI-R3G（Padavan），共用同一份模板和一套脚本。脚本按层拆分
（配置 → 能力 → 转换 → 编排），每个只做一件事；路由器日志自动轮转，不会无限增长。
其他硬件/发行版欢迎反馈，但**不保证开箱可用**。

## 免责声明

本项目涉及网络代理与流量转发，请遵守你所在地区的法律法规。
仓库内不包含任何订阅链接、节点、密钥或第三方二进制。

## License

[General Pleasure League (GPL) 1.0](https://github.com/fanzu8/General-Pleasure-League)
