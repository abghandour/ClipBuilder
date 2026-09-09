import Foundation

@MainActor
final class AssetSyncExecutor {
    let roots: AssetSyncRoots
    let client: GoogleDriveClient
    let transfers: GoogleDriveTransfers
    let profile: String
    let group: UUID
    var journal: AssetSyncJournal
    private let fontsArrived: () -> Void
    private var uploaded = 0
    private var downloaded = 0
    private var inSync = 0
    private var conflicts = 0
    private var errors = 0
    private var touched: Set<AssetSyncKind> = []
    private var fontsWereDownloaded = false
    var summary: String {
        "\(uploaded) uploaded, \(downloaded) downloaded, \(inSync) in sync, \(conflicts) conflict"
            + (errors == 0 ? "" : ", \(errors) errors")
    }

    init(
        roots: AssetSyncRoots, client: GoogleDriveClient, transfers: GoogleDriveTransfers,
        profile: String, group: UUID, journal: AssetSyncJournal, fontsArrived: (() -> Void)? = nil
    ) {
        self.roots = roots
        self.client = client
        self.transfers = transfers
        self.profile = profile
        self.group = group
        self.journal = journal
        self.fontsArrived = fontsArrived ?? { if roots.usesSharedCatalog { AssetStore.registerFonts() } }
    }

