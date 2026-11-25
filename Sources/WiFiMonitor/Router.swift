import Foundation
import Security
import Darwin

// MARK: - Model

enum RouterKind: String, CaseIterable, Identifiable {
    case none, upnp, snmp, zte, openwrt, mikrotik, asus, fritzbox, unifi, opnsense, omada, netgear, pfsense
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Disabled"
        case .upnp: return "UPnP (no password — most home/ISP routers)"
        case .snmp: return "SNMP v2c (community string)"
        case .openwrt: return "OpenWrt / GL.iNet (username + password)"
        case .mikrotik: return "MikroTik RouterOS 7 REST (username + password)"
        case .asus: return "ASUS (AsusWRT / Merlin, username + password)"
        case .fritzbox: return "AVM FRITZ!Box (TR-064, username + password)"
        case .unifi: return "Ubiquiti UniFi (UDM / Cloud Key / controller)"
        case .opnsense: return "OPNsense (API key + secret)"
        case .omada: return "TP-Link Omada controller (OpenAPI client ID + secret)"
        case .netgear: return "Netgear / Orbi (SOAP, admin password)"
        case .pfsense: return "pfSense (REST API package)"
        case .zte: return "ZTE fibre router (Airtel / Jio / BSNL — F670L, F680…)"
        }
    }
    var needsLogin: Bool { ![.none, .upnp, .snmp].contains(self) }
    var userLabel: String {
        switch self {
        case .opnsense: return "API key"
        case .omada: return "Client ID"
        case .pfsense: return "Username (leave empty to use an API key)"
        default: return "Username"
        }
    }
    var passwordLabel: String {
        switch self {
        case .opnsense, .omada: return "Client / API secret (stored in macOS Keychain)"
        case .pfsense: return "Password or API key (stored in macOS Keychain)"
        default: return "Password (stored in macOS Keychain)"
        }
    }
}

struct RouterInterface: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var rx: UInt64
    var tx: UInt64
    var up: Bool?
}

struct RouterClient: Identifiable, Hashable {
    var id: String { mac }
    var mac: String
    var ip: String?
    var name: String?
    var signal: Int?
    var iface: String?
    var rxTotal: UInt64?   // bytes the router received from the client (client upload)
    var txTotal: UInt64?   // bytes the router sent to the client (client download)
    var connectedSeconds: Double?
    var ap: String? = nil  // access point / mesh node the client is attached to
}

struct RouterSnapshot {
    var ts = Date()
    var model: String?
    var firmware: String?
    var uptime: Double?
    var externalIP: String?
    var wanRx: UInt64?           // cumulative WAN counters (whole network)
    var wanTx: UInt64?
    var wanCounters32bit = false
    var linkDown: Double?        // bps
    var linkUp: Double?
    var linkStatus: String?
    var cpuLoad: Double?         // 0…1
    var memUsed: Double?         // 0…1
    var interfaces: [RouterInterface] = []
    var clients: [RouterClient] = []
}

struct RouterError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - Keychain (password never touches the database)

enum Keychain {
    private static let service = "local.wifimonitor.router"

