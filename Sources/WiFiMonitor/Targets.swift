import Foundation
import Network
import Security

// MARK: - Watch targets (your own hosts / URLs to monitor)

enum TargetKind: String, CaseIterable, Identifiable {
    case ping, tcp, http, tls
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ping: return "Ping (ICMP)"
        case .tcp: return "TCP port"
        case .http: return "HTTP(S) URL"
        case .tls: return "TLS certificate"
        }
    }
    var placeholder: String {
        switch self {
        case .ping: return "192.168.1.10 or example.com"
        case .tcp: return "nas.local:445 or example.com:22"
        case .http: return "https://example.com/health"
        case .tls: return "example.com or example.com:8443"
        }
    }
    var icon: String {
        switch self {
        case .ping: return "dot.radiowaves.right"
        case .tcp: return "point.3.connected.trianglepath.dotted"
        case .http: return "globe"
        case .tls: return "lock.shield"
        }
    }
}

struct WatchTarget: Identifiable, Hashable {
    var id: Int64
    var name: String
    var kind: TargetKind
    var target: String
    var interval: Double
    var enabled: Bool
}

struct TargetResult {
    var ts = Date()
    var ok: Bool
    var latency: Double?      // ms
    var status: Int?          // HTTP status
    var detail: String?
    var certExpiry: Date?

    var certDaysLeft: Int? { certExpiry.map { Int($0.timeIntervalSinceNow / 86400) } }
}

/// Days of certificate validity below which a TLS target counts as failing.
let certWarningDays = 14

enum TargetChecker {
    static func check(_ t: WatchTarget) -> TargetResult {
        switch t.kind {
        case .ping:
            let ms = ICMP.ping(t.target, timeoutMs: 2000)
            return TargetResult(ok: ms != nil, latency: ms, detail: ms == nil ? "No reply" : nil)
        case .tcp:
            let (host, port) = hostPort(t.target, defaultPort: 80)
            return tcpConnect(host: host, port: port)
        case .http:
            return http(t.target)
        case .tls:
            let (host, port) = hostPort(t.target.replacingOccurrences(of: "https://", with: ""), defaultPort: 443)
            var r = http("https://\(host):\(port)/", acceptAnyStatus: true)
            if let days = r.certDaysLeft {
                r.ok = days >= certWarningDays
                r.detail = r.ok ? "Valid for \(days) days" : (days < 0 ? "Expired \(-days) days ago" : "Expires in \(days) days")
            } else if r.ok {
                r.ok = false
                r.detail = r.detail ?? "No certificate"
            }
            return r
        }
    }

    static func hostPort(_ s: String, defaultPort: UInt16) -> (String, UInt16) {
        var str = s
        if let r = str.range(of: "://") { str = String(str[r.upperBound...]) }
        str = String(str.split(separator: "/").first ?? "")
        if let colon = str.lastIndex(of: ":"), let p = UInt16(str[str.index(after: colon)...]) {
            return (String(str[..<colon]), p)
        }
        return (str, defaultPort)
    }

