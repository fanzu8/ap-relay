#!/bin/sh
# 把「从 AP 接口进来、需要转发」的流量导入 mihomo 的 TUN。
#
# 核心思想：策略路由只匹配 iif <AP>。
#   本机自己产生的流量 iif 不是 AP 接口，因此永远不会被代理
#   —— 这也是代理挂掉时 SSH / 面板仍然可用的原因。
#
# 幂等性：
#   - ip rule / ip route 都是“先删后加”
#   - 删除用 while 循环，能清掉历史遗留的重复规则
#   - nft 规则先检查再添加
. "$(dirname "$0")/lib.sh"
set -u

# 等 TUN 出现（由 mihomo 创建）。0.2s 轮询，最多 10s。
i=0
while [ $i -lt 50 ]; do
	ip link show "$TUN_DEV" >/dev/null 2>&1 && break
	sleep 0.2; i=$((i+1))
done
if ! ip link show "$TUN_DEV" >/dev/null 2>&1; then
	echo "ap-tun-route: TUN $TUN_DEV 未出现（mihomo 启动失败？）" >&2
	exit 1
fi
# TUN 建出来时可能还没初始化完；等一拍再复验，避免路由挂到瞬态设备上
settle
if ! ip link show "$TUN_DEV" >/dev/null 2>&1; then
	echo "ap-tun-route: TUN $TUN_DEV 在等待后消失（mihomo 重启中？）" >&2
	exit 1
fi
ip link set "$TUN_DEV" up 2>/dev/null || true

# 回程包是从 TUN 注入的、源地址为境外 IP，严格的 rp_filter 会把它们当“伪造源”丢掉。
# 这里统一设为 0（宽松模式）；代价是失去一部分反欺骗能力，属于本方案的取舍。
for f in /proc/sys/net/ipv4/conf/*/rp_filter; do echo 0 > "$f" 2>/dev/null || true; done

# 先清掉同名规则（可能有重复），再加一条
while ip rule del iif "$AP_IF" lookup "$TABLE_ID" 2>/dev/null; do :; done
ip rule add iif "$AP_IF" lookup "$TABLE_ID" pref "$RULE_PREF"

# 表内路由：AP 网段直连，其余全部进 TUN
ip route flush table "$TABLE_ID" 2>/dev/null || true
ip route add "$AP_NET" dev "$AP_IF" table "$TABLE_ID"
ip route add default dev "$TUN_DEV" table "$TABLE_ID"

# mixed/system 栈会把连接改写成 <tun 地址> -> <tun 地址:随机端口> 再从 TUN 进入本机。
# input 默认 policy drop 时这些包会被丢掉，表现为“TUN 有流量、连接表却是空的”。
# 详见 docs/pitfalls.md 坑 18。
if command -v nft >/dev/null 2>&1; then
	nft list chain inet filter input 2>/dev/null | grep -q "iifname \"$TUN_DEV\"" || \
		nft add rule inet filter input iifname "$TUN_DEV" accept 2>/dev/null || true
fi

echo "ap-tun-route: ok"