    static func save(account: String, password: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        guard !password.isEmpty else { return }
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

// MARK: - Minimal synchronous HTTP (called from background threads only)

final class HTTP: NSObject, URLSessionDelegate {
    static let shared = HTTP()
    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        return URLSession(configuration: c, delegate: self, delegateQueue: nil)
    }()

    /// Accept self-signed certificates only for the router host the user configured.
    var trustedHost: String?

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == trustedHost, let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// Credential used for HTTP Digest/Basic challenges (FRITZ!Box TR-064).
    var credential: URLCredential?

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let m = challenge.protectionSpace.authenticationMethod
        if m == NSURLAuthenticationMethodServerTrust {
            urlSession(session, didReceive: challenge, completionHandler: completionHandler)
        } else if (m == NSURLAuthenticationMethodHTTPDigest || m == NSURLAuthenticationMethodHTTPBasic),
                  let credential, challenge.previousFailureCount == 0, challenge.protectionSpace.host == trustedHost {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func request(_ url: URL, method: String = "GET", headers: [String: String] = [:], body: Data? = nil) -> (status: Int, data: Data)? {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.httpBody = body
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let sem = DispatchSemaphore(value: 0)
        var result: (Int, Data)?
        session.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse { result = (http.statusCode, data ?? Data()) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 10)
        return result
    }
}

// MARK: - Router client

/// Polls a router using the configured protocol. Holds a little state (cached UPnP URLs, OpenWrt session).
final class RouterClientService {
    struct Config: Equatable {
        var kind: RouterKind
        var host: String
        var username: String
        var password: String
        var community: String
        var wanInterface: String
        var https: Bool
        var site: String = "default"
    }

    private var upnpControl: (common: (url: URL, type: String)?, conn: (url: URL, type: String)?)?
    private var upnpHost: String?
    private var ubusSession: String?
    fileprivate var asusToken: String?
    fileprivate var asusPrevCPU: (total: Double, used: Double)?
    fileprivate var unifiBase: String?
    var omadaToken: (id: String, token: String, site: String, expires: Date)?
    var netgearLoggedIn = false
    var zteLoggedIn = false
    var zteLoginBlockedUntil: Date?

    func poll(_ c: Config) -> Result<RouterSnapshot, RouterError> {
        guard !c.host.isEmpty else { return .failure(RouterError("No router address (gateway unknown)")) }
        HTTP.shared.trustedHost = c.host.split(separator: ":").first.map(String.init) ?? c.host
        switch c.kind {
        case .none: return .failure(RouterError("Router integration disabled"))
        case .upnp: return pollUPnP(c)
        case .snmp: return pollSNMP(c)
        case .openwrt: return pollOpenWrt(c)
        case .mikrotik: return pollMikroTik(c)
        case .asus: return pollASUS(c)
        case .fritzbox: return pollFritz(c)
        case .unifi: return pollUniFi(c)
        case .opnsense: return pollOPNsense(c)
        case .omada: return pollOmada(c)
        case .netgear: return pollNetgear(c)
        case .pfsense: return pollPfSense(c)
        case .zte: return pollZTE(c)
        }
    }

    // MARK: UPnP IGD

    private func pollUPnP(_ c: Config) -> Result<RouterSnapshot, RouterError> {
        if upnpControl == nil || upnpHost != c.host {
            guard let loc = ssdpDiscover(preferHost: c.host) else {
                return .failure(RouterError("No UPnP gateway answered. Enable UPnP on the router, or pick another method."))
            }
            guard let desc = HTTP.shared.request(loc), let xml = String(data: desc.data, encoding: .utf8) else {
                return .failure(RouterError("Could not read UPnP description at \(loc)"))
            }
            upnpControl = parseUPnPServices(xml, base: loc)
            upnpHost = c.host
        }
        guard let ctl = upnpControl, ctl.common != nil || ctl.conn != nil else {
            upnpControl = nil
            return .failure(RouterError("Router speaks UPnP but exposes no WAN statistics service"))
        }
        var s = RouterSnapshot()
        if let common = ctl.common {
            // Some routers (e.g. AVM) offer 64-bit counters via GetAddonInfos; prefer them.
            if let r = soap(common, "GetAddonInfos"), let rx = r["NewX_AVM_DE_TotalBytesReceived64"].flatMap(UInt64.init),
               let tx = r["NewX_AVM_DE_TotalBytesSent64"].flatMap(UInt64.init) {
                s.wanRx = rx; s.wanTx = tx
            } else {
                s.wanRx = soap(common, "GetTotalBytesReceived")?["NewTotalBytesReceived"].flatMap(UInt64.init)
                s.wanTx = soap(common, "GetTotalBytesSent")?["NewTotalBytesSent"].flatMap(UInt64.init)
                s.wanCounters32bit = true
            }
            if let l = soap(common, "GetCommonLinkProperties") {
                s.linkDown = l["NewLayer1DownstreamMaxBitRate"].flatMap(Double.init)
                s.linkUp = l["NewLayer1UpstreamMaxBitRate"].flatMap(Double.init)
                s.linkStatus = l["NewPhysicalLinkStatus"]
            }
        }
        if let conn = ctl.conn {
            s.externalIP = soap(conn, "GetExternalIPAddress")?["NewExternalIPAddress"]
            if let st = soap(conn, "GetStatusInfo") {
                s.uptime = st["NewUptime"].flatMap(Double.init)
                if s.linkStatus == nil { s.linkStatus = st["NewConnectionStatus"] }
            }
        }
        if s.externalIP?.isEmpty == true { s.externalIP = nil }
        if s.wanRx == 0 && s.wanTx == 0 { s.wanRx = nil; s.wanTx = nil } // stub counters on some ISP firmware
        if s.wanRx == nil || s.wanTx == nil {
            if s.externalIP == nil {
                upnpControl = nil
                return .failure(RouterError("Your router answers UPnP but doesn't expose traffic counters (common on ISP routers). Try SNMP, or OpenWrt/MikroTik if you run one."))
            }
            s.wanRx = nil; s.wanTx = nil
        }
        return .success(s)
    }

    private func ssdpDiscover(preferHost: String) -> URL? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 300_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &addr.sin_addr)
        var found: [URL] = []
        for st in ["urn:schemas-upnp-org:device:InternetGatewayDevice:1", "urn:schemas-upnp-org:device:InternetGatewayDevice:2",
                   "urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1"] {
            let msg = Array("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: \(st)\r\n\r\n".utf8)
            _ = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
        let deadline = Date().addingTimeInterval(2.5)
        var buf = [UInt8](repeating: 0, count: 2048)
        while Date() < deadline {
            let n = recv(fd, &buf, buf.count, 0)
            guard n > 0 else { continue }
            let text = String(decoding: buf[0..<n], as: UTF8.self)
            for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
                if let u = URL(string: line.dropFirst(9).trimmingCharacters(in: .whitespaces)) {
                    if u.host == preferHost { return u }
                    found.append(u)
                }
            }
        }
        return found.first
    }

