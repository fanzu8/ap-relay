# From zero to working

**English** | [中文](README_zh.md)

Using Alpine / postmarketOS as the example. On other distros, replace the package
manager (see `docs/porting.md`).

> Variables such as `$AP_IF`, `$TUN_DEV`, `$GLOBAL_PORT`, `$UI_PORT`, and
> `$DNS_PORT` below come from `/etc/ap-relay.conf`. In a root shell, run
> `. /etc/ap-relay.conf` first, or replace them with actual values.

## 0. Pre-flight checks

```sh
iw list | grep -A4 'valid interface combinations'   # AP and managed must coexist
ls -l /dev/net/tun
ip -V
```

## 1. Install dependencies

```sh
# Alpine / postmarketOS
sudo apk add hostapd dnsmasq nftables iw iproute2 curl

# Debian / Ubuntu
# sudo apt install hostapd dnsmasq nftables iw iproute2 curl
```

mihomo uses the official static binary (not bundled):

```sh
# arm64 example; replace the version as needed
curl -L -o /tmp/mihomo.gz \
  https://github.com/MetaCubeX/mihomo/releases/download/v1.19.33/mihomo-linux-arm64-v1.19.33.gz
gunzip -f /tmp/mihomo.gz
sudo install -m 755 /tmp/mihomo /usr/local/bin/mihomo
mihomo -v
```

> NAT is handled by `ap-fw.sh`: it uses nft first and falls back to iptables.
> On Alpine / postmarketOS, installing `nftables` is enough; no separate
> iptables package is required.

## 2. Install scripts and config templates

```sh
sudo install -m 755 scripts/*.sh /usr/local/bin/
sudo install -m 644 templates/ap-relay.conf   /etc/ap-relay.conf
sudo install -m 600 templates/ap-hotspot.conf /etc/ap-hotspot.conf
sudo install -m 644 templates/systemd/*.service /etc/systemd/system/
sudo mkdir -p /etc/hostapd
sudo systemctl daemon-reload
```

## 3. Edit the two configs

```sh
sudo vi /etc/ap-relay.conf     # interface names, subnet, TUN name, ports
sudo vi /etc/ap-hotspot.conf   # SSID, password, band, channel
```

At minimum, confirm:

- `STA_IF` is the interface that actually connects upstream
- `AP_IF` does not collide with an existing interface
- `UPLINK_IF` is correct (use `eth0` for a wired uplink)

## 4. Configure mihomo

```sh
sudo mkdir -p /etc/mihomo/providers
# Render the template first: ports/interfaces are substituted from /etc/ap-relay.conf
# Note: this overwrites the output file. Re-render before re-applying custom edits.
sudo ap-render.sh templates/mihomo.config.yaml /etc/mihomo/config.yaml
sudo chmod 600 /etc/mihomo/config.yaml
sudo vi /etc/mihomo/config.yaml      # change secret; adjust provider paths
```

Put the provider file at `/etc/mihomo/providers/provider_a.yaml` (the format is
mihomo's `proxies:` list).

Keep geo data local so startup does not need to download it:

```sh
sudo curl -L -o /etc/mihomo/geoip.metadb \
  https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb
sudo curl -L -o /etc/mihomo/geosite.dat \
  https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat
```

Optional: dashboard (static files only)

```sh
# zashboard example
curl -L -o /tmp/zash.zip https://github.com/Zephyruso/zashboard/releases/download/v3.30.0/dist-no-fonts.zip
sudo mkdir -p /etc/mihomo/ui && sudo unzip -o /tmp/zash.zip -d /tmp/zash
sudo cp -r /tmp/zash/dist/* /etc/mihomo/ui/
```

## 5. Install the firewall rules

```sh
# Render the template: ${AP_IF} / ${TUN_DEV} / port placeholders are substituted
sudo ap-render.sh templates/51_hotspot.nft /etc/nftables.d/51_hotspot.nft
sudo nft -c -f /etc/nftables.d/51_hotspot.nft     # syntax check
sudo systemctl restart nftables
```

> Do not drop this file into the same path on non-Alpine systems; see the
> firewall section in `docs/porting.md`.

## 6. Start

```sh
sudo systemctl enable --now ap-hostapd ap-dnsmasq ap-mihomo ap-firewall
systemctl status ap-hostapd ap-dnsmasq ap-mihomo ap-firewall
```

## 7. Verify

```sh
# services
systemctl is-active ap-hostapd ap-dnsmasq ap-mihomo ap-firewall

# hotspot
iw dev <AP_IF> info | grep -E 'ssid|channel'

# does DNS return fake IPs? (critical)
nslookup www.example.com <AP_IP>        # expect 198.18.x.x

# proxy itself (without going through the hotspot)
curl -x 127.0.0.1:$GLOBAL_PORT -o /dev/null -w '%{http_code}\n' https://www.example.com
# egress IP: visit any "what is my IP" site; it should show the node's location

# one-shot health check
sudo ap-diag.sh
```

Finally, connect a client to the hotspot and open a foreign site in a browser.

## 8. When something goes wrong

Start with:

```sh
sudo ap-diag.sh
journalctl -u ap-mihomo -n 50
journalctl -u ap-hostapd -n 30
```

Then use the "symptom → command → interpretation" table in
`docs/troubleshooting.md`.
