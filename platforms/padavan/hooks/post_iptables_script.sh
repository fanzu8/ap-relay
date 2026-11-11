#!/bin/sh
/etc/storage/crontabs_script.sh &
export PATH='/etc/storage/bin:/tmp/script:/etc/storage/script:/opt/usr/sbin:/opt/usr/bin:/opt/sbin:/opt/bin:/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin'
export LD_LIBRARY_PATH=/lib:/opt/lib

logger -t "【防火墙规则】" "脚本完成"


# mihomo 透明代理：防火墙重载后补回规则
[ -f /tmp/mihomo.pid ] && /etc/storage/mihomo-fw.sh up >/dev/null 2>&1
