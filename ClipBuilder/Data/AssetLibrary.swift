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
    case bumpers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .music: return "Music"
        case .fonts: return "Fonts"
        case .bumpers: return "Bumpers"
        case .images: return "Images"
        }
    }

    var systemImage: String {
        switch self {
        case .music: return "music.note"
        case .fonts: return "textformat"
        case .bumpers: return "film.stack"
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
        case .bumpers: return ["mp4", "mov", "m4v"]
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
        case .bumpers: return "Add short videos for intros, outros, or mid-roll ads and calls to action. Bumpers always take the full screen."
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

    @concurrent
    static func foldersAsync(of kind: AssetKind) async -> Set<URL> {
        folders(of: kind)
    }

    /// Synchronous walk: `FileManager`'s enumerator cannot be iterated from
    /// an async context.
    static func folders(of kind: AssetKind) -> Set<URL> {
        let root = kind.rootURL
        var folders: Set<URL> = [root]
        guard let entries = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return folders }
        for case let url as URL in entries {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { folders.insert(url) }
        }
        return folders
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
        catalogCache.withLock { _ = $0.refreshing.remove(kind) }
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

    /// Root-relative path of a folder inside a library ("" for the root,
    /// "Fights/Intros" for a nested folder). Compares resolved paths so a
    /// /var vs /private/var root still strips.
    static func relativeFolderName(_ folder: URL, of kind: AssetKind) -> String {
        let rootPath = kind.rootURL.resolvingSymlinksInPath().path
        let path = folder.resolvingSymlinksInPath().path
        guard path.hasPrefix(rootPath + "/") else { return "" }
        return String(path.dropFirst(rootPath.count + 1))
    }

    /// Root-relative names of every folder in a library (root excluded),
    /// sorted; includes empty folders, so it is what a "Move to…" menu wants.
    @concurrent
    static func folderNamesAsync(of kind: AssetKind) async -> [String] {
        let root = kind.rootURL
        return await foldersAsync(of: kind)
            .subtracting([root])
            .map { relativeFolderName($0, of: kind) }
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Folders that contain at least one matching file (plus their
    /// ancestors), derived from the cached catalog so menus rebuilt on the
    /// main actor stay cheap. Empty folders are omitted: they hold nothing a
    /// picker could choose.
    static func populatedFolderNames(of kind: AssetKind) -> [String] {
        var names = Set<String>()
        for file in allFiles(of: kind) {
            var components = file.name.split(separator: "/").dropLast()
            while !components.isEmpty {
                names.insert(components.joined(separator: "/"))
                components = components.dropLast()
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Files whose root-relative name sits under `folder` (case-insensitive;
    /// nil or "" = the whole library). Subfolders of `folder` are included.
    static func allFiles(of kind: AssetKind, inFolder folder: String?) -> [(name: String, url: URL)] {
        let files = allFiles(of: kind)
        guard let folder = folder?.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
              !folder.isEmpty else { return files }
        let prefix = folder.lowercased() + "/"
        return files.filter { $0.name.lowercased().hasPrefix(prefix) }
    }

    /// The library folder matching `name` case-insensitively, as the catalog
    /// spells it; nil when no populated folder matches.
    static func resolveFolderName(_ name: String, of kind: AssetKind) -> String? {
        let wanted = name.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased()
        guard !wanted.isEmpty else { return nil }
        let folders = populatedFolderNames(of: kind)
        if let exact = folders.first(where: { $0.lowercased() == wanted }) { return exact }
        // "folder A" for a nested "Season 2/folder A": match on the last component.
        let matches = folders.filter { $0.split(separator: "/").last?.lowercased() == wanted }
        return matches.count == 1 ? matches[0] : nil
    }

    nonisolated enum MoveError: LocalizedError {
        case intoItself

        var errorDescription: String? {
            switch self {
            case .intoItself: return "A folder can't be moved into itself."
            }
        }
    }

    /// Move a file or folder into another folder of the same library,
    /// renaming on collision. Moving into the folder it is already in is a
    /// no-op; moving a folder into itself or a descendant is refused.
    @discardableResult
    static func move(_ item: AssetItem, into folder: URL) throws -> URL {
        let sourceFolder = item.url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let targetFolder = folder.resolvingSymlinksInPath().path
        guard sourceFolder != targetFolder else { return item.url }
        if item.isFolder {
            let itemPath = item.url.resolvingSymlinksInPath().path
            if targetFolder == itemPath || targetFolder.hasPrefix(itemPath + "/") {
                throw MoveError.intoItself
            }
        }
        let destination = uniqueDestination(for: item.name, in: folder)
        try FileManager.default.moveItem(at: item.url, to: destination)
        invalidateCatalog()
        return destination
    }

    static func createFolder(named name: String, in folder: URL) throws {
        let target = folder.appendingPathComponent(ProfileStore.sanitize(name), isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        invalidateCatalog()
    }

    /// Sync preserves exact names and can target isolated roots without disturbing the shared catalog.
    static func createFolder(at url: URL, syncKind: AssetKind?, invalidate: Bool) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if invalidate { invalidateCatalog(syncKind) }
    }

    /// The staging file is on the destination volume. Replace atomically, never remove the old file first.
    static func installSyncedFile(
        _ staging: URL, at destination: URL, modifiedDate: Date,
        replacing: Bool, syncKind: AssetKind?, invalidate: Bool
    ) throws {
        try Task.checkCancellation()
        try FileManager.default.setAttributes([.modificationDate: modifiedDate], ofItemAtPath: staging.path)
        if replacing {
            _ = try FileManager.default.replaceItemAt(
                destination, withItemAt: staging,
                options: .usingNewMetadataOnly)
        } else {
            guard !FileManager.default.fileExists(atPath: destination.path) else { throw GoogleDriveError.conflict }
            try FileManager.default.moveItem(at: staging, to: destination)
        }
        if invalidate { invalidateCatalog(syncKind) }
        try FileManager.default.setAttributes([.modificationDate: modifiedDate], ofItemAtPath: destination.path)
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

    @discardableResult
    static func rename(_ item: AssetItem, to newName: String) throws -> URL {
        var name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return item.url }
        // Keep the original extension so a display-name edit can't break the
        // file's type.
        if !item.isFolder, !item.url.pathExtension.isEmpty,
           (name as NSString).pathExtension.lowercased() != item.url.pathExtension.lowercased() {
            name += "." + item.url.pathExtension
        }
        let target = item.url.deletingLastPathComponent().appendingPathComponent(name)
        guard target != item.url else { return item.url }
        try FileManager.default.moveItem(at: item.url, to: target)
        invalidateCatalog()
        return target
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
