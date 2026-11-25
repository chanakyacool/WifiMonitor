import Foundation
import SystemConfiguration
import Darwin

// MARK: - Address helpers

enum IPClass {
    static func v4(_ ip: String) -> [UInt32]? {
        let p = ip.split(separator: ".").compactMap { UInt32($0) }
        return p.count == 4 ? p : nil
    }
    static func isPrivate(_ ip: String) -> Bool {
        guard let p = v4(ip) else { return ip.hasPrefix("fe80") || ip.hasPrefix("fd") || ip.hasPrefix("fc") }
        return p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168) || (p[0] == 169 && p[1] == 254)
    }
    /// RFC 6598 carrier-grade NAT space — always inside the ISP.
    static func isCGNAT(_ ip: String) -> Bool {
        guard let p = v4(ip) else { return false }
        return p[0] == 100 && (64...127).contains(p[1])
    }
}

// MARK: - ASN / ISP lookups (DNS TXT queries to Team Cymru, cached)

enum ASN {
    struct Info { let asn: Int; let owner: String? }
    private static var cache: [String: Info?] = [:]
    private static var names: [Int: String] = [:]
    private static let lock = NSLock()

    private static func txt(_ name: String) -> String? {
        let out = Shell.run("/usr/bin/dig", ["+short", "+time=2", "+tries=1", "TXT", name], timeout: 5).output
        return out.split(separator: "\n").first.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
    }

    /// ASN + owner name for a public IPv4 address (nil for private/unknown).
    static func lookup(_ ip: String) -> Info? {
        guard Prefs.asnLookups, let p = IPClass.v4(ip), !IPClass.isPrivate(ip), !IPClass.isCGNAT(ip) else { return nil }
        lock.lock(); if let c = cache[ip] { lock.unlock(); return c }; lock.unlock()
        var info: Info?
        if let t = txt("\(p[3]).\(p[2]).\(p[1]).\(p[0]).origin.asn.cymru.com"),
           let asn = t.split(separator: "|").first.flatMap({ Int($0.trimmingCharacters(in: .whitespaces).split(separator: " ").first ?? "") }) {
            lock.lock(); var owner = names[asn]; lock.unlock()
            if owner == nil, let n = txt("AS\(asn).asn.cymru.com") {
                // "13335 | US | arin | 2010-07-14 | CLOUDFLARENET - Cloudflare, Inc., US"
                owner = n.split(separator: "|").last.map { raw -> String in
                    let s = raw.trimmingCharacters(in: .whitespaces)
                    if let dash = s.range(of: " - ") { return String(s[dash.upperBound...]).replacingOccurrences(of: #",\s*[A-Z]{2}$"#, with: "", options: .regularExpression) }
                    return s
                }
                lock.lock(); names[asn] = owner; lock.unlock()
            }
            info = Info(asn: asn, owner: owner)
        }
        lock.lock(); cache[ip] = info; lock.unlock()
        return info
    }
}

// MARK: - Traceroute with segment attribution

struct TraceHop: Identifiable {
    var id: Int { hop }
    var hop: Int
    var ip: String?
    var rtt: Double?
    var asn: Int?
    var owner: String?
    var segment: String     // "Home", "ISP", "Internet"
}

struct TraceResult {
    var ts = Date()
    var target: String
    var hops: [TraceHop]
    var reached: Bool
    var localMs: Double?    // latency to the edge of your home network
    var ispMs: Double?      // latency to the last ISP hop
    var totalMs: Double?    // latency to the destination

    var ispAdded: Double? { ispMs.flatMap { i in localMs.map { max(0, i - $0) } ?? i } }
    var upstreamAdded: Double? { totalMs.flatMap { t in (ispMs ?? localMs).map { max(0, t - $0) } } }
}

enum Traceroute {
    static func resolveV4(_ host: String) -> String? {
        if IPClass.v4(host) != nil { return host }
        var hints = addrinfo(); hints.ai_family = AF_INET
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let r = res else { return nil }
        defer { freeaddrinfo(res) }
        var a = r.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count))
        return String(cString: buf)
    }

