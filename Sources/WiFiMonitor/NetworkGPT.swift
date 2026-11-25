import Foundation
import SQLite3

// MARK: - API key storage

/// Gemini API key: Keychain → GEMINI_API_KEY env var → one-time auto-import from the NSE project's .env file.
/// The key is never logged, displayed, or written anywhere except the Keychain.
enum NetworkGPTKey {
    static let account = "gemini-api-key"
    /// Set after the user resets the key: never auto-import from .env again (explicit import still possible).
    static let autoImportDisabledKey = "gptKeyAutoImportDisabled"
    private static let sourceKey = "gptKeySource"   // "user" | "env-import"

    enum Source { case user, envImport, environment, none }

    static var current: String? {
        if let k = Keychain.load(account: account), !k.isEmpty { return k }
        if let k = environmentKey { return k }
        if !UserDefaults.standard.bool(forKey: autoImportDisabledKey) {
            // One-time auto import; later resets disable it.
            UserDefaults.standard.set(true, forKey: autoImportDisabledKey)
            if importFromEnvFile(), let k = Keychain.load(account: account), !k.isEmpty { return k }
        }
        return nil
    }

    static var isSet: Bool { current != nil }

    private static var environmentKey: String? {
        let k = ProcessInfo.processInfo.environment["GEMINI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (k?.isEmpty == false) ? k : nil
    }

    static var source: Source {
        if Keychain.load(account: account)?.isEmpty == false {
            return UserDefaults.standard.string(forKey: sourceKey) == "env-import" ? .envImport : .user
        }
        return environmentKey != nil ? .environment : .none
    }

    /// Masked form for display: at most the first 4 characters, then dots. Never shows the full key.
    static func masked(_ k: String) -> String {
        String(k.prefix(min(4, max(0, k.count - 8)))) + String(repeating: "•", count: 12)
    }

    /// Saves a user-entered key in the Keychain.
    static func save(_ key: String) {
        save(key, source: "user")
    }

    private static func save(_ key: String, source: String) {
        Keychain.save(account: account, password: key.trimmingCharacters(in: .whitespacesAndNewlines))
        UserDefaults.standard.set(source, forKey: sourceKey)
    }

    /// Deletes the key from the Keychain and stops any future automatic .env import.
    static func reset() {
        Keychain.save(account: account, password: "")
        UserDefaults.standard.removeObject(forKey: sourceKey)
        UserDefaults.standard.set(true, forKey: autoImportDisabledKey)
    }

    static var envFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Projects/NSE/NSE-OptionChain/.env")
    }
    static var envFileExists: Bool { FileManager.default.fileExists(atPath: envFileURL.path) }

    /// Reads `GEMINI_API_KEY=...` from ~/Projects/NSE/NSE-OptionChain/.env and stores it in the Keychain.
    @discardableResult
    static func importFromEnvFile() -> Bool {
        guard let text = try? String(contentsOf: envFileURL, encoding: .utf8) else { return false }
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard line.hasPrefix("GEMINI_API_KEY"), let eq = line.firstIndex(of: "=") else { continue }
            guard line[..<eq].trimmingCharacters(in: .whitespaces) == "GEMINI_API_KEY" else { continue }
            var v = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let hash = v.range(of: " #"), !(v.hasPrefix("\"") || v.hasPrefix("'")) { v = String(v[..<hash.lowerBound]) }
            v = v.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t"))
            guard !v.isEmpty else { continue }
            save(v, source: "env-import")
            return true
        }
        return false
    }

    /// Validates a key by calling ListModels; returns the models usable with generateContent.
    static func validate(_ key: String) async throws -> [GPTModelInfo] {
        var all: [GPTModelInfo] = []
        var pageToken: String?
        repeat {
            var comps = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models")!
            var items = [URLQueryItem(name: "key", value: key), URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            comps.queryItems = items
            var req = URLRequest(url: comps.url!)
            req.timeoutInterval = 15
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            guard (200..<300).contains(code), let json else {
                let msg = ((json?["error"] as? [String: Any])?["message"] as? String) ?? HTTPURLResponse.localizedString(forStatusCode: code)
                if code == 400 || code == 401 || code == 403 { throw NetworkGPTError.auth(.gemini, msg) }
                throw NetworkGPTError.http(code, msg)
            }
            for m in json["models"] as? [[String: Any]] ?? [] {
                guard let methods = m["supportedGenerationMethods"] as? [String], methods.contains("generateContent"),
                      var id = m["name"] as? String else { continue }
                if id.hasPrefix("models/") { id = String(id.dropFirst(7)) }
                all.append(GPTModelInfo(id: id, displayName: (m["displayName"] as? String) ?? id))
            }
            pageToken = json["nextPageToken"] as? String
            if pageToken?.isEmpty == true { pageToken = nil }
        } while pageToken != nil
        return NetworkGPTModels.sorted(all)
    }
}

