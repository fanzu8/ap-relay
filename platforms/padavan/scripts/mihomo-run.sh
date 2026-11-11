#!/bin/sh
# ===========================================================================
# mihomo 守护外壳
# ===========================================================================
# 职责：
#   - 启动内核并在退出后有限重试（最多 3 次）；
#   - 只有“自己仍是当前实例”时才动规则，避免新旧实例互相踩；
#   - 彻底失败时摘掉规则，宁可直连也不要全屋指向死端口；
#   - 守护期间按时轮转日志（不能只靠启动时检查，进程可以连续跑几个月）。
#
# 常量和端口判断都在 mihomo-env.sh；本文件只写重试与接管逻辑。
# ===========================================================================
here=$(dirname "$0")
. "$here/mihomo-env.sh"

conf=$MIHOMO_CONF
[ -d "$conf" ] || conf=$MIHOMO_DIR

bin=$(padavan_bin_path) || {
	padavan_log "找不到 mihomo 二进制"
	exit 1
}

trap '' HUP

# 第二道保险：已有守护实例在跑就直接退出，避免出现两个。
if [ -f "$MIHOMO_PID" ]; then
	old=$(cat "$MIHOMO_PID" 2>/dev/null)
	if [ -n "$old" ] && [ "$old" != "$$" ] && kill -0 "$old" 2>/dev/null; then
		exit 0
	fi
fi

printf '%s\n' "$$" > "$MIHOMO_PID"

# 4 个端口都起来才算真正可用（只等面板会让 redir/DNS 短暂空窗）；
# tun 模式还要求 meta 设备真的存在，否则端口起来也没用。
alive() {
	padavan_ports_ready || return 1
	if [ "$(padavan_mode)" = "tun" ]; then
		padavan_tun_ready || return 1
	fi
	return 0
}

n=0
while [ "$n" -lt 3 ]; do
	n=$((n + 1))

	"$bin" -d "$conf" -f "$conf/config.yaml" >> "$MIHOMO_LOG" 2>&1 &
	child=$!

	# 后台日志轮转：每 15 秒看一眼大小，超过上限就 copytruncate。
	# 放在子进程里做，不阻塞启动和等待路径；内核退出后循环自然结束，
	# 再由下面的 kill 收尾（kill -0 对僵尸进程仍返回成功，所以必须显式收）。
	{
		while kill -0 "$child" 2>/dev/null; do
			padavan_rotate_log
			sleep 15
		done
	} &
	rot=$!

	# 等端口就绪（最多 25 秒）
	i=0
	while [ "$i" -lt 25 ]; do
		alive && break
		i=$((i + 1))
		sleep 1
	done

	if alive; then
		[ "$(cat "$MIHOMO_PID" 2>/dev/null)" = "$$" ] &&
			"$here/mihomo-fw.sh" up >/dev/null 2>&1
		padavan_log "第 $n 次启动成功，透明代理规则已挂上"
	else
		padavan_log "第 $n 次启动失败（端口未就绪）"
	fi

	wait "$child"
	rc=$?
	# 内核已退出，轮转循环还在 sleep 里，直接收掉，避免残留。
	kill "$rot" 2>/dev/null
	wait "$rot" 2>/dev/null

	# 已被新实例接管时不要动规则。
	if [ "$(cat "$MIHOMO_PID" 2>/dev/null)" != "$$" ]; then
		padavan_log "已被新实例接管，本实例退出"
		exit 0
	fi

	# 自己还是当前实例：摘规则，宁可直连也不要全屋指向死端口/死的 tun。
	"$here/mihomo-tun-route.sh" down >/dev/null 2>&1
	"$here/mihomo-fw.sh" down >/dev/null 2>&1
	padavan_log "进程退出(rc=$rc)，已摘除规则与路由，局域网恢复直连"

	[ "$n" -ge 3 ] && break
	padavan_log "30 秒后重试"
	sleep 30
done

padavan_log "重试结束，保持直连"
rm -f "$MIHOMO_PID"
exit 1
