import SwiftUI
import Charts

/// Traceroute path monitoring, IPv6, public IP / ISP history, captive portals and VPN / link awareness.
struct PathsView: View {
    @EnvironmentObject var m: Monitor
    @State private var traces: [TraceRow] = []
    @State private var trace: TraceResult?
    @State private var ipv6: [IPv6Row] = []
    @State private var identity: [IdentityRow] = []
    @State private var baseline: (local: Double?, isp: Double?, upstream: Double?) = (nil, nil, nil)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterBar(showNetworkFilters: false)
            HStack(alignment: .bottom) {
                SectionHeader(title: "Path & Internet", subtitle: "Where slowdowns happen (Wi-Fi, ISP or beyond), IPv6 health, public IP / ISP changes, captive portals and VPNs")
                Button { Task { await m.runTrace(); await load() } } label: {
                    Label(m.tracing ? "Tracing…" : "Trace now", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                .buttonStyle(.app(.teal)).disabled(m.tracing)
                Button { Task { await m.checkIdentity(); await m.probeIPv6(); await load() } } label: {
                    Label("Recheck", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.appSecondary(.teal))
            }

            if m.identity?.captive == true {
                Banner(icon: "hand.raised.square.fill", title: "Captive portal detected",
                       message: "This network wants you to sign in or accept terms in a browser before internet access works.", color: .orange) {
                    Button("Open sign-in page") { if let u = URL(string: "http://captive.apple.com") { NSWorkspace.shared.open(u) } }
                        .buttonStyle(.app(.orange))
                }
            }

            LazyVGrid(columns: kpiColumns, spacing: 12) {
                KPITile(title: "Public IP", value: m.identity?.publicIP ?? "—", subtitle: m.identity?.captive == true ? "captive portal" : nil, icon: "globe", color: .indigo)
                KPITile(title: "ISP", value: m.identity?.isp ?? "—", subtitle: m.identity?.asn.map { "AS\($0)" }, icon: "building.columns.fill", color: .blue)
                KPITile(title: "Connection", value: m.linkState?.link ?? "—", subtitle: m.linkState?.primary.map { "via \($0)" }, icon: linkIcon, color: .teal)
                KPITile(title: "VPN", value: m.linkState?.vpn ?? "Off", icon: m.linkState?.vpn == nil ? "lock.open" : "lock.shield.fill",
                        color: m.linkState?.vpn == nil ? .gray : .green)
                KPITile(title: "IPv6", value: ipv6Status, subtitle: m.ipv6?.address, icon: "6.circle.fill",
                        color: m.ipv6?.latency != nil ? .green : (m.ipv6?.hasV6 == true ? .red : .gray))
                KPITile(title: "IPv6 latency", value: Fmt.ms(m.ipv6?.latency), subtitle: "IPv4 \(Fmt.ms(m.current?.inetLatency))", icon: "timer", color: .purple)
                KPITile(title: "Home segment", value: Fmt.ms(trace?.localMs), subtitle: "usual \(Fmt.ms(baseline.local))", icon: "house.fill", color: .green)
                KPITile(title: "ISP adds", value: Fmt.ms(trace?.ispAdded), subtitle: "usual \(Fmt.ms(baseline.isp))", icon: "building.2.fill", color: .orange)
                KPITile(title: "Internet adds", value: Fmt.ms(trace?.upstreamAdded), subtitle: "usual \(Fmt.ms(baseline.upstream))", icon: "network", color: .pink)
            }

            if let t = trace { pathCard(t) }

            LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 16) {
                ChartCard(title: "Latency by path segment", subtitle: "stacked: home + ISP + internet", icon: "square.stack.3d.up.fill", color: .teal) {
                    if traces.isEmpty { EmptyChart(text: "Traceroutes run every 15 min (Settings)") } else {
                        Chart {
                            ForEach(traces) { t in
                                ForEach([("Home", t.local), ("ISP", t.isp), ("Internet", t.upstream)], id: \.0) { seg, v in
                                    if let v {
                                        AreaMark(x: .value("Time", t.ts), y: .value("ms", v), stacking: .standard)
                                            .foregroundStyle(by: .value("Segment", seg)).interpolationMethod(.monotone)
                                    }
                                }
                            }
                        }
                        .chartForegroundStyleScale(["Home": Color.green, "ISP": Color.orange, "Internet": Color.pink])
                        .chartYAxisLabel("ms")
                        .chartLegend(position: .top, alignment: .leading)
                        .chartHover { proxy, loc in
                            guard let d: Date = proxy.value(atX: loc.x), let t = ChartHoverKit.nearest(traces, to: d, by: \.ts) else { return nil }
                            return ChartTip(title: ChartHoverKit.date(t.ts), rows: [
                                .init(label: "Home", value: Fmt.ms(t.local), color: .green),
                                .init(label: "ISP", value: Fmt.ms(t.isp), color: .orange),
                                .init(label: "Internet", value: Fmt.ms(t.upstream), color: .pink),
                                .init(label: "Total", value: Fmt.ms(t.total)),
                                .init(label: "Target", value: t.target + (t.reached ? "" : " (not reached)")),
                            ], guideX: proxy.position(forX: t.ts))
                        }
                    }
                }
                ChartCard(title: "IPv6 vs IPv4 latency", icon: "6.circle.fill", color: .purple) {
                    TimeLineChart(points: ipv6.flatMap { r in
                        [r.latency.map { SeriesPoint(date: r.ts, value: $0, series: "IPv6") },
                         r.v4.map { SeriesPoint(date: r.ts, value: $0, series: "IPv4") }].compactMap { $0 }
                    }, unit: "ms")
                }
                ChartCard(title: "IPv6 availability", icon: "checkmark.shield.fill", color: .mint) {
                    if ipv6.isEmpty { EmptyChart() } else {
                        Chart(ipv6) { r in
                            RectangleMark(x: .value("Time", r.ts), yStart: 0, yEnd: 1, width: .fixed(3))
                                .foregroundStyle(r.latency != nil ? Color.green : (r.hasV6 ? Color.red : Color.gray.opacity(0.5)))
                        }
                        .chartYAxis(.hidden)
                        .chartHover { proxy, loc in
                            guard let d: Date = proxy.value(atX: loc.x), let r = ChartHoverKit.nearest(ipv6, to: d, by: \.ts) else { return nil }
                            let status = r.latency != nil ? "Working" : (r.hasV6 ? "Has IPv6 but unreachable" : "No IPv6 address")
                            let c: Color = r.latency != nil ? .green : (r.hasV6 ? .red : .gray)
                            return ChartTip(title: ChartHoverKit.date(r.ts), rows: [
                                .init(label: "IPv6", value: status, color: c),
                                .init(label: "IPv6 latency", value: Fmt.ms(r.latency)),
                                .init(label: "IPv4 latency", value: Fmt.ms(r.v4)),
                            ], guideX: proxy.position(forX: r.ts))
                        }
                    }
                }
                ChartCard(title: "DNS over IPv6", icon: "server.rack", color: .indigo) {
                    TimeLineChart(points: ipv6.compactMap { r in r.dns.map { SeriesPoint(date: r.ts, value: $0, series: "DNS") } }, unit: "ms")
                }
            }

            GroupBox {
                Table(identity) {
                    TableColumn("Time") { Text(Fmt.dateTime.string(from: $0.ts)) }.width(min: 140, ideal: 160)
                    TableColumn("Public IP") { Text($0.publicIP ?? "—").font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                    TableColumn("ISP") { r in Text([r.isp, r.asn.map { "AS\($0)" }].compactMap { $0 }.joined(separator: " · ")) }
                    TableColumn("Network") { Text($0.ssid ?? $0.link ?? "—") }
                    TableColumn("VPN") { Text($0.vpn ?? "—") }
                    TableColumn("Captive") { r in Text(r.captive ? "yes" : "no").foregroundStyle(r.captive ? .orange : .secondary) }.width(60)
                }
                .frame(minHeight: 180)
            } label: { Label("Public IP & ISP history (\(identity.count) changes)", systemImage: "clock.arrow.circlepath").font(.headline) }

            Text("ISP names come from DNS lookups to Team Cymru's IP-to-ASN service and your public IP from OpenDNS; both can be turned off in Settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .dashboardPage()
        .task(id: ReloadKey(filter: m.filter, version: m.dataVersion)) { await load() }
    }

    private var linkIcon: String {
        switch m.linkState?.link {
        case "Ethernet": return "cable.connector"
        case "VPN": return "lock.shield"
        case "Wi-Fi": return "wifi"
        default: return "network"
        }
    }

    private var ipv6Status: String {
        guard let v = m.ipv6 else { return "—" }
        if !v.hasV6 { return "Not available" }
        return v.latency != nil ? "Working" : "Broken"
    }

    private func pathCard(_ t: TraceResult) -> some View {
        let verdict = PathVerdict.judge(t, baseline: baseline)
        return VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: "Latest path to \(t.target)", icon: "point.topleft.down.to.point.bottomright.curvepath", color: .teal,
                      subtitle: "\(Fmt.dateTime.string(from: t.ts)) · \(t.hops.count) hops\(t.reached ? "" : " · destination didn't answer")")
            if let v = verdict {
                Label(v.text, systemImage: v.slow ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.callout.weight(.medium)).foregroundStyle(v.slow ? .orange : .green)
            }
            // Segment bar
            GeometryReader { g in
                let total = max(1, t.totalMs ?? t.ispMs ?? t.localMs ?? 1)
                let parts: [(String, Double, Color)] = [("Home", t.localMs ?? 0, .green), ("ISP", t.ispAdded ?? 0, .orange), ("Internet", t.upstreamAdded ?? 0, .pink)]
                HStack(spacing: 2) {
                    ForEach(parts, id: \.0) { name, v, c in
                        if v > 0 {
                            RoundedRectangle(cornerRadius: 6).fill(Theme.gradient(c))
                                .frame(width: max(40, g.size.width * v / total))
                                .overlay(Text("\(name) \(Fmt.ms(v))").font(.caption2.weight(.bold)).foregroundStyle(.white).lineLimit(1).minimumScaleFactor(0.6))
                        }
                    }
                }
            }
            .frame(height: 26)
            VStack(spacing: 0) {
                ForEach(t.hops) { h in
                    HStack(spacing: 10) {
                        Text("\(h.hop)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                        Circle().fill(segColor(h.segment)).frame(width: 8, height: 8)
                        Text(h.ip ?? "* no reply").font(.system(.callout, design: .monospaced)).foregroundStyle(h.ip == nil ? .tertiary : .primary)
                            .frame(width: 150, alignment: .leading)
                        Text(h.owner.map { "\($0)\(h.asn.map { " · AS\($0)" } ?? "")" } ?? (h.ip.map { IPClass.isPrivate($0) || IPClass.isCGNAT($0) ? "private address" : "" } ?? ""))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Text(h.segment).font(.caption2.weight(.semibold)).foregroundStyle(segColor(h.segment))
                        Text(Fmt.ms(h.rtt)).font(.callout.monospacedDigit()).frame(width: 80, alignment: .trailing)
                    }
                    .padding(.vertical, 4)
                    Divider().opacity(0.3)
                }
            }
        }
        .glassCard(tint: .teal)
    }

    private func segColor(_ s: String) -> Color { s == "Home" ? .green : s == "ISP" ? .orange : .pink }

    private func load() async {
        let f = m.filter
        let r = await Blocking.run { (Queries.traces(f), Queries.latestTrace(), Queries.ipv6History(f), Queries.identityHistory(f), Queries.traceBaseline()) }
        traces = r.0; trace = m.lastTrace ?? r.1; ipv6 = r.2; identity = r.3; baseline = r.4
    }
}