// MARK: - Models

struct GPTModelInfo: Codable, Hashable, Identifiable {
    var id: String
    var displayName: String
}

enum NetworkGPTModels {
    static let defaultsKey = "gptModel"
    static let cacheKey = "gptModelsCache"
    static let all = ["gemini-3.5-flash", "gemini-2.5-flash", "gemini-3.1-flash-lite"]
    static var primary: String {
        let m = (UserDefaults.standard.string(forKey: defaultsKey) ?? "").trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? all[0] : m
    }
    /// Primary (the user's choice) first, then the built-in fallback chain.
    static var chain: [String] { [primary] + all.filter { $0 != primary } }

    /// Models fetched from ListModels, cached in UserDefaults.
    static var cached: [GPTModelInfo] {
        get {
            guard let d = UserDefaults.standard.data(forKey: cacheKey) else { return [] }
            return (try? JSONDecoder().decode([GPTModelInfo].self, from: d)) ?? []
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: cacheKey) }
    }

    /// Gemini flash/pro first (newest version first), then other Gemini models, then everything else.
    static func sorted(_ list: [GPTModelInfo]) -> [GPTModelInfo] {
        func rank(_ id: String) -> Int {
            let s = id.lowercased()
            guard s.hasPrefix("gemini") else { return 3 }
            if s.contains("flash") || s.contains("pro") {
                return (s.contains("preview") || s.contains("exp") || s.contains("tts") || s.contains("image") || s.contains("live")) ? 1 : 0
            }
            return 2
        }
        return Array(Set(list)).sorted { a, b in
            let ra = rank(a.id), rb = rank(b.id)
            if ra != rb { return ra < rb }
            return a.id.compare(b.id, options: .numeric) == .orderedDescending
        }
    }
}

// MARK: - Chat model (persisted)

struct GPTMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant, error }
    var id = UUID()
    var role: Role
    var text: String
    var queries: [String] = []
    var model: String? = nil
    var date = Date()
}

enum NetworkGPTStore {
    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WiFiMonitor", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("networkgpt-chat.json")
    }
    static func load() -> [GPTMessage] {
        guard let d = try? Data(contentsOf: url) else { return [] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return (try? dec.decode([GPTMessage].self, from: d)) ?? []
    }
    static func save(_ msgs: [GPTMessage]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(Array(msgs.suffix(50))) { try? d.write(to: url, options: .atomic) }
    }
}

// MARK: - Errors

enum NetworkGPTError: LocalizedError {
    case noKey(GPTProvider)
    case auth(GPTProvider, String)
    case http(Int, String)
    case allModelsFailed(GPTProvider, String)
    case badResponse(String)
    case tooManyRounds

    var errorDescription: String? {
        switch self {
        case .noKey(let p): return "No \(p.shortName) API key. Add one with the gear button or in Settings → NetworkGPT."
        case .auth(let p, let m): return "\(p.shortName) rejected the API key: \(m)"
        case .http(let c, let m): return c == 0 ? m : "AI provider error \(c): \(m)"
        case .allModelsFailed(let p, let m): return "All \(p.shortName) models are unavailable right now. \(m)"
        case .badResponse(let m): return "Unexpected response from the AI: \(m)"
        case .tooManyRounds: return "The assistant needed too many steps to answer. Try a more specific question."
        }
    }
}

// MARK: - Engine

/// Progress reported to the UI while a question is being answered.
struct GPTStep: Equatable {
    var text: String
    var sql: String?
}

