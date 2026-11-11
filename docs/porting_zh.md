# 移植到其他 Linux

[English](porting.md) | **中文**

## 先做三个检查

### 1. 网卡能不能做 AP（以及能否与 STA 并发）

```sh
iw list | sed -n '/valid interface combinations/,$p' | head -20
```

要能看到类似：

```
#{ managed } <= 2, #{ AP, P2P-client } <= 2, #{ P2P-device } <= 1, total <= 4
```

- 有 `AP` 且 `managed` 和 `AP` 能同时存在 → 单卡方案可行
- 只有 `AP` 或 `total <= 1` → 单卡不行，需要第二张网卡或以太网上行

### 2. TUN 是否可用

```sh
ls -l /dev/net/tun
# 或者
zcat /proc/config.gz 2>/dev/null | grep CONFIG_TUN
```

### 3. 防火墙归谁管

```sh
command -v firewall-cmd ufw nft iptables
systemctl is-active firewalld ufw nftables
```

| 发行版 | 常见情况 | 怎么接 |
|---|---|---|
| Alpine / postmarketOS | `nftables` + `/etc/nftables.d/*.nft` | 直接放 `51_hotspot.nft` |
| Debian / Ubuntu | `ufw` 或裸 `nftables` | 用 `ufw route allow` / 在 `/etc/nftables.conf` 里 include，**不要**和 ufw 抢 `inet filter` |
| RHEL / Fedora | `firewalld` | `firewall-cmd --add-masquerade --add-forward`，不要套用 nft 模板 |
| Arch | 裸 `nftables` 或 iptables | 二选一，保持一致 |

## 要改的变量

全部集中在 `/etc/ap-relay.conf`（模板见 `templates/ap-relay.conf`）：

| 变量 | 说明 |
|---|---|
| `STA_IF` | 上行接口（WiFi 时通常是 `wlan0` 或 `wlp2s0`） |
| `UPLINK_IF` | NAT 出接口；有线上行时改成 `eth0` |
| `AP_IF` | 热点接口名（自己起，运行时创建） |
| `AP_IP` / `AP_CIDR` / `AP_NET` | 热点网段 |
| `DHCP_START` / `DHCP_END` | DHCP 池 |
| `TUN_DEV` | 必须与 mihomo 的 `tun.device` 一致 |
| `TABLE_ID` / `RULE_PREF` | 策略路由表号与优先级 |
| `GLOBAL_PORT` | mihomo mixed 代理端口，必须与 `mixed-port` 一致 |
| `UI_PORT` | 面板 + REST API，必须与 `external-controller` 一致 |
| `DNS_PORT` | 必须与 mihomo 的 `dns.listen` 一致 |
| `DNS_STD_PORT` / `DHCP_PORT` | dnsmasq 对客户端提供 DNS/DHCP 的标准端口 |
| `QUIC_PORT` | 需要拦截的 QUIC 端口 |
| `HTTP_PORT` / `HTTP_ALT_START` / `HTTP_ALT_END` | mihomo sniffer HTTP 端口 |
| `TLS_PORT` / `TLS_ALT_PORT` | mihomo sniffer TLS/QUIC 端口 |
| `DNS_LISTEN` | `dns.listen` 的完整值（手机 `127.0.0.1:1053`，路由器 `0.0.0.0:1053`） |
| `REDIR_LINE` | redirect 模式填 `redir-port: 1009`；TUN 模式整行注释掉 |
| `PROXY_SERVER_NS` | 解析节点域名用的 DoH（必须是 DoH，见坑 3） |
| `TUN_ENABLE` / `TUN_STACK` / `TUN_AUTO_DETECT_INTERFACE` | 该平台是否走 TUN |
| `SNIFFER_OVERRIDE_DESTINATION` / `SNIFFER_HTTP_PORTS` | redirect 为 true，TUN 为 false |
| `GEO_AUTO_UPDATE` / `GEO_UPDATE_INTERVAL` | geo 自动更新开关与间隔（小时） |
| `PROVIDER_NAME` / `SUB_UA` / `SUB_INTERVAL` | 订阅 provider 的名字、UA、拉取间隔 |
| `EXCLUDE_FILTER` / `HEALTH_CHECK_INTERVAL` | 节点排除正则与测速间隔 |
| `SECRET` / `SUB_URL` | **凭据，放本机 `.local.conf`，不进仓库** |

