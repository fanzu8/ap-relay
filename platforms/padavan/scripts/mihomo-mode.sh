#!/bin/sh
# ===========================================================================
# 切换透明代理模式
# ===========================================================================
#   mihomo-mode.sh show        看当前模式与运行状态
#   mihomo-mode.sh tun         走 TUN + gvisor（路由进 tun）
#   mihomo-mode.sh redirect    走 iptables REDIRECT（不用 tun，CPU 更低）
#
# 模式记在 RWFS 的 mode 文件里，重启后沿用。
# 切换会重启 mihomo，全屋断几秒到十几秒，属于预期行为。
#
# 一致性：config.yaml 的 tun.enable 由渲染产生，
# 所以除了改当前配置，还要把平台变量里的 TUN_ENABLE 同步改掉，
# 否则下一次 mihomo-apply.sh 会把模式改回去。
# ===========================================================================
here=$(dirname "$0")
. "$here/mihomo-env.sh"

CONF="$MIHOMO_CONF/config.yaml"

# 只改 tun: 块里的 enable，不碰 dns / sniffer 等其他同名字段。
set_tun_enable() {
	val=$1
	awk -v v="$val" '
		/^tun:[[:space:]]*$/ { intun = 1; print; next }
		intun && /^[^[:space:]#]/ { intun = 0 }
		intun && /^[[:space:]]+enable:/ && !done {
			print "  enable: " v
			done = 1
			next
		}
		{ print }
	' "$CONF" > "$CONF.mode.tmp" || return 1

	grep -q "  enable: $val" "$CONF.mode.tmp" || {
		rm -f "$CONF.mode.tmp"
		return 1
	}
	mv -f "$CONF.mode.tmp" "$CONF"
	return 0
}

# 把 TUN_ENABLE 写回平台变量文件（保持下次渲染一致）。
persist_var() {
	f=$MIHOMO_PLATFORM_CONF
	[ -f "$f" ] || return 0
	awk -v k="$1" -v v="$2" '
		$0 ~ "^" k "=" { print k "=" v; done = 1; next }
		{ print }
	' "$f" > "$f.mode.tmp" || return 1
	mv -f "$f.mode.tmp" "$f"
}

show() {
	printf '模式: %s\n' "$(padavan_mode)"
	if padavan_tun_ready; then
		printf 'tun : 存在 (mtu %s)\n' "$(cat "/sys/class/net/$TUN_DEV/mtu" 2>/dev/null)"
	else
		printf 'tun : 不存在\n'
	fi
	printf 'rule: %s\n' "$(ip rule show 2>/dev/null | grep "iif $LAN_IF" || printf '无')"
	if padavan_ports_ready; then
		printf '端口: 4/4\n'
	else
		printf '端口: 未就绪\n'
	fi
}

case "${1:-show}" in
	show)
		show
		exit 0
		;;
	tun|redirect)
		WANT=$1
		;;
	*)
		printf '用法: %s [show|tun|redirect]\n' "$0"
		exit 1
		;;
esac

[ -f "$CONF" ] || {
	printf '找不到 %s\n' "$CONF"
	exit 1
}

if [ "$WANT" = "tun" ]; then
	set_tun_enable true || { printf '改 tun.enable 失败\n'; exit 1; }
	persist_var TUN_ENABLE true
else
	set_tun_enable false || { printf '改 tun.enable 失败\n'; exit 1; }
	persist_var TUN_ENABLE false
fi
printf '%s\n' "$WANT" > "$MIHOMO_MODE_FILE"

printf '模式已写入 %s，重启 mihomo...\n' "$WANT"
"$here/mihomo-start.sh"
sleep 2

printf '\n---- 结果 ----\n'
show
printf '\n---- 出口 ----\n'
curl -s -m 20 -x "http://127.0.0.1:$GLOBAL_PORT" https://api.ipify.org 2>/dev/null
printf '\n'
