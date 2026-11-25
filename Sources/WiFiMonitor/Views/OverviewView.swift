import SwiftUI
import Charts

/// Executive summary for the filtered range: every headline number plus the key trends.
struct OverviewView: View {
    @EnvironmentObject var m: Monitor
    @State private var o = Overview()
    @State private var history: [HistoryPoint] = []
    @State private var usage: [UsageBucket] = []
    @State private var hourly = true
    @State private var networks: [UsageGroup] = []
    @State private var loading = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterBar()
            SectionHeader(title: "Overview", subtitle: "\(o.samples) samples · \(Fmt.duration(o.span)) of monitoring in range" + (loading ? " · loading…" : ""))

            GroupHeading(title: "Connection")
            LazyVGrid(columns: kpiColumns, spacing: 12) {
                KPITile(title: "Wi-Fi uptime", value: Fmt.pct(o.wifiUptime, digits: 2), subtitle: "\(o.disconnects) disconnects", icon: "wifi", color: .green)
                KPITile(title: "Internet uptime", value: Fmt.pct(o.internetUptime, digits: 2), subtitle: "\(o.outages) outages", icon: "globe", color: .blue)
                KPITile(title: "Avg signal", value: o.avgRssi.map { "\(Int($0)) dBm" } ?? "—",
                        subtitle: "min \(Fmt.num(o.minRssi)) · max \(Fmt.num(o.maxRssi))", icon: "cellularbars", color: SignalQuality(rssi: o.avgRssi.map { Int($0) }).color)
                KPITile(title: "Avg SNR", value: o.avgSnr.map { "\(Int($0)) dB" } ?? "—", subtitle: "noise \(Fmt.num(o.avgNoise)) dBm", icon: "waveform", color: .purple)
                KPITile(title: "Avg link rate", value: Fmt.mbps(o.avgTxRate), subtitle: "peak \(Fmt.mbps(o.maxTxRate))", icon: "bolt.horizontal", color: .yellow)
                KPITile(title: "Roams (AP changes)", value: "\(o.roams)", subtitle: "\(o.aps) APs · \(o.networks) networks", icon: "arrow.triangle.swap", color: .teal)
                KPITile(title: "Low-signal events", value: "\(o.lowSignalEvents)", subtitle: "below \(Prefs.lowRssi) dBm", icon: "wifi.exclamationmark", color: .orange)
            }

            GroupHeading(title: "Performance")
            LazyVGrid(columns: kpiColumns, spacing: 12) {
                KPITile(title: "Router latency", value: Fmt.ms(o.avgGw), subtitle: "average", icon: "wifi.router", color: .teal)
                KPITile(title: "Internet latency", value: Fmt.ms(o.avgInet), subtitle: "p95 \(Fmt.ms(o.p95Inet)) · max \(Fmt.ms(o.maxInet))", icon: "globe", color: .blue)
                KPITile(title: "Jitter", value: Fmt.ms(o.jitter), icon: "waveform.path", color: .indigo)
                KPITile(title: "DNS lookup", value: Fmt.ms(o.avgDns), icon: "server.rack", color: .indigo)
                KPITile(title: "Packet loss", value: Fmt.pct(o.loss, digits: 2), icon: "exclamationmark.triangle", color: (o.loss ?? 0) > 0.01 ? .red : .green)
                KPITile(title: "Speed tests", value: "\(o.speedTests)", subtitle: "avg ↓ \(Fmt.mbps(o.avgDl)) ↑ \(Fmt.mbps(o.avgUl))", icon: "speedometer", color: .pink)
            }

            GroupHeading(title: "Data & environment")
            LazyVGrid(columns: kpiColumns, spacing: 12) {
                KPITile(title: "Total data", value: Fmt.bytes(o.rxBytes + o.txBytes), subtitle: "this Mac over Wi-Fi", icon: "sum", color: .pink)
                KPITile(title: "Downloaded", value: Fmt.bytes(o.rxBytes), subtitle: "peak \(Fmt.bps(o.peakRx))", icon: "arrow.down.circle", color: .green)
                KPITile(title: "Uploaded", value: Fmt.bytes(o.txBytes), subtitle: "peak \(Fmt.bps(o.peakTx))", icon: "arrow.up.circle", color: .orange)
                KPITile(title: "LAN devices seen", value: "\(o.devices)", icon: "laptopcomputer.and.iphone", color: .mint)
                KPITile(title: "Nearby APs seen", value: "\(o.nearbyNetworks)", icon: "wifi.router", color: .cyan)
            }

            LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 16) {
                ChartCard(title: "Signal strength") {
                    TimeLineChart(points: pts([("RSSI", \.rssi), ("Noise", \.noise)]), unit: "dBm")
                }
                ChartCard(title: "Latency") {
                    TimeLineChart(points: pts([("Router", \.gw), ("Internet", \.inet), ("DNS", \.dns)]), unit: "ms")
                }
                ChartCard(title: "Data usage", subtitle: hourly ? "per hour" : "per day") { UsageBarChart(buckets: usage, hourly: hourly) }
                ChartCard(title: "Availability", subtitle: "% of time connected / online") {
                    TimeLineChart(points: pts([("Wi-Fi", \.up), ("Internet", \.inetUp)]).map {
                        SeriesPoint(date: $0.date, value: $0.value * 100, series: $0.series)
                    }, unit: "%", yDomain: 0...100)
                }
                ChartCard(title: "Data by network") { RankedBars(groups: networks) }
                ChartCard(title: "Packet loss") {
                    TimeLineChart(points: pts([("Loss", \.loss)]).map { SeriesPoint(date: $0.date, value: $0.value * 100, series: $0.series) }, unit: "%", area: true)
                }
            }
        }
        .dashboardPage()
        .task(id: ReloadKey(filter: m.filter, version: m.dataVersion)) { await load() }
    }

    private func pts(_ defs: [(String, KeyPath<HistoryPoint, Double?>)]) -> [SeriesPoint] {
        defs.flatMap { name, kp in history.compactMap { p in p[keyPath: kp].map { SeriesPoint(date: p.date, value: $0, series: name) } } }
    }

    private func load() async {
        loading = true
        let f = m.filter
        let r = await Blocking.run { (Queries.overview(f), Queries.history(f), Queries.usageBuckets(f), Queries.usageBy("ssid", f)) }
        o = r.0; history = r.1; usage = r.2.buckets; hourly = r.2.hourly; networks = r.3
        loading = false
    }
}

struct UsageBarChart: View {
    let buckets: [UsageBucket]
    let hourly: Bool

    var body: some View {
        if buckets.isEmpty || buckets.allSatisfy({ $0.rx + $0.tx == 0 }) {
            EmptyChart()
        } else {
            Chart {
                ForEach(buckets) { b in
                    BarMark(x: .value("Time", b.date, unit: hourly ? .hour : .day), y: .value("MB", b.rx / 1_048_576))
                        .foregroundStyle(by: .value("Direction", "Download"))
                    BarMark(x: .value("Time", b.date, unit: hourly ? .hour : .day), y: .value("MB", b.tx / 1_048_576))
                        .foregroundStyle(by: .value("Direction", "Upload"))
                }
            }
            .chartForegroundStyleScale(["Download": Color.green, "Upload": Color.orange])
            .chartYAxisLabel("MiB")
            .chartLegend(position: .top, alignment: .leading)
            .chartHover { proxy, loc in
                guard let d: Date = proxy.value(atX: loc.x) else { return nil }
                let cal = Calendar.current
                let b = buckets.first { cal.isDate($0.date, equalTo: d, toGranularity: hourly ? .hour : .day) }
                    ?? ChartHoverKit.nearest(buckets, to: d, by: \.date)
                guard let b else { return nil }
                let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = hourly ? .short : .none
                return ChartTip(title: f.string(from: b.date), rows: [
                    .init(label: "Download", value: Fmt.bytes(b.rx), color: .green),
                    .init(label: "Upload", value: Fmt.bytes(b.tx), color: .orange),
                    .init(label: "Total", value: Fmt.bytes(b.rx + b.tx)),
                ])
            }
        }
    }
}
