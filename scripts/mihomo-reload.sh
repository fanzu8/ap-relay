#!/bin/sh
# ===========================================================================
# 运行时操作层：热重载配置（不重启进程、不断网）
# ===========================================================================
# 用法：
#   mihomo-reload.sh [-f] [平台配置] [私有配置]
#
#   不带 -f : 校验失败或热重载失败就放弃，绝不带病重载
#   带   -f : 热重载失败时回退到完整重启（会断几秒）
#
# 适用场景：
#   - 只改了规则 / 分组 / provider 参数：热重载即可。
#   - 改了 tun、dns、监听端口这类启动期参数：热重载不会生效，
#     请改用 mihomo-apply.sh（它会重启并等端口）。
#
# 流程：mihomo -t 校验 → PUT /configs?force=true（让内核重新读同一个文件）
#       → 检查 HTTP 204。
#
# 平台差异（systemd / Padavan）只在 mihomo_restart 里，本脚本不判断平台。
# ===========================================================================
set -eu

here=$(dirname "$0")

force=0
if [ "${1:-}" = "-f" ]; then
	force=1
	shift
fi

. "$here/mihomo-vars.sh" "${1:-}" "${2:-}"
. "$here/mihomo-lib.sh"

cfg=$(mihomo_conf_file) || cfg=
[ -n "$cfg" ] || mihomo_die "找不到 mihomo 配置（/etc/mihomo/config.yaml 或持久分区里的同名文件）"

# 先确认凭据存在；没有 secret 时 API 只会返回 401，不如直接报原因。
mihomo_secret "$cfg" >/dev/null || mihomo_die "配置里没有 secret，无法调用 API"

# ---- 1. 语法校验：不通过就原地停下，线上配置一个字节都不动 ----
printf '校验配置 %s ...\n' "$cfg"
tlog="/tmp/mihomo-reload.$$.log"
trap 'rm -f "$tlog" "${out:-}" >/dev/null 2>&1' EXIT INT TERM
mihomo_test_config "$cfg" "$tlog" || rc=$?
rc=${rc:-0}
if [ "$rc" != "0" ]; then
	if [ "$rc" = "2" ]; then
		mihomo_die "找不到 mihomo 二进制，无法校验"
	fi
	printf '校验失败，未重载：\n' >&2
	tail -5 "$tlog" | sed 's/^/  /' >&2
	exit 1
fi

# ---- 2. 热重载 ----
out="/tmp/mihomo-reload.$$.out"
code=$(mihomo_api PUT '/configs?force=true' "{\"path\":\"$cfg\"}" "$out")

if [ "$code" = "204" ]; then
	printf '已热重载（进程未重启）\n'
	exit 0
fi

printf '热重载失败 (http=%s)\n' "$code" >&2
[ -s "$out" ] && sed -n '1,3p' "$out" | sed 's/^/  /' >&2

# ---- 3. 可选回退：只有显式 -f 才重启，避免误操作把代理打断 ----
if [ "$force" = "1" ]; then
	printf '回退到完整重启...\n' >&2
	mihomo_restart
	exit $?
fi

printf '配置未生效；确认要重启请加 -f，或改用 mihomo-apply.sh\n' >&2
exit 1
