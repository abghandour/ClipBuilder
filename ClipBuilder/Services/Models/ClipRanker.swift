import Foundation

nonisolated enum ClipRanker {
  static let inventoryLimit = 120
  static func features(_ scene: SceneRecord, traits: ReelTraits? = nil) -> [String: Double] {
    var values = (traits ?? ReelTraits()).features
    let context: [String: Double] = [
      "duration": scene.duration, "position": scene.startTime / max(1, scene.videoDuration),
      "score": scene.score ?? 0, "excitement": scene.excitement ?? 0,
      "personPresence": scene.tags.contains { $0.hasPrefix("person:") } ? 1 : 0,
      "tagCount": Double(scene.tags.count), "bRoll": scene.isBRoll ? 1 : 0,
      "action": scene.tags.contains { $0.hasPrefix("action:") } ? 1 : 0,
      "highlight": scene.tags.contains { $0.hasPrefix("highlight:") } ? 1 : 0,
      "aspect": Double(scene.videoWidth) / Double(max(1, scene.videoHeight)),
    ]
    values.merge(context, uniquingKeysWith: { _, context in context })
    return values
  }
  static func ranked(
    _ scenes: [SceneRecord], predictor: (any ReelModelPredictor)?,
    limit: Int = inventoryLimit, traits: [Int64: ReelTraits] = [:]
  ) throws -> [SceneRecord] {
    guard let predictor else { return scenes }
    let scored = try scenes.enumerated().map { entry in
      (
        entry.offset, entry.element,
        try predictor.predict(features(entry.element, traits: traits[entry.element.id]))["keep"]
          ?? 0
      )
    }
    return scored.sorted { $0.2 == $1.2 ? $0.0 < $1.0 : $0.2 > $1.2 }.prefix(max(0, limit)).map {
      $0.1
    }
  }
}
