import SwiftUI
import AppKit

/// Button that opens the speed-test popup window and starts a test.
struct SpeedTestButton: View {
    @EnvironmentObject var m: Monitor
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button {
            openWindow(id: "speedtest")
            NSApp.activate(ignoringOtherApps: true)
            Task { await m.runSpeedTest() }
        } label: {
            Label(m.speedTestRunning ? "Testing…" : "Speed test", systemImage: "speedometer")
        }
        .disabled(m.speedTestRunning)
    }
}

// MARK: - Palette

private enum GaugeTheme {
    static let download = [Color(red: 0.09, green: 0.64, blue: 0.38), Color(red: 0.30, green: 0.93, blue: 0.56)]
    static let upload = [Color(red: 0.42, green: 0.27, blue: 0.93), Color(red: 0.80, green: 0.47, blue: 1.00)]
    static let ping = Color.orange

    static func needle(_ upload: Bool) -> Color {
        let light = upload ? NSColor(red: 0.25, green: 0.12, blue: 0.55, alpha: 1) : NSColor(red: 0.04, green: 0.32, blue: 0.17, alpha: 1)
        let dark = upload ? NSColor(red: 0.90, green: 0.84, blue: 1.00, alpha: 1) : NSColor(red: 0.85, green: 1.00, blue: 0.91, alpha: 1)
        return Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
}

// MARK: - Gauge

/// 270° speedometer: thick gradient arc, tapered needle on a pivot ring, non-linear Mbps scale.
struct SpeedGauge: View {
    var fraction: Double            // 0…1 along the arc (see `fraction(for:)`)
    var colors: [Color]
    var needle: Color
    var readout: String
    var caption: String

    static let stops: [Double] = [0, 5, 10, 50, 100, 250, 500, 1000]
    private static let start = 135.0, sweep = 270.0

    /// Maps Mbps onto the arc with equal spacing per scale stop, so 20 Mbps and 900 Mbps both read well.
    static func fraction(for mbps: Double) -> Double {
        guard mbps > 0 else { return 0 }
        for i in 1..<stops.count where mbps <= stops[i] {
            return (Double(i - 1) + (mbps - stops[i - 1]) / (stops[i] - stops[i - 1])) / Double(stops.count - 1)
        }
        return 1
    }

