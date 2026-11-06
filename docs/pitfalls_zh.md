# 踩坑清单

[English](pitfalls.md) | **中文**

按“踩到时有多痛”排序。每条都给出**现象 / 原因 / 处理**，能复现的都附命令。

> 命令里的 `$AP_IF`、`$TUN_DEV`、`$UI_PORT`、`$QUIC_PORT` 等变量来自
> `/etc/ap-relay.conf`。在 root shell 里先 `. /etc/ap-relay.conf`，或替换成实际值。
> `nft` 片段里的 `${AP_IF}` 是模板占位符，用 `ap-render.sh` 渲染或直接替换成实际值。

---

## 1. TLS 嗅探改写目标 → 假 SNI 客户端全挂

**现象**：客户端能连上，但所有连接 3 秒后失败。日志里出现：

```
sniffed domain: random.example for tcp:203.0.113.10:40487
failed: dial tcp: lookup random.example: no such host
```

**原因**：部分客户端（加速器、部分 App）使用“假 SNI”——TLS 里的域名是随机串，真实连接只靠 IP。
如果中间层把目标 IP 改写成嗅探到的域名，就会去解析一个不存在的域名。

**处理**：mihomo 里保持

```yaml
sniffer:
  override-destination: false
```

嗅探只用于**匹配规则**，不用于改写目标。

---

## 2. TPROXY 与 REDIRECT 混用 → 自己连自己

**现象**：CPU 飙满、内存暴涨、连接数爆炸。

**原因**：配置里同时开了 `sockopt.tproxy` 和 iptables `REDIRECT`。
REDIRECT 的目标是 `SO_ORIGINAL_DST`，而 tproxy 让进程把自己的监听地址当成目标 → 自我连接。

**处理**：二选一，不要混。本项目用 TUN，两者都不需要。

**教训**：这类错误语法检查会通过、进程也是 `active`，只有看日志里的目标地址才能发现。

---

## 3. 5GHz + WPA2 装密钥超时（-110）

**现象**：`AP-ENABLED` 之后 3 秒变成 `AP-DISABLED`，日志里有 `-110 (ETIMEDOUT)`。

**原因**：hostapd 在 AP 起来后要装组播密钥（GTK），固件在这条 WMI 命令上超时。
开放网络不需要装 GTK，所以不触发。

**处理**（按顺序试）：

1. `GROUP_REKEY=0`（关闭组密钥轮换）
2. 换到 2.4GHz
3. 换网卡（USB AP）
4. 等固件修

**不要**试 `cryptmode=1`（见坑 15）。

---

## 4. `setsid` 起的进程会被 systemd 一起杀掉

**现象**：手动测试正常，写成服务后子进程莫名消失。

**原因**：systemd 默认用 cgroup 管理，`setsid` 只是脱离会话，没脱离 cgroup。

**处理**：用 `systemd-run --unit=...`，或老老实实写一个 unit。

---

## 5. `tproxy` 是 nftables 保留字

**现象**：`nft add table inet tproxy` 报语法错误。

**处理**：表名换一个（如 `inet filter`）。这是命名冲突，不是权限问题。

---

## 6. macOS `networksetup` 假阴性

**现象**：在 Mac 上扫描不到热点，以为 AP 没广播。

**原因**：新版 macOS 的 `networksetup -listallnetworkservices` / 扫描行为不可靠。

**处理**：换一台设备（手机/另一台电脑）验证，或用 `wdutil` / 系统设置界面确认。

---

## 7. `ip nat` 表被 iptables-nft 接管

**现象**：

```
# Warning! table ip nat is managed by iptables-nft, do not touch!
```

手工 `nft` 改完，`iptables` 一看又变回去了。

**处理**：统一用一个后端。要么全用 `iptables`，要么全用 `nft`，不要交叉修改同一张表。

---

## 8. nft `input` 默认 drop 会拦掉热点客户端

**现象**：客户端能连上 Wi-Fi，但拿不到 IP 或解析不了域名。

**原因**：`input` 链 `policy drop`，而 DHCP(`$DHCP_PORT`)/DNS(`$DNS_STD_PORT`) 没有放行。

**处理**：

```nft
iifname "${AP_IF}" udp dport ${DHCP_PORT} accept
iifname "${AP_IF}" tcp dport ${DNS_STD_PORT} accept
iifname "${AP_IF}" udp dport ${DNS_STD_PORT} accept
```

---

## 9. dnsmasq 因日志文件权限起不来

**现象**：`dnsmasq: cannot open log /var/log/dnsmasq.log: Permission denied`。

**处理**：交给 journal，不要自己写文件：

```
--log-facility=-
```

---

## 10. 演示用的阻断规则是雷，会误伤别人的 App

**现象**：为了验证“流量真的走了代理”，加了一条 `block <公共 DNS 的 IP>`，
结果客户端上的代理 App 启动时探测公共 DNS 全部失败，表现为“连上这个热点就上不了网”。

**处理**：测试完立刻删。阻断规则要限定到具体域名/端口，不要用公共 DNS 当靶子。

---

## 11. 改 MAC 是死路

