import SwiftUI
import AppKit

@main
struct WiFiMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var monitor = Monitor.shared

    init() {
        if CommandLine.arguments.contains("--selftest") { SelfTest.run(); exit(0) }
    }

    var body: some Scene {
        Window("WiFi Monitor", id: "main") {
            ContentView()
                .environmentObject(monitor)
                .frame(minWidth: 1100, minHeight: 700)
        }
        .defaultSize(width: 1400, height: 900)

        Window("Speed Test", id: "speedtest") {
            SpeedTestPopup().environmentObject(monitor)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Wi-Fi Networks", id: "wifipicker") {
            WiFiPickerPopup().environmentObject(monitor)
        }
        .defaultSize(width: 560, height: 640)
        .defaultPosition(.center)

        MenuBarExtra {
            MenuBarView().environmentObject(monitor)
        } label: {
            MenuBarLabel().environmentObject(monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in Monitor.shared.start() }
    }

    /// Set by the always-alive menu bar label so the delegate can reopen the SwiftUI dashboard window.
    @MainActor static var openMain: (() -> Void)?

    /// Dock icon clicked: bring the dashboard back if it was closed or minimised
    /// (SwiftUI doesn't do this reliably when the app also has a menu bar item or a popup window open).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        let main = sender.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
        if let main, main.isVisible {
            main.makeKeyAndOrderFront(nil)
        } else if let main, main.isMiniaturized {
            main.deminiaturize(nil)
        } else if let open = Self.openMain {
            open()
        } else {
            return true
        }
        sender.activate(ignoringOtherApps: true)
        return false
    }

    /// Keep monitoring in the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

enum Page: String, CaseIterable, Identifiable {
    case live = "Live"
    case overview = "Overview"
    case quality = "Signal & Latency"
    case usage = "Data Usage"
    case nearby = "Nearby Networks"
    case devices = "LAN Devices"
    case speed = "Speed Tests"
    case events = "Events & Outages"
    case router = "Router"
    case gpt = "NetworkGPT"
    case targets = "Watch Targets"
    case paths = "Path & Internet"
    case roaming = "Roaming & RF"
    case settings = "Settings & Data"

    var id: String { rawValue }
    /// Pages for power users; hidden in Simple mode.
    var isAdvanced: Bool { [.quality, .roaming, .paths, .targets, .nearby].contains(self) }
    var icon: String {
        switch self {
        case .live: return "waveform.path.ecg"
        case .overview: return "square.grid.2x2"
        case .quality: return "cellularbars"
        case .usage: return "chart.bar.fill"
        case .nearby: return "antenna.radiowaves.left.and.right"
        case .devices: return "laptopcomputer.and.iphone"
        case .speed: return "speedometer"
        case .events: return "bell.badge.fill"
        case .router: return "wifi.router.fill"
        case .gpt: return "sparkles"
        case .targets: return "scope"
        case .paths: return "point.topleft.down.to.point.bottomright.curvepath"
        case .roaming: return "arrow.triangle.swap"
        case .settings: return "gearshape.fill"
        }
    }
    var color: Color {
        switch self {
        case .live: return .green
        case .overview: return .blue
        case .quality: return .purple
        case .usage: return .pink
        case .router: return .indigo
        case .gpt: return .purple
        case .targets: return .orange
        case .paths: return .teal
        case .roaming: return .purple
        case .nearby: return .cyan
        case .devices: return .mint
        case .speed: return .red
        case .events: return .yellow
        case .settings: return .gray
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var m: Monitor
    // `-startPage "Data Usage"` launch argument opens a specific page (used for smoke tests).
    @State private var page: Page? = Page(rawValue: UserDefaults.standard.string(forKey: "startPage") ?? "") ?? .live
    @AppStorage("uiMode") private var uiMode = "simple"
    private var advanced: Bool { uiMode == "advanced" }
    private func visible(_ pages: [Page]) -> [Page] { advanced ? pages : pages.filter { !$0.isAdvanced } }

    var body: some View {
        NavigationSplitView {
            List(selection: $page) {
                Section("Assistant") {
                    SidebarRow(page: .gpt).tag(Page.gpt)
                }
                Section("Monitor") {
                    ForEach(visible([Page.live, .overview, .quality, .roaming, .usage])) { p in SidebarRow(page: p).tag(p) }
                }
                Section("Network") {
                    ForEach(visible([Page.router, .devices, .speed, .events, .paths, .targets, .nearby])) { p in SidebarRow(page: p).tag(p) }
                }
                Section {
                    SidebarRow(page: .settings).tag(Page.settings)
                }
            }
            .onChange(of: uiMode) { _, _ in if let p = page, p.isAdvanced, !advanced { page = .live } }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .top) { SidebarBrand().padding(.horizontal, 14).padding(.top, 6) }
            .safeAreaInset(edge: .bottom) { SidebarStatus().padding(10) }
        } detail: {
            switch page ?? .live {
            case .live: LiveView()
            case .overview: OverviewView()
            case .quality: QualityView()
            case .usage: UsageView()
            case .nearby: NearbyView()
            case .devices: DevicesView()
            case .speed: SpeedView()
            case .events: EventsView()
            case .router: RouterView()
            case .gpt: NetworkGPTView()
            case .targets: TargetsView()
            case .paths: PathsView()
            case .roaming: RoamingView()
            case .settings: SettingsView()
            }
        }
        .navigationTitle(page?.rawValue ?? "WiFi Monitor")
        .groupBoxStyle(GlassGroupBoxStyle())
        .onAppear {
            // `-speedTestOnLaunch YES` opens the speed-test popup and starts a test (used for smoke tests).
            if UserDefaults.standard.bool(forKey: "speedTestOnLaunch") {
                openWindow(id: "speedtest")
                Task { await m.runSpeedTest() }
            }
        }
    }
    @Environment(\.openWindow) private var openWindow
}

struct SidebarRow: View {
    let page: Page
    var body: some View {
        Label {
            Text(page.rawValue)
        } icon: {
            RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.gradient(page.color))
                .frame(width: 22, height: 22)
                .overlay(Image(systemName: page.icon).font(.system(size: 11, weight: .bold)).foregroundStyle(.white))
        }
        .padding(.vertical, 2)
    }
}