struct GPTAnswer {
    var text: String
    var queries: [String]
    var model: String
}

final class NetworkGPTEngine {
    static let maxRounds = 6

    /// Answers `question` given the earlier conversation. `onStep` is called on the main actor.
    func ask(history: [GPTMessage], question: String,
             onStep: @escaping @MainActor (GPTStep) -> Void) async throws -> GPTAnswer {
        let provider = GPTProvider.active
        guard let key = GPTKeys.current(provider) else { throw NetworkGPTError.noKey(provider) }
        let system = await Self.systemPrompt()
        await onStep(GPTStep(text: "Thinking…"))
        switch provider.wire {
        case .anthropic: return try await askAnthropic(provider, key: key, history: history, question: question, system: system, onStep: onStep)
        case .openai: return try await askOpenAI(provider, key: key, history: history, question: question, system: system, onStep: onStep)
        case .gemini: return try await askGemini(key: key, history: history, question: question, system: system, onStep: onStep)
        }
    }

    private func askGemini(key: String, history: [GPTMessage], question: String, system: String,
                           onStep: @escaping @MainActor (GPTStep) -> Void) async throws -> GPTAnswer {
        var contents: [[String: Any]] = []
        for m in history.suffix(20) where m.role != .error && !m.text.isEmpty {
            contents.append(["role": m.role == .user ? "user" : "model", "parts": [["text": m.text]]])
        }
        contents.append(["role": "user", "parts": [["text": question]]])

        var queries: [String] = []
        let chain = GPTProvider.gemini.modelChain
        var modelIndex = 0
        var locked = false

        for _ in 0..<Self.maxRounds {
            try Task.checkCancellation()
            let body: [String: Any] = [
                "systemInstruction": ["parts": [["text": system]]],
                "contents": contents,
                "tools": [["functionDeclarations": Self.toolDeclarations]],
                "generationConfig": ["temperature": 0.2],
            ]
            // Call with model fallback.
            var response: [String: Any]?
            var lastError = ""
            while modelIndex < chain.count {
                let model = chain[modelIndex]
                let timeout: TimeInterval = (!locked && modelIndex == 0) ? 8 : 90
                do {
                    response = try await Self.generate(model: model, key: key, body: body, timeout: timeout)
                    locked = true
                    break
                } catch let e as RetryableError {
                    lastError = e.message
                    modelIndex += 1
                    if modelIndex < chain.count { await onStep(GPTStep(text: "Switching to \(chain[modelIndex])…")) }
                }
            }
            guard let response else { throw NetworkGPTError.allModelsFailed(.gemini, lastError) }
            let model = chain[modelIndex]

            guard let cand = (response["candidates"] as? [[String: Any]])?.first,
                  let content = cand["content"] as? [String: Any] else {
                if let fb = response["promptFeedback"] as? [String: Any], let r = fb["blockReason"] as? String {
                    throw NetworkGPTError.badResponse("blocked (\(r))")
                }
                let reason = ((response["candidates"] as? [[String: Any]])?.first?["finishReason"] as? String) ?? "no content"
                throw NetworkGPTError.badResponse(reason)
            }
            let parts = content["parts"] as? [[String: Any]] ?? []
            let calls = parts.compactMap { $0["functionCall"] as? [String: Any] }

            if calls.isEmpty {
                let text = parts.filter { ($0["thought"] as? Bool) != true }
                    .compactMap { $0["text"] as? String }.joined()
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty {
                    let reason = (cand["finishReason"] as? String) ?? "empty answer"
                    throw NetworkGPTError.badResponse(reason)
                }
                return GPTAnswer(text: text, queries: queries, model: model)
            }

            // Echo the model turn back verbatim (keeps thought signatures intact), then answer each call.
            var modelTurn = content
            modelTurn["role"] = "model"
            contents.append(modelTurn)
            var responses: [[String: Any]] = []
            for call in calls {
                try Task.checkCancellation()
                let name = call["name"] as? String ?? ""
                let result = await runTool(name, call["args"] as? [String: Any] ?? [:], queries: &queries, onStep: onStep)
                var fr: [String: Any] = ["name": name, "response": ["result": result]]
                if let id = call["id"] { fr["id"] = id }
                responses.append(["functionResponse": fr])
            }
            contents.append(["role": "user", "parts": responses])
            await onStep(GPTStep(text: "Writing answer…"))
        }
        throw NetworkGPTError.tooManyRounds
    }

