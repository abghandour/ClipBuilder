import Foundation

/// Local-only joined row. Captions/identities are deliberately absent from the feature vector.
nonisolated struct ReelOutcome: Codable, Sendable {
  var videoID: String
  var accountID: Int64
  var postedAt: Date
  var postingMonth: String
  var weekday: Int
  var hour: Int
  var topicTags: [String]
  var traits: ReelTraits
  var raw: [String: Double]
  var lift: [String: Double]
  var reference: Bool = false

  static let targets = ["saves", "shares", "comments", "watchFraction"]
  var isLabeled: Bool { !reference && Self.targets.allSatisfy { lift[$0]?.isFinite == true } }

  static func joined(
    media: IGReportMediaRow, traits: ReelTraits, account: IGAccountRecord,
    insights: [IGAccountInsightRow]
  ) -> ReelOutcome? {
    guard account.isOwn, let posted = media.postedAt else { return nil }
    let month = String(ReportDates.iso(posted).prefix(7))
    var raw: [String: Double] = [:]
    raw["saves"] = media.metrics["saved"] ?? media.metrics["saves"]
    raw["shares"] = media.metrics["shares"]
    raw["comments"] = media.metrics["comments"]
    raw["reach"] = media.metrics["reach"]
    raw["views"] = media.metrics["views"]
    if let watch = media.metrics["ig_reels_avg_watch_time"], traits.duration > 0 {
      // The Graph metric is milliseconds; no magnitude-dependent unit guessing.
      raw["watchFraction"] = watch / 1000 / traits.duration
    }
    raw = raw.filter { $0.value.isFinite && $0.value >= 0 }
    guard !raw.isEmpty else { return nil }
    var lift: [String: Double] = [:]
    for target in Self.targets {
      let metric = "reel_" + (target == "watchFraction" ? "watch_fraction" : target) + "_median"
      let values = insights.filter {
        $0.metric == metric && $0.period == "month" && $0.dimension.isEmpty
          && $0.breakdown.isEmpty && String($0.endTime.prefix(7)) == month
      }.map(\.value)
      let median = ReelTraitExtractor.median(values)
      if let outcome = raw[target], outcome.isFinite, outcome >= 0, median > 0 {
        lift[target] = outcome / median
      }
    }
    let calendar = ReportDates.calendar
    return ReelOutcome(
      videoID: String(media.id), accountID: account.id, postedAt: posted,
      postingMonth: month, weekday: (calendar.component(.weekday, from: posted) + 5) % 7 + 1,
      hour: calendar.component(.hour, from: posted),
      topicTags: media.caption.split(whereSeparator: \.isWhitespace).filter { $0.hasPrefix("#") }
        .map(String.init),
      traits: traits, raw: raw, lift: lift)
  }
}
