import Foundation
import SwiftUI

// MARK: - Result types

struct TraceRow: Identifiable {
    var id: Int64
    var ts: Date
    var target: String
    var reached: Bool
    var local: Double?
    var isp: Double?        // added by the ISP segment
    var upstream: Double?   // added beyond the ISP
    var total: Double?
}

struct IPv6Row: Identifiable {
    var id: Date { ts }
    var ts: Date
    var hasV6: Bool
    var latency: Double?
    var loss: Double?
    var dns: Double?
    var v4: Double?
}

struct IdentityRow: Identifiable {
    var id: Date { ts }
    var ts: Date
    var publicIP: String?
    var asn: Int?
    var isp: String?
    var captive: Bool
    var ssid: String?
    var link: String?
    var vpn: String?
}

struct RoamRecord: Identifiable {
    var id: Date { ts }
    var ts: Date
    var from: String
    var to: String
    var ssid: String?
    var rssiBefore: Int?
    var rssiAfter: Int?
    var gap: Double          // seconds between last sample on old AP and first on new
    var latencyAfter: Double?
    var pingPong = false
}

struct StickyRecord: Identifiable {
    var id: Date { ts }
    var ts: Date
    var ssid: String?
    var bssid: String
    var rssi: Int
    var better: String
    var betterRssi: Int
}

struct APReliability: Identifiable {
    var id: String { bssid }
    var bssid: String
    var ssid: String?
    var band: String?
    var hours: Double
    var avgRssi: Double?
    var loss: Double?
    var disconnects: Int
    var roamsAway: Int
    var perHour: Double { hours > 0 ? Double(disconnects) / hours : 0 }
}

struct RoamReport {
    var roams: [RoamRecord] = []
    var sticky: [StickyRecord] = []
    var aps: [APReliability] = []
    var connectedHours = 0.0
    var roamsPerHour: Double { connectedHours > 0 ? Double(roams.count) / connectedHours : 0 }
    var medianGap: Double? {
        let g = roams.map(\.gap).sorted()
        return g.isEmpty ? nil : g[g.count / 2]
    }
    var pingPongs: Int { roams.filter(\.pingPong).count }
    var avgGain: Double? {
        let v = roams.compactMap { r in r.rssiAfter.flatMap { a in r.rssiBefore.map { Double(a - $0) } } }
        return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }
}

struct ChannelNoise: Identifiable {
    var id: String { "\(band ?? "?")-\(channel)" }
    var channel: Int
    var band: String?
    var samples: Int
    var median: Double
    var p95: Double
    var spikeShare: Double     // fraction of samples ≥ median + 6 dB
    var apsVisible: Double     // avg access points seen on this channel per scan
    var avgSnr: Double?
    var avgRssi: Double?
    var spikeHours: [Int: Int] // hour of day → spike count
}

struct Hint: Identifiable {
    var id: String { title }
    var title: String
    var detail: String
    var severity: Int          // 0 info, 1 warning, 2 problem
    var color: Color { [Color.blue, .orange, .red][min(2, max(0, severity))] }
    var icon: String { ["info.circle.fill", "exclamationmark.triangle.fill", "xmark.octagon.fill"][min(2, max(0, severity))] }
}

struct PresenceSession: Identifiable {
    var id: String { "\(mac)-\(start.timeIntervalSince1970)" }
    var mac: String
    var name: String
    var tag: String?
    var start: Date
    var end: Date
}

struct ConnRow: Identifiable {
    var id: String { "\(proto)|\(remote)|\(port)" }
    var remote: String
    var host: String?
    var port: Int
    var proto: String
    var rx: Double
    var tx: Double
    var lastSeen: Date
    var snapshots: Int
    var service: String { PortScanner.common[port] ?? (port == 443 ? "HTTPS" : "\(proto.lowercased())/\(port)") }
}

struct LinkUsage {
    var wifiBytes = 0.0
    var ethernetBytes = 0.0
    var time: [UsageGroup] = []     // seconds per link type
    var vpnSeconds = 0.0
    var vpnNames: [UsageGroup] = []
}

