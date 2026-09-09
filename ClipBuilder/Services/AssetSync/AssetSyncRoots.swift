import Foundation

/// Explicit roots never read or invalidate the process-wide asset catalog.
nonisolated struct AssetSyncRoots: Sendable {
    private let directories: [AssetSyncKind: URL]
    let usesSharedCatalog: Bool

    init(base: URL) {
        directories = Dictionary(
            uniqueKeysWithValues: AssetSyncKind.allCases.map {
                ($0, base.appendingPathComponent($0.folderName, isDirectory: true))
            })
        usesSharedCatalog = false
    }

    init() {
        directories = Dictionary(
            uniqueKeysWithValues: AssetSyncKind.allCases.map { kind in
                let root =
                    kind.assetKind?.rootURL
                    ?? (kind == .overlays ? OverlayTemplateStore.directory : ScreenCropStore.directory)
                return (kind, root)
            })
        usesSharedCatalog = true
    }

    subscript(_ kind: AssetSyncKind) -> URL { directories[kind]! }

    func url(for path: String, isFolder: Bool = false) throws -> URL {
        guard AssetSyncKind.accepts(path, isFolder: isFolder),
            let first = path.split(separator: "/").first, let kind = AssetSyncKind(rawValue: String(first))
        else { throw GoogleDriveError.invalidResponse }
        let root = self[kind].standardizedFileURL.resolvingSymlinksInPath()
        let result = path.split(separator: "/").dropFirst().reduce(root) {
            $0.appendingPathComponent(String($1))
        }
        // Refuse symlink traversal, including a final symlink to another asset.
        var component = self[kind].standardizedFileURL
        for name in path.split(separator: "/").dropFirst() {
            component.appendPathComponent(String(name))
            if (try? component.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw GoogleDriveError.conflict
            }
        }
        return result
    }
}
