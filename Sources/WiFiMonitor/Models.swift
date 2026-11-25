import Foundation
import SwiftUI

struct Sample: Identifiable {
    var id = UUID()
    var ts = Date()
    var connected = false
    var powerOn = false
    var interface: String?
    var ssid: String?
    var bssid: String?
    var rssi: Int?
    var noise: Int?
    var channel: Int?
    var band: String?
    var width: String?
    var phy: String?
    var txRate: Double?
    var txPower: Int?
    var security: String?
    var country: String?
    var mac: String?
    var ip: String?
    var gateway: String?
    var dns: String?
    var gwLatency: Double?
    var inetLatency: Double?
    var dnsLatency: Double?
    var loss: Double?
    var rxBps: Double?
    var txBps: Double?
    var rxBytes: Int64?
    var txBytes: Int64?
    /// Interface carrying the default route (en0, en7, utun3…) and what kind of link it is.
    var primaryIface: String?
    var link: String?          // "Wi-Fi", "Ethernet", "VPN", "Other"
    var vpn: String?           // name of the active VPN, if any
    var ethRxBytes: Int64?
    var ethTxBytes: Int64?

    var snr: Int? {
        guard let r = rssi, let n = noise, n != 0 else { return nil }
        return r - n
    }

    init() {}

    init(row r: Row) {
        ts = r.date("ts") ?? Date()
        connected = (r.int("connected") ?? 0) == 1
        powerOn = (r.int("power_on") ?? 0) == 1
        interface = r.string("interface"); ssid = r.string("ssid"); bssid = r.string("bssid")
        rssi = r.int("rssi"); noise = r.int("noise"); channel = r.int("channel")
        band = r.string("band"); width = r.string("width"); phy = r.string("phy")
        txRate = r.double("tx_rate"); txPower = r.int("tx_power")
        security = r.string("security"); country = r.string("country"); mac = r.string("mac")
        ip = r.string("ip"); gateway = r.string("gateway"); dns = r.string("dns")
        gwLatency = r.double("gw_latency"); inetLatency = r.double("inet_latency")
        dnsLatency = r.double("dns_latency"); loss = r.double("loss")
        rxBps = r.double("rx_bps"); txBps = r.double("tx_bps")
        rxBytes = r.int("rx_bytes").map(Int64.init); txBytes = r.int("tx_bytes").map(Int64.init)
        primaryIface = r.string("primary_iface"); link = r.string("link"); vpn = r.string("vpn")
        ethRxBytes = r.int("eth_rx_bytes").map(Int64.init); ethTxBytes = r.int("eth_tx_bytes").map(Int64.init)
    }
}

struct ScanResult: Identifiable, Hashable {
    var id: String { (bssid ?? "?") + "|" + (ssid ?? "") + "|\(channel ?? 0)" }
    var ts: Date
    var ssid: String?
    var bssid: String?
    var rssi: Int
    var noise: Int
    var channel: Int?
    var band: String?
    var width: String?
    var security: String
    var beaconInterval: Int
    var country: String?
    var seenCount: Int = 1

    var displaySSID: String { (ssid?.isEmpty == false) ? ssid! : "‹hidden›" }
}

struct Device: Identifiable, Hashable {
    var id: String { mac }
    var mac: String
    var ip: String?
    var hostname: String?
    var interface: String?
    var ssid: String?
    var firstSeen: Date
    var lastSeen: Date
    var vendor: String? = nil
    var mdnsName: String? = nil
    var netbiosName: String? = nil
    var friendlyName: String? = nil
    var model: String? = nil
    var kind: String? = nil
    var nickname: String? = nil
    var tag: String? = nil
    var trusted = false
    var openPorts: String? = nil
    var portsScanned: Date? = nil

    /// Best available human name: your nickname → UPnP friendly name → Bonjour → NetBIOS → DHCP/DNS → vendor.
    var displayName: String {
        for n in [nickname, friendlyName, mdnsName, netbiosName, hostname] { if let n, !n.isEmpty { return n } }
        if let v = vendor, v != "Private address" { return "\(v) device" }
        return ip ?? mac
    }