    private func parseUPnPServices(_ xml: String, base: URL) -> (common: (url: URL, type: String)?, conn: (url: URL, type: String)?) {
        func tag(_ name: String, in s: String) -> String? {
            guard let a = s.range(of: "<\(name)>"), let b = s.range(of: "</\(name)>", range: a.upperBound..<s.endIndex) else { return nil }
            return String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let urlBase = tag("URLBase", in: xml).flatMap(URL.init(string:)) ?? base
        var common: (URL, String)?, conn: (URL, String)?
        for chunk in xml.components(separatedBy: "<service>").dropFirst() {
            guard let type = tag("serviceType", in: chunk), let ctl = tag("controlURL", in: chunk),
                  let url = URL(string: ctl, relativeTo: urlBase)?.absoluteURL else { continue }
            if type.contains("WANCommonInterfaceConfig") { common = (url, type) }
            if type.contains("WANIPConnection") || (type.contains("WANPPPConnection") && conn == nil) { conn = (url, type) }
        }
        return (common, conn)
    }

    private func soap(_ svc: (url: URL, type: String), _ action: String) -> [String: String]? {
        let body = """
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(svc.type)"></u:\(action)></s:Body></s:Envelope>
        """
        guard let r = HTTP.shared.request(svc.url, method: "POST",
                                          headers: ["Content-Type": "text/xml; charset=\"utf-8\"", "SOAPAction": "\"\(svc.type)#\(action)\""],
                                          body: Data(body.utf8)),
              r.status == 200, let xml = String(data: r.data, encoding: .utf8) else { return nil }
        var out: [String: String] = [:]
        let pattern = try! NSRegularExpression(pattern: "<(New[A-Za-z0-9_]+)>([^<]*)</")
        for m in pattern.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            if let k = Range(m.range(at: 1), in: xml), let v = Range(m.range(at: 2), in: xml) { out[String(xml[k])] = String(xml[v]) }
        }
        return out
    }

    // MARK: SNMP v2c (uses the net-snmp tools bundled with macOS)

