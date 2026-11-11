#!/bin/sh
# ===========================================================================
# 配置层：mihomo 渲染变量
# ===========================================================================
# 职责：只负责「把变量准备好」，不含任何函数或业务逻辑。
#
# 载入顺序（后面的覆盖前面的）：
#   1. 本文件里的保守默认值（保证缺项也能渲染）
#   2. 平台配置（手机 /etc/ap-relay.conf，路由器 /etc/storage/mihomo.conf）
#   3. 私有配置（* .local.conf，只放 SECRET / SUB_URL）
#
# 用法（被其它脚本 source，不要直接执行）：
#   . mihomo-vars.sh [平台配置] [私有配置]
#
# 平台配置省略时按固定路径探测；私有配置默认跟随平台配置的后缀：
#   手机   : /etc/ap-relay.conf        → /etc/ap-relay.local.conf
#   路由器 : /etc/storage/mihomo.conf  → /etc/storage/mihomo.local.conf
#
# 凭据约束：SECRET 与 SUB_URL 只允许出现在 .local.conf（权限 600），
# 仓库、模板、平台配置里一律不写真实值。
#
# 工具约束（两台设备都缺一不可的才算数）：
#   有   : sed / awk / grep / curl / wget / md5sum / sort / uniq
#   没有 : 路由器没有 python3、mktemp、diff、cmp、sha256sum；手机没有 jq
# 因此本目录脚本一律不依赖后者。
# ===========================================================================

# ---- 1. 平台配置 -----------------------------------------------------------
# 用 MIHOMO_PLATFORM_CONF 记住最终选了哪个文件：
#   - 能力层（mihomo-lib.sh）靠它判断当前是手机还是路由器；
#   - 出错时也方便打印「到底读的是哪份配置」。
MIHOMO_PLATFORM_CONF=${1:-}
if [ -z "$MIHOMO_PLATFORM_CONF" ]; then
	if [ -r /etc/ap-relay.conf ]; then
		MIHOMO_PLATFORM_CONF=/etc/ap-relay.conf
	elif [ -r /etc/storage/mihomo.conf ]; then
		MIHOMO_PLATFORM_CONF=/etc/storage/mihomo.conf
	fi
fi
if [ -n "$MIHOMO_PLATFORM_CONF" ] && [ -r "$MIHOMO_PLATFORM_CONF" ]; then
	. "$MIHOMO_PLATFORM_CONF"
fi

# ---- 2. 私有配置（凭据） ---------------------------------------------------
# 只在用户没有显式指定时，才根据平台配置的位置推断默认路径。
MIHOMO_LOCAL_CONF=${2:-}
if [ -z "$MIHOMO_LOCAL_CONF" ]; then
	case "$MIHOMO_PLATFORM_CONF" in
		*/ap-relay.conf)   MIHOMO_LOCAL_CONF=/etc/ap-relay.local.conf ;;
		*/mihomo.conf)     MIHOMO_LOCAL_CONF=/etc/storage/mihomo.local.conf ;;
	esac
fi
if [ -n "$MIHOMO_LOCAL_CONF" ] && [ -r "$MIHOMO_LOCAL_CONF" ]; then
	. "$MIHOMO_LOCAL_CONF"
fi

# ---- 3. 入站 / 面板 -------------------------------------------------------
# 兼容旧配置：历史变量名 PROXY_PORT 等价于 GLOBAL_PORT（与 lib.sh 保持一致）。
if [ -z "${GLOBAL_PORT:-}" ] && [ -n "${PROXY_PORT:-}" ]; then
	GLOBAL_PORT=$PROXY_PORT
fi
GLOBAL_PORT=${GLOBAL_PORT:-7890}       # mixed（HTTP+SOCKS5）入口
UI_PORT=${UI_PORT:-9090}               # 面板 + REST API
UI_BIND=${UI_BIND:-0.0.0.0}            # 面板监听地址
ALLOW_LAN=${ALLOW_LAN:-true}           # 是否允许局域网设备用代理端口
BIND_ADDRESS=${BIND_ADDRESS:-*}        # mihomo 入站绑定地址
LOG_LEVEL=${LOG_LEVEL:-warning}
# 整行变量：路由器保留 "redir-port: 1009"，手机走 TUN 时整行注释掉。
# 之所以不写成数字，是因为这行在模板里必须「存在或整行不存在」。
REDIR_LINE=${REDIR_LINE:-'# redir-port: 不用（走 TUN）'}

