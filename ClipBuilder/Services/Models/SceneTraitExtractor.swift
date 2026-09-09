import Foundation

nonisolated enum SceneTraitExtractor {
  static func cacheKey(_ scene: SceneRecord) -> String {
    "\(scene.id):\(scene.startTime):\(scene.endTime)"
  }
  @concurrent
  static func traits(
    for scene: SceneRecord, database: Database,
    cachedDetectors: VideoDetectors? = nil,
    inspector: any ReelFrameInspector = VisionReelFrameInspector()
  ) async throws -> ReelTraits {
    let key = cacheKey(scene)
    if let cached = try await database.reelTraits(kind: "scene", videoID: key) { return cached }
    let detectors: VideoDetectors
    if let cachedDetectors {
      detectors = cachedDetectors
    } else {
      let attributes = try scene.videoURL.resourceValues(forKeys: [
        .fileSizeKey, .contentModificationDateKey,
      ])
      let fingerprint =
        "1:\(attributes.fileSize ?? 0):\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)"
      if let cached = try await database.cachedDetectors(
        videoID: scene.videoID, fingerprint: fingerprint)
      {
        detectors = cached
      } else {
        detectors = try await FFmpeg.detectors(of: scene.videoURL, duration: scene.videoDuration)
        try await database.cacheDetectors(
          detectors, videoID: scene.videoID, fingerprint: fingerprint)
      }
    }
    let times = Array(
      Set(([0.25, 0.75, 1.5, 2.5] + [scene.duration / 2]).filter { $0 < scene.duration })
    ).sorted()
    var frames: [ReelTraitExtractor.Frame] = []
    for time in times {
      if let image = await ThumbnailService.jpegFrame(
        url: scene.videoURL, at: scene.startTime + time),
        let quality = inspector.quality(image)
      {
        frames.append(.init(time: time, signals: try inspector.inspect(image), quality: quality))
      }
    }
    guard !frames.isEmpty else { throw ReelModelError.unavailable("No readable scene frames.") }
    func ranges(_ values: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
      values.compactMap { range in
        let start = max(scene.startTime, range.lowerBound)
        let end = min(scene.endTime, range.upperBound)
        return start < end ? (start - scene.startTime)...(end - scene.startTime) : nil
      }
    }
    let source = try await database.fetchTranscripts(videoID: scene.videoID).filter {
      !$0.isTranslation
    }
    let segments = source.filter { $0.endTime > scene.startTime && $0.startTime < scene.endTime }
      .map {
        TranscriptSegment(
          start: max(0, $0.startTime - scene.startTime),
          end: min(scene.duration, $0.endTime - scene.startTime), text: $0.text)
      }
    let value = ReelTraitExtractor.assemble(
      duration: scene.duration, width: scene.videoWidth, height: scene.videoHeight,
      detectors: VideoDetectors(
        black: ranges(detectors.black), frozen: ranges(detectors.frozen),
        cuts: detectors.cuts.filter { $0 > scene.startTime && $0 < scene.endTime }.map {
          $0 - scene.startTime
        }),
      frames: frames, caption: nil, transcript: source.isEmpty ? nil : segments,
      hasAudio: await FFmpeg.hasAudioStream(scene.videoURL))
    try await database.saveReelTraits(value, kind: "scene", videoID: key)
    return value
  }
}
