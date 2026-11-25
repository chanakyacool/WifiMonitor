import SwiftUI
import Charts

struct SpeedView: View {
    @EnvironmentObject var m: Monitor
    @State private var tests: [SpeedTestResult] = []
    @State private var bloatHours: [UsageGroup] = []
    @AppStorage("bufferbloatHours") private var scheduled = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterBar()
            HStack {
                SectionHeader(title: "Speed Tests", subtitle: "Apple networkQuality — throughput and responsiveness (RPM). Schedule automatic tests in Settings.")
                SpeedTestButton().buttonStyle(.app(.pink))
                if m.speedTestRunning { ProgressView().controlSize(.small) }
            }

            let dl = tests.compactMap(\.dlMbps), ul = tests.compactMap(\.ulMbps), rpm = tests.compactMap(\.responsiveness)
            LazyVGrid(columns: kpiColumns, spacing: 12) {
                KPITile(title: "Tests", value: "\(tests.count)", icon: "number", color: .gray)
                KPITile(title: "Latest download", value: Fmt.mbps(tests.first?.dlMbps), subtitle: tests.first.map { Fmt.dateTime.string(from: $0.ts) }, icon: "arrow.down.circle", color: .green)
                KPITile(title: "Latest upload", value: Fmt.mbps(tests.first?.ulMbps), icon: "arrow.up.circle", color: .orange)
                KPITile(title: "Avg download", value: Fmt.mbps(avg(dl)), subtitle: "min \(Fmt.mbps(dl.min())) · max \(Fmt.mbps(dl.max()))", icon: "chart.bar", color: .green)
                KPITile(title: "Avg upload", value: Fmt.mbps(avg(ul)), subtitle: "min \(Fmt.mbps(ul.min())) · max \(Fmt.mbps(ul.max()))", icon: "chart.bar", color: .orange)
                KPITile(title: "Avg responsiveness", value: avg(rpm).map { "\(Int($0)) RPM" } ?? "—", subtitle: rpmLabel(avg(rpm)), icon: "hare", color: .blue)
                let g = tests.first?.bloatGrade
                KPITile(title: "Bufferbloat (latest)", value: g?.rawValue ?? "—",
                        subtitle: tests.first?.bloatMs.map { "+\(Fmt.ms($0)) under load" }, icon: "tortoise.fill", color: g?.color ?? .gray)
                let bloat = tests.compactMap(\.bloatMs)
                KPITile(title: "Avg bufferbloat", value: avg(bloat).map { BloatGrade(ms: $0).rawValue } ?? "—",
                        subtitle: avg(bloat).map { "+\(Fmt.ms($0)) avg" }, icon: "chart.bar.doc.horizontal", color: avg(bloat).map { BloatGrade(ms: $0).color } ?? .gray)
            }

