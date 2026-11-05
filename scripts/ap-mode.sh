#!/bin/sh
# 用法: ap-mode.sh 24g|5g
# 作用：改 BAND → 重新渲染配置 → 重启 hostapd → 等它真的起来。
. "$(dirname "$0")/lib.sh"

case "$1" in
  24g|2.4g|2g) B=24g ;;
  5g|5G)       B=5g  ;;
  *) echo "用法: ap-mode.sh 24g|5g"; exit 1 ;;
esac

# sed 只改 BAND 这一行，重复执行结果一致（幂等）
sed -i "s/^BAND=.*/BAND=$B/" /etc/ap-hotspot.conf
"$(dirname "$0")/ap-gen.sh"
systemctl restart ap-hostapd

# 轮询等待 AP 真的起来（最多 10s，每 0.2s 检查一次，好了立刻返回）。
# 同时等 ssid 写进接口：hostapd 刚启动的瞬间 iw info 里可能还没有 ssid，
# 只看 is-active 会抢跑，随后 grep 取不到内容导致脚本误报失败。
i=0
while [ $i -lt 50 ]; do
	systemctl is-active --quiet ap-hostapd &&
		iw dev "$AP_IF" info 2>/dev/null | grep -q 'ssid' && break
	sleep 0.2; i=$((i+1))
done

# 命中后再等一拍，复验接口和 ssid 仍然在
settle

if ! systemctl is-active --quiet ap-hostapd; then
	echo "ap-mode: ap-hostapd 未启动，检查 journalctl -u ap-hostapd" >&2
	exit 1
fi
if ! iw dev "$AP_IF" info 2>/dev/null | grep -q 'ssid'; then
	echo "ap-mode: hostapd 已启动但接口上没有 SSID，检查 journalctl -u ap-hostapd" >&2
	exit 1
fi

echo "BAND=$B  $(systemctl is-active ap-hostapd)"
iw dev "$AP_IF" info 2>/dev/null | grep -E "ssid|channel|width"
