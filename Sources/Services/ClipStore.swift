import AppKit

/// The kind of content a clip holds; drives how its card is previewed and pasted.
enum ClipKind: String, Codable {
    case text, link, image, file

    var label: String {
        switch self {
        case .text: return "Text"
        case .link: return "Link"
        case .image: return "Image"
        case .file: return "File"
        }
    }
}

/// A single captured clipboard entry.
struct ClipItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: ClipKind
    /// Text content, URL string, newline-joined file paths, or image dimensions.
    var text: String
    /// Base name of the stored image files (`<name>.png` and `<name>-thumb.png`).
    var imageFile: String?
    /// Content fingerprint used to de-duplicate images.
    var fingerprint: String?
    var sourceBundleID: String?
    var sourceName: String?
    var date = Date()

    var filePaths: [String] { kind == .file ? text.components(separatedBy: "\n") : [] }
    var host: String { URL(string: text)?.host() ?? text }

    /// A readable title derived only from the URL host (no network access).
    var linkTitle: String {
        var h = host.lowercased()
        if h.hasPrefix("www.") { h.removeFirst(4) }
        let parts = h.split(separator: ".")
        let name = parts.count >= 2 ? parts[parts.count - 2] : (parts.first ?? Substring(h))
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Short one-line description for VoiceOver and filtering.
    var summary: String {
        switch kind {
        case .text: return String(text.prefix(200))
        case .link: return "\(linkTitle), \(host)"
        case .image: return "Image \(text)"
        case .file:
            let names = filePaths.map { ($0 as NSString).lastPathComponent }
            return names.joined(separator: ", ")
        }
    }

    func sameContent(as other: ClipItem) -> Bool {
        kind == other.kind && text == other.text && fingerprint == other.fingerprint
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || text.localizedCaseInsensitiveContains(query)
            || (sourceName ?? "").localizedCaseInsensitiveContains(query)
            || kind.label.localizedCaseInsensitiveContains(query)
    }
}

/// A named, user-created collection of saved clips.
struct Pinboard: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var items: [ClipItem] = []
}

/// Which tab of the shelf is showing.
enum ShelfTab: Hashable {
    case history
    case board(UUID)
}

/// Owns clipboard history and pinboards, persisting them as JSON with image files alongside.
final class ClipStore: ObservableObject {
    static let shared = ClipStore()

    @Published private(set) var history: [ClipItem] = []
    @Published private(set) var pinboards: [Pinboard] = []

    private struct Snapshot: Codable {
        var history: [ClipItem]
        var pinboards: [Pinboard]
    }

