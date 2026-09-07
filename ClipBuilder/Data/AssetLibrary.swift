import Foundation
import CoreText
import Synchronization
import UniformTypeIdentifiers

/// The shared asset libraries under `~/Documents/ClipBuilder/assets` —
/// per-user, shared across profiles (music already lived there feeding the
/// Wizard and Builder). Each library is a plain folder tree the user can
/// organize into subfolders; the sidebar's Music/Fonts/Images sections browse
/// them in-app.
nonisolated enum AssetKind: String, CaseIterable, Identifiable, Sendable {
    case music
    case fonts
    case images

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: return "Music"
        case .fonts: return "Fonts"
        case .images: return "Images"
        }
    }

    var systemImage: String {
        switch self {
        case .music: return "music.note"
        case .fonts: return "textformat"
        case .images: return "photo.on.rectangle.angled"
        }
    }

    /// `~/Documents/ClipBuilder/assets/<kind>`.
    var rootURL: URL {
        ProfileStore.profilesDirectory.appendingPathComponent("assets/\(rawValue)", isDirectory: true)
    }

    var allowedExtensions: Set<String> {
        switch self {
        case .music: return ["mp3", "m4a", "wav", "aac", "flac"]
        case .fonts: return ["ttf", "otf", "ttc"]
        case .images: return ["png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp"]
        }
    }

    /// Types offered by the file importer.
    var contentTypes: [UTType] {
        allowedExtensions.compactMap { UTType(filenameExtension: $0) }
    }

    var emptyHint: String {
        switch self {
        case .music: return "Add audio tracks (MP3, M4A, WAV, AAC, FLAC) for the Wizard and Builder to use as background music."
        case .fonts: return "Add font files (TTF, OTF, TTC) to use in captions and text overlays."
        case .images: return "Add images (PNG, JPEG, HEIC, …) to keep logos and artwork alongside your footage."
        }
    }
}

/// One entry in an asset folder: a subfolder or a media file.
nonisolated struct AssetItem: Identifiable, Hashable, Sendable {
    var url: URL
    var isFolder: Bool

    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var displayName: String {
        isFolder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
    }
}