    private func snmp(_ cmd: String, _ c: Config, _ oids: [String]) -> [(oid: String, value: String)] {
        let out = Shell.run("/usr/bin/\(cmd)", ["-v2c", "-c", c.community, "-Onqt", "-t", "2", "-r", "1", c.host] + oids, timeout: 20).output
        return out.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\" ")))
        }
    }

    private func pollSNMP(_ c: Config) -> Result<RouterSnapshot, RouterError> {
        let sys = snmp("snmpget", c, [".1.3.6.1.2.1.1.1.0", ".1.3.6.1.2.1.1.3.0", ".1.3.6.1.2.1.1.5.0"])
        guard !sys.isEmpty else { return .failure(RouterError("No SNMP response from \(c.host) (check community string and that SNMP is enabled)")) }
        var s = RouterSnapshot()
        for (oid, v) in sys {
            if oid.hasSuffix("1.1.1.0") { s.firmware = v }
            if oid.hasSuffix("1.1.3.0") { s.uptime = Double(v).map { $0 / 100 } }
            if oid.hasSuffix("1.1.5.0") { s.model = v }
        }
        func column(_ base: String) -> [String: String] {
            Dictionary(snmp("snmpwalk", c, [base]).map { (String($0.oid.dropFirst(base.count + 1)), $0.value) }, uniquingKeysWith: { a, _ in a })
        }
        let names = column(".1.3.6.1.2.1.31.1.1.1.1").merging(column(".1.3.6.1.2.1.2.2.1.2")) { a, _ in a }
        let inHC = column(".1.3.6.1.2.1.31.1.1.1.6"), outHC = column(".1.3.6.1.2.1.31.1.1.1.10")
        let status = column(".1.3.6.1.2.1.2.2.1.8")
        s.interfaces = names.compactMap { idx, name in
            guard let rx = inHC[idx].flatMap(UInt64.init), let tx = outHC[idx].flatMap(UInt64.init) else { return nil }
            return RouterInterface(name: name, rx: rx, tx: tx, up: status[idx].map { $0 == "1" || $0.hasPrefix("up") })
        }.sorted { $0.rx + $0.tx > $1.rx + $1.tx }
        if let wan = pickWAN(s.interfaces, preferred: c.wanInterface) { s.wanRx = wan.rx; s.wanTx = wan.tx }
        let cpu = column(".1.3.6.1.2.1.25.3.3.1.2").values.compactMap(Double.init)
        if !cpu.isEmpty { s.cpuLoad = cpu.reduce(0, +) / Double(cpu.count) / 100 }
        return .success(s)
    }

    private func pickWAN(_ ifaces: [RouterInterface], preferred: String) -> RouterInterface? {
        if !preferred.isEmpty, let i = ifaces.first(where: { $0.name == preferred }) { return i }
        let hints = ["wan", "ppp", "pppoe", "ether1", "eth0.2", "internet", "dsl"]
        if let i = ifaces.first(where: { n in hints.contains { n.name.lowercased().contains($0) } }) { return i }
        return ifaces.first { i in !["lo", "br", "bridge"].contains { i.name.lowercased().hasPrefix($0) } }
    }

    // MARK: OpenWrt (ubus JSON-RPC over HTTP)

    private func ubus(_ c: Config, _ obj: String, _ method: String, _ args: [String: Any] = [:]) -> [String: Any]? {
        let scheme = c.https ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(c.host)/ubus") else { return nil }
        let sid = obj == "session" ? "00000000000000000000000000000000" : (ubusSession ?? "")
        let payload: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "call", "params": [sid, obj, method, args]]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let r = HTTP.shared.request(url, method: "POST", headers: ["Content-Type": "application/json"], body: body),
              let json = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any],
              let result = json["result"] as? [Any], let code = result.first as? Int else { return nil }
        if code != 0 { if code == 6 { ubusSession = nil }; return nil }
        return result.count > 1 ? result[1] as? [String: Any] : [:]
    }

    private func pollOpenWrt(_ c: Config) -> Result<RouterSnapshot, RouterError> {
        if ubusSession == nil {
            guard let r = ubus(c, "session", "login", ["username": c.username, "password": c.password]),
                  let sid = r["ubus_rpc_session"] as? String else {
                return .failure(RouterError("OpenWrt login failed — check address, username and password (rpcd/uhttpd-mod-ubus must be installed)"))
            }
            ubusSession = sid
        }
        var s = RouterSnapshot()
        guard let info = ubus(c, "system", "info") else {
            ubusSession = nil
            return .failure(RouterError("OpenWrt session expired — will log in again"))
        }
        s.uptime = (info["uptime"] as? NSNumber)?.doubleValue
        if let load = info["load"] as? [NSNumber], let l1 = load.first { s.cpuLoad = l1.doubleValue / 65536 }
        if let mem = info["memory"] as? [String: NSNumber], let total = mem["total"]?.doubleValue, total > 0 {
            let avail = (mem["available"] ?? mem["free"])?.doubleValue ?? 0
            s.memUsed = 1 - avail / total
        }
        if let board = ubus(c, "system", "board") {
            s.model = board["model"] as? String
            s.firmware = (board["release"] as? [String: Any])?["description"] as? String
        }
        let wanName = c.wanInterface.isEmpty ? "wan" : c.wanInterface
        if let wan = ubus(c, "network.interface.\(wanName)", "status") {
            s.externalIP = ((wan["ipv4-address"] as? [[String: Any]])?.first?["address"] as? String)
            s.linkStatus = (wan["up"] as? Bool) == true ? "Up" : "Down"
            if let dev = (wan["l3_device"] ?? wan["device"]) as? String,
               let st = ubus(c, "network.device", "status", ["name": dev])?["statistics"] as? [String: NSNumber] {
                s.wanRx = st["rx_bytes"]?.uint64Value; s.wanTx = st["tx_bytes"]?.uint64Value
            }
        }
        // DHCP names, then Wi-Fi association lists with per-client signal and bytes.
        var names: [String: (ip: String?, name: String?)] = [:]
        if let leases = ubus(c, "luci-rpc", "getDHCPLeases")?["dhcp_leases"] as? [[String: Any]] {
            for l in leases { if let mac = (l["macaddr"] as? String)?.lowercased() { names[mac] = (l["ipaddr"] as? String, l["hostname"] as? String) } }
        }
        var clients: [String: RouterClient] = [:]
        for (mac, v) in names { clients[mac] = RouterClient(mac: mac, ip: v.ip, name: v.name) }
        if let devs = ubus(c, "iwinfo", "devices")?["devices"] as? [String] {
            for d in devs {
                guard let list = ubus(c, "iwinfo", "assoclist", ["device": d])?["results"] as? [[String: Any]] else { continue }
                for a in list {
                    guard let mac = (a["mac"] as? String)?.lowercased() else { continue }
                    var cl = clients[mac] ?? RouterClient(mac: mac)
                    cl.signal = (a["signal"] as? NSNumber)?.intValue
                    cl.iface = d
                    cl.ap = d
                    cl.rxTotal = ((a["rx"] as? [String: Any])?["bytes"] as? NSNumber)?.uint64Value
                    cl.txTotal = ((a["tx"] as? [String: Any])?["bytes"] as? NSNumber)?.uint64Value
                    cl.connectedSeconds = (a["connected_time"] as? NSNumber)?.doubleValue
                    clients[mac] = cl
                }
            }
        }
        // nlbwmon (if installed) gives per-device traffic for every host, wired included.
        if let nl = ubus(c, "file", "exec", ["command": "/usr/sbin/nlbw", "params": ["-c", "json", "-g", "mac"]]),
           let stdout = nl["stdout"] as? String, let data = stdout.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cols = json["columns"] as? [String], let rows = json["data"] as? [[Any]],
           let mi = cols.firstIndex(of: "mac"), let rxi = cols.firstIndex(of: "rx_bytes"), let txi = cols.firstIndex(of: "tx_bytes") {
            let ipi = cols.firstIndex(of: "ip")
            for row in rows where row.count > max(mi, rxi, txi) {
                guard let mac = (row[mi] as? String)?.lowercased(), mac != "00:00:00:00:00:00" else { continue }
                var cl = clients[mac] ?? RouterClient(mac: mac)
                // nlbw rx = downloaded by the host, tx = uploaded by the host
                cl.txTotal = (row[rxi] as? NSNumber)?.uint64Value
                cl.rxTotal = (row[txi] as? NSNumber)?.uint64Value
                if cl.ip == nil, let ipi, row.count > ipi { cl.ip = row[ipi] as? String }
                clients[mac] = cl
            }
        }
        s.clients = Array(clients.values)
        return .success(s)
    }

    // MARK: MikroTik RouterOS 7 REST

    private func mikrotik(_ c: Config, _ path: String) -> Any? {
        let scheme = c.https ? "https" : "http"
        guard let url = URL(string: "\(scheme)://\(c.host)/rest/\(path)") else { return nil }
        let auth = Data("\(c.username):\(c.password)".utf8).base64EncodedString()
        guard let r = HTTP.shared.request(url, headers: ["Authorization": "Basic \(auth)"]), r.status == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: r.data)
    }

    private func pollMikroTik(_ c: Config) -> Result<RouterSnapshot, RouterError> {
        guard let res = mikrotik(c, "system/resource") as? [String: Any] else {
            return .failure(RouterError("MikroTik REST login failed — RouterOS 7+ with the www/www-ssl service enabled is required"))
        }
        var s = RouterSnapshot()
        s.model = res["board-name"] as? String
        s.firmware = (res["version"] as? String).map { "RouterOS \($0)" }
        s.cpuLoad = (res["cpu-load"] as? String).flatMap(Double.init).map { $0 / 100 }
        if let free = (res["free-memory"] as? String).flatMap(Double.init), let total = (res["total-memory"] as? String).flatMap(Double.init), total > 0 {
            s.memUsed = 1 - free / total
        }
        s.uptime = (res["uptime"] as? String).map(parseROSDuration)
        if let ifs = mikrotik(c, "interface") as? [[String: Any]] {
            s.interfaces = ifs.compactMap { i in
                guard let n = i["name"] as? String, let rx = (i["rx-byte"] as? String).flatMap(UInt64.init),
                      let tx = (i["tx-byte"] as? String).flatMap(UInt64.init) else { return nil }
                return RouterInterface(name: n, rx: rx, tx: tx, up: (i["running"] as? String) == "true")
            }.sorted { $0.rx + $0.tx > $1.rx + $1.tx }
            if let wan = pickWAN(s.interfaces, preferred: c.wanInterface) { s.wanRx = wan.rx; s.wanTx = wan.tx }
        }
        var clients: [String: RouterClient] = [:]
        if let leases = mikrotik(c, "ip/dhcp-server/lease") as? [[String: Any]] {
            for l in leases {
                guard let mac = (l["mac-address"] as? String)?.lowercased() else { continue }
                clients[mac] = RouterClient(mac: mac, ip: (l["active-address"] ?? l["address"]) as? String, name: l["host-name"] as? String)
            }
        }
        let reg = (mikrotik(c, "interface/wifi/registration-table") ?? mikrotik(c, "interface/wireless/registration-table")) as? [[String: Any]] ?? []
        for r in reg {
            guard let mac = (r["mac-address"] as? String)?.lowercased() else { continue }
            var cl = clients[mac] ?? RouterClient(mac: mac)
            cl.iface = r["interface"] as? String
            let sig = (r["signal"] ?? r["signal-strength"]) as? String
            cl.signal = sig.flatMap { Int($0.split(separator: "@").first ?? "") }
            // "bytes" = "tx,rx" from the router's perspective
            if let b = (r["bytes"] as? String)?.split(separator: ","), b.count == 2 {
                cl.txTotal = UInt64(b[0]); cl.rxTotal = UInt64(b[1])
            }
            cl.connectedSeconds = (r["uptime"] as? String).map(parseROSDuration)
            clients[mac] = cl
        }
        s.clients = Array(clients.values)
        return .success(s)
    }

    /// "1w2d03:04:05" or "2d3h4m5s" → seconds
    private func parseROSDuration(_ s: String) -> Double {
        var total = 0.0, num = ""
        let units: [Character: Double] = ["w": 604800, "d": 86400, "h": 3600, "m": 60, "s": 1]
        for ch in s {
            if ch.isNumber { num.append(ch) }
            else if let u = units[ch] { total += (Double(num) ?? 0) * u; num = "" }
            else if ch == ":" { num.append(ch) }
        }
        if num.contains(":") {
            let parts = num.split(separator: ":").compactMap { Double($0) }
            total += parts.reduce(0) { $0 * 60 + $1 }
        } else if let n = Double(num) { total += n }
        return total
    }
}

