import Foundation
import Darwin

// MARK: - MAC vendor (OUI) lookup

/// IEEE OUI → vendor, from the bundled `oui.tsv` (generated from Wireshark's manuf list).
enum OUI {
    private static let table: [String: String] = {
        let candidates = [
            Bundle.main.url(forResource: "oui", withExtension: "tsv"),
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("../../Resources/oui.tsv"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/oui.tsv"),
        ].compactMap { $0 }
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var t: [String: String] = [:]
        t.reserveCapacity(41_000)
        for line in text.split(separator: "\n") {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            t[String(line[..<tab])] = String(line[line.index(after: tab)...])
        }
        return t
    }()

    static var isLoaded: Bool { !table.isEmpty }

    static func vendor(for mac: String) -> String? {
        let hex = mac.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "-", with: "").uppercased()
        guard hex.count >= 6 else { return nil }
        if let b = UInt8(hex.prefix(2), radix: 16), b & 0x02 != 0 { return "Private address" }
        return table[String(hex.prefix(6))]
    }
}

// MARK: - Device name discovery (mDNS / NetBIOS / SSDP)

struct DiscoveredNames {
    var mdnsName: String?
    var netbiosName: String?
    var friendlyName: String?
    var model: String?
    var kind: String?
}

enum NameDiscovery {
    /// Probes one device over mDNS (unicast) and NetBIOS. Each probe is a single UDP packet with a short timeout.
    static func probe(ip: String) -> DiscoveredNames {
        var n = DiscoveredNames()
        n.mdnsName = mdnsReverse(ip)
        let services = mdnsServices(ip)
        n.kind = classify(services)
        n.netbiosName = netbios(ip)
        return n
    }

