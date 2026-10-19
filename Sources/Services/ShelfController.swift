import AppKit
import ApplicationServices
import SwiftUI

/// Borderless panel that can take keyboard focus without activating the app.
final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// UI state of the shelf shared between the AppKit controller and SwiftUI views.
final class ShelfModel: ObservableObject {
    @Published var isShown = false
    @Published var tab: ShelfTab = .history
    @Published var query = ""
    @Published var selection = 0
    @Published var previewShown = false
    @Published var creatingBoard = false
    @Published var newBoardName = ""
    @Published var pendingDelete: Pinboard?

    var items: [ClipItem] { ClipStore.shared.items(for: tab, query: query) }
    var selectedItem: ClipItem? { items.indices.contains(selection) ? items[selection] : nil }

    func select(tab newTab: ShelfTab) {
        tab = newTab
        selection = 0
        previewShown = false
    }
}

/// Positions, animates and drives keyboard interaction for the bottom shelf panel, and performs pastes.
final class ShelfController: NSObject, NSWindowDelegate {
    static let shared = ShelfController()

    let model = ShelfModel()
    private var panel: ShelfPanel?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?

    func toggle() { model.isShown ? hide() : show() }

    func show() {
        guard !model.isShown else { return }
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            previousApp = front
        }
        let panel = makePanel()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let height = CGFloat(UserDefaults.standard.double(forKey: Prefs.shelfHeight))
        panel.setFrame(NSRect(x: visible.minX + 8, y: visible.minY + 6, width: visible.width - 16, height: height),
                       display: true)

        model.query = ""
        model.selection = 0
        model.previewShown = false
        model.creatingBoard = false
        model.pendingDelete = nil
        panel.orderFrontRegardless()
        panel.makeKey()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) { model.isShown = true }
        installKeyMonitor()
    }

    func hide(then completion: (() -> Void)? = nil) {
        guard model.isShown else { completion?(); return }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        model.previewShown = false
        withAnimation(.easeIn(duration: 0.16)) { model.isShown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            if self?.model.isShown == false { self?.panel?.orderOut(nil) }
            completion?()
        }
    }

    private func makePanel() -> ShelfPanel {
        if let panel { return panel }
        let p = ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.delegate = self
        p.contentView = NSHostingView(rootView: ShelfView(model: model, store: ClipStore.shared))
        panel = p
        return p
    }

    func windowDidResignKey(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.isShown, !self.model.previewShown else { return }
            if let key = NSApp.keyWindow, key === self.panel || key.parent === self.panel { return }
            self.hide()
        }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard model.isShown else { return event }
        if model.creatingBoard {
            if event.keyCode == 53 { model.creatingBoard = false; return nil }
            return event
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let count = model.items.count
        switch event.keyCode {
        case 53: // Escape
            if model.previewShown { model.previewShown = false }
            else if model.pendingDelete != nil { model.pendingDelete = nil }
            else if !model.query.isEmpty { model.query = ""; model.selection = 0 }
            else { hide() }
            return nil
        case 123: model.selection = max(0, model.selection - 1); return nil
        case 124: model.selection = min(max(count - 1, 0), model.selection + 1); return nil
        case 36, 76:
            if let board = model.pendingDelete {
                ClipStore.shared.deletePinboard(board.id)
                model.pendingDelete = nil
                model.select(tab: .history)
            } else if let item = model.selectedItem { paste(item) }
            return nil
        case 48: cycleTab(backwards: flags.contains(.shift)); return nil
        case 49 where model.query.isEmpty:
            model.previewShown.toggle()
            return nil
        case 51:
            if !model.query.isEmpty { model.query.removeLast(); model.selection = 0 }
            else if let item = model.selectedItem {
                ClipStore.shared.delete(item, from: model.tab)
                model.selection = min(model.selection, max(model.items.count - 1, 0))
            }
            return nil
        default: break
        }
        let chars = event.charactersIgnoringModifiers ?? ""
        if flags.contains(.command) {
            if let n = Int(chars), (1...9).contains(n), let item = model.selectedItem {
                let boards = ClipStore.shared.pinboards
                if boards.indices.contains(n - 1) { ClipStore.shared.pin(item, to: boards[n - 1].id) }
                else { NSSound.beep() }
                return nil
            }
            if chars == "," { hide { AppWindows.showSettings() }; return nil }
            return event
        }
        if !flags.contains(.control), let typed = event.characters, !typed.isEmpty,
           typed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            model.query += typed
            model.selection = 0
            model.previewShown = false
            return nil
        }
        return event
    }

    private func cycleTab(backwards: Bool) {
        let tabs: [ShelfTab] = [.history] + ClipStore.shared.pinboards.map { .board($0.id) }
        guard let i = tabs.firstIndex(of: model.tab) else { model.select(tab: .history); return }
        model.select(tab: tabs[(i + (backwards ? tabs.count - 1 : 1)) % tabs.count])
    }

    // MARK: Paste

    /// Copies the clip, hides the shelf, reactivates the previous app and sends ⌘V when permitted.
    func paste(_ item: ClipItem) {
        ClipboardMonitor.write(item)
        let target = previousApp
        hide {
            target?.activate()
            if AXIsProcessTrusted() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { Self.postCommandV() }
            } else {
                Toast.show("Copied! Press ⌘V to paste — grant Accessibility access in Settings for auto-paste.")
            }
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

/// Small transient message shown near the bottom of the screen.
enum Toast {
    private static var panel: NSPanel?

    static func show(_ message: String) {
        panel?.orderOut(nil)
        let host = NSHostingView(rootView:
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.regularMaterial, in: Capsule())
                .fixedSize())
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? .zero
        let p = NSPanel(contentRect: NSRect(x: visible.midX - size.width / 2, y: visible.minY + 40,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.contentView = host
        p.orderFrontRegardless()
        panel = p
        NSAccessibility.post(element: host, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            if panel === p { p.orderOut(nil); panel = nil }
        }
    }
}