    /// Runs one tool call (shared by every provider) and reports progress.
    func runTool(_ name: String, _ args: [String: Any], queries: inout [String],
                 onStep: @escaping @MainActor (GPTStep) -> Void) async -> Any {
        switch name {
        case "run_sql":
            let sql = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            queries.append(sql)
            await onStep(GPTStep(text: "Querying database…", sql: sql))
            return await Blocking.run { SQLTool.run(sql) }
        case "get_schema":
            await onStep(GPTStep(text: "Reading database schema…"))
            return await Blocking.run { ["schema": SchemaInfo.text()] }
        case "get_live_status":
            await onStep(GPTStep(text: "Checking live status…"))
            return await Self.liveStatus()
        default:
            return ["error": "Unknown tool \(name)"]
        }
    }

    // MARK: HTTP

    private struct RetryableError: Error { let message: String }

    private static func generate(model: String, key: String, body: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        var comps = URLComponents(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        comps.queryItems = [URLQueryItem(name: "key", value: key)]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let u = error as? URLError {
                if u.code == .cancelled { throw CancellationError() }
                if u.code == .notConnectedToInternet { throw NetworkGPTError.http(0, "No internet connection.") }
                throw RetryableError(message: "\(model): \(u.code == .timedOut ? "timed out" : u.localizedDescription)")
            }
            throw RetryableError(message: "\(model): \(error.localizedDescription)")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let errObj = json?["error"] as? [String: Any]
        let message = (errObj?["message"] as? String) ?? HTTPURLResponse.localizedString(forStatusCode: code)
        let status = (errObj?["status"] as? String) ?? ""

        if (200..<300).contains(code), let json { return json }
        let lower = message.lowercased()
        if code == 401 || code == 403 || status == "PERMISSION_DENIED" || status == "UNAUTHENTICATED"
            || lower.contains("api key") || lower.contains("api_key") {
            throw NetworkGPTError.auth(.gemini, message)
        }
        if [404, 429, 500, 502, 503, 504].contains(code) || lower.contains("overloaded") || status == "UNAVAILABLE" {
            throw RetryableError(message: "\(model): \(message)")
        }
        throw NetworkGPTError.http(code, message)
    }

    // MARK: Tools

    static let toolDeclarations: [[String: Any]] = [
        [
            "name": "run_sql",
            "description": "Run ONE read-only SQLite SELECT (or WITH … SELECT) query against the Wi-Fi Monitor database and return up to 200 rows as JSON objects. Timestamps are unix epoch seconds (REAL); use datetime(ts,'unixepoch','localtime') for display and strftime('%s', …, 'utc') / unixepoch() for filtering. Aggregate in SQL instead of fetching raw rows.",
            "parameters": [
                "type": "OBJECT",
                "properties": ["query": ["type": "STRING", "description": "A single SELECT or WITH statement."]],
                "required": ["query"],
            ],
        ],
        [
            "name": "get_schema",
            "description": "Return the CREATE TABLE statements of every table plus a hint about what each table and its units mean.",
            "parameters": ["type": "OBJECT", "properties": [String: Any]()],
        ],
        [
            "name": "get_live_status",
            "description": "Return the current live state: Wi-Fi network, signal, noise, channel/band, link rate, router and internet latency, packet loss, internet up/down, public IP/ISP, VPN, and router stats if a router is configured.",
            "parameters": ["type": "OBJECT", "properties": [String: Any]()],
        ],
    ]

    @MainActor
    static func liveStatus() -> [String: Any] {
        let m = Monitor.shared
        var d: [String: Any] = ["now_local": localNow(), "internet_up": m.internetUp]
        if let s = m.current {
            var w: [String: Any] = ["connected": s.connected, "sample_time_local": localTime(s.ts)]
            func put(_ k: String, _ v: Any?) { if let v { w[k] = v } }
            put("interface", s.interface); put("ssid", s.ssid); put("bssid", s.bssid)
            put("rssi_dbm", s.rssi); put("noise_dbm", s.noise); put("snr_db", s.snr)
            put("channel", s.channel); put("band", s.band); put("channel_width", s.width); put("phy_mode", s.phy)
            put("link_rate_mbps", s.txRate); put("security", s.security)
            put("ip", s.ip); put("gateway", s.gateway); put("dns", s.dns)
            put("router_latency_ms", s.gwLatency.map(round1)); put("internet_latency_ms", s.inetLatency.map(round1))
            put("dns_latency_ms", s.dnsLatency.map(round1)); put("packet_loss_pct", s.loss.map { round1($0 * 100) })
            put("download_now_bps", s.rxBps.map(round1)); put("upload_now_bps", s.txBps.map(round1))
            put("primary_link", s.link); put("vpn", s.vpn)
            d["wifi"] = w
        } else {
            d["wifi"] = "no sample collected yet"
        }
        if let i = m.identity {
            var id: [String: Any] = ["captive_portal": i.captive]
            if let v = i.publicIP { id["public_ip"] = v }
            if let v = i.isp { id["isp"] = v }
            if let v = i.asn { id["asn"] = v }
            d["internet_identity"] = id
        }
        d["session_downloaded_bytes"] = m.sessionRx
        d["session_uploaded_bytes"] = m.sessionTx
        d["lan_devices_known"] = m.devices.count
        if let r = m.router {
            var rd: [String: Any] = ["clients": r.clients.count, "poll_time_local": localTime(r.ts)]
            func put(_ k: String, _ v: Any?) { if let v { rd[k] = v } }
            put("model", r.model); put("firmware", r.firmware); put("uptime_seconds", r.uptime)
            put("external_ip", r.externalIP); put("wan_link_status", r.linkStatus)
            put("wan_link_down_bps", r.linkDown); put("wan_link_up_bps", r.linkUp)
            put("cpu_pct", r.cpuLoad.map { round1($0 * 100) }); put("mem_pct", r.memUsed.map { round1($0 * 100) })
            put("wan_download_now_bps", m.routerWanRxBps.map(round1)); put("wan_upload_now_bps", m.routerWanTxBps.map(round1))
            d["router"] = rd
        } else if let e = m.routerError {
            d["router_error"] = e
        }
        if let st = m.lastSpeedTest {
            var sd: [String: Any] = ["time_local": localTime(st.ts)]
            if let v = st.dlMbps { sd["download_mbps"] = v }
            if let v = st.ulMbps { sd["upload_mbps"] = v }
            d["last_speed_test"] = sd
        }
        if let c = m.capStatus {
            d["data_cap"] = ["used_bytes": c.used, "cap_bytes": c.cap, "period_start": localTime(c.start), "period_end": localTime(c.end)]
        }
        let ev = m.events.prefix(8).map { "\(localTime($0.ts)) \($0.type.rawValue): \($0.message)" }
        if !ev.isEmpty { d["recent_events"] = Array(ev) }
        return d
    }

    // MARK: Prompt

    static func systemPrompt() async -> String {
        let schema = await Blocking.run { SchemaInfo.text() }
        let tz = TimeZone.current
        return """
        You are NetworkGPT, a friendly assistant inside the "WiFi Monitor" Mac app. You answer questions about the user's \
        Wi-Fi, internet connection, router and the devices on their home network, using ONLY the app's local SQLite database \
        and live status via the tools you have.

        Current local date/time: \(localNow()) (timezone \(tz.identifier), UTC offset \(tz.secondsFromGMT() / 3600)h). \
        Current unix time: \(Int(Date().timeIntervalSince1970)).

        How to work:
        - Use run_sql to look things up. Aggregate in SQL (SUM/AVG/COUNT/GROUP BY) rather than fetching raw rows. Results are capped at 200 rows.
        - All `ts`/time columns are unix epoch seconds (REAL). For local-time boundaries use e.g. \
        ts >= strftime('%s','now','localtime','start of day','utc') for "today", \
        strftime('%s','now','localtime','start of day','-1 day','+17 hours','utc') for 5 PM yesterday, \
        ts >= strftime('%s','now','-7 days') for "the last week", and datetime(ts,'unixepoch','localtime') to display times. \
        "Yesterday evening" ≈ 17:00–23:00 local time yesterday. (strftime returns text: wrap it in CAST(… AS INTEGER) \
        when not comparing directly against a ts column.)
        - Group by local hour/day with strftime('%Y-%m-%d %H:00', ts, 'unixepoch', 'localtime').
        - Use get_live_status for questions about right now.
        - You may run several queries; if a query errors, fix it and retry.

        How to answer:
        - The reader is not technical. Be short and clear: lead with the direct answer, then 2–5 supporting facts.
        - Use markdown: **bold**, bullet lists, and small tables when comparing items. No code blocks unless asked.
        - Convert bytes to KB/MB/GB (1 GB = 1,000,000,000 bytes), bits-per-second to Mbps, epoch times to local time (e.g. "Tue 7:42 PM").
        - Explain jargon briefly (e.g. "signal −72 dBm (weak)": > −60 good, −60…−70 fair, < −70 weak; latency < 30 ms good, > 100 ms bad).
        - Never invent numbers. If the data is missing or empty for the period asked, say so plainly and suggest what would collect it \
        (e.g. configure a router in Settings for per-device usage).
        - Do not mention SQL, table names or tool names in the answer unless the user asks.

        Database schema:
        \(schema)
        """
    }

    static func localNow() -> String { localTime(Date()) }
    static func localTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }
    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }
}

