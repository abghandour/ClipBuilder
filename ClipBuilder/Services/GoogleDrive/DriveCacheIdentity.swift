import Foundation

/// Keeps the existing thumbnail cache key and expected content after off-load.
nonisolated struct DriveCacheIdentity: Codable, Sendable {
    var size: Double
    var mtime: Double
    var md5: String
}
