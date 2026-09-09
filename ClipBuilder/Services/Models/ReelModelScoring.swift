import Foundation

nonisolated enum ReelModelScoring {
  static func criticLines(
    config: AIConfig, store: ReelModelStore, traits: ReelTraits?,
    frames: [Data], trainer: any ReelModelTrainer = CreateMLReelModelTrainer(),
    printer: any TasteFeaturePrinter = VisionTasteFeaturePrinter()
  ) throws -> [String] {
    var lines: [String] = []
    if let predictor = try? store.predictor(item: .outcome, config: config, trainer: trainer),
      let traits
    {
      let report = store.report(.outcome)
      let origin = report?.origin ?? "Local outcome model"
      lines.append(
        "[\(origin) v\(report?.version ?? 1)] "
          + ReelOutcomeModel.predictedLine(try predictor.predict(traits.features)))
    }
    if let predictor = try? store.predictor(item: .taste, config: config, trainer: trainer),
      !frames.isEmpty
    {
      let scores = try frames.compactMap {
        try TasteSimilarity.score(image: $0, predictor: predictor, printer: printer)
      }
      if !scores.isEmpty {
        lines.append(
          "Looks like ours: \((ReelTraitExtractor.average(scores) * 100).formatted(.number.precision(.fractionLength(0))))%"
        )
      }
    }
    return lines
  }

  /// Candidate scoring consumes the proxy FILE through the same extractor as final and imported reels.
  static func candidate(
    proxy: URL, id: String, caption: String?, transcript: [TranscriptSegment]?,
    config: AIConfig, database: Database, store: ReelModelStore
  ) async throws -> [String: Double]? {
    guard
      let predictor = try? store.predictor(
        item: .outcome, config: config, trainer: CreateMLReelModelTrainer())
    else { return nil }
    let traits = try await ReelTraitExtractor.traits(
      for: proxy, caption: caption, transcript: transcript)
    try await database.saveReelTraits(traits, kind: "candidate", videoID: id)
    return try predictor.predict(traits.features)
  }
}
