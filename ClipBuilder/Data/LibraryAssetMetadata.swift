import Foundation

nonisolated struct LibraryAssetMetadata: Identifiable, Codable, Sendable, Hashable {
    var path: String
    var kind: String
    var isBRoll: Bool
    var subjects: [String]
    var tags: [String]
    var provider: String?
    var model: String?
    var displayName: String? = nil
    var placements: [String]? = nil

    var id: String { path }
}
