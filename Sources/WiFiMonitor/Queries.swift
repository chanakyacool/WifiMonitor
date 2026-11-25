import Foundation

// MARK: - Filters

enum RangePreset: String, CaseIterable, Identifiable {
    case m15 = "15 min", h1 = "1 hour", h6 = "6 hours", h24 = "24 hours", today = "Today",
         yesterday = "Yesterday", d7 = "7 days", d30 = "30 days", d90 = "90 days",
         cycle = "This billing cycle", lastCycle = "Last billing cycle", all = "All time", custom = "Custom"
    var id: String { rawValue }
}

/// One filter shared by every dashboard: time range + network / access point / band.
struct DashFilter: Hashable {
    var preset: RangePreset = .h24
    var customFrom = Calendar.current.startOfDay(for: Date()).addingTimeInterval(-86400)
    var customTo = Date()
    var ssid: String?
    var bssid: String?
    var band: String?

    var interval: (from: Date, to: Date) {
        let now = Date(), cal = Calendar.current
        switch preset {
        case .m15: return (now.addingTimeInterval(-900), now)
        case .h1: return (now.addingTimeInterval(-3600), now)
        case .h6: return (now.addingTimeInterval(-6 * 3600), now)
        case .h24: return (now.addingTimeInterval(-86400), now)
        case .today: return (cal.startOfDay(for: now), now)
        case .yesterday:
            let s = cal.startOfDay(for: now)
            return (s.addingTimeInterval(-86400), s)
        case .d7: return (now.addingTimeInterval(-7 * 86400), now)
        case .d30: return (now.addingTimeInterval(-30 * 86400), now)
        case .d90: return (now.addingTimeInterval(-90 * 86400), now)
        case .cycle: return (DataCap.cycle(now: now).start, now)
        case .lastCycle: let c = DataCap.cycle(now: now, offset: -1); return (c.start, c.end)
        case .all: return (Date(timeIntervalSince1970: 0), now)
        case .custom: return (min(customFrom, customTo), max(customFrom, customTo))
        }
    }

    var isNetworkFiltered: Bool { ssid != nil || bssid != nil || band != nil }

    /// Builds a WHERE clause. Pass nil for columns a table doesn't have.
    func clause(ts: String = "ts", ssid ssidCol: String? = "ssid", bssid bssidCol: String? = "bssid", band bandCol: String? = "band") -> (String, [Any?]) {
        let (from, to) = interval
        var parts = ["\(ts) >= ?", "\(ts) <= ?"]
        var params: [Any?] = [from.timeIntervalSince1970, to.timeIntervalSince1970]
        if let ssid, let col = ssidCol { parts.append("\(col) = ?"); params.append(ssid) }
        if let bssid, let col = bssidCol { parts.append("\(col) = ?"); params.append(bssid) }
        if let band, let col = bandCol { parts.append("\(col) = ?"); params.append(band) }
        return (parts.joined(separator: " AND "), params)
    }
}

struct FilterOptions {
    var ssids: [String] = []
    var aps: [(bssid: String, ssid: String?)] = []
    var bands: [String] = []
}

// MARK: - Result types

struct Overview {
    var samples = 0
    var span: TimeInterval = 0
    var avgRssi: Double?, minRssi: Double?, maxRssi: Double?
    var avgNoise: Double?, avgSnr: Double?, avgTxRate: Double?, maxTxRate: Double?
    var avgGw: Double?, avgInet: Double?, p95Inet: Double?, maxInet: Double?, avgDns: Double?
    var jitter: Double?
    var loss: Double?
    var wifiUptime: Double?      // fraction of samples connected
    var internetUptime: Double?  // fraction of samples with internet reachable
    var rxBytes: Double = 0, txBytes: Double = 0
    var peakRx: Double?, peakTx: Double?
    var disconnects = 0, roams = 0, outages = 0, lowSignalEvents = 0
    var speedTests = 0
    var avgDl: Double?, avgUl: Double?, maxDl: Double?
    var networks = 0, aps = 0, devices = 0, nearbyNetworks = 0
}

struct HistoryPoint: Identifiable {
    var id: Date { date }
    var date: Date
    var rssi: Double?, minRssi: Double?, noise: Double?, snr: Double?, txRate: Double?
    var gw: Double?, inet: Double?, maxInet: Double?, dns: Double?, loss: Double?
    var rxBps: Double?, txBps: Double?, up: Double?, inetUp: Double?
}

struct UsageBucket: Identifiable {
    var id: Date { date }
    var date: Date
    var rx: Double
    var tx: Double
}

struct UsageGroup: Identifiable {
    var id: String { name }
    var name: String
    var detail: String?
    var rx: Double
    var tx: Double
    var seconds: Double = 0
    var total: Double { rx + tx }
}