    /// Distinctive words of an organisation name ("Bharti Airtel Ltd., Telemedia Services" → bharti, airtel).
    static func orgTokens(_ s: String?) -> Set<String> {
        let generic: Set<String> = ["ltd", "limited", "inc", "corp", "corporation", "company", "services", "service", "telemedia",
                                    "communications", "communication", "network", "networks", "internet", "telecom", "broadband",
                                    "the", "group", "holdings", "pvt", "private", "llc", "gmbh", "global", "data", "online"]
        return Set((s ?? "").lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count >= 4 && !generic.contains($0) })
    }

    static func run(_ target: String, publicASN: Int?, publicISP: String? = nil) -> TraceResult? {
        let out = Shell.run("/usr/sbin/traceroute", ["-n", "-I", "-q", "1", "-w", "1", "-m", "24", target], timeout: 60).output
        var hops: [TraceHop] = []
        for line in out.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let n = parts.first.flatMap({ Int($0) }) else { continue }
            if parts.count >= 3, parts[1] != "*" {
                let ip = String(parts[1])
                let rtt = Double(parts[2])
                hops.append(TraceHop(hop: n, ip: ip, rtt: rtt, segment: ""))
            } else {
                hops.append(TraceHop(hop: n, ip: nil, rtt: nil, segment: ""))
            }
        }
        guard !hops.isEmpty else { return nil }

        // ASN lookups in parallel for public hops.
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: hops.count) { i in
            guard let ip = hops[i].ip, let info = ASN.lookup(ip) else { return }
            lock.lock(); hops[i].asn = info.asn; hops[i].owner = info.owner; lock.unlock()
        }

        // Segment attribution: hop 1 = home; private/CGNAT or same-ASN-as-your-public-IP = ISP; everything after = Internet.
        var seg = "Home"
        var ispASN = publicASN
        var ispOrg = orgTokens(publicISP)
        for i in hops.indices {
            if i == 0 { hops[i].segment = "Home"; continue }
            if let ip = hops[i].ip {
                if seg != "Internet" {
                    if IPClass.isPrivate(ip) || IPClass.isCGNAT(ip) { seg = "ISP" }
                    else if let a = hops[i].asn {
                        if ispASN == nil { ispASN = a; ispOrg = orgTokens(hops[i].owner) }   // first public hop belongs to your ISP
                        // Big ISPs run several ASNs (e.g. broadband vs backbone) — same organisation name counts as ISP too.
                        let sameOrg = !ispOrg.isDisjoint(with: orgTokens(hops[i].owner))
                        seg = (a == ispASN || sameOrg) ? "ISP" : "Internet"
                    }   // unknown owner: stay in the current segment
                }
            }
            hops[i].segment = seg
        }
        let dest = resolveV4(target) ?? target
        let reached = hops.last?.ip == dest
        func lastRTT(_ s: String) -> Double? { hops.last { $0.segment == s && $0.rtt != nil }?.rtt }
        return TraceResult(target: target, hops: hops, reached: reached, localMs: lastRTT("Home"), ispMs: lastRTT("ISP"),
                           totalMs: reached ? hops.last?.rtt : nil)
    }
}

// MARK: - Public IP, captive portal

enum NetIdentity {
    struct Snapshot: Equatable {
        var publicIP: String?
        var asn: Int?
        var isp: String?
        var captive: Bool
    }

    static func publicIP() -> String? {
        let out = Shell.run("/usr/bin/dig", ["+short", "-4", "+time=2", "+tries=1", "myip.opendns.com", "@resolver1.opendns.com"], timeout: 5).output
        let ip = out.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
        return ip.flatMap { IPClass.v4($0) != nil ? $0 : nil }
    }

    /// Same check macOS/iOS use: a captive network intercepts this URL instead of returning "Success".
    static func captivePortal() -> Bool? {
        guard let u = URL(string: "http://captive.apple.com/hotspot-detect.html"),
              let r = HTTP.shared.request(u, headers: ["Cache-Control": "no-cache"]) else { return nil }
        return !String(decoding: r.data, as: UTF8.self).contains("Success")
    }

    static func snapshot() -> Snapshot {
        let captive = captivePortal() ?? false
        let ip = captive ? nil : publicIP()
        let info = ip.flatMap(ASN.lookup)
        return Snapshot(publicIP: ip, asn: info?.asn, isp: info?.owner, captive: captive)
    }
}

// MARK: - IPv6

enum IPv6Probe {
    struct Result {
        var hasV6: Bool
        var address: String?
        var latency: Double?
        var loss: Double?
        var dnsLatency: Double?
    }

