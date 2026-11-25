import SwiftUI
import Charts

// MARK: - Design system

enum Theme {
    /// Vivid two-stop gradients keyed by a base hue.
    static func gradient(_ c: Color) -> LinearGradient {
        LinearGradient(colors: [c, partner(c)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static func partner(_ c: Color) -> Color {
        switch c {
        case .blue: return .cyan
        case .green: return .mint
        case .mint: return .teal
        case .orange: return .yellow
        case .red: return .pink
        case .pink: return .purple
        case .purple: return .indigo
        case .indigo: return .blue
        case .teal: return .cyan
        case .cyan: return .blue
        case .yellow: return .orange
        default: return c.opacity(0.7)
        }
    }

    /// Ordered chart palette (bright and readable in both light and dark mode).
    static let palette: [Color] = [
        Color(red: 0.24, green: 0.56, blue: 1.00),   // electric blue
        Color(red: 0.16, green: 0.85, blue: 0.62),   // emerald
        Color(red: 1.00, green: 0.55, blue: 0.20),   // tangerine
        Color(red: 0.75, green: 0.36, blue: 1.00),   // violet
        Color(red: 1.00, green: 0.33, blue: 0.55),   // hot pink
        Color(red: 0.10, green: 0.80, blue: 0.95),   // aqua
        Color(red: 1.00, green: 0.80, blue: 0.20),   // sun
    ]

    /// Fixed colors for well-known series so they match across every chart.
    static func seriesColor(_ name: String, index: Int) -> Color {
        switch name {
        case "Download", "RSSI", "RSSI avg", "Wi-Fi", "Router": return palette[0]
        case "Upload", "Internet", "Max internet": return palette[2]
        case "DNS", "Memory", "SNR": return palette[3]
        case "Noise", "RSSI min": return palette[4]
        case "Tx rate", "Total", "CPU": return palette[5]
        case "Loss": return palette[4]
        default: return palette[index % palette.count]
        }
    }

    static let cardRadius: CGFloat = 18
}

/// Colorful ambient background behind every page (static: no animation cost).
struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            (scheme == .dark ? Color(red: 0.05, green: 0.06, blue: 0.11) : Color(red: 0.95, green: 0.96, blue: 0.99))
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                ZStack {
                    blob(Color(red: 0.25, green: 0.35, blue: 1.0), size: w * 0.7).position(x: w * 0.15, y: h * 0.05)
                    blob(Color(red: 0.70, green: 0.25, blue: 1.0), size: w * 0.55).position(x: w * 0.95, y: h * 0.25)
                    blob(Color(red: 0.05, green: 0.85, blue: 0.85), size: w * 0.6).position(x: w * 0.55, y: h * 0.95)
                    blob(Color(red: 1.0, green: 0.45, blue: 0.45), size: w * 0.35).position(x: w * 0.05, y: h * 0.75)
                }
                .drawingGroup() // rasterize the blurred blobs once instead of re-blurring every frame
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
    private func blob(_ c: Color, size: CGFloat) -> some View {
        Circle().fill(c.opacity(scheme == .dark ? 0.22 : 0.16)).frame(width: size, height: size).blur(radius: size * 0.28)
    }
}

/// Glass-look card. Uses a translucent solid fill instead of a live `Material` blur and draws the
/// shadow on the background shape only — both keep scrolling at full ProMotion frame rate.
struct GlassCard: ViewModifier {
    var tint: Color? = nil
    var padding: CGFloat = 14
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
        let dark = scheme == .dark
        return content
            .padding(padding)
            .background {
                shape
                    .fill(dark ? Color(red: 0.11, green: 0.12, blue: 0.19).opacity(0.82) : Color.white.opacity(0.78))
                    .overlay {
                        if let tint {
                            shape.fill(LinearGradient(colors: [tint.opacity(dark ? 0.20 : 0.12), .clear],
                                                      startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                    }
                    .overlay {
                        shape.strokeBorder(LinearGradient(colors: [.white.opacity(dark ? 0.16 : 0.8), .white.opacity(0.04)],
                                                          startPoint: .top, endPoint: .bottom), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(dark ? 0.30 : 0.07), radius: 8, y: 4)
            }
    }
}

extension View {
    func glassCard(tint: Color? = nil, padding: CGFloat = 14) -> some View { modifier(GlassCard(tint: tint, padding: padding)) }

    /// Standard scrolling dashboard page layout with the ambient background.
    func dashboardPage() -> some View {
        ScrollView {
            self.padding(.horizontal, 24).padding(.vertical, 20).frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
    }

    /// Glass container for native tables.
    func tableCard(_ title: String, icon: String, color: Color = .blue) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: title, icon: icon, color: color)
            self.scrollContentBackground(.hidden)
        }
        .glassCard()
    }
}

/// Rounded-square gradient icon (like System Settings).
struct IconBadge: View {
    let icon: String
    var color: Color = .blue
    var size: CGFloat = 26
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(Theme.gradient(color))
            .frame(width: size, height: size)
            .overlay(Image(systemName: icon).font(.system(size: size * 0.5, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: color.opacity(0.45), radius: 4, y: 2)
    }
}

struct CardTitle: View {
    let title: String
    let icon: String
    var color: Color = .blue
    var subtitle: String? = nil
    var body: some View {
        HStack(spacing: 10) {
            IconBadge(icon: icon, color: color, size: 24)
            Text(title).font(.headline)
            if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Building blocks

struct KPITile: View {
    let title: String
    let value: String
    var subtitle: String? = nil
    var icon: String
    var color: Color = .accentColor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                IconBadge(icon: icon, color: color, size: 26)
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [.primary, color], startPoint: .leading, endPoint: .trailing))
                .lineLimit(1).minimumScaleFactor(0.55)
                .monospacedDigit()
            if let subtitle {
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .glassCard(tint: color)
    }
}

struct InfoCard: View {
    let title: String
    let icon: String
    var color: Color = .blue
    let rows: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle(title: title, icon: icon, color: color)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                    HStack(alignment: .firstTextBaseline) {
                        Text(r.0).foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(r.1).font(.system(.callout, design: .monospaced).weight(.medium))
                            .multilineTextAlignment(.trailing).textSelection(.enabled)
                    }
                    .padding(.vertical, 6)
                    if i < rows.count - 1 { Divider().opacity(0.4) }
                }
            }
        }
        .glassCard(tint: color)
    }
}

struct ChartCard<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    var icon: String? = nil
    var color: Color? = nil
    var height: CGFloat = 200
    @ViewBuilder var content: () -> Content

