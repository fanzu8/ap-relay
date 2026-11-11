#!/bin/sh
# ===========================================================================
# 纯转换层：渲染 mihomo 配置模板
# ===========================================================================
# 职责：<模板> + <变量> → <配置文件>。不做备份、不重启、不判断线上状态。
#
# 用法：
#   mihomo-render.sh <模板> <输出> [平台配置] [私有配置]
#
# 例：
#   mihomo-render.sh templates/mihomo.config.yaml /etc/mihomo/config.yaml
#   mihomo-render.sh templates/mihomo.config.yaml /tmp/preview.yaml /etc/ap-relay.conf
#
# 行为与约束：
#   - 只替换 ${NAME} 形式、且 NAME 在 MIHOMO_VAR_LIST 里的占位符；
#     注释里出现的其它 ${...} 原样保留。
#   - 发现清单外的占位符就失败退出，绝不把 ${...} 留在线上配置里。
#   - 先写 <输出>.new，成功后才 mv：失败不会留下半截配置。
#   - 输出权限固定 600：文件里有 secret 和订阅地址。
#   - 用 awk 而不是 sed 拼 -e：值里带 / & | \ 都不需要转义。
#   - 变量通过环境传给 awk（ENVIRON），不需要临时文件，也不用 mktemp。
# ===========================================================================
set -eu

if [ "$#" -lt 2 ]; then
	printf '用法: %s <模板> <输出> [平台配置] [私有配置]\n' "$0" >&2
	exit 1
fi

here=$(dirname "$0")
# 配置层在前，能力层在后；本脚本只用变量，不调用能力层函数。
. "$here/mihomo-vars.sh" "${3:-}" "${4:-}"
. "$here/mihomo-lib.sh"

src=$1
dst=$2
[ -r "$src" ] || mihomo_die "读不到模板: $src"

mkdir -p "$(dirname "$dst")"

# 原子替换：先写 .new，成功后 rename 覆盖。
new="${dst}.new"
trap 'rm -f "$new" >/dev/null 2>&1' EXIT INT TERM

# 把清单里的变量标记为导出，awk 通过 ENVIRON 读取它们的当前值。
for _v in $MIHOMO_VAR_LIST; do
	eval "export $_v"
done

# 逐行替换。match() 的 RSTART/RLENGTH 比手工扫字符简单，也不会死循环。
# 模板行里可能有多个占位符，所以 while 循环处理完当前行再 print。
#
# 把 $MIHOMO_VAR_LIST 传给 awk，只认清单里的名字：
# 不能直接用 `name in ENVIRON` 判断，因为环境里还有 HOME/PATH 等无关变量，
# 那样模板里写 ${HOME} 会被静默替换成宿主机路径。
#
# 清单是多行文本，awk -v 不接受字符串里的换行，先压成一行（空格分隔）。
_var_names=$(printf '%s' "$MIHOMO_VAR_LIST" | tr '\n' ' ')

awk -v vars="$_var_names" '
BEGIN {
	# 默认 FS 就是空白，足够把清单拆成数组。
	_n = split(vars, _list)
	for (_i = 1; _i <= _n; _i++) allowed[_list[_i]] = 1
}
{
	line = $0
	out = ""
	while (match(line, /\$\{[A-Za-z_][A-Za-z0-9_]*\}/)) {
		name = substr(line, RSTART + 2, RLENGTH - 3)
		if (name in allowed) {
			out = out substr(line, 1, RSTART - 1) ENVIRON[name]
		} else {
			# 用 @@NAME@@ 占位，END 里统一报错；这样失败信息能列出全部漏项。
			unknown[name] = 1
			out = out substr(line, 1, RSTART - 1) "@@" name "@@"
		}
		line = substr(line, RSTART + RLENGTH)
	}
	print out line
}
END {
	if (length(unknown)) {
		for (n in unknown)
			printf "mihomo-render: 未定义的占位符: %s\n", n > "/dev/stderr"
		exit 1
	}
}
' "$src" > "$new"

mv -f "$new" "$dst"
chmod 600 "$dst" 2>/dev/null || true
trap - EXIT INT TERM

printf '已渲染 %s（%s 行，%s 字节）\n' \
	"$dst" "$(wc -l < "$dst" | tr -d ' ')" "$(wc -c < "$dst" | tr -d ' ')"
