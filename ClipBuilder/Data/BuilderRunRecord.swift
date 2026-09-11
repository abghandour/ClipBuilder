import Foundation

nonisolated enum BuilderRunStatus: String, Codable, Sendable {
    case completed, applied, failed, discarded, reverted
}

nonisolated struct BuilderRunRecord: Sendable, Equatable {
    var runUUID: String
    var timelineID: Int64
    var request: String
    var createdAt: String = Date.now.ISO8601Format()
    var provider: String = "local"
    var model: String?
    var durationSeconds: Double?
    var status: BuilderRunStatus
    var baselineRevision: Int
    var appliedRevision: Int?
    var summary: String?
    var libraryEffectsJSON: String = "[]"
    var eventsJSON: String = "[]"
}
