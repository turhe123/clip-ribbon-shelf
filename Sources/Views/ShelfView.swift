import AppKit
import SwiftUI

/// Root view of the shelf: pinboard tabs, the typed-search pill and the horizontal card strip.
struct ShelfView: View {
    @ObservedObject var model: ShelfModel
    @ObservedObject var store: ClipStore
    @AppStorage(Prefs.shelfHeight) private var shelfHeight = 240.0
    @AppStorage(Prefs.cardWidth) private var cardWidth = 220.0
    @FocusState private var nameFieldFocused: Bool

    private var reduceTransparency: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency }

    var body: some View {
        let items = model.items
        VStack(alignment: .leading, spacing: 10) {
            header
            if let board = model.pendingDelete { deleteConfirmation(board) }
            if items.isEmpty { emptyState } else { strip(items) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background {
            let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
            if reduceTransparency {
                shape.fill(Color(nsColor: .windowBackgroundColor))
            } else {
                shape.fill(.ultraThinMaterial)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.15)))
        .offset(y: model.isShown ? 0 : shelfHeight + 20)
        .opacity(model.isShown ? 1 : 0)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    tabButton("History", systemImage: "clock", tab: .history, shortcut: nil)
                    ForEach(Array(store.pinboards.enumerated()), id: \.element.id) { index, board in
                        tabButton(board.name, systemImage: "pin", tab: .board(board.id),
                                  shortcut: index < 9 ? "⌘\(index + 1)" : nil)
                            .dropDestination(for: String.self) { ids, _ in
                                let clips = ids.compactMap { UUID(uuidString: $0) }.compactMap(store.item(withID:))
                                clips.forEach { store.pin($0, to: board.id) }
                                return !clips.isEmpty
                            }
                            .contextMenu {
                                Button("Delete Pinboard…", role: .destructive) { model.pendingDelete = board }
                            }
                    }
                    newBoardControl
                }
            }
            Spacer(minLength: 8)
            if !model.query.isEmpty {
                Label(model.query, systemImage: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel("Filter: \(model.query)")
            }
            Button { ShelfController.shared.hide { AppWindows.showSettings() } } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .frame(height: 28)
    }

    private func tabButton(_ title: String, systemImage: String, tab: ShelfTab, shortcut: String?) -> some View {
        let selected = model.tab == tab
        return Button { model.select(tab: tab) } label: {
            HStack(spacing: 4) {
                Image(systemName: systemImage).imageScale(.small)
                Text(title).lineLimit(1)
                if let shortcut { Text(shortcut).font(.caption2).foregroundStyle(.secondary) }
            }
            .font(.system(size: 12, weight: selected ? .semibold : .regular))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(selected ? AnyShapeStyle(Color.accentColor.opacity(0.25)) : AnyShapeStyle(.quaternary),
                        in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) tab")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var newBoardControl: some View {
        if model.creatingBoard {
            TextField("Pinboard name", text: $model.newBoardName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .focused($nameFieldFocused)
                .onAppear { nameFieldFocused = true }
                .onSubmit {
                    if let board = store.createPinboard(named: model.newBoardName) { model.select(tab: .board(board.id)) }
                    model.creatingBoard = false
                }
        } else {
            Button {
                model.newBoardName = ""
                model.creatingBoard = true
            } label: {
                Image(systemName: "plus").padding(6).background(.quaternary, in: Circle())
            }
            .buttonStyle(.plain)
            .help("New Pinboard")
            .accessibilityLabel("New pinboard")
        }
    }

    private func deleteConfirmation(_ board: Pinboard) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("Delete “\(board.name)”? Its cards will move back to History.")
            Spacer()
            Button("Cancel") { model.pendingDelete = nil }
            Button("Delete", role: .destructive) {
                store.deletePinboard(board.id)
                model.pendingDelete = nil
                model.select(tab: .history)
            }
            .keyboardShortcut(.defaultAction)
        }
        .font(.system(size: 12))
    }

    // MARK: Cards

    private var emptyState: some View {
        let text: String
        if !model.query.isEmpty { text = "No clips match “\(model.query)”" }
        else if model.tab == .history { text = "Your shelf is empty — copy something and it will appear here." }
        else { text = "Drag cards here" }
        return VStack(spacing: 8) {
            Image(systemName: model.tab == .history ? "doc.on.clipboard" : "pin.square")
                .font(.system(size: 30)).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func strip(_ items: [ClipItem]) -> some View {
        let cardHeight = max(100, shelfHeight - 76)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        CardView(item: item, selected: index == model.selection, store: store)
                            .frame(width: cardWidth, height: cardHeight)
                            .id(item.id)
                            .onTapGesture(count: 2) { ShelfController.shared.paste(item) }
                            .onTapGesture { model.selection = index }
                            .draggable(item.id.uuidString)
                            .contextMenu { cardMenu(item) }
                            .popover(isPresented: Binding(
                                get: { model.previewShown && model.selection == index },
                                set: { if !$0 { model.previewShown = false } }), arrowEdge: .top) {
                                QuickLookView(item: item, store: store)
                            }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: model.selection) { _, newValue in
                guard items.indices.contains(newValue) else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(items[newValue].id, anchor: .center) }
            }
        }
    }

    @ViewBuilder private func cardMenu(_ item: ClipItem) -> some View {
        Button("Paste") { ShelfController.shared.paste(item) }
        Button("Copy") { ClipboardMonitor.write(item) }
        if !store.pinboards.isEmpty {
            Menu("Add to Pinboard") {
                ForEach(store.pinboards) { board in Button(board.name) { store.pin(item, to: board.id) } }
            }
        }
        Divider()
        Button("Delete", role: .destructive) { store.delete(item, from: model.tab) }
    }
}

