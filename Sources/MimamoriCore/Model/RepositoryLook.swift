import CoreGraphics
import Foundation
import ImageIO

/// The color that marks a repository wherever it appears: its monogram, the tag on its agents'
/// rows. One of the system's named colors, so it reads in light and dark and in the widgets.
public enum RepositoryColor: String, CaseIterable, Codable, Sendable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown

    public var title: String { rawValue.capitalized }

    /// Roughly the system color's hue, for matching an icon's color to the nearest one.
    var hue: Double {
        switch self {
        case .red: 0.01
        case .orange: 0.09
        case .yellow: 0.14
        case .green: 0.37
        case .mint: 0.48
        case .teal: 0.52
        case .cyan: 0.55
        case .blue: 0.59
        case .indigo: 0.67
        case .purple: 0.78
        case .pink: 0.95
        case .brown: 0.08
        }
    }

    /// A color picked from the repository's name, the same on every Mac. Brown stays out: it
    /// looks muddy beside the others unless an icon calls for it.
    public static func automatic(for name: String) -> RepositoryColor {
        // FNV-1a: Swift's own hash is seeded differently on every launch.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100_0000_01b3
        }
        let choices = allCases.filter { $0 != .brown }
        return choices[Int(hash % UInt64(choices.count))]
    }

    /// The color nearest a pixel's, or nil for one too gray or dark to call.
    static func nearest(hue: Double, saturation: Double, brightness: Double) -> RepositoryColor? {
        guard saturation >= 0.25, brightness >= 0.25 else { return nil }
        let match = allCases.filter { $0 != .brown }.min { a, b in
            circularDistance(a.hue, hue) < circularDistance(b.hue, hue)
        }!
        return (match == .orange || match == .yellow) && brightness < 0.55 ? .brown : match
    }

    private static func circularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 1 - d)
    }

    /// The color most of an image's colorful pixels are nearest, or nil when it is mostly gray.
    public static func dominant(in url: URL) -> RepositoryColor? {
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 64]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return dominant(in: image)
    }

    static func dominant(in image: CGImage) -> RepositoryColor? {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }
        // Each pixel votes for its nearest color, the more vivid the louder.
        var votes: [RepositoryColor: Double] = [:]
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let alpha = Double(pixels[i + 3]) / 255
            guard alpha > 0.5 else { continue }
            let r = Double(pixels[i]) / 255 / alpha, g = Double(pixels[i + 1]) / 255 / alpha, b = Double(pixels[i + 2]) / 255 / alpha
            let maximum = max(r, g, b), minimum = min(r, g, b)
            let saturation = maximum > 0 ? (maximum - minimum) / maximum : 0
            guard let color = nearest(hue: hue(r, g, b, maximum: maximum, minimum: minimum),
                                      saturation: saturation, brightness: maximum) else { continue }
            votes[color, default: 0] += saturation * maximum
        }
        // A few colorful pixels in a gray icon do not make it that color.
        guard let best = votes.max(by: { $0.value < $1.value }), best.value > Double(side * side) * 0.04 else { return nil }
        return best.key
    }

    private static func hue(_ r: Double, _ g: Double, _ b: Double, maximum: Double, minimum: Double) -> Double {
        let delta = maximum - minimum
        guard delta > 0 else { return 0 }
        let sixths: Double = switch maximum {
        case r: (g - b) / delta
        case g: (b - r) / delta + 2
        default: (r - g) / delta + 4
        }
        return (sixths / 6).truncatingRemainder(dividingBy: 1) + (sixths < 0 ? 1 : 0)
    }
}

/// One or two letters for a repository without an icon: "AcmeStore" → "AS", "mimamori" → "M".
public enum RepositoryMonogram {
    public static func initials(for name: String) -> String {
        // Words split at anything not a letter or digit, and where lowercase turns to uppercase.
        var words: [String] = []
        var current = ""
        var previous: Character?
        for character in name {
            guard character.isLetter || character.isNumber else {
                if !current.isEmpty { words.append(current) }
                current = ""
                previous = nil
                continue
            }
            if let previous, previous.isLowercase, character.isUppercase, !current.isEmpty {
                words.append(current)
                current = ""
            }
            current.append(character)
            previous = character
        }
        if !current.isEmpty { words.append(current) }
        let initials = String(words.prefix(2).compactMap(\.first)).uppercased()
        return initials.isEmpty ? "?" : initials
    }
}

