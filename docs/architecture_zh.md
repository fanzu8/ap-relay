# 架构

[English](architecture.md) | **中文**

## 数据流

```
┌──────────────────── 客户端（手机/电脑，无需任何配置）────────────────────┐
│ DHCP 拿到：IP <AP_NET>.x / 网关 AP_IP / DNS AP_IP                    │
└───────────────────────────────┬─────────────────────────────────────┘
                                │ Wi-Fi（AP 接口）
                     ┌──────────▼──────────┐
                     │ hostapd             │  SSID / 频段 / 加密
                     │ ap-hostapd.service  │
                     └──────────┬──────────┘
        ┌───────────────────────┴────────────────────────┐
        │ DNS :$DNS_STD_PORT                              │ 其它所有流量
┌───────▼──────────────┐                        ┌─────────▼──────────────┐
│ dnsmasq              │                        │ ip rule iif <AP>       │
│ ap-dnsmasq           │                        │ → table $TABLE_ID      │
│ 转发到                │                        │ → default dev <TUN>    │
│ 127.0.0.1:$DNS_PORT  │                        └─────────┬──────────────┘
└───────┬──────────────┘                                  │
        │              ┌─────────────────────────────────▼──────────────┐
        └─────────────►│ mihomo TUN（stack: mixed）                      │
                       │ fake-ip 198.18.0.0/16                          │
                       │ 还原域名 → GEOSITE / GEOIP 分流                  │
                       └─────────────────────┬──────────────────────────┘
                                             │ 代理 / DIRECT
                       ┌─────────────────────▼──────────────────────────┐
                       │ ap-fw.sh：ip_forward + MASQUERADE              │
                       └─────────────────────┬──────────────────────────┘
                                             │
                                  上行接口（STA 或 eth0）
                                             ▼
                                          外网
```

## 服务

| 服务 | 职责 | 启动顺序 |
|---|---|---|
| `ap-hostapd` | `ExecStartPre` 建 AP 接口、渲染配置，然后起 hostapd | 最先（`After=network.target`） |
| `ap-dnsmasq` | DHCP + 把 DNS 转发到 mihomo | `After=ap-hostapd` |
| `ap-mihomo` | TUN + 规则分流；`ExecStartPost` 加策略路由，`ExecStopPost` 撤销 | `After=ap-hostapd`，`Before=ap-firewall` |
| `ap-firewall` | `ip_forward` + NAT + 放行 AP 入站 + 放行 iptables `FORWARD`（oneshot，优先 nft；防止 Docker 的 policy drop 挡住转发，见坑 22） | 最后（`After=ap-hostapd, nftables`） |

## 脚本

| 脚本 | 调用者 | 作用 |
|---|---|---|
| `lib.sh` | 被其它脚本 source | 读取 `/etc/ap-relay.conf`，提供默认值 |
| `ap-prep.sh` | hostapd `ExecStartPre` | 等上行接口 → 建 AP 接口 → 配 IP（幂等） |
| `ap-gen.sh` | hostapd `ExecStartPre` | 由 `ap-hotspot.conf` 渲染 `hostapd.conf` |
| `ap-mode.sh` | 手动 | `24g` / `5g` 切换，轮询等待 AP 起来 |
| `ap-render.sh` | 手动 | 用 `/etc/ap-relay.conf` 渲染 nft 等模板里的 `${...}` 占位符 |
| `mihomo-vars.sh` | 被其它脚本 source | 配置层：载入平台变量 + `.local.conf`，只补默认值 |
| `mihomo-lib.sh` | 被其它脚本 source | 能力层：定位配置/二进制、读 secret、重启、等端口、调用 REST API |
| `mihomo-render.sh` | 手动 / `mihomo-apply.sh` | 渲染 mihomo 模板，拒绝未定义占位符，输出强制 600 |
| `mihomo-verify.sh` | 手动 / `mihomo-apply.sh` | 结构自检 + `mihomo -t` |
| `mihomo-apply.sh` | 手动 | 渲染 → 校验 → 备份 → 替换 → 重启 → 等端口，失败回滚 |
| `mihomo-refresh.sh` | 手动 / 定时可选 | 立刻刷新一个 provider |
| `mihomo-reload.sh` | 手动 | 校验后热重载配置（`-f` 回退重启） |
| `ap-fw.sh` | `ap-firewall` | 开转发 + NAT + 放行 AP 入站 + 放行 iptables `FORWARD`（优先 nft，回退 iptables） |
| `ap-tun-route.sh` | mihomo `ExecStartPost` | 加 `ip rule` / table `$TABLE_ID` / `rp_filter=0` / 放行 TUN 入站 |
| `ap-tun-unroute.sh` | mihomo `ExecStopPost` | 撤规则（流量回落内核转发） |
| `ap-diag.sh` | 手动 | 一键体检 |
| `ap-debug.sh` | 手动 | 切换 mihomo 日志级别 |

## 脚本分层

共用脚本按依赖方向分四层，下层不知道上层的存在：