            if let g = tests.first?.bloatGrade {
                Banner(icon: "tortoise.fill", title: "Bufferbloat grade \(g.rawValue)", message: g.meaning, color: g.color) { EmptyView() }
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Run a load test automatically at these hours (once per hour) to catch evening congestion. Uses ~20 s of full bandwidth each time.")
                        .font(.callout).foregroundStyle(.secondary)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 12), spacing: 6) {
                        ForEach(0..<24, id: \.self) { h in
                            let on = hours.contains(h)
                            Button(String(format: "%02d", h)) { toggle(h) }
                                .buttonStyle(on ? AppButtonStyle(kind: .prominent, color: .pink) : AppButtonStyle(kind: .secondary, color: .gray))
                        }
                    }
                }
            } label: { Label("Busy-hour bufferbloat schedule\(hours.isEmpty ? "" : " · \(hours.count) hours")", systemImage: "calendar.badge.clock").font(.headline) }

            ChartCard(title: "Added latency under load by hour", subtitle: "average bufferbloat per hour of day", icon: "tortoise.fill", color: .orange) {
                if bloatHours.isEmpty { EmptyChart(text: "Run a few tests at different times of day") } else {
                    Chart(bloatHours) { b in
                        BarMark(x: .value("Hour", b.name), y: .value("ms", b.rx))
                            .foregroundStyle(BloatGrade(ms: b.rx).color.gradient).cornerRadius(5)
                    }
                    .chartYAxisLabel("ms")
                    .chartHover { proxy, loc in
                        guard let h: String = proxy.value(atX: loc.x), let b = bloatHours.first(where: { $0.name == h }) else { return nil }
                        let g = BloatGrade(ms: b.rx)
                        return ChartTip(title: "Hour \(b.name)", rows: [.init(label: "Added latency", value: Fmt.ms(b.rx), color: g.color),
                                                                     .init(label: "Grade", value: g.rawValue)])
                    }
                }
            }

            ChartCard(title: "Throughput history", height: 240) {
                if tests.isEmpty { EmptyChart(text: "No speed tests yet — run one above") } else {
                    Chart {
                        ForEach(tests) { t in
                            if let d = t.dlMbps {
                                LineMark(x: .value("Time", t.ts), y: .value("Mbps", d), series: .value("S", "Download")).foregroundStyle(by: .value("S", "Download"))
                                PointMark(x: .value("Time", t.ts), y: .value("Mbps", d)).foregroundStyle(by: .value("S", "Download"))
                            }
                            if let u = t.ulMbps {
                                LineMark(x: .value("Time", t.ts), y: .value("Mbps", u), series: .value("S", "Upload")).foregroundStyle(by: .value("S", "Upload"))
                                PointMark(x: .value("Time", t.ts), y: .value("Mbps", u)).foregroundStyle(by: .value("S", "Upload"))
                            }
                        }
                    }
                    .chartForegroundStyleScale(["Download": Color.green, "Upload": Color.orange])
                    .chartYAxisLabel("Mbps")
                    .chartHover { proxy, loc in
                        guard let d: Date = proxy.value(atX: loc.x), let t = ChartHoverKit.nearest(tests, to: d, by: \.ts) else { return nil }
                        let x = proxy.position(forX: t.ts)
                        var tip = ChartTip(title: ChartHoverKit.date(t.ts), guideX: x)
                        tip.rows.append(.init(label: "Download", value: Fmt.mbps(t.dlMbps), color: .green))
                        tip.rows.append(.init(label: "Upload", value: Fmt.mbps(t.ulMbps), color: .orange))
                        if let g = t.bloatGrade { tip.rows.append(.init(label: "Bufferbloat", value: "\(g.rawValue) · +\(Fmt.ms(t.bloatMs))")) }
                        if let s = t.ssid { tip.rows.append(.init(label: "Network", value: s)) }
                        if let x {
                            if let v = t.dlMbps, let y = proxy.position(forY: v) { tip.dots.append((CGPoint(x: x, y: y), .green)) }
                            if let v = t.ulMbps, let y = proxy.position(forY: v) { tip.dots.append((CGPoint(x: x, y: y), .orange)) }
                        }
                        return tip
                    }
                }
            }

            GroupBox {
                Table(tests) {
                    TableColumn("Time") { Text(Fmt.dateTime.string(from: $0.ts)) }
                    TableColumn("Download") { Text(Fmt.mbps($0.dlMbps)) }
                    TableColumn("Upload") { Text(Fmt.mbps($0.ulMbps)) }
                    TableColumn("Responsiveness") { t in Text(t.responsiveness.map { "\(Int($0)) RPM · \(rpmLabel($0) ?? "")" } ?? "—") }
                    TableColumn("Base RTT") { Text(Fmt.ms($0.baseRTT)) }
                    TableColumn("Bufferbloat") { t in
                        if let g = t.bloatGrade { Text("\(g.rawValue) · +\(Fmt.ms(t.bloatMs))").foregroundStyle(g.color) } else { Text("—") }
                    }
                    TableColumn("Type") { Text($0.kind ?? "manual").foregroundStyle(.secondary) }
                    TableColumn("Network") { Text($0.ssid ?? "—") }
                    TableColumn("Band") { Text($0.band ?? "—") }
                }
                .frame(minHeight: 260)
            } label: { Label("Results", systemImage: "list.bullet").font(.headline) }
        }
        .dashboardPage()
        .task(id: ReloadKey(filter: m.filter, version: m.dataVersion)) {
            let f = m.filter
            let r = await Blocking.run { (Queries.speedTests(f), Queries.bloatByHour(f)) }
            tests = r.0; bloatHours = r.1
        }
    }

    private var hours: Set<Int> {
        Set(scheduled.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }
    private func toggle(_ h: Int) {
        var s = hours
        if s.contains(h) { s.remove(h) } else { s.insert(h) }
        scheduled = s.sorted().map(String.init).joined(separator: ",")
    }

    private func avg(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
    private func rpmLabel(_ v: Double?) -> String? {
        guard let v else { return nil }
        return v >= 1000 ? "High" : v >= 300 ? "Medium" : "Low"
    }
}

struct EventsView: View {
    @EnvironmentObject var m: Monitor
    @State private var events: [EventItem] = []
    @State private var outages: [Outage] = []
    @State private var types: Set<EventType> = Set(EventType.allCases)
    @State private var search = ""

    private var rows: [EventItem] {
        events.filter { types.contains($0.type) && (search.isEmpty || $0.message.localizedCaseInsensitiveContains(search)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterBar()
            SectionHeader(title: "Events & Outages", subtitle: "Disconnects, roaming, outages, threshold alerts, new devices and more")

            let counts = Dictionary(grouping: events, by: \.type).mapValues(\.count)
            let wifiDown = outages.filter { $0.kind == "Wi-Fi" }.reduce(0) { $0 + $1.duration }
            let inetDown = outages.filter { $0.kind == "Internet" }.reduce(0) { $0 + $1.duration }
            LazyVGrid(columns: kpiColumns, spacing: 12) {
                KPITile(title: "Total events", value: "\(events.count)", icon: "list.number", color: .gray)
                KPITile(title: "Disconnects", value: "\(counts[.disconnected] ?? 0)", subtitle: "down \(Fmt.duration(wifiDown))", icon: "wifi.slash", color: .red)
                KPITile(title: "Internet outages", value: "\(counts[.internetDown] ?? 0)", subtitle: "down \(Fmt.duration(inetDown))", icon: "globe", color: .red)
                KPITile(title: "Longest outage", value: outages.map(\.duration).max().map { Fmt.duration($0) } ?? "—", icon: "hourglass", color: .orange)
                KPITile(title: "Roams", value: "\(counts[.roam] ?? 0)", icon: "arrow.triangle.swap", color: .teal)
                KPITile(title: "Low signal alerts", value: "\(counts[.lowSignal] ?? 0)", icon: "wifi.exclamationmark", color: .orange)
                KPITile(title: "High latency alerts", value: "\(counts[.highLatency] ?? 0)", icon: "tortoise", color: .orange)
                KPITile(title: "New devices", value: "\(counts[.newDevice] ?? 0)", icon: "sparkles", color: .blue)
            }

            ChartCard(title: "Event timeline", height: 220) {
                if events.isEmpty { EmptyChart() } else {
                    Chart(events) { e in
                        PointMark(x: .value("Time", e.ts), y: .value("Type", e.type.title))
                            .foregroundStyle(e.type.color)
                            .symbolSize(40)
                    }
                    .chartHover { proxy, loc in
                        guard let e = ChartHoverKit.nearestInPlot(events, proxy: proxy, at: loc, position: { e in
                            proxy.position(forX: e.ts).flatMap { x in proxy.position(forY: e.type.title).map { CGPoint(x: x, y: $0) } }
                        }) else { return nil }
                        var tip = ChartTip(title: e.type.title, rows: [.init(label: "Time", value: ChartHoverKit.date(e.ts), color: e.type.color)])
                        if let s = e.ssid { tip.rows.append(.init(label: "Network", value: s)) }
                        tip.rows.append(.init(label: "", value: String(e.message.prefix(80))))
                        return tip
                    }
                }
            }

            GroupBox {
                Table(outages) {
                    TableColumn("Type") { Text($0.kind) }
                    TableColumn("Started") { Text(Fmt.dateTime.string(from: $0.start)) }
                    TableColumn("Ended") { Text($0.end.map { Fmt.dateTime.string(from: $0) } ?? "ongoing") }
                    TableColumn("Duration") { Text(Fmt.duration($0.duration)).fontWeight(.medium) }
                }
                .frame(minHeight: 160)
            } label: { Label("Outages (\(outages.count))", systemImage: "bolt.horizontal.circle").font(.headline) }

            GroupBox {
                VStack(alignment: .leading) {
                    HStack {
                        TextField("Search events", text: $search).textFieldStyle(.roundedBorder).frame(width: 260)
                        Menu("Event types (\(types.count)/\(EventType.allCases.count))") {
                            Button("All") { types = Set(EventType.allCases) }
                            Button("Problems only") { types = [.disconnected, .internetDown, .lowSignal, .highLatency, .scanError] }
                            Divider()
                            ForEach(EventType.allCases) { t in
                                Toggle(t.title, isOn: Binding(get: { types.contains(t) }, set: { on in if on { types.insert(t) } else { types.remove(t) } }))
                            }
                        }.frame(width: 240)
                    }
                    Table(rows) {
                        TableColumn("Time") { Text(Fmt.dateTime.string(from: $0.ts)) }.width(min: 140, ideal: 160)
                        TableColumn("Type") { e in Label(e.type.title, systemImage: e.type.icon).foregroundStyle(e.type.color) }.width(min: 140, ideal: 170)
                        TableColumn("Details") { Text($0.message).textSelection(.enabled) }
                        TableColumn("Network") { Text($0.ssid ?? "—") }.width(min: 80, ideal: 120)
                    }
                    .frame(minHeight: 360)
                }
            } label: { Label("Event log (\(rows.count))", systemImage: "list.bullet").font(.headline) }
        }
        .dashboardPage()
        .task(id: ReloadKey(filter: m.filter, version: m.dataVersion &+ m.events.count)) {
            let f = m.filter
            let r = await Blocking.run { (Queries.events(f), Queries.outages(f)) }
            events = r.0; outages = r.1
        }
    }
}
