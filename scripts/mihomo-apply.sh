#!/bin/sh
# ===========================================================================
# 编排层：把模板安全地变成线上配置
# ===========================================================================
# 一条命令完成：渲染 → 校验 → 备份 → 替换 → 重启 → 等端口。
# 任何一步失败都回滚，绝不把“半生效”的配置留在线上。
#
# 用法：
#   mihomo-apply.sh [--dry-run] [模板] [平台配置] [私有配置]
#
#   --dry-run  只渲染 + 校验 + 输出差异，不动线上配置、不重启
#
# 例：
#   sudo mihomo-apply.sh --dry-run
#   sudo mihomo-apply.sh
#   sudo mihomo-apply.sh templates/mihomo.config.yaml
#
# 模板省略时按平台自动探测（手机 /usr/local/share，路由器 /media/mtd_rwfs）。
# 本脚本只做流程编排；渲染、校验、端口等待分别由 render / verify / lib 负责。
# ===========================================================================
set -eu

here=$(dirname "$0")

dry=0
if [ "${1:-}" = "--dry-run" ]; then
	dry=1
	shift
fi

tmpl=${1:-}
conf=${2:-}
localconf=${3:-}

# ---- 1. 配置层 + 能力层 ---------------------------------------------------
# 先载入变量和函数，后面才能用 mihomo_die / mihomo_conf_file。
. "$here/mihomo-vars.sh" "$conf" "$localconf"
. "$here/mihomo-lib.sh"

# ---- 2. 定位模板 ----------------------------------------------------------
# 顺序覆盖两台设备的安装位置；最后两个是仓库内直接运行的场景。
if [ -z "$tmpl" ]; then
	for t in /usr/local/share/ap-relay/mihomo.config.yaml \
	         /etc/storage/mihomo.config.yaml \
	         /media/mtd_rwfs/mihomo/mihomo.config.yaml.tpl \
	         "$here/../templates/mihomo.config.yaml" \
	         "$here/mihomo.config.yaml"; do
		[ -r "$t" ] && { tmpl=$t; break; }
	done
fi
[ -n "$tmpl" ] && [ -r "$tmpl" ] || mihomo_die \
	"找不到模板：显式传一个，或放到 /usr/local/share/ap-relay/mihomo.config.yaml"

cfg=$(mihomo_conf_file) || cfg=
[ -n "$cfg" ] || mihomo_die "找不到 mihomo 配置（/etc/mihomo/config.yaml 或持久分区里的同名文件）"

new="$cfg.new"
rm -f "$new"

printf '模板 : %s\n' "$tmpl"
printf '输出 : %s\n\n' "$cfg"

# ---- 3. 渲染 + 校验（纯转换层，失败不影响线上） ---------------------------
"$here/mihomo-render.sh" "$tmpl" "$new" "$conf" "$localconf"
"$here/mihomo-verify.sh" "$new" "$conf" "$localconf"
printf '\n'

# ---- 4. 差异概览 ----------------------------------------------------------
show_diff() {
	printf '与当前配置对比：\n'
	if have diff; then
		changed=$(diff -u "$cfg" "$new" 2>/dev/null |
			grep -c '^[+-][^+-]' || true)
		changed=${changed:-0}
		printf '  变更行数: %s\n' "$changed"
		if [ "$changed" -gt 0 ]; then
			diff -u "$cfg" "$new" 2>/dev/null |
				sed -n '1,60p' | sed 's/^/  /'
			[ "$changed" -gt 30 ] && printf '  ...（只显示前 60 行）\n'
		fi
	else
		printf '  当前 %s 字节 → 新 %s 字节\n' \
			"$(wc -c < "$cfg" | tr -d ' ')" \
			"$(wc -c < "$new" | tr -d ' ')"
		printf '  （本机没有 diff，看不出具体差异；可先在别的机器上 --dry-run）\n'
	fi
	printf '\n'
}
show_diff

if [ "$dry" = "1" ]; then
	printf 'dry-run：未改动线上配置。渲染结果在 %s\n' "$new"
	exit 0
fi

# ---- 5. 备份并替换 --------------------------------------------------------
bak="$cfg.bak.$(date +%Y%m%d-%H%M%S)"
cp -a "$cfg" "$bak"
printf '已备份: %s\n' "$bak"

mv -f "$new" "$cfg"
chmod 600 "$cfg" 2>/dev/null || true
printf '已替换: %s\n' "$cfg"

# ---- 6. 重启并等端口；失败回滚 --------------------------------------------
# 回滚 = 恢复备份 + 再重启一次。两处都失败时保留现场，让人能 SSH 进去查。
rollback() {
	printf '回滚到备份...\n' >&2
	cp -a "$bak" "$cfg"
	mihomo_restart || printf '回滚后重启失败，请手动检查\n' >&2
}

printf '重启 mihomo...\n'
if ! mihomo_restart; then
	printf '重启失败\n' >&2
	rollback
	exit 1
fi

want=$(mihomo_expected_ports)
if ! mihomo_wait_ports $want; then
	printf '端口没起来，配置未生效\n' >&2
	rollback
	exit 1
fi

printf '\n'
if have systemctl &&
   systemctl list-unit-files 2>/dev/null | grep -q '^ap-mihomo\.service'; then
	printf '服务: %s\n' "$(systemctl is-active ap-mihomo 2>/dev/null)"
fi
printf '端口: %s\n' "$(printf '%s\n' $want | sed 's/^/:/' | tr '\n' ' ')"
printf '完成。回滚命令：\n'
printf '  sudo cp -a %s %s\n' "$bak" "$cfg"
printf '  sudo systemctl restart ap-mihomo    # Padavan: /etc/storage/mihomo-start.sh\n'
