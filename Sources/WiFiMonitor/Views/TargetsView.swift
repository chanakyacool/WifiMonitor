import SwiftUI
import Charts

/// Your own status page: ping, TCP ports, HTTP(S) endpoints and TLS certificate expiry.
struct TargetsView: View {
    @EnvironmentObject var m: Monitor
    @State private var stats: [Int64: TargetStats] = [:]
    @State private var history: [Int64: [HistoryPoint]] = [:]
    @State private var editing: WatchTarget?
    @State private var adding = false

    private var upCount: Int { m.targets.filter { $0.enabled && m.targetLatest[$0.id]?.ok == true }.count }
    private var downCount: Int { m.targets.filter { $0.enabled && m.targetLatest[$0.id]?.ok == false }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .bottom) {
                SectionHeader(title: "Watch Targets", subtitle: "Your own status page: hosts, ports, websites and certificates you care about")
                Button { adding = true } label: { Label("Add target", systemImage: "plus.circle.fill") }
                    .buttonStyle(.app(.orange))
            }
            FilterBar(showNetworkFilters: false)

            LazyVGrid(columns: kpiColumns, spacing: 14) {
                KPITile(title: "Targets", value: "\(m.targets.count)", subtitle: "\(m.targets.filter(\.enabled).count) active", icon: "scope", color: .orange)
                KPITile(title: "Up", value: "\(upCount)", icon: "checkmark.circle.fill", color: .green)
                KPITile(title: "Down", value: "\(downCount)", icon: "xmark.octagon.fill", color: downCount > 0 ? .red : .gray)
                KPITile(title: "Avg uptime", value: Fmt.pct(avgUptime, digits: 2), subtitle: "in range", icon: "chart.line.uptrend.xyaxis", color: .blue)
                KPITile(title: "Soonest cert expiry", value: soonestCert.map { "\($0) days" } ?? "—", icon: "lock.shield.fill",
                        color: (soonestCert ?? 999) < certWarningDays ? .red : .purple)
            }

