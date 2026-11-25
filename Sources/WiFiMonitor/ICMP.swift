import Foundation
import Darwin

/// In-process ICMP echo using an unprivileged datagram socket (macOS allows this without root).
/// Replaces spawning /sbin/ping — no process launches, near-zero CPU.
enum ICMP {
    private static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count { sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1]); i += 2 }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
        return ~UInt16(sum)
    }

    private static func packet(id: UInt16, seq: UInt16) -> [UInt8] {
        var p: [UInt8] = [8, 0, 0, 0, UInt8(id >> 8), UInt8(id & 0xFF), UInt8(seq >> 8), UInt8(seq & 0xFF)]
        p += Array("wifimonitor-probe".utf8)
        let c = checksum(p)
        p[2] = UInt8(c >> 8); p[3] = UInt8(c & 0xFF)
        return p
    }

    private static func resolve(_ host: String) -> in_addr? {
        var a = in_addr()
        if inet_pton(AF_INET, host, &a) == 1 { return a }
        var hints = addrinfo(); hints.ai_family = AF_INET
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0, let r = res else { return nil }
        defer { freeaddrinfo(res) }
        return r.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    }

    private static func openSocket(timeoutMs: Int) -> Int32? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        var tv = timeval(tv_sec: timeoutMs / 1000, tv_usec: Int32((timeoutMs % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private static func send(_ fd: Int32, to addr: in_addr, id: UInt16, seq: UInt16) -> Bool {
        var sa = sockaddr_in()
        sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        sa.sin_family = sa_family_t(AF_INET)
        sa.sin_addr = addr
        let p = packet(id: id, seq: seq)
        return withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, p, p.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } > 0
    }

    /// Receives one datagram; returns (source address, icmp type, id, seq) or nil on timeout.
    private static func receive(_ fd: Int32) -> (src: in_addr_t, type: UInt8, id: UInt16, seq: UInt16)? {
        var buf = [UInt8](repeating: 0, count: 1500)
        var from = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buf, buf.count, 0, $0, &len) }
        }
        guard n > 0 else { return nil }
        // macOS delivers the IP header on ICMP datagram sockets; skip it if present.
        var off = 0
        if buf[0] >> 4 == 4 { off = Int(buf[0] & 0x0F) * 4 }
        guard n >= off + 8 else { return (from.sin_addr.s_addr, 255, 0, 0) }
        return (from.sin_addr.s_addr, buf[off], UInt16(buf[off + 4]) << 8 | UInt16(buf[off + 5]), UInt16(buf[off + 6]) << 8 | UInt16(buf[off + 7]))
    }

    /// Round-trip time in milliseconds, or nil on timeout.
    static func ping(_ host: String, timeoutMs: Int = 1500) -> Double? {
        guard let addr = resolve(host), let fd = openSocket(timeoutMs: timeoutMs) else { return nil }
        defer { close(fd) }
        let id = UInt16.random(in: 1...UInt16.max), seq = UInt16.random(in: 1...UInt16.max)
        let start = DispatchTime.now().uptimeNanoseconds
        guard send(fd, to: addr, id: id, seq: seq) else { return nil }
        let deadline = start + UInt64(timeoutMs) * 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            guard let r = receive(fd) else { return nil }
            if r.type == 0 && r.src == addr.s_addr && r.seq == seq {
                return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
            }
        }
        return nil
    }

    /// Pings many hosts from a single socket (paced), then collects replies.
    /// Mainly used to populate the ARP cache for LAN device discovery. Returns responding IPs.
    static func sweep(_ hosts: [String], waitMs: Int = 1500) -> Set<String> {
        guard let fd = openSocket(timeoutMs: 200) else { return [] }
        defer { close(fd) }
        let id = UInt16.random(in: 1...UInt16.max)
        var byAddr: [in_addr_t: String] = [:]
        for (i, h) in hosts.enumerated() {
            guard let a = resolve(h) else { continue }
            byAddr[a.s_addr] = h
            _ = send(fd, to: a, id: id, seq: UInt16(truncatingIfNeeded: i))
            if i % 32 == 31 { usleep(5_000) } // gentle pacing
        }
        var alive = Set<String>()
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(waitMs) * 1_000_000
        while DispatchTime.now().uptimeNanoseconds < deadline {
            guard let r = receive(fd) else { continue }
            if r.type == 0, let h = byAddr[r.src] { alive.insert(h) }
        }
        return alive
    }
}
