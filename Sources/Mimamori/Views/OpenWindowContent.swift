import SwiftUI

/// A window's content, drawn only while the window is open. SwiftUI keeps a `Window` scene's
/// window after you close it, ready to open again, and the views in it would go on following
/// every agent event and file change with nobody to see them: with agents at work, a closed main
/// window cost more than everything else Mimamori did. Closed, this draws nothing; opened again,
/// it builds its content afresh, so state kept only in those views (a scroll position) starts over.
/// What you type there belongs in the model.
struct OpenWindowContent<Content: View>: View {
    @ViewBuilder var content: Content
    /// Open from the start, so a window's first frame has its content.
    @State private var isOpen = true

    var body: some View {
        Group {
            if isOpen {
                content
            } else {
                Color.clear
            }
        }
        .onAppear { isOpen = true }
        .onDisappear { isOpen = false }
    }
}