// MARK: - More router drivers

extension RouterClientService {
    private func base(_ c: Config, defaultHTTPS: Bool = false, port: Int? = nil) -> String {
        let scheme = (c.https || defaultHTTPS) ? "https" : "http"
        return "\(scheme)://\(c.host)" + (port.map { ":\($0)" } ?? "")
    }

    private func json(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }

    // MARK: ASUS (AsusWRT / Merlin)

    func pollASUS(_ c: Config) -> Result<RouterSnapshot, RouterError> {
        let ua = "asusrouter-Android-DUTUtil-1.0.0.245"
        let b = base(c)
        if asusToken == nil {
            let auth = Data("\(c.username):\(c.password)".utf8).base64EncodedString()
            guard let url = URL(string: "\(b)/login.cgi"),
                  let r = HTTP.shared.request(url, method: "POST", headers: ["User-Agent": ua, "Content-Type": "application/x-www-form-urlencoded"],
                                              body: Data("login_authorization=\(auth)".utf8)),
                  let obj = json(r.data) as? [String: Any], let token = obj["asus_token"] as? String else {
                return .failure(RouterError("ASUS login failed — check address, username and password"))
            }
            asusToken = token
        }
        func hook(_ h: String) -> [String: Any]? {
            guard let url = URL(string: "\(b)/appGet.cgi"),
                  let r = HTTP.shared.request(url, method: "POST",
                                              headers: ["User-Agent": ua, "Cookie": "asus_token=\(asusToken ?? "")",
                                                        "Content-Type": "application/x-www-form-urlencoded"],
                                              body: Data("hook=\(h)".utf8)),
                  r.status == 200 else { return nil }
            if let o = json(r.data) as? [String: Any] { return o }
            // Some hooks return near-JSON; fall back to a regex for "key":"value" pairs.
            let text = String(decoding: r.data, as: UTF8.self)
            var out: [String: Any] = ["_raw": text]
            let re = try! NSRegularExpression(pattern: "\"([A-Za-z0-9_]+)\"\\s*:\\s*\"([^\"]*)\"")
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let k = Range(m.range(at: 1), in: text), let v = Range(m.range(at: 2), in: text) { out[String(text[k])] = String(text[v]) }
            }
            return out
        }
        guard let net = hook("netdev(appobj)") else {
            asusToken = nil
            return .failure(RouterError("ASUS session expired — will log in again"))
        }
        var s = RouterSnapshot()
        let nd = (net["netdev"] as? [String: Any]) ?? net
        func hex(_ k: String) -> UInt64? { (nd[k] as? String).flatMap { UInt64($0.replacingOccurrences(of: "0x", with: ""), radix: 16) } }
        s.wanRx = hex("INTERNET_rx") ?? hex("WIRED_rx"); s.wanTx = hex("INTERNET_tx") ?? hex("WIRED_tx")
        s.interfaces = ["INTERNET", "WIRED", "WIRELESS0", "WIRELESS1", "WIRELESS2", "BRIDGE"].compactMap { n in
            guard let rx = hex("\(n)_rx"), let tx = hex("\(n)_tx") else { return nil }
            return RouterInterface(name: n.capitalized, rx: rx, tx: tx, up: nil)
        }
        if let m = hook("memory_usage(appobj)") {
            let mu = (m["memory_usage"] as? [String: Any]) ?? m
            if let t = (mu["mem_total"] as? String).flatMap(Double.init), let u = (mu["mem_used"] as? String).flatMap(Double.init), t > 0 { s.memUsed = u / t }
        }
        if let cpu = hook("cpu_usage(appobj)") {
            let cu = (cpu["cpu_usage"] as? [String: Any]) ?? cpu
            var total = 0.0, used = 0.0
            for (k, v) in cu {
                guard let d = (v as? String).flatMap(Double.init) else { continue }
                if k.hasSuffix("_total") { total += d } else if k.hasSuffix("_usage") { used += d }
            }
            if let p = asusPrevCPU, total > p.total { s.cpuLoad = (used - p.used) / (total - p.total) }
            asusPrevCPU = (total, used)
        }
        if let up = hook("uptime()"), let raw = up["_raw"] as? String ?? (up["uptime"] as? String),
           let r = raw.range(of: "\\((\\d+) secs", options: .regularExpression) {
            s.uptime = Double(raw[r].filter(\.isNumber))
        }
        if let cl = hook("get_clientlist(appobj)"), let list = (cl["get_clientlist"] as? [String: Any]) {
            s.clients = list.compactMap { mac, v in
                guard mac.contains(":"), let d = v as? [String: Any] else { return nil }
                if (d["isOnline"] as? String) == "0" { return nil }
                let name = [(d["nickName"] as? String), (d["name"] as? String)].compactMap { $0 }.first { !$0.isEmpty }
                return RouterClient(mac: mac.lowercased(), ip: d["ip"] as? String, name: name,
                                    signal: (d["rssi"] as? String).flatMap(Int.init).flatMap { $0 == 0 ? nil : $0 },
                                    iface: (d["isWL"] as? String).map { $0 == "0" ? "wired" : ($0 == "1" ? "2.4 GHz" : "5 GHz") },
                                    connectedSeconds: nil,
                                    ap: (d["amesh_papMac"] as? String).flatMap { $0.isEmpty ? nil : "AiMesh node \($0.lowercased())" } ?? "Main router")
            }
        }
        s.model = "ASUS router"
        return .success(s)
    }

    // MARK: FRITZ!Box (TR-064)

    func pollFritz(_ c: Config) -> Result<RouterSnapshot, RouterError> {
        HTTP.shared.credential = c.password.isEmpty ? nil : URLCredential(user: c.username, password: c.password, persistence: .forSession)
        let b = "http://\(c.host):49000"
        func svc(_ path: String, _ type: String) -> (url: URL, type: String) { (URL(string: b + path)!, type) }
        let common = svc("/igdupnp/control/WANCommonIFC1", "urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1")
        var s = RouterSnapshot()
        if let a = soapCall(common, "GetAddonInfos") {
            s.wanRx = a["NewX_AVM_DE_TotalBytesReceived64"].flatMap(UInt64.init)
            s.wanTx = a["NewX_AVM_DE_TotalBytesSent64"].flatMap(UInt64.init)
        }
        guard s.wanRx != nil else {
            return .failure(RouterError("FRITZ!Box did not answer on port 49000 — enable “Allow access for applications” (Home Network → Network → Network Settings)"))
        }
        if let l = soapCall(common, "GetCommonLinkProperties") {
            s.linkDown = l["NewLayer1DownstreamMaxBitRate"].flatMap(Double.init)
            s.linkUp = l["NewLayer1UpstreamMaxBitRate"].flatMap(Double.init)
            s.linkStatus = l["NewPhysicalLinkStatus"]
        }
        if let ip = soapCall(svc("/igdupnp/control/WANIPConn1", "urn:schemas-upnp-org:service:WANIPConnection:1"), "GetExternalIPAddress") {
            s.externalIP = ip["NewExternalIPAddress"]
        }
        // Authenticated TR-064 services (need a FRITZ!Box user)
        if let info = soapCall(svc("/upnp/control/deviceinfo", "urn:dslforum-org:service:DeviceInfo:1"), "GetInfo") {
            s.model = info["NewModelName"]; s.firmware = info["NewSoftwareVersion"]
            s.uptime = info["NewUpTime"].flatMap(Double.init)
        }
        if let hl = soapCall(svc("/upnp/control/hosts", "urn:dslforum-org:service:Hosts:1"), "X_AVM-DE_GetHostListPath"),
           let path = hl["NewX_AVM-DE_HostListPath"], let url = URL(string: b + path),
           let r = HTTP.shared.request(url), let xml = String(data: r.data, encoding: .utf8) {
            func tag(_ t: String, _ chunk: String) -> String? {
                guard let a = chunk.range(of: "<\(t)>"), let e = chunk.range(of: "</\(t)>", range: a.upperBound..<chunk.endIndex) else { return nil }
                let v = String(chunk[a.upperBound..<e.lowerBound]); return v.isEmpty ? nil : v
            }
            s.clients = xml.components(separatedBy: "<Item>").dropFirst().compactMap { item in
                guard tag("Active", item) == "1", let mac = tag("MACAddress", item)?.lowercased() else { return nil }
                return RouterClient(mac: mac, ip: tag("IPAddress", item), name: tag("HostName", item),
                                    iface: tag("InterfaceType", item))
            }
        }
        return .success(s)
    }

    private func soapCall(_ svc: (url: URL, type: String), _ action: String) -> [String: String]? {
        let body = """
        <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:\(action) xmlns:u="\(svc.type)"></u:\(action)></s:Body></s:Envelope>
        """
        guard let r = HTTP.shared.request(svc.url, method: "POST",
                                          headers: ["Content-Type": "text/xml; charset=\"utf-8\"", "SOAPAction": "\"\(svc.type)#\(action)\""],
                                          body: Data(body.utf8)),
              r.status == 200, let xml = String(data: r.data, encoding: .utf8) else { return nil }
        var out: [String: String] = [:]
        let re = try! NSRegularExpression(pattern: "<(New[A-Za-z0-9_\\-]+)>([^<]*)</")
        for m in re.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)) {
            if let k = Range(m.range(at: 1), in: xml), let v = Range(m.range(at: 2), in: xml) { out[String(xml[k])] = String(xml[v]) }
        }
        return out
    }

    // MARK: UniFi Network

    func pollUniFi(_ c: Config) -> Result<RouterSnapshot, RouterError> {
        let site = c.site.isEmpty ? "default" : c.site
        if unifiBase == nil {
            let creds = try? JSONSerialization.data(withJSONObject: ["username": c.username, "password": c.password])
            // UniFi OS consoles (UDM, UCG, Cloud Key Gen2+)
            if let u = URL(string: "https://\(c.host)/api/auth/login"),
               let r = HTTP.shared.request(u, method: "POST", headers: ["Content-Type": "application/json"], body: creds), r.status == 200 {
                unifiBase = "https://\(c.host)/proxy/network"
            } else if let u = URL(string: "https://\(c.host):8443/api/login"),
                      let r = HTTP.shared.request(u, method: "POST", headers: ["Content-Type": "application/json"], body: creds), r.status == 200 {
                unifiBase = "https://\(c.host):8443"
            } else {
                return .failure(RouterError("UniFi login failed — use a local (non-SSO) admin account"))
            }
        }
        func get(_ path: String) -> [[String: Any]]? {
            guard let u = URL(string: "\(unifiBase!)/api/s/\(site)/\(path)"), let r = HTTP.shared.request(u), r.status == 200,
                  let o = json(r.data) as? [String: Any] else { return nil }
            return o["data"] as? [[String: Any]]
        }
        guard let devices = get("stat/device") else {
            unifiBase = nil
            return .failure(RouterError("UniFi session expired — will log in again"))
        }
        var s = RouterSnapshot()
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap(Double.init) }
        if let gw = devices.first(where: { ["ugw", "udm", "uxg"].contains(($0["type"] as? String) ?? "") }) {
            s.model = (gw["model"] as? String).map { "UniFi \($0)" }
            s.firmware = gw["version"] as? String
            s.uptime = num(gw["uptime"])
            if let st = gw["system-stats"] as? [String: Any] {
                s.cpuLoad = num(st["cpu"]).map { $0 / 100 }; s.memUsed = num(st["mem"]).map { $0 / 100 }
            }
            if let up = gw["uplink"] as? [String: Any] {
                s.wanRx = num(up["rx_bytes"]).map { UInt64($0) }; s.wanTx = num(up["tx_bytes"]).map { UInt64($0) }
                s.externalIP = up["ip"] as? String
                s.linkStatus = (up["up"] as? Bool) == true ? "Up" : "Down"
            }
        }
        if let health = get("stat/health"), let www = health.first(where: { ($0["subsystem"] as? String) == "www" }) {
            s.linkDown = num(www["xput_down"]).map { $0 * 1e6 }; s.linkUp = num(www["xput_up"]).map { $0 * 1e6 }
        }
        var apNames: [String: String] = [:]
        for d in devices { if let mac = (d["mac"] as? String)?.lowercased() { apNames[mac] = (d["name"] as? String) ?? (d["model"] as? String) ?? mac } }
        s.clients = (get("stat/sta") ?? []).compactMap { d in
            guard let mac = (d["mac"] as? String)?.lowercased() else { return nil }
            let apMac = ((d["ap_mac"] ?? d["sw_mac"]) as? String)?.lowercased()
            let name = [(d["name"] as? String), (d["hostname"] as? String)].compactMap { $0 }.first { !$0.isEmpty }
            return RouterClient(mac: mac, ip: d["ip"] as? String, name: name,
                                signal: num(d["signal"] ?? d["rssi"]).map { Int($0) },
                                iface: (d["is_wired"] as? Bool) == true ? "wired" : (d["essid"] as? String),
                                rxTotal: num(d["rx_bytes"] ?? d["wired-rx_bytes"]).map { UInt64($0) },
                                txTotal: num(d["tx_bytes"] ?? d["wired-tx_bytes"]).map { UInt64($0) },
                                connectedSeconds: num(d["uptime"]), ap: apMac.map { apNames[$0] ?? $0 })
        }
        return .success(s)
    }

    // MARK: OPNsense

    func pollOPNsense(_ c: Config) -> Result<RouterSnapshot, RouterError> {
        let b = base(c, defaultHTTPS: true)
        let auth = "Basic " + Data("\(c.username):\(c.password)".utf8).base64EncodedString()
        func get(_ path: String) -> Any? {
            guard let u = URL(string: "\(b)/api/\(path)"), let r = HTTP.shared.request(u, headers: ["Authorization": auth]), r.status == 200 else { return nil }
            return json(r.data)
        }
        guard let stats = get("diagnostics/interface/getInterfaceStatistics") as? [String: Any] else {
            return .failure(RouterError("OPNsense API login failed — create an API key under System → Access → Users"))
        }
        var s = RouterSnapshot()
        let table = (stats["statistics"] as? [String: Any]) ?? stats
        func num(_ v: Any?) -> UInt64? { (v as? NSNumber)?.uint64Value ?? (v as? String).flatMap(UInt64.init) }
        s.interfaces = table.compactMap { key, v in
            guard let d = v as? [String: Any], let rx = num(d["received-bytes"] ?? d["bytes received"]),
                  let tx = num(d["sent-bytes"] ?? d["bytes transmitted"]) else { return nil }
            return RouterInterface(name: key, rx: rx, tx: tx, up: nil)
        }.sorted { $0.rx + $0.tx > $1.rx + $1.tx }
        let wan = s.interfaces.first { !c.wanInterface.isEmpty && $0.name.contains(c.wanInterface) }
            ?? s.interfaces.first { $0.name.lowercased().contains("[wan]") || $0.name.lowercased().contains("wan") }
        s.wanRx = wan?.rx; s.wanTx = wan?.tx
        if let res = get("diagnostics/system/systemResources") as? [String: Any], let mem = res["memory"] as? [String: Any],
           let total = (mem["total"] as? NSNumber)?.doubleValue ?? (mem["total"] as? String).flatMap(Double.init),
           let used = (mem["used"] as? NSNumber)?.doubleValue ?? (mem["used"] as? String).flatMap(Double.init), total > 0 {
            s.memUsed = used / total
        }
        if let arp = get("diagnostics/interface/getArp") as? [[String: Any]] {
            s.clients = arp.compactMap { a in
                guard let mac = (a["mac"] as? String)?.lowercased() else { return nil }
                let host = (a["hostname"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                return RouterClient(mac: mac, ip: a["ip"] as? String, name: host, iface: a["intf_description"] as? String ?? a["intf"] as? String)
            }
        }
        s.model = "OPNsense"
        return .success(s)
    }
}
