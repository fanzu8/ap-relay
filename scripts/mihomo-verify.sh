#!/bin/sh
# ===========================================================================
# 纯校验层：检查渲染后的 mihomo 配置
# ===========================================================================
# 职责：只读文件、只输出结论；不改线上配置、不重启、不拉订阅。
#
# 用法：
#   mihomo-verify.sh <配置文件> [平台配置] [私有配置]
#
# 检查项（任一失败即退出 1）：
#   1. 没有残留占位符（@@NAME@@ 或 ${NAME}）
#   2. mihomo -t 语法校验通过
#   3. secret 非空
#   4. provider 必须是 type: http，且有 url 与正整数 interval
#   5. 分组与规则条数合理（分组 >= 1，规则 >= 1000）
#   6. mixed-port 存在且与 GLOBAL_PORT 一致
#
# 每个检查都是独立函数，失败只置 FAIL，不提前退出：
# 一次跑完能看到全部问题，比修一个跑一次更省事。
#
# 工具约束：grep / awk / sed；路由器没有 python3，手机没有 jq。
# ===========================================================================
set -eu

here=$(dirname "$0")
. "$here/mihomo-vars.sh" "${2:-}" "${3:-}"
. "$here/mihomo-lib.sh"

if [ "$#" -lt 1 ]; then
	printf '用法: %s <配置文件> [平台配置] [私有配置]\n' "$0" >&2
	exit 1
fi

cfg=$1
[ -r "$cfg" ] || mihomo_die "读不到配置: $cfg"

FAIL=0
ok()  { printf '  [ ok ] %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*"; FAIL=1; }

# ---------------------------------------------------------------------------
# 1. 占位符：渲染器把未知占位符替换成 @@NAME@@，这里兜底检查两种形态。
# ---------------------------------------------------------------------------
check_placeholders() {
	if grep -q '@@[A-Za-z_][A-Za-z0-9_]*@@' "$cfg" 2>/dev/null ||
	   grep -q '\${[A-Za-z_][A-Za-z0-9_]*}' "$cfg" 2>/dev/null; then
		bad "存在未替换的占位符，说明渲染不完整"
	else
		ok "无残留占位符"
	fi
}

# ---------------------------------------------------------------------------
# 2. 语法：用本机内核二进制，数据目录取配置文件所在目录
#    （provider 的 path 是相对数据目录的，-d 传错会误报找不到缓存文件）。
# ---------------------------------------------------------------------------
check_syntax() {
	tlog="/tmp/mihomo-verify.$$.log"
	bin=$(mihomo_bin) || bin=
	# 用 `|| rc=$?` 形式，避免 set -e 在校验失败时直接退出脚本。
	rc=0
	mihomo_test_config "$cfg" "$tlog" || rc=$?
	if [ "$rc" = "0" ]; then
		ver=$("$bin" -v 2>/dev/null | head -1)
		ok "${ver:-mihomo} 语法校验通过"
	elif [ "$rc" = "2" ] || [ -z "$bin" ]; then
		bad "找不到 mihomo 二进制，跳过语法校验"
	else
		bad "mihomo -t 未通过："
		sed 's/^/        /' "$tlog" | tail -8
	fi
	rm -f "$tlog"
}

# ---------------------------------------------------------------------------
# 3. secret：非空即可，绝不打印内容（长度都不打印，避免侧信道）。
# ---------------------------------------------------------------------------
check_secret() {
	sec=$(mihomo_secret "$cfg") || sec=
	if [ -z "$sec" ]; then
		bad "secret 为空（面板/API 会裸奔，refresh / reload 也无法鉴权）"
	else
		ok "secret 已设置（不打印内容）"
	fi
}

# ---------------------------------------------------------------------------
# 4. provider：只认 type: http（内核自己定时拉取）。
#    type: file 意味着订阅靠外部脚本更新，和统一方案不符。
# ---------------------------------------------------------------------------
check_provider() {
	prov=$(awk '/^proxy-providers:/ { p = 1 } /^proxy-groups:/ { p = 0 } p' "$cfg")
	ptype=$(printf '%s\n' "$prov" | awk '/^    type:/ { print $2; exit }')
	purl=$(printf '%s\n' "$prov" | awk '/^    url:/ { print $2; exit }' | tr -d '"')
	pint=$(printf '%s\n' "$prov" | awk '/^    interval:/ { print $2; exit }')

	case "$ptype" in
		http)	ok "provider 为 type: http（内核定时拉取）" ;;
		file)	bad "provider 是 type: file：不会自动更新，需外部脚本" ;;
		'')	bad "没解析到 provider 的 type" ;;
		*)	bad "provider type 未知: $ptype" ;;
	esac

	case "$purl" in
		http://*|https://*) ok "provider url 已填写（不打印内容）" ;;
		*) bad "provider url 为空或不是 http(s)" ;;
	esac

	case "$pint" in
		''|*[!0-9]*) bad "provider interval 不是整数秒: ${pint:-<空>}" ;;
		*)
			if [ "$pint" -gt 0 ]; then
				ok "provider interval = ${pint}s"
			else
				bad "provider interval 为 0（等于不自动更新）"
			fi
			;;
	esac
}

# ---------------------------------------------------------------------------
# 5. 结构：分组和规则都在才算完整；规则少于 1000 条基本是解析/拆分出错。
# ---------------------------------------------------------------------------
check_structure() {
	groups=$(awk '/^proxy-groups:/ { p = 1; next }
	              /^rules:/ { p = 0 }
	              p && /^  - name:/ { n++ }
	              END { print n + 0 }' "$cfg")
	rules=$(awk '/^rules:/ { p = 1; next }
	             p && /^  - / { n++ }
	             END { print n + 0 }' "$cfg")

	[ "$groups" -ge 1 ] && ok "分组 $groups 个" ||
		bad "没有解析到分组"
	[ "$rules" -ge 1000 ] && ok "规则 $rules 条" ||
		bad "规则只有 $rules 条，疑似规则块丢失"
}

# ---------------------------------------------------------------------------
# 6. 端口：mixed-port 必须与平台变量一致，否则客户端连错入口。
# ---------------------------------------------------------------------------
check_mixed_port() {
	mp=$(awk '/^mixed-port:/ { print $2; exit }' "$cfg")
	if [ -n "$mp" ] && [ "$mp" = "$GLOBAL_PORT" ]; then
		ok "mixed-port = ${mp}（与 GLOBAL_PORT 一致）"
	else
		bad "mixed-port 缺失或与 GLOBAL_PORT($GLOBAL_PORT) 不一致: ${mp:-<空>}"
	fi
}

# ---------------------------------------------------------------------------
# 执行
# ---------------------------------------------------------------------------
printf '校验 %s\n' "$cfg"
check_placeholders
check_syntax
check_secret
check_provider
check_structure
check_mixed_port

printf '\n'
if [ "$FAIL" != "0" ]; then
	printf '校验未通过\n' >&2
	exit 1
fi
printf '校验通过\n'
