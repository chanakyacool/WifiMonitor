import SwiftUI
import AppKit

// MARK: - Conversation state (shared so a running answer survives page switches)

@MainActor
final class NetworkGPTChat: ObservableObject {
    static let shared = NetworkGPTChat()

    @Published var messages: [GPTMessage] = []
    @Published var running = false
    @Published var step: GPTStep?
    @Published var stepQueries: [String] = []
    @Published var hasKey = false

    private let engine = NetworkGPTEngine()
    private var task: Task<Void, Never>?
    private var loaded = false

    func loadIfNeeded() {
        refreshKey()
        guard !loaded else { return }
        loaded = true
        messages = NetworkGPTStore.load()
    }

    func refreshKey() { hasKey = GPTKeys.isConfigured(GPTProvider.active) }

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !running else { return }
        messages.removeAll { $0.role == .error }
        messages.append(GPTMessage(role: .user, text: text))
        persist()
        answer(text)
    }

    /// Re-asks the last user question after an error.
    func retry() {
        guard !running, let last = messages.last(where: { $0.role == .user }) else { return }
        messages.removeAll { $0.role == .error }
        answer(last.text)
    }

    func stop() {
        task?.cancel()
    }

    func newChat() {
        stop()
        messages = []
        step = nil
        stepQueries = []
        persist()
    }

    private func answer(_ question: String) {
        // History = everything before the question being asked.
        var history = messages
        if let i = history.lastIndex(where: { $0.role == .user && $0.text == question }) { history = Array(history[..<i]) }
        running = true
        step = GPTStep(text: "Thinking…")
        stepQueries = []
        let engine = engine
        task = Task { [weak self] in
            do {
                let a = try await engine.ask(history: history, question: question) { s in
                    guard let self else { return }
                    self.step = s
                    if let sql = s.sql { self.stepQueries.append(sql) }
                }
                self?.finish(GPTMessage(role: .assistant, text: a.text, queries: a.queries, model: a.model))
            } catch is CancellationError {
                self?.finish(GPTMessage(role: .error, text: "Stopped."))
            } catch {
                if Task.isCancelled { self?.finish(GPTMessage(role: .error, text: "Stopped.")); return }
                if case NetworkGPTError.noKey = error { self?.refreshKey() }
                self?.finish(GPTMessage(role: .error, text: error.localizedDescription))
            }
        }
    }

    private func finish(_ m: GPTMessage) {
        messages.append(m)
        running = false
        step = nil
        stepQueries = []
        task = nil
        persist()
    }

    private func persist() {
        let msgs = messages.filter { $0.role != .error }
        DispatchQueue.global(qos: .utility).async { NetworkGPTStore.save(msgs) }
    }
}

// MARK: - Main view

