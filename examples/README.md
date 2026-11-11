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
sudo mkdir -p /usr/local/share/ap-relay
sudo install -m 644 templates/mihomo.config.yaml /usr/local/share/ap-relay/
sudo mkdir -p /etc/hostapd
sudo systemctl daemon-reload
```

`mihomo-apply.sh` looks for the template there by default; you can also pass a
path explicitly.

## 3. Edit the configs

```sh
sudo vi /etc/ap-relay.conf     # interface names, subnet, TUN name, ports
sudo vi /etc/ap-hotspot.conf   # SSID, password, band, channel
```

At minimum, confirm:

- `STA_IF` is the interface that actually connects upstream
- `AP_IF` does not collide with an existing interface
- `UPLINK_IF` is correct (use `eth0` for a wired uplink)

Keep credentials in a separate root-only file:

```sh
sudo install -m 600 /dev/null /etc/ap-relay.local.conf
sudo tee /etc/ap-relay.local.conf >/dev/null <<'EOF'
SECRET='CHANGE_ME_DASHBOARD_SECRET'
SUB_URL='https://example.com/link/CHANGE_ME?clash=1'
EOF
```

> Do not put `SECRET` or `SUB_URL` in `/etc/ap-relay.conf`, and never commit
> them to the repository.

## 4. Configure mihomo

```sh
sudo mkdir -p /etc/mihomo/providers
# Preview: render + verify + diff, without touching the live config
sudo mihomo-apply.sh --dry-run

# Apply: render -> verify -> backup -> replace -> restart -> wait for ports
sudo mihomo-apply.sh
```

Notes:

- The provider is `type: http`: on first start mihomo downloads the nodes from
  `SUB_URL` into `path`, so you do not place `providers/*.yaml` by hand.
- `SECRET` / `SUB_URL` come from `/etc/ap-relay.local.conf`; the rendered
  `/etc/mihomo/config.yaml` is forced to mode 600.
- After editing `/etc/ap-relay.conf`, rerun `mihomo-apply.sh`. Do not edit the
  generated file.

Keep geo data local so startup does not need to download it (and so
`geo-auto-update` has a file to register against):

```sh
sudo curl -L -o /etc/mihomo/geoip.metadb \
  https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb
sudo curl -L -o /etc/mihomo/geosite.dat \
  https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat
sudo chown root:root /etc/mihomo/geoip.metadb /etc/mihomo/geosite.dat
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

# subscription: confirm it is an HTTP provider and nodes are downloaded
sudo mihomo-refresh.sh

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