```
配置层  mihomo-vars.sh        变量与默认值（纯数据）
   │
能力层  mihomo-lib.sh         路径/端口/secret/API（纯函数，不读配置）
   │
转换层  mihomo-render.sh      模板 → 配置（原子替换、600）
        mihomo-verify.sh      配置 → 通过/失败（只读）
   │
编排层  mihomo-apply.sh       渲染→校验→备份→替换→重启→等端口→回滚
        mihomo-reload.sh      校验→热重载
        mihomo-refresh.sh     立刻刷新 provider
```

平台差异不在命令脚本里：手机是变量文件 + systemd，路由器是变量文件 +
`platforms/padavan/scripts/mihomo-env.sh`（路径、端口、PID/日志、链名）。
这样新增设备时只需要补“变量文件 + 环境层 + 启动方式”，渲染、校验、编排完全复用。

## 地址与端口

| 接口 | 地址 | 说明 |
|---|---|---|
| AP | `AP_IP/24`（默认 `192.168.43.1`） | 网关 + DNS |
| TUN | `198.18.0.1/30`（mihomo 自动） | 不是可配置项，由 fake-ip 段决定 |
| 上行 | 由 DHCP 获得 | STA 或以太网 |

> 端口变量来自 `/etc/ap-relay.conf`，括号内是默认值。
> dnsmasq 用 `53`，mihomo 用 `1053`（避开上游可能劫持的明文 53），
> 两者分别绑定 AP 接口和 `127.0.0.1`，不会冲突。

| 端口 | 说明 |
|---|---|
| `$DNS_STD_PORT`/udp+tcp | dnsmasq（只绑 AP 接口，默认 53） |
| `$DHCP_PORT`/udp | dnsmasq DHCP（默认 67） |
| `$DNS_PORT` | mihomo fake-ip DNS（只监听 127.0.0.1，默认 1053） |
| `$GLOBAL_PORT` | mihomo mixed（HTTP+SOCKS，默认 1008） |
| `$UI_PORT` | 面板 + REST API（默认 7070；务必设 secret 并限制来源） |

## 三种 TUN 栈

| 栈 | TCP 谁处理 | UDP 谁处理 | 内存 | 备注 |
|---|---|---|---|---|
| `system` | 内核（环回监听 `<tun>:随机端口`） | 内核 | 低 | 默认；依赖内核环回路径 |
| `gvisor` | gVisor 用户态 | gVisor | 高 | 完全不碰内核环回，最可预测 |
| `mixed` | 内核 | gVisor | 中 | 推荐：TCP 用成熟内核栈，UDP 用用户态 |

判断当前用的是哪种（不用查文档）：

```sh
sudo ss -lntp | grep mihomo | grep 198.18
# 有输出 = TCP 走内核栈；没有 = 纯用户态
```

## 设计取舍

| 决定 | 原因 |
|---|---|
| 只匹配 `iif <AP>` | 本机流量不进代理；代理挂了 SSH/面板不受影响 |
| 手工 `ip rule` 而不是 `auto-route: true` | 后者会改默认路由、劫持整机 |
| fake-ip + 域名规则前置 | 避免国内 DNS 解析结果影响分流判断 |
| QUIC 用 `reject` 而不是 `drop` | 客户端能立刻知道不通，回落 TCP 更快 |
| `ap-tun-unroute.sh` 在服务停止时清理 | 失败降级：回落到内核转发 + NAT，客户端不断网 |

## 与 OpenWrt 路由器方案的关系

架构是同源的：`hostapd + dnsmasq + NAT + 代理内核 + 策略路由`。
在 OpenWrt 上对应的是 Nikki / OpenClash / passwall 这类方案。

差别不在架构，而在平台约束：

| 维度 | 路由器 | 手机 / 移动设备 |
|---|---|---|
| 上行 | 通常有线 WAN | 通常是 WiFi STA（单射频） |
| AP 接口 | 开机即有 | 运行时 `iw interface add` 创建，重启即消失 |
| 空口 | AP/STA 分射频或有线，不争抢 | 单射频分时复用，吞吐与延迟打折 |
| 配置体系 | UCI + LuCI，有现成包 | 纯文件 + systemd，需要自己拼 |
| 硬件加速 | 常有 NAT / 加密 offload | 基本没有，全部走 CPU |
| 电源与散热 | 长期供电 | 电池、温控、可能休眠 |
| 驱动可靠性 | 为长期运行设计 | 固件坑多（见坑 3、坑 15） |
| 救援通道 | 串口 / 网口 | USB 网络（如果设备支持） |

所以本项目的定位不是“发明新方案”，而是：**把路由器上成熟的做法搬到没有 UCI、
没有现成包、只有一张射频的设备上，并把踩过的坑记录下来。**

## 失败模式

| 故障 | 结果 |
|---|---|
| mihomo 崩溃/重启 | `ExecStopPost` 撤策略路由 → 流量走内核转发 + NAT（直连，不翻墙，但不断网） |
| hostapd 崩溃 | `Restart=always` 重试；`$AP_IF` 由 `ap-prep.sh` 重建 |
| dnsmasq 崩溃 | 客户端拿不到 DHCP/DNS；已有租约的客户端仍可通信但解析失败 |
| 面板 `$UI_PORT` 暴露 | **默认就暴露在 AP 网段**，必须改 secret 并用防火墙限制来源 |