/// File operations for the asset libraries. All throwing calls surface
/// FileManager errors to the caller for alert display.
nonisolated enum AssetStore {
    private struct FileListing {
        var files: [(name: String, url: URL)]
        var fingerprint: [String]
        var checkedAt: TimeInterval
    }

    private struct FontFamilies {
        var fingerprint: [String]
        var names: [String]
    }

    private struct CatalogCache {
        var files: [AssetKind: FileListing] = [:]
        var fontFamilies: FontFamilies?
        var revision = 0
        var refreshing: Set<AssetKind> = []
        var roots: [AssetKind: URL] = [:]
    }

    private static let catalogCache = Mutex(CatalogCache())
    private static let recheckInterval: TimeInterval = 2

    /// In-memory catalog used by frequently rebuilt menus and pickers. File
    /// operations below invalidate it; external changes can call this method
    /// from a folder watcher.
    static func invalidateCatalog(_ kind: AssetKind? = nil) {
        catalogCache.withLock { cache in
            cache.revision &+= 1
            if let kind {
                cache.files[kind]?.checkedAt = 0
                if kind == .fonts { cache.fontFamilies = nil }
            } else {
                for kind in AssetKind.allCases { cache.files[kind]?.checkedAt = 0 }
                cache.fontFamilies = nil
            }
        }
        AssetCatalogChanges.publish()
    }

    static func libraryFontFamilies() -> [String] {
        let urls = allFiles(of: .fonts).map(\.url)
        let fingerprint = catalogCache.withLock { $0.files[.fonts]?.fingerprint ?? [] }
        if let cached = catalogCache.withLock({ cache in
            cache.fontFamilies.flatMap { $0.fingerprint == fingerprint ? $0.names : nil }
        }) { return cached }

        var families = Set<String>()
        for url in urls {
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                    as? [CTFontDescriptor] else { continue }
            for descriptor in descriptors {
                if let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String {
                    families.insert(name)
                }
            }
        }
        let result = families.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        catalogCache.withLock { cache in
            guard cache.files[.fonts]?.fingerprint == fingerprint else { return }
            cache.fontFamilies = FontFamilies(fingerprint: fingerprint, names: result)
        }
        return result
    }

    /// Keep the first CoreText descriptor scan off the main actor while
    /// retaining the synchronous cached accessor for non-UI callers.
    @concurrent
    static func libraryFontFamiliesAsync() async -> [String] {
        libraryFontFamilies()
    }

    static func ensureRoots() {
        for kind in AssetKind.allCases {
            try? FileManager.default.createDirectory(at: kind.rootURL, withIntermediateDirectories: true)
        }
    }

    /// Folders first, then matching files, both name-sorted. Hidden files are
    /// skipped; foreign file types are ignored rather than errors.
    static func items(of kind: AssetKind, in folder: URL) -> [AssetItem] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])) ?? []
        let entries = contents.compactMap { url -> AssetItem? in
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if !isFolder, !kind.allowedExtensions.contains(url.pathExtension.lowercased()) {
                return nil
            }
            return AssetItem(url: url, isFolder: isFolder)
        }
        return entries.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    @concurrent
    static func itemsAsync(of kind: AssetKind, in folder: URL) async -> [AssetItem] {
        items(of: kind, in: folder)
    }

    /// Recursive listing of a library's files with root-relative display
    /// names (extension dropped), name-sorted — the shape the Builder's
    /// Music/Image menus want.
    static func allFiles(of kind: AssetKind) -> [(name: String, url: URL)] {
        AssetCatalogChanges.observe()
        let root = kind.rootURL
        catalogCache.withLock { cache in
            if cache.roots[kind] != root {
                cache.roots[kind] = root
                cache.files[kind] = nil
                cache.revision &+= 1
                if kind == .fonts { cache.fontFamilies = nil }
            }
        }
        let now = Date.timeIntervalSinceReferenceDate
        if let cached = catalogCache.withLock({ cache -> [(name: String, url: URL)]? in
            guard let listing = cache.files[kind],
                  now - listing.checkedAt < recheckInterval else { return nil }
            return listing.files
        }) { return cached }
        // One-shot callers need a complete first listing, even on MainActor.
        // An existing listing (including an empty one) can refresh lazily.
        if Thread.isMainThread, catalogCache.withLock({ $0.files[kind] != nil }) {
            let state = catalogCache.withLock { cache in
                let launch = cache.refreshing.insert(kind).inserted
                return (launch, cache.revision, cache.files[kind]?.files ?? [])
            }
            if state.0 {
                Task { await refreshFiles(of: kind, root: root, revision: state.1) }
            }
            return state.2
        }
        return scanFiles(of: kind, root: root, revision: catalogCache.withLock { $0.revision })
    }

    @concurrent
    private static func refreshFiles(of kind: AssetKind, root: URL, revision: Int) async {
        _ = scanFiles(of: kind, root: root, revision: revision)
        catalogCache.withLock { $0.refreshing.remove(kind) }
        AssetCatalogChanges.publish()
    }

    private static func scanFiles(of kind: AssetKind, root: URL, revision: Int) -> [(name: String, url: URL)] {
        let now = Date.timeIntervalSinceReferenceDate
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        // The enumerator reports resolved paths (/private/var/…) even when
        // the root was given through a symlink (/var/…); compare resolved
        // forms so the library-relative name always strips the root.
        let rootPath = root.resolvingSymlinksInPath().path
        let result: [(name: String, url: URL)] = (enumerator?.compactMap { $0 as? URL } ?? [])
            .filter { kind.allowedExtensions.contains($0.pathExtension.lowercased()) }
            .map { url in
                var name = url.resolvingSymlinksInPath().deletingPathExtension().path
                if name.hasPrefix(rootPath + "/") {
                    name = String(name.dropFirst(rootPath.count + 1))
                }
                return (name, url)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let fingerprint = result.map { item in
            let modified = (try? item.url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate)?.timeIntervalSinceReferenceDate ?? 0
            return "\(item.url.path)|\(modified)"
        }
        catalogCache.withLock { cache in
            guard cache.revision == revision else { return }
            if kind == .fonts, cache.files[kind]?.fingerprint != fingerprint {
                cache.fontFamilies = nil
            }
            cache.files[kind] = FileListing(files: result, fingerprint: fingerprint, checkedAt: now)
        }
        return result
    }

    static func createFolder(named name: String, in folder: URL) throws {
        let target = folder.appendingPathComponent(ProfileStore.sanitize(name), isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        invalidateCatalog()
    }

    /// Copy external files into `folder`, skipping non-matching types.
    /// Returns how many files were actually imported.
    @discardableResult
    static func importFiles(_ urls: [URL], of kind: AssetKind, into folder: URL) async throws -> Int {
        try await importWorker.copy(urls, of: kind, into: folder)
    }

    // Blocking I/O on the cooperative pool is intentional for this single serial worker.
    private actor ImportWorker {
        func copy(_ urls: [URL], of kind: AssetKind, into folder: URL) throws -> Int {
            try AssetStore.copyFiles(urls, of: kind, into: folder)
        }
    }
    private static let importWorker = ImportWorker()

    private static func copyFiles(_ urls: [URL], of kind: AssetKind, into folder: URL) throws -> Int {
        var imported = 0
        defer {
            if imported > 0 {
                invalidateCatalog(kind)
                if kind == .fonts { registerFonts() }
            }
        }
        for url in urls {
            try Task.checkCancellation()
            guard kind.allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            // File-importer URLs are security-scoped; direct drags are not.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            // Stage under a hidden name; cancellation/errors never leave a
            // partially copied file visible in a catalog or folder watcher.
            let staging = folder.appendingPathComponent(".import-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.copyItem(at: url, to: staging)
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: staging,
                to: uniqueDestination(for: url.lastPathComponent, in: folder))
            imported += 1
        }
        return imported
    }

    static func rename(_ item: AssetItem, to newName: String) throws {
        var name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        // Keep the original extension so a display-name edit can't break the
        // file's type.
        if !item.isFolder, !item.url.pathExtension.isEmpty,
           (name as NSString).pathExtension.lowercased() != item.url.pathExtension.lowercased() {
            name += "." + item.url.pathExtension
        }
        let target = item.url.deletingLastPathComponent().appendingPathComponent(name)
        guard target != item.url else { return }
        try FileManager.default.moveItem(at: item.url, to: target)
        invalidateCatalog()
    }

    static func trash(_ item: AssetItem) throws {
        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        invalidateCatalog()
    }

    private static func uniqueDestination(for filename: String, in folder: URL) -> URL {
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = folder.appendingPathComponent(filename)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = folder.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }

    /// Register every font in the fonts library for this process so caption
    /// and overlay rendering can resolve them by name. Re-registering already
    /// registered fonts is a harmless no-op error that CTFontManager reports
    /// per-font; errors are ignored.
    static func registerFonts() {
        if Thread.isMainThread {
            Task { await registerFontsAsync() }
            return
        }
        let fontURLs = allFiles(of: .fonts).map(\.url)
        guard !fontURLs.isEmpty else { return }
        CTFontManagerRegisterFontURLs(fontURLs as CFArray, .process, true, nil)
    }

    @concurrent
    private static func registerFontsAsync() async {
        registerFonts()
        AssetCatalogChanges.publish()
    }
}