/// Finds a repository's own icon: an Xcode app icon, a Mac `.icns`, an Android launcher icon or
/// a web app's icon or favicon. It looks only near the top, and skips dependencies and build
/// output, so a big repository is quick.
public enum RepositoryIconFinder {
    /// Folders never searched.
    static let skippedFolders: Set<String> = ["node_modules", "Pods", "Carthage", "build", ".build", "DerivedData", "vendor",
                                              "dist", "out", "target", "SourcePackages", "fastlane", "Tests", "test", "tests"]
    /// Words in a path that mark an icon as another target's than the main app's.
    static let otherTargets = ["widget", "watch", "test", "preview", "clip", "extension", "intent", "sticker",
                               "notification", "example", "sample", "demo", "beta", "debug", "dev"]
    /// Icons at known places, best first, for when no Xcode or Mac icon turns up.
    static let wellKnownPaths = [
        "app/src/main/res/mipmap-xxxhdpi/ic_launcher.png", "app/src/main/res/mipmap-xxxhdpi/ic_launcher.webp",
        "app/src/main/res/mipmap-xxhdpi/ic_launcher.png", "app/src/main/res/mipmap-xxhdpi/ic_launcher.webp",
        "build/icon.icns", "build/icon.png",
        "assets/icon.png", "assets/images/icon.png",
        "public/apple-touch-icon.png", "public/icon.png", "public/logo512.png", "public/logo192.png", "public/favicon.png",
        "app/icon.png", "src/app/icon.png", "app/apple-icon.png", "src/app/apple-icon.png",
        "static/apple-touch-icon.png", "static/favicon.png",
        "apple-touch-icon.png", "icon.png", "logo.png", "favicon.png",
        "public/favicon.ico", "app/favicon.ico", "src/app/favicon.ico", "static/favicon.ico", "favicon.ico",
        "docs/logo.png", ".github/logo.png", "images/logo.png", "assets/logo.png",
    ]

    public static func icon(in root: URL, maxDepth: Int = 5, maxFolders: Int = 4000) -> URL? {
        var iconSets: [URL] = []
        var macIcons: [URL] = []
        let manager = FileManager.default
        // Breadth first, so the main app's icon, near the top, is found before a budget runs out.
        var queue: [(URL, Int)] = [(root, 0)]
        var next = 0
        while next < queue.count, next < maxFolders {
            let (folder, depth) = queue[next]
            next += 1
            guard let items = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for item in items {
                let name = item.lastPathComponent
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    if name.hasSuffix(".appiconset") {
                        iconSets.append(item)
                    } else if depth < maxDepth, !skippedFolders.contains(name), !name.hasSuffix(".xcodeproj"),
                              !name.hasSuffix(".xcworkspace"), !name.hasSuffix(".app") {
                        queue.append((item, depth + 1))
                    }
                } else if name.hasSuffix(".icns") {
                    macIcons.append(item)
                }
            }
        }
        if let set = best(iconSets, in: root, preferredName: "AppIcon.appiconset"), let image = largestImage(in: set) {
            return image
        }
        if let icns = best(macIcons, in: root, preferredName: "AppIcon.icns") { return icns }
        return wellKnownPaths.lazy.map { root.appendingPathComponent($0) }.first { manager.fileExists(atPath: $0.path) }
    }

    /// The main app's: named as Xcode names it, not under another target's folder, nearest the top.
    static func best(_ candidates: [URL], in root: URL, preferredName: String) -> URL? {
        func rank(_ url: URL) -> (Int, Int, Int) {
            let relative = String(url.path.dropFirst(root.path.count)).lowercased()
            let others = otherTargets.filter { relative.contains($0) }.count
            return (others, url.lastPathComponent == preferredName ? 0 : 1, url.pathComponents.count)
        }
        return candidates.min { rank($0) < rank($1) }
    }

    /// The biggest image an app icon set lists for its default appearance (not dark or tinted).
    static func largestImage(in iconSet: URL) -> URL? {
        struct Contents: Decodable {
            struct Image: Decodable {
                var filename: String?
                var size: String?
                var scale: String?
                var appearances: [[String: String]]?
            }
            var images: [Image]
        }
        func pixels(_ image: Contents.Image) -> Double {
            let side = Double(image.size?.split(separator: "x").first ?? "") ?? 0
            let scale = Double(image.scale?.dropLast() ?? "") ?? 1
            return side * scale
        }
        let manager = FileManager.default
        if let data = try? Data(contentsOf: iconSet.appendingPathComponent("Contents.json")),
           let contents = try? JSONDecoder().decode(Contents.self, from: data) {
            let listed = contents.images.filter { ($0.appearances ?? []).isEmpty && $0.filename != nil }
                .filter { manager.fileExists(atPath: iconSet.appendingPathComponent($0.filename!).path) }
            if let biggest = listed.max(by: { pixels($0) < pixels($1) }) {
                return iconSet.appendingPathComponent(biggest.filename!)
            }
        }
        // No usable Contents.json: the biggest image file in the folder.
        let files = (try? manager.contentsOfDirectory(at: iconSet, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .max { a, b in
                ((try? a.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    < ((try? b.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
            }
    }
}
