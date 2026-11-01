import Foundation

/// Picks the few reels and sibling pairs where the on-device models, the AI
/// critic and existing human judgments disagree most, so a judgment there
/// teaches the models more than grading every reel. Pure: the store gathers
/// the signals, this ranks them. See docs/Teaching-Queue-Plan.md.
nonisolated enum TeachingQueue {
  /// Every opinion the app already holds about one generated reel.
  struct Signals: Sendable, Hashable {
    var reelID: Int64
    var batchID: String?
    /// Mean predicted lift from the outcome model; nil when it is not eligible
    /// or the reel has no traits yet.
    var outcome: Double? = nil
    /// Mean keep probability of the reel's plan scenes from the clip ranker.
    var ranker: Double? = nil
    /// Taste similarity. Nil in v1: it needs decoded frames per reel.
    var taste: Double? = nil
    var criticScore: Int? = nil
    var criticForecast: Int? = nil
    /// The reel's overall review verdict: 1 liked, -1 disliked, 0 or nil unset.
    var humanVerdict: Int? = nil
    /// The reel appears in any wizard_preferences row.
    var hasPreference = false

    var isJudged: Bool { (humanVerdict ?? 0) != 0 }
  }

  enum Source: String, Codable, CaseIterable, Sendable, Hashable {
    case outcome, ranker, taste, critic

    var label: String {
      switch self {
      case .outcome: "Outcome model"
      case .ranker: "Clip ranker"
      case .taste: "Taste"
      case .critic: "AI critic"
      }
    }
  }

  enum Kind: Sendable, Hashable {
    case reel(Int64)
    /// Lower id first.
    case pair(Int64, Int64)

    var reelIDs: [Int64] {
      switch self {
      case .reel(let id): [id]
      case .pair(let a, let b): [a, b]
      }
    }
  }

  struct Item: Identifiable, Sendable, Hashable {
    var kind: Kind
    /// 0...1: the max percentile gap (reel) or mean opposing rank gap (pair).
    var disagreement: Double
    var disagreeing: [Source]
    var informs: [ReelModelItem]
    var summary: String

    var id: String {
      switch kind {
      case .reel(let id): "reel-\(id)"
      case .pair(let a, let b): "pair-\(a)-\(b)"
      }
    }

    /// True once the human answer this item asked for exists.
    func isAnswered(by signals: [Int64: Signals]) -> Bool {
      switch kind {
      case .reel(let id): signals[id]?.isJudged ?? false
      case .pair(let a, let b): (signals[a]?.hasPreference ?? false) || (signals[b]?.hasPreference ?? false)
      }
    }
  }

  /// A source's raw value for one reel. The critic speaks through its
  /// audience forecast when it gave one, else its overall score.
  static func value(_ source: Source, _ signals: Signals) -> Double? {
    switch source {
    case .outcome: signals.outcome
    case .ranker: signals.ranker
    case .taste: signals.taste
    case .critic: (signals.criticForecast ?? signals.criticScore).map(Double.init)
    }
  }

  /// Percentile rank (0...1, ties averaged) of each reel per source. A source
  /// with fewer than two values in the pool has no ranking and is dropped.
  static func percentiles(_ signals: [Signals]) -> [Source: [Int64: Double]] {
    var result: [Source: [Int64: Double]] = [:]
    for source in Source.allCases {
      let values = signals.compactMap { s in value(source, s).map { (s.reelID, $0) } }
      guard values.count >= 2 else { continue }
      let sorted = values.sorted { $0.1 < $1.1 }
      var ranks: [Int64: Double] = [:]
      var index = 0
      while index < sorted.count {
        var end = index
        while end + 1 < sorted.count && sorted[end + 1].1 == sorted[index].1 { end += 1 }
        let rank = Double(index + end) / 2 / Double(sorted.count - 1)
        for position in index...end { ranks[sorted[position].0] = rank }
        index = end + 1
      }
      result[source] = ranks
    }
    return result
  }

  /// The on-device models a human answer to an item of this kind feeds. A
  /// pair pick lands in wizard_preferences, which only the outcome model's
  /// evaluation reads (its `preferenceAgreement` metric). A reel verdict
  /// lands in generation_reviews, which no on-device model trains on (the
  /// outcome model trains on Instagram outcomes, the ranker and taste on
  /// per-clip reviews); the wizard's prompt and lessons distillation read it.
  static func informs(_ kind: Kind) -> [ReelModelItem] {
    switch kind {
    case .reel: []
    case .pair: [.outcome]
    }
  }

  /// Where a reel verdict goes instead of an on-device model.
  static let reelVerdictDestination = "the wizard's lessons"

  static func rank(signals: [Signals], limit: Int = 5) -> [Item] {
    guard limit > 0 else { return [] }
    let ranks = percentiles(signals)
    let sourcePairs: [(Source, Source)] = Source.allCases.enumerated().flatMap { entry in
      Source.allCases.dropFirst(entry.offset + 1).map { (entry.element, $0) }
    }
    var items: [Item] = []

    for reel in signals where !reel.isJudged {
      var best: (gap: Double, high: Source, low: Source)?
      for (a, b) in sourcePairs {
        guard let left = ranks[a]?[reel.reelID], let right = ranks[b]?[reel.reelID] else { continue }
        let gap = abs(left - right)
        if gap > (best?.gap ?? 0) { best = left >= right ? (gap, a, b) : (gap, b, a) }
      }
      guard let best else { continue }
      let high = ranks[best.high]?[reel.reelID] ?? 0
      let low = ranks[best.low]?[reel.reelID] ?? 0
      items.append(Item(
        kind: .reel(reel.reelID), disagreement: best.gap, disagreeing: [best.high, best.low],
        informs: informs(.reel(reel.reelID)),
        summary: "\(best.high.label) ranks it \(percent(high)), \(best.low.label.lowercased()) \(percent(low)). "
          + "Your verdict informs \(reelVerdictDestination), not the on-device models."))
    }

    let batches = Dictionary(grouping: signals.filter { $0.batchID != nil && !$0.hasPreference }, by: { $0.batchID! })
    for (_, siblings) in batches where siblings.count > 1 {
      let ordered = siblings.sorted { $0.reelID < $1.reelID }
      for i in ordered.indices {
        for j in ordered.indices where j > i {
          let a = ordered[i]
          let b = ordered[j]
          var best: (score: Double, first: Source, second: Source, firstPrefersA: Bool)?
          for (s1, s2) in sourcePairs {
            guard let a1 = ranks[s1]?[a.reelID], let b1 = ranks[s1]?[b.reelID],
              let a2 = ranks[s2]?[a.reelID], let b2 = ranks[s2]?[b.reelID]
            else { continue }
            let d1 = a1 - b1
            let d2 = a2 - b2
            guard d1 * d2 < 0 else { continue }
            let score = (abs(d1) + abs(d2)) / 2
            if score > (best?.score ?? 0) { best = (score, s1, s2, d1 > 0) }
          }
          guard let best else { continue }
          let first = best.firstPrefersA ? "A" : "B"
          let second = best.firstPrefersA ? "B" : "A"
          items.append(Item(
            kind: .pair(a.reelID, b.reelID), disagreement: best.score,
            disagreeing: [best.first, best.second],
            informs: informs(.pair(a.reelID, b.reelID)),
            summary: "\(best.first.label) prefers \(first), \(best.second.label.lowercased()) prefers \(second)"))
        }
      }
    }

    return Array(items.sorted {
      $0.disagreement == $1.disagreement ? $0.id < $1.id : $0.disagreement > $1.disagreement
    }.prefix(limit))
  }

  private static func percent(_ rank: Double) -> String {
    "\(Int((rank * 100).rounded()))th percentile"
  }

  // MARK: - Signal building

  /// Builds every reel's signals from already-loaded rows. CPU work: call it
  /// off the main actor. `outcome` and `ranker` are nil when not eligible.
  static func signals(
    videos: [GeneratedVideoRecord], reelTraits: [Int64: ReelTraits],
    scenes: [Int64: SceneRecord], sceneTraits: [Int64: ReelTraits],
    verdicts: [Int64: Int], preferred: Set<Int64>,
    outcome: (any ReelModelPredictor)?, ranker: (any ReelModelPredictor)?
  ) -> [Signals] {
    videos.map { video in
      var signals = Signals(reelID: video.id, batchID: video.batchID)
      if let outcome, let traits = reelTraits[video.id],
        let lift = try? outcome.predict(traits.features), !lift.isEmpty
      {
        signals.outcome = ReelTraitExtractor.average(Array(lift.values))
      }
      if let ranker {
        let keeps = sceneIDs(video).compactMap { scenes[$0] }.compactMap { scene in
          (try? ranker.predict(ClipRanker.features(scene, traits: sceneTraits[scene.id])))?["keep"]
        }
        if !keeps.isEmpty { signals.ranker = ReelTraitExtractor.average(keeps) }
      }
      if let critique = video.critique {
        signals.criticScore = critique.score
        signals.criticForecast = critique.forecast
      }
      signals.humanVerdict = verdicts[video.id]
      signals.hasPreference = preferred.contains(video.id)
      return signals
    }
  }

  /// The scenes a reel was cut from, from its plan clips or its timeline.
  static func sceneIDs(_ video: GeneratedVideoRecord) -> [Int64] {
    var seen = Set<Int64>()
    return CriticEvaluator.plan(for: video).clips.map(\.sceneID).filter { seen.insert($0).inserted }
  }
}
