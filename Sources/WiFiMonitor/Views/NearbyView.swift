import SwiftUI
import Charts

struct NearbyView: View {
    @EnvironmentObject var m: Monitor
    @State private var mode = 0 // 0 = live scan, 1 = everything seen in filtered range
    @State private var seen: [ScanResult] = []
    @State private var search = ""
    @State private var bandFilter = "All"

    private var source: [ScanResult] { mode == 0 ? m.nearby : seen }
    private var rows: [ScanResult] {
        source.filter { r in
            (bandFilter == "All" || r.band == bandFilter) &&
            (search.isEmpty || r.displaySSID.localizedCaseInsensitiveContains(search) || (r.bssid ?? "").contains(search.lowercased()))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if mode == 1 { FilterBar(showNetworkFilters: false) }
            HStack {
                SectionHeader(title: "Nearby Networks", subtitle: mode == 0
                    ? "Latest scan \(m.lastScan.map { Fmt.time.string(from: $0) } ?? "—") · \(m.nearby.count) access points"
                    : "\(seen.count) access points seen in range (RSSI averaged)")
                Picker("", selection: $mode) { Text("Live scan").tag(0); Text("Seen in range").tag(1) }
                    .pickerStyle(.segmented).frame(width: 240)
                Button { Task { await m.scanNearby() } } label: { Label("Scan now", systemImage: "arrow.clockwise") }
                    .buttonStyle(.app(.cyan))
                WiFiNetworksButton(title: "Switch network").buttonStyle(.appSecondary(.cyan))
            }
            if !m.locationAuthorized { LocationBanner() }

            LazyVGrid(columns: kpiColumns, spacing: 12) {
                KPITile(title: "Access points", value: "\(source.count)", icon: "wifi.router", color: .cyan)
                KPITile(title: "Unique networks", value: "\(Set(source.map(\.displaySSID)).count)", icon: "wifi", color: .blue)
                KPITile(title: "2.4 GHz", value: "\(source.filter { $0.band == "2.4 GHz" }.count)", icon: "dial.low", color: .orange)
                KPITile(title: "5 GHz", value: "\(source.filter { $0.band == "5 GHz" }.count)", icon: "dial.medium", color: .green)
                KPITile(title: "6 GHz", value: "\(source.filter { $0.band == "6 GHz" }.count)", icon: "dial.high", color: .purple)
                KPITile(title: "Open / weak security", value: "\(source.filter { ["Open", "WEP", "WPA Personal", "Dynamic WEP"].contains($0.security) }.count)", icon: "lock.open", color: .red)
                KPITile(title: "Best 2.4 GHz channel", value: best24.map { "ch \($0)" } ?? "—", subtitle: "least overlap of 1/6/11", icon: "checkmark.seal", color: .green)
                KPITile(title: "Best 5 GHz channel", value: best5.map { "ch \($0)" } ?? "—", subtitle: "least occupied", icon: "checkmark.seal", color: .green)
            }

            LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 16) {
                ChartCard(title: "2.4 GHz channel map", subtitle: "signal per AP") { channelChart("2.4 GHz") }
                ChartCard(title: "5 / 6 GHz channel map", subtitle: "signal per AP") { channelChart(nil) }
                ChartCard(title: "Security in use") { RankedBars(groups: groups(\.security), value: { $0.rx }, label: { "\(Int($0))" }) }
                ChartCard(title: "Channel widths") { RankedBars(groups: groups { $0.width ?? "?" }, value: { $0.rx }, label: { "\(Int($0))" }) }
            }

            GroupBox {
                VStack(alignment: .leading) {
                    HStack {
                        TextField("Search SSID or BSSID", text: $search).textFieldStyle(.roundedBorder).frame(width: 260)
                        Picker("Band", selection: $bandFilter) {
                            ForEach(["All", "2.4 GHz", "5 GHz", "6 GHz"], id: \.self) { Text($0) }
                        }.frame(width: 160)
                    }
                    Table(rows) {
                        TableColumn("SSID") { r in
                            HStack {
                                if r.bssid != nil && r.bssid == m.current?.bssid { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                                Text(r.displaySSID)
                            }
                        }
                        TableColumn("BSSID") { Text($0.bssid ?? "—").font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                        TableColumn("RSSI") { r in Text("\(r.rssi) dBm").foregroundStyle(SignalQuality(rssi: r.rssi).color) }
                        TableColumn("Noise") { Text("\($0.noise) dBm") }
                        TableColumn("Channel") { Text("\($0.channel.map(String.init) ?? "—") · \($0.band ?? "—")") }
                        TableColumn("Width") { Text($0.width ?? "—") }
                        TableColumn("Security") { Text($0.security) }
                        TableColumn("Beacon") { Text("\($0.beaconInterval) TU") }
                        TableColumn("Country") { Text($0.country ?? "—") }
                        TableColumn(mode == 0 ? "Seen" : "Times seen") { r in Text(mode == 0 ? Fmt.time.string(from: r.ts) : "\(r.seenCount)") }
                    }
                    .frame(minHeight: 340)
                }
            } label: { Label("Access points (\(rows.count))", systemImage: "list.bullet").font(.headline) }
        }
        .dashboardPage()
        .task(id: ReloadKey(filter: m.filter, version: m.dataVersion + mode * 100_000)) {
            if mode == 1 { let f = m.filter; seen = await Blocking.run { Queries.networksSeen(f) } }
        }
    }

    private func groups(_ key: (ScanResult) -> String) -> [UsageGroup] {
        Dictionary(grouping: source, by: key).map { UsageGroup(name: $0.key, rx: Double($0.value.count), tx: 0) }.sorted { $0.rx > $1.rx }
    }

    @ViewBuilder private func channelChart(_ band: String?) -> some View {
        let nets = source.filter { band == nil ? ($0.band == "5 GHz" || $0.band == "6 GHz") : $0.band == band }.filter { $0.channel != nil }
        if nets.isEmpty {
            EmptyChart(text: "No networks")
        } else {
            Chart(nets) { n in
                BarMark(x: .value("Channel", "\(n.channel!)"), yStart: .value("dBm", -100), yEnd: .value("dBm", n.rssi), width: .ratio(0.6))
                    .foregroundStyle(by: .value("SSID", n.displaySSID))
                    .position(by: .value("BSSID", n.bssid ?? n.id))
            }
            .chartXScale(domain: Array(Set(nets.compactMap(\.channel))).sorted().map(String.init))
            .chartYScale(domain: -100 ... -20)
            .chartYAxisLabel("dBm")
            .chartLegend(nets.count > 14 ? .hidden : .visible)
            .chartHover { proxy, loc in
                guard let ch: String = proxy.value(atX: loc.x) else { return nil }
                let here = nets.filter { "\($0.channel!)" == ch }.sorted { $0.rssi > $1.rssi }
                guard !here.isEmpty else { return nil }
                var tip = ChartTip(title: "Channel \(ch) · \(here.count) network\(here.count == 1 ? "" : "s")")
                tip.rows = here.prefix(10).map { .init(label: $0.displaySSID, value: Fmt.dbm($0.rssi)) }
                if here.count > 10 { tip.rows.append(.init(label: "+\(here.count - 10) more", value: "")) }
                return tip
            }
        }
    }

    private var others: [ScanResult] { source.filter { $0.bssid != m.current?.bssid } }

    private var best24: Int? {
        let n = others.filter { $0.band == "2.4 GHz" }
        guard !n.isEmpty else { return nil }
        return [1, 6, 11].min { a, b in score24(a, n) < score24(b, n) }
    }
    private func score24(_ ch: Int, _ nets: [ScanResult]) -> Double {
        nets.reduce(0) { acc, n in
            guard let c = n.channel, abs(c - ch) < 5 else { return acc }
            return acc + Double(max(0, n.rssi + 100)) * (1 - Double(abs(c - ch)) / 5)
        }
    }
    private var best5: Int? {
        let n = others.filter { $0.band == "5 GHz" }
        guard !n.isEmpty else { return nil }
        let candidates = [36, 40, 44, 48, 149, 153, 157, 161, 165]
        return candidates.min { a, b in
            n.filter { $0.channel == a }.reduce(0) { $0 + max(0, $1.rssi + 100) } < n.filter { $0.channel == b }.reduce(0) { $0 + max(0, $1.rssi + 100) }
        }
    }
}
