import SwiftUI
import Charts

/// Data consumption: totals, over time, per network / AP / band, and per app.
struct UsageView: View {
    @EnvironmentObject var m: Monitor
    @State private var o = Overview()
    @State private var buckets: [UsageBucket] = []
    @State private var hourly = true
    @State private var byNetwork: [UsageGroup] = []
    @State private var byAP: [APStat] = []
    @State private var byBand: [UsageGroup] = []
    @State private var byApp: [UsageGroup] = []
    @State private var appTotal: Double = 0
    @State private var allTime: (rx: Double, tx: Double, since: Date?) = (0, 0, nil)
    @State private var heat: [HeatCell] = []
    @State private var links = LinkUsage()
    @State private var cycle = DataCap.status()
    @State private var connApps: [String] = []
    @State private var connApp = ""
    @State private var conns: [ConnRow] = []
    @AppStorage("uiMode") private var uiMode = "simple"
    private var advanced: Bool { uiMode == "advanced" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterBar()
            SectionHeader(title: "Data Usage", subtitle: "Wi-Fi and Ethernet traffic from this Mac's interface counters; per-app traffic and connections from nettop")
            DataCapCard()

            LazyVGrid(columns: kpiColumns, spacing: 12) {
                KPITile(title: "Total in range", value: Fmt.bytes(o.rxBytes + o.txBytes), icon: "sum", color: .pink)
                KPITile(title: "Downloaded", value: Fmt.bytes(o.rxBytes), subtitle: share(o.rxBytes), icon: "arrow.down.circle", color: .green)
                KPITile(title: "Uploaded", value: Fmt.bytes(o.txBytes), subtitle: share(o.txBytes), icon: "arrow.up.circle", color: .orange)
                if advanced {
                KPITile(title: "Average rate", value: Fmt.bps(o.span > 0 ? (o.rxBytes + o.txBytes) * 8 / o.span : nil), subtitle: "over monitored time", icon: "gauge.medium", color: .blue)
                KPITile(title: "Peak download", value: Fmt.bps(o.peakRx), icon: "arrow.down.to.line", color: .green)
                KPITile(title: "Peak upload", value: Fmt.bps(o.peakTx), icon: "arrow.up.to.line", color: .orange)
                }
                KPITile(title: "Busiest \(hourly ? "hour" : "day")", value: busiest.map { Fmt.bytes($0.rx + $0.tx) } ?? "—",
                        subtitle: busiest.map { hourly ? Fmt.dateTime.string(from: $0.date) : DateFormatter.localizedString(from: $0.date, dateStyle: .medium, timeStyle: .none) },
                        icon: "flame", color: .red)
                KPITile(title: "This billing cycle", value: Fmt.bytes(cycle.used),
                        subtitle: "since \(Self.dayMonth.string(from: cycle.start)) · \(cycle.daysLeft) days left", icon: "calendar", color: .indigo)
                KPITile(title: "All-time total", value: Fmt.bytes(allTime.rx + allTime.tx),
                        subtitle: allTime.since.map { "since \(DateFormatter.localizedString(from: $0, dateStyle: .medium, timeStyle: .none))" }, icon: "infinity", color: .purple)
                if advanced {
                KPITile(title: "This session", value: Fmt.bytes(Double(m.sessionRx + m.sessionTx)), subtitle: "since app launch", icon: "clock", color: .teal)
                KPITile(title: "Ethernet data", value: Fmt.bytes(links.ethernetBytes), subtitle: "wired / dock / USB adapters", icon: "cable.connector", color: .indigo)
                KPITile(title: "Time on VPN", value: Fmt.duration(links.vpnSeconds), subtitle: links.vpnNames.first?.name, icon: "lock.shield.fill", color: .green)
                }
            }

            ChartCard(title: "Usage over time", subtitle: hourly ? "per hour" : "per day", height: 240) {
                UsageBarChart(buckets: buckets, hourly: hourly)
            }
            if advanced {
            ChartCard(title: "Cumulative usage", height: 200) {
                TimeLineChart(points: cumulative, unit: "GiB", area: true)
            }
            }

            LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 16) {
                if advanced {
                ChartCard(title: "By network (SSID)") { RankedBars(groups: byNetwork) }
                ChartCard(title: "By band") { RankedBars(groups: byBand) }
                ChartCard(title: "By connection type", subtitle: "data", icon: "cable.connector", color: .indigo) {
                    RankedBars(groups: [UsageGroup(name: "Wi-Fi", rx: links.wifiBytes, tx: 0), UsageGroup(name: "Ethernet", rx: links.ethernetBytes, tx: 0)]
                        .filter { $0.rx > 0 })
                }
                ChartCard(title: "Time per connection type", icon: "clock.fill", color: .teal) {
                    RankedBars(groups: links.time + links.vpnNames.map { UsageGroup(name: "VPN: \($0.name)", rx: $0.rx, tx: 0) },
                               value: { $0.rx }, label: { Fmt.duration($0) })
                }
                }
                ChartCard(title: "Top apps & processes", subtitle: "Wi-Fi + Ethernet · \(Fmt.bytes(appTotal)) attributed", height: 320) {
                    RankedBars(groups: byApp, limit: 15)
                }
                ChartCard(title: "When you use data", subtitle: "weekday × hour", height: 320) {
                    HeatmapView(cells: heat, format: { Fmt.bytes($0) })
                }
            }

