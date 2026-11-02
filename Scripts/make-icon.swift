#!/usr/bin/env swift
// Draws Mimamori's app icon at every size and packs it into Resources/AppIcon.icns: a paper
// lantern (chōchin) on a night sky, with 見 painted on it, lighting the code behind it, where a
// diff's hunk shows a line taken out and two put in. Drawn from shapes, so every size is sharp;
// small sizes keep fewer, bolder lines of code and leave out the lantern's ribs and character and
// the diff's + and −.
//
// Usage: swift Scripts/make-icon.swift [Resources/AppIcon.icns]

import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func radialGlow(_ stops: [(NSColor, CGFloat)], at center: CGPoint, radius: CGFloat) {
    NSGradient(colors: stops.map(\.0), atLocations: stops.map(\.1), colorSpace: .sRGB)!
        .draw(fromCenter: center, radius: 0, toCenter: center, radius: radius, options: [])
}

/// A line of code: its indent, then its tokens (length on the 824-point shape, syntax colour).
struct CodeLine {
    var indent: Int
    var tokens: [(CGFloat, NSColor)]
}

let keyword = color(0.98, 0.47, 0.66), function = color(0.45, 0.71, 1.0), string = color(1.0, 0.72, 0.42)
let identifier = color(0.86, 0.89, 0.96), number = color(0.76, 0.62, 1.0), comment = color(0.46, 0.52, 0.64)
let type = color(0.50, 0.86, 0.66)
let code: [CodeLine] = [
    CodeLine(indent: 0, tokens: [(90, keyword), (170, function), (50, identifier), (140, string)]),
    CodeLine(indent: 1, tokens: [(70, keyword), (110, identifier), (40, identifier), (200, string)]),
    CodeLine(indent: 1, tokens: [(60, keyword), (130, identifier), (200, function), (50, identifier)]),
    CodeLine(indent: 2, tokens: [(150, identifier), (230, string)]),
    CodeLine(indent: 2, tokens: [(100, keyword), (80, number), (180, identifier)]),
    CodeLine(indent: 1, tokens: [(40, identifier)]),
    CodeLine(indent: 1, tokens: [(340, comment)]),
    CodeLine(indent: 1, tokens: [(80, keyword), (150, type), (130, function), (90, identifier)]),
    CodeLine(indent: 2, tokens: [(120, identifier), (60, number), (200, string)]),
    CodeLine(indent: 2, tokens: [(90, keyword), (140, identifier), (60, number), (120, identifier)]),
    CodeLine(indent: 2, tokens: [(90, keyword), (140, identifier), (200, function), (60, identifier)]),
    CodeLine(indent: 2, tokens: [(150, identifier), (60, identifier), (210, string)]),
]

enum Change {
    case added, removed

    var color: NSColor { self == .added ? NSColor(srgbRed: 0.30, green: 0.88, blue: 0.50, alpha: 1)
                                        : NSColor(srgbRed: 1, green: 0.38, blue: 0.38, alpha: 1) }
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
    // At 64 px and under, thin lines and fine detail turn to mush: draw fewer and bolder.
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

    let x = rect.midX
    let y0 = rect.minY
    let center = CGPoint(x: x, y: y0 + 455 * k)
    let width: CGFloat = 330 * k, height: CGFloat = 360 * k
    // The lantern's light on the sky, under the code.
    radialGlow([(color(1, 0.72, 0.35, 0.40), 0), (color(1, 0.6, 0.25, 0.10), 0.5), (color(1, 0.5, 0.2, 0), 1)],
               at: center, radius: 470 * k)