    /// First global-unicast IPv6 address on the interface (skips link-local and ULA).
    static func globalAddress(_ iface: String) -> String? {
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0 else { return nil }
        defer { freeifaddrs(ptr) }
        var p = ptr
        while let cur = p {
            let ifa = cur.pointee
            if String(cString: ifa.ifa_name) == iface, let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET6) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let a = String(cString: host)
                    let l = a.lowercased()
                    if !l.hasPrefix("fe80"), !l.hasPrefix("fd"), !l.hasPrefix("fc"), l != "::1", l.first == "2" || l.first == "3" { return a }
                }
            }
            p = ifa.ifa_next
        }
        return nil
    }

    static func probe(iface: String, dnsName: String) -> Result {
        let addr = globalAddress(iface)
        guard addr != nil else { return Result(hasV6: false) }
        var rtts: [Double] = []
        let targets = ["2606:4700:4700::1111", "2001:4860:4860::8888"]
        for t in targets {
            let out = Shell.run("/sbin/ping6", ["-c", "2", "-i", "0.2", t], timeout: 5).output
            for line in out.split(separator: "\n") {
                if let r = line.range(of: "time=") {
                    let num = line[r.upperBound...].prefix { $0.isNumber || $0 == "." }
                    if let v = Double(num) { rtts.append(v) }
                }
            }
        }
        let sent = Double(targets.count * 2)
        return Result(hasV6: true, address: addr,
                      latency: rtts.isEmpty ? nil : rtts.reduce(0, +) / Double(rtts.count),
                      loss: 1 - Double(rtts.count) / sent,
                      dnsLatency: dnsQueryV6(server: "2606:4700:4700::1111", name: dnsName))
    }

    /// Times a raw AAAA query sent over IPv6 transport.
    static func dnsQueryV6(server: String, name: String) -> Double? {
        let id = UInt16.random(in: 0...UInt16.max)
        var packet: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") { let b = Array(label.utf8); packet.append(UInt8(b.count)); packet += b }
        packet += [0, 0, 28, 0, 1]
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = in_port_t(53).bigEndian
        guard inet_pton(AF_INET6, server, &addr.sin6_addr) == 1 else { return nil }
        let start = DispatchTime.now().uptimeNanoseconds
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        guard sent > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 1500)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n <= 0 { return nil }
            if n >= 2, buf[0] == UInt8(id >> 8), buf[1] == UInt8(id & 0xFF) { break }
        }
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }
}

// MARK: - Link type & VPN detection

enum LinkInfo {
    struct State: Equatable {
        var primary: String?        // interface with the default route
        var link: String            // Wi-Fi / Ethernet / VPN / Other / Offline
        var vpn: String?            // active VPN name (split or full tunnel)
        var ethernet: [String]      // wired interfaces with an IPv4 address
    }

    static func primaryInterface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "WiFiMonitor" as CFString, nil, nil),
              let d = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] else { return nil }
        return d["PrimaryInterface"] as? String
    }

    /// Interfaces that currently have an IPv4 address → address.
    static func ipv4Interfaces() -> [String: String] {
        var out: [String: String] = [:]
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0 else { return out }
        defer { freeifaddrs(ptr) }
        var p = ptr
        while let cur = p {
            let ifa = cur.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), (ifa.ifa_flags & UInt32(IFF_UP)) != 0 {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    out[String(cString: ifa.ifa_name)] = String(cString: host)
                }
            }
            p = ifa.ifa_next
        }
        return out
    }

    private static var vpnNameCache: (ifaces: Set<String>, name: String?)?

    static func state(wifiInterface: String) -> State {
        let v4 = ipv4Interfaces()
        let primary = primaryInterface()
        let tunnels = v4.keys.filter { $0.hasPrefix("utun") || $0.hasPrefix("ipsec") || $0.hasPrefix("ppp") || $0.hasPrefix("tun") || $0.hasPrefix("wg") }
        let ethernet = v4.keys.filter { $0.hasPrefix("en") && $0 != wifiInterface }.sorted()
        var vpn: String?
        if !tunnels.isEmpty {
            let set = Set(tunnels)
            if let c = vpnNameCache, c.ifaces == set { vpn = c.name } else {
                vpn = vpnName(tunnels: tunnels, addresses: v4)
                vpnNameCache = (set, vpn)
            }
        } else { vpnNameCache = nil }
        let link: String
        switch primary {
        case nil: link = "Offline"
        case let p? where p == wifiInterface: link = "Wi-Fi"
        case let p? where tunnels.contains(p): link = "VPN"
        case let p? where p.hasPrefix("en"): link = "Ethernet"
        default: link = "Other"
        }
        return State(primary: primary, link: link, vpn: vpn, ethernet: ethernet)
    }

    /// Best-effort friendly VPN name: system VPN services first, then well-known address ranges.
    private static func vpnName(tunnels: [String], addresses: [String: String]) -> String? {
        let out = Shell.run("/usr/sbin/scutil", ["--nc", "list"], timeout: 3).output
        for line in out.split(separator: "\n") where line.contains("(Connected)") {
            if let a = line.firstIndex(of: "\""), let b = line[line.index(after: a)...].firstIndex(of: "\"") {
                return String(line[line.index(after: a)..<b])
            }
        }
        for t in tunnels.sorted() {
            guard let ip = addresses[t] else { continue }
            if IPClass.isCGNAT(ip) { return "Tailscale (\(t))" }
            if ip.hasPrefix("10.2.0.") { return "Proton VPN (\(t))" }
            if ip.hasPrefix("10.64.") || ip.hasPrefix("10.65.") { return "WireGuard VPN (\(t))" }
            return "VPN (\(t))"
        }
        return nil
    }
}

