import SwiftUI
import AVFoundation
import UniformTypeIdentifiers

/// Folder-tree browser for one asset library (Music, Fonts, or Images).
/// Users navigate subfolders via breadcrumbs, create folders, and add files
/// through the importer or by dropping them from Finder. Presentation adapts
/// per kind: audio rows with preview playback, font rows with rendered
/// samples, image thumbnails in a grid.
struct AssetBrowserView: View {
    let kind: AssetKind

    /// Path components below the library root; empty = root.
    @State private var path: [String] = []
    @State private var items: [AssetItem] = []
    @State private var watcher: FolderWatcher?

    @State private var showingImporter = false
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: AssetItem?
    @State private var renameText = ""
    @State private var deleteTarget: AssetItem?
    @State private var previewImage: AssetItem?
    @State private var operationError: String?

    // Music preview playback — one shared player, the playing row's id.
    @State private var player: AVPlayer?
    @State private var playingID: String?

    private var currentFolder: URL {
        path.reduce(kind.rootURL) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    var body: some View {
        VStack(spacing: 0) {
            breadcrumbBar
            Divider()
            if items.isEmpty {
                emptyState
            } else if kind == .images {
                imageGrid
            } else {
                listContent
            }
        }
        .navigationTitle(kind.title)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button {
                    newFolderName = ""
                    showingNewFolder = true
                } label: {
                    Label("New Folder", systemImage: "folder.badge.plus")
                }
                .help("Create a folder inside the current folder")

                Button {
                    showingImporter = true
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
                .help("Copy files into the current folder")

                Button {
                    NSWorkspace.shared.open(currentFolder)
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .help("Open the current folder in Finder")
            }
        }
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: kind.contentTypes,
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                importFiles(urls)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            importFiles(urls)
            return true
        }
        .alert("New Folder", isPresented: $showingNewFolder) {
            TextField("Name", text: $newFolderName)
            Button("Create") { createFolder() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Rename") { renameItem() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .alert("Error", isPresented: Binding(
            get: { operationError != nil },
            set: { if !$0 { operationError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(operationError ?? "")
        }
        .confirmationDialog(
            deleteTarget.map { "Move “\($0.name)” to the Trash?" } ?? "Move to Trash?",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })
        ) {
            Button("Move to Trash", role: .destructive) {
                if let deleteTarget { perform { try AssetStore.trash(deleteTarget) } }
                deleteTarget = nil
            }
            Button("Cancel", role: .cancel) { deleteTarget = nil }
        } message: {
            if let deleteTarget, deleteTarget.isFolder {
                Text("The folder and everything inside it moves to the Trash.")
            }
        }
        .sheet(item: $previewImage) { item in
            ImagePreviewSheet(url: item.url, title: item.name)
        }
        .onAppear {
            AssetStore.ensureRoots()
            refresh()
            let watcher = FolderWatcher { refresh() }
            watcher.watch(currentFolder)
            self.watcher = watcher
        }
        .onDisappear {
            watcher?.stop()
            watcher = nil
            stopPlayback()
        }
        .onChange(of: path) {
            stopPlayback()
            refresh()
            watcher?.watch(currentFolder)
        }
    }

    private var subtitle: String {
        let folders = items.filter(\.isFolder).count
        let files = items.count - folders
        var parts: [String] = []
        if folders > 0 { parts.append("\(folders) folder\(folders == 1 ? "" : "s")") }
        parts.append("\(files) file\(files == 1 ? "" : "s")")
        return parts.joined(separator: ", ")
    }

    // MARK: - Navigation

    private var breadcrumbBar: some View {
        HStack(spacing: 4) {
            breadcrumbButton(title: kind.title, depth: 0)
            ForEach(Array(path.enumerated()), id: \.offset) { index, component in
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                breadcrumbButton(title: component, depth: index + 1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func breadcrumbButton(title: String, depth: Int) -> some View {
        Button(title) {
            path = Array(path.prefix(depth))
        }
        .buttonStyle(.plain)
        .fontWeight(depth == path.count ? .semibold : .regular)
        .foregroundStyle(depth == path.count ? .primary : .secondary)
        .disabled(depth == path.count)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(path.isEmpty ? "No \(kind.title) Yet" : "Empty Folder", systemImage: kind.systemImage)
        } description: {
            Text("\(kind.emptyHint) Drop files here, or use Add Files.")
        } actions: {
            Button("Add Files…") { showingImporter = true }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - List (music, fonts)

    private var listContent: some View {
        List(items) { item in
            row(for: item)
                .contextMenu { contextMenu(for: item) }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func row(for item: AssetItem) -> some View {
        if item.isFolder {
            Button {
                open(item)
            } label: {
                Label(item.name, systemImage: "folder.fill")
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else if kind == .music {
            MusicRow(item: item, isPlaying: playingID == item.id) {
                togglePlayback(item)
            }
        } else {
            FontRow(item: item)
        }
    }

    // MARK: - Grid (images)

    private var imageGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(items) { item in
                    imageTile(for: item)
                        .contextMenu { contextMenu(for: item) }
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func imageTile(for item: AssetItem) -> some View {
        VStack(spacing: 6) {
            if item.isFolder {
                Image(systemName: "folder.fill")
                    .font(.system(size: 42))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 100)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            } else {
                ImageThumbnail(url: item.url)
                    .frame(height: 100)
            }
            Text(item.name)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if item.isFolder {
                open(item)
            } else {
                previewImage = item
            }
        }
        .help(item.isFolder ? "Double-click to open" : "Double-click to preview")
    }

    // MARK: - Shared actions

    @ViewBuilder
    private func contextMenu(for item: AssetItem) -> some View {
        if item.isFolder {
            Button("Open") { open(item) }
        } else if kind == .music {
            Button(playingID == item.id ? "Stop" : "Play") { togglePlayback(item) }
        } else if kind == .images {
            Button("Preview") { previewImage = item }
        }
        Button("Rename…") {
            renameText = item.name
            renameTarget = item
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        }
        Divider()
        Button("Move to Trash", role: .destructive) { deleteTarget = item }
    }

    private func open(_ folder: AssetItem) {
        path.append(folder.name)
    }

    private func refresh() {
        items = AssetStore.items(of: kind, in: currentFolder)
        if let playingID, !items.contains(where: { $0.id == playingID }) {
            stopPlayback()
        }
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        perform { try AssetStore.createFolder(named: name, in: currentFolder) }
    }

    private func renameItem() {
        if let renameTarget { perform { try AssetStore.rename(renameTarget, to: renameText) } }
        renameTarget = nil
    }

    private func importFiles(_ urls: [URL]) {
        perform {
            let imported = try AssetStore.importFiles(urls, of: kind, into: currentFolder)
            if imported == 0, !urls.isEmpty {
                let allowed = kind.allowedExtensions.sorted().joined(separator: ", ").uppercased()
                operationError = "No matching files to import. \(kind.title) accepts: \(allowed)."
            }
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            refresh()
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func togglePlayback(_ item: AssetItem) {
        if playingID == item.id {
            stopPlayback()
        } else {
            player?.pause()
            let player = AVPlayer(url: item.url)
            player.play()
            self.player = player
            playingID = item.id
        }
    }

    private func stopPlayback() {
        player?.pause()
        player = nil
        playingID = nil
    }
}

/// Audio file row: play/stop toggle, name, duration.
private struct MusicRow: View {
    let item: AssetItem
    let isPlaying: Bool
    let togglePlay: () -> Void

    @State private var duration: Double?

    var body: some View {
        HStack(spacing: 10) {
            Button(action: togglePlay) {
                Image(systemName: isPlaying ? "stop.circle.fill" : "play.circle")
                    .font(.title2)
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(isPlaying ? "Stop" : "Play")

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)
                Text(item.url.pathExtension.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let duration {
                Text(duration.timecode)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .task(id: item.id) {
            let asset = AVURLAsset(url: item.url)
            if let loaded = try? await asset.load(.duration) {
                duration = loaded.seconds
            }
        }
    }
}

/// Font file row: display name plus a sample line rendered in the font.
private struct FontRow: View {
    let item: AssetItem

    @State private var fontName: String?
    @State private var sampleFont: Font?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(fontName ?? item.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(item.url.pathExtension.uppercased())
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text("The quick brown fox jumps over the lazy dog")
                .font(sampleFont ?? .title3)
                .lineLimit(1)
                .redacted(reason: sampleFont == nil ? .placeholder : [])
        }
        .padding(.vertical, 4)
        .task(id: item.id) {
            // Loading the descriptor off the file avoids requiring the font
            // to be registered before it can be previewed.
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(item.url as CFURL) as? [CTFontDescriptor],
                  let descriptor = descriptors.first else { return }
            let ctFont = CTFontCreateWithFontDescriptor(descriptor, 18, nil)
            fontName = CTFontCopyDisplayName(ctFont) as String
            sampleFont = Font(ctFont)
        }
    }
}

/// Async downsampled image thumbnail (full-size decodes would balloon memory
/// in a large grid).
private struct ImageThumbnail: View {
    let url: URL

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Color.clear
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
            } else {
                Rectangle()
                    .fill(.quaternary)
                ProgressView()
                    .controlSize(.small)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: url.path) {
            image = await Self.thumbnail(for: url)
        }
    }

    private static func thumbnail(for url: URL) async -> NSImage? {
        let path = url
        return await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(path as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 400,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return nil
            }
            return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        }.value
    }
}

/// Full-size image viewer sheet.
private struct ImagePreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let title: String

    @State private var image: NSImage?
    @State private var loadFailed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(minWidth: 420, maxWidth: 900, minHeight: 320, maxHeight: 700)
                    .padding([.horizontal, .bottom])
            } else if loadFailed {
                ContentUnavailableView("Can't Load Image", systemImage: "photo")
                    .frame(minWidth: 420, minHeight: 320)
            } else {
                ProgressView()
                    .frame(minWidth: 420, minHeight: 320)
            }
        }
        .task {
            image = NSImage(contentsOf: url)
            loadFailed = image == nil
        }
    }
}