    func run(
        _ plan: AssetSyncPlan, remote: [String: AssetSyncEntry], database: Database,
        progress: (Int, Int) -> Void = { _, _ in }, log: (String) -> Void = { _ in }
    ) async throws {
        defer { finishArrivals() }
        var folders = remote.filter { $0.value.isFolder }.compactMapValues { $0.driveID }
        journal.kindFolderIDs = folders.filter { !$0.key.contains("/") }
        try await journal.save(database: database)
        for line in plan.reports { report(line, path: "Inventory", log: log) }
        for (index, action) in plan.actions.enumerated() {
            try Task.checkCancellation()
            progress(index, plan.actions.count)
            let path = action.path
            guard let component = path.split(separator: "/").first,
                let kind = AssetSyncKind(rawValue: String(component))
            else { throw GoogleDriveError.invalidResponse }
            do {
                switch action.operation {
                case .createLocalFolder:
                    let url = try roots.url(for: path, isFolder: true)
                    try AssetStore.createFolder(at: url, syncKind: kind.assetKind, invalidate: roots.usesSharedCatalog)
                    touched.insert(kind)
                    log("\(path): created local folder")
                case .createDriveFolder:
                    let parentPath = path.split(separator: "/").dropLast().joined(separator: "/")
                    let parent = parentPath.isEmpty ? journal.homeID : folders[parentPath]
                    guard let parent else { throw GoogleDriveError.conflict }
                    let folder = try await client.findOrCreateFolder(
                        name: String(path.split(separator: "/").last!), parent: parent)
                    folders[path] = folder.id
                    if parentPath.isEmpty { journal.kindFolderIDs[path] = folder.id }
                    log("\(path): created Drive folder")
                case .download, .replaceLocal:
                    guard let remote = action.remote, let id = remote.driveID else {
                        throw GoogleDriveError.invalidResponse
                    }
                    let destination = try roots.url(for: path)
                    // A staging directory belongs to exactly one action, including all its retries.
                    let staging = roots[kind].appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: staging) }
                    let staged = staging.appendingPathComponent(destination.lastPathComponent)
                    let file = try await transfers.assetTransfer(
                        profile: profile, group: group, path: path,
                        upload: false, size: remote.size
                    ) { [self] progress in
                        let file = try await client.download(id: id, to: staged, progress: progress)
                        try Task.checkCancellation()
                        _ = try roots.url(for: path)  // recheck symlinks after network I/O
                        try await Self.checkLocal(action.local, at: destination)
                        guard let date = AssetSyncEntry.date(file.modifiedTime) else {
                            throw GoogleDriveError.invalidResponse
                        }
                        try AssetStore.installSyncedFile(
                            staged, at: destination, modifiedDate: date,
                            replacing: action.operation == .replaceLocal, syncKind: kind.assetKind,
                            invalidate: roots.usesSharedCatalog)
                        arrived(kind)
                        return file
                    }
                    let entry = AssetSyncEntry(file)
                    let md5: String
                    if let checksum = file.md5Checksum {
                        md5 = checksum
                    } else {
                        md5 = try await Self.hash(destination)
                    }
                    journal.md5Cache[path] = .init(
                        size: entry.size, modifiedDate: entry.modifiedDate,
                        md5: md5, driveID: file.id)
                    downloaded += 1
                    log(
                        "\(path): \(action.operation == .replaceLocal ? "newer Drive copy replaced local" : "downloaded")"
                    )
                case .upload, .replaceInDrive:
                    let source = try roots.url(for: path)
                    let parentPath = path.split(separator: "/").dropLast().joined(separator: "/")
                    guard let folder = folders[parentPath], let local = action.local else {
                        throw GoogleDriveError.conflict
                    }
                    // Same per-profile checkpoint directory as media uploads, with a separate asset key.
                    let checkpoint = database.path.deletingLastPathComponent().appendingPathComponent("drive-transfers")
                        .appendingPathComponent(
                            "asset-\(ContentHashForDrive.key(journal.homeID + "|" + source.path)).json")
                    defer { try? FileManager.default.removeItem(at: checkpoint) }
                    let file = try await transfers.assetTransfer(
                        profile: profile, group: group, path: path,
                        upload: true, size: local.size
                    ) { [self] progress in
                        _ = try roots.url(for: path)
                        try await Self.checkLocal(local, at: source)
                        return try await client.upload(
                            file: source, folder: folder, checkpoint: checkpoint,
                            replacingID: action.operation == .replaceInDrive ? action.remote?.driveID : nil,
                            verifyChecksum: true, progress: progress)
                    }
                    guard let md5 = file.md5Checksum else { throw GoogleDriveError.invalidResponse }
                    journal.md5Cache[path] = .init(
                        size: local.size, modifiedDate: local.modifiedDate,
                        md5: md5, driveID: file.id)
                    uploaded += 1
                    log(
                        "\(path): \(action.operation == .replaceInDrive ? "newer local copy replaced Drive" : "uploaded")"
                    )
                case .skip:
                    inSync += 1
                    log("\(path): in sync")
                case .conflict:
                    conflicts += 1
                    report(
                        "\(path): conflict — equal modification times or file/folder collision; left both copies",
                        path: path, log: log)
                }
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                if error as? GoogleDriveError == .cannotReplaceAsset {
                    conflicts += 1
                    report("\(path): cannot replace (not created by Clip Builder)", path: path, log: log)
                } else {
                    errors += 1
                    report("\(path): \(GoogleDriveError.message(for: error))", path: path, log: log)
                }
            }
            // Keep transfer receipts durable without rewriting the entire hash cache for every skip.
            switch action.operation {
            case .createDriveFolder, .download, .replaceLocal, .upload, .replaceInDrive:
                try await journal.save(database: database)
            default: break
            }
            progress(index + 1, plan.actions.count)
        }
    }

    private func report(_ line: String, path: String, log: (String) -> Void) {
        transfers.assetReport(profile: profile, group: group, path: path, message: line)
        log(line)
    }

    private func arrived(_ kind: AssetSyncKind) {
        touched.insert(kind)
        if kind == .fonts { fontsWereDownloaded = true }
    }

    private func finishArrivals() {
        if fontsWereDownloaded { fontsArrived() }
        guard roots.usesSharedCatalog else { return }
        for kind in touched {
            if let assetKind = kind.assetKind { AssetStore.invalidateCatalog(assetKind) }
            if kind == .overlays { OverlayTemplateStore.invalidateCache() }
            if kind == .screenCrops { ScreenCropStore.invalidateListing() }
        }
    }

    /// Off the main actor: the MD5 comparison reads the whole file.
    @concurrent nonisolated private static func checkLocal(_ expected: AssetSyncEntry?, at url: URL) async throws {
        guard let expected else {
            if FileManager.default.fileExists(atPath: url.path) { throw GoogleDriveError.conflict }
            return
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
        guard values.isRegularFile == true, Int64(values.fileSize ?? 0) == expected.size,
            values.contentModificationDate == expected.modifiedDate
        else { throw GoogleDriveError.conflict }
        if let md5 = expected.md5, try ContentHashForDrive.md5(url) != md5 { throw GoogleDriveError.conflict }
    }

    @concurrent nonisolated private static func hash(_ url: URL) async throws -> String {
        try ContentHashForDrive.md5(url)
    }
}
