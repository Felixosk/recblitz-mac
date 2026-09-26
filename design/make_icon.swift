// Generates design/AppIcon.icns: a waveform rising out of the water with a red
// record dot, on the same ocean background as the MeetingBlitz icon, so both
// apps read as one family. Run: swift design/make_icon.swift (from the project
// root; needs only Command Line Tools + iconutil)
import AppKit

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let hull = color(0x2EC7A0), glow = color(0x8EE6C8), foam = color(0xCFF5EA)
let red = color(0xF2554A), redDeep = color(0xC7372E)

func drawIcon(_ px: Int) -> NSBitmapImageRep {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gc
    let ctx = gc.cgContext

    // Big-Sur-style rounded square with a margin (same as MeetingBlitz).
    let inset = 0.085 * s
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = 0.225 * rect.width
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()

    // Ocean gradient background, identical to the MeetingBlitz icon.
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(0x18A9B4).cgColor, color(0x0A4E58).cgColor] as CFArray,
                          locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: rect.minX, y: rect.maxY),
                           end: CGPoint(x: rect.maxX, y: rect.minY), options: [])

    // Waveform: rounded bars, tallest in the middle, standing on the water.
    let waterY = rect.minY + 0.30 * rect.height
    let heights: [CGFloat] = [0.16, 0.28, 0.44, 0.58, 0.44, 0.30, 0.18]
    let barW = rect.width * 0.068
    let gap = rect.width * 0.040
    let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
    var x = rect.midX - total / 2 - rect.width * 0.03
    for (i, h) in heights.enumerated() {
        let height = h * rect.height
        let bar = CGRect(x: x, y: waterY - barW * 0.4, width: barW, height: height)
        let path = CGPath(roundedRect: bar, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 0.03 * s, color: glow.withAlphaComponent(0.55).cgColor)
        ctx.setFillColor((i % 2 == 0 ? hull : glow).cgColor)
        ctx.addPath(path); ctx.fillPath()
        ctx.restoreGState()
        x += barW + gap
    }

    // Water body with a wavy surface in the lower part.
    let amp = 0.016 * s
    let wave = CGMutablePath()
    wave.move(to: CGPoint(x: rect.minX, y: waterY))
    var wx = rect.minX
    while wx <= rect.maxX {
        let t = (wx - rect.minX) / rect.width
        wave.addLine(to: CGPoint(x: wx, y: waterY + sin(t * .pi * 3.2) * amp))
        wx += max(1, s / 200)
    }
    wave.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    wave.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    wave.closeSubpath()
    ctx.setFillColor(color(0x0C5A63, 0.92).cgColor)
    ctx.addPath(wave); ctx.fillPath()

    // Foam crest.
    ctx.setStrokeColor(foam.withAlphaComponent(0.75).cgColor)
    ctx.setLineWidth(max(1, 0.012 * s)); ctx.setLineCap(.round)
    wx = rect.minX
    ctx.move(to: CGPoint(x: wx, y: waterY))
    while wx <= rect.maxX {
        let t = (wx - rect.minX) / rect.width
        ctx.addLine(to: CGPoint(x: wx, y: waterY + sin(t * .pi * 3.2) * amp))
        wx += max(1, s / 200)
    }
    ctx.strokePath()

    // Red record dot, top right, with a soft ring.
    let d = rect.width * 0.20
    let dot = CGRect(x: rect.maxX - d - rect.width * 0.12, y: rect.maxY - d - rect.height * 0.12,
                     width: d, height: d)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.22).cgColor)
    ctx.fillEllipse(in: dot.insetBy(dx: -d * 0.16, dy: -d * 0.16))
    let rg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [red.cgColor, redDeep.cgColor] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: dot); ctx.clip()
    ctx.drawLinearGradient(rg, start: CGPoint(x: dot.midX, y: dot.maxY),
                           end: CGPoint(x: dot.midX, y: dot.minY), options: [])
    ctx.restoreGState()

    // Soft top highlight for depth.
    let hl = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor.white.withAlphaComponent(0.14).cgColor,
                                 NSColor.white.withAlphaComponent(0).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: rect.midX, y: rect.maxY),
                           end: CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.35), options: [])

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = "design/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
    ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in variants {
    let data = drawIcon(px).representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset, "-o", "design/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "OK design/AppIcon.icns" : "iconutil failed")
