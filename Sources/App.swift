import AppKit
import ApplicationServices
import SwiftUI

/// App entry point: a menu bar extra that controls the shelf.
@main
struct ClipRibbonShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(Prefs.capturePaused) private var paused = false
    @AppStorage(Prefs.hotKeyDisplay) private var hotKey = "⇧⌘C"

    init() { Prefs.register() }

    var body: some Scene {
        MenuBarExtra("ClipRibbonShelf", systemImage: paused ? "pause.rectangle" : "rectangle.stack") {
            Button("Show Shelf (\(hotKey))") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { ShelfController.shared.show() }
            }
            Toggle("Pause Capture", isOn: $paused)
            Divider()
            Button("Settings…") { AppWindows.showSettings() }.keyboardShortcut(",")
            Button("Support / Donate ❤️") { AppWindows.openDonate() }
            Divider()
            Button("Quit ClipRibbonShelf") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
    }
}

/// Starts capture and the global hotkey, and shows the first-run sheet.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        _ = ClipStore.shared
        ClipboardMonitor.shared.start()
        HotKeyManager.shared.onPress = { ShelfController.shared.toggle() }
        HotKeyManager.shared.registerFromDefaults()

        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Prefs.didOnboard) {
            defaults.set(true, forKey: Prefs.didOnboard)
            if !AXIsProcessTrusted() {
                AppWindows.show(id: "onboarding", title: "Welcome", view: OnboardingView())
            }
        }
    }
}

/// Presents the app's standalone windows (Settings, onboarding) for this menu-bar-only app.
enum AppWindows {
    private static var windows: [String: NSWindow] = [:]

    static func showSettings() {
        show(id: "settings", title: "ClipRibbonShelf Settings", view: SettingsView())
    }

    static func show<V: View>(id: String, title: String, view: V) {
        let window = windows[id] ?? {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: view)
            w.title = title
            w.center()
            windows[id] = w
            return w
        }()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func close(_ id: String) { windows[id]?.close() }

    static func openDonate() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
    }
}