    // The code, in a layer of its own so the light can fall off across it.
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    let gutter = rect.minX + 62 * k
    let left = rect.minX + 104 * k
    let top = y0 + 762 * k
    let pitch: CGFloat = small ? 96 * k : 56 * k
    let bar: CGFloat = small ? 46 * k : 24 * k
    // The hunk: a line taken out, two put in, under the lantern. Small sizes keep one of each,
    // clear of it, and colour the whole line.
    let changes: [Int: Change] = small ? [1: .removed, 6: .added] : [9: .removed, 10: .added, 11: .added]
    for (i, line) in (small ? Array(code.prefix(7)) : code).enumerated() {
        let y = top - CGFloat(i) * pitch
        var cursor = left + CGFloat(line.indent) * 60 * k
        let tokens = small ? [(line.tokens.reduce(0) { $0 + $1.0 } * 0.85, line.tokens[0].1)] : line.tokens
        let change = changes[i]
        if let change {
            // The line's band, from the gutter to just past its end, and its + or −.
            let end = min(cursor + tokens.reduce(0) { $0 + ($1.0 + 18) * k } + 12 * k, rect.maxX - 30 * k)
            let band = CGRect(x: rect.minX + 30 * k, y: y + bar / 2 - pitch * 0.42, width: end - rect.minX - 30 * k, height: pitch * 0.84)
            change.color.withAlphaComponent(small ? 0.45 : 0.26).setFill()
            NSBezierPath(roundedRect: band, xRadius: band.height * 0.3, yRadius: band.height * 0.3).fill()
            if !small {
                change.color.setFill()
                let mid = CGPoint(x: gutter, y: y + bar / 2), arm: CGFloat = 15 * k, thick: CGFloat = 8 * k
                NSBezierPath(roundedRect: CGRect(x: mid.x - arm, y: mid.y - thick / 2, width: arm * 2, height: thick),
                             xRadius: thick / 2, yRadius: thick / 2).fill()
                if change == .added {
                    NSBezierPath(roundedRect: CGRect(x: mid.x - thick / 2, y: mid.y - arm, width: thick, height: arm * 2),
                                 xRadius: thick / 2, yRadius: thick / 2).fill()
                }
            }
        }
        for (length, tint) in tokens {
            (small ? change?.color ?? tint : tint).setFill()
            let length = min(length * k, rect.maxX - 50 * k - cursor)
            guard length > 0 else { break }
            NSBezierPath(roundedRect: CGRect(x: cursor, y: y, width: length, height: bar), xRadius: bar / 2, yRadius: bar / 2).fill()
            cursor += length + 18 * k
        }
    }
    // Lit near the lantern and fading into the night towards the edges, a little warmed by it.
    cg.setBlendMode(.destinationIn)
    radialGlow([(color(1, 1, 1, 1), 0), (color(1, 1, 1, 0.95), 0.3), (color(1, 1, 1, 0.55), 0.65), (color(1, 1, 1, 0.2), 1)],
               at: center, radius: 600 * k)
    cg.setBlendMode(.sourceAtop)
    radialGlow([(color(1, 0.75, 0.4, 0.25), 0), (color(1, 0.65, 0.3, 0.08), 0.5), (color(1, 0.6, 0.3, 0), 1)],
               at: center, radius: 520 * k)
    cg.setBlendMode(.normal)
    cg.endTransparencyLayer()
    // A halo round the lantern, over the code.
    radialGlow([(color(1, 0.8, 0.45, 0.26), 0.5), (color(1, 0.7, 0.35, 0.12), 0.7), (color(1, 0.6, 0.3, 0), 1)],
               at: center, radius: 290 * k)

    // The lantern, lifted off the code by a soft shadow and a dark rim: a paper body lit from
    // within, dark caps at top and bottom, and the cord it hangs from.
    let wood = color(0.20, 0.13, 0.11)
    let body = NSBezierPath(ovalIn: CGRect(x: x - width / 2, y: center.y - height / 2, width: width, height: height))
    let caps = [center.y + height / 2 - 20 * k, center.y - height / 2 - 30 * k].map { capY in
        NSBezierPath(roundedRect: CGRect(x: x - width * 0.36, y: capY, width: width * 0.72, height: 50 * k), xRadius: 12 * k, yRadius: 12 * k)
    }
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -18 * k), blur: 46 * k, color: NSColor.black.withAlphaComponent(0.75).cgColor)
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    wood.setFill()
    body.fill()
    caps.forEach { $0.fill() }
    cg.endTransparencyLayer()
    cg.restoreGState()
    wood.setStroke()
    let cord = NSBezierPath()
    cord.lineWidth = 14 * k * weight
    cord.move(to: CGPoint(x: x, y: center.y + height / 2 + 20 * k))
    cord.line(to: CGPoint(x: x, y: rect.maxY))
    cord.stroke()
    cg.saveGState()
    body.addClip()
    radialGlow([(color(1, 0.97, 0.85), 0), (color(1, 0.78, 0.38), 0.55), (color(0.92, 0.42, 0.14), 1)],
               at: CGPoint(x: x, y: center.y + 12 * k), radius: height * 0.62)
    if !small {
        color(0.75, 0.32, 0.10, 0.45).setStroke()
        for rib in 1..<8 {
            let y = center.y - height / 2 + CGFloat(rib) * height / 8
            let line = NSBezierPath()
            line.lineWidth = 6 * k
            line.move(to: CGPoint(x: x - width / 2, y: y))
            line.line(to: CGPoint(x: x + width / 2, y: y))
            line.stroke()
        }
        // 見, "to watch", the first character of 見守り (mimamori), painted on the paper over the ribs.
        guard let mincho = NSFont(name: "HiraMinProN-W6", size: height * 0.5) else { fatalError("Hiragino Mincho not found") }
        let mi = NSAttributedString(string: "見", attributes: [.font: mincho, .foregroundColor: color(0.62, 0.10, 0.06, 0.88)])
        let box = mi.size()
        mi.draw(at: CGPoint(x: x - box.width / 2, y: center.y - box.height / 2))
    }
    cg.restoreGState()
    wood.withAlphaComponent(0.9).setStroke()
    body.lineWidth = (small ? 16 : 10) * k
    body.stroke()
    wood.setFill()
    caps.forEach { $0.fill() }
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
