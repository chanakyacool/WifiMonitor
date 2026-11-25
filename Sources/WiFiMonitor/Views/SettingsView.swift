import SwiftUI
import AppKit
import ServiceManagement
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject var m: Monitor
    @AppStorage("sampleInterval") private var sampleInterval = 5.0
    @AppStorage("scanInterval") private var scanInterval = 120.0
    @AppStorage("sweepInterval") private var sweepInterval = 600.0
    @AppStorage("appUsageInterval") private var appUsageInterval = 60.0
    @AppStorage("speedTestInterval") private var speedTestInterval = 0.0
    @AppStorage("retentionDays") private var retentionDays = 90.0
    @AppStorage("pingHost1") private var pingHost1 = "1.1.1.1"
    @AppStorage("pingHost2") private var pingHost2 = "8.8.8.8"
    @AppStorage("dnsTestHost") private var dnsTestHost = "www.apple.com"
    @AppStorage("lowRssi") private var lowRssi = -75.0
    @AppStorage("highLatency") private var highLatency = 150.0
    @AppStorage("notifications") private var notifications = true
    @AppStorage("capEnabled") private var capEnabled = false
    @AppStorage("capGB") private var capGB = 100.0
    @AppStorage("capResetDay") private var capResetDay = 1
    @AppStorage("capScope") private var capScope = "mac"
    @AppStorage("traceInterval") private var traceInterval = 900.0
    @AppStorage("ipv6Interval") private var ipv6Interval = 60.0
    @AppStorage("identityInterval") private var identityInterval = 300.0
    @AppStorage("connInterval") private var connInterval = 300.0
    @AppStorage("untrustedAlerts") private var untrustedAlerts = false
    @AppStorage("asnLookups") private var asnLookups = true
    @AppStorage("menuBarSpeed") private var menuBarSpeed = "both"
    @AppStorage("uiMode") private var uiMode = "simple"
    private var advanced: Bool { uiMode == "advanced" }

    @State private var counts: [(String, Int)] = []
    @State private var dbSize: Int64 = 0
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmClear = false
    @State private var exportTable = "samples"
    @State private var message: String?

    private var cycleText: String {
        _ = capResetDay   // recompute when the day changes
        let c = DataCap.cycle()
        let f = DateFormatter(); f.dateFormat = "d MMM"
        return "\(f.string(from: c.start)) → \(f.string(from: c.end.addingTimeInterval(-86400)))"
    }

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: $uiMode) {
                    Text("Simple").tag("simple")
                    Text("Advanced").tag("advanced")
                }
                .pickerStyle(.segmented)
                Text(advanced
                     ? "Advanced: every page and setting — signal & latency charts, roaming/RF, traceroute paths, watch targets, nearby networks, collection intervals, probes and CSV export."
                     : "Simple: just what most people need — is the internet OK, how much data was used, who is on the network, speed tests, outages and NetworkGPT. Switch to Advanced any time; everything keeps being recorded in the background either way.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: { Text("Experience") }

            NetworkGPTSettingsSection()

            if advanced {
            Section("Collection") {
                Picker("Sample Wi-Fi & latency every", selection: $sampleInterval) {
                    ForEach([2.0, 5, 10, 15, 30, 60], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                Picker("Scan nearby networks every", selection: $scanInterval) {
                    Text("Off").tag(0.0)
                    ForEach([30.0, 60, 120, 300, 600, 1800], id: \.self) { Text(label($0)).tag($0) }
                }
                Picker("Discover LAN devices every", selection: $sweepInterval) {
                    Text("Off (ARP cache only)").tag(0.0)
                    ForEach([300.0, 600, 1800, 3600], id: \.self) { Text(label($0)).tag($0) }
                }
                Picker("Record per-app usage every", selection: $appUsageInterval) {
                    Text("Off").tag(0.0)
                    ForEach([30.0, 60, 300], id: \.self) { Text(label($0)).tag($0) }
                }
                Picker("Automatic speed test", selection: $speedTestInterval) {
                    Text("Manual only").tag(0.0)
                    ForEach([30.0, 60, 180, 360, 720, 1440], id: \.self) { Text("every \(label($0 * 60))").tag($0) }
                }
            }

            Section("Path, IPv6 & identity") {
                Picker("Traceroute to ping target 1 every", selection: $traceInterval) {
                    Text("Off").tag(0.0)
                    ForEach([300.0, 600, 900, 1800, 3600], id: \.self) { Text(label($0)).tag($0) }
                }
                Picker("Check IPv6 every", selection: $ipv6Interval) {
                    Text("Off").tag(0.0)
                    ForEach([30.0, 60, 300, 600], id: \.self) { Text(label($0)).tag($0) }
                }
                Picker("Check public IP & captive portal every", selection: $identityInterval) {
                    Text("Off").tag(0.0)
                    ForEach([60.0, 300, 900, 3600], id: \.self) { Text(label($0)).tag($0) }
                }
                Picker("Snapshot per-app connections every", selection: $connInterval) {
                    Text("Off").tag(0.0)
                    ForEach([60.0, 300, 900], id: \.self) { Text(label($0)).tag($0) }
                }
                Toggle("Look up ISP / network owner names (DNS query to Team Cymru)", isOn: $asnLookups)
                Toggle("Alert when an untrusted device joins the network", isOn: $untrustedAlerts)
            }

            Section("Probes") {
                TextField("Internet ping target 1", text: $pingHost1)
                TextField("Internet ping target 2", text: $pingHost2)
                TextField("DNS test hostname", text: $dnsTestHost)
            }

            } // advanced: collection, path, probes

            Section("Billing cycle & data cap") {
                Picker("Monthly plan starts on day", selection: $capResetDay) { ForEach(1...28, id: \.self) { Text("\($0)").tag($0) } }
                Text("Current cycle: \(cycleText). Used by the \"This billing cycle\" / \"Last billing cycle\" ranges on every dashboard, the Data Usage page and the data cap.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Track a monthly data cap", isOn: $capEnabled)
                if capEnabled {
                    HStack {
                        Text("Cap")
                        TextField("", value: $capGB, format: .number).frame(width: 90).multilineTextAlignment(.trailing)
                        Text("GB")
                    }
                    Picker("Count", selection: $capScope) {
                        Text("This Mac's Wi-Fi traffic").tag("mac")
                        Text("Whole network (needs router integration)").tag("network")
                    }
                    Text("Notifies at 50%, 80% and 100% of the cap.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .onChange(of: capEnabled) { _, _ in Task { await m.checkDataCap() } }
            .onChange(of: capGB) { _, _ in Task { await m.checkDataCap() } }
            .onChange(of: capResetDay) { _, _ in m.dataVersion += 1; Task { await m.checkDataCap() } }
            .onChange(of: capScope) { _, _ in Task { await m.checkDataCap() } }

            Section("Alerts") {
                Toggle("macOS notifications for disconnects, outages, weak signal, new devices", isOn: $notifications)
                if advanced {
                HStack {
                    Text("Low signal threshold")
                    Slider(value: $lowRssi, in: -90 ... -55, step: 1)
                    Text("\(Int(lowRssi)) dBm").monospacedDigit().frame(width: 70)
                }
                HStack {
                    Text("High latency threshold")
                    Slider(value: $highLatency, in: 30...500, step: 10)
                    Text("\(Int(highLatency)) ms").monospacedDigit().frame(width: 70)
                }
                }
            }

            Section("App") {
                Picker("Menu bar speed", selection: $menuBarSpeed) {
                    Text("Upload and download").tag("both")
                    Text("Busier direction only").tag("busier")
                    Text("Off (bolt only)").tag("off")
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { message = "Launch at login failed: \(error.localizedDescription) (install the app in /Applications first)" }
                    }
                HStack {
                    Text("Location permission (for SSID/BSSID)")
                    Spacer()
                    Text(m.locationAuthorized ? "Granted" : "Not granted").foregroundStyle(m.locationAuthorized ? .green : .orange)
                    if !m.locationAuthorized { Button("Grant…") { m.requestLocation() }.buttonStyle(.app(.orange)) }
                }
            }

            Section("Local database") {
                LabeledContent("Location") {
                    Text(Database.shared.url.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
                LabeledContent("Size", value: Fmt.bytes(Double(dbSize)))
                if advanced { ForEach(counts, id: \.0) { c in LabeledContent(c.0, value: "\(c.1) rows") } }
                Picker("Keep history for", selection: $retentionDays) {
                    ForEach([7.0, 30, 90, 180, 365, 3650], id: \.self) { Text($0 >= 3650 ? "Forever (10 y)" : "\(Int($0)) days").tag($0) }
                }
                HStack {
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Database.shared.url]) }.buttonStyle(.appSecondary(.blue))
                    Button("Back up database…") { backup() }.buttonStyle(.appSecondary(.blue))
                    Spacer()
                    Button("Delete all data…", role: .destructive) { confirmClear = true }.buttonStyle(.app(.red))
                }
            }

            if advanced {
            Section("Export (uses the current dashboard filter)") {
                HStack {
                    Picker("Table", selection: $exportTable) {
                        ForEach(["samples", "events", "scans", "speedtests", "devices", "app_usage", "router_stats", "target_results"], id: \.self) { Text($0) }
                    }.frame(width: 260)
                    Button("Export CSV…") { export() }.buttonStyle(.app(.blue))
                }
                Text("Filter: \(m.filter.preset.rawValue)\(m.filter.ssid.map { " · \($0)" } ?? "")\(m.filter.band.map { " · \($0)" } ?? "")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            }

            if let message { Section { Text(message).foregroundStyle(.secondary) } }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .task(id: m.dataVersion) { await refreshStats() }
        .confirmationDialog("Delete all recorded data?", isPresented: $confirmClear) {
            Button("Delete everything", role: .destructive) { m.clearAllData(); Task { await refreshStats() } }
        } message: { Text("This permanently removes all samples, scans, events, speed tests, devices and usage history.") }
    }

    private func label(_ s: Double) -> String {
        s >= 3600 ? "\(Int(s / 3600)) h" : s >= 60 ? "\(Int(s / 60)) min" : "\(Int(s)) s"
    }

    private func refreshStats() async {
        let r = await Blocking.run { (Queries.tableCounts(), Database.shared.fileSize) }
        counts = r.0; dbSize = r.1
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "wifi-\(exportTable)-\(Int(Date().timeIntervalSince1970)).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let f = m.filter, table = exportTable
        Task {
            let err = await Blocking.run { () -> String? in
                do { try Queries.exportCSV(table: table, f, to: url); return nil } catch { return error.localizedDescription }
            }
            message = err.map { "Export failed: \($0)" } ?? "Exported \(table) to \(url.path)"
        }
    }

    private func backup() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "wifi-backup-\(Int(Date().timeIntervalSince1970)).sqlite"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.path.replacingOccurrences(of: "'", with: "''")
        Database.shared.exec("VACUUM INTO '\(path)';")
        message = FileManager.default.fileExists(atPath: url.path) ? "Backup saved to \(url.path)" : "Backup failed"
    }
}

struct MenuBarView: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let c = m.current
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: m.menuIcon).font(.system(size: 24, weight: .bold))
                VStack(alignment: .leading, spacing: 2) {
                    Text(c?.connected == true ? (c?.ssid ?? "Connected") : "Not connected").font(.system(.headline, design: .rounded))
                    Text(m.internetUp ? "Online · \(SignalQuality(rssi: c?.rssi).rawValue) signal" : "Internet unreachable").font(.caption).opacity(0.85)
                }
                Spacer()
                Text(Fmt.dbm(c?.rssi)).font(.system(.title3, design: .rounded).weight(.heavy)).monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(LinearGradient(
                colors: m.internetUp && c?.connected == true
                    ? [Color(red: 0.16, green: 0.36, blue: 0.95), Color(red: 0.45, green: 0.25, blue: 0.95), Color(red: 0.05, green: 0.72, blue: 0.85)]
                    : [Color(red: 0.80, green: 0.15, blue: 0.25), Color(red: 0.55, green: 0.10, blue: 0.45)],
                startPoint: .topLeading, endPoint: .bottomTrailing)))
            Divider()
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                row("Signal", "\(Fmt.dbm(c?.rssi)) · \(SignalQuality(rssi: c?.rssi).rawValue)")
                row("SNR", Fmt.db(c?.snr))
                row("Channel", "\(c?.channel.map(String.init) ?? "—") · \(c?.band ?? "—")")
                row("Link rate", Fmt.mbps(c?.txRate))
                row("Router", Fmt.ms(c?.gwLatency))
                row("Internet", Fmt.ms(c?.inetLatency))
                row("DNS", Fmt.ms(c?.dnsLatency))
                row("↓ / ↑", "\(Fmt.bps(c?.rxBps)) / \(Fmt.bps(c?.txBps))")
                row("Session data", Fmt.bytes(Double(m.sessionRx + m.sessionTx)))
                row("IP", c?.ip ?? "—")
                if let cap = m.capStatus { row("Data cap", String(format: "%.0f%% · %@ left", cap.fraction * 100, Fmt.bytes(max(0, cap.cap - cap.used)))) }
                let down = m.targets.filter { m.targetLatest[$0.id]?.ok == false }
                if !m.targets.isEmpty { row("Targets", down.isEmpty ? "all \(m.targets.count) up" : "\(down.count) down: \(down.map(\.name).joined(separator: ", "))") }
            }
            .font(.callout)
            Divider()
            HStack {
                Button("Open Dashboard") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .buttonStyle(.app(.blue))
                SpeedTestButton().buttonStyle(.app(.pink))
                WiFiNetworksButton(title: "Wi-Fi").buttonStyle(.app(.cyan))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.appSecondary(.gray))
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).monospacedDigit()
        }
    }
}
