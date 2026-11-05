import AppKit
import SwiftUI
import MimamoriCore

/// Tells you once, over the main window, that `state.json` couldn't all be read.
struct StateNoticeAlert: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.alert(StateNotice.title, isPresented: isPresented, presenting: model.stateNotice) { notice in
            Button("OK") {}
                .keyboardShortcut(.defaultAction)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([notice.file]) }
        } message: { notice in
            Text(notice.message)
        }
    }

    private var isPresented: Binding<Bool> {
        Binding(get: { model.stateNotice != nil }, set: { shown in
            if !shown { model.stateNotice = nil }
        })
    }
}
