# 坑与经验

在 MI-R3G + Padavan + mihomo 这套部署上实际踩过的坑，按「现象 → 原因 → 结论」记录，排障时可直接对照。

环境：mihomo v1.19.28 / v1.19.33，`redirect` 模式，`/media/mtd_rwfs/mihomo` 为持久目录，`/etc/mihomo` 为软链。

---

## 1. 订阅只更新「节点」，其余全是手写

**现象**：以为更新订阅会把 DNS、分组、规则一起带过来。

**原因**：本方案用 `proxy-providers` 只吃订阅里的 `proxies:` 段。`dns`、`hosts`、`sniffer`、`tun`、`proxy-groups`、`rules`（5000+ 条）都是手写在 `config.yaml` 里的。

**结论**

- 订阅更新只改变「有哪些节点」，不碰任何策略。
- 规则是**一次性抄来的副本**，抄完就冻结；机场改规则时路由器不会跟。
- 想跟着订阅走，只能在外部生成整份配置再推过来 —— mihomo 没有 Verge 那种 merge/script 机制。

自查：

```sh
grep -c '^proxy-providers' config.yaml    # 订阅里通常没有这一段
grep -c '^  - ' providers/juzi.yaml       # 节点数（本项目是 48，排除后 44）
```

---

## 2. 「节点全灭」不等于机场挂了：先看解析到的 IP

**现象**：provider 健康检查 0/44，日志刷满 `dial tcp <IP>:<port>: i/o timeout`。

**排查顺序**（按这个顺序一次就能定位，别从头猜）

1. 统计**每天失败拨号涉及的不同目标 IP 数**：
   - 每天 20–40 个不同 IP、只挂几个 → 正常波动；
   - 某天突然收敛到**固定 4 个**且全线失败 → 解析结果被钉死到不可达边缘。
2. 用 check-host.net 从境外节点探同一 `IP:port`：能连（0.07–0.26 s）→ **服务器没挂、端口开着**，是国内到该 IP 的链路被拦。
3. `traceroute` 看断点：走到 CMNET 国际出口后无回应 → 链路问题，不是路由黑洞。
4. 同一份订阅放到另一台客户端（Clash Verge）上试：能通 → 一定是**解析差异**。

**结论**：公共 DNS 返回的是机场 CDN 的香港边缘（`220.246.x` / `42.3.25.x`，netvigator），从国内拨 `i/o timeout`；机场私有 DoH 返回国内中转（`155.117.198.x`），可直连。**节点没坏，是域名被解析到了被封的入口。** 旧/新订阅的 endpoint 参数逐字节相同，也说明订阅内容不是原因。

---

## 3. `proxy-server-nameserver` 必须用 DoH，不能用明文 53

关键配置（本方案最终形态）：

```yaml
dns:
  enable: true
  # 引导解析 DoH 域名本身，必须留公共 IP
  default-nameserver:
    - 223.5.5.5
    - 119.29.29.29
  # 日常域名解析：国内公共 DoH
  nameserver:
    - https://dns.alidns.com/dns-query
    - https://doh.pub/dns-query
  # 只负责解析「代理服务器自己的地址」，必须是 DoH
  proxy-server-nameserver:
    - https://dns.alidns.com/dns-query
```

> 也可以填机场给的私有 DoH/DoT（如 `https://query.<机场私有 DoH>/dns-query` +
> `tls://query.<机场私有 DoH>:8453`）。关键是**不能是明文 53**：上游一旦劫持
> UDP/TCP 53，节点域名会被解析成 fake-ip 或过期的边缘 IP，表现为全节点超时。

`hosts`：

```yaml
hosts:
  dns.alidns.com: [223.5.5.5, 223.6.6.6]
  doh.pub: [1.12.12.12, 120.53.53.53]
```

四条硬性经验：

1. **`default-nameserver` 不能换成 DoH** —— 解析 DoH 域名本身会自举失败，保持公共 IP。
2. **`proxy-server-nameserver` 不要加明文 DNS 兜底** —— 一旦退回明文 53，就可能又解析到被封的香港边缘，问题原样复发。
3. **DoH 和 DoT 指向同一套系统**，可作冗余；别混明文 DNS。
4. `hosts` 里给 DoH 域名钉死 IP 是好习惯，避免 DNS 循环。

