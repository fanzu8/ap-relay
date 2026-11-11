#!/bin/sh

### Custom user script
### Called after router started and network is ready

### Example - load ipset modules
modprobe ip_set
modprobe ip_set_hash_ip
modprobe ip_set_hash_net
modprobe ip_set_bitmap_ip
modprobe ip_set_list_set
modprobe xt_set

/etc/storage/www_sh/menu_title.sh &

#confdir=`grep "/tmp/ss/dnsmasq.d" /etc/storage/dnsmasq/dnsmasq.conf | sed 's/.*\=//g'`
#if [ -z "$confdir" ] ; then 
    confdir="/tmp/ss/dnsmasq.d"
#fi
mkdir -p /tmp/ss_tproxy/dnsmasq.d
[ ! -d "$confdir" ] && mkdir -p $confdir
# SMB 资源挂载示例已移除（原文件此处含 Padavan 自带的示例 IP 与占位账号）

sleep 5
stop_ftpsamba
sleep 3
#mdev -s
# 挂载SD卡
for mmc_mount in `/usr/bin/find  /dev -name 'mmcblk[0-9]*' | awk '{print $1}'`
do
[ ! -z "$(df -m | grep $mmc_mount )" ] && continue
mmc_mount=$(basename $mmc_mount | awk '{print $1}')
echo $mmc_mount
device_name=`echo ${mmc_mount:6:1}`
partno=`echo ${mmc_mount:8:1}`
[ -z "$partno" ] && partno=1
/sbin/automount.sh $mmc_mount AiCard_$device_name$partno
done

# 挂载存储设备
for sd_mount in `/usr/bin/find  /dev -name 'sd[a-z]*' | awk '{print $1}'`
do
[ ! -z "$(df -m | grep $sd_mount )" ] && continue
sd_mount=$(basename $sd_mount | awk '{print $1}')
echo $sd_mount
device_name=`echo ${sd_mount:2:1}`
partno=`echo ${sd_mount:3:1}`
[ -z "$partno" ] && partno=1
/sbin/automount.sh $sd_mount AiDisk_$device_name$partno
done
sleep 3
run_ftpsamba
sleep 3

### 运行脚本1
/etc/storage/script_script.sh
/etc/storage/script/sh_ezscript.sh 3 & #更新按钮状态
logger -t "【运行路由器启动后】" "脚本完成"


#启动流量监控脚本
mkdir -p /tmp/bwmon
/usr/sbin/bwmon &


# ap-relay ssh key: /home 是 tmpfs，重启后恢复公钥
mkdir -p /home/root/.ssh
chmod 700 /home/root/.ssh
if [ -f /etc/storage/ssh/authorized_keys ]; then
    ln -sf /etc/storage/ssh/authorized_keys /home/root/.ssh/authorized_keys
fi

/etc/storage/mihomo-sysctl.sh

# mihomo 透明代理（RWFS 持久分区，存在 enabled 文件才自启）
/etc/storage/mihomo-start.sh &