struct APStat: Identifiable {
    var id: String { bssid }
    var bssid: String
    var ssid: String?
    var band: String?
    var channel: Int?
    var samples: Int
    var seconds: Double
    var avgRssi: Double?
    var minRssi: Double?
    var avgInet: Double?
    var loss: Double?
    var rx: Double
    var tx: Double
    var firstSeen: Date?
    var lastSeen: Date?
}

struct HeatCell: Identifiable {
    var id: String { "\(weekday)-\(hour)" }
    var weekday: Int   // 0 = Sunday
    var hour: Int
    var value: Double
}

struct Outage: Identifiable {
    var id: Date { start }
    var start: Date
    var end: Date?
    var kind: String
    var duration: TimeInterval { (end ?? Date()).timeIntervalSince(start) }
}

struct DistBucket: Identifiable {
    var id: String { label }
    var label: String
    var count: Double
    var order: Int
}

// MARK: - Queries

enum Queries {
    static var db: Database { .shared }

    static func scanResult(_ r: Row) -> ScanResult {
        ScanResult(ts: r.date("ts") ?? Date(), ssid: r.string("ssid"), bssid: r.string("bssid"),
                   rssi: r.int("rssi") ?? -100, noise: r.int("noise") ?? 0, channel: r.int("channel"),
                   band: r.string("band"), width: r.string("width"), security: r.string("security") ?? "?",
                   beaconInterval: r.int("beacon_interval") ?? 0, country: r.string("country"),
                   seenCount: r.int("seen") ?? 1)
    }

    static func device(_ r: Row) -> Device {
        Device(mac: r.string("mac") ?? "?", ip: r.string("ip"), hostname: r.string("hostname"),
               interface: r.string("interface"), ssid: r.string("ssid"),
               firstSeen: r.date("first_seen") ?? Date(), lastSeen: r.date("last_seen") ?? Date(),
               vendor: r.string("vendor") ?? OUI.vendor(for: r.string("mac") ?? ""),
               mdnsName: r.string("mdns_name"), netbiosName: r.string("netbios_name"), friendlyName: r.string("friendly_name"),
               model: r.string("model"), kind: r.string("kind"), nickname: r.string("nickname"),
               tag: r.string("tag"), trusted: (r.int("trusted") ?? 0) == 1, openPorts: r.string("open_ports"), portsScanned: r.date("ports_scanned"))
    }

    static func event(_ r: Row) -> EventItem {
        EventItem(id: Int64(r.int("id") ?? 0), ts: r.date("ts") ?? Date(),
                  type: EventType(rawValue: r.string("type") ?? "") ?? .started,
                  message: r.string("message") ?? "", ssid: r.string("ssid"))
    }

    static func filterOptions() -> FilterOptions {
        var o = FilterOptions()
        o.ssids = db.query("SELECT DISTINCT ssid FROM samples WHERE ssid IS NOT NULL ORDER BY ssid").compactMap { $0.string("ssid") }
        o.aps = db.query("SELECT bssid, MAX(ssid) AS ssid FROM samples WHERE bssid IS NOT NULL GROUP BY bssid ORDER BY ssid, bssid")
            .compactMap { r in r.string("bssid").map { ($0, r.string("ssid")) } }
        o.bands = db.query("SELECT DISTINCT band FROM samples WHERE band IS NOT NULL ORDER BY band").compactMap { $0.string("band") }
        return o
    }

    /// Sample interval in seconds; used to convert sample counts to time.
    private static var sampleSeconds: Double { Prefs.sampleInterval }

    // MARK: Overview

