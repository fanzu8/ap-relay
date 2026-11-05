# Pitfall list

**English** | [中文](pitfalls_zh.md)

Sorted by "how painful it was when we hit it". Each entry gives **symptom /
cause / fix**, with commands where the issue is reproducible.

> Commands use variable names such as `$AP_IF`, `$TUN_DEV`, `$UI_PORT`, and
> `$QUIC_PORT` from `/etc/ap-relay.conf`. Source that file in a root shell or
> replace the names with actual values. The `nft` snippets use template
> placeholders such as `${AP_IF}`; render the template with `ap-render.sh` or
> substitute the actual values.

---

## 1. TLS sniffing rewrites the destination → fake-SNI clients all fail

**Symptom**: clients connect, but every connection fails after 3 seconds. The log shows:

```
sniffed domain: random.example for tcp:203.0.113.10:40487
failed: dial tcp: lookup random.example: no such host
```

**Cause**: some clients (game accelerators, some apps) use a "fake SNI" — the
domain in TLS is a random string and the real connection is made by IP. If the
middlebox rewrites the destination IP to the sniffed domain, it tries to resolve
a domain that does not exist.

**Fix**: keep this in mihomo:

```yaml
sniffer:
  override-destination: false
```

Sniffing is for **rule matching only**, not for rewriting the destination.

---

## 2. Mixing TPROXY and REDIRECT → connecting to yourself

**Symptom**: CPU pegged, memory exploding, connection count through the roof.

**Cause**: `sockopt.tproxy` and iptables `REDIRECT` enabled at the same time.
REDIRECT targets `SO_ORIGINAL_DST`, while tproxy makes the process treat its own
listen address as the destination → self-connection.

**Fix**: pick one, never mix. This project uses TUN, so neither is needed.

**Lesson**: this kind of mistake passes syntax checks and the process is
`active`; only the destination address in the logs reveals it.

---

## 3. 5GHz + WPA2 key installation timeout (-110)

**Symptom**: 3 seconds after `AP-ENABLED` it becomes `AP-DISABLED`; the log shows
`-110 (ETIMEDOUT)`.

**Cause**: hostapd installs the group key (GTK) after the AP starts, and the
firmware times out on that WMI command. Open networks do not install a GTK, so
they do not trigger it.

**Fix** (try in order):

1. `GROUP_REKEY=0` (disable group-key rotation)
2. Switch to 2.4GHz
3. Change the card (USB AP)
4. Wait for a firmware fix

**Do not** try `cryptmode=1` (see pitfall 15).

---

## 4. Processes started with `setsid` are killed by systemd

**Symptom**: manual testing works, but the child process disappears after it is
turned into a service.

**Cause**: systemd manages by cgroup by default. `setsid` leaves the session but
not the cgroup.

**Fix**: use `systemd-run --unit=...`, or just write a proper unit.

---

## 5. `tproxy` is a reserved word in nftables

**Symptom**: `nft add table inet tproxy` reports a syntax error.

**Fix**: use another table name (e.g. `inet filter`). This is a naming conflict,
not a permission problem.

---

## 6. macOS `networksetup` false negative

**Symptom**: the hotspot is not visible when scanning on a Mac, so you assume the
AP is not broadcasting.

**Cause**: newer macOS versions are unreliable with
`networksetup -listallnetworkservices` / scanning.

**Fix**: verify with another device (phone/another computer), or use `wdutil` /
the System Settings UI.

---

## 7. The `ip nat` table is owned by iptables-nft

**Symptom**:

```
# Warning! table ip nat is managed by iptables-nft, do not touch!
```

You edit it with `nft`, then `iptables` changes it back.

**Fix**: use one backend consistently. Either use `iptables` everywhere or `nft`
everywhere; do not modify the same table with both.

---

## 8. nft `input` default drop blocks hotspot clients

**Symptom**: clients join Wi-Fi but cannot get an IP or resolve names.

**Cause**: the `input` chain has `policy drop`, and DHCP (`$DHCP_PORT`) / DNS
(`$DNS_STD_PORT`) are not allowed.

**Fix**:

