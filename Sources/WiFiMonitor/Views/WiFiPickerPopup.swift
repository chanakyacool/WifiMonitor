import SwiftUI
import AppKit
import CoreWLAN

// MARK: - Joining networks

enum WiFiSwitcher {
    /// Networks saved on this Mac (macOS "Known Networks"), so they can be joined without typing a password.
    static func savedNetworks(iface: String) -> Set<String> {
        let out = Shell.run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", iface], timeout: 5).output
        return Set(out.split(separator: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
    }

    /// Joins `ssid`. With no password, a saved network uses the password macOS already stores.
    /// Returns nil on success, otherwise a readable error. Call off the main thread.
    static func join(ssid: String, password: String?) -> String? {
        guard let i = CWWiFiClient.shared().interface(), let name = i.interfaceName else { return "No Wi-Fi interface found." }
        if !i.powerOn() { try? i.setPower(true) }
        let pw = (password?.isEmpty == false) ? password : nil

        if pw == nil, savedNetworks(iface: name).contains(ssid) {
            // networksetup looks up the saved password in the System keychain.
            let r = Shell.run("/usr/sbin/networksetup", ["-setairportnetwork", name, ssid], timeout: 30)
            if r.status == 0, !r.output.lowercased().contains("error"), !r.output.lowercased().contains("could not") {
                return waitFor(ssid, i) ? nil : "Couldn't join “\(ssid)”. macOS may need the password again."
            }
        }
        do {
            let found = try i.scanForNetworks(withName: ssid, includeHidden: true)
            guard let net = found.max(by: { $0.rssiValue < $1.rssiValue }) else { return "“\(ssid)” is no longer in range." }
            try i.associate(to: net, password: pw)
            return waitFor(ssid, i) ? nil : "Joined, but the connection didn't come up. Check the password."
        } catch {
            let e = error as NSError
            if pw == nil, net(needsPassword: e) { return "This network needs a password." }
            return "Couldn't join “\(ssid)”: \(e.localizedDescription)"
        }
    }

    private static func net(needsPassword e: NSError) -> Bool {
        e.localizedDescription.lowercased().contains("password") || e.code == -3900 || e.code == -3924
    }

    private static func waitFor(_ ssid: String, _ i: CWInterface) -> Bool {
        for _ in 0..<20 {
            if i.ssid() == ssid, i.rssiValue() != 0 { return true }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return i.ssid() == ssid
    }
}

// MARK: - Button + popup window

/// Opens the Wi-Fi networks popup and starts a scan.
struct WiFiNetworksButton: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.openWindow) private var openWindow
    var title = "Wi-Fi networks"
    var body: some View {
        Button {
            openWindow(id: "wifipicker")
            NSApp.activate(ignoringOtherApps: true)
        } label: { Label(title, systemImage: "wifi") }
    }
}

/// One row per network name (strongest access point), sorted by signal.
private struct NetworkEntry: Identifiable {
    var id: String { ssid }
    let ssid: String
    let best: ScanResult
    let apCount: Int
    let bands: [String]
}

struct WiFiPickerPopup: View {
    @EnvironmentObject var m: Monitor
    @State private var scanning = false
    @State private var saved: Set<String> = []
    @State private var joining: String?
    @State private var message: (ok: Bool, text: String)?
    @State private var passwordFor: NetworkEntry?
    @State private var password = ""
    @State private var showHidden = false

    private var entries: [NetworkEntry] {
        let groups = Dictionary(grouping: m.nearby.filter { showHidden || $0.ssid?.isEmpty == false }, by: { $0.displaySSID })
        return groups.compactMap { name, aps in
            guard let best = aps.max(by: { $0.rssi < $1.rssi }) else { return nil }
            return NetworkEntry(ssid: name, best: best, apCount: aps.count,
                                bands: Array(Set(aps.compactMap(\.band))).sorted())
        }
        .sorted { a, b in
            if isCurrent(a) != isCurrent(b) { return isCurrent(a) }
            return a.best.rssi > b.best.rssi
        }
    }

