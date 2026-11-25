import AppKit
import SwiftUI

/// Compact borderless menu bar item: a lightning bolt (status) plus live speed.
/// Modes (Settings): "both" = ↑ upload over ↓ download, "busier" = only the busier direction, "off" = bolt only.
struct MenuBarLabel: View {
    @EnvironmentObject var m: Monitor
    @AppStorage("menuBarSpeed") private var mode = "both"
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if mode == "off" {
                Image(systemName: m.menuIcon)
            } else {
                Image(nsImage: MenuBarIcon.image(symbol: m.menuIcon, down: rates.down, up: rates.up, busierOnly: mode == "busier"))
            }
        }
        // The label lives as long as the app, so the Dock icon can always reopen the dashboard through it.
        .onAppear { AppDelegate.openMain = { openWindow(id: "main") } }
    }

    /// Current throughput in bits/s; uses Ethernet counters when the Mac is on a wired link.
    private var rates: (down: Double?, up: Double?) {
        guard let c = m.current else { return (nil, nil) }
        if m.linkState?.link == "Ethernet", let rx = c.ethRxBytes, let tx = c.ethTxBytes {
            let dt = Prefs.sampleInterval
            return (Double(rx) * 8 / dt, Double(tx) * 8 / dt)
        }
        return (c.rxBps, c.txBps)
    }
}

enum MenuBarIcon {
    static func rate(_ bps: Double?) -> String {
        guard let v = bps else { return "– Kb/s" }
        switch v {
        case 1e9...: return String(format: "%.2f Gb/s", v / 1e9)
        case 100e6...: return String(format: "%.0f Mb/s", v / 1e6)
        case 1e6...: return String(format: "%.1f Mb/s", v / 1e6)
        default: return String(format: "%.0f Kb/s", v / 1e3)
        }
    }

    static func image(symbol: String, down: Double?, up: Double?, busierOnly: Bool) -> NSImage {
        let height: CGFloat = 22
        let small = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        let single = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        let font = busierOnly ? single : small
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let sep = "\u{2009}"  // thin space between arrow and value
        // Width hugs the text actually shown so there's no trailing gap in the menu bar.
        let upBusier = (up ?? 0) > (down ?? 0)
        let shown = busierOnly ? [upBusier ? rate(up) : rate(down)] : [rate(up), rate(down)]
        let textW = ceil(shown.map { ("↓" + sep + $0 as NSString).size(withAttributes: attrs).width }.max() ?? 0)
        let bolt = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        let boltSize = bolt?.size ?? NSSize(width: 10, height: 14)
        let gap: CGFloat = 2
        let size = NSSize(width: ceil(boltSize.width) + gap + textW, height: height)

        // Drawn at display time, so `labelColor` follows the menu bar's current light/dark look;
        // only the arrows carry color (upload = orange, download = green).
        let upColor = NSColor(red: 1.0, green: 0.62, blue: 0.22, alpha: 1)
        let downColor = NSColor(red: 0.25, green: 0.88, blue: 0.55, alpha: 1)
        let img = NSImage(size: size, flipped: false) { _ in
            let text = NSColor.labelColor
            if let b = bolt?.withSymbolConfiguration(.init(paletteColors: [text.withAlphaComponent(1)])) {
                b.draw(in: NSRect(x: 0, y: (height - boltSize.height) / 2, width: boltSize.width, height: boltSize.height))
            }
            let x = ceil(boltSize.width) + gap
            func line(_ arrow: String, _ color: NSColor, _ value: String) -> NSAttributedString {
                let s = NSMutableAttributedString(string: arrow, attributes: [.font: font, .foregroundColor: color])
                s.append(NSAttributedString(string: sep + value, attributes: [.font: font, .foregroundColor: text]))
                return s
            }
            if busierOnly {
                let s = upBusier ? line("↑", upColor, rate(up)) : line("↓", downColor, rate(down))
                s.draw(at: NSPoint(x: x, y: (height - s.size().height) / 2))
            } else {
                let lineH = (" " as NSString).size(withAttributes: attrs).height
                line("↑", upColor, rate(up)).draw(at: NSPoint(x: x, y: height / 2 - 1))
                line("↓", downColor, rate(down)).draw(at: NSPoint(x: x, y: height / 2 - lineH + 1))
            }
            return true
        }
        img.isTemplate = false
        img.accessibilityDescription = "Download \(rate(down)), upload \(rate(up))"
        return img
    }
}
