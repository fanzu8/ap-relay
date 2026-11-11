#!/bin/sh
# ===========================================================================
# mihomo 需要的内核参数
# ===========================================================================
# 由 started_script.sh（开机）和 mihomo-start.sh（每次启动）调用，幂等。
# /proc 里的值重启就没了，所以必须在这里设，不能靠手动。
#
# 临时端口范围：
#   Padavan 默认 1024-65535，把 mihomo 的监听端口（1008/1009/7070/1053）
#   也圈在里面，理论上可能与 NAT 出去的连接抢同一个端口。
#   改成 32768-60999（主流 Linux 默认值）后，监听端口全部落在范围外。
# ===========================================================================
here=$(dirname "$0")
. "$here/mihomo-env.sh"

WANT_RANGE="32768 60999"

set_range() {
	cur=$(awk '{print $1" "$2}' /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)
	[ "$cur" = "$WANT_RANGE" ] && return 0

	printf '%s\n' "$WANT_RANGE" > /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null
	new=$(awk '{print $1" "$2}' /proc/sys/net/ipv4/ip_local_port_range 2>/dev/null)

	if [ "$new" = "$WANT_RANGE" ]; then
		padavan_log "临时端口范围 $cur -> $new"
		return 0
	fi
	padavan_log "临时端口范围设置失败（当前 ${new:-读不到}）"
	return 1
}

rc=0
set_range || rc=1

# ---- TUN 模式（暂未启用，切换后需要时再打开） ----
# rp_filter 会把 TUN 回来的包当伪造包丢掉，开启 TUN 时必须关掉。
# 现在由 mihomo-tun-route.sh up 在切到 TUN 时处理，这里保留说明。

exit $rc
