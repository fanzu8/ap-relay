#!/bin/sh
# ===========================================================================
# 语法检查 /etc/storage 下的 mihomo 相关文件，全部通过才写 flash
# ===========================================================================
# /etc/storage 在 tmpfs 上，不执行 mtd_storage.sh save 的话重启就丢。
# 写 flash 前先 sh -n，避免把语法错误的脚本固化下来（下次开机直接失效）。
#
# 用法: mihomo-save.sh
# ===========================================================================
here=$(dirname "$0")
. "$here/mihomo-env.sh"

ERR=/tmp/mihomo-save.err
bad=0

for f in /etc/storage/mihomo-*.sh \
         /etc/storage/mihomo.conf \
         /etc/storage/mihomo.local.conf \
         /etc/storage/started_script.sh \
         /etc/storage/post_iptables_script.sh; do
	[ -f "$f" ] || continue
	if ! sh -n "$f" 2>"$ERR"; then
		printf '语法错误: %s\n' "$f"
		sed 's/^/  /' "$ERR"
		bad=1
	fi
done
rm -f "$ERR"

if [ "$bad" != "0" ]; then
	printf '存在语法错误，未写入 flash\n'
	exit 1
fi

printf '语法检查通过，写入 flash...\n'
if padavan_save_flash; then
	printf '已保存，重启后生效\n'
	exit 0
fi

printf '保存失败，改动只在内存\n'
exit 1