            if m.targets.isEmpty {
                Banner(icon: "scope", title: "No targets yet",
                       message: "Add your NAS, home server, a website, a game server or a certificate to get uptime, latency history and alerts.",
                       color: .orange) {
                    Button("Add target") { adding = true }.buttonStyle(.app(.orange))
                }
                HStack(spacing: 10) {
                    Text("Quick add:").foregroundStyle(.secondary)
                    quickAdd("Google DNS", .ping, "8.8.8.8")
                    quickAdd("Cloudflare", .http, "https://www.cloudflare.com")
                    quickAdd("Apple", .tls, "apple.com")
                    if let gw = m.current?.gateway { quickAdd("Router admin", .tcp, "\(gw):80") }
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 460), spacing: 18)], alignment: .leading, spacing: 18) {
                ForEach(m.targets) { t in targetCard(t) }
            }
        }
        .dashboardPage()
        .task(id: ReloadKey(filter: m.filter, version: m.dataVersion &+ m.targets.count &+ m.targetLatest.count)) { await load() }
        .sheet(isPresented: $adding) { TargetEditor(target: nil) { m.addTarget(name: $0.name, kind: $0.kind, target: $0.target, interval: $0.interval) } }
        .sheet(item: $editing) { t in TargetEditor(target: t) { m.updateTarget($0) } }
    }

    private var avgUptime: Double? {
        let v = stats.values.compactMap(\.uptime)
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }
    private var soonestCert: Int? { m.targets.compactMap { m.targetLatest[$0.id]?.certDaysLeft }.min() }

    private func quickAdd(_ name: String, _ kind: TargetKind, _ target: String) -> some View {
        Button { m.addTarget(name: name, kind: kind, target: target, interval: 60) } label: {
            Label(name, systemImage: kind.icon)
        }
        .buttonStyle(.appSecondary(.orange))
    }

    private func targetCard(_ t: WatchTarget) -> some View {
        let r = m.targetLatest[t.id]
        let st = stats[t.id]
        let color: Color = !t.enabled ? .gray : (r == nil ? .blue : (r!.ok ? .green : .red))
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconBadge(icon: t.kind.icon, color: color, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).font(.headline)
                    Text(t.target).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(!t.enabled ? "Paused" : (r == nil ? "Pending" : (r!.ok ? "Up" : "Down")))
                        .font(.caption.weight(.bold)).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Capsule().fill(color.opacity(0.2))).foregroundStyle(color)
                    if let r { Text(Fmt.time.string(from: r.ts)).font(.caption2).foregroundStyle(.secondary) }
                }
                Menu {
                    Button("Check now") { m.checkTargetNow(t.id) }
                    Button("Edit…") { editing = t }
                    Button(t.enabled ? "Pause" : "Resume") { var x = t; x.enabled.toggle(); m.updateTarget(x) }
                    Divider()
                    Button("Delete", role: .destructive) { m.deleteTarget(t.id) }
                } label: { Image(systemName: "ellipsis.circle").font(.title3) }
                .menuStyle(.borderlessButton).frame(width: 28)
            }

            HStack(spacing: 16) {
                stat("Latency", Fmt.ms(r?.latency))
                stat("Uptime", Fmt.pct(st?.uptime, digits: 2))
                stat("p95", Fmt.ms(st?.p95Latency))
                stat("Failures", "\(st?.failures ?? 0)")
                if let d = r?.certDaysLeft { stat("Cert", "\(d) d") }
            }

            let pts = (history[t.id] ?? []).compactMap { p in p.inet.map { SeriesPoint(date: p.date, value: $0, series: "Latency") } }
            if pts.isEmpty { EmptyChart(text: "Collecting data…").frame(height: 90) } else {
                Chart {
                    ForEach(pts) { p in
                        AreaMark(x: .value("t", p.date), y: .value("ms", p.value))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.45), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("t", p.date), y: .value("ms", p.value))
                            .foregroundStyle(color).interpolationMethod(.monotone).lineStyle(StrokeStyle(lineWidth: 2))
                        if pts.count < 6 { PointMark(x: .value("t", p.date), y: .value("ms", p.value)).foregroundStyle(color) }
                    }
                    ForEach(history[t.id] ?? []) { p in
                        if let up = p.up, up < 1 {
                            RuleMark(x: .value("t", p.date)).foregroundStyle(.red.opacity(0.35 + 0.5 * (1 - up))).lineStyle(StrokeStyle(lineWidth: 2))
                        }
                    }
                }
                .chartYAxisLabel("ms")
                .chartHover { proxy, loc in
                    guard let d: Date = proxy.value(atX: loc.x), let p = ChartHoverKit.nearest(pts, to: d, by: \.date) else { return nil }
                    let x = proxy.position(forX: p.date)
                    var tip = ChartTip(title: ChartHoverKit.date(p.date), rows: [.init(label: "Latency", value: Fmt.ms(p.value), color: color)], guideX: x)
                    if let up = (history[t.id] ?? []).first(where: { $0.date == p.date })?.up {
                        tip.rows.append(.init(label: "Up", value: Fmt.pct(up, digits: 0), color: up < 1 ? .red : nil))
                    }
                    if let x, let y = proxy.position(forY: p.value) { tip.dots = [(CGPoint(x: x, y: y), color)] }
                    return tip
                }
                .frame(height: 90)
            }
            if let d = r?.detail { Text(d).font(.caption).foregroundStyle(r?.ok == false ? .red : .secondary).lineLimit(2) }
        }
        .glassCard(tint: color)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
        }
    }

    private func load() async {
        let f = m.filter
        let ids = m.targets.map(\.id)
        let r = await Blocking.run { () -> ([Int64: TargetStats], [Int64: [HistoryPoint]]) in
            var s: [Int64: TargetStats] = [:], h: [Int64: [HistoryPoint]] = [:]
            for id in ids { s[id] = Queries.targetStats(id, f); h[id] = Queries.targetHistory(id, f) }
            return (s, h)
        }
        stats = r.0; history = r.1
    }
}

struct TargetEditor: View {
    let target: WatchTarget?
    let onSave: (WatchTarget) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: TargetKind = .http
    @State private var value = ""
    @State private var interval = 60.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                IconBadge(icon: kind.icon, color: .orange, size: 36)
                Text(target == nil ? "Add watch target" : "Edit target").font(.title2.weight(.bold))
            }
            Form {
                Picker("Check type", selection: $kind) { ForEach(TargetKind.allCases) { Text($0.title).tag($0) } }
                TextField("Target", text: $value, prompt: Text(kind.placeholder))
                TextField("Name", text: $name, prompt: Text("optional"))
                Picker("Check every", selection: $interval) {
                    ForEach([30.0, 60, 300, 900, 3600], id: \.self) { Text($0 >= 60 ? "\(Int($0 / 60)) min" : "\(Int($0)) s").tag($0) }
                }
            }
            .formStyle(.grouped)
            if kind == .tls { Text("Fails (and alerts) when the certificate expires within \(certWarningDays) days.").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.appSecondary(.gray))
                Button("Save") {
                    onSave(WatchTarget(id: target?.id ?? 0, name: name.isEmpty ? value : name, kind: kind,
                                       target: value.trimmingCharacters(in: .whitespaces), interval: interval, enabled: target?.enabled ?? true))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.app(.orange))
                .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            if let t = target { name = t.name; kind = t.kind; value = t.target; interval = t.interval }
        }
    }
}