    static func overview(_ f: DashFilter) -> Overview {
        var o = Overview()
        let (w, p) = f.clause()
        if let r = db.query("""
            SELECT COUNT(*) n, MIN(ts) t0, MAX(ts) t1,
                AVG(CASE WHEN connected=1 THEN rssi END) rssi, MIN(CASE WHEN connected=1 THEN rssi END) min_rssi,
                MAX(CASE WHEN connected=1 THEN rssi END) max_rssi, AVG(noise) noise, AVG(snr) snr,
                AVG(tx_rate) tx_rate, MAX(tx_rate) max_tx_rate,
                AVG(gw_latency) gw, AVG(inet_latency) inet, MAX(inet_latency) max_inet, AVG(dns_latency) dns, AVG(loss) loss,
                AVG(connected) up, AVG(CASE WHEN inet_latency IS NOT NULL THEN 1.0 ELSE 0.0 END) inet_up,
                SUM(rx_bytes) rx, SUM(tx_bytes) tx, MAX(rx_bps) peak_rx, MAX(tx_bps) peak_tx,
                COUNT(DISTINCT ssid) nets, COUNT(DISTINCT bssid) aps
            FROM samples WHERE \(w)
            """, p).first {
            o.samples = r.int("n") ?? 0
            if let a = r.double("t0"), let b = r.double("t1") { o.span = b - a }
            o.avgRssi = r.double("rssi"); o.minRssi = r.double("min_rssi"); o.maxRssi = r.double("max_rssi")
            o.avgNoise = r.double("noise"); o.avgSnr = r.double("snr")
            o.avgTxRate = r.double("tx_rate"); o.maxTxRate = r.double("max_tx_rate")
            o.avgGw = r.double("gw"); o.avgInet = r.double("inet"); o.maxInet = r.double("max_inet"); o.avgDns = r.double("dns")
            o.loss = r.double("loss"); o.wifiUptime = r.double("up"); o.internetUptime = r.double("inet_up")
            o.rxBytes = r.double("rx") ?? 0; o.txBytes = r.double("tx") ?? 0
            o.peakRx = r.double("peak_rx"); o.peakTx = r.double("peak_tx")
            o.networks = r.int("nets") ?? 0; o.aps = r.int("aps") ?? 0
        }
        // p95 latency
        let n = Int(db.scalar("SELECT COUNT(*) FROM samples WHERE \(w) AND inet_latency IS NOT NULL", p) ?? 0)
        if n > 0 {
            o.p95Inet = db.scalar("SELECT inet_latency FROM samples WHERE \(w) AND inet_latency IS NOT NULL ORDER BY inet_latency LIMIT 1 OFFSET ?",
                                  p + [Int(Double(n) * 0.95)])
        }
        // Jitter = mean absolute difference between consecutive latency samples
        let lat = db.query("SELECT inet_latency l FROM samples WHERE \(w) AND inet_latency IS NOT NULL ORDER BY ts DESC LIMIT 5000", p).compactMap { $0.double("l") }
        if lat.count > 1 { o.jitter = zip(lat, lat.dropFirst()).map { abs($0 - $1) }.reduce(0, +) / Double(lat.count - 1) }

        let (ew, ep) = f.clause(band: nil)
        for r in db.query("SELECT type, COUNT(*) c FROM events WHERE \(ew) GROUP BY type", ep) {
            let c = r.int("c") ?? 0
            switch EventType(rawValue: r.string("type") ?? "") {
            case .disconnected: o.disconnects = c
            case .roam: o.roams = c
            case .internetDown: o.outages = c
            case .lowSignal: o.lowSignalEvents = c
            default: break
            }
        }
        let (sw, sp) = f.clause()
        if let r = db.query("SELECT COUNT(*) n, AVG(dl_mbps) dl, AVG(ul_mbps) ul, MAX(dl_mbps) mdl FROM speedtests WHERE \(sw)", sp).first {
            o.speedTests = r.int("n") ?? 0; o.avgDl = r.double("dl"); o.avgUl = r.double("ul"); o.maxDl = r.double("mdl")
        }
        let (dw, dp) = f.clause(ts: "last_seen", bssid: nil, band: nil)
        o.devices = Int(db.scalar("SELECT COUNT(*) FROM devices WHERE \(dw)", dp) ?? 0)
        let (nw, np) = f.clause(ssid: nil, bssid: nil)
        o.nearbyNetworks = Int(db.scalar("SELECT COUNT(DISTINCT bssid) FROM scans WHERE \(nw)", np) ?? 0)
        return o
    }

    // MARK: Time series

    static func history(_ f: DashFilter, points: Int = 300) -> [HistoryPoint] {
        let (from, to) = effectiveBounds(f)
        let bucket = max(Prefs.sampleInterval, (to - from) / Double(points))
        let (w, p) = f.clause()
        return db.query("""
            SELECT CAST(ts / ? AS INTEGER) * ? AS b,
                AVG(CASE WHEN connected=1 THEN rssi END) rssi, MIN(CASE WHEN connected=1 THEN rssi END) min_rssi,
                AVG(noise) noise, AVG(snr) snr, AVG(tx_rate) tx_rate,
                AVG(gw_latency) gw, AVG(inet_latency) inet, MAX(inet_latency) max_inet, AVG(dns_latency) dns, AVG(loss) loss,
                AVG(rx_bps) rx, AVG(tx_bps) tx, AVG(connected) up,
                AVG(CASE WHEN inet_latency IS NOT NULL THEN 1.0 ELSE 0.0 END) inet_up
            FROM samples WHERE \(w) GROUP BY b ORDER BY b
            """, [bucket, bucket] + p).map { r in
            HistoryPoint(date: Date(timeIntervalSince1970: r.double("b") ?? 0),
                         rssi: r.double("rssi"), minRssi: r.double("min_rssi"), noise: r.double("noise"), snr: r.double("snr"),
                         txRate: r.double("tx_rate"), gw: r.double("gw"), inet: r.double("inet"), maxInet: r.double("max_inet"),
                         dns: r.double("dns"), loss: r.double("loss"), rxBps: r.double("rx"), txBps: r.double("tx"),
                         up: r.double("up"), inetUp: r.double("inet_up"))
        }
    }

