import Foundation
import SystemConfiguration
import Darwin

// MARK: - Concurrency helpers

enum Blocking {
    /// Runs blocking work on a GCD thread (not the Swift cooperative pool) and awaits the result.
    static func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { c in
            DispatchQueue.global(qos: .utility).async { c.resume(returning: work()) }
        }
    }
}

enum Shell {
    @discardableResult
    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

// MARK: - Formatting

enum Fmt {
    static func ms(_ v: Double?) -> String { v.map { String(format: "%.1f ms", $0) } ?? "—" }
    static func dbm(_ v: Int?) -> String { v.map { "\($0) dBm" } ?? "—" }
    static func db(_ v: Int?) -> String { v.map { "\($0) dB" } ?? "—" }
    static func pct(_ v: Double?, digits: Int = 1) -> String { v.map { String(format: "%.\(digits)f%%", $0 * 100) } ?? "—" }
    static func mbps(_ v: Double?) -> String { v.map { String(format: "%.1f Mbps", $0) } ?? "—" }
    static func num(_ v: Double?, _ digits: Int = 0) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "—" }

    static func bps(_ v: Double?) -> String {
        guard let v else { return "—" }
        switch v {
        case 1e9...: return String(format: "%.2f Gbps", v / 1e9)
        case 1e6...: return String(format: "%.2f Mbps", v / 1e6)
        case 1e3...: return String(format: "%.1f Kbps", v / 1e3)
        default: return String(format: "%.0f bps", v)
        }
    }

    static func bytes(_ v: Double?) -> String {
        guard let v else { return "—" }
        let f = ByteCountFormatter()
        f.countStyle = .binary
        return f.string(fromByteCount: Int64(v))
    }

    static func duration(_ s: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = s >= 3600 ? [.day, .hour, .minute] : [.minute, .second]
        f.unitsStyle = .abbreviated
        return f.string(from: s) ?? "\(Int(s))s"
    }

    static let dateTime: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .medium; return f
    }()
    static let time: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .medium; return f
    }()
}

// MARK: - Network information

enum NetUtil {
    /// IPv4 address and netmask of an interface.
    static func ipv4(for ifname: String) -> (ip: String, mask: String)? {
        var ptr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ptr) == 0 else { return nil }
        defer { freeifaddrs(ptr) }
        var p = ptr
        while let cur = p {
            let ifa = cur.pointee
            if String(cString: ifa.ifa_name) == ifname, let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let ip = numericHost(sa)
                let mask = ifa.ifa_netmask.map(numericHost) ?? "255.255.255.0"
                if let ip { return (ip, mask ?? "255.255.255.0") }
            }
            p = ifa.ifa_next
        }
        return nil
    }

    private static func numericHost(_ sa: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: host)
    }

    static func defaultGateway() -> String? {
        let out = Shell.run("/sbin/route", ["-n", "get", "default"], timeout: 3).output
        for line in out.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("gateway:") { return t.dropFirst(8).trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    static func dnsServers() -> [String] {
        guard let store = SCDynamicStoreCreate(nil, "WiFiMonitor" as CFString, nil, nil),
              let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
              let servers = dict["ServerAddresses"] as? [String] else { return [] }
        return servers
    }

    /// Cumulative 64-bit byte counters for every interface (sysctl NET_RT_IFLIST2).
    static func byteCounters() -> [String: (rx: UInt64, tx: UInt64)] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [:] }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [:] }
        var result: [String: (UInt64, UInt64)] = [:]
        buf.withUnsafeBytes { raw in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr.self)
                if hdr.ifm_msglen == 0 { break }
                if Int32(hdr.ifm_type) == RTM_IFINFO2, off + MemoryLayout<if_msghdr2>.size <= len {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE) + 1)
                    if if_indextoname(UInt32(h2.ifm_index), &name) != nil {
                        result[String(cString: name)] = (h2.ifm_data.ifi_ibytes, h2.ifm_data.ifi_obytes)
                    }
                }
                off += Int(hdr.ifm_msglen)
            }
        }
        return result
    }

    struct ArpEntry { let ip: String; let mac: String; let iface: String }

    static func arpTable() -> [ArpEntry] {
        let out = Shell.run("/usr/sbin/arp", ["-an"], timeout: 5).output
        var entries: [ArpEntry] = []
        for line in out.split(separator: "\n") {
            // ? (192.168.1.1) at 94:98:69:6c:77:10 on en0 ifscope [ethernet]
            let parts = line.split(separator: " ")
            guard parts.count >= 6, parts[2] == "at", parts[4] == "on" else { continue }
            let ip = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let mac = String(parts[3])
            guard mac != "(incomplete)", mac != "ff:ff:ff:ff:ff:ff", !ip.hasSuffix(".255"), !ip.hasPrefix("224."), !ip.hasPrefix("239.") else { continue }
            entries.append(ArpEntry(ip: ip, mac: normalizeMAC(mac), iface: String(parts[5])))
        }
        return entries
    }

    static func normalizeMAC(_ m: String) -> String {
        m.split(separator: ":").map { $0.count == 1 ? "0" + $0 : String($0) }.joined(separator: ":").lowercased()
    }

    static func reverseDNS(_ ip: String) -> String? {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
            }
        }
        guard rc == 0 else { return nil }
        let name = String(cString: host)
        return name == ip ? nil : name
    }

    /// Host addresses in the subnet (capped to the /24 around our IP for large subnets).
    static func subnetHosts(ip: String, mask: String) -> [String] {
        func toInt(_ s: String) -> UInt32? {
            let p = s.split(separator: ".").compactMap { UInt32($0) }
            return p.count == 4 ? p.reduce(0) { $0 << 8 | $1 } : nil
        }
        guard let ipI = toInt(ip), var maskI = toInt(mask) else { return [] }
        if maskI.nonzeroBitCount < 22 { maskI = 0xFFFFFF00 }
        let network = ipI & maskI
        let broadcast = network | ~maskI
        guard broadcast > network + 1 else { return [] }
        return ((network + 1)..<broadcast).filter { $0 != ipI }.map {
            "\($0 >> 24 & 255).\($0 >> 16 & 255).\($0 >> 8 & 255).\($0 & 255)"
        }
    }
}

