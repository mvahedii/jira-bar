import AppKit
import SwiftUI
import JiraBarCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    enum Anchor { case statusItem, center, dock }

    let settings = Settings()
    let host = PanelHost()
    private(set) lazy var board = BoardFlow(settings: settings)
    private(set) lazy var create = CreateFlow(settings: settings, board: board)

    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var pasteMonitor: Any?
    private var lastHiddenAt = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        setupPanel()
        setupStatusItem()
        applyVisibility()
        applyHotKey()
        settings.onHotKeyChange = { [weak self] in self?.applyHotKey() }
        settings.onVisibilityChange = { [weak self] in self?.applyVisibility() }
        installPasteMonitor()
        Task {
            await settings.refreshIdentity()
            await settings.upgradeBoardsIfNeeded()
        }
        if !settings.isConfigured { show(from: .statusItem) }
        #if DEBUG
        if let dir = ProcessInfo.processInfo.environment["JIRABAR_SNAPSHOT_DIR"] { runSnapshotSession(dir: dir) }
        #endif
    }

    // MARK: - Panel

    private func setupPanel() {
        panel = FloatingPanel()
        panel.onCancel = { [weak self] in self?.hide() }

        let root = RootView()
            .environmentObject(settings)
            .environmentObject(host)
            .environmentObject(board)
            .environmentObject(create)
        let hosting = SizedHostingView(rootView: root)
        hosting.sizingOptions = [.intrinsicContentSize]
        hosting.onIdealHeight = { [weak self] h in self?.setContentHeight(h) }

        let blur = NSVisualEffectView()
        blur.material = .popover
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 0.5
        blur.layer?.borderColor = NSColor.separatorColor.cgColor

        hosting.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: blur.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])
        panel.contentView = blur

        host.hide = { [weak self] in self?.hide() }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // While setting up or in Settings the panel stays put: people leave to copy a token
                // from the browser and must find it again when they come back.
                guard let self, !self.host.suspendAutoHide,
                      self.settings.isConfigured, !self.host.showSettings else { return }
                self.hide()
            }
        }
    }

    private func setContentHeight(_ height: CGFloat) {
        guard height > 40, let panel else { return }
        let screenHeight = panel.screen?.visibleFrame.height ?? NSScreen.main?.visibleFrame.height ?? 900
        let h = min(height, screenHeight - 80)
        guard abs(panel.frame.height - h) > 0.5 else { return }
        var f = panel.frame
        let top = f.maxY
        f.size.height = h
        f.origin.y = top - h
        panel.setFrame(f, display: true)
        panel.invalidateShadow()
    }

    func show(from anchor: Anchor) {
        if create.phase == .created,
           let c = create.created, Date().timeIntervalSince(c.createdAt) > 45 {
            create.reset()
        }
        host.showSettings = host.showSettings && settings.isConfigured
        position(anchor)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        host.showCount += 1
    }

    func hide() {
        guard panel.isVisible else { return }
        lastHiddenAt = Date()
        panel.orderOut(nil)
        NSApp.hide(nil)
    }

    private func toggle(from anchor: Anchor) {
        if panel.isVisible { hide(); return }
        // Clicking the menu bar or Dock icon first makes the panel resign key (which hides it);
        // don't instantly reopen it in that case.
        if anchor != .center, Date().timeIntervalSince(lastHiddenAt) < 0.25 { return }
        show(from: anchor)
    }

    /// Clicking the Dock icon, or opening JiraBar again from Spotlight/Finder.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        toggle(from: .dock)
        return true
    }

    private func applyVisibility() {
        NSApp.setActivationPolicy(settings.showDockIcon ? .regular : .accessory)
        statusItem?.isVisible = settings.showMenuBarIcon
    }

    private func position(_ anchor: Anchor) {
        let size = panel.frame.size
        // Only hang the panel under the icon when the icon is really on screen; macOS hides
        // menu bar items that don't fit, and then the panel opens in the middle instead.
        if anchor == .statusItem, settings.showMenuBarIcon,
           let button = statusItem.button, let window = button.window, window.isVisible,
           let screen = NSScreen.screens.first(where: { $0.frame.contains(window.frame.origin) }) {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let visible = screen.visibleFrame
            var x = rect.midX - size.width / 2
            x = min(max(x, visible.minX + 8), visible.maxX - size.width - 8)
            panel.setFrameTopLeftPoint(NSPoint(x: x, y: rect.minY - 6))
        } else {
            let mouse = NSEvent.mouseLocation
            let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main
            let v = screen?.visibleFrame ?? .zero
            panel.setFrameTopLeftPoint(NSPoint(x: v.midX - size.width / 2, y: v.maxY - v.height * 0.16))
        }
    }

    // MARK: - Menu bar item & hotkey

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.badge.plus", accessibilityDescription: "JiraBar")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            menu.addItem(withTitle: "New task  \(settings.hotKeyDisplay)", action: #selector(openFromMenu), keyEquivalent: "").target = self
            menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quit JiraBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            toggle(from: .statusItem)
        }
    }

    @objc private func openFromMenu() { show(from: .statusItem) }

    @objc private func openSettings() {
        host.showSettings = true
        show(from: .statusItem)
    }

    private func applyHotKey() {
        GlobalHotKey.shared.handler = { [weak self] in
            MainActor.assumeIsolated { self?.toggle(from: .center) }
        }
        settings.hotKeyRegistered = GlobalHotKey.shared.register(keyCode: settings.hotKeyCode, modifiers: settings.hotKeyMods)
    }

    // MARK: - Pasting screenshots

    /// Tab cycles the Create fields; ⌘V with an image on the clipboard attaches it (text pastes are left to the text field).
    private func installPasteMonitor() {
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if let self, event.keyCode == 48, self.panel.isKeyWindow,   // Tab
               self.host.tab == .create, !self.host.showSettings, self.create.phase == .compose,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.shift).isEmpty {
                self.create.cycleFocus(forward: !event.modifierFlags.contains(.shift))
                return nil
            }
            guard let self, self.panel.isKeyWindow,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.keyCode == 9,   // V on any keyboard layout (Persian included)
                  self.host.tab == .create, !self.host.showSettings, self.create.phase == .compose else { return event }
            let pb = NSPasteboard.general
            let hasFiles = pb.types?.contains(.fileURL) == true
            let hasText = pb.types?.contains(.string) == true
            if hasText && !hasFiles { return event }
            let items = ImageTools.attachments(from: pb)
            guard !items.isEmpty else { return event }
            self.create.add(items)
            return nil
        }
    }

    // A menu-bar-only app has no menu, but text fields need Edit key equivalents to work.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit JiraBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        NSApp.mainMenu = main
    }

