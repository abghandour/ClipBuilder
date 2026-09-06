import Foundation

/// Serializes destructive disk changes and transfer registration per profile.
actor DriveMediaStore {
    let database: Database
    let client: GoogleDriveClient
    let inputFolder: URL
    private let checksumOf: @Sendable (URL) throws -> String
    private var importing: [String: Task<URL, Error>] = [:]
    private var fetching: [String: Task<URL, Error>] = [:]

    init(
        database: Database, client: GoogleDriveClient, inputFolder: URL,
        checksumOf: @escaping @Sendable (URL) throws -> String = ContentHashForDrive.md5
    ) {
        self.database = database
        self.client = client
        self.inputFolder = inputFolder
        self.checksumOf = checksumOf
    }

    func download(
        _ file: DriveFile, projectID: Int64?,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> URL {
        if let existing = try await database.driveSource(fileID: file.id) {
            let url = try await ensure(existing.driveMedia, progress: progress)
            if let projectID { try await database.assignVideos([existing.id], to: projectID) }
            return url
        }
        if let task = importing[file.id] {
            let url = try await task.value
            if let projectID, let video = try await database.driveSource(fileID: file.id) {
                try await database.assignVideos([video.id], to: projectID)
            }
            return url
        }
        let task = Task { try await self.downloadNew(file, progress: progress) }
        importing[file.id] = task
        defer { importing[file.id] = nil }
        let url = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        if let projectID, let video = try await database.driveSource(fileID: file.id) {
            try await database.assignVideos([video.id], to: projectID)
        }
        return url
    }

    private func downloadNew(_ file: DriveFile, progress: @escaping @Sendable (Double) async -> Void) async throws
        -> URL
    {
        // Drive names are untrusted and need not be unique. A private per-id
        // subdirectory prevents traversal and collisions with imported footage.
        let safeID = ContentHashForDrive.key(file.id)
        let name = URL(fileURLWithPath: file.name).lastPathComponent
        guard name != ".", name != "..", name != "/", !name.isEmpty, !file.isFolder else {
            throw GoogleDriveError.invalidResponse
        }
        let destination = inputFolder.appendingPathComponent("Google Drive/\(safeID)", isDirectory: true)
            .appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: destination.path) {
            _ = try await client.download(id: file.id, to: destination, progress: progress)
        }
        let hash = try ContentHash.fingerprint(of: destination)
        // Match the folder scanner's content-based registration. Preserve an
        // existing local copy (and its scenes) instead of moving its DB path.
        let known = try await database.fetchVideos().first { $0.hash == hash }
        let recordID: Int64
        let registeredURL: URL
        if let known, FileManager.default.fileExists(atPath: known.path) {
            recordID = known.id
            registeredURL = known.url
            if known.path != destination.path { try? FileManager.default.removeItem(at: destination) }
        } else {
            let info = await FFmpeg.info(of: destination)
            recordID = try await database.registerVideo(
                hash: hash, filename: name, path: destination.path,
                duration: info.duration, width: info.width, height: info.height, wide: info.width > info.height)
            registeredURL = destination
        }
        let media = DriveMedia(kind: .source, recordID: recordID, path: registeredURL.path)
        try await database.setDriveCopy(media, file: file)
        return registeredURL
    }

    func ensure(
        _ media: DriveMedia,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> URL {
        let url = URL(fileURLWithPath: media.path)
        if FileManager.default.fileExists(atPath: media.path) {
            if media.offloaded { try await database.setDriveOffloaded(media, false) }
            return url
        }
        guard let id = media.fileID else { throw GoogleDriveError.notFound }
        if let task = fetching[media.path] { return try await task.value }
        let task = Task {
            let files = DriveTransferFiles(for: url)
            try files.prepare()
            let staging = files.restoring
            if !FileManager.default.fileExists(atPath: staging.path) {
                _ = try await client.download(id: id, to: staging, transferFiles: files, progress: progress)
            }
            let identity = files.readIdentity()
            if let identity, try ContentHashForDrive.md5(staging) != identity.md5 {
                try? FileManager.default.removeItem(at: staging)
                throw GoogleDriveError.conflict
            }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: staging, to: url)
            try await database.setDriveOffloaded(media, false)
            return url
        }
        fetching[media.path] = task
        defer { fetching[media.path] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func offload(_ media: DriveMedia) async throws {
        try await DriveMediaResolver.shared.beginOffload(media.path)
        defer { Task { await DriveMediaResolver.shared.endOffload(media.path) } }
        guard let id = media.fileID, fetching[media.path] == nil else { throw GoogleDriveError.conflict }
        // Never delete the last accessible copy merely because an old id exists.
        let remote = try await client.metadata(id: id)
        guard remote.size != nil else { throw GoogleDriveError.invalidResponse }
        let url = URL(fileURLWithPath: media.path)
        if FileManager.default.fileExists(atPath: url.path) {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard Int64(size) == remote.byteCount else { throw GoogleDriveError.conflict }
            let checksum = try checksumOf(url)
            if let expected = remote.md5Checksum, checksum != expected {
                throw GoogleDriveError.conflict
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: media.path)
            let cacheIdentity = DriveCacheIdentity(
                size: Double(size),
                mtime: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1,
                md5: checksum)
            let files = DriveTransferFiles(for: url)
            try files.prepare()
            try JSONEncoder().encode(cacheIdentity).write(to: files.identity, options: .atomic)
            // Flag first: if removal fails, roll it back. Keep the stable path,
            // every scene, transcript, cached thumbnail and timeline unchanged.
            try await database.setDriveOffloaded(media, true)
            do { try FileManager.default.removeItem(at: url) } catch {
                try? await database.setDriveOffloaded(media, false)
                throw error
            }
        } else {
            try await database.setDriveOffloaded(media, true)
        }
    }

    func byteCount(_ media: DriveMedia) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: media.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }

    func upload(
        _ media: DriveMedia, folder: String,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> DriveFile {
        let url = try await ensure(media, progress: progress)
        let checkpoint = database.path.deletingLastPathComponent().appendingPathComponent("drive-transfers")
            .appendingPathComponent(ContentHashForDrive.key(database.path.path + media.id) + ".json")
        let file = try await client.upload(file: url, folder: folder, checkpoint: checkpoint, progress: progress)
        try await database.setDriveCopy(media, file: file)
        try? FileManager.default.removeItem(at: checkpoint)
        return file
    }
}