    /// Picks an icon + color from the title so every card is distinct without per-call styling.
    private var style: (String, Color) {
        if let icon, let color { return (icon, color) }
        let t = title.lowercased()
        let table: [(String, String, Color)] = [
            ("loss", "exclamationmark.triangle.fill", .red), ("spike", "bolt.trianglebadge.exclamationmark.fill", .red),
            ("snr", "waveform", .purple), ("signal quality", "chart.bar.fill", .purple), ("signal", "cellularbars", .blue),
            ("rssi", "cellularbars", .blue), ("latency", "timer", .orange), ("throughput", "arrow.up.arrow.down", .green),
            ("usage", "chart.bar.xaxis", .green), ("data", "externaldrive.fill", .pink), ("availability", "checkmark.shield.fill", .mint),
            ("time per", "clock.fill", .teal), ("link", "bolt.fill", .yellow), ("weekly", "calendar", .pink),
            ("when", "calendar", .pink), ("app", "square.grid.2x2.fill", .indigo), ("channel", "dial.medium.fill", .cyan),
            ("security", "lock.fill", .red), ("width", "arrow.left.and.right", .teal), ("timeline", "calendar.day.timeline.left", .indigo),
            ("cpu", "cpu.fill", .purple), ("speed", "speedometer", .pink), ("device", "laptopcomputer.and.iphone", .mint),
            ("network", "wifi", .blue), ("band", "dot.radiowaves.left.and.right", .cyan), ("distribution", "chart.bar.fill", .purple),
        ]
        let hit = table.first { t.contains($0.0) }
        return (icon ?? hit?.1 ?? "chart.xyaxis.line", color ?? hit?.2 ?? .blue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardTitle(title: title, icon: style.0, color: style.1, subtitle: subtitle)
            content().frame(height: height)
        }
        .glassCard()
    }
}

