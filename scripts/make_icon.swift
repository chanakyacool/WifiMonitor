// Renders Resources/AppIcon.icns. Run: swift scripts/make_icon.swift
import AppKit

func render(_ size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size / 1024

    // macOS icon grid: 824pt squircle centered in 1024 canvas, with soft shadow.
    let rect = CGRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * s), blur: 28 * s, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill(); squircle.fill()
    ctx.restoreGState()

    squircle.addClip()
    NSGradient(colors: [NSColor(red: 0.07, green: 0.12, blue: 0.36, alpha: 1),
                        NSColor(red: 0.13, green: 0.35, blue: 0.86, alpha: 1),
                        NSColor(red: 0.10, green: 0.78, blue: 0.92, alpha: 1)])!.draw(in: rect, angle: 65)
    // subtle top sheen
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.18), NSColor.white.withAlphaComponent(0)])!
        .draw(in: CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)

    // Lightning bolt whose tip strikes the pulse line below (the live network signal).
    let boltPts: [(CGFloat, CGFloat)] = [(600, 880), (345, 545), (492, 545), (440, 328), (700, 660), (548, 660)]
    let bolt = CGMutablePath()
    bolt.move(to: CGPoint(x: boltPts[0].0 * s, y: boltPts[0].1 * s))
    for p in boltPts.dropFirst() { bolt.addLine(to: CGPoint(x: p.0 * s, y: p.1 * s)) }
    bolt.closeSubpath()
    // glow
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 60 * s, color: NSColor(red: 1.0, green: 0.78, blue: 0.25, alpha: 0.85).cgColor)
    ctx.addPath(bolt); ctx.setFillColor(NSColor(red: 1.0, green: 0.8, blue: 0.3, alpha: 1).cgColor); ctx.fillPath()
    ctx.restoreGState()
    // gradient body
    ctx.saveGState()
    ctx.addPath(bolt); ctx.clip()
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [NSColor(red: 1.0, green: 0.97, blue: 0.62, alpha: 1).cgColor,
                                   NSColor(red: 1.0, green: 0.78, blue: 0.22, alpha: 1).cgColor,
                                   NSColor(red: 1.0, green: 0.50, blue: 0.14, alpha: 1).cgColor] as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 520 * s, y: 880 * s), end: CGPoint(x: 470 * s, y: 330 * s), options: [])
    ctx.restoreGState()
    // crisp edge
    ctx.addPath(bolt)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
    ctx.setLineWidth(10 * s); ctx.setLineJoin(.round)
    ctx.strokePath()

    // Monitoring pulse line along the bottom
    let pulse = CGMutablePath()
    let base = 235 * s
    let pts: [(CGFloat, CGFloat)] = [(170, 0), (345, 0), (392, -55), (440, 95), (500, -80), (548, 35), (585, 0), (854, 0)]
    pulse.move(to: CGPoint(x: pts[0].0 * s, y: base + pts[0].1 * s))
    for p in pts.dropFirst() { pulse.addLine(to: CGPoint(x: p.0 * s, y: base + p.1 * s)) }
    ctx.addPath(pulse)
    ctx.setLineJoin(.round)
    ctx.setLineCap(.round)
    ctx.setLineWidth(30 * s)
    ctx.setStrokeColor(NSColor(red: 0.35, green: 1.0, blue: 0.65, alpha: 1).cgColor)
    ctx.setShadow(offset: .zero, blur: 18 * s, color: NSColor(red: 0.35, green: 1.0, blue: 0.65, alpha: 0.8).cgColor)
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! render(px).representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
try! render(1024).representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent("AppIcon-1024.png"))
print("iconset written")