            if advanced {
            GroupBox {
                Table(byApp) {
                    TableColumn("App / process") { Text($0.name) }
                    TableColumn("Downloaded") { Text(Fmt.bytes($0.rx)) }
                    TableColumn("Uploaded") { Text(Fmt.bytes($0.tx)) }
                    TableColumn("Total") { Text(Fmt.bytes($0.total)).fontWeight(.medium) }
                    TableColumn("Of which wired") { Text($0.detail ?? "—").foregroundStyle(.secondary) }
                    TableColumn("Share") { g in Text(appTotal > 0 ? String(format: "%.1f%%", g.total / appTotal * 100) : "—") }
                }
                .frame(minHeight: 260)
            } label: { Label("Per-app usage (\(byApp.count))", systemImage: "app.badge").font(.headline) }

            GroupBox {
                VStack(alignment: .leading) {
                    HStack {
                        Picker("App", selection: $connApp) {
                            ForEach(connApps, id: \.self) { Text($0).tag($0) }
                        }.frame(width: 320)
                        Text("\(conns.count) remote endpoints · sampled every \(Int(Prefs.connInterval / 60)) min").font(.caption).foregroundStyle(.secondary)
                    }
                    Table(conns) {
                        TableColumn("Remote host") { c in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(c.host ?? c.remote).lineLimit(1)
                                if c.host != nil { Text(c.remote).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                            }
                        }.width(min: 220, ideal: 320)
                        TableColumn("Service") { c in Text("\(c.service) (\(c.proto) \(c.port))") }
                        TableColumn("Received") { Text(Fmt.bytes($0.rx)) }
                        TableColumn("Sent") { Text(Fmt.bytes($0.tx)) }
                        TableColumn("Seen") { Text("\($0.snapshots)×") }.width(50)
                        TableColumn("Last seen") { Text(Fmt.dateTime.string(from: $0.lastSeen)) }
                    }
                    .frame(minHeight: 260)
                }
            } label: { Label("Connections per app", systemImage: "point.3.connected.trianglepath.dotted").font(.headline) }
            .task(id: "\(connApp)-\(m.filter.hashValue)-\(m.dataVersion)") {
                let f = m.filter, app = connApp
                guard !app.isEmpty else { conns = []; return }
                conns = await Blocking.run { Queries.connections(app: app, f) }
            }

            GroupBox {
                Table(byAP) {
                    TableColumn("Network") { Text($0.ssid ?? "—") }
                    TableColumn("Access point") { Text($0.bssid).font(.system(.body, design: .monospaced)) }
                    TableColumn("Band") { Text($0.band ?? "—") }
                    TableColumn("Downloaded") { Text(Fmt.bytes($0.rx)) }
                    TableColumn("Uploaded") { Text(Fmt.bytes($0.tx)) }
                    TableColumn("Total") { Text(Fmt.bytes($0.rx + $0.tx)).fontWeight(.medium) }
                    TableColumn("Time connected") { Text(Fmt.duration($0.seconds)) }
                }
                .frame(minHeight: 200)
            } label: { Label("Per access point", systemImage: "wifi.router").font(.headline) }
            }

