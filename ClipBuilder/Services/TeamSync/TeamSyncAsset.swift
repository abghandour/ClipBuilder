import Foundation

nonisolated enum TeamSyncAsset {
    /// Match symlink-resolved paths against known library roots, even for missing files.
    /// Unknown locations retain their full-path entropy without exporting paths.
    static func identity(path: String, kind: String, knownRoots: [URL] = []) -> String {
        let filePath = normalizedPath(URL(fileURLWithPath: path))
        var roots = knownRoots
        if let assetKind = AssetKind(rawValue: kind) { roots.append(assetKind.rootURL) }
        for root in roots {
            let rootPath = normalizedPath(root)
            let prefix = rootPath == "/" ? "/" : rootPath + "/"
            if filePath.hasPrefix(prefix) {
                return SyncMapping.stableID([kind, String(filePath.dropFirst(prefix.count))])
            }
        }
        return SyncMapping.stableID([kind, filePath])
    }

    private static func normalizedPath(_ url: URL) -> String {
        var ancestor = url
        var remaining: [String] = []
        while ancestor.path != "/", !FileManager.default.fileExists(atPath: ancestor.path) {
            remaining.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
        var resolved = ancestor.resolvingSymlinksInPath()
        for component in remaining.reversed() {
            resolved.appendPathComponent(component)
        }
        // Foundation can strip /private for existing paths but retain it for
        // missing descendants. Apply the same spelling to files and roots.
        let path = resolved.standardizedFileURL.path
        return path.hasPrefix("/private/") ? String(path.dropFirst("/private".count)) : path
    }
}