// MARK: - Schema

enum SchemaInfo {
    static let hints: [String: String] = [
        "samples": "This Mac's connection, one row every few seconds. connected 0/1; ssid/bssid (network / access point); rssi & noise in dBm, snr in dB; channel, band ('2.4 GHz','5 GHz','6 GHz'), width, phy; tx_rate = Wi-Fi link rate in Mbps; gw_latency = ping to router (ms), inet_latency = avg ping to internet hosts (ms; NULL while connected means internet unreachable), dns_latency ms; loss = packet-loss fraction 0..1; rx_bps/tx_bps = throughput in BITS per second; rx_bytes/tx_bytes = bytes downloaded/uploaded on Wi-Fi since the previous sample (SUM them for totals); eth_rx_bytes/eth_tx_bytes same for wired; link = 'Wi-Fi'/'Ethernet'/'VPN'/'Other'; vpn = VPN name.",
        "scans": "Nearby Wi-Fi access points seen in periodic scans (other networks/neighbours). rssi/noise dBm, channel, band, width.",
        "events": "Timeline of notable events. type values: started, connected, disconnected, roam, ssidChange, channelChange, ipChange, internetDown, internetUp, lowSignal, signalRecovered, highLatency, latencyRecovered, newDevice, speedTest, powerChange, targetDown, targetUp, certExpiring, dataCap, routerReboot, untrustedDevice, captivePortal, publicIPChange, ipv6Down, ipv6Up, vpnUp, vpnDown, linkChange, stickyClient, pathSlow. An internet outage = an 'internetDown' event (ended by the next 'internetUp'); a Wi-Fi drop = 'disconnected'.",
        "speedtests": "Speed tests. dl_mbps/ul_mbps in Mbps; responsiveness in RPM (round-trips per minute, higher is better); base_rtt and loaded_latency in ms; kind = 'manual' / 'scheduled' / etc.",
        "devices": "Devices discovered on the local network (LAN). Best display name: COALESCE(nickname, friendly_name, mdns_name, netbios_name, hostname, vendor, mac). vendor = manufacturer; kind = device type; first_seen/last_seen epoch; trusted 0/1; open_ports text.",
        "app_usage": "Per-app traffic on THIS Mac. rx_bytes (download) / tx_bytes (upload) are bytes since the previous collection (SUM them). link = 'Wi-Fi' or 'Ethernet'.",
        "app_connections": "Per-app network connections on this Mac (remote address/host/port) with bytes.",
        "router_stats": "Router polls (whole household). wan_rx_bytes/wan_tx_bytes = bytes downloaded/uploaded by the whole network since the previous poll (SUM them); wan_rx_bps/wan_tx_bps BITS per second; uptime seconds; link_down/link_up = WAN line rate bits/s; cpu & mem fractions 0..1; clients = connected client count. Empty if no router is configured.",
        "router_clients": "Clients the router reports (one row per MAC, latest values). name, ip, signal dBm, iface, ap (mesh node). rx_total = client UPLOAD counter, tx_total = client DOWNLOAD counter (cumulative bytes, may reset).",
        "router_client_usage": "Per-device data usage from the router: down_bytes/up_bytes since the previous poll for each mac (SUM per mac over a period). Join router_clients/devices on mac for names. Use this for 'which device used the most data'.",
        "device_sessions": "When each LAN device (mac) was online: intervals [start, end] in epoch seconds.",
        "targets": "User-defined watch targets (websites/hosts) to check. kind e.g. http/ping/tcp; interval seconds.",
        "target_results": "Results of watch-target checks: ok 0/1, latency ms, status (HTTP code), detail, cert_expiry epoch.",
        "traces": "Traceroutes to the internet: local_ms (home network part), isp_ms (ISP part), total_ms; reached 0/1.",
        "trace_hops": "Hops of each trace (trace_id → traces.id): rtt ms, owner/asn, segment 'Home'/'ISP'/'Internet'.",
        "ipv6_samples": "IPv6 checks: has_v6 0/1, latency ms, loss fraction 0..1, dns_latency ms, v4_latency ms (IPv4 for comparison).",
        "net_identity": "History of the public IP address / ISP name / ASN, captive portal flag, link type and VPN.",
    ]