// MARK: - Queries

extension Queries {
    // MARK: Paths

    static func traceBaseline() -> (local: Double?, isp: Double?, upstream: Double?) {
        let since = Date().addingTimeInterval(-86400).timeIntervalSince1970
        let rows = db.query("SELECT local_ms l, isp_ms i, total_ms t FROM traces WHERE ts >= ?", [since])
        func median(_ v: [Double]) -> Double? { let s = v.sorted(); return s.isEmpty ? nil : s[s.count / 2] }
        let local = rows.compactMap { $0.double("l") }
        let isp = rows.compactMap { r in r.double("i").map { i in max(0, i - (r.double("l") ?? 0)) } }
        let up = rows.compactMap { r in r.double("t").flatMap { t in (r.double("i") ?? r.double("l")).map { max(0, t - $0) } } }
        return (median(local), median(isp), median(up))
    }

    static func traces(_ f: DashFilter) -> [TraceRow] {
        let (w, p) = f.clause(bssid: nil, band: nil)
        return db.query("SELECT * FROM traces WHERE \(w) ORDER BY ts", p).map { r in
            let l = r.double("local_ms"), i = r.double("isp_ms"), t = r.double("total_ms")
            return TraceRow(id: Int64(r.int("id") ?? 0), ts: r.date("ts") ?? Date(), target: r.string("target") ?? "",
                            reached: (r.int("reached") ?? 0) == 1, local: l, isp: i.map { max(0, $0 - (l ?? 0)) },
                            upstream: t.flatMap { t in (i ?? l).map { max(0, t - $0) } }, total: t)
        }
    }

    static func trace(id: Int64) -> TraceResult? {
        guard let r = db.query("SELECT * FROM traces WHERE id = ?", [id]).first else { return nil }
        let hops = db.query("SELECT * FROM trace_hops WHERE trace_id = ? ORDER BY hop", [id]).map { h in
            TraceHop(hop: h.int("hop") ?? 0, ip: h.string("ip"), rtt: h.double("rtt"), asn: h.int("asn"), owner: h.string("owner"),
                     segment: h.string("segment") ?? "")
        }
        return TraceResult(ts: r.date("ts") ?? Date(), target: r.string("target") ?? "", hops: hops, reached: (r.int("reached") ?? 0) == 1,
                           localMs: r.double("local_ms"), ispMs: r.double("isp_ms"), totalMs: r.double("total_ms"))
    }

    static func latestTrace() -> TraceResult? {
        db.scalar("SELECT MAX(id) FROM traces").flatMap { trace(id: Int64($0)) }
    }

    static func ipv6History(_ f: DashFilter) -> [IPv6Row] {
        let (w, p) = f.clause(bssid: nil, band: nil)
        return db.query("SELECT * FROM ipv6_samples WHERE \(w) ORDER BY ts", p).map { r in
            IPv6Row(ts: r.date("ts") ?? Date(), hasV6: (r.int("has_v6") ?? 0) == 1, latency: r.double("latency"),
                    loss: r.double("loss"), dns: r.double("dns_latency"), v4: r.double("v4_latency"))
        }
    }

    static func identityHistory(_ f: DashFilter) -> [IdentityRow] {
        let (w, p) = f.clause(bssid: nil, band: nil)
        return db.query("SELECT * FROM net_identity WHERE \(w) ORDER BY ts DESC LIMIT 500", p).map { r in
            IdentityRow(ts: r.date("ts") ?? Date(), publicIP: r.string("public_ip"), asn: r.int("asn"), isp: r.string("isp"),
                        captive: (r.int("captive") ?? 0) == 1, ssid: r.string("ssid"), link: r.string("link"), vpn: r.string("vpn"))
        }
    }

    // MARK: Roaming