**现象**：为了排查 AP 问题去改 MAC，结果什么都没解决。

**处理**：AP 的问题基本都在驱动/固件/信道/加密，不在 MAC。别在这上面浪费时间。

---

## 12. 设备上访问不了 GitHub Releases

**现象**：`curl` 下载 mihomo 超时或被重置。

**处理**：在电脑上下载，再 `scp` 进去。或者用可信镜像。
**不要**在设备上反复重试，浪费时间。

---

## 13. BusyBox 的 `ip` / `ps` 没有 GNU 选项

**现象**：`ip -br`、`ps -p <pid>` 报 `unrecognized option`。

**处理**：

```sh
ip -o addr show <if>          # 代替 ip -br
grep VmRSS /proc/<pid>/status # 代替 ps -o rss
```

---

## 14. `unudhcpd` 也占着 `0.0.0.0:67`

**现象**：`ss -lunp` 看到两个进程监听 67。

**原因**：部分手机镜像自带 `unudhcpd`（USB 网络用）。

**处理**：dnsmasq 用 `--interface=<AP> --bind-interfaces`，只绑热点接口即可共存。
如果 DHCP 行为异常，先确认没有两个 DHCP 同时应答同一网段。

---

## 15. `cryptmode=1` 让 Wi-Fi 整卡消失

**现象**：改完模块参数后，`wlan0` / AP 接口全没了，SSH 也断了。

**原因**：`ath10k_snoc: cryptmode > 0 requires raw mode support from firmware`
→ `fatal problem with firmware features: -22` → probe 失败，整张卡不创建。

**处理**：

```sh
sudo rm -f /etc/modprobe.d/ath10k-cryptmode.conf
sudo modprobe -r ath10k_snoc && sudo modprobe ath10k_snoc
```

**教训**：改任何影响 probe 的模块参数前，先留一条不走 Wi-Fi 的通道（USB 网络 / 串口）。

---

## 16. AP 接口是运行时创建的，必须由 unit 重建

**现象**：重启后 `hostapd` 报 `interface not found`，无限重启。

**原因**：AP 接口是 `iw dev <STA> interface add <AP> type __ap` 造出来的，重启即消失。

**处理**：把它放进 `ExecStartPre`，并**等上行接口就绪**：

```ini
ExecStartPre=/usr/local/bin/ap-prep.sh
ExecStartPre=/usr/local/bin/ap-gen.sh
ExecStart=/usr/sbin/hostapd /etc/hostapd/ap.conf
```

验证（不用重启）：

```sh
sudo ip link del <AP_IF>
sudo systemctl restart ap-hostapd
iw dev <AP_IF> info | grep ssid
```

---

## 17. 等待逻辑别用固定 `sleep`

**现象**：启动慢、偶发抢跑（接口还没出现就往下执行）。

**处理**：轮询 + 上限，发现即返回：

```sh
i=0
while [ $i -lt 150 ]; do
    ip link show "$STA_IF" >/dev/null 2>&1 && break
    sleep 0.2; i=$((i+1))
done
```

固定 `sleep 4` 既慢又不可靠；1 秒轮询则浪费启动时间。

---

## 18. TUN 栈的环回需要 `input` 放行 【最隐蔽】

**现象**：客户端 DNS 正常（拿到假 IP），包也进了 TUN，但**一个连接都建立不起来**；
`/connections` 永远是空。

```
# tcpdump -i <TUN>
192.168.43.100.55206 > 198.18.0.25.443: Flags [S]
198.18.0.2.10104    > 198.18.0.1.38881: Flags [S]   ← 然后没有下文
```

**原因**：`system` / `mixed` 栈把连接改写成 `<tun 地址> → <tun 地址:随机端口>`，
再从 TUN **作为入站包**送进内核。这条路径走的是 `input` 链，而 `input` 默认 `policy drop`。

**处理**：

```sh
sudo nft add rule inet filter input iifname "<TUN>" accept
```

**为什么所有检查都“看起来对”**：`ip rule`、`ip route get`、DNS、TUN 计数全都正常，
唯一的异常点是连接表为空。**看到“TUN 有包 + 连接表空”，先查 input 链。**

---

## 19. 国内 DNS + `GEOIP,CN` 把境外站点判成直连

**现象**：某些站点（典型是 Google 系）打不开，其他正常。日志：

```
[TCP] --> media.example.com:443 match GeoIP(cn) using DIRECT
dial tcp 203.0.113.20:443: i/o timeout
```

**原因**：国内 DNS 会把 Google 系域名解析到国内 CDN/运营商缓存 IP，`GEOIP,CN` 判成直连，
而那个 IP 实际不可达。

**处理**：**域名规则必须排在 `GEOIP,CN` 之前**：

```yaml
- GEOSITE,google,🚀 代理
- GEOSITE,youtube,🚀 代理
- DOMAIN-SUFFIX,<你的目标域名>,🚀 代理
- GEOSITE,cn,DIRECT
- GEOIP,CN,DIRECT
- MATCH,🚀 代理
```

**为什么这样就够**：fake-ip 让 mihomo 知道域名，命中域名规则后把**域名**交给节点，
由节点自己解析——出口 IP 才是对的。