    /// Clamp "All time" to the data actually present so buckets are sensible.
    static func effectiveBounds(_ f: DashFilter) -> (Double, Double) {
        var (from, to) = (f.interval.from.timeIntervalSince1970, f.interval.to.timeIntervalSince1970)
        if let first = db.scalar("SELECT MIN(ts) FROM samples"), first > from { from = first }
        if to <= from { to = from + 60 }
        return (from, to)
    }

    // MARK: Data usage

    static func usageBuckets(_ f: DashFilter) -> (buckets: [UsageBucket], hourly: Bool) {
        let (from, to) = effectiveBounds(f)
        let hourly = (to - from) <= 3 * 86400
        let fmt = hourly ? "%Y-%m-%d %H:00:00" : "%Y-%m-%d 00:00:00"
        let (w, p) = f.clause()
        let parser = DateFormatter()
        parser.dateFormat = "yyyy-MM-dd HH:mm:ss"
        parser.timeZone = .current
        let rows = db.query("""
            SELECT strftime('\(fmt)', ts, 'unixepoch', 'localtime') b, SUM(rx_bytes) rx, SUM(tx_bytes) tx
            FROM samples WHERE \(w) GROUP BY b ORDER BY b
            """, p)
        let buckets = rows.compactMap { r -> UsageBucket? in
            guard let s = r.string("b"), let d = parser.date(from: s) else { return nil }
            return UsageBucket(date: d, rx: r.double("rx") ?? 0, tx: r.double("tx") ?? 0)
        }
        return (buckets, hourly)
    }

    static func usageBy(_ column: String, _ f: DashFilter) -> [UsageGroup] {
        let (w, p) = f.clause()
        return db.query("""
            SELECT COALESCE(\(column), '‹unknown›') k, SUM(rx_bytes) rx, SUM(tx_bytes) tx, COUNT(*) n
            FROM samples WHERE \(w) AND connected=1 GROUP BY k ORDER BY SUM(COALESCE(rx_bytes,0)+COALESCE(tx_bytes,0)) DESC
            """, p).map {
            UsageGroup(name: $0.string("k") ?? "?", rx: $0.double("rx") ?? 0, tx: $0.double("tx") ?? 0,
                       seconds: Double($0.int("n") ?? 0) * sampleSeconds)
        }
    }

    static func usageByApp(_ f: DashFilter, limit: Int = 50) -> [UsageGroup] {
        // Network filters only apply to Wi-Fi rows; wired rows have no SSID.
        let (w, p) = f.isNetworkFiltered ? f.clause() : f.clause(ssid: nil, bssid: nil, band: nil)
        return db.query("""
            SELECT app, SUM(rx_bytes) rx, SUM(tx_bytes) tx,
                   SUM(CASE WHEN link='Ethernet' THEN rx_bytes + tx_bytes ELSE 0 END) wired
            FROM app_usage WHERE \(w)
            GROUP BY app ORDER BY SUM(rx_bytes + tx_bytes) DESC LIMIT ?
            """, p + [limit]).map {
            let wired = $0.double("wired") ?? 0
            return UsageGroup(name: $0.string("app") ?? "?", detail: wired > 0 ? Fmt.bytes(wired) : nil, rx: $0.double("rx") ?? 0, tx: $0.double("tx") ?? 0)
        }
    }

    static func appUsageTotal(_ f: DashFilter) -> Double {
        let (w, p) = f.isNetworkFiltered ? f.clause() : f.clause(ssid: nil, bssid: nil, band: nil)
        return db.scalar("SELECT SUM(rx_bytes + tx_bytes) FROM app_usage WHERE \(w)", p) ?? 0
    }

    static func allTimeUsage() -> (rx: Double, tx: Double, since: Date?) {
        let r = db.query("SELECT SUM(rx_bytes) rx, SUM(tx_bytes) tx, MIN(ts) t FROM samples").first
        return (r?.double("rx") ?? 0, r?.double("tx") ?? 0, r?.date("t"))
    }

    // MARK: Access points