    static func roaming(_ f: DashFilter) -> RoamReport {
        var rep = RoamReport()
        let (w, p) = f.clause()
        let rows = db.query("""
            SELECT ts, ssid, bssid, rssi, pt, pb, pr FROM (
                SELECT ts, ssid, bssid, rssi,
                       LAG(ts) OVER (ORDER BY ts) pt, LAG(bssid) OVER (ORDER BY ts) pb, LAG(rssi) OVER (ORDER BY ts) pr
                FROM samples WHERE \(w) AND connected = 1 AND bssid IS NOT NULL
            ) WHERE pb IS NOT NULL AND bssid != pb ORDER BY ts DESC LIMIT 2000
            """, p)
        var roams: [RoamRecord] = rows.compactMap { r in
            guard let ts = r.date("ts"), let to = r.string("bssid"), let from = r.string("pb"), let pt = r.date("pt") else { return nil }
            let gap = ts.timeIntervalSince(pt)
            guard gap <= 120 else { return nil }   // longer gaps are reconnects, not roams
            return RoamRecord(ts: ts, from: from, to: to, ssid: r.string("ssid"), rssiBefore: r.int("pr"), rssiAfter: r.int("rssi"), gap: gap)
        }
        roams.sort { $0.ts < $1.ts }
        for i in roams.indices where i > 0 {
            if roams[i].to == roams[i - 1].from && roams[i].ts.timeIntervalSince(roams[i - 1].ts) < 120 { roams[i].pingPong = true }
        }
        // Disruption right after each roam (latest 300).
        for i in roams.indices.suffix(300) {
            let t = roams[i].ts.timeIntervalSince1970
            roams[i].latencyAfter = db.scalar("SELECT MAX(inet_latency) FROM samples WHERE ts > ? AND ts <= ?", [t - 1, t + 15])
        }
        rep.roams = roams.reversed()
        rep.connectedHours = (db.scalar("SELECT COUNT(*) FROM samples WHERE \(w) AND connected = 1", p) ?? 0) * Prefs.sampleInterval / 3600

        // Sticky-client moments from scans: weak current AP while the same SSID is ≥ 8 dB stronger elsewhere.
        let (sw, sp) = f.clause(ssid: nil, bssid: nil, band: nil)
        rep.sticky = db.query("""
            WITH sc AS (SELECT DISTINCT ts FROM scans WHERE \(sw) ORDER BY ts DESC LIMIT 3000),
                 cur AS (SELECT sc.ts sts, (SELECT id FROM samples s WHERE s.ts BETWEEN sc.ts - 10 AND sc.ts + 10 AND s.connected = 1
                                            ORDER BY ABS(s.ts - sc.ts) LIMIT 1) sid FROM sc)
            SELECT cur.sts ts, s.ssid, s.bssid, s.rssi,
                   (SELECT x.bssid FROM scans x WHERE x.ts = cur.sts AND x.ssid = s.ssid AND x.bssid != s.bssid ORDER BY x.rssi DESC LIMIT 1) bb,
                   (SELECT MAX(x.rssi) FROM scans x WHERE x.ts = cur.sts AND x.ssid = s.ssid AND x.bssid != s.bssid) br
            FROM cur JOIN samples s ON s.id = cur.sid WHERE s.rssi < -68 AND s.bssid IS NOT NULL
            """, sp).compactMap { r in
            guard let rssi = r.int("rssi"), let br = r.int("br"), br - rssi >= 8, let b = r.string("bssid"), let bb = r.string("bb") else { return nil }
            return StickyRecord(ts: r.date("ts") ?? Date(), ssid: r.string("ssid"), bssid: b, rssi: rssi, better: bb, betterRssi: br)
        }

        // Per-AP reliability.
        let (ew, ep) = f.clause(band: nil)
        let disc = Dictionary(db.query("SELECT bssid, COUNT(*) c FROM events WHERE \(ew) AND type = 'disconnected' AND bssid IS NOT NULL GROUP BY bssid", ep)
            .compactMap { r in r.string("bssid").map { ($0, r.int("c") ?? 0) } }, uniquingKeysWith: +)
        let away = Dictionary(grouping: roams, by: \.from).mapValues(\.count)
        rep.aps = db.query("""
            SELECT bssid, MAX(ssid) ssid, MAX(band) band, COUNT(*) n, AVG(rssi) rssi, AVG(loss) loss
            FROM samples WHERE \(w) AND connected = 1 AND bssid IS NOT NULL GROUP BY bssid ORDER BY n DESC
            """, p).compactMap { r in
            guard let b = r.string("bssid") else { return nil }
            return APReliability(bssid: b, ssid: r.string("ssid"), band: r.string("band"),
                                 hours: Double(r.int("n") ?? 0) * Prefs.sampleInterval / 3600, avgRssi: r.double("rssi"),
                                 loss: r.double("loss"), disconnects: disc[b] ?? 0, roamsAway: away[b] ?? 0)
        }
        return rep
    }

