import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images among binary files, so the diff can show one instead of saying only that it changed.
public enum ImagePreview {
    /// The longest side, in pixels, an image is decoded at for showing: big enough for a sharp
    /// picture on a Retina display, without holding a huge image's every pixel in memory.
    public static let maxPixelSize = 2048
    /// A side larger than this isn't read for a preview.
    public static let maxBytes = 50 * 1024 * 1024

    /// Whether the file at `path` is an image by its extension: PNG, JPEG, GIF, HEIC, TIFF, WebP and
    /// the other types macOS knows as images. Whether it decodes is another matter; see `decode`.
    public static func isImage(path: String) -> Bool {
        let fileExtension = (path as NSString).pathExtension
        guard !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// A decoded image and its size as stored, which the picture shown may be smaller than.
    /// CGImage is immutable, so one is safe to hand across threads.
    public struct Decoded: @unchecked Sendable {
        public let image: CGImage
        public let pixelWidth: Int
        public let pixelHeight: Int
    }

    /// Decodes `data` as an image, turned upright and scaled to fit `maxPixelSize`; nil when
    /// ImageIO can't read it (an SVG, say, or a damaged file).
    public static func decode(_ data: Data, maxPixelSize: Int = maxPixelSize) -> Decoded? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        var width = properties[kCGImagePropertyPixelWidth] as? Int ?? image.width
        var height = properties[kCGImagePropertyPixelHeight] as? Int ?? image.height
        // Orientations 5 to 8 turn the picture a quarter: its upright size is the stored one turned.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
            swap(&width, &height)
        }
        return Decoded(image: image, pixelWidth: width, pixelHeight: height)
    }
}

/// A binary file's bytes on each side of a change, for showing it.
public struct FileVersions: Sendable, Equatable {
    public enum Side: Sendable, Equatable {
        /// The file isn't on this side: it was added, or deleted.
        case none
        /// It's too large to read for a preview.
        case tooLarge(bytes: Int)
        case data(Data)
    }

    public var old: Side
    public var new: Side

    public init(old: Side, new: Side) {
        self.old = old
        self.new = new
    }
}