// MARK: - Port scanner (on-demand, opt-in)

struct PortResult: Identifiable, Hashable {
    var id: Int { port }
    var port: Int
    var service: String
    var banner: String?
    var latency: Double
}

enum PortScanner {
    static let common: [Int: String] = [
        21: "FTP", 22: "SSH", 23: "Telnet", 25: "SMTP", 53: "DNS", 80: "HTTP", 81: "HTTP alt", 88: "Kerberos", 110: "POP3",
        111: "RPC", 135: "MS RPC", 139: "NetBIOS", 143: "IMAP", 161: "SNMP", 389: "LDAP", 443: "HTTPS", 445: "SMB", 465: "SMTPS",
        515: "LPD printer", 548: "AFP", 554: "RTSP camera", 587: "SMTP submit", 631: "IPP printer", 853: "DNS over TLS",
        873: "rsync", 993: "IMAPS", 995: "POP3S", 1080: "SOCKS", 1194: "OpenVPN", 1433: "MS SQL", 1723: "PPTP", 1883: "MQTT",
        1900: "UPnP", 2049: "NFS", 2375: "Docker (insecure)", 2376: "Docker TLS", 3000: "Web dev / Grafana", 3306: "MySQL",
        3389: "Remote Desktop", 3689: "DAAP / iTunes", 4070: "Spotify Connect", 5000: "UPnP / Synology", 5001: "Synology HTTPS",
        5060: "SIP", 5353: "mDNS", 5432: "PostgreSQL", 5555: "Android ADB", 5900: "VNC / Screen Sharing", 6379: "Redis",
        6443: "Kubernetes", 6668: "Tuya IoT", 7000: "AirPlay", 7100: "AirPlay", 8000: "HTTP alt", 8008: "Chromecast",
        8009: "Chromecast", 8060: "Roku", 8080: "HTTP proxy / alt", 8081: "HTTP alt", 8086: "InfluxDB", 8123: "Home Assistant",
        8291: "MikroTik Winbox", 8443: "HTTPS alt", 8554: "RTSP alt", 8883: "MQTT TLS", 8888: "HTTP alt", 9000: "Portainer / PHP",
        9090: "Prometheus / Cockpit", 9100: "Printer raw", 9200: "Elasticsearch", 10000: "Webmin", 11211: "Memcached",
        27017: "MongoDB", 32400: "Plex", 49152: "UPnP", 62078: "iPhone sync (lockdown)",
    ]

    /// TCP connect scan of the well-known port list. Never runs automatically.
    static func scan(_ ip: String, ports: [Int] = Array(common.keys).sorted(), timeoutMs: Int32 = 700,
                     progress: ((Int) -> Void)? = nil) -> [PortResult] {
        var results: [PortResult] = []
        let lock = NSLock()
        var done = 0
        let sem = DispatchSemaphore(value: 48)
        let group = DispatchGroup()
        for port in ports {
            sem.wait(); group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { sem.signal(); group.leave() }
                if let r = probe(ip, port, timeoutMs) { lock.lock(); results.append(r); lock.unlock() }
                lock.lock(); done += 1; let d = done; lock.unlock()
                progress?(d)
            }
        }
        group.wait()
        return results.sorted { $0.port < $1.port }
    }

    private static func probe(_ ip: String, _ port: Int, _ timeoutMs: Int32) -> PortResult? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port)).bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        let start = DispatchTime.now().uptimeNanoseconds
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if rc != 0 && errno != EINPROGRESS { return nil }
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMs) == 1 else { return nil }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        guard err == 0 else { return nil }
        let latency = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6

        // Banner grab: HTTP-ish ports get a HEAD request; others may speak first (SSH, FTP, SMTP…).
        let httpPorts: Set<Int> = [80, 81, 3000, 5000, 8000, 8008, 8060, 8080, 8081, 8123, 8888, 9000, 9090, 32400]
        if httpPorts.contains(port) {
            let req = Array("HEAD / HTTP/1.0\r\nHost: \(ip)\r\n\r\n".utf8)
            _ = send(fd, req, req.count, 0)
        }
        var banner: String?
        var rp = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        if poll(&rp, 1, 800) == 1 {
            var buf = [UInt8](repeating: 0, count: 512)
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 {
                let text = String(decoding: buf[0..<n], as: UTF8.self)
                let lines = text.split(whereSeparator: \.isNewline).map(String.init)
                if httpPorts.contains(port) {
                    let status = lines.first ?? ""
                    let server = lines.first { $0.lowercased().hasPrefix("server:") }.map { String($0.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
                    banner = [status, server].compactMap { $0 }.joined(separator: " · ")
                } else {
                    banner = lines.first.map { String($0.filter { $0.isASCII && !$0.isNewline }.prefix(120)) }
                }
            }
        }
        return PortResult(port: port, service: common[port] ?? "tcp/\(port)", banner: banner?.isEmpty == true ? nil : banner, latency: latency)
    }
}

