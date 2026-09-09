import Foundation

nonisolated enum ReelTraitRecording {
  /// Project the audible source transcript onto output time, for both proxy and final files.
  static func transcript(document: TimelineDocument, scenes: [SceneRecord], database: Database)
    async throws -> [TranscriptSegment]?
  {
    var result: [TranscriptSegment] = []
    var hasTranscript = false
    let audible = document.videoTrack.filter { $0.track == 0 && !$0.bumper && !$0.muted }
    if audible.isEmpty { return [] }
    for clip in audible {
      guard let scene = scenes.first(where: { $0.videoPath == clip.videoFile }) else { continue }
      let source = try await database.fetchTranscripts(videoID: scene.videoID).filter {
        !$0.isTranslation
      }
      if !source.isEmpty { hasTranscript = true }
      // An untrimmed scene clip carries no source bounds; the scene's own range applies.
      let sourceStart = clip.sourceStart ?? scene.startTime
      let sourceEnd = clip.sourceEnd ?? scene.endTime
      let scale = clip.duration / max(0.001, sourceEnd - sourceStart)
      for row in source where row.endTime > sourceStart && row.startTime < sourceEnd {
        result.append(
          TranscriptSegment(
            start: clip.startTime + (max(row.startTime, sourceStart) - sourceStart) * scale,
            end: clip.startTime + (min(row.endTime, sourceEnd) - sourceStart) * scale,
            text: row.text))
      }
    }
    return hasTranscript ? result : nil
  }

  static func record(
    url: URL, id: Int64, database: Database, document: TimelineDocument,
    scenes: [SceneRecord], caption: String? = nil,
    log: @escaping @Sendable (String) -> Void
  ) async {
    do {
      let transcript = try await transcript(document: document, scenes: scenes, database: database)
      let traits = try await ReelTraitExtractor.traits(
        for: url, caption: caption, transcript: transcript)
      try await database.saveReelTraits(traits, kind: "generated", videoID: String(id))
    } catch { log("Reel traits unavailable: \(error.localizedDescription)") }
  }
}