    static func apStats(_ f: DashFilter) -> [APStat] {
        let (w, p) = f.clause()
        return db.query("""
            SELECT bssid, MAX(ssid) ssid, MAX(band) band, MAX(channel) channel, COUNT(*) n,
                AVG(rssi) rssi, MIN(rssi) min_rssi, AVG(inet_latency) inet, AVG(loss) loss,
                SUM(rx_bytes) rx, SUM(tx_bytes) tx, MIN(ts) t0, MAX(ts) t1
            FROM samples WHERE \(w) AND connected=1 AND bssid IS NOT NULL
            GROUP BY bssid ORDER BY n DESC
            """, p).map { r in
            APStat(bssid: r.string("bssid") ?? "?", ssid: r.string("ssid"), band: r.string("band"), channel: r.int("channel"),
                   samples: r.int("n") ?? 0, seconds: Double(r.int("n") ?? 0) * sampleSeconds,
                   avgRssi: r.double("rssi"), minRssi: r.double("min_rssi"), avgInet: r.double("inet"), loss: r.double("loss"),
                   rx: r.double("rx") ?? 0, tx: r.double("tx") ?? 0, firstSeen: r.date("t0"), lastSeen: r.date("t1"))
        }
    }

    /// Time spent per value of a column (band, channel, phy, width…), as fraction of connected time.
    static func timeShare(_ column: String, _ f: DashFilter) -> [UsageGroup] {
        let (w, p) = f.clause()
        return db.query("""
            SELECT CAST(\(column) AS TEXT) k, COUNT(*) n FROM samples
            WHERE \(w) AND connected=1 AND \(column) IS NOT NULL GROUP BY k ORDER BY n DESC
            """, p).map { UsageGroup(name: $0.string("k") ?? "?", rx: 0, tx: 0, seconds: Double($0.int("n") ?? 0) * sampleSeconds) }
    }

    // MARK: Distributions & heatmaps

    static func signalDistribution(_ f: DashFilter) -> [DistBucket] {
        let (w, p) = f.clause()
        let rows = db.query("""
            SELECT CASE WHEN rssi >= -50 THEN 0 WHEN rssi >= -60 THEN 1 WHEN rssi >= -70 THEN 2 WHEN rssi >= -80 THEN 3 ELSE 4 END q,
                COUNT(*) n FROM samples WHERE \(w) AND connected=1 AND rssi IS NOT NULL GROUP BY q
            """, p)
        let labels = ["Excellent (≥-50)", "Good (-60)", "Fair (-70)", "Weak (-80)", "Poor (<-80)"]
        let total = Double(rows.reduce(0) { $0 + ($1.int("n") ?? 0) })
        return labels.enumerated().map { i, l in
            let n = Double(rows.first { $0.int("q") == i }?.int("n") ?? 0)
            return DistBucket(label: l, count: total > 0 ? n / total : 0, order: i)
        }
    }

    static func latencyDistribution(_ f: DashFilter) -> [DistBucket] {
        let (w, p) = f.clause()
        let edges: [(String, Double)] = [("<10 ms", 10), ("10–20", 20), ("20–40", 40), ("40–80", 80), ("80–150", 150), ("150–300", 300), (">300", .infinity)]
        let lat = db.query("SELECT inet_latency l FROM samples WHERE \(w) AND inet_latency IS NOT NULL", p).compactMap { $0.double("l") }
        var counts = [Double](repeating: 0, count: edges.count)
        for l in lat { if let i = edges.firstIndex(where: { l < $0.1 }) { counts[i] += 1 } }
        let total = max(1, Double(lat.count))
        return edges.enumerated().map { DistBucket(label: $1.0, count: counts[$0] / total, order: $0) }
    }

    /// metric: "rssi" | "inet_latency" | "loss" | "usage"
    static func heatmap(_ f: DashFilter, metric: String) -> [HeatCell] {
        let (w, p) = f.clause()
        let expr: String
        switch metric {
        case "usage": expr = "SUM(COALESCE(rx_bytes,0) + COALESCE(tx_bytes,0))"
        case "loss": expr = "AVG(loss)"
        case "inet_latency": expr = "AVG(inet_latency)"
        default: expr = "AVG(CASE WHEN connected=1 THEN rssi END)"
        }
        return db.query("""
            SELECT CAST(strftime('%w', ts, 'unixepoch', 'localtime') AS INTEGER) wd,
                   CAST(strftime('%H', ts, 'unixepoch', 'localtime') AS INTEGER) hr, \(expr) v
            FROM samples WHERE \(w) GROUP BY wd, hr
            """, p).compactMap { r in
            guard let v = r.double("v") else { return nil }
            return HeatCell(weekday: r.int("wd") ?? 0, hour: r.int("hr") ?? 0, value: v)
        }
    }

    // MARK: Outages