    // MARK: Interference

    static func interference(_ f: DashFilter) -> (channels: [ChannelNoise], hints: [Hint]) {
        let (w, p) = f.clause()
        let hist = db.query("""
            SELECT channel, band, noise, COUNT(*) c FROM samples
            WHERE \(w) AND connected = 1 AND noise IS NOT NULL AND noise != 0 AND channel IS NOT NULL
            GROUP BY channel, band, noise
            """, p)
        let (nw, np) = f.clause(ssid: nil, bssid: nil)
        let scanCount = max(1, db.scalar("SELECT COUNT(DISTINCT ts) FROM scans WHERE \(nw)", np) ?? 1)
        let aps = Dictionary(db.query("SELECT channel, COUNT(*) c FROM scans WHERE \(nw) AND channel IS NOT NULL GROUP BY channel", np)
            .compactMap { r in r.int("channel").map { ($0, Double(r.int("c") ?? 0) / scanCount) } }, uniquingKeysWith: +)

        var grouped: [String: (ch: Int, band: String?, vals: [(Int, Int)])] = [:]
        for r in hist {
            guard let ch = r.int("channel"), let n = r.int("noise") else { continue }
            let k = "\(r.string("band") ?? "?")-\(ch)"
            grouped[k, default: (ch, r.string("band"), [])].vals.append((n, r.int("c") ?? 0))
        }
        var channels: [ChannelNoise] = []
        for (_, g) in grouped {
            let total = g.vals.reduce(0) { $0 + $1.1 }
            guard total > 10 else { continue }
            let sorted = g.vals.sorted { $0.0 < $1.0 }
            func pct(_ q: Double) -> Double {
                var acc = 0
                for (v, c) in sorted { acc += c; if Double(acc) >= Double(total) * q { return Double(v) } }
                return Double(sorted.last?.0 ?? 0)
            }
            let med = pct(0.5)
            let spikes = sorted.filter { Double($0.0) >= med + 6 }.reduce(0) { $0 + $1.1 }
            let extra = db.query("SELECT AVG(snr) snr, AVG(rssi) rssi FROM samples WHERE \(w) AND connected = 1 AND channel = ?", p + [g.ch]).first
            var hours: [Int: Int] = [:]
            if spikes > 0 {
                for r in db.query("""
                    SELECT CAST(strftime('%H', ts, 'unixepoch', 'localtime') AS INTEGER) h, COUNT(*) c FROM samples
                    WHERE \(w) AND connected = 1 AND channel = ? AND noise >= ? AND noise != 0 GROUP BY h
                    """, p + [g.ch, med + 6]) { hours[r.int("h") ?? 0] = r.int("c") ?? 0 }
            }
            channels.append(ChannelNoise(channel: g.ch, band: g.band, samples: total, median: med, p95: pct(0.95),
                                         spikeShare: Double(spikes) / Double(total), apsVisible: aps[g.ch] ?? 0,
                                         avgSnr: extra?.double("snr"), avgRssi: extra?.double("rssi"), spikeHours: hours))
        }
        channels.sort { $0.samples > $1.samples }
        return (channels, hints(channels))
    }