// MARK: - Probes

enum Probe {
    static let socketICMPAvailable: Bool = {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        if fd >= 0 { close(fd); return true }
        return false
    }()

    /// Single ICMP echo (in-process socket; falls back to /sbin/ping if the socket can't be opened).
    static func ping(_ host: String, timeout: Int = 2) -> Double? {
        if socketICMPAvailable { return ICMP.ping(host, timeoutMs: timeout * 1000) }
        let out = Shell.run("/sbin/ping", ["-n", "-c", "1", "-t", "\(timeout)", host], timeout: TimeInterval(timeout + 1)).output
        guard let r = out.range(of: "time=") else { return nil }
        let rest = out[r.upperBound...]
        let num = rest.prefix { $0.isNumber || $0 == "." }
        return Double(num)
    }

    /// Times a raw UDP DNS A-record query to `server` (bypasses the local cache).
    static func dnsQuery(server: String, name: String, timeout: Int = 2) -> Double? {
        let id = UInt16.random(in: 0...UInt16.max)
        var packet: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            let b = Array(label.utf8)
            packet.append(UInt8(b.count)); packet += b
        }
        packet += [0, 0, 1, 0, 1]

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(53).bigEndian
        guard inet_pton(AF_INET, server, &addr.sin_addr) == 1 else { return nil }

        let start = DispatchTime.now().uptimeNanoseconds
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
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

    /// Per-process cumulative Wi-Fi byte counters from nettop, keyed by "name.pid".
    static func nettopSnapshot() -> [String: (rx: Int64, tx: Int64)] {
        let out = Shell.run("/usr/bin/nettop", ["-P", "-L", "1", "-x", "-n", "-t", "wifi", "-J", "bytes_in,bytes_out"], timeout: 10).output
        var result: [String: (Int64, Int64)] = [:]
        for line in out.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3, let rx = Int64(cols[1]), let tx = Int64(cols[2]) else { continue }
            result[String(cols[0])] = (rx, tx)
        }
        return result
    }

    struct SpeedResult { var dl: Double?; var ul: Double?; var rpm: Double?; var rtt: Double? }

    /// Apple's built-in `networkQuality` test (macOS 12+). Takes ~20 seconds.
    static func speedTest() -> SpeedResult? {
        let out = Shell.run("/usr/bin/networkQuality", ["-c"], timeout: 120).output
        guard let start = out.firstIndex(of: "{"),
              let data = String(out[start...]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func num(_ k: String) -> Double? {
            if let d = json[k] as? Double { return d }
            if let i = json[k] as? Int { return Double(i) }
            if let s = json[k] as? String { return Double(s) }
            return nil
        }
        var r = SpeedResult()
        r.dl = num("dl_throughput").map { $0 / 1e6 }
        r.ul = num("ul_throughput").map { $0 / 1e6 }
        r.rpm = num("responsiveness") ?? num("dl_responsiveness")
        r.rtt = num("base_rtt")
        return (r.dl == nil && r.ul == nil) ? nil : r
    }
}
