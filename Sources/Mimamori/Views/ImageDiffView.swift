import SwiftUI
import MimamoriCore

/// A changed image's two versions side by side: what the baseline had, and what the working tree
/// (or a commit) has now. Shown in place of the text diff, which git can't make for an image.
struct ImageDiffView: View {
    let session: WorktreeSession
    let change: FileChange
    /// Shows the change as one commit made it, rather than in the working tree.
    var commit: CommitRecord? = nil

    @State private var sides: ImageSides?
    @State private var errorText: String?

    var body: some View {
        Group {
            if let sides {
                HStack(alignment: .top, spacing: 16) {
                    if let old = sides.old { ImageSidePanel(title: "Before", side: old) }
                    if let new = sides.new { ImageSidePanel(title: "After", side: new) }
                }
                .padding(16)
            } else if let errorText {
                ContentUnavailableView("Could Not Load Image", systemImage: "exclamationmark.triangle",
                                       description: Text(errorText))
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: "\(commit?.oid ?? "")|\(change.contentKey)") { await load() }
    }

    private func load() async {
        errorText = nil
        // Another file's images go at once; this file's stay up until the new ones are ready.
        if sides?.path != change.path { sides = nil }
        do {
            guard let versions = try await session.versions(of: change, inCommit: commit != nil) else {
                errorText = "The worktree isn't ready yet."
                return
            }
            let path = change.path
            // Decoding a large image takes a moment: off the main thread.
            sides = await Task.detached(priority: .userInitiated) {
                ImageSides(path: path, old: ImageSide(versions.old), new: ImageSide(versions.new))
            }.value
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Both sides of an image change as decoded; a side the file isn't on is nil.
private struct ImageSides: Sendable {
    let path: String
    let old: ImageSide?
    let new: ImageSide?
}

/// One version of an image, as it can be shown.
private enum ImageSide: Sendable {
    case image(ImagePreview.Decoded, bytes: Int)
    case tooLarge(bytes: Int)
    /// Its bytes aren't an image ImageIO reads, such as an SVG.
    case undecodable(bytes: Int)

    init?(_ side: FileVersions.Side) {
        switch side {
        case .none: return nil
        case .tooLarge(let bytes): self = .tooLarge(bytes: bytes)
        case .data(let data):
            self = ImagePreview.decode(data).map { .image($0, bytes: data.count) } ?? .undecodable(bytes: data.count)
        }
    }

    var bytes: Int {
        switch self {
        case .image(_, let bytes), .tooLarge(let bytes), .undecodable(let bytes): bytes
        }
    }
}

/// One version of an image under its title, with its size in pixels and on disk.
private struct ImageSidePanel: View {
    let title: String
    let side: ImageSide

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            picture
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Text(caption)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(caption)")
    }

    @ViewBuilder
    private var picture: some View {
        switch side {
        case .image(let decoded, _):
            // At most its own size, so a small icon isn't blown up into a blur.
            Image(decorative: decoded.image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: CGFloat(decoded.image.width), maxHeight: CGFloat(decoded.image.height))
                .background(CheckerboardBackground())
                .overlay(Rectangle().strokeBorder(.separator))
        case .tooLarge:
            ContentUnavailableView("Too Large to Preview", systemImage: "photo",
                                   description: Text("Images over \(Self.format(ImagePreview.maxBytes)) aren't shown."))
        case .undecodable:
            ContentUnavailableView("Can't Show This Image", systemImage: "photo.badge.exclamationmark",
                                   description: Text("macOS can't read this file as an image."))
        }
    }

    private var caption: String {
        switch side {
        case .image(let decoded, let bytes): "\(decoded.pixelWidth) × \(decoded.pixelHeight) · \(Self.format(bytes))"
        case .tooLarge(let bytes), .undecodable(let bytes): Self.format(bytes)
        }
    }

    private static func format(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

/// The checkerboard image editors draw behind transparency, so clear pixels read as clear.
private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let square: CGFloat = 8
            var path = Path()
            for row in 0..<Int((size.height / square).rounded(.up)) {
                for column in 0..<Int((size.width / square).rounded(.up)) where (row + column).isMultiple(of: 2) {
                    path.addRect(CGRect(x: CGFloat(column) * square, y: CGFloat(row) * square, width: square, height: square))
                }
            }
            context.fill(path, with: .color(.secondary.opacity(0.15)))
        }
        .accessibilityHidden(true)
    }
}