    private static func hints(_ channels: [ChannelNoise]) -> [Hint] {
        var out: [Hint] = []
        if channels.isEmpty {
            return [Hint(title: "Not enough data yet", detail: "Interference hints need some connected samples with a noise reading.", severity: 0)]
        }
        if channels.allSatisfy({ $0.p95 - $0.median < 1 }) {
            out.append(Hint(title: "Your Mac reports a flat noise floor",
                            detail: "This Wi-Fi chip reports a fixed noise value, so noise spikes can't be seen directly. Hints below rely on SNR and congestion instead.",
                            severity: 0))
        }
        for c in channels {
            let is24 = c.band == "2.4 GHz"
            let name = "ch \(c.channel) (\(c.band ?? "?"))"
            if c.spikeShare > 0.05 && c.apsVisible <= 2.5 {
                let meal = [11, 12, 13, 18, 19, 20, 21].reduce(0) { $0 + (c.spikeHours[$1] ?? 0) }
                let all = max(1, c.spikeHours.values.reduce(0, +))
                var detail = "Noise jumps ≥ 6 dB above normal \(Int(c.spikeShare * 100))% of the time, but only \(String(format: "%.1f", c.apsVisible)) networks share this channel — the source is probably not Wi-Fi."
                if is24 && Double(meal) / Double(all) > 0.5 {
                    detail += " Spikes cluster around meal times: a microwave oven near the router or this Mac is the classic cause."
                } else if is24 {
                    detail += " Typical 2.4 GHz culprits: microwave ovens, Bluetooth, baby monitors, wireless cameras/doorbells, cordless phones, USB 3 hubs."
                } else {
                    detail += " On 5 GHz this can be radar (DFS), wireless video senders, or nearby equipment."
                }
                out.append(Hint(title: "Likely non-Wi-Fi interference on \(name)", detail: detail, severity: 2))
            } else if c.spikeShare > 0.05 {
                out.append(Hint(title: "Noisy periods on \(name)",
                                detail: "Noise is ≥ 6 dB above its baseline \(Int(c.spikeShare * 100))% of the time with \(String(format: "%.1f", c.apsVisible)) neighbouring networks — could be busy neighbours or a non-Wi-Fi source.",
                                severity: 1))
            }
            if c.median > (is24 ? -85 : -88) {
                out.append(Hint(title: "Raised noise floor on \(name)",
                                detail: "Median noise is \(Int(c.median)) dBm (healthy is about −90 to −95 dBm). Move the router away from electronics/metal, or try another channel.",
                                severity: 1))
            }
            if let snr = c.avgSnr, let rssi = c.avgRssi, rssi > -65, snr < 25 {
                out.append(Hint(title: "Strong signal but poor SNR on \(name)",
                                detail: "Signal averages \(Int(rssi)) dBm yet SNR is only \(Int(snr)) dB — something is adding noise close to this Mac.",
                                severity: 1))
            }
            if c.apsVisible >= 6 {
                out.append(Hint(title: "Crowded channel \(name)",
                                detail: "About \(Int(c.apsVisible)) other networks are on this channel (Wi-Fi congestion rather than non-Wi-Fi noise). See Nearby Networks for the least-used channel.",
                                severity: 1))
            }
        }
        if out.isEmpty || out.allSatisfy({ $0.severity == 0 }) {
            out.append(Hint(title: "No interference detected", detail: "Noise and SNR look normal on the channels you used in this range.", severity: 0))
        }
        return out
    }

    // MARK: Presence

    static func presence(_ f: DashFilter) -> [PresenceSession] {
        let (from, to) = f.interval
        return db.query("""
            SELECT s.mac, s.start, s.end, d.tag,
                   COALESCE(d.nickname, d.friendly_name, d.mdns_name, d.netbios_name, d.hostname, d.ip, s.mac) name
            FROM device_sessions s LEFT JOIN devices d ON d.mac = s.mac
            WHERE s.end >= ? AND s.start <= ? ORDER BY s.start
            """, [from.timeIntervalSince1970, to.timeIntervalSince1970]).compactMap { r in
            guard let mac = r.string("mac"), let a = r.date("start"), let b = r.date("end") else { return nil }
            return PresenceSession(mac: mac, name: r.string("name") ?? mac, tag: r.string("tag"),
                                   start: max(a, from), end: min(max(b, a.addingTimeInterval(60)), to))
        }
    }