    var body: some View {
        GeometryReader { g in
            let size = min(g.size.width, g.size.height)
            let line = size * 0.09
            let r = size / 2 - line / 2
            let f = min(1, max(0, fraction))
            let gradient = AngularGradient(colors: colors, center: .center, startAngle: .degrees(0), endAngle: .degrees(Self.sweep))
            ZStack {
                Circle().trim(from: 0, to: Self.sweep / 360)
                    .stroke(Color.primary.opacity(0.07), style: StrokeStyle(lineWidth: line, lineCap: .butt))
                    .rotationEffect(.degrees(Self.start))
                Circle().trim(from: 0, to: Self.sweep / 360 * f)
                    .stroke(gradient, style: StrokeStyle(lineWidth: line, lineCap: .butt))
                    .rotationEffect(.degrees(Self.start))
                    .shadow(color: (colors.last ?? .green).opacity(0.45), radius: 12)

                // Scale labels inside the arc; those already passed light up.
                ForEach(Array(Self.stops.enumerated()), id: \.offset) { i, stop in
                    let t = Double(i) / Double(Self.stops.count - 1)
                    let a = (Self.start + Self.sweep * t) * .pi / 180
                    let lr = r - line / 2 - size * 0.075
                    Text(stop >= 1000 ? "1G" : String(Int(stop)))
                        .font(.system(size: size * 0.043, weight: .semibold, design: .rounded))
                        .foregroundStyle(f > 0 && t <= f + 0.001 ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .position(x: size / 2 + cos(a) * lr, y: size / 2 + sin(a) * lr)
                }

                NeedleShape()
                    .fill(LinearGradient(colors: [needle, needle.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                    .frame(width: size * 0.058, height: r * 0.64)
                    .offset(y: -(r * 0.64 - size * 0.058) / 2)
                    .rotationEffect(.degrees(Self.start + Self.sweep * f + 90))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 2)
                Circle().stroke(needle.opacity(0.55), lineWidth: 1.5).frame(width: size * 0.15, height: size * 0.15)
                Circle().fill(needle).frame(width: size * 0.05, height: size * 0.05)

                VStack(spacing: 0) {
                    Text(readout)
                        .font(.system(size: size * 0.135, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: fraction))
                    Text(caption)
                        .font(.system(size: size * 0.045, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .position(x: size / 2, y: size / 2 + r * 0.80)
            }
            .frame(width: size, height: size)
            .position(x: g.size.width / 2, y: g.size.height / 2)
        }
    }
}

/// Needle pointing up: rounded tip, widening to a round base centred on the pivot.
private struct NeedleShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        var p = Path()
        p.move(to: CGPoint(x: rect.midX - w * 0.09, y: rect.minY + w * 0.12))
        p.addQuadCurve(to: CGPoint(x: rect.midX + w * 0.09, y: rect.minY + w * 0.12), control: CGPoint(x: rect.midX, y: rect.minY - w * 0.06))
        p.addLine(to: CGPoint(x: rect.midX + w / 2, y: rect.maxY - w / 2))
        p.addArc(center: CGPoint(x: rect.midX, y: rect.maxY - w / 2), radius: w / 2, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        p.closeSubpath()
        return p
    }
}

// MARK: - Popup

/// Dedicated popup window: a live speedometer while running, then results compared to history.
struct SpeedTestPopup: View {
    @EnvironmentObject var m: Monitor
    @ObservedObject private var live = SpeedTestLive.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var history: (dl: Double?, ul: Double?, rpm: Double?, count: Int) = (nil, nil, nil, 0)
    @State private var intro: Double?          // start-of-test sweep overrides the needle briefly

    private enum Stage { case idle, connecting, download, upload, done }

    private var stage: Stage {
        if m.speedTestRunning {
            switch live.phase {
            case .download: return .download
            case .upload: return .upload
            default: return .connecting
            }
        }
        return m.lastSpeedTest != nil && m.lastSpeedTestError == nil ? .done : .idle
    }

    private var isUpload: Bool { stage == .upload }
    private var accent: [Color] { isUpload ? GaugeTheme.upload : GaugeTheme.download }

    private var gaugeMbps: Double {
        switch stage {
        case .download: return live.dl
        case .upload: return live.ul
        case .done: return m.lastSpeedTest?.dlMbps ?? 0
        default: return 0
        }
    }

    private var readout: String {
        switch stage {
        case .idle, .connecting: return "—"
        default: return Self.fmt(gaugeMbps)
        }
    }

    private var caption: String {
        switch stage {
        case .idle: return "Ready"
        case .connecting: return "Connecting…"
        case .download: return "Mbps · Download"
        case .upload: return "Mbps · Upload"
        case .done: return "Mbps · Download"
        }
    }

    var body: some View {
        VStack(spacing: 16) {
            header

            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [(accent.last ?? .green).opacity(stage == .idle ? 0.10 : 0.22), .clear],
                                         center: .center, startRadius: 10, endRadius: 190))
                    .frame(width: 380, height: 380)
                    .blur(radius: 8)
                SpeedGauge(fraction: intro ?? SpeedGauge.fraction(for: gaugeMbps),
                           colors: accent, needle: GaugeTheme.needle(isUpload),
                           readout: readout, caption: caption)
                    .frame(width: 290, height: 290)
                    .animation(reduceMotion ? .easeOut(duration: 0.25) : .spring(response: 0.55, dampingFraction: 0.68), value: intro ?? SpeedGauge.fraction(for: gaugeMbps))
                    .animation(.easeInOut(duration: 0.5), value: isUpload)
            }
            .frame(height: 290)
            .animation(.easeInOut(duration: 0.6), value: isUpload)

            HStack(spacing: 12) {
                PhaseStat(title: "Ping", icon: "timer", color: GaugeTheme.ping,
                          value: stage == .done ? m.lastSpeedTest?.baseRTT.map { String(format: "%.0f", $0) } : nil,
                          unit: "ms", active: stage == .connecting, note: stage == .done ? "idle latency" : nil)
                PhaseStat(title: "Download", icon: "arrow.down", color: GaugeTheme.download[0],
                          value: dlValue, unit: "Mbps", active: stage == .download,
                          note: stage == .done ? compare(m.lastSpeedTest?.dlMbps, history.dl) : nil)
                PhaseStat(title: "Upload", icon: "arrow.up", color: GaugeTheme.upload[0],
                          value: ulValue, unit: "Mbps", active: stage == .upload,
                          note: stage == .done ? compare(m.lastSpeedTest?.ulMbps, history.ul) : nil)
            }

            details
                .frame(minHeight: 112, alignment: .top)
                .animation(.easeInOut(duration: 0.35), value: stage)

            HStack {
                Text("Powered by Apple networkQuality").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Close") { NSApp.keyWindow?.close() }.keyboardShortcut(.cancelAction).buttonStyle(.appSecondary(.gray))
                Button(m.lastSpeedTest == nil && !m.speedTestRunning ? "Start test" : "Run again") {
                    Task { await m.runSpeedTest() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.app(.pink))
                .disabled(m.speedTestRunning)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onChange(of: live.phase) { _, new in
            if new == .connecting { sweepIntro() }
        }
        .onAppear { if live.phase == .connecting { sweepIntro() } }
        .task(id: m.lastSpeedTest?.id) {
            let excluding = m.lastSpeedTest?.id ?? -1
            history = await Blocking.run {
                let r = Database.shared.query("SELECT AVG(dl_mbps) dl, AVG(ul_mbps) ul, AVG(responsiveness) rpm, COUNT(*) n FROM speedtests WHERE id != ?", [excluding]).first
                return (r?.double("dl"), r?.double("ul"), r?.double("rpm"), r?.int("n") ?? 0)
            }
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "speedometer").font(.title2).foregroundStyle(.tint)
            Text("Speed Test").font(.title2.weight(.semibold))
            Spacer()
            if let c = m.current, c.connected {
                HStack(spacing: 6) {
                    Image(systemName: "wifi")
                    Text("\(c.ssid ?? "Wi-Fi") · \(c.band ?? "") ch \(c.channel ?? 0) · \(Fmt.dbm(c.rssi))")
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(.background.secondary))
            }
        }
    }

    private var dlValue: String? {
        switch stage {
        case .download, .upload: return Self.fmt(live.dl)
        case .done: return m.lastSpeedTest?.dlMbps.map(Self.fmt)
        default: return nil
        }
    }

    private var ulValue: String? {
        switch stage {
        case .upload: return Self.fmt(live.ul)
        case .done: return m.lastSpeedTest?.ulMbps.map(Self.fmt)
        default: return nil
        }
    }

    @ViewBuilder private var details: some View {
        switch stage {
        case .connecting, .download, .upload:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(stage == .upload ? "Measuring upload. Other traffic may slow down briefly."
                     : stage == .download ? "Measuring download, then upload. This takes about 30 seconds."
                     : "Finding the nearest Apple test server…")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
            .transition(.opacity)
        case .done:
            if let r = m.lastSpeedTest { results(r).transition(.opacity.combined(with: .move(edge: .bottom))) }
        case .idle:
            if let e = m.lastSpeedTestError {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
                    Text(e).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.10)))
            } else {
                Text("Measures download, upload, latency and bufferbloat against Apple's servers.")
                    .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity)
            }
        }
    }