struct SidebarBrand: View {
    @AppStorage("uiMode") private var uiMode = "simple"
    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 0) {
                Text("WiFi Monitor").font(.system(.headline, design: .rounded).weight(.bold))
                Text(uiMode == "advanced" ? "Advanced mode" : "Simple mode").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 6)
    }
}

struct SidebarStatus: View {
    @EnvironmentObject var m: Monitor
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().fill(statusColor.opacity(0.25)).frame(width: 22, height: 22)
                Circle().fill(statusColor).frame(width: 10, height: 10).shadow(color: statusColor, radius: 4)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(m.current?.ssid ?? (m.current?.connected == true ? "Connected" : "Not connected"))
                    .font(.caption.weight(.semibold)).lineLimit(1)
                Text(m.internetUp ? "Internet OK · \(Fmt.ms(m.current?.inetLatency))" : "Internet down").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .glassCard(tint: statusColor, padding: 10)
    }
    var statusColor: Color {
        guard m.current?.connected == true else { return .red }
        return m.internetUp ? .green : .orange
    }
}

/// `WiFiMonitor --selftest` prints what each collector sees (handy for troubleshooting).
enum SelfTest {
    static func run() {
        Prefs.register()
        func t(_ label: String, _ f: () -> String) {
            let start = Date(); let r = f()
            print(String(format: "%-22@ %@  (%.0f ms)", label as NSString, r, Date().timeIntervalSince(start) * 1000))
        }
        let s = WiFiCollector.snapshot()
        t("Wi-Fi") { "\(s.ssid ?? "‹hidden›") \(s.bssid ?? "") rssi=\(s.rssi ?? 0) ch=\(s.channel ?? 0) \(s.band ?? "")" }
        let gw = NetUtil.defaultGateway() ?? "?"
        t("Gateway") { gw }
        t("ICMP socket") { Probe.socketICMPAvailable ? "available" : "unavailable (using /sbin/ping)" }
        t("Ping gateway") { Fmt.ms(Probe.ping(gw)) }
        t("Ping 1.1.1.1") { Fmt.ms(Probe.ping("1.1.1.1")) }
        t("DNS query") { Fmt.ms(NetUtil.dnsServers().first(where: { !$0.contains(":") }).flatMap { Probe.dnsQuery(server: $0, name: "www.apple.com") }) }
        t("Byte counters") { "\(NetUtil.byteCounters()[s.interface ?? "en0"].map { "rx=\($0.rx) tx=\($0.tx)" } ?? "none")" }
        if let a = NetUtil.ipv4(for: s.interface ?? "en0") {
            let hosts = NetUtil.subnetHosts(ip: a.ip, mask: a.mask)
            t("ICMP sweep") { "\(ICMP.sweep(hosts).count)/\(hosts.count) hosts replied" }
        }
        t("ARP table") {
            let all = NetUtil.arpTable()
            let raw = Shell.run("/usr/sbin/arp", ["-an"], timeout: 5)
            _ = raw
            return all.isEmpty ? "empty — grant Local Network access to WiFi Monitor" : "\(all.filter { $0.iface == (s.interface ?? "en0") }.count) entries"
        }
        t("OUI vendor DB") { OUI.isLoaded ? "loaded · gateway = \(NetUtil.arpTable().first { $0.ip == gw }.flatMap { OUI.vendor(for: $0.mac) } ?? "?")" : "missing" }
        t("mDNS (gateway)") { NameDiscovery.mdnsReverse(gw) ?? "no answer" }
        t("NetBIOS (gateway)") { NameDiscovery.netbios(gw) ?? "no answer" }
        t("SSDP sweep") {
            let r = NameDiscovery.ssdpSweep()
            return "\(r.count) devices" + (r.first.map { ": \($0.key) = \($0.value.name ?? "?") \($0.value.model ?? "")" } ?? "")
        }
        t("nettop") { "\(Probe.nettopSnapshot().count) processes" }
        t("Link / VPN") { let l = LinkInfo.state(wifiInterface: s.interface ?? "en0"); return "\(l.link) via \(l.primary ?? "-") · VPN \(l.vpn ?? "off") · ethernet \(l.ethernet)" }
        var pubASN: Int?, pubISP: String?
        t("Public IP / ISP") { let n = NetIdentity.snapshot(); pubASN = n.asn; pubISP = n.isp; return "\(n.publicIP ?? "-") · AS\(n.asn ?? 0) \(n.isp ?? "-") · captive=\(n.captive)" }
        t("IPv6") { let r = IPv6Probe.probe(iface: LinkInfo.primaryInterface() ?? "en0", dnsName: "www.apple.com"); return "has=\(r.hasV6) \(r.address ?? "") rtt=\(Fmt.ms(r.latency)) loss=\(Fmt.pct(r.loss)) dns=\(Fmt.ms(r.dnsLatency))" }
        t("Traceroute") {
            guard let r = Traceroute.run("1.1.1.1", publicASN: pubASN, publicISP: pubISP) else { return "failed" }
            let hops = r.hops.map { "\($0.hop):\($0.ip ?? "*")[\($0.segment)\($0.asn.map { " AS\($0)" } ?? "")]" }.joined(separator: " ")
            return "home \(Fmt.ms(r.localMs)) isp+\(Fmt.ms(r.ispAdded)) inet+\(Fmt.ms(r.upstreamAdded)) reached=\(r.reached)\n    \(hops)"
        }
        t("Connections") { let c = NetTop.connections(); return "\(c.count) · e.g. " + c.prefix(3).map { "\($0.app)→\($0.remote):\($0.port)" }.joined(separator: ", ") }
        t("nettop wired") { "\(NetTop.processBytes(link: "wired").count) processes" }
        t("Port scan gateway") { PortScanner.scan(gw).map { "\($0.port)/\($0.service)\($0.banner.map { " [\($0)]" } ?? "")" }.joined(separator: ", ") }
        let cfg = RouterClientService.Config(kind: .upnp, host: gw, username: "", password: "", community: "public", wanInterface: "", https: false)
        t("Router (UPnP)") {
            switch RouterClientService().poll(cfg) {
            case .success(let r): return "OK wanRx=\(r.wanRx.map(String.init) ?? "-") wanTx=\(r.wanTx.map(String.init) ?? "-") ip=\(r.externalIP ?? "-") link=\(r.linkStatus ?? "-")"
            case .failure(let e): return "✗ \(e.message)"
            }
        }
    }
}
