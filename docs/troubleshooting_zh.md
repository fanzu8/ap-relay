# 排障

[English](troubleshooting.md) | **中文**

先跑一键体检：

```sh
sudo ap-diag.sh
```

> 下面命令里的 `$AP_IF`、`$TUN_DEV`、`$TABLE_ID`、`$UI_PORT`、`$DNS_PORT`
> 等变量来自 `/etc/ap-relay.conf`。在 root shell 里先执行 `. /etc/ap-relay.conf`，
> 或者把它们替换成实际值。

## 症状 → 命令 → 判断

### 客户端连不上热点

```sh
iw dev <AP_IF> info | grep ssid        # AP 是否存在
systemctl status ap-hostapd            # 是否在重启循环
journalctl -u ap-hostapd -n 30
```

- `interface ... not found` → `ap-prep.sh` 没建出接口，看上行接口是否就绪
- 反复 `AP-DISABLED` → 多半是加密/密钥问题（见 pitfalls 中的 -110）

### 能连上，但打不开网页

```sh
cat /var/lib/misc/dnsmasq.leases        # 有没有拿到地址
nslookup www.example.com <AP_IP>         # 是否返回 198.18.x.x
ip rule show | grep iif                 # 策略路由在不在
ip route show table $TABLE_ID
cat /sys/class/net/<TUN>/statistics/rx_packets   # TUN 有没有收包
```

判断顺序：

1. 没有租约 → DHCP 问题（dnsmasq 没起 / 接口不匹配）
2. DNS 不返回假 IP → mihomo DNS 没起，或 dnsmasq 上游不是 `$DNS_PORT`
3. 有假 IP 但 TUN 计数不涨 → 策略路由没生效，或包在 forward 阶段被 iptables 丢了（装了 Docker 时见坑 22）
4. TUN 有包但连不上 → **先查防火墙 input 链是否放行 TUN**（见下）

### TUN 完全没有流量（包没进 TUN）

先确认策略路由在，再看是不是被 iptables 的 `FORWARD` 策略丢了：

```sh
ip rule show | grep iif
iptables -S FORWARD | head
iptables -L FORWARD -v -n | head -3
```

如果看到 `-P FORWARD DROP`，且没有 `ap-relay` 的放行规则，就是 Docker 把
默认策略改成了 DROP（坑 22）。修复：

```sh
sudo ap-fw.sh     # 脚本会幂等补上 AP_IF 和 TUN_DEV 的 FORWARD 放行
```

### TUN 有流量，但 mihomo 连接表是空的

这是最隐蔽的一类：包进了 TUN，但没有一个连接建立成功。

```sh
curl -sS -H "Authorization: Bearer <secret>" http://127.0.0.1:$UI_PORT/connections
```

如果返回 `connections: null`，而 `tcpdump -i <TUN>` 能看到客户端的 SYN：

```sh
sudo nft list chain inet filter input | grep -i tun
```

**原因**：`system`/`mixed` 栈会把连接改写成 `<tun>:x -> <tun>:随机端口` 再从 TUN 进入本机，
`input` 链默认 `policy drop` 时 SYN 被丢掉，永远不回 SYN-ACK。

**修复**：

```sh
sudo nft add rule inet filter input iifname "<TUN>" accept
```

### 只有某个网站打不开（其他正常）

```sh
journalctl -u ap-mihomo -f | grep -E '\[(TCP|UDP)\]'
```

看命中的规则：

- `match GeoIP(cn) using DIRECT` 但目标是境外站点 → 域名被解析到国内 IP，需要把域名规则前置（坑 19）
- `match GeoSite(...) using 🚀 代理` 但连接超时 → 节点问题，换节点/换线路
- 完全没有日志 → 包没进 TUN，或防火墙丢了（`journalctl -k | grep nft-drop`）

### 页面一直转圈（浏览器正常，App 不行）

先确认机场是否支持 UDP：

```sh
curl -sS -H "Authorization: Bearer <secret>" http://127.0.0.1:$UI_PORT/connections \
  | tr '{' '\n' | grep '"network":"udp"' \
  | grep -oE '"host":"[^"]*"|"upload":[0-9]+|"download":[0-9]+' | paste - -
```

`upload` 有值、`download` 恒为 0 = UDP 中继不可用 → 必须封 QUIC（坑 21）。

### 面板打不开

```sh
ss -lntp | grep "$UI_PORT"
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:$UI_PORT/ui/
nft list chain inet filter input | grep "$UI_PORT"
```

- 本机 200、外部超时 → 防火墙没放行来源网段
- 401 → 没带 secret（正常）
- 空白页 → 可能是 Service Worker 缓存（见坑：UI 空白）

### 服务起不来

```sh
systemctl status ap-hostapd ap-dnsmasq ap-mihomo ap-firewall
journalctl -u ap-mihomo -n 50
```

常见原因：

| 现象 | 原因 |
|---|---|
| `ap-prep: 等 <STA_IF> 超时` | 无线驱动没加载 / 接口名不对 |
| `ap-tun-route: TUN 未出现` | mihomo 启动失败（配置错误、端口占用） |
| dnsmasq `address already in use` | 另一个 DHCP/DNS 服务占了 `$DNS_STD_PORT` / `$DHCP_PORT` |
| hostapd `interface not found` | AP 接口没建出来 |

## 抓包

```sh
sudo tcpdump -i <AP_IF> -nn "port $DNS_STD_PORT" # DNS 交互
sudo tcpdump -i <TUN> -nn -c 20                # 客户端流量是否进 TUN
sudo tcpdump -i <TUN> -nn "udp port $QUIC_PORT" # QUIC 尝试
journalctl -k -f | grep nft-drop               # 被防火墙丢掉的包
```

## ap-diag 输出怎么读

| 段 | 正常值 | 异常含义 |
|---|---|---|
| `[1] 服务` | 全 `active` | 有 `inactive/failed` 就看对应 unit |
| `[3] 路由` | 有 `iif <AP>` + table `$TABLE_ID` 两条 | 缺了 = `ap-tun-route.sh` 没跑 |
| `[4] TUN` | 有地址、rx/tx 在涨 | 无地址 = mihomo 没起来 |
| `[5] 防火墙` | 有 TUN 放行规则 | 缺 = 坑 18 |
| `[8] 规则命中` | 有 `GeoSite(...)` 命中 | 大量 `GeoIP(cn) DIRECT` 且是境外域名 = 坑 19 |
| `[9] DNS` | 三个域名都是 `198.18.x.x` | 返回真实 IP = fake-ip 没生效 |
| `[10] 代理` | `204` + 境外出口 IP | 超时 = 节点/订阅问题 |
