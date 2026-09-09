import Foundation

/// Closed, anonymous feature vocabulary shared by published, draft and proxy files.
nonisolated struct ReelTraits: Codable, Sendable, Hashable {
  static let version = 1
  enum Aspect: Int, Codable, Sendable { case portrait, square, landscape }
  enum Crop: Int, Codable, Sendable { case full, letterboxed, pillarboxed }
  enum Language: Int, Codable, Sendable { case unknown, english, portuguese, spanish, other }
  enum Presence: Int, Codable, Sendable { case unknown, absent, present }
  var duration: Double = 0
  var cutCount: Int = 0
  var cutsPerMinute: Double = 0
  var cutIntervalVariance: Double = 0
  var blackFraction: Double = 0
  var frozenFraction: Double = 0
  var faceFirstSecond: Double = 0
  var faceFirstThreeSeconds: Double = 0
  var textFirstThreeSeconds: Double = 0
  var textArea: Double = 0
  var speechFraction: Double = 0
  var wordsPerMinute: Double = 0
  var fillerFraction: Double = 0
  var deadAirFraction: Double = 0
  var musicPresence: Presence = .unknown
  var loudnessDB: Double = -120
  var aspect: Aspect = .portrait
  var crop: Crop = .full
  var actionMix: Double = 0
  var crowdMix: Double = 0
  var landscapeMix: Double = 0
  var graphicMix: Double = 0
  var sharpnessMedian: Double = 0
  var luminanceMedian: Double = 0
  var captionLength: Int = 0
  var hashtagCount: Int = 0
  var questionWords: Int = 0
  var hookWords: Int = 0
  var language: Language = .unknown
  var transcriptAvailable: Int = 0

  var features: [String: Double] {
    // Codable is also the schema oracle: enums encode their small integer values.
    guard let data = try? JSONEncoder().encode(self),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: NSNumber]
    else { return [:] }
    return object.mapValues(\.doubleValue)
  }
}
