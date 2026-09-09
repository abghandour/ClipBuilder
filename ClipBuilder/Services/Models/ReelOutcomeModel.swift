import Foundation

nonisolated enum ReelOutcomeModel {
  static let minimumRows = 40
  static func rows(_ outcomes: [ReelOutcome]) -> [ReelModelRow] {
    outcomes.filter(\.isLabeled).map {
      ReelModelRow(
        id: $0.videoID, date: $0.postedAt, features: $0.traits.features,
        targets: $0.lift.filter { ReelOutcome.targets.contains($0.key) })
    }.sorted { ($0.date, $0.id) < ($1.date, $1.id) }
  }
  static func requireEnough(_ rows: [ReelModelRow]) throws {
    guard rows.count >= minimumRows else {
      throw ReelModelError.needsRows(minimumRows - rows.count)
    }
  }
  static func predictedLine(_ prediction: [String: Double]) -> String {
    "Predicted lift: "
      + ReelOutcome.targets.compactMap { key in
        prediction[key].map { "\(key) \($0.formatted(.number.precision(.fractionLength(2))))×" }
      }.joined(separator: " · ")
  }
}