struct NetworkGPTView: View {
    @EnvironmentObject var m: Monitor
    @ObservedObject private var chat = NetworkGPTChat.shared
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            if !chat.hasKey {
                ScrollView { NetworkGPTKeyCard().frame(maxWidth: 560).padding(32).frame(maxWidth: .infinity) }
            } else if chat.messages.isEmpty && !chat.running {
                ScrollView { emptyState.frame(maxWidth: 760).padding(.horizontal, 24).frame(maxWidth: .infinity) }
            } else {
                messageList
            }
            if chat.hasKey { composer }
        }
        .background(AppBackground())
        .sheet(isPresented: $showSettings, onDismiss: { chat.refreshKey() }) { NetworkGPTSettingsSheet() }
        .onAppear {
            chat.loadIfNeeded()
            focused = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            IconBadge(icon: "sparkles", color: .purple, size: 28)
            Text("NetworkGPT").font(.system(size: 17, weight: .bold, design: .rounded))
            ModelSwitcher(openSettings: { showSettings = true })
            Spacer()
            Button {
                chat.newChat()
                draft = ""
                focused = true
            } label: {
                Label("New chat", systemImage: "square.and.pencil")
            }
            .buttonStyle(.appSecondary(.purple))
            .disabled(chat.messages.isEmpty && !chat.running)
            .help("Start a new conversation")
            Button { showSettings = true } label: {
                Label("Settings", systemImage: "gearshape.fill")
            }
            .buttonStyle(.appSecondary(.purple))
            .help("API key and model")
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: Empty state

    private static let suggestions: [(icon: String, color: Color, text: String)] = [
        ("tortoise.fill", .orange, "Why was my internet slow yesterday evening?"),
        ("chart.bar.fill", .pink, "Which device used the most data this week?"),
        ("bolt.slash.fill", .red, "How many outages did I have today?"),
        ("wifi", .blue, "How is my Wi‑Fi signal right now?"),
        ("speedometer", .purple, "Summarize my speed tests from the last 7 days"),
        ("app.badge", .teal, "Which apps on this Mac used the most data today?"),
    ]

    private var emptyState: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 40)
            Image(systemName: "sparkles")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(LinearGradient(colors: [Theme.palette[0], Theme.palette[3], Theme.palette[4]],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: Theme.palette[3].opacity(0.4), radius: 14, y: 4)
            Text("NetworkGPT")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [Theme.palette[0], Theme.palette[3], Theme.palette[4]],
                                                startPoint: .leading, endPoint: .trailing))
            Text("Ask anything about your Wi‑Fi and network")
                .font(.title3).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                ForEach(Self.suggestions, id: \.text) { s in
                    Button { chat.send(s.text) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            IconBadge(icon: s.icon, color: s.color, size: 26)
                            Text(s.text).font(.callout).multilineTextAlignment(.leading).foregroundStyle(.primary)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .topLeading)
                        .glassCard(tint: s.color, padding: 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 12)
            Text("Answers come from the data this app has recorded on your Mac. Your question and query results are sent to \(GPTProvider.active.title).")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            Spacer(minLength: 20)
        }
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(chat.messages) { msg in
                        MessageRow(msg: msg, isLastError: msg.id == chat.messages.last?.id && msg.role == .error,
                                   retry: { chat.retry() })
                            .id(msg.id)
                    }
                    if chat.running {
                        ThinkingRow(step: chat.step, queries: chat.stepQueries).id("thinking")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 780)
                .padding(.horizontal, 24).padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: chat.step) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Ask about your network…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...6)
                .focused($focused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) || press.modifiers.contains(.option) {
                        draft += "\n"
                        return .handled
                    }
                    submit()
                    return .handled
                }
                .onSubmit(submit)
                .padding(.vertical, 6)
            if chat.running {
                Button { chat.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 28))
                        .foregroundStyle(Theme.gradient(.red))
                }
                .buttonStyle(.plain)
                .help("Stop")
            } else {
                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 28))
                        .foregroundStyle(canSend ? AnyShapeStyle(Theme.gradient(.purple)) : AnyShapeStyle(Color.secondary.opacity(0.4)))
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Return)")
            }
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 6)
        .glassCard(tint: .purple, padding: 4)
        .overlay(RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
            .strokeBorder(focused ? Color.purple.opacity(0.45) : .clear, lineWidth: 1.5))
        .frame(maxWidth: 780)
        .padding(.horizontal, 24).padding(.bottom, 16).padding(.top, 8)
        .frame(maxWidth: .infinity)
    }

    private var canSend: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !chat.running }

    private func submit() {
        guard canSend else { return }
        let t = draft
        draft = ""
        chat.send(t)
    }
}

// MARK: - Rows

private struct Avatar: View {
    var body: some View { IconBadge(icon: "sparkles", color: .purple, size: 28) }
}

private struct MessageRow: View {
    let msg: GPTMessage
    let isLastError: Bool
    let retry: () -> Void
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        switch msg.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(msg.text)
                    .textSelection(.enabled)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.gradient(.purple)))
                    .shadow(color: Color.purple.opacity(0.25), radius: 6, y: 3)
            }
        case .assistant:
            HStack(alignment: .top, spacing: 12) {
                Avatar()
                VStack(alignment: .leading, spacing: 8) {
                    MarkdownView(text: msg.text)
                    if !msg.queries.isEmpty { QueriesDisclosure(queries: msg.queries) }
                    HStack(spacing: 6) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(msg.text, forType: .string)
                            copied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                        } label: {
                            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.caption)
                        }
                        .buttonStyle(.borderless)
                        Text(msg.date.formatted(date: .omitted, time: .shortened)).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .opacity(hovering || copied ? 1 : 0)
                }
                Spacer(minLength: 40)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
        case .error:
            HStack(alignment: .top, spacing: 12) {
                IconBadge(icon: "exclamationmark.triangle.fill", color: .red, size: 28)
                VStack(alignment: .leading, spacing: 8) {
                    Text(msg.text).textSelection(.enabled).font(.callout)
                    if isLastError {
                        Button("Retry", systemImage: "arrow.clockwise", action: retry)
                            .buttonStyle(.app(.red))
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.red.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.red.opacity(0.35)))
                Spacer(minLength: 40)
            }
        }
    }
}

