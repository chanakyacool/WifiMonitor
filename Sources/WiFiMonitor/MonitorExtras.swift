import Foundation

/// Path tracing, IPv6, public IP / captive portal, link + VPN awareness, roaming, presence and device trust.
extension Monitor {
    func startExtras() {
        tasks.append(loop(initialDelay: 15, seconds: { Prefs.traceInterval }) { await self.runTrace() })
        tasks.append(loop(initialDelay: 10, seconds: { Prefs.ipv6Interval }) { await self.probeIPv6() })
        tasks.append(loop(initialDelay: 5, seconds: { Prefs.identityInterval }) { await self.checkIdentity() })
        tasks.append(loop(initialDelay: 40, seconds: { Prefs.connInterval }) { await self.collectConnections() })
    }

    // MARK: Link type & VPN

    func analyzeLink(_ ls: LinkInfo.State, _ s: Sample) {
        guard let prev = linkState else { return }
        if prev.link != ls.link, ls.link != "Offline", prev.link != "Offline" {
            addEvent(.linkChange, "Connection switched \(prev.link) → \(ls.link) (\(ls.primary ?? "?"))", ssid: s.ssid)
            Task { await checkIdentity() }
        }
        if prev.vpn == nil, let v = ls.vpn {
            addEvent(.vpnUp, "VPN connected: \(v)", ssid: s.ssid)
            Task { await checkIdentity() }
        } else if let v = prev.vpn, ls.vpn == nil {
            addEvent(.vpnDown, "VPN disconnected: \(v)", ssid: s.ssid)
            Task { await checkIdentity() }
        }
        if let a = prev.vpn, let b = ls.vpn, a != b { addEvent(.vpnUp, "VPN changed: \(a) → \(b)", ssid: s.ssid) }
    }

    // MARK: Traceroute

    func runTrace() async {
        guard !tracing, current?.connected == true || linkState?.link == "Ethernet" else { return }
        tracing = true
        defer { tracing = false }
        let target = Prefs.pingHost1, asn = identity?.asn, isp = identity?.isp, ssid = current?.ssid
        guard let r = await Blocking.run({ Traceroute.run(target, publicASN: asn, publicISP: isp) }) else { return }
        let id = db.run("INSERT INTO traces(ts, target, hops, reached, local_ms, isp_ms, total_ms, ssid) VALUES(?,?,?,?,?,?,?,?)",
                        [r.ts, target, r.hops.count, r.reached, r.localMs, r.ispMs, r.totalMs, ssid])
        db.runMany("INSERT INTO trace_hops(trace_id, hop, ip, rtt, asn, owner, segment) VALUES(?,?,?,?,?,?,?)",
                   r.hops.map { [id, $0.hop, $0.ip, $0.rtt, $0.asn, $0.owner, $0.segment] })
        lastTrace = r
        // Compare each segment with its own 24 h median; flag when one segment is clearly the culprit.
        let base = await Blocking.run { Queries.traceBaseline() }
        if let verdict = PathVerdict.judge(r, baseline: base), verdict.slow {
            if !pathSlowActive { pathSlowActive = true; addEvent(.pathSlow, verdict.text, ssid: ssid) }
        } else { pathSlowActive = false }
        dataVersion += 1
    }

    // MARK: IPv6

    func probeIPv6() async {
        let iface = linkState?.primary ?? current?.interface ?? "en0"
        let name = Prefs.dnsTestHost, v4 = current?.inetLatency, ssid = current?.ssid
        let r = await Blocking.run { IPv6Probe.probe(iface: iface, dnsName: name) }
        ipv6 = r
        db.run("INSERT INTO ipv6_samples(ts, has_v6, address, latency, loss, dns_latency, v4_latency, ssid) VALUES(?,?,?,?,?,?,?,?)",
               [Date(), r.hasV6, r.address, r.latency, r.loss, r.dnsLatency, v4, ssid])
        let ok = r.hasV6 && r.latency != nil
        if let was = ipv6Ok, was != ok, internetUp {
            if ok { addEvent(.ipv6Up, "IPv6 working again (\(Fmt.ms(r.latency)))", ssid: ssid) }
            else { addEvent(.ipv6Down, r.hasV6 ? "IPv6 address present but IPv6 internet unreachable" : "Lost IPv6 connectivity (no global address)", ssid: ssid) }
        }
        ipv6Ok = ok
    }