#if DEBUG
    // MARK: - Debug snapshots (renders the panel to PNG with fake data; no screen-recording permission needed)

    private func runSnapshotSession(dir: String) {
        host.suspendAutoHide = true
        Task { @MainActor in
            func wait(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            show(from: .center)
            await wait(0.8)
            snapshot("1-onboarding", dir)

            settings.loadDemoData()
            board.loadDemoData()
            create.loadDemoDraft()
            host.showSettings = false
            host.tab = .create
            await wait(0.8)
            snapshot("2-create", dir)

            create.loadDemoDraft(persian: true)
            await wait(0.6)
            snapshot("2b-create-persian", dir)
            create.title = ""
            create.notes = ""

            create.loadDemoCreated()
            await wait(0.8)
            snapshot("3-created", dir)
            create.reset()
            create.loadDemoCreatedPersian()
            await wait(0.6)
            snapshot("3b-created-persian", dir)

            host.tab = .board
            await wait(0.8)
            snapshot("4-board", dir)

            settings.activeBoardID = 66
            host.tab = .create
            create.reset()
            host.showSettings = true
            await wait(0.8)
            snapshot("5-settings", dir)
            NSApp.terminate(nil)
        }
    }

    private func snapshot(_ name: String, _ dir: String) {
        guard let view = panel.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: view.bounds.size).fill()
        rep.draw(in: NSRect(origin: .zero, size: view.bounds.size))
        image.unlockFocus()
        if let tiff = image.tiffRepresentation, let r = NSBitmapImageRep(data: tiff),
           let png = r.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
    }
#endif
}