mihomo / nft 模板里的占位符不再需要手工改：

```sh
# nft 仍由 ap-render.sh 渲染
sudo ap-render.sh templates/51_hotspot.nft /etc/nftables.d/51_hotspot.nft

# mihomo 用专用渲染脚本（会校验未定义占位符、强制 600、先写 .new 再原子替换）
sudo mihomo-apply.sh --dry-run     # 预览
sudo mihomo-apply.sh               # 渲染 + 校验 + 备份 + 重启
```

模板中的 `${GLOBAL_PORT}`、`${UI_PORT}`、`${DNS_PORT}`、`${DNS_STD_PORT}`、
`${DHCP_PORT}`、`${QUIC_PORT}`、`${AP_IF}`、`${TUN_DEV}` 等变量都来自
`/etc/ap-relay.conf`；`SECRET` / `SUB_URL` 来自 `/etc/ap-relay.local.conf`。
改配置后重新渲染即可，不需要全局搜索替换。

## 接口名会变吗

| 名字 | 谁定 | 稳定性 |
|---|---|---|
| `wlan0` / `wlp2s0` | 内核 + udev（PCI 设备可预测命名） | 一般稳定；插拔 USB 网卡可能改变顺序 |
| `AP_IF` | 我们自己 `iw ... interface add` | 完全可控 |
| `TUN_DEV` | mihomo 配置 | 完全可控 |

**风险**：机器上出现第二张无线网卡时，`STA_IF` 可能指向错的设备。
硬化办法是按驱动/phy 选接口：

```sh
for p in /sys/class/ieee80211/phy*; do
    drv=$(basename "$(readlink -f "$p/device/driver")")
    echo "$(basename "$p") -> $drv"
done
```

## NetworkManager 会抢接口

如果系统用 NM 管理网络，把 AP 接口设为 unmanaged：

```ini
# /etc/NetworkManager/conf.d/99-ap-relay.conf
[keyfile]
unmanaged-devices=interface-name:<AP_IF>
```

或者干脆用 NM 自己的 AP 模式（`nmcli con add type wifi mode ap`），不用 hostapd。

## 有线上行（最稳）

1. `UPLINK_IF=eth0`
2. `STA_IF` 可以留空或指向任意存在的接口（`ap-prep.sh` 会等它，建议改成 `eth0`）
3. 其余不变

这样完全不涉及 AP+STA 并发，吞吐和稳定性最好。

> 注意：AP 接口仍然要从无线 phy 创建。如果用「有线上行 + 独立 USB AP 网卡」，
> 请让 `AP_IF` 就是那块网卡已有的接口名；否则需要调整 `ap-prep.sh`，
> 从正确的 phy 创建 AP 接口。

## 发行版包名

| 组件 | Alpine | Debian/Ubuntu | Arch |
|---|---|---|---|
| hostapd | `hostapd` | `hostapd` | `hostapd` |
| dnsmasq | `dnsmasq` | `dnsmasq` | `dnsmasq` |
| nftables | `nftables` | `nftables` | `nftables` |
| iptables（可选回退） | `iptables` | `iptables` | `iptables` |
| iw / iproute2 | `iw iproute2` | `iw iproute2` | `iw iproute2` |
| mihomo | 官方静态二进制 | 官方静态二进制 | AUR / 官方二进制 |

## 检查清单

- [ ] `iw list` 里 AP 与 managed 可共存（或改用双网卡/有线上行）
- [ ] `/dev/net/tun` 存在
- [ ] `ip rule` / `ip route` 可用（iproute2）
- [ ] 防火墙方案确定，且不会与模板冲突
- [ ] `/etc/ap-relay.conf` 的接口名、网段与实际一致
- [ ] mihomo 的 `tun.device` / `dns.listen` 与配置一致
- [ ] nft 模板已用 `ap-render.sh` 渲染
- [ ] mihomo 已用 `mihomo-apply.sh` 渲染，`mihomo-verify.sh` 通过
- [ ] 面板 secret、订阅地址已写入 `/etc/ap-relay.local.conf`（600）
- [ ] `ap-diag.sh` 全绿

## 已知不适合的情况

- 网卡驱动不支持 AP 模式（部分 Broadcom / 老 Realtek）
- 单卡且不支持并发，又没有第二个接口
- 系统没有 systemd 且不想写服务脚本（本仓库只提供 systemd unit）
