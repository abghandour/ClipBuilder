import Foundation
import Testing

@testable import Clip_Builder

@Suite struct TeachingQueueTests {
  typealias Signals = TeachingQueue.Signals

  /// Outcome and critic agree on every reel: low-to-high by id.
  static func agreeing(_ count: Int, batch: (Int64) -> String? = { _ in nil }) -> [Signals] {
    (1...Int64(count)).map { id in
      Signals(reelID: id, batchID: batch(id), outcome: Double(id), criticScore: Int(id) * 5)
    }
  }

  @Test func plantedDisagreementRanksFirst() {
    var signals = Self.agreeing(10)
    // Reel 3: the outcome model loves it, the critic hates it.
    signals[2].outcome = 100
    signals[2].criticScore = 0
    let items = TeachingQueue.rank(signals: signals)
    #expect(items.first?.kind == .reel(3))
    #expect(Set(items.first?.disagreeing ?? []) == [.outcome, .critic])
    // A reel verdict trains no on-device model; the summary says where it goes.
    #expect(items.first?.informs == [])
    #expect(items.first?.summary.contains(TeachingQueue.reelVerdictDestination) == true)
    #expect((items.first?.disagreement ?? 0) > 0.9)
  }

  @Test func judgedReelsSkipped() {
    var signals = Self.agreeing(10)
    signals[2].outcome = 100
    signals[2].criticScore = 0
    signals[2].humanVerdict = 1
    let items = TeachingQueue.rank(signals: signals)
    #expect(!items.contains { $0.kind == .reel(3) })
    // An unset verdict (0) still counts as unjudged.
    signals[2].humanVerdict = 0
    #expect(TeachingQueue.rank(signals: signals).first?.kind == .reel(3))
  }

  @Test func pairRuleNeedsOppositeOrdering() {
    let signals = [
      Signals(reelID: 1, batchID: "b", outcome: 0.9, ranker: 0.1),
      Signals(reelID: 2, batchID: "b", outcome: 0.1, ranker: 0.9),
      Signals(reelID: 3, batchID: "c", outcome: 0.8, ranker: 0.8),
      Signals(reelID: 4, batchID: "c", outcome: 0.2, ranker: 0.2),
    ]
    let pairs = TeachingQueue.rank(signals: signals, limit: 20).filter {
      if case .pair = $0.kind { return true } else { return false }
    }
    #expect(pairs.map(\.kind) == [.pair(1, 2)])
    #expect(pairs.first?.informs == [.outcome])
    #expect((pairs.first?.disagreement ?? 0) > 0)
  }

  @Test func pairsWithPreferenceSkipped() {
    var signals = [
      Signals(reelID: 1, batchID: "b", outcome: 0.9, ranker: 0.1),
      Signals(reelID: 2, batchID: "b", outcome: 0.1, ranker: 0.9),
    ]
    #expect(TeachingQueue.rank(signals: signals).contains { $0.kind == .pair(1, 2) })
    signals[1].hasPreference = true
    #expect(!TeachingQueue.rank(signals: signals).contains { $0.kind == .pair(1, 2) })
  }

  @Test func limitRespected() {
    var signals = Self.agreeing(20)
    for index in stride(from: 0, to: 20, by: 2) { signals[index].criticScore = 100 - index * 5 }
    #expect(TeachingQueue.rank(signals: signals).count == 5)
    #expect(TeachingQueue.rank(signals: signals, limit: 2).count == 2)
    #expect(TeachingQueue.rank(signals: signals, limit: 0).isEmpty)
  }

  @Test func nilSourcesIgnored() {
    // Only one source per reel: nothing to disagree with.
    let lonely = (1...6).map { Signals(reelID: Int64($0), outcome: Double($0)) }
    #expect(TeachingQueue.rank(signals: lonely).isEmpty)
    // A source present on a single reel has no ranking.
    var signals = Self.agreeing(6)
    signals[0].ranker = 1
    let items = TeachingQueue.rank(signals: signals, limit: 50)
    #expect(!items.contains { $0.disagreeing.contains(.ranker) })
    #expect(TeachingQueue.percentiles(signals)[.ranker] == nil)
    #expect(TeachingQueue.percentiles(signals)[.taste] == nil)
  }

  @Test func reelItemsNeverInformOnDeviceModelsAndPairsInformOutcome() {
    var signals = (1...6).map { Signals(reelID: Int64($0), ranker: Double($0), criticScore: $0 * 10) }
    signals[0].ranker = 100
    for index in signals.indices { signals[index].criticForecast = signals[index].criticScore }
    let reels = TeachingQueue.rank(signals: signals, limit: 50).filter {
      if case .reel = $0.kind { return true } else { return false }
    }
    #expect(!reels.isEmpty)
    #expect(reels.allSatisfy { $0.informs.isEmpty })
    #expect(TeachingQueue.informs(.reel(1)) == [])
    #expect(TeachingQueue.informs(.pair(1, 2)) == [.outcome])
  }

  @Test func answeredItems() {
    let reel = TeachingQueue.Item(kind: .reel(1), disagreement: 1, disagreeing: [], informs: [.outcome], summary: "")
    let pair = TeachingQueue.Item(kind: .pair(1, 2), disagreement: 1, disagreeing: [], informs: [.ranker], summary: "")
    var byID = [Int64(1): Signals(reelID: 1), 2: Signals(reelID: 2)]
    #expect(!reel.isAnswered(by: byID) && !pair.isAnswered(by: byID))
    byID[1]?.humanVerdict = -1
    byID[2]?.hasPreference = true
    #expect(reel.isAnswered(by: byID) && pair.isAnswered(by: byID))
  }

  @Test func signalsFromRecords() {
    struct Constant: ReelModelPredictor {
      var values: [String: Double]
      func predict(_ features: [String: Double]) throws -> [String: Double] { values }
    }
    var video = Fixtures.generatedVideo(id: 7, batchID: "b")
    video.critiqueJSON = #"{"score":70,"summary":"","strengths":[],"issues":[],"notes":[],"regenerate":false,"forecast":40}"#
    let signals = TeachingQueue.signals(
      videos: [video, Fixtures.generatedVideo(id: 8)], reelTraits: [7: ReelTraits()],
      scenes: [:], sceneTraits: [:], verdicts: [8: 1], preferred: [7],
      outcome: Constant(values: ["a": 1, "b": 3]), ranker: Constant(values: ["keep": 1]))
    #expect(signals[0].outcome == 2)
    #expect(signals[0].ranker == nil)  // no plan scenes
    #expect(signals[0].criticScore == 70 && signals[0].criticForecast == 40)
    #expect(signals[0].hasPreference && signals[0].batchID == "b")
    #expect(signals[1].outcome == nil && signals[1].humanVerdict == 1)
    #expect(signals.allSatisfy { $0.taste == nil })
  }
}