struct SeriesPoint: Identifiable {
    let date: Date
    let value: Double
    let series: String
    var id: String { "\(series)|\(date.timeIntervalSinceReferenceDate)" }
}

/// Multi-series line chart with gradient area fills.
struct TimeLineChart: View {
    let points: [SeriesPoint]
    var unit: String
    var area: Bool = false
    var yDomain: ClosedRange<Double>? = nil

    var body: some View {
        if points.isEmpty {
            EmptyChart()
        } else {
            let names = orderedSeries
            let colors = names.enumerated().map { Theme.seriesColor($1, index: $0) }
            let single = names.count == 1
            let chart = Chart(points) { p in
                if area || single {
                    AreaMark(x: .value("Time", p.date), y: .value(unit, p.value), stacking: .unstacked)
                        .foregroundStyle(by: .value("Series", p.series))
                        .opacity(single ? 0.28 : 0.14)
                        .interpolationMethod(.monotone)
                }
                LineMark(x: .value("Time", p.date), y: .value(unit, p.value), series: .value("Series", p.series))
                    .foregroundStyle(by: .value("Series", p.series))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                if points.count < 6 {
                    PointMark(x: .value("Time", p.date), y: .value(unit, p.value)).foregroundStyle(by: .value("Series", p.series))
                }
            }
            .chartForegroundStyleScale(domain: names, range: colors)
            .chartYAxisLabel(unit)
            .chartLegend(single ? .hidden : .visible)
            .chartLegend(position: .top, alignment: .leading)
            .chartXAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(.secondary.opacity(0.15)); AxisValueLabel() } }
            .chartYAxis { AxisMarks { _ in AxisGridLine().foregroundStyle(.secondary.opacity(0.15)); AxisValueLabel() } }
            .chartHover { proxy, loc in
                guard let d: Date = proxy.value(atX: loc.x),
                      let anchor = ChartHoverKit.nearest(points, to: d, by: \.date) else { return nil }
                var tip = ChartTip(title: ChartHoverKit.date(anchor.date), guideX: proxy.position(forX: anchor.date))
                for (i, name) in names.enumerated() {
                    // nearest sample of this series, only if it's close to the anchor time
                    guard let p = ChartHoverKit.nearest(points.filter { $0.series == name }, to: anchor.date, by: \.date) else { continue }
                    let px = proxy.position(forX: p.date) ?? 0, ax = proxy.position(forX: anchor.date) ?? 0
                    guard abs(px - ax) < 12 else { continue }
                    tip.rows.append(.init(label: name, value: ChartHoverKit.value(p.value, unit: unit), color: colors[i]))
                    if let y = proxy.position(forY: p.value) { tip.dots.append((CGPoint(x: px, y: y), colors[i])) }
                }
                return tip
            }
            if let yDomain { chart.chartYScale(domain: yDomain) } else { chart }
        }
    }

    private var orderedSeries: [String] {
        var seen: [String] = []
        for p in points where !seen.contains(p.series) { seen.append(p.series) }
        return seen
    }
}

