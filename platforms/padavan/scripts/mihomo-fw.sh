#!/bin/sh
# ===========================================================================
# 局域网透明代理防火墙规则（按模式分两套）
# ===========================================================================
#   redirect: nat REDIRECT 到 redir-port（本内核最省 CPU）
#   tun     : 只劫持 DNS，其余由 ip rule 导入 meta（见 mihomo-tun-route.sh）
#
# 模式来自 RWFS 的 mode 文件，可用环境变量 MIHOMO_MODE 覆盖。
# 用法: mihomo-fw.sh up | down
#
# 设计要点：
#   - 用独立链（MIHOMO / MIHOMO_FWD），重载时整链删掉重建，
#     不会在 PREROUTING / FORWARD 里堆积重复跳转。
#   - DNS 劫持必须放在私网 RETURN 之前，否则客户端查路由器 LAN IP 的 53
#     会先命中私网规则，直接落到 dnsmasq，拿到被污染的真实 IP。
#   - iptables 偶发 EAGAIN 才重试；“规则不存在”是正常情况，不能 sleep 重试。
# ===========================================================================
here=$(dirname "$0")
. "$here/mihomo-env.sh"

MODE=${MIHOMO_MODE:-$(padavan_mode)}
[ -z "$MODE" ] && MODE=redirect

TAG=$IPT_TAG
FWD=$IPT_FWD

# ---- 串行化：start / 守护脚本 / 防火墙重载可能同时调用 ----
# 用带 PID 的锁；只有持有者已经不存在时才清理，避免把活锁删掉导致并发。
LOCK=/tmp/mihomo-fw.lock
k=0
while ! mkdir "$LOCK" 2>/dev/null; do
	old=$(cat "$LOCK/pid" 2>/dev/null)
	if [ -z "$old" ]; then
		sleep 1
		old=$(cat "$LOCK/pid" 2>/dev/null)
	fi
	if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
		k=$((k + 1))
		[ "$k" -gt 90 ] && exit 1
		sleep 1
	else
		rm -rf "$LOCK"
		continue
	fi
done
printf '%s\n' "$$" > "$LOCK/pid"
trap 'rm -rf "$LOCK" 2>/dev/null' EXIT INT TERM

# ---- iptables 包装：只对“表暂时不可用”重试 ----
ipt() {
	n=0
	while [ "$n" -lt 4 ]; do
		err=$(iptables "$@" 2>&1) && return 0
		case "$err" in
			*"temporarily unavailable"*|*"Resource temporarily"*)
				n=$((n + 1))
				sleep 1
				;;
			*)
				return 1
				;;
		esac
	done
	return 1
}

# 删除所有同形态的跳转（可能残留多条）。
drop_jumps() {
	t=$1
	c=$2
	shift 2
	k=0
	while [ "$k" -lt 6 ]; do
		ipt -t "$t" -D "$c" "$@" || break
		k=$((k + 1))
	done
}

# 整链清理：先删跳转，再 flush + delete 链。
del_chains() {
	k=0
	while [ "$k" -lt 3 ]; do
		# redirect 模式是 -i br0，tun 模式是裸跳转，两种都清。
		drop_jumps nat    PREROUTING -i "$LAN_IF" -j "$TAG"
		drop_jumps mangle PREROUTING -i "$LAN_IF" -j "$TAG"
		drop_jumps filter FORWARD    -i "$LAN_IF" -j "$FWD"
		drop_jumps filter FORWARD    -j "$FWD"

		# 链必须先 flush 再 delete；还有引用时会报 Too many links。
		ipt -t nat    -F "$TAG"
		ipt -t nat    -X "$TAG"
		ipt -t mangle -F "$TAG"
		ipt -t mangle -X "$TAG"
		ipt -t filter -F "$FWD"
		ipt -t filter -X "$FWD"

		if ! iptables -t nat -S PREROUTING 2>/dev/null | grep -q -- "-j $TAG$" &&
		   ! iptables -t filter -S FORWARD 2>/dev/null | grep -q -- "-j $FWD$"; then
			return 0
		fi
		k=$((k + 1))
		sleep 1
	done
	return 1
}

