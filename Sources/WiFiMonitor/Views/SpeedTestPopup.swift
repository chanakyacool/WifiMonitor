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

/// Dedicated popup window: live progress while running, then a results card compared to history.
struct SpeedTestPopup: View {
    @EnvironmentObject var m: Monitor
    @State private var history: (dl: Double?, ul: Double?, rpm: Double?, count: Int) = (nil, nil, nil, 0)

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Image(systemName: "speedometer").font(.title2).foregroundStyle(.tint)
                Text("Speed Test").font(.title2.weight(.semibold))
                Spacer()
                if let c = m.current, c.connected {
                    Text("\(c.ssid ?? "Wi-Fi") · \(c.band ?? "") ch \(c.channel ?? 0) · \(Fmt.dbm(c.rssi))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if m.speedTestRunning {
                running
            } else if let e = m.lastSpeedTestError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40)).foregroundStyle(.orange)
                    Text(e).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                .frame(height: 230)
            } else if let r = m.lastSpeedTest {
                results(r)
            } else {
                Text("Run a test to measure download, upload and responsiveness.")
                    .foregroundStyle(.secondary).frame(height: 230)
            }

            HStack {
                Text("Powered by Apple networkQuality").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Close") { NSApp.keyWindow?.close() }.keyboardShortcut(.cancelAction).buttonStyle(.appSecondary(.gray))
                Button(m.lastSpeedTest == nil && !m.speedTestRunning ? "Start" : "Run again") {
                    Task { await m.runSpeedTest() }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.app(.pink))
                .disabled(m.speedTestRunning)
            }
        }
        .padding(22)
        .frame(width: 560)
        .task(id: m.lastSpeedTest?.id) {
            let excluding = m.lastSpeedTest?.id ?? -1
            history = await Blocking.run {
                let r = Database.shared.query("SELECT AVG(dl_mbps) dl, AVG(ul_mbps) ul, AVG(responsiveness) rpm, COUNT(*) n FROM speedtests WHERE id != ?", [excluding]).first
                return (r?.double("dl"), r?.double("ul"), r?.double("rpm"), r?.int("n") ?? 0)
            }
        }
    }

    private var running: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let elapsed = ctx.date.timeIntervalSince(m.speedTestStarted ?? ctx.date)
            VStack(spacing: 14) {
                ZStack {
                    Circle().stroke(.quaternary, lineWidth: 10)
                    Circle().trim(from: 0, to: min(0.97, elapsed / 22))
                        .stroke(AngularGradient(colors: [.cyan, .blue, .green], center: .center), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.5), value: elapsed)
                    VStack(spacing: 2) {
                        Text("\(Int(elapsed)) s").font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                        Text(elapsed < 11 ? "Testing download…" : "Testing upload…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 170, height: 170)
                Text("Saturating your connection for ~20 seconds. Other traffic may slow down briefly.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(height: 230)
        }
    }

    private func results(_ r: SpeedTestResult) -> some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                bigStat("Download", r.dlMbps, unit: "Mbps", icon: "arrow.down.circle.fill", color: .green, avg: history.dl)
                bigStat("Upload", r.ulMbps, unit: "Mbps", icon: "arrow.up.circle.fill", color: .orange, avg: history.ul)
            }
            if let g = r.bloatGrade {
                HStack(spacing: 12) {
                    Text(g.rawValue).font(.system(size: 30, weight: .heavy, design: .rounded)).foregroundStyle(g.color).frame(width: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bufferbloat · +\(Fmt.ms(r.bloatMs)) under load").font(.headline)
                        Text(g.meaning).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(g.color.opacity(0.10)))
            }
            HStack(spacing: 14) {
                small("Responsiveness", r.responsiveness.map { "\(Int($0)) RPM" } ?? "—", sub: rpmLabel(r.responsiveness), icon: "hare.fill", color: .blue)
                small("Base latency", Fmt.ms(r.baseRTT), sub: "idle round-trip", icon: "timer", color: .indigo)
                small("Tested", Fmt.time.string(from: r.ts), sub: history.count > 0 ? "vs \(history.count) earlier tests" : "first test", icon: "clock", color: .gray)
            }
            Text(verdict(r)).font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func bigStat(_ title: String, _ v: Double?, unit: String, icon: String, color: Color, avg: Double?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).foregroundStyle(color).font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(v.map { String(format: $0 >= 100 ? "%.0f" : "%.1f", $0) } ?? "—")
                    .font(.system(size: 46, weight: .bold, design: .rounded)).monospacedDigit()
                Text(unit).foregroundStyle(.secondary)
            }
            if let v, let avg, avg > 0 {
                let diff = (v - avg) / avg * 100
                Text(String(format: "%@%.0f%% vs your average (%.0f)", diff >= 0 ? "▲ " : "▼ ", abs(diff), avg))
                    .font(.caption).foregroundStyle(diff >= -10 ? .green : .orange)
            } else {
                Text(" ").font(.caption)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.10)))
    }

    private func small(_ title: String, _ value: String, sub: String?, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(color)
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(sub ?? " ").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }

    private func rpmLabel(_ v: Double?) -> String? {
        guard let v else { return nil }
        return v >= 1000 ? "High — great for calls & gaming" : v >= 300 ? "Medium" : "Low — laggy under load"
    }

    private func verdict(_ r: SpeedTestResult) -> String {
        guard let dl = r.dlMbps else { return "" }
        let uses: String
        switch dl {
        case 200...: uses = "Plenty for multiple 4K streams, large downloads and many users at once."
        case 50..<200: uses = "Good for 4K streaming, video calls and a busy household."
        case 15..<50: uses = "Fine for HD streaming and video calls; large downloads will take a while."
        case 5..<15: uses = "OK for browsing and SD video; video calls may struggle."
        default: uses = "Slow — browsing and calls will feel sluggish."
        }
        return uses
    }
}
