import Foundation

/// User settings (backed by UserDefaults, editable from Settings). Read fresh every loop so changes apply live.
enum Prefs {
    static let defaults: [String: Any] = [
        "sampleInterval": 5.0,          // seconds between Wi-Fi/latency samples
        "scanInterval": 120.0,          // seconds between nearby-network scans (0 = off)
        "sweepInterval": 600.0,         // seconds between LAN device discovery sweeps (0 = off)
        "appUsageInterval": 60.0,       // seconds between per-app traffic snapshots (0 = off)
        "speedTestInterval": 0.0,       // minutes between automatic speed tests (0 = manual only)
        "retentionDays": 90.0,
        "pingHost1": "1.1.1.1",
        "pingHost2": "8.8.8.8",
        "dnsTestHost": "www.apple.com",
        "lowRssi": -75.0,
        "highLatency": 150.0,
        "notifications": true,
        "routerKind": "none",
        "routerHost": "",               // empty = use the default gateway
        "routerUser": "",
        "routerCommunity": "public",
        "routerWan": "",                // empty = auto-detect WAN interface
        "routerHTTPS": false,
        "routerInterval": 60.0,
        "routerSite": "default",        // UniFi site name
        "capEnabled": false,
        "capGB": 100.0,
        "capResetDay": 1,
        "capScope": "mac",
        "traceInterval": 900.0,         // seconds between traceroutes (0 = off)
        "ipv6Interval": 60.0,           // seconds between IPv6 probes (0 = off)
        "identityInterval": 300.0,      // seconds between public-IP / captive-portal checks (0 = off)
        "connInterval": 300.0,          // seconds between per-app connection snapshots (0 = off)
        "bufferbloatHours": "",         // comma-separated hours for scheduled load tests, e.g. "20,21"
        "untrustedAlerts": false,       // alert when a device not on the trusted list comes online
        "asnLookups": true,
        "menuBarSpeed": "both",         // menu bar: "both", "busier" or "off"
        "uiMode": "simple",             // "simple" (everyday essentials) or "advanced" (every page and setting)
        "gptModel": "gemini-3.5-flash",
    ]

    static func register() { UserDefaults.standard.register(defaults: defaults) }

    private static var d: UserDefaults { .standard }
    static var sampleInterval: Double { max(2, d.double(forKey: "sampleInterval")) }
    static var scanInterval: Double { d.double(forKey: "scanInterval") }
    static var sweepInterval: Double { d.double(forKey: "sweepInterval") }
    static var appUsageInterval: Double { d.double(forKey: "appUsageInterval") }
    static var speedTestInterval: Double { d.double(forKey: "speedTestInterval") }
    static var retentionDays: Double { max(1, d.double(forKey: "retentionDays")) }
    static var pingHost1: String { d.string(forKey: "pingHost1") ?? "1.1.1.1" }
    static var pingHost2: String { d.string(forKey: "pingHost2") ?? "8.8.8.8" }
    static var dnsTestHost: String { d.string(forKey: "dnsTestHost") ?? "www.apple.com" }
    static var lowRssi: Int { Int(d.double(forKey: "lowRssi")) }
    static var highLatency: Double { d.double(forKey: "highLatency") }
    static var notifications: Bool { d.bool(forKey: "notifications") }
    static var routerKind: RouterKind { RouterKind(rawValue: d.string(forKey: "routerKind") ?? "none") ?? .none }
    static var routerInterval: Double { max(15, d.double(forKey: "routerInterval")) }
    static var traceInterval: Double { d.double(forKey: "traceInterval") }
    static var ipv6Interval: Double { d.double(forKey: "ipv6Interval") }
    static var identityInterval: Double { d.double(forKey: "identityInterval") }
    static var connInterval: Double { d.double(forKey: "connInterval") }
    static var bufferbloatHours: Set<Int> {
        Set((d.string(forKey: "bufferbloatHours") ?? "").split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) })
    }
    static var untrustedAlerts: Bool { d.bool(forKey: "untrustedAlerts") }
    static var asnLookups: Bool { d.bool(forKey: "asnLookups") }
    static var isAdvanced: Bool { d.string(forKey: "uiMode") == "advanced" }
}
