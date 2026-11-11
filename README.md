<p align="center">
  <img src="assets/icon.svg" width="88" height="88" alt="ap-relay icon">
</p>

# ap-relay

[![License: General Pleasure League 1.0](https://img.shields.io/badge/license-General%20Pleasure%20League%201.0-blue.svg)](https://github.com/fanzu8/General-Pleasure-League)
[![Platform: Linux](https://img.shields.io/badge/platform-Linux-informational.svg)](#hardware-requirements)
[![Shell: POSIX sh](https://img.shields.io/badge/shell-POSIX%20sh-4EAA25.svg)](#layout)
[![Version: v0.2.0](https://img.shields.io/badge/version-v0.2.0-blue.svg)](#status)
[![Docs: English | 中文](https://img.shields.io/badge/docs-English%20%7C%20%E4%B8%AD%E6%96%87-success.svg)](README_zh.md)
[![GitHub: fanzu8/ap-relay](https://img.shields.io/badge/GitHub-fanzu8%2Fap--relay-181717.svg?logo=github)](https://github.com/fanzu8/ap-relay)

**English** | [中文](README_zh.md)

Turn any Linux box into a **Wi-Fi relay with a transparent proxy**.

**Connect to the hotspot and the proxy just works — no client apps, no client settings. (Hand it to an AI and the relay config is usually done quickly.)**

This project is a set of **field-tested scripts, configuration templates, and
pitfall notes**. It does not ship any third-party binaries or node
subscriptions. The reference platform is a OnePlus 6 (postmarketOS 25.12 /
ath10k), but **a phone is only one possible host**.

---

## What it solves

```
[client] --Wi-Fi--> [host: AP] --policy routing--> [mihomo TUN] --proxy--> [uplink] --> Internet
```

In one sentence: **zero client configuration**. Join the hotspot and both the
proxy and DNS work automatically.

Specifically:

- Clients install **no software** (no Clash / v2rayNG / etc.).
- Clients change **no settings** (no system proxy, no DNS override).
- One device provides **both** the AP and the uplink (Wi-Fi STA or Ethernet).
- TCP and DNS are fully covered; UDP depends on your upstream provider (see pitfall 21).
- **The host's own traffic bypasses the proxy** (policy routing matches only
  `iif <AP interface>`), so a broken proxy does not kill SSH.

Scope:

- This is a **transparent proxy**, not a VPN: end-to-end HTTPS encryption still
  happens between the client and the destination.
- "Zero configuration" refers to clients. The server still needs dependencies
  and configuration.

## Hardware requirements

There are only two real requirements: **an interface that can run AP mode** and
**an uplink interface**. They can be the same card or two different cards.

| Setup | Usable | Notes |
|---|---|---|
| One card with **concurrent AP+STA** | ✅ | The reference platform; same radio is time-shared, so throughput/latency suffer |
| **Two cards** (built-in STA + USB AP) | ✅ Better | Radios do not contend |
| **Ethernet uplink + one AP card** | ✅ Most stable | Set `UPLINK_IF=eth0`; no concurrency involved |
| One card without AP+STA concurrency | ❌ | Hard limit; change hardware |

See [docs/porting.md](docs/porting.md) for how to check.

## Dependencies (not bundled)

| Component | Role | Notes |
|---|---|---|
| [mihomo](https://github.com/MetaCubeX/mihomo) | Proxy core + TUN + rules | Official static binary, GPL-3.0 |
| hostapd | Runs the hotspot | Distro package |
| dnsmasq | DHCP + DNS forwarding | Distro package |
| nftables or iptables | NAT + filtering | Scripts prefer nft and fall back to iptables |
| iproute2 / iw | Routing and wireless management | Distro packages |

The dashboard (zashboard / metacubexd) is optional static content and is also
not bundled.

## Layout

```
ap-relay/
├── scripts/            # AP scripts + mihomo config/capability/render/verify/apply layers
├── templates/          # config templates (global vars / hotspot / mihomo / nft / systemd)
├── platforms/
│   └── padavan/        # MI-R3G router runtime scripts, hooks and variables (former mihomo-padavan)
├── docs/
│   ├── architecture.md # data flow and layering
│   ├── architecture_zh.md
│   ├── pitfalls.md     # 21 real pitfalls (the core value of this project)
│   ├── pitfalls_zh.md
│   ├── pitfalls_padavan_zh.md   # Padavan-specific pitfalls
│   ├── troubleshooting.md
│   ├── troubleshooting_zh.md
│   ├── porting.md      # what to change on another machine/distro
│   └── porting_zh.md
└── examples/
    ├── README.md       # complete from-zero walkthrough
    └── README_zh.md
```

The phone and the router share one `templates/mihomo.config.yaml` and one set of
`scripts/mihomo-*.sh`; platform differences live only in the variable files
(phone `/etc/ap-relay.conf`, router `/etc/storage/mihomo.conf`).

The shared scripts are layered so each file has exactly one job:

| Layer | Files | Responsibility |
|---|---|---|
| Config | `mihomo-vars.sh` | Load platform/private variables, apply defaults. Data only, no logic. |
| Capability | `mihomo-lib.sh` | Locate config/binary, read `secret`, restart, wait for ports, call the REST API. |
| Pure transforms | `mihomo-render.sh`, `mihomo-verify.sh` | Template → config, and config → pass/fail. No writes to live config. |
| Orchestration | `mihomo-apply.sh`, `mihomo-reload.sh`, `mihomo-refresh.sh` | Compose the layers; the only files that touch a running instance. |

Padavan adds one platform layer, `platforms/padavan/scripts/mihomo-env.sh`
(paths, ports, PID/log locations, iptables chain names), so its runtime scripts
do not each repeat those constants.

## Quick start (overview)

1. Install dependencies (mihomo / hostapd / dnsmasq / nftables).
2. Copy `scripts/*.sh` to `/usr/local/bin` and `templates/ap-relay.conf` to `/etc/`.
3. Edit `/etc/ap-relay.conf` and `/etc/ap-hotspot.conf` for your environment.
4. Put `SECRET` and `SUB_URL` in `/etc/ap-relay.local.conf` (mode 600).
5. Preview with `mihomo-apply.sh --dry-run`, then apply with `mihomo-apply.sh`.
6. `systemctl enable --now ap-hostapd ap-dnsmasq ap-mihomo ap-firewall`.

See **[examples/README.md](examples/README.md)** for the complete walkthrough and
verification commands.

> Ports are centralized in `/etc/ap-relay.conf`: `GLOBAL_PORT`, `UI_PORT`,
> `DNS_PORT`, `DNS_STD_PORT`, `DHCP_PORT`, `QUIC_PORT`, plus the sniffer ports
> `HTTP_PORT` / `HTTP_ALT_START` / `HTTP_ALT_END` / `TLS_PORT` / `TLS_ALT_PORT`.
> Defaults are the validated set: `1008` (mixed), `7070` (controller), `1053`
> (mihomo DNS, avoiding the upstream's possible 53 hijack). The mihomo config is
> rendered by `mihomo-render.sh` from `templates/mihomo.config.yaml`; it rejects
> undefined placeholders and forces mode 600.

## Subscription and geo auto-update

- `proxy-providers` uses `type: http`: the mihomo core downloads the
  subscription itself every `SUB_INTERVAL` (default 6h) — no cron, no external
  update script.
- `GEO_AUTO_UPDATE=true` / `GEO_UPDATE_INTERVAL=2160` (90 days) keeps geo data
  fresh. At least one geo file (e.g. `geoip.metadb`) must already exist in the
  data dir, otherwise the updater is never registered.
- `SUB_URL` and `SECRET` live only on the device: phone
  `/etc/ap-relay.local.conf`, router `/etc/storage/mihomo.local.conf` (mode 600).
  The repo, templates and platform variable files contain no real values.
- Refresh now: `mihomo-refresh.sh`; rules/groups only: `mihomo-reload.sh`;
  variable or startup-only changes: `mihomo-apply.sh` (restarts and waits for ports).

## Design notes

1. **Only forwarded traffic entering the AP interface is captured**:
   `ip rule iif <AP> lookup $TABLE_ID` → `default dev <TUN>`.
   The host's own traffic has a different `iif`, so it bypasses the proxy.
2. **fake-ip + domain rules first**: `GEOSITE,google` must come before
   `GEOIP,CN`; otherwise Google domains resolve to domestic CDN IPs and are
   classified as direct (see pitfall 19).
3. **Whether to block QUIC depends on your provider**: block it if the provider
   cannot relay UDP (pitfall 21); leave it alone if UDP works.

## Idempotency

All scripts can be **run repeatedly**. They do not stack rules, create duplicate
interfaces, or fail just because something already exists:

| Script | Idempotency mechanism |
|---|---|
| `ap-prep.sh` | Skips interface creation if it exists; uses `ip addr replace` instead of `add` |
| `ap-gen.sh` | Fully re-renders every time; writes a temp file and `mv`s it atomically so hostapd never reads a partial config |
| `ap-render.sh` | Fully re-renders every time; writes a temp file and `mv`s it atomically |
| `ap-fw.sh` | nft path rebuilds the dedicated `inet ap_relay` table; iptables path deletes rules tagged `comment "ap-relay"` before adding |
| `ap-tun-route.sh` | Deletes `ip rule` / `ip route` before adding; the delete loop also clears historical duplicates |
| `ap-tun-unroute.sh` | Delete loop; missing rules are not an error |
| `ap-mode.sh` | Changes only the `BAND` line; polls every 0.2s instead of a fixed `sleep` |

Consistency constraints (subnet, TUN name, DNS port) are documented at the top of
`templates/ap-relay.conf`.

## Known limitations

- Single-radio AP+STA shares airtime; throughput and latency suffer.
- UDP/QUIC availability depends entirely on your provider; this project cannot
  fix the upstream.
- The initial release only provides **systemd** units; OpenRC / runit users must
  write their own.
- You must change the dashboard `secret` and the hotspot password; templates
  contain placeholders.
- Battery health for always-on devices is out of scope; see the companion
  project below.

## Companion: always-on operation

Using a device as a permanent hotspot means keeping it plugged in. Battery and
power management are out of scope for this project. Consider
**[chargecap](https://github.com/fanzu8/chargecap)**:

- **Charge limit**: cap at 45–50% to avoid swelling from constant full charge.
- **Temperature / power notifications**: alert on overheating, power loss, or full charge.
- **Inhibit sleep**: keep the network alive so the hotspot does not disappear.

> chargecap supports postmarketOS (mainline kernel) and Android 7+.
> For a phone used as an always-on hotspot, these three features are close to
> essential.

## Documentation

| Document | Contents |
|---|---|
| [docs/architecture.md](docs/architecture.md) | Data flow, service dependencies, ports and addresses |
| [docs/pitfalls.md](docs/pitfalls.md) | 21 real pitfalls and how to verify them |
| [docs/pitfalls_padavan_zh.md](docs/pitfalls_padavan_zh.md) | Padavan / MI-R3G pitfalls (Chinese) |
| [docs/troubleshooting.md](docs/troubleshooting.md) | Symptom → command → interpretation |
| [docs/porting.md](docs/porting.md) | What to change on another machine/distro |

> Chinese versions use the `_zh.md` suffix (for example `README_zh.md`,
> `docs/pitfalls_zh.md`, `examples/README_zh.md`).

## Status

`v0.2.0` — validated on two platforms: OnePlus 6 (postmarketOS 25.12 / ath10k)
and MI-R3G (Padavan), which share the same template and scripts. The tooling is
layered (config → capability → transform → orchestration), each script doing
one job, and the router rotates its log on its own so it cannot grow unbounded.
Feedback for other hardware/distros is welcome, but **out-of-the-box operation
is not guaranteed**.

## Disclaimer

This project involves network proxying and traffic forwarding. Follow the laws
and regulations of your jurisdiction. The repository contains no subscription
links, nodes, keys, or third-party binaries.

## License

[General Pleasure League (GPL) 1.0](https://github.com/fanzu8/General-Pleasure-League)
