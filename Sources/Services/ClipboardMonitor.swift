import AppKit
import UniformTypeIdentifiers

/// UserDefaults keys and defaults shared by the app.
enum Prefs {
    static let hotKeyCode = "hotKeyCode"
    static let hotKeyModifiers = "hotKeyModifiers"
    static let hotKeyDisplay = "hotKeyDisplay"
    static let historyLimit = "historyLimit"
    static let shelfHeight = "shelfHeight"
    static let cardWidth = "cardWidth"
    static let ignoredApps = "ignoredApps"
    static let captureImages = "captureImages"
    static let capturePaused = "capturePaused"
    static let didOnboard = "didOnboard"

    static func register() {
        UserDefaults.standard.register(defaults: [
            hotKeyCode: 8,                 // kVK_ANSI_C
            hotKeyModifiers: 768,          // cmdKey | shiftKey
            hotKeyDisplay: "⇧⌘C",
            historyLimit: 500,
            shelfHeight: 240.0,
            cardWidth: 220.0,
            ignoredApps: "com.apple.keychainaccess\ncom.1password.1password",
            captureImages: true,
            capturePaused: false,
        ])
    }

    static var ignoredBundleIDs: [String] {
        (UserDefaults.standard.string(forKey: ignoredApps) ?? "")
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// Polls the general pasteboard's change count and records new clips into the store.
final class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private let maxBytes = 20 * 1024 * 1024
    private let skipTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                          "com.agilebits.onepassword"]

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Prefs.capturePaused) else { return }

        let front = NSWorkspace.shared.frontmostApplication
        if let id = front?.bundleIdentifier, Prefs.ignoredBundleIDs.contains(id) { return }
        if let types = pb.types, types.contains(where: { skipTypes.contains($0.rawValue) }) { return }

        guard var item = read(pb, images: defaults.bool(forKey: Prefs.captureImages)) else { return }
        item.sourceBundleID = front?.bundleIdentifier
        item.sourceName = front?.localizedName
        ClipStore.shared.add(item)
    }

    /// Reads the richest supported representation: file URLs, images, links, then plain text.
    private func read(_ pb: NSPasteboard, images: Bool) -> ClipItem? {
        let fileOptions: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: fileOptions) as? [URL], !urls.isEmpty {
            return ClipItem(kind: .file, text: urls.map(\.path).joined(separator: "\n"))
        }

        if images, let type = pb.availableType(from: [.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier)]),
           let data = pb.data(forType: type) {
            guard data.count <= maxBytes, let image = NSImage(data: data),
                  let stored = ClipStore.shared.storeImage(image) else { return nil }
            return ClipItem(kind: .image, text: "\(Int(stored.size.width))×\(Int(stored.size.height))",
                            imageFile: stored.name, fingerprint: stored.fingerprint)
        }

        if let string = pb.string(forType: .string) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, string.utf8.count <= maxBytes else { return nil }
            if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
               let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil {
                return ClipItem(kind: .link, text: trimmed)
            }
            return ClipItem(kind: .text, text: string)
        }

        if let urls = pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL], let url = urls.first {
            return ClipItem(kind: .link, text: url.absoluteString)
        }
        return nil
    }

    /// Writes a clip back onto the general pasteboard.
    static func write(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text, forType: .string)
        case .link:
            pb.setString(item.text, forType: .string)
            pb.setString(item.text, forType: .URL)
        case .image:
            if let url = ClipStore.shared.fullImageURL(for: item), let image = NSImage(contentsOf: url) {
                pb.writeObjects([image])
            }
        case .file:
            let urls = item.filePaths.map { URL(fileURLWithPath: $0) as NSURL }
            pb.writeObjects(urls)
        }
    }
}
