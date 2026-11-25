import Foundation

// MARK: - TP-Link Omada, Netgear / Orbi, pfSense

extension RouterClientService {
    private func jsonObj(_ data: Data) -> [String: Any]? { (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] }
    private func anyNum(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue ?? (v as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) } }
    private func mac(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return NetUtil.normalizeMAC(s.replacingOccurrences(of: "-", with: ":"))
    }

    // MARK: TP-Link Omada (Software Controller / OC200 / OC300) — OpenAPI with client credentials

    func pollOmada(_ c: Config) -> Result<RouterSnapshot, RouterError> {
        let base = "https://\(c.host)"
        if omadaToken == nil || omadaToken!.expires < Date() {
            guard let iu = URL(string: "\(base)/api/info"), let ir = HTTP.shared.request(iu),
                  let id = (jsonObj(ir.data)?["result"] as? [String: Any])?["omadacId"] as? String else {
                return .failure(RouterError("Omada controller not found at \(c.host) — include the port, e.g. 192.168.0.2:8043"))
            }
            let body = try? JSONSerialization.data(withJSONObject: ["omadacId": id, "client_id": c.username, "client_secret": c.password])
            guard let tu = URL(string: "\(base)/openapi/authorize/token?grant_type=client_credentials"),
                  let tr = HTTP.shared.request(tu, method: "POST", headers: ["Content-Type": "application/json"], body: body),
                  let res = jsonObj(tr.data)?["result"] as? [String: Any], let token = res["accessToken"] as? String else {
                return .failure(RouterError("Omada login failed — create an OpenAPI app (Settings → Platform Integration → Open API, “Client” mode) and use its Client ID / Secret"))
            }
            let ttl = anyNum(res["expiresIn"]) ?? 7200
            omadaToken = (id, token, "", Date().addingTimeInterval(ttl - 120))
        }
        let auth = ["Authorization": "AccessToken=\(omadaToken!.token)"]
        func get(_ path: String) -> Any? {
            guard let u = URL(string: "\(base)/openapi/v1/\(omadaToken!.id)/\(path)"), let r = HTTP.shared.request(u, headers: auth),
                  let o = jsonObj(r.data), (o["errorCode"] as? NSNumber)?.intValue ?? 0 == 0 else { return nil }
            return o["result"]
        }
        if omadaToken!.site.isEmpty {
            guard let sites = (get("sites?page=1&pageSize=100") as? [String: Any])?["data"] as? [[String: Any]], !sites.isEmpty else {
                omadaToken = nil
                return .failure(RouterError("Omada: no sites visible to this API client (give it access to the site)"))
            }
            let wanted = c.site.isEmpty || c.site == "default" ? nil : c.site
            let site = sites.first { ($0["name"] as? String) == wanted } ?? sites[0]
            omadaToken!.site = site["siteId"] as? String ?? ""
        }
        let site = omadaToken!.site
        var s = RouterSnapshot()
        var deviceNames: [String: String] = [:]
        if let devs = (get("sites/\(site)/devices?page=1&pageSize=200") as? [String: Any])?["data"] as? [[String: Any]] {
            for d in devs {
                if let m = mac(d["mac"] as? String) { deviceNames[m] = (d["name"] as? String) ?? (d["model"] as? String) }
                if (d["type"] as? String) == "gateway" {
                    s.model = (d["model"] as? String).map { "Omada \($0)" }
                    s.firmware = d["firmwareVersion"] as? String
                    s.cpuLoad = anyNum(d["cpuUtil"]).map { $0 / 100 }
                    s.memUsed = anyNum(d["memUtil"]).map { $0 / 100 }
                    s.uptime = anyNum(d["uptimeLong"]) ?? anyNum(d["uptime"])
                    s.externalIP = d["publicIp"] as? String
                }
            }
            if s.model == nil { s.model = "Omada (\(devs.count) devices)" }
        }
        guard let list = (get("sites/\(site)/clients?page=1&pageSize=1000") as? [String: Any])?["data"] as? [[String: Any]] else {
            omadaToken = nil
            return .failure(RouterError("Omada: could not read clients (token expired?) — will retry"))
        }
        s.clients = list.compactMap { d in
            guard let m = mac(d["mac"] as? String) else { return nil }
            let wireless = (d["wireless"] as? Bool) ?? false
            let apMac = mac(d["apMac"] as? String)
            let ap = (d["apName"] as? String) ?? apMac.map { deviceNames[$0] ?? $0 } ?? (d["switchName"] as? String) ?? (d["gatewayName"] as? String)
            return RouterClient(mac: m, ip: d["ip"] as? String,
                                name: [(d["name"] as? String), (d["hostName"] as? String)].compactMap { $0 }.first { !$0.isEmpty && $0 != m },
                                signal: anyNum(d["rssi"]).map { Int($0) },
                                iface: wireless ? (d["ssid"] as? String) : "wired",
                                rxTotal: anyNum(d["trafficUp"]).map { UInt64(max(0, $0)) },
                                txTotal: anyNum(d["trafficDown"]).map { UInt64(max(0, $0)) },
                                connectedSeconds: anyNum(d["uptime"]), ap: ap)
        }
        return .success(s)
    }

    // MARK: Netgear / Orbi (Genie SOAP API on port 5000 or 80)

    private func netgearSOAP(_ c: Config, service: String, action: String, inner: String = "") -> String? {
        let body = """
        <?xml version="1.0" encoding="utf-8" ?><SOAP-ENV:Envelope xmlns:SOAP-ENV="http://schemas.xmlsoap.org/soap/envelope/" SOAP-ENV:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><SOAP-ENV:Header><SessionID>A7D88AE69687E58D9A00</SessionID></SOAP-ENV:Header><SOAP-ENV:Body><M1:\(action) xmlns:M1="urn:NETGEAR-ROUTER:service:\(service):1">\(inner)</M1:\(action)></SOAP-ENV:Body></SOAP-ENV:Envelope>
        """
        let hostOnly = c.host.split(separator: ":").first.map(String.init) ?? c.host
        let hosts = c.host.contains(":") ? [c.host] : ["\(hostOnly):5000", hostOnly]
        for h in hosts {
            guard let u = URL(string: "http://\(h)/soap/server_sa/"),
                  let r = HTTP.shared.request(u, method: "POST",
                                              headers: ["SOAPAction": "urn:NETGEAR-ROUTER:service:\(service):1#\(action)",
                                                        "Content-Type": "text/xml; charset=\"utf-8\""],
                                              body: Data(body.utf8)), r.status == 200 else { continue }
            let xml = String(decoding: r.data, as: UTF8.self)
            if let code = tag("ResponseCode", xml), code != "000", code != "0" { return nil }
            return xml
        }
        return nil
    }

    private func tag(_ t: String, _ s: String) -> String? {
        guard let a = s.range(of: "<\(t)>"), let e = s.range(of: "</\(t)>", range: a.upperBound..<s.endIndex) else { return nil }
        let v = String(s[a.upperBound..<e.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    func pollNetgear(_ c: Config) -> Result<RouterSnapshot, RouterError> {
        let user = c.username.isEmpty ? "admin" : c.username
        let esc = { (v: String) in v.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;") }
        if !netgearLoggedIn {
            let ok = netgearSOAP(c, service: "DeviceConfig", action: "SOAPLogin",
                                 inner: "<Username>\(esc(user))</Username><Password>\(esc(c.password))</Password>") != nil
                || netgearSOAP(c, service: "ParentalControl", action: "Authenticate",
                               inner: "<NewUsername>\(esc(user))</NewUsername><NewPassword>\(esc(c.password))</NewPassword>") != nil
            guard ok else { return .failure(RouterError("Netgear login failed — check the admin password (the router's SOAP API runs on port 5000 or 80)")) }
            netgearLoggedIn = true
        }
        var s = RouterSnapshot()
        if let info = netgearSOAP(c, service: "DeviceInfo", action: "GetInfo") {
            s.model = tag("ModelName", info).map { "Netgear \($0)" }
            s.firmware = tag("Firmwareversion", info)
        } else {
            netgearLoggedIn = false
            return .failure(RouterError("Netgear session expired — will log in again"))
        }
        if let sys = netgearSOAP(c, service: "DeviceInfo", action: "GetSystemInfo") {
            s.cpuLoad = tag("NewCPUUtilization", sys).flatMap(Double.init).map { $0 / 100 }
            s.memUsed = tag("NewMemoryUtilization", sys).flatMap(Double.init).map { $0 / 100 }
        }
        if let wan = netgearSOAP(c, service: "WANIPConnection", action: "GetInfo") {
            s.externalIP = tag("NewExternalIPAddress", wan)
        }
        var clients: [RouterClient] = []
        if let xml = netgearSOAP(c, service: "DeviceInfo", action: "GetAttachDevice2"), xml.contains("<Device>") {
            let items = xml.components(separatedBy: "<Device>").dropFirst()
            let names = Dictionary(items.compactMap { i in mac(tag("MAC", i)).map { ($0, tag("Name", i) ?? $0) } }, uniquingKeysWith: { a, _ in a })
            clients = items.compactMap { i in
                guard let m = mac(tag("MAC", i)) else { return nil }
                let pct = tag("SignalStrength", i).flatMap(Int.init)
                let wired = (tag("ConnectionType", i) ?? "").lowercased().contains("wired")
                let apMac = mac(tag("ConnAPMAC", i))
                return RouterClient(mac: m, ip: tag("IP", i), name: tag("Name", i).flatMap { $0 == "--" ? nil : $0 },
                                    signal: wired ? nil : pct.map { $0 / 2 - 100 },
                                    iface: wired ? "wired" : (tag("SSID", i) ?? tag("ConnectionType", i)),
                                    ap: apMac.map { names[$0] ?? "Satellite \($0)" } ?? "Main router")
            }
        } else if let xml = netgearSOAP(c, service: "DeviceInfo", action: "GetAttachDevice"),
                  let raw = tag("NewAttachDevice", xml) {
            // "count@1;IP;Name;MAC;type;linkspeed;signal;allow@2;…"
            clients = raw.split(separator: "@").dropFirst().compactMap { rec in
                let f = rec.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 4, let m = mac(f[3]) else { return nil }
                let wired = f.count > 4 && f[4].lowercased().contains("wired")
                return RouterClient(mac: m, ip: f[1], name: f[2] == "<unknown>" ? nil : f[2],
                                    signal: (!wired && f.count > 6) ? Int(f[6]).map { $0 / 2 - 100 } : nil,
                                    iface: wired ? "wired" : "Wi-Fi", ap: "Main router")
            }
        }
        s.clients = clients
        return .success(s)
    }

    // MARK: pfSense (pfrest / "RESTAPI" package v2, with v1 fallback)

    func pollPfSense(_ c: Config) -> Result<RouterSnapshot, RouterError> {
        let base = "https://\(c.host)"
        var headers = ["Accept": "application/json"]
        if c.username.isEmpty { headers["X-API-Key"] = c.password }
        else { headers["Authorization"] = "Basic " + Data("\(c.username):\(c.password)".utf8).base64EncodedString() }
        func get(_ path: String) -> Any? {
            for v in ["v2", "v1"] {
                guard let u = URL(string: "\(base)/api/\(v)/\(path)"), let r = HTTP.shared.request(u, headers: headers),
                      r.status == 200, let o = jsonObj(r.data) else { continue }
                return o["data"]
            }
            return nil
        }
        guard let sys = get("status/system") as? [String: Any] else {
            return .failure(RouterError("pfSense API not reachable — install the REST API package (github.com/pfrest/pfSense-pkg-RESTAPI) and enable it, or use SNMP (Services → SNMP)"))
        }
        var s = RouterSnapshot()
        s.model = (sys["platform"] as? String).map { "pfSense \($0)" } ?? "pfSense"
        s.firmware = (sys["system_version"] as? String) ?? (sys["version"] as? String)
        s.cpuLoad = anyNum(sys["cpu_usage"]).map { $0 / 100 }
        s.memUsed = anyNum(sys["mem_usage"]).map { $0 / 100 }
        if let up = sys["uptime"] as? String { s.uptime = parseUptimeText(up) } else { s.uptime = anyNum(sys["uptime"]) }
        if let ifs = get("status/interfaces") as? [[String: Any]] {
            s.interfaces = ifs.compactMap { i in
                guard let rx = anyNum(i["inbytes"]), let tx = anyNum(i["outbytes"]) else { return nil }
                let name = [(i["descr"] as? String), (i["name"] as? String)].compactMap { $0 }.first ?? "?"
                return RouterInterface(name: name, rx: UInt64(rx), tx: UInt64(tx), up: (i["status"] as? String).map { $0 == "up" })
            }.sorted { $0.rx + $0.tx > $1.rx + $1.tx }
            let wan = s.interfaces.first { !c.wanInterface.isEmpty && $0.name.lowercased() == c.wanInterface.lowercased() }
                ?? s.interfaces.first { $0.name.lowercased().contains("wan") }
            s.wanRx = wan?.rx; s.wanTx = wan?.tx
            s.externalIP = ifs.first { (($0["descr"] as? String) ?? "").lowercased().contains("wan") }?["ipaddr"] as? String
        }
        if let arp = get("diagnostics/arp_table") as? [[String: Any]] {
            s.clients = arp.compactMap { a in
                guard let m = mac(a["mac_address"] as? String) else { return nil }
                let host = (a["hostname"] as? String).flatMap { $0.isEmpty || $0 == "?" ? nil : $0 }
                return RouterClient(mac: m, ip: a["ip_address"] as? String, name: host, iface: a["interface"] as? String)
            }
        }
        return .success(s)
    }

    /// "3 Days 04 Hours 12 Minutes 09 Seconds" → seconds
    private func parseUptimeText(_ t: String) -> Double? {
        let units: [String: Double] = ["day": 86400, "hour": 3600, "min": 60, "sec": 1]
        var total = 0.0, last: Double?
        for w in t.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if let n = Double(w) { last = n; continue }
            if let l = last, let u = units.first(where: { w.hasPrefix($0.key) })?.value { total += l * u; last = nil }
        }
        return total > 0 ? total : nil
    }
}