---

## 20. `tcp-concurrent`：一个被自己 A/B 推翻的“根因”

**背景**：排查“App 白屏、浏览器正常”时，一度把 `tcp-concurrent: true` 当成主因，
因为关掉后某次压测从 3~9 秒降到 1 秒。

**后来的 A/B（运行时切换，交替多轮）**：

| 并发 | `true` | `false` |
|---|---|---|
| 25 | 25/25，0.72s | 25/25，0.73s |
| 60 | 60/60，0.72s | 60/60，0.67s |

**没有可测差异。** 之前那次劣化是机场/上行的**瞬时拥塞**，不是这个开关造成的。

**处理**：保持 `false` 只是“少放大一点拨号”的保守选择，**不要把它写成因果结论**。

**可复用的教训**：

1. 单次 A/B 不足以定因，网络状况是时变的，必须交替多轮
2. 先把“链路本身”量化清楚：WiFi 带宽（`nc` 打流）和外网带宽要分开测
3. App 对“并发 + 超时”敏感，浏览器不敏感——现象差异 ≠ 链路差异

---

## 21. 机场 UDP 只发不收 → QUIC 必须封

**现象**：YouTube App 白屏几秒后提示“无网络”，浏览器却能正常播放。

**判定方法**（不用客户端）：

```sh
curl -sS -H "Authorization: Bearer <secret>" http://127.0.0.1:$UI_PORT/connections \
  | tr '{' '\n' | grep '"network":"udp"' \
  | grep -oE '"host":"[^"]*"|"upload":[0-9]+|"download":[0-9]+' | paste - -
```

```
host: api.example.com   upload: 7200   download: 0
host: api.example.com   upload: 4800   download: 0
```

**upload 一直涨、download 恒为 0** = 包发出去了，节点从没回过包。

**原因**：

- VLESS + XTLS Vision 协议本身不支持 UDP
- 或者机场侧没开 UDP 中继（即使节点写了 `udp: true`）

**处理**：封 QUIC，让客户端回落 TCP：

```nft
iifname "${AP_IF}" udp dport ${QUIC_PORT} counter reject
```

用 `reject`（ICMP port unreachable）而不是 `drop`，客户端能立刻知道不通，回落更快。

**如果你的机场 UDP 正常**：不要封，删掉这条规则即可，QUIC 体验更好。

---

## 22. Docker 把 iptables `FORWARD` 策略改成 DROP → 热点客户端完全不通

**现象**：客户端能连上 Wi-Fi、能拿到 IP、DNS 也能返回假 IP，但 TUN 的
`rx_packets` 几乎不涨，`/connections` 是空的；把 mihomo 停掉走内核转发也不通。
看起来像“策略路由失效”，但 `ip rule` / `ip route show table $TABLE_ID` 都正常。

**判定**：

```sh
iptables -S FORWARD | head
iptables -L FORWARD -v -n | head -3
```

典型的 Docker 现场：

```
-P FORWARD DROP
-A FORWARD -j DOCKER-USER
-A FORWARD -j DOCKER-FORWARD
Chain FORWARD (policy DROP 27196 packets, 2582K bytes)
```

**原因**：`dockerd` 启动时会把 `ip filter` 表的 `FORWARD` 默认策略设成
`DROP`，再插入自己的 `DOCKER-USER` / `DOCKER-FORWARD`。nft 的
`inet filter` 和 iptables 的 `ip filter` 是**两张独立的表**，`inet` 里的
`accept` 不能覆盖另一张表的 `policy drop`。所以策略路由把包指到了 TUN，
包却在 `forward` 阶段先被 iptables 丢掉了。

**修复**：

```sh
sudo iptables -I FORWARD 1 -i "$AP_IF"  -m comment --comment "ap-relay" -j ACCEPT
sudo iptables -I FORWARD 1 -i "$TUN_DEV" -m comment --comment "ap-relay" -j ACCEPT
```

`ap-fw.sh` 已内置这两条（幂等，重跑即可恢复）：

```sh
sudo ap-fw.sh
```

**为什么“重启后才坏”**：Docker 的 iptables 规则不落盘，每次 `dockerd`
启动都会重新把 `FORWARD` 策略设成 `DROP`。它不是覆盖你写的规则，而是每次
开机都把默认策略重新设成 `DROP`。`ap-firewall.service` 是 oneshot，只在
开机跑一次，不会在 Docker 起来后再复查——所以放行规则必须在
`ap-firewall` 里主动补上，并插在链首，避免被 Docker 后插入的链挡在前面。

**不要这样做**：

- 不要用 `"iptables": false` 关掉 Docker 的 iptables 管理来“绕过”——
  容器网络和 NAT 会一起坏掉。
- 只加 nft `inet filter forward` 的 `accept` 不够；它管不到 iptables 的
  `policy drop`（本仓库的 `51_hotspot.nft` 模板就是如此，必须配合
  `ap-fw.sh` 的 iptables 放行）。
- 不需要加定时器轮询：规则插在 `FORWARD` 链首，Docker 之后启动也挡不住它。