    static func outages(_ f: DashFilter) -> [Outage] {
        let (w, p) = f.clause(band: nil)
        let rows = db.query("SELECT ts, type FROM events WHERE \(w) AND type IN ('disconnected','connected','internetDown','internetUp','started') ORDER BY ts", p)
        var result: [Outage] = []
        var wifiStart: Date?, inetStart: Date?
        for r in rows {
            guard let ts = r.date("ts") else { continue }
            switch r.string("type") {
            case "disconnected": wifiStart = ts
            case "connected": if let s = wifiStart { result.append(Outage(start: s, end: ts, kind: "Wi-Fi")); wifiStart = nil }
            case "internetDown": inetStart = ts
            case "internetUp": if let s = inetStart { result.append(Outage(start: s, end: ts, kind: "Internet")); inetStart = nil }
            case "started":
                // App restarted while down: close with unknown end.
                if let s = wifiStart { result.append(Outage(start: s, end: ts, kind: "Wi-Fi")); wifiStart = nil }
                if let s = inetStart { result.append(Outage(start: s, end: ts, kind: "Internet")); inetStart = nil }
            default: break
            }
        }
        if let s = wifiStart { result.append(Outage(start: s, end: nil, kind: "Wi-Fi")) }
        if let s = inetStart { result.append(Outage(start: s, end: nil, kind: "Internet")) }
        return result.sorted { $0.start > $1.start }
    }

    // MARK: Lists

    static func recentEvents(limit: Int) -> [EventItem] {
        db.query("SELECT * FROM events ORDER BY ts DESC LIMIT ?", [limit]).map(event)
    }

    static func events(_ f: DashFilter, limit: Int = 2000) -> [EventItem] {
        let (w, p) = f.clause(band: nil)
        return db.query("SELECT * FROM events WHERE \(w) ORDER BY ts DESC LIMIT ?", p + [limit]).map(event)
    }

    static func speedTests(_ f: DashFilter) -> [SpeedTestResult] {
        let (w, p) = f.clause()
        return db.query("SELECT * FROM speedtests WHERE \(w) ORDER BY ts DESC", p).map { r in
            SpeedTestResult(id: Int64(r.int("id") ?? 0), ts: r.date("ts") ?? Date(), dlMbps: r.double("dl_mbps"),
                            ulMbps: r.double("ul_mbps"), responsiveness: r.double("responsiveness"),
                            baseRTT: r.double("base_rtt"), ssid: r.string("ssid"), band: r.string("band"),
                            loadedLatency: r.double("loaded_latency"), kind: r.string("kind"))
        }
    }

    static func allDevices() -> [Device] {
        db.query("SELECT * FROM devices ORDER BY last_seen DESC").map(device)
    }

    static func devices(_ f: DashFilter) -> [Device] {
        let (w, p) = f.clause(ts: "last_seen", bssid: nil, band: nil)
        return db.query("SELECT * FROM devices WHERE \(w)", p).map(device).sorted { $0.ipSortKey < $1.ipSortKey }
    }

    /// Every network seen in scans during the range, aggregated per BSSID.
    static func networksSeen(_ f: DashFilter) -> [ScanResult] {
        let (w, p) = f.clause(ssid: "ssid", bssid: nil)
        return db.query("""
            SELECT MAX(ts) ts, MAX(ssid) ssid, bssid, CAST(AVG(rssi) AS INTEGER) rssi, CAST(AVG(noise) AS INTEGER) noise,
                MAX(channel) channel, MAX(band) band, MAX(width) width, MAX(security) security,
                MAX(beacon_interval) beacon_interval, MAX(country) country, COUNT(*) seen
            FROM scans WHERE \(w) GROUP BY bssid, ssid ORDER BY rssi DESC
            """, p).map(scanResult)
    }

    // MARK: Database stats & export

    static func tableCounts() -> [(String, Int)] {
        ["samples", "scans", "events", "speedtests", "devices", "app_usage", "device_sessions", "traces", "ipv6_samples",
         "net_identity", "app_connections"].map {
            ($0, Int(db.scalar("SELECT COUNT(*) FROM \($0)") ?? 0))
        }
    }

