#!/usr/bin/env swift
// Draws Mimamori's app icon at every size and packs it into Resources/AppIcon.icns: a paper
// lantern (chōchin) hung over a branch graph, the worktrees it watches over, on a night sky.
// Drawn from shapes, so every size is sharp; small sizes get bolder lines and solid branch ends,
// and leave out the lantern's ribs.
//
// Usage: swift Scripts/make-icon.swift [Resources/AppIcon.icns]

import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func circle(_ center: CGPoint, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
}

func radialGlow(_ stops: [(NSColor, CGFloat)], at center: CGPoint, radius: CGFloat) {
    NSGradient(colors: stops.map(\.0), atLocations: stops.map(\.1), colorSpace: .sRGB)!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}

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
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: canvas, height: canvas).fill(using: .copy)

    // The macOS icon grid: the shape occupies 824 of a 1024 canvas with ~185pt corners.
    // (macOS 26 masks it to its own shape and adds the glass rim.)
    let inset = canvas * (100.0 / 1024.0)
    let rect = CGRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset)
    let radius = rect.width * (185.4 / 824.0)
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    // Everything below is laid out on the 824-point shape.
    let k = rect.width / 824
    // At 64 px and under, thin lines and hollow ends turn to mush: draw them bolder and solid.
    let small = canvas <= 64
    let weight: CGFloat = small ? 1.7 : 1

    // Drop shadow under the shape.
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -canvas * 0.012), blur: canvas * 0.035,
                 color: NSColor.black.withAlphaComponent(0.4).cgColor)
    color(0.04, 0.05, 0.11).setFill()
    shape.fill()
    cg.restoreGState()

    cg.saveGState()
    shape.addClip()
    // Night sky.
    NSGradient(starting: color(0.15, 0.17, 0.34), ending: color(0.04, 0.05, 0.11))!.draw(in: rect, angle: -90)

    // The branch graph: a trunk, and a branch off to each side, each ending in a dot.
    let x = rect.midX
    let y0 = rect.minY
    let root = CGPoint(x: x, y: y0 + 130 * k)
    let left = CGPoint(x: x - 215 * k, y: y0 + 385 * k)
    let right = CGPoint(x: x + 215 * k, y: y0 + 430 * k)
    let top = CGPoint(x: x, y: y0 + 470 * k)
    let blue = color(0.56, 0.68, 0.98)
    blue.setStroke()
    func stroke(_ path: NSBezierPath) {
        path.lineWidth = 34 * k * weight
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
    let trunk = NSBezierPath()
    trunk.move(to: root)
    trunk.line(to: top)
    stroke(trunk)
    let leftBranch = NSBezierPath()
    leftBranch.move(to: CGPoint(x: x, y: y0 + 215 * k))
    leftBranch.curve(to: left, controlPoint1: CGPoint(x: x, y: y0 + 300 * k), controlPoint2: CGPoint(x: left.x, y: y0 + 270 * k))
    stroke(leftBranch)
    let rightBranch = NSBezierPath()
    rightBranch.move(to: CGPoint(x: x, y: y0 + 265 * k))
    rightBranch.curve(to: right, controlPoint1: CGPoint(x: x, y: y0 + 350 * k), controlPoint2: CGPoint(x: right.x, y: y0 + 320 * k))
    stroke(rightBranch)
    blue.setFill()
    for end in [root, left, right] { circle(end, 44 * k * (small ? 1.25 : 1)).fill() }
    if !small {
        color(0.04, 0.05, 0.11).setFill()
        for end in [root, left, right] { circle(end, 20 * k).fill() }
    }

    // The lantern at the top of the trunk, its glow over the branches: a paper body lit from
    // within, dark caps at top and bottom, and the cord it hangs from.
    let center = CGPoint(x: x, y: y0 + 600 * k)
    let width: CGFloat = 250 * k, height: CGFloat = 270 * k
    radialGlow([(color(1, 0.72, 0.35, 0.55), 0), (color(1, 0.6, 0.25, 0.14), 0.5), (color(1, 0.5, 0.2, 0), 1)],
               at: center, radius: 360 * k)
    let wood = color(0.20, 0.13, 0.11)
    wood.setStroke()
    let cord = NSBezierPath()
    cord.lineWidth = 12 * k * weight
    cord.move(to: CGPoint(x: x, y: center.y + height / 2 + 20 * k))
    cord.line(to: CGPoint(x: x, y: rect.maxY))
    cord.stroke()
    let body = NSBezierPath(ovalIn: CGRect(x: x - width / 2, y: center.y - height / 2, width: width, height: height))
    cg.saveGState()
    body.addClip()
    radialGlow([(color(1, 0.97, 0.85), 0), (color(1, 0.78, 0.38), 0.55), (color(0.92, 0.42, 0.14), 1)],
               at: CGPoint(x: x, y: center.y + 10 * k), radius: height * 0.62)
    if !small {
        color(0.75, 0.32, 0.10, 0.45).setStroke()
        for rib in 1..<7 {
            let y = center.y - height / 2 + CGFloat(rib) * height / 7
            let line = NSBezierPath()
            line.lineWidth = 5 * k
            line.move(to: CGPoint(x: x - width / 2, y: y))
            line.line(to: CGPoint(x: x + width / 2, y: y))
            line.stroke()
        }
    }
    cg.restoreGState()
    wood.setFill()
    for capY in [center.y + height / 2 - 16 * k, center.y - height / 2 - 24 * k] {
        NSBezierPath(roundedRect: CGRect(x: x - width * 0.36, y: capY, width: width * 0.72, height: 40 * k),
                     xRadius: 10 * k, yRadius: 10 * k).fill()
    }
    cg.restoreGState()
    return rep
}

let iconsetURL = URL(fileURLWithPath: "build/Mimamori.iconset", isDirectory: true)
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
print("Wrote \(output.path)")