    private func isCurrent(_ e: NetworkEntry) -> Bool { m.current?.ssid == e.ssid && m.current?.connected == true }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if !m.locationAuthorized {
                LocationBanner().padding(12)
            }
            if let message {
                Label(message.text, systemImage: message.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(message.ok ? .green : .orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
            }
            if entries.isEmpty {
                VStack(spacing: 10) {
                    if scanning { ProgressView() } else { Image(systemName: "wifi.slash").font(.largeTitle).foregroundStyle(.secondary) }
                    Text(scanning ? "Scanning for networks…" : "No networks found yet").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(entries) { e in row(e) }
                    }
                    .padding(14)
                }
            }
            Divider().opacity(0.4)
            HStack {
                Toggle("Show hidden", isOn: $showHidden).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Text("Signal: Excellent ≥ −50 · Good ≥ −60 · Fair ≥ −70 · Weak ≥ −80 dBm").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 640)
        .background(AppBackground())
        .task { await rescan() }
        .sheet(item: $passwordFor) { e in passwordSheet(e) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            IconBadge(icon: "wifi", color: .cyan, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Wi-Fi Networks").font(.system(.title3, design: .rounded).weight(.bold))
                Text(m.lastScan.map { "\(entries.count) networks · scanned \(Fmt.time.string(from: $0))" } ?? "Scanning…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await rescan() } } label: {
                Label(scanning ? "Scanning…" : "Scan again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.app(.cyan))
            .disabled(scanning)
        }
        .padding(16)
    }

    // MARK: Row

    private func row(_ e: NetworkEntry) -> some View {
        let q = SignalQuality(rssi: e.best.rssi)
        let current = isCurrent(e)
        let open = e.best.security == "Open" || e.best.security == "None"
        return HStack(spacing: 12) {
            SignalBars(rssi: e.best.rssi).frame(width: 30, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(e.ssid).font(.body.weight(.semibold)).lineLimit(1)
                    if !open { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
                    if current { Chip(text: "Connected", color: .green) }
                    else if saved.contains(e.ssid) { Chip(text: "Saved", color: .blue) }
                }
                Text([e.bands.joined(separator: " + "), e.best.channel.map { "ch \($0)" }, e.best.security,
                      e.apCount > 1 ? "\(e.apCount) access points" : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(e.best.rssi) dBm").font(.callout.weight(.semibold)).monospacedDigit()
                Text(q.rawValue).font(.caption2.weight(.semibold)).foregroundStyle(q.color)
            }
            .frame(width: 74, alignment: .trailing)
            if current {
                Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(.green).frame(width: 64)
            } else if joining == e.ssid {
                ProgressView().controlSize(.small).frame(width: 64)
            } else {
                Button("Join") { tapJoin(e, open: open) }
                    .buttonStyle(.app(.cyan))
                    .disabled(joining != nil || e.ssid == "‹hidden›")
                    .frame(width: 64)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(current ? Color.green.opacity(0.10) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(current ? Color.green.opacity(0.4) : Color.primary.opacity(0.06)))
    }

    private func passwordSheet(_ e: NetworkEntry) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                IconBadge(icon: "lock.fill", color: .cyan, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Join “\(e.ssid)”").font(.headline)
                    Text(e.best.security).font(.caption).foregroundStyle(.secondary)
                }
            }
            SecureField("Password", text: $password).textFieldStyle(.roundedBorder).onSubmit { submitPassword(e) }
            Text("macOS saves the password in its keychain, as when you join from the menu bar.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { passwordFor = nil; password = "" }.keyboardShortcut(.cancelAction)
                Button("Join") { submitPassword(e) }.keyboardShortcut(.defaultAction).disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    // MARK: Actions

    private func rescan() async {
        scanning = true
        let iface = m.current?.interface ?? "en0"
        async let s: Set<String> = Blocking.run { WiFiSwitcher.savedNetworks(iface: iface) }
        await m.scanNearby()
        saved = await s
        scanning = false
    }

    private func tapJoin(_ e: NetworkEntry, open: Bool) {
        if open || saved.contains(e.ssid) { join(e.ssid, password: nil) }
        else { password = ""; passwordFor = e }
    }

    private func submitPassword(_ e: NetworkEntry) {
        let pw = password
        passwordFor = nil
        password = ""
        join(e.ssid, password: pw)
    }

    private func join(_ ssid: String, password: String?) {
        joining = ssid
        message = nil
        Task {
            let err = await Blocking.run { WiFiSwitcher.join(ssid: ssid, password: password) }
            joining = nil
            if let err {
                message = (false, err)
                if err.contains("needs a password"), let e = entries.first(where: { $0.ssid == ssid }) { passwordFor = e }
            } else {
                message = (true, "Connected to “\(ssid)”")
                await rescan()
            }
        }
    }
}

/// Four-bar Wi-Fi strength glyph coloured by quality.
struct SignalBars: View {
    let rssi: Int
    var body: some View {
        let q = SignalQuality(rssi: rssi)
        let lit: Int = { switch q { case .excellent: return 4; case .good: return 3; case .fair: return 2; case .weak: return 1; default: return 1 } }()
        GeometryReader { g in
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<4) { i in
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(i < lit ? q.color : Color.primary.opacity(0.15))
                        .frame(height: g.size.height * CGFloat(i + 1) / 4)
                }
            }
        }
    }
}
