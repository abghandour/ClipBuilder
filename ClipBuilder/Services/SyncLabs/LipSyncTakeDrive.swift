import Foundation

/// Lip sync takes shared through the team's Drive folder, like dub takes:
/// "Lip sync takes/<key>.mp4" with its "<key>.json" sidecar. The key already
/// names the recording's content, the range, the model and the dubbed lines,
/// so a teammate with the same recording and the same shared dub takes asks
/// for the same key and downloads instead of paying. The folder itself is
/// the index: no database row and no server column.
actor LipSyncTakeDrive {
    static let shared = LipSyncTakeDrive()
    static let folderName = "Lip sync takes"

    private struct Context: Sendable {
        var client: GoogleDriveClient
        var profile: String
        var teamFolderID: String?
        var transfers: GoogleDriveTransfers
    }
    private var contexts: [URL: Context] = [:]
    /// One lookup per team folder, shared by everything that asks while it runs:
    /// two callers must never both find no folder and each create one.
    private var folders: [String: Task<String, Error>] = [:]
    private var uploads: [String: Task<Void, Never>] = [:]
    private var tail: Task<Void, Never>?

    func register(database: Database, client: GoogleDriveClient, teamFolderID: String?, transfers: GoogleDriveTransfers) async {
        let path = await database.path
        let profile = await client.profile
        contexts[path] = Context(client: client, profile: profile, teamFolderID: teamFolderID, transfers: transfers)
    }

    /// The team's folder and what is in it by name; nil without a connected team folder.
    private func remote(_ context: Context) async throws -> (folder: String, files: [String: DriveFile])? {
        guard let team = context.teamFolderID, !team.isEmpty,
              case .connected = await context.client.auth.state(profile: context.profile) else { return nil }
        let folderKey = context.profile + "/" + team
        let lookup: Task<String, Error>
        if let existing = folders[folderKey] { lookup = existing }
        else {
            lookup = Task { try await context.client.findOrCreateFolder(name: Self.folderName, parent: team).id }
            folders[folderKey] = lookup
        }
        let folder: String
        do { folder = try await lookup.value } catch {
            folders[folderKey] = nil
            throw error
        }
        var files: [String: DriveFile] = [:]
        var token: String?
        repeat {
            let page = try await context.client.list(folder: folder, videosOnly: false, pageToken: token)
            for file in page.files where files[file.name] == nil { files[file.name] = file }
            token = page.nextPageToken
            try Task.checkCancellation()
        } while token != nil
        return (folder, files)
    }

    /// Downloads the takes a teammate already made. Returns the keys now on
    /// disk. Only cancellation throws: a Drive failure means paying as before.
    func fetch(_ keys: [String], into directory: URL, database: Database,
               log: @escaping @Sendable (String) -> Void) async throws -> Set<String> {
        let path = await database.path
        guard !keys.isEmpty, let context = contexts[path] else { return [] }
        var fetched: Set<String> = []
        do {
            guard let remote = try await remote(context) else { return [] }
            let group = UUID()
            for key in keys {
                guard let video = remote.files[key + ".mp4"], let sidecar = remote.files[key + ".json"] else { continue }
                try Task.checkCancellation()
                let staging = directory.appendingPathComponent("download-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                let picture = staging.appendingPathComponent(key + ".mp4"), record = staging.appendingPathComponent(key + ".json")
                do {
                    _ = try await context.transfers.assetTransfer(profile: context.profile, group: group,
                        path: Self.folderName + "/" + video.name, upload: false, size: Int64(video.size ?? "") ?? 0) { progress in
                        try await context.client.download(id: video.id, to: picture, progress: progress)
                    }
                    _ = try await context.client.download(id: sidecar.id, to: record)
                    // Drive checks the bytes, not that this is the take it is named after.
                    guard LipSyncTakes.all(in: staging).contains(where: { $0.key == key }) else {
                        log("Lip sync: a shared take was unreadable and is made here instead")
                        continue
                    }
                    // The video lands first: a sidecar without its video is not a take.
                    try? FileManager.default.removeItem(at: LipSyncTakes.video(key, in: directory))
                    try FileManager.default.moveItem(at: picture, to: LipSyncTakes.video(key, in: directory))
                    try? FileManager.default.removeItem(at: LipSyncTakes.sidecar(key, in: directory))
                    try FileManager.default.moveItem(at: record, to: LipSyncTakes.sidecar(key, in: directory))
                    fetched.insert(key)
                } catch {
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    log("Lip sync: a shared take could not be downloaded (\(error.localizedDescription))")
                }
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            ErrorLog.record("Lip sync", "Could not read shared takes: \(error.localizedDescription)")
        }
        return fetched
    }

    /// Uploads a take the team folder does not have yet, in the background, one at a time.
    func enqueue(_ key: String, directory: URL, database: Database) async {
        let path = await database.path
        guard let context = contexts[path], let team = context.teamFolderID, !team.isEmpty else { return }
        let id = path.path + "/" + key
        guard uploads[id] == nil else { return }
        let previous = tail
        let task = Task {
            await previous?.value
            defer { uploads[id] = nil }
            do {
                guard let remote = try await remote(context) else { return }
                let video = LipSyncTakes.video(key, in: directory)
                guard var take = LipSyncTakes.all(in: directory).first(where: { $0.key == key }) else { return }
                let staging = directory.appendingPathComponent("upload-" + UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: staging) }
                if remote.files[key + ".mp4"] == nil {
                    let copy = staging.appendingPathComponent(key + ".mp4")
                    try FileManager.default.copyItem(at: video, to: copy)
                    let size = (try FileManager.default.attributesOfItem(atPath: copy.path)[.size] as? NSNumber)?.int64Value ?? 0
                    _ = try await context.transfers.assetTransfer(profile: context.profile, group: UUID(),
                        path: Self.folderName + "/" + key + ".mp4", upload: true, size: size) { progress in
                        try await context.client.upload(file: copy, folder: remote.folder,
                            checkpoint: staging.appendingPathComponent("upload.json"), verifyChecksum: true, progress: progress)
                    }
                }
                // The sidecar goes last: teammates only take a pair.
                if remote.files[key + ".json"] == nil {
                    // Neither the folder nor the recording's name leaves this Mac:
                    // the key already says which recording, and a teammate's copy lives elsewhere.
                    take.sourcePath = ""
                    try LipSyncTakes.write(take, in: staging)
                    _ = try await context.client.upload(file: LipSyncTakes.sidecar(key, in: staging), folder: remote.folder,
                        checkpoint: staging.appendingPathComponent("sidecar.json.checkpoint"))
                }
            } catch {
                if !(error is CancellationError) {
                    ErrorLog.record("Lip sync", "Could not share take: \(error.localizedDescription)")
                }
            }
        }
        uploads[id] = task
        tail = task
    }
}

/// How the service reaches the team's shared takes; nil where nothing is shared (tests).
nonisolated struct LipSyncTakeSharing: Sendable {
    var fetch: @Sendable ([String], URL, @escaping @Sendable (String) -> Void) async throws -> Set<String>
    var publish: @Sendable (String, URL) async -> Void

    static func drive(_ database: Database) -> LipSyncTakeSharing {
        .init(fetch: { keys, directory, log in
            try await LipSyncTakeDrive.shared.fetch(keys, into: directory, database: database, log: log)
        }, publish: { key, directory in
            await LipSyncTakeDrive.shared.enqueue(key, directory: directory, database: database)
        })
    }
}
