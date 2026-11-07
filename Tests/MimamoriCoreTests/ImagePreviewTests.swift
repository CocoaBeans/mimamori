import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MimamoriCore

/// A PNG of `width` × `height` pixels, optionally tagged with an EXIF orientation.
func makePNG(width: Int, height: Int, orientation: Int? = nil) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(red: 1, green: 0, blue: 0, alpha: 0.5)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    let properties = orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }
    CGImageDestinationAddImage(destination, image, properties)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@Suite("Image previews")
struct ImagePreviewTests {
    @Test func imagesAreKnownByTheirExtension() {
        for path in ["assets/icon.png", "photo.JPG", "a/b/shot.heic", "anim.gif", "scan.tiff", "art.webp"] {
            #expect(ImagePreview.isImage(path: path), "\(path)")
        }
        for path in ["notes.txt", "archive.zip", "Makefile", "app.sqlite", "font.ttf", "doc.pdf"] {
            #expect(!ImagePreview.isImage(path: path), "\(path)")
        }
    }

    @Test func decodesAnImageAtItsSize() throws {
        let decoded = try #require(ImagePreview.decode(try makePNG(width: 40, height: 30)))
        #expect(decoded.pixelWidth == 40 && decoded.pixelHeight == 30)
        #expect(decoded.image.width == 40 && decoded.image.height == 30)  // a small one isn't enlarged
    }

    @Test func aLargeImageIsScaledDownButKeepsItsSize() throws {
        let decoded = try #require(ImagePreview.decode(try makePNG(width: 400, height: 100), maxPixelSize: 100))
        #expect(decoded.pixelWidth == 400 && decoded.pixelHeight == 100)
        #expect(decoded.image.width == 100 && decoded.image.height == 25)
    }

    @Test func aTurnedPhotoReportsItsUprightSize() throws {
        // Orientation 6: stored landscape, shown turned a quarter, so upright it's portrait.
        let decoded = try #require(ImagePreview.decode(try makePNG(width: 40, height: 30, orientation: 6)))
        #expect(decoded.pixelWidth == 30 && decoded.pixelHeight == 40)
        #expect(decoded.image.width == 30 && decoded.image.height == 40)
    }

    @Test func whatIsntAnImageDecodesAsNothing() {
        #expect(ImagePreview.decode(Data("not an image".utf8)) == nil)
        #expect(ImagePreview.decode(Data(#"<svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)) == nil)
    }
}

/// Exercises the real git binary against a throwaway repository.
@Suite("Image previews (integration)", .serialized)
struct ImagePreviewIntegrationTests {
    @Test func readsBothSidesOfAChangedImage() async throws {
        let git = try #require(await GitClient.locate())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mimamori-images-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let config = ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false"]
        try await git.run(["init", "-q", "-b", "main"], in: repo)
        let before = try makePNG(width: 20, height: 10)
        let after = try makePNG(width: 30, height: 15)
        try before.write(to: repo.appendingPathComponent("icon.png"))
        try await git.run(config + ["add", "-A"], in: repo)
        try await git.run(config + ["commit", "-q", "-m", "Add the icon"], in: repo)
        try after.write(to: repo.appendingPathComponent("icon.png"))

        let inspector = try await WorktreeInspector(git: git, worktree: repo, shadowIndexDirectory: root.appendingPathComponent("index"))
        let oldOID = await git.blobOID(at: "HEAD", path: "icon.png", in: repo)
        #expect(await git.blobSize(try #require(oldOID), in: repo) == before.count)
        let changed = FileChange(path: "icon.png", kind: .modified, oldOID: oldOID, newOID: nil, isBinary: true)

        // In the working tree, the new side is the file as it is now.
        let working = try await inspector.versions(of: changed, fromWorkingTree: true)
        #expect(working == FileVersions(old: .data(before), new: .data(after)))
        // Over the limit, a side isn't read.
        let capped = try await inspector.versions(of: changed, fromWorkingTree: true, maxBytes: 10)
        #expect(capped == FileVersions(old: .tooLarge(bytes: before.count), new: .tooLarge(bytes: after.count)))
        // A commit's new side is its blob, whatever the working tree holds now.
        let added = FileChange(path: "icon.png", kind: .added, oldOID: nil, newOID: oldOID, isBinary: true)
        #expect(try await inspector.versions(of: added, fromWorkingTree: false) == FileVersions(old: .none, new: .data(before)))
        // Deleted, there is no new side to read.
        let deleted = FileChange(path: "icon.png", kind: .deleted, oldOID: oldOID, newOID: nil, isBinary: true)
        #expect(try await inspector.versions(of: deleted, fromWorkingTree: true) == FileVersions(old: .data(before), new: .none))
        #expect(await git.blobSize("0000000000000000000000000000000000000000", in: repo) == nil)
    }
}