    private static func tcpConnect(host: String, port: UInt16, timeout: Double = 5) -> TargetResult {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return TargetResult(ok: false, detail: "Bad port") }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let sem = DispatchSemaphore(value: 0)
        var result = TargetResult(ok: false, detail: "Timed out")
        let start = DispatchTime.now().uptimeNanoseconds
        var done = false
        let lock = NSLock()
        conn.stateUpdateHandler = { state in
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            switch state {
            case .ready:
                result = TargetResult(ok: true, latency: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6, detail: "Port \(port) open")
                done = true; sem.signal()
            case .failed(let e), .waiting(let e):
                result = TargetResult(ok: false, detail: e.localizedDescription)
                done = true; sem.signal()
            default: break
            }
        }
        conn.start(queue: .global(qos: .utility))
        _ = sem.wait(timeout: .now() + timeout)
        conn.cancel()
        return result
    }

    private static func http(_ urlString: String, acceptAnyStatus: Bool = false) -> TargetResult {
        var s = urlString.trimmingCharacters(in: .whitespaces)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s) else { return TargetResult(ok: false, detail: "Invalid URL") }
        let probe = CertProbe()
        let session = URLSession(configuration: .ephemeral, delegate: probe, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 10)
        req.setValue("WiFiMonitor/1.0 (uptime check)", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var result = TargetResult(ok: false, detail: "Timed out")
        let start = DispatchTime.now().uptimeNanoseconds
        session.dataTask(with: req) { _, resp, err in
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            if let http = resp as? HTTPURLResponse {
                let ok = acceptAnyStatus || (200..<400).contains(http.statusCode)
                result = TargetResult(ok: ok, latency: ms, status: http.statusCode, detail: "HTTP \(http.statusCode)")
            } else if let err {
                result = TargetResult(ok: false, latency: nil, detail: err.localizedDescription)
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 12)
        result.certExpiry = probe.expiry
        return result
    }
}

/// Captures the leaf certificate's expiry date while letting normal validation proceed.
private final class CertProbe: NSObject, URLSessionDelegate {
    var expiry: Date?
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust,
           let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first,
           let values = SecCertificateCopyValues(leaf, [kSecOIDX509V1ValidityNotAfter] as CFArray, nil) as? [CFString: Any],
           let entry = values[kSecOIDX509V1ValidityNotAfter] as? [CFString: Any],
           let num = entry[kSecPropertyKeyValue] as? NSNumber {
            expiry = Date(timeIntervalSinceReferenceDate: num.doubleValue)
        }
        completionHandler(.performDefaultHandling, nil)
    }
}

// MARK: - Monthly data cap

enum DataCap {
    static var enabled: Bool { UserDefaults.standard.bool(forKey: "capEnabled") }
    static var capBytes: Double { max(1, UserDefaults.standard.double(forKey: "capGB")) * 1_073_741_824 }
    static var resetDay: Int { min(28, max(1, UserDefaults.standard.integer(forKey: "capResetDay"))) }
    /// "mac" = this Mac's Wi-Fi traffic, "network" = whole-network WAN traffic from the router.
    static var scope: String { UserDefaults.standard.string(forKey: "capScope") ?? "mac" }

    /// Billing cycle [start, end) containing `now`; `offset: -1` is the previous cycle.
    /// Used with or without a cap: the cycle start day is its own setting.
    static func cycle(now: Date = Date(), offset: Int = 0) -> (start: Date, end: Date) {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month], from: now)
        comps.day = resetDay
        var start = cal.date(from: comps)!
        if start > now { start = cal.date(byAdding: .month, value: -1, to: start)! }
        if offset != 0 { start = cal.date(byAdding: .month, value: offset, to: start)! }
        return (start, cal.date(byAdding: .month, value: 1, to: start)!)
    }

    struct Status {
        var used: Double
        var cap: Double
        var start: Date
        var end: Date
        var fraction: Double { used / cap }
        var elapsedFraction: Double { min(1, max(0.001, Date().timeIntervalSince(start) / end.timeIntervalSince(start))) }
        var projected: Double { used / elapsedFraction }
        var daysLeft: Int { max(0, Int(ceil(end.timeIntervalSinceNow / 86400))) }
        var dailyBudget: Double { daysLeft > 0 ? max(0, cap - used) / Double(daysLeft) : 0 }
    }

    static func status() -> Status {
        let (start, end) = cycle()
        let sql = scope == "network"
            ? "SELECT SUM(COALESCE(wan_rx_bytes,0) + COALESCE(wan_tx_bytes,0)) FROM router_stats WHERE ts >= ?"
            : "SELECT SUM(COALESCE(rx_bytes,0) + COALESCE(tx_bytes,0)) FROM samples WHERE ts >= ?"
        let used = Database.shared.scalar(sql, [start.timeIntervalSince1970]) ?? 0
        return Status(used: used, cap: capBytes, start: start, end: end)
    }
}