    // MARK: Link type usage

    static func linkUsage(_ f: DashFilter) -> LinkUsage {
        var u = LinkUsage()
        let (w, p) = f.isNetworkFiltered ? f.clause() : f.clause(ssid: nil, bssid: nil, band: nil)
        if let r = db.query("""
            SELECT SUM(COALESCE(rx_bytes,0) + COALESCE(tx_bytes,0)) wifi, SUM(COALESCE(eth_rx_bytes,0) + COALESCE(eth_tx_bytes,0)) eth,
                   SUM(CASE WHEN vpn IS NOT NULL THEN 1 ELSE 0 END) vpn
            FROM samples WHERE \(w)
            """, p).first {
            u.wifiBytes = r.double("wifi") ?? 0; u.ethernetBytes = r.double("eth") ?? 0
            u.vpnSeconds = (r.double("vpn") ?? 0) * Prefs.sampleInterval
        }
        u.time = db.query("SELECT COALESCE(link, 'Wi-Fi') k, COUNT(*) n FROM samples WHERE \(w) GROUP BY k ORDER BY n DESC", p).map {
            UsageGroup(name: $0.string("k") ?? "?", rx: Double($0.int("n") ?? 0) * Prefs.sampleInterval, tx: 0, seconds: Double($0.int("n") ?? 0) * Prefs.sampleInterval)
        }
        u.vpnNames = db.query("SELECT vpn, COUNT(*) n FROM samples WHERE \(w) AND vpn IS NOT NULL GROUP BY vpn ORDER BY n DESC", p).map {
            UsageGroup(name: $0.string("vpn") ?? "?", rx: Double($0.int("n") ?? 0) * Prefs.sampleInterval, tx: 0)
        }
        return u
    }

    // MARK: Connections

    static func connectionApps(_ f: DashFilter) -> [String] {
        let (from, to) = f.interval
        return db.query("SELECT app, COUNT(DISTINCT remote) n FROM app_connections WHERE ts >= ? AND ts <= ? GROUP BY app ORDER BY n DESC",
                        [from.timeIntervalSince1970, to.timeIntervalSince1970]).compactMap { $0.string("app") }
    }

    static func connections(app: String, _ f: DashFilter) -> [ConnRow] {
        let (from, to) = f.interval
        return db.query("""
            SELECT proto, remote, port, MAX(host) host, MAX(rx_bytes) rx, MAX(tx_bytes) tx, MAX(ts) last, COUNT(*) n
            FROM app_connections WHERE app = ? AND ts >= ? AND ts <= ?
            GROUP BY proto, remote, port ORDER BY MAX(rx_bytes + tx_bytes) DESC LIMIT 500
            """, [app, from.timeIntervalSince1970, to.timeIntervalSince1970]).map { r in
            ConnRow(remote: r.string("remote") ?? "?", host: r.string("host"), port: r.int("port") ?? 0, proto: r.string("proto") ?? "",
                    rx: r.double("rx") ?? 0, tx: r.double("tx") ?? 0, lastSeen: r.date("last") ?? Date(), snapshots: r.int("n") ?? 0)
        }
    }

    // MARK: Bufferbloat by hour

    static func bloatByHour(_ f: DashFilter) -> [UsageGroup] {
        let (w, p) = f.clause()
        return db.query("""
            SELECT CAST(strftime('%H', ts, 'unixepoch', 'localtime') AS INTEGER) h,
                   AVG(MAX(0, COALESCE(loaded_latency, 60000.0 / responsiveness) - base_rtt)) bloat, COUNT(*) n
            FROM speedtests WHERE \(w) AND base_rtt IS NOT NULL AND (loaded_latency IS NOT NULL OR responsiveness > 0)
            GROUP BY h ORDER BY h
            """, p).map { UsageGroup(name: String(format: "%02d:00", $0.int("h") ?? 0), detail: "\($0.int("n") ?? 0) tests", rx: $0.double("bloat") ?? 0, tx: 0) }
    }
}
