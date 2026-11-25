import SwiftUI
import Charts

/// What to show while the pointer hovers a chart: a tooltip, plus an optional guide line and highlight dots.
/// `guideX` and `dots` are in plot-area coordinates (as returned by `ChartProxy.position(...)`).
struct ChartTip {
    struct Row: Identifiable {
        let id = UUID()
        var label: String
        var value: String
        var color: Color? = nil
    }
    var title: String
    var rows: [Row] = []
    var guideX: CGFloat? = nil
    var dots: [(CGPoint, Color)] = []
}

extension View {
    /// Adds a hover tooltip to a Swift Charts chart. `resolve` gets the chart proxy and the pointer location
    /// in plot-area coordinates and returns what to show (or nil for nothing).
    func chartHover(_ resolve: @escaping (ChartProxy, CGPoint) -> ChartTip?) -> some View {
        modifier(ChartHoverModifier(resolve: resolve))
    }
}

private struct ChartHoverModifier: ViewModifier {
    let resolve: (ChartProxy, CGPoint) -> ChartTip?
    @State private var location: CGPoint?

    func body(content: Content) -> some View {
        content.chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotFrame.map { geo[$0] } ?? CGRect(origin: .zero, size: geo.size)
                ZStack(alignment: .topLeading) {
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let p): location = p
                            case .ended: location = nil
                            }
                        }
                    if let loc = location, plot.insetBy(dx: -4, dy: -4).contains(loc),
                       let tip = resolve(proxy, CGPoint(x: loc.x - plot.minX, y: loc.y - plot.minY)) {
                        overlay(tip, at: loc, plot: plot, size: geo.size)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func overlay(_ tip: ChartTip, at loc: CGPoint, plot: CGRect, size: CGSize) -> some View {
        if let gx = tip.guideX, gx >= 0, gx <= plot.width {
            Rectangle()
                .fill(Color.secondary.opacity(0.55))
                .frame(width: 1, height: plot.height)
                .position(x: plot.minX + gx, y: plot.midY)
                .allowsHitTesting(false)
        }
        ForEach(Array(tip.dots.enumerated()), id: \.offset) { _, d in
            Circle()
                .fill(d.1)
                .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                .frame(width: 9, height: 9)
                .position(x: plot.minX + d.0.x, y: plot.minY + d.0.y)
                .allowsHitTesting(false)
        }
        let right = loc.x > size.width / 2
        let below = loc.y > size.height / 2
        TipBox(tip: tip)
            .fixedSize()
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(width: size.width, height: size.height,
                   alignment: Alignment(horizontal: right ? .trailing : .leading, vertical: below ? .bottom : .top))
            .offset(x: right ? -(size.width - loc.x) : loc.x,
                    y: below ? -(size.height - loc.y) : loc.y)
            .allowsHitTesting(false)
    }
}

private struct TipBox: View {
    let tip: ChartTip
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(tip.title).font(.caption.weight(.semibold))
            ForEach(tip.rows) { r in
                HStack(spacing: 6) {
                    if let c = r.color { Circle().fill(c).frame(width: 7, height: 7) }
                    Text(r.label).foregroundStyle(.secondary)
                    Spacer(minLength: 10)
                    Text(r.value).monospacedDigit().fontWeight(.medium)
                }
                .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(minWidth: 120, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }
}

// MARK: - Helpers for resolving hovered data

enum ChartHoverKit {
    /// Item whose x date is closest to the hovered date.
    static func nearest<T>(_ items: [T], to date: Date, by key: (T) -> Date) -> T? {
        items.min { abs(key($0).timeIntervalSince(date)) < abs(key($1).timeIntervalSince(date)) }
    }

    /// Item whose plotted position is closest to the pointer, within `maxDistance` points.
    static func nearestInPlot<T>(_ items: [T], proxy: ChartProxy, at p: CGPoint, maxDistance: CGFloat = 24,
                                 position: (T) -> CGPoint?) -> T? {
        var best: (T, CGFloat)?
        for item in items {
            guard let q = position(item) else { continue }
            let d = hypot(q.x - p.x, q.y - p.y)
            if d <= maxDistance, d < (best?.1 ?? .infinity) { best = (item, d) }
        }
        return best?.0
    }

    static func date(_ d: Date) -> String { Fmt.dateTime.string(from: d) }

    static func value(_ v: Double, unit: String) -> String {
        let a = abs(v)
        let s = a >= 100 ? String(format: "%.0f", v) : a >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v)
        return unit.isEmpty ? s : "\(s) \(unit)"
    }
}
