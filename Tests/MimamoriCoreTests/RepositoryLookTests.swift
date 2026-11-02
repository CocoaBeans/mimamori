import CoreGraphics
import Foundation
import Testing
@testable import MimamoriCore

@Suite("Repository looks")
struct RepositoryLookTests {
    @Test func monogramsTakeTheFirstTwoWords() {
        #expect(RepositoryMonogram.initials(for: "mimamori") == "M")
        #expect(RepositoryMonogram.initials(for: "AcmeStore") == "AS")
        #expect(RepositoryMonogram.initials(for: "fix-session-bank") == "FS")
        #expect(RepositoryMonogram.initials(for: "99 Bottles v2") == "9B")
        #expect(RepositoryMonogram.initials(for: "QWRTY") == "Q")
        #expect(RepositoryMonogram.initials(for: "--") == "?")
    }

    @Test func automaticColorsAreStableAndVaried() {
        #expect(RepositoryColor.automatic(for: "AcmeStore") == RepositoryColor.automatic(for: "acmestore"))
        let names = ["mimamori", "garden", "AcmeStore", "TideTable", "atlas", "QWRTY", "Pebble", "99 Bottles v2"]
        let colors = names.map(RepositoryColor.automatic(for:))
        #expect(Set(colors).count >= 4)
        #expect(!colors.contains(.brown))
    }

    private func image(_ fill: (CGFloat, CGFloat, CGFloat), dot: (CGFloat, CGFloat, CGFloat)? = nil) -> CGImage {
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(red: fill.0, green: fill.1, blue: fill.2, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        if let dot {
            context.setFillColor(red: dot.0, green: dot.1, blue: dot.2, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 6, height: 6))
        }
        return context.makeImage()!
    }

    @Test func iconColorIsTheNearestNamedColor() {
        #expect(RepositoryColor.dominant(in: image((0.20, 0.78, 0.35))) == .green)
        #expect(RepositoryColor.dominant(in: image((0.0, 0.48, 1.0))) == .blue)
        #expect(RepositoryColor.dominant(in: image((0.69, 0.32, 0.87))) == .purple)
        #expect(RepositoryColor.dominant(in: image((0.45, 0.28, 0.10))) == .brown)
        // Gray, or gray with a speck of color, has none.
        #expect(RepositoryColor.dominant(in: image((0.5, 0.5, 0.5))) == nil)
        #expect(RepositoryColor.dominant(in: image((0.2, 0.2, 0.22), dot: (1, 0, 0))) == nil)
    }

    private func makeTree(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("icons-\(UUID().uuidString)")
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
        return root
    }

    @Test func findsTheMainAppsIconSet() throws {
        let contents = #"""
        {"images":[
          {"filename":"icon-1024.png","idiom":"universal","platform":"ios","size":"1024x1024"},
          {"appearances":[{"appearance":"luminosity","value":"dark"}],"filename":"icon-dark.png","idiom":"universal","platform":"ios","size":"1024x1024"},
          {"filename":"icon-60@2x.png","idiom":"iphone","scale":"2x","size":"60x60"}
        ]}
        """#
        let root = try makeTree([
            "AcmeStore/Assets.xcassets/AppIcon.appiconset/Contents.json": contents,
            "AcmeStore/Assets.xcassets/AppIcon.appiconset/icon-1024.png": "x",
            "AcmeStore/Assets.xcassets/AppIcon.appiconset/icon-dark.png": "x",
            "AcmeStore/Assets.xcassets/AppIcon.appiconset/icon-60@2x.png": "x",
            "AcmeStoreWidget/Assets.xcassets/AppIcon.appiconset/Contents.json": contents,
            "AcmeStoreWidget/Assets.xcassets/AppIcon.appiconset/icon-1024.png": "x",
            "A/Preview Content/Preview Assets.xcassets/AppIcon.appiconset/big.png": "xxxxxxxx",
            "node_modules/thing/AppIcon.appiconset/huge.png": "xxxxxxxxxxxxxxxx",
            "public/favicon.ico": "x",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = try #require(RepositoryIconFinder.icon(in: root))
        #expect(found.path.hasSuffix("AcmeStore/Assets.xcassets/AppIcon.appiconset/icon-1024.png"))
    }

    @Test func fallsBackToMacIconsThenWellKnownPlaces() throws {
        let mac = try makeTree(["Resources/AppIcon.icns": "x", "Tools/Other/Other.icns": "x", "favicon.ico": "x"])
        defer { try? FileManager.default.removeItem(at: mac) }
        #expect(RepositoryIconFinder.icon(in: mac)?.lastPathComponent == "AppIcon.icns")

        let web = try makeTree(["public/favicon.ico": "x", "public/apple-touch-icon.png": "x", "src/index.ts": "x"])
        defer { try? FileManager.default.removeItem(at: web) }
        #expect(RepositoryIconFinder.icon(in: web)?.lastPathComponent == "apple-touch-icon.png")

        let plain = try makeTree(["README.md": "x", "Sources/main.swift": "x"])
        defer { try? FileManager.default.removeItem(at: plain) }
        #expect(RepositoryIconFinder.icon(in: plain) == nil)
    }

    @Test func iconSetWithoutContentsUsesItsBiggestFile() throws {
        let root = try makeTree(["App/Assets.xcassets/AppIcon.appiconset/small.png": "x",
                                 "App/Assets.xcassets/AppIcon.appiconset/large.png": "xxxxxx"])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(RepositoryIconFinder.icon(in: root)?.lastPathComponent == "large.png")
    }
}