```nft
iifname "${AP_IF}" udp dport ${DHCP_PORT} accept
iifname "${AP_IF}" tcp dport ${DNS_STD_PORT} accept
iifname "${AP_IF}" udp dport ${DNS_STD_PORT} accept
```

---

## 9. dnsmasq fails to start because of log-file permissions

**Symptom**: `dnsmasq: cannot open log /var/log/dnsmasq.log: Permission denied`.

**Fix**: send logs to the journal instead of a file:

```
--log-facility=-
```

---

## 10. Demo blocking rules are landmines and break other apps

**Symptom**: to prove "traffic really goes through the proxy", you add
`block <public DNS IP>`. Client proxy apps then fail their startup probe and it
looks like "joining this hotspot breaks the Internet".

**Fix**: delete it immediately after testing. Blocking rules should target a
specific domain/port, not public DNS.

---

## 11. Changing the MAC address is a dead end

**Symptom**: you change the MAC while debugging the AP and nothing improves.

**Fix**: AP problems are almost always driver/firmware/channel/encryption, not
MAC. Do not waste time here.

---

## 12. The device cannot reach GitHub Releases

**Symptom**: `curl` downloading mihomo times out or is reset.

**Fix**: download it on a computer and `scp` it over, or use a trusted mirror.
**Do not** retry endlessly on the device.

---

## 13. BusyBox `ip` / `ps` lack GNU options

**Symptom**: `ip -br`, `ps -p <pid>` report `unrecognized option`.

**Fix**:

```sh
ip -o addr show <if>          # instead of ip -br
grep VmRSS /proc/<pid>/status # instead of ps -o rss
```

---

## 14. `unudhcpd` also occupies `0.0.0.0:67`

**Symptom**: `ss -lunp` shows two processes listening on 67.

**Cause**: some phone images ship `unudhcpd` for USB networking.

**Fix**: run dnsmasq with `--interface=<AP> --bind-interfaces` so it only binds
the hotspot interface. If DHCP behaves strangely, first check that two DHCP
servers are not answering on the same subnet.

---

## 15. `cryptmode=1` makes the whole Wi-Fi card disappear

**Symptom**: after changing the module parameter, `wlan0` / the AP interface are
gone and SSH dies too.

**Cause**: `ath10k_snoc: cryptmode > 0 requires raw mode support from firmware`
→ `fatal problem with firmware features: -22` → probe fails and the whole card is
never created.

**Fix**:

```sh
sudo rm -f /etc/modprobe.d/ath10k-cryptmode.conf
sudo modprobe -r ath10k_snoc && sudo modprobe ath10k_snoc
```

**Lesson**: before changing any module parameter that affects probe, keep a
non-Wi-Fi rescue path (USB networking / serial).

---

## 16. The AP interface is created at runtime and must be rebuilt by the unit

**Symptom**: after reboot, hostapd reports `interface not found` and restarts
forever.

**Cause**: the AP interface is created with
`iw dev <STA> interface add <AP> type __ap`, and it disappears on reboot.

**Fix**: put it in `ExecStartPre` and **wait for the uplink interface**:

```ini
ExecStartPre=/usr/local/bin/ap-prep.sh
ExecStartPre=/usr/local/bin/ap-gen.sh
ExecStart=/usr/sbin/hostapd /etc/hostapd/ap.conf
```

Verify without rebooting:

```sh
sudo ip link del <AP_IF>
sudo systemctl restart ap-hostapd
iw dev <AP_IF> info | grep ssid
```

---

## 17. Do not use a fixed `sleep` for waiting

**Symptom**: slow startup, or occasional races (the script continues before the
interface exists).

**Fix**: poll with an upper bound and return as soon as the condition is met:

```sh
i=0
while [ $i -lt 150 ]; do
    ip link show "$STA_IF" >/dev/null 2>&1 && break
    sleep 0.2; i=$((i+1))
done
```

A fixed `sleep 4` is both slow and unreliable; a 1-second poll wastes startup
time.

---

## 18. The TUN stack loopback needs an `input` allow 【most subtle】

**Symptom**: client DNS works (clients get fake IPs) and packets enter the TUN,
but **not a single connection is established**; `/connections` is always empty.

