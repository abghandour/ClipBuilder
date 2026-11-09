import Foundation

/// Profile-scoped audio transfers. The durable take row is the upload queue:
/// missing Drive IDs are retried when that take is used again. Transfers appear
/// in the existing Drive queue with Stop, and never hold up dub preparation.
actor DubTakeDrive {
    static let shared = DubTakeDrive()

    private struct Context: Sendable {
        var client: GoogleDriveClient
        var profile: String
        var teamFolderID: String?
        var transfers: GoogleDriveTransfers
    }
    private var contexts: [URL: Context] = [:]
    private var uploads: [String: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?
    private var folders: [String: String] = [:]

    func register(database: Database, client: GoogleDriveClient, teamFolderID: String?, transfers: GoogleDriveTransfers) async {
        let path = await database.path
        let profile = await client.profile
        contexts[path] = Context(client: client, profile: profile, teamFolderID: teamFolderID, transfers: transfers)
    }

    func download(id: String, to destination: URL, database: Database) async throws {
        let path = await database.path
        guard let context = contexts[path] else { throw GoogleDriveError.notFound }
        _ = try await context.client.download(id: id, to: destination)
    }

    func enqueue(_ take: DubTake, database: Database) async {
        let path = await database.path
        guard take.driveFileID == nil, let context = contexts[path],
              let teamFolderID = context.teamFolderID, !teamFolderID.isEmpty else { return }
        let key = path.path + "/" + DubTake.digest([take.id, take.text])
        guard uploads[key] == nil else { return }
        let previous = tail
        let task = Task {
            await previous?.value
            defer { uploads[key] = nil }
            do {
                guard case .connected = await context.client.auth.state(profile: context.profile) else { return }
                let current = try await database.fetchDubTakes(videoID: take.source.videoID).first { $0.id == take.id }
                guard let current, current.text == take.text, current.alignment == take.alignment,
                      current.driveFileID == nil else { return }
                let directory = await database.dubTakesDirectory
                let source = directory.appendingPathComponent(take.audioFile)
                guard DubTakeStore.hasAudio(source) else { return }
                // Snapshot the bytes before any network await. Another review can
                // replace this same natural-key take while its upload is running.
                let staging = directory.appendingPathComponent("upload-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                let audio = staging.appendingPathComponent(take.audioFile)
                try FileManager.default.copyItem(at: source, to: audio)
                let size = (try FileManager.default.attributesOfItem(atPath: audio.path)[.size] as? NSNumber)?.int64Value ?? 0
                let group = UUID()
                let folderKey = context.profile + "/" + teamFolderID
                let folder: String
                if let existing = folders[folderKey] { folder = existing }
                else {
                    folder = try await context.client.findOrCreateFolder(name: "Dub takes", parent: teamFolderID).id
                    folders[folderKey] = folder
                }
                let file = try await context.transfers.assetTransfer(profile: context.profile,
                    group: group, path: "Dub takes/" + take.audioFile, upload: true, size: size) { progress in
                    try await context.client.upload(file: audio, folder: folder,
                        checkpoint: staging.appendingPathComponent("upload.json"), verifyChecksum: true, progress: progress)
                }
                try await database.setDubTakeDriveFile(file.id, for: take)
            } catch {
                if !(error is CancellationError) {
                    ErrorLog.record("Dub", "Could not share take: \(error.localizedDescription)")
                }
            }
        }
        uploads[key] = task
        tail = task
    }
}