struct EmptyChart: View {
    var text = "No data for this filter yet"
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5, 4])).foregroundStyle(.secondary.opacity(0.3))
            VStack(spacing: 6) {
                Image(systemName: "chart.line.flattrend.xyaxis").font(.title2).foregroundStyle(.tertiary)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// Hour-of-day × weekday heatmap.
struct HeatmapView: View {
    let cells: [HeatCell]
    let format: (Double) -> String
    var invert = false // true when higher = worse

    private let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    var body: some View {
        if cells.isEmpty {
            EmptyChart()
        } else {
            let lo = cells.map(\.value).min() ?? 0
            let hi = cells.map(\.value).max() ?? 1
            Chart(cells) { c in
                RectangleMark(x: .value("Hour", "\(c.hour)"), y: .value("Day", days[c.weekday]), width: .ratio(0.9), height: .ratio(0.86))
                    .foregroundStyle(color(c.value, lo, hi))
                    .cornerRadius(4)
                    .annotation(position: .overlay) {
                        Text(format(c.value)).font(.system(size: 8, weight: .medium)).foregroundStyle(.white.opacity(0.9))
                    }
            }
            .chartXScale(domain: (0..<24).map { "\($0)" })
            .chartYScale(domain: days)
            .chartXAxisLabel("Hour of day")
            .chartHover { proxy, loc in
                guard let h: String = proxy.value(atX: loc.x), let day: String = proxy.value(atY: loc.y),
                      let wd = days.firstIndex(of: day), let c = cells.first(where: { "\($0.hour)" == h && $0.weekday == wd })
                else { return nil }
                return ChartTip(title: "\(day) · \(String(format: "%02d:00–%02d:00", c.hour, (c.hour + 1) % 24))",
                                rows: [.init(label: "Value", value: format(c.value), color: color(c.value, lo, hi))])
            }
        }
    }

    private func color(_ v: Double, _ lo: Double, _ hi: Double) -> Color {
        var t = hi > lo ? (v - lo) / (hi - lo) : 0.5
        if invert { t = 1 - t }
        // red → amber → green → aqua
        return Color(hue: 0.0 + 0.5 * t, saturation: 0.75, brightness: 0.92)
    }
}

/// Ranked breakdown list (apps, networks, APs…): name and value on one line, a slim gradient bar under it.
/// Rows have a fixed height and scroll inside the card, so long lists never overlap.
struct RankedBars: View {
    let groups: [UsageGroup]
    var value: (UsageGroup) -> Double = { $0.total }
    var label: (Double) -> String = { Fmt.bytes($0) }
    var limit = 12

    var body: some View {
        let top = Array(groups.prefix(limit)).filter { value($0) > 0 }
        if top.isEmpty {
            EmptyChart()
        } else {
            let maxV = top.map(value).max() ?? 1
            let sum = groups.map(value).reduce(0, +)
            ScrollView(.vertical) {
                VStack(spacing: 10) {
                    ForEach(Array(top.enumerated()), id: \.element.id) { i, g in
                        RankedBarRow(rank: i + 1, name: g.name, value: label(value(g)),
                                     share: sum > 0 ? value(g) / sum : nil,
                                     fraction: maxV > 0 ? value(g) / maxV : 0,
                                     color: Theme.palette[i % Theme.palette.count])
                    }
                }
                .padding(.trailing, 6)
            }
            .scrollIndicators(.automatic)
        }
    }
}

private struct RankedBarRow: View {
    let rank: Int
    let name: String
    let value: String
    let share: Double?
    let fraction: Double
    let color: Color
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text("\(rank)")
                    .font(.caption2.weight(.bold)).monospacedDigit()
                    .foregroundStyle(color)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(color.opacity(0.16)))
                Text(name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle).help(name)
                Spacer(minLength: 8)
                if let share { Text(String(format: "%.0f%%", share * 100)).font(.caption2).foregroundStyle(.tertiary).monospacedDigit() }
                Text(value).font(.callout.weight(.semibold)).monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.07))
                    Capsule().fill(LinearGradient(colors: [color, Theme.partner(color)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
            .padding(.leading, 28)
        }
        .padding(.vertical, 3).padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hover ? 0.05 : 0)))
        .onHover { hover = $0 }
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [Theme.palette[0], Theme.palette[3], Theme.palette[4]],
                                                startPoint: .leading, endPoint: .trailing))
            if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small group heading inside a page.
struct GroupHeading: View {
    let title: String
    var body: some View {
        Text(title.uppercased()).font(.caption.weight(.bold)).tracking(1.2).foregroundStyle(.secondary).padding(.top, 4)
    }
}

