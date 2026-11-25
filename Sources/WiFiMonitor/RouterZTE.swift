import Foundation
import CryptoKit

// MARK: - ZTE fibre ONTs (Airtel / Jio / BSNL: F670L, F680, F6600P…) — newer "_type=menuData" web UI

extension RouterClientService {
    /// Where raw router replies are saved for troubleshooting (local only, overwritten each poll).
    static var zteDebugDir: URL {
        Database.shared.url.deletingLastPathComponent().appendingPathComponent("router-debug", isDirectory: true)
    }

    private func zteGet(_ base: String, _ query: String) -> String? {
        guard let u = URL(string: "\(base)/?\(query)"), let r = HTTP.shared.request(u, headers: ["X-Requested-With": "XMLHttpRequest"]),
              r.status == 200 else { return nil }
        return String(decoding: r.data, as: UTF8.self)
    }

    private func zteLogin(_ c: Config, base: String) -> RouterError? {
        // Back off after a failed login: these ONTs lock the account after a few bad attempts.
        if let until = zteLoginBlockedUntil, until > Date() {
            return RouterError("ZTE login paused after a failed attempt (avoids locking the router) — retrying at \(Fmt.time.string(from: until))")
        }
        guard let entry = zteGet(base, "_type=loginData&_tag=login_entry"),
              let ej = try? JSONSerialization.jsonObject(with: Data(entry.utf8)) as? [String: Any],
              let sess = ej["sess_token"] as? String else {
            return RouterError("No ZTE login page at \(c.host) — is this a ZTE ONT (F670L/F680…)?")
        }
        if let lock = (ej["lockingTime"] as? NSNumber)?.intValue, lock > 0 {
            zteLoginBlockedUntil = Date().addingTimeInterval(Double(lock) + 5)
            return RouterError("The router has locked logins for \(lock) s after failed attempts — wait and try again")
        }
        guard let tokXML = zteGet(base, "_type=loginData&_tag=login_token"),
              let a = tokXML.range(of: ">"), let b = tokXML.range(of: "</", range: a.upperBound..<tokXML.endIndex) else {
            return RouterError("ZTE: could not get a login token")
        }
        let token = String(tokXML[a.upperBound..<b.lowerBound])
        let hash = SHA256.hash(data: Data((c.password + token).utf8)).map { String(format: "%02x", $0) }.joined()
        let user = c.username.isEmpty ? "admin" : c.username
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }
        let body = "action=login&Password=\(hash)&Username=\(enc(user))&_sessionTOKEN=\(sess)"
        guard let u = URL(string: "\(base)/?_type=loginData&_tag=login_entry"),
              let r = HTTP.shared.request(u, method: "POST", headers: ["Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
                                                                      "X-Requested-With": "XMLHttpRequest"], body: Data(body.utf8)),
              let j = try? JSONSerialization.jsonObject(with: r.data) as? [String: Any] else {
            return RouterError("ZTE: no answer to the login request")
        }
        // Same rule as the router's own page: success = "login_need_refresh" (reload into the dashboard).
        if (j["login_need_refresh"] as? NSNumber)?.boolValue == true {
            zteLoggedIn = true
            return nil
        }
        let msg = (j["loginErrMsg"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (j["promptMsg"] as? String) ?? "wrong username or password"
        zteLoginBlockedUntil = Date().addingTimeInterval(600)
        return RouterError("ZTE login failed: \(msg). Check the username/password from the sticker (Airtel often uses “admin”). Will not retry for 10 minutes to avoid a lockout.")
    }

    /// Parses ZTE's `<OBJ_…><Instance><ParaName>k</ParaName><ParaValue>v</ParaValue>…` replies.
    private func zteParse(_ xml: String) -> [String: [[String: String]]] {
        var out: [String: [[String: String]]] = [:]
        let objRe = try! NSRegularExpression(pattern: "<((?:OBJ|ID)_[A-Za-z0-9_]+)>(.*?)</\\1>", options: [.dotMatchesLineSeparators])
        let instRe = try! NSRegularExpression(pattern: "<Instance>(.*?)</Instance>", options: [.dotMatchesLineSeparators])
        let kvRe = try! NSRegularExpression(pattern: "<ParaName>(.*?)</ParaName>\\s*<ParaValue>(.*?)</ParaValue>", options: [.dotMatchesLineSeparators])
        let ns = xml as NSString
        for om in objRe.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: om.range(at: 1)), body = ns.substring(with: om.range(at: 2)) as NSString
            for im in instRe.matches(in: body as String, range: NSRange(location: 0, length: body.length)) {
                let inst = body.substring(with: im.range(at: 1)) as NSString
                var d: [String: String] = [:]
                for kv in kvRe.matches(in: inst as String, range: NSRange(location: 0, length: inst.length)) {
                    d[inst.substring(with: kv.range(at: 1))] = inst.substring(with: kv.range(at: 2))
                        .replacingOccurrences(of: "&#32;", with: " ").replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespaces)
                }
                if !d.isEmpty { out[name, default: []].append(d) }
            }
        }
        return out
    }

    private func pick(_ d: [String: String], _ keys: [String]) -> String? {
        for k in keys { if let v = d.first(where: { $0.key.lowercased() == k.lowercased() })?.value, !v.isEmpty, v != "0.0.0.0" { return v } }
        return nil
    }

    func pollZTE(_ c: Config) -> Result<RouterSnapshot, RouterError> {
        let base = "\(c.https ? "https" : "http")://\(c.host)"
        if !zteLoggedIn, let e = zteLogin(c, base: base) { return .failure(e) }

        // (menu page to open first, data endpoint) — the ONT only serves data for the page you're "on".
        let pages: [(String, String, String)] = [
            ("devinfo", "statusMgr", "devmgr_statusmgr_lua.lua"),
            ("landevs", "localNetStatus", "accessdev_landevs_lua.lua"),
            ("wlanclients", "localNetStatus", "wlan_client_stat_lua.lua"),   // Wi-Fi clients (OBJ_WLAN_AD_ID)
            ("wlanstatus", "wlanStatus", "wlan_wlanstatus_lua.lua"),
            ("wan", "ethWanStatus", "wan_internetstatus_lua.lua&TypeUplink=2&pageType=1"),
            ("wanpon", "ponWanStatus", "wan_internetstatus_lua.lua&TypeUplink=1&pageType=1"),
            ("optical", "ponopticalinfo", "optical_info_lua.lua"),
        ]
        try? FileManager.default.createDirectory(at: Self.zteDebugDir, withIntermediateDirectories: true)
        var objs: [String: [[String: String]]] = [:]
        var sawData = false
        for (name, view, data) in pages {
            if let html = zteGet(base, "_type=menuView&_tag=\(view)&Menu3Location=0") {
                try? html.write(to: Self.zteDebugDir.appendingPathComponent("zte-view-\(name).html"), atomically: true, encoding: .utf8)
            }
            guard let xml = zteGet(base, "_type=menuData&_tag=\(data)") else { continue }
            try? xml.write(to: Self.zteDebugDir.appendingPathComponent("zte-\(name).xml"), atomically: true, encoding: .utf8)
            // An unknown page also answers "SessionTimeout", so only a fully empty poll means we were logged out.
            if xml.contains("SessionTimeout") || xml.contains("loginForm") || xml.contains("login_entry") { continue }
            let parsed = zteParse(xml)
            if !parsed.isEmpty { sawData = true }
            for (k, v) in parsed { objs[k, default: []] += v }
        }
        guard sawData else {
            zteLoggedIn = false
            return .failure(RouterError("Logged in to the ZTE router but it returned no data (session taken over by a browser login?). Raw replies saved in \(Self.zteDebugDir.path)"))
        }

        var s = RouterSnapshot()
        let all = objs.values.flatMap { $0 }
        // Each value lives in its own object (DEVINFO, CPUMEMUSAGE, POWERONTIME…), so search every instance.
        func any(_ keys: [String]) -> String? { for d in all { if let v = pick(d, keys) { return v } }; return nil }
        func pct(_ v: String) -> Double? { Double(v.replacingOccurrences(of: "%", with: "")).map { $0 / 100 } }
        s.model = any(["ModelName", "DevModel", "ProductClass"]).map { "ZTE \($0)" }
        s.firmware = any(["SoftwareVer", "SoftwareVersion", "SwVersion"])
        s.uptime = any(["PowerOnTime", "SysUpTime"]).flatMap(Double.init)
        let cores = all.flatMap { d in d.filter { $0.key.range(of: "^CpuUsage\\d*$", options: [.regularExpression, .caseInsensitive]) != nil }.compactMap { Double($0.value) } }
        if !cores.isEmpty { s.cpuLoad = cores.reduce(0, +) / Double(cores.count) / 100 }
        s.memUsed = any(["MemUsage", "MemoryUsage", "MemUsed"]).flatMap(pct)
        if s.model == nil { s.model = "ZTE ONT" }
        // WAN: prefer the internet connection (name contains INTERNET / default gateway) that has byte counters.
        let wans = objs.filter { $0.key.localizedCaseInsensitiveContains("WAN") }.flatMap { $0.value }
        func score(_ w: [String: String]) -> Int {
            var n = 0
            if (w["WANCName"] ?? "").localizedCaseInsensitiveContains("INTERNET") { n += 4 }
            if w["IsDefGW"] == "1" { n += 2 }
            if pick(w, ["RxBytes", "BytesReceived"]) != nil { n += 3 }
            if (w["ConnStatus"] ?? "") == "Connected" { n += 1 }
            return n
        }
        if let w = wans.max(by: { score($0) < score($1) }) {
            if let ip = pick(w, ["IPAddress", "ExternalIPAddress", "IpAddr"]), IPClass.v4(ip) != nil { s.externalIP = ip }
            if let rx = pick(w, ["RxBytes", "BytesReceived", "TotalBytesReceived"]).flatMap(UInt64.init),
               let tx = pick(w, ["TxBytes", "BytesSent", "TotalBytesSent"]).flatMap(UInt64.init) {
                s.wanRx = rx; s.wanTx = tx
                s.wanCounters32bit = rx < (1 << 32) && tx < (1 << 32)   // F670L counters are 32-bit and wrap at 4 GB
            }
            s.linkStatus = pick(w, ["ConnStatus", "ConnectionStatus", "Status", "LinkStatus"])
        }
        // Clients from the LAN + Wi-Fi device lists, merged by MAC.
        var clients: [String: RouterClient] = [:]
        // SSID name per AP instance (DEV.WIFI.AP1 → "Airtel_…") to label Wi-Fi clients.
        var ssidByAP: [String: String] = [:]
        for ap in objs["OBJ_WLANAP_ID"] ?? [] { if let id = ap["_InstID"], let n = ap["ESSID"] { ssidByAP[id] = n } }
        for (k, list) in objs where k.contains("ACCESSDEV") || k.contains("WLAN_AD") || k.contains("STA") || k.contains("CLIENT") {
            for d in list {
                guard let raw = pick(d, ["MACAddress", "MacAddr", "MAC", "AssociatedDeviceMACAddress"]) else { continue }
                let mac = NetUtil.normalizeMAC(raw.replacingOccurrences(of: "-", with: ":"))
                guard mac.count == 17 else { continue }
                var cl = clients[mac] ?? RouterClient(mac: mac)
                cl.ip = cl.ip ?? pick(d, ["IPAddress", "IpAddr", "IP"])
                cl.name = cl.name ?? pick(d, ["HostName", "DevName", "Name"])
                if let r = pick(d, ["RSSI", "Rssi", "SignalStrength"]).flatMap(Int.init) { cl.signal = r < 0 ? r : r / 2 - 100 }
                let apID = (d["_InstID"] ?? "").components(separatedBy: ".AD").first ?? ""
                cl.iface = cl.iface ?? ssidByAP[apID] ?? pick(d, ["SSIDName", "ESSID", "SSID", "ConnectType", "Interface", "Port"])
                if let rx = pick(d, ["RxBytes", "BytesReceived"]).flatMap(UInt64.init) { cl.rxTotal = rx }
                if let tx = pick(d, ["TxBytes", "BytesSent"]).flatMap(UInt64.init) { cl.txTotal = tx }
                cl.connectedSeconds = cl.connectedSeconds ?? pick(d, ["LinkTime", "OnlineTime", "AssociatedTime"]).flatMap(Double.init)
                cl.ap = "ZTE ONT"
                clients[mac] = cl
            }
        }
        s.clients = Array(clients.values)
        return .success(s)
    }
}
