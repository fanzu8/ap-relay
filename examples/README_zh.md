# 从零到能用

[English](README.md) | **中文**

以 Alpine / postmarketOS 为例。其他发行版把包管理器换掉即可（见 `docs/porting_zh.md`）。

> 下面命令里的 `$AP_IF`、`$TUN_DEV`、`$GLOBAL_PORT`、`$UI_PORT`、`$DNS_PORT`
> 等变量来自 `/etc/ap-relay.conf`。在 root shell 里先执行 `. /etc/ap-relay.conf`，
> 或者替换成实际值。

## 0. 前置检查

```sh
iw list | grep -A4 'valid interface combinations'   # 要有 AP 与 managed 共存
ls -l /dev/net/tun
ip -V
```

## 1. 装依赖

```sh
# Alpine / postmarketOS
sudo apk add hostapd dnsmasq nftables iw iproute2 curl

# Debian / Ubuntu
# sudo apt install hostapd dnsmasq nftables iw iproute2 curl
```

mihomo 用官方静态二进制（不随本仓库分发）：

```sh
# 以 arm64 为例，版本自行替换
curl -L -o /tmp/mihomo.gz \
  https://github.com/MetaCubeX/mihomo/releases/download/v1.19.33/mihomo-linux-arm64-v1.19.33.gz
gunzip -f /tmp/mihomo.gz
sudo install -m 755 /tmp/mihomo /usr/local/bin/mihomo
mihomo -v
```

## 2. 放脚本和配置模板

```sh
sudo install -m 755 scripts/*.sh /usr/local/bin/
sudo install -m 644 templates/ap-relay.conf   /etc/ap-relay.conf
sudo install -m 600 templates/ap-hotspot.conf /etc/ap-hotspot.conf
sudo install -m 644 templates/systemd/*.service /etc/systemd/system/
sudo mkdir -p /usr/local/share/ap-relay
sudo install -m 644 templates/mihomo.config.yaml /usr/local/share/ap-relay/
sudo mkdir -p /etc/hostapd
sudo systemctl daemon-reload
```

`mihomo-apply.sh` 默认从这里找模板；也可以显式传路径。

## 3. 改配置

```sh
sudo vi /etc/ap-relay.conf     # 接口名、网段、TUN 名、端口
sudo vi /etc/ap-hotspot.conf   # SSID、密码、频段、信道
```

至少要确认：

- `STA_IF` 是真正连上游的那个接口
- `AP_IF` 不与已有接口重名
- `UPLINK_IF` 正确（有线上行改成 `eth0`）

凭据单独放一个只有 root 能读的文件：

```sh
sudo install -m 600 /dev/null /etc/ap-relay.local.conf
sudo tee /etc/ap-relay.local.conf >/dev/null <<'EOF'
SECRET='CHANGE_ME_DASHBOARD_SECRET'
SUB_URL='https://example.com/link/CHANGE_ME?clash=1'
EOF
```

> `SECRET` 和 `SUB_URL` 不要写进 `/etc/ap-relay.conf`，更不要提交到仓库。

## 4. 配 mihomo

```sh
sudo mkdir -p /etc/mihomo/providers
# 预览：渲染 + 校验 + 差异，不动线上配置
sudo mihomo-apply.sh --dry-run

# 确认无误后生效：渲染 → 校验 → 备份 → 替换 → 重启 → 等端口
sudo mihomo-apply.sh
```

说明：

- provider 是 `type: http`，首次启动时 mihomo 会自己按 `SUB_URL` 下载节点到
  `path`，不需要手工放 `providers/*.yaml`。
- `SECRET` / `SUB_URL` 从 `/etc/ap-relay.local.conf` 注入；渲染出的
  `/etc/mihomo/config.yaml` 会被强制设为 600。
- 改完 `/etc/ap-relay.conf` 后重新执行 `mihomo-apply.sh` 即可，不要手改生成物。

geo 数据放本地，避免首次启动时联网拉取（`geo-auto-update` 也需要目录里先有一个 geo 文件）：

```sh
sudo curl -L -o /etc/mihomo/geoip.metadb \
  https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb
sudo curl -L -o /etc/mihomo/geosite.dat \
  https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat
sudo chown root:root /etc/mihomo/geoip.metadb /etc/mihomo/geosite.dat
```

可选：面板（纯静态）

```sh
# 以 zashboard 为例
curl -L -o /tmp/zash.zip https://github.com/Zephyruso/zashboard/releases/download/v3.30.0/dist-no-fonts.zip
sudo mkdir -p /etc/mihomo/ui && sudo unzip -o /tmp/zash.zip -d /tmp/zash
sudo cp -r /tmp/zash/dist/* /etc/mihomo/ui/
```

## 5. 接入防火墙规则

```sh
# 渲染模板：${AP_IF} / ${TUN_DEV} / 端口占位符会自动替换
sudo ap-render.sh templates/51_hotspot.nft /etc/nftables.d/51_hotspot.nft
sudo nft -c -f /etc/nftables.d/51_hotspot.nft     # 语法检查
sudo systemctl restart nftables
```

> NAT 由 `ap-fw.sh` 负责：它优先使用 nft，nft 不存在时回退 iptables。
> Alpine / postmarketOS 装 `nftables` 即可，不需要额外装 iptables。

> 非 Alpine 系统不要直接放这个路径，见 `docs/porting_zh.md` 的防火墙一节。

## 6. 启动

```sh
sudo systemctl enable --now ap-hostapd ap-dnsmasq ap-mihomo ap-firewall
systemctl status ap-hostapd ap-dnsmasq ap-mihomo ap-firewall
```

## 7. 验证

```sh
# 服务
systemctl is-active ap-hostapd ap-dnsmasq ap-mihomo ap-firewall

# 热点
iw dev <AP_IF> info | grep -E 'ssid|channel'

# DNS 是否返回假 IP（关键）
nslookup www.example.com <AP_IP>        # 期望 198.18.x.x

# 代理本身（不经过热点）
curl -x 127.0.0.1:$GLOBAL_PORT -o /dev/null -w '%{http_code}\n' https://www.example.com
# 出口 IP：访问任意“查询我的 IP”网站，应显示节点所在地

# 订阅：确认是 HTTP provider，节点已下载
sudo mihomo-refresh.sh

# 一键体检
sudo ap-diag.sh
```

最后用一台客户端连上热点，打开浏览器访问一个境外站点。

## 8. 出问题

先看：

```sh
sudo ap-diag.sh
journalctl -u ap-mihomo -n 50
journalctl -u ap-hostapd -n 30
```

对照 `docs/troubleshooting_zh.md` 的「症状 → 命令 → 判断」。
