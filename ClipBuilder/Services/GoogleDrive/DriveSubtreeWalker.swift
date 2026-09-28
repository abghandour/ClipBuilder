import Foundation

/// One file found below the browser's current folder, with the folder chain
/// that leads to it (excluding the current folder itself).
nonisolated struct DriveFlatFile: Identifiable, Hashable, Sendable {
    var file: DriveFile
    var folderIDs: [String]
    var folderNames: [String]
    var id: String { file.id }
    /// The first folder below the current one, or nil for a direct child.
    var topFolderID: String? { folderIDs.first }
    var pathLabel: String { folderNames.joined(separator: " / ") }
}

/// The one Drive call the walker needs, so tests can fake it and the
/// browser can cache it.
nonisolated protocol DriveFolderLister: Sendable {
    func children(of folderID: String, videosOnly: Bool, driveID: String?, pageToken: String?) async throws
        -> DrivePage
}

extension GoogleDriveClient: DriveFolderLister {
    func children(of folderID: String, videosOnly: Bool, driveID: String?, pageToken: String?) async throws
        -> DrivePage
    {
        try await list(folder: folderID, videosOnly: videosOnly, driveID: driveID, pageToken: pageToken)
    }
}

/// Remembers every page a folder returned so toggling filters or the flat
/// view does not hit Drive again. One per browser session.
actor CachingDriveFolderLister: DriveFolderLister {
    private let base: any DriveFolderLister
    private var pages: [String: DrivePage] = [:]
    init(base: any DriveFolderLister) { self.base = base }

    func children(of folderID: String, videosOnly: Bool, driveID: String?, pageToken: String?) async throws
        -> DrivePage
    {
        let key = "\(folderID)|\(videosOnly)|\(driveID ?? "")|\(pageToken ?? "")"
        if let page = pages[key] { return page }
        let page = try await base.children(of: folderID, videosOnly: videosOnly, driveID: driveID, pageToken: pageToken)
        pages[key] = page
        return page
    }
}

/// Breadth-first listing of everything below a set of seed entries. Drive
/// has no recursive query, so this is one request per folder page, capped so
/// a huge shared tree cannot run away.
nonisolated struct DriveSubtreeWalker: Sendable {
    var maxRequests = 400
    var maxDepth = 8

    struct Progress: Equatable, Sendable {
        var foldersScanned = 0
        var filesFound = 0
        var requests = 0
    }

    struct Result: Equatable, Sendable {
        var files: [DriveFlatFile]
        var foldersScanned: Int
        /// True when the request cap stopped the walk before every folder was read.
        var truncated: Bool
    }

    func walk(
        seed: [DriveFile], lister: any DriveFolderLister, videosOnly: Bool, driveID: String?,
        progress: @Sendable (Progress) -> Void = { _ in }
    ) async throws -> Result {
        // Seeds can overlap (the Recent listing returns a folder and its
        // descendants side by side), so folders are walked once and files
        // emitted once, at the first place they were seen.
        var files: [DriveFlatFile] = []
        var seenFiles = Set<String>()
        var queuedFolders = Set<String>()
        var queue: [(folder: DriveFile, ids: [String], names: [String])] = []
        func enqueue(_ folder: DriveFile, ids: [String], names: [String]) {
            guard queuedFolders.insert(folder.id).inserted else { return }
            queue.append((folder, ids, names))
        }
        func emit(_ file: DriveFile, ids: [String], names: [String]) {
            guard seenFiles.insert(file.id).inserted else { return }
            files.append(DriveFlatFile(file: file, folderIDs: ids, folderNames: names))
        }
        for entry in seed {
            if entry.isFolder {
                enqueue(entry, ids: [entry.id], names: [entry.name])
            } else {
                emit(entry, ids: [], names: [])
            }
        }
        var state = Progress(filesFound: files.count)
        var truncated = false
        var index = 0
        scan: while index < queue.count {
            let (folder, ids, names) = queue[index]
            index += 1
            var token: String?
            repeat {
                guard state.requests < maxRequests else {
                    truncated = true
                    break scan
                }
                try Task.checkCancellation()
                let page = try await lister.children(
                    of: folder.id, videosOnly: videosOnly, driveID: driveID, pageToken: token)
                state.requests += 1
                for entry in page.files {
                    if entry.isFolder {
                        if ids.count < maxDepth { enqueue(entry, ids: ids + [entry.id], names: names + [entry.name]) }
                        else { truncated = true }
                    } else {
                        emit(entry, ids: ids, names: names)
                    }
                }
                state.filesFound = files.count
                token = page.nextPageToken
                progress(state)
            } while token != nil
            state.foldersScanned += 1
            progress(state)
        }
        return Result(files: files, foldersScanned: state.foldersScanned, truncated: truncated)
    }

    /// How many videos below each direct child folder pass the filter. Folders
    /// absent from the result have none.
    static func matchesByTopFolder(_ files: [DriveFlatFile], filter: DriveBrowserFilter) -> [String: Int] {
        let kept = Set(filter.apply(to: files.map(\.file)).files.map(\.id))
        var counts: [String: Int] = [:]
        for entry in files where kept.contains(entry.id) && entry.file.isVideo {
            if let top = entry.topFolderID { counts[top, default: 0] += 1 }
        }
        return counts
    }
}
