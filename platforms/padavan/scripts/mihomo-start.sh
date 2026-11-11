#!/bin/sh
# ===========================================================================
# 启动 mihomo（幂等：重复调用只会有一个实例）
# ===========================================================================
# 由 started_script.sh 开机调用，也可手动执行。
# 二进制、geo、providers 都在 RWFS 持久分区；/etc 是 tmpfs，
# 所以每次启动都重建 /etc/mihomo 软链。
#
# 流程：内核参数 → 串行锁 → 等 RWFS → 检查 enabled → 建软链 →
#       停旧实例 → 轮转日志 → 起守护 → 等端口 → 按模式装规则。
# ===========================================================================
here=$(dirname "$0")
. "$here/mihomo-env.sh"

# 临时端口范围每次开机都会还原，所以启动时补一遍（幂等）。
[ -x "$here/mihomo-sysctl.sh" ] && "$here/mihomo-sysctl.sh"

# ---- 同一时刻只允许一个启动流程；并发的直接退出，由第一个负责 ----
LOCK=/tmp/mihomo-start.lock
if ! mkdir "$LOCK" 2>/dev/null; then
	_k=0
	while [ -d "$LOCK" ] && [ "$_k" -lt 60 ]; do
		_k=$((_k + 1))
		sleep 1
	done
	exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null' EXIT INT TERM

# ---- 等持久分区挂载（开机时本脚本可能比挂载早跑，最多 60 秒） ----
if ! padavan_wait_rwfs 60; then
	padavan_log "RWFS 未挂载，放弃启动"
	exit 1
fi

# enabled 在 RWFS 里，必须等挂载后才能判断。
[ -f "$MIHOMO_DIR/enabled" ] || {
	padavan_log "未启用，跳过启动"
	exit 0
}

bin=$(padavan_bin_path) || {
	padavan_log "找不到 $MIHOMO_DIR/mihomo"
	exit 1
}

# ---- 对外暴露成与 pmos 一致的路径（/etc 是 tmpfs，重启后重建） ----
ln -sfn "$MIHOMO_DIR" /etc/mihomo
mkdir -p /opt/bin
ln -sf "$bin" /opt/bin/mihomo

# ---- 先彻底停掉旧实例（会等到端口释放） ----
"$here/mihomo-stop.sh" >/dev/null 2>&1

# ---- 日志归档：先按大小归档上一轮，再开一份新的 ----
# 统一走 padavan_rotate_log（copytruncate），避免和守护期间的轮转实现两套语义。
# 此时 mihomo 还没起来，没有 fd 问题。
padavan_rotate_log >/dev/null 2>&1
: > "$MIHOMO_LOG"

# ---- 起守护脚本 ----
nohup "$here/mihomo-run.sh" >/dev/null 2>&1 &
wpid=$!

# ---- 等 4 个端口全部就绪（最多 40 秒） ----
if ! padavan_wait_ports 40; then
	padavan_log "启动失败，见 $MIHOMO_LOG"
	tail -5 "$MIHOMO_LOG" > /tmp/mihomo.last
	kill "$wpid" 2>/dev/null
	exit 1
fi

# ---- 按模式装防火墙 / 路由 ----
# 顺序很重要：先放行转发，再改路由；
# 否则路由一挂、转发还没放行，客户端会短暂全断。
mode=$(padavan_mode)

if "$here/mihomo-fw.sh" up; then fwok=1; else fwok=0; fi

if [ "$mode" = "tun" ]; then
	if "$here/mihomo-tun-route.sh" up; then rtok=1; else rtok=0; fi
else
	"$here/mihomo-tun-route.sh" down >/dev/null 2>&1
	rtok=1
fi

if [ "$fwok" = "1" ] && [ "$rtok" = "1" ]; then
	padavan_log "已启动 (模式 $mode, 守护 pid $wpid)"
else
	padavan_log "已启动但未完全生效 (模式 $mode, 防火墙 $fwok, 路由 $rtok, 守护 pid $wpid)"
fi
exit 0