private struct QueriesDisclosure: View {
    let queries: [String]
    var title: String? = nil
    @State private var open = false

    var body: some View {
        DisclosureGroup(isExpanded: $open) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(queries.enumerated()), id: \.offset) { _, q in
                    Text(q)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                }
            }
            .padding(.top, 4)
        } label: {
            Text(title ?? "Show queries (\(queries.count))").font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ThinkingRow: View {
    let step: GPTStep?
    let queries: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Avatar()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TimelineView(.periodic(from: .now, by: 0.3)) { ctx in
                        let phase = Int(ctx.date.timeIntervalSinceReferenceDate / 0.3) % 3
                        HStack(spacing: 4) {
                            ForEach(0..<3) { i in
                                Circle().fill(Theme.gradient(.purple)).frame(width: 7, height: 7)
                                    .opacity(i == phase ? 1 : 0.3)
                                    .scaleEffect(i == phase ? 1.2 : 0.9)
                            }
                        }
                        .animation(.easeInOut(duration: 0.25), value: phase)
                    }
                    Text(step?.text ?? "Thinking…").font(.callout).foregroundStyle(.secondary)
                }
                .padding(.top, 6)
                if !queries.isEmpty {
                    QueriesDisclosure(queries: queries, title: "SQL (\(queries.count))")
                }
            }
            Spacer()
        }
    }
}

// MARK: - Markdown (inline via AttributedString, blocks parsed by hand)

struct MarkdownView: View {
    let text: String

    private enum Block {
        case heading(Int, String)
        case bullet(String, Int)       // text, indent level
        case numbered(String, String)  // number, text
        case table([[String]])
        case code(String)
        case paragraph(String)
        case rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.parse(text).enumerated()), id: \.offset) { _, b in
                view(for: b)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for b: Block) -> some View {
        switch b {
        case .heading(let level, let t):
            Self.inline(t).font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 4)
        case .bullet(let t, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(indent > 0 ? "◦" : "•").foregroundStyle(.purple)
                Self.inline(t).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let n, let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n + ".").monospacedDigit().foregroundStyle(.secondary)
                Self.inline(t).fixedSize(horizontal: false, vertical: true)
            }
        case .table(let rows):
            TableBlock(rows: rows)
        case .code(let c):
            Text(c).font(.system(.callout, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.06)))
        case .paragraph(let t):
            Self.inline(t).fixedSize(horizontal: false, vertical: true)
        case .rule:
            Divider()
        }
    }

    static func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }

    private static func parse(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var para: [String] = []
        var table: [String] = []
        var code: [String]? = nil

        func flushPara() {
            if !para.isEmpty { blocks.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            let rows = table
                .filter { line in !line.replacingOccurrences(of: " ", with: "").allSatisfy { "|-:".contains($0) } }
                .map { line -> [String] in
                    var l = line.trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("|") { l.removeFirst() }
                    if l.hasSuffix("|") { l.removeLast() }
                    return l.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                }
            if !rows.isEmpty { blocks.append(.table(rows)) }
            table = []
        }

        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { blocks.append(.code(c.joined(separator: "\n"))); code = nil }
                else { flushPara(); flushTable(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }

            if line.hasPrefix("|") { flushPara(); table.append(line); continue }
            flushTable()

            if line.isEmpty { flushPara(); continue }
            if line == "---" || line == "***" || line == "___" { flushPara(); blocks.append(.rule); continue }
            if line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                if level <= 6, line.dropFirst(level).first == " " {
                    flushPara()
                    blocks.append(.heading(level, String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)))
                    continue
                }
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") || line.hasPrefix("+ ") {
                flushPara()
                let leading = raw.prefix(while: { $0 == " " || $0 == "\t" }).count
                blocks.append(.bullet(String(line.dropFirst(2)), leading >= 2 ? 1 : 0))
                continue
            }
            if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
               line[line.index(after: dot)...].first == " " {
                flushPara()
                blocks.append(.numbered(String(line[..<dot]), String(line[line.index(dot, offsetBy: 2)...])))
                continue
            }
            para.append(line)
        }
        if let c = code { blocks.append(.code(c.joined(separator: "\n"))) }
        flushTable()
        flushPara()
        return blocks
    }
}