    // MARK: Public IP / ISP / captive portal

    func checkIdentity() async {
        guard current?.connected == true || linkState?.link == "Ethernet" else { return }
        let snap = await Blocking.run { NetIdentity.snapshot() }
        let prev = identity
        identity = snap
        let ls = linkState
        if snap != prev {
            db.run("INSERT INTO net_identity(ts, public_ip, asn, isp, captive, ssid, link, vpn) VALUES(?,?,?,?,?,?,?,?)",
                   [Date(), snap.publicIP, snap.asn, snap.isp, snap.captive, current?.ssid, ls?.link, ls?.vpn])
        }
        if snap.captive && prev?.captive != true {
            addEvent(.captivePortal, "Captive portal detected on \(current?.ssid ?? "this network") — sign in through the browser", ssid: current?.ssid)
        }
        if let p = prev, let a = p.publicIP, let b = snap.publicIP, a != b {
            let isp = p.asn != snap.asn ? " · ISP \(p.isp ?? "AS\(p.asn ?? 0)") → \(snap.isp ?? "AS\(snap.asn ?? 0)")" : ""
            addEvent(.publicIPChange, "Public IP \(a) → \(b)\(isp)", ssid: current?.ssid)
        }
    }

    // MARK: Sticky client (staying on a weak AP while a much better one of the same network is in range)

    func checkSticky(_ list: [ScanResult]) {
        guard let c = current, c.connected, let ssid = c.ssid, let bssid = c.bssid, let rssi = c.rssi, rssi < -68 else { return }
        guard let better = list.filter({ $0.ssid == ssid && $0.bssid != bssid }).max(by: { $0.rssi < $1.rssi }),
              better.rssi - rssi >= 8 else { return }
        guard Date().timeIntervalSince(stickyWarned) > 1800 else { return }
        stickyWarned = Date()
        addEvent(.stickyClient, "Stuck on \(bssid) at \(rssi) dBm while \(better.bssid ?? "another AP") offers \(better.rssi) dBm (ch \(better.channel ?? 0))",
                 ssid: ssid, bssid: bssid)
    }

    // MARK: Router reboot

    func checkRouterReboot(_ s: RouterSnapshot) {
        guard let up = s.uptime else { return }
        let d = UserDefaults.standard
        let prevUp = d.double(forKey: "lastRouterUptime"), prevTs = d.double(forKey: "lastRouterUptimeTs")
        d.set(up, forKey: "lastRouterUptime"); d.set(s.ts.timeIntervalSince1970, forKey: "lastRouterUptimeTs")
        guard prevTs > 0 else { return }
        let expected = prevUp + (s.ts.timeIntervalSince1970 - prevTs)
        if up + 120 < expected {
            let when = s.ts.addingTimeInterval(-up)
            addEvent(.routerReboot, "Router restarted at \(Fmt.dateTime.string(from: when)) (had been up \(Fmt.duration(prevUp)))")
        }
    }

    // MARK: Presence & trust

    /// Extends each device's current presence session, or opens a new one after a gap.
    func recordPresence(_ macs: [String], at now: Date) {
        guard !macs.isEmpty else { return }
        let gap = max(900, Prefs.sweepInterval * 1.6)
        let open = Dictionary(db.query("SELECT mac, MAX(id) id, MAX(end) end FROM device_sessions WHERE end >= ? GROUP BY mac",
                                       [now.timeIntervalSince1970 - gap]).compactMap { r in
            r.string("mac").map { ($0, Int64(r.int("id") ?? 0)) } }, uniquingKeysWith: { a, _ in a })
        var updates: [[Any?]] = [], inserts: [[Any?]] = []
        for mac in Set(macs) {
            if let id = open[mac] { updates.append([now, id]) } else { inserts.append([mac, now, now]) }
        }
        db.runMany("UPDATE device_sessions SET end=? WHERE id=?", updates)
        db.runMany("INSERT INTO device_sessions(mac, start, end) VALUES(?,?,?)", inserts)
    }

