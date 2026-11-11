#!/bin/sh
# 一键体检。排障先跑这个，别一条条猜。
# 用法：sudo ap-diag.sh [连接明细条数，默认 10]
#
# 本脚本只读：变量来自 lib.sh，secret 解析复用 mihomo 能力层，
# 保证与 refresh / reload 用同一套解析规则（能正确处理引号）。
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/mihomo-lib.sh"

# 依赖检查：缺工具时给出提示，而不是输出一堆空行
for c in curl nslookup systemctl nft; do
	command -v "$c" >/dev/null 2>&1 || echo "ap-diag: 警告：缺少 $c，相关检查会被跳过" >&2
done

SECRET=$(mihomo_secret) || SECRET=
API=http://127.0.0.1:$UI_PORT
N=${1:-10}
line() { printf '%s\n' "------------------------------------------------------------"; }
q() { curl -sS -H "Authorization: Bearer $SECRET" "$API$1" 2>/dev/null; }

line; echo "[1] 服务"
systemctl is-active ap-hostapd ap-dnsmasq ap-mihomo ap-firewall 2>/dev/null | tr '\n' ' '; echo

line; echo "[2] Wi-Fi"
echo "上行($STA_IF): $(iw dev "$STA_IF" link 2>/dev/null | grep -E 'SSID|signal' | tr -d '\t' | tr '\n' ' ')"
echo "热点($AP_IF): $(iw dev "$AP_IF" info 2>/dev/null | grep -E 'ssid|channel' | tr -d '\t' | tr '\n' ' ')"
echo "客户端: $(iw dev "$AP_IF" station dump 2>/dev/null | grep -c '^Station') 个"
awk '{printf "  %-18s %s\n", $3, $4}' /var/lib/misc/dnsmasq.leases 2>/dev/null

line; echo "[3] 策略路由"
ip rule show | grep -E "iif $AP_IF" || echo "  !! 缺少 iif $AP_IF 规则（ap-tun-route.sh 没跑？）"
ip route show table "$TABLE_ID" 2>/dev/null | sed 's/^/  /'

line; echo "[4] TUN"
ip -o addr show "$TUN_DEV" 2>/dev/null | awk '{print "  "$2" "$4}'
echo "  rx=$(cat /sys/class/net/$TUN_DEV/statistics/rx_packets 2>/dev/null)  tx=$(cat /sys/class/net/$TUN_DEV/statistics/tx_packets 2>/dev/null)"
echo "  drop=$(cat /sys/class/net/$TUN_DEV/statistics/rx_dropped 2>/dev/null)"

line; echo "[5] 防火墙"
nft list chain inet filter input 2>/dev/null | grep -E "iifname \"$TUN_DEV\"|nft-drop" | sed 's/^/  /'
echo "  最近被丢（journalctl -k）:"
journalctl -k --since "-30min" -o cat 2>/dev/null | grep 'nft-drop' | tail -5 | sed 's/^/    /'
if command -v iptables >/dev/null 2>&1; then
	pol=$(iptables -S FORWARD 2>/dev/null | awk '/^-P FORWARD/{print $2}')
	fw=$(iptables -S FORWARD 2>/dev/null | grep -c 'ap-relay')
	echo "  iptables FORWARD: policy=${pol:-?} ap-relay规则=${fw:-0}"
	if [ "$pol" = "DROP" ] && [ "${fw:-0}" -lt 2 ]; then
		echo "  !! FORWARD 是 DROP 且缺少 ap-relay 放行（Docker 改了默认策略，见坑 22；sudo ap-fw.sh 修复）"
	fi
fi

line; echo "[6] mihomo"
echo "  版本 : $(/usr/local/bin/mihomo -v 2>/dev/null | head -1 | cut -c1-40)"
echo "  内存 : $(awk '/VmRSS/{printf "%.0f MB", $2/1024}' /proc/$(pgrep mihomo | head -1)/status 2>/dev/null)"
[ -n "$SECRET" ] && echo "  累计 : $(q /connections | tr ',' '\n' | grep -E 'downloadTotal|uploadTotal' | tr '\n' ' ')"
echo "  活跃连接（次数 host -> 出口）:"
q /connections | tr '{' '\n' | grep -oE '"host":"[^"]*"|"chains":\[[^]]*\]' | paste - - 2>/dev/null \
  | sed 's/"//g' | sort | uniq -c | sort -rn | head -"$N" | sed 's/^/    /'

line; echo "[7] 最近连接（含命中规则）"
journalctl -u ap-mihomo --since "-15min" -o cat 2>/dev/null | grep -E '\[(TCP|UDP)\]' | tail -"$N" \
  | sed 's/.*msg="//; s/"$//' | sed 's/^/  /'

line; echo "[8] 规则命中统计（最近 1 小时）"
journalctl -u ap-mihomo --since "-1h" -o cat 2>/dev/null \
  | grep -oE 'match [A-Za-z()0-9,._-]+ using' | sed 's/ using//' | sort | uniq -c | sort -rn | head -8 | sed 's/^/  /'
echo "  ⚠ 若境外域名出现 match GeoIP(cn) using DIRECT，说明域名规则没前置（坑 19）"

line; echo "[9] DNS（客户端路径，应返回 198.18.x.x）"
for d in www.google.com www.youtube.com www.baidu.com; do
  printf '  %-22s -> %s\n' "$d" "$(nslookup "$d" "$AP_IP" 2>/dev/null | awk '/^Address: /{print $2}' | tail -1)"
done

line; echo "[10] 代理连通性"
curl -sS -x 127.0.0.1:$GLOBAL_PORT -m 12 -o /dev/null -w "  generate_204: %{http_code} (%{time_total}s)\n" \
  https://www.gstatic.com/generate_204 2>&1 | tail -1
echo "  出口 IP: $(curl -sS -x 127.0.0.1:$GLOBAL_PORT -m 12 https://api.ipify.org 2>/dev/null)"

line; echo "[11] 最近错误"
journalctl -u ap-mihomo --since "-30min" -o cat 2>/dev/null \
  | grep -iE 'level=(error|warning)' | tail -5 | sed 's/^/  /'
line