private struct TableBlock: View {
    let rows: [[String]]

    var body: some View {
        let cols = rows.map(\.count).max() ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { r, row in
                    GridRow {
                        ForEach(0..<cols, id: \.self) { c in
                            MarkdownView.inline(c < row.count ? row[c] : "")
                                .font(r == 0 ? .callout.weight(.semibold) : .callout)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(r == 0 ? Color.purple.opacity(0.12) : (r % 2 == 0 ? Color.primary.opacity(0.035) : .clear))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        }
    }
}

// MARK: - Model switcher (header menu, like ChatGPT's)

private struct ModelSwitcher: View {
    @AppStorage(GPTProvider.defaultsKey) private var providerRaw = GPTProvider.gemini.rawValue
    @State private var tick = 0   // forces a refresh after picking a model
    let openSettings: () -> Void

    var body: some View {
        let active = GPTProvider(rawValue: providerRaw) ?? .gemini
        Menu {
            ForEach(GPTProvider.allCases) { p in
                if GPTKeys.isConfigured(p) {
                    Menu(p.title) {
                        let list = p.cachedModels.isEmpty ? p.builtinModels : p.cachedModels.map(\.id)
                        ForEach(Array(list.prefix(40)), id: \.self) { m in
                            Button {
                                UserDefaults.standard.set(m, forKey: p.modelDefaultsKey)
                                providerRaw = p.rawValue
                                tick += 1
                                NetworkGPTChat.shared.refreshKey()
                            } label: {
                                if p == active && m == p.selectedModel { Label(m, systemImage: "checkmark") } else { Text(m) }
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Add a provider or key…", action: openSettings)
        } label: {
            HStack(spacing: 4) {
                Text(active.shortName).fontWeight(.semibold)
                Text(active.selectedModel).foregroundStyle(.secondary)
            }
            .font(.callout)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .id(tick)
        .help("Choose the AI provider and model")
    }
}

// MARK: - API key entry

/// Shown in place of the chat when the chosen provider has no key yet.
struct NetworkGPTKeyCard: View {
    @AppStorage(GPTProvider.defaultsKey) private var providerRaw = GPTProvider.gemini.rawValue
    @State private var key = ""
    @State private var validating = false
    @State private var error: String?
    @State private var importFailed = false
    private var provider: GPTProvider { GPTProvider(rawValue: providerRaw) ?? .gemini }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconBadge(icon: "key.fill", color: .purple, size: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect NetworkGPT").font(.title3.bold())
                    Text("Pick an AI provider and paste its API key.").font(.callout).foregroundStyle(.secondary)
                }
            }
            Picker("Provider", selection: $providerRaw) {
                ForEach(GPTProvider.allCases) { Text($0.title).tag($0.rawValue) }
            }
            .onChange(of: providerRaw) { _, _ in error = nil; NetworkGPTChat.shared.refreshKey() }
            Text(.init(provider.keyPrompt + " The key is stored in your macOS Keychain and never shown again."))
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack {
                SecureField("\(provider.shortName) API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                if validating { ProgressView().controlSize(.small) }
                Button("Save", action: save)
                    .buttonStyle(.app(.purple))
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || validating)
            }
            if let error { Label(error, systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red) }
            if provider == .gemini, NetworkGPTKey.envFileExists {
                Button("Import from NSE .env") {
                    importFailed = !NetworkGPTKey.importFromEnvFile()
                    NetworkGPTChat.shared.refreshKey()
                }
                .buttonStyle(.appSecondary(.purple))
                if importFailed { Text("No GEMINI_API_KEY found in that file.").font(.caption).foregroundStyle(.red) }
            }
        }
        .glassCard(tint: .purple, padding: 20)
    }

    private func save() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = provider
        guard !k.isEmpty, !validating else { return }
        validating = true; error = nil
        Task {
            do {
                let models = try await GPTKeys.validate(p, k)
                GPTKeys.save(p, k)
                if !models.isEmpty { p.cachedModels = models }
                key = ""
                NetworkGPTChat.shared.refreshKey()
            } catch {
                self.error = "Key check failed: \(error.localizedDescription)"
            }
            validating = false
        }
    }
}

// MARK: - Settings (Settings page section + sheet on the NetworkGPT screen)

/// Sheet opened from the gear button on the NetworkGPT screen.
struct NetworkGPTSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                IconBadge(icon: "gearshape.fill", color: .purple, size: 24)
                Text("NetworkGPT Settings").font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Form { NetworkGPTSettingsSection() }
                .formStyle(.grouped)
        }
        .frame(width: 600, height: 600)
    }
}

/// Drop-in `Section` for the Settings `Form`: provider, its API key (masked; copy / reset only) and model.
struct NetworkGPTSettingsSection: View {
    @AppStorage(GPTProvider.defaultsKey) private var providerRaw = GPTProvider.gemini.rawValue
    @AppStorage("gptOllamaURL") private var ollamaURL = "http://localhost:11434"
    @State private var model = ""
    @State private var key = ""
    @State private var masked: String?
    @State private var source: GPTKeys.Source = .none
    @State private var validating = false
    @State private var keyStatus: (ok: Bool, text: String)?
    @State private var copied = false
    @State private var confirmReset = false
    @State private var models: [GPTModelInfo] = []
    @State private var loadingModels = false
    @State private var modelsError: String?
    @State private var customModel = ""
    @State private var importFailed = false

