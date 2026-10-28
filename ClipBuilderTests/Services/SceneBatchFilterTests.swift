import Foundation
import Testing
@testable import Clip_Builder

struct SceneBatchFilterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 24 * 60 * 60) }

    private var runs: [SceneBatchFilter.Run] {
        [
            .init(id: 1, analyzedAt: daysAgo(0.5), videoType: .interview),
            .init(id: 2, analyzedAt: daysAgo(2.9), videoType: .podcast),
            .init(id: 3, analyzedAt: daysAgo(3.1), videoType: .fight),
            .init(id: 4, analyzedAt: nil, videoType: .fight),
            .init(id: 5, analyzedAt: daysAgo(10), videoType: nil),
            .init(id: 6, analyzedAt: daysAgo(10), videoType: .recap),
            .init(id: 7, analyzedAt: daysAgo(10), videoType: .training),
            .init(id: 8, analyzedAt: daysAgo(10), videoType: .other),
        ]
    }

    @Test func sentinelsAreNegativeAndDistinctFromAllBatches() {
        let ids = SceneBatchFilter.allCases.map(\.id)
        #expect(ids == [-2, -3, -4, -5, -6, -7, -8, -9])
        #expect(!ids.contains(-1))
        #expect(SceneBatchFilter.allCases.map(\.title) == ["Recent", "Interviews", "Podcasts", "Fights", "Fight Recaps", "Training", "Other", "Screen Recordings"])
    }

    @Test func recentCoversTheLastThreeDays() {
        let ids = SceneBatchFilter.runIDs(for: [SceneBatchFilter.recent.id], runs: runs, now: now)
        #expect(ids == [1, 2])
    }

    @Test func typeRowsMatchTheVideoType() {
        #expect(SceneBatchFilter.runIDs(for: [SceneBatchFilter.interviews.id], runs: runs, now: now) == [1])
        #expect(SceneBatchFilter.runIDs(for: [SceneBatchFilter.podcasts.id], runs: runs, now: now) == [2])
        #expect(SceneBatchFilter.runIDs(for: [SceneBatchFilter.fights.id], runs: runs, now: now) == [3, 4])
        #expect(SceneBatchFilter.runIDs(for: [SceneBatchFilter.recaps.id], runs: runs, now: now) == [6])
        #expect(SceneBatchFilter.runIDs(for: [SceneBatchFilter.training.id], runs: runs, now: now) == [7])
    }

    @Test func otherIncludesUntypedVideos() {
        #expect(SceneBatchFilter.runIDs(for: [SceneBatchFilter.other.id], runs: runs, now: now) == [5, 8])
    }

    @Test func everyVideoTypeHasARow() {
        let typed = Set(VideoType.allCases)
        let covered = Set(VideoType.allCases.filter { type in
            SceneBatchFilter.allCases.contains { $0 != .recent && $0.matches(.init(id: 1, analyzedAt: nil, videoType: type), now: now) }
        })
        #expect(covered == typed)
    }

    @Test func rowsAndBatchesCombineAsAUnion() {
        let selection: Set<Int64> = [SceneBatchFilter.podcasts.id, 5]
        #expect(SceneBatchFilter.runIDs(for: selection, runs: runs, now: now) == [2, 5])
    }

    @Test func allBatchesSentinelIsNotTreatedAsABatch() {
        #expect(SceneBatchFilter.runIDs(for: [-1], runs: runs, now: now).isEmpty)
    }
}
