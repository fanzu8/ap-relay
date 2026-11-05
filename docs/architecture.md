# Architecture

**English** | [中文](architecture_zh.md)

## Data flow

```
┌──────────────────── clients (phone/laptop, zero config) ────────────────────┐
│ DHCP: IP <AP_NET>.x / gateway AP_IP / DNS AP_IP                             │
└───────────────────────────────┬─────────────────────────────────────────────┘
                                │ Wi-Fi (AP interface)
                     ┌──────────▼──────────┐
                     │ hostapd             │  SSID / band / encryption
                     │ ap-hostapd.service  │
                     └──────────┬──────────┘
        ┌───────────────────────┴────────────────────────┐
        │ DNS $DNS_STD_PORT                              │  all other traffic
┌───────▼──────────────┐                        ┌─────────▼──────────────────┐
│ dnsmasq              │                        │ ip rule iif <AP>           │
│ ap-dnsmasq           │                        │ → table $TABLE_ID          │
│ forwards to          │                        │ → default dev <TUN>        │
│ 127.0.0.1:$DNS_PORT  │                        └─────────┬──────────────────┘
└───────┬──────────────┘                                  │
        │              ┌─────────────────────────────────▼──────────────┐
        └─────────────►│ mihomo TUN (stack: mixed)                      │
                       │ fake-ip 198.18.0.0/16                          │
                       │ restore domain → GEOSITE / GEOIP split         │
                       └─────────────────────┬──────────────────────────┘
                                             │ proxy / DIRECT
                       ┌─────────────────────▼──────────────────────────┐
                       │ ap-fw.sh: ip_forward + NAT                     │
                       └─────────────────────┬──────────────────────────┘
                                             │
                                  uplink interface (STA or eth0)
                                             ▼
                                          Internet
```

## Services

| Service | Responsibility | Start order |
|---|---|---|
| `ap-hostapd` | `ExecStartPre` creates the AP interface and renders the config, then starts hostapd | First (`After=network.target`) |
| `ap-dnsmasq` | DHCP + forwards DNS to mihomo | `After=ap-hostapd` |
| `ap-mihomo` | TUN + rule-based routing; `ExecStartPost` adds policy routing, `ExecStopPost` removes it | `After=ap-hostapd`, `Before=ap-firewall` |
| `ap-firewall` | `ip_forward` + NAT + allows AP input (oneshot) | Last (`After=ap-hostapd, nftables`) |

## Scripts

| Script | Called by | Purpose |
|---|---|---|
| `lib.sh` | sourced by other scripts | Reads `/etc/ap-relay.conf`, provides defaults |
| `ap-prep.sh` | hostapd `ExecStartPre` | Waits for uplink → creates AP interface → assigns IP (idempotent) |
| `ap-gen.sh` | hostapd `ExecStartPre` | Renders `hostapd.conf` from `ap-hotspot.conf` |
| `ap-render.sh` | manual | Renders `${...}` placeholders in templates from `/etc/ap-relay.conf` |
| `ap-mode.sh` | manual | Switches `24g` / `5g`, polling until the AP is really up |
| `ap-fw.sh` | `ap-firewall` | Enables forwarding + NAT + AP input (nft first, iptables fallback) |
| `ap-tun-route.sh` | mihomo `ExecStartPost` | Adds `ip rule` / table `$TABLE_ID` / `rp_filter=0` / TUN input allow |
| `ap-tun-unroute.sh` | mihomo `ExecStopPost` | Removes the rules (traffic falls back to kernel forwarding) |
| `ap-diag.sh` | manual | One-shot health check |
| `ap-debug.sh` | manual | Switches mihomo log level |

## Addresses and ports

| Interface | Address | Notes |
|---|---|---|
| AP | `AP_IP/24` (default `192.168.43.1`) | Gateway + DNS |
| TUN | `198.18.0.1/30` (created by mihomo) | Not configurable; derived from the fake-ip range |
| Uplink | from DHCP | STA or Ethernet |

> Port variables come from `/etc/ap-relay.conf`; defaults are shown in parentheses.
> Both dnsmasq and mihomo use `53` by default, but bind different addresses
> (the AP interface vs `127.0.0.1`), so they do not conflict.

| Port | Purpose |
|---|---|
| `$DNS_STD_PORT`/udp+tcp | dnsmasq (bound to the AP interface only; default 53) |
| `$DHCP_PORT`/udp | dnsmasq DHCP (default 67) |
| `$DNS_PORT` | mihomo fake-ip DNS (listens on 127.0.0.1 only; default 53) |
| `$GLOBAL_PORT` | mihomo mixed (HTTP+SOCKS; default 7890) |
| `$UI_PORT` | Dashboard + REST API (default 9090; set a secret and restrict sources) |

## The three TUN stacks

| Stack | TCP handled by | UDP handled by | Memory | Notes |
|---|---|---|---|---|
| `system` | Kernel (loopback listener `<tun>:random`) | Kernel | Low | Default; depends on the kernel loopback path |
| `gvisor` | gVisor userspace | gVisor | High | Never touches kernel loopback; most predictable |
| `mixed` | Kernel | gVisor | Medium | Recommended: mature kernel TCP stack, userspace UDP |

To see which one is active (no docs needed):

```sh
sudo ss -lntp | grep mihomo | grep 198.18
# output present = TCP uses the kernel stack; no output = pure userspace
```

## Design trade-offs

| Decision | Reason |
|---|---|
| Match only `iif <AP>` | Host traffic never enters the proxy; a broken proxy does not affect SSH/dashboard |
| Manual `ip rule` instead of `auto-route: true` | The latter changes the default route and hijacks the whole host |
| fake-ip + domain rules first | Avoids domestic DNS answers influencing routing decisions |
| QUIC `reject` instead of `drop` | Clients learn immediately and fall back to TCP faster |
| `ap-tun-unroute.sh` on service stop | Graceful degradation: traffic falls back to kernel forwarding + NAT, clients stay online |

## Relationship to OpenWrt router setups

The architecture is the same: `hostapd + dnsmasq + NAT + proxy core + policy
routing`. On OpenWrt this corresponds to Nikki / OpenClash / passwall.

The difference is not the architecture but the platform constraints:

| Dimension | Router | Phone / mobile device |
|---|---|---|
| Uplink | Usually wired WAN | Usually Wi-Fi STA (single radio) |
| AP interface | Exists at boot | Created at runtime with `iw interface add`, gone after reboot |
| Air interface | Separate radios or wired; no contention | Single radio time-shared; throughput and latency suffer |
| Configuration | UCI + LuCI, packaged | Plain files + systemd, assembled by hand |
| Hardware offload | Often NAT / crypto offload | Usually none; everything on the CPU |
| Power and cooling | Always powered | Battery, thermal limits, may suspend |
| Driver reliability | Designed for long-running use | Many firmware quirks (see pitfalls 3 and 15) |
| Rescue path | Serial / Ethernet | USB networking (if supported) |

So the project is not inventing a new scheme. It moves a mature router setup to a
device with no UCI, no packages, and only one radio, and documents the pitfalls.

## Failure modes

| Failure | Result |
|---|---|
| mihomo crashes/restarts | `ExecStopPost` removes policy routing → traffic falls back to kernel forwarding + NAT (direct, no proxy, but still online) |
| hostapd crashes | `Restart=always` retries; `$AP_IF` is recreated by `ap-prep.sh` |
| dnsmasq crashes | Clients cannot get DHCP/DNS; clients with existing leases can still communicate but cannot resolve |
| Dashboard `$UI_PORT` exposed | **Exposed on the AP network by default**; change the secret and restrict sources with the firewall |
