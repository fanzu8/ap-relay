# Porting to another Linux system

**English** | [中文](porting_zh.md)

## Three checks first

### 1. Can the card run AP mode (and can it do AP+STA concurrently)?

```sh
iw list | sed -n '/valid interface combinations/,$p' | head -20
```

You want to see something like:

```
#{ managed } <= 2, #{ AP, P2P-client } <= 2, #{ P2P-device } <= 1, total <= 4
```

- `AP` present and `managed` + `AP` can coexist → single-card setup is viable
- Only `AP`, or `total <= 1` → single-card is not enough; use a second card or Ethernet uplink

### 2. Is TUN available?

```sh
ls -l /dev/net/tun
# or
zcat /proc/config.gz 2>/dev/null | grep CONFIG_TUN
```

### 3. Who owns the firewall?

```sh
command -v firewall-cmd ufw nft iptables
systemctl is-active firewalld ufw nftables
```

| Distro | Typical setup | How to integrate |
|---|---|---|
| Alpine / postmarketOS | `nftables` + `/etc/nftables.d/*.nft` | Drop in the rendered `51_hotspot.nft` |
| Debian / Ubuntu | `ufw` or plain `nftables` | Use `ufw route allow` / include it in `/etc/nftables.conf`; **do not** fight ufw over `inet filter` |
| RHEL / Fedora | `firewalld` | `firewall-cmd --add-masquerade --add-forward`; do not use the nft template |
| Arch | plain `nftables` or iptables | Pick one and stay consistent |

## Variables to change

Everything is centralized in `/etc/ap-relay.conf` (template:
`templates/ap-relay.conf`):

| Variable | Meaning |
|---|---|
| `STA_IF` | Uplink interface (usually `wlan0` or `wlp2s0` for Wi-Fi) |
| `UPLINK_IF` | NAT egress interface; set to `eth0` for a wired uplink |
| `AP_IF` | Hotspot interface name (your choice; created at runtime) |
| `AP_IP` / `AP_CIDR` / `AP_NET` | Hotspot subnet |
| `DHCP_START` / `DHCP_END` | DHCP pool |
| `TUN_DEV` | Must match mihomo's `tun.device` |
| `TABLE_ID` / `RULE_PREF` | Policy-routing table and priority |
| `GLOBAL_PORT` | mihomo mixed proxy port; must match `mixed-port` |
| `UI_PORT` | Dashboard + REST API; must match `external-controller` |
| `DNS_PORT` | Must match mihomo's `dns.listen` |
| `DNS_STD_PORT` / `DHCP_PORT` | Standard DNS/DHCP ports served by dnsmasq |
| `QUIC_PORT` | QUIC port to block |
| `HTTP_PORT` / `HTTP_ALT_START` / `HTTP_ALT_END` | mihomo sniffer HTTP ports |
| `TLS_PORT` / `TLS_ALT_PORT` | mihomo sniffer TLS/QUIC ports |

The mihomo / nft template placeholders no longer need to be edited by hand.
Render them with `ap-render.sh`:

```sh
sudo ap-render.sh templates/mihomo.config.yaml /etc/mihomo/config.yaml
sudo ap-render.sh templates/51_hotspot.nft     /etc/nftables.d/51_hotspot.nft
```

The `${GLOBAL_PORT}`, `${UI_PORT}`, `${DNS_PORT}`, `${DNS_STD_PORT}`,
`${DHCP_PORT}`, `${QUIC_PORT}`, `${AP_IF}`, `${TUN_DEV}`, etc. placeholders all
come from `/etc/ap-relay.conf`. Re-render after changing the config; no global
search-and-replace is needed.

## Do interface names change?

| Name | Set by | Stability |
|---|---|---|
| `wlan0` / `wlp2s0` | Kernel + udev (predictable names for PCI devices) | Usually stable; USB cards can reorder |
| `AP_IF` | We create it with `iw ... interface add` | Fully controlled |
| `TUN_DEV` | mihomo config | Fully controlled |

**Risk**: with a second wireless card, `STA_IF` may point at the wrong device.
A more robust approach is to select by driver/phy:

```sh
for p in /sys/class/ieee80211/phy*; do
    drv=$(basename "$(readlink -f "$p/device/driver")")
    echo "$(basename "$p") -> $drv"
done
```

## NetworkManager may claim the interface

If the system uses NM, mark the AP interface as unmanaged:

```ini
# /etc/NetworkManager/conf.d/99-ap-relay.conf
[keyfile]
unmanaged-devices=interface-name:<AP_IF>
```

Or use NM's own AP mode (`nmcli con add type wifi mode ap`) and skip hostapd.

## Wired uplink (most stable)

1. `UPLINK_IF=eth0`
2. `STA_IF` can be empty or point at any existing interface (`ap-prep.sh` waits
   for it; setting it to `eth0` is fine)
3. Everything else stays the same

This avoids AP+STA concurrency entirely and gives the best throughput and
stability.

> Note: the AP interface is still created from the wireless phy. If you use a
> separate USB AP card together with a wired uplink, make sure `AP_IF` is the
> interface name that card already has, or adjust `ap-prep.sh` to create the AP
> interface from the right phy.

## Distro package names

| Component | Alpine | Debian/Ubuntu | Arch |
|---|---|---|---|
| hostapd | `hostapd` | `hostapd` | `hostapd` |
| dnsmasq | `dnsmasq` | `dnsmasq` | `dnsmasq` |
| nftables | `nftables` | `nftables` | `nftables` |
| iptables (optional fallback) | `iptables` | `iptables` | `iptables` |
| iw / iproute2 | `iw iproute2` | `iw iproute2` | `iw iproute2` |
| mihomo | official static binary | official static binary | AUR / official binary |

## Checklist

- [ ] `iw list` shows AP and managed can coexist (or use two cards / wired uplink)
- [ ] `/dev/net/tun` exists
- [ ] `ip rule` / `ip route` work (iproute2)
- [ ] Firewall approach chosen and it does not conflict with the template
- [ ] Interface names and subnet in `/etc/ap-relay.conf` match reality
- [ ] mihomo `tun.device` / `dns.listen` match the config
- [ ] nft / mihomo templates rendered with `ap-render.sh`
- [ ] Dashboard secret changed
- [ ] `ap-diag.sh` reports no failures

## Known unsuitable cases

- Wireless drivers that do not support AP mode (some Broadcom / old Realtek)
- A single card without AP+STA concurrency and no second interface
- Systems without systemd, unless you write service scripts yourself (only
  systemd units are provided)
