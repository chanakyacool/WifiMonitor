import SwiftUI
import AppKit
import Charts

struct DevicesView: View {
    @EnvironmentObject var m: Monitor
    @State private var list: [Device] = []
    @State private var search = ""
    @State private var onlineOnly = false
    @State private var selection = Set<String>()
    @State private var renaming: Device?
    @State private var renameText = ""
    @State private var groupFilter = "All"
    @State private var tagging: [String]?
    @State private var tagText = ""
    @State private var scanning: Device?
    @State private var presence: [PresenceSession] = []
    @AppStorage("untrustedAlerts") private var untrustedAlerts = false
    static let presetGroups = ["Family", "Kids", "Guests", "IoT", "Work", "Media"]

    private var rows: [Device] {
        list.filter { d in
            (!onlineOnly || d.online) &&
            (groupFilter == "All" || (groupFilter == "Untrusted" ? !d.trusted : groupFilter == "No group" ? d.tag == nil : d.tag == groupFilter)) &&
            (search.isEmpty || [d.ip, d.mac, d.displayName, d.vendor, d.model, d.kind].compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(search) })
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            FilterBar()
            HStack {
                SectionHeader(title: "LAN Devices", subtitle: "Everyone on your network, discovered via ARP + subnet ping sweep")
                Button {
                    Task { await m.refreshDevices(sweep: true) }
                } label: {
                    Label(m.sweeping ? "Scanning…" : "Discover now", systemImage: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(.app(.mint))
                .disabled(m.sweeping)
            }

            if m.localNetworkBlocked {
                HStack {
                    IconBadge(icon: "network.slash", color: .orange, size: 34)
                    VStack(alignment: .leading) {
                        Text("Local Network access needed").font(.headline)
                        Text("macOS hides other devices' addresses until you allow WiFi Monitor in System Settings → Privacy & Security → Local Network.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Settings") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork") { NSWorkspace.shared.open(u) }
                    }
                    .buttonStyle(.app(.orange))
                }
                .glassCard(tint: .orange)
            }
            LazyVGrid(columns: kpiColumns, spacing: 12) {
                KPITile(title: "Seen in range", value: "\(list.count)", icon: "laptopcomputer.and.iphone", color: .blue)
                KPITile(title: "Online now", value: "\(list.filter(\.online).count)", subtitle: "seen in last 15 min", icon: "circle.fill", color: .green)
                KPITile(title: "Private (random) MACs", value: "\(list.filter(\.isPrivateMAC).count)", subtitle: "phones/tablets/laptops", icon: "eye.slash", color: .purple)
                KPITile(title: "New in range", value: "\(list.filter { $0.firstSeen >= m.filter.interval.from }.count)", icon: "sparkles", color: .orange)
                KPITile(title: "Identified", value: "\(list.filter { $0.nickname ?? $0.friendlyName ?? $0.mdnsName ?? $0.netbiosName ?? $0.hostname != nil }.count)",
                        subtitle: "have a real name", icon: "person.text.rectangle", color: .indigo)
                KPITile(title: "All-time known", value: "\(m.devices.count)", icon: "archivebox", color: .gray)
                KPITile(title: "Trusted", value: "\(list.filter(\.trusted).count)", subtitle: "\(list.filter { !$0.trusted && $0.online }.count) untrusted online",
                        icon: "checkmark.shield.fill", color: list.contains { !$0.trusted && $0.online } ? .orange : .green)
            }

            Banner(icon: "person.badge.shield.checkmark.fill", title: "Unknown-device alerts",
                   message: untrustedAlerts
                       ? "On — you'll be alerted when a device that isn't trusted joins (or returns after an hour away)."
                       : "Mark the devices you know as trusted, then get alerted whenever anything else joins your network.",
                   color: untrustedAlerts ? .green : .blue) {
                HStack {
                    Toggle("Alerts", isOn: $untrustedAlerts).toggleStyle(.switch)
                    Button { m.trustAllCurrent() } label: { Label("Trust all current", systemImage: "checkmark.seal") }
                        .buttonStyle(.appSecondary(.green))
                }
            }

            PresenceTimeline(sessions: presence, groupFilter: groupFilter)

            LazyVGrid(columns: cardColumns, alignment: .leading, spacing: 18) {
                ChartCard(title: "Devices by vendor", icon: "building.2.fill", color: .blue) {
                    RankedBars(groups: grouped { $0.vendor ?? "Unknown" }, value: { $0.rx }, label: { "\(Int($0))" }, limit: 10)
                }
                ChartCard(title: "Devices by type", icon: "square.grid.3x3.fill", color: .purple) {
                    RankedBars(groups: grouped { $0.kind ?? ($0.isPrivateMAC ? "Phone / laptop (private MAC)" : "Unclassified") },
                               value: { $0.rx }, label: { "\(Int($0))" }, limit: 10)
                }
            }

            ChartCard(title: "Device first-seen timeline", height: 160) {
                if list.isEmpty { EmptyChart() } else {
                    Chart(list) { d in
                        PointMark(x: .value("First seen", d.firstSeen), y: .value("Type", d.isPrivateMAC ? "Private MAC" : "Fixed MAC"))
                            .foregroundStyle(d.online ? .green : .gray)
                    }
                    .chartHover { proxy, loc in
                        guard let d = ChartHoverKit.nearestInPlot(list, proxy: proxy, at: loc, position: { d in
                            proxy.position(forX: d.firstSeen).flatMap { x in
                                proxy.position(forY: d.isPrivateMAC ? "Private MAC" : "Fixed MAC").map { CGPoint(x: x, y: $0) } }
                        }) else { return nil }
                        var tip = ChartTip(title: d.displayName, rows: [
                            .init(label: "First seen", value: ChartHoverKit.date(d.firstSeen), color: d.online ? .green : .gray),
                            .init(label: "Last seen", value: ChartHoverKit.date(d.lastSeen)),
                        ])
                        if let ip = d.ip { tip.rows.append(.init(label: "IP", value: ip)) }
                        tip.rows.append(.init(label: "MAC", value: d.mac))
                        return tip
                    }
                }
            }

            GroupBox {
                VStack(alignment: .leading) {
                    HStack {
                        TextField("Search name, IP, MAC, vendor…", text: $search).textFieldStyle(.roundedBorder).frame(width: 280)
                        Toggle("Online only", isOn: $onlineOnly)
                        Picker("Group", selection: $groupFilter) {
                            Text("All devices").tag("All")
                            Text("Untrusted").tag("Untrusted")
                            Text("No group").tag("No group")
                            Divider()
                            ForEach(allGroups, id: \.self) { Text($0).tag($0) }
                        }.frame(width: 200)
                    }
                    Table(rows, selection: $selection) {
                        TableColumn("") { d in Circle().fill(d.online ? .green : .gray.opacity(0.5)).frame(width: 8, height: 8).shadow(color: d.online ? .green : .clear, radius: 3) }.width(16)
                        TableColumn("Device") { d in
                            HStack(spacing: 8) {
                                IconBadge(icon: deviceIcon(d), color: deviceColor(d), size: 22)
                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(spacing: 4) {
                                        Text(d.displayName).fontWeight(.medium)
                                        Image(systemName: d.trusted ? "checkmark.shield.fill" : "questionmark.circle")
                                            .font(.caption).foregroundStyle(d.trusted ? Color.green : Color.orange)
                                            .help(d.trusted ? "Trusted" : "Not trusted")
                                    }
                                    if let k = d.kind ?? (d.ip == m.current?.gateway ? "Router" : nil) { Text(k).font(.caption2).foregroundStyle(.secondary) }
                                }
                            }
                        }.width(min: 180, ideal: 240)
                        TableColumn("IP address") { d in
                            HStack {
                                Text(d.ip ?? "—").font(.system(.body, design: .monospaced))
                                if d.ip == m.current?.gateway { Text("router").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1).background(Capsule().fill(.blue.opacity(0.25))) }
                            }
                        }
                        TableColumn("Group") { d in
                            if let t = d.tag { Chip(text: t, color: tagColor(t)) } else { Text("—").foregroundStyle(.tertiary) }
                        }.width(min: 70, ideal: 90)
                        TableColumn("Vendor / model") { d in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(d.vendor ?? "—")
                                if let model = d.model { Text(model).font(.caption2).foregroundStyle(.secondary) }
                            }
                        }
                        TableColumn("MAC address") { Text($0.mac).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
                        TableColumn("Names seen") { d in
                            Text(namesSeen(d)).font(.caption).foregroundStyle(.secondary)
                        }
                        TableColumn("Open ports") { d in
                            Text(d.openPorts ?? "not scanned").font(.caption).foregroundStyle(d.openPorts == nil ? Color.gray : Color.secondary).lineLimit(2)
                        }
                        TableColumn("First seen") { Text(Fmt.dateTime.string(from: $0.firstSeen)) }
                        TableColumn("Last seen") { Text(Fmt.dateTime.string(from: $0.lastSeen)) }
                    }
                    .contextMenu(forSelectionType: String.self) { macs in
                        if let mac = macs.first, let d = list.first(where: { $0.mac == mac }) {
                            Button("Rename “\(d.displayName)”…") { renameText = d.nickname ?? ""; renaming = d }
                            if d.nickname != nil { Button("Clear nickname") { m.setNickname(mac, nil) } }
                            Button("Copy MAC address") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(mac, forType: .string) }
                            if d.ip != nil { Button("Scan open ports…") { scanning = d } }
                        }
                        if !macs.isEmpty {
                            Divider()
                            let sel = Array(macs)
                            let allTrusted = sel.allSatisfy { mac in list.first { $0.mac == mac }?.trusted == true }
                            Button(allTrusted ? "Remove from trusted" : "Mark as trusted") { m.setTrusted(sel, !allTrusted) }
                            Menu("Group") {
                                ForEach(allGroups, id: \.self) { g in Button(g) { m.setTag(sel, g) } }
                                Divider()
                                Button("New group…") { tagText = ""; tagging = sel }
                                Button("Remove from group") { m.setTag(sel, nil) }
                            }
                        }
                    } primaryAction: { macs in
                        if let mac = macs.first, let d = list.first(where: { $0.mac == mac }) { renameText = d.nickname ?? ""; renaming = d }
                    }
                    .frame(minHeight: 400)
                }
            } label: { Label("Devices (\(rows.count)) · double-click to rename · right-click for groups, trust and port scan", systemImage: "list.bullet") }
        }
        .dashboardPage()
        .sheet(item: $renaming) { d in
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    IconBadge(icon: deviceIcon(d), color: deviceColor(d), size: 32)
                    VStack(alignment: .leading) {
                        Text("Rename device").font(.title3.weight(.bold))
                        Text("\(d.ip ?? "") · \(d.mac) · \(d.vendor ?? "unknown vendor")").font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField("Nickname", text: $renameText, prompt: Text(d.displayName)).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { renaming = nil }.keyboardShortcut(.cancelAction).buttonStyle(.appSecondary(.gray))
                    Button("Save") { m.setNickname(d.mac, renameText); renaming = nil }.keyboardShortcut(.defaultAction).buttonStyle(.app(.mint))
                }
            }
            .padding(22).frame(width: 420)
        }
        .sheet(isPresented: Binding(get: { tagging != nil }, set: { if !$0 { tagging = nil } })) {
            VStack(alignment: .leading, spacing: 14) {
                Text("New group").font(.title3.weight(.bold))
                TextField("Group name (e.g. Kids, IoT, Guests)", text: $tagText).textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { tagging = nil }.keyboardShortcut(.cancelAction).buttonStyle(.appSecondary(.gray))
                    Button("Save") { if let t = tagging { m.setTag(t, tagText) }; tagging = nil }
                        .keyboardShortcut(.defaultAction).buttonStyle(.app(.mint)).disabled(tagText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }.padding(22).frame(width: 380)
        }
        .sheet(item: $scanning) { d in PortScanSheet(device: d) }
        .task(id: ReloadKey(filter: m.filter, version: m.dataVersion &+ m.devices.count)) {
            let f = m.filter
            let r = await Blocking.run { (Queries.devices(f), Queries.presence(f)) }
            list = r.0; presence = r.1
        }
    }

    private func namesSeen(_ d: Device) -> String {
        var parts: [String] = []
        if let n = d.mdnsName { parts.append("Bonjour: \(n)") }
        if let n = d.netbiosName { parts.append("NetBIOS: \(n)") }
        if let n = d.hostname { parts.append("DNS: \(n)") }
        return parts.joined(separator: " · ")
    }

    private var allGroups: [String] {
        var g = Self.presetGroups
        for t in m.devices.compactMap(\.tag) where !g.contains(t) { g.append(t) }
        return g
    }

    private func tagColor(_ t: String) -> Color {
        switch t {
        case "Kids": return .pink
        case "Guests": return .orange
        case "IoT": return .teal
        case "Work": return .indigo
        case "Family": return .green
        case "Media": return .purple
        default: return .blue
        }
    }

    private func grouped(_ key: (Device) -> String) -> [UsageGroup] {
        Dictionary(grouping: list, by: key).map { UsageGroup(name: $0.key, rx: Double($0.value.count), tx: 0) }.sorted { $0.rx > $1.rx }
    }

    private func deviceIcon(_ d: Device) -> String {
        if d.ip == m.current?.gateway { return "wifi.router.fill" }
        let k = (d.kind ?? "").lowercased(), v = (d.vendor ?? "").lowercased(), n = d.displayName.lowercased()
        if k.contains("tv") || k.contains("chromecast") || n.contains("tv") { return "tv.fill" }
        if k.contains("printer") { return "printer.fill" }
        if k.contains("speaker") || k.contains("airplay") { return "hifispeaker.fill" }
        if k.contains("homekit") || k.contains("matter") { return "homekit" }
        if k.contains("computer") || n.contains("macbook") || n.contains("imac") || n.contains("pc") { return "desktopcomputer" }
        if n.contains("iphone") || n.contains("pixel") || n.contains("galaxy") || d.isPrivateMAC { return "iphone" }
        if n.contains("ipad") { return "ipad" }
        if v.contains("apple") { return "applelogo" }
        if v.contains("raspberry") { return "cpu.fill" }
        return "network"
    }

    private func deviceColor(_ d: Device) -> Color {
        let colors: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .cyan, .mint]
        return d.ip == m.current?.gateway ? .indigo : colors[abs(d.mac.hashValue) % colors.count]
    }
}

