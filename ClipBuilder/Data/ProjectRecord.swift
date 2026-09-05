import Foundation

nonisolated struct ProjectRecord: Identifiable, Sendable, Hashable {
    var id: Int64
    var profileName: String
    var name: String
    var createdAt: String?
    var lastOpenedAt: String?
    var archived: Bool
    var isHome: Bool
    var thumbnailVideoID: Int64?
    var uiStateJSON: String?
    var sourceCount: Int
    var timelineCount: Int
    var outputCount: Int
    var thumbnailPaths: [String]

    var lastOpenedDate: Date? { Database.parseSQLiteDate(lastOpenedAt) }
}
