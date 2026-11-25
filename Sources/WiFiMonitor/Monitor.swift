import Foundation
import SwiftUI
import UserNotifications

/// Central engine: runs collection loops, detects events, persists to SQLite, publishes live state to the UI.
@MainActor
final class Monitor: ObservableObject {
    static let shared = Monitor()

    let db = Database.shared
    private let location = LocationPermission()

    // Live state
    @Published var current: Sample?
    @Published var recent: [Sample] = []           // last 15 minutes, in memory
    @Published var nearby: [ScanResult] = []
    @Published var lastScan: Date?
    @Published var devices: [Device] = []
    @Published var events: [EventItem] = []
    @Published var speedTestRunning = false
    @Published var speedTestStarted: Date?
    @Published var lastSpeedTest: SpeedTestResult?
    @Published var lastSpeedTestError: String?
    @Published var sweeping = false
    @Published var internetUp = true
    /// True when hosts answer ping but the ARP table comes back empty → Local Network permission not granted.
    @Published var localNetworkBlocked = false
    @Published var locationAuthorized = false
    @Published var sessionRx: Int64 = 0             // bytes since app launch
    @Published var sessionTx: Int64 = 0

    // Router integration
    @Published var router: RouterSnapshot?
    @Published var routerError: String?
    @Published var routerWanRxBps: Double?
    @Published var routerWanTxBps: Double?
    private let routerService = RouterClientService()

    // Watch targets & data cap
    @Published var targets: [WatchTarget] = []
    @Published var targetLatest: [Int64: TargetResult] = [:]
    @Published var capStatus: DataCap.Status?
    private var targetLastRun: [Int64: Date] = [:]
    private var targetFailStreak: [Int64: Int] = [:]
    private var targetDown: Set<Int64> = []
    private var certWarned: [Int64: Date] = [:]
    private var targetsRunning = false
    private var prevWan: (rx: UInt64, tx: UInt64, t: Date)?
    private var prevClientBytes: [String: (rx: UInt64, tx: UInt64)] = [:]

    // Dashboard filters (shared across every dashboard)
    @Published var filter = DashFilter()
    @Published var filterOptions = FilterOptions()
    /// Bumped whenever new data lands that dashboards should reload for.
    @Published var dataVersion = 0

    // Paths, identity, IPv6, link type
    @Published var linkState: LinkInfo.State?
    @Published var identity: NetIdentity.Snapshot?
    @Published var lastTrace: TraceResult?
    @Published var tracing = false
    @Published var ipv6: IPv6Probe.Result?
    var ipv6Ok: Bool?
    var stickyWarned = Date.distantPast
    var pathSlowActive = false
    var prevEth: (rx: UInt64, tx: UInt64, t: Date)?

    var tasks: [Task<Void, Never>] = []
    private var started = false
    private var prevCounters: (iface: String, rx: UInt64, tx: UInt64, t: Date)?
    var cachedGateway: String?
    private var lastGatewayRefresh = Date.distantPast
    var lastSample: Sample?
    private var inetFailStreak = 0
    private var inetDownSince: Date?
    private var lowSignal = false
    private var highLatencyStreak = 0
    private var highLatencyActive = false
    var prevNettop: [String: (rx: Int64, tx: Int64)]?
    var knownMACs = Set<String>()

    var menuIcon: String {
        guard current?.connected == true || linkState?.link == "Ethernet" else { return "bolt.slash.fill" }
        if !internetUp { return "bolt.trianglebadge.exclamationmark.fill" }
        return "bolt.fill"
    }

    // MARK: - Lifecycle

    func start() {
        guard !started else { return }
        started = true
        Prefs.register()
        location.onChange = { [weak self] ok in self?.locationAuthorized = ok }
        locationAuthorized = location.authorized
        location.request()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        loadFromDB()
        addEvent(.started, "Monitoring started")

        tasks.append(loop(seconds: { Prefs.sampleInterval }) { await self.collectSample() })
        tasks.append(loop(initialDelay: 4, seconds: { Prefs.scanInterval }) { await self.scanNearby() })
        tasks.append(loop(initialDelay: 8, seconds: { Prefs.sweepInterval > 0 ? Prefs.sweepInterval : 120 }) {
            await self.refreshDevices(sweep: Prefs.sweepInterval > 0)
        })
        tasks.append(loop(initialDelay: 2, seconds: { Prefs.appUsageInterval > 0 ? Prefs.appUsageInterval : 60 }) {
            if Prefs.appUsageInterval > 0 { await self.collectAppUsage() }
        })
        tasks.append(loop(initialDelay: 90, seconds: { 60 }) { await self.maybeAutoSpeedTest() })
        tasks.append(loop(initialDelay: 6, seconds: { Prefs.routerInterval }) {
            if Prefs.routerKind != .none { await self.pollRouter() }
        })
        tasks.append(loop(initialDelay: 20, seconds: { 3600 }) { await self.maintenance() })
        tasks.append(loop(initialDelay: 3, seconds: { 10 }) { await self.runDueTargets() })
        tasks.append(loop(initialDelay: 2, seconds: { 300 }) { await self.checkDataCap() })
        tasks.append(loop(initialDelay: 30, seconds: { 30 }) {
            await self.reloadFilterOptions()
            self.dataVersion += 1
        })
        startExtras()
    }

