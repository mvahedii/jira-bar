import AppKit
import SwiftUI

/// Borderless Spotlight-style window that can take keyboard focus.
final class FloatingPanel: NSPanel {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

enum RootTab { case create, board }

/// Bridge between SwiftUI and the window: panel-level state and actions.
@MainActor
final class PanelHost: ObservableObject {
    @Published var tab: RootTab = .create
    @Published var showSettings = false
    @Published var showCount = 0                 // bumped on every show; views use it to grab focus

    var hide: () -> Void = {}
    /// Set while a modal dialog (file picker) is open, so losing key focus doesn't close the panel.
    var suspendAutoHide = false
}

/// Hosting view that reports the ideal height of its SwiftUI content whenever it changes,
/// so the window can grow and shrink to fit (Create is short, Board and Settings are tall).
final class SizedHostingView<Content: View>: NSHostingView<Content> {
    var onIdealHeight: ((CGFloat) -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onIdealHeight?(self.intrinsicContentSize.height)
        }
    }
}
