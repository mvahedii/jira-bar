// Generates Resources/AppIcon.icns:  swift Scripts/make_icon.swift
import AppKit

func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
    let out = NSImage(size: image.size)
    out.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: image.size))
    color.set()
    NSRect(origin: .zero, size: image.size).fill(using: .sourceIn)
    out.unlockFocus()
    return out
}

func render(_ size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let inset = s * 0.085
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = rect.width * 0.225
    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    shadow.shadowBlurRadius = s * 0.025
    shadow.set()
    NSColor.black.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0.33, green: 0.58, blue: 1.0, alpha: 1),
                        NSColor(red: 0.34, green: 0.26, blue: 0.92, alpha: 1)])!.draw(in: path, angle: -55)

    let config = NSImage.SymbolConfiguration(pointSize: s * 0.44, weight: .semibold)
    if let symbol = NSImage(systemSymbolName: "text.badge.plus", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let white = tinted(symbol, .white)
        white.draw(at: NSPoint(x: (s - white.size.width) / 2, y: (s - white.size.height) / 2),
                   from: .zero, operation: .sourceOver, fraction: 1)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = "build/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: dir)
try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes { try render(px).write(to: URL(fileURLWithPath: "\(dir)/\(name).png")) }
print("iconset written to \(dir)")
