import Foundation

nonisolated enum AssetSyncInventory {
    struct Remote: Sendable {
        var entries: [String: AssetSyncEntry] = [:]
        var reports: [String] = []
    }

    /// Keep the entire enumerator walk synchronous; hashing is deferred until comparison.
    static func local(roots: AssetSyncRoots) throws -> [String: AssetSyncEntry] {
        var result: [String: AssetSyncEntry] = [:]
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .contentModificationDateKey,
        ]
        for kind in AssetSyncKind.allCases {
            let root = roots[kind].resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard try root.resourceValues(forKeys: keys).isDirectory == true else {
                throw GoogleDriveError.conflict
            }
            result[kind.folderName] = AssetSyncEntry(isFolder: true)
            var walkError: Error?
            guard
                let walk = FileManager.default.enumerator(
                    at: root, includingPropertiesForKeys: Array(keys),
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, error in
                        walkError = error
                        return false
                    })
            else { throw GoogleDriveError.invalidResponse }
            for case let url as URL in walk {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true {
                    walk.skipDescendants()
                    continue
                }
                // The enumerator may hand back resolved (/private/var) or unresolved
                // (/var) paths regardless of the root it was given; compare like with like.
                let resolved = url.resolvingSymlinksInPath().path
                guard resolved.hasPrefix(root.path + "/") else { continue }
                let relative = String(resolved.dropFirst(root.path.count + 1))
                let path = kind.folderName + "/" + relative
                let folder = values.isDirectory == true
                guard AssetSyncKind.accepts(path, isFolder: folder) else {
                    if folder { walk.skipDescendants() }
                    continue
                }
                guard folder || values.isRegularFile == true else { continue }
                result[path] = AssetSyncEntry(
                    size: Int64(values.fileSize ?? 0),
                    modifiedDate: values.contentModificationDate ?? .distantPast, isFolder: folder)
            }
            if let walkError { throw walkError }
        }
        return result
    }

    static func hashingMatches(
        local: [String: AssetSyncEntry], remote: [String: AssetSyncEntry],
        roots: AssetSyncRoots, journal: inout AssetSyncJournal
    ) throws -> [String: AssetSyncEntry] {
        var result = local
        for path in local.keys.sorted() {
            guard var entry = local[path], !entry.isFolder, remote[path]?.md5 != nil else { continue }
            entry.md5 = try journal.checksum(path: path, entry: entry, url: roots.url(for: path))
            result[path] = entry
        }
        return result
    }

    static func remote(client: GoogleDriveClient, homeID: String) async throws -> Remote {
        var result = Remote()
        var queue: [(id: String, path: String)] = [(homeID, "")]
        var visited: Set<String> = []
        while !queue.isEmpty {
            try Task.checkCancellation()
            let parent = queue.removeFirst()
            guard visited.insert(parent.id).inserted else { continue }
            var files: [DriveFile] = []
            var token: String?
            repeat {
                let page = try await client.list(folder: parent.id, videosOnly: false, pageToken: token)
                files += page.files
                token = page.nextPageToken
            } while token != nil
            // Choose across all pages, independent of response order. Never traverse losing folders.
            let groups = Dictionary(
                grouping: files.filter { file in
                    guard file.trashed != true, !file.name.contains("/"), !file.name.contains("\\") else {
                        return false
                    }
                    let path = parent.path.isEmpty ? file.name : parent.path + "/" + file.name
                    if parent.path.isEmpty { return file.isFolder && AssetSyncKind(rawValue: file.name) != nil }
                    return AssetSyncKind.accepts(path, isFolder: file.isFolder)
                        && (file.isFolder || !file.mimeType.hasPrefix("application/vnd.google-apps."))
                }, by: { $0.name })
            let winners = groups.keys.sorted().compactMap { name -> DriveFile? in
                let matches = groups[name]!.sorted {
                    let a = AssetSyncEntry($0).modifiedDate
                    let b = AssetSyncEntry($1).modifiedDate
                    return a == b ? $0.id < $1.id : a > b
                }
                if matches.count > 1 {
                    result.reports.append(
                        "\(parent.path.isEmpty ? name : parent.path + "/" + name): duplicate Drive names; using \(matches[0].id), most recently modified"
                    )
                }
                return matches.first
            }.sorted { $0.isFolder == $1.isFolder ? $0.name < $1.name : $0.isFolder }
            for file in winners {
                let path = parent.path.isEmpty ? file.name : parent.path + "/" + file.name
                result.entries[path] = AssetSyncEntry(file)
                if file.isFolder { queue.append((file.id, path)) }
            }
        }
        return result
    }
}