    private var provider: GPTProvider { GPTProvider(rawValue: providerRaw) ?? .gemini }

    var body: some View {
        Section {
            Picker("AI provider", selection: $providerRaw) {
                ForEach(GPTProvider.allCases) { p in
                    HStack {
                        Text(p.title)
                        if GPTKeys.isConfigured(p) && p.needsKey { Text("· key saved").foregroundStyle(.secondary) }
                    }.tag(p.rawValue)
                }
            }
            if provider == .ollama {
                TextField("Ollama address", text: $ollamaURL, prompt: Text("http://localhost:11434"))
            } else {
                keyRows
            }
            modelRows
            Text("\(provider.keyPrompt) Questions and query results are sent to \(provider.title); the database itself stays on this Mac. If the chosen model is busy, NetworkGPT falls back to \(provider.builtinModels.filter { $0 != model }.joined(separator: ", ")).")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            Text("NetworkGPT")
        }
        .onAppear { load() }
        .onChange(of: providerRaw) { _, _ in keyStatus = nil; modelsError = nil; key = ""; load() }
        .onChange(of: model) { _, m in UserDefaults.standard.set(m, forKey: provider.modelDefaultsKey) }
        .confirmationDialog("Reset the \(provider.shortName) API key?", isPresented: $confirmReset) {
            Button("Reset key", role: .destructive) {
                GPTKeys.reset(provider)
                keyStatus = nil
                refresh()
            }
        } message: {
            Text("The key is deleted from your Keychain. NetworkGPT can't use \(provider.shortName) until you enter a new key.")
        }
    }

    // MARK: Key

    @ViewBuilder private var keyRows: some View {
        if let masked {
            LabeledContent("\(provider.shortName) API key") {
                HStack(spacing: 8) {
                    Text(masked).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
                    Button(copied ? "Copied ✓" : "Copy") { copyKey() }
                    Button("Reset", role: .destructive) { confirmReset = true }
                        .disabled(source == .environment)
                }
            }
            sourceLabel
        } else {
            LabeledContent("\(provider.shortName) API key") {
                HStack(spacing: 8) {
                    SecureField("", text: $key, prompt: Text("Paste your \(provider.shortName) API key"))
                        .labelsHidden()
                        .onSubmit(save)
                    if validating { ProgressView().controlSize(.small) }
                    Button("Save", action: save)
                        .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || validating)
                }
            }
            if provider == .gemini, NetworkGPTKey.envFileExists {
                HStack {
                    Button("Import from NSE .env") {
                        importFailed = !NetworkGPTKey.importFromEnvFile()
                        refresh()
                        if !importFailed { Task { await loadModels() } }
                    }
                    if importFailed { Text("No GEMINI_API_KEY in that file").font(.caption).foregroundStyle(.red) }
                }
            }
        }
        if let keyStatus {
            Label(keyStatus.text, systemImage: keyStatus.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption).foregroundStyle(keyStatus.ok ? .green : .red)
        }
    }

