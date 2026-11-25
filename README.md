# WiFi Monitor

A native, lightweight macOS app (SwiftUI + CoreWLAN + SQLite) that monitors your Wi‑Fi and network around the clock, stores everything in a local database, and shows it on filterable dashboards. No dependencies, no cloud, no account.

## Build & run

```bash
./build.sh              # builds "build/WiFi Monitor.app"
./build.sh --install    # installs it to /Applications (the only copy kept) and launches it
open "build/WiFi Monitor.app"
```

Requires macOS 14+ and Xcode or the Command Line Tools (`xcode-select --install`).

On first launch, allow:
- **Location**: macOS hides Wi‑Fi names (SSID/BSSID) without it. Your location is never read or stored.
- **Local Network**: needed to discover other devices on your network.
- **Notifications** (optional): alerts for disconnects, outages, weak signal, new or untrusted devices, router restarts, captive portals, IPv6/VPN changes and slow network paths.

Closing the window keeps monitoring running in the **menu bar**. Use Quit there to stop it.

## What it monitors

| Area | Details |
|---|---|
| **Live** | RSSI, noise, SNR, channel/band/width, PHY (Wi‑Fi 4/5/6/7), link rate, Tx power, security, country, BSSID, IP/gateway/DNS, router/internet/DNS latency, jitter, packet loss, live throughput, connection type (Wi‑Fi / Ethernet / VPN), active VPN, captive‑portal status |
| **Overview** | Wi‑Fi and internet uptime, disconnects, roams, signal/latency stats (avg/p95/max), packet loss, total data, speed‑test averages, devices and APs seen |
| **Signal & Latency** | Time series, signal‑quality and latency distributions, time per band/channel/standard, weekday × hour heatmaps, per‑access‑point table |
| **Roaming & RF** | Roam count, roam gaps, ping‑pong roams, signal gain after roaming, **sticky‑client** moments, disconnects per hour by access point, noise floor by channel, **interference hints** (non‑Wi‑Fi noise, microwave patterns, raised noise floor, crowded channels) |
| **Data Usage** | **Monthly data cap** (progress, projection, daily budget, alerts at 50/80/100%), total, downloaded and uploaded data, per hour or day, cumulative, by network/band/AP, Wi‑Fi vs **Ethernet**, time on **VPN**, **per app** (Wi‑Fi and wired), **connections per app** (remote hosts, services, bytes), busiest hour, all‑time total |
| **Router** | Optional. Whole‑network WAN usage (all users), WAN throughput, router CPU/memory/uptime, public IP, **data per user/device**, clients with signal, **mesh view** (which client is on which AP or satellite), router interfaces, **router restart alerts** |
| **Path & Internet** | Scheduled **traceroute** with each hop attributed to Home, ISP or Internet (by ASN and owner), latency added per segment vs its usual value, slow‑path alerts, **IPv6** reachability/latency/DNS vs IPv4, **public IP and ISP history**, **captive‑portal** detection, VPN and connection type |
| **Watch Targets** | Your own status page: ping, TCP port, HTTP(S) and TLS certificate checks with uptime %, p95 latency, history charts and up/down alerts |
| **Nearby Networks** | Live scan or everything seen in a range, channel maps, best‑channel suggestion, security/width breakdown |
| **LAN Devices** | Every device on your network (ARP + ICMP sweep) with **vendor** (bundled OUI database), **Bonjour, NetBIOS and UPnP names**, device type, model, nicknames (double‑click to rename), **groups** (Kids, IoT, Guests or your own), **trusted list** with unknown‑device alerts, **presence timeline** (who was home and when), opt‑in **port scan** with banners, private‑MAC detection, first/last seen |
| **Speed Tests** | Apple `networkQuality`: download, upload, responsiveness (RPM), base RTT, **bufferbloat grade** (A+ to F, latency added under load). Results open in a popup and are compared with your history. Can run on a schedule, plus **busy‑hour bufferbloat tests** at hours you pick |
| **Events & Outages** | Connects/disconnects, roams, channel/IP changes, internet down/up with durations, low signal, high latency, new and untrusted devices, router restarts, public IP/ISP changes, captive portals, IPv6 down/up, VPN up/down, connection‑type changes, sticky client, slow path |

The **filter bar** (time range presets or a custom range, network, access point, band) applies to every historical dashboard.

## Router integration

Open **Router** in the sidebar and choose a method:

| Method | Login | Gives you |
|---|---|---|
| UPnP IGD | none | WAN total for the whole network, link speed, uptime, public IP (many ISP routers return empty counters) |
| SNMP v2c | community | All interface counters, CPU, uptime |
| OpenWrt / GL.iNet | user + password | WAN totals, CPU/memory, DHCP names, **per‑client signal and data** (all hosts, wired included, when `nlbwmon` is installed) |
| MikroTik RouterOS 7 | user + password | Same as OpenWrt, via the REST API |
| ASUS (AsusWRT / Merlin) | user + password | WAN totals, CPU/memory, uptime, clients with signal |
| AVM FRITZ!Box | user + password | 64‑bit WAN counters, link speed, public IP, model/uptime, host list (TR‑064) |
| Ubiquiti UniFi | local admin | WAN totals, gateway CPU/memory, **per‑client signal and data** |
| OPNsense | API key + secret | Interface counters, memory, ARP client list |
| TP‑Link Omada | OpenAPI client ID + secret | Every client with signal, traffic and **which AP it's on**, gateway CPU/memory/uptime |
| Netgear / Orbi | admin password | Attached devices with signal and, on Orbi, which satellite each one uses (Genie SOAP API) |
| pfSense | user + password or API key | Interface counters, CPU/memory/uptime, ARP client list (needs the [REST API package](https://github.com/pfrest/pfSense-pkg-RESTAPI); or use SNMP) |

**Google/Nest Wifi, eero and TP‑Link Deco** have no local admin API (their apps go through the vendor cloud). Use **UPnP** for them.

The ASUS, FRITZ!Box, UniFi, OPNsense, Omada, Netgear and pfSense drivers follow those vendors' documented APIs but haven't been tested against real hardware yet. Use **Save & test connection** to check yours.

Passwords are stored in the **macOS Keychain**, not in the database.

## Data

- Database: `~/Library/Application Support/WiFiMonitor/wifi.sqlite` (WAL mode), with retention set in Settings (default 90 days)
- Tables: `samples`, `scans`, `events`, `speedtests`, `devices`, `device_sessions`, `app_usage`, `app_connections`, `router_stats`, `router_clients`, `router_client_usage`, `targets`, `target_results`, `traces`, `trace_hops`, `ipv6_samples`, `net_identity`
- Per‑app connection snapshots are kept for 14 days at most; everything else follows the retention setting.
- Export any table to CSV (using the current filter), back up with `VACUUM INTO`, or query it directly with `sqlite3`.

## Light on resources

- Pings run over an in‑process ICMP socket, so no `ping` processes are spawned. LAN discovery uses one socket for the whole subnet.
- DNS timing is a single raw UDP query. Interface byte counters come from `sysctl`.
- Subprocesses (`route`, `arp`, `nettop`, `traceroute`, `ping6`, `dig`, `networkQuality`) run only every 1–15 minutes or when you ask.
- Scrolling stays at full frame rate: cards use a translucent fill instead of live blur, shadows are drawn on the card shape only, and the background is rasterised once.
- Dashboards query SQLite only for the page you have open, using bucketed aggregates.
- Measured: about 1% CPU with the dashboard open, near idle in the menu bar. Every interval can be changed in Settings.

## Privacy

Everything stays on your Mac, with two optional exceptions (both can be turned off in **Settings → Path, IPv6 & identity**):
- **Public IP** is read with a DNS query to OpenDNS (`myip.opendns.com`), and captive portals are detected with Apple's `captive.apple.com` check.
- **ISP / network owner names** come from DNS TXT lookups to Team Cymru's IP‑to‑ASN service, which sends your public IP and the public router addresses along the traceroute path.

## Troubleshooting

```bash
"build/WiFi Monitor.app/Contents/MacOS/WiFiMonitor" --selftest
```
This prints what each collector sees: Wi‑Fi, gateway, ICMP, DNS, counters, sweep, ARP, nettop, link/VPN, public IP/ISP, IPv6, traceroute with segments, per‑app connections, a port scan of the gateway, and UPnP.

> **Note on rebuilding:** the app is ad‑hoc signed, so macOS treats every rebuild as a new app and asks for Location and Local Network permission again. Install once with `--install` and the grants stick.

## Layout

```
Sources/WiFiMonitor/
  App.swift            app, windows, navigation, --selftest
  Monitor.swift        engine: loops, event detection, persistence
  Database.swift       SQLite wrapper and schema
  Queries.swift        filters and every dashboard query
  WiFiCollector.swift  CoreWLAN and Location permission
  ICMP.swift           in-process ping and subnet sweep
  Util.swift           shell, formatting, net info, DNS probe, nettop, networkQuality
  MonitorExtras.swift  traceroute, IPv6, public IP / captive portal, link + VPN, presence, trust, sticky client, connections
  Diagnostics.swift    traceroute + ASN attribution, IPv6 probe, captive portal, VPN detection, port scanner, nettop parser
  Analysis.swift       roaming, interference, presence, path, IPv6, connection and bufferbloat queries
  Router.swift         UPnP / SNMP / OpenWrt / MikroTik / ASUS / FRITZ!Box / UniFi / OPNsense, Keychain
  RouterDrivers2.swift TP-Link Omada / Netgear (Orbi) / pfSense
  Discovery.swift      OUI vendor lookup, mDNS / NetBIOS / SSDP device names
  Targets.swift        watch-target checks (ICMP, TCP, HTTP, TLS) and the data-cap engine
  Views/               dashboards, filter bar, components, popup, menu bar
scripts/make_icon.swift  generates Resources/AppIcon.icns
Resources/oui.tsv        MAC vendor database (from Wireshark's manuf list)
```