/// "Who was home and when": one bar per presence session, one row per device.
struct PresenceTimeline: View {
    let sessions: [PresenceSession]
    var groupFilter = "All"

    var body: some View {
        let filtered = sessions.filter { groupFilter == "All" || groupFilter == "Untrusted" || groupFilter == "No group" ? true : $0.tag == groupFilter }
        let byDevice = Dictionary(grouping: filtered, by: \.mac)
        let top = byDevice.map { ($0.key, $0.value.reduce(0) { $0 + $1.end.timeIntervalSince($1.start) }) }
            .sorted { $0.1 > $1.1 }.prefix(24).map(\.0)
        let shown = filtered.filter { top.contains($0.mac) }
        let names = top.compactMap { mac in byDevice[mac]?.first?.name }
        ChartCard(title: "Presence timeline", subtitle: "who was on the network and when · top \(top.count) devices",
                  icon: "person.2.badge.gearshape.fill", color: .mint, height: max(160, CGFloat(top.count) * 22 + 40)) {
            if shown.isEmpty {
                EmptyChart(text: "Presence history builds up as devices are discovered")
            } else {
                Chart(shown) { s in
                    BarMark(xStart: .value("From", s.start), xEnd: .value("To", s.end), y: .value("Device", s.name), height: .ratio(0.6))
                        .foregroundStyle(by: .value("Group", s.tag ?? "No group"))
                        .cornerRadius(4)
                }
                .chartYScale(domain: names)
                .chartLegend(position: .top, alignment: .leading)
                .chartHover { proxy, loc in
                    guard let name: String = proxy.value(atY: loc.y), let d: Date = proxy.value(atX: loc.x) else { return nil }
                    let mine = shown.filter { $0.name == name }
                    guard let s = mine.first(where: { $0.start <= d && d <= $0.end }) else {
                        return ChartTip(title: name, rows: [.init(label: "At \(Fmt.time.string(from: d))", value: "offline")])
                    }
                    return ChartTip(title: name, rows: [
                        .init(label: "From", value: ChartHoverKit.date(s.start)),
                        .init(label: "To", value: ChartHoverKit.date(s.end)),
                        .init(label: "Duration", value: Fmt.duration(s.end.timeIntervalSince(s.start))),
                        .init(label: "Group", value: s.tag ?? "No group"),
                    ], guideX: loc.x)
                }
            }
        }
    }
}