    /// Locally-administered bit set → randomized / private Wi-Fi address (iOS, Android, macOS).
    var isPrivateMAC: Bool {
        guard let first = mac.split(separator: ":").first, let b = UInt8(first, radix: 16) else { return false }
        return b & 0x02 != 0
    }
    var online: Bool { Date().timeIntervalSince(lastSeen) < 15 * 60 }

    /// Sort IPv4 addresses numerically.
    var ipSortKey: UInt32 {
        guard let ip else { return .max }
        return ip.split(separator: ".").compactMap { UInt32($0) }.reduce(0) { $0 << 8 | $1 }
    }
}

enum EventType: String, CaseIterable, Identifiable {
    case started, connected, disconnected, roam, ssidChange, channelChange, ipChange
    case internetDown, internetUp, lowSignal, signalRecovered, highLatency, latencyRecovered
    case newDevice, speedTest, powerChange, scanError
    case targetDown, targetUp, certExpiring, dataCap
    case routerReboot, untrustedDevice, captivePortal, publicIPChange, ipv6Down, ipv6Up
    case vpnUp, vpnDown, linkChange, stickyClient, pathSlow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .started: return "Monitor started"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        case .roam: return "Roamed (AP change)"
        case .ssidChange: return "Network changed"
        case .channelChange: return "Channel changed"
        case .ipChange: return "IP changed"
        case .internetDown: return "Internet down"
        case .internetUp: return "Internet restored"
        case .lowSignal: return "Low signal"
        case .signalRecovered: return "Signal recovered"
        case .highLatency: return "High latency"
        case .latencyRecovered: return "Latency recovered"
        case .newDevice: return "New LAN device"
        case .speedTest: return "Speed test"
        case .powerChange: return "Wi-Fi power"
        case .scanError: return "Scan error"
        case .targetDown: return "Target down"
        case .targetUp: return "Target recovered"
        case .certExpiring: return "Certificate expiring"
        case .dataCap: return "Data cap"
        case .routerReboot: return "Router restarted"
        case .untrustedDevice: return "Untrusted device online"
        case .captivePortal: return "Captive portal"
        case .publicIPChange: return "Public IP / ISP changed"
        case .ipv6Down: return "IPv6 down"
        case .ipv6Up: return "IPv6 restored"
        case .vpnUp: return "VPN connected"
        case .vpnDown: return "VPN disconnected"
        case .linkChange: return "Connection type changed"
        case .stickyClient: return "Sticky client"
        case .pathSlow: return "Slow network path"
        }
    }

    var icon: String {
        switch self {
        case .started: return "play.circle"
        case .connected: return "wifi"
        case .disconnected: return "wifi.slash"
        case .roam: return "arrow.triangle.swap"
        case .ssidChange: return "arrow.left.arrow.right"
        case .channelChange: return "dial.medium"
        case .ipChange: return "number"
        case .internetDown: return "globe.badge.chevron.backward"
        case .internetUp: return "globe"
        case .lowSignal: return "wifi.exclamationmark"
        case .signalRecovered: return "wifi"
        case .highLatency: return "tortoise"
        case .latencyRecovered: return "hare"
        case .newDevice: return "laptopcomputer.and.iphone"
        case .speedTest: return "speedometer"
        case .powerChange: return "power"
        case .scanError: return "exclamationmark.triangle"
        case .targetDown: return "xmark.circle"
        case .targetUp: return "checkmark.circle"
        case .certExpiring: return "lock.trianglebadge.exclamationmark"
        case .dataCap: return "chart.pie"
        case .routerReboot: return "arrow.clockwise.circle"
        case .untrustedDevice: return "person.fill.questionmark"
        case .captivePortal: return "hand.raised.square"
        case .publicIPChange: return "globe.badge.chevron.backward"
        case .ipv6Down: return "6.circle"
        case .ipv6Up: return "6.circle.fill"
        case .vpnUp: return "lock.shield"
        case .vpnDown: return "lock.open"
        case .linkChange: return "cable.connector"
        case .stickyClient: return "pin.circle"
        case .pathSlow: return "point.topleft.down.to.point.bottomright.curvepath"
        }
    }

    var color: Color {
        switch self {
        case .disconnected, .internetDown, .scanError, .targetDown, .untrustedDevice, .ipv6Down: return .red
        case .routerReboot, .captivePortal, .stickyClient, .pathSlow: return .orange
        case .ipv6Up, .vpnUp: return .green
        case .publicIPChange, .linkChange, .vpnDown: return .blue
        case .certExpiring, .dataCap: return .orange
        case .targetUp: return .green
        case .lowSignal, .highLatency: return .orange
        case .connected, .internetUp, .signalRecovered, .latencyRecovered: return .green
        case .newDevice, .speedTest: return .blue
        default: return .secondary
        }
    }

    var notifies: Bool {
        switch self {
        case .disconnected, .internetDown, .internetUp, .lowSignal, .highLatency, .newDevice, .ssidChange,
             .targetDown, .targetUp, .certExpiring, .dataCap, .routerReboot, .untrustedDevice, .captivePortal,
             .publicIPChange, .ipv6Down, .vpnUp, .vpnDown, .pathSlow: return true
        default: return false
        }
    }
}

