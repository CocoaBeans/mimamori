#!/usr/bin/env swift
// Renders an emoji on a macOS-style rounded background at every icon size and
// packs the result into Resources/AppIcon.icns. A placeholder until a real icon exists.
//
// Usage: swift Scripts/make-icon.swift ["🕯️"] [Resources/AppIcon.icns]

import AppKit

let arguments = CommandLine.arguments
let emoji = arguments.count > 1 ? arguments[1] : "🕯️"
let outputPath = arguments.count > 2 ? arguments[2] : "Resources/AppIcon.icns"

func render(canvas: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(canvas)
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        fatalError("Could not allocate bitmap")
    }
    rep.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("No graphics context") }
    NSGraphicsContext.current = context
    let cg = context.cgContext
    cg.setAllowsAntialiasing(true)
    cg.setShouldSmoothFonts(true)

    // The macOS icon grid: the shape occupies 824 of a 1024 canvas with ~185pt corners.
    let inset = canvas * (100.0 / 1024.0)
    let rect = CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
    let radius = rect.width * (185.4 / 824.0)
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Drop shadow under the shape.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -canvas * 0.012), blur: canvas * 0.035,
                 color: NSColor.black.withAlphaComponent(0.4).cgColor)
    NSColor(red: 0.08, green: 0.09, blue: 0.18, alpha: 1).setFill()
    shape.fill()
    cg.restoreGState()

    // Night-sky gradient with a warm glow behind the flame.
    cg.saveGState()
    shape.addClip()
    NSGradient(colors: [
        NSColor(red: 0.20, green: 0.21, blue: 0.42, alpha: 1),
        NSColor(red: 0.06, green: 0.06, blue: 0.14, alpha: 1),
    ])!.draw(in: rect, angle: -90)
    let glowCenter = NSPoint(x: rect.midX, y: rect.midY + rect.height * 0.16)
    NSGradient(colorsAndLocations:
        (NSColor(red: 1.0, green: 0.78, blue: 0.40, alpha: 0.60), 0.0),
        (NSColor(red: 1.0, green: 0.62, blue: 0.25, alpha: 0.18), 0.45),
        (NSColor(red: 1.0, green: 0.55, blue: 0.20, alpha: 0.0), 1.0))!
        .draw(fromCenter: glowCenter, radius: 0, toCenter: glowCenter, radius: rect.width * 0.46, options: [])

    // The emoji itself. The system font falls back to Apple Color Emoji.
    let font = NSFont.systemFont(ofSize: rect.height * 0.60)
    let text = NSAttributedString(string: emoji, attributes: [.font: font])
    let textSize = text.size()
    let origin = NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2 - rect.height * 0.015)
    text.draw(at: origin)
    cg.restoreGState()
    return rep
}

let iconsetURL = URL(fileURLWithPath: "build/Vigil.iconset", isDirectory: true)
try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let entries: [(String, CGFloat)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in entries {
    let rep = render(canvas: size)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
    try data.write(to: iconsetURL.appendingPathComponent(name))
}

let output = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetURL.path, "-o", output.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed with status \(iconutil.terminationStatus)") }
print("Wrote \(output.path) from \(emoji)")