/// Capsule chip for small facts.
struct Chip: View {
    let text: String
    var icon: String? = nil
    var color: Color = .white
    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon) }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.18)))
        .overlay(Capsule().strokeBorder(color.opacity(0.35)))
    }
}

/// Colorful banner for warnings / calls to action.
struct Banner<Trailing: View>: View {
    let icon: String
    let title: String
    let message: String
    var color: Color = .orange
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 14) {
            IconBadge(icon: icon, color: color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            trailing()
        }
        .glassCard(tint: color)
    }
}

let kpiColumns = [GridItem(.adaptive(minimum: 180), spacing: 14)]
let cardColumns = [GridItem(.adaptive(minimum: 440), spacing: 18)]

/// Turns every `GroupBox` (table sections) into a glass card with a gradient badge.
struct GlassGroupBoxStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            configuration.label
                .labelStyle(BadgeLabelStyle())
            configuration.content.scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

struct BadgeLabelStyle: LabelStyle {
    var color: Color = .indigo
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.gradient(color)).frame(width: 24, height: 24)
                .overlay(configuration.icon.font(.system(size: 12, weight: .semibold)).foregroundStyle(.white))
                .shadow(color: color.opacity(0.4), radius: 3, y: 2)
            configuration.title.font(.headline)
        }
    }
}

// MARK: - Buttons

/// App-wide button look: gradient capsule with an icon badge feel, hover lift and press feedback.
struct AppButtonStyle: ButtonStyle {
    enum Kind { case prominent, secondary, onColor }
    var kind: Kind = .prominent
    var color: Color = .blue

    func makeBody(configuration: Configuration) -> some View {
        AppButtonBody(configuration: configuration, kind: kind, color: color)
    }

    private struct AppButtonBody: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let color: Color
        @Environment(\.isEnabled) private var enabled
        @Environment(\.colorScheme) private var scheme
        @State private var hover = false

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .labelStyle(AppButtonLabelStyle())
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background { Capsule().fill(fill).overlay(Capsule().strokeBorder(stroke, lineWidth: 1)) }
                .shadow(color: kind == .prominent ? color.opacity(hover ? 0.45 : 0.28) : .clear, radius: hover ? 8 : 5, y: 3)
                .brightness(pressed ? -0.08 : (hover ? 0.04 : 0))
                .scaleEffect(pressed ? 0.96 : 1)
                .opacity(enabled ? 1 : 0.5)
                .contentShape(Capsule())
                .onHover { hover = $0 && enabled }
                .animation(.easeOut(duration: 0.12), value: pressed)
                .animation(.easeOut(duration: 0.15), value: hover)
        }

        private var foreground: Color {
            switch kind {
            case .prominent, .onColor: return .white
            case .secondary: return scheme == .dark ? .white : color
            }
        }
        private var fill: AnyShapeStyle {
            switch kind {
            case .prominent: return AnyShapeStyle(Theme.gradient(color))
            case .onColor: return AnyShapeStyle(Color.white.opacity(hover ? 0.30 : 0.20))
            case .secondary: return AnyShapeStyle(color.opacity(hover ? 0.22 : 0.14))
            }
        }
        private var stroke: Color {
            switch kind {
            case .prominent: return .white.opacity(0.25)
            case .onColor: return .white.opacity(0.35)
            case .secondary: return color.opacity(0.35)
            }
        }
    }
}

private struct AppButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 12, weight: .bold))
            configuration.title
        }
    }
}

extension ButtonStyle where Self == AppButtonStyle {
    static func app(_ color: Color = .blue) -> AppButtonStyle { AppButtonStyle(kind: .prominent, color: color) }
    static func appSecondary(_ color: Color = .blue) -> AppButtonStyle { AppButtonStyle(kind: .secondary, color: color) }
    /// For buttons sitting on a colored hero/gradient background.
    static var appOnColor: AppButtonStyle { AppButtonStyle(kind: .onColor) }
}
