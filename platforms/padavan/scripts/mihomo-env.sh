#!/bin/sh
# ===========================================================================
# Padavan 平台环境层：所有 mihomo 平台脚本共用的常量与小工具
# ===========================================================================
# 只被 source，不直接执行。安装后与其它脚本同目录（/etc/storage），
# 所以用脚本自身位置定位即可：
#
#   here=$(dirname "$0")
#   . "$here/mihomo-env.sh"
#
# 这样无论从仓库里直接跑，还是从 /etc/storage 跑，都能找到本文件。
#
# 分层原则：
#   - 平台差异（持久分区路径、PID/日志位置、iptables 链名、busybox 限制）
#     全部集中在这里；
#   - 具体脚本只写“做什么”，不再各自抄一遍端口和路径。
#   - 端口优先读 /etc/storage/mihomo.conf（与渲染用的是同一份事实来源），
#     读不到才用默认值。这样改了配置里的端口，平台脚本不会漂移。
# ===========================================================================

PATH=/sbin:/usr/sbin:/usr/bin:/bin
export PATH

# ---- 路径 -----------------------------------------------------------------
MIHOMO_DIR=/media/mtd_rwfs/mihomo        # 持久分区（mihomo 二进制、geo、providers）
MIHOMO_MOUNT=${MIHOMO_DIR%/*}            # 挂载点（/media/mtd_rwfs），用于判断 RWFS 是否就绪
MIHOMO_CONF=/etc/mihomo                  # 运行期统一路径（start.sh 建的软链）
MIHOMO_MODE_FILE=$MIHOMO_DIR/mode        # redirect / tun，重启后沿用
MIHOMO_PID=/tmp/mihomo.pid               # 守护脚本 pid
MIHOMO_LOG=/tmp/mihomo.log               # mihomo 标准输出
MIHOMO_PLATFORM_CONF=/etc/storage/mihomo.conf   # 平台变量文件（渲染与脚本共用）

# ---- 端口 / 网段（可被 mihomo.conf 覆盖） ---------------------------------
[ -r "$MIHOMO_PLATFORM_CONF" ] && . "$MIHOMO_PLATFORM_CONF"

GLOBAL_PORT=${GLOBAL_PORT:-1008}          # mixed 入口
UI_PORT=${UI_PORT:-7070}                  # 面板 + REST API
TUN_DEV=${TUN_DEV:-meta}                  # 必须与 tun.device 一致

# DNS 端口从 DNS_LISTEN 取（例如 0.0.0.0:1053）；没配再回退 1053。
if [ -z "${DNS_PORT:-}" ]; then
	case "${DNS_LISTEN:-}" in
		*:*) DNS_PORT=${DNS_LISTEN##*:} ;;
	esac
fi
DNS_PORT=${DNS_PORT:-1053}

# redir-port 是启动期参数，配置里是一整行；注释掉表示不用 redirect。
REDIR_PORT=$(printf '%s\n' "${REDIR_LINE:-}" | awk '/^redir-port:/ { print $2 }')
[ -n "$REDIR_PORT" ] || REDIR_PORT=1009

# ---- 局域网 / 策略路由 ----------------------------------------------------
LAN_IF=${LAN_IF:-br0}                     # 只处理从 LAN 进来的流量
TABLE_ID=${TABLE_ID:-100}                 # TUN 模式自定义路由表
RULE_PREF=${RULE_PREF:-11000}             # ip rule 优先级

IPT_TAG=MIHOMO                            # nat / mangle 链名
IPT_FWD=${IPT_TAG}_FWD                    # filter 转发链名

# ---- 小工具 ---------------------------------------------------------------

# 统一日志前缀，方便 `logread -e mihomo`。
padavan_log() {
	logger -t mihomo "$*"
}

# 当前透明代理模式；文件不存在时按 redirect（与 mihomo.conf 默认一致）。
padavan_mode() {
	cat "$MIHOMO_MODE_FILE" 2>/dev/null || printf 'redirect\n'
}

# mihomo 二进制：优先运行期软链目录，回退持久分区。
padavan_bin_path() {
	if [ -x "$MIHOMO_CONF/mihomo" ]; then
		printf '%s\n' "$MIHOMO_CONF/mihomo"
	elif [ -x "$MIHOMO_DIR/mihomo" ]; then
		printf '%s\n' "$MIHOMO_DIR/mihomo"
	else
		return 1
	fi
}

# 等 RWFS 挂载完成（开机时脚本可能比挂载先跑）。参数：最多等几秒。
padavan_wait_rwfs() {
	_limit=${1:-60}
	_i=0
	while [ "$_i" -lt "$_limit" ]; do
		grep -q " $MIHOMO_MOUNT " /proc/mounts && return 0
		_i=$((_i + 1))
		sleep 1
	done
	return 1
}

# tun 设备是否已由 mihomo 建出来。
padavan_tun_ready() {
	ip link show "$TUN_DEV" >/dev/null 2>&1
}

# 4 个端口是否全部监听（mixed / redir / DNS / 面板）。
# 只等面板会让 redir / DNS 短暂空窗，所以必须一起判断。
padavan_ports_ready() {
	_n=$(netstat -lnt 2>/dev/null |
		grep -cE ":($GLOBAL_PORT|$REDIR_PORT|$UI_PORT|$DNS_PORT) ")
	[ "$_n" -ge 4 ]
}

# 等端口就绪。参数：最多等几秒（默认 40）。
padavan_wait_ports() {
	_limit=${1:-40}
	_i=0
	while [ "$_i" -lt "$_limit" ]; do
		padavan_ports_ready && return 0
		_i=$((_i + 1))
		sleep 1
	done
	return 1
}

# 写 flash：/etc/storage 是 tmpfs，不 save 重启就丢。
padavan_save_flash() {
	/sbin/mtd_storage.sh save >/dev/null 2>&1
}
