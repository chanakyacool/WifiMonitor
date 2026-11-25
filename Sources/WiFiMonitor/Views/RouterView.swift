import SwiftUI
import Charts

/// Router integration: setup + router-side stats (whole-network WAN usage, CPU/memory, every client).
struct RouterView: View {
    @EnvironmentObject var m: Monitor
    @AppStorage("routerKind") private var kind = "none"
    @AppStorage("routerHost") private var host = ""
    @AppStorage("routerUser") private var user = ""
    @AppStorage("routerCommunity") private var community = "public"
    @AppStorage("routerWan") private var wan = ""
    @AppStorage("routerHTTPS") private var https = false
    @AppStorage("routerInterval") private var interval = 60.0
    @AppStorage("routerSite") private var site = "default"
    @State private var password = ""
    @State private var testResult: String?
    @State private var testing = false
    @State private var showSetup = false

    @State private var usage = RouterUsage()
    @State private var history: [HistoryPoint] = []
    @State private var buckets: [UsageBucket] = []
    @State private var hourly = true
    @State private var perClient: [UsageGroup] = []
    @State private var clients: [RouterClient] = []
    @AppStorage("uiMode") private var uiMode = "simple"
    private var advanced: Bool { uiMode == "advanced" }

    private var routerKind: RouterKind { RouterKind(rawValue: kind) ?? .none }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionHeader(title: "Router", subtitle: "Connect your router to see whole-network stats — total data for every user, connected clients, router health")
                Button(showSetup || routerKind == .none ? "Hide setup" : "Router setup…") { showSetup.toggle() }
                    .buttonStyle(.appSecondary(.indigo))
                    .opacity(routerKind == .none ? 0 : 1)
            }
            if routerKind == .none || showSetup { setup }

            if routerKind != .none {
                if let e = m.routerError {
                    Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading).glassCard(tint: .orange)
                }
                FilterBar(showNetworkFilters: false)
                stats
            }
        }
        .dashboardPage()
        .onAppear { password = Keychain.load(account: user.isEmpty ? "router" : user) ?? "" }
        .task(id: ReloadKey(filter: m.filter, version: m.dataVersion)) { await load() }
    }

    // MARK: Setup

    private var setup: some View {
        GroupBox {
            Form {
                Picker("Connection method", selection: $kind) {
                    ForEach(RouterKind.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if routerKind != .none {
                    TextField("Router address", text: $host, prompt: Text("auto: \(m.current?.gateway ?? "default gateway")"))
                }
                if routerKind.needsLogin {
                    TextField(routerKind.userLabel, text: $user, prompt: Text(routerKind == .openwrt ? "root" : "admin"))
                    SecureField(routerKind.passwordLabel, text: $password)
                    if [.openwrt, .mikrotik, .asus, .opnsense].contains(routerKind) {
                        Toggle("Use HTTPS (self-signed certificates accepted for this router only)", isOn: $https)
                    }
                    if routerKind == .unifi || routerKind == .omada { TextField("Site", text: $site, prompt: Text(routerKind == .omada ? "first site" : "default")) }
                }
                if routerKind == .snmp {
                    TextField("Community string", text: $community)
                }
                if [.snmp, .mikrotik, .openwrt, .opnsense, .pfsense].contains(routerKind) {
                    TextField(routerKind == .openwrt ? "WAN interface (OpenWrt logical name)" : "WAN interface name",
                              text: $wan, prompt: Text(routerKind == .openwrt ? "wan" : "auto-detect"))
                }
                if routerKind != .none {
                    Picker("Poll every", selection: $interval) {
                        ForEach([30.0, 60, 120, 300], id: \.self) { Text($0 >= 60 ? "\(Int($0 / 60)) min" : "\(Int($0)) s").tag($0) }
                    }
                    HStack {
                        Button(testing ? "Testing…" : "Save & test connection") { save(); test() }.buttonStyle(.app(.indigo)).disabled(testing)
                        if let testResult { Text(testResult).foregroundStyle(testResult.hasPrefix("✓") ? .green : .red) }
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Text(help).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.bottom, 6)
        } label: { Label("Router connection", systemImage: "wifi.router").font(.headline) }
    }

    private var help: String {
        switch routerKind {
        case .none: return "Pick a method. UPnP works on most home and ISP routers with no password (gives whole-network WAN totals). OpenWrt and MikroTik with a login also give per-device usage and Wi-Fi signal for every client."
        case .upnp: return "UPnP IGD reports total WAN bytes for the entire network, link speed, uptime and public IP. Enable “UPnP” in your router's admin page if the test fails. This is also the method to use for Google/Nest Wifi, eero and TP-Link Deco: they have no local admin API (their apps go through the vendor's cloud), but they do answer UPnP."
        case .snmp: return "Enable SNMP v2c on the router (read-only community). Gives all interface counters, CPU and uptime."
        case .openwrt: return "Uses the LuCI ubus API (http://router/ubus). Gives WAN totals, CPU/memory, DHCP names and every Wi-Fi client's signal and traffic."
        case .mikrotik: return "Uses the RouterOS 7 REST API (enable the www or www-ssl service). A read-only user is enough."
        case .asus: return "Uses the same API as the ASUS Router app. Gives WAN totals, CPU/memory, uptime and every connected client with signal."
        case .fritzbox: return "Uses TR-064 on port 49000 with 64-bit counters. Enable “Allow access for applications”. A FRITZ!Box user unlocks model, uptime and the host list."
        case .unifi: return "Works with UniFi OS consoles (UDM, UCG, Cloud Key) and the classic controller on :8443. Use a local admin account (not SSO). Gives WAN totals, gateway CPU/memory and every client's signal and data."
        case .opnsense: return "Create an API key/secret under System → Access → Users. Gives interface counters, memory and the ARP/client list."
        case .omada: return "Address = controller with port (OC200/OC300: its IP; software controller: IP:8043). In the controller open Settings → Platform Integration → Open API, add an app in “Client” mode with site access, and paste its Client ID and Client Secret. Gives every client with signal, traffic and which AP it's on, plus gateway CPU/memory."
        case .zte: return "For Airtel / Jio / BSNL fibre routers made by ZTE (F670L, F680, F6600P…). Use the admin username and password from the router's sticker or your ISP. The password is sent only as a one-time SHA-256 hash, like the router's own login page. Note: these routers allow one admin session, so the app may sign you out of the router's web page while it polls."
        case .netgear: return "Uses the Netgear Genie SOAP API (port 5000 or 80) that Nighthawk and Orbi routers expose. Username is usually “admin”. Gives the attached-device list with signal and, on Orbi, which satellite each device uses."
        case .pfsense: return "pfSense has no built-in API. Install the free REST API package (github.com/pfrest/pfSense-pkg-RESTAPI), then use a user with API access (or leave username empty and paste an API key). Alternatively enable SNMP under Services → SNMP and pick SNMP above."
        }
    }

    private func save() {
        Keychain.save(account: user.isEmpty ? "router" : user, password: password)
    }

    private func test() {
        testing = true
        Task {
            testResult = await m.pollRouter()
            testing = false
            m.dataVersion += 1
        }
    }

    // MARK: Stats

    @ViewBuilder private var stats: some View {
        let r = m.router
        LazyVGrid(columns: kpiColumns, spacing: 12) {
            let measuring = usage.down + usage.up == 0 && r?.wanRx != nil
            KPITile(title: "Whole network · total", value: measuring ? "Measuring…" : Fmt.bytes(usage.down + usage.up),
                    subtitle: measuring ? "first numbers after the next router poll (every \(interval >= 60 ? "\(Int(interval / 60)) min" : "\(Int(interval)) s"))" : "all users, WAN, in range", icon: "sum", color: .pink)
            KPITile(title: "Network downloaded", value: Fmt.bytes(usage.down), subtitle: "peak \(Fmt.bps(usage.peakDownBps))", icon: "arrow.down.circle", color: .green)
            KPITile(title: "Network uploaded", value: Fmt.bytes(usage.up), subtitle: "peak \(Fmt.bps(usage.peakUpBps))", icon: "arrow.up.circle", color: .orange)
            KPITile(title: "WAN now", value: "↓ \(Fmt.bps(m.routerWanRxBps))", subtitle: "↑ \(Fmt.bps(m.routerWanTxBps))", icon: "gauge.medium", color: .blue)
            KPITile(title: "WAN link", value: r?.linkStatus ?? "—", subtitle: r?.linkDown.map { "↓ \(Fmt.bps($0)) ↑ \(Fmt.bps(r?.linkUp))" }, icon: "cable.connector", color: .teal)
            KPITile(title: "Public IP", value: r?.externalIP ?? "—", icon: "globe", color: .indigo)
            KPITile(title: "Router uptime", value: r?.uptime.map { Fmt.duration($0) } ?? "—", icon: "clock", color: .gray)
            KPITile(title: "Router CPU", value: Fmt.pct(r?.cpuLoad, digits: 0), subtitle: "avg \(Fmt.pct(usage.avgCpu, digits: 0)) · max \(Fmt.pct(usage.maxCpu, digits: 0))", icon: "cpu", color: .purple)
            KPITile(title: "Router memory", value: Fmt.pct(r?.memUsed, digits: 0), icon: "memorychip", color: .purple)
            KPITile(title: "Clients", value: r.map { "\($0.clients.count)" } ?? "—", subtitle: r?.model, icon: "person.3", color: .mint)
        }

        LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 16) {
            ChartCard(title: "Whole-network usage", subtitle: hourly ? "per hour" : "per day") { UsageBarChart(buckets: buckets, hourly: hourly) }
            ChartCard(title: "WAN throughput") {
                TimeLineChart(points: history.flatMap { p in
                    [p.rxBps.map { SeriesPoint(date: p.date, value: $0 / 1e6, series: "Download") },
                     p.txBps.map { SeriesPoint(date: p.date, value: $0 / 1e6, series: "Upload") }].compactMap { $0 }
                }, unit: "Mbps", area: true)
            }
            if advanced {
            ChartCard(title: "Router CPU & memory") {
                TimeLineChart(points: history.flatMap { p in
                    [p.up.map { SeriesPoint(date: p.date, value: $0 * 100, series: "CPU") },
                     p.inetUp.map { SeriesPoint(date: p.date, value: $0 * 100, series: "Memory") }].compactMap { $0 }
                }, unit: "%")
            }
            }
            ChartCard(title: "Data per user / device", subtitle: perClient.isEmpty ? "needs OpenWrt or MikroTik" : nil) { RankedBars(groups: perClient) }
        }

        if let r, r.clients.contains(where: { $0.ap != nil }) { MeshView(clients: r.clients, current: m.current) }

        if !perClient.isEmpty {
            GroupBox {
                Table(perClient) {
                    TableColumn("Device") { Text($0.name) }
                    TableColumn("IP") { Text($0.detail ?? "—") }
                    TableColumn("Downloaded") { Text(Fmt.bytes($0.rx)) }
                    TableColumn("Uploaded") { Text(Fmt.bytes($0.tx)) }
                    TableColumn("Total") { Text(Fmt.bytes($0.total)).fontWeight(.medium) }
                    TableColumn("Share") { g in Text(usage.down + usage.up > 0 ? String(format: "%.1f%%", g.total / (usage.down + usage.up) * 100) : "—") }
                }.frame(minHeight: 220)
            } label: { Label("Usage per user / device (in range)", systemImage: "person.3").font(.headline) }
        }

        if let r, !r.clients.isEmpty {
            GroupBox {
                Table(r.clients.sorted { ($0.signal ?? -200) > ($1.signal ?? -200) }) {
                    TableColumn("Name") { Text($0.name ?? "—") }
                    TableColumn("IP") { Text($0.ip ?? "—").font(.system(.body, design: .monospaced)) }
                    TableColumn("MAC") { Text($0.mac).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    TableColumn("Signal") { c in Text(Fmt.dbm(c.signal)).foregroundStyle(SignalQuality(rssi: c.signal).color) }
                    TableColumn("Radio") { Text($0.iface ?? "wired / DHCP") }
                    TableColumn("Access point") { Text($0.ap ?? "—") }
                    TableColumn("Downloaded") { Text($0.txTotal.map { Fmt.bytes(Double($0)) } ?? "—") }
                    TableColumn("Uploaded") { Text($0.rxTotal.map { Fmt.bytes(Double($0)) } ?? "—") }
                    TableColumn("Connected for") { Text($0.connectedSeconds.map { Fmt.duration($0) } ?? "—") }
                }.frame(minHeight: 260)
            } label: { Label("Clients right now (\(r.clients.count))", systemImage: "laptopcomputer.and.iphone").font(.headline) }
        }

        if advanced, let r, !r.interfaces.isEmpty {
            GroupBox {
                Table(r.interfaces) {
                    TableColumn("Interface") { Text($0.name) }
                    TableColumn("Status") { i in Text(i.up == nil ? "—" : (i.up! ? "up" : "down")).foregroundStyle(i.up == false ? .red : .green) }
                    TableColumn("Received (since boot)") { Text(Fmt.bytes(Double($0.rx))) }
                    TableColumn("Sent (since boot)") { Text(Fmt.bytes(Double($0.tx))) }
                }.frame(minHeight: 200)
            } label: { Label("Router interfaces", systemImage: "point.3.connected.trianglepath.dotted").font(.headline) }
        }
    }

    private func load() async {
        guard routerKind != .none else { return }
        let f = m.filter
        let r = await Blocking.run { (Queries.routerUsage(f), Queries.routerHistory(f), Queries.routerUsageBuckets(f), Queries.routerClientUsage(f)) }
        usage = r.0; history = r.1; buckets = r.2.buckets; hourly = r.2.hourly; perClient = r.3
    }
}

/// Mesh / multi-AP view: which client is attached to which access point or satellite.
struct MeshView: View {
    let clients: [RouterClient]
    let current: Sample?

    private var nodes: [(name: String, clients: [RouterClient])] {
        Dictionary(grouping: clients) { $0.ap ?? "Unknown / wired" }
            .map { ($0.key, $0.value.sorted { ($0.signal ?? -200) > ($1.signal ?? -200) }) }
            .sorted { $0.clients.count > $1.clients.count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "Mesh & access points", icon: "point.3.filled.connected.trianglepath.dotted", color: .indigo,
                      subtitle: "\(nodes.count) nodes · \(clients.count) clients")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], alignment: .leading, spacing: 14) {
                ForEach(nodes, id: \.name) { node in
                    let sig = node.clients.compactMap(\.signal)
                    let avg = sig.isEmpty ? nil : sig.reduce(0, +) / sig.count
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            IconBadge(icon: "wifi.router.fill", color: .indigo, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(node.name).font(.headline).lineLimit(1)
                                Text("\(node.clients.count) clients · avg \(Fmt.dbm(avg))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if node.clients.count >= 25 { Chip(text: "busy", icon: "flame.fill", color: .orange) }
                        }
                        Divider().opacity(0.4)
                        ForEach(node.clients.prefix(8)) { c in
                            HStack(spacing: 6) {
                                Circle().fill(SignalQuality(rssi: c.signal).color).frame(width: 7, height: 7)
                                Text(c.name ?? c.ip ?? c.mac).font(.callout).lineLimit(1)
                                if let ip = current?.ip, c.ip == ip { Chip(text: "this Mac", color: .blue) }
                                Spacer()
                                Text(c.signal.map { "\($0) dBm" } ?? (c.iface == "wired" ? "wired" : "—"))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                        if node.clients.count > 8 { Text("+ \(node.clients.count - 8) more").font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.indigo.opacity(0.07)))
                }
            }
        }
        .glassCard(tint: .indigo)
    }
}