> 只改 `proxy-server-nameserver` 这一段就够了，`nameserver`（日常上网）不用动，否则国内站点可能被解析到海外边缘、变慢。

---

## 4. 「同名不同簿」：机场 DoH 与公共 DoH 的答案不一样

同一个节点域名，两边给出完全不同的地址：

| 解析器 | 节点域名答案 | 本网络可达性 |
|---|---|---|
| 公共 DNS / 阿里 DoH / doh.pub | `220.246.x`、`42.3.25.x`（香港 CDN 边缘） | 不可达 |
| 机场私有 DoH | `155.117.198.x`（国内中转） | 可达 |

对普通域名差异同样明显：机场 DoH 查 `www.baidu.com` 会给海外 CDN 边缘，查 `www.google.com` 给真实 IP；阿里 DoH 反之。所以**机场 DoH 只适合放 `proxy-server-nameserver`，不能当日常 `nameserver`**。

---

## 5. 路由器其实有 `curl`：在 `/usr/sbin`

**坑**：在非交互式 SSH 里执行 `which curl` 返回 not found，于是误判「路由器没 curl」。实际文件在：

```text
/usr/sbin/curl   # curl 8.8.0 (mipsel-unknown-linux-gnu) libcurl/8.8.0 OpenSSL/3.0.14
```

**原因**：非交互 SSH 的 `PATH` 只有 `/usr/bin:/bin`，没有 `/usr/sbin`；部署脚本自己设了 `PATH=/sbin:/usr/sbin:/usr/bin:/bin`，所以脚本里一直能用。

**结论**：判断「有没有某命令」不能只靠 `which`，至少要看 `PATH` 里有哪些目录：

```sh
echo $PATH
for d in /usr/bin /usr/sbin /bin /sbin /opt/bin; do ls "$d" | grep -x curl; done
```

---

## 6. BusyBox `wget` 会被机场前置 WAF 拦，`curl` 不会

**现象**：路由器上用 `wget` 抓订阅失败：

```text
HTTP/1.1 302 Found
Location: /GE/CC/VALIDATOR?key=...&url=...
HTTP/1.1 403 Forbidden
```

`curl`（同 UA、同 IP、同一时刻）直接 `200`。

**结论**：这是客户端指纹/反爬校验，不是网络问题、也不是「没有工具」。抓订阅优先用 `curl`；`wget` 只适合抓静态文件（GitHub releases 那种）。

---

## 7. 让订阅真正自动更新：provider 用 `type: http`

`type: file` 的 provider 只监听本地文件，必须外部下载好再放进去。换成 `type: http` 后，**mihomo 自己按 `interval` 下载**，不需要 cron，也不需要 curl：

```yaml
proxy-providers:
  juzi:
    type: http
    url: "https://<订阅域名>/link/<TOKEN>?clash=1"
    path: ./providers/juzi.yaml
    interval: 21600            # 秒，6h
    header:
      User-Agent:
        - "clash-verge/v2.0.0"
    exclude-filter: '(?i)回家页|查看公告'
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 180
```

要点：

- `header` 的值是**数组**（`map[string][]string`）。不带 UA 时该机场直接拒绝，浏览器 UA 和 `clash-verge/v2.0.0` 都能用；统一用后者只为两份配置逐字节一致。
- 订阅返回的是**整份 config**（含 groups/rules），provider 解析时只取 `proxies`，实测没问题（48 条解析、排除后 44 条）。
- 是否带 `&meta=1` 实测返回内容相同（只差几百字节），统一去掉。
- 首次下载前若 `path` 已有旧文件，mihomo 会先用旧文件，再按文件 mtime + `interval` 决定何时拉新的。
- 想立刻拉一次：`mihomo-refresh.sh`，或
  `curl -X PUT -H "Authorization: Bearer <secret>" http://127.0.0.1:7070/providers/proxies/juzi`
  （HTTP provider 会重新下载，返回 204；失败返回 503 + JSON）。

---

## 8. 热重载能换 provider 类型，但换不了 geo 定时器

