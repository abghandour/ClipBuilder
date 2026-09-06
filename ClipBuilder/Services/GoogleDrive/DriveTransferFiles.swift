import Foundation

/// Checkpoints stay on the media's volume for atomic installation, but never
/// alongside the visible footage. The original media path also keys restores.
nonisolated struct DriveTransferFiles: Sendable {
    let mediaURL: URL
    let directory: URL

    init(for mediaURL: URL) {
        self.mediaURL = mediaURL.standardizedFileURL
        directory = mediaURL.standardizedFileURL.deletingLastPathComponent()
            .appendingPathComponent(".drive", isDirectory: true)
            .appendingPathComponent(ContentHashForDrive.key(mediaURL.standardizedFileURL.path), isDirectory: true)
    }

    var identity: URL { directory.appendingPathComponent("drive-cache-identity.json") }
    var partial: URL { directory.appendingPathComponent("drive-partial") }
    var checkpoint: URL { directory.appendingPathComponent("drive-download.json") }
    var restoring: URL { directory.appendingPathComponent("drive-restoring") }

    func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Prefer an interrupted restore over an older initial-download checkpoint.
        // Move its checkpoint and partial bytes as a pair, without combining them.
        let oldRestore = mediaURL.appendingPathExtension("drive-restoring")
        try migrate([(mediaURL.appendingPathExtension("drive-cache-identity.json"), identity)])
        try migrate([(oldRestore, restoring)])
        try migrate([
            (oldRestore.appendingPathExtension("drive-partial"), partial),
            (oldRestore.appendingPathExtension("drive-download.json"), checkpoint),
        ])
        try migrate([
            (mediaURL.appendingPathExtension("drive-partial"), partial),
            (mediaURL.appendingPathExtension("drive-download.json"), checkpoint),
        ])
    }

    private func migrate(_ group: [(URL, URL)]) throws {
        let occupied = group.contains { FileManager.default.fileExists(atPath: $0.1.path) }
        let archivePrefix = "legacy-\(UUID().uuidString)-"
        for (source, target) in group where FileManager.default.fileExists(atPath: source.path) {
            // Preserve competing checkpoints together without mixing their bytes.
            let destination =
                occupied ? directory.appendingPathComponent(archivePrefix + target.lastPathComponent) : target
            try FileManager.default.moveItem(at: source, to: destination)
        }
    }

    func readIdentity() -> DriveCacheIdentity? {
        if FileManager.default.fileExists(atPath: mediaURL.appendingPathExtension("drive-cache-identity.json").path) {
            try? prepare()
        }
        return (try? Data(contentsOf: identity)).flatMap {
            try? JSONDecoder().decode(DriveCacheIdentity.self, from: $0)
        }
    }
}