// MARK: - Per-process traffic and connections (nettop)

enum NetTop {
    struct Conn { var app: String; var proto: String; var remote: String; var port: Int; var rx: Int64; var tx: Int64 }

    /// Cumulative bytes per "name.pid" for one link type ("wifi" or "wired").
    static func processBytes(link: String) -> [String: (rx: Int64, tx: Int64)] {
        let out = Shell.run("/usr/bin/nettop", ["-P", "-L", "1", "-x", "-n", "-t", link, "-J", "bytes_in,bytes_out"], timeout: 10).output
        var result: [String: (Int64, Int64)] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3, let rx = Int64(cols[1]), let tx = Int64(cols[2]) else { continue }
            result[String(cols[0])] = (rx, tx)
        }
        return result
    }

    /// Open connections per process (remote endpoint + bytes so far). Skips listeners and loopback.
    static func connections() -> [Conn] {
        let out = Shell.run("/usr/bin/nettop", ["-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"], timeout: 15).output
        var conns: [Conn] = []
        var app = ""
        for line in out.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard let first = cols.first, !first.isEmpty else { continue }
            guard first.hasPrefix("tcp") || first.hasPrefix("udp") else {
                let parts = first.split(separator: ".")
                app = parts.count > 1 ? parts.dropLast().joined(separator: ".") : first
                continue
            }
            let bits = first.split(separator: " ", maxSplits: 1)
            guard bits.count == 2, let arrow = bits[1].range(of: "<->") else { continue }
            let proto = bits[0].hasPrefix("tcp") ? "TCP" : "UDP"
            let remoteRaw = String(bits[1][arrow.upperBound...])
            guard !remoteRaw.hasPrefix("*") else { continue }
            let v4 = bits[0].hasSuffix("4")
            let sep: Character = v4 ? ":" : "."
            guard let idx = remoteRaw.lastIndex(of: sep), let port = Int(remoteRaw[remoteRaw.index(after: idx)...]) else { continue }
            var host = String(remoteRaw[..<idx])
            if let pct = host.firstIndex(of: "%") { host = String(host[..<pct]) }
            if host.hasPrefix("127.") || host == "::1" || host.hasPrefix("fe80") { continue }
            let rx = cols.count > 1 ? Int64(cols[1]) ?? 0 : 0, tx = cols.count > 2 ? Int64(cols[2]) ?? 0 : 0
            conns.append(Conn(app: app, proto: proto, remote: host, port: port, rx: rx, tx: tx))
        }
        return conns
    }

    private static var dnsCache: [String: String?] = [:]
    private static let lock = NSLock()

    /// Reverse-DNS names for remote IPs (cached; at most `limit` new lookups per call).
    static func resolve(_ ips: [String], limit: Int = 40) -> [String: String] {
        lock.lock()
        let todo = Array(Set(ips).filter { dnsCache[$0] == nil }.prefix(limit))
        lock.unlock()
        DispatchQueue.concurrentPerform(iterations: todo.count) { i in
            let name = reverse(todo[i])
            lock.lock(); dnsCache[todo[i]] = .some(name); lock.unlock()
        }
        lock.lock(); defer { lock.unlock() }
        var out: [String: String] = [:]
        for ip in ips { if let n = dnsCache[ip] ?? nil { out[ip] = n } }
        return out
    }

    private static func reverse(_ ip: String) -> String? {
        if !ip.contains(":") { return NetUtil.reverseDNS(ip) }
        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        guard inet_pton(AF_INET6, ip, &addr.sin6_addr) == 1 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in6>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        return rc == 0 ? String(cString: host) : nil
    }
}