            Text("Note: per-app bytes are counted on Wi-Fi and wired interfaces (VPN traffic is counted on the interface it travels over). macOS only exposes traffic for this Mac. Per-device usage for other people on the network requires your router's own statistics (most routers show this in their admin page).")
                .font(.caption).foregroundStyle(.secondary)
        }
        .dashboardPage()
        .task(id: ReloadKey(filter: m.filter, version: m.dataVersion)) { await load() }
    }

    private static let dayMonth: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM"; return f }()

    private var busiest: UsageBucket? { buckets.max { $0.rx + $0.tx < $1.rx + $1.tx } }

    private func share(_ v: Double) -> String? {
        let t = o.rxBytes + o.txBytes
        return t > 0 ? String(format: "%.0f%% of total", v / t * 100) : nil
    }

    private var cumulative: [SeriesPoint] {
        var acc = 0.0
        return buckets.map { b in
            acc += b.rx + b.tx
            return SeriesPoint(date: b.date, value: acc / 1_073_741_824, series: "Total")
        }
    }

    private func load() async {
        let f = m.filter
        let r = await Blocking.run {
            (Queries.overview(f), Queries.usageBuckets(f), Queries.usageBy("ssid", f), Queries.apStats(f).sorted { $0.rx + $0.tx > $1.rx + $1.tx },
             Queries.usageBy("band", f), Queries.usageByApp(f), Queries.appUsageTotal(f), Queries.allTimeUsage(), Queries.heatmap(f, metric: "usage"))
        }
        let extra = await Blocking.run { (Queries.linkUsage(f), Queries.connectionApps(f), DataCap.status()) }
        o = r.0; buckets = r.1.buckets; hourly = r.1.hourly; byNetwork = r.2; byAP = r.3
        byBand = r.4; byApp = r.5; appTotal = r.6; allTime = r.7; heat = r.8
        links = extra.0; connApps = extra.1; cycle = extra.2
        if !connApps.contains(connApp) { connApp = connApps.first ?? "" }
    }
}

/// Monthly data-cap progress (configured in Settings).
struct DataCapCard: View {
    @EnvironmentObject var m: Monitor
    var body: some View {
        if let st = m.capStatus {
            let color: Color = st.fraction >= 1 ? .red : st.fraction >= 0.8 ? .orange : st.projected > st.cap ? .yellow : .green
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    CardTitle(title: "Monthly data cap", icon: "chart.pie.fill", color: color,
                              subtitle: "\(DataCap.scope == "network" ? "whole network" : "this Mac") · cycle starts on day \(DataCap.resetDay)")
                    Text(String(format: "%.0f%%", st.fraction * 100)).font(.system(size: 28, weight: .heavy, design: .rounded)).foregroundStyle(color)
                }
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.secondary.opacity(0.15))
                        Capsule().fill(LinearGradient(colors: [.green, .yellow, .orange, .red], startPoint: .leading, endPoint: .trailing))
                            .frame(width: g.size.width * min(1, st.fraction))
                            .mask(Capsule())
                        // expected-by-now marker
                        Rectangle().fill(.primary.opacity(0.6)).frame(width: 2).offset(x: g.size.width * st.elapsedFraction - 1)
                    }
                }
                .frame(height: 16)
                HStack(spacing: 22) {
                    capStat("Used", Fmt.bytes(st.used))
                    capStat("Cap", Fmt.bytes(st.cap))
                    capStat("Remaining", Fmt.bytes(max(0, st.cap - st.used)))
                    capStat("Projected", Fmt.bytes(st.projected), warn: st.projected > st.cap)
                    capStat("Daily budget", Fmt.bytes(st.dailyBudget))
                    capStat("Days left", "\(st.daysLeft)")
                }
            }
            .glassCard(tint: color)
        } else {
            Banner(icon: "chart.pie.fill", title: "Set a monthly data cap",
                   message: "Track usage against your plan with alerts at 50%, 80% and 100%.", color: .pink) {
                Text("Settings → Billing cycle & data cap").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func capStat(_ t: String, _ v: String, warn: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(t).font(.caption2).foregroundStyle(.secondary)
            Text(v).font(.system(.callout, design: .rounded).weight(.bold)).foregroundStyle(warn ? .orange : .primary).monospacedDigit()
        }
    }
}
