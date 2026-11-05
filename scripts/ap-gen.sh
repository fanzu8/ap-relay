#!/bin/sh
# 由 /etc/ap-hotspot.conf 渲染 /etc/hostapd/ap.conf。
#
# 设计：唯一配置源是 ap-hotspot.conf，生成物永远不要手改。
# 幂等性：每次全量重写，结果只取决于输入配置。
set -eu
. "$(dirname "$0")/lib.sh"
. /etc/ap-hotspot.conf

OUT=/etc/hostapd/ap.conf
TMP=$(mktemp)
# 任何退出路径都清理临时文件（set -e 下尤其重要）
trap 'rm -f "$TMP"' EXIT INT TERM
mkdir -p /etc/hostapd

# ---- 输入校验：配置写错时早点报错，而不是生成一个坏配置 ----
if [ -z "${PASS:-}" ]; then
	echo "ap-gen: PASS 为空，请在 /etc/ap-hotspot.conf 设置密码" >&2
	exit 1
fi
if [ "${BAND:-}" = "5g" ]; then
	: "${SSID_5G:?ap-gen: BAND=5g 但 SSID_5G 为空}"
	: "${CHANNEL_5:?ap-gen: BAND=5g 但 CHANNEL_5 为空}"
else
	: "${SSID_24:?ap-gen: BAND=24g 但 SSID_24 为空}"
	: "${CHANNEL_24:?ap-gen: BAND=24g 但 CHANNEL_24 为空}"
fi

# 两个频段共用的 WPA2 参数
common() {
cat <<EOC
wpa=2
wpa_passphrase=$PASS
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
auth_algs=1
wmm_enabled=1
wpa_group_rekey=${GROUP_REKEY:-600}
EOC
}

if [ "$BAND" = "5g" ]; then
  {
    echo "ssid=$SSID_5G"
    echo "hw_mode=a"
    echo "channel=$CHANNEL_5"
    echo "ieee80211n=1"
    common
    # 80MHz 需要指定中心频点（比主信道高 6 个）
    case "${WIDTH_5:-80}" in
      80) echo "ht_capab=[HT40+]"
          echo "ieee80211ac=1"
          echo "vht_oper_chwidth=1"
          echo "vht_oper_centr_freq_seg0_idx=$((CHANNEL_5+6))" ;;
      40) echo "ht_capab=[HT40+]" ;;
      *)  : ;;
    esac
  } > "$TMP"
else
  {
    echo "ssid=$SSID_24"
    echo "hw_mode=g"
    echo "channel=$CHANNEL_24"
    echo "ieee80211n=1"
    common
  } > "$TMP"
fi

# 先写临时文件再 mv：避免 hostapd 读到写了一半的配置
{
	echo "interface=$AP_IF"
	echo "driver=nl80211"
	cat "$TMP"
} > "$OUT.new"
chmod 600 "$OUT.new"
mv -f "$OUT.new" "$OUT"

# 设备特定的兜底：某些 ath10k 固件在 cryptmode>0 时会整卡消失，
# 这个 modprobe 覆盖文件一旦存在就会触发。非 ath10k 机器删除它也无害。
rm -f /etc/modprobe.d/ath10k-cryptmode.conf