struct EventItem: Identifiable {
    var id: Int64
    var ts: Date
    var type: EventType
    var message: String
    var ssid: String?
}

struct SpeedTestResult: Identifiable {
    var id: Int64
    var ts: Date
    var dlMbps: Double?
    var ulMbps: Double?
    var responsiveness: Double?
    var baseRTT: Double?
    var ssid: String?
    var band: String?
    var loadedLatency: Double? = nil
    var kind: String? = nil

    /// Extra delay your connection adds under load (bufferbloat), from networkQuality's RPM and idle RTT.
    var bloatMs: Double? {
        guard let l = loadedLatency ?? responsiveness.map({ 60000 / $0 }), let b = baseRTT else { return nil }
        return max(0, l - b)
    }
    var bloatGrade: BloatGrade? { bloatMs.map(BloatGrade.init(ms:)) }
}

/// Bufferbloat grade by added latency under load (same thresholds popular online tests use).
enum BloatGrade: String {
    case aPlus = "A+", a = "A", b = "B", c = "C", d = "D", f = "F"
    init(ms: Double) {
        switch ms {
        case ..<5: self = .aPlus
        case ..<30: self = .a
        case ..<60: self = .b
        case ..<200: self = .c
        case ..<400: self = .d
        default: self = .f
        }
    }
    var color: Color {
        switch self {
        case .aPlus, .a: return .green
        case .b: return .mint
        case .c: return .yellow
        case .d: return .orange
        case .f: return .red
        }
    }
    var meaning: String {
        switch self {
        case .aPlus, .a: return "Calls and games stay smooth even while the line is busy"
        case .b: return "Mostly fine; heavy uploads may cause brief lag"
        case .c: return "Noticeable lag in calls/games while someone downloads or uploads"
        case .d, .f: return "Severe lag under load — enable SQM / Smart Queue (fq_codel, CAKE) on the router"
        }
    }
}

enum SignalQuality: String {
    case excellent = "Excellent", good = "Good", fair = "Fair", weak = "Weak", poor = "Poor", none = "No signal"

    init(rssi: Int?) {
        guard let r = rssi, r != 0 else { self = .none; return }
        switch r {
        case (-50)...: self = .excellent
        case (-60)...: self = .good
        case (-70)...: self = .fair
        case (-80)...: self = .weak
        default: self = .poor
        }
    }

    var color: Color {
        switch self {
        case .excellent: return .green
        case .good: return .mint
        case .fair: return .yellow
        case .weak: return .orange
        case .poor, .none: return .red
        }
    }
}
