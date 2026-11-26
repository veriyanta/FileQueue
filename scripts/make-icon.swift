// Draws the FileQueue app icon and builds Assets/AppIcon.icns.
// Run:  swift scripts/make-icon.swift            (from the FileQueue folder)
//       swift scripts/make-icon.swift preview.png (also writes a 1024 px preview)
import AppKit
import CoreGraphics
import Foundation

/// Everything is drawn on a 1024×1024 grid and scaled, so every size is sharp.
func drawIcon(_ ctx: CGContext, size: CGFloat) {
    let s = size / 1024
    ctx.scaleBy(x: s, y: s)
    let space = CGColorSpaceCreateDeviceRGB()
    func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }
    func rounded(_ r: CGRect, _ radius: CGFloat) -> CGPath {
        CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    // Body: the standard macOS icon shape (824 pt square, centred), with a soft shadow.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = rounded(body, 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.30))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x3B5BDB))
    ctx.fillPath()
    ctx.restoreGState()

    // Gradient: indigo (top-left) → teal (bottom-right).
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [color(0x5C7CFA), color(0x3B5BDB), color(0x0CA5BE)] as CFArray,
                              locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 160, y: 924), end: CGPoint(x: 880, y: 100), options: [])
    // A gentle highlight across the top.
    let shine = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    /// A folder: a tab on the top-left and a rounded body.
    func folder(_ r: CGRect, fill: CGColor, tabFill: CGColor, shadow: Bool) {
        ctx.saveGState()
        if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x0B1E66, 0.35)) }
        let tab = CGRect(x: r.minX, y: r.maxY - 30, width: r.width * 0.40, height: 70)
        ctx.addPath(rounded(tab, 26))
        ctx.setFillColor(tabFill)
        ctx.fillPath()
        ctx.addPath(rounded(r, 42))
        ctx.setFillColor(fill)
        ctx.fillPath()
        ctx.restoreGState()
    }

    // Back folder (the source), then the front folder (the destination), offset to suggest movement.
    folder(CGRect(x: 214, y: 470, width: 430, height: 300), fill: color(0xFFFFFF, 0.42), tabFill: color(0xFFFFFF, 0.42), shadow: false)
    folder(CGRect(x: 360, y: 400, width: 450, height: 315), fill: color(0xFFFFFF), tabFill: color(0xE7ECFF), shadow: true)

    // Arrow on the front folder: things moving in.
    ctx.saveGState()
    ctx.setStrokeColor(color(0x3B5BDB))
    ctx.setLineWidth(34)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: 470, y: 557)); ctx.addLine(to: CGPoint(x: 680, y: 557))
    ctx.move(to: CGPoint(x: 612, y: 625)); ctx.addLine(to: CGPoint(x: 684, y: 557)); ctx.addLine(to: CGPoint(x: 612, y: 489))
    ctx.strokePath()
    ctx.restoreGState()

    // The queue: three lanes with progress, as in the app's queue panel.
    let lanes: [(CGFloat, CGFloat, UInt32)] = [(320, 0.78, 0xFFD43B), (262, 0.48, 0x69DB7C), (204, 0.92, 0xFFA94D)]
    for (y, progress, accent) in lanes {
        let track = CGRect(x: 214, y: y, width: 596, height: 36)
        ctx.addPath(rounded(track, 18))
        ctx.setFillColor(color(0xFFFFFF, 0.28))
        ctx.fillPath()
        ctx.addPath(rounded(CGRect(x: track.minX, y: track.minY, width: track.width * progress, height: track.height), 18))
        ctx.setFillColor(color(accent))
        ctx.fillPath()
    }
}

func png(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let gc = NSGraphicsContext(bitmapImageRep: rep)!
    gc.imageInterpolation = .high
    let ctx = gc.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.setShouldAntialias(true)
    drawIcon(ctx, size: CGFloat(size))
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let root = URL(fileURLWithPath: fm.currentDirectoryPath)
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let assets = root.appendingPathComponent("Assets")
try fm.createDirectory(at: assets, withIntermediateDirectories: true)
let output = assets.appendingPathComponent("AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
try? fm.removeItem(at: iconset)
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("Wrote \(output.path)")
if CommandLine.arguments.count > 1 {
    let preview = URL(fileURLWithPath: CommandLine.arguments[1])
    try png(size: 1024).write(to: preview)
    print("Wrote preview \(preview.path)")
}
