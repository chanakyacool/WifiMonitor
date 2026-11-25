import SwiftUI
import Charts

/// Roaming analysis (roam gaps, ping-pong, sticky client, per-AP reliability) and interference hints.
struct RoamingView: View {
    @EnvironmentObject var m: Monitor
    @State private var rep = RoamReport()
    @State private var channels: [ChannelNoise] = []
    @State private var hints: [Hint] = []
    @State private var history: [HistoryPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterBar()
            SectionHeader(title: "Roaming & RF", subtitle: "How well this Mac moves between access points, which APs drop you, and signs of interference")

            LazyVGrid(columns: kpiColumns, spacing: 12) {
                KPITile(title: "Roams", value: "\(rep.roams.count)", subtitle: String(format: "%.2f per connected hour", rep.roamsPerHour), icon: "arrow.triangle.swap", color: .teal)
                KPITile(title: "Median roam gap", value: rep.medianGap.map { String(format: "%.0f s", $0) } ?? "—",
                        subtitle: "sample-resolution (\(Int(Prefs.sampleInterval)) s)", icon: "timer", color: .blue)
                KPITile(title: "Ping-pong roams", value: "\(rep.pingPongs)", subtitle: "A → B → A within 2 min", icon: "arrow.left.arrow.right", color: rep.pingPongs > 3 ? .orange : .green)
                KPITile(title: "Avg signal gain", value: rep.avgGain.map { String(format: "%+.0f dB", $0) } ?? "—", subtitle: "after roaming", icon: "cellularbars", color: (rep.avgGain ?? 0) < 0 ? .orange : .green)
                KPITile(title: "Sticky moments", value: "\(rep.sticky.count)", subtitle: "stayed on a weak AP", icon: "pin.circle.fill", color: rep.sticky.isEmpty ? .green : .orange)
                KPITile(title: "Worst AP", value: worstAP.map { String(format: "%.2f/h", $0.perHour) } ?? "—", subtitle: worstAP?.bssid, icon: "wifi.exclamationmark", color: .red)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(hints) { h in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: h.icon).foregroundStyle(h.color).font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.title).font(.headline)
                                Text(h.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } label: { Label("Interference hints", systemImage: "waveform.badge.exclamationmark").font(.headline) }

            LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 16) {
                ChartCard(title: "Noise floor", subtitle: "avg per bucket — spikes suggest interference", icon: "waveform.path", color: .purple) {
                    TimeLineChart(points: history.compactMap { p in p.noise.map { SeriesPoint(date: p.date, value: $0, series: "Noise") } }, unit: "dBm")
                }
                ChartCard(title: "Noise by channel", subtitle: "median and 95th percentile", icon: "dial.medium.fill", color: .cyan) {
                    if channels.isEmpty { EmptyChart() } else {
                        Chart {
                            ForEach(channels) { c in
                                BarMark(x: .value("Channel", "ch \(c.channel)"), yStart: .value("dBm", -100), yEnd: .value("dBm", c.median))
                                    .foregroundStyle(by: .value("Stat", "Median"))
                                PointMark(x: .value("Channel", "ch \(c.channel)"), y: .value("dBm", c.p95))
                                    .foregroundStyle(by: .value("Stat", "95th pct")).symbolSize(70)
                            }
                        }
                        .chartForegroundStyleScale(["Median": Color.cyan, "95th pct": Color.red])
                        .chartYScale(domain: -100 ... -60)
                        .chartHover { proxy, loc in
                            guard let ch: String = proxy.value(atX: loc.x), let c = channels.first(where: { "ch \($0.channel)" == ch }) else { return nil }
                            var tip = ChartTip(title: "Channel \(c.channel)" + (c.band.map { " · \($0)" } ?? ""), rows: [
                                .init(label: "Median noise", value: String(format: "%.0f dBm", c.median), color: .cyan),
                                .init(label: "95th pct", value: String(format: "%.0f dBm", c.p95), color: .red),
                                .init(label: "Spikes", value: Fmt.pct(c.spikeShare, digits: 0)),
                                .init(label: "APs visible", value: String(format: "%.1f", c.apsVisible)),
                                .init(label: "Samples", value: "\(c.samples)"),
                            ])
                            if let s = c.avgSnr { tip.rows.append(.init(label: "Avg SNR", value: String(format: "%.0f dB", s))) }
                            return tip
                        }
                    }
                }
                ChartCard(title: "Roams over time", subtitle: "signal before → after", icon: "arrow.triangle.swap", color: .teal) {
                    if rep.roams.isEmpty { EmptyChart(text: "No roams in this range") } else {
                        Chart(rep.roams) { r in
                            if let a = r.rssiBefore, let b = r.rssiAfter {
                                RuleMark(x: .value("Time", r.ts), yStart: .value("dBm", a), yEnd: .value("dBm", b))
                                    .foregroundStyle(b >= a ? Color.green : Color.orange).lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                                PointMark(x: .value("Time", r.ts), y: .value("dBm", b)).foregroundStyle(r.pingPong ? Color.red : Color.teal)
                            }
                        }
                        .chartYAxisLabel("dBm")
                        .chartHover { proxy, loc in
                            guard let d: Date = proxy.value(atX: loc.x), let r = ChartHoverKit.nearest(rep.roams, to: d, by: \.ts) else { return nil }
                            var tip = ChartTip(title: ChartHoverKit.date(r.ts) + (r.pingPong ? " · ping-pong" : ""), rows: [
                                .init(label: "From", value: r.from),
                                .init(label: "To", value: r.to),
                                .init(label: "Signal", value: "\(Fmt.dbm(r.rssiBefore)) → \(Fmt.dbm(r.rssiAfter))",
                                      color: (r.rssiAfter ?? 0) >= (r.rssiBefore ?? 0) ? .green : .orange),
                                .init(label: "Gap", value: String(format: "%.1f s", r.gap)),
                            ], guideX: proxy.position(forX: r.ts))
                            if let s = r.ssid { tip.rows.insert(.init(label: "Network", value: s), at: 0) }
                            if let l = r.latencyAfter { tip.rows.append(.init(label: "Latency after", value: Fmt.ms(l))) }
                            return tip
                        }
                    }
                }
                ChartCard(title: "Disconnects per hour by AP", icon: "wifi.router.fill", color: .red) {
                    RankedBars(groups: rep.aps.filter { $0.hours > 0.05 }.map {
                        UsageGroup(name: "\($0.ssid ?? "?") · \($0.bssid.suffix(8))", rx: $0.perHour, tx: 0)
                    }.sorted { $0.rx > $1.rx }, value: { $0.rx }, label: { String(format: "%.2f/h", $0) })
                }
            }

