# Troubleshooting

**English** | [中文](troubleshooting_zh.md)

Start with the one-shot health check:

```sh
sudo ap-diag.sh
```

> Variables such as `$AP_IF`, `$TUN_DEV`, `$TABLE_ID`, `$UI_PORT`, and `$DNS_PORT`
> below come from `/etc/ap-relay.conf`. In a root shell, run
> `. /etc/ap-relay.conf` first, or replace them with the actual values.

## Symptom → command → interpretation

### Clients cannot join the hotspot

```sh
iw dev <AP_IF> info | grep ssid        # does the AP exist?
systemctl status ap-hostapd            # is it in a restart loop?
journalctl -u ap-hostapd -n 30
```

- `interface ... not found` → `ap-prep.sh` did not create the interface; check whether the uplink is ready
- Repeated `AP-DISABLED` → usually encryption/key issues (see pitfall 3, `-110`)

### Clients connect but cannot open pages

```sh
cat /var/lib/misc/dnsmasq.leases        # did they get an address?
nslookup www.example.com <AP_IP>         # does it return 198.18.x.x?
ip rule show | grep iif                 # is policy routing present?
ip route show table $TABLE_ID
cat /sys/class/net/<TUN>/statistics/rx_packets   # is the TUN receiving?
```

Interpret in this order:

1. No lease → DHCP problem (dnsmasq not running / interface mismatch)
2. DNS does not return a fake IP → mihomo DNS is not up, or dnsmasq's upstream is not `$DNS_PORT`
3. Fake IP works but TUN counters do not increase → policy routing is not active
4. TUN has packets but connections fail → **check whether the firewall input chain allows the TUN** (see below)

### The TUN has traffic but mihomo's connection table is empty

This is the most subtle class: packets enter the TUN, but no connection is ever
established.

```sh
curl -sS -H "Authorization: Bearer <secret>" http://127.0.0.1:$UI_PORT/connections
```

If it returns `connections: null` while `tcpdump -i <TUN>` shows client SYNs:

```sh
sudo nft list chain inet filter input | grep -i tun
```

**Cause**: the `system`/`mixed` stack rewrites the connection to
`<tun>:x -> <tun>:random port>` and injects it back into the host through the
TUN. With the `input` chain's default `policy drop`, the SYN is dropped and no
SYN-ACK is ever sent.

**Fix**:

```sh
sudo nft add rule inet filter input iifname "<TUN>" accept
```

### Only one site fails (everything else works)

```sh
journalctl -u ap-mihomo -f | grep -E '\[(TCP|UDP)\]'
```

Look at the matched rule:

- `match GeoIP(cn) using DIRECT` but the target is a foreign site → the domain resolved to a domestic IP; move domain rules earlier (pitfall 19)
- `match GeoSite(...) using 🚀 代理` but the connection times out → node problem; try another node/route
- No log at all → packets never entered the TUN, or the firewall dropped them (`journalctl -k | grep nft-drop`)

### Pages spin forever (browser works, app does not)

First check whether the provider supports UDP:

```sh
curl -sS -H "Authorization: Bearer <secret>" http://127.0.0.1:$UI_PORT/connections \
  | tr '{' '\n' | grep '"network":"udp"' \
  | grep -oE '"host":"[^"]*"|"upload":[0-9]+|"download":[0-9]+' | paste - -
```

`upload` has a value but `download` stays 0 = UDP relay is unavailable → block
QUIC (pitfall 21).

### The dashboard does not load

```sh
ss -lntp | grep "$UI_PORT"
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:$UI_PORT/ui/
nft list chain inet filter input | grep "$UI_PORT"
```

- Local 200, external timeout → the firewall does not allow the source subnet
- 401 → no secret supplied (normal)
- Blank page → possibly a Service Worker cache (see the "blank UI" pitfall)

### Services will not start

```sh
systemctl status ap-hostapd ap-dnsmasq ap-mihomo ap-firewall
journalctl -u ap-mihomo -n 50
```

Common causes:

| Symptom | Cause |
|---|---|
| `ap-prep: timed out waiting for <STA_IF>` | Wireless driver not loaded / wrong interface name |
| `ap-tun-route: TUN not found` | mihomo failed to start (bad config, port already in use) |
| dnsmasq `address already in use` | Another DHCP/DNS service occupies `$DNS_STD_PORT` / `$DHCP_PORT` |
| hostapd `interface not found` | The AP interface was not created |

## Packet capture

```sh
sudo tcpdump -i <AP_IF> -nn "port $DNS_STD_PORT" # DNS exchange
sudo tcpdump -i <TUN> -nn -c 20                  # is client traffic entering the TUN?
sudo tcpdump -i <TUN> -nn "udp port $QUIC_PORT"  # QUIC attempts
journalctl -k -f | grep nft-drop                 # packets dropped by the firewall
```

## Reading `ap-diag` output

| Section | Normal | Meaning of an anomaly |
|---|---|---|
| `[1] 服务` (services) | All `active` | Any `inactive/failed` → inspect that unit |
| `[3] 策略路由` (routing) | `iif <AP>` + two `table $TABLE_ID` routes | Missing = `ap-tun-route.sh` did not run |
| `[4] TUN` | Address present, rx/tx increasing | No address = mihomo is not up |
| `[5] 防火墙` (firewall) | TUN allow rule present | Missing = pitfall 18 |
| `[8] 规则命中统计` (rule hits) | `GeoSite(...)` matches | Lots of `GeoIP(cn) DIRECT` for foreign domains = pitfall 19 |
| `[9] DNS` | All three domains return `198.18.x.x` | Real IP returned = fake-ip is not active |
| `[10] 代理连通性` (proxy) | `204` + foreign egress IP | Timeout = node/subscription problem |
