import AppKit
import ApplicationServices
import ServiceManagement
import SwiftUI

/// Preferences: hotkey, history length, shelf sizing, ignored apps, capture and login options.
struct SettingsView: View {
    @AppStorage(Prefs.historyLimit) private var historyLimit = 500
    @AppStorage(Prefs.shelfHeight) private var shelfHeight = 240.0
    @AppStorage(Prefs.cardWidth) private var cardWidth = 220.0
    @AppStorage(Prefs.captureImages) private var captureImages = true
    @AppStorage(Prefs.ignoredApps) private var ignoredApps = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var trusted = AXIsProcessTrusted()

    private var ignoredList: [String] { Prefs.ignoredBundleIDs }

    var body: some View {
        Form {
            Section("Shelf") {
                LabeledContent("Show shelf shortcut") { HotKeyRecorder() }
                Picker("History length", selection: $historyLimit) {
                    ForEach([100, 500, 1000], id: \.self) { Text("\($0) clips").tag($0) }
                }
                LabeledContent("Shelf height") {
                    Slider(value: $shelfHeight, in: 180...360, step: 10) { EmptyView() }
                    Text("\(Int(shelfHeight)) pt").monospacedDigit().frame(width: 50)
                }
                LabeledContent("Card width") {
                    Slider(value: $cardWidth, in: 160...320, step: 10) { EmptyView() }
                    Text("\(Int(cardWidth)) pt").monospacedDigit().frame(width: 50)
                }
            }

            Section("Capture") {
                Toggle("Capture images", isOn: $captureImages)
                ForEach(ignoredList, id: \.self) { id in
                    HStack {
                        if let icon = AppIconCache.icon(for: id) { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                        Text(id).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Button { setIgnored(ignoredList.filter { $0 != id }) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Stop ignoring \(id)")
                    }
                }
                Menu("Ignore an App…") {
                    ForEach(runningApps, id: \.self) { app in
                        Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                            if let id = app.bundleIdentifier { setIgnored(ignoredList + [id]) }
                        }
                    }
                }
            }

            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
                LabeledContent("Accessibility (auto-paste)") {
                    if trusted {
                        Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Grant Access…") { Permissions.requestAccessibility() }
                    }
                }
                if !trusted {
                    Text("Without Accessibility access, Return copies the card and you press ⌘V yourself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Text("ClipRibbonShelf is free and open source.")
                    Spacer()
                    Button("Support / Donate ❤️") { AppWindows.openDonate() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 600)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in trusted = AXIsProcessTrusted() }
    }

    private var runningApps: [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.bundleIdentifier.map { !ignoredList.contains($0) } == true
        }
    }

    private func setIgnored(_ ids: [String]) { ignoredApps = ids.joined(separator: "\n") }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn’t update login item: \(error.localizedDescription)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Button that records a new global shortcut from the next key press.
struct HotKeyRecorder: View {
    @AppStorage(Prefs.hotKeyDisplay) private var display = "⇧⌘C"
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Type shortcut… (Esc to cancel)" : display) { recording ? stop() : start() }
            .accessibilityLabel(recording ? "Recording shortcut" : "Shortcut \(display). Click to change.")
    }

    private func start() {
        recording = true
        HotKeyManager.shared.unregister()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 { stop(); return nil }
            guard !flags.isEmpty, flags != .shift else { NSSound.beep(); return nil }
            let key = event.keyCode == 49 ? "Space" : (event.charactersIgnoringModifiers ?? "?").uppercased()
            let d = UserDefaults.standard
            d.set(Int(event.keyCode), forKey: Prefs.hotKeyCode)
            d.set(HotKeyManager.carbonModifiers(flags), forKey: Prefs.hotKeyModifiers)
            display = HotKeyManager.symbols(flags) + key
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        HotKeyManager.shared.registerFromDefaults()
    }
}

/// First-run sheet explaining why Accessibility access is needed.
struct OnboardingView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "rectangle.stack.fill").font(.system(size: 44)).foregroundStyle(.tint)
            Text("Welcome to ClipRibbonShelf").font(.title2.bold())
            Text("Press \(UserDefaults.standard.string(forKey: Prefs.hotKeyDisplay) ?? "⇧⌘C") anywhere to slide up your clipboard shelf.")
            Text("To paste a card directly into the app you were using, ClipRibbonShelf sends ⌘V on your behalf. macOS requires Accessibility permission for that. Without it, cards are still copied and you can press ⌘V yourself.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Not Now") { AppWindows.close("onboarding") }
                Button("Grant Accessibility Access") {
                    Permissions.requestAccessibility()
                    AppWindows.close("onboarding")
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 440)
    }
}

/// Wraps the Accessibility permission prompt.
enum Permissions {
    static func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
