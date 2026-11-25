# TODO: what else could be integrated

Grouped by value. ✅ = done (these were the ⭐ highest-impact items).

## Router and whole-network
- ✅ **More router drivers**: ASUS, FRITZ!Box (TR‑064), UniFi, OPNsense, TP‑Link Omada (OpenAPI), Netgear/Orbi (SOAP), pfSense (REST API package). Google/Nest Wifi, eero and Deco have no local API — use UPnP.
- ✅ **Per-device bandwidth on OpenWrt** via `nlbwmon` (used automatically when it's installed; covers wired clients).
- **Airtel / JioFiber / ISP ONT scraping** (needs a HAR capture of the router's admin login to build): login and parse their web admin for connected-client lists and WAN counters.
- ✅ **Router reboot / uptime alerts**: alert when the uptime counter resets.
- ✅ **Mesh view**: map which client is attached to which mesh node or AP.

## Devices
- ✅ **Vendor lookup** from a bundled database of 40k IEEE OUI prefixes, with private (randomised) MAC detection.
- ✅ **Bonjour / mDNS + SSDP + NetBIOS names**, device type from Bonjour services, UPnP model names, and nicknames (double‑click a device).
- ✅ **Device tags/groups** set by the user (Kids, IoT, Guests). Nicknames are done.
- ✅ **Presence timeline**: who was home and when, from device online/offline history.
- ✅ **Unknown-device alerts** with an allow-list ("trusted devices").
- ✅ **Port/service scan** of a device on demand (open ports, banners), opt-in.

## Monitoring depth
- ✅ **Watch Targets**: ping, TCP port, HTTP(S) and TLS certificate expiry, with uptime, p95, latency history and up/down alerts.
- ✅ **Traceroute / path monitoring**: record hop latency and spot where slowdowns happen (Wi‑Fi, ISP or upstream).
- ✅ **IPv6 monitoring**: separate v6 latency and reachability, DNS over v6.
- ✅ **Captive portal detection** and public-IP/ISP change history (ASN lookup).
- ✅ **Bufferbloat test** using `networkQuality` RPM under load, scheduled at busy hours.
- ✅ **Roaming analysis**: roam latency, sticky-client detection, per-AP disconnect rates.
- ✅ **Interference hints**: non-Wi‑Fi interference inferred from noise-floor spikes.
- ✅ **Ethernet / VPN awareness**: track wired and `utun` interfaces as well, and tag samples with the active VPN.
- ✅ **Per-app usage including non-Wi‑Fi** and per-app connection lists (remote hosts per process).

## Alerts and reporting
- ✅ **Data caps**: monthly cap for this Mac or the whole network, a reset day, projection, daily budget, and alerts at 50%, 80% and 100%.
- **Daily / weekly summary report** (PDF or HTML) with uptime, worst hours, data used and speed trends.
- **Webhooks / Slack / Telegram / email alerts** for outages.
- **ISP SLA report**: provable downtime and speed shortfalls for complaints, with exportable evidence.
- **Threshold rules editor**, for example "notify if loss > 5% for 2 min on network X".

## App and UX
- **WidgetKit widgets** (signal, latency, data today) for the desktop or Notification Center.
- **Menu bar text mode**: show live RSSI or latency next to the icon.
- **Comparisons**: this week vs last week, or network A vs B, side by side.
- **Floor-plan heatmap**: walk around, tag locations and plot signal per room.
- **Dark/light themed PDF export** of any dashboard.
- **Keyboard shortcuts** (⌘1…⌘9 for pages, ⌘R refresh, ⌘T speed test).
- **Proper code signing + notarization** so permissions persist across updates, and a Sparkle auto-updater.

## Data
- **Downsampling / rollups**: keep raw 5 s samples for 7 days, then roll up to 1‑minute and 1‑hour tables to keep the DB tiny for years.
- **Prometheus `/metrics` endpoint or InfluxDB push** to plug into Grafana.
- **Multi-Mac sync**: merge databases from several Macs to see the whole house.
- **Local HTTP dashboard** to view the stats from a phone on the same network.
