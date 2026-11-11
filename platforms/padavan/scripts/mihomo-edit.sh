#!/bin/sh
# ===========================================================================
# 安全编辑 /etc/storage 下的脚本
# ===========================================================================
# 退出编辑器后：语法检查 → 失败自动回滚 → 通过则询问是否写 flash。
#
# 用法: mihomo-edit.sh /etc/storage/mihomo-fw.sh
# ===========================================================================
here=$(dirname "$0")
. "$here/mihomo-env.sh"

f="$1"
[ -n "$f" ] || { printf '用法: %s <文件>\n' "$0"; exit 1; }
case "$f" in
	/etc/storage/*) ;;
	*) printf '只处理 /etc/storage 下的文件\n'; exit 1 ;;
esac
[ -f "$f" ] || { printf '文件不存在: %s\n' "$f"; exit 1; }

BAK="/tmp/edit.$$.bak"
ERR="/tmp/edit.$$.err"
cp -f "$f" "$BAK"

finish() {
	if ! sh -n "$f" 2>"$ERR"; then
		printf '\n!! 语法错误，已回滚（flash 未改动）\n'
		sed 's/^/   /' "$ERR"
		cp -f "$BAK" "$f"
	else
		printf '\n写入 flash（重启后仍生效）? [y/N] '
		read -r ans
		case "$ans" in
			y|Y)
				if padavan_save_flash; then
					printf '已保存\n'
				else
					printf '保存失败，改动只在内存\n'
				fi
				;;
			*)
				printf '未保存：改动只在内存，重启会丢\n'
				;;
		esac
	fi
	rm -f "$BAK" "$ERR"
}
trap finish EXIT INT TERM

"${EDITOR:-vi}" "$f"
