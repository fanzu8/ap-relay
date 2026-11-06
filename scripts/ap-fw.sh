#!/bin/sh
# 转发 + NAT。
#
# 为什么需要：
#   客户端在 AP 网段（默认 192.168.43.0/24），上游只认识本机的上行地址。
#   不做源地址伪装，回包没有到 AP 网段的路由，会被上游直接丢掉。
#
# 后端选择：
#   优先使用 nftables（Alpine / postmarketOS 默认自带 nft），
#   没有 nft 时回退到 iptables。两条路径都会先清理自己的旧规则，
#   所以重复执行不会叠加规则。
#
# 幂等性：
#   nft 路径：每次先删掉独立的 inet ap_relay 表，再整体重建。
#   iptables 路径：规则带 comment "ap-relay"，先删同 tag 旧规则再添加。
set -eu
. "$(dirname "$0")/lib.sh"

sysctl -qw net.ipv4.ip_forward=1

# 清掉可能由旧版本或另一种后端留下的 NAT 规则，避免重复伪装。
cleanup_old_nat() {
	if command -v nft >/dev/null 2>&1; then
		nft delete table inet ap_relay 2>/dev/null || true
	fi
	if command -v iptables >/dev/null 2>&1; then
		iptables -w -t nat -S POSTROUTING 2>/dev/null | while IFS= read -r r; do
			case "$r" in
				"-A POSTROUTING "*"ap-relay"*)
					# shellcheck disable=SC2086
					set -- $r
					shift
					iptables -w -t nat -D "$@" 2>/dev/null || true
					;;
			esac
		done
	fi
}

# 放行 AP ↔ TUN 的转发（iptables 侧）。
#
# 为什么需要：dockerd 启动时会把 ip filter 的 FORWARD 默认策略设为 DROP，
# 并插入 DOCKER-USER / DOCKER-FORWARD。nft 的 inet filter 与 iptables 的
# ip filter 是两张独立的表，inet 里的 accept 覆盖不了 iptables 的 policy drop。
# 结果是策略路由、TUN、mihomo 都正常，客户端包却在 forward 阶段被丢掉
# （见 docs/pitfalls.md 坑 22）。
#
# 用 -I FORWARD 1 插到最前面：即使 Docker 在本脚本之后启动、把它的链插到
# 更前面，这两条仍然位于 policy drop 之前，照样生效。
allow_forward_iptables() {
	command -v iptables >/dev/null 2>&1 || return 0
	while iptables -w -D FORWARD -i "$AP_IF" -m comment --comment "ap-relay" -j ACCEPT 2>/dev/null; do :; done
	while iptables -w -D FORWARD -i "$TUN_DEV" -m comment --comment "ap-relay" -j ACCEPT 2>/dev/null; do :; done
	iptables -w -I FORWARD 1 -i "$AP_IF" -m comment --comment "ap-relay" -j ACCEPT
	iptables -w -I FORWARD 1 -i "$TUN_DEV" -m comment --comment "ap-relay" -j ACCEPT
}

# 放行 AP 入站（DHCP/DNS 之外，面板、SSH 等也依赖这条）。
# 只有 inet filter 表存在时才加；没有这张表时系统默认策略通常就是 accept。
allow_ap_input_nft() {
	if nft list chain inet filter input >/dev/null 2>&1; then
		nft list chain inet filter input | grep -q "iifname \"$AP_IF\"" || \
			nft add rule inet filter input iifname "$AP_IF" accept comment "ap-relay"
	fi
}

add_nat_nft() {
	# 独立表，避免和 iptables-nft 管理的 ip nat 表交叉修改（见坑 7）。
	nft -f - <<EOF
table inet ap_relay {
	chain postrouting {
		type nat hook postrouting priority srcnat; policy accept;
		oifname "$UPLINK_IF" ip saddr $AP_NET masquerade comment "ap-relay"
	}
}
EOF
}

add_nat_iptables() {
	# -w 等 xtables 锁，避免和 docker/其他服务并发时失败。
	iptables -w -t nat -A POSTROUTING -s "$AP_NET" -o "$UPLINK_IF" \
		-m comment --comment "ap-relay" -j MASQUERADE
}

cleanup_old_nat

if command -v nft >/dev/null 2>&1; then
	if add_nat_nft; then
		allow_ap_input_nft
	elif command -v iptables >/dev/null 2>&1; then
		echo "ap-fw: nft 失败，回退到 iptables" >&2
		add_nat_iptables
	else
		echo "ap-fw: nft 失败，且找不到 iptables" >&2
		exit 1
	fi
elif command -v iptables >/dev/null 2>&1; then
	add_nat_iptables
else
	echo "ap-fw: 需要 nft 或 iptables（Alpine / postmarketOS 安装 nftables 即可）" >&2
	exit 1
fi

# NAT 之后统一补 iptables 转发放行：无论 NAT 走 nft 还是 iptables，
# Docker 的 FORWARD policy drop 都会影响同一条转发路径。
allow_forward_iptables