/// One rounded card with a type-aware preview, source app icon and time stamp.
struct CardView: View {
    let item: ClipItem
    let selected: Bool
    let store: ClipStore

    private var tint: Color {
        switch item.kind {
        case .text: return .blue
        case .link: return .teal
        case .image: return .purple
        case .file: return .orange
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.kind.label).font(.system(size: 12, weight: .bold))
                    Text(item.date, format: .relative(presentation: .named)).font(.system(size: 10)).opacity(0.85)
                }
                Spacer()
                if let icon = AppIconCache.icon(for: item.sourceBundleID) {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(tint.gradient)

            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.1), lineWidth: selected ? 3 : 1))
        .shadow(color: .black.opacity(0.18), radius: selected ? 6 : 3, y: 2)
        .scaleEffect(selected ? 1.0 : 0.97)
        .animation(.easeOut(duration: 0.12), value: selected)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.kind.label) card from \(item.sourceName ?? "unknown app"): \(item.summary)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint("Press Return to paste, Space for a larger preview")
    }

    @ViewBuilder private var preview: some View {
        switch item.kind {
        case .text:
            Text(String(item.text.prefix(800)))
                .font(.system(size: 12))
                .foregroundStyle(.primary)
        case .link:
            VStack(alignment: .leading, spacing: 4) {
                Image(systemName: "link.circle.fill").font(.system(size: 26)).foregroundStyle(tint)
                Text(item.linkTitle).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                Text(item.host).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Text(item.text).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(3)
            }
        case .image:
            if let thumb = store.thumbnail(for: item) {
                Image(nsImage: thumb).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Label("Image unavailable", systemImage: "photo").foregroundStyle(.secondary)
            }
        case .file:
            let paths = item.filePaths
            VStack(spacing: 6) {
                if let first = paths.first {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: first)).resizable().frame(width: 56, height: 56)
                    Text((first as NSString).lastPathComponent)
                        .font(.system(size: 12, weight: .medium)).lineLimit(2).multilineTextAlignment(.center)
                }
                if paths.count > 1 {
                    Text("and \(paths.count - 1) more").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Larger "quick look" preview shown in a popover when Space is pressed.
struct QuickLookView: View {
    let item: ClipItem
    let store: ClipStore

    var body: some View {
        Group {
            switch item.kind {
            case .image:
                if let url = store.fullImageURL(for: item), let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: 560, maxHeight: 400)
                }
            default:
                ScrollView {
                    Text(item.text).font(.system(size: 13, design: item.kind == .text ? .monospaced : .default))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 480, height: 300)
            }
        }
        .padding(12)
    }
}

/// Caches application icons looked up by bundle identifier.
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]

    static func icon(for bundleID: String?) -> NSImage? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        cache[bundleID] = icon
        return icon
    }
}
