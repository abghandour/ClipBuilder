import Foundation
import CoreText
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

    /// Recursive listing of a library's files with root-relative display
    /// names (extension dropped), name-sorted — the shape the Builder's
    /// Music/Image menus want.
    static func allFiles(of kind: AssetKind) -> [(name: String, url: URL)] {
        let root = kind.rootURL
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { kind.allowedExtensions.contains($0.pathExtension.lowercased()) }
            .map { url in
                var name = url.deletingPathExtension().path
                if name.hasPrefix(root.path + "/") {
                    name = String(name.dropFirst(root.path.count + 1))
                }
                return (name, url)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func createFolder(named name: String, in folder: URL) throws {
        let target = folder.appendingPathComponent(ProfileStore.sanitize(name), isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    }

    /// Copy external files into `folder`, skipping non-matching types.
    /// Returns how many files were actually imported.
    @discardableResult
    static func importFiles(_ urls: [URL], of kind: AssetKind, into folder: URL) throws -> Int {
        var imported = 0
        for url in urls {
            guard kind.allowedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            // File-importer URLs are security-scoped; direct drags are not.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try FileManager.default.copyItem(at: url, to: uniqueDestination(for: url.lastPathComponent, in: folder))
            imported += 1
        }
        if kind == .fonts, imported > 0 { registerFonts() }
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
    }

    static func trash(_ item: AssetItem) throws {
        try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
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
        guard let enumerator = FileManager.default.enumerator(
            at: AssetKind.fonts.rootURL, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return }
        let fontURLs = enumerator.compactMap { $0 as? URL }
            .filter { AssetKind.fonts.allowedExtensions.contains($0.pathExtension.lowercased()) }
        guard !fontURLs.isEmpty else { return }
        CTFontManagerRegisterFontURLs(fontURLs as CFArray, .process, true, nil)
    }
}