    /// One SSDP M-SEARCH for the whole LAN; returns friendly name/model per IP (TVs, speakers, consoles, NAS, printers…).
    static func ssdpSweep(timeout: Double = 2.5) -> [String: (name: String?, model: String?, maker: String?)] {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return [:] }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(1900).bigEndian
        inet_pton(AF_INET, "239.255.255.250", &addr.sin_addr)
        let msg = Array("M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: upnp:rootdevice\r\n\r\n".utf8)
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, msg, msg.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var locations: [String: URL] = [:]
        var buf = [UInt8](repeating: 0, count: 2048)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var from = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
            }
            guard n > 0 else { continue }
            let ip = String(cString: inet_ntoa(from.sin_addr))
            guard locations[ip] == nil else { continue }
            for line in String(decoding: buf[0..<n], as: UTF8.self).components(separatedBy: "\r\n")
            where line.lowercased().hasPrefix("location:") {
                locations[ip] = URL(string: line.dropFirst(9).trimmingCharacters(in: .whitespaces))
            }
        }
        var out: [String: (String?, String?, String?)] = [:]
        let lock = NSLock()
        let list = Array(locations.prefix(40))
        DispatchQueue.concurrentPerform(iterations: list.count) { i in
            let (ip, url) = list[i]
            guard let r = HTTP.shared.request(url), let xml = String(data: r.data, encoding: .utf8) else { return }
            func tag(_ t: String) -> String? {
                guard let a = xml.range(of: "<\(t)>"), let b = xml.range(of: "</\(t)>", range: a.upperBound..<xml.endIndex) else { return nil }
                let v = xml[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }
            lock.lock(); out[ip] = (tag("friendlyName"), tag("modelName"), tag("manufacturer")); lock.unlock()
        }
        return out
    }

    // MARK: mDNS

    private static func dnsQuery(name: String, type: UInt16, unicastResponse: Bool) -> [UInt8] {
        var p: [UInt8] = [0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") { let b = Array(label.utf8); p.append(UInt8(b.count)); p += b }
        p += [0, UInt8(type >> 8), UInt8(type & 0xFF), unicastResponse ? 0x80 : 0x00, 0x01]
        return p
    }

    private static func udpExchange(_ ip: String, port: UInt16, _ packet: [UInt8], timeoutMs: Int = 600) -> [UInt8]? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: Int32(timeoutMs * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return nil }
        let sent = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, packet, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard sent > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: 9000)
        let n = recv(fd, &buf, buf.count, 0)
        return n > 12 ? Array(buf[0..<n]) : nil
    }

    /// Reads a (possibly compressed) DNS name at `offset`; returns the name and the offset after it.
    private static func readName(_ b: [UInt8], _ offset: Int) -> (String, Int)? {
        var labels: [String] = []
        var i = offset, end: Int? = nil, jumps = 0
        while i < b.count {
            let len = Int(b[i])
            if len == 0 { i += 1; break }
            if len & 0xC0 == 0xC0 {
                guard i + 1 < b.count, jumps < 20 else { return nil }
                if end == nil { end = i + 2 }
                i = (len & 0x3F) << 8 | Int(b[i + 1]); jumps += 1
                continue
            }
            guard i + 1 + len <= b.count else { return nil }
            labels.append(String(decoding: b[(i + 1)..<(i + 1 + len)], as: UTF8.self))
            i += 1 + len
        }
        return (labels.joined(separator: "."), end ?? i)
    }

    /// Returns all PTR targets in the answer/additional sections.
    private static func ptrAnswers(_ b: [UInt8]) -> [String] {
        let qd = Int(b[4]) << 8 | Int(b[5])
        let records = (Int(b[6]) << 8 | Int(b[7])) + (Int(b[8]) << 8 | Int(b[9])) + (Int(b[10]) << 8 | Int(b[11]))
        var i = 12
        for _ in 0..<qd { guard let (_, next) = readName(b, i) else { return [] }; i = next + 4 }
        var out: [String] = []
        for _ in 0..<records {
            guard let (_, next) = readName(b, i), next + 10 <= b.count else { break }
            let type = Int(b[next]) << 8 | Int(b[next + 1])
            let rdlen = Int(b[next + 8]) << 8 | Int(b[next + 9])
            let rdata = next + 10
            if type == 12, let (target, _) = readName(b, rdata) { out.append(target) }
            i = rdata + rdlen
        }
        return out
    }

    static func mdnsReverse(_ ip: String) -> String? {
        let rev = ip.split(separator: ".").reversed().joined(separator: ".") + ".in-addr.arpa"
        guard let resp = udpExchange(ip, port: 5353, dnsQuery(name: rev, type: 12, unicastResponse: true)) else { return nil }
        guard let name = ptrAnswers(resp).first else { return nil }
        let clean = name.hasSuffix(".local") ? String(name.dropLast(6)) : name
        return clean.isEmpty ? nil : clean
    }

    static func mdnsServices(_ ip: String) -> [String] {
        guard let resp = udpExchange(ip, port: 5353, dnsQuery(name: "_services._dns-sd._udp.local", type: 12, unicastResponse: true)) else { return [] }
        return ptrAnswers(resp)
    }

    /// Guesses a device type from advertised Bonjour services.
    static func classify(_ services: [String]) -> String? {
        let s = Set(services.map { $0.lowercased() })
        func has(_ x: String) -> Bool { s.contains { $0.hasPrefix(x) } }
        if has("_googlecast") { return "Chromecast / Google TV" }
        if has("_androidtvremote") { return "Android TV" }
        if has("_airplay") && has("_raop") && !has("_companion-link") { return "AirPlay speaker / TV" }
        if has("_hap") || has("_homekit") { return "HomeKit accessory" }
        if has("_ipp") || has("_printer") || has("_pdl-datastream") || has("_scanner") { return "Printer / scanner" }
        if has("_spotify-connect") || has("_sonos") { return "Speaker" }
        if has("_companion-link") || has("_apple-mobdev") || has("_rdlink") { return "Apple device" }
        if has("_smb") || has("_afpovertcp") || has("_ssh") || has("_sftp-ssh") { return "Computer / NAS" }
        if has("_amzn") { return "Amazon device" }
        if has("_matter") { return "Matter device" }
        return services.isEmpty ? nil : "Bonjour device"
    }

    // MARK: NetBIOS

    /// NetBIOS node-status query (Windows PCs, Samba/NAS boxes).
    static func netbios(_ ip: String) -> String? {
        var p: [UInt8] = [UInt8.random(in: 0...255), UInt8.random(in: 0...255), 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0x20]
        p += Array("CKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA".utf8)
        p += [0, 0, 0x21, 0, 1]
        guard let r = udpExchange(ip, port: 137, p), r.count > 57 else { return nil }
        let count = Int(r[56])
        var i = 57
        for _ in 0..<count {
            guard i + 18 <= r.count else { break }
            let name = String(decoding: r[i..<(i + 15)], as: UTF8.self).trimmingCharacters(in: .whitespaces.union(.controlCharacters))
            let suffix = r[i + 15], group = r[i + 16] & 0x80 != 0
            if suffix == 0 && !group && !name.isEmpty { return name }
            i += 18
        }
        return nil
    }
}