- `PUT /configs?force=true`（body `{"path":"/etc/mihomo/config.yaml"}`）返回 204 后，provider 的 `vehicleType` 立刻从 `File` 变成 `HTTP`，**进程不用重启**。
- 但 geo 的定时器是在 **进程启动时** 用 `geo-update-interval` 注册的（`main.go` 里 `RegisterGeoUpdater()`），改这个数字**必须重启**进程才生效。

验证 vehicleType：

```sh
curl -s -H "Authorization: Bearer <secret>" http://127.0.0.1:7070/providers/proxies/juzi \
  | grep -o '"vehicleType":"[^"]*"'
```

---

## 9. `geo-auto-update` 的隐藏前提：至少存在一个 geo 文件

**坑**：全新目录下开了 `geo-auto-update: true`，日志只报：

```text
[GEO] Get GEO database update time error: stat .../GeoSite.dat: no such file or directory
```

然后什么都不下载，看起来「开了没反应」。

**原因**：`getUpdateTime()` 依次 `stat` `GeoIP.dat` / MMDB / `ASN.mmdb` / `GeoSite.dat`，**一个都不存在时直接返回错误，注册流程就此 `return`**，定时器根本没建起来。

**结论**：

- 目录里至少要有 `geoip.metadb`（本项目就是靠它触发的）。
- `geodata-mode: false` + 存在 `geoip.metadb` 时，走的是 `UpdateMMDB`（下载 `geoip.metadb`，约 8.4 MB），不是 `geoip.dat`。
- 没有 `GEOSITE` 规则时不会去下 `geosite.dat`；没有 ASN 需求也不下 `GeoLite2-ASN.mmdb`。

---

## 10. geo 更新失败不影响代理

`component/updater/update_geo.go` 的顺序是：

```go
data, hash, err := vehicle.Read(...)    // 整份下载到内存
if err != nil { return err }            // 失败：旧文件不动
if oldHash.Equal(hash) { return nil }   // 内容没变：只更 mtime
maxminddb.FromBytes(data)               // 校验新库可用
mmdb.IPInstance().Reader.Close()        // 通过后才替换
vehicle.Write(data)
defer mmdb.ReloadIP()                   // 热加载
```

所以下载中断、超时、4xx/5xx、残包、损坏，全部**不会动旧库**，代理照常跑；更新本身在独立 goroutine 里，不阻塞启动和已有连接。

**唯一的边角情况**：如果失败恰好发生在「启动时那次初始更新」（即开机时文件已超过间隔），那个 goroutine 会直接 `return`，**本次进程生命周期内不再定时更新**，直到下次重启。代理依然正常。

---

## 11. geo 间隔与 flash 写入量

默认 `geo-update-interval: 24`（小时）→ 每天下载并重写约 **8.4 MB**，一年约 3 GB，对 NAND 偏多。

按需要拉长：

```yaml
geo-auto-update: true
geo-update-interval: 2160    # 90 天，约 34 MB/年
```

代价是 geo 数据最多旧 90 天。本项目只有 1 条 `GEOIP,CN,DIRECT` 兜底规则（0 条 GEOSITE），过期只会让**极个别新分配 IP** 被误判（国内走了代理、或海外走了直连），不影响 DNS/节点/域名规则。

---

## 12. 刚重载/重启时，healthcheck 读数不可信

重启后第一次读 provider 状态可能只有 `33/44`，等十几秒并发测速跑完再读是 `42/44`。**别拿刚启动的瞬时数字下结论**，等一轮 `interval` 跑完再看，或手动触发：

```sh
# 注意触发测速是 GET；用 PUT 会 404
curl -X GET -H "Authorization: Bearer <secret>" \
  http://127.0.0.1:7070/providers/proxies/juzi/healthcheck
```

---

## 13. 改配置的安全流程（本项目一直在用）

1. 本地改好，`diff` 确认只动了预期的那几行。
2. `scp` 到 `/tmp/new-config.yaml`。
3. **沙盒校验**：必须把依赖文件一起拷进去，否则会因缺 provider / geo 库误报失败：

   ```sh
   mkdir -p /tmp/mtx/providers
   cp /tmp/new-config.yaml /tmp/mtx/config.yaml
   cp /media/mtd_rwfs/mihomo/providers/*.yaml /tmp/mtx/providers/
   cp /media/mtd_rwfs/mihomo/geoip.metadb /tmp/mtx/
   /media/mtd_rwfs/mihomo/mihomo -t -d /tmp/mtx -f /tmp/mtx/config.yaml
   ```

