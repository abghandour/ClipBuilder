import Foundation

/// Editable scene cutaway, always on the source recording's transcript clock.
nonisolated struct BRollCut: Codable, Sendable, Hashable, Identifiable {
    enum Origin: String, Codable, Sendable, Hashable { case auto, ai, user }

    var id = UUID()
    var start: Double
    var end: Double
    var sceneID: Int64
    /// Seconds into the B-roll scene, not into its recording.
    var sceneOffset: Double
    var reason: String
    var origin: Origin
}
