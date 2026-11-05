#!/bin/sh
# 用 /etc/ap-relay.conf 里的值渲染模板中的 ${VAR} 占位符。
#
# 用法：
#   ap-render.sh <模板文件> <输出文件>
#
# 例：
#   ap-render.sh templates/mihomo.config.yaml /etc/mihomo/config.yaml
#   ap-render.sh templates/51_hotspot.nft     /etc/nftables.d/51_hotspot.nft
#
# 只替换下面列出的变量；模板里其它内容原样保留。
# 注意：输出文件会被整体覆盖。对 /etc/mihomo/config.yaml 这类文件，
# 建议先编辑模板或备份，再重新渲染。
set -eu
. "$(dirname "$0")/lib.sh"

if [ $# -ne 2 ]; then
	echo "用法: ap-render.sh <模板文件> <输出文件>" >&2
	exit 1
fi

src=$1
dst=$2
[ -r "$src" ] || { echo "ap-render: 读不到模板 $src" >&2; exit 1; }

mkdir -p "$(dirname "$dst")"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT INT TERM

vars="GLOBAL_PORT UI_PORT DNS_PORT DNS_STD_PORT DHCP_PORT QUIC_PORT \
HTTP_PORT HTTP_ALT_START HTTP_ALT_END TLS_PORT TLS_ALT_PORT AP_IF TUN_DEV"

set -- sed
# shellcheck disable=SC2086
for var in $vars; do
	eval "val=\${$var}"
	set -- "$@" -e "s|\${$var}|$val|g"
done
"$@" "$src" > "$tmp"

mv -f "$tmp" "$dst"
