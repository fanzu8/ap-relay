#!/bin/sh
# 公共变量。被其它脚本 source。
#
# 优先级：/etc/ap-relay.conf 里的值 > 这里的默认值。
# 默认值 = 在 OnePlus 6 / postmarketOS 25.12 上验证过的那套配置。
# 所有脚本都通过 ${VAR:-默认} 取值，因此配置文件缺项也能跑。
[ -r /etc/ap-relay.conf ] && . /etc/ap-relay.conf

# ---- 接口 ----
STA_IF=${STA_IF:-wlan0}           # 上行接口（连上游 WiFi；有线上行时设成 eth0 也可）
AP_IF=${AP_IF:-wlan1}             # 热点接口，运行时创建，不要与已有接口重名
UPLINK_IF=${UPLINK_IF:-$STA_IF}   # NAT 出接口。单卡 AP+STA 时等于 STA_IF

# ---- 网段 ----
AP_IP=${AP_IP:-192.168.43.1}          # 热点网关，同时也是客户端 DNS
AP_CIDR=${AP_CIDR:-192.168.43.1/24}   # 配到 AP 接口上的地址（带掩码）
AP_NET=${AP_NET:-192.168.43.0/24}     # 网段（给路由/NAT 用，不带主机位）

# ---- mihomo ----
TUN_DEV=${TUN_DEV:-meta}     # 必须与 mihomo 配置里的 tun.device 一致

# ---- 端口 ----
# 所有端口集中在这里，方便全局替换。
# 兼容旧配置：只写了 PROXY_PORT 时，把它当作 GLOBAL_PORT。
if [ -z "${GLOBAL_PORT:-}" ] && [ -n "${PROXY_PORT:-}" ]; then
	GLOBAL_PORT=$PROXY_PORT
fi
GLOBAL_PORT=${GLOBAL_PORT:-1008}   # mixed（HTTP+SOCKS），必须与 mixed-port 一致
PROXY_PORT=${PROXY_PORT:-$GLOBAL_PORT}  # 兼容旧变量名，等同 GLOBAL_PORT
DNS_PORT=${DNS_PORT:-1053}         # 必须与 mihomo 配置里的 dns.listen 端口一致
UI_PORT=${UI_PORT:-7070}           # 面板 + REST API，必须与 external-controller 一致
DNS_STD_PORT=${DNS_STD_PORT:-53}   # dnsmasq 对客户端提供 DNS 的端口
DHCP_PORT=${DHCP_PORT:-67}         # dnsmasq DHCP 端口
QUIC_PORT=${QUIC_PORT:-443}        # 需要拦截的 QUIC 端口
HTTP_PORT=${HTTP_PORT:-80}         # mihomo sniffer HTTP
HTTP_ALT_START=${HTTP_ALT_START:-8080}
HTTP_ALT_END=${HTTP_ALT_END:-8880}
TLS_PORT=${TLS_PORT:-443}          # mihomo sniffer TLS
TLS_ALT_PORT=${TLS_ALT_PORT:-8443} # mihomo sniffer TLS/QUIC 备用端口

# ---- 策略路由 ----
TABLE_ID=${TABLE_ID:-100}    # 自定义路由表号
RULE_PREF=${RULE_PREF:-11000} # 规则优先级（数字越小越先匹配）

# 轮询命中后不要马上下结论：接口 up、hostapd 写入 ssid、TUN 建好之后，
# 内核/驱动把状态同步到 sysfs、iw、ip 的输出往往还晚一拍。
# 再等 1 秒（5×0.2s），然后由调用方复验一次，避免“看起来好了其实还没好”的竞态。
settle() {
	_n=0
	while [ "$_n" -lt 5 ]; do
		sleep 0.2
		_n=$((_n + 1))
	done
}
