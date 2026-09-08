import SwiftUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// Folder-tree browser for one asset library (Music, Fonts, or Images).
/// Users navigate subfolders via breadcrumbs, create folders, and add files
/// through the importer or by dropping them from Finder. Presentation adapts
/// per kind: audio rows with preview playback, font rows with rendered
/// samples, image thumbnails in a grid.
struct AssetBrowserView: View {
    @State private var showingDriveBrowser = false
    @Environment(AppStore.self) private var store
    let kind: AssetKind

    /// Path components below the library root; empty = root.
    @State private var path: [String] = []
    @State private var items: [AssetItem] = []
    /// Every folder in the library (root-relative), for "Move to…".
    @State private var folderNames: [String] = []
    @State private var refreshVersion = 0
    @State private var watcher: FolderWatcher?

    @State private var showingImporter = false
    @State private var showingNewFolder = false
    @State private var newFolderName = ""
    @State private var renameTarget: AssetItem?
    @State private var renameText = ""
    @State private var deleteTarget: AssetItem?
    @State private var previewImage: AssetItem?
    @State private var editingBumper: BumperAsset?
    @State private var operationError: String?
    @State private var searchText = ""
    @State private var metadata: [String: LibraryAssetMetadata] = [:]
    @State private var analyzingPaths: Set<String> = []
    @State private var showingAskImages = false
    @State private var matchedImagePaths: Set<String>?

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
            } else if kind == .bumpers {
                bumperGrid
            } else if kind == .images {
                imageGrid
            } else {
                listContent
            }
        }
        .sheet(isPresented: $showingDriveBrowser) { GoogleDriveBrowserSheet() }
        .screenTitle(kind.title, subtitle: subtitle)
        .toolbar {
            ToolbarItemGroup {
                Button("Add Files", systemImage: "plus") {
                    showingImporter = true
                }
                .help("Copy files into the current folder")
                Button("Add from Google Drive…", systemImage: "icloud.and.arrow.down") { showingDriveBrowser = true }
                    .help("Add Drive media to this project’s Sources")

                if kind == .images {
                    Button("Ask Images", systemImage: "sparkle.magnifyingglass") {
                        showingAskImages = true
                    }
                    .disabled(items.filter { !$0.isFolder }.isEmpty)
                    if matchedImagePaths != nil {
                        Button("Clear AI Search", systemImage: "xmark.circle") {
                            matchedImagePaths = nil
                        }
                    }
                }

                Menu("More", systemImage: "ellipsis.circle") {
                    Button("New Folder", systemImage: "folder.badge.plus") {
                        newFolderName = ""
                        showingNewFolder = true
                    }
                    Divider()
                    Button("Show in Finder", systemImage: "folder") {
                        NSWorkspace.shared.open(currentFolder)
                    }
                    if kind == .images {
                        Button("Tag Images with AI", systemImage: "sparkles") {
                            analyzeVisibleImages()
                        }
                        .disabled(analyzingPaths.isEmpty == false)
                    }
                }
                .help("Create folders or reveal this library in Finder")
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
            receive(urls, into: currentFolder)
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
        .sheet(item: $editingBumper) { bumper in
            BumperEditor(bumper: bumper).environment(store)
        }
        .sheet(item: $previewImage) { item in
            ImagePreviewSheet(url: item.url, title: item.name)
        }
        .sheet(isPresented: $showingAskImages) {
            ImageLibrarySearchSheet(
                candidates: items.filter { !$0.isFolder }, metadata: metadata
            ) { paths in
                matchedImagePaths = Set(paths)
            }
            .environment(store)
        }
        .onAppear {
            AssetStore.ensureRoots()
            refresh()
            let watcher = FolderWatcher { handleExternalChange() }
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
        .searchable(text: $searchText, prompt: "Name, fighter, event, or tag")
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
        let target = folderURL(forDepth: depth)
        return Button(title) {
            path = Array(path.prefix(depth))
        }
        .buttonStyle(.plain)
        .fontWeight(depth == path.count ? .semibold : .regular)
        .foregroundStyle(depth == path.count ? .primary : .secondary)
        .disabled(depth == path.count)
        // Dragging a row onto an ancestor crumb moves it up the tree.
        .dropDestination(for: URL.self) { urls, _ in
            guard depth < path.count else { return false }
            receive(urls, into: target)
            return true
        }
    }

    private func folderURL(forDepth depth: Int) -> URL {
        path.prefix(depth).reduce(kind.rootURL) { $0.appendingPathComponent($1, isDirectory: true) }
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
                .draggable(item.url)
                .modifier(FolderDropTarget(folder: item.isFolder ? item.url : nil) { receive($0, into: $1) })
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

    private func bumper(for item: AssetItem) -> BumperAsset {
        store.bumpers.first { $0.path == item.url.path }
            ?? BumperAsset(path: item.url.path, displayName: item.displayName)
    }

    private var bumperGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), alignment: .top)], spacing: 12) {
                ForEach(filteredItems) { item in
                    if item.isFolder {
                        imageTile(for: item).contextMenu { contextMenu(for: item) }
                            .draggable(item.url)
                            .modifier(FolderDropTarget(folder: item.url) { receive($0, into: $1) })
                    } else {
                        let asset = bumper(for: item)
                        VStack(alignment: .leading, spacing: 6) {
                            VideoThumbnail(url: item.url, time: 0)
                                .frame(height: 110)
                            HStack {
                                Text(asset.displayName).lineLimit(1)
                                Spacer()
                                Button("Edit Bumper", systemImage: "pencil") { editingBumper = asset }
                                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                            }
                            Text(asset.duration.map { String(format: "%.1f seconds", $0) } ?? "Duration unavailable")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack(spacing: 4) {
                                ForEach(BumperPlacement.allCases.filter { asset.placements.contains($0) }) { placement in
                                    Text(placement.title).font(.caption2)
                                        .padding(4).background(.quaternary, in: .capsule)
                                }
                            }
                        }
                        .padding(8)
                        .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 8))
                        .contextMenu { contextMenu(for: item) }
                        .draggable(item.url)
                    }
                }
            }.padding()
        }
    }

    // MARK: - Grid (images)

    private var imageGrid: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12, alignment: .top)], spacing: 12) {
                ForEach(filteredItems) { item in
                    imageTile(for: item)
                        .contextMenu { contextMenu(for: item) }
                        .draggable(item.url)
                        .modifier(FolderDropTarget(folder: item.isFolder ? item.url : nil) { receive($0, into: $1) })
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func imageTile(for item: AssetItem) -> some View {
        Button {
            if item.isFolder {
                open(item)
            } else {
                previewImage = item
            }
        } label: {
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
                        .overlay(alignment: .topTrailing) {
                            if analyzingPaths.contains(item.url.path) {
                                ProgressView().controlSize(.small).padding(6)
                            } else if metadata[item.url.path]?.isBRoll == true {
                                Label("B-roll", systemImage: "rectangle.on.rectangle")
                                    .font(.caption)
                                    .padding(4)
                                    .background(.regularMaterial, in: .capsule)
                                    .padding(5)
                            }
                        }
                }
                Text(item.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let info = metadata[item.url.path], !info.subjects.isEmpty {
                    Text(info.subjects.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.isFolder ? "Open folder \(item.name)" : "Preview image \(item.name)")
        .help(item.isFolder ? "Open folder" : "Preview image")
    }

    // MARK: - Shared actions

    @ViewBuilder
    private func contextMenu(for item: AssetItem) -> some View {
        if kind == .bumpers, !item.isFolder {
            Button("Edit Bumper…", systemImage: "pencil") { editingBumper = bumper(for: item) }
        }
        if item.isFolder {
            Button("Open") { open(item) }
        } else if kind == .music {
            Button(playingID == item.id ? "Stop" : "Play") { togglePlayback(item) }
        } else if kind == .images {
            Button("Preview") { previewImage = item }
            Button(metadata[item.url.path]?.isBRoll == true ? "Remove B-roll Mark" : "Mark as B-roll") {
                toggleBRoll(item)
            }
            Button("Analyze Subjects and Tags", systemImage: "sparkles") {
                analyzeImage(item)
            }
        }
        Button("Rename…") {
            renameText = item.name
            renameTarget = item
        }
        Menu("Move to…", systemImage: "folder") {
            let destinations = moveDestinations(for: item)
            if destinations.isEmpty {
                Text("No other folders")
            }
            ForEach(destinations, id: \.url) { destination in
                Button(destination.title) { receive([item.url], into: destination.url) }
            }
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

    /// Folders `item` can move into: the root plus every library folder,
    /// minus where it already is and (for a folder) itself and its subtree.
    private func moveDestinations(for item: AssetItem) -> [(title: String, url: URL)] {
        let here = AssetStore.relativeFolderName(item.url.deletingLastPathComponent(), of: kind)
        let own = item.isFolder ? AssetStore.relativeFolderName(item.url, of: kind) : nil
        let candidates = [""] + folderNames
        return candidates.compactMap { name in
            guard name != here else { return nil }
            if let own, name == own || name.hasPrefix(own + "/") { return nil }
            let url = name.split(separator: "/").reduce(kind.rootURL) {
                $0.appendingPathComponent(String($1), isDirectory: true)
            }
            return (name.isEmpty ? kind.title : name, url)
        }
    }

    private func isLibraryURL(_ url: URL) -> Bool {
        let root = kind.rootURL.resolvingSymlinksInPath().path
        return url.resolvingSymlinksInPath().path.hasPrefix(root + "/")
    }

    /// Dropped or chosen URLs: items already in this library move into
    /// `folder`; anything else is copied in from outside.
    private func receive(_ urls: [URL], into folder: URL) {
        let (internalURLs, external) = urls.reduce(into: ([URL](), [URL]())) { result, url in
            if isLibraryURL(url) { result.0.append(url) } else { result.1.append(url) }
        }
        if !internalURLs.isEmpty { moveItems(internalURLs, into: folder) }
        if !external.isEmpty { importFiles(external, into: folder) }
    }

    private func moveItems(_ urls: [URL], into folder: URL) {
        let kind = kind
        Task {
            do {
                for url in urls {
                    let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    let item = AssetItem(url: url, isFolder: isFolder)
                    let destination = try AssetStore.move(item, into: folder)
                    if kind == .bumpers, !isFolder, destination != url {
                        try await store.database?.moveBumperMetadata(from: url, to: destination)
                    }
                }
            } catch { operationError = error.localizedDescription }
            refresh()
        }
    }

    private func refresh() {
        refreshVersion += 1
        let version = refreshVersion
        let folder = currentFolder
        let kind = kind
        Task {
            async let folders = AssetStore.folderNamesAsync(of: kind)
            let refreshed = await AssetStore.itemsAsync(of: kind, in: folder)
            guard !Task.isCancelled, version == refreshVersion, folder == currentFolder else { return }
            items = refreshed
            folderNames = await folders
            if let playingID, !items.contains(where: { $0.id == playingID }) { stopPlayback() }
            if kind == .images || kind == .bumpers { loadMetadata() }
            if kind == .bumpers { store.refreshBumpers() }
        }
    }

    private var filteredItems: [AssetItem] {
        items.filter { item in
            let matchesAI = matchedImagePaths.map { item.isFolder || $0.contains(item.url.path) } ?? true
            guard matchesAI else { return false }
            guard !searchText.isEmpty else { return true }
            return item.isFolder || item.name.localizedStandardContains(searchText)
                || (kind == .bumpers && bumper(for: item).displayName.localizedStandardContains(searchText))
                || metadata[item.url.path]?.subjects.contains(where: { $0.localizedStandardContains(searchText) }) == true
                || metadata[item.url.path]?.tags.contains(where: { $0.localizedStandardContains(searchText) }) == true
        }
    }

    private func loadMetadata() {
        guard let database = store.database else { return }
        Task {
            let rows = (try? await database.fetchAssetMetadata(kind: kind.rawValue)) ?? []
            metadata = Dictionary(uniqueKeysWithValues: rows.map { ($0.path, $0) })
        }
    }

    private func toggleBRoll(_ item: AssetItem) {
        guard let database = store.database else { return }
        var info = metadata[item.url.path]
            ?? LibraryAssetMetadata(path: item.url.path, kind: AssetKind.images.rawValue,
                                    isBRoll: false, subjects: [], tags: [], provider: nil, model: nil)
        info.isBRoll.toggle()
        metadata[item.url.path] = info
        Task {
            do { try await database.upsertAssetMetadata(info) }
            catch { store.presentError("Could not save image tags", error) }
        }
    }

    /// How many images are tagged at once: each is an AI CLI subprocess
    /// carrying a photo, so a library of hundreds must not fan out unbounded.
    private static let imageTaggingConcurrency = 3

    private func analyzeVisibleImages() {
        let pending = filteredItems.filter { !$0.isFolder && !analyzingPaths.contains($0.url.path) }
        guard !pending.isEmpty else { return }
        for item in pending { analyzingPaths.insert(item.url.path) }
        Task {
            await withTaskGroup(of: Void.self) { group in
                var iterator = pending.makeIterator()
                for _ in 0..<Self.imageTaggingConcurrency {
                    if let item = iterator.next() { group.addTask { await self.tagImage(item) } }
                }
                for await _ in group {
                    if let item = iterator.next() { group.addTask { await self.tagImage(item) } }
                }
            }
        }
    }

    private func analyzeImage(_ item: AssetItem) {
        guard !analyzingPaths.contains(item.url.path) else { return }
        analyzingPaths.insert(item.url.path)
        Task { await tagImage(item) }
    }

    /// Downsampled JPEG for the tagger, decoded away from the main actor: a
    /// 12-megapixel photo is neither needed nor affordable on the UI thread.
    private nonisolated static func taggingPayload(for url: URL) async -> Data? {
        await Task.detached(priority: .utility) { () -> Data? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 1600,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                  ] as CFDictionary) else { return nil }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)
            else { return nil }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
            return CGImageDestinationFinalize(destination) ? data as Data : nil
        }.value
    }

    /// Tag one image; the caller has already marked it in `analyzingPaths`.
    private func tagImage(_ item: AssetItem) async {
        defer { analyzingPaths.remove(item.url.path) }
        guard let database = store.database else { return }
        let knownPeople = store.people.filter { !$0.name.isEmpty }.map(\.name)
        do {
            guard let jpeg = await Self.taggingPayload(for: item.url) else {
                store.presentError("Could not read \(item.name)")
                return
            }
            let prompt = """
                Tag this owned library image for editorial search. Known people: \(knownPeople.joined(separator: ", ")).
                Return only JSON: {"subjects":["person/event/topic"],"tags":["crowd|walkout|training|establishing-shot|action|portrait|graphic|other"],"is_broll":true|false}.
                Match a known person only when visually confident. B-roll means a cutaway, atmosphere, training, walkout, crowd, or establishing visual.
                """
            let response = try await store.ai.call(prompt: prompt, task: "analyze",
                                                   frames: [AIFrame(jpeg: jpeg, label: item.name)],
                                                   timeout: 120, log: { _ in })
            guard let object = AIResponseParser.jsonObject(from: response.text) else {
                throw AIError.unusableResponse("Image tagger returned invalid JSON")
            }
            let info = LibraryAssetMetadata(
                path: item.url.path, kind: AssetKind.images.rawValue,
                isBRoll: object["is_broll"] as? Bool ?? false,
                subjects: object["subjects"] as? [String] ?? [],
                tags: object["tags"] as? [String] ?? [],
                provider: response.provider, model: response.model)
            try await database.upsertAssetMetadata(info)
            metadata[item.url.path] = info
        } catch {
            store.presentError("Could not tag \(item.name)", error)
        }
    }

    private func handleExternalChange() {
        AssetStore.invalidateCatalog(kind)
        ImageCache.removeAll()
        if kind == .fonts { AssetStore.registerFonts() }
        refresh()
    }

    private func createFolder() {
        let name = newFolderName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        perform { try AssetStore.createFolder(named: name, in: currentFolder) }
    }

    private func renameItem() {
        guard let item = renameTarget else { return }
        let name = renameText
        renameTarget = nil
        Task {
            do {
                let destination = try AssetStore.rename(item, to: name)
                if kind == .bumpers {
                    try await store.database?.moveBumperMetadata(from: item.url, to: destination)
                }
            } catch { operationError = error.localizedDescription }
            refresh()
        }
    }

    private func importFiles(_ urls: [URL]) {
        importFiles(urls, into: currentFolder)
    }

    private func importFiles(_ urls: [URL], into folder: URL) {
        let kind = kind
        Task {
            do {
                let imported = try await AssetStore.importFiles(urls, of: kind, into: folder)
                if imported == 0, !urls.isEmpty {
                    let allowed = kind.allowedExtensions.sorted().joined(separator: ", ").uppercased()
                    operationError = "No matching files to import. \(kind.title) accepts: \(allowed)."
                }
            } catch { operationError = error.localizedDescription }
            // Also refresh after a partial success followed by an error.
            refresh()
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

/// Makes a folder row or tile accept dragged library items (and outside
/// files); a nil folder leaves the view untouched so file rows stay inert.
private struct FolderDropTarget: ViewModifier {
    let folder: URL?
    let receive: ([URL], URL) -> Void

    @State private var isTargeted = false

    func body(content: Content) -> some View {
        if let folder {
            content
                .background(isTargeted ? Color.accentColor.opacity(0.15) : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .dropDestination(for: URL.self) { urls, _ in
                    // A folder dropped on itself is a no-op, not an error.
                    guard !urls.contains(where: { $0.standardizedFileURL == folder.standardizedFileURL }) else {
                        return false
                    }
                    receive(urls, folder)
                    return true
                } isTargeted: { isTargeted = $0 }
        } else {
            content
        }
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
                Label(isPlaying ? "Stop preview" : "Play preview",
                      systemImage: isPlaying ? "stop.circle.fill" : "play.circle")
                    .font(.title2)
                    .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary)
            }
            .labelStyle(.iconOnly)
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
/// in a large grid). Shared with the image-overlay picker.
struct ImageThumbnail: View {
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
        await ImageCache.image(for: url, maxPixel: 400)
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
        .modalCloseButton { dismiss() }
        .task(id: url.path) {
            image = await ImageCache.image(for: url, maxPixel: 1800)
            loadFailed = image == nil
        }
    }
}
