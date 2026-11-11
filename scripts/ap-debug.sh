#!/bin/sh
# 用法: ap-debug.sh on|off —— 切换 mihomo 日志级别（只改运行时，重启回 info）
#
# secret 解析复用能力层，避免每个脚本各抄一套（引号处理也一致）。
here=$(dirname "$0")
. "$here/lib.sh"
. "$here/mihomo-lib.sh"
SECRET=$(mihomo_secret) || SECRET=
case "${1:-}" in
  on)  L=debug ;;
  off) L=info ;;
  *)   echo "用法: ap-debug.sh on|off"; exit 1 ;;
esac
curl -sS -X PATCH -H "Authorization: Bearer $SECRET" -H 'Content-Type: application/json' \
     -d "{\"log-level\":\"$L\"}" http://127.0.0.1:$UI_PORT/configs -o /dev/null -w "log-level=$L http=%{http_code}\n"
