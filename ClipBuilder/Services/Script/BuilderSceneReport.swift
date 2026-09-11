import Foundation

/// The only answer accepted from a find agent. Validation belongs to the
/// session as well as the tool schema, so prose cannot manufacture results.
nonisolated struct BuilderSceneReport: Codable, Sendable, Equatable {
    struct Scene: Codable, Sendable, Equatable {
        let id: Int64
        let reason: String
    }
    let scenes: [Scene]
    let summary: String
}