    let directory: URL
    let imagesDirectory: URL
    private var storeURL: URL { directory.appendingPathComponent("store.json") }
    private let thumbCache = NSCache<NSString, NSImage>()

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        directory = base.appendingPathComponent("ClipRibbonShelf", isDirectory: true)
        imagesDirectory = directory.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
        load()
    }

    // MARK: Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            let snap = try JSONDecoder().decode(Snapshot.self, from: data)
            history = snap.history
            pinboards = snap.pinboards
        } catch {
            // Corrupt storage: keep a backup copy and start fresh.
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = directory.appendingPathComponent("store-corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: storeURL, to: backup)
            NSLog("ClipRibbonShelf: corrupt store backed up to \(backup.path): \(error)")
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(Snapshot(history: history, pinboards: pinboards))
            try data.write(to: storeURL, options: .atomic)
        } catch {
            NSLog("ClipRibbonShelf: failed to save store: \(error)")
        }
    }

    // MARK: Queries

    func items(for tab: ShelfTab, query: String) -> [ClipItem] {
        let source: [ClipItem]
        switch tab {
        case .history: source = history
        case .board(let id): source = pinboards.first { $0.id == id }?.items ?? []
        }
        return query.isEmpty ? source : source.filter { $0.matches(query) }
    }

    func item(withID id: UUID) -> ClipItem? {
        history.first { $0.id == id } ?? pinboards.lazy.flatMap(\.items).first { $0.id == id }
    }

    // MARK: Mutations

    func add(_ item: ClipItem) {
        history.removeAll { $0.sameContent(as: item) }
        history.insert(item, at: 0)
        let limit = max(UserDefaults.standard.integer(forKey: Prefs.historyLimit), 10)
        if history.count > limit { history.removeLast(history.count - limit) }
        cleanupOrphanImages()
        save()
    }

    func delete(_ item: ClipItem, from tab: ShelfTab) {
        switch tab {
        case .history: history.removeAll { $0.id == item.id }
        case .board(let id):
            if let i = pinboards.firstIndex(where: { $0.id == id }) { pinboards[i].items.removeAll { $0.id == item.id } }
        }
        cleanupOrphanImages()
        save()
    }

    func pin(_ item: ClipItem, to boardID: UUID) {
        guard let i = pinboards.firstIndex(where: { $0.id == boardID }),
              !pinboards[i].items.contains(where: { $0.sameContent(as: item) }) else { return }
        var copy = item
        copy.id = UUID()
        pinboards[i].items.insert(copy, at: 0)
        save()
    }

    @discardableResult
    func createPinboard(named name: String) -> Pinboard? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let board = Pinboard(name: String(trimmed.prefix(40)))
        pinboards.append(board)
        save()
        return board
    }

    /// Removes a pinboard and moves its cards back into history.
    func deletePinboard(_ id: UUID) {
        guard let i = pinboards.firstIndex(where: { $0.id == id }) else { return }
        let board = pinboards.remove(at: i)
        for item in board.items.reversed() where !history.contains(where: { $0.sameContent(as: item) }) {
            history.insert(item, at: 0)
        }
        save()
    }

    // MARK: Images

    /// Downscales and stores an image, returning the base file name and pixel size.
    func storeImage(_ image: NSImage) -> (name: String, size: CGSize, fingerprint: String)? {
        guard let full = Self.pngData(image, maxSide: 2560),
              let thumb = Self.pngData(image, maxSide: 480) else { return nil }
        let name = UUID().uuidString
        do {
            try full.write(to: imagesDirectory.appendingPathComponent("\(name).png"))
            try thumb.write(to: imagesDirectory.appendingPathComponent("\(name)-thumb.png"))
        } catch {
            NSLog("ClipRibbonShelf: failed to write image: \(error)")
            return nil
        }
        return (name, Self.pixelSize(of: image), Self.fnv1a(thumb))
    }

    func thumbnail(for item: ClipItem) -> NSImage? {
        guard let name = item.imageFile else { return nil }
        if let cached = thumbCache.object(forKey: name as NSString) { return cached }
        let image = NSImage(contentsOf: imagesDirectory.appendingPathComponent("\(name)-thumb.png"))
        if let image { thumbCache.setObject(image, forKey: name as NSString) }
        return image
    }

    func fullImageURL(for item: ClipItem) -> URL? {
        item.imageFile.map { imagesDirectory.appendingPathComponent("\($0).png") }
    }

    private func cleanupOrphanImages() {
        let used = Set((history + pinboards.flatMap(\.items)).compactMap(\.imageFile))
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: imagesDirectory.path) else { return }
        for file in files {
            let base = file.replacingOccurrences(of: "-thumb.png", with: "").replacingOccurrences(of: ".png", with: "")
            if !used.contains(base) {
                try? FileManager.default.removeItem(at: imagesDirectory.appendingPathComponent(file))
                thumbCache.removeObject(forKey: base as NSString)
            }
        }
    }

    static func pixelSize(of image: NSImage) -> CGSize {
        let w = image.representations.map(\.pixelsWide).max() ?? 0
        let h = image.representations.map(\.pixelsHigh).max() ?? 0
        return w > 0 && h > 0 ? CGSize(width: w, height: h) : image.size
    }

    /// Draws the image into a downscaled bitmap representation and returns PNG data.
    static func pngData(_ image: NSImage, maxSide: CGFloat) -> Data? {
        let size = pixelSize(of: image)
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(1, maxSide / max(size.width, size.height))
        let w = max(1, Int(size.width * scale)), h = max(1, Int(size.height * scale))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    private static func fnv1a(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return String(hash, radix: 16)
    }
}