    private func results(_ r: SpeedTestResult) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                if let g = r.bloatGrade {
                    HStack(spacing: 12) {
                        Text(g.rawValue).font(.system(size: 28, weight: .heavy, design: .rounded)).foregroundStyle(g.color).frame(width: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Bufferbloat · +\(Fmt.ms(r.bloatMs)) under load").font(.subheadline.weight(.semibold))
                            Text(g.meaning).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 12).fill(g.color.opacity(0.10)))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Label("Responsiveness", systemImage: "hare.fill").font(.caption).foregroundStyle(.blue)
                    Text(r.responsiveness.map { "\(Int($0)) RPM" } ?? "—").font(.title3.weight(.semibold)).monospacedDigit()
                    Text(rpmLabel(r.responsiveness) ?? " ").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(10)
                .frame(width: 170, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
            }
            HStack(alignment: .firstTextBaseline) {
                Text(verdict(r)).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("\(Fmt.time.string(from: r.ts)) · \(history.count > 0 ? "vs \(history.count) earlier" : "first test")")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    private func sweepIntro() {
        guard !reduceMotion else { return }
        intro = 0
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(30))
            intro = 1
            try? await Task.sleep(for: .milliseconds(650))
            intro = nil
        }
    }

    private func compare(_ v: Double?, _ avg: Double?) -> String? {
        guard let v, let avg, avg > 0 else { return nil }
        let diff = (v - avg) / avg * 100
        return String(format: "%@%.0f%% vs avg", diff >= 0 ? "▲ " : "▼ ", abs(diff))
    }

    private static func fmt(_ v: Double) -> String { String(format: v >= 100 ? "%.0f" : "%.1f", v) }

    private func rpmLabel(_ v: Double?) -> String? {
        guard let v else { return nil }
        return v >= 1000 ? "High — great for calls & gaming" : v >= 300 ? "Medium" : "Low — laggy under load"
    }

    private func verdict(_ r: SpeedTestResult) -> String {
        guard let dl = r.dlMbps else { return "" }
        switch dl {
        case 200...: return "Plenty for multiple 4K streams, large downloads and many users at once."
        case 50..<200: return "Good for 4K streaming, video calls and a busy household."
        case 15..<50: return "Fine for HD streaming and video calls; large downloads will take a while."
        case 5..<15: return "OK for browsing and SD video; video calls may struggle."
        default: return "Slow — browsing and calls will feel sluggish."
        }
    }
}

/// One of the Ping / Download / Upload tiles under the gauge; glows while its phase is running.
private struct PhaseStat: View {
    let title: String, icon: String, color: Color
    let value: String?, unit: String
    let active: Bool
    let note: String?
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.caption.weight(.bold))
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(color.opacity(0.15)))
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                if active {
                    Circle().fill(color).frame(width: 7, height: 7)
                        .opacity(pulse ? 0.25 : 1)
                        .animation(.easeInOut(duration: 0.7).repeatForever(), value: pulse)
                        .onAppear { pulse = true }
                        .onDisappear { pulse = false }
                }
            }
            .foregroundStyle(color)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value ?? "—")
                    .font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.snappy, value: value)
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            Text(note ?? " ").font(.caption2)
                .foregroundStyle(note?.hasPrefix("▼") == true ? Color.orange : note?.hasPrefix("▲") == true ? Color.green : Color.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(active ? color.opacity(0.10) : Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(active ? color.opacity(0.6) : .clear, lineWidth: 1.5))
        .animation(.easeInOut(duration: 0.3), value: active)
    }
}