    /// CREATE TABLE statements + hints. Cached after first read.
    private static var cache: String?
    private static let lock = NSLock()

    static func text() -> String {
        lock.lock(); defer { lock.unlock() }
        if let cache { return cache }
        let rows = (try? SQLTool.select("SELECT name, sql FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name", limit: 500).rows) ?? []
        var out: [String] = []
        for r in rows {
            guard let name = r["name"] as? String, let sql = r["sql"] as? String else { continue }
            var s = sql.replacingOccurrences(of: "\n", with: " ")
            while s.contains("  ") { s = s.replacingOccurrences(of: "  ", with: " ") }
            out.append("-- \(name): \(hints[name] ?? "")\n\(s);")
        }
        let t = out.joined(separator: "\n")
        if !t.isEmpty { cache = t }
        return t
    }
}

// MARK: - Read-only SQL

enum SQLTool {
    static let maxRows = 200
    static let maxCell = 300
    static let timeLimit: TimeInterval = 8

    struct Result { var columns: [String]; var rows: [[String: Any]]; var truncated: Bool }
    struct Failure: Error { let message: String }

    private static let forbidden = ["PRAGMA", "ATTACH", "DETACH", "INSERT", "UPDATE", "DELETE", "DROP", "ALTER",
                                    "CREATE", "VACUUM", "REINDEX", "ANALYZE", "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "RELEASE"]

    /// Validates and runs a model-supplied query; returns a JSON-friendly dictionary.
    static func run(_ sql: String) -> [String: Any] {
        if let problem = validate(sql) { return ["error": problem] }
        do {
            let r = try select(sql, limit: maxRows)
            var d: [String: Any] = ["row_count": r.rows.count, "rows": r.rows]
            if r.truncated { d["note"] = "Only the first \(maxRows) rows are shown; aggregate or add LIMIT." }
            return d
        } catch let f as Failure {
            return ["error": f.message]
        } catch {
            return ["error": error.localizedDescription]
        }
    }

    static func validate(_ sql: String) -> String? {
        var s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix(";") { s = String(s.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !s.isEmpty else { return "Empty query." }
        let stripped = stripLiteralsAndComments(s)
        let upper = stripped.uppercased()
        guard upper.hasPrefix("SELECT") || upper.hasPrefix("WITH") else { return "Only SELECT or WITH queries are allowed." }
        if stripped.contains(";") { return "Only one statement is allowed." }
        let words = Set(upper.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted))
        if let bad = forbidden.first(where: words.contains) { return "\(bad) is not allowed (read-only access)." }
        // REPLACE is fine as the replace() string function, not as a statement.
        if upper.range(of: #"\bREPLACE\s+INTO\b|\bOR\s+REPLACE\b"#, options: .regularExpression) != nil {
            return "REPLACE statements are not allowed (read-only access)."
        }
        return nil
    }

    /// Removes quoted strings / identifiers and comments so keyword checks don't trip on data.
    private static func stripLiteralsAndComments(_ s: String) -> String {
        var out = ""
        var it = Array(s)
        var i = 0
        while i < it.count {
            let c = it[i]
            if c == "'" || c == "\"" || c == "`" {
                let q = c; i += 1
                while i < it.count {
                    if it[i] == q { if i + 1 < it.count && it[i + 1] == q { i += 2; continue }; break }
                    i += 1
                }
                out.append(" x "); i += 1
            } else if c == "-" && i + 1 < it.count && it[i + 1] == "-" {
                while i < it.count && it[i] != "\n" { i += 1 }
            } else if c == "/" && i + 1 < it.count && it[i + 1] == "*" {
                i += 2
                while i + 1 < it.count && !(it[i] == "*" && it[i + 1] == "/") { i += 1 }
                i += 2
            } else { out.append(c); i += 1 }
        }
        it = []
        return out
    }

    /// Runs a query on a separate READ-ONLY connection (never touches the app's writer connection).
    static func select(_ sql: String, limit: Int) throws -> Result {
        var db: OpaquePointer?
        guard sqlite3_open_v2(Database.shared.url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            throw Failure(message: "Cannot open the database.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)
        sqlite3_exec(db, "PRAGMA query_only=1", nil, nil, nil)

        // Abort runaway queries.
        let deadline = Box(Date().addingTimeInterval(timeLimit))
        let ctx = Unmanaged.passRetained(deadline).toOpaque()
        defer { Unmanaged<Box>.fromOpaque(ctx).release() }
        sqlite3_progress_handler(db, 20_000, { p in
            guard let p else { return 0 }
            return Date() > Unmanaged<Box>.fromOpaque(p).takeUnretainedValue().deadline ? 1 : 0
        }, ctx)

        var stmt: OpaquePointer?
        var tail: UnsafePointer<CChar>?
        let rc = sql.withCString { sqlite3_prepare_v2(db, $0, -1, &stmt, &tail) }
        guard rc == SQLITE_OK, let stmt else {
            throw Failure(message: "SQL error: " + String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        if let tail, !String(cString: tail).trimmingCharacters(in: CharacterSet(charactersIn: "; \n\t\r")).isEmpty {
            throw Failure(message: "Only one statement is allowed.")
        }
        guard sqlite3_stmt_readonly(stmt) != 0 else { throw Failure(message: "Only read-only queries are allowed.") }

        let n = sqlite3_column_count(stmt)
        let cols = (0..<n).map { String(cString: sqlite3_column_name(stmt, $0)) }
        var rows: [[String: Any]] = []
        var truncated = false
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                if step == SQLITE_INTERRUPT { throw Failure(message: "Query took too long (>\(Int(timeLimit))s); narrow the time range or aggregate.") }
                throw Failure(message: "SQL error: " + String(cString: sqlite3_errmsg(db)))
            }
            if rows.count >= limit { truncated = true; break }
            var row: [String: Any] = [:]
            for i in 0..<n {
                let name = cols[Int(i)]
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: row[name] = sqlite3_column_int64(stmt, i)
                case SQLITE_FLOAT:
                    let d = sqlite3_column_double(stmt, i)
                    row[name] = d.isFinite ? d : NSNull()
                case SQLITE_TEXT:
                    let s = String(cString: sqlite3_column_text(stmt, i))
                    row[name] = s.count > maxCell ? String(s.prefix(maxCell)) + "…" : s
                case SQLITE_BLOB: row[name] = "<blob \(sqlite3_column_bytes(stmt, i)) bytes>"
                default: row[name] = NSNull()
                }
            }
            rows.append(row)
        }
        return Result(columns: cols, rows: rows, truncated: truncated)
    }

    private final class Box { let deadline: Date; init(_ d: Date) { deadline = d } }
}