# ---- 4. DNS ---------------------------------------------------------------
DNS_PORT=${DNS_PORT:-53}                       # 仅用于拼默认 DNS_LISTEN
DNS_LISTEN=${DNS_LISTEN:-127.0.0.1:$DNS_PORT}  # mihomo dns.listen
# 必须是 DoH/TLS：上游若劫持明文 53，节点域名会被解析成 fake-ip。
PROXY_SERVER_NS=${PROXY_SERVER_NS:-'[https://dns.alidns.com/dns-query]'}

# ---- 5. sniffer -----------------------------------------------------------
# REDIRECT 模式必须 true（否则规则按 IP 匹配，域名规则失效）；TUN 模式 false。
SNIFFER_OVERRIDE_DESTINATION=${SNIFFER_OVERRIDE_DESTINATION:-false}
SNIFFER_HTTP_PORTS=${SNIFFER_HTTP_PORTS:-'[80, 8080-8880]'}
HTTP_PORT=${HTTP_PORT:-80}
HTTP_ALT_START=${HTTP_ALT_START:-8080}
HTTP_ALT_END=${HTTP_ALT_END:-8880}
TLS_PORT=${TLS_PORT:-443}
TLS_ALT_PORT=${TLS_ALT_PORT:-8443}

# ---- 6. TUN ---------------------------------------------------------------
TUN_DEV=${TUN_DEV:-meta}                 # 必须与 tun.device 一致
TUN_ENABLE=${TUN_ENABLE:-true}           # 手机 true；路由器 redirect 模式 false
TUN_STACK=${TUN_STACK:-mixed}
TUN_AUTO_DETECT_INTERFACE=${TUN_AUTO_DETECT_INTERFACE:-true}

# ---- 7. geo 数据 ----------------------------------------------------------
GEO_AUTO_UPDATE=${GEO_AUTO_UPDATE:-true}
GEO_UPDATE_INTERVAL=${GEO_UPDATE_INTERVAL:-2160}   # 单位：小时（90 天）

# ---- 8. 订阅 provider -----------------------------------------------------
# SUB_URL 是凭据，必须在私有配置里；这里只给空默认值。
PROVIDER_NAME=${PROVIDER_NAME:-juzi}
SUB_URL=${SUB_URL:-}
SUB_UA=${SUB_UA:-clash-verge/v2.0.0}
SUB_INTERVAL=${SUB_INTERVAL:-21600}      # 秒；21600 = 6 小时
EXCLUDE_FILTER=${EXCLUDE_FILTER:-'(?i)回家页|查看公告'}
HEALTH_CHECK_INTERVAL=${HEALTH_CHECK_INTERVAL:-180}
SECRET=${SECRET:-}

# ---- 9. 渲染变量清单 ------------------------------------------------------
# 只有这个清单里的变量会被喂给渲染器；新增模板占位符时记得同步加进来。
# 顺序即注释顺序，便于排查「模板里有、清单里漏了」。
MIHOMO_VAR_LIST="GLOBAL_PORT UI_PORT UI_BIND ALLOW_LAN BIND_ADDRESS LOG_LEVEL
REDIR_LINE DNS_PORT DNS_LISTEN PROXY_SERVER_NS SNIFFER_OVERRIDE_DESTINATION
SNIFFER_HTTP_PORTS HTTP_PORT HTTP_ALT_START HTTP_ALT_END TLS_PORT TLS_ALT_PORT
TUN_DEV TUN_ENABLE TUN_STACK TUN_AUTO_DETECT_INTERFACE GEO_AUTO_UPDATE
GEO_UPDATE_INTERVAL PROVIDER_NAME SUB_URL SUB_UA SUB_INTERVAL EXCLUDE_FILTER
HEALTH_CHECK_INTERVAL SECRET"