    /// Alerts when a device that isn't on your trusted list shows up again after being away ≥ 1 h.
    func checkUntrusted(_ d: Device, now: Date) {
        guard Prefs.untrustedAlerts, !d.trusted, now.timeIntervalSince(d.lastSeen) >= 3600 else { return }
        addEvent(.untrustedDevice, "\(d.displayName) (\(d.ip ?? "?"), \(d.mac)) joined the network — not on your trusted list", ssid: current?.ssid)
    }

    func setTag(_ macs: [String], _ tag: String?) {
        let t = tag?.trimmingCharacters(in: .whitespaces)
        db.runMany("UPDATE devices SET tag=? WHERE mac=?", macs.map { [t?.isEmpty == true ? nil : t, $0] })
        devices = Queries.allDevices(); dataVersion += 1
    }

    func setTrusted(_ macs: [String], _ trusted: Bool) {
        db.runMany("UPDATE devices SET trusted=? WHERE mac=?", macs.map { [trusted, $0] })
        devices = Queries.allDevices(); dataVersion += 1
    }

    func trustAllCurrent() {
        db.run("UPDATE devices SET trusted=1")
        devices = Queries.allDevices(); dataVersion += 1
    }

    func savePortScan(_ mac: String, _ results: [PortResult]) {
        let text = results.map { "\($0.port) \($0.service)" }.joined(separator: ", ")
        db.run("UPDATE devices SET open_ports=?, ports_scanned=? WHERE mac=?", [text.isEmpty ? "none" : text, Date(), mac])
        devices = Queries.allDevices(); dataVersion += 1
    }

    // MARK: Per-app connections

    func collectConnections() async {
        let link = linkState?.link
        let rows = await Blocking.run { () -> [[Any?]] in
            let conns = NetTop.connections()
            let names = NetTop.resolve(conns.map(\.remote))
            let now = Date()
            // Collapse duplicates (same app → same endpoint) into one row.
            var agg: [String: NetTop.Conn] = [:]
            for c in conns {
                let k = "\(c.app)|\(c.proto)|\(c.remote)|\(c.port)"
                if var e = agg[k] { e.rx += c.rx; e.tx += c.tx; agg[k] = e } else { agg[k] = c }
            }
            return agg.values.map { [now, $0.app, $0.proto, $0.remote, $0.port, names[$0.remote], $0.rx, $0.tx, link] }
        }
        db.runMany("INSERT INTO app_connections(ts, app, proto, remote, port, host, rx_bytes, tx_bytes, link) VALUES(?,?,?,?,?,?,?,?,?)", rows)
    }
}

/// Decides which part of the path (home, ISP, internet) is responsible for extra latency.
struct PathVerdict {
    var text: String
    var slow: Bool
    var segment: String?

    static func judge(_ r: TraceResult, baseline: (local: Double?, isp: Double?, upstream: Double?)) -> PathVerdict? {
        guard r.localMs != nil || r.ispMs != nil else { return nil }
        let parts: [(String, Double?, Double?, Double)] = [
            ("your Wi-Fi / home network", r.localMs, baseline.local, 15),
            ("your ISP", r.ispAdded, baseline.isp, 25),
            ("the wider internet (beyond your ISP)", r.upstreamAdded, baseline.upstream, 40),
        ]
        // A segment is "slow" when it's both well above its own baseline and above an absolute floor.
        let slow = parts.compactMap { name, v, b, floor -> (String, Double, Double)? in
            guard let v else { return nil }
            let ref = b ?? floor / 2
            return v > max(floor, ref * 2) ? (name, v, ref) : nil
        }.max { $0.1 - $0.2 < $1.1 - $1.2 }
        if let s = slow {
            return PathVerdict(text: "Slowdown is in \(s.0): \(Fmt.ms(s.1)) vs usual \(Fmt.ms(s.2))", slow: true, segment: s.0)
        }
        let total = r.totalMs ?? r.ispMs ?? r.localMs ?? 0
        return PathVerdict(text: "Path looks normal (\(Fmt.ms(total)) end-to-end)", slow: false, segment: nil)
    }
}
