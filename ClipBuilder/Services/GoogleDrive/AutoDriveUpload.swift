import Foundation

/// The policy is independent of UI, database, and transfer scheduling.
nonisolated enum AutoDriveUpload {
    static let settingKey = "autoUploadNewSources"

    enum Reason: String, Sendable {
        case notAttached = "not attached"
        case settingOff = "setting off"
        case driveNotConnected = "Drive not connected"
        case nothingNew = "nothing new"
    }

    struct Decision: Sendable {
        var candidates: [VideoRecord] = []
        var reason: Reason?
    }

    static func isEnabled(setting: String?) -> Bool { setting != "false" }

    static func newVideos(before: [VideoRecord], after: [VideoRecord]) -> [VideoRecord] {
        let known = Set(before.map(\.id))
        return after.filter { !known.contains($0.id) }
    }

    /// Call off the main actor: checking files on a disconnected volume can take time.
    static func decide(
        videos: [VideoRecord], attached: Bool, driveConnected: Bool, enabled: Bool,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> Decision {
        guard attached else { return Decision(reason: .notAttached) }
        guard enabled else { return Decision(reason: .settingOff) }
        guard driveConnected else { return Decision(reason: .driveNotConnected) }
        let eligible = Set(GoogleDriveTransfers.uploadCandidates(videos.map(\.driveMedia)).map(\.recordID))
        let candidates = videos.filter {
            guard eligible.contains($0.id), let path = $0.path, !path.isEmpty else { return false }
            return fileExists(path)
        }
        return candidates.isEmpty ? Decision(reason: .nothingNew) : Decision(candidates: candidates)
    }
}
