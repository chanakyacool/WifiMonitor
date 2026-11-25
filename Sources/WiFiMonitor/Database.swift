import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A single result row from a query.
struct Row {
    let values: [String: Any]

    func double(_ k: String) -> Double? {
        if let d = values[k] as? Double { return d }
        if let i = values[k] as? Int64 { return Double(i) }
        return nil
    }
    func int(_ k: String) -> Int? {
        if let i = values[k] as? Int64 { return Int(i) }
        if let d = values[k] as? Double { return Int(d) }
        return nil
    }
    func string(_ k: String) -> String? {
        if let s = values[k] as? String { return s }
        if let i = values[k] as? Int64 { return String(i) }
        return nil
    }
    func date(_ k: String) -> Date? { double(k).map { Date(timeIntervalSince1970: $0) } }
}

/// Thin, thread-safe SQLite wrapper. All access is serialized on a private queue.
final class Database {
    static let shared = Database()

    let url: URL
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "wifimonitor.database")

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WiFiMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("wifi.sqlite")
        if sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            fatalError("Cannot open database at \(url.path)")
        }
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA foreign_keys=ON;")
        migrate()
    }

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS samples(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL,
            connected INTEGER NOT NULL,
            power_on INTEGER,
            interface TEXT, ssid TEXT, bssid TEXT,
            rssi INTEGER, noise INTEGER, snr INTEGER,
            channel INTEGER, band TEXT, width TEXT, phy TEXT,
            tx_rate REAL, tx_power INTEGER,
            security TEXT, country TEXT, mac TEXT,
            ip TEXT, gateway TEXT, dns TEXT,
            gw_latency REAL, inet_latency REAL, dns_latency REAL, loss REAL,
            rx_bps REAL, tx_bps REAL,
            rx_bytes INTEGER, tx_bytes INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_samples_ts ON samples(ts);
        CREATE INDEX IF NOT EXISTS idx_samples_ssid ON samples(ssid, ts);

        CREATE TABLE IF NOT EXISTS scans(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL,
            ssid TEXT, bssid TEXT, rssi INTEGER, noise INTEGER,
            channel INTEGER, band TEXT, width TEXT, security TEXT,
            beacon_interval INTEGER, country TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_scans_ts ON scans(ts);

        CREATE TABLE IF NOT EXISTS events(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL, type TEXT NOT NULL, message TEXT NOT NULL,
            ssid TEXT, bssid TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_events_ts ON events(ts);

        CREATE TABLE IF NOT EXISTS speedtests(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL, dl_mbps REAL, ul_mbps REAL,
            responsiveness REAL, base_rtt REAL,
            interface TEXT, ssid TEXT, bssid TEXT, band TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_speed_ts ON speedtests(ts);

        CREATE TABLE IF NOT EXISTS devices(
            mac TEXT PRIMARY KEY,
            ip TEXT, hostname TEXT, interface TEXT, ssid TEXT,
            first_seen REAL, last_seen REAL
        );

        CREATE TABLE IF NOT EXISTS app_usage(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL, app TEXT NOT NULL,
            rx_bytes INTEGER NOT NULL, tx_bytes INTEGER NOT NULL,
            ssid TEXT, bssid TEXT, band TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_app_usage_ts ON app_usage(ts);

        CREATE TABLE IF NOT EXISTS router_stats(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL,
            wan_rx_bytes INTEGER, wan_tx_bytes INTEGER, wan_rx_bps REAL, wan_tx_bps REAL,
            uptime REAL, external_ip TEXT, link_down REAL, link_up REAL, link_status TEXT,
            cpu REAL, mem REAL, clients INTEGER
        );
        CREATE INDEX IF NOT EXISTS idx_router_stats_ts ON router_stats(ts);

        CREATE TABLE IF NOT EXISTS router_clients(
            mac TEXT PRIMARY KEY, ip TEXT, name TEXT, signal INTEGER, iface TEXT,
            rx_total INTEGER, tx_total INTEGER, first_seen REAL, last_seen REAL
        );

        CREATE TABLE IF NOT EXISTS router_client_usage(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL, mac TEXT NOT NULL,
            down_bytes INTEGER NOT NULL, up_bytes INTEGER NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_rcu_ts ON router_client_usage(ts);

        CREATE TABLE IF NOT EXISTS targets(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL, kind TEXT NOT NULL, target TEXT NOT NULL,
            interval REAL NOT NULL DEFAULT 60, enabled INTEGER NOT NULL DEFAULT 1, created REAL
        );
        CREATE TABLE IF NOT EXISTS target_results(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts REAL NOT NULL, target_id INTEGER NOT NULL,
            ok INTEGER NOT NULL, latency REAL, status INTEGER, detail TEXT, cert_expiry REAL
        );
        CREATE INDEX IF NOT EXISTS idx_target_results ON target_results(target_id, ts);
        CREATE INDEX IF NOT EXISTS idx_target_results_ts ON target_results(ts);
        """)
        // Columns added after the first release.
        for (col, type) in [("vendor", "TEXT"), ("mdns_name", "TEXT"), ("netbios_name", "TEXT"), ("friendly_name", "TEXT"),
                            ("model", "TEXT"), ("kind", "TEXT"), ("nickname", "TEXT"), ("names_checked", "REAL"),
                            ("tag", "TEXT"), ("trusted", "INTEGER"), ("open_ports", "TEXT"), ("ports_scanned", "REAL")] {
            addColumnIfMissing("devices", col, type)
        }
        for (col, type) in [("primary_iface", "TEXT"), ("link", "TEXT"), ("vpn", "TEXT"), ("eth_rx_bytes", "INTEGER"), ("eth_tx_bytes", "INTEGER")] {
            addColumnIfMissing("samples", col, type)
        }
        addColumnIfMissing("router_clients", "ap", "TEXT")
        addColumnIfMissing("app_usage", "link", "TEXT")
        addColumnIfMissing("speedtests", "loaded_latency", "REAL")
        addColumnIfMissing("speedtests", "kind", "TEXT")

        exec("""
        CREATE TABLE IF NOT EXISTS device_sessions(
            id INTEGER PRIMARY KEY AUTOINCREMENT, mac TEXT NOT NULL, start REAL NOT NULL, end REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_dev_sessions_mac ON device_sessions(mac, end);
        CREATE INDEX IF NOT EXISTS idx_dev_sessions_end ON device_sessions(end);

        CREATE TABLE IF NOT EXISTS traces(
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, target TEXT NOT NULL, hops INTEGER,
            reached INTEGER, local_ms REAL, isp_ms REAL, total_ms REAL, ssid TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_traces_ts ON traces(ts);
        CREATE TABLE IF NOT EXISTS trace_hops(
            trace_id INTEGER NOT NULL, hop INTEGER NOT NULL, ip TEXT, rtt REAL, asn INTEGER, owner TEXT, segment TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_trace_hops ON trace_hops(trace_id);

        CREATE TABLE IF NOT EXISTS ipv6_samples(
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, has_v6 INTEGER NOT NULL, address TEXT,
            latency REAL, loss REAL, dns_latency REAL, v4_latency REAL, ssid TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_ipv6_ts ON ipv6_samples(ts);

        CREATE TABLE IF NOT EXISTS net_identity(
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, public_ip TEXT, asn INTEGER, isp TEXT,
            captive INTEGER, ssid TEXT, link TEXT, vpn TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_net_identity_ts ON net_identity(ts);

        CREATE TABLE IF NOT EXISTS app_connections(
            id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, app TEXT NOT NULL, proto TEXT,
            remote TEXT, port INTEGER, host TEXT, rx_bytes INTEGER, tx_bytes INTEGER, link TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_app_conn_ts ON app_connections(ts);
        CREATE INDEX IF NOT EXISTS idx_app_conn_app ON app_connections(app, ts);
        """)
    }

    private func addColumnIfMissing(_ table: String, _ column: String, _ type: String) {
        let existing = query("PRAGMA table_info(\(table))").compactMap { $0.string("name") }
        if !existing.contains(column) { exec("ALTER TABLE \(table) ADD COLUMN \(column) \(type)") }
    }

    func exec(_ sql: String) {
        queue.sync {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK, let err {
                NSLog("SQLite exec error: \(String(cString: err))")
                sqlite3_free(err)
            }
        }
    }

    @discardableResult
    func run(_ sql: String, _ params: [Any?] = []) -> Int64 {
        queue.sync {
            guard let stmt = prepare(sql, params) else { return 0 }
            defer { sqlite3_finalize(stmt) }
            if sqlite3_step(stmt) != SQLITE_DONE { logError(sql) }
            return sqlite3_last_insert_rowid(db)
        }
    }

    /// Runs the same statement for many parameter sets inside one transaction.
    func runMany(_ sql: String, _ rows: [[Any?]]) {
        guard !rows.isEmpty else { return }
        queue.sync {
            sqlite3_exec(db, "BEGIN", nil, nil, nil)
            for params in rows {
                if let stmt = prepare(sql, params) {
                    if sqlite3_step(stmt) != SQLITE_DONE { logError(sql) }
                    sqlite3_finalize(stmt)
                }
            }
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
    }

    func query(_ sql: String, _ params: [Any?] = []) -> [Row] {
        queue.sync {
            guard let stmt = prepare(sql, params) else { return [] }
            defer { sqlite3_finalize(stmt) }
            var rows: [Row] = []
            let count = sqlite3_column_count(stmt)
            while sqlite3_step(stmt) == SQLITE_ROW {
                var dict: [String: Any] = [:]
                for i in 0..<count {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER: dict[name] = sqlite3_column_int64(stmt, i)
                    case SQLITE_FLOAT: dict[name] = sqlite3_column_double(stmt, i)
                    case SQLITE_TEXT: dict[name] = String(cString: sqlite3_column_text(stmt, i))
                    default: break
                    }
                }
                rows.append(Row(values: dict))
            }
            return rows
        }
    }

    func scalar(_ sql: String, _ params: [Any?] = []) -> Double? {
        guard let row = query(sql, params).first, let v = row.values.values.first else { return nil }
        if let d = v as? Double { return d }
        if let i = v as? Int64 { return Double(i) }
        return nil
    }

    var fileSize: Int64 {
        let paths = [url.path, url.path + "-wal"]
        return paths.reduce(0) { acc, p in
            acc + ((try? FileManager.default.attributesOfItem(atPath: p)[.size] as? Int64) ?? 0)
        }
    }

    // MARK: - Private

    private func prepare(_ sql: String, _ params: [Any?]) -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            logError(sql)
            return nil
        }
        for (idx, p) in params.enumerated() {
            let i = Int32(idx + 1)
            guard let v = p else { sqlite3_bind_null(stmt, i); continue }
            switch v {
            case let x as Int: sqlite3_bind_int64(stmt, i, Int64(x))
            case let x as Int64: sqlite3_bind_int64(stmt, i, x)
            case let x as UInt64: sqlite3_bind_int64(stmt, i, Int64(clamping: x))
            case let x as Int32: sqlite3_bind_int64(stmt, i, Int64(x))
            case let x as Double: sqlite3_bind_double(stmt, i, x)
            case let x as Bool: sqlite3_bind_int64(stmt, i, x ? 1 : 0)
            case let x as Date: sqlite3_bind_double(stmt, i, x.timeIntervalSince1970)
            case let x as String: sqlite3_bind_text(stmt, i, x, -1, SQLITE_TRANSIENT)
            default: sqlite3_bind_text(stmt, i, String(describing: v), -1, SQLITE_TRANSIENT)
            }
        }
        return stmt
    }

    private func logError(_ sql: String) {
        NSLog("SQLite error: \(String(cString: sqlite3_errmsg(db))) — \(sql.prefix(120))")
    }
}