    static func exportCSV(table: String, _ f: DashFilter, to url: URL) throws {
        let (w, p): (String, [Any?])
        switch table {
        case "events": (w, p) = f.clause(band: nil)
        case "devices": (w, p) = f.clause(ts: "last_seen", bssid: nil, band: nil)
        case "scans": (w, p) = f.clause(bssid: nil)
        case "router_stats", "target_results": (w, p) = f.clause(ssid: nil, bssid: nil, band: nil)
        default: (w, p) = f.clause()
        }
        let rows = db.query("SELECT * FROM \(table) WHERE \(w) ORDER BY \(table == "devices" ? "last_seen" : "ts")", p)
        guard let first = rows.first else { try "".write(to: url, atomically: true, encoding: .utf8); return }
        let cols = first.values.keys.sorted { a, b in a == "id" || (b != "id" && a < b) }
        let iso = ISO8601DateFormatter()
        var out = cols.joined(separator: ",") + "\n"
        for r in rows {
            out += cols.map { c -> String in
                guard let v = r.values[c] else { return "" }
                if ["ts", "first_seen", "last_seen"].contains(c), let d = r.double(c) {
                    return iso.string(from: Date(timeIntervalSince1970: d))
                }
                let s = "\(v)"
                return s.contains(",") || s.contains("\"") ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
            }.joined(separator: ",") + "\n"
        }
        try out.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Router queries

struct RouterUsage {
    var down: Double = 0, up: Double = 0
    var avgDownBps: Double?, avgUpBps: Double?, peakDownBps: Double?, peakUpBps: Double?
    var avgCpu: Double?, maxCpu: Double?, avgMem: Double?
    var polls = 0
}

extension Queries {
    static func routerUsage(_ f: DashFilter) -> RouterUsage {
        let (w, p) = f.clause(ssid: nil, bssid: nil, band: nil)
        guard let r = db.query("""
            SELECT SUM(wan_rx_bytes) d, SUM(wan_tx_bytes) u, AVG(wan_rx_bps) ad, AVG(wan_tx_bps) au, MAX(wan_rx_bps) pd, MAX(wan_tx_bps) pu,
                   AVG(cpu) cpu, MAX(cpu) mcpu, AVG(mem) mem, COUNT(*) n FROM router_stats WHERE \(w)
            """, p).first else { return RouterUsage() }
        return RouterUsage(down: r.double("d") ?? 0, up: r.double("u") ?? 0, avgDownBps: r.double("ad"), avgUpBps: r.double("au"),
                           peakDownBps: r.double("pd"), peakUpBps: r.double("pu"), avgCpu: r.double("cpu"), maxCpu: r.double("mcpu"),
                           avgMem: r.double("mem"), polls: r.int("n") ?? 0)
    }

    static func routerHistory(_ f: DashFilter, points: Int = 300) -> [HistoryPoint] {
        var (from, to) = (f.interval.from.timeIntervalSince1970, f.interval.to.timeIntervalSince1970)
        if let first = db.scalar("SELECT MIN(ts) FROM router_stats"), first > from { from = first }
        let bucket = max(Prefs.routerInterval, (max(to, from + 60) - from) / Double(points))
        let (w, p) = f.clause(ssid: nil, bssid: nil, band: nil)
        return db.query("""
            SELECT CAST(ts / ? AS INTEGER) * ? b, AVG(wan_rx_bps) rx, AVG(wan_tx_bps) tx, AVG(cpu) cpu, AVG(mem) mem
            FROM router_stats WHERE \(w) GROUP BY b ORDER BY b
            """, [bucket, bucket] + p).map { r in
            // Reuse HistoryPoint: rx/tx = WAN bps, up = CPU, inetUp = memory
            HistoryPoint(date: Date(timeIntervalSince1970: r.double("b") ?? 0), rxBps: r.double("rx"), txBps: r.double("tx"),
                         up: r.double("cpu"), inetUp: r.double("mem"))
        }
    }

    static func routerUsageBuckets(_ f: DashFilter) -> (buckets: [UsageBucket], hourly: Bool) {
        var (from, to) = (f.interval.from.timeIntervalSince1970, f.interval.to.timeIntervalSince1970)
        if let first = db.scalar("SELECT MIN(ts) FROM router_stats"), first > from { from = first }
        to = max(to, from + 60)
        let hourly = (to - from) <= 3 * 86400
        let fmt = hourly ? "%Y-%m-%d %H:00:00" : "%Y-%m-%d 00:00:00"
        let parser = DateFormatter(); parser.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let (w, p) = f.clause(ssid: nil, bssid: nil, band: nil)
        let rows = db.query("SELECT strftime('\(fmt)', ts, 'unixepoch', 'localtime') b, SUM(wan_rx_bytes) rx, SUM(wan_tx_bytes) tx FROM router_stats WHERE \(w) GROUP BY b ORDER BY b", p)
        return (rows.compactMap { r in
            guard let s = r.string("b"), let d = parser.date(from: s) else { return nil }
            return UsageBucket(date: d, rx: r.double("rx") ?? 0, tx: r.double("tx") ?? 0)
        }, hourly)
    }

    /// Data per user/device on the network, as reported by the router (OpenWrt / MikroTik).
    static func routerClientUsage(_ f: DashFilter) -> [UsageGroup] {
        let (w, p) = f.clause(ts: "u.ts", ssid: nil, bssid: nil, band: nil)
        return db.query("""
            SELECT u.mac, COALESCE(d.nickname, d.friendly_name, d.mdns_name, c.name, d.netbios_name, d.hostname, d.vendor, u.mac) name,
                   COALESCE(c.ip, d.ip) ip,
                   SUM(u.down_bytes) down, SUM(u.up_bytes) up
            FROM router_client_usage u
            LEFT JOIN router_clients c ON c.mac = u.mac LEFT JOIN devices d ON d.mac = u.mac
            WHERE \(w) GROUP BY u.mac ORDER BY SUM(u.down_bytes + u.up_bytes) DESC
            """, p).map { UsageGroup(name: $0.string("name") ?? "?", detail: $0.string("ip"), rx: $0.double("down") ?? 0, tx: $0.double("up") ?? 0) }
    }

    static func routerClients() -> [RouterClient] {
        db.query("SELECT * FROM router_clients ORDER BY last_seen DESC").map { r in
            RouterClient(mac: r.string("mac") ?? "?", ip: r.string("ip"), name: r.string("name"), signal: r.int("signal"), iface: r.string("iface"),
                         rxTotal: r.int("rx_total").map { UInt64(max(0, $0)) }, txTotal: r.int("tx_total").map { UInt64(max(0, $0)) },
                         connectedSeconds: r.double("last_seen"), ap: r.string("ap"))
        }
    }
}

// MARK: - Watch target queries

struct TargetStats {
    var checks = 0
    var uptime: Double?
    var avgLatency: Double?
    var p95Latency: Double?
    var failures = 0
}

extension Queries {
    static func targets() -> [WatchTarget] {
        db.query("SELECT * FROM targets ORDER BY name COLLATE NOCASE").compactMap { r in
            guard let id = r.int("id"), let kind = TargetKind(rawValue: r.string("kind") ?? "") else { return nil }
            return WatchTarget(id: Int64(id), name: r.string("name") ?? "", kind: kind, target: r.string("target") ?? "",
                               interval: r.double("interval") ?? 60, enabled: (r.int("enabled") ?? 1) == 1)
        }
    }

    static func targetResult(_ r: Row) -> TargetResult {
        TargetResult(ts: r.date("ts") ?? Date(), ok: (r.int("ok") ?? 0) == 1, latency: r.double("latency"),
                     status: r.int("status"), detail: r.string("detail"), certExpiry: r.date("cert_expiry"))
    }

    static func targetStats(_ id: Int64, _ f: DashFilter) -> TargetStats {
        let (w, p) = f.clause(ssid: nil, bssid: nil, band: nil)
        var s = TargetStats()
        if let r = db.query("SELECT COUNT(*) n, AVG(ok) up, AVG(latency) lat, SUM(1 - ok) fails FROM target_results WHERE target_id = ? AND \(w)", [id] + p).first {
            s.checks = r.int("n") ?? 0; s.uptime = s.checks > 0 ? r.double("up") : nil
            s.avgLatency = r.double("lat"); s.failures = r.int("fails") ?? 0
        }
        let n = Int(db.scalar("SELECT COUNT(*) FROM target_results WHERE target_id = ? AND latency IS NOT NULL AND \(w)", [id] + p) ?? 0)
        if n > 0 {
            s.p95Latency = db.scalar("SELECT latency FROM target_results WHERE target_id = ? AND latency IS NOT NULL AND \(w) ORDER BY latency LIMIT 1 OFFSET ?",
                                     [id] + p + [Int(Double(n) * 0.95)])
        }
        return s
    }

    /// Bucketed latency (avg) and availability for one target.
    static func targetHistory(_ id: Int64, _ f: DashFilter, points: Int = 120) -> [HistoryPoint] {
        var (from, to) = (f.interval.from.timeIntervalSince1970, f.interval.to.timeIntervalSince1970)
        if let first = db.scalar("SELECT MIN(ts) FROM target_results WHERE target_id = ?", [id]), first > from { from = first }
        let bucket = max(30, (max(to, from + 60) - from) / Double(points))
        let (w, p) = f.clause(ssid: nil, bssid: nil, band: nil)
        return db.query("""
            SELECT CAST(ts / ? AS INTEGER) * ? b, AVG(latency) lat, AVG(ok) up FROM target_results
            WHERE target_id = ? AND \(w) GROUP BY b ORDER BY b
            """, [bucket, bucket, id] + p).map {
            HistoryPoint(date: Date(timeIntervalSince1970: $0.double("b") ?? 0), inet: $0.double("lat"), up: $0.double("up"))
        }
    }

    static func targetFailures(_ id: Int64, limit: Int = 20) -> [TargetResult] {
        db.query("SELECT * FROM target_results WHERE target_id = ? AND ok = 0 ORDER BY ts DESC LIMIT ?", [id, limit]).map(targetResult)
    }
}
