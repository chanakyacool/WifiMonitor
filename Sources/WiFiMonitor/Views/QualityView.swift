import SwiftUI
import Charts

/// Deep dive into signal quality, latency, distributions, heatmaps and per-AP behaviour.
struct QualityView: View {
    @EnvironmentObject var m: Monitor
    @State private var history: [HistoryPoint] = []
    @State private var signalDist: [DistBucket] = []
    @State private var latencyDist: [DistBucket] = []
    @State private var heat: [HeatCell] = []
    @State private var heatMetric = "rssi"
    @State private var aps: [APStat] = []
    @State private var bands: [UsageGroup] = []
    @State private var channels: [UsageGroup] = []
    @State private var phys: [UsageGroup] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterBar()
            SectionHeader(title: "Signal & Latency", subtitle: "Time series are averaged into ~300 buckets for the selected range")

            LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 16) {
                ChartCard(title: "RSSI & noise", subtitle: "avg and worst per bucket") {
                    TimeLineChart(points: pts([("RSSI avg", \.rssi), ("RSSI min", \.minRssi), ("Noise", \.noise)]), unit: "dBm")
                }
                ChartCard(title: "Signal-to-noise ratio") { TimeLineChart(points: pts([("SNR", \.snr)]), unit: "dB", area: true) }
                ChartCard(title: "Link (Tx) rate") { TimeLineChart(points: pts([("Tx rate", \.txRate)]), unit: "Mbps") }
                ChartCard(title: "Latency", subtitle: "router · internet · DNS") {
                    TimeLineChart(points: pts([("Router", \.gw), ("Internet", \.inet), ("DNS", \.dns)]), unit: "ms")
                }
                ChartCard(title: "Latency spikes", subtitle: "worst internet ping per bucket") {
                    TimeLineChart(points: pts([("Max internet", \.maxInet)]), unit: "ms", area: true)
                }
                ChartCard(title: "Throughput") {
                    TimeLineChart(points: pts([("Download", \.rxBps), ("Upload", \.txBps)]).map {
                        SeriesPoint(date: $0.date, value: $0.value / 1e6, series: $0.series)
                    }, unit: "Mbps", area: true)
                }
                ChartCard(title: "Signal quality distribution", subtitle: "share of connected time") {
                    DistChart(buckets: signalDist, colors: [.green, .mint, .yellow, .orange, .red])
                }
                ChartCard(title: "Latency distribution", subtitle: "share of internet pings") {
                    DistChart(buckets: latencyDist, colors: [.green, .mint, .teal, .yellow, .orange, .red, .purple])
                }
                ChartCard(title: "Time per band") { RankedBars(groups: bands, value: { $0.seconds }, label: { Fmt.duration($0) }) }
                ChartCard(title: "Time per channel") { RankedBars(groups: channels, value: { $0.seconds }, label: { Fmt.duration($0) }) }
                ChartCard(title: "Time per Wi-Fi standard") { RankedBars(groups: phys, value: { $0.seconds }, label: { Fmt.duration($0) }) }
            }

            ChartCard(title: "Weekly pattern", subtitle: "by weekday and hour of day", height: 260) {
                VStack(alignment: .leading) {
                    Picker("", selection: $heatMetric) {
                        Text("Signal").tag("rssi"); Text("Latency").tag("inet_latency")
                        Text("Packet loss").tag("loss"); Text("Data usage").tag("usage")
                    }.pickerStyle(.segmented).frame(width: 420)
                    HeatmapView(cells: heat, format: heatFormat, invert: heatMetric == "inet_latency" || heatMetric == "loss")
                }
            }
            .task(id: "\(heatMetric)-\(m.filter.hashValue)-\(m.dataVersion)") {
                let f = m.filter, metric = heatMetric
                heat = await Blocking.run { Queries.heatmap(f, metric: metric) }
            }

            GroupBox {
                Table(aps) {
                    TableColumn("Network") { Text($0.ssid ?? "—") }
                    TableColumn("BSSID") { Text($0.bssid).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    TableColumn("Band / Ch") { Text("\($0.band ?? "—") · \($0.channel.map(String.init) ?? "—")") }
                    TableColumn("Time connected") { Text(Fmt.duration($0.seconds)) }
                    TableColumn("Avg RSSI") { Text($0.avgRssi.map { "\(Int($0)) dBm" } ?? "—").foregroundStyle(SignalQuality(rssi: $0.avgRssi.map { Int($0) }).color) }
                    TableColumn("Worst") { Text($0.minRssi.map { "\(Int($0)) dBm" } ?? "—") }
                    TableColumn("Avg latency") { Text(Fmt.ms($0.avgInet)) }
                    TableColumn("Loss") { Text(Fmt.pct($0.loss, digits: 2)) }
                    TableColumn("Data") { Text(Fmt.bytes($0.rx + $0.tx)) }
                    TableColumn("Last seen") { Text($0.lastSeen.map { Fmt.dateTime.string(from: $0) } ?? "—") }
                }
                .frame(minHeight: 220)
            } label: { Label("Access points used (\(aps.count))", systemImage: "wifi.router").font(.headline) }
        }
        .dashboardPage()
        .task(id: ReloadKey(filter: m.filter, version: m.dataVersion)) { await load() }
    }

    private var heatFormat: (Double) -> String {
        switch heatMetric {
        case "usage": return { Fmt.bytes($0) }
        case "loss": return { String(format: "%.0f%%", $0 * 100) }
        case "inet_latency": return { String(format: "%.0f", $0) }
        default: return { String(format: "%.0f", $0) }
        }
    }

    private func pts(_ defs: [(String, KeyPath<HistoryPoint, Double?>)]) -> [SeriesPoint] {
        defs.flatMap { name, kp in history.compactMap { p in p[keyPath: kp].map { SeriesPoint(date: p.date, value: $0, series: name) } } }
    }

    private func load() async {
        let f = m.filter
        let r = await Blocking.run {
            (Queries.history(f), Queries.signalDistribution(f), Queries.latencyDistribution(f), Queries.apStats(f),
             Queries.timeShare("band", f), Queries.timeShare("channel", f), Queries.timeShare("phy", f))
        }
        history = r.0; signalDist = r.1; latencyDist = r.2; aps = r.3; bands = r.4; channels = r.5; phys = r.6
    }
}

struct DistChart: View {
    let buckets: [DistBucket]
    let colors: [Color]
    var body: some View {
        if buckets.allSatisfy({ $0.count == 0 }) {
            EmptyChart()
        } else {
            Chart(buckets) { b in
                BarMark(x: .value("Bucket", b.label), y: .value("Share", b.count * 100))
                    .foregroundStyle(colors[min(b.order, colors.count - 1)].gradient)
                    .annotation(position: .top) { Text(String(format: "%.0f%%", b.count * 100)).font(.caption2).foregroundStyle(.secondary) }
            }
            .chartXScale(domain: buckets.map(\.label))
            .chartYAxisLabel("%")
            .chartHover { proxy, loc in
                guard let l: String = proxy.value(atX: loc.x), let b = buckets.first(where: { $0.label == l }) else { return nil }
                return ChartTip(title: b.label, rows: [.init(label: "Share of time", value: String(format: "%.1f%%", b.count * 100),
                                                             color: colors[min(b.order, colors.count - 1)])])
            }
        }
    }
}