            GroupBox {
                Table(rep.aps) {
                    TableColumn("Network") { Text($0.ssid ?? "—") }
                    TableColumn("Access point") { Text($0.bssid).font(.system(.body, design: .monospaced)) }
                    TableColumn("Band") { Text($0.band ?? "—") }
                    TableColumn("Time connected") { Text(Fmt.duration($0.hours * 3600)) }
                    TableColumn("Avg signal") { a in Text(a.avgRssi.map { "\(Int($0)) dBm" } ?? "—").foregroundStyle(SignalQuality(rssi: a.avgRssi.map { Int($0) }).color) }
                    TableColumn("Loss") { Text(Fmt.pct($0.loss)) }
                    TableColumn("Disconnects") { Text("\($0.disconnects)") }
                    TableColumn("Per hour") { a in Text(String(format: "%.2f", a.perHour)).foregroundStyle(a.perHour > 0.5 ? .red : .primary) }
                    TableColumn("Roamed away") { Text("\($0.roamsAway)") }
                }
                .frame(minHeight: 180)
            } label: { Label("Per-AP reliability", systemImage: "wifi.router").font(.headline) }

            GroupBox {
                Table(rep.roams) {
                    TableColumn("Time") { Text(Fmt.dateTime.string(from: $0.ts)) }
                    TableColumn("From → to") { r in Text("\(r.from.suffix(8)) → \(r.to.suffix(8))").font(.system(.body, design: .monospaced)) }
                    TableColumn("Signal") { r in Text("\(Fmt.dbm(r.rssiBefore)) → \(Fmt.dbm(r.rssiAfter))") }
                    TableColumn("Gap") { Text(String(format: "%.0f s", $0.gap)) }
                    TableColumn("Worst latency after") { Text(Fmt.ms($0.latencyAfter)) }
                    TableColumn("") { r in if r.pingPong { Chip(text: "ping-pong", color: .red) } }
                }
                .frame(minHeight: 200)
            } label: { Label("Roam log (\(rep.roams.count))", systemImage: "list.bullet").font(.headline) }

            if !rep.sticky.isEmpty {
                GroupBox {
                    Table(rep.sticky) {
                        TableColumn("Time") { Text(Fmt.dateTime.string(from: $0.ts)) }
                        TableColumn("Network") { Text($0.ssid ?? "—") }
                        TableColumn("Stuck on") { s in Text("\(s.bssid) · \(s.rssi) dBm").font(.system(.body, design: .monospaced)) }
                        TableColumn("Better AP available") { s in Text("\(s.better) · \(s.betterRssi) dBm").font(.system(.body, design: .monospaced)).foregroundStyle(.green) }
                        TableColumn("Difference") { s in Text("+\(s.betterRssi - s.rssi) dB") }
                    }
                    .frame(minHeight: 160)
                } label: { Label("Sticky-client moments", systemImage: "pin.circle").font(.headline) }
                Text("A “better AP” can be the same router's other band (each band has its own BSSID). Frequent sticky moments usually mean the AP's roaming assist / minimum-RSSI setting is off, or the APs are too far apart.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .dashboardPage()
        .task(id: ReloadKey(filter: m.filter, version: m.dataVersion)) {
            let f = m.filter
            let r = await Blocking.run { (Queries.roaming(f), Queries.interference(f), Queries.history(f)) }
            rep = r.0; channels = r.1.channels; hints = r.1.hints; history = r.2
        }
    }

    private var worstAP: APReliability? { rep.aps.filter { $0.hours > 0.25 }.max { $0.perHour < $1.perHour } }
}
