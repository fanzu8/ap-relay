#!/bin/sh
# ===========================================================================
# 能力层：mihomo 脚本共用的环境探测与小工具
# ===========================================================================
# 职责：只提供可复用的函数，不读配置文件、不在 source 时执行任何动作。
#
# 使用方式（调用方先载入配置，再载入本文件）：
#   . "$here/mihomo-vars.sh"   # 配置层：变量与默认值
#   . "$here/mihomo-lib.sh"    # 能力层：本文件
#
# 为什么分成两层：
#   - mihomo-vars.sh 只有数据，换平台时只动它；
#   - 本文件只有逻辑，手机 / 路由器共用，不掺平台差异。
#
# 反过来也成立：只做诊断、不需要渲染变量的脚本（如 ap-diag.sh）
# 可以只载入本文件，用 mihomo_secret / mihomo_conf_file 就够了。
#
# 工具约束见 mihomo-vars.sh 头部；这里同样不假设 jq / python3 / mktemp 存在。
# ===========================================================================

# 非交互 SSH、cron、systemd 的 PATH 往往缺 /usr/sbin，
# 而 Padavan 的 curl 恰好在 /usr/sbin，所以在能力层统一补全一次。
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/usr/sbin:/usr/bin:/bin:${PATH:-}
export PATH

# ---------------------------------------------------------------------------
# 1. 基础工具
# ---------------------------------------------------------------------------

# 统一的致命错误出口：所有命令脚本都用它，保证信息走 stderr、退出码为 1。
mihomo_die() {
	printf '%s\n' "$*" >&2
	exit 1
}

# busybox 1.29 的 ash 没有 command -v（会报 "command: not found"），
# 所以按 PATH 逐目录探测可执行位。这是两台设备都可靠的做法。
have() {
	_have_found=1
	for _have_dir in $(printf '%s\n' "$PATH" | tr ':' ' '); do
		if [ -x "$_have_dir/$1" ]; then
			_have_found=0
			break
		fi
	done
	return "$_have_found"
}

# ---------------------------------------------------------------------------
# 2. 定位 mihomo 的配置、数据目录与二进制
# ---------------------------------------------------------------------------

# 输出线上配置文件路径；找不到时返回 1（调用方负责报错）。
# 手机上就是 /etc/mihomo/config.yaml；
# 路由器上 /etc/mihomo 是软链，但开机早期软链可能还没建，所以回退到持久分区。
mihomo_conf_file() {
	if [ -f /etc/mihomo/config.yaml ]; then
		printf '%s\n' /etc/mihomo/config.yaml
	elif [ -f /media/mtd_rwfs/mihomo/config.yaml ]; then
		printf '%s\n' /media/mtd_rwfs/mihomo/config.yaml
	else
		return 1
	fi
}

# 数据目录（mihomo -d 参数）。providers/、geo 文件、cache.db 都在这里。
mihomo_data_dir() {
	dirname "$(mihomo_conf_file)" 2>/dev/null
}

# 输出 mihomo 二进制路径；找不到时返回 1。
mihomo_bin() {
	for _bin in /usr/local/bin/mihomo \
	            /media/mtd_rwfs/mihomo/mihomo \
	            /etc/mihomo/mihomo; do
		if [ -x "$_bin" ]; then
			printf '%s\n' "$_bin"
			return 0
		fi
	done
	return 1
}

# 从配置里取 secret。只输出值，不打印内容、不写日志。
# 参数可选：不传时用自动探测到的线上配置。
mihomo_secret() {
	_cfg=${1:-$(mihomo_conf_file)}
	[ -n "$_cfg" ] && [ -r "$_cfg" ] || return 1
	awk '/^secret:/ { sub(/^secret:[[:space:]]*/, ""); gsub(/["'"'"']/, ""); print; exit }' "$_cfg"
}

# 用本机内核二进制做语法校验（等价于 mihomo -t）。
# 用法: mihomo_test_config <配置> <日志文件>
# 返回: 0 通过 / 1 校验失败 / 2 找不到二进制
mihomo_test_config() {
	_cfg=$1
	_log=$2
	_bin=$(mihomo_bin) || {
		printf '找不到 mihomo 二进制\n' >&2
		return 2
	}
	"$_bin" -t -d "$(dirname "$_cfg")" -f "$_cfg" > "$_log" 2>&1
}

# ---------------------------------------------------------------------------
# 3. 进程与端口
# ---------------------------------------------------------------------------

