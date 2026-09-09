import Foundation

nonisolated enum ReelTraitCache {
  static func traits(
    kind: String, videoID: String, database: Database, reference: Bool = false,
    version: Int = ReelTraits.version,
    compute: @Sendable () async throws -> ReelTraits
  ) async throws -> ReelTraits {
    if let cached = try await database.reelTraits(kind: kind, videoID: videoID, version: version) {
      return cached
    }
    let value = try await compute()
    try Task.checkCancellation()
    try await database.saveReelTraits(
      value, kind: kind, videoID: videoID, reference: reference, version: version)
    return value
  }
}