    @ViewBuilder private var sourceLabel: some View {
        switch source {
        case .user: Label("Your key (Keychain)", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
        case .envImport: Label("Imported from NSE-OptionChain .env (stored in Keychain)", systemImage: "square.and.arrow.down").font(.caption).foregroundStyle(.secondary)
        case .environment: Label("From the \(provider.envVar) environment variable", systemImage: "terminal").font(.caption).foregroundStyle(.secondary)
        case .none: EmptyView()
        }
    }

    // MARK: Model

    @ViewBuilder private var modelRows: some View {
        let options: [GPTModelInfo] = models.isEmpty ? provider.builtinModels.map { GPTModelInfo(id: $0, displayName: $0) } : models
        HStack {
            Picker("Model", selection: $model) {
                ForEach(options) { m in
                    Text(m.displayName == m.id ? m.id : "\(m.displayName) — \(m.id)").tag(m.id)
                }
                if !model.isEmpty, !options.map(\.id).contains(model) { Text("\(model) (custom)").tag(model) }
            }
            if loadingModels { ProgressView().controlSize(.small) }
            Button { Task { await loadModels() } } label: { Image(systemName: "arrow.clockwise") }
                .help("Refresh the model list from \(provider.shortName)")
                .disabled(loadingModels || !GPTKeys.isConfigured(provider))
        }
        HStack {
            TextField("Custom model id", text: $customModel, prompt: Text("e.g. \(provider.builtinModels.last ?? "")"))
                .onSubmit(useCustom)
            Button("Use", action: useCustom).disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        if let modelsError {
            Text("Couldn't load the model list: \(modelsError)").font(.caption).foregroundStyle(.orange)
        } else if models.isEmpty {
            Text("Showing the built-in models. Press ↻ to load every model your key can use.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    private func load() {
        model = provider.selectedModel
        models = provider.cachedModels
        refresh()
        if models.isEmpty, GPTKeys.isConfigured(provider) { Task { await loadModels() } }
    }

    private func refresh() {
        if provider.needsKey, let k = GPTKeys.current(provider) { masked = GPTKeys.masked(k) } else { masked = nil }
        source = GPTKeys.source(provider)
        NetworkGPTChat.shared.refreshKey()
    }

    private func copyKey() {
        guard let k = GPTKeys.current(provider), !k.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(k, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
    }

    private func save() {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = provider
        guard !k.isEmpty, !validating else { return }
        validating = true
        keyStatus = nil
        Task {
            do {
                let list = try await GPTKeys.validate(p, k)
                GPTKeys.save(p, k)
                key = ""
                keyStatus = (true, "Key works ✓ — saved in Keychain")
                if p == provider { applyModels(list, p) }
                refresh()
            } catch {
                keyStatus = (false, "Key check failed: \(error.localizedDescription)")
            }
            validating = false
        }
    }

    private func loadModels() async {
        let p = provider
        guard let k = GPTKeys.current(p) else { return }
        loadingModels = true
        do { applyModels(try await GPTKeys.validate(p, k), p) }
        catch { if p == provider { modelsError = error.localizedDescription } }
        loadingModels = false
    }

    private func applyModels(_ list: [GPTModelInfo], _ p: GPTProvider) {
        guard p == provider else { return }
        guard !list.isEmpty else { modelsError = "no models returned"; return }
        models = list
        modelsError = nil
        p.cachedModels = list
    }

    private func useCustom() {
        let m = customModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { return }
        model = m.hasPrefix("models/") ? String(m.dropFirst(7)) : m
        customModel = ""
    }
}