# 重启 mihomo：systemd 优先，Padavan 走开机脚本。
# 具体命令是两台设备唯一的差异点，集中在这里，编排脚本不用关心平台。
mihomo_restart() {
	if have systemctl &&
	   systemctl list-unit-files 2>/dev/null | grep -q '^ap-mihomo\.service'; then
		systemctl restart ap-mihomo
	elif [ -x /etc/storage/mihomo-start.sh ]; then
		/etc/storage/mihomo-start.sh
	else
		printf '%s\n' \
			"找不到可用的重启方式（既没有 ap-mihomo.service，也没有 /etc/storage/mihomo-start.sh）" >&2
		return 1
	fi
}

# 当前监听端口列表（ss 优先，netstat 兜底；两台设备都至少有一个）。
listening_ports() {
	if have ss; then
		ss -lnt 2>/dev/null
	else
		netstat -lnt 2>/dev/null
	fi
}

# 某个 TCP 端口是否处于 LISTEN。
mihomo_port_open() {
	listening_ports | grep -q ":$1 "
}

# 本次配置理论上应该监听的端口。
#   mixed / 面板 : GLOBAL_PORT / UI_PORT
#   DNS          : 从 DNS_LISTEN 末尾取端口
#   redir        : 从 REDIR_LINE 整行取（手机走 TUN 时该行被注释，自然不出现）
mihomo_expected_ports() {
	[ -n "${GLOBAL_PORT:-}" ] && printf '%s\n' "$GLOBAL_PORT"
	[ -n "${UI_PORT:-}" ] && printf '%s\n' "$UI_PORT"
	case "${DNS_LISTEN:-}" in
		*:*) printf '%s\n' "${DNS_LISTEN##*:}" ;;
	esac
	case "${REDIR_LINE:-}" in
		'#'*) ;;
		redir-port:*)
			_redir=$(printf '%s\n' "$REDIR_LINE" | awk '{ print $2 }')
			[ -n "$_redir" ] && printf '%s\n' "$_redir"
			;;
	esac
}

# 等一组端口全部就绪，最多 30 秒。
# 全部就绪返回 0；超时把缺失端口打到 stderr 并返回 1。
mihomo_wait_ports() {
	_tries=0
	while [ "$_tries" -lt 30 ]; do
		_missing=
		for _port in "$@"; do
			mihomo_port_open "$_port" || _missing="$_missing $_port"
		done
		[ -z "$_missing" ] && return 0
		_tries=$((_tries + 1))
		[ "$_tries" -lt 30 ] && sleep 1
	done
	printf '端口未就绪:%s\n' "$_missing" >&2
	return 1
}

# ---------------------------------------------------------------------------
# 4. REST API
# ---------------------------------------------------------------------------

# 本机 API 地址（mihomo external-controller）。
mihomo_api_url() {
	printf 'http://127.0.0.1:%s%s\n' "$UI_PORT" "${1:-}"
}

# 调用本机 API，输出 HTTP 状态码；响应体写入 <输出文件>（默认丢弃）。
#   用法: mihomo_api METHOD PATH [JSON] [输出文件]
#   例：  code=$(mihomo_api PUT /configs?force=true "{\"path\":\"$cfg\"}" "$out")
# 这样 reload / refresh / debug 三个命令共用同一套鉴权与超时设置。
mihomo_api() {
	_api_method=$1
	_api_path=$2
	_api_json=${3:-}
	_api_out=${4:-/dev/null}
	_api_secret=$(mihomo_secret) || _api_secret=

	if [ -n "$_api_json" ]; then
		_api_code=$(curl -s -o "$_api_out" -w '%{http_code}' -m 60 \
			-X "$_api_method" \
			-H "Authorization: Bearer $_api_secret" \
			-H 'Content-Type: application/json' \
			-d "$_api_json" \
			"$(mihomo_api_url "$_api_path")" 2>/dev/null) || _api_code=000
	else
		_api_code=$(curl -s -o "$_api_out" -w '%{http_code}' -m 60 \
			-X "$_api_method" \
			-H "Authorization: Bearer $_api_secret" \
			"$(mihomo_api_url "$_api_path")" 2>/dev/null) || _api_code=000
	fi

	# 连接失败时 curl 可能什么都不输出，统一成 000 方便调用方判断。
	case "$_api_code" in
		[0-9][0-9][0-9]) ;;
		*) _api_code=000 ;;
	esac
	printf '%s\n' "$_api_code"
}