# ---- redirect 模式 --------------------------------------------------------
build_redirect() {
	ipt -t nat -N "$TAG"

	# DNS 必须先劫持，理由见文件头。
	ipt -t nat -A "$TAG" -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
	ipt -t nat -A "$TAG" -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"

	# 私网/保留地址直连，不劫持。
	for n in 0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 169.254.0.0/16 \
	         172.16.0.0/12 192.168.0.0/16 224.0.0.0/4 240.0.0.0/4; do
		ipt -t nat -A "$TAG" -d "$n" -j RETURN
	done
	ipt -t nat -A "$TAG" -p tcp -j REDIRECT --to-ports "$REDIR_PORT"
	ipt -t nat -I PREROUTING 1 -i "$LAN_IF" -j "$TAG"

	# 这台内核的 REJECT 只能在 filter 表用（mangle 会报 Invalid argument）。
	ipt -t filter -N "$FWD"
	ipt -t filter -A "$FWD" -d 198.18.0.0/16 -p udp --dport 443 \
		-j REJECT --reject-with icmp-port-unreachable
	ipt -t filter -I FORWARD 1 -i "$LAN_IF" -j "$FWD"
}

# ---- TUN 模式 -------------------------------------------------------------
build_tun() {
	# tun 模式下只有 DNS 需要劫持；TCP/UDP 由策略路由整包送进 tun。
	ipt -t nat -N "$TAG"
	ipt -t nat -A "$TAG" -p udp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
	ipt -t nat -A "$TAG" -p tcp --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
	ipt -t nat -I PREROUTING 1 -i "$LAN_IF" -j "$TAG"

	# Padavan 的 FORWARD 默认 DROP：进出 tun 的转发必须显式放行，
	# 否则客户端流量进来就被丢掉（表现是“全屋断网”而不是“没代理”）。
	ipt -t filter -N "$FWD"
	ipt -t filter -A "$FWD" -i "$LAN_IF" -o "$TUN_DEV" -j ACCEPT
	ipt -t filter -A "$FWD" -i "$TUN_DEV" -o "$LAN_IF" -j ACCEPT
	ipt -t filter -I FORWARD 1 -j "$FWD"
}

# 两条跳转都在、且各自只有一条，才算成功。
verify() {
	a=$(iptables -t nat -S PREROUTING 2>/dev/null | grep -c -- "-j $TAG$")
	b=$(iptables -t filter -S FORWARD 2>/dev/null | grep -c -- "-j $FWD$")
	[ "$a" = "1" ] && [ "$b" = "1" ]
}

# ---- 入口 ---------------------------------------------------------------------
sysctl -qw net.ipv4.ip_forward=1

case "$1" in
	up)
		n=0
		while [ "$n" -lt 3 ]; do
			n=$((n + 1))
			del_chains
			if [ "$MODE" = "tun" ]; then
				build_tun
			else
				build_redirect
			fi
			if verify; then
				padavan_log "透明代理规则已加载（$MODE）"
				exit 0
			fi
			padavan_log "规则校验未通过，第 $n 次重试"
			sleep 1
		done

		# 最后一次兜底：先把跳转补上，保证“宁可多一条，不要断网”。
		if [ "$MODE" = "tun" ]; then
			iptables -t nat -C PREROUTING -i "$LAN_IF" -j "$TAG" 2>/dev/null ||
				ipt -t nat -I PREROUTING 1 -i "$LAN_IF" -j "$TAG"
			iptables -t filter -C FORWARD -j "$FWD" 2>/dev/null ||
				ipt -t filter -I FORWARD 1 -j "$FWD"
		else
			iptables -t nat -C PREROUTING -i "$LAN_IF" -j "$TAG" 2>/dev/null ||
				ipt -t nat -I PREROUTING 1 -i "$LAN_IF" -j "$TAG"
			iptables -t filter -C FORWARD -i "$LAN_IF" -j "$FWD" 2>/dev/null ||
				ipt -t filter -I FORWARD 1 -i "$LAN_IF" -j "$FWD"
		fi
		verify && padavan_log "透明代理规则已加载（$MODE，兜底）" ||
			padavan_log "规则加载失败"
		;;
	down)
		del_chains
		padavan_log "透明代理规则已清除"
		;;
	*)
		printf '用法: %s up|down\n' "$0"
		exit 1
		;;
esac
