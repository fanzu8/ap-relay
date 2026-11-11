#!/bin/sh
# ===========================================================================
# 停止 mihomo 并清除透明代理规则
# ===========================================================================
# 幂等：进程本来就没跑、规则本来就没有，也返回 0。
# 顺序：先杀守护和内核，再等端口释放，最后摘规则；
# 反过来会让客户端在“规则还在、代理已死”的空窗里断网。
# ===========================================================================
here=$(dirname "$0")
. "$here/mihomo-env.sh"

# 守护脚本（按 pid 文件）
if [ -f "$MIHOMO_PID" ]; then
	kill "$(cat "$MIHOMO_PID")" 2>/dev/null
fi

# 兜底：任何残留的守护脚本
for p in $(ps w 2>/dev/null | grep '[m]ihomo-run' | awk '{print $1}'); do
	kill "$p" 2>/dev/null
done

killall mihomo 2>/dev/null
killall clash 2>/dev/null   # 兼容旧实例名

# 等进程真正退出（killall 是异步的）
i=0
while [ "$i" -lt 10 ]; do
	pidof mihomo >/dev/null 2>&1 || pidof clash >/dev/null 2>&1 || break
	i=$((i + 1))
	sleep 1
done

# 等端口释放，避免下一次启动抢端口
i=0
while [ "$i" -lt 10 ]; do
	netstat -lnt 2>/dev/null | grep -q ":$UI_PORT " || break
	i=$((i + 1))
	sleep 1
done

rm -f "$MIHOMO_PID"

# 规则清理放在最后；两个脚本各自幂等。
"$here/mihomo-tun-route.sh" down >/dev/null 2>&1
"$here/mihomo-fw.sh" down >/dev/null 2>&1

padavan_log "已停止"
exit 0
