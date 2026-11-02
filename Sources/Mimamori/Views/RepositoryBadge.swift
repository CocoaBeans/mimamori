import AppKit
import SwiftUI
import MimamoriCore

/// How a repository is marked wherever it appears.
struct RepositoryLook: Equatable {
    var color: RepositoryColor
    /// Its own icon; nil when it has none, or it is set aside for the initials.
    var icon: NSImage?
    var monogram: String
}

/// An icon found in a repository's files, with the color it suggests.
struct FoundRepositoryIcon {
    let image: NSImage
    let color: RepositoryColor?
}

enum RepositoryIconImage {
    /// The icon ready to draw small. A Mac icon brings its own shape; an iPhone or web icon is a
    /// square, so it gets the rounded corners it has on a home screen.
    static func load(_ url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url), image.isValid else { return nil }
        guard url.pathExtension.lowercased() != "icns" else { return image }
        let side: CGFloat = 64
        return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: side * 0.225, yRadius: side * 0.225).addClip()
            NSGraphicsContext.current?.imageInterpolation = .high
            image.draw(in: rect)
            return true
        }
    }

    /// A dot of the color, for menus, which would draw a symbol in plain black or white.
    static func swatch(_ color: RepositoryColor) -> NSImage {
        let swatch = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(color.muted).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        swatch.isTemplate = false
        return swatch
    }
}

/// A repository's mark: its own icon, or its initials on its color.
struct RepositoryBadge: View {
    let look: RepositoryLook
    var size: CGFloat = 16

    var body: some View {
        if let icon = look.icon {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            // An outline, like the symbols beside it, in its color.
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .strokeBorder(look.color.muted, lineWidth: max(1, size / 14))
                .frame(width: size, height: size)
                .overlay {
                    Text(look.monogram)
                        .font(.system(size: size * (look.monogram.count > 1 ? 0.4 : 0.52), weight: .semibold, design: .rounded))
                        .foregroundStyle(look.color.muted)
                        .minimumScaleFactor(0.5)
                }
        }
    }
}

/// The context-menu items that pick a repository's color and whether its icon shows.
struct RepositoryLookMenu: View {
    @Environment(AppModel.self) private var model
    let repo: RepositoryEntry

    var body: some View {
        Menu("Color") {
            Picker("Color", selection: Binding(get: { repo.color }, set: { model.setColor($0, for: repo.id) })) {
                Text("Automatic").tag(RepositoryColor?.none)
                Divider()
                ForEach(RepositoryColor.allCases, id: \.self) { color in
                    Label { Text(color.title) } icon: { Image(nsImage: RepositoryIconImage.swatch(color)) }
                        .tag(Optional(color))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        if model.hasIcon(repo) {
            Toggle("Show Project Icon", isOn: Binding(get: { !repo.hidesIcon }, set: { model.setHidesIcon(!$0, for: repo.id) }))
        }
    }
}
