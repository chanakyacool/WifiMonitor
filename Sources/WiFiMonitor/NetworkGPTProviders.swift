import Foundation

// MARK: - Providers

/// AI providers NetworkGPT can talk to. Three wire formats: Gemini, Anthropic Messages, and OpenAI chat-completions
/// (which OpenAI, OpenRouter, Groq, DeepSeek, Mistral, xAI and local Ollama all speak).
enum GPTProvider: String, CaseIterable, Identifiable, Codable {
    case gemini, openai, anthropic, openrouter, groq, deepseek, mistral, xai, ollama

    enum Wire { case gemini, anthropic, openai }

    var id: String { rawValue }
    static let defaultsKey = "gptProvider"
    static var active: GPTProvider {
        GPTProvider(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .gemini
    }

    var title: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .openai: return "OpenAI (ChatGPT)"
        case .anthropic: return "Anthropic Claude"
        case .openrouter: return "OpenRouter (hundreds of models)"
        case .groq: return "Groq"
        case .deepseek: return "DeepSeek"
        case .mistral: return "Mistral AI"
        case .xai: return "xAI Grok"
        case .ollama: return "Ollama (local, on this Mac)"
        }
    }
    var shortName: String {
        switch self {
        case .gemini: return "Gemini"
        case .openai: return "OpenAI"
        case .anthropic: return "Claude"
        case .openrouter: return "OpenRouter"
        case .groq: return "Groq"
        case .deepseek: return "DeepSeek"
        case .mistral: return "Mistral"
        case .xai: return "Grok"
        case .ollama: return "Ollama"
        }
    }
    var wire: Wire {
        switch self {
        case .gemini: return .gemini
        case .anthropic: return .anthropic
        default: return .openai
        }
    }
    var needsKey: Bool { self != .ollama }

    /// Base URL for OpenAI-compatible providers (`/chat/completions`, `/models` are appended).
    var baseURL: String {
        switch self {
        case .openai: return "https://api.openai.com/v1"
        case .openrouter: return "https://openrouter.ai/api/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .deepseek: return "https://api.deepseek.com/v1"
        case .mistral: return "https://api.mistral.ai/v1"
        case .xai: return "https://api.x.ai/v1"
        case .ollama: return (UserDefaults.standard.string(forKey: "gptOllamaURL").flatMap { $0.isEmpty ? nil : $0 } ?? "http://localhost:11434") + "/v1"
        case .anthropic: return "https://api.anthropic.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta"
        }
    }

    /// Built-in models: the first is the default, the rest are the fallback chain when a model is busy.
    var builtinModels: [String] {
        switch self {
        case .gemini: return ["gemini-3.5-flash", "gemini-2.5-flash", "gemini-3.1-flash-lite"]
        case .openai: return ["gpt-5-mini", "gpt-5", "gpt-4.1-mini"]
        case .anthropic: return ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]
        case .openrouter: return ["openrouter/auto", "anthropic/claude-sonnet-5-5", "google/gemini-2.5-flash"]
        case .groq: return ["llama-3.3-70b-versatile", "openai/gpt-oss-120b"]
        case .deepseek: return ["deepseek-chat"]
        case .mistral: return ["mistral-large-latest", "mistral-small-latest"]
        case .xai: return ["grok-4", "grok-3-mini"]
        case .ollama: return ["llama3.1", "qwen2.5"]
        }
    }

    var keyPrompt: String {
        switch self {
        case .gemini: return "Get a free key at aistudio.google.com → Get API key."
        case .openai: return "Create a key at platform.openai.com → API keys."
        case .anthropic: return "Create a key at platform.claude.com → API keys."
        case .openrouter: return "Create a key at openrouter.ai → Keys. One key gives access to models from every major lab."
        case .groq: return "Create a key at console.groq.com → API Keys."
        case .deepseek: return "Create a key at platform.deepseek.com → API keys."
        case .mistral: return "Create a key at console.mistral.ai → API Keys."
        case .xai: return "Create a key at console.x.ai → API Keys."
        case .ollama: return "No key needed. Install Ollama (ollama.com), run `ollama pull llama3.1`, and keep it running. Pick a model that supports tool calling."
        }
    }

    var envVar: String {
        switch self {
        case .gemini: return "GEMINI_API_KEY"
        case .openai: return "OPENAI_API_KEY"
        case .anthropic: return "ANTHROPIC_API_KEY"
        case .openrouter: return "OPENROUTER_API_KEY"
        case .groq: return "GROQ_API_KEY"
        case .deepseek: return "DEEPSEEK_API_KEY"
        case .mistral: return "MISTRAL_API_KEY"
        case .xai: return "XAI_API_KEY"
        case .ollama: return ""
        }
    }

    // MARK: Model choice per provider

    var modelDefaultsKey: String { self == .gemini ? "gptModel" : "gptModel.\(rawValue)" }
    var modelsCacheKey: String { self == .gemini ? "gptModelsCache" : "gptModelsCache.\(rawValue)" }

    var selectedModel: String {
        let m = (UserDefaults.standard.string(forKey: modelDefaultsKey) ?? "").trimmingCharacters(in: .whitespaces)
        return m.isEmpty ? builtinModels[0] : m
    }
    /// The user's choice first, then the built-in fallbacks.
    var modelChain: [String] { [selectedModel] + builtinModels.filter { $0 != selectedModel } }

    var cachedModels: [GPTModelInfo] {
        get {
            guard let d = UserDefaults.standard.data(forKey: modelsCacheKey) else { return [] }
            return (try? JSONDecoder().decode([GPTModelInfo].self, from: d)) ?? []
        }
        nonmutating set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: modelsCacheKey) }
    }
}