    func requestLocation() {
        location.request()
        if !location.authorized,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    func loop(initialDelay: Double = 0, seconds: @escaping () -> Double, _ body: @escaping () async -> Void) -> Task<Void, Never> {
        Task {
            if initialDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(initialDelay * 1e9)) }
            while !Task.isCancelled {
                let interval = seconds()
                if interval > 0 { await body() }
                try? await Task.sleep(nanoseconds: UInt64(max(1, interval) * 1e9))
            }
        }
    }

    private func loadFromDB() {
        let since = Date().addingTimeInterval(-15 * 60).timeIntervalSince1970
        recent = db.query("SELECT * FROM samples WHERE ts >= ? ORDER BY ts", [since]).map(Sample.init(row:))
        events = Queries.recentEvents(limit: 300)
        devices = Queries.allDevices()
        knownMACs = Set(devices.map(\.mac))
        targets = Queries.targets()
        for t in targets {
            if let r = db.query("SELECT * FROM target_results WHERE target_id = ? ORDER BY ts DESC LIMIT 1", [t.id]).first {
                targetLatest[t.id] = Queries.targetResult(r)
                targetLastRun[t.id] = r.date("ts")
            }
        }
        if let lastTs = db.scalar("SELECT MAX(ts) FROM scans") {
            nearby = db.query("SELECT * FROM scans WHERE ts = ? ORDER BY rssi DESC", [lastTs]).map(Queries.scanResult)
            lastScan = Date(timeIntervalSince1970: lastTs)
        }
        if let r = db.query("SELECT * FROM net_identity ORDER BY ts DESC LIMIT 1").first {
            identity = .init(publicIP: r.string("public_ip"), asn: r.int("asn"), isp: r.string("isp"), captive: (r.int("captive") ?? 0) == 1)
        }
        if let r = db.query("SELECT * FROM ipv6_samples ORDER BY ts DESC LIMIT 1").first {
            ipv6 = .init(hasV6: (r.int("has_v6") ?? 0) == 1, address: r.string("address"), latency: r.double("latency"),
                         loss: r.double("loss"), dnsLatency: r.double("dns_latency"))
            ipv6Ok = ipv6?.hasV6 == true && ipv6?.latency != nil
        }
        lastTrace = Queries.latestTrace()
        Task { await reloadFilterOptions() }
    }

    func reloadFilterOptions() async {
        filterOptions = await Blocking.run { Queries.filterOptions() }
    }

    // MARK: - Sampling

    private func collectSample() async {
        // `route` is a subprocess, so only re-read the gateway every 2 min, on roam/IP change, or when unknown.
        let refreshGW = Date().timeIntervalSince(lastGatewayRefresh) > 120 || cachedGateway == nil
        let gwCache = cachedGateway
        let host1 = Prefs.pingHost1, host2 = Prefs.pingHost2, dnsHost = Prefs.dnsTestHost

        let (sample, gateway, counters) = await Blocking.run { () -> (Sample, String?, [String: (rx: UInt64, tx: UInt64)]) in
            var s = WiFiCollector.snapshot()
            let iface = s.interface ?? "en0"
            if let addr = NetUtil.ipv4(for: iface) { s.ip = addr.ip }
            let gw = refreshGW ? NetUtil.defaultGateway() : gwCache
            s.gateway = gw
            let dnsServers = NetUtil.dnsServers()
            s.dns = dnsServers.joined(separator: ", ")

            // Run the 4 probes in parallel.
            var gwL: Double?, l1: Double?, l2: Double?, dnsL: Double?
            let group = DispatchGroup()
            let q = DispatchQueue.global(qos: .utility)
            let lock = NSLock()
            if let gw { group.enter(); q.async { let v = Probe.ping(gw); lock.lock(); gwL = v; lock.unlock(); group.leave() } }
            group.enter(); q.async { let v = Probe.ping(host1); lock.lock(); l1 = v; lock.unlock(); group.leave() }
            group.enter(); q.async { let v = Probe.ping(host2); lock.lock(); l2 = v; lock.unlock(); group.leave() }
            if let dnsServer = dnsServers.first(where: { !$0.contains(":") }) {
                group.enter(); q.async { let v = Probe.dnsQuery(server: dnsServer, name: dnsHost); lock.lock(); dnsL = v; lock.unlock(); group.leave() }
            }
            group.wait()

            s.gwLatency = gwL
            s.dnsLatency = dnsL
            let inet = [l1, l2].compactMap { $0 }
            s.inetLatency = inet.isEmpty ? nil : inet.reduce(0, +) / Double(inet.count)
            s.loss = Double(2 - inet.count) / 2.0
            let ls = LinkInfo.state(wifiInterface: iface)
            s.primaryIface = ls.primary; s.link = ls.link; s.vpn = ls.vpn
            return (s, gw, NetUtil.byteCounters())
        }

        var s = sample
        if refreshGW { cachedGateway = gateway; lastGatewayRefresh = Date() }
        if s.ip != lastSample?.ip || s.bssid != lastSample?.bssid { lastGatewayRefresh = .distantPast }

        // Throughput & data usage from interface byte counters.
        let iface = s.interface ?? "en0"
        if let c = counters[iface] {
            if let p = prevCounters, p.iface == iface, c.rx >= p.rx, c.tx >= p.tx {
                let dt = s.ts.timeIntervalSince(p.t)
                let drx = Int64(c.rx - p.rx), dtx = Int64(c.tx - p.tx)
                s.rxBytes = drx; s.txBytes = dtx
                if dt > 0 { s.rxBps = Double(drx) * 8 / dt; s.txBps = Double(dtx) * 8 / dt }
                sessionRx += drx; sessionTx += dtx
            }
            prevCounters = (iface, c.rx, c.tx, s.ts)
        }
        // Wired traffic: sum every Ethernet-type interface that has an address (docks, USB adapters, Thunderbolt).
        let ls = LinkInfo.State(primary: s.primaryIface, link: s.link ?? "Offline", vpn: s.vpn,
                                ethernet: counters.keys.filter { $0.hasPrefix("en") && $0 != iface && NetUtil.ipv4(for: $0) != nil })
        let eth = ls.ethernet.reduce((rx: UInt64(0), tx: UInt64(0))) { acc, n in
            guard let c = counters[n] else { return acc }
            return (acc.rx + c.rx, acc.tx + c.tx)
        }
        if !ls.ethernet.isEmpty {
            if let p = prevEth, eth.rx >= p.rx, eth.tx >= p.tx { s.ethRxBytes = Int64(eth.rx - p.rx); s.ethTxBytes = Int64(eth.tx - p.tx) }
            prevEth = (eth.rx, eth.tx, s.ts)
        } else { prevEth = nil }
        analyzeLink(ls, s)
        linkState = ls

        analyze(s)
        persist(s)
        current = s
        lastSample = s
        recent.append(s)
        let cutoff = Date().addingTimeInterval(-15 * 60)
        if let idx = recent.firstIndex(where: { $0.ts >= cutoff }), idx > 0 { recent.removeFirst(idx) }
    }

    private func persist(_ s: Sample) {
        db.run("""
        INSERT INTO samples(ts, connected, power_on, interface, ssid, bssid, rssi, noise, snr, channel, band, width, phy,
            tx_rate, tx_power, security, country, mac, ip, gateway, dns, gw_latency, inet_latency, dns_latency, loss,
            rx_bps, tx_bps, rx_bytes, tx_bytes, primary_iface, link, vpn, eth_rx_bytes, eth_tx_bytes)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [s.ts, s.connected, s.powerOn, s.interface, s.ssid, s.bssid, s.rssi, s.noise, s.snr, s.channel, s.band,
              s.width, s.phy, s.txRate, s.txPower, s.security, s.country, s.mac, s.ip, s.gateway, s.dns,
              s.gwLatency, s.inetLatency, s.dnsLatency, s.loss, s.rxBps, s.txBps, s.rxBytes, s.txBytes,
              s.primaryIface, s.link, s.vpn, s.ethRxBytes, s.ethTxBytes])
    }

    // MARK: - Event detection

    private func analyze(_ s: Sample) {
        if let p = lastSample {
            if p.powerOn != s.powerOn { addEvent(.powerChange, "Wi-Fi turned \(s.powerOn ? "on" : "off")") }
            if p.connected && !s.connected {
                addEvent(.disconnected, "Disconnected from \(p.ssid ?? "Wi-Fi")", ssid: p.ssid, bssid: p.bssid)
            } else if !p.connected && s.connected {
                addEvent(.connected, "Connected to \(s.ssid ?? "Wi-Fi") on ch \(s.channel.map(String.init) ?? "?") (\(s.band ?? "?"))", ssid: s.ssid, bssid: s.bssid)
            } else if p.connected && s.connected {
                if let a = p.ssid, let b = s.ssid, a != b {
                    addEvent(.ssidChange, "Switched network \(a) → \(b)", ssid: b, bssid: s.bssid)
                } else if let a = p.bssid, let b = s.bssid, a != b {
                    addEvent(.roam, "Roamed \(a) → \(b) · ch \(p.channel ?? 0) → \(s.channel ?? 0) · \(Fmt.dbm(p.rssi)) → \(Fmt.dbm(s.rssi))", ssid: s.ssid, bssid: b)
                } else if let a = p.channel, let b = s.channel, a != b {
                    addEvent(.channelChange, "Channel \(a) → \(b) (\(s.band ?? "?"), \(s.width ?? "?"))", ssid: s.ssid, bssid: s.bssid)
                }
            }
            if let a = p.ip, let b = s.ip, a != b { addEvent(.ipChange, "IP address \(a) → \(b)", ssid: s.ssid, bssid: s.bssid) }
        } else if s.connected {
            addEvent(.connected, "Connected to \(s.ssid ?? "Wi-Fi") · \(Fmt.dbm(s.rssi)) · ch \(s.channel ?? 0)", ssid: s.ssid, bssid: s.bssid)
        }

        // Signal strength threshold (with 3 dB hysteresis)
        if s.connected, let r = s.rssi {
            if r < Prefs.lowRssi && !lowSignal {
                lowSignal = true
                addEvent(.lowSignal, "Weak signal \(r) dBm on \(s.ssid ?? "Wi-Fi")", ssid: s.ssid, bssid: s.bssid)
            } else if r >= Prefs.lowRssi + 3 && lowSignal {
                lowSignal = false
                addEvent(.signalRecovered, "Signal recovered to \(r) dBm", ssid: s.ssid, bssid: s.bssid)
            }
        }

        // Internet reachability (2 consecutive failed samples = down)
        if s.inetLatency == nil {
            inetFailStreak += 1
            if inetFailStreak == 2 && internetUp {
                internetUp = false
                inetDownSince = lastSample?.ts ?? s.ts
                let why = !s.connected ? "Wi-Fi disconnected" : (s.gwLatency == nil ? "router unreachable" : "router OK, upstream unreachable")
                addEvent(.internetDown, "Internet unreachable (\(why))", ssid: s.ssid, bssid: s.bssid)
            }
        } else {
            if !internetUp {
                internetUp = true
                let dur = inetDownSince.map { s.ts.timeIntervalSince($0) } ?? 0
                addEvent(.internetUp, "Internet restored after \(Fmt.duration(dur))", ssid: s.ssid, bssid: s.bssid)
            }
            inetFailStreak = 0
        }

        // Latency threshold (3 consecutive high samples)
        if let l = s.inetLatency {
            if l > Prefs.highLatency {
                highLatencyStreak += 1
                if highLatencyStreak == 3 && !highLatencyActive {
                    highLatencyActive = true
                    addEvent(.highLatency, "High latency \(Fmt.ms(l)) to internet", ssid: s.ssid, bssid: s.bssid)
                }
            } else {
                highLatencyStreak = 0
                if highLatencyActive {
                    highLatencyActive = false
                    addEvent(.latencyRecovered, "Latency back to \(Fmt.ms(l))", ssid: s.ssid, bssid: s.bssid)
                }
            }
        }
    }

    func addEvent(_ type: EventType, _ message: String, ssid: String? = nil, bssid: String? = nil) {
        let now = Date()
        let id = db.run("INSERT INTO events(ts, type, message, ssid, bssid) VALUES(?,?,?,?,?)",
                        [now, type.rawValue, message, ssid, bssid])
        events.insert(EventItem(id: id, ts: now, type: type, message: message, ssid: ssid), at: 0)
        if events.count > 500 { events.removeLast(events.count - 500) }
        if type.notifies && Prefs.notifications && Bundle.main.bundleIdentifier != nil {
            let content = UNMutableNotificationContent()
            content.title = type.title
            content.body = message
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    // MARK: - Nearby networks

    func scanNearby() async {
        let result: Result<[ScanResult], Error> = await Blocking.run {
            do { return .success(try WiFiCollector.scan()) } catch { return .failure(error) }
        }
        switch result {
        case .success(let list):
            nearby = list
            lastScan = Date()
            checkSticky(list)
            db.runMany("""
            INSERT INTO scans(ts, ssid, bssid, rssi, noise, channel, band, width, security, beacon_interval, country)
            VALUES(?,?,?,?,?,?,?,?,?,?,?)
            """, list.map { [$0.ts, $0.ssid, $0.bssid, $0.rssi, $0.noise, $0.channel, $0.band, $0.width, $0.security, $0.beaconInterval, $0.country] })
        case .failure(let e):
            NSLog("Scan failed: \(e.localizedDescription)")
        }
    }

    // MARK: - LAN devices

    func refreshDevices(sweep: Bool) async {
        guard !sweeping else { return }
        sweeping = true
        defer { sweeping = false }
        let iface = current?.interface ?? "en0"
        let ssid = current?.ssid
        let (entries, responders) = await Blocking.run { () -> ([NetUtil.ArpEntry], Int) in
            var alive = 0
            if sweep, let addr = NetUtil.ipv4(for: iface) {
                // One-socket ICMP sweep populates the ARP cache (devices that ignore ping still answer ARP).
                alive = ICMP.sweep(NetUtil.subnetHosts(ip: addr.ip, mask: addr.mask)).count
            }
            return (NetUtil.arpTable().filter { $0.iface == iface }, alive)
        }
        localNetworkBlocked = entries.isEmpty && (responders > 0 || current?.gwLatency != nil)

        let now = Date()
        let firstRun = knownMACs.isEmpty
        var needNames: [(String, String)] = []
        let before = Dictionary(devices.map { ($0.mac, $0) }, uniquingKeysWith: { a, _ in a })
        for e in entries {
            if let d = before[e.mac] { checkUntrusted(d, now: now) }
            if knownMACs.contains(e.mac) {
                db.run("UPDATE devices SET ip=?, last_seen=?, ssid=COALESCE(?, ssid), interface=? WHERE mac=?", [e.ip, now, ssid, e.iface, e.mac])
            } else {
                knownMACs.insert(e.mac)
                db.run("INSERT OR IGNORE INTO devices(mac, ip, interface, ssid, first_seen, last_seen) VALUES(?,?,?,?,?,?)",
                       [e.mac, e.ip, e.iface, ssid, now, now])
                if !firstRun { addEvent(.newDevice, "New device \(e.ip) (\(e.mac))", ssid: ssid) }
            }
            needNames.append((e.mac, e.ip))
        }
        recordPresence(entries.map(\.mac), at: now)
        devices = Queries.allDevices()

        // Resolve hostnames for devices that don't have one yet.
        let missing = needNames.filter { pair in devices.first(where: { $0.mac == pair.0 })?.hostname == nil }
        if !missing.isEmpty {
            let names = await Blocking.run { () -> [(String, String)] in
                var out: [(String, String)] = []
                let lock = NSLock()
                DispatchQueue.concurrentPerform(iterations: missing.count) { i in
                    if let n = NetUtil.reverseDNS(missing[i].1) { lock.lock(); out.append((missing[i].0, n)); lock.unlock() }
                }
                return out
            }
            for (mac, name) in names { db.run("UPDATE devices SET hostname=? WHERE mac=?", [name, mac]) }
            if !names.isEmpty { devices = Queries.allDevices() }
        }
        await discoverNames(entries.map { ($0.mac, $0.ip) })
    }

    /// Vendor + Bonjour/NetBIOS/SSDP names for devices not checked in the last 24 h (max 40 per run).
    private func discoverNames(_ list: [(mac: String, ip: String)]) async {
        let dayAgo = Date().addingTimeInterval(-86400)
        let checked = Dictionary(db.query("SELECT mac, names_checked FROM devices").compactMap { r in
            r.string("mac").map { ($0, r.date("names_checked") ?? .distantPast) } }, uniquingKeysWith: { a, _ in a })
        let due = Array(list.filter { (checked[$0.mac] ?? .distantPast) < dayAgo }.prefix(40))
        guard !due.isEmpty else { return }
        let found = await Blocking.run { () -> ([String: DiscoveredNames], [String: (name: String?, model: String?, maker: String?)]) in
            var out: [String: DiscoveredNames] = [:]
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: due.count) { i in
                let n = NameDiscovery.probe(ip: due[i].ip)
                lock.lock(); out[due[i].mac] = n; lock.unlock()
            }
            return (out, NameDiscovery.ssdpSweep())
        }
        let now = Date()
        for d in due {
            let n = found.0[d.mac]
            let ssdp = found.1[d.ip]
            let model = [ssdp?.maker, ssdp?.model].compactMap { $0 }.joined(separator: " ")
            db.run("""
            UPDATE devices SET vendor=?, mdns_name=COALESCE(?, mdns_name), netbios_name=COALESCE(?, netbios_name),
                friendly_name=COALESCE(?, friendly_name), model=COALESCE(?, model), kind=COALESCE(?, kind), names_checked=? WHERE mac=?
            """, [OUI.vendor(for: d.mac), n?.mdnsName, n?.netbiosName, ssdp?.name, model.isEmpty ? nil : model,
                  n?.kind ?? (ssdp != nil ? "UPnP device" : nil), now, d.mac])
        }
        devices = Queries.allDevices()
    }

    func setNickname(_ mac: String, _ name: String?) {
        let v = name?.trimmingCharacters(in: .whitespaces)
        db.run("UPDATE devices SET nickname=? WHERE mac=?", [v?.isEmpty == true ? nil : v, mac])
        devices = Queries.allDevices()
        dataVersion += 1
    }

    // MARK: - Watch targets

    func addTarget(name: String, kind: TargetKind, target: String, interval: Double) {
        db.run("INSERT INTO targets(name, kind, target, interval, enabled, created) VALUES(?,?,?,?,1,?)",
               [name.isEmpty ? target : name, kind.rawValue, target.trimmingCharacters(in: .whitespaces), interval, Date()])
        targets = Queries.targets()
        Task { await runDueTargets() }
    }

    func updateTarget(_ t: WatchTarget) {
        db.run("UPDATE targets SET name=?, kind=?, target=?, interval=?, enabled=? WHERE id=?",
               [t.name, t.kind.rawValue, t.target, t.interval, t.enabled, t.id])
        targets = Queries.targets()
        targetLastRun[t.id] = nil
    }

    func deleteTarget(_ id: Int64) {
        db.run("DELETE FROM target_results WHERE target_id=?", [id])
        db.run("DELETE FROM targets WHERE id=?", [id])
        targets = Queries.targets()
        targetLatest[id] = nil
        dataVersion += 1
    }

    func checkTargetNow(_ id: Int64) {
        targetLastRun[id] = nil
        Task { await runDueTargets() }
    }

    func runDueTargets() async {
        guard !targetsRunning else { return }
        let now = Date()
        let due = targets.filter { $0.enabled && now.timeIntervalSince(targetLastRun[$0.id] ?? .distantPast) >= $0.interval }
        guard !due.isEmpty else { return }
        targetsRunning = true
        defer { targetsRunning = false }
        for t in due { targetLastRun[t.id] = now }
        let results = await Blocking.run { () -> [(WatchTarget, TargetResult)] in
            var out: [(WatchTarget, TargetResult)] = []
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: due.count) { i in
                let r = TargetChecker.check(due[i])
                lock.lock(); out.append((due[i], r)); lock.unlock()
            }
            return out
        }
        db.runMany("INSERT INTO target_results(ts, target_id, ok, latency, status, detail, cert_expiry) VALUES(?,?,?,?,?,?,?)",
                   results.map { [$1.ts, $0.id, $1.ok, $1.latency, $1.status, $1.detail, $1.certExpiry] })
        for (t, r) in results {
            targetLatest[t.id] = r
            if r.ok {
                targetFailStreak[t.id] = 0
                if targetDown.remove(t.id) != nil { addEvent(.targetUp, "\(t.name) is back up (\(Fmt.ms(r.latency)))") }
            } else {
                targetFailStreak[t.id, default: 0] += 1
                // TLS targets "fail" on expiry warnings — report those separately, once a day.
                if t.kind == .tls, let days = r.certDaysLeft {
                    if Date().timeIntervalSince(certWarned[t.id] ?? .distantPast) > 86400 {
                        certWarned[t.id] = Date()
                        addEvent(.certExpiring, "\(t.name): certificate \(days < 0 ? "expired" : "expires in \(days) days")")
                    }
                } else if targetFailStreak[t.id] == 2 && !targetDown.contains(t.id) {
                    targetDown.insert(t.id)
                    addEvent(.targetDown, "\(t.name) is down — \(r.detail ?? "no response")")
                }
            }
        }
    }

    // MARK: - Data cap

    func checkDataCap() async {
        guard DataCap.enabled else { capStatus = nil; return }
        let st = await Blocking.run { DataCap.status() }
        capStatus = st
        let key = "capNotified-\(Int(st.start.timeIntervalSince1970))"
        let already = UserDefaults.standard.integer(forKey: key)
        if let level = [100, 80, 50].first(where: { st.fraction * 100 >= Double($0) }), level > already {
            UserDefaults.standard.set(level, forKey: key)
            addEvent(.dataCap, "\(level)% of your \(Fmt.bytes(st.cap)) data cap used (\(Fmt.bytes(st.used))) · \(st.daysLeft) days left")
        }
    }

    // MARK: - Per-app usage

    private func collectAppUsage() async {
        // One nettop pass per link type so usage can be split into Wi-Fi vs wired (Ethernet, docks, USB/Thunderbolt).
        let snap = await Blocking.run { () -> [String: (rx: Int64, tx: Int64)] in
            var out: [String: (rx: Int64, tx: Int64)] = [:]
            for link in ["wifi", "wired"] {
                for (k, v) in NetTop.processBytes(link: link) { out["\(link)|\(k)"] = v }
            }
            return out
        }
        guard !snap.isEmpty else { return }
        defer { prevNettop = snap }
        guard let prev = prevNettop else { return } // first run = baseline only

        var perApp: [String: (rx: Int64, tx: Int64)] = [:]
        for (key, cur) in snap {
            var drx = cur.rx, dtx = cur.tx
            if let p = prev[key] {
                drx = cur.rx >= p.rx ? cur.rx - p.rx : cur.rx
                dtx = cur.tx >= p.tx ? cur.tx - p.tx : cur.tx
            }
            guard drx > 0 || dtx > 0 else { continue }
            let parts = key.split(separator: "|", maxSplits: 1)
            let link = parts.first == "wired" ? "Ethernet" : "Wi-Fi"
            let proc = String(parts.last ?? "")
            let app = proc.split(separator: ".").dropLast().joined(separator: ".")
            let name = "\(link)|" + (app.isEmpty ? proc : app)
            perApp[name, default: (0, 0)].rx += drx
            perApp[name, default: (0, 0)].tx += dtx
        }
        let now = Date(), c = current
        db.runMany("INSERT INTO app_usage(ts, app, rx_bytes, tx_bytes, ssid, bssid, band, link) VALUES(?,?,?,?,?,?,?,?)",
                   perApp.map { k, v in
                       let parts = k.split(separator: "|", maxSplits: 1).map(String.init)
                       let wifi = parts[0] == "Wi-Fi"
                       return [now, parts[1], v.rx, v.tx, wifi ? c?.ssid : nil, wifi ? c?.bssid : nil, wifi ? c?.band : nil, parts[0]]
                   })
    }

    // MARK: - Router

    func routerConfig() -> RouterClientService.Config {
        let d = UserDefaults.standard
        let host = (d.string(forKey: "routerHost") ?? "").trimmingCharacters(in: .whitespaces)
        let user = d.string(forKey: "routerUser") ?? ""
        return .init(kind: Prefs.routerKind, host: host.isEmpty ? (current?.gateway ?? cachedGateway ?? "") : host,
                     username: user, password: Keychain.load(account: user.isEmpty ? "router" : user) ?? "",
                     community: d.string(forKey: "routerCommunity") ?? "public",
                     wanInterface: d.string(forKey: "routerWan") ?? "", https: d.bool(forKey: "routerHTTPS"),
                     site: d.string(forKey: "routerSite") ?? "default")
    }

    /// Polls the router once. Returns a human-readable status (used by "Test connection").
    @discardableResult
    func pollRouter() async -> String {
        let cfg = routerConfig()
        let svc = routerService
        let result = await Blocking.run { svc.poll(cfg) }
        switch result {
        case .failure(let e):
            routerError = e.message
            return "✗ " + e.message
        case .success(let snap):
            routerError = nil
            ingestRouter(snap)
            router = snap
            var parts = ["✓ Connected"]
            if let m = snap.model { parts.append(m) }
            if snap.wanRx != nil { parts.append("WAN counters OK") }
            if !snap.clients.isEmpty { parts.append("\(snap.clients.count) clients") }
            return parts.joined(separator: " · ")
        }
    }

    private func counterDelta(_ new: UInt64, _ old: UInt64, wrap32: Bool) -> UInt64 {
        if new >= old { return new - old }
        if wrap32 && old > (1 << 31) { return (UInt64(1) << 32) - old + new } // 32-bit counter wrapped
        return new // router rebooted / counter reset
    }

    private func ingestRouter(_ s: RouterSnapshot) {
        checkRouterReboot(s)
        var drx: UInt64?, dtx: UInt64?
        routerWanRxBps = nil; routerWanTxBps = nil
        if let rx = s.wanRx, let tx = s.wanTx {
            if let p = prevWan {
                let dt = s.ts.timeIntervalSince(p.t)
                let a = counterDelta(rx, p.rx, wrap32: s.wanCounters32bit), b = counterDelta(tx, p.tx, wrap32: s.wanCounters32bit)
                // Discard impossible jumps (> 10 Gbps average) from counter glitches.
                if dt > 0, Double(a + b) * 8 / dt < 10e9 {
                    drx = a; dtx = b
                    routerWanRxBps = Double(a) * 8 / dt; routerWanTxBps = Double(b) * 8 / dt
                }
            }
            prevWan = (rx, tx, s.ts)
        }
        db.run("""
        INSERT INTO router_stats(ts, wan_rx_bytes, wan_tx_bytes, wan_rx_bps, wan_tx_bps, uptime, external_ip, link_down, link_up, link_status, cpu, mem, clients)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
        """, [s.ts, drx, dtx, routerWanRxBps, routerWanTxBps, s.uptime, s.externalIP, s.linkDown, s.linkUp, s.linkStatus,
              s.cpuLoad, s.memUsed, s.clients.isEmpty ? nil : s.clients.count])

        // Per-client usage + merge router-known clients into the LAN device list.
        var usageRows: [[Any?]] = []
        for c in s.clients {
            db.run("""
            INSERT INTO router_clients(mac, ip, name, signal, iface, rx_total, tx_total, first_seen, last_seen, ap) VALUES(?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(mac) DO UPDATE SET ip=COALESCE(excluded.ip, ip), name=COALESCE(excluded.name, name), signal=excluded.signal,
                iface=COALESCE(excluded.iface, iface), rx_total=excluded.rx_total, tx_total=excluded.tx_total, last_seen=excluded.last_seen,
                ap=COALESCE(excluded.ap, ap)
            """, [c.mac, c.ip, c.name, c.signal, c.iface, c.rxTotal, c.txTotal, s.ts, s.ts, c.ap])
            if let rx = c.rxTotal, let tx = c.txTotal {
                if let p = prevClientBytes[c.mac] {
                    let up = counterDelta(rx, p.rx, wrap32: false), down = counterDelta(tx, p.tx, wrap32: false)
                    if up + down > 0 { usageRows.append([s.ts, c.mac, down, up]) }
                }
                prevClientBytes[c.mac] = (rx, tx)
            }
            if let d = devices.first(where: { $0.mac == c.mac }) { checkUntrusted(d, now: s.ts) }
            if !knownMACs.contains(c.mac) {
                knownMACs.insert(c.mac)
                db.run("INSERT OR IGNORE INTO devices(mac, ip, hostname, ssid, first_seen, last_seen) VALUES(?,?,?,?,?,?)",
                       [c.mac, c.ip, c.name, current?.ssid, s.ts, s.ts])
            } else {
                db.run("UPDATE devices SET last_seen=?, ip=COALESCE(?, ip), hostname=COALESCE(hostname, ?) WHERE mac=?", [s.ts, c.ip, c.name, c.mac])
            }
        }
        db.runMany("INSERT INTO router_client_usage(ts, mac, down_bytes, up_bytes) VALUES(?,?,?,?)", usageRows)
        recordPresence(s.clients.map(\.mac), at: s.ts)
        if !s.clients.isEmpty { devices = Queries.allDevices() }
    }

    // MARK: - Speed tests

    func runSpeedTest(kind: String = "manual") async {
        guard !speedTestRunning else { return }
        speedTestRunning = true
        speedTestStarted = Date()
        lastSpeedTestError = nil
        defer { speedTestRunning = false }
        let c = current
        guard let r = await Blocking.run({ Probe.speedTest() }) else {
            lastSpeedTestError = "No result from networkQuality — check your internet connection and try again."
            addEvent(.scanError, "Speed test failed (no result from networkQuality)", ssid: c?.ssid)
            return
        }
        let loaded = r.rpm.flatMap { $0 > 0 ? 60000 / $0 : nil }
        let id = db.run("INSERT INTO speedtests(ts, dl_mbps, ul_mbps, responsiveness, base_rtt, interface, ssid, bssid, band, loaded_latency, kind) VALUES(?,?,?,?,?,?,?,?,?,?,?)",
               [Date(), r.dl, r.ul, r.rpm, r.rtt, c?.interface, c?.ssid, c?.bssid, c?.band, loaded, kind])
        let result = SpeedTestResult(id: id, ts: Date(), dlMbps: r.dl, ulMbps: r.ul, responsiveness: r.rpm, baseRTT: r.rtt, ssid: c?.ssid, band: c?.band,
                                     loadedLatency: loaded, kind: kind)
        lastSpeedTest = result
        let grade = result.bloatGrade.map { " · bufferbloat \($0.rawValue) (+\(Fmt.ms(result.bloatMs)))" } ?? ""
        addEvent(.speedTest, "↓ \(Fmt.mbps(r.dl))  ↑ \(Fmt.mbps(r.ul))  · \(Fmt.num(r.rpm)) RPM\(grade)", ssid: c?.ssid, bssid: c?.bssid)
        dataVersion += 1
    }

    private func maybeAutoSpeedTest() async {
        // Scheduled bufferbloat tests at the hours you picked (busy-hour checks), once per hour slot.
        let hour = Calendar.current.component(.hour, from: Date())
        if Prefs.bufferbloatHours.contains(hour) {
            let slot = Calendar.current.dateInterval(of: .hour, for: Date())!.start.timeIntervalSince1970
            if (db.scalar("SELECT COUNT(*) FROM speedtests WHERE kind='scheduled' AND ts >= ?", [slot]) ?? 0) == 0 {
                await runSpeedTest(kind: "scheduled")
                return
            }
        }
        let minutes = Prefs.speedTestInterval
        guard minutes > 0 else { return }
        let last = db.scalar("SELECT MAX(ts) FROM speedtests") ?? 0
        if Date().timeIntervalSince1970 - last >= minutes * 60 { await runSpeedTest(kind: "auto") }
    }

    // MARK: - Maintenance

    private func maintenance() async {
        let cutoff = Date().addingTimeInterval(-Prefs.retentionDays * 86400).timeIntervalSince1970
        await Blocking.run {
            for t in ["samples", "scans", "events", "app_usage", "router_stats", "router_client_usage", "target_results",
                      "ipv6_samples", "net_identity", "app_connections"] {
                Database.shared.run("DELETE FROM \(t) WHERE ts < ?", [cutoff])
            }
            Database.shared.run("DELETE FROM trace_hops WHERE trace_id IN (SELECT id FROM traces WHERE ts < ?)", [cutoff])
            Database.shared.run("DELETE FROM traces WHERE ts < ?", [cutoff])
            Database.shared.run("DELETE FROM device_sessions WHERE end < ?", [cutoff])
            // Per-connection snapshots are bulky: keep 14 days at most.
            Database.shared.run("DELETE FROM app_connections WHERE ts < ?", [Date().addingTimeInterval(-14 * 86400).timeIntervalSince1970])
            Database.shared.exec("PRAGMA optimize;")
        }
    }

    func clearAllData() {
        for t in ["samples", "scans", "events", "speedtests", "devices", "app_usage", "router_stats", "router_clients", "router_client_usage", "target_results",
                  "device_sessions", "traces", "trace_hops", "ipv6_samples", "net_identity", "app_connections"] {
            db.run("DELETE FROM \(t)")
        }
        db.exec("VACUUM;")
        recent = []; events = []; devices = []; nearby = []; knownMACs = []
        sessionRx = 0; sessionTx = 0
        dataVersion += 1
        Task { await reloadFilterOptions() }
    }
}