4. `mv` 覆盖 `config.yaml`（同分区、原子）。
5. 优先热重载：`mihomo-reload.sh` 或 `PUT /configs?force=true`；涉及 provider 类型 / geo 间隔这类**启动时固化**的配置才重启。
6. 重启后核对：`pidof mihomo`、4 个端口、`iptables -t nat -S PREROUTING | grep MIHOMO`、以及经 1008 实际访问一次。

---

## 14. iptables 只劫持 `-i br0`，路由器自身流量是直连

`mihomo-fw.sh` 的规则挂在 `nat PREROUTING -i $LAN_IF`，所以：

- 局域网客户端流量 → REDIRECT 到 1009；
- **路由器自己发起的流量不被劫持**（因此路由器上跑 `curl`/`wget` 是「真直连」）。

这条既是设计（避免路由器自身成环），也是排障工具：想测「不经代理能不能通」，用路由器本地命令；想测「经代理通不通」，从 Mac 打 `192.168.2.1:1008`。

---

## 15. macOS + Clash Verge TUN 下测 DNS 会拿到 fake-ip

开了 TUN 的 Mac 上，`nslookup`/`curl` 直连测试返回的是 `198.18.x`（fake-ip），所有连接都会「瞬间 OPEN」，测不出真实可达性。

真直连测试要绕开 TUN：

```sh
# 先拿到真实 IP，再绑网卡 + 钉 IP
curl --interface en0 --resolve host:443:<真实IP> https://host/...
```

同理，判断「节点死没死」不要在被 TUN 劫持的机器上做裸 TCP 探测。

---

## 16. `/tmp` 是 tmpfs，备份放那里等于没有

路由器 `/tmp` 在内存里，重启即清空。备份请放 `/media/mtd_rwfs/`；如果只是本次操作的临时回滚，放 `/tmp` 也行，但要清楚它活不过重启。

---

## 17. 常用 API 小抄

external-controller 只监听 `127.0.0.1:7070` 时，从 Mac 上排障用隧道：

```sh
ssh -f -N -L 17070:127.0.0.1:7070 admin@192.168.2.1
S=$(ssh admin@192.168.2.1 "awk -F': ' '/^secret:/{print \$2; exit}' /etc/mihomo/config.yaml | tr -d \"'\"")
```

| 动作 | 请求 |
|---|---|
| 读 provider（含 `vehicleType` / `updatedAt` / `subscriptionInfo`） | `GET /providers/proxies/<name>` |
| **重新下载** HTTP provider | `PUT /providers/proxies/<name>` → 204 / 503 |
| 触发测速 | `GET /providers/proxies/<name>/healthcheck` → 204 |
| 分组当前选中 | `GET /proxies` |
| 活动连接（看实际拨到哪个 IP） | `GET /connections` |
| 热重载配置 | `PUT /configs?force=true`，body `{"path":"/etc/mihomo/config.yaml"}` |

小细节：`PUT /providers/proxies/<name>/healthcheck` 会 404，测速是 **GET**。

---

## 18. `subscription-userinfo` 能看流量和到期

HTTP provider 会把订阅响应头里的 `subscription-userinfo` 存下来，`GET /providers/proxies/<name>` 返回：

```json
{"Upload":..., "Download":..., "Total":..., "Expire":<unix秒>}
```

顺手做个流量/到期监控比反复登录机场面板方便。

---

## 排查清单（速查）

1. 节点不通 → 先看 `provider healthcheck`，再看日志里失败拨号的**目标 IP 分布**。
2. IP 收敛且固定 → 查 `proxy-server-nameserver`，对比公共 DoH 与机场 DoH 的答案。
3. 服务器是否活着 → check-host.net 境外探测 + traceroute。
4. 订阅更新失败 → 用 `curl`，别用 BusyBox `wget`。
5. 数字不对 → 等一轮测速，别信刚重启的瞬时值。
6. 改配置 → 沙盒 `-t` 校验 → 热重载优先，必要时重启。
