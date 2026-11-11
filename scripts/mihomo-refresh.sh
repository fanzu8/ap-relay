#!/bin/sh
# ===========================================================================
# 运行时操作层：立刻刷新 provider（等于让 mihomo 马上重拉一次订阅）
# ===========================================================================
# 用法：
#   mihomo-refresh.sh [provider名] [平台配置] [私有配置]
#
# provider 省略时取 PROVIDER_NAME（默认 juzi）。
#
# 说明：
#   type: http → PUT 会立刻下载并解析，不用等 interval。
#   type: file → PUT 只是让内核重读本地文件，不会下载；脚本会明确提示。
#
# 流程：PUT /providers/proxies/<name> → GET 同一路径 → 打印
#       vehicleType / updatedAt / 节点数（便于确认“真的换了订阅”）。
#
# 输出里不含订阅地址与 secret；字段解析按工具存在性选择
# jq（路由器）→ python3（手机可能有）→ sed（都没有也能用）。
# ===========================================================================
set -eu

here=$(dirname "$0")

name=${1:-}
shift 1 2>/dev/null || true

. "$here/mihomo-vars.sh" "${1:-}" "${2:-}"
. "$here/mihomo-lib.sh"

[ -n "$name" ] || name=$PROVIDER_NAME

cfg=$(mihomo_conf_file) || cfg=
[ -n "$cfg" ] || mihomo_die "找不到 mihomo 配置"
mihomo_secret "$cfg" >/dev/null || mihomo_die "配置里没有 secret，无法调用 API"

tmp="/tmp/mihomo-refresh.$$.json"
put="/tmp/mihomo-refresh.$$.put"
trap 'rm -f "$tmp" "$put" >/dev/null 2>&1' EXIT INT TERM

# ---- 1. 触发刷新 ----------------------------------------------------------
printf '刷新 provider: %s\n' "$name"
code=$(mihomo_api PUT "/providers/proxies/$name" '' "$put")

if [ "$code" != "204" ]; then
	printf '刷新失败 (http=%s)\n' "$code" >&2
	[ -s "$put" ] && sed -n '1,3p' "$put" >&2
	exit 1
fi
printf '已触发刷新 (http=204)\n'

# ---- 2. 读回状态 ----------------------------------------------------------
code=$(mihomo_api GET "/providers/proxies/$name" '' "$tmp")
[ "$code" = "200" ] || {
	printf '读取 provider 状态失败 (http=%s)\n' "$code" >&2
	exit 1
}

# 优先 jq（结构化、可靠）；没有 jq 用 python3；再没有就按字段名做文本匹配。
# 文本匹配只用于“给人看的摘要”，不参与任何判断以外的逻辑。
field() {
	if have jq; then
		jq -r --arg k "$1" '.[$k] // empty' "$tmp" 2>/dev/null | head -1
	elif have python3; then
		python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
v = d.get(sys.argv[2])
print("" if v is None else v)' "$tmp" "$1" 2>/dev/null
	else
		tr ',' '\n' < "$tmp" |
			sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" | head -1
	fi
}

count_proxies() {
	if have jq; then
		jq -r '.proxies | length' "$tmp" 2>/dev/null
	elif have python3; then
		python3 -c 'import json,sys
print(len(json.load(open(sys.argv[1])).get("proxies", [])))' "$tmp" 2>/dev/null
	else
		# fallback：provider 条目里每个有效节点都带 "alive" 字段。
		tr ',' '\n' < "$tmp" | grep -c '"alive"' || true
	fi
}

vt=$(field vehicleType)
ua=$(field updatedAt)
n=$(count_proxies)

printf '  type      : %s\n' "${vt:-?}"
printf '  updatedAt : %s\n' "${ua:-?}"
printf '  proxies   : %s\n' "${n:-?}"

case "$vt" in
	HTTP) ;;
	File) printf '  注意: file 型 provider，PUT 只重读本地文件，不会下载新订阅。\n' >&2 ;;
	*)    printf '  注意: vehicleType=%s，请确认配置里的 provider 是 type: http。\n' "${vt:-?}" >&2 ;;
esac

# ---- 3. 顺带看一眼缓存文件（path 相对数据目录） ---------------------------
p=$(awk '/^    path:/ { print $2; exit }' "$cfg" | tr -d '"')
if [ -n "$p" ]; then
	case "$p" in
		/*) f=$p ;;
		*)  f="$(dirname "$cfg")/${p#./}" ;;
	esac
	if [ -f "$f" ]; then
		printf '  缓存文件  : %s（%s 字节）\n' "$f" "$(wc -c < "$f" | tr -d ' ')"
	fi
fi
