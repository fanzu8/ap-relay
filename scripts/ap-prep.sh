#!/bin/sh
# 创建 AP 接口并配好地址。
#
# 为什么需要这个脚本：
#   AP 接口不是硬件接口，是运行时用 `iw interface add` 造出来的，重启即消失。
#   把它放在 hostapd 的 ExecStartPre 里，保证每次启动都先有接口。
#
# 幂等性：
#   - 接口已存在则跳过创建
#   - 地址用 `ip addr replace`，重复执行不会报 "File exists"
. "$(dirname "$0")/lib.sh"

# 等上行接口出现（驱动加载需要几秒）。0.2s 轮询，最多 30s。
# 用轮询而不是固定 sleep：启动快、且不会在慢机器上抢跑。
i=0
while [ $i -lt 150 ]; do
	ip link show "$STA_IF" >/dev/null 2>&1 && break
	sleep 0.2; i=$((i+1))
done
if ! ip link show "$STA_IF" >/dev/null 2>&1; then
	echo "ap-prep: 等 $STA_IF 超时（30s），无线驱动可能没加载" >&2
	exit 1
fi
# 接口出现不代表驱动已就绪，再等一拍并复验
settle
if ! ip link show "$STA_IF" >/dev/null 2>&1; then
	echo "ap-prep: $STA_IF 在等待后消失（驱动重载？）" >&2
	exit 1
fi

# 建 AP 接口（已存在则跳过）
if ! iw dev "$AP_IF" info >/dev/null 2>&1; then
	iw dev "$STA_IF" interface add "$AP_IF" type __ap || exit 1
fi

ip link set "$AP_IF" up || exit 1

# replace 而不是 add：幂等，且地址变了也能纠正过来
ip addr replace "$AP_CIDR" dev "$AP_IF"

# 最后确认一次，避免“看起来成功其实没建出来”
iw dev "$AP_IF" info >/dev/null 2>&1 || exit 1
exit 0
