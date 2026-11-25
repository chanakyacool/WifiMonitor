import SwiftUI
import Charts

/// Real-time view of the current connection (last 15 minutes kept in memory).
struct LiveView: View {
    @EnvironmentObject var m: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !m.locationAuthorized { LocationBanner() }
            header
            LazyVGrid(columns: kpiColumns, spacing: 12) { kpis }
            LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 16) {
                ChartCard(title: "Signal", subtitle: "last 15 min") {
                    TimeLineChart(points: series([("RSSI", { $0.rssi.map(Double.init) }), ("Noise", { $0.noise.map(Double.init) })]), unit: "dBm")
                }
                ChartCard(title: "Latency", subtitle: "last 15 min") {
                    TimeLineChart(points: series([("Router", { $0.gwLatency }), ("Internet", { $0.inetLatency }), ("DNS", { $0.dnsLatency })]), unit: "ms")
                }
                ChartCard(title: "Throughput", subtitle: "last 15 min") {
                    TimeLineChart(points: series([("Download", { $0.rxBps.map { $0 / 1e6 } }), ("Upload", { $0.txBps.map { $0 / 1e6 } })]), unit: "Mbps", area: true)
                }
                ChartCard(title: "Link rate", subtitle: "last 15 min") {
                    TimeLineChart(points: series([("Tx rate", { $0.txRate })]), unit: "Mbps")
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 16)], alignment: .leading, spacing: 16) { infoCards }
        }
        .dashboardPage()
    }

    private func series(_ defs: [(String, (Sample) -> Double?)]) -> [SeriesPoint] {
        defs.flatMap { name, get in m.recent.compactMap { s in get(s).map { SeriesPoint(date: s.ts, value: $0, series: name) } } }
    }

    // MARK: Header

    private var header: some View {
        let c = m.current
        let connected = c?.connected == true
        let q = SignalQuality(rssi: connected ? c?.rssi : nil)
        let pct = connected ? min(1, max(0, Double((c?.rssi ?? -100) + 100) / 70)) : 0
        return HStack(spacing: 24) {
            ZStack {
                Circle().stroke(.white.opacity(0.15), lineWidth: 12)
                Circle().trim(from: 0, to: pct)
                    .stroke(AngularGradient(colors: [.red, .orange, .yellow, .mint, .green, .red], center: .center,
                                            startAngle: .degrees(0), endAngle: .degrees(360)),
                            style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: q.color.opacity(0.6), radius: 8)
                VStack(spacing: 0) {
                    Image(systemName: connected ? "wifi" : "wifi.slash").font(.system(size: 22, weight: .bold))
                    Text(connected ? "\(c?.rssi ?? 0)" : "—").font(.system(size: 30, weight: .heavy, design: .rounded)).monospacedDigit()
                    Text("dBm").font(.caption2.weight(.semibold)).opacity(0.8)
                }
                .foregroundStyle(.white)
            }
            .frame(width: 120, height: 120)

            VStack(alignment: .leading, spacing: 10) {
                Text(connected ? (c?.ssid ?? "Connected") : (c?.powerOn == false ? "Wi-Fi is off" : "Not connected"))
                    .font(.system(size: 34, weight: .bold, design: .rounded)).foregroundStyle(.white)
                    .lineLimit(1).minimumScaleFactor(0.6)
                HStack(spacing: 8) {
                    Chip(text: q.rawValue, icon: "sparkles", color: .white)
                    if let c, connected {
                        Chip(text: c.band ?? "—", icon: "dot.radiowaves.left.and.right", color: .white)
                        Chip(text: "Ch \(c.channel ?? 0) · \(c.width ?? "")", icon: "dial.medium", color: .white)
                        if let phy = c.phy { Chip(text: phy, icon: "bolt.horizontal", color: .white) }
                    }
                    if let ls = m.linkState, ls.link != "Wi-Fi", ls.link != "Offline" {
                        Chip(text: "Internet via \(ls.link) (\(ls.primary ?? "?"))", icon: "cable.connector", color: .white)
                    }
                    if let v = m.linkState?.vpn { Chip(text: v, icon: "lock.shield.fill", color: .white) }
                    if m.identity?.captive == true { Chip(text: "Captive portal", icon: "hand.raised.fill", color: .white) }
                }
                .foregroundStyle(.white)
                HStack(spacing: 18) {
                    heroStat("Router", Fmt.ms(c?.gwLatency), "wifi.router")
                    heroStat("Internet", Fmt.ms(c?.inetLatency), "globe")
                    heroStat("Download", Fmt.bps(c?.rxBps), "arrow.down")
                    heroStat("Upload", Fmt.bps(c?.txBps), "arrow.up")
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 6) {
                    Circle().fill(m.internetUp ? Color.green : Color.red).frame(width: 9, height: 9).shadow(color: m.internetUp ? .green : .red, radius: 4)
                    Text(m.internetUp ? "Online" : "Offline").font(.headline)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.18)))
                .foregroundStyle(.white)
                if let ts = c?.ts { Text("Updated \(Fmt.time.string(from: ts))").font(.caption).foregroundStyle(.white.opacity(0.8)) }
                HStack {
                    SpeedTestButton()
                    WiFiNetworksButton(title: "Scan & switch Wi-Fi")
                }
                .buttonStyle(.appOnColor)
            }
        }
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(LinearGradient(colors: heroColors(q), startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    Circle().fill(.white.opacity(0.10)).frame(width: 340).offset(x: 280, y: -120).blur(radius: 2),
                    alignment: .topTrailing)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: heroColors(q)[0].opacity(0.45), radius: 22, y: 10)
        }
    }

    private func heroColors(_ q: SignalQuality) -> [Color] {
        switch q {
        case .excellent, .good: return [Color(red: 0.16, green: 0.36, blue: 0.95), Color(red: 0.45, green: 0.25, blue: 0.95), Color(red: 0.05, green: 0.72, blue: 0.85)]
        case .fair: return [Color(red: 0.85, green: 0.45, blue: 0.10), Color(red: 0.90, green: 0.30, blue: 0.45)]
        case .weak, .poor, .none: return [Color(red: 0.80, green: 0.15, blue: 0.25), Color(red: 0.55, green: 0.10, blue: 0.45)]
        }
    }

    private func heroStat(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: icon).font(.caption2.weight(.semibold)).opacity(0.8)
            Text(value).font(.system(.title3, design: .rounded).weight(.bold)).monospacedDigit()
        }
        .foregroundStyle(.white)
    }

    // MARK: KPIs

    @ViewBuilder private var kpis: some View {
        let c = m.current
        let last5 = m.recent.filter { $0.ts > Date().addingTimeInterval(-300) }
        let lossVals = last5.compactMap(\.loss)
        let loss = lossVals.isEmpty ? nil : lossVals.reduce(0, +) / Double(lossVals.count)
        let lat = m.recent.compactMap(\.inetLatency)
        let jitter = lat.count > 1 ? zip(lat, lat.dropFirst()).map { abs($0 - $1) }.reduce(0, +) / Double(lat.count - 1) : nil

        KPITile(title: "Signal (RSSI)", value: Fmt.dbm(c?.rssi), subtitle: SignalQuality(rssi: c?.rssi).rawValue, icon: "cellularbars", color: SignalQuality(rssi: c?.rssi).color)
        KPITile(title: "Noise", value: Fmt.dbm(c?.noise), subtitle: "SNR \(Fmt.db(c?.snr))", icon: "waveform", color: .purple)
        KPITile(title: "Link rate", value: Fmt.mbps(c?.txRate), subtitle: "Tx power \(c?.txPower.map { "\($0) mW" } ?? "—")", icon: "bolt.horizontal", color: .yellow)
        KPITile(title: "Router latency", value: Fmt.ms(c?.gwLatency), subtitle: c?.gateway, icon: "wifi.router", color: .teal)
        KPITile(title: "Internet latency", value: Fmt.ms(c?.inetLatency), subtitle: "Jitter \(Fmt.ms(jitter))", icon: "globe", color: .blue)
        KPITile(title: "DNS lookup", value: Fmt.ms(c?.dnsLatency), subtitle: Prefs.dnsTestHost, icon: "server.rack", color: .indigo)
        KPITile(title: "Packet loss (5 min)", value: Fmt.pct(loss), icon: "exclamationmark.triangle", color: (loss ?? 0) > 0.02 ? .red : .green)
        KPITile(title: "Download now", value: Fmt.bps(c?.rxBps), icon: "arrow.down.circle", color: .green)
        KPITile(title: "Upload now", value: Fmt.bps(c?.txBps), icon: "arrow.up.circle", color: .orange)
        KPITile(title: "Data this session", value: Fmt.bytes(Double(m.sessionRx + m.sessionTx)),
                subtitle: "↓ \(Fmt.bytes(Double(m.sessionRx)))  ↑ \(Fmt.bytes(Double(m.sessionTx)))", icon: "externaldrive", color: .pink)
        KPITile(title: "Nearby networks", value: "\(m.nearby.count)", subtitle: m.lastScan.map { "Scanned \(Fmt.time.string(from: $0))" }, icon: "wifi.router", color: .cyan)
        KPITile(title: "LAN devices online", value: "\(m.devices.filter(\.online).count)", subtitle: "\(m.devices.count) known", icon: "laptopcomputer.and.iphone", color: .mint)
    }

    // MARK: Detail cards

    @ViewBuilder private var infoCards: some View {
        let c = m.current
        InfoCard(title: "Network", icon: "wifi", color: .blue, rows: [
            ("SSID", c?.ssid ?? "—"),
            ("BSSID (AP)", c?.bssid ?? "—"),
            ("Security", c?.security ?? "—"),
            ("Country", c?.country ?? "—"),
        ])
        InfoCard(title: "Radio", icon: "antenna.radiowaves.left.and.right", color: .purple, rows: [
            ("Channel", c?.channel.map(String.init) ?? "—"),
            ("Band", c?.band ?? "—"),
            ("Width", c?.width ?? "—"),
            ("PHY mode", c?.phy ?? "—"),
        ])
        InfoCard(title: "Addressing", icon: "number", color: .teal, rows: [
            ("Interface", c?.interface ?? "—"),
            ("Wi-Fi MAC", c?.mac ?? "—"),
            ("IPv4", c?.ip ?? "—"),
            ("Gateway", c?.gateway ?? "—"),
            ("DNS", c?.dns?.isEmpty == false ? c!.dns! : "—"),
        ])
        InfoCard(title: "Probes", icon: "scope", color: .orange, rows: [
            ("Ping targets", "\(Prefs.pingHost1), \(Prefs.pingHost2)"),
            ("DNS test", Prefs.dnsTestHost),
            ("Sample every", "\(Int(Prefs.sampleInterval)) s"),
            ("Samples in memory", "\(m.recent.count)"),
        ])
    }
}

struct LocationBanner: View {
    @EnvironmentObject var m: Monitor
    var body: some View {
        HStack {
            IconBadge(icon: "location.slash.fill", color: .orange, size: 34)
            VStack(alignment: .leading) {
                Text("Location permission needed").font(.headline)
                Text("macOS hides Wi-Fi network names (SSID) and access-point addresses (BSSID) from apps without Location Services access. Signal, latency and usage still work.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Grant access") { m.requestLocation() }.buttonStyle(.app(.orange))
        }
        .glassCard(tint: .orange)
    }
}
