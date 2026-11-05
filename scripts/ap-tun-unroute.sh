#!/bin/sh
# 撤掉策略路由。
#
# 为什么需要：
#   mihomo 停止/崩溃时如果不清理，客户端流量会被继续送进一个不存在的 TUN，直接断网。
#   清理后流量回落到内核转发 + NAT（见 ap-fw.sh），至少还能直连上网。
#
# 幂等性：删除用 while 循环，重复执行或规则不存在都不会报错。
. "$(dirname "$0")/lib.sh"
while ip rule del iif "$AP_IF" lookup "$TABLE_ID" 2>/dev/null; do :; done
ip route flush table "$TABLE_ID" 2>/dev/null || true