// MARK: - Keys (one Keychain entry per provider; never displayed, only masked / copied / reset)

enum GPTKeys {
    enum Source { case user, envImport, environment, none }

    private static func account(_ p: GPTProvider) -> String { p == .gemini ? NetworkGPTKey.account : "\(p.rawValue)-api-key" }

    static func current(_ p: GPTProvider) -> String? {
        if p == .gemini { return NetworkGPTKey.current }
        if !p.needsKey { return "" }
        if let k = Keychain.load(account: account(p)), !k.isEmpty { return k }
        let e = ProcessInfo.processInfo.environment[p.envVar]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (e?.isEmpty == false) ? e : nil
    }
    static func isConfigured(_ p: GPTProvider) -> Bool { !p.needsKey || current(p) != nil }

    static func source(_ p: GPTProvider) -> Source {
        if p == .gemini {
            switch NetworkGPTKey.source {
            case .user: return .user
            case .envImport: return .envImport
            case .environment: return .environment
            case .none: return .none
            }
        }
        if Keychain.load(account: account(p))?.isEmpty == false { return .user }
        return current(p) != nil ? .environment : .none
    }

    static func save(_ p: GPTProvider, _ key: String) {
        if p == .gemini { NetworkGPTKey.save(key); return }
        Keychain.save(account: account(p), password: key.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    static func reset(_ p: GPTProvider) {
        if p == .gemini { NetworkGPTKey.reset(); return }
        Keychain.save(account: account(p), password: "")
    }
    static func masked(_ k: String) -> String { NetworkGPTKey.masked(k) }

    /// Checks a key by listing the provider's models; returns the chat-capable ones.
    static func validate(_ p: GPTProvider, _ key: String) async throws -> [GPTModelInfo] {
        switch p.wire {
        case .gemini: return try await NetworkGPTKey.validate(key)
        case .anthropic: return try await listAnthropic(key)
        case .openai: return try await listOpenAI(p, key)
        }
    }

    private static func listAnthropic(_ key: String) async throws -> [GPTModelInfo] {
        var out: [GPTModelInfo] = []
        var after: String?
        repeat {
            var c = URLComponents(string: "https://api.anthropic.com/v1/models")!
            c.queryItems = [URLQueryItem(name: "limit", value: "1000")] + (after.map { [URLQueryItem(name: "after_id", value: $0)] } ?? [])
            var req = URLRequest(url: c.url!)
            req.timeoutInterval = 15
            AnthropicWire.headers(&req, key: key, model: nil)
            let json = try await GPTHTTP.getJSON(req, provider: .anthropic)
            for m in json["data"] as? [[String: Any]] ?? [] {
                guard let id = m["id"] as? String else { continue }
                out.append(GPTModelInfo(id: id, displayName: (m["display_name"] as? String) ?? id))
            }
            after = (json["has_more"] as? Bool) == true ? json["last_id"] as? String : nil
        } while after != nil
        return out   // the API returns newest first
    }

    private static func listOpenAI(_ p: GPTProvider, _ key: String) async throws -> [GPTModelInfo] {
        var req = URLRequest(url: URL(string: p.baseURL + "/models")!)
        req.timeoutInterval = 15
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let json = try await GPTHTTP.getJSON(req, provider: p)
        var list: [GPTModelInfo] = []
        for m in json["data"] as? [[String: Any]] ?? [] {
            guard let id = m["id"] as? String else { continue }
            let s = id.lowercased()
            // Keep chat models only.
            let junk = ["embed", "whisper", "tts", "audio", "realtime", "transcribe", "dall-e", "image", "moderation",
                        "davinci", "babbage", "search", "computer-use", "guard", "ocr"]
            if junk.contains(where: { s.contains($0) }) { continue }
            if p == .openai, !(s.hasPrefix("gpt") || s.hasPrefix("o1") || s.hasPrefix("o3") || s.hasPrefix("o4") || s.hasPrefix("chatgpt")) { continue }
            if p == .openrouter, let params = m["supported_parameters"] as? [String], !params.contains("tools") { continue }
            list.append(GPTModelInfo(id: id, displayName: (m["name"] as? String) ?? id))
        }
        return list.sorted { $0.id.compare($1.id, options: .numeric) == .orderedDescending }
    }
}

// MARK: - HTTP helpers shared by the wires

enum GPTHTTP {
    struct Retryable: Error { let message: String }

    static func getJSON(_ req: URLRequest, provider p: GPTProvider) async throws -> [String: Any] {
        try await send(req, provider: p, label: p.shortName)
    }

    /// Sends a request; maps auth errors to `.auth`, busy/missing models to `Retryable`, everything else to `.http`.
    static func send(_ req: URLRequest, provider p: GPTProvider, label: String) async throws -> [String: Any] {
        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if let u = error as? URLError {
                if u.code == .cancelled { throw CancellationError() }
                if u.code == .notConnectedToInternet { throw NetworkGPTError.http(0, "No internet connection.") }
                if p == .ollama && (u.code == .cannotConnectToHost || u.code == .cannotFindHost) {
                    throw NetworkGPTError.http(0, "Ollama isn't running on \(p.baseURL). Start the Ollama app and try again.")
                }
                throw Retryable(message: "\(label): \(u.code == .timedOut ? "timed out" : u.localizedDescription)")
            }
            throw Retryable(message: "\(label): \(error.localizedDescription)")
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if (200..<300).contains(code), let json { return json }
        let err = json?["error"]
        let message = ((err as? [String: Any])?["message"] as? String) ?? (err as? String)
            ?? (json?["message"] as? String) ?? HTTPURLResponse.localizedString(forStatusCode: code)
        let lower = message.lowercased()
        if code == 401 || code == 403 || lower.contains("api key") || lower.contains("api_key") || lower.contains("x-api-key") {
            throw NetworkGPTError.auth(p, message)
        }
        if [404, 408, 429, 500, 502, 503, 504, 529].contains(code) || lower.contains("overloaded") {
            throw Retryable(message: "\(label): \(message)")
        }
        throw NetworkGPTError.http(code, message)
    }
}

// MARK: - Tool schema in JSON-Schema form (OpenAI + Anthropic)

enum GPTTools {
    /// (name, description, JSON schema) for each tool, derived from the Gemini declarations.
    static var specs: [(name: String, description: String, schema: [String: Any])] {
        NetworkGPTEngine.toolDeclarations.map { d in
            (d["name"] as? String ?? "", d["description"] as? String ?? "", lower(d["parameters"] as? [String: Any] ?? [:]))
        }
    }
    /// Gemini uses OBJECT/STRING; JSON Schema wants object/string.
    private static func lower(_ s: [String: Any]) -> [String: Any] {
        var o: [String: Any] = [:]
        for (k, v) in s {
            if k == "type", let t = v as? String { o[k] = t.lowercased() }
            else if k == "properties", let p = v as? [String: Any] {
                o[k] = p.mapValues { ($0 as? [String: Any]).map(lower) ?? $0 }
            } else { o[k] = v }
        }
        if o["properties"] == nil { o["properties"] = [String: Any]() }
        return o
    }
}

// MARK: - Anthropic Messages wire (raw HTTP: Swift has no official Anthropic SDK)

enum AnthropicWire {
    static let version = "2026-10-21"
    /// Models that accept server-side refusal fallbacks (beta).
    static let fallbackModels: Set<String> = ["claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"]

    static func headers(_ req: inout URLRequest, key: String, model: String?) {
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue(version, forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        if let model, fallbackModels.contains(model) {
            req.setValue("server-side-fallback-2026-07-01", forHTTPHeaderField: "anthropic-beta")
        }
    }

    static func tools() -> [[String: Any]] {
        GPTTools.specs.map { ["name": $0.name, "description": $0.description, "input_schema": $0.schema] }
    }
}

extension NetworkGPTEngine {
    /// Tool loop over the Anthropic Messages API. Assistant turns (including thinking blocks) are sent back unchanged.
    func askAnthropic(_ p: GPTProvider, key: String, history: [GPTMessage], question: String, system: String,
                      onStep: @escaping @MainActor (GPTStep) -> Void) async throws -> GPTAnswer {
        var messages: [[String: Any]] = []
        for m in history.suffix(20) where m.role != .error && !m.text.isEmpty {
            let role = m.role == .user ? "user" : "assistant"
            if let last = messages.last, last["role"] as? String == role {   // roles must alternate
                messages[messages.count - 1]["content"] = (last["content"] as? String ?? "") + "\n\n" + m.text
            } else { messages.append(["role": role, "content": m.text]) }
        }
        if messages.first?["role"] as? String == "assistant" { messages.removeFirst() }
        if messages.last?["role"] as? String == "user" { messages.removeLast() }
        messages.append(["role": "user", "content": question])

        var queries: [String] = []
        let chain = p.modelChain
        var idx = 0, locked = false
        for _ in 0..<Self.maxRounds {
            try Task.checkCancellation()
            var resp: [String: Any]?
            var lastErr = ""
            while idx < chain.count {
                let model = chain[idx]
                var body: [String: Any] = ["model": model, "max_tokens": 16000, "system": system,
                                           "messages": messages, "tools": AnthropicWire.tools()]
                if AnthropicWire.fallbackModels.contains(model) { body["fallbacks"] = "default" }
                var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
                req.httpMethod = "POST"
                req.timeoutInterval = (!locked && idx == 0 && chain.count > 1) ? 45 : 180
                AnthropicWire.headers(&req, key: key, model: model)
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                do { resp = try await GPTHTTP.send(req, provider: p, label: model); locked = true; break }
                catch let e as GPTHTTP.Retryable {
                    lastErr = e.message; idx += 1
                    if idx < chain.count { await onStep(GPTStep(text: "Switching to \(chain[idx])…")) }
                }
            }
            guard let resp else { throw NetworkGPTError.allModelsFailed(p, lastErr) }
            let model = (resp["model"] as? String) ?? chain[idx]
            let content = resp["content"] as? [[String: Any]] ?? []
            let stop = resp["stop_reason"] as? String ?? ""
            if stop == "refusal" { throw NetworkGPTError.badResponse("Claude declined to answer this question.") }

            let calls = content.filter { $0["type"] as? String == "tool_use" }
            if stop != "tool_use" || calls.isEmpty {
                let text = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
                    .joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { throw NetworkGPTError.badResponse(stop.isEmpty ? "empty answer" : stop) }
                return GPTAnswer(text: text, queries: queries, model: model)
            }
            messages.append(["role": "assistant", "content": content])
            var results: [[String: Any]] = []
            for c in calls {
                try Task.checkCancellation()
                let r = await runTool(c["name"] as? String ?? "", c["input"] as? [String: Any] ?? [:], queries: &queries, onStep: onStep)
                results.append(["type": "tool_result", "tool_use_id": c["id"] as? String ?? "", "content": Self.jsonString(r)])
            }
            messages.append(["role": "user", "content": results])   // all results in one message
            await onStep(GPTStep(text: "Writing answer…"))
        }
        throw NetworkGPTError.tooManyRounds
    }

    /// Tool loop over OpenAI-style chat completions (OpenAI, OpenRouter, Groq, DeepSeek, Mistral, xAI, Ollama).
    func askOpenAI(_ p: GPTProvider, key: String, history: [GPTMessage], question: String, system: String,
                   onStep: @escaping @MainActor (GPTStep) -> Void) async throws -> GPTAnswer {
        var messages: [[String: Any]] = [["role": "system", "content": system]]
        for m in history.suffix(20) where m.role != .error && !m.text.isEmpty {
            messages.append(["role": m.role == .user ? "user" : "assistant", "content": m.text])
        }
        messages.append(["role": "user", "content": question])
        let tools: [[String: Any]] = GPTTools.specs.map {
            ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.schema]]
        }

        var queries: [String] = []
        let chain = p.modelChain
        var idx = 0, locked = false
        for _ in 0..<Self.maxRounds {
            try Task.checkCancellation()
            var resp: [String: Any]?
            var lastErr = ""
            while idx < chain.count {
                let model = chain[idx]
                var req = URLRequest(url: URL(string: p.baseURL + "/chat/completions")!)
                req.httpMethod = "POST"
                req.timeoutInterval = p == .ollama ? 300 : ((!locked && idx == 0 && chain.count > 1) ? 30 : 120)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
                if p == .openrouter { req.setValue("WiFi Monitor", forHTTPHeaderField: "X-Title") }
                req.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "messages": messages, "tools": tools])
                do { resp = try await GPTHTTP.send(req, provider: p, label: model); locked = true; break }
                catch let e as GPTHTTP.Retryable {
                    lastErr = e.message; idx += 1
                    if idx < chain.count { await onStep(GPTStep(text: "Switching to \(chain[idx])…")) }
                }
            }
            guard let resp else { throw NetworkGPTError.allModelsFailed(p, lastErr) }
            let model = (resp["model"] as? String) ?? chain[idx]
            guard let choice = (resp["choices"] as? [[String: Any]])?.first, let msg = choice["message"] as? [String: Any] else {
                throw NetworkGPTError.badResponse("no choices")
            }
            let calls = msg["tool_calls"] as? [[String: Any]] ?? []
            if calls.isEmpty {
                let text = (msg["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if text.isEmpty { throw NetworkGPTError.badResponse((choice["finish_reason"] as? String) ?? "empty answer") }
                return GPTAnswer(text: text, queries: queries, model: model)
            }
            var assistant: [String: Any] = ["role": "assistant", "tool_calls": calls]
            assistant["content"] = msg["content"] as? String ?? NSNull()
            messages.append(assistant)
            for c in calls {
                try Task.checkCancellation()
                let fn = c["function"] as? [String: Any] ?? [:]
                let argsText = fn["arguments"] as? String ?? "{}"
                let args = (try? JSONSerialization.jsonObject(with: Data(argsText.utf8))) as? [String: Any]
                    ?? (fn["arguments"] as? [String: Any]) ?? [:]
                let r = await runTool(fn["name"] as? String ?? "", args, queries: &queries, onStep: onStep)
                messages.append(["role": "tool", "tool_call_id": c["id"] as? String ?? "", "content": Self.jsonString(r)])
            }
            await onStep(GPTStep(text: "Writing answer…"))
        }
        throw NetworkGPTError.tooManyRounds
    }

    static func jsonString(_ v: Any) -> String {
        guard JSONSerialization.isValidJSONObject(v), let d = try? JSONSerialization.data(withJSONObject: v) else { return "\(v)" }
        return String(decoding: d, as: UTF8.self)
    }
}
