import Foundation

@MainActor
extension AssetSyncExecutor {
    /// A separate learned operation leaves the asset planner and its conflict rules unchanged.
    func publishLearned(_ build: LearnedDocumentBuilder.Build, database: Database,
                        library: LearnedLibrary) async throws {
        let document = try LearnedRedaction.apply(build.document, publishing: true)
        let learned = try await client.findOrCreateFolder(name: "learned", parent: journal.homeID)
        let ownFolder = try await client.findOrCreateFolder(name: document.contributor, parent: learned.id)
        let framesFolder = try await client.findOrCreateFolder(name: "frames", parent: ownFolder.id)
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(".import-learned-\(UUID())")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        // Ownership receipts are scoped by home AND contributor. A same-name
        // file without our receipt is never adopted for overwrite.
        let receiptKey = "learnedReceipts." + LearnedPreferences.stableID(journal.homeID + "|" + document.contributor)
        let stored = try await database.driveSetting(receiptKey) ?? "{}"
        var receipts = (try? JSONDecoder().decode([String: String].self, from: Data(stored.utf8))) ?? [:]
        let peers = try await learnedFiles(in: learned.id)
        let remoteFrames = try await learnedFiles(in: framesFolder.id)
        let documentName = document.contributor + ".json"
        if let id = receipts[documentName] {
            if let existing = peers.first(where: { $0.id == id }) {
                guard existing.name == documentName, !existing.isFolder else { throw GoogleDriveError.conflict }
            } else { receipts[documentName] = nil }
        }
        if peers.contains(where: { $0.name == documentName && $0.id != receipts[documentName] }) {
            throw GoogleDriveError.conflict
        }
        var uploads: [(name: String, data: Data, folder: String, path: String)] = []
        for name in document.frameNames {
            guard let data = build.frames[name] else { throw LearnedRedaction.Failure.invalidDocument }
            let filename = URL(fileURLWithPath: name).lastPathComponent
            if let id = receipts[name] {
                if let existing = remoteFrames.first(where: { $0.id == id }) {
                    guard existing.name == filename, !existing.isFolder else { throw GoogleDriveError.conflict }
                } else { receipts[name] = nil }
            }
            if remoteFrames.contains(where: { $0.name == filename && $0.id != receipts[name] }) {
                throw GoogleDriveError.conflict
            }
            uploads.append((filename, data, framesFolder.id, name))
        }
        // Publish the manifest last so readers never see references before frames.
        uploads.append((documentName, try JSONEncoder().encode(document), learned.id, documentName))
        for upload in uploads {
            try Task.checkCancellation()
            let source = staging.appendingPathComponent(upload.name)
            try upload.data.write(to: source)
            let checkpoint = database.path.deletingLastPathComponent().appendingPathComponent("drive-transfers")
                .appendingPathComponent("learned-\(LearnedPreferences.stableID(receiptKey + upload.path)).json")
            let replacingID = receipts[upload.path]
            let file = try await transfers.assetTransfer(profile: profile, group: group, path: "learned/" + upload.path,
                upload: true, size: Int64(upload.data.count)) { [self] progress in
                try await client.upload(file: source, folder: upload.folder, checkpoint: checkpoint,
                    replacingID: replacingID, verifyChecksum: true, progress: progress)
            }
            receipts[upload.path] = file.id
            try await database.setDriveSetting(receiptKey, value: String(decoding: JSONEncoder().encode(receipts), as: UTF8.self))
            try? FileManager.default.removeItem(at: checkpoint)
        }
        try library.install(document, frames: build.frames)
        var downloadedNames: Set<String> = []
        for peer in peers where !peer.isFolder && peer.name.hasSuffix(".json") && peer.name != documentName {
            guard downloadedNames.insert(peer.name).inserted else { continue }
            try Task.checkCancellation()
            let data = try await learnedDownload(peer, staging: staging)
            let other = try library.decode(data)
            guard peer.name == other.contributor + ".json", other.contributor != document.contributor else {
                throw LearnedRedaction.Failure.invalidDocument
            }
            var frames: [String: Data] = [:]
            if !other.frameNames.isEmpty {
                guard let folder = peers.first(where: { $0.isFolder && $0.name == other.contributor }),
                      let frameFolder = try await learnedFiles(in: folder.id).first(where: { $0.isFolder && $0.name == "frames" }) else {
                    throw GoogleDriveError.notFound
                }
                let files = try await learnedFiles(in: frameFolder.id)
                for name in other.frameNames {
                    guard let file = files.first(where: { !$0.isFolder && $0.name == URL(fileURLWithPath: name).lastPathComponent }) else {
                        throw GoogleDriveError.notFound
                    }
                    frames[name] = try await learnedDownload(file, staging: staging)
                }
            }
            try library.install(other, frames: frames)
        }
        LearnedCache.invalidate(profile: profile)
    }

    func learnedFiles(in folder: String) async throws -> [DriveFile] {
        var result: [DriveFile] = []
        var token: String?
        repeat {
            let page = try await client.list(folder: folder, videosOnly: false, pageToken: token)
            result += page.files.filter { $0.trashed != true }
            token = page.nextPageToken
        } while token != nil
        return result.sorted {
            let a = AssetSyncEntry($0).modifiedDate, b = AssetSyncEntry($1).modifiedDate
            return a == b ? $0.id < $1.id : a > b
        }
    }

    func learnedDownload(_ file: DriveFile, staging: URL) async throws -> Data {
        guard (Int64(file.size ?? "") ?? Int64.max) <= 20_000_000 else { throw LearnedRedaction.Failure.invalidDocument }
        let target = staging.appendingPathComponent(UUID().uuidString)
        _ = try await transfers.assetTransfer(profile: profile, group: group, path: "learned/" + file.name,
            upload: false, size: Int64(file.size ?? "") ?? 0) { [self] progress in
            try await client.download(id: file.id, to: target, progress: progress)
        }
        return try Data(contentsOf: target)
    }
}

@MainActor enum LearnedSync {
    static func run(executor: AssetSyncExecutor, profile: BrandProfile, database: Database,
                    library: LearnedLibrary = LearnedLibrary(), benchmarks: AccountBenchmarks? = nil,
                    log: (String) -> Void = { _ in }, config: AIConfig? = nil,
                    distill: () async throws -> Void) async throws {
        guard !profile.learnedSharing.deviceNickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AIError.notConfigured("Open What Clip Builder has learned and enter a device nickname before publishing.")
        }
        // Distillation needs a model; when it is unavailable the lessons already
        // on file still publish, and the fingerprint stays unrecorded so the
        // next Refresh tries again.
        do {
            try await distillPending(database: database, distill: distill)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            log("Learned preferences: lesson distillation skipped — \(GoogleDriveError.message(for: error))")
        }
        let build = try await LearnedDocumentBuilder.build(profile: profile, database: database, benchmarks: benchmarks)
        var destination = library
        destination.profile = profile.profileName
        try await executor.publishLearned(build, database: database, library: destination)
        if let config {
            try await executor.syncLearnedModels(contributor: build.document.contributor, database: database,
                library: destination, config: config)
        }
    }

    @discardableResult
    static func distillPending(database: Database, distill: () async throws -> Void) async throws -> Bool {
        guard let fingerprint = try await database.learnedFeedbackFingerprint(),
              fingerprint != (try await database.driveSetting("learnedDistilledFeedback")) else { return false }
        try await distill()
        try await database.setDriveSetting("learnedDistilledFeedback", value: fingerprint)
        return true
    }

}