/// Opt-in TCP port scan of one device.
struct PortScanSheet: View {
    let device: Device
    @EnvironmentObject var m: Monitor
    @Environment(\.dismiss) private var dismiss
    @State private var confirmed = false
    @State private var running = false
    @State private var progress = 0
    @State private var results: [PortResult]?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconBadge(icon: "door.left.hand.open", color: .orange, size: 32)
                VStack(alignment: .leading) {
                    Text("Port scan · \(device.displayName)").font(.title3.weight(.bold))
                    Text("\(device.ip ?? "") · \(device.mac)").font(.caption).foregroundStyle(.secondary)
                }
            }
            if results == nil && !running {
                Text("Checks \(PortScanner.common.count) well-known TCP ports (web admin, SSH, SMB, printers, cameras, Telnet, databases…) and grabs a short banner from anything that answers. Only scan devices you own or manage — some security software logs port scans.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("This is my device / I have permission to scan it", isOn: $confirmed)
            }
            if running {
                ProgressView(value: Double(progress), total: Double(PortScanner.common.count)) {
                    Text("Scanning… \(progress)/\(PortScanner.common.count)")
                }
            }
            if let results {
                if results.isEmpty {
                    Label("No open ports found — nothing is listening on the common ports.", systemImage: "checkmark.shield.fill").foregroundStyle(.green)
                } else {
                    Table(results) {
                        TableColumn("Port") { Text("\($0.port)").monospacedDigit() }.width(60)
                        TableColumn("Service") { r in
                            HStack {
                                Text(r.service)
                                if [23, 21, 2375, 5555, 6379, 11211, 27017].contains(r.port) { Chip(text: "risky", icon: "exclamationmark.triangle.fill", color: .red) }
                            }
                        }
                        TableColumn("Banner") { Text($0.banner ?? "—").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                        TableColumn("Connect") { Text(Fmt.ms($0.latency)) }.width(80)
                    }
                    .frame(minHeight: 220)
                }
            }
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(.appSecondary(.gray))
                Button(results == nil ? "Start scan" : "Scan again") { start() }
                    .buttonStyle(.app(.orange)).disabled(!confirmed || running || device.ip == nil)
            }
        }
        .padding(22).frame(width: 620)
    }

    private func start() {
        guard let ip = device.ip else { return }
        running = true; progress = 0; results = nil
        Task {
            let r = await Blocking.run {
                PortScanner.scan(ip) { n in DispatchQueue.main.async { progress = n } }
            }
            results = r
            running = false
            m.savePortScan(device.mac, r)
        }
    }
}
