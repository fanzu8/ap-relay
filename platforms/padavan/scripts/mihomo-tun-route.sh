#!/bin/sh
# ===========================================================================
# TUN 模式的策略路由（对应手机侧的 ap-tun-route.sh）
# ===========================================================================
# 只把“从 br0 进来、需要转发”的流量导进 mihomo 的 tun：
#   路由器自己产生的流量 iif 不是 br0，天然走主表直连
#   —— SSH、更新订阅、mihomo 连机场节点都不会被自己代理（不形成环路）。
#
# 为什么不用 auto-route：mihomo 的 auto-route 会改主表默认路由，
# 把路由器自己也卷进去。手工策略路由范围最小、出问题好回退。
#
# 用法: mihomo-tun-route.sh up|down
# ===========================================================================
here=$(dirname "$0")
. "$here/mihomo-env.sh"

TUN=$TUN_DEV
TABLE=$TABLE_ID
PREF=$RULE_PREF

down() {
	while ip rule del iif "$LAN_IF" lookup "$TABLE" 2>/dev/null; do :; done
	ip route flush table "$TABLE" 2>/dev/null
	return 0
}

up() {
	# 等 mihomo 把 tun 建出来（启动时会先建设备再监听端口）。
	i=0
	while [ "$i" -lt 40 ]; do
		padavan_tun_ready && break
		i=$((i + 1))
		sleep 1
	done
	if ! padavan_tun_ready; then
		printf 'mihomo-tun-route: tun %s 未出现\n' "$TUN" >&2
		return 1
	fi
	ip link set "$TUN" up 2>/dev/null

	# 回程包的源地址是境外 IP、从 tun 进来，rp_filter 会当成伪造包丢掉。
	for f in /proc/sys/net/ipv4/conf/*/rp_filter; do
		printf '0\n' > "$f" 2>/dev/null
	done

	# 幂等：先删干净再加。
	while ip rule del iif "$LAN_IF" lookup "$TABLE" 2>/dev/null; do :; done
	ip rule add iif "$LAN_IF" lookup "$TABLE" pref "$PREF" || return 1

	ip route flush table "$TABLE" 2>/dev/null

	# 直连网段必须原样抄进自定义表：
	#   少了 LAN 网段，客户端访问路由器本身会被送进 tun；
	#   少了上游网段，访问上游也会被代理。
	ip route show | while read -r r; do
		case "$r" in
			default*) continue ;;
			"")       continue ;;
		esac
		ip route add $r table "$TABLE" 2>/dev/null
	done

	ip route add default dev "$TUN" table "$TABLE" || return 1
	return 0
}

case "$1" in
	up)   up ;;
	down) down ;;
	*)
		printf '用法: %s up|down\n' "$0"
		exit 1
		;;
esac