```
# tcpdump -i <TUN>
192.168.43.100.55206 > 198.18.0.25.443: Flags [S]
198.18.0.2.10104    > 198.18.0.1.38881: Flags [S]   ← then nothing
```

**Cause**: the `system` / `mixed` stack rewrites the connection to
`<tun address> → <tun address:random port>` and injects it back into the kernel
**as an inbound packet** through the TUN. That path goes through the `input`
chain, which has `policy drop`.

**Fix**:

```sh
sudo nft add rule inet filter input iifname "<TUN>" accept
```

**Why every check "looks right"**: `ip rule`, `ip route get`, DNS, and TUN
counters are all normal; the only anomaly is an empty connection table.
**"TUN has packets + connection table empty" → check the input chain first.**

---

## 19. Domestic DNS + `GEOIP,CN` classifies foreign sites as direct

**Symptom**: some sites (typically Google) fail while others work. Log:

```
[TCP] --> media.example.com:443 match GeoIP(cn) using DIRECT
dial tcp 203.0.113.20:443: i/o timeout
```

**Cause**: domestic DNS resolves Google domains to domestic CDN/carrier cache
IPs; `GEOIP,CN` classifies them as direct, but that IP is not actually reachable.

**Fix**: **domain rules must come before `GEOIP,CN`**:

```yaml
- GEOSITE,google,🚀 代理
- GEOSITE,youtube,🚀 代理
- DOMAIN-SUFFIX,<your target domain>,🚀 代理
- GEOSITE,cn,DIRECT
- GEOIP,CN,DIRECT
- MATCH,🚀 代理
```

**Why this is enough**: fake-ip lets mihomo know the domain. After a domain rule
matches, the **domain** is handed to the node, which resolves it itself — the
egress IP is then correct.

---

## 20. `tcp-concurrent`: a "root cause" that our own A/B test disproved

**Background**: while debugging "app shows a blank screen but the browser works",
we once blamed `tcp-concurrent: true`, because turning it off made one load test
drop from 3–9 seconds to 1 second.

**Later A/B (runtime toggle, alternating rounds)**:

| Concurrency | `true` | `false` |
|---|---|---|
| 25 | 25/25, 0.72s | 25/25, 0.73s |
| 60 | 60/60, 0.72s | 60/60, 0.67s |

**No measurable difference.** The earlier degradation was **transient congestion**
on the provider/uplink, not this switch.

**Fix**: keeping `false` is only a conservative choice to "dial a little less";
**do not present it as a causal conclusion**.

**Reusable lessons**:

1. A single A/B run is not enough to establish causation; networks change over time, so alternate multiple rounds.
2. Quantify the link first: measure Wi-Fi bandwidth (`nc` stream) and WAN bandwidth separately.
3. Apps are sensitive to "concurrency + timeout"; browsers are not — different symptoms ≠ different links.

---

## 21. Provider relays UDP one way only → QUIC must be blocked

**Symptom**: the YouTube app shows a blank screen for a few seconds, then says
"no network", while the browser plays fine.

**How to tell** (no client needed):

```sh
curl -sS -H "Authorization: Bearer <secret>" http://127.0.0.1:$UI_PORT/connections \
  | tr '{' '\n' | grep '"network":"udp"' \
  | grep -oE '"host":"[^"]*"|"upload":[0-9]+|"download":[0-9]+' | paste - -
```

```
host: api.example.com   upload: 7200   download: 0
host: api.example.com   upload: 4800   download: 0
```

**Upload keeps growing, download stays 0** = packets go out, but the node never
sends anything back.

**Cause**:

- VLESS + XTLS Vision does not support UDP itself
- or the provider does not enable UDP relay (even if the node says `udp: true`)

**Fix**: block QUIC so clients fall back to TCP:

```nft
iifname "${AP_IF}" udp dport ${QUIC_PORT} counter reject
```

Use `reject` (ICMP port unreachable) rather than `drop`; clients learn
immediately and fall back faster.

**If your provider's UDP works**: do not block it; delete this rule and enjoy
better QUIC performance.
